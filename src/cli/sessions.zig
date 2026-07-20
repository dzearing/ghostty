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

/// How long to wait for the agent's SESSIONS reply before giving up. Generous:
/// the roster is a pure in-memory snapshot, but a wedged agent must not hang the
/// CLI forever.
const list_timeout_ns: u64 = 5 * std.time.ns_per_s;

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Output machine-readable JSON instead of the human-readable table.
    json: bool = false,

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
/// Each row reports: the session id, liveness (`alive` or `dead` with its exit
/// code), whether a viewer is currently `attached`, the activity state
/// (idle/busy/needs_input), the child pid, the working directory, and the command.
///
/// Flags:
///
///   * `--json`: Output as JSON instead of the human-readable table.
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
        try stderr.print("+sessions: could not resolve the home directory.\n", .{});
        return 1;
    };

    const info = readInfoFile(alloc, info_path) catch {
        try stderr.print(
            "+sessions: no local agent found (session persistence is off, or the agent is not running).\n",
            .{},
        );
        return 1;
    };

    // Dial the agent: prefer the UDS `socket`, fall back to a legacy TCP `port`.
    var dialed = dialAgent(alloc, info) catch |err| {
        try stderr.print("+sessions: could not connect to the local agent: {s}.\n", .{@errorName(err)});
        return 1;
    };
    defer dialed.deinit();

    var roster = dialed.conn.requestSessions(list_timeout_ns) catch |err| {
        try stderr.print("+sessions: the agent did not answer: {s}.\n", .{@errorName(err)});
        return 1;
    };
    defer roster.deinit();

    if (opts.json) {
        try printJson(alloc, stdout, roster.sessions);
    } else {
        try printTable(stdout, roster.sessions);
    }
    return 0;
}

/// `~/.config/ghoztty/local-agent[-debug]/port.json` — the same path
/// `LocalAgentManager` writes (debug lineage gets its own directory so debug and
/// release agents never share state). On Windows the local agent's state dir is
/// `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\` instead (T89a decision 2).
fn agentInfoPath(alloc: Allocator) ![]const u8 {
    const dir = if (build_config.is_debug) "local-agent-debug" else "local-agent";
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
        // Liveness column: "alive" or "dead(<code>)".
        try stdout.print("{s}  ", .{s.id});
        if (s.alive) {
            try stdout.writeAll("alive");
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
        };
    }
    const json = try std.json.Stringify.valueAlloc(alloc, rows, .{ .whitespace = .indent_2 });
    try stdout.writeAll(json);
    try stdout.writeAll("\n");
}
