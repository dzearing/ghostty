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
/// rule). Per-machine probe connections are short-lived: dialed, read, freed.
/// The local agent's warm shared connection is reused (and NOT freed here — it
/// is owned by `LocalAgentManager`).
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

    /// Live push subscription for the LOCAL agent's roster, when the agent
    /// supports it. Set once `subscribeLocalPush` succeeds; nil means we are
    /// polling instead (an older agent, or no warm connection).
    ///
    /// A push is strictly better than the 2s poll it replaces: the roster
    /// changes at the instant a session is created, exits, is closed, attaches
    /// or detaches, and the agent tells us then. A poll can only ever be as
    /// fresh as its last tick, and — as this feature learned the hard way — a
    /// poll whose completion cannot be delivered silently freezes with no
    /// symptom other than stale rows.
    private var pushBox: Unmanaged<PushBox>?
    private var pushHandle: ghostty_remote_connection_t?

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

    /// True once the local roster is served by pushes, so the poll can stand
    /// down for it.
    private(set) var localIsPushed = false

    /// Subscribe to the local agent's pushed roster. No-op if already
    /// subscribed. Falls back silently to polling when the agent is older or
    /// there is no warm shared connection — the caller does not branch.
    func subscribeLocalPush() {
        guard !stopped, pushBox == nil else { return }
        guard let handle = LocalAgentManager.shared.warmSharedHandle else { return }
        let box = PushBox(probe: self, key: Self.localKey)
        let unmanaged = Unmanaged.passRetained(box)
        let ok = ghostty_remote_connection_sessions_subscribe(
            handle, sessionsRosterTrampoline, unmanaged.toOpaque())
        guard ok else {
            unmanaged.release()
            return
        }
        pushBox = unmanaged
        pushHandle = handle
        localIsPushed = true
        expanded.insert(Self.localKey)
    }

    /// Tear the push down. Idempotent.
    private func unsubscribePush() {
        if let pushHandle {
            ghostty_remote_connection_sessions_unsubscribe(pushHandle)
        }
        pushHandle = nil
        pushBox?.release()
        pushBox = nil
        localIsPushed = false
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
        } else {
            expanded.insert(key)
            if states[key] == nil { fetch(machine: machine) }
        }
    }

    private func fetch(machine: Machine, keepOnFailure: Bool = false) {
        let key = machine.id.uuidString
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        if states[key] == nil { states[key] = .loading }

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
    private func dialAndList(
        key: String,
        keepOnFailure: Bool = false,
        dial: @escaping () -> ghostty_remote_connection_t?
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = dial()
            let sessions: [BrowsedSession]? = handle.flatMap { RemoteSessionRoster.list(handle: $0) }
            if let handle { ghostty_remote_connection_free(handle) }
            // Must land while the chooser's modal panel is up -- see
            // `onMainEvenWhenModal`. With a plain main-queue hop this never
            // runs until the dialog closes, leaving `inflight` set forever and
            // freezing the roster.
            onMainEvenWhenModal { self?.finish(key, sessions, keepOnFailure: keepOnFailure) }
        }
    }

    // MARK: Master-detail selection (fetch-on-select)

    /// Ensure the local-agent roster is loaded and marked expanded, so the
    /// detail pane can render it the instant "Local" is selected. Fetches only
    /// if not already loaded (the local roster is primed on open).
    func fetchIfNeededLocal() {
        expanded.insert(Self.localKey)
        if states[Self.localKey] == nil { fetchLocal() }
    }

    /// Ensure a machine's roster is loaded and marked expanded, so selecting it
    /// in the master list drives the detail pane. Fetches lazily on first select.
    func fetchIfNeeded(machine: Machine) {
        let key = machine.id.uuidString
        expanded.insert(key)
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
        guard !localIsPushed else { return }
        guard expanded.contains(key), !inflight.contains(key) else { return }
        inflight.insert(key)
        LocalAgentManager.shared.listLocalSessions { [weak self] sessions in
            self?.finish(key, sessions, keepOnFailure: true)
        }
    }

    /// Re-fetch a machine's roster IN PLACE (same no-flicker / keep-last-good
    /// contract as `refreshLocalInPlace`). Only the currently-selected remote is
    /// polled by the chooser, so this dials at most one machine per tick.
    func refreshInPlace(machine: Machine) {
        let key = machine.id.uuidString
        guard expanded.contains(key), !inflight.contains(key) else { return }
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
    /// no fetch outlives the picker. In-flight background reads land in `finish`
    /// which no-ops once `stopped` is set.
    func stop() {
        unsubscribePush()
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
