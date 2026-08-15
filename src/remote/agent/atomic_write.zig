//! Same-directory atomic file publish — write a staging file next to the
//! destination, fsync, rename. The ONE copy of the recipe behind
//! `session_meta.writeAtomic`, `layout_meta.writeAtomic`,
//! `ring_snapshot.writeAtomic`, the win32 `session_layout.writeAtomic`, and
//! (since T500) the single-writer publishes too: the agent info file
//! (`main.writeInfoFile`), `enroll.saveRelayEnv`, and `relay_account.save` —
//! the latter two as `.secret` (0600 staging on POSIX; their Windows DACL
//! hardening stays at the call site).
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
//! ## Why the rename retries, and why the budget is seconds (T508)
//!
//! Unique staging names make every rename publish a complete file, but on
//! Windows the rename ITSELF can transiently fail: the publish is
//! `FileRenameInformation` + `ReplaceIfExists`, and replacing a target some
//! other process holds open without `FILE_SHARE_DELETE` surfaces
//! `STATUS_ACCESS_DENIED` (⇒ `error.AccessDenied`). The holder in practice is
//! the on-access scanner examining the file the PREVIOUS writer just
//! published. Measured on this box (probe with unbounded retries, 4 threads x
//! 200 rounds x 10 processes under CPU load): outages hit all four threads at
//! once, last 440–786ms, and always clear — scan holds are sub-millisecond on
//! an idle box, which is why only loaded soaks ever saw this. The staging
//! file is complete and synced before the rename, so retrying is safe by
//! construction; the budget must out-wait a whole stretched scan hold, so it
//! is seconds, not milliseconds (a 95ms budget still failed 37 of 120 runs).
//! A genuine permission problem still fails, ~5s later.
//!
//! ## Crash debris
//!
//! A process that dies between create and rename leaves `<path>.<hex>.tmp`
//! behind (the error paths clean up; a hard kill cannot). Debris is bounded by
//! crash count, matched by no loader, and every successful call best-effort
//! deletes the legacy fixed `<path>.tmp` name so a file left by a pre-T183
//! build heals on the next persist.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// The payload is a credential: the staging file is created mode 0600 on
    /// POSIX, and the rename carries that mode onto the published file.
    /// Ignored on Windows, where create-flag modes don't exist — Windows
    /// callers tighten the published path's DACL themselves (win_acl.harden)
    /// after the publish.
    secret: bool = false,
};

/// Atomically publish the concatenation of `chunks` at `path`, creating parent
/// directories as needed. A concurrent or subsequent reader observes either
/// the previous complete file or the new complete file, never a mix — and that
/// holds even when several threads write the same `path` at once (see the
/// module doc).
pub fn writeChunks(alloc: Allocator, path: []const u8, chunks: []const []const u8, opts: Options) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const nonce = std.fmt.hex(std.crypto.random.int(u64));
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.{s}.tmp", .{ path, &nonce });
    defer alloc.free(tmp_path);
    var flags: std.fs.File.CreateFlags = .{ .truncate = true };
    if (opts.secret and builtin.os.tag != .windows) flags.mode = 0o600;
    {
        // Declared before the create/close pair so on error (LIFO) the file
        // closes BEFORE the delete — Windows can't delete an open file.
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, flags);
        defer file.close();
        for (chunks) |c| try file.writeAll(c);
        // Durable before the rename publishes it.
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try renameWithRetry(std.fs.cwd(), ThreadSleeper{}, tmp_path, path);

    // Heal legacy `<path>.tmp` debris left by a pre-unique-name build that
    // died between create and rename (that name is never written again).
    const legacy = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(legacy);
    std.fs.cwd().deleteFile(legacy) catch {};
}

/// Total retry budget for the publish rename before its error is real (T508).
/// Sized from measurement, not taste: with retries unbounded, the observed
/// AccessDenied outages on this box under a deliberately brutal load harness
/// (16 CPU spinners + 40 writer threads) lasted 440–786ms and always cleared —
/// the signature of an on-access scanner holding the just-published target,
/// stretched by CPU starvation. 5s is ~6x the worst observed hold; the first
/// sizing (95ms) was inside the window and still failed 37 of 120 runs.
const rename_retry_budget_ns: u64 = 5 * std.time.ns_per_s;

/// Backoff before retry `attempt` (1-based): 1ms, 2ms, 4ms … capped at 50ms.
fn renameBackoffNs(attempt: usize) u64 {
    const shift: u6 = @intCast(@min(attempt - 1, 6));
    return @min(@as(u64, std.time.ns_per_ms) << shift, 50 * std.time.ns_per_ms);
}

/// The error shapes a scanner's transient hold on the target (or a concurrent
/// replace of the same target) produces on Windows. Anything else —
/// FileNotFound, NoSpaceLeft, a bad path — is real and never retried.
fn isTransientRenameError(err: anyerror) bool {
    return switch (err) {
        error.AccessDenied, error.PathAlreadyExists => true,
        else => false,
    };
}

/// Sleeper used by production `writeChunks`; tests inject a recorder instead
/// so the budget-exhaustion path runs without real sleeping.
const ThreadSleeper = struct {
    fn sleep(_: @This(), ns: u64) void {
        std.Thread.sleep(ns);
    }
};

/// Rename with a time-budgeted retry on the transient contention errors
/// (T508). `dir` is anything with a `rename(old, new)` method — `std.fs.Dir`
/// in production, a failure-injecting mock in tests — and `sleeper` anything
/// with a `sleep(ns)` method. The budget counts REQUESTED sleep, so actual
/// wall time is at least the budget under load, which is the direction that
/// helps.
fn renameWithRetry(dir: anytype, sleeper: anytype, tmp_path: []const u8, path: []const u8) !void {
    var slept: u64 = 0;
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        return dir.rename(tmp_path, path) catch |err| {
            if (!isTransientRenameError(err)) return err;
            if (slept >= rename_retry_budget_ns) return err;
            const ns = renameBackoffNs(attempt);
            sleeper.sleep(ns);
            slept += ns;
            continue;
        };
    }
}

/// Best-effort: delete EVERY staging sibling of `path` — the legacy fixed
/// `<path>.tmp` and any unique `<path>.<hex16>.tmp` a crashed writer left
/// behind. For a credential file that debris IS the credential, so its
/// single writer sweeps after each publish and on sign-out delete.
///
/// SINGLE-WRITER paths only: on a multi-writer path this would delete a
/// concurrent writer's in-flight staging file and fail its rename — the exact
/// T183 failure the unique names removed. That is why `writeChunks` itself
/// never sweeps.
pub fn cleanStaging(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var dir = std.fs.cwd().openDir(parent, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        if (entry.kind == .directory) continue;
        if (isStagingName(entry.name, base)) dir.deleteFile(entry.name) catch {};
    }
}

/// Whether `name` is a staging sibling of a file named `base`: exactly
/// `<base>.tmp` (legacy) or `<base>.<hex16>.tmp` (unique). Deliberately strict
/// so an unrelated neighbor like `<base>.bak.tmp` is never swept.
fn isStagingName(name: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, name, base)) return false;
    if (!std.mem.endsWith(u8, name, ".tmp")) return false;
    const mid = name[base.len .. name.len - ".tmp".len];
    if (mid.len == 0) return true; // legacy `<base>.tmp`
    if (mid.len != 17 or mid[0] != '.') return false;
    for (mid[1..]) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
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

    try writeChunks(alloc, path, &.{ "head", "-", "tail" }, .{});
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
    try writeChunks(alloc, path, &.{"again"}, .{});
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

    // On failure the error is RECORDED, not just a bool — T508 spent a soak
    // cycle blind because this test's catch discarded the error value.
    const Failure = struct {
        var err_name = std.atomic.Value(?[*:0]const u8).init(null);
    };
    const W = struct {
        fn run(a: Allocator, p: []const u8, fill: u8, failed: *std.atomic.Value(bool)) void {
            var body: [body_len]u8 = undefined;
            @memset(&body, fill);
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                writeChunks(a, p, &.{&body}, .{}) catch |err| {
                    Failure.err_name.store(@errorName(err).ptr, .seq_cst);
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
    if (failed.load(.seq_cst)) {
        std.debug.print("concurrent writeChunks failed: error.{s}\n", .{Failure.err_name.load(.seq_cst).?});
        return error.ConcurrentWriterErrored;
    }

    // The survivor is exactly ONE complete body.
    const got = try std.fs.cwd().readFileAlloc(alloc, path, body_len * 2);
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, body_len), got.len);
    for (got) |b| try testing.expectEqual(got[0], b);
}

/// Failure-injecting stand-in for `std.fs.Dir` in the retry tests: fails the
/// first `fail_count` renames with `err`, then succeeds.
const MockRenameDir = struct {
    fail_count: usize,
    err: anyerror = error.AccessDenied,
    calls: usize = 0,

    fn rename(self: *MockRenameDir, old: []const u8, new: []const u8) !void {
        _ = old;
        _ = new;
        self.calls += 1;
        if (self.calls <= self.fail_count) return self.err;
    }
};

/// Records requested sleeps instead of performing them, so the retry tests —
/// including exhausting the whole 5s budget — run in microseconds.
const RecordingSleeper = struct {
    total_ns: u64 = 0,
    fn sleep(self: *RecordingSleeper, ns: u64) void {
        self.total_ns += ns;
    }
};

test "renameWithRetry: transient AccessDenied is retried away (T508)" {
    var mock: MockRenameDir = .{ .fail_count = 3 };
    var sleeper: RecordingSleeper = .{};
    try renameWithRetry(&mock, &sleeper, "a.tmp", "a");
    try testing.expectEqual(@as(usize, 4), mock.calls);
    // Exponential opening: 1ms + 2ms + 4ms requested.
    try testing.expectEqual(@as(u64, 7 * std.time.ns_per_ms), sleeper.total_ns);
}

test "renameWithRetry: persistent transient error surfaces after the time budget" {
    var mock: MockRenameDir = .{ .fail_count = std.math.maxInt(usize) };
    var sleeper: RecordingSleeper = .{};
    try testing.expectError(error.AccessDenied, renameWithRetry(&mock, &sleeper, "a.tmp", "a"));
    // The whole budget was spent waiting before giving up — this is what
    // out-waits a stretched scan hold (measured up to ~786ms; see module doc).
    try testing.expect(sleeper.total_ns >= rename_retry_budget_ns);
    // …and not overspent by more than one capped backoff.
    try testing.expect(sleeper.total_ns < rename_retry_budget_ns + 50 * std.time.ns_per_ms);
    try testing.expect(mock.calls > 2);
}

test "renameWithRetry: a real error is never retried" {
    var mock: MockRenameDir = .{ .fail_count = std.math.maxInt(usize), .err = error.FileNotFound };
    var sleeper: RecordingSleeper = .{};
    try testing.expectError(error.FileNotFound, renameWithRetry(&mock, &sleeper, "a.tmp", "a"));
    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expectEqual(@as(u64, 0), sleeper.total_ns);
}

test "renameWithRetry: PathAlreadyExists counts as transient" {
    var mock: MockRenameDir = .{ .fail_count = 1, .err = error.PathAlreadyExists };
    var sleeper: RecordingSleeper = .{};
    try renameWithRetry(&mock, &sleeper, "a.tmp", "a");
    try testing.expectEqual(@as(usize, 2), mock.calls);
}

test "renameBackoffNs: exponential then capped at 50ms" {
    try testing.expectEqual(@as(u64, 1 * std.time.ns_per_ms), renameBackoffNs(1));
    try testing.expectEqual(@as(u64, 2 * std.time.ns_per_ms), renameBackoffNs(2));
    try testing.expectEqual(@as(u64, 32 * std.time.ns_per_ms), renameBackoffNs(6));
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), renameBackoffNs(7));
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), renameBackoffNs(100));
}

test "writeChunks: secret publishes mode 0600 on POSIX" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "cred.env" });
    defer alloc.free(path);

    try writeChunks(alloc, path, &.{"TOKEN=t\n"}, .{ .secret = true });
    const st = try std.fs.cwd().statFile(path);
    // Owner read/write only — the rename carried the staging file's mode.
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.mode & 0o777)));
}

test "isStagingName: matches legacy and unique names, nothing else" {
    try testing.expect(isStagingName("a.env.tmp", "a.env"));
    try testing.expect(isStagingName("a.env.0123456789abcdef.tmp", "a.env"));
    try testing.expect(isStagingName("a.env.ABCDEF0123456789.tmp", "a.env"));
    try testing.expect(!isStagingName("a.env", "a.env")); // the target itself
    try testing.expect(!isStagingName("a.env.bak.tmp", "a.env")); // not a nonce
    try testing.expect(!isStagingName("a.env.0123456789abcdeX.tmp", "a.env"));
    try testing.expect(!isStagingName("a.env.0123456789abcde.tmp", "a.env")); // 15 hex
    try testing.expect(!isStagingName("b.env.tmp", "a.env"));
    try testing.expect(!isStagingName("a.env.tmpx", "a.env"));
}

test "cleanStaging: sweeps legacy + unique debris, leaves target and neighbors" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "cred.env" });
    defer alloc.free(path);

    try tmp.dir.writeFile(.{ .sub_path = "cred.env", .data = "live" });
    try tmp.dir.writeFile(.{ .sub_path = "cred.env.tmp", .data = "legacy debris" });
    try tmp.dir.writeFile(.{ .sub_path = "cred.env.00112233aabbccdd.tmp", .data = "crash debris" });
    try tmp.dir.writeFile(.{ .sub_path = "cred.env.bak.tmp", .data = "not ours" });
    try tmp.dir.writeFile(.{ .sub_path = "other.env", .data = "not ours" });

    cleanStaging(path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next()) |entry| {
        seen += 1;
        const kept = std.mem.eql(u8, entry.name, "cred.env") or
            std.mem.eql(u8, entry.name, "cred.env.bak.tmp") or
            std.mem.eql(u8, entry.name, "other.env");
        try testing.expect(kept);
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // Idempotent, and fine on a path whose parent doesn't exist.
    cleanStaging(path);
    cleanStaging("definitely/not/a/real/dir/x.env");
}
