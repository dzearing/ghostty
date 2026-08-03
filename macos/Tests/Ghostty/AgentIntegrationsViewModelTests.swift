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

    @Test func rowsCoverAllAgentTypes() throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome())
        #expect(vm.rows.map(\.agent) == RuntimeAgent.allCases)
    }

    @Test func undetectedAgentRowIsNotDetected() throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome())
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.detected == false)
        #expect(copilot.status.state == .notInstalled)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func setUpInstallsAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home)
        await vm.setUp(.copilot)
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .installed)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func uninstallRemovesAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home)
        await vm.setUp(.copilot)
        await vm.uninstall(.copilot)
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .notInstalled)
        #expect(copilot.errorText == nil)
    }
}
