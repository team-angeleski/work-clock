import AppKit
import SwiftUI
import UserNotifications

// MARK: Windows

/// The two real windows: first-run setup and Settings. Each is built when opened and
/// thrown away when closed, so nothing stays in memory.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    static private(set) var shared: AppWindows?

    private let store: Store
    private let board: Board
    private let updater: Updater
    private var setup: NSWindow?
    private var settings: NSWindow?

    init(store: Store, board: Board, updater: Updater) {
        self.store = store
        self.board = board
        self.updater = updater
        super.init()
        Self.shared = self
    }

    /// `emailOnly`: already on a board but no email yet (accounts from before 1.3).
    func showSetup(emailOnly: Bool = false) {
        settings?.close()
        let view = SetupView(store: store, board: board, emailOnly: emailOnly) { [weak self] in self?.setup?.close() }
        setup = setup ?? makeWindow(title: "Welcome to Darnell Jr.", size: NSSize(width: 620, height: 690))
        setup?.titleVisibility = .hidden
        setup?.isMovableByWindowBackground = true
        setup?.contentView = NSHostingView(rootView: view)
        present(setup)
    }

    func showSettings(tab: SettingsView.Tab = .general) {
        let view = SettingsView(store: store, board: board, updater: updater, tab: tab)
        settings = settings ?? makeWindow(title: "Darnell Jr. Settings", size: NSSize(width: 500, height: 440))
        settings?.contentView = NSHostingView(rootView: view)
        present(settings)
    }

    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        NSApp.activate()
        w?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        w.contentView = nil
        if w === setup { setup = nil }
        if w === settings { settings = nil }
    }
}

// MARK: Setup

/// First-run setup, in the style of Apple's own: one idea per page, a hero up top,
/// feature rows with tinted symbol tiles, one big button.
struct SetupView: View {
    let store: Store
    let board: Board
    var emailOnly = false
    var onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, permissions, you, signIn, office, board, done }

    @State private var step: Step
    @State private var forward = true
    @State private var name = UserDefaults.standard.string(forKey: "boardName") ?? NSFullUserName().components(separatedBy: " ").first ?? ""
    @State private var email = ""
    @State private var code = UserDefaults.standard.string(forKey: "inviteCode") ?? ""
    @State private var axOK = AXIsProcessTrusted()
    @State private var notifyOK = false
    @State private var signingIn = false
    @State private var codeSent = false
    @State private var loginCode = ""
    @State private var startMin: Int
    @State private var days: Int

    init(store: Store, board: Board, emailOnly: Bool, startAt: Step? = nil, onFinish: @escaping () -> Void) {
        self.store = store
        self.board = board
        self.emailOnly = emailOnly
        self.onFinish = onFinish
        _step = State(initialValue: startAt ?? (emailOnly ? .you : .welcome))
        _startMin = State(initialValue: store.office.plannedStart)
        _days = State(initialValue: store.office.plannedDays)
    }

    private var steps: [Step] {
        if emailOnly { return [.you, .office, .done] }
        return signingIn ? [.welcome, .permissions, .signIn, .done] : [.welcome, .permissions, .you, .office, .board, .done]
    }
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: 620, height: 690)
        .background(VisualEffect().ignoresSafeArea())
        .onReceive(poll) { _ in
            guard step == .permissions else { return }
            axOK = AXIsProcessTrusted()
            UNUserNotificationCenter.current().getNotificationSettings { s in
                let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                Task { @MainActor in notifyOK = ok }
            }
        }
    }

    @ViewBuilder private func page(_ step: Step) -> some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome: welcome
            case .permissions: permissions
            case .you: you
            case .signIn: signIn
            case .office: office
            case .board: boardStep
            case .done: done
            }
        }
        .padding(.horizontal, 64)
        .padding(.top, 52)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 0) {
            buddy(mood: 1)
            title("Meet Darnell Jr.", "Your little focus buddy. He sits next to your Dock and only counts real work.")
            VStack(alignment: .leading, spacing: 18) {
                feature("cursorarrow.click.2", .blue, "Pick, then focus", "Click the clock, click the apps you work in, then click it again to start.")
                feature("eye.fill", .orange, "Only real work counts", "Drift to YouTube and it stops, and gives you a nudge back.")
                feature("trophy.fill", .yellow, "Race your friends", "Win the day and you get three taunts that pop up on their screens.")
                feature("building.2.fill", .indigo, "Office hours", "Pick a start time. Being late costs points, and your friends hear about it.")
            }
        }
    }

    private var permissions: some View {
        VStack(spacing: 0) {
            hero("hand.raised.fill", .blue)
            title("Two permissions", "Both stay on this Mac. Only your daily totals ever leave it.")
            VStack(spacing: 12) {
                permission(ok: axOK, icon: "accessibility", tint: .blue, title: "Accessibility",
                           detail: "Lets the clock sit by your Dock and see which app is in front.", action: "Open Settings") {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                permission(ok: notifyOK, icon: "bell.badge.fill", tint: .red, title: "Notifications",
                           detail: "Nudges when you drift, when you're nearly late, and when a friend starts.", action: "Allow") {
                    Notify.ask()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
            Text("The first time you count a website, macOS asks if Darnell Jr. can read your browser's tabs. Click OK.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
        }
    }

    private var you: some View {
        VStack(spacing: 0) {
            hero("person.crop.circle.fill", .purple)
            title(emailOnly ? "Add your email" : "Make it yours",
                  emailOnly ? "Your email is now part of your account. It's how the race reaches your phone."
                            : "Friends see your name. Your email is your account.")
            VStack(spacing: 10) {
                if !emailOnly { field("Name", text: $name) }
                field("Email", text: $email, submit: { if canContinue { next() } })
            }
            .padding(.bottom, 26)
            VStack(alignment: .leading, spacing: 14) {
                Text("You'll get an email, even with your Mac shut, when:")
                    .font(.callout).foregroundStyle(.secondary)
                feature("figure.run", .green, "A friend passes you", nil)
                feature("alarm.fill", .red, "You're late to clock in", nil)
                feature("crown.fill", .yellow, "Someone spends a taunt on you", nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Nothing else. Never shared.").font(.footnote).foregroundStyle(.tertiary).padding(.top, 18)
            if !emailOnly {
                Button("Already use Darnell Jr. on another computer? Sign in") {
                    signingIn = true
                    forward = true
                    withAnimation(.smooth(duration: 0.35)) { step = .signIn }
                }
                .buttonStyle(.link).padding(.top, 10)
            }
        }
    }

    private var signIn: some View {
        VStack(spacing: 0) {
            hero("laptopcomputer.and.arrow.down", .teal)
            title("Sign in", "Same account on every computer. Your time adds up across all of them.")
            VStack(spacing: 10) {
                field("Email on your account", text: $email, submit: { Task { await sendCode() } })
                    .disabled(codeSent)
                if codeSent {
                    TextField("", text: $loginCode, prompt: Text("6-digit code"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
                        .onChange(of: loginCode) { _, v in
                            if v.filter(\.isNumber).count == 6 { Task { await finishSignIn() } }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            HStack(spacing: 14) {
                if codeSent {
                    Button { Task { await finishSignIn() } } label: { Text("Sign In").font(.headline).frame(width: 200) }
                        .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                        .disabled(loginCode.filter(\.isNumber).count != 6 || board.busy)
                    Button("Send again") { Task { await sendCode() } }.buttonStyle(.link).disabled(board.busy)
                } else {
                    Button { Task { await sendCode() } } label: { Text("Email Me a Code").font(.headline).frame(width: 200) }
                        .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                        .disabled(!emailValid || board.busy)
                }
            }
            .padding(.top, 18)
            if let e = board.error { Text(e).font(.callout).foregroundStyle(.red).padding(.top, 10) }
            if codeSent && board.error == nil {
                Text("Check your email. The code works for 10 minutes.").font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            }
            Button("New here? Set up a new account") {
                signingIn = false; codeSent = false
                forward = false
                withAnimation(.smooth(duration: 0.35)) { step = .you }
            }
            .buttonStyle(.link).padding(.top, 22)
        }
        .animation(.smooth, value: codeSent)
    }

    private func sendCode() async {
        guard emailValid else { return }
        if await board.sendCode(to: email) { codeSent = true }
    }

    private func finishSignIn() async {
        guard !board.busy else { return }
        if await board.signIn(email: email, code: loginCode) { advance() } else { loginCode = "" }
    }

    private var office: some View {
        VStack(spacing: 0) {
            hero("building.2.fill", .indigo)
            title("Office hours", "At home nobody's waiting for you at 9. Now someone is.")
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Text("I start work at").font(.title3)
                    DatePicker("", selection: startBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field).controlSize(.large).frame(width: 96)
                }
                DayPicker(days: $days)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
            .padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 16) {
                feature("timer", .green, "Five minutes clocks you in", "Your first five focused minutes of the day.")
                feature("minus.circle.fill", .red, "Late costs a point a minute", "After five minutes' grace. At fifteen, your friends get an email.")
                feature("calendar.badge.clock", .orange, "Changes start tomorrow", "So you can't push today back once you're running late.")
                feature("xmark.app.fill", .pink, "Distractions stay closed", "YouTube, Instagram and co close until you've clocked in.")
            }
        }
    }

    private var boardStep: some View {
        VStack(spacing: 0) {
            hero("person.3.fill", .green)
            title("Join your friends", "Up to five people race on focus every day.")
            HStack(spacing: 10) {
                TextField("", text: $code, prompt: Text("BOARD CODE"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10)
                    .frame(width: 200)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
                    .onSubmit { if code.count >= 6 { Task { await join(code: code) } } }
                Button { Task { await join(code: code) } } label: { Text("Join").frame(width: 70) }
                    .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || board.busy)
            }
            Button("No code? Start a new board") { Task { await join(code: nil) } }
                .buttonStyle(.link).padding(.top, 12).disabled(board.busy)
            if let e = board.error {
                Text(e).font(.callout).foregroundStyle(.red).padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("clock.fill", .blue, "1 point a focused minute", "Before 9am each minute counts 1.5×.")
                feature("leaf.fill", .green, "Clean morning: +30", "No socials before 1pm, plus an hour of focus by then.")
                feature("checkmark.shield.fill", .teal, "No faking it", "Idle time is handed back, and the server checks every number.")
            }
            .padding(.top, 28)
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            buddy(mood: 1)
            title("You're all set", board.code.map { "You're on board \($0). Invite friends from Settings → Account." } ?? "Time to get some work done.")
            VStack(alignment: .leading, spacing: 18) {
                feature("cursorarrow.click", .blue, "Click the clock to start", "Then click your work apps, and click the clock again.")
                feature("cursorarrow.click.badge.clock", .orange, "Right-click for the race", "Your week, your rank, and taunts when you've won.")
                feature("gearshape.fill", .gray, "Settings live there too", "Office hours, email, your board.")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            if step == .done {
                primary("Start Focusing") { onFinish(); store.primaryAction() }
            } else if step != .board && step != .signIn {
                primary(step == .permissions && !axOK ? "Skip for Now" : "Continue") { next() }
                    .disabled(!canContinue || board.busy)
            } else {
                Color.clear.frame(height: 40)
            }
            ZStack {
                HStack(spacing: 7) {
                    ForEach(steps, id: \.self) { s in
                        Capsule().fill(s == step ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                            .frame(width: s == step ? 16 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: step)
                HStack {
                    if step != steps.first && step != .done {
                        Button("Back") { back() }.buttonStyle(.link)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 26)
    }

    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.count >= 5 && e.contains("@") && e.split(separator: "@").last?.contains(".") == true
    }

    private var canContinue: Bool {
        switch step {
        case .you: return emailValid && (emailOnly || !name.trimmingCharacters(in: .whitespaces).isEmpty)
        default: return true
        }
    }

    private func next() {
        if step == .you && emailOnly {
            Task {
                await board.setEmail(email)
                if board.error == nil { advance() }
            }
            return
        }
        if step == .office {
            if emailOnly {
                store.office.plan(start: startMin, days: days)
                Task { await board.setSchedule(start: startMin, days: days) }
            } else {
                store.office.setNow(start: startMin, days: days)
            }
        }
        advance()
    }

    private func advance() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        forward = true
        withAnimation(.smooth(duration: 0.35)) { step = steps[i + 1] }
    }

    private func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        forward = false
        withAnimation(.smooth(duration: 0.35)) { step = steps[i - 1] }
    }

    private func join(code: String?) async {
        await board.join(code: code, name: name, email: email, start: startMin, days: days)
        if board.joined && board.error == nil { advance() }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(startMin * 60)) },
                set: { startMin = Office.minutes(from: $0) })
    }

    // MARK: Pieces

    /// The clock's own buddy, big and happy.
    private func buddy(mood: Double) -> some View {
        Face(mood: mood, blink: 0, tint: .orange)
            .frame(width: 84, height: 84)
            .shadow(color: .orange.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 22)
    }

    private func hero(_ icon: String, _ tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 80, height: 80)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.gradient))
            .shadow(color: tint.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 22)
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 30, weight: .bold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 30)
    }

    private func feature(_ icon: String, _ tint: Color, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, submit: (() -> Void)? = nil) -> some View {
        TextField("", text: text, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .onSubmit { submit?() }
    }

    private func primary(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.headline).frame(width: 260)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
    }

    private func permission(ok: Bool, icon: String, tint: Color, title: String, detail: String,
                            action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ok {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action, action: perform).controlSize(.large)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.05)))
        .animation(.bouncy, value: ok)
    }
}

/// The frosted window background.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// M T W T F S S toggles.
struct DayPicker: View {
    @Binding var days: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { i in
                let on = days & (1 << i) != 0
                Button(Office.dayLetters[i]) { days ^= (1 << i) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                    .foregroundStyle(on ? .white : .secondary)
            }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Bindable var store: Store
    let board: Board
    let updater: Updater
    @State var tab: Tab

    enum Tab: Hashable { case general, office, account, scoring }

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            OfficeHours(store: store, board: board).padding(24)
                .frame(maxHeight: .infinity, alignment: .top)
                .tabItem { Label("Office hours", systemImage: "building.2") }.tag(Tab.office)
            AccountSettings(store: store, board: board).tabItem { Label("Account", systemImage: "person.crop.circle") }.tag(Tab.account)
            scoring.tabItem { Label("Scoring", systemImage: "trophy") }.tag(Tab.scoring)
        }
        .padding(.top, 28)
        .frame(width: 500, height: 440)
    }

    private var general: some View {
        Form {
            Section("Daily goal") {
                Toggle("Grow my goal with me", isOn: $store.autoGoal)
                if store.autoGoal {
                    Text("Today: \(long(store.goal)). Your recent average plus 15 minutes.").foregroundStyle(.secondary)
                } else {
                    Stepper("Goal: \(store.goalHours.formatted()) hours", value: $store.goalHours, in: 0.5...12, step: 0.5)
                }
            }
            Section("Counting") {
                Toggle(board.joined ? "Pause after 2 minutes idle (always on with friends)" : "Pause after 2 minutes idle",
                       isOn: board.joined ? .constant(true) : $store.idlePause)
                    .disabled(board.joined)
                LabeledContent("Apps and sites") {
                    Button("Change apps") { NSApp.keyWindow?.close(); store.changeApps() }
                }
                LabeledContent("Start or stop from anywhere") { Text("⌃⌥F").monospaced() }
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { store.openAtLogin }, set: { store.openAtLogin = $0 }))
                LabeledContent("Version") {
                    if let v = updater.available {
                        Button(updater.updating ? "Updating…" : "Update to \(v)") { updater.install() }.disabled(updater.updating)
                    } else {
                        Text(updater.current).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var scoring: some View {
        Form {
            Section("Points") {
                row("clock", "1 point per focused minute")
                row("sunrise.fill", "Before 9am, minutes count 1.5×")
                row("leaf.fill", "No socials before 1pm + an hour of focus: +30")
                row("building.2.fill", "Late to clock in: −1 a minute after 5 minutes' grace (max −120)")
            }
            Section("Winning") {
                row("crown.fill", Costume.enabled ? "Top score wins the day: 3 taunts, and you unlock a legend to play as the next day"
                                                  : "Top score wins the day and gets 3 taunts the next day")
                row("envelope.fill", "Friends get emailed when you pass them, and when you're 15 minutes late")
            }
            Section("Fair play") {
                row("moon.zzz.fill", "Idle for 2 minutes and the time is handed back")
                row("hand.tap.fill", "No key, click or scroll for 10 minutes and it's handed back too")
                row("checkmark.shield.fill", "The server rejects focus that couldn't fit in the time that's passed")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
    }
}

struct AccountSettings: View {
    let store: Store
    let board: Board
    @State private var email = ""
    @State private var leaveArmed = false

    var body: some View {
        Form {
            if board.joined {
                Section("You") {
                    LabeledContent("Name") { Text(UserDefaults.standard.string(forKey: "boardName") ?? "—") }
                    LabeledContent("Email") {
                        HStack {
                            TextField("", text: $email, prompt: Text("you@email.com")).labelsHidden()
                                .onSubmit { save() }
                            Button("Save") { save() }
                                .disabled(email.trimmingCharacters(in: .whitespaces) == (board.email ?? "") || !email.contains("@"))
                        }
                    }
                    Text("Alerts go here: friends passing you, being late, taunts. You can change it, not turn it off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Board") {
                    LabeledContent("Code") { Text(board.code ?? "—").monospaced() }
                    LabeledContent("Invite a friend") {
                        Button("Copy invite") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(board.installCommand ?? "", forType: .string)
                            store.announce("Invite copied. Send it to a friend", sound: nil, seconds: 3)
                        }
                    }
                    Text("They paste it into Terminal. It installs Darnell Jr. and opens setup with your code filled in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("This Mac") {
                    Text("Sign in with the same email on your other computers and your time adds up across all of them.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Stop counting this Mac") {
                        Button("Sign Out") { board.signOut(); AppWindows.shared?.showSetup() }
                    }
                    LabeledContent("Delete account everywhere") {
                        Button(leaveArmed ? "Really delete?" : "Delete…") {
                            if leaveArmed { Task { await board.leave() } } else {
                                leaveArmed = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { leaveArmed = false }
                            }
                        }
                        .foregroundStyle(leaveArmed ? .red : .primary)
                    }
                }
                if let e = board.error { Text(e).foregroundStyle(.red) }
            } else {
                Section {
                    Text("You're not on a board yet.")
                    Button("Set up Darnell Jr.") { AppWindows.shared?.showSetup() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { email = board.email ?? "" }
    }

    private func save() {
        Task { await board.setEmail(email) }
    }
}
