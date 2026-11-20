import AppKit
import CryptoKit
import SwiftUI

/// Quitting takes a long code you wrote down once. Pure friction: closing the clock to slack off
/// should be a chore. Logging out, restarting and updates still quit straight away.
@MainActor
enum QuitLock {
    private static let d = UserDefaults.standard
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no 0/O or 1/I
    static let groups = 8, groupSize = 5
    /// Lost the code? Quitting opens up after this long.
    static let forgotWait: TimeInterval = 30 * 60

    /// Set when the code was right (or the Mac is shutting down): the next quit goes through.
    static var unlocked = false

    static var hasCode: Bool { d.string(forKey: "quitCodeHash") != nil }

    /// A new code. Only its hash is kept, so it's shown once and never again.
    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<groups * groupSize).map { _ in alphabet.randomElement(using: &rng)! }
        let code = stride(from: 0, to: chars.count, by: groupSize)
            .map { String(chars[$0..<$0 + groupSize]) }.joined(separator: "-")
        d.set(hash(code), forKey: "quitCodeHash")
        d.removeObject(forKey: "quitForgotAt")
        return code
    }

    static func check(_ input: String) -> Bool {
        guard let saved = d.string(forKey: "quitCodeHash") else { return true }
        return hash(input) == saved
    }

    private static func hash(_ s: String) -> String {
        let clean = s.uppercased().filter { $0.isLetter || $0.isNumber }
        return SHA256.hash(data: Data(clean.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Forgot it

    static var forgotAt: Date? { d.object(forKey: "quitForgotAt") as? Date }
    static func startForgotTimer() { if forgotAt == nil { d.set(Date(), forKey: "quitForgotAt") } }
    static var forgotLeft: TimeInterval? { forgotAt.map { max(forgotWait - Date().timeIntervalSince($0), 0) } }

    /// Logging out, restarting or shutting down: never stand in the way.
    static var systemIsQuitting: Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                kAERestart, kAEShutDown].map { OSType($0) }.contains(reason)
    }
}

/// Shown once: the code, and a check that it's written down.
struct QuitCodeView: View {
    let code: String
    let done: () -> Void
    @State private var typed = ""

    /// Four groups per line, so a line never breaks inside a group.
    private var twoLines: String {
        let g = code.split(separator: "-")
        return g.prefix(4).joined(separator: "-") + "-\n" + g.dropFirst(4).joined(separator: "-")
    }
    private var firstGroup: String { String(code.prefix(QuitLock.groupSize)) }
    private var ok: Bool { typed.uppercased().trimmingCharacters(in: .whitespaces) == firstGroup }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.orange.gradient)
            Text("Your quit code").font(.title.bold())
            Text("Write this down on paper. You'll need all of it to quit Darnell Jr., and it won't be shown again.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(twoLines)
                .multilineTextAlignment(.center)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .textSelection(.disabled)
                .padding(.vertical, 14).padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
            VStack(spacing: 6) {
                Text("Written down? Type the first five letters:").font(.callout)
                TextField(String(repeating: "•", count: QuitLock.groupSize), text: $typed)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .frame(width: 120).multilineTextAlignment(.center)
                    .onSubmit { if ok { done() } }
            }
            Button("Done") { done() }
                .keyboardShortcut(.defaultAction).controlSize(.large).disabled(!ok)
        }
        .padding(32)
        .frame(width: 520)
    }
}

/// Asked on every quit.
struct QuitPromptView: View {
    let quit: () -> Void
    let cancel: () -> Void
    @State private var typed = ""
    @State private var wrong = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 14) {
                Image(systemName: "lock.fill").font(.system(size: 28)).foregroundStyle(.orange.gradient)
                Text("Enter your quit code").font(.title2.bold())
                Text("The one you wrote down. Still want to stop?")
                    .foregroundStyle(.secondary)
                TextField("XXXXX-XXXXX-…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 420)
                    .onSubmit(tryQuit)
                if wrong { Text("That's not it.").font(.callout).foregroundStyle(.red) }
                HStack {
                    forgot
                    Spacer()
                    Button("Keep working", action: cancel).keyboardShortcut(.cancelAction)
                    Button("Quit", action: tryQuit).keyboardShortcut(.defaultAction)
                }
                .frame(width: 420)
            }
            .padding(28)
        }
    }

    @ViewBuilder private var forgot: some View {
        if let left = QuitLock.forgotLeft {
            if left == 0 {
                Button("Quit without the code") { QuitLock.unlocked = true; quit() }
            } else {
                Text("Lost it: quit opens in \(Int(left / 60) + 1)m").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Button("Lost it?") { QuitLock.startForgotTimer() }.buttonStyle(.link)
        }
    }

    private func tryQuit() {
        if QuitLock.check(typed) { QuitLock.unlocked = true; quit() }
        else { wrong = true; typed = "" }
    }
}
