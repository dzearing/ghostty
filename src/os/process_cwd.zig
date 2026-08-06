//! Read another process's *current* working directory from the OS (Windows).
//!
//! This is the cwd the process itself would report: cmd.exe, bash, nu and most
//! shells call SetCurrentDirectory/chdir on every `cd`, so the value tracks
//! the user live — independent of any OSC 7 report. PowerShell is the notable
//! exception (Set-Location does not move the process cwd), which is why
//! callers treat this as a FALLBACK for shells that never report OSC 7
//! (T185); pwsh gets its live value from shell integration instead.
//!
//! One implementation, two entry points: the agent's pty child already holds
//! a process HANDLE (`fromHandle`); the app side knows only a pid
//! (`fromPid`, which opens and closes its own handle). Every read is
//! bounds-checked against the untrusted target process and any failure
//! returns null — never a crash.

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

    // 1. PEB base address via NtQueryInformationProcess.
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

    // 2. Read the target's PEB, then take ProcessParameters (a remote pointer).
    var peb: windows.PEB = undefined;
    _ = windows.ReadProcessMemory(
        handle,
        @ptrCast(pbi.PebBaseAddress),
        std.mem.asBytes(&peb),
    ) catch return null;
    const pp_addr = @intFromPtr(peb.ProcessParameters);
    if (pp_addr == 0) return null;

    // 3. Read the RTL_USER_PROCESS_PARAMETERS; take CurrentDirectory.DosPath.
    var params: windows.RTL_USER_PROCESS_PARAMETERS = undefined;
    _ = windows.ReadProcessMemory(
        handle,
        @ptrFromInt(pp_addr),
        std.mem.asBytes(&params),
    ) catch return null;

    const us = params.CurrentDirectory.DosPath; // UNICODE_STRING
    const buf_ptr = us.Buffer orelse return null;
    const wlen: usize = us.Length / 2; // Length is in BYTES
    // A path far over MAX_PATH*2 is bogus; reject it (untrusted target).
    if (wlen == 0 or wlen > 32768) return null;

    // 4. Read the UTF-16 path buffer out of the target and convert to UTF-8.
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
