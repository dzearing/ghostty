//! Offer to restart the terminal the installer just replaced (T1352).
//!
//! ## The defect, in the user's words (2026-09-05)
//!
//! > "i ran the latest ghoztty installer but it didn't reset this window at
//! > all. what's going on?"
//!
//! The install had genuinely succeeded. Windows cannot replace a running
//! image, but MSI can rename the running exe aside and drop a new one in its
//! place, so the upgrade completed with nothing to prompt about — and the
//! process carried on executing five-day-old code. Every window the user had
//! lived in that one process.
//!
//! ## Why nothing that already exists covers it
//!
//! - **T1204** (Restart Manager participation) only speaks when RM *cannot
//!   proceed otherwise*. Here it could proceed, so it correctly said nothing.
//! - **T1205** (the stale-build tray balloon and the About "Restart Now"
//!   offer) is the missing signal, but it lives in the build that is NOT
//!   running: a feature cannot announce itself retroactively out of a process
//!   started before it shipped.
//! - **T1176** (launch-on-finish) is suppressed on the upgrade path, and would
//!   only have added a window to the OLD process anyway.
//!
//! ## The shape of the fix
//!
//! The one process that is guaranteed to contain today's code at the moment of
//! the upgrade is the exe msiexec has just written. So the package runs it:
//! `[INSTALLDIR]ghoztty.exe --install-restart`, after `InstallFinalize`, as an
//! `asyncNoWait` action — the installer must not wait on a dialog, and this
//! action's exit code must never be able to fail an install that has already
//! completed.
//!
//! It then:
//!
//!  1. **Looks for windows of the install it just replaced** — top-level
//!     `GhozttyWindow` windows whose process image is `<INSTALLDIR>\ghoztty.exe`.
//!     None (the ordinary case: nobody was running it) means it exits silently.
//!  2. **Offers.** The same dark `ConfirmDialog` every other Ghoztty prompt
//!     uses, relabelled Restart Now / Later.
//!  3. **On Restart Now, closes them the way the Restart Manager does** —
//!     `WM_QUERYENDSESSION` then `WM_ENDSESSION` with `ENDSESSION_CLOSEAPP`.
//!     That pair is not an approximation of the update path, it IS the update
//!     path: `Window.zig` answers it by flushing the session layout and exiting
//!     WITHOUT marking any session CLOSE (T89e/T1204), so the agent keeps the
//!     PTYs and the relaunched app re-attaches them. Then it relaunches
//!     `<INSTALLDIR>\ghoztty.exe`, which restores the layout.
//!  4. **On Later, leaves a reminder** — a tray balloon naming the version that
//!     is now installed and the fact that the open windows are still on the old
//!     one. "Installed but not running yet" must never look identical to
//!     "nothing happened", which is the whole complaint above.
//!
//! ## Deliberately NOT here
//!
//! - **Killing anything.** A window that does not close within the wait budget
//!   is a build older than T1204, whose message handler does not answer an RM
//!   close. Terminating it would take the layout it never got to flush; the
//!   honest outcome is to say so and let the user close it themselves. A
//!   restart offer that loses work is worse than silence.
//! - **The silent path.** The package gates this action on `UILevel > 3`, so
//!   the in-app updater's `/qb-!` install never runs it. The updater already
//!   closes and relaunches the app itself; a second offer inside an unattended
//!   update would be a hang.
//! - **Any effect on the install.** Every path returns 0 and the action is
//!   `Return="ignore"` besides. The files are on disk before this runs.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const build_config = @import("../../build_config.zig");
const ConfirmDialog = @import("ConfirmDialog.zig");
const job_spawn = @import("job_spawn.zig");
const restart_manager = @import("restart_manager.zig");

const log = std.log.scoped(.win32_install_restart);

/// The argv flag that turns a `ghoztty.exe` start into the restart offer.
///
/// An argument rather than an environment variable, and spelled like plumbing
/// rather than as a `+verb`, for the reasons its neighbours give: the caller is
/// msiexec, which controls its child's command line and not its environment,
/// and `src/cli/ghostty.zig`'s action enum is the cross-platform CLI surface
/// that must not grow a Windows-installer-only member (the T141 lesson).
pub const flag = "--install-restart";

/// Optional `--install-dir=<path>`: which install's windows to offer to
/// restart. Defaults to the directory the running exe lives in, which is what
/// the custom action means (`[INSTALLDIR]ghoztty.exe --install-restart`).
///
/// The flag is what keeps this honest under test AND in ordinary use: the
/// filter is the whole reason a developer's `zig-out` build is never swept up
/// by an installer running against `%LOCALAPPDATA%\Programs\Ghoztty`.
pub const dir_flag = "--install-dir=";

/// Optional `--installed-version=<text>`: what to call the build that was just
/// installed. The package passes `[ARPDISPLAYVERSION]`, so the number in the
/// dialog is the one Apps & Features shows (T1205) rather than the internal
/// `yy.m.dNN` the installer sequences on.
pub const version_flag = "--installed-version=";

/// Optional `--answer=restart|later`: skip the dialog and act as if the button
/// had been pressed.
///
/// The acceptance seam, for the same reason `install_maintenance.answer_flag`
/// is one: what is worth measuring is the OUTCOME — the running app exits and a
/// new one comes up on the new build — and that cannot be measured by a script
/// that has to click a button on a background desktop, where synthetic input
/// does not reach.
pub const answer_flag = "--answer=";

/// What the person chose.
pub const Answer = enum {
    restart,
    later,

    pub fn parse(text: []const u8) ?Answer {
        if (std.mem.eql(u8, text, "restart")) return .restart;
        if (std.mem.eql(u8, text, "later")) return .later;
        return null;
    }
};

/// What a command line asked for, or null when it did not ask for this at all.
pub const Request = struct {
    /// The install whose windows to offer to restart, or null for "the
    /// directory this exe lives in".
    dir: ?[]const u8 = null,
    /// How to name the newly installed build, or null for this exe's own
    /// version.
    version: ?[]const u8 = null,
    /// A pre-supplied answer (the acceptance seam), or null to ask.
    answer: ?Answer = null,
};

/// Parse a command line. Pure, so the lane checks it: like its neighbours in
/// `install_prepare.zig` and `install_maintenance.zig`, this function decides
/// whether an ordinary `ghoztty.exe` start is quietly turned into something
/// that is not a terminal — and a false positive here would close the user's
/// windows, which is the most expensive way to be wrong in this directory.
///
/// `args` is the FULL argv including argv[0], the way the process sees it.
pub fn parse(args: []const []const u8) ?Request {
    var found = false;
    var req: Request = .{};
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, flag)) {
            found = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, dir_flag)) {
            const value = arg[dir_flag.len..];
            if (value.len > 0) req.dir = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, version_flag)) {
            const value = arg[version_flag.len..];
            if (value.len > 0) req.version = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, answer_flag)) {
            req.answer = Answer.parse(arg[answer_flag.len..]);
            continue;
        }
    }
    if (!found) return null;
    return req;
}

/// The image whose windows this offers to restart. One name, because one
/// process type has the windows: the agent and its holders are windowless and
/// are `install_prepare.zig`'s business, not this module's.
pub const app_image = "ghoztty.exe";

/// True when `exe_path` is the app image of the install rooted at `dir`.
///
/// Compared case-insensitively because Windows paths are, and structurally
/// (directory + basename) rather than by prefix, so a sibling install at
/// `...\Ghoztty-old` is never mistaken for one inside `...\Ghoztty`.
pub fn isInstalledApp(exe_path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    const base = std.fs.path.basename(exe_path);
    if (!std.ascii.eqlIgnoreCase(base, app_image)) return false;
    const parent = std.fs.path.dirname(exe_path) orelse return false;
    return std.ascii.eqlIgnoreCase(trimTrailingSep(parent), trimTrailingSep(dir));
}

fn trimTrailingSep(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    return path[0..end];
}

/// How long a window gets to act on the close request before this gives up on
/// it. Generous on purpose: the app flushes the session layout synchronously on
/// its way out, and the cost of being impatient is telling the user a restart
/// failed that was about to succeed.
pub const close_wait_ms: u32 = 20_000;

/// How often the wait re-checks. Small enough that the relaunch follows the
/// exit closely, large enough not to spin.
pub const poll_ms: u32 = 100;

/// The longest message this builds, so buffers are sized from one number.
pub const max_message = 640;

/// The offer's title.
pub const title = "Ghoztty has been updated";

/// The offer. Leads with what is TRUE right now — the update is installed, the
/// windows on screen are not running it — because that sentence is the one the
/// user went looking for and could not find.
pub fn message(buf: []u8, version: []const u8, windows: usize) []const u8 {
    const subject = if (windows == 1)
        "The Ghoztty window you have open is"
    else
        "The Ghoztty windows you have open are";
    return std.fmt.bufPrint(
        buf,
        "Ghoztty {s} is installed.\n\n{s} still running the previous build — " ++
            "Windows cannot replace a program while it is running.\n\n" ++
            "Restart Ghoztty now to use the new build? Your windows and " ++
            "sessions come back.",
        .{ version, subject },
    ) catch "Ghoztty has been updated. Restart Ghoztty now to use the new build?";
}

/// The reminder left behind when the offer is declined — a tray balloon, so the
/// state "installed but not running yet" leaves a mark instead of looking
/// exactly like "nothing happened".
pub const reminder_title = "Ghoztty updated";

pub fn reminderBody(buf: []u8, version: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Ghoztty {s} is installed. Your open windows are still running the " ++
            "previous build until you restart Ghoztty.",
        .{version},
    ) catch "Ghoztty has been updated. Restart Ghoztty to use the new build.";
}

/// What is said when a window would not close. Never a silent give-up: the
/// user asked for a restart and did not get one.
pub const failure_title = "Ghoztty could not be restarted";

pub fn failureMessage(buf: []u8, still_open: usize) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{d} Ghoztty window(s) did not close, so Ghoztty was not restarted.\n\n" ++
            "Quit Ghoztty yourself and open it again to use the new build. " ++
            "Your sessions are kept either way.",
        .{still_open},
    ) catch "Ghoztty did not close, so it was not restarted. Quit Ghoztty and open it again.";
}

/// How long the reminder balloon is left on screen. The shell's own timeout is
/// advisory; the icon must outlive the balloon or it takes it with it.
pub const reminder_ms: u32 = 12_000;

/// Was this process started as the installer's restart offer? If so, make the
/// offer and hand `main` an exit code — an offer never becomes a terminal.
///
/// Returns null for an ordinary start. Every other path returns 0: the install
/// finished before this ran, and nothing here is allowed to look like a failed
/// one.
pub fn runFromArgs(alloc: Allocator) ?u8 {
    if (comptime builtin.os.tag != .windows) return null;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = std.process.argsAlloc(arena) catch return null;
    const req = parse(args) orelse return null;

    const self_exe = std.fs.selfExePathAlloc(arena) catch |err| {
        log.err("install restart: cannot resolve own exe: {}", .{err});
        return 0;
    };
    const dir = req.dir orelse (std.fs.path.dirname(self_exe) orelse {
        log.err("install restart: {s} has no directory", .{self_exe});
        return 0;
    });

    const targets = collectWindows(arena, dir) catch |err| {
        log.err("install restart: could not enumerate windows: {}", .{err});
        return 0;
    };
    if (targets.len == 0) {
        // The ordinary case by a mile: nobody had Ghoztty open, so there is
        // nothing stale and nothing to say.
        log.info("install restart: no running windows from {s}; nothing to offer", .{dir});
        return 0;
    }

    const version = req.version orelse build_config.version_string;
    const answer = req.answer orelse ask(version, targets.len);
    log.warn("install restart: {d} window(s) from {s}; answer={s}", .{
        targets.len,
        dir,
        @tagName(answer),
    });

    switch (answer) {
        .later => remind(version),
        .restart => restart(arena, dir, targets),
    }
    return 0;
}

/// A window of the install being replaced, and the process behind it.
pub const Target = struct {
    hwnd: w32.HWND,
    pid: u32,
};

/// Every top-level Ghoztty window whose process runs `<dir>\ghoztty.exe`,
/// excluding this one.
///
/// `FindWindowExW` rather than `EnumWindows`: the class name is the filter, so
/// the enumeration can BE the filter instead of a callback that re-checks it.
/// The class string is the one every build has registered since long before
/// this feature, which matters here more than anywhere else in this directory —
/// the whole point is to reach a process built before today.
fn collectWindows(arena: Allocator, dir: []const u8) ![]Target {
    var out = std.ArrayList(Target){};
    if (comptime builtin.os.tag != .windows) return out.items;

    const self_pid = w32.GetCurrentProcessId();
    var prev: ?w32.HWND = null;
    // Bounded: a pathological window list must not turn an installer step into
    // an infinite one.
    for (0..512) |_| {
        const hwnd = FindWindowExW(null, prev, app_window_class, null) orelse break;
        prev = hwnd;

        var pid: u32 = 0;
        _ = w32.GetWindowThreadProcessId(hwnd, &pid);
        if (pid == 0 or pid == self_pid) continue;
        // One row per process: an app with four windows must be closed once,
        // not four times.
        var seen = false;
        for (out.items) |t| {
            if (t.pid == pid) seen = true;
        }
        if (seen) continue;

        const path = processImagePath(arena, pid) orelse continue;
        if (!isInstalledApp(path, dir)) continue;
        try out.append(arena, .{ .hwnd = hwnd, .pid = pid });
    }
    return out.items;
}

/// The window class every Ghoztty top-level window has been registered with.
/// Duplicated from `App.WINDOW_CLASS_NAME` rather than imported, because this
/// module must not pull the whole app in to run as a 200ms installer step —
/// the assertion that the two agree lives in the tests below.
const app_window_class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyWindow");

/// The full image path of a running process, or null when it cannot be asked
/// (it exited, or it belongs to somebody else).
fn processImagePath(arena: Allocator, pid: u32) ?[]const u8 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer std.os.windows.CloseHandle(h);

    var buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    var len: u32 = buf.len;
    if (QueryFullProcessImageNameW(h, 0, &buf, &len) == 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(arena, buf[0..len]) catch null;
}

/// Put the offer on screen and wait for it.
///
/// `showStandalone`: this process has no `App`, no window and no message loop —
/// it is the installed exe run by msiexec, the same position
/// `install_maintenance.zig` and `update_install.zig` are in.
fn ask(version: []const u8, windows: usize) Answer {
    if (comptime builtin.os.tag != .windows) return .later;

    var text_buf: [max_message]u8 = undefined;
    const text = message(&text_buf, version, windows);

    var wbuf: [max_message * 2]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], text) catch {
        // A message that cannot be encoded is no reason to close the user's
        // terminal without asking.
        log.err("install restart: offer could not be encoded; leaving the app alone", .{});
        return .later;
    };
    wbuf[n] = 0;

    const result = ConfirmDialog.showStandalone(null, 1.0, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral(title),
        .text = wbuf[0..n :0],
        .style = .ok_cancel,
        .icon = .info,
        // Enter lands on Restart Now: the user has just run an installer, and
        // restarting is what they came for. Nothing is lost either way — the
        // sessions survive the restart — so the default can be the useful one.
        .default_cancel = false,
        .ok_label = std.unicode.utf8ToUtf16LeStringLiteral("Restart Now"),
        .cancel_label = std.unicode.utf8ToUtf16LeStringLiteral("Later"),
    });

    return switch (result) {
        .ok => .restart,
        .cancel => .later,
    };
}

/// Close every target the way the Restart Manager would, then start the new
/// build. See the module header for why this pair and not a `WM_CLOSE`: it is
/// the app-EXIT path, which deliberately marks no session CLOSE.
fn restart(arena: Allocator, dir: []const u8, targets: []const Target) void {
    if (comptime builtin.os.tag != .windows) return;

    for (targets) |t| {
        var result: usize = 0;
        _ = w32.SendMessageTimeoutW(
            t.hwnd,
            w32.WM_QUERYENDSESSION,
            0,
            @bitCast(restart_manager.ENDSESSION_CLOSEAPP),
            SMTO_ABORTIFHUNG,
            5_000,
            &result,
        );
        // The answer is not consulted: this is OUR app, and the one build that
        // could refuse is one that never sees the message at all. Sending the
        // query first is what makes the pair the same pair the Restart Manager
        // sends, which is what the handler is written against.
        _ = w32.SendMessageTimeoutW(
            t.hwnd,
            w32.WM_ENDSESSION,
            1,
            @bitCast(restart_manager.ENDSESSION_CLOSEAPP),
            SMTO_ABORTIFHUNG,
            close_wait_ms,
            &result,
        );
    }

    const still_open = waitForExit(targets);
    if (still_open > 0) {
        log.err("install restart: {d} process(es) did not exit; NOT relaunching", .{still_open});
        var buf: [max_message]u8 = undefined;
        report(failure_title, failureMessage(&buf, still_open));
        return;
    }

    const exe = std.fmt.allocPrint(arena, "{s}\\{s}", .{ trimTrailingSep(dir), app_image }) catch return;
    if (!relaunch(arena, exe)) {
        var buf: [max_message]u8 = undefined;
        report(failure_title, failureMessage(&buf, targets.len));
    }
}

/// Wait for every target process to end, and report how many did not.
fn waitForExit(targets: []const Target) usize {
    if (comptime builtin.os.tag != .windows) return 0;

    var waited: u32 = 0;
    while (waited < close_wait_ms) : (waited += poll_ms) {
        if (aliveCount(targets) == 0) return 0;
        w32.Sleep(poll_ms);
    }
    return aliveCount(targets);
}

fn aliveCount(targets: []const Target) usize {
    var alive: usize = 0;
    for (targets) |t| {
        const h = OpenProcess(SYNCHRONIZE, 0, t.pid) orelse continue;
        defer std.os.windows.CloseHandle(h);
        if (w32.WaitForSingleObject(h, 0) != w32.WAIT_OBJECT_0) alive += 1;
    }
    return alive;
}

/// Start the newly installed build. Detached and outside any job we inherited,
/// the way every other relaunch in this codebase spawns (`job_spawn`), so the
/// new terminal does not die with whatever started the installer.
fn relaunch(arena: Allocator, exe: []const u8) bool {
    const cmd = std.fmt.allocPrint(arena, "\"{s}\"", .{exe}) catch return false;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(arena, cmd) catch return false;

    const spawned = job_spawn.spawnEscapingJob(
        arena,
        cmd_w.ptr,
        job_spawn.DETACHED_PROCESS,
        "install restart",
    ) catch |err| {
        log.err("install restart: relaunch of {s} FAILED: {}", .{ exe, err });
        return false;
    };
    const pid = w32.GetProcessId(spawned.pi.hProcess);
    std.os.windows.CloseHandle(spawned.pi.hProcess);
    std.os.windows.CloseHandle(spawned.pi.hThread);
    log.warn("install restart: relaunched {s} as pid {d} (escape={s})", .{
        exe,
        pid,
        spawned.tier.name(),
    });
    return true;
}

/// Say the thing that could not be done, in the same standalone modal the
/// update applier uses for the same purpose (T1206).
fn report(box_title: []const u8, text: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;

    var title_buf: [128]u16 = undefined;
    const tn = std.unicode.utf8ToUtf16Le(title_buf[0 .. title_buf.len - 1], box_title) catch return;
    title_buf[tn] = 0;

    var wbuf: [max_message * 2]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], text) catch return;
    wbuf[n] = 0;

    _ = ConfirmDialog.showStandalone(null, 1.0, .{
        .title = title_buf[0..tn :0],
        .text = wbuf[0..n :0],
        .style = .ok_only,
        .icon = .warning,
    });
}

/// Leave the reminder for a declined offer: a tray balloon from a process that
/// exists only long enough to show it.
///
/// The icon has to outlive the balloon (removing it removes the balloon), and
/// the shell delivers its notifications by window message, so this owns a
/// hidden window and pumps it for `reminder_ms`. That is the whole reason this
/// is not a call into `App.showTrayBalloon` — there is no App here.
fn remind(version: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;

    const hinstance = w32.GetModuleHandleW(null);
    const class = std.unicode.utf8ToUtf16LeStringLiteral("GhozttyInstallRestartNotify");
    var wc: w32.WNDCLASSEXW = std.mem.zeroes(w32.WNDCLASSEXW);
    wc.cbSize = @sizeOf(w32.WNDCLASSEXW);
    wc.lpfnWndProc = w32.DefWindowProcW;
    wc.hInstance = hinstance;
    wc.lpszClassName = class;
    _ = w32.RegisterClassExW(&wc);

    const hwnd = w32.CreateWindowExW(
        0,
        class,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty"),
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("install restart: no window for the reminder balloon", .{});
        return;
    };
    defer _ = w32.DestroyWindow(hwnd);

    var body_buf: [max_message]u8 = undefined;
    const body = reminderBody(&body_buf, version);

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = reminder_uid;
    nid.uFlags = w32.NIF_ICON | w32.NIF_TIP | w32.NIF_INFO;
    nid.hIcon = w32.LoadIconW(hinstance, w32.IDI_GHOSTTY) orelse
        w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = reminder_ms;

    var title_utf16: [64]u16 = undefined; // NOTIFYICONDATAW.szInfoTitle
    const tlen = std.unicode.utf8ToUtf16Le(&title_utf16, reminder_title) catch return;
    @memcpy(nid.szInfoTitle[0..tlen], title_utf16[0..tlen]);
    nid.szInfoTitle[tlen] = 0;

    var body_utf16: [256]u16 = undefined; // NOTIFYICONDATAW.szInfo
    if (body.len >= body_utf16.len) return;
    const blen = std.unicode.utf8ToUtf16Le(&body_utf16, body) catch return;
    @memcpy(nid.szInfo[0..blen], body_utf16[0..blen]);
    nid.szInfo[blen] = 0;

    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    if (w32.Shell_NotifyIconW(w32.NIM_ADD, &nid) == 0) {
        log.err("install restart: the shell refused the reminder balloon", .{});
        return;
    }
    defer _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);

    // Keep the icon (and therefore the balloon) alive, pumping so the shell's
    // messages are answered rather than piling up behind an unresponsive
    // window.
    var waited: u32 = 0;
    var msg: w32.MSG = undefined;
    while (waited < reminder_ms) : (waited += poll_ms) {
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            _ = w32.TranslateMessage(&msg);
            _ = w32.DispatchMessageW(&msg);
        }
        w32.Sleep(poll_ms);
    }
}

/// The reminder's tray-icon id. Its own number rather than any of
/// `tray_notify.zig`'s: those belong to the running app's icons, and this one
/// is added and removed by a different process entirely.
pub const reminder_uid: u32 = 11;

const SYNCHRONIZE: std.os.windows.DWORD = 0x00100000;
const PROCESS_QUERY_LIMITED_INFORMATION: std.os.windows.DWORD = 0x1000;
const SMTO_ABORTIFHUNG: u32 = 0x0002;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn QueryFullProcessImageNameW(
    hProcess: std.os.windows.HANDLE,
    dwFlags: std.os.windows.DWORD,
    lpExeName: [*]u16,
    lpdwSize: *u32,
) callconv(.winapi) std.os.windows.BOOL;

extern "user32" fn FindWindowExW(
    hWndParent: ?w32.HWND,
    hWndChildAfter: ?w32.HWND,
    lpszClass: ?[*:0]const u16,
    lpszWindow: ?[*:0]const u16,
) callconv(.winapi) ?w32.HWND;

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "parse: recognises the flag anywhere in argv" {
    const req = parse(&.{ "ghoztty.exe", flag }) orelse return error.NotParsed;
    try testing.expect(req.dir == null);
    try testing.expect(req.version == null);
    try testing.expect(req.answer == null);
}

test "parse: an ordinary start never closes anybody's windows" {
    // The expensive direction to be wrong in: every one of these must be null,
    // or a plain launch would offer to shut the terminal down.
    try testing.expect(parse(&.{"ghoztty.exe"}) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "+list" }) == null);
    // argv[0] is skipped: an exe NAMED like the flag must not arm it.
    try testing.expect(parse(&.{flag}) == null);
    // Near misses are misses, including the two neighbouring installer flags.
    try testing.expect(parse(&.{ "ghoztty.exe", "--install-restart-x" }) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "--install-prepare" }) == null);
    try testing.expect(parse(&.{ "ghoztty.exe", "--install-maintenance" }) == null);
}

test "parse: reads the install dir, the version and the answer" {
    const req = parse(&.{
        "ghoztty.exe",
        flag,
        dir_flag ++ "C:\\Users\\x\\AppData\\Local\\Programs\\Ghoztty",
        version_flag ++ "1.36.13",
        answer_flag ++ "restart",
    }) orelse return error.NotParsed;
    try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Local\\Programs\\Ghoztty", req.dir.?);
    try testing.expectEqualStrings("1.36.13", req.version.?);
    try testing.expectEqual(Answer.restart, req.answer.?);

    const later = parse(&.{ "ghoztty.exe", flag, answer_flag ++ "later" }) orelse
        return error.NotParsed;
    try testing.expectEqual(Answer.later, later.answer.?);

    // Empty values are an MSI property that resolved to nothing: fall back
    // rather than pointing the offer at "".
    const empty = parse(&.{ "ghoztty.exe", flag, dir_flag, version_flag }) orelse
        return error.NotParsed;
    try testing.expect(empty.dir == null);
    try testing.expect(empty.version == null);

    // An unrecognised answer ASKS rather than guessing, and the guess that
    // matters is never "restart".
    const bogus = parse(&.{ "ghoztty.exe", flag, answer_flag ++ "yes" }) orelse
        return error.NotParsed;
    try testing.expect(bogus.answer == null);
}

test "isInstalledApp: only this install's app image" {
    const dir = "C:\\Users\\x\\AppData\\Local\\Programs\\Ghoztty";
    try testing.expect(isInstalledApp(dir ++ "\\ghoztty.exe", dir));
    // Windows paths are case-insensitive, and so is the drive letter.
    try testing.expect(isInstalledApp("c:\\users\\X\\appdata\\local\\programs\\ghoztty\\GHOZTTY.EXE", dir));
    // A trailing separator on either side is the same directory.
    try testing.expect(isInstalledApp(dir ++ "\\ghoztty.exe", dir ++ "\\"));

    // The developer's build is NOT this install, which is what keeps an
    // installer from closing a debug window (and an acceptance run from
    // closing the user's terminal).
    try testing.expect(!isInstalledApp("D:\\git\\ghoztty\\zig-out\\bin\\ghoztty.exe", dir));
    // A sibling directory that merely starts with the same text.
    try testing.expect(!isInstalledApp(dir ++ "-old\\ghoztty.exe", dir));
    // A subdirectory of the install is not the install.
    try testing.expect(!isInstalledApp(dir ++ "\\gl\\ghoztty.exe", dir));
    // Other images in the same directory are somebody else's business: the
    // agent and its holders are windowless and belong to install_prepare.
    try testing.expect(!isInstalledApp(dir ++ "\\ghoztty-agent.exe", dir));
    try testing.expect(!isInstalledApp(dir ++ "\\ghoztty.com", dir));
    // Nonsense in, false out.
    try testing.expect(!isInstalledApp("ghoztty.exe", dir));
    try testing.expect(!isInstalledApp(dir ++ "\\ghoztty.exe", ""));
}

test "message: names the version and both choices, singular and plural" {
    var buf: [max_message]u8 = undefined;

    const one = message(&buf, "1.36.13", 1);
    try testing.expect(std.mem.indexOf(u8, one, "1.36.13") != null);
    try testing.expect(std.mem.indexOf(u8, one, "window you have open is") != null);
    try testing.expect(std.mem.indexOf(u8, one, "Restart Ghoztty now") != null);
    // The sentence the user could not find anywhere on 2026-09-05.
    try testing.expect(std.mem.indexOf(u8, one, "still running the previous build") != null);
    // And the reassurance, because the offer is worthless if taking it looks
    // like it costs the user their work.
    try testing.expect(std.mem.indexOf(u8, one, "sessions come back") != null);

    const many = message(&buf, "1.36.13", 3);
    try testing.expect(std.mem.indexOf(u8, many, "windows you have open are") != null);

    // The buffer is sized from max_message, so the longest plausible version
    // string must still fit rather than silently falling back to the short
    // form.
    const long = message(&buf, "26.9.301+0123456789abcdef", 2);
    try testing.expect(std.mem.indexOf(u8, long, "26.9.301+0123456789abcdef") != null);
}

test "reminderBody: the declined offer still says what is true" {
    var buf: [max_message]u8 = undefined;
    const text = reminderBody(&buf, "1.36.13");
    try testing.expect(std.mem.indexOf(u8, text, "1.36.13") != null);
    try testing.expect(std.mem.indexOf(u8, text, "installed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "until you restart") != null);
    // It has to fit the shell's szInfo field (256 wide chars) or the balloon
    // is silently not shown — which would be the defect again.
    try testing.expect(text.len < 256);
}

test "failureMessage: says what to do instead" {
    var buf: [max_message]u8 = undefined;
    const text = failureMessage(&buf, 2);
    try testing.expect(std.mem.indexOf(u8, text, "2 Ghoztty window(s) did not close") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not restarted") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sessions are kept") != null);
}

test "the close request is the Restart Manager's, not a window close" {
    // What makes this session-safe: WM_ENDSESSION with ENDSESSION_CLOSEAPP is
    // the app-EXIT path, which marks no session CLOSE (T89e/T1204). A WM_CLOSE
    // would go through window.close and take the sessions with it.
    try testing.expectEqual(@as(u32, 0x0011), w32.WM_QUERYENDSESSION);
    try testing.expectEqual(@as(u32, 0x0016), w32.WM_ENDSESSION);
    try testing.expect(restart_manager.isCloseAppRequest(restart_manager.ENDSESSION_CLOSEAPP));
}

test "the window class matches the one the app registers" {
    // Duplicated on purpose (see the decl), so this is the assertion that the
    // duplicate is still true. A drift here is a feature that silently finds
    // nothing to restart, forever.
    const App = @import("App.zig");
    try testing.expectEqualSlices(u16, App.WINDOW_CLASS_NAME, app_window_class);
}
