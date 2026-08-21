// macos/Sources/Features/Setup/BannerScriptInstaller.swift
import Foundation

/// Copies the bundled hook scripts to STABLE owned paths so generated hooks
/// never reference a volatile `Ghoztty.app` bundle path.
///
/// Two scripts, one directory: `ghoztty-banner.sh` keeps the pane's sticky
/// banner current, and `ghoztty-activity-state.sh` owns the pane's
/// idle/busy/needs_input state machine. They install and uninstall together
/// because a runtime's hooks reference both, so a half-installed pair would
/// leave hook commands pointing at a script that isn't there.
struct BannerScriptInstaller {
    static let marker = GhosttyManagedMarker.shellComment

    let homeDirectoryURL: URL
    let fileManager: FileManager

    /// The banner script's path. Still the anchor threaded through the hook
    /// specs — `HookScripts` resolves the siblings from it.
    static func scriptURL(homeDirectoryURL: URL) -> URL {
        directoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent(HookScripts.bannerName)
    }

    static func directoryURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".config/ghoztty/hooks", isDirectory: true)
    }

    /// Every script this component owns, paired with its bundled source.
    private var scripts: [(url: URL, load: () throws -> String)] {
        let dir = Self.directoryURL(homeDirectoryURL: homeDirectoryURL)
        return [
            (dir.appendingPathComponent(HookScripts.bannerName), GhosttyAssets.bannerScript),
            (dir.appendingPathComponent(HookScripts.activityStateName), GhosttyAssets.activityStateScript),
        ]
    }

    /// Installed only when EVERY script is current. A missing or stale sibling
    /// has to read as actionable rather than `.installed`, or an upgrade that
    /// adds a script would never offer to write it.
    func state() -> ComponentInstallState {
        let states = scripts.map { script -> ComponentInstallState in
            guard let want = try? script.load() else { return .outdated }
            return ManagedFile.state(at: script.url, expected: want, marker: Self.marker)
        }
        if states.allSatisfy({ $0 == .installed }) { return .installed }
        if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
        return .outdated
    }

    func install() throws {
        // Render all up front so a missing bundled asset fails before any write.
        let rendered = try scripts.map { (url: $0.url, body: try $0.load()) }
        for file in rendered {
            try ManagedFile.write(file.body, to: file.url, marker: Self.marker, mode: 0o700, fileManager: fileManager)
        }
    }

    func uninstall() throws {
        for script in scripts {
            try ManagedFile.removeIfManaged(at: script.url, marker: Self.marker, fileManager: fileManager)
        }
    }
}
