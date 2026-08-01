// macos/Tests/Ghostty/RuntimeIntegrationTests.swift
import Foundation
import Testing
@testable import Ghostty

struct RuntimeIntegrationTests {
    private func comp(_ name: String, _ s: ComponentInstallState, install: @escaping () throws -> Void = {}, uninstall: @escaping () throws -> Void = {}) -> IntegrationComponent {
        IntegrationComponent(name: name, state: { s }, install: install, uninstall: uninstall)
    }

    @Test func aggregationRule() {
        func integ(_ states: [ComponentInstallState]) -> RuntimeIntegration {
            RuntimeIntegration(agent: .copilot, components: states.enumerated().map { comp("\($0.0)", $0.1) }, requiredDirectory: nil, fileManager: .default)
        }
        #expect(integ([.installed, .installed]).state() == .installed)
        #expect(integ([.installed, .notInstalled]).state() == .notInstalled)
        #expect(integ([.installed, .outdated]).state() == .outdated)
    }

    @Test func gateThrowsWhenDirAbsent() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString)")
        let integ = RuntimeIntegration(agent: .copilot, components: [comp("x", .notInstalled)], requiredDirectory: missing, fileManager: .default)
        #expect(throws: AgentIntegrationError.self) { try integ.install() }
    }

    @Test func rollbackOnPartialFailure() throws {
        var firstInstalled = false
        var firstRolledBack = false
        struct Boom: Error {}
        let integ = RuntimeIntegration(
            agent: .copilot,
            components: [
                comp("first", .notInstalled, install: { firstInstalled = true }, uninstall: { firstRolledBack = true }),
                comp("second", .notInstalled, install: { throw Boom() }),
            ],
            requiredDirectory: nil, fileManager: .default)
        #expect(throws: Boom.self) { try integ.install() }
        #expect(firstInstalled)
        #expect(firstRolledBack)
    }
}
