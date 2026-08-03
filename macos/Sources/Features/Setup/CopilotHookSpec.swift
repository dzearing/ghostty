// macos/Sources/Features/Setup/CopilotHookSpec.swift
import Foundation

/// Copilot auto-loads every JSON in ~/.copilot/hooks/, so Ghoztty owns a
/// dedicated file. camelCase event names; version 1 envelope.
struct CopilotHookSpec: HookSpec {
    let ownership: HookOwnership = .dedicatedFile
    let marker = GhosttyManagedMarker.token

    func hookFileURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".copilot/hooks/ghoztty.json")
    }

    func renderedFile(bannerScriptPath: String) -> String {
        // Build the document as a dictionary and serialize with JSONSerialization
        // (deterministic sorted keys) — the same idiom ClaudeHookSpec/HookComponent
        // use — rather than hand-templating JSON and re-implementing escaping.
        func hook(_ purpose: HookPurpose) -> [[String: Any]] {
            [["type": "command",
              "bash": HookCommand.perEvent(purpose: purpose, bannerScriptPath: bannerScriptPath, runtime: .copilot),
              "timeoutSec": 10]]
        }
        let object: [String: Any] = [
            "version": 1,
            "_comment": marker,
            "hooks": [
                "sessionStart": hook(.sessionStart),
                "userPromptSubmitted": hook(.promptSubmit),
                "agentStop": hook(.stop),
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
