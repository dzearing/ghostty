//! Per-channel inbound ring + channel table (WP3 spike, §3.4 mini-spec).
//!
//! This is the one novel concurrency primitive the remote-machines feature
//! introduces, so the design gates it behind its own spike + benchmark before
//! WP3 fans out (§3.4/§17). The problem it solves: a single connection demux
//! thread reads framed `DATA` for N panes off one socket. If it applied each
//! frame inline (as Exec's `ReadThread` does today, `Exec.zig:1358`), a flooding
//! pane would head-of-line-block the quiet panes. The fix:
//!
//!   - One **SPSC byte ring per channel**. The connection's demux thread is the
//!     single *producer*; the pane's own IO thread is the single *consumer*
//!     (which then calls `processOutput` on its own thread, restoring per-pane
//!     parallelism — no cross-pane HOL).
//!   - The producer does a **non-blocking `push`** and is therefore never stalled
//!     by a full ring: on backpressure it sends `FLOW{pause}` for that channel and
//!     keeps servicing the others. The consumer sends `FLOW{resume}` once it has
//!     drained back below the low-water mark.
//!   - A `ChannelTable` (lock-protected) maps `channel_id → *Channel`. The
//!     **lock-ordering teardown invariant** (§3.4): the producer holds the table
//!     lock for the duration of a lookup+push, so a channel can never be freed out
//!     from under a push. Teardown order is *stop consumer → join pane IO thread →
//!     deregister under the table lock → free ring*.
//!
//! This module is standalone-testable (`zig test src/remote/inbound_ring.zig`);
//! it has no dependency on xev or the rest of the termio stack. The real WP3
//! wiring supplies a `Waker` backed by the pane's `xev.Async`; here the stress
//! harness backs it with a `std.Thread.ResetEvent`. The ring stores raw decoded
//! child-output bytes (the same stream the §4.2 `byte_offset` counts).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

/// Default ring capacity: 256 KiB. Sized ≥ the 64 KiB data-channel window (§4.3)
/// so a full in-flight window fits even after `FLOW{pause}` is sent, without the
/// producer ever having to block. Must be a power of two (index masking).
pub const default_capacity: usize = 256 * 1024;

/// Default high-water mark: pause when occupancy reaches `capacity - 64 KiB`, so
/// the remaining headroom absorbs a full window already in flight when the pause
/// is sent (§3.4).
pub const default_high_water: usize = default_capacity - 64 * 1024;

/// Default low-water mark: resume once the consumer has drained back to 16 KiB
/// (§3.4). The gap between the two marks gives hysteresis so a busy channel
/// doesn't thrash pause/resume frames.
pub const default_low_water: usize = 16 * 1024;

// -----------------------------------------------------------------------------
// Waker — abstracts the pane's wakeup mechanism
// -----------------------------------------------------------------------------

/// How the producer wakes a sleeping consumer. In WP3 proper this wraps the
/// pane's existing `xev.Async` (edge-triggered notify); the stress harness wraps
/// a `std.Thread.ResetEvent`. Modeling it as a tiny vtable keeps this module free
/// of an xev dependency.
pub const Waker = struct {
    ctx: *anyopaque,
    wakeFn: *const fn (*anyopaque) void,

    pub fn wake(self: Waker) void {
        self.wakeFn(self.ctx);
    }

    /// A no-op waker, for tests that drain synchronously.
    pub const noop: Waker = .{ .ctx = undefined, .wakeFn = noopWake };
    fn noopWake(_: *anyopaque) void {}
};

// -----------------------------------------------------------------------------
// InboundRing — lock-free SPSC byte ring
// -----------------------------------------------------------------------------

/// A single-producer / single-consumer byte ring. The producer (connection demux
/// thread) calls `push`; the consumer (pane IO thread) calls `pop`. The two sides
/// synchronize only through the atomic `head`/`tail` cursors with acquire/release
/// ordering — no lock on the hot path. Lifetime safety against teardown is
/// provided by the `ChannelTable` lock, not by the ring.
pub const InboundRing = struct {
    buf: []u8,
    /// `capacity - 1`; capacity is a power of two so `idx & mask` wraps.
    mask: usize,

    /// Absolute (monotonic, wrapping) producer cursor. Only the producer stores
    /// it; the consumer loads it to learn how much is available.
    tail: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    /// Absolute (monotonic, wrapping) consumer cursor. Only the consumer stores
    /// it; the producer loads it to learn how much is free. Placed on its own
    /// cache line to avoid false sharing with `tail`.
    head: Atomic(usize) align(std.atomic.cache_line) = .init(0),

    pub fn init(alloc: Allocator, cap: usize) Allocator.Error!InboundRing {
        assert(cap >= 2);
        assert(std.math.isPowerOfTwo(cap));
        const buf = try alloc.alloc(u8, cap);
        return .{ .buf = buf, .mask = cap - 1 };
    }

    pub fn deinit(self: *InboundRing, alloc: Allocator) void {
        alloc.free(self.buf);
        self.* = undefined;
    }

    pub fn capacity(self: *const InboundRing) usize {
        return self.mask + 1;
    }

    /// Current occupancy in bytes. Safe to call from either side (used for the
    /// water marks); the value is a consistent snapshot for the calling side.
    pub fn len(self: *const InboundRing) usize {
        const t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        return t -% h;
    }

    pub fn freeLen(self: *const InboundRing) usize {
        return self.capacity() - self.len();
    }

    pub fn isEmpty(self: *const InboundRing) bool {
        return self.tail.load(.acquire) == self.head.load(.acquire);
    }

    /// Producer side. Copy as many of `bytes` as fit into free space and return
    /// the count written (may be `< bytes.len`, or 0, when the ring is full —
    /// never blocks). The caller retains the unwritten remainder and is expected
    /// to send `FLOW{pause}` (see `Channel.push`).
    pub fn push(self: *InboundRing, bytes: []const u8) usize {
        const t = self.tail.load(.monotonic); // producer owns tail
        const h = self.head.load(.acquire); // observe consumer progress
        const free = self.capacity() - (t -% h);
        const n = @min(free, bytes.len);
        if (n == 0) return 0;

        const start = t & self.mask;
        const first = @min(n, self.capacity() - start);
        @memcpy(self.buf[start..][0..first], bytes[0..first]);
        if (n > first) @memcpy(self.buf[0 .. n - first], bytes[first..n]);

        self.tail.store(t +% n, .release); // publish data
        return n;
    }

    /// Consumer side. Copy up to `dst.len` bytes out and return the count read
    /// (may be 0 when empty). Never blocks.
    pub fn pop(self: *InboundRing, dst: []u8) usize {
        const h = self.head.load(.monotonic); // consumer owns head
        const t = self.tail.load(.acquire); // observe producer progress
        const avail = t -% h;
        const n = @min(avail, dst.len);
        if (n == 0) return 0;

        const start = h & self.mask;
        const first = @min(n, self.capacity() - start);
        @memcpy(dst[0..first], self.buf[start..][0..first]);
        if (n > first) @memcpy(dst[first..n], self.buf[0 .. n - first]);

        self.head.store(h +% n, .release); // publish free space
        return n;
    }
};

// -----------------------------------------------------------------------------
// Channel — a ring plus its flow-control state + consumer waker
// -----------------------------------------------------------------------------

/// What the producer must do after a `push`: how many bytes landed and whether
/// this push crossed the high-water mark and should emit `FLOW{pause}`.
pub const PushResult = struct {
    written: usize,
    /// True exactly once per flowing→paused transition (edge-triggered) so the
    /// caller emits a single `FLOW{pause}` per episode.
    send_pause: bool,
};

/// What the consumer must do after a `pop`: how many bytes it got and whether
/// this drain crossed back under the low-water mark and should emit
/// `FLOW{resume}`.
pub const PopResult = struct {
    read: usize,
    /// True exactly once per paused→flowing transition (edge-triggered).
    send_resume: bool,
};

/// A per-pane channel: its inbound ring, its flow-pause flag, its water marks,
/// and the waker that nudges the pane's IO thread after a push. Owned by the pane
/// (freed only after the pane's IO thread has joined — see the teardown invariant
/// in `ChannelTable`).
pub const Channel = struct {
    id: u128,
    ring: InboundRing,
    waker: Waker,
    high_water: usize,
    low_water: usize,

    /// Flow-pause state. Written by the producer (false→true at high-water) and
    /// the consumer (true→false at low-water), so it is atomic and transitions
    /// are claimed via CAS to make each `FLOW` edge fire exactly once.
    paused: Atomic(bool) = .init(false),

    pub const InitOptions = struct {
        capacity: usize = default_capacity,
        /// Pause threshold; defaults to `capacity * 3/4` (== 192 KiB at the
        /// 256 KiB default capacity, matching `default_high_water`).
        high_water: ?usize = null,
        /// Resume threshold; defaults to `capacity / 16` (== 16 KiB at the
        /// 256 KiB default capacity, matching `default_low_water`).
        low_water: ?usize = null,
        waker: Waker = Waker.noop,
    };

    pub fn init(alloc: Allocator, id: u128, opts: InitOptions) Allocator.Error!Channel {
        const high = opts.high_water orelse opts.capacity * 3 / 4;
        const low = opts.low_water orelse opts.capacity / 16;
        assert(low < high);
        assert(high <= opts.capacity);
        return .{
            .id = id,
            .ring = try InboundRing.init(alloc, opts.capacity),
            .waker = opts.waker,
            .high_water = high,
            .low_water = low,
        };
    }

    pub fn deinit(self: *Channel, alloc: Allocator) void {
        self.ring.deinit(alloc);
        self.* = undefined;
    }

    /// Producer entry point. Pushes (non-blocking), wakes the consumer if any
    /// bytes landed, and reports whether to send `FLOW{pause}`.
    pub fn push(self: *Channel, bytes: []const u8) PushResult {
        const written = self.ring.push(bytes);
        if (written > 0) self.waker.wake();

        var send_pause = false;
        if (self.ring.len() >= self.high_water) {
            // Claim the flowing→paused edge: CAS succeeds (returns null) for the
            // single producer that first crosses high-water.
            if (self.paused.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
                send_pause = true;
            }
        }
        return .{ .written = written, .send_pause = send_pause };
    }

    /// Consumer entry point. Pops into `dst` and reports whether to send
    /// `FLOW{resume}` now that the ring has drained.
    pub fn pop(self: *Channel, dst: []u8) PopResult {
        const read = self.ring.pop(dst);
        var send_resume = false;
        if (read > 0 and self.ring.len() <= self.low_water) {
            if (self.paused.cmpxchgStrong(true, false, .acq_rel, .monotonic) == null) {
                send_resume = true;
            }
        }
        return .{ .read = read, .send_resume = send_resume };
    }

    pub fn isPaused(self: *const Channel) bool {
        return self.paused.load(.acquire);
    }
};

// -----------------------------------------------------------------------------
// ChannelTable — the lock-protected registry (lifetime / teardown invariant)
// -----------------------------------------------------------------------------

/// Maps `channel_id → *Channel` for one connection. The map is guarded by `mutex`.
/// The crucial invariant (§3.4): the producer holds `mutex` for the *entire*
/// lookup+push, and deregistration also takes `mutex`, so the producer can never
/// push into a `Channel` that is being torn down. The table does **not** own the
/// `Channel` storage — the pane does — so `deregister` only unlinks; the pane
/// frees the ring after its IO thread has joined.
pub const ChannelTable = struct {
    mutex: std.Thread.Mutex = .{},
    map: std.AutoHashMapUnmanaged(u128, *Channel) = .empty,
    alloc: Allocator,

    pub fn init(alloc: Allocator) ChannelTable {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ChannelTable) void {
        self.map.deinit(self.alloc);
        self.* = undefined;
    }

    /// Register a pane's channel. The pointer must outlive every `pushTo` until
    /// `deregister` returns (guaranteed by the teardown order).
    pub fn register(self: *ChannelTable, ch: *Channel) Allocator.Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(self.alloc, ch.id, ch);
    }

    /// Unlink a channel. After this returns, no in-flight `pushTo` can be touching
    /// it (both hold `mutex`), so the caller may free the `Channel` — but only
    /// after its consumer IO thread has been joined (teardown order).
    pub fn deregister(self: *ChannelTable, id: u128) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(id);
    }

    pub fn count(self: *ChannelTable) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }

    /// The result of routing a frame's bytes to a channel.
    pub const RouteResult = union(enum) {
        /// No such channel (already torn down, or a hostile/stale `channel` id —
        /// §15 M3). The demux drops the frame; never a crash.
        unknown,
        /// Routed; carries the push outcome (written count + pause edge).
        routed: PushResult,
    };

    /// Producer entry point: look up `id` and push under the table lock so the
    /// `Channel` cannot be freed mid-push (the load-bearing teardown invariant).
    /// IMPORTANT: nothing else may be locked while `mutex` is held that could in
    /// turn be held while waiting on the renderer mutex — the push path takes no
    /// other lock, preserving the §3.4 lock ordering (no inversion).
    pub fn pushTo(self: *ChannelTable, id: u128, bytes: []const u8) RouteResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ch = self.map.get(id) orelse return .unknown;
        return .{ .routed = ch.push(bytes) };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "InboundRing: single-threaded push/pop round-trip with wrap" {
    const alloc = testing.allocator;
    var ring = try InboundRing.init(alloc, 16); // tiny, forces wrap
    defer ring.deinit(alloc);

    try testing.expect(ring.isEmpty());
    try testing.expectEqual(@as(usize, 16), ring.freeLen());

    // Push 10, pop 10, repeatedly — exercises the wrap boundary every round.
    var seed: u8 = 0;
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        var src: [10]u8 = undefined;
        for (&src) |*b| {
            b.* = seed;
            seed +%= 1;
        }
        try testing.expectEqual(@as(usize, 10), ring.push(&src));

        var dst: [10]u8 = undefined;
        try testing.expectEqual(@as(usize, 10), ring.pop(&dst));
        try testing.expectEqualSlices(u8, &src, &dst);
    }
}

test "InboundRing: push is bounded by free space (no overrun)" {
    const alloc = testing.allocator;
    var ring = try InboundRing.init(alloc, 8);
    defer ring.deinit(alloc);

    const big = "0123456789ABCDEF"; // 16 bytes into an 8-byte ring
    try testing.expectEqual(@as(usize, 8), ring.push(big)); // only 8 fit
    try testing.expectEqual(@as(usize, 0), ring.freeLen());
    try testing.expectEqual(@as(usize, 0), ring.push("x")); // full → 0

    var dst: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), ring.pop(&dst));
    try testing.expectEqualSlices(u8, "01234567", &dst);
}

test "Channel: flow pause/resume edges fire exactly once each" {
    const alloc = testing.allocator;
    var ch = try Channel.init(alloc, 1, .{
        .capacity = 1024,
        .high_water = 768,
        .low_water = 128,
    });
    defer ch.deinit(alloc);

    const block = [_]u8{0} ** 256;

    // Push up to just under high-water: no pause yet.
    _ = ch.push(&block); // 256
    _ = ch.push(&block); // 512
    try testing.expect(!ch.isPaused());

    // This push reaches 768 == high-water → exactly one pause edge.
    const r1 = ch.push(&block); // 768
    try testing.expect(r1.send_pause);
    try testing.expect(ch.isPaused());

    // Further pushes while paused do NOT re-emit pause.
    const r2 = ch.push(&block); // 1024 (full)
    try testing.expect(!r2.send_pause);

    // Drain toward low-water. The pop that brings occupancy to <=128 emits one
    // resume edge; subsequent pops do not.
    var dst: [256]u8 = undefined;
    var resumes: usize = 0;
    while (!ch.ring.isEmpty()) {
        const p = ch.pop(&dst);
        if (p.send_resume) resumes += 1;
    }
    try testing.expectEqual(@as(usize, 1), resumes);
    try testing.expect(!ch.isPaused());
}

test "ChannelTable: register / route / deregister; unknown id is graceful" {
    const alloc = testing.allocator;
    var table = ChannelTable.init(alloc);
    defer table.deinit();

    var ch = try Channel.init(alloc, 0xABCD, .{ .capacity = 64 });
    defer ch.deinit(alloc);

    // Routing before registration → unknown (no crash), models a stale/hostile
    // channel id (§15 M3).
    try testing.expect(table.pushTo(0xABCD, "hi") == .unknown);

    try table.register(&ch);
    try testing.expectEqual(@as(usize, 1), table.count());

    const res = table.pushTo(0xABCD, "hello");
    try testing.expect(res == .routed);
    try testing.expectEqual(@as(usize, 5), res.routed.written);

    table.deregister(0xABCD);
    try testing.expectEqual(@as(usize, 0), table.count());
    // After deregister, routing is unknown again (the pane will free `ch` only
    // after its consumer thread has joined — teardown order §3.4).
    try testing.expect(table.pushTo(0xABCD, "x") == .unknown);
}

// --- Concurrent SPSC integrity ------------------------------------------------

const SpscCtx = struct {
    ring: *InboundRing,
    total: usize,
};

fn spscProducer(ctx: *SpscCtx) void {
    var produced: usize = 0;
    while (produced < ctx.total) {
        // Pattern byte = low 8 bits of the absolute stream position.
        var chunk: [997]u8 = undefined; // odd size to misalign with capacity
        const want = @min(chunk.len, ctx.total - produced);
        for (0..want) |i| chunk[i] = @truncate(produced + i);
        var off: usize = 0;
        while (off < want) {
            const n = ctx.ring.push(chunk[off..want]);
            off += n;
            if (n == 0) std.Thread.yield() catch {};
        }
        produced += want;
    }
}

test "InboundRing: concurrent SPSC streams 4 MiB without loss or corruption" {
    const alloc = testing.allocator;
    var ring = try InboundRing.init(alloc, 4096); // small ring, lots of backpressure
    defer ring.deinit(alloc);

    const total: usize = 4 * 1024 * 1024;
    var ctx: SpscCtx = .{ .ring = &ring, .total = total };

    const producer = try std.Thread.spawn(.{}, spscProducer, .{&ctx});

    // Consumer runs on this thread: verify every byte matches its stream position.
    var consumed: usize = 0;
    var dst: [577]u8 = undefined; // odd size, different from producer chunk
    while (consumed < total) {
        const n = ring.pop(&dst);
        if (n == 0) {
            std.Thread.yield() catch {};
            continue;
        }
        for (0..n) |i| {
            const expected: u8 = @truncate(consumed + i);
            try testing.expectEqual(expected, dst[i]);
        }
        consumed += n;
    }
    producer.join();
    try testing.expectEqual(total, consumed);
}

// --- The headline test: 4 channels, one firehose, no cross-pane HOL ----------

/// A ResetEvent-backed waker so the harness models the pane's `xev.Async`.
const EventWaker = struct {
    event: std.Thread.ResetEvent = .{},
    fn waker(self: *EventWaker) Waker {
        return .{ .ctx = self, .wakeFn = wakeImpl };
    }
    fn wakeImpl(ctx: *anyopaque) void {
        const self: *EventWaker = @ptrCast(@alignCast(ctx));
        self.event.set();
    }
};

const PaneConsumer = struct {
    ch: *Channel,
    waker: *EventWaker,
    quota: usize,
    // Drain gate: a slow pane waits on this before it starts draining, modeling
    // a deprioritized/congested pane. The firehose pane uses it to prove the
    // single-producer demux still services the quiet panes while it is blocked.
    gate: ?*std.Thread.ResetEvent,
    // Outputs:
    received: usize = 0,
    corrupt: bool = false,
    resume_edges: usize = 0,

    fn run(self: *PaneConsumer) void {
        if (self.gate) |g| g.wait(); // congested pane: wait before draining

        var dst: [8192]u8 = undefined;
        while (self.received < self.quota) {
            const p = self.ch.pop(&dst);
            if (p.read == 0) {
                self.waker.event.timedWait(2 * std.time.ns_per_ms) catch {};
                self.waker.event.reset();
                continue;
            }
            if (p.send_resume) self.resume_edges += 1;
            // Verify the per-channel byte pattern (continuity == no loss/reorder).
            for (0..p.read) |i| {
                const expected: u8 = @truncate(self.received + i);
                if (dst[i] != expected) {
                    self.corrupt = true;
                    return;
                }
            }
            self.received += p.read;
        }
    }
};

test "stress: 4 channels, one firehose, quiet panes are not HOL-blocked" {
    const alloc = testing.allocator;

    // Channel 0 is the firehose with a *gated* (congested) consumer; channels
    // 1..3 are quiet with fast consumers. A naive *blocking* producer would stall
    // inside channel 0's full ring and never service the quiet panes — and since
    // channel 0's consumer only starts draining after the quiet panes finish,
    // that design would deadlock this exact harness. The non-blocking `push` here
    // keeps the single demux thread servicing every channel, so it completes.
    const n_channels = 4;
    const fire_quota: usize = 1024 * 1024; // 1 MiB firehose
    const quiet_quota: usize = 256 * 1024; // 256 KiB each

    var channels: [n_channels]Channel = undefined;
    var wakers: [n_channels]EventWaker = .{ .{}, .{}, .{}, .{} };
    for (&channels, 0..) |*c, i| {
        c.* = try Channel.init(alloc, @intCast(i + 1), .{
            .capacity = default_capacity,
            .waker = wakers[i].waker(),
        });
    }
    defer for (&channels) |*c| c.deinit(alloc);

    // The firehose consumer waits on this gate until the quiet panes are done.
    var fire_gate: std.Thread.ResetEvent = .{};

    var consumers: [n_channels]PaneConsumer = undefined;
    for (&consumers, 0..) |*pc, i| {
        pc.* = .{
            .ch = &channels[i],
            .waker = &wakers[i],
            .quota = if (i == 0) fire_quota else quiet_quota,
            .gate = if (i == 0) &fire_gate else null,
        };
    }

    var threads: [n_channels]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, PaneConsumer.run, .{&consumers[i]});
    }

    // The single demux/producer thread (this thread). Round-robin generate data
    // for all channels; never block on a full ring — hold the remainder and move
    // on (exactly what `FLOW{pause}` + "service the others" does in WP3).
    var produced: [n_channels]usize = .{0} ** n_channels;
    var pending: [n_channels]usize = .{0} ** n_channels; // bytes generated, not yet pushed
    var scratch: [n_channels][8192]u8 = undefined;
    var pause_edges: usize = 0;
    var quiet_done_announced = false;

    const quotas = [n_channels]usize{ fire_quota, quiet_quota, quiet_quota, quiet_quota };

    while (true) {
        var all_done = true;
        for (0..n_channels) |i| {
            const quota = quotas[i];
            // (Re)fill this channel's pending chunk from its quota if empty.
            if (pending[i] == 0 and produced[i] < quota) {
                const want = @min(scratch[i].len, quota - produced[i]);
                for (0..want) |k| scratch[i][k] = @truncate(produced[i] + k);
                pending[i] = want;
            }
            if (pending[i] > 0) {
                const chunk = scratch[i][0..pending[i]];
                const res = channels[i].push(chunk);
                if (res.send_pause) pause_edges += 1;
                if (res.written > 0) {
                    // Shift remainder to the front of the scratch chunk.
                    const rem = pending[i] - res.written;
                    if (rem > 0) {
                        std.mem.copyForwards(
                            u8,
                            scratch[i][0..rem],
                            scratch[i][res.written..pending[i]],
                        );
                    }
                    pending[i] = rem;
                    produced[i] += res.written;
                }
            }
            if (produced[i] < quota or pending[i] > 0) all_done = false;
        }

        // Once the three quiet channels are fully pushed, release the firehose
        // consumer so it can drain channel 0 and let the producer finish it.
        if (!quiet_done_announced and
            produced[1] == quiet_quota and pending[1] == 0 and
            produced[2] == quiet_quota and pending[2] == 0 and
            produced[3] == quiet_quota and pending[3] == 0)
        {
            quiet_done_announced = true;
            fire_gate.set();
        }

        if (all_done) break;
        // If we couldn't push anything this round (all rings full), yield so the
        // consumers make progress instead of spinning hot.
        std.Thread.yield() catch {};
    }

    // Safety: if the quiet channels somehow never completed, still release the
    // gate so consumer threads can exit rather than hang the test.
    fire_gate.set();

    for (&threads) |t| t.join();

    // Every channel delivered its full quota with an intact byte pattern: proves
    // no loss, no reorder, and — critically — that the quiet panes completed
    // despite the firehose congestion (no cross-pane head-of-line blocking).
    for (&consumers, 0..) |*pc, i| {
        try testing.expect(!pc.corrupt);
        try testing.expectEqual(quotas[i], pc.received);
    }
    // The quiet panes were announced done before the firehose was even allowed to
    // drain — the structural proof that they were not HOL-blocked.
    try testing.expect(quiet_done_announced);
    // The firehose channel filled its ring and exercised the pause path.
    try testing.expect(pause_edges > 0);
}
