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
}
