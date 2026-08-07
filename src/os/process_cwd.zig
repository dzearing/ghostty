//! Read another process's *current* working directory — and its command
//! line — from the OS (Windows). Both live in the same remote structure
//! (`PEB->ProcessParameters`), so one PEB-walking implementation serves both.
//!
//! The cwd is the one the process itself would report: cmd.exe, bash, nu and
//! most shells call SetCurrentDirectory/chdir on every `cd`, so the value
//! tracks the user live — independent of any OSC 7 report. PowerShell is the
//! notable exception (Set-Location does not move the process cwd), which is
//! why callers treat this as a FALLBACK for shells that never report OSC 7
//! (T185); pwsh gets its live value from shell integration instead.
//!
//! The command line (`ProcessParameters->CommandLine`) is what the process was
//! started with — the agent's foreground-command sampling (T429) reads it so a
//! restart notice can name what a pane was running.
//!
//! One implementation, two entry points each: the agent's pty child already
//! holds a process HANDLE (`fromHandle`/`cmdlineFromHandle`); other callers
//! know only a pid (`fromPid`/`cmdlineFromPid`, which open and close their own
//! handle). Every read is bounds-checked against the untrusted target process
//! and any failure returns null — never a crash.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

/// Read the target's `PEB->ProcessParameters->CurrentDirectory.DosPath`.
///
///   1. `NtQueryInformationProcess(ProcessBasicInformation)` → `PebBaseAddress`.
///   2. `ReadProcessMemory` the target's PEB → `ProcessParameters` pointer.
///   3. `ReadProcessMemory` the `RTL_USER_PROCESS_PARAMETERS` →
///      `CurrentDirectory.DosPath` (a `UNICODE_STRING`).
///   4. `ReadProcessMemory` its UTF-16 buffer and convert to UTF-8.
///
/// Uses the std `PEB` / `RTL_USER_PROCESS_PARAMETERS` / `UNICODE_STRING` ABI
/// types (no hand-rolled offsets) and the std `ReadProcessMemory` wrapper.
/// The handle needs PROCESS_QUERY_INFORMATION | PROCESS_VM_READ rights.
pub fn fromHandle(handle: windows.HANDLE, alloc: Allocator) ?[]u8 {
    if (comptime builtin.os.tag != .windows) return null;
    const params = readParams(handle) orelse return null;
    return readUnicodeString(handle, params.CurrentDirectory.DosPath, alloc);
}

/// Read the target's command line (`PEB->ProcessParameters->CommandLine`) as
/// UTF-8 — the string the process was started with, quoting included (T429).
/// Same trust posture as `fromHandle`: any failure returns null.
pub fn cmdlineFromHandle(handle: windows.HANDLE, alloc: Allocator) ?[]u8 {
    if (comptime builtin.os.tag != .windows) return null;
    const params = readParams(handle) orelse return null;
    return readUnicodeString(handle, params.CommandLine, alloc);
}

/// Open `pid` and read its command line. Same-user targets need no elevation.
/// Returns a fresh `alloc`-owned UTF-8 string, or null on any failure.
pub fn cmdlineFromPid(pid: u32, alloc: Allocator) ?[]u8 {
    if (comptime builtin.os.tag != .windows) return null;
    if (pid == 0) return null;
    const handle = OpenProcess(
        PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
        windows.FALSE,
        pid,
    ) orelse return null;
    defer windows.CloseHandle(handle);
    return cmdlineFromHandle(handle, alloc);
}

/// Steps 1–3 of the PEB walk, shared by the cwd and command-line readers:
/// PEB base address via `NtQueryInformationProcess`, then two bounds-checked
/// `ReadProcessMemory` hops to the target's `RTL_USER_PROCESS_PARAMETERS`.
/// Uses the std ABI types (no hand-rolled offsets).
fn readParams(handle: windows.HANDLE) ?windows.RTL_USER_PROCESS_PARAMETERS {
    var pbi: windows.PROCESS_BASIC_INFORMATION = undefined;
    var ret_len: windows.ULONG = 0;
    const st = windows.ntdll.NtQueryInformationProcess(
        handle,
        .ProcessBasicInformation,
        &pbi,
        @sizeOf(windows.PROCESS_BASIC_INFORMATION),
        &ret_len,
    );
    if (st != .SUCCESS) return null;

    var peb: windows.PEB = undefined;
    _ = windows.ReadProcessMemory(
        handle,
        @ptrCast(pbi.PebBaseAddress),
        std.mem.asBytes(&peb),
    ) catch return null;
    const pp_addr = @intFromPtr(peb.ProcessParameters);
    if (pp_addr == 0) return null;

    var params: windows.RTL_USER_PROCESS_PARAMETERS = undefined;
    _ = windows.ReadProcessMemory(
        handle,
        @ptrFromInt(pp_addr),
        std.mem.asBytes(&params),
    ) catch return null;
    return params;
}

/// Read a `UNICODE_STRING` whose buffer lives in the TARGET process, convert
/// to UTF-8. Bounds-checked (a length far over the 32K wchar OS limit is
/// bogus data from an untrusted target); null on any failure.
fn readUnicodeString(
    handle: windows.HANDLE,
    us: windows.UNICODE_STRING,
    alloc: Allocator,
) ?[]u8 {
    const buf_ptr = us.Buffer orelse return null;
    const wlen: usize = us.Length / 2; // Length is in BYTES
    if (wlen == 0 or wlen > 32768) return null;

    const wbuf = alloc.alloc(u16, wlen) catch return null;
    defer alloc.free(wbuf);
    _ = windows.ReadProcessMemory(
        handle,
        @ptrCast(buf_ptr),
        std.mem.sliceAsBytes(wbuf),
    ) catch return null;

    return std.unicode.utf16LeToUtf8Alloc(alloc, wbuf) catch null;
}

/// Open `pid` and read its current working directory. Same-user targets need
/// no elevation. Returns a fresh `alloc`-owned UTF-8 path, or null on any
/// failure (pid gone, access denied, malformed data).
pub fn fromPid(pid: u32, alloc: Allocator) ?[]u8 {
    if (comptime builtin.os.tag != .windows) return null;
    if (pid == 0) return null;
    const handle = OpenProcess(
        PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
        windows.FALSE,
        pid,
    ) orelse return null;
    defer windows.CloseHandle(handle);
    return fromHandle(handle, alloc);
}

// `std.os.windows.kernel32` does not declare OpenProcess; declared locally
// like the other call sites in this repo (LocalAgent, relaunch_guard, …).
extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;
const PROCESS_QUERY_INFORMATION: windows.DWORD = 0x0400;
const PROCESS_VM_READ: windows.DWORD = 0x0010;

test "fromPid: own process round-trips our real cwd" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const got = fromPid(windows.GetCurrentProcessId(), alloc) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(got);

    const want = try std.process.getCwdAlloc(alloc);
    defer alloc.free(want);

    // The PEB path may carry a trailing backslash (it does for drive roots
    // and often in general); getCwd does not. Compare trimmed.
    const got_trim = std.mem.trimRight(u8, got, "\\");
    const want_trim = std.mem.trimRight(u8, want, "\\");
    try testing.expectEqualStrings(want_trim, got_trim);
}

test "fromPid: nonexistent pid returns null" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    // Pids are multiples of 4; 3 can never name a real process. And pid 0
    // (the idle process) is rejected before OpenProcess.
    try std.testing.expect(fromPid(3, std.testing.allocator) == null);
    try std.testing.expect(fromPid(0, std.testing.allocator) == null);
}

test "cmdlineFromPid: own process names our own executable" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const got = cmdlineFromPid(windows.GetCurrentProcessId(), alloc) orelse
        return error.TestUnexpectedResult;
    defer alloc.free(got);

    // The command line's first token is the exe (possibly quoted); compare
    // against our real image path's basename rather than pinning quoting.
    const exe = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(exe);
    const base = std.fs.path.basename(exe);
    try testing.expect(std.ascii.indexOfIgnoreCase(got, base) != null);
}

test "cmdlineFromPid: nonexistent pid returns null" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(cmdlineFromPid(3, std.testing.allocator) == null);
    try std.testing.expect(cmdlineFromPid(0, std.testing.allocator) == null);
}
