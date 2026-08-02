// macos/Tests/Ghostty/RuntimeIntegrationFactoryTests.swift
import Foundation
import Testing
@testable import Ghostty

struct RuntimeIntegrationFactoryTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func availabilityFollowsConfigDirAndOfferGate() throws {
        let home = try tempHome()
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default).isEmpty)
        // Copilot is detectable but gated off (isOffered == false), so it is
        // never offered even when its config dir exists (H3).
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default).isEmpty)
        // Claude is offered once its config dir exists.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default) == [.claude])
    }

    // H2: the banner must be ordered before the hooks component, and hooks must
    // be last — the refcount-on-uninstall correctness proof depends on it.
    @Test func bannerComponentPrecedesHooksWhichAreLast() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: .default)
        let names = integ.components.map(\.name)
        let bannerIdx = try #require(names.firstIndex(of: RuntimeIntegrationFactory.bannerComponentName))
        let hooksIdx = try #require(names.firstIndex(of: RuntimeIntegrationFactory.hooksComponentName))
        #expect(bannerIdx < hooksIdx)
        #expect(hooksIdx == names.count - 1)
    }

    @Test func endToEndCopilotInstall() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(for: .copilot, homeDirectoryURL: home, fileManager: .default)
        try integ.install()
        #expect(integ.state() == .installed)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/hooks/ghoztty.json").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh").path))
    }

    @Test func gateBlocksWhenCopilotMissing() throws {
        let home = try tempHome() // no ~/.copilot
        let integ = RuntimeIntegrationFactory.make(for: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(throws: AgentIntegrationError.self) { try integ.install() }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/skills").path))
    }

    @Test func claudeWithExternalPluginSkipsHooks() throws {
        let home = try tempHome()
        let claudeDir = home.appendingPathComponent(".claude")
        let pluginsDir = claudeDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#
            .write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)

        let integ = RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: .default)
        try integ.install()

        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/ghoztty/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh").path))
        let settings = home.appendingPathComponent(".claude/settings.json")
        if let data = FileManager.default.contents(atPath: settings.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            #expect(json["hooks"] == nil)
        }
        #expect(integ.state() == .installed)
    }

    @Test func claudeWithoutExternalPluginInstallsAll() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: .default)
        try integ.install()
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/ghoztty/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh").path))
        let settings = home.appendingPathComponent(".claude/settings.json")
        let data = try #require(FileManager.default.contents(atPath: settings.path))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["hooks"] != nil)
        #expect(integ.state() == .installed)
    }
}
