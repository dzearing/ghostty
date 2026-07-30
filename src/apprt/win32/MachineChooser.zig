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
//! Shape (T175): a master-detail chooser, ported from Mac's 840x540
//! `MachineChooserView` — account row across the top, a fixed-width machine
//! column on a faint wash at the left, a detail pane at the right carrying the
//! selected machine's identity and its primary action, and a footer holding
//! Cancel alone. The geometry is pure and lives in `chooser_layout.zig`; the
//! wash, the rules and the detail header are painted in `WM_PAINT` rather than
//! built from STATICs, so they can use the same GDI glyph routine the list rows
//! do.
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
const chooser_layout = @import("chooser_layout.zig");
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

/// The dialog background as the pure color model sees it, and the master
/// column's wash derived from it. The listbox is painted with the wash (not the
/// field color) so the filter, the rows and the status strip read as one
/// column — the way Mac's `machineListColumn` does.
const DIALOG_BG: chooser_rows.Rgb = .{ .r = 32, .g = 32, .b = 32 };
const WASH: chooser_rows.Rgb = chooser_rows.columnWash(DIALOG_BG);

/// The row background the owner-drawn selection/hover fills composite against:
/// the column wash the rows actually sit on.
const ROW_BG: chooser_rows.Rgb = WASH;

fn rgb(c: chooser_rows.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

var class_registered: bool = false;
var bg_brush: ?w32.HBRUSH = null;
var field_brush: ?w32.HBRUSH = null;
/// The master column's wash and the hairline rules (T175). Process-lifetime,
/// like the other two — created once with the window class.
var wash_brush: ?w32.HBRUSH = null;
var divider_brush: ?w32.HBRUSH = null;

window: *Window,
hwnd: w32.HWND,
filter: w32.HWND,
list: w32.HWND,
hint: w32.HWND,
/// The detail pane's primary action ("New Window"), Mac's `.borderedProminent`
/// button — in the detail header, NOT the footer (which holds Cancel alone).
primary_btn: w32.HWND,
cancel_btn: w32.HWND,
account_status: w32.HWND,
account_btn: w32.HWND,
font: ?*anyopaque = null,
/// Smaller font for the dimmed row subline (Mac's `.caption`).
subtitle_font: ?*anyopaque = null,
/// Semibold display font for the detail pane's machine name (Mac's `.title3`).
title_font: ?*anyopaque = null,

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

/// Dialog layout in physical pixels from the owner DPI scale. Pure — the math
/// and its tests live in `chooser_layout.zig`.
const Layout = chooser_layout.Layout;
const layout = chooser_layout.layout;

/// `chooser_layout.Rect` as the `RECT` the placement APIs want.
fn rect(r: chooser_layout.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
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
        .primary_btn = undefined,
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
    // Built at one status-strip line; `applyLayout` re-places the column once
    // the real strip text has been measured (see the end of this function).
    // The dialog itself is a fixed size — only the list flexes.
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
        // No border: the list is not a field sitting on the dialog, it IS the
        // master column — the wash behind it is the panel (T175).
        //
        // LBS_NOINTEGRALHEIGHT because `chooser_layout` already snaps the list
        // to whole rows. Left to itself the listbox snaps at CREATION using the
        // default item height (LB_SETITEMHEIGHT lands afterwards), which shaved
        // a whole row off and then pinned the height there — so the column
        // stopped flexing when the status strip wrapped.
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_VSCROLL |
            w32.LBS_NOTIFY | w32.LBS_OWNERDRAWFIXED | w32.LBS_NOINTEGRALHEIGHT,
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

    // Mac's primary action is labeled for what it does — "New Window" — and it
    // lives in the detail header beside the machine it acts on, not in the
    // footer (MachineChooserView.swift:456-466, 1410-1418).
    self.primary_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("New Window"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_DEFPUSHBUTTON,
        l.primary_btn.left,
        l.primary_btn.top,
        l.primary_btn.right - l.primary_btn.left,
        l.primary_btn.bottom - l.primary_btn.top,
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
    _ = w32.SetWindowTheme(self.primary_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
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
            self.filter,         self.list,        self.hint,
            self.account_status, self.account_btn, self.primary_btn,
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
    // The detail pane's machine name is Mac's `.title3` + `.semibold`: bigger
    // than the dialog font and heavier, so the pane has an obvious subject.
    self.title_font = w32.CreateFontW(
        -l.title_font_h,
        0,
        0,
        0,
        600,
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
    self.refreshDetail();
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

/// Set the master column's status-strip text (empty hides it visually) and
/// re-lay-out so the sentence is never clipped. The T140 screenshot caught the
/// old fixed one-line slot cutting "…to list your" mid-sentence; since T175 the
/// dialog is a fixed 840x540, so the extra lines come out of the LIST's height
/// rather than the window's.
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

/// Re-place every control for the current `hint_lines`. The dialog does NOT
/// resize (it is Mac's fixed 840x540) — only the list gives up the height the
/// status strip took.
fn applyLayout(self: *MachineChooser) void {
    const l = layout(self.window.scale, self.hint_lines);

    const placements = [_]struct { hwnd: w32.HWND, r: w32.RECT }{
        .{ .hwnd = self.account_status, .r = rect(l.account_status) },
        .{ .hwnd = self.account_btn, .r = rect(l.account_btn) },
        .{ .hwnd = self.filter, .r = rect(l.filter) },
        .{ .hwnd = self.list, .r = rect(l.list) },
        .{ .hwnd = self.hint, .r = rect(l.hint) },
        .{ .hwnd = self.primary_btn, .r = rect(l.primary_btn) },
        .{ .hwnd = self.cancel_btn, .r = rect(l.cancel) },
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
// Chrome + detail pane (T175)
// ---------------------------------------------------------------------

/// Paint the dialog's own surface: the master column's wash, the three rules
/// that frame it, and the detail pane's header (glyph, machine name, subtitle).
/// The header is drawn rather than built from STATICs so it can reuse the same
/// GDI glyph routine the list rows use — one silhouette, two sizes.
fn paintChrome(self: *MachineChooser, hdc: w32.HDC) void {
    const l = layout(self.window.scale, self.hint_lines);

    if (wash_brush) |b| {
        var r = rect(l.master);
        _ = w32.FillRect(hdc, &r, b);
    }
    if (divider_brush) |b| {
        var rules = [_]w32.RECT{
            .{ .left = 0, .top = l.header_divider_y, .right = l.client_w, .bottom = l.header_divider_y + 1 },
            .{ .left = l.master_divider_x, .top = l.master.top, .right = l.master_divider_x + 1, .bottom = l.master.bottom },
            .{ .left = 0, .top = l.footer_divider_y, .right = l.client_w, .bottom = l.footer_divider_y + 1 },
        };
        for (&rules) |*r| _ = w32.FillRect(hdc, r, b);
    }

    self.paintDetail(hdc, l);
}

/// The detail pane's header: the selected machine's glyph, name and subtitle —
/// or Mac's centered "No machines" when the filter matched nothing.
fn paintDetail(self: *MachineChooser, hdc: w32.HDC, l: Layout) void {
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    const row = self.selectedRow() orelse {
        _ = w32.SetTextColor(hdc, rgb(chooser_rows.secondary_gray));
        var r = rect(l.detail);
        var wbuf: [32]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, "No machines") catch return;
        _ = w32.DrawTextW(
            hdc,
            &wbuf,
            @intCast(wlen),
            &r,
            w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
        );
        return;
    };

    var sub_buf: [256]u8 = undefined;
    const detail = switch (row) {
        .local => chooser_rows.localDetail(),
        .device => |i| chooser_rows.deviceDetail(
            &sub_buf,
            self.devices[i].name,
            self.devices[i].hostname,
            self.devices[i].online,
        ),
    };

    // The glyph keeps its 20:16 proportions inside the taller detail box.
    const box = l.detail_glyph;
    const gw = box.width();
    const gh = @divTrunc(gw * 4, 5);
    drawGlyphBox(hdc, box.left, box.top + @divTrunc(box.height() - gh, 2), gw, gh, detail.glyph);

    var title_rect = rect(l.detail_title);
    const old_font = if (self.title_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, COLOR_TEXT);
    drawTextUtf8(hdc, detail.title, &title_rect);
    if (old_font) |o| _ = w32.SelectObject(hdc, o);

    var sub_rect = rect(l.detail_subtitle);
    _ = w32.SetTextColor(hdc, rgb(chooser_rows.secondary_gray));
    drawTextUtf8(hdc, detail.subtitle, &sub_rect);
}

/// The highlighted row, or null when the list is empty.
fn selectedRow(self: *const MachineChooser) ?Row {
    const sel: i32 = @intCast(w32.SendMessageW(self.list, w32.LB_GETCURSEL, 0, 0));
    if (sel < 0 or @as(usize, @intCast(sel)) >= self.row_count) return null;
    return self.rows[@intCast(sel)];
}

/// Repaint the detail pane (the selection moved, or the list was refiltered)
/// and show or hide the primary action with it — there is nothing to open when
/// no row is selected.
fn refreshDetail(self: *MachineChooser) void {
    const l = layout(self.window.scale, self.hint_lines);
    var r = rect(l.detail);
    _ = w32.InvalidateRect(self.hwnd, &r, 1);
    _ = w32.ShowWindow(
        self.primary_btn,
        if (self.selectedRow() == null) w32.SW_HIDE else w32.SW_SHOW,
    );
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
        if (wash_brush) |b| _ = w32.FillRect(hdc, &dis.rcItem, b);
        return;
    }

    const m = chooser_rows.rowMetrics(self.window.scale);
    const selected = (dis.itemState & w32.ODS_SELECTED) != 0;
    const hovered = self.hover_row == idx;

    // Background first: the column wash the row sits on, so the pill
    // composites against what is actually behind it.
    if (wash_brush) |b| _ = w32.FillRect(hdc, &dis.rcItem, b);

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
    drawGlyphBox(hdc, r.left + m.glyph_x, r.top + m.glyph_y, m.glyph_w, m.glyph_h, glyph);
}

/// `drawGlyph` at an absolute box, so the detail pane can draw the same
/// silhouette at its own (larger) size.
fn drawGlyphBox(hdc: w32.HDC, x: i32, y: i32, w: i32, h: i32, glyph: chooser_rows.Glyph) void {
    // A bigger glyph needs a heavier stroke or it reads as a wireframe.
    const pen_w: i32 = if (w >= 24) 2 else 1;
    const pen = w32.CreatePen(w32.PS_SOLID, pen_w, rgb(chooser_rows.secondary_gray)) orelse return;
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
    wash_brush = w32.CreateSolidBrush(rgb(WASH));
    divider_brush = w32.CreateSolidBrush(rgb(chooser_rows.dividerColor(DIALOG_BG)));
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
            } else if (control_id == LIST_ID and notification == w32.LBN_SELCHANGE) {
                // The detail pane is the selection's mirror — it has to follow
                // a click as well as an arrow key.
                self.refreshDetail();
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
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            self.paintChrome(hdc);
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, COLOR_FIELD_BG);
            if (field_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The list sits ON the column wash, not on a field — its unfilled tail
        // below the last row has to be the same color as the rows themselves.
        w32.WM_CTLCOLORLISTBOX => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_TEXT);
            _ = w32.SetBkColor(hdc, rgb(WASH));
            if (wash_brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc, COLOR_LABEL);
            // The status strip lives inside the master column, so it takes the
            // wash; everything else sits on the dialog surface.
            const on_wash = @as(?w32.HWND, self.hint) == @as(?w32.HWND, @ptrFromInt(@as(usize, @bitCast(lparam))));
            _ = w32.SetBkColor(hdc, if (on_wash) rgb(WASH) else COLOR_BG);
            const brush = if (on_wash) wash_brush else bg_brush;
            if (brush) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
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
        hwnd == self.hint or hwnd == self.primary_btn or hwnd == self.cancel_btn or
        hwnd == self.account_status or hwnd == self.account_btn;
}

/// Keyboard focus targets, in Tab order. `account` is the sign-in/out button
/// (T141) — last in the cycle so Tab from the filter still reaches the list
/// first, the common path.
pub const Focusable = enum { filter, list, primary, cancel, account };

/// Pure Tab-order cycle. Unit-tested.
pub fn nextFocus(cur: Focusable, backwards: bool) Focusable {
    return if (backwards) switch (cur) {
        .filter => .account,
        .list => .filter,
        .primary => .list,
        .cancel => .primary,
        .account => .cancel,
    } else switch (cur) {
        .filter => .list,
        .list => .primary,
        .primary => .cancel,
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
            if (next >= 0) {
                _ = w32.SendMessageW(self.list, w32.LB_SETCURSEL, @intCast(next), 0);
                // LB_SETCURSEL does not notify, so the detail pane has to be
                // told by hand — otherwise arrowing moves the highlight and
                // leaves the pane describing the machine you left.
                self.refreshDetail();
            }
            return true;
        },
        w32.VK_TAB => {
            const backwards = w32.GetKeyState(@as(i32, w32.VK_SHIFT)) < 0;
            const focus = w32.GetFocus();
            const cur: Focusable = if (focus == @as(?w32.HWND, self.list))
                .list
            else if (focus == @as(?w32.HWND, self.primary_btn))
                .primary
            else if (focus == @as(?w32.HWND, self.cancel_btn))
                .cancel
            else if (focus == @as(?w32.HWND, self.account_btn))
                .account
            else
                .filter;
            const next_hwnd = switch (nextFocus(cur, backwards)) {
                .filter => self.filter,
                .list => self.list,
                .primary => self.primary_btn,
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
    if (self.title_font) |f| {
        _ = w32.DeleteObject(f);
        self.title_font = null;
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

test "nextFocus: forward cycle filter -> list -> primary -> cancel -> account -> filter" {
    try testing.expectEqual(Focusable.list, nextFocus(.filter, false));
    try testing.expectEqual(Focusable.primary, nextFocus(.list, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.primary, false));
    try testing.expectEqual(Focusable.account, nextFocus(.cancel, false));
    try testing.expectEqual(Focusable.filter, nextFocus(.account, false));
}

test "nextFocus: backward cycle reverses" {
    try testing.expectEqual(Focusable.account, nextFocus(.filter, true));
    try testing.expectEqual(Focusable.cancel, nextFocus(.account, true));
    try testing.expectEqual(Focusable.primary, nextFocus(.cancel, true));
    try testing.expectEqual(Focusable.list, nextFocus(.primary, true));
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

// The layout math itself is tested in `chooser_layout.zig` (it moved there
// with T175). What stays here is the one thing that couples the two modules:
// the list column has to hold whole rows of the height the row model asks for.
test "layout: the machine list holds whole rows at every scale" {
    inline for (.{ @as(f32, 1.0), @as(f32, 1.5), @as(f32, 2.0) }) |scale| {
        const row_h = chooser_rows.rowMetrics(scale).height;
        // Even with the status strip at its maximum, the column is deep enough
        // to be a real list rather than a peephole.
        const worst = layout(scale, chooser_rows.max_hint_lines);
        try testing.expect(worst.list.height() >= row_h * 5);
        // And a one-line strip leaves strictly more room than the worst case.
        const best = layout(scale, 1);
        try testing.expect(best.list.height() > worst.list.height());
    }
}
