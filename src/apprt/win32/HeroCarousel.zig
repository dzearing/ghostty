//! Owner-painted hero-mode carousel column (T58 design; T59a static
//! pass, T59b interactions/motion).
//!
//! The carousel lives in the parent Window's client area — there are NO
//! child HWNDs per tile. Tiles show snapshot DIBs captured by each pane's
//! renderer thread (Surface.heroSnap*). This module is geometry + GDI
//! painting + hit-testing only; all state lives on Window (per-tab hero
//! arrays + transient hover/drag/animation) and Surface (DIB cache).
//! Pure math is in hero_math.zig.
const std = @import("std");

const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");
const hero_math = @import("hero_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const color_math = @import("color_math.zig");
const system_colors = @import("system_colors.zig");

const log = std.log.scoped(.win32);

/// The band's own backdrop: the window background darkened ~30% toward black
/// (Mac: black @ 0.3 alpha over the window background). Derived once here
/// because it is BOTH what the band is filled with and the surface the accent
/// below has to read against — two call sites deriving it separately is how
/// the strip's `background + 20` ended up in two files.
fn bandBackdrop(win: *Window) color_math.Rgb {
    const bg = win.app.config.background;
    return .{
        .r = @intCast((@as(u16, bg.r) * 7) / 10),
        .g = @intCast((@as(u16, bg.g) * 7) / 10),
        .b = @intCast((@as(u16, bg.b) * 7) / 10),
    };
}

/// The carousel's two accent states (T305). They used to be the literals
/// `RGB(106,106,255)` and `RGB(139,92,246)` — a blue and a purple that were
/// neither the user's accent nor each other, ported as raw numbers off Mac's
/// `Color(0.416,0.416,1.0)` / `Color(0.545,0.361,0.965)`.
///
///   - `on`   — selected, and the hovered/dragged divider: the accent itself,
///              floored to 3:1 against the band so a dark accent still reads.
///   - `soft` — a hovered tile: the same accent stepped toward the band, so
///              hover reads as "this could become the selection" instead of as
///              an unrelated second hue.
const BandAccent = struct { on: color_math.Rgb, soft: color_math.Rgb };

fn bandAccent(win: *Window) BandAccent {
    const back = bandBackdrop(win);
    const on = chrome_theme.accentOn(back, system_colors.accentCached());
    // Toward the band, then floored again: a hover that stepped back so far it
    // stopped reading against the backdrop would be a hover nobody sees, which
    // is the failure the 3:1 floor exists for.
    return .{ .on = on, .soft = chrome_theme.accentOn(back, color_math.mix(on, back, 0.35)) };
}

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
    // Strip position = centered selected tile + wheel scroll (clamped at
    // read time so layout/tree changes self-heal a stale offset) + the
    // decaying re-center animation offset.
    const scroll = hero_math.clampScroll(
        win.tab_hero_scroll[tab],
        split.carousel,
        layout,
        count,
    ) + win.heroRecenterOffset();
    const top0 = hero_math.stripTop(split.carousel, layout, selected, scroll);
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
    const back = bandBackdrop(win);
    const bg_color = w32.RGB(back.r, back.g, back.b);
    var full: w32.RECT = .{ .left = 0, .top = 0, .right = rw, .bottom = rh };
    if (w32.CreateSolidBrush(bg_color)) |brush| {
        _ = w32.FillRect(mem_dc, &full, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // Divider: thin vertical line centered in the band; gray normally,
    // accent while hovered or dragged (Mac: blue while hovered/dragged).
    const line_w = @max(@as(i32, @intFromFloat(@round(1.0 * win.scale))), 1);
    const band_w = geo.split.divider.width();
    var line: w32.RECT = .{
        .left = @divTrunc(band_w - line_w, 2),
        .top = 0,
        .right = @divTrunc(band_w - line_w, 2) + line_w,
        .bottom = rh,
    };
    const div_accent = bandAccent(win).on;
    const div_color = if (win.hero_divider_hover or win.hero_divider_drag)
        w32.RGB(div_accent.r, div_accent.g, div_accent.b)
    else
        w32.RGB(96, 96, 96);
    if (w32.CreateSolidBrush(div_color)) |brush| {
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
        const hovered = win.hero_hover_tile >= 0 and
            @as(usize, @intCast(win.hero_hover_tile)) == i;
        // Hero tiles are renderer snapshots, so only terminal panes have
        // one to paint (T90a S15: viewers are excluded from hero mode).
        const surface = entry.view.surface() orelse continue;
        paintTile(win, mem_dc, surface, local, i == geo.selected, hovered);
    }

    _ = w32.BitBlt(hdc_screen, region.left, region.top, rw, rh, mem_dc, 0, 0, w32.SRCCOPY);
}

/// One thumbnail tile: rounded-clipped snapshot (dimmed unless selected,
/// half-dimmed while hovered) + rounded border. Mac chrome parity minus
/// the glow shadow (GDI has no cheap soft shadow — deliberate
/// simplification, T58 decision 3).
fn paintTile(
    win: *Window,
    dc: w32.HDC,
    surface: *Surface,
    rect: w32.RECT,
    selected: bool,
    hovered: bool,
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

    // Snapshot, dimmed unless selected (Mac alpha 1.0 selected / 0.6
    // hovered / 0.35 normal). AlphaBlend also stretches on transient
    // size mismatches right after a resize.
    if (surface.snap_dib) |dib| blit: {
        const src_dc = w32.CreateCompatibleDC(dc) orelse break :blit;
        defer _ = w32.DeleteDC(src_dc);
        const old = w32.SelectObject(src_dc, dib);
        defer _ = w32.SelectObject(src_dc, old);
        const bf: w32.BLENDFUNCTION = .{
            .SourceConstantAlpha = if (selected) 255 else if (hovered) 153 else 89,
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
    // width lands. Selected: 2px in the user's accent. Hovered: 1px in a
    // softer step of the same accent — Mac paints a second hue here
    // (0.416,0.416,1.0 vs 0.545,0.361,0.965), which was ported as two raw
    // literals and read as an unrelated purple once the accent stopped being
    // blue (T305). Normal: 1px dim gray (Mac white 0.5 @ 0.3).
    if (rgn) |r| {
        _ = w32.SelectClipRgn(dc, null);
        _ = w32.DeleteObject(r);
    }
    const border_w: i32 = if (selected)
        @max(@as(i32, @intFromFloat(@round(2.0 * win.scale))), 2)
    else
        @max(@as(i32, @intFromFloat(@round(1.0 * win.scale))), 1);
    const ba = bandAccent(win);
    const border_color = if (selected)
        w32.RGB(ba.on.r, ba.on.g, ba.on.b)
    else if (hovered)
        w32.RGB(ba.soft.r, ba.soft.g, ba.soft.b)
    else
        w32.RGB(110, 110, 110);
    const pen = w32.CreatePen(0, border_w, border_color) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_pen = w32.SelectObject(dc, pen);
    defer _ = w32.SelectObject(dc, old_pen);
    const old_brush = w32.SelectObject(dc, w32.GetStockObject(w32.NULL_BRUSH));
    defer _ = w32.SelectObject(dc, old_brush);
    _ = w32.RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, corner, corner);
}

/// Owner-paint the hero region during a selection slide (T58 decision 5):
/// every hero HWND is hidden; the outgoing and incoming SNAPSHOTS slide
/// vertically by one strip slot (hero height + 40px·scale gap, Mac
/// parity) in the selection direction. Double-buffered; snapshots are
/// HALFTONE-stretched from thumbnail size — content freezes for ≤350ms,
/// which reads like the Mac's live slide.
pub fn paintSlide(win: *Window, hdc_screen: w32.HDC) void {
    const slide = win.hero_slide orelse return;
    const tab = win.active_tab;
    if (!win.tab_hero_active[tab]) return;

    const split = splitRects(win, win.surfaceRect());
    const hero = split.hero;
    const w = hero.width();
    const h = hero.height();
    if (w <= 0 or h <= 0) return;

    // Eased progress; a finished slide paints its end state (the next
    // anim tick shows the real pane and clears the state).
    const p = Window.heroAnimProgress(slide.start, Window.HERO_SLIDE_MS) orelse 1.0;

    const mem_dc = w32.CreateCompatibleDC(hdc_screen) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const mem_bmp = w32.CreateCompatibleBitmap(hdc_screen, w, h) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, mem_bmp);
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(mem_bmp);
    }

    // Background fill (visible in the inter-slot gap mid-slide).
    const bg = win.app.config.background;
    var full: w32.RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    if (w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b))) |brush| {
        _ = w32.FillRect(mem_dc, &full, brush);
        _ = w32.DeleteObject(@ptrCast(brush));
    }

    // Strip slot distance: hero height + 40px (scaled) gap, Mac parity.
    // Selecting a later leaf moves the strip UP (content slides up).
    const gap: i32 = @intFromFloat(@round(40.0 * win.scale));
    const distance = h + gap;
    const dir: i32 = if (slide.to_index > slide.from_index) 1 else -1;
    const shift: i32 = @intFromFloat(@round(p * @as(f32, @floatFromInt(distance))));
    const out_y = -dir * shift;
    const in_y = dir * (distance - shift);

    _ = w32.SetStretchBltMode(mem_dc, w32.HALFTONE);
    _ = w32.SetBrushOrgEx(mem_dc, 0, 0, null);
    paintSlideSnap(win, mem_dc, tab, slide.from_index, out_y, w, h);
    paintSlideSnap(win, mem_dc, tab, slide.to_index, in_y, w, h);

    _ = w32.BitBlt(hdc_screen, hero.left, hero.top, w, h, mem_dc, 0, 0, w32.SRCCOPY);
}

/// One hero-sized snapshot at vertical offset `y` inside the slide's
/// memory DC. A leaf without a snapshot paints nothing (bg shows).
fn paintSlideSnap(
    win: *Window,
    dc: w32.HDC,
    tab: usize,
    index: usize,
    y: i32,
    w: i32,
    h: i32,
) void {
    if (y >= h or y + h <= 0) return;
    const pane = win.leafAt(tab, index) orelse return;
    const view = pane.surface() orelse return;
    const dib = view.snap_dib orelse return;
    if (view.snap_dib_w <= 0 or view.snap_dib_h <= 0) return;
    const src_dc = w32.CreateCompatibleDC(dc) orelse return;
    defer _ = w32.DeleteDC(src_dc);
    const old = w32.SelectObject(src_dc, dib);
    defer _ = w32.SelectObject(src_dc, old);
    _ = w32.StretchBlt(
        dc,
        0,
        y,
        w,
        h,
        src_dc,
        0,
        0,
        view.snap_dib_w,
        view.snap_dib_h,
        w32.SRCCOPY,
    );
}
