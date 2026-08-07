//! Foreground-COMMAND sampling (T429) — what a session's shell is actually
//! running, so the restart notice (and anything else that wants a label for a
//! plain shell pane) can name it.
//!
//! Why this exists: `handleOpen` records a command label only from the OPEN
//! request (`command`/`shell`), and a plain local GUI pane sends neither — so
//! every such session persisted with no label at all and the notice printed
//! after an agent restart could never name what the user was running. The
//! valuable answer is not the shell path (that is true and useless — it
//! asserts a command was running when the pane was simply a prompt) but the
//! FOREGROUND program inside the shell: `claude`, `zig build`, `ping`.
//!
//! Semantics of a query, encoded in `FgQuery` and relied on by
//! `SessionStore.refreshForegroundCommands`:
//!   - `.cmd`  — a program is running in front of the shell; record its
//!               command line.
//!   - `.none` — the shell itself is the foreground (an idle prompt); CLEAR
//!               any recorded value. A stale "previous command" that had
//!               already finished is exactly the false assertion this feature
//!               exists to avoid.
//!   - null    — the query failed (process gone mid-walk, access denied);
//!               KEEP the last known value, the same keep-on-failure rule the
//!               cwd refresh uses (T425).
//!
//! Per-OS mechanism:
//!   - POSIX: the pty already knows — `tcgetpgrp` names the foreground process
//!     group leader. The pty-owning caller (`pty_child.zig`) resolves the pid
//!     and this module reads its command line (`/proc/<pid>/cmdline` on Linux;
//!     macOS has no procfs and its arm is deferred — see the seat:mac task).
//!   - Windows: ConPTY has no foreground process group, so "foreground" is
//!     approximated as the most recently created DIRECT child of the shell
//!     process — for an interactive shell that is the command the user typed
//!     (background `start /b` jobs are the rare exception and lose the tie).
//!     The command line comes from the child's PEB, the same cross-process
//!     read `process_cwd.zig` already does for the cwd.
//!
//! The Toolhelp walk + per-candidate `GetProcessTimes` is NOT a cheap single
//! syscall, so callers must treat this like `Child.queryCwd`: called on a slow
//! periodic tick, OUTSIDE the store lock (collect-then-act).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const process_cwd = @import("../../os/process_cwd.zig");

/// The outcome of a foreground-command query. See the module doc for the
/// tri-state contract (`.cmd` record / `.none` clear / null keep).
pub const FgQuery = union(enum) {
    none,
    /// Caller-allocator-owned; the caller frees it.
    cmd: []u8,
};

// -----------------------------------------------------------------------------
// Pure selection logic (unit-testable on any OS)
// -----------------------------------------------------------------------------

/// One process-table row, as much of it as the selection rule needs.
pub const Entry = struct {
    pid: u32,
    ppid: u32,
    /// Executable basename (e.g. "node.exe"). Compared case-insensitively.
    name: []const u8 = "",
    /// Creation timestamp in any monotone unit (Windows: FILETIME ticks).
    /// 0 = unknown, which loses every tie-break.
    created: u64 = 0,
};

/// Infrastructure processes that can appear parented to a console process but
/// are never "the command the user ran".
const excluded_names = [_][]const u8{ "conhost.exe", "openconsole.exe" };

/// Pick the foreground candidate among `entries`: the most recently created
/// direct child of `shell_pid` that is not console infrastructure. Null when
/// the shell has no such child — an idle prompt.
pub fn pickForeground(entries: []const Entry, shell_pid: u32) ?u32 {
    var best: ?Entry = null;
    for (entries) |e| {
        if (e.ppid != shell_pid or e.pid == shell_pid) continue;
        if (isExcluded(e.name)) continue;
        if (best == null or e.created > best.?.created) best = e;
    }
    return if (best) |b| b.pid else null;
}

fn isExcluded(name: []const u8) bool {
    for (excluded_names) |x| {
        if (std.ascii.eqlIgnoreCase(name, x)) return true;
    }
    return false;
}

/// Normalize a raw `/proc/<pid>/cmdline` image in place: argv strings are
/// NUL-separated (with a trailing NUL), so every NUL becomes a space and the
/// result is trimmed. Returns the trimmed slice of `buf`.
pub fn normalizeCmdline(buf: []u8) []u8 {
    for (buf) |*c| {
        if (c.* == 0) c.* = ' ';
    }
    const trimmed = std.mem.trim(u8, buf, " ");
    return buf[(@intFromPtr(trimmed.ptr) - @intFromPtr(buf.ptr))..][0..trimmed.len];
}

// -----------------------------------------------------------------------------
// Windows: Toolhelp direct-child walk + PEB command-line read
// -----------------------------------------------------------------------------

/// Windows foreground-command query for the shell process `shell_pid`.
/// See the module doc for the walk and the tri-state contract.
pub fn queryWindows(alloc: Allocator, shell_pid: u32) ?FgQuery {
    if (comptime builtin.os.tag != .windows) return null;
    if (shell_pid == 0) return null;
    const w = win;
    const W = std.os.windows;

    const snap = w.CreateToolhelp32Snapshot(w.TH32CS_SNAPPROCESS, 0);
    if (snap == W.INVALID_HANDLE_VALUE) return null;
    defer W.CloseHandle(snap);

    var candidates: std.ArrayList(Entry) = .empty;
    defer candidates.deinit(alloc);

    var entry: w.PROCESSENTRY32W = .{ .dwSize = @sizeOf(w.PROCESSENTRY32W) };
    var ok = w.Process32FirstW(snap, &entry) != 0;
    while (ok) : (ok = w.Process32NextW(snap, &entry) != 0) {
        if (entry.th32ParentProcessID != shell_pid) continue;
        if (entry.th32ProcessID == shell_pid) continue;

        // Basename to UTF-8 in a stack buffer (260 WCHARs fits in 780 bytes).
        var name_buf: [780]u8 = undefined;
        const name_w = std.mem.sliceTo(&entry.szExeFile, 0);
        const name_len = std.unicode.utf16LeToUtf8(&name_buf, name_w) catch 0;
        if (isExcluded(name_buf[0..name_len])) continue;

        // Creation time for the most-recent tie-break; a denied handle keeps
        // the candidate with created=0 (it loses ties but still counts as "a
        // program is running").
        var created: u64 = 0;
        if (w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID)) |h| {
            defer W.CloseHandle(h);
            var c: W.FILETIME = undefined;
            var e: W.FILETIME = undefined;
            var k: W.FILETIME = undefined;
            var u: W.FILETIME = undefined;
            if (w.GetProcessTimes(h, &c, &e, &k, &u) != 0) {
                created = (@as(u64, c.dwHighDateTime) << 32) | @as(u64, c.dwLowDateTime);
            }
        }

        candidates.append(alloc, .{
            .pid = entry.th32ProcessID,
            .ppid = entry.th32ParentProcessID,
            .created = created,
        }) catch return null; // OOM: can't tell → keep last known
    }

    const fg_pid = pickForeground(candidates.items, shell_pid) orelse return .none;
    const cmd = process_cwd.cmdlineFromPid(fg_pid, alloc) orelse return null;
    if (cmd.len == 0) {
        alloc.free(cmd);
        return null;
    }
    return .{ .cmd = cmd };
}

// -----------------------------------------------------------------------------
// Linux: /proc/<pid>/cmdline
// -----------------------------------------------------------------------------

/// Read `pid`'s command line from procfs. Null on any failure (process gone,
/// kernel thread with an empty cmdline, permission).
pub fn cmdlineLinux(alloc: Allocator, pid: i64) ?[]u8 {
    if (comptime builtin.os.tag != .linux) return null;
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;
    const raw = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch return null;
    defer alloc.free(raw);
    const norm = normalizeCmdline(raw);
    if (norm.len == 0) return null;
    return alloc.dupe(u8, norm) catch null;
}

// -----------------------------------------------------------------------------
// Windows externs (mirrors proc.zig's local decls — kept local per house style)
// -----------------------------------------------------------------------------

const win = struct {
    const W = std.os.windows;
    const BOOL = W.BOOL;
    const DWORD = W.DWORD;
    const HANDLE = W.HANDLE;
    const FILETIME = W.FILETIME;
    const WCHAR = W.WCHAR;

    const TH32CS_SNAPPROCESS: DWORD = 0x00000002;
    const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
    const MAX_PATH = 260;

    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD,
        cntUsage: DWORD = 0,
        th32ProcessID: DWORD = 0,
        th32DefaultHeapID: usize = 0,
        th32ModuleID: DWORD = 0,
        cntThreads: DWORD = 0,
        th32ParentProcessID: DWORD = 0,
        pcPriClassBase: W.LONG = 0,
        dwFlags: DWORD = 0,
        szExeFile: [MAX_PATH]WCHAR = undefined,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetProcessTimes(
        hProcess: HANDLE,
        lpCreationTime: *FILETIME,
        lpExitTime: *FILETIME,
        lpKernelTime: *FILETIME,
        lpUserTime: *FILETIME,
    ) callconv(.winapi) BOOL;
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "pickForeground: no children means an idle prompt" {
    const entries = [_]Entry{
        .{ .pid = 100, .ppid = 1, .name = "cmd.exe", .created = 5 },
        .{ .pid = 300, .ppid = 200, .name = "node.exe", .created = 9 },
    };
    try std.testing.expect(pickForeground(&entries, 100) == null);
}

test "pickForeground: the single direct child wins; grandchildren don't count" {
    const entries = [_]Entry{
        .{ .pid = 100, .ppid = 1, .name = "cmd.exe", .created = 5 },
        .{ .pid = 200, .ppid = 100, .name = "node.exe", .created = 8 },
        .{ .pid = 300, .ppid = 200, .name = "git.exe", .created = 9 },
    };
    try std.testing.expectEqual(@as(?u32, 200), pickForeground(&entries, 100));
}

test "pickForeground: multiple children pick the most recently created" {
    const entries = [_]Entry{
        .{ .pid = 200, .ppid = 100, .name = "svc.exe", .created = 3 },
        .{ .pid = 201, .ppid = 100, .name = "ping.exe", .created = 7 },
        .{ .pid = 202, .ppid = 100, .name = "old.exe", .created = 1 },
    };
    try std.testing.expectEqual(@as(?u32, 201), pickForeground(&entries, 100));
}

test "pickForeground: console infrastructure never counts as the command" {
    const entries = [_]Entry{
        .{ .pid = 200, .ppid = 100, .name = "conhost.exe", .created = 9 },
        .{ .pid = 201, .ppid = 100, .name = "OpenConsole.exe", .created = 8 },
    };
    try std.testing.expect(pickForeground(&entries, 100) == null);

    const mixed = [_]Entry{
        .{ .pid = 200, .ppid = 100, .name = "conhost.exe", .created = 9 },
        .{ .pid = 201, .ppid = 100, .name = "claude.exe", .created = 2 },
    };
    try std.testing.expectEqual(@as(?u32, 201), pickForeground(&mixed, 100));
}

test "pickForeground: a child with unknown creation time still counts" {
    const entries = [_]Entry{
        .{ .pid = 200, .ppid = 100, .name = "x.exe", .created = 0 },
    };
    try std.testing.expectEqual(@as(?u32, 200), pickForeground(&entries, 100));
}

test "normalizeCmdline: NUL-separated argv becomes one spaced line" {
    var buf = "claude\x00--continue\x00go\x00".*;
    try std.testing.expectEqualStrings("claude --continue go", normalizeCmdline(&buf));
}

test "normalizeCmdline: empty and all-NUL images trim to nothing" {
    var empty = "".*;
    try std.testing.expectEqualStrings("", normalizeCmdline(&empty));
    var nuls = "\x00\x00".*;
    try std.testing.expectEqualStrings("", normalizeCmdline(&nuls));
}

test "queryWindows: our own shell-less process reports an idle prompt or a child" {
    // Smoke only: the test runner's direct children are unpredictable, but the
    // call must never crash and must return a well-formed tri-state.
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const pid = std.os.windows.GetCurrentProcessId();
    if (queryWindows(alloc, pid)) |q| switch (q) {
        .none => {},
        .cmd => |c| alloc.free(c),
    };
}
