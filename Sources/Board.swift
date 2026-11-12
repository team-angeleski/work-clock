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
    var late: Int? = nil       // minutes late today (costs a point each)
    var due_min: Int? = nil    // clock-in time in minutes after midnight, nil on a day off
    var in_min: Int? = nil     // when they clocked in today
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
    let me: MeInfo?
    let mine: Mine?
}

private struct Mine: Decodable {
    let others_today: Int
    let history: [String: Int]
}

private struct SignedIn: Decodable { let member_id: UUID?; let secret: UUID?; let code: String?; let name: String?; let error: String? }

private struct MeInfo: Decodable {
    let email: String?
    let start_min: Int
    let workdays: Int
    let next_start_min: Int?
    let next_workdays: Int?
    let next_from: String?
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
    /// Where my email alerts go (nil = off).
    private(set) var email: String?

    var memberID: UUID? { defaults.string(forKey: "boardMember").flatMap(UUID.init) }
    var joined: Bool { memberID != nil }
    var inviteCode: String? { defaults.string(forKey: "inviteCode") }
    var me: Friend? { friends.first { $0.id == memberID } }
    var others: [Friend] { friends.filter { $0.id != memberID } }

    /// Minutes late today, as the server counts them (live locally until clocked in).
    var myLate: Int {
        guard let store else { return 0 }
        let server = me?.late ?? 0
        guard me?.due_min != nil else { return 0 }
        return max(server, store.office.lateMinutes(now: store.now, clockedIn: store.clockedIn))
    }

    /// My live score after the lateness penalty.
    var myScore: Int {
        guard let store else { return 0 }
        return max(me?.score ?? 0, max(0, Int(store.todayScore) - myLate * 60))
    }

    /// The race with my own row using my live numbers (the server's copy lags a few minutes).
    var ranked: [Friend] {
        guard let store else { return friends }
        return friends.map { f in
            guard f.id == memberID else { return f }
            let score = myScore
            return Friend(id: f.id, name: f.name, level: store.level, streak: store.streak,
                          focusing: store.mode == .running && store.onTask,
                          today: max(f.today, Int(store.today)), score: score,
                          yesterday: f.yesterday, week: f.week - f.score + score,
                          taunted_today: f.taunted_today, late: myLate, due_min: f.due_min, in_min: f.in_min)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    /// Yesterday's winner(s), by score.
    var champions: Set<UUID> {
        let best = friends.map(\.yesterday).max() ?? 0
        guard best >= 600 else { return [] }
        return Set(friends.filter { $0.yesterday == best }.map(\.id))
    }

    @ObservationIgnored var onShowTaunt: ((Taunt?) -> Void)?
    @ObservationIgnored var onSynced: (() -> Void)?
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
        let mine = myScore
        let rate = store.scoreRate
        let ranked = others.sorted { $0.score > $1.score }
        if let ahead = ranked.filter({ $0.score >= mine }).last {
            let gap = Double(ahead.score - mine) / rate
            return "\(minutes(gap + 60)) to beat \(short(ahead.name))"
        }
        let second = ranked[0]
        return "Leading \(short(second.name)) by \(minutes(Double(mine - second.score)))"
    }

    var leading: Bool { others.allSatisfy { myScore > $0.score } && !others.isEmpty }

    private func short(_ name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return first.count > 9 ? String(first.prefix(8)) + "…" : first
    }

    private func minutes(_ seconds: Double) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    // MARK: Actions

    
    func join(code: String?, name: String, email: String, start: Int, days: Int) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Add your name first"; return }
        busy = true; defer { busy = false }
        do {
            let data = code == nil
                ? try await call("focus_create", ["p_name": name, "p_platform": "mac", "p_email": email,
                                                  "p_start_min": start, "p_workdays": days])
                : try await call("focus_join", ["p_code": code, "p_name": name, "p_platform": "mac", "p_email": email,
                                                "p_start_min": start, "p_workdays": days])
            let j = try JSONDecoder().decode(Joined.self, from: data)
            defaults.set(j.member_id.uuidString, forKey: "boardMember")
            defaults.set(j.secret.uuidString, forKey: "boardSecret")
            defaults.set(j.code, forKey: "boardCode")
            defaults.set(name, forKey: "boardName")
            defaults.removeObject(forKey: "inviteCode")
            self.code = j.code
            error = nil
            store?.announce(code == nil ? "Board \(j.code) created" : "Joined the board", sound: "Glass")
            Self.askForNotifications()
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

    /// On a board but no email yet (accounts from before 1.3): setup asks for one.
    var needsEmail: Bool { joined && lastSynced != nil && email == nil }

    /// Where alerts go. Required; it can be changed but not removed.
    func setEmail(_ value: String) async {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { error = "An email is required"; return }
        busy = true; defer { busy = false }
        do {
            _ = try await call("focus_set_email", ["p_member": memberID?.uuidString, "p_secret": secret?.uuidString, "p_email": v])
            error = nil
            store?.announce("Email saved", sound: "Pop")
            await sync()
        } catch { self.error = describe(error) }
    }

    /// Clock-in time and workdays. The server applies it from tomorrow.
    func setSchedule(start: Int, days: Int) async {
        guard joined else { return }
        do {
            _ = try await call("focus_schedule", ["p_member": memberID?.uuidString, "p_secret": secret?.uuidString,
                                                  "p_start_min": start, "p_workdays": days])
            error = nil
            await sync()
        } catch { self.error = describe(error) }
    }

    // MARK: Signing in on another computer

    /// Emails a 6-digit code to the account's address.
    func sendCode(to email: String) async -> Bool {
        busy = true; defer { busy = false }
        do {
            _ = try await call("focus_login_start", ["p_email": email.trimmingCharacters(in: .whitespacesAndNewlines)])
            error = nil
            return true
        } catch { self.error = describe(error); return false }
    }

    /// Trades the code for the account; this computer then counts toward it.
    func signIn(email: String, code: String) async -> Bool {
        busy = true; defer { busy = false }
        do {
            let data = try await call("focus_login_finish", ["p_email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             "p_code": code.filter(\.isNumber)])
            let r = try JSONDecoder().decode(SignedIn.self, from: data)
            if let e = r.error { error = e; return false }
            guard let id = r.member_id, let secret = r.secret else { error = "Couldn't sign in"; return false }
            defaults.set(id.uuidString, forKey: "boardMember")
            defaults.set(secret.uuidString, forKey: "boardSecret")
            defaults.set(r.code, forKey: "boardCode")
            defaults.set(r.name, forKey: "boardName")
            defaults.removeObject(forKey: "inviteCode")
            self.code = r.code
            error = nil
            store?.announce("Signed in as \(r.name ?? "you")", sound: "Glass")
            await sync()
            return true
        } catch { self.error = describe(error); return false }
    }

    /// This computer, as one of possibly several on the account.
    static var deviceID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "deviceID")
        return id
    }

    /// Stop counting this computer toward the account. The account and its other computers carry on.
    func signOut() { forget() }

    /// Deletes the account everywhere.
    func leave() async {
        _ = try? await call("focus_leave", ["p_member": memberID?.uuidString, "p_secret": secret?.uuidString])
        forget()
    }

    private func forget() {
        for k in ["boardMember", "boardSecret", "boardCode"] { defaults.removeObject(forKey: k) }
        friends = []; code = nil; tauntsLeft = 0; queue = []; scheduled = []; email = nil
        store?.applyRemote(othersToday: 0, history: [:])
    }

    /// The command a friend pastes into Terminal to install and join.
    var installCommand: String? {
        code.map { "curl -fsSL https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh | bash -s \($0)" }
    }

    // MARK: Sync

    private func syncIfDue() {
        guard joined else { return }
        let every: TimeInterval = defaults.bool(forKey: "debugCoachFast") ? 15 : store?.mode == .running ? 120 : 300
        let since = Date().timeIntervalSince(lastSyncAttempt)
        // Check in just before 9am and 1pm: the server only credits bonus time it saw before the cut-off.
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let cutoff = (c.hour == 8 || c.hour == 12) && c.minute == 59 && since > 45
        if since >= every || cutoff { Task { await sync() } }
    }

    /// Sync now (start, stop, wake) so friends see the live dot quickly.
    func nudge() { Task { await sync() } }

    func sync() async {
        guard joined, let store else { return }
        lastSyncAttempt = Date()
        do {
            let data = try await call("focus_sync", [
                "p_member": memberID?.uuidString, "p_secret": secret?.uuidString,
                "p_day": Self.day(), "p_seconds": Int(store.localToday), "p_score": Int(store.todayScore),
                "p_level": store.level, "p_streak": store.streak,
                "p_focusing": store.mode == .running && store.onTask,
                "p_tz_minutes": TimeZone.current.secondsFromGMT() / 60,
                "p_device": Self.deviceID, "p_blown": store.blownToday])
            let s = try JSONDecoder().decode(BoardState.self, from: data)
            friends = s.members
            code = s.code
            tauntsLeft = s.taunts_left
            if let m = s.mine { store.applyRemote(othersToday: TimeInterval(m.others_today), history: m.history) }
            if let m = s.me {
                email = m.email
                store.office.adopt(start: m.start_min, days: m.workdays, nextStart: m.next_start_min,
                                   nextDays: m.next_workdays, from: m.next_from)
            }
            lastSynced = Date()
            error = nil
            schedule(s.incoming)
            onSynced?()
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
            notify("You won yesterday 👑", "You've got \(tauntsLeft) taunts to send. Right-click your clock.")
        } else if let winner = friends.first(where: { champs.contains($0.id) }) {
            store?.announce("\(winner.name) won yesterday. Brace yourself.", sound: "Funk", seconds: 6)
            notify("\(winner.name) won yesterday", "Taunts incoming. Win today to get your revenge.")
        }
    }

    private func announceLeadChange() {
        guard !others.isEmpty, let store, store.today > 300 else { return }
        let now = leading
        if let before = lastLead, before != now {
            if now {
                store.announce("You took the lead!", sound: "Glass")
                notify("You took the lead 👑", raceLine ?? "Keep going")
            } else if let top = others.max(by: { $0.score < $1.score }) {
                store.announce("\(top.name) overtook you", sound: "Basso")
                notify("\(top.name) overtook you", raceLine.map { "\($0). Get back to it." } ?? "Get back to it.")
            }
        }
        lastLead = now
    }

    // MARK: Taunts popping up

    /// Each unseen taunt pops up at a random moment in the next 2–45 minutes, while I'm at the computer.
    private func schedule(_ incoming: [Taunt]) {
        for t in incoming where !scheduled.contains(t.id) {
            scheduled.insert(t.id)
            // Hidden test switch: `defaults write local.workclock debugFastTaunts -bool YES`.
            let delay = defaults.bool(forKey: "debugFastTaunts") ? 3 : Double.random(in: 120...2700)
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
        notify("\(next.from_name) says", next.message)
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
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues { $0 ?? NSNull() })
        let (data, resp) = try await send(req)
        guard let http = resp as? HTTPURLResponse, http.statusCode < 300 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw BoardError(text: msg ?? "Couldn't reach the board")
        }
        return data
    }

    /// Retries dropped connections and timeouts (Wi-Fi blips, sleeping Macs) before giving up.
    private func send(_ req: URLRequest, attempts: Int = 3) async throws -> (Data, URLResponse) {
        var last: Error?
        for attempt in 0..<attempts {
            do { return try await URLSession.shared.data(for: req) } catch let e as URLError {
                last = e
                let transient: [URLError.Code] = [.networkConnectionLost, .timedOut, .cannotConnectToHost,
                                                  .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
                guard transient.contains(e.code), attempt < attempts - 1 else { break }
                try? await Task.sleep(for: .milliseconds(600 * (attempt + 1)))
            }
        }
        throw last ?? URLError(.unknown)
    }

    static func askForNotifications() { Notify.ask() }
    private func notify(_ title: String, _ body: String) { Notify.post(title, body) }

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
