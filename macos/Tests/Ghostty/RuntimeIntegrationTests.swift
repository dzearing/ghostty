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
        #expect(integ([.outdated, .notInstalled]).state() == .notInstalled)
    }

    @Test func gateThrowsWhenDirAbsent() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString)")
        var ran = false
        let integ = RuntimeIntegration(
            agent: .copilot,
            components: [comp("x", .notInstalled, install: { ran = true })],
            requiredDirectory: missing, fileManager: .default)
        #expect { try integ.install() } throws: { $0 as? AgentIntegrationError == .notInstalled(.copilot) }
        #expect(!ran)
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

    @Test func uninstallReversesAndRethrowsFirst() {
        struct E1: Error, Equatable {}
        struct E2: Error, Equatable {}
        var order: [String] = []
        let integ = RuntimeIntegration(
            agent: .copilot,
            components: [
                comp("a", .installed, uninstall: { order.append("a"); throw E1() }),
                comp("b", .installed, uninstall: { order.append("b"); throw E2() }),
            ],
            requiredDirectory: nil, fileManager: .default)
        // Reverse sweep: b runs first (throws E2 = first error), then a (throws E1).
        // The implementation rethrows the first error encountered, which is E2.
        #expect(throws: E2.self) { try integ.uninstall() }
        #expect(order == ["b", "a"])
    }
}
