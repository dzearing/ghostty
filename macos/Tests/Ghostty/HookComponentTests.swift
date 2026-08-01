// macos/Tests/Ghostty/HookComponentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct HookComponentTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copilotDedicatedFileLifecycle() throws {
        let home = try tempHome()
        let c = HookComponent(spec: CopilotHookSpec(), homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .notInstalled)
        try c.install()
        #expect(c.state() == .installed)
        let url = home.appendingPathComponent(".copilot/hooks/ghoztty.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try c.uninstall()
        #expect(c.state() == .notInstalled)
    }

    @Test func claudeMergedFragmentPreservesUserKeys() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"dark"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        try c.install()
        #expect(c.state() == .installed)
        let json = try readJSON(settings)
        #expect(json["theme"] as? String == "dark")
        #expect(json["hooks"] != nil)
        try c.uninstall()
        let after = try readJSON(settings)
        #expect(after["theme"] as? String == "dark")
        #expect(after["hooks"] == nil)
        #expect(c.state() == .notInstalled)
    }

    // C1: through the real on-disk read/merge/write path, a user's pre-existing
    // hooks in the SHARED settings.json survive install AND uninstall — only
    // Ghoztty's own entries are added and later removed.
    @Test func claudeMergePreservesPreExistingUserHooksOnDisk() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"dark","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            .write(to: settings, atomically: true, encoding: .utf8)

        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        try c.install()
        #expect(c.state() == .installed)

        var hooks = (try readJSON(settings)["hooks"] as? [String: Any]) ?? [:]
        #expect(serialize(hooks["PreToolUse"]).contains("echo mine"))
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        #expect(hooks["Stop"] != nil)

        try c.uninstall()
        #expect(c.state() == .notInstalled)
        let json = try readJSON(settings)
        #expect(json["theme"] as? String == "dark")
        hooks = (json["hooks"] as? [String: Any]) ?? [:]
        #expect(serialize(hooks["PreToolUse"]).contains("echo mine"))
        #expect(hooks["SessionStart"] == nil)
        #expect(hooks["UserPromptSubmit"] == nil)
        #expect(hooks["Stop"] == nil)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return obj as? [String: Any] ?? [:]
    }

    private func serialize(_ value: Any?) -> String {
        guard let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
