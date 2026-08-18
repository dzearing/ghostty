const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const verb_flags = @import("verb_flags.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,

    _arguments: std.ArrayList([:0]const u8) = .empty,

    _diagnostics: diagnostics.DiagnosticList = .{},

    /// The server ignores a flag it does not know, on purpose, so the CLI is
    /// where a typo has to be caught (T852).
    _flags: verb_flags.Checker = .{ .spec = verb_flags.set_state },

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        if (!try self._flags.accept(alloc, arg)) return null;
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

/// Set the activity state of a named window or pane.
///
/// Sets the activity state via IPC, which updates the window title
/// suffix and the AXWindowActivityState accessibility attribute.
///
/// The state names below are the machine tokens: they are what this
/// flag and AXWindowActivityState use. The title suffix shows the
/// human label instead, so `needs_input` renders as `(question)`.
/// Read the accessibility attribute, never the title, to determine
/// a window's state.
///
/// Flags:
///
///   * `--target=<name>`: The named window or pane. Required.
///
///   * `--state=<value>`: The activity state: idle, busy, or
///     needs_input. Required.
///
/// Any other argument starting with `--` is an error, so a misspelled
/// flag is rejected instead of being dropped by the server.
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

    if (opts._flags.help_requested) return Action.help_error;

    if (try opts._flags.report(stderr)) return 1;

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .set_state,
        .{
            .arguments = if (opts._arguments.items.len == 0) null else opts._arguments.items,
        },
    ) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("+set-state requires a running Ghoztty instance.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    // sendIpc already printed the server's error text (if any) to stderr.
    try stderr.print("+set-state failed.\n", .{});
    return 1;
}
