import AppKit
import GhosttyKit

/// Session persistence (design doc §5, T06): the launch-time restore of
/// local-agent-backed windows recorded in the `SessionLayoutManifest`.
///
/// For every manifest entry this rebuilds the window at its persisted frame,
/// reconstructs the split tree with EXACT directions/ratios (native
/// `SplitTree` nodes — never the +split/+rearrange CLI, which cannot hit
/// exact ratios), and creates each leaf as a `.remote` surface that
/// re-`ATTACH`es its recorded agent session — the agent replays its retained
/// ring, so scrollback comes back and the pane's process was never touched.
///
/// Failure handling, per entry (mirrors the relay `restoreRemoteWindows`):
/// - never synced a tree → dropped (nothing to rebuild)
/// - agent unreachable → ALL entries kept untouched for the next launch
/// - every leaf session gone/uncaptured → dropped silently
/// - SOME leaves gone → the window is still restored; dead leaves ATTACH,
///   fail bring-up, and show their exited overlay (tree shape survives)
///
/// Crash safety: entries are never drained up front. A restored window
/// ADOPTS its existing manifest entry id (set before `remoteConnection`, so
/// the didSet registration hook sees it and does not register a duplicate)
/// and future syncs update the same entry in place — a crash mid-restore
/// leaves every not-yet-restored entry intact for the next launch.
extension AppDelegate {
    /// Kick off the launch-time layout restore. Synchronously marks the
    /// restore pending (suppressing the initial launch window), then dials
    /// the local agent and probes sessions off the main thread.
    func restoreSessionLayoutWindows() {
        guard ghostty.config.sessionPersistence else { return }

        let entries = SessionLayoutManifest.shared.allEntries()
        // Entries that never synced a tree have nothing to restore — drop
        // them now so they don't accumulate.
        for entry in entries where entry.tree == nil {
            SessionLayoutManifest.shared.remove(entry.id)
        }
        let localRestorable = entries.filter { $0.tree != nil }

        // We ALWAYS consult the agent, even when the local manifest is empty.
        // The agent is the crash-durable authority: after an app crash it keeps
        // running with every layout blob (design: sessions "survive app
        // crashes"), while THIS app-local manifest can regress — a crash
        // relaunch that rebuilt nothing then overwrote the file, dropping the
        // windows it never brought back. Reconciling the two here is what makes
        // agent-only windows — exactly the ones an app crash orphans — come
        // back automatically on the next launch instead of only via a manual
        // "Resume all". The agent is already warmed at launch (config load →
        // LocalAgentManager.warmUp), so this dial adds no new spawn.
        hasPendingSessionRestore = true

        LocalAgentManager.shared.sharedConnectionAsync { [weak self] connection in
            guard let self else { return }
            guard let connection else {
                // Agent unreachable: without a connection there is nothing to
                // ATTACH to, so keep every local entry untouched for the next
                // launch (the agent — and its live sessions — outlive this app,
                // so a retry recovers them). Never alert from the restore path.
                if !localRestorable.isEmpty {
                    Self.logger.warning("session restore: local agent unreachable; keeping \(localRestorable.count) manifest entries for next launch")
                }
                self.sessionLayoutRestoreFinished()
                return
            }
            // Pull the agent's authoritative layout roster and reconcile it with
            // the local entries, then liveness-probe every leaf off the main
            // thread (GET_CWD by session id answers ok=false for a dead/unknown
            // session, bounded timeout — same probe as the relay restore).
            DispatchQueue.global(qos: .userInitiated).async {
                let agentEntries = (RemoteLayoutRoster.get(handle: connection.handle) ?? [])
                    .compactMap(\.entry)
                let merged = Self.reconcileLayoutEntries(
                    local: localRestorable, agent: agentEntries)
                let probe = Self.probeSessions(entries: merged, handle: connection.handle)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Adopt agent-only entries into the local manifest so
                    // restore's in-place sync tracks them and they persist here
                    // for the next launch (an id already local is left alone).
                    let localIDs = Set(localRestorable.map(\.id))
                    for entry in merged where !localIDs.contains(entry.id) {
                        SessionLayoutManifest.shared.adopt(entry)
                    }
                    self.presentRestoredSessionWindows(
                        entries: merged,
                        probe: probe,
                        connection: connection)
                    self.sessionLayoutRestoreFinished()
                }
            }
        }
    }

    /// Union the app-local layout entries with the agent's authoritative
    /// roster, keyed by manifest entry id. Local entries come first (preserving
    /// manifest order) and WIN on an id collision — the local copy is written
    /// before the agent push, so a crash can only make it fresher, never
    /// staler. Agent-only entries (the windows an app crash orphaned, kept alive
    /// by the ever-running agent) are appended in agent order. Entries without a
    /// tree are skipped on both sides. Pure/static so it is unit-testable
    /// without a live agent.
    static func reconcileLayoutEntries(
        local: [SessionLayoutManifest.Entry],
        agent: [SessionLayoutManifest.Entry]
    ) -> [SessionLayoutManifest.Entry] {
        var byID: [UUID: SessionLayoutManifest.Entry] = [:]
        var order: [UUID] = []
        for entry in local where entry.tree != nil {
            if byID[entry.id] == nil { order.append(entry.id) }
            byID[entry.id] = entry
        }
        for entry in agent where entry.tree != nil {
            guard byID[entry.id] == nil else { continue }
            byID[entry.id] = entry
            order.append(entry.id)
        }
        return order.compactMap { byID[$0] }
    }

    /// Restore is over (windows built, or nothing restorable). If it ended
    /// with zero windows on screen (agent dead, every session gone), give
    /// the user the initial window a plain launch would have opened — its
    /// creation was suppressed by `hasPendingSessionRestore` meanwhile.
    @MainActor
    private func sessionLayoutRestoreFinished() {
        hasPendingSessionRestore = false
        if TerminalController.all.isEmpty && ghostty.config.initialWindow {
            undoManager.disableUndoRegistration()
            _ = TerminalController.newWindow(ghostty)
            undoManager.enableUndoRegistration()
        }
    }

    /// The tri-state liveness of every recorded session id (T06b). Blocking
    /// (bounded per-session RPC timeout) — background queue only.
    ///
    /// The distinction is what makes the drop policy safe: an empty
    /// `query_cwd` reply is NOT proof a session is gone (seen live: a fast
    /// relaunch races the agent's dead-peer detection, so every probe comes
    /// back empty while every shell is still alive). Only a POSITIVE
    /// not-found from the agent may forget a persisted entry; a
    /// timeout/transport failure / older-agent reply stays `.unknown` and the
    /// entry is kept.
    enum SessionLiveness { case alive, dead, unknown }

    private static func probeSessions(
        entries: [SessionLayoutManifest.Entry],
        handle: ghostty_remote_connection_t
    ) -> [String: SessionLiveness] {
        var result = [String: SessionLiveness]()
        for entry in entries {
            guard let tree = entry.tree else { continue }
            for leaf in SessionLayoutManifest.leaves(of: tree) {
                guard let sid = leaf.sessionID, !sid.isEmpty,
                      result[sid] == nil else { continue }
                let code = sid.withCString {
                    ghostty_remote_connection_probe_session(handle, $0, 5000)
                }
                result[sid] = switch code {
                case 1: .alive
                case 0: .dead
                default: .unknown
                }
            }
        }
        return result
    }

    /// Build every restorable window on the main thread. Entries sharing a
    /// `tabGroupID` come back as native tabs of one window, in `tabIndex`
    /// order; the rest are standalone windows in manifest order.
    @MainActor
    private func presentRestoredSessionWindows(
        entries: [SessionLayoutManifest.Entry],
        probe: [String: SessionLiveness],
        connection: RemoteConnection
    ) {
        // Double-restore guard: an entry already bound to an open window
        // (its controller carries the entry id) must not be rebuilt — the
        // second ATTACH would evict the live pane.
        let openEntryIDs = Set(TerminalController.all.compactMap(\.sessionLayoutEntryID))

        // Group tab siblings, preserving manifest order between groups.
        var groups: [[SessionLayoutManifest.Entry]] = []
        var groupIndex: [UUID: Int] = [:]
        for entry in entries {
            if let gid = entry.tabGroupID {
                if let idx = groupIndex[gid] {
                    groups[idx].append(entry)
                } else {
                    groupIndex[gid] = groups.count
                    groups.append([entry])
                }
            } else {
                groups.append([entry])
            }
        }

        var restoredCount = 0
        for group in groups {
            var tabParent: NSWindow?
            for entry in group.sorted(by: { $0.tabIndex < $1.tabIndex }) {
                guard !openEntryIDs.contains(entry.id), let tree = entry.tree else { continue }

                // Drop policy (T06b): forget an entry ONLY when every leaf is
                // POSITIVELY dead. A leaf whose probe was inconclusive
                // (`.unknown` — fast-relaunch race, timeout, older agent) or a
                // leaf with no recorded id is NOT proof the session is gone, so
                // the entry is kept and rebuilt; `.unknown` leaves attach and
                // (if the agent truly lost them) show their exited overlay,
                // while a live session re-attaches normally. Losing a persisted
                // layout to a transient probe failure is worse than a stale
                // entry that recovers on the next launch.
                let leaves = SessionLayoutManifest.leaves(of: tree)
                let liveness: (SessionLayoutManifest.Leaf) -> SessionLiveness = { leaf in
                    guard let sid = leaf.sessionID, !sid.isEmpty else { return .unknown }
                    return probe[sid] ?? .unknown
                }
                let allDead = leaves.allSatisfy { liveness($0) == .dead }
                guard !allDead else {
                    Self.logger.info("session restore: all \(leaves.count) leaf sessions POSITIVELY dead; dropping entry \(entry.id.uuidString, privacy: .public)")
                    SessionLayoutManifest.shared.remove(entry.id)
                    continue
                }

                if let controller = presentRestoredSessionWindow(
                    entry: entry,
                    connection: connection,
                    tabParent: tabParent
                ) {
                    restoredCount += 1
                    tabParent = controller.window ?? tabParent
                }
            }
        }
        if restoredCount > 0 {
            Self.logger.info("session restore: restored \(restoredCount) window(s)")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Rebuild ONE window from its manifest entry: split tree with per-leaf
    /// ATTACH surfaces, frame, title override, IPC names. Returns nil only
    /// if libghostty is not initialized (cannot create surfaces).
    @MainActor
    private func presentRestoredSessionWindow(
        entry: SessionLayoutManifest.Entry,
        connection: RemoteConnection,
        tabParent: NSWindow?,
        bindLocal: Bool = true,
        reanchorFrame: Bool = false
    ) -> TerminalController? {
        guard let app = ghostty.app, let tree = entry.tree else { return nil }

        // Each leaf ATTACHes its recorded session over the connection. Dead
        // sessions attach anyway and show their exited overlay — the tree shape
        // must survive partial death.
        let root = Self.makeSessionLayoutRoot(tree: tree, connection: connection, app: app)

        let controller = TerminalController(
            ghostty,
            withSurfaceTree: SplitTree(root: root, zoomed: nil))

        // For a LOCAL resume/restore, adopt the manifest entry so the window is
        // itself restorable and detaches-on-close. Ordering matters: the entry id
        // must be set before `remoteConnection` (whose didSet would otherwise
        // register a DUPLICATE entry for a local-machine connection) and before
        // the window loads (windowDidLoad gates AppKit restorability off for
        // tracked windows). For a cross-machine resume (`bindLocal == false`) the
        // entry id belongs to the OTHER machine — leave it unbound; the remote
        // connection is not `isLocalMachine`, so the didSet registers nothing.
        if bindLocal { controller.sessionLayoutEntryID = entry.id }
        controller.remoteConnection = connection
        controller.remoteMachine = connection.machine

        guard let window = controller.window else { return controller }
        if bindLocal {
            // The window usually loaded during init, BEFORE the entry id above
            // bound — re-apply the AppKit-restoration gate now that it has.
            controller.disableAppKitRestorationForSessionLayout()
        }

        if let tabParent {
            if tabParent.isMiniaturized { tabParent.deminiaturize(nil) }
            tabParent.addTabbedWindowSafely(window, ordered: .above)
        }
        // Standalone windows (and the first tab of a group) get their persisted
        // frame BEFORE showWindow as well: the surfaces' first real layout (and
        // therefore the grid size their termio threads carry into ATTACH) then
        // happens at the final size instead of the config default, so the
        // agent-side PTY winsize starts correct instead of relying on a
        // corrective RESIZE after the window grows ("big window, small
        // content"). showWindow can re-apply default sizing on the way to
        // screen, so the frame is asserted again right after (that second set
        // is a no-op when showWindow left it alone).
        let persistedRect: NSRect? = if tabParent == nil, let frame = entry.frame {
            reanchorFrame ? Self.reanchoredFrame(frame.rect) : frame.rect
        } else { nil }
        if let rect = persistedRect {
            window.setFrame(rect, display: true)
        }
        controller.showWindow(self)
        // Tab siblings inherit the group's frame. A cross-machine resume
        // re-anchors the frame to a visible local screen (the owning machine's
        // coordinates may be off every display here).
        if let rect = persistedRect {
            window.setFrame(rect, display: true)
        }

        // The user-set window title, through the same property a manual
        // rename sets, so it survives later shell OSC title updates.
        if let title = entry.titleOverride, !title.isEmpty {
            controller.titleOverride = title
        }

        // The user-set WINDOW-level title (pins the titlebar over any
        // tab/pane title). Per-controller storage, so restore order within
        // a tab group doesn't matter — the group scan finds the holder.
        if let title = entry.windowTitleOverride, !title.isEmpty {
            controller.windowTitleOverride = title
        }

        // Put restored windows/panes back in the IPC target registry under
        // their persisted names (existing live registrations win — same
        // idempotent semantics as the CLI). Only for a LOCAL resume/restore: a
        // cross-machine resumed window is not addressable by the OTHER machine's
        // names (they belong to that machine's IPC namespace).
        let leafInfos = SessionLayoutManifest.leaves(of: tree)
        let views = root.leaves()
        if bindLocal {
            if let name = entry.ipcName, !name.isEmpty {
                ipcServer.registerRestoredRemoteWindow(name: name, controller: controller)
            }
            for (leaf, pane) in zip(leafInfos, views) {
                guard let name = leaf.ipcName, !name.isEmpty else { continue }
                if let surface = pane.surfaceView {
                    ipcServer.registerRestoredPane(name: name, controller: controller, surface: surface)
                } else if pane.viewerView != nil {
                    ipcServer.registerRestoredViewerPane(name: name, controller: controller, pane: pane)
                }
            }
        }

        // Focus the first pane (parity with a fresh window; AppKit's own
        // restoration does the same when no focus record exists).
        if let first = views.first {
            controller.focusedSurface = first.surfaceView
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: first, from: nil)
            }
        }

        // Re-sync the adopted entry against the live window (frame after
        // showWindow, confirmed session ids once the termio threads publish
        // them — dropped leaves may have changed the recorded topology). Only
        // when the entry is bound to the LOCAL manifest.
        if bindLocal {
            SessionLayoutManifest.syncAndCaptureSessionIDs(of: controller, entryID: entry.id)
        }

        return controller
    }

    /// Clamp a window frame that came from ANOTHER machine's manifest onto a
    /// visible local screen (T18 cross-machine "Resume all"): if the frame does
    /// not intersect any screen (the owning machine had a different display
    /// arrangement), re-center a same-sized window on the main screen's visible
    /// area, also shrinking it to fit if necessary.
    @MainActor
    private static func reanchoredFrame(_ rect: NSRect) -> NSRect {
        let intersectsAny = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        if intersectsAny { return rect }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 100, y: 100, width: 800, height: 600)
        let w = min(rect.width, visible.width)
        let h = min(rect.height, visible.height)
        let x = visible.origin.x + (visible.width - w) / 2
        let y = visible.origin.y + (visible.height - h) / 2
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Build a live split-tree root from a manifest tree, each leaf a `.remote`
    /// surface that re-`ATTACH`es its recorded session over `connection`. Shared
    /// by launch restore (`presentRestoredSessionWindow`) and in-place recovery
    /// (`rebuildSessionLayoutController`). Dead sessions attach anyway and show
    /// their exited overlay (or, when the agent restarted, auto-RELAUNCH) — the
    /// tree shape must survive partial death.
    @MainActor
    static func makeSessionLayoutRoot(
        tree: SessionLayoutManifest.Node,
        connection: RemoteConnection,
        app: ghostty_app_t
    ) -> SplitTree<PaneView>.Node {
        SessionLayoutManifest.makeTreeNode(tree) { leaf -> PaneView in
            // Viewer leaves have no agent session: restore by re-opening the
            // viewed file/URL. Missing files render an in-page error rather
            // than failing the tree.
            if leaf.isViewer {
                return PaneView(viewer: ViewerView(location: leaf.viewerLocation ?? ""))
            }

            var cfg = Ghostty.SurfaceConfiguration()
            cfg.remoteMachine = connection.machine
            cfg.remoteConnection = connection.handle
            cfg.connectionKeepAlive = connection
            cfg.remoteSessionId = leaf.sessionID
            // Recreate the pane under its PERSISTED surface uuid (wp3 pane
            // identity) so `+list` ids and the shell's baked GHOZTTY_PANE_ID
            // stay valid across the relaunch. Nil (older manifest) mints fresh.
            let view = Ghostty.SurfaceView(
                app,
                baseConfig: cfg,
                uuid: leaf.surfaceID.flatMap { UUID(uuidString: $0) })
            // Seed the last-synced pane title; live OSC titles (if the
            // session emits them) take over after re-attach.
            if let title = leaf.title, !title.isEmpty { view.setTitle(title) }
            return PaneView(surface: view)
        }
    }

    // MARK: In-place recovery (T12e)

    /// The shared local-agent connection's transport dropped while the app
    /// stayed up — the agent crashed and launchd (KeepAlive, T12d) is bringing
    /// a NEW one back. Re-dial the restarted agent ONCE and rebuild every open
    /// local-agent window in place: each leaf re-`ATTACH`es its recorded
    /// session, finds a relaunchable tombstone (the restarted agent
    /// materialized it from disk metadata, T12b), and auto-RELAUNCHes with the
    /// "--- session restarted ---" banner (T12c). No app relaunch; the local
    /// machine pill is never shown (isLocalMachine). Wired to
    /// `LocalAgentManager.onSharedConnectionDrop`. Main-thread only.
    @MainActor
    func recoverSessionLayoutInPlace() {
        guard ghostty.config.sessionPersistence else { return }
        // Quit deliberately closes the transport; don't fight it.
        guard !isQuitting else { return }
        // A `reconnecting → dead` double-edge (or a second drop mid-recovery)
        // must not kick two concurrent re-dials.
        guard !isRecoveringSessionLayout else { return }

        // Only windows actually backed by the local agent (a bound layout entry).
        let hasLocalWindows = TerminalController.all.contains {
            $0.sessionLayoutEntryID != nil
        }
        guard hasLocalWindows else {
            // Nothing to rebuild: drop the dead shared connection so the next
            // new window re-dials it lazily.
            LocalAgentManager.shared.invalidateShared()
            return
        }

        isRecoveringSessionLayout = true
        Self.logger.warning(
            "session recovery: shared local-agent link dropped; re-dialing the restarted agent to rebuild local windows in place")

        LocalAgentManager.shared.reconnectSharedForRecovery { [weak self] connection in
            guard let self else { return }
            defer { self.isRecoveringSessionLayout = false }
            guard let connection else {
                Self.logger.error(
                    "session recovery: local agent did not come back; local windows stay disconnected until the next app relaunch")
                return
            }
            self.rebuildOpenSessionLayoutWindows(connection: connection)
        }
    }

    /// Rebuild every currently-open local-agent window onto the freshly-dialed
    /// `connection`. Controllers that closed during the re-dial are skipped.
    /// Main-thread only.
    @MainActor
    private func rebuildOpenSessionLayoutWindows(connection: RemoteConnection) {
        guard let app = ghostty.app else { return }
        let entries = Dictionary(
            SessionLayoutManifest.shared.allEntries().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var rebuilt = 0
        for controller in TerminalController.all {
            guard let entryID = controller.sessionLayoutEntryID,
                  let entry = entries[entryID],
                  let tree = entry.tree else { continue }
            rebuildSessionLayoutController(
                controller, entry: entry, tree: tree, connection: connection, app: app)
            rebuilt += 1
        }
        if rebuilt > 0 {
            Self.logger.warning(
                "session recovery: rebuilt \(rebuilt) local window(s) on the restarted agent")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Rebuild ONE already-open controller's split tree in place on `connection`
    /// (the WP-D1 reconnect-swap mechanism — replace `surfaceTree` on the live
    /// controller — but with the FULL manifest topology, not a single root
    /// pane). The window/frame/title stay; the old dead-transport surfaces are
    /// released with the old tree, and the old shared connection frees once its
    /// last surface deallocates. Main-thread only.
    @MainActor
    private func rebuildSessionLayoutController(
        _ controller: TerminalController,
        entry: SessionLayoutManifest.Entry,
        tree: SessionLayoutManifest.Node,
        connection: RemoteConnection,
        app: ghostty_app_t
    ) {
        let root = Self.makeSessionLayoutRoot(tree: tree, connection: connection, app: app)

        // Adopt the fresh connection (didSet rebinds the link observer to it;
        // the entry id is already bound so no duplicate registration) and swap
        // the rebuilt tree in.
        controller.remoteConnection = connection
        controller.remoteMachine = connection.machine
        controller.surfaceTree = SplitTree(root: root, zoomed: nil)

        // Re-register pane IPC names against the NEW surfaces (the window name,
        // being controller-keyed, is unaffected — the controller is the same).
        let leafInfos = SessionLayoutManifest.leaves(of: tree)
        let views = root.leaves()
        for (leaf, pane) in zip(leafInfos, views) {
            guard let name = leaf.ipcName, !name.isEmpty else { continue }
            if let surface = pane.surfaceView {
                ipcServer.registerRestoredPane(
                    name: name, controller: controller, surface: surface)
            } else if pane.viewerView != nil {
                ipcServer.registerRestoredViewerPane(
                    name: name, controller: controller, pane: pane)
            }
        }

        if let first = views.first {
            controller.focusedSurface = first.surfaceView
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: first, from: nil)
            }
        }

        // The relaunched shells publish fresh session ids; re-sync so the
        // manifest tracks them for the NEXT restore.
        SessionLayoutManifest.syncAndCaptureSessionIDs(of: controller, entryID: entry.id)
    }

    // MARK: Resume all (T18)

    /// Resume ALL of `machine`'s windows on the local machine: pull the
    /// agent-owned layout blobs (`GET_LAYOUTS`) + probe each leaf's liveness over
    /// the machine's transport, then rebuild the full window/tab/split topology
    /// locally, ATTACHing each leaf to its still-running session. The processes
    /// keep running on their host agent; only the viewer windows are local.
    /// `machine == nil` ⇒ the LOCAL agent, and the rebuild is sourced from the
    /// AGENT's copy of the layout (not the local file), so it works even with an
    /// empty local manifest — the property another machine relies on.
    /// User-initiated, so failures surface an alert.
    @MainActor
    func resumeAllSessions(machine: Machine?) {
        if let machine {
            resumeAllRemoteSessions(machine: machine)
        } else {
            resumeAllLocalSessions()
        }
    }

    @MainActor
    private func resumeAllLocalSessions() {
        LocalAgentManager.shared.sharedConnectionAsync { [weak self] connection in
            guard let self else { return }
            guard let connection else {
                self.presentResumeAllUnreachable(name: "the local session agent")
                return
            }
            self.pullAndResumeAll(connection: connection, bindLocal: true, reanchor: false)
        }
    }

    @MainActor
    private func resumeAllRemoteSessions(machine: Machine) {
        if let base = machine.relayBase, let device = machine.deviceID {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let token = await RelayAccount.resolveToken() else {
                    Self.presentSignInRequiredAlert()
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let handle = AppDelegate.dialRelay(base: base, device: device, token: token)
                    DispatchQueue.main.async {
                        guard let self else {
                            if let handle { ghostty_remote_connection_free(handle) }
                            return
                        }
                        guard let handle else {
                            self.presentResumeAllUnreachable(name: machine.name)
                            return
                        }
                        let connection = RemoteConnection(handle: handle, machine: machine)
                        self.pullAndResumeAll(connection: connection, bindLocal: false, reanchor: true)
                    }
                }
            }
        } else {
            let host = machine.host
            let port = machine.port
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let handle = host.withCString { ghostty_remote_connection_new_tcp($0, port) }
                DispatchQueue.main.async {
                    guard let self else {
                        if let handle { ghostty_remote_connection_free(handle) }
                        return
                    }
                    guard let handle else {
                        self.presentResumeAllUnreachable(name: machine.name)
                        return
                    }
                    let connection = RemoteConnection(handle: handle, machine: machine)
                    self.pullAndResumeAll(connection: connection, bindLocal: false, reanchor: true)
                }
            }
        }
    }

    /// GET_LAYOUTS + liveness-probe off the main thread, then rebuild on main.
    @MainActor
    private func pullAndResumeAll(connection: RemoteConnection, bindLocal: Bool, reanchor: Bool) {
        let handle = connection.handle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let layouts = RemoteLayoutRoster.get(handle: handle) ?? []
            let entries = layouts.compactMap { $0.entry }
            let probe = Self.probeSessions(entries: entries, handle: handle)
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentResumedTopology(
                    entries: entries,
                    probe: probe,
                    connection: connection,
                    bindLocal: bindLocal,
                    reanchor: reanchor)
            }
        }
    }

    /// Rebuild every window in `entries` on `connection` (mirrors
    /// `presentRestoredSessionWindows`: group tab siblings, drop all-dead
    /// windows, build each). `bindLocal` adopts the local manifest (local resume,
    /// so the windows are restorable again); `reanchor` re-clamps frames onto a
    /// visible local screen (cross-machine).
    @MainActor
    private func presentResumedTopology(
        entries: [SessionLayoutManifest.Entry],
        probe: [String: SessionLiveness],
        connection: RemoteConnection,
        bindLocal: Bool,
        reanchor: Bool
    ) {
        guard !entries.isEmpty else {
            presentResumeAllEmpty()
            return
        }

        // For a LOCAL resume, skip an entry already bound to an open window (the
        // double-attach guard). For a cross-machine resume the entry ids belong
        // to the other machine, so the guard doesn't apply.
        let openEntryIDs = bindLocal
            ? Set(TerminalController.all.compactMap(\.sessionLayoutEntryID))
            : Set<UUID>()

        // Group tab siblings, preserving order between groups.
        var groups: [[SessionLayoutManifest.Entry]] = []
        var groupIndex: [UUID: Int] = [:]
        for entry in entries {
            if let gid = entry.tabGroupID {
                if let idx = groupIndex[gid] {
                    groups[idx].append(entry)
                } else {
                    groupIndex[gid] = groups.count
                    groups.append([entry])
                }
            } else {
                groups.append([entry])
            }
        }

        var resumedCount = 0
        for group in groups {
            var tabParent: NSWindow?
            for entry in group.sorted(by: { $0.tabIndex < $1.tabIndex }) {
                if openEntryIDs.contains(entry.id) { continue }
                guard let tree = entry.tree else { continue }

                // Skip a window whose leaves are ALL positively dead — nothing
                // live to attach. `.unknown` leaves are rebuilt (attach anyway).
                let leaves = SessionLayoutManifest.leaves(of: tree)
                let liveness: (SessionLayoutManifest.Leaf) -> SessionLiveness = { leaf in
                    guard let sid = leaf.sessionID, !sid.isEmpty else { return .unknown }
                    return probe[sid] ?? .unknown
                }
                if leaves.allSatisfy({ liveness($0) == .dead }) { continue }

                if let controller = presentRestoredSessionWindow(
                    entry: entry,
                    connection: connection,
                    tabParent: tabParent,
                    bindLocal: bindLocal,
                    reanchorFrame: reanchor
                ) {
                    resumedCount += 1
                    tabParent = controller.window ?? tabParent
                }
            }
        }

        if resumedCount > 0 {
            Self.logger.info("resume all: rebuilt \(resumedCount) window(s)")
            NSApp.activate(ignoringOtherApps: true)
        } else {
            presentResumeAllEmpty()
        }
    }

    @MainActor
    private func presentResumeAllUnreachable(name: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't resume sessions"
        alert.informativeText = "\(name) is not reachable."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func presentResumeAllEmpty() {
        let alert = NSAlert()
        alert.messageText = "Nothing to resume"
        alert.informativeText = "No saved window layout was found for this machine, or its sessions are no longer running. You can still resume individual sessions from the list."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
