//! T922: deciding WHEN to re-persist the panes' screens.
//!
//! The session-layout manifest carries each pane's WP-D3 screen snapshot, and
//! that is what a pane restored under the `restore` policy paints above the
//! session-interrupted notice (D78, `termio/restore_history.zig`). Every other
//! trigger for writing that file is a TOPOLOGY mutation — a split, a tab, a
//! rename, a banner — so before this a pane that had merely been RUNNING for an
//! hour restored the screen it had when a window was last moved. The promise
//! D78 made ("you can read the error, the build output or the last thing your
//! agent said before the reboot took it") is about the LAST screen, so the
//! manifest has to follow the panes' output too.
//!
//! What lives here is the part that is pure arithmetic over a cursor and a
//! clock — whether this tick should capture, keep waiting, or do nothing — so
//! it is asserted in the test lanes instead of only being observable by
//! rebooting a box. The caller (`App.tickLayoutRefresh`) owns reading the panes
//! and writing the file. Same split as `termio/restore_park.zig` and
//! `termio/restore_history.zig`.

const std = @import("std");
const testing = std.testing;

/// What a refresh tick should do.
pub const Action = enum {
    /// Nothing has painted since the manifest was last written.
    idle,
    /// Output is still arriving. Capturing mid-burst is wasted work — the
    /// snapshot would be superseded a tick later — so wait for quiet.
    wait,
    /// Capture and persist now.
    capture,
};

/// The state a tick compares, in the units it compares them in.
pub const State = struct {
    /// Summed agent-stream offset across every pane, this tick. A cursor, not a
    /// quantity: it moves iff some pane applied output.
    now: u64,
    /// The same sum, as of the PREVIOUS tick.
    seen: u64,
    /// The sum the manifest on disk reflects.
    captured: u64,
    /// Milliseconds since the last capture. The ceiling on "wait for quiet": a
    /// pane that never pauses — a long build, a `tail -f`, an agent thinking out
    /// loud — would otherwise never look quiet, and its screen would never be
    /// persisted at all.
    since_write_ms: i64,
    /// That ceiling.
    max_wait_ms: i64,
};

pub fn decide(s: State) Action {
    if (s.now == s.captured) return .idle;
    if (s.now != s.seen and s.since_write_ms < s.max_wait_ms) return .wait;
    return .capture;
}

test "idle: nothing painted since the last write" {
    try testing.expectEqual(Action.idle, decide(.{
        .now = 4096,
        .seen = 4096,
        .captured = 4096,
        .since_write_ms = 999_999,
        .max_wait_ms = 30_000,
    }));
}

test "a burst waits: the offsets are still moving" {
    try testing.expectEqual(Action.wait, decide(.{
        .now = 8192,
        .seen = 4096,
        .captured = 1024,
        .since_write_ms = 2_000,
        .max_wait_ms = 30_000,
    }));
}

test "quiet after a burst captures: same sum as last tick, newer than disk" {
    try testing.expectEqual(Action.capture, decide(.{
        .now = 8192,
        .seen = 8192,
        .captured = 1024,
        .since_write_ms = 2_000,
        .max_wait_ms = 30_000,
    }));
}

test "unbroken output captures anyway once the ceiling is reached" {
    // Without this a pane that never stops printing is the ONE pane whose
    // screen is never persisted — the exact case the user is most likely to
    // want back after a crash.
    try testing.expectEqual(Action.capture, decide(.{
        .now = 1_000_000,
        .seen = 900_000,
        .captured = 1024,
        .since_write_ms = 30_000,
        .max_wait_ms = 30_000,
    }));
}

test "the ceiling cannot fire when there is nothing new to persist" {
    // `idle` outranks the ceiling: an app left running overnight must not
    // rewrite the manifest every 30 seconds for a screen that has not changed.
    try testing.expectEqual(Action.idle, decide(.{
        .now = 4096,
        .seen = 4096,
        .captured = 4096,
        .since_write_ms = 86_400_000,
        .max_wait_ms = 30_000,
    }));
}

test "the first tick after launch captures rather than waiting a cycle" {
    // `since_write_ms` is huge before the first write, so a pane that painted
    // during startup is persisted on the first tick instead of the second.
    try testing.expectEqual(Action.capture, decide(.{
        .now = 4096,
        .seen = 0,
        .captured = 0,
        .since_write_ms = std.math.maxInt(i32),
        .max_wait_ms = 30_000,
    }));
}
