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
const build_config = @import("../../build_config.zig");
const protocol = @import("../../remote/protocol.zig");
const agent_upgrade = @import("agent_upgrade.zig");
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

/// Whether this app run already wrote/refreshed the HKCU Run autostart entry
/// (T89h). Once per run: the value only changes when the install moves.
autostart_done: bool = false,

/// The build stamp of the agent binary THIS app ships beside (T147), learned
/// once by running `<agent exe> --version`. Null means "not knowable" — no
/// binary, or the probe failed — which the policy turns into "never judge the
/// running agent stale". Owned; freed in `deinit`.
bundled_version: ?[]const u8 = null,
bundled_version_probed: bool = false,

pub fn init(alloc: Allocator) LocalAgent {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *LocalAgent) void {
    if (self.shared) |*d| d.deinit();
    self.shared = null;
    if (self.bundled_version) |v| self.alloc.free(v);
    self.bundled_version = null;
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
    // handler has finished, so this is also the teardown-safe ordering.
    d.conn.clearStateHandler();
    d.conn.shutdown();
    self.retired.append(self.alloc, d) catch {
        // Out of memory while retiring: dropping the struct leaks it outright,
        // which is still strictly safer than destroying a borrowed connection.
        log.warn("retired local-agent connection could not be tracked; leaking it", .{});
    };
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

    const info = self.readInfoFile();
    const pid: i64 = if (info) |i| i.pid else 0;

    // Shut our end down BEFORE the kill: a retired connection fails sends fast
    // instead of blocking the GUI thread on a pipe whose server just died.
    if (self.shared) |old| self.retire(old);
    self.shared = null;
    self.shared_pid = 0;
    // A deliberate restart is not a failure, and the cooldown must not make the
    // very next resolve fall back to exec.
    self.last_failure_ms = null;

    const killed = if (pid > 0) terminateProcess(pid) else false;
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
fn terminateProcess(pid: i64) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (pid <= 0 or pid > std.math.maxInt(u32)) return false;
    const windows = std.os.windows;

    const h = OpenProcess(
        PROCESS_TERMINATE | SYNCHRONIZE,
        windows.FALSE,
        @intCast(pid),
    ) orelse return false;
    defer windows.CloseHandle(h);

    if (windows.kernel32.TerminateProcess(h, 0) == 0) {
        log.warn("TerminateProcess(agent pid {d}) failed err={}", .{ pid, windows.kernel32.GetLastError() });
        return false;
    }
    // The pipe name only frees when the agent's last handle closes; waiting
    // here is what keeps `findOrSpawn` from dialing the corpse.
    _ = w32.WaitForSingleObject(h, agent_exit_wait_ms);
    return true;
}

/// How long to wait for a terminated agent to actually exit. Generous relative
/// to the observed teardown (instant on TerminateProcess) and bounded so the
/// GUI thread can never park here.
const agent_exit_wait_ms: u32 = 3000;

const PROCESS_TERMINATE: std.os.windows.DWORD = 0x0001;
const SYNCHRONIZE: std.os.windows.DWORD = 0x00100000;

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
    log.info("agent autostart Run key refreshed ({s})", .{autostartValueName()});
}

/// `GhozttyAgent` for release, `GhozttyAgent-debug` for the debug lineage —
/// so the force-hook test path can never clobber the user's real entry.
fn autostartValueName() []const u8 {
    return if (build_config.is_debug) "GhozttyAgent-debug" else "GhozttyAgent";
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

    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, autostartValueName());
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
    // 1. Find: dial the agent recorded in port.json, if any.
    if (self.dialExisting()) |d| return d;

    // 2. Spawn: launch the agent detached, then poll for it to bind + dial.
    const deadline = std.time.milliTimestamp() + spawn_deadline_ms;
    self.spawnAgent() catch |err| {
        log.warn("local agent spawn failed err={}", .{err});
        return null;
    };
    while (std.time.milliTimestamp() < deadline) {
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        if (self.dialExisting()) |d| return d;
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

    return tcp_dial.dialPipeTimeout(self.alloc, pipe, .raw, probe_handshake_ns) catch |err| {
        log.debug("dial existing agent failed err={}", .{err});
        return null;
    };
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

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        windows.FALSE, // no handle inheritance
        .{ .detached_process = true, .create_new_process_group = true },
        null,
        null,
        &si,
        &pi,
    ) == 0) {
        log.warn("CreateProcessW(ghoztty-agent) failed err={}", .{windows.kernel32.GetLastError()});
        return error.SpawnFailed;
    }
    windows.CloseHandle(pi.hProcess);
    windows.CloseHandle(pi.hThread);
    log.info("spawned local agent: {s}", .{cmd_utf8});
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

/// `%LOCALAPPDATA%\ghoztty\local-agent[-debug]` — the per-lineage state dir.
/// Same directory `+sessions` reads (design §T89a decision 2).
fn agentDir(self: *LocalAgent, arena: Allocator) ![]const u8 {
    const sub = if (build_config.is_debug) "local-agent-debug" else "local-agent";
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
/// `\\.\pipe\ghoztty-agent[-debug]-<user>` (T89c naming). User-scoped so two
/// users' agents never collide; the owner-only DACL is the actual gate.
fn pipeName(self: *LocalAgent, arena: Allocator) ![]const u8 {
    const suffix = if (build_config.is_debug) "-debug" else "";
    const user = std.process.getEnvVarOwned(self.alloc, "USERNAME") catch
        try self.alloc.dupe(u8, "user");
    defer self.alloc.free(user);
    // Sanitize the username: pipe path segments can't contain a backslash.
    const clean = try arena.dupe(u8, user);
    for (clean) |*c| {
        if (c.* == '\\' or c.* == '/') c.* = '_';
    }
    return std.fmt.allocPrint(arena, "\\\\.\\pipe\\ghoztty-agent{s}-{s}", .{ suffix, clean });
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
