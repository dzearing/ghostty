// macos/Sources/Features/Setup/AgentIntegrationService.swift
import Foundation

/// A UI-facing snapshot of one runtime's Ghoztty-integration state.
struct AgentStatus: Equatable, Sendable {
    let agent: RuntimeAgent
    /// The runtime's CLI is installed (a binary probe — NOT "its config dir
    /// exists", which Ghoztty itself creates; see `RuntimeProbe`).
    let detected: Bool
    let state: RuntimeIntegrationState
    /// Claude only: an external `ghoztty` plugin already owns the hooks.
    let pluginManaged: Bool
    /// Another installed agent's hooks also reference the shared banner script,
    /// so uninstalling THIS agent will leave the banner in place. Drives honest
    /// uninstall copy.
    let bannerSharedWithOther: Bool
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
                                fileManager: FileManager = .default,
                                probe: RuntimeProbe = .binary) -> [RuntimeAgent] {
        RuntimeIntegrationFactory.availableAgents(
            homeDirectoryURL: homeDirectoryURL, fileManager: fileManager, probe: probe)
    }

    static var jqAvailable: Bool {
        (LoginShell.run("command -v jq")?.exitCode ?? 1) == 0
    }

    static func install(agent: RuntimeAgent,
                        homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                        fileManager: FileManager = .default,
                        probe: RuntimeProbe = .binary) -> IntegrationOutcome {
        let integ = RuntimeIntegrationFactory.make(
            for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager, probe: probe)
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
                          fileManager: FileManager = .default,
                          probe: RuntimeProbe = .binary) -> IntegrationOutcome {
        // The shared banner is refcounted inside its own component (see
        // RuntimeIntegrationFactory.make): it removes the script only when no
        // agent's hooks still reference it. Uninstall no longer special-cases the
        // banner, so the guarantee holds for ANY caller of
        // RuntimeIntegration.uninstall() — including the install() rollback path.
        let integ = RuntimeIntegrationFactory.make(
            for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager, probe: probe)
        do {
            try integ.uninstall()
        } catch {
            return .failed(error.localizedDescription)
        }
        return .uninstalled
    }

    /// Blocking: the default probe spawns a login shell per runtime. Call it off
    /// the main thread (`AgentIntegrationsViewModel.refresh` does).
    static func allAgentStatuses(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
                                 fileManager: FileManager = .default,
                                 probe: RuntimeProbe = .binary) -> [AgentStatus] {
        RuntimeAgent.allCases.map { agent in
            let detected = probe.isInstalled(agent, homeDirectoryURL)
            let integ = RuntimeIntegrationFactory.make(
                for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager, probe: probe)
            let pluginManaged = agent == .claude
                && ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            let bannerSharedWithOther = RuntimeIntegrationFactory.anyHooksReferenceBanner(
                homeDirectoryURL: homeDirectoryURL, fileManager: fileManager, excluding: agent)
            return AgentStatus(agent: agent, detected: detected, state: integ.state(),
                               pluginManaged: pluginManaged, bannerSharedWithOther: bannerSharedWithOther)
        }
    }
}
