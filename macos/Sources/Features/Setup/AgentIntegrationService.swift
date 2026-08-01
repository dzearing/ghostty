// macos/Sources/Features/Setup/AgentIntegrationService.swift
import Foundation

enum IntegrationOutcome: Equatable {
    case installed, upToDate, upgraded, notFound, pluginPresent, failed(String)

    var label: String {
        switch self {
        case .installed: "installed"
        case .upToDate: "already up to date"
        case .upgraded: "upgraded"
        case .notFound: "not found"
        case .pluginPresent: "plugin already present"
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
}
