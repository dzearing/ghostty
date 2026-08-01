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
    let requiredDirectory: URL?
    let fileManager: FileManager

    func state() -> RuntimeIntegrationState {
        let states = components.map { $0.state() }
        if states.contains(.notInstalled) { return .notInstalled }
        if states.contains(.outdated) { return .outdated }
        return .installed
    }

    func install() throws {
        if let dir = requiredDirectory {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: dir.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else { throw AgentIntegrationError.notInstalled(agent) }
        }
        var done: [IntegrationComponent] = []
        do {
            for c in components {
                try c.install()
                done.append(c)
            }
        } catch {
            for c in done.reversed() {
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
