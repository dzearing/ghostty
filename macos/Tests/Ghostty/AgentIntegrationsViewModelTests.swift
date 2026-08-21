import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentIntegrationsViewModelTests {
    /// Availability is a binary probe, so these temp-home tests state which
    /// runtimes exist rather than inheriting whatever CLIs the machine has.
    private let both = RuntimeProbe.stub([.claude, .copilot])
    private let neither = RuntimeProbe.stub([])

    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `refresh()` is awaited explicitly: it runs off the main actor now (it
    /// shells out), so `init`'s kick-off has not necessarily landed by the time
    /// a test reads `rows`.
    @Test func rowsCoverAllAgentTypes() async throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome(), probe: both)
        await vm.refresh()
        #expect(vm.rows.map(\.agent) == RuntimeAgent.allCases)
    }

    @Test func undetectedAgentRowIsNotDetected() async throws {
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: try tempHome(), probe: neither)
        await vm.refresh()
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.detected == false)
        #expect(copilot.status.state == .notInstalled)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func setUpInstallsAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home, probe: both)
        await vm.refresh()
        await vm.setUp(.copilot)
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .installed)
        #expect(copilot.busy == false)
        #expect(copilot.errorText == nil)
    }

    @Test func uninstallRemovesAndUpdatesRow() async throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let vm = AgentIntegrationsViewModel(homeDirectoryURL: home, probe: both)
        await vm.refresh()
        await vm.setUp(.copilot)
        await vm.uninstall(.copilot)
        let copilot = try #require(vm.rows.first { $0.agent == .copilot })
        #expect(copilot.status.state == .notInstalled)
        #expect(copilot.errorText == nil)
    }
}
