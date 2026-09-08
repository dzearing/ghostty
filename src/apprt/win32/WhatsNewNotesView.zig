//! The release-notes ACCESSORY (T625): a child control that shows what an
//! update changed, inside a dialog that is asking the user to accept a cost.
//!
//! Mac hangs `WhatsNewNotesView` off the mandatory agent-restart alert, so the
//! person being told "this closes your terminal sessions" can see what the
//! restart buys them before answering. The win32 confirmation had a title, a
//! body and two buttons: it named the cost and nothing else, and the answer
//! was made on trust.
//!
//! ## Why a child window rather than more `ConfirmDialog` paint code
//!
//! The notes SCROLL. A region with its own scroll offset, its own wheel
//! handling, its own thumb and its own link hit-testing is a control, and
//! giving it a window is what keeps all of that out of the dialog — which
//! otherwise grows a second, subtly different copy of the What's New window's
//! input handling. It also gives the harness something to find: the accessory
//! either exists as a `GhozttyWhatsNewNotes` child of the dialog or it does
//! not, and its window TEXT carries the model it is showing, so an acceptance
//! script can assert the notes are the RIGHT ones without photographing them.
//!
//! The pixels themselves are `whats_new_notes.Renderer` at `.compact` density
//! — the same walker the What's New window paints with. That sharing is the
//! point of the task: a second renderer would drift, and what it would drift
//! about is the only part of this the user ever sees.

const WhatsNewNotesView = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const layout = @import("whats_new_layout.zig");
const notes_render = @import("whats_new_notes.zig");
const panel_theme = @import("panel_theme.zig");
const release_notes = @import("release_notes.zig");
const system_colors = @import("system_colors.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyWhatsNewNotes");

var class_registered: bool = false;

const fillRect = notes_render.fillRect;
const cr = notes_render.cr;

alloc: Allocator,
hwnd: w32.HWND,
scale: f32,
/// The notes to show. Borrowed: the caller owns the store these slices point
/// into and outlives the modal loop this control lives inside.
split: release_notes.Partitioned,
renderer: notes_render.Renderer,
scroll: i32 = 0,
content_h: i32 = 0,
/// Grab offset while dragging the scroll thumb; -1 when not dragging.
thumb_drag_dy: i32 = -1,
hover_link: bool = false,
/// The app whose theme this paints from, and whose `openUrl` a clicked link
/// goes through. Null on the app-less dialog paths, which never carry notes.
app: ?*App,

/// Create the accessory inside `parent` at `rect` (parent client
/// coordinates). Returns null when the control could not be made, which the
/// caller treats as "no accessory" rather than as a failure: the dialog it
/// belongs to is the mandatory-update confirmation, and losing the evidence
/// must never lose the question.
pub fn create(
    alloc: Allocator,
    app: ?*App,
    hinstance: ?w32.HINSTANCE,
    parent: w32.HWND,
    rect: w32.RECT,
    scale: f32,
    split: release_notes.Partitioned,
) ?*WhatsNewNotesView {
    registerClass(hinstance) orelse return null;

    const self = alloc.create(WhatsNewNotesView) catch return null;
    self.* = .{
        .alloc = alloc,
        .app = app,
        .hwnd = undefined,
        .scale = scale,
        .split = split,
        .renderer = .init(alloc, scale, .compact, palFor(app)),
    };
    // The accessory answers one question — "what does this update buy me?" —
    // so it shows the fresh half and stops. The already-installed history is
    // the window's job, and a dialog is not where anyone browses it.
    self.renderer.fresh_only = true;

    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        parent,
        null,
        hinstance,
        null,
    ) orelse {
        self.renderer.deinit();
        alloc.destroy(self);
        return null;
    };
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.measureContent();
    self.publishModel();
    return self;
}

pub fn destroy(self: *WhatsNewNotesView) void {
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    self.renderer.deinit();
    self.alloc.destroy(self);
}

fn palFor(app: ?*App) panel_theme.Panel {
    return if (app) |a| system_colors.panelFor(a) else system_colors.panelSystem();
}

fn registerClass(hinstance: ?w32.HINSTANCE) ?void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // The notes wrap to the control's width, so a resize repaints all of
        // it rather than the newly exposed strip.
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("what's new accessory: class registration failed", .{});
        return null;
    }
    class_registered = true;
}

// ---------------------------------------------------------------------
// The model, published as window text
// ---------------------------------------------------------------------

/// Write what this accessory is showing into its window text, where a probe
/// can read it with WM_GETTEXT.
///
/// A screenshot cannot answer the question this accessory exists to settle —
/// whether the notes are the AGENT's, and whether they are the ones new since
/// the version the user was running — so the control says so itself. The
/// format is `releases=<n> notes=<n> height=<px>`, stable and parseable.
fn publishModel(self: *WhatsNewNotesView) void {
    var count: usize = 0;
    for (self.split.fresh) |notes| {
        for (notes.sections) |section| count += section.items.len;
    }
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "releases={d} notes={d} height={d}", .{
        self.split.fresh.len,
        count,
        self.content_h,
    }) catch return;
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
    wbuf[wlen] = 0;
    _ = w32.SetWindowTextW(self.hwnd, @ptrCast(&wbuf));
}

/// What the accessory is showing, for the dialog's log line.
pub fn releaseCount(self: *const WhatsNewNotesView) usize {
    return self.split.fresh.len;
}

// ---------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------

fn clientRect(self: *const WhatsNewNotesView) w32.RECT {
    var rc: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(self.hwnd, &rc);
    return rc;
}

/// The viewport and its scrollbar gutter, for the current client size.
const Frame = struct {
    viewport: layout.Rect,
    scrollbar: layout.Rect,
    text_w: i32,
};

fn frame(self: *const WhatsNewNotesView) Frame {
    const rc = self.clientRect();
    const m = self.renderer.metrics();
    const w = rc.right - rc.left;
    const h = rc.bottom - rc.top;
    const viewport: layout.Rect = .{
        .x = 0,
        .y = 0,
        .w = @max(0, w - m.scrollbar_w),
        .h = @max(0, h),
    };
    return .{
        .viewport = viewport,
        .scrollbar = .{ .x = viewport.w, .y = 0, .w = m.scrollbar_w, .h = viewport.h },
        .text_w = @max(0, viewport.w - 2 * m.margin),
    };
}

fn measureContent(self: *WhatsNewNotesView) void {
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const f = self.frame();
    const m = self.renderer.metrics();
    self.content_h = self.renderer.render(hdc, m.margin, 0, f.text_w, self.split, false);
    self.scroll = layout.clampScroll(self.scroll, self.content_h, f.viewport.h);
}

// ---------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------

fn paint(self: *WhatsNewNotesView, hdc: w32.HDC) void {
    const p = palFor(self.app);
    self.renderer.palette = p;
    const f = self.frame();
    const m = self.renderer.metrics();

    // The accessory is a WELL inside the dialog, not a second panel: the
    // deeper surface is what says "this is quoted material" without a border.
    fillRect(hdc, .{
        .x = 0,
        .y = 0,
        .w = f.viewport.w + f.scrollbar.w,
        .h = f.viewport.h,
    }, cr(p.well));
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    self.renderer.beginPaint();
    const saved = w32.SaveDC(hdc);
    _ = w32.IntersectClipRect(
        hdc,
        f.viewport.x,
        f.viewport.y,
        f.viewport.x + f.viewport.w,
        f.viewport.y + f.viewport.h,
    );
    self.content_h = self.renderer.render(
        hdc,
        m.margin,
        -self.scroll,
        f.text_w,
        self.split,
        true,
    );
    _ = w32.RestoreDC(hdc, saved);

    if (layout.thumb(f.scrollbar, self.content_h, self.scroll, m.wheel_step)) |t| {
        fillRect(hdc, t, cr(p.boundary));
    }
}

// ---------------------------------------------------------------------
// Scrolling + input
// ---------------------------------------------------------------------

pub fn scrollBy(self: *WhatsNewNotesView, dy: i32) void {
    self.scrollTo(self.scroll + dy);
}

fn scrollTo(self: *WhatsNewNotesView, y: i32) void {
    const f = self.frame();
    const next = layout.clampScroll(y, self.content_h, f.viewport.h);
    if (next == self.scroll) return;
    self.scroll = next;
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

fn onLeftDown(self: *WhatsNewNotesView, x: i32, y: i32) void {
    // A link under the pointer wins over a drag.
    if (self.renderer.linkAt(x, y)) |url| {
        if (self.app) |a| a.openUrl(url);
        return;
    }
    const f = self.frame();
    const m = self.renderer.metrics();
    if (layout.thumb(f.scrollbar, self.content_h, self.scroll, m.wheel_step)) |t| {
        if (t.contains(x, y)) {
            self.thumb_drag_dy = y - t.y;
            _ = w32.SetCapture(self.hwnd);
            return;
        }
        if (f.scrollbar.contains(x, y)) {
            self.scrollBy(if (y < t.y) -f.viewport.h else f.viewport.h);
        }
    }
}

fn onMouseMove(self: *WhatsNewNotesView, x: i32, y: i32) void {
    if (self.thumb_drag_dy >= 0) {
        const f = self.frame();
        const m = self.renderer.metrics();
        const t = layout.thumb(f.scrollbar, self.content_h, self.scroll, m.wheel_step) orelse return;
        const travel = @max(1, f.scrollbar.h - t.h);
        const want_y = y - self.thumb_drag_dy - f.scrollbar.y;
        const max_scroll = @max(0, self.content_h - f.scrollbar.h);
        self.scrollTo(@divTrunc(want_y * max_scroll, travel));
        return;
    }

    const over = self.renderer.linkAt(x, y) != null;
    if (over != self.hover_link) {
        self.hover_link = over;
        _ = w32.SetCursor(w32.LoadCursorW(
            null,
            if (over) w32.IDC_HAND else w32.IDC_ARROW,
        ));
    }
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *WhatsNewNotesView = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        // The control paints every pixel it owns, background included, so
        // letting the system erase first only buys a flash of the wrong color.
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps);
            if (hdc) |dc| self.paint(dc);
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        // The same pixels into a caller's DC, so a probe photographs this
        // control synchronously rather than through DWM's async copy (T835).
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            self.paint(@ptrFromInt(wparam));
            return 0;
        },
        w32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)));
            const m = self.renderer.metrics();
            const notches = @divTrunc(@as(i32, delta), w32.WHEEL_DELTA);
            self.scrollBy(-notches * m.wheel_step);
            return 0;
        },
        w32.WM_LBUTTONDOWN => {
            self.onLeftDown(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            self.onMouseMove(loWordSigned(lparam), hiWordSigned(lparam));
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (self.thumb_drag_dy >= 0) {
                self.thumb_drag_dy = -1;
                _ = w32.ReleaseCapture();
            }
            return 0;
        },
        w32.WM_SIZE => {
            self.measureContent();
            self.publishModel();
            _ = w32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn loWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF))));
}

fn hiWordSigned(lparam: isize) i32 {
    return @as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF))));
}
