//! Process *spawn* for the remote machine activity monitor (§9.3, increment 5).
//! Split from `proc_control.zig` because it depends on the GUI-free `CommandCore`
//! spawn core (which imports `src/CommandCore.zig` via `../../CommandCore.zig`).
//! That relative import only resolves inside a module rooted at `src/` (the agent
//! exe + the embedded C API). The agent's `server.zig` therefore does NOT import
//! this file directly (importing it would drag `CommandCore` into the client's
//! transport graph, which is rooted at `src/remote/` and can't reach `src/`).
//! Instead the agent injects spawn through the `Spawner` vtable (implemented in
//! `pty_child.zig`, which already pulls `CommandCore`); the LOCAL C-API provider
//! in `apprt/embedded.zig` (rooted at `src/`) calls `spawnDetached` directly.
//!
//! ## Spawn semantics
//! The command is run through the platform shell so a full command line works
//! (POSIX `/bin/sh -lc <cmd>`, Windows `cmd.exe /C <cmd>`), detached, with no pty
//! and stdio left null/inherit-null. We capture the pid and do NOT wait — it runs
//! independently. On POSIX a short-lived reaper thread `waitpid`s the child so it
//! doesn't linger as a zombie in the long-lived agent.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const CommandCore = @import("../../CommandCore.zig");

const is_windows = builtin.os.tag == .windows;

/// Result of `spawnDetached`. `pid` is set iff `ok`. `@"error"` is either a static
/// string (an `@errorName` / a literal) OR — on the Windows path — an ALLOCATED
/// diagnostic note (see `free_error`). On success it may STILL be non-null on
/// Windows: a temporary diagnostic note (creation-flags path taken + the child's
/// immediate exit-code) so the orchestrator can read what happened via `--spawn`.
pub const SpawnOutcome = struct {
    ok: bool = false,
    pid: ?i64 = null,
    @"error": ?[]const u8 = null,
    /// When true, `@"error"` was allocated from the `alloc` passed to
    /// `spawnDetached` and the caller must free it. When false it is a static
    /// string (free nothing). Used for the Windows diagnostic note.
    free_error: bool = false,
};

/// Launch `cmd` as a DETACHED process via the platform shell (so a full command
/// line — pipes, redirects, args — works), optionally in `cwd`. No pty; stdio is
/// left null (Windows: \Device\Null; POSIX: inherits the agent's). Returns
/// `{ok, pid?}`; on a spawn failure returns `{ok=false, error=@errorName}`.
///
/// POSIX: a detached reaper thread `waitpid`s the child so a long-lived agent
/// doesn't accumulate zombies. We do not block the caller on it.
pub fn spawnDetached(alloc: Allocator, cmd: []const u8, cwd: ?[]const u8) SpawnOutcome {
    if (cmd.len == 0) return .{ .ok = false, .@"error" = "empty command" };
    return if (is_windows)
        spawnWindows(alloc, cmd, cwd)
    else
        spawnPosix(alloc, cmd, cwd);
}

fn spawnPosix(alloc: Allocator, cmd: []const u8, cwd: ?[]const u8) SpawnOutcome {
    // Build `/bin/sh -lc <cmd>`. argv is duped (CommandCore copies it before exec).
    const shell = "/bin/sh";
    const shell_z = alloc.dupeZ(u8, shell) catch return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(shell_z);
    const flag_z = alloc.dupeZ(u8, "-lc") catch return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(flag_z);
    const cmd_z = alloc.dupeZ(u8, cmd) catch return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(cmd_z);

    var args = [_][:0]const u8{ shell_z, flag_z, cmd_z };

    var c: CommandCore.DefaultCommand = .{
        .path = shell_z,
        .args = &args,
        .cwd = cwd,
        // No pty; stdin/out/err null ⇒ the child inherits the agent's std fds
        // (the headless agent's are already detached from any terminal).
    };
    c.start(alloc) catch |err| return .{ .ok = false, .@"error" = @errorName(err) };
    const pid: posix.pid_t = c.pid orelse return .{ .ok = false, .@"error" = "no pid" };

    // Reap the child off-thread so the long-lived agent never accumulates a
    // zombie. Best-effort: if the thread can't spawn, the worst case is one
    // zombie until the agent exits.
    const Reaper = struct {
        fn run(p: posix.pid_t) void {
            _ = posix.waitpid(p, 0);
        }
    };
    if (std.Thread.spawn(.{}, Reaper.run, .{pid})) |t| {
        t.detach();
    } else |_| {}

    return .{ .ok = true, .pid = @intCast(pid) };
}

fn spawnWindows(alloc: Allocator, cmd: []const u8, cwd: ?[]const u8) SpawnOutcome {
    if (builtin.os.tag != .windows) return .{ .ok = false, .@"error" = "unsupported" };
    const w = windows;
    const W = std.os.windows;

    // DIRECT CreateProcessW (not via CommandCore) so we control stdio + creation
    // flags exactly and can instrument the result. Strategy (revised after the
    // DETACHED_PROCESS + \Device\Null variant still vanished):
    //   - CREATE_NEW_CONSOLE — give the child its OWN console window. cmd.exe and
    //     console apps (ping) need a console to keep running; the prior DETACHED_
    //     PROCESS gave them none and the \Device\Null std handles likely made
    //     cmd.exe exit immediately. A new console keeps console apps alive and is
    //     harmless for GUI apps (notepad).
    //   - CREATE_NEW_PROCESS_GROUP — own process group (not Ctrl-signaled with us).
    //   - CREATE_BREAKAWAY_FROM_JOB — escape a kill-on-job-close job the agent may
    //     live in. Tried first; if CreateProcessW fails with ERROR_ACCESS_DENIED
    //     (job forbids breakaway) we retry WITHOUT it.
    // We do NOT set STARTF_USESTDHANDLES: the new console owns the child's stdio, so
    // there are no \Device\Null handles to make cmd.exe exit on startup.
    const base_flags: w.DWORD = w.CREATE_NEW_CONSOLE | w.CREATE_NEW_PROCESS_GROUP | w.CREATE_UNICODE_ENVIRONMENT;

    // Build the command line: `cmd.exe /C <cmd>`. cmd.exe's own parsing handles the
    // rest, so we don't need per-arg quoting here.
    const cmdline = std.fmt.allocPrint(alloc, "C:\\Windows\\System32\\cmd.exe /C {s}", .{cmd}) catch
        return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(cmdline);
    const cmdline_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmdline) catch
        return .{ .ok = false, .@"error" = "bad command encoding" };
    defer alloc.free(cmdline_w);
    const cwd_w: ?[:0]u16 = if (cwd) |d|
        (std.unicode.utf8ToUtf16LeAllocZ(alloc, d) catch null)
    else
        null;
    defer if (cwd_w) |p| alloc.free(p);

    var si: W.STARTUPINFOW = std.mem.zeroes(W.STARTUPINFOW);
    si.cb = @sizeOf(W.STARTUPINFOW);

    // Attempt 1: WITH breakaway. Attempt 2 (on access-denied): without.
    var used_breakaway = true;
    var breakaway_gle: w.DWORD = 0;
    var pi: W.PROCESS_INFORMATION = undefined;
    var ok = w.CreateProcessW(
        null,
        cmdline_w.ptr,
        null,
        null,
        W.FALSE, // do NOT inherit handles (fully detached)
        base_flags | w.CREATE_BREAKAWAY_FROM_JOB,
        null,
        if (cwd_w) |p| p.ptr else null,
        &si,
        &pi,
    ) != 0;
    if (!ok) {
        breakaway_gle = @intFromEnum(W.kernel32.GetLastError());
        used_breakaway = false;
        ok = w.CreateProcessW(
            null,
            cmdline_w.ptr,
            null,
            null,
            W.FALSE,
            base_flags,
            null,
            if (cwd_w) |p| p.ptr else null,
            &si,
            &pi,
        ) != 0;
    }
    if (!ok) {
        const gle = @intFromEnum(W.kernel32.GetLastError());
        const note = std.fmt.allocPrint(alloc, "CreateProcessW failed: breakaway-gle={d} final-gle={d}", .{ breakaway_gle, gle }) catch
            return .{ .ok = false, .@"error" = "CreateProcessW failed" };
        return .{ .ok = false, .@"error" = note, .free_error = true };
    }

    // The child started. Real pid is right in PROCESS_INFORMATION (matches the
    // Toolhelp th32ProcessID used by proc_list / OpenProcess in killProc).
    const real_pid: i64 = @intCast(pi.dwProcessId);

    // INSTRUMENTATION: immediately probe whether the child is still alive. If it
    // already exited, exit_code != STILL_ACTIVE (259) tells us cmd.exe / the child
    // died on startup (the bug we're chasing) rather than persisting.
    var exit_code: w.DWORD = 0;
    const got_code = w.GetExitCodeProcess(pi.hProcess, &exit_code) != 0;

    // We don't keep the handles (the child is detached). Closing a HANDLE never
    // terminates the process.
    W.CloseHandle(pi.hThread);
    W.CloseHandle(pi.hProcess);

    const flags_desc = if (used_breakaway) "NEW_CONSOLE|NEW_GROUP|BREAKAWAY" else "NEW_CONSOLE|NEW_GROUP(fallback,no-breakaway)";
    const alive_desc = if (!got_code)
        "exit=?(GetExitCodeProcess failed)"
    else if (exit_code == w.STILL_ACTIVE)
        "exit=STILL_ACTIVE"
    else
        "exit=EXITED";
    const note = std.fmt.allocPrint(alloc, "diag: flags={s} {s}({d}) breakaway-gle={d}", .{
        flags_desc, alive_desc, exit_code, breakaway_gle,
    }) catch null;

    return .{ .ok = true, .pid = real_pid, .@"error" = note, .free_error = note != null };
}

// =============================================================================
// Windows — CreateProcessW (raw-flag variant) + diagnostics (Windows-only)
// =============================================================================
//
// std's `kernel32.CreateProcessW` takes a packed `CreateProcessFlags` struct, not a
// raw DWORD, so we prototype our own raw-DWORD variant for full flag control. The
// rest (STARTUPINFOW, PROCESS_INFORMATION, GetExitCodeProcess, GetLastError,
// CloseHandle, FALSE) come from std.

const windows = struct {
    const W = std.os.windows;
    const DWORD = W.DWORD;
    const HANDLE = W.HANDLE;
    const BOOL = W.BOOL;
    const LPCWSTR = W.LPCWSTR;
    const LPWSTR = W.LPWSTR;
    const LPVOID = W.LPVOID;
    const SECURITY_ATTRIBUTES = W.SECURITY_ATTRIBUTES;
    const STARTUPINFOW = W.STARTUPINFOW;
    const PROCESS_INFORMATION = W.PROCESS_INFORMATION;

    // dwCreationFlags bits (winbase.h). Values are ABI-stable Win32 constants.
    const CREATE_NEW_CONSOLE: DWORD = 0x00000010;
    const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
    const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
    const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;

    // STILL_ACTIVE (a.k.a. STATUS_PENDING): the exit code GetExitCodeProcess reports
    // for a process that has NOT yet exited.
    const STILL_ACTIVE: DWORD = 259;

    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?LPCWSTR,
        lpCommandLine: ?LPWSTR,
        lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?LPVOID,
        lpCurrentDirectory: ?LPCWSTR,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
};

// =============================================================================
// Tests (native macOS/Linux exercise the real spawn round-trip)
// =============================================================================

const testing = std.testing;

test "spawnDetached: launches a sleeper and returns a real pid (POSIX)" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    const out = spawnDetached(alloc, "sleep 0.2", null);
    try testing.expect(out.ok);
    try testing.expect(out.pid != null);
    try testing.expect(out.pid.? > 0);
}

test "spawnDetached: empty command is rejected" {
    const alloc = testing.allocator;
    const out = spawnDetached(alloc, "", null);
    try testing.expect(!out.ok);
    try testing.expect(out.@"error" != null);
}
