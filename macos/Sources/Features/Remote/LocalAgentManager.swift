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

        init(bundleID: String?, home: URL) {
            // The debug lineage (com.dzearing.ghoztty.debug) gets its own
            // directory; anything else — including a nil bundle id when
            // running bare — is the release lineage.
            let name = bundleID?.hasSuffix(".debug") == true
                ? "local-agent-debug" : "local-agent"
            self.directory = home
                .appendingPathComponent(".config/ghoztty/\(name)", isDirectory: true)
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

    /// Wrap a dialed connection in a strong `RemoteConnection` owner and cache
    /// it as the shared one. Main-thread only.
    private func cacheShared(_ conn: Connection) -> RemoteConnection {
        let owner = RemoteConnection(
            handle: conn.handle,
            machine: Self.localMachine(port: conn.port))
        sharedOwner = owner
        sharedAgentPid = conn.pid
        Self.logger.info("shared local-agent connection ready (agent pid \(conn.pid), port \(conn.port))")
        return owner
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
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            usleep(100_000)
            let data = try? Data(contentsOf: paths.portFile)
            if data == staleData, staleData != nil { continue }
            if let conn = dialExisting(paths: paths) { return conn }
        }
        logger.error("local agent did not become dialable within 5s; see \(paths.logFile.path, privacy: .public)")
        return nil
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
