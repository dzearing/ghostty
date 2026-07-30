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
//!
//! Account (T141): the dialog's top row is the signed-in Google account —
//! email plus a Sign In / Sign Out button — mirroring the Mac chooser's
//! `accountRow`. This is the ONLY place a relay sign-in is initiated; the
//! `+relay-login` / `+relay-logout` CLI verbs that used to do it were deleted
//! because the Mac client never had them. The async half lives in
//! `RelayAccountRow.zig`; signing in re-fetches the device list in place.

const MachineChooser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Window = @import("Window.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const RelayAccountRow = @import("RelayAccountRow.zig");
const chooser_rows = @import("chooser_rows.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyMachineChooser");
const FILTER_ID: u16 = 100;
const LIST_ID: u16 = 101;
const ACCOUNT_ID: u16 = 102;

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

/// The row background the owner-drawn selection/hover fills composite against
/// (the list's own field background, not the dialog's).
const ROW_BG: chooser_rows.Rgb = .{ .r = 30, .g = 30, .b = 30 };

fn rgb(c: chooser_rows.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

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
account_status: w32.HWND,
account_btn: w32.HWND,
font: ?*anyopaque = null,
/// Smaller font for the dimmed row subline (Mac's `.caption`).
subtitle_font: ?*anyopaque = null,

/// The listbox's original window procedure, saved when it is subclassed for
/// hover tracking. Restored is unnecessary — the control dies with the dialog.
list_proc: ?*const anyopaque = null,
/// Row under the pointer, or -1. Drives the hover wash (Mac's `hoveredIndex`).
hover_row: i32 = -1,
/// Whether the listbox currently has a `TrackMouseEvent` leave request in
/// flight, so one is armed per entry instead of per mouse-move.
tracking_leave: bool = false,
/// Wrapped line count the footer hint is currently laid out for. The dialog
/// re-lays-out (and resizes) when a new hint needs a different number.
hint_lines: i32 = 1,

/// Backs `relay_base`, `token` and `email` for the dialog's lifetime (used by
/// the dial on selection). Freed in `close`.
arena: std.heap.ArenaAllocator,
relay_base: []const u8 = "",
token: ?[]const u8 = null,

/// The signed-in account's email, or null when signed out. Read from the
/// account store on open and after every sign-in/sign-out (T141).
email: ?[]const u8 = null,

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
    account_status: w32.RECT,
    account_btn: w32.RECT,
    filter: w32.RECT,
    list: w32.RECT,
    hint: w32.RECT,
    open: w32.RECT,
    cancel: w32.RECT,
    font_h: i32,
    /// Height of one wrapped line of footer-hint text. The hint control is
    /// `hint_lines` of these tall.
    hint_line_h: i32,
};

/// `hint_lines` is how many wrapped lines the footer hint needs (measured at
/// runtime with `DT_CALCRECT`, clamped by `chooser_rows.clampHintLines`). The
/// dialog GROWS to fit it — the T140 screenshot showed the hint clipped
/// mid-sentence because this used to be a fixed one-line slot.
pub fn layout(scale: f32, hint_lines: i32) Layout {
    const margin = px(16, scale);
    const filter_h = px(26, scale);
    const gap = px(10, scale);
    // Exactly five owner-drawn rows, so the list never shows a half row.
    const list_h = chooser_rows.rowMetrics(scale).height * 5 + px(4, scale);
    const hint_line_h = px(16, scale);
    const hint_h = hint_line_h * chooser_rows.clampHintLines(hint_lines);
    const btn_gap_v = px(12, scale);
    const btn_w = px(96, scale);
    const btn_h = px(28, scale);
    const btn_gap_h = px(8, scale);
    // The account row (T141): status text on the left, the Sign In / Sign Out
    // button right-aligned. Wide enough for "Sign in with Google…".
    const account_h = px(26, scale);
    const account_btn_w = px(150, scale);

    const client_w = px(440, scale);

    const account_top = margin;
    const filter_top = account_top + account_h + gap;
    const list_top = filter_top + filter_h + gap;
    const hint_top = list_top + list_h + gap;
    const btn_top = hint_top + hint_h + btn_gap_v;
    const client_h = btn_top + btn_h + margin;

    const cancel_left = client_w - margin - btn_w;
    const open_left = cancel_left - btn_gap_h - btn_w;
    const account_btn_left = client_w - margin - account_btn_w;

    return .{
        .client_w = client_w,
        .client_h = client_h,
        // The status STATIC is vertically centered against the taller button so
        // its single line of text sits on the button's baseline band.
        .account_status = .{
            .left = margin,
            .top = account_top + @divTrunc(account_h - hint_h, 2),
            .right = account_btn_left - btn_gap_h,
            .bottom = account_top + @divTrunc(account_h - hint_h, 2) + hint_h,
        },
        .account_btn = .{ .left = account_btn_left, .top = account_top, .right = account_btn_left + account_btn_w, .bottom = account_top + account_h },
        .filter = .{ .left = margin, .top = filter_top, .right = client_w - margin, .bottom = filter_top + filter_h },
        .list = .{ .left = margin, .top = list_top, .right = client_w - margin, .bottom = list_top + list_h },
        .hint = .{ .left = margin, .top = hint_top, .right = client_w - margin, .bottom = hint_top + hint_h },
        .open = .{ .left = open_left, .top = btn_top, .right = open_left + btn_w, .bottom = btn_top + btn_h },
        .cancel = .{ .left = cancel_left, .top = btn_top, .right = cancel_left + btn_w, .bottom = btn_top + btn_h },
        .font_h = px(15, scale),
        .hint_line_h = hint_line_h,
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
        .account_status = undefined,
        .account_btn = undefined,
        .arena = std.heap.ArenaAllocator.init(alloc),
    };

    // Resolve the relay base + bearer token and fetch the device list once.
    // Any failure degrades to a Local-only list plus a footer hint.
    const arena = self.arena.allocator();
    self.relay_base = relay_directory.resolveBase(arena) catch relay_directory.default_base;
    self.token = IpcHandlers.resolveToken(arena);
    self.email = relay_signin.signedInEmail(arena);
    const hint_text = self.fetchDevices(alloc);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    // Built at one hint line; `applyLayout` re-sizes once the real hint text
    // has been measured (see the end of this function).
    const l = layout(window.scale, 1);

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

    // Account row (T141): status text + the Sign In / Sign Out button.
    self.account_status = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.account_status.left,
        l.account_status.top,
        l.account_status.right - l.account_status.left,
        l.account_status.bottom - l.account_status.top,
        hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    self.account_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        l.account_btn.left,
        l.account_btn.top,
        l.account_btn.right - l.account_btn.left,
        l.account_btn.bottom - l.account_btn.top,
        hwnd,
        @ptrFromInt(@as(usize, ACCOUNT_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.account_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

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
    // The empty edit read as an unlabeled mystery box in the T140 screenshot.
    _ = w32.SendMessageW(
        self.filter,
        w32.EM_SETCUEBANNER,
        1, // keep the cue visible while focused, until the user types
        @bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral("Filter machines…"))),
    );

    // Owner-drawn rows (T172): no LBS_HASSTRINGS, so LB_ADDSTRING's lParam is
    // stored as the item's data and WM_DRAWITEM paints each row itself.
    self.list = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_BORDER | w32.WS_VSCROLL |
            w32.LBS_NOTIFY | w32.LBS_OWNERDRAWFIXED,
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
    // Authoritative row height for the owner-drawn list. Set explicitly rather
    // than answered from WM_MEASUREITEM, which the listbox sends DURING
    // CreateWindowExW — before `self` is reachable from the dialog's userdata.
    _ = w32.SendMessageW(
        self.list,
        w32.LB_SETITEMHEIGHT,
        0,
        chooser_rows.rowMetrics(window.scale).height,
    );
    // Hover feedback (Mac's `onHover` row wash) needs the listbox's own mouse
    // messages, which never reach the parent — so subclass it.
    self.list_proc = @ptrFromInt(@as(usize, @bitCast(w32.SetWindowLongPtrW(
        self.list,
        w32.GWLP_WNDPROC,
        @bitCast(@intFromPtr(&listWndProc)),
    ))));
    _ = w32.SetWindowLongPtrW(self.list, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

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
        for ([_]w32.HWND{
            self.filter,         self.list,       self.hint,
            self.account_status, self.account_btn, self.open_btn,
            self.cancel_btn,
        }) |c| {
            _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
    // The row subline is a notch smaller, like Mac's `.caption`. Owner-drawn
    // rows select it into the DC themselves, so it is never sent WM_SETFONT.
    self.subtitle_font = w32.CreateFontW(
        -chooser_rows.rowMetrics(window.scale).subtitle_font_h,
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

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.setHint(hint_text);
    self.refreshAccountRow();
    self.refilter("");

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
        return "Not signed in — use Sign in with Google above to list your machines.";

    const parsed = relay_directory.listDevices(list_alloc, self.relay_base, tok) catch |err| {
        log.warn("machine chooser: device list failed err={}", .{err});
        return switch (err) {
            error.Unauthorized => "Session expired — sign in again above.",
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
    self.hover_row = -1;

    _ = w32.SendMessageW(self.list, w32.LB_RESETCONTENT, 0, 0);
    // Owner-drawn and LBS_HASSTRINGS-less: the lParam is item DATA, not a
    // string pointer. The row's own index is all WM_DRAWITEM needs to look the
    // row back up in `self.rows`.
    for (0..self.row_count) |i| {
        _ = w32.SendMessageW(self.list, w32.LB_ADDSTRING, 0, @intCast(i));
    }
    if (self.row_count > 0) _ = w32.SendMessageW(self.list, w32.LB_SETCURSEL, 0, 0);
}

/// What a row renders: title, dimmed subline, status shape and glyph. Pure
/// derivation lives in `chooser_rows`; this just resolves the device.
fn rowText(self: *const MachineChooser, row: Row) chooser_rows.RowText {
    return switch (row) {
        .local => chooser_rows.localRow(),
        .device => |i| chooser_rows.deviceRow(
            self.devices[i].name,
            self.devices[i].hostname,
            self.devices[i].online,
        ),
    };
}

/// Relabel the account row from the current state: the email (or "Not signed
/// in") on the left, "Sign Out" / "Sign in with Google…" on the button, and the
/// button disabled while an operation is in flight (T141).
fn refreshAccountRow(self: *MachineChooser) void {
    const busy = RelayAccountRow.isRunning();
    setText(self.account_status, RelayAccountRow.statusText(self.email, busy));
    setText(self.account_btn, RelayAccountRow.buttonLabel(self.email != null, busy));

    // Hand focus off BEFORE disabling the button. Disabling the focused control
    // makes Windows drop the thread's keyboard focus entirely, and with no
    // focus window WM_KEYDOWN arrives with `msg.hwnd == null` — which the app's
    // message loop cannot attribute to this dialog, so Enter/Escape/Tab go
    // dead for as long as the sign-in runs (measured, not theorized:
    // `relay-account.ps1` asserts focus stays inside the chooser while busy,
    // and it failed before this line existed).
    if (busy and w32.GetFocus() == @as(?w32.HWND, self.account_btn)) {
        _ = w32.SetFocus(self.filter);
    }
    _ = w32.EnableWindow(self.account_btn, if (busy) 0 else 1);
}

/// The account button was clicked: sign out when signed in, else sign in. Both
/// run off-thread (`RelayAccountRow`); the row goes to its pending state
/// immediately so the click is visibly acknowledged.
fn onAccountClicked(self: *MachineChooser) void {
    const started = if (self.email != null)
        RelayAccountRow.signOutAsync(self.window.app)
    else
        RelayAccountRow.signInAsync(self.window.app);
    if (!started) return;
    self.refreshAccountRow();
    if (self.email == null) self.setHint("Complete the sign-in in your browser…");
}

/// GUI thread: a sign-in/sign-out finished. Re-read the account, relabel the
/// row, and (on a successful sign-in) re-fetch the device list in place so the
/// user's machines appear without reopening the chooser.
pub fn onAccountResult(self: *MachineChooser, res: *const RelayAccountRow.Result) void {
    const arena = self.arena.allocator();
    self.email = relay_signin.signedInEmail(arena);

    if (res.ok) {
        self.token = IpcHandlers.resolveToken(arena);
        self.reloadDevices();
    }
    self.refreshAccountRow();
    if (res.message.len > 0) self.setHint(res.message);
}

/// Drop the current device list and fetch it again with the current token.
fn reloadDevices(self: *MachineChooser) void {
    const alloc = self.window.app.core_app.alloc;
    if (self.parsed) |*p| {
        p.deinit();
        self.parsed = null;
    }
    self.devices = &.{};
    const hint_text = self.fetchDevices(alloc);
    self.setHint(hint_text);

    var buf: [256]u8 = undefined;
    self.refilter(self.filterText(&buf));
}

/// Set a control's text from UTF-8 (truncated to fit).
fn setText(hwnd: w32.HWND, text: []const u8) void {
    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch 0;
    wbuf[@min(wlen, wbuf.len - 1)] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&wbuf));
}

/// Set the footer hint text (empty hides it visually) and grow or shrink the
/// dialog so the sentence is never clipped. The T140 screenshot caught the old
/// fixed one-line slot cutting "…to list your" mid-sentence.
fn setHint(self: *MachineChooser, text: []const u8) void {
    setText(self.hint, text);

    const lines = chooser_rows.clampHintLines(self.measureHintLines(text));
    if (lines != self.hint_lines) {
        self.hint_lines = lines;
        self.applyLayout();
    }
}

/// How many wrapped lines `text` needs at the current hint width, measured with
/// the dialog's own font via `DT_CALCRECT | DT_WORDBREAK` — the same wrapping
/// the STATIC will do, so the reserved height always matches what is drawn.
fn measureHintLines(self: *const MachineChooser, text: []const u8) i32 {
    if (text.len == 0) return 1;
    const l = layout(self.window.scale, self.hint_lines);
    const width = l.hint.right - l.hint.left;
    if (width <= 0) return 1;

    const hdc = w32.GetDC(self.hint) orelse return 1;
    defer _ = w32.ReleaseDC(self.hint, hdc);
    const prev = if (self.font) |f| w32.SelectObject(hdc, f) else null;
    defer if (prev) |p| {
        _ = w32.SelectObject(hdc, p);
    };

    var wbuf: [512]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 1;
    var r: w32.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = 0 };
    _ = w32.DrawTextW(
        hdc,
        &wbuf,
        @intCast(wlen),
        &r,
        w32.DT_LEFT | w32.DT_WORDBREAK | w32.DT_CALCRECT | w32.DT_NOPREFIX,
    );
    const h = r.bottom - r.top;
    if (h <= 0 or l.hint_line_h <= 0) return 1;
    return @divTrunc(h + l.hint_line_h - 1, l.hint_line_h);
}

/// Re-place every control for the current `hint_lines` and resize the dialog
/// around them, keeping it centered where it already is.
fn applyLayout(self: *MachineChooser) void {
    const l = layout(self.window.scale, self.hint_lines);

    const style: u32 = w32.WS_POPUP | w32.WS_CAPTION | w32.WS_SYSMENU;
    const ex_style: u32 = w32.WS_EX_DLGMODALFRAME;
    var frame: w32.RECT = .{ .left = 0, .top = 0, .right = l.client_w, .bottom = l.client_h };
    _ = w32.AdjustWindowRectEx(&frame, style, 0, ex_style);
    const outer_w = frame.right - frame.left;
    const outer_h = frame.bottom - frame.top;

    var cur: w32.RECT = undefined;
    if (w32.GetWindowRect(self.hwnd, &cur) != 0) {
        const cx = cur.left + @divTrunc(cur.right - cur.left, 2);
        const cy = cur.top + @divTrunc(cur.bottom - cur.top, 2);
        _ = w32.SetWindowPos(
            self.hwnd,
            null,
            cx - @divTrunc(outer_w, 2),
            cy - @divTrunc(outer_h, 2),
            outer_w,
            outer_h,
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
        );
    }

    const placements = [_]struct { hwnd: w32.HWND, r: w32.RECT }{
        .{ .hwnd = self.account_status, .r = l.account_status },
        .{ .hwnd = self.account_btn, .r = l.account_btn },
        .{ .hwnd = self.filter, .r = l.filter },
        .{ .hwnd = self.list, .r = l.list },
        .{ .hwnd = self.hint, .r = l.hint },
        .{ .hwnd = self.open_btn, .r = l.open },
        .{ .hwnd = self.cancel_btn, .r = l.cancel },
    };
    for (placements) |p| {
        _ = w32.MoveWindow(
            p.hwnd,
            p.r.left,
            p.r.top,
            p.r.right - p.r.left,
            p.r.bottom - p.r.top,
            1,
        );
    }
}

// ---------------------------------------------------------------------
// Owner-drawn rows (T172)
// ---------------------------------------------------------------------

/// Paint one list row: a rounded selection/hover pill, the shape-coded status
/// dot, the machine glyph, the name, and the dimmed subline. Ported from Mac's
/// `MachineChooserView.row(for:)` / `statusIndicator(for:)`.
fn drawRow(self: *MachineChooser, dis: *const w32.DRAWITEMSTRUCT) void {
    const hdc = dis.hDC;
    const r = dis.rcItem;
    const idx: i32 = @bitCast(dis.itemID);
    // A listbox with no items still asks for one empty row (itemID == -1).
    if (idx < 0 or @as(usize, @intCast(idx)) >= self.row_count) {
        if (field_brush) |b| _ = w32.FillRect(hdc, &dis.rcItem, b);
        return;
    }

    const m = chooser_rows.rowMetrics(self.window.scale);
    const selected = (dis.itemState & w32.ODS_SELECTED) != 0;
    const hovered = self.hover_row == idx;

    // Background first: the row's own field color, so the pill composites
    // against what is actually behind it.
    if (field_brush) |b| _ = w32.FillRect(hdc, &dis.rcItem, b);

    if (selected or hovered) {
        const fill = if (selected)
            chooser_rows.selectionFill(ROW_BG)
        else
            chooser_rows.hoverFill(ROW_BG);
        const brush = w32.CreateSolidBrush(rgb(fill));
        const pen = if (selected)
            w32.CreatePen(w32.PS_SOLID, 1, rgb(chooser_rows.selectionBorder(ROW_BG)))
        else
            w32.CreatePen(w32.PS_SOLID, 1, rgb(fill));
        if (brush != null and pen != null) {
            const old_brush = w32.SelectObject(hdc, brush);
            const old_pen = w32.SelectObject(hdc, pen);
            _ = w32.RoundRect(
                hdc,
                r.left + m.fill_inset_x,
                r.top + m.fill_inset_y,
                r.right - m.fill_inset_x,
                r.bottom - m.fill_inset_y,
                m.fill_radius * 2,
                m.fill_radius * 2,
            );
            _ = w32.SelectObject(hdc, old_brush);
            _ = w32.SelectObject(hdc, old_pen);
        }
        if (brush) |b| _ = w32.DeleteObject(b);
        if (pen) |p| _ = w32.DeleteObject(p);
    }

    const text = self.rowText(self.rows[@intCast(idx)]);
    drawStatusDot(hdc, r, m, text.status);
    drawGlyph(hdc, r, m, text.glyph);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    const text_right = r.right - m.text_pad_right;

    var title_rect: w32.RECT = .{
        .left = r.left + m.text_x,
        .top = r.top + m.title_y,
        .right = text_right,
        .bottom = r.top + m.title_y + m.title_h,
    };
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    drawTextUtf8(hdc, text.title, &title_rect);

    if (text.subtitle.len > 0) {
        var sub_rect: w32.RECT = .{
            .left = r.left + m.text_x,
            .top = r.top + m.subtitle_y,
            .right = text_right,
            .bottom = r.top + m.subtitle_y + m.subtitle_h,
        };
        const old = if (self.subtitle_font) |f| w32.SelectObject(hdc, f) else null;
        _ = w32.SetTextColor(hdc, rgb(chooser_rows.secondary_gray));
        drawTextUtf8(hdc, text.subtitle, &sub_rect);
        if (old) |o| _ = w32.SelectObject(hdc, o);
    }
}

/// One line of ellipsized, vertically centered UTF-8 text.
fn drawTextUtf8(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
    _ = w32.DrawTextW(
        hdc,
        &wbuf,
        @intCast(wlen),
        r,
        w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
    );
}

/// The leading status column: a filled green dot when online, a hollow gray
/// ring when offline, nothing for the Local row (which keeps the column so all
/// rows share one grid). Shape-coded, not just color-coded, like Mac's.
fn drawStatusDot(hdc: w32.HDC, r: w32.RECT, m: chooser_rows.RowMetrics, status: chooser_rows.Status) void {
    if (status == .none) return;
    const half = @divTrunc(m.dot_d, 2);
    const cx = r.left + m.status_cx;
    const cy = r.top + m.status_cy;

    const online = status == .online;
    const color = if (online) chooser_rows.online_green else chooser_rows.secondary_gray;
    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(color)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const brush: ?*anyopaque = if (online)
        w32.CreateSolidBrush(rgb(color))
    else
        w32.GetStockObject(w32.NULL_BRUSH);
    defer if (online) {
        if (brush) |b| _ = w32.DeleteObject(b);
    };

    const old_pen = w32.SelectObject(hdc, pen);
    const old_brush = w32.SelectObject(hdc, brush);
    _ = w32.Ellipse(hdc, cx - half, cy - half, cx + half, cy + half);
    _ = w32.SelectObject(hdc, old_pen);
    _ = w32.SelectObject(hdc, old_brush);
}

/// The machine glyph, drawn with GDI primitives rather than an icon font (no
/// tofu risk if Segoe's symbol font is missing): a laptop silhouette for the
/// local machine, a two-unit rack for a relay device.
fn drawGlyph(hdc: w32.HDC, r: w32.RECT, m: chooser_rows.RowMetrics, glyph: chooser_rows.Glyph) void {
    const x = r.left + m.glyph_x;
    const y = r.top + m.glyph_y;
    const w = m.glyph_w;
    const h = m.glyph_h;

    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(chooser_rows.secondary_gray)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const old_pen = w32.SelectObject(hdc, pen);
    const old_brush = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));
    defer {
        _ = w32.SelectObject(hdc, old_pen);
        _ = w32.SelectObject(hdc, old_brush);
    }

    switch (glyph) {
        .local => {
            // Screen over a full-width base line.
            const inset = @divTrunc(w, 8);
            _ = w32.Rectangle(hdc, x + inset, y, x + w - inset, y + h - @divTrunc(h, 4));
            _ = w32.MoveToEx(hdc, x, y + h - @divTrunc(h, 8), null);
            _ = w32.LineTo(hdc, x + w, y + h - @divTrunc(h, 8));
        },
        .server => {
            // Two stacked rack units, each with a drive indicator.
            const unit_h = @divTrunc(h - 2, 2);
            var i: i32 = 0;
            while (i < 2) : (i += 1) {
                const top = y + i * (unit_h + 2);
                _ = w32.Rectangle(hdc, x, top, x + w, top + unit_h);
                const dot = @divTrunc(unit_h, 3);
                const dy = top + @divTrunc(unit_h - dot, 2);
                _ = w32.MoveToEx(hdc, x + w - dot - 2, dy + @divTrunc(dot, 2), null);
                _ = w32.LineTo(hdc, x + w - 2, dy + @divTrunc(dot, 2));
            }
        },
    }
}

/// Subclassed listbox proc: adds pointer hover feedback (the parent never sees
/// the listbox's own mouse messages). Everything else falls through untouched.
fn listWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *MachineChooser = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const prev = self.list_proc orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var tme: w32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.tracking_leave = true;
            }
            const hit = w32.SendMessageW(hwnd, w32.LB_ITEMFROMPOINT, 0, lparam);
            // High word non-zero ⇒ the point is outside the client area.
            const outside = (@as(usize, @bitCast(hit)) >> 16) & 0xFFFF != 0;
            const row: i32 = if (outside) -1 else @intCast(hit & 0xFFFF);
            self.setHover(if (row >= 0 and @as(usize, @intCast(row)) < self.row_count) row else -1);
        },
        w32.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            self.setHover(-1);
        },
        else => {},
    }
    return w32.CallWindowProcW(prev, hwnd, msg, wparam, lparam);
}

/// Move the hover highlight, repainting only when it actually changed.
fn setHover(self: *MachineChooser, row: i32) void {
    if (self.hover_row == row) return;
    self.hover_row = row;
    _ = w32.InvalidateRect(self.list, null, 0);
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
                    ACCOUNT_ID => {
                        self.onAccountClicked();
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
        w32.WM_DRAWITEM => {
            const dis: *const w32.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (dis.CtlType == w32.ODT_LISTBOX and dis.CtlID == LIST_ID) {
                self.drawRow(dis);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MEASUREITEM => {
            const mis: *w32.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (mis.CtlType == w32.ODT_LISTBOX and mis.CtlID == LIST_ID) {
                mis.itemHeight = @intCast(chooser_rows.rowMetrics(self.window.scale).height);
                return 1;
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
        hwnd == self.hint or hwnd == self.open_btn or hwnd == self.cancel_btn or
        hwnd == self.account_status or hwnd == self.account_btn;
}

/// Keyboard focus targets, in Tab order. `account` is the sign-in/out button
/// (T141) — last in the cycle so Tab from the filter still reaches the list
/// first, the common path.
pub const Focusable = enum { filter, list, open, cancel, account };

/// Pure Tab-order cycle. Unit-tested.
pub fn nextFocus(cur: Focusable, backwards: bool) Focusable {
    return if (backwards) switch (cur) {
        .filter => .account,
        .list => .filter,
        .open => .list,
        .cancel => .open,
        .account => .cancel,
    } else switch (cur) {
        .filter => .list,
        .list => .open,
        .open => .cancel,
        .cancel => .account,
        .account => .filter,
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
            // Enter on the account button presses IT, not the default Open
            // button — this loop intercepts Enter before the control sees it.
            if (w32.GetFocus() == @as(?w32.HWND, self.account_btn)) {
                self.onAccountClicked();
            } else {
                self.openSelection();
            }
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
            else if (focus == @as(?w32.HWND, self.account_btn))
                .account
            else
                .filter;
            const next_hwnd = switch (nextFocus(cur, backwards)) {
                .filter => self.filter,
                .list => self.list,
                .open => self.open_btn,
                .cancel => self.cancel_btn,
                .account => self.account_btn,
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
                self.setHint("Not signed in — use Sign in with Google above.");
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
    _ = w32.SetWindowLongPtrW(self.list, w32.GWLP_USERDATA, 0);
    _ = w32.DestroyWindow(self.hwnd);
    if (self.font) |f| {
        _ = w32.DeleteObject(f);
        self.font = null;
    }
    if (self.subtitle_font) |f| {
        _ = w32.DeleteObject(f);
        self.subtitle_font = null;
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

test "nextFocus: forward cycle filter -> list -> open -> cancel -> account -> filter" {
    try testing.expectEqual(Focusable.list, nextFocus(.filter, false));
    try testing.expectEqual(Focusable.open, nextFocus(.list, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.open, false));
    try testing.expectEqual(Focusable.account, nextFocus(.cancel, false));
    try testing.expectEqual(Focusable.filter, nextFocus(.account, false));
}

test "nextFocus: backward cycle reverses" {
    try testing.expectEqual(Focusable.account, nextFocus(.filter, true));
    try testing.expectEqual(Focusable.cancel, nextFocus(.account, true));
    try testing.expectEqual(Focusable.open, nextFocus(.cancel, true));
    try testing.expectEqual(Focusable.list, nextFocus(.open, true));
    try testing.expectEqual(Focusable.filter, nextFocus(.list, true));
}

test "nextFocus: every target is reachable both ways (no orphan in the cycle)" {
    inline for (.{ false, true }) |backwards| {
        var seen = [_]bool{false} ** @typeInfo(Focusable).@"enum".fields.len;
        var cur: Focusable = .filter;
        for (0..seen.len) |_| {
            seen[@intFromEnum(cur)] = true;
            cur = nextFocus(cur, backwards);
        }
        try testing.expectEqual(Focusable.filter, cur); // closed cycle
        for (seen) |s| try testing.expect(s);
    }
}

test "containsIgnoreCase: basic matches" {
    try testing.expect(containsIgnoreCase("Winbox", "box"));
    try testing.expect(containsIgnoreCase("Winbox", ""));
    try testing.expect(!containsIgnoreCase("Winbox", "mac"));
    try testing.expect(!containsIgnoreCase("ab", "abc")); // needle longer
}

test "layout: controls nest inside the client area, buttons right-aligned" {
    const l = layout(1.0, 1);
    try testing.expect(l.client_w > 0 and l.client_h > 0);
    for ([_]w32.RECT{ l.account_status, l.account_btn, l.filter, l.list, l.hint, l.open, l.cancel }) |r| {
        try testing.expect(r.left >= 0 and r.top >= 0);
        try testing.expect(r.right <= l.client_w and r.bottom <= l.client_h);
        try testing.expect(r.right > r.left and r.bottom > r.top);
    }
    try testing.expect(l.open.right < l.cancel.left);
    try testing.expect(l.list.bottom < l.hint.top);
}

test "layout: the account row sits above the filter and never overlaps it" {
    const l = layout(1.0, 1);
    // Status text left of the button, with a gap; both above the filter.
    try testing.expect(l.account_status.right <= l.account_btn.left);
    try testing.expect(l.account_status.right < l.account_btn.left);
    try testing.expect(l.account_btn.bottom <= l.filter.top);
    try testing.expect(l.account_status.bottom <= l.filter.top);
    // Right-aligned with the same margin as the dialog's other right edges.
    try testing.expectEqual(l.filter.right, l.account_btn.right);
    // Wide enough for "Sign in with Google…" at 1.0 scale.
    try testing.expect(l.account_btn.right - l.account_btn.left >= 140);
}

test "layout: scales with DPI" {
    const l1 = layout(1.0, 1);
    const l2 = layout(2.0, 1);
    try testing.expectEqual(l1.client_w * 2, l2.client_w);
    try testing.expectEqual(l1.list.top * 2, l2.list.top);
    try testing.expectEqual(l1.font_h * 2, l2.font_h);
    try testing.expectEqual(l1.account_btn.top * 2, l2.account_btn.top);
    try testing.expectEqual(
        (l1.account_btn.right - l1.account_btn.left) * 2,
        l2.account_btn.right - l2.account_btn.left,
    );
}

test "layout: a wrapping hint grows the dialog instead of clipping (T140)" {
    const one = layout(1.0, 1);
    const three = layout(1.0, 3);

    // The hint control gets exactly its measured lines...
    try testing.expectEqual(one.hint_line_h, one.hint.bottom - one.hint.top);
    try testing.expectEqual(one.hint_line_h * 3, three.hint.bottom - three.hint.top);
    // ...and the dialog is that much taller, so nothing is cut off.
    try testing.expectEqual(one.client_h + one.hint_line_h * 2, three.client_h);
    try testing.expectEqual(one.client_w, three.client_w);

    // Everything above the hint is unmoved; the buttons ride down with it.
    try testing.expectEqual(one.list.bottom, three.list.bottom);
    try testing.expect(three.open.top > one.open.top);
    for ([_]w32.RECT{ three.hint, three.open, three.cancel }) |r| {
        try testing.expect(r.bottom <= three.client_h);
    }
}

test "layout: a runaway hint is capped, not unbounded" {
    const capped = layout(1.0, chooser_rows.max_hint_lines);
    try testing.expectEqual(capped.client_h, layout(1.0, 99).client_h);
}

test "layout: the list shows whole rows only" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const l = layout(scale, 1);
        const row_h = chooser_rows.rowMetrics(scale).height;
        const list_h = l.list.bottom - l.list.top;
        // Five full rows fit, and the leftover is less than one more row (so
        // the list never renders a clipped half row at its foot).
        try testing.expect(list_h >= row_h * 5);
        try testing.expect(list_h < row_h * 6);
    }
}
