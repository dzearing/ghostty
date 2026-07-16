//! Modal "New Remote Window" machine chooser for the win32 apprt (T22c).
//!
//! The GUI counterpart to `ghoztty +new-remote-window`: ctrl+shift+n opens
//! this picker (also reachable via the "New Remote Window" command-palette
//! entry), which lists the signed-in account's enrolled relay devices and,
//! on selection, dials that machine and opens a window on it — the same relay
//! dial + `createWindow` the `+new-remote-window` IPC verb performs (routed
//! through the shared `App.openRelayWindow`, so there is ONE relay-open path).
//!
//! Modeled on `RenameDialog.zig` (the T50 pattern-setter): a real owner-
//! centered modal popup (caption, dark chrome, native controls) whose owner
//! window is disabled while it is open, with the app message loop still
//! running so the renderer thread and the IPC server stay live. Enter/Escape/
//! Tab/Up/Down never reach the native controls — the main message loop routes
//! them here via `handleKey` (see `App.machineChooserOwning`), exactly like
//! the rename dialog.
//!
//! Data: the device list is fetched once when the chooser opens, via
//! `relay_directory.listDevices` (a synchronous authenticated GET on the GUI
//! thread, bounded like the dial). No credential, or a fetch error, degrades
//! to a "Local"-only list plus a footer hint — never a crash (T22a decision 1).
//! Live re-poll while open is a deliberate non-goal for this first cut.

const MachineChooser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Window = @import("Window.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyMachineChooser");
const FILTER_ID: u16 = 100;
const LIST_ID: u16 = 101;

/// Cap on rendered device rows (bounds the fixed-size `rows` array). The
/// account device list is tiny in practice; extra devices are dropped from
/// the view (logged) rather than growing state unboundedly.
pub const MAX_DEVICES = 128;

/// A selectable row: the local machine (always first when it matches the
/// filter) or an enrolled relay device (index into `devices`).
pub const Row = union(enum) {
    local,
    device: usize,
};

/// Dialog colors — the RenameDialog dark palette (matches the command palette
/// and tab bar chrome).
const COLOR_BG = w32.RGB(32, 32, 32);
const COLOR_FIELD_BG = w32.RGB(30, 30, 30);
const COLOR_TEXT = w32.RGB(230, 230, 230);
const COLOR_LABEL = w32.RGB(200, 200, 200);

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;

window: *Window,
hwnd: w32.HWND,
filter: w32.HWND,
list: w32.HWND,
hint: w32.HWND,
open_btn: w32.HWND,
cancel_btn: w32.HWND,
font: ?*anyopaque = null,

/// Backs `relay_base` and `token` for the dialog's lifetime (used by the dial
/// on selection). Freed in `close`.
arena: std.heap.ArenaAllocator,
relay_base: []const u8 = "",
token: ?[]const u8 = null,

/// The fetched device list. Owned by `parsed` (its own JSON arena); empty when
/// there is no credential or the fetch failed. Freed in `close`.
parsed: ?relay_directory.Parsed = null,
devices: []const relay_directory.Device = &.{},

/// Current filtered rows (display order) mapped 1:1 to the listbox items.
rows: [MAX_DEVICES + 1]Row = undefined,
row_count: usize = 0,

/// Dialog layout in physical pixels from the owner DPI scale. Pure — tested.
pub const Layout = struct {
    client_w: i32,
    client_h: i32,
    filter: w32.RECT,
    list: w32.RECT,
    hint: w32.RECT,
    open: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
};

pub fn layout(scale: f32) Layout {
    const margin = px(16, scale);
    const filter_h = px(26, scale);
    const gap = px(10, scale);
    const list_h = px(220, scale);
    const hint_h = px(16, scale);
    const btn_gap_v = px(12, scale);
    const btn_w = px(96, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);

    const client_w = px(420, scale);

    const filter_top = margin;
    const list_top = filter_top + filter_h + gap;
    const hint_top = list_top + list_h + gap;
    const btn_top = hint_top + hint_h + btn_gap_v;
    const client_h = btn_top + btn_h + margin;

    const cancel_left = client_w - margin - btn_w;
    const open_left = cancel_left - btn_gap_h - btn_w;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .filter = .{ .left = margin, .top = filter_top, .right = client_w - margin, .bottom = filter_top + filter_h },
        .list = .{ .left = margin, .top = list_top, .right = client_w - margin, .bottom = list_top + list_h },
        .hint = .{ .left = margin, .top = hint_top, .right = client_w - margin, .bottom = hint_top + hint_h },
        .open = .{ .left = open_left, .top = btn_top, .right = open_left + btn_w, .bottom = btn_top + btn_h },
        .cancel = .{ .left = cancel_left, .top = btn_top, .right = cancel_left + btn_w, .bottom = btn_top + btn_h },
        .font_h = px(15, scale),
    };
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

/// Case-insensitive ASCII substring test. Pure.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

/// True when a device row (name or hostname) matches the filter needle. Pure.
fn deviceMatches(dev: relay_directory.Device, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (containsIgnoreCase(dev.name, needle)) return true;
    if (dev.hostname) |h| return containsIgnoreCase(h, needle);
    return false;
}

/// Fill `out` with the rows matching `needle` in display order: the Local row
/// first (when "Local" matches the needle), then each matching device (capped
/// at `out.len`). Returns the row count. Pure — unit-tested.
pub fn filterRows(devices: []const relay_directory.Device, needle: []const u8, out: []Row) usize {
    var n: usize = 0;
    if (n < out.len and containsIgnoreCase("Local", needle)) {
        out[n] = .local;
        n += 1;
    }
    for (devices, 0..) |dev, i| {
        if (n >= out.len) break;
        if (deviceMatches(dev, needle)) {
            out[n] = .{ .device = i };
            n += 1;
        }
    }
    return n;
}

/// Open the chooser for the currently focused window. Idempotent: an already-
/// open chooser is focused instead of a second one being created.
pub fn open(window: *Window) void {
    if (window.machine_chooser) |existing| {
        _ = w32.SetForegroundWindow(existing.hwnd);
        _ = w32.SetFocus(existing.filter);
        return;
    }

    const owner = window.hwnd orelse return;

    // Mutual exclusion with the inline tab-rename edit (as RenameDialog does).
    window.cancelTabRename();

    registerClass(window.app) orelse return;

    const alloc = window.app.core_app.alloc;
    const self = alloc.create(MachineChooser) catch |err| {
        log.warn("machine chooser alloc failed err={}", .{err});
        return;
    };
    self.* = .{
        .window = window,
        .hwnd = undefined,
        .filter = undefined,
        .list = undefined,
        .hint = undefined,
        .open_btn = undefined,
        .cancel_btn = undefined,
        .arena = std.heap.ArenaAllocator.init(alloc),
    };

    // Resolve the relay base + bearer token and fetch the device list once.
    // Any failure degrades to a Local-only list plus a footer hint.
    const arena = self.arena.allocator();
    self.relay_base = relay_directory.resolveBase(arena) catch relay_directory.default_base;
    self.token = IpcHandlers.resolveToken(arena);
    const hint_text = self.fetchDevices(alloc);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    const l = layout(window.scale);

    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;
    var owner_rect: w32.RECT = undefined;
    if (w32.GetWindowRect(owner, &owner_rect) == 0) {
        self.destroyState();
        return;
    }
    const x = owner_rect.left + @divTrunc((owner_rect.right - owner_rect.left) - outer_w, 2);
    const y = owner_rect.top + @divTrunc((owner_rect.bottom - owner_rect.top) - outer_h, 2);

    const hwnd = w32.CreateWindowExW(
        ex_style,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("New Remote Window"),
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
        self.destroyState();
        return;
    };
    self.hwnd = hwnd;

    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    self.filter = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        l.filter.left,
        l.filter.top,
        l.filter.right - l.filter.left,
        l.filter.bottom - l.filter.top,
        hwnd,
        @ptrFromInt(@as(usize, FILTER_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.filter, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    self.list = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_BORDER | w32.WS_VSCROLL |
            w32.LBS_NOTIFY | w32.LBS_HASSTRINGS,
        l.list.left,
        l.list.top,
        l.list.right - l.list.left,
        l.list.bottom - l.list.top,
        hwnd,
        @ptrFromInt(@as(usize, LIST_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.list, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

    self.hint = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.hint.left,
        l.hint.top,
        l.hint.right - l.hint.left,
        l.hint.bottom - l.hint.top,
        hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };

    self.open_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Open"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_DEFPUSHBUTTON,
        l.open.left,
        l.open.top,
        l.open.right - l.open.left,
        l.open.bottom - l.open.top,
        hwnd,
        @ptrFromInt(@as(usize, w32.IDOK)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    self.cancel_btn = w32.CreateWindowExW(
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
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.open_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    _ = w32.SetWindowTheme(self.cancel_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

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
        for ([_]w32.HWND{ self.filter, self.list, self.hint, self.open_btn, self.cancel_btn }) |c| {
            _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }

    self.setHint(hint_text);
    self.refilter("");

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    window.machine_chooser = self;

    _ = w32.EnableWindow(owner, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.filter);
}

/// Fetch the device list into `self.parsed`/`self.devices`. Returns the footer
/// hint text describing the outcome (empty when devices were listed).
/// `list_alloc` backs the returned `Parsed` (freed in `close`).
fn fetchDevices(self: *MachineChooser, list_alloc: Allocator) []const u8 {
    const tok = self.token orelse
        return "Not signed in — run  ghoztty +relay-login  to list your machines.";

    const parsed = relay_directory.listDevices(list_alloc, self.relay_base, tok) catch |err| {
        log.warn("machine chooser: device list failed err={}", .{err});
        return switch (err) {
            error.Unauthorized => "Session expired — sign in again with  ghoztty +relay-login.",
            error.NotFound => "No device directory on this relay.",
            else => "Couldn't reach the relay — showing this machine only.",
        };
    };

    self.parsed = parsed;
    var devs = parsed.value.devices;
    if (devs.len > MAX_DEVICES) {
        log.warn("machine chooser: {d} devices, showing first {d}", .{ devs.len, MAX_DEVICES });
        devs = devs[0..MAX_DEVICES];
    }
    self.devices = devs;
    return if (devs.len == 0) "No enrolled machines for this account." else "";
}

/// Recompute the filtered rows for `needle` and repopulate the listbox,
/// selecting the first row.
fn refilter(self: *MachineChooser, needle: []const u8) void {
    self.row_count = filterRows(self.devices, needle, &self.rows);

    _ = w32.SendMessageW(self.list, w32.LB_RESETCONTENT, 0, 0);
    var buf: [256]u8 = undefined;
    var wbuf: [256]u16 = undefined;
    for (self.rows[0..self.row_count]) |row| {
        const label = self.rowLabel(row, &buf);
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, label) catch 0;
        wbuf[@min(wlen, wbuf.len - 1)] = 0;
        _ = w32.SendMessageW(self.list, w32.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&wbuf)));
    }
    if (self.row_count > 0) _ = w32.SendMessageW(self.list, w32.LB_SETCURSEL, 0, 0);
}

/// Render a row as a single listbox line into `buf`.
fn rowLabel(self: *const MachineChooser, row: Row, buf: []u8) []const u8 {
    return switch (row) {
        .local => "Local  ·  this machine",
        .device => |i| blk: {
            const dev = self.devices[i];
            const status = if (dev.online) "online" else "offline";
            if (dev.hostname) |h| {
                break :blk std.fmt.bufPrint(buf, "{s}  —  {s}  ·  {s}", .{ dev.name, h, status }) catch dev.name;
            }
            break :blk std.fmt.bufPrint(buf, "{s}  ·  {s}", .{ dev.name, status }) catch dev.name;
        },
    };
}

/// Set the footer hint text (empty hides it visually).
fn setHint(self: *MachineChooser, text: []const u8) void {
    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch 0;
    wbuf[@min(wlen, wbuf.len - 1)] = 0;
    _ = w32.SetWindowTextW(self.hint, @ptrCast(&wbuf));
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
        log.warn("machine chooser class registration failed", .{});
        return null;
    }
    class_registered = true;
}

fn dialogWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *MachineChooser = @ptrFromInt(@as(usize, @bitCast(userdata)));

    switch (msg) {
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (notification == w32.BN_CLICKED) {
                switch (control_id) {
                    w32.IDOK => {
                        self.openSelection();
                        return 0;
                    },
                    w32.IDCANCEL => {
                        self.cancel();
                        return 0;
                    },
                    else => {},
                }
            } else if (control_id == FILTER_ID and notification == w32.EN_CHANGE) {
                var buf: [256]u8 = undefined;
                self.refilter(self.filterText(&buf));
                return 0;
            } else if (control_id == LIST_ID and notification == w32.LBN_DBLCLK) {
                self.openSelection();
                return 0;
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
                if (!owned) _ = w32.SetFocus(self.filter);
            }
            return 0;
        },
        w32.WM_CTLCOLOREDIT, w32.WM_CTLCOLORLISTBOX => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_FIELD_BG);
            if (field_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
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

/// Read the current filter edit text into `buf` (truncated to fit).
fn filterText(self: *const MachineChooser, buf: []u8) []const u8 {
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(self.filter, &wbuf, wbuf.len));
    const n = std.unicode.utf16LeToUtf8(buf, wbuf[0..wlen]) catch return "";
    return buf[0..n];
}

/// True when `hwnd` is the dialog or one of its controls. The message loop
/// uses this to route keys to `handleKey` (and to keep the chooser's children
/// away from the Surface-cast popup-edit intercepts).
pub fn ownsHwnd(self: *const MachineChooser, hwnd: w32.HWND) bool {
    return hwnd == self.hwnd or hwnd == self.filter or hwnd == self.list or
        hwnd == self.hint or hwnd == self.open_btn or hwnd == self.cancel_btn;
}

/// Keyboard focus targets, in Tab order.
pub const Focusable = enum { filter, list, open, cancel };

/// Pure Tab-order cycle. Unit-tested.
pub fn nextFocus(cur: Focusable, backwards: bool) Focusable {
    return if (backwards) switch (cur) {
        .filter => .cancel,
        .list => .filter,
        .open => .list,
        .cancel => .open,
    } else switch (cur) {
        .filter => .list,
        .list => .open,
        .open => .cancel,
        .cancel => .filter,
    };
}

/// Move the listbox selection by `delta`, clamped to [0, row_count). Pure
/// index math — unit-tested via `clampSelection`.
pub fn clampSelection(cur: i32, delta: i32, count: usize) i32 {
    if (count == 0) return -1;
    const max: i32 = @intCast(count - 1);
    const next = cur + delta;
    if (next < 0) return 0;
    if (next > max) return max;
    return next;
}

/// Handle a dialog key from the main message loop. Returns true when consumed
/// (the message must not be translated/dispatched). Typing keys return false
/// so the filter EDIT receives them (its EN_CHANGE re-filters the list).
pub fn handleKey(self: *MachineChooser, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => {
            self.cancel();
            return true;
        },
        w32.VK_RETURN => {
            self.openSelection();
            return true;
        },
        w32.VK_UP, w32.VK_DOWN => {
            const cur: i32 = @intCast(w32.SendMessageW(self.list, w32.LB_GETCURSEL, 0, 0));
            const delta: i32 = if (vk == w32.VK_UP) -1 else 1;
            const next = clampSelection(cur, delta, self.row_count);
            if (next >= 0) _ = w32.SendMessageW(self.list, w32.LB_SETCURSEL, @intCast(next), 0);
            return true;
        },
        w32.VK_TAB => {
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const focus = w32.GetFocus();
            const cur: Focusable = if (focus == @as(?w32.HWND, self.list))
                .list
            else if (focus == @as(?w32.HWND, self.open_btn))
                .open
            else if (focus == @as(?w32.HWND, self.cancel_btn))
                .cancel
            else
                .filter;
            const next_hwnd = switch (nextFocus(cur, backwards)) {
                .filter => self.filter,
                .list => self.list,
                .open => self.open_btn,
                .cancel => self.cancel_btn,
            };
            _ = w32.SetFocus(next_hwnd);
            return true;
        },
        else => return false,
    }
}

/// Open the highlighted row: dial + open a remote window for a device, or a
/// plain local window for the Local row. A dial/open failure keeps the chooser
/// open with a footer hint so the user can retry or pick another machine.
fn openSelection(self: *MachineChooser) void {
    const sel: i32 = @intCast(w32.SendMessageW(self.list, w32.LB_GETCURSEL, 0, 0));
    if (sel < 0 or @as(usize, @intCast(sel)) >= self.row_count) return;
    const row = self.rows[@intCast(sel)];
    const app = self.window.app;

    switch (row) {
        .local => {
            // Close (refocusing the owner) first, then create — so the new
            // local window is the last to take the foreground.
            self.close(true);
            _ = app.createWindow(.{}) catch |err| {
                log.warn("machine chooser: open local window failed err={}", .{err});
            };
        },
        .device => |i| {
            const dev = self.devices[i];
            const tok = self.token orelse {
                self.setHint("Not signed in — run  ghoztty +relay-login.");
                return;
            };
            // Dial synchronously while the chooser is still alive (relay_base,
            // token and dev.id are borrowed from it); close only on success.
            _ = app.openRelayWindow(self.relay_base, dev.id, tok, .{}) catch |err| {
                log.warn("machine chooser: open relay window failed device={s} err={}", .{ dev.id, err });
                self.setHint(switch (err) {
                    error.DialFailed => "Couldn't reach that machine — is its agent running?",
                    else => "Couldn't open that machine.",
                });
                return;
            };
            // The new remote window already took the foreground — tear down
            // WITHOUT refocusing the owner, so it stays on top.
            self.close(false);
        },
    }
}

/// Dismiss without opening anything (returns focus to the owner window).
pub fn cancel(self: *MachineChooser) void {
    self.close(true);
}

/// Free state that was allocated before the HWND existed (early-return paths
/// in `open`). Does NOT touch `machine_chooser` or the owner (never set yet).
fn destroyState(self: *MachineChooser) void {
    if (self.parsed) |*p| p.deinit();
    self.arena.deinit();
    self.window.app.core_app.alloc.destroy(self);
}

/// Tear down: re-enable the owner, destroy the dialog, free. The owner MUST be
/// re-enabled before the dialog is destroyed, else Windows may activate another
/// application's window. `refocus_owner` returns the foreground/focus to the
/// owner window (cancel / local-open); it is skipped when a freshly opened
/// remote window has already taken the foreground and should keep it.
fn close(self: *MachineChooser, refocus_owner: bool) void {
    const window = self.window;
    window.machine_chooser = null;

    if (window.hwnd) |owner| _ = w32.EnableWindow(owner, 1);

    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }

    if (refocus_owner) {
        if (window.hwnd) |owner| _ = w32.SetForegroundWindow(owner);
        if (window.getActiveSurface()) |s| {
            if (s.hwnd) |h| App.deferSetFocus(h); // T48
        }
    }

    if (self.parsed) |*p| p.deinit();
    self.arena.deinit();
    window.app.core_app.alloc.destroy(self);
}

// ---------------------------------------------------------------------
// Tests (pure logic only — run in the win32 test lane)
// ---------------------------------------------------------------------

const testing = std.testing;

fn testDevice(name: []const u8, hostname: ?[]const u8, online: bool) relay_directory.Device {
    return .{ .id = name, .name = name, .hostname = hostname, .online = online };
}

test "filterRows: empty needle yields Local + all devices in order" {
    const devs = [_]relay_directory.Device{
        testDevice("Winbox", "winbox.local", true),
        testDevice("Laptop", null, false),
    };
    var out: [8]Row = undefined;
    const n = filterRows(&devs, "", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(Row.local, out[0]);
    try testing.expectEqual(@as(usize, 0), out[1].device);
    try testing.expectEqual(@as(usize, 1), out[2].device);
}

test "filterRows: needle matching a device drops Local and non-matches" {
    const devs = [_]relay_directory.Device{
        testDevice("Winbox", "winbox.local", true),
        testDevice("Laptop", "lap.home", false),
    };
    var out: [8]Row = undefined;
    const n = filterRows(&devs, "win", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 0), out[0].device);
}

test "filterRows: needle matches on hostname, case-insensitive" {
    const devs = [_]relay_directory.Device{
        testDevice("Alpha", "prod-server", true),
    };
    var out: [8]Row = undefined;
    const n = filterRows(&devs, "PROD", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 0), out[0].device);
}

test "filterRows: 'local' needle keeps Local, drops devices" {
    const devs = [_]relay_directory.Device{testDevice("Winbox", null, true)};
    var out: [8]Row = undefined;
    const n = filterRows(&devs, "loc", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(Row.local, out[0]);
}

test "filterRows: respects the output cap" {
    var devs: [4]relay_directory.Device = undefined;
    for (&devs, 0..) |*d, i| d.* = testDevice(switch (i) {
        0 => "a",
        1 => "b",
        2 => "c",
        else => "d",
    }, null, false);
    var out: [2]Row = undefined; // room for Local + 1 device
    const n = filterRows(&devs, "", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Row.local, out[0]);
    try testing.expectEqual(@as(usize, 0), out[1].device);
}

test "clampSelection: clamps within bounds and handles empty" {
    try testing.expectEqual(@as(i32, 0), clampSelection(0, -1, 3)); // no wrap above top
    try testing.expectEqual(@as(i32, 2), clampSelection(2, 1, 3)); // no wrap past bottom
    try testing.expectEqual(@as(i32, 1), clampSelection(0, 1, 3));
    try testing.expectEqual(@as(i32, -1), clampSelection(0, 1, 0)); // empty list
    try testing.expectEqual(@as(i32, 0), clampSelection(-1, 1, 3)); // from no-selection
}

test "nextFocus: forward cycle filter -> list -> open -> cancel -> filter" {
    try testing.expectEqual(Focusable.list, nextFocus(.filter, false));
    try testing.expectEqual(Focusable.open, nextFocus(.list, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.open, false));
    try testing.expectEqual(Focusable.filter, nextFocus(.cancel, false));
}

test "nextFocus: backward cycle reverses" {
    try testing.expectEqual(Focusable.cancel, nextFocus(.filter, true));
    try testing.expectEqual(Focusable.open, nextFocus(.cancel, true));
    try testing.expectEqual(Focusable.list, nextFocus(.open, true));
    try testing.expectEqual(Focusable.filter, nextFocus(.list, true));
}

test "containsIgnoreCase: basic matches" {
    try testing.expect(containsIgnoreCase("Winbox", "box"));
    try testing.expect(containsIgnoreCase("Winbox", ""));
    try testing.expect(!containsIgnoreCase("Winbox", "mac"));
    try testing.expect(!containsIgnoreCase("ab", "abc")); // needle longer
}

test "layout: controls nest inside the client area, buttons right-aligned" {
    const l = layout(1.0);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.filter, l.list, l.hint, l.open, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
        try testing.expect(r.right > r.left and r.bottom > r.top);
    }
    try testing.expect(l.open.right < l.cancel.left);
    try testing.expect(l.list.bottom < l.hint.top);
}

test "layout: scales with DPI" {
    const l1 = layout(1.0);
    const l2 = layout(2.0);
    try testing.expectEqual(l1.client_w * 2, l2.client_w);
    try testing.expectEqual(l1.list.top * 2, l2.list.top);
    try testing.expectEqual(l1.font_h * 2, l2.font_h);
}
