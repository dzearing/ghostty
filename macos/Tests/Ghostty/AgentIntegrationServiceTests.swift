// macos/Tests/Ghostty/AgentIntegrationServiceTests.swift
import Foundation
import Testing
@testable import Ghostty

struct AgentIntegrationServiceTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installThenUpToDate() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .upToDate)
    }

    @Test func notFoundWhenRuntimeAbsent() throws {
        let home = try tempHome()
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .notFound)
    }

    @Test func summaryJoinsPerRuntime() {
        let text = AgentIntegrationService.summary([(.claude, .installed), (.copilot, .upToDate)])
        #expect(text.contains("Claude Code: installed"))
        #expect(text.contains("Copilot CLI: already up to date"))
    }

    @Test func claudeWithExternalPluginReportsPluginPresent() throws {
        let home = try tempHome()
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#
            .write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        let outcome = AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: .default)
        #expect(outcome == .pluginPresent)
    }

    @Test func reinstallAfterDriftReportsUpgraded() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        // Drift one installed managed file so prior state becomes .outdated.
        let hookFile = home.appendingPathComponent(".copilot/hooks/ghoztty.json")
        // Keep the ownership marker so it stays "managed" (drift, not notInstalled). Marker is "ghoztty-managed".
        try #"{"drifted":true}\n// ghoztty-managed"#.write(to: hookFile, atomically: true, encoding: .utf8)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .upgraded)
    }

    @Test func uninstallRemovesInstalledIntegration() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        #expect(AgentIntegrationService.uninstall(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .uninstalled)
        // After uninstall the skills file Ghoztty wrote is gone.
        let skill = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        #expect(!FileManager.default.fileExists(atPath: skill.path))
    }

    @Test func uninstalledOutcomeLabel() {
        #expect(IntegrationOutcome.uninstalled.label == "removed")
    }

    @Test func allAgentStatusesCoversEveryRuntime() throws {
        let home = try tempHome()
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        #expect(statuses.map(\.agent) == RuntimeAgent.allCases)
    }

    @Test func undetectedAgentIsNotDetectedAndNotInstalled() throws {
        let home = try tempHome() // no .copilot / .claude dirs
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        let copilot = try #require(statuses.first { $0.agent == .copilot })
        #expect(copilot.detected == false)
        #expect(copilot.state == .notInstalled)
        #expect(copilot.pluginManaged == false)
    }

    @Test func detectedInstalledAgentReportsInstalled() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        let copilot = try #require(statuses.first { $0.agent == .copilot })
        #expect(copilot.detected == true)
        #expect(copilot.state == .installed)
    }

    @Test func claudePluginPresenceReportsPluginManaged() throws {
        let home = try tempHome()
        let pluginsDir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try #"{"plugins":[{"name":"ghoztty"}]}"#
            .write(to: pluginsDir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
        let statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        let claude = try #require(statuses.first { $0.agent == .claude })
        #expect(claude.pluginManaged == true)
    }

    @Test func uninstallingOneAgentKeepsSharedBannerForOther() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: .default) == .installed)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        let banner = BannerScriptInstaller.scriptURL(homeDirectoryURL: home)
        #expect(FileManager.default.fileExists(atPath: banner.path))

        // Uninstalling one agent must keep the shared banner (the other still uses it).
        #expect(AgentIntegrationService.uninstall(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .uninstalled)
        #expect(FileManager.default.fileExists(atPath: banner.path))
        let claude = try #require(AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default).first { $0.agent == .claude })
        #expect(claude.state == .installed)

        // Uninstalling the last integrated agent removes the shared banner.
        #expect(AgentIntegrationService.uninstall(agent: .claude, homeDirectoryURL: home, fileManager: .default) == .uninstalled)
        #expect(!FileManager.default.fileExists(atPath: banner.path))
    }
}
