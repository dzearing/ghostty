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

    // H1: a present-but-unparseable shared settings.json must NEVER be
    // overwritten. install() throws, the file's bytes are unchanged, and state()
    // reports .outdated (never .notInstalled, which would offer a destructive
    // "Set up" right before the wipe).
    @Test func claudeUnparseableSettingsIsNotOverwritten() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"theme":"dark", "oops": ,}"#  // present but invalid JSON
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .outdated)
        #expect(throws: HookComponentError.self) { try c.install() }
        let after = try String(contentsOf: settings, encoding: .utf8)
        #expect(after == original)
    }

    // A valid-JSON but non-object root (top-level array) is also unsafe to
    // merge into and must be refused, not silently replaced.
    @Test func claudeTopLevelArraySettingsIsNotOverwritten() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[1,2,3]".write(to: settings, atomically: true, encoding: .utf8)
        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .outdated)
        #expect(throws: HookComponentError.self) { try c.install() }
        #expect(try String(contentsOf: settings, encoding: .utf8) == "[1,2,3]")
    }

    // An absent or empty settings.json has no user data to lose, so a fresh
    // install proceeds from an empty base.
    @Test func claudeEmptySettingsInstallsCleanly() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: settings, atomically: true, encoding: .utf8)
        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        try c.install()
        #expect(c.state() == .installed)
    }

    // H10: the Claude settings.json write must refuse a symlinked destination
    // (dotfiles hazard) instead of replacing the user's symlink with a regular
    // file, matching how ManagedFile guards our own dedicated files.
    @Test func claudeSettingsSymlinkIsRefusedNotReplaced() throws {
        let home = try tempHome()
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        // Real settings live outside (a "dotfiles repo"); settings.json is a symlink to it.
        let real = home.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"dark"}"#.write(to: real, atomically: true, encoding: .utf8)
        let link = claude.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        #expect(throws: ManagedFileError.self) { try c.install() }
        // The symlink is intact and the real file is untouched.
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(try String(contentsOf: real, encoding: .utf8) == #"{"theme":"dark"}"#)
    }

    // H10: a normal (non-symlink) settings.json is still merged and preserved.
    @Test func claudeSettingsRegularFileMergesThroughGuardedWriter() throws {
        let home = try tempHome()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme":"dark"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let c = HookComponent(spec: ClaudeHookSpec(), homeDirectoryURL: home, fileManager: .default)
        try c.install()
        let json = try readJSON(settings)
        #expect(json["theme"] as? String == "dark")
        #expect(json["hooks"] != nil)
        // Not a symlink; a one-time backup of the original was taken.
        let type = try FileManager.default.attributesOfItem(atPath: settings.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(FileManager.default.fileExists(atPath: settings.path + ".ghoztty.bak"))
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
