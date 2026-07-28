import Foundation

/// Tracks the app version the user last ran, so the agent-update dialog can
/// show only the notes that accrued since then. Snapshotted once at launch
/// (before session restore can fire the dialog) and read later by the dialog.
enum WhatsNewTracking {
    static let defaultsKey = "whatsNewLastSeenVersion"

    /// The version stored BEFORE this launch advanced it — the anchor the
    /// dialog splits on. nil on the very first instrumented run.
    private(set) static var previousSeenVersion: String?

    /// This build's marketing version (`CFBundleShortVersionString`).
    static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Read the stored last-seen version into `previousSeenVersion`, then store
    /// `current`. Idempotent within a launch; call once early in launch.
    @discardableResult
    static func snapshotAndAdvance(current: String, defaults: UserDefaults = .standard) -> String? {
        let prev = defaults.string(forKey: defaultsKey)
        defaults.set(current, forKey: defaultsKey)
        previousSeenVersion = prev
        return prev
    }
}
