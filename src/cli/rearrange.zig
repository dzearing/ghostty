const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const ipc_client = @import("../os/ipc_client.zig");

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
    const conn = ipc_client.connect(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoRunningInstance,
    };
    defer conn.close();

    const json_payload = try ipc_client.buildRequest(
        alloc,
        "rearrange",
        if (arguments.len > 0) arguments else null,
    );
    defer alloc.free(json_payload);

    const resp_buf = try ipc_client.exchange(alloc, conn, json_payload, .{
        .max_response = 4_194_304,
    }, stderr);

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
