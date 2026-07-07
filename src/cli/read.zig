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

    name: ?[:0]const u8 = null,
    lines: u32 = 50,

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        if (std.mem.startsWith(u8, arg, "--name=")) {
            self.name = try alloc.dupeZ(u8, arg["--name=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--lines=")) {
            self.lines = std.fmt.parseInt(u32, arg["--lines=".len..], 10) catch return error.InvalidValue;
        }

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (std.mem.startsWith(u8, param, "--name=")) {
                self.name = try alloc.dupeZ(u8, param["--name=".len..]);
            } else if (std.mem.startsWith(u8, param, "--lines=")) {
                self.lines = std.fmt.parseInt(u32, param["--lines=".len..], 10) catch return error.InvalidValue;
            }
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

/// Read the last N lines of terminal output from a named pane in a
/// running Ghoztty instance and print them to stdout.
///
/// The output is plain text with no JSON wrapping or ANSI escape
/// sequences, suitable for piping or capturing in a variable.
///
/// Flags:
///
///   * `--name=<pane>`: The name of the pane to read from. Required.
///     The pane must have been created with `+split --name=<name>` or
///     registered via `+new-window --target=<name>`.
///
///   * `--lines=<N>`: Number of lines to read from the end of the
///     scrollback buffer. Default: 50.
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

    if (opts.name == null) {
        try stderr.print("Error: --name is required for +read\n", .{});
        return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resp_body = sendReadQuery(alloc, opts._arguments.items, stderr) catch |err| switch (err) {
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

    // Parse the response to extract text
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{}) catch {
        try stderr.print("IPC response is not valid JSON\n", .{});
        return 1;
    };
    defer parsed.deinit();

    const data_val = parsed.value.object.get("data") orelse {
        try stderr.print("IPC response missing data field\n", .{});
        return 1;
    };

    const text = switch (data_val) {
        .object => |obj| blk: {
            const t = obj.get("text") orelse break :blk "";
            break :blk switch (t) {
                .string => |s| s,
                else => "",
            };
        },
        else => "",
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    stdout.writeAll(text) catch return 1;
    stdout.writeAll("\n") catch return 1;
    stdout.flush() catch return 1;

    return 0;
}

/// Query the last `lines` lines of a named pane and return the plain
/// text. For use by other CLI actions (e.g. `+send-keys --when-idle`).
/// The returned slice points into JSON parsed with `alloc`, so callers
/// must pass an arena (as the CLI actions do).
pub fn queryPaneText(
    alloc: Allocator,
    name: []const u8,
    lines: u32,
    stderr: *std.Io.Writer,
) ![]const u8 {
    const name_arg = try std.fmt.allocPrintSentinel(alloc, "--name={s}", .{name}, 0);
    const lines_arg = try std.fmt.allocPrintSentinel(alloc, "--lines={d}", .{lines}, 0);
    var ipc_args = [_][:0]const u8{ name_arg, lines_arg };
    const resp_body = try sendReadQuery(alloc, &ipc_args, stderr);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{});
    const data_val = parsed.value.object.get("data") orelse return "";
    if (data_val != .object) return "";
    const text = data_val.object.get("text") orelse return "";
    return switch (text) {
        .string => |s| s,
        else => "",
    };
}

fn sendReadQuery(
    alloc: Allocator,
    arguments: [][:0]const u8,
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

    // Build JSON payload
    var json_buf: std.Io.Writer.Allocating = .init(alloc);
    defer json_buf.deinit();
    var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

    jws.beginObject() catch return error.IPCFailed;
    jws.objectField("action") catch return error.IPCFailed;
    jws.write("read") catch return error.IPCFailed;

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

    // Send: 4-byte big-endian length + JSON
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

    // Read response: 4-byte big-endian length + JSON
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

    // Check success field
    const success_parsed = std.json.parseFromSlice(
        struct { success: bool = false, @"error": ?[]const u8 = null },
        alloc,
        resp_buf,
        .{ .ignore_unknown_fields = true },
    ) catch {
        stderr.print("IPC response is not valid JSON\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    defer success_parsed.deinit();

    if (!success_parsed.value.success) {
        if (success_parsed.value.@"error") |err_msg| {
            stderr.print("{s}\n", .{err_msg}) catch {};
            stderr.flush() catch {};
        }
        return error.IPCFailed;
    }

    return resp_buf;
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
