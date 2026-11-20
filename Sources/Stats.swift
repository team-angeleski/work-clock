import Charts
import SwiftUI

/// Everything Stats shows, worked out once from the store.
@MainActor
struct StatsData {
    struct Day: Identifiable { let id: Date; let focus: TimeInterval; let label: String }
    struct Count: Identifiable { let id: String; let n: Int }
    struct Hour: Identifiable { let id: Int; let minutes: Double }
    struct App: Identifiable { let id: String; let name: String; let time: TimeInterval }
    struct BlockDay: Identifiable { var id: String { "\(day.timeIntervalSince1970)\(site)" }; let day: Date; let site: String; let n: Int }
    struct Start: Identifiable { let id: Date; let label: String; let minute: Int }

    var today: TimeInterval = 0, week: TimeInterval = 0, average: TimeInterval = 0
    var best: (Date, TimeInterval)?
    var days: [Day] = []
    var goal: TimeInterval = 0
    var blocksToday = 0, blocksWeek = 0, blocksAll = 0
    var blockDays: [BlockDay] = []
    var drifts: [Count] = []
    var driftsWeek = 0
    var hours: [Hour] = []
    var apps: [App] = []
    var sessions = 0
    var sessionAverage: TimeInterval = 0, sessionLongest: TimeInterval = 0
    var starts: [Start] = []
    var target: Int?
    /// Whole hours around the start times and the target, for the chart's axis.
    var startRange: [Double] {
        let m = starts.map(\.minute) + (target.map { [$0] } ?? [])
        guard let lo = m.min(), let hi = m.max() else { return [8, 10] }
        return [Double(lo / 60), Double(hi / 60 + 1)]
    }

    init(store: Store) {
        let cal = Calendar.current
        let now = store.now
        let today0 = cal.startOfDay(for: now)
        func day(_ back: Int) -> Date { cal.date(byAdding: .day, value: -back, to: today0)! }
        let short = DateFormatter(); short.dateFormat = "EEE d"

        self.today = store.total(on: now)
        goal = store.goal
        days = (0..<14).reversed().map { i in
            let d = day(i)
            return Day(id: d, focus: store.total(on: d), label: i == 0 ? "Today" : short.string(from: d))
        }
        week = (0..<7).reduce(0) { $0 + store.total(on: day($1)) }
        let month = (0..<30).map { (day($0), store.total(on: day($0))) }
        let worked = month.filter { $0.1 >= 300 }
        average = worked.isEmpty ? 0 : worked.reduce(0) { $0 + $1.1 } / Double(worked.count)
        best = month.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0 : nil }

        // Blocks
        let marks = store.marks
        let blocks = marks.filter { $0.kind == .block }
        blocksToday = blocks.filter { $0.at >= today0 }.count
        blocksWeek = blocks.filter { $0.at >= day(6) }.count
        blocksAll = blocks.count
        var bd: [BlockDay] = []
        for i in (0..<14).reversed() {
            let d = day(i), e = cal.date(byAdding: .day, value: 1, to: d)!
            for site in ["youtube.com", "instagram.com"] {
                let n = blocks.filter { $0.site == site && $0.at >= d && $0.at < e }.count
                bd.append(BlockDay(day: d, site: site == "youtube.com" ? "YouTube" : "Instagram", n: n))
            }
        }
        blockDays = bd

        // Drifts during a session
        let drift = marks.filter { $0.kind == .drift && $0.at >= day(6) }
        driftsWeek = drift.count
        drifts = Dictionary(grouping: drift, by: { $0.site ?? "?" })
            .map { Count(id: $0.key, n: $0.value.count) }.sorted { $0.n > $1.n }

        // Local segments: hours of the day, apps, sessions
        let segs = store.allSegments.filter { $0.end > day(29) }
        var byHour = [Double](repeating: 0, count: 24)
        for s in segs {
            var t = max(s.start, day(29))
            while t < s.end {
                let h = cal.component(.hour, from: t)
                let next = min(cal.dateInterval(of: .hour, for: t)!.end, s.end)
                byHour[h] += next.timeIntervalSince(t) / 60
                t = next
            }
        }
        let workedDays = Double(max(worked.count, 1))
        hours = (0..<24).map { Hour(id: $0, minutes: byHour[$0] / workedDays) }

        var byApp: [String: TimeInterval] = [:]
        for s in segs where s.start >= day(6) { byApp[Browser.split(s.app).bundle, default: 0] += s.duration }
        apps = byApp.sorted { $0.value > $1.value }.prefix(6).map { App(id: $0.key, name: store.name($0.key), time: $0.value) }

        // Sessions: focus with breaks under 2 minutes counts as one stretch.
        var stretches: [TimeInterval] = []
        var cur: TimeInterval = 0, lastEnd = Date.distantPast
        for s in segs.filter({ $0.start >= day(6) }) {
            if s.start.timeIntervalSince(lastEnd) > 120, cur > 0 { stretches.append(cur); cur = 0 }
            cur += s.duration; lastEnd = s.end
        }
        if cur > 0 { stretches.append(cur) }
        stretches = stretches.filter { $0 >= 60 }
        sessions = stretches.count
        sessionAverage = stretches.isEmpty ? 0 : stretches.reduce(0, +) / Double(stretches.count)
        sessionLongest = stretches.max() ?? 0

        // When you started each day
        let all = store.allSegments
        starts = (0..<14).reversed().compactMap { i in
            let d = day(i), e = cal.date(byAdding: .day, value: 1, to: d)!
            guard let first = all.first(where: { $0.start >= d && $0.start < e }) else { return nil }
            return Start(id: d, label: i == 0 ? "Today" : short.string(from: d), minute: Office.minutes(from: first.start))
        }
        target = Office.enabled ? store.office.startMin : nil
    }
}

struct StatsView: View {
    let store: Store
    var scrolls = true          // off for snapshots (ImageRenderer can't draw a ScrollView)
    @State private var refresh = 0

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .frame(minWidth: 640, minHeight: 600)
        .id(refresh)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in refresh += 1 }
    }

    private var content: some View {
        let s = StatsData(store: store)
        return VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    tile("Today", long(s.today), .orange)
                    tile("This week", long(s.week), .blue)
                    tile("Daily average", long(s.average), .purple, sub: "days you worked, 30d")
                    tile("Best day", s.best.map { long($0.1) } ?? "–", .green,
                         sub: s.best.map { $0.0.formatted(.dateTime.weekday(.abbreviated).day()) })
                }

                card("Focus, last 14 days", "chart.bar.fill") {
                    Chart {
                        ForEach(s.days) { d in
                            BarMark(x: .value("Day", d.label), y: .value("Hours", d.focus / 3600))
                                .foregroundStyle(d.focus >= s.goal ? Color.green.gradient : Color.orange.gradient)
                                .cornerRadius(4)
                        }
                        RuleMark(y: .value("Goal", s.goal / 3600))
                            .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .top, alignment: .leading) { Text("goal \(long(s.goal))").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .chartYAxisLabel("hours")
                    .frame(height: 170)
                }

                card("Blocked: YouTube and Instagram", "lock.fill") {
                    HStack(spacing: 24) {
                        number(s.blocksToday, "today"); number(s.blocksWeek, "this week"); number(s.blocksAll, "all time")
                    }
                    if s.blocksAll == 0 {
                        Text("Nothing blocked yet. Every time YouTube or Instagram gets closed, it shows up here.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                    Chart(s.blockDays) { b in
                        BarMark(x: .value("Day", b.day, unit: .day), y: .value("Blocks", b.n))
                            .foregroundStyle(by: .value("Site", b.site))
                    }
                    .chartForegroundStyleScale(["YouTube": Color.red, "Instagram": Color.purple])
                    .frame(height: 110)
                    }
                    Text("Each one is a time you reached for it before 1pm or before 2 hours of focus.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                card("Drifted during a session (7 days)", "arrow.uturn.right") {
                    if s.drifts.isEmpty {
                        Text("Not once this week.").foregroundStyle(.secondary)
                    } else {
                        Text("\(s.driftsWeek) times").font(.title3.bold())
                        ForEach(s.drifts) { d in
                            HStack { Text(d.id); Spacer(); Text("\(d.n)×").monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                }

                card("Your best hours (average day, 30 days)", "clock.fill") {
                    Chart(s.hours.filter { $0.id >= 5 }) { h in
                        BarMark(x: .value("Hour", h.id), y: .value("Minutes", h.minutes))
                            .foregroundStyle(Color.blue.gradient)
                    }
                    .chartXAxis { AxisMarks(values: [6, 9, 12, 15, 18, 21]) { v in
                        AxisValueLabel { if let h = v.as(Int.self) { Text(Office.text(h * 60).replacingOccurrences(of: ":00", with: "")) } }
                    } }
                    .chartYAxisLabel("min")
                    .frame(height: 120)
                }

                HStack(alignment: .top, spacing: 14) {
                    card("Where the time went (7 days)", "square.stack.3d.up.fill") {
                        if s.apps.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(s.apps) { a in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(a.name).lineLimit(1); Spacer(); Text(long(a.time)).monospacedDigit().foregroundStyle(.secondary) }
                                GeometryReader { g in
                                    Capsule().fill(.blue.opacity(0.7))
                                        .frame(width: g.size.width * a.time / max(s.apps.first?.time ?? 1, 1))
                                }.frame(height: 5)
                            }
                        }
                    }
                    card("Sessions (7 days)", "timer") {
                        number(s.sessions, "stretches of focus")
                        Text("Average \(long(s.sessionAverage))").foregroundStyle(.secondary)
                        Text("Longest \(long(s.sessionLongest))").foregroundStyle(.secondary)
                    }
                    .frame(width: 190)
                }

                card("When you started", "sunrise.fill") {
                    if s.starts.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    else {
                        Chart {
                            ForEach(s.starts) { st in
                                PointMark(x: .value("Day", st.label), y: .value("Started", -Double(st.minute) / 60))
                                    .foregroundStyle(s.target.map { st.minute <= $0 + 5 ? Color.green : Color.orange } ?? .blue)
                            }
                            if let t = s.target {
                                RuleMark(y: .value("Aim", -Double(t) / 60))
                                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            }
                        }
                        .chartYScale(domain: -s.startRange[1] ... -s.startRange[0])
                        .chartYAxis { AxisMarks(values: .stride(by: max(1, ((s.startRange[1] - s.startRange[0]) / 4).rounded(.up)))) { v in
                            AxisGridLine()
                            AxisValueLabel { if let h = v.as(Double.self) { Text(Office.text(Int(-h * 60)).replacingOccurrences(of: ":00", with: "")) } }
                        } }
                        .frame(height: 130)
                    }
                }
        }
        .padding(22)
    }

    private func tile(_ title: String, _ value: String, _ color: Color, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).foregroundStyle(color.gradient).monospacedDigit()
            Text(sub ?? " ").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
    }

    private func number(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.04)))
    }
}
