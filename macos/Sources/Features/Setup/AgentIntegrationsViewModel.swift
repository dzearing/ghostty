// macos/Sources/Features/Setup/AgentIntegrationsViewModel.swift
import Foundation

/// Drives the Agent Integrations window. Holds all logic so the view stays
/// declarative and the behavior is unit-testable without an NSWindow.
@MainActor
final class AgentIntegrationsViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let agent: RuntimeAgent
        var status: AgentStatus
        var busy: Bool = false
        var errorText: String?
        var id: String { agent.rawValue }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var jqMissing: Bool = false

    private let homeDirectoryURL: URL

    init(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath)) {
        self.homeDirectoryURL = homeDirectoryURL
        refresh()
    }

    /// Re-read every agent's state from disk, preserving per-row busy and error text.
    func refresh() {
        let prior = Dictionary(rows.map { ($0.agent, $0) }, uniquingKeysWith: { a, _ in a })
        rows = AgentIntegrationService
            .allAgentStatuses(homeDirectoryURL: homeDirectoryURL)
            // Gated runtimes (isOffered == false) are hidden unless already
            // installed, so an existing install stays manageable (updatable /
            // removable) but no new setup is offered for it.
            .filter { $0.agent.isOffered || $0.state != .notInstalled }
            .map { status in
                Row(agent: status.agent,
                    status: status,
                    busy: prior[status.agent]?.busy ?? false,
                    errorText: prior[status.agent]?.errorText)
            }
        jqMissing = !AgentIntegrationService.jqAvailable
    }

    func setUp(_ agent: RuntimeAgent) async {
        await run(agent) { home in
            AgentIntegrationService.install(agent: agent, homeDirectoryURL: home, fileManager: .default)
        }
    }

    func update(_ agent: RuntimeAgent) async { await setUp(agent) }

    func uninstall(_ agent: RuntimeAgent) async {
        await run(agent) { home in
            AgentIntegrationService.uninstall(agent: agent, homeDirectoryURL: home, fileManager: .default)
        }
    }

    private func run(_ agent: RuntimeAgent,
                     _ work: @escaping @Sendable (URL) -> IntegrationOutcome) async {
        setBusy(agent, true)
        let home = homeDirectoryURL
        let outcome = await Task.detached { work(home) }.value
        setBusy(agent, false)
        if case .failed(let message) = outcome {
            setError(agent, message)
        } else {
            setError(agent, nil)
        }
        refresh()
    }

    private func setBusy(_ agent: RuntimeAgent, _ value: Bool) {
        guard let i = rows.firstIndex(where: { $0.agent == agent }) else { return }
        rows[i].busy = value
    }

    private func setError(_ agent: RuntimeAgent, _ text: String?) {
        guard let i = rows.firstIndex(where: { $0.agent == agent }) else { return }
        rows[i].errorText = text
    }
}
