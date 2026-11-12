import SwiftUI

/// The winner's second prize: play as a legend for the day, like picking your fighter.
/// Your clock wears it, friends see the badge next to your name, and picking one shows
/// that person's line on your own screen. Taunts stay your own words.
enum Costume: String, CaseIterable, Identifiable {
    case obama, mlk, tyson, fifty, icecube

    var id: String { rawValue }

    var name: String {
        switch self {
        case .obama: "Barack Obama"
        case .mlk: "Martin Luther King Jr."
        case .tyson: "Mike Tyson"
        case .fifty: "50 Cent"
        case .icecube: "Ice Cube"
        }
    }

    /// Shown on your own screen when you pick it.
    var line: String {
        switch self {
        case .obama: "Yes we can."
        case .mlk: "I have a dream."
        case .tyson: "Everybody has a plan until they get punched in the mouth."
        case .fifty: "Get rich or die tryin'."
        case .icecube: "Today was a good day."
        }
    }

    var badge: String {
        switch self {
        case .obama: "🇺🇸"
        case .mlk: "🕊️"
        case .tyson: "🥊"
        case .fifty: "💰"
        case .icecube: "🧢"
        }
    }

    var skin: Color {
        switch self {
        case .obama: Color(red: 0.60, green: 0.40, blue: 0.27)
        case .mlk: Color(red: 0.50, green: 0.32, blue: 0.21)
        case .tyson: Color(red: 0.47, green: 0.30, blue: 0.20)
        case .fifty: Color(red: 0.45, green: 0.29, blue: 0.19)
        case .icecube: Color(red: 0.52, green: 0.34, blue: 0.22)
        }
    }

    /// Hair colour and how far down the forehead it comes (nil: shaved or under a cap).
    var hair: (color: Color, depth: CGFloat)? {
        switch self {
        case .obama: (Color(white: 0.32), 0.27)      // short, going grey
        case .mlk: (Color(white: 0.09), 0.29)
        case .tyson: (Color(white: 0.08), 0.2)        // close crop
        case .fifty, .icecube: nil
        }
    }
}

// MARK: Pieces

private let ink = Color(white: 0.1)

/// Hair: the top of the head, with a soft curved hairline.
private struct Hair: View {
    let color: Color
    let depth: CGFloat
    let size: CGFloat
    var body: some View {
        Circle().fill(color.gradient)
            .frame(width: size * 1.02, height: size * 1.02)
            .mask(alignment: .top) {
                Ellipse().frame(width: size * 1.25, height: size * depth * 2).offset(y: -size * depth * 0.9)
            }
    }
}

/// Ice Cube's black cap: crown and a brim across the forehead.
private struct Cap: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.12).gradient)
                .frame(width: size * 1.06, height: size * 1.06)
                .mask(alignment: .top) { Rectangle().frame(height: size * 0.36) }
                .offset(y: -size * 0.02)
            Capsule().fill(Color(white: 0.2))
                .frame(width: size * 1.0, height: size * 0.13)
                .offset(y: -size * 0.15)
            Circle().fill(Color(white: 0.75)).frame(width: size * 0.09).offset(y: -size * 0.33)   // silver button
        }
    }
}

struct Ears: View {
    let skin: Color
    let size: CGFloat
    var earring = false
    var body: some View {
        HStack(spacing: size * 0.8) {
            ear
            ear.overlay(alignment: .bottom) {
                if earring {
                    Circle().fill(.white).frame(width: size * 0.07).shadow(color: .white, radius: 1).offset(y: size * 0.03)
                }
            }
        }
        .offset(y: size * 0.03)
    }
    private var ear: some View {
        Ellipse().fill(skin).frame(width: size * 0.17, height: size * 0.22)
            .overlay(Ellipse().fill(.black.opacity(0.18)).frame(width: size * 0.07, height: size * 0.11))
    }
}

/// Tyson's face tattoo, by his left eye.
private struct Tattoo: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.maxX, y: r.minY))
        p.move(to: CGPoint(x: r.minX + r.width * 0.1, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX * 0.85, y: r.maxY), control: CGPoint(x: r.maxX * 0.8, y: r.midY))
        return p
    }
}

/// Everything that sits on the head. Used on the clock (head only) and in portraits.
struct CostumeLayer: View {
    let costume: Costume
    var size: CGFloat

    var body: some View {
        ZStack {
            if let hair = costume.hair { Hair(color: hair.color, depth: hair.depth, size: size) }
            switch costume {
            case .icecube:
                Cap(size: size)
            case .mlk:
                Capsule().fill(ink).frame(width: size * 0.22, height: size * 0.04).offset(y: size * 0.04)
            case .tyson:
                Tattoo().stroke(ink, style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round))
                    .frame(width: size * 0.13, height: size * 0.16)
                    .offset(x: size * 0.33, y: -size * 0.14)
            case .fifty:
                // Shaved head: a little shine.
                Ellipse().fill(.white.opacity(0.22)).frame(width: size * 0.3, height: size * 0.1)
                    .rotationEffect(.degrees(-20)).offset(x: -size * 0.16, y: -size * 0.36)
            case .obama:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// The head, with ears and costume. `face` is the Face the caller wants (mood, blink, tint).
struct CostumedHead<F: View>: View {
    let costume: Costume
    let size: CGFloat
    @ViewBuilder let face: () -> F

    var body: some View {
        ZStack {
            Ears(skin: costume.skin, size: size, earring: costume == .fifty)
            face().frame(width: size, height: size)
            CostumeLayer(costume: costume, size: size)
        }
    }
}

// MARK: Portraits (picker and board)

/// Head and shoulders, dressed the part.
struct Portrait: View {
    let costume: Costume
    var size: CGFloat          // head size
    var mood = 1.0

    var body: some View {
        ZStack(alignment: .top) {
            outfit
                .frame(width: size * 1.45, height: size * 0.62)
                .offset(y: size * 0.88)
            // Neck
            Rectangle().fill(costume.skin.mix(with: .black, by: 0.12))
                .frame(width: size * 0.32, height: size * 0.25)
                .offset(y: size * 0.8)
            CostumedHead(costume: costume, size: size) {
                Face(mood: mood, blink: 0, tint: .orange, skin: costume.skin)
            }
            .frame(width: size, height: size)
            extras
        }
        .frame(width: size * 1.5, height: size * 1.5, alignment: .top)
    }

    @ViewBuilder private var outfit: some View {
        let shoulders = UnevenRoundedRectangle(topLeadingRadius: size * 0.42, topTrailingRadius: size * 0.42)
        switch costume {
        case .obama, .mlk:
            // Dark suit, white shirt, tie.
            ZStack(alignment: .top) {
                shoulders.fill(costume == .obama ? Color(red: 0.12, green: 0.16, blue: 0.28) : Color(white: 0.16))
                Triangle().fill(.white).frame(width: size * 0.42, height: size * 0.36)
                Tie().fill(costume == .obama ? Color(red: 0.2, green: 0.35, blue: 0.75) : Color(red: 0.45, green: 0.1, blue: 0.12))
                    .frame(width: size * 0.12, height: size * 0.36).offset(y: size * 0.04)
            }
        case .fifty:
            ZStack(alignment: .top) {
                shoulders.fill(Color(white: 0.96))
                shoulders.stroke(Color.black.opacity(0.15), lineWidth: max(1, size * 0.02))
                Ellipse().fill(costume.skin.mix(with: .black, by: 0.12)).frame(width: size * 0.36, height: size * 0.2).offset(y: -size * 0.1)
            }
        case .icecube, .tyson:
            ZStack(alignment: .top) {
                shoulders.fill(Color(white: 0.13))
                Ellipse().fill(costume.skin.mix(with: .black, by: 0.12)).frame(width: size * 0.36, height: size * 0.2).offset(y: -size * 0.1)
            }
        }
    }

    @ViewBuilder private var extras: some View {
        switch costume {
        case .obama:
            Text("🇺🇸").font(.system(size: size * 0.16)).offset(x: -size * 0.32, y: size * 1.02)
        case .mlk:
            Text("🕊️").font(.system(size: size * 0.32)).offset(x: size * 0.58, y: -size * 0.05)
        case .fifty:
            Chain().stroke(LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing),
                           style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, dash: [size * 0.035, size * 0.03]))
                .frame(width: size * 0.5, height: size * 0.28).offset(y: size * 0.9)
            Text("$").font(.system(size: size * 0.16, weight: .black)).foregroundStyle(.yellow)
                .offset(y: size * 1.15)
        case .tyson:
            HStack(spacing: size * 0.62) {
                Text("🥊").font(.system(size: size * 0.38))
                Text("🥊").font(.system(size: size * 0.38)).scaleEffect(x: -1)
            }
            .offset(y: size * 0.74)
        case .icecube:
            EmptyView()
        }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath() }
    }
}

private struct Tie: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX - r.width * 0.3, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX + r.width * 0.3, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY * 0.85))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY * 0.85))
            p.closeSubpath()
        }
    }
}

private struct Chain: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.8))
        }
    }
}

// MARK: Picker

/// Yesterday's winner picks today's legend.
struct CharacterPicker: View {
    let board: Board
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(board.myCostume.map { "Today you're \(board.me?.characterTitle ?? $0.name)" }
                    ?? (board.canUnlock ? "You won yesterday. Unlock a legend" : "You won yesterday. Pick who you are today"),
                  systemImage: "theatermasks.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.yellow)
            Text(board.canUnlock ? "Every day you win unlocks one, yours to keep. \(board.unlocked.count) of \(Costume.allCases.count) unlocked."
                                 : "\(board.unlocked.count) of \(Costume.allCases.count) unlocked. Win again to unlock another.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(Costume.allCases) { c in
                    let owned = board.unlocked.contains(c)
                    let open = owned || board.canUnlock
                    Button { Task { await board.setCostume(c, name: name) } } label: {
                        VStack(spacing: 3) {
                            Portrait(costume: c, size: 30)
                                .saturation(owned ? 1 : 0)
                                .opacity(owned ? 1 : 0.45)
                                .overlay(alignment: .topTrailing) {
                                    if !owned {
                                        Image(systemName: board.canUnlock ? "lock.open.fill" : "lock.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(board.canUnlock ? .yellow : .secondary)
                                    }
                                }
                            Text(c.name).font(.system(size: 8.5, weight: .semibold)).lineLimit(2)
                                .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                                .frame(height: 22, alignment: .top)
                        }
                        .padding(.top, 6).padding(.horizontal, 2)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(board.myCostume == c ? Color.yellow.opacity(0.28) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(board.myCostume == c ? Color.yellow : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(board.busy || !open)
                    .help(owned ? "Wear \(c.name) today" : open ? "Unlock \(c.name) (one unlock per win)" : "Locked. Win a day to unlock")
                }
            }
            if let c = board.myCostume {
                Text("“\(c.line)”").font(.system(.callout, design: .serif).italic())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            }
            HStack(spacing: 6) {
                TextField("Nickname (optional)", text: $name)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onChange(of: name) { _, v in if v.count > 24 { name = String(v.prefix(24)) } }
                if let c = board.myCostume {
                    Button("Save") { Task { await board.setCostume(c, name: name) } }
                        .controlSize(.small).disabled(board.busy)
                }
            }
            Text("Your clock wears it today, and your friends see it next to your name.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.yellow.opacity(0.1)))
    }
}
