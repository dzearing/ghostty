import SwiftUI
import AppKit
import Combine

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
    /// Resume ONE browsed session (cross-machine resume, T17): open a local
    /// viewer window that re-`ATTACH`es to `session` over its host machine's
    /// transport. `machine == nil` means the local agent ("this Mac"). Produced
    /// by clicking / keyboard-selecting a row in a machine's expanded session
    /// list; never a top-level `targets` row.
    case resumeSession(machine: Machine?, session: BrowsedSession)
    /// Resume ALL of a machine's windows (cross-machine "Resume all", T18):
    /// rebuild the full window/tab/split topology locally from the machine's
    /// agent-owned layout blobs, attaching each leaf to its live session.
    /// `machine == nil` means the local agent. Produced by the "Resume all"
    /// affordance at the foot of a machine's expanded session list; never a
    /// top-level `targets` row.
    case resumeAll(machine: Machine?)
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
    /// live as the account device list is fetched from the relay on open and
    /// re-polled while the chooser stays open (WP-C2) and as rows are
    /// renamed/removed.
    @ObservedObject var registry: MachineRegistry
    /// Live per-machine metrics for the remote rows, refreshed while the picker
    /// is open. Drives each remote row's subline in place of the IP:port.
    @ObservedObject var probe: MachineMetricsProbe
    /// Lazily-fetched per-machine session rosters (cross-machine resume browse,
    /// T16). Drives each row's disclosure: a session-count badge + an expandable
    /// read-only list of that machine's active sessions.
    @ObservedObject var browser: SessionBrowserProbe
    /// Live per-session CPU for the SELECTED target, from the agent's pushed
    /// `session_cpu` stream.
    ///
    /// Owned by the PRESENTER, not by this view, and torn down in its `finish`
    /// alongside `probe`/`browser`. A `@StateObject` here relying on
    /// `.onDisappear` does not work: the chooser is an NSPanel that gets
    /// `orderOut`, which hides the window without removing the SwiftUI view from
    /// its hosting controller — so `.onDisappear` never fires and the stream (and
    /// the agent-side pump enumerating every process behind it) runs forever.
    @ObservedObject var sessionCPU: SessionCPUProbe
    var onSelect: (WindowTarget) -> Void
    var onCancel: () -> Void
    /// Secondary action: open the Activity Monitor for the selected row instead of
    /// a window. Triggered by the detail header's "See Activity" button.
    ///
    /// `nil` means **this Mac** — the monitor's in-process Local source, which
    /// needs no connection. A non-nil machine is dialed.
    var onActivityMonitor: (Machine?) -> Void

    /// Signed-in Google account state for the footer row (WP-B2). Observed so
    /// the row flips between "Sign in with Google…" and "<email> · Sign Out"
    /// as sign-in completes.
    @ObservedObject var account: RelayAccount

    @State private var query: String = ""
    /// True while the browser sign-in flow is running (shows the spinner row).
    @State private var isSigningIn = false
    /// True while the sign-out flow is in flight (it awaits a network round
    /// trip to revoke this machine, so the link must not be clickable twice).
    @State private var isSigningOut = false
    /// Index into `targets` of the highlighted row. Bound to `List(selection:)`
    /// so the native selection highlight + focus ring track the keyboard.
    @State private var selectedIndex: Int = 0
    /// Stable identity (registry UUID) of the highlighted MACHINE row, nil when
    /// "Local" is highlighted. The background directory poll can insert/remove
    /// rows above the highlight; re-anchoring by identity keeps the highlight
    /// on the same machine instead of whatever slid into its index.
    @State private var selectedMachineID: UUID?
    /// Index of the row currently under the pointer (for hover feedback).
    @State private var hoveredIndex: Int?
    /// Keyboard sub-cursor INTO the highlighted row's session list
    /// (cross-machine resume, T17). `nil` ⇒ the machine row itself is
    /// highlighted; a value ⇒ THAT SESSION in the highlighted row's list is
    /// highlighted, and Return resumes it. Cleared whenever the machine-row
    /// highlight moves or its list collapses.
    ///
    /// A session ID, not an index into the displayed array. The list re-sorts
    /// underneath the cursor — the moment a column header is clicked, and on
    /// any live CPU tick that moves a displayed percentage while sorted by CPU
    /// — and an index would quietly re-point at whatever row slid into that
    /// slot. Same reason `selectedMachineID` anchors the machine highlight by
    /// identity rather than by row number.
    @State private var browseCursorID: String?
    /// Which column the session list is sorted by, and which way. Seeded from
    /// the persisted preference so it survives closing the chooser.
    @State private var sortOrder: MachineChooserSessionSort.Order = MachineChooserSessionSort.load()
    @FocusState private var isFilterFocused: Bool

    /// Drives the live-refresh poll: while the chooser is open, re-fetch the
    /// relevant rosters every couple seconds so new/closed panes and pane
    /// renames show without reopening. Bounded to local + the selected remote.
    ///
    /// Fires in `.modalPanel` as well as `.common`, and that is load-bearing:
    /// the chooser is shown with `NSApp.runModal(for:)`, which pumps the run
    /// loop in `NSModalPanelRunLoopMode` — a mode that is NOT a member of
    /// `.common`. A `.common`-only timer therefore never fires for as long as
    /// the dialog is up, so the roster froze at whatever it held when it opened:
    /// closed sessions lingered as "Resume" rows indefinitely, and reopening the
    /// dialog was the only way to see the truth. Exactly the staleness this timer
    /// exists to prevent. (`pollTask` alongside it kept working because a Swift
    /// `Task` is not run-loop-mode dependent — only this timer was affected.)
    ///
    /// Only one run loop mode is active at a time, so the merge cannot
    /// double-fire; it just means the poll survives whether or not the dialog is
    /// modal.
    private let rosterRefreshTimer = Publishers.Merge(
        Timer.publish(every: 2, on: .main, in: .common).autoconnect(),
        Timer.publish(every: 2, on: .main, in: .modalPanel).autoconnect()
    )

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

    // MARK: - Session browse (T16)

    /// The `SessionBrowserProbe` key for a target's row, or nil for a target
    /// that never browses (`restoreRemote`, which is an action, not a row).
    private func browseKey(for target: WindowTarget) -> String? {
        switch target {
        case .local: return SessionBrowserProbe.localKey
        case .remote(let m): return m.id.uuidString
        case .restoreRemote, .resumeSession, .resumeAll: return nil
        }
    }

    /// The sessions the detail list RENDERS for `target`, in the order it
    /// renders them: the actionable roster, sorted by the active column.
    ///
    /// One definition, shared by the rows, the keyboard cursor, and the header
    /// row's visibility, so the three can never disagree about what is on
    /// screen or in what order. (They already had drifted: the cursor's list
    /// filtered on `isConnectable` alone while the rows also dropped
    /// attached-elsewhere sessions, so on a machine with any of those, Return
    /// resumed a different session than the one highlighted.)
    ///
    /// `actionable` is a defense-in-depth backstop to the agent's own immediate
    /// reap: never render a dead, non-relaunchable tombstone (an unreconnectable
    /// `exited` dead-end). It protects against an OLDER agent that doesn't reap,
    /// and the brief window a still-bound tombstone exists. Alive + relaunchable
    /// stay.
    private func displayedSessions(_ target: WindowTarget) -> [BrowsedSession] {
        guard let key = browseKey(for: target),
              let all = browser.loadedSessions(for: key)
        else { return [] }
        let titles = persistedTitles
        let live = liveSessionInfo
        return MachineChooserSessionSort.sorted(
            actionable(all),
            by: sortOrder,
            label: { $0.label(liveTitle: live.titles[$0.id], persistedTitle: titles[$0.id]) },
            cpu: { sessionCPU.cpuBySession[$0.id] })
    }

    /// The displayed session list of the currently-highlighted machine row,
    /// else `[]`. Drives the keyboard session sub-cursor (T17).
    private var highlightedSessions: [BrowsedSession] {
        guard let target = resolvedSelection else { return [] }
        return displayedSessions(target)
    }

    /// Build the `resumeSession` target for `session` under its parent row
    /// (`.local` ⇒ local agent, `.remote` ⇒ that machine). `nil` for rows that
    /// never browse.
    private func resumeTarget(_ session: BrowsedSession, parent: WindowTarget) -> WindowTarget? {
        switch parent {
        case .local: return .resumeSession(machine: nil, session: session)
        case .remote(let m): return .resumeSession(machine: m, session: session)
        case .restoreRemote, .resumeSession, .resumeAll: return nil
        }
    }

    /// Build the `resumeAll` target for `parent` (`.local` ⇒ local agent,
    /// `.remote` ⇒ that machine). `nil` for rows that never browse.
    private func resumeAllTarget(_ parent: WindowTarget) -> WindowTarget? {
        switch parent {
        case .local: return .resumeAll(machine: nil)
        case .remote(let m): return .resumeAll(machine: m)
        case .restoreRemote, .resumeSession, .resumeAll: return nil
        }
    }

    /// The number of ALIVE sessions in the currently-highlighted expanded row.
    /// "Resume all" is offered only when there are at least two (a single pane is
    /// covered by the per-session resume, and there is no topology to rebuild).
    private var highlightedAliveSessionCount: Int {
        highlightedSessions.filter { $0.alive }.count
    }

    /// Whether the highlighted expanded row can offer "Resume all".
    private var resumeAllAvailable: Bool {
        highlightedAliveSessionCount >= 2
    }

    /// Resume all sessions under `parent`: dismiss the chooser and hand the
    /// selection to the app.
    private func resumeAll(parent: WindowTarget) {
        guard let target = resumeAllTarget(parent) else { return }
        onSelect(target)
    }

    /// Resume `session` under `parent`: dismiss the chooser and hand the
    /// selection to the app. Only ALIVE sessions are resumable (a dead session
    /// has no live pane to attach; its row is rendered disabled).
    private func resume(_ session: BrowsedSession, parent: WindowTarget) {
        guard session.alive, let target = resumeTarget(session, parent: parent) else { return }
        onSelect(target)
    }

    /// A small capsule showing a row's active-session count, once its roster has
    /// loaded (hidden while loading/failed or when zero).
    @ViewBuilder
    private func countBadge(for target: WindowTarget) -> some View {
        if let key = browseKey(for: target), let n = actionableCount(for: key), n > 0 {
            Text("\(n)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .help("\(n) active session\(n == 1 ? "" : "s")")
                .padding(.leading, 6)
        }
    }

    /// Whether the keyboard session sub-cursor (T17) currently points at
    /// `session` under the row keyed `key` — i.e. that row is the highlighted
    /// machine row AND its list is where the cursor lives.
    private func isSessionCursor(key: String, session: BrowsedSession) -> Bool {
        guard browseCursorID == session.id,
              let target = resolvedSelection,
              browseKey(for: target) == key
        else { return false }
        return true
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
        VStack(spacing: 0) {
            // Top header: the selected machine's identity flush LEFT, the
            // account area (avatar + email + Sign Out, or Sign In) flush right.
            // Account state is a global affordance, so it sits above the
            // master-detail split rather than in the footer — and that left an
            // entire band of empty space next to it, which is now where the
            // identity lives.
            HStack(spacing: 0) {
                if let target = resolvedSelection {
                    headerIdentity(target)
                }
                Spacer(minLength: 16)
                accountRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            // Master–detail: a machine list on the LEFT drives a rich detail
            // pane on the RIGHT (that machine's sessions + management actions).
            HStack(spacing: 0) {
                machineListColumn
                    .frame(width: 260)
                    .background(Color.primary.opacity(0.035))
                Divider()
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 840, height: 540)
        .onAppear {
            // Preselect the first target so its detail pane shows on open and
            // Return immediately opens it.
            select(0)
            // Focus the filter so typing narrows the list right away. Arrow
            // navigation still works via the invisible shortcut buttons.
            // Dispatch to the next runloop turn so focus actually sticks
            // (matches the command-palette workaround).
            DispatchQueue.main.async {
                isFilterFocused = true
            }
        }
        .onReceive(rosterRefreshTimer) { _ in
            refreshRosters()
        }
        .onDisappear {
            // Belt-and-braces for hosts that really do remove the view. The
            // authoritative teardown is the presenter's `finish` — see the
            // note on `sessionCPU`; this alone would never fire for the modal
            // NSPanel the chooser actually uses. `stop()` is idempotent.
            sessionCPU.stop()
        }
    }

    // MARK: - Master column (machine list)

    /// The left column: a filter field over a scrollable machine list. Selecting
    /// a row drives the detail pane; the account-refresh status pins to the foot.
    @ViewBuilder
    private var machineListColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Invisible shortcut buttons that drive navigation from the keyboard
            // regardless of which control has focus (command-palette pattern):
            // Up/Down (and ⌃P/⌃N) move the machine highlight; Right steps INTO
            // the detail pane's session list, Left steps back out.
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
                    Button { enterSessions() } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button { exitSessions() } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                TextField("Filter machines…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFilterFocused)
                    .onSubmit { submit() }
                    .onChange(of: query) { _ in reanchorSelection() }
            }
            .padding([.top, .horizontal], 14)
            .padding(.bottom, 10)

            // Rows are a ScrollView+VStack, NOT a `List`: a SwiftUI List swallows
            // row taps for its own selection machinery, so `.onTapGesture` there
            // never fired. In a plain VStack the tap reliably fires. Selection is
            // driven manually off `selectedIndex`; a single tap selects, a double
            // tap opens, `.onHover` gives feedback.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(targets.enumerated()), id: \.element) { idx, target in
                        machineRow(idx: idx, target: target)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: machines) { _ in
                // Keep the highlighted row valid — and on the SAME machine —
                // as the account fetch/poll or a removal changes the list.
                reanchorSelection()
            }

            if registry.isRefreshing || registry.lastRefreshError != nil {
                refreshStatus
            }
        }
    }

    /// One machine row in the master list: glyph, name, subline, and a live
    /// session-count badge. Selection drives the detail pane; a double-click
    /// runs the primary action.
    @ViewBuilder
    private func machineRow(idx: Int, target: WindowTarget) -> some View {
        HStack(spacing: 0) {
            Button {
                select(idx)
            } label: {
                row(for: target)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { activate(target) })

            countBadge(for: target)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowHighlight(idx))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in hoveredIndex = hovering ? idx : nil }
        .contextMenu {
            if case .remote(let machine) = target {
                managementActions(for: machine)
            }
        }
    }

    /// Account-list refresh status (WP-C2): a small spinner while the device
    /// directory is being fetched, or the fetch error. Never blocks the list.
    @ViewBuilder
    private var refreshStatus: some View {
        HStack(spacing: 6) {
            if registry.isRefreshing {
                ProgressView().controlSize(.small)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Detail column (selected machine)

    /// The right pane: header + action bar for the selected machine, then its
    /// live session list. Empty state when there is nothing to select.
    @ViewBuilder
    private var detailColumn: some View {
        if let target = resolvedSelection {
            VStack(alignment: .leading, spacing: 0) {
                detailActionBar(target)
                Divider()
                detailSessions(target)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("No machines")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The selected machine's identity — glyph, name, session-count subtitle —
    /// rendered flush LEFT in the top header band.
    ///
    /// It used to open the detail column, stacked above the action bar, where
    /// it cost ~50pt of the one thing that column is short of: rows. The band
    /// above it already carried a whole row of empty space beside the account
    /// block, and an identity line is exactly what a header band is for.
    @ViewBuilder
    private func headerIdentity(_ target: WindowTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: detailGlyph(target))
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(detailTitle(target))
                    .font(.title3).fontWeight(.semibold)
                    .lineLimit(1)
                detailSubtitle(target)
            }
        }
    }

    /// The detail column's action bar, and now its first row. The prominent
    /// primary button (New Window / Restore) is the default action (Return);
    /// Restore-all / Activity / management sit beside it.
    ///
    /// Vertical padding is 12, not the 16 this block used to carry: the point
    /// of moving the identity out was to give the session list the space, and
    /// padding is the obvious way to lose it again on the way down.
    @ViewBuilder
    private func detailActionBar(_ target: WindowTarget) -> some View {
        HStack(spacing: 8) {
            Button {
                submit()
            } label: {
                Label(primaryButtonTitle, systemImage: primaryButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .help("Open a new window on \(detailTitle(target))")

            if resumeAllAvailable {
                Button {
                    resumeAll(parent: target)
                } label: {
                    Label("Restore All", systemImage: "rectangle.3.group")
                }
                .help("Rebuild this machine's full window layout here")
            }

            // Push the inspect action to the trailing edge, away from the
            // open actions. "See Activity" doesn't open a window, so
            // grouping it with the buttons that do invites misclicks — and
            // a right-aligned slot keeps it on this row rather than adding
            // a second row of chrome to an already compact dialog.
            Spacer(minLength: 12)

            switch target {
            case .local:
                seeActivityButton(machine: nil, named: detailTitle(target))
            case .remote(let machine):
                seeActivityButton(machine: machine, named: machine.name)
            default:
                EmptyView()
            }

            if case .remote(let machine) = target {
                Menu {
                    managementActions(for: machine)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Manage \(machine.name)")
            }
            // NOTE: no trailing Spacer. The one above is what pushes the
            // inspect action to the trailing edge; a second Spacer here
            // would split the free space evenly between them and park the
            // button in the middle instead of flush right.
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The glyph for the machine's identity — laptop for the local/this-Mac
    /// machine, server otherwise.
    private func detailGlyph(_ target: WindowTarget) -> String {
        switch target {
        case .local: return "laptopcomputer"
        case .remote(let m): return m.isLocalMachine ? "laptopcomputer" : "server.rack"
        default: return "server.rack"
        }
    }

    /// The machine's title — "This Mac" for local, else the machine name.
    private func detailTitle(_ target: WindowTarget) -> String {
        switch target {
        case .local: return "This Mac"
        case .remote(let m): return m.name
        default: return ""
        }
    }

    /// The machine's subtitle — session count + machine status/metrics.
    @ViewBuilder
    private func detailSubtitle(_ target: WindowTarget) -> some View {
        HStack(spacing: 8) {
            if let key = browseKey(for: target), let n = actionableCount(for: key) {
                Text("\(n) session\(n == 1 ? "" : "s")")
            }
            switch target {
            case .remote(let m):
                if m.isRelay {
                    if let hostname = hostnameSubtext(for: m) {
                        Text("· \(hostname)")
                    }
                } else {
                    Text("· \(tcpSublineText(for: m))")
                }
            default:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The detail pane's session list: sortable column headers over loading /
    /// failed / empty states, else a rich, per-session row with liveness,
    /// activity, badges, and Resume/Kill.
    @ViewBuilder
    private func detailSessions(_ target: WindowTarget) -> some View {
        if let key = browseKey(for: target) {
            // Resolved once and shared by the header and the rows, so the
            // headers can't advertise an order the rows aren't in.
            let sessions = displayedSessions(target)
            VStack(alignment: .leading, spacing: 0) {
                // OUTSIDE the ScrollView, so the headers stay put while the
                // rows scroll under them. Only drawn when there is something to
                // sort — column headers over "No active sessions" are furniture.
                if !sessions.isEmpty {
                    sessionListHeader
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        switch browser.states[key] {
                        case .some(.loaded):
                            if sessions.isEmpty {
                                sessionsPlaceholder(icon: "moon.zzz", text: "No active sessions")
                            } else {
                                let titles = persistedTitles
                                let live = liveSessionInfo
                                ForEach(sessions) { session in
                                    sessionDetailRow(
                                        session,
                                        target: target,
                                        persistedTitle: titles[session.id],
                                        liveTitle: live.titles[session.id],
                                        isOpenLocally: live.openIDs.contains(session.id),
                                        highlighted: isSessionCursor(key: key, session: session))
                                }
                            }
                        case .some(.failed):
                            sessionsPlaceholder(
                                icon: "exclamationmark.triangle.fill",
                                text: "Couldn't reach this machine's agent",
                                tint: .yellow)
                        case .some(.loading), .none:
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading sessions…").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.sessionGutter)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// The session list's gutter — the inset from the detail column's edge to a
    /// row's card.
    private static let sessionGutter: CGFloat = 16

    /// Horizontal inset of a session row's CONTENT: the gutter plus the row
    /// card's own 12pt padding. The column header lives outside the scroll view
    /// so it can't scroll away, which means it has to reproduce both to land
    /// its labels on the columns it sorts.
    private static let sessionContentInset: CGFloat = sessionGutter + 12

    /// The session list's clickable column headers: CPU and Name, each sorting
    /// the list and flipping direction when clicked while already active.
    ///
    /// Built on the SAME column widths the rows use rather than a grid of its
    /// own. The CPU meters were deliberately given a fixed-width column so they
    /// stack into a scannable strip; a header that sat anywhere else would
    /// introduce a second, competing alignment and undo that.
    @ViewBuilder
    private var sessionListHeader: some View {
        HStack(spacing: 10) {
            // The liveness dot's slot. Nothing to label — the dot is its own
            // legend — but the space has to be held or every column after it
            // shifts left of the rows.
            Color.clear
                .frame(width: Self.livenessColumnWidth, height: 1)
            sessionSortButton(.cpu)
                .frame(width: Self.cpuColumnWidth, alignment: .leading)
            sessionSortButton(.name)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Self.sessionContentInset)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    /// One column header: its title, plus a direction chevron when it is the
    /// column the list is currently sorted by.
    @ViewBuilder
    private func sessionSortButton(_ key: MachineChooserSessionSort.Key) -> some View {
        let active = sortOrder.key == key
        Button {
            setSortOrder(MachineChooserSessionSort.toggled(sortOrder, clicking: key))
        } label: {
            HStack(spacing: 3) {
                Text(key.columnTitle)
                // The chevron marks the ACTIVE column, so it is drawn only
                // there. Reserving room for one on every column would push each
                // label off the column it heads, which is the one thing this
                // header cannot do.
                if active {
                    Image(systemName: sortOrder.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sessionSortHelp(key))
        .accessibilityLabel("Sort by \(key.columnTitle)")
        .accessibilityValue(
            active ? (sortOrder.ascending ? "Ascending" : "Descending") : "Not sorted")
    }

    /// Tooltip for a column header: what clicking it will do, or — when it is
    /// already the active column — what it is doing now.
    private func sessionSortHelp(_ key: MachineChooserSessionSort.Key) -> String {
        let column = key.columnTitle.lowercased()
        guard sortOrder.key == key else { return "Sort by \(column)" }
        return sortOrder.ascending
            ? "Sorted by \(column), ascending — click to reverse"
            : "Sorted by \(column), descending — click to reverse"
    }

    /// Apply a new sort order and remember it for next time.
    ///
    /// The keyboard session cursor needs no fixing up across this: it is
    /// anchored to a session ID, so it follows its row through the re-sort
    /// rather than staying on a row number.
    private func setSortOrder(_ order: MachineChooserSessionSort.Order) {
        guard order != sortOrder else { return }
        sortOrder = order
        MachineChooserSessionSort.save(order)
    }

    /// The trailing "See Activity" action in the detail header.
    ///
    /// Offered for **This Mac** as well as remote machines: the Activity Monitor
    /// has had a Local source all along, but the button was gated to remote rows,
    /// so the most common case — inspecting your own machine — had no entry point
    /// here at all. `machine == nil` opens that Local source directly (no dial).
    @ViewBuilder
    private func seeActivityButton(machine: Machine?, named name: String) -> some View {
        Button {
            onActivityMonitor(machine)
        } label: {
            Label("See Activity", systemImage: "chart.bar.xaxis")
        }
        .help("Open Activity Monitor for \(name)")
    }

    /// A centered placeholder card for the empty / failed session states.
    @ViewBuilder
    private func sessionsPlaceholder(icon: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    /// One rich session row in the detail pane: liveness dot, real-name label
    /// (live pane title → agent title → persisted title → cwd → command → pid),
    /// activity + status badges, cwd / command sublines, and Show/Resume + Kill.
    /// A session already open in a window shows **Show** (which focuses that
    /// window) instead of "Resume" (which would open a duplicate). A single click
    /// moves the keyboard session cursor here; double-click runs the row action.
    @ViewBuilder
    private func sessionDetailRow(
        _ session: BrowsedSession,
        target: WindowTarget,
        persistedTitle: String?,
        liveTitle: String?,
        isOpenLocally: Bool,
        highlighted: Bool
    ) -> some View {
        let machine = detailMachine(target)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: session.alive ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(session.alive ? Color.green : Color.secondary)
                .frame(width: Self.livenessColumnWidth)
                .padding(.top, 4)

            // CPU sits in its own fixed-width column ahead of the title so the
            // meters stack into a scannable vertical strip. Inline after the
            // title it moved with every label's length, which is precisely what
            // stops you comparing rows at a glance.
            cpuMeterColumn(session)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.label(liveTitle: liveTitle, persistedTitle: persistedTitle))
                        .font(.body).fontWeight(.medium)
                        .lineLimit(1)
                    if session.alive {
                        activityBadge(session.activity)
                    } else {
                        pill(exitedLabel(session), .secondary)
                    }
                    // No "open"/"attached"/"pinned" chips. A chip should mark the
                    // EXCEPTION, and none of these are: every persistent local
                    // session is pinned, and since the list now hides sessions this
                    // viewer cannot resume, every remaining row is either open here
                    // or genuinely detached — so "open" sat on nearly all of them
                    // and "attached" on none. They cost a column of chrome to say
                    // nothing, and the row's own button already draws the
                    // distinction: "Show" for a session on screen, "Resume" for one
                    // that is not. Only genuinely exceptional states get a chip —
                    // the activity badge (busy / needs input), and how a dead
                    // session exited.
                }
                if let cwd = session.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let argv = session.argv, !argv.isEmpty {
                    Text(argv)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if session.alive {
                    if isOpenLocally {
                        Button("Show") { resume(session, parent: target) }
                            .controlSize(.small)
                            .help("Bring this session's window to the front")
                    } else {
                        Button("Resume") { resume(session, parent: target) }
                            .controlSize(.small)
                            .help("Resume this session in a new window")
                    }
                }
                Button {
                    confirmKill(session, machine: machine)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .help("End this session (terminates its process)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(highlighted ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { browseCursorID = session.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { resume(session, parent: target) })
    }

    /// Fixed width of the leading liveness-dot column. The two dot glyphs are
    /// intrinsically sized, so without this the CPU column — and the header
    /// that has to sit over it — starts at a different x on a live row than on
    /// a dead one.
    private static let livenessColumnWidth: CGFloat = 10

    /// A compact CPU meter for a live session: a small bar plus the percentage.
    ///
    /// The number is per-core over the session's WHOLE process tree, so a session
    /// running four busy threads reads ~400% — the same convention as top(1), and
    /// the honest one here, because "is this agent runaway?" is exactly a question
    /// about how many cores it is eating.
    ///
    /// Shown for every live session once a reading arrives, INCLUDING 0%.
    /// Hiding idle rows seemed tidier, but it makes "idle" and "the meter isn't
    /// working" look identical — and it removes the baseline that makes a busy
    /// row obvious, since 400% only reads as alarming next to neighbours sitting
    /// at 0. A missing meter now means exactly one thing: the agent can't serve
    /// the stream.
    private static let cpuBarWidth: CGFloat = 26

    /// Width reserved for the percentage. Fixed, so the number can never resize
    /// and shove the titles — the list must not twitch just because a session got
    /// busy.
    ///
    /// Sized for three digits ("999%"), not for the theoretical maximum. Per-core
    /// CPU is uncapped, so a fully busy 16-core box could read "1600%" — but
    /// reserving for that bought a guarantee nobody exercises and left a visible
    /// gap on EVERY row, since the common reading is "0%". Three digits covers up
    /// to ten fully-busy cores in a single session; beyond that the value simply
    /// runs into its slack, which is the right thing to degrade.
    private static let cpuValueWidth: CGFloat = 27

    /// Width of the whole CPU column, reserved even when there is no meter to
    /// draw, so every row's title starts at the same x — a column that collapses
    /// on some rows isn't a column.
    private static let cpuColumnWidth: CGFloat = cpuBarWidth + 4 + cpuValueWidth

    @ViewBuilder
    private func cpuMeterColumn(_ session: BrowsedSession) -> some View {
        Group {
            if session.alive, sessionCPU.supported, let pct = sessionCPU.cpuBySession[session.id] {
                // The bar saturates at one full core; beyond that the number
                // carries the magnitude. A bar scaled to ncpu would leave the
                // common one-busy-core case as a barely visible sliver.
                let fill = min(Double(pct) / 100.0, 1.0)
                // An idle row stays visually quiet — a drawn-but-empty track —
                // so the busy one still pops without the idle ones vanishing.
                let tint: Color = pct >= 100 ? .red : (pct >= 40 ? .orange : .secondary)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: Self.cpuBarWidth, height: 4)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(tint)
                                .frame(width: Self.cpuBarWidth * fill, height: 4)
                        }
                    // Leading-aligned in a FIXED-width slot: the number belongs
                    // to the bar, so it sits right after it and the slack falls on
                    // its right, against the title. Pushing it to the trailing
                    // edge instead put the gap between bar and number and parked
                    // the number against the title, which read as if it belonged
                    // to the title. Monospaced digits so it does not shimmer as
                    // the value changes.
                    Text("\(Int(pct.rounded()))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                        .fixedSize()
                        .frame(width: Self.cpuValueWidth, alignment: .leading)
                }
                .help(cpuMeterHelp(pct))
            } else {
                // Dead session, or no reading yet: hold the space open.
                Color.clear
            }
        }
        .frame(width: Self.cpuColumnWidth, alignment: .leading)
    }

    /// Tooltip for the CPU meter. Names the units (a number over 100 is
    /// confusing without them) and, when the agent has throttled itself, says so
    /// — otherwise a slow-moving meter reads as a broken one.
    private func cpuMeterHelp(_ pct: Float) -> String {
        var text = String(
            format: "%.0f%% CPU across this session's whole process tree (100%% = one core).",
            pct)
        let ms = sessionCPU.agentIntervalMs
        if ms > 2000 {
            text += String(format: "\nUpdating every %.0fs — the agent is throttling itself under load.",
                           Double(ms) / 1000.0)
        }
        return text
    }

    /// A small activity badge for a live session: busy / needs-input are shown;
    /// idle is intentionally unbadged (the default, no need for noise).
    @ViewBuilder
    private func activityBadge(_ activity: String) -> some View {
        switch activity {
        case "busy": pill("busy", .orange)
        case "needs_input": pill("needs input", .red)
        default: EmptyView()
        }
    }

    /// A small rounded status capsule.
    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(color == .secondary ? 0.15 : 0.18)))
    }

    /// A dead session's exit label — "exited" or "exited (code)".
    private func exitedLabel(_ session: BrowsedSession) -> String {
        if let code = session.exitCode { return "exited (\(code))" }
        return "exited"
    }

    // MARK: - Footer

    /// The footer: just Cancel, right-aligned. The account area moved to the
    /// top header, and the primary action lives in the detail header, so the
    /// footer stays minimal.
    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Detail helpers

    /// The machine backing a target (`nil` for Local / non-machine targets).
    private func detailMachine(_ target: WindowTarget) -> Machine? {
        if case .remote(let m) = target { return m }
        return nil
    }

    /// The primary button's SF Symbol — restore vs. new.
    private var primaryButtonIcon: String {
        guard let target = resolvedSelection else { return "plus" }
        return restorableCount(for: target) > 0 ? "arrow.clockwise" : "plus"
    }

    /// A map of session id → persisted layout title, harvested from the saved
    /// `SessionLayoutManifest`. Lets a relaunched-but-not-yet-retitled session
    /// still show its real name in the detail list before the pane re-titles
    /// itself (survives app restart). Recomputed per detail render (the roster
    /// is small, and a restore that happens while the chooser is open should be
    /// reflected).
    private var persistedTitles: [String: String] {
        var map: [String: String] = [:]
        for entry in SessionLayoutManifest.shared.allEntries() {
            guard let tree = entry.tree else { continue }
            for leaf in SessionLayoutManifest.leaves(of: tree) {
                if let sid = leaf.sessionID, let title = leaf.title, !title.isEmpty {
                    map[sid] = title
                }
            }
        }
        return map
    }

    /// Live state harvested from the app's OPEN windows, so the detail list
    /// reflects reality as it changes — recomputed every render (and the poll
    /// timer forces renders): `openIDs` are the sessions currently bound to an
    /// open pane (so their row shows "Show" and focuses the window instead of
    /// "Resume"-ing a duplicate), and `titles` are those panes' LIVE titles (so
    /// a pane rename shows immediately — the agent doesn't track renames).
    private struct LiveSessionInfo {
        var openIDs: Set<String> = []
        var titles: [String: String] = [:]
    }

    /// The sessions the user can actually act on — what the list renders, and
    /// what every count must agree with.
    ///
    /// Beyond the dead-tombstone backstop (`isConnectable`), this drops any
    /// session the agent reports as ATTACHED that we have no open pane for.
    /// In practice that is a pane just closed: its session stays alive for the
    /// undo window (5s) and is still bound to us, so it rendered as a "Resume"
    /// row for a window the user deliberately closed — which reads as a leak and
    /// invites reviving it. It also covers a session attached to some OTHER
    /// viewer, which this one equally cannot resume.
    ///
    /// Keyed on our own open panes rather than a "closing" marker, so it holds by
    /// construction: if it is not on screen here and something else holds it, we
    /// cannot offer it. Genuinely detached sessions — the real Resume case — are
    /// untouched.
    private func actionable(_ sessions: [BrowsedSession]) -> [BrowsedSession] {
        let live = liveSessionInfo
        return sessions.filter { session in
            guard session.isConnectable else { return false }
            if session.attached && !live.openIDs.contains(session.id) { return false }
            return true
        }
    }

    /// The count shown on a row badge / in the detail header. Derived from the
    /// SAME filter as the list, so the number can never disagree with the rows.
    private func actionableCount(for key: String) -> Int? {
        guard let all = browser.loadedSessions(for: key) else { return nil }
        return actionable(all).count
    }

    private var liveSessionInfo: LiveSessionInfo {
        var info = LiveSessionInfo()
        for controller in TerminalController.all {
            // A PINNED window title is the most intentional name the window has
            // -- the user typed it -- and it wins in the titlebar (window title →
            // tab title → pane title). The row used only `pane.title`, so
            // renaming a window left the picker showing the old shell-derived
            // name: the rename appeared to do nothing here.
            let windowTitle = controller.effectiveWindowTitleOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let panes = controller.surfaceTree.root?.leaves() ?? []
            for pane in controller.surfaceTree {
                guard let view = pane.surfaceView,
                      let sid = view.liveRemoteSessionID
                else { continue }
                info.openIDs.insert(sid)
                let paneTitle = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
                // Prefer the window title, but keep the pane title as a
                // disambiguator when the window holds several panes -- otherwise
                // every pane of a renamed window collapses to one identical row.
                if let windowTitle, !windowTitle.isEmpty {
                    info.titles[sid] = (panes.count > 1 && !paneTitle.isEmpty && paneTitle != windowTitle)
                        ? "\(windowTitle) › \(paneTitle)"
                        : windowTitle
                } else if !paneTitle.isEmpty {
                    info.titles[sid] = paneTitle
                }
            }
        }
        return info
    }

    /// Live-refresh the currently-relevant rosters (the poll tick): the local
    /// agent always (cheap, warm connection — keeps "This Mac" and its list
    /// current), plus the selected remote machine. In-place, so newly spawned
    /// panes appear and closed ones drop without flicker or a reopen.
    private func refreshRosters() {
        browser.refreshLocalInPlace()
        if case .remote(let m) = resolvedSelection {
            browser.refreshInPlace(machine: m)
        }
    }

    /// Step the keyboard cursor INTO the detail pane's session list (Right).
    private func enterSessions() {
        guard browseCursorID == nil, let first = highlightedSessions.first else { return }
        browseCursorID = first.id
    }

    /// Step the keyboard cursor back OUT of the session list to the machine
    /// (Left).
    private func exitSessions() {
        browseCursorID = nil
    }

    /// Ensure the selected target's session roster is fetched so the detail pane
    /// can render it (fetch-on-select; lazy for remote machines).
    private func ensureFetched(_ target: WindowTarget?) {
        switch target {
        case .local:
            browser.fetchIfNeededLocal()
            sessionCPU.subscribeLocal()
        case .remote(let m):
            browser.fetchIfNeeded(machine: m)
            sessionCPU.subscribe(machine: m)
        default:
            // Nothing selected (or a non-browsable row): don't keep a stream —
            // or a warm connection — running for a target the user is no longer
            // looking at.
            sessionCPU.stop()
            browser.standDownRemote()
        }
    }

    /// Confirm, then end (`Kill`) a session — the session-scoped equivalent of
    /// closing its pane. Destructive, so an NSAlert confirms first (the chooser
    /// runs an AppKit modal session, matching Rename/Remove).
    ///
    /// If the session is currently OPEN in one of our panes, close THAT pane —
    /// closing the pane ends the session cleanly (the `+close` lifecycle) AND
    /// removes the pane, instead of killing the session on the agent and leaving
    /// an orphaned pane attached to a now-dead session. Otherwise (a detached /
    /// browsed session) end it with the session-scoped `close_session` RPC. Both
    /// paths let the live roster poll drop the row.
    private func confirmKill(_ session: BrowsedSession, machine: Machine?) {
        let alert = NSAlert()
        alert.messageText = "End session “\(session.label(liveTitle: liveSessionInfo.titles[session.id], persistedTitle: persistedTitles[session.id]))”?"
        alert.informativeText = "This ends the session — the same as closing its pane. Any unsaved work in it is lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Optimistically drop the row now so it doesn't linger (and degrade to a
        // "pid" label) during the close's undo window while the agent still
        // lists the ending session.
        let key = machine.map { $0.id.uuidString } ?? SessionBrowserProbe.localKey
        browser.markKilled(session.id, key: key)

        if let (controller, surface) = localSurface(forSession: session.id) {
            // Open in one of our panes: close the pane (ends the session for a
            // local persistence pane; for a remote session open locally the
            // viewer close only detaches, so ALSO end it on its agent below).
            controller.closeSurface(surface, withConfirmation: false)
            if machine != nil {
                browser.kill(session: session, machine: machine)
            }
        } else {
            browser.kill(session: session, machine: machine)
        }
    }

    /// The (controller, surface) of a local pane currently bound to `sessionID`,
    /// or nil when the session isn't open in any of our windows. Used so Kill
    /// closes an open pane rather than orphaning it against a dead session.
    private func localSurface(forSession sessionID: String) -> (TerminalController, Ghostty.SurfaceView)? {
        for controller in TerminalController.all {
            for pane in controller.surfaceTree {
                if let view = pane.surfaceView,
                   view.liveRemoteSessionID == sessionID {
                    return (controller, view)
                }
            }
        }
        return nil
    }

    /// The account footer (WP-B2): avatar + email + a standard "Sign Out"
    /// button when signed in, a standard "Sign In with Google" button when
    /// signed out, a spinner while the browser flow runs, or a pointer to the
    /// setup doc when no Google client id is configured. Plain bordered
    /// buttons, styled like Cancel/New — no link styling or cursor hacks.
    @ViewBuilder
    private var accountRow: some View {
        if let email = account.email {
            // Email + Sign Out stacked on two right-aligned lines, to the LEFT
            // of a larger avatar pinned to the corner. Sign Out is a link, not a
            // button.
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(email)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 240, alignment: .trailing)
                        .help("Signed in as \(email)")
                    // "Signing Out…" is not decoration: sign-out now awaits a
                    // relay round trip to revoke this machine, so the click has
                    // a visible duration and must not be repeatable.
                    Button(isSigningOut ? "Signing Out…" : "Sign Out") { startSignOut() }
                        .buttonStyle(.ghosttyLink)
                        .font(.caption)
                        .disabled(isSigningOut)
                }
                avatar(for: email, size: 34)
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
    private func avatar(for email: String, size: CGFloat = 20) -> some View {
        Group {
            if let url = account.pictureURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        monogram(for: email, size: size)
                    }
                }
            } else {
                monogram(for: email, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Signed in as \(email)")
    }

    /// A Google-style monogram circle: the email's first letter on an accent
    /// gradient. The no-network fallback for the avatar.
    private func monogram(for email: String, size: CGFloat = 20) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom))
            Text(String(email.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
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

    /// Sign out, which FIRST revokes this machine's own relay enrollment (see
    /// `RelayAccount.signOut(force:)`). When that revocation can't reach the
    /// relay the account stays signed IN and the user gets the choice, because
    /// the alternative — reporting "signed out" while every other client on the
    /// account can still reach and watch this machine — is the bug this whole
    /// path exists to close.
    private func startSignOut() {
        isSigningOut = true
        Task { @MainActor in
            defer { isSigningOut = false }
            do {
                try await account.signOut()
            } catch let error as RelayAccount.AccountError {
                guard case .machineRevocationFailed = error else {
                    showError(title: "Sign out failed", error: error)
                    return
                }
                guard confirmSignOutWithoutRevoking(error) else { return }
                do {
                    try await account.signOut(force: true)
                } catch {
                    showError(title: "Sign out failed", error: error)
                }
            } catch {
                showError(title: "Sign out failed", error: error)
            }
        }
    }

    /// The "we couldn't revoke this machine" fork. Cancelling (and retrying) is
    /// the default; signing out anyway is offered but named for what it costs.
    private func confirmSignOutWithoutRevoking(_ error: Error) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This machine is still connected to your account"
        alert.informativeText =
            error.localizedDescription
            + "\n\nUntil it is removed, other devices signed in to this account"
            + " can still open sessions on this machine and watch the ones"
            + " already running. Signing out anyway will keep trying to remove"
            + " it in the background."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign Out Anyway")
        if #available(macOS 11.0, *) {
            alert.buttons.last?.hasDestructiveAction = true
        }
        return alert.runModal() == .alertSecondButtonReturn
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
        case .restoreRemote, .resumeSession, .resumeAll:
            // Never appears in `targets`; they're action results, not rows.
            EmptyView()
        }
    }

    /// The leading status column for a device row. For relay machines the
    /// status is SHAPE-coded, not just color-coded (colorblind-safe): online
    /// is a filled circle with an inner ring mark (`circle.inset.filled`,
    /// green), offline a HOLLOW circle (`circle`, gray), and checking — a
    /// cache-seeded row at launch whose live status hasn't arrived yet — a
    /// dimmed dotted outline (`circle.dotted`). Non-relay rows get an equally
    /// sized empty slot so all rows share one column grid.
    ///
    /// Checking/offline rows stay SELECTABLE, matching the long-standing
    /// offline policy: the chooser never blocks a connect attempt on
    /// directory presence (which can be stale in either direction); a machine
    /// that really is unreachable fails at dial time with a clear error.
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
        default: return "Checking status"
        }
    }

    /// The management actions for a remote machine, shared by the per-row
    /// ellipsis menu and the row's context menu. Per-host settings apply to
    /// every remote machine (TCP or relay); rename/remove are account-resource
    /// actions and stay relay-only (WP-C2).
    @ViewBuilder
    private func managementActions(for machine: Machine) -> some View {
        Button("Host Settings…") { promptHostSettings(machine) }
        if machine.isRelay {
            Divider()
            Button("Rename…") { promptRename(machine) }
            Divider()
            Button("Remove from Account…", role: .destructive) { confirmRemove(machine) }
        }
    }

    /// Shell presets offered in the host-settings combo box: the Windows
    /// shells the agent has per-shell argv conventions for (cmd `/c`,
    /// powershell/pwsh `-Command`, wsl `--` — see pty_child.zig), plus common
    /// POSIX shells. The combo box is editable, so any other path can be
    /// typed as free text.
    private static let shellPresets: [String] = [
        "cmd.exe",
        "powershell.exe",
        "pwsh.exe",
        "wsl.exe",
        "/bin/bash",
        "/bin/zsh",
    ]

    /// Edit the per-host defaults (working directory + shell) for new remote
    /// sessions on `machine`. NSAlert-based like `promptRename` (the chooser
    /// panel runs an AppKit modal session). Empty fields mean "use the
    /// remote's own default" — saving them clears the stored setting.
    private func promptHostSettings(_ machine: Machine) {
        let current = machine.settings

        let alert = NSAlert()
        alert.messageText = "Host Settings for “\(machine.name)”"
        alert.informativeText = "Defaults for new terminals on this machine. Both are values on the remote machine (e.g. wsl.exe or C:\\dev on a Windows host). Leave a field empty to use the remote's own default."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let labelWidth: CGFloat = 120
        let fieldWidth: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: labelWidth + 8 + fieldWidth, height: 62))

        let wdLabel = NSTextField(labelWithString: "Working directory:")
        wdLabel.alignment = .right
        wdLabel.frame = NSRect(x: 0, y: 38, width: labelWidth, height: 18)
        let wdField = NSTextField(frame: NSRect(x: labelWidth + 8, y: 34, width: fieldWidth, height: 24))
        wdField.placeholderString = "Remote default"
        wdField.stringValue = current.workingDirectory ?? ""

        let shellLabel = NSTextField(labelWithString: "Shell:")
        shellLabel.alignment = .right
        shellLabel.frame = NSRect(x: 0, y: 6, width: labelWidth, height: 18)
        let shellCombo = NSComboBox(frame: NSRect(x: labelWidth + 8, y: 0, width: fieldWidth, height: 26))
        shellCombo.addItems(withObjectValues: Self.shellPresets)
        shellCombo.placeholderString = "Remote default"
        shellCombo.stringValue = current.shell ?? ""
        shellCombo.completes = true

        container.addSubview(wdLabel)
        container.addSubview(wdField)
        container.addSubview(shellLabel)
        container.addSubview(shellCombo)
        alert.accessoryView = container
        alert.window.initialFirstResponder = wdField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MachineSettingsStore.set(
            MachineSettings(
                workingDirectory: wdField.stringValue,
                shell: shellCombo.stringValue),
            for: machine.settingsKey)
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
            reanchorSelection()
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
    /// When the highlighted row is expanded with a loaded session list, Down/Up
    /// first traverse that list (the `browseCursorID` sub-cursor, T17) before
    /// stepping to the next/previous machine row, so the whole chooser —
    /// machines and their sessions — is keyboard-navigable.
    private func move(_ delta: Int) {
        guard !targets.isEmpty else { return }
        // With a session cursor active, Up/Down traverse the detail pane's
        // session list; stepping above the first returns to machine navigation,
        // as does the anchored session disappearing out from under the cursor.
        if let id = browseCursorID {
            browseCursorID = MachineChooserSessionSort.cursorID(
                steppingBy: delta, from: id, in: highlightedSessions)
            return
        }
        select(min(max(selectedIndex + delta, 0), targets.count - 1))
    }

    /// Highlight row `idx`, remember the machine identity under it (so a later
    /// list change can re-anchor to the same machine), and fetch that machine's
    /// session roster so the detail pane fills in.
    private func select(_ idx: Int) {
        if idx != selectedIndex { browseCursorID = nil }
        selectedIndex = idx
        selectedMachineID = machineID(at: idx)
        ensureFetched(resolvedSelection)
    }

    /// The registry UUID of the machine at row `idx`, or nil for the Local
    /// row / out-of-range indexes.
    private func machineID(at idx: Int) -> UUID? {
        guard targets.indices.contains(idx),
              case .remote(let machine) = targets[idx]
        else { return nil }
        return machine.id
    }

    /// Re-anchor the highlight after the target list changed (query edit,
    /// directory fetch/poll, or a removal): follow the previously highlighted
    /// machine to its new row when it still exists, otherwise fall back to
    /// clamping the index and re-anchoring on whatever row that lands on.
    private func reanchorSelection() {
        // The list changed underfoot — drop any session sub-cursor (its roster
        // may have shifted) so the highlight lands cleanly on a machine row.
        browseCursorID = nil
        if let id = selectedMachineID,
           let idx = targets.firstIndex(where: { target in
               if case .remote(let machine) = target { return machine.id == id }
               return false
           }) {
            selectedIndex = idx
            ensureFetched(resolvedSelection)
            return
        }
        clampSelection()
        selectedMachineID = machineID(at: selectedIndex)
        ensureFetched(resolvedSelection)
    }

    /// Clamp `selectedIndex` to the current (possibly newly filtered) list.
    private func clampSelection() {
        guard !targets.isEmpty else { selectedIndex = 0; return }
        selectedIndex = min(max(selectedIndex, 0), targets.count - 1)
    }

    private func submit() {
        // A session sub-cursor (T17) resumes that session; otherwise — and when
        // the anchored session has since left the roster — the selected
        // machine's primary action (New / Restore) fires.
        if let id = browseCursorID, let target = resolvedSelection,
           let session = displayedSessions(target).first(where: { $0.id == id }) {
            resume(session, parent: target)
            return
        }
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
        case 0: return "New Window"
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

/// Presents the window-target chooser as a MODELESS floating panel centered on
/// the active (key) window — or the main screen if there is none — and calls
/// `completion` with the chosen target, or nil if the user cancelled.
///
/// The chooser always lists a "Local" entry first (a normal local window),
/// followed by every registered remote machine. On open it refreshes the relay
/// account's device list (WP-C2) and keeps re-fetching it quietly every few
/// seconds while the chooser stays open, so relay rows carry LIVE online
/// status and may appear/disappear as devices come and go. Callers should
/// special-case the nothing-to-choose case (no machines AND no relay account)
/// before calling this (e.g. just open a local window directly).
/// Reports a user-initiated close (close button, Cmd-W) so the presenter can
/// tear its probes down. A modeless panel has no modal session to end, so this
/// is the only signal that the picker went away.
///
/// Not `private`: the close actions below are a responder-chain contract, and
/// `MachineChooserPanelTests` asserts they exist.
@MainActor
final class MachineChooserPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }

    // MARK: - First Responder

    /// Cmd-W ("Close") and Cmd-Shift-W ("Close Window") while the chooser holds
    /// the keyboard.
    ///
    /// Both menu items send their action to the FIRST RESPONDER, and the
    /// chooser's own chain — a hosting controller over a bare `NSPanel` —
    /// answered neither. AppKit does not stop there: it carries the search on
    /// into the MAIN window, and a panel cannot become main, so the terminal
    /// behind the chooser stayed main and took the hit. Cmd-W over the dialog
    /// closed a pane the user was not even looking at.
    ///
    /// A window's delegate sits in that window's action chain, which makes this
    /// the place to answer — the same reason `AboutController` implements these
    /// two. Closing IS cancelling here, so both route to the one teardown path
    /// the close button and Escape already use.
    @IBAction func close(_ sender: Any) {
        onClose()
    }

    @IBAction func closeWindow(_ sender: Any) {
        onClose()
    }
}

@MainActor
enum MachineChooser {
    /// The open panel and its delegate. `NSApp.runModal` used to retain the
    /// panel AND block `present` until it closed; modeless, nothing else holds
    /// it, so the presenter must.
    private static var openPanel: NSWindow?
    private static var openPanelDelegate: MachineChooserPanelDelegate?

    static func present(
        registry: MachineRegistry = .shared,
        completion: @escaping (WindowTarget?) -> Void
    ) {
        // Modeless means a second invocation would stack a second panel -- the
        // modal session used to make that impossible. Focus the open one.
        if let existing = Self.openPanel {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Capture the window we're presenting over BEFORE we activate/raise our
        // own panel, so we can center on it.
        let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow

        var windowRef: NSWindow?
        // Directory poll for the picker's lifetime (assigned below, before the
        // modal session starts); cancelled in `finish` so no poll outlives the
        // chooser.
        var pollTask: Task<Void, Never>?

        // Live metrics probe for the picker's lifetime. Owns one short-lived
        // connection per remote machine; torn down in `finish` regardless of
        // outcome (pick remote, pick Local, or cancel).
        let probe = MachineMetricsProbe()

        // Session-roster browse for the picker's lifetime (cross-machine resume,
        // T16). Torn down in `finish` like the metrics probe.
        let browser = SessionBrowserProbe()

        // Pushed per-session CPU for the selected row. Owned here, NOT by the
        // view, for the same reason as the two probes above: the view's
        // `.onDisappear` never fires for this modal panel.
        let sessionCPU = SessionCPUProbe()

        // Runs exactly once, however the picker goes away: a pick, Cancel, or the
        // user closing the panel (which arrives via the delegate and re-enters
        // here), so the guard is load-bearing.
        var finished = false
        let finish: (WindowTarget?) -> Void = { target in
            if finished { return }
            finished = true
            // Tear down all probe connections BEFORE handing control back, so
            // no probe connection outlives the picker no matter the choice.
            probe.stop()
            browser.stop()
            sessionCPU.stop()
            pollTask?.cancel()
            if let windowRef {
                windowRef.delegate = nil   // don't re-enter via windowWillClose
                windowRef.close()
            }
            Self.openPanel = nil
            Self.openPanelDelegate = nil
            completion(target)
        }

        let view = MachineChooserView(
            registry: registry,
            probe: probe,
            browser: browser,
            sessionCPU: sessionCPU,
            onSelect: { finish($0) },
            onCancel: { finish(nil) },
            onActivityMonitor: { machine in
                // Dismiss the chooser (tearing down its probes via `finish`),
                // then open the monitor. This Mac uses the in-process Local
                // source — dialing a connection to ourselves would be pointless
                // and would fail whenever no agent is listening.
                finish(nil)
                if let machine {
                    RemoteActivityMonitor.presentDialing(machine: machine)
                } else {
                    RemoteActivityMonitor.presentLocal()
                }
            },
            account: .shared
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSPanel(contentViewController: hosting)
        // Modeless needs its own way out -- under runModal the buttons were the
        // only exits. Floating + not hiding on deactivate means the picker stays
        // visible while you work behind it, which is the whole point: you can
        // close a terminal window and watch the roster update.
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.hidesOnDeactivate = false
        window.title = "New Window"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        let panelDelegate = MachineChooserPanelDelegate { finish(nil) }
        window.delegate = panelDelegate
        Self.openPanel = window
        Self.openPanelDelegate = panelDelegate
        windowRef = window

        // Size the window to the SwiftUI content's natural size BEFORE centering.
        // The master-detail view fixes its size (840×540); force a layout so
        // `fittingSize` returns it, then set the content size. Without this, the
        // panel's frame size is still its default at center time (width ≈ 0 → the
        // left edge lands at the screen midpoint, so it appears shoved right).
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
        // Rows update in place as it lands.
        //
        // NOTE: this comment used to claim the modal-panel runloop mode is a
        // common mode "so main-queue work is delivered". It is not. Under
        // `runModal` every `DispatchQueue.main.async` completion — the
        // session-roster refresh included — sat undelivered until the panel
        // closed, which froze the roster and left closed sessions showing as
        // "Resume" rows. The panel is modeless now, so the main queue drains.
        Task { @MainActor in
            await registry.refreshFromRelay()
        }
        // Keep the list LIVE while the chooser is open: re-fetch the directory
        // every few seconds so online/offline indicators, names, hostnames,
        // and appearing/disappearing devices track reality without reopening.
        // `quiet:` refreshes never flash the footer spinner or transient error
        // text, and the registry's in-flight guard makes a tick that overlaps
        // a slow fetch a no-op (no request pile-up). Ticks are skipped
        // entirely while signed out (no credentials — nothing to poll).
        // Cancelled in `finish`, so the loop cannot outlive the chooser.
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                guard RelayAccount.hasCredentials else { continue }
                await registry.refreshFromRelay(quiet: true)
            }
        }
        // Begin probing remote machines for live metrics now that the picker is
        // on screen. Dials happen off the main thread; rows update as samples
        // arrive (or fall back to "Unreachable"). Relay machines are skipped:
        // the probe dials TCP only, and their subline shows directory status.
        probe.start(registry.machines.filter { !$0.isRelay })
        // Prime the local agent's session count so "this Mac" shows it on the
        // collapsed row (cheap: reuses the warm shared connection, no dial).
        // Remote machines are browsed lazily on expand.
        browser.primeLocal()
        // Prefer a live subscription over the 2s poll: the agent tells us the
        // moment a session is created, exits, is closed, attaches or detaches.
        // Falls back to polling by itself against an older agent, so there is no
        // branch here.
        browser.subscribeLocalPush()
    }
}
