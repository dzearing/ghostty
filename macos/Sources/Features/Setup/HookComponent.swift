// macos/Sources/Features/Setup/HookComponent.swift
import Foundation

enum HookComponentError: Error, Equatable {
    /// The shared config file (e.g. ~/.claude/settings.json) exists but is not a
    /// JSON object we can safely merge into — invalid JSON, or a valid top-level
    /// array/scalar. We refuse to overwrite it rather than replace the user's
    /// data with only Ghoztty's hooks block.
    case unparseableConfig(URL)
}

/// Installs a runtime's hook automation per its `HookSpec` ownership strategy.
///
/// NOTE (deferred refactor — review item H9): the `.mergedFragment` branch below
/// calls the concrete `ClaudeHookSpec.merge/removeFragment/fragmentState` statics
/// rather than dispatching through `spec`, and the factory downcasts `spec as?
/// ClaudeHookSpec` for plugin detection. The `HookSpec` protocol therefore only
/// truly abstracts the `.dedicatedFile` path. This is intentional debt, not a
/// bug: both shipped runtimes work, and a new `.dedicatedFile` runtime needs no
/// changes here. Only a SECOND `.mergedFragment` runtime forces generalizing
/// this — at which point move merge/state/remove onto `HookSpec` (and make
/// external-plugin ownership a spec capability) rather than adding another
/// concrete branch. Deferred until that runtime actually exists.
struct HookComponent {
    let spec: HookSpec
    let homeDirectoryURL: URL
    let fileManager: FileManager

    private var bannerScriptPath: String {
        BannerScriptInstaller.scriptURL(homeDirectoryURL: homeDirectoryURL).path
    }

    private var fileURL: URL { spec.hookFileURL(homeDirectoryURL: homeDirectoryURL) }

    func state() -> ComponentInstallState {
        switch spec.ownership {
        case .dedicatedFile:
            return ManagedFile.state(
                at: fileURL,
                expected: spec.renderedFile(bannerScriptPath: bannerScriptPath),
                marker: spec.marker)
        case .mergedFragment:
            // A present-but-unparseable shared file must NOT read as
            // .notInstalled — that would offer a destructive "Set up". Report
            // .outdated: the row's action is non-destructive and install()
            // re-reads and throws instead of clobbering the user's config.
            guard let json = try? readJSON() else { return .outdated }
            return ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: bannerScriptPath)
        }
    }

    func install() throws {
        switch spec.ownership {
        case .dedicatedFile:
            try ManagedFile.write(
                spec.renderedFile(bannerScriptPath: bannerScriptPath),
                to: fileURL, marker: spec.marker, mode: 0o600, fileManager: fileManager)
        case .mergedFragment:
            let merged = ClaudeHookSpec.merge(into: try readJSON(), bannerScriptPath: bannerScriptPath)
            try writeJSON(merged)
        }
    }

    func uninstall() throws {
        switch spec.ownership {
        case .dedicatedFile:
            try ManagedFile.removeIfManaged(at: fileURL, marker: spec.marker, fileManager: fileManager)
        case .mergedFragment:
            let json = try readJSON()
            guard ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: bannerScriptPath) != .notInstalled else { return }
            try writeJSON(ClaudeHookSpec.removeFragment(from: json, bannerScriptPath: bannerScriptPath))
        }
    }

    /// Read the shared JSON config. Returns an empty base ONLY when the file is
    /// genuinely absent or empty (so a first-time install correctly starts from
    /// `[:]`). If the file is PRESENT with content but is not a JSON object,
    /// THROW — never fall back to `[:]`, because merge()+writeJSON() would then
    /// replace the user's real config with only Ghoztty's hooks block.
    private func readJSON() throws -> [String: Any] {
        // Absent OR empty → empty base: a fresh merge writing only our hooks is
        // safe because there is no user data to lose.
        guard let data = fileManager.contents(atPath: fileURL.path), !data.isEmpty else { return [:] }
        // Present with content but NOT a JSON object (invalid JSON, or a valid
        // array/scalar/null) → refuse: overwriting would destroy the user's file.
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw HookComponentError.unparseableConfig(fileURL)
        }
        return dict
    }

    private func writeJSON(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // One-time safety net: back up the user's original shared config before
        // the FIRST Ghoztty rewrite, so a future merge regression stays
        // recoverable.
        let backupURL = fileURL.appendingPathExtension("ghoztty.bak")
        if fileManager.fileExists(atPath: fileURL.path),
           !fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }
        // Route through the shared symlink-refusing atomic writer (no marker
        // requirement — settings.json is user-owned and unmarked) so the shared
        // config gets the same dotfiles-safety and atomicity as our own files,
        // rather than Data.write(.atomic) silently replacing a symlinked config.
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw HookComponentError.unparseableConfig(fileURL)
        }
        try ManagedFile.writeAtomicNoFollow(text, to: fileURL, mode: 0o600, fileManager: fileManager)
    }
}
