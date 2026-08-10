//! Spawning a process that must OUTLIVE this one — i.e. escaping the Windows
//! job object this process sits in.
//!
//! Extracted from `relaunch_guard.zig` (T524) so the local agent can use the
//! same escape (T426). The two callers want the identical thing and for the
//! identical reason: a child joins its parent's job by default, this box's jobs
//! are kill-on-close, and a job teardown kills every member at once. A
//! supervisor that shares its subject's fate supervises nothing, and a daemon
//! that shares the app's fate is not a daemon. `DETACHED_PROCESS` does not
//! leave a job; only the tiers below do.
//!
//!  1. `CREATE_BREAKAWAY_FROM_JOB` — the clean escape, a no-op for a jobless
//!     caller. Refused with ACCESS_DENIED when ANY job in the caller's chain
//!     forbids breakaway — which is the MEASURED reality on this box (the
//!     pane-shell job chain refuses it; verified live 2026-08-06), so this
//!     tier alone would have fixed nothing.
//!  2. Parent-process hop: spawn with `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`
//!     pointing at the shell (explorer). Job membership follows the ACTUAL
//!     parent used for inheritance, so the child lands in the shell's (safe)
//!     job context instead of ours — no breakaway permission involved. The
//!     environment is passed EXPLICITLY, because with a spoofed parent the
//!     child would otherwise be handed the SHELL's environment, and both
//!     callers carry meaning in theirs (the guard's spec variable; the agent's
//!     test seams and `LOCALAPPDATA`).
//!  3. Inside the job, loudly: degraded, never absent. A jailed child still
//!     covers every death that is not a job teardown.
//!
//! Which tier fired is returned as well as logged, because "the child escaped"
//! and "the child is jailed with us" are different states and the next
//! incident's log has to say which one it had.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oswin = @import("../../os/windows.zig");

const log = std.log.scoped(.win32_job_spawn);

pub const DETACHED_PROCESS: std.os.windows.DWORD = 0x00000008;
pub const CREATE_NEW_PROCESS_GROUP: std.os.windows.DWORD = 0x00000200;
pub const CREATE_NO_WINDOW: std.os.windows.DWORD = 0x08000000;
pub const CREATE_BREAKAWAY_FROM_JOB: std.os.windows.DWORD = 0x01000000;

const PROCESS_CREATE_PROCESS: std.os.windows.DWORD = 0x0080;
/// ProcThreadAttributeValue(ProcThreadAttributeParentProcess=0, false, true, false)
const PROC_THREAD_ATTRIBUTE_PARENT_PROCESS: std.os.windows.DWORD = 0x00020000;

/// How the child got out — or that it did not.
pub const Tier = enum {
    /// `CREATE_BREAKAWAY_FROM_JOB` was accepted: the child is in no job of ours.
    breakaway,
    /// The shell adopted it, so it is in the shell's job context, not ours.
    shell_parent,
    /// Still inside our job: a teardown that kills us kills it too.
    in_job,

    /// One word for a log line. `escaped` is deliberately NOT collapsed into a
    /// bool — a reader wants to know which mechanism, so the next incident can
    /// be told apart from this one.
    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .breakaway => "breakaway",
            .shell_parent => "shell-parent",
            .in_job => "IN-JOB (degraded)",
        };
    }

    pub fn escaped(self: Tier) bool {
        return self != .in_job;
    }
};

pub const Spawned = struct {
    pi: std.os.windows.PROCESS_INFORMATION,
    tier: Tier,
};

/// Spawn `cmd_w` with `base` flags, escaping the caller's job object if it can.
/// `tag` prefixes every log line so two callers' trails stay tellable apart.
///
/// The caller owns `pi.hProcess`/`pi.hThread` and must close them.
pub fn spawnEscapingJob(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
) !Spawned {
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
    ) != 0) return .{ .pi = pi, .tier = .breakaway };

    const breakaway_err = windows.kernel32.GetLastError();
    log.warn(
        "{s}: breakaway spawn refused err={}; trying the shell-parent hop",
        .{ tag, breakaway_err },
    );

    if (spawnViaShellParent(arena, cmd_w, base, tag)) |shell_pi| {
        return .{ .pi = shell_pi, .tier = .shell_parent };
    } else |err| {
        log.warn(
            "{s}: shell-parent spawn unavailable err={}; spawning INSIDE the job (a job teardown that kills us kills this child too)",
            .{ tag, err },
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
    ) != 0) return .{ .pi = pi, .tier = .in_job };

    log.warn("{s}: CreateProcessW failed err={}", .{ tag, windows.kernel32.GetLastError() });
    return error.SpawnFailed;
}

/// Tier 2: create the child with the SHELL (explorer) as its inheritance
/// parent, which places it in the shell's job context rather than ours. Every
/// failure here is an error return, never fatal — the caller falls back.
fn spawnViaShellParent(
    arena: Allocator,
    cmd_w: [*:0]u16,
    base: std.os.windows.DWORD,
    tag: []const u8,
) !std.os.windows.PROCESS_INFORMATION {
    const windows = std.os.windows;

    const shell_hwnd = GetShellWindow() orelse return error.NoShellWindow;
    var shell_pid: windows.DWORD = 0;
    _ = GetWindowThreadProcessId(shell_hwnd, &shell_pid);
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

    // A spoofed parent would otherwise donate the SHELL's environment to the
    // child, so pass ours explicitly.
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
        log.warn("{s}: shell-parent CreateProcessW failed err={}", .{ tag, windows.kernel32.GetLastError() });
        return error.ShellSpawnFailed;
    }
    log.info("{s}: escaped the job via shell-parent spawn (parent pid {d})", .{ tag, shell_pid });
    return pi;
}

extern "user32" fn GetShellWindow() callconv(.winapi) ?std.os.windows.HWND;
extern "user32" fn GetWindowThreadProcessId(
    hWnd: std.os.windows.HWND,
    lpdwProcessId: ?*std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.DWORD;
extern "kernel32" fn OpenProcess(
    dwDesiredAccess: std.os.windows.DWORD,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: std.os.windows.DWORD,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
extern "kernel32" fn FreeEnvironmentStringsW(penv: [*]u16) callconv(.winapi) std.os.windows.BOOL;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a tier reports whether the child actually got out" {
    try testing.expect(Tier.breakaway.escaped());
    try testing.expect(Tier.shell_parent.escaped());
    try testing.expect(!Tier.in_job.escaped());
}

test "every tier names itself for the log" {
    // The in-job name must READ as the bad case: a log reader scanning for why
    // a daemon died with the app has to see it without decoding an enum.
    try testing.expectEqualStrings("breakaway", Tier.breakaway.name());
    try testing.expectEqualStrings("shell-parent", Tier.shell_parent.name());
    try testing.expect(std.mem.indexOf(u8, Tier.in_job.name(), "IN-JOB") != null);
}
