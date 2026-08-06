//! A supervisor for the one window of time in which the app is allowed to
//! disappear: the destructive agent refresh (T421, after T229).
//!
//! The mandatory confirmation promises the panes come back. Twice now — T229's
//! two occurrences and again on 2026-08-03 — the user consented and the app
//! simply ended: no crash record, no further log line, no windows, and nothing
//! that would ever bring it back. The user relaunched Ghoztty by hand fourteen
//! minutes later.
//!
//! T229 attacked the cause and could not reproduce it in four shapes. This
//! module attacks the OUTCOME instead, which is the half the user actually
//! feels: whatever kills the app between "I confirmed" and "my panes are back",
//! something outside that process must notice and start it again.
//!
//! Shape: before the destructive step the app ARMS the guard —
//!
//!  1. writes a marker file (its own pid + the exe to relaunch), then
//!  2. spawns a detached copy of `ghoztty.exe` carrying
//!     `GHOZTTY_RELAUNCH_GUARD=<pid>|<marker>|<exe>` in its environment.
//!
//! That copy is not a terminal: `runFromEnv` sees the variable before any app
//! state exists, waits on the armed pid, and exits. If the app clears the marker
//! (a refresh that finished, however it finished) the guard exits quietly. If
//! the app's process ENDS while the marker is still there, the guard relaunches
//! it and then removes the marker.
//!
//! Deliberate properties:
//!
//! - **The window is seconds wide.** The marker exists only across
//!   `restartForUpgrade` + the in-place rebuild, so a user who quits Ghoztty
//!   deliberately is not fighting a relaunch — they would have to quit inside
//!   that window.
//! - **It relaunches at most once.** The guard exits after spawning, and the
//!   relaunched app does not inherit the variable, so a crash loop cannot be
//!   manufactured out of this.
//! - **It cannot outlive its purpose.** `max_wait_ms` caps the whole watch.
//! - **No `CREATE_NEW_PROCESS_GROUP`.** That flag is inherited by every
//!   descendant and disables Ctrl-C for all of them (T84) — a relaunched app
//!   whose panes ignore ^C would be a worse bug than the one being fixed.
//! - **It breaks out of the app's job object** (T524). A child joins its
//!   parent's job by default, and a job teardown kills every member at once —
//!   which is how four production guards died WITH the app they were
//!   watching, before executing one instruction. A supervisor that shares its
//!   subject's fate supervises nothing. `spawnEscapingJob` escapes in tiers:
//!   `CREATE_BREAKAWAY_FROM_JOB`, then a shell-parent hop for the job chains
//!   that refuse breakaway (this box's do), then in-job as a loud last
//!   resort.
//! - **No new CLI surface.** It is an environment variable, not a `+verb`:
//!   `ghoztty`'s command set stays identical on both platforms (CLAUDE.md's
//!   standing rule), and the same variable is available to the Mac seat when it
//!   wires the equivalent (T427).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const build_config = @import("../../build_config.zig");
const oswin = @import("../../os/windows.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_relaunch_guard);

/// The environment variable that turns a `ghoztty.exe` start into a guard.
pub const env_var = "GHOZTTY_RELAUNCH_GUARD";

/// Field separator inside the variable. Neither a Windows path nor a decimal
/// pid can contain it, so no escaping is needed.
const sep = '|';

/// Hard cap on a guard's life. Far above the refresh (seconds) and low enough
/// that a guard whose app hangs forever still goes away.
const max_wait_ms: i64 = 10 * std.time.ms_per_min;

/// How long each wait slice is, i.e. how often a disarm is noticed.
const poll_ms: u32 = 500;

pub const Spec = struct {
    /// The app process to watch.
    pid: u32,
    /// The file whose EXISTENCE at exit time means "relaunch".
    marker: []const u8,
    /// The binary to relaunch.
    exe: []const u8,
};

/// `<pid>|<marker>|<exe>` into `buf`.
pub fn formatSpec(buf: []u8, spec: Spec) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}{c}{s}{c}{s}", .{
        spec.pid, sep, spec.marker, sep, spec.exe,
    });
}

/// The inverse. Null for anything malformed — a guard that cannot read its own
/// orders must do nothing at all, never guess a pid or a path.
pub fn parseSpec(raw: []const u8) ?Spec {
    const a = std.mem.indexOfScalar(u8, raw, sep) orelse return null;
    const rest = raw[a + 1 ..];
    const b = std.mem.indexOfScalar(u8, rest, sep) orelse return null;

    const pid = std.fmt.parseInt(u32, raw[0..a], 10) catch return null;
    if (pid == 0) return null;
    const marker = rest[0..b];
    const exe = rest[b + 1 ..];
    if (marker.len == 0 or exe.len == 0) return null;
    return .{ .pid = pid, .marker = marker, .exe = exe };
}

/// The whole decision the guard makes, isolated from the syscalls that feed it
/// so it can be tested without a process to kill.
///
/// `app_exited` — the watched pid is gone. `marker_present` — the app never
/// reported the refresh finished. Only both together mean the app died inside
/// the window it promised to come out of.
pub fn shouldRelaunch(app_exited: bool, marker_present: bool) bool {
    return app_exited and marker_present;
}

/// `%LOCALAPPDATA%\ghoztty\agent-refresh[-debug].marker` — per lineage, like
/// every other bit of app state, so a debug run can never arm a guard that
/// relaunches the user's installed release.
pub fn markerPath(arena: Allocator) ![]const u8 {
    const name = if (build_config.is_debug)
        "agent-refresh-debug.marker"
    else
        "agent-refresh.marker";
    const local = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch return error.NoLocalAppData;
    return std.fmt.allocPrint(arena, "{s}\\ghoztty\\{s}", .{ local, name });
}

/// A live arming. `disarm` is idempotent and must run on every path out of the
/// refresh — including the failure paths, which is exactly when the app is most
/// likely to still be alive and NOT want relaunching.
pub const Armed = struct {
    alloc: Allocator,
    marker: []const u8,

    pub fn disarm(self: *Armed) void {
        std.fs.cwd().deleteFile(self.marker) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("relaunch guard: could not remove marker {s} err={}", .{ self.marker, err }),
        };
        log.info("relaunch guard: disarmed", .{});
        self.alloc.free(self.marker);
        self.marker = &.{};
    }
};

/// Write the marker and spawn the watcher. Null when the guard could not be
/// armed — that is a degraded refresh, never a blocked one: the refresh is what
/// the user asked for, and refusing it because a supervisor would not start
/// trades a rare failure for a certain one.
pub fn arm(alloc: Allocator) ?Armed {
    if (comptime builtin.os.tag != .windows) return null;
    return armImpl(alloc) catch |err| {
        log.warn("relaunch guard: NOT armed err={} (the refresh proceeds unsupervised)", .{err});
        return null;
    };
}

fn armImpl(alloc: Allocator) !Armed {
    const windows = std.os.windows;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try std.fs.selfExePathAlloc(arena);
    const marker = try markerPath(arena);
    if (std.fs.path.dirname(marker)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const pid = w32.GetCurrentProcessId();

    // Content is for a human reading the box afterwards; the guard keys on the
    // file EXISTING, never on what is in it.
    {
        const f = try std.fs.cwd().createFile(marker, .{ .truncate = true });
        defer f.close();
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "pid={d}\nexe={s}\n", .{ pid, exe });
        try f.writeAll(line);
    }
    errdefer std.fs.cwd().deleteFile(marker) catch {};

    var spec_buf: [2 * std.fs.max_path_bytes + 32]u8 = undefined;
    const spec = try formatSpec(&spec_buf, .{ .pid = pid, .marker = marker, .exe = exe });

    // The child inherits our environment, so the variable is set on US for the
    // duration of the spawn and removed immediately after. Building a private
    // environment block would mean duplicating every other variable a pane
    // needs; this is one call each way.
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, env_var);
    const spec_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, spec);
    if (w32.SetEnvironmentVariableW(name_w.ptr, spec_w.ptr) == 0) return error.SetEnvFailed;
    defer _ = w32.SetEnvironmentVariableW(name_w.ptr, null);

    const cmd = try std.fmt.allocPrint(arena, "\"{s}\"", .{exe});
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, cmd);

    // Detached and windowless, but NOT a new process group: that flag is
    // inherited all the way down and would kill Ctrl-C in every pane of the
    // relaunched app (T84).
    const pi = try spawnEscapingJob(arena, cmd_w.ptr, DETACHED_PROCESS | CREATE_NO_WINDOW);
    const guard_pid = w32.GetProcessId(pi.hProcess);
    windows.CloseHandle(pi.hProcess);
    windows.CloseHandle(pi.hThread);

    log.info(
        "relaunch guard: ARMED (guard pid {d} watching app pid {d}; marker {s})",
        .{ guard_pid, pid, marker },
    );
    return .{ .alloc = alloc, .marker = try alloc.dupe(u8, marker) };
}

/// Called from `main` before anything else exists. Null ⇒ this is a normal
/// start; a value ⇒ this process was a guard and `main` must exit with it.
pub fn runFromEnv(alloc: Allocator) ?u8 {
    if (comptime builtin.os.tag != .windows) return null;

    const raw = std.process.getEnvVarOwned(alloc, env_var) catch return null;
    defer alloc.free(raw);
    if (raw.len == 0) return null;

    const spec = parseSpec(raw) orelse {
        log.warn("relaunch guard: malformed {s}='{s}'; doing nothing", .{ env_var, raw });
        return 2;
    };
    return run(alloc, spec);
}

fn run(alloc: Allocator, spec: Spec) u8 {
    const windows = std.os.windows;
    log.info(
        "relaunch guard: watching app pid {d} (marker {s})",
        .{ spec.pid, spec.marker },
    );

    // A pid we cannot open is a pid that is already gone (or one we may not
    // touch); either way there is nothing left to wait for, so fall straight
    // through to the marker check.
    const h: ?windows.HANDLE = OpenProcess(SYNCHRONIZE, windows.FALSE, spec.pid);
    defer if (h) |handle| windows.CloseHandle(handle);

    var waited_ms: i64 = 0;
    var exited = h == null;
    while (!exited) {
        if (!markerPresent(spec.marker)) {
            log.info("relaunch guard: marker cleared, app pid {d} is fine; exiting", .{spec.pid});
            return 0;
        }
        if (waited_ms >= max_wait_ms) {
            log.warn(
                "relaunch guard: gave up after {d}ms with app pid {d} still alive",
                .{ waited_ms, spec.pid },
            );
            return 0;
        }
        const r = w32.WaitForSingleObject(h.?, poll_ms);
        if (r == w32.WAIT_OBJECT_0) {
            exited = true;
            break;
        }
        waited_ms += poll_ms;
    }

    // Re-read rather than trusting the last poll: the app may have finished the
    // refresh and exited for an unrelated reason (a user quit) in the same
    // instant.
    const marker_present = markerPresent(spec.marker);
    if (!shouldRelaunch(exited, marker_present)) {
        log.info("relaunch guard: app pid {d} ended with the marker cleared; nothing to do", .{spec.pid});
        return 0;
    }

    log.warn(
        "relaunch guard: app pid {d} ENDED during the agent refresh; relaunching {s}",
        .{ spec.pid, spec.exe },
    );
    const ok = relaunch(alloc, spec.exe);
    std.fs.cwd().deleteFile(spec.marker) catch {};
    return if (ok) 0 else 1;
}

const DETACHED_PROCESS: std.os.windows.DWORD = 0x00000008;
const CREATE_NO_WINDOW: std.os.windows.DWORD = 0x08000000;
const CREATE_BREAKAWAY_FROM_JOB: std.os.windows.DWORD = 0x01000000;
const PROCESS_CREATE_PROCESS: std.os.windows.DWORD = 0x0080;
/// ProcThreadAttributeValue(ProcThreadAttributeParentProcess=0, false, true, false)
const PROC_THREAD_ATTRIBUTE_PARENT_PROCESS: std.os.windows.DWORD = 0x00020000;

/// Spawn `cmd_w` detached, ESCAPING the caller's job object.
///
/// T524: a child joins its parent's job by default, and this box's jobs are
/// kill-on-close — in all four production incidents the guard died WITH the
/// app, before executing one instruction, which is why the T421 guard never
/// fired outside its harness. `DETACHED_PROCESS` does not leave a job. Three
/// tiers, each logged so the next incident says which guard it had:
///
///  1. `CREATE_BREAKAWAY_FROM_JOB` — the clean escape, a no-op for a jobless
///     caller. Refused with ACCESS_DENIED when ANY job in the caller's chain
///     forbids breakaway — which is the MEASURED reality on this box (the
///     pane-shell job chain refuses it; verified live 2026-08-06), so this
///     tier alone would have fixed nothing.
///  2. Parent-process hop: spawn with `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`
///     pointing at the shell (explorer). Job membership follows the ACTUAL
///     parent used for inheritance, so the child lands in the shell's (safe)
///     job context instead of ours — no breakaway permission involved. The
///     environment is passed EXPLICITLY, because with a spoofed parent the
///     spec-carrying variable would otherwise be read from the wrong process.
///  3. Inside the job, loudly: a jailed guard is degraded (a job teardown
///     still takes it down with the app), never absent — it still covers
///     every death that is not a job teardown.
fn spawnEscapingJob(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
) !std.os.windows.PROCESS_INFORMATION {
    const windows = std.os.windows;

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    if (oswin.exp.kernel32.CreateProcessW(
        null,
        cmd_w,
        null,
        null,
        windows.FALSE,
        base | CREATE_BREAKAWAY_FROM_JOB,
        null,
        null,
        &si,
        &pi,
    ) != 0) return pi;

    const breakaway_err = windows.kernel32.GetLastError();
    log.warn(
        "relaunch guard: breakaway spawn refused err={}; trying the shell-parent hop",
        .{breakaway_err},
    );

    if (spawnViaShellParent(arena, cmd_w, base)) |shell_pi| {
        return shell_pi;
    } else |err| {
        log.warn(
            "relaunch guard: shell-parent spawn unavailable err={}; spawning INSIDE the job (a job teardown that kills the app kills this child too)",
            .{err},
        );
    }

    if (oswin.exp.kernel32.CreateProcessW(
        null,
        cmd_w,
        null,
        null,
        windows.FALSE,
        base,
        null,
        null,
        &si,
        &pi,
    ) != 0) return pi;

    log.warn("relaunch guard: CreateProcessW failed err={}", .{windows.kernel32.GetLastError()});
    return error.SpawnFailed;
}

/// Tier 2: create the child with the SHELL (explorer) as its inheritance
/// parent, which places it in the shell's job context rather than ours. Every
/// failure here is an error return, never fatal — the caller falls back.
fn spawnViaShellParent(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
) !std.os.windows.PROCESS_INFORMATION {
    const windows = std.os.windows;

    const shell_hwnd = GetShellWindow() orelse return error.NoShellWindow;
    var shell_pid: windows.DWORD = 0;
    _ = w32.GetWindowThreadProcessId(shell_hwnd, &shell_pid);
    if (shell_pid == 0) return error.NoShellWindow;

    const parent = OpenProcess(PROCESS_CREATE_PROCESS, windows.FALSE, shell_pid) orelse
        return error.OpenShellDenied;
    defer windows.CloseHandle(parent);

    var attr_size: windows.SIZE_T = 0;
    _ = oswin.exp.kernel32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try arena.alloc(u8, attr_size);
    if (oswin.exp.kernel32.InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0)
        return error.AttrListFailed;
    var parent_handle: windows.HANDLE = parent;
    if (oswin.exp.kernel32.UpdateProcThreadAttribute(
        attr_buf.ptr,
        0,
        PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
        @ptrCast(&parent_handle),
        @sizeOf(windows.HANDLE),
        null,
        null,
    ) == 0) return error.AttrListFailed;

    // The spec travels in OUR environment; a spoofed parent would hand the
    // child the SHELL's environment instead, so pass ours explicitly.
    const env = GetEnvironmentStringsW() orelse return error.NoEnvironment;
    defer _ = FreeEnvironmentStringsW(env);

    var siex: oswin.exp.STARTUPINFOEX = .{
        .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
        .lpAttributeList = attr_buf.ptr,
    };
    siex.StartupInfo.cb = @sizeOf(oswin.exp.STARTUPINFOEX);

    var pi: windows.PROCESS_INFORMATION = undefined;
    if (oswin.exp.kernel32.CreateProcessW(
        null,
        cmd_w,
        null,
        null,
        windows.FALSE,
        base | oswin.exp.EXTENDED_STARTUPINFO_PRESENT | oswin.exp.CREATE_UNICODE_ENVIRONMENT,
        env,
        null,
        &siex.StartupInfo,
        &pi,
    ) == 0) {
        log.warn("relaunch guard: shell-parent CreateProcessW failed err={}", .{windows.kernel32.GetLastError()});
        return error.ShellSpawnFailed;
    }
    log.info("relaunch guard: escaped the job via shell-parent spawn (parent pid {d})", .{shell_pid});
    return pi;
}

extern "user32" fn GetShellWindow() callconv(.winapi) ?std.os.windows.HWND;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW(penv: [*]u16) callconv(.winapi) std.os.windows.BOOL;

fn markerPresent(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn relaunch(alloc: Allocator, exe: []const u8) bool {
    const windows = std.os.windows;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The relaunched app must NOT be a guard in turn.
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(arena, env_var) catch return false;
    _ = w32.SetEnvironmentVariableW(name_w.ptr, null);

    const cmd = std.fmt.allocPrint(arena, "\"{s}\"", .{exe}) catch return false;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(arena, cmd) catch return false;

    const pi = spawnEscapingJob(arena, cmd_w.ptr, DETACHED_PROCESS) catch {
        log.err("relaunch guard: relaunch of {s} FAILED", .{exe});
        return false;
    };
    const pid = w32.GetProcessId(pi.hProcess);
    windows.CloseHandle(pi.hProcess);
    windows.CloseHandle(pi.hThread);
    log.warn("relaunch guard: relaunched {s} as pid {d}", .{ exe, pid });
    return true;
}

const SYNCHRONIZE: std.os.windows.DWORD = 0x00100000;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "formatSpec and parseSpec round-trip a real Windows path" {
    var buf: [512]u8 = undefined;
    const s = try formatSpec(&buf, .{
        .pid = 41416,
        .marker = "C:\\Users\\David\\AppData\\Local\\ghoztty\\agent-refresh.marker",
        .exe = "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe",
    });
    const p = parseSpec(s).?;
    try testing.expectEqual(@as(u32, 41416), p.pid);
    try testing.expectEqualStrings("C:\\Users\\David\\AppData\\Local\\ghoztty\\agent-refresh.marker", p.marker);
    try testing.expectEqualStrings("C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty.exe", p.exe);
}

test "parseSpec keeps a path that contains spaces intact" {
    var buf: [512]u8 = undefined;
    const s = try formatSpec(&buf, .{
        .pid = 7,
        .marker = "C:\\Program Files\\a b\\m.marker",
        .exe = "C:\\Program Files\\Gho ztty\\ghoztty.exe",
    });
    const p = parseSpec(s).?;
    try testing.expectEqualStrings("C:\\Program Files\\a b\\m.marker", p.marker);
    try testing.expectEqualStrings("C:\\Program Files\\Gho ztty\\ghoztty.exe", p.exe);
}

test "parseSpec refuses anything it cannot read exactly" {
    // A guard that misreads its orders would wait on the wrong pid and relaunch
    // the wrong binary, so every one of these must be a no-op.
    try testing.expect(parseSpec("") == null);
    try testing.expect(parseSpec("41416") == null);
    try testing.expect(parseSpec("41416|C:\\m.marker") == null);
    try testing.expect(parseSpec("|C:\\m.marker|C:\\a.exe") == null);
    try testing.expect(parseSpec("abc|C:\\m.marker|C:\\a.exe") == null);
    try testing.expect(parseSpec("-1|C:\\m.marker|C:\\a.exe") == null);
    // Pid 0 is "the whole system idle process"; never a thing to wait on.
    try testing.expect(parseSpec("0|C:\\m.marker|C:\\a.exe") == null);
    try testing.expect(parseSpec("7||C:\\a.exe") == null);
    try testing.expect(parseSpec("7|C:\\m.marker|") == null);
}

test "shouldRelaunch fires only when the app ended inside the window" {
    // The bug: the app ended and never cleared the marker.
    try testing.expect(shouldRelaunch(true, true));
    // A refresh that finished. The app may then exit for any reason it likes.
    try testing.expect(!shouldRelaunch(true, false));
    // Still running: nothing to do either way.
    try testing.expect(!shouldRelaunch(false, true));
    try testing.expect(!shouldRelaunch(false, false));
}

test "markerPath is per lineage so a debug run cannot relaunch the release" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try markerPath(arena.allocator());
    try testing.expect(std.mem.endsWith(u8, p, ".marker"));
    try testing.expect(std.mem.indexOf(u8, p, "\\ghoztty\\") != null);
    if (build_config.is_debug) {
        try testing.expect(std.mem.endsWith(u8, p, "agent-refresh-debug.marker"));
    } else {
        try testing.expect(std.mem.endsWith(u8, p, "\\agent-refresh.marker"));
    }
}

test "the guard is armed with a spec long enough for two max-length paths" {
    // `armImpl`'s stack buffer must hold the formatted spec for the deepest
    // paths Windows will hand us; a truncating bufPrint there would arm a guard
    // pointing at a chopped path.
    var buf: [2 * std.fs.max_path_bytes + 32]u8 = undefined;
    const long = "C:\\" ++ ("d" ** 200);
    const s = try formatSpec(&buf, .{ .pid = 4294967295, .marker = long, .exe = long });
    const p = parseSpec(s).?;
    try testing.expectEqual(@as(u32, 4294967295), p.pid);
    try testing.expectEqualStrings(long, p.exe);
}
