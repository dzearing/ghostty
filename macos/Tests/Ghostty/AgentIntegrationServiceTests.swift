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

    // H2/TAU2: a FAILED install of one agent must not delete the shared banner
    // that a working sibling's live hooks still invoke. The old install()
    // rollback removed the banner unconditionally.
    @Test func failedInstallRollbackKeepsSharedBannerForOtherAgent() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        // Claude is fully installed and its hooks reference the shared banner.
        #expect(AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: .default) == .installed)
        let banner = BannerScriptInstaller.scriptURL(homeDirectoryURL: home)
        #expect(FileManager.default.fileExists(atPath: banner.path))

        // Make Copilot's skills install fail: plant an UNMANAGED file (no marker)
        // at the skill path so ManagedFile.write refuses it and throws, triggering
        // rollback AFTER the banner component has already run.
        let skill = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not ghoztty owned".write(to: skill, atomically: true, encoding: .utf8)

        let outcome = AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        guard case .failed = outcome else {
            Issue.record("expected copilot install to fail, got \(outcome)")
            return
        }
        // Rollback must NOT delete the shared banner Claude still uses.
        #expect(FileManager.default.fileExists(atPath: banner.path))
    }

    // H2/TAU3: uninstalling one agent must keep the banner when a sibling with a
    // partially-installed integration (hooks present, skills manually deleted)
    // still references it. The old refcount keyed off the aggregate state()
    // (→ .notInstalled for a partial install) and wrongly dropped the banner.
    @Test func uninstallKeepsBannerWhenSiblingHooksStillPresent() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: .default) == .installed)
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        let banner = BannerScriptInstaller.scriptURL(homeDirectoryURL: home)

        // Partially-install Claude: remove its skills dir but keep its hooks.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/skills"))

        #expect(AgentIntegrationService.uninstall(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .uninstalled)
        // Claude's hooks still call the banner, so it must survive.
        #expect(FileManager.default.fileExists(atPath: banner.path))
    }

    @Test func uninstalledOutcomeLabel() {
        #expect(IntegrationOutcome.uninstalled.label == "removed")
    }

    // H15: allAgentStatuses reports whether the shared banner would survive
    // uninstalling each agent (another agent's hooks still reference it), so the
    // uninstall dialog can tell the user the truth.
    @Test func bannerSharedFlagReflectsSiblingHooks() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        // Only Claude installed → neither agent shares the banner with another.
        #expect(AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: .default) == .installed)
        var statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        #expect(try #require(statuses.first { $0.agent == .claude }).bannerSharedWithOther == false)

        // Both installed → each agent's banner is shared with the other.
        #expect(AgentIntegrationService.install(agent: .copilot, homeDirectoryURL: home, fileManager: .default) == .installed)
        statuses = AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, fileManager: .default)
        #expect(try #require(statuses.first { $0.agent == .claude }).bannerSharedWithOther == true)
        #expect(try #require(statuses.first { $0.agent == .copilot }).bannerSharedWithOther == true)
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
