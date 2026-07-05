const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Command = @import("Command.zig");

const log_path_suffix = "/ghoztty-exit.log";

pub fn logUnexpectedExit(exit_code: u32, runtime_ms: u64, context: []const u8) void {
    const exit = Command.Exit.init(exit_code);

    const is_unexpected = switch (exit) {
        .Signal => true,
        .Stopped => true,
        .Unknown => true,
        .Exited => |code| code != 0 or runtime_ms < 10_000,
    };
    if (!is_unexpected) return;

    var buf: [512]u8 = undefined;
    const msg = switch (exit) {
        .Signal => |sig| std.fmt.bufPrint(&buf, "[{s}] killed by signal={} runtime={}ms\n", .{ context, sig, runtime_ms }),
        .Exited => |code| std.fmt.bufPrint(&buf, "[{s}] exited code={} runtime={}ms\n", .{ context, code, runtime_ms }),
        .Stopped => |sig| std.fmt.bufPrint(&buf, "[{s}] stopped by signal={} runtime={}ms\n", .{ context, sig, runtime_ms }),
        .Unknown => std.fmt.bufPrint(&buf, "[{s}] unknown raw_status={} runtime={}ms\n", .{ context, exit_code, runtime_ms }),
    } catch return;

    appendToLog(msg);
}

pub fn logEvent(context: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{s}]\n", .{context}) catch return;
    appendToLog(msg);
}

fn appendToLog(msg: []const u8) void {
    // This is a $TMPDIR-based debugging aid for the macOS/Linux builds;
    // skip it on Windows rather than porting the path handling.
    if (comptime builtin.os.tag == .windows) return;

    const tmpdir = posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ tmpdir, log_path_suffix }) catch return;
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => std.fs.cwd().createFile(path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    _ = file.write(msg) catch {};
}
