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

    @Test func availabilityFollowsConfigDir() throws {
        let home = try tempHome()
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default).isEmpty)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        #expect(RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: home, fileManager: .default) == [.copilot])
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
}
