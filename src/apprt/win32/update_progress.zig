//! Pure model behind the update-download progress panel (T1195).
//!
//! Before this, consenting to an update on the `auto-update = check` path
//! produced ONE tray balloon — "Downloading the update…" — and then nothing
//! until the app either restarted into the new build or said the download had
//! failed. Tens of megabytes on a slow link is a long silence, and a silence
//! is the one thing a stall and a slow transfer look identical through. Mac
//! shows a progress bar for exactly this stretch.
//!
//! Everything here is OS-free so it runs in every lane: the byte formatting,
//! the fraction the bar fills to, the sentence under it, and — the part that
//! answers "stalled or just slow?" — a tracker that watches the received
//! count rather than the clock. A download that is merely slow keeps moving
//! the count; one that has stopped does not, and after `stall_after_ms` of no
//! movement the panel says so instead of continuing to imply progress.
//!
//! `UpdateProgress.zig` owns the window, the timer and the paint.

const std = @import("std");

/// How the download ended, as seen from the GUI thread. Written by the
/// download worker, read by the panel's timer.
pub const Outcome = enum(u32) {
    running = 0,
    ok = 1,
    failed = 2,
};

/// The cross-thread handoff: the worker publishes bytes as they arrive, the
/// panel reads them on its timer. Deliberately atomics rather than a mutex —
/// there is nothing to keep consistent between the fields (a snapshot that
/// pairs this tick's `received` with last tick's `total` is still a truthful
/// frame), and the worker must never block on the GUI thread's paint.
///
/// Both sides hold a reference: whichever finishes last frees it. The worker
/// can outlive the panel (the user closes the window) and the panel can
/// outlive the worker (the download finishes while the panel is still
/// showing its last frame), so neither may own it outright.
pub const Shared = struct {
    received: std.atomic.Value(u64) = .{ .raw = 0 },
    /// 0 means the server did not send a Content-Length — an honest "we do
    /// not know how big this is", which the panel renders as an
    /// indeterminate bar rather than a made-up percentage.
    total: std.atomic.Value(u64) = .{ .raw = 0 },
    outcome: std.atomic.Value(u32) = .{ .raw = @intFromEnum(Outcome.running) },
    refs: std.atomic.Value(u32) = .{ .raw = 2 },

    pub fn report(self: *Shared, received: u64, total: u64) void {
        self.total.store(total, .monotonic);
        self.received.store(received, .monotonic);
    }

    pub fn finish(self: *Shared, outcome: Outcome) void {
        self.outcome.store(@intFromEnum(outcome), .release);
    }

    pub fn snapshot(self: *const Shared) Snapshot {
        const raw = self.outcome.load(.acquire);
        const total = self.total.load(.monotonic);
        return .{
            .received = self.received.load(.monotonic),
            .total = if (total == 0) null else total,
            .outcome = std.meta.intToEnum(Outcome, raw) catch .running,
        };
    }

    /// Drop this side's reference, freeing when the other side is already
    /// gone. Safe to call from either thread, exactly once per holder.
    pub fn release(self: *Shared, alloc: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) alloc.destroy(self);
    }
};

pub const Snapshot = struct {
    received: u64,
    total: ?u64,
    outcome: Outcome,
};

/// No bytes for this long, and the panel stops implying the download is
/// moving. Ten seconds is long enough that a slow-but-alive transfer over a
/// bad link is never accused (a 256 KiB read at 30 KB/s is ~9s), and short
/// enough that a dead socket is called out while the user is still watching.
pub const stall_after_ms: i64 = 10_000;

/// Watches the received count for movement. Purely a function of the counts
/// it has been shown and when — no wall-clock reading of its own, so the
/// tests drive it with an explicit clock.
pub const StallTracker = struct {
    seen: u64 = 0,
    /// When `seen` last changed. Zero until the first observation, which is
    /// what keeps a panel that opened before the first byte from being
    /// declared stalled against a clock it never started.
    since_ms: i64 = 0,
    started: bool = false,

    pub fn observe(self: *StallTracker, received: u64, now_ms: i64) void {
        if (!self.started or received != self.seen) {
            self.started = true;
            self.seen = received;
            self.since_ms = now_ms;
        }
    }

    /// Milliseconds since the count last moved (0 before the first
    /// observation, so an unstarted tracker never reads as stalled).
    pub fn idleMs(self: *const StallTracker, now_ms: i64) i64 {
        if (!self.started) return 0;
        return @max(0, now_ms - self.since_ms);
    }

    pub fn stalled(self: *const StallTracker, now_ms: i64) bool {
        return self.idleMs(now_ms) >= stall_after_ms;
    }
};

/// The 0..1 fraction the bar fills to, or null when the total is unknown
/// (the caller draws an indeterminate bar). Clamped: a server that
/// under-reports Content-Length must not produce a bar wider than its track.
pub fn fraction(received: u64, total: ?u64) ?f32 {
    const t = total orelse return null;
    if (t == 0) return null;
    const f = @as(f64, @floatFromInt(received)) / @as(f64, @floatFromInt(t));
    return @floatCast(std.math.clamp(f, 0.0, 1.0));
}

/// Whole percent for the panel's caption, or null when unknown.
pub fn percent(received: u64, total: ?u64) ?u8 {
    const f = fraction(received, total) orelse return null;
    return @intFromFloat(@round(f * 100.0));
}

/// Filled width in pixels for a determinate bar. A non-zero fraction always
/// paints at least one pixel — a bar that reads "0%" while bytes are landing
/// is the same lie the balloon told.
pub fn fillWidth(track_w: i32, frac: ?f32) i32 {
    const f = frac orelse return 0;
    if (track_w <= 0) return 0;
    const w: i32 = @intFromFloat(@round(f * @as(f32, @floatFromInt(track_w))));
    if (w <= 0 and f > 0) return 1;
    return @min(track_w, w);
}

/// Left edge of the marquee chip for an indeterminate bar, given a monotonic
/// tick. It bounces rather than wrapping, so the chip never appears to jump
/// backwards across the track's edge.
pub fn marqueeX(track_w: i32, chip_w: i32, tick: u64) i32 {
    const span = track_w - chip_w;
    if (span <= 0) return 0;
    const period: u64 = @intCast(span * 2);
    const p: i64 = @intCast(tick % period);
    return if (p <= span) @intCast(p) else @intCast(period - @as(u64, @intCast(p)));
}

/// "12.4 MB" / "812 KB" / "48 bytes". One decimal above a megabyte because
/// that is the digit that visibly moves during a download.
pub fn formatBytes(buf: []u8, n: u64) []const u8 {
    const mb = 1024 * 1024;
    const kb = 1024;
    if (n >= mb) {
        const v = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(mb));
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{v}) catch "?";
    }
    if (n >= kb) {
        return std.fmt.bufPrint(buf, "{d} KB", .{n / kb}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} bytes", .{n}) catch "?";
}

/// The sentence under the bar. This is the whole of the panel's language, so
/// the three states it has to keep apart live in one place: moving, stopped,
/// and over.
pub fn statusLine(buf: []u8, snap: Snapshot, idle_ms: i64) []const u8 {
    switch (snap.outcome) {
        .ok => return std.fmt.bufPrint(buf, "Download complete.", .{}) catch "Download complete.",
        .failed => return std.fmt.bufPrint(
            buf,
            "The download failed. Ghoztty will keep the build you have.",
            .{},
        ) catch "The download failed.",
        .running => {},
    }

    var got_buf: [32]u8 = undefined;
    const got = formatBytes(&got_buf, snap.received);

    if (idle_ms >= stall_after_ms) {
        const secs = @divTrunc(idle_ms, 1000);
        return std.fmt.bufPrint(
            buf,
            "Stalled — no data for {d}s ({s} so far). Still waiting.",
            .{ secs, got },
        ) catch "Stalled.";
    }

    if (snap.total) |t| {
        var tot_buf: [32]u8 = undefined;
        const tot = formatBytes(&tot_buf, t);
        const pct = percent(snap.received, snap.total) orelse 0;
        return std.fmt.bufPrint(buf, "{s} of {s} ({d}%)", .{ got, tot, pct }) catch got;
    }
    return std.fmt.bufPrint(buf, "{s} downloaded", .{got}) catch got;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "fraction: unknown total is unknown, not zero" {
    try testing.expect(fraction(100, null) == null);
    try testing.expect(fraction(100, 0) == null);
}

test "fraction: clamped to the track" {
    try testing.expectApproxEqAbs(@as(f32, 0.5), fraction(50, 100).?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), fraction(500, 100).?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), fraction(0, 100).?, 0.001);
}

test "percent rounds to whole" {
    try testing.expectEqual(@as(u8, 50), percent(1, 2).?);
    try testing.expectEqual(@as(u8, 33), percent(1, 3).?);
    try testing.expectEqual(@as(u8, 100), percent(3, 3).?);
    try testing.expect(percent(3, null) == null);
}

test "fillWidth never paints zero while bytes are landing" {
    try testing.expectEqual(@as(i32, 0), fillWidth(200, null));
    try testing.expectEqual(@as(i32, 0), fillWidth(200, 0.0));
    try testing.expectEqual(@as(i32, 1), fillWidth(200, 0.001));
    try testing.expectEqual(@as(i32, 100), fillWidth(200, 0.5));
    try testing.expectEqual(@as(i32, 200), fillWidth(200, 1.0));
    try testing.expectEqual(@as(i32, 0), fillWidth(0, 0.5));
}

test "marqueeX bounces inside the track" {
    const track: i32 = 100;
    const chip: i32 = 20;
    // span = 80
    try testing.expectEqual(@as(i32, 0), marqueeX(track, chip, 0));
    try testing.expectEqual(@as(i32, 40), marqueeX(track, chip, 40));
    try testing.expectEqual(@as(i32, 80), marqueeX(track, chip, 80));
    try testing.expectEqual(@as(i32, 40), marqueeX(track, chip, 120));
    try testing.expectEqual(@as(i32, 0), marqueeX(track, chip, 160));
    // Never leaves the track, at any tick.
    var t: u64 = 0;
    while (t < 500) : (t += 1) {
        const x = marqueeX(track, chip, t);
        try testing.expect(x >= 0 and x + chip <= track);
    }
    // A chip as wide as the track has nowhere to go.
    try testing.expectEqual(@as(i32, 0), marqueeX(20, 20, 7));
}

test "formatBytes picks the unit that moves" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("48 bytes", formatBytes(&buf, 48));
    try testing.expectEqualStrings("1 KB", formatBytes(&buf, 1024));
    try testing.expectEqualStrings("812 KB", formatBytes(&buf, 812 * 1024));
    try testing.expectEqualStrings("1.0 MB", formatBytes(&buf, 1024 * 1024));
    try testing.expectEqualStrings("12.5 MB", formatBytes(&buf, 12 * 1024 * 1024 + 512 * 1024));
}

test "StallTracker: an unstarted tracker is never stalled" {
    var st: StallTracker = .{};
    try testing.expectEqual(@as(i64, 0), st.idleMs(1_000_000));
    try testing.expect(!st.stalled(1_000_000));
}

test "StallTracker: movement resets the clock, stillness does not" {
    var st: StallTracker = .{};
    st.observe(0, 1000);
    st.observe(0, 5000);
    try testing.expectEqual(@as(i64, 4000), st.idleMs(5000));
    try testing.expect(!st.stalled(5000));

    // Still no movement at 11s past the last change: stalled.
    try testing.expect(st.stalled(12_000));

    // A single byte lands — not stalled any more, clock restarts.
    st.observe(1, 12_500);
    try testing.expect(!st.stalled(12_500));
    try testing.expectEqual(@as(i64, 0), st.idleMs(12_500));
    try testing.expect(!st.stalled(22_499));
    try testing.expect(st.stalled(22_500));
}

test "StallTracker: a slow download that keeps moving is never stalled" {
    var st: StallTracker = .{};
    var now: i64 = 0;
    var got: u64 = 0;
    // 9 seconds between chunks — slow, but alive.
    while (now < 120_000) : (now += 9_000) {
        got += 4096;
        st.observe(got, now);
        try testing.expect(!st.stalled(now));
    }
}

test "statusLine: known total reads as progress" {
    var buf: [160]u8 = undefined;
    const line = statusLine(&buf, .{
        .received = 12 * 1024 * 1024,
        .total = 48 * 1024 * 1024,
        .outcome = .running,
    }, 0);
    try testing.expectEqualStrings("12.0 MB of 48.0 MB (25%)", line);
}

test "statusLine: unknown total says only what is known" {
    var buf: [160]u8 = undefined;
    const line = statusLine(&buf, .{
        .received = 3 * 1024 * 1024,
        .total = null,
        .outcome = .running,
    }, 0);
    try testing.expectEqualStrings("3.0 MB downloaded", line);
}

test "statusLine: a stall is not a slow download" {
    var buf: [160]u8 = undefined;
    const snap: Snapshot = .{
        .received = 12 * 1024 * 1024,
        .total = 48 * 1024 * 1024,
        .outcome = .running,
    };
    const slow = statusLine(&buf, snap, 9_000);
    try testing.expect(std.mem.indexOf(u8, slow, "Stalled") == null);

    var buf2: [160]u8 = undefined;
    const stuck = statusLine(&buf2, snap, 14_000);
    try testing.expectEqualStrings(
        "Stalled — no data for 14s (12.0 MB so far). Still waiting.",
        stuck,
    );
}

test "statusLine: terminal states replace the numbers" {
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("Download complete.", statusLine(&buf, .{
        .received = 1,
        .total = 1,
        .outcome = .ok,
    }, 0));
    const failed = statusLine(&buf, .{ .received = 1, .total = 9, .outcome = .failed }, 99_000);
    try testing.expect(std.mem.startsWith(u8, failed, "The download failed."));
}

test "Shared: publish and snapshot across the two sides" {
    var shared: Shared = .{};
    var snap = shared.snapshot();
    try testing.expectEqual(@as(u64, 0), snap.received);
    try testing.expect(snap.total == null);
    try testing.expectEqual(Outcome.running, snap.outcome);

    shared.report(1024, 4096);
    snap = shared.snapshot();
    try testing.expectEqual(@as(u64, 1024), snap.received);
    try testing.expectEqual(@as(u64, 4096), snap.total.?);

    // A server with no Content-Length keeps total unknown, not zero-sized.
    shared.report(2048, 0);
    snap = shared.snapshot();
    try testing.expect(snap.total == null);

    shared.finish(.ok);
    try testing.expectEqual(Outcome.ok, shared.snapshot().outcome);
}

test "Shared: the last holder frees it" {
    const alloc = testing.allocator;
    const shared = try alloc.create(Shared);
    shared.* = .{};
    // Two holders; the allocator's leak check is the assertion.
    shared.release(alloc);
    shared.release(alloc);
}
