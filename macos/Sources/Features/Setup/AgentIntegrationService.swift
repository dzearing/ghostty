// macos/Sources/Features/Setup/AgentIntegrationService.swift
import Foundation

/// A UI-facing snapshot of one runtime's Ghoztty-integration state.
struct AgentStatus: Equatable, Sendable {
    let agent: RuntimeAgent
    /// The runtime's config dir (~/.claude, ~/.copilot) exists on disk.
    let detected: Bool
    let state: RuntimeIntegrationState
    /// Claude only: an external `ghoztty` plugin already owns the hooks.
    let pluginManaged: Bool
}

enum IntegrationOutcome: Equatable {
    case installed, upToDate, upgraded, notFound, pluginPresent, uninstalled, failed(String)

    var label: String {
        switch self {
        case .installed: "installed"
        case .upToDate: "already up to date"
        case .upgraded: "upgraded"
        case .notFound: "not found"
        case .pluginPresent: "plugin already present"
        case .uninstalled: "removed"
        case .failed(let d): "failed — \(d)"
        }
    }
}

enum AgentIntegrationService {
    static func availableAgents(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                                fileManager: FileManager = .default) -> [RuntimeAgent] {
        RuntimeIntegrationFactory.availableAgents(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    }

    static var jqAvailable: Bool {
        (LoginShell.run("command -v jq")?.exitCode ?? 1) == 0
    }

    static func install(agent: RuntimeAgent,
                        homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                        fileManager: FileManager = .default) -> IntegrationOutcome {
        let integ = RuntimeIntegrationFactory.make(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        let prior = integ.state()
        do {
            try integ.install()
        } catch AgentIntegrationError.notInstalled {
            return .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
        let now = integ.state()
        if agent == .claude,
           ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) {
            return .pluginPresent
        }
        switch (prior, now) {
        case (.installed, .installed): return .upToDate
        case (.outdated, .installed): return .upgraded
        case (_, .installed): return .installed
        default: return .failed("post-install state \(now)")
        }
    }

    static func summary(_ results: [(RuntimeAgent, IntegrationOutcome)]) -> String {
        results.map { "\($0.0.displayName): \($0.1.label)" }.joined(separator: " · ")
    }

    static func uninstall(agent: RuntimeAgent,
                          homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                          fileManager: FileManager = .default) -> IntegrationOutcome {
        let integ = RuntimeIntegrationFactory.make(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        do {
            try integ.uninstall()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .uninstalled
    }

    static func allAgentStatuses(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                                 fileManager: FileManager = .default) -> [AgentStatus] {
        RuntimeAgent.allCases.map { agent in
            let dir = agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            var isDir: ObjCBool = false
            let detected = fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
            let integ = RuntimeIntegrationFactory.make(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            let pluginManaged = agent == .claude
                && ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            return AgentStatus(agent: agent, detected: detected, state: integ.state(), pluginManaged: pluginManaged)
        }
    }
}
