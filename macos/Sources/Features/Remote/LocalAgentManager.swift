import AppKit
import Foundation
import GhosttyKit
import os
import SwiftUI

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

    /// Thread-safe one-shot holder for a `connect()` result handed from a
    /// background queue to the main thread across a `DispatchSemaphore`, used by
    /// `sharedConnectionForNewSurface`'s bounded wait. `Connection` is a plain
    /// value (a C handle + ints); the lock only guards the cross-thread handoff.
    private final class ConnectResultBox {
        private let lock = NSLock()
        private var value: Connection?
        func set(_ v: Connection?) { lock.lock(); value = v; lock.unlock() }
        func take() -> Connection? {
            lock.lock(); defer { value = nil; lock.unlock() }; return value
        }
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

    /// Called (main thread) once the shared connection's transport has been
    /// CONFIRMED down — down at the edge and still down `sharedLinkDropSettle`
    /// later (see `evaluateSharedLinkDrop`). `AppDelegate` wires this to
    /// `recoverSessionLayoutInPlace()`. Set once at launch; fired at most once
    /// per shared connection (the recovery re-dials and installs a fresh
    /// `sharedOwner` with a fresh observer). Main only.
    ///
    /// A down EDGE on its own is not enough: the Zig link FSM enters
    /// `reconnecting` after three missed heartbeats and returns to `connected`
    /// on the next authentic packet, so a stalled heartbeat is indistinguishable
    /// from a dead agent for a few hundred milliseconds — and rebuilding on that
    /// blip is pure damage.
    var onSharedConnectionDrop: (@MainActor () -> Void)?

    /// The Machine value describing the local agent endpoint. A loopback
    /// host/name makes `Machine.isLocalMachine` true, so remote-only UI (the
    /// titlebar machine pill) stays hidden for persistent local windows.
    static func localMachine(port: UInt16 = 0) -> Machine {
        // The loopback `name` makes `isLocalMachine` true even with port 0 (the
        // UDS transport has no port), so the machine pill stays hidden.
        Machine(name: "127.0.0.1", host: "127.0.0.1", port: port)
    }

    /// Timestamp of the last find-or-spawn failure, so `session-persistence`
    /// default-on never re-beachballs window creation against a broken or
    /// unspawnable agent: after a failure, new surfaces fall back to exec
    /// immediately for `connectFailureCooldown` while `warmUp()` keeps retrying
    /// in the background. Main-thread only.
    private var lastConnectFailureAt: Date?
    private let connectFailureCooldown: TimeInterval = 15

    /// Resolve the shared local-agent connection for a NEW persistent surface,
    /// with a BOUNDED main-thread wait so `session-persistence` (default-on
    /// since T19) can never hang window creation:
    ///
    ///   * a warm, healthy connection returns instantly (the common case after
    ///     `warmUp()` at launch);
    ///   * otherwise a find-or-spawn+dial runs on a background queue and we wait
    ///     at most `timeout` for it — a healthy agent dials in well under a
    ///     second (spawn ~300ms), so it lands agent-backed; a slow/broken agent
    ///     exceeds the bound and this returns nil, so the caller opens a plain
    ///     exec surface for THIS window while the eventual connection is cached
    ///     (or the failure recorded) for the next one;
    ///   * a recent find-or-spawn failure short-circuits to nil (no probe, no
    ///     wait) for a cooldown, so an unspawnable agent doesn't re-block every
    ///     window.
    ///
    /// nil ⇒ the caller must fall back to a non-persistent exec surface.
    /// Main-thread only.
    func sharedConnectionForNewSurface(timeout: TimeInterval = 2.0) -> RemoteConnection? {
        dispatchPrecondition(condition: .onQueue(.main))

        // Fast path: a warm, healthy connection — agent-backed, no wait.
        if let warm = warmSharedOwner() { return warm }

        // Dead link or dead agent: drop our reference (windows still using the
        // old connection keep it alive; their reconnect ladder handles it).
        sharedOwner = nil
        sharedAgentPid = 0

        // Known-broken recently: fall back to exec now, no probe. `warmUp()`
        // keeps retrying in the background and will clear this on success.
        if let last = lastConnectFailureAt,
           Date().timeIntervalSince(last) < connectFailureCooldown {
            return nil
        }

        // No warm connection and no recent failure: bounded find-or-spawn.
        let box = ConnectResultBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            box.set(connect())
            sem.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            // Still dialing — don't hold the main thread. Absorb the eventual
            // result (cache it, or record the failure) when it lands, and open
            // an exec surface for this window now.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                sem.wait()
                let conn = box.take()
                DispatchQueue.main.async { self.absorbConnectResult(conn) }
            }
            return nil
        }

        // Completed within the bound.
        return absorbConnectResult(box.take())
    }

    /// Cache a freshly-dialed connection as the shared owner (or record the
    /// failure), returning the resulting owner. Idempotent against a racing
    /// caller that cached one first: keep theirs, free ours. Main-thread only.
    @discardableResult
    private func absorbConnectResult(_ conn: Connection?) -> RemoteConnection? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let conn else {
            lastConnectFailureAt = Date()
            return nil
        }
        lastConnectFailureAt = nil
        if let warm = warmSharedOwner() {
            ghostty_remote_connection_free(conn.handle)
            return warm
        }
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
                    self.lastConnectFailureAt = nil
                    completion(existing)
                    return
                }
                guard let conn else {
                    // Record the failure so default-on window creation short-
                    // circuits to exec during the cooldown instead of re-probing.
                    self.lastConnectFailureAt = Date()
                    completion(nil)
                    return
                }
                self.lastConnectFailureAt = nil
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
    ///
    /// (See `warmSharedHandle` below for the long-lived-subscription variant.)

    /// The warm shared local-agent connection, when one is healthy and its agent
    /// is still alive. **Borrowed, never owned**: `LocalAgentManager` holds this
    /// for the app's lifetime, so a caller must not free it — only use it for the
    /// duration of a subscription and unsubscribe when done.
    ///
    /// Exposed for long-lived subscriptions (the chooser's per-session CPU
    /// stream), which — unlike `listLocalSessions`' one-shot RPC — need the SAME
    /// connection to stay open across pushes. Returns nil when there is no warm
    /// connection; callers then simply do without rather than spawning an agent.
    var warmSharedHandle: ghostty_remote_connection_t? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let existing = sharedOwner,
              existing.linkState != .dead,
              sharedAgentPid > 0,
              kill(sharedAgentPid, 0) == 0 || errno == EPERM
        else { return nil }
        return existing.handle
    }

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
                onMainEvenWhenModal { completion(sessions) }
            }
            return
        }

        // No warm shared connection: dial the EXISTING agent only (no spawn), so
        // browsing never starts an agent. Free the probe connection afterward.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let conn = Self.dialExisting(paths: .current) else {
                onMainEvenWhenModal { completion(nil) }
                return
            }
            let sessions = RemoteSessionRoster.list(handle: conn.handle)
            ghostty_remote_connection_free(conn.handle)
            onMainEvenWhenModal { completion(sessions) }
        }
    }

    /// Close (end) a local-agent session by id — the session-scoped equivalent
    /// of closing its pane (`+close`): the agent terminates the child and frees
    /// the session container. Reuses the warm shared connection when healthy (NOT
    /// freed here — the app owns it), else dials the EXISTING agent only (never
    /// spawns, so killing a browsed session never starts an agent). The
    /// `CLOSE_SESSION` RPC blocks, so it runs on a background queue; `completion`
    /// (true iff the agent confirmed the close) is delivered on the main actor.
    func closeLocalSession(_ sessionID: String, completion: @escaping @MainActor (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        if let existing = sharedOwner,
           existing.linkState != .dead,
           sharedAgentPid > 0,
           kill(sharedAgentPid, 0) == 0 || errno == EPERM {
            let handle = existing.handle
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = RemoteSessionKiller.close(handle: handle, sessionID: sessionID)
                onMainEvenWhenModal { completion(ok) }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let conn = Self.dialExisting(paths: .current) else {
                onMainEvenWhenModal { completion(false) }
                return
            }
            let ok = RemoteSessionKiller.close(handle: conn.handle, sessionID: sessionID)
            ghostty_remote_connection_free(conn.handle)
            onMainEvenWhenModal { completion(ok) }
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

    /// (Re)bind the link-state observer to `owner` so a CONFIRMED transport drop
    /// on the shared connection triggers in-place recovery (T12e). The prior
    /// observer, if any, is removed first. Main-thread only.
    private func bindSharedLinkObserver(_ owner: RemoteConnection) {
        if let existing = sharedLinkObserver {
            NotificationCenter.default.removeObserver(existing)
            sharedLinkObserver = nil
        }
        sharedLinkDropWatchOwner = nil
        sharedLinkObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyRemoteConnectionLinkDidChange,
            object: owner,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let conn = note.object as? RemoteConnection,
                  conn === self.sharedOwner,
                  conn.linkState.isDown else { return }
            // A down edge is NOT proof the agent died — see `LinkState.isDown`.
            // Recovery replaces every local window's surface tree, so it must
            // never run on a blip: watch the link for `sharedLinkDropSettle`
            // and only hand off if it never comes back. The observer stays
            // bound throughout, so a link that heals and drops again later is
            // still caught.
            self.beginSharedLinkDropWatch(conn)
        }
    }

    // MARK: - Confirming a shared-link drop

    /// How long the shared link must stay down before a drop counts as real.
    /// The Zig FSM's heartbeat path recovers on the very next authentic packet
    /// (the 2026-07-21 incident healed in 27ms); a genuinely dead agent never
    /// does. Sized past one full `heartbeat_interval_ms` (3s in
    /// `src/remote/connection.zig`) so a link that only heals on its next
    /// heartbeat round-trip still gets to, plus margin. Recovery rebuilds every
    /// local window, and a truly dead agent leaves those panes frozen either
    /// way — so waiting to be sure costs nothing that was not already lost.
    static let sharedLinkDropSettle: TimeInterval = 5.0

    /// How often the settle window is re-checked. Short enough that a real drop
    /// is confirmed promptly once the window elapses.
    static let sharedLinkDropPollInterval: TimeInterval = 0.25

    /// What a down shared link means once re-checked. Pure, so the policy is
    /// unit-testable without a live agent.
    enum SharedLinkDropVerdict: Equatable {
        /// The link came back on its own. Do nothing at all.
        case linkRecovered

        /// A different shared connection has been installed meanwhile (a racing
        /// re-dial), so this owner is nobody's transport now. Do nothing.
        case ownerReplaced

        /// Still down, but the settle window has not elapsed. Keep watching.
        case keepWatching

        /// Still down after the settle window, and the agent we were talking to
        /// is no longer the agent on disk (it restarted, or it is gone).
        /// `currentPid` is nil when no live agent could be found at all.
        case agentRestarted(previousPid: pid_t, currentPid: pid_t?)

        /// Still down after the settle window, but the SAME agent process is
        /// alive: the transport failed, not the agent. Rebuilding is still the
        /// cure (re-dial + re-ATTACH), but nothing here restarted — saying so
        /// in the log is what made the 2026-07-21 incident hard to diagnose.
        case transportDown(pid: pid_t)

        /// Whether this verdict means "rebuild the local windows in place".
        var triggersRecovery: Bool {
            switch self {
            case .agentRestarted, .transportDown: return true
            case .linkRecovered, .ownerReplaced, .keepWatching: return false
            }
        }
    }

    /// Decide what a down shared link means. `settleRemaining` is the settle
    /// time left AFTER this check; `liveAgentPid` is the pid recorded in the
    /// agent's info file (nil when no live agent is there) and is only consulted
    /// once the window has elapsed.
    static func evaluateSharedLinkDrop(
        linkState: RemoteConnection.LinkState,
        ownerIsCurrentShared: Bool,
        settleRemaining: TimeInterval,
        previousAgentPid: pid_t,
        liveAgentPid: pid_t?
    ) -> SharedLinkDropVerdict {
        guard ownerIsCurrentShared else { return .ownerReplaced }
        guard linkState.isDown else { return .linkRecovered }
        guard settleRemaining <= 0 else { return .keepWatching }
        if let liveAgentPid, previousAgentPid > 0, liveAgentPid == previousAgentPid {
            return .transportDown(pid: liveAgentPid)
        }
        return .agentRestarted(previousPid: previousAgentPid, currentPid: liveAgentPid)
    }

    /// The connection whose down link we are currently watching, so overlapping
    /// down edges (`reconnecting → dead`) share ONE settle window. Main only.
    private var sharedLinkDropWatchOwner: RemoteConnection?

    /// Start (or keep) the settle window for `owner`'s down link.
    private func beginSharedLinkDropWatch(_ owner: RemoteConnection) {
        guard sharedLinkDropWatchOwner !== owner else { return }
        sharedLinkDropWatchOwner = owner
        Self.logger.warning(
            "shared local-agent link went down (\(String(describing: owner.linkState), privacy: .public)); watching \(Self.sharedLinkDropSettle, privacy: .public)s before deciding on in-place recovery")
        pollSharedLinkDrop(owner, remaining: Self.sharedLinkDropSettle)
    }

    /// One tick of the settle window. Re-arms itself until the link recovers,
    /// the owner is replaced, or the window elapses with the link still down.
    private func pollSharedLinkDrop(_ owner: RemoteConnection, remaining: TimeInterval) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sharedLinkDropPollInterval
        ) { [weak self] in
            guard let self, self.sharedLinkDropWatchOwner === owner else { return }
            let left = remaining - Self.sharedLinkDropPollInterval
            let isShared = self.sharedOwner === owner
            // Only touch the filesystem on the deciding tick.
            let livePid: pid_t? = (isShared && owner.linkState.isDown && left <= 0)
                ? Self.liveAgentPid(paths: .current) : nil
            let verdict = Self.evaluateSharedLinkDrop(
                linkState: owner.linkState,
                ownerIsCurrentShared: isShared,
                settleRemaining: left,
                previousAgentPid: self.sharedAgentPid,
                liveAgentPid: livePid)

            switch verdict {
            case .keepWatching:
                self.pollSharedLinkDrop(owner, remaining: left)
            case .linkRecovered:
                self.sharedLinkDropWatchOwner = nil
                Self.logger.warning(
                    "shared local-agent link recovered on its own (\(String(describing: owner.linkState), privacy: .public)); no in-place recovery needed")
            case .ownerReplaced:
                self.sharedLinkDropWatchOwner = nil
                Self.logger.info(
                    "shared local-agent link dropped but a new shared connection is already in place; nothing to recover")
            case .transportDown(let pid):
                self.sharedLinkDropWatchOwner = nil
                self.detachSharedLinkObserver()
                Self.logger.warning(
                    "shared local-agent link stayed down for \(Self.sharedLinkDropSettle, privacy: .public)s while agent pid \(pid, privacy: .public) is still running: the transport failed, not the agent; re-dialing to rebuild local windows in place")
                self.onSharedConnectionDrop?()
            case .agentRestarted(let previous, let current):
                self.sharedLinkDropWatchOwner = nil
                self.detachSharedLinkObserver()
                Self.logger.warning(
                    "shared local-agent link stayed down for \(Self.sharedLinkDropSettle, privacy: .public)s and agent pid \(previous, privacy: .public) is gone (info file now reports \(current.map(String.init) ?? "no live agent", privacy: .public)); re-dialing the restarted agent to rebuild local windows in place")
                self.onSharedConnectionDrop?()
            }
        }
    }

    /// Stop observing the current shared owner's link. Recovery re-dials and
    /// installs a fresh owner with its own observer, so a follow-up
    /// `reconnecting → dead` edge can't re-fire the same handoff.
    private func detachSharedLinkObserver() {
        guard let observer = sharedLinkObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        sharedLinkObserver = nil
    }

    /// Drop the cached shared connection and its observer so the NEXT resolve
    /// re-dials from scratch. Windows still riding the old connection keep it
    /// alive via `connectionKeepAlive` until their surfaces are replaced. Used
    /// by in-place recovery (T12e) before re-dialing the restarted agent.
    /// Main-thread only.
    func invalidateShared() {
        dispatchPrecondition(condition: .onQueue(.main))
        detachSharedLinkObserver()
        sharedLinkDropWatchOwner = nil
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

    // MARK: - Non-destructive agent upgrade (staleness detection + lazy refresh)

    /// The build stamp ("YYYYMMDD-<hash>") of the agent binary THIS app bundles,
    /// learned once by invoking `<bundled agent> --version`. nil ⇒ can't be
    /// determined ⇒ we never judge the running agent stale (fail safe). Cached
    /// for the app's lifetime.
    static let bundledAgentVersion: String? = computeBundledAgentVersion()

    private static func computeBundledAgentVersion() -> String? {
        guard let url = agentBinaryURL(),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        // Output form: "ghoztty-agent YYYYMMDD-<hash>\n" → the last token.
        guard let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let stamp = line.split(whereSeparator: { $0 == " " || $0.isNewline }).last
        else { return nil }
        let s = String(stamp)
        return s.isEmpty ? nil : s
    }

    /// True iff stamp `a` is a NEWER build than `b`, ordered by the `YYYYMMDD`
    /// date prefix. Same date (or an unparseable prefix) ⇒ false, so an equal or
    /// unknown date never *blocks* a refresh (the stamp-equality check decides
    /// that), yet a genuinely newer running agent is never downgraded.
    static func agentStampIsNewer(_ a: String, than b: String) -> Bool {
        func datePrefix(_ s: String) -> Int { Int(s.prefix(while: { $0.isNumber })) ?? 0 }
        return datePrefix(a) > datePrefix(b)
    }

    /// Is the connected agent an OLDER build than the one this app bundles?
    /// `running == nil` ⇒ an agent too old to advertise a stamp ⇒ stale (it
    /// predates this feature). Exact match ⇒ current. A running build NEWER than
    /// bundled ⇒ NOT stale (never downgrade the agent out from under the app).
    static func agentIsStale(running: String?, bundled: String) -> Bool {
        guard let running else { return true }
        if running == bundled { return false }
        if agentStampIsNewer(running, than: bundled) { return false }
        return true
    }

    /// Lazily adopt a newer bundled agent build, called ONLY at safe moments:
    /// layout restore finished with no live panes, or the last persistent pane
    /// just closed. Idle (`liveSessionCount == 0`) ⇒ restart silently — nothing
    /// to lose — logged + a subtle notice. Live sessions ⇒ NEVER silent: a
    /// mandatory confirmation before any destructive restart (docs/claude/sessions.md's "never
    /// silently reset live sessions"). No-op when the agent is already current,
    /// the bundled build is unknown, or there is no shared connection.
    @MainActor
    func refreshLocalAgentIfStale(liveSessionCount: Int, reason: String) {
        guard let bundled = Self.bundledAgentVersion else { return }
        // Resolve the shared connection (reuse the warm one, or dial the running
        // agent) so this works even on a no-session launch — the most common
        // stale case — where `sharedOwner` isn't cached yet. Reusing an existing
        // agent never spawns; a genuinely absent agent yields a fresh (current)
        // one, which reads as not-stale.
        sharedConnectionAsync { [weak self] owner in
            guard let self, let owner else { return }
            let running = owner.agentBuildVersion
            guard Self.agentIsStale(running: running, bundled: bundled) else { return }
            if liveSessionCount == 0 {
                Self.logger.info("local agent stale (running \(running ?? "<pre-versioned>", privacy: .public) != bundled \(bundled, privacy: .public)); idle → refreshing [\(reason, privacy: .public)]")
                self.forceRefreshLocalAgent(reconnect: false)
                self.postAgentRefreshNotice(to: bundled)
            } else {
                self.promptAndRefreshLocalAgent(liveSessionCount: liveSessionCount, running: running, bundled: bundled)
            }
        }
    }

    /// Bootout + bootstrap the launchd job so it re-execs the newer bundled agent
    /// binary, then drop the shared connection so the next use dials the fresh
    /// agent. `reconnect` drives in-place session-layout recovery (used by the
    /// destructive path so live windows rebind/relaunch); the idle path leaves
    /// reconnection to the next warm-up. Caller MUST have established it is safe
    /// (idle) or user-confirmed — the bootout ends any live agent children.
    @MainActor
    private func forceRefreshLocalAgent(reconnect: Bool) {
        lock.lock()
        let ok = Self.ensureLaunchAgentLoaded(paths: .current, force: true)
        lock.unlock()
        guard ok else {
            Self.logger.error("force agent refresh failed to (re)load launchd job")
            return
        }
        invalidateShared()
        if reconnect {
            onSharedConnectionDrop?()
        } else {
            warmUp()
        }
    }

    /// Build the mandatory agent-restart confirmation, including the offline
    /// "What's new" accessory when bundled notes are available. Free of side
    /// effects (no runModal) so it is unit-testable.
    @MainActor
    static func makeUpgradeAlert(
        liveSessionCount n: Int,
        previousSeen: String?,
        current: String,
        store: ReleaseNotesStore
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Restart the Ghoztty background terminal process?"
        let sessions = "\(n) open terminal session\(n == 1 ? "" : "s")"
        alert.informativeText = "Ghoztty keeps your terminal sessions running in the background. Finishing this update restarts that background process, which will close your \(sessions) — they can’t be carried across the update. You can keep working instead: Ghoztty updates automatically the next time no sessions are open."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .warning

        let split = store.partitioned(previousSeen: previousSeen, current: current)
        if !split.new.isEmpty || !split.installed.isEmpty {
            let host = NSHostingView(
                rootView: WhatsNewNotesView(newNotes: split.new, installedNotes: split.installed))
            host.frame = NSRect(origin: .zero, size: WhatsNewNotesView.preferredSize)
            alert.accessoryView = host
        }
        return alert
    }

    /// The mandatory confirmation before a destructive agent restart while
    /// sessions are live. On confirm → refresh (live windows recover/relaunch);
    /// on defer → nothing (the agent refreshes automatically once idle).
    @MainActor
    private func promptAndRefreshLocalAgent(liveSessionCount n: Int, running: String?, bundled: String) {
        let alert = Self.makeUpgradeAlert(
            liveSessionCount: n,
            previousSeen: WhatsNewTracking.previousSeenVersion,
            current: WhatsNewTracking.currentAppVersion,
            store: ReleaseNotesStore(directory: ReleaseNotesStore.agentNotesDirectory))
        guard alert.runModal() == .alertFirstButtonReturn else {
            Self.logger.info("user deferred destructive agent refresh (\(n) live session(s))")
            return
        }
        Self.logger.info("user confirmed destructive agent refresh (running \(running ?? "<pre-versioned>", privacy: .public) → bundled \(bundled, privacy: .public), \(n) live session(s))")
        forceRefreshLocalAgent(reconnect: true)
    }

    /// The idle refresh is silent (no modal) but never fully invisible: it is
    /// recorded to the unified log so an operator/user can confirm exactly when
    /// the background agent was adopted. (A visible in-app toast is Phase-2
    /// polish.)
    @MainActor
    private func postAgentRefreshNotice(to bundled: String) {
        Self.logger.notice("local agent refreshed to bundled build \(bundled, privacy: .public) (idle, no sessions affected)")
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

    /// True iff the agent recorded in the info file is still a live process.
    /// Used by `ensureLaunchAgentLoaded` (FIX 1a) to refuse a destructive
    /// bootout of a running agent: an alive pid means live PTYs + children we
    /// must not tombstone. Uses the SAME liveness probe as `dialExisting` (signal
    /// 0; EPERM still means "exists"), but does NOT dial — a live-but-momentarily-
    /// unresponsive agent (slow HELLO, socket backlog) must count as alive here so
    /// we never restart it out from under its sessions.
    private static func agentProcessAlive(paths: Paths) -> Bool {
        liveAgentPid(paths: paths) != nil
    }

    /// The pid of the agent recorded in the info file, or nil when the file is
    /// missing/garbage or that process is gone. Same liveness probe as
    /// `dialExisting` (signal 0; EPERM still means "exists") and, like
    /// `agentProcessAlive`, deliberately does NOT dial: this answers "is the
    /// agent I was talking to still the agent that is there?", which a slow
    /// HELLO must not turn into a false "it restarted".
    static func liveAgentPid(paths: Paths) -> pid_t? {
        guard let data = try? Data(contentsOf: paths.portFile),
              let record = parsePortFile(data),
              kill(record.pid, 0) == 0 || errno == EPERM
        else { return nil }
        return record.pid
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
    /// `force` = a DELIBERATE restart of the launchd job (bootout + bootstrap),
    /// even when the plist is unchanged and the agent is alive. The normal
    /// (force == false) path NEVER bootouts a live agent — it defers to the next
    /// cold start to avoid tombstoning sessions. `force` is used only by the
    /// non-destructive-upgrade path (`refreshLocalAgentIfStale`), which has
    /// already established it is safe (agent idle) or user-confirmed (destructive)
    /// to restart, so the agent can pick up a newer bundled binary now.
    private static func ensureLaunchAgentLoaded(paths: Paths, force: Bool = false) -> Bool {
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
        // Compare only the STABLE part of the plist. `launchAgentPlistData` bakes
        // in PATH/SHELL/LANG inherited from the app's environment (FIX 1b), which
        // drift between launches (Finder vs a terminal vs a different parent
        // shell) even when nothing about the agent config really changed. If those
        // volatile keys counted toward `changed`, an ordinary upgrade would flip
        // it on nearly every launch and take the destructive reload path below —
        // booting out the running agent and tombstoning its children. Normalize
        // them out of BOTH sides so an unchanged agent config compares equal and
        // no rebootstrap happens. (The plist we WRITE still carries the current
        // env; we just don't treat env drift as a config change.)
        let changed = existing.map {
            Self.plistComparisonKey($0) != Self.plistComparisonKey(desired)
        } ?? true
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

        // Already loaded with an unchanged (stable) config: just make sure it's
        // running.
        if loaded && !changed && !force {
            _ = launchctl(["kickstart", service])
            return true
        }

        // The stable config changed, or the job isn't loaded. We must get the new
        // plist into launchd — but NEVER by booting out a LIVE agent (FIX 1a): a
        // bootout kills the agent's children, which come back as dead tombstones
        // (the past "everything came back tombstoned" upgrades). Per docs/claude/sessions.md's
        // mandated lazy / non-destructive upgrade, if the recorded agent is still
        // alive we leave it — and its sessions — untouched. The new plist is
        // already on disk, so the NEXT cold start (reboot, agent crash → KeepAlive
        // respawn, or the user closing every session) picks it up. The argv
        // (bundle-relative binary path + per-lineage socket/port/sessions paths)
        // is stable across app upgrades, so a deferred reload loses nothing — a
        // later respawn execs the upgraded binary at the same path.
        //
        // Note this path is normally only reachable after `dialExisting` already
        // failed (connect:139), so "alive" here means a live agent that just
        // wasn't answering the dial in that instant (slow HELLO, socket backlog,
        // mid-GC). Restarting it then would be the exact destructive mistake; the
        // caller's `pollDial` retries the dial for 5s instead, and if that still
        // fails the window falls back to a plain exec surface — the live sessions
        // are never reset.
        if loaded && changed && !force && Self.agentProcessAlive(paths: paths) {
            logger.info("agent LaunchAgent config changed but a live agent (pid from \(paths.portFile.lastPathComponent, privacy: .public)) is running; deferring reload to next cold start (no bootout, sessions preserved)")
            _ = launchctl(["kickstart", service])
            return true
        }

        // Loaded+changed with NO live agent (a genuinely dead/absent agent), or
        // not loaded at all → safe to (re)bootstrap so launchd re-reads the plist.
        // `bootout` is best-effort (the job may already be gone).
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

    /// A comparison key for a LaunchAgent plist that ignores the VOLATILE baked
    /// env (PATH/SHELL/LANG) so drift in those keys doesn't count as a config
    /// change (FIX 1b). Parses the plist and strips those env subkeys, returning
    /// an order-insensitive `NSDictionary` so two plists that differ only in the
    /// volatile env compare equal. A plist that fails to parse returns nil, which
    /// `ensureLaunchAgentLoaded` treats as "changed" (fail safe: an unreadable or
    /// malformed existing plist should be rewritten). The keys stripped here are
    /// exactly the ones `launchAgentPlistData` inherits from the app environment.
    private static let volatileEnvKeys = ["PATH", "SHELL", "LANG"]
    private static func plistComparisonKey(_ data: Data) -> NSDictionary? {
        guard var plist = (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        if var env = plist["EnvironmentVariables"] as? [String: Any] {
            for key in volatileEnvKeys { env.removeValue(forKey: key) }
            plist["EnvironmentVariables"] = env
        }
        return plist as NSDictionary
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
