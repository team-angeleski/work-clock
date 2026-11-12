import AppKit
import Observation

/// Office hours: the commitment that replaces "my boss expects me at 9".
/// You pick a clock-in time and workdays. Changes only start tomorrow, so you can't push
/// today's start back once you're running late. Clocking in = your first 5 focused minutes.
@MainActor @Observable
final class Office {
    private(set) var startMin: Int
    private(set) var workdays: Int          // bit 0 = Monday … bit 6 = Sunday
    private(set) var nextStartMin: Int?
    private(set) var nextWorkdays: Int?
    private(set) var nextFrom: String?      // yyyy-MM-dd the pending change starts
    var lockDistractions: Bool { didSet { d.set(lockDistractions, forKey: "officeLock") } }

    @ObservationIgnored private let d = UserDefaults.standard
    static let grace = 5          // minutes before late counts
    static let clockInSeconds: TimeInterval = 300

    init() {
        startMin = d.object(forKey: "officeStart") as? Int ?? 540
        workdays = d.object(forKey: "officeDays") as? Int ?? 31
        nextStartMin = d.object(forKey: "officeNextStart") as? Int
        nextWorkdays = d.object(forKey: "officeNextDays") as? Int
        nextFrom = d.string(forKey: "officeNextFrom")
        lockDistractions = d.object(forKey: "officeLock") as? Bool ?? true
        promote()
    }

    /// The schedule you'll have from tomorrow (pending change, or the current one).
    var plannedStart: Int { nextStartMin ?? startMin }
    var plannedDays: Int { nextWorkdays ?? workdays }
    var hasPending: Bool { nextFrom != nil }

    /// Ask for a new schedule. It starts tomorrow.
    func plan(start: Int, days: Int) {
        if start == startMin && days == workdays {
            nextStartMin = nil; nextWorkdays = nil; nextFrom = nil
        } else {
            nextStartMin = start; nextWorkdays = days
            nextFrom = Board.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        }
        persist()
    }

    /// First-time setup: applies straight away (you're never counted late on the day you set it up).
    func setNow(start: Int, days: Int) {
        startMin = start; workdays = days
        nextStartMin = nil; nextWorkdays = nil; nextFrom = nil
        persist()
    }

    static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return min(max((c.hour ?? 9) * 60 + (c.minute ?? 0), 240), 840) / 5 * 5
    }

    /// The server is the referee once you're on a board.
    func adopt(start: Int, days: Int, nextStart: Int?, nextDays: Int?, from: String?) {
        guard start != startMin || days != workdays || nextStart != nextStartMin || nextDays != nextWorkdays || from != nextFrom else { return }
        startMin = start; workdays = days; nextStartMin = nextStart; nextWorkdays = nextDays; nextFrom = from
        persist()
    }

    func promote() {
        guard let f = nextFrom, f <= Board.day() else { return }
        startMin = nextStartMin ?? startMin
        workdays = nextWorkdays ?? workdays
        nextStartMin = nil; nextWorkdays = nil; nextFrom = nil
        persist()
    }

    private func persist() {
        d.set(startMin, forKey: "officeStart")
        d.set(workdays, forKey: "officeDays")
        d.set(nextStartMin, forKey: "officeNextStart")
        d.set(nextWorkdays, forKey: "officeNextDays")
        d.set(nextFrom, forKey: "officeNextFrom")
    }

    // MARK: Questions

    static func bit(for date: Date) -> Int {
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: date)   // 1 = Sunday
        return (weekday + 5) % 7                                                         // 0 = Monday
    }

    func isWorkday(_ date: Date) -> Bool { workdays & (1 << Self.bit(for: date)) != 0 }

    /// When you're due today, or nil on a day off.
    func due(on date: Date) -> Date? {
        guard isWorkday(date) else { return nil }
        return Calendar.current.startOfDay(for: date).addingTimeInterval(TimeInterval(startMin * 60))
    }

    /// Minutes late right now (0 within the grace period, capped at 2 hours).
    func lateMinutes(now: Date, clockedIn: Bool) -> Int {
        guard !clockedIn, let due = due(on: now) else { return 0 }
        let m = Int(now.timeIntervalSince(due) / 60)
        return m <= Self.grace ? 0 : min(m, 120)
    }

    static func text(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d%@", h12, m, h < 12 ? "am" : "pm")
    }

    static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]
}

/// Closes the front tab in a browser (⌘W to that app only).
enum TabCloser {
    static func closeFrontTab(of app: NSRunningApplication) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true)   // W
        let up = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.postToPid(app.processIdentifier)
        up?.postToPid(app.processIdentifier)
    }
}
