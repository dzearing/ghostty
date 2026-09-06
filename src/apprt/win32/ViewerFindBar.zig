//! The viewer pane's find-in-page card (T1184): an owner-painted native child
//! window carrying a real `EDIT`, a live match count, and previous / next /
//! close controls.
//!
//! A FLOATING CARD at the content's top-trailing corner, not a strip under the
//! nav bar — the same call Mac made. A second band would push the document
//! down by ~64 px on every ctrl+F, so the text you were about to search
//! scrolls out from under you as you ask for it. The card costs no layout at
//! all, looks identical in every viewer mode, and is the shape Chrome trained
//! people to expect. Its one cost — it covers the
//! document's top-right corner — is paid back by `find.js` scrolling matches to
//! the MIDDLE of the pane, so the card is never over the match it just found.
//!
//! ## Who does what
//!
//! The card OWNS its controls and their painting. The PAGE owns the search
//! itself (`src/viewer/find.js` — the index, the matching, the highlight
//! painting, the count). The PANE owns the conversation between them: it
//! pushes queries down, receives counts back up, and decides when the card is
//! open. Geometry and the count's wording are `viewer_find.zig`, where they
//! assert at every scale without a window.
//!
//! Precedents for the shape of this file: `ViewerNavBar.zig` (the EDIT and its
//! main-loop key routing) and `ViewerTOCPanel.zig` (a card floating above the
//! WebView2 sibling, drawn through `banner_card.render`).
const ViewerFindBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const class_redraw = @import("class_redraw.zig");
const color_math = @import("color_math.zig");
const chrome_theme = @import("chrome_theme.zig");
const banner_card = @import("banner_card.zig");
const type_ramp = @import("type_ramp.zig");
const icon_button = @import("icon_button.zig");
const icon_paint = @import("icon_button_paint.zig");
const find = @import("viewer_find.zig");
const viewer_accel = @import("viewer_accel.zig");
const input = @import("../../input.zig");
const utf16_text = @import("utf16_text.zig");
const ViewerPane = @import("ViewerPane.zig");

const log = std.log.scoped(.viewer_find);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyViewerFind");
const class_name_utf8 = "GhozttyViewerFind";

/// Select the whole query once a focus-gaining click has finished — the same
/// ordering lesson (and the same fix) as the address field's.
pub const WM_APP_SELECT_ALL: u32 = w32.WM_APP + 1;

const edit_id: usize = 1;

/// UTF-16 units the query field may hold. `viewer_find.max_query` is a byte
/// bound on what is PUSHED; this is the control's own, and it is deliberately
/// the same number — UTF-16 units never outnumber UTF-8 bytes, so a field the
/// user filled to the brim still pushes without truncation for any query that
/// is not mostly non-Latin.
const query_cap_utf16: usize = find.max_query + 1;

/// The honesty note's bound (`find.js` → `scopeNote`): a file name plus a
/// clause, with room for a long path's last component.
const note_cap: usize = 256;

hwnd: w32.HWND,
edit: w32.HWND,
pane: *ViewerPane,
alloc: Allocator,

/// What the page last reported, and what it said it is NOT searching.
result: find.Result = .none,
note: [note_cap]u8 = undefined,
note_len: usize = 0,

hover: ?find.Button = null,
pressed: ?find.Button = null,
tracking: bool = false,

/// Set by the main loop's `WM_LBUTTONDOWN` intercept when the click landed on
/// an UNFOCUSED query field; consumed on the matching `WM_LBUTTONUP`.
select_on_up: bool = false,

/// The scale the fonts and layout were last built for, and the CONTENT width
/// the card was last placed inside. The width is cached rather than re-derived
/// from the parent, whose client area includes chrome the card is not measured
/// against — and caching it is what makes the paint and the hit test resolve
/// the same layout the placement did.
scale: f32 = 0,
content_w: i32 = 0,
font: ?*anyopaque = null, // HFONT for the query field and the count
note_font: ?*anyopaque = null, // HFONT for the honesty line
edit_brush: ?w32.HBRUSH = null,

/// The card's pre-rendered glass, and what it was rendered for.
card_dc: ?w32.HDC = null,
card_bmp: ?*anyopaque = null,
card_w: i32 = 0,
card_h: i32 = 0,
card_bg: color_math.Rgb = .{ .r = 0, .g = 0, .b = 0 },
card_scale: f32 = 0,

/// The card box the metrics line last reported. `place` runs on every bounds
/// sync, so a line per call would be noise; a line per CHANGE is the rule the
/// TOC card's `logCardMetrics` already follows, and it is what an acceptance
/// script reads to see the corner clip that was applied.
logged_card_w: i32 = -1,
logged_card_h: i32 = -1,

// Theme, derived from the pane's background in `applyTheme`.
doc_rgb: color_math.Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x20 },
card_rgb: color_math.Rgb = .{ .r = 0x28, .g = 0x28, .b = 0x28 },
field_rgb: color_math.Rgb = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A },
text_ref: u32 = 0x00FFFFFF,
secondary_ref: u32 = 0x00AAAAAA,
dark: bool = true,

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // CS_HREDRAW | CS_VREDRAW: the card's whole layout is a function of
        // its width — the field stretches and the trailing cluster is anchored
        // to the right edge — so a width change makes every pixel stale, not
        // just the strip the resize uncovers (the T467 rule).
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
        log.warn("viewer find class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Create the card as a HIDDEN child of the pane's host window. Null when any
/// window cannot be created — the pane then simply has no find card, which
/// degrades to "ctrl+F does nothing" rather than to a crash.
pub fn create(
    alloc: Allocator,
    pane: *ViewerPane,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
) ?*ViewerFindBar {
    registerClass(hinstance);
    if (!class_registered) return null;

    const self = alloc.create(ViewerFindBar) catch return null;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD, // shown by `open`
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

    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(edit_id),
        hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return null;
    };
    // No WS_BORDER, unlike the address field: this field sits inside a card
    // that already has an edge, and a second rectangle inside it reads as a
    // dialog rather than as a browser find bar. The cue banner is what says
    // "type here" — Mac's placeholder, and the Windows-native way to label a
    // search box without a caption.
    _ = w32.SendMessageW(edit, w32.EM_LIMITTEXT, query_cap_utf16 - 1, 0);
    _ = w32.SendMessageW(
        edit,
        w32.EM_SETCUEBANNER,
        1,
        @bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Find"))),
    );

    self.* = .{
        .hwnd = hwnd,
        .edit = edit,
        .pane = pane,
        .alloc = alloc,
    };
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.applyTheme();
    return self;
}

pub fn destroy(self: *ViewerFindBar) void {
    // Clear the back-pointer FIRST: DestroyWindow delivers messages
    // synchronously, and they must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd); // destroys the EDIT with it
    if (self.font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.note_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.edit_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.releaseCardSurface();
    self.alloc.destroy(self);
}

fn fromHwnd(hwnd: w32.HWND) ?*ViewerFindBar {
    const v = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

/// The card whose QUERY FIELD is `hwnd`, if any — the main message loop's
/// routing hook, identified by the parent's class exactly like
/// `ViewerNavBar.owningEdit`.
pub fn owningEdit(hwnd: w32.HWND) ?*ViewerFindBar {
    const parent = w32.GetParent(hwnd) orelse return null;
    var name: [24:0]u16 = undefined;
    const n = w32.GetClassNameW(parent, &name, name.len);
    if (n <= 0) return null;
    const expect = std.unicode.utf8ToUtf16LeStringLiteral(class_name_utf8);
    if (!std.mem.eql(u16, name[0..@intCast(n)], expect)) return null;
    const self = fromHwnd(parent) orelse return null;
    if (self.edit != hwnd) return null;
    return self;
}

/// True while the query field holds keyboard focus. The pane asks this to
/// answer `viewer_find.Focus.find`.
pub fn fieldFocused(self: *const ViewerFindBar) bool {
    return w32.GetFocus() == @as(?w32.HWND, self.edit);
}

// -------------------------------------------------------------------------
// Theme & layout
// -------------------------------------------------------------------------

/// Re-derive every color from the pane's background — the same one-source rule
/// the nav bar and the TOC card follow.
pub fn applyTheme(self: *ViewerFindBar) void {
    const bg = self.pane.bg;
    self.doc_rgb = bg;
    self.dark = !color_math.isLight(bg);
    self.card_rgb = banner_card.fillColor(bg);
    const text = chrome_theme.textOn(self.card_rgb);
    const secondary = chrome_theme.textSecondaryOn(self.card_rgb);
    self.text_ref = w32.RGB(text.r, text.g, text.b);
    self.secondary_ref = w32.RGB(secondary.r, secondary.g, secondary.b);
    // The field is a step off the card — darker in dark mode, lighter in light
    // — so it reads as a well rather than as paint missing from the card.
    const d: i32 = if (self.dark) -14 else 14;
    self.field_rgb = .{
        .r = icon_button.shadeChannel(self.card_rgb.r, d),
        .g = icon_button.shadeChannel(self.card_rgb.g, d),
        .b = icon_button.shadeChannel(self.card_rgb.b, d),
    };
    if (self.edit_brush) |b| _ = w32.DeleteObject(@ptrCast(b));
    self.edit_brush = w32.CreateSolidBrush(w32.RGB(
        self.field_rgb.r,
        self.field_rgb.g,
        self.field_rgb.b,
    ));
    _ = w32.SetWindowTheme(
        self.edit,
        if (self.dark)
            std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Explorer"),
        null,
    );
    self.releaseCardSurface();
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

/// Position the card in the pane's CONTENT rect and lay its controls out.
///
/// `content_top` is where the page starts — below the nav bar's band while
/// that is showing — so the card moves down with the content instead of
/// sliding under the bar, exactly as Mac anchors it to the web view's top
/// rather than the pane's.
///
/// Returns false when this pane is too narrow to hold a legible card, which is
/// also the answer to "should it be visible at all".
pub fn place(self: *ViewerFindBar, content_top: i32, content_w: i32, scale: f32) bool {
    self.ensureFonts(scale);
    self.content_w = content_w;
    const l = self.currentLayout(content_w);
    if (!l.fits()) {
        _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
        return false;
    }
    _ = w32.MoveWindow(
        self.hwnd,
        l.card.left,
        content_top + l.card.top,
        l.card.width(),
        l.card.height(),
        1,
    );
    _ = w32.MoveWindow(
        self.edit,
        l.field.left,
        l.field.top,
        @max(l.field.width(), 0),
        l.field.height(),
        1,
    );
    self.applyCornerRegion(l.card.width(), l.card.height());
    return true;
}

/// Clip the card window to its rounded silhouette (T1391).
///
/// The card surface is composited onto a backdrop of `doc_rgb` — the pane's
/// background — and then blitted over the whole window rect, corners included.
/// So before this the four corners shipped an ASSUMED colour on top of whatever
/// was really there, and over anything that is not exactly `pane.bg` (a
/// document, a light page, a selection) the rounding stopped reading as
/// rounding: you saw a square plate with a lighter rounded inset. Clipping the
/// WINDOW means those pixels are never painted at all, which is correct over
/// any content — the same treatment the TOC card's compact mode already gets,
/// for the same reason.
///
/// This runs from `place`, so it re-applies on every resize and every DPI
/// change rather than leaving a region cut for the old size or the old scale.
fn applyCornerRegion(self: *ViewerFindBar, w: i32, h: i32) void {
    const r = find.cornerRegion(w, h, self.scale);
    // The system owns the region on success. On failure `CreateRoundRectRgn`
    // hands us null, `SetWindowRgn` reads that as "no region", and the card
    // keeps the square corners it had before this existed — a worse card, not
    // a broken one.
    const rgn = w32.CreateRoundRectRgn(0, 0, r.right, r.bottom, r.ellipse, r.ellipse);
    _ = w32.SetWindowRgn(self.hwnd, rgn, 1);

    if (w == self.logged_card_w and h == self.logged_card_h) return;
    self.logged_card_w = w;
    self.logged_card_h = h;
    log.info("viewer find card pane={s} card={d}x{d} ellipse={d}", .{
        self.pane.paneId(),
        w,
        h,
        r.ellipse,
    });
}

/// Show the card, raising it above the WebView2 sibling so it floats over the
/// document (the TOC card's arrangement, for the same reason).
pub fn show(self: *ViewerFindBar) void {
    _ = w32.SetWindowPos(
        self.hwnd,
        null, // HWND_TOP
        0,
        0,
        0,
        0,
        w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
    );
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

pub fn hide(self: *ViewerFindBar) void {
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);
}

/// Put the caret in the query field with the whole query selected — the
/// browser rule, so the next keystroke replaces a resumed search rather than
/// appending to it. Same rule `ViewerNavBar.focusAddress` follows.
pub fn focusField(self: *ViewerFindBar) void {
    _ = w32.SetFocus(self.edit);
    _ = w32.SendMessageW(self.edit, w32.EM_SETSEL, 0, -1);
}

/// The query as UTF-8, into `buf`.
pub fn queryText(self: *ViewerFindBar, buf: []u8) []const u8 {
    var wide: [query_cap_utf16]u16 = undefined;
    const n = w32.GetWindowTextW(self.edit, &wide, wide.len);
    if (n <= 0) return "";
    const len = utf16_text.toUtf8Truncating(buf, wide[0..@intCast(n)]);
    return buf[0..len];
}

/// Buffer size a caller needs for `queryText`. UTF-8 is at most three bytes
/// per UTF-16 unit outside the surrogate range, and a surrogate PAIR is four
/// bytes for two units — so 3x is the bound.
pub const query_utf8_cap: usize = query_cap_utf16 * 3;

/// What the page reported. The pane has already checked that the count belongs
/// to the query currently in the field.
pub fn setResult(self: *ViewerFindBar, result: find.Result, note: ?[]const u8) bool {
    const text = note orelse "";
    const kept = if (text.len <= self.note.len) text else text[0..self.note.len];
    const note_changed = kept.len != self.note_len or
        !std.mem.eql(u8, self.note[0..self.note_len], kept);
    if (std.meta.eql(self.result, result) and !note_changed) return false;
    self.result = result;
    @memcpy(self.note[0..kept.len], kept);
    self.note_len = kept.len;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
    // The note is a whole extra LINE, so its arrival or departure changes the
    // card's height — the caller has to re-place, not just repaint.
    return note_changed;
}

/// Forget the last count without touching the query, so a card reopened over a
/// new document does not flash yesterday's "3/17" before the page answers.
pub fn clearResult(self: *ViewerFindBar) void {
    self.result = .none;
    self.note_len = 0;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
}

// -------------------------------------------------------------------------
// Main-loop hooks (the EDIT's keys and clicks)
// -------------------------------------------------------------------------

/// Enter / Shift-Enter and Escape while the query field holds focus, routed
/// here by the main message loop (an EDIT never delivers these itself).
/// Returns true when consumed.
///
/// The DECISION is `viewer_find.fieldKeyAction`'s, not this function's: with
/// the caret in this field the address bar cannot also have it, so the answer
/// is fixed — but routing it through the one precedence table is what keeps
/// the two fields' rules from drifting apart.
pub fn handleEditKey(self: *ViewerFindBar, vk: u16) bool {
    const mods: find.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    const action = find.fieldKeyAction(vk, mods, .{
        .find = true,
        .find_open = true,
    }) orelse return false;
    switch (action) {
        .close_find => self.pane.closeFind(),
        .find_next => self.pane.stepFind(1),
        .find_previous => self.pane.stepFind(-1),
        // Not reachable with `find` focused, and answering them here would be
        // acting on another field's behalf.
        .revert_address, .clear_diff_filter => return false,
    }
    return true;
}

/// The pane-scoped chords while the query field holds focus: the chords belong
/// to the PANE, and this card is inside the pane — so ctrl+F re-selects the
/// query and ctrl+G / F3 step without the caret having to leave. Routed by the
/// main message loop like `handleEditKey`.
pub fn handleEditChord(self: *ViewerFindBar, vk: u16) bool {
    const mods: input.Mods = .{
        .ctrl = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0,
        .shift = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0,
        .alt = w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0,
        .super = w32.GetKeyState(@as(i32, w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@as(i32, w32.VK_RWIN)) < 0,
    };
    const chord = viewer_accel.paneChord(vk, mods) orelse return false;
    self.pane.handlePaneChord(chord);
    return true;
}

pub fn noteClickDown(self: *ViewerFindBar) void {
    self.select_on_up = w32.GetFocus() != @as(?w32.HWND, self.edit);
}

pub fn noteClickUp(self: *ViewerFindBar) void {
    if (!self.select_on_up) return;
    self.select_on_up = false;
    _ = w32.PostMessageW(self.hwnd, WM_APP_SELECT_ALL, 0, 0);
}

// -------------------------------------------------------------------------
// Painting & input
// -------------------------------------------------------------------------

fn ensureFonts(self: *ViewerFindBar, scale: f32) void {
    if (self.scale == scale and self.font != null) return;
    self.scale = scale;
    if (self.font) |f| _ = w32.DeleteObject(@ptrCast(f));
    if (self.note_font) |f| _ = w32.DeleteObject(@ptrCast(f));
    self.font = makeFont(type_ramp.body(scale));
    self.note_font = makeFont(type_ramp.caption(scale));
    if (self.font) |f| _ = w32.SendMessageW(self.edit, w32.WM_SETFONT, @intFromPtr(f), 1);
}

fn makeFont(ramp: type_ramp.Font) ?*anyopaque {
    return w32.CreateFontW(
        -ramp.height,
        0,
        0,
        0,
        ramp.weight,
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

/// The count's rendered width, measured rather than estimated: "No results"
/// and "3/17" are different widths in the same font, and a card that always
/// reserved the wider of them would have a visible hole in it most of the
/// time.
fn measureCount(self: *ViewerFindBar) i32 {
    var buf: [find.Result.label_cap]u8 = undefined;
    const text = self.result.label(&buf, self.hasQuery()) orelse return 0;
    const hdc = w32.GetDC(self.hwnd) orelse return 0;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const old = if (self.font) |f| w32.SelectObject(hdc, @ptrCast(f)) else null;
    defer if (old) |o| {
        _ = w32.SelectObject(hdc, o);
    };
    var wide: [find.Result.label_cap]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text) catch return 0;
    var size: w32.SIZE = undefined;
    if (w32.GetTextExtentPoint32W(hdc, wide[0..n].ptr, @intCast(n), &size) == 0) return 0;
    return size.cx;
}

fn hasQuery(self: *ViewerFindBar) bool {
    return w32.GetWindowTextLengthW(self.edit) > 0;
}

/// The layout for a given content width, with the count measured and the note
/// counted. `content_w` of zero asks for the layout of the width the card was
/// last PLACED for — which is what every paint and hit test wants, and what
/// keeps them from disagreeing with the placement about where a button is.
fn currentLayout(self: *ViewerFindBar, content_w: i32) find.Layout {
    const w = if (content_w > 0) content_w else self.content_w;
    return find.layout(self.scale, w, self.measureCount(), self.note_len > 0);
}

fn paint(self: *ViewerFindBar, hdc: w32.HDC, width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const l = self.currentLayout(0);

    // The glass card, rendered once by the shared renderer and blitted. The
    // window IS the card, so the band's center crop lands at the origin — the
    // TOC card's compact arrangement, for the same reason.
    const margin = @as(i32, @intFromFloat(@round(banner_card.MARGIN * self.scale)));
    self.ensureCardSurface(hdc, width + 2 * margin, height + 2 * margin);
    if (self.card_dc) |mem| {
        _ = w32.BitBlt(hdc, 0, 0, width, height, mem, margin, margin, w32.SRCCOPY);
    } else {
        // No surface: a flat fill still reads as a card against the document,
        // which is a great deal better than an unpainted hole.
        const ref = w32.RGB(self.card_rgb.r, self.card_rgb.g, self.card_rgb.b);
        if (w32.CreateSolidBrush(ref)) |brush| {
            defer _ = w32.DeleteObject(@ptrCast(brush));
            var r = w32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
            _ = w32.FillRect(hdc, &r, brush);
        }
    }

    // The field's well, painted under the EDIT so the control sits in a recess
    // rather than floating on the card.
    if (l.field.width() > 0) {
        const ref = w32.RGB(self.field_rgb.r, self.field_rgb.g, self.field_rgb.b);
        if (w32.CreateSolidBrush(ref)) |brush| {
            defer _ = w32.DeleteObject(@ptrCast(brush));
            var r = w32.RECT{
                .left = l.field.left,
                .top = l.field.top,
                .right = l.field.right,
                .bottom = l.field.bottom,
            };
            _ = w32.FillRect(hdc, &r, brush);
        }
    }

    const m = icon_button.Metrics.init(self.scale);

    // The leading magnifier: a label for the field, not a button, so it paints
    // no fill and answers no hover.
    icon_paint.glyph(
        hdc,
        m,
        l.glyph,
        .search,
        self.secondary_ref,
    );

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    // The count.
    if (l.count.width() > 0) {
        var buf: [find.Result.label_cap]u8 = undefined;
        if (self.result.label(&buf, self.hasQuery())) |text| {
            const old = if (self.font) |f| w32.SelectObject(hdc, @ptrCast(f)) else null;
            defer if (old) |o| {
                _ = w32.SelectObject(hdc, o);
            };
            // A count of zero is stated in the secondary color: "No results" is
            // information, not an error, and painting it in the body color
            // would make an ordinary miss look like a failure.
            _ = w32.SetTextColor(
                hdc,
                if (self.result.total > 0) self.text_ref else self.secondary_ref,
            );
            drawText(hdc, text, l.count, w32.DT_RIGHT);
        }
    }

    // The controls. Stepping is dead with nothing to step to, and a disabled
    // button never lights — the design system's own state table.
    for (std.enums.values(find.Button)) |b| {
        const box = l.button(b);
        if (box.width() <= 0) continue;
        const enabled = self.buttonEnabled(b);
        const state: icon_button.State = st: {
            if (!enabled) break :st .normal;
            if (self.pressed == b) break :st .pressed;
            if (self.hover == b and self.pressed == null) break :st .hover;
            break :st .normal;
        };
        if (icon_button.paintsFill(state)) {
            const d = icon_button.fillDelta(state, self.dark);
            const fill = w32.RGB(
                icon_button.shadeChannel(self.card_rgb.r, d),
                icon_button.shadeChannel(self.card_rgb.g, d),
                icon_button.shadeChannel(self.card_rgb.b, d),
            );
            const f = icon_button.fillRegion(m, box);
            if (w32.CreateRoundRectRgn(f.left, f.top, f.right, f.bottom, f.ellipse, f.ellipse)) |rgn| {
                defer _ = w32.DeleteObject(rgn);
                if (w32.CreateSolidBrush(fill)) |brush| {
                    defer _ = w32.DeleteObject(@ptrCast(brush));
                    _ = w32.FillRgn(hdc, rgn, @ptrCast(brush));
                }
            }
        }
        const g = buttonGlyph(b);
        const color = if (enabled) self.text_ref else self.secondary_ref;
        icon_paint.glyph(hdc, m, icon_button.glyphTarget(m, box, g), g, color);
    }

    // The honesty line — what the page says it is NOT searching.
    if (l.note.width() > 0 and self.note_len > 0) {
        const old = if (self.note_font) |f| w32.SelectObject(hdc, @ptrCast(f)) else null;
        defer if (old) |o| {
            _ = w32.SelectObject(hdc, o);
        };
        _ = w32.SetTextColor(hdc, self.secondary_ref);
        drawText(hdc, self.note[0..self.note_len], l.note, w32.DT_LEFT);
    }
}

fn drawText(hdc: w32.HDC, text: []const u8, box: find.Rect, flags: u32) void {
    var wide: [note_cap]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text) catch return;
    var r = w32.RECT{
        .left = box.left,
        .top = box.top,
        .right = box.right,
        .bottom = box.bottom,
    };
    _ = w32.DrawTextW(
        hdc,
        wide[0..n].ptr,
        @intCast(n),
        &r,
        flags | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
    );
}

fn buttonEnabled(self: *const ViewerFindBar, b: find.Button) bool {
    return switch (b) {
        // Stepping with nothing found is not a command, it is a no-op the user
        // would press twice wondering why.
        .previous, .next => self.result.total > 0,
        .close => true,
    };
}

fn buttonGlyph(b: find.Button) icon_button.Glyph {
    return switch (b) {
        // The same chevrons the nav bar uses for next/previous CHANGE in a
        // diff pane, deliberately: they are the platform's "step through a
        // list" glyphs, and a second pair would read as a different KIND of
        // action rather than a different list. What keeps the two apart is
        // where they are and what their tooltips say.
        .previous => .chevron_up,
        .next => .chevron_down,
        .close => .close,
    };
}

fn ensureCardSurface(self: *ViewerFindBar, hdc: w32.HDC, w: i32, h: i32) void {
    const stale = self.card_dc == null or self.card_w != w or self.card_h != h or
        !std.meta.eql(self.card_bg, self.doc_rgb) or self.card_scale != self.scale;
    if (!stale) return;
    self.releaseCardSurface();
    if (w <= 0 or h <= 0) return;

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
        self.doc_rgb,
    );

    self.card_dc = mem_dc;
    self.card_bmp = bmp;
    self.card_w = w;
    self.card_h = h;
    self.card_bg = self.doc_rgb;
    self.card_scale = self.scale;
}

fn releaseCardSurface(self: *ViewerFindBar) void {
    if (self.card_bmp) |b| _ = w32.DeleteObject(b);
    if (self.card_dc) |d| _ = w32.DeleteDC(d);
    self.card_bmp = null;
    self.card_dc = null;
    self.card_w = 0;
    self.card_h = 0;
}

fn updateHover(self: *ViewerFindBar, x: i32, y: i32) void {
    const l = self.currentLayout(0);
    const hot = l.hitButton(self.scale, x, y);
    const hot_enabled: ?find.Button = if (hot) |b|
        (if (self.buttonEnabled(b)) b else null)
    else
        null;
    if (hot_enabled == self.hover) return;
    self.hover = hot_enabled;
    _ = w32.InvalidateRect(self.hwnd, null, 1);
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
        // The same card into a caller's DC, so a pixel probe photographs it
        // synchronously rather than through DWM's asynchronous copy (T835/T940).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var r: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &r) == 0) return 0;
            self.paint(@ptrFromInt(wparam), r.right - r.left, r.bottom - r.top);
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            self.updateHover(x, y);
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
            if (self.hover != null or self.pressed != null) {
                self.hover = null;
                self.pressed = null;
                _ = w32.InvalidateRect(hwnd, null, 1);
            }
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            const l = self.currentLayout(0);
            if (l.hitButton(self.scale, x, y)) |b| {
                if (self.buttonEnabled(b)) {
                    self.pressed = b;
                    _ = w32.SetCapture(hwnd);
                    _ = w32.InvalidateRect(hwnd, null, 1);
                }
            }
            return 0;
        },

        w32.WM_LBUTTONUP => {
            const x: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
            const y: i32 = @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
            _ = w32.ReleaseCapture();
            const was = self.pressed;
            self.pressed = null;
            _ = w32.InvalidateRect(hwnd, null, 1);
            if (was) |b| {
                const l = self.currentLayout(0);
                if (l.hitButton(self.scale, x, y) == b) self.activate(b);
            }
            return 0;
        },

        WM_APP_SELECT_ALL => {
            _ = w32.SendMessageW(self.edit, w32.EM_SETSEL, 0, -1);
            return 0;
        },

        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, self.text_ref);
            _ = w32.SetBkColor(hdc, w32.RGB(self.field_rgb.r, self.field_rgb.g, self.field_rgb.b));
            if (self.edit_brush) |b| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_COMMAND => {
            const code: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const id: u16 = @intCast(wparam & 0xFFFF);
            if (id != edit_id) return 0;
            switch (code) {
                // Every keystroke is pushed straight through, with no debounce:
                // the page caches its text index between keystrokes and rebuilds
                // it only when the DOM actually moves, so a keystroke costs a
                // scan of a buffer that is already built (Mac's `setFindQuery`
                // makes the same call for the same reason).
                w32.EN_CHANGE => self.pane.findQueryChanged(),
                w32.EN_SETFOCUS => {
                    // A KEYBOARD arrival (tab, the chord) selects all; a click
                    // arrival is handled by noteClickDown/Up. The click case is
                    // distinguishable: the mouse is down over us.
                    if (w32.GetKeyState(w32.VK_LBUTTON) >= 0) {
                        _ = w32.SendMessageW(self.edit, w32.EM_SETSEL, 0, -1);
                    }
                },
                else => {},
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// A control click, delivered on mouse-up over the same control it went down
/// on. Everything routes to the pane — the card knows how to paint a chevron,
/// not what "next match" means.
fn activate(self: *ViewerFindBar, b: find.Button) void {
    // Part of the T1184 oracle: the POINTER route, which is otherwise
    // indistinguishable from the keyboard one in the count line it produces.
    log.info("viewer find control={s}", .{@tagName(b)});
    switch (b) {
        .previous => self.pane.stepFind(-1),
        .next => self.pane.stepFind(1),
        .close => self.pane.closeFind(),
    }
}

// T467: the card's field stretches and its cluster is anchored to the right
// edge, so a width change re-lays out every control. `place()` resizes with
// `MoveWindow(.., TRUE)`, which paints the update region — the class style is
// what decides that the region is the whole card and not the sliver the widen
// uncovered.
test "viewer find class: a resize invalidates the whole card" {
    const hinst = w32.GetModuleHandleW(null) orelse return error.SkipZigTest;
    registerClass(hinst);
    if (!class_registered) return error.SkipZigTest;
    try class_redraw.expectResizeInvalidatesWholeClient(CLASS_NAME);
}
