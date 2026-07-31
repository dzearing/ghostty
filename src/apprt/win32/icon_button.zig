//! Pure geometry and state model for every icon button in the win32 chrome
//! (T204). No OS imports, so these unit tests run in every app-runtime lane
//! (the `split_geometry.zig` / `tab_strip_layout.zig` pattern).
//!
//! Why this module exists. The chrome grew four icon buttons over four
//! separate tasks, and each one open-coded its own treatment:
//!
//!   * "+"  (new tab)  — rounded hover fill, glyph drawn `DT_LEFT`
//!   * "≡"  (menu)     — rounded hover fill, glyph drawn `DT_CENTER`
//!   * "×"  (close)    — NO fill; hover only recolored the glyph red, `DT_LEFT`
//!   * chevron (banner collapse) — no hover, no hit state, no fill at all
//!
//! Four controls, four answers to the same question, so they could not agree
//! and did not. The user's report, 2026-07-30, naming all three symptoms:
//!
//! > "icon buttons should have a consistent design with consistent hover and
//! >  centered icons" ... "why doesn't the chevron in the banner have a
//! >  similar hover? why doesn't the x to close a tab have a similar hover?"
//!
//! And on the "+" specifically — its fill was a tab-height slab while the
//! glyph sat against the slab's left edge, so a hovered "+" read as a second
//! tab rather than a button.
//!
//! So the button model lives here, once: the shared square target, the
//! rounded fill inset inside it, the per-state shade, and the rule that the
//! glyph is centered on BOTH axes of that square. A site that wants an icon
//! button asks this module for its geometry; it does not get to invent one.
//! That is what makes the user's complaint un-reproducible by construction
//! rather than by three sites happening to agree.
//!
//! Measured target: `docs/design/win32-tab-strip.md`.

const std = @import("std");
const testing = std.testing;

/// Negative control for `test/win32/tab-strip.ps1` and
/// `test/win32/pane-banner.ps1` (project standard: an acceptance script has
/// to be SHOWN to fail, or it is not evidence). Flip to `true`, rebuild
/// `-Dapp-runtime=win32`, and re-run those scripts: it restores the pre-T204
/// world where glyphs are leading-aligned and only the "+"/"≡" light a fill,
/// so the centering assertions and the close/chevron hover assertions must
/// fail — and the "+"/"≡" hover assertions must NOT.
///
/// Left in the source rather than behind a build option so the control is one
/// edit away from any future reader, and so the unit tests below pin the
/// shipped (`false`) behavior on every build.
pub const T204_NEUTERED = false;

/// A rectangle in physical pixels, right/bottom exclusive. Mirrors `w32.RECT`
/// field-for-field so Window.zig can copy one into the other; declared here so
/// this module needs no OS import. `tab_strip_layout.zig` re-exports it, so
/// the strip and the banner share one rectangle type rather than two
/// structurally identical ones.
pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: Rect, x: i32) bool {
        return x >= self.left and x < self.right;
    }

    pub fn containsPoint(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and
            y >= self.top and y < self.bottom;
    }
};

/// A rounded rect expressed as the arguments to `CreateRoundRectRgn`, whose
/// right/bottom are inclusive — so they are already +1'd here and every call
/// site passes them straight through. One place to get that off-by-one right.
pub const RoundRegion = struct {
    left: i32,
    top: i32,
    /// Exclusive, already +1'd for `CreateRoundRectRgn`.
    right: i32,
    /// Exclusive, already +1'd.
    bottom: i32,
    /// The `w`/`h` arguments (diameter, not radius).
    ellipse: i32,
};

/// What the button is doing right now. One enum for every site, so "hovered"
/// cannot mean a red glyph in one place and a lit fill in another.
pub const State = enum {
    normal,
    hover,
    /// Mouse is down on the button.
    pressed,
    /// Latched on — the menu button while its popup is open. Windows keeps a
    /// menu button lit for as long as the menu it owns is showing.
    active,
};

/// Every DIP constant an icon button is built from, resolved to physical
/// pixels for one DPI scale.
pub const Metrics = struct {
    /// The square target every icon button shares. Chrome buttons are square;
    /// making this one number is what stops three controls from landing at
    /// three unrelated sizes.
    target: i32,
    /// Inset of the rounded fill inside that target, so two adjacent lit
    /// buttons never touch.
    inset: i32,
    /// Corner radius of the fill. Windows 11 lights a button as a rounded
    /// rect inset in its hit box, not as a full-bleed square — the square is
    /// what made the "+" and "≡" read as one slab.
    corner_r: i32,
    /// Glyph em height. Deliberately INDEPENDENT of the tab title font: the
    /// glyphs used to inherit T78's `window-title-font-family` at ~9pt, which
    /// is why the user said the icons "feel too small". Chrome glyphs are
    /// sized as chrome, not as text the user chose.
    glyph_px: i32,
    /// Pen width for a stroked glyph, never thinner than a pixel.
    stroke_w: i32,

    pub fn init(scale: f32) Metrics {
        return .{
            .target = px(26.0, scale),
            .inset = px(1.0, scale),
            .corner_r = px(4.0, scale),
            .glyph_px = px(16.0, scale),
            .stroke_w = @max(px(1.5, scale), 1),
        };
    }

    fn px(dip: f32, scale: f32) i32 {
        return @intFromFloat(@round(dip * scale));
    }
};

/// The shared square target, centered inside whatever box a site has for the
/// button. Sites keep their own (often wider, more forgiving) HIT box; the
/// paint always happens in this square, which is what puts every glyph and
/// every fill on one frame.
///
/// A box smaller than `target` on either axis clamps rather than overflowing —
/// a cramped strip should shrink its buttons, not paint outside itself.
pub fn targetBox(m: Metrics, box: Rect) Rect {
    const side = @min(m.target, @min(box.width(), box.height()));
    const cx = @divTrunc(box.left + box.right, 2);
    const cy = @divTrunc(box.top + box.bottom, 2);
    const half = @divTrunc(side, 2);
    return .{
        .left = cx - half,
        .top = cy - half,
        .right = cx - half + side,
        .bottom = cy - half + side,
    };
}

/// The rounded fill lit under a button, inset inside its shared target.
pub fn fillRegion(m: Metrics, box: Rect) RoundRegion {
    const t = targetBox(m, box);
    return .{
        .left = t.left + m.inset,
        .top = t.top + m.inset,
        .right = t.right - m.inset + 1,
        .bottom = t.bottom - m.inset + 1,
        .ellipse = m.corner_r * 2,
    };
}

/// Does this state paint a fill at all?
///
/// Under the neuter this answers `false` for everything except the states the
/// pre-T204 "+"/"≡" already lit, which is how the acceptance scripts can show
/// the close button's and the chevron's new hover actually came from here.
pub fn paintsFill(state: State) bool {
    return switch (state) {
        .normal => false,
        .hover, .pressed, .active => true,
    };
}

/// How far to shade the site's own base color for a state, per channel.
///
/// A DELTA rather than a color because the sites have different backgrounds:
/// the strip lights against the tab-bar background, the banner against its
/// card. Signed on `dark` so a light theme darkens on hover instead of
/// washing out — T203 owns the theming pass, but the sign belongs to the
/// button model, not to whoever calls it.
pub fn fillDelta(state: State, dark: bool) i32 {
    const magnitude: i32 = switch (state) {
        .normal => 0,
        .hover, .active => 15,
        // Pressed reads as a firmer version of hover, the way every Windows
        // chrome button does.
        .pressed => 25,
    };
    return if (dark) magnitude else -magnitude;
}

/// Apply `fillDelta` to one 8-bit channel, clamped.
pub fn shadeChannel(base: u8, delta: i32) u8 {
    const v = @as(i32, base) + delta;
    return @intCast(std.math.clamp(v, 0, 255));
}

/// One line of a stroked glyph, in physical pixels.
pub const Stroke = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// The icons the chrome draws. Names follow the Fluent icon they stand in for
/// (ChromeClose, Add, GlobalNavButton) so a later switch to a real icon font
/// is a substitution rather than a redesign.
pub const Glyph = enum {
    /// "×" — close a tab.
    close,
    /// "+" — new tab.
    add,
    /// "≡" — the window menu.
    menu,
    /// Collapse chevron, apex up (the banner is expanded).
    chevron_up,
    /// Expand chevron, apex down (the banner is collapsed).
    chevron_down,
};

/// The maximum strokes any glyph needs, so callers can size a stack buffer.
pub const max_strokes: usize = 3;

/// The line segments for `glyph`, centered in `target`.
///
/// STROKED, not a font character. Two reasons, and they are the same two T172
/// had for drawing the machine-chooser icons by hand:
///
///   1. A symbol font that is missing renders as tofu. Segoe Fluent Icons
///      ships with Windows 11 and MDL2 with Windows 10, but "ships with" is
///      not "is present", and a chrome button that renders as a box is worse
///      than one that is a pixel off.
///   2. Text characters carry a font's metrics, not ours. The old "×" was
///      U+00D7 and the old "+" an ASCII plus, both from the user's TAB TITLE
///      font — so their size tracked a setting that has nothing to do with
///      chrome, which is the "icons still feel too small" half of the report.
///
/// Drawing them means the size is a number in this module and the three
/// glyphs are optically consistent by construction.
///
/// Returns the used prefix of `out`, which must hold `max_strokes` entries.
pub fn glyphStrokes(m: Metrics, target: Rect, glyph: Glyph, out: []Stroke) []const Stroke {
    std.debug.assert(out.len >= max_strokes);
    const cx = @divTrunc(target.left + target.right, 2);
    const cy = @divTrunc(target.top + target.bottom, 2);
    // Half-extent of the drawn mark inside the glyph box. A third of the em
    // gives a 10px mark in a 16px box, which is the proportion Fluent's
    // ChromeClose/Add use inside their own em square.
    const h = @max(@divTrunc(m.glyph_px, 3), 2);

    switch (glyph) {
        .close => {
            out[0] = .{ .x0 = cx - h, .y0 = cy - h, .x1 = cx + h, .y1 = cy + h };
            out[1] = .{ .x0 = cx - h, .y0 = cy + h, .x1 = cx + h, .y1 = cy - h };
            return out[0..2];
        },
        .add => {
            out[0] = .{ .x0 = cx - h, .y0 = cy, .x1 = cx + h, .y1 = cy };
            out[1] = .{ .x0 = cx, .y0 = cy - h, .x1 = cx, .y1 = cy + h };
            return out[0..2];
        },
        .menu => {
            // Three rules, evenly spaced about the center.
            const gap = @max(@divTrunc(m.glyph_px, 4), 2);
            out[0] = .{ .x0 = cx - h, .y0 = cy - gap, .x1 = cx + h, .y1 = cy - gap };
            out[1] = .{ .x0 = cx - h, .y0 = cy, .x1 = cx + h, .y1 = cy };
            out[2] = .{ .x0 = cx - h, .y0 = cy + gap, .x1 = cx + h, .y1 = cy + gap };
            return out[0..3];
        },
        .chevron_up, .chevron_down => {
            // A shallower rise than the arms are wide — a chevron, not a
            // caret. `rise` is half `h` so the two legs read as one angle.
            const rise = @max(@divTrunc(h, 2), 1);
            const apex_up = (glyph == .chevron_up);
            const y_end: i32 = if (apex_up) cy + rise else cy - rise;
            const y_apex: i32 = if (apex_up) cy - rise else cy + rise;
            out[0] = .{ .x0 = cx - h, .y0 = y_end, .x1 = cx, .y1 = y_apex };
            out[1] = .{ .x0 = cx, .y0 = y_apex, .x1 = cx + h, .y1 = y_end };
            return out[0..2];
        },
    }
}

/// Are glyphs centered in their target? Always yes in the shipped build; the
/// neuter answers `false` so the paint sites fall back to the leading
/// alignment the user reported, and the centering assertions fail.
pub fn glyphCentered() bool {
    return !T204_NEUTERED;
}

/// Do the close "×" and the banner chevron light a fill like the "+" and "≡"?
/// Always yes in the shipped build; the neuter answers `false`, restoring the
/// pre-T204 state where those two were the odd ones out.
pub fn universalHover() bool {
    return !T204_NEUTERED;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "targetBox is square and centered in its box" {
    const m = Metrics.init(1.0);
    // The "+"/"≡" box: 36 wide, the full 3..32 band.
    const t = targetBox(m, .{ .left = 100, .top = 3, .right = 136, .bottom = 32 });
    try testing.expectEqual(@as(i32, 26), t.width());
    try testing.expectEqual(@as(i32, 26), t.height());
    // Centered horizontally on the box's own center (118).
    try testing.expectEqual(@as(i32, 105), t.left);
    try testing.expectEqual(@as(i32, 131), t.right);
}

test "every icon button lands on ONE vertical frame" {
    const m = Metrics.init(1.0);
    // The three strip controls, given the same 3..32 band but different
    // widths. This is the user's "misaligned" complaint, as an assertion:
    // whatever their widths, their vertical extents must be identical.
    const band_top: i32 = 3;
    const band_bottom: i32 = 32;
    const plus = targetBox(m, .{ .left = 0, .top = band_top, .right = 36, .bottom = band_bottom });
    const menu = targetBox(m, .{ .left = 900, .top = band_top, .right = 936, .bottom = band_bottom });
    const close = targetBox(m, .{ .left = 300, .top = band_top, .right = 326, .bottom = band_bottom });

    try testing.expectEqual(plus.top, menu.top);
    try testing.expectEqual(plus.top, close.top);
    try testing.expectEqual(plus.bottom, menu.bottom);
    try testing.expectEqual(plus.bottom, close.bottom);
    // ...and identical size, which is the other half of "consistent design".
    try testing.expectEqual(plus.width(), menu.width());
    try testing.expectEqual(plus.width(), close.width());
}

test "the fill is a square inset inside the target, not a tab-shaped slab" {
    const m = Metrics.init(1.0);
    // The pre-T204 "+" fill was the full 36-wide button box inset by 2, i.e.
    // 32x24 — wider than tall, which is exactly why a hovered "+" read as a
    // second tab. The shared fill is square.
    const f = fillRegion(m, .{ .left = 0, .top = 3, .right = 36, .bottom = 32 });
    const w = f.right - 1 - f.left;
    const h = f.bottom - 1 - f.top;
    try testing.expectEqual(w, h);
    try testing.expectEqual(@as(i32, 24), w);
    try testing.expect(w < 32); // narrower than the old slab
}

test "fill region round-trips CreateRoundRectRgn's inclusive edges" {
    const m = Metrics.init(1.0);
    const box = Rect{ .left = 10, .top = 3, .right = 46, .bottom = 32 };
    const t = targetBox(m, box);
    const f = fillRegion(m, box);
    try testing.expectEqual(t.left + m.inset, f.left);
    try testing.expectEqual(t.right - m.inset + 1, f.right);
    try testing.expectEqual(m.corner_r * 2, f.ellipse);
}

test "a box smaller than the target clamps instead of overflowing" {
    const m = Metrics.init(1.0);
    const box = Rect{ .left = 0, .top = 0, .right = 12, .bottom = 12 };
    const t = targetBox(m, box);
    try testing.expectEqual(@as(i32, 12), t.width());
    try testing.expect(t.left >= box.left);
    try testing.expect(t.right <= box.right);
    try testing.expect(t.top >= box.top);
    try testing.expect(t.bottom <= box.bottom);
}

test "targetBox scales with DPI" {
    const m = Metrics.init(2.0);
    try testing.expectEqual(@as(i32, 52), m.target);
    try testing.expectEqual(@as(i32, 32), m.glyph_px);
    const t = targetBox(m, .{ .left = 0, .top = 0, .right = 72, .bottom = 64 });
    try testing.expectEqual(@as(i32, 52), t.width());
}

test "glyph size does not track the tab title font" {
    // The regression this pins: glyph_px is derived from the DPI scale alone.
    // Nothing about a user-chosen title font can reach it, which is what
    // "icons still feel too small" was.
    const a = Metrics.init(1.0);
    const b = Metrics.init(1.0);
    try testing.expectEqual(a.glyph_px, b.glyph_px);
    try testing.expectEqual(@as(i32, 16), a.glyph_px);
}

test "every non-normal state paints a fill" {
    // The whole point of the task: hover is a FILL everywhere, not a fill in
    // two places and a color change in a third.
    try testing.expect(!paintsFill(.normal));
    try testing.expect(paintsFill(.hover));
    try testing.expect(paintsFill(.pressed));
    try testing.expect(paintsFill(.active));
}

test "fillDelta shades toward the foreground on dark, away on light" {
    try testing.expectEqual(@as(i32, 0), fillDelta(.normal, true));
    try testing.expectEqual(@as(i32, 15), fillDelta(.hover, true));
    try testing.expectEqual(@as(i32, -15), fillDelta(.hover, false));
    // Pressed is firmer than hover in both themes.
    try testing.expect(@abs(fillDelta(.pressed, true)) > @abs(fillDelta(.hover, true)));
    try testing.expect(@abs(fillDelta(.pressed, false)) > @abs(fillDelta(.hover, false)));
}

test "hover and active shade identically" {
    // A menu button with its popup open should look hovered, not different.
    try testing.expectEqual(fillDelta(.hover, true), fillDelta(.active, true));
}

test "shadeChannel clamps at both ends" {
    try testing.expectEqual(@as(u8, 65), shadeChannel(50, 15));
    try testing.expectEqual(@as(u8, 255), shadeChannel(250, 15));
    try testing.expectEqual(@as(u8, 0), shadeChannel(5, -15));
}

test "every glyph is centered on its target's center" {
    // The user's "centered icons", as an assertion. Each glyph's own bounding
    // box must be centered on the target it was given — for all five, at
    // several DPI scales, including odd-sized targets where a naive
    // implementation drifts by a pixel.
    var buf: [max_strokes]Stroke = undefined;
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        for ([_]Rect{
            .{ .left = 0, .top = 3, .right = 36, .bottom = 32 },
            .{ .left = 101, .top = 4, .right = 128, .bottom = 33 }, // odd sizes
        }) |box| {
            const t = targetBox(m, box);
            const cx = @divTrunc(t.left + t.right, 2);
            const cy = @divTrunc(t.top + t.bottom, 2);
            for ([_]Glyph{ .close, .add, .menu, .chevron_up, .chevron_down }) |g| {
                const strokes = glyphStrokes(m, t, g, &buf);
                try testing.expect(strokes.len >= 2);
                var min_x: i32 = std.math.maxInt(i32);
                var max_x: i32 = std.math.minInt(i32);
                var min_y: i32 = std.math.maxInt(i32);
                var max_y: i32 = std.math.minInt(i32);
                for (strokes) |s| {
                    min_x = @min(min_x, @min(s.x0, s.x1));
                    max_x = @max(max_x, @max(s.x0, s.x1));
                    min_y = @min(min_y, @min(s.y0, s.y1));
                    max_y = @max(max_y, @max(s.y0, s.y1));
                }
                try testing.expectEqual(cx * 2, min_x + max_x);
                try testing.expectEqual(cy * 2, min_y + max_y);
            }
        }
    }
}

test "every glyph fits inside its target" {
    var buf: [max_strokes]Stroke = undefined;
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        const m = Metrics.init(scale);
        const t = targetBox(m, .{ .left = 0, .top = 3, .right = 36, .bottom = 32 });
        for ([_]Glyph{ .close, .add, .menu, .chevron_up, .chevron_down }) |g| {
            for (glyphStrokes(m, t, g, &buf)) |s| {
                try testing.expect(s.x0 >= t.left and s.x1 >= t.left);
                try testing.expect(s.x0 <= t.right and s.x1 <= t.right);
                try testing.expect(s.y0 >= t.top and s.y1 >= t.top);
                try testing.expect(s.y0 <= t.bottom and s.y1 <= t.bottom);
            }
        }
    }
}

test "close, add and menu share one optical width" {
    // Three controls side by side must not be three different sizes — that
    // was half of "misaligned".
    var buf: [max_strokes]Stroke = undefined;
    const m = Metrics.init(1.0);
    const t = targetBox(m, .{ .left = 0, .top = 3, .right = 36, .bottom = 32 });
    var widths: [3]i32 = undefined;
    for ([_]Glyph{ .close, .add, .menu }, 0..) |g, i| {
        const strokes = glyphStrokes(m, t, g, &buf);
        var min_x: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        for (strokes) |s| {
            min_x = @min(min_x, @min(s.x0, s.x1));
            max_x = @max(max_x, @max(s.x0, s.x1));
        }
        widths[i] = max_x - min_x;
    }
    try testing.expectEqual(widths[0], widths[1]);
    try testing.expectEqual(widths[0], widths[2]);
}

test "the two chevrons mirror each other" {
    var up: [max_strokes]Stroke = undefined;
    var down: [max_strokes]Stroke = undefined;
    const m = Metrics.init(1.0);
    const t = targetBox(m, .{ .left = 0, .top = 0, .right = 26, .bottom = 26 });
    const a = glyphStrokes(m, t, .chevron_up, &up);
    const b = glyphStrokes(m, t, .chevron_down, &down);
    try testing.expectEqual(a.len, b.len);
    const cy = @divTrunc(t.top + t.bottom, 2);
    for (a, b) |sa, sb| {
        try testing.expectEqual(sa.x0, sb.x0);
        try testing.expectEqual(sa.x1, sb.x1);
        try testing.expectEqual(cy * 2, sa.y0 + sb.y0);
        try testing.expectEqual(cy * 2, sa.y1 + sb.y1);
    }
}

test "a stroke is never hairline-invisible at any DPI" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0, 3.0 }) |scale| {
        try testing.expect(Metrics.init(scale).stroke_w >= 1);
    }
}

test "the shipped build centers glyphs and lights every button" {
    // These pin the SHIPPED behavior on every build, so flipping the neuter
    // for a negative-control run cannot be forgotten in place.
    try testing.expect(glyphCentered());
    try testing.expect(universalHover());
    try testing.expect(!T204_NEUTERED);
}
