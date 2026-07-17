import AppKit
import Foundation
import GhosttyKit

/// Session persistence (design doc §5, T05): a durable manifest of every
/// LOCAL-agent-backed window's layout so a later launch can rebuild the
/// window — frame, split topology with exact directions/ratios, titles, IPC
/// names — and re-`ATTACH` each leaf to its still-running agent session.
///
/// This is the local sibling of `RemoteSessionManifest` (which records relay
/// remote windows, one session per window). The layout manifest differs in
/// two ways:
///
/// - It records the whole SPLIT TREE per window, with a session id per LEAF,
///   because persistent local windows are expected to carry nontrivial split
///   layouts that must come back exactly (directions, ratios).
/// - It lives in a JSON FILE (`Application Support/<bundle id>/
///   session-layout.json`, atomic tmp+rename writes) rather than
///   UserDefaults, so the E2E harness can assert on it directly and the
///   debug/release lineages stay separate via their bundle ids.
///
/// Lifecycle mirrors `RemoteSessionManifest`:
/// - An entry is **registered** when a window binds to the local agent
///   (`BaseTerminalController.remoteConnection` didSet) and is then kept in
///   sync on every split-tree change, window move/resize (debounced), and
///   title change. Leaf session ids are published asynchronously by the
///   termio thread, so a capture loop re-syncs until every leaf has one.
/// - The entry is **removed on a clean close** (user closed the window; see
///   `BaseTerminalController.windowWillClose`).
/// - The entry is **kept on app quit** (`AppDelegate.isQuitting`) so the next
///   launch can restore it (T06).
///
/// One entry per `TerminalController` — an AppKit tab is its own window +
/// controller, so a "window with tabs" persists as N entries sharing a
/// `tabGroupID` with ascending `tabIndex`. Restore groups them back together.
final class SessionLayoutManifest {
    static let shared = SessionLayoutManifest()

    // MARK: Model

    /// Split direction with stable string raw values so the on-disk JSON is
    /// self-describing (and greppable by the E2E harness).
    enum SplitDirection: String, Codable, Equatable {
        case horizontal
        case vertical
    }

    /// One terminal pane: what T06 needs to re-attach and re-label it.
    struct Leaf: Codable, Equatable {
        /// The agent session UUID to re-`ATTACH` to. Nil until the termio
        /// thread has opened the session and the capture loop recorded the
        /// id; leaves that never resolve one cannot be re-attached (restore
        /// shows them exited).
        var sessionID: String?
        /// The pane's title at last sync (best-effort; live OSC titles take
        /// over after re-attach).
        var title: String?
        /// The IPC target-registry name (`+split --name=...`) so a restored
        /// pane stays addressable by `+send-keys`/`+read`/`+close`.
        var ipcName: String?
        /// The pane's STABLE surface UUID (wp3 pane identity): restore
        /// recreates the SurfaceView with this exact uuid so the `+list`
        /// leaf `id` — and the GHOZTTY_PANE_ID env baked into the still-
        /// running shell at spawn — survive an app relaunch unchanged.
        /// Optional/additive: older manifests decode with nil (restore then
        /// mints a fresh uuid, today's behavior).
        var surfaceID: String?
    }

    /// A parallel codable of `SplitTree.Node` capturing per-leaf session
    /// info instead of live views.
    indirect enum Node: Codable, Equatable {
        case leaf(Leaf)
        case split(Split)

        struct Split: Codable, Equatable {
            let direction: SplitDirection
            let ratio: Double
            let left: Node
            let right: Node
        }
    }

    /// A window frame in screen coordinates. Explicit fields (not NSRect)
    /// so the JSON stays flat and stable.
    struct Frame: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: NSRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    /// One persistent window (one `TerminalController`; a tab is its own
    /// entry sharing a `tabGroupID`).
    struct Entry: Codable, Equatable, Identifiable {
        /// Stable identity for this manifest entry (NOT an agent session id).
        let id: UUID
        /// Window frame at last sync. Nil until the window has appeared.
        var frame: Frame?
        /// The USER-set window title (`titleOverride`), nil when never
        /// renamed (shell-computed titles are transient, not persisted).
        var titleOverride: String?
        /// The IPC target-registry name (`+new-window --target=...`).
        var ipcName: String?
        /// Shared by every entry in one native tab group; nil for a
        /// standalone window. Transient runtime value — only meaningful for
        /// grouping entries of ONE app run back together at restore.
        var tabGroupID: UUID?
        /// Position within the tab group (0 for standalone windows).
        var tabIndex: Int = 0
        /// The split topology. Nil until the first tree sync.
        var tree: Node?
    }

    // MARK: Storage

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [Entry]

    /// Installed by `AppDelegate` (T18): mirror every layout change to the local
    /// `ghoztty-agent` so a viewer on ANOTHER machine can pull the topology and
    /// "Resume all". `onEntryChanged` fires (on the main queue) after an entry is
    /// upserted; `onEntryRemoved` after a clean-close removal. Kept out of the
    /// manifest's own concerns (it stays transport-agnostic) — the app owns the
    /// push. Fired AFTER the lock is released (via `DispatchQueue.main.async`) so
    /// the callback never re-enters the manifest under the lock.
    var onEntryChanged: ((Entry) -> Void)?
    var onEntryRemoved: ((UUID) -> Void)?

    /// Schedule the upsert callback for `entry` on the main queue (post-unlock).
    private func notifyChanged(_ entry: Entry) {
        guard let cb = onEntryChanged else { return }
        DispatchQueue.main.async { cb(entry) }
    }

    /// Schedule the removal callback for `id` on the main queue (post-unlock).
    private func notifyRemoved(_ id: UUID) {
        guard let cb = onEntryRemoved else { return }
        DispatchQueue.main.async { cb(id) }
    }

    /// `Application Support/<bundle id>/session-layout.json`. The debug and
    /// release apps have different bundle ids, so their manifests are
    /// naturally separate files.
    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("session-layout.json")
    }

    init(fileURL: URL = SessionLayoutManifest.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    private func saveLocked() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // .atomic = tmp+rename: a crash mid-write never truncates the
            // manifest (same rationale as the agent's --port-file writer).
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence; the next sync retries.
        }
    }

    // MARK: Mutation

    /// Register a newly-bound persistent window. Fields fill in via `sync`
    /// as the window appears (an entry that never syncs a tree has nothing
    /// to restore and is skipped at launch).
    @discardableResult
    func register() -> UUID {
        let entry = Entry(id: UUID())
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        saveLocked()
        return entry.id
    }

    /// Overwrite an entry's synced fields from a live snapshot. Nil `frame`,
    /// `ipcName`, and `tree` mean "not available right now" and keep the
    /// previous value (window not yet on screen / name registered later /
    /// tree unchanged); `titleOverride`, `tabGroupID`, and `tabIndex` are
    /// authoritative each sync. No-op (and no disk write) when nothing
    /// changed. Unknown ids are a no-op.
    func update(
        _ id: UUID,
        frame: Frame?,
        titleOverride: String?,
        ipcName: String?,
        tabGroupID: UUID?,
        tabIndex: Int,
        tree: Node?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[idx]
        if let frame { entry.frame = frame }
        entry.titleOverride = titleOverride
        if let ipcName { entry.ipcName = ipcName }
        entry.tabGroupID = tabGroupID
        entry.tabIndex = tabIndex
        if let tree { entry.tree = tree }
        guard entry != entries[idx] else { return }
        entries[idx] = entry
        saveLocked()
        notifyChanged(entry)
    }

    /// Record the user-set window title (nil ⇒ rename cleared). Called from
    /// the `titleOverride` didSet choke point so the persisted title is
    /// correct even without a clean quit. Unknown ids are a no-op.
    func updateWindowTitle(_ id: UUID, windowTitle: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[idx].titleOverride != windowTitle else { return }
        entries[idx].titleOverride = windowTitle
        saveLocked()
        notifyChanged(entries[idx])
    }

    /// Remove an entry (clean close). Removing an unknown id is a no-op.
    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        saveLocked()
        notifyRemoved(id)
    }

    /// Read-only snapshot of every entry (tests/diagnostics/restore).
    func allEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Whether the entry still has leaves without a captured session id
    /// (or no tree at all) — drives the capture loop's retry decision.
    func entryHasMissingSessionIDs(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return Self.hasMissingSessionIDs(entry.tree)
    }

    /// Nil tree counts as missing (nothing synced yet ⇒ keep polling).
    static func hasMissingSessionIDs(_ node: Node?) -> Bool {
        guard let node else { return true }
        switch node {
        case .leaf(let leaf):
            return leaf.sessionID == nil
        case .split(let split):
            return hasMissingSessionIDs(split.left)
                || hasMissingSessionIDs(split.right)
        }
    }

    // MARK: Agent-owned blob (T18)

    /// Encode `entry` to the opaque JSON blob pushed to the agent for
    /// cross-machine "Resume all", plus the leaf session ids it references (for
    /// the agent's reaping). Returns nil when the entry has no tree, or no leaf
    /// has a captured session id yet (nothing another machine could attach to).
    static func layoutBlob(for entry: Entry) -> (blob: Data, sessionIDs: [String])? {
        guard let tree = entry.tree else { return nil }
        let ids = leaves(of: tree).compactMap { leaf in
            leaf.sessionID.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard !ids.isEmpty else { return nil }
        guard let blob = try? JSONEncoder().encode(entry) else { return nil }
        return (blob, ids)
    }

    /// Decode an agent-stored blob back into an `Entry` (the resumer side of
    /// "Resume all"). Returns nil on malformed JSON.
    static func decodeBlob(_ data: Data) -> Entry? {
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    // MARK: Tree encoding

    /// Map a live `SplitTree` node to its codable parallel, preserving
    /// directions and ratios exactly. Generic over the view type (pure) so
    /// the mapping is unit-testable without real terminal surfaces.
    static func encodeNode<V: NSView & Codable & Identifiable>(
        _ node: SplitTree<V>.Node,
        leaf leafInfo: (V) -> Leaf
    ) -> Node {
        switch node {
        case .leaf(let view):
            return .leaf(leafInfo(view))
        case .split(let split):
            return .split(Node.Split(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: encodeNode(split.left, leaf: leafInfo),
                right: encodeNode(split.right, leaf: leafInfo)))
        }
    }

    // MARK: Tree decoding (restore)

    /// Inverse of `encodeNode` (T06): build a live `SplitTree` node from the
    /// codable parallel, preserving directions and ratios exactly, calling
    /// `leafView` to construct each pane's view. Generic and pure like
    /// `encodeNode` so the restore-path tree rebuild is unit-testable
    /// without real terminal surfaces.
    static func makeTreeNode<V: NSView & Codable & Identifiable>(
        _ node: Node,
        leaf leafView: (Leaf) -> V
    ) -> SplitTree<V>.Node {
        switch node {
        case .leaf(let leaf):
            return .leaf(view: leafView(leaf))
        case .split(let split):
            return .split(.init(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: makeTreeNode(split.left, leaf: leafView),
                right: makeTreeNode(split.right, leaf: leafView)))
        }
    }

    /// The leaves of a codable tree in tree order (depth-first,
    /// left-before-right) — the same order `makeTreeNode` invokes its leaf
    /// factory and `SplitTree.Node.leaves()` returns views, so restored
    /// views pair with their manifest leaves by position.
    static func leaves(of node: Node) -> [Leaf] {
        switch node {
        case .leaf(let leaf):
            return [leaf]
        case .split(let split):
            return leaves(of: split.left) + leaves(of: split.right)
        }
    }

    // MARK: Live sync

    /// Debounced sync work, keyed by entry id. Main-thread only.
    private var pendingSyncs: [UUID: DispatchWorkItem] = [:]

    /// Stable-for-this-run ids for native tab groups, keyed by group
    /// identity. Transient by design: `tabGroupID` only needs to group
    /// entries of one run back together at the next restore. Main-thread only.
    private var tabGroupIDs: [ObjectIdentifier: UUID] = [:]

    /// Debounce a full snapshot sync for this controller's entry (~250ms):
    /// window drags and rapid split churn fire many triggers, one write
    /// suffices. Each sync then kicks the session-id capture loop.
    @MainActor
    func scheduleSync(_ controller: BaseTerminalController) {
        guard let entryID = controller.sessionLayoutEntryID else { return }
        pendingSyncs[entryID]?.cancel()
        let item = DispatchWorkItem { [weak controller] in
            guard let controller else { return }
            Self.syncAndCaptureSessionIDs(of: controller, entryID: entryID)
        }
        pendingSyncs[entryID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Run every pending debounced sync NOW. Called when a quit begins
    /// (`applicationShouldTerminate`), while every window is still fully
    /// alive, so a change made just before Cmd-Q isn't lost to the debounce
    /// window. (Individual `windowWillClose` during quit must NOT re-sync:
    /// sibling tabs are already closing, so live tab-group state is wrong
    /// there — only the final title is belt-and-braces synced.)
    @MainActor
    func flushPendingSyncs() {
        let items = pendingSyncs
        pendingSyncs.removeAll()
        for (_, item) in items where !item.isCancelled {
            item.perform()
            item.cancel() // the asyncAfter timer still fires; make it a no-op
        }
    }

    /// Sync now, then retry every 0.5s (up to ~30s) while any leaf still
    /// lacks its agent session id — the termio thread publishes ids only
    /// after OPEN completes (async). Same shape as
    /// `RemoteSessionManifest.captureSessionID`, but per-leaf.
    @MainActor
    static func syncAndCaptureSessionIDs(
        of controller: BaseTerminalController,
        entryID: UUID,
        attempt: Int = 0
    ) {
        // The window was closed (entry removed) or re-tracked; stop.
        guard controller.sessionLayoutEntryID == entryID else { return }

        shared.sync(controller)

        guard attempt < 60, shared.entryHasMissingSessionIDs(entryID) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak controller] in
            guard let controller else { return }
            syncAndCaptureSessionIDs(of: controller, entryID: entryID, attempt: attempt + 1)
        }
    }

    /// Snapshot the controller's live state into its entry, then refresh
    /// every sibling entry in the same native tab group. The sibling pass is
    /// what keeps group membership consistent: when a new tab joins (or a
    /// tab is torn off / reordered), only the changed controller gets a sync
    /// trigger, but `tabGroupID`/`tabIndex` changed for ALL members — without
    /// the refresh, restore would see the old members as ungrouped.
    @MainActor
    func sync(_ controller: BaseTerminalController) {
        syncEntry(controller)
        guard let group = controller.window?.tabGroup else { return }
        for sibling in group.windows {
            guard let siblingController = sibling.windowController as? BaseTerminalController,
                  siblingController !== controller,
                  siblingController.sessionLayoutEntryID != nil
            else { continue }
            syncEntry(siblingController)
        }
    }

    /// Snapshot ONE controller's live state into its entry: frame, tab-group
    /// membership, IPC names, title override, and the full split tree with
    /// per-leaf session ids read straight from libghostty. No sibling
    /// refresh — `sync(_:)` layers that on top (depth 1, no recursion).
    @MainActor
    private func syncEntry(_ controller: BaseTerminalController) {
        guard let entryID = controller.sessionLayoutEntryID else { return }
        let ipc = (NSApp.delegate as? AppDelegate)?.ipcServer

        let tree: Node? = controller.surfaceTree.root.map { root in
            Self.encodeNode(root) { view in
                Leaf(
                    // Fall back to the id the surface was CREATED to attach
                    // when the live id is unavailable — surface creation can
                    // fail entirely (dark-wake OutOfMemory, T06b) and a sync
                    // in that state must not wipe the recorded session id
                    // (next launch would then drop the whole entry).
                    sessionID: Self.liveSessionID(of: view) ?? view.expectedRemoteSessionID,
                    title: view.title,
                    ipcName: ipc?.registeredPaneName(forSurface: view),
                    surfaceID: view.id.uuidString)
            }
        }

        var frame: Frame?
        var tabGroupID: UUID?
        var tabIndex = 0
        if let window = controller.window {
            frame = Frame(window.frame)
            // A closed tab can linger in `tabGroup.windows` until AppKit
            // releases it (seen live: the close-path sibling refresh ran
            // 250ms after `windowWillClose` and still counted the closed
            // window, leaving a stale group id). Count only windows that
            // are actually on screen (or minimized).
            if let group = window.tabGroup {
                let members = group.windows.filter { $0.isVisible || $0.isMiniaturized }
                if members.count > 1 {
                    tabGroupID = self.tabGroupID(for: group)
                    tabIndex = members.firstIndex(of: window) ?? 0
                }
            }
        }

        let ipcName: String? = (controller as? TerminalController)
            .flatMap { ipc?.registeredWindowName(forController: $0) }

        update(
            entryID,
            frame: frame,
            titleOverride: controller.titleOverride,
            ipcName: ipcName,
            tabGroupID: tabGroupID,
            tabIndex: tabIndex,
            tree: tree)
    }

    /// The surface's live agent session UUID, nil until OPEN has completed
    /// (the id is published asynchronously by the termio thread).
    @MainActor
    static func liveSessionID(of view: Ghostty.SurfaceView) -> String? {
        guard let surface = view.surface else { return nil }
        let s = Ghostty.AllocatedString(
            ghostty_surface_remote_session_id(surface)).string
        return s.isEmpty ? nil : s
    }

    @MainActor
    private func tabGroupID(for group: NSWindowTabGroup) -> UUID {
        let key = ObjectIdentifier(group)
        if let existing = tabGroupIDs[key] { return existing }
        let id = UUID()
        tabGroupIDs[key] = id
        return id
    }
}
