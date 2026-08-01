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
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(json["theme"] as? String == "dark")
        #expect(json["hooks"] != nil)
        try c.uninstall()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        #expect(after["theme"] as? String == "dark")
        #expect(after["hooks"] == nil)
        #expect(c.state() == .notInstalled)
    }
}
