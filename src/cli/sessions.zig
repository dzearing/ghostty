const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const build_config = @import("../build_config.zig");
const homedir = @import("../os/homedir.zig");
const tcp_dial = @import("../remote/tcp_dial.zig");
const connection = @import("../remote/connection.zig");
const agent_lineage = @import("../remote/agent_lineage.zig");
const agent_build = @import("../remote/agent_build.zig");

/// How long to wait for the agent's SESSIONS reply before giving up. Generous:
/// the roster is a pure in-memory snapshot, but a wedged agent must not hang the
/// CLI forever.
const list_timeout_ns: u64 = 5 * std.time.ns_per_s;

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Output machine-readable JSON instead of the human-readable table.
    json: bool = false,

    /// Report the RUNNING agent's build next to the bundled one instead of
    /// listing sessions (T662).
    agent: bool = false,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The agent's `--port-file` info body (written by `runListenUnix`/
/// `runListenPipe`/`runListen`). A UDS agent writes
/// `{"port":0,"pid":P,"socket":"<path>",...}`; a Windows named-pipe agent
/// writes `{"port":0,"pid":P,"pipe":"<name>",...}` (T89c); a legacy TCP agent
/// omits both and sets a real `port`. Unknown fields (e.g. `startedAt`) are
/// ignored — both endpoint fields are additive per the agent-contract rules.
const InfoFile = struct {
    port: u16 = 0,
    pid: i64 = 0,
    socket: ?[]const u8 = null,
    pipe: ?[]const u8 = null,
};

/// List the terminal sessions owned by the local `ghoztty-agent` (the daemon that
/// keeps session-persistence PTYs alive across app restarts). Dials the agent
/// directly over its 0600 unix socket — NOT the app's IPC socket — so it works
/// even when the Ghoztty app is not running (as long as the agent is).
///
/// By default, prints a human-readable table. Use `--json` for a machine-readable
/// array (one object per session) for scripts and AI agents.
///
/// Each row reports: the session id, liveness (`alive`, `dead(relaunchable)`
/// for a tombstone RELAUNCH can revive, or `dead` with its exit code),
/// whether a viewer is currently `attached`, the activity state
/// (idle/busy/needs_input), the child pid, the working directory, and the command.
///
/// Flags:
///
///   * `--json`: Output as JSON instead of the human-readable table.
///
///   * `--agent`: Report the RUNNING agent's build stamp next to the one this
///     CLI ships beside, plus how far behind it is, instead of listing
///     sessions. The agent outlives the app on purpose, so it is routinely a
///     different build than everything around it; this is how you find out
///     WHICH build without reading app logs, and it works with the app closed.
///     Never an error: no agent running is an answer (`not_running`), not a
///     failure.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stdout, stderr);
    stdout.flush() catch {};
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    if (try args.reportCliDiagnostics(Options, &opts, "+sessions", null, stderr)) return 1;

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    // The agent `Connection` we dial below spawns reader/writer/heartbeat threads
    // that allocate through the allocator we hand it — concurrently with THIS
    // thread's own allocations (requestSessions duping the roster, printJson/
    // printTable, teardown). A bare `ArenaAllocator` is NOT thread-safe, so
    // sharing it across those threads corrupts the arena's bookkeeping and yields
    // a wild read/write (an `undefined`-poisoned `0xaa…` pointer) inside
    // `rpcCall` / `failPendingRpcs` — an intermittent SIGSEGV/SIGBUS in short-lived
    // CLI runs. Funnel EVERY allocation for this command through one
    // `ThreadSafeAllocator` over the arena so all of them are serialized. (We keep
    // the arena for free-all-at-once; the mutex only guards the bookkeeping.)
    var tsa: std.heap.ThreadSafeAllocator = .{ .child_allocator = arena.allocator() };
    const alloc = tsa.allocator();

    // Locate the local agent's info file and read what to dial.
    const info_path = agentInfoPath(alloc) catch {
        if (opts.agent) return reportAgentBuild(alloc, stdout, opts.json, null, null);
        try stderr.print("+sessions: could not resolve the home directory.\n", .{});
        return 1;
    };

    const info = readInfoFile(alloc, info_path) catch {
        // `--agent` treats "no agent" as a state to report, not an error: it is
        // the answer to "how far behind is it?" (nothing is), and it is the
        // normal shape on a box where persistence has never engaged.
        if (opts.agent) return reportAgentBuild(alloc, stdout, opts.json, null, null);
        try stderr.print(
            "+sessions: no local agent found (session persistence is off, or the agent is not running).\n",
            .{},
        );
        return 1;
    };

    // Dial the agent: prefer the UDS `socket`, fall back to a legacy TCP `port`.
    var dialed = dialAgent(alloc, info) catch |err| {
        // A `port.json` whose agent is gone is the same state as no file at all
        // — a stale info file outlives its writer routinely.
        if (opts.agent) return reportAgentBuild(alloc, stdout, opts.json, null, null);
        try stderr.print("+sessions: could not connect to the local agent: {s}.\n", .{@errorName(err)});
        return 1;
    };
    defer dialed.deinit();

    var roster = dialed.conn.requestSessions(list_timeout_ns) catch |err| {
        // We reached the agent, so its build IS knowable even though the roster
        // is not — and a wedged agent is exactly when someone asks which build
        // it is. Report what we have rather than throwing the answer away.
        if (opts.agent) return reportAgentBuild(alloc, stdout, opts.json, &dialed, info.pid);
        try stderr.print("+sessions: the agent did not answer: {s}.\n", .{@errorName(err)});
        return 1;
    };
    defer roster.deinit();

    if (opts.agent) {
        return reportAgentBuildWithRoster(
            alloc,
            stdout,
            opts.json,
            &dialed,
            info.pid,
            roster.sessions,
        );
    }

    if (opts.json) {
        try printJson(alloc, stdout, roster.sessions);
    } else {
        try printTable(stdout, roster.sessions);
    }
    return 0;
}

// =============================================================================
// `--agent`: which build is actually running (T662)
// =============================================================================

/// One JSON object for `--agent --json`. A dedicated struct so the keys are a
/// stable contract; `status` is the machine token from `agent_build.Status`,
/// never the human sentence beside it.
const AgentJson = struct {
    status: []const u8,
    running: ?[]const u8,
    bundled: ?[]const u8,
    days_behind: ?i64,
    live_sessions: ?u32,
    sessions: ?u32,
    agent_pid: ?i64,
};

fn reportAgentBuild(
    alloc: Allocator,
    stdout: *std.Io.Writer,
    json: bool,
    dialed: ?*tcp_dial.Dialed,
    pid: ?i64,
) !u8 {
    return emitAgentReport(alloc, stdout, json, .{
        .agent_running = dialed != null,
        .running = if (dialed) |d| peerStamp(d) else null,
        .bundled = bundledAgentVersion(alloc),
        .agent_pid = if (dialed != null) pid else null,
    });
}

fn reportAgentBuildWithRoster(
    alloc: Allocator,
    stdout: *std.Io.Writer,
    json: bool,
    dialed: *tcp_dial.Dialed,
    pid: i64,
    sessions: []const connection.OwnedSession,
) !u8 {
    var live: u32 = 0;
    for (sessions) |s| if (s.alive) {
        live += 1;
    };
    return emitAgentReport(alloc, stdout, json, .{
        .agent_running = true,
        .running = peerStamp(dialed),
        .bundled = bundledAgentVersion(alloc),
        .live_sessions = live,
        .total_sessions = @intCast(sessions.len),
        .agent_pid = pid,
    });
}

fn emitAgentReport(
    alloc: Allocator,
    stdout: *std.Io.Writer,
    json: bool,
    in: agent_build.Input,
) !u8 {
    const rep = agent_build.report(in);
    if (!json) {
        try rep.write(stdout);
        return 0;
    }
    const row: AgentJson = .{
        .status = rep.status.token(),
        .running = rep.running,
        .bundled = rep.bundled,
        .days_behind = rep.days_behind,
        .live_sessions = rep.live_sessions,
        .sessions = rep.total_sessions,
        .agent_pid = rep.agent_pid,
    };
    const text = try std.json.Stringify.valueAlloc(alloc, row, .{ .whitespace = .indent_2 });
    try stdout.writeAll(text);
    try stdout.writeAll("\n");
    return 0;
}

/// The stamp the connected agent advertised in its HELLO, widened from the
/// sentinel-terminated wire string. Null for an agent too old to advertise one,
/// which the report reads as pre-versioned (and therefore stale).
fn peerStamp(dialed: *tcp_dial.Dialed) ?[]const u8 {
    const v = dialed.conn.peerBuildVersion() orelse return null;
    return v;
}

/// The build stamp of the `ghoztty-agent` binary sitting beside this CLI, by
/// running its `--version` — the same probe the app makes (`LocalAgent
/// .bundledVersion`), from the one process that is guaranteed to exist when
/// someone asks the question.
///
/// Null on any failure at all (no binary, spawn refused, nothing printed): the
/// bundled side being unknown is a REPORTABLE state (`unknown`), never an error
/// and never a guess. Honors `GHOSTTY_LOCAL_AGENT_BIN` so a dev tree or a test
/// sandbox reports the agent it would actually spawn.
fn bundledAgentVersion(alloc: Allocator) ?[]const u8 {
    // The same DEBUG-ONLY test hook the app's probe honors
    // (`LocalAgent.bundledVersion`), deliberately spelled with the same name:
    // every stamp in a real tree comes from the one binary, so without it an
    // acceptance script could only ever reach the `current` arm — there is no
    // way to fabricate an old agent from a new tree. Never honored in a release
    // build, where a stray env var must not be able to misreport a user's box.
    if (build_config.is_debug) {
        if (std.process.getEnvVarOwned(alloc, "GHOZTTY_AGENT_BUNDLED_VERSION")) |v| {
            if (v.len > 0) return v;
        } else |_| {}
    }

    const exe = agentBinaryPath(alloc) catch return null;
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ exe, "--version" },
        .max_output_bytes = 4096,
    }) catch return null;
    return agent_build.parseVersionOutput(result.stdout);
}

fn agentBinaryPath(alloc: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_LOCAL_AGENT_BIN")) |override| {
        if (override.len > 0) return override;
    } else |_| {}
    const exe_dir = try std.fs.selfExeDirPathAlloc(alloc);
    const name = if (comptime builtin.os.tag == .windows) "ghoztty-agent.exe" else "ghoztty-agent";
    const sep = if (comptime builtin.os.tag == .windows) "\\" else "/";
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ exe_dir, sep, name });
}

/// `~/.config/ghoztty/local-agent[-debug]/port.json` — the same path
/// `LocalAgentManager` writes (debug lineage gets its own directory so debug and
/// release agents never share state). On Windows the local agent's state dir is
/// `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\` instead (T89a decision 2).
///
/// A `GHOZTTY_AGENT_INSTANCE` suffix appends one more segment (T167), so
/// `+sessions` run inside a test sandbox reads THAT sandbox's agent rather than
/// the box's. Unset — every production run — leaves the path unchanged.
fn agentInfoPath(alloc: Allocator) ![]const u8 {
    const base = if (build_config.is_debug) "local-agent-debug" else "local-agent";
    var dir_buf: [64]u8 = undefined;
    var sfx_buf: [agent_lineage.max_len]u8 = undefined;
    const dir = try agent_lineage.appendSuffix(&dir_buf, base, agent_lineage.fromEnv(&sfx_buf));
    if (comptime builtin.os.tag == .windows) {
        const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return error.NoHome;
        defer alloc.free(local);
        return std.fmt.allocPrint(alloc, "{s}\\ghoztty\\{s}\\port.json", .{ local, dir });
    }
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try homedir.home(&home_buf)) orelse return error.NoHome;
    return std.fmt.allocPrint(alloc, "{s}/.config/ghoztty/{s}/port.json", .{ home, dir });
}

fn readInfoFile(alloc: Allocator, path: []const u8) !InfoFile {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024);
    var parsed = try std.json.parseFromSlice(InfoFile, alloc, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    // Return a copy whose `socket`/`pipe` strings live in the arena (parsed
    // owns its own).
    return .{
        .port = parsed.value.port,
        .pid = parsed.value.pid,
        .socket = if (parsed.value.socket) |s| try alloc.dupe(u8, s) else null,
        .pipe = if (parsed.value.pipe) |p| try alloc.dupe(u8, p) else null,
    };
}

fn dialAgent(alloc: Allocator, info: InfoFile) !tcp_dial.Dialed {
    // Windows named pipe (T89c) — the local agent's endpoint on Windows.
    if (info.pipe) |name| {
        if (name.len > 0) return tcp_dial.dialPipe(alloc, name, .raw);
    }
    if (info.socket) |sock| {
        if (sock.len > 0) return tcp_dial.dialUnix(alloc, sock, .raw);
    }
    if (info.port > 0) return tcp_dial.dial(alloc, "127.0.0.1", info.port, .raw);
    return error.NoAgentEndpoint;
}

fn printTable(stdout: *std.Io.Writer, sessions: []const connection.OwnedSession) !void {
    if (sessions.len == 0) {
        try stdout.writeAll("No sessions.\n");
        return;
    }
    for (sessions) |s| {
        // Liveness column: "alive", "dead(relaunchable)", "dead(<code>)", or
        // bare "dead". A relaunchable reboot-floor tombstone has
        // `alive == false` and no exit code — exactly what a genuinely dead
        // session without a recorded code looks like — so without the marker
        // the one command that works with the app closed answers "dead" for a
        // session that RELAUNCH can revive (T324).
        try stdout.print("{s}  ", .{s.id});
        if (s.alive) {
            try stdout.writeAll("alive");
        } else if (s.relaunchable) {
            try stdout.writeAll("dead(relaunchable)");
        } else if (s.exit_code) |code| {
            try stdout.print("dead({d})", .{code});
        } else {
            try stdout.writeAll("dead");
        }
        try stdout.print(
            "  {s}  {s}  pid={d}",
            .{ if (s.attached) "attached" else "detached", s.activity, s.pid },
        );
        if (s.pinned) try stdout.writeAll("  pinned");
        if (s.cwd) |c| try stdout.print("  cwd={s}", .{c});
        if (s.argv) |a| try stdout.print("  cmd={s}", .{a});
        if (s.title) |t| try stdout.print("  title={s}", .{t});
        try stdout.writeAll("\n");
    }
}

/// One JSON row. A dedicated struct (rather than re-using the wire `SessionInfo`)
/// so the output keys are stable and every field is emitted, including nulls, for
/// predictable script parsing.
const JsonRow = struct {
    id: []const u8,
    alive: bool,
    exit_code: ?i64,
    attached: bool,
    activity: []const u8,
    pid: i64,
    cwd: ?[]const u8,
    argv: ?[]const u8,
    title: ?[]const u8,
    created_at: i64,
    last_activity: i64,
    pinned: bool,
    /// True for a relaunchable reboot-floor tombstone (`alive == false`, but the
    /// recorded argv/cwd can revive it via RELAUNCH). Emitted so a consumer can
    /// tell a resumable tombstone from a genuinely-exited one; an older reader
    /// that does not know the key ignores it (additive, no protocol bump — T322).
    relaunchable: bool,
};

fn printJson(alloc: Allocator, stdout: *std.Io.Writer, sessions: []const connection.OwnedSession) !void {
    var rows = try alloc.alloc(JsonRow, sessions.len);
    for (sessions, 0..) |s, i| {
        rows[i] = .{
            .id = s.id,
            .alive = s.alive,
            .exit_code = s.exit_code,
            .attached = s.attached,
            .activity = s.activity,
            .pid = s.pid,
            .cwd = s.cwd,
            .argv = s.argv,
            .title = s.title,
            .created_at = s.created_at,
            .last_activity = s.last_activity,
            .pinned = s.pinned,
            .relaunchable = s.relaunchable,
        };
    }
    const json = try std.json.Stringify.valueAlloc(alloc, rows, .{ .whitespace = .indent_2 });
    try stdout.writeAll(json);
    try stdout.writeAll("\n");
}

test "printTable distinguishes a relaunchable tombstone from a genuinely dead session" {
    // Both rows are `alive == false` with no exit code — identical to the
    // liveness column before T324, which printed bare "dead" for each. The
    // relaunchable one must read as recoverable.
    const testing = std.testing;
    const alloc = testing.allocator;

    const sessions = [_]connection.OwnedSession{
        .{
            .id = "aaaa",
            .alive = false,
            .exit_code = null,
            .attached = false,
            .activity = "idle",
            .pid = 0,
            .title = null,
            .cwd = null,
            .argv = null,
            .created_at = 1,
            .last_activity = 2,
            .pinned = false,
            .relaunchable = true,
        },
        .{
            .id = "bbbb",
            .alive = false,
            .exit_code = null,
            .attached = false,
            .activity = "idle",
            .pid = 0,
            .title = null,
            .cwd = null,
            .argv = null,
            .created_at = 3,
            .last_activity = 4,
            .pinned = false,
            .relaunchable = false,
        },
        .{
            .id = "cccc",
            .alive = false,
            .exit_code = 1,
            .attached = false,
            .activity = "idle",
            .pid = 0,
            .title = null,
            .cwd = null,
            .argv = null,
            .created_at = 5,
            .last_activity = 6,
            .pinned = false,
            .relaunchable = false,
        },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try printTable(&out.writer, &sessions);

    const text = out.written();
    var lines = std.mem.splitScalar(u8, text, '\n');
    const row_a = lines.next().?;
    const row_b = lines.next().?;
    const row_c = lines.next().?;

    try testing.expect(std.mem.indexOf(u8, row_a, "dead(relaunchable)") != null);
    try testing.expect(std.mem.indexOf(u8, row_b, "dead(relaunchable)") == null);
    try testing.expect(std.mem.indexOf(u8, row_b, "dead") != null);
    try testing.expect(std.mem.indexOf(u8, row_c, "dead(1)") != null);
}

test "printJson emits relaunchable for a reboot-floor tombstone" {
    // A relaunchable tombstone is dead-but-resumable: the row has to carry the
    // flag, because `alive` alone cannot distinguish it from a genuinely-exited
    // child and every consumer's "is this connectable?" test is
    // `alive || relaunchable` (T322).
    const testing = std.testing;
    const alloc = testing.allocator;

    const sessions = [_]connection.OwnedSession{
        .{
            .id = "aaaa",
            .alive = false,
            .exit_code = null,
            .attached = false,
            .activity = "idle",
            .pid = 0,
            .title = null,
            .cwd = "/tmp",
            .argv = "zsh",
            .created_at = 1,
            .last_activity = 2,
            .pinned = false,
            .relaunchable = true,
        },
        .{
            .id = "bbbb",
            .alive = true,
            .exit_code = null,
            .attached = true,
            .activity = "busy",
            .pid = 42,
            .title = null,
            .cwd = null,
            .argv = null,
            .created_at = 3,
            .last_activity = 4,
            .pinned = true,
            .relaunchable = false,
        },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var arena: ArenaAllocator = .init(alloc);
    defer arena.deinit();
    try printJson(arena.allocator(), &out.writer, &sessions);

    const json = out.written();
    const parsed = try std.json.parseFromSlice([]struct {
        id: []const u8,
        relaunchable: bool,
    }, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    try testing.expect(parsed.value[0].relaunchable);
    try testing.expect(!parsed.value[1].relaunchable);
}
