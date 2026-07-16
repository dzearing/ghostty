import Foundation
import GhosttyKit
import os

/// Finds or spawns the local `ghoztty-agent` and hands back dialed connection
/// handles to it — the local end of session persistence: panes backed by this
/// agent survive the app process, so the app can be killed/upgraded and
/// re-attach to the same PTYs.
///
/// The local transport is a 0600 AF_UNIX socket with a same-uid peercred gate
/// (design §5.2 hardening): unlike a 127.0.0.1 TCP port — reachable by any local
/// uid — only this user can reach the shell.
///
/// Discovery order:
///
///  1. **Find**: read the agent's info file (written atomically by
///     `--port-file` after its socket binds), liveness-check the recorded pid,
///     and dial the recorded AF_UNIX `socket` path (a legacy TCP `port` record
///     still dials `127.0.0.1:<port>`). The dial blocks through the HELLO
///     handshake before returning, so a non-nil handle IS the health check.
///  2. **Spawn**: launch the agent bundled next to the app executable
///     (`Contents/MacOS/ghoztty-agent`) in its own session (`setsid`) so it
///     outlives the app with `--listen-unix=<dir>/agent.sock`, then poll the
///     info file until a dial succeeds.
///
/// All agent state lives in a per-lineage directory keyed by bundle id
/// (`~/.config/ghoztty/local-agent[-debug]/`) so the debug app never shares an
/// agent — or its sessions — with the release app. The lock/heartbeat paths
/// are forced there via the agent's `GHOSTTY_AGENT_LOCK`/`GHOSTTY_AGENT_HEARTBEAT`
/// overrides; its single-instance guard (loser exits 183) makes concurrent
/// spawns safe.
final class LocalAgentManager {
    static let shared = LocalAgentManager()

    private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: String(describing: LocalAgentManager.self)
    )

    /// Serializes connect() so racing callers can't double-spawn from within
    /// this process (cross-process races are the agent guard's job).
    private let lock = NSLock()

    /// Everything path-shaped, resolved purely from (bundleID, home) so tests
    /// can assert the layout without touching the filesystem or the real bundle.
    struct Paths: Equatable {
        let directory: URL
        /// The real user home (LaunchAgents plists live under the true `~`, never
        /// a sandbox container) — kept so `launchAgentPlistURL` is derivable.
        let home: URL
        /// The per-user LaunchAgent label/job name (design §5.2 "Lifecycle").
        /// Debug and release lineages get distinct labels so their KeepAlive jobs
        /// never collide.
        let launchAgentLabel: String

        /// The agent's info file (still passed via `--port-file`): now carries
        /// the UDS socket path + pid rather than a TCP port.
        var portFile: URL { directory.appendingPathComponent("port.json") }
        /// The AF_UNIX socket the agent binds and clients dial. 0600, same-uid
        /// gated — the secure local transport (design §5.2).
        var socketFile: URL { directory.appendingPathComponent("agent.sock") }
        /// The reboot-floor session-metadata store (passed via `--sessions-file`):
        /// the agent keeps this current with its live-session roster (id/argv/cwd/
        /// title/pinned) so sessions can be relaunched after an agent/machine
        /// restart (design §5.4, T12).
        var sessionsFile: URL { directory.appendingPathComponent("sessions.json") }
        var lockFile: URL { directory.appendingPathComponent("agent.lock") }
        var heartbeatFile: URL { directory.appendingPathComponent("agent.heartbeat") }
        var logFile: URL { directory.appendingPathComponent("agent.log") }

        /// The LaunchAgent plist launchd loads for this lineage
        /// (`~/Library/LaunchAgents/<label>.plist`). Always under the true home:
        /// launchd's `gui/<uid>` domain only reads plists from there.
        var launchAgentPlistURL: URL {
            home.appendingPathComponent(
                "Library/LaunchAgents/\(launchAgentLabel).plist")
        }

        init(bundleID: String?, home: URL) {
            // The debug lineage (com.dzearing.ghoztty.debug) gets its own
            // directory; anything else — including a nil bundle id when
            // running bare — is the release lineage.
            let isDebug = bundleID?.hasSuffix(".debug") == true
            let name = isDebug ? "local-agent-debug" : "local-agent"
            self.home = home
            self.directory = home
                .appendingPathComponent(".config/ghoztty/\(name)", isDirectory: true)
            self.launchAgentLabel = isDebug
                ? "com.dzearing.ghoztty.debug.agent"
                : "com.dzearing.ghoztty.agent"
        }

        static var current: Paths {
            .init(
                bundleID: Bundle.main.bundleIdentifier,
                home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// The agent's `--port-file` body. The UDS agent writes
    /// `{"port":0,"pid":P,"socket":"<path>","startedAt":MS}`; a legacy TCP agent
    /// wrote `{"port":N,"pid":P,"startedAt":MS}` (no `socket`). Both decode here
    /// — `socket` present ⇒ dial UDS, else dial the TCP `port`. `startedAt` is
    /// ignored (the pid liveness check supersedes it).
    struct PortFile: Codable, Equatable {
        var port: UInt16?
        let pid: pid_t
        var socket: String?
    }

    /// A successfully dialed local-agent connection. The caller owns the
    /// handle (free with `ghostty_remote_connection_free`, or hand it to a
    /// `RemoteConnection` owner). `port` is 0 for the UDS transport (no port).
    struct Connection {
        let handle: ghostty_remote_connection_t
        let port: UInt16
        let pid: pid_t
    }

    /// Find-or-spawn the local agent and dial it. Blocking (dial + spawn
    /// polling, worst case ~5s) — call off the main thread.
    func connect() -> Connection? {
        lock.lock()
        defer { lock.unlock() }
        let paths = Paths.current
        if let conn = Self.dialExisting(paths: paths) { return conn }
        // Prefer launchd ownership: a launchd-managed agent is auto-restarted
        // after a kill/crash/reboot (RunAtLoad + KeepAlive) — the reboot-floor
        // guarantee (design §5.2, AC4). launchd is the SOLE spawner on this
        // path (no posix_spawn race → no single-instance-guard respawn loop).
        if Self.ensureLaunchAgentLoaded(paths: paths) {
            if let conn = Self.pollDial(paths: paths, seconds: 5.0) { return conn }
            Self.logger.error("launchd agent did not become dialable within 5s; see \(paths.logFile.path, privacy: .public)")
            return nil
        }
        // Fallback (launchctl unavailable — e.g. no Aqua/gui session): spawn the
        // agent detached, as before. No KeepAlive on this path, so a killed
        // agent won't auto-restart; find-or-spawn still recovers it on demand.
        Self.logger.warning("launchd unavailable; falling back to detached agent spawn")
        return Self.spawnAndDial(paths: paths)
    }

    // MARK: - Shared connection (session persistence)

    /// Cached shared connection for session-persistent surfaces. Every
    /// persistent window/tab/split rides this ONE connection, exactly like the
    /// tabs/splits of a remote window share theirs. This manager's reference
    /// keeps it alive for the app's lifetime; windows retain it additionally
    /// via `connectionKeepAlive`. Main-thread only.
    private var sharedOwner: RemoteConnection?

    /// The pid of the agent behind `sharedOwner`, for cheap liveness checks.
    private var sharedAgentPid: pid_t = 0

    /// Link-state observer token for the CURRENT `sharedOwner`, so a shared
    /// connection whose transport drops (the local agent crashed, T12e) can be
    /// detected and recovered in place — without waiting for the next app
    /// relaunch. Removed/rebound whenever `sharedOwner` changes. Main only.
    private var sharedLinkObserver: NSObjectProtocol?

    /// Called (main thread) the first time the shared connection's transport
    /// drops to a non-self-healing state (`reconnecting`/`reattaching`/`dead`).
    /// The local UDS transport never re-dials itself (the Zig FSM only computes
    /// the backoff — see connection.zig), so a drop is permanent until we act:
    /// `AppDelegate` wires this to `recoverSessionLayoutInPlace()`. Set once at
    /// launch; fired at most once per shared connection (the recovery re-dials
    /// and installs a fresh `sharedOwner` with a fresh observer). Main only.
    var onSharedConnectionDrop: (@MainActor () -> Void)?

    /// The Machine value describing the local agent endpoint. A loopback
    /// host/name makes `Machine.isLocalMachine` true, so remote-only UI (the
    /// titlebar machine pill) stays hidden for persistent local windows.
    static func localMachine(port: UInt16 = 0) -> Machine {
        // The loopback `name` makes `isLocalMachine` true even with port 0 (the
        // UDS transport has no port), so the machine pill stays hidden.
        Machine(name: "127.0.0.1", host: "127.0.0.1", port: port)
    }

    /// The shared local-agent connection, creating it (find-or-spawn + dial)
    /// if there is no healthy cached one. Blocking on a cache miss:
    /// milliseconds against a live agent, ~300ms when the agent must be
    /// spawned (call `warmUp()` at launch to hide this), ~5s worst case
    /// against a wedged agent. Main-thread only.
    func sharedRemoteConnection() -> RemoteConnection? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = sharedOwner,
           existing.linkState != .dead,
           sharedAgentPid > 0,
           kill(sharedAgentPid, 0) == 0 || errno == EPERM {
            return existing
        }
        // Dead link or dead agent: drop our reference (windows still using the
        // old connection keep it alive; their reconnect ladder handles it) and
        // dial fresh.
        sharedOwner = nil
        sharedAgentPid = 0
        guard let conn = connect() else { return nil }
        return cacheShared(conn)
    }

    /// Find-or-spawn + dial in the background so the first persistent window
    /// finds a warm cached connection instead of blocking the main thread on
    /// the agent spawn. Safe to call repeatedly (e.g. on config reload).
    func warmUp() {
        sharedConnectionAsync { _ in }
    }

    /// Resolve the shared connection WITHOUT blocking the caller: find-or-
    /// spawn + dial on a background queue, cache on main, deliver on main.
    /// Used by the launch warm-up and the T06 layout restore (which must not
    /// beachball launch on an agent spawn). Completion receives nil when no
    /// agent could be reached; it is delivered on the main actor.
    func sharedConnectionAsync(_ completion: @escaping @MainActor (RemoteConnection?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let conn = connect()
            DispatchQueue.main.async {
                // A racing main-thread caller may have cached one already:
                // keep the established one, discard ours.
                if let existing = self.sharedOwner, existing.linkState != .dead,
                   self.sharedAgentPid > 0,
                   kill(self.sharedAgentPid, 0) == 0 || errno == EPERM {
                    if let conn { ghostty_remote_connection_free(conn.handle) }
                    completion(existing)
                    return
                }
                guard let conn else {
                    completion(nil)
                    return
                }
                completion(self.cacheShared(conn))
            }
        }
    }

    /// List the local agent's sessions for the Cmd-Shift-N session browser (T16)
    /// WITHOUT spawning an agent. Reuses the warm shared connection when healthy
    /// (owned elsewhere — not freed here); otherwise dials the EXISTING agent
    /// only (never spawns) and frees that probe connection after reading. The
    /// `LIST_SESSIONS` RPC runs on a background queue; `completion` is delivered
    /// on the main actor — nil ⇒ no local agent reachable or the RPC failed.
    func listLocalSessions(_ completion: @escaping @MainActor ([BrowsedSession]?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Prefer the warm shared connection (do NOT free it — LocalAgentManager
        // owns it for the app's lifetime). The muxed RPC is safe to issue from a
        // background thread while the main thread also uses the connection.
        if let existing = sharedOwner,
           existing.linkState != .dead,
           sharedAgentPid > 0,
           kill(sharedAgentPid, 0) == 0 || errno == EPERM {
            let handle = existing.handle
            DispatchQueue.global(qos: .userInitiated).async {
                let sessions = RemoteSessionRoster.list(handle: handle)
                DispatchQueue.main.async { completion(sessions) }
            }
            return
        }

        // No warm shared connection: dial the EXISTING agent only (no spawn), so
        // browsing never starts an agent. Free the probe connection afterward.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let conn = Self.dialExisting(paths: .current) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let sessions = RemoteSessionRoster.list(handle: conn.handle)
            ghostty_remote_connection_free(conn.handle)
            DispatchQueue.main.async { completion(sessions) }
        }
    }

    /// The warm shared connection when it is healthy, else nil. Non-spawning,
    /// non-dialing — the exact liveness gate `listLocalSessions` uses. Main-thread.
    private func warmSharedOwner() -> RemoteConnection? {
        guard let existing = sharedOwner,
              existing.linkState != .dead,
              sharedAgentPid > 0,
              kill(sharedAgentPid, 0) == 0 || errno == EPERM
        else { return nil }
        return existing
    }

    /// Mirror one window's layout blob to the local agent (T18 cross-machine
    /// "Resume all"). Best-effort and non-spawning: pushes over the warm shared
    /// connection if one exists (it always does for agent-backed windows), else
    /// silently skips. The `SET_LAYOUT` RPC blocks through its ack, so it runs on
    /// a background queue. Safe to call from the manifest's change callback.
    func pushLayout(key: String, blob: Data, sessionIDs: [String]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = warmSharedOwner(),
              let blobStr = String(data: blob, encoding: .utf8) else { return }
        let handle = owner.handle
        let idsJoined = sessionIDs.joined(separator: "\n")
        DispatchQueue.global(qos: .utility).async {
            let ok = key.withCString { k in
                blobStr.withCString { b in
                    idsJoined.withCString { s in
                        ghostty_remote_connection_set_layout(handle, k, b, s, false, 5000)
                    }
                }
            }
            if ok == 0 {
                Self.logger.debug("layout push for \(key, privacy: .public) failed (agent unreachable or rejected)")
            }
        }
    }

    /// Remove a window's layout blob from the local agent (a clean window close,
    /// T18). Best-effort, non-spawning, off-main — the mirror of `pushLayout`.
    func deleteLayout(key: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner = warmSharedOwner() else { return }
        let handle = owner.handle
        DispatchQueue.global(qos: .utility).async {
            _ = key.withCString { k in
                "".withCString { b in
                    "".withCString { s in
                        ghostty_remote_connection_set_layout(handle, k, b, s, true, 5000)
                    }
                }
            }
        }
    }

    /// Wrap a dialed connection in a strong `RemoteConnection` owner and cache
    /// it as the shared one. Main-thread only.
    private func cacheShared(_ conn: Connection) -> RemoteConnection {
        let owner = RemoteConnection(
            handle: conn.handle,
            machine: Self.localMachine(port: conn.port))
        sharedOwner = owner
        sharedAgentPid = conn.pid
        bindSharedLinkObserver(owner)
        Self.logger.info("shared local-agent connection ready (agent pid \(conn.pid), port \(conn.port))")
        return owner
    }

    /// (Re)bind the link-state observer to `owner` so a transport drop on the
    /// shared connection triggers in-place recovery (T12e). The prior
    /// observer, if any, is removed first. Main-thread only.
    private func bindSharedLinkObserver(_ owner: RemoteConnection) {
        if let existing = sharedLinkObserver {
            NotificationCenter.default.removeObserver(existing)
            sharedLinkObserver = nil
        }
        sharedLinkObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyRemoteConnectionLinkDidChange,
            object: owner,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let conn = note.object as? RemoteConnection,
                  conn === self.sharedOwner else { return }
            switch conn.linkState {
            case .reconnecting, .reattaching, .dead:
                // The local UDS link does not self-heal (the Zig side computes
                // backoff but never re-dials), so this is terminal for THIS
                // connection: hand off to recovery ONCE. We stop observing this
                // owner now — recovery re-dials and installs a fresh owner with
                // its own observer — so a follow-up reconnecting→dead edge can't
                // re-fire the same handoff.
                if let observer = self.sharedLinkObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.sharedLinkObserver = nil
                }
                Self.logger.warning(
                    "shared local-agent link dropped (\(String(describing: conn.linkState))); triggering in-place recovery")
                self.onSharedConnectionDrop?()
            case .connected, .degraded:
                break
            }
        }
    }

    /// Drop the cached shared connection and its observer so the NEXT resolve
    /// re-dials from scratch. Windows still riding the old connection keep it
    /// alive via `connectionKeepAlive` until their surfaces are replaced. Used
    /// by in-place recovery (T12e) before re-dialing the restarted agent.
    /// Main-thread only.
    func invalidateShared() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = sharedLinkObserver {
            NotificationCenter.default.removeObserver(existing)
            sharedLinkObserver = nil
        }
        sharedOwner = nil
        sharedAgentPid = 0
    }

    /// Force a FRESH shared connection for in-place recovery (T12e): invalidate
    /// the dead one, then re-dial the (launchd-restarted) agent off the main
    /// thread with a short retry ladder — a just-crashed agent is normally back
    /// within a second or two, but launchd's KeepAlive respawn can lag behind a
    /// throttle window, so a single `connect()` (≤5s) is retried. Delivers the
    /// new shared `RemoteConnection` (or nil if the agent never came back) on
    /// the main actor. Main-thread entry only.
    func reconnectSharedForRecovery(
        attempts: Int = 4,
        _ completion: @escaping @MainActor (RemoteConnection?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        invalidateShared()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var conn: Connection?
            for attempt in 1...max(1, attempts) {
                conn = connect()
                if conn != nil { break }
                Self.logger.warning(
                    "recovery re-dial attempt \(attempt)/\(attempts) found no agent; retrying")
                Thread.sleep(forTimeInterval: 1.5)
            }
            let dialed = conn
            DispatchQueue.main.async {
                // A racing main-thread caller (e.g. a new window) may have
                // cached a healthy shared owner already: keep it, discard ours.
                if let existing = self.sharedOwner, existing.linkState != .dead,
                   self.sharedAgentPid > 0,
                   kill(self.sharedAgentPid, 0) == 0 || errno == EPERM {
                    if let dialed { ghostty_remote_connection_free(dialed.handle) }
                    completion(existing)
                    return
                }
                guard let dialed else {
                    completion(nil)
                    return
                }
                completion(self.cacheShared(dialed))
            }
        }
    }

    /// Strict parse of the info file body. Static + pure for tests. Accepts a
    /// UDS record (non-empty `socket`) OR a legacy TCP record (`port > 0`);
    /// either way `pid` must be positive. A record with neither a socket nor a
    /// usable port is rejected.
    static func parsePortFile(_ data: Data) -> PortFile? {
        guard let parsed = try? JSONDecoder().decode(PortFile.self, from: data),
              parsed.pid > 0
        else { return nil }
        if let socket = parsed.socket, !socket.isEmpty { return parsed }
        if let port = parsed.port, port > 0 { return parsed }
        return nil
    }

    /// The bundled agent binary: a sibling of the app executable inside
    /// Contents/MacOS. `GHOSTTY_LOCAL_AGENT_BIN` overrides for tests/dev
    /// (e.g. driving a zig-out binary without rebuilding the bundle).
    static func agentBinaryURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["GHOSTTY_LOCAL_AGENT_BIN"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let exe = Bundle.main.executableURL else { return nil }
        return exe.deletingLastPathComponent().appendingPathComponent("ghoztty-agent")
    }

    // MARK: - Find

    /// Dial the agent recorded in the info file, if it looks alive. The file is
    /// never cleaned up on agent exit, so stale entries are expected: dead pid
    /// or failed HELLO both mean "no healthy agent" (nil). Prefers the UDS
    /// socket (the secure default) and falls back to a legacy TCP `port`.
    private static func dialExisting(paths: Paths) -> Connection? {
        guard let data = try? Data(contentsOf: paths.portFile),
              let record = parsePortFile(data)
        else { return nil }

        // Liveness: signal 0 probes existence without touching the process.
        // EPERM still means "exists" (not expected same-uid, but harmless).
        guard kill(record.pid, 0) == 0 || errno == EPERM else { return nil }

        // UDS record: dial the 0600 same-uid-gated socket. The dial BLOCKS
        // through HELLO, so a non-nil handle is the health check.
        if let socket = record.socket, !socket.isEmpty {
            guard let handle = socket.withCString({
                ghostty_remote_connection_new_unix($0)
            }) else { return nil }
            return Connection(handle: handle, port: 0, pid: record.pid)
        }

        // Legacy TCP record (an older agent lineage still on --listen).
        guard let port = record.port, port > 0,
              let handle = "127.0.0.1".withCString({
                  ghostty_remote_connection_new_tcp($0, port)
              })
        else { return nil }
        return Connection(handle: handle, port: port, pid: record.pid)
    }

    // MARK: - Spawn

    /// Spawn the bundled agent detached (own session, stdio to the log file)
    /// and poll until its freshly-written port file dials. The agent is
    /// deliberately NOT our child in the same session: it must outlive the
    /// app across quit/upgrade/kill -9.
    private static func spawnAndDial(paths: Paths) -> Connection? {
        guard let bin = agentBinaryURL(),
              FileManager.default.isExecutableFile(atPath: bin.path)
        else {
            logger.error("local agent binary not found or not executable at \(Self.agentBinaryURL()?.path ?? "<nil>", privacy: .public)")
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: paths.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            logger.error("failed to create \(paths.directory.path, privacy: .public): \(error)")
            return nil
        }

        // Pre-spawn snapshot of the port file so polling can tell a fresh
        // write from the stale record that just failed dialExisting. (If a
        // healthy agent existed we would not be here.)
        let staleData = try? Data(contentsOf: paths.portFile)

        guard spawnDetached(binary: bin, paths: paths) else { return nil }

        // Poll for a healthy dial. The winner of the agent's single-instance
        // guard (ours, or a concurrent spawner's) rewrites the port file after
        // its bind; the loser exits 183 without touching it.
        if let conn = pollDial(paths: paths, seconds: 5.0, staleData: staleData) {
            return conn
        }
        logger.error("local agent did not become dialable within 5s; see \(paths.logFile.path, privacy: .public)")
        return nil
    }

    /// Poll the info file until a dial succeeds, or `seconds` elapse. Shared by
    /// the launchd path (wait for launchd's RunAtLoad agent to bind) and the
    /// detached-spawn fallback. `staleData`, when given, is the pre-action
    /// snapshot of the port file: a byte-identical read is skipped so we never
    /// dial the record that just failed (the fresh agent overwrites it on bind).
    private static func pollDial(
        paths: Paths, seconds: TimeInterval, staleData: Data? = nil
    ) -> Connection? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            usleep(100_000)
            let data = try? Data(contentsOf: paths.portFile)
            if let stale = staleData, data == stale { continue }
            if let conn = dialExisting(paths: paths) { return conn }
        }
        return nil
    }

    // MARK: - LaunchAgent (reboot floor, design §5.2)

    /// Write/refresh this lineage's LaunchAgent plist and load it into the
    /// per-user `gui/<uid>` domain, so launchd owns the agent with RunAtLoad +
    /// KeepAlive — it is (re)started at login and restarted within seconds if it
    /// is ever killed or crashes (AC3 reboot, AC4 agent crash). Idempotent:
    /// re-loading an unchanged, already-bootstrapped job is a no-op + kickstart.
    ///
    /// Returns true once launchd is managing the job (so the caller can poll for
    /// the agent to bind); false when launchctl is unavailable or the load
    /// failed, signalling the caller to fall back to a detached spawn.
    private static func ensureLaunchAgentLoaded(paths: Paths) -> Bool {
        // The agent binds sockets / writes the port + sessions files under this
        // directory; launchd won't create it, so ensure it exists first (0700 —
        // the UDS lives here and the same-uid gate assumes a private dir).
        do {
            try FileManager.default.createDirectory(
                at: paths.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            logger.error("failed to create \(paths.directory.path, privacy: .public): \(error)")
            return false
        }

        guard let desired = launchAgentPlistData(paths: paths) else { return false }

        let plistURL = paths.launchAgentPlistURL
        let existing = try? Data(contentsOf: plistURL)
        let changed = existing != desired
        if changed {
            do {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try desired.write(to: plistURL, options: .atomic)
            } catch {
                logger.error("failed to write \(plistURL.path, privacy: .public): \(error)")
                return false
            }
        }

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(paths.launchAgentLabel)"
        let loaded = launchctl(["print", service]).status == 0

        // Already loaded with an unchanged plist: just make sure it's running.
        if loaded && !changed {
            _ = launchctl(["kickstart", service])
            return true
        }

        // Changed plist (new bundle path/argv) → replace the stale job first so
        // launchd re-reads it. `bootout` is best-effort (may already be gone).
        if loaded { _ = launchctl(["bootout", service]) }

        let (rc, out) = launchctl(["bootstrap", domain, plistURL.path])
        // rc 5 == "service already bootstrapped" — a benign race with another
        // process/launch; anything else is a real failure.
        if rc != 0 && rc != 5 {
            logger.error("launchctl bootstrap \(service, privacy: .public) failed rc=\(rc): \(out, privacy: .public)")
            return false
        }
        _ = launchctl(["kickstart", service])
        return launchctl(["print", service]).status == 0
    }

    /// Remove the LaunchAgent job + plist for this lineage. Not called in the
    /// normal flow (the agent is meant to persist across app quits); exposed for
    /// teardown/tests so a KeepAlive job doesn't linger.
    @discardableResult
    static func uninstallLaunchAgent(paths: Paths = .current) -> Bool {
        let service = "gui/\(getuid())/\(paths.launchAgentLabel)"
        _ = launchctl(["bootout", service])
        try? FileManager.default.removeItem(at: paths.launchAgentPlistURL)
        return true
    }

    /// The plist bytes launchd loads. Uses `PropertyListSerialization` so paths
    /// with XML-special characters are escaped correctly.
    private static func launchAgentPlistData(paths: Paths) -> Data? {
        guard let bin = agentBinaryURL(),
              FileManager.default.isExecutableFile(atPath: bin.path)
        else {
            logger.error("local agent binary not found or not executable at \(Self.agentBinaryURL()?.path ?? "<nil>", privacy: .public)")
            return nil
        }

        let argv: [String] = [
            bin.path,
            "--listen-unix=\(paths.socketFile.path)",
            "--port-file=\(paths.portFile.path)",
            "--sessions-file=\(paths.sessionsFile.path)",
        ]

        // launchd does NOT inherit the app's environment, so bake in the guard
        // paths + self-update opt-out (as spawnDetached passes) plus the few
        // vars the agent needs to resolve a login shell for its sessions.
        var env: [String: String] = [
            "GHOSTTY_AGENT_LOCK": paths.lockFile.path,
            "GHOSTTY_AGENT_HEARTBEAT": paths.heartbeatFile.path,
            "GHOSTTY_AGENT_NO_SELFUPDATE": "1",
        ]
        let appEnv = ProcessInfo.processInfo.environment
        for key in ["SHELL", "PATH", "LANG"] {
            if let v = appEnv[key], !v.isEmpty { env[key] = v }
        }

        let plist: [String: Any] = [
            "Label": paths.launchAgentLabel,
            "ProgramArguments": argv,
            "EnvironmentVariables": env,
            "WorkingDirectory": paths.home.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            // Interactive: latency-sensitive, not a batch job — keep it off the
            // throttled background band.
            "ProcessType": "Interactive",
            "StandardOutPath": paths.logFile.path,
            "StandardErrorPath": paths.logFile.path,
        ]
        return try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Run `/bin/launchctl` with `args`, returning its exit status + combined
    /// output. Synchronous (each launchctl verb returns promptly).
    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// posix_spawn the agent in a NEW session (POSIX_SPAWN_SETSID): no
    /// controlling terminal, not in the app's process group, reparented to
    /// launchd — app exit (or SIGKILL) cannot take it down. stdin is
    /// /dev/null; stdout/stderr append to agent.log for diagnosis.
    private static func spawnDetached(binary: URL, paths: Paths) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, 1, paths.logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        // The agent's cwd is the default cwd of every session it OPENs without
        // an explicit one. The app's own cwd is "/" when launched from Finder —
        // start the agent in the user's home instead.
        posix_spawn_file_actions_addchdir_np(
            &actions, FileManager.default.homeDirectoryForCurrentUser.path)

        // The SECURE local transport (design §5.2): a 0600 AF_UNIX socket with a
        // same-uid peercred gate — unlike a 127.0.0.1 TCP port, no other local
        // uid can reach the shell. The agent publishes its pid + socket path to
        // the info file (`--port-file`) so we can find-or-dial it next time.
        let argv: [String] = [
            binary.path,
            "--listen-unix=\(paths.socketFile.path)",
            "--port-file=\(paths.portFile.path)",
            // Reboot-floor metadata store (design §5.4, T12): the agent keeps this
            // current with its live-session roster so sessions can be relaunched
            // after an agent/machine restart.
            "--sessions-file=\(paths.sessionsFile.path)",
        ]

        // Inherit the app's environment, forcing the per-lineage guard paths
        // and disabling self-update (the bundle owns the binary's lifecycle;
        // Sparkle replaces it with the app).
        var env = ProcessInfo.processInfo.environment
        env["GHOSTTY_AGENT_LOCK"] = paths.lockFile.path
        env["GHOSTTY_AGENT_HEARTBEAT"] = paths.heartbeatFile.path
        env["GHOSTTY_AGENT_NO_SELFUPDATE"] = "1"

        var cArgv = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary.path, &actions, &attr, cArgv, cEnv)
        guard rc == 0 else {
            logger.error("posix_spawn(\(binary.path, privacy: .public)) failed: \(String(cString: strerror(rc)), privacy: .public)")
            return false
        }
        logger.info("spawned local agent pid \(pid) (log: \(paths.logFile.path, privacy: .public))")
        return true
    }
}
