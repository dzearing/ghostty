//! Which live WINDOW's connection an Activity Monitor panel may borrow (T301).
//!
//! A remote panel reaches its machine one of two ways: it DIALS its own relay
//! connection and owns it, or it BORROWS the connection a remote window is
//! already riding on and never frees it (`ActivityMonitor.openReusing`). Until
//! T301 only the palette entry could produce the second kind, so switching the
//! carousel away from a borrowed machine and back again always re-dialed — which
//! fails outright with no signed-in account, and opens a redundant second
//! connection with one. A `127.0.0.1:PORT` window is the sharper case: it has no
//! relay device id, so there is nothing correct to re-dial.
//!
//! This module is the pure half of the answer: given each open window's machine
//! identity and link state, WHICH one (if any) should a panel switching to `id`
//! borrow from. The impure half — walking `app.windows` and handing over the
//! `*Connection` — stays in `ActivityMonitor.zig`.
//!
//! ## The identity key
//! A card is keyed by relay DEVICE ID, because that is what the relay directory
//! lists and what the chooser opens with. A direct-TCP window has no device id,
//! so it is keyed `host:port` — the same string `Surface.openActivityMonitor`
//! builds, and the same shape `RemoteMachine.hostDefaultsKey` uses to key
//! per-host defaults. One derivation (`sourceId`), so the palette entry and the
//! switch cannot key the same window two different ways.
//!
//! ## Why only a CONNECTED window
//! A window whose link is down or reconnecting has a connection object, but
//! samples through it fail. Borrowing one would trade a dial that might succeed
//! for a connection that certainly will not, and would report the machine as
//! unreachable while the account could have reached it. So a borrow requires the
//! window's own status pill to read connected; anything else falls through to
//! the dial, which is what the panel did before this existed.

const std = @import("std");

/// The largest identity key `sourceId` will build. Matches
/// `ActivityMonitor.max_source_id` — a longer id is truncated there too, and an
/// id is only ever compared against another copy of itself.
pub const max_id: usize = 128;

/// A machine identity in the two shapes a remote window can have one.
pub const Machine = union(enum) {
    relay: []const u8,
    tcp: struct { host: []const u8, port: u16 },
};

/// One open window, as the borrow decision sees it.
pub const Candidate = struct {
    /// The window's machine, or null when it is local (nothing to borrow).
    machine: ?Machine = null,
    /// Whether the window's link is UP — its pill reads connected.
    connected: bool = false,
};

/// This machine's panel-source id, written into `buf`. Null when `buf` cannot
/// hold it: a caller that cannot name a machine must not guess, since a
/// truncated key would match the wrong window.
pub fn sourceId(buf: []u8, machine: Machine) ?[]const u8 {
    return switch (machine) {
        .relay => |device| {
            if (device.len > buf.len) return null;
            @memcpy(buf[0..device.len], device);
            return buf[0..device.len];
        },
        .tcp => |t| std.fmt.bufPrint(buf, "{s}:{d}", .{ t.host, t.port }) catch null,
    };
}

/// The index of the window a panel switching to `id` should borrow from, or
/// null to dial. The FIRST connected match wins: every window on one machine
/// talks to the same agent, so there is nothing to choose between them, and a
/// stable rule keeps the choice reproducible across a switch away and back.
pub fn borrowFrom(cands: []const Candidate, id: []const u8) ?usize {
    if (id.len == 0) return null;
    for (cands, 0..) |c, i| {
        if (!c.connected) continue;
        const machine = c.machine orelse continue;
        var buf: [max_id]u8 = undefined;
        const key = sourceId(&buf, machine) orelse continue;
        if (std.mem.eql(u8, key, id)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "sourceId: relay is the bare device id" {
    var buf: [max_id]u8 = undefined;
    try testing.expectEqualStrings(
        "dev-abc",
        sourceId(&buf, .{ .relay = "dev-abc" }).?,
    );
}

test "sourceId: tcp is host:port" {
    var buf: [max_id]u8 = undefined;
    try testing.expectEqualStrings(
        "127.0.0.1:7777",
        sourceId(&buf, .{ .tcp = .{ .host = "127.0.0.1", .port = 7777 } }).?,
    );
}

test "sourceId: refuses rather than truncating" {
    var small: [4]u8 = undefined;
    try testing.expect(sourceId(&small, .{ .relay = "dev-abc" }) == null);
    try testing.expect(sourceId(&small, .{ .tcp = .{ .host = "example.internal", .port = 7777 } }) == null);
}

test "borrowFrom: a connected relay window is borrowed" {
    const cands = [_]Candidate{
        .{ .machine = null, .connected = false }, // a local window
        .{ .machine = .{ .relay = "dev-abc" }, .connected = true },
    };
    try testing.expectEqual(@as(?usize, 1), borrowFrom(&cands, "dev-abc"));
}

test "borrowFrom: a direct-TCP window is borrowed by host:port" {
    const cands = [_]Candidate{
        .{ .machine = .{ .tcp = .{ .host = "127.0.0.1", .port = 7777 } }, .connected = true },
    };
    try testing.expectEqual(@as(?usize, 0), borrowFrom(&cands, "127.0.0.1:7777"));
    // A different port is a different machine, not a near miss.
    try testing.expectEqual(@as(?usize, null), borrowFrom(&cands, "127.0.0.1:7778"));
}

test "borrowFrom: a window that is not connected is not borrowed" {
    const cands = [_]Candidate{
        .{ .machine = .{ .relay = "dev-abc" }, .connected = false },
    };
    try testing.expectEqual(@as(?usize, null), borrowFrom(&cands, "dev-abc"));
}

test "borrowFrom: the first connected match wins" {
    const cands = [_]Candidate{
        .{ .machine = .{ .relay = "dev-abc" }, .connected = false },
        .{ .machine = .{ .relay = "dev-abc" }, .connected = true },
        .{ .machine = .{ .relay = "dev-abc" }, .connected = true },
    };
    try testing.expectEqual(@as(?usize, 1), borrowFrom(&cands, "dev-abc"));
}

test "borrowFrom: no windows, no match, empty id" {
    try testing.expectEqual(@as(?usize, null), borrowFrom(&.{}, "dev-abc"));
    const cands = [_]Candidate{
        .{ .machine = .{ .relay = "dev-xyz" }, .connected = true },
    };
    try testing.expectEqual(@as(?usize, null), borrowFrom(&cands, "dev-abc"));
    // An empty target id must never match a window; it is not a wildcard.
    try testing.expectEqual(@as(?usize, null), borrowFrom(&cands, ""));
}
