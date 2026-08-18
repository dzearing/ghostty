//! The viewer pane's native table-of-contents card (T160, design P5): an
//! owner-painted child window listing the document's headings, nested by
//! level, with the section being read highlighted as the page scrolls.
//!
//! The Windows port of Mac's `ViewerTOCPanel` + `ViewerSidePanel`. The card
//! chrome IS the banner's glass card (`banner_card.zig` renders the backdrop
//! — T131's port of `GlassCardBackground`), so a TOC card and a banner in the
//! pane next door read as the same component; the row metrics, the selection
//! pill, the gutter⇄overlay switch and the drag-to-resize handle come from
//! `viewer_toc_layout.zig`, where they assert at every scale without a
//! window.
//!
//! ## Who does what
//!
//! The panel OWNS its window, fonts, painting, scrolling, hover, and the
//! resize drag's mouse tracking. The PANE owns the policy: when the card
//! exists, which layout it is in, the width preference, pushing the page
//! gutter, and what a row click means (`tocRowClicked` runs the page's
//! `scrollToAnchor`, which pins the scroll spy — the pin itself lives in
//! `viewer.js` and this side must not fight it; the highlight simply follows
//! the `active` messages the page posts).
//!
//! Heading ids and the active id are BORROWED from the pane's own storage
//! (`ViewerPane.headings` / `active_heading`): everything runs on the UI
//! thread, and the pane rebuilds this panel's rows in the same call that
//! replaces that storage, so no borrow outlives its owner. Row TEXT is
//! converted to UTF-16 once at sync time and owned here — paint runs far more
//! often than headings change.
const ViewerTOCPanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
// Test-only (T467): the class-level resize/redraw probe. Imported at file
// scope so its own positive and negative controls are queued into the win32
// test lane along with the class test below.
const class_redraw = @import("class_redraw.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const system_colors = @import("system_colors.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const toc = @import("viewer_toc_layout.zig");
const ViewerPane = @import("ViewerPane.zig");

const log = std.log.scoped(.viewer_toc);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewerTOC");

/// The document page's own background, kept in step with viewer.css (and with
/// Mac's `SidePanelCard.documentBackground`) so the card's opaque composite is
/// the same color as the page it sits on: white in light, GitHub's `#0d1117`
/// in dark.
pub fn documentBackground(dark: bool) color_math.Rgb {
    return if (dark)
        .{ .r = 13, .g = 17, .b = 23 }
    else
        .{ .r = 255, .g = 255, .b = 255 };
}

/// One display row: a borrowed id, owned UTF-16 label, indent depth, and its
/// measured slot in the list (list coordinates: y=0 at the top of the first
/// row's padding, i.e. just under the header's own inset).
const Row = struct {
    id: []const u8,
    text16: []u16,
    depth: u8,
    y: i32 = 0,
    h: i32 = 0,
};

hwnd: w32.HWND,
pane: *ViewerPane,
alloc: Allocator,

rows: std.ArrayList(Row) = .empty,
/// Total measured list height (rows + inter-row spacing), px.
list_h: i32 = 0,
/// Whether rows need re-measuring before the next placement (new items, new
/// width, or new scale).
dirty: bool = true,

/// Index of the active (highlighted) row, -1 when none.
active: i32 = -1,
hover: i32 = -1,
tracking: bool = false,

/// Scroll offset into the list, px, >= 0.
scroll: i32 = 0,

/// The layout of the last placement, in this window's client coordinates
/// (window origin). `place` refreshes it; every hit test reads it.
layout: toc.Layout = .{ .which = .hidden },
/// The measured card width the rows were laid against, px.
measured_w: i32 = 0,
measured_scale: f32 = 0,

/// Resize drag state: the card width (DIP) when the drag started, and the
/// mouse x (client px) it started at. Null when not dragging.
drag: ?struct { start_dip: f32, start_x: i32 } = null,

scale: f32 = 1.0,
row_font: ?*anyopaque = null,
header_font: ?*anyopaque = null,
line_h: i32 = 16,
caption_line_h: i32 = 14,

// Theme, derived in applyTheme.
dark: bool = true,
doc_bg: color_math.Rgb = .{ .r = 13, .g = 17, .b = 23 },
card_fill: color_math.Rgb = .{ .r = 28, .g = 31, .b = 37 },
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,

// Cached card backdrop DIB (the BannerOverlay pattern): regenerated when the
// band size, the theme, or the scale moves.
card_dc: ?w32.HDC = null,
card_bmp: ?*anyopaque = null,
card_w: i32 = 0,
card_h: i32 = 0,
card_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
card_scale: f32 = 0,

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW (T467): the card is a rounded band drawn
        // against the window's own bounds - the rim and its shadow sit on the
        // edges, and in gutter mode the card is inset inside a strip whose
        // width `place()` re-derives from the pane. `place()` happens to redraw
        // today because `SetWindowRgn(.., TRUE)` runs right after its
        // `MoveWindow`, but that is a side effect of the rounded-corner clip,
        // not a repaint contract: the gutter branch that passes a null region
        // would lose it. The class style is the property being relied on, so
        // it is the class that states it.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null, // every pixel painted in WM_PAINT
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("viewer TOC class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Create the panel as a HIDDEN child of the pane's host window. Null when
/// the window cannot be created — the pane then has no card, which degrades
/// to the pre-T160 world rather than to a crash.
pub fn create(
    alloc: Allocator,
    pane: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
) ?*ViewerTOCPanel {
    registerClass(hinstance);
    if (!class_registered) return null;

    const self = alloc.create(ViewerTOCPanel) catch return null;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD, // shown by place() when a layout calls for it
        0,
        0,
        0,
        0,
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return null;
    };

    self.* = .{
        .hwnd = hwnd,
        .pane = pane,
        .alloc = alloc,
    };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.applyTheme();
    return self;
}

pub fn destroy(self: *ViewerTOCPanel) void {
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.clearRows();
    self.rows.deinit(self.alloc);
    self.releaseCardSurface();
    if (self.row_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.header_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*ViewerTOCPanel {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

// -------------------------------------------------------------------------
// State pushed by the pane
// -------------------------------------------------------------------------

fn clearRows(self: *ViewerTOCPanel) void {
    for (self.rows.items) |r| self.alloc.free(r.text16);
    self.rows.clearRetainingCapacity();
    self.list_h = 0;
}

/// Rebuild the display rows from the pane's current headings. Called by the
/// pane in the same breath as it replaces `pane.headings`, so the borrowed
/// ids can never dangle. Measurement is deferred to `place` (it needs the
/// card width).
pub fn setItems(self: *ViewerTOCPanel) void {
    self.clearRows();
    self.active = -1;
    self.hover = -1;
    self.scroll = 0;
    self.dirty = true;

    const items = self.pane.headings;
    // Depth is relative to the document's own top level (Mac's
    // `ViewerTOCItem.list`), so a file whose headings start at ## is not
    // indented for no reason.
    var top: u8 = 255;
    for (items) |h| top = @min(top, h.level);
    for (items) |h| {
        const text16 = std.unicode.utf8ToUtf16LeAlloc(self.alloc, h.text) catch continue;
        self.rows.append(self.alloc, .{
            .id = h.id,
            .text16 = text16,
            .depth = toc.depthOf(h.level, top),
        }) catch {
            self.alloc.free(text16);
            return;
        };
    }
    // Keep the selection continuous across a re-index (a live reload posts a
    // fresh headings list, then an active id).
    self.syncActiveFromPane(false);
}

/// Re-derive the highlighted row from `pane.active_heading` and reveal it.
/// `reveal` scrolls the list the minimum needed to show the row (Mac's
/// `proxy.scrollTo`); a plain re-sync after a rebuild skips that so a restore
/// does not yank the list around.
pub fn syncActiveFromPane(self: *ViewerTOCPanel, reveal: bool) void {
    const id = self.pane.active_heading;
    var next: i32 = -1;
    if (id) |wanted| {
        for (self.rows.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, wanted)) {
                next = @intCast(i);
                break;
            }
        }
    }
    if (next == self.active) return;
    self.active = next;
    if (reveal and next >= 0) self.revealRow(@intCast(next));
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// The DPI scale moved (monitor change): fonts and measurements are stale.
pub fn setScale(self: *ViewerTOCPanel, scale: f32) void {
    if (self.scale == scale) return;
    self.scale = scale;
    self.dirty = true;
}

/// Re-derive every color from the pane's color scheme. The card sits on the
/// DOCUMENT, so its composite base is the page background, not the terminal's.
pub fn applyTheme(self: *ViewerTOCPanel) void {
    self.dark = self.pane.color_scheme != .light;
    self.doc_bg = documentBackground(self.dark);
    self.card_fill = banner_card.fillColor(self.doc_bg);
    const text = chrome_theme.textOn(self.card_fill);
    const secondary = chrome_theme.textSecondaryOn(self.card_fill);
    self.text_ref = w32.RGB(text.r, text.g, text.b);
    self.secondary_ref = w32.RGB(secondary.r, secondary.g, secondary.b);
    self.releaseCardSurface();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// -------------------------------------------------------------------------
// Measurement & placement
// -------------------------------------------------------------------------

fn px(self: *const ViewerTOCPanel, dip: f32) i32 {
    return toc.px(dip, self.scale);
}

fn ensureFonts(self: *ViewerTOCPanel) void {
    if (self.row_font != null and self.measured_scale == self.scale) return;
    if (self.row_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.header_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    const row_ramp = type_ramp.caption(self.scale);
    self.row_font = w32.CreateFontW(
        -row_ramp.height,
        0,
        0,
        0,
        row_ramp.weight,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
    self.header_font = w32.CreateFontW(
        -row_ramp.height,
        0,
        0,
        0,
        type_ramp.weight_semibold,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
}

/// Measure every row's wrapped height against `card_w`, filling `y`/`h` and
/// `list_h`. Uses a screen DC — measurement is font metrics, not painting.
fn measureRows(self: *ViewerTOCPanel, card_w: i32) void {
    self.ensureFonts();
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);

    const font = self.row_font orelse return;
    const prev = w32.SelectObject(hdc, @ptrCast(font));
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };

    // One line's height, measured rather than assumed from the em size.
    var probe = [_]u16{ 'A', 'g' };
    var pr = w32.RECT{ .left = 0, .top = 0, .right = 1000, .bottom = 0 };
    _ = w32.DrawTextW(hdc, &probe, 2, &pr, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    self.line_h = @max(pr.bottom - pr.top, 1);
    self.caption_line_h = self.line_h;

    const gap = self.px(1); // Mac: VStack spacing 1 between rows
    var y: i32 = 0;
    for (self.rows.items, 0..) |*row, i| {
        if (i != 0) y += gap;
        const text_w = toc.rowTextWidth(card_w, row.depth, self.scale);
        var r = w32.RECT{ .left = 0, .top = 0, .right = text_w, .bottom = 0 };
        _ = w32.DrawTextW(
            hdc,
            row.text16.ptr,
            @intCast(row.text16.len),
            &r,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );
        const measured_lines = std.math.divCeil(i32, @max(r.bottom - r.top, 1), self.line_h) catch 1;
        const lines = std.math.clamp(measured_lines, 1, @as(i32, toc.max_row_lines));
        row.y = y;
        row.h = toc.rowHeight(lines, self.line_h, self.scale);
        y += row.h;
    }
    self.list_h = y;
    self.measured_w = card_w;
    self.measured_scale = self.scale;
    self.dirty = false;
}

/// The card content's needed height: header + list inset above and below.
fn neededHeight(self: *const ViewerTOCPanel) i32 {
    return toc.headerHeight(self.caption_line_h, self.scale) +
        2 * self.px(toc.fill_inset_dip) + self.list_h;
}

/// The result of a placement, for the pane's gutter push.
pub const Placement = struct {
    which: toc.Mode,
    card_w_dip: f32,
};

/// Lay the panel out for the pane's current content area and show or hide it.
///
/// `content_top` is where the pane's content begins in host-client
/// coordinates (the nav bar's band when it is visible); `content_w`/`content_h`
/// are the content area's size. `visible` lets the pane keep a compact card
/// hidden while it is toggled closed — the layout is still computed so the
/// nav button knows the card exists.
pub fn place(
    self: *ViewerTOCPanel,
    scale: f32,
    content_top: i32,
    content_w: i32,
    content_h: i32,
    pref_dip: f32,
    visible: bool,
) Placement {
    self.setScale(scale);

    const pane_w_dip = @as(f32, @floatFromInt(content_w)) / scale;
    const which = toc.mode(pane_w_dip, self.rows.items.len);
    if (which == .hidden) {
        self.layout = .{ .which = .hidden };
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        return .{ .which = .hidden, .card_w_dip = 0 };
    }

    // Measure against the width this mode gives the card; re-measure only
    // when the width, scale, or items moved.
    const card_w_dip = switch (which) {
        .gutter => toc.clampWidth(pref_dip, pane_w_dip),
        .compact => toc.compactCardWidth(pref_dip, pane_w_dip),
        .hidden => unreachable,
    };
    const card_w = self.px(card_w_dip);
    if (self.dirty or self.measured_w != card_w or self.measured_scale != scale) {
        self.measureRows(card_w);
    }

    self.layout = toc.Layout.init(
        scale,
        content_w,
        content_h,
        pref_dip,
        self.neededHeight(),
        self.rows.items.len,
    );
    const l = self.layout;

    // Clamp the scroll to the new viewport (a taller card may have absorbed
    // the overflow the old scroll compensated for).
    self.clampScroll();

    _ = w32.MoveWindow(
        self.hwnd,
        l.window.left,
        content_top + l.window.top,
        @max(l.window.width(), 1),
        @max(l.window.height(), 1),
        1,
    );

    // The compact card floats over live document text, so the WINDOW is
    // clipped to the card's rounded shape — its corners show the page, not a
    // squared-off patch of card fill. The gutter window sits over the page's
    // reserved padding and needs no region.
    if (which == .compact) {
        const r = self.px(banner_card.RADIUS);
        const rgn = w32.CreateRoundRectRgn(
            0,
            0,
            l.window.width() + 1,
            l.window.height() + 1,
            2 * r,
            2 * r,
        );
        // The system owns the region on success; on failure the window just
        // keeps square corners.
        _ = w32.SetWindowRgn(self.hwnd, rgn, 1);
    } else {
        _ = w32.SetWindowRgn(self.hwnd, null, 1);
    }

    if (visible) {
        // Above the WebView2 sibling: the card floats over the document.
        _ = w32.SetWindowPos(
            self.hwnd,
            null, // HWND_TOP
            0,
            0,
            0,
            0,
            w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
        );
    } else {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
    }
    _ = w32.InvalidateRect(self.hwnd, null, 0);

    return .{ .which = which, .card_w_dip = l.card_w_dip };
}

pub fn hide(self: *ViewerTOCPanel) void {
    self.layout = .{ .which = .hidden };
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
}

// -------------------------------------------------------------------------
// Scrolling
// -------------------------------------------------------------------------

/// The list viewport's height: the card minus its pinned header and the list
/// insets.
fn viewportHeight(self: *const ViewerTOCPanel) i32 {
    return @max(
        self.layout.card.height() -
            toc.headerHeight(self.caption_line_h, self.scale) -
            2 * self.px(toc.fill_inset_dip),
        1,
    );
}

fn maxScroll(self: *const ViewerTOCPanel) i32 {
    return @max(self.list_h - self.viewportHeight(), 0);
}

fn clampScroll(self: *ViewerTOCPanel) void {
    self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll());
}

/// Scroll the minimum needed to bring a row into view (Mac's un-anchored
/// `proxy.scrollTo`): a long TOC must not jump around while the user reads.
fn revealRow(self: *ViewerTOCPanel, index: usize) void {
    if (index >= self.rows.items.len) return;
    const row = self.rows.items[index];
    const view_h = self.viewportHeight();
    if (row.y < self.scroll) {
        self.scroll = row.y;
    } else if (row.y + row.h > self.scroll + view_h) {
        self.scroll = row.y + row.h - view_h;
    }
    self.clampScroll();
}

// -------------------------------------------------------------------------
// Hit testing
// -------------------------------------------------------------------------

/// The row under a client point, honoring the header (points on it belong to
/// nothing) and the scroll offset.
fn hitRow(self: *const ViewerTOCPanel, x: i32, y: i32) i32 {
    const l = self.layout;
    if (l.which == .hidden) return -1;
    const header_h = toc.headerHeight(self.caption_line_h, self.scale);
    const list_top = l.card.top + header_h + self.px(toc.fill_inset_dip);
    if (x < l.card.left or x >= l.card.right) return -1;
    if (y < list_top or y >= l.card.bottom - self.px(toc.fill_inset_dip)) return -1;
    const ly = y - list_top + self.scroll;
    for (self.rows.items, 0..) |r, i| {
        if (ly >= r.y and ly < r.y + r.h) return @intCast(i);
    }
    return -1;
}

fn onHandle(self: *const ViewerTOCPanel, x: i32, y: i32) bool {
    return self.layout.which == .gutter and self.layout.handle.containsPoint(x, y);
}

// -------------------------------------------------------------------------
// Painting
// -------------------------------------------------------------------------

/// Build the glass-card backdrop DIB for a band of `w` x `h` (the card plus a
/// margin on every side), composited over the document background.
fn ensureCardSurface(self: *ViewerTOCPanel, hdc: w32.HDC, w: i32, h: i32) void {
    const stale = self.card_dc == null or self.card_w != w or self.card_h != h or
        !std.meta.eql(self.card_bg, self.doc_bg) or self.card_scale != self.scale;
    if (!stale) return;
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
    banner_card.render(
        pixels[0..count],
        banner_card.Metrics.init(w, h, self.scale),
        self.doc_bg,
    );

    self.card_dc = mem_dc;
    self.card_bmp = bmp;
    self.card_w = w;
    self.card_h = h;
    self.card_bg = self.doc_bg;
    self.card_scale = self.scale;
}

fn releaseCardSurface(self: *ViewerTOCPanel) void {
    if (self.card_dc) |dc| _ = w32.DeleteDC(dc);
    if (self.card_bmp) |b| _ = w32.DeleteObject(b);
    self.card_dc = null;
    self.card_bmp = null;
    self.card_w = 0;
    self.card_h = 0;
    self.card_scale = 0;
}

fn fillRoundRect(hdc: w32.HDC, r: w32.RECT, radius: i32, color: u32) void {
    const rgn = w32.CreateRoundRectRgn(
        r.left,
        r.top,
        r.right + 1,
        r.bottom + 1,
        2 * radius,
        2 * radius,
    ) orelse return;
    defer _ = w32.DeleteObject(rgn);
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
}

fn paint(self: *ViewerTOCPanel, hdc: w32.HDC, width: i32, height: i32) void {
    const l = self.layout;
    if (l.which == .hidden) return;
    self.ensureFonts();

    const margin = self.px(toc.margin_dip);
    const band_w = l.card.width() + 2 * margin;
    const band_h = l.card.height() + 2 * margin;
    self.ensureCardSurface(hdc, band_w, band_h);

    // Backdrop: the glass card over the document background. In gutter mode
    // the window is the whole strip — the band blits at the card's origin
    // minus a margin, and everything below is plain page background. In
    // compact mode the window IS the card, so the band's center crop lands at
    // the origin.
    const doc_ref = w32.RGB(self.doc_bg.r, self.doc_bg.g, self.doc_bg.b);
    if (w32.CreateSolidBrush(doc_ref)) |brush| {
        defer _ = w32.DeleteObject(@ptrCast(brush));
        var full = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
        _ = w32.FillRect(hdc, &full, brush);
    }
    if (self.card_dc) |mem| {
        switch (l.which) {
            .gutter => _ = w32.BitBlt(
                hdc,
                l.card.left - margin,
                l.card.top - margin,
                band_w,
                band_h,
                mem,
                0,
                0,
                w32.SRCCOPY,
            ),
            .compact => _ = w32.BitBlt(
                hdc,
                0,
                0,
                l.card.width(),
                l.card.height(),
                mem,
                margin,
                margin,
                w32.SRCCOPY,
            ),
            .hidden => unreachable,
        }
    } else {
        // No DIB: a flat card fill still yields a readable list.
        const fill_ref = w32.RGB(self.card_fill.r, self.card_fill.g, self.card_fill.b);
        if (w32.CreateSolidBrush(fill_ref)) |brush| {
            defer _ = w32.DeleteObject(@ptrCast(brush));
            var r = w32.RECT{
                .left = l.card.left,
                .top = l.card.top,
                .right = l.card.right,
                .bottom = l.card.bottom,
            };
            _ = w32.FillRect(hdc, &r, brush);
        }
    }

    // Everything from here on stays inside the card's rounded shape.
    const saved = w32.SaveDC(hdc);
    defer _ = w32.RestoreDC(hdc, saved);
    const radius = self.px(banner_card.RADIUS);
    if (w32.CreateRoundRectRgn(
        l.card.left,
        l.card.top,
        l.card.right + 1,
        l.card.bottom + 1,
        2 * radius,
        2 * radius,
    )) |rgn| {
        defer _ = w32.DeleteObject(rgn);
        _ = w32.SelectClipRgn(hdc, rgn);
    }

    const header_h = toc.headerHeight(self.caption_line_h, self.scale);
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // Rows, clipped to the list viewport so they scroll UNDER the header.
    {
        const inner_saved = w32.SaveDC(hdc);
        defer _ = w32.RestoreDC(hdc, inner_saved);
        const list_top = l.card.top + header_h;
        _ = w32.IntersectClipRect(hdc, l.card.left, list_top, l.card.right, l.card.bottom);

        const fill_inset = self.px(toc.fill_inset_dip);
        const origin_y = list_top + fill_inset - self.scroll;
        const accent = system_colors.accentCached();
        const accent_text = chrome_theme.textOn(accent);
        const row_radius = self.px(toc.row_corner_dip);
        const emphasized = self.isEmphasized();

        if (self.row_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        for (self.rows.items, 0..) |row, i| {
            const top = origin_y + row.y;
            if (top + row.h < list_top) continue;
            if (top > l.card.bottom) break;

            const is_active = self.active == @as(i32, @intCast(i));
            const is_hover = self.hover == @as(i32, @intCast(i));
            const fill_rect = w32.RECT{
                .left = l.card.left + fill_inset,
                .top = top,
                .right = l.card.right - fill_inset,
                .bottom = top + row.h,
            };

            var color = self.secondary_ref;
            if (is_active) {
                // The macOS selection rule, translated: the KEY window gets
                // the accent pill with contrast-checked text; every other
                // window drops to a neutral wash with the ordinary label
                // color (state never carried by color alone — the pill shape
                // itself is the state).
                if (emphasized) {
                    fillRoundRect(
                        hdc,
                        fill_rect,
                        row_radius,
                        w32.RGB(accent.r, accent.g, accent.b),
                    );
                    color = w32.RGB(accent_text.r, accent_text.g, accent_text.b);
                } else {
                    const wash = unemphasizedFill(self.card_fill);
                    fillRoundRect(hdc, fill_rect, row_radius, w32.RGB(wash.r, wash.g, wash.b));
                    color = self.text_ref;
                }
            } else if (is_hover) {
                const wash = hoverFill(self.card_fill);
                fillRoundRect(hdc, fill_rect, row_radius, w32.RGB(wash.r, wash.g, wash.b));
            }

            const text_left = l.card.left + toc.rowTextLeft(row.depth, self.scale);
            const text_w = toc.rowTextWidth(l.card.width(), row.depth, self.scale);
            var tr = w32.RECT{
                .left = text_left,
                .top = top + self.px(toc.row_v_pad_dip),
                .right = text_left + text_w,
                .bottom = top + row.h - self.px(toc.row_v_pad_dip),
            };
            _ = w32.SetTextColor(hdc, color);
            _ = w32.DrawTextW(
                hdc,
                row.text16.ptr,
                @intCast(row.text16.len),
                &tr,
                w32.DT_WORDBREAK | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );
        }

        // Overflow scroller: a thin overlay thumb, because a list you can
        // scroll with no scroller is a list that looks complete when it
        // isn't.
        const max_s = self.maxScroll();
        if (max_s > 0) {
            const view_h = self.viewportHeight();
            const track_top = list_top + fill_inset;
            const thumb_h = @max(
                @divTrunc(view_h * view_h, self.list_h),
                self.px(24),
            );
            const range = view_h - thumb_h;
            const thumb_top = track_top +
                @divTrunc(range * self.scroll, max_s);
            const tw = self.px(3);
            const tr = w32.RECT{
                .left = l.card.right - self.px(3) - tw,
                .top = thumb_top,
                .right = l.card.right - self.px(3),
                .bottom = thumb_top + thumb_h,
            };
            fillRoundRect(hdc, tr, @divTrunc(tw, 2), self.secondary_ref);
        }
    }

    // The pinned header, over the rows: an opaque band of the card's own fill
    // with the "CONTENTS" caption at the label inset (a sidebar header lines
    // up with the row text, not the fill).
    {
        const fill_ref = w32.RGB(self.card_fill.r, self.card_fill.g, self.card_fill.b);
        if (w32.CreateSolidBrush(fill_ref)) |brush| {
            defer _ = w32.DeleteObject(@ptrCast(brush));
            var hr = w32.RECT{
                .left = l.card.left,
                .top = l.card.top,
                .right = l.card.right,
                .bottom = l.card.top + header_h,
            };
            _ = w32.FillRect(hdc, &hr, brush);
        }
        if (self.header_font) |f| _ = w32.SelectObject(hdc, @ptrCast(f));
        _ = w32.SetTextColor(hdc, self.secondary_ref);
        var caption = std.unicode.utf8ToUtf16LeStringLiteral("CONTENTS").*;
        var cr = w32.RECT{
            .left = l.card.left + self.px(toc.label_inset_dip),
            .top = l.card.top,
            .right = l.card.right - self.px(toc.label_inset_dip),
            .bottom = l.card.top + header_h,
        };
        _ = w32.DrawTextW(
            hdc,
            &caption,
            caption.len,
            &cr,
            w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
        );
    }
}

/// True when this card's top-level window is the ACTIVE window — the Windows
/// reading of Mac's "key window", which decides whether the selection pill
/// paints in the accent or the neutral unemphasized gray.
///
/// `w32.windowIsActive` rather than a bare `GetForegroundWindow` comparison
/// (T215): the latter is null for every window on a background desktop, so
/// the pill painted unemphasized there forever — including under the pixel
/// probes that are supposed to prove it does not.
fn isEmphasized(self: *const ViewerTOCPanel) bool {
    return w32.windowIsActive(w32.GetAncestor(self.hwnd, w32.GA_ROOT));
}

/// The unemphasized selection wash: a visible step off the card fill.
/// `color_math.wash` picks its direction from the fill's own luminance, so
/// one alpha serves both themes.
fn unemphasizedFill(fill: color_math.Rgb) color_math.Rgb {
    return color_math.wash(fill, 0.14);
}

/// The hover wash: fainter than any selection (Mac: primary at 6%).
fn hoverFill(fill: color_math.Rgb) color_math.Rgb {
    return color_math.wash(fill, 0.06);
}

// -------------------------------------------------------------------------
// Window procedure
// -------------------------------------------------------------------------

fn xOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF))));
}
fn yOf(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF))));
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_ERASEBKGND => return 1,

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) != 0) {
                self.paint(hdc, r.right - r.left, r.bottom - r.top);
            }
            return 0;
        },
        // The same card into a caller's DC, so a pixel probe can photograph it
        // synchronously rather than through DWM's asynchronous copy of the
        // composited surface, which tears mid-row (T835/T940).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },

        // The card is chrome: interacting with it must not steal keyboard
        // focus from the document (or the address bar).
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,

        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0 and w32.ScreenToClient(hwnd, &pt) != 0) {
                if (self.drag != null or self.onHandle(pt.x, pt.y)) {
                    _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_SIZEWE));
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_MOUSEMOVE => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.drag) |d| {
                const dx = @as(f32, @floatFromInt(x - d.start_x)) / self.scale;
                self.pane.setTOCWidthLive(d.start_dip + dx);
                return 0;
            }
            const hot = self.hitRow(x, y);
            if (hot != self.hover) {
                self.hover = hot;
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            if (!self.tracking) {
                var tme = w32.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.tracking = true;
            }
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.hover != -1) {
                self.hover = -1;
                _ = w32.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            const delta: i32 = @as(i16, @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF))));
            // Three text lines per notch — the Windows list default.
            const step = @divTrunc(delta * 3 * self.line_h, 120);
            const before = self.scroll;
            self.scroll -= step;
            self.clampScroll();
            if (self.scroll != before) _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.onHandle(x, y)) {
                self.drag = .{ .start_dip = self.layout.card_w_dip, .start_x = x };
                _ = w32.SetCapture(hwnd);
                return 0;
            }
            // Row activation happens on the up over the same row (standard
            // button affordance); remember the press via hover.
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x = xOf(lparam);
            const y = yOf(lparam);
            if (self.drag != null) {
                self.drag = null;
                _ = w32.ReleaseCapture();
                self.pane.commitTOCWidth();
                return 0;
            }
            const hit = self.hitRow(x, y);
            if (hit >= 0) {
                const row = self.rows.items[@intCast(hit)];
                self.pane.tocRowClicked(row.id);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// T467: the panel is a rounded card drawn against its own bounds — the rim and
// its shadow sit on the edges — and `place()` re-derives its width from the
// pane on every bounds sync. It survives today only because
// `SetWindowRgn(.., TRUE)` happens to follow the `MoveWindow`; this asserts the
// property directly, on the class, where it does not depend on that.
test "viewer TOC class: a resize invalidates the whole card" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClass(hinst);
    if (!class_registered) return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
