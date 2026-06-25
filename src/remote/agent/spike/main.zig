//! WP2 Windows-agent risk spike (§13/§17).
//!
//! This is NOT the production agent — it is the *de-risking* spike the design
//! mandates before WP2 fans out. It writes the Windows-specific code for every
//! item §17 flags as a blocker/verify, in the exact API sequence the real agent
//! will use, so that:
//!
//!   1. Cross-compiling it from a Mac (`zig build-exe -target x86_64-windows-gnu
//!      src/remote/agent/spike/main.zig`) proves the extern prototypes in
//!      `win32.zig` are well-formed and link against MinGW's import libraries.
//!   2. The exact on-Windows test procedure (FINDINGS.md §"on-Windows test
//!      procedure") can be run by hand on a real box — none of this can execute
//!      on macOS.
//!
//! Each function corresponds to one risk:
//!   - `setupBinaryStdio` / `relayStdinToPipe` — binary/COBS stdio (§4.2).
//!   - `ensureSingleInstance`                  — named mutex single-instance (§4.1).
//!   - `ownerOnlyPipeSecurity` / `createDaemonPipe` — owner-only DACL +
//!     FIRST_PIPE_INSTANCE + reject-remote (§4.1/§15 M6).
//!   - `acceptAndIdentifyClient`               — peer-cred via
//!     GetNamedPipeClientProcessId (§9.5).
//!   - `connectToDaemonPipe`                   — WaitNamedPipe startup-race
//!     handling (§4.1).
//!   - `startDaemonViaScheduledTask`           — out-of-band daemon (NOT
//!     breakaway-from-sshd) (§4.1/§13).
//!   - `createDaemonJob` / `spawnContainedSession` / `jobAccounting` — Job-Object
//!     containment topology + caps + accounting (§9.1/§13.4).
//!   - `interruptSession` / `killSession`      — Ctrl-C escalation vs hard kill
//!     (§9.2).
//!
//! `main` dispatches on argv so every extern is referenced and thus linked
//! (the build-time proof).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const w32 = @import("win32.zig");
// `protocol` is supplied as a module by the build graph (see FINDINGS.md for the
// exact `zig build-exe --dep protocol -Mprotocol=src/remote/protocol.zig …`
// command). build.zig will wire the same module when the agent is real.
const protocol = @import("protocol");

comptime {
    // The spike is Windows-only by construction.
    if (builtin.os.tag != .windows) {
        @compileError("the WP2 spike is Windows-only; build with -target x86_64-windows-gnu");
    }
}

const log = std.log.scoped(.agent_spike);

/// The daemon's local endpoint. The `<sid>` in a real name is obfuscation, not
/// access control — the owner-only DACL is what enforces access (§15 M6).
const pipe_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "\\\\.\\pipe\\ghoztty-agent",
);

/// Single-instance mutex name (Local\ namespace = per-session, per-user).
const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "Local\\ghoztty-agent-singleton",
);

/// Owner-only DACL: protected (`P`), one ACE granting GENERIC_ALL (`GA`) to the
/// object OWNER (`OW`). No Everyone/Authenticated-Users ACE → only the creating
/// user can open the pipe (§15 M6).
const owner_only_sddl = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;OW)");

pub const SpikeError = error{
    AlreadyRunning,
    PipeNameSquatted,
    PipeCreateFailed,
    SecurityDescriptorFailed,
    DaemonUnreachable,
    JobCreateFailed,
    JobAssignFailed,
    SpawnFailed,
    Win32,
};

fn lastError() w32.DWORD {
    return @intFromEnum(windows.GetLastError());
}

// -----------------------------------------------------------------------------
// 1. Binary / COBS stdio (§4.2)
// -----------------------------------------------------------------------------

/// Get the raw std handles. We deliberately use `ReadFile`/`WriteFile` on the
/// raw handle rather than the CRT (`_setmode(_O_BINARY)`): the raw kernel handle
/// performs NO CR/LF translation, sidestepping the `ssh-shellhost.exe` mangling
/// class (#1256) at the source. (We still wrap frames in COBS/base64 because the
/// *ssh hop* — not our local handle — is what can corrupt bytes; see
/// FINDINGS.md.) Returns `{ stdin, stdout }`.
fn setupBinaryStdio() struct { in: w32.HANDLE, out: w32.HANDLE } {
    const in = windows.kernel32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;
    const out = windows.kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse
        windows.INVALID_HANDLE_VALUE;
    return .{ .in = in, .out = out };
}

/// The SSH bridge is a *pure relay* (§13.1): it shuttles framed bytes between the
/// SSH stdio (here, our std handles) and the daemon's named pipe — it owns no
/// ConPTY. This demonstrates the read side plus COBS framing of one frame to
/// prove the `protocol` codec compiles for a Windows target.
fn relayStdinToPipe(std_in: w32.HANDLE, pipe: w32.HANDLE) SpikeError!void {
    var buf: [4096]u8 = undefined;
    var cobs_buf: [protocol.cobs.maxEncodedLen(4096) + 1]u8 = undefined;
    while (true) {
        var read: w32.DWORD = 0;
        if (windows.kernel32.ReadFile(std_in, &buf, buf.len, &read, null) == 0)
            return; // EOF / pipe closed
        if (read == 0) return;

        // Frame the chunk with COBS + a 0x00 delimiter, exactly as the wire layer
        // does on a Windows hop (§4.2). (The real relay frames whole protocol
        // frames, not raw chunks; this is the codec smoke-test.)
        const n = protocol.cobs.encode(buf[0..read], &cobs_buf);
        cobs_buf[n] = 0;

        var written: w32.DWORD = 0;
        if (windows.kernel32.WriteFile(pipe, &cobs_buf, @intCast(n + 1), &written, null) == 0)
            return SpikeError.Win32;
    }
}

// -----------------------------------------------------------------------------
// 2. Single-instance mutex (§4.1)
// -----------------------------------------------------------------------------

/// Acquire the singleton mutex. Two bridges attaching at once both reach here;
/// only the first creates the daemon, the rest get `AlreadyRunning` and converge
/// on it. Returns the mutex handle (held for the daemon's lifetime).
fn ensureSingleInstance() SpikeError!w32.HANDLE {
    const h = w32.CreateMutexW(null, windows.TRUE, mutex_name) orelse
        return SpikeError.Win32;
    if (lastError() == w32.ERROR_ALREADY_EXISTS) {
        _ = windows.CloseHandle(h);
        return SpikeError.AlreadyRunning;
    }
    return h;
}

// -----------------------------------------------------------------------------
// 3. Owner-only pipe (DACL + FIRST_PIPE_INSTANCE + reject-remote) (§4.1/§15 M6)
// -----------------------------------------------------------------------------

const PipeSecurity = struct {
    sa: w32.SECURITY_ATTRIBUTES,
    sd: w32.PSECURITY_DESCRIPTOR,

    fn deinit(self: *PipeSecurity) void {
        _ = w32.LocalFree(self.sd);
        self.* = undefined;
    }
};

/// Translate the owner-only SDDL into a SECURITY_ATTRIBUTES the pipe inherits.
/// The SDDL is a fixed constant — no caller-supplied value is ever interpolated
/// into it (mirrors the OSC-9;9 injection-safety rule, §9.4).
fn ownerOnlyPipeSecurity() SpikeError!PipeSecurity {
    var sd: w32.PSECURITY_DESCRIPTOR = undefined;
    if (w32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
        owner_only_sddl,
        w32.SDDL_REVISION_1,
        &sd,
        null,
    ) == 0) return SpikeError.SecurityDescriptorFailed;

    return .{
        .sa = .{
            .nLength = @sizeOf(w32.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = sd,
            .bInheritHandle = windows.FALSE,
        },
        .sd = sd,
    };
}

/// Create the daemon's pipe server with the three fail-closed guards:
///   - FILE_FLAG_FIRST_PIPE_INSTANCE → fail if the name already exists (squat).
///   - PIPE_REJECT_REMOTE_CLIENTS    → no off-box clients.
///   - owner-only DACL               → no other local user.
/// A squat surfaces as ACCESS_DENIED → `PipeNameSquatted` (§15 M6).
fn createDaemonPipe(sec: *PipeSecurity) SpikeError!w32.HANDLE {
    const open_mode: w32.DWORD =
        w32.PIPE_ACCESS_DUPLEX |
        w32.FILE_FLAG_FIRST_PIPE_INSTANCE;
    const pipe_mode: w32.DWORD =
        w32.PIPE_TYPE_BYTE |
        w32.PIPE_READMODE_BYTE |
        w32.PIPE_WAIT |
        w32.PIPE_REJECT_REMOTE_CLIENTS;

    const h = windows.kernel32.CreateNamedPipeW(
        pipe_name,
        open_mode,
        pipe_mode,
        w32.PIPE_UNLIMITED_INSTANCES,
        64 * 1024, // out buffer
        64 * 1024, // in buffer
        0, // default timeout
        &sec.sa,
    );
    if (h == windows.INVALID_HANDLE_VALUE) {
        return switch (lastError()) {
            w32.ERROR_ACCESS_DENIED, w32.ERROR_ALREADY_EXISTS => SpikeError.PipeNameSquatted,
            else => SpikeError.PipeCreateFailed,
        };
    }
    return h;
}

// -----------------------------------------------------------------------------
// 4. Peer-cred identity (§9.5)
// -----------------------------------------------------------------------------

/// Wait for a client, then derive its PID from the kernel — the unforgeable
/// peer-cred identity the daemon maps PID→session via job membership (§9.5).
/// Returns the client PID.
fn acceptAndIdentifyClient(pipe: w32.HANDLE) SpikeError!w32.ULONG {
    // ConnectNamedPipe returns 0 with ERROR_PIPE_CONNECTED if a client already
    // raced in; treat both as connected.
    _ = w32.ConnectNamedPipe(pipe, null);

    var client_pid: w32.ULONG = 0;
    if (w32.GetNamedPipeClientProcessId(pipe, &client_pid) == 0)
        return SpikeError.Win32;
    return client_pid;
}

// -----------------------------------------------------------------------------
// 5. Bridge connect with the schtasks startup race (§4.1)
// -----------------------------------------------------------------------------

/// Connect to the daemon pipe from the SSH bridge. Because `schtasks /run` is
/// async (returns on trigger, not on listen), the pipe may not exist yet, so we
/// `WaitNamedPipeW` with bounded backoff before each `CreateFileW`, capped well
/// under the exit-code-13 (agent-deploy-failed, §10.2) budget.
fn connectToDaemonPipe() SpikeError!w32.HANDLE {
    var attempt: u32 = 0;
    const max_attempts = 50; // ~50 * 100ms = 5s, < the cold-connect budget
    while (attempt < max_attempts) : (attempt += 1) {
        const h = windows.kernel32.CreateFileW(
            pipe_name,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            0,
            null,
        );
        if (h != windows.INVALID_HANDLE_VALUE) return h;

        switch (lastError()) {
            // Pipe not created yet, or all instances busy: wait for one.
            w32.ERROR_FILE_NOT_FOUND, w32.ERROR_PIPE_BUSY => {
                _ = w32.WaitNamedPipeW(pipe_name, 100); // 100ms bounded wait
            },
            else => return SpikeError.DaemonUnreachable,
        }
    }
    return SpikeError.DaemonUnreachable;
}

// -----------------------------------------------------------------------------
// 6. Out-of-band daemon via Scheduled Task — NOT breakaway-from-sshd (§4.1/§13)
// -----------------------------------------------------------------------------

/// Register (idempotently) and run the daemon as a per-user Scheduled Task, so
/// Task Scheduler launches it in its OWN job decoupled from sshd's job — which,
/// unlike `CREATE_BREAKAWAY_FROM_JOB`, actually works under
/// `ssh-shellhost.exe` (Win32-OpenSSH#1032). `/create /f` is idempotent; `/run`
/// is async (hence `connectToDaemonPipe`'s WaitNamedPipe loop).
fn startDaemonViaScheduledTask(alloc: std.mem.Allocator, agent_path: []const u8) SpikeError!void {
    const task = "ghoztty-agent-daemon";

    // schtasks /create /f /sc ONLOGON /tn <task> /tr "<agent> daemon" /it /rl LIMITED
    const create_u8 = std.fmt.allocPrint(
        alloc,
        "schtasks /create /f /sc ONLOGON /tn {s} /tr \"\\\"{s}\\\" daemon\" /it /rl LIMITED",
        .{ task, agent_path },
    ) catch return SpikeError.SpawnFailed;
    defer alloc.free(create_u8);

    const run_u8 = std.fmt.allocPrint(
        alloc,
        "schtasks /run /tn {s}",
        .{task},
    ) catch return SpikeError.SpawnFailed;
    defer alloc.free(run_u8);

    try runDetached(alloc, create_u8);
    try runDetached(alloc, run_u8);
}

/// Spawn a command line via CreateProcessW, detached (no console window). Used
/// for the schtasks invocations. NOTE: `DETACHED_PROCESS` only detaches the
/// console, not the job — daemon survival comes from Task Scheduler, not this.
fn runDetached(alloc: std.mem.Allocator, cmdline_u8: []const u8) SpikeError!void {
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmdline_u8) catch
        return SpikeError.SpawnFailed;
    defer alloc.free(cmd_w);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    if (w32.CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        windows.FALSE,
        w32.CREATE_NO_WINDOW | w32.DETACHED_PROCESS,
        null,
        null,
        &si,
        &pi,
    ) == 0) return SpikeError.SpawnFailed;

    _ = windows.CloseHandle(pi.hThread);
    _ = windows.CloseHandle(pi.hProcess);
}

// -----------------------------------------------------------------------------
// 7. Job-Object containment topology (§9.1/§13.4)
// -----------------------------------------------------------------------------

/// The daemon owns a job with BREAKAWAY_OK (so its session children may break
/// away and be reassigned) + KILL_ON_JOB_CLOSE (clean teardown) + the §7.1
/// resource caps (active-process limit; memory cap shown). This is the *only*
/// place BREAKAWAY_OK is valid — because the daemon controls its own job, unlike
/// sshd's (§13.4).
fn createDaemonJob() SpikeError!w32.HANDLE {
    const job = w32.CreateJobObjectW(null, null) orelse return SpikeError.JobCreateFailed;
    errdefer _ = windows.CloseHandle(job);

    var info: w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(
        w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    );
    info.BasicLimitInformation.LimitFlags =
        w32.JOB_OBJECT_LIMIT_BREAKAWAY_OK |
        w32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        w32.JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    info.BasicLimitInformation.ActiveProcessLimit = 1024; // backstop

    if (w32.SetInformationJobObject(
        job,
        .ExtendedLimitInformation,
        &info,
        @sizeOf(w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == 0) return SpikeError.JobCreateFailed;

    return job;
}

const Session = struct {
    process: w32.HANDLE,
    thread: w32.HANDLE,
    pid: w32.DWORD,
    job: w32.HANDLE, // per-session containment job
};

/// Spawn a session's ConPTY child and contain it (§13.4):
///   - CREATE_BREAKAWAY_FROM_JOB → leave the daemon's job…
///   - CREATE_NEW_PROCESS_GROUP  → own process group (for GenerateConsoleCtrlEvent)
///   - then AssignProcessToJobObject into a fresh per-session job.
/// If reassignment is refused, the real agent falls back to a nested job; here we
/// surface `JobAssignFailed` for the on-Windows test to observe.
fn spawnContainedSession(
    alloc: std.mem.Allocator,
    cmdline_u8: []const u8,
) SpikeError!Session {
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmdline_u8) catch
        return SpikeError.SpawnFailed;
    defer alloc.free(cmd_w);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    // (Real agent attaches the ConPTY HPCON via PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
    // here, as Command.zig:294 does; omitted in the spike to keep it focused on
    // the containment topology.)
    if (w32.CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        windows.FALSE,
        w32.CREATE_BREAKAWAY_FROM_JOB | w32.CREATE_NEW_PROCESS_GROUP | w32.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    ) == 0) return SpikeError.SpawnFailed;
    errdefer {
        _ = windows.CloseHandle(pi.hThread);
        _ = windows.CloseHandle(pi.hProcess);
    }

    const session_job = w32.CreateJobObjectW(null, null) orelse
        return SpikeError.JobCreateFailed;
    errdefer _ = windows.CloseHandle(session_job);

    if (w32.AssignProcessToJobObject(session_job, pi.hProcess) == 0)
        return SpikeError.JobAssignFailed; // → real agent retries with a nested job

    return .{
        .process = pi.hProcess,
        .thread = pi.hThread,
        .pid = pi.dwProcessId,
        .job = session_job,
    };
}

/// Read accounting for the monitor view (§9.3). Returns active process count.
fn jobAccounting(job: w32.HANDLE) SpikeError!w32.DWORD {
    var acct: w32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = std.mem.zeroes(
        w32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
    );
    if (w32.QueryInformationJobObject(
        job,
        .BasicAccountingInformation,
        &acct,
        @sizeOf(w32.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION),
        null,
    ) == 0) return SpikeError.Win32;
    return acct.ActiveProcesses;
}

// -----------------------------------------------------------------------------
// 8. Ctrl-C escalation vs hard kill (§9.2)
// -----------------------------------------------------------------------------

/// Interactive interrupt is NOT a kill (§9.2). Escalation order on Windows:
///   1. write 0x03 to ConPTY input (handles the console-read case directly), then
///   2. GenerateConsoleCtrlEvent(CTRL_C_EVENT, pgid) (child in its own group), and
///   only an explicit kill uses `killSession` (TerminateJobObject).
fn interruptSession(conpty_input: w32.HANDLE, process_group_id: w32.DWORD) SpikeError!void {
    const etx = [_]u8{0x03};
    var written: w32.DWORD = 0;
    _ = windows.kernel32.WriteFile(conpty_input, &etx, 1, &written, null);

    if (w32.GenerateConsoleCtrlEvent(windows.CTRL_C_EVENT, process_group_id) == 0)
        return SpikeError.Win32;
}

/// Hard kill: terminate the whole containment job atomically (§9.2 default for
/// `+remote kill`). Reaps setsid-style escapees that `kill -pgid` would miss.
fn killSession(session_job: w32.HANDLE) void {
    _ = w32.TerminateJobObject(session_job, 1);
}

// -----------------------------------------------------------------------------
// Dispatcher — references every path so the externs link (build-time proof)
// -----------------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe
    const mode = args.next() orelse "daemon";

    if (std.mem.eql(u8, mode, "daemon")) {
        try runDaemon(alloc);
    } else if (std.mem.eql(u8, mode, "bridge")) {
        try runBridge();
    } else if (std.mem.eql(u8, mode, "spawn-daemon")) {
        try startDaemonViaScheduledTask(alloc, "C:\\Users\\me\\ghoztty-agent.exe");
    } else {
        log.err("unknown mode: {s}", .{mode});
        return error.UnknownMode;
    }
}

fn runDaemon(alloc: std.mem.Allocator) !void {
    const mutex = ensureSingleInstance() catch |err| switch (err) {
        SpikeError.AlreadyRunning => {
            log.info("another daemon already owns the singleton; exiting", .{});
            return;
        },
        else => return err,
    };
    defer _ = windows.CloseHandle(mutex);

    const daemon_job = try createDaemonJob();
    defer _ = windows.CloseHandle(daemon_job);

    var sec = try ownerOnlyPipeSecurity();
    defer sec.deinit();

    const pipe = try createDaemonPipe(&sec);
    defer _ = windows.CloseHandle(pipe);

    const client_pid = try acceptAndIdentifyClient(pipe);
    log.info("bridge connected, peer pid={d}", .{client_pid});

    const session = try spawnContainedSession(alloc, "pwsh.exe -NoLogo");
    defer {
        _ = windows.CloseHandle(session.thread);
        _ = windows.CloseHandle(session.process);
        _ = windows.CloseHandle(session.job);
    }

    const active = try jobAccounting(session.job);
    log.info("session pid={d} active_in_job={d}", .{ session.pid, active });

    // Escalation demo: ^C the session (its own process group), then hard-kill.
    try interruptSession(pipe, session.pid);
    killSession(session.job);
}

fn runBridge() !void {
    const std_io = setupBinaryStdio();
    const pipe = try connectToDaemonPipe();
    defer _ = windows.CloseHandle(pipe);
    try relayStdinToPipe(std_io.in, pipe);
}
