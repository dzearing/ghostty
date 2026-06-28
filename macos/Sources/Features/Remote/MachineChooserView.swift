import SwiftUI
import AppKit

/// The result of the window-target chooser: either a normal local window or a
/// specific remote `Machine`.
enum WindowTarget: Hashable {
    case local
    case remote(Machine)
}

/// A native, filterable chooser for picking where to open a new window: the
/// local machine or a registered remote `Machine`. Modeled on the command
/// palette's keyboard pattern: the filter field keeps focus for typing, while
/// invisible Up/Down shortcut buttons move the highlighted selection in the
/// list, Return opens the highlighted row, and Escape cancels. Invokes
/// `onSelect` with the chosen target (or `onCancel` if dismissed).
struct MachineChooserView: View {
    let machines: [Machine]
    /// Live per-machine metrics for the remote rows, refreshed while the picker
    /// is open. Drives each remote row's subline in place of the IP:port.
    @ObservedObject var probe: MachineMetricsProbe
    var onSelect: (WindowTarget) -> Void
    var onCancel: () -> Void
    /// Secondary action: open the Remote Activity Monitor for a machine instead of
    /// a window. Triggered by the per-row chart button.
    var onActivityMonitor: (Machine) -> Void

    @State private var query: String = ""
    /// Index into `targets` of the highlighted row. Bound to `List(selection:)`
    /// so the native selection highlight + focus ring track the keyboard.
    @State private var selectedIndex: Int = 0
    @FocusState private var isFilterFocused: Bool

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

    /// The currently highlighted target, clamped to a valid row.
    private var resolvedSelection: WindowTarget? {
        guard !targets.isEmpty else { return nil }
        let i = min(max(selectedIndex, 0), targets.count - 1)
        return targets[i]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Window")
                .font(.headline)
                .padding([.top, .horizontal], 16)
                .padding(.bottom, 8)

            // Invisible shortcut buttons that drive list navigation from the
            // keyboard regardless of which control has focus. Mirrors the
            // command-palette pattern so arrows move the selection even while
            // the filter field is focused for typing.
            ZStack {
                Group {
                    Button { move(-1) } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { move(1) } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { move(-1) } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.init("p"), modifiers: [.control])
                    Button { move(1) } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.init("n"), modifiers: [.control])
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                TextField("Filter machines…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFilterFocused)
                    .onSubmit { submit() }
                    .onChange(of: query) { _ in
                        // Keep the selection valid as the filtered list changes.
                        clampSelection()
                    }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            List(selection: Binding(
                get: { resolvedSelection },
                set: { newValue in
                    if let newValue, let idx = targets.firstIndex(of: newValue) {
                        selectedIndex = idx
                    }
                }
            )) {
                ForEach(Array(targets.enumerated()), id: \.element) { _, target in
                    row(for: target)
                        .contentShape(Rectangle())
                        .tag(target)
                        .onTapGesture(count: 2) { onSelect(target) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 180)

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
        .frame(width: 440)
        .onAppear {
            // Preselect the first target so something is highlighted on open
            // and Enter immediately opens it.
            selectedIndex = 0
            // Focus the filter so typing narrows the list right away. Arrow
            // navigation still works via the invisible shortcut buttons above.
            // Dispatch to the next runloop turn so focus actually sticks
            // (matches the command-palette workaround).
            DispatchQueue.main.async {
                isFilterFocused = true
            }
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
                    metricsSubline(for: machine)
                }
                Spacer()
                // Secondary affordance: open the Activity Monitor for this machine
                // (dials a fresh connection). Selecting the row still opens a window.
                Button {
                    onActivityMonitor(machine)
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.borderless)
                .help("Open Activity Monitor for \(machine.name)")
            }
        }
    }

    /// The remote-row subline: live CPU/memory once metrics arrive, or a
    /// graceful placeholder while connecting / when unreachable. Deliberately
    /// never shows the host:port (the user does not want the IP displayed).
    private func metricsSubline(for machine: Machine) -> some View {
        Text(sublineText(for: machine))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The text shown in a remote row's subline for the machine's probe state.
    private func sublineText(for machine: Machine) -> String {
        switch probe.readings[machine.id] {
        case .live(let m):
            return "CPU \(Int(m.cpuPct.rounded()))%  ·  \(memString(m.memUsed)) / \(memString(m.memTotal))"
        case .failed:
            return "Unreachable"
        case .connecting, nil:
            return "Connecting…"
        }
    }

    /// Format a byte count as gigabytes with one decimal (e.g. "12.3 GB").
    private func memString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gb)
    }

    /// Move the highlighted selection by `delta` rows, clamped to the list.
    private func move(_ delta: Int) {
        guard !targets.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), targets.count - 1)
    }

    /// Clamp `selectedIndex` to the current (possibly newly filtered) list.
    private func clampSelection() {
        guard !targets.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex, 0), targets.count - 1)
    }

    private func submit() {
        if let target = resolvedSelection {
            onSelect(target)
        }
    }
}

/// Presents the window-target chooser as an application-modal panel centered on
/// the active (key) window — or the main screen if there is none — and calls
/// `completion` with the chosen target, or nil if the user cancelled.
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
        // Capture the window we're presenting over BEFORE we activate/raise our
        // own panel, so we can center on it.
        let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow

        var windowRef: NSWindow?

        // Live metrics probe for the picker's lifetime. Owns one short-lived
        // connection per remote machine; torn down in `finish` regardless of
        // outcome (pick remote, pick Local, or cancel).
        let probe = MachineMetricsProbe()

        let finish: (WindowTarget?) -> Void = { target in
            // Tear down all probe connections BEFORE handing control back, so
            // no probe connection outlives the picker no matter the choice.
            probe.stop()
            if let windowRef {
                NSApp.stopModal()
                windowRef.orderOut(nil)
            }
            completion(target)
        }

        let view = MachineChooserView(
            machines: machines,
            probe: probe,
            onSelect: { finish($0) },
            onCancel: { finish(nil) },
            onActivityMonitor: { machine in
                // Dismiss the chooser (tearing down its probes via `finish`) and
                // open the Activity Monitor on a freshly-dialed connection.
                finish(nil)
                RemoteActivityMonitor.presentDialing(machine: machine)
            }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSPanel(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "New Window"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        windowRef = window

        // Center the panel over the anchor window (or the active screen). We
        // size-to-fit first so the centering math uses the real frame.
        window.layoutIfNeeded()
        let panelSize = window.frame.size
        if let anchor = anchorWindow {
            let a = anchor.frame
            let origin = NSPoint(
                x: a.midX - panelSize.width / 2,
                y: a.midY - panelSize.height / 2
            )
            window.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let origin = NSPoint(
                x: v.midX - panelSize.width / 2,
                y: v.midY - panelSize.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Begin probing remote machines for live metrics now that the picker is
        // on screen. Dials happen off the main thread; rows update as samples
        // arrive (or fall back to "Unreachable").
        probe.start(machines)
        NSApp.runModal(for: window)
    }
}
