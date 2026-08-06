//! Same-directory atomic file publish — write a staging file next to the
//! destination, fsync, rename. The ONE copy of the recipe behind
//! `session_meta.writeAtomic`, `layout_meta.writeAtomic`,
//! `ring_snapshot.writeAtomic`, and the win32 `session_layout.writeAtomic`.
//!
//! ## Why the staging name is unique per call (T183)
//!
//! The staging name is `<path>.<hex64>.tmp`, a fresh random nonce every call —
//! NOT a shared `<path>.tmp`. The shared name made the recipe wrong under
//! CONCURRENT writers to the same path, and concurrent writers are a normal
//! state, not a test artifact: the agent persists `sessions.json` from the
//! control thread (OPEN/CLOSE/RELAUNCH), the child-exit watcher, and shutdown.
//! With a shared staging name, two overlapping writers interleave like this:
//!
//!   A: create <path>.tmp, write, sync        (complete, durable)
//!   B: create <path>.tmp (TRUNCATES A's), begins writing
//!   A: rename <path>.tmp → <path>            (publishes B's PARTIAL bytes)
//!   B: rename <path>.tmp → <path>            (FileNotFound — A took the file)
//!
//! So one writer can publish a torn file — on the reboot floor, a corrupt
//! roster — and the other fails with the mystery warn that took the floor
//! lanes red (`session_meta: write to ...\sessions.json failed: FileNotFound`,
//! T183). A unique name means every rename publishes only a file its own
//! writer finished and synced; when writers overlap, last rename wins with a
//! COMPLETE file.
//!
//! ## Crash debris
//!
//! A process that dies between create and rename leaves `<path>.<hex>.tmp`
//! behind (the error paths clean up; a hard kill cannot). Debris is bounded by
//! crash count, matched by no loader, and every successful call best-effort
//! deletes the legacy fixed `<path>.tmp` name so a file left by a pre-T183
//! build heals on the next persist.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Atomically publish the concatenation of `chunks` at `path`, creating parent
/// directories as needed. A concurrent or subsequent reader observes either
/// the previous complete file or the new complete file, never a mix — and that
/// holds even when several threads write the same `path` at once (see the
/// module doc).
pub fn writeChunks(alloc: Allocator, path: []const u8, chunks: []const []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const nonce = std.fmt.hex(std.crypto.random.int(u64));
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.{s}.tmp", .{ path, &nonce });
    defer alloc.free(tmp_path);
    {
        // Declared before the create/close pair so on error (LIFO) the file
        // closes BEFORE the delete — Windows can't delete an open file.
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        for (chunks) |c| try file.writeAll(c);
        // Durable before the rename publishes it.
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);

    // Heal legacy `<path>.tmp` debris left by a pre-unique-name build that
    // died between create and rename (that name is never written again).
    const legacy = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(legacy);
    std.fs.cwd().deleteFile(legacy) catch {};
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "writeChunks: chunks concatenate; publish leaves ONLY the file behind" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    // Nested path exercises makePath (the parent dir does not exist yet).
    const path = try std.fs.path.join(alloc, &.{ dir_path, "state", "file.bin" });
    defer alloc.free(path);

    try writeChunks(alloc, path, &.{ "head", "-", "tail" });
    const got = try std.fs.cwd().readFileAlloc(alloc, path, 1024);
    defer alloc.free(got);
    try testing.expectEqualStrings("head-tail", got);

    // No staging leftover of ANY name — the parent holds exactly the file.
    var dir = try std.fs.cwd().openDir(std.fs.path.dirname(path).?, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        count += 1;
        try testing.expectEqualStrings("file.bin", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), count);

    // A pre-T183 build's crash debris heals on the next successful publish.
    const legacy = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(legacy);
    try std.fs.cwd().writeFile(.{ .sub_path = legacy, .data = "debris" });
    try writeChunks(alloc, path, &.{"again"});
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(legacy));
}

test "writeChunks: concurrent writers to ONE path never error or tear (T183)" {
    // The observed floor-lane failure, reproduced deliberately: several threads
    // publishing the same path at once. With the shared `<path>.tmp` staging
    // name this fails fast — the loser's rename comes back FileNotFound (the
    // winner renamed the staging file away) and a torn publish is possible
    // (the loser's create truncated the winner's synced bytes). With unique
    // staging names every call must SUCCEED and the surviving file must be one
    // writer's complete body, never a mix.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "contended.json" });
    defer alloc.free(path);

    const writers = 4;
    const rounds = 25;
    // Each writer's body is one distinct byte repeated: any interleaving of
    // two writers' bytes is detectable, and truncation is detectable by size.
    const body_len = 4096;

    const W = struct {
        fn run(a: Allocator, p: []const u8, fill: u8, failed: *std.atomic.Value(bool)) void {
            var body: [body_len]u8 = undefined;
            @memset(&body, fill);
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                writeChunks(a, p, &.{&body}) catch {
                    failed.store(true, .seq_cst);
                    return;
                };
            }
        }
    };

    var failed = std.atomic.Value(bool).init(false);
    var threads: [writers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, W.run, .{ alloc, path, 'A' + @as(u8, @intCast(i)), &failed });
    }
    for (&threads) |*t| t.join();
    try testing.expect(!failed.load(.seq_cst));

    // The survivor is exactly ONE complete body.
    const got = try std.fs.cwd().readFileAlloc(alloc, path, body_len * 2);
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, body_len), got.len);
    for (got) |b| try testing.expectEqual(got[0], b);
}
