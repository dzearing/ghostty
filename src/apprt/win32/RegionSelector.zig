//! The screenshot region selector (T647): a full-desktop overlay showing a
//! dimmed photograph of the screen, out of which the user drags the rectangle
//! that becomes a feedback screenshot.
//!
//! This is D44's recommended answer built. The two Windows-native alternatives
//! — `ms-screenclip:` and `SnippingTool /clip` — both hand their result over
//! through the CLIPBOARD, and the whole point of a capture inside a feedback
//! composer is that it does not cost the user whatever they had copied. Mac's
//! `screencapture -i -o` is explicit about the same thing (`-o`, never `-c`),
//! so a Windows build that clobbered the clipboard would not be a translation
//! of the feature, it would be a different one.
//!
//! ## How it works, and why in that order
//!
//! 1. Photograph the whole virtual screen ONCE (`screen_capture.zig`), before
//!    this window exists. A second grab at the end would photograph this
//!    overlay instead of the desktop.
//! 2. Precompute a DIMMED copy of that photograph. Both are DIB sections, so
//!    every repaint is two `BitBlt`s — the dim everywhere, the original inside
//!    the selection — rather than a per-pixel pass at mouse-move rate.
//! 3. Show an opaque popup covering the virtual screen, take the drag, and on
//!    mouse-up crop the ORIGINAL photograph.
//!
//! Opaque rather than `WS_EX_LAYERED`: the window shows a picture of the
//! desktop, so there is nothing to be transparent to, and a layered
//! full-desktop window is the shape most likely to go wrong under an
//! aggressive foreground lock.
//!
//! ## Coordinates
//!
//! The window is placed AT the virtual screen's bounds, so its client
//! coordinates are the snapshot's own buffer coordinates and a message's
//! lparam needs no translation. Only the crop converts back to virtual-screen
//! coordinates, by adding the bounds origin. Rect math is in the pure
//! `region_select.zig`.
//!
//! ## Driving it without a mouse
//!
//! Every input this handles arrives as an ordinary window message read out of
//! `wparam`/`lparam` — nothing calls `GetCursorPos` or `GetKeyState`. That is
//! deliberate: the acceptance suite runs on a background desktop where
//! `SendInput` is dead (T233), so a drag has to be postable. `PostMessageW` of
//! `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` / `WM_LBUTTONUP` (and `WM_KEYDOWN`
//! `VK_ESCAPE`) is a complete script for this window.

const RegionSelector = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const region = @import("region_select.zig");
const screen_capture = @import("screen_capture.zig");
const type_ramp = @import("type_ramp.zig");

const log = std.log.scoped(.viewer_feedback);

pub const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyRegionSelect");

const ui_face = std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face);

/// "The drag is over; deliver the result and go away." Posted to itself rather
/// than run inline, so the object is torn down from a message of its own rather
/// than from the middle of the mouse message that ended the drag.
const WM_APP_FINISH: u32 = w32.WM_APP + 7;

/// What the overlay says while nothing is selected yet.
const hint_text = "Drag to capture  ·  Esc to cancel";

/// Called exactly once per selector, with the captured PNG or null when the
/// user cancelled. The bytes belong to the SELECTOR and are freed as soon as
/// this returns, so a callback that wants to keep them copies them (the
/// composer does not need to: `attachImage` copies into the pane's store).
pub const OnDone = *const fn (ctx: *anyopaque, png: ?[]const u8) void;

alloc: Allocator,
hwnd: w32.HWND,
ctx: *anyopaque,
on_done: OnDone,

/// The desktop as it was when the capture began.
snap: screen_capture.Snapshot,
/// The same picture, darkened. Owned here; `deinit` frees both.
dim: w32.HANDLE,

/// Where the drag started, in client (= snapshot buffer) coordinates. Null
/// until the button goes down.
anchor: ?region.Point = null,
/// Where the pointer is now. Only meaningful while `anchor` is set.
cursor: region.Point = .{ .x = 0, .y = 0 },
/// The selection painted last, so a mouse-move can invalidate the OLD rect as
/// well as the new one instead of the whole desktop.
painted: ?region.Rect = null,

/// The monitor the pointer was on when the capture began, in client
/// coordinates — where the hint card goes.
home: region.Rect,
scale: f32,
font: ?*anyopaque = null,

/// Set once the result has been handed over, so a second mouse-up or a stray
/// Escape arriving behind it cannot deliver twice.
finished: bool = false,

/// The captured PNG, held between `finish` (which crops it) and the posted
/// `WM_APP_FINISH` that delivers it and tears the window down.
result: ?[]u8 = null,

/// Whether the overlay ever held activation. Losing something it never had is
/// not a reason to cancel — and it is the common case where the foreground
/// could not be taken at all, which must leave the overlay usable by mouse
/// rather than tearing it down before the user has seen it.
activated: bool = false,

/// The hint card's rect, measured once in `begin`. Kept because the card has to
/// be INVALIDATED when it stops being drawn: paint only touches the rect it was
/// asked for, so a card nobody invalidates stays on screen under the drag it
/// was telling the user to make.
hint_rect: region.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

var class_registered: bool = false;

fn registerClass(hinstance: ?w32.HINSTANCE) void {
    if (class_registered) return;
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        // Null, and set per-message in WM_SETCURSOR: a class cursor would be
        // re-applied by USER32 on every mouse move anyway, and this way the
        // crosshair is one decision in one place.
        .hCursor = null,
        .hbrBackground = null, // every pixel is painted
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("region selector class registration failed", .{});
        return;
    }
    class_registered = true;
}

/// Photograph the desktop and put the selector up over it. Null when there is
/// no picture to select out of or the window cannot be made — the caller then
/// simply gets no screenshot, which is the same outcome as a cancel.
///
/// `owner` is the pane's top-level window, so the overlay can never end up
/// behind the window whose content the user is reporting on, and dies with it.
pub fn begin(
    alloc: Allocator,
    hinstance: ?w32.HINSTANCE,
    owner: ?w32.HWND,
    scale: f32,
    ctx: *anyopaque,
    on_done: OnDone,
) ?*RegionSelector {
    registerClass(hinstance);
    if (!class_registered) return null;

    // Every failure below unwinds by hand rather than with `errdefer`: this
    // returns an OPTIONAL, not an error union, so an errdefer here would be
    // dead code and each of these two buffers is the size of the desktop.
    const snap = screen_capture.capture() orelse return null;

    const dim = dimCopy(snap) orelse {
        snap.deinit();
        return null;
    };

    const self = alloc.create(RegionSelector) catch {
        _ = w32.DeleteObject(dim);
        snap.deinit();
        return null;
    };

    const b = snap.bounds;
    self.* = .{
        .alloc = alloc,
        .hwnd = undefined,
        .ctx = ctx,
        .on_done = on_done,
        .snap = snap,
        .dim = dim,
        .home = homeMonitor(b),
        .scale = scale,
    };

    // WS_EX_TOOLWINDOW keeps it out of the taskbar and Alt-Tab; it is a modal
    // gesture, not a window anybody navigates to. NOT WS_EX_NOACTIVATE — this
    // one has to take the keyboard, because Escape is how it is cancelled.
    const hwnd = w32.CreateWindowExW(
        w32.WS_EX_TOPMOST | w32.WS_EX_TOOLWINDOW,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        b.x,
        b.y,
        b.w,
        b.h,
        owner,
        null,
        hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        _ = w32.DeleteObject(dim);
        snap.deinit();
        return null;
    };
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.font = w32.CreateFontW(
        -type_ramp.body(scale).height,
        0,
        0,
        0,
        type_ramp.body(scale).weight,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        w32.ANTIALIASED_QUALITY,
        0,
        ui_face,
    );
    self.measureHint();

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(hwnd);

    log.info("viewer feedback capture=begin bounds={d},{d} {d}x{d}", .{ b.x, b.y, b.w, b.h });
    return self;
}

/// Take the overlay down WITHOUT delivering anything — what the composer calls
/// when it is destroyed while a capture is still up. The callback is not
/// invoked, because the thing that would receive it is going away.
pub fn cancel(self: *RegionSelector) void {
    self.finished = true;
    self.destroy();
}

fn destroy(self: *RegionSelector) void {
    // Cleared FIRST: DestroyWindow delivers messages synchronously, and they
    // must not find a half-dead object.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.font) |f| _ = w32.DeleteObject(f);
    _ = w32.DeleteObject(self.dim);
    self.snap.deinit();
    self.alloc.destroy(self);
}

/// The monitor the pointer is on, in the snapshot's client coordinates, so the
/// hint card lands on the screen the user is looking at. Falls back to the
/// whole virtual screen when the pointer cannot be located — a hint in the
/// middle of a two-monitor desktop is worse than ideal, never wrong.
fn homeMonitor(bounds: region.Rect) region.Rect {
    var pt: w32.POINT = .{ .x = 0, .y = 0 };
    if (w32.GetCursorPos_(&pt) == 0) return .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h };
    const mon = w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST) orelse
        return .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h };
    var mi: w32.MONITORINFO = .{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
    };
    if (w32.GetMonitorInfoW(mon, &mi) == 0) {
        return .{ .x = 0, .y = 0, .w = bounds.w, .h = bounds.h };
    }
    return .{
        .x = mi.rcMonitor.left - bounds.x,
        .y = mi.rcMonitor.top - bounds.y,
        .w = mi.rcMonitor.right - mi.rcMonitor.left,
        .h = mi.rcMonitor.bottom - mi.rcMonitor.top,
    };
}

/// A darkened copy of the snapshot, as a DIB section of the same geometry.
///
/// Computed once here rather than composited per paint: `AlphaBlend`ing a
/// stretched 1x1 source over a 4K desktop on every mouse move is a lot of work
/// to repeat, and the answer never changes. One pass over the pixels is ~8M
/// multiplies for a 4K screen and happens while the user is still reaching for
/// the mouse.
fn dimCopy(snap: screen_capture.Snapshot) ?w32.HANDLE {
    var bits_ptr: ?*anyopaque = null;
    const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{
        .biWidth = snap.bounds.w,
        .biHeight = -snap.bounds.h,
        .biBitCount = 32,
    } };
    const section = w32.CreateDIBSection(
        null,
        &bmi,
        w32.DIB_RGB_COLORS,
        &bits_ptr,
        null,
        0,
    ) orelse return null;
    const dst: [*]u8 = @ptrCast(bits_ptr orelse {
        _ = w32.DeleteObject(section);
        return null;
    });

    const count: usize = @as(usize, @intCast(snap.bounds.w)) *
        @as(usize, @intCast(snap.bounds.h)) * 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        dst[i] = @intCast((@as(u32, snap.bits[i]) * region.dim_numerator) >> 8);
    }
    return section;
}

// ------------------------------------------------------------------- drawing

/// The selection as it stands, in client coordinates. Null before the drag
/// starts and for any drag with no area.
fn selection(self: *const RegionSelector) ?region.Rect {
    const a = self.anchor orelse return null;
    return region.selection(a, self.cursor, .{
        .x = 0,
        .y = 0,
        .w = self.snap.bounds.w,
        .h = self.snap.bounds.h,
    });
}

/// Repaint just what moved: the rect that was drawn last and the one that
/// replaces it, each grown by the outline so its two-pixel edge is included.
///
/// Plus the hint card whenever it changes state. The card is drawn only while
/// there is no selection, and `WM_PAINT` only ever touches the rect it was
/// asked for — so a card whose rect nobody invalidates stays on screen
/// underneath the drag it was telling the user to make.
fn invalidateSelection(self: *RegionSelector, next: ?region.Rect) void {
    if ((self.painted == null) != (next == null)) self.invalidate(self.hint_rect, 0);
    const grow = region.px(region.border_dip, self.scale) + 1;
    for ([_]?region.Rect{ self.painted, next }) |maybe| {
        self.invalidate(maybe orelse continue, grow);
    }
    self.painted = next;
}

fn invalidate(self: *RegionSelector, r: region.Rect, grow: i32) void {
    if (r.w <= 0 or r.h <= 0) return;
    var rc: w32.RECT = .{
        .left = r.x - grow,
        .top = r.y - grow,
        .right = r.right() + grow,
        .bottom = r.bottom() + grow,
    };
    _ = w32.InvalidateRect(self.hwnd, &rc, 0);
}

/// Measure the hint card once, at creation, into `hint_rect`. Measured rather
/// than assumed because the card is sized to its TEXT, and the text is measured
/// in whatever face and size the type ramp resolved to at this scale.
fn measureHint(self: *RegionSelector) void {
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const old_font = if (self.font) |f| w32.SelectObject(hdc, f) else null;
    defer if (self.font != null) {
        _ = w32.SelectObject(hdc, old_font);
    };

    var buf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, hint_text) catch return;
    var size: w32.SIZE = .{ .cx = 0, .cy = 0 };
    if (w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size) == 0) return;
    self.hint_rect = region.hintBox(self.home, self.scale, size.cx, size.cy);
}

fn paint(self: *RegionSelector, hdc: w32.HDC, clip: w32.RECT) void {
    const mem = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem);

    // The dim everywhere the paint asked for.
    const old_dim = w32.SelectObject(mem, self.dim);
    _ = w32.BitBlt(
        hdc,
        clip.left,
        clip.top,
        clip.right - clip.left,
        clip.bottom - clip.top,
        mem,
        clip.left,
        clip.top,
        w32.SRCCOPY,
    );
    _ = w32.SelectObject(mem, old_dim);

    if (self.selection()) |sel| {
        // The original, bright, inside the selection.
        const old_snap = w32.SelectObject(mem, self.snap.section);
        _ = w32.BitBlt(hdc, sel.x, sel.y, sel.w, sel.h, mem, sel.x, sel.y, w32.SRCCOPY);
        _ = w32.SelectObject(mem, old_snap);
        self.drawOutline(hdc, sel);
        return;
    }

    self.drawHint(hdc);
}

/// The selection's outline: a white inner edge over a black outer one.
///
/// Two colours rather than one accent, and this is the 3:1 contrast floor
/// rather than decoration — a single-colour outline over a photograph of an
/// arbitrary desktop is guaranteed to be invisible somewhere. A white line
/// against black always clears the floor against at least one of its
/// neighbours no matter what is underneath.
fn drawOutline(self: *RegionSelector, hdc: w32.HDC, sel: region.Rect) void {
    const t = region.px(region.border_dip, self.scale);
    frame(hdc, sel, t, 0x00FFFFFF);
    frame(hdc, .{
        .x = sel.x - t,
        .y = sel.y - t,
        .w = sel.w + 2 * t,
        .h = sel.h + 2 * t,
    }, t, 0x00000000);
}

/// A `t`-thick rectangle drawn INSIDE `r`, as four fills. Four fills rather
/// than a pen: a wide GDI pen biases one side of the path, which is the same
/// reason the design system bans `LineTo` for glyphs.
fn frame(hdc: w32.HDC, r: region.Rect, t: i32, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    const sides = [_]w32.RECT{
        .{ .left = r.x, .top = r.y, .right = r.right(), .bottom = r.y + t },
        .{ .left = r.x, .top = r.bottom() - t, .right = r.right(), .bottom = r.bottom() },
        .{ .left = r.x, .top = r.y + t, .right = r.x + t, .bottom = r.bottom() - t },
        .{ .left = r.right() - t, .top = r.y + t, .right = r.right(), .bottom = r.bottom() - t },
    };
    for (sides) |s| {
        var rc = s;
        _ = w32.FillRect(hdc, &rc, brush);
    }
}

fn drawHint(self: *RegionSelector, hdc: w32.HDC) void {
    const card = self.hint_rect;
    if (card.w <= 0 or card.h <= 0) return;

    const old_font = if (self.font) |f| w32.SelectObject(hdc, f) else null;
    defer if (self.font != null) {
        _ = w32.SelectObject(hdc, old_font);
    };

    var buf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, hint_text) catch return;
    const radius = region.px(region.hint_radius_dip, self.scale);

    // A near-black card with white text: the overlay is a dimmed desktop, so a
    // theme-following surface would sometimes land light-on-light. This one
    // reads over any photograph.
    const brush = w32.CreateSolidBrush(0x00202020) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    const pen = w32.CreatePen(w32.PS_SOLID, 1, 0x00707070) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    const old_pen = w32.SelectObject(hdc, pen);
    _ = w32.RoundRect(
        hdc,
        card.x,
        card.y,
        card.right(),
        card.bottom(),
        radius * 2,
        radius * 2,
    );
    _ = w32.SelectObject(hdc, old_brush);
    _ = w32.SelectObject(hdc, old_pen);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, 0x00FFFFFF);
    _ = w32.TextOutW(
        hdc,
        card.x + region.px(region.hint_pad_x_dip, self.scale),
        card.y + region.px(region.hint_pad_y_dip, self.scale),
        &buf,
        @intCast(n),
    );
}

// --------------------------------------------------------------------- input

fn finish(self: *RegionSelector, sel: ?region.Rect) void {
    if (self.finished) return;
    self.finished = true;
    if (self.anchor != null) _ = w32.ReleaseCapture();
    // Down before the callback runs: the composer inserts a chip and repaints,
    // and a full-desktop overlay still on screen while that happens is a
    // flicker with the user's own window behind it.
    _ = w32.ShowWindow(self.hwnd, w32.SW_HIDE);

    if (sel) |r| {
        const virtual: region.Rect = .{
            .x = r.x + self.snap.bounds.x,
            .y = r.y + self.snap.bounds.y,
            .w = r.w,
            .h = r.h,
        };
        if (self.snap.crop(self.alloc, virtual)) |png| {
            self.result = png;
            log.info("viewer feedback capture=done rect={d},{d} {d}x{d} bytes={d}", .{
                virtual.x, virtual.y, virtual.w, virtual.h, png.len,
            });
        } else {
            log.warn("viewer feedback capture=failed rect={d}x{d}", .{ r.w, r.h });
        }
    } else {
        log.info("viewer feedback capture=cancelled", .{});
    }

    // Posted, not called: the teardown then runs from a message of the
    // selector's own rather than from inside the mouse message that ended the
    // drag. If the post cannot be made at all, deliver inline — a leaked
    // full-desktop window and a composer whose `+` never works again is a
    // worse answer than the re-entrancy this avoids.
    if (w32.PostMessageW(self.hwnd, WM_APP_FINISH, 0, 0) == 0) {
        log.warn("viewer feedback capture: could not post the finish; delivering inline", .{});
        self.deliver();
    }
}

fn deliver(self: *RegionSelector) void {
    const png = self.result;
    self.result = null;
    self.on_done(self.ctx, png);
    if (png) |p| self.alloc.free(p);
    self.destroy();
}

fn fromHwnd(hwnd: w32.HWND) ?*RegionSelector {
    const ud = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (ud == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ud)));
}

fn xOf(lparam: isize) i32 {
    return @intCast(@as(i16, @bitCast(@as(u16, @intCast(lparam & 0xFFFF)))));
}

fn yOf(lparam: isize) i32 {
    return @intCast(@as(i16, @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)))));
}

fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const self = fromHwnd(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SETCURSOR => {
            _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_CROSS));
            return 1;
        },

        w32.WM_ERASEBKGND => return 1, // WM_PAINT covers every pixel

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.paint(hdc, ps.rcPaint);
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const p: region.Point = .{ .x = xOf(lparam), .y = yOf(lparam) };
            self.anchor = p;
            self.cursor = p;
            _ = w32.SetCapture(hwnd);
            self.invalidateSelection(null);
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            if (self.anchor == null) return 0;
            self.cursor = .{ .x = xOf(lparam), .y = yOf(lparam) };
            self.invalidateSelection(self.selection());
            return 0;
        },

        w32.WM_LBUTTONUP => {
            if (self.anchor == null) return 0;
            self.cursor = .{ .x = xOf(lparam), .y = yOf(lparam) };
            // A click with no drag lands here with no selection, and that is a
            // CANCEL — never a zero-pixel picture, which would look like the
            // capture worked.
            self.finish(self.selection());
            return 0;
        },

        // Right-click is the other universal "not that" in a drag gesture.
        w32.WM_RBUTTONDOWN => {
            self.finish(null);
            return 0;
        },

        w32.WM_KEYDOWN => {
            if (wparam == w32.VK_ESCAPE) {
                self.finish(null);
                return 0;
            }
            return 0;
        },

        // Something took the overlay's activation away — another app's window,
        // a lock screen. Cancel rather than leave a full-desktop window up
        // behind whatever now has focus.
        w32.WM_ACTIVATE => {
            if (wparam != 0) {
                self.activated = true;
            } else if (self.activated and !self.finished) {
                self.finish(null);
            }
            return 0;
        },

        WM_APP_FINISH => {
            self.deliver();
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
