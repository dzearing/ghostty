//! Pure geometry for the win32 tab strip (T202). No OS imports, so these unit
//! tests run in every app-runtime lane (the `split_geometry.zig` pattern).
//! The painting half is `paintTabBar` in Window.zig; the hit tests
//! (`handleTabBarClick`, `handleTabBarMouseMove`, `handleTabBarRightClick`)
//! consume the same rects, which is what keeps what you see and what you can
//! click from drifting apart.
//!
//! Target and measurements: `docs/design/win32-tab-strip.md`. The short
//! version, from reading pixels off a live Windows Terminal:
//!
//!   * A tab's width is its EQUAL SHARE of the strip, clamped to
//!     [min, max] — never the remainder. Three tabs on a 1610px strip took
//!     900px and left 700px empty. The old code handed the last tab
//!     `available - x`, so a single tab spanned the whole window; that one
//!     rule produced three of the four things the user called amateur (close
//!     button flung to the far edge, "+" jammed against the tab, and a
//!     full-width accent rule).
//!   * The "+" travels with the last tab (WinUI `AddTabButton`); the menu
//!     button is pinned right (WinUI `TabStripFooter`). Pinning both right
//!     made them read as one undifferentiated cluster.
//!   * Tabs can never be laid out under the button band. When they will not
//!     all fit at `min_tab_w`, the ones that do not fit get NO rect at all —
//!     invisible and unhittable — instead of being drawn off the end and
//!     painted over.

const std = @import("std");
const testing = std.testing;

/// Negative control for `test/win32/tab-strip.ps1` (project standard: an
/// acceptance script has to be SHOWN to fail, or it is not evidence). Flip to
/// `true`, rebuild `-Dapp-runtime=win32`, and re-run the script: it restores
/// the pre-T202 rule where the last tab is handed whatever width is left, so
/// the single-tab-width, tab-width-clamp and last-tab→"+" gap assertions must
/// fail — and the accent-rule and hit-test assertions must NOT.
///
/// Left in the source rather than behind a build option so the control is one
/// edit away from any future reader of this module, and so the unit tests
/// below pin the shipped (`false`) behavior on every build.
const T202_NEUTERED = false;

/// A rectangle in physical pixels, right/bottom exclusive. Mirrors `w32.RECT`
/// field-for-field so Window.zig can copy one into the other; declared here so
/// this module needs no OS import.
pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: Rect, x: i32) bool {
        return x >= self.left and x < self.right;
    }
};

/// Every DIP constant the strip is built from, resolved to physical pixels for
/// one DPI scale. Values and their rationale: `docs/design/win32-tab-strip.md`.
pub const Metrics = struct {
    /// Strip height. Deliberately 32 DIP, not Windows Terminal's measured 40:
    /// WT's strip IS the titlebar and spends 8 DIP of it on a drag region,
    /// while ours sits under a real caption bar.
    bar_h: i32,
    /// Strip background left above the chiclet, so its rounded top corners
    /// have something to read against.
    tab_top_pad: i32,
    min_tab_w: i32,
    max_tab_w: i32,
    /// Top-corner radius of the selected/hovered chiclet (bottom corners stay
    /// square — the tab merges into the pane below it).
    corner_r: i32,
    /// Inset before the first tab.
    strip_pad_l: i32,
    /// Inset after the menu button. Its own metric rather than folded into
    /// the `client_w` arithmetic for two reasons: the user caught the strip
    /// being asymmetric without it ("the hamburger button has no gap between
    /// it and the border"), and once the strip shares a row with the caption
    /// buttons (T205) this becomes the gap to the caption group rather than
    /// to the window edge.
    strip_pad_r: i32,
    /// Separation last-tab → "+", and "+" → menu button.
    group_gap: i32,
    /// Width of the "+" and "≡" buttons (T190 kept them equal).
    btn_w: i32,
    /// Close-button hit box inside a tab.
    close_btn_w: i32,
    /// Leading padding before the title.
    text_pad: i32,
    /// T72 user tab-color tag thickness.
    stripe_h: i32,
    /// A 1 DIP rule (the inter-tab separator), never thinner than a pixel.
    hairline: i32,
    /// Corner radius of the "+"/"≡" hover fill. Windows 11 lights a button
    /// as a rounded rect inset inside its hit box, not as a full-bleed
    /// square — the square is what made the two read as one slab.
    btn_corner_r: i32,
    /// Inset of that fill inside the button's hit box.
    btn_inset_x: i32,
    btn_inset_y: i32,

    pub fn init(scale: f32) Metrics {
        return .{
            .bar_h = px(32.0, scale),
            .tab_top_pad = px(3.0, scale),
            .min_tab_w = px(60.0, scale),
            .max_tab_w = px(200.0, scale),
            .corner_r = px(6.0, scale),
            .strip_pad_l = px(4.0, scale),
            .strip_pad_r = px(4.0, scale),
            .group_gap = px(8.0, scale),
            .btn_w = px(36.0, scale),
            .close_btn_w = px(20.0, scale),
            .text_pad = px(10.0, scale),
            .stripe_h = @max(px(3.0, scale), 2),
            .hairline = @max(px(1.0, scale), 1),
            .btn_corner_r = px(4.0, scale),
            .btn_inset_x = px(2.0, scale),
            .btn_inset_y = px(4.0, scale),
        };
    }

    fn px(dip: f32, scale: f32) i32 {
        return @intFromFloat(@round(dip * scale));
    }

    /// The close button's box inside a tab, shared by the painter and both
    /// hit tests. It used to be recomputed in three places from two loose
    /// constants, which is how a geometry change could silently move the
    /// glyph away from the thing you click.
    pub fn closeRect(self: Metrics, tab: Rect) Rect {
        const left = tab.right - self.close_btn_w - @divTrunc(self.text_pad, 2);
        const mid = @divTrunc(tab.top + tab.bottom, 2);
        return .{
            .left = left,
            .top = mid - @divTrunc(self.close_btn_w, 2),
            .right = left + self.close_btn_w,
            .bottom = mid + @divTrunc(self.close_btn_w, 2),
        };
    }

    /// The title's box inside a tab: after the leading padding, stopping
    /// before the close button.
    pub fn titleRect(self: Metrics, tab: Rect) Rect {
        return .{
            .left = tab.left + self.text_pad,
            .top = tab.top,
            .right = tab.right - self.close_btn_w - self.text_pad,
            .bottom = tab.bottom,
        };
    }
};

/// Upper bound on tabs a strip can lay out, matching `Window.MAX_TABS`. The
/// caller supplies the output buffer, so this is only a sanity clamp.
pub const MAX_TABS: usize = 64;

/// The resolved strip. `tabs[0..visible]` are the tabs that got a rect; any
/// tab index >= `visible` is deliberately not laid out (see the module doc)
/// and its rect must be zeroed by the caller so hit tests miss it.
pub const Strip = struct {
    /// How many tabs fit. Never greater than the requested count.
    visible: usize = 0,
    /// Uniform tab width actually used. 0 when nothing fit.
    tab_w: i32 = 0,
    /// Right edge of the last laid-out tab (== `strip_pad_l` when none fit).
    tabs_right: i32 = 0,
    new_tab: Rect = .{},
    menu: Rect = .{},
};

/// Resolve the strip for `client_w` pixels of client width and `tab_count`
/// tabs, writing tab rects into `out` (which must hold at least `tab_count`
/// entries; entries past `visible` are zeroed).
pub fn layout(m: Metrics, client_w: i32, tab_count: usize, out: []Rect) Strip {
    std.debug.assert(out.len >= tab_count);
    for (out[0..tab_count]) |*r| r.* = .{};

    // The menu button is pinned to the right END OF THE STRIP — inset by
    // `strip_pad_r`, matching the inset the first tab gets on the left. The
    // "+" may travel, but never past `group_gap` short of the menu button.
    const menu_right = client_w - m.strip_pad_r;
    const menu_left = menu_right - m.btn_w;
    const plus_limit = menu_left - m.group_gap - m.btn_w;

    var s: Strip = .{
        .tabs_right = m.strip_pad_l,
        .menu = .{ .left = menu_left, .top = 0, .right = menu_right, .bottom = m.bar_h },
        .new_tab = .{ .left = plus_limit, .top = 0, .right = plus_limit + m.btn_w, .bottom = m.bar_h },
    };

    // Width the tabs may occupy: up to `group_gap` short of the "+"'s limit.
    const tabs_avail = plus_limit - m.group_gap - m.strip_pad_l;
    if (tab_count == 0 or tabs_avail < m.min_tab_w) return s;

    // Equal share, clamped. This is the whole anti-stretch rule: with one tab
    // and a wide window the share is enormous and the clamp cuts it to
    // `max_tab_w`, leaving dead strip space exactly as Windows Terminal does.
    const count_i: i32 = @intCast(@min(tab_count, MAX_TABS));
    var w = @divTrunc(tabs_avail, count_i);
    w = @max(w, m.min_tab_w);
    w = @min(w, m.max_tab_w);

    // At `min_tab_w` some tabs may still not fit. Those get no rect rather
    // than a rect under the button band.
    const fits: usize = @intCast(@divTrunc(tabs_avail, w));
    const visible = @min(tab_count, fits);

    var x = m.strip_pad_l;
    for (out[0..visible], 0..) |*r, i| {
        // The neuter restores the exact rule T202 removed: the last tab takes
        // everything that is left, which is what stretched a single tab
        // across the whole window.
        const this_w = if (T202_NEUTERED and i + 1 == visible)
            @max(m.strip_pad_l + tabs_avail - x, m.min_tab_w)
        else
            w;
        r.* = .{ .left = x, .top = m.tab_top_pad, .right = x + this_w, .bottom = m.bar_h };
        x += this_w;
    }

    s.visible = visible;
    s.tab_w = w;
    s.tabs_right = x;
    const plus_left = @min(x + m.group_gap, plus_limit);
    s.new_tab = .{ .left = plus_left, .top = 0, .right = plus_left + m.btn_w, .bottom = m.bar_h };
    return s;
}

/// The chiclet's clip shape, expressed as the rect to hand
/// `CreateRoundRectRgn`. The bottom is pushed past the strip so only the TOP
/// corners round — the tab merges into the pane below it, which is how a
/// WinUI TabView marks selection (and why it needs no underline).
pub const RoundRegion = struct {
    left: i32,
    top: i32,
    /// Exclusive, already +1'd for `CreateRoundRectRgn`.
    right: i32,
    /// Exclusive, already +1'd, and past `bar_h` so the bottom corners are
    /// clipped away by the strip's own bitmap.
    bottom: i32,
    /// The `w`/`h` arguments (diameter, not radius).
    ellipse: i32,
};

pub fn chicletRegion(m: Metrics, tab: Rect) RoundRegion {
    return .{
        .left = tab.left,
        .top = tab.top,
        .right = tab.right + 1,
        .bottom = m.bar_h + m.corner_r + 1,
        .ellipse = m.corner_r * 2,
    };
}

/// The rounded fill lit under a hovered/open "+" or "≡", inset inside the
/// button's hit box. Returned as a `RoundRegion` for the same reason the
/// chiclet is — one `CreateRoundRectRgn` call site.
pub fn buttonFillRegion(m: Metrics, btn: Rect) RoundRegion {
    return .{
        .left = btn.left + m.btn_inset_x,
        .top = btn.top + m.btn_inset_y,
        .right = btn.right - m.btn_inset_x + 1,
        .bottom = btn.bottom - m.btn_inset_y + 1,
        .ellipse = m.btn_corner_r * 2,
    };
}

/// The 1px separator drawn between two adjacent tabs when neither is selected
/// or hovered (Windows Terminal draws one; it is what keeps transparent tabs
/// from reading as one run of text). Vertically inset to the middle ~50%.
pub fn separatorRect(m: Metrics, tab: Rect) Rect {
    const h = tab.bottom - tab.top;
    const inset = @divTrunc(h, 4);
    return .{
        .left = tab.right - m.hairline,
        .top = tab.top + inset,
        .right = tab.right,
        .bottom = tab.bottom - inset,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const WIDE: i32 = 1600;

fn layoutN(scale: f32, client_w: i32, n: usize, buf: []Rect) struct { Metrics, Strip } {
    const m = Metrics.init(scale);
    return .{ m, layout(m, client_w, n, buf) };
}

test "one tab is clamped to max width, not stretched across the window" {
    // THE bug this module exists for. `Window.zig` used to hand the last tab
    // `available - x`, so with one tab it took the entire strip.
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 1, &buf);
        try testing.expectEqual(@as(usize, 1), s.visible);
        try testing.expectEqual(m.max_tab_w, buf[0].width());
        // ... and there is real dead strip space left over.
        try testing.expect(s.tabs_right < @divTrunc(WIDE, 2));
    }
}

test "the tab area never reaches the button band" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        for ([_]usize{ 1, 2, 3, 8, 20, 40, 64 }) |n| {
            const m, const s = layoutN(scale, WIDE, n, &buf);
            if (s.visible == 0) continue;
            try testing.expect(s.tabs_right + m.group_gap <= s.new_tab.left);
            try testing.expect(s.new_tab.right + m.group_gap <= s.menu.left);
            // The strip is inset by the SAME amount at both ends. Without a
            // right inset the menu button sat flush on the window border
            // while the first tab was inset by 4 — asymmetric by omission,
            // and the user caught it.
            try testing.expectEqual(m.strip_pad_l, m.strip_pad_r);
            try testing.expectEqual(WIDE, s.menu.right + m.strip_pad_r);
            // Every laid-out tab is left of the "+".
            for (buf[0..s.visible]) |r| try testing.expect(r.right <= s.new_tab.left);
        }
    }
}

test "the + follows the last tab and stops at its limit" {
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);

    const one = layout(m, WIDE, 1, &buf);
    const two = layout(m, WIDE, 2, &buf);
    const three = layout(m, WIDE, 3, &buf);
    // Adding a tab moves the "+" right by exactly one tab width...
    try testing.expectEqual(one.new_tab.left + m.max_tab_w, two.new_tab.left);
    try testing.expectEqual(two.new_tab.left + m.max_tab_w, three.new_tab.left);
    // ... and it is a real gap, not zero (the "clipped" look).
    try testing.expect(one.new_tab.left - one.tabs_right == m.group_gap);

    // Once the tabs fill the strip the "+" stops at its limit and stays put.
    const many = layout(m, WIDE, 40, &buf);
    const more = layout(m, WIDE, 64, &buf);
    try testing.expectEqual(many.new_tab.left, more.new_tab.left);
    try testing.expect(many.new_tab.right + m.group_gap <= many.menu.left);
}

test "tabs shrink with count, then overflow instead of running off the end" {
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);

    try testing.expectEqual(m.max_tab_w, layout(m, WIDE, 2, &buf).tab_w);
    // Enough tabs to force a shrink below max...
    const eight = layout(m, WIDE, 8, &buf);
    try testing.expect(eight.tab_w < m.max_tab_w);
    try testing.expect(eight.tab_w > m.min_tab_w);
    try testing.expectEqual(@as(usize, 8), eight.visible);
    // ... and enough to hit the floor, after which tabs are dropped, not
    // painted under the buttons.
    const flood = layout(m, WIDE, 64, &buf);
    try testing.expectEqual(m.min_tab_w, flood.tab_w);
    try testing.expect(flood.visible < 64);
    try testing.expect(flood.visible > 0);
    // Dropped tabs have a zero rect, so a hit test can never find them.
    for (buf[flood.visible..64]) |r| try testing.expect(r.isEmpty());
}

test "tabs tile the strip left to right with no gaps or overlaps" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 6, &buf);
        try testing.expectEqual(m.strip_pad_l, buf[0].left);
        for (buf[1..s.visible], 0..) |r, i| {
            try testing.expectEqual(buf[i].right, r.left);
            try testing.expectEqual(buf[i].width(), r.width());
        }
        // Tabs hang below the strip top by the pad, and reach the bottom so
        // the selected one merges into the pane.
        for (buf[0..s.visible]) |r| {
            try testing.expectEqual(m.tab_top_pad, r.top);
            try testing.expectEqual(m.bar_h, r.bottom);
        }
    }
}

test "a window too narrow for a tab still lays out its buttons" {
    // A degenerate strip must not produce negative widths or a tab drawn on
    // top of the menu button; the buttons matter more than the tabs there.
    var buf: [MAX_TABS]Rect = undefined;
    const m = Metrics.init(1.0);
    for ([_]i32{ 0, 10, 60, 100, 130 }) |w| {
        const s = layout(m, w, 3, &buf);
        try testing.expectEqual(@as(usize, 0), s.visible);
        try testing.expectEqual(w - m.strip_pad_r, s.menu.right);
        for (buf[0..3]) |r| try testing.expect(r.isEmpty());
    }
    // Just wide enough for one minimum tab, and it appears.
    const ok = layout(m, m.strip_pad_l + m.strip_pad_r + m.min_tab_w + m.group_gap * 2 + m.btn_w * 2, 3, &buf);
    try testing.expectEqual(@as(usize, 1), ok.visible);
    try testing.expectEqual(m.min_tab_w, ok.tab_w);
}

test "close and title boxes stay inside their tab, close after title" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 3, &buf);
        for (buf[0..s.visible]) |tab| {
            const close = m.closeRect(tab);
            const title = m.titleRect(tab);
            try testing.expect(close.left > tab.left);
            try testing.expect(close.right <= tab.right);
            try testing.expect(close.top >= tab.top);
            try testing.expect(close.bottom <= tab.bottom);
            try testing.expect(title.left > tab.left);
            try testing.expect(title.right <= close.left);
        }
    }
}

test "the chiclet rounds only its top corners" {
    var buf: [MAX_TABS]Rect = undefined;
    const m, const s = layoutN(1.0, WIDE, 2, &buf);
    _ = s;
    const rr = chicletRegion(m, buf[0]);
    try testing.expectEqual(buf[0].left, rr.left);
    try testing.expectEqual(buf[0].top, rr.top);
    try testing.expectEqual(buf[0].right + 1, rr.right);
    // The rounded bottom is pushed past the strip, so the strip's own bitmap
    // clips it and the tab meets the pane with square corners.
    try testing.expect(rr.bottom > m.bar_h);
    try testing.expectEqual(m.corner_r * 2, rr.ellipse);
}

test "a button's hover fill is inset inside its hit box, on both buttons" {
    var buf: [MAX_TABS]Rect = undefined;
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        const m, const s = layoutN(scale, WIDE, 2, &buf);
        for ([_]Rect{ s.new_tab, s.menu }) |btn| {
            const f = buttonFillRegion(m, btn);
            try testing.expect(f.left > btn.left);
            try testing.expect(f.right - 1 < btn.right);
            try testing.expect(f.top > btn.top);
            try testing.expect(f.bottom - 1 < btn.bottom);
            try testing.expect(f.ellipse > 0);
        }
    }
}

test "the separator is a 1px hairline inset inside the tab" {
    var buf: [MAX_TABS]Rect = undefined;
    const m, _ = layoutN(1.0, WIDE, 2, &buf);
    const sep = separatorRect(m, buf[0]);
    try testing.expectEqual(m.hairline, sep.width());
    try testing.expectEqual(buf[0].right, sep.right);
    try testing.expect(sep.top > buf[0].top);
    try testing.expect(sep.bottom < buf[0].bottom);
}
