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

    /// Availability is the CLI's own presence, not the config dir.
    ///
    /// Ghoztty writes `skills/` (and Copilot's `hooks/`) into that dir, so if the
    /// dir were the signal, our own leftovers would keep reporting a CLI the user
    /// had removed — the failure the design doc rules out by name.
    @Test func availabilityFollowsTheBinaryNotTheConfigDir() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)

        // Config dir present, CLI absent -> NOT available.
        #expect(RuntimeIntegrationFactory.availableAgents(
            homeDirectoryURL: home, fileManager: .default, probe: .stub([])).isEmpty)

        // CLI present -> available, config dir or not.
        #expect(RuntimeIntegrationFactory.availableAgents(
            homeDirectoryURL: home, fileManager: .default, probe: .stub([.copilot])) == [.copilot])
        let bare = try tempHome() // no ~/.claude at all
        #expect(RuntimeIntegrationFactory.availableAgents(
            homeDirectoryURL: bare, fileManager: .default, probe: .stub([.claude])) == [.claude])
    }

    /// The binary probe looks for the runtime's own executable, so a directory
    /// full of Ghoztty artifacts cannot satisfy it.
    @Test func binaryProbeIgnoresGhosttyArtifacts() throws {
        let home = try tempHome()
        let skills = home.appendingPathComponent(".claude/skills/ghoztty")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try "x".write(to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // No `claude` binary in any fallback location under this fake home, and
        // the probe's PATH lookup is irrelevant to files we wrote.
        #expect(!RuntimeAgent.claude.fallbackBinaryPaths(homeDirectoryURL: home)
            .contains { FileManager.default.isExecutableFile(atPath: $0) })
    }

    // H2: the banner must be ordered before the hooks component, and hooks must
    // be last — the refcount-on-uninstall correctness proof depends on it.
    @Test func bannerComponentPrecedesHooksWhichAreLast() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: .default, probe: .stub([.claude]))
        let names = integ.components.map(\.name)
        let bannerIdx = try #require(names.firstIndex(of: RuntimeIntegrationFactory.bannerComponentName))
        let hooksIdx = try #require(names.firstIndex(of: RuntimeIntegrationFactory.hooksComponentName))
        #expect(bannerIdx < hooksIdx)
        #expect(hooksIdx == names.count - 1)
    }

    @Test func endToEndCopilotInstall() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(for: .copilot, homeDirectoryURL: home, fileManager: .default, probe: .stub([.copilot]))
        try integ.install()
        #expect(integ.state() == .installed)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/hooks/ghoztty.json").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh").path))
    }

    /// The install gate is the CLI's presence. A config dir alone is not enough
    /// to install into, and — the case that matters — its absence is no longer
    /// what blocks: a CLI installed but never run still installs cleanly.
    @Test func gateBlocksWhenCopilotCLIMissing() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let integ = RuntimeIntegrationFactory.make(
            for: .copilot, homeDirectoryURL: home, fileManager: .default, probe: .stub([]))
        #expect(throws: AgentIntegrationError.self) { try integ.install() }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot/skills").path))
    }

    /// A runtime whose CLI is installed but has never been run has no config dir
    /// yet. That used to block the install outright; the components create what
    /// they need.
    @Test func installsForACLIThatHasNeverBeenRun() throws {
        let home = try tempHome() // no ~/.copilot
        let integ = RuntimeIntegrationFactory.make(
            for: .copilot, homeDirectoryURL: home, fileManager: .default, probe: .stub([.copilot]))
        try integ.install()
        #expect(integ.state() == .installed)
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".copilot/hooks/ghoztty.json").path))
    }

    @Test func claudeWithExternalPluginSkipsHooks() throws {
        let home = try tempHome()
        let claudeDir = home.appendingPathComponent(".claude")
        let pluginsDir = claudeDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#
            .write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)

        let integ = RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: .default, probe: .stub([.claude]))
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
        let integ = RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: .default, probe: .stub([.claude]))
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
