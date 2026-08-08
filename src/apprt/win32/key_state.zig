//! The key-state MODEL (T446): which key tables are active, and which keys of
//! a multi-key sequence have been pressed so far. The Windows half of Mac's
//! `Ghostty.SurfaceView` `keyTables` / `keySequence` state, which feeds its
//! `KeyStateIndicator` pill (`macos/Sources/Ghostty/Surface View/SurfaceView.swift`).
//!
//! Both states are invisible on Windows today because the `.key_sequence` and
//! `.key_table` apprt actions fall through to a bare `return true` in
//! `App.zig`. That is worse than a missing decoration: a pane waiting for the
//! second half of a chord looks *exactly* like a pane that ignored the first
//! half, and a key table you entered by accident silently reinterprets every
//! key you press afterwards with nothing on screen to say so.
//!
//! Two things live here rather than in the painter:
//!
//! - **The key-table stack is a STACK**, not a single value. Tables nest, so
//!   `deactivate` pops one and `deactivate_all` clears the lot — the same
//!   model `Surface.keyboard.table_stack` keeps in the core, mirrored here
//!   because the apprt only ever sees the three transitions, never the stack.
//! - **The true depth is tracked past what is displayable.** A pop after an
//!   overflowing push has to land back on the entry it came from, so `depth`
//!   counts every activation while only the first `MAX_TABLES` names are kept.
//!   Dropping the count with the name is how a nested table would come back
//!   from a pop that should have emptied the stack.
//!
//! Fixed capacity and no allocator: this is driven from the key handler, and a
//! per-keystroke allocation that can fail is a worse answer than a bounded
//! display. Key labels are formatted through `menu_label.formatTrigger` — the
//! same formatter the menus use — so a chord reads identically wherever the
//! app prints it (`Ctrl+Shift+T`, Windows' own modifier order).
//!
//! No OS imports, so the tests below run in every app-runtime lane. The
//! geometry and pixels are `key_state_pill.zig`; the window is
//! `KeyStateIndicator.zig`.

const std = @import("std");
const input = @import("../../input.zig");
const menu_label = @import("menu_label.zig");

/// Key tables whose NAMES are retained. Deeper nesting still counts (see
/// `depth`), it just stops adding rows to the pill — eight nested tables is
/// already far past what a person can hold in their head.
pub const MAX_TABLES: usize = 8;

/// Pending keys retained. A sequence longer than this keeps counting; the
/// pill's trailing dots already say "and more is expected".
pub const MAX_KEYS: usize = 8;

/// Bytes retained per key-table name and per formatted key label. A longer
/// one is tail-truncated with an ellipsis at a UTF-8 boundary.
pub const NAME_CAP: usize = 32;
pub const LABEL_CAP: usize = 24;

const ELLIPSIS = "\u{2026}";

/// A bounded, self-truncating UTF-8 string.
fn Text(comptime cap: usize) type {
    return struct {
        const Self = @This();

        buf: [cap]u8 = @splat(0),
        len: usize = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *Self, src: []const u8) void {
            self.len = truncateInto(&self.buf, src);
        }
    };
}

/// Copy `src` into `dst`, tail-truncating with an ellipsis when it does not
/// fit. The cut backs off to a UTF-8 boundary first: a name sliced mid-
/// codepoint would render as a replacement glyph, which looks like corruption
/// rather than like elision.
fn truncateInto(dst: []u8, src: []const u8) usize {
    if (src.len <= dst.len) {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
    // Not enough room even for the ellipsis: keep whatever whole codepoints
    // fit rather than emitting a lone marker.
    if (dst.len <= ELLIPSIS.len) {
        var n = dst.len;
        while (n > 0 and isContinuation(src[n])) n -= 1;
        @memcpy(dst[0..n], src[0..n]);
        return n;
    }

    var cut = dst.len - ELLIPSIS.len;
    while (cut > 0 and isContinuation(src[cut])) cut -= 1;
    @memcpy(dst[0..cut], src[0..cut]);
    @memcpy(dst[cut..][0..ELLIPSIS.len], ELLIPSIS);
    return cut + ELLIPSIS.len;
}

fn isContinuation(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Everything a pane's key-state pill needs to know, and nothing else.
pub const Model = struct {
    tables: [MAX_TABLES]Text(NAME_CAP) = @splat(.{}),
    /// Every activation, including the ones past `MAX_TABLES`. This is the
    /// number `deactivate` pops.
    depth: usize = 0,

    keys: [MAX_KEYS]Text(LABEL_CAP) = @splat(.{}),
    /// Every pending key, including the ones past `MAX_KEYS`.
    key_count: usize = 0,

    /// `.key_table = .activate(name)` — push a table onto the stack.
    pub fn activate(self: *Model, name: []const u8) void {
        if (self.depth < MAX_TABLES) self.tables[self.depth].set(name);
        // Saturate rather than wrap: a stack that silently restarts at zero
        // would make an unrelated table the one a later pop lands on.
        if (self.depth < std.math.maxInt(usize)) self.depth += 1;
    }

    /// `.key_table = .deactivate` — pop one table.
    pub fn deactivate(self: *Model) void {
        if (self.depth > 0) self.depth -= 1;
    }

    /// `.key_table = .deactivate_all` — leave every table.
    pub fn deactivateAll(self: *Model) void {
        self.depth = 0;
    }

    /// `.key_sequence = .{ .trigger = t }` — one more key of a sequence has
    /// been pressed and the terminal is waiting for the next.
    pub fn pushTrigger(self: *Model, trigger: input.Binding.Trigger) void {
        if (self.key_count < MAX_KEYS) {
            var buf: [LABEL_CAP * 2]u8 = undefined;
            const n = menu_label.formatTrigger(trigger, &buf);
            self.keys[self.key_count].set(buf[0..n]);
        }
        if (self.key_count < std.math.maxInt(usize)) self.key_count += 1;
    }

    /// `.key_sequence = .end` — the sequence resolved or was abandoned.
    pub fn endSequence(self: *Model) void {
        self.key_count = 0;
    }

    /// Nothing to show. The pill hides on this, which is the common case:
    /// every pane, almost all of the time.
    pub fn isEmpty(self: *const Model) bool {
        return self.depth == 0 and self.key_count == 0;
    }

    /// Table names the pill can actually draw.
    pub fn visibleTables(self: *const Model) usize {
        return @min(self.depth, MAX_TABLES);
    }

    /// True when the stack is deeper than the names retained, so the pill can
    /// say so instead of implying the innermost table is the last one.
    pub fn tablesOverflow(self: *const Model) bool {
        return self.depth > MAX_TABLES;
    }

    pub fn tableName(self: *const Model, i: usize) []const u8 {
        if (i >= self.visibleTables()) return "";
        return self.tables[i].slice();
    }

    /// Pending keys the pill can actually draw.
    pub fn visibleKeys(self: *const Model) usize {
        return @min(self.key_count, MAX_KEYS);
    }

    pub fn keyLabel(self: *const Model, i: usize) []const u8 {
        if (i >= self.visibleKeys()) return "";
        return self.keys[i].slice();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a table stack pushes, pops, and clears" {
    var m: Model = .{};
    try testing.expect(m.isEmpty());

    m.activate("resize");
    try testing.expect(!m.isEmpty());
    try testing.expectEqual(@as(usize, 1), m.visibleTables());
    try testing.expectEqualStrings("resize", m.tableName(0));

    m.activate("nested");
    try testing.expectEqual(@as(usize, 2), m.visibleTables());
    try testing.expectEqualStrings("nested", m.tableName(1));

    // One pop leaves the outer table active — the whole reason this is a
    // stack and not a single value.
    m.deactivate();
    try testing.expectEqual(@as(usize, 1), m.visibleTables());
    try testing.expectEqualStrings("resize", m.tableName(0));

    m.activate("again");
    m.deactivateAll();
    try testing.expectEqual(@as(usize, 0), m.visibleTables());
    try testing.expect(m.isEmpty());
}

test "popping an empty stack is a no-op, not an underflow" {
    var m: Model = .{};
    m.deactivate();
    m.deactivate();
    try testing.expectEqual(@as(usize, 0), m.depth);
    // ...and the stack still works afterwards.
    m.activate("t");
    try testing.expectEqual(@as(usize, 1), m.visibleTables());
}

test "depth is counted past MAX_TABLES so a pop lands where it should" {
    var m: Model = .{};
    for (0..MAX_TABLES + 3) |i| {
        var buf: [8]u8 = undefined;
        m.activate(std.fmt.bufPrint(&buf, "t{d}", .{i}) catch unreachable);
    }
    try testing.expectEqual(MAX_TABLES, m.visibleTables());
    try testing.expect(m.tablesOverflow());

    // Three pops undo the three that were never drawn; the pill is still
    // full, and — critically — the stack is NOT empty.
    m.deactivate();
    m.deactivate();
    m.deactivate();
    try testing.expectEqual(MAX_TABLES, m.depth);
    try testing.expect(!m.tablesOverflow());
    try testing.expect(!m.isEmpty());
    try testing.expectEqualStrings("t0", m.tableName(0));
}

test "a pending sequence appends keys and clears on end" {
    var m: Model = .{};
    m.pushTrigger(.{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 1), m.visibleKeys());
    try testing.expectEqualStrings("Ctrl+A", m.keyLabel(0));

    m.pushTrigger(.{ .key = .{ .physical = .key_b } });
    try testing.expectEqual(@as(usize, 2), m.visibleKeys());
    try testing.expectEqualStrings("B", m.keyLabel(1));
    try testing.expect(!m.isEmpty());

    m.endSequence();
    try testing.expectEqual(@as(usize, 0), m.visibleKeys());
    try testing.expect(m.isEmpty());
}

test "the two states are independent" {
    var m: Model = .{};
    m.activate("resize");
    m.pushTrigger(.{ .key = .{ .physical = .key_x } });

    // Ending the sequence must not leave the table, and leaving the table
    // must not end a sequence: the core reports them as separate actions.
    m.endSequence();
    try testing.expectEqual(@as(usize, 1), m.visibleTables());
    try testing.expect(!m.isEmpty());

    m.pushTrigger(.{ .key = .{ .physical = .key_x } });
    m.deactivateAll();
    try testing.expectEqual(@as(usize, 1), m.visibleKeys());
    try testing.expect(!m.isEmpty());
}

test "an over-long sequence keeps counting without overrunning its slots" {
    var m: Model = .{};
    for (0..MAX_KEYS + 5) |_| {
        m.pushTrigger(.{ .key = .{ .physical = .key_q } });
    }
    try testing.expectEqual(MAX_KEYS, m.visibleKeys());
    try testing.expectEqual(MAX_KEYS + 5, m.key_count);
    try testing.expectEqualStrings("Q", m.keyLabel(MAX_KEYS - 1));
    // Out of range asks return nothing rather than stale slot contents.
    try testing.expectEqualStrings("", m.keyLabel(MAX_KEYS));
    m.endSequence();
    try testing.expectEqual(@as(usize, 0), m.key_count);
}

test "a long table name is elided, never sliced mid-codepoint" {
    var m: Model = .{};
    const long = "a" ** (NAME_CAP + 10);
    m.activate(long);
    const got = m.tableName(0);
    try testing.expect(got.len <= NAME_CAP);
    try testing.expect(std.mem.endsWith(u8, got, ELLIPSIS));
    try testing.expect(std.unicode.utf8ValidateSlice(got));

    // A multi-byte name cut exactly on a continuation byte still validates.
    m.deactivateAll();
    const wide = "\u{00e9}" ** (NAME_CAP); // 2 bytes each, so it must truncate
    m.activate(wide);
    try testing.expect(std.unicode.utf8ValidateSlice(m.tableName(0)));
    try testing.expect(m.tableName(0).len <= NAME_CAP);
}

test "a name that exactly fills its slot keeps every byte" {
    var m: Model = .{};
    const exact = "b" ** NAME_CAP;
    m.activate(exact);
    try testing.expectEqualStrings(exact, m.tableName(0));
}

test "truncateInto degrades sanely when there is no room for the ellipsis" {
    var buf: [2]u8 = undefined;
    // Two 2-byte codepoints into a 2-byte slot: one whole codepoint fits.
    const n = truncateInto(&buf, "\u{00e9}\u{00e9}");
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.unicode.utf8ValidateSlice(buf[0..n]));

    // A 3-byte codepoint into the same slot keeps nothing rather than half.
    var buf2: [2]u8 = undefined;
    const n2 = truncateInto(&buf2, "\u{2026}\u{2026}");
    try testing.expectEqual(@as(usize, 0), n2);
}

test "an empty name is stored as empty, not as an ellipsis" {
    var m: Model = .{};
    m.activate("");
    try testing.expectEqual(@as(usize, 1), m.visibleTables());
    try testing.expectEqualStrings("", m.tableName(0));
    try testing.expect(!m.isEmpty());
}
