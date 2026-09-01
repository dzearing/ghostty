//! The OS half of the Windows in-app update (T1178): fetch the package,
//! and then choreograph the one thing a running program cannot do to itself —
//! be replaced on disk. The decisions this file acts on are all in
//! `update_apply.zig`, where they are tested without a box.
//!
//! Shape, which is deliberately the `relaunch_guard.zig` shape one directory
//! over, for the same reason (it is the only shape that survives its own
//! subject exiting):
//!
//!  1. The app downloads the MSI into `%LOCALAPPDATA%\ghoztty\updates` and
//!     checks that what arrived is really a package.
//!  2. `arm` copies `ghoztty.exe` to `…\updates\ghoztty-updater.exe` and
//!     spawns THAT copy carrying `GHOZTTY_UPDATE_APPLY=<pid>|<msi>|<exe>`.
//!     A copy, not the installed exe: the installed one is exactly what
//!     msiexec is about to replace, and an applier holding it open would
//!     block the install it exists to perform.
//!  3. The app quits.
//!  4. `runFromEnv` (that copy, before any app state exists) waits for the
//!     app's pid, clears INSTALLDIR of anything still locked, runs msiexec,
//!     and relaunches Ghoztty.
//!
//! Two properties worth defending in review:
//!
//! - **The user's shells are not collateral.** Per-session PTY holders
//!   (`ghoztty-agent.exe --pty-host`) outlive the agent by design, so they are
//!   still running — out of INSTALLDIR — when msiexec starts. They are NOT
//!   killed to make room. Their image is RENAMED instead (`sidelineName`):
//!   Windows will not delete a running image but will happily rename one, the
//!   open handle follows the file, and msiexec then writes a fresh
//!   `ghoztty-agent.exe` into a path that is now empty. The holders keep the
//!   old code until they are next restarted, which is precisely the situation
//!   the app↔agent protocol handshake already exists to handle.
//! - **A failed update leaves a working terminal.** Every failure path still
//!   relaunches the exe it was given. The worst outcome is the version the
//!   user already had, plus an msiexec log to read.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");
const job_spawn = @import("job_spawn.zig");
const update_apply = @import("update_apply.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_update_install);

/// The environment variable that turns a `ghoztty.exe` start into an applier.
pub const env_var = "GHOZTTY_UPDATE_APPLY";

/// Hard cap on how long the applier waits for the app to exit. Far above a
/// normal quit and low enough that an app which hangs forever does not leave
/// an applier resident.
const max_app_wait_ms: i64 = 2 * std.time.ms_per_min;

/// How long msiexec is allowed to take. A per-user MSI of this size installs
/// in seconds; ten minutes is "something is very wrong", not "be patient".
const max_msiexec_ms: u32 = 10 * 60 * 1000;

const poll_ms: u32 = 250;

/// Cap on a downloaded package. The Ghoztty MSI is tens of MB; this is the
/// ceiling that stops a wrong URL streaming forever into the user's disk.
pub const max_package_bytes: usize = 512 * 1024 * 1024;

/// The images an update replaces, and therefore the ones that may need
/// sidelining. `share/` is data, not code, and nothing holds it open.
const install_images = [_][]const u8{ "ghoztty.exe", "ghoztty.com", "ghoztty-agent.exe" };

// =============================================================================
// Staging
// =============================================================================

/// `%LOCALAPPDATA%\ghoztty\updates[-debug]` — per lineage like every other bit
/// of app state, so a debug run can never stage a package the installed
/// release would find, nor spawn an applier that installs over it.
pub fn stagingDir(arena: Allocator) ![]const u8 {
    const name = if (build_config.is_debug) "updates-debug" else "updates";
    const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return error.NoLocalAppData;
    const dir = try std.fmt.allocPrint(arena, "{s}\\ghoztty\\{s}", .{ local, name });
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return dir;
}

/// Download `url` into the staging directory and return the staged path
/// (caller-owned, allocated with `alloc`). The bytes are verified as an MSI
/// before the path is returned, so a caller can never hand msiexec an HTML
/// error page.
/// Where a download reports its byte counts while it runs (T1195). The
/// callback fires on the DOWNLOAD thread after every chunk, so it must not
/// block: the progress panel's implementation is two atomic stores.
///
/// `total` is 0 when the server sent no Content-Length — an honest "unknown",
/// never a guess, because a made-up denominator produces a bar that lies.
pub const Progress = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, received: u64, total: u64) void,

    fn emit(self: Progress, received: u64, total: u64) void {
        self.report(self.ctx, received, total);
    }
};

pub fn download(
    alloc: Allocator,
    url: []const u8,
    version: []const u8,
    progress: ?Progress,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = try stagingDir(arena);
    var name_buf: [512]u8 = undefined;
    const name = try update_apply.stagedName(&name_buf, url, version);
    const dest = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ dir, name });

    const body = try fetch(arena, url, progress);
    if (!update_apply.looksLikeMsi(body)) {
        log.warn("update download: {d} bytes from {s} is not an MSI package", .{ body.len, url });
        return error.NotAPackage;
    }

    const f = try std.fs.cwd().createFile(dest, .{ .truncate = true });
    defer f.close();
    try f.writeAll(body);

    log.info("update download: staged {d} bytes at {s}", .{ body.len, dest });
    return try alloc.dupe(u8, dest);
}

/// Read a URL into memory. `file://` is handled directly — WinINet's
/// `InternetOpenUrlW` rejects it, and it is how the acceptance test serves a
/// canned package without a network.
fn fetch(arena: Allocator, url: []const u8, progress: ?Progress) ![]u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        var path = url["file://".len..];
        if (path.len > 2 and path[0] == '/') path = path[1..]; // file:///C:/…
        const f = std.fs.openFileAbsolute(path, .{}) catch return error.ReadFailed;
        defer f.close();
        const body = f.readToEndAlloc(arena, max_package_bytes) catch return error.ReadFailed;
        // A local file is instantaneous, but it still reports: the acceptance
        // path serves its canned package this way, and a panel that only ever
        // works over the network is a panel nothing on this box can check.
        if (progress) |p| p.emit(body.len, body.len);
        return body;
    }

    const agent = std.unicode.utf8ToUtf16LeStringLiteral("Ghoztty-Update/1.0");
    const inet = w32.InternetOpenW(agent, w32.INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0) orelse
        return error.InternetOpenFailed;
    defer _ = w32.InternetCloseHandle(inet);

    var url_buf: [2048]u16 = undefined;
    if (url.len >= url_buf.len) return error.UrlTooLong;
    const url_len = std.unicode.utf8ToUtf16Le(&url_buf, url) catch return error.UrlTooLong;
    url_buf[url_len] = 0;

    // No INTERNET_FLAG_SECURE: the scheme decides, exactly as the releases-list
    // fetch in App.zig does. The asset URL comes from the same https feed.
    const flags = w32.INTERNET_FLAG_NO_CACHE_WRITE | w32.INTERNET_FLAG_RELOAD;
    const conn = w32.InternetOpenUrlW(inet, @ptrCast(&url_buf), null, 0, flags, 0) orelse
        return error.InternetOpenUrlFailed;
    defer _ = w32.InternetCloseHandle(conn);

    // Content-Length, so the bar can be determinate. A server that will not
    // say leaves this 0 and the panel shows an indeterminate bar — the read
    // loop below is unchanged either way, since the cap is what bounds it.
    const total: u64 = blk: {
        var value: u32 = 0;
        var len: u32 = @sizeOf(u32);
        if (w32.HttpQueryInfoW(
            conn,
            w32.HTTP_QUERY_CONTENT_LENGTH | w32.HTTP_QUERY_FLAG_NUMBER,
            @ptrCast(&value),
            &len,
            null,
        ) == 0) break :blk 0;
        break :blk value;
    };

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(arena);
    if (progress) |p| p.emit(0, total);
    while (body.items.len < max_package_bytes) {
        try body.ensureUnusedCapacity(arena, 256 * 1024);
        const dst = body.unusedCapacitySlice();
        var bytes_read: u32 = 0;
        const want: u32 = @intCast(@min(dst.len, max_package_bytes - body.items.len));
        if (w32.InternetReadFile(conn, dst.ptr, want, &bytes_read) == 0) return error.ReadFailed;
        if (bytes_read == 0) break;
        body.items.len += bytes_read;
        if (progress) |p| p.emit(body.items.len, total);
    }
    return body.items;
}

/// Delete what a previous update left behind: the applier copy, sidelined
/// images, and staged packages. Called at startup, where "still in use" is
/// the normal answer for a holder that has not restarted yet — every failure
/// here is ignored on purpose, and the next launch tries again.
pub fn sweep(alloc: Allocator) void {
    if (comptime builtin.os.tag != .windows) return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Staged packages and the applier copy: everything in the staging dir is
    // ours and disposable once no update is in flight.
    if (stagingDir(arena)) |dir| {
        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return;
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            d.deleteFile(entry.name) catch continue;
        }
    } else |_| {}

    // Sidelined images beside the running exe.
    const exe = internal_os.self_exe.productExePathAlloc(arena) catch return;
    const install_dir = std.fs.path.dirname(exe) orelse return;
    var d = std.fs.cwd().openDir(install_dir, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!update_apply.isSidelined(entry.name)) continue;
        if (d.deleteFile(entry.name)) |_| {
            log.info("update sweep: removed leftover {s}", .{entry.name});
        } else |_| {
            // A holder is still running out of it. Next launch.
        }
    }
}

// =============================================================================
// Arming
// =============================================================================

/// Spawn the applier for a staged package. Returns false when the applier
/// could not be started, which is a REFUSED update rather than a degraded one:
/// unlike the relaunch guard (whose absence only removes a safety net), an
/// applier that never runs while the app quits anyway would close the user's
/// terminal and install nothing.
pub fn arm(alloc: Allocator, msi_path: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return armImpl(alloc, msi_path) catch |err| {
        log.err("update apply: NOT armed err={} (nothing installed, app stays up)", .{err});
        return false;
    };
}

fn armImpl(alloc: Allocator, msi_path: []const u8) !bool {
    const windows = std.os.windows;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exe to relaunch is resolved NOW: after the upgrade there is no app
    // left to ask, and `productExePathAlloc` is the same resolution the
    // relaunch guard and the holder spawn use (and the one that refuses to
    // self-spawn a test binary).
    const exe = try internal_os.self_exe.productExePathAlloc(arena);
    const dir = try stagingDir(arena);
    const applier = try std.fmt.allocPrint(arena, "{s}\\ghoztty-updater.exe", .{dir});

    // A fresh copy every time: an applier left over from a previous update is
    // the OLD build, and the one thing it must be able to do correctly is the
    // choreography this build just wrote.
    std.fs.cwd().deleteFile(applier) catch {};
    try std.fs.copyFileAbsolute(exe, applier, .{});

    const pid = w32.GetCurrentProcessId();
    var spec_buf: [2 * std.fs.max_path_bytes + 32]u8 = undefined;
    const spec = try update_apply.formatSpec(&spec_buf, .{
        .pid = pid,
        .msi = msi_path,
        .exe = exe,
    });

    // The child inherits our environment, so the variable is set on US across
    // the spawn and removed straight after — one call each way, versus
    // rebuilding an entire environment block.
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, env_var);
    const spec_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, spec);
    if (w32.SetEnvironmentVariableW(name_w.ptr, spec_w.ptr) == 0) return error.SetEnvFailed;
    defer _ = w32.SetEnvironmentVariableW(name_w.ptr, null);

    const cmd = try std.fmt.allocPrint(arena, "\"{s}\"", .{applier});
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, cmd);

    // Detached, windowless, and OUT of this app's job object: a job teardown
    // kills every member at once, and an applier that dies with the app it is
    // waiting for installs nothing (T524's lesson, paid for by four production
    // relaunch guards). No CREATE_NEW_PROCESS_GROUP — that flag is inherited
    // all the way down and would disable Ctrl-C in every pane of the
    // relaunched app (T84).
    const spawned = try job_spawn.spawnEscapingJob(
        arena,
        cmd_w.ptr,
        job_spawn.DETACHED_PROCESS | job_spawn.CREATE_NO_WINDOW,
        "update applier",
    );
    const applier_pid = w32.GetProcessId(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hThread);

    log.warn(
        "update apply: ARMED (applier pid {d} waiting on app pid {d}; package {s}; escape={s})",
        .{ applier_pid, pid, msi_path, spawned.tier.name() },
    );
    return true;
}

// =============================================================================
// The applier
// =============================================================================

/// Called from `main` before anything else exists. Null ⇒ this is a normal
/// start; a value ⇒ this process was an applier and `main` must exit with it.
pub fn runFromEnv(alloc: Allocator) ?u8 {
    if (comptime builtin.os.tag != .windows) return null;

    const raw = std.process.getEnvVarOwned(alloc, env_var) catch return null;
    defer alloc.free(raw);
    if (raw.len == 0) return null;

    const spec = update_apply.parseSpec(raw) orelse {
        log.warn("update apply: malformed {s}='{s}'; doing nothing", .{ env_var, raw });
        return 2;
    };
    return run(alloc, spec);
}

fn run(alloc: Allocator, spec: update_apply.Spec) u8 {
    const windows = std.os.windows;
    log.warn("update apply: waiting for app pid {d} to exit", .{spec.pid});

    // A pid we cannot open is a pid that is already gone (or one we may not
    // touch); either way there is nothing to wait for.
    if (OpenProcess(SYNCHRONIZE, windows.FALSE, spec.pid)) |h| {
        defer windows.CloseHandle(h);
        var waited: i64 = 0;
        while (waited < max_app_wait_ms) {
            if (w32.WaitForSingleObject(h, poll_ms) == w32.WAIT_OBJECT_0) break;
            waited += poll_ms;
        } else {
            // Still running after the cap. Installing over a live app would
            // half-replace it; leaving the package staged is recoverable.
            log.err("update apply: app pid {d} still alive after {d}ms; not installing", .{ spec.pid, waited });
            return 1;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An applier running out of the directory it is about to clear would
    // rename ITSELF aside and then relaunch a path that no longer exists —
    // the user's terminal, deleted by its own updater. `arm` always spawns a
    // copy in the staging directory, so this can only be reached by driving
    // the environment variable by hand; it is checked anyway, because the
    // consequence is the one failure this code must never have.
    const install_dir = std.fs.path.dirname(spec.exe);
    if (install_dir) |dir| {
        if (runningInside(arena, dir)) {
            log.err(
                "update apply: refusing to install into {s} — this applier is running from there; " ++
                    "`arm` spawns a copy in the staging directory for exactly this reason",
                .{dir},
            );
            _ = relaunch(arena, spec.exe);
            return 1;
        }
        clearInstallDir(arena, dir);
    }

    const code = runMsiexec(arena, spec.msi);
    if (code == 0) {
        log.warn("update apply: msiexec succeeded", .{});
        std.fs.cwd().deleteFile(spec.msi) catch {};
    } else {
        log.err("update apply: msiexec exited {d}; relaunching the build that was already here", .{code});
    }

    // Relaunch on every path. A failed install must still give the user their
    // terminal back — the worst outcome is the version they already had.
    const relaunched = relaunch(arena, spec.exe);
    return if (code == 0 and relaunched) 0 else 1;
}

/// Rename any image msiexec cannot overwrite out of the way. See the module
/// header: the alternative is killing the user's PTY holders.
fn clearInstallDir(arena: Allocator, install_dir: []const u8) void {
    const stamp: u64 = @intCast(@max(0, std.time.timestamp()));
    for (install_images) |name| {
        const path = std.fmt.allocPrint(arena, "{s}\\{s}", .{ install_dir, name }) catch continue;
        if (!isLocked(path)) continue;
        var side_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const side = update_apply.sidelineName(&side_buf, path, stamp) catch continue;
        if (std.fs.renameAbsolute(path, side)) |_| {
            log.warn("update apply: {s} is in use; renamed it aside so msiexec can write a fresh one", .{name});
        } else |err| {
            log.err("update apply: {s} is in use and could not be renamed ({}); the install may need a reboot", .{ name, err });
        }
    }
}

/// True if THIS process's image lives in `dir`. `selfExePathAlloc` rather than
/// `productExePathAlloc`: the question is where the running bytes are, not
/// which product they belong to. Compared case-insensitively, because Windows
/// paths are.
fn runningInside(arena: Allocator, dir: []const u8) bool {
    const self_path = std.fs.selfExePathAlloc(arena) catch return false;
    const self_dir = std.fs.path.dirname(self_path) orelse return false;
    return std.ascii.eqlIgnoreCase(self_dir, dir);
}

/// True if the file cannot be opened for writing — which, for a file in
/// INSTALLDIR, means a process is running that image. A file that does not
/// exist is not locked (msiexec will simply create it).
fn isLocked(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    f.close();
    return false;
}

/// Run msiexec and return its exit code (or a non-zero stand-in when it could
/// not be run or did not finish).
fn runMsiexec(arena: Allocator, msi_path: []const u8) u32 {
    const windows = std.os.windows;

    const dir = std.fs.path.dirname(msi_path) orelse ".";
    const log_path = std.fmt.allocPrint(arena, "{s}\\install.log", .{dir}) catch return 1602;

    var cmd_buf: [2 * std.fs.max_path_bytes + 128]u8 = undefined;
    const cmd = update_apply.msiexecCommandLine(&cmd_buf, msi_path, log_path) catch return 1602;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(arena, cmd) catch return 1602;

    log.warn("update apply: {s}", .{cmd});

    // msiexec must not join a job that could take it down mid-install, for the
    // same reason the applier itself escaped one.
    const spawned = job_spawn.spawnEscapingJob(arena, cmd_w.ptr, 0, "msiexec") catch |err| {
        log.err("update apply: could not start msiexec err={}", .{err});
        return 1601;
    };
    defer windows.CloseHandle(spawned.pi.hProcess);
    defer windows.CloseHandle(spawned.pi.hThread);

    if (w32.WaitForSingleObject(spawned.pi.hProcess, max_msiexec_ms) != w32.WAIT_OBJECT_0) {
        log.err("update apply: msiexec did not finish within {d}ms", .{max_msiexec_ms});
        return 1618; // ERROR_INSTALL_ALREADY_RUNNING, the closest true thing.
    }
    var code: u32 = 1603;
    if (GetExitCodeProcess(spawned.pi.hProcess, &code) == 0) return 1603;
    // 3010 is "success, a reboot would be nice" — not a failure, and with
    // /norestart the only way the user hears about it at all.
    if (code == 3010) return 0;
    return code;
}

fn relaunch(arena: Allocator, exe: []const u8) bool {
    const windows = std.os.windows;

    // The relaunched app must NOT be an applier in turn.
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(arena, env_var) catch return false;
    _ = w32.SetEnvironmentVariableW(name_w.ptr, null);

    const cmd = std.fmt.allocPrint(arena, "\"{s}\"", .{exe}) catch return false;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(arena, cmd) catch return false;

    const spawned = job_spawn.spawnEscapingJob(arena, cmd_w.ptr, job_spawn.DETACHED_PROCESS, "update relaunch") catch {
        log.err("update apply: relaunch of {s} FAILED", .{exe});
        return false;
    };
    const pid = w32.GetProcessId(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hThread);
    log.warn("update apply: relaunched {s} as pid {d} (escape={s})", .{ exe, pid, spawned.tier.name() });
    return true;
}

const SYNCHRONIZE: std.os.windows.DWORD = 0x00100000;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: std.os.windows.HANDLE,
    lpExitCode: *u32,
) callconv(.winapi) std.os.windows.BOOL;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the staging directory is per lineage" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dir = try stagingDir(arena.allocator());
    try testing.expect(std.mem.indexOf(u8, dir, "\\ghoztty\\") != null);
    if (build_config.is_debug) {
        try testing.expect(std.mem.endsWith(u8, dir, "updates-debug"));
    } else {
        try testing.expect(std.mem.endsWith(u8, dir, "\\updates"));
    }
}

test "isLocked says no for a file that is not there" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expect(!isLocked("C:\\this\\path\\does\\not\\exist\\ghoztty.exe"));
}

test "every image an update replaces is considered for sidelining" {
    // The list is the contract with dist/windows-installer/build-msi.sh: the
    // three files it puts in INSTALLDIR are the three that can be locked.
    try testing.expectEqual(@as(usize, 3), install_images.len);
    for ([_][]const u8{ "ghoztty.exe", "ghoztty.com", "ghoztty-agent.exe" }) |want| {
        var found = false;
        for (install_images) |got| {
            if (std.mem.eql(u8, got, want)) found = true;
        }
        try testing.expect(found);
    }
}
