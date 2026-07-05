const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _arguments: std.ArrayList([:0]const u8) = .empty,
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        _ = self;
        return try alloc.dupeZ(u8, arg);
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Rearrange the pane layout of a running Ghoztty window.
///
/// Accepts a declarative JSON layout description and rebuilds the split
/// tree to match, preserving terminal state (running processes, scrollback,
/// focus). Panes are referenced by name and must already exist in the
/// target window.
///
/// Flags:
///
///   * `--target=<name>`: The target window name to rearrange. If not
///     specified, the most recently focused window is used.
///
///   * `--layout=<json>`: A JSON layout descriptor. The layout is a tree
///     of split nodes and leaf panes:
///
///       Leaf: `{"pane": "name"}`
///       Split: `{"direction": "horizontal|vertical", "ratio": 0-100, "left": ..., "right": ...}`
///
///     Ratio is the percentage given to the left/top child (default 50,
///     clamped to 10-90). Panes not included in the layout are closed.
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
    // These commands drive a running Ghoztty instance over a Unix-domain
    // socket, which the Windows beta does not have (see
    // docs/design/windows-amd64-plan.md cut lines). Guarding here keeps the
    // posix-only socket helpers below out of Windows semantic analysis.
    if (comptime builtin.os.tag == .windows) {
        try stderr.print("This command is not supported on Windows.\n", .{});
        return 1;
    }

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

    sendRearrange(alloc, opts._arguments.items, stderr) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("No running Ghoztty instance found. Start one with +new-window first.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("IPC failed: {}\n", .{err});
            return 1;
        },
    };

    return 0;
}

fn sendRearrange(
    alloc: Allocator,
    arguments: [][:0]const u8,
    stderr: *std.Io.Writer,
) !void {
    // Unix-socket IPC does not exist on Windows; the Windows beta has no
    // CLI window-management (see docs/design/windows-amd64-plan.md).
    if (comptime builtin.os.tag == .windows) return error.IPCFailed;

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

    var json_buf: std.Io.Writer.Allocating = .init(alloc);
    defer json_buf.deinit();
    var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

    jws.beginObject() catch return error.IPCFailed;
    jws.objectField("action") catch return error.IPCFailed;
    jws.write("rearrange") catch return error.IPCFailed;

    if (arguments.len > 0) {
        jws.objectField("arguments") catch return error.IPCFailed;
        jws.beginArray() catch return error.IPCFailed;
        for (arguments) |arg| {
            jws.write(arg) catch return error.IPCFailed;
        }
        jws.endArray() catch return error.IPCFailed;
    }

    jws.endObject() catch return error.IPCFailed;

    const json_bytes = json_buf.written();

    const len: u32 = @intCast(json_bytes.len);
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, len));
    _ = std.posix.write(fd, &len_bytes) catch |err| {
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    _ = std.posix.write(fd, json_bytes) catch |err| {
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

    const parsed = std.json.parseFromSlice(
        struct { success: bool = false, @"error": ?[]const u8 = null },
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
        if (parsed.value.@"error") |err_msg| {
            stderr.print("error: {s}\n", .{err_msg}) catch {};
        }
        stderr.flush() catch {};
        return error.IPCFailed;
    }
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
