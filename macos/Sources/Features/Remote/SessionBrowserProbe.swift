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

    enum CodingKeys: String, CodingKey {
        case id, alive, attached, activity, pid, cwd, argv, title, pinned
        case exitCode = "exit_code"
        case createdAt = "created_at"
        case lastActivity = "last_activity"
    }

    /// A human label for the row: the title if the agent has one, else the last
    /// path component of the cwd, else the command, else the short id.
    var displayLabel: String {
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        if let argv, !argv.isEmpty { return argv }
        return String(id.prefix(8))
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

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    /// The session count for a row once its roster has loaded, else nil (still
    /// loading, failed, or never fetched). Drives the collapsed-row count badge.
    func count(for key: String) -> Int? {
        if case .loaded(let sessions) = states[key] { return sessions.count }
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

    private func fetch(machine: Machine) {
        let key = machine.id.uuidString
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        if states[key] == nil { states[key] = .loading }

        if machine.isRelay {
            guard let base = machine.relayBase, let device = machine.deviceID else {
                finish(key, nil)
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
                guard let token else { self.finish(key, nil); return }
                self.dialAndList(key: key) {
                    AppDelegate.dialRelay(base: base, device: device, token: token)
                }
            }
        } else {
            let host = machine.host
            let port = machine.port
            dialAndList(key: key) {
                host.withCString { ghostty_remote_connection_new_tcp($0, port) }
            }
        }
    }

    /// Dial (via `dial`) on a background queue, run `LIST_SESSIONS`, free the
    /// probe connection, and publish the result on the main actor.
    private func dialAndList(
        key: String,
        dial: @escaping () -> ghostty_remote_connection_t?
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let handle = dial()
            let sessions: [BrowsedSession]? = handle.flatMap { RemoteSessionRoster.list(handle: $0) }
            if let handle { ghostty_remote_connection_free(handle) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(key, sessions) }
            }
        }
    }

    // MARK: Completion / teardown

    private func finish(_ key: String, _ sessions: [BrowsedSession]?) {
        guard !stopped else { return }
        inflight.remove(key)
        // Cache the roster regardless of expansion (the local agent is primed
        // while collapsed); a nil result becomes .failed.
        states[key] = sessions.map { .loaded($0) } ?? .failed
    }

    /// Tear down: drop all state. Called from the chooser's `finish` closure so
    /// no fetch outlives the picker. In-flight background reads land in `finish`
    /// which no-ops once `stopped` is set.
    func stop() {
        stopped = true
        states.removeAll()
        expanded.removeAll()
        inflight.removeAll()
    }
}
