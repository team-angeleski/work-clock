import SwiftUI

/// The winner's second prize: play as a character for the day, like picking your fighter.
/// Your clock wears it, and friends see the badge next to your name. Picking one shows that
/// character's line on your own screen. Taunts stay your own words.
enum Costume: String, CaseIterable, Identifiable {
    // Icons
    case obama, mlk, tyson, fifty, icecube
    // Originals
    case boss, sergeant, professor, techbro, nana, gentleman, scientist, champ

    var id: String { rawValue }

    var name: String {
        switch self {
        case .obama: "Barack Obama"
        case .mlk: "Martin Luther King Jr."
        case .tyson: "Mike Tyson"
        case .fifty: "50 Cent"
        case .icecube: "Ice Cube"
        case .boss: "Big Boss"
        case .sergeant: "Drill Sergeant"
        case .professor: "The Professor"
        case .techbro: "Tech Bro"
        case .nana: "Nana"
        case .gentleman: "The Gentleman"
        case .scientist: "Mad Scientist"
        case .champ: "The Champ"
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
        case .boss: "Corner office. Mine."
        case .sergeant: "Fall in. The clock is running."
        case .professor: "Class is in session."
        case .techbro: "Shipping. Don't talk to me."
        case .nana: "I made you a snack. Now get to work."
        case .gentleman: "Splendid. Shall we begin?"
        case .scientist: "It's alive! Your focus, that is."
        case .champ: "Undisputed."
        }
    }

    /// Face colour for characters based on real people.
    var skin: Color? {
        switch self {
        case .obama, .mlk, .tyson, .fifty, .icecube: Color(red: 0.55, green: 0.36, blue: 0.24)
        default: nil
        }
    }

    var hat: String? {
        switch self {
        case .boss: "👑"
        case .sergeant: "🪖"
        case .professor: "🎓"
        case .techbro, .icecube: "🧢"
        case .nana: "👒"
        case .gentleman: "🎩"
        default: nil
        }
    }

    var eyes: String? {
        switch self {
        case .boss, .techbro: "🕶️"
        case .professor, .nana: "👓"
        case .scientist: "🥽"
        default: nil
        }
    }

    /// Small badge next to a name on the board.
    var badge: String {
        switch self {
        case .obama: "🇺🇸"
        case .mlk: "🕊️"
        case .tyson: "🥊"
        case .fifty: "💰"
        case .icecube: "🧢"
        case .champ: "🏆"
        default: hat ?? eyes ?? "⭐️"
        }
    }
}

/// The costume pieces, sized to sit on a Face of the given size.
struct CostumeLayer: View {
    let costume: Costume
    var size: CGFloat

    var body: some View {
        let ink = Color(white: 0.1)
        ZStack {
            if let eyes = costume.eyes {
                Text(eyes).font(.system(size: size * 0.58)).offset(y: -size * 0.04)
            }
            if let hat = costume.hat {
                Text(hat).font(.system(size: size * 0.6))
                    .colorMultiply(costume == .icecube ? Color(white: 0.25) : .white)   // a black cap
                    .rotationEffect(.degrees(costume == .techbro ? -14 : costume == .gentleman ? 6 : 0))
                    .offset(x: costume == .techbro ? -size * 0.04 : 0,
                            y: -size * (costume == .boss ? 0.5 : costume == .nana ? 0.47 : 0.43))
            }
            switch costume {
            case .champ:
                Capsule().fill(.red.gradient).frame(width: size * 0.92, height: size * 0.13).offset(y: -size * 0.32)
                gloves
            case .tyson:
                // The face tattoo by his left eye, and gloves up.
                TattooMark().stroke(ink, style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .frame(width: size * 0.14, height: size * 0.18)
                    .scaleEffect(x: -1)
                    .offset(x: size * 0.34, y: -size * 0.2)
                gloves
            case .mlk:
                Capsule().fill(ink).frame(width: size * 0.22, height: size * 0.04).offset(y: size * 0.04)
                Text("🕊️").font(.system(size: size * 0.4)).offset(x: size * 0.5, y: -size * 0.42)
            case .obama:
                Text("🇺🇸").font(.system(size: size * 0.26)).offset(x: size * 0.36, y: size * 0.4)
            case .fifty:
                Chain().stroke(Color.yellow.gradient, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, dash: [size * 0.03, size * 0.04]))
                    .frame(width: size * 0.7, height: size * 0.3).offset(y: size * 0.46)
                Text("💰").font(.system(size: size * 0.3)).offset(x: size * 0.44, y: size * 0.42)
            default:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private var gloves: some View {
        ZStack {
            Text("🥊").font(.system(size: size * 0.42)).offset(x: -size * 0.5, y: size * 0.3)
            Text("🥊").font(.system(size: size * 0.42)).scaleEffect(x: -1).offset(x: size * 0.5, y: size * 0.3)
        }
    }
}

private struct TattooMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY), control: CGPoint(x: r.minX, y: r.minY))
        p.move(to: CGPoint(x: r.maxX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.minX + r.width * 0.2, y: r.maxY), control: CGPoint(x: r.minX + r.width * 0.2, y: r.midY))
        return p
    }
}

private struct Chain: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
        return p
    }
}

/// A costumed buddy for pickers and rows.
struct CharacterFace: View {
    let costume: Costume?
    var size: CGFloat
    var mood = 1.0

    var body: some View {
        ZStack {
            Face(mood: mood, blink: 0, tint: .orange, skin: costume?.skin).frame(width: size, height: size)
            if let costume { CostumeLayer(costume: costume, size: size) }
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

/// Yesterday's winner picks today's character.
struct CharacterPicker: View {
    let board: Board
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(board.myCostume == nil ? "You won yesterday. Pick your character for today"
                                         : "Today you're \(board.me?.characterTitle ?? board.myCostume!.name)",
                  systemImage: "theatermasks.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.yellow)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
                ForEach(Costume.allCases) { c in
                    Button { Task { await board.setCostume(c, name: name) } } label: {
                        VStack(spacing: 2) {
                            CharacterFace(costume: c, size: 30)
                            Text(c.name).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(board.myCostume == c ? Color.yellow.opacity(0.25) : Color.primary.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                    .disabled(board.busy)
                }
            }
            if let c = board.myCostume {
                Text("“\(c.line)”").font(.system(.callout, design: .serif).italic())
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
