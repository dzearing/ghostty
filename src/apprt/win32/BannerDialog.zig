//! Modal-ish "Set Pane Banner" editor for the win32 apprt (T35), the
//! Windows analog of the Mac Cmd+R banner editor. Follows the T50
//! RenameDialog pattern: real owner-centered dark dialog, owner disabled
//! while open, app message loop (renderer + IPC) keeps running.
//!
//! The edit is multi-line (banners support line breaks): Enter inserts a
//! newline, Ctrl+Enter (or OK) saves, Escape cancels — the Windows mirror
//! of the Mac editor's Return/Cmd+Return/Escape. Saving routes through
//! `Surface.setPaneBanner`, the same path as `+set-banner` and OSC 7778;
//! empty text clears the banner.
//!
//! Enter/Escape/Tab are routed here by the main message loop via
//! `handleKey` (see the WM_KEYDOWN intercept in App.run), like the rename
//! dialog. Unlike it, plain Enter is NOT consumed — it falls through to
//! the ES_WANTRETURN edit as a newline.

const BannerDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const type_ramp = @import("type_ramp.zig");
const utf16_text = @import("utf16_text.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyBannerDialog");
const EDIT_ID: u16 = 100;

/// Max banner source length the editor round-trips (UTF-16 units).
const MAX_TEXT: usize = 2048;

window: *Window,
/// The pane whose banner is being edited (banners are per-pane).
surface: *Surface,
hwnd: w32.HWND,
edit: w32.HWND,
ok_btn: w32.HWND,
cancel_btn: w32.HWND,
font: ?*anyopaque = null,

/// Dialog colors (dark chrome, same palette as RenameDialog).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_EDIT_BG = w32.RGB(30, 30, 30);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var edit_brush: ?w32.HBRUSH = null;

/// Dialog layout in physical pixels from the owner's DPI scale. Pure —
/// unit tested below. Mirrors RenameDialog.layout but with a multi-line
/// edit (~5 visible lines) and a second hint label.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    label: w32.RECT,
    edit: w32.RECT,
    hint: w32.RECT,
    ok: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
};

pub fn layout(scale: f32) Layout {
    const body = type_ramp.body(scale);
    const margin = px(16, scale);
    // The label and the hint are each ONE line of body text, so their boxes
    // come from the ramp (T313) rather than from a flat 16 that cleared the
    // old 15 px font by coincidence.
    const label_h = type_ramp.lineBox(body, scale);
    const label_gap = px(6, scale);
    const edit_h = px(96, scale); // ~5 lines of body text + padding
    const hint_gap = px(6, scale);
    const hint_h = type_ramp.lineBox(body, scale);
    const btn_gap_v = px(12, scale);
    const btn_w = px(88, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);

    const client_w = px(460, scale);
    const client_h = margin + label_h + label_gap + edit_h + hint_gap +
        hint_h + btn_gap_v + btn_h + margin;

    const edit_top = margin + label_h + label_gap;
    const hint_top = edit_top + edit_h + hint_gap;
    const btn_top = hint_top + hint_h + btn_gap_v;
    const cancel_left = client_w - margin - btn_w;
    const ok_left = cancel_left - btn_gap_h - btn_w;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .label = .{ .left = margin, .top = margin, .right = client_w - margin, .bottom = margin + label_h },
        .edit = .{ .left = margin, .top = edit_top, .right = client_w - margin, .bottom = edit_top + edit_h },
        .hint = .{ .left = margin, .top = hint_top, .right = client_w - margin, .bottom = hint_top + hint_h },
        .ok = .{ .left = ok_left, .top = btn_top, .right = ok_left + btn_w, .bottom = btn_top + btn_h },
        .cancel = .{ .left = cancel_left, .top = btn_top, .right = cancel_left + btn_w, .bottom = btn_top + btn_h },
        .font_h = body.height,
    };
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Normalize editor output to banner source: CRLF -> LF in place, then
/// trim surrounding whitespace/newlines (a stray trailing newline must not
/// render as a blank banner line). Pure — unit tested below.
pub fn normalizeText(buf: []u8) []const u8 {
    var w: usize = 0;
    var r: usize = 0;
    while (r < buf.len) : (r += 1) {
        if (buf[r] == '\r' and r + 1 < buf.len and buf[r + 1] == '\n') continue;
        if (buf[r] == '\r') {
            buf[w] = '\n';
        } else {
            buf[w] = buf[r];
        }
        w += 1;
    }
    return std.mem.trim(u8, buf[0..w], " \t\r\n");
}

/// Open the banner editor for a pane. Idempotent per window: an already
/// open editor is focused instead (retargeted dialogs would lose edits).
pub fn open(surface: *Surface) void {
    const window = surface.parent_window;
    if (window.banner_dialog) |existing| {
        _ = w32.SetForegroundWindow(existing.hwnd);
        _ = w32.SetFocus(existing.edit);
        return;
    }

    const owner = window.hwnd orelse return;
    window.cancelTabRename();

    registerClass(window.app) orelse return;

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const l = layout(window.scale);

    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var owner_rect: w32.RECT = undefined;
    if (w32.GetWindowRect(owner, &owner_rect) == 0) return;
    const x = owner_rect.left + @divTrunc((owner_rect.right - owner_rect.left) - outer_w, 2);
    const y = owner_rect.top + @divTrunc((owner_rect.bottom - owner_rect.top) - outer_h, 2);

    const alloc = window.app.core_app.alloc;
    const self = alloc.create(BannerDialog) catch |err| {
        log.warn("banner dialog alloc failed err={}", .{err});
        return;
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Set Pane Banner"),
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

    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const label = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("Banner text (empty clears):"),
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

    // Prefill with the pane's current banner source (raw markdown),
    // LF -> CRLF so the multi-line EDIT shows real line breaks.
    var prefill: [MAX_TEXT:0]u16 = undefined;
    var prefill_len: usize = 0;
    if (surface.banner_text) |t| {
        // LF -> CRLF (byte-level; UTF-8 continuation bytes never equal
        // '\n') so the multi-line EDIT shows real line breaks.
        var crlf_buf: [MAX_TEXT]u8 = undefined;
        var n: usize = 0;
        for (t) |c| {
            if (n + 2 > crlf_buf.len) break;
            if (c == '\n') {
                crlf_buf[n] = '\r';
                n += 1;
            }
            crlf_buf[n] = c;
            n += 1;
        }
        prefill_len = std.unicode.utf8ToUtf16Le(prefill[0..MAX_TEXT], crlf_buf[0..n]) catch 0;
    }
    prefill[prefill_len] = 0;

    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&prefill),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_BORDER |
            w32.ES_MULTILINE | w32.ES_AUTOVSCROLL | w32.ES_WANTRETURN,
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

    const hint = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(
            "**bold**  *italic*  __underline__  `code`  [link](url) — Ctrl+Enter saves",
        ),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.hint.left,
        l.hint.top,
        l.hint.right - l.hint.left,
        l.hint.bottom - l.hint.top,
        hwnd,
        null,
        window.app.hinstance,
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
        .surface = surface,
        .hwnd = hwnd,
        .edit = edit,
        .ok_btn = ok_btn,
        .cancel_btn = cancel_btn,
    };

    self.font = w32.CreateFontW(
        -l.font_h,
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
    );
    if (self.font) |f| {
        if (label) |lbl| _ = w32.SendMessageW(lbl, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (hint) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(ok_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(cancel_btn, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    window.banner_dialog = self;

    _ = w32.EnableWindow(owner, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(edit);
    // Select-all so typing replaces the current banner.
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
        log.warn("banner dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *BannerDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

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

/// True when the given HWND is the dialog or one of its controls.
pub fn ownsHwnd(self: *const BannerDialog, hwnd: w32.HWND) bool {
    return hwnd == self.hwnd or hwnd == self.edit or
        hwnd == self.ok_btn or hwnd == self.cancel_btn;
}

pub const Focusable = enum { edit, ok, cancel };

/// Pure Tab-order cycle, same shape as RenameDialog. Unit tested below.
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
/// key was consumed. Plain Enter in the edit is NOT consumed — it falls
/// through to the ES_WANTRETURN edit as a newline; Ctrl+Enter saves.
pub fn handleKey(self: *BannerDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.cancel();
            return true;
        },
        w32.VK_RETURN => {
            const ctrl_held = w32.GetKeyState(@as(i32, w32.VK_CONTROL)) < 0;
            if (ctrl_held) {
                self.finish();
                return true;
            }
            const focus = w32.GetFocus();
            if (focus == @as(?w32.HWND, self.ok_btn)) {
                self.finish();
                return true;
            }
            if (focus == @as(?w32.HWND, self.cancel_btn)) {
                self.cancel();
                return true;
            }
            return false; // newline in the edit
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

/// Commit: normalize the edit text and apply it via Surface.setPaneBanner
/// (the `+set-banner`/OSC 7778 path). Empty clears the banner.
pub fn finish(self: *BannerDialog) void {
    var wbuf: [MAX_TEXT]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(self.edit, &wbuf, wbuf.len));
    // `MAX_TEXT * 3` is the measured worst case, and the bounded conversion
    // (T990) is what keeps it true if either size is ever edited alone.
    var utf8_buf: [MAX_TEXT * 3]u8 = undefined;
    const utf8_len = utf16_text.toUtf8Truncating(&utf8_buf, wbuf[0..wlen]);
    const text = normalizeText(utf8_buf[0..utf8_len]);

    const surface = self.surface;
    self.close();
    surface.setPaneBanner(if (text.len > 0) text else null);
}

/// Dismiss without applying.
pub fn cancel(self: *BannerDialog) void {
    self.close();
}

/// Tear down: re-enable and refocus the owner, destroy, free. The owner
/// MUST be re-enabled before the dialog is destroyed (else Windows may
/// activate another application's window).
fn close(self: *BannerDialog) void {
    const window = self.window;
    window.banner_dialog = null;

    if (window.hwnd) |owner| _ = w32.EnableWindow(owner, 1);

    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }

    if (window.hwnd) |owner| _ = w32.SetForegroundWindow(owner);
    if (window.getActiveSurface()) |s| {
        if (s.hwnd) |h| App.deferSetFocus(h); // T48
    }

    window.app.core_app.alloc.destroy(self);
}

// ---------------------------------------------------------------------
// Tests (pure logic only — run in the win32 test lane)
// ---------------------------------------------------------------------

const testing = std.testing;

test "nextFocus cycles like RenameDialog" {
    try testing.expectEqual(Focusable.ok, nextFocus(.edit, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.ok, false));
    try testing.expectEqual(Focusable.edit, nextFocus(.cancel, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.edit, true));
}

test "layout: controls nest inside the client area and scale" {
    const l = layout(1.0);
    for ([_]w32.RECT{ l.label, l.edit, l.hint, l.ok, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
        try testing.expect(r.right > r.left and r.bottom > r.top);
    }
    try testing.expect(l.edit.bottom - l.edit.top >= 90); // multi-line
    const l2 = layout(2.0);
    try testing.expectEqual(l.client_w * 2, l2.client_w);
    try testing.expectEqual(l.client_h * 2, l2.client_h);
}

test "normalizeText: CRLF to LF and trim" {
    var buf1 = "a\r\nb\r\nc".*;
    try testing.expectEqualStrings("a\nb\nc", normalizeText(&buf1));
    var buf2 = "  hello \r\n".*;
    try testing.expectEqualStrings("hello", normalizeText(&buf2));
    var buf3 = "\r\n\r\n".*;
    try testing.expectEqualStrings("", normalizeText(&buf3));
    var buf4 = "bare\rreturn".*;
    try testing.expectEqualStrings("bare\nreturn", normalizeText(&buf4));
}

test "layout: the fonts and the line boxes come from the ramp (T313)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale);
        try testing.expectEqual(type_ramp.body(scale).height, l.font_h);
        // The label and the hint each hold ONE line of that same body text, so
        // both boxes are the ramp's line box rather than a flat constant.
        const box = type_ramp.lineBox(type_ramp.body(scale), scale);
        try testing.expectEqual(box, l.label.bottom - l.label.top);
        try testing.expectEqual(box, l.hint.bottom - l.hint.top);
        try testing.expect(l.label.bottom - l.label.top > l.font_h);
    }
    // The retired 15 px body is gone, at the size a user actually sees it.
    try testing.expectEqual(@as(i32, 14), layout(1.0).font_h);
}
