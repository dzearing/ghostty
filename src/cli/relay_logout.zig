const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const relay_account = @import("../remote/relay_account.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Sign out of the relay Google account (T21a): delete the DPAPI-encrypted
/// account store at `%LOCALAPPDATA%\ghoztty\account.dat`. Runs entirely in
/// this process (no IPC). Signing out when already signed out succeeds
/// silently — the account tier just falls back to `GHOSTTY_RELAY_TOKEN`.
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

fn runArgs(alloc_gpa: Allocator, argsIter: anytype, stderr: *std.Io.Writer) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var arena_state = ArenaAllocator.init(alloc_gpa);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const path = relay_account.accountPath(alloc) catch {
        try stderr.print("Could not resolve the account store path.\n", .{});
        return 1;
    };
    const was_signed_in = relay_account.isSignedIn(alloc, path);
    relay_account.delete(path);

    var out_buf: [256]u8 = undefined;
    var out_writer = std.fs.File.stdout().writerStreaming(&out_buf);
    const stdout = &out_writer.interface;
    const msg = if (was_signed_in) "Signed out.\n" else "Already signed out.\n";
    try stdout.writeAll(msg);
    stdout.flush() catch {};
    return 0;
}
