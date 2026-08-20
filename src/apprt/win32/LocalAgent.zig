//! Finds or spawns the local `ghoztty-agent` and hands back a dialed
//! connection to it — the Windows local end of session persistence (T89d,
//! design §T89a decision 3). Panes backed by this agent survive the app
//! process (quit, crash, upgrade) and can be re-attached (T89f).
//!
//! The Windows local transport is a byte-mode named pipe
//! (`\\.\pipe\ghoztty-agent[-debug]-<user>`) with an owner-only DACL (T89c):
//! the DACL stands in for the Mac's 0600 AF_UNIX + SO_PEERCRED same-uid gate —
//! only this user can reach the shell (unlike a 127.0.0.1 TCP port).
//!
//! Discovery order, mirroring `LocalAgentManager` on the Mac:
//!
//!  1. **Find**: read the agent's info file (`port.json`, written after its
//!     pipe binds), dial the recorded `pipe`. The dial BLOCKS through the
//!     HELLO handshake, so a non-null handle IS the health check.
//!  2. **Spawn**: launch `ghoztty-agent.exe` (a sibling of `ghoztty.exe`,
//!     override via `GHOSTTY_LOCAL_AGENT_BIN`) DETACHED so it outlives the
//!     app, with `--listen-pipe`/`--port-file`/`--sessions-file`, then poll
//!     the info file until a dial succeeds (bounded).
//!
//! All state lives in a per-lineage dir keyed by the debug/release build
//! (`%LOCALAPPDATA%\ghoztty\local-agent[-debug]\`) so the debug app never
//! shares an agent — or its sessions — with the release app (design §T89a
//! decision 2). The agent's single-instance guard uses a distinct `local`
//! key (T89d1), so a concurrent double-spawn (or a coexisting relay agent) is
//! safe: the loser exits cleanly.
//!
//! Default-on (`session-persistence`, T19 / config): the resolve is BOUNDED
//! and non-fatal — a broken or unspawnable agent yields null within
//! `spawn_deadline_ms`, and the caller opens a plain exec surface for that
//! window instead of hanging. After a failure, new surfaces fall back to exec
//! for `failure_cooldown_ms` so an unspawnable agent never re-beachballs every
//! window.

const LocalAgent = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const tcp_dial = @import("../../remote/tcp_dial.zig");
const connection = @import("../../remote/connection.zig");
const agent_lineage = @import("../../remote/agent_lineage.zig");
const build_config = @import("../../build_config.zig");
const protocol = @import("../../remote/protocol.zig");
const agent_upgrade = @import("agent_upgrade.zig");
const gui_pump = @import("gui_pump.zig");
const job_object = @import("job_object.zig");
const job_spawn = @import("job_spawn.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_local_agent);

/// Bounded wall-clock budget for a find-or-spawn resolve (design §T89a
/// decision 3: "2s bound"). A healthy agent dials in well under a second
/// (spawn ~300ms); a slow/broken one exceeds this and the caller falls back
/// to exec.
const spawn_deadline_ms: i64 = 2000;

/// HELLO-handshake deadline for a single probe dial. Short so a wedged agent
/// (accepts the pipe but never answers) can't eat the whole `spawn_deadline_ms`
/// budget in one attempt.
const probe_handshake_ns: u64 = 1200 * std.time.ns_per_ms;

/// After a failed resolve, short-circuit to exec (no probe, no wait) for this
/// long so an unspawnable agent doesn't re-block every window (Mac
/// `connectFailureCooldown` = 15s).
const failure_cooldown_ms: i64 = 15_000;

/// Poll interval while waiting for a freshly-spawned agent to bind + write its
/// info file.
const poll_interval_ms: u64 = 100;

alloc: Allocator,

/// The cached shared connection. Every persistent window/tab/split rides this
/// ONE connection, exactly like the tabs/splits of a remote window share
/// theirs. Owned here for the app's lifetime; surfaces BORROW `.conn`. Null
/// until the first successful resolve (or after the agent is found dead).
shared: ?tcp_dial.Dialed = null,

/// The pid of the agent process `shared` is talking to, as recorded in its info
/// file at dial time. 0 when unknown. Read by the crash-recovery policy (T145)
/// to tell "the agent restarted" from "the transport failed while the SAME
/// agent kept running" — a distinction that only shows up in the log, but its
/// absence is what made the Mac's 2026-07-21 incident hard to diagnose.
shared_pid: i64 = 0,

/// Connections that have been REPLACED but not freed. See `retire`: surfaces
/// borrow `*Connection` and nothing refcounts it, so a connection may only be
/// destroyed once every surface that could still touch it is gone — which is
/// app teardown. Bounded in practice by the number of agent crashes in one app
/// run.
retired: std.ArrayList(tcp_dial.Dialed) = .empty,

/// Threads running `Connection.shutdown` for retired connections (see
/// `retire`). Joined in `deinit` — and ONLY there — because `deinit` is also
/// where `retired` is finally freed, so a teardown must not still be touching a
/// connection when its allocation goes away.
teardowns: std.ArrayList(std.Thread) = .empty,

/// The link-state observer applied to EVERY connection this manager installs as
/// shared (T145). Stored rather than set once, because recovery replaces the
/// connection and the replacement needs watching just as much as the original —
/// a second agent crash must be caught too.
///
/// NOTE for whoever writes the handler: it fires on the connection's reader
/// thread, under `state_mutex`. It must not re-enter `Connection`, and it must
/// not touch GUI state — post a message and return.
state_ctx: ?*anyopaque = null,
state_handler: ?connection.StateHandler = null,

/// Timestamp (ms) of the last find-or-spawn failure, or null. Guards the
/// cooldown so a broken agent falls back to exec immediately.
last_failure_ms: ?i64 = null,

/// True while a find-or-spawn is in flight on the GUI thread (T188). The
/// resolve pumps IPC while it waits, so a request served from inside it can
/// re-enter this manager; that nested caller is answered "no connection" rather
/// than being allowed to start a second agent and overwrite `shared`.
resolving: bool = false,

/// Whether this app run already wrote/refreshed the HKCU Run autostart entry
/// (T89h). Once per run: the value only changes when the install moves.
autostart_done: bool = false,

/// The build stamp of the agent binary THIS app ships beside (T147), learned
/// once by running `<agent exe> --version`. Null means "not knowable" — no
/// binary, or the probe failed — which the policy turns into "never judge the
/// running agent stale". Owned; freed in `deinit`.
bundled_version: ?[]const u8 = null,
bundled_version_probed: bool = false,

/// The last dial that failed because the agent speaks a protocol this build
/// cannot negotiate (T125), or null when the last dial did not fail that way.
///
/// Recorded rather than swallowed because a skewed agent is indistinguishable
/// from a dead one at the call site — both make `dialExisting` return null — and
/// the two need OPPOSITE responses: a dead agent should be replaced by spawning
/// one, while a skewed agent is alive, holding every session, and must not be
/// touched without consent. Cleared by the next dial that succeeds and by a
/// restart, so it always describes the agent that is out there NOW.
protocol_skew: ?Skew = null,

/// What a skewed dial learned. `peer_proto_version` is null when the peer never
/// got as far as a parseable HELLO.
pub const Skew = struct {
    peer_proto_version: ?u16 = null,
};

pub fn init(alloc: Allocator) LocalAgent {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *LocalAgent) void {
    if (self.shared) |*d| d.deinit();
    self.shared = null;
    if (self.bundled_version) |v| self.alloc.free(v);
    self.bundled_version = null;
    // Let every async teardown finish before the allocations it is walking are
    // freed below.
    for (self.teardowns.items) |t| t.join();
    self.teardowns.deinit(self.alloc);
    self.teardowns = .empty;
    // Safe here and ONLY here: `App.terminate` deinits every window (and thus
    // every surface that borrowed one of these) before calling us.
    for (self.retired.items) |*d| d.deinit();
    self.retired.deinit(self.alloc);
    self.retired = .empty;
}

/// Stop using `dialed` as the shared connection without FREEING it (T145).
///
/// `tcp_dial.Dialed.deinit` calls `conn.destroy(alloc)`, but that pointer is
/// borrowed all over: `Surface.remote_conn`, `Window.local_agent_conn`, and the
/// shared `termio.Remote` backend all hold it, and nothing refcounts it. So
/// destroying a replaced connection while any surface still exists is a
/// use-after-free — which is exactly what the pre-T145 dead-connection drop in
/// `sharedConnection` did. Instead we `shutdown` (idempotent; unblocks anyone
/// waiting on it and makes every later send fail cleanly) and keep the
/// allocation alive until app teardown. One live-forever connection per agent
/// crash is a trade we take: liveness beats cleanliness when the alternative is
/// a dangling pointer in the user's terminal.
fn retire(self: *LocalAgent, dialed: tcp_dial.Dialed) void {
    var d = dialed;
    // Stop it observing first: a retired connection's dying transitions are
    // noise, and the watcher would otherwise re-open a settle window on a link
    // nobody is using. `clearStateHandler` returns only once any in-flight
    // handler has finished, so this is also the teardown-safe ordering. Cheap —
    // it is one mutex take.
    d.conn.clearStateHandler();
    self.retired.append(self.alloc, d) catch {
        // Out of memory while retiring: dropping the struct leaks it outright,
        // which is still strictly safer than destroying a borrowed connection.
        log.warn("retired local-agent connection could not be tracked; leaking it", .{});
    };

    // `shutdown` JOINS the connection's writer, control-reader, data-reader and
    // heartbeat threads. Every caller of `retire` is on the GUI THREAD, so a
    // peer thread that does not exit promptly does not slow the app down — it
    // WEDGES it, with no log line and no crash, which is exactly the shape of
    // T229's field failure ("the dialog disappears and nothing comes back").
    //
    // Nothing here needs the join to have happened: a retired connection is
    // deliberately never freed (see the doc comment above), and `deinit` — the
    // one place it IS freed — joins these threads first. So run it off the GUI
    // thread and let the message loop keep pumping.
    const t = std.Thread.spawn(.{}, shutdownRetired, .{d.conn}) catch |err| {
        // Spawn failed: fall back to the blocking teardown. No worse than the
        // behavior this replaced, and said out loud rather than skipped.
        log.warn("retired local-agent connection: async teardown unavailable ({}), shutting down inline", .{err});
        d.conn.shutdown();
        return;
    };
    self.teardowns.append(self.alloc, t) catch {
        // Untracked ⇒ nobody can join it. Detach so the OS reclaims it, and
        // accept that `deinit` will not wait for this one.
        t.detach();
        log.warn("retired local-agent teardown thread could not be tracked; detached", .{});
    };
}

fn shutdownRetired(conn: *connection.Connection) void {
    conn.shutdown();
}

/// Register the link-state observer for the shared connection, now and for
/// every connection that replaces it. Applied immediately when one is already
/// dialed.
pub fn setStateObserver(
    self: *LocalAgent,
    ctx: *anyopaque,
    handler: connection.StateHandler,
) void {
    self.state_ctx = ctx;
    self.state_handler = handler;
    self.applyStateObserver();
}

fn applyStateObserver(self: *LocalAgent) void {
    const ctx = self.state_ctx orelse return;
    const handler = self.state_handler orelse return;
    if (self.shared) |*d| d.conn.setStateHandler(ctx, handler);
}

/// The shared connection's transport link state, or null when there is no
/// shared connection at all. The crash-recovery watcher (T145) samples this;
/// see `agent_recovery.zig` for what a down link is allowed to mean.
pub fn linkState(self: *LocalAgent) ?connection.LinkState.State {
    if (self.shared) |*d| return d.conn.state();
    return null;
}

/// The pid of the agent process the shared connection was dialed against, or 0
/// when unknown / not connected.
pub fn sharedPid(self: *const LocalAgent) i64 {
    return if (self.shared == null) 0 else self.shared_pid;
}

/// The pid of a LIVE agent process as recorded in the info file, or null when
/// there is no info file, no pid, or that pid is not a running process.
///
/// The liveness check is the whole point (Mac gates the same read on
/// `kill(pid, 0)`): a crashed agent leaves its `port.json` behind, so a
/// file-only read would report the dead agent's pid, match it against the pid
/// we had, and conclude "same agent, transport failed" about a process that no
/// longer exists. Deliberately does not dial or spawn — this answers "did the
/// agent restart?" on the deciding tick of a settle window, not "is it well?".
pub fn liveAgentPid(self: *LocalAgent) ?i64 {
    const info = self.readInfoFile() orelse return null;
    if (info.pid <= 0) return null;
    if (!processAlive(info.pid)) return null;
    return info.pid;
}

/// Whether `pid` names a currently-running process. Access-denied counts as
/// ALIVE (the Mac's `errno == EPERM` arm): a process we cannot open is still a
/// process, and reporting it dead would invent an agent restart.
fn processAlive(pid: i64) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (pid <= 0 or pid > std.math.maxInt(u32)) return false;
    const windows = std.os.windows;
    const h = OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION,
        windows.FALSE,
        @intCast(pid),
    ) orelse {
        return windows.kernel32.GetLastError() == .ACCESS_DENIED;
    };
    defer windows.CloseHandle(h);
    // An exited process keeps a queryable handle until the last one closes, so
    // existence is not liveness — the exit code is.
    var code: windows.DWORD = 0;
    if (windows.kernel32.GetExitCodeProcess(h, &code) == 0) return true;
    return code == STILL_ACTIVE;
}

/// Declared here rather than taken from `std.os.windows.kernel32`, which does
/// not export it (`src/remote/agent/proc.zig` does the same).
extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

const PROCESS_QUERY_LIMITED_INFORMATION: std.os.windows.DWORD = 0x1000;
const STILL_ACTIVE: std.os.windows.DWORD = 259;

/// Re-dial the local agent for in-place crash recovery (T145) and install the
/// result as the new shared connection, retiring (never freeing) the old one.
/// Returns the fresh connection, or null when no agent could be reached within
/// the normal find-or-spawn budget — in which case the OLD connection is left
/// in place, because handing the caller nothing to re-ATTACH to is worse than
/// leaving frozen panes pointing at a dead link they can retry later.
///
/// Ignores the failure cooldown: a confirmed drop already waited out the settle
/// window, and recovery is a deliberate user-visible act, not a per-surface
/// fallback.
pub fn reconnectForRecovery(self: *LocalAgent) ?*connection.Connection {
    if (comptime builtin.os.tag != .windows) return null;

    // Same re-entrancy rule as `sharedConnection` (T188): the find-or-spawn
    // below pumps IPC, and a request served from inside it must not start a
    // second agent on top of this one.
    if (self.resolving) {
        log.info("in-place recovery: a local-agent resolve is already in flight", .{});
        return null;
    }
    self.resolving = true;
    defer self.resolving = false;

    const dialed = self.findOrSpawn() orelse {
        self.last_failure_ms = std.time.milliTimestamp();
        log.warn("in-place recovery: no local agent could be reached", .{});
        return null;
    };

    if (self.shared) |old| self.retire(old);
    self.shared = dialed;
    self.shared_pid = if (self.readInfoFile()) |i| i.pid else 0;
    self.last_failure_ms = null;
    self.applyStateObserver();
    log.info("in-place recovery: re-dialed the local agent (pid {d})", .{self.shared_pid});
    return self.shared.?.conn;
}

/// Resolve the shared local-agent connection for a NEW persistent surface,
/// with a bounded wait so `session-persistence` (default-on) can never hang
/// window creation. Returns a BORROWED connection (owned here, valid for the
/// app's lifetime) or null — null ⇒ the caller must open a plain exec surface.
///
/// Runs synchronously on the GUI thread. The common case (a warm cached
/// connection) returns instantly; only the first window after a cold start (or
/// after the agent died) pays the spawn/dial cost, bounded to
/// `spawn_deadline_ms`.
pub fn sharedConnection(self: *LocalAgent) ?*connection.Connection {
    // Windows-only: POSIX uses the Mac LocalAgentManager.
    if (comptime builtin.os.tag != .windows) return null;

    // Fast path: a warm, healthy cached connection — no dial, no wait.
    if (self.shared) |d| {
        if (d.conn.state() != .dead) return d.conn;
        // The cached connection went dead (agent crashed): stop handing it to
        // new surfaces and RETIRE it. It must not be freed here — the surfaces
        // already riding it hold the raw pointer and nothing refcounts it
        // (T145). A fresh resolve below re-dials the respawned agent.
        self.retire(d);
        self.shared = null;
        self.shared_pid = 0;
    }

    // Known-broken recently: fall back to exec now, no probe.
    if (self.last_failure_ms) |last| {
        if (std.time.milliTimestamp() - last < failure_cooldown_ms) return null;
    }

    // T188: `findOrSpawn` now pumps IPC while it waits, so an IPC request served
    // from inside it can land HERE, one frame deep, asking for the very
    // connection this call is still resolving. Re-entering would spawn a SECOND
    // agent and overwrite `self.shared` from under the outer call. There is no
    // usable shared connection at this instant, so the truthful answer is the
    // same one the caller would have gotten a millisecond earlier: none. The
    // pane opens as a plain local shell, exactly as it does whenever the agent
    // is unreachable.
    if (self.resolving) {
        log.info("shared local-agent connection is still resolving; answering none", .{});
        return null;
    }
    self.resolving = true;
    defer self.resolving = false;

    const dialed = self.findOrSpawn() orelse {
        self.last_failure_ms = std.time.milliTimestamp();
        return null;
    };
    self.shared = dialed;
    self.shared_pid = if (self.readInfoFile()) |i| i.pid else 0;
    self.last_failure_ms = null;
    self.applyStateObserver();
    log.info("shared local-agent connection ready (agent pid {d})", .{self.shared_pid});

    // Persistence just engaged: make sure the agent also comes back after a
    // reboot, so sessions rematerialize as relaunchable tombstones (T89h).
    self.ensureAutostart();

    return self.shared.?.conn;
}

// =============================================================================
// Non-destructive agent upgrade (T147)
// =============================================================================

/// The build stamp of the agent binary this app ships beside, or null when it
/// cannot be determined (missing binary, `--version` failed or printed
/// nothing). Probed at most ONCE per app run — the binary can be swapped
/// underneath us mid-run (that is exactly what the upgrade script does), but
/// the app that shipped it is this process, so the stamp it should adopt is the
/// one that was next to it when it started. Cached either way, including the
/// failure, so a broken probe costs one spawn and never repeats.
pub fn bundledVersion(self: *LocalAgent) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    if (self.bundled_version_probed) return self.bundled_version;
    self.bundled_version_probed = true;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Test hook (DEBUG BUILDS ONLY, like `GHOZTTY_AGENT_AUTOSTART=force`):
    // pretend we ship a different build than the one on disk. Every stamp in a
    // real build comes from the same binary the agent runs, so without this the
    // acceptance harness could only ever exercise the "current" arm — there is
    // no way to fabricate an old agent from a new tree. Overrides the INPUT
    // only; the decision and the restart it drives are the shipping ones. Never
    // honored in a release build: a stray env var must not be able to kill a
    // user's agent.
    if (build_config.is_debug) {
        if (std.process.getEnvVarOwned(self.alloc, "GHOZTTY_AGENT_BUNDLED_VERSION")) |v| {
            defer self.alloc.free(v);
            if (v.len > 0) {
                self.bundled_version = self.alloc.dupe(u8, v) catch return null;
                log.warn("bundled agent build OVERRIDDEN to {s} (debug test hook)", .{v});
                return self.bundled_version;
            }
        } else |_| {}
    }

    const exe = self.agentBinary(arena) catch return null;
    std.fs.cwd().access(exe, .{}) catch {
        log.warn("bundled agent binary not found at {s}; upgrade check disabled", .{exe});
        return null;
    };

    // The agent is a GUI-subsystem exe on Windows (no console pops up for the
    // tray daemon), but `--version` still writes to whatever stdout handle it
    // inherits — here, this pipe.
    const result = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ exe, "--version" },
        .max_output_bytes = 4096,
    }) catch |err| {
        log.warn("agent --version probe failed err={}", .{err});
        return null;
    };

    const stamp = agent_upgrade.parseVersionOutput(result.stdout) orelse {
        log.warn("agent --version printed nothing usable; upgrade check disabled", .{});
        return null;
    };
    self.bundled_version = self.alloc.dupe(u8, stamp) catch return null;
    log.info("bundled agent build is {s}", .{self.bundled_version.?});
    return self.bundled_version;
}

/// The build stamp the CONNECTED agent advertised in its HELLO, or null when
/// there is no shared connection or the agent is too old to advertise one
/// (which the policy reads as "pre-versioned", i.e. stale).
pub fn runningVersion(self: *LocalAgent) ?[]const u8 {
    if (self.shared) |*d| {
        if (d.conn.peerBuildVersion()) |v| return v;
    }
    return null;
}

/// Whether a shared connection exists right now (i.e. persistence has actually
/// engaged and there is an agent whose build we can judge).
pub fn hasSharedConnection(self: *const LocalAgent) bool {
    return self.shared != null;
}

/// The cached shared connection if there IS one and it is not dead — never
/// dialing, never spawning. `sharedConnection` is the resolve-or-fall-back
/// entry point for new surfaces; this one is for callers that only want to talk
/// to an agent that already exists (the upgrade check, which must not spawn a
/// fresh agent just to ask whether the running one is old).
pub fn sharedConnectionIfWarm(self: *LocalAgent) ?*connection.Connection {
    if (self.shared) |d| {
        if (d.conn.state() != .dead) return d.conn;
    }
    return null;
}

/// Adopt an agent that came up AFTER a failed resolve (T976): dial the pipe it
/// has since recorded, and install the result as the shared connection.
///
/// Two deliberate differences from `sharedConnection`, both of which exist
/// because the caller is a bounded RETRY on a timer rather than a window being
/// created:
///
///   * **It never spawns.** The launch resolve already issued the spawn; the
///     agent is coming up, not missing. Spawning again on every tick would
///     start a process that the single-instance guard immediately kills, and
///     the poll loop that follows a spawn is exactly the 2s GUI-thread block
///     the retry exists to stop paying.
///   * **It ignores the failure cooldown.** The cooldown (15s) protects window
///     creation from re-blocking on an unspawnable agent — a real concern for
///     a call that spawns and polls, and none at all for a find-only dial that
///     fails the instant no pipe exists. Honouring it here would mean the
///     first ~15s of the retry schedule, which is where the late agent almost
///     always lands, could not see it.
///
/// Returns the shared connection when one is now available (including the
/// already-warm case), or null while no healthy agent answers.
pub fn adoptIfUp(self: *LocalAgent) ?*connection.Connection {
    if (comptime builtin.os.tag != .windows) return null;

    // Warm and healthy: nothing to adopt, and the caller's question ("can I
    // talk to an agent?") is already answered yes.
    if (self.shared) |d| {
        if (d.conn.state() != .dead) return d.conn;
        // Same rule as `sharedConnection`: retire, never free — surfaces still
        // hold the raw pointer.
        self.retire(d);
        self.shared = null;
        self.shared_pid = 0;
    }

    // Same re-entrancy rule as `sharedConnection` (T188): the dial below pumps
    // IPC, and a request served from inside it must not start a second resolve.
    if (self.resolving) return null;
    self.resolving = true;
    defer self.resolving = false;

    gui_pump.pump();
    const dialed = self.dialExisting() orelse return null;
    gui_pump.pump();

    self.shared = dialed;
    self.shared_pid = if (self.readInfoFile()) |i| i.pid else 0;
    self.last_failure_ms = null;
    self.applyStateObserver();
    log.info("adopted the local agent that came up late (agent pid {d})", .{self.shared_pid});

    // Persistence just engaged, exactly as in `sharedConnection`: make sure the
    // agent also comes back after a reboot.
    self.ensureAutostart();

    return self.shared.?.conn;
}

/// Dial the agent that is ALREADY running — never spawning one, and touching
/// none of a manager's shared state. Returns a PROBE connection the caller owns
/// and must `deinit`; null when no healthy agent answered.
///
/// A free function on purpose: it reads the info file and dials, nothing else,
/// so it is safe from a WORKER THREAD. That is what the machine chooser's
/// session roster needs (T318) — browsing a roster must never start a daemon,
/// and it must never block the GUI thread on a dial. Mirrors Mac's
/// `LocalAgentManager.dialExisting` (`LocalAgentManager.swift:348-358`).
pub fn dialProbe(alloc: Allocator) ?tcp_dial.Dialed {
    if (comptime builtin.os.tag != .windows) return null;
    var probe: LocalAgent = .init(alloc);
    return probe.dialExisting();
}

/// Terminate the running local agent and drop our connection to it, so the next
/// resolve spawns the binary now on disk (T147). DESTRUCTIVE: the agent owns
/// every persistent PTY, so its children die with it — the caller MUST have
/// established that this is safe (no live sessions) or user-confirmed.
///
/// Returns true when an agent was actually terminated. The connection is
/// RETIRED, never freed, for the same borrowed-pointer reason as everywhere
/// else in this file.
pub fn restartForUpgrade(self: *LocalAgent) bool {
    if (comptime builtin.os.tag != .windows) return false;

    // A STEP TRAIL, not a result line (T229). The three statements below can
    // each block indefinitely — a `retire` teardown, a `TerminateProcess`, a
    // bounded wait on a dying process — and a hang leaves NO record at all
    // unless the step before it announced itself. The field failure this fixes
    // stopped logging immediately after the confirm, and there was no way to
    // tell which of these it stopped in.
    log.info("agent restart: begin (reading agent info file)", .{});
    const info = self.readInfoFile();
    const pid: i64 = if (info) |i| i.pid else 0;

    // Shut our end down BEFORE the kill: a retired connection fails sends fast
    // instead of blocking the GUI thread on a pipe whose server just died.
    log.info("agent restart: retiring the shared connection (agent pid {d})", .{pid});
    if (self.shared) |old| self.retire(old);
    self.shared = null;
    self.shared_pid = 0;
    // A deliberate restart is not a failure, and the cooldown must not make the
    // very next resolve fall back to exec.
    self.last_failure_ms = null;
    // Whatever skew we recorded belonged to the agent we are about to kill. Its
    // replacement is by definition this build's protocol, and leaving the flag
    // set would make `findOrSpawn` refuse to spawn that replacement.
    self.protocol_skew = null;

    log.info("agent restart: terminating agent pid {d}", .{pid});
    const killed = if (pid > 0) self.terminateAgent(pid) else false;
    if (killed) {
        log.info("terminated local agent pid {d} to adopt the bundled build", .{pid});
    } else {
        log.warn("no local agent process to terminate (pid {d}); the next resolve spawns one", .{pid});
    }
    return killed;
}

/// TerminateProcess + a bounded wait for the process to actually go away, so a
/// respawn can't race the dying agent's still-bound pipe. Best-effort: a
/// process we cannot open (gone already, or access-denied) reports false and
/// the caller carries on — the spawn path re-dials before spawning anyway.
///
/// **The pid is VERIFIED to be the agent before it is killed (T421).** It comes
/// out of `port.json`, so nothing about it is guaranteed to still name the
/// agent: Windows recycles pids and a stale info file outlives its writer. On
/// 2026-08-03 the app died inside this function with no crash record and no
/// further log line — the signature of a clean self-terminate — and an
/// unguarded `TerminateProcess(pid-from-a-file)` is a defect on its own terms
/// whether or not that is what happened. Two gates, cheapest first: never our
/// own pid, and never a pid whose image is not the agent binary.
///
/// Each step announces itself for the same reason the caller's step trail
/// exists: the next occurrence must say WHICH call it stopped in.
fn terminateAgent(self: *LocalAgent, pid: i64) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (pid <= 0 or pid > std.math.maxInt(u32)) return false;
    const windows = std.os.windows;

    if (pid == @as(i64, w32.GetCurrentProcessId())) {
        log.err(
            "agent restart: REFUSING to terminate pid {d} — that is THIS process, " ++
                "not the agent (stale port.json or a recycled pid)",
            .{pid},
        );
        return false;
    }

    const h = OpenProcess(
        PROCESS_TERMINATE | SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
        windows.FALSE,
        @intCast(pid),
    ) orelse {
        log.warn("agent restart: cannot open pid {d} (already gone, or access denied)", .{pid});
        return false;
    };
    defer windows.CloseHandle(h);

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expected: ?[]const u8 = self.agentBinary(arena) catch null;

    if (processImagePath(h, arena)) |image| {
        if (!agent_upgrade.imageIsAgent(image, expected)) {
            log.err(
                "agent restart: REFUSING to terminate pid {d} — its image is '{s}', " ++
                    "which is not the local agent ('{s}', with or without a delivery's " ++
                    "rename suffix)",
                .{ pid, image, agent_upgrade.baseName(expected orelse agent_upgrade.default_agent_image) },
            );
            return false;
        }
        log.info("agent restart: pid {d} verified as '{s}'", .{ pid, image });
    } else {
        // Unverifiable is not the same as wrong. The self-pid gate above still
        // holds, and refusing here would break the refresh on any box where the
        // query is denied — so proceed, out loud.
        log.warn(
            "agent restart: could not read the image path of pid {d}; " ++
                "terminating on the info file's word alone",
            .{pid},
        );
    }

    // THE MEASUREMENT (T426). Four times the app has ended cleanly inside this
    // very call — no WER record, no `terminate returned` line — and the only
    // mechanism consistent with all four is a shared kill-on-close job going
    // down with the process we are about to end. Nobody has ever measured
    // whether that job is shared, because by the time it matters the app is
    // gone. So write it down BEFORE the call, every time: the next occurrence
    // then either names the cause or rules it out, instead of funding another
    // round of hypotheses.
    {
        var line_buf: [256]u8 = undefined;
        log.info("agent restart: job facts before the kill — {s}", .{
            job_object.describe(&line_buf, job_object.probe(@intCast(pid), h)),
        });
    }

    if (windows.kernel32.TerminateProcess(h, 0) == 0) {
        log.warn("TerminateProcess(agent pid {d}) failed err={}", .{ pid, windows.kernel32.GetLastError() });
        return false;
    }
    // The pipe name only frees when the agent's last handle closes; waiting
    // here is what keeps `findOrSpawn` from dialing the corpse.
    const waited = w32.WaitForSingleObject(h, agent_exit_wait_ms);
    log.info("agent restart: pid {d} terminate returned, exit wait={d}", .{ pid, waited });
    return true;
}

/// `QueryFullProcessImageNameW` for an already-open handle, as UTF-8 in
/// `arena`. Null on any failure — the caller treats that as "unverifiable",
/// never as "not the agent".
fn processImagePath(h: std.os.windows.HANDLE, arena: Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    var buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    var len: std.os.windows.DWORD = buf.len;
    if (QueryFullProcessImageNameW(h, 0, &buf, &len) == 0) return null;
    if (len == 0 or len > buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(arena, buf[0..len]) catch null;
}

/// How long to wait for a terminated agent to actually exit. Generous relative
/// to the observed teardown (instant on TerminateProcess) and bounded so the
/// GUI thread can never park here.
const agent_exit_wait_ms: u32 = 3000;

const PROCESS_TERMINATE: std.os.windows.DWORD = 0x0001;
const SYNCHRONIZE: std.os.windows.DWORD = 0x00100000;

/// Declared here for the same reason `OpenProcess` is: `std.os.windows.kernel32`
/// does not export it.
extern "kernel32" fn QueryFullProcessImageNameW(
    hProcess: std.os.windows.HANDLE,
    dwFlags: std.os.windows.DWORD,
    lpExeName: [*]u16,
    lpdwSize: *std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

/// Write/refresh the HKCU Run autostart entry for the local agent (T89h) —
/// the Windows analog of the Mac's per-user LaunchAgent. At sign-in the agent
/// starts, reads `sessions.json`, and materializes each recorded session as a
/// relaunchable tombstone, so the app's launch restore (T89f2/T89g) can bring
/// panes back per `session-relaunch` after a reboot.
///
/// Runs only after persistence actually ENGAGED (a successful agent resolve),
/// once per app run, and refreshes the command in place so the entry tracks
/// the install the user actually runs. Debug builds never write the release
/// entry: they use a lineage-suffixed value name and only under the explicit
/// `GHOZTTY_AGENT_AUTOSTART=force` test hook (mirroring PathInstaller's
/// gating pattern). `GHOZTTY_AGENT_AUTOSTART=0`/`off` disables entirely.
/// Best-effort: a registry failure logs and never affects the session.
fn ensureAutostart(self: *LocalAgent) void {
    if (comptime builtin.os.tag != .windows) return;
    if (self.autostart_done) return;
    self.autostart_done = true;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const gate: ?[]const u8 =
        std.process.getEnvVarOwned(arena, "GHOZTTY_AGENT_AUTOSTART") catch null;
    if (gate) |v| {
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off")) return;
    }
    const force = if (gate) |v| std.ascii.eqlIgnoreCase(v, "force") else false;
    if (build_config.is_debug and !force) return;

    self.writeAutostart(arena) catch |err| {
        log.warn("agent autostart Run-key write failed err={}", .{err});
        return;
    };
    var name_buf: [64]u8 = undefined;
    log.info("agent autostart Run key refreshed ({s})", .{autostartValueName(&name_buf)});
}

/// `GhozttyAgent` for release, `GhozttyAgent-debug` for the debug lineage, plus
/// the `GHOZTTY_AGENT_INSTANCE` suffix when a sandbox set one (T167) — so
/// neither the force-hook test path nor a sandbox can ever clobber the user's
/// real entry. Written into `buf` (>= 64 bytes); the suffix is length-capped
/// by `agent_lineage.max_len`.
fn autostartValueName(buf: []u8) []const u8 {
    const base = if (build_config.is_debug) "GhozttyAgent-debug" else "GhozttyAgent";
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    return agent_lineage.appendSuffix(buf, base, agent_lineage.fromEnv(&sfx_buf)) catch base;
}

fn writeAutostart(self: *LocalAgent, arena: Allocator) !void {
    const cmd = try self.agentCommandLine(arena);

    var key: w32.HKEY = undefined;
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
    );
    if (w32.RegOpenKeyExW(
        w32.HKEY_CURRENT_USER,
        subkey,
        0,
        w32.KEY_SET_VALUE,
        &key,
    ) != w32.ERROR_SUCCESS) return error.RegOpenFailed;
    defer _ = w32.RegCloseKey(key);

    var name_buf: [64]u8 = undefined;
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, autostartValueName(&name_buf));
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, cmd);
    if (w32.RegSetValueExW(
        key,
        name_w,
        0,
        w32.REG_SZ,
        @ptrCast(cmd_w.ptr),
        @intCast((cmd_w.len + 1) * 2),
    ) != w32.ERROR_SUCCESS) return error.RegSetFailed;
}

/// Find an existing agent (dial its recorded pipe) or spawn one and poll until
/// it dials, within `spawn_deadline_ms`. Returns the dialed connection or null.
fn findOrSpawn(self: *LocalAgent) ?tcp_dial.Dialed {
    // 1. Find: dial the agent recorded in port.json, if any. The dial itself is
    //    bounded by `probe_handshake_ns`, and a WEDGED agent spends all of it —
    //    so pump either side of it (T188) and keep the unserviced stretch to one
    //    handshake timeout instead of the whole find-or-spawn budget.
    gui_pump.pump();
    if (self.dialExisting()) |d| return d;
    gui_pump.pump();

    // 1b. A skewed agent is ALIVE and holding the single-instance guard, so the
    //     spawn below cannot succeed: the new process exits immediately and we
    //     spend the whole spawn deadline (seconds, on the GUI thread) polling a
    //     pipe that will keep refusing us. Fail fast instead and let the app take
    //     the mandatory-update path, which is the only thing that can fix this.
    if (self.protocol_skew != null) {
        log.info("not spawning a local agent: the running one is protocol-skewed, not absent", .{});
        return null;
    }

    // 2. Spawn: launch the agent detached, then poll for it to bind + dial.
    const deadline = std.time.milliTimestamp() + spawn_deadline_ms;
    self.spawnAgent() catch |err| {
        log.warn("local agent spawn failed err={}", .{err});
        return null;
    };
    while (std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        // T188: this loop is where the worst measured startup blackout lives —
        // an agent suspended across the relaunch holds the single-instance guard,
        // so every poll fails and we spend the whole deadline here. We are asleep
        // most of that time anyway, so answer the IPC requests piling up behind
        // us instead of making their callers wait for an agent they never asked
        // about. A no-op off the GUI thread and before the app installs the hook.
        gui_pump.pump();
        if (self.dialExisting()) |d| return d;
        // An agent that ANSWERED and disagreed is up; polling it again just
        // re-runs the same handshake to the same conclusion, and every extra
        // second of that is spent blocking the GUI thread. Stop and let the
        // caller take the mandatory-update path.
        if (self.protocol_skew != null) return null;
    }
    log.warn("local agent did not become dialable within {d}ms", .{spawn_deadline_ms});
    return null;
}

/// Dial the agent recorded in the info file, if it looks alive. A stale record
/// (dead agent) fails the dial fast — the pipe name vanishes with the agent's
/// last handle (T89c) — so a failed dial reliably means "no healthy agent".
fn dialExisting(self: *LocalAgent) ?tcp_dial.Dialed {
    const info = self.readInfoFile() orelse return null;
    if (info.pipe_len == 0) return null;
    const pipe = info.pipe_buf[0..info.pipe_len];

    var report: tcp_dial.DialReport = .{};
    const dialed = tcp_dial.dialPipeTimeoutReport(
        self.alloc,
        pipe,
        .raw,
        probe_handshake_ns,
        &report,
    ) catch |err| {
        if (err == error.ProtocolIncompatible) {
            // The agent ANSWERED and we could not agree with it. That is a live
            // process holding live sessions, not a dead one — so it is recorded
            // for `App.refreshLocalAgentIfStale` to act on, and this returns null
            // only because there is no usable connection to hand back.
            self.protocol_skew = .{ .peer_proto_version = report.peer_proto_version };
            log.warn(
                "local agent refused the handshake: protocol skew (agent offers {?d}, this app speaks {d})",
                .{ report.peer_proto_version, protocol.proto_version },
            );
            return null;
        }
        log.debug("dial existing agent failed err={}", .{err});
        return null;
    };
    // A dial we could negotiate is proof the skew (if any) is over.
    self.protocol_skew = null;
    return dialed;
}

/// The protocol skew the last dial hit, or null. Read by the app to decide
/// whether the mandatory-update path applies (T125).
pub fn protocolSkew(self: *const LocalAgent) ?Skew {
    return self.protocol_skew;
}

/// The agent's info file as OWNED, allocation-free data. The pipe name is
/// copied into a fixed buffer rather than handed back as a borrowed slice: the
/// JSON arena has to die with this call, and every caller either dials the pipe
/// immediately or only wants the pid.
const Info = struct {
    pid: i64 = 0,
    pipe_buf: [256]u8 = undefined,
    pipe_len: usize = 0,
};

/// Read + parse `port.json`. Null when absent, unreadable, or not JSON — all of
/// which mean "no agent we can name", never an error worth surfacing.
fn readInfoFile(self: *LocalAgent) ?Info {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const info_path = self.infoFilePath(&buf) catch return null;

    const bytes = std.fs.cwd().readFileAlloc(self.alloc, info_path, 64 * 1024) catch return null;
    defer self.alloc.free(bytes);
    var parsed = std.json.parseFromSlice(InfoFile, self.alloc, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var out: Info = .{ .pid = parsed.value.pid };
    if (parsed.value.pipe) |p| {
        if (p.len > 0 and p.len <= out.pipe_buf.len) {
            @memcpy(out.pipe_buf[0..p.len], p);
            out.pipe_len = p.len;
        }
    }
    return out;
}

/// The agent's `--port-file` body (T89c). A Windows named-pipe agent writes
/// `{"port":0,"pid":P,"pipe":"<name>","startedAt":MS}`; we only need `pipe`.
const InfoFile = struct {
    port: u16 = 0,
    pid: i64 = 0,
    pipe: ?[]const u8 = null,
};

/// Spawn `ghoztty-agent.exe` DETACHED so it outlives the app. Raw
/// CreateProcessW (not std.process.Child, which inherits handles + would keep
/// the caller's pipes open): DETACHED_PROCESS so it has no console attached to
/// us, CREATE_NEW_PROCESS_GROUP so a Ctrl-C to us never reaches it, no handle
/// inheritance. Env is inherited (the single-instance guard is keyed by mode,
/// not env — T89d1 — and the listen-pipe agent never self-updates).
///
/// **And it leaves our JOB OBJECT** (T426, after T524). "Outlives the app" was
/// only ever true of the app EXITING: a child joins its parent's job by
/// default, this box's jobs are kill-on-close, and a job teardown kills every
/// member at once — which is exactly how four relaunch guards died with the app
/// before executing one instruction. A daemon that owns every persistent PTY
/// must not be a member of anything that can kill it on the app's account, and
/// `DETACHED_PROCESS` does not leave a job; only `job_spawn`'s tiers do. This
/// also removes the leading candidate mechanism for the app's own clean death
/// inside `TerminateProcess(agent)`: with no shared job there is no shared job
/// to tear down.
fn spawnAgent(self: *LocalAgent) !void {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const windows = std.os.windows;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Ensure the per-lineage state dir exists (the agent writes port.json /
    // sessions.json / ring snapshots here). CreateProcessW won't create it.
    const dir = try self.agentDir(arena);
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const exe = try self.agentBinary(arena);
    // Fail fast (no spawn) if the binary is missing — the caller records the
    // failure and falls back to exec for the cooldown.
    std.fs.cwd().access(exe, .{}) catch {
        log.warn("local agent binary not found at {s}", .{exe});
        return error.AgentBinaryNotFound;
    };

    const cmd_utf8 = try self.agentCommandLine(arena);
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, cmd_utf8);

    const spawned = job_spawn.spawnEscapingJob(
        arena,
        cmd_w.ptr,
        job_spawn.DETACHED_PROCESS | job_spawn.CREATE_NEW_PROCESS_GROUP,
        "local agent",
    ) catch |err| {
        log.warn("CreateProcessW(ghoztty-agent) failed err={}", .{err});
        return error.SpawnFailed;
    };
    const agent_pid = w32.GetProcessId(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hThread);
    log.info(
        "spawned local agent pid {d} (job escape={s}): {s}",
        .{ agent_pid, spawned.tier.name(), cmd_utf8 },
    );
    if (!spawned.tier.escaped()) {
        // Not fatal — an agent inside our job is better than no agent, and it
        // only dies with us if something tears the job down. But it is the
        // condition T426 exists to remove, so it says so at warn level rather
        // than hiding inside the line above.
        log.warn(
            "local agent pid {d} is INSIDE this app's job object; a job teardown will kill it with us",
            .{agent_pid},
        );
    }
}

/// The full daemon command line — the ONE way this app starts its local
/// agent, used verbatim by both the on-demand spawn and the HKCU Run
/// autostart entry (T89h) so reboot and find-or-spawn can never drift apart.
/// Every token is quoted so a path with spaces (e.g. a roaming profile)
/// survives CreateProcessW's parsing; the values never contain embedded
/// quotes.
fn agentCommandLine(self: *LocalAgent, arena: Allocator) ![]const u8 {
    const exe = try self.agentBinary(arena);
    const dir = try self.agentDir(arena);
    const pipe = try self.pipeName(arena);
    return std.fmt.allocPrint(
        arena,
        "\"{s}\" \"--listen-pipe={s}\" \"--port-file={s}\\port.json\" \"--sessions-file={s}\\sessions.json\"",
        .{ exe, pipe, dir, dir },
    );
}

/// The agent's `sharing.json` path — the per-machine "Share this machine"
/// flag the chooser's toggle writes and the agent's uplink reconciler reads
/// (T546/T547). Resolved with the agent's OWN rules (`sharing.pathFor`: the
/// `GHOSTTY_SHARING_CONFIG` override first, else beside `sessions.json` in
/// the state dir above), so the writer and the reader cannot drift apart.
/// Owned by the caller; null when neither an override nor a state dir exists.
pub fn sharingConfigPath(self: *LocalAgent, alloc: Allocator) ?[]u8 {
    const sharing = @import("../../remote/agent/sharing.zig");
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sessions: ?[]const u8 = blk: {
        const dir = self.agentDir(arena) catch break :blk null;
        break :blk std.fs.path.join(arena, &.{ dir, "sessions.json" }) catch null;
    };
    return sharing.pathFor(alloc, sessions);
}

/// `%LOCALAPPDATA%\ghoztty\local-agent[-debug][-<instance>]` — the per-lineage
/// state dir. Same directory `+sessions` reads (design §T89a decision 2), and
/// the same `GHOZTTY_AGENT_INSTANCE` suffix moves both (T167).
fn agentDir(self: *LocalAgent, arena: Allocator) ![]const u8 {
    const base = if (build_config.is_debug) "local-agent-debug" else "local-agent";
    var sub_buf: [64]u8 = undefined;
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const sub = try agent_lineage.appendSuffix(&sub_buf, base, agent_lineage.fromEnv(&sfx_buf));
    const local = std.process.getEnvVarOwned(self.alloc, "LOCALAPPDATA") catch return error.NoLocalAppData;
    defer self.alloc.free(local);
    return std.fmt.allocPrint(arena, "{s}\\ghoztty\\{s}", .{ local, sub });
}

/// `<agentDir>\port.json`, written into `buf`. The info file `+sessions` and
/// the app both read.
fn infoFilePath(self: *LocalAgent, buf: []u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const dir = try self.agentDir(arena_state.allocator());
    return std.fmt.bufPrint(buf, "{s}\\port.json", .{dir});
}

/// The pipe the local agent binds + advertises:
/// `\\.\pipe\ghoztty-agent[-debug][-<instance>]-<user>` (T89c naming, plus the
/// T167 lineage suffix). User-scoped so two users' agents never collide; the
/// owner-only DACL is the actual gate, and the instance suffix is a NAMING
/// device for test isolation, never a security boundary.
fn pipeName(self: *LocalAgent, arena: Allocator) ![]const u8 {
    const lineage = if (build_config.is_debug) "-debug" else "";
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    // NOT `appendSuffix` here: the lineage part is already written with its
    // leading '-' (it is a fragment of the name, not a segment), so a release
    // build's empty lineage still needs its own separator before the instance.
    const tail = if (agent_lineage.fromEnv(&sfx_buf)) |instance|
        try std.fmt.allocPrint(arena, "{s}-{s}", .{ lineage, instance })
    else
        lineage;
    const user = std.process.getEnvVarOwned(self.alloc, "USERNAME") catch
        try self.alloc.dupe(u8, "user");
    defer self.alloc.free(user);
    // Sanitize the username: pipe path segments can't contain a backslash.
    const clean = try arena.dupe(u8, user);
    for (clean) |*c| {
        if (c.* == '\\' or c.* == '/') c.* = '_';
    }
    return std.fmt.allocPrint(arena, "\\\\.\\pipe\\ghoztty-agent{s}-{s}", .{ tail, clean });
}

/// The agent binary to spawn: `GHOSTTY_LOCAL_AGENT_BIN` override (tests/dev),
/// else `ghoztty-agent.exe` next to our own executable (delivery lands it
/// there — T89h).
fn agentBinary(self: *LocalAgent, arena: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(self.alloc, "GHOSTTY_LOCAL_AGENT_BIN")) |override| {
        defer self.alloc.free(override);
        if (override.len > 0) return arena.dupe(u8, override);
    } else |_| {}
    const exe_dir = try std.fs.selfExeDirPathAlloc(arena);
    return std.fmt.allocPrint(arena, "{s}\\ghoztty-agent.exe", .{exe_dir});
}

test "agentCommandLine quotes every token and pins the daemon flags" {
    // The autostart Run key and the on-demand spawn share this composition
    // (T89h); its shape is load-bearing for both.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var la = LocalAgent.init(std.testing.allocator);
    const cmd = try la.agentCommandLine(arena.allocator());
    try std.testing.expect(cmd.len > 0 and cmd[0] == '"' and cmd[cmd.len - 1] == '"');
    try std.testing.expect(std.mem.indexOf(u8, cmd, "ghoztty-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "\"--listen-pipe=\\\\.\\pipe\\ghoztty-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "\\port.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "\\sessions.json\"") != null);
    // Exactly 4 quoted tokens => 8 quotes; no embedded quoting surprises.
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, cmd, "\""));
}

test "pipeName is a valid pipe path and lineage-suffixed" {
    // Pure-composition smoke test (runs in both lanes). We can't assert the
    // exact username, but the prefix/shape is stable.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var la = LocalAgent.init(std.testing.allocator);
    const name = try la.pipeName(arena.allocator());
    try std.testing.expect(std.mem.startsWith(u8, name, "\\\\.\\pipe\\ghoztty-agent"));
    try std.testing.expect(std.mem.indexOfScalar(u8, name, '-') != null);
}

/// `SetEnvironmentVariableW` — `std.process` has no portable setter, and these
/// tests need the PROCESS environment to change (that is the channel the
/// suffix travels on).
fn setEnvForTest(name: []const u8, value: ?[]const u8) !void {
    if (comptime builtin.os.tag != .windows) return;
    var name_buf: [128]u16 = undefined;
    var value_buf: [128]u16 = undefined;
    const nl = try std.unicode.utf8ToUtf16Le(&name_buf, name);
    name_buf[nl] = 0;
    var val_ptr: ?[*:0]const u16 = null;
    if (value) |v| {
        const vl = try std.unicode.utf8ToUtf16Le(&value_buf, v);
        value_buf[vl] = 0;
        val_ptr = value_buf[0..vl :0].ptr;
    }
    if (w32.SetEnvironmentVariableW(name_buf[0..nl :0].ptr, val_ptr) == 0) return error.SetEnvFailed;
}

test "T167: GHOZTTY_AGENT_INSTANCE forks the dir, the pipe and the autostart value together" {
    // The trap this closes is a HALF-isolated sandbox: private state but a
    // shared guard (or a shared pipe), which comes up with no agent at all and
    // silently exercises the non-persistent path. So all three derivations must
    // move on the one knob, and all three must be unchanged without it.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var la = LocalAgent.init(std.testing.allocator);

    // Baseline: no suffix. Capture what production composes today.
    try setEnvForTest(agent_lineage.env_var, null);
    const base_dir = try la.agentDir(a);
    const base_pipe = try la.pipeName(a);
    var nb: [64]u8 = undefined;
    const base_name = try a.dupe(u8, autostartValueName(&nb));
    try std.testing.expect(!std.mem.endsWith(u8, base_dir, "-sbx1"));
    try std.testing.expect(std.mem.indexOf(u8, base_pipe, "sbx1") == null);

    // With a suffix: every one of the three gains exactly that segment.
    try setEnvForTest(agent_lineage.env_var, "sbx1");
    defer setEnvForTest(agent_lineage.env_var, null) catch {};
    const dir1 = try la.agentDir(a);
    const pipe1 = try la.pipeName(a);
    var nb1: [64]u8 = undefined;
    const name1 = try a.dupe(u8, autostartValueName(&nb1));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}-sbx1", .{base_dir}), dir1);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}-sbx1", .{base_name}), name1);
    // The pipe's suffix lands before the user segment, not after it.
    try std.testing.expect(std.mem.indexOf(u8, pipe1, "-sbx1-") != null);
    try std.testing.expect(!std.mem.eql(u8, base_pipe, pipe1));

    // A second sandbox shares nothing with the first — the coexistence claim.
    try setEnvForTest(agent_lineage.env_var, "sbx2");
    try std.testing.expect(!std.mem.eql(u8, dir1, try la.agentDir(a)));
    try std.testing.expect(!std.mem.eql(u8, pipe1, try la.pipeName(a)));

    // An unusable value (empty) is NOT a lineage: it falls back to the shared
    // names rather than inventing a nameless one.
    try setEnvForTest(agent_lineage.env_var, "");
    try std.testing.expectEqualStrings(base_dir, try la.agentDir(a));
    try std.testing.expectEqualStrings(base_pipe, try la.pipeName(a));
}

test "T167: the spawned agent command line carries the sandbox's own dir and pipe" {
    // The app is what tells the agent where to bind and where to write its
    // state; the env var is what tells the agent which GUARD to take. If the
    // command line did not follow the suffix, a sandbox agent would take its own
    // guard and then fight the box's agent for one pipe name.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var la = LocalAgent.init(std.testing.allocator);

    try setEnvForTest(agent_lineage.env_var, "sbx1");
    defer setEnvForTest(agent_lineage.env_var, null) catch {};
    const cmd = try la.agentCommandLine(a);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-sbx1-") != null); // the pipe
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-sbx1\\port.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "-sbx1\\sessions.json") != null);
    // Still exactly 4 quoted tokens — the suffix must not add an argument.
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, cmd, "\""));
}
