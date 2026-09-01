//! The update-download progress panel (T1195) — the window half.
//!
//! On the `auto-update = check` path, consenting to an update at the balloon
//! starts a download of tens of megabytes and, until this existed, said so
//! exactly once ("Downloading the update…") and then went quiet until the app
//! either restarted into the new build or reported a failure. Mac shows a
//! progress bar for that stretch; this is the Windows-native version of it —
//! a small owner-centered panel in the ConfirmDialog palette, so it looks
//! like the dialog the user just clicked through rather than a new species of
//! window.
//!
//! Three things it has to do, which the balloon could not:
//!
//! - **Show movement.** A determinate bar when the server sent a
//!   Content-Length, an indeterminate marquee when it did not. Never a
//!   percentage derived from a guessed total.
//! - **Tell a stall from a slow link.** `update_progress.StallTracker`
//!   watches the byte count rather than the clock, and after ten seconds of
//!   no movement the panel says "Stalled" instead of continuing to imply
//!   progress. This is the criterion the one-shot balloon failed hardest.
//! - **Stay out of the way when there is nothing to watch.** The
//!   `auto-update = download` default has the package on disk before the user
//!   ever clicks, and that path never constructs this window — clicking there
//!   installs, exactly as it did before.
//!
//! It is MODELESS on purpose. The download runs on a worker thread and the
//! app must keep pumping (the terminal keeps drawing, the IPC window keeps
//! answering) while it does, so this cannot borrow ConfirmDialog's nested
//! loop. It follows the layered-overlay lifecycle instead: create, tick on a
//! timer, destroy itself when the download reaches a terminal state.
//!
//! The numbers, the sentence and the stall rule are all in
//! `update_progress.zig`, unit-tested in every lane; this file owns the
//! window, the timer and the GDI.

const UpdateProgress = @This();

const std = @import("std");
const w32 = @import("win32.zig");
const model = @import("update_progress.zig");
const type_ramp = @import("type_ramp.zig");

const log = std.log.scoped(.win32_update_progress);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyUpdateProgress");

/// Repaint cadence. Fast enough that the bar reads as motion, slow enough
/// that a 40 MB download costs a few hundred repaints of a 420x110 window.
const TICK_MS: u32 = 150;
const TIMER_ID: usize = 1;

/// How long the panel stays up after the download ends, so "Download
/// complete." and (more importantly) a failure are readable rather than a
/// flash. A success is followed by the app quitting to install, so this is
/// mostly the failure case's dwell time.
const LINGER_MS: i64 = 2_500;

// The ConfirmDialog dark palette — this panel is the same surface as the
// dialog that launched it, so the colors are not re-invented here.
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_TEXT_SECONDARY = w32.RGB(160, 160, 160);
/// The bar's unfilled track: one notch darker than the surface, the same
/// relationship the dialog's text field has to it.
const COLOR_TRACK = w32.RGB(58, 58, 58);
/// The filled run — the accent blue the tab strip and command palette use for
/// the active thing.
const COLOR_FILL = w32.RGB(76, 160, 235);
/// A stalled or failed run desaturates rather than turning red: nothing is
/// broken yet, and the sentence under the bar carries the meaning.
const COLOR_FILL_STALLED = w32.RGB(120, 120, 120);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;

alloc: std.mem.Allocator,
hwnd: w32.HWND,
shared: *model.Shared,
/// Title line, e.g. "Downloading Ghoztty 1.36.0" (UTF-16, owned).
title: [:0]u16,
scale: f32,
fonts: Fonts,
tracker: model.StallTracker = .{},
/// Monotonic-ish millisecond clock for the stall tracker and the linger.
/// `std.time.milliTimestamp` is wall clock, which is what every other timing
/// in this app uses and is fine for a ten-second window.
ended_ms: i64 = 0,
tick: u64 = 0,
/// What the panel last SAID, so it can log the same sentence it paints
/// without logging it six times a second. The bucket is the progress decile
/// when a total is known and every fourth megabyte when it is not; a stall
/// and each terminal state are their own one-shot lines.
///
/// This is the acceptance harness's only oracle: the panel paints on a
/// background desktop where nothing can read its pixels, and it is custom
/// drawn so it carries no readable control text either. Logging what it says
/// is what makes "the user can watch this" a checkable claim rather than an
/// assertion about a window handle existing.
logged_bucket: i64 = -1,
logged_stall: bool = false,
logged_end: bool = false,
/// Set once the panel has torn itself down, so a late timer cannot run over
/// freed state.
closing: bool = false,

const Fonts = struct {
    body: ?*anyopaque,
    caption: ?*anyopaque,

    fn deinit(self: Fonts) void {
        if (self.body) |f| _ = w32.DeleteObject(f);
        if (self.caption) |f| _ = w32.DeleteObject(f);
    }
};

/// Panel geometry in physical pixels. Pure and unit-tested below — the panel
/// is small enough that its whole layout is four rects, and keeping them here
/// means the paint code never does arithmetic.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    title: w32.RECT,
    track: w32.RECT,
    status: w32.RECT,
};

pub fn layoutFor(scale: f32, title_h: i32, status_h: i32) Layout {
    const margin = px(16, scale);
    const bar_h = px(8, scale);
    const gap = px(12, scale);
    const client_w = px(420, scale);
    const title_top = margin;
    const track_top = title_top + title_h + gap;
    const status_top = track_top + bar_h + gap;
    return .{
        .client_w = client_w,
        .client_h = status_top + status_h + margin,
        .title = .{
            .left = margin,
            .top = title_top,
            .right = client_w - margin,
            .bottom = title_top + title_h,
        },
        .track = .{
            .left = margin,
            .top = track_top,
            .right = client_w - margin,
            .bottom = track_top + bar_h,
        },
        .status = .{
            .left = margin,
            .top = status_top,
            .right = client_w - margin,
            .bottom = status_top + status_h,
        },
    };
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Open the panel over `owner` (or centered on the primary screen when there
/// is none). Takes ONE of `shared`'s two references; the download worker
/// holds the other. Returns null when the window could not be created, which
/// is not fatal to anything: the download still runs, exactly as it did
/// before this panel existed.
pub fn create(
    alloc: std.mem.Allocator,
    hinstance: ?w32.HINSTANCE,
    owner: ?w32.HWND,
    scale: f32,
    version: []const u8,
    shared: *model.Shared,
) ?*UpdateProgress {
    registerClass(hinstance) orelse return null;

    const self = alloc.create(UpdateProgress) catch return null;
    errdefer alloc.destroy(self);

    var title_buf: [128]u8 = undefined;
    const title_utf8 = std.fmt.bufPrint(
        &title_buf,
        "Downloading Ghoztty {s}",
        .{version},
    ) catch "Downloading Ghoztty";
    const title = utf16z(alloc, title_utf8) catch return null;
    errdefer alloc.free(title);

    const fonts: Fonts = .{
        .body = w32.CreateFontW(
            -type_ramp.body(scale).height,
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
        ),
        .caption = w32.CreateFontW(
            -type_ramp.caption(scale).height,
            0,
            0,
            0,
            type_ramp.weight_normal,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
        ),
    };
    errdefer fonts.deinit();

    const l = layoutFor(
        scale,
        type_ramp.lineBox(type_ramp.body(scale), scale),
        type_ramp.lineBox(type_ramp.caption(scale), scale),
    );

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME | w32.WS_EX_TOOLWINDOW;

    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var center: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = w32.GetSystemMetrics(0), // SM_CXSCREEN
        .bottom = w32.GetSystemMetrics(1), // SM_CYSCREEN
    };
    if (owner) |o| _ = w32.GetWindowRect(o, &center);
    const x = center.left + @divTrunc((center.right - center.left) - outer_w, 2);
    const y = center.top + @divTrunc((center.bottom - center.top) - outer_h, 2);

    self.* = .{
        .alloc = alloc,
        .hwnd = undefined,
        .shared = shared,
        .title = title,
        .scale = scale,
        .fonts = fonts,
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        title.ptr,
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        hinstance,
        null,
    ) orelse {
        log.warn("update progress panel could not be created", .{});
        return null;
    };
    self.hwnd = hwnd;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    // SW_SHOWNA: the panel reports, it does not steal the caret from the
    // terminal the user is still typing in.
    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNA);
    _ = w32.SetTimer(hwnd, TIMER_ID, TICK_MS, null);
    return self;
}

/// Close the panel. Idempotent — the timer path, the close box and an
/// explicit call can all reach it. The heap state is freed in `finalize` off
/// WM_NCDESTROY rather than here, because this window is OWNED by a terminal
/// window: closing that window destroys this one without anybody calling
/// `close`, and a teardown that only runs on the polite path leaks on the
/// impolite one.
pub fn close(self: *UpdateProgress) void {
    if (self.closing) return;
    self.closing = true;
    _ = w32.DestroyWindow(self.hwnd);
}

/// The single teardown, reached from WM_NCDESTROY however the window died.
fn finalize(self: *UpdateProgress) void {
    const alloc = self.alloc;
    const shared = self.shared;
    _ = w32.KillTimer(self.hwnd, TIMER_ID);
    self.fonts.deinit();
    alloc.free(self.title);
    alloc.destroy(self);
    shared.release(alloc);
}

/// One timer tick: read the worker's counters, decide whether the panel has
/// anything left to say, and repaint. Returns false when the panel closed
/// itself, so the owner can drop its pointer.
fn onTick(self: *UpdateProgress) bool {
    const snap = self.shared.snapshot();
    const now = std.time.milliTimestamp();
    self.tick +%= 1;

    if (snap.outcome == .running) {
        self.tracker.observe(snap.received, now);
    } else if (self.ended_ms == 0) {
        self.ended_ms = now;
    }
    self.logProgress(snap, self.tracker.idleMs(now));

    _ = w32.InvalidateRect(self.hwnd, null, 0);

    // A finished download leaves its last sentence up briefly and then goes.
    if (self.ended_ms != 0 and now - self.ended_ms >= LINGER_MS) {
        self.close();
        return false;
    }
    return true;
}

/// Say out loud what the panel is showing, on the transitions that matter.
fn logProgress(self: *UpdateProgress, snap: model.Snapshot, idle_ms: i64) void {
    var buf: [192]u8 = undefined;

    if (snap.outcome != .running) {
        if (self.logged_end) return;
        self.logged_end = true;
        log.info("update progress: {s}", .{model.statusLine(&buf, snap, idle_ms)});
        return;
    }

    if (idle_ms >= model.stall_after_ms) {
        if (self.logged_stall) return;
        self.logged_stall = true;
        log.info("update progress: {s}", .{model.statusLine(&buf, snap, idle_ms)});
        return;
    }
    // Movement resumed: the next stall is a new fact and gets its own line.
    self.logged_stall = false;

    const bucket: i64 = if (model.percent(snap.received, snap.total)) |pct|
        @divTrunc(@as(i64, pct), 10)
    else
        @intCast(snap.received / (4 * 1024 * 1024));
    if (bucket == self.logged_bucket) return;
    self.logged_bucket = bucket;
    log.info("update progress: {s}", .{model.statusLine(&buf, snap, idle_ms)});
}

fn paint(self: *UpdateProgress, hdc: w32.HDC, client: w32.RECT) void {
    const w = client.right - client.left;
    const h = client.bottom - client.top;
    if (w <= 0 or h <= 0) return;

    // Double-buffered: the bar repaints six times a second, and a direct
    // paint over the surface brush flickers at that rate.
    const mem_dc = w32.CreateCompatibleDC(hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const bmp = w32.CreateCompatibleBitmap(hdc, w, h) orelse return;
    defer _ = w32.DeleteObject(bmp);
    const prev_bmp = w32.SelectObject(mem_dc, bmp);
    defer _ = w32.SelectObject(mem_dc, prev_bmp);

    if (bg_brush) |b| _ = w32.FillRect(mem_dc, &client, b);

    const snap = self.shared.snapshot();
    const now = std.time.milliTimestamp();
    const idle = self.tracker.idleMs(now);
    const l = layoutFor(
        self.scale,
        type_ramp.lineBox(type_ramp.body(self.scale), self.scale),
        type_ramp.lineBox(type_ramp.caption(self.scale), self.scale),
    );

    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // Title.
    if (self.fonts.body) |f| {
        const prev = w32.SelectObject(mem_dc, f);
        defer _ = w32.SelectObject(mem_dc, prev);
        _ = w32.SetTextColor(mem_dc, COLOR_TEXT);
        var r = l.title;
        _ = w32.DrawTextW(
            mem_dc,
            self.title.ptr,
            @intCast(self.title.len),
            &r,
            w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX | w32.DT_END_ELLIPSIS,
        );
    }

    // Track, then the run over it.
    const track_w = l.track.right - l.track.left;
    if (w32.CreateSolidBrush(COLOR_TRACK)) |tb| {
        defer _ = w32.DeleteObject(tb);
        _ = w32.FillRect(mem_dc, &l.track, tb);
    }
    const stalled = snap.outcome == .running and idle >= model.stall_after_ms;
    const fill_color = if (stalled or snap.outcome == .failed) COLOR_FILL_STALLED else COLOR_FILL;
    if (w32.CreateSolidBrush(fill_color)) |fb| {
        defer _ = w32.DeleteObject(fb);
        var run = l.track;
        if (snap.outcome == .ok) {
            // A finished download is a full bar regardless of what the
            // server claimed the length was.
        } else if (model.fraction(snap.received, snap.total)) |frac| {
            run.right = run.left + model.fillWidth(track_w, frac);
        } else {
            // No Content-Length: a marquee chip, held still while stalled so
            // the animation cannot contradict the sentence under it.
            const chip = @max(px(24, self.scale), @divTrunc(track_w, 5));
            const x = if (stalled) 0 else model.marqueeX(track_w, chip, self.tick);
            run.left = l.track.left + x;
            run.right = run.left + chip;
        }
        if (run.right > run.left) _ = w32.FillRect(mem_dc, &run, fb);
    }

    // Status sentence.
    if (self.fonts.caption) |f| {
        const prev = w32.SelectObject(mem_dc, f);
        defer _ = w32.SelectObject(mem_dc, prev);
        _ = w32.SetTextColor(mem_dc, COLOR_TEXT_SECONDARY);
        var status_buf: [192]u8 = undefined;
        const status = model.statusLine(&status_buf, snap, idle);
        var w_buf: [256]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&w_buf, status) catch 0;
        var r = l.status;
        _ = w32.DrawTextW(
            mem_dc,
            &w_buf,
            @intCast(n),
            &r,
            w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX | w32.DT_END_ELLIPSIS,
        );
    }

    _ = w32.BitBlt(hdc, 0, 0, w, h, mem_dc, 0, 0, w32.SRCCOPY);
}

fn utf16z(alloc: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
}

fn registerClass(hinstance: ?w32.HINSTANCE) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("update progress class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *UpdateProgress = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_TIMER => {
            if (wparam == TIMER_ID) _ = self.onTick();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1, // paint() fills the whole client
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            if (w32.BeginPaint(hwnd, &ps)) |hdc| {
                var client: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &client) != 0) self.paint(hdc, client);
                _ = w32.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        // The same content into a caller's DC, so a pixel probe can photograph
        // the panel synchronously instead of through DWM's asynchronous copy of
        // the composited surface, which tears (T835/T940). Everything this
        // window shows is owner-drawn - there are no child controls for
        // DefWindowProc's WM_PRINT handling to print - so the whole client
        // comes from here.
        w32.WM_PRINTCLIENT => {
            if (wparam == 0) return 0;
            var client: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &client) != 0) {
                self.paint(@ptrFromInt(wparam), client);
            }
            return 0;
        },
        w32.WM_CLOSE => {
            // Closing the panel dismisses the REPORT, not the download: the
            // user already consented to install, and quietly cancelling that
            // behind a close box would be a different promise than the one
            // the dialog made.
            self.close();
            return 0;
        },
        w32.WM_NCDESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            self.finalize();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "layout: rows stack without overlapping, at every scale" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const title_h = type_ramp.lineBox(type_ramp.body(scale), scale);
        const status_h = type_ramp.lineBox(type_ramp.caption(scale), scale);
        const l = layoutFor(scale, title_h, status_h);

        try testing.expect(l.title.bottom <= l.track.top);
        try testing.expect(l.track.bottom <= l.status.top);
        try testing.expect(l.status.bottom < l.client_h);
        // Equal side margins.
        try testing.expectEqual(l.title.left, l.track.left);
        try testing.expectEqual(l.client_w - l.title.right, l.title.left);
        try testing.expectEqual(l.track.right, l.status.right);
        // The bar is a bar, not a box.
        const bar_h = l.track.bottom - l.track.top;
        try testing.expect(bar_h > 0 and bar_h < title_h);
    }
}

test "layout: scales with DPI" {
    const at1 = layoutFor(1.0, 20, 16);
    const at2 = layoutFor(2.0, 40, 32);
    try testing.expectEqual(at1.client_w * 2, at2.client_w);
    try testing.expect(at2.client_h > at1.client_h);
}
