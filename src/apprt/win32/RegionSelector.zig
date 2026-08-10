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
//!
//! ## The keyboard (T671)
//!
//! That property is also what makes a real keyboard path possible, so the
//! selector has one: arrows move a caret, Ctrl+arrow moves it 32 px at a time,
//! Enter pins the first corner and Enter again captures, Shift+arrow is the
//! shortcut that does both in one press, and Escape still cancels. Space is
//! left alone on purpose — it is what Mac's `screencapture -i` uses to switch
//! to picking a whole window, which is T670. The rules
//! are pure (`region_select.zig`: `moveCaret` / `dropAnchor`), so the keyboard
//! and the mouse drive the SAME `anchor`/`cursor` pair and can be interleaved.
//!
//! Modifiers are tracked from the `WM_KEYDOWN`/`WM_KEYUP` of `VK_SHIFT` and
//! `VK_CONTROL` rather than read with `GetKeyState`, for the reason above: a
//! posted message carries no key state, so a `GetKeyState`-based Shift would be
//! unreachable from the harness and therefore untested. The one thing tracking
//! cannot see is a modifier that was ALREADY down when the overlay appeared —
//! Ctrl+Shift+S is exactly that — so `begin` seeds the pair once from the
//! creating thread's own queue state, and every release after that is an
//! ordinary `WM_KEYUP`.
//!
//! What the caret is doing is ANNOUNCED as well as drawn: the live position and
//! selection size go into the hint card AND into the window's text, which is
//! the name assistive tech reads (and, not by accident, the only oracle a
//! background-desktop script has for painted text).

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

/// What the overlay says before the caret has been placed or anything dragged —
/// the only status line that names both input devices, because it is the one a
/// user reads before choosing one.
const hint_text = "Drag, or arrows then Enter  ·  Esc to cancel";

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

/// The selection's pinned corner, in client (= snapshot buffer) coordinates.
/// Null until the button goes down (or Enter pins one).
anchor: ?region.Point = null,
/// Where the pointer — or the keyboard's caret — is now. Seeded to the middle
/// of the home monitor so the keyboard path starts somewhere sensible; the
/// first mouse press overwrites it.
cursor: region.Point = .{ .x = 0, .y = 0 },
/// The selection painted last, so a mouse-move can invalidate the OLD rect as
/// well as the new one instead of the whole desktop.
painted: ?region.Rect = null,

/// Which modifiers are held, tracked from key messages rather than read from
/// the OS — see the header. Seeded once in `begin` so a chord that was still
/// held when the overlay appeared is not missed.
mods: region.Mods = .{},

/// Whether the mouse was captured, so `finish` releases only what it took.
captured: bool = false,

/// Whether the keyboard has driven the caret yet. The caret mark is drawn only
/// once it has, so a pure mouse capture paints exactly what it always did.
keyboard: bool = false,

/// The caret position painted last, for the same reason `painted` exists.
painted_caret: ?region.Point = null,

/// The live status line — the hint card's text and the window's accessible
/// name. Held so a repaint does not have to recompute it and so an unchanged
/// line does not re-set the window text.
status_buf: [region.status_max]u8 = undefined,
status_len: usize = 0,

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
    const home = homeMonitor(b);
    self.* = .{
        .alloc = alloc,
        .hwnd = undefined,
        .ctx = ctx,
        .on_done = on_done,
        .snap = snap,
        .dim = dim,
        .home = home,
        .scale = scale,
        .cursor = region.caretStart(home),
        // The ONE place this reads the OS's key state, and only because the
        // keys that opened the overlay were pressed before it existed: a chord
        // (Ctrl+Shift+S) is still held here, and its releases will arrive as
        // ordinary WM_KEYUPs once this window has focus.
        .mods = .{ .shift = keyDown(w32.VK_SHIFT), .ctrl = keyDown(w32.VK_CONTROL) },
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
    self.refreshStatus();

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
/// `WM_PAINT` only ever touches the rect it was asked for, so anything that
/// stops being drawn has to be invalidated by whatever stopped drawing it —
/// which is why the caret and the hint card have their own versions of this.
fn invalidateSelection(self: *RegionSelector, next: ?region.Rect) void {
    const grow = region.px(region.border_dip, self.scale) + 1;
    for ([_]?region.Rect{ self.painted, next }) |maybe| {
        self.invalidate(maybe orelse continue, grow);
    }
    self.painted = next;
}

/// The same, for the keyboard caret's mark.
fn invalidateCaret(self: *RegionSelector, next: ?region.Point) void {
    for ([_]?region.Point{ self.painted_caret, next }) |maybe| {
        const p = maybe orelse continue;
        self.invalidate(region.caretBox(p, self.scale), 1);
    }
    self.painted_caret = next;
}

/// The caret mark, or null when there is nothing to draw one for: before the
/// keyboard has been used at all, and once a selection with AREA exists, whose
/// outline already says where the caret is.
///
/// Keyed on the drawn selection rather than on the anchor, because a pinned
/// corner with nothing dragged off it yet draws no outline — and a user who
/// presses Enter and watches the only mark on screen disappear has been told
/// their keypress broke something.
fn caretMark(self: *const RegionSelector) ?region.Point {
    if (!self.keyboard or self.selection() != null) return null;
    return self.cursor;
}

/// Recompute the status line, and if it changed, publish it in both places it
/// lives: the window's text — which is what a screen reader announces and the
/// only handle a background-desktop test has on painted text — and the hint
/// card, which has to be invalidated by hand for the reason above.
///
/// Coordinates are rebased to the VIRTUAL SCREEN, so the numbers match what
/// every other tool on the desktop would report for the same pixel.
fn refreshStatus(self: *RegionSelector) void {
    var buf: [region.status_max]u8 = undefined;
    const origin = self.snap.bounds;
    const sel: ?region.Rect = if (self.selection()) |r| .{
        .x = r.x + origin.x,
        .y = r.y + origin.y,
        .w = r.w,
        .h = r.h,
    } else null;
    const next = region.statusText(&buf, .{
        .x = self.cursor.x + origin.x,
        .y = self.cursor.y + origin.y,
    }, sel);
    if (std.mem.eql(u8, next, self.status_buf[0..self.status_len])) return;

    @memcpy(self.status_buf[0..next.len], next);
    self.status_len = next.len;

    var wide: [region.status_max + 1]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, next) catch return;
    wide[n] = 0;
    _ = w32.SetWindowTextW(self.hwnd, wide[0..n :0]);
    self.invalidate(self.hint_rect, 0);
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
///
/// Measured from the TEMPLATE rather than from the line currently showing: the
/// status line changes on every mouse move and every arrow press, and a card
/// that resized with it would re-center itself sideways a few pixels at a time
/// while the user is trying to read the number that is moving it. One fixed box,
/// text centered inside.
fn measureHint(self: *RegionSelector) void {
    const hdc = w32.GetDC(self.hwnd) orelse return;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const old_font = if (self.font) |f| w32.SelectObject(hdc, f) else null;
    defer if (self.font != null) {
        _ = w32.SelectObject(hdc, old_font);
    };

    var buf: [region.status_max]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, region.status_template) catch return;
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
    } else if (self.caretMark()) |p| {
        self.drawCaret(hdc, p);
    }

    // Last, so it is on top of a selection it overlaps — and always, because it
    // is now a live readout of where the caret is and how big the selection is,
    // not a one-off instruction that stops being true.
    self.drawHint(hdc);
}

/// The keyboard caret: a small cross, white over black, for the same
/// any-wallpaper contrast reason the selection outline is two colours.
///
/// It exists because arrows that move nothing visible are arrows that appear
/// not to work. It is drawn only while the keyboard is aiming and nothing is
/// selected yet, so a mouse-only capture paints exactly what it always did.
fn drawCaret(self: *RegionSelector, hdc: w32.HDC, p: region.Point) void {
    const t = region.px(region.border_dip, self.scale);
    const arm = region.px(region.caret_arm_dip, self.scale);
    const bars = [_]region.Rect{
        .{ .x = p.x - arm, .y = p.y - @divTrunc(t, 2), .w = 2 * arm, .h = t },
        .{ .x = p.x - @divTrunc(t, 2), .y = p.y - arm, .w = t, .h = 2 * arm },
    };
    for (bars) |bar| {
        // The black halo first, one outline thickness bigger on every side.
        fill(hdc, .{
            .x = bar.x - t,
            .y = bar.y - t,
            .w = bar.w + 2 * t,
            .h = bar.h + 2 * t,
        }, 0x00000000);
    }
    for (bars) |bar| fill(hdc, bar, 0x00FFFFFF);
}

fn fill(hdc: w32.HDC, r: region.Rect, color: u32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));
    var rc: w32.RECT = .{ .left = r.x, .top = r.y, .right = r.right(), .bottom = r.bottom() };
    _ = w32.FillRect(hdc, &rc, brush);
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

    var buf: [region.status_max]u16 = undefined;
    const text = if (self.status_len > 0) self.status_buf[0..self.status_len] else hint_text;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
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

    // Centered in the fixed card rather than pinned to its padding: the card is
    // sized to the widest line this can ever show (`measureHint`), so a shorter
    // one left-aligned would hang off toward an empty right half.
    var size: w32.SIZE = .{ .cx = card.w - 2 * region.px(region.hint_pad_x_dip, self.scale), .cy = 0 };
    _ = w32.GetTextExtentPoint32W(hdc, &buf, @intCast(n), &size);
    const x = card.x + @max(region.px(region.hint_pad_x_dip, self.scale), @divTrunc(card.w - size.cx, 2));

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, 0x00FFFFFF);
    _ = w32.TextOutW(
        hdc,
        x,
        card.y + region.px(region.hint_pad_y_dip, self.scale),
        &buf,
        @intCast(n),
    );
}

// --------------------------------------------------------------------- input

/// Whether `vk` is held right now, as far as the thread dispatching this
/// message is concerned. Called exactly once, in `begin` — see the header.
fn keyDown(vk: u16) bool {
    // The high bit means "down", and this is a signed 16-bit answer, so that
    // bit IS the sign.
    return w32.GetKeyState(@intCast(vk)) < 0;
}

/// One key transition. Modifiers are remembered; everything else acts.
///
/// Both edges matter: without the `WM_KEYUP` half, a Shift released before the
/// next arrow would still be extending, which is the stuck-modifier bug every
/// hand-rolled tracker has.
fn key(self: *RegionSelector, vk: u16, down: bool) void {
    switch (vk) {
        w32.VK_SHIFT, w32.VK_LSHIFT, w32.VK_RSHIFT => {
            self.mods.shift = down;
            return;
        },
        w32.VK_CONTROL, w32.VK_LCONTROL, w32.VK_RCONTROL => {
            self.mods.ctrl = down;
            return;
        },
        else => {},
    }
    if (!down) return;

    switch (vk) {
        w32.VK_ESCAPE => self.finish(null),

        w32.VK_LEFT, w32.VK_RIGHT, w32.VK_UP, w32.VK_DOWN => {
            const arrow: region.Arrow = switch (vk) {
                w32.VK_LEFT => .left,
                w32.VK_RIGHT => .right,
                w32.VK_UP => .up,
                else => .down,
            };
            const next = region.moveCaret(self.keyState(), arrow, self.mods, .{
                .x = 0,
                .y = 0,
                .w = self.snap.bounds.w,
                .h = self.snap.bounds.h,
            });
            self.keyboard = true;
            self.anchor = next.anchor;
            self.cursor = next.caret;
            self.applied(self.selection());
        },

        // Enter pins the first corner and captures the second — the keyboard's
        // whole gesture in one key, so nothing here needs a chord.
        //
        // Deliberately NOT Space as well, however button-shaped this window is:
        // Space is what Mac's `screencapture -i` uses to switch to picking a
        // WINDOW, which is T670's whole subject. A binding is much worse to take
        // away than never to have shipped.
        w32.VK_RETURN => {
            if (self.anchor == null) {
                self.keyboard = true;
                const next = region.dropAnchor(self.keyState());
                self.anchor = next.anchor;
                self.applied(self.selection());
            } else {
                // A pin with no area is a cancel, exactly as a click with no
                // drag is — never a zero-pixel picture.
                self.finish(self.selection());
            }
        },

        else => {},
    }
}

fn keyState(self: *const RegionSelector) region.KeyState {
    return .{ .caret = self.cursor, .anchor = self.anchor };
}

/// Everything that has to happen after `anchor`/`cursor` change, in one place
/// so the mouse path and the keyboard path cannot drift: repaint what moved,
/// and re-announce where things now are.
fn applied(self: *RegionSelector, sel: ?region.Rect) void {
    self.invalidateSelection(sel);
    self.invalidateCaret(self.caretMark());
    self.refreshStatus();
}

fn finish(self: *RegionSelector, sel: ?region.Rect) void {
    if (self.finished) return;
    self.finished = true;
    // Only if we took it: the keyboard path sets an anchor without ever
    // capturing the mouse, and releasing a capture this window does not hold
    // takes it away from whoever in this thread does.
    if (self.captured) _ = w32.ReleaseCapture();
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
            // The pointer owns the gesture again: a caret left over from an
            // earlier arrow press must stop being drawn.
            self.keyboard = false;
            _ = w32.SetCapture(hwnd);
            self.captured = true;
            self.applied(null);
            return 0;
        },

        w32.WM_MOUSEMOVE => {
            if (self.anchor == null) return 0;
            self.cursor = .{ .x = xOf(lparam), .y = yOf(lparam) };
            self.applied(self.selection());
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
            self.key(@intCast(wparam & 0xFFFF), true);
            return 0;
        },

        w32.WM_KEYUP => {
            self.key(@intCast(wparam & 0xFFFF), false);
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
