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
const ActivityMonitor = @import("ActivityMonitor.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const RelayAccountRow = @import("RelayAccountRow.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const HostSettingsDialog = @import("HostSettingsDialog.zig");
const host_defaults = @import("host_defaults.zig");
const chooser_rows = @import("chooser_rows.zig");
const chrome_theme = @import("chrome_theme.zig");
const panel_theme = @import("panel_theme.zig");
const brush_cache = @import("brush_cache.zig");
const color_math = @import("color_math.zig");
const type_ramp = @import("type_ramp.zig");
const system_colors = @import("system_colors.zig");
const chooser_layout = @import("chooser_layout.zig");
const chooser_menu = @import("chooser_menu.zig");
const chooser_sessions = @import("chooser_sessions.zig");
const text_search = @import("text_search.zig");
const SessionRoster = @import("SessionRoster.zig");
const machine_pool = @import("machine_pool.zig");
const MachineConnectionPool = @import("MachineConnectionPool.zig");
const RestoreAllRelay = @import("RestoreAllRelay.zig");
const remote_connection = @import("../../remote/connection.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const relay_signin = @import("../../remote/relay_signin.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyMachineChooser");
const FILTER_ID: u16 = 100;
const LIST_ID: u16 = 101;
const ACCOUNT_ID: u16 = 102;
const MENU_ID: u16 = 103;
const ACTIVITY_ID: u16 = 104;
/// The signed-in state's "Sign Out" LINK (T311). A second control rather than a
/// restyled `ACCOUNT_ID`: the signed-out state must stay a real themed button,
/// and one HWND cannot be both a themed push button and an owner-drawn link.
const ACCOUNT_LINK_ID: u16 = 105;
const RESTORE_ALL_ID: u16 = 106;

/// The action row's captions. Measured (not assumed) to size their buttons, so
/// they live where both the creation and the measurement can see them.
const PRIMARY_LABEL = "New Window";
const ACTIVITY_LABEL = "Activity";
const RESTORE_ALL_LABEL = "Restore All";

/// `Host Settings…` needs the per-host defaults store, which T174 built
/// (`host_defaults.zig` + `HostSettingsDialog.zig`) — one bool, at the one place
/// the menu is built (see `chooser_menu`).
const HOST_SETTINGS_AVAILABLE = true;

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

/// The dialog's palette, derived from the surface `window-theme` puts the app
/// on and the accent the user picked (T308).
///
/// This used to be four `w32.RGB(...)` literals plus a `DIALOG_BG` of
/// `RGB(32,32,32)` — "the RenameDialog dark palette", which is a fine
/// description of a dialog that can only ever be dark. On a light system theme
/// the chooser opened dark with light text on it while the window behind it was
/// light: the panel-scale version of the defect T203 was filed against.
///
/// A function rather than a `const` because the value is a live theme read, and
/// container-level consts are comptime. `system_colors.panelPalette` memoizes
/// it on its inputs, so calling this per painted row is a struct copy.
fn pal(self: *const MachineChooser) panel_theme.Panel {
    return palFor(self.window.app);
}

fn palFor(app: *App) panel_theme.Panel {
    const bg = app.config.background;
    return system_colors.panelPalette(
        app.config.@"window-theme",
        .{ .r = bg.r, .g = bg.g, .b = bg.b },
    );
}

/// The master column's wash: the listbox is painted with it (not the field
/// color) so the filter, the rows and the status strip read as one column — the
/// way Mac's `machineListColumn` does. It is also the row background the
/// owner-drawn selection/hover fills composite against.
fn columnWash(p: panel_theme.Panel) chooser_rows.Rgb {
    return chooser_rows.columnWash(p.bg);
}

fn rgb(c: chooser_rows.Rgb) u32 {
    return w32.RGB(c.r, c.g, c.b);
}

/// Hands out `MachineChooser.id`. A roster reply is matched on that id, never
/// on a pointer: the chooser it was asked for may already be freed by the time
/// the worker's `PostMessage` is dispatched, and a pointer comparison there
/// would be a use-after-free with a plausible-looking result.
var next_chooser_id: u64 = 1;

var class_registered: bool = false;
/// The dialog surface, the filter field, the master column's wash and the
/// hairline rules (T175). Process-lifetime, and since T308 keyed on the color
/// they were made for: a GDI brush is immutable, so a theme flip has to mean a
/// new object rather than a stale handle painting the old palette forever.
var bg_brush: brush_cache.CachedBrush = .{};
var field_brush: brush_cache.CachedBrush = .{};
var wash_brush: brush_cache.CachedBrush = .{};
var divider_brush: brush_cache.CachedBrush = .{};

window: *Window,
hwnd: w32.HWND,
filter: w32.HWND,
list: w32.HWND,
hint: w32.HWND,
/// The detail pane's primary action ("New Window"), Mac's `.borderedProminent`
/// button — in the detail header, NOT the footer (which holds Cancel alone).
primary_btn: w32.HWND,
/// "Restore All" — rebuild this machine's whole window topology here (T335).
/// Offered only when the highlighted machine has at least two ALIVE sessions
/// (`chooser_sessions.restoreAllAvailable`), so it is hidden far more often than
/// it is shown.
restore_all_btn: w32.HWND,
/// "Activity" — opens the Activity Monitor for the selected machine (T177).
/// Mac gates it on the row being remote, in the same `if case .remote` that
/// carries the `…` menu (MachineChooserView.swift:474-491), so the two appear
/// and disappear together.
activity_btn: w32.HWND,
/// The `…` management-menu button, beside the primary action (T176). Hidden
/// for rows that have no management actions (the Local row).
menu_btn: w32.HWND,
cancel_btn: w32.HWND,
account_status: w32.HWND,
account_btn: w32.HWND,
/// The signed-in state's "Sign Out" link (T311). Only one of it and
/// `account_btn` is ever visible — see `accountControl`.
account_link: w32.HWND,
/// True while the pointer is over the link, so it can underline. Entering is
/// seen from `WM_SETCURSOR` (which the child forwards to us, so the message
/// already names the window under the cursor); LEAVING needs the link's own
/// `WM_MOUSELEAVE` (T315), because a pointer that goes from the link straight
/// out of the dialog produces no further `WM_SETCURSOR` at all and the
/// underline would stick until it came back.
link_hot: bool = false,
font: ?*anyopaque = null,
/// Smaller font for the dimmed row subline (Mac's `.caption`).
subtitle_font: ?*anyopaque = null,
/// Semibold display font for the detail pane's machine name (Mac's `.title3`).
title_font: ?*anyopaque = null,
/// Body, underlined — the link's hover/pressed face. A link is accent-colored
/// at rest (Fluent's HyperlinkButton, and Mac's `.link` style) and underlines
/// when the pointer is on it, so the affordance is not carried by color alone.
link_font: ?*anyopaque = null,
/// Body, semibold — the monogram letter. Mac sets it at `size * 0.42` of a 34
/// circle, which IS 14: the ramp's body size, so the mark lands on Mac's number
/// without inventing a fourth type size (T310's ramp stays 12/14/20).
strong_font: ?*anyopaque = null,

/// The listbox's original window procedure, saved when it is subclassed for
/// hover tracking. Restored is unnecessary — the control dies with the dialog.
list_proc: ?*const anyopaque = null,
/// Row under the pointer, or -1. Drives the hover wash (Mac's `hoveredIndex`).
hover_row: i32 = -1,
/// Whether the listbox currently has a `TrackMouseEvent` leave request in
/// flight, so one is armed per entry instead of per mouse-move.
tracking_leave: bool = false,

/// The account link's original window procedure, saved when it is subclassed
/// for leave tracking (T315). Same lifetime rule as `list_proc`.
link_proc: ?*const anyopaque = null,
/// Whether the link currently has a `TrackMouseEvent` leave request in flight.
link_tracking_leave: bool = false,
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

/// Whether a sign-in can be started at all — false when this build carries no
/// Google OAuth client id and none is in the environment (T747). Resolved once
/// on open: it is a build/environment fact, not something the dialog can
/// change, and the account row hides its button entirely when it is false.
sign_in_configured: bool = true,

/// The fetched device list. Owned by `parsed` (its own JSON arena); empty when
/// there is no credential or the fetch failed. Freed in `close`.
parsed: ?relay_directory.Parsed = null,
devices: []const relay_directory.Device = &.{},

/// Current filtered rows (display order) mapped 1:1 to the listbox items.
rows: [MAX_DEVICES + 1]Row = undefined,
row_count: usize = 0,

/// This chooser's identity for the whole app run — see `next_chooser_id`.
id: u64,

/// The selected machine's live sessions (T318). Only the Local row has one
/// today; a remote machine's roster comes over its own transport in T319.
roster: SessionRoster,

/// This chooser's borrow on the SELECTED remote machine's warm connection
/// (T461), or null when the selection is Local, empty, or signed out. It follows
/// the selection: moving to another machine releases this one and takes a new
/// one, which is what keeps a browse from leaving a connection open to every
/// machine the user clicked through. Released in `destroyState`, so a connection
/// can never outlive the dialog that wanted it.
pool_lease: ?*MachineConnectionPool.Lease = null,

/// A cross-machine Restore All is dialing on a worker thread (T339). It gates
/// a second press: the first one's dials are still in flight, and pressing
/// again would rebuild the same topology twice — the button has no other way
/// to say "already working on it" now that the work no longer blocks the
/// keystroke.
restore_inflight: bool = false,

/// Dialog layout in physical pixels from the owner DPI scale. Pure — the math
/// and its tests live in `chooser_layout.zig`.
const Layout = chooser_layout.Layout;
const layout = chooser_layout.layout;

/// `chooser_layout.Rect` as the `RECT` the placement APIs want.
fn rect(r: chooser_layout.Rect) w32.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// Case-insensitive ASCII substring test — one implementation for every win32
/// filter box, in `text_search.zig` (T288). The Activity Monitor's process
/// filter folds with the same function, and the ASCII limit is documented and
/// revisited there rather than in each caller.
const containsIgnoreCase = text_search.containsIgnoreCase;

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
    // Every control here is created with a comptime UTF-16 literal, and each one
    // costs comptime branches to transcode. The function crossed the 1000-branch
    // default when T335 added its button, so the budget is stated rather than
    // being one string literal away from a build failure again.
    @setEvalBranchQuota(10_000);
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
        .restore_all_btn = undefined,
        .activity_btn = undefined,
        .menu_btn = undefined,
        .cancel_btn = undefined,
        .account_status = undefined,
        .account_btn = undefined,
        .account_link = undefined,
        .arena = std.heap.ArenaAllocator.init(alloc),
        .id = next_chooser_id,
        .roster = .init(alloc),
    };
    next_chooser_id +%= 1;
    // The saved layout's titles are one rung of the session label ladder, and
    // the file does not change while a dialog is open — read it once here
    // rather than on every repaint.
    self.roster.loadManifest();

    // Resolve the relay base + bearer token and fetch the device list once.
    // Any failure degrades to a Local-only list plus a footer hint.
    const arena = self.arena.allocator();
    self.relay_base = relay_directory.resolveBase(arena) catch relay_directory.default_base;
    self.token = IpcHandlers.resolveToken(arena);
    self.email = relay_signin.signedInEmail(arena);
    self.sign_in_configured = relay_signin.isConfigured(arena);
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

    // Account row (T141, recomposed in T311): the status/email text, the
    // signed-out state's bordered button, and the signed-in state's link.
    // Positions come from `accountRow` at `refreshAccountRow` time — the row has
    // two compositions, so nothing here has a fixed slot.
    //
    // `SS_RIGHT` because the block is right-aligned in BOTH states (Mac 2.4);
    // `SS_PATHELLIPSIS` because the email is middle-truncated; `SS_CENTERIMAGE`
    // so the single line sits on the rect's center line rather than its top;
    // `SS_NOPREFIX` because an address may contain '&'.
    self.account_status = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.SS_RIGHT |
            w32.SS_PATHELLIPSIS | w32.SS_CENTERIMAGE | w32.SS_NOPREFIX,
        l.account.band.left,
        l.account.band.top,
        l.account.band.width(),
        l.account.band.height(),
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
        l.account.band.left,
        l.account.band.top,
        l.account.band.width(),
        l.control_h,
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
    // The link is a BUTTON so it keeps the tab stop, the focus rect and
    // BN_CLICKED that a clickable STATIC would throw away; only its PAINT is
    // ours (`drawAccountLink`).
    self.account_link = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.BS_OWNERDRAW,
        l.account.band.left,
        l.account.band.top,
        l.account.band.width(),
        l.account.link_h,
        hwnd,
        @ptrFromInt(@as(usize, ACCOUNT_LINK_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    // Leave tracking has to sit on the LINK, not on the dialog: while the
    // pointer is over a child, the parent is not the window under the cursor,
    // so a `TME_LEAVE` armed on the dialog fires the moment the pointer enters
    // the link — which would clear the hover on entry instead of on exit. The
    // proc reaches `self` through the PARENT's userdata rather than the
    // button's own, because a control class may use `GWLP_USERDATA` for itself.
    self.link_proc = @ptrFromInt(@as(usize, @bitCast(w32.SetWindowLongPtrW(
        self.account_link,
        w32.GWLP_WNDPROC,
        @bitCast(@intFromPtr(&linkWndProc)),
    ))));

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

    // The action row is packed from measured captions, which needs the dialog
    // font — created further down. Every button here is therefore built at the
    // row's leading edge and re-placed by the `applyLayout` at the end of this
    // function; nothing is on screen until then.
    const seed = rect(l.action_row);

    // Mac's primary action is labeled for what it does — "New Window" — and it
    // lives in the detail header beside the machine it acts on, not in the
    // footer (MachineChooserView.swift:456-466, 1410-1418).
    self.primary_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(PRIMARY_LABEL),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.BS_DEFPUSHBUTTON,
        seed.left,
        seed.top,
        l.action_min_btn_w,
        seed.bottom - seed.top,
        hwnd,
        @ptrFromInt(@as(usize, w32.IDOK)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    // "Rebuild this machine's full window layout here" (466-473). Created
    // hidden like Activity, and hidden far more often: it needs the selected
    // machine to have two or more live sessions, which `refreshDetail` decides
    // from the roster.
    self.restore_all_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(RESTORE_ALL_LABEL),
        w32.WS_CHILD,
        seed.left,
        seed.top,
        l.action_min_btn_w,
        seed.bottom - seed.top,
        hwnd,
        @ptrFromInt(@as(usize, RESTORE_ALL_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.restore_all_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    // "Open Activity Monitor for <machine>" (474-481). Created hidden: the row
    // that is selected when the chooser opens may not be a remote one, and
    // `refreshDetail` is what decides.
    self.activity_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral(ACTIVITY_LABEL),
        w32.WS_CHILD,
        seed.left,
        seed.top,
        l.action_min_btn_w,
        seed.bottom - seed.top,
        hwnd,
        @ptrFromInt(@as(usize, ACTIVITY_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.activity_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);
    // Mac's per-row management menu (`ellipsis.circle`) lives in the same
    // action row (456-492). Labeled with the ellipsis CHARACTER rather than
    // three periods so it reads as one glyph at any DPI.
    self.menu_btn = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("…"),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE,
        seed.left,
        seed.top,
        seed.bottom - seed.top,
        seed.bottom - seed.top,
        hwnd,
        @ptrFromInt(@as(usize, MENU_ID)),
        window.app.hinstance,
        null,
    ) orelse {
        _ = w32.DestroyWindow(hwnd);
        self.destroyState();
        return;
    };
    _ = w32.SetWindowTheme(self.menu_btn, std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"), null);

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
        for ([_]w32.HWND{
            self.filter,          self.list,        self.account_status,
            self.account_btn,     self.primary_btn, self.restore_all_btn,
            self.activity_btn,    self.menu_btn,    self.cancel_btn,
        }) |c| {
            _ = w32.SendMessageW(c, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
    }
    // The link's hover/pressed face: the same body size, underlined. Two fonts
    // rather than one underlined one, because an always-underlined link is a
    // 2003 look — Fluent and Mac both underline on interaction only.
    self.link_font = w32.CreateFontW(
        -l.font_h,
        0,
        0,
        0,
        type_ramp.weight_normal,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral(type_ramp.face),
    );
    // The monogram letter (T311): body size, semibold.
    self.strong_font = w32.CreateFontW(
        -l.font_h,
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
    );
    // The row subline is a notch smaller, like Mac's `.caption`. Owner-drawn
    // rows select it into the DC themselves, so it is never sent WM_SETFONT.
    self.subtitle_font = w32.CreateFontW(
        -chooser_rows.rowMetrics(window.scale).subtitle_font_h,
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
    // The status strip is the same caption role (§3.2), and `hint_line_h` is
    // derived from it — so it takes the caption font rather than the body one,
    // or the reserved height and the wrapped text stop agreeing.
    if (self.subtitle_font) |f| {
        _ = w32.SendMessageW(self.hint, w32.WM_SETFONT, @intFromPtr(f), 1);
    }
    // The detail pane's machine name is Mac's `.title3` + `.semibold`: bigger
    // than the dialog font and heavier, so the pane has an obvious subject.
    self.title_font = w32.CreateFontW(
        -l.title_font_h,
        0,
        0,
        0,
        l.title_font_weight,
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

    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.setHint(hint_text);
    self.refreshAccountRow();
    self.refilter("");

    window.machine_chooser = self;

    // Prime the selected row's roster the moment the dialog opens (Mac's
    // `primeLocal`), so the count is in the detail subtitle before the user has
    // looked at it. Off-thread, so this costs the dialog nothing.
    self.syncRoster();

    _ = w32.EnableWindow(owner, 0);
    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.SetForegroundWindow(hwnd);
    _ = w32.SetFocus(self.filter);
}

/// Fetch the device list into `self.parsed`/`self.devices`. Returns the footer
/// hint text describing the outcome (empty when devices were listed).
/// `list_alloc` backs the returned `Parsed` (freed in `close`).
fn fetchDevices(self: *MachineChooser, list_alloc: Allocator) []const u8 {
    // Pointing at a button that is not drawn — and could not work if it were —
    // is worse than saying nothing, so the unconfigured build gets the remedy
    // instead of the invitation (T747).
    const tok = self.token orelse return if (self.sign_in_configured)
        "Not signed in — use Sign in with Google above to list your machines."
    else
        RelayAccountRow.unconfigured_hint;

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

/// Relabel AND recompose the account row from the current state (T141, T311).
/// Signed in it is the email over a "Sign Out" link with a monogram beside
/// them; signed out (or busy) it is one bordered button sized to its own
/// caption. The two controls swap visibility — a hidden one is not placed
/// off-screen, so `IsWindowVisible` stays the honest answer for the Tab walk
/// and for the acceptance script.
fn refreshAccountRow(self: *MachineChooser) void {
    const busy = RelayAccountRow.isRunning();
    const state = self.accountState();
    const signed_in = state == .signed_in;
    // Nothing to press in either of these: the link is the signed-in control,
    // and an unconfigured build has no control at all (T747).
    const hide_button = signed_in or state == .unconfigured;

    setText(self.account_status, RelayAccountRow.statusText(self.email, busy, self.sign_in_configured));
    setText(self.account_link, RelayAccountRow.buttonLabel(true, false));
    setText(self.account_btn, RelayAccountRow.buttonLabel(false, busy));

    // The email is the ramp's CAPTION role and the state sentence its BODY, so
    // the STATIC's font follows the state the same way its rect does.
    const status_font = if (signed_in) self.subtitle_font else self.font;
    if (status_font) |f| _ = w32.SendMessageW(self.account_status, w32.WM_SETFONT, @intFromPtr(f), 1);

    // Hand focus off BEFORE disabling or hiding the control that has it.
    // Disabling the focused control makes Windows drop the thread's keyboard
    // focus entirely, and with no focus window WM_KEYDOWN arrives with
    // `msg.hwnd == null` — which the app's message loop cannot attribute to this
    // dialog, so Enter/Escape/Tab go dead for as long as the sign-in runs
    // (measured, not theorized: `relay-account.ps1` asserts focus stays inside
    // the chooser while busy, and it failed before this line existed). Hiding
    // does the same thing, which is why the guard covers both controls.
    const focus = w32.GetFocus();
    const on_account = focus == @as(?w32.HWND, self.account_btn) or
        focus == @as(?w32.HWND, self.account_link);
    // The control that will still be pressable after this pass — null in the
    // unconfigured state, where BOTH are hidden and focus has nowhere to stay.
    const live: ?w32.HWND = if (state == .unconfigured) null else self.accountControl();
    if (on_account and (busy or focus != live)) {
        _ = w32.SetFocus(self.filter);
    }

    _ = w32.ShowWindow(self.account_btn, if (hide_button) w32.SW_HIDE else w32.SW_SHOW);
    _ = w32.ShowWindow(self.account_link, if (signed_in) w32.SW_SHOW else w32.SW_HIDE);
    // A hidden window gets no `WM_MOUSELEAVE`, so signing out under the pointer
    // would leave the flag set and the link would come back already underlined
    // the next time it is shown.
    if (!signed_in) self.setLinkHot(false);
    _ = w32.EnableWindow(self.account_btn, if (busy) 0 else 1);

    self.applyAccountRow(layout(self.window.scale, self.hint_lines));
}

/// What the account row is showing right now. One derivation, so the labels,
/// the placement and the measurement cannot disagree about the state.
fn accountState(self: *const MachineChooser) chooser_layout.AccountState {
    return chooser_layout.accountState(
        self.email != null,
        RelayAccountRow.isRunning(),
        self.sign_in_configured,
    );
}

/// The account row's VISIBLE control — the link when signed in, the bordered
/// button otherwise. One name for "the thing the user can press", so the focus
/// cycle, the Enter handler and the click routing cannot disagree about which
/// of the two is live. In the `unconfigured` state neither is shown; the Tab
/// walk steps over the hidden button, so this still answers safely.
fn accountControl(self: *const MachineChooser) w32.HWND {
    return if (self.email != null and !RelayAccountRow.isRunning())
        self.account_link
    else
        self.account_btn;
}

/// Place the account row's controls for the current state, and repaint the band
/// (the monogram is painted, not a control, so moving the stack has to
/// invalidate it).
fn applyAccountRow(self: *MachineChooser, l: Layout) void {
    const state = self.accountState();
    const row = chooser_layout.accountRow(l, state, self.measureAccount(state));

    _ = w32.MoveWindow(
        self.account_status,
        row.text.left,
        row.text.top,
        row.text.width(),
        row.text.height(),
        1,
    );
    if (row.link) |r| _ = w32.MoveWindow(self.account_link, r.left, r.top, r.width(), r.height(), 1);
    if (row.button) |r| _ = w32.MoveWindow(self.account_btn, r.left, r.top, r.width(), r.height(), 1);

    var band = rect(l.account.band);
    _ = w32.InvalidateRect(self.hwnd, &band, 1);
}

/// Caption widths for the account row, each measured in the font it will be
/// DRAWN in — the layout module is text-free by design (T235's lesson), and the
/// email is caption-sized while the link and the button are body-sized, so one
/// measurement font would be wrong for one of them.
fn measureAccount(self: *const MachineChooser, state: chooser_layout.AccountState) chooser_layout.AccountText {
    return switch (state) {
        .signed_in => .{
            .email = self.measureWith(
                self.subtitle_font,
                RelayAccountRow.statusText(self.email, false, self.sign_in_configured),
            ),
            .link = self.measureWith(self.font, RelayAccountRow.buttonLabel(true, false)),
        },
        .signed_out, .busy => .{
            .button = self.measureWith(self.font, RelayAccountRow.buttonLabel(false, state == .busy)),
        },
        // Nothing to size: the sentence takes the whole band and there is no
        // control beside it (T747).
        .unconfigured => .{},
    };
}

/// The account button was clicked: sign out when signed in, else sign in. Both
/// run off-thread (`RelayAccountRow`); the row goes to its pending state
/// immediately so the click is visibly acknowledged.
fn onAccountClicked(self: *MachineChooser) void {
    // Unreachable through the UI — the button is not drawn in the unconfigured
    // state — but the click can still arrive as a synthesized BM_CLICK, and
    // starting a flow that can only fail is the defect this state exists to
    // remove (T747).
    if (self.email == null and !self.sign_in_configured) {
        self.setHint(RelayAccountRow.unconfigured_hint);
        return;
    }
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

/// Drop the current device list and fetch it again with the current token,
/// keeping the highlight on the machine that was selected (Mac's
/// `reanchorSelection`). Without the re-anchor, renaming a machine throws the
/// user back to the Local row — and with it the detail pane and the management
/// button that acted on the machine they were working with.
fn reloadDevices(self: *MachineChooser) void {
    // The id has to be COPIED: the refetch frees the arena it points into.
    var anchor_buf: [128]u8 = undefined;
    const anchor: ?[]const u8 = anchor: {
        switch (self.selectedRow() orelse break :anchor null) {
            .local => break :anchor null,
            .device => |i| {
                const id = self.devices[i].id;
                if (id.len > anchor_buf.len) break :anchor null;
                @memcpy(anchor_buf[0..id.len], id);
                break :anchor anchor_buf[0..id.len];
            },
        }
    };

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

    // A machine that is gone (removed, or filtered out) simply keeps
    // `refilter`'s first-row selection.
    if (anchor) |id| {
        if (rowForDeviceId(self.rows[0..self.row_count], self.devices, id)) |row| {
            _ = w32.SendMessageW(self.list, w32.LB_SETCURSEL, row, 0);
            self.refreshDetail();
        }
    }
}

/// The display row showing the device with `id`, or null when it is not in the
/// current filtered list. Pure — unit-tested.
pub fn rowForDeviceId(
    rows: []const Row,
    devices: []const relay_directory.Device,
    id: []const u8,
) ?usize {
    for (rows, 0..) |row, i| switch (row) {
        .local => {},
        .device => |d| {
            if (d < devices.len and std.mem.eql(u8, devices[d].id, id)) return i;
        },
    };
    return null;
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
/// the strip's OWN font via `DT_CALCRECT | DT_WORDBREAK` — the same wrapping
/// the STATIC will do, so the reserved height always matches what is drawn.
/// That font is the caption role since T310; measuring with the body font while
/// the STATIC renders in caption is how a reserved height quietly stops being
/// the height that gets used.
fn measureHintLines(self: *const MachineChooser, text: []const u8) i32 {
    if (text.len == 0) return 1;
    const l = layout(self.window.scale, self.hint_lines);
    const width = l.hint.right - l.hint.left;
    if (width <= 0) return 1;

    const hdc = w32.GetDC(self.hint) orelse return 1;
    defer _ = w32.ReleaseDC(self.hint, hdc);
    const prev = if (self.subtitle_font) |f| w32.SelectObject(hdc, f) else null;
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
        .{ .hwnd = self.filter, .r = rect(l.filter) },
        .{ .hwnd = self.list, .r = rect(l.list) },
        .{ .hwnd = self.hint, .r = rect(l.hint) },
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
    // The account row is packed, not slotted (T311), so it places itself from
    // the state rather than from a fixed rect in `Layout`.
    self.applyAccountRow(l);
    self.layoutActions(l);
}

/// Place the detail pane's action row for the CURRENT selection. The row is a
/// run, not a set of fixed slots (T177): its composition changes with the
/// machine, so the `…` button's position depends on whether Activity is in the
/// row beside it — which means this has to run on every selection change, not
/// only on a DPI change.
fn layoutActions(self: *MachineChooser, l: Layout) void {
    const row = chooser_layout.actionRow(l, self.actionComposition(), self.measureActions());
    for (row.kinds[0..row.len], row.rects[0..row.len]) |kind, r| {
        const hwnd = switch (kind) {
            .primary => self.primary_btn,
            .restore_all => self.restore_all_btn,
            .activity => self.activity_btn,
            .menu => self.menu_btn,
        };
        _ = w32.MoveWindow(hwnd, r.left, r.top, r.width(), r.height(), 1);
    }
}

/// Which optional actions the selected row offers. Mac gates BOTH Activity and
/// the `…` menu on `if case .remote(let machine)` (MachineChooserView.swift:
/// 474-491) — the Local row gets neither. Restore All is gated on the machine's
/// live session COUNT instead (T335), which is why the roster is read here.
fn actionComposition(self: *const MachineChooser) chooser_layout.Composition {
    return compositionFor(self.selectedRow(), self.roster.aliveCount());
}

/// Pure half of `actionComposition` — unit-tested. `null` is the empty list
/// (the filter matched nothing), which offers no actions at all. `alive` is how
/// many of the highlighted machine's sessions are running.
fn compositionFor(row: ?Row, alive: usize) chooser_layout.Composition {
    const r = row orelse return .{};
    return .{
        // Machine-agnostic since T336, which is also Mac's rule
        // (MachineChooserView.swift:145-155): the count of LIVE sessions is the
        // whole condition, and where they run only decides which transport the
        // rebuild takes. Until T336 this carried an `r == .local` clause,
        // because offering a button that cannot act is worse than no button.
        .restore_all = chooser_sessions.restoreAllAvailable(alive),
        .activity = r != .local,
        .menu = chooser_menu.hasMenu(menuState(r)),
    };
}

/// Caption widths for the labeled action buttons, measured with the dialog's
/// own font. The layout module is text-free by design, so the measuring belongs
/// here (T235's lesson).
fn measureActions(self: *const MachineChooser) chooser_layout.ActionText {
    return .{
        .primary = self.measureCaption(PRIMARY_LABEL),
        .restore_all = self.measureCaption(RESTORE_ALL_LABEL),
        .activity = self.measureCaption(ACTIVITY_LABEL),
    };
}

/// Width of `text` in the dialog's body font, in physical pixels.
fn measureCaption(self: *const MachineChooser, text: []const u8) i32 {
    return self.measureWith(self.font, text);
}

/// Width of `text` in `font`, in physical pixels. A width measured in the wrong
/// font is worse than no measurement: it sizes a slot the text does not fit.
fn measureWith(self: *const MachineChooser, font: ?*anyopaque, text: []const u8) i32 {
    const hdc = w32.GetDC(self.hwnd) orelse return 0;
    defer _ = w32.ReleaseDC(self.hwnd, hdc);
    const old = if (font) |f| w32.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = w32.SelectObject(hdc, o);
    };

    // Sized for an email, not for a button caption: `utf8ToUtf16Le` returns
    // NoSpaceLeft for anything longer, and a measurement that silently returns
    // 0 collapses the slot it was supposed to size.
    var wbuf: [256]u16 = undefined;
    if (text.len > wbuf.len) return 0;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
    var r: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.DrawTextW(
        hdc,
        &wbuf,
        @intCast(wlen),
        &r,
        w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_CALCRECT | w32.DT_NOPREFIX,
    );
    return r.right - r.left;
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
    const p = self.pal();

    if (wash_brush.get(rgb(columnWash(p)))) |b| {
        var r = rect(l.master);
        _ = w32.FillRect(hdc, &r, b);
    }
    if (divider_brush.get(rgb(chooser_rows.dividerColor(p.bg)))) |b| {
        var rules = [_]w32.RECT{
            .{ .left = 0, .top = l.header_divider_y, .right = l.client_w, .bottom = l.header_divider_y + 1 },
            .{ .left = l.master_divider_x, .top = l.master.top, .right = l.master_divider_x + 1, .bottom = l.master.bottom },
            .{ .left = 0, .top = l.footer_divider_y, .right = l.client_w, .bottom = l.footer_divider_y + 1 },
        };
        for (&rules) |*r| _ = w32.FillRect(hdc, r, b);
    }

    self.paintAccount(hdc, l);
    self.paintDetail(hdc, l);
}

/// The account row's monogram circle (T311). Mac draws the Google profile
/// picture when it has one and falls back to initials on an accent gradient
/// (MachineChooserView.swift:942-976); the brokered sign-in never hands us a
/// picture URL, so the monogram IS the win32 avatar.
///
/// The fill is FLAT accent, not a gradient. The letter's contrast floor is
/// computed against one color — a gradient would make the floor a function of
/// position, so the glyph would be legible at one end of the disc and not
/// necessarily at the other, and there is no second color anybody chose. The
/// cue Mac is buying with the gradient (this is an identity mark, not a button)
/// is already carried by the shape.
fn paintAccount(self: *MachineChooser, hdc: w32.HDC, l: Layout) void {
    const email = self.email orelse return;
    if (RelayAccountRow.isRunning()) return;
    const row = chooser_layout.accountRow(l, .signed_in, self.measureAccount(.signed_in));
    const box = row.avatar orelse return;

    const fill = self.pal().accent;
    const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(fill)) orelse return;
    defer _ = w32.DeleteObject(pen);
    const brush = w32.CreateSolidBrush(rgb(fill)) orelse return;
    defer _ = w32.DeleteObject(brush);
    const old_pen = w32.SelectObject(hdc, pen);
    const old_brush = w32.SelectObject(hdc, brush);
    _ = w32.Ellipse(hdc, box.left, box.top, box.right, box.bottom);
    _ = w32.SelectObject(hdc, old_pen);
    _ = w32.SelectObject(hdc, old_brush);

    const letter = RelayAccountRow.monogram(email) orelse return;
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, rgb(color_math.contrastForeground(fill)));
    const old_font = if (self.strong_font) |f| w32.SelectObject(hdc, f) else null;
    defer if (old_font) |o| {
        _ = w32.SelectObject(hdc, o);
    };
    var r = rect(box);
    var wbuf = [_]u16{letter};
    _ = w32.DrawTextW(
        hdc,
        &wbuf,
        1,
        &r,
        w32.DT_CENTER | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
    );
}

/// The "Sign Out" link (T311, finding 6). Mac styles it `.link`; Windows has no
/// link BUTTON style, so the control is `BS_OWNERDRAW` — it keeps the tab stop,
/// the focus and BN_CLICKED, and only the paint is ours.
///
/// Rest is accent text on the dialog surface with no border and no underline
/// (Fluent's HyperlinkButton); hover and press underline it, and focus draws the
/// system's own focus rect — so no state is signalled by color alone.
fn drawAccountLink(self: *const MachineChooser, dis: *const w32.DRAWITEMSTRUCT) void {
    const hdc = dis.hDC;
    var r = dis.rcItem;
    const p = self.pal();
    if (bg_brush.get(rgb(p.bg))) |b| _ = w32.FillRect(hdc, &r, b);

    const disabled = (dis.itemState & w32.ODS_DISABLED) != 0;
    const pressed = (dis.itemState & w32.ODS_SELECTED) != 0;
    const focused = (dis.itemState & w32.ODS_FOCUS) != 0;
    const marked = self.link_hot or pressed or focused;

    const color = if (disabled) p.secondary else p.accent;

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    _ = w32.SetTextColor(hdc, rgb(color));
    const face = if (marked) self.link_font else self.font;
    const old_font = if (face) |f| w32.SelectObject(hdc, f) else null;
    var text_rect = r;
    drawTextUtf8Aligned(
        hdc,
        RelayAccountRow.buttonLabel(true, false),
        &text_rect,
        w32.DT_RIGHT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_NOPREFIX,
    );
    if (old_font) |o| _ = w32.SelectObject(hdc, o);

    if (focused) _ = w32.DrawFocusRect(hdc, &r);
}

/// The detail pane's header: the selected machine's glyph, name and subtitle —
/// or Mac's centered "No machines" when the filter matched nothing.
fn paintDetail(self: *MachineChooser, hdc: w32.HDC, l: Layout) void {
    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    const p = self.pal();

    const row = self.selectedRow() orelse {
        _ = w32.SetTextColor(hdc, rgb(p.secondary));
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

    // The mark is square at the system's large-icon size (T310), the way the
    // row's is square at its small-icon size — one rule for both.
    const box = l.detail_glyph;
    drawGlyphBox(
        hdc,
        box.left,
        box.top,
        box.width(),
        box.height(),
        detail.glyph,
        p.secondary,
    );

    var title_rect = rect(l.detail_title);
    const old_font = if (self.title_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(p.text));
    drawTextUtf8(hdc, detail.title, &title_rect);
    if (old_font) |o| _ = w32.SelectObject(hdc, o);

    // The detail subtitle is the ramp's CAPTION role, like the row subline it
    // echoes — it was drawing at body size, which made it compete with the
    // machine name instead of supporting it.
    //
    // Once the roster has loaded it LEADS with the session count, the way Mac's
    // `detailSubtitle` does (`MachineChooserView.swift:520-540`).
    var sub_buf2: [128]u8 = undefined;
    const subtitle = self.detailSubtitle(&sub_buf2, row, detail.subtitle);
    var sub_rect = rect(l.detail_subtitle);
    const old_sub = if (self.subtitle_font) |f| w32.SelectObject(hdc, f) else null;
    _ = w32.SetTextColor(hdc, rgb(p.secondary));
    drawTextUtf8(hdc, subtitle, &sub_rect);
    if (old_sub) |o| _ = w32.SelectObject(hdc, o);

    self.paintSessions(hdc, l, row);
}

/// The detail subtitle, with the session count prepended once the roster has
/// loaded for a row that HAS one. A machine whose roster is still loading (or
/// which has none) keeps its plain subtitle rather than showing a placeholder
/// count — a number that appears and then changes is worse than one that
/// appears late.
fn detailSubtitle(
    self: *const MachineChooser,
    buf: []u8,
    row: Row,
    base: []const u8,
) []const u8 {
    _ = row;
    if (self.roster.state != .loaded) return base;

    var rows: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const visible = self.roster.visible(self.window.app, &rows);
    var count_buf: [32]u8 = undefined;
    const count = chooser_sessions.countLabel(&count_buf, visible.len);
    if (base.len == 0) return std.fmt.bufPrint(buf, "{s}", .{count}) catch base;
    return std.fmt.bufPrint(buf, "{s} - {s}", .{ count, base }) catch base;
}

/// Paint the roster region for the selected row. Every row has one since T319 —
/// the local agent's, or a relay machine's over its own short-lived dial — and
/// the roster paints nothing at all when it is pointed at no machine.
fn paintSessions(self: *MachineChooser, hdc: w32.HDC, l: Layout, row: Row) void {
    _ = row;
    const p = self.pal();
    var rows: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const visible = self.roster.visible(self.window.app, &rows);
    self.roster.paint(.{
        .hdc = hdc,
        .region = l.sessions,
        .scale = self.window.scale,
        .bg = p.bg,
        // The user's accent floored against the surface the cards composite on
        // — the same resolution `drawRow` does for the list's selected pill, so
        // one selection language covers both halves of the dialog (T320).
        .accent = p.accent,
        .label_font = self.strong_font,
        .caption_font = self.subtitle_font,
    }, visible);
}

/// GUI thread: a roster fetch landed. Finds the chooser it was asked for by id
/// — never by pointer — and hands it over; a chooser that closed in the
/// meantime means the result is freed here instead.
pub fn onSessions(app: *App, res: *SessionRoster.Result) void {
    defer res.destroy();
    for (app.windows.items) |win| {
        const chooser = win.machine_chooser orelse continue;
        if (chooser.id != res.chooser_id) continue;
        if (chooser.roster.adopt(res)) {
            // The offset survives the refetch (T333); the ROWS may not, so it is
            // re-clamped here, where the region is known, before anything paints
            // against it.
            chooser.clampRosterScroll();
            chooser.refreshSessions();
        }
        return;
    }
    log.debug("chooser roster: reply landed after its chooser closed", .{});
}

/// Point the roster at whatever row is selected (T319). Called on open and on
/// every selection change; the roster itself decides whether that means a fresh
/// fetch, a refresh in place, or nothing at all.
fn syncRoster(self: *MachineChooser) void {
    var target: chooser_sessions.Target = .none;
    var remote: ?SessionRoster.Remote = null;
    if (self.selectedRow()) |row| switch (row) {
        .local => target = .local,
        .device => |i| if (i < self.devices.len) {
            target = .{ .remote = self.devices[i].id };
            // No credential leaves `remote` null, which the roster reads as the
            // signed-out state and says so — it does not dial and fail.
            if (self.token) |tok| remote = .{
                .base = self.relay_base,
                .device = self.devices[i].id,
                .token = tok,
            };
        },
    };
    // The lease FIRST: `show` fetches, and a fetch against a remote machine
    // borrows the pooled connection this lease is what dials.
    self.syncPoolLease(target, remote);
    if (self.roster.show(self.window.app, self.id, target, remote)) self.refreshSessions();
}

/// Hold a lease on exactly the machine the roster is pointed at (T461) — one
/// per chooser, moved rather than accumulated.
///
/// Keyed by ENDPOINT, so re-selecting the same machine (or selecting a second
/// row that names it) keeps the existing lease and its warm connection instead of
/// releasing and re-dialing. The release comes FIRST when the endpoint really
/// changed: the machine we are leaving should let go of its socket before the one
/// we are arriving at takes a slot.
fn syncPoolLease(
    self: *MachineChooser,
    target: chooser_sessions.Target,
    remote: ?SessionRoster.Remote,
) void {
    var kbuf: [machine_pool.max_key]u8 = undefined;
    const want: ?[]const u8 = if (target == .remote) blk: {
        const r = remote orelse break :blk null;
        break :blk machine_pool.key(&kbuf, .{
            .relay = .{ .base = r.base, .device = r.device },
        });
    } else null;

    if (self.pool_lease) |lease| {
        if (want) |k| {
            if (std.mem.eql(u8, lease.key(), k)) return;
        }
        self.window.app.machine_pool.release(lease);
        self.pool_lease = null;
    }

    const k = want orelse return;
    _ = k;
    const r = remote.?;
    const hwnd = self.window.app.msg_hwnd orelse return;
    self.pool_lease = self.window.app.machine_pool.acquire(
        hwnd,
        .{ .relay = .{ .base = r.base, .device = r.device } },
        r.token,
        self,
        onPoolChange,
    );
}

/// The pool's state feed for the machine this chooser is browsing (T461). Static
/// so it can be a plain function pointer; `ctx` is the chooser, which is safe
/// because a lease is released synchronously in `destroyState` and the pool never
/// calls back into a released one.
fn onPoolChange(
    ctx: *anyopaque,
    conn: ?*remote_connection.Connection,
    failure: MachineConnectionPool.Failure,
) void {
    const self: *MachineChooser = @ptrCast(@alignCast(ctx));
    if (self.roster.onPoolChange(self.window.app, self.id, conn, failure)) {
        self.refreshSessions();
    }
}

/// Repaint the detail pane after the roster changed. The subtitle's count lives
/// there too, so this is one invalidate and not two.
///
/// It also re-applies the action row, because one action is a function OF the
/// roster: "Restore All" appears at two live sessions and goes away again when a
/// Kill drops the machine back to one (T335). The roster arrives asynchronously,
/// so a composition applied only on selection change would be computed before
/// the data it is derived from exists — the button would never appear at all.
fn refreshSessions(self: *MachineChooser) void {
    const l = layout(self.window.scale, self.hint_lines);
    var r = rect(l.detail);
    _ = w32.InvalidateRect(self.hwnd, &r, 1);
    self.applyActionComposition(l);
}

/// The highlighted row, or null when the list is empty.
fn selectedRow(self: *const MachineChooser) ?Row {
    const sel: i32 = @intCast(w32.SendMessageW(self.list, w32.LB_GETCURSEL, 0, 0));
    if (sel < 0 or @as(usize, @intCast(sel)) >= self.row_count) return null;
    return self.rows[@intCast(sel)];
}

/// Repaint the detail pane (the selection moved, or the list was refiltered)
/// and show or hide the detail actions with it — there is nothing to open when
/// no row is selected, and the Local row has no management actions at all.
fn refreshDetail(self: *MachineChooser) void {
    const l = layout(self.window.scale, self.hint_lines);
    var r = rect(l.detail);
    _ = w32.InvalidateRect(self.hwnd, &r, 1);
    // The roster follows the selection (T319). Before the repaint below, so a
    // move to another machine blanks the region in the SAME frame the header
    // changes — a stale roster under a new machine name is the defect.
    self.syncRoster();
    const row = self.selectedRow();
    _ = w32.ShowWindow(
        self.primary_btn,
        if (row == null) w32.SW_HIDE else w32.SW_SHOW,
    );
    self.applyActionComposition(l);
}

/// Show/hide the optional detail actions for the current selection and re-pack
/// the run. Called both when the SELECTION changes and when the ROSTER changes,
/// since the composition depends on both.
fn applyActionComposition(self: *MachineChooser, l: Layout) void {
    // Hidden rather than greyed: Mac omits the menu on rows that have none,
    // and a `…` that opens nothing is worse than no `…` at all. Activity is
    // gated on the same thing Mac gates it on — the row being remote.
    const comp = self.actionComposition();
    _ = w32.ShowWindow(self.restore_all_btn, if (comp.restore_all) w32.SW_SHOW else w32.SW_HIDE);
    _ = w32.ShowWindow(self.activity_btn, if (comp.activity) w32.SW_SHOW else w32.SW_HIDE);
    _ = w32.ShowWindow(self.menu_btn, if (comp.menu) w32.SW_SHOW else w32.SW_HIDE);
    // The row is packed as a run, so dropping a button MOVES the ones after it.
    self.layoutActions(l);
    // Focus must not be left on a control the user can no longer see.
    const focus = w32.GetFocus();
    if ((!comp.menu and focus == @as(?w32.HWND, self.menu_btn)) or
        (!comp.activity and focus == @as(?w32.HWND, self.activity_btn)) or
        (!comp.restore_all and focus == @as(?w32.HWND, self.restore_all_btn)))
    {
        _ = w32.SetFocus(self.list);
    }
}

// ---------------------------------------------------------------------
// Per-row management menu (T176)
// ---------------------------------------------------------------------

/// What menu `row` gets. Every non-local row in the Windows chooser comes from
/// the relay device directory today (there is no direct-TCP machine list yet),
/// so a device row is a relay row.
fn menuState(row: Row) chooser_menu.State {
    return .{
        .kind = switch (row) {
            .local => .local,
            .device => .relay,
        },
        .host_settings = HOST_SETTINGS_AVAILABLE,
    };
}

/// Build and track the management menu for the selected row at a SCREEN point,
/// then run the chosen action. Both entry points (the `…` button and a
/// right-click on a row) land here, so the two can never drift.
fn openRowMenu(self: *MachineChooser, screen_x: i32, screen_y: i32) void {
    const row = self.selectedRow() orelse return;
    const device_index = switch (row) {
        .local => return, // no management actions
        .device => |i| i,
    };

    var buf: [chooser_menu.max_items]chooser_menu.Item = undefined;
    const items = chooser_menu.build(menuState(row), &buf);
    if (items.len == 0) return;

    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);
    for (items) |item| switch (item) {
        .separator => _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null),
        .cmd => |c| _ = w32.AppendMenuW(menu, w32.MF_STRING, @intFromEnum(c.id), c.title.ptr),
    };

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        screen_x,
        screen_y,
        self.hwnd,
        null,
    );
    // 0 = dismissed without choosing.
    const id = std.meta.intToEnum(chooser_menu.Id, @as(usize, @intCast(cmd))) catch return;
    switch (id) {
        .rename => self.promptRename(device_index),
        .remove => self.confirmRemove(device_index),
        .host_settings => self.promptHostSettings(device_index),
    }
}

/// Open the management menu from the `…` button: aligned under its leading
/// edge, the way a menu button's popup should hang.
fn openRowMenuFromButton(self: *MachineChooser) void {
    var r: w32.RECT = undefined;
    if (w32.GetWindowRect(self.menu_btn, &r) == 0) return;
    self.openRowMenu(r.left, r.bottom);
}

/// Edit this machine's per-host defaults (T174): the working directory and
/// shell NEW sessions on it start with. Unlike rename/remove this touches
/// nothing on the relay — the store is local (`host_defaults.zig`), and the
/// key is the DEVICE ID so a later rename does not orphan the settings.
///
/// Available for every remote machine, signed in or not: these are local
/// preferences, not account resources.
fn promptHostSettings(self: *MachineChooser, device_index: usize) void {
    const dev = self.devices[device_index];
    const alloc = self.window.app.core_app.alloc;

    // `dev` borrows the device list's JSON arena, and the modal below pumps
    // messages — a sign-in landing under it re-lists and frees that arena.
    // Copy out everything needed afterwards first (the reloadDevices lesson).
    var id_buf: [host_defaults.MAX_KEY_LEN]u8 = undefined;
    var name_buf: [128]u8 = undefined;
    if (dev.id.len > id_buf.len or dev.name.len > name_buf.len) {
        // Never a silent no-op: the user picked a menu item.
        self.setHint("That machine's name or id is too long to edit here.");
        return;
    }
    const id = id_buf[0..dev.id.len];
    const name = name_buf[0..dev.name.len];
    @memcpy(id, dev.id);
    @memcpy(name, dev.name);
    const key: host_defaults.Key = .{ .relay = id };

    // Seed the fields from the store, then hand it straight back — the dialog
    // pumps messages, so nothing borrowed from the store may outlive this.
    var current: host_defaults.Resolved = .{};
    host_defaults.lookup(alloc, key, &current);

    const window = self.window;
    var wd_buf: [host_defaults.MAX_VALUE_LEN]u8 = undefined;
    var shell_buf: [host_defaults.MAX_VALUE_LEN]u8 = undefined;
    const answer = HostSettingsDialog.prompt(
        window.app,
        self.hwnd,
        window.scale,
        null,
        name,
        .{
            .working_directory = current.workingDirectory(),
            .shell = current.shell(),
        },
        &wd_buf,
        &shell_buf,
    ) orelse return;
    // The dialog ran its own message loop; the chooser may not have survived.
    if (window.machine_chooser != self) return;

    host_defaults.update(alloc, key, .{
        .working_directory = answer.working_directory,
        .shell = answer.shell,
    });
}

/// Prompt for a new name and PATCH it onto the relay account. Errors land in
/// the status strip, never silently.
fn promptRename(self: *MachineChooser, device_index: usize) void {
    const dev = self.devices[device_index];
    if (self.token == null) {
        self.setHint("Not signed in — use Sign in with Google above.");
        return;
    }

    // `dev` borrows the device list's JSON arena, and the modal below pumps
    // messages — a sign-in completing under it re-lists and frees that arena.
    // Everything needed afterwards is copied out first.
    var id_buf: [128]u8 = undefined;
    var old_buf: [128]u8 = undefined;
    if (dev.id.len > id_buf.len or dev.name.len > old_buf.len) {
        // Never a silent no-op: the user pressed a menu item and is owed an
        // answer even in the case we cannot serve.
        self.setHint("That machine's name or id is too long to edit here.");
        return;
    }
    const id = id_buf[0..dev.id.len];
    const old_name = old_buf[0..dev.name.len];
    @memcpy(id, dev.id);
    @memcpy(old_name, dev.name);

    var title_buf: [160]u16 = undefined;
    var seed_buf: [160]u16 = undefined;
    const title = utf16z(&title_buf, "Rename this machine") orelse return;
    const seed = utf16z(&seed_buf, old_name) orelse return;

    // The chooser must survive the nested modal pump; `window` is the handle
    // back to it afterwards.
    const window = self.window;
    var typed_buf: [256]u8 = undefined;
    const typed = ConfirmDialog.prompt(window.app, self.hwnd, window.scale, null, .{
        .title = title.ptr,
        .text = std.unicode.utf8ToUtf16LeStringLiteral("Enter a new name for this device."),
        .icon = .none,
        .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Rename"),
        .input = seed,
    }, &typed_buf) orelse return;
    // The prompt ran its own message loop; the chooser may not have survived it.
    if (window.machine_chooser != self) return;

    const name = chooser_menu.newName(typed, old_name) orelse return;
    const tok = self.token orelse return;
    var parsed = relay_directory.renameDevice(
        self.window.app.core_app.alloc,
        self.relay_base,
        tok,
        id,
        name,
    ) catch |err| {
        log.warn("machine chooser: rename failed device={s} err={}", .{ id, err });
        self.setHint(renameError(err));
        return;
    };
    parsed.deinit();

    // Re-list rather than patching the row in place: the device list is owned
    // by a JSON arena of const strings, and a refetch is also what proves the
    // relay accepted the change.
    self.reloadDevices();
}

/// Confirm, then DELETE the device from the relay account and drop its row.
fn confirmRemove(self: *MachineChooser, device_index: usize) void {
    const dev = self.devices[device_index];
    if (self.token == null) {
        self.setHint("Not signed in — use Sign in with Google above.");
        return;
    }
    // `dev` borrows the device list's JSON arena, which the confirmation's
    // nested pump can free out from under us (a sign-in landing under it
    // re-lists) — copy the id out first.
    var id_buf: [128]u8 = undefined;
    if (dev.id.len > id_buf.len) {
        self.setHint("That machine's id is too long to act on here.");
        return;
    }
    const id = id_buf[0..dev.id.len];
    @memcpy(id, dev.id);

    var title_buf: [256]u16 = undefined;
    const title = utf16z(&title_buf, "Remove this machine from your account?") orelse return;

    const window = self.window;
    const answer = ConfirmDialog.show(window.app, self.hwnd, window.scale, null, .{
        .title = title.ptr,
        .text = std.unicode.utf8ToUtf16LeStringLiteral(
            "This deletes the device from the relay and revokes its credential. " ++
                "The agent on that machine will no longer be able to connect.",
        ),
        .icon = .warning,
        .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Remove"),
        // Destructive: Enter must not approve it (MB_DEFBUTTON2 parity).
        .default_cancel = true,
    });
    if (window.machine_chooser != self) return;
    if (answer != .ok) return;

    const tok = self.token orelse return;
    relay_directory.deleteDevice(
        self.window.app.core_app.alloc,
        self.relay_base,
        tok,
        id,
    ) catch |err| switch (err) {
        // Already gone on the relay: the user's intent is satisfied, so drop
        // the row rather than reporting a failure they cannot act on.
        error.NotFound => {},
        else => {
            log.warn("machine chooser: remove failed device={s} err={}", .{ id, err });
            self.setHint(removeError(err));
            return;
        },
    };

    self.reloadDevices();
}

/// Status-strip text for a failed rename.
fn renameError(err: anyerror) []const u8 {
    return switch (err) {
        error.Unauthorized => "Session expired — sign in again above.",
        error.NotFound => "That machine is no longer on this account.",
        error.BadResponse => "The relay's reply to the rename made no sense.",
        else => "Couldn't rename that machine — is the relay reachable?",
    };
}

/// Status-strip text for a failed removal.
fn removeError(err: anyerror) []const u8 {
    return switch (err) {
        error.Unauthorized => "Session expired — sign in again above.",
        else => "Couldn't remove that machine — is the relay reachable?",
    };
}

/// UTF-8 into a NUL-terminated UTF-16 buffer, or null when it does not fit.
/// Dialog captions are built at runtime, so they cannot be string literals.
fn utf16z(buf: []u16, text: []const u8) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
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
    const row_bg = columnWash(self.pal());
    if (idx < 0 or @as(usize, @intCast(idx)) >= self.row_count) {
        if (wash_brush.get(rgb(row_bg))) |b| _ = w32.FillRect(hdc, &dis.rcItem, b);
        return;
    }

    const m = chooser_rows.rowMetrics(self.window.scale);
    // Three states, three signals (T312). `ODS_FOCUS` is the LIST's keyboard
    // focus landing on its caret row, which is a different question from
    // `ODS_SELECTED` — a row stays selected while the user tabs away, and
    // before T312 the painter could not tell those apart.
    const state: chooser_rows.RowState = .{
        .selected = (dis.itemState & w32.ODS_SELECTED) != 0,
        .focused = (dis.itemState & w32.ODS_FOCUS) != 0,
        .hovered = self.hover_row == idx,
    };

    // Background first: the column wash the row sits on, so the pill
    // composites against what is actually behind it.
    if (wash_brush.get(rgb(row_bg))) |b| _ = w32.FillRect(hdc, &dis.rcItem, b);

    // The user's accent, floored to 3:1 against the row it composites over
    // (T305). It used to be `chooser_rows.accent`, the literal `#3D8EF8`.
    const paint = chooser_rows.rowPaint(
        row_bg,
        chrome_theme.accentOn(row_bg, system_colors.accentCached()),
        state,
    );

    // Everything drawn INSIDE the row is floored against what the row actually
    // paints - the pill when there is one, the column wash otherwise. A
    // selected row is a different surface from an unselected one, and a color
    // measured against the wash was never measured against the pill.
    const surface = paint.fill orelse row_bg;

    const pill: w32.RECT = .{
        .left = r.left + m.fill_inset_x,
        .top = r.top + m.fill_inset_y,
        .right = r.right - m.fill_inset_x,
        .bottom = r.bottom - m.fill_inset_y,
    };

    if (paint.fill) |fill| {
        const brush = w32.CreateSolidBrush(rgb(fill));
        const pen = w32.CreatePen(w32.PS_SOLID, 1, rgb(paint.border orelse fill));
        if (brush != null and pen != null) {
            const old_brush = w32.SelectObject(hdc, brush);
            const old_pen = w32.SelectObject(hdc, pen);
            _ = w32.RoundRect(
                hdc,
                pill.left,
                pill.top,
                pill.right,
                pill.bottom,
                m.fill_radius * 2,
                m.fill_radius * 2,
            );
            _ = w32.SelectObject(hdc, old_brush);
            _ = w32.SelectObject(hdc, old_pen);
        }
        if (brush) |b| _ = w32.DeleteObject(b);
        if (pen) |p| _ = w32.DeleteObject(p);
    }

    // §2.2's focus ring, inside the pill so a focused-and-selected row reads as
    // one control. `NULL_BRUSH` because this is a rim, not a second fill.
    if (paint.ring) |ring| {
        const pen = w32.CreatePen(w32.PS_SOLID, m.focus_ring_w, rgb(ring));
        if (pen) |p| {
            const old_pen = w32.SelectObject(hdc, p);
            const old_brush = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));
            _ = w32.RoundRect(
                hdc,
                pill.left + m.focus_path_inset,
                pill.top + m.focus_path_inset,
                pill.right - m.focus_path_inset,
                pill.bottom - m.focus_path_inset,
                m.focus_ring_radius * 2,
                m.focus_ring_radius * 2,
            );
            _ = w32.SelectObject(hdc, old_pen);
            _ = w32.SelectObject(hdc, old_brush);
            _ = w32.DeleteObject(p);
        }
    }

    const text = self.rowText(self.rows[@intCast(idx)]);
    drawStatusDot(hdc, r, m, text.status, surface);
    drawGlyph(hdc, r, m, text.glyph, surface);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
    const text_right = r.right - m.text_pad_right;

    var title_rect: w32.RECT = .{
        .left = r.left + m.text_x,
        .top = r.top + m.title_y,
        .right = text_right,
        .bottom = r.top + m.title_y + m.title_h,
    };
    _ = w32.SetTextColor(hdc, rgb(chrome_theme.textOn(surface)));
    drawTextUtf8(hdc, text.title, &title_rect);

    if (text.subtitle.len > 0) {
        var sub_rect: w32.RECT = .{
            .left = r.left + m.text_x,
            .top = r.top + m.subtitle_y,
            .right = text_right,
            .bottom = r.top + m.subtitle_y + m.subtitle_h,
        };
        const old = if (self.subtitle_font) |f| w32.SelectObject(hdc, f) else null;
        _ = w32.SetTextColor(hdc, rgb(chooser_rows.secondaryOn(surface)));
        drawTextUtf8(hdc, text.subtitle, &sub_rect);
        if (old) |o| _ = w32.SelectObject(hdc, o);
    }
}

/// One line of ellipsized, vertically centered UTF-8 text.
fn drawTextUtf8(hdc: w32.HDC, text: []const u8, r: *w32.RECT) void {
    drawTextUtf8Aligned(
        hdc,
        text,
        r,
        w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
    );
}

/// `drawTextUtf8` with the caller's own `DT_` flags — the account link is
/// right-aligned against the monogram, where everything else here is left.
fn drawTextUtf8Aligned(hdc: w32.HDC, text: []const u8, r: *w32.RECT, flags: u32) void {
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
    _ = w32.DrawTextW(hdc, &wbuf, @intCast(wlen), r, flags);
}

/// The leading status column: a filled green dot when online, a hollow gray
/// ring when offline, nothing for the Local row (which keeps the column so all
/// rows share one grid). Shape-coded, not just color-coded, like Mac's.
fn drawStatusDot(
    hdc: w32.HDC,
    r: w32.RECT,
    m: chooser_rows.RowMetrics,
    status: chooser_rows.Status,
    surface: chooser_rows.Rgb,
) void {
    if (status == .none) return;
    const half = @divTrunc(m.dot_d, 2);
    const cx = r.left + m.status_cx;
    const cy = r.top + m.status_cy;

    const online = status == .online;
    // Both clamped against the surface they land on (T310): the dot to the 3:1
    // chrome floor so it keeps its green, the ring to the de-emphasized text
    // ramp so it matches the subline beside it.
    const color = if (online)
        chooser_rows.onlineOn(surface)
    else
        chooser_rows.secondaryOn(surface);
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
fn drawGlyph(
    hdc: w32.HDC,
    r: w32.RECT,
    m: chooser_rows.RowMetrics,
    glyph: chooser_rows.Glyph,
    surface: chooser_rows.Rgb,
) void {
    drawGlyphBox(
        hdc,
        r.left + m.glyph_x,
        r.top + m.glyph_y,
        m.glyph_w,
        m.glyph_h,
        glyph,
        chooser_rows.secondaryOn(surface),
    );
}

/// `drawGlyph` at an absolute box, so the detail pane can draw the same
/// silhouette at its own (larger) size. `color` is a parameter because the two
/// callers sit on different surfaces — the rows on the column wash, the detail
/// pane on the dialog background — and a mark's contrast floor is only
/// meaningful against what is actually behind it (T310).
fn drawGlyphBox(
    hdc: w32.HDC,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    glyph: chooser_rows.Glyph,
    color: chooser_rows.Rgb,
) void {
    // A bigger glyph needs a heavier stroke or it reads as a wireframe.
    const pen_w: i32 = if (w >= 24) 2 else 1;
    const pen = w32.CreatePen(w32.PS_SOLID, pen_w, rgb(color)) orelse return;
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
        // T312: the selection WEAKENS when the list stops being the focused
        // control, so a focus change repaints more than the caret row's rim.
        // The listbox does send its own `ODA_FOCUS` draw, but only for the
        // caret item and only as an optimization of the focus rect it thinks
        // it owns; a whole-list invalidate after the default handler has
        // updated its state makes the repaint the definition rather than a
        // behavior we are relying on.
        w32.WM_SETFOCUS, w32.WM_KILLFOCUS => {
            const res = w32.CallWindowProcW(prev, hwnd, msg, wparam, lparam);
            _ = w32.InvalidateRect(hwnd, null, 0);
            return res;
        },
        // Right-click is the second way into the management menu (Mac's
        // `.contextMenu` on the row). Select the row under the cursor first —
        // a menu that acts on a different row than the one you clicked is a
        // bug waiting to happen — then open on the button UP: opening on DOWN
        // leaves the pending release to dismiss the menu immediately.
        w32.WM_RBUTTONDOWN => {
            if (rowAtPoint(hwnd, self, lparam)) |row| {
                _ = w32.SendMessageW(hwnd, w32.LB_SETCURSEL, @intCast(row), 0);
                self.refreshDetail();
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            var pt = w32.POINT{ .x = loWordSigned(lparam), .y = hiWordSigned(lparam) };
            _ = w32.ClientToScreen(hwnd, &pt);
            self.openRowMenu(pt.x, pt.y);
            return 0;
        },
        // Keyboard menu key (VK_APPS / shift+F10): lParam is -1 and there is
        // no click point, so it opens at the selected row.
        w32.WM_CONTEXTMENU => {
            if (lparam == -1) {
                self.openRowMenuAtSelection();
                return 0;
            }
        },
        else => {},
    }
    return w32.CallWindowProcW(prev, hwnd, msg, wparam, lparam);
}

/// Subclassed account-link proc (T315): the one place that can see the pointer
/// LEAVE the link. `WM_SETCURSOR` on the dialog says when the pointer is on the
/// link and when it has moved onto something else inside the dialog, but a
/// pointer that goes from the link straight off the top or trailing edge of the
/// window sends no further `WM_SETCURSOR`, and the underline used to stay lit
/// until it came back. Everything else falls through untouched.
fn linkWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const parent = w32.GetParent(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const userdata = w32.GetWindowLongPtrW(parent, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *MachineChooser = @ptrFromInt(@as(usize, @bitCast(userdata)));
    const prev = self.link_proc orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_MOUSEMOVE => {
            if (!self.link_tracking_leave) {
                var tme: w32.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
                    .dwFlags = w32.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (w32.TrackMouseEvent(&tme) != 0) self.link_tracking_leave = true;
            }
            // The positive control lives here too, so the hover does not depend
            // on `WM_SETCURSOR` having been delivered first.
            self.setLinkHot(true);
        },
        w32.WM_MOUSELEAVE => {
            self.link_tracking_leave = false;
            self.setLinkHot(false);
        },
        else => {},
    }
    return w32.CallWindowProcW(prev, hwnd, msg, wparam, lparam);
}

/// The row index under a listbox client point (`lparam` of a mouse message),
/// or null when the point is past the last row.
fn rowAtPoint(list: w32.HWND, self: *const MachineChooser, lparam: isize) ?i32 {
    const hit = w32.SendMessageW(list, w32.LB_ITEMFROMPOINT, 0, lparam);
    // High word non-zero ⇒ the point is outside the client area.
    if ((@as(usize, @bitCast(hit)) >> 16) & 0xFFFF != 0) return null;
    const row: i32 = @intCast(hit & 0xFFFF);
    if (row < 0 or @as(usize, @intCast(row)) >= self.row_count) return null;
    return row;
}

fn loWordSigned(lparam: isize) i32 {
    return @intCast(@as(i16, @truncate(lparam & 0xFFFF)));
}

fn hiWordSigned(lparam: isize) i32 {
    return @intCast(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
}

/// Open the management menu over the selected row (keyboard path — there is no
/// pointer to anchor it to).
fn openRowMenuAtSelection(self: *MachineChooser) void {
    const sel: i32 = @intCast(w32.SendMessageW(self.list, w32.LB_GETCURSEL, 0, 0));
    if (sel < 0) return;
    var r: w32.RECT = undefined;
    if (w32.SendMessageW(self.list, w32.LB_GETITEMRECT, @intCast(sel), @bitCast(@intFromPtr(&r))) < 0) return;
    var pt = w32.POINT{ .x = r.left, .y = r.bottom };
    _ = w32.ClientToScreen(self.list, &pt);
    self.openRowMenu(pt.x, pt.y);
}

/// Move the hover highlight, repainting only when it actually changed.
fn setHover(self: *MachineChooser, row: i32) void {
    if (self.hover_row == row) return;
    self.hover_row = row;
    _ = w32.InvalidateRect(self.list, null, 0);
}

/// One place that changes the link's hover state and repaints it, so the three
/// callers (enter via `WM_SETCURSOR`, leave via `WM_MOUSELEAVE`, and the link
/// being hidden on sign-out) cannot drift apart.
fn setLinkHot(self: *MachineChooser, hot: bool) void {
    if (self.link_hot == hot) return;
    self.link_hot = hot;
    _ = w32.InvalidateRect(self.account_link, null, 1);
}

fn registerClass(app: *App) ?void {
    if (class_registered) return;
    // Warm the palette memo so the first paint does not resolve on the
    // critical path; the brushes themselves are created on demand, keyed on
    // the color they are made for.
    _ = palFor(app);
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        // The roster's cards are painted on the dialog, so the dialog is what
        // has to be told to deliver double clicks — without CS_DBLCLKS the
        // second click of a resume arrives as another WM_LBUTTONDOWN and the
        // gesture silently does not exist (T320).
        .style = w32.CS_DBLCLKS,
        .lpfnWndProc = &dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = app.hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        // Null, and erased in `WM_ERASEBKGND` from the live palette instead
        // (T308): a class background brush is captured at registration, which
        // happens once per process, so it cannot follow a theme flip.
        .hbrBackground = null,
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
                    ACCOUNT_ID, ACCOUNT_LINK_ID => {
                        self.onAccountClicked();
                        return 0;
                    },
                    MENU_ID => {
                        self.openRowMenuFromButton();
                        return 0;
                    },
                    ACTIVITY_ID => {
                        self.openActivityMonitor();
                        return 0;
                    },
                    RESTORE_ALL_ID => {
                        self.restoreAll();
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
            if (dis.CtlType == w32.ODT_BUTTON and dis.CtlID == ACCOUNT_LINK_ID) {
                self.drawAccountLink(dis);
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // Link hover, without a subclass: WM_SETCURSOR names the window under
        // the pointer, and a child that does not handle it forwards it here —
        // so "over the link" and "left the link" are the same test, and the
        // hand cursor is set at the one place that already knows.
        w32.WM_SETCURSOR => {
            const over: ?w32.HWND = @ptrFromInt(wparam);
            const hot = over == @as(?w32.HWND, self.account_link) and
                w32.IsWindowVisible(self.account_link) != 0;
            self.setLinkHot(hot);
            if (hot) {
                if (w32.LoadCursorW(null, w32.IDC_HAND)) |c| {
                    _ = w32.SetCursor(c);
                    return 1;
                }
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
        // The roster's cards are painted on the dialog itself, not in a child
        // control, so their pointer handling lives here.
        w32.WM_MOUSEMOVE => {
            self.onSessionHover(loWordSigned(lparam), hiWordSigned(lparam));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_LBUTTONDOWN => {
            if (self.onSessionClick(loWordSigned(lparam), hiWordSigned(lparam))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // Single click points the cursor at a row, double click resumes it —
        // Mac's own gesture split (`MachineChooserView.swift:700-701`) and the
        // one every Windows list already teaches.
        w32.WM_LBUTTONDBLCLK => {
            if (self.onSessionDoubleClick(loWordSigned(lparam), hiWordSigned(lparam))) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEWHEEL => {
            if (self.onSessionWheel(@as(i16, @bitCast(@as(u16, @intCast((wparam >> 16) & 0xFFFF)))))) return 0;
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
        // The class carries no background brush (it would be frozen at
        // registration time), so the dialog surface is erased here from the
        // live palette; `paintChrome` draws the column and rules over it.
        w32.WM_ERASEBKGND => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            var er: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &er) == 0) return 0;
            if (bg_brush.get(rgb(self.pal().bg))) |b| _ = w32.FillRect(hdc, &er, b);
            return 1;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            self.paintChrome(hdc);
            _ = w32.EndPaint(hwnd, &ps);
            return 0;
        },
        // A light/dark flip or an accent change reaches TOP-LEVEL windows, and
        // a panel is one (T308). Drop the cached accent and repaint: the
        // palette is derived per paint, so the repaint IS the re-theme.
        //
        // Through the shared helper since T307, which redraws the CHILDREN too
        // — this chooser's filter field and buttons colour themselves from a
        // `WM_CTLCOLOR*` reply, which is only sent when the child repaints.
        w32.WM_SETTINGCHANGE, w32.WM_DWMCOLORIZATIONCOLORCHANGED => {
            if (msg != w32.WM_SETTINGCHANGE or system_colors.isColorSettingChange(lparam)) {
                system_colors.repaintForColorChange(hwnd);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLOREDIT => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            _ = w32.SetTextColor(hdc, rgb(p.text));
            _ = w32.SetBkColor(hdc, rgb(p.field));
            if (field_brush.get(rgb(p.field))) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The list sits ON the column wash, not on a field — its unfilled tail
        // below the last row has to be the same color as the rows themselves.
        w32.WM_CTLCOLORLISTBOX => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            const w = rgb(columnWash(p));
            _ = w32.SetTextColor(hdc, rgb(p.text));
            _ = w32.SetBkColor(hdc, w);
            if (wash_brush.get(w)) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLORBTN => {
            const hdc: w32.HDC = @ptrFromInt(wparam);
            const p = self.pal();
            _ = w32.SetTextColor(hdc, rgb(p.label));
            // The status strip lives inside the master column, so it takes the
            // wash; everything else sits on the dialog surface.
            const on_wash = @as(?w32.HWND, self.hint) == @as(?w32.HWND, @ptrFromInt(@as(usize, @bitCast(lparam))));
            const back = rgb(if (on_wash) columnWash(p) else p.bg);
            _ = w32.SetBkColor(hdc, back);
            const brush = if (on_wash) &wash_brush else &bg_brush;
            if (brush.get(back)) |b| return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(b))));
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// ---------------------------------------------------------------------
// Session roster interaction (T318)
// ---------------------------------------------------------------------

/// The roster's region and its currently visible rows, or null when the
/// selected row has no roster. Every pointer handler starts here so hit
/// testing, hovering and scrolling can never disagree about what is on screen.
fn sessionView(
    self: *MachineChooser,
    rows: []SessionRoster.VisibleRow,
) ?struct { region: chooser_layout.Rect, rows: []const SessionRoster.VisibleRow } {
    // The ROSTER's target decides, not the selected row: the two agree, but a
    // second reading of "does this row have a roster" is a second place for
    // them to stop agreeing. A remote machine's rows are hit-tested, hovered
    // and killed exactly like the local agent's (T319).
    if (self.roster.target == .none) return null;
    const l = layout(self.window.scale, self.hint_lines);
    return .{ .region = l.sessions, .rows = self.roster.visible(self.window.app, rows) };
}

/// Hold the roster's scroll offset inside the content it now has (T333). A
/// no-op when the selected row has no roster, or when the offset already fits.
fn clampRosterScroll(self: *MachineChooser) void {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse return;
    _ = self.roster.clampScrollTo(view.rows, view.region, self.window.scale);
}

fn onSessionHover(self: *MachineChooser, x: i32, y: i32) void {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse {
        self.setKillHover(-1);
        return;
    };
    const hit = self.roster.killAt(view.rows, view.region, self.window.scale, x, y);
    self.setKillHover(if (hit) |i| @intCast(i) else -1);
}

fn setKillHover(self: *MachineChooser, index: i32) void {
    if (self.roster.hover_kill == index) return;
    self.roster.hover_kill = index;
    self.refreshSessions();
}

/// A click in the roster. Returns true when it was consumed. Kill is tested
/// first: its hit box lives INSIDE a card, so one point answers both and the
/// more specific control has to win.
fn onSessionClick(self: *MachineChooser, x: i32, y: i32) bool {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse return false;
    if (self.roster.killAt(view.rows, view.region, self.window.scale, x, y)) |idx| {
        self.confirmKill(view.rows[idx]);
        return true;
    }
    const idx = self.roster.rowAt(view.rows, view.region, self.window.scale, x, y) orelse
        return false;
    // Point the keyboard cursor at the clicked card (Mac's `onTapGesture`), so
    // a click followed by Return resumes the row the user just touched.
    const next: i32 = @intCast(idx);
    if (self.roster.cursor != next) {
        self.roster.cursor = next;
        self.refreshSessions();
    }
    return true;
}

/// A double click in the roster: resume that session. Returns true when
/// consumed. Falls through to the single-click behavior for a card that is not
/// resumable, so the cursor still lands where the user clicked.
fn onSessionDoubleClick(self: *MachineChooser, x: i32, y: i32) bool {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse return false;
    // A double click that landed on Kill is still a Kill (its confirmation runs
    // a nested pump, and the second click already opened it).
    if (self.roster.killAt(view.rows, view.region, self.window.scale, x, y) != null) return true;
    const idx = self.roster.rowAt(view.rows, view.region, self.window.scale, x, y) orelse
        return false;
    self.resumeRow(view.rows[idx]);
    return true;
}

/// Whether Left/Right belong to the roster cursor rather than to the filter's
/// caret. Pure so the rule is testable: the filter owns them whenever it has
/// focus AND has text to move a caret through — an empty field has no caret to
/// move, so navigation is free to take them.
pub fn horizontalIsNav(filter_focused: bool, filter_len: usize) bool {
    return !(filter_focused and filter_len > 0);
}

fn horizontalIsNavigation(self: *const MachineChooser) bool {
    const focused = w32.GetFocus() == @as(?w32.HWND, self.filter);
    var buf: [256]u8 = undefined;
    return horizontalIsNav(focused, self.filterText(&buf).len);
}

/// Right: step the keyboard cursor into the roster, and scroll its first card
/// into view.
fn enterSessions(self: *MachineChooser) void {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse return;
    self.roster.cursor = chooser_sessions.enterCursor(self.roster.cursor, view.rows.len);
    _ = self.roster.scrollToCursor(view.rows, view.region, self.window.scale);
}

/// Up/Down inside the roster. Repaints once for the move and the scroll
/// together — they are one visual change.
fn moveSessionCursor(self: *MachineChooser, delta: i32) void {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse {
        self.roster.cursor = chooser_sessions.no_cursor;
        return;
    };
    self.roster.cursor = chooser_sessions.moveCursor(
        self.roster.cursor,
        delta,
        view.rows.len,
    );
    _ = self.roster.scrollToCursor(view.rows, view.region, self.window.scale);
    self.refreshSessions();
}

/// Resume the row the keyboard cursor is on (Return). No cursor ⇒ not ours.
fn resumeCursor(self: *MachineChooser) bool {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse return false;
    const idx = self.roster.cursorIndex(view.rows) orelse return false;
    self.resumeRow(view.rows[idx]);
    return true;
}

/// Resume ONE browsed session (T320): dismiss the chooser and open a local
/// window whose pane ATTACHes to that session — the local agent's, or a relay
/// machine's over its own transport.
///
/// The chooser produces a target and closes; the attach itself belongs to `App`
/// (Mac keeps the same separation via `WindowTarget.resumeSession`, and
/// `MachineChooser.zig` is large enough without owning an attach path).
///
/// Everything the target borrows is copied to the stack FIRST: `close` frees
/// the arena the device listing and the session strings are parsed into.
fn resumeRow(self: *MachineChooser, row: SessionRoster.VisibleRow) void {
    const target = chooser_sessions.resumeTarget(self.roster.target, row.session);

    // Already open in one of our panes: focus it instead of attaching a second
    // viewer. The agent rebinds a session to the newest ATTACH, so a second
    // attach would quietly take the pane away from the window that has it —
    // and "show me that session" is what the user asked for either way. A
    // deliberate divergence from Mac, which resumes unconditionally (T330).
    if (row.open_locally) {
        if (self.focusOpenSession(row.session.id)) return;
    }

    switch (target) {
        .none => {
            // A tombstone row: listed (its command and cwd are worth seeing)
            // but there is no live child to attach to.
            self.setHint("That session has exited - it can't be resumed.");
        },
        .local => |sid| {
            var id_buf: [128]u8 = undefined;
            if (sid.len == 0 or sid.len > id_buf.len) return;
            const id = id_buf[0..sid.len];
            @memcpy(id, sid);
            // The recorded pane id, so a resumed pane answers to the
            // `$GHOZTTY_PANE_ID` its still-running shell was baked with (T113).
            var pane_buf: [64]u8 = undefined;
            const pane_id: ?[]const u8 = if (self.roster.persistedPaneIdFor(sid)) |p| blk: {
                if (p.len == 0 or p.len > pane_buf.len) break :blk null;
                @memcpy(pane_buf[0..p.len], p);
                break :blk pane_buf[0..p.len];
            } else null;

            const app = self.window.app;
            self.close(true);
            _ = app.resumeLocalSession(id, pane_id) catch |err| {
                log.warn("machine chooser: resume local session failed err={}", .{err});
            };
        },
        .remote => |r| {
            const tok = self.token orelse {
                self.setHint("Not signed in - use Sign in with Google above.");
                return;
            };
            const app = self.window.app;
            // Dial synchronously while the chooser is still alive (relay_base,
            // token and the ids are borrowed from it); close only on success,
            // exactly as `openSelection` does for a new remote window.
            _ = app.resumeRelaySession(self.relay_base, r.device, tok, r.session) catch |err| {
                log.warn("machine chooser: resume relay session failed err={}", .{err});
                self.setHint(switch (err) {
                    error.DialFailed => "Couldn't reach that machine - is its agent running?",
                    else => "Couldn't resume that session.",
                });
                return;
            };
            self.close(false);
        },
    }
}

/// Restore ALL of the selected machine's windows (T335 local, T336 relay):
/// rebuild its whole window/tab/split topology here from the layout blobs THAT
/// machine's agent holds, with every pane ATTACHed to its still-running session.
///
/// The two arms differ only in transport — a local rebuild rides the shared
/// agent connection, a remote one dials the machine (and gives each rebuilt
/// window its own dial) — so the decision, the messaging and the outcomes all
/// live here once.
///
/// Unlike the per-session resume, this one runs BEFORE the chooser closes: the
/// rebuild's failure modes are worth saying out loud, and a dismissed chooser
/// has nowhere to say them. Mac uses a modal alert
/// (`SessionLayoutRestore.swift:755-773`); the footer hint is this dialog's
/// equivalent and does not steal the user's next keystroke.
///
/// The LOCAL arm runs here and now — every RPC in it is a bounded named-pipe
/// round trip to a daemon on this box. The REMOTE arm hands the job to a worker
/// thread (T339) and comes back through `onRestoreAll`: its N+1 relay dials are
/// the ones that would otherwise stop the message loop for as long as the link
/// is slow.
fn restoreAll(self: *MachineChooser) void {
    const row = self.selectedRow() orelse return;
    const app = self.window.app;

    const n = switch (row) {
        .local => app.restoreAllLocalSessions(),
        .device => |i| {
            // A second press while the first one's dials are still open would
            // build the same windows twice — the snapshot guard cannot see a
            // window that does not exist yet.
            if (self.restore_inflight) return;
            const dev = self.devices[i];
            const tok = self.token orelse {
                self.setHint("Not signed in - use Sign in with Google above.");
                return;
            };
            // `relay_base`, the token and the device id are all borrowed from
            // this chooser, which may close while the worker is still dialing;
            // `start` deep-copies them.
            if (!RestoreAllRelay.start(app, self.id, .{
                .base = self.relay_base,
                .device = dev.id,
                .token = tok,
            })) {
                self.setHint("Couldn't start the restore.");
                return;
            }
            self.restore_inflight = true;
            self.setHint("Restoring this machine's windows...");
            return;
        },
    } catch |err| {
        self.restoreAllFailed(err);
        return;
    };
    self.restoreAllFinished(n);
}

/// GUI thread: a cross-machine Restore All came back (T339). The REBUILD happens
/// either way — the user asked for it, and dismissing the chooser in the
/// meantime was never a cancel — so a reply whose chooser is gone still builds
/// its windows and only drops the sentence it had nowhere to say.
pub fn onRestoreAll(app: *App, job: *RestoreAllRelay.Job) void {
    defer job.destroy();

    var owner: ?*MachineChooser = null;
    for (app.windows.items) |win| {
        const chooser = win.machine_chooser orelse continue;
        if (chooser.id != job.chooser_id) continue;
        owner = chooser;
        break;
    }
    if (owner) |c| c.restore_inflight = false;

    if (job.err) |err| {
        if (owner) |c| c.restoreAllFailed(err) else log.warn(
            "machine chooser: restore all failed after its chooser closed err={}",
            .{err},
        );
        return;
    }

    const n = app.adoptRestoreAll(job);
    if (owner) |c| c.restoreAllFinished(n) else log.info(
        "machine chooser: restore all rebuilt {d} window(s) after its chooser closed",
        .{n},
    );
}

/// Turn a failed restore into the one sentence the user can act on.
fn restoreAllFailed(self: *MachineChooser, err: App.RestoreAllError) void {
    log.warn("machine chooser: restore all failed err={}", .{err});
    self.setHint(switch (err) {
        error.NoAgent => "The session agent isn't running - there's nothing to restore from.",
        error.PullFailed => "Couldn't read this machine's saved layouts from the agent.",
        error.DialFailed => "Couldn't reach that machine - is its agent running?",
        error.Unauthorized => "Session expired - sign in again above.",
    });
}

/// A restore that reached the end: dismiss onto the rebuilt windows, or say why
/// there were none.
fn restoreAllFinished(self: *MachineChooser, n: usize) void {
    if (n == 0) {
        // A successful pull that rebuilt nothing is a different fact from a
        // failed one, and the user is owed the difference: their windows are
        // either already here or genuinely not saved.
        self.setHint("Nothing to restore - these sessions are already open, or no layout was saved.");
        return;
    }
    log.info("machine chooser: restore all rebuilt {d} window(s)", .{n});
    // Do NOT refocus the owner: the rebuilt windows are what the user asked to
    // be looking at.
    self.close(false);
}

/// Focus the pane already ATTACHed to `id`, if one of our windows has it.
/// Returns true when the chooser was dismissed onto it.
fn focusOpenSession(self: *MachineChooser, id: []const u8) bool {
    const app = self.window.app;
    for (app.windows.items) |win| {
        for (0..win.tab_count) |t| {
            var it = win.tab_trees[t].iterator();
            while (it.next()) |entry| {
                const s2 = entry.view.surface() orelse continue;
                if (!s2.core_surface_ready) continue;
                const sid = s2.core_surface.remoteSessionId() orelse continue;
                if (!std.mem.eql(u8, sid, id)) continue;
                log.info("machine chooser: session already open, focusing its pane", .{});
                const surface = entry.view;
                // Close WITHOUT refocusing the owner: the pane we are about to
                // raise may live in a different window, and the owner would
                // otherwise take the foreground back off it.
                self.close(false);
                win.selectTabIndex(t);
                win.tab_active_pane[t] = surface;
                if (win.hwnd) |hwnd| {
                    if (w32.IsIconic(hwnd) != 0) _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                    _ = w32.SetForegroundWindow(hwnd);
                }
                if (surface.hwnd()) |h| App.deferSetFocus(h); // T48
                return true;
            }
        }
    }
    return false;
}

fn onSessionWheel(self: *MachineChooser, wheel_delta: i16) bool {
    var buf: [SessionRoster.max_rows]SessionRoster.VisibleRow = undefined;
    const view = self.sessionView(&buf) orelse return false;
    // Three card-heights per notch, the way a list scrolls three lines.
    const m = chooser_sessions.metrics(self.window.scale);
    const step = (m.title_h + m.pad_y * 2) * 3;
    const delta: i32 = if (wheel_delta > 0) -step else step;
    if (self.roster.scrollBy(delta, view.rows, view.region, self.window.scale)) {
        self.refreshSessions();
    }
    return true;
}

/// Confirm, then END a session — the session-scoped equivalent of closing its
/// pane, so it is destructive and Enter must not approve it.
///
/// The row is copied out of the roster first: the confirmation runs a nested
/// message pump, and a reply landing under it replaces the `OwnedSessions` the
/// row's strings borrow.
fn confirmKill(self: *MachineChooser, row: SessionRoster.VisibleRow) void {
    var id_buf: [128]u8 = undefined;
    const id_src = row.session.id;
    if (id_src.len == 0 or id_src.len > id_buf.len) return;
    const id = id_buf[0..id_src.len];
    @memcpy(id, id_src);

    var label_buf: [32]u8 = undefined;
    const name = chooser_sessions.label(
        &label_buf,
        row.session,
        row.live_title,
        row.persisted_title,
    );
    var title_utf8: [256]u8 = undefined;
    const title_text = std.fmt.bufPrint(
        &title_utf8,
        "End session \"{s}\"?",
        .{name},
    ) catch "End this session?";
    var title_buf: [256]u16 = undefined;
    const title = utf16z(&title_buf, title_text) orelse return;

    const window = self.window;
    const answer = ConfirmDialog.show(window.app, self.hwnd, window.scale, null, .{
        .title = title.ptr,
        .text = std.unicode.utf8ToUtf16LeStringLiteral(
            "This ends the session - the same as closing its pane. " ++
                "Any unsaved work in it is lost.",
        ),
        .icon = .warning,
        .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("End Session"),
        // Destructive: Enter must not approve it.
        .default_cancel = true,
    });
    // The nested pump may have closed this chooser out from under us.
    if (window.machine_chooser != self) return;
    if (answer != .ok) return;

    // Hide the row NOW: the close has an undo window during which the agent
    // still lists the session, and a row that lingers there degrades to a
    // "pid" label as its pane goes away — which reads as a failed Kill.
    log.info("chooser roster: ending session id={s}", .{id});
    self.roster.markKilled(id);
    self.roster.hover_kill = -1;
    self.refreshSessions();
    self.roster.fetch(window.app, self.id, id);
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
        hwnd == self.account_status or hwnd == self.account_btn or
        hwnd == self.account_link or hwnd == self.restore_all_btn or
        hwnd == self.activity_btn or hwnd == self.menu_btn;
}

/// Keyboard focus targets, in Tab order — the same left-to-right order the
/// action row is painted in, so Tab walks the row the way the eye does.
/// `restore_all` (T335), `activity` (T177) and `menu` (T176) follow the primary
/// action they sit beside; `account` is the sign-in/out button (T141), last in
/// the cycle so Tab from the filter still reaches the list first, the common
/// path.
pub const Focusable = enum { filter, list, primary, restore_all, activity, menu, cancel, account };

/// Pure Tab-order cycle. Unit-tested.
pub fn nextFocus(cur: Focusable, backwards: bool) Focusable {
    return if (backwards) switch (cur) {
        .filter => .account,
        .list => .filter,
        .primary => .list,
        .restore_all => .primary,
        .activity => .restore_all,
        .menu => .activity,
        .cancel => .menu,
        .account => .cancel,
    } else switch (cur) {
        .filter => .list,
        .list => .primary,
        .primary => .restore_all,
        .restore_all => .activity,
        .activity => .menu,
        .menu => .cancel,
        .cancel => .account,
        .account => .filter,
    };
}

/// The control behind a focus stop.
fn hwndFor(self: *const MachineChooser, f: Focusable) w32.HWND {
    return switch (f) {
        .filter => self.filter,
        .list => self.list,
        .primary => self.primary_btn,
        .restore_all => self.restore_all_btn,
        .activity => self.activity_btn,
        .menu => self.menu_btn,
        .cancel => self.cancel_btn,
        // Whichever of the two account controls is live in this state (T311) —
        // the Tab walk already steps over anything hidden, and this keeps the
        // stop pointing at the one the user can actually press.
        .account => self.accountControl(),
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
        // Ctrl+W — the Windows spelling of Mac's Cmd-W ("Close"), and its
        // Ctrl+Shift+W sibling. Over a dialog, "close" means CLOSE THE DIALOG,
        // so both route to the one teardown path the close button and Escape
        // already use (upstream `11fe14bc3`, T603).
        //
        // On Mac that fix was load-bearing: the menu item sends its action to
        // the first responder, and with nothing in the panel's chain answering
        // it, AppKit walked on into the MAIN window and closed a pane behind
        // the dialog. Win32 cannot reach that state — the chord arrives as a
        // WM_KEYDOWN at whichever chooser control has the keyboard, the owner
        // window is DISABLED while the chooser is up, and only a Surface's own
        // WndProc turns a key into a binding — so this is the second half of
        // the parity: the chord now DOES something here rather than nothing.
        // The regression arm asserts both halves (`chooser-close-chord.ps1`).
        //
        // Alt is required to be UP: AltGr reports as ctrl+alt, so an AltGr+W
        // that types a character on someone's layout must still reach the
        // filter EDIT. Shift is not consulted — ctrl+shift+w is the same verb.
        'W' => {
            if (w32.GetKeyState(@as(i32, w32.VK_CONTROL)) >= 0) return false;
            if (w32.GetKeyState(@as(i32, w32.VK_MENU)) < 0) return false;
            self.cancel();
            return true;
        },
        w32.VK_RETURN => {
            // Enter on a non-default button presses IT, not the default Open
            // button — this loop intercepts Enter before the control sees it.
            const focus = w32.GetFocus();
            if (focus == @as(?w32.HWND, self.account_btn) or
                focus == @as(?w32.HWND, self.account_link))
            {
                self.onAccountClicked();
            } else if (focus == @as(?w32.HWND, self.menu_btn)) {
                self.openRowMenuFromButton();
            } else if (focus == @as(?w32.HWND, self.activity_btn)) {
                self.openActivityMonitor();
            } else if (focus == @as(?w32.HWND, self.restore_all_btn)) {
                self.restoreAll();
            } else if (self.roster.cursor != chooser_sessions.no_cursor and self.resumeCursor()) {
                // The session sub-cursor is in the roster: Return resumes THAT
                // row, not the machine's primary action (Mac's `submit`,
                // `MachineChooserView.swift:1373-1381`).
            } else {
                self.openSelection();
            }
            return true;
        },
        // Right steps INTO the detail pane's session list and Left steps back
        // out (Mac binds both, `:315-318`). They are consumed only when the
        // filter cannot use them: Left/Right in a field with text are caret
        // keys, and taking those would make the filter uneditable.
        w32.VK_RIGHT, w32.VK_LEFT => {
            if (!self.horizontalIsNavigation()) return false;
            const before = self.roster.cursor;
            if (vk == w32.VK_RIGHT) {
                self.enterSessions();
            } else {
                self.roster.cursor = chooser_sessions.no_cursor;
            }
            if (self.roster.cursor != before) self.refreshSessions();
            return true;
        },
        w32.VK_UP, w32.VK_DOWN => {
            // With the cursor inside the roster, Up/Down walk the sessions;
            // stepping above the first row hands navigation back to the
            // machine list (Mac's `move`, `:1309-1322`).
            if (self.roster.cursor != chooser_sessions.no_cursor) {
                self.moveSessionCursor(if (vk == w32.VK_UP) -1 else 1);
                return true;
            }
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
            var cur: Focusable = if (focus == @as(?w32.HWND, self.list))
                .list
            else if (focus == @as(?w32.HWND, self.primary_btn))
                .primary
            else if (focus == @as(?w32.HWND, self.restore_all_btn))
                .restore_all
                // Activity was missing from this ladder until T335: focus on it
                // read as `.filter`, so Tab from Activity jumped back to the
                // list instead of stepping on to the `…` menu beside it.
            else if (focus == @as(?w32.HWND, self.activity_btn))
                .activity
            else if (focus == @as(?w32.HWND, self.menu_btn))
                .menu
            else if (focus == @as(?w32.HWND, self.cancel_btn))
                .cancel
            else if (focus == @as(?w32.HWND, self.account_btn) or
                focus == @as(?w32.HWND, self.account_link))
                .account
            else
                .filter;

            // The detail actions come and go with the selection, so Tab has to
            // step OVER a hidden one instead of parking focus on an invisible
            // control. Bounded by the cycle length; something is always shown.
            var next = nextFocus(cur, backwards);
            for (0..@typeInfo(Focusable).@"enum".fields.len) |_| {
                if (w32.IsWindowVisible(self.hwndFor(next)) != 0) break;
                cur = next;
                next = nextFocus(cur, backwards);
            }
            _ = w32.SetFocus(self.hwndFor(next));
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

/// Open the Activity Monitor for the selected machine (T177), Mac's
/// `onActivityMonitor(machine)` — which dismisses the chooser first and then
/// opens the panel (`MachineChooserView.swift:1488-1492`: `finish(nil)` then
/// `RemoteActivityMonitor.presentDialing`). Dismissing first is not cosmetic
/// here: the chooser DISABLES its owner window while it is up, and a panel
/// opened over a disabled owner would come up behind a dead window.
///
/// The identity is copied out before the close — `close` frees the arena the
/// device list is parsed into, and the panel keys its registry on the id.
fn openActivityMonitor(self: *MachineChooser) void {
    const row = self.selectedRow() orelse return;
    const device_index = switch (row) {
        .local => return, // Mac shows no Activity button on the local row
        .device => |i| i,
    };
    const dev = self.devices[device_index];

    var id_buf: [ActivityMonitor.max_source_id]u8 = undefined;
    var name_buf: [ActivityMonitor.max_source_label]u8 = undefined;
    if (dev.id.len > id_buf.len or dev.name.len > name_buf.len) {
        log.warn("machine chooser: activity monitor id/name too long device={s}", .{dev.id});
        self.setHint("Couldn't open Activity for that machine.");
        return;
    }
    @memcpy(id_buf[0..dev.id.len], dev.id);
    @memcpy(name_buf[0..dev.name.len], dev.name);
    const id = id_buf[0..dev.id.len];
    const name = name_buf[0..dev.name.len];

    const window = self.window;
    self.close(true);
    ActivityMonitor.open(window, .{ .remote = .{ .id = id, .name = name } });
}

/// Dismiss without opening anything (returns focus to the owner window).
pub fn cancel(self: *MachineChooser) void {
    self.close(true);
}

/// Free state that was allocated before the HWND existed (early-return paths
/// in `open`). Does NOT touch `machine_chooser` or the owner (never set yet).
fn destroyState(self: *MachineChooser) void {
    self.releaseOwned();
    if (self.parsed) |*p| p.deinit();
    self.arena.deinit();
    self.window.app.core_app.alloc.destroy(self);
}

/// Everything this chooser holds that lives OUTSIDE its own allocation. Called
/// from both teardown paths — `destroyState` (the early returns in `open`) and
/// `close` (every real dismissal) — because the two used to diverge and that is
/// exactly how the pool lease outlived its chooser: the lease holds `self` as its
/// callback context, so a lease left behind is a call into freed memory the next
/// time anything about that machine changes (measured: the SECOND chooser's dial
/// notified the first chooser's ghost and the app died).
///
/// An in-flight roster fetch is not in here: it holds no pointer to us, only the
/// chooser id, so its reply finds no chooser and frees itself. An RPC still
/// riding the pooled connection is fine too — its borrow holds the transport
/// alive on its own, which is what refcounting the entry buys.
fn releaseOwned(self: *MachineChooser) void {
    if (self.pool_lease) |lease| {
        self.window.app.machine_pool.release(lease);
        self.pool_lease = null;
    }
    self.roster.deinit();
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

    // Put the link's own proc back before the dialog's userdata goes, else the
    // subclass loses its way to `self` and would answer the teardown's button
    // messages with `DefWindowProcW` instead of the BUTTON class.
    if (self.link_proc) |prev| {
        _ = w32.SetWindowLongPtrW(self.account_link, w32.GWLP_WNDPROC, @bitCast(@intFromPtr(prev)));
        self.link_proc = null;
    }
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
    if (self.link_font) |f| {
        _ = w32.DeleteObject(f);
        self.link_font = null;
    }
    if (self.strong_font) |f| {
        _ = w32.DeleteObject(f);
        self.strong_font = null;
    }

    if (refocus_owner) {
        if (window.hwnd) |owner| _ = w32.SetForegroundWindow(owner);
        if (window.getActiveSurface()) |s| {
            if (s.hwnd) |h| App.deferSetFocus(h); // T48
        }
    }

    self.releaseOwned();
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

test "nextFocus: forward cycle filter -> list -> primary -> restore_all -> activity -> menu -> cancel -> account -> filter" {
    try testing.expectEqual(Focusable.list, nextFocus(.filter, false));
    try testing.expectEqual(Focusable.primary, nextFocus(.list, false));
    try testing.expectEqual(Focusable.restore_all, nextFocus(.primary, false));
    try testing.expectEqual(Focusable.activity, nextFocus(.restore_all, false));
    try testing.expectEqual(Focusable.menu, nextFocus(.activity, false));
    try testing.expectEqual(Focusable.cancel, nextFocus(.menu, false));
    try testing.expectEqual(Focusable.account, nextFocus(.cancel, false));
    try testing.expectEqual(Focusable.filter, nextFocus(.account, false));
}

test "nextFocus: backward cycle reverses" {
    try testing.expectEqual(Focusable.account, nextFocus(.filter, true));
    try testing.expectEqual(Focusable.cancel, nextFocus(.account, true));
    try testing.expectEqual(Focusable.menu, nextFocus(.cancel, true));
    try testing.expectEqual(Focusable.activity, nextFocus(.menu, true));
    try testing.expectEqual(Focusable.restore_all, nextFocus(.activity, true));
    try testing.expectEqual(Focusable.primary, nextFocus(.restore_all, true));
    try testing.expectEqual(Focusable.list, nextFocus(.primary, true));
    try testing.expectEqual(Focusable.filter, nextFocus(.list, true));
}

test "the Tab order is the paint order of the action run" {
    // Restore All, Activity and the `…` all act on the machine the primary
    // button opens, so they follow it directly rather than turning up after
    // Cancel — and in the order they are painted in (T177, T335). The forward
    // and backward walks are each other's inverse across the whole run.
    const run = [_]Focusable{ .primary, .restore_all, .activity, .menu };
    for (run[0 .. run.len - 1], run[1..]) |a, b| {
        try testing.expectEqual(b, nextFocus(a, false));
        try testing.expectEqual(a, nextFocus(b, true));
    }
}

test "compositionFor: Activity and the menu appear together, on remote rows only" {
    // Mac gates both on the same `if case .remote(let machine)`
    // (MachineChooserView.swift:474-491).
    const local = compositionFor(.local, 0);
    try testing.expect(!local.activity);
    try testing.expect(!local.menu);

    const device = compositionFor(.{ .device = 0 }, 0);
    try testing.expect(device.activity);
    try testing.expect(device.menu);

    // Nothing selected (the filter matched nothing): no actions at all.
    const none = compositionFor(null, 9);
    try testing.expect(!none.activity);
    try testing.expect(!none.menu);
    try testing.expect(!none.restore_all);
}

test "compositionFor: Restore All needs two live sessions, on ANY machine" {
    // The rule (>= 2 alive) is Mac's, and since T336 it is the WHOLE rule: the
    // count decides, not which machine the count came from.
    try testing.expect(!compositionFor(.local, 0).restore_all);
    try testing.expect(!compositionFor(.local, 1).restore_all);
    try testing.expect(compositionFor(.local, 2).restore_all);
    try testing.expect(compositionFor(.local, 7).restore_all);

    // A remote machine takes the identical ladder — the T336 regression, since
    // the pre-T336 rule answered false for every one of these.
    try testing.expect(!compositionFor(.{ .device = 0 }, 0).restore_all);
    try testing.expect(!compositionFor(.{ .device = 0 }, 1).restore_all);
    try testing.expect(compositionFor(.{ .device = 0 }, 2).restore_all);
    try testing.expect(compositionFor(.{ .device = 0 }, 5).restore_all);
}

test "the action row's own packing puts Activity between New Window and the menu" {
    const l = layout(1.0, 1);
    const row = chooser_layout.actionRow(l, compositionFor(.{ .device = 0 }, 0), .{
        .primary = 70,
        .activity = 44,
    });
    try testing.expectEqual(@as(usize, 3), row.len);
    try testing.expect(row.rect(.primary).?.right <= row.rect(.activity).?.left);
    try testing.expect(row.rect(.activity).?.right <= row.rect(.menu).?.left);
}

test "the action row packs Restore All between New Window and Activity" {
    // The whole row at once — the case the packer was named for (T177) and
    // could not be exercised until a caller could set the flag.
    const l = layout(1.0, 1);
    const comp: chooser_layout.Composition = .{ .restore_all = true, .activity = true, .menu = true };
    const row = chooser_layout.actionRow(l, comp, .{
        .primary = 70,
        .restore_all = 66,
        .activity = 44,
    });
    try testing.expectEqual(@as(usize, 4), row.len);
    try testing.expect(row.rect(.primary).?.right <= row.rect(.restore_all).?.left);
    try testing.expect(row.rect(.restore_all).?.right <= row.rect(.activity).?.left);
    try testing.expect(row.rect(.activity).?.right <= row.rect(.menu).?.left);

    // Dropping it closes the gap rather than leaving a hole — the reason the
    // row is packed as a RUN and re-packed on every selection change.
    const without = chooser_layout.actionRow(l, .{ .activity = true, .menu = true }, .{
        .primary = 70,
        .restore_all = 66,
        .activity = 44,
    });
    try testing.expectEqual(@as(usize, 3), without.len);
    try testing.expectEqual(row.rect(.restore_all).?.left, without.rect(.activity).?.left);
}

test "menuState: the Local row has no menu, a device row gets the relay menu" {
    try testing.expectEqual(chooser_menu.Kind.local, menuState(.local).kind);
    try testing.expectEqual(chooser_menu.Kind.relay, menuState(.{ .device = 3 }).kind);
    try testing.expect(!chooser_menu.hasMenu(menuState(.local)));
    // Every non-local row in the Windows chooser comes from the relay
    // directory, so a device row must be manageable.
    try testing.expect(chooser_menu.hasMenu(menuState(.{ .device = 0 })));
}

test "T174 landed the store, so Host Settings is now built into the menu" {
    try testing.expect(HOST_SETTINGS_AVAILABLE);
    var buf: [chooser_menu.max_items]chooser_menu.Item = undefined;
    const items = chooser_menu.build(
        .{ .kind = .relay, .host_settings = HOST_SETTINGS_AVAILABLE },
        &buf,
    );
    // Mac's order: Host Settings… leads, the account actions follow.
    try testing.expectEqual(chooser_menu.Id.host_settings, items[0].cmd.id);
    var found = false;
    for (items) |item| switch (item) {
        .separator => {},
        .cmd => |c| if (c.id == .host_settings) {
            found = true;
        },
    };
    try testing.expect(found);
}

test "host-settings key is the device id, so a rename cannot orphan it" {
    // The chooser keys the store on `dev.id`, never on the display name —
    // renaming a machine must not lose its defaults.
    var buf: [host_defaults.MAX_KEY_LEN]u8 = undefined;
    try testing.expectEqualStrings(
        "dev-abc",
        host_defaults.formatKey(&buf, .{ .relay = "dev-abc" }).?,
    );
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

test "rowForDeviceId: finds a device's display row past the Local row" {
    const devs = [_]relay_directory.Device{
        testDevice("Winbox", null, true),
        testDevice("Laptop", null, false),
    };
    const rows = [_]Row{ .local, .{ .device = 0 }, .{ .device = 1 } };
    try testing.expectEqual(@as(?usize, 1), rowForDeviceId(&rows, &devs, "Winbox"));
    try testing.expectEqual(@as(?usize, 2), rowForDeviceId(&rows, &devs, "Laptop"));
}

test "rowForDeviceId: a filtered-out or removed device has no row" {
    const devs = [_]relay_directory.Device{testDevice("Winbox", null, true)};
    // Only the Local row survived the filter.
    const only_local = [_]Row{.local};
    try testing.expect(rowForDeviceId(&only_local, &devs, "Winbox") == null);
    // And an id that is not on the account at all.
    const rows = [_]Row{ .local, .{ .device = 0 } };
    try testing.expect(rowForDeviceId(&rows, &devs, "gone") == null);
    try testing.expect(rowForDeviceId(&rows, &devs, "") == null);
}

test "rowForDeviceId: indices are re-resolved, not assumed stable" {
    // A refetch can reorder the list; the anchor must follow the ID, not the
    // old position (this is the whole point of re-anchoring by id).
    const before = [_]relay_directory.Device{
        testDevice("A", null, true),
        testDevice("B", null, true),
    };
    const after = [_]relay_directory.Device{
        testDevice("B", null, true),
        testDevice("A", null, true),
    };
    const rows = [_]Row{ .local, .{ .device = 0 }, .{ .device = 1 } };
    try testing.expectEqual(@as(?usize, 1), rowForDeviceId(&rows, &before, "A"));
    try testing.expectEqual(@as(?usize, 2), rowForDeviceId(&rows, &after, "A"));
}

test "rowForDeviceId: a stale row index never reads past the device list" {
    const devs = [_]relay_directory.Device{testDevice("A", null, true)};
    const rows = [_]Row{ .local, .{ .device = 7 } };
    try testing.expect(rowForDeviceId(&rows, &devs, "A") == null);
}

// `containsIgnoreCase`'s own tests moved to `text_search.zig` with the
// function (T288), where they also run in the `none` lane.

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
