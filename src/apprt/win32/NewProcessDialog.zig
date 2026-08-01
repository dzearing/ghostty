//! The Activity Monitor's "New Process" dialog (T286): a command and an
//! optional working directory, started on the panel's source.
//!
//! The win32 port of Mac's `NewProcessSheet`
//! (`RemoteActivityMonitorView.swift:1124-1169`), which is a 380-wide sheet with
//! a headline, two labeled fields and a Cancel/Start pair whose Start is
//! disabled while the command is blank.
//!
//! Structurally this is `HostSettingsDialog` with two plain EDITs instead of an
//! EDIT and a combo: same synchronous API (disable the owner, run a nested
//! pump — the T48-safe shape MessageBoxW itself uses, so the renderer thread and
//! the IPC server stay live), same dark chrome, same Enter/Escape/Tab routing
//! out of the nested loop. It is a separate class rather than a third
//! `ConfirmDialog` flavor for the reason that file already gives: a labeled
//! two-row form is a different dialog, not a wider message box.
//!
//! The headline goes in the CAPTION (win32's place for it) and the body
//! paragraph carries the one thing the Mac sheet has no reason to say: the
//! command runs through `cmd.exe /C`, which is what `proc_spawn.spawnDetached`
//! actually does on Windows.
//!
//! The layout math is pure and unit-tested at the bottom of this file, like
//! `HostSettingsDialog.layoutFor`.

const NewProcessDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const actions = @import("activity_actions.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyNewProcess");

/// Dialog colors — the shared dark dialog palette (ConfirmDialog /
/// HostSettingsDialog / the machine chooser).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_FIELD_BG = w32.RGB(30, 30, 30);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;

/// The longest command line / working directory the dialog will carry. Comfortably
/// past anything typed by hand and well inside `CreateProcess`'s own 32k limit.
pub const MAX_VALUE_LEN: usize = 1024;

const BODY_TEXT = blk: {
    @setEvalBranchQuota(4000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral(
        "The command runs through cmd.exe, detached from Ghoztty — it keeps " ++
            "running after this panel closes. Leave the working directory empty " ++
            "to use Ghoztty's own.",
    );
};

const CMD_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Command:");
const CWD_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Working directory:");
const CMD_PLACEHOLDER = std.unicode.utf8ToUtf16LeStringLiteral("e.g. notepad");
const CWD_PLACEHOLDER = std.unicode.utf8ToUtf16LeStringLiteral("Default");
const START_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Start");
const CANCEL_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Cancel");

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;
const IDC_CMD: u16 = 3;

hwnd: w32.HWND,
body: ?w32.HWND = null,
cmd_label: ?w32.HWND = null,
cwd_label: ?w32.HWND = null,
cmd_edit: w32.HWND,
cwd_edit: w32.HWND,
start_btn: w32.HWND,
cancel_btn: w32.HWND,
started: bool = false,
done: bool = false,

/// What the user left in the two fields. Slices point into the caller's buffers;
/// the command is reported VERBATIM (trimming belongs to the caller, the
/// `ConfirmDialog.prompt` contract).
pub const Result = struct {
    command: []const u8,
    working_directory: []const u8,
};

// ---------------------------------------------------------------------
// Layout (pure)
// ---------------------------------------------------------------------

pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    body: w32.RECT,
    cmd_label: w32.RECT,
    cmd_field: w32.RECT,
    cwd_label: w32.RECT,
    cwd_field: w32.RECT,
    start: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
};

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Geometry for the dialog, in physical pixels. `text_w`/`text_h` are the
/// measured extent of the body paragraph, `label_w` the widest label, `btn_w`
/// the (already padded) button width.
///
/// Same proportions as `HostSettingsDialog.layoutFor` — a right-aligned label
/// column beside fields that share one left edge and run to the trailing
/// margin — because they are the same form, and two dialogs the user opens from
/// the same window must not disagree about their own margins (design system §1).
pub fn layoutFor(
    scale: f32,
    text_w: i32,
    text_h: i32,
    label_w: i32,
    btn_w: i32,
) Layout {
    const margin = px(16, scale);
    const label_gap = px(8, scale);
    const field_h = px(26, scale);
    const row_gap = px(10, scale);
    const body_gap = px(14, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);
    const btn_gap_v = px(18, scale);
    // Mac's sheet is 380 wide with the fields filling it; this is the same
    // floor expressed as the field, so a long body paragraph widens the dialog
    // rather than squeezing the input.
    const min_field_w = px(240, scale);

    const rows_w = label_w + label_gap + min_field_w;
    const btns_w = 2 * btn_w + btn_gap_h;

    var client_w = margin + text_w + margin;
    client_w = @max(client_w, margin + rows_w + margin);
    client_w = @max(client_w, margin + btns_w + margin);
    client_w = @max(client_w, px(420, scale));

    const body_top = margin;
    const row1_top = body_top + text_h + body_gap;
    const row2_top = row1_top + field_h + row_gap;
    const btn_top = row2_top + field_h + btn_gap_v;
    const client_h = btn_top + btn_h + margin;

    const field_left = margin + label_w + label_gap;
    const field_right = client_w - margin;
    const label_h = px(18, scale);
    const label_drop = @divTrunc(field_h - label_h, 2);

    const cancel_left = client_w - margin - btn_w;
    const start_left = cancel_left - btn_gap_h - btn_w;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .body = .{
            .left = margin,
            .top = body_top,
            .right = client_w - margin,
            .bottom = body_top + text_h,
        },
        .cmd_label = .{
            .left = margin,
            .top = row1_top + label_drop,
            .right = margin + label_w,
            .bottom = row1_top + label_drop + label_h,
        },
        .cmd_field = .{
            .left = field_left,
            .top = row1_top,
            .right = field_right,
            .bottom = row1_top + field_h,
        },
        .cwd_label = .{
            .left = margin,
            .top = row2_top + label_drop,
            .right = margin + label_w,
            .bottom = row2_top + label_drop + label_h,
        },
        .cwd_field = .{
            .left = field_left,
            .top = row2_top,
            .right = field_right,
            .bottom = row2_top + field_h,
        },
        .start = .{
            .left = start_left,
            .top = btn_top,
            .right = start_left + btn_w,
            .bottom = btn_top + btn_h,
        },
        .cancel = .{
            .left = cancel_left,
            .top = btn_top,
            .right = cancel_left + btn_w,
            .bottom = btn_top + btn_h,
        },
        .font_h = px(15, scale),
    };
}

// ---------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------

/// Ask for a command to start on `source_label`, returning what the user typed
/// (verbatim, written into `cmd_buf`/`cwd_buf`) or null when they cancelled.
///
/// `owner` is disabled for the duration; the nested pump keeps the app's
/// renderer/IPC alive. `refocus` receives deferred focus afterwards (T48).
pub fn prompt(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    source_label: []const u8,
    cmd_buf: []u8,
    cwd_buf: []u8,
) ?Result {
    registerClass(app) orelse return null;

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;

    // Caption: Mac's headline ("New Process on <source>"), which on win32
    // belongs in the title bar.
    var caption_buf: [256]u16 = undefined;
    const caption = captionFor(&caption_buf, source_label);

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

    var text_rect: w32.RECT = .{ .left = 0, .top = 0, .right = px(420, scale), .bottom = 0 };
    var label_w: i32 = 0;
    var btn_label_w: i32 = 0;
    {
        const hdc = w32.GetDC(null) orelse return null;
        defer _ = w32.ReleaseDC(null, hdc);
        const prev = if (font) |f| w32.SelectObject(hdc, f) else null;
        defer if (prev) |p| {
            _ = w32.SelectObject(hdc, p);
        };
        _ = w32.DrawTextW(
            hdc,
            BODY_TEXT.ptr,
            @intCast(BODY_TEXT.len),
            &text_rect,
            w32.DT_CALCRECT | w32.DT_WORDBREAK | w32.DT_NOPREFIX,
        );
        for ([_][:0]const u16{ CMD_LABEL, CWD_LABEL }) |s| {
            label_w = @max(label_w, measure(hdc, s));
        }
        for ([_][:0]const u16{ START_LABEL, CANCEL_LABEL }) |s| {
            btn_label_w = @max(btn_label_w, measure(hdc, s));
        }
    }

    const l = layoutFor(
        scale,
        text_rect.right - text_rect.left,
        text_rect.bottom - text_rect.top,
        label_w,
        buttonWidth(scale, btn_label_w),
    );

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

    // The dialog lives on this stack frame: `prompt` does not return until the
    // nested loop is done, so nothing needs to be allocated.
    var self: NewProcessDialog = .{
        .hwnd = undefined,
        .cmd_edit = undefined,
        .cwd_edit = undefined,
        .start_btn = undefined,
        .cancel_btn = undefined,
    };

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        caption,
        style,
        x,
        y,
        outer_w,
        outer_h,
        owner,
        null,
        app.hinstance,
        null,
    ) orelse return null;
    self.hwnd = hwnd;

    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    self.body = createStatic(app, hwnd, BODY_TEXT, l.body, 0);
    self.cmd_label = createStatic(app, hwnd, CMD_LABEL, l.cmd_label, w32.SS_RIGHT);
    self.cwd_label = createStatic(app, hwnd, CWD_LABEL, l.cwd_label, w32.SS_RIGHT);

    self.cmd_edit = createEdit(app, hwnd, l.cmd_field, IDC_CMD, CMD_PLACEHOLDER) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    self.cwd_edit = createEdit(app, hwnd, l.cwd_field, 0, CWD_PLACEHOLDER) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };

    if (font) |f| {
        if (self.body) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.cmd_label) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.cwd_label) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(self.cmd_edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(self.cwd_edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    self.start_btn = createButton(app, hwnd, START_LABEL, l.start, IDOK, true, font) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    self.cancel_btn = createButton(app, hwnd, CANCEL_LABEL, l.cancel, IDCANCEL, false, font) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    // Mac's `.disabled(cmd.isEmpty)`: a dialog that opens with a live Start
    // could spawn nothing at all (design system §2.2 — a disabled control is an
    // honest state, a live one that does nothing is a defect).
    _ = w32.EnableWindow(self.start_btn, 0);

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&self)));

    if (owner) |o| _ = w32.EnableWindow(o, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.cmd_edit);

    self.runModal();

    // Read the fields BEFORE the window is destroyed.
    var result: ?Result = null;
    if (self.started) {
        result = .{
            .command = cmd_buf[0..readText(self.cmd_edit, cmd_buf)],
            .working_directory = cwd_buf[0..readText(self.cwd_edit, cwd_buf)],
        };
    }

    // The owner MUST be re-enabled before the dialog is destroyed, else Windows
    // may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48

    return result;
}

/// `New Process on <source>` (Mac's headline). Never fails — a caption is not
/// worth abandoning the dialog over.
fn captionFor(buf: []u16, source_label: []const u8) [*:0]const u16 {
    var tmp: [320]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "New Process on {s}", .{
        if (source_label.len > 160) source_label[0..160] else source_label,
    }) catch "New Process";
    return (utf16z(buf, text) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("New Process")).ptr;
}

fn measure(hdc: w32.HDC, s: [:0]const u16) i32 {
    var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.DrawTextW(hdc, s.ptr, @intCast(s.len), &r, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    return r.right - r.left;
}

/// Button width: the standard 88 DIP, widened when a caption needs it (the
/// ConfirmDialog rule).
pub fn buttonWidth(scale: f32, max_label_w: i32) i32 {
    return @max(px(88, scale), max_label_w + px(24, scale));
}

fn createStatic(
    app: *App,
    parent: w32.HWND,
    text: [:0]const u16,
    r: w32.RECT,
    extra_style: u32,
) ?w32.HWND {
    return w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        text.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_NOPREFIX | extra_style,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        parent,
        null,
        app.hinstance,
        null,
    );
}

fn createEdit(
    app: *App,
    parent: w32.HWND,
    r: w32.RECT,
    id: u16,
    placeholder: [:0]const u16,
) ?w32.HWND {
    const h = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        parent,
        if (id == 0) null else @ptrFromInt(@as(usize, id)),
        app.hinstance,
        null,
    ) orelse return null;
    _ = w32.SetWindowTheme(h, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    _ = w32.SendMessageW(h, w32.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(placeholder.ptr)));
    return h;
}

fn createButton(
    app: *App,
    parent: w32.HWND,
    label: [:0]const u16,
    r: w32.RECT,
    id: u16,
    default: bool,
    font: ?*anyopaque,
) ?w32.HWND {
    const h = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        label.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | (if (default) w32.BS_DEFPUSHBUTTON else 0),
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        parent,
        @ptrFromInt(@as(usize, id)),
        app.hinstance,
        null,
    ) orelse return null;
    _ = w32.SetWindowTheme(h, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    if (font) |f| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
    return h;
}

/// UTF-8 → NUL-terminated UTF-16 in `buf`, or null when it does not fit.
fn utf16z(buf: []u16, text: []const u8) ?[:0]const u16 {
    if (text.len + 1 > buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Copy a control's text into `buf` as UTF-8, returning its length (0 when it
/// does not fit — a truncated command is worse than none).
fn readText(h: w32.HWND, buf: []u8) usize {
    var wbuf: [MAX_VALUE_LEN + 1]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, wbuf.len));
    return std.unicode.utf16LeToUtf8(buf, wbuf[0..wlen]) catch 0;
}

/// Is the command field non-blank? Read live off the control, so the Start
/// button's enabled state and the Enter key agree on one source of truth.
fn commandValid(self: *const NewProcessDialog) bool {
    var buf: [MAX_VALUE_LEN]u8 = undefined;
    const n = readText(self.cmd_edit, &buf);
    return actions.spawnCommandValid(buf[0..n]);
}

// ---------------------------------------------------------------------
// Modal loop + key routing
// ---------------------------------------------------------------------

/// Nested modal pump — the ConfirmDialog shape: WM_APP_SETFOCUS (T48 deferred
/// focus) is performed here rather than dispatched; everything else flows
/// through Translate/Dispatch so the renderer and IPC stay live.
fn runModal(self: *NewProcessDialog) void {
    var msg: w32.MSG = undefined;
    while (!self.done) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT: repost for the outer loop and start nothing.
            w32.PostQuitMessage(@intCast(msg.wParam));
            self.started = false;
            return;
        }
        if (result < 0) {
            self.started = false;
            return;
        }
        if (msg.message == App.WM_APP_SETFOCUS) {
            if (msg.hwnd) |h| App.performDeferredFocus(h);
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

fn ownsHwnd(self: *const NewProcessDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.cmd_edit or hwnd == self.cwd_edit) return true;
    if (hwnd == self.start_btn or hwnd == self.cancel_btn) return true;
    return false;
}

/// Tab stops in order: command → working directory → Start → Cancel. Pure —
/// the cycle is `nextFocusIndex`, shared with ConfirmDialog's rule.
pub fn nextFocusIndex(cur: usize, stops: usize, backwards: bool) usize {
    if (stops == 0) return 0;
    if (backwards) return (cur + stops - 1) % stops;
    return (cur + 1) % stops;
}

fn finish(self: *NewProcessDialog, started: bool) void {
    self.started = started;
    self.done = true;
}

/// Handle a dialog key out of the nested pump. Returns true when consumed.
fn handleKey(self: *NewProcessDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.finish(false);
            return true;
        },
        w32.VK_RETURN => {
            const focus = w32.GetFocus();
            if (focus == @as(?w32.HWND, self.cancel_btn)) {
                self.finish(false);
                return true;
            }
            // Enter commits what was typed — but only when there IS a command.
            // Otherwise it is swallowed, matching the disabled Start button
            // rather than silently spawning "".
            if (self.commandValid()) self.finish(true);
            return true;
        },
        w32.VK_TAB => {
            const stops: [4]w32.HWND = .{ self.cmd_edit, self.cwd_edit, self.start_btn, self.cancel_btn };
            const focus = w32.GetFocus();
            var cur: usize = 0;
            for (stops, 0..) |h, i| {
                if (focus == @as(?w32.HWND, h)) cur = i;
            }
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            _ = w32.SetFocus(stops[nextFocusIndex(cur, stops.len, backwards)]);
            return true;
        },
        else => return false,
    }
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    bg_brush = w32.CreateSolidBrush(COLOR_BG);
    field_brush = w32.CreateSolidBrush(COLOR_FIELD_BG);
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
        log.warn("new process dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *NewProcessDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == IDC_CMD and notification == w32.EN_CHANGE) {
                _ = w32.EnableWindow(self.start_btn, if (self.commandValid()) 1 else 0);
                return 0;
            }
            if (notification == w32.BN_CLICKED) switch (control_id) {
                IDOK => {
                    // Belt and braces: the button is disabled while the command
                    // is blank, but a synthesized BN_CLICKED does not check that.
                    if (self.commandValid()) self.finish(true);
                    return 0;
                },
                IDCANCEL => {
                    self.finish(false);
                    return 0;
                },
                else => {},
            };
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CLOSE => {
            // ✕ discards, like Cancel.
            self.finish(false);
            return 0;
        },
        w32.WM_ACTIVATE => {
            const state: u16 = @intCast(wparam & 0xFFFF);
            if (state != w32.WA_INACTIVE) {
                const focus = w32.GetFocus();
                const owned = focus != null and self.ownsHwnd(focus.?);
                if (!owned) _ = w32.SetFocus(self.cmd_edit);
            }
            return 0;
        },
        // Fields are fields, not dialog surface: without this they render as
        // white boxes.
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_FIELD_BG);
            if (field_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const ctl: ?w32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const is_label = (self.cmd_label != null and ctl == self.cmd_label) or
                (self.cwd_label != null and ctl == self.cwd_label);
            _ = w32.SetTextColor(hdc, if (is_label) COLOR_LABEL else COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_BG);
            if (bg_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORBTN => {
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
// Tests (pure layout / focus-cycle logic)
// ---------------------------------------------------------------------

const testing = std.testing;

test "layoutFor: every control nests inside the client area" {
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layoutFor(scale, 400, 60, 120, 88);
        try testing.expect(l.client_w > 0 and l.client_h > 0);
        for ([_]w32.RECT{
            l.body,      l.cmd_label, l.cmd_field, l.cwd_label,
            l.cwd_field, l.start,     l.cancel,
        }) |r| {
            try testing.expect(r.left >= 0 and r.top >= 0);
            try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
            try testing.expect(r.right > r.left and r.bottom > r.top);
        }
    }
}

test "layoutFor: the two rows never touch, and the buttons clear them" {
    // §0.1 — nothing touches anything. Asserted at 1.25 too, where most of
    // these defects are visible and 1.0 hides them.
    for ([_]f32{ 1.0, 1.25, 1.5, 2.0 }) |scale| {
        const l = layoutFor(scale, 400, 60, 120, 88);
        try testing.expect(l.cmd_field.bottom < l.cwd_field.top);
        try testing.expect(l.cwd_field.bottom < l.start.top);
        try testing.expect(l.body.bottom < l.cmd_field.top);
        // The label column and the fields share a gutter, never an edge.
        try testing.expect(l.cmd_label.right < l.cmd_field.left);
        try testing.expect(l.cwd_label.right < l.cwd_field.left);
        // Start sits left of Cancel with a gap between them.
        try testing.expect(l.start.right < l.cancel.left);
    }
}

test "layoutFor: both fields share one left and right edge" {
    for ([_]f32{ 1.0, 1.25, 2.0 }) |scale| {
        const l = layoutFor(scale, 400, 60, 120, 88);
        try testing.expectEqual(l.cmd_field.left, l.cwd_field.left);
        try testing.expectEqual(l.cmd_field.right, l.cwd_field.right);
        try testing.expectEqual(
            l.cmd_field.bottom - l.cmd_field.top,
            l.cwd_field.bottom - l.cwd_field.top,
        );
    }
}

test "layoutFor: a long body paragraph widens the dialog, it never squeezes the fields" {
    const narrow = layoutFor(1.0, 200, 40, 120, 88);
    const wide = layoutFor(1.0, 900, 40, 120, 88);
    try testing.expect(wide.client_w > narrow.client_w);
    try testing.expect(wide.cmd_field.right - wide.cmd_field.left >=
        narrow.cmd_field.right - narrow.cmd_field.left);
}

test "buttonWidth: floors at 88 DIP and grows for a long caption" {
    try testing.expectEqual(@as(i32, 88), buttonWidth(1.0, 10));
    try testing.expect(buttonWidth(1.0, 200) > 88);
    try testing.expectEqual(@as(i32, 176), buttonWidth(2.0, 10));
}

test "nextFocusIndex: forward and backward wrap around the four stops" {
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 4, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(3, 4, false));
    try testing.expectEqual(@as(usize, 3), nextFocusIndex(0, 4, true));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(0, 0, false));
}
