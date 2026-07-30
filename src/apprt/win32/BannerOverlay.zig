//! Sticky pane-banner overlay (T35/T91). Windows analog of the Mac
//! `SurfacePaneBanner`: a card rendered above the terminal content of a
//! pane that persists (survives scrolling, screen clears, content updates)
//! until changed or cleared.
//!
//! Like DimOverlay/Scrollbar, the banner is a WS_EX_LAYERED popup owned by
//! its surface HWND — DWM composites it above the surface's OpenGL
//! content, which a plain child window cannot reliably do. Unlike the dim
//! overlay it is NOT click-through: `[text](url)` links are clickable
//! (hand cursor + ShellExecuteW), a multi-line banner collapses/expands on
//! click, and a click on a single-line banner focuses the pane underneath.
//!
//! The window covers the band the layout reserves above the terminal
//! (T101) and is fully OPAQUE (T131): it paints the pane background, then
//! the floating glass card inside it (`banner_card.zig`, the port of Mac's
//! `GlassCardBackground`). It used to be a translucent full-width strip,
//! which let the stale terminal pixels behind the band show through — that
//! see-through is what read as "text scrolling behind the banner".
//!
//! Content comes from the pure banner_markdown block parser (unit tested
//! in every lane): text lines, headings, thematic-break rules, lists with
//! a shared marker gutter (bullets / ordered numbers / native checkbox
//! boxes), and pipe tables with bold-measured column widths, `:` alignment
//! and long-cell word wrap. This file owns only the windowing, GDI
//! measurement, and painting.

const std = @import("std");
const w32 = @import("win32.zig");
const App = @import("App.zig");
const markdown = @import("banner_markdown.zig");
const card = @import("banner_card.zig");
const banner_layout = @import("banner_layout.zig");
const color_math = @import("color_math.zig");

const log = std.log.scoped(.win32_banner);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyBannerOverlay");

/// Window opacity (LWA_ALPHA). FULLY opaque (T131): the card's own
/// translucency is composited against the pane background in
/// `banner_card.render`, so nothing behind the window can bleed through.
/// A window-wide alpha let stale terminal pixels in the reserved band show
/// through the banner — the user-visible "text scrolling behind" bug. The
/// window stays WS_EX_LAYERED because that is what puts it above the
/// surface's OpenGL content.
const STRIP_ALPHA: u8 = 255;

/// Margin between the card and the band edges (Mac `GlassCard.outerMargin`).
const MARGIN: f32 = card.MARGIN;

/// Unscaled layout metrics. The Mac banner is a 12pt system font with
/// 12pt padding; our base font is 15px (T35), so px metrics scale by
/// 15/12 where they mirror a Mac point value.
const PAD: f32 = card.PADDING;
const FONT_H: f32 = 15.0;
const LINE_H: f32 = 20.0;
/// Vertical gap between blocks (Mac: VStack spacing 8).
const BLOCK_GAP: f32 = 8.0;
/// Vertical gap between list rows / table rows (Mac: Grid spacing 4).
const ROW_GAP: f32 = 4.0;
/// Gap between a list marker gutter and item content (Mac: 6).
const GUTTER_GAP: f32 = 6.0;
/// Horizontal gap between table columns (Mac: 18).
const COL_GAP: f32 = 18.0;
/// Native checkbox side (Mac: 12 at 12pt → 15 at our 15px base).
const CHECK_SIDE: f32 = 15.0;
/// Tail-truncation glyph for a cell that runs past `MAX_CELL_LINES`.
const ELLIPSIS = "…";
/// Negative-control switch (kept, deliberately): true restores the
/// pre-T123 table sizing — the fixed 360pt cap, no mid-string break, no
/// 3-line cell cap. Flipping it and re-running `pane-banner.ps1` must fail
/// exactly the 6 section-6g assertions and nothing else; that is how those
/// assertions were shown to test the fix rather than the harness.
const T123_NEUTERED = false;
/// Collapsed content height: first line fully visible plus a sliver that
/// fades out (Mac: 24 at 12pt → 30 at 15px).
const COLLAPSED_H: f32 = 30.0;
/// Chevron toggle glyph half-width / height.
const CHEV_W: f32 = 5.0;
const CHEV_H: f32 = 3.5;

/// Heading text px per level (Mac: 17/16/15/14/13/12pt over a 12pt base,
/// scaled by 15/12).
const heading_px = [6]f32{ 21.25, 20.0, 18.75, 17.5, 16.25, 15.0 };
/// Number of cached font size classes: base + 6 heading levels.
const size_classes = 7;

/// The task-list checkbox green (Apple systemGreen, what the Mac's
/// `Color.green` resolves near).
const GREEN = color_math.Rgb{ .r = 52, .g = 199, .b = 89 };

pub const BannerOverlay = struct {
    alloc: std.mem.Allocator,
    /// The surface HWND this banner sits on top of (popup owner).
    owner: w32.HWND,
    hwnd: w32.HWND,
    /// Arena holding the parsed blocks and their text (reset per setText).
    arena: std.heap.ArenaAllocator,
    blocks: []const markdown.Block = &.{},

    /// Multi-line banners collapse/expand on click (Mac chevron parity).
    collapsible: bool = false,
    collapsed: bool = false,
    /// Expanded content height in px (excludes padding), lazily computed;
    /// -1 means stale (recompute on next use).
    content_h: i32 = -1,

    /// Height the window layout reserved for this strip ABOVE the owner
    /// pane (T101). The layout shrinks/offsets the owner HWND by this and
    /// `updatePosition` glues the strip into the vacated band, so the
    /// terminal grid starts below the banner instead of under it. 0 until
    /// a layout pass ran (then the strip falls back to overlapping the
    /// owner top so it is never lost).
    inset: i32 = 0,

    /// Width of the pane slot the banner spans, fed TOP-DOWN by the window
    /// layout (T123). Table columns are sized from it, so the banner
    /// reflows live with the pane and can never act as a minimum pane
    /// width. 0 until a layout pass ran — then column sizing falls back to
    /// the old fixed cap so the first paint is never absurdly wide.
    pane_w: i32 = 0,

    scale: f32 = 1.0,
    bg: u32 = 0, // COLORREF card fill
    bg_rgb: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    /// The pane's own background — what the band around the card shows,
    /// and the backdrop the card's wash is composited over (T131).
    pane_bg_rgb: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    fg: u32 = 0xFFFFFF,
    fg_rgb: color_math.Rgb = .{ .r = 255, .g = 255, .b = 255 },
    link_fg: u32 = 0xFF9C4F, // COLORREF is 0x00BBGGRR
    divider: u32 = 0,
    bg_brush: ?w32.HBRUSH = null,
    alpha_set: bool = false,

    /// Cached card backdrop (T131): the band background + elevation shadow
    /// + card fill/sheen/rim, rendered by `banner_card` into a DIB section
    /// and blitted under the text. Regenerated only when the band size, the
    /// pane background, or the DPI scale changes — a banner repaint (hover,
    /// collapse, content update) reuses it.
    card_dc: ?w32.HDC = null,
    card_bmp: ?*anyopaque = null,
    card_bits: ?[*]u32 = null,
    card_w: i32 = 0,
    card_h: i32 = 0,
    card_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
    card_scale: f32 = 0,

    /// Lazy font cache: size class (0 base, 1–6 headings) × style bits
    /// (bold | italic<<1 | ul<<2 | code<<3).
    fonts: [size_classes * 16]?*anyopaque = @splat(null),

    /// Link hit rects, rebuilt on every paint (client coordinates).
    links: std.ArrayList(LinkRect) = .empty,

    const LinkRect = struct {
        rect: w32.RECT,
        /// Arena-owned (lives until the next setText).
        url: []const u8,
    };

    pub fn create(
        alloc: std.mem.Allocator,
        owner: w32.HWND,
        hinstance: w32.HINSTANCE,
    ) !*BannerOverlay {
        try registerClassOnce(hinstance);

        const self = try alloc.create(BannerOverlay);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .owner = owner,
            .hwnd = undefined,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };

        // WS_EX_LAYERED — DWM-composited above OpenGL content.
        // WS_EX_NOACTIVATE — clicks never move activation to the popup.
        // WS_EX_TOOLWINDOW — out of the taskbar / Alt-Tab list.
        // Deliberately not WS_EX_TRANSPARENT: links/collapse are clickable.
        const ex_style: u32 = w32.WS_EX_LAYERED | w32.WS_EX_NOACTIVATE |
            w32.WS_EX_TOOLWINDOW;

        const hwnd = w32.CreateWindowExW(
            ex_style,
            WINDOW_CLASS_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP,
            0,
            0,
            1,
            1, // placeholder — updatePosition glues to the owner
            owner,
            null,
            hinstance,
            null,
        ) orelse return error.Win32Error;

        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *BannerOverlay) void {
        _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(self.hwnd);
        self.clearFonts();
        self.releaseCardSurface();
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.links.deinit(self.alloc);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    /// Replace the banner source text (raw markdown) and repaint. The
    /// caller keeps ownership of `text`; empty text is the caller's cue to
    /// destroy/hide instead — here it just paints an empty strip.
    pub fn setText(self: *BannerOverlay, text: []const u8) void {
        _ = self.arena.reset(.retain_capacity);
        self.links.clearRetainingCapacity();
        self.blocks = markdown.parseBlocks(self.arena.allocator(), text) catch &.{};
        self.collapsible = std.mem.indexOfScalar(u8, text, '\n') != null;
        if (!self.collapsible) self.collapsed = false;
        self.content_h = -1;
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Refresh card colors from the pane's effective background (per-pane
    /// tint or config background) and the config foreground. The fill is
    /// Mac's glass wash — `lighten(0.06)` on a dark pane, `darken(0.04)` on
    /// a light one (T131) — composited, not translucent.
    pub fn setColors(self: *BannerOverlay, pane_bg: color_math.Rgb, fg: color_math.Rgb) void {
        const light = color_math.isLight(pane_bg);
        const strip = card.fillColor(pane_bg);
        // The band around the card is the pane's own background, so a pane
        // background change repaints even when the card fill rounds to the
        // same value.
        const bg_changed = !std.meta.eql(self.pane_bg_rgb, pane_bg);
        self.pane_bg_rgb = pane_bg;
        const div = if (light)
            color_math.darken(pane_bg, 0.25)
        else
            color_math.lighten(pane_bg, 0.25);
        const bg_ref = w32.RGB(strip.r, strip.g, strip.b);
        const fg_ref = w32.RGB(fg.r, fg.g, fg.b);
        const link_ref: u32 = if (light) w32.RGB(0, 102, 204) else w32.RGB(90, 160, 255);
        const div_ref = w32.RGB(div.r, div.g, div.b);
        if (!bg_changed and bg_ref == self.bg and fg_ref == self.fg and
            link_ref == self.link_fg and div_ref == self.divider and
            self.bg_brush != null) return;
        self.bg = bg_ref;
        self.bg_rgb = strip;
        self.fg = fg_ref;
        self.fg_rgb = fg;
        self.link_fg = link_ref;
        self.divider = div_ref;
        if (self.bg_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
        self.bg_brush = w32.CreateSolidBrush(bg_ref);
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    /// Glue the strip into the band the window layout reserved above the
    /// owner pane (T101; screen coordinates). Hides when the owner is not
    /// visible (hidden split, other tab, hero carousel). Idempotent —
    /// doubles as the reposition call.
    pub fn updatePosition(self: *BannerOverlay, scale: f32) void {
        if (w32.IsWindowVisible_(self.owner) == 0) {
            self.hide();
            return;
        }
        if (!self.alpha_set) {
            _ = w32.SetLayeredWindowAttributes(self.hwnd, 0, STRIP_ALPHA, w32.LWA_ALPHA);
            self.alpha_set = true;
        }
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(self.owner, &rect) == 0) return;
        // The owner spans the pane slot's full width (the layout only ever
        // offsets its TOP by the band), so its rect is the pane width the
        // banner content must size itself to (T123).
        const strip = self.insetHeight(scale, rect.right - rect.left);
        // `inset` > 0: the layout moved the owner down by that much; the
        // strip fills the vacated band exactly (bottom-clipped when the
        // clamp engaged in a degenerate short pane). `inset` == 0: no
        // layout pass ran yet — fall back to overlapping the owner top so
        // the strip is never lost.
        const height = if (self.inset > 0) @min(self.inset, strip) else strip;
        const top = rect.top - @max(self.inset, 0);
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            rect.left,
            top,
            @max(rect.right - rect.left, 1),
            @max(height, 1),
            w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW,
        );
        // Every reposition re-checks the z-order instead of leaving it to
        // whatever last touched it (T142).
        w32.healOverlayZOrder(self.hwnd, self.owner);
    }

    /// The strip's natural height at `scale` in a `pane_w`-wide pane slot,
    /// for the window layout to reserve above the owner pane (T101). Syncs
    /// the overlay's scale and pane width first, so a DPI change measures
    /// with the right fonts and a resize re-measures at the width the
    /// content will actually be painted into (T123 — a table that rewraps
    /// narrower gets a taller band, and one that unwraps gets a shorter
    /// one, instead of the band and the paint disagreeing).
    pub fn insetHeight(self: *BannerOverlay, scale: f32, pane_w: i32) i32 {
        if (scale != self.scale) {
            self.scale = scale;
            self.clearFonts();
            self.content_h = -1;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        const w = @max(pane_w, 0);
        if (w != self.pane_w) {
            self.pane_w = w;
            self.content_h = -1;
            _ = w32.InvalidateRect(self.hwnd, null, 1);
        }
        return self.stripHeight();
    }

    pub fn hide(self: *BannerOverlay) void {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    }

    /// Total band height: the floating card (padding + content) plus the
    /// margin it leaves on the top AND bottom, so the terminal content
    /// below always starts a breath under the card (Mac parity — its
    /// bottom margin is part of the measured banner height too).
    fn stripHeight(self: *BannerOverlay) i32 {
        return banner_layout.bandHeight(
            self.cardHeight(),
            self.px(MARGIN),
        );
    }

    /// Height of the card itself: uniform inner padding around the content.
    fn cardHeight(self: *BannerOverlay) i32 {
        const content = if (self.collapsed)
            self.px(COLLAPSED_H)
        else
            self.ensureContentHeight();
        return self.px(PAD) * 2 + content;
    }

    /// Width available to the content INSIDE the card: the pane slot less
    /// the card's margin and padding on both sides. 0 while the pane width
    /// is still unknown, which is the signal for the fixed-cap fallback.
    fn contentWidth(self: *const BannerOverlay) i32 {
        if (self.pane_w <= 0) return 0;
        const inner = self.px(MARGIN) + self.px(PAD);
        return @max(self.pane_w - inner * 2, 1);
    }

    /// Expanded content height, measured via a window DC when stale. The
    /// measure runs at the SAME content width the paint will use, so the
    /// reserved band always matches what gets drawn into it (T123).
    fn ensureContentHeight(self: *BannerOverlay) i32 {
        if (self.content_h >= 0) return self.content_h;
        const hdc = w32.GetDC(self.hwnd) orelse {
            return self.px(LINE_H); // degrade: one-line strip
        };
        defer _ = w32.ReleaseDC(self.hwnd, hdc);
        self.content_h = self.renderContent(hdc, 0, 0, self.contentWidth(), false);
        return self.content_h;
    }

    fn px(self: *const BannerOverlay, v: f32) i32 {
        return @intFromFloat(@round(v * self.scale));
    }

    fn clearFonts(self: *BannerOverlay) void {
        for (&self.fonts) |*f| {
            if (f.*) |font| _ = w32.DeleteObject(font);
            f.* = null;
        }
    }

    /// Font for a style at a size class (0 = base text, 1–6 = heading
    /// levels). Headings render semibold (Mac parity), so class > 0
    /// forces bold.
    fn fontFor(self: *BannerOverlay, style: markdown.Style, size_class: usize) ?*anyopaque {
        const bold = style.bold or size_class > 0;
        const bits: usize = @as(usize, @intFromBool(bold)) |
            (@as(usize, @intFromBool(style.italic)) << 1) |
            (@as(usize, @intFromBool(style.underline)) << 2) |
            (@as(usize, @intFromBool(style.code)) << 3);
        const idx = size_class * 16 + bits;
        if (self.fonts[idx]) |f| return f;
        const face = if (style.code)
            std.unicode.utf8ToUtf16LeStringLiteral("Consolas")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        const height = if (size_class == 0) FONT_H else heading_px[size_class - 1];
        self.fonts[idx] = w32.CreateFontW(
            -self.px(height),
            0,
            0,
            0,
            if (bold) 700 else 400,
            @intFromBool(style.italic),
            @intFromBool(style.underline),
            0,
            w32.DEFAULT_CHARSET,
            0,
            0,
            0,
            0,
            face,
        );
        return self.fonts[idx];
    }

    /// Blend `c` toward the strip background by `1 - t` (t = opacity of c
    /// over the strip), the GDI stand-in for Mac's alpha-composited marks.
    fn overStrip(self: *const BannerOverlay, c: color_math.Rgb, t: f32) u32 {
        const blend = struct {
            fn ch(a: u8, b: u8, tt: f32) u8 {
                const v = @as(f32, @floatFromInt(b)) * (1.0 - tt) +
                    @as(f32, @floatFromInt(a)) * tt;
                return @intFromFloat(@max(0.0, @min(255.0, @round(v))));
            }
        };
        return w32.RGB(
            blend.ch(c.r, self.bg_rgb.r, t),
            blend.ch(c.g, self.bg_rgb.g, t),
            blend.ch(c.b, self.bg_rgb.b, t),
        );
    }

    /// Secondary text/marker color (Mac `.secondary`): fg at ~55% over bg.
    fn secondary(self: *const BannerOverlay) u32 {
        return self.overStrip(self.fg_rgb, 0.55);
    }

    // -----------------------------------------------------------------
    // Measure + draw walker. One code path computes geometry for both the
    // measuring pass (draw=false → returns content height) and painting
    // (draw=true → also fills link rects), so height and pixels can't
    // drift apart.
    // -----------------------------------------------------------------

    fn measureSeg(self: *BannerOverlay, hdc: w32.HDC, text: []const u8, style: markdown.Style, size_class: usize, force_bold: bool) w32.SIZE {
        var s = style;
        if (force_bold) s.bold = true;
        var wbuf: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return .{ .cx = 0, .cy = 0 };
        if (wlen == 0) return .{ .cx = 0, .cy = 0 };
        const font = self.fontFor(s, size_class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        return size;
    }

    fn drawSegText(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x: i32,
        y: i32,
        line_h: i32,
        text: []const u8,
        style: markdown.Style,
        link: ?[]const u8,
        size_class: usize,
        force_bold: bool,
        draw: bool,
    ) i32 {
        var s = style;
        if (force_bold) s.bold = true;
        var wbuf: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
        if (wlen == 0) return 0;
        const font = self.fontFor(s, size_class);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        if (draw) {
            const ty = y + @divTrunc(line_h - size.cy, 2);
            _ = w32.SetTextColor(hdc, if (link != null) self.link_fg else self.fg);
            _ = w32.TextOutW(hdc, x, ty, &wbuf, @intCast(wlen));
            if (link) |url| {
                self.links.append(self.alloc, .{
                    .rect = .{ .left = x, .top = y, .right = x + size.cx, .bottom = y + line_h },
                    .url = url,
                }) catch {};
            }
        }
        return size.cx;
    }

    /// Draw a native task-list checkbox centered on the line; returns its
    /// advance width.
    fn drawCheckbox(self: *BannerOverlay, hdc: w32.HDC, x: i32, y: i32, line_h: i32, checked: bool, draw: bool) i32 {
        const side = self.px(CHECK_SIDE);
        if (!draw) return side;
        const top = y + @divTrunc(line_h - side, 2);
        const radius = self.px(3.0);

        const fill_ref = if (checked) self.overStrip(GREEN, 0.16) else self.bg;
        const border_ref = if (checked)
            self.overStrip(GREEN, 0.55)
        else
            self.overStrip(self.fg_rgb, 0.55);

        const fill = w32.CreateSolidBrush(fill_ref);
        const pen = w32.CreatePen(0, 1, border_ref); // PS_SOLID
        if (fill != null and pen != null) {
            const prev_brush = w32.SelectObject(hdc, @ptrCast(fill.?));
            const prev_pen = w32.SelectObject(hdc, pen.?);
            _ = w32.RoundRect(hdc, x, top, x + side, top + side, radius, radius);
            _ = w32.SelectObject(hdc, prev_pen);
            _ = w32.SelectObject(hdc, prev_brush);
        }
        if (fill) |b| _ = w32.DeleteObject(@ptrCast(b));
        if (pen) |p| _ = w32.DeleteObject(p);

        if (checked) {
            const check_pen = w32.CreatePen(0, @max(1, self.px(1.6)), w32.RGB(GREEN.r, GREEN.g, GREEN.b));
            if (check_pen) |p| {
                const prev_pen = w32.SelectObject(hdc, p);
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(top);
                const fs: f32 = @floatFromInt(side);
                _ = w32.MoveToEx(hdc, @intFromFloat(fx + fs * 0.26), @intFromFloat(fy + fs * 0.54), null);
                _ = w32.LineTo(hdc, @intFromFloat(fx + fs * 0.44), @intFromFloat(fy + fs * 0.72));
                _ = w32.LineTo(hdc, @intFromFloat(fx + fs * 0.76), @intFromFloat(fy + fs * 0.30));
                _ = w32.SelectObject(hdc, prev_pen);
                _ = w32.DeleteObject(p);
            }
        }
        return side;
    }

    /// Lay out one single-display-line run of inline content at (x, y);
    /// returns the total advance width.
    fn drawInlineLine(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x0: i32,
        y: i32,
        line_h: i32,
        segs: []const markdown.Inline,
        size_class: usize,
        force_bold: bool,
        draw: bool,
    ) i32 {
        var x = x0;
        for (segs) |inl| switch (inl) {
            .seg => |s| x += self.drawSegText(hdc, x, y, line_h, s.text, s.style, s.link, size_class, force_bold, draw),
            .checkbox => |checked| x += self.drawCheckbox(hdc, x, y, line_h, checked, draw),
        };
        return x - x0;
    }

    fn hasCheckbox(segs: []const markdown.Inline) bool {
        for (segs) |inl| if (inl == .checkbox) return true;
        return false;
    }

    /// A word/space token of a wrapping table cell.
    const Token = struct {
        text: []const u8 = "", // empty for a checkbox token
        style: markdown.Style = .{},
        link: ?[]const u8 = null,
        checkbox: ?bool = null,
        is_space: bool = false,
        width: f32 = 0,
    };

    /// Split cell segs into word/space tokens with measured widths.
    fn tokenizeCell(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        segs: []const markdown.Inline,
        force_bold: bool,
    ) std.mem.Allocator.Error![]Token {
        var out: std.ArrayList(Token) = .empty;
        for (segs) |inl| switch (inl) {
            .checkbox => |checked| try out.append(arena, .{
                .checkbox = checked,
                .width = @floatFromInt(self.px(CHECK_SIDE)),
            }),
            .seg => |s| {
                var i: usize = 0;
                while (i < s.text.len) {
                    const is_space = s.text[i] == ' ';
                    var j = i;
                    while (j < s.text.len and (s.text[j] == ' ') == is_space) j += 1;
                    const word = s.text[i..j];
                    const size = self.measureSeg(hdc, word, s.style, 0, force_bold);
                    try out.append(arena, .{
                        .text = word,
                        .style = s.style,
                        .link = s.link,
                        .is_space = is_space,
                        .width = @floatFromInt(size.cx),
                    });
                    i = j;
                }
            },
        };
        return out.items;
    }

    /// Natural (single-line) width of a cell's inline content.
    fn cellNaturalWidth(self: *BannerOverlay, hdc: w32.HDC, segs: []const markdown.Inline, force_bold: bool) i32 {
        var total: i32 = 0;
        for (segs) |inl| switch (inl) {
            .seg => |s| total += self.measureSeg(hdc, s.text, s.style, 0, force_bold).cx,
            .checkbox => total += self.px(CHECK_SIDE),
        };
        return total;
    }

    /// Replace every non-space token wider than `max_w` with a run of
    /// sub-tokens that each fit, so a long unbroken string breaks
    /// mid-string instead of overflowing its column (T123 / CLAUDE.md:
    /// "even a long unbroken token breaks mid-string"). Returns `tokens`
    /// untouched — no allocation — when nothing is too wide, which is the
    /// overwhelmingly common case.
    fn breakWideTokens(
        self: *BannerOverlay,
        arena: std.mem.Allocator,
        hdc: w32.HDC,
        tokens: []const Token,
        max_w: i32,
    ) std.mem.Allocator.Error![]const Token {
        if (max_w <= 0) return tokens;
        const limit: f32 = @floatFromInt(max_w);
        const too_wide = struct {
            fn f(t: Token, lim: f32) bool {
                return t.checkbox == null and !t.is_space and t.width > lim;
            }
        }.f;
        var any = false;
        for (tokens) |t| {
            if (too_wide(t, limit)) {
                any = true;
                break;
            }
        }
        if (!any) return tokens;

        var out: std.ArrayList(Token) = .empty;
        for (tokens) |t| {
            if (!too_wide(t, limit)) {
                try out.append(arena, t);
                continue;
            }
            var rest = t.text;
            while (rest.len > 0) {
                const fit = self.prefixFitting(hdc, rest, t.style, max_w);
                // Always consume at least one codepoint: a column too
                // narrow for even a single glyph must still terminate.
                const take = if (fit > 0)
                    fit
                else
                    (std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
                const chunk = rest[0..@min(take, rest.len)];
                try out.append(arena, .{
                    .text = chunk,
                    .style = t.style,
                    .link = t.link,
                    .width = @floatFromInt(self.measureSeg(hdc, chunk, t.style, 0, false).cx),
                });
                rest = rest[chunk.len..];
            }
        }
        return out.items;
    }

    /// Byte length of the longest prefix of `text` that renders within
    /// `max_w` px in `style`. 0 when nothing fits (or on failure).
    fn prefixFitting(
        self: *BannerOverlay,
        hdc: w32.HDC,
        text: []const u8,
        style: markdown.Style,
        max_w: i32,
    ) usize {
        var wbuf: [1024]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
        if (wlen == 0) return 0;
        const font = self.fontFor(style, 0);
        const prev = w32.SelectObject(hdc, font);
        defer _ = w32.SelectObject(hdc, prev);
        var fit: i32 = 0;
        var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
        if (w32.GetTextExtentExPointW(hdc, &wbuf, @intCast(wlen), max_w, &fit, null, &size) == 0) return 0;
        if (fit <= 0) return 0;
        var units: usize = @min(@as(usize, @intCast(fit)), wlen);
        // Never break inside a surrogate pair.
        if (units > 0 and units < wlen and wbuf[units - 1] >= 0xD800 and wbuf[units - 1] <= 0xDBFF) units -= 1;
        return banner_layout.utf16PrefixBytes(text, units);
    }

    const CellLayout = struct {
        tokens: []const Token = &.{},
        lines: []markdown.WrapLine = &.{},
        /// Single-line fast path when the cell fits (or holds a checkbox).
        single: bool = true,
        /// The cell ran past MAX_CELL_LINES and its last visible line
        /// tail-truncates with an ellipsis.
        truncated: bool = false,
    };

    /// Height + draw of one table block in `avail_w` px of content width.
    /// Column widths come from the widest cell's natural width (+slack)
    /// with header cells measured bold — the Mac's exact scheme, so bold
    /// labels never force-wrap — divided against the PANE's width rather
    /// than a fixed cap (T123), so a wide pane is used and a narrow one
    /// rewraps instead of being blocked from shrinking.
    fn renderTable(self: *BannerOverlay, hdc: w32.HDC, table: markdown.Table, x0: i32, y0: i32, avail_w: i32, draw: bool) i32 {
        const columns = table.header.len;
        if (columns == 0) return 0;
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const arena = scratch.allocator();

        const line_h = self.px(LINE_H);
        const row_gap = self.px(ROW_GAP);
        const col_gap = self.px(COL_GAP);
        const slack = self.px(2.0);
        const show_header = table.hasVisibleHeader();

        const natural = arena.alloc(f32, columns) catch return 0;
        @memset(natural, 0);
        if (show_header) {
            for (table.header, 0..) |cell, col| {
                natural[col] = @max(natural[col], @as(f32, @floatFromInt(self.cellNaturalWidth(hdc, cell, true))));
            }
        }
        for (table.rows) |row| {
            for (row, 0..) |cell, col| {
                if (col >= columns) break;
                natural[col] = @max(natural[col], @as(f32, @floatFromInt(self.cellNaturalWidth(hdc, cell, false))));
            }
        }
        for (natural) |*n| n.* += @floatFromInt(slack);

        const shares = arena.alloc(f32, columns) catch return 0;
        banner_layout.columnWidths(
            natural,
            shares,
            if (T123_NEUTERED) 0 else @floatFromInt(@max(avail_w, 0)),
            @floatFromInt(col_gap),
        );
        const widths = arena.alloc(i32, columns) catch return 0;
        for (shares, 0..) |s, col| widths[col] = @max(1, @as(i32, @intFromFloat(@floor(s))));

        // Wrap layout per body cell (checkbox cells stay single-line).
        const layouts = arena.alloc(CellLayout, table.rows.len * columns) catch return 0;
        @memset(layouts, .{});
        for (table.rows, 0..) |row, r| {
            for (row, 0..) |cell, col| {
                if (col >= columns) break;
                const lay = &layouts[r * columns + col];
                if (hasCheckbox(cell)) continue;
                if (self.cellNaturalWidth(hdc, cell, false) <= widths[col]) continue;
                const raw = self.tokenizeCell(arena, hdc, cell, false) catch continue;
                const tokens = if (T123_NEUTERED) raw else self.breakWideTokens(arena, hdc, raw, widths[col]) catch continue;
                const tw = arena.alloc(f32, tokens.len) catch continue;
                const ts = arena.alloc(bool, tokens.len) catch continue;
                for (tokens, 0..) |t, ti| {
                    tw[ti] = t.width;
                    ts[ti] = t.is_space;
                }
                var lines = markdown.wrapTokens(arena, tw, ts, @floatFromInt(widths[col])) catch continue;
                // A cell is capped at MAX_CELL_LINES display lines; past
                // that the last visible line tail-truncates, so one nasty
                // cell can't blow up the banner height (Mac parity).
                const truncated = !T123_NEUTERED and lines.len > banner_layout.MAX_CELL_LINES;
                if (truncated) lines = lines[0..banner_layout.MAX_CELL_LINES];
                lay.* = .{
                    .tokens = tokens,
                    .lines = lines,
                    .single = false,
                    .truncated = truncated,
                };
            }
        }

        var y = y0;

        if (show_header) {
            for (table.header, 0..) |cell, col| {
                var cx = x0;
                for (widths[0..col]) |wd| cx += wd + col_gap;
                const cw = self.inlineLineWidth(hdc, cell, true);
                _ = self.drawInlineLine(hdc, alignedX(cx, widths[col], cw, table.alignments[col]), y, line_h, cell, 0, true, draw);
            }
            y += line_h + row_gap;
            // Divider spanning the table's content width.
            if (draw) {
                var tw: i32 = 0;
                for (widths, 0..) |wd, col| {
                    tw += wd;
                    if (col + 1 < columns) tw += col_gap;
                }
                self.drawHLine(hdc, x0, x0 + tw, y);
            }
            y += 1 + row_gap;
        }

        for (table.rows, 0..) |row, r| {
            var row_h: i32 = line_h;
            for (0..columns) |col| {
                const lay = layouts[r * columns + col];
                if (!lay.single) {
                    const n: i32 = @intCast(lay.lines.len);
                    row_h = @max(row_h, n * line_h);
                }
            }
            var cx = x0;
            for (0..columns) |col| {
                const cell: []const markdown.Inline = if (col < row.len) row[col] else &.{};
                const lay = layouts[r * columns + col];
                if (lay.single) {
                    const cw = self.inlineLineWidth(hdc, cell, false);
                    _ = self.drawInlineLine(hdc, alignedX(cx, widths[col], cw, table.alignments[col]), y, line_h, cell, 0, false, draw);
                } else {
                    for (lay.lines, 0..) |wl, li| {
                        var run = lay.tokens[wl.start..wl.end];
                        // Tail-truncate the last visible line of a capped
                        // cell: drop whatever no longer fits beside the
                        // ellipsis, then draw the ellipsis itself.
                        const ellipsis = lay.truncated and li + 1 == lay.lines.len;
                        var ell_w: i32 = 0;
                        if (ellipsis) {
                            ell_w = self.measureSeg(hdc, ELLIPSIS, .{}, 0, false).cx;
                            var tw2: []f32 = &.{};
                            if (arena.alloc(f32, run.len)) |buf| {
                                tw2 = buf;
                            } else |_| {}
                            if (tw2.len == run.len) {
                                for (run, 0..) |t, ti| tw2[ti] = t.width;
                                const keep = banner_layout.fitWithEllipsis(
                                    tw2,
                                    @floatFromInt(ell_w),
                                    @floatFromInt(widths[col]),
                                );
                                run = run[0..keep];
                                while (run.len > 0 and run[run.len - 1].is_space) run = run[0 .. run.len - 1];
                            }
                        }
                        var lw: f32 = @floatFromInt(ell_w);
                        for (run) |t| lw += t.width;
                        var tx = alignedX(cx, widths[col], @intFromFloat(@round(lw)), table.alignments[col]);
                        const ly = y + @as(i32, @intCast(li)) * line_h;
                        for (run) |t| {
                            if (t.checkbox) |checked| {
                                tx += self.drawCheckbox(hdc, tx, ly, line_h, checked, draw);
                            } else {
                                tx += self.drawSegText(hdc, tx, ly, line_h, t.text, t.style, t.link, 0, false, draw);
                            }
                        }
                        if (ellipsis) {
                            _ = self.drawSegText(hdc, tx, ly, line_h, ELLIPSIS, .{}, null, 0, false, draw);
                        }
                    }
                }
                cx += widths[col] + col_gap;
            }
            y += row_h;
            if (r + 1 < table.rows.len) y += row_gap;
        }

        return y - y0;
    }

    fn inlineLineWidth(self: *BannerOverlay, hdc: w32.HDC, segs: []const markdown.Inline, force_bold: bool) i32 {
        return self.cellNaturalWidth(hdc, segs, force_bold);
    }

    fn alignedX(x0: i32, col_w: i32, content_w: i32, alignment: ?markdown.ColumnAlignment) i32 {
        const a = alignment orelse .leading;
        return switch (a) {
            .leading => x0,
            .center => x0 + @max(0, @divTrunc(col_w - content_w, 2)),
            .trailing => x0 + @max(0, col_w - content_w),
        };
    }

    fn drawHLine(self: *BannerOverlay, hdc: w32.HDC, x1: i32, x2: i32, y: i32) void {
        const pen = w32.CreatePen(0, 1, self.divider); // PS_SOLID
        if (pen) |p| {
            const prev = w32.SelectObject(hdc, p);
            _ = w32.MoveToEx(hdc, x1, y, null);
            _ = w32.LineTo(hdc, x2, y);
            _ = w32.SelectObject(hdc, prev);
            _ = w32.DeleteObject(p);
        }
    }

    /// Height + draw of one list block: markers share a gutter sized to
    /// the widest marker so all item content left-aligns.
    fn renderList(self: *BannerOverlay, hdc: w32.HDC, items: []const markdown.ListItem, x0: i32, y0: i32, draw: bool) i32 {
        const line_h = self.px(LINE_H);
        const row_gap = self.px(ROW_GAP);
        const dot = self.px(5.0);
        const check = self.px(CHECK_SIDE);

        var gutter: i32 = 0;
        for (items) |item| {
            const wd: i32 = switch (item.marker) {
                .checkbox => check,
                .bullet => dot,
                .ordered => |n| blk: {
                    var buf: [12]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}.", .{n}) catch break :blk 0;
                    break :blk self.measureSeg(hdc, s, .{}, 0, false).cx;
                },
            };
            gutter = @max(gutter, wd);
        }

        var y = y0;
        for (items, 0..) |item, idx| {
            if (draw) {
                switch (item.marker) {
                    .checkbox => |checked| {
                        const mx = x0 + @divTrunc(gutter - check, 2);
                        _ = self.drawCheckbox(hdc, mx, y, line_h, checked, true);
                    },
                    .bullet => {
                        // A drawn dot sizes predictably vs the "•" glyph
                        // (Mac parity). RoundRect with full corner radius
                        // is a filled circle.
                        const mx = x0 + @divTrunc(gutter - dot, 2);
                        const my = y + @divTrunc(line_h - dot, 2);
                        const brush = w32.CreateSolidBrush(self.secondary());
                        const pen = w32.CreatePen(0, 1, self.secondary());
                        if (brush != null and pen != null) {
                            const pb = w32.SelectObject(hdc, @ptrCast(brush.?));
                            const pp = w32.SelectObject(hdc, pen.?);
                            _ = w32.RoundRect(hdc, mx, my, mx + dot, my + dot, dot, dot);
                            _ = w32.SelectObject(hdc, pp);
                            _ = w32.SelectObject(hdc, pb);
                        }
                        if (brush) |b| _ = w32.DeleteObject(@ptrCast(b));
                        if (pen) |p| _ = w32.DeleteObject(p);
                    },
                    .ordered => |n| {
                        var buf: [12]u8 = undefined;
                        if (std.fmt.bufPrint(&buf, "{d}.", .{n})) |s| {
                            const mw = self.measureSeg(hdc, s, .{}, 0, false).cx;
                            const mx = x0 + @divTrunc(gutter - mw, 2);
                            const prev_color = w32.SetTextColor(hdc, self.secondary());
                            var wbuf: [24]u16 = undefined;
                            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, s) catch 0;
                            if (wlen > 0) {
                                const font = self.fontFor(.{}, 0);
                                const prev_font = w32.SelectObject(hdc, font);
                                var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
                                _ = w32.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
                                _ = w32.TextOutW(hdc, mx, y + @divTrunc(line_h - size.cy, 2), &wbuf, @intCast(wlen));
                                _ = w32.SelectObject(hdc, prev_font);
                            }
                            _ = w32.SetTextColor(hdc, prev_color);
                        } else |_| {}
                    },
                }
            }
            _ = self.drawInlineLine(hdc, x0 + gutter + self.px(GUTTER_GAP), y, line_h, item.content, 0, false, draw);
            y += line_h;
            if (idx + 1 < items.len) y += row_gap;
        }
        return y - y0;
    }

    /// Walk all blocks: measure (draw=false) or paint (draw=true).
    /// Returns total content height. (`x0`, `y0`) is the content origin in
    /// client coords (the card's inner top-left) and `content_w` is the
    /// width available to it (bounds the rule width).
    fn renderContent(
        self: *BannerOverlay,
        hdc: w32.HDC,
        x0: i32,
        y0: i32,
        content_w: i32,
        draw: bool,
    ) i32 {
        const line_h = self.px(LINE_H);
        const block_gap = self.px(BLOCK_GAP);
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

        var y: i32 = y0;
        for (self.blocks, 0..) |block, bi| {
            if (bi > 0) y += block_gap;
            const h: i32 = switch (block) {
                .text => |segs| blk: {
                    _ = self.drawInlineLine(hdc, x0, y, line_h, segs, 0, false, draw);
                    break :blk line_h;
                },
                .heading => |h| blk: {
                    const hpx = heading_px[@min(h.level - 1, 5)];
                    const hl = self.px(hpx * 4.0 / 3.0);
                    _ = self.drawInlineLine(hdc, x0, y, hl, h.content, @min(h.level, 6), false, draw);
                    break :blk hl;
                },
                .rule => blk: {
                    if (draw) self.drawHLine(hdc, x0, x0 + content_w, y);
                    break :blk 1;
                },
                .list => |items| self.renderList(hdc, items, x0, y, draw),
                .table => |t| self.renderTable(hdc, t, x0, y, content_w, draw),
            };
            y += h;
        }
        return y - y0;
    }

    /// Chevron toggle hit rect (the card's top-right corner), in client
    /// coords — inside the card, not the band (T131).
    fn chevronRect(self: *BannerOverlay, client_w: i32) w32.RECT {
        const side = self.px(24.0);
        const margin = self.px(MARGIN);
        return .{
            .left = client_w - margin - side,
            .top = margin,
            .right = client_w - margin,
            .bottom = margin + side,
        };
    }

    /// Paint the band: the glass card backdrop (pane background + shadow +
    /// card), then the blocks inside the card, then collapse fade +
    /// chevron. Rebuilds the link hit rects as a side effect.
    fn paint(self: *BannerOverlay, hdc: w32.HDC) void {
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(self.hwnd, &client) == 0) return;

        self.paintCardBackdrop(hdc, client);

        self.links.clearRetainingCapacity();

        // Content lives inside the card: one margin, then one padding.
        const inner = self.px(MARGIN) + self.px(PAD);
        const content_w = @max(client.right - inner * 2, 1);

        // Clip everything the content walker draws to the card's own
        // rounded shape, so a collapsed banner's overflow (and any block
        // wider than the card) stops at the card edge instead of spilling
        // across the margin the terminal sees.
        const clip = self.cardClipRegion(client);
        defer if (clip) |rgn| {
            _ = w32.SelectClipRgn(hdc, null);
            _ = w32.DeleteObject(rgn);
        };
        if (clip) |rgn| _ = w32.SelectClipRgn(hdc, rgn);

        if (self.collapsed) {
            // Clip content to the collapsed card: the band is already
            // collapsed-height, so painting just overflows past the
            // bottom; the fade below dissolves it (Mac mask parity).
            _ = self.renderContent(hdc, inner, inner, content_w, true);
            self.paintCollapseFade(hdc, client);
        } else {
            _ = self.renderContent(hdc, inner, inner, content_w, true);
        }

        if (self.collapsible) self.paintChevron(hdc, client);
    }

    /// The card's rounded shape as a GDI region (client coords), for
    /// clipping content to it. Null when the region cannot be created —
    /// callers then draw unclipped rather than not at all.
    fn cardClipRegion(self: *BannerOverlay, client: w32.RECT) ?*anyopaque {
        const margin = self.px(MARGIN);
        const r = self.px(card.RADIUS);
        const left = client.left + margin;
        const top = client.top + margin;
        const right = client.right - margin;
        const bottom = client.bottom - margin;
        if (right <= left or bottom <= top) return null;
        return w32.CreateRoundRectRgn(left, top, right + 1, bottom + 1, r * 2, r * 2);
    }

    /// Blit the cached glass-card backdrop, regenerating it when the band
    /// size, the pane background, or the DPI scale changed (T131). Falls
    /// back to a flat card-fill rect if the DIB cannot be created.
    fn paintCardBackdrop(self: *BannerOverlay, hdc: w32.HDC, client: w32.RECT) void {
        const w = @max(client.right - client.left, 1);
        const h = @max(client.bottom - client.top, 1);

        const stale = self.card_dc == null or self.card_w != w or self.card_h != h or
            !std.meta.eql(self.card_bg, self.pane_bg_rgb) or self.card_scale != self.scale;
        if (stale) self.buildCardSurface(hdc, w, h);

        if (self.card_dc) |mem| {
            _ = w32.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, w32.SRCCOPY);
            return;
        }
        if (self.bg_brush) |brush| _ = w32.FillRect(hdc, &client, brush);
    }

    fn buildCardSurface(self: *BannerOverlay, hdc: w32.HDC, w: i32, h: i32) void {
        self.releaseCardSurface();

        var bmi = std.mem.zeroes(w32.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;

        const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
        var bits: ?*anyopaque = null;
        const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(mem_dc);
            return;
        };
        const raw = bits orelse {
            _ = w32.DeleteObject(bmp);
            _ = w32.DeleteDC(mem_dc);
            return;
        };
        _ = w32.SelectObject(mem_dc, bmp);

        const pixels = @as([*]u32, @ptrCast(@alignCast(raw)));
        const count: usize = @intCast(w * h);
        card.render(
            pixels[0..count],
            card.Metrics.init(w, h, self.scale),
            self.pane_bg_rgb,
        );

        self.card_dc = mem_dc;
        self.card_bmp = bmp;
        self.card_bits = pixels;
        self.card_w = w;
        self.card_h = h;
        self.card_bg = self.pane_bg_rgb;
        self.card_scale = self.scale;
    }

    fn releaseCardSurface(self: *BannerOverlay) void {
        if (self.card_dc) |dc| _ = w32.DeleteDC(dc);
        if (self.card_bmp) |b| _ = w32.DeleteObject(b);
        self.card_dc = null;
        self.card_bmp = null;
        self.card_bits = null;
        self.card_w = 0;
        self.card_h = 0;
        self.card_scale = 0;
    }

    /// Fade the tail of collapsed content into the card fill: an
    /// alpha-ramp DIB of the fill color blended over the lower portion of
    /// the CARD (Mac: linear mask opaque→clear from 55% to 100%). Spans the
    /// card, not the band — the margins around it are pane background.
    fn paintCollapseFade(self: *BannerOverlay, hdc: w32.HDC, client: w32.RECT) void {
        const margin = self.px(MARGIN);
        const card_top = client.top + margin;
        const card_bottom = client.bottom - margin;
        const card_h = card_bottom - card_top;
        if (card_h <= 0) return;
        const fade_top = card_top + @divTrunc(card_h * 45, 100);
        const fade_h = card_bottom - fade_top;
        if (fade_h <= 0) return;

        var bmi = std.mem.zeroes(w32.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w32.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = 1;
        bmi.bmiHeader.biHeight = -fade_h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;

        const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
        defer _ = w32.DeleteDC(mem_dc);
        var bits: ?*anyopaque = null;
        const bmp = w32.CreateDIBSection(mem_dc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        defer _ = w32.DeleteObject(bmp);
        const pixels = @as([*]u32, @ptrCast(@alignCast(bits orelse return)))[0..@intCast(fade_h)];
        for (pixels, 0..) |*p, row| {
            const a: u32 = @min(255, (row * 255) / @as(usize, @intCast(fade_h)));
            // Premultiplied BGRA of the strip bg at alpha a.
            const r = (@as(u32, self.bg_rgb.r) * a) / 255;
            const g = (@as(u32, self.bg_rgb.g) * a) / 255;
            const b = (@as(u32, self.bg_rgb.b) * a) / 255;
            p.* = (a << 24) | (r << 16) | (g << 8) | b;
        }

        const old = w32.SelectObject(mem_dc, bmp);
        defer _ = w32.SelectObject(mem_dc, old);
        const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
        _ = w32.AlphaBlend(
            hdc,
            client.left,
            fade_top,
            client.right - client.left,
            fade_h,
            mem_dc,
            0,
            0,
            1,
            fade_h,
            blend,
        );
    }

    /// The collapse/expand chevron in the top-right corner (Mac parity:
    /// chevron.up when expanded, chevron.down when collapsed).
    fn paintChevron(self: *BannerOverlay, hdc: w32.HDC, client: w32.RECT) void {
        const rect = self.chevronRect(client.right);
        const cx = @divTrunc(rect.left + rect.right, 2);
        // Vertically centered on the card's first content line (the card
        // starts one margin down from the band top, T131).
        const cy = self.px(MARGIN) + self.px(PAD) + @divTrunc(self.px(LINE_H), 2);
        const half = self.px(CHEV_W);
        const rise = self.px(CHEV_H);
        const pen = w32.CreatePen(0, @max(1, self.px(1.6)), self.secondary());
        if (pen) |p| {
            const prev = w32.SelectObject(hdc, p);
            if (self.collapsed) {
                // chevron.down: apex below the ends.
                _ = w32.MoveToEx(hdc, cx - half, cy - rise, null);
                _ = w32.LineTo(hdc, cx, cy + rise);
                _ = w32.LineTo(hdc, cx + half, cy - rise);
            } else {
                // chevron.up: apex above the ends.
                _ = w32.MoveToEx(hdc, cx - half, cy + rise, null);
                _ = w32.LineTo(hdc, cx, cy - rise);
                _ = w32.LineTo(hdc, cx + half, cy + rise);
            }
            _ = w32.SelectObject(hdc, prev);
            _ = w32.DeleteObject(p);
        }
    }

    fn toggleCollapsed(self: *BannerOverlay) void {
        if (!self.collapsible) return;
        self.collapsed = !self.collapsed;
        // The strip height changed: re-run the owning window's layout so
        // the terminal band under the strip grows/shrinks to match (T101).
        // The layout pass repositions this popup via updatePaneBanners.
        App.relayoutOwnerWindow(self.owner);
        _ = w32.InvalidateRect(self.hwnd, null, 1);
    }

    fn linkAt(self: *const BannerOverlay, x: i32, y: i32) ?[]const u8 {
        for (self.links.items) |l| {
            if (x >= l.rect.left and x < l.rect.right and
                y >= l.rect.top and y < l.rect.bottom) return l.url;
        }
        return null;
    }
};

var class_registered: bool = false;

fn registerClassOnce(hinstance: w32.HINSTANCE) !void {
    if (class_registered) return;

    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = bannerWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // painted in WM_PAINT with the cached brush
        .lpszMenuName = null,
        .lpszClassName = WINDOW_CLASS_NAME,
        .hIconSm = null,
    };

    if (w32.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn bannerWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const self_opt: ?*BannerOverlay = if (ud == 0) null else @ptrFromInt(@as(usize, @bitCast(ud)));
    const self = self_opt orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_ERASEBKGND => return 1, // WM_PAINT covers everything

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paint(hdc);
            return 0;
        },

        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                _ = w32.ScreenToClient(hwnd, &pt);
                const cursor = if (self.linkAt(pt.x, pt.y) != null)
                    w32.LoadCursorW(null, w32.IDC_HAND)
                else
                    w32.LoadCursorW(null, w32.IDC_ARROW);
                _ = w32.SetCursor(cursor);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
            if (self.linkAt(x, y)) |url| {
                var wurl: [2048:0]u16 = undefined;
                const wlen = std.unicode.utf8ToUtf16Le(&wurl, url) catch return 0;
                if (wlen < wurl.len) {
                    wurl[wlen] = 0;
                    _ = w32.ShellExecuteW(
                        null,
                        std.unicode.utf8ToUtf16LeStringLiteral("open"),
                        @ptrCast(&wurl),
                        null,
                        null,
                        w32.SW_SHOW,
                    );
                }
            } else if (self.collapsible) {
                // Mac parity: a tap anywhere on a multi-line banner
                // toggles collapse.
                self.toggleCollapsed();
            } else {
                // A click on a single-line strip focuses the pane under
                // it, like a click on the pane itself (T48: never
                // SetFocus in a WndProc).
                App.deferSetFocus(self.owner);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
