const std = @import("std");
const windows = std.os.windows;

// Export any constants or functions we need from the Windows API so
// we can just import one file.
pub const kernel32 = windows.kernel32;
pub const unexpectedError = windows.unexpectedError;
pub const OpenFile = windows.OpenFile;
pub const CloseHandle = windows.CloseHandle;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const SetHandleInformation = windows.SetHandleInformation;
pub const DWORD = windows.DWORD;
pub const FILE_ATTRIBUTE_NORMAL = windows.FILE_ATTRIBUTE_NORMAL;
pub const FILE_FLAG_OVERLAPPED = windows.FILE_FLAG_OVERLAPPED;
pub const FILE_SHARE_READ = windows.FILE_SHARE_READ;
pub const GENERIC_READ = windows.GENERIC_READ;
pub const HANDLE = windows.HANDLE;
pub const HANDLE_FLAG_INHERIT = windows.HANDLE_FLAG_INHERIT;
pub const INFINITE = windows.INFINITE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const OPEN_EXISTING = windows.OPEN_EXISTING;
pub const PIPE_ACCESS_OUTBOUND = windows.PIPE_ACCESS_OUTBOUND;
pub const PIPE_TYPE_BYTE = windows.PIPE_TYPE_BYTE;
pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;
pub const S_OK = windows.S_OK;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const SYNCHRONIZE = windows.SYNCHRONIZE;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const WAIT_OBJECT_0 = windows.WAIT_OBJECT_0;
pub const WAIT_TIMEOUT = windows.WAIT_TIMEOUT;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;

pub const exp = struct {
    pub const HPCON = windows.LPVOID;

    pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
    pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;

    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    };

    // --- EcoQoS opt-out (T1465) ------------------------------------------------
    //
    // Windows 11 decides, on its own, that a background process should run in
    // "efficiency mode": its threads are parked on E-cores at a reduced clock.
    // On a 13900K that is worth roughly 2.2x, which is exactly the deficit an
    // agent-held pane showed against the same code running inside the
    // foreground app. `SetProcessInformation(ProcessPowerThrottling)` with the
    // EXECUTION_SPEED bit in `ControlMask` and clear in `StateMask` is the
    // documented way to say "never throttle this one"; child processes inherit
    // it, which is how the ConPTY's own conhost gets covered.

    pub const PROCESS_INFORMATION_CLASS = enum(c_int) {
        ProcessMemoryPriority = 0,
        ProcessMemoryExhaustionInfo = 1,
        ProcessAppMemoryInfo = 2,
        ProcessInPrivateInfo = 3,
        ProcessPowerThrottling = 4,
        ProcessReservedValue1 = 5,
        ProcessTelemetryCoverageInfo = 6,
        ProcessProtectionLevelInfo = 7,
        ProcessLeapSecondInfo = 8,
        ProcessMachineTypeInfo = 9,
    };

    pub const PROCESS_POWER_THROTTLING_CURRENT_VERSION: windows.ULONG = 1;
    pub const PROCESS_POWER_THROTTLING_EXECUTION_SPEED: windows.ULONG = 0x1;

    pub const PROCESS_POWER_THROTTLING_STATE = extern struct {
        Version: windows.ULONG,
        ControlMask: windows.ULONG,
        StateMask: windows.ULONG,
    };

    /// One processor, as `GetSystemCpuSetInformation` reports it (winnt.h
    /// `SYSTEM_CPU_SET_INFORMATION`). `EfficiencyClass` is the field that makes
    /// a hybrid CPU's performance cores nameable without hardcoding a mask:
    /// higher is faster, and every processor sharing one value means the
    /// machine has no faster half. The union in the C header has exactly one
    /// arm today, so it is flattened here.
    pub const SYSTEM_CPU_SET_INFORMATION = extern struct {
        Size: windows.DWORD,
        Type: windows.DWORD,
        Id: windows.DWORD,
        Group: windows.WORD,
        LogicalProcessorIndex: u8,
        CoreIndex: u8,
        LastLevelCacheIndex: u8,
        NumaNodeIndex: u8,
        EfficiencyClass: u8,
        AllFlags: u8,
        _pad: [2]u8,
        SchedulingClass: windows.DWORD,
        AllocationTag: u64,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn GetSystemCpuSetInformation(
            Information: ?*SYSTEM_CPU_SET_INFORMATION,
            BufferLength: windows.ULONG,
            ReturnedLength: *windows.ULONG,
            Process: windows.HANDLE,
            Flags: windows.ULONG,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetProcessDefaultCpuSets(
            Process: windows.HANDLE,
            CpuSetIds: ?[*]const windows.ULONG,
            CpuSetIdCount: windows.ULONG,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetProcessAffinityMask(
            hProcess: windows.HANDLE,
            dwProcessAffinityMask: usize,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn GetProcessAffinityMask(
            hProcess: windows.HANDLE,
            lpProcessAffinityMask: *usize,
            lpSystemAffinityMask: *usize,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetProcessInformation(
            hProcess: windows.HANDLE,
            ProcessInformationClass: PROCESS_INFORMATION_CLASS,
            ProcessInformation: windows.LPVOID,
            ProcessInformationSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetConsoleCP(
            wCodePageID: windows.UINT,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn SetConsoleOutputCP(
            wCodePageID: windows.UINT,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: windows.LPSTR,
            nSize: *windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: windows.DWORD,
            lpBuffer: windows.LPWSTR,
        ) callconv(.winapi) windows.DWORD;
    };

    pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
    pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
    pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
    pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;

    pub const ProcThreadAttributeNumber = enum(windows.DWORD) {
        ProcThreadAttributePseudoConsole = 22,
        _,
    };

    /// Corresponds to the ProcThreadAttributeValue define in WinBase.h
    pub fn ProcThreadAttributeValue(
        comptime attribute: ProcThreadAttributeNumber,
        comptime thread: bool,
        comptime input: bool,
        comptime additive: bool,
    ) windows.DWORD {
        return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
            (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
            (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
            (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
    }

    pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(.ProcThreadAttributePseudoConsole, false, true, false);
};
