//! MSI custom-action DLL for the Ghoztty Remote Agent installer
//! (`ghoztty-agent-ca.dll`, wired in relay/deploy/msi/ghoztty-agent.wxs).
//!
//! Why a DLL: MSI "run an exe" custom actions (type 50) spawn real processes,
//! and console-subsystem tools (taskkill, powershell, schtasks) each pop a
//! console window over the installer UI — ugly for what is a tray app. wixl
//! (GNOME msitools) doesn't support inline-script custom actions (type 37/38),
//! but it DOES support type-1 Binary-table DLL actions, which run in-process
//! inside msiexec: no child console can ever appear. The one external tool we
//! still need (schtasks — the Task Scheduler COM API is not worth hand-rolling
//! here) is spawned with CREATE_NO_WINDOW, which suppresses its console.
//!
//! Exports (UINT __stdcall (MSIHANDLE), both Return="ignore" best-effort —
//! a failed cleanup must never fail the install):
//!   KillAgentCA      terminate every running ghoztty-agent.exe (all installs,
//!                    upgrades, and uninstalls: frees the exe so files-in-use
//!                    never triggers).
//!   LegacyCleanupCA  retire the pre-MSI install.ps1 layout: kill its
//!                    run-agent.ps1 watchdog (else it respawns the OLD agent
//!                    3s after the kill and steals the single-instance lock),
//!                    unhook its logon triggers (scheduled task + Startup
//!                    .cmd), kill the agent, delete the old-path binaries.
//!                    relay.env and logs in the same dir are shared state and
//!                    deliberately kept.
//!
//! Everything here is deliberately std-light Win32: the DLL must stay tiny,
//! dependency-free, and loadable by msiexec with no CRT surprises.

const std = @import("std");

const W = std.os.windows;
const UINT = c_uint;
const DWORD = W.DWORD;
const HANDLE = W.HANDLE;
const BOOL = W.BOOL;
const ERROR_SUCCESS: UINT = 0;

// ---------------------------------------------------------------------------
// Win32 externs (kernel32 only).

const TH32CS_SNAPPROCESS: DWORD = 0x2;
const PROCESS_TERMINATE: DWORD = 0x0001;
const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
const CREATE_NO_WINDOW: DWORD = 0x08000000;
const INFINITE: DWORD = 0xFFFFFFFF;

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: i32,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn QueryFullProcessImageNameW(hProcess: HANDLE, dwFlags: DWORD, lpExeName: [*]u16, lpdwSize: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ExpandEnvironmentStringsW(lpSrc: [*:0]const u16, lpDst: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *W.STARTUPINFOW,
    lpProcessInformation: *W.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, n: DWORD, lpRead: *DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Helpers. All best-effort: cleanup must never fail the install.

/// Expand a path containing %VAR% references into `buf`, NUL-terminated.
/// Returns the slice without the terminator, or null on failure/overflow.
fn expandPath(comptime src: []const u8, buf: []u16) ?[:0]u16 {
    const src_w = std.unicode.utf8ToUtf16LeStringLiteral(src);
    const n = ExpandEnvironmentStringsW(src_w, buf.ptr, @intCast(buf.len));
    if (n == 0 or n > buf.len) return null;
    return buf[0 .. n - 1 :0]; // n includes the NUL
}

fn eqlIgnoreCaseW(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca < 128) std.ascii.toLower(@intCast(ca)) else ca;
        const lb = if (cb < 128) std.ascii.toLower(@intCast(cb)) else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Terminate every process whose image basename matches `exe_basename`
/// (UTF-16, e.g. "ghoztty-agent.exe"). Returns how many were terminated.
fn killByBasename(exe_basename: []const u16) u32 {
    var killed: u32 = 0;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == W.INVALID_HANDLE_VALUE) return 0;
    defer _ = CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    var ok = Process32FirstW(snap, &entry);
    while (ok != 0) : (ok = Process32NextW(snap, &entry)) {
        const name = std.mem.sliceTo(&entry.szExeFile, 0);
        if (!eqlIgnoreCaseW(name, exe_basename)) continue;
        const h = OpenProcess(PROCESS_TERMINATE, 0, entry.th32ProcessID) orelse continue;
        defer _ = CloseHandle(h);
        if (TerminateProcess(h, 1) != 0) killed += 1;
    }
    return killed;
}

/// Terminate the process `pid` ONLY if its image basename matches
/// `expect_basename` — PID reuse must never friendly-fire an innocent process
/// (mirrors single_instance.zig's takeover hygiene).
fn killPidIfImage(pid: DWORD, expect_basename: []const u16) void {
    const h = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return;
    defer _ = CloseHandle(h);
    var path_buf: [W.PATH_MAX_WIDE]u16 = undefined;
    var n: DWORD = @intCast(path_buf.len);
    if (QueryFullProcessImageNameW(h, 0, &path_buf, &n) == 0) return;
    const full = path_buf[0..n];
    const base = if (std.mem.lastIndexOfScalar(u16, full, '\\')) |i| full[i + 1 ..] else full;
    if (!eqlIgnoreCaseW(base, expect_basename)) return;
    _ = TerminateProcess(h, 1);
}

/// Read a decimal PID out of a small text file (the legacy launcher.pid).
fn readPidFile(path: [:0]const u16) ?DWORD {
    const GENERIC_READ: DWORD = 0x80000000;
    const FILE_SHARE_ALL: DWORD = 0x7;
    const OPEN_EXISTING: DWORD = 3;
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, 0, null);
    if (h == W.INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var buf: [64]u8 = undefined;
    var read: DWORD = 0;
    if (ReadFile(h, &buf, buf.len, &read, null) == 0 or read == 0) return null;
    const text = std.mem.trim(u8, buf[0..read], " \t\r\n\x00\xff\xfe"); // tolerate BOMs
    // PowerShell may have written UTF-16; strip embedded NULs either way.
    var digits: [16]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (c >= '0' and c <= '9') {
            if (len >= digits.len) return null;
            digits[len] = c;
            len += 1;
        } else if (c != 0) break;
    }
    if (len == 0) return null;
    return std.fmt.parseInt(DWORD, digits[0..len], 10) catch null;
}

/// Run a console tool with CREATE_NO_WINDOW (invisible) and wait briefly.
fn runHidden(comptime cmdline: []const u8) void {
    const src = std.unicode.utf8ToUtf16LeStringLiteral(cmdline);
    var cmd_buf: [512]u16 = undefined;
    const n = ExpandEnvironmentStringsW(src, &cmd_buf, cmd_buf.len);
    if (n == 0 or n > cmd_buf.len) return;
    var si: W.STARTUPINFOW = std.mem.zeroes(W.STARTUPINFOW);
    si.cb = @sizeOf(W.STARTUPINFOW);
    var pi: W.PROCESS_INFORMATION = undefined;
    if (CreateProcessW(null, @ptrCast(&cmd_buf), null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return;
    _ = WaitForSingleObject(pi.hProcess, 10_000);
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
}

fn deleteExpanded(comptime path: []const u8) void {
    var buf: [W.PATH_MAX_WIDE]u16 = undefined;
    const p = expandPath(path, &buf) orelse return;
    _ = DeleteFileW(p);
}

const agent_exe_w = std.unicode.utf8ToUtf16LeStringLiteral("ghoztty-agent.exe");
const powershell_w = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");

// ---------------------------------------------------------------------------
// Custom-action entry points. MSI calls UINT __stdcall f(MSIHANDLE); the
// handle is unused (we read no properties), and we always report success —
// the .wxs additionally marks both actions Return="ignore".

/// Terminate every running ghoztty-agent.exe so the exe is never in use
/// during install/upgrade/uninstall.
export fn KillAgentCA(hInstall: usize) callconv(.winapi) UINT {
    _ = hInstall;
    _ = killByBasename(agent_exe_w);
    return ERROR_SUCCESS;
}

/// Retire the legacy install.ps1 layout. Order matters: watchdog first (it
/// respawns the agent 3s after any kill), then logon triggers, then the
/// agent processes, then the dead binaries.
export fn LegacyCleanupCA(hInstall: usize) callconv(.winapi) UINT {
    _ = hInstall;

    // 1. The run-agent.ps1 watchdog, by the PID it recorded — but only if
    //    that PID still names a powershell.exe.
    var pid_path_buf: [W.PATH_MAX_WIDE]u16 = undefined;
    if (expandPath("%LOCALAPPDATA%\\ghoztty\\launcher.pid", &pid_path_buf)) |pid_path| {
        if (readPidFile(pid_path)) |pid| killPidIfImage(pid, powershell_w);
        _ = DeleteFileW(pid_path);
    }

    // 2. Logon triggers: the scheduled task (schtasks, window suppressed)
    //    and the Startup-folder fallback launcher.
    runHidden("%SystemRoot%\\System32\\schtasks.exe /Delete /TN GhozttyAgent /F");
    deleteExpanded("%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\ghoztty-agent.cmd");

    // 3. Any agent the watchdog managed to (re)start, then its binaries.
    _ = killByBasename(agent_exe_w);
    Sleep(400);
    deleteExpanded("%LOCALAPPDATA%\\ghoztty\\ghoztty-agent.exe");
    deleteExpanded("%LOCALAPPDATA%\\ghoztty\\run-agent.ps1");

    return ERROR_SUCCESS;
}
