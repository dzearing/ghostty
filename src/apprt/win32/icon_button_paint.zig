//! The GDI half of an icon-button glyph: one function, so the tab strip and
//! the pane banner cannot draw the same chevron two different ways (T232).
//!
//! The geometry — and all of its symmetry — lives in `icon_button.zig`, which
//! stays free of OS imports so its assertions run in every app-runtime lane.
//! This module exists only because that one cannot call `Polygon`, and
//! because putting the call in `Window.zig` would force `BannerOverlay` to
//! import the whole window to draw a chevron.

const w32 = @import("win32.zig");
const icon_button = @import("icon_button.zig");

/// Fill one glyph's quads inside `target`.
///
/// FILLED, never stroked. `LineTo` excludes its endpoint, so a stroke from
/// `cx-h` to `cx+h` paints one pixel short on the trailing side, and a pen
/// wider than 1 px biases its extra pixel to one side at even widths.
/// Together they are the user's "the left half of the horizontal line of the
/// plus is shorter than the right half", and they cannot be fixed by nudging
/// coordinates because the bias flips with DPI (design system §4.1).
pub fn glyph(
    hdc: w32.HDC,
    m: icon_button.Metrics,
    target: icon_button.Rect,
    which: icon_button.Glyph,
    color: u32,
) void {
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
