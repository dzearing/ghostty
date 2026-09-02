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

/// The most of the chrome's wash STEP the marker is allowed to cost (T364).
///
/// Every separation this chrome draws above the bar — an inactive tab, a
/// hovered tab, an icon button's hover fill — is a fixed FRACTION of the
/// distance from the bar to white (`color_math.wash`). So the size of the step
/// depends on how dark the bar is, and mixing amber into a dark base makes it
/// much lighter: on `--background=#000000` the inactive tab's lift fell from
/// 14 levels to 9, a debug-only erosion of exactly the separation T206 exists
/// to create. `debugChromeBase` now puts that room back (see there), and this
/// is how much it is allowed to leave behind.
///
/// Not zero, because it cannot be: only pure black is as far from white as
/// pure black, so a marker on a near-black background HAS to spend some of the
/// room to be a color at all. 10% is a step of 12.6 where the release paints
/// 14 — under a level of difference on the surface a dev is looking at, and
/// far inside the 35% that made this a task.
pub const debug_max_step_loss: f64 = 0.10;

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
    const amber = markedBase(base, debug_tint);
    if (channelDistance(amber, base) >= debug_min_delta) return amber;
    return markedBase(base, debug_tint_fallback);
}

/// The marked base for one hue: the tint, with the wash room it costs put back
/// (T364).
///
/// The tint itself is unchanged — `mix(base, hue, debug_tint_amount)` is still
/// what decides the COLOR. What follows it is a move along the axis `wash`
/// travels, which restores the distance to the wash target without touching
/// the hue that distance is now carrying. On a dark base that means the marked
/// band comes back DARKER than the plain mix, so the washes above it step as
/// far as they do in the release build; on a light one it comes back lighter,
/// for the same reason in the other direction.
///
/// T43 still comes first. A restored base that no longer clears
/// `debug_min_delta` — or that has crossed the light/dark line the washes take
/// their direction from — loses to the plain tint: a band that steps perfectly
/// and does not say "this is not the release" fails the only thing the marker
/// is for.
fn markedBase(base: Rgb, hue: Rgb) Rgb {
    const tinted = color_math.mix(base, hue, debug_tint_amount);
    const restored = color_math.restoreWashHeadroom(tinted, base, 1.0 - debug_max_step_loss);
    if (channelDistance(restored, base) >= debug_min_delta and
        color_math.isLight(restored) == color_math.isLight(base)) return restored;
    return tinted;
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

/// Which side of light/dark this window is on, for a `window-theme` value —
/// the ONE answer to that question (T309).
///
/// Derived FROM `chromeBase` rather than beside it, so the DWM immersive
/// dark-mode attribute, the USER menu palette and the color the chrome paints
/// cannot disagree: they are the same decision read two ways. `applyChromeTheme`
/// and `DarkMode.modeForTheme` each used to re-answer it with their own inline
/// Rec.709 `0.2126/0.7152/0.0722` luminance, which agrees with this on every
/// ordinary background and is not guaranteed to near the crossover — the same
/// defect T203/T304 was filed against, one level up: not a disagreeing color
/// but a disagreeing DECISION that colors are picked from.
///
/// The weighting is `color_math.isLight`'s Rec.601, which is the repo's answer
/// everywhere else AND the Mac's: `OSColor.isLightColor` is
/// `0.299/0.587/0.114 > 0.5` (`macos/Sources/Helpers/Extensions/
/// OSColor+Extension.swift`), and this is the decision that picks the same
/// title bar Mac picks. Note the boundary moved with it: a background at
/// exactly 0.5 luminance is now DARK (`> 0.5` is light), matching Mac, where
/// the old `< 0.5` call read it as light.
///
/// Not to be confused with `color_math.contrastForeground`, which deliberately
/// does NOT use `isLight` — picking ink for a surface is a contrast question
/// with a measurable better answer, while which theme a window is in is a
/// single either/or that every surface must agree on.
pub fn isDark(theme: anytype, terminal_bg: Rgb, system_light: bool) bool {
    return !color_math.isLight(chromeBase(theme, terminal_bg, system_light));
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
    /// Destructive red as a FILL — the caption close slab's hover, the
    /// connection pill's Reconnect capsule. Kept dark enough that WHITE reads
    /// on it (see `dangerFillOn`), which is why it is not simply `danger_ink`.
    danger: Rgb,
    /// The foreground on `danger`: always white, per Windows' convention.
    on_danger: Rgb,
    /// Destructive red as INK on the bar — the tab strip's close glyph on
    /// hover, which is a red mark rather than a red fill. Clamped to 3:1
    /// against `bar` like any other chrome glyph.
    danger_ink: Rgb,
};

/// The luminance a destructive FILL must stay at or under for white to clear
/// the 4.5:1 text floor on it: `1.05 / (L + 0.05) >= 4.5`.
pub const danger_fill_max_luminance: f64 = 1.05 / 4.5 - 0.05;

/// The one foreground a destructive fill ever takes.
pub const on_danger_fixed: Rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };

/// The destructive red as INK on `surface` — a red MARK, floored to the 3:1
/// chrome target like every other glyph.
pub fn dangerInkOn(surface: Rgb) Rgb {
    return accentOn(surface, danger_base);
}

/// The destructive red as a FILL on `surface`, with white as its foreground.
///
/// Windows' convention IS the spec for this one: every native window paints a
/// WHITE X on the close button's red hover, and a black one reads as broken
/// chrome at the single most-looked-at control on the window (T528, user-
/// reported). So the constraint goes on the FILL — the red may not be lightened
/// past the point where white clears 4.5:1 on it — instead of on the
/// foreground, which is what used to give way.
///
/// It gave way silently because every floor still passed: on a mid-dark bar
/// (`#202020`'s band is one) the 3:1 ink search lightens `#C42B1C` until the
/// lightened red's own luminance crosses `contrastForeground`'s crossover, and
/// black-on-light-red is WCAG-clean at 4.9:1. Two correct rules, one wrong
/// button.
///
/// Where the ceiling and the 3:1 lift off the bar cannot both hold — bars in
/// roughly `#2F2F2F`..`#595959`, where no red is light enough to clear the band
/// and dark enough to carry white — the convention wins and the fill sits at
/// the ceiling, i.e. as far off the bar as a white-safe red can get. The fill
/// is still a saturated red against a grey band, which no luminance ratio
/// measures; a black X on it is a defect a user reports.
pub fn dangerFillOn(surface: Rgb) Rgb {
    return color_math.cappedLuminance(dangerInkOn(surface), danger_fill_max_luminance);
}

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
        .danger = dangerFillOn(bar),
        .on_danger = on_danger_fixed,
        .danger_ink = dangerInkOn(bar),
    };
}

// --- tests ---

fn ratio(a: Rgb, b: Rgb) f64 {
    return color_math.wcagContrastRatio(
        color_math.wcagLuminance(a),
        color_math.wcagLuminance(b),
    );
}

/// The close-button convention, as one assertion every sweep can make (T528):
/// the glyph on a destructive fill IS white, and white really reads on it.
///
/// The second half is what makes the first one honest — a palette could always
/// have answered "white" and left the fill too pale to see it on.
fn expectWhiteOnDanger(p: Palette) !void {
    try testing.expectEqual(on_danger_fixed, p.on_danger);
    try testing.expect(ratio(p.on_danger, p.danger) >= 4.5);

    // And the fill is still as far off the bar as that ceiling allows: it
    // clears the 3:1 chrome floor, or it is sitting ON the ceiling because no
    // white-safe red could.
    try testing.expect(
        ratio(p.danger, p.bar) >= ui_contrast_target or
            color_math.wcagLuminance(p.danger) >= danger_fill_max_luminance - 0.004,
    );
}

test "resolve: the close glyph is WHITE on every theme (T528)" {
    // The user's report, as a number. `#202020` is Fluent's dark surface, so
    // its band is the one a default dark theme actually paints — and the old
    // `contrastForeground(danger)` answered BLACK there, at a perfectly legal
    // 4.9:1, because the 3:1 ink search had lightened the red past white's
    // reach first.
    const p = resolve(surface_dark, default_accent);
    try testing.expectEqual(on_danger_fixed, p.on_danger);
    try testing.expect(ratio(p.on_danger, p.danger) >= 4.5);
    try testing.expect(color_math.wcagLuminance(p.danger) > color_math.wcagLuminance(p.bar));

    // The INK is a different answer to a different question and keeps its own
    // floor: the tab strip's close glyph is a red mark ON the band, so it has
    // to lift off the band rather than carry a foreground.
    try testing.expect(ratio(p.danger_ink, p.bar) >= ui_contrast_target);

    // A light theme never needed the cap and must not be moved by it: Windows'
    // own red already carries white there.
    const light = resolve(surface_light, default_accent);
    try testing.expectEqual(danger_base, light.danger);
    try testing.expectEqual(on_danger_fixed, light.on_danger);
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

test "isDark: the chrome's side never disagrees with the surface it paints" {
    // The assertion T309 exists to make possible, and it is only an assertion
    // because there is one function left to assert about: while the DWM
    // attribute and `chromeBase` were computed by different code with different
    // luminance weightings, "they agree" was a claim about two crossovers
    // landing in the same place, which nothing checked and which is false in
    // principle near mid-grey.
    const Theme = enum { auto, system, light, dark, ghostty };
    const themes = [_]Theme{ .auto, .system, .light, .dark, .ghostty };

    // Sweep the grey ramp plus the saturated corners, both OS answers. A grey
    // ramp is where the two weightings differ least and a saturated color is
    // where they differ most, so both belong in the sweep.
    var v: u16 = 0;
    while (v <= 255) : (v += 1) {
        const c: u8 = @intCast(v);
        const cases = [_]Rgb{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = 0, .b = 0 },
            .{ .r = 0, .g = c, .b = 0 },
            .{ .r = 0, .g = 0, .b = c },
            .{ .r = c, .g = 0xFF - c, .b = 0x80 },
        };
        for (cases) |bg| {
            for (themes) |theme| {
                for ([_]bool{ true, false }) |sys_light| {
                    const base = chromeBase(theme, bg, sys_light);
                    try testing.expectEqual(
                        !color_math.isLight(base),
                        isDark(theme, bg, sys_light),
                    );
                }
            }
        }
    }
}

test "isDark: the decision table, and the surfaces are on their nominal sides" {
    const Theme = enum { auto, system, light, dark, ghostty };
    const dark_bg: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };
    const light_bg: Rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };

    // The explicit themes are their own answer whatever else moves — which
    // requires the OS surfaces to actually BE light and dark. If `surface_light`
    // were ever edited to something the luminance test reads as dark, the
    // sweep above would still pass (it compares two views of one value) and a
    // `window-theme = light` window would get a dark title bar; this is the
    // check that catches it.
    for ([_]Rgb{ dark_bg, light_bg }) |bg| {
        for ([_]bool{ true, false }) |sys| {
            try testing.expect(!isDark(Theme.light, bg, sys));
            try testing.expect(isDark(Theme.dark, bg, sys));
        }
    }

    // `system` is the OS's call; `auto`/`ghostty` are the terminal's.
    try testing.expect(!isDark(Theme.system, dark_bg, true));
    try testing.expect(isDark(Theme.system, light_bg, false));
    try testing.expect(isDark(Theme.auto, dark_bg, true));
    try testing.expect(!isDark(Theme.auto, light_bg, false));
    try testing.expect(isDark(Theme.ghostty, dark_bg, true));

    // Rec.601, matching the Mac's `isLightColor`: green weighs most, blue
    // least, so pure green is a LIGHT window and pure blue a dark one.
    try testing.expect(!isDark(Theme.auto, Rgb{ .r = 0, .g = 0xFF, .b = 0 }, false));
    try testing.expect(isDark(Theme.auto, Rgb{ .r = 0, .g = 0, .b = 0xFF }, true));

    // The boundary, stated rather than left to be discovered: `isLight` is
    // `> 0.5`, so a background at exactly half luminance is DARK. #808080 is
    // 0.50196 and lands light; the old `< 0.5` Rec.709 call read both the same
    // way, and this is the one background where the migration is visible.
    try testing.expect(!isDark(Theme.auto, Rgb{ .r = 0x80, .g = 0x80, .b = 0x80 }, false));
    try testing.expect(isDark(Theme.auto, Rgb{ .r = 0x7F, .g = 0x7F, .b = 0x7F }, false));
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
    try testing.expect(ratio(p.accent, p.bar) >= ui_contrast_target);
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
    // The expectation is the amber construction in full — the tint plus the
    // wash room T364 puts back — so this still fails if the fallback hue is
    // reached for on a background amber can mark.
    for ([_]Rgb{ surface_light, surface_dark, .{ .r = 0x1E, .g = 0x1E, .b = 0x2E } }) |bg| {
        const marked = debugChromeBase(bg);
        try testing.expectEqual(markedBase(bg, debug_tint), marked);
        // And it leans amber rather than violet, which is the part a reader of
        // the band can check without the arithmetic.
        try testing.expect(marked.r > marked.b);
    }
    // A background that IS the marker hue takes the fallback instead of coming
    // back unmarked — the whole reason there are two.
    try testing.expectEqual(
        markedBase(debug_tint, debug_tint_fallback),
        debugChromeBase(debug_tint),
    );
}

test "debugChromeBase: the marker cannot cost the chrome its wash steps (T364)" {
    // The number this task exists for, as ONE ratio. Every separation above
    // the bar is `alpha * washHeadroom` — an inactive tab, a hovered tab, an
    // icon button's hover fill — so a base that keeps its headroom keeps all
    // of them, whatever their alphas are, and a sweep of bases is the whole
    // proof.
    const floor: f64 = 1.0 - debug_max_step_loss;
    var v: u16 = 0;
    while (v <= 255) : (v += 1) {
        const c: u8 = @intCast(v);
        for ([_]Rgb{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = @intCast(255 - v), .b = 0x40 },
            .{ .r = 0x20, .g = c, .b = @intCast(255 - v) },
            .{
                .r = @intCast(@min(255, @as(u16, c) + 128)),
                .g = @intCast((@as(u16, c) * 176) / 255),
                .b = c / 4,
            },
        }) |bg| {
            const marked = debugChromeBase(bg);
            const want: f64 = @floatFromInt(color_math.washHeadroom(bg, bg));
            const have: f64 = @floatFromInt(color_math.washHeadroom(marked, bg));

            if (color_math.isLight(marked) == color_math.isLight(bg)) {
                // The ordinary case, and the guarantee: the marked band washes
                // the same way the plain one does and keeps its room to do it.
                try testing.expect(have >= want * floor);
            } else {
                // The tint crossed the light/dark line, so `markedBase` kept
                // the plain tint rather than push a band onto the far side of
                // the line its washes take their direction from. Restoring
                // headroom cannot help there, and it does not make it worse:
                // the measured floor over this sweep is 0.8933, on
                // `#208679` — one rounding step under the guarantee, not a
                // separate policy.
                try testing.expect(have >= want * 0.89);
            }
        }
    }
}

test "debugChromeBase: the #000000 regression, as the two step tables (T364)" {
    // T364's own table, which is what a dev on a dark theme actually sees: the
    // bar the marker paints on a pure black background, and the inactive tab
    // lifted off it. Measured before this task: 9 / 11 / 14 against a release
    // chrome that steps 14 / 14 / 14, because the marked bar was `(102,77,20)`
    // where the release paints `(20,20,20)`.
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    // `tab_shape.INACTIVE_LIFT`, which is `banner_card.FILL_LIGHTEN`. Named
    // here rather than imported: this module is the bottom of the chrome's
    // color stack and does not depend on the painters above it.
    const inactive_lift: f32 = 0.06;

    const plain_bar = color_math.wash(black, bar_wash);
    const marked_bar = color_math.wash(debugChromeBase(black), bar_wash);
    const plain = color_math.wash(plain_bar, inactive_lift);
    const marked = color_math.wash(marked_bar, inactive_lift);

    try testing.expectEqual(@as(u8, 14), plain.r - plain_bar.r);
    try testing.expectEqual(@as(u8, 14), plain.g - plain_bar.g);
    try testing.expectEqual(@as(u8, 14), plain.b - plain_bar.b);

    // 11 / 13 / 14 now. The red channel is the one that cannot come all the
    // way back: amber IS 255 red, so on a black base the marker has to spend
    // that channel's room to be amber at all — spending less of it takes the
    // band under `debug_min_delta` and stops it being a marker.
    try testing.expect(marked.r - marked_bar.r >= 11);
    try testing.expect(marked.g - marked_bar.g >= 13);
    try testing.expect(marked.b - marked_bar.b >= 14);

    // And the aggregate, which is the guarantee rather than the table: 0.899
    // of the release chrome's step, where it used to be 0.803.
    const have: f64 = @floatFromInt(color_math.washHeadroom(marked_bar, plain_bar));
    const want: f64 = @floatFromInt(color_math.washHeadroom(plain_bar, plain_bar));
    // `- 1.5` is the rounding slack of a u8 bar washed off a u8 base, not a
    // softened bar: 634 against a guarantee of 634.5.
    try testing.expect(have >= want * (1.0 - debug_max_step_loss) - 1.5);
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
                try testing.expect(ratio(p.accent, p.bar) >= ui_contrast_target);
                try testing.expect(ratio(p.danger_ink, p.bar) >= ui_contrast_target);
                try testing.expect(ratio(p.on_accent, p.accent) >= 4.4);
                try expectWhiteOnDanger(p);

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
            try testing.expect(ratio(p.accent, p.bar) >= ui_contrast_target);
            try testing.expect(ratio(p.danger_ink, p.bar) >= ui_contrast_target);
            try testing.expect(ratio(p.on_accent, p.accent) >= 4.4);
            try expectWhiteOnDanger(p);

            // The band reads as a band, and hover reads as a lift off it —
            // the "mutually distinguishable" half of T203's validation, which
            // is what actually broke in a light theme.
            try testing.expect(!p.bar.eql(bg));
            try testing.expect(!p.hover.eql(p.bar));
            try testing.expect(ratio(p.hover, p.bar) >= 1.02);
        }
    }
}
