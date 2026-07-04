//! Out-of-tree smoke driver for the real-PTY agent (NOT part of the build graph).
//! Spawns the `ghoztty-agent` binary, performs the HELLO handshake, sends OPEN +
//! a DATA `"echo hello-from-pty\n"`, and confirms the text comes back through the
//! agent's output ring/frames on stdout. Run from the repo root:
//!
//!   zig run -Mroot=src/remote/agent_smoke.zig -- zig-out/bin/ghoztty-agent
//!
//! Prints PASS/FAIL and exits non-zero on failure.

const std = @import("std");
const protocol = @import("protocol.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    const agent_path = args.next() orelse "zig-out/bin/ghoztty-agent";

    const enc: protocol.TransferEncoding = .raw;

    var child = std.process.Child.init(&.{agent_path}, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const stdin = child.stdin.?;
    const stdout = child.stdout.?;

    // --- send HELLO -----------------------------------------------------------
    {
        const json = try (protocol.Hello{ .transfer_encoding = enc }).encode(alloc);
        defer alloc.free(json);
        try sendFrame(alloc, stdin, enc, .{ .type = .hello, .channel = protocol.control_channel, .seq = 0, .payload = json });
    }

    // --- read agent HELLO + OPEN (control) on stdout via a Reader -------------
    var reader = protocol.Reader.init(alloc, enc);
    defer reader.deinit();
    var scratch: [16 * 1024]u8 = undefined;

    _ = try waitFrame(stdout, &reader, &scratch, .hello);

    // --- send OPEN ------------------------------------------------------------
    {
        const json = try protocol.encodeJson(alloc, protocol.Open{ .rows = 24, .cols = 80 });
        defer alloc.free(json);
        try sendFrame(alloc, stdin, enc, .{ .type = .open, .channel = protocol.control_channel, .seq = 0, .payload = json });
    }

    // --- read OPENED; capture the data channel --------------------------------
    const opened_frame = try waitFrame(stdout, &reader, &scratch, .opened);
    const data_channel = opened_frame.channel;

    // --- send DATA: `echo hello-from-pty\n` -----------------------------------
    {
        const line = "echo hello-from-pty\n";
        const payload = try alloc.alloc(u8, protocol.DataPayload.encodedLen(line.len));
        defer alloc.free(payload);
        _ = (protocol.DataPayload{ .byte_offset = 0, .bytes = line }).encodeInto(payload);
        try sendFrame(alloc, stdin, enc, .{ .type = .data, .channel = data_channel, .seq = 0, .payload = payload });
    }

    // --- collect DATA frames until we see "hello-from-pty" --------------------
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(alloc);

    const deadline = std.time.milliTimestamp() + 8000;
    var ok = false;
    while (std.time.milliTimestamp() < deadline) {
        const maybe = reader.next() catch break;
        if (maybe) |f| {
            if (f.type == .data) {
                const dp = try protocol.DataPayload.decode(f.payload);
                try accumulated.appendSlice(alloc, dp.bytes);
                if (std.mem.indexOf(u8, accumulated.items, "hello-from-pty") != null) {
                    ok = true;
                    break;
                }
            }
            continue;
        }
        const n = stdout.read(&scratch) catch break;
        if (n == 0) break;
        try reader.push(scratch[0..n]);
    }

    // Tear down: kill the agent (Child.kill closes the pipes + reaps).
    _ = child.kill() catch {};

    if (ok) {
        std.debug.print("SMOKE PASS: received \"hello-from-pty\" back through the pty/output-ring/DATA frames.\n", .{});
        std.debug.print("captured echo bytes:\n{s}\n", .{accumulated.items});
    } else {
        std.debug.print("SMOKE FAIL: did not observe \"hello-from-pty\". captured:\n{s}\n", .{accumulated.items});
        std.process.exit(1);
    }
}

fn sendFrame(
    alloc: std.mem.Allocator,
    file: std.fs.File,
    enc: protocol.TransferEncoding,
    frame: protocol.Frame,
) !void {
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(alloc);
    try protocol.writeFrame(alloc, enc, frame, &wire);
    try file.writeAll(wire.items);
}

fn waitFrame(
    file: std.fs.File,
    reader: *protocol.Reader,
    scratch: []u8,
    want: protocol.FrameType,
) !protocol.Frame {
    while (true) {
        if (try reader.next()) |f| {
            if (f.type == want) return f;
            continue;
        }
        const n = try file.read(scratch);
        if (n == 0) return error.Eof;
        try reader.push(scratch[0..n]);
    }
}
