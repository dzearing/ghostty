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
        // The activity-state machine (idle/busy/needs_input) is deliberately
        // only PARTIALLY wired here, and the missing half is a known gap rather
        // than an oversight.
        //
        // Claude registers six more events for it — PreToolUse, PostToolUse,
        // Notification, PermissionRequest, SubagentStart, SubagentStop — and
        // Copilot's equivalents (if any) are not known. Its event vocabulary is
        // not documented in `copilot help config`, which describes only the hook
        // SCHEMA, and the CLI ships as a compressed single-file executable, so
        // the three names below are the ones empirically verified against a live
        // Copilot hook. Guessing at the rest would write events that silently
        // never fire, which is worse than not writing them: the pane would look
        // wired up while reporting stale state.
        //
        // What IS wired: `sessionStart` sweeps leaked agent markers, and
        // `agentStop` settles the pane. Without the subagent events there is
        // nothing to track, so settle resolves to idle — today's behavior — and
        // without a pause event needs_input is never raised here. Both are
        // correct-if-incomplete rather than wrong.
        let object: [String: Any] = [
            "version": 1,
            "_comment": marker,
            "hooks": [
                "sessionStart": hook(.sessionStart) + hook(.activitySessionStart),
                "userPromptSubmitted": hook(.promptSubmit),
                "agentStop": hook(.stop) + hook(.activitySettle),
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
