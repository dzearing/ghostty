//! Windows system-tray UI for the `ghoztty-agent` listen daemon.
//!
//! When the agent runs in TCP listen-daemon or relay mode on Windows (the
//! default — the deploy watcher launches it as `ghoztty-agent --listen ...`), it
//! shows a tray icon so the human running the Windows box has a visible,
//! dismissable handle on the daemon: confirm it's alive, see the live session
//! count, and Quit it cleanly. `--headless` suppresses this (CI / ssh-piped /
//! stdio paths), keeping the previous behavior exactly.
//!
//! In RELAY mode the caller also passes a `link_control.LinkControl`: the menu
//! then carries a live status line plus a Disconnect/Reconnect item (one item
//! that retitles by state), and the tooltip tracks the link ("connected to
//! <host>" / "reconnecting…" / "disconnected (by user)", refreshed on every
//! tray callback via NIM_MODIFY). `LinkControl`'s methods are thread-safe by
//! contract, so the message-pump thread calls them directly; the control loop
//! reacts promptly (close-the-live-WebSocket + wake-event, see link_control.zig).
//! `--listen` mode passes null and gets the previous menu exactly.
//!
//! ## Threading contract (mirrors `main.zig`'s wiring)
//! Win32 message loops MUST run on the thread that created the window, so the
//! CALLER (`runListen`) runs the TCP `acceptLoop` on a separate thread and calls
//! `tray.run` on the MAIN thread. `run` creates a hidden message-only host window
//! + a `Shell_NotifyIcon` tray icon, then blocks in `GetMessageW` until the user
//! picks "Exit" (which removes the icon and `PostQuitMessage`s). On return the
//! caller exits the process.
//!
//! ## Platform gating
//! ALL Win32 guts are gated under `builtin.os.tag == .windows`. On any other OS
//! (notably the macOS host that runs `zig build test-agent`) the public `run` is a
//! no-op stub so this module compiles and links cleanly everywhere.
//!
//! ## Session snapshotting
//! The menu lists live sessions. We snapshot them FRESH each time the menu opens,
//! copying the few fields we render (pid + a label) into owned/stack memory UNDER
//! `store.mutex`, then release the lock before touching any UI (the locking
//! discipline from `session.zig`: never hold the store lock across a UI call).
//!
//! ## Win32 extern style
//! Mirrors the rest of the agent (`metrics.zig`, `proc_control.zig`): a private
//! `const windows = struct { ... }` block of `extern "user32"/"shell32"` fns with
//! `callconv(.winapi)`, reusing `std.os.windows` types where they exist.

const std = @import("std");
const builtin = @import("builtin");
const session = @import("session.zig");
const link_control = @import("link_control.zig");
const tray_account = @import("tray_account.zig");

/// Show the agent tray icon and run the Win32 message loop until the user picks
/// Exit. BLOCKS the calling thread (must be the main thread — see the module doc).
///
/// On non-Windows targets this is a no-op (returns `false` immediately) so the
/// caller can fall through to running the accept loop directly.
///
/// Returns `true` ONLY if the tray actually showed and the message loop ran to a
/// user-chosen Exit. Returns `false` if any tray setup step failed — the caller
/// MUST NOT exit the process on `false` (the daemon keeps serving headless).
///
/// `store` is the daemon-scoped session store (snapshotted under its lock when the
/// menu opens). `build_hash` is a short build identifier shown in the About line.
/// `link` is the relay-link control (relay mode only; pass null in `--listen` TCP
/// mode, where there is no relay link): non-null adds a status line plus a
/// Disconnect/Reconnect item to the menu and a live-status tooltip. Its methods
/// are thread-safe, so the message-pump thread may call them directly.
/// `account` is the sign in/out controller (relay mode only; null in `--listen`):
/// non-null adds the "Signed in as <email>" line and the Sign in/out item. Its
/// `view`/`request*` methods are thread-safe (workers run off the pump thread).
pub fn run(
    store: *session.SessionStore,
    build_hash: []const u8,
    link: ?*link_control.LinkControl,
    account: ?*tray_account.TrayAccount,
) bool {
    if (builtin.os.tag != .windows) return false;
    return win.run(store, build_hash, link, account);
}

/// One-shot PRE-TRAY error surface: a plain error message box on Windows,
/// a no-op elsewhere. For daemon-startup failures that happen before the tray
/// icon exists (first-run enrollment, see `main.zig`'s `autoEnrollForRelay`) —
/// there is no tooltip to carry the status yet, and the GUI-subsystem exe
/// launched from the Start Menu / Run key has no console for stderr. Blocks
/// until dismissed; callers exit right after, so nothing else is stalled.
pub fn showStartupError(text: []const u8) void {
    if (builtin.os.tag != .windows) return;
    win.showStartupError(text);
}

// =============================================================================
// Windows implementation (compiled only on Windows)
// =============================================================================

const win = if (builtin.os.tag == .windows) struct {
    const W = std.os.windows;
    const HWND = W.HWND;
    const HINSTANCE = W.HINSTANCE;
    const HICON = W.HANDLE;
    const HMENU = W.HANDLE;
    const HBRUSH = W.HANDLE;
    const HCURSOR = W.HANDLE;
    const UINT = W.UINT;
    const WPARAM = W.WPARAM;
    const LPARAM = W.LPARAM;
    const LRESULT = W.LRESULT;
    const DWORD = W.DWORD;
    const BOOL = W.BOOL;
    const ATOM = W.ATOM;
    const WCHAR = W.WCHAR;

    // --- Window-class / message constants -----------------------------------
    const WS_OVERLAPPED: DWORD = 0x00000000;
    const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
    const WM_DESTROY: UINT = 0x0002;
    const WM_COMMAND: UINT = 0x0111;
    const WM_MOUSEMOVE: UINT = 0x0200;
    const WM_LBUTTONUP: UINT = 0x0202;
    const WM_RBUTTONUP: UINT = 0x0205;
    const WM_APP: UINT = 0x8000;

    /// Our private tray-callback message (Shell_NotifyIcon posts mouse events as
    /// this; the low word of `lParam` is the mouse message).
    const WM_TRAY: UINT = WM_APP + 1;

    // Menu command ids.
    const ID_ABOUT: UINT = 1001;
    const ID_UPDATE: UINT = 1002;
    const ID_EXIT: UINT = 1003;
    const ID_DISCONNECT: UINT = 1004;
    const ID_RECONNECT: UINT = 1005;
    const ID_SIGNOUT: UINT = 1006;
    const ID_SIGNIN: UINT = 1007;

    // AppendMenuW flags.
    const MF_STRING: UINT = 0x0000;
    const MF_GRAYED: UINT = 0x0001;
    const MF_DISABLED: UINT = 0x0002;
    const MF_POPUP: UINT = 0x0010;
    const MF_SEPARATOR: UINT = 0x0800;

    // TrackPopupMenu flags.
    const TPM_RIGHTBUTTON: UINT = 0x0002;
    const TPM_BOTTOMALIGN: UINT = 0x0020;

    // LoadIconW well-known icon (IDI_APPLICATION) — last-resort fallback only.
    const IDI_APPLICATION: usize = 32512;

    // Our embedded icon's resource id (see dist/windows/ghoztty-agent.rc). As a
    // MAKEINTRESOURCE value it is just the integer id.
    const ICON_RES_ID: usize = 1;

    // LoadImageW image type + load flags.
    const IMAGE_ICON: UINT = 1;
    const LR_DEFAULTCOLOR: UINT = 0x0000;

    // GetSystemMetrics indices for the small-icon dimensions (tray size).
    const SM_CXSMICON: i32 = 49;
    const SM_CYSMICON: i32 = 50;

    // MessageBoxW flags.
    const MB_OK: UINT = 0x0000;
    const MB_ICONERROR: UINT = 0x0010;
    const MB_ICONINFORMATION: UINT = 0x0040;

    // Shell_NotifyIcon messages + flags.
    const NIM_ADD: DWORD = 0x0000;
    const NIM_MODIFY: DWORD = 0x0001;
    const NIM_DELETE: DWORD = 0x0002;
    const NIF_MESSAGE: UINT = 0x0001;
    const NIF_ICON: UINT = 0x0002;
    const NIF_TIP: UINT = 0x0004;

    const POINT = extern struct { x: i32, y: i32 };

    const WNDCLASSEXW = extern struct {
        cbSize: UINT,
        style: UINT,
        lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
        cbClsExtra: i32 = 0,
        cbWndExtra: i32 = 0,
        hInstance: ?HINSTANCE,
        hIcon: ?HICON = null,
        hCursor: ?HCURSOR = null,
        hbrBackground: ?HBRUSH = null,
        lpszMenuName: ?[*:0]const u16 = null,
        lpszClassName: [*:0]const u16,
        hIconSm: ?HICON = null,
    };

    const MSG = extern struct {
        hwnd: ?HWND,
        message: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
        time: DWORD,
        pt: POINT,
    };

    /// NOTIFYICONDATAW. We only use the first handful of fields; the szTip /
    /// version/state tail pads it to the struct size Shell_NotifyIconW expects.
    const NOTIFYICONDATAW = extern struct {
        cbSize: DWORD,
        hWnd: ?HWND,
        uID: UINT,
        uFlags: UINT,
        uCallbackMessage: UINT,
        hIcon: ?HICON,
        szTip: [128]u16 = [_]u16{0} ** 128,
        dwState: DWORD = 0,
        dwStateMask: DWORD = 0,
        szInfo: [256]u16 = [_]u16{0} ** 256,
        uVersionOrTimeout: UINT = 0,
        szInfoTitle: [64]u16 = [_]u16{0} ** 64,
        dwInfoFlags: DWORD = 0,
        guidItem: W.GUID = std.mem.zeroes(W.GUID),
        hBalloonIcon: ?HICON = null,
    };

    // --- externs ------------------------------------------------------------
    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;

    extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
    extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: [*:0]const u16,
        lpWindowName: ?[*:0]const u16,
        dwStyle: DWORD,
        x: i32,
        y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: ?HWND,
        hMenu: ?HMENU,
        hInstance: ?HINSTANCE,
        lpParam: ?*anyopaque,
    ) callconv(.winapi) ?HWND;
    extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
    extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
    extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;
    extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: usize) callconv(.winapi) ?HICON;
    extern "user32" fn LoadImageW(hInst: ?HINSTANCE, name: usize, imageType: UINT, cx: i32, cy: i32, fuLoad: UINT) callconv(.winapi) ?HICON;
    extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;
    extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
    extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
    extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
    extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const anyopaque) callconv(.winapi) BOOL;
    extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
    extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn PostMessageW(hWnd: ?HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
    extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: UINT) callconv(.winapi) i32;

    extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

    // --- module-local state -------------------------------------------------
    // The wndproc receives only HWND + message params, so the store pointer and
    // build hash are stashed here. The tray is a singleton (one daemon = one
    // tray) so a file-scoped global is fine and avoids GWLP_USERDATA dancing.
    var g_store: ?*session.SessionStore = null;
    var g_build_hash: []const u8 = "dev";
    /// Relay-link control, or null in `--listen` mode (no relay link → no
    /// Disconnect/Reconnect UI). Thread-safe by contract; the message-pump
    /// thread calls disconnect/reconnect/display on it directly.
    var g_link: ?*link_control.LinkControl = null;
    /// Sign in/out controller, or null in `--listen` mode (no account section).
    /// Thread-safe: the message-pump thread reads `view` and calls `request*`
    /// (which spawn workers), never blocking on network/browser work.
    var g_account: ?*tray_account.TrayAccount = null;
    var g_nid: NOTIFYICONDATAW = undefined; // retained so Exit can NIM_DELETE it.

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyAgentTrayWnd");
    const tray_tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty Agent");

    /// Driver: register the class + hidden host window, add the tray icon, run the
    /// message loop until Exit. Any setup failure here is fatal-to-the-tray-only:
    /// we return `false` so `main.zig`'s caller keeps serving headless (the daemon
    /// NEVER dies because the UI couldn't start). Returns `true` only after the
    /// message loop ran to a user-chosen Exit.
    fn run(
        store: *session.SessionStore,
        build_hash: []const u8,
        link: ?*link_control.LinkControl,
        account: ?*tray_account.TrayAccount,
    ) bool {
        g_store = store;
        g_build_hash = build_hash;
        g_link = link;
        g_account = account;

        const hinst = GetModuleHandleW(null) orelse return false;

        // Our embedded ghost icon, reused for the window class and the tray.
        const app_icon = loadAppIcon(hinst);

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = wndProc,
            .hInstance = hinst,
            .hIcon = app_icon,
            .hIconSm = app_icon,
            .lpszClassName = class_name,
        };
        // RegisterClassExW returns 0 on failure. A duplicate-class error (if the
        // daemon somehow re-registers) is also fine — we proceed to create.
        _ = RegisterClassExW(&wc);

        // A normal (but never-shown) overlapped window. We never call ShowWindow,
        // so nothing appears on screen; it exists only to own the tray icon and
        // pump WM_TRAY / WM_COMMAND. (A message-only HWND_MESSAGE window can't own
        // a tray icon reliably, so we use a hidden top-level window instead.)
        const hwnd = CreateWindowExW(
            0,
            class_name,
            tray_tip,
            WS_OVERLAPPED,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            0,
            0,
            null,
            null,
            hinst,
            null,
        ) orelse return false;

        // Add the tray icon, wired to deliver mouse events as WM_TRAY.
        g_nid = .{
            .cbSize = @sizeOf(NOTIFYICONDATAW),
            .hWnd = hwnd,
            .uID = 1,
            .uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
            .uCallbackMessage = WM_TRAY,
            .hIcon = app_icon,
        };
        copyTip(&g_nid.szTip, tray_tip);
        setTipText(); // relay mode: reflect the link state from the start
        if (Shell_NotifyIconW(NIM_ADD, &g_nid) == 0) {
            // Couldn't place the icon — tear the window down and bail so the caller
            // falls back to headless serving.
            _ = DestroyWindow(hwnd);
            return false;
        }

        // Blocking message loop on this (main) thread. Returns when WM_QUIT is
        // posted by the Exit handler. GetMessageW returns 0 on WM_QUIT, -1 on
        // error — break on either.
        var msg: MSG = undefined;
        while (true) {
            const r = GetMessageW(&msg, null, 0, 0);
            if (r == 0 or r == -1) break;
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        // Loop exited (Exit chosen); the icon was already removed in onExit.
        return true;
    }

    /// Rewrite `g_nid.szTip` from the current relay-link state. No-op when
    /// there is no link (`--listen` mode keeps the static "Ghoztty Agent" tip).
    /// Does NOT call Shell_NotifyIcon — pair with NIM_ADD (setup) or use
    /// `updateTip` (NIM_MODIFY) once the icon exists.
    fn setTipText() void {
        const lk = g_link orelse return;
        _ = switch (lk.display()) {
            .connected => fmtUtf16(&g_nid.szTip, "Ghoztty Agent \u{2014} connected to ", lk.host, ""),
            .reconnecting => fmtUtf16(&g_nid.szTip, "Ghoztty Agent \u{2014} reconnecting", "\u{2026}", ""),
            .offline => fmtUtf16(&g_nid.szTip, "Ghoztty Agent \u{2014} disconnected (by user)", "", ""),
        };
    }

    /// Refresh the live tray icon's tooltip from the current relay-link state
    /// (NIM_MODIFY with the flags already in `g_nid`). No-op in `--listen` mode.
    fn updateTip() void {
        if (g_link == null) return;
        setTipText();
        _ = Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    }

    /// Load the embedded ghost icon (resource id 1) from our own module. Prefers
    /// a crisp small icon sized for the tray (LoadImageW at the system small-icon
    /// size), then a default-size LoadIconW, and only as a last resort the generic
    /// IDI_APPLICATION — so a resource/link mishap degrades instead of showing no
    /// icon at all.
    fn loadAppIcon(hinst: HINSTANCE) ?HICON {
        var cx = GetSystemMetrics(SM_CXSMICON);
        var cy = GetSystemMetrics(SM_CYSMICON);
        if (cx <= 0) cx = 16;
        if (cy <= 0) cy = 16;
        if (LoadImageW(hinst, ICON_RES_ID, IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR)) |h| return h;
        if (LoadIconW(hinst, ICON_RES_ID)) |h| return h;
        return LoadIconW(null, IDI_APPLICATION);
    }

    /// Copy a NUL-terminated UTF-16 literal into a fixed szTip buffer (truncating).
    fn copyTip(dst: []u16, src: [*:0]const u16) void {
        var i: usize = 0;
        while (src[i] != 0 and i + 1 < dst.len) : (i += 1) dst[i] = src[i];
        dst[i] = 0;
    }

    fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
        switch (msg) {
            WM_TRAY => {
                // Shell_NotifyIcon stuffs the originating mouse message into the
                // low word of lParam. Open the menu on either button release.
                // On ANY callback (including hover mouse-moves) refresh the
                // tooltip first, so the tip the shell is about to show reflects
                // the CURRENT relay-link state (cheap: text + NIM_MODIFY;
                // no-op in --listen mode).
                updateTip();
                const mouse: UINT = @truncate(@as(usize, @bitCast(lParam)) & 0xFFFF);
                if (mouse == WM_LBUTTONUP or mouse == WM_RBUTTONUP) {
                    showMenu(hwnd);
                }
                return 0;
            },
            WM_COMMAND => {
                const id: UINT = @truncate(wParam & 0xFFFF);
                switch (id) {
                    ID_ABOUT => onAbout(hwnd),
                    ID_UPDATE => onUpdate(hwnd),
                    ID_DISCONNECT => {
                        // Take the relay link down: closes the live control WS
                        // and suspends the reconnect loop. Local sessions stay
                        // alive (detach, not terminate).
                        if (g_link) |lk| lk.disconnect();
                        updateTip();
                    },
                    ID_RECONNECT => {
                        // Resume the loop immediately (no backoff wait).
                        if (g_link) |lk| lk.reconnect();
                        updateTip();
                    },
                    ID_SIGNOUT => {
                        // Full de-enroll: revoke on the relay + clear the local
                        // credential + park the link. Runs on a worker thread so
                        // the pump never blocks; the menu reflects it next open.
                        if (g_account) |ac| ac.requestSignOut();
                    },
                    ID_SIGNIN => {
                        // Interactive re-enroll (opens the browser) on a worker
                        // thread, then adopts the new token + un-parks the link.
                        if (g_account) |ac| ac.requestSignIn();
                    },
                    ID_EXIT => onExit(),
                    else => {},
                }
                return 0;
            },
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wParam, lParam),
        }
    }

    /// Build + show the context menu, snapshotting sessions fresh. TrackPopupMenu
    /// needs the owning window foreground or it dismisses instantly (a documented
    /// Win32 quirk), hence the SetForegroundWindow + trailing null PostMessage.
    fn showMenu(hwnd: HWND) void {
        const menu = CreatePopupMenu() orelse return;
        defer _ = DestroyMenu(menu); // frees attached submenus too

        // Snapshot the account state ONCE (email copied into a stack buffer so we
        // never hold the account lock across a UI call). Null in `--listen` mode.
        var email_buf: [320]u8 = undefined;
        const acct: ?tray_account.TrayAccount.View =
            if (g_account) |ac| ac.view(&email_buf) else null;

        // Header (disabled): "Ghoztty Agent <hash>".
        var hdr_buf: [128]u16 = undefined;
        const hdr = fmtUtf16(&hdr_buf, "Ghoztty Agent ", g_build_hash, "");
        _ = AppendMenuW(menu, MF_STRING | MF_GRAYED | MF_DISABLED, 0, hdr);

        // Account status line (relay mode): the account this machine is bound to.
        if (acct) |av| {
            var acc_buf: [384]u16 = undefined;
            const line = switch (av.status) {
                .signed_in => if (av.email.len > 0)
                    fmtUtf16(&acc_buf, "Signed in as ", av.email, "")
                else
                    lit("Signed in"),
                .signed_out => lit("Not signed in"),
                .working => lit("Working\u{2026}"),
            };
            _ = AppendMenuW(menu, MF_STRING | MF_GRAYED | MF_DISABLED, 0, line);
        }
        _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);

        // Relay-link section: a status line + ONE item that retitles by state
        // ("Disconnect from relay" while connected/reconnecting, "Reconnect to
        // relay" while disconnected-by-user). Hidden when signed out (there is no
        // credential to dial) and in `--listen` mode (g_link null).
        const show_link = g_link != null and (acct == null or acct.?.status != .signed_out);
        if (show_link) {
            const lk = g_link.?;
            var st_buf: [160]u16 = undefined;
            const d = lk.display();
            const st = switch (d) {
                .connected => fmtUtf16(&st_buf, "Relay: connected to ", lk.host, ""),
                .reconnecting => fmtUtf16(&st_buf, "Relay: reconnecting", "\u{2026}", ""),
                .offline => fmtUtf16(&st_buf, "Relay: disconnected (by user)", "", ""),
            };
            _ = AppendMenuW(menu, MF_STRING | MF_GRAYED | MF_DISABLED, 0, st);
            if (d == .offline) {
                _ = AppendMenuW(menu, MF_STRING, ID_RECONNECT, lit("Reconnect to relay"));
            } else {
                _ = AppendMenuW(menu, MF_STRING, ID_DISCONNECT, lit("Disconnect from relay"));
            }
            _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
        }

        // Sessions as a SUBMENU (rows live inside it, not as top-level siblings).
        appendSessionsSubmenu(menu);
        _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);

        _ = AppendMenuW(menu, MF_STRING, ID_UPDATE, lit("Check for updates"));

        // Sign in / out (relay mode). Grayed while an op is in flight.
        if (acct) |av| {
            switch (av.status) {
                .signed_in => _ = AppendMenuW(menu, MF_STRING, ID_SIGNOUT, lit("Sign out")),
                .signed_out => _ = AppendMenuW(menu, MF_STRING, ID_SIGNIN, lit("Sign in\u{2026}")),
                .working => _ = AppendMenuW(menu, MF_STRING | MF_GRAYED | MF_DISABLED, 0, lit("Working\u{2026}")),
            }
        }

        // About directly above Exit (grouped at the bottom, standard convention).
        _ = AppendMenuW(menu, MF_STRING, ID_ABOUT, lit("About"));
        _ = AppendMenuW(menu, MF_STRING, ID_EXIT, lit("Quit Ghoztty Agent"));

        var pt: POINT = undefined;
        _ = GetCursorPos(&pt);
        // Required so the menu doesn't vanish on the first click off it.
        _ = SetForegroundWindow(hwnd);
        _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, null);
        // Per MSDN: post a benign message so the menu's modal loop cleans up.
        _ = PostMessageW(hwnd, WM_APP, 0, 0);
    }

    /// A single snapshotted session row: pid + a short owned label rendered into a
    /// fixed buffer (no heap; the menu is built and shown synchronously).
    const SessionRow = struct {
        pid: i64,
        /// UTF-8 label (title, else cwd, else short id), copied out under the lock.
        label_buf: [96]u8 = undefined,
        label_len: usize = 0,
        fn label(self: *const SessionRow) []const u8 {
            return self.label_buf[0..self.label_len];
        }
    };

    /// Append a "Sessions (N)" SUBMENU to `parent`, with one disabled row per
    /// live session INSIDE the submenu (not as siblings of the top-level items).
    /// The submenu is attached with MF_POPUP, so `DestroyMenu(parent)` frees it.
    fn appendSessionsSubmenu(parent: HMENU) void {
        const sub = CreatePopupMenu() orelse {
            // Can't build a submenu — degrade to a single disabled inline label
            // rather than dropping the section entirely.
            _ = AppendMenuW(parent, MF_STRING | MF_GRAYED | MF_DISABLED, 0, lit("Sessions"));
            return;
        };

        const total = appendSessionRows(sub);

        var hdr_buf: [64]u16 = undefined;
        var num_buf: [20]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "?";
        const hdr = fmtUtf16(&hdr_buf, "Sessions (", num, ")");
        // MF_POPUP: uIDNewItem carries the submenu handle, not a command id.
        _ = AppendMenuW(parent, MF_STRING | MF_POPUP, @intFromPtr(sub), hdr);
    }

    /// Snapshot up to N live sessions UNDER the store lock (copying out pid + a
    /// label into stack memory), then append them to `target` as disabled rows —
    /// releasing the lock BEFORE any AppendMenuW call (never hold the store lock
    /// across a UI call; the `session.zig` discipline). Returns the live count.
    fn appendSessionRows(target: HMENU) usize {
        const store = g_store orelse return 0;

        const max_rows = 32;
        var rows: [max_rows]SessionRow = undefined;
        var n: usize = 0;
        var total: usize = 0;

        store.mutex.lock();
        {
            var it = store.table.by_id.valueIterator();
            while (it.next()) |sp| {
                const s = sp.*;
                if (!s.alive) continue;
                total += 1;
                if (n >= max_rows) continue;
                var row: SessionRow = .{ .pid = s.pid };
                // Label preference: title → cwd → short id (first 8 hex chars).
                const src: []const u8 = if (s.title) |t|
                    t
                else if (s.cwd) |c|
                    c
                else
                    s.id_str[0..8];
                const m = @min(src.len, row.label_buf.len);
                @memcpy(row.label_buf[0..m], src[0..m]);
                row.label_len = m;
                rows[n] = row;
                n += 1;
            }
        }
        store.mutex.unlock();

        if (total == 0) {
            _ = AppendMenuW(target, MF_STRING | MF_GRAYED | MF_DISABLED, 0, lit("(no active sessions)"));
            return 0;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const row = &rows[i];
            var line_buf: [160]u16 = undefined;
            var pid_buf: [24]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}  ", .{row.pid}) catch "?  ";
            const line = fmtUtf16(&line_buf, pid_str, row.label(), "");
            _ = AppendMenuW(target, MF_STRING | MF_GRAYED | MF_DISABLED, 0, line);
        }
        return total;
    }

    fn onAbout(hwnd: HWND) void {
        var buf: [256]u16 = undefined;
        const text = fmtUtf16(
            &buf,
            "Ghoztty Agent (build ",
            g_build_hash,
            ")\nRemote session daemon — listening for client connections.",
        );
        _ = MessageBoxW(hwnd, text, lit("About Ghoztty Agent"), MB_OK | MB_ICONINFORMATION);
    }

    fn onUpdate(hwnd: HWND) void {
        // TODO(update): real update check. The deploy watcher currently hot-swaps a
        // new ghoztty-agent.exe dropped on the share, so updates are automatic; a
        // manual "check now" / version-compare path is a later increment.
        var buf: [256]u16 = undefined;
        const text = fmtUtf16(
            &buf,
            "Current build ",
            g_build_hash,
            ".\nAuto-update is handled by the deploy watcher.",
        );
        _ = MessageBoxW(hwnd, text, lit("Check for updates"), MB_OK | MB_ICONINFORMATION);
    }

    /// Exit: remove the tray icon, then post WM_QUIT so the message loop returns
    /// and the caller exits the process.
    fn onExit() void {
        _ = Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
    }

    /// Format `a ++ b ++ c` (UTF-8 inputs) into `dst` as a NUL-terminated UTF-16LE
    /// string, truncating to fit. Returns a `[*:0]const u16` for the Win32 calls.
    /// Used for the small, dynamic menu/dialog strings.
    /// Pre-tray startup-error box (see the public `showStartupError`). Owner
    /// HWND is null — no window exists yet at the failures this serves.
    fn showStartupError(text: []const u8) void {
        var buf: [512]u16 = undefined;
        const wtext = fmtUtf16(&buf, text, "", "");
        _ = MessageBoxW(null, wtext, lit("Ghoztty Agent"), MB_OK | MB_ICONERROR);
    }

    fn fmtUtf16(dst: []u16, a: []const u8, b: []const u8, c: []const u8) [*:0]const u16 {
        var i: usize = 0;
        for ([_][]const u8{ a, b, c }) |part| {
            // utf8ToUtf16Le handles multi-byte; our inputs are paths/titles/ascii.
            const room = dst.len -| (i + 1); // leave space for the NUL
            if (room == 0) break;
            const written = std.unicode.utf8ToUtf16Le(dst[i .. i + room], part) catch
                // On invalid UTF-8 (shouldn't happen for our inputs), copy the
                // ASCII subset byte-wise so we still render something.
                copyAsciiLossy(dst[i .. i + room], part);
            i += written;
        }
        dst[i] = 0;
        return @ptrCast(dst.ptr);
    }

    /// Fallback: copy `src` into `dst` as UTF-16, replacing non-ASCII with '?'.
    /// Returns the number of code units written.
    fn copyAsciiLossy(dst: []u16, src: []const u8) usize {
        var i: usize = 0;
        while (i < src.len and i < dst.len) : (i += 1) {
            dst[i] = if (src[i] < 0x80) src[i] else '?';
        }
        return i;
    }

    /// Shorthand for a compile-time UTF-16 literal.
    inline fn lit(comptime s: []const u8) [*:0]const u16 {
        return std.unicode.utf8ToUtf16LeStringLiteral(s);
    }
} else struct {};

test {
    std.testing.refAllDecls(@This());
}
