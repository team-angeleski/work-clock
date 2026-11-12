import AppKit
import Observation
import ServiceManagement

struct Segment: Codable {
    var start: Date
    var end: Date
    var app: String
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

private struct SaveFile: Codable {
    var segments: [Segment]
    var xp: Double
    var picked: [String]
    var goalHours: Double
    var idlePause: Bool
    var running: Bool? = nil      // was a session running at last save
    var savedAt: Date? = nil
    var sessionXP: Double? = nil
    var dropProgress: Double? = nil
    var drops: [String: Int]? = nil
    var boostUntil: Date? = nil
    var autoGoal: Bool? = nil
    var distractions: [String: Date]? = nil
}

struct DayTotal: Identifiable {
    let id: Date
    let total: TimeInterval
}

enum Mode { case idle, picking, running }

@MainActor @Observable
final class Store {
    // Session state
    private(set) var mode: Mode = .idle
    private(set) var picked: [String] = []        // apps that count, by bundle id
    private(set) var pickingSet: [String] = []
    private(set) var onTask = false
    private(set) var offReason: String?
    private(set) var comboStart: Date?
    private(set) var now = Date()
    private(set) var sessionXP = 0.0

    // Game state
    private(set) var xp = 0.0
    private(set) var flash: String?
    private(set) var levelUpTick = 0
    private(set) var goalTick = 0

    // UI
    var pressed = false
    let office = Office()

    /// Clocked in = the first 5 focused minutes of the day are done.
    var clockedIn: Bool { today >= Office.clockInSeconds }
    @ObservationIgnored weak var board: Board?

    /// Friends' pranks and board events surface here.
    func announce(_ text: String, sound: String?, seconds: Double = 4) {
        if let sound { NSSound(named: sound)?.play() }
        levelUpTick += 1
        show(text, seconds: seconds)
    }

    // Settings
    var goalHours = 4.0 { didSet { save() } }
    var idlePause = true { didSet { save() } }
    var autoGoal = true { didSet { save() } }

    private var segments: [Segment] = []
    private var segStart: Date?
    private var segApp = ""
    private var offSince: Date?
    private var lastSave = Date()
    private var flashTask: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]

    private let idleLimit = 120.0
    private let comboBreak = 15.0
    private let selfID = Bundle.main.bundleIdentifier ?? "WorkClock"
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkClock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }()

    init() {
        load()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2   // lets macOS batch our wakeups with others
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while menus or popovers are open
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app?.bundleIdentifier) }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.mode == .running { self?.stop() } }
        }
    }

    // MARK: Actions

    /// The single pill click: idle → pick apps → focus → stop.
    /// Every start goes through picking; tapping again without picking reuses last time's apps.
    func primaryAction() {
        switch mode {
        case .idle: beginPicking()
        case .picking: start()
        case .running: stop()
        }
    }

    /// Hotkey: skip picking and reuse the last set of apps.
    func quickToggle() {
        switch mode {
        case .running: stop()
        case .picking: start()
        case .idle: picked.isEmpty ? beginPicking() : start()
        }
    }

    /// From the panel: choose different apps for the next session.
    func changeApps() {
        if mode == .running { stop() }
        beginPicking()
    }

    func cancelPicking() {
        guard mode == .picking else { return }
        mode = .idle
        pickingSet = []
        NSApp.hide(nil)
    }

    func removePicked(_ id: String) {
        picked.removeAll { $0 == id }
        pickingSet.removeAll { $0 == id }
        save()
    }

    private func beginPicking() {
        pickingSet = []
        mode = .picking
        // Take focus so that the first click on any window registers as a pick.
        flash = nil
        NSApp.activate()
    }

    private func start() {
        if !pickingSet.isEmpty { picked = pickingSet }
        guard !picked.isEmpty else { show("Click an app first"); return }
        pickingSet = []
        mode = .running
        sessionXP = 0
        comboStart = nil
        offSince = nil
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == selfID { NSApp.hide(nil) }
        NSSound(named: "Pop")?.play()
        board?.nudge()
        save()
        tick()
    }

    private func stop() {
        if onTask { close(at: Date()) }
        mode = .idle
        comboStart = nil
        let earned = Int(sessionXP.rounded())
        if earned > 0 { show("+\(earned) XP", seconds: 4) }
        NSSound(named: "Bottle")?.play()
        save()
        board?.nudge()
    }

    private func appActivated(_ id: String?) { pickFront() }

    /// While picking, add whatever is in front: an app, or the site in a browser's active tab.
    private func pickFront() {
        guard mode == .picking,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, front != selfID else { return }
        var key = front
        if Browser.isBrowser(front), let domain = Browser.domain(of: front) {
            guard !domain.isEmpty else { return }   // new tab or settings page: wait for a real site
            key = "\(front)|\(domain)"
        }
        guard !pickingSet.contains(key), pickingSet.count < 8 else { return }
        pickingSet.append(key)
        NSSound(named: "Tink")?.play()
        show("+ \(name(key))", seconds: 2)
    }

    // MARK: Clock

    private func tick() {
        // While stopped nothing on screen moves, so only refresh once a minute (for the pace face).
        let t = Date()
        if mode != .idle || t.timeIntervalSince(now) >= 60 { now = t }
        defer { if now.timeIntervalSince(lastSave) > 30 { save() } }
        if mode == .picking { pickFront() }
        watchDistractions()
        guard mode == .running else { return }

        // Split at midnight so each day gets its own time.
        if let s = segStart, !Calendar.current.isDate(s, inSameDayAs: now) {
            close(at: Calendar.current.startOfDay(for: now))
            begin(segApp, at: Calendar.current.startOfDay(for: now))
        }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        // On a board the rules are stricter and can't be switched off: idle pause is always on, and
        // there must be a key press, click or scroll every 10 minutes (mouse-jiggler apps only move).
        let strict = board?.joined == true
        let handsIdle = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel))
        let idleAway = (idlePause || strict) && idle > idleLimit
        let jiggleAway = strict && handsIdle > 600
        let away = idleAway || jiggleAway
        let awayFor = idleAway ? idle : handsIdle
        let isSelf = front == selfID   // our own popover keeps whatever state we were in

        // In a browser, the site decides. Only ask the browser if something of it was picked.
        var key = front
        var distraction: String?
        if Browser.isBrowser(front), picked.contains(where: { Browser.split($0).bundle == front }),
           let domain = Browser.domain(of: front), !domain.isEmpty {
            key = "\(front)|\(domain)"
            if Browser.isDistraction(domain) { distraction = domain; noteDistraction() }
        }
        let matches = picked.contains(key) || (picked.contains(front) && distraction == nil)
        let working = !away && (matches || (isSelf && onTask))
        offReason = away ? "Away" : distraction

        if working {
            if !onTask { begin(key, at: now) }
            else if !isSelf && key != segApp { close(at: now); begin(key, at: now) }
            offSince = nil
            if comboStart == nil { comboStart = now }
            award(multiplier / 60)
        } else {
            if onTask {
                if away {
                    // Hand back the idle stretch: it was not real work.
                    close(at: max(segStart ?? now, now.addingTimeInterval(-awayFor)))
                    award(-min(awayFor, 601) / 60 * multiplier)
                    comboStart = nil
                } else {
                    close(at: now)
                }
                offSince = now
            }
            if let o = offSince, now.timeIntervalSince(o) > comboBreak, let c = comboStart {
                let minutes = o.timeIntervalSince(c) / 60
                if minutes >= 10 {
                    NSSound(named: "Basso")?.play()
                    show("Combo lost (×\(minutes >= 25 ? 3 : 2))", seconds: 4)
                }
                comboStart = nil
            }
        }
    }

    private func begin(_ app: String, at date: Date) {
        segStart = date
        segApp = app
        onTask = true
    }

    private func close(at end: Date) {
        guard let s = segStart else { return }
        if end.timeIntervalSince(s) >= 1 { segments.append(Segment(start: s, end: end, app: segApp)); dayCache = [:] }
        segStart = nil
        onTask = false
    }

    private func award(_ amount: Double) {
        let levelBefore = level
        let goalBefore = goalMet
        let tierBefore = Self.tier(todayPercentile)
        xp = max(0, xp + amount)
        sessionXP = max(0, sessionXP + amount)
        if level > levelBefore {
            levelUpTick += 1
            NSSound(named: "Glass")?.play()
            show("Level \(level)!", seconds: 4)
        }
        let tierNow = Self.tier(todayPercentile)
        if amount > 0, tierNow != tierBefore, todayPercentile >= 40 {
            levelUpTick += 1
            NSSound(named: "Glass")?.play()
            show("You're now \(tierNow)", seconds: 5)
        }
        if goalMet && !goalBefore {
            goalTick += 1
            NSSound(named: "Hero")?.play()
            show("Goal reached", seconds: 5)
        }
    }

    private func show(_ text: String, seconds: Double = 3) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    // MARK: Derived

    /// Flow multiplier: stay on task and it climbs.
    var multiplier: Double {
        guard let c = comboStart, onTask else { return 1 }
        let m = now.timeIntervalSince(c) / 60
        return m >= 25 ? 3 : m >= 10 ? 2 : 1
    }

    var comboMinutes: Int {
        guard let c = comboStart else { return 0 }
        return Int(now.timeIntervalSince(c) / 60)
    }

    /// XP needed to go from level n to n+1.
    private func cost(_ n: Int) -> Double { 60 + 30 * Double(n - 1) }

    var level: Int {
        var n = 1, left = xp
        while left >= cost(n) { left -= cost(n); n += 1 }
        return n
    }

    var levelProgress: Double {
        var n = 1, left = xp
        while left >= cost(n) { left -= cost(n); n += 1 }
        return left / cost(n)
    }

    var xpToNext: Int {
        var n = 1, left = xp
        while left >= cost(n) { left -= cost(n); n += 1 }
        return Int((cost(n) - left).rounded(.up))
    }

    /// Closed-session totals per day. Only changes when a session closes, so cache it.
    @ObservationIgnored private var dayCache: [Date: TimeInterval] = [:]

    func total(on day: Date) -> TimeInterval {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let closed: TimeInterval
        if let cached = dayCache[start] {
            closed = cached
        } else {
            closed = segments.reduce(0) { $1.start >= start && $1.start < end ? $0 + $1.duration : $0 }
            dayCache[start] = closed
        }
        guard let s = segStart, s >= start, s < end else { return closed }
        return closed + now.timeIntervalSince(s)
    }

    var today: TimeInterval { total(on: now) }

    // MARK: Score: focus time plus bonuses (what the friend board ranks on)
    // Early bird: focus before 9am counts 1.5x. Clean morning: no distraction sites before 1pm
    // and at least an hour of focus by then earns a flat 30 minutes.

    static let earlyHour = 9, cleanHour = 13
    static let cleanBonus: TimeInterval = 1800

    /// First time a distraction site was in front, per day.
    private(set) var distractions: [String: Date] = [:]
    @ObservationIgnored private var lastDistractionCheck = Date.distantPast
    @ObservationIgnored private var cleanAnnounced = ""

    var todayScore: TimeInterval { score(on: now) }
    /// Score per focused second right now.
    var scoreRate: Double { Calendar.current.component(.hour, from: now) < Self.earlyHour ? 1.5 : 1 }
    var earlyBird: Bool { scoreRate > 1 }

    func score(on day: Date) -> TimeInterval {
        total(on: day) + 0.5 * focused(on: day, before: Self.earlyHour) + (cleanMorning(on: day) ? Self.cleanBonus : 0)
    }

    func earlyBonus(on day: Date) -> TimeInterval { 0.5 * focused(on: day, before: Self.earlyHour) }

    /// Focused seconds on a day before a given hour.
    func focused(on day: Date, before hour: Int) -> TimeInterval {
        let start = Calendar.current.startOfDay(for: day)
        let cutoff = start.addingTimeInterval(TimeInterval(hour) * 3600)
        var t = segments.reduce(0.0) { sum, s in
            guard s.start >= start, s.start < cutoff else { return sum }
            return sum + max(0, min(s.end, cutoff).timeIntervalSince(s.start))
        }
        if let s = segStart, s >= start, s < cutoff { t += max(0, min(now, cutoff).timeIntervalSince(s)) }
        return t
    }

    /// When the first distraction happened on a day, if any.
    func firstDistraction(on day: Date) -> Date? { distractions[Board.day(day)] }

    /// nil while it's still before 1pm today; then whether the bonus was earned.
    func cleanMorning(on day: Date) -> Bool {
        let start = Calendar.current.startOfDay(for: day)
        let cutoff = start.addingTimeInterval(TimeInterval(Self.cleanHour) * 3600)
        guard now >= cutoff else { return false }
        if let first = distractions[Board.day(day)], first < cutoff { return false }
        return focused(on: day, before: Self.cleanHour) >= 3600
    }

    /// Clean-morning status for display: still on track, earned, or blown.
    var cleanMorningStatus: String {
        let start = Calendar.current.startOfDay(for: now)
        let cutoff = start.addingTimeInterval(TimeInterval(Self.cleanHour) * 3600)
        if let first = distractions[Board.day(now)], first < cutoff {
            return "Blown at \(first.formatted(date: .omitted, time: .shortened))"
        }
        if now >= cutoff { return cleanMorning(on: now) ? "Earned +30m" : "Missed (needed 1h by 1pm)" }
        let need = max(0, 3600 - focused(on: now, before: Self.cleanHour))
        return need > 0 ? "On track · \(Int(need / 60))m more by 1pm" : "On track · stay off socials till 1pm"
    }

    /// Checks the front browser tab every few seconds, whether or not the clock is running.
    private func watchDistractions() {
        let t = Date()
        guard t.timeIntervalSince(lastDistractionCheck) >= 5 else { return }
        lastDistractionCheck = t
        office.promote()
        if Calendar.current.component(.hour, from: t) >= Self.cleanHour {
            let today = Board.day(t)
            if cleanAnnounced != today && cleanMorning(on: t) {
                cleanAnnounced = today
                announce("Clean morning bonus +30m", sound: "Hero", seconds: 6)
            }
            return
        }
        guard distractions[Board.day(t)] == nil,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              Browser.isBrowser(front), let domain = Browser.domain(of: front),
              !domain.isEmpty, Browser.isDistraction(domain) else { return }
        noteDistraction()
    }

    fileprivate func noteDistraction() {
        let key = Board.day(now)
        guard distractions[key] == nil, Calendar.current.component(.hour, from: now) < Self.cleanHour else { return }
        distractions[key] = Date()
        announce("Clean morning blown", sound: "Basso", seconds: 4)
        save()
    }

    // MARK: How you compare
    // A rough log-normal curve fitted to published figures: the average knowledge worker logs
    // about 1h 51m of focus work a day (RescueTime), 2h 48m of "productive" screen time is
    // roughly the top quarter, and ~4h is the daily ceiling for elite performers (Ericsson).

    private static let medianMinutes = 110.0
    private static let spread = 0.6

    /// 0–100: share of workers who focus less than this in a whole day.
    static func percentile(_ t: TimeInterval) -> Double {
        guard t >= 60 else { return 0 }
        let z = log(t / 60 / medianMinutes) / spread
        return 0.5 * (1 + erf(z / 2.0.squareRoot())) * 100
    }

    /// "Top 12%" or "Bottom 30%".
    static func rank(_ p: Double) -> String {
        p >= 50 ? "Top \(max(1, Int((100 - p).rounded(.up))))%" : "Bottom \(max(1, Int(p.rounded(.up))))%"
    }

    static func tier(_ p: Double) -> String {
        switch p {
        case ..<10: "Slacking"
        case ..<40: "Below average"
        case ..<60: "Average"
        case ..<80: "Above average"
        case ..<95: "Grinder"
        case ..<99: "Elite"
        default: "Monk mode"
        }
    }

    var todayPercentile: Double { Self.percentile(today) }

    /// Your average over the days you actually worked in the last week.
    var typicalDay: TimeInterval {
        let worked = week.filter { $0.total >= 60 }
        return worked.isEmpty ? 0 : worked.reduce(0) { $0 + $1.total } / Double(worked.count)
    }

    /// Time needed today to reach the next tier.
    var nextTier: (name: String, needed: TimeInterval)? {
        let cutoffs: [(Double, String)] = [(40, "Average"), (60, "Above average"), (80, "Grinder"), (95, "Elite"), (99, "Monk mode")]
        guard let next = cutoffs.first(where: { $0.0 > todayPercentile }) else { return nil }
        // Invert the curve for that percentile.
        let z = inverseNormal(next.0 / 100)
        let minutes = Self.medianMinutes * exp(z * Self.spread)
        return (next.1, max(minutes * 60 - today, 0))
    }

    func inverseNormal(_ p: Double) -> Double {
        var lo = -6.0, hi = 6.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if 0.5 * (1 + erf(mid / 2.0.squareRoot())) < p { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Share of the goal you should have by now, spreading it over a 9am to 5pm day.
    var expectedProgress: Double {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        return min(max(now.timeIntervalSince(start) / (8 * 3600), 0), 1)
    }

    /// Minutes ahead (+) or behind (-) pace.
    var paceMinutes: Int { Int((progress - expectedProgress) * goal / 60) }

    /// -1 (sad) … 1 (beaming), drives the face.
    var mood: Double {
        if mode == .running && !onTask {
            let off = offSince.map { now.timeIntervalSince($0) } ?? 0
            return off > 60 ? -1 : -0.6
        }
        if goalMet { return 1 }
        if mode == .running { return multiplier >= 3 ? 1 : multiplier >= 2 ? 0.75 : 0.5 }
        let delta = progress - expectedProgress
        return delta >= 0 ? 0.4 : delta > -0.15 ? 0 : -0.6
    }
    var goal: TimeInterval { autoGoal ? adaptiveGoal : goalHours * 3600 }

    /// Your recent average (before today) plus 15 minutes: always a stretch, never out of reach.
    var adaptiveGoal: TimeInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let past = (1...7).map { total(on: cal.date(byAdding: .day, value: -$0, to: start)!) }.filter { $0 >= 300 }
        let base = past.isEmpty ? 2700 : past.reduce(0, +) / Double(past.count)
        let target = min(max(base + 900, 1800), 5 * 3600)
        return (target / 900).rounded() * 900
    }

    /// Tomorrow's adaptive goal: the last 7 days including today, plus 15 minutes.
    var adaptiveGoalTomorrow: TimeInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let days = (0..<7).map { total(on: cal.date(byAdding: .day, value: -$0, to: start)!) }.filter { $0 >= 300 }
        let base = days.isEmpty ? 2700 : days.reduce(0, +) / Double(days.count)
        return (min(max(base + 900, 1800), 5 * 3600) / 900).rounded() * 900
    }

    /// Minutes a day for the Elite tier (95th percentile).
    var eliteMinutes: Double { Self.medianMinutes * exp(inverseNormal(0.95) * Self.spread) }

    /// Days to reach Elite if you add 15 minutes to your typical day, every day.
    var daysToElite: Int? {
        let base = max(typicalDay, today) / 60
        guard base < eliteMinutes else { return nil }
        return Int(((eliteMinutes - base) / 15).rounded(.up))
    }
    var progress: Double { goal > 0 ? today / goal : 0 }
    var goalMet: Bool { today >= goal }

    var week: [DayTotal] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        return (0..<7).reversed().map { i in
            let d = cal.date(byAdding: .day, value: -i, to: start)!
            return DayTotal(id: d, total: total(on: d))
        }
    }

    /// Consecutive days that hit the goal. Today counts once it is hit.
    var streak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: now)
        if total(on: day) < goal { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while total(on: day) >= goal, n < 3650 {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    var todaySegmentsByApp: [(app: String, time: TimeInterval)] {
        let cal = Calendar.current
        var map: [String: TimeInterval] = [:]
        for s in segments where cal.isDate(s.start, inSameDayAs: now) { map[s.app, default: 0] += s.duration }
        if let s = segStart { map[segApp, default: 0] += now.timeIntervalSince(s) }
        return map.map { ($0.key, $0.value) }.sorted { $0.time > $1.time }
    }

    var shownApps: [String] { mode == .picking ? pickingSet : picked }

    func icon(_ key: String) -> NSImage {
        let id = Browser.split(key).bundle
        if let i = icons[id] { return i }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let i = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        icons[id] = i
        return i
    }

    func name(_ key: String) -> String {
        let (id, domain) = Browser.split(key)
        if let domain { return domain }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    // MARK: Persistence

    @ObservationIgnored private var loading = false

    func save() {
        guard !loading else { return }   // never write a half-loaded state
        lastSave = Date()
        var all = segments
        if let s = segStart { all.append(Segment(start: s, end: Date(), app: segApp)) }
        let data = SaveFile(segments: all, xp: xp, picked: picked, goalHours: goalHours, idlePause: idlePause,
                            running: mode == .running, savedAt: Date(), sessionXP: sessionXP,
                            autoGoal: autoGoal,
                            distractions: distractions)
        if let json = try? JSONEncoder().encode(data) { try? json.write(to: file, options: .atomic) }
    }

    private func load() {
        guard let json = try? Data(contentsOf: file),
              let data = try? JSONDecoder().decode(SaveFile.self, from: json) else { return }
        loading = true
        defer { loading = false }
        segments = data.segments
        dayCache = [:]
        xp = data.xp
        picked = data.picked
        goalHours = data.goalHours
        idlePause = data.idlePause
        autoGoal = data.autoGoal ?? true
        distractions = (data.distractions ?? [:]).filter { Date().timeIntervalSince($0.value) < 14 * 86400 }
        // Restarted mid-session (an update, a crash): carry on instead of stopping.
        if data.running == true, let at = data.savedAt, Date().timeIntervalSince(at) < 300, !picked.isEmpty {
            mode = .running
            sessionXP = data.sessionXP ?? 0
        }
    }
}
