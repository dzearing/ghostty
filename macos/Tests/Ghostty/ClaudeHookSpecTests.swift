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

    private func manifestHome(_ json: String) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try json.write(to: pluginsDir.appendingPathComponent("installed_plugins.json"),
                       atomically: true, encoding: .utf8)
        return home
    }

    /// The real manifest is `"version": 2`: `plugins` is an OBJECT keyed by
    /// `<name>@<marketplace>`, not the array the older shape used.
    @Test func detectsThePluginInTheVersion2Manifest() throws {
        let home = try manifestHome(#"""
        {"version":2,"plugins":{"ghoztty@dzearing-claude-marketplace":[
          {"scope":"user","installPath":"/Users/x/.claude/plugins/cache/dzearing-claude-marketplace/ghoztty/0.8.0","version":"0.8.0"}]}}
        """#)
        #expect(ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }

    /// The same plugin is registered through more than one marketplace in
    /// practice, so the marketplace half of the key cannot be part of the match.
    @Test func detectsThePluginUnderAnyMarketplace() throws {
        let home = try manifestHome(#"{"version":2,"plugins":{"ghoztty@ghoztty-claude-plugin":[{"scope":"user"}]}}"#)
        #expect(ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }

    /// A substring match over the whole file false-positives on any OTHER
    /// plugin installed at project scope from a ghoztty checkout: the manifest
    /// records that checkout as `projectPath`. Ghoztty would then decline to
    /// install, believing its own plugin owned the runtime.
    @Test func ignoresGhosttyAppearingOnlyInAnotherPluginsPaths() throws {
        let home = try manifestHome(#"""
        {"version":2,"plugins":{"commit-commands@claude-plugins-official":[
          {"scope":"project","projectPath":"/Users/x/git/ghoztty",
           "installPath":"/Users/x/.claude/plugins/cache/claude-plugins-official/commit-commands/unknown"}]}}
        """#)
        #expect(!ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }

    /// A plugin whose name merely CONTAINS "ghoztty" is a different plugin.
    @Test func ignoresAPluginWhoseNameMerelyContainsGhoztty() throws {
        let home = try manifestHome(#"{"version":2,"plugins":{"ghoztty-themes@someone-else":[{"scope":"user"}]}}"#)
        #expect(!ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }
}
