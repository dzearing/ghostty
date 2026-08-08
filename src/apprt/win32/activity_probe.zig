//! Pure policy for the Activity Monitor's per-machine metrics probes (T298) —
//! the half of Mac's `MachineMetricsProbe` with no socket in it.
//!
//! T296 shipped the carousel; every INACTIVE card reported the relay
//! directory's `online` flag because nothing had dialed that machine. Mac
//! paints a live `up 3d 4h` / `CPU 12% · Mem 40%` on every card at once, fed by
//! `MachineMetricsProbe` (MachineMetricsProbe.swift:72-134), which dials each
//! registered machine and holds a metrics subscription for the panel's whole
//! life. This module owns the DECISIONS that design needs and
//! `ActivityMonitor.zig` owns the connections:
//!
//!   * which machines to probe at all (`want`),
//!   * how long to wait before re-dialing one that refused (`retryDelayMs`),
//!   * when a probe that stopped answering stops being believed (`isStale`),
//!   * and how a `host:port` card id becomes a dial target (`parseHostPort`).
//!
//! Three rules are load-bearing, and all three are asserted below:
//!
//!   * **The active source is never probed.** Its card is fed by the panel's own
//!     connection, which is live and already paid for; a second connection to
//!     the machine you are looking at buys nothing. Mac excludes it the same
//!     way (it prefers `host` for the active card, RemoteActivityMonitorView
//!     .swift:263).
//!   * **A refused dial backs off; it never retries in a tight loop.** A panel
//!     sits open for hours, and a machine that is off stays off — so the delay
//!     grows to a ceiling and stays there, rather than either hammering the
//!     relay or giving up on a machine that comes back at lunchtime.
//!   * **Silence is not a reading.** A probe whose metrics stop arriving is a
//!     dead link, not a machine frozen at its last CPU%. After
//!     `stale_after_intervals` missed pushes the card says `unreachable` and
//!     the probe re-enters the backoff — the same "a state we do not have is a
//!     state we do not paint" rule `activity_cards.State` was built on.

const std = @import("std");

/// How many machines a panel probes at once. Sized to the carousel's own
/// machine cap (`ActivityMonitor.max_machines`), so every card that can be
/// painted can be probed — Mac probes all of its registered machines and a card
/// that is visible but permanently `idle` would be the odd one out.
pub const max_probes: usize = 8;

/// Which transport a probe dials. A card id alone cannot say: a relay device id
/// and a `host:port` are both opaque strings, and guessing from a colon would
/// misroute a device id that happens to contain one. So the kind travels WITH
/// the id, from whichever list the machine came out of.
pub const Kind = enum { relay, tcp };

/// A machine a probe could be pointed at. `id` borrows the caller's storage
/// (`ActivityMonitor.MachineEntry`, stable for the panel's life).
pub const Target = struct {
    kind: Kind = .relay,
    id: []const u8 = "",
};

/// The machines that SHOULD have a probe right now: every candidate except the
/// active source, deduplicated by id, capped at `out.len`. Written into `out`;
/// returns how many.
///
/// Deduplication matters because the two lists behind it answer different
/// questions and overlap freely: `machines` is what the ACCOUNT can reach (the
/// relay directory) and `win_machines` is what this app is already talking to
/// (T301). A machine in both must not be dialed twice.
///
/// The FIRST candidate for an id wins, which is why `ActivityMonitor` passes
/// the directory list first: a directory entry knows the machine is a relay
/// device, and a window entry for the same machine would send the probe down
/// the `host:port` path instead.
pub fn want(
    cands: []const Target,
    active_local: bool,
    active_id: []const u8,
    out: []Target,
) usize {
    var n: usize = 0;
    for (cands) |c| {
        if (n == out.len) break;
        if (c.id.len == 0) continue;
        // The active machine's card is fed by the panel's own connection.
        if (!active_local and std.mem.eql(u8, c.id, active_id)) continue;
        var dup = false;
        for (out[0..n]) |prev| {
            if (std.mem.eql(u8, prev.id, c.id)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        out[n] = c;
        n += 1;
    }
    return n;
}

/// Index of the probe holding `id`, or null.
pub fn indexOf(ids: []const []const u8, id: []const u8) ?usize {
    for (ids, 0..) |have, i| {
        if (std.mem.eql(u8, have, id)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------
// Backoff
// ---------------------------------------------------------------------

/// First wait after a refused dial. Long enough that a machine that is simply
/// off costs nothing to keep listed, short enough that a box finishing a reboot
/// shows up while the user is still looking at the panel.
pub const retry_floor_ms: u64 = 30 * std.time.ms_per_s;

/// The ceiling the backoff climbs to and stays at. A panel is a long-lived
/// window; a probe that has failed all afternoon must keep costing about
/// nothing while still noticing if the machine returns.
pub const retry_ceiling_ms: u64 = 5 * 60 * std.time.ms_per_s;

/// How long to wait before dialing a machine again, after `attempts` failures.
/// Doubling from the floor to the ceiling: 30s, 60s, 120s, 240s, then 5 min
/// forever. `attempts` counts the failure that just happened, so the first call
/// is `retryDelayMs(1)`.
pub fn retryDelayMs(attempts: u32) u64 {
    if (attempts == 0) return 0;
    var delay = retry_floor_ms;
    var i: u32 = 1;
    while (i < attempts) : (i += 1) {
        delay *|= 2;
        if (delay >= retry_ceiling_ms) return retry_ceiling_ms;
    }
    return @min(delay, retry_ceiling_ms);
}

/// Whether a probe with no connection may dial now. `next_ms` is the deadline
/// `retryDelayMs` produced; a probe that has never been dialed carries 0 and is
/// therefore due immediately.
pub fn dialDue(now_ms: i64, next_ms: i64) bool {
    return now_ms >= next_ms;
}

// ---------------------------------------------------------------------
// Staleness
// ---------------------------------------------------------------------

/// How many pushes may be missed before a live probe stops being believed.
/// Five, not one: the agent throttles its own cadence under load (see
/// `Connection.SessionCpuHandler`'s note about the agent choosing the
/// interval), and a card that flickered to `unreachable` every time a busy box
/// skipped a beat would be a worse lie than a reading one interval old.
pub const stale_after_intervals: u64 = 5;

/// Whether a probe that has been answering has now gone quiet. `last_ms` is
/// when its most recent metrics frame landed; 0 means none ever has, which is
/// NOT stale — that probe is still `connecting`, and the dial's own handshake
/// timeout is what bounds it.
pub fn isStale(now_ms: i64, last_ms: i64, interval_ms: u32) bool {
    if (last_ms == 0) return false;
    if (now_ms <= last_ms) return false;
    const elapsed: u64 = @intCast(now_ms - last_ms);
    return elapsed > @as(u64, interval_ms) * stale_after_intervals;
}

// ---------------------------------------------------------------------
// Dial targets
// ---------------------------------------------------------------------

pub const HostPort = struct { host: []const u8, port: u16 };

/// Split a `.tcp` card id back into the host and port a dial needs. The id was
/// built by `activity_borrow.sourceId` as `host:port`, so this is that function
/// read backwards — and it splits on the LAST colon so a bracketed IPv6
/// literal (`[::1]:7777`) keeps its own colons.
///
/// Returns null rather than a guess for anything that is not that shape: a
/// machine we cannot name is a machine we do not dial.
pub fn parseHostPort(id: []const u8) ?HostPort {
    const idx = std.mem.lastIndexOfScalar(u8, id, ':') orelse return null;
    const host = id[0..idx];
    const port_s = id[idx + 1 ..];
    if (host.len == 0 or port_s.len == 0) return null;
    const port = std.fmt.parseInt(u16, port_s, 10) catch return null;
    if (port == 0) return null;
    return .{ .host = host, .port = port };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn relayTarget(id: []const u8) Target {
    return .{ .kind = .relay, .id = id };
}

test "want: the active machine is never probed" {
    const cands = [_]Target{ relayTarget("dev-1"), relayTarget("dev-2"), relayTarget("dev-3") };
    var out: [max_probes]Target = undefined;
    const n = want(&cands, false, "dev-2", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("dev-1", out[0].id);
    try testing.expectEqualStrings("dev-3", out[1].id);
}

test "want: a LOCAL active source probes every machine" {
    const cands = [_]Target{ relayTarget("dev-1"), relayTarget("dev-2") };
    var out: [max_probes]Target = undefined;
    // "" is Local's id, and it must not be read as "the machine named nothing".
    try testing.expectEqual(@as(usize, 2), want(&cands, true, "", &out));
}

test "want: one machine in both lists is one probe, and the first kind wins" {
    const cands = [_]Target{
        .{ .kind = .relay, .id = "dev-1" },
        .{ .kind = .tcp, .id = "dev-1" },
        .{ .kind = .tcp, .id = "127.0.0.1:7777" },
    };
    var out: [max_probes]Target = undefined;
    const n = want(&cands, true, "", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("dev-1", out[0].id);
    try testing.expectEqual(Kind.relay, out[0].kind);
    try testing.expectEqualStrings("127.0.0.1:7777", out[1].id);
    try testing.expectEqual(Kind.tcp, out[1].kind);
}

test "want: an unnamed machine is skipped, not probed blind" {
    const cands = [_]Target{ relayTarget(""), relayTarget("dev-1") };
    var out: [max_probes]Target = undefined;
    const n = want(&cands, true, "", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("dev-1", out[0].id);
}

test "want: the connection budget is a hard cap" {
    var ids: [12][8]u8 = undefined;
    var cands: [12]Target = undefined;
    for (&ids, 0..) |*buf, i| {
        const s = std.fmt.bufPrint(buf, "dev-{d}", .{i}) catch unreachable;
        cands[i] = relayTarget(s);
    }
    var out: [max_probes]Target = undefined;
    try testing.expectEqual(max_probes, want(&cands, true, "", &out));
}

test "indexOf: a probe is found by id" {
    const ids = [_][]const u8{ "dev-1", "127.0.0.1:7777" };
    try testing.expectEqual(@as(?usize, 0), indexOf(&ids, "dev-1"));
    try testing.expectEqual(@as(?usize, 1), indexOf(&ids, "127.0.0.1:7777"));
    try testing.expectEqual(@as(?usize, null), indexOf(&ids, "dev-2"));
}

test "retryDelayMs: doubles from the floor and stops at the ceiling" {
    try testing.expectEqual(@as(u64, 0), retryDelayMs(0));
    try testing.expectEqual(retry_floor_ms, retryDelayMs(1));
    try testing.expectEqual(retry_floor_ms * 2, retryDelayMs(2));
    try testing.expectEqual(retry_floor_ms * 4, retryDelayMs(3));
    try testing.expectEqual(retry_floor_ms * 8, retryDelayMs(4));
    try testing.expectEqual(retry_ceiling_ms, retryDelayMs(5));
    // An afternoon of failures costs the same as the fifth one — and cannot
    // overflow its way back down to a tight loop.
    try testing.expectEqual(retry_ceiling_ms, retryDelayMs(50));
    try testing.expectEqual(retry_ceiling_ms, retryDelayMs(std.math.maxInt(u32)));
}

test "retryDelayMs: never returns a delay that would be a tight loop" {
    var attempts: u32 = 1;
    while (attempts <= 64) : (attempts += 1) {
        try testing.expect(retryDelayMs(attempts) >= retry_floor_ms);
    }
}

test "dialDue: a never-dialed probe is due at once, a backed-off one waits" {
    try testing.expect(dialDue(0, 0));
    try testing.expect(dialDue(1_000, 0));
    try testing.expect(!dialDue(1_000, 31_000));
    try testing.expect(dialDue(31_000, 31_000));
    try testing.expect(dialDue(31_001, 31_000));
}

test "isStale: a probe that has never answered is connecting, not stale" {
    try testing.expect(!isStale(999_999, 0, 1500));
}

test "isStale: silence past the grace window retires the reading" {
    const interval: u32 = 1500;
    const grace = interval * stale_after_intervals;
    try testing.expect(!isStale(1_000 + grace, 1_000, interval));
    try testing.expect(isStale(1_000 + grace + 1, 1_000, interval));
    // A fresh reading is never stale, and a clock that went backwards does not
    // manufacture staleness either.
    try testing.expect(!isStale(1_000, 1_000, interval));
    try testing.expect(!isStale(900, 1_000, interval));
}

test "parseHostPort: the id activity_borrow built, read backwards" {
    const hp = parseHostPort("127.0.0.1:7777").?;
    try testing.expectEqualStrings("127.0.0.1", hp.host);
    try testing.expectEqual(@as(u16, 7777), hp.port);
    const named = parseHostPort("winbox.local:22").?;
    try testing.expectEqualStrings("winbox.local", named.host);
    try testing.expectEqual(@as(u16, 22), named.port);
}

test "parseHostPort: an IPv6 literal keeps its own colons" {
    const hp = parseHostPort("[::1]:7777").?;
    try testing.expectEqualStrings("[::1]", hp.host);
    try testing.expectEqual(@as(u16, 7777), hp.port);
}

test "parseHostPort: anything that is not host:port is refused" {
    try testing.expect(parseHostPort("dev-abc") == null);
    try testing.expect(parseHostPort("") == null);
    try testing.expect(parseHostPort("host:") == null);
    try testing.expect(parseHostPort(":7777") == null);
    try testing.expect(parseHostPort("host:0") == null);
    try testing.expect(parseHostPort("host:notaport") == null);
    try testing.expect(parseHostPort("host:99999") == null);
}
