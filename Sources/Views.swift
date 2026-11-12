import SwiftUI

private let flowGradient = AngularGradient(colors: [.orange, .pink, .orange], center: .center)
private let goalGradient = AngularGradient(colors: [.mint, .green, .mint], center: .center)

/// Live clock: 4:07, 52:30, 1:02:45
func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Readable duration: 45m, 2h 10m
func long(_ t: TimeInterval) -> String {
    if t > 0 && t < 60 { return "\(Int(t))s" }
    let m = Int(t) / 60
    if m >= 60 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
    return "\(m)m"
}

// MARK: Pill next to the Dock (drawn over a blurred AppKit backing)

struct PillView: View {
    let store: Store
    let board: Board
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let shape = RoundedRectangle(cornerRadius: (h * 0.3).rounded(), style: .circular)
            HStack(spacing: h * 0.16) {
                leading(h)
                    .frame(width: h * 0.52, height: h * 0.52)
                VStack(alignment: .center, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(title)
                            .font(.system(size: h * 0.29, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(titleStyle)
                        if board.leading {
                            Image(systemName: "crown.fill")
                                .font(.system(size: h * 0.15, weight: .bold))
                                .foregroundStyle(.yellow)
                        }
                        if store.multiplier > 1 {
                            Text("×\(Int(store.multiplier))")
                                .font(.system(size: h * 0.16, weight: .heavy, design: .rounded))
                                .foregroundStyle(.orange)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: h * 0.165, weight: .medium))
                        .foregroundStyle(subtitleStyle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                // Fixed-width, centred column: changing text never moves the buddy,
                // and the whole block stays balanced in the pill.
                .frame(width: geo.size.width - h * 0.52 - h * 0.16 - h * 0.36, alignment: .center)
            }
            .frame(width: geo.size.width, height: h, alignment: .center)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.13 : 0.45), lineWidth: 1))
            .animation(.smooth(duration: 0.3), value: store.mode)
            .animation(.smooth, value: store.onTask)
            .animation(.smooth, value: store.multiplier)
            .animation(.smooth, value: store.flash)
            .animation(.easeOut(duration: 0.12), value: store.pressed)
            .keyframeAnimator(initialValue: 1.0, trigger: store.levelUpTick + store.goalTick) { view, s in
                view.scaleEffect(s)
            } keyframes: { _ in
                SpringKeyframe(1.06, duration: 0.18)
                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
            }
        }
        .allowsHitTesting(false)
    }

    private var fill: Color {
        let base = scheme == .dark ? Color.black.opacity(0.42) : Color.white.opacity(0.25)
        return store.pressed ? (scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)) : base
    }

    @ViewBuilder private func leading(_ h: CGFloat) -> some View {
        if store.mode == .picking {
            PickedIcons(store: store, size: h * 0.42)
        } else {
            Ring(progress: store.progress,
                 active: store.mode == .running && store.onTask,
                 done: store.goalMet,
                 offTask: store.mode == .running && !store.onTask,
                 mood: store.mood,
                 blink: store.mode == .running && store.onTask ? Int(store.now.timeIntervalSince1970) / 4 : 0,
                 size: h * 0.52)
        }
    }

    private var title: String {
        store.mode == .picking ? (store.pickingSet.isEmpty ? "Pick apps" : "Ready") : clock(store.today)
    }

    private var titleStyle: AnyShapeStyle {
        store.mode == .running && store.onTask || store.mode == .picking ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var subtitle: String {
        if let f = store.flash { return f }
        switch store.mode {
        case .idle:
            if let office = officeLine { return office }
            let minute = Int(store.now.timeIntervalSince1970) / 60
            if let race = board.raceLine, minute % 2 == 0 { return race }
            if minute % 2 == 1, let next = store.nextTier {
                return "\(long(next.needed)) to \(next.name)"
            }
            return store.picked.isEmpty ? "Tap to focus" : Store.rank(store.todayPercentile)
        case .picking:
            if !store.pickingSet.isEmpty { return "Tap to start" }
            return store.picked.isEmpty ? "Click your apps" : "Pick, or tap for same"
        case .running:
            if !store.onTask { return store.offReason.map { "Off task · \($0)" } ?? "Off task" }
            // Take turns every 4s: the race, then flow or early bird.
            if let race = board.raceLine, (Int(store.now.timeIntervalSince1970) / 4) % 2 == 1 { return race }
            if store.earlyBird { return "Early bird ×1.5" }
            return store.comboMinutes > 0 ? "In flow \(store.comboMinutes)m" : "Focusing"
        }
    }

    /// "Clock in by 9:00am" in the hour before, "Late 12m · clock in" after.
    private var officeLine: String? {
        guard let due = store.office.due(on: store.now), !store.clockedIn else { return nil }
        let late = store.office.lateMinutes(now: store.now, clockedIn: false)
        if late > 0 { return "Late \(late)m · clock in" }
        let toGo = due.timeIntervalSince(store.now)
        return toGo > 0 && toGo <= 3600 ? "Clock in by \(Office.text(store.office.startMin))" : nil
    }

    private var subtitleStyle: AnyShapeStyle {
        if store.flash != nil { return AnyShapeStyle(.orange) }
        if store.mode == .idle && store.office.lateMinutes(now: store.now, clockedIn: store.clockedIn) > 0 { return AnyShapeStyle(.red) }
        if store.mode == .idle && store.todayPercentile < 40 { return AnyShapeStyle(.red.opacity(0.85)) }
        if store.mode == .running && !store.onTask { return AnyShapeStyle(.red.opacity(0.9)) }
        return AnyShapeStyle(.secondary)
    }
}

struct Ring: View {
    var progress: Double
    var active: Bool
    var done: Bool
    var offTask: Bool
    var mood: Double
    var blink: Int
    var dunce = false
    var size: CGFloat

    var body: some View {
        let line = size * 0.12
        let tint: Color = offTask ? .red : done ? .green : active ? .orange : .secondary
        ZStack {
            Circle().stroke(.primary.opacity(0.13), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.002, min(progress, 1)))
                .stroke(active ? AnyShapeStyle(done ? goalGradient : flowGradient)
                               : AnyShapeStyle(offTask ? Color.red.opacity(0.7) : Color.secondary.opacity(0.7)),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Equatable: only redraws when the expression, blink or colour actually changes.
            EquatableView(content: Face(mood: (mood * 20).rounded() / 20, blink: blink,
                                        tint: offTask ? .red : done ? .green : active ? .orange : .gray,
                                        dunce: dunce))
                .frame(width: size * 0.7, height: size * 0.7)
        }
        .padding(line / 2)
    }
}

/// Focus buddy: a soft round face tinted by status, with shiny eyes, blush and a tiny mouth.
struct Face: View, Equatable {
    var mood: Double      // -1 sad … 1 delighted
    var blink: Int
    var tint: Color
    var dunce = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let ink = Color(white: 0.12)
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.55), tint.mix(with: .white, by: 0.25)],
                                         startPoint: .top, endPoint: .bottom))
                // Blush
                HStack(spacing: w * 0.42) {
                    Ellipse().frame(width: w * 0.17, height: w * 0.1)
                    Ellipse().frame(width: w * 0.17, height: w * 0.1)
                }
                .foregroundStyle(Color.pink.opacity(0.75 * max(mood, 0)))
                .offset(y: w * 0.1)
                // Eyes
                Group {
                    if mood > 0.85 {
                        HStack(spacing: w * 0.2) {
                            HappyEye().stroke(ink, style: StrokeStyle(lineWidth: w * 0.07, lineCap: .round))
                                .frame(width: w * 0.17, height: w * 0.09)
                            HappyEye().stroke(ink, style: StrokeStyle(lineWidth: w * 0.07, lineCap: .round))
                                .frame(width: w * 0.17, height: w * 0.09)
                        }
                    } else {
                        HStack(spacing: w * 0.22) {
                            eye(w, ink)
                            eye(w, ink)
                        }
                        .keyframeAnimator(initialValue: 1.0, trigger: blink) { view, s in
                            view.scaleEffect(x: 1, y: s)
                        } keyframes: { _ in
                            CubicKeyframe(0.1, duration: 0.07)
                            CubicKeyframe(1, duration: 0.12)
                        }
                    }
                }
                .offset(y: -w * 0.06 + (mood < 0 ? w * 0.03 : 0))
                if dunce {
                    DunceCap()
                        .fill(LinearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
                        .overlay(DunceCap().stroke(.white.opacity(0.6), lineWidth: max(0.5, w * 0.03)))
                        .frame(width: w * 0.5, height: w * 0.62)
                        .overlay(alignment: .top) { Circle().fill(.yellow).frame(width: w * 0.16).offset(y: -w * 0.06) }
                        .rotationEffect(.degrees(14))
                        .offset(x: w * 0.12, y: -w * 0.62)
                }
                // Mouth
                Mouth(smile: mood)
                    .stroke(ink, style: StrokeStyle(lineWidth: w * 0.065, lineCap: .round))
                    .frame(width: w * 0.2, height: w * 0.1)
                    .offset(y: w * 0.17)
            }
            .frame(width: w, height: g.size.height)
        }
        .animation(.spring(duration: 0.6, bounce: 0.4), value: mood)
    }

    private func eye(_ w: CGFloat, _ ink: Color) -> some View {
        Ellipse()
            .fill(ink)
            .frame(width: w * 0.14, height: w * (mood < 0 ? 0.15 : 0.19))
            .overlay(alignment: .topTrailing) {
                Circle().fill(.white).frame(width: w * 0.055).offset(x: -w * 0.012, y: w * 0.025)
            }
    }
}

struct DunceCap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.12))
        p.closeSubpath()
        return p
    }
}

/// ^ shaped closed eye for the happiest moments.
struct HappyEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        return p
    }
}

struct Mouth: Shape {
    var smile: Double   // -1 frown … 1 grin
    var animatableData: Double {
        get { smile }
        set { smile = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let bend = r.height * smile
        p.move(to: CGPoint(x: r.minX, y: r.midY - bend / 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY - bend / 2),
                       control: CGPoint(x: r.midX, y: r.midY + bend * 1.2))
        return p
    }
}

struct PickedIcons: View {
    let store: Store
    var size: CGFloat

    var body: some View {
        // Nothing picked yet: show last time's apps faded, since tapping again reuses them.
        let ghost = store.pickingSet.isEmpty && !store.picked.isEmpty
        let apps = Array((ghost ? store.picked : store.pickingSet).suffix(3))
        ZStack {
            if apps.isEmpty {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: size * 0.75, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            }
            ForEach(Array(apps.enumerated()), id: \.element) { i, id in
                let shift = CGFloat(i) - CGFloat(apps.count - 1) / 2
                Image(nsImage: store.icon(id))
                    .resizable()
                    .frame(width: size, height: size)
                    .offset(x: shift * size * 0.38)
                    .opacity(ghost ? 0.4 : 1)
                    .saturation(ghost ? 0 : 1)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .animation(.bouncy, value: store.pickingSet)
    }
}

// MARK: Today's goal bar with mood

struct TodayBar: View {
    let store: Store

    var body: some View {
        let tint: Color = store.goalMet ? .green : store.mood < 0 ? .red : .orange
        HStack(spacing: 12) {
            Face(mood: store.mood, blink: 0, tint: tint)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Today").font(.headline)
                    Spacer()
                    Text("\(long(store.today)) / \(long(store.goal))")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.08))
                        Capsule()
                            .fill(store.goalMet ? AnyShapeStyle(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing))
                                                : AnyShapeStyle(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)))
                            .frame(width: max(8, g.size.width * min(store.progress, 1)))
                        // Where you should be by now
                        if !store.goalMet && store.expectedProgress > 0 {
                            Capsule()
                                .fill(.primary.opacity(0.6))
                                .frame(width: 2, height: 12)
                                .offset(x: g.size.width * store.expectedProgress - 1)
                        }
                    }
                }
                .frame(height: 8)
                Text(paceText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var paceText: String {
        if store.goalMet { return "Goal smashed. Anything more is bonus XP." }
        let left = long(max(store.goal - store.today, 0))
        let pace = store.paceMinutes
        if pace >= 0 { return "\(left) to go · \(long(Double(pace) * 60)) ahead of pace" }
        return "\(left) to go · \(long(Double(-pace) * 60)) behind pace"
    }
}

// MARK: How you compare

struct CompareCard: View {
    let store: Store

    var body: some View {
        let today = store.todayPercentile
        let typical = Store.percentile(store.typicalDay)
        VStack(alignment: .leading, spacing: 10) {
            // Lead with the next rung: it is always close.
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Next rung").font(.caption).foregroundStyle(.secondary)
                    Text(store.nextTier?.name ?? "Monk mode")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .foregroundStyle(.orange.gradient)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(store.nextTier.map { long($0.needed) } ?? "Top 1%")
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                    Text(store.nextTier == nil ? "you made it" : "more focus today")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.red, .orange, .yellow, .green, .mint],
                                             startPoint: .leading, endPoint: .trailing))
                        .opacity(0.85)
                        .frame(height: 8)
                    // Tier rungs
                    ForEach([40.0, 60, 80, 95], id: \.self) { rung in
                        Rectangle().fill(.black.opacity(0.45)).frame(width: 2, height: 8).offset(x: w * rung / 100 - 1)
                    }
                    if store.typicalDay > 0 {
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .offset(x: w * typical / 100 - 4, y: 12)
                    }
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(color(today), lineWidth: 3))
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, min(w - 14, w * today / 100 - 7)))
                        .shadow(radius: 2)
                }
                .frame(height: 14)
            }
            .frame(height: 22)
            HStack {
                Text("Slacking"); Spacer(); Text("Average"); Spacer(); Text("Grinder"); Spacer(); Text("Elite")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Today: **\(Store.rank(today)) · \(Store.tier(today))**")
                if store.typicalDay > 0 {
                    Text("Typical day (\(long(store.typicalDay))): \(Store.rank(typical)) · \(Store.tier(typical))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let days = store.daysToElite {
                Label {
                    Text("Road to Elite: add 15m a day and you're there in **\(days) days**")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
    }

    private func color(_ p: Double) -> Color {
        p < 20 ? .red : p < 40 ? .orange : p < 60 ? .yellow : .green
    }
}

// MARK: Week glance (hover)

struct WeekPeek: View {
    let store: Store
    let board: Board

    var body: some View {
        let days = store.week
        let total = days.reduce(0) { $0 + $1.total }
        let best = days.max { $0.total < $1.total }
        let hits = days.filter { $0.total >= store.goal }.count
        VStack(alignment: .leading, spacing: 14) {
            TodayBar(store: store)
            if board.joined && board.friends.count > 1 {
                Divider()
                FriendsMini(board: board)
            }
            Divider()
            CompareCard(store: store)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days").font(.headline)
                Spacer()
                Text(long(total))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            WeekBars(store: store, height: 78, showValues: true)
            HStack {
                stat("Daily avg", long(total / 7))
                Spacer()
                stat("Best day", best.map { $0.total > 0 ? $0.id.formatted(.dateTime.weekday(.abbreviated)) : "–" } ?? "–")
                Spacer()
                stat("Goals hit", "\(hits)/7")
                Spacer()
                stat("Streak", "\(store.streak)d")
            }
            Text("Ranks are a rough estimate from RescueTime focus data and Ericsson's research on elite performers. Right-click for settings.")
                .fixedSize(horizontal: false, vertical: true)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct WeekBars: View {
    let store: Store
    var height: CGFloat = 56
    var showValues = false

    var body: some View {
        let days = store.week
        let cal = Calendar.current
        let top = max(store.goal, days.map(\.total).max() ?? 0, 1)
        let goalY = height * store.goal / top
        ZStack(alignment: .bottom) {
            // Goal line
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay(Line().stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .padding(.bottom, goalY + (showValues ? 0 : 0) + 18)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days) { day in
                    let hit = day.total >= store.goal
                    let isToday = cal.isDateInToday(day.id)
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.primary.opacity(0.06))
                            Capsule()
                                .fill(hit ? AnyShapeStyle(LinearGradient(colors: [.green, .mint], startPoint: .bottom, endPoint: .top))
                                          : AnyShapeStyle(LinearGradient(colors: [.orange, .pink], startPoint: .bottom, endPoint: .top)))
                                .frame(height: day.total > 0 ? max(5, height * day.total / top) : 0)
                        }
                        .frame(width: 16, height: height)
                        .overlay(alignment: .top) {
                            if showValues && day.total >= 60 {
                                Text(String(format: "%.1f", day.total / 3600))
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .offset(y: max(-12, height - height * day.total / top - 13))
                            }
                        }
                        Text(day.id.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? .primary : .secondary)
                            .frame(height: 14)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, showValues ? 12 : 0)
    }
}

private struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

// MARK: Full panel (right-click)

struct DetailView: View {
    @Bindable var store: Store
    let board: Board
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let v = updater.available {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("Work Clock \(v) is out").font(.callout.weight(.semibold))
                    Spacer()
                    Button(updater.updating ? "Updating…" : "Update") { updater.install() }
                        .controlSize(.small)
                        .disabled(updater.updating)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.12)))
            }
            TodayBar(store: store)
            OfficeStatus(store: store)
            FriendsSection(board: board, store: store)
            CompareCard(store: store)
            levelBar
            VStack(alignment: .leading, spacing: 8) {
                Text("Last 7 days").font(.caption).foregroundStyle(.secondary)
                WeekBars(store: store, height: 56, showValues: true)
            }
            if !store.todaySegmentsByApp.isEmpty || !store.picked.isEmpty { apps }
            Divider()
            HStack {
                Text("⌃⌥F to start or stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.mode == .picking {
                    Button("Cancel") { store.cancelPicking() }.controlSize(.small)
                }
                Button("Settings…") { AppWindows.shared?.showSettings() }.controlSize(.small)
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 310)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Focused today").font(.subheadline).foregroundStyle(.secondary)
                Text(clock(store.today))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(Int(min(store.progress, 9.99) * 100))% of \(long(store.goal)) goal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label("\(store.streak)", systemImage: "flame.fill")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(store.streak > 0 ? AnyShapeStyle(.orange.gradient) : AnyShapeStyle(.tertiary))
                Text("day streak").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var levelBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Level \(store.level)").font(.system(.headline, design: .rounded))
                Spacer()
                Text("\(store.xpToNext) XP to next").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, g.size.width * store.levelProgress))
                }
            }
            .frame(height: 6)
            Text("1 XP per focused minute. Stay in flow: ×2 after 10m, ×3 after 25m.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Counted apps · today").font(.caption).foregroundStyle(.secondary)
            let times = Dictionary(store.todaySegmentsByApp.map { ($0.app, $0.time) }, uniquingKeysWith: +)
            let ids = store.picked + times.keys.filter { !store.picked.contains($0) }.sorted()
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 8) {
                    Image(nsImage: store.icon(id)).resizable().frame(width: 18, height: 18)
                    Text(store.name(id)).lineLimit(1)
                    Spacer()
                    Text(long(times[id] ?? 0)).foregroundStyle(.secondary).monospacedDigit()
                    if store.picked.contains(id) && store.mode != .running {
                        Button { store.removePicked(id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
        }
    }

}

// MARK: Friends

/// The race, for the hover view.
struct FriendsMini: View {
    let board: Board

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Today's race").font(.headline)
                Spacer()
                if let line = board.raceLine {
                    Text(line).font(.caption.weight(.semibold)).foregroundStyle(board.leading ? .green : .orange)
                }
            }
            ForEach(Array(board.ranked.enumerated()), id: \.element.id) { i, f in
                FriendRow(board: board, rank: i + 1, friend: f, compact: true)
            }
        }
    }
}

struct FriendRow: View {
    let board: Board
    let rank: Int
    let friend: Friend
    var compact = false

    var body: some View {
        let me = friend.id == board.memberID
        HStack(spacing: 8) {
            Text("\(rank)").font(.system(.callout, design: .rounded).weight(.heavy)).frame(width: 16)
                .foregroundStyle(rank == 1 ? .yellow : .secondary)
            Circle().fill(friend.focusing ? Color.green : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                .help(friend.focusing ? "Focusing right now" : "Not focusing right now")
            Text(me ? "You" : friend.name).fontWeight(me ? .bold : .regular).lineLimit(1)
            if board.champions.contains(friend.id) {
                Image(systemName: "crown.fill").foregroundStyle(.yellow).font(.caption)
                    .help("Won yesterday")
            }
            if friend.streak > 1 && !compact {
                Label("\(friend.streak)", systemImage: "flame.fill").font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(long(Double(friend.score))).monospacedDigit().fontWeight(.semibold)
                if !compact {
                    Text("\(long(Double(friend.today))) focus · \(long(Double(friend.week)))/wk")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let status = clockStatus {
                    Text(status.text).font(.caption2.weight(.semibold)).foregroundStyle(status.color)
                }
            }
        }
        .font(.callout)
    }

    /// "in 8:52am", "in 9:40am · −35", "late 23m · −23", or "due 9:00am".
    private var clockStatus: (text: String, color: Color)? {
        guard let due = friend.due_min else { return nil }
        let late = friend.late ?? 0
        if let inAt = friend.in_min {
            return late > 0 ? ("in \(Office.text(inAt)) · −\(late)", .orange) : ("in \(Office.text(inAt))", .green)
        }
        if late > 0 { return ("late \(late)m · −\(late)", .red) }
        return compact ? nil : ("due \(Office.text(due))", .secondary)
    }
}

struct FriendsSection: View {
    let board: Board
    let store: Store
    @State private var taunt = ""
    @State private var target: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Friends").font(.system(.headline, design: .rounded))
                Spacer()
                if let c = board.code {
                    Text(c).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(board.installCommand ?? c, forType: .string)
                        store.announce("Invite copied. Send it to a friend", sound: nil, seconds: 3)
                    } label: {
                        Label("Copy invite", systemImage: "person.badge.plus")
                    }
                    .controlSize(.small)
                    .help("Copies a one-line install command with your board code")
                }
            }
            if !board.joined {
                Button("Set up friends and office hours…") { AppWindows.shared?.showSetup() }
                    .controlSize(.small)
            } else { boardView }
            if let e = board.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var boardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if board.friends.count <= 1 {
                Text("Just you so far. Copy the invite and send it to a friend; they paste it into Terminal and they're in.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let line = board.raceLine {
                Text(line)
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .foregroundStyle(board.leading ? AnyShapeStyle(.green.gradient) : AnyShapeStyle(.orange.gradient))
            }
            ForEach(Array(board.ranked.enumerated()), id: \.element.id) { i, f in
                FriendRow(board: board, rank: i + 1, friend: f)
            }
            if board.tauntsLeft > 0 && !board.others.isEmpty { tauntBox } else if board.friends.count > 1 {
                Label("Win today to earn 3 taunts for tomorrow", systemImage: "crown")
                    .font(.caption).foregroundStyle(.secondary)
            }
            BonusCard(store: store)
        }
        .disabled(board.busy)
    }

    private var tauntBox: some View {
        let others = board.others
        let chosen = others.first { $0.id == target } ?? others[0]
        return VStack(alignment: .leading, spacing: 6) {
            Label("You won yesterday. \(board.tauntsLeft) taunt\(board.tauntsLeft == 1 ? "" : "s") left", systemImage: "crown.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.yellow)
            HStack(spacing: 6) {
                if others.count > 1 {
                    Picker("", selection: Binding(get: { chosen.id }, set: { target = $0 })) {
                        ForEach(others) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                TextField("Say something to \(chosen.name)…", text: $taunt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send(to: chosen) }
                Button {
                    taunt = Board.ideas.randomElement() ?? ""
                } label: { Image(systemName: "dice") }
                    .help("Give me an idea")
                Button("Send") { send(to: chosen) }
                    .disabled(taunt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            Text("It pops up on \(chosen.name)'s screen at a random moment, with a sound. \(taunt.count)/80")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.1)))
    }

    private func send(to friend: Friend) {
        let text = String(taunt.prefix(80))
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await board.taunt(friend, message: text)
            if board.error == nil { taunt = "" }
        }
    }
}

/// Today's bonuses, so the scoring is never a mystery.
struct BonusCard: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bonuses today").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label("Early bird", systemImage: "sunrise.fill").foregroundStyle(.orange)
                Spacer()
                Text(store.earlyBonus(on: store.now) > 0 ? "+\(long(store.earlyBonus(on: store.now)))" : "before 9am counts 1.5×")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("Clean morning", systemImage: "leaf.fill").foregroundStyle(.green)
                Spacer()
                Text(store.cleanMorningStatus).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

/// The bubble that pops up above the pill when a friend's taunt lands.
struct TauntBubble: View {
    let taunt: Taunt
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill").foregroundStyle(.yellow)
                Text("\(taunt.from_name) says").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
            Text(taunt.message)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.yellow.opacity(0.5), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(20)
    }
}

// MARK: Office hours

/// One line in the popover: when you're due and whether you made it.
struct OfficeStatus: View {
    let store: Store

    var body: some View {
        let s = OfficeHours.status(store)
        HStack {
            Label("Office hours", systemImage: "building.2.fill").foregroundStyle(.secondary)
            Spacer()
            Text(s.text).fontWeight(.semibold).foregroundStyle(s.color)
        }
        .font(.callout)
    }
}

/// The Settings tab: clock-in time, workdays and the distraction lock.
struct OfficeHours: View {
    let store: Store
    let board: Board

    var body: some View {
        let office = store.office
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Today").foregroundStyle(.secondary)
                Spacer()
                let s = Self.status(store)
                Text(s.text).fontWeight(.semibold).foregroundStyle(s.color)
            }
            HStack(spacing: 12) {
                Text("I start work at").font(.title3)
                DatePicker("", selection: startBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).frame(width: 100)
            }
            HStack(spacing: 6) {
                Text("on").foregroundStyle(.secondary)
                DayPicker(days: Binding(get: { office.plannedDays }, set: { plan(start: office.plannedStart, days: $0) }))
            }
            if office.hasPending {
                Label("From tomorrow: \(Office.text(office.plannedStart)), \(Self.daysText(office.plannedDays)). Today stays \(Office.text(office.startMin)), \(Self.daysText(office.workdays)).",
                      systemImage: "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Your first 5 focused minutes clock you in. Late costs a point a minute after 5 minutes' grace, and at 15 minutes your friends get an email. Changes start the next day, so you can't push today back.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Close YouTube, Instagram, TikTok and co until I clock in",
                   isOn: Binding(get: { office.lockDistractions }, set: { store.office.lockDistractions = $0 }))
                .toggleStyle(.switch)
        }
    }

    static func status(_ store: Store) -> (text: String, color: Color) {
        let office = store.office
        guard let due = office.due(on: store.now) else { return ("Day off", .secondary) }
        if store.clockedIn { return ("Clocked in", .green) }
        let late = office.lateMinutes(now: store.now, clockedIn: false)
        if late > 0 { return ("\(late)m late · −\(late)", .red) }
        if store.now < due { return ("Due \(Office.text(office.startMin))", .secondary) }
        return ("Clock in now", .orange)
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(store.office.plannedStart * 60)) },
            set: { plan(start: Office.minutes(from: $0), days: store.office.plannedDays) })
    }

    private func plan(start: Int, days: Int) {
        store.office.plan(start: start, days: days)
        Task { await board.setSchedule(start: start, days: days) }
    }

    static func daysText(_ days: Int) -> String {
        if days == 0 { return "no workdays" }
        if days == 31 { return "Mon–Fri" }
        if days == 127 { return "every day" }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return (0..<7).filter { days & (1 << $0) != 0 }.map { names[$0] }.joined(separator: " ")
    }
}
