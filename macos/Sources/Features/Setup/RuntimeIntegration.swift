// macos/Sources/Features/Setup/RuntimeIntegration.swift
import Foundation
import OSLog

private let integrationLogger = Logger(subsystem: Bundle.loggerSubsystem, category: "AgentIntegration")

struct IntegrationComponent {
    let name: String
    let state: () -> ComponentInstallState
    let install: () throws -> Void
    let uninstall: () throws -> Void
}

enum AgentIntegrationError: Error, Equatable {
    case notInstalled(RuntimeAgent)
}

struct RuntimeIntegration {
    let agent: RuntimeAgent
    let components: [IntegrationComponent]
    /// Whether the runtime is installed at all. A detection signal, NOT the
    /// config dir this writes into — see `RuntimeProbe`. Components create
    /// whatever directories they need, so a CLI that is installed but has never
    /// been run still installs cleanly.
    let isAvailable: () -> Bool
    let fileManager: FileManager

    func state() -> RuntimeIntegrationState {
        let states = components.map { $0.state() }
        if states.contains(.notInstalled) { return .notInstalled }
        if states.contains(.outdated) { return .outdated }
        return .installed
    }

    func install() throws {
        guard isAvailable() else { throw AgentIntegrationError.notInstalled(agent) }

        // Roll back ONLY what this call created. A component that was already
        // installed before we started is left alone: its `install()` was an
        // idempotent rewrite of a file the user already had, so "undoing" it
        // means deleting something this call never created.
        //
        // Without that distinction, a failure in the LAST component wipes the
        // earlier ones on every retry. Concretely: the integration is fully
        // installed, something replaces the hooks file with an unmarked one, the
        // panel offers "Set Up" again, banner and skills rewrite fine, hooks
        // throws `notManaged` — and the rollback deletes the working skills and
        // the shared banner script. Clicking "Set Up" would remove a working
        // install.
        //
        // `.outdated` counts as pre-existing too: the file is the user's, we
        // merely refreshed it, and leaving a newer version behind beats deleting
        // it outright.
        var created: [IntegrationComponent] = []
        do {
            for c in components {
                let existedBefore = c.state() != .notInstalled
                try c.install()
                if !existedBefore { created.append(c) }
            }
        } catch {
            for c in created.reversed() {
                do { try c.uninstall() }
                catch { integrationLogger.error("rollback of \(agent.rawValue)/\(c.name) failed: \(String(describing: error))") }
            }
            throw error
        }
    }

    func uninstall() throws {
        var firstError: Error?
        for c in components.reversed() {
            do { try c.uninstall() }
            catch {
                integrationLogger.error("uninstall of \(agent.rawValue)/\(c.name) failed: \(String(describing: error))")
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
