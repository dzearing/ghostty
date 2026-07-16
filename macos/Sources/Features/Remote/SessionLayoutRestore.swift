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
        let restorable = entries.filter { $0.tree != nil }
        guard !restorable.isEmpty else { return }

        hasPendingSessionRestore = true

        LocalAgentManager.shared.sharedConnectionAsync { [weak self] connection in
            guard let self else { return }
            guard let connection else {
                // Agent unreachable: keep every entry untouched so the next
                // launch retries; never alert from the restore path.
                Self.logger.warning("session restore: local agent unreachable; keeping \(restorable.count) manifest entries for next launch")
                self.sessionLayoutRestoreFinished()
                return
            }
            // Liveness-probe every leaf session off the main thread (GET_CWD
            // by session id answers ok=false for a dead/unknown session,
            // bounded timeout — same probe as the relay restore).
            DispatchQueue.global(qos: .userInitiated).async {
                let probe = Self.probeSessions(entries: restorable, handle: connection.handle)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.presentRestoredSessionWindows(
                        entries: restorable,
                        probe: probe,
                        connection: connection)
                    self.sessionLayoutRestoreFinished()
                }
            }
        }
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
        tabParent: NSWindow?
    ) -> TerminalController? {
        guard let app = ghostty.app, let tree = entry.tree else { return nil }

        // Each leaf ATTACHes its recorded session over the shared local-agent
        // connection. Dead sessions attach anyway and show their exited
        // overlay — the tree shape must survive partial death.
        let root = Self.makeSessionLayoutRoot(tree: tree, connection: connection, app: app)

        let controller = TerminalController(
            ghostty,
            withSurfaceTree: SplitTree(root: root, zoomed: nil))

        // Adopt the EXISTING manifest entry. Ordering matters: the entry id
        // must be set before `remoteConnection` (whose didSet would register
        // a duplicate entry) and before the window loads (whose windowDidLoad
        // gates AppKit restorability off for tracked windows).
        controller.sessionLayoutEntryID = entry.id
        controller.remoteConnection = connection
        controller.remoteMachine = connection.machine

        guard let window = controller.window else { return controller }
        // The window usually loaded during init, BEFORE the entry id above
        // bound — re-apply the AppKit-restoration gate now that it has.
        controller.disableAppKitRestorationForSessionLayout()

        if let tabParent {
            if tabParent.isMiniaturized { tabParent.deminiaturize(nil) }
            tabParent.addTabbedWindowSafely(window, ordered: .above)
        }
        controller.showWindow(self)
        // Standalone windows (and the first tab of a group) get their exact
        // persisted frame — AFTER showWindow, which applies config default
        // size/position on the way to screen. Tab siblings inherit the
        // group's frame.
        if tabParent == nil, let frame = entry.frame {
            window.setFrame(frame.rect, display: true)
        }

        // The user-set window title, through the same property a manual
        // rename sets, so it survives later shell OSC title updates.
        if let title = entry.titleOverride, !title.isEmpty {
            controller.titleOverride = title
        }

        // Put restored windows/panes back in the IPC target registry under
        // their persisted names (existing live registrations win — same
        // idempotent semantics as the CLI).
        if let name = entry.ipcName, !name.isEmpty {
            ipcServer.registerRestoredRemoteWindow(name: name, controller: controller)
        }
        let leafInfos = SessionLayoutManifest.leaves(of: tree)
        let views = root.leaves()
        for (leaf, view) in zip(leafInfos, views) {
            if let name = leaf.ipcName, !name.isEmpty {
                ipcServer.registerRestoredPane(name: name, controller: controller, surface: view)
            }
        }

        // Focus the first pane (parity with a fresh window; AppKit's own
        // restoration does the same when no focus record exists).
        if let first = views.first {
            controller.focusedSurface = first
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: first, from: nil)
            }
        }

        // Re-sync the adopted entry against the live window (frame after
        // showWindow, confirmed session ids once the termio threads publish
        // them — dropped leaves may have changed the recorded topology).
        SessionLayoutManifest.syncAndCaptureSessionIDs(of: controller, entryID: entry.id)

        return controller
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
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        SessionLayoutManifest.makeTreeNode(tree) { leaf -> Ghostty.SurfaceView in
            var cfg = Ghostty.SurfaceConfiguration()
            cfg.remoteMachine = connection.machine
            cfg.remoteConnection = connection.handle
            cfg.connectionKeepAlive = connection
            cfg.remoteSessionId = leaf.sessionID
            let view = Ghostty.SurfaceView(app, baseConfig: cfg)
            // Seed the last-synced pane title; live OSC titles (if the
            // session emits them) take over after re-attach.
            if let title = leaf.title, !title.isEmpty { view.setTitle(title) }
            return view
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
        for (leaf, view) in zip(leafInfos, views) {
            if let name = leaf.ipcName, !name.isEmpty {
                ipcServer.registerRestoredPane(
                    name: name, controller: controller, surface: view)
            }
        }

        if let first = views.first {
            controller.focusedSurface = first
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: first, from: nil)
            }
        }

        // The relaunched shells publish fresh session ids; re-sync so the
        // manifest tracks them for the NEXT restore.
        SessionLayoutManifest.syncAndCaptureSessionIDs(of: controller, entryID: entry.id)
    }
}
