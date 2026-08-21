//! One derivation site for every flat color the win32 PANELS paint (T308).
//!
//! `chrome_theme.zig` did this for the window chrome — the caption band, the
//! tab strip — in T304/T305. The panels were left behind: the Activity Monitor
//! held about thirty `RGB(...)` constants, the machine chooser four more plus a
//! `DIALOG_BG`, and the hero carousel two mid-greys. Every one of them assumed
//! a dark surface, so a panel opened dark on a light system theme with fixed
//! light text on it — the panel-scale version of exactly the defect T203 was
//! filed against.
//!
//! The inputs are the same two the chrome already resolves from: the surface
//! the panel sits on (`chrome_theme.chromeBase` of `window-theme`, the terminal
//! background and the OS apps theme) and the accent the user picked. Everything
//! else is DERIVED — washes whose direction follows the surface's own luminance,
//! and contrast floors enforced by search rather than by hoping.
//!
//! Pure: no `win32.zig` import, so the tests run in every app-runtime lane. The
//! COLORREF conversion and the brush caching live with the callers.
//!
//! Two moves, not one. `color_math.wash` composites toward the surface's
//! CONTRASTING side, which is what a raised surface (a card, a header band, a
//! hover) does. A well — a text field, a chart plot area — has to go the other
//! way, toward the surface's own side, or it stops reading as inset. That is
//! `recede`, and it is the only reason this module is not four calls into
//! `chrome_theme`.
//!
//! Floors, from `docs/design/win32-design-system.md`:
//!   - text                      >= 4.5:1  (WCAG 1.4.3)
//!   - status marks, boundaries  >= 3.0:1  (WCAG 1.4.11)

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");

pub const Rgb = color_math.Rgb;

// --- the wash scale -------------------------------------------------------
//
// Every number here is checked against what the dark panel painted before it,
// so this is a light-theme FIX rather than a redesign of the dark look: on the
// `#202020` surface the panels used to hardcode, each wash lands within a few
// levels of the literal it replaces (asserted in "the dark panel does not move"
// below).

/// A text field or a combo box: a well, one notch INTO the surface. Was
/// `RGB(30,30,30)` on `RGB(32,32,32)`.
pub const field_recede: f64 = 0.0625;

/// A chart plot area: a deeper well, so the gauge reads as a recessed trough
/// rather than as a panel-colored rectangle. Was `RGB(26,26,26)`.
pub const well_recede: f64 = 0.19;

/// A table header band — the shallowest raised step. Was `RGB(40,40,40)`.
pub const header_wash: f32 = 0.04;

/// A card at rest, and a hovered table row: one step off the panel. Was
/// `RGB(44,44,44)` / `RGB(45,45,45)` — two literals for one step.
pub const surface_wash: f32 = 0.06;

/// A hovered card, and the hairline rules that divide the panel. Was
/// `RGB(56,56,56)` / `RGB(60,60,60)`.
pub const raised_wash: f32 = 0.12;

/// A chart grid line, washed off the WELL it is drawn on rather than off the
/// panel — it is a rule on the chart surface, not on the panel. Was
/// `RGB(52,52,52)`.
pub const grid_wash: f32 = 0.11;

/// A resting boundary that carries meaning: a card outline, a scroll thumb, a
/// carousel tile border. Floored to 3:1 afterwards, so the wash sets the LOOK
/// and the floor guarantees it is seen. Was `RGB(110,110,110)` / `RGB(130,130,130)`
/// / `RGB(96,96,96)` / `RGB(90,90,90)` — four numbers for one role.
pub const boundary_wash: f32 = 0.35;

/// How far the DRAGGED state of a boundary steps past its resting one. A step
/// beyond the floored color, deliberately, and not a second larger wash: the
/// floor search returns the SMALLEST change that clears 3:1, so on a mid-tone
/// surface two washes on the same side of it land on the identical color and
/// the drag state stops existing. Was `RGB(130,130,130)` against `RGB(90,90,90)`.
pub const boundary_active_step: f64 = 0.30;

/// De-emphasized-but-not-secondary text: a column heading, a field label. Sits
/// between `chrome_theme.text_wash` (0.90) and `text_secondary_wash` (0.55),
/// which is what `RGB(200,200,200)` was between 230 and 150.
pub const label_wash: f32 = 0.75;

/// How far a selection fill is dragged toward the accent. Enough to read as
/// "this row is chosen" at a glance; not so far that the panel's own surface
/// stops showing through. Was `RGB(38,79,120)`, a fourth invented blue.
pub const select_alpha: f64 = 0.45;

/// A gauge's filled area, under its stroke. Was `RGB(38,66,94)` / `RGB(40,78,52)`,
/// both hand-blended against the dark panel.
pub const gauge_fill_alpha: f64 = 0.28;

/// A warning banner's fill: Mac's `.orange.opacity(0.12)` over the panel
/// (RemoteActivityMonitorView.swift:1077). GDI has no alpha for flat fills, so
/// the blend is resolved here instead of being precomputed as `RGB(56,47,35)`.
pub const banner_alpha: f64 = 0.12;

// --- the semantic hues ----------------------------------------------------
//
// These are NOT washes of the surface: a status dot is green because green
// means good, and a CPU trace is blue because Mac's is (`tint: .blue`). They
// stay literal, and are then floored against whatever surface they land on —
// which is the half that was missing, because a hue picked to read on
// `#202020` says nothing about how it reads on `#F3F3F3`.

/// Mac's gauge tints (RemoteActivityMonitorView.swift:868, :878).
pub const cpu_base: Rgb = .{ .r = 80, .g = 160, .b = 235 };
pub const mem_base: Rgb = .{ .r = 90, .g = 190, .b = 120 };

/// The "list truncated" / action-error amber.
pub const warn_base: Rgb = .{ .r = 220, .g = 165, .b = 90 };

/// Status dots: the three states Mac paints, plus the neutral one for "the
/// directory says offline and we have not dialed it" (which is the secondary
/// text ramp, not a hue — see `Panel.secondary`).
pub const good_base: Rgb = .{ .r = 90, .g = 200, .b = 120 };
pub const pending_base: Rgb = .{ .r = 225, .g = 180, .b = 80 };
pub const bad_base: Rgb = .{ .r = 230, .g = 100, .b = 100 };

// --- primitives -----------------------------------------------------------

/// Composite toward the surface's OWN side — white over a light surface, black
/// over a dark one. The mirror of `color_math.wash`, and what makes a well read
/// as inset instead of raised.
///
/// A surface at either extreme cannot recede (mixing black into black is
/// black), and a well nobody can see is worse than a well drawn the other way:
/// so when the move cannot change the color at all, it washes instead. Without
/// that fallback a `#000000` terminal background — which `window-theme = auto`
/// hands straight to the panel — loses every field and every chart trough.
pub fn recede(surface: Rgb, a: f64) Rgb {
    const toward: Rgb = if (color_math.isLight(surface))
        .{ .r = 255, .g = 255, .b = 255 }
    else
        .{ .r = 0, .g = 0, .b = 0 };
    const out = color_math.mix(surface, toward, a);
    if (!out.eql(surface)) return out;
    return color_math.wash(surface, @floatCast(a));
}

/// A resting boundary on `surface`, floored to WCAG 1.4.11's 3:1 — a card
/// outline, a scroll thumb, a carousel tile border.
pub fn boundaryOn(surface: Rgb) Rgb {
    return color_math.contrastAdjustedTo(
        color_math.wash(surface, boundary_wash),
        surface,
        chrome_theme.ui_contrast_target,
    );
}

/// The same boundary while grabbed or dragged: a further step off the surface,
/// so the state change is a change of VALUE and not of color alone.
pub fn boundaryActiveOn(surface: Rgb) Rgb {
    const rest = boundaryOn(surface);
    const out = color_math.mix(rest, color_math.contrastForeground(surface), boundary_active_step);
    if (!out.eql(rest)) return out;
    // `rest` is already the extreme this surface contrasts with, so there is no
    // further away to go: the drag state steps back TOWARD the surface instead
    // and is re-floored, which keeps it both visible and distinguishable.
    return color_math.contrastAdjustedTo(
        color_math.mix(rest, surface, boundary_active_step),
        surface,
        chrome_theme.ui_contrast_target,
    );
}

/// A semantic hue as a non-text mark on `surface` (a status dot, a gauge
/// stroke): its own color, floored to 3:1.
pub fn semanticOn(hue: Rgb, surface: Rgb) Rgb {
    return color_math.contrastAdjustedTo(hue, surface, chrome_theme.ui_contrast_target);
}

/// A semantic hue as TEXT on `surface` (the warning line above a banner):
/// floored to 4.5:1 instead, because it is read rather than seen.
pub fn textSemanticOn(hue: Rgb, surface: Rgb) Rgb {
    return color_math.contrastAdjusted(hue, surface);
}

/// A tinted fill: `hue` composited over `surface` at `a`, resolved opaque
/// because GDI has no alpha for flat fills.
pub fn fillOn(surface: Rgb, hue: Rgb, a: f64) Rgb {
    return color_math.mix(surface, hue, a);
}

// --- the palette ----------------------------------------------------------

/// Every flat color a panel paints, resolved together.
///
/// Together on purpose, for the reason `chrome_theme.Palette` is: these colors
/// are only correct RELATIVE to each other. `text` is legible on `bg`,
/// `text_on_select` on `select`, `card_border` against `card` — a painter that
/// took half of them from here and half from a literal is back to the defect
/// this module exists to remove.
pub const Panel = struct {
    /// The panel's own surface: `chrome_theme.chromeBase`, undiluted. A panel
    /// is a top-level window that abuts nothing, so unlike the chrome band it
    /// has no neighbour to separate itself from.
    bg: Rgb,
    /// An inset field: an edit box, a combo box.
    field: Rgb,
    /// A chart plot area — a deeper well than a field.
    well: Rgb,
    /// A table header band.
    header: Rgb,
    /// A card at rest, and a hovered table row.
    card: Rgb,
    /// A hovered card.
    card_hover: Rgb,
    /// The hairline rules that divide the panel.
    divider: Rgb,
    /// A chart grid line, on `well`.
    grid: Rgb,
    /// A resting boundary on `bg` — a scroll thumb, a carousel tile border.
    boundary: Rgb,
    /// The same, grabbed.
    boundary_active: Rgb,
    /// A card's outline, floored against the CARD rather than the panel.
    card_border: Rgb,
    /// Primary panel text.
    text: Rgb,
    /// A column heading or a field label: de-emphasized, still not secondary.
    label: Rgb,
    /// Secondary text: a subline, a detail, a unit.
    secondary: Rgb,
    /// The user's accent as drawn on the panel, floored to 3:1.
    accent: Rgb,
    /// A foreground that reads on top of `accent`.
    on_accent: Rgb,
    /// A selection fill: the panel dragged toward the accent.
    select: Rgb,
    /// Primary text on `select` — NOT `text`, which is measured against `bg`.
    text_on_select: Rgb,
    /// Secondary text on `select`. The one that broke first: the old
    /// `RGB(150,150,150)` read 4.7:1 on the resting card and 2.9:1 on the
    /// selected one, which is why there was a hand-picked `RGB(190,205,225)`
    /// beside it.
    secondary_on_select: Rgb,
    /// A warning banner's fill, and the amber text that sits on it.
    banner: Rgb,
    warn: Rgb,
    /// Gauge strokes and their filled areas.
    cpu: Rgb,
    cpu_fill: Rgb,
    mem: Rgb,
    mem_fill: Rgb,
    /// Status dots. `neutral` is the secondary text ramp, deliberately: "we do
    /// not know" is an absence of state, not a fourth state with a hue.
    good: Rgb,
    pending: Rgb,
    bad: Rgb,
    neutral: Rgb,
};

pub fn resolve(base: Rgb, accent: Rgb) Panel {
    const well = recede(base, well_recede);
    const card = color_math.wash(base, surface_wash);
    const acc = chrome_theme.accentOn(base, accent);
    const select = fillOn(base, acc, select_alpha);
    const warn = textSemanticOn(warn_base, base);
    const cpu = semanticOn(cpu_base, base);
    const mem = semanticOn(mem_base, base);
    return .{
        .bg = base,
        .field = recede(base, field_recede),
        .well = well,
        .header = color_math.wash(base, header_wash),
        .card = card,
        .card_hover = color_math.wash(base, raised_wash),
        .divider = color_math.wash(base, raised_wash),
        .grid = color_math.wash(well, grid_wash),
        .boundary = boundaryOn(base),
        .boundary_active = boundaryActiveOn(base),
        .card_border = boundaryOn(card),
        .text = chrome_theme.textOn(base),
        .label = color_math.contrastAdjusted(color_math.wash(base, label_wash), base),
        .secondary = chrome_theme.textSecondaryOn(base),
        .accent = acc,
        .on_accent = color_math.contrastForeground(acc),
        .select = select,
        .text_on_select = chrome_theme.textOn(select),
        .secondary_on_select = chrome_theme.textSecondaryOn(select),
        .banner = fillOn(base, warn, banner_alpha),
        .warn = warn,
        .cpu = cpu,
        .cpu_fill = fillOn(base, cpu, gauge_fill_alpha),
        .mem = mem,
        .mem_fill = fillOn(base, mem, gauge_fill_alpha),
        .good = semanticOn(good_base, base),
        .pending = semanticOn(pending_base, base),
        .bad = semanticOn(bad_base, base),
        .neutral = chrome_theme.textSecondaryOn(base),
    };
}

// --- tests ---

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

fn near(a: Rgb, b: Rgb, tol: u8) bool {
    const d = struct {
        fn f(x: u8, y: u8) u8 {
            return if (x > y) x - y else y - x;
        }
    }.f;
    return d(a.r, b.r) <= tol and d(a.g, b.g) <= tol and d(a.b, b.b) <= tol;
}

test "recede: a well goes INTO the surface, both ways" {
    const dark: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 };
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };

    // Dark panel: the field is darker than the panel. Light panel: lighter.
    // The direction FLIPS, which is the whole difference from `wash`.
    try testing.expect(recede(dark, field_recede).r < dark.r);
    try testing.expect(recede(light, field_recede).r > light.r);
    try testing.expect(color_math.wash(dark, field_recede).r > dark.r);

    // A deeper well is further in, not further out.
    try testing.expect(recede(dark, well_recede).r < recede(dark, field_recede).r);
    try testing.expect(recede(light, well_recede).r > recede(light, field_recede).r);
}

test "recede: the extremes fall back rather than vanish" {
    // `window-theme = auto` hands the panel the terminal background, and a
    // pure-black terminal is a real configuration. Mixing black into black
    // cannot move, so the well would be invisible — every field and every
    // chart trough gone. It washes instead.
    for ([_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 0xFE, .g = 0xFE, .b = 0xFE },
    }) |bg| {
        for ([_]f64{ field_recede, well_recede }) |a| {
            try testing.expect(!recede(bg, a).eql(bg));
        }
    }
}

test "the dark panel does not visibly move (T308 is a light-theme fix)" {
    // Every literal the three panels used to hardcode, against what the
    // derivation now answers on the surface they assumed. Not equality — the
    // point is that a user on a dark theme sees the same panel, so the tolerance
    // is "no visible step", not "the same number".
    const p = resolve(.{ .r = 32, .g = 32, .b = 32 }, chrome_theme.default_accent);

    try testing.expect(near(p.field, .{ .r = 30, .g = 30, .b = 30 }, 2));
    try testing.expect(near(p.well, .{ .r = 26, .g = 26, .b = 26 }, 2));
    try testing.expect(near(p.header, .{ .r = 40, .g = 40, .b = 40 }, 3));
    try testing.expect(near(p.card, .{ .r = 44, .g = 44, .b = 44 }, 3));
    try testing.expect(near(p.card_hover, .{ .r = 56, .g = 56, .b = 56 }, 4));
    try testing.expect(near(p.divider, .{ .r = 60, .g = 60, .b = 60 }, 4));
    try testing.expect(near(p.grid, .{ .r = 52, .g = 52, .b = 52 }, 3));
    try testing.expect(near(p.text, .{ .r = 230, .g = 230, .b = 230 }, 5));
    try testing.expect(near(p.label, .{ .r = 200, .g = 200, .b = 200 }, 5));
    try testing.expect(near(p.secondary, .{ .r = 150, .g = 150, .b = 150 }, 6));
    try testing.expect(near(p.boundary, .{ .r = 110, .g = 110, .b = 110 }, 6));
    // The carousel's two greys were the same role at two values; both land on
    // `boundary` now, so one of them moves by more than the other.
    try testing.expect(near(p.boundary, .{ .r = 96, .g = 96, .b = 96 }, 16));
}

test "resolve: every floor holds across the whole surface x accent space" {
    // The sweep, for the same reason `chrome_theme` has one: the dark panel is
    // the ONE surface these thirty literals were ever checked against, and the
    // defect is that nobody looked at the others.
    var bgs: std.ArrayList(Rgb) = .empty;
    defer bgs.deinit(testing.allocator);
    var v: u16 = 0;
    while (v <= 255) : (v += 8) {
        const c: u8 = @intCast(v);
        try bgs.append(testing.allocator, .{ .r = c, .g = c, .b = c });
        try bgs.append(testing.allocator, .{ .r = c, .g = @intCast(255 - v), .b = 0x40 });
        try bgs.append(testing.allocator, .{ .r = 0x20, .g = c, .b = @intCast(255 - v) });
    }

    const accents = [_]Rgb{
        .{ .r = 0x68, .g = 0x00, .b = 0x81 }, // this box's real accent
        chrome_theme.default_accent,
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0xFF, .g = 0xF0, .b = 0x00 },
    };

    for (bgs.items) |bg| {
        for (accents) |a| {
            const p = resolve(bg, a);

            // Text floors, on every surface text is actually drawn on.
            try testing.expect(ratio(p.text, p.bg) >= 4.4);
            try testing.expect(ratio(p.label, p.bg) >= 4.4);
            try testing.expect(ratio(p.secondary, p.bg) >= 4.4);
            try testing.expect(ratio(p.text_on_select, p.select) >= 4.4);
            try testing.expect(ratio(p.secondary_on_select, p.select) >= 4.4);
            try testing.expect(ratio(p.warn, p.bg) >= 4.4);
            try testing.expect(ratio(p.on_accent, p.accent) >= 4.4);

            // Non-text floors: marks and boundaries.
            for ([_]Rgb{ p.accent, p.boundary, p.boundary_active, p.cpu, p.mem, p.good, p.pending, p.bad }) |c| {
                try testing.expect(ratio(c, p.bg) >= chrome_theme.ui_contrast_target);
            }
            try testing.expect(ratio(p.card_border, p.card) >= chrome_theme.ui_contrast_target);

            // Every surface is distinguishable from the one it sits on — the
            // half a contrast floor does not cover, and the half that actually
            // broke: on a light panel a per-channel add clamped the card, its
            // hover and the panel onto the same near-white.
            for ([_]Rgb{ p.field, p.well, p.header, p.card, p.card_hover, p.divider, p.select }) |c| {
                try testing.expect(!c.eql(p.bg));
            }
            try testing.expect(!p.card_hover.eql(p.card));
            try testing.expect(!p.grid.eql(p.well));
            try testing.expect(!p.boundary_active.eql(p.boundary));
        }
    }
}

test "resolve: the panel follows its surface's direction" {
    const light = resolve(chrome_theme.surface_light, chrome_theme.default_accent);
    const dark = resolve(chrome_theme.surface_dark, chrome_theme.default_accent);

    // A light panel gets dark text and a light card; a dark one the reverse.
    // This is the assertion the whole task is about: nothing here is allowed to
    // be "the dark answer" on both.
    try testing.expect(color_math.luminance(light.text) < 0.5);
    try testing.expect(color_math.luminance(dark.text) > 0.5);
    try testing.expect(color_math.luminance(light.card) < color_math.luminance(light.bg));
    try testing.expect(color_math.luminance(dark.card) > color_math.luminance(dark.bg));
    try testing.expect(color_math.luminance(light.field) > color_math.luminance(light.bg));
    try testing.expect(color_math.luminance(dark.field) < color_math.luminance(dark.bg));
}

test "the semantic hues stay their own hue on both panels" {
    // A status dot is green because green means good. Flooring it must not turn
    // it into the text ramp — on a light panel the old `RGB(90,200,120)` was
    // 1.9:1 and effectively gone, so it HAS to move, but it moves within its
    // hue.
    for ([_]Rgb{ chrome_theme.surface_light, chrome_theme.surface_dark }) |bg| {
        const p = resolve(bg, chrome_theme.default_accent);
        try testing.expect(p.good.g > p.good.r and p.good.g > p.good.b);
        try testing.expect(p.bad.r > p.bad.g and p.bad.r > p.bad.b);
        try testing.expect(p.cpu.b > p.cpu.r);
        try testing.expect(p.pending.r > p.pending.b and p.pending.g > p.pending.b);
        try testing.expect(p.warn.r > p.warn.b);
    }

    // And the gauge fill stays UNDER its stroke: a fill that reached the stroke
    // would erase the trace it is supposed to sit behind.
    const p = resolve(chrome_theme.surface_dark, chrome_theme.default_accent);
    try testing.expect(ratio(p.cpu, p.cpu_fill) > 1.5);
    try testing.expect(ratio(p.mem, p.mem_fill) > 1.5);
}
