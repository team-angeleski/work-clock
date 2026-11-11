import AppKit
import Observation

// MARK: Friend board
// A private race between up to 5 friends, ranked by focus score (focus time plus bonuses).
// Yesterday's winner gets 3 taunts: messages that pop up on friends' screens at random moments.
// The server checks every number: focus can't grow faster than real time, and only
// yesterday's real winner can send taunts.

struct Friend: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let level: Int
    let streak: Int
    let focusing: Bool
    let today: Int       // focused seconds today
    let score: Int       // today's score in seconds, bonuses included
    let yesterday: Int   // yesterday's score
    let week: Int        // last 7 days' score
    let taunted_today: Int
}

struct Taunt: Decodable, Identifiable, Equatable {
    let id: UUID
    let message: String
    let from_name: String
}

private struct BoardState: Decodable {
    let code: String
    let taunts_left: Int
    let members: [Friend]
    let incoming: [Taunt]
}

private struct Joined: Decodable { let member_id: UUID; let secret: UUID; let code: String }

@MainActor @Observable
final class Board {
    private(set) var friends: [Friend] = []
    private(set) var code: String?
    private(set) var tauntsLeft = 0
    private(set) var error: String?
    private(set) var busy = false
    private(set) var lastSynced: Date?
    /// The taunt currently popping up on screen.
    private(set) var showing: Taunt?

    var memberID: UUID? { defaults.string(forKey: "boardMember").flatMap(UUID.init) }
    var joined: Bool { memberID != nil }
    var inviteCode: String? { defaults.string(forKey: "inviteCode") }
    var me: Friend? { friends.first { $0.id == memberID } }
    var others: [Friend] { friends.filter { $0.id != memberID } }

    /// Yesterday's winner(s), by score.
    var champions: Set<UUID> {
        let best = friends.map(\.yesterday).max() ?? 0
        guard best >= 600 else { return [] }
        return Set(friends.filter { $0.yesterday == best }.map(\.id))
    }

    @ObservationIgnored var onShowTaunt: ((Taunt?) -> Void)?
    @ObservationIgnored private weak var store: Store?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var scheduled: Set<UUID> = []
    @ObservationIgnored private var queue: [Taunt] = []
    @ObservationIgnored private var lastSyncAttempt = Date.distantPast
    @ObservationIgnored private var announcedDay = ""
    @ObservationIgnored private var lastLead: Bool?

    private let base = URL(string: "https://kjjhpstxwwldjlskefrr.supabase.co/rest/v1/rpc/")!
    private let key: String = Bundle.main.url(forResource: "anon", withExtension: "key")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    private var secret: UUID? { defaults.string(forKey: "boardSecret").flatMap(UUID.init) }

    init(store: Store) {
        self.store = store
        code = defaults.string(forKey: "boardCode")
        announcedDay = defaults.string(forKey: "boardAnnouncedDay") ?? ""
        // Light polling: every 2 minutes while focusing, every 5 otherwise. ~1 KB each.
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncIfDue() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudge() }
        }
        Task { await sync() }
    }

    // MARK: The race

    /// "15m to beat Cung", "Leading Cung by 20m", or nil when alone.
    var raceLine: String? {
        guard let store, joined, !others.isEmpty else { return nil }
        let mine = Int(store.todayScore)
        let rate = store.scoreRate
        let ranked = others.sorted { $0.score > $1.score }
        if let ahead = ranked.filter({ $0.score >= mine }).last {
            let gap = Double(ahead.score - mine) / rate
            return "\(minutes(gap + 60)) to beat \(ahead.name)"
        }
        let second = ranked[0]
        return "Leading \(second.name) by \(minutes(Double(mine - second.score)))"
    }

    var leading: Bool { others.allSatisfy { Int(store?.todayScore ?? 0) > $0.score } && !others.isEmpty }

    private func minutes(_ seconds: Double) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    // MARK: Actions

    func create(name: String) async { await join(code: nil, name: name) }

    func join(code: String?, name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Add your name first"; return }
        busy = true; defer { busy = false }
        do {
            let data = code == nil
                ? try await call("focus_create", ["p_name": name, "p_platform": "mac"])
                : try await call("focus_join", ["p_code": code, "p_name": name, "p_platform": "mac"])
            let j = try JSONDecoder().decode(Joined.self, from: data)
            defaults.set(j.member_id.uuidString, forKey: "boardMember")
            defaults.set(j.secret.uuidString, forKey: "boardSecret")
            defaults.set(j.code, forKey: "boardCode")
            defaults.set(name, forKey: "boardName")
            defaults.removeObject(forKey: "inviteCode")
            self.code = j.code
            error = nil
            store?.announce(code == nil ? "Board \(j.code) created" : "Joined the board", sound: "Glass")
            await sync()
        } catch { self.error = describe(error) }
    }

    func taunt(_ friend: Friend, message: String) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "Write something first"; return }
        busy = true; defer { busy = false }
        do {
            _ = try await call("focus_taunt", [
                "p_member": memberID?.uuidString, "p_secret": secret?.uuidString,
                "p_target": friend.id.uuidString, "p_message": String(text.prefix(80)), "p_day": Self.day()])
            error = nil
            store?.announce("Taunt sent to \(friend.name)", sound: "Purr")
            await sync()
        } catch { self.error = describe(error) }
    }

    func leave() async {
        _ = try? await call("focus_leave", ["p_member": memberID?.uuidString, "p_secret": secret?.uuidString])
        forget()
    }

    private func forget() {
        for k in ["boardMember", "boardSecret", "boardCode"] { defaults.removeObject(forKey: k) }
        friends = []; code = nil; tauntsLeft = 0; queue = []; scheduled = []
    }

    /// The command a friend pastes into Terminal to install and join.
    var installCommand: String? {
        code.map { "curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s \($0)" }
    }

    // MARK: Sync

    private func syncIfDue() {
        guard joined else { return }
        let every: TimeInterval = store?.mode == .running ? 120 : 300
        if Date().timeIntervalSince(lastSyncAttempt) >= every { Task { await sync() } }
    }

    /// Sync now (start, stop, wake) so friends see the live dot quickly.
    func nudge() { Task { await sync() } }

    func sync() async {
        guard joined, let store else { return }
        lastSyncAttempt = Date()
        do {
            let data = try await call("focus_sync", [
                "p_member": memberID?.uuidString, "p_secret": secret?.uuidString,
                "p_day": Self.day(), "p_seconds": Int(store.today), "p_score": Int(store.todayScore),
                "p_level": store.level, "p_streak": store.streak,
                "p_focusing": store.mode == .running && store.onTask])
            let s = try JSONDecoder().decode(BoardState.self, from: data)
            friends = s.members
            code = s.code
            tauntsLeft = s.taunts_left
            lastSynced = Date()
            error = nil
            schedule(s.incoming)
            announceDay()
            announceLeadChange()
        } catch let e as BoardError where e.text == "Not a member of this board" {
            forget()
            self.error = "You were removed from the board"
        } catch {
            // Offline: keep the last known board; the next sync catches up.
        }
    }

    /// Once a day: tell me who won yesterday.
    private func announceDay() {
        let today = Self.day()
        guard announcedDay != today, let mine = memberID, friends.count > 1 else { return }
        let champs = champions
        guard !champs.isEmpty else { return }
        announcedDay = today
        defaults.set(today, forKey: "boardAnnouncedDay")
        if champs.contains(mine) {
            store?.announce("You won yesterday! \(tauntsLeft) taunts ready", sound: "Hero", seconds: 6)
        } else if let winner = friends.first(where: { champs.contains($0.id) }) {
            store?.announce("\(winner.name) won yesterday. Brace yourself.", sound: "Funk", seconds: 6)
        }
    }

    private func announceLeadChange() {
        guard !others.isEmpty, let store, store.today > 300 else { return }
        let now = leading
        if let before = lastLead, before != now {
            if now { store.announce("You took the lead!", sound: "Glass") }
            else if let top = others.max(by: { $0.score < $1.score }) {
                store.announce("\(top.name) overtook you", sound: "Basso")
            }
        }
        lastLead = now
    }

    // MARK: Taunts popping up

    /// Each unseen taunt pops up at a random moment in the next 2–45 minutes, while I'm at the computer.
    private func schedule(_ incoming: [Taunt]) {
        for t in incoming where !scheduled.contains(t.id) {
            scheduled.insert(t.id)
            let delay = Double.random(in: 120...2700)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.enqueue(t) }
        }
    }

    private func enqueue(_ t: Taunt) {
        queue.append(t)
        showNext()
    }

    private func showNext() {
        guard showing == nil, let next = queue.first else { return }
        // Only pop up when someone's actually there to see it.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 60 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.showNext() }
            return
        }
        queue.removeFirst()
        showing = next
        onShowTaunt?(next)
        Self.playPoop()
        Task { _ = try? await call("focus_seen", ["p_member": memberID?.uuidString, "p_secret": secret?.uuidString, "p_taunt": next.id.uuidString]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.dismissTaunt() }
    }

    func dismissTaunt() {
        guard showing != nil else { return }
        showing = nil
        onShowTaunt?(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.showNext() }
    }

    static func playPoop() {
        if let url = Bundle.main.url(forResource: "poop", withExtension: "wav") {
            NSSound(contentsOf: url, byReference: true)?.play()
        }
    }

    // MARK: Network

    struct BoardError: Error { let text: String }

    private func call(_ fn: String, _ body: [String: Any?]) async throws -> Data {
        guard !key.isEmpty else { throw BoardError(text: "This build has no board key") }
        var req = URLRequest(url: base.appendingPathComponent(fn))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 300 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw BoardError(text: msg ?? "Couldn't reach the board")
        }
        return data
    }

    private func describe(_ e: Error) -> String {
        if let b = e as? BoardError { return b.text }
        return "Couldn't reach the board. Check your internet."
    }

    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Starters for the taunt box.
    static let ideas = [
        "ur a loser 🫵",
        "I did more before lunch than you did all day",
        "Is your keyboard decorative?",
        "Touch keyboard, not grass",
        "Elite tier called. It said 'who?'",
        "Imagine being out-focused by me",
    ]
}
