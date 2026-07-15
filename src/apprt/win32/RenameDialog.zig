//! Modal-ish "Rename Window" dialog for the win32 apprt (T50).
//!
//! The keybind rename (ctrl+shift+r -> prompt_title) used to reuse the
//! inline tab-rename Edit control, which with a hidden tab bar degraded to
//! a bare borderless box (no label, no buttons - not obviously a dialog).
//! This is a real owner-centered dialog: caption, label, prefilled edit,
//! OK/Cancel. The owner window is disabled while it is open (modal to the
//! window), but the app message loop keeps running, so the renderer thread
//! and the IPC server stay live.
//!
//! Commit path: OK applies the text via `Window.setTitleOverride`, the
//! same path as the `+rename` IPC verb - the override beats
//! terminal-reported titles until cleared (T10 precedence). An empty text
//! clears the override, reverting the title to the terminal-reported one.
//!
//! Enter/Escape/Tab never reach the native controls: the main message
//! loop routes them here via `handleKey` (see the WM_KEYDOWN intercept in
//! App.run), the same mechanism the inline tab rename uses.

const RenameDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyRenameDialog");
const EDIT_ID: u16 = 100;

window: *Window,
hwnd: w32.HWND,
edit: w32.HWND,
ok_btn: w32.HWND,
cancel_btn: w32.HWND,
font: ?*anyopaque = null,

/// Dialog colors (dark chrome, matching the command palette and the
/// tab bar's dark styling).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_EDIT_BG = w32.RGB(30, 30, 30);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);

/// Class-lifetime brushes, created at class registration and never freed
/// (like the App's class background brush - they live for the process).
var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var edit_brush: ?w32.HBRUSH = null;

/// Dialog layout in physical pixels, computed from the owner window's DPI
/// scale. Pure - unit tested below.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    label: w32.RECT,
    edit: w32.RECT,
    ok: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
};

pub fn layout(scale: f32) Layout {
    const margin = px(16, scale);
    const label_h = px(16, scale);
    const label_gap = px(6, scale);
    const edit_h = px(26, scale);
    const btn_gap_v = px(18, scale);
    const btn_w = px(88, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);

    const client_w = px(380, scale);
    const client_h = margin + label_h + label_gap + edit_h + btn_gap_v + btn_h + margin;

    const edit_top = margin + label_h + label_gap;
    const btn_top = edit_top + edit_h + btn_gap_v;
    const cancel_left = client_w - margin - btn_w;
    const ok_left = cancel_left - btn_gap_h - btn_w;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .label = .{ .left = margin, .top = margin, .right = client_w - margin, .bottom = margin + label_h },
        .edit = .{ .left = margin, .top = edit_top, .right = client_w - margin, .bottom = edit_top + edit_h },
        .ok = .{ .left = ok_left, .top = btn_top, .right = ok_left + btn_w, .bottom = btn_top + btn_h },
        .cancel = .{ .left = cancel_left, .top = btn_top, .right = cancel_left + btn_w, .bottom = btn_top + btn_h },
        .font_h = px(15, scale),
    };
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Open the rename dialog for a window. Idempotent: if the window already
/// has one open, it is focused instead.
pub fn open(window: *Window) void {
    if (window.rename_dialog) |existing| {
        _ = w32.SetForegroundWindow(existing.hwnd);
        _ = w32.SetFocus(existing.edit);
        return;
    }

    const owner = window.hwnd orelse return;

    // Mutual exclusion with the inline tab-rename edit.
    window.cancelTabRename();

    registerClass(window.app) orelse return;

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const l = layout(window.scale);

    // Outer size from the desired client size, centered on the owner.
    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var owner_rect: w32.RECT = undefined;
    if (w32.GetWindowRect(owner, &owner_rect) == 0) return;
    const x = owner_rect.left + @divTrunc((owner_rect.right - owner_rect.left) - outer_w, 2);
    const y = owner_rect.top + @divTrunc((owner_rect.bottom - owner_rect.top) - outer_h, 2);

    const alloc = window.app.core_app.alloc;
    const self = alloc.create(RenameDialog) catch |err| {
        log.warn("rename dialog alloc failed err={}", .{err});
        return;
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Rename Window"),
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        alloc.destroy(self);
        return;
    };

    // Dark title bar, matching the terminal windows.
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    // Label.
    const label = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("Window title:"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.label.left,
        l.label.top,
        l.label.right - l.label.left,
        l.label.bottom - l.label.top,
        hwnd,
        null,
        window.app.hinstance,
        null,
    );

    // Edit, prefilled with the current effective title (the override when
    // set, else the active tab's terminal-reported title).
    var title_buf: [257]u16 = undefined;
    var title_len: usize = 0;
    if (window.title_override) |t| {
        title_len = std.unicode.utf8ToUtf16Le(title_buf[0..256], t) catch 0;
    } else if (window.tab_count > 0) {
        const tlen = window.tab_title_lens[window.active_tab];
        @memcpy(title_buf[0..tlen], window.tab_titles[window.active_tab][0..tlen]);
        title_len = tlen;
    }
    title_buf[title_len] = 0;

    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        l.edit.left,
        l.edit.top,
        l.edit.right - l.edit.left,
        l.edit.bottom - l.edit.top,
        hwnd,
        @ptrFromInt(@as(usize, EDIT_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    const ok_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("OK"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_DEFPUSHBUTTON,
        l.ok.left,
        l.ok.top,
        l.ok.right - l.ok.left,
        l.ok.bottom - l.ok.top,
        hwnd,
        @ptrFromInt(@as(usize, w32.IDOK)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    const cancel_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.cancel.left,
        l.cancel.top,
        l.cancel.right - l.cancel.left,
        l.cancel.bottom - l.cancel.top,
        hwnd,
        @ptrFromInt(@as(usize, w32.IDCANCEL)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        alloc.destroy(self);
        return;
    };
    _ = w32.SetWindowTheme(ok_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    _ = w32.SetWindowTheme(cancel_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    self.* = .{
        .window = window,
        .hwnd = hwnd,
        .edit = edit,
        .ok_btn = ok_btn,
        .cancel_btn = cancel_btn,
    };

    // DPI-scaled dialog font for all controls.
    self.font = w32.CreateFontW(
        -l.font_h,
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
    if (self.font) |f| {
        if (label) |lbl| _ = w32.SendMessageW(lbl, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(ok_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(cancel_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    window.rename_dialog = self;

    // Modal to the owner: no input reaches it until the dialog closes.
    _ = w32.EnableWindow(owner, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(edit);
    // Select-all so typing replaces the current title.
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    edit_brush = w32.CreateSolidBrush(COLOR_EDIT_BG);
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
        log.warn("rename dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *RenameDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) {
                switch (control_id) {
                    w32.IDOK => {
                        self.finish();
                        return 0;
                    },
                    w32.IDCANCEL => {
                        self.cancel();
                        return 0;
                    },
                    else => {},
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            self.cancel();
            return 0;
        },
        w32.WM_ACTIVATE => {
            // Restore focus to the edit when the dialog is reactivated
            // (e.g. after alt-tabbing away) and no child holds it.
            const state: u16 = @intCast(wparam & 0xFFFF);
            if (state != w32.WA_INACTIVE) {
                const focus = w32.GetFocus();
                const owned = focus != null and self.ownsHwnd(focus.?);
                if (!owned) _ = w32.SetFocus(self.edit);
            }
            return 0;
        },
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_EDIT_BG);
            if (edit_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_LABEL);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// True when the given HWND is the dialog or one of its controls. The
/// main message loop uses this to route WM_KEYDOWN to `handleKey` (and to
/// keep dialog children away from the Surface-cast intercepts).
pub fn ownsHwnd(self: *const RenameDialog, hwnd: w32.HWND) bool {
    return hwnd == self.hwnd or hwnd == self.edit or
        hwnd == self.ok_btn or hwnd == self.cancel_btn;
}

/// Keyboard focus targets, in Tab order.
pub const Focusable = enum { edit, ok, cancel };

/// Pure Tab-order cycle: forward edit -> OK -> Cancel -> edit; backwards
/// reversed. Unit tested below.
pub fn nextFocus(cur: Focusable, backwards: bool) Focusable {
    return if (backwards) switch (cur) {
        .edit => .cancel,
        .ok => .edit,
        .cancel => .ok,
    } else switch (cur) {
        .edit => .ok,
        .ok => .cancel,
        .cancel => .edit,
    };
}

/// Handle a dialog key from the main message loop. Returns true when the
/// key was consumed (the message must not be translated/dispatched).
pub fn handleKey(self: *RenameDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.cancel();
            return true;
        },
        w32.VK_RETURN => {
            // Enter activates the focused button, else the default (OK) -
            // standard dialog convention.
            if (w32.GetFocus() == @as(?w32.HWND, self.cancel_btn)) {
                self.cancel();
            } else {
                self.finish();
            }
            return true;
        },
        w32.VK_TAB => {
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const focus = w32.GetFocus();
            const cur: Focusable = if (focus == @as(?w32.HWND, self.ok_btn))
                .ok
            else if (focus == @as(?w32.HWND, self.cancel_btn))
                .cancel
            else
                .edit;
            const next_hwnd = switch (nextFocus(cur, backwards)) {
                .edit => self.edit,
                .ok => self.ok_btn,
                .cancel => self.cancel_btn,
            };
            _ = w32.SetFocus(next_hwnd);
            return true;
        },
        else => return false,
    }
}

/// Commit: apply the edit text as the window's title override (the
/// `+rename` path - wins over terminal titles per T10). Empty clears the
/// override, reverting to terminal-reported titles.
pub fn finish(self: *RenameDialog) void {
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(self.edit, &wbuf, wbuf.len));
    var utf8_buf: [1024]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..wlen]) catch 0;

    const window = self.window;
    self.close();
    window.setTitleOverride(if (utf8_len > 0) utf8_buf[0..utf8_len] else null);
}

/// Dismiss without applying.
pub fn cancel(self: *RenameDialog) void {
    self.close();
}

/// Tear down: re-enable and refocus the owner, destroy the dialog, free.
/// The owner MUST be re-enabled before the dialog is destroyed, otherwise
/// Windows may activate another application's window.
fn close(self: *RenameDialog) void {
    const window = self.window;
    window.rename_dialog = null;

    if (window.hwnd) |owner| _ = w32.EnableWindow(owner, 1);

    // Clear the userdata so messages during teardown hit DefWindowProc
    // instead of re-entering handlers on a dying dialog.
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }

    if (window.hwnd) |owner| _ = w32.SetForegroundWindow(owner);
    if (window.getActiveSurface()) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }

    window.app.core_app.alloc.destroy(self);
}

// ---------------------------------------------------------------------
// Tests (pure logic only - run in the win32 test lane)
// ---------------------------------------------------------------------

const testing = std.testing;

test "nextFocus: forward cycle edit -> ok -> cancel -> edit" {
    try testing.expectEqual(Focusable.ok, nextFocus(.edit, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.ok, false));
    try testing.expectEqual(Focusable.edit, nextFocus(.cancel, false));
}

test "nextFocus: backward cycle edit -> cancel -> ok -> edit" {
    try testing.expectEqual(Focusable.cancel, nextFocus(.edit, true));
    try testing.expectEqual(Focusable.edit, nextFocus(.ok, true));
    try testing.expectEqual(Focusable.ok, nextFocus(.cancel, true));
}

test "layout: controls nest inside the client area at 1.0 scale" {
    const l = layout(1.0);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.label, l.edit, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
        try testing.expect(r.right > r.left and r.bottom > r.top);
    }
}

test "layout: buttons right-aligned, OK left of Cancel, no overlap" {
    const l = layout(1.0);
    try testing.expect(l.ok.right < l.cancel.left);
    try testing.expectEqual(l.edit.right, l.cancel.right);
    try testing.expectEqual(l.ok.top, l.cancel.top);
}

test "layout: scales with DPI" {
    const l1 = layout(1.0);
    const l2 = layout(2.0);
    try testing.expectEqual(l1.client_w * 2, l2.client_w);
    try testing.expectEqual(l1.client_h * 2, l2.client_h);
    try testing.expectEqual(l1.edit.left * 2, l2.edit.left);
    try testing.expectEqual(l1.font_h * 2, l2.font_h);
}
