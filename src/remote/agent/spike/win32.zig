//! Win32 declarations the remote agent needs that `std.os.windows` does NOT
//! provide (WP2 spike, §13/§17). Follows the project's existing pattern of an
//! `exp`-style extern namespace (see `src/os/windows.zig`): one place to declare
//! the prototypes, structs, and constants, so the agent code reads like ordinary
//! calls.
//!
//! Everything here was confirmed *absent* from `std.os.windows`/`.kernel32` in
//! zig 0.15.2 (see `FINDINGS.md` §"extern inventory"). The signatures match the
//! Win32 SDK headers; cross-compiling this file for `x86_64-windows-gnu` links
//! them against MinGW's import libraries, which is the build-time proof that the
//! prototypes are well-formed.
//!
//! This file is Windows-only by construction; it is compiled only when the agent
//! is built for a Windows target.

const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const WCHAR = windows.WCHAR;
pub const LPVOID = windows.LPVOID;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPWSTR = windows.LPWSTR;
pub const SIZE_T = windows.SIZE_T;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const OVERLAPPED = windows.OVERLAPPED;

/// `std.os.windows` has no `PSECURITY_DESCRIPTOR`; it is just a `void*`.
pub const PSECURITY_DESCRIPTOR = LPVOID;

// -----------------------------------------------------------------------------
// Named-pipe constants (§4.1). FILE_FLAG_FIRST_PIPE_INSTANCE already exists in
// the project's os/windows.zig `exp` namespace; redeclared here so the spike is
// self-contained.
// -----------------------------------------------------------------------------

pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
pub const PIPE_TYPE_BYTE: DWORD = 0x00000000;
pub const PIPE_READMODE_BYTE: DWORD = 0x00000000;
pub const PIPE_WAIT: DWORD = 0x00000000;
/// Refuse clients arriving over SMB/RPC from another machine (§4.1, local-only).
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008;
/// Fail-closed if the pipe name already exists → defeats a local name-squat
/// (§15 M6). The daemon also guards single-instance with a named mutex.
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
pub const NMPWAIT_WAIT_FOREVER: DWORD = 0xffffffff;
pub const NMPWAIT_USE_DEFAULT_WAIT: DWORD = 0x00000000;

pub const SDDL_REVISION_1: DWORD = 1;

// Win32 error codes the agent branches on.
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_SEM_TIMEOUT: DWORD = 121;

// -----------------------------------------------------------------------------
// Process-creation flags (§9.1/§13.4). The daemon owns a BREAKAWAY_OK job; per
// session it spawns the ConPTY child with CREATE_BREAKAWAY_FROM_JOB |
// CREATE_NEW_PROCESS_GROUP, then reassigns it into a per-session containment job.
// -----------------------------------------------------------------------------

pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const CREATE_BREAKAWAY_FROM_JOB: DWORD = 0x01000000;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const DETACHED_PROCESS: DWORD = 0x00000008;

// -----------------------------------------------------------------------------
// Job Object info classes + limit structs (§9.1). Absent from std.os.windows.
// -----------------------------------------------------------------------------

pub const JOBOBJECTINFOCLASS = enum(c_int) {
    BasicAccountingInformation = 1,
    BasicLimitInformation = 2,
    ExtendedLimitInformation = 9,
    _,
};

/// Set in JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags.
pub const JOB_OBJECT_LIMIT_BREAKAWAY_OK: DWORD = 0x00000800;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
pub const JOB_OBJECT_LIMIT_PROCESS_MEMORY: DWORD = 0x00000100;
pub const JOB_OBJECT_LIMIT_ACTIVE_PROCESS: DWORD = 0x00000008;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: LARGE_INTEGER,
    PerJobUserTimeLimit: LARGE_INTEGER,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: SIZE_T,
    MaximumWorkingSetSize: SIZE_T,
    ActiveProcessLimit: DWORD,
    Affinity: ULONG_PTR,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: SIZE_T,
    JobMemoryLimit: SIZE_T,
    PeakProcessMemoryUsed: SIZE_T,
    PeakJobMemoryUsed: SIZE_T,
};

pub const JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = extern struct {
    TotalUserTime: LARGE_INTEGER,
    TotalKernelTime: LARGE_INTEGER,
    ThisPeriodTotalUserTime: LARGE_INTEGER,
    ThisPeriodTotalKernelTime: LARGE_INTEGER,
    TotalPageFaultCount: DWORD,
    TotalProcesses: DWORD,
    ActiveProcesses: DWORD,
    TotalTerminatedProcesses: DWORD,
};

// -----------------------------------------------------------------------------
// Extern prototypes std.os.windows lacks (the "must declare" set from §17/WP2).
// kernel32 + advapi32; all `callconv(.winapi)`.
// -----------------------------------------------------------------------------

// --- Named pipes (server + client) -------------------------------------------

pub extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: HANDLE,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: HANDLE,
) callconv(.winapi) BOOL;

/// Bridge-side wait for the daemon's pipe to exist (schtasks /run is async — the
/// daemon may not have called CreateNamedPipe yet, §4.1 startup race).
pub extern "kernel32" fn WaitNamedPipeW(
    lpNamedPipeName: LPCWSTR,
    nTimeOut: DWORD,
) callconv(.winapi) BOOL;

/// Kernel-derived peer identity (§9.5): the daemon maps this PID → session via
/// job membership. Unforgeable by the caller, unlike an env bearer token.
pub extern "kernel32" fn GetNamedPipeClientProcessId(
    Pipe: HANDLE,
    ClientProcessId: *ULONG,
) callconv(.winapi) BOOL;

// --- Job Objects (containment + accounting + kill) ---------------------------

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: HANDLE,
    hProcess: HANDLE,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn TerminateJobObject(
    hJob: HANDLE,
    uExitCode: UINT,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: JOBOBJECTINFOCLASS,
    lpJobObjectInformation: LPVOID,
    cbJobObjectInformationLength: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn QueryInformationJobObject(
    hJob: ?HANDLE,
    JobObjectInformationClass: JOBOBJECTINFOCLASS,
    lpJobObjectInformation: LPVOID,
    cbJobObjectInformationLength: DWORD,
    lpReturnLength: ?*DWORD,
) callconv(.winapi) BOOL;

// --- Console control (Ctrl-C escalation, §9.2) -------------------------------

pub extern "kernel32" fn GenerateConsoleCtrlEvent(
    dwCtrlEvent: DWORD,
    dwProcessGroupId: DWORD,
) callconv(.winapi) BOOL;

// --- Single-instance mutex (§4.1) --------------------------------------------

pub extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*SECURITY_ATTRIBUTES,
    bInitialOwner: BOOL,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;

// --- Owner-only DACL for the pipe (§4.1/§15 M6) ------------------------------

/// Build a SECURITY_DESCRIPTOR from an SDDL string (e.g. owner-only
/// `D:P(A;;GA;;;OW)`). Frees with `LocalFree`.
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: LPCWSTR,
    StringSDRevision: DWORD,
    SecurityDescriptor: *PSECURITY_DESCRIPTOR,
    SecurityDescriptorSize: ?*ULONG,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn LocalFree(
    hMem: ?LPVOID,
) callconv(.winapi) ?LPVOID;

// --- CreateProcessW with raw DWORD flags -------------------------------------
//
// `std.os.windows.kernel32.CreateProcessW` types `dwCreationFlags` as a packed
// `CreateProcessFlags` struct that does not expose CREATE_BREAKAWAY_FROM_JOB /
// CREATE_NEW_PROCESS_GROUP. The project already redeclares CreateProcessW for an
// unrelated reason (`src/os/windows.zig:91`); we do the same with a plain DWORD
// flags field so the job-topology flags can be OR'd in.
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?LPVOID,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
