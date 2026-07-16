//! Owner-painted hero-mode carousel column (T58 design, T59a static pass).
//!
//! The carousel lives in the parent Window's client area — there are NO
//! child HWNDs per tile. Tiles show snapshot DIBs captured by each pane's
//! renderer thread (Surface.heroSnap*). This module is geometry + GDI
//! painting + hit-testing only; all state lives on Window (per-tab hero
//! arrays) and Surface (DIB cache). Pure math is in hero_math.zig.
//!
//! T59a scope: static render (selected tile centered, no scroll/hover/
//! animation — those land in T59b) + click-to-select hit testing.
const std = @import("std");

const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");
const hero_math = @import("hero_math.zig");

const log = std.log.scoped(.win32);

/// Everything needed to place carousel tiles for the active tab.
pub const Geometry = struct {
    split: hero_math.Split,
    layout: hero_math.TileLayout,
    top0: i32,
    count: usize,
    selected: usize,
};

fn toHm(rect: w32.RECT) hero_math.Rect {
    return .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
}

fn toW32(rect: hero_math.Rect) w32.RECT {
    return .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
}

/// The hero/divider/carousel split of a content rect for the active tab.
pub fn splitRects(win: *Window, rect: w32.RECT) hero_math.Split {
    return hero_math.splitRects(
        toHm(rect),
        win.tab_hero_ratio[win.active_tab],
        win.scale,
    );
}

/// Full carousel geometry for the active tab, or null when hero mode is
/// not active there.
pub fn geometry(win: *Window) ?Geometry {
    if (win.tab_count == 0) return null;
    const tab = win.active_tab;
    if (!win.tab_hero_active[tab]) return null;

    var count: usize = 0;
    var it = win.tab_trees[tab].iterator();
    while (it.next()) |_| count += 1;
    if (count == 0) return null;

    const split = splitRects(win, win.surfaceRect());
    const hero_w: f32 = @floatFromInt(@max(split.hero.width(), 1));
    const hero_h: f32 = @floatFromInt(@max(split.hero.height(), 1));
    const layout = hero_math.tileLayout(split.carousel, hero_w / hero_h, win.scale);

    const selected: usize = @min(@as(usize, win.tab_hero_index[tab]), count - 1);
    const top0 = hero_math.stripTop(split.carousel, layout, selected, 0);
    return .{
        .split = split,
        .layout = layout,
        .top0 = top0,
        .count = count,
        .selected = selected,
    };
}

/// The client-space rect of tile `index`, or null when hero is inactive
/// or the index is out of range.
pub fn tileRect(win: *Window, index: usize) ?w32.RECT {
    const geo = geometry(win) orelse return null;
    if (index >= geo.count) return null;
    return toW32(hero_math.tileRect(geo.split.carousel, geo.layout, geo.top0, index));
}

/// Which tile contains the client-space point, if any.
pub fn hitTest(win: *Window, x: i32, y: i32) ?usize {
    const geo = geometry(win) orelse return null;
    return hero_math.hitTest(geo.split.carousel, geo.layout, geo.top0, geo.count, x, y);
}

/// Paint the divider line + carousel column (double-buffered) into the
/// window DC. Called from Window.paintWindow inside BeginPaint/EndPaint.
pub fn paint(win: *Window, hdc_screen: w32.HDC) void {
    const geo = geometry(win) orelse return;

    // The owner-painted region: divider band through the right edge.
    const region: w32.RECT = .{
        .left = geo.split.divider.left,
        .top = geo.split.carousel.top,
        .right = geo.split.carousel.right,
        .bottom = geo.split.carousel.bottom,
    };
    const rw = region.right - region.left;
    const rh = region.bottom - region.top;
    if (rw <= 0 or rh <= 0) return;

    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, rw, rh) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // Background: window background darkened ~30% toward black (Mac:
    // black @ 0.3 alpha over the window background).
    const bg = win.app.config.background;
    const bg_color = w32.RGB(
        @intCast((@as(u16, bg.r) * 7) / 10),
        @intCast((@as(u16, bg.g) * 7) / 10),
        @intCast((@as(u16, bg.b) * 7) / 10),
    );
    var full: w32.RECT = .{ .left = 0, .top = 0, .right = rw, .bottom = rh };
    if (w32.CreateSolidBrush(bg_color)) |brush| {
        _ = w32.FillRect(mem_dc, &full, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // Divider: thin vertical line centered in the band; gray for now
    // (hover/drag accent lands with T59b's drag support).
    const line_w = @max(@as(i32, @intFromFloat(@round(1.0 * win.scale))), 1);
    const band_w = geo.split.divider.width();
    var line: w32.RECT = .{
        .left = @divTrunc(band_w - line_w, 2),
        .top = 0,
        .right = @divTrunc(band_w - line_w, 2) + line_w,
        .bottom = rh,
    };
    if (w32.CreateSolidBrush(w32.RGB(96, 96, 96))) |brush| {
        _ = w32.FillRect(mem_dc, &line, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // Tiles.
    var it = win.tab_trees[win.active_tab].iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const tr = hero_math.tileRect(geo.split.carousel, geo.layout, geo.top0, i);
        // Skip tiles fully outside the painted region.
        if (tr.bottom <= region.top or tr.top >= region.bottom) continue;
        const local: w32.RECT = .{
            .left = tr.left - region.left,
            .top = tr.top - region.top,
            .right = tr.right - region.left,
            .bottom = tr.bottom - region.top,
        };
        paintTile(win, mem_dc, entry.view, local, i == geo.selected);
    }

    _ = w32.BitBlt(hdc_screen, region.left, region.top, rw, rh, mem_dc, 0, 0, w32.SRCCOPY);
}

/// One thumbnail tile: rounded-clipped snapshot (dimmed unless selected)
/// + rounded border. Mac chrome parity minus the glow shadow (GDI has no
/// cheap soft shadow — deliberate simplification, T58 decision 3).
fn paintTile(
    win: *Window,
    dc: w32.HDC,
    surface: *Surface,
    rect: w32.RECT,
    selected: bool,
) void {
    const corner = @max(@as(i32, @intFromFloat(@round(12.0 * win.scale))), 4); // 6px radius
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;

    // Clip the content to the rounded shape (+1: region right/bottom are
    // exclusive).
    const rgn = w32.CreateRoundRectRgn(rect.left, rect.top, rect.right + 1, rect.bottom + 1, corner, corner);
    if (rgn) |r| _ = w32.SelectClipRgn(dc, r);

    // Placeholder under (or instead of) the snapshot: near-black.
    if (w32.CreateSolidBrush(w32.RGB(16, 16, 16))) |brush| {
        var rr = rect;
        _ = w32.FillRect(dc, &rr, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // Snapshot, dimmed unless selected (Mac alpha 1.0 / 0.35; hover 0.6
    // lands in T59b). AlphaBlend also stretches on transient size
    // mismatches right after a resize.
    if (surface.snap_dib) |dib| blit: {
        const src_dc = w32.CreateCompatibleDC(dc) orelse break :blit;
        defer _ = w32.DeleteDC(src_dc);
        const old = w32.SelectObject(src_dc, dib);
        defer _ = w32.SelectObject(src_dc, old);
        const bf: w32.BLENDFUNCTION = .{
            .SourceConstantAlpha = if (selected) 255 else 89,
            // The GL readback's alpha channel is not meaningful — blend
            // with the constant alpha only.
            .AlphaFormat = 0,
        };
        _ = w32.AlphaBlend(
            dc,
            rect.left,
            rect.top,
            w,
            h,
            src_dc,
            0,
            0,
            surface.snap_dib_w,
            surface.snap_dib_h,
            bf,
        );
    }

    // Border on top of the content, outside the clip so the full stroke
    // width lands. Selected: 2px accent blue (Mac 0.416,0.416,1.0).
    // Normal: 1px dim gray (Mac white 0.5 @ 0.3).
    if (rgn) |r| {
        _ = w32.SelectClipRgn(dc, null);
        _ = w32.DeleteObject(r);
    }
    const border_w: i32 = if (selected)
        @max(@as(i32, @intFromFloat(@round(2.0 * win.scale))), 2)
    else
        @max(@as(i32, @intFromFloat(@round(1.0 * win.scale))), 1);
    const border_color = if (selected) w32.RGB(106, 106, 255) else w32.RGB(110, 110, 110);
    const pen = w32.CreatePen(0, border_w, border_color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_pen = w32.SelectObject(dc, pen);
    defer _ = w32.SelectObject(dc, old_pen);
    const old_brush = w32.SelectObject(dc, w32.GetStockObject(w32.NULL_BRUSH));
    defer _ = w32.SelectObject(dc, old_brush);
    _ = w32.RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, corner, corner);
}
