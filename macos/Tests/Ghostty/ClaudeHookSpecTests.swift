// macos/Tests/Ghostty/ClaudeHookSpecTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ClaudeHookSpecTests {
    private let scriptPath = "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh"

    @Test func mergePreservesUnrelatedKeysAndIsDetectable() {
        let existing: [String: Any] = ["theme": "dark", "model": "opus"]
        let merged = ClaudeHookSpec.merge(into: existing, bannerScriptPath: scriptPath)
        #expect(merged["theme"] as? String == "dark")
        #expect(merged["model"] as? String == "opus")
        #expect(ClaudeHookSpec.fragmentState(in: merged, bannerScriptPath: scriptPath) == .installed)
    }

    @Test func removeFragmentLeavesRest() {
        var json = ClaudeHookSpec.merge(into: ["theme": "dark"], bannerScriptPath: scriptPath)
        json = ClaudeHookSpec.removeFragment(from: json)
        #expect(json["theme"] as? String == "dark")
        #expect(ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: scriptPath) == .notInstalled)
    }

    @Test func detectsExternalPlugin() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#.write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        #expect(ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
    }
}
