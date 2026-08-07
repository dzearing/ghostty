//! The GDI half of an icon-button glyph: one function, so the tab strip, the
//! caption and the pane banner cannot draw the same chevron two different
//! ways (T232).
//!
//! Since T497 that one function renders the SYSTEM ICON FONT first — Segoe
//! Fluent Icons (ships with Windows 11), else Segoe MDL2 Assets (ships with
//! Windows 10) — and only falls back to the hand-drawn filled quads when
//! neither face is actually present. The user's report was direct: *"our
//! icons look chunky and don't really feel native to the platform. Chevrons
//! are chunky for example. We should absolutely feel native like it was built
//! by microsoft using their design language."* A 2 DIP filled mark with
//! square-cut ends cannot read like a 1 px Fluent stroke, and no amount of
//! geometry tuning closes that gap — the fix is to draw the same glyphs
//! Windows draws.
//!
//! The quad geometry — and all of its symmetry — stays in `icon_button.zig`,
//! which stays free of OS imports so its assertions run in every app-runtime
//! lane. It is the fallback, and the reason a machine with no icon font gets
//! a slightly heavier chevron instead of a tofu box.

const std = @import("std");
const w32 = @import("win32.zig");
const icon_button = @import("icon_button.zig");

/// Which icon font this process actually has, resolved once on first use.
/// "Ships with" is not "is present" (the T172 lesson), so presence is proven
/// by selecting the face and asking GDI what it really mapped — the font
/// mapper substitutes silently on a miss, which would otherwise draw the
/// PUA codepoints below as whatever the substitute keeps there.
const Face = enum { unknown, fluent, mdl2, none };
var detected: Face = .unknown;

const fluent_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons");
const mdl2_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets");

/// The Fluent/MDL2 codepoint for each chrome glyph. Identical in both faces —
/// MDL2 is the same symbol set one design generation earlier — which is what
/// makes the fallback a face swap rather than a second mapping.
fn codepoint(which: icon_button.Glyph) u16 {
    return switch (which) {
        .close => 0xE8BB, // ChromeClose
        .add => 0xE710, // Add
        .menu => 0xE700, // GlobalNavButton
        .chevron_up => 0xE70E, // ChevronUp
        .chevron_down => 0xE70D, // ChevronDown
        .minimize => 0xE921, // ChromeMinimize
        .maximize => 0xE922, // ChromeMaximize
        .restore => 0xE923, // ChromeRestore
        .overflow => 0xE712, // More
        .back => 0xE72B, // Back
        .forward => 0xE72A, // Forward
        .refresh => 0xE72C, // Refresh
        .home => 0xE80F, // Home
        .contents => 0xE700, // GlobalNavButton — Windows' own nav-pane toggle
    };
}

/// Font em size per glyph, in DIP. The caption cluster (and the tab close,
/// which shares `ChromeClose`) renders at 10 — Windows' own caption glyph
/// size, the number the user's "expected" screenshot is drawn at. The strip
/// and banner marks render at 12, keeping the optical step the drawn marks
/// had between the small close and the wider hamburger/chevrons.
fn fontDip(which: icon_button.Glyph) f32 {
    return switch (which) {
        .minimize, .maximize, .restore, .close, .overflow => 10.0,
        .add, .menu, .chevron_up, .chevron_down => 12.0,
        // The nav cluster renders at the strip size: back/forward/refresh/home
        // sit beside an address field the way the strip glyphs sit beside
        // tabs, and 10 is the caption's size, not a toolbar's.
        .back, .forward, .refresh, .home, .contents => 12.0,
    };
}

/// Does `hdc` really map `face`? Selecting a missing face silently
/// substitutes, so create-select-ask is the only honest check.
fn faceMaps(hdc: w32.HDC, face: [:0]const u16) bool {
    const font = w32.CreateFontW(
        -16, // any plausible size; presence is per-face, not per-size
        0,
        0,
        0,
        w32.FW_NORMAL,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0, // OUT_DEFAULT_PRECIS
        0, // CLIP_DEFAULT_PRECIS
        w32.ANTIALIASED_QUALITY,
        0, // DEFAULT_PITCH | FF_DONTCARE
        face.ptr,
    ) orelse return false;
    defer _ = w32.DeleteObject(font);
    const old = w32.SelectObject(hdc, font) orelse return false;
    defer _ = w32.SelectObject(hdc, old);

    var got: [w32.LF_FACESIZE]u16 = undefined;
    const n = w32.GetTextFaceW(hdc, @intCast(got.len), &got);
    if (n <= 0) return false;
    // Scan for the terminator rather than trusting the return value's
    // convention (whether it counts the null differs between the docs and
    // the implementations' folklore).
    var len: usize = 0;
    while (len < got.len and got[len] != 0) : (len += 1) {}
    const mapped = got[0..len];
    if (mapped.len != face.len) return false;
    for (mapped, face) |a, b| {
        // Face names are ASCII; fold case so a mapper that reports a cased
        // variant is not mistaken for a substitution.
        const la = if (a < 128) std.ascii.toLower(@intCast(a)) else a;
        const lb = if (b < 128) std.ascii.toLower(@intCast(b)) else b;
        if (la != lb) return false;
    }
    return true;
}

/// The face to draw with, probing on first call. Paints happen on the UI
/// thread only, so a plain module-local is safe.
fn resolveFace(hdc: w32.HDC) ?[:0]const u16 {
    switch (detected) {
        .fluent => return fluent_face,
        .mdl2 => return mdl2_face,
        .none => return null,
        .unknown => {},
    }
    if (faceMaps(hdc, fluent_face)) {
        detected = .fluent;
        return fluent_face;
    }
    if (faceMaps(hdc, mdl2_face)) {
        detected = .mdl2;
        return mdl2_face;
    }
    detected = .none;
    return null;
}

/// Draw `which` from the icon font, centered in `target`. False = no icon
/// font on this machine; the caller falls back to the drawn quads.
fn fontGlyph(
    hdc: w32.HDC,
    m: icon_button.Metrics,
    target: icon_button.Rect,
    which: icon_button.Glyph,
    color: u32,
) bool {
    return fontCodepoint(hdc, m.scale, target, codepoint(which), fontDip(which), color);
}

/// Draw one icon-font codepoint at `dip` DIP, centered in `target`. False =
/// this machine has neither icon face.
///
/// Public because not every icon in the app is an icon BUTTON. The read-only
/// badge's eye (T445) is a decoration inside a card whose LABEL carries the
/// meaning, so its answer to a missing face is "draw no glyph" — not the
/// hand-drawn quad fallback, which has no vocabulary for a lens-and-pupil
/// shape and would produce a mark worse than none. Sharing this keeps the
/// face probe (`resolveFace`) in one place rather than growing a second copy
/// that can disagree about what "present" means.
pub fn fontCodepoint(
    hdc: w32.HDC,
    scale: f32,
    target: icon_button.Rect,
    cp: u16,
    dip: f32,
    color: u32,
) bool {
    const face = resolveFace(hdc) orelse return false;

    const em: i32 = @max(@as(i32, @intFromFloat(@round(dip * scale))), 1);
    // Negative height asks the mapper for a CHARACTER height, i.e. the em
    // square — which is exactly the box these icon faces are designed to
    // fill, so `em` IS the icon size on screen.
    const font = w32.CreateFontW(
        -em,
        0,
        0,
        0,
        w32.FW_NORMAL,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        w32.ANTIALIASED_QUALITY,
        0,
        face.ptr,
    ) orelse return false;
    defer _ = w32.DeleteObject(font);
    const old_font = w32.SelectObject(hdc, font) orelse return false;
    defer _ = w32.SelectObject(hdc, old_font);

    const old_bk = w32.SetBkMode(hdc, w32.TRANSPARENT);
    defer _ = w32.SetBkMode(hdc, old_bk);
    const old_color = w32.SetTextColor(hdc, color);
    defer _ = w32.SetTextColor(hdc, old_color);

    var rect = w32.RECT{
        .left = target.left,
        .top = target.top,
        .right = target.right,
        .bottom = target.bottom,
    };
    var ch = [1]u16{cp};
    _ = w32.DrawTextW(
        hdc,
        &ch,
        1,
        &rect,
        w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
    );
    return true;
}

/// Render one glyph inside `target`: the system icon font when present, the
/// filled quads when not.
///
/// The quad path is FILLED, never stroked. `LineTo` excludes its endpoint, so
/// a stroke from `cx-h` to `cx+h` paints one pixel short on the trailing
/// side, and a pen wider than 1 px biases its extra pixel to one side at even
/// widths. Together they are the user's "the left half of the horizontal line
/// of the plus is shorter than the right half", and they cannot be fixed by
/// nudging coordinates because the bias flips with DPI (design system §4.1).
pub fn glyph(
    hdc: w32.HDC,
    m: icon_button.Metrics,
    target: icon_button.Rect,
    which: icon_button.Glyph,
    color: u32,
) void {
    if (fontGlyph(hdc, m, target, which, color)) return;

    var quads: [icon_button.max_quads]icon_button.Quad = undefined;

    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    defer _ = w32.SelectObject(hdc, old_brush);

    // NULL_PEN, or `Polygon` also OUTLINES each quad with whatever pen the DC
    // is holding — which would put the wide-pen bias straight back on top of
    // the fill that exists to remove it.
    const old_pen = if (w32.GetStockObject(w32.NULL_PEN)) |p|
        w32.SelectObject(hdc, p)
    else
        null;
    defer if (old_pen) |p| {
        _ = w32.SelectObject(hdc, p);
    };

    for (icon_button.glyphQuads(m, target, which, &quads)) |q| {
        _ = w32.Polygon(hdc, @ptrCast(&q.pts), @intCast(q.pts.len));
    }
}
