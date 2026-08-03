// macos/Sources/Features/Setup/ClaudeHookSpec.swift
import Foundation

/// Claude stores hooks in the SHARED ~/.claude/settings.json (no auto-loaded
/// hooks dir), so Ghoztty merges a fragment under the `hooks` key and tracks
/// ownership by the banner-script invocation signature.
struct ClaudeHookSpec: HookSpec {
    let ownership: HookOwnership = .mergedFragment
    let marker = GhosttyManagedMarker.token

    func hookFileURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".claude/settings.json")
    }

    // renderedFile is unused for mergedFragment; the component uses the merge
    // helpers instead. Provide the whole-file form for protocol conformance/tests.
    func renderedFile(bannerScriptPath: String) -> String {
        let json = Self.merge(into: [:], bannerScriptPath: bannerScriptPath)
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Ownership signature: any hook command that invokes our banner script.
    static func signature(_ bannerScriptPath: String) -> String { bannerScriptPath }

    /// Ghoztty's contribution to the shared `hooks` map: one element per event.
    /// The map is keyed by event name; each value is the array of hook elements
    /// Ghoztty appends for that event. Each command carries a `timeout` (seconds)
    /// so a hook — notably Stop's best-effort `gh pr view` — can never stall the
    /// agent's turn; Claude reads the `timeout` key (Copilot uses `timeoutSec`).
    static func hooksBlock(bannerScriptPath: String) -> [String: [[String: Any]]] {
        func command(_ purpose: HookPurpose) -> [String: Any] {
            ["type": "command",
             "command": HookCommand.perEvent(purpose: purpose, bannerScriptPath: bannerScriptPath, runtime: .claude),
             "timeout": 10]
        }
        func entry(_ purpose: HookPurpose) -> [[String: Any]] {
            [["hooks": [command(purpose)]]]
        }
        return [
            "SessionStart": [["matcher": "startup|clear", "hooks": [command(.sessionStart)]]],
            "UserPromptSubmit": entry(.promptSubmit),
            "Stop": entry(.stop),
        ]
    }

    /// Serialize a single hook element deterministically for signature matching
    /// and set comparison (sorted keys, literal slashes so the script path is
    /// byte-comparable to `signature`).
    private static func serialized(_ element: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: element, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Merge Ghoztty's hooks into the user's shared settings WITHOUT clobbering
    /// their own hooks. Only Ghoztty's three events are touched, and within each
    /// only prior Ghoztty elements (matched by the script-path signature) are
    /// replaced — every other event and every non-Ghoztty element is preserved.
    static func merge(into json: [String: Any], bannerScriptPath: String) -> [String: Any] {
        var out = json
        var hooks = (out["hooks"] as? [String: Any]) ?? [:]
        let sig = signature(bannerScriptPath)
        for (event, ghosttyElements) in hooksBlock(bannerScriptPath: bannerScriptPath) {
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.removeAll { serialized($0).contains(sig) }
            arr.append(contentsOf: ghosttyElements)
            hooks[event] = arr
        }
        out["hooks"] = hooks
        return out
    }

    /// Remove ONLY Ghoztty's own elements (matched by signature) from each event,
    /// pruning an event key that becomes empty and the whole `hooks` map if it
    /// becomes empty. The user's other events and elements are left intact.
    static func removeFragment(from json: [String: Any], bannerScriptPath: String) -> [String: Any] {
        var out = json
        guard var hooks = out["hooks"] as? [String: Any] else { return out }
        let sig = signature(bannerScriptPath)
        for (event, value) in hooks {
            guard var arr = value as? [[String: Any]] else { continue }
            arr.removeAll { serialized($0).contains(sig) }
            if arr.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = arr
            }
        }
        if hooks.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooks
        }
        return out
    }

    /// State of ONLY Ghoztty's fragment: collect the Ghoztty elements (by
    /// signature) from the three events and compare them against what we would
    /// install. The user's other hooks vary and are never part of the compare.
    static func fragmentState(in json: [String: Any], bannerScriptPath: String) -> ComponentInstallState {
        let sig = signature(bannerScriptPath)
        let hooks = (json["hooks"] as? [String: Any]) ?? [:]
        var found = false
        var matches = true
        for (event, wantElements) in hooksBlock(bannerScriptPath: bannerScriptPath) {
            let existing = (hooks[event] as? [[String: Any]]) ?? []
            let ours = existing.filter { serialized($0).contains(sig) }
            if !ours.isEmpty { found = true }
            let wantSet = Set(wantElements.map { serialized($0) })
            let haveSet = Set(ours.map { serialized($0) })
            if wantSet != haveSet { matches = false }
        }
        guard found else { return .notInstalled }
        return matches ? .installed : .outdated
    }

    func isExternalPluginInstalled(homeDirectoryURL: URL, fileManager: FileManager) -> Bool {
        let url = homeDirectoryURL.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("ghoztty")
    }
}
