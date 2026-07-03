import SwiftUI
import AppKit

/// The result of the window-target chooser: either a normal local window or a
/// specific remote `Machine`.
enum WindowTarget: Hashable {
    case local
    case remote(Machine)
    /// Restore the machine's recoverable manifest windows (WP-D2 entries with
    /// a session to re-`ATTACH` that aren't bound to an open window) instead
    /// of opening a new one. Produced by the chooser's contextual "Restore"
    /// primary action; never shown as a list row.
    case restoreRemote(Machine)
}

/// A native, filterable chooser for picking where to open a new window: the
/// local machine or a registered remote `Machine`. Modeled on the command
/// palette's keyboard pattern: the filter field keeps focus for typing, while
/// invisible Up/Down shortcut buttons move the highlighted selection in the
/// list, Return triggers the highlighted row's primary action (New — or
/// Restore when the machine has recoverable windows), and Escape cancels.
/// Invokes `onSelect` with the chosen target (or `onCancel` if dismissed).
struct MachineChooserView: View {
    /// Source of the machine list. Observed (not a snapshot) so rows update
    /// live as the account device list is fetched from the relay on open
    /// (WP-C2) and as rows are renamed/removed.
    @ObservedObject var registry: MachineRegistry
    /// Live per-machine metrics for the remote rows, refreshed while the picker
    /// is open. Drives each remote row's subline in place of the IP:port.
    @ObservedObject var probe: MachineMetricsProbe
    var onSelect: (WindowTarget) -> Void
    var onCancel: () -> Void
    /// Secondary action: open the Remote Activity Monitor for a machine instead of
    /// a window. Triggered by the per-row chart button.
    var onActivityMonitor: (Machine) -> Void

    /// Signed-in Google account state for the footer row (WP-B2). Observed so
    /// the row flips between "Sign in with Google…" and "<email> · Sign Out"
    /// as sign-in completes.
    @ObservedObject var account: RelayAccount

    @State private var query: String = ""
    /// True while the browser sign-in flow is running (shows the spinner row).
    @State private var isSigningIn = false
    /// Index into `targets` of the highlighted row. Bound to `List(selection:)`
    /// so the native selection highlight + focus ring track the keyboard.
    @State private var selectedIndex: Int = 0
    /// Index of the row currently under the pointer (for hover feedback).
    @State private var hoveredIndex: Int?
    @FocusState private var isFilterFocused: Bool

    /// The background for row `idx`: accent when selected, a faint wash on hover,
    /// else clear. Drives the manual selection/hover highlight.
    @ViewBuilder
    private func rowHighlight(_ idx: Int) -> some View {
        if selectedIndex == idx {
            Color.accentColor.opacity(0.25)
        } else if hoveredIndex == idx {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }

    /// The current machine list (live from the registry), minus any relay
    /// device that IS this Mac: it duplicates the pinned "Local — This machine"
    /// row, so it is hidden from the chooser. Display-only filtering — the
    /// machine stays in `MachineRegistry` (it is still an account resource that
    /// other surfaces/management may need).
    private var machines: [Machine] {
        registry.machines.filter { !($0.isRelay && $0.isLocalMachine) }
    }

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
            // No in-content header: the panel titlebar already says
            // "New Window" — repeating it inside the content just wasted
            // vertical space.

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
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 8)

            // Rows are a ScrollView+VStack, NOT a `List`: a SwiftUI List swallows
            // row taps for its own selection machinery, so `.onTapGesture` there
            // never fired (single-click select was dead; only the explicit
            // double-click gesture worked). In a plain VStack the tap reliably
            // fires. Selection is driven manually off `selectedIndex`; a single tap
            // selects, a double tap opens, `.onHover` gives feedback.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(targets.enumerated()), id: \.element) { idx, target in
                        HStack(spacing: 0) {
                            // The main row area is a Button so a single click
                            // reliably SELECTS (a SwiftUI `.onTapGesture` here did
                            // not respond to clicks; a Button action does). A double
                            // click opens via a simultaneous gesture.
                            Button {
                                selectedIndex = idx
                            } label: {
                                row(for: target)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Double-click follows the PRIMARY action for the
                            // row (New or Restore), not always "new", so it
                            // stays consistent with the footer button.
                            .simultaneousGesture(TapGesture(count: 2).onEnded { activate(target) })

                            // Secondary affordance (remote only): open the Activity
                            // Monitor. A SIBLING button so it doesn't nest inside the
                            // selection button.
                            if case .remote(let machine) = target {
                                Button {
                                    onActivityMonitor(machine)
                                } label: {
                                    Image(systemName: "chart.bar.xaxis")
                                }
                                .buttonStyle(.borderless)
                                .help("Open Activity Monitor for \(machine.name)")
                                .padding(.trailing, 6)

                                // Account-resource management (relay devices
                                // only, WP-C2): rename or remove the host.
                                if machine.isRelay {
                                    Menu {
                                        managementActions(for: machine)
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .help("Manage \(machine.name)")
                                    .padding(.trailing, 6)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(rowHighlight(idx))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onHover { hovering in hoveredIndex = hovering ? idx : nil }
                        .contextMenu {
                            if case .remote(let machine) = target, machine.isRelay {
                                managementActions(for: machine)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minHeight: 180)
            .onChange(of: machines) { _ in
                // Keep the highlighted row valid as the account fetch or a
                // removal changes the list.
                clampSelection()
            }

            // Account-list refresh status (WP-C2): a small spinner while the
            // device directory is being fetched, or the fetch error. Never
            // blocks the list — existing rows stay usable.
            if registry.isRefreshing || registry.lastRefreshError != nil {
                HStack(spacing: 6) {
                    if registry.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing devices…")
                    } else if let err = registry.lastRefreshError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Couldn't refresh devices: \(err)")
                            .lineLimit(2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            // Hairline separating the machine list from the footer row.
            Divider()
                .padding(.top, 8)

            // Footer: account area (avatar + email + Sign Out, or Sign In)
            // left-aligned; Cancel + the primary button right-aligned. The
            // primary button reads "New" (it creates a new window) — or
            // "Restore"/"Restore (N)" when the highlighted machine has
            // recoverable windows. Recomputed on every render, so it live-
            // updates as the selection moves.
            HStack {
                accountRow
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryButtonTitle) { submit() }
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

    /// The account footer (WP-B2): avatar + email + a standard "Sign Out"
    /// button when signed in, a standard "Sign In with Google" button when
    /// signed out, a spinner while the browser flow runs, or a pointer to the
    /// setup doc when no Google client id is configured. Plain bordered
    /// buttons, styled like Cancel/New — no link styling or cursor hacks.
    @ViewBuilder
    private var accountRow: some View {
        if let email = account.email {
            HStack(spacing: 8) {
                avatar(for: email)
                Text(email)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help("Signed in as \(email)")
                Button("Sign Out") { account.signOut() }
            }
        } else if isSigningIn {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for browser sign-in…")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } else if RelayAccount.isConfigured {
            Button("Sign In with Google") { startSignIn() }
        } else {
            Text("Google client not configured — see docs/design/relay-oidc-setup.md")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    /// The signed-in avatar: the Google profile photo when the session has a
    /// `picture` claim (loaded asynchronously; AsyncImage's shared URLSession
    /// caches it in URLCache), falling back to the monogram while loading or
    /// when absent — e.g. a session signed in before the `profile` scope was
    /// requested has no picture until the user re-signs in.
    @ViewBuilder
    private func avatar(for email: String) -> some View {
        Group {
            if let url = account.pictureURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        monogram(for: email)
                    }
                }
            } else {
                monogram(for: email)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(Circle())
        .accessibilityLabel("Signed in as \(email)")
    }

    /// A Google-style monogram circle: the email's first letter on an accent
    /// gradient. The no-network fallback for the avatar.
    private func monogram(for email: String) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom))
            Text(String(email.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Run the browser sign-in flow, then refresh the device list so the
    /// chooser fills with the account's machines.
    private func startSignIn() {
        isSigningIn = true
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                try await account.signIn()
                await registry.refreshFromRelay()
            } catch {
                showError(title: "Google sign-in failed", error: error)
            }
        }
    }

    /// Fixed width of the leading status-indicator column. Reserved in EVERY
    /// row (an empty spacer for Local/TCP rows) so the icon and text columns
    /// line up across all row types.
    private static let statusColumnWidth: CGFloat = 12
    /// Fixed width of the leading machine-glyph column. The glyphs differ in
    /// intrinsic width (laptop vs server.rack), so without this the name/
    /// subtext column drifts per row.
    private static let iconColumnWidth: CGFloat = 28

    @ViewBuilder
    private func row(for target: WindowTarget) -> some View {
        switch target {
        case .local:
            HStack(spacing: 8) {
                // Empty status slot: keeps the icon/text columns aligned with
                // the device rows (which carry a status indicator here).
                Color.clear
                    .frame(width: Self.statusColumnWidth, height: 1)
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconColumnWidth)
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
            HStack(spacing: 8) {
                statusIndicator(for: machine)
                // A machine that IS this Mac gets the laptop glyph (matching
                // the "Local" row) plus a "this Mac" tag, so it doesn't read
                // as a mystery duplicate of "Local". Only non-relay (direct
                // TCP loopback) entries can hit this: relay devices for this
                // Mac are filtered out of `machines` entirely.
                Image(systemName: machine.isLocalMachine ? "laptopcomputer" : "server.rack")
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconColumnWidth)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(machine.name)
                            .font(.body)
                        if machine.isLocalMachine {
                            Text("this Mac")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        }
                    }
                    subline(for: machine)
                }
                Spacer()
                // (The Activity-Monitor chart affordance is rendered as a sibling
                // button in the row wrapper, NOT here, so it doesn't nest inside the
                // row's selection button.)
            }
        case .restoreRemote:
            // Never appears in `targets`; it's an action result, not a row.
            EmptyView()
        }
    }

    /// The leading status column for a device row. For relay machines the
    /// status is SHAPE-coded, not just color-coded (colorblind-safe): online
    /// is a filled circle with an inner ring mark (`circle.inset.filled`,
    /// green), offline a HOLLOW circle (`circle`, gray), unknown (pre-fetch) a
    /// dotted outline (`circle.dotted`). Non-relay rows get an equally sized
    /// empty slot so all rows share one column grid.
    @ViewBuilder
    private func statusIndicator(for machine: Machine) -> some View {
        if machine.isRelay {
            Group {
                switch machine.online {
                case true:
                    Image(systemName: "circle.inset.filled")
                        .foregroundStyle(.green)
                case false:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                default:
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .frame(width: Self.statusColumnWidth)
            .accessibilityLabel(statusText(for: machine))
            .help(statusText(for: machine))
        } else {
            Color.clear
                .frame(width: Self.statusColumnWidth, height: 1)
        }
    }

    /// Accessible description of a relay machine's directory status. Spoken /
    /// tooltip only — the row never renders "Online"/"Offline" as text; the
    /// leading shape indicator conveys it.
    private func statusText(for machine: Machine) -> String {
        switch machine.online {
        case true: return "Online"
        case false: return "Offline"
        default: return "Status unknown"
        }
    }

    /// The rename/remove actions for an account (relay) device, shared by the
    /// per-row ellipsis menu and the row's context menu (WP-C2).
    @ViewBuilder
    private func managementActions(for machine: Machine) -> some View {
        Button("Rename…") { promptRename(machine) }
        Divider()
        Button("Remove from Account…", role: .destructive) { confirmRemove(machine) }
    }

    /// Ask for confirmation, then delete the device from the relay account
    /// (revoking its credential) and drop its row. Errors (401/404/network)
    /// surface as an alert, never a crash. NSAlert is used (not a SwiftUI
    /// sheet) because the chooser panel runs an AppKit modal session.
    private func confirmRemove(_ machine: Machine) {
        guard let deviceID = machine.deviceID else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(machine.name)” from your account?"
        alert.informativeText = "This deletes the device from the relay and revokes its credential. The agent on that machine will no longer be able to connect."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            do {
                try await registry.removeFromAccount(deviceID: deviceID)
            } catch {
                showError(title: "Couldn't remove “\(machine.name)”", error: error)
            }
            clampSelection()
        }
    }

    /// Prompt for a new name and rename the device on the relay account.
    /// Errors surface as an alert.
    private func promptRename(_ machine: Machine) {
        guard let deviceID = machine.deviceID else { return }

        let alert = NSAlert()
        alert.messageText = "Rename “\(machine.name)”"
        alert.informativeText = "Enter a new name for this device."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = machine.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != machine.name else { return }

        Task { @MainActor in
            do {
                try await registry.renameOnAccount(deviceID: deviceID, to: newName)
            } catch {
                showError(title: "Couldn't rename “\(machine.name)”", error: error)
            }
        }
    }

    /// Show a warning alert for a failed account operation.
    private func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The remote-row subline. Relay machines show the agent-reported hostname
    /// in parentheses — only when it differs (case-insensitively) from the
    /// display name, i.e. after a rename — and NEVER an "Online"/"Offline"
    /// line: status is conveyed solely by the leading shape indicator. TCP
    /// machines keep the live metrics probe state. Deliberately never shows
    /// the host:port (the user does not want the IP displayed).
    @ViewBuilder
    private func subline(for machine: Machine) -> some View {
        if machine.isRelay {
            if let hostname = hostnameSubtext(for: machine) {
                Text("(\(hostname))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(tcpSublineText(for: machine))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The hostname to show beneath a relay machine's name, or nil when the
    /// relay doesn't know it or it matches the display name (showing
    /// "MaximusHome" over "(maximushome)" would be noise).
    private func hostnameSubtext(for machine: Machine) -> String? {
        guard let hostname = machine.hostname,
              !hostname.isEmpty,
              hostname.caseInsensitiveCompare(machine.name) != .orderedSame
        else { return nil }
        return hostname
    }

    /// The subline for a direct-TCP machine: live CPU/memory once metrics
    /// arrive, or a graceful placeholder while connecting / when unreachable.
    private func tcpSublineText(for machine: Machine) -> String {
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
            activate(target)
        }
    }

    // MARK: Primary action (New vs Restore)

    /// How many of `target`'s manifest windows could be restored right now:
    /// relay entries with a captured session UUID that aren't bound to an
    /// open window (the same open-entry bookkeeping the restore path's
    /// `partitionForRestore` uses). Always 0 for Local and direct-TCP rows.
    /// Computed on demand (the manifest isn't observable), so it refreshes
    /// whenever the body re-renders — every selection change included.
    private func restorableCount(for target: WindowTarget) -> Int {
        guard case .remote(let machine) = target,
              let relayBase = machine.relayBase,
              let deviceID = machine.deviceID
        else { return 0 }
        let openEntryIDs = Set(TerminalController.all.compactMap(\.remoteManifestEntryID))
        return RemoteSessionManifest.shared.restorableEntries(
            relayBase: relayBase,
            deviceID: deviceID,
            openEntryIDs: openEntryIDs
        ).count
    }

    /// The footer primary-button label for the current selection: "New" (it
    /// creates a new window) unless the highlighted machine has recoverable
    /// windows, then "Restore" — with the count when more than one.
    private var primaryButtonTitle: String {
        guard let target = resolvedSelection else { return "New" }
        let count = restorableCount(for: target)
        switch count {
        case 0: return "New"
        case 1: return "Restore"
        default: return "Restore (\(count))"
        }
    }

    /// Perform the primary action for `target`: restore its recoverable
    /// windows when it has any, otherwise open a new window. Shared by the
    /// footer button (Return) and the row double-click so both always follow
    /// the label the button is showing.
    private func activate(_ target: WindowTarget) {
        if case .remote(let machine) = target, restorableCount(for: target) > 0 {
            onSelect(.restoreRemote(machine))
        } else {
            onSelect(target)
        }
    }
}

/// Presents the window-target chooser as an application-modal panel centered on
/// the active (key) window — or the main screen if there is none — and calls
/// `completion` with the chosen target, or nil if the user cancelled.
///
/// The chooser always lists a "Local" entry first (a normal local window),
/// followed by every registered remote machine. On open it refreshes the relay
/// account's device list (WP-C2), so relay rows carry live online status and
/// may appear/disappear as the fetch lands. Callers should special-case the
/// nothing-to-choose case (no machines AND no relay account) before calling
/// this (e.g. just open a local window directly).
@MainActor
enum MachineChooser {
    static func present(
        registry: MachineRegistry = .shared,
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
            registry: registry,
            probe: probe,
            onSelect: { finish($0) },
            onCancel: { finish(nil) },
            onActivityMonitor: { machine in
                // Dismiss the chooser (tearing down its probes via `finish`) and
                // open the Activity Monitor on a freshly-dialed connection.
                finish(nil)
                RemoteActivityMonitor.presentDialing(machine: machine)
            },
            account: .shared
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSPanel(contentViewController: hosting)
        window.styleMask = [.titled]
        window.title = "New Window"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        windowRef = window

        // Size the window to the SwiftUI content's natural size BEFORE centering.
        // The view fixes its width at 440; force a layout so `fittingSize` returns
        // the real height, then set the content size. Without this, the panel's
        // frame size is still its default at center time (width ≈ 0 → the left edge
        // lands at the screen midpoint, so it appears shoved to the right).
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)

        // Center on the SCREEN (anchor window's screen, else main) so the chooser
        // lands in the middle of the display regardless of the terminal's position.
        if let screen = anchorWindow?.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: v.midX - size.width / 2,
                y: v.midY - size.height / 2
            ))
        } else {
            window.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Refresh the account device list from the relay on open (WP-C2). The
        // continuation runs during the modal session (the modal panel runloop
        // mode is a common mode, so main-queue work is delivered — the probe
        // relies on the same behavior). Rows update in place as it lands.
        Task { @MainActor in
            await registry.refreshFromRelay()
        }
        // Begin probing remote machines for live metrics now that the picker is
        // on screen. Dials happen off the main thread; rows update as samples
        // arrive (or fall back to "Unreachable"). Relay machines are skipped:
        // the probe dials TCP only, and their subline shows directory status.
        probe.start(registry.machines.filter { !$0.isRelay })
        NSApp.runModal(for: window)
    }
}
