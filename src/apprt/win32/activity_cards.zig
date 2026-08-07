//! Pure model for the Activity Monitor's machine-card carousel (T296) — the
//! switcher that moves the panel to another source WITHOUT opening a second
//! window.
//!
//! Mac's half is `RemoteActivityMonitorView.cardCarousel` (:788-855) plus
//! `MachineCard` (:1400) and `RemoteActivityMonitorModel.CardSummary` (:143).
//! Everything here is the part with no HWND in it: the card list and its
//! ordering, each card's summary state, the three lines of text a card paints,
//! and the focus-ring arithmetic. `ActivityMonitor.zig` keeps the GDI calls,
//! the machine-list fetch and the source switch — the same split that keeps
//! `activity_layout.zig` / `activity_rows.zig` runnable in the none-runtime
//! lane.
//!
//! Two rules are load-bearing and both are asserted below:
//!
//!   * **Local is always card 0.** The panel must always offer a way home: a
//!     remote panel whose machine went unreachable still has a card that works.
//!   * **Arrowing moves focus, never the source.** `moveFocus` is pure index
//!     arithmetic precisely so that no code path can make a keystroke dial.

const std = @import("std");

/// Local plus the registered machines the panel is willing to show at once.
/// `MachineChooser.MAX_DEVICES` is the sibling cap on the same directory list.
pub const max_cards: usize = 9;

/// What a card knows about its machine right now.
///
/// Mac has three states (`CardSummary.State`: connecting / failed / live)
/// because every card there is fed by a live probe. Windows has no such probe
/// yet (that is a follow-up), so an INACTIVE remote card reports what the relay
/// directory told us — hence `.idle`, which says "we are not connected to this
/// machine" rather than inventing a reading. A state we do not have is a state
/// we do not paint.
pub const State = enum {
    /// Not connected by us; `online` is the relay directory's word, not ours.
    idle,
    /// A dial or the first sample is in flight.
    connecting,
    /// The source is unreachable (dial failed, or the last sample failed).
    failed,
    /// Live metrics below are current.
    live,
};

/// The per-card readout. Zeroed fields mean "unknown", never "zero" — every
/// formatter below checks before it prints.
pub const Summary = struct {
    state: State = .idle,
    /// The relay directory's online flag. Only meaningful in `.idle`.
    online: bool = false,
    uptime_s: u64 = 0,
    cpu_pct: f32 = 0,
    mem_used: u64 = 0,
    mem_total: u64 = 0,
};

/// One card. `id` is empty for Local (its identity is the kind), and is the
/// relay device id for a machine — the same key `ActivityMonitor.Source`
/// compares on, so a rename can never split one machine across two cards.
pub const Card = struct {
    local: bool,
    id: []const u8 = "",
    label: []const u8,
    summary: Summary = .{},
};

/// Index of the card matching (`local`, `id`), or null. Identity is the id, not
/// the label — same rule as `Source.eql`.
pub fn indexOf(cards: []const Card, local: bool, id: []const u8) ?usize {
    for (cards, 0..) |c, i| {
        if (c.local != local) continue;
        if (local) return i;
        if (std.mem.eql(u8, c.id, id)) return i;
    }
    return null;
}

/// Move the focus ring by `delta`, clamped to the card range (Mac's
/// `moveFocus`, :845). Clamped rather than wrapped: a focus ring that leaps
/// from the last machine back to Local reads as a bug at the exact moment the
/// user is trying to find the end of the list.
///
/// Returns 0 when there are no cards, so a caller can hold the result
/// unconditionally.
pub fn moveFocus(focus: i32, delta: i32, count: usize) i32 {
    if (count == 0) return 0;
    const last: i32 = @intCast(count - 1);
    return std.math.clamp(focus + delta, 0, last);
}

/// The keystrokes the carousel's focus ring answers to, as a shape with no VK
/// numbers in it — `ActivityMonitor.handleKey` maps the virtual keys onto this
/// so the arithmetic stays runnable in the none-runtime lane.
pub const FocusKey = enum { left, right, home, end };

/// Where `key` puts the focus ring (T300). Home and End are expressed as a
/// FULL-LENGTH step rather than a literal 0 / count-1, so `moveFocus`'s clamp
/// stays the one place the range is enforced — an edge key and an arrow key
/// that ran off the end must not be able to disagree about where the end is.
pub fn focusFor(key: FocusKey, focus: i32, count: usize) i32 {
    const span: i32 = @intCast(count);
    return moveFocus(focus, switch (key) {
        .left => -1,
        .right => 1,
        .home => -span,
        .end => span,
    }, count);
}

/// Whether the carousel band appears at all. One card controls nothing, and
/// design system §6 says chrome that controls nothing does not appear.
pub fn hasCarousel(count: usize) bool {
    return count > 1;
}

/// The horizontal scroll that brings card `index` fully into a `view_w`-wide
/// viewport, given the current `scroll_x`. Returns `scroll_x` unchanged when the
/// card is already fully visible — so arrowing across visible cards never
/// jitters the strip.
///
/// `left`/`right` are the card's painted edges at `scroll_x == 0`, i.e. content
/// coordinates; the caller derives them from `activity_layout.cardRect`.
pub fn scrollToShow(scroll_x: i32, left: i32, right: i32, view_w: i32, margin: i32) i32 {
    if (view_w <= 0) return scroll_x;
    var out = scroll_x;
    if (left - margin < out) out = @max(0, left - margin);
    if (right + margin > out + view_w) out = right + margin - view_w;
    return out;
}

/// Clamp a carousel scroll to the content it has. `content_w` is
/// `activity_layout.carouselContentWidth`.
pub fn clampScroll(scroll_x: i32, content_w: i32, view_w: i32) i32 {
    const max_scroll = @max(0, content_w - view_w);
    return std.math.clamp(scroll_x, 0, max_scroll);
}

// ---------------------------------------------------------------------
// Card text
// ---------------------------------------------------------------------

/// "up 3d 4h" / "up 5h 12m" / "up 7m" from a seconds count — Mac's
/// `MachineCard.uptimeString` (:1496). Zero is unknown, not "up 0m".
pub fn uptimeString(buf: []u8, seconds: u64) []const u8 {
    if (seconds == 0) return "";
    const days = seconds / 86_400;
    const hours = (seconds % 86_400) / 3_600;
    const mins = (seconds % 3_600) / 60;
    if (days > 0) return std.fmt.bufPrint(buf, "up {d}d {d}h", .{ days, hours }) catch "";
    if (hours > 0) return std.fmt.bufPrint(buf, "up {d}h {d}m", .{ hours, mins }) catch "";
    return std.fmt.bufPrint(buf, "up {d}m", .{mins}) catch "";
}

/// The card's second line (Mac's `summaryLine`, :1419). `switching` is true only
/// for the card the panel is currently dialing.
pub fn summaryLine(buf: []u8, s: Summary, switching: bool) []const u8 {
    if (switching) return "connecting…";
    return switch (s.state) {
        .connecting => "connecting…",
        .failed => "unreachable",
        // We have not dialed this machine; the directory's flag is all we know,
        // and saying so beats a dash that could mean anything.
        .idle => if (s.online) "online" else "offline",
        .live => blk: {
            const up = uptimeString(buf, s.uptime_s);
            break :blk if (up.len > 0) up else "—";
        },
    };
}

/// The card's third line (Mac's `metricLine`, :1429), or empty when there is no
/// live reading to show. Mem% needs a total to divide by; a card with no total
/// prints nothing rather than 0%.
pub fn metricLine(buf: []u8, s: Summary) []const u8 {
    if (s.state != .live or s.mem_total == 0) return "";
    const cpu: u32 = @intFromFloat(@round(std.math.clamp(s.cpu_pct, 0, 100)));
    const mem_ratio = @as(f64, @floatFromInt(s.mem_used)) / @as(f64, @floatFromInt(s.mem_total));
    const mem: u32 = @intFromFloat(@round(std.math.clamp(mem_ratio, 0, 1) * 100));
    return std.fmt.bufPrint(buf, "CPU {d}% · Mem {d}%", .{ cpu, mem }) catch "";
}

/// The status dot's meaning, kept separate from its color so the palette lives
/// with the painter and the RULE lives here.
pub const Dot = enum { good, pending, bad, unknown };

pub fn dot(s: Summary, switching: bool) Dot {
    if (switching) return .pending;
    return switch (s.state) {
        .connecting => .pending,
        .failed => .bad,
        .live => .good,
        .idle => if (s.online) .good else .unknown,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn machine(id: []const u8, label: []const u8) Card {
    return .{ .local = false, .id = id, .label = label };
}

test "indexOf: identity is the id, not the label" {
    const cards = [_]Card{
        .{ .local = true, .label = "Local" },
        machine("dev-1", "Winbox"),
        machine("dev-2", "Laptop"),
    };
    try testing.expectEqual(@as(?usize, 0), indexOf(&cards, true, ""));
    try testing.expectEqual(@as(?usize, 1), indexOf(&cards, false, "dev-1"));
    try testing.expectEqual(@as(?usize, 2), indexOf(&cards, false, "dev-2"));
    try testing.expectEqual(@as(?usize, null), indexOf(&cards, false, "dev-3"));
    // A renamed machine keeps its card.
    const renamed = [_]Card{ .{ .local = true, .label = "Local" }, machine("dev-1", "Studio") };
    try testing.expectEqual(@as(?usize, 1), indexOf(&renamed, false, "dev-1"));
}

test "indexOf: Local is found by kind, whatever its label" {
    const cards = [_]Card{machine("dev-1", "Winbox")};
    try testing.expectEqual(@as(?usize, null), indexOf(&cards, true, ""));
}

test "moveFocus: clamps at both ends and survives an empty list" {
    try testing.expectEqual(@as(i32, 0), moveFocus(0, -1, 3));
    try testing.expectEqual(@as(i32, 1), moveFocus(0, 1, 3));
    try testing.expectEqual(@as(i32, 2), moveFocus(2, 1, 3));
    try testing.expectEqual(@as(i32, 2), moveFocus(2, 5, 3));
    try testing.expectEqual(@as(i32, 0), moveFocus(1, -9, 3));
    try testing.expectEqual(@as(i32, 0), moveFocus(4, 1, 0));
}

test "focusFor: arrows step, Home and End jump to the ends" {
    try testing.expectEqual(@as(i32, 0), focusFor(.left, 1, 4));
    try testing.expectEqual(@as(i32, 2), focusFor(.right, 1, 4));
    try testing.expectEqual(@as(i32, 0), focusFor(.home, 3, 4));
    try testing.expectEqual(@as(i32, 3), focusFor(.end, 0, 4));
    // Already at an end: the edge key holds, it does not wrap to the other one.
    try testing.expectEqual(@as(i32, 0), focusFor(.home, 0, 4));
    try testing.expectEqual(@as(i32, 3), focusFor(.end, 3, 4));
    // Home and End agree with an arrow that ran off the same end — the whole
    // point of routing both through `moveFocus`'s clamp.
    try testing.expectEqual(focusFor(.end, 0, 4), moveFocus(0, 99, 4));
    try testing.expectEqual(focusFor(.home, 3, 4), moveFocus(3, -99, 4));
    // No cards, no ring.
    try testing.expectEqual(@as(i32, 0), focusFor(.end, 0, 0));
}

test "hasCarousel: one source paints no switcher" {
    try testing.expect(!hasCarousel(0));
    try testing.expect(!hasCarousel(1));
    try testing.expect(hasCarousel(2));
}

test "scrollToShow: leaves an already-visible card alone" {
    // A card at 20..200 inside a 0..600 viewport needs no scroll.
    try testing.expectEqual(@as(i32, 0), scrollToShow(0, 20, 200, 600, 16));
}

test "scrollToShow: brings a card past either edge into view" {
    // Off the right edge: scroll so right + margin == view width.
    try testing.expectEqual(@as(i32, 116), scrollToShow(0, 520, 700, 600, 16));
    // Off the left edge: scroll back to the card's left minus the margin.
    try testing.expectEqual(@as(i32, 84), scrollToShow(300, 100, 280, 600, 16));
    // Never negative: the first card's margin cannot push the strip past 0.
    try testing.expectEqual(@as(i32, 0), scrollToShow(50, 4, 180, 600, 16));
}

test "clampScroll: content narrower than the view cannot scroll" {
    try testing.expectEqual(@as(i32, 0), clampScroll(120, 300, 600));
    try testing.expectEqual(@as(i32, 200), clampScroll(999, 800, 600));
    try testing.expectEqual(@as(i32, 0), clampScroll(-5, 800, 600));
}

test "uptimeString: days, hours, minutes — and unknown stays empty" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", uptimeString(&buf, 0));
    try testing.expectEqualStrings("up 7m", uptimeString(&buf, 7 * 60));
    try testing.expectEqualStrings("up 5h 12m", uptimeString(&buf, 5 * 3600 + 12 * 60));
    try testing.expectEqualStrings("up 3d 4h", uptimeString(&buf, 3 * 86400 + 4 * 3600));
}

test "summaryLine: every state says something true" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("connecting…", summaryLine(&buf, .{ .state = .connecting }, false));
    try testing.expectEqualStrings("unreachable", summaryLine(&buf, .{ .state = .failed }, false));
    try testing.expectEqualStrings("online", summaryLine(&buf, .{ .state = .idle, .online = true }, false));
    try testing.expectEqualStrings("offline", summaryLine(&buf, .{ .state = .idle, .online = false }, false));
    try testing.expectEqualStrings("up 2m", summaryLine(&buf, .{ .state = .live, .uptime_s = 120 }, false));
    // Live with no uptime is a real gap, not a zero.
    try testing.expectEqualStrings("—", summaryLine(&buf, .{ .state = .live }, false));
    // Switching wins over whatever the card knew a moment ago.
    try testing.expectEqualStrings("connecting…", summaryLine(&buf, .{ .state = .live, .uptime_s = 120 }, true));
}

test "metricLine: only a live card with a memory total prints numbers" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("", metricLine(&buf, .{ .state = .idle, .online = true }));
    try testing.expectEqualStrings("", metricLine(&buf, .{ .state = .live, .cpu_pct = 30 }));
    try testing.expectEqualStrings("CPU 30% · Mem 50%", metricLine(&buf, .{
        .state = .live,
        .cpu_pct = 30,
        .mem_used = 8,
        .mem_total = 16,
    }));
    // Out-of-range readings are clamped, never printed raw.
    try testing.expectEqualStrings("CPU 100% · Mem 100%", metricLine(&buf, .{
        .state = .live,
        .cpu_pct = 4000,
        .mem_used = 32,
        .mem_total = 16,
    }));
}

test "dot: an idle card reports the directory's flag, not a guess" {
    try testing.expectEqual(Dot.good, dot(.{ .state = .idle, .online = true }, false));
    try testing.expectEqual(Dot.unknown, dot(.{ .state = .idle, .online = false }, false));
    try testing.expectEqual(Dot.pending, dot(.{ .state = .connecting }, false));
    try testing.expectEqual(Dot.bad, dot(.{ .state = .failed }, false));
    try testing.expectEqual(Dot.good, dot(.{ .state = .live }, false));
    // Mid-dial the active card is pending whatever it knew before.
    try testing.expectEqual(Dot.pending, dot(.{ .state = .live }, true));
}
