import AppKit
import UserNotifications

/// Mac notifications that stay in Notification Center.
enum Notify {
    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("WorkClock notifications: granted=\(granted) error=\(String(describing: error))")
        }
    }

    static func post(_ title: String, _ body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// The coach: small, well-timed pushes back to work. Everything here exists to get you
/// focusing sooner, keep you there longer, and pull you back fast when you drift.
@MainActor
final class Coach {
    private weak var store: Store?
    private weak var board: Board?
    private let defaults = UserDefaults.standard

    /// Shakes the pill (set by the app).
    var onShake: (() -> Void)?

    // Drifting off mid-session
    private var offStart: Date?
    private var shookThisEpisode = 0
    private var notifiedThisEpisode = false

    // Not started yet today
    private var firstActive: Date?
    private var firstActiveDay = ""

    // Friends starting to focus
    private var friendWasFocusing: [UUID: Bool] = [:]
    private var friendNoticed: [UUID: Date] = [:]

    init(store: Store, board: Board) {
        self.store = store
        self.board = board
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
    }

    private var userActive: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 60
    }

    private func once(_ key: String) -> Bool {
        let k = "coach.\(key).\(Board.day())"
        guard !defaults.bool(forKey: k) else { return false }
        defaults.set(true, forKey: k)
        return true
    }

    private func step() {
        guard let store else { return }
        let now = Date()
        drifting(store, now)
        clockIn(store, now)
        lockDistractions(store, now)
        notStarted(store, now)
        streakAtRisk(store, now)
        recap(store, now)
    }

    // MARK: 6. Office hours: be at your desk on time

    private func clockIn(_ store: Store, _ now: Date) {
        guard let due = store.office.due(on: now), !store.clockedIn, store.mode != .running else { return }
        let toGo = due.timeIntervalSince(now)
        let at = Office.text(store.office.startMin)
        let onBoard = board?.joined == true && !(board?.others.isEmpty ?? true)
        if toGo <= 600 && toGo > 0, once("soon") {
            Notify.post("Clock in by \(at)", "10 minutes." + (onBoard ? " Late costs a point a minute, and your friends get told." : ""), id: "office")
        } else if toGo <= 0 && toGo > -3600, once("due") {
            Notify.post("It's \(at). Clock in.", "One click on your clock, pick your apps, go.", id: "office")
            store.announce("Clock in", sound: "Funk", seconds: 6)
            onShake?()
        } else if toGo <= -15 * 60 && toGo > -3 * 3600, once("late15") {
            let late = store.office.lateMinutes(now: now, clockedIn: false)
            Notify.post("You're \(late) minutes late", onBoard ? "Your friends have been told. −\(late) and counting." : "Every minute you wait makes it harder. Start with 5 minutes.", id: "office")
            onShake?()
        }
    }

    /// Before you've clocked in on a workday, distracting sites get closed.
    private var lastLockCheck = Date.distantPast
    private func lockDistractions(_ store: Store, _ now: Date) {
        guard store.office.lockDistractions, store.office.isWorkday(now), !store.clockedIn,
              Calendar.current.component(.hour, from: now) >= 5,
              now.timeIntervalSince(lastLockCheck) >= 4,
              let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              Browser.isBrowser(id) else { return }
        lastLockCheck = now
        guard let domain = Browser.domain(of: id), Browser.isDistraction(domain) else { return }
        TabCloser.closeFrontTab(of: app)
        store.announce("Clock in first 🔒", sound: "Basso", seconds: 5)
        onShake?()
    }

    // MARK: 5. Streak about to break

    private func streakAtRisk(_ store: Store, _ now: Date) {
        guard Calendar.current.component(.hour, from: now) >= 20, !store.goalMet, store.streak > 0,
              store.mode != .running, once("streak") else { return }
        let left = long(max(store.goal - store.today, 0))
        Notify.post("Your \(store.streak)-day streak ends at midnight", "\(left) to go. Start now and keep it alive.", id: "streak")
        store.announce("Streak at risk", sound: "Funk", seconds: 6)
        onShake?()
    }

    // MARK: 1. Drifting during a session

    private func drifting(_ store: Store, _ now: Date) {
        // Only while a session is running and you've left your work; idle is handled by idle pause.
        guard store.mode == .running, !store.onTask, store.offReason != "Away" else {
            offStart = nil; shookThisEpisode = 0; notifiedThisEpisode = false
            return
        }
        let start = offStart ?? now
        offStart = start
        // Hidden test switch: `defaults write local.workclock debugCoachFast -bool YES` runs 10x faster.
        let off = now.timeIntervalSince(start) * (defaults.bool(forKey: "debugCoachFast") ? 10 : 1)
        let site = store.offReason          // a distraction site, or nil for some other app
        // Distraction sites: shake at 20s and 60s, notify at 2 min. Other apps: shake at 90s, notify at 5 min.
        let shakes: [TimeInterval] = site != nil ? [20, 60] : [90]
        let notifyAt: TimeInterval = site != nil ? 120 : 300
        if shookThisEpisode < shakes.count, off >= shakes[shookThisEpisode] {
            shookThisEpisode += 1
            store.announce("Back to work?", sound: "Basso", seconds: 4)
            onShake?()
        }
        if off >= notifyAt && !notifiedThisEpisode {
            notifiedThisEpisode = true
            let race = board?.raceLine.map { " \($0)." } ?? ""
            Notify.post(site.map { "\(Int(notifyAt / 60)) minutes on \($0)" } ?? "You left your work apps",
                        "Your clock is paused.\(race) Get back in.", id: "drift")
        }
    }

    // MARK: 2. At the computer but not started

    private func notStarted(_ store: Store, _ now: Date) {
        let hour = Calendar.current.component(.hour, from: now)
        let day = Board.day(now)
        if firstActiveDay != day { firstActiveDay = day; firstActive = nil }
        guard store.mode == .idle, store.today < 60, (7..<20).contains(hour), userActive else { return }
        let first = firstActive ?? now
        firstActive = first
        let waited = now.timeIntervalSince(first)
        let race = board?.raceLine
        if waited >= 15 * 60, once("nudge1") {
            Notify.post("You haven't started yet",
                        race.map { "\($0). One click on your clock and you're in." }
                            ?? "\(Store.rank(0)) today so far. One click on your clock and you're in.", id: "start")
            store.announce("Tap to start", sound: "Funk", seconds: 6)
            onShake?()
        } else if waited >= 90 * 60, once("nudge2") {
            let friendsLine = board?.others.filter { $0.today > 0 }.map { "\($0.name) is on \(long(Double($0.score)))" }.first
            Notify.post("Still nothing on the clock", (friendsLine.map { "\($0). " } ?? "") + "Pick one thing and give it 25 minutes.", id: "start")
            onShake?()
        }
    }

    // MARK: 3. Friends starting to focus (called after each board sync)

    func boardSynced() {
        guard let board, let store else { return }
        // A friend blew their clock-in: rub it in.
        for f in board.others where f.due_min != nil && f.in_min == nil && (f.late ?? 0) >= 15 {
            guard once("friendlate-\(f.id)") else { continue }
            Notify.post("\(f.name) hasn't clocked in", "\(f.late ?? 15) minutes late and losing a point a minute. Get ahead.", id: "friendlate-\(f.id)")
        }
        for f in board.others {
            defer { friendWasFocusing[f.id] = f.focusing }
            guard f.focusing, friendWasFocusing[f.id] == false else { continue }
            // Only when I'm not already working, and at most once an hour per friend.
            guard store.mode != .running, Date().timeIntervalSince(friendNoticed[f.id] ?? .distantPast) > 3600 else { continue }
            friendNoticed[f.id] = Date()
            Notify.post("\(f.name) just started focusing",
                        "They're on \(long(Double(f.score))). You're on \(long(store.todayScore)). Your move.", id: "friend-\(f.id)")
        }
    }

    // MARK: 4. End-of-day recap at 9pm

    private func recap(_ store: Store, _ now: Date) {
        guard Calendar.current.component(.hour, from: now) >= 21, store.today >= 60, once("recap") else { return }
        let p = store.todayPercentile
        var body = "\(long(store.today)) focused · \(Store.rank(p)) (\(Store.tier(p)))."
        if let board, !board.others.isEmpty {
            body += board.leading ? " You're beating everyone. Win the day, earn 3 taunts."
                                  : (board.raceLine.map { " \($0) before midnight." } ?? "")
        }
        body += " Tomorrow's goal: \(long(store.adaptiveGoalTomorrow))."
        if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
            store.office.promote()
            let days = store.office.plannedDays
            if days & (1 << Office.bit(for: tomorrow)) != 0 {
                body += " Clock in by \(Office.text(store.office.plannedStart))."
            }
        }
        Notify.post(store.goalMet ? "Goal smashed today 🎉" : "Today's focus", body, id: "recap")
    }
}
