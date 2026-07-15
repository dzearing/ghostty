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
                let alive = Self.probeSessions(entries: restorable, handle: connection.handle)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.presentRestoredSessionWindows(
                        entries: restorable,
                        alive: alive,
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

    /// The set of recorded session ids the agent still knows. Blocking
    /// (bounded per-session RPC timeout) — background queue only.
    private static func probeSessions(
        entries: [SessionLayoutManifest.Entry],
        handle: ghostty_remote_connection_t
    ) -> Set<String> {
        var alive = Set<String>()
        var probed = Set<String>()
        for entry in entries {
            guard let tree = entry.tree else { continue }
            for leaf in SessionLayoutManifest.leaves(of: tree) {
                guard let sid = leaf.sessionID, !sid.isEmpty,
                      probed.insert(sid).inserted else { continue }
                let cwd = sid.withCString {
                    Ghostty.AllocatedString(
                        ghostty_remote_connection_query_cwd_timeout(handle, $0, 5000)).string
                }
                if !cwd.isEmpty { alive.insert(sid) }
            }
        }
        return alive
    }

    /// Build every restorable window on the main thread. Entries sharing a
    /// `tabGroupID` come back as native tabs of one window, in `tabIndex`
    /// order; the rest are standalone windows in manifest order.
    @MainActor
    private func presentRestoredSessionWindows(
        entries: [SessionLayoutManifest.Entry],
        alive: Set<String>,
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

                // An entry with no live leaf has nothing to re-attach: drop
                // it (uncaptured ids count as dead — attaching nil would
                // OPEN a fresh session, which is not this entry's session).
                let leaves = SessionLayoutManifest.leaves(of: tree)
                let liveLeaves = leaves.filter { $0.sessionID.map(alive.contains) == true }
                guard !liveLeaves.isEmpty else {
                    Self.logger.info("session restore: all \(leaves.count) leaf sessions gone; dropping entry \(entry.id.uuidString, privacy: .public)")
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
        let root = SessionLayoutManifest.makeTreeNode(tree) { leaf -> Ghostty.SurfaceView in
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
}
