// macos/Tests/Ghostty/ClaudeHookSpecTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ClaudeHookSpecTests {
    private let scriptPath = "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh"

    // H11: every Ghoztty hook command carries a `timeout` so a hook — notably
    // Stop's best-effort `gh pr view` — can never stall the agent's turn.
    @Test func mergedFragmentCarriesTimeoutOnEveryCommand() {
        let merged = ClaudeHookSpec.merge(into: [:], bannerScriptPath: scriptPath)
        let hooks = hooksDict(merged)
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            let elements = hooks[event] as? [[String: Any]] ?? []
            let commands = elements.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            #expect(!commands.isEmpty)
            #expect(commands.allSatisfy { ($0["timeout"] as? Int) == 10 })
        }
    }

    @Test func mergePreservesUnrelatedKeysAndIsDetectable() {
        let existing: [String: Any] = ["theme": "dark", "model": "opus"]
        let merged = ClaudeHookSpec.merge(into: existing, bannerScriptPath: scriptPath)
        #expect(merged["theme"] as? String == "dark")
        #expect(merged["model"] as? String == "opus")
        #expect(ClaudeHookSpec.fragmentState(in: merged, bannerScriptPath: scriptPath) == .installed)
    }

    @Test func removeFragmentLeavesRest() {
        var json = ClaudeHookSpec.merge(into: ["theme": "dark"], bannerScriptPath: scriptPath)
        json = ClaudeHookSpec.removeFragment(from: json, bannerScriptPath: scriptPath)
        #expect(json["theme"] as? String == "dark")
        #expect(ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: scriptPath) == .notInstalled)
    }

    // C1: install merges event-scoped, so the user's OWN unrelated hooks
    // (e.g. their PreToolUse) survive alongside Ghoztty's three events.
    @Test func mergePreservesUserPreToolUseHooks() {
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "echo mine"]]]]],
        ]
        let merged = ClaudeHookSpec.merge(into: existing, bannerScriptPath: scriptPath)
        let hooks = hooksDict(merged)
        #expect(serialize(hooks["PreToolUse"]).contains("echo mine"))
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)
        #expect(ClaudeHookSpec.fragmentState(in: merged, bannerScriptPath: scriptPath) == .installed)
    }

    // C1: uninstall removes ONLY Ghoztty's entries; user hooks + other keys stay.
    @Test func removeFragmentDropsOnlyGhosttyEntries() {
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "echo mine"]]]]],
        ]
        let merged = ClaudeHookSpec.merge(into: existing, bannerScriptPath: scriptPath)
        let removed = ClaudeHookSpec.removeFragment(from: merged, bannerScriptPath: scriptPath)
        #expect(removed["theme"] as? String == "dark")
        let hooks = hooksDict(removed)
        #expect(serialize(hooks["PreToolUse"]).contains("echo mine"))
        #expect(hooks["SessionStart"] == nil)
        #expect(hooks["UserPromptSubmit"] == nil)
        #expect(hooks["Stop"] == nil)
        #expect(ClaudeHookSpec.fragmentState(in: removed, bannerScriptPath: scriptPath) == .notInstalled)
    }

    // C1: a user's OWN element WITHIN SessionStart (a non-Ghoztty element) must
    // survive both install (appended-to, not replaced) and uninstall.
    @Test func userSessionStartElementSurvivesInstallAndUninstall() {
        let existing: [String: Any] = [
            "hooks": ["SessionStart": [["hooks": [["type": "command", "command": "echo user-start"]]]]],
        ]
        let merged = ClaudeHookSpec.merge(into: existing, bannerScriptPath: scriptPath)
        let mergedSS = hooksDict(merged)["SessionStart"] as? [[String: Any]] ?? []
        #expect(mergedSS.count == 2)
        #expect(serialize(mergedSS).contains("echo user-start"))
        #expect(serialize(mergedSS).contains(scriptPath))
        #expect(ClaudeHookSpec.fragmentState(in: merged, bannerScriptPath: scriptPath) == .installed)

        let removed = ClaudeHookSpec.removeFragment(from: merged, bannerScriptPath: scriptPath)
        let removedSS = hooksDict(removed)["SessionStart"] as? [[String: Any]] ?? []
        #expect(removedSS.count == 1)
        #expect(serialize(removedSS).contains("echo user-start"))
        #expect(!serialize(removedSS).contains(scriptPath))
    }

    private func hooksDict(_ json: [String: Any]) -> [String: Any] {
        (json["hooks"] as? [String: Any]) ?? [:]
    }

    private func serialize(_ value: Any?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    @Test func detectsExternalPlugin() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#.write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        #expect(ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }
}
