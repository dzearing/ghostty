//! The "Host Settings" editor (T174): the per-host defaults — a working
//! directory and a shell — that NEW sessions on one remote machine start with.
//!
//! The win32 port of Mac's `promptHostSettings`
//! (`MachineChooserView.swift:1143`), which is an NSAlert with a two-row
//! accessoryView: a right-aligned label column, a text field for the working
//! directory, and an EDITABLE combo box (presets + free text) for the shell.
//! Both fields empty mean "use the remote's own default", so clearing them is
//! how a user removes a setting.
//!
//! Structurally this is `ConfirmDialog` with a second field and a combo instead
//! of one plain EDIT: same synchronous API (disable the owner, run a nested
//! pump — the T48-safe shape MessageBoxW itself uses, so the renderer thread
//! and the IPC server stay live), same dark chrome, same Enter/Escape/Tab
//! routing out of the nested loop. It is a separate class rather than a third
//! `Options` flavor on ConfirmDialog because a labeled two-row form is a
//! different dialog, not a wider message box (the no-mega-files rule).
//!
//! The layout math is pure and unit-tested at the bottom of this file, like
//! `ConfirmDialog.layoutFor`; the store it reads and writes is
//! `host_defaults.zig`.

const HostSettingsDialog = @This();

const std = @import("std");
const App = @import("App.zig");
const host_defaults = @import("host_defaults.zig");
const type_ramp = @import("type_ramp.zig");
const w32 = @import("win32.zig");
const utf16_text = @import("utf16_text.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyHostSettings");

/// Dialog colors — the shared dark dialog palette (ConfirmDialog / RenameDialog
/// / the machine chooser).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_FIELD_BG = w32.RGB(30, 30, 30);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;

/// The informative line above the fields, matching Mac's `informativeText`
/// word for word — it is the only place the "values are REMOTE-native" rule is
/// explained to the user.
const BODY_TEXT = blk: {
    // A paragraph this long outruns the default comptime branch quota inside
    // `utf8ToUtf16LeStringLiteral`.
    @setEvalBranchQuota(4000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral(
        "Defaults for new terminals on this machine. Both are values on the remote " ++
            "machine (e.g. wsl.exe or C:\\dev on a Windows host). Leave a field empty " ++
            "to use the remote's own default.",
    );
};

const WD_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Working directory:");
const SHELL_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Shell:");
const PLACEHOLDER = std.unicode.utf8ToUtf16LeStringLiteral("Remote default");
const SAVE_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Save");
const CANCEL_LABEL = std.unicode.utf8ToUtf16LeStringLiteral("Cancel");

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;

hwnd: w32.HWND,
body: ?w32.HWND = null,
wd_label: ?w32.HWND = null,
shell_label: ?w32.HWND = null,
wd_edit: w32.HWND,
shell_combo: w32.HWND,
save_btn: w32.HWND,
cancel_btn: w32.HWND,
saved: bool = false,
done: bool = false,

/// What the user left in the two fields. Slices point into the caller's
/// buffers; whitespace/empty handling belongs to `host_defaults.normalize`, so
/// this reports the fields verbatim (the `ConfirmDialog.prompt` contract).
pub const Result = struct {
    working_directory: []const u8,
    shell: []const u8,
};

// ---------------------------------------------------------------------
// Layout (pure)
// ---------------------------------------------------------------------

pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    body: w32.RECT,
    wd_label: w32.RECT,
    wd_field: w32.RECT,
    shell_label: w32.RECT,
    /// The combo box's CLOSED geometry. Its window is created taller than this
    /// (the drop-down list lives in the rest of the window rect); only the
    /// closed band participates in the layout.
    shell_field: w32.RECT,
    save: w32.RECT,
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
/// Mac's accessoryView proportions: a right-aligned label column beside fields
/// that share one left edge and run to the trailing margin.
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
    // Mac's `fieldWidth`. The floor, not the actual — fields stretch with the
    // dialog, which the body paragraph usually makes wider than this.
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
    // Labels sit on the field's text baseline band, not the field's full box —
    // one line of the ramp's body, boxed by the ramp (T313).
    const label_h = type_ramp.lineBox(type_ramp.body(scale), scale);
    const label_drop = @divTrunc(field_h - label_h, 2);

    const cancel_left = client_w - margin - btn_w;
    const save_left = cancel_left - btn_gap_h - btn_w;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .body = .{
            .left = margin,
            .top = body_top,
            .right = client_w - margin,
            .bottom = body_top + text_h,
        },
        .wd_label = .{
            .left = margin,
            .top = row1_top + label_drop,
            .right = margin + label_w,
            .bottom = row1_top + label_drop + label_h,
        },
        .wd_field = .{
            .left = field_left,
            .top = row1_top,
            .right = field_right,
            .bottom = row1_top + field_h,
        },
        .shell_label = .{
            .left = margin,
            .top = row2_top + label_drop,
            .right = margin + label_w,
            .bottom = row2_top + label_drop + label_h,
        },
        .shell_field = .{
            .left = field_left,
            .top = row2_top,
            .right = field_right,
            .bottom = row2_top + field_h,
        },
        .save = .{
            .left = save_left,
            .top = btn_top,
            .right = save_left + btn_w,
            .bottom = btn_top + btn_h,
        },
        .cancel = .{
            .left = cancel_left,
            .top = btn_top,
            .right = cancel_left + btn_w,
            .bottom = btn_top + btn_h,
        },
        // The Ctrl+Shift+N surface's body role (T310). Host Settings is part of
        // that surface, so it takes the ramp with the chooser rather than
        // keeping the seventh copy of a 15 nobody chose.
        .font_h = type_ramp.body(scale).height,
    };
}

// ---------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------

/// Edit `current` for the machine named `machine_name`, returning what the user
/// saved (verbatim field contents, written into `wd_buf`/`shell_buf`) or null
/// when they cancelled.
///
/// `owner` is disabled for the duration; the nested pump keeps the app's
/// renderer/IPC alive. `refocus` receives deferred focus afterwards (T48).
pub fn prompt(
    app: *App,
    owner: ?w32.HWND,
    scale: f32,
    refocus: ?w32.HWND,
    machine_name: []const u8,
    current: host_defaults.Settings,
    wd_buf: []u8,
    shell_buf: []u8,
) ?Result {
    registerClass(app) orelse return null;

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;

    // Caption: Mac's `messageText`, which on win32 belongs in the title bar
    // (the body paragraph carries the explanation).
    var caption_buf: [256]u16 = undefined;
    const caption = captionFor(&caption_buf, machine_name);

    // T310 pointed this dialog's LAYOUT at the ramp but left the GDI font it
    // actually draws with at the retired 15, so `layoutFor` was doing its
    // arithmetic against a 14 that no text on screen was ever set in. Both
    // ends read the ramp now (T313) — a half-migrated dialog is worse than an
    // unmigrated one, because its numbers look right.
    const font = w32.CreateFontW(
        -type_ramp.body(scale).height,
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
    defer if (font) |f| {
        _ = w32.DeleteObject(f);
    };

    // Measure the body paragraph (wrapped) and the widest label/button caption.
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
        for ([_][:0]const u16{ WD_LABEL, SHELL_LABEL }) |s| {
            label_w = @max(label_w, measure(hdc, s));
        }
        for ([_][:0]const u16{ SAVE_LABEL, CANCEL_LABEL }) |s| {
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
    var self: HostSettingsDialog = .{
        .hwnd = undefined,
        .wd_edit = undefined,
        .shell_combo = undefined,
        .save_btn = undefined,
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
    self.wd_label = createStatic(app, hwnd, WD_LABEL, l.wd_label, w32.SS_RIGHT);
    self.shell_label = createStatic(app, hwnd, SHELL_LABEL, l.shell_label, w32.SS_RIGHT);

    // Working directory: a plain EDIT seeded with the stored value.
    var seed_buf: [host_defaults.MAX_VALUE_LEN + 1]u16 = undefined;
    const wd_seed = utf16z(&seed_buf, current.working_directory orelse "") orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    self.wd_edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        wd_seed.ptr,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        l.wd_field.left,
        l.wd_field.top,
        l.wd_field.right - l.wd_field.left,
        l.wd_field.bottom - l.wd_field.top,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    _ = w32.SetWindowTheme(self.wd_edit, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    // "Remote default" while empty, so the meaning of an empty field is visible
    // (Mac's `placeholderString`).
    _ = w32.SendMessageW(self.wd_edit, w32.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(PLACEHOLDER.ptr)));

    // Shell: an EDITABLE combo box. The window is created tall enough for the
    // preset list; `CB_SETITEMHEIGHT(-1)` sets the CLOSED band so it lines up
    // with the EDIT above it.
    const field_h = l.shell_field.bottom - l.shell_field.top;
    const item_h = l.font_h + px(6, scale);
    self.shell_combo = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX"),
        // Seeded below with SetWindowTextW, after the presets are added.
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_VSCROLL |
            w32.CBS_DROPDOWN | w32.CBS_AUTOHSCROLL,
        l.shell_field.left,
        l.shell_field.top,
        l.shell_field.right - l.shell_field.left,
        field_h + item_h * @as(i32, @intCast(host_defaults.shell_presets.len)),
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    _ = w32.SetWindowTheme(self.shell_combo, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_CFD"), null);

    if (font) |f| {
        if (self.body) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.wd_label) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        if (self.shell_label) |h| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(self.wd_edit, w32.WM_SETFONT, @intFromPtr(f), 1);
        _ = w32.SendMessageW(self.shell_combo, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    // After WM_SETFONT (which resets item heights to the font's).
    _ = w32.SendMessageW(self.shell_combo, w32.CB_SETITEMHEIGHT, @bitCast(@as(isize, -1)), field_h - px(6, scale));
    _ = w32.SendMessageW(self.shell_combo, w32.CB_SETITEMHEIGHT, 0, item_h);

    // The presets, then the stored value as the field's text. Adding the
    // presets does not select one, so a stored value that is not a preset (any
    // typed path) survives — the whole point of an editable combo.
    for (host_defaults.shell_presets) |preset| {
        var pbuf: [64]u16 = undefined;
        const w = utf16z(&pbuf, preset) orelse continue;
        _ = w32.SendMessageW(self.shell_combo, w32.CB_ADDSTRING, 0, @bitCast(@intFromPtr(w.ptr)));
    }
    var shell_seed_buf: [host_defaults.MAX_VALUE_LEN + 1]u16 = undefined;
    if (utf16z(&shell_seed_buf, current.shell orelse "")) |s| {
        _ = w32.SetWindowTextW(self.shell_combo, s.ptr);
    }
    _ = w32.SendMessageW(
        self.shell_combo,
        w32.CB_SETCUEBANNER,
        0,
        @bitCast(@intFromPtr(PLACEHOLDER.ptr)),
    );

    self.save_btn = createButton(app, hwnd, SAVE_LABEL, l.save, IDOK, true, font) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };
    self.cancel_btn = createButton(app, hwnd, CANCEL_LABEL, l.cancel, IDCANCEL, false, font) orelse {
        _ = w32.DestroyWindow(hwnd);
        return null;
    };

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(&self)));

    if (owner) |o| _ = w32.EnableWindow(o, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    // Mac's `initialFirstResponder = wdField`, with the seed selected so typing
    // replaces it.
    _ = w32.SetFocus(self.wd_edit);
    _ = w32.SendMessageW(self.wd_edit, w32.EM_SETSEL, 0, -1);

    self.runModal();

    // Read the fields BEFORE the window is destroyed.
    var result: ?Result = null;
    if (self.saved) {
        result = .{
            .working_directory = wd_buf[0..readText(self.wd_edit, wd_buf)],
            .shell = shell_buf[0..readText(self.shell_combo, shell_buf)],
        };
    }

    // The owner MUST be re-enabled before the dialog is destroyed, else
    // Windows may activate another app's window.
    if (owner) |o| _ = w32.EnableWindow(o, 1);
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(hwnd);
    if (owner) |o| _ = w32.SetForegroundWindow(o);
    if (refocus) |h| App.deferSetFocus(h); // T48

    return result;
}

/// `Host Settings for "<name>"` (Mac's `messageText`), truncated with an
/// ellipsis if the name is absurd. Never fails — a caption is not worth
/// abandoning the dialog over.
fn captionFor(buf: []u16, machine_name: []const u8) [*:0]const u16 {
    const prefix = "Host Settings for \u{201c}";
    const suffix = "\u{201d}";
    var tmp: [320]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{s}{s}{s}", .{
        prefix,
        if (machine_name.len > 160) machine_name[0..160] else machine_name,
        suffix,
    }) catch "Host Settings";
    return (utf16z(buf, text) orelse
        std.unicode.utf8ToUtf16LeStringLiteral("Host Settings")).ptr;
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
/// does not fit — a truncated path is worse than none).
///
/// T990: the bounded conversion is what makes that "0" true; the plain
/// `std.unicode.utf16LeToUtf8` this used to call panics on a short
/// destination instead of erroring, and `MAX_VALUE_LEN` units can need three
/// times `MAX_VALUE_LEN` bytes.
fn readText(h: w32.HWND, buf: []u8) usize {
    var wbuf: [host_defaults.MAX_VALUE_LEN + 1]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(h, &wbuf, wbuf.len));
    return utf16_text.toUtf8AllOrNothing(buf, wbuf[0..wlen]);
}

// ---------------------------------------------------------------------
// Modal loop + key routing
// ---------------------------------------------------------------------

/// Nested modal pump — the ConfirmDialog shape: WM_APP_SETFOCUS (T48 deferred
/// focus) is performed here rather than dispatched; everything else flows
/// through Translate/Dispatch so the renderer and IPC stay live.
fn runModal(self: *HostSettingsDialog) void {
    var msg: w32.MSG = undefined;
    while (!self.done) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) {
            // WM_QUIT: repost for the outer loop and save nothing.
            w32.PostQuitMessage(@intCast(msg.wParam));
            self.saved = false;
            return;
        }
        if (result < 0) {
            self.saved = false;
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

fn ownsHwnd(self: *const HostSettingsDialog, hwnd: w32.HWND) bool {
    if (hwnd == self.hwnd or hwnd == self.wd_edit or hwnd == self.shell_combo) return true;
    if (hwnd == self.save_btn or hwnd == self.cancel_btn) return true;
    // The focus inside an editable combo is on its child EDIT.
    if (w32.GetParent(hwnd)) |p| if (p == self.shell_combo) return true;
    return false;
}

/// True while the shell combo's drop-down list is open. Enter and Escape then
/// belong to the LIST (commit/dismiss the selection), not to the dialog —
/// otherwise picking a preset with the keyboard would also close the dialog.
fn comboDropped(self: *const HostSettingsDialog) bool {
    return w32.SendMessageW(self.shell_combo, w32.CB_GETDROPPEDSTATE, 0, 0) != 0;
}

/// Tab stops in order: working directory → shell → Save → Cancel. Pure — the
/// cycle is `nextFocusIndex`, shared with ConfirmDialog's rule.
pub fn nextFocusIndex(cur: usize, stops: usize, backwards: bool) usize {
    if (stops == 0) return 0;
    if (backwards) return (cur + stops - 1) % stops;
    return (cur + 1) % stops;
}

fn finish(self: *HostSettingsDialog, saved: bool) void {
    self.saved = saved;
    self.done = true;
}

/// Handle a dialog key out of the nested pump. Returns true when consumed.
fn handleKey(self: *HostSettingsDialog, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            if (self.comboDropped()) return false;
            self.finish(false);
            return true;
        },
        w32.VK_RETURN => {
            if (self.comboDropped()) return false;
            // Enter activates the focused button, else saves (a form's Enter
            // commits what was typed — Mac's alert default is Save).
            const focus = w32.GetFocus();
            if (focus == @as(?w32.HWND, self.cancel_btn)) {
                self.finish(false);
            } else {
                self.finish(true);
            }
            return true;
        },
        w32.VK_TAB => {
            const stops: [4]w32.HWND = .{ self.wd_edit, self.shell_combo, self.save_btn, self.cancel_btn };
            const focus = w32.GetFocus();
            var cur: usize = 0;
            for (stops, 0..) |h, i| {
                if (focus == @as(?w32.HWND, h)) cur = i;
            }
            // Focus inside an editable combo lands on its child EDIT, which
            // must still count as the combo's stop.
            if (focus) |f| if (w32.GetParent(f)) |p| {
                if (p == self.shell_combo) cur = 1;
            };
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
        log.warn("host settings dialog class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *HostSettingsDialog = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) switch (control_id) {
                IDOK => {
                    self.finish(true);
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
                if (!owned) _ = w32.SetFocus(self.wd_edit);
            }
            return 0;
        },
        // Fields (and the combo's inner edit / its drop-down list) are fields,
        // not dialog surface: without this they render as white boxes.
        w32.WM_CTLCOLOREDIT, w32.WM_CTLCOLORLISTBOX => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_FIELD_BG);
            if (field_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            // Labels are secondary text; the body paragraph reads as primary.
            const ctl: ?w32.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const is_label = (self.wd_label != null and ctl == self.wd_label) or
                (self.shell_label != null and ctl == self.shell_label);
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
    for ([_]f32{ 1.0, 1.5, 2.0 }) |scale| {
        const l = layoutFor(scale, 400, 60, 120, 88);
        try testing.expect(l.client_w > 0 and l.client_h > 0);
        for ([_]w32.RECT{
            l.body,   l.wd_label, l.wd_field, l.shell_label,
            l.shell_field, l.save, l.cancel,
        }) |r| {
            try testing.expect(r.left >= 0 and r.top >= 0);
            try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
            try testing.expect(r.right > r.left and r.bottom > r.top);
        }
    }
}

test "layoutFor: the two rows stack without overlapping, fields share a left edge" {
    const l = layoutFor(1.0, 400, 60, 120, 88);
    try testing.expect(l.body.bottom <= l.wd_field.top);
    try testing.expect(l.wd_field.bottom <= l.shell_field.top);
    try testing.expect(l.shell_field.bottom <= l.save.top);
    try testing.expectEqual(l.wd_field.left, l.shell_field.left);
    try testing.expectEqual(l.wd_field.right, l.shell_field.right);
    // Rows are the same height (the combo's closed band matches the EDIT).
    try testing.expectEqual(
        l.wd_field.bottom - l.wd_field.top,
        l.shell_field.bottom - l.shell_field.top,
    );
}

test "layoutFor: labels are a right-aligned column left of the fields" {
    const l = layoutFor(1.0, 400, 60, 120, 88);
    try testing.expectEqual(@as(i32, 16), l.wd_label.left);
    try testing.expectEqual(l.wd_label.left, l.shell_label.left);
    try testing.expectEqual(l.wd_label.right, l.shell_label.right);
    try testing.expect(l.wd_label.right < l.wd_field.left);
    // Each label sits within its row's band.
    try testing.expect(l.wd_label.top >= l.wd_field.top);
    try testing.expect(l.wd_label.bottom <= l.wd_field.bottom);
    try testing.expect(l.shell_label.top >= l.shell_field.top);
    try testing.expect(l.shell_label.bottom <= l.shell_field.bottom);
}

test "layoutFor: Save sits left of Cancel, both on the trailing margin" {
    const l = layoutFor(1.0, 400, 60, 120, 88);
    try testing.expect(l.save.right < l.cancel.left);
    try testing.expectEqual(l.save.top, l.cancel.top);
    try testing.expectEqual(l.cancel.right, l.client_w - 16);
    try testing.expectEqual(l.save.bottom, l.cancel.bottom);
}

test "layoutFor: the dialog is never narrower than its rows, buttons, or floor" {
    // A tiny body paragraph still leaves room for label + 240pt field.
    const narrow = layoutFor(1.0, 10, 20, 120, 88);
    try testing.expect(narrow.client_w >= 16 + 120 + 8 + 240 + 16);
    try testing.expect(narrow.client_w >= 420);
    // A very wide label pushes the dialog out rather than squeezing the field.
    const wide_label = layoutFor(1.0, 10, 20, 400, 88);
    try testing.expect(wide_label.wd_field.right - wide_label.wd_field.left >= 240);
    // A wide body paragraph grows the dialog and the fields with it.
    const wide = layoutFor(1.0, 900, 40, 120, 88);
    try testing.expect(wide.client_w >= 900 + 32);
    try testing.expect(wide.wd_field.right - wide.wd_field.left > 240);
}

test "layoutFor: scaling is proportional, not clipped" {
    const a = layoutFor(1.0, 400, 60, 120, 88);
    const b = layoutFor(2.0, 800, 120, 240, 176);
    try testing.expectEqual(a.client_w * 2, b.client_w);
    try testing.expectEqual(a.client_h * 2, b.client_h);
}

test "buttonWidth: standard 88 DIP, widened for a long caption" {
    try testing.expectEqual(@as(i32, 88), buttonWidth(1.0, 40));
    try testing.expectEqual(@as(i32, 176), buttonWidth(2.0, 40));
    try testing.expectEqual(@as(i32, 224), buttonWidth(1.0, 200));
}

test "nextFocusIndex: wd -> shell -> Save -> Cancel -> wrap" {
    try testing.expectEqual(@as(usize, 1), nextFocusIndex(0, 4, false));
    try testing.expectEqual(@as(usize, 2), nextFocusIndex(1, 4, false));
    try testing.expectEqual(@as(usize, 3), nextFocusIndex(2, 4, false));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(3, 4, false));
    // Shift+Tab walks back and wraps the other way.
    try testing.expectEqual(@as(usize, 3), nextFocusIndex(0, 4, true));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(1, 4, true));
    try testing.expectEqual(@as(usize, 0), nextFocusIndex(0, 0, false));
}

test {
    testing.refAllDecls(@This());
}

test "layoutFor: the font comes from the ramp, and so does the drawn font (T313)" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.25), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        try testing.expectEqual(
            type_ramp.body(scale).height,
            layoutFor(scale, 400, 60, 120, 88).font_h,
        );
    }
    // T310 migrated this dialog's arithmetic and left its `CreateFontW` at the
    // retired 15, so the layout measured a 14 that nothing was drawn in. Both
    // read `type_ramp.body` now; this is the number a reviewer can check the
    // font call against.
    try testing.expectEqual(@as(i32, 14), layoutFor(1.0, 400, 60, 120, 88).font_h);
}
