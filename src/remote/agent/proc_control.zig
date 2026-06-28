//! Process *kill* for the remote machine activity monitor (§9.3 process view,
//! increment 4). The read-only enumeration lives in `proc.zig`; the spawn half
//! lives in `proc_spawn.zig` (it needs the GUI-free `CommandCore` spawn core, so
//! it is kept separate to keep THIS file dependency-free — `std` only — so it can
//! be pulled into the client's transport graph via `server.zig` without dragging
//! `CommandCore`/`pty` into a module rooted at `src/remote/`).
//!
//! `killProc` is pure of any session-store state — it touches only the OS — so the
//! agent calls it UNLOCKED (the `handleGetCwd` discipline). The same function
//! backs the in-process LOCAL provider in `apprt/embedded.zig`.
//!
//! ## Kill semantics
//! POSIX honors the requested signal (default TERM; "KILL" ⇒ SIGKILL). Windows has
//! NO real SIGTERM: a graceful console-ctrl path is unreliable cross-session, so
//! for v1 BOTH "TERM" and "KILL" map to `TerminateProcess(h, 1)`. Access-denied /
//! no-such-pid is surfaced as `{ok=false, error}` (never a crash).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Result of `killProc`. `@"error"` is a static string literal (never owned) so
/// the caller never frees it.
pub const ProcKillOutcome = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
};

/// Terminate the process `pid` with the named `signal` (null/"TERM" ⇒ graceful
/// terminate, "KILL" ⇒ forceful). Returns `{ok, error?}`; an OS failure
/// (no-such-pid / access denied) is surfaced as `{ok=false, error}` rather than a
/// crash. See the module doc for the Windows TERM==KILL caveat.
pub fn killProc(pid: i64, signal: ?[]const u8) ProcKillOutcome {
    if (pid <= 0) return .{ .ok = false, .@"error" = "invalid pid" };
    return switch (builtin.os.tag) {
        .windows => killWindows(pid),
        .macos, .linux => killPosix(pid, signal),
        else => .{ .ok = false, .@"error" = "unsupported platform" },
    };
}

fn killPosix(pid: i64, signal: ?[]const u8) ProcKillOutcome {
    if (builtin.os.tag == .windows) return .{ .ok = false, .@"error" = "unsupported" };
    // Default to TERM; only an explicit "KILL" escalates to SIGKILL. (Escalation
    // TERM→KILL-after-deadline is a v2 nicety.)
    const sig: u8 = blk: {
        if (signal) |s| {
            if (std.ascii.eqlIgnoreCase(s, "KILL")) break :blk posix.SIG.KILL;
        }
        break :blk posix.SIG.TERM;
    };
    posix.kill(@intCast(pid), sig) catch |err| return .{
        .ok = false,
        // Map the common cases to a stable string; everything else gets the
        // error name (still a static literal, never owned).
        .@"error" = switch (err) {
            error.ProcessNotFound => "no such process",
            error.PermissionDenied => "permission denied",
            else => @errorName(err),
        },
    };
    return .{ .ok = true };
}

fn killWindows(pid: i64) ProcKillOutcome {
    if (builtin.os.tag != .windows) return .{ .ok = false, .@"error" = "unsupported" };
    const w = windows;
    const W = std.os.windows;

    // OpenProcess with PROCESS_TERMINATE. A failure here is access-denied or a
    // vanished pid; surface it rather than crash.
    const h = w.OpenProcess(w.PROCESS_TERMINATE, 0, @intCast(pid)) orelse {
        // GetLastError distinguishes the two common cases for a useful message.
        const e = W.kernel32.GetLastError();
        return .{
            .ok = false,
            .@"error" = switch (e) {
                .ACCESS_DENIED => "permission denied",
                .INVALID_PARAMETER => "no such process",
                else => "OpenProcess failed",
            },
        };
    };
    defer W.CloseHandle(h);

    // Windows has no real SIGTERM; "TERM" and "KILL" both TerminateProcess (exit
    // code 1). See the module doc.
    if (w.TerminateProcess(h, 1) == 0) {
        return .{ .ok = false, .@"error" = "TerminateProcess failed" };
    }
    return .{ .ok = true };
}

// =============================================================================
// Windows — kill externs not in std.os.windows (compiled only on Windows)
// =============================================================================

const windows = struct {
    const W = std.os.windows;
    const BOOL = W.BOOL;
    const DWORD = W.DWORD;
    const HANDLE = W.HANDLE;

    const PROCESS_TERMINATE: DWORD = 0x0001;

    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "killProc: bogus pid is a graceful failure, not a crash" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    // A pid that (almost certainly) doesn't exist.
    const k = killProc(2147483600, null);
    try testing.expect(!k.ok);
    try testing.expect(k.@"error" != null);
}

test "killProc: invalid pid (<= 0) is rejected" {
    const k = killProc(0, null);
    try testing.expect(!k.ok);
    const k2 = killProc(-1, "KILL");
    try testing.expect(!k2.ok);
}
