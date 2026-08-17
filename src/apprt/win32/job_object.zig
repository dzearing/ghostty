//! What Windows job object are we in, and is that other process in it with us?
//!
//! T426. Four times now the app has ended cleanly — no WER record, no further
//! log line — inside `TerminateProcess(agent)` during the destructive agent
//! refresh. T524 established the mechanism that explains every one of them: the
//! processes here live inside kill-on-close job objects, and a job teardown
//! kills every member at once, which is also how four relaunch guards died
//! before executing one instruction.
//!
//! The leading hypothesis is that the app and the OLD agent share such a job.
//! Nobody has measured that, because at the instant it matters the app is
//! already dead. So the refresh MEASURES it first and writes it down: this
//! module answers, in one line the log can carry, whether we are in a job, what
//! that job's limit flags are, whether the other process is in a job, and —
//! the actual question — whether the other process is a member of OURS.
//!
//! Everything here degrades to "unknown" rather than to a guess: a denied query
//! is not evidence of absence, and a diagnostic that says `?` is worth more
//! than one that confidently says `no`.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

/// `JOBOBJECT_BASIC_LIMIT_INFORMATION.LimitFlags` bits we care to name. The
/// rest are CPU/memory caps and say nothing about who dies with whom.
pub const limit_breakaway_ok: u32 = 0x00000800;
pub const limit_silent_breakaway_ok: u32 = 0x00001000;
pub const limit_kill_on_job_close: u32 = 0x00002000;

const JobObjectBasicProcessIdList: c_int = 3;
const JobObjectExtendedLimitInformation: c_int = 9;

/// One process pair's job facts. `null` is "could not tell", never "no".
pub const Facts = struct {
    /// Are WE in any job?
    self_in_job: ?bool = null,
    /// Our innermost job's `LimitFlags` (null when jobless or denied).
    self_flags: ?u32 = null,
    /// Is the other process in any job?
    other_in_job: ?bool = null,
    /// Is the other process a member of OUR job? This is the one that matters:
    /// true means terminating it can tear our job down on top of us.
    shared: ?bool = null,
};

/// Human-readable `LimitFlags`, e.g. `0x2800 kill_on_close|breakaway_ok`.
/// Pure — this is the half of the diagnostic that has to be right in the log a
/// year from now, so it is asserted rather than eyeballed.
pub fn describeFlags(buf: []u8, flags: u32) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.print("0x{X}", .{flags}) catch return buf[0..fbs.pos];

    var first = true;
    inline for (.{
        .{ limit_kill_on_job_close, "kill_on_close" },
        .{ limit_breakaway_ok, "breakaway_ok" },
        .{ limit_silent_breakaway_ok, "silent_breakaway_ok" },
    }) |pair| {
        if (flags & pair[0] != 0) {
            w.print("{s}{s}", .{ if (first) " " else "|", pair[1] }) catch
                return buf[0..fbs.pos];
            first = false;
        }
    }
    return buf[0..fbs.pos];
}

/// The whole diagnostic as one log-ready line. Pure, for the same reason.
pub fn describe(buf: []u8, facts: Facts) []const u8 {
    var flag_buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.print("self_in_job={s} self_job_flags={s} agent_in_job={s} SHARED_JOB={s}", .{
        tri(facts.self_in_job),
        if (facts.self_flags) |f| describeFlags(&flag_buf, f) else "?",
        tri(facts.other_in_job),
        tri(facts.shared),
    }) catch {};
    return buf[0..fbs.pos];
}

fn tri(v: ?bool) []const u8 {
    return if (v) |b| (if (b) "yes" else "no") else "?";
}

/// Just this process's side of the question: are WE in a job, and with what
/// limit flags? The startup self-escape (T675) asks exactly this, with no other
/// process in the picture. Same degradation rule as `probe`: null is "could not
/// tell", never "no".
pub const SelfJob = struct {
    in_job: ?bool = null,
    flags: ?u32 = null,
};

pub fn selfJob() SelfJob {
    if (comptime builtin.os.tag != .windows) return .{};

    var facts: SelfJob = .{};

    var b: windows.BOOL = 0;
    if (IsProcessInJob(windows.kernel32.GetCurrentProcess(), null, &b) != 0)
        facts.in_job = b != 0;

    // A NULL job handle asks about the CALLER's job. Denied ⇒ we are not in one
    // (or may not ask), which the null already says.
    var ext: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    var ret: windows.DWORD = 0;
    if (QueryInformationJobObject(
        null,
        JobObjectExtendedLimitInformation,
        &ext,
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        &ret,
    ) != 0) facts.flags = ext.BasicLimitInformation.LimitFlags;

    return facts;
}

/// Measure the facts for `other_pid`. Never fails: every step that cannot be
/// answered leaves its field null.
///
/// `other_handle` is an ALREADY-OPEN handle to that process when the caller has
/// one (the refresh does — it opened it to terminate it), so the probe does not
/// need `PROCESS_QUERY_*` rights of its own. Null is fine; the membership
/// question is answered from our own job's process-id list either way.
pub fn probe(other_pid: u32, other_handle: ?windows.HANDLE) Facts {
    if (comptime builtin.os.tag != .windows) return .{};

    const self = selfJob();
    var facts: Facts = .{
        .self_in_job = self.in_job,
        .self_flags = self.flags,
    };

    if (other_handle) |h| {
        var ob: windows.BOOL = 0;
        if (IsProcessInJob(h, null, &ob) != 0) facts.other_in_job = ob != 0;
    }

    facts.shared = ownJobContains(other_pid);
    return facts;
}

/// Is `pid` a member of the job WE are in? Null when it cannot be answered —
/// including the case where the list came back truncated and the pid was not in
/// the part we got, since the tail could still hold it.
pub fn ownJobContains(pid: u32) ?bool {
    if (comptime builtin.os.tag != .windows) return null;

    // 4 KiB holds ~500 pids on x64. A job with more members than that is not
    // one we can answer about honestly, and says so.
    //
    // ZEROED, not `undefined`: a failed query leaves the buffer exactly as it
    // found it, and reading a count out of uninitialised stack could scan
    // garbage and report a shared job that does not exist. A diagnostic that
    // can lie is worse than one that says `?`.
    var buf: [4096]u8 align(@alignOf(JOBOBJECT_BASIC_PROCESS_ID_LIST)) = @splat(0);
    var ret: windows.DWORD = 0;
    if (QueryInformationJobObject(
        null,
        JobObjectBasicProcessIdList,
        &buf,
        buf.len,
        &ret,
    ) == 0) {
        // ERROR_MORE_DATA means the list was TRUNCATED, not that it is absent:
        // what we were given is real, it is just not all of it. Anything else
        // (not in a job, denied) is unanswerable.
        if (windows.kernel32.GetLastError() != .MORE_DATA) return null;
    }

    const list: *const JOBOBJECT_BASIC_PROCESS_ID_LIST = @ptrCast(&buf);
    const returned = list.NumberOfProcessIdsInList;
    // Guard against a bogus count before indexing: the buffer is written by the
    // kernel, but the arithmetic is ours.
    const max_ids = (buf.len - @sizeOf(JOBOBJECT_BASIC_PROCESS_ID_LIST)) /
        @sizeOf(usize) + 1;
    const n = @min(returned, max_ids);

    const ids: [*]const usize = @ptrCast(&list.ProcessIdList);
    for (ids[0..n]) |id| {
        if (id == pid) return true;
    }
    // Not in what we were given. Only conclusive if we were given all of it.
    if (returned < list.NumberOfAssignedProcesses) return null;
    return false;
}

// =============================================================================
// Win32 declarations
// =============================================================================

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER,
    PerJobUserTimeLimit: windows.LARGE_INTEGER,
    LimitFlags: windows.DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: windows.DWORD,
    Affinity: usize,
    PriorityClass: windows.DWORD,
    SchedulingClass: windows.DWORD,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

const JOBOBJECT_BASIC_PROCESS_ID_LIST = extern struct {
    NumberOfAssignedProcesses: windows.DWORD,
    NumberOfProcessIdsInList: windows.DWORD,
    ProcessIdList: [1]usize,
};

extern "kernel32" fn IsProcessInJob(
    ProcessHandle: windows.HANDLE,
    JobHandle: ?windows.HANDLE,
    Result: *windows.BOOL,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn QueryInformationJobObject(
    hJob: ?windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
    lpReturnLength: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "describeFlags names the production shape" {
    var buf: [64]u8 = undefined;
    // 0x3C00 is what a pane-shell descendant reported on this box (T524).
    try testing.expectEqualStrings(
        "0x3C00 kill_on_close|breakaway_ok|silent_breakaway_ok",
        describeFlags(&buf, 0x3C00),
    );
    try testing.expectEqualStrings(
        "0x2800 kill_on_close|breakaway_ok",
        describeFlags(&buf, 0x2800),
    );
}

test "describeFlags still prints a job with none of the interesting bits" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0x0", describeFlags(&buf, 0));
    // An unrelated limit (ACTIVE_PROCESS 0x8) is shown as a number, not
    // silently dropped: the hex is the fact, the names are the reading of it.
    try testing.expectEqualStrings("0x8", describeFlags(&buf, 0x8));
}

test "describe says ? rather than no for what it could not measure" {
    var buf: [256]u8 = undefined;
    // The whole point of the diagnostic: an unanswerable question must not read
    // as a negative answer, which is what would send the next investigation
    // back down the wrong path.
    try testing.expectEqualStrings(
        "self_in_job=? self_job_flags=? agent_in_job=? SHARED_JOB=?",
        describe(&buf, .{}),
    );
    try testing.expectEqualStrings(
        "self_in_job=yes self_job_flags=0x2000 kill_on_close agent_in_job=yes SHARED_JOB=yes",
        describe(&buf, .{
            .self_in_job = true,
            .self_flags = limit_kill_on_job_close,
            .other_in_job = true,
            .shared = true,
        }),
    );
    try testing.expectEqualStrings(
        "self_in_job=yes self_job_flags=0x0 agent_in_job=no SHARED_JOB=no",
        describe(&buf, .{
            .self_in_job = true,
            .self_flags = 0,
            .other_in_job = false,
            .shared = false,
        }),
    );
}

test "probe never traps on a pid that does not exist" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    // Whatever the box's job situation is, a probe is a diagnostic and must
    // never be the thing that fails a refresh.
    _ = probe(0xFFFF_FFFF, null);
    _ = ownJobContains(0);
}
