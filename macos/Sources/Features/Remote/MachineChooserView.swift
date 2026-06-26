import SwiftUI
import AppKit

/// The result of the window-target chooser: either a normal local window or a
/// specific remote `Machine`.
enum WindowTarget: Hashable {
    case local
    case remote(Machine)
}

/// A simple, filterable chooser for picking where to open a new window: the
/// local machine or a registered remote `Machine`. Modeled on the command
/// palette's list/sheet pattern but intentionally minimal. Invokes `onSelect`
/// with the chosen target (or `onCancel` if dismissed).
struct MachineChooserView: View {
    let machines: [Machine]
    var onSelect: (WindowTarget) -> Void
    var onCancel: () -> Void

    @State private var query: String = ""
    @State private var selection: WindowTarget?

    /// Filtered remote machines based on the search query.
    private var filteredMachines: [Machine] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return machines }
        return machines.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.host.localizedCaseInsensitiveContains(q)
        }
    }

    /// Whether the "Local" entry matches the current query (always shown when
    /// the query is empty, or when it matches "local").
    private var showsLocal: Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || "local".localizedCaseInsensitiveContains(q)
    }

    /// The ordered list of targets shown in the list: "Local" first, then the
    /// filtered remote machines.
    private var targets: [WindowTarget] {
        var result: [WindowTarget] = []
        if showsLocal { result.append(.local) }
        result.append(contentsOf: filteredMachines.map { .remote($0) })
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Window")
                .font(.headline)
                .padding([.top, .horizontal], 16)
                .padding(.bottom, 8)

            TextField("Filter machines…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .onSubmit { submit() }

            List(selection: $selection) {
                ForEach(targets, id: \.self) { target in
                    row(for: target)
                        .contentShape(Rectangle())
                        .tag(target)
                        .onTapGesture(count: 2) { onSelect(target) }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolvedSelection == nil)
            }
            .padding(16)
        }
        .frame(width: 420)
        .onAppear {
            // Preselect the first target for immediate Enter-to-open.
            if selection == nil { selection = targets.first }
        }
    }

    @ViewBuilder
    private func row(for target: WindowTarget) -> some View {
        switch target {
        case .local:
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local")
                        .font(.body)
                    Text("This machine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        case .remote(let machine):
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
        }
    }

    /// The currently selected target, falling back to the first row.
    private var resolvedSelection: WindowTarget? {
        if let selection, targets.contains(selection) {
            return selection
        }
        return targets.first
    }

    private func submit() {
        if let target = resolvedSelection {
            onSelect(target)
        }
    }
}

/// Presents the window-target chooser as an application-modal sheet/window and
/// calls `completion` with the chosen target, or nil if the user cancelled.
///
/// The chooser always lists a "Local" entry first (a normal local window),
/// followed by every registered remote machine. It is shown whenever there is at
/// least one registered machine — even a single machine — so the user always has
/// the Local-vs-remote choice. Callers should special-case the zero-machine case
/// before calling this (e.g. just open a local window directly).
@MainActor
enum MachineChooser {
    static func present(
        machines: [Machine],
        completion: @escaping (WindowTarget?) -> Void
    ) {
        var windowRef: NSWindow?

        let finish: (WindowTarget?) -> Void = { target in
            if let windowRef {
                NSApp.stopModal()
                windowRef.orderOut(nil)
            }
            completion(target)
        }

        let view = MachineChooserView(
            machines: machines,
            onSelect: { finish($0) },
            onCancel: { finish(nil) }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "New Window"
        window.isReleasedWhenClosed = false
        window.center()
        windowRef = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }
}
