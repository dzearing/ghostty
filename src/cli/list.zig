const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    json: bool = false,

    tty: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// List all open windows, tabs, and panes in a running Ghoztty instance.
///
/// By default, outputs a human-readable tree view. Use `--json` to output
/// machine-readable JSON for programmatic use by AI agents and scripts.
///
/// Flags:
///
///   * `--json`: Output as JSON instead of human-readable tree view.
///
///   * `--tty=<tty>`: Print only the registered name of the pane whose
///     terminal matches the given tty (`ttys014` or `/dev/ttys014`),
///     then exit. Exits 1 if no pane matches. Listing auto-registers
///     every pane, so the printed name is immediately usable as a
///     `--target`/`--name` for other commands.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
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
    const alloc = arena.allocator();

    const resp_body = sendListQuery(alloc, stderr) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("No running Ghoztty instance found.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("IPC query failed: {}\n", .{err});
            return 1;
        },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (opts.tty) |tty| {
        const name = findPaneNameByTty(alloc, resp_body, tty) catch {
            try stderr.print("Failed to parse list response\n", .{});
            return 1;
        } orelse {
            try stderr.print("No pane found for tty {s}\n", .{tty});
            return 1;
        };
        stdout.writeAll(name) catch return 1;
        stdout.writeAll("\n") catch return 1;
        stdout.flush() catch return 1;
        return 0;
    }

    if (opts.json) {
        stdout.writeAll(resp_body) catch return 1;
        stdout.writeAll("\n") catch return 1;
    } else {
        formatHumanReadable(alloc, resp_body, stdout) catch {
            try stderr.print("Failed to format response\n", .{});
            return 1;
        };
    }
    stdout.flush() catch return 1;

    return 0;
}

fn sendListQuery(
    alloc: Allocator,
    stderr: *std.Io.Writer,
) ![]const u8 {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const uid = std.c.getuid();
    const build_config = @import("../build_config.zig");
    const suffix = if (build_config.is_debug) "-debug" else "";
    const sock_path = try std.fmt.allocPrintSentinel(alloc, "{s}ghostty{s}-{d}.sock", .{
        tmpdir, suffix, uid,
    }, 0);
    defer alloc.free(sock_path);

    const fd = connectUnixSocket(sock_path) catch {
        return error.NoRunningInstance;
    };
    defer std.posix.close(fd);

    const json_payload = "{\"action\":\"list\"}";
    const len: u32 = @intCast(json_payload.len);
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, len));
    _ = std.posix.write(fd, &len_bytes) catch |err| {
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    _ = std.posix.write(fd, json_payload) catch |err| {
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    var resp_len_bytes: [4]u8 = undefined;
    readFull(fd, &resp_len_bytes) catch {
        stderr.print("Failed to read IPC response length\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
    if (resp_len == 0 or resp_len > 4_194_304) {
        stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    }

    const resp_buf = try alloc.alloc(u8, resp_len);

    readFull(fd, resp_buf) catch {
        stderr.print("Failed to read IPC response\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    // Verify the response has success:true
    const parsed = std.json.parseFromSlice(
        struct { success: bool = false },
        alloc,
        resp_buf,
        .{ .ignore_unknown_fields = true },
    ) catch {
        stderr.print("IPC response is not valid JSON\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    defer parsed.deinit();

    if (!parsed.value.success) {
        stderr.print("IPC request failed\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    }

    return resp_buf;
}

/// Find the registered name of the pane whose terminal tty matches
/// `tty` (compared with the `/dev/` prefix stripped from both sides).
/// Returns null if no pane matches or the matching pane has no name.
fn findPaneNameByTty(alloc: Allocator, resp_body: []const u8, tty_raw: []const u8) !?[]const u8 {
    // Trim so raw `ps -o tty=` output (padded) works as-is.
    const tty = std.mem.trim(u8, tty_raw, " \t\r\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{});
    // Leaks into the arena intentionally: the returned name slice points
    // into the parsed JSON, so it must outlive this function.

    const data_val = parsed.value.object.get("data") orelse return null;
    const windows = (data_val.object.get("windows") orelse return null).array;
    for (windows.items) |window| {
        const tabs = (window.object.get("tabs") orelse continue).array;
        for (tabs.items) |tab| {
            const splits = tab.object.get("splits") orelse continue;
            const leaves = try collectLeaves(alloc, splits);
            for (leaves) |leaf| {
                if (leaf != .object) continue;
                const term_tty = jsonStr(leaf.object.get("tty"));
                if (!std.mem.eql(u8, stripDev(term_tty), stripDev(tty))) continue;
                const name = jsonStr(leaf.object.get("name"));
                return if (name.len > 0) name else null;
            }
        }
    }
    return null;
}

fn stripDev(tty: []const u8) []const u8 {
    if (std.mem.startsWith(u8, tty, "/dev/")) return tty["/dev/".len..];
    return tty;
}

fn formatHumanReadable(alloc: Allocator, resp_body: []const u8, stdout: *std.Io.Writer) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const data_val = root.object.get("data") orelse return;

    const windows = (data_val.object.get("windows") orelse return).array;
    if (windows.items.len == 0) {
        try stdout.writeAll("No windows open.\n");
        return;
    }

    for (windows.items) |window| {
        const win_obj = window.object;
        const win_title = jsonStr(win_obj.get("title"));
        const win_focused = jsonBool(win_obj.get("focused"));

        try stdout.writeAll("Window: \"");
        try stdout.writeAll(win_title);
        try stdout.writeAll("\"");

        if (win_obj.get("target")) |target| {
            if (target != .null) {
                try stdout.writeAll(" [target: ");
                try stdout.writeAll(jsonStr(target));
                try stdout.writeAll("]");
            }
        }

        if (win_focused) {
            try stdout.writeAll(" (focused)");
        }
        try stdout.writeAll("\n");

        const tabs = (win_obj.get("tabs") orelse continue).array;
        for (tabs.items) |tab| {
            const tab_obj = tab.object;
            const tab_title = jsonStr(tab_obj.get("title"));
            const tab_index = jsonInt(tab_obj.get("index"));
            const tab_selected = jsonBool(tab_obj.get("selected"));

            try stdout.print("  Tab {d}: \"{s}\"", .{ tab_index, tab_title });
            if (tab_selected) {
                try stdout.writeAll(" (selected)");
            }
            try stdout.writeAll("\n");

            if (tab_obj.get("splits")) |splits| {
                const leaves = collectLeaves(alloc, splits) catch continue;
                defer alloc.free(leaves);

                if (leaves.len == 1) {
                    try stdout.writeAll("    ");
                    try formatTerminal(stdout, leaves[0]);
                    try stdout.writeAll("\n");
                } else {
                    for (leaves, 0..) |leaf, i| {
                        if (i == leaves.len - 1) {
                            try stdout.writeAll("    \xe2\x94\x94\xe2\x94\x80 ");
                        } else {
                            try stdout.writeAll("    \xe2\x94\x9c\xe2\x94\x80 ");
                        }
                        try formatTerminal(stdout, leaf);
                        try stdout.writeAll("\n");
                    }
                }
            }
        }
    }
}

fn formatTerminal(stdout: *std.Io.Writer, terminal_val: std.json.Value) !void {
    if (terminal_val != .object) return;
    const term = terminal_val.object;

    const title = jsonStr(term.get("title"));
    const focused = jsonBool(term.get("focused"));

    // Viewer panes render a file or website instead of a terminal; they
    // have no cwd/pid/tty, so show their kind + location instead.
    const is_viewer = if (term.get("type")) |t|
        t == .string and std.mem.eql(u8, t.string, "viewer")
    else
        false;

    if (is_viewer) {
        try stdout.print("view: {s}  {s}", .{ title, jsonStr(term.get("url")) });
    } else {
        const cwd = jsonStr(term.get("working_directory"));
        const pid = jsonInt(term.get("pid"));
        const tty = jsonStr(term.get("tty"));
        try stdout.print("{s}  {s}  pid:{d}  {s}", .{ title, cwd, pid, tty });
    }

    if (term.get("name")) |name| {
        if (name != .null) {
            try stdout.writeAll("  [name: ");
            try stdout.writeAll(jsonStr(name));
            try stdout.writeAll("]");
        }
    }

    if (!is_viewer) {
        if (term.get("exit_code")) |exit_code| {
            switch (exit_code) {
                .integer => |code| try stdout.print("  exited({d})", .{code}),
                .null => try stdout.writeAll("  running"),
                else => {},
            }
        }
    }

    if (focused) {
        try stdout.writeAll(" *");
    }
}

const LeafList = []std.json.Value;

fn collectLeaves(alloc: Allocator, node: std.json.Value) !LeafList {
    if (node != .object) return &.{};

    const obj = node.object;
    const node_type = jsonStr(obj.get("type"));

    if (std.mem.eql(u8, node_type, "leaf")) {
        const terminal = obj.get("terminal") orelse return &.{};
        const result = try alloc.alloc(std.json.Value, 1);
        result[0] = terminal;
        return result;
    }

    if (std.mem.eql(u8, node_type, "split")) {
        const left_node = obj.get("left") orelse return &.{};
        const right_node = obj.get("right") orelse return &.{};
        const left_leaves = try collectLeaves(alloc, left_node);
        const right_leaves = try collectLeaves(alloc, right_node);

        const result = try alloc.alloc(std.json.Value, left_leaves.len + right_leaves.len);
        @memcpy(result[0..left_leaves.len], left_leaves);
        @memcpy(result[left_leaves.len..], right_leaves);
        return result;
    }

    return &.{};
}

fn jsonStr(val: ?std.json.Value) []const u8 {
    const v = val orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn jsonBool(val: ?std.json.Value) bool {
    const v = val orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn jsonInt(val: ?std.json.Value) i64 {
    const v = val orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

fn connectUnixSocket(path: [:0]const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    );
    errdefer std.posix.close(fd);

    var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;

    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    return fd;
}

fn readFull(fd: std.posix.fd_t, buffer: []u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = std.posix.read(fd, buffer[total..]) catch |err| return err;
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}
