// macos/Sources/Features/Setup/ClaudePluginMigration.swift
import Foundation
import OSLog

enum ClaudePluginMigrationError: Error, LocalizedError {
    case shellUnavailable
    case uninstallFailed(registration: String, exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .shellUnavailable:
            "Could not run the claude command."
        case .uninstallFailed(let registration, let code):
            "`claude plugin uninstall \(registration)` exited \(code)."
        }
    }
}

/// Hands Claude's `ghoztty` integration over from the standalone plugin to the
/// app, which now ships the same skills itself (tied to the installed Ghoztty
/// rather than to a separately-versioned marketplace release).
///
/// The plugin is removed through **Claude's own CLI**, never by deleting files
/// out of `~/.claude/plugins/cache`. That tree is Claude Code's package-manager
/// state — it carries `.in_use`/`.orphaned_at` sentinels and a versioned
/// manifest whose schema is not ours — so deleting a directory there leaves a
/// dangling entry the next marketplace sync may act on, and editing the manifest
/// means writing another tool's lockfile.
struct ClaudePluginMigration {
    let homeDirectoryURL: URL
    let fileManager: FileManager

    /// Runs a command through the user's login shell and returns its exit code,
    /// or nil if the shell could not be launched. Injected so tests exercise the
    /// flow without a `claude` binary or a real plugin install.
    ///
    /// Blocking: call `run()` off the main thread.
    var runCommand: (String) -> Int32? = { LoginShell.run($0)?.exitCode }

    private static let logger = Logger(subsystem: Bundle.loggerSubsystem, category: "AgentIntegration")

    private var pluginStateDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".claude/ghoztty-banner")
    }

    private var appStateDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".config/ghoztty/banner-state")
    }

    private var pluginSymlink: URL {
        homeDirectoryURL.appendingPathComponent(".claude/scripts/ghoztty-banner.sh")
    }

    var registrations: [String] {
        ClaudeHookSpec.externalPluginRegistrations(
            homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    }

    var isNeeded: Bool { !registrations.isEmpty }

    /// Uninstall FIRST. Everything after it is cleanup that only makes sense
    /// once the plugin is actually gone, so a failure here leaves the user
    /// exactly where they started rather than half-migrated.
    func run() throws {
        try uninstallPlugin()
        try migrateBannerState()
        try removeStalePluginSymlink()
    }

    func uninstallPlugin() throws {
        for registration in registrations {
            guard let code = runCommand("claude plugin uninstall \(registration)") else {
                throw ClaudePluginMigrationError.shellUnavailable
            }
            guard code == 0 else {
                throw ClaudePluginMigrationError.uninstallFailed(registration: registration, exitCode: code)
            }
            Self.logger.info("uninstalled external Claude plugin \(registration, privacy: .public)")
        }
    }

    /// Carry the plugin's per-tty banner state into the app's state directory so
    /// a pane mid-session keeps its banner instead of blanking until the next
    /// prompt.
    ///
    /// Copies rather than moves, and never overwrites: a file the app already
    /// wrote is newer than anything the plugin left behind, and leaving the
    /// originals in place means a user who reinstalls the plugin finds its state
    /// where it expects.
    func migrateBannerState() throws {
        guard let names = try? fileManager.contentsOfDirectory(atPath: pluginStateDirectory.path) else { return }
        try fileManager.createDirectory(at: appStateDirectory, withIntermediateDirectories: true)
        for name in names where name.hasSuffix(".json") {
            let destination = appStateDirectory.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: pluginStateDirectory.appendingPathComponent(name), to: destination)
        }
    }

    /// The plugin's SessionStart hook maintains
    /// `~/.claude/scripts/ghoztty-banner.sh` as a symlink into its own cache,
    /// re-pointing it every session. With the plugin gone nothing maintains it
    /// and it dangles, so anything still invoking that path silently does
    /// nothing.
    ///
    /// Only a symlink INTO the plugin cache is ours to remove. A real file
    /// there, or a link the user aimed somewhere else, is theirs.
    func removeStalePluginSymlink() throws {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: pluginSymlink.path),
              destination.contains("/plugins/cache/")
        else { return }
        try fileManager.removeItem(at: pluginSymlink)
        Self.logger.info("removed the plugin's stale banner symlink")
    }
}
