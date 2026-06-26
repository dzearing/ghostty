const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    _arguments: std.ArrayList([:0]const u8) = .empty,

    host: ?[:0]const u8 = null,
    port: u16 = 0,

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        try self.absorb(alloc, arg);
        while (iter.next()) |param| try self.absorb(alloc, param);

        return false;
    }

    fn absorb(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!void {
        if (std.mem.startsWith(u8, arg, "--host=")) {
            self.host = try alloc.dupeZ(u8, arg["--host=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            self.port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch return error.InvalidValue;
        }
        try self._arguments.append(alloc, try alloc.dupeZ(u8, arg));
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

/// Open a remote-machine terminal window in a running Ghoztty instance via IPC.
///
/// This drives the EXACT same flow as the Cmd-Shift-N "New Remote Window" menu
/// action: the running app dials the agent at `host:port` over TCP (completing
/// the handshake), builds a surface configuration bound to that connection, and
/// opens a window whose terminal runs on the remote machine. It exists so the
/// remote-window GUI path can be triggered headlessly from the shell (macOS
/// blocks synthesized keystrokes), which makes the feature scriptable and
/// reproducible for tests.
///
/// Flags:
///
///   * `--host=<host>`: The agent host (DNS name or literal IP). Required.
///   * `--port=<port>`: The agent TCP port. Required.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&buffer);
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

    if (opts.host == null) {
        try stderr.print("Error: --host is required for +new-remote-window\n", .{});
        return 1;
    }
    if (opts.port == 0) {
        try stderr.print("Error: --port is required for +new-remote-window\n", .{});
        return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    sendOpen(alloc, opts._arguments.items, stderr) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("No running Ghoztty instance found. Start one with +new-window first.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    };

    return 0;
}

fn sendOpen(
    alloc: Allocator,
    arguments: [][:0]const u8,
    stderr: *std.Io.Writer,
) !void {
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

    // Build JSON payload: {"action":"new-remote-window","arguments":[...]}
    var json_buf: std.Io.Writer.Allocating = .init(alloc);
    defer json_buf.deinit();
    var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

    jws.beginObject() catch return error.IPCFailed;
    jws.objectField("action") catch return error.IPCFailed;
    jws.write("new-remote-window") catch return error.IPCFailed;
    jws.objectField("arguments") catch return error.IPCFailed;
    jws.beginArray() catch return error.IPCFailed;
    for (arguments) |arg| jws.write(arg) catch return error.IPCFailed;
    jws.endArray() catch return error.IPCFailed;
    jws.endObject() catch return error.IPCFailed;

    const json_bytes = json_buf.written();

    const len: u32 = @intCast(json_bytes.len);
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, len));
    _ = std.posix.write(fd, &len_bytes) catch |err| {
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        return error.IPCFailed;
    };
    _ = std.posix.write(fd, json_bytes) catch |err| {
        stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
        return error.IPCFailed;
    };

    // Read response: 4-byte big-endian length + JSON {success, error?}.
    var resp_len_bytes: [4]u8 = undefined;
    readFull(fd, &resp_len_bytes) catch {
        stderr.print("Failed to read IPC response length\n", .{}) catch {};
        return error.IPCFailed;
    };

    const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
    if (resp_len == 0 or resp_len > 1_048_576) {
        stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
        return error.IPCFailed;
    }

    const resp_buf = try alloc.alloc(u8, resp_len);
    readFull(fd, resp_buf) catch {
        stderr.print("Failed to read IPC response\n", .{}) catch {};
        return error.IPCFailed;
    };

    const parsed = std.json.parseFromSlice(
        struct { success: bool = false, @"error": ?[]const u8 = null },
        alloc,
        resp_buf,
        .{ .ignore_unknown_fields = true },
    ) catch {
        stderr.print("IPC response is not valid JSON\n", .{}) catch {};
        return error.IPCFailed;
    };
    defer parsed.deinit();

    if (!parsed.value.success) {
        if (parsed.value.@"error") |err_msg| {
            stderr.print("{s}\n", .{err_msg}) catch {};
        }
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
