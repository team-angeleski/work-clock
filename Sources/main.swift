import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: Dock geometry

enum Dock {
    /// Frame of the Dock's icon row in Cocoa screen coordinates, via Accessibility.
    static func frame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == kAXListRole as String else { continue }
            var pos: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size)
            var p = CGPoint.zero, s = CGSize.zero
            guard let pos, let size,
                  AXValueGetValue(pos as! AXValue, .cgPoint, &p),
                  AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: p.x, y: primaryHeight - p.y - s.height, width: s.width, height: s.height)
        }
        return nil
    }
}

// MARK: Global hotkey (⌃⌥F), no permissions needed

final class HotKey {
    nonisolated(unsafe) static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x57434C4B), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: Hosting view: AppKit handles the mouse so clicks are instant

final class PillHost<Content: View>: NSHostingView<Content> {
    var onPress: ((Bool) -> Void)?
    var onClick: ((Bool) -> Void)?
    var onRightClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    private var controlClick = false

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click: open the panel and ignore the matching mouse-up.
        controlClick = event.modifierFlags.contains(.control)
        if controlClick { onRightClick?(); return }
        onPress?(true)
    }

    override func mouseUp(with event: NSEvent) {
        if controlClick { controlClick = false; return }
        onPress?(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(event.modifierFlags.contains(.option))
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    let updater = Updater()
    lazy var board: Board = {
        let b = Board(store: store)
        store.board = b
        return b
    }()
    private var panel: NSPanel!
    private var blur: NSVisualEffectView!
    private var host: PillHost<PillView>!
    private let details = NSPopover()
    private let peek = NSPopover()
    private var peekTask: Task<Void, Never>?
    private var peekBlocked = false   // after a click, wait for the mouse to leave before peeking again
    private var hotKey: HotKey?
    private var tauntPanel: NSPanel?
    private var coach: Coach?
    private var windows: AppWindows?
    private var askedForEmail = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        // Real behind-window blur, like the Dock itself.
        blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active

        host = PillHost(rootView: PillView(store: store, board: board))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        host.onPress = { [weak self] down in self?.store.pressed = down }
        host.onClick = { [weak self] _ in
            self?.peekBlocked = true
            self?.hidePeek()
            self?.store.primaryAction()
        }
        host.onRightClick = { [weak self] in self?.toggleDetails() }
        host.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { self.schedulePeek() } else { self.peekBlocked = false; self.hidePeek() }
        }
        blur.addSubview(host)
        panel.contentView = blur

        details.behavior = .transient
        details.delegate = self
        peek.behavior = .applicationDefined
        peek.animates = true
        peek.delegate = self

        reposition()
        panel.orderFrontRegardless()
        // The Dock only moves when apps come and go, a display changes, or its settings change.
        // React to those, with a slow safety poll, instead of asking the Dock constantly.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionSoon() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionSoon() }
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.dock.prefchanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionSoon() }
        }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        hotKey = HotKey { [weak self] in self?.store.quickToggle() }
        board.onShowTaunt = { [weak self] taunt in self?.showTaunt(taunt) }
        Notify.ask()
        coach = Coach(store: store, board: board)
        coach?.onShake = { [weak self] in self?.shake() }
        windows = AppWindows(store: store, board: board, updater: updater)
        board.onSynced = { [weak self] in
            guard let self else { return }
            self.coach?.boardSynced()
            // Accounts from before 1.3 have no email yet: ask once per launch.
            if self.board.needsEmail && !self.askedForEmail {
                self.askedForEmail = true
                self.windows?.showSetup(emailOnly: true)
            }
        }

        // Hidden test switch: `defaults write local.workclock debugSnapshot -bool YES` writes the panel
        // to /tmp/workclock-panel.png a few seconds after launch.
        if UserDefaults.standard.bool(forKey: "debugSnapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self else { return }
                @MainActor func snap<V: View>(_ v: V, _ name: String) {
                    let r = ImageRenderer(content: v.background(Color(nsColor: .windowBackgroundColor)))
                    r.scale = 1.5
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/workclock-\(name).png"))
                    }
                }
                snap(DetailView(store: self.store, board: self.board, updater: self.updater), "panel")
                for step in SetupView.Step.allCases {
                    snap(SetupView(store: self.store, board: self.board, emailOnly: false, startAt: step) {}, "setup-\(step)")
                }
                snap(OfficeHours(store: self.store, board: self.board).padding(24).frame(width: 500), "settings-office")
                snap(HStack(spacing: 24) {
                    ForEach(Costume.allCases) { c in
                        VStack(spacing: 8) { Portrait(costume: c, size: 90); Text(c.name).font(.caption) }
                    }
                }.padding(30), "characters")
                snap(HStack(spacing: 18) {
                    ForEach(Costume.allCases) { c in
                        Ring(progress: 0.6, active: true, done: false, offTask: false, mood: 0.6, blink: 0, costume: c, size: 60)
                    }
                }.padding(20), "characters-clock")
            }
        }

        // New installs (including a friend's invite) open setup.
        if !board.joined {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.windows?.showSetup() }
        }

        // Save on quit, including `kill`, so no focused time is lost.
        signal(SIGTERM, SIG_IGN)
        sigterm.setEventHandler { [weak self] in self?.store.save(); exit(0) }
        sigterm.resume()
    }

    private let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    func applicationWillTerminate(_ note: Notification) { store.save() }

    private func reposition() {
        let target: CGRect
        if let d = Dock.frame() {
            guard NSScreen.screens.contains(where: { $0.frame.intersects(d) }) else { panel.orderOut(nil); return }
            // The Dock's accessibility frame sits a few points above its visible glass.
            let h = d.height
            target = CGRect(x: d.maxX + 6, y: d.minY - 4, width: (h * 2.1).rounded(), height: h)
        } else if let screen = NSScreen.main {
            // No Accessibility yet: sit bottom-right at Dock height.
            let dockH = max(screen.visibleFrame.minY - screen.frame.minY - 8, 56)
            let w = (dockH * 2.1).rounded()
            target = CGRect(x: screen.frame.maxX - w - 12, y: screen.frame.minY + 4, width: w, height: dockH)
        } else { return }
        if panel.frame != target {
            panel.setFrame(target, display: true)
            blur.maskImage = Self.roundedMask(radius: (target.height * 0.3).rounded())
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Stretchable rounded mask: the only reliable way to round an NSVisualEffectView's blur.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// A quick side-to-side shake of the whole pill, like a wrong password.
    private func shake() {
        let origin = panel.frame.origin
        Task { @MainActor in
            for dx in [-8.0, 8, -6, 6, -3, 3, 0] {
                panel.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
                try? await Task.sleep(for: .milliseconds(45))
            }
        }
    }

    /// A friend's taunt floats above the pill for a few seconds.
    private func showTaunt(_ taunt: Taunt?) {
        guard let taunt else {
            if let p = tauntPanel {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                     completionHandler: { p.orderOut(nil) })
            }
            return
        }
        let view = NSHostingView(rootView: TauntBubble(taunt: taunt) { [weak self] in self?.board.dismissTaunt() })
        let size = view.fittingSize
        let p = tauntPanel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            return p
        }()
        tauntPanel = p
        p.contentView = view
        let pill = panel.frame
        var x = pill.midX - size.width / 2
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(pill) }) ?? NSScreen.main {
            x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        }
        p.setFrame(CGRect(x: x, y: pill.maxY - 12, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
        store.announce("Taunted!", sound: nil, seconds: 6)
    }

    /// The Dock animates when icons are added or removed: follow it for a moment.
    private func repositionSoon() {
        for delay in [0.05, 0.35, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reposition() }
        }
    }

    // Popover content only exists while shown, so nothing hidden keeps redrawing.
    func popoverDidClose(_ notification: Notification) {
        (notification.object as? NSPopover)?.contentViewController = nil
    }

    private func schedulePeek() {
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, !self.details.isShown, !self.store.pressed, !self.peekBlocked else { return }
            self.peek.contentViewController = NSHostingController(rootView: WeekPeek(store: self.store, board: self.board))
            self.peek.show(relativeTo: self.host.bounds, of: self.host, preferredEdge: .maxY)
            self.watchPeek()
        }
    }

    /// Hover exits can be missed (spaces, app switches), so check the pointer while the peek is open.
    private func watchPeek() {
        Task { [weak self] in
            while let self, self.peek.isShown {
                try? await Task.sleep(for: .milliseconds(400))
                let mouse = NSEvent.mouseLocation
                let overPill = self.panel.frame.contains(mouse)
                let overPeek = self.peek.contentViewController?.view.window?.frame.contains(mouse) ?? false
                if !overPill && !overPeek { self.hidePeek(); self.peekBlocked = false }
            }
        }
    }

    private func hidePeek() {
        peekTask?.cancel()
        if peek.isShown { peek.close() }
    }

    private func toggleDetails() {
        hidePeek()
        if details.isShown { details.performClose(nil); return }
        NSApp.activate()
        board.nudge()   // fresh race numbers when you look
        details.contentViewController = NSHostingController(rootView: DetailView(store: store, board: board, updater: updater))
        details.show(relativeTo: host.bounds, of: host, preferredEdge: .maxY)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Debug: `defaults write local.workclock debugRegular -bool YES` gives it a Dock icon so screen tools can see it.
    app.setActivationPolicy(UserDefaults.standard.bool(forKey: "debugRegular") ? .regular : .accessory)
    app.run()
}
