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

/// Result of `spawnDetached`. `pid` is set iff `ok`. `@"error"` is the spawn
/// error name (`@errorName`, a static string) — never owned.
pub const SpawnOutcome = struct {
    ok: bool = false,
    pid: ?i64 = null,
    @"error": ?[]const u8 = null,
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
    // Build `cmd.exe /C <cmd>`. `startWindows` joins argv into a command line with
    // proper quoting, so passing the user's command as a single arg is correct.
    const shell = "C:\\Windows\\System32\\cmd.exe";
    const shell_z = alloc.dupeZ(u8, shell) catch return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(shell_z);
    const flag_z = alloc.dupeZ(u8, "/C") catch return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(flag_z);
    const cmd_z = alloc.dupeZ(u8, cmd) catch return .{ .ok = false, .@"error" = "OutOfMemory" };
    defer alloc.free(cmd_z);

    var args = [_][:0]const u8{ shell_z, flag_z, cmd_z };

    // DETACHED spawn: the launched process must outlive the agent's console / any
    // job object the agent is enrolled in. We OR these into `CreateProcessW`'s
    // dwCreationFlags (via the `windows_creation_flags` field threaded into
    // `CommandCore.startWindows`):
    //   - DETACHED_PROCESS          — no shared console with the agent.
    //   - CREATE_NEW_PROCESS_GROUP  — its own process group (not signaled with us).
    //   - CREATE_BREAKAWAY_FROM_JOB — escape a kill-on-job-close job the agent may
    //     live in (e.g. ssh-shellhost / a Windows service container). This is the
    //     cause of detached children (notepad.exe, ping) vanishing immediately: the
    //     inherited job is torn down with the agent's console.
    // BREAKAWAY fails (CreateProcessW returns 0) if the agent's job forbids
    // breakaway; in that case we retry WITHOUT it (the process then shares the
    // job's fate, but that is strictly better than failing the spawn outright).
    const detached_base: windows.DWORD = windows.DETACHED_PROCESS | windows.CREATE_NEW_PROCESS_GROUP;

    var c: CommandCore.DefaultCommand = .{
        .path = shell_z,
        .args = &args,
        .cwd = cwd,
        .windows_creation_flags = detached_base | windows.CREATE_BREAKAWAY_FROM_JOB,
        // No ConPTY (pseudo_console null), stdio null ⇒ \Device\Null (see
        // CommandCore.startWindows).
    };
    c.start(alloc) catch {
        // Most likely: the agent's job forbids breakaway. Retry detached but
        // without CREATE_BREAKAWAY_FROM_JOB.
        var c2: CommandCore.DefaultCommand = .{
            .path = shell_z,
            .args = &args,
            .cwd = cwd,
            .windows_creation_flags = detached_base,
        };
        c2.start(alloc) catch |err2| return .{ .ok = false, .@"error" = @errorName(err2) };
        return windowsResult(c2.pid);
    };
    return windowsResult(c.pid);
}

/// Map a CommandCore Windows `pid` field (which holds the child's process HANDLE,
/// since `posix.pid_t == windows.HANDLE`) to the REAL OS process id via
/// `GetProcessId`. This matches `proc.zig`'s Toolhelp `th32ProcessID` and what
/// `proc_control.killProc`'s `OpenProcess(pid)` expects — so a spawned process's
/// reported pid is the same id it appears under in `proc_list` and can be killed
/// by. We intentionally leak the process HANDLE (the child is detached); the
/// agent's eventual exit closes all its handles, which does NOT terminate a
/// broken-away child.
fn windowsResult(handle_opt: ?posix.pid_t) SpawnOutcome {
    const handle = handle_opt orelse return .{ .ok = false, .@"error" = "no pid" };
    const real_pid = windows.GetProcessId(@ptrCast(handle));
    if (real_pid == 0) return .{ .ok = false, .@"error" = "GetProcessId failed" };
    return .{ .ok = true, .pid = @intCast(real_pid) };
}

// =============================================================================
// Windows — CreateProcessW detached flags + GetProcessId (compiled only on Win)
// =============================================================================
//
// std exposes these creation flags only as booleans inside an internal struct and
// has no `GetProcessId`, so we name the standard Win32 constant values + prototype
// the one extern we need.

const windows = struct {
    const W = std.os.windows;
    const DWORD = W.DWORD;
    const HANDLE = W.HANDLE;

    // dwCreationFlags bits (winbase.h). Values are ABI-stable Win32 constants.
    const DETACHED_PROCESS: DWORD = 0x00000008;
    const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
    const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;

    extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
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
