const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Wake up the app event loop. The `none` runtime has no event loop (it is
    /// the CLI/headless artifact), so this is a no-op. It exists so code that is
    /// generic over the runtime — e.g. `App.Mailbox.push`, exercised by headless
    /// harnesses that drive a real `Termio` — can compile and link.
    pub fn wakeup(self: *const App) void {
        _ = self;
    }

    pub fn performIpc(
        alloc: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        const action_name = switch (action) {
            .new_window => "new-window",
            .split => "split",
            .close => "close",
            .rename => "rename",
            .rearrange => "rearrange",
            .send_keys => "send-keys",
            .set_state => "set-state",
            .set_banner => "set-banner",
        };

        return sendIpc(alloc, action_name, value.arguments);
    }

    fn sendIpc(
        alloc: Allocator,
        action_name: []const u8,
        arguments: ?[][:0]const u8,
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        var buf: [256]u8 = undefined;
        // Streaming (not positional) writer: the CLI command that called us
        // has its own buffered stderr writer, and mixing a positional writer
        // with it corrupts/reorders output when stderr is a file or pipe.
        var stderr_writer = std.fs.File.stderr().writerStreaming(&buf);
        const stderr = &stderr_writer.interface;

        const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
        const uid = std.c.getuid();
        const build_config = @import("../build_config.zig");
        const suffix = if (build_config.is_debug) "-debug" else "";
        const sock_path = std.fmt.allocPrintSentinel(alloc, "{s}ghostty{s}-{d}.sock", .{
            tmpdir, suffix, uid,
        }, 0) catch |err| {
            stderr.print("Failed to build socket path: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer alloc.free(sock_path);

        const fd = connectUnixSocket(sock_path) catch blk: {
            // Connection failed. Drop a sentinel file to signal the main
            // process to rebind its socket, then retry with backoff.
            const sentinel_path = std.fmt.allocPrintSentinel(alloc, "{s}.reset", .{sock_path}, 0) catch {
                stderr.print("Could not connect to running Ghoztty instance.\n", .{}) catch {};
                stderr.flush() catch {};
                return error.IPCFailed;
            };
            defer alloc.free(sentinel_path);

            if (std.fs.cwd().createFile(sentinel_path, .{})) |f| {
                f.close();
            } else |_| {}

            const max_retries = 8;
            var attempt: usize = 0;
            while (attempt < max_retries) : (attempt += 1) {
                std.Thread.sleep(300 * std.time.ns_per_ms);
                if (connectUnixSocket(sock_path)) |connected_fd| {
                    std.fs.cwd().deleteFile(sentinel_path) catch {};
                    break :blk connected_fd;
                } else |_| {}

                // If the sentinel file still exists after several attempts,
                // no server is watching for it — bail early.
                if (attempt >= 2) {
                    if (std.fs.accessAbsolute(sentinel_path, .{})) |_| {
                        break;
                    } else |_| {}
                }
            }

            std.fs.cwd().deleteFile(sentinel_path) catch {};
            return error.NoRunningInstance;
        };
        defer std.posix.close(fd);

        var json_buf: std.Io.Writer.Allocating = .init(alloc);
        defer json_buf.deinit();
        var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

        jws.beginObject() catch return error.IPCFailed;
        jws.objectField("action") catch return error.IPCFailed;
        jws.write(action_name) catch return error.IPCFailed;

        if (arguments) |args| {
            jws.objectField("arguments") catch return error.IPCFailed;
            jws.beginArray() catch return error.IPCFailed;
            for (args) |arg| {
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
        if (resp_len == 0 or resp_len > 1048576) {
            stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        }

        const resp_buf = alloc.alloc(u8, resp_len) catch {
            stderr.print("Out of memory reading IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer alloc.free(resp_buf);

        readFull(fd, resp_buf) catch {
            stderr.print("Failed to read IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        const parsed = apprt.ipc.parseResponse(alloc, resp_buf) catch {
            stderr.print("IPC response is not valid JSON\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer parsed.deinit();

        // On failure the server includes a human-readable reason (e.g.
        // "pane 'd1' not found in registry"). Print it here so EVERY CLI
        // action surfaces the real cause instead of a generic fallback.
        if (!parsed.value.success) {
            if (parsed.value.@"error") |msg| {
                stderr.print("{s}\n", .{msg}) catch {};
                stderr.flush() catch {};
            }
            return false;
        }

        return true;
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
};
pub const Surface = struct {};
