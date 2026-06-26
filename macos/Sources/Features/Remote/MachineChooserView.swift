import SwiftUI
import AppKit

/// A simple, filterable chooser for picking a remote `Machine`. Modeled on the
/// command palette's list/sheet pattern but intentionally minimal for the first
/// launchable build. Invokes `onSelect` with the chosen machine (or `onCancel`
/// if dismissed).
struct MachineChooserView: View {
    let machines: [Machine]
    var onSelect: (Machine) -> Void
    var onCancel: () -> Void

    @State private var query: String = ""
    @State private var selection: Machine.ID?

    private var filtered: [Machine] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return machines }
        return machines.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.host.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open Remote Window")
                .font(.headline)
                .padding([.top, .horizontal], 16)
                .padding(.bottom, 8)

            TextField("Filter machines…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .onSubmit { submit() }

            List(selection: $selection) {
                ForEach(filtered) { machine in
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.name)
                                .font(.body)
                            Text(machine.endpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .tag(machine.id)
                    .onTapGesture(count: 2) {
                        onSelect(machine)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolvedSelection == nil)
            }
            .padding(16)
        }
        .frame(width: 420)
        .onAppear {
            // Preselect the first machine for immediate Enter-to-connect.
            if selection == nil { selection = filtered.first?.id }
        }
    }

    /// The currently selected machine, falling back to the first filtered row.
    private var resolvedSelection: Machine? {
        if let selection, let m = machines.first(where: { $0.id == selection }) {
            return m
        }
        return filtered.first
    }

    private func submit() {
        if let m = resolvedSelection {
            onSelect(m)
        }
    }
}

/// Presents the machine chooser as an application-modal sheet/window and calls
/// `completion` with the chosen machine, or nil if the user cancelled.
///
/// If the registry has exactly one machine, the chooser is skipped and that
/// machine is returned immediately (faster first-build flow). The chooser is
/// still built for when several machines are configured.
@MainActor
enum MachineChooser {
    static func present(
        machines: [Machine],
        completion: @escaping (Machine?) -> Void
    ) {
        guard !machines.isEmpty else {
            completion(nil)
            return
        }

        // Skip the dialog when there's only one machine.
        if machines.count == 1 {
            completion(machines[0])
            return
        }

        var windowRef: NSWindow?

        let finish: (Machine?) -> Void = { machine in
            if let windowRef {
                NSApp.stopModal()
                windowRef.orderOut(nil)
            }
            completion(machine)
        }

        let view = MachineChooserView(
            machines: machines,
            onSelect: { finish($0) },
            onCancel: { finish(nil) }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "Open Remote Window"
        window.isReleasedWhenClosed = false
        window.center()
        windowRef = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }
}
