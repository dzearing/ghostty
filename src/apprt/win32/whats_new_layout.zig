//! Geometry for the "What's New in Ghoztty" window (T624). Pure — no OS
//! imports — so it is asserted at every DPI scale in every app-runtime lane,
//! per `docs/design/win32-design-system.md`.
//!
//! Two halves:
//!
//!   - the window FRAME: the tab run across the top, the hairline under it,
//!     and the scrolling viewport below;
//!   - the content FLOW: the spacing steps and indents a release block is
//!     built from, plus the scroll clamp.
//!
//! Text extents are measured by the caller and passed in — this file owns the
//! numbers around the text, never the text itself, which is the shape every
//! other win32 layout module here takes.
//!
//! Mac parity: `WhatsNewWindowView` opens at 700x740 pt with a 420x320 floor
//! and a `TabView` between Client and Agent. Windows has no `TabView`, so the
//! tab run is the Win11 "pivot" the rest of this app already reads like — a
//! leading-aligned row of labels with an accent underline beneath the
//! selected one — rather than the 3D notebook tabs of `SysTabControl32`.
//! Every spacing value below is a step on the design system's scale.

const std = @import("std");
const type_ramp = @import("type_ramp.zig");

/// A physical-pixel rectangle. Local so this module imports no OS headers.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and x < self.x + self.w and
            y >= self.y and y < self.y + self.h;
    }
};

/// The two tabs, in the order Mac lists them.
pub const Tab = enum(u8) {
    client = 0,
    agent = 1,

    pub const count: usize = 2;

    pub fn label(self: Tab) []const u8 {
        return switch (self) {
            .client => "Client",
            .agent => "Agent",
        };
    }
};

fn px(dip: f32, scale: f32) i32 {
    return @intFromFloat(@round(dip * scale));
}

// Design-system spacing scale (§1): xs 2, sm 4, md 8, lg 12, xl 16, xxl 24.
const dip_xs: f32 = 2;
const dip_sm: f32 = 4;
const dip_md: f32 = 8;
const dip_lg: f32 = 12;
const dip_xl: f32 = 16;
const dip_xxl: f32 = 24;

/// How much air the notes get (T625). Mac's `WhatsNewNotesContent` takes the
/// same knob: one renderer, two spacings, so the window and the alert
/// accessory cannot drift about what a release note looks like.
///
/// `spacious` is the window — the reader has a whole window and is browsing.
/// `compact` is an accessory inside a dialog, where the notes are the evidence
/// for a decision the user is being asked to make right now and every step on
/// the scale drops one notch. Only the SPACING changes: the type ramp, the
/// bullet shape and the order are the window's, which is what makes the
/// accessory recognisable as the same thing.
pub const Density = enum { spacious, compact };

/// Every number the window draws with, resolved for one DPI scale.
pub const Metrics = struct {
    /// Dialog content inset (xl).
    margin: i32,
    /// Height of the tab run, text line box plus md above and below.
    tab_h: i32,
    /// Horizontal padding inside one tab, around its measured label (lg).
    tab_pad_x: i32,
    /// Gap between two tabs (sm) — they are one run, not two groups.
    tab_gap: i32,
    /// The selected tab's accent underline (xs), and the hairline under the
    /// whole run that it sits on top of.
    underline_h: i32,
    rule_h: i32,
    /// Gap between one release block and the next (xxl). Mac's spacious
    /// density uses its own larger number; here the scale is the authority.
    release_gap: i32,
    /// Gap between a release's version heading and its sections (lg).
    section_gap: i32,
    /// Gap between the bullets within a section (md).
    item_gap: i32,
    /// Gap between a bullet's title line and its body line (xs).
    item_line_gap: i32,
    /// Space between the bullet glyph and the text it marks (md).
    bullet_gap: i32,
    /// How far a bullet's text is indented from the block's leading edge.
    /// The glyph sits in this gutter, so every wrapped line aligns under the
    /// first rather than under the dot.
    bullet_indent: i32,
    /// Vertical padding above and below the labelled "already installed"
    /// rule (lg).
    rule_gap: i32,
    /// One mouse-wheel notch, in pixels of content.
    wheel_step: i32,
    /// Width of the scrollbar gutter reserved at the trailing edge.
    scrollbar_w: i32,
};

/// The window's spacing — `metricsFor(scale, .spacious)`, kept as the bare
/// name because the window is what every existing caller means.
pub fn metrics(scale: f32) Metrics {
    return metricsFor(scale, .spacious);
}

pub fn metricsFor(scale: f32, density: Density) Metrics {
    const line = type_ramp.lineBox(type_ramp.body(scale), scale);
    // One notch down the scale per step, so the compact block stays legible
    // and keeps the same ORDER (a release break wider than a section break,
    // wider than a bullet gap) — the thing the eye actually reads.
    const compact = density == .compact;
    const dip_margin: f32 = if (compact) dip_lg else dip_xl;
    const dip_release: f32 = if (compact) dip_xl else dip_xxl;
    const dip_section: f32 = if (compact) dip_md else dip_lg;
    const dip_item: f32 = if (compact) dip_sm else dip_md;
    return .{
        .margin = px(dip_margin, scale),
        .tab_h = line + 2 * px(dip_md, scale),
        .tab_pad_x = px(dip_lg, scale),
        .tab_gap = px(dip_sm, scale),
        .underline_h = px(dip_xs, scale),
        .rule_h = @max(1, px(1, scale)),
        .release_gap = px(dip_release, scale),
        .section_gap = px(dip_section, scale),
        .item_gap = px(dip_item, scale),
        .item_line_gap = px(dip_xs, scale),
        .bullet_gap = px(dip_md, scale),
        .bullet_indent = px(dip_lg, scale),
        .rule_gap = px(if (compact) dip_md else dip_lg, scale),
        .wheel_step = 3 * line,
        .scrollbar_w = px(dip_lg, scale),
    };
}

/// The content size the window opens at, before the caller clamps it to the
/// work area — Mac's `defaultContentSize`, in physical pixels.
pub fn defaultSize(scale: f32) struct { w: i32, h: i32 } {
    return .{ .w = px(700, scale), .h = px(740, scale) };
}

/// The height a dialog accessory's scroll area gets (T625), in physical
/// pixels. Fixed on purpose: the notes scroll INSIDE it, so a release with
/// twelve bullets and one with two produce the same dialog. A dialog that
/// resized itself around its evidence would move the buttons the user is
/// reaching for.
pub fn accessoryHeight(scale: f32) i32 {
    return px(196, scale);
}

/// How far down the window may be dragged — Mac's `minimumContentSize`.
pub fn minSize(scale: f32) struct { w: i32, h: i32 } {
    return .{ .w = px(420, scale), .h = px(320, scale) };
}

/// A window of `size` centred inside `visible` and clamped to it, so a tall
/// default never opens with its bottom off a short display (Mac's
/// `openingFrame`).
pub fn openingFrame(w: i32, h: i32, visible: Rect) Rect {
    const cw = @min(w, visible.w);
    const ch = @min(h, visible.h);
    return .{
        .x = visible.x + @divTrunc(visible.w - cw, 2),
        .y = visible.y + @divTrunc(visible.h - ch, 2),
        .w = cw,
        .h = ch,
    };
}

/// The window's chrome, for a client area of `client_w` x `client_h`.
/// `label_w` holds the measured width of each tab's label.
pub const Frame = struct {
    tabs: [Tab.count]Rect,
    /// The accent bar under the selected tab.
    underline: Rect,
    /// The hairline the whole tab run sits on.
    rule: Rect,
    /// Where the notes scroll. Excludes the trailing scrollbar gutter.
    viewport: Rect,
    /// The scrollbar gutter, full viewport height at the trailing edge.
    scrollbar: Rect,
    /// Width available to wrapped text inside the viewport.
    text_w: i32,
};

pub fn frameFor(
    scale: f32,
    client_w: i32,
    client_h: i32,
    label_w: [Tab.count]i32,
    selected: Tab,
) Frame {
    const m = metrics(scale);

    var tabs: [Tab.count]Rect = undefined;
    var x = m.margin;
    for (0..Tab.count) |i| {
        const w = label_w[i] + 2 * m.tab_pad_x;
        tabs[i] = .{ .x = x, .y = 0, .w = w, .h = m.tab_h };
        x += w + m.tab_gap;
    }

    const sel = tabs[@intFromEnum(selected)];
    const underline: Rect = .{
        .x = sel.x + m.tab_pad_x,
        .y = m.tab_h - m.underline_h,
        .w = @max(0, sel.w - 2 * m.tab_pad_x),
        .h = m.underline_h,
    };
    const rule: Rect = .{
        .x = 0,
        .y = m.tab_h - m.rule_h,
        .w = client_w,
        .h = m.rule_h,
    };

    const body_y = m.tab_h;
    const body_h = @max(0, client_h - body_y);
    const viewport: Rect = .{
        .x = 0,
        .y = body_y,
        .w = @max(0, client_w - m.scrollbar_w),
        .h = body_h,
    };
    const scrollbar: Rect = .{
        .x = viewport.x + viewport.w,
        .y = body_y,
        .w = m.scrollbar_w,
        .h = body_h,
    };
    return .{
        .tabs = tabs,
        .underline = underline,
        .rule = rule,
        .viewport = viewport,
        .scrollbar = scrollbar,
        .text_w = @max(0, viewport.w - 2 * m.margin),
    };
}

/// Which tab a click at (`x`, `y`) landed on, if any.
pub fn hitTab(frame: Frame, x: i32, y: i32) ?Tab {
    for (frame.tabs, 0..) |r, i| {
        if (r.contains(x, y)) return @enumFromInt(@as(u8, @intCast(i)));
    }
    return null;
}

/// Clamp a scroll offset to the range this content actually has. Content
/// shorter than the viewport pins to the top rather than scrolling into
/// empty space.
pub fn clampScroll(offset: i32, content_h: i32, viewport_h: i32) i32 {
    const max_scroll = @max(0, content_h - viewport_h);
    return std.math.clamp(offset, 0, max_scroll);
}

/// The scrollbar thumb for `content_h` of content scrolled to `offset`, or
/// null when everything fits and no thumb should be drawn. `min_thumb` keeps
/// a very long document's thumb grabbable.
pub fn thumb(
    gutter: Rect,
    content_h: i32,
    offset: i32,
    min_thumb: i32,
) ?Rect {
    if (content_h <= gutter.h or gutter.h <= 0) return null;
    const ratio = @as(f64, @floatFromInt(gutter.h)) / @as(f64, @floatFromInt(content_h));
    const h = @max(min_thumb, @as(i32, @intFromFloat(@round(
        @as(f64, @floatFromInt(gutter.h)) * ratio,
    ))));
    const travel = gutter.h - h;
    const max_scroll = @max(1, content_h - gutter.h);
    const y = @divTrunc(travel * std.math.clamp(offset, 0, max_scroll), max_scroll);
    return .{ .x = gutter.x, .y = gutter.y + y, .w = gutter.w, .h = h };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// The scales the design system requires every geometry module to assert.
const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };

test "metrics: every step is positive and ordered at every scale" {
    for (scales) |s| {
        const m = metrics(s);
        try testing.expect(m.margin > 0);
        try testing.expect(m.tab_h > 0);
        try testing.expect(m.underline_h >= 1);
        try testing.expect(m.rule_h >= 1);
        // The spacing scale's order must survive rounding: a release break is
        // always wider than a section break, which is always wider than the
        // gap between two bullets.
        try testing.expect(m.release_gap > m.section_gap);
        try testing.expect(m.section_gap > m.item_gap);
        try testing.expect(m.item_gap > m.item_line_gap);
        // The tab run has to hold a line of body text with room around it.
        try testing.expect(m.tab_h > type_ramp.lineBox(type_ramp.body(s), s));
    }
}

test "metrics: values scale monotonically with DPI" {
    var prev = metrics(scales[0]);
    for (scales[1..]) |s| {
        const m = metrics(s);
        try testing.expect(m.margin >= prev.margin);
        try testing.expect(m.tab_h >= prev.tab_h);
        try testing.expect(m.release_gap >= prev.release_gap);
        try testing.expect(m.wheel_step >= prev.wheel_step);
        prev = m;
    }
}

test "metrics: 100% resolves the design system's scale exactly" {
    const m = metrics(1.0);
    try testing.expectEqual(@as(i32, 16), m.margin); // xl
    try testing.expectEqual(@as(i32, 12), m.tab_pad_x); // lg
    try testing.expectEqual(@as(i32, 4), m.tab_gap); // sm
    try testing.expectEqual(@as(i32, 2), m.underline_h); // xs
    try testing.expectEqual(@as(i32, 24), m.release_gap); // xxl
    try testing.expectEqual(@as(i32, 12), m.section_gap); // lg
    try testing.expectEqual(@as(i32, 8), m.item_gap); // md
}

test "metricsFor: compact is tighter than spacious, and still ordered" {
    for (scales) |s| {
        const spacious = metricsFor(s, .spacious);
        const compact = metricsFor(s, .compact);

        // Every step the density touches gives ground, and none of them
        // collapse to nothing — an accessory with zero gap between releases is
        // a wall of text, not a denser list.
        try testing.expect(compact.margin < spacious.margin);
        try testing.expect(compact.release_gap < spacious.release_gap);
        try testing.expect(compact.section_gap < spacious.section_gap);
        try testing.expect(compact.item_gap < spacious.item_gap);
        try testing.expect(compact.item_gap > 0);
        try testing.expect(compact.margin > 0);

        // The ORDER is what the eye reads, and it survives the squeeze.
        try testing.expect(compact.release_gap > compact.section_gap);
        try testing.expect(compact.section_gap > compact.item_gap);
        try testing.expect(compact.item_gap > compact.item_line_gap);

        // The type ramp is NOT a density knob: the accessory is the same
        // renderer at the same sizes, which is why it reads as the window's
        // notes rather than a summary of them.
        try testing.expectEqual(spacious.bullet_indent, compact.bullet_indent);
        try testing.expectEqual(spacious.item_line_gap, compact.item_line_gap);
    }
}

test "metricsFor: the bare metrics() is the window's spacing" {
    for (scales) |s| {
        const bare = metrics(s);
        const spacious = metricsFor(s, .spacious);
        try testing.expectEqual(spacious.margin, bare.margin);
        try testing.expectEqual(spacious.release_gap, bare.release_gap);
        try testing.expectEqual(spacious.section_gap, bare.section_gap);
        try testing.expectEqual(spacious.item_gap, bare.item_gap);
    }
}

test "metricsFor: compact resolves the design system's scale exactly at 100%" {
    const m = metricsFor(1.0, .compact);
    try testing.expectEqual(@as(i32, 12), m.margin); // lg
    try testing.expectEqual(@as(i32, 16), m.release_gap); // xl
    try testing.expectEqual(@as(i32, 8), m.section_gap); // md
    try testing.expectEqual(@as(i32, 4), m.item_gap); // sm
}

test "accessoryHeight: a fixed band that grows with DPI and holds real notes" {
    var prev: i32 = 0;
    for (scales) |s| {
        const h = accessoryHeight(s);
        // Tall enough for a version banner plus a couple of bullets, or the
        // accessory is a peephole rather than an answer.
        try testing.expect(h > 4 * type_ramp.lineBox(type_ramp.body(s), s));
        try testing.expect(h >= prev);
        prev = h;
    }
}

test "frameFor: tabs run leading-aligned and the underline tracks selection" {
    for (scales) |s| {
        const m = metrics(s);
        const label_w: [Tab.count]i32 = .{ 40, 38 };
        const f = frameFor(s, 900, 800, label_w, .client);

        try testing.expectEqual(m.margin, f.tabs[0].x);
        try testing.expectEqual(f.tabs[0].x + f.tabs[0].w + m.tab_gap, f.tabs[1].x);
        try testing.expectEqual(label_w[0] + 2 * m.tab_pad_x, f.tabs[0].w);

        // The underline hugs the selected label, not the whole hit target.
        try testing.expectEqual(f.tabs[0].x + m.tab_pad_x, f.underline.x);
        try testing.expectEqual(label_w[0], f.underline.w);
        try testing.expectEqual(m.tab_h - m.underline_h, f.underline.y);

        const g = frameFor(s, 900, 800, label_w, .agent);
        try testing.expectEqual(f.tabs[1].x + m.tab_pad_x, g.underline.x);
    }
}

test "frameFor: the viewport fills below the run and leaves the gutter" {
    for (scales) |s| {
        const m = metrics(s);
        const f = frameFor(s, 900, 800, .{ 40, 38 }, .client);
        try testing.expectEqual(m.tab_h, f.viewport.y);
        try testing.expectEqual(800 - m.tab_h, f.viewport.h);
        try testing.expectEqual(900 - m.scrollbar_w, f.viewport.w);
        try testing.expectEqual(f.viewport.x + f.viewport.w, f.scrollbar.x);
        try testing.expectEqual(f.viewport.h, f.scrollbar.h);
        try testing.expectEqual(f.viewport.w - 2 * m.margin, f.text_w);
    }
}

test "frameFor: a window squeezed below its floor never yields a negative box" {
    // The floor is enforced by WM_GETMINMAXINFO, but a layout that can go
    // negative is a crash waiting for the one path that bypasses it.
    for (scales) |s| {
        const f = frameFor(s, 10, 10, .{ 40, 38 }, .agent);
        try testing.expect(f.viewport.w >= 0);
        try testing.expect(f.viewport.h >= 0);
        try testing.expect(f.text_w >= 0);
    }
}

test "hitTab: picks the tab under the point, nothing below the run" {
    const s: f32 = 1.5;
    const m = metrics(s);
    const f = frameFor(s, 900, 800, .{ 40, 38 }, .client);
    try testing.expectEqual(Tab.client, hitTab(f, f.tabs[0].x + 2, 2).?);
    try testing.expectEqual(Tab.agent, hitTab(f, f.tabs[1].x + 2, 2).?);
    // The gap between the two tabs belongs to neither.
    try testing.expect(hitTab(f, f.tabs[0].x + f.tabs[0].w + 1, 2) == null);
    // Below the run is the notes, not a tab.
    try testing.expect(hitTab(f, f.tabs[0].x + 2, m.tab_h + 1) == null);
    try testing.expect(hitTab(f, 1, 2) == null); // left of the leading margin
}

test "clampScroll: pins short content to the top and long content to its end" {
    try testing.expectEqual(@as(i32, 0), clampScroll(50, 200, 400));
    try testing.expectEqual(@as(i32, 0), clampScroll(-30, 900, 400));
    try testing.expectEqual(@as(i32, 500), clampScroll(9999, 900, 400));
    try testing.expectEqual(@as(i32, 120), clampScroll(120, 900, 400));
}

test "thumb: absent when everything fits, and travels the full gutter" {
    const gutter: Rect = .{ .x = 880, .y = 40, .w = 12, .h = 400 };
    try testing.expect(thumb(gutter, 300, 0, 20) == null);

    const top = thumb(gutter, 1200, 0, 20).?;
    try testing.expectEqual(gutter.y, top.y);
    try testing.expect(top.h < gutter.h);

    const bottom = thumb(gutter, 1200, 800, 20).?;
    try testing.expectEqual(gutter.y + gutter.h, bottom.y + bottom.h);

    // A very long document still leaves something to grab.
    const tiny = thumb(gutter, 1_000_000, 0, 20).?;
    try testing.expectEqual(@as(i32, 20), tiny.h);
}

test "openingFrame: centres, and clamps to a short display" {
    const visible: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const f = openingFrame(700, 740, visible);
    try testing.expectEqual(@as(i32, 700), f.w);
    try testing.expectEqual(@as(i32, (1920 - 700) / 2), f.x);

    const short: Rect = .{ .x = 100, .y = 50, .w = 1024, .h = 600 };
    const g = openingFrame(700, 740, short);
    try testing.expectEqual(@as(i32, 600), g.h);
    try testing.expectEqual(@as(i32, 50), g.y);
}

test "defaultSize sits above the floor at every scale" {
    for (scales) |s| {
        const d = defaultSize(s);
        const min = minSize(s);
        try testing.expect(d.w > min.w);
        try testing.expect(d.h > min.h);
    }
}
