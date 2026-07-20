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

/// Timestamp (ms) of the last find-or-spawn failure, or null. Guards the
/// cooldown so a broken agent falls back to exec immediately.
last_failure_ms: ?i64 = null,

/// Whether this app run already wrote/refreshed the HKCU Run autostart entry
/// (T89h). Once per run: the value only changes when the install moves.
autostart_done: bool = false,

pub fn init(alloc: Allocator) LocalAgent {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *LocalAgent) void {
    if (self.shared) |*d| d.deinit();
    self.shared = null;
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
    if (self.shared) |*d| {
        if (d.conn.state() != .dead) return d.conn;
        // The cached connection went dead (agent crashed): drop it. Surfaces
        // still riding it keep their own reference alive via the core; a fresh
        // resolve re-dials the (respawned) agent.
        d.deinit();
        self.shared = null;
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
    self.last_failure_ms = null;
    log.info("shared local-agent connection ready", .{});

    // Persistence just engaged: make sure the agent also comes back after a
    // reboot, so sessions rematerialize as relaunchable tombstones (T89h).
    self.ensureAutostart();

    return self.shared.?.conn;
}

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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const info_path = self.infoFilePath(&buf) catch return null;

    const bytes = std.fs.cwd().readFileAlloc(self.alloc, info_path, 64 * 1024) catch return null;
    defer self.alloc.free(bytes);
    var parsed = std.json.parseFromSlice(InfoFile, self.alloc, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const pipe = parsed.value.pipe orelse return null;
    if (pipe.len == 0) return null;

    return tcp_dial.dialPipeTimeout(self.alloc, pipe, .raw, probe_handshake_ns) catch |err| {
        log.debug("dial existing agent failed err={}", .{err});
        return null;
    };
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
