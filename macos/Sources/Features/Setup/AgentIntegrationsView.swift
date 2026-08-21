// macos/Sources/Features/Setup/AgentIntegrationsView.swift
import SwiftUI

struct AgentIntegrationsView: View {
    @ObservedObject var viewModel: AgentIntegrationsViewModel
    let onDone: () -> Void
    @State private var confirmingUninstall: RuntimeAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Integrations").font(.headline)
                Text("Add Ghoztty's status banner, skills, and hooks to your coding agents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    AgentIntegrationRow(
                        row: row,
                        jqMissing: viewModel.jqMissing,
                        onSetUp: { Task { await viewModel.setUp(row.agent) } },
                        onUpdate: { Task { await viewModel.update(row.agent) } },
                        onUninstall: { confirmingUninstall = row.agent })
                }
            }

            // Only nag about jq when a banner actually depends on it — i.e. an
            // integration is installed (or needs updating). With nothing set up,
            // the missing dependency isn't yet the user's problem.
            if viewModel.jqMissing && viewModel.rows.contains(where: { $0.status.state != .notInstalled }) {
                Label("The status banner needs jq — install it with: brew install jq",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            confirmingUninstall.map { "Remove Ghoztty integration from \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { confirmingUninstall != nil },
                set: { if !$0 { confirmingUninstall = nil } }),
            presenting: confirmingUninstall
        ) { agent in
            Button("Remove", role: .destructive) {
                confirmingUninstall = nil
                Task { await viewModel.uninstall(agent) }
            }
            Button("Cancel", role: .cancel) { confirmingUninstall = nil }
        } message: { agent in
            Text(uninstallMessage(for: agent))
        }
    }

    /// Honest, per-situation uninstall copy: the shared banner is kept when
    /// another agent still uses it, and plugin-managed hooks are never touched.
    private func uninstallMessage(for agent: RuntimeAgent) -> String {
        let status = viewModel.rows.first { $0.agent == agent }?.status
        let name = agent.displayName
        if status?.pluginManaged == true {
            return "This removes the skills Ghoztty added for \(name). Its hooks are managed by the Claude plugin and won't be changed. Your \(name) configuration is otherwise untouched."
        }
        if status?.bannerSharedWithOther == true {
            return "This removes the skills and hooks Ghoztty added for \(name). The shared status-banner script stays because another agent still uses it. Your \(name) configuration is otherwise untouched."
        }
        return "This removes the banner script, skills, and hooks Ghoztty installed. Your \(name) configuration is otherwise untouched."
    }
}

private struct AgentIntegrationRow: View {
    let row: AgentIntegrationsViewModel.Row
    let jqMissing: Bool
    let onSetUp: () -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.agent.displayName)
                    .foregroundStyle(row.status.detected ? .primary : .secondary)
                Text(statusLabel).font(.footnote).foregroundStyle(.secondary)
                if row.status.pluginManaged {
                    Text("Hooks managed by Claude plugin").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = row.errorText {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Spacer()
            if row.busy {
                ProgressView().controlSize(.small)
            } else {
                actions
            }
        }
        .padding(.vertical, 10)
    }

    private var statusLabel: String {
        guard row.status.detected else { return "Not detected — install \(row.agent.displayName) to enable" }
        switch row.status.state {
        case .notInstalled: return "Not set up"
        // When jq is missing the banner script exits without painting, so an
        // "Installed" row would be misleading — say so on the row itself rather
        // than relying on the separate footnote.
        case .installed: return jqMissing ? "Installed — banner inactive (install jq)" : "Installed"
        case .outdated: return jqMissing ? "Update available — banner inactive (install jq)" : "Update available"
        }
    }

    @ViewBuilder private var actions: some View {
        if row.status.detected {
            switch row.status.state {
            case .notInstalled:
                Button("Set Up", action: onSetUp)
            case .installed:
                Button("Uninstall", role: .destructive, action: onUninstall)
            case .outdated:
                Button("Update", action: onUpdate)
                Button("Uninstall", role: .destructive, action: onUninstall)
            }
        }
    }
}
