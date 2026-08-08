//! One resolution site for every flat color the win32 chrome paints (T304,
//! the derivation half of T203).
//!
//! The chrome used to answer these questions three times over, and each
//! answer was invented where it was needed: the tab bar as `background + 20`
//! per channel, `chooser_rows.accent` as the literal `#3D8EF8`, and
//! `ActivityMonitor.COLOR_ACCENT` as a DIFFERENT literal blue. Neither blue is
//! the user's accent, and a per-channel add is not a color system — it clamps
//! toward white on a light background, so the bar, its hover and the active
//! tab converge on the same near-white and the fixed grey text goes
//! illegible.
//!
//! This module answers them once, from two inputs the OS actually has: the
//! color the chrome sits on, and the accent the user picked. Everything else
//! is derived — washes whose DIRECTION follows the background's own luminance
//! (`color_math.wash`), and contrast floors enforced by search rather than by
//! hoping (`color_math.contrastAdjustedTo`).
//!
//! Pure: no `win32.zig` import, so the unit tests run in every app-runtime
//! lane. The live registry read lives in `system_colors.zig`; the surfaces
//! that consume this palette are rewired in T305.
//!
//! Floors, from `docs/design/win32-design-system.md`:
//!   - text                          >= 4.5:1  (WCAG 1.4.3)
//!   - accent, danger, chrome glyphs >= 3.0:1  (WCAG 1.4.11)

const std = @import("std");
const testing = std.testing;
const color_math = @import("color_math.zig");

pub const Rgb = color_math.Rgb;

/// Windows 11's own default accent (`#0078D4`), used when the system accent
/// cannot be read. Stated rather than invented: the previous fallbacks were
/// two different hand-picked blues that matched nothing on the system.
pub const default_accent: Rgb = .{ .r = 0x00, .g = 0x78, .b = 0xD4 };

/// Fluent's solid window surface (`SolidBackgroundFillColorBase`): `#F3F3F3`
/// light, `#202020` dark. Cited as DOCUMENTATION, never as a measurement —
/// T302 established that `PrintWindow(PW_RENDERFULLCONTENT)` cannot capture a
/// WinUI window at all (it returns a flat black bitmap and reports success),
/// so nothing on this box can measure these two values.
pub const surface_light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
pub const surface_dark: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 };

/// The chrome band as a wash of the color behind it. 0.08 is not a new number:
/// on the default dark background it lands within a few levels of the retired
/// `background + 20`, so this is a light-theme FIX rather than a redesign of
/// the dark look (asserted in color_math's wash tests).
pub const bar_wash: f32 = 0.08;

/// A hovered chrome control lifts one more step off the bar. Hover is a change
/// of SURFACE, the same idiom `tab_shape.HOVER_LIFT` uses for tabs.
pub const hover_wash: f32 = 0.07;

/// Primary and de-emphasized chrome text, as washes of the bar toward its own
/// contrasting side. A wash rather than a flat grey so the text ramp carries
/// the bar's hue instead of sitting on it — and then clamped to the text floor
/// below, so the ramp can never cost legibility.
pub const text_wash: f32 = 0.90;
pub const text_secondary_wash: f32 = 0.55;

/// WCAG 1.4.11's floor for chrome glyphs and meaningful boundaries. The accent
/// is clamped to THIS, not to 4.5: dragging a user's color up to the text
/// ramp stops it being recognizably their color, and an accent rule is not
/// text.
pub const ui_contrast_target: f64 = 3.0;

/// Windows' close-button red (`#C42B1C`), the one destructive color in the
/// chrome. Shared so the caption's red fill and the tab close glyph stop being
/// two different reds (`#C42B1C` vs `RGB(232,65,65)`).
pub const danger_base: Rgb = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C };

/// What a status mark MEANS, never what color it is. Every consumer resolves a
/// tone against the surface it lands on (`toneInk` / `toneFill`), so the same
/// meaning clears the same floor on light and dark alike.
///
/// Hoisted here in T367 because the connection pill needed the very colors the
/// chooser's session badges had already picked, and a second private copy of
/// "what green means" is the silent divergence this module exists to stop.
pub const Tone = enum { neutral, good, warn, danger };

/// Mac's `.green` / `.orange` / `.red` as BASES — never drawn raw. `toneInk`
/// clamps each to the surface it is drawn on.
pub const good_base: Rgb = .{ .r = 0x34, .g = 0xC7, .b = 0x59 };
pub const warn_base: Rgb = .{ .r = 0xFF, .g = 0x95, .b = 0x00 };
/// Deliberately NOT `danger_base` above: that one is Windows' close-button red,
/// a CONTROL color, and this one is Apple's status red that the chooser badges
/// and the connection pill both mean when they say "this is broken".
pub const status_danger_base: Rgb = .{ .r = 0xFF, .g = 0x3B, .b = 0x30 };

/// A status mark's ink on `surface`, floored to the 3:1 chrome target.
pub fn toneInk(surface: Rgb, tone: Tone) Rgb {
    return switch (tone) {
        .neutral => textSecondaryOn(surface),
        .good => accentOn(surface, good_base),
        .warn => accentOn(surface, warn_base),
        .danger => accentOn(surface, status_danger_base),
    };
}

/// A status chip's fill: its own ink at a low alpha over the surface, so the
/// chip reads as a tint of the thing it labels rather than a second color to
/// reconcile. Mac's badge capsules are built the same way.
pub fn toneFill(surface: Rgb, tone: Tone) Rgb {
    const alpha: f64 = if (tone == .neutral) 0.15 else 0.18;
    return color_math.mix(surface, toneInk(surface, tone), alpha);
}

/// The debug build's marker hue (T43): warning amber, the same signal the Mac
/// debug banner carries as a yellow `exclamationmark.triangle.fill`.
pub const debug_tint: Rgb = .{ .r = 0xFF, .g = 0xB0, .b = 0x00 };

/// The marker hue for the one background amber cannot mark: a terminal
/// background that is ALREADY amber. See `debugChromeBase`.
pub const debug_tint_fallback: Rgb = .{ .r = 0x7B, .g = 0x2F, .b = 0xF7 };

/// How far the chrome background is dragged toward the marker hue. Enough that
/// the band reads as a different COLOR at a glance rather than as a shade —
/// "unmistakable" is T43's whole validation — and not so far that the band
/// stops being the window's own theme underneath.
pub const debug_tint_amount: f64 = 0.35;

/// The channel distance (sum of |dR|+|dG|+|dB|) a tinted base must clear
/// against the untinted one to count as marked.
pub const debug_min_delta: u16 = 48;

fn channelDistance(a: Rgb, b: Rgb) u16 {
    const d = struct {
        fn f(x: u8, y: u8) u16 {
            return if (x > y) @as(u16, x - y) else @as(u16, y - x);
        }
    }.f;
    return d(a.r, b.r) + d(a.g, b.g) + d(a.b, b.b);
}

/// The chrome background a DEBUG (or ReleaseSafe) build paints from.
///
/// Why this and not a badge or a banner row. Mac stacks a full-width warning
/// strip above the terminal (`TerminalView.swift:81`); on Windows that row
/// would come straight out of the terminal, and T234/T205 had just spent two
/// tasks giving 95 physical px of it BACK. The design system's rule is
/// explicit — *vertical space belongs to the terminal* — so the marker has to
/// live in chrome the window already pays for. Tinting the band costs zero
/// rows and zero geometry: no rect moves, so no layout module, hit test or
/// acceptance-script datum changes with it. (T43's own Details names "a tinted
/// tab bar" as one of the two candidate vehicles; this is that one.)
///
/// Everything downstream is re-derived from the tinted base by `resolve`, so
/// the text ramp, the accent and the danger red all get their contrast floors
/// recomputed against the band that is actually painted. A tint applied to
/// `Palette.bar` AFTER the fact would leave every floor measured against a
/// surface no longer on screen.
///
/// The fallback exists because a fixed hue cannot mark a background that
/// already IS that hue: on an amber terminal background, `mix(base, amber)` is
/// the base again and the debug build would look exactly like the release one.
/// Amber and violet are 508 apart in channel distance, so by the triangle
/// inequality no background can be within `debug_min_delta / debug_tint_amount`
/// (137) of both — asserted in the sweep below rather than argued.
pub fn debugChromeBase(base: Rgb) Rgb {
    const amber = color_math.mix(base, debug_tint, debug_tint_amount);
    if (channelDistance(amber, base) >= debug_min_delta) return amber;
    return color_math.mix(base, debug_tint_fallback, debug_tint_amount);
}

/// Decode the DWORD Windows stores for the accent color. It is **ABGR**
/// (`0xAABBGGRR`), not ARGB — read it as ARGB and every accent comes out with
/// its red and blue swapped, which is the kind of bug that looks like a
/// deliberate color choice.
///
/// MEASURED on this box (2026-08-01): `HKCU\Software\Microsoft\Windows\DWM\
/// AccentColor` = 4286644328 = `0xFF810068` -> `#680081`, which is exactly the
/// accent T302 recorded as this box's real one.
pub fn accentFromDword(v: u32) Rgb {
    return .{
        .r = @truncate(v & 0xFF),
        .g = @truncate((v >> 8) & 0xFF),
        .b = @truncate((v >> 16) & 0xFF),
    };
}

/// The color the chrome paints FROM, for a `window-theme` value.
///
/// `auto`/`ghostty` tint the caption to the terminal background
/// (`Window.applyChromeTheme`), and T202's selected chiclet MERGES into the
/// pane below it — both require the chrome to be derived from the terminal
/// background. The explicit themes reset the caption to the system default
/// instead, and a band tinted to the terminal background sitting next to a
/// system-default caption is two colors pretending to be one; those follow the
/// OS surface. `system` asks the OS which way it is.
pub fn chromeBase(theme: anytype, terminal_bg: Rgb, system_light: bool) Rgb {
    return switch (theme) {
        .light => surface_light,
        .dark => surface_dark,
        .system => if (system_light) surface_light else surface_dark,
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows —
        // the same mapping `DarkMode.modeForTheme` makes.
        .auto, .ghostty => terminal_bg,
    };
}

/// Every flat color the chrome paints, resolved together.
///
/// Together, in one shot, on purpose: these colors are only correct RELATIVE
/// to each other — text is legible against `bar`, the accent clears its floor
/// against `bar`, `on_accent` against `accent`. A caller that resolved them
/// one at a time against whatever background it happened to hold is how the
/// three current answers ended up disagreeing.
///
/// Not here: the tab surfaces themselves. `tab_shape.fillColor` already
/// derives active/inactive/hovered from the strip and content backgrounds,
/// luminance-aware, and a second source for them would be the exact defect
/// this module exists to remove.
pub const Palette = struct {
    /// The chrome band behind the tabs and the caption buttons.
    bar: Rgb,
    /// The base a hovered chrome control's fill shades from.
    hover: Rgb,
    /// Primary chrome text: the active tab's title, the window title.
    text: Rgb,
    /// De-emphasized chrome text: inactive tab titles, a resting close glyph.
    text_secondary: Rgb,
    /// The user's accent, as drawn — clamped to 3:1 against `bar`.
    accent: Rgb,
    /// A foreground that reads on top of `accent`.
    on_accent: Rgb,
    /// Destructive red, clamped to 3:1 against `bar`.
    danger: Rgb,
    /// A foreground that reads on top of `danger`.
    on_danger: Rgb,
};

/// Primary chrome text for a surface that is NOT the bar — the owner-drawn
/// STATIC popups (hovered-URL preview, resize overlay) sit directly on the
/// terminal background, so clamping their label against `bar` would be
/// clamping it against a surface it does not touch.
///
/// Exported so those callers ask this module rather than re-deriving the ramp
/// and the floor; `resolve` answers the bar's own text with the same function,
/// which is what keeps the two from drifting.
pub fn textOn(surface: Rgb) Rgb {
    return color_math.contrastAdjusted(color_math.wash(surface, text_wash), surface);
}

/// De-emphasized text for a surface that is NOT the bar — the chooser's row
/// sublines, its detail subtitle, its status strip, and the marks that carry
/// the same de-emphasis (an offline status ring, a machine glyph).
///
/// Hoisted out of `resolve` in T310 so the chooser can consume the ramp
/// instead of re-deriving it. What it replaces there was a flat
/// `secondary_gray = #999999`, which is 2.8:1 on Fluent's light surface — under
/// BOTH the 4.5:1 text floor and the 3:1 chrome floor, so on a light theme the
/// sublines, the ring and the glyph went illegible together. A wash toward the
/// surface's own contrasting side plus a searched floor cannot do that on any
/// background, which is the whole reason `textOn` is shaped this way.
pub fn textSecondaryOn(surface: Rgb) Rgb {
    return color_math.contrastAdjusted(
        color_math.wash(surface, text_secondary_wash),
        surface,
    );
}

/// The accent as drawn on a surface that is NOT the bar — the chooser's row
/// pill, the Activity Monitor's active card. Same floor and the same search as
/// `resolve`, so a surface that is not the tab strip still gets the user's
/// color clamped exactly once, in this module.
pub fn accentOn(surface: Rgb, accent: Rgb) Rgb {
    return color_math.contrastAdjustedTo(accent, surface, ui_contrast_target);
}

pub fn resolve(chrome_bg: Rgb, accent: Rgb) Palette {
    const bar = color_math.wash(chrome_bg, bar_wash);
    return .{
        .bar = bar,
        .hover = color_math.wash(bar, hover_wash),
        .text = textOn(bar),
        .text_secondary = textSecondaryOn(bar),
        .accent = accentOn(bar, accent),
        .on_accent = color_math.contrastForeground(accentOn(bar, accent)),
        .danger = accentOn(bar, danger_base),
        .on_danger = color_math.contrastForeground(accentOn(bar, danger_base)),
    };
}

// --- tests ---

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

test "accentFromDword: ABGR, against the value measured on this box" {
    // HKCU\Software\Microsoft\Windows\DWM\AccentColor = 4286644328.
    try testing.expectEqual(
        Rgb{ .r = 0x68, .g = 0x00, .b = 0x81 },
        accentFromDword(4286644328),
    );
    // Read as ARGB the same DWORD would give #810068 — the swap this decode
    // exists to prevent.
    try testing.expect(!accentFromDword(4286644328).eql(.{ .r = 0x81, .g = 0x00, .b = 0x68 }));

    // Channel isolation, so a future edit cannot quietly transpose two of them.
    try testing.expectEqual(Rgb{ .r = 0xFF, .g = 0, .b = 0 }, accentFromDword(0xFF0000FF));
    try testing.expectEqual(Rgb{ .r = 0, .g = 0xFF, .b = 0 }, accentFromDword(0xFF00FF00));
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0xFF }, accentFromDword(0xFFFF0000));
}

test "chromeBase: explicit themes leave the terminal background behind" {
    const Theme = enum { auto, system, light, dark, ghostty };
    const term: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };

    // auto/ghostty follow the terminal so the selected chiclet can merge into
    // the pane (T202).
    try testing.expectEqual(term, chromeBase(Theme.auto, term, true));
    try testing.expectEqual(term, chromeBase(Theme.ghostty, term, false));

    // The explicit themes sit on the OS surface, whatever the terminal is.
    try testing.expectEqual(surface_light, chromeBase(Theme.light, term, false));
    try testing.expectEqual(surface_dark, chromeBase(Theme.dark, term, true));

    // `system` asks the OS, and the answer moves with it — the live flip
    // T305 wires to WM_SETTINGCHANGE.
    try testing.expectEqual(surface_light, chromeBase(Theme.system, term, true));
    try testing.expectEqual(surface_dark, chromeBase(Theme.system, term, false));
}

test "resolve: the light theme the old arithmetic could not express" {
    // The concrete regression. On a light chrome background `bg + 20` moved
    // everything toward white; the wash moves it toward black, so the band is
    // visible, hover is a further step, and the text is dark.
    const light: Rgb = .{ .r = 0xF3, .g = 0xF3, .b = 0xF3 };
    const p = resolve(light, .{ .r = 0x68, .g = 0x00, .b = 0x81 });

    try testing.expect(p.bar.r < light.r);
    try testing.expect(p.hover.r < p.bar.r);
    try testing.expect(color_math.luminance(p.text) < 0.5);
    try testing.expect(ratio(p.text, p.bar) >= 4.5);
    try testing.expect(ratio(p.text_secondary, p.bar) >= 4.4);

    // And on a dark one the same code lifts instead.
    const dark: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };
    const d = resolve(dark, .{ .r = 0x68, .g = 0x00, .b = 0x81 });
    try testing.expect(d.bar.r > dark.r);
    try testing.expect(d.hover.r > d.bar.r);
    try testing.expect(color_math.luminance(d.text) > 0.5);
}

test "textSecondaryOn: the floor the fixed grey could not hold (T310)" {
    // The concrete defect finding 12 names: #999999 on Fluent's light surface.
    const gray: Rgb = .{ .r = 0x99, .g = 0x99, .b = 0x99 };
    try testing.expect(ratio(gray, surface_light) < 3.0);

    // The derived answer clears the TEXT floor on both surfaces, and it is the
    // same function `resolve` uses for the bar — one ramp, not two.
    for ([_]Rgb{ surface_light, surface_dark, .{ .r = 0x28, .g = 0x28, .b = 0x28 } }) |s| {
        try testing.expect(ratio(textSecondaryOn(s), s) >= 4.4);
        // ...and it stays de-emphasized: dimmer than the primary ramp, never
        // equal to it, or the two roles stop being two roles.
        try testing.expect(ratio(textSecondaryOn(s), s) < ratio(textOn(s), s));
    }

    // It follows the surface's own direction instead of heading for one end.
    try testing.expect(color_math.luminance(textSecondaryOn(surface_light)) < 0.5);
    try testing.expect(color_math.luminance(textSecondaryOn(surface_dark)) > 0.5);

    // And `resolve` still answers the bar with exactly this function.
    const p = resolve(surface_dark, default_accent);
    try testing.expectEqual(textSecondaryOn(p.bar), p.text_secondary);
}

test "resolve: the accent survives as the user's color when it already clears 3:1" {
    // Contrast clamping must be a floor, not a filter: an accent that already
    // reads against the bar comes back untouched.
    const bg: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };
    const bright: Rgb = .{ .r = 0x3D, .g = 0x8E, .b = 0xF8 };
    try testing.expectEqual(bright, resolve(bg, bright).accent);

    // This box's real accent (#680081) is too dark to read on a dark bar, so
    // it IS moved — but only as far as the 3:1 floor, staying in its own hue.
    const deep: Rgb = .{ .r = 0x68, .g = 0x00, .b = 0x81 };
    const p = resolve(bg, deep);
    try testing.expect(!p.accent.eql(deep));
    try testing.expect(p.accent.b > p.accent.g);
    try testing.expect(p.accent.r > p.accent.g);
    try testing.expect(ratio(p.accent, p.bar) >= ui_contrast_target - 0.05);
    // Still well under the text floor — proof it stopped at the UI floor
    // instead of being dragged onto the text ramp.
    try testing.expect(ratio(p.accent, p.bar) < 4.5);
}

test "debugChromeBase: every background comes back visibly marked (T43)" {
    // The sweep is the point. A hand-picked background proves nothing here:
    // the failure mode this guards against is "the debug build looks like the
    // release build", and it only shows up on the backgrounds nobody checked.
    var bases: std.ArrayList(Rgb) = .empty;
    defer bases.deinit(testing.allocator);
    var v: u16 = 0;
    while (v <= 255) : (v += 1) {
        const c: u8 = @intCast(v);
        // Greys...
        try bases.append(testing.allocator, .{ .r = c, .g = c, .b = c });
        // ...the amber ramp itself, which is the case the fallback exists for...
        try bases.append(testing.allocator, .{
            .r = @intCast(@min(255, @as(u16, c) + 128)),
            .g = @intCast((@as(u16, c) * 176) / 255),
            .b = @intCast(c / 4),
        });
        // ...and saturated backgrounds, where a per-channel rule skews hue.
        try bases.append(testing.allocator, .{ .r = c, .g = @intCast(255 - v), .b = 0x40 });
        try bases.append(testing.allocator, .{ .r = 0x20, .g = c, .b = @intCast(255 - v) });
    }
    // The two hues the marker can be, exactly as they are painted.
    try bases.append(testing.allocator, debug_tint);
    try bases.append(testing.allocator, debug_tint_fallback);

    for (bases.items) |base| {
        const marked = debugChromeBase(base);
        try testing.expect(channelDistance(marked, base) >= debug_min_delta);
    }
}

test "debugChromeBase: no background can defeat both marker hues" {
    // The argument the fallback rests on, checked rather than asserted in
    // prose: amber and violet are far enough apart that a background within
    // reach of one is out of reach of the other.
    const span = channelDistance(debug_tint, debug_tint_fallback);
    const reach: u16 = @intFromFloat(@as(f64, @floatFromInt(debug_min_delta)) / debug_tint_amount);
    try testing.expect(span > 2 * reach);

    // And the preferred hue really is preferred: a neutral background gets
    // amber, not the fallback, so "the debug band is amber" stays learnable.
    for ([_]Rgb{ surface_light, surface_dark, .{ .r = 0x1E, .g = 0x1E, .b = 0x2E } }) |bg| {
        try testing.expectEqual(color_math.mix(bg, debug_tint, debug_tint_amount), debugChromeBase(bg));
    }
    // A background that IS the marker hue takes the fallback instead of coming
    // back unmarked — the whole reason there are two.
    try testing.expectEqual(
        color_math.mix(debug_tint, debug_tint_fallback, debug_tint_amount),
        debugChromeBase(debug_tint),
    );
}

test "debugChromeBase: the marker survives resolve with every floor intact" {
    // A marked band is still a BAND: the text on it, the accent and the danger
    // red all keep the floors `resolve` enforces, because the tint goes in
    // BEFORE the derivation rather than on top of it.
    var v: u16 = 0;
    while (v <= 255) : (v += 8) {
        const c: u8 = @intCast(v);
        for ([_]Rgb{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = @intCast(255 - v), .b = 0x40 },
            .{ .r = 0x20, .g = c, .b = @intCast(255 - v) },
        }) |bg| {
            for ([_]Rgb{ default_accent, .{ .r = 0x68, .g = 0x00, .b = 0x81 } }) |a| {
                const p = resolve(debugChromeBase(bg), a);
                try testing.expect(ratio(p.text, p.bar) >= 4.4);
                try testing.expect(ratio(p.text_secondary, p.bar) >= 4.4);
                try testing.expect(ratio(p.accent, p.bar) >= ui_contrast_target - 0.05);
                try testing.expect(ratio(p.danger, p.bar) >= ui_contrast_target - 0.05);
                try testing.expect(ratio(p.on_accent, p.accent) >= 4.4);
                try testing.expect(ratio(p.on_danger, p.danger) >= 4.4);

                // And the marked band is distinguishable from the band the
                // same background would have produced unmarked — which is the
                // property a screenshot of the two builds has to show.
                const plain = resolve(bg, a);
                try testing.expect(channelDistance(p.bar, plain.bar) >= 16);
            }
        }
    }
}

test "resolve: every floor holds across the whole background x accent space" {
    // The sweep, and it is the point of the task. A single hand-picked pair
    // proves nothing here: `bg + 20` looked fine against the one background
    // anybody checked it against, and that is exactly how it survived.
    var bgs: std.ArrayList(Rgb) = .empty;
    defer bgs.deinit(testing.allocator);
    var v: u16 = 0;
    while (v <= 255) : (v += 8) {
        const c: u8 = @intCast(v);
        // Greys across the full range...
        try bgs.append(testing.allocator, .{ .r = c, .g = c, .b = c });
        // ...plus saturated backgrounds, where a per-channel rule skews hue.
        try bgs.append(testing.allocator, .{ .r = c, .g = @intCast(255 - v), .b = 0x40 });
        try bgs.append(testing.allocator, .{ .r = 0x20, .g = c, .b = @intCast(255 - v) });
    }

    const accents = [_]Rgb{
        .{ .r = 0x68, .g = 0x00, .b = 0x81 }, // this box's real accent
        default_accent,
        .{ .r = 0x3D, .g = 0x8E, .b = 0xF8 }, // the retired literal
        .{ .r = 0x00, .g = 0x00, .b = 0x00 }, // degenerate: pure black
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, // degenerate: pure white
        .{ .r = 0xFF, .g = 0xF0, .b = 0x00 }, // a very light saturated pick
        .{ .r = 0x00, .g = 0x33, .b = 0x00 }, // a very dark saturated pick
    };

    for (bgs.items) |bg| {
        for (accents) |a| {
            const p = resolve(bg, a);

            // Text floors.
            try testing.expect(ratio(p.text, p.bar) >= 4.4);
            try testing.expect(ratio(p.text_secondary, p.bar) >= 4.4);

            // UI floors.
            try testing.expect(ratio(p.accent, p.bar) >= ui_contrast_target - 0.05);
            try testing.expect(ratio(p.danger, p.bar) >= ui_contrast_target - 0.05);
            try testing.expect(ratio(p.on_accent, p.accent) >= 4.4);
            try testing.expect(ratio(p.on_danger, p.danger) >= 4.4);

            // The band reads as a band, and hover reads as a lift off it —
            // the "mutually distinguishable" half of T203's validation, which
            // is what actually broke in a light theme.
            try testing.expect(!p.bar.eql(bg));
            try testing.expect(!p.hover.eql(p.bar));
            try testing.expect(ratio(p.hover, p.bar) >= 1.02);
        }
    }
}
