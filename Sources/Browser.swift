import Foundation

/// Reads the site in a browser's active tab, so a "tab" can be picked instead of the whole browser.
/// Picked items are keys: "com.apple.Notes" for an app, "com.google.Chrome|github.com" for a site.
enum Browser {
    private static let chromium = "URL of active tab of front window"
    private static let sources: [String: String] = [
        "com.google.Chrome": chromium,
        "com.brave.Browser": chromium,
        "com.microsoft.edgemac": chromium,
        "company.thebrowser.Browser": chromium,
        "com.apple.Safari": "URL of current tab of front window",
    ]
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    /// Sites that never count unless you picked them yourself.
    static let distractions = ["youtube.com", "tiktok.com", "instagram.com", "facebook.com", "x.com",
                               "twitter.com", "reddit.com", "netflix.com", "twitch.tv"]

    static func isBrowser(_ bundle: String) -> Bool { sources[bundle] != nil }

    /// "github.com" for the front tab, or nil if unreadable (no window, or permission denied).
    static func domain(of bundle: String) -> String? {
        guard let property = sources[bundle] else { return nil }
        let script = compiled[bundle] ?? NSAppleScript(source: "tell application id \"\(bundle)\" to get \(property)")!
        compiled[bundle] = script
        var error: NSDictionary?
        guard let text = script.executeAndReturnError(&error).stringValue else { return nil }
        // New tab, settings and other non-web pages read as "" so they are never picked.
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host(), !host.isEmpty else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isDistraction(_ domain: String) -> Bool {
        distractions.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Splits a key into its app and optional site.
    static func split(_ key: String) -> (bundle: String, domain: String?) {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }
}
