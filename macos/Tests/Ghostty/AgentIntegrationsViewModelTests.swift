import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentIntegrationsViewModelTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rowsShowOfferedAndInstalledAgentsOnly() throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome())
        // Claude is offered (shown even when not installed); Copilot is gated off
        // (isOffered == false) and not installed, so it is hidden (H3).
        #expect(vm.rows.map(\.agent) == [.claude])
    }

    @Test func gatedUndetectedCopilotRowIsHidden() throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome())
        #expect(vm.rows.first { $0.agent == .copilot } == nil)
        let claude = try #require(vm.rows.first { $0.agent == .claude })
        #expect(claude.status.detected == false)
        #expect(claude.status.state == .notInstalled)
        #expect(claude.busy == false)
        #expect(claude.errorText == nil)
    }

    @Test func setUpInstallsAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home)
        await vm.setUp(.copilot)
        // Once installed, a gated agent's row surfaces so it can be managed.
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .installed)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func uninstallRemovesGatedCopilotRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home)
        await vm.setUp(.copilot)
        #expect(vm.rows.first { $0.agent == .copilot }?.status.state == .installed)
        await vm.uninstall(.copilot)
        // Gated + now uninstalled → the row disappears (no new setup offered).
        #expect(vm.rows.first { $0.agent == .copilot } == nil)
    }
}
