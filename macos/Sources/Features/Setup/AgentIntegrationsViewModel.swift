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
    private let probe: RuntimeProbe

    init(homeDirectoryURL: URL = URL(fileURLWithPath: LoginShell.homePath),
         probe: RuntimeProbe = .binary) {
        self.homeDirectoryURL = homeDirectoryURL
        self.probe = probe
        Task { await refresh() }
    }

    /// Re-read every agent's state, preserving per-row busy and error text.
    ///
    /// The read itself runs OFF the main actor. Both halves of it shell out —
    /// `jqAvailable` and the runtime probe each spawn `zsh -l -i`, whose own doc
    /// comment says "Blocking: run off the main thread" — so doing this inline
    /// froze the UI for as long as the user's shell profile takes to load, on
    /// every window open and after every install. `AppDelegate+Setup` already
    /// dispatches its `LoginShell` work this way.
    func refresh() async {
        let home = homeDirectoryURL
        let probe = probe
        let (statuses, jq) = await Task.detached(priority: .userInitiated) {
            (AgentIntegrationService.allAgentStatuses(homeDirectoryURL: home, probe: probe),
             AgentIntegrationService.jqAvailable)
        }.value

        let prior = Dictionary(rows.map { ($0.agent, $0) }, uniquingKeysWith: { a, _ in a })
        rows = statuses.map { status in
            Row(agent: status.agent,
                status: status,
                busy: prior[status.agent]?.busy ?? false,
                errorText: prior[status.agent]?.errorText)
        }
        jqMissing = !jq
    }

    func setUp(_ agent: RuntimeAgent) async {
        let probe = probe
        await run(agent) { home in
            AgentIntegrationService.install(agent: agent, homeDirectoryURL: home, fileManager: .default, probe: probe)
        }
    }

    func update(_ agent: RuntimeAgent) async { await setUp(agent) }

    func uninstall(_ agent: RuntimeAgent) async {
        let probe = probe
        await run(agent) { home in
            AgentIntegrationService.uninstall(agent: agent, homeDirectoryURL: home, fileManager: .default, probe: probe)
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
        await refresh()
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
