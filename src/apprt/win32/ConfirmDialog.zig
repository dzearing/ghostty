//! Dark-mode replacement for the light `MessageBoxW` prompts (T80).
//!
//! A small owner-centered dialog in the T50 RenameDialog pattern — dark
//! caption, dark client, system icon, message text, OK/Cancel — but with a
//! *synchronous* API: `show` disables the owner, runs its own nested
//! message loop (exactly what MessageBoxW does internally, which the T48
//! analysis established is WndProc-safe: the thread keeps pumping, so the
//! IME/CTF cascade and the IPC message-only window stay live), and returns
//! the user's choice. That keeps every caller's control flow identical to
//! the MessageBoxW it replaces.
//!
//! Semantics preserved from the MessageBoxW sites:
//!   - `default_cancel` mirrors MB_DEFBUTTON2: initial focus and the Enter
//!     default land on Cancel so an accidental Enter never approves a
//!     destructive action.
//!   - Escape cancels (for `ok_only` it simply dismisses).
//!   - The ✕ close box cancels.

const ConfirmDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyConfirmDialog");

pub const Result = enum { ok, cancel };
pub const Style = enum { ok_only, ok_cancel };
pub const Icon = enum { none, warning, info };

pub const Options = struct {
    title: [*:0]const u16,
    text: [:0]const u16,
    style: Style = .ok_cancel,
    icon: Icon = .warning,
    /// MB_DEFBUTTON2 parity: focus + Enter default on Cancel.
    default_cancel: bool = true,
    /// Button captions. The affirmative/dismissive semantics (and the
    /// Result values) stay OK/Cancel regardless of the label — callers
    /// like the T69 config-errors dialog relabel them ("Open Config" /
    /// "Ignore") without changing any dialog behavior. Buttons widen to
    /// fit the longer caption.
    ok_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("OK"),
    cancel_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
};

/// Dialog colors — the RenameDialog dark palette (matches the command
/// palette and the tab bar's dark styling).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_TEXT = w32.RGB(230, 230, 230);

/// Class-lifetime brush, created at class registration and never freed
/// (lives for the process, like the other dialog classes).
var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;

hwnd: w32.HWND,
static: ?w32.HWND,
ok_btn: w32.HWND,
cancel_btn: ?w32.HWND,
icon_handle: ?w32.HICON,
icon_rect: w32.RECT,
default_cancel: bool,
result: Result = .cancel,
done: bool = false,

/// Dialog layout in physical pixels, computed from the owner window's DPI
/// scale and the measured text extent. Pure — unit tested below.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    icon: w32.RECT,
    text: w32.RECT,
    ok: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
};

/// `btn_w` is the physical-pixel button width — at least the standard
/// 88 DIP, wider when a caption needs the room (see buttonWidth).
pub fn layoutFor(scale: f32, text_w: i32, text_h: i32, has_icon: bool, has_cancel: bool, btn_w: i32) Layout {
    const margin = px(16, scale);
    const icon_px = px(32, scale);
    const icon_gap = px(12, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);
    const btn_gap_v = px(18, scale);

    const icon_span: i32 = if (has_icon) icon_px + icon_gap else 0;
    const n_btns: i32 = if (has_cancel) 2 else 1;
    const btns_w = n_btns * btn_w + (n_btns - 1) * btn_gap_h;

    var client_w = margin + icon_span + text_w + margin;
    // Never narrower than the button row (or a sane floor).
    client_w = @max(client_w, margin + btns_w + margin);
    client_w = @max(client_w, px(280, scale));

    const content_h = @max(text_h, if (has_icon) icon_px else 0);
    const client_h = margin + content_h + btn_gap_v + btn_h + margin;

    // Vertically center the shorter of icon/text within the content band.
    const icon_top = margin + @divTrunc(content_h - icon_px, 2);
    const text_top = margin + @divTrunc(content_h - text_h, 2);

    const btn_top = margin + content_h + btn_gap_v;
    const right_left = client_w - margin - btn_w;
    const left_left = right_left - btn_gap_h - btn_w;
    // With two buttons OK sits left of Cancel; alone, OK takes the right slot.
    const ok_left = if (has_cancel) left_left else right_left;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .icon = if (has_icon) .{
            .left = margin,
            .top = icon_top,
            .right = margin + icon_px,
            .bottom = icon_top + icon_px,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .text = .{
            .left = margin + icon_span,
            .top = text_top,
            .right = margin + icon_span + text_w,
            .bottom = text_top + text_h,
        },
        .ok = .{ .left = ok_left, .top = btn_top, .right = ok_left + btn_w, .bottom = btn_top + btn_h },
        .cancel = if (has_cancel) .{
            .left = right_left,
            .top = btn_top,
            .right = right_left + btn_w,
            .bottom = btn_top + btn_h,
        } else .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .font_h = px(15, scale),
    };
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Button width for the given widest caption extent (physical pixels):
/// the standard 88-DIP button, widened with 12 DIP of padding per side
/// when the caption needs the room.
pub fn buttonWidth(scale: f32, max_label_w: i32) i32 {
    return @max(px(88, scale), max_label_w + px(24, scale));
}

/// Show the dialog modally and return the user's choice. `owner` is
/// disabled for the duration (input-modal to that window; the app loop
/// keeps effectively running because we pump here). `refocus`, when given,
/// receives deferred focus after the dialog closes (T48 pattern) — pass
/// the active terminal surface HWND, or null when the window is about to
/// be destroyed anyway (posted focus to a dead HWND is dropped by the OS).
pub fn show(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    opts: Options,
) Result {
    registerClass(app) orelse return fallback(owner, opts);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const has_icon = opts.icon != .none;
    const has_cancel = opts.style == .ok_cancel;

    // DPI-scaled dialog font, needed up front to measure the text.
    const font = w32.CreateFontW(
        -px(15, scale),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    defer if (font) |f| {
        _ = w32.DeleteObject(f);
    };

    // Measure the text: wrap at a max width; DrawText shrinks the rect to
    // the widest actual line (or grows it for an unbreakable run, e.g. the
    // About box's executable path — then the dialog widens to fit).
    var text_rect: w32.RECT = .{
        .left = 0,
        .top = 0,
        .right = px(420, scale),
        .bottom = 0,
    };
    var label_w: i32 = 0;
    {
        const hdc = w32.GetDC(null) orelse return fallback(owner, opts);
        defer _ = w32.ReleaseDC(null, hdc);
        const prev = if (font) |f| w32.SelectObject(hdc, f) else null;
        defer if (prev) |p| {
            _ = w32.SelectObject(hdc, p);
        };
        _ = w32.DrawTextW(
            hdc,
            opts.text.ptr,
            @intCast(opts.text.len),
            &text_rect,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );

        // Widest button caption, so custom labels never truncate.
        const labels: [2][:0]const u16 = .{ opts.ok_label, opts.cancel_label };
        for (labels, 0..) |label, i| {
            if (i == 1 and !has_cancel) break;
            var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = w32.DrawTextW(
                hdc,
                label.ptr,
                @intCast(label.len),
                &r,
                w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
            );
            label_w = @max(label_w, r.right - r.left);
        }
    }
    const l = layoutFor(
        scale,
        text_rect.right - text_rect.left,
        text_rect.bottom - text_rect.top,
        has_icon,
        has_cancel,
        buttonWidth(scale, label_w),
    );

    // Outer size from the desired client size, centered on the owner (or
    // the primary screen when there is no owner window).
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

    // The dialog lives entirely on this stack frame — show() does not
    // return until the nested loop finishes, so no allocation is needed.
    var self: ConfirmDialog = .{
        .hwnd = undefined,
        .static = null,
        .ok_btn = undefined,
        .cancel_btn = null,
        .icon_handle = switch (opts.icon) {
            .none => null,
            .warning => w32.LoadIconW(null, w32.IDI_WARNING),
            .info => w32.LoadIconW(null, w32.IDI_INFORMATION),
        },
        .icon_rect = l.icon,
        .default_cancel = has_cancel and opts.default_cancel,
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        opts.title,
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        app.hinstance,
        null,
    ) orelse return fallback(owner, opts);
    self.hwnd = hwnd;

    // Dark title bar, matching the terminal windows.
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    // Message text.
    self.static = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        opts.text.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX,
        l.text.left,
        l.text.top,
        l.text.right - l.text.left,
        l.text.bottom - l.text.top,
        hwnd,
        null,
        app.hinstance,
        null,
    );

    self.ok_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        opts.ok_label.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
            (if (self.default_cancel) 0 else w32.BS_DEFPUSHBUTTON),
        l.ok.left,
        l.ok.top,
        l.ok.right - l.ok.left,
        l.ok.bottom - l.ok.top,
        hwnd,
        @ptrFromInt(@as(usize, @intCast(w32.IDOK))),
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        return fallback(owner, opts);
    };
    _ = w32.SetWindowTheme(self.ok_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    if (has_cancel) {
        const cancel_btn = w32.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
            opts.cancel_label.ptr,
            w32.WS_CHILD | w32.WS_VISIBLE_STYLE |
                (if (self.default_cancel) w32.BS_DEFPUSHBUTTON else 0),
            l.cancel.left,
            l.cancel.top,
            l.cancel.right - l.cancel.left,
            l.cancel.bottom - l.cancel.top,
            hwnd,
            @ptrFromInt(@as(usize, @intCast(w32.IDCANCEL))),
            app.hinstance,
            null,
        ) orelse {
            _ = w32.DestroyWindow(hwnd);
            return fallback(owner, opts);
        };
        _ = w32.SetWindowTheme(cancel_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
        self.cancel_btn = cancel_btn;
    }

    if (font) |f| {
        if (self.static) |s| _ = w32.SendMessageW(s, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(self.ok_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.cancel_btn) |c| _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&self)));

    // Input-modal to the owner until the dialog closes.
    if (owner) |o| _ = w32.EnableWindow(o, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.defaultButton());

    self.runModal();

    // Teardown. The owner MUST be re-enabled before the dialog is
    // destroyed, otherwise Windows may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48

    return self.result;
}

/// Last-resort fallback when dialog construction fails: the old (light)
/// MessageBoxW, so a prompt is never silently skipped.
fn fallback(owner: ?w32.HWND, opts: Options) Result {
    var flags: u32 = switch (opts.style) {
        .ok_only => w32.MB_OK,
        .ok_cancel => w32.MB_OKCANCEL,
    };
    flags |= switch (opts.icon) {
        .none => 0,
        .warning => w32.MB_ICONWARNING,
        .info => w32.MB_ICONINFORMATION,
    };
    if (opts.style == .ok_cancel and opts.default_cancel) flags |= w32.MB_DEFBUTTON2;
    const r = w32.MessageBoxW(owner, opts.text.ptr, opts.title, flags);
    return if (opts.style == .ok_only or r == w32.IDOK) .ok else .cancel;
}

/// Nested modal message pump — the same shape MessageBoxW runs internally.
/// Replicates the App.run top-of-loop specials that matter while modal:
/// WM_APP_SETFOCUS (T48 deferred focus) is performed here, never
/// dispatched. Everything else (renderer wakeups, IPC — both handled in
/// window procs) flows through Translate/Dispatch as usual.
fn runModal(self: *ConfirmDialog) void {
    var msg: w32.MSG = undefined;
    while (!self.done) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT: repost for the outer App.run loop and bail out
            // without approving anything.
            w32.PostQuitMessage(@intCast(msg.wParam));
            self.result = .cancel;
            return;
        }
        if (result < 0) {
            self.result = .cancel;
            return;
        }
        if (msg.message == App.WM_APP_SETFOCUS) {
            if (msg.hwnd) |h| _ = w32.SetFocus(h);
            continue;
        }
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null and self.ownsHwnd(msg.hwnd.?)) {
            const vk: u16 = @intCast(msg.wParam & 0xFFFF);
            if (self.handleKey(vk)) continue;
        }
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

fn defaultButton(self: *const ConfirmDialog) w32.HWND {
    if (self.default_cancel) {
        if (self.cancel_btn) |c| return c;
    }
    return self.ok_btn;
}

fn ownsHwnd(self: *const ConfirmDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.ok_btn) return true;
    if (self.static) |s| if (hwnd == s) return true;
    if (self.cancel_btn) |c| if (hwnd == c) return true;
    return false;
}

fn finish(self: *ConfirmDialog, result: Result) void {
    self.result = result;
    self.done = true;
}

/// Handle a dialog key from the nested pump. Returns true when consumed.
fn handleKey(self: *ConfirmDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            // MB_OK parity: Escape dismisses an OK-only box as "ok".
            self.finish(if (self.cancel_btn == null) .ok else .cancel);
            return true;
        },
        w32.VK_RETURN => {
            // Enter activates the focused button, else the default —
            // standard dialog convention (MB_DEFBUTTON2 preserved).
            const focus = w32.GetFocus();
            if (self.cancel_btn != null and focus == self.cancel_btn) {
                self.finish(.cancel);
            } else if (focus == @as(?w32.HWND, self.ok_btn)) {
                self.finish(.ok);
            } else {
                self.finish(if (self.default_cancel) .cancel else .ok);
            }
            return true;
        },
        w32.VK_TAB => {
            // Two focus stops at most: OK <-> Cancel.
            const cancel_btn = self.cancel_btn orelse return true;
            const next = if (w32.GetFocus() == @as(?w32.HWND, self.ok_btn))
                cancel_btn
            else
                self.ok_btn;
            _ = w32.SetFocus(next);
            return true;
        },
        else => return false,
    }
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };
    if (w32.RegisterClassExW(&wc) == 0) {
        log.warn("confirm dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *ConfirmDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) {
                switch (control_id) {
                    @as(u16, @intCast(w32.IDOK)) => {
                        self.finish(.ok);
                        return 0;
                    },
                    @as(u16, @intCast(w32.IDCANCEL)) => {
                        self.finish(.cancel);
                        return 0;
                    },
                    else => {},
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            // ✕ dismisses: cancel for confirms, ok for OK-only boxes.
            self.finish(if (self.cancel_btn == null) .ok else .cancel);
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            if (self.icon_handle) |icon| {
                _ = w32.DrawIconEx(
                    hdc,
                    self.icon_rect.left,
                    self.icon_rect.top,
                    icon,
                    self.icon_rect.right - self.icon_rect.left,
                    self.icon_rect.bottom - self.icon_rect.top,
                    0,
                    null,
                    w32.DI_NORMAL,
                );
            }
            return 0;
        },
        w32.WM_ACTIVATE => {
            // Restore focus to the default button when reactivated (e.g.
            // after alt-tabbing away) and no child holds it.
            const state: u16 = @intCast(wparam & 0xFFFF);
            if (state != w32.WA_INACTIVE) {
                const focus = w32.GetFocus();
                const owned = focus != null and self.ownsHwnd(focus.?);
                if (!owned) _ = w32.SetFocus(self.defaultButton());
            }
            return 0;
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------
// Tests (pure logic only — run in both test lanes)
// ---------------------------------------------------------------------

const testing = std.testing;

test "layoutFor: controls nest inside the client area at 1.0 scale" {
    const l = layoutFor(1.0, 300, 40, true, true, 88);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.icon, l.text, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
    }
}

test "layoutFor: buttons right-aligned, OK left of Cancel, no overlap" {
    const l = layoutFor(1.0, 300, 40, true, true, 88);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expectEqual(l.ok.top, l.cancel.top);
    try testing.expectEqual(l.cancel.right, l.client_w - 16);
}

test "layoutFor: ok-only puts OK in the rightmost slot, no cancel rect" {
    const l = layoutFor(1.0, 300, 40, false, false, 88);
    try testing.expectEqual(l.ok.right, l.client_w - 16);
    try testing.expectEqual(@as(i32, 0), l.cancel.right - l.cancel.left);
    try testing.expectEqual(@as(i32, 0), l.icon.right - l.icon.left);
}

test "layoutFor: text starts right of the icon with a gap" {
    const l = layoutFor(1.0, 300, 40, true, true, 88);
    try testing.expect(l.text.left >= l.icon.right + 12);
    // Without an icon the text hugs the margin.
    const l2 = layoutFor(1.0, 300, 40, false, true, 88);
    try testing.expectEqual(@as(i32, 16), l2.text.left);
}

test "layoutFor: short text is vertically centered against the icon" {
    const l = layoutFor(1.0, 300, 16, true, true, 88);
    // Icon (32px) taller than text (16px): text drops to center.
    try testing.expect(l.text.top > l.icon.top);
    try testing.expectEqual(l.icon.top, 16);
    // Text (60px) taller than icon: icon centers instead.
    const l2 = layoutFor(1.0, 300, 60, true, true, 88);
    try testing.expect(l2.icon.top > l2.text.top);
}

test "layoutFor: narrow text still fits the button row" {
    const l = layoutFor(1.0, 40, 20, false, true, 88);
    // Two 88px buttons + 8px gap + 2*16 margins = 216, floored at 280.
    try testing.expect(l.client_w >= 280);
    try testing.expect(l.ok.left >= 16);
}

test "layoutFor: scales with DPI" {
    const l1 = layoutFor(1.0, 300, 40, true, true, 88);
    const l2 = layoutFor(2.0, 600, 80, true, true, 176);
    try testing.expectEqual(l1.client_w * 2, l2.client_w);
    try testing.expectEqual(l1.client_h * 2, l2.client_h);
    try testing.expectEqual(l1.ok.left * 2, l2.ok.left);
    try testing.expectEqual(l1.font_h * 2, l2.font_h);
}

test "buttonWidth: standard until the caption outgrows it, then padded" {
    // "OK"/"Cancel"-sized captions keep the 88-DIP standard width.
    try testing.expectEqual(@as(i32, 88), buttonWidth(1.0, 40));
    try testing.expectEqual(@as(i32, 176), buttonWidth(2.0, 80));
    // A wide caption ("Open Config") gets 12 DIP padding per side.
    try testing.expectEqual(@as(i32, 124), buttonWidth(1.0, 100));
}

test "layoutFor: wide buttons widen the row and never overlap" {
    const l = layoutFor(1.0, 40, 20, false, true, 124);
    try testing.expectEqual(@as(i32, 124), l.ok.right - l.ok.left);
    try testing.expectEqual(@as(i32, 124), l.cancel.right - l.cancel.left);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expect(l.ok.left >= 16);
    // Client floor still respected: 2*124 + 8 + 2*16 = 288 > 280.
    try testing.expectEqual(@as(i32, 288), l.client_w);
}
