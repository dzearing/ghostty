// macos/Sources/Features/Setup/ClaudeHookSpec.swift
import Foundation

/// Claude stores hooks in the SHARED ~/.claude/settings.json (no auto-loaded
/// hooks dir), so Ghoztty merges a fragment under the `hooks` key and tracks
/// ownership by the banner-script invocation signature.
struct ClaudeHookSpec: HookSpec {
    let ownership: HookOwnership = .mergedFragment
    let marker = "ghoztty-managed"

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

    static func hooksBlock(bannerScriptPath: String) -> [String: Any] {
        func entry(_ purpose: HookPurpose) -> [String: Any] {
            ["hooks": [["type": "command",
                        "command": HookCommand.perEvent(purpose: purpose, bannerScriptPath: bannerScriptPath)]]]
        }
        return [
            "SessionStart": [["matcher": "startup|clear", "hooks": [["type": "command", "command": HookCommand.perEvent(purpose: .sessionStart, bannerScriptPath: bannerScriptPath)]]]],
            "UserPromptSubmit": [entry(.promptSubmit)],
            "Stop": [entry(.stop)],
        ]
    }

    static func merge(into json: [String: Any], bannerScriptPath: String) -> [String: Any] {
        var out = json
        out["hooks"] = hooksBlock(bannerScriptPath: bannerScriptPath)
        return out
    }

    static func removeFragment(from json: [String: Any]) -> [String: Any] {
        var out = json
        out.removeValue(forKey: "hooks")
        return out
    }

    static func fragmentState(in json: [String: Any], bannerScriptPath: String) -> ComponentInstallState {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: json["hooks"] ?? [:],
                  options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8),
              text.contains(signature(bannerScriptPath)) else {
            return .notInstalled
        }
        let want = hooksBlock(bannerScriptPath: bannerScriptPath)
        let wantData = try? JSONSerialization.data(withJSONObject: want, options: [.sortedKeys])
        let haveData = try? JSONSerialization.data(withJSONObject: json["hooks"] ?? [:], options: [.sortedKeys])
        return wantData == haveData ? .installed : .outdated
    }

    func isExternalPluginInstalled(homeDirectoryURL: URL, fileManager: FileManager) -> Bool {
        let url = homeDirectoryURL.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("ghoztty")
    }
}
