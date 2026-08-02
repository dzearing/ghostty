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
                        onSetUp: { Task { await viewModel.setUp(row.agent) } },
                        onUpdate: { Task { await viewModel.update(row.agent) } },
                        onUninstall: { confirmingUninstall = row.agent })
                }
            }

            if viewModel.jqMissing {
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
        } message: { _ in
            Text("This removes the banner script, skills, and hooks Ghoztty installed. Your configuration is otherwise untouched.")
        }
    }
}

private struct AgentIntegrationRow: View {
    let row: AgentIntegrationsViewModel.Row
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
        case .installed: return "Installed"
        case .outdated: return "Update available"
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
