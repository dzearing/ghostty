//! Env-gated (`GHOZTTY_PERF`) throughput meters for the **relay**: the trip a
//! byte of child output takes from the ConPTY read inside a pty holder, across
//! two named pipes, to `termio/Remote.feedSliced` in the app (T1464).
//!
//! ## Why this exists
//!
//! T1458 instrumented what happens *after* the bytes arrive (`perf agent_feed`
//! — parse, lock, yield) and T1463 used it to measure, on an optimized build,
//! that the same workload takes **6.1 s with a local ConPTY and 12.8 s when the
//! PTY is held by `ghoztty-agent`**, with an identical parse cost in both. So
//! the ~6.5 s the agent path adds is the trip itself — and the trip had no
//! instrument at all. Every hypothesis about it (framing overhead, a
//! round-trip per message, a thread hop) was indistinguishable from the others
//! because nothing counted a frame or timed a pipe write anywhere along it.
//!
//! A `Meter` is that count. Three of them bracket the whole path, and the app's
//! existing `perf agent_feed` line is the fourth point:
//!
//! ```
//!   ConPTY ──> holder_out ──pipe──> holder_in ──> relay_out ──pipe──> agent_feed
//!             (pty_host)          (pty_holder_child)  (server)        (Remote)
//! ```
//!
//! Each line reports once a wall-clock second, in the same shape as
//! `perf agent_feed` so the four are directly comparable: rates per second, and
//! durations as **milliseconds per wall-clock second** (500 reads as "half of
//! every second went here").
//!
//! ## Threading
//!
//! A `Meter` is plain data with no synchronization: each one is owned by ONE
//! loop thread (a holder's writer, an owner's reader, the agent's writer) and
//! is only ever touched from it. That is the same contract `feed_telemetry` in
//! `termio/Remote.zig` has via `threadlocal`; here the meter lives beside the
//! loop's other locals instead, because a holder process can serve more than
//! one connection and each connection's writer wants its own window.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.relay_perf);

/// Process-wide `GHOZTTY_PERF` answer, resolved once. Reading the environment
/// on every frame at 10-20k frames/s would itself be a cost worth measuring,
/// which is exactly the shape this file exists to avoid.
var enabled_cache: ?bool = null;

/// Whether relay telemetry is on for this process.
pub fn isOn() bool {
    return enabled_cache orelse on: {
        const on = std.process.hasNonEmptyEnvVarConstant("GHOZTTY_PERF");
        enabled_cache = on;
        break :on on;
    };
}

// -----------------------------------------------------------------------------
// Where the lines go
// -----------------------------------------------------------------------------
//
// The app's telemetry reaches a reader because the app's stderr is redirected by
// whoever launched it. Nothing redirects the AGENT's, and nothing at all
// launches a pty HOLDER except the agent - so two of the three legs of the relay
// would log into a handle that goes nowhere, which is the same as not measuring
// them. `GHOZTTY_RELAY_PERF_DIR` names a directory to ALSO append these lines
// to, one file per process (`relay-perf-<pid>.log`), and both the agent and its
// holders inherit it from the app that spawned them. Unset (every ordinary run)
// costs one null check per report.

/// Resolved once, like `enabled_cache`: null when unset or unusable.
var sink: ?std.fs.File = null;
var sink_resolved: bool = false;
var sink_mutex: std.Thread.Mutex = .{};

pub const dir_env_var = "GHOZTTY_RELAY_PERF_DIR";

/// This process's id, for the per-process file name.
fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

/// The append sink, or null when `GHOZTTY_RELAY_PERF_DIR` is unset or the file
/// cannot be opened. Resolved once; a failure is remembered as "no sink" rather
/// than retried on every report.
fn sinkFile() ?std.fs.File {
    sink_mutex.lock();
    defer sink_mutex.unlock();
    if (sink_resolved) return sink;
    sink_resolved = true;

    var env_buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&env_buf);
    const dir = std.process.getEnvVarOwned(fba.allocator(), dir_env_var) catch return null;
    if (dir.len == 0) return null;

    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}{c}relay-perf-{d}.log",
        .{ dir, std.fs.path.sep, currentPid() },
    ) catch return null;

    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return null;
    f.seekFromEnd(0) catch {};
    sink = f;
    return sink;
}

/// Append one already-formatted line to the sink, if there is one.
fn appendToSink(line: []const u8) void {
    const f = sinkFile() orelse return;
    sink_mutex.lock();
    defer sink_mutex.unlock();
    f.writeAll(line) catch {};
    f.writeAll("\n") catch {};
}

/// A one-second rate window over one leg of the relay.
///
/// `frames` and `bytes` are what crossed; `batches` is how many times the loop
/// woke and did work (so `frames / batches` says whether the leg is carrying
/// the stream one message at a time or coalescing it); `io_ns` is time spent
/// inside the pipe syscalls themselves.
pub const Meter = struct {
    /// Names the leg on the log line (`perf <label> ...`).
    label: []const u8,

    window: ?std.time.Instant = null,
    frames: u64 = 0,
    bytes: u64 = 0,
    batches: u64 = 0,
    io_ns: u64 = 0,

    pub fn init(label: []const u8) Meter {
        return .{ .label = label };
    }

    /// Start stamp for an interval, or null when telemetry is off — which is
    /// also the signal that `stop` will do nothing.
    pub fn start(_: *Meter) ?std.time.Instant {
        if (!isOn()) return null;
        return std.time.Instant.now() catch null;
    }

    /// Accumulate a pipe-syscall interval opened by `start`.
    pub fn stop(self: *Meter, from: ?std.time.Instant) void {
        const s = from orelse return;
        const end = std.time.Instant.now() catch return;
        self.io_ns += end.since(s);
    }

    /// One frame of `n` payload bytes crossed this leg.
    pub fn frame(self: *Meter, n: usize) void {
        if (!isOn()) return;
        self.frames += 1;
        self.bytes += n;
    }

    /// The loop woke and did work (one drain, one write batch, one read).
    pub fn wake(self: *Meter) void {
        if (!isOn()) return;
        self.batches += 1;
    }

    /// Emit the line if a wall-clock second has passed, and start a new window.
    /// Call it once per loop iteration; it is a clock read and nothing else
    /// until the second is up.
    pub fn report(self: *Meter) void {
        if (!isOn()) return;
        const tick = std.time.Instant.now() catch return;
        const from = self.window orelse {
            self.window = tick;
            return;
        };
        const elapsed = tick.since(from);
        if (elapsed < std.time.ns_per_s) return;
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "perf {s} frames_per_s={d} kb_per_s={d} bytes_per_frame={d} " ++
                "wakes_per_s={d} frames_per_wake={d} io_ms_per_s={d}",
            .{
                self.label,
                perSecond(self.frames, elapsed),
                perSecond(self.bytes, elapsed) / 1024,
                ratio(self.bytes, self.frames),
                perSecond(self.batches, elapsed),
                ratio(self.frames, self.batches),
                msPerSecond(self.io_ns, elapsed),
            },
        ) catch "perf (line too long)";
        log.info("{s}", .{line});
        appendToSink(line);
        self.window = tick;
        self.frames = 0;
        self.bytes = 0;
        self.batches = 0;
        self.io_ns = 0;
    }
};

/// Scale a count accumulated over `elapsed_ns` into a per-wall-clock-second
/// rate.
pub fn perSecond(total: u64, elapsed_ns: u64) u64 {
    return total * std.time.ns_per_s / @max(elapsed_ns, 1);
}

/// Scale a nanosecond total accumulated over `elapsed_ns` into milliseconds per
/// wall-clock second — the same unit every duration on `perf agent_feed` is in.
pub fn msPerSecond(total_ns: u64, elapsed_ns: u64) u64 {
    return (total_ns * std.time.ns_per_s / @max(elapsed_ns, 1)) / std.time.ns_per_ms;
}

/// `a / b`, answering 0 rather than trapping when nothing crossed this window.
/// The two averages on the report line are the point of it — "60 bytes per
/// frame" and "1 frame per wake" is the whole T1464 finding — so they must be
/// safe to compute on an idle second.
pub fn ratio(a: u64, b: u64) u64 {
    if (b == 0) return 0;
    return a / b;
}

test "perSecond scales a count to a wall-clock second" {
    const testing = std.testing;
    // Half a second of 5 frames is 10 frames per second.
    try testing.expectEqual(@as(u64, 10), perSecond(5, std.time.ns_per_s / 2));
    // Exactly a second passes the count through.
    try testing.expectEqual(@as(u64, 7), perSecond(7, std.time.ns_per_s));
    // A zero elapsed cannot divide by zero.
    try testing.expectEqual(@as(u64, std.time.ns_per_s), perSecond(1, 0));
}

test "msPerSecond reports a nanosecond total as ms of every second" {
    const testing = std.testing;
    // 250 ms spent over half a second is 500 ms of every second.
    try testing.expectEqual(
        @as(u64, 500),
        msPerSecond(250 * std.time.ns_per_ms, std.time.ns_per_s / 2),
    );
    try testing.expectEqual(@as(u64, 0), msPerSecond(0, std.time.ns_per_s));
}

test "ratio answers zero on an idle window instead of dividing by zero" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 60), ratio(600, 10));
    try testing.expectEqual(@as(u64, 0), ratio(0, 0));
    try testing.expectEqual(@as(u64, 0), ratio(9, 0));
}
