//! How the machine chooser's session list is ORDERED (T602) — the win32 twin
//! of Mac's `MachineChooserSessionSort.swift` (upstream `2389d3182`).
//!
//! Kept out of `SessionRoster` because none of it needs a window: the
//! comparator, the keyboard cursor's anchoring and the persistence format are
//! plain functions, and they are the pieces of the feature most worth testing
//! — so they live here and run in the none-runtime lane.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The sortable columns of the session list.
pub const Key = enum {
    name,
    cpu,

    /// The direction a column starts in the first time it is clicked. Name
    /// reads A→Z; CPU reads busiest-first, because "what is eating this
    /// machine" is the only reason to sort by it.
    pub fn startsAscending(self: Key) bool {
        return switch (self) {
            .name => true,
            .cpu => false,
        };
    }

    /// The column header's label.
    pub fn columnTitle(self: Key) []const u8 {
        return switch (self) {
            .name => "Name",
            .cpu => "CPU",
        };
    }
};

/// A column plus a direction — the whole sort state.
pub const Order = struct {
    key: Key,
    ascending: bool,
};

/// Name, A→Z. The roster arrives in the agent's own creation order, which is
/// not an order anyone can predict or scan; alphabetical is, and it is the one
/// order that does not move on its own.
pub const initial: Order = .{ .key = .name, .ascending = true };

/// The order after clicking column `key`: the active column flips direction,
/// an inactive one becomes active in its natural direction.
pub fn toggled(order: Order, key: Key) Order {
    return if (order.key == key)
        .{ .key = key, .ascending = !order.ascending }
    else
        .{ .key = key, .ascending = key.startsAscending() };
}

/// The CPU value a row is sorted by: the whole percent the meter actually
/// DISPLAYS, not the raw float behind it.
///
/// This is what keeps a CPU-sorted list from twitching. The reading is
/// re-pushed every couple of seconds and is noisy in its fractional digits, so
/// comparing raw floats would reshuffle rows that look identical on screen.
/// Rounding to the displayed integer means the order can only change when the
/// number you are reading changes — and combined with the fixed name/id
/// tiebreak below, a screenful of "0%" rows never moves at all.
///
/// A missing reading (a dead session, or one the agent hasn't reported yet)
/// sorts as 0, matching its blank meter.
pub fn displayedCpu(pct: ?f32) i32 {
    const p = pct orelse return 0;
    return @intFromFloat(@round(p));
}

/// A session's resolved sort keys. `name` must be the string the row actually
/// SHOWS — the user sorts by what they can read, not by the opaque session id
/// underneath it — and `cpu` the DISPLAYED whole percent (`displayedCpu`).
/// Both are precomputed once per row by the caller: the label walks a
/// four-step fallback chain, and a comparator that recomputed it would run
/// that chain O(n log n) times.
pub const Keys = struct {
    name: []const u8,
    cpu: i32,
    id: []const u8,
};

/// The comparison the roster is sorted with. A TOTAL order — ties fall through
/// to name and then to the session id, ALWAYS ascending regardless of the
/// primary direction. That is deliberate: `std.sort.pdq` is unstable, so
/// without a final unique key equal rows could legitimately swap places on
/// every re-render — and a group of equal values keeps ONE order no matter
/// which way the active column points.
pub fn less(order: Order, a: Keys, b: Keys) bool {
    switch (order.key) {
        .cpu => if (a.cpu != b.cpu)
            return if (order.ascending) a.cpu < b.cpu else a.cpu > b.cpu,
        .name => switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
            .eq => {},
            .lt => return order.ascending,
            .gt => return !order.ascending,
        },
    }
    // Fixed tiebreak, never flipped by `order.ascending`.
    switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    return std.mem.order(u8, a.id, b.id) == .lt;
}

// ---------------------------------------------------------------------
// Keyboard cursor
// ---------------------------------------------------------------------

/// Where the keyboard session cursor lands when it steps by `delta` from
/// `resolved` — the index its anchored session id resolved to in the DISPLAYED
/// list, or null when that session is no longer in the roster (it exited, or
/// was killed, while the cursor sat on it).
///
/// `null` out means LEAVE the list, back to machine navigation: either the
/// anchor is gone, or the step went above the first row. Stepping past the
/// last row stays on the last row.
///
/// The cursor is anchored to a session ID rather than to an index, and this
/// function is why: the list re-sorts underneath it — when a column header is
/// clicked, and on any live CPU tick that changes a displayed percentage while
/// sorted by CPU. An index would silently re-point at whatever slid into that
/// slot; the ID follows the row the user is looking at.
pub fn steppedCursor(resolved: ?usize, delta: i32, count: usize) ?usize {
    const cur = resolved orelse return null;
    if (count == 0) return null;
    const next = @as(i32, @intCast(cur)) + delta;
    if (next < 0) return null;
    if (next >= count) return count - 1;
    return @intCast(next);
}

// ---------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------
//
// A preference rather than per-open state, matching the viewer's own chrome
// preferences (`viewer_prefs.zig`, the `window_memory.zig` pattern): how you
// want to read a list is a property of you, not of the machine that happened
// to be selected when you set it. Mac stores the same pair in UserDefaults
// (`MachineChooserSessionSortKey` / `...Ascending`).

/// Parse a persisted order. Null on malformed input — the caller then uses
/// `initial`, exactly as if the file did not exist. A key with no direction
/// means a hand-edited file; it falls back to the column's own natural
/// direction rather than to a bare `false`, Mac's rule.
pub fn parse(text: []const u8) ?Order {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const key_s = it.next() orelse return null;
    const key: Key = if (std.mem.eql(u8, key_s, "name"))
        .name
    else if (std.mem.eql(u8, key_s, "cpu"))
        .cpu
    else
        return null;
    const dir_s = it.next() orelse return .{ .key = key, .ascending = key.startsAscending() };
    if (it.next() != null) return null;
    const ascending = if (std.mem.eql(u8, dir_s, "asc"))
        true
    else if (std.mem.eql(u8, dir_s, "desc"))
        false
    else
        return null;
    return .{ .key = key, .ascending = ascending };
}

pub const FORMAT_BUF_LEN: usize = 16;

/// Format an order for the file: `<key> <asc|desc>\n`.
pub fn format(buf: []u8, order: Order) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}\n", .{
        @tagName(order.key),
        if (order.ascending) "asc" else "desc",
    }) catch unreachable;
}

fn prefPath(alloc: Allocator) ?[]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return null;
    defer alloc.free(dir);
    // Debug builds get their own file (the debug-IPC-pipe coexistence pattern)
    // so dev/test choosers never move the release app's preference.
    const name = if (builtin.mode == .Debug)
        "chooser_session_sort-debug"
    else
        "chooser_session_sort";
    return std.fs.path.join(alloc, &.{ dir, "ghoztty", name }) catch null;
}

/// The order to use: the persisted preference, else `initial`.
pub fn load(alloc: Allocator) Order {
    const path = prefPath(alloc) orelse return initial;
    defer alloc.free(path);
    const f = std.fs.cwd().openFile(path, .{}) catch return initial;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    const n = f.readAll(&buf) catch return initial;
    return parse(buf[0..n]) orelse initial;
}

/// Persist an order. Best-effort: a preference is never worth an error dialog.
pub fn save(alloc: Allocator, order: Order) void {
    const path = prefPath(alloc) orelse return;
    defer alloc.free(path);
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse return) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    f.writeAll(format(&buf, order)) catch {};
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "toggled: an inactive column starts in its natural direction" {
    // Name reads A→Z the first time; CPU reads busiest-first.
    try testing.expectEqual(Order{ .key = .cpu, .ascending = false }, toggled(initial, .cpu));
    try testing.expectEqual(
        Order{ .key = .name, .ascending = true },
        toggled(.{ .key = .cpu, .ascending = false }, .name),
    );
}

test "toggled: clicking the active column flips it" {
    try testing.expectEqual(Order{ .key = .name, .ascending = false }, toggled(initial, .name));
    const cpu_desc: Order = .{ .key = .cpu, .ascending = false };
    try testing.expectEqual(Order{ .key = .cpu, .ascending = true }, toggled(cpu_desc, .cpu));
    try testing.expectEqual(cpu_desc, toggled(toggled(cpu_desc, .cpu), .cpu));
}

test "displayedCpu rounds to the percent the meter shows, and a blank meter is 0" {
    try testing.expectEqual(@as(i32, 0), displayedCpu(null));
    try testing.expectEqual(@as(i32, 0), displayedCpu(0.4));
    try testing.expectEqual(@as(i32, 1), displayedCpu(0.5));
    try testing.expectEqual(@as(i32, 17), displayedCpu(16.7));
    // The point: two readings that DISPLAY the same number compare equal, so
    // sub-point jitter in the 2s push cannot reshuffle rows that read
    // identically.
    try testing.expectEqual(displayedCpu(16.6), displayedCpu(17.4));
}

test "less: the active column decides, in either direction" {
    const a: Keys = .{ .name = "alpha", .cpu = 5, .id = "1" };
    const b: Keys = .{ .name = "beta", .cpu = 90, .id = "2" };

    try testing.expect(less(.{ .key = .name, .ascending = true }, a, b));
    try testing.expect(!less(.{ .key = .name, .ascending = false }, a, b));
    try testing.expect(less(.{ .key = .cpu, .ascending = true }, a, b));
    try testing.expect(!less(.{ .key = .cpu, .ascending = false }, a, b));
    // Case-insensitive, like the labels the user reads.
    const cap: Keys = .{ .name = "Beta", .cpu = 0, .id = "3" };
    try testing.expect(less(.{ .key = .name, .ascending = true }, a, cap));
    try testing.expect(!less(.{ .key = .name, .ascending = true }, cap, a));
}

test "less: ties fall through to name then id, never flipped by the direction" {
    // Equal CPU: name decides, ascending in BOTH directions — a screenful of
    // equal readings keeps one order no matter which way the column points.
    const a: Keys = .{ .name = "alpha", .cpu = 0, .id = "9" };
    const b: Keys = .{ .name = "beta", .cpu = 0, .id = "1" };
    try testing.expect(less(.{ .key = .cpu, .ascending = false }, a, b));
    try testing.expect(less(.{ .key = .cpu, .ascending = true }, a, b));
    try testing.expect(!less(.{ .key = .cpu, .ascending = false }, b, a));

    // Equal name too: the id is the final, unique key — fixed ascending.
    const x: Keys = .{ .name = "same", .cpu = 0, .id = "aaa" };
    const y: Keys = .{ .name = "same", .cpu = 0, .id = "bbb" };
    for ([_]Order{
        .{ .key = .cpu, .ascending = false },
        .{ .key = .cpu, .ascending = true },
        .{ .key = .name, .ascending = false },
        .{ .key = .name, .ascending = true },
    }) |o| {
        try testing.expect(less(o, x, y));
        try testing.expect(!less(o, y, x));
    }
    // And a row never sorts before itself (irreflexive — what pdq needs).
    try testing.expect(!less(initial, x, x));
}

test "steppedCursor: steps, clamps at the end, and leaves at the top" {
    try testing.expectEqual(@as(?usize, 1), steppedCursor(0, 1, 3));
    try testing.expectEqual(@as(?usize, 0), steppedCursor(1, -1, 3));
    // Past the last row stays on the last row.
    try testing.expectEqual(@as(?usize, 2), steppedCursor(2, 1, 3));
    // Above the first row hands navigation back to the machine list.
    try testing.expectEqual(@as(?usize, null), steppedCursor(0, -1, 3));
}

test "steppedCursor: a gone anchor leaves the list" {
    // The anchored session exited or was killed: null in, null out — the row
    // that slid into its old index is NOT the row the user was pointing at.
    try testing.expectEqual(@as(?usize, null), steppedCursor(null, 1, 5));
    try testing.expectEqual(@as(?usize, null), steppedCursor(null, -1, 5));
    try testing.expectEqual(@as(?usize, null), steppedCursor(2, 1, 0));
}

test "parse: valid forms, including Mac's missing-direction fallback" {
    try testing.expectEqual(@as(?Order, .{ .key = .name, .ascending = true }), parse("name asc\n"));
    try testing.expectEqual(@as(?Order, .{ .key = .cpu, .ascending = false }), parse("cpu desc"));
    try testing.expectEqual(@as(?Order, .{ .key = .name, .ascending = false }), parse(" name  desc \r\n"));
    // A key with no direction is a hand-edited file: the column's own natural
    // direction, not a bare `false`.
    try testing.expectEqual(@as(?Order, .{ .key = .cpu, .ascending = false }), parse("cpu"));
    try testing.expectEqual(@as(?Order, .{ .key = .name, .ascending = true }), parse("name"));
}

test "parse: malformed input rejected" {
    try testing.expectEqual(@as(?Order, null), parse(""));
    try testing.expectEqual(@as(?Order, null), parse("pid asc"));
    try testing.expectEqual(@as(?Order, null), parse("name up"));
    try testing.expectEqual(@as(?Order, null), parse("name asc extra"));
}

test "format round-trips through parse" {
    var buf: [FORMAT_BUF_LEN]u8 = undefined;
    for ([_]Order{
        .{ .key = .name, .ascending = true },
        .{ .key = .name, .ascending = false },
        .{ .key = .cpu, .ascending = true },
        .{ .key = .cpu, .ascending = false },
    }) |o| {
        try testing.expectEqual(@as(?Order, o), parse(format(&buf, o)));
    }
}

test "column titles and natural directions match Mac's" {
    try testing.expectEqualStrings("Name", Key.name.columnTitle());
    try testing.expectEqualStrings("CPU", Key.cpu.columnTitle());
    try testing.expect(Key.name.startsAscending());
    try testing.expect(!Key.cpu.startsAscending());
    try testing.expectEqual(initial, Order{ .key = .name, .ascending = true });
}
