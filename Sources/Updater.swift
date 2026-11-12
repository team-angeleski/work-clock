import Foundation
import Observation

/// Checks GitHub for a newer release every hour and installs it by itself as soon as you're not
/// in the middle of a focus session. Builds made locally with run.sh are dev builds and never update.
/// The Update button still works for anyone who wants it now.
@MainActor @Observable
final class Updater {
    private(set) var available: String?
    private(set) var updating = false

    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    /// Set by the app: true when it's safe to restart (not mid-session).
    @ObservationIgnored var canInstallNow: () -> Bool = { true }
    private var isDev: Bool { UserDefaults.standard.bool(forKey: "devBuild") }
    private static let latest = URL(string: "https://api.github.com/repos/team-angeleski/work-clock/releases/latest")!
    private static let installer = "https://raw.githubusercontent.com/team-angeleski/work-clock/main/install.sh"

    init() {
        Task { [weak self] in await self?.check() }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check() }
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        // Once an update is found, install it the moment you're not focusing.
        let w = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfIdle() }
        }
        w.tolerance = 15
        RunLoop.main.add(w, forMode: .common)
    }

    func check() async {
        guard !isDev else { return }
        var req = URLRequest(url: Self.latest)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        available = Self.newer(version, than: current) ? version : nil
        installIfIdle()
    }

    private func installIfIdle() {
        guard available != nil, !updating, !isDev, canInstallNow() else { return }
        UserDefaults.standard.set(current, forKey: "updatedFrom")
        install()
    }

    /// Runs the same one-line installer; it replaces the app and reopens it. History and board stay.
    func install() {
        guard !updating else { return }
        updating = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "curl -fsSL \(Self.installer) | bash >/tmp/workclock-update.log 2>&1"]
        do { try p.run() } catch { updating = false }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
