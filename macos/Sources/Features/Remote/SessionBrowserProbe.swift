import Foundation
import GhosttyKit

/// One session as reported by an agent's `LIST_SESSIONS` RPC, decoded from the
/// JSON emitted by `ghostty_remote_connection_list_sessions`. Read-only browse
/// model for the Cmd-Shift-N session browser (T16); the actual attach (T17)
/// only needs `id`.
struct BrowsedSession: Identifiable, Hashable, Decodable {
    let id: String
    let alive: Bool
    let attached: Bool
    let activity: String
    let pid: Int64
    let cwd: String?
    let argv: String?
    let title: String?
    let exitCode: Int64?
    let createdAt: Int64
    let lastActivity: Int64
    let pinned: Bool
    /// True when this is a DEAD reboot-floor tombstone the agent materialized from
    /// disk and can bring back via `RELAUNCH` (the legitimate Resume case) — as
    /// opposed to a child that genuinely exited (dead, not relaunchable), which is
    /// a dead-end. Optional/defaulted so an older agent that omits the field
    /// decodes as `false` (forward-compatible, cf. the agent-contract rule).
    let relaunchable: Bool

    enum CodingKeys: String, CodingKey {
        case id, alive, attached, activity, pid, cwd, argv, title, pinned, relaunchable
        case exitCode = "exit_code"
        case createdAt = "created_at"
        case lastActivity = "last_activity"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive) ?? true
        attached = try c.decodeIfPresent(Bool.self, forKey: .attached) ?? false
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? "idle"
        pid = try c.decodeIfPresent(Int64.self, forKey: .pid) ?? 0
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        argv = try c.decodeIfPresent(String.self, forKey: .argv)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        exitCode = try c.decodeIfPresent(Int64.self, forKey: .exitCode)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        lastActivity = try c.decodeIfPresent(Int64.self, forKey: .lastActivity) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        relaunchable = try c.decodeIfPresent(Bool.self, forKey: .relaunchable) ?? false
    }

    /// A session worth showing in the chooser: still alive (resumable/showable) or
    /// a relaunchable reboot-floor tombstone (resumable via RELAUNCH). A dead,
    /// non-relaunchable tombstone is an unreconnectable dead-end — filtered out as
    /// a client-side backstop to the agent's own immediate reap of such rows.
    var isConnectable: Bool { alive || relaunchable }

    /// A human label for the row, most-current first:
    /// - `liveTitle`: the title of an OPEN pane bound to this session, read
    ///   straight from the app — the freshest source, so a pane RENAME shows
    ///   immediately (the agent does not track title renames).
    /// - the agent-reported `title` (captured at session creation / relaunch).
    /// - `persistedTitle`: the saved layout title (so a name still shows for a
    ///   relaunched-but-not-yet-retitled session across app restarts).
    /// - the last path component of the cwd, then the command, and finally — the
    ///   ultimate fallback — the actual pid (an opaque short session id reads like
    ///   a pid and means nothing, so we show the real pid instead).
    func label(liveTitle: String? = nil, persistedTitle: String? = nil) -> String {
        if let liveTitle, !liveTitle.isEmpty { return liveTitle }
        if let title, !title.isEmpty { return title }
        if let persistedTitle, !persistedTitle.isEmpty { return persistedTitle }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        if let argv, !argv.isEmpty { return argv }
        return "pid \(pid)"
    }

    /// Convenience with no persisted-title cross-reference (existing callers).
    var displayLabel: String { label() }
}

/// Ends a session by id over a dialed connection — the session-scoped
/// equivalent of closing a pane (`+close`): the agent terminates the child and
/// frees the session container. Blocking (blocks on the RPC reply); call OFF the
/// main thread. Returns true iff the agent confirmed the session closed; false
/// on an older agent that doesn't advertise the `close_session` capability, no
/// connection, timeout, or an unknown id.
enum RemoteSessionKiller {
    static func close(handle: ghostty_remote_connection_t, sessionID: String, timeoutMs: UInt32 = 5000) -> Bool {
        sessionID.withCString { ghostty_remote_connection_close_session(handle, $0, timeoutMs) }
    }
}

/// Runs the `LIST_SESSIONS` RPC against a dialed connection handle and decodes
/// the JSON roster. Transport-agnostic — the same call works against the local
/// agent or a relay machine (the Zig ABI resolves the transport via the
/// connection handle). Blocking; call off the main thread.
enum RemoteSessionRoster {
    static func list(handle: ghostty_remote_connection_t, timeoutMs: UInt32 = 5000) -> [BrowsedSession]? {
        let cstr = ghostty_remote_connection_list_sessions(handle, timeoutMs)
        defer { ghostty_string_free(cstr) }
        // `.empty` (ptr == nil, len == 0) ⇒ RPC failure / no connection ⇒ nil.
        // A successful empty roster serializes as "[]" (len 2) ⇒ decodes to [].
        guard let ptr = cstr.ptr, cstr.len > 0 else { return nil }
        let data = Data(bytes: ptr, count: Int(cstr.len))
        return try? JSONDecoder().decode([BrowsedSession].self, from: data)
    }
}

/// One stored layout blob as reported by an agent's `GET_LAYOUTS` RPC (T18
/// cross-machine "Resume all"): the opaque `blob` (a `SessionLayoutManifest.Entry`
/// JSON) and the `key` it was stored under.
struct BrowsedLayout: Decodable {
    let key: String
    let blob: String

    /// Decode the opaque blob back into a manifest entry, or nil if malformed.
    var entry: SessionLayoutManifest.Entry? {
        SessionLayoutManifest.decodeBlob(Data(blob.utf8))
    }
}

/// Runs the `GET_LAYOUTS` RPC against a dialed connection and decodes the stored
/// layout blobs. Transport-agnostic (local agent OR relay machine), blocking —
/// call off the main thread. Used by "Resume all" to pull a machine's whole
/// window/tab/split topology and rebuild it locally.
enum RemoteLayoutRoster {
    static func get(handle: ghostty_remote_connection_t, timeoutMs: UInt32 = 5000) -> [BrowsedLayout]? {
        let cstr = ghostty_remote_connection_get_layouts(handle, timeoutMs)
        defer { ghostty_string_free(cstr) }
        guard let ptr = cstr.ptr, cstr.len > 0 else { return nil }
        let data = Data(bytes: ptr, count: Int(cstr.len))
        struct Reply: Decodable { let layouts: [BrowsedLayout] }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.layouts
    }
}

/// Lazily fetches a machine's live-session roster for the lifetime of one
/// Cmd-Shift-N machine-picker presentation, so the picker can expand a row into
/// a read-only list of that machine's active sessions (the browse half of
/// cross-machine resume, T16).
///
/// ## Threading & wedge-safety
/// Every dial + `LIST_SESSIONS` RPC runs on a background queue (the dial blocks
/// through the handshake), exactly like `MachineMetricsProbe`. A failed or slow
/// dial resolves to `.failed` on that row — it NEVER pops a modal alert and
/// never blocks the main thread or the chooser (cf. the remote-dial-modal-wedge
/// rule).
///
/// ## Where the connections come from
/// Nothing here owns a connection for longer than one call. The local agent's
/// warm shared connection is borrowed from `LocalAgentManager`; a remote
/// machine's is borrowed from `MachineConnectionPool` under a lease held only
/// while that machine is the selected row. A machine with no warm connection
/// (the pool is still dialing, or the dial failed) falls back to the original
/// dial-read-free probe, so the roster always has a path — it is just less
/// prompt.
@MainActor
final class SessionBrowserProbe: ObservableObject {
    enum State: Equatable {
        case loading
        case failed
        case loaded([BrowsedSession])
    }

    /// The stable key for the local-agent ("this Mac") row.
    static let localKey = "local"

    /// Per-row fetch state, keyed by `localKey` or a machine's `id.uuidString`.
    /// A row may be fetched (its roster cached here) WITHOUT being expanded —
    /// the local agent is primed on open so its count shows on the collapsed
    /// row. Remote rows are only fetched on first expand.
    @Published private(set) var states: [String: State] = [:]

    /// The set of currently-expanded row keys (independent of fetch state).
    @Published private(set) var expanded: Set<String> = []

    private var inflight: Set<String> = []
    private var stopped = false

    /// One live pushed-roster subscription, keyed like `states`.
    ///
    /// A push is strictly better than the 2s poll it replaces: the roster
    /// changes at the instant a session is created, exits, is closed, attaches
    /// or detaches, and the agent tells us then. A poll can only ever be as
    /// fresh as its last tick, and — as this feature learned the hard way — a
    /// poll whose completion cannot be delivered silently freezes with no
    /// symptom other than stale rows.
    private struct Push {
        let handle: ghostty_remote_connection_t
        let box: Unmanaged<PushBox>
    }

    /// Live subscriptions. A key is present iff its roster is currently served
    /// by pushes — which is exactly when the poll must stand down for it.
    private var pushes: [String: Push] = [:]

    /// Pool leases for REMOTE machines we are serving (or trying to serve) by
    /// push. Held only while that machine is the selected row: the chooser is
    /// transient, and one connection per machine the user happened to click
    /// through is not warm, it is a leak with good manners.
    ///
    /// The local agent has no lease — `LocalAgentManager` owns its warm
    /// connection for the app's lifetime and we merely borrow the handle.
    private var leases: [String: MachineConnectionPool.Lease] = [:]

    /// Bridges the C roster callback back to the probe. `probe` is weak so the
    /// box never keeps it alive.
    fileprivate final class PushBox {
        weak var probe: SessionBrowserProbe?
        let key: String
        init(probe: SessionBrowserProbe, key: String) {
            self.probe = probe
            self.key = key
        }
    }

    /// True when `key`'s roster is served by pushes. Callers do NOT branch on
    /// this to decide how to read the roster — pushed and polled rosters are
    /// indistinguishable downstream. It exists only so the poll can stand down.
    private func isPushed(_ key: String) -> Bool { pushes[key] != nil }

    /// Subscribe to the local agent's pushed roster. No-op if already
    /// subscribed. Falls back silently to polling when the agent is older or
    /// there is no warm shared connection — the caller does not branch.
    func subscribeLocalPush() {
        guard !stopped, !isPushed(Self.localKey) else { return }
        guard let handle = LocalAgentManager.shared.warmSharedHandle else { return }
        guard attachPush(key: Self.localKey, handle: handle) else { return }
        expanded.insert(Self.localKey)
    }

    /// Subscribe to a REMOTE machine's pushed roster, over the pool's warm
    /// connection for that machine.
    ///
    /// Identical in contract to `subscribeLocalPush`: it either upgrades the row
    /// to pushes or leaves it polling, and the caller cannot tell which. The
    /// three ways it lands on polling are an agent too old to advertise
    /// `sessions_push`, a machine that cannot be dialed at all, and a dial still
    /// in flight — the last of which resolves itself when the pool reports the
    /// connection.
    ///
    /// At most ONE remote machine is subscribed at a time, matching what the
    /// chooser already polled (only the selected remote) and keeping the
    /// connection count at one per selection rather than one per row visited.
    func subscribePush(machine: Machine) {
        guard !stopped else { return }
        let key = machine.id.uuidString
        releaseRemoteLeases(except: key)
        guard leases[key] == nil else { return }

        leases[key] = MachineConnectionPool.shared.acquire(machine: machine) { [weak self] handle in
            guard let self, !self.stopped else { return }
            if let handle {
                _ = self.attachPush(key: key, handle: handle)
            } else {
                // The connection died or never came up: drop the subscription
                // and let the poll take over again. This is the transition that
                // MUST NOT be missed — a stale `isPushed` would keep the poll
                // standing down against a socket that will never speak again.
                self.detachPush(key: key)
            }
        }
    }

    /// Try to subscribe `key`'s roster on `handle`. Returns false when the agent
    /// is older than `sessions_push` (or the connection isn't established), in
    /// which case the row simply keeps polling.
    @discardableResult
    private func attachPush(key: String, handle: ghostty_remote_connection_t) -> Bool {
        guard pushes[key] == nil else { return true }
        let box = PushBox(probe: self, key: key)
        let unmanaged = Unmanaged.passRetained(box)
        let ok = ghostty_remote_connection_sessions_subscribe(
            handle, sessionsRosterTrampoline, unmanaged.toOpaque())
        guard ok else {
            unmanaged.release()
            return false
        }
        pushes[key] = Push(handle: handle, box: unmanaged)
        return true
    }

    /// Tear one subscription down. Idempotent. Unsubscribes BEFORE releasing the
    /// box, so no callback can fire against freed userdata.
    private func detachPush(key: String) {
        guard let push = pushes.removeValue(forKey: key) else { return }
        ghostty_remote_connection_sessions_unsubscribe(push.handle)
        push.box.release()
    }

    /// Give every remote machine's warm connection back — the selection moved to
    /// something with no roster of its own. Without this a machine the user has
    /// navigated away from keeps a connection open for the rest of the chooser's
    /// life, which is precisely the leak the lease refcount exists to prevent.
    func standDownRemote() {
        releaseRemoteLeases(except: nil)
    }

    /// Release every remote lease except `key`'s, unsubscribing first so the
    /// pool never frees a connection we are still subscribed on.
    private func releaseRemoteLeases(except key: String?) {
        for k in Array(leases.keys) where k != key {
            detachPush(key: k)
            leases.removeValue(forKey: k)?.release()
        }
    }

    /// Apply a pushed roster. Main-actor; same decode + bookkeeping as a polled
    /// reply, so pushed and polled rosters are indistinguishable downstream.
    fileprivate func ingestPushedRoster(key: String, json: Data) {
        guard !stopped else { return }
        guard let sessions = try? JSONDecoder().decode([BrowsedSession].self, from: json) else { return }
        finish(key, sessions, keepOnFailure: true)
    }

    /// Sessions the user just KILLED, per roster key, hidden optimistically so
    /// the row vanishes immediately instead of lingering (and degrading to a
    /// "pid" label) during the close's undo window while the agent still lists
    /// it. An id is dropped once a refetch confirms the session is truly gone.
    private var killedByKey: [String: Set<String>] = [:]

    /// Optimistically hide a just-killed session so its row disappears at once.
    /// Called from the chooser's Kill action before the close/RPC lands.
    func markKilled(_ id: String, key: String) {
        killedByKey[key, default: []].insert(id)
        if case .loaded(let sessions) = states[key] {
            states[key] = .loaded(sessions.filter { $0.id != id })
        }
    }

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    /// The session count for a row once its roster has loaded, else nil (still
    /// loading, failed, or never fetched). Drives the collapsed-row count badge.
    func count(for key: String) -> Int? {
        if case .loaded(let sessions) = states[key] { return sessions.count }
        return nil
    }

    /// The loaded roster for `key`, or nil if it hasn't loaded. Lets the view
    /// apply its own visibility filter and derive a count from the SAME list it
    /// renders, instead of a raw total that disagrees with the rows.
    func loadedSessions(for key: String) -> [BrowsedSession]? {
        if case .loaded(let sessions) = states[key] { return sessions }
        return nil
    }

    // MARK: Local agent

    /// Fetch the local agent's roster WITHOUT expanding, so "this Mac" can show
    /// its session count on the collapsed row. Called once when the chooser opens
    /// (cheap: the warm shared connection, no dial). Safe to call repeatedly.
    func primeLocal() {
        fetchLocal()
    }

    /// Toggle the local-agent row's expansion. Fetches if not already loaded.
    func toggleLocal() {
        let key = Self.localKey
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
            if states[key] == nil { fetchLocal() }
        }
    }

    private func fetchLocal() {
        let key = Self.localKey
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        if states[key] == nil { states[key] = .loading }
        LocalAgentManager.shared.listLocalSessions { [weak self] sessions in
            self?.finish(key, sessions)
        }
    }

    // MARK: Remote machine (relay / TCP)

    /// Toggle a machine row's expansion. On first expand, resolve the relay
    /// token (if needed) and lazy-fetch its sessions over the machine's transport.
    func toggle(machine: Machine) {
        let key = machine.id.uuidString
        if expanded.contains(key) {
            expanded.remove(key)
            detachPush(key: key)
            leases.removeValue(forKey: key)?.release()
        } else {
            expanded.insert(key)
            subscribePush(machine: machine)
            if states[key] == nil { fetch(machine: machine) }
        }
    }

    private func fetch(machine: Machine, keepOnFailure: Bool = false) {
        let key = machine.id.uuidString
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        if states[key] == nil { states[key] = .loading }

        // Warm connection? Ride it. This is the whole saving for a relay
        // machine, whose every old poll tick paid a `RelayAccount.resolveToken()`
        // round-trip (possibly into the Keychain) plus a fresh dial, just to read
        // a roster. `borrow` keeps the connection alive across the blocking RPC
        // even if the last lease drops mid-call.
        let borrowed = MachineConnectionPool.shared.borrow(machine: machine) { [weak self] handle in
            let sessions = RemoteSessionRoster.list(handle: handle)
            onMainEvenWhenModal { self?.finish(key, sessions, keepOnFailure: keepOnFailure) }
        }
        if borrowed { return }

        if machine.isRelay {
            guard let base = machine.relayBase, let device = machine.deviceID else {
                finish(key, nil, keepOnFailure: keepOnFailure)
                return
            }
            // Resolve the account token (async, may touch the Keychain), then
            // dial the relay on a background queue.
            Task { @MainActor [weak self] in
                let token = await RelayAccount.resolveToken()
                guard let self, !self.stopped, self.inflight.contains(key) else {
                    self?.inflight.remove(key)
                    return
                }
                guard let token else { self.finish(key, nil, keepOnFailure: keepOnFailure); return }
                self.dialAndList(key: key, keepOnFailure: keepOnFailure) {
                    AppDelegate.dialRelay(base: base, device: device, token: token)
                }
            }
        } else {
            let host = machine.host
            let port = machine.port
            dialAndList(key: key, keepOnFailure: keepOnFailure) {
                host.withCString { ghostty_remote_connection_new_tcp($0, port) }
            }
        }
    }

    /// Dial (via `dial`) on a background queue, run `LIST_SESSIONS`, free the
    /// probe connection, and publish the result on the main actor.
    ///
    /// The fallback path, used only when the machine has no warm pooled
    /// connection yet (still dialing, or undialable).
    private func dialAndList(
        key: String,
        keepOnFailure: Bool = false,
        dial: @escaping () -> ghostty_remote_connection_t?
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = dial()
            let sessions: [BrowsedSession]? = handle.flatMap { RemoteSessionRoster.list(handle: $0) }
            if let handle { ghostty_remote_connection_free(handle) }
            // Must land even while an AppKit modal is up -- see
            // `onMainEvenWhenModal`. The chooser panel itself is modeless now,
            // but it still runs alerts of its own (Kill's confirmation, Rename,
            // Remove), and with a plain main-queue hop this would not run until
            // one of those closed, leaving `inflight` set forever and freezing
            // the roster.
            onMainEvenWhenModal { self?.finish(key, sessions, keepOnFailure: keepOnFailure) }
        }
    }

    // MARK: Master-detail selection (fetch-on-select)

    /// Ensure the local-agent roster is loaded and marked expanded, so the
    /// detail pane can render it the instant "Local" is selected. Fetches only
    /// if not already loaded (the local roster is primed on open).
    func fetchIfNeededLocal() {
        expanded.insert(Self.localKey)
        // Selection moved off every remote row: give their warm connections back
        // so none outlives the row the user is actually looking at.
        releaseRemoteLeases(except: nil)
        if states[Self.localKey] == nil { fetchLocal() }
    }

    /// Ensure a machine's roster is loaded and marked expanded, so selecting it
    /// in the master list drives the detail pane. Fetches lazily on first select,
    /// and asks for the pushed roster (silently staying on the poll if the
    /// machine's agent can't serve one).
    func fetchIfNeeded(machine: Machine) {
        let key = machine.id.uuidString
        expanded.insert(key)
        subscribePush(machine: machine)
        if states[key] == nil { fetch(machine: machine) }
    }

    // MARK: Live refresh (poll while the chooser is open)

    /// Re-fetch the local roster IN PLACE while the chooser is open, so newly
    /// spawned panes appear and closed ones drop without reopening. No loading
    /// flicker (the current roster stays visible) and a transient failure keeps
    /// the last good roster rather than flipping the list to an error.
    func refreshLocalInPlace() {
        let key = Self.localKey
        // Pushed rosters are authoritative and arrive the moment anything
        // changes; polling on top of them would only add redundant RPCs.
        guard !isPushed(key) else { return }
        guard expanded.contains(key), !inflight.contains(key) else { return }
        inflight.insert(key)
        LocalAgentManager.shared.listLocalSessions { [weak self] sessions in
            self?.finish(key, sessions, keepOnFailure: true)
        }
    }

    /// Re-fetch a machine's roster IN PLACE (same no-flicker / keep-last-good
    /// contract as `refreshLocalInPlace`). Only the currently-selected remote is
    /// polled by the chooser, so this touches at most one machine per tick.
    func refreshInPlace(machine: Machine) {
        let key = machine.id.uuidString
        // Stand down for a pushed machine, exactly as the local row does: the
        // agent tells us the instant anything changes, so a poll on top could
        // only ever be redundant or stale.
        guard !isPushed(key) else { return }
        guard expanded.contains(key), !inflight.contains(key) else { return }
        // This tick doubles as the pool's recovery clock: a machine whose warm
        // connection died gets re-dialed here (after the pool's own cooldown),
        // and its push comes back with it. No extra timer.
        if leases[key] != nil {
            MachineConnectionPool.shared.ensureConnected(machine: machine)
        }
        fetch(machine: machine, keepOnFailure: true)
    }

    // MARK: Kill (end a session)

    /// Kill (end) a browsed session by id, then refetch its machine's roster so
    /// the detail list reflects the removal live. `machine == nil` ⇒ the local
    /// agent. The close RPC blocks, so it runs off the main thread (the same
    /// wedge-safe discipline as the roster fetch — it NEVER blocks the chooser).
    func kill(session: BrowsedSession, machine: Machine?) {
        if let machine {
            killRemote(sessionID: session.id, machine: machine)
        } else {
            killLocal(sessionID: session.id)
        }
    }

    private func killLocal(sessionID: String) {
        LocalAgentManager.shared.closeLocalSession(sessionID) { [weak self] _ in
            guard let self, !self.stopped else { return }
            // Force a re-fetch so the roster reflects the kill.
            self.states[Self.localKey] = nil
            self.fetchLocal()
        }
    }

    private func killRemote(sessionID: String, machine: Machine) {
        let key = machine.id.uuidString

        // Warm connection? Kill over it — no second dial, no second token
        // round-trip. A pushed machine needs no refetch afterwards either: ending
        // a session IS a roster change, so the agent tells us.
        let borrowed = MachineConnectionPool.shared.borrow(machine: machine) { [weak self] handle in
            _ = RemoteSessionKiller.close(handle: handle, sessionID: sessionID)
            onMainEvenWhenModal {
                guard let self, !self.stopped, !self.isPushed(key) else { return }
                self.states[key] = nil
                self.fetch(machine: machine)
            }
        }
        if borrowed { return }

        if machine.isRelay {
            guard let base = machine.relayBase, let device = machine.deviceID else { return }
            Task { @MainActor [weak self] in
                let token = await RelayAccount.resolveToken()
                guard let self, !self.stopped, let token else { return }
                self.dialAndClose(key: key, sessionID: sessionID, machine: machine) {
                    AppDelegate.dialRelay(base: base, device: device, token: token)
                }
            }
        } else {
            let host = machine.host
            let port = machine.port
            dialAndClose(key: key, sessionID: sessionID, machine: machine) {
                host.withCString { ghostty_remote_connection_new_tcp($0, port) }
            }
        }
    }

    /// Dial a short-lived probe connection, close `sessionID`, free the handle,
    /// then re-fetch the machine's roster on the main actor so the list updates.
    private func dialAndClose(
        key: String,
        sessionID: String,
        machine: Machine,
        dial: @escaping () -> ghostty_remote_connection_t?
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = dial()
            if let handle {
                _ = RemoteSessionKiller.close(handle: handle, sessionID: sessionID)
                ghostty_remote_connection_free(handle)
            }
            onMainEvenWhenModal {
                guard let self, !self.stopped else { return }
                self.states[key] = nil
                self.fetch(machine: machine)
            }
        }
    }

    // MARK: Completion / teardown

    private func finish(_ key: String, _ sessions: [BrowsedSession]?, keepOnFailure: Bool = false) {
        guard !stopped else { return }
        inflight.remove(key)
        // On a live-refresh poll, a transient failure keeps the last good roster
        // visible rather than flipping the detail list to an error card.
        if sessions == nil, keepOnFailure, case .loaded = states[key] { return }
        guard let sessions else { states[key] = .failed; return }
        // Keep just-killed sessions hidden while the agent still lists them
        // (undo window); once one is truly gone from the roster, stop hiding it.
        // Drop rows for panes the user just closed. Their sessions are still
        // alive for the undo window, so the agent legitimately reports them --
        // but the user closed those windows and must not be offered a Resume.
        // Reconcile first so the hidden set can't grow: anything the agent no
        // longer reports has finished closing and needs no hiding.
        ClosingSessions.shared.reconcile(against: Set(sessions.map { $0.id }))
        let visible = ClosingSessions.shared.visible(sessions)

        if var kills = killedByKey[key], !kills.isEmpty {
            kills = kills.intersection(Set(visible.map { $0.id }))
            killedByKey[key] = kills.isEmpty ? nil : kills
            states[key] = .loaded(kills.isEmpty ? visible : visible.filter { !kills.contains($0.id) })
        } else {
            states[key] = .loaded(visible)
        }
    }

    /// Tear down: drop all state. Called from the chooser's `finish` closure so
    /// no fetch — and no warm connection — outlives the picker. In-flight
    /// background reads land in `finish` which no-ops once `stopped` is set.
    func stop() {
        // Unsubscribe every push before giving the leases back, so the pool
        // never frees a connection we still have a callback registered on.
        for key in Array(pushes.keys) { detachPush(key: key) }
        releaseRemoteLeases(except: nil)
        stopped = true
        states.removeAll()
        expanded.removeAll()
        inflight.removeAll()
        killedByKey.removeAll()
    }
}


/// Global, capture-free C callback for the pushed session roster. Fires on the
/// connection's control-reader thread against a borrowed buffer, so it copies
/// the JSON out BEFORE hopping to main.
private func sessionsRosterTrampoline(
    _ json: UnsafePointer<CChar>?,
    _ ud: UnsafeMutableRawPointer?
) {
    guard let json, let ud else { return }
    let data = Data(String(cString: json).utf8)
    let box = Unmanaged<SessionBrowserProbe.PushBox>.fromOpaque(ud).takeUnretainedValue()
    let key = box.key
    onMainEvenWhenModal {
        box.probe?.ingestPushedRoster(key: key, json: data)
    }
}
