//! Single-instance guard for the `ghoztty-agent` DAEMON modes (`--listen`,
//! `--relay`).
//!
//! ## Why
//! Multiple supervisors can (and did, live) race to keep the agent alive on the
//! same box — the installer's scheduled-task launcher AND an SMB deploy-watcher
//! script both respawn-on-exit, and each happily launched its own agent (two
//! daemons fighting over the listen port / relay control
//! socket). The agent itself must be idempotent at the process level: the
//! SECOND daemon instance detects the first and exits immediately with a
//! distinct, documented exit code, so a supervisor's keep-alive loop degrades
//! into a cheap respawn-and-exit heartbeat instead of a second daemon.
//!
//! ## Mechanism (per platform, per user)
//!   - **Windows**: a named mutex `Global\GhozttyAgentDaemon-<user-SID>` via
//!     `CreateMutexW`. The GLOBAL namespace is shared across ALL logon
//!     sessions, and the SID suffix keeps different users from blocking each
//!     other. This matters because `Local\` scopes per LOGON SESSION, NOT per
//!     user: a scheduled-task/service supervisor ("run whether user is logged
//!     on or not") lives in a DIFFERENT logon session than an interactive
//!     launch, so a `Local\`-only guard let two same-user daemons coexist —
//!     exactly the live dup-daemon incident this rework fixes. Per MS "Kernel
//!     object namespaces": creating a MUTEX in `Global\` requires NO special
//!     privilege — the `SeCreateGlobalPrivilege` check is limited to
//!     file-mapping and symbolic-link objects — and using a global named
//!     object to detect "already an instance running across all sessions" is
//!     the doc's own example. Fallback chain, so the guard never regresses
//!     below the old behavior: SID unavailable → username suffix
//!     (`GetUserNameW`); `Global\` create denied (AppContainer-style sandboxes
//!     where the global namespace is unavailable) → the legacy per-session
//!     `Local\GhozttyAgentDaemon`. An ACCESS_DENIED from `CreateMutexW` is
//!     disambiguated with a minimal `OpenMutexW(SYNCHRONIZE)` probe: name
//!     exists but is unopenable (e.g. the first daemon runs elevated) →
//!     already running; name absent → namespace unusable → fall back. The
//!     handle is held for the process lifetime; the OS destroys the mutex when
//!     the last handle closes (normal exit OR crash), so no stale-lock cleanup
//!     is ever needed. Detection is the classic `GetLastError() ==
//!     ERROR_ALREADY_EXISTS` after `CreateMutexW` — we never wait on the mutex,
//!     so abandonment semantics don't apply.
//!   - **POSIX**: an advisory `flock(LOCK_EX | LOCK_NB)` on a lock file next to
//!     the agent's other per-user state (`~/.config/ghoztty/agent.lock`, or
//!     `$XDG_CONFIG_HOME/ghoztty/agent.lock`; `GHOSTTY_AGENT_LOCK` overrides
//!     the full path — tests use this). The fd is held for the process
//!     lifetime; the kernel releases the flock when the fd closes (normal exit
//!     OR crash), so a stale lock file on disk is harmless — it's the LOCK,
//!     not the file's existence, that gates. flock is per open-file-
//!     description, so a second process (or even a second `open()` of the same
//!     path) conflicts.
//!
//! ## Exit code
//! On conflict the daemon logs `ghoztty-agent: another instance is already
//! running; exiting` and exits with **code 183** (`already_running_exit_code`)
//! — deliberately chosen to mirror Windows' `ERROR_ALREADY_EXISTS` (183) so
//! the value is self-describing in supervisor logs on either OS.
//!
//! ## Which modes take the lock
//! Only the daemon modes (`--listen`, `--relay`, and the bare-invocation
//! default which is `--listen`). `--stdio` is a per-ssh-connection servant
//! (many may legitimately coexist) and `--enroll` is a one-shot utility that
//! must work WHILE a daemon runs — neither takes the lock.
//!
//! ## Takeover — "there should be only one" (`acquireWithTakeover`)
//! Losing the guard race no longer means blind deference: the holder might be
//! SIGSTOP'd, deadlocked, or an anomaly that leaked the lock. The winning
//! daemon proves liveness by touching a HEARTBEAT file containing its PID
//! (`agent.heartbeat`, sibling of the other per-user agent state:
//! `%LOCALAPPDATA%\ghoztty\` on Windows, `$XDG_CONFIG_HOME|~/.config/ghoztty/`
//! on POSIX; `GHOSTTY_AGENT_HEARTBEAT` overrides — tests) every
//! `heartbeat_interval_ms` (10s). A challenger that hits AlreadyRunning:
//!
//!   1. Reads the heartbeat. FRESH (mtime age < `heartbeat_stale_after_ms`,
//!      45s) → the holder is alive and responsive → yield (exit 183 upstream).
//!   2. STALE → the holder is stuck. Verify the PID still names a
//!      ghoztty-agent image (QueryFullProcessImageNameW / proc_pidpath /
//!      /proc/<pid>/exe, best-effort) so PID reuse can't friendly-fire an
//!      innocent process: confirmed-agent → kill it (TerminateProcess /
//!      SIGKILL) and take the guard; confirmed-OTHER → never kill, yield with
//!      a warning; unverifiable → kill only because the guard is provably
//!      still held (re-checked immediately before the verdict).
//!   3. NO heartbeat file at all → an old-binary (pre-heartbeat) holder or a
//!      racing first run: treated as responsive → yield. (`--force-replace`
//!      cannot help here either — with no PID on record there is nobody safe
//!      to kill.)
//!   4. After a kill, the OS frees the mutex/flock with the process; the
//!      challenger retries acquisition in a short bounded loop (5 × 200ms)
//!      and, if the guard is SOMEHOW still held, yields — when in doubt, die:
//!      never two daemons.
//!
//! ## Sandbox lineages (`GHOZTTY_AGENT_INSTANCE`, T167)
//! The guard identity is otherwise a COMPILE-TIME fact (`local` / `local-debug`
//! / relay), which means a debug agent already on the box refuses every test
//! sandbox's agent — silently, since the app just falls back to non-persistent
//! panes. `instanceWithSuffix` forks the key off the env var so a sandbox names
//! its own mutex, lock file and heartbeat; unset (production) reproduces the
//! legacy names byte for byte. See `../agent_lineage.zig` for the full story
//! and for the other derivations the same suffix moves.
//!
//! `--force-replace` (daemon modes) skips the freshness check and kills the
//! recorded holder unconditionally (still refusing confirmed-other PIDs), for
//! a human who wants THIS launch to win. The decision matrix is the pure
//! `takeoverVerdict` (unit-tested); the kill/probe syscalls are thin glue.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const agent_lineage = @import("../agent_lineage.zig");

/// Exit code used when another daemon instance already holds the lock.
/// 183 == Windows ERROR_ALREADY_EXISTS, reused verbatim on POSIX so the code
/// reads the same in any supervisor's log.
pub const already_running_exit_code: u8 = 183;

/// Which daemon instance a guard is for. The local session-persistence agent
/// (`--listen-pipe`, T89d) and the relay agent (`--relay`) are SEPARATE daemons
/// that must coexist on one box (T89a decision 2), so each takes a distinctly
/// NAMED guard + heartbeat. The relay / TCP-listen singleton keeps the LEGACY
/// names (empty key) so a running relay agent's guard is byte-for-byte
/// unchanged across this upgrade; only the local agent gets a distinct key.
pub const Instance = struct {
    /// Name segment inserted into the mutex name and the lock/heartbeat
    /// filenames. Empty ⇒ the legacy singleton names (relay / TCP listen);
    /// non-empty ⇒ a distinct instance. Sanitized defensively by the composers,
    /// but keep it filesystem- and mutex-name-safe by construction.
    key: []const u8 = "",

    /// The relay / TCP-listen daemon: legacy names, unchanged.
    pub const relay: Instance = .{ .key = "" };
    /// The local session-persistence agent (release lineage).
    pub const local: Instance = .{ .key = "local" };
    /// The local session-persistence agent (debug lineage — its own dir/pipe
    /// suffix per T89a decision 2, so its own guard too).
    pub const local_debug: Instance = .{ .key = "local-debug" };
};

/// Compose a guard key for a SANDBOXED lineage: the build's own key plus the
/// `GHOZTTY_AGENT_INSTANCE` suffix, into `buf` (T167). An absent suffix
/// reproduces `base.key` byte for byte, which is every production run — so this
/// can only ever ADD identities, never move an existing one.
///
/// This is what lets a test sandbox run its own agent while the box's agent
/// keeps holding the user's real panes: without it the sandbox's agent exits
/// 183 and the sandbox silently tests the non-persistent path. `buf` outlives
/// the returned `Instance` (its `key` borrows it).
pub fn instanceWithSuffix(buf: []u8, base: Instance, suffix: ?[]const u8) error{NameTooLong}!Instance {
    return .{ .key = try agent_lineage.appendSuffix(buf, base.key, suffix) };
}

pub const AcquireError = error{
    /// Another daemon instance holds the guard in this user session.
    AlreadyRunning,
    /// The guard infrastructure itself failed (couldn't create the mutex /
    /// lock file). Callers should log and CONTINUE serving — daemon
    /// availability beats guard integrity (the daemon serves anyway).
    GuardUnavailable,
};

/// A held single-instance guard. Keep it alive for the whole daemon lifetime;
/// `release` exists for tests and symmetry — in production the OS reclaims the
/// mutex handle / flock on process exit (clean or crash), so never calling
/// `release` is correct.
pub const Guard = struct {
    impl: Impl,

    const Impl = if (builtin.os.tag == .windows)
        struct { handle: std.os.windows.HANDLE }
    else
        struct { fd: std.posix.fd_t };

    pub fn release(self: *Guard) void {
        if (builtin.os.tag == .windows) {
            std.os.windows.CloseHandle(self.impl.handle);
        } else {
            // Closing the fd drops the flock (per open-file-description).
            std.posix.close(self.impl.fd);
        }
        self.* = undefined;
    }
};

/// Acquire the per-user daemon guard. See the module doc for the
/// platform mechanisms. `alloc` is only used transiently (path resolution on
/// POSIX); the returned `Guard` owns no heap memory.
pub fn acquire(alloc: Allocator, instance: Instance) AcquireError!Guard {
    if (builtin.os.tag == .windows) return acquireWindows(instance);
    const path = lockFilePath(alloc, instance) catch return error.GuardUnavailable;
    defer alloc.free(path);
    return acquirePath(path);
}

// -----------------------------------------------------------------------------
// Windows: named mutex (Global\ per-user, with a Local\ fallback)
// -----------------------------------------------------------------------------

/// UTF-8 prefix of the preferred (cross-logon-session) mutex name. The suffix
/// is the current user's SID string — or the username when the SID can't be
/// resolved — so distinct users never block each other while ALL of one
/// user's logon sessions (interactive, scheduled task, service) share ONE
/// guard. Public so the name composition is unit-testable off-Windows.
pub const global_mutex_name_prefix = "Global\\GhozttyAgentDaemon-";

/// UTF-8 prefix of the legacy per-logon-session fallback name (`Local\` =
/// per-logon-session namespace — see the module doc for why that's too weak
/// as the primary): sandboxed contexts without Global\ access still get
/// today's per-session guard rather than none at all. The instance key (if
/// any) is appended as `-<key>` by `composeLocalMutexName`.
pub const local_mutex_name_base = "Local\\GhozttyAgentDaemon";

/// Compose `Global\GhozttyAgentDaemon-[<key>-]<user_id>` into `buf`. Both the
/// instance key and the id are sanitized: backslashes (illegal in a mutex name
/// anywhere past the namespace prefix) and control characters become `_`. An
/// empty key reproduces the LEGACY `Global\GhozttyAgentDaemon-<user_id>` name
/// verbatim (no double dash). Pure — testable on any host; the Windows path
/// converts the result to UTF-16 for CreateMutexW.
pub fn composeGlobalMutexName(buf: []u8, key: []const u8, user_id: []const u8) error{NameTooLong}![]const u8 {
    const key_len = if (key.len == 0) 0 else key.len + 1; // "<key>-"
    const total = global_mutex_name_prefix.len + key_len + user_id.len;
    if (total > buf.len) return error.NameTooLong;
    @memcpy(buf[0..global_mutex_name_prefix.len], global_mutex_name_prefix);
    var i = global_mutex_name_prefix.len;
    if (key.len != 0) {
        for (key) |c| {
            buf[i] = if (c == '\\' or c < 0x20) '_' else c;
            i += 1;
        }
        buf[i] = '-';
        i += 1;
    }
    for (user_id) |c| {
        buf[i] = if (c == '\\' or c < 0x20) '_' else c;
        i += 1;
    }
    return buf[0..total];
}

/// Compose the `Local\` fallback name `Local\GhozttyAgentDaemon[-<key>]` into
/// `buf`. Empty key reproduces the LEGACY literal exactly. Same sanitization as
/// the global composer. Pure; unit-tested off-Windows.
pub fn composeLocalMutexName(buf: []u8, key: []const u8) error{NameTooLong}![]const u8 {
    const key_len = if (key.len == 0) 0 else key.len + 1; // "-<key>"
    const total = local_mutex_name_base.len + key_len;
    if (total > buf.len) return error.NameTooLong;
    @memcpy(buf[0..local_mutex_name_base.len], local_mutex_name_base);
    var i = local_mutex_name_base.len;
    if (key.len != 0) {
        buf[i] = '-';
        i += 1;
        for (key) |c| {
            buf[i] = if (c == '\\' or c < 0x20) '_' else c;
            i += 1;
        }
    }
    return buf[0..total];
}

fn acquireWindows(instance: Instance) AcquireError!Guard {
    if (builtin.os.tag != .windows) unreachable;

    // Preferred: Global\ + [instance key +] per-user id (SID, else username).
    // Any failure on this path degrades to the legacy Local\ guard — never
    // below it.
    var id_buf: [768]u8 = undefined; // UNLEN=256 UTF-16 units ≤ 768 UTF-8 bytes
    if (windowsUserId(&id_buf)) |id| global: {
        var name8: [832]u8 = undefined;
        const name = composeGlobalMutexName(&name8, instance.key, id) catch break :global;
        var name16: [833]u16 = undefined;
        const n16 = std.unicode.utf8ToUtf16Le(name16[0..832], name) catch break :global;
        name16[n16] = 0;
        switch (tryCreateMutex(name16[0..n16 :0])) {
            .acquired => |h| return .{ .impl = .{ .handle = h } },
            .already_running => return error.AlreadyRunning,
            .namespace_unavailable => {},
        }
        std.debug.print(
            "ghoztty-agent: single-instance: Global\\ mutex unavailable; falling back to the per-logon-session Local\\ mutex (guard will NOT span logon sessions)\n",
            .{},
        );
    } else {
        std.debug.print(
            "ghoztty-agent: single-instance: user SID/name lookup failed; falling back to the per-logon-session Local\\ mutex (guard will NOT span logon sessions)\n",
            .{},
        );
    }

    // Fallback: the legacy per-logon-session guard (today's behavior), keyed to
    // the instance so local and relay don't share it either.
    var local8: [128]u8 = undefined;
    const local_name = composeLocalMutexName(&local8, instance.key) catch return error.GuardUnavailable;
    var local16: [129]u16 = undefined;
    const ln16 = std.unicode.utf8ToUtf16Le(local16[0..128], local_name) catch return error.GuardUnavailable;
    local16[ln16] = 0;
    return switch (tryCreateMutex(local16[0..ln16 :0])) {
        .acquired => |h| .{ .impl = .{ .handle = h } },
        .already_running => error.AlreadyRunning,
        .namespace_unavailable => error.GuardUnavailable,
    };
}

const CreateOutcome = union(enum) {
    acquired: std.os.windows.HANDLE,
    already_running,
    /// The name couldn't be created OR proven to exist — the namespace (or
    /// the mutex machinery) is unusable here; try the next fallback.
    namespace_unavailable,
};

/// One CreateMutexW attempt with full outcome classification. bInitialOwner =
/// FALSE: we never wait on / own the mutex — its mere EXISTENCE (first
/// creator wins) is the whole signal, which also means abandoned-mutex
/// semantics can never bite us.
fn tryCreateMutex(name: [*:0]const u16) CreateOutcome {
    if (builtin.os.tag != .windows) unreachable;
    const handle = win32.CreateMutexW(null, 0, name) orelse {
        if (std.os.windows.GetLastError() == .ACCESS_DENIED) {
            // Ambiguous: either the name EXISTS but its DACL / integrity
            // level refuses CreateMutexW's implicit MUTEX_ALL_ACCESS open
            // (e.g. the first daemon runs elevated → that IS another
            // instance), or the namespace itself is off limits (AppContainer-
            // style sandbox). A minimal SYNCHRONIZE probe tells them apart.
            if (win32.OpenMutexW(win32.SYNCHRONIZE, 0, name)) |h| {
                std.os.windows.CloseHandle(h);
                return .already_running;
            }
            if (std.os.windows.GetLastError() == .ACCESS_DENIED) return .already_running;
            return .namespace_unavailable;
        }
        return .namespace_unavailable;
    };
    if (std.os.windows.GetLastError() == .ALREADY_EXISTS) {
        // Another instance created it first. Drop our handle (the winner's
        // handle keeps the mutex alive) and report the conflict.
        std.os.windows.CloseHandle(handle);
        return .already_running;
    }
    return .{ .acquired = handle };
}

/// Resolve a stable per-user identity string for the mutex suffix, into `buf`:
/// the current process token's user SID (canonical — identical across ALL of
/// the user's logon sessions, elevated or not), else the bare username from
/// `GetUserNameW`. Null when both fail (caller falls back to `Local\`).
fn windowsUserId(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) unreachable;

    sid: {
        var tok: std.os.windows.HANDLE = undefined;
        if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &tok) == 0) break :sid;
        defer std.os.windows.CloseHandle(tok);

        // TOKEN_USER (16 bytes on x64) + SECURITY_MAX_SID_SIZE (68) ≤ 128.
        var info_buf: [128]u8 align(8) = undefined;
        var ret_len: u32 = 0;
        if (win32.GetTokenInformation(tok, win32.TokenUser, &info_buf, info_buf.len, &ret_len) == 0) break :sid;
        const tu: *const win32.TOKEN_USER = @ptrCast(&info_buf);

        var sid_w: ?[*:0]u16 = null;
        if (win32.ConvertSidToStringSidW(tu.User.Sid, &sid_w) == 0) break :sid;
        const s = sid_w orelse break :sid;
        defer _ = win32.LocalFree(s);

        const n = std.unicode.utf16LeToUtf8(buf, std.mem.span(s)) catch break :sid;
        if (n == 0) break :sid;
        return buf[0..n];
    }

    // Fallback: username. Less canonical than the SID (renames, collisions
    // across domains) but still per-user and cross-session.
    var name_w: [257]u16 = undefined;
    var len: u32 = name_w.len;
    if (win32.GetUserNameW(&name_w, &len) == 0) return null;
    if (len <= 1) return null; // len includes the terminating NUL
    const n = std.unicode.utf16LeToUtf8(buf, name_w[0 .. len - 1]) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

const win32 = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    const TOKEN_QUERY: u32 = 0x0008;
    const TokenUser: c_int = 1; // TOKEN_INFORMATION_CLASS
    const SYNCHRONIZE: u32 = 0x0010_0000;

    const SID_AND_ATTRIBUTES = extern struct {
        Sid: *anyopaque,
        Attributes: u32,
    };
    const TOKEN_USER = extern struct {
        User: SID_AND_ATTRIBUTES,
    };

    extern "kernel32" fn CreateMutexW(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: windows.BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn OpenMutexW(
        dwDesiredAccess: u32,
        bInheritHandle: windows.BOOL,
        lpName: [*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "advapi32" fn OpenProcessToken(
        ProcessHandle: windows.HANDLE,
        DesiredAccess: u32,
        TokenHandle: *windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetTokenInformation(
        TokenHandle: windows.HANDLE,
        TokenInformationClass: c_int,
        TokenInformation: ?*anyopaque,
        TokenInformationLength: u32,
        ReturnLength: *u32,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(
        Sid: *anyopaque,
        StringSid: *?[*:0]u16,
    ) callconv(.winapi) windows.BOOL;
    extern "advapi32" fn GetUserNameW(
        lpBuffer: [*]u16,
        pcbBuffer: *u32,
    ) callconv(.winapi) windows.BOOL;

    // --- takeover protocol ---
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const PROCESS_TERMINATE: u32 = 0x0001;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: u32,
        bInheritHandle: windows.BOOL,
        dwProcessId: u32,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn TerminateProcess(
        hProcess: windows.HANDLE,
        uExitCode: c_uint,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn QueryFullProcessImageNameW(
        hProcess: windows.HANDLE,
        dwFlags: u32,
        lpExeName: [*]u16,
        lpdwSize: *u32,
    ) callconv(.winapi) windows.BOOL;
} else struct {};

// -----------------------------------------------------------------------------
// POSIX: flock on a per-user lock file
// -----------------------------------------------------------------------------

/// Compose the per-instance state filename `agent[-<key>]<ext>` into `buf`:
/// `agent.lock`/`agent.heartbeat` for the legacy singleton (empty key),
/// `agent-<key>.lock` etc. otherwise. The key is sanitized ('\'/'/'/control →
/// '_') so it can never smuggle a path separator into a filename. Pure;
/// unit-tested. `ext` includes the dot (e.g. ".lock").
pub fn composeStateFileName(buf: []u8, key: []const u8, ext: []const u8) error{NameTooLong}![]const u8 {
    const base = "agent";
    const key_len = if (key.len == 0) 0 else key.len + 1; // "-<key>"
    const total = base.len + key_len + ext.len;
    if (total > buf.len) return error.NameTooLong;
    @memcpy(buf[0..base.len], base);
    var i = base.len;
    if (key.len != 0) {
        buf[i] = '-';
        i += 1;
        for (key) |c| {
            buf[i] = if (c == '\\' or c == '/' or c < 0x20) '_' else c;
            i += 1;
        }
    }
    @memcpy(buf[i .. i + ext.len], ext);
    return buf[0..total];
}

/// Resolve the lock-file path (POSIX only):
///   1. `GHOSTTY_AGENT_LOCK` (explicit full-path override; tests use this),
///   2. `$XDG_CONFIG_HOME/ghoztty/agent[-<key>].lock`,
///   3. `$HOME/.config/ghoztty/agent[-<key>].lock`.
/// Same directory family as `enroll.relayEnvPath` so all agent state cohabits;
/// the instance key separates the local persistence agent from the relay agent
/// (empty key ⇒ the legacy `agent.lock`). Owned by the caller.
pub fn lockFilePath(alloc: Allocator, instance: Instance) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_AGENT_LOCK")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    var name_buf: [64]u8 = undefined;
    const name = try composeStateFileName(&name_buf, instance.key, ".lock");
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", name });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", name });
}

/// Open (creating as needed) `path` and take an exclusive, non-blocking
/// advisory flock on it. POSIX only. Split out from `acquire` so tests can
/// point two independent open-file-descriptions at one temp path.
pub fn acquirePath(path: []const u8) AcquireError!Guard {
    if (builtin.os.tag == .windows) unreachable;
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return error.GuardUnavailable;
    }
    const file = std.fs.cwd().createFile(path, .{
        .truncate = false, // never clobber; contents are irrelevant, the lock gates
        .read = true,
    }) catch return error.GuardUnavailable;
    errdefer file.close(); // any error return below must not leak the fd

    std.posix.flock(file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) catch |err| {
        return switch (err) {
            error.WouldBlock => error.AlreadyRunning,
            else => error.GuardUnavailable,
        };
    };
    return .{ .impl = .{ .fd = file.handle } };
}

// -----------------------------------------------------------------------------
// Takeover — "there should be only one" (see the module doc §Takeover)
// -----------------------------------------------------------------------------

/// How often the guard HOLDER touches the heartbeat file.
pub const heartbeat_interval_ms: u64 = 10_000;
/// A heartbeat older than this marks the holder unresponsive (4.5 missed
/// beats — generous enough for a paging stall, far below human patience).
pub const heartbeat_stale_after_ms: i64 = 45_000;
/// Post-kill guard re-acquisition: attempts × delay (the OS frees the
/// mutex/flock with the dying process; 1s total is ample).
const takeover_retry_attempts = 5;
const takeover_retry_delay_ms = 200;

/// Result of the best-effort "does this PID still name a ghoztty-agent?"
/// probe that gates a kill (PID-reuse friendly-fire protection).
pub const ImageCheck = enum {
    /// PID resolves to an image whose basename starts with `ghoztty-agent`.
    confirmed_agent,
    /// PID resolves to some OTHER image: never kill it.
    confirmed_other,
    /// Couldn't resolve (no API, no permission, process gone).
    unavailable,
};

/// What a challenger that lost the guard race should do about the holder.
pub const Verdict = enum {
    /// Holder is (presumed) alive and responsive: exit 183 as always.
    yield,
    /// Holder is stuck/anomalous and safely identified: kill it, then retry
    /// the guard.
    kill_and_take,
    /// Anomaly detected but killing is unsafe (unidentified holder / foreign
    /// PID): log loudly and exit 183 — when in doubt, never two daemons.
    die,
};

/// THE takeover decision matrix — pure, unit-tested. Caller contract: only
/// invoked while the guard is verifiably still held (the caller re-attempts
/// acquisition immediately before asking), which is what makes killing on an
/// `unavailable` image check acceptable: a stale heartbeat AND a genuinely
/// held guard is a real anomaly, not a leftover file.
///
///   heartbeat_age_ms == null  → no/unreadable heartbeat file: an old-binary
///     holder or a racing first run — nobody safe to kill. Yield (die under
///     `force`, which promised a replacement it can't deliver).
///   image == .confirmed_other → PID reuse: never friendly-fire, even forced.
///   force                     → skip the freshness check, kill the holder.
///   fresh (< stale_after_ms)  → responsive primary: yield.
///   stale                     → kill and take over.
pub fn takeoverVerdict(
    force: bool,
    heartbeat_age_ms: ?i64,
    image: ImageCheck,
    stale_after_ms: i64,
) Verdict {
    const age = heartbeat_age_ms orelse return if (force) .die else .yield;
    if (image == .confirmed_other) return .die;
    if (force) return .kill_and_take;
    if (age < stale_after_ms) return .yield;
    return .kill_and_take;
}

/// `acquire` + the takeover protocol: on AlreadyRunning, probe the holder's
/// heartbeat and either yield (`error.AlreadyRunning`), or kill a stuck /
/// force-replaced holder and take the guard. This is what the daemon modes
/// call; `acquire` remains the raw primitive.
pub fn acquireWithTakeover(alloc: Allocator, force: bool, instance: Instance) AcquireError!Guard {
    if (acquire(alloc, instance)) |g| return g else |err| switch (err) {
        error.AlreadyRunning => {},
        error.GuardUnavailable => return error.GuardUnavailable,
    }

    // Probe the holder: heartbeat (PID + age) and what that PID runs today. The
    // heartbeat is keyed to the SAME instance as the guard, so a local
    // challenger reads the local holder's beat (never the relay agent's).
    const hb = readHeartbeatDefault(alloc, instance);
    const image: ImageCheck = if (hb) |h| checkPidImage(h.pid) else .unavailable;

    // Re-probe the guard right before deciding: (a) the holder may have
    // exited since the first attempt — then we just take over, no kill —
    // and (b) it upholds takeoverVerdict's "guard genuinely still held"
    // contract for the unverifiable-image kill.
    if (acquire(alloc, instance)) |g| return g else |err| switch (err) {
        error.AlreadyRunning => {},
        error.GuardUnavailable => return error.GuardUnavailable,
    }

    switch (takeoverVerdict(force, if (hb) |h| h.age_ms else null, image, heartbeat_stale_after_ms)) {
        .yield => return error.AlreadyRunning,
        .die => {
            std.debug.print(
                "ghoztty-agent: single-instance anomaly: guard held but the holder can't be safely replaced (heartbeat {s}, pid image {s}); yielding — never two daemons\n",
                .{
                    if (hb != null) "present" else "missing",
                    @tagName(image),
                },
            );
            return error.AlreadyRunning;
        },
        .kill_and_take => {
            const holder = hb.?; // null heartbeat can never reach kill_and_take
            std.debug.print(
                "ghoztty-agent: single-instance: holder pid {d} is {s} (heartbeat {d}ms old); killing it and taking over\n",
                .{ holder.pid, if (force) "being force-replaced" else "unresponsive", holder.age_ms },
            );
            killPid(holder.pid) catch |err| {
                std.debug.print("ghoztty-agent: single-instance: kill of pid {d} failed ({s}); yielding\n", .{ holder.pid, @errorName(err) });
                return error.AlreadyRunning;
            };
            // The OS releases the mutex/flock as the holder dies — give it a
            // few beats, then insist on actually WINNING the guard.
            var attempt: usize = 0;
            while (attempt < takeover_retry_attempts) : (attempt += 1) {
                std.Thread.sleep(takeover_retry_delay_ms * std.time.ns_per_ms);
                if (acquire(alloc, instance)) |g| {
                    std.debug.print("ghoztty-agent: single-instance: takeover complete (replaced pid {d})\n", .{holder.pid});
                    return g;
                } else |err| switch (err) {
                    error.AlreadyRunning => continue,
                    error.GuardUnavailable => return error.GuardUnavailable,
                }
            }
            std.debug.print(
                "ghoztty-agent: single-instance: guard still held {d}ms after killing pid {d}; yielding — never two daemons\n",
                .{ takeover_retry_attempts * takeover_retry_delay_ms, holder.pid },
            );
            return error.AlreadyRunning;
        },
    }
}

// --- Heartbeat file ----------------------------------------------------------

/// Resolve the heartbeat path: `GHOSTTY_AGENT_HEARTBEAT` override (tests),
/// else `agent[-<key>].heartbeat` next to the rest of the per-user agent state
/// (`%LOCALAPPDATA%\ghoztty\` on Windows — same dir as relay.env — and
/// `$XDG_CONFIG_HOME|~/.config/ghoztty/` on POSIX — same dir as agent.lock).
/// Keyed to the instance so a local challenger and a relay challenger consult
/// DISTINCT heartbeats (empty key ⇒ the legacy `agent.heartbeat`). Owned by the
/// caller.
pub fn heartbeatPath(alloc: Allocator, instance: Instance) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_AGENT_HEARTBEAT")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    var name_buf: [64]u8 = undefined;
    const name = try composeStateFileName(&name_buf, instance.key, ".heartbeat");
    if (builtin.os.tag == .windows) {
        const local = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
        defer alloc.free(local);
        return std.fs.path.join(alloc, &.{ local, "ghoztty", name });
    }
    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", name });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", name });
}

/// One heartbeat tick: (re)write the file with our PID. The WRITE is the
/// liveness signal (it bumps mtime); the content identifies who to kill when
/// it goes stale. Public + path-parameterized so it's testable anywhere.
pub fn writeHeartbeat(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d}\n", .{currentPid()}) catch unreachable;
    try file.writeAll(line);
}

pub const HeartbeatInfo = struct { pid: i32, age_ms: i64 };

/// Read + parse a heartbeat file: the holder's PID and the file's mtime age.
/// Null on any problem (missing, unreadable, garbage PID) — callers treat
/// that as "no heartbeat" (old-binary holder rule). Public for tests.
pub fn readHeartbeat(path: []const u8) ?HeartbeatInfo {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const st = file.stat() catch return null;
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch return null;
    if (pid <= 0) return null;
    const age_ns = std.time.nanoTimestamp() - st.mtime;
    const age_ms_wide = @divTrunc(age_ns, std.time.ns_per_ms);
    const age_ms: i64 = std.math.cast(i64, @max(0, age_ms_wide)) orelse std.math.maxInt(i64);
    return .{ .pid = pid, .age_ms = age_ms };
}

fn readHeartbeatDefault(alloc: Allocator, instance: Instance) ?HeartbeatInfo {
    const path = heartbeatPath(alloc, instance) catch return null;
    defer alloc.free(path);
    return readHeartbeat(path);
}

/// The holder's heartbeat writer: a daemon-lifetime thread touching the file
/// every `heartbeat_interval_ms`. Start it right after winning the guard.
/// Failures only cost takeover-ability, never the daemon (same availability-
/// first policy as the guard itself).
pub const Heartbeat = struct {
    alloc: Allocator,
    path: []u8,
    interval_ms: u64,
    stop_ev: std.Thread.ResetEvent = .{},
    thread: ?std.Thread = null,

    /// Resolve the default path, write the first beat synchronously (so the
    /// file exists the moment the daemon is up), and spawn the ticker. Null
    /// (with a log) when any of that fails.
    pub fn start(alloc: Allocator, instance: Instance) ?*Heartbeat {
        const path = heartbeatPath(alloc, instance) catch |err| {
            std.debug.print("ghoztty-agent: heartbeat path unavailable ({s}); takeover-by-challenger disabled\n", .{@errorName(err)});
            return null;
        };
        return startWithPath(alloc, path, heartbeat_interval_ms) orelse {
            alloc.free(path);
            return null;
        };
    }

    /// Test seam: explicit path (takes ownership on success) and interval.
    pub fn startWithPath(alloc: Allocator, path: []u8, interval_ms: u64) ?*Heartbeat {
        const self = alloc.create(Heartbeat) catch return null;
        self.* = .{ .alloc = alloc, .path = path, .interval_ms = interval_ms };
        writeHeartbeat(path) catch |err| {
            std.debug.print("ghoztty-agent: heartbeat write failed ({s}); takeover-by-challenger disabled\n", .{@errorName(err)});
            alloc.destroy(self);
            return null;
        };
        self.thread = std.Thread.spawn(.{}, Heartbeat.run, .{self}) catch |err| blk: {
            std.debug.print("ghoztty-agent: heartbeat thread spawn failed ({s}); heartbeat will go stale\n", .{@errorName(err)});
            break :blk null; // first beat exists; keep the daemon anyway
        };
        return self;
    }

    fn run(self: *Heartbeat) void {
        while (true) {
            if (self.stop_ev.timedWait(self.interval_ms * std.time.ns_per_ms)) |_| {
                return; // stopped
            } else |_| {}
            writeHeartbeat(self.path) catch {}; // transient FS hiccup: next tick retries
        }
    }

    /// Stop the ticker, remove the file (a clean exit shouldn't leave a
    /// corpse for challengers to ponder), and free. Tests + main's error
    /// paths; production daemons never stop.
    pub fn stopAndFree(self: *Heartbeat) void {
        self.stop_ev.set();
        if (self.thread) |t| t.join();
        std.fs.cwd().deleteFile(self.path) catch {};
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }
};

// --- PID probes (best-effort, per platform) ----------------------------------

/// Basename-of-image test shared by all platforms' `checkPidImage`: does it
/// start with `ghoztty-agent` (matches the exe, the .exe, and the test
/// binary)? Pure; public for tests.
pub fn imageLooksLikeAgent(image_path: []const u8) bool {
    const cut = std.mem.lastIndexOfAny(u8, image_path, "/\\");
    const base = if (cut) |i| image_path[i + 1 ..] else image_path;
    return std.ascii.startsWithIgnoreCase(base, "ghoztty-agent");
}

/// Best-effort: what does `pid` run right now? See `ImageCheck`.
fn checkPidImage(pid: i32) ImageCheck {
    switch (builtin.os.tag) {
        .windows => {
            const h = win32.OpenProcess(
                win32.PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                @intCast(pid),
            ) orelse return .unavailable;
            defer std.os.windows.CloseHandle(h);
            var buf16: [1024]u16 = undefined;
            var size: u32 = buf16.len;
            if (win32.QueryFullProcessImageNameW(h, 0, &buf16, &size) == 0) return .unavailable;
            var buf8: [3072]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&buf8, buf16[0..size]) catch return .unavailable;
            return if (imageLooksLikeAgent(buf8[0..n])) .confirmed_agent else .confirmed_other;
        },
        .linux => {
            var pbuf: [64]u8 = undefined;
            const proc = std.fmt.bufPrint(&pbuf, "/proc/{d}/exe", .{pid}) catch return .unavailable;
            var tbuf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fs.cwd().readLink(proc, &tbuf) catch return .unavailable;
            return if (imageLooksLikeAgent(target)) .confirmed_agent else .confirmed_other;
        },
        .macos => {
            var buf: [1024]u8 = undefined;
            const n = darwin.proc_pidpath(pid, &buf, buf.len);
            if (n <= 0) return .unavailable;
            return if (imageLooksLikeAgent(buf[0..@intCast(n)])) .confirmed_agent else .confirmed_other;
        },
        else => return .unavailable,
    }
}

/// Terminate `pid` (TerminateProcess / SIGKILL). Only ever called on a PID
/// `takeoverVerdict` approved.
fn killPid(pid: i32) !void {
    if (builtin.os.tag == .windows) {
        const h = win32.OpenProcess(win32.PROCESS_TERMINATE, 0, @intCast(pid)) orelse
            return error.OpenProcessFailed;
        defer std.os.windows.CloseHandle(h);
        if (win32.TerminateProcess(h, 1) == 0) return error.TerminateFailed;
        return;
    }
    try std.posix.kill(@intCast(pid), std.posix.SIG.KILL);
}

fn currentPid() i32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(win32.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

const darwin = if (builtin.os.tag == .macos) struct {
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
} else struct {};

// -----------------------------------------------------------------------------
// Tests. The Windows MUTEX mechanics are compile-verified only (by the
// x86_64-windows-gnu agent build); the NAME composition is pure and tested
// here on every host. The flock mechanics are tested for real (POSIX).
// -----------------------------------------------------------------------------

test "takeover verdict: the full decision matrix" {
    const V = takeoverVerdict;
    const stale = heartbeat_stale_after_ms;
    const eq = std.testing.expectEqual;

    // No heartbeat file: old-binary holder / racing first run — treated as
    // responsive; force can't help (no PID on record → nobody safe to kill).
    try eq(Verdict.yield, V(false, null, .unavailable, stale));
    try eq(Verdict.die, V(true, null, .unavailable, stale));

    // Fresh heartbeat → responsive primary → yield (boundary: strict <).
    try eq(Verdict.yield, V(false, 0, .confirmed_agent, stale));
    try eq(Verdict.yield, V(false, stale - 1, .unavailable, stale));

    // Stale heartbeat → stuck holder → kill, when the PID is (confirmed_agent)
    // or may be (unavailable — guard-still-held is the caller's precondition)
    // an agent.
    try eq(Verdict.kill_and_take, V(false, stale, .confirmed_agent, stale));
    try eq(Verdict.kill_and_take, V(false, std.math.maxInt(i64), .unavailable, stale));

    // PID reuse friendly-fire guard: a pid confirmed to be some OTHER program
    // is never killed — not even under --force-replace.
    try eq(Verdict.die, V(false, std.math.maxInt(i64), .confirmed_other, stale));
    try eq(Verdict.die, V(true, 50, .confirmed_other, stale));

    // --force-replace skips the freshness check (kills a HEALTHY holder).
    try eq(Verdict.kill_and_take, V(true, 0, .confirmed_agent, stale));
    try eq(Verdict.kill_and_take, V(true, 0, .unavailable, stale));
}

test "image check: basename must start with ghoztty-agent" {
    try std.testing.expect(imageLooksLikeAgent("/usr/local/bin/ghoztty-agent"));
    try std.testing.expect(imageLooksLikeAgent("C:\\Program Files\\Ghoztty\\ghoztty-agent.exe"));
    try std.testing.expect(imageLooksLikeAgent("ghoztty-agent-test")); // the zig test binary
    try std.testing.expect(imageLooksLikeAgent("/opt/GHOZTTY-AGENT.exe")); // case-insensitive
    try std.testing.expect(!imageLooksLikeAgent("/usr/bin/python3"));
    try std.testing.expect(!imageLooksLikeAgent("/home/x/ghoztty-agent/README")); // dir name doesn't count
}

test "heartbeat: write/read roundtrip reports our pid, fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "agent.heartbeat" });
    defer std.testing.allocator.free(path);

    try writeHeartbeat(path);
    const hb = readHeartbeat(path) orelse return error.HeartbeatUnreadable;
    try std.testing.expectEqual(currentPid(), hb.pid);
    try std.testing.expect(hb.age_ms >= 0);
    try std.testing.expect(hb.age_ms < heartbeat_stale_after_ms); // just written = fresh
}

test "heartbeat: missing or garbage file reads as no-heartbeat" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "agent.heartbeat" });
    defer std.testing.allocator.free(path);

    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path)); // missing

    try tmp.dir.writeFile(.{ .sub_path = "agent.heartbeat", .data = "not-a-pid\n" });
    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path));

    try tmp.dir.writeFile(.{ .sub_path = "agent.heartbeat", .data = "-5\n" });
    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path));
}

test "heartbeat writer: first beat is synchronous, ticker recreates a deleted file, stop removes it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "agent.heartbeat" });
    // Ownership of `path` moves into the Heartbeat on success.

    const hb = Heartbeat.startWithPath(alloc, path, 10) orelse {
        alloc.free(path);
        return error.HeartbeatStartFailed;
    };
    // First beat happened before startWithPath returned.
    try std.testing.expect(readHeartbeat(hb.path) != null);

    // Prove the ticker ticks: delete the file and watch it come back.
    try tmp.dir.deleteFile("agent.heartbeat");
    var waited_ms: u64 = 0;
    while (readHeartbeat(hb.path) == null) {
        if (waited_ms > 5_000) return error.TickerNeverRewrote;
        std.Thread.sleep(10 * std.time.ns_per_ms);
        waited_ms += 10;
    }

    // Clean stop removes the corpse.
    const path_copy = try alloc.dupe(u8, hb.path);
    defer alloc.free(path_copy);
    hb.stopAndFree();
    try std.testing.expectEqual(@as(?HeartbeatInfo, null), readHeartbeat(path_copy));
}

test "global mutex name: empty key (relay) composes the legacy name verbatim" {
    var buf: [256]u8 = undefined;
    const name = try composeGlobalMutexName(&buf, Instance.relay.key, "S-1-5-21-3623811015-3361044348-30300820-1013");
    try std.testing.expectEqualStrings(
        "Global\\GhozttyAgentDaemon-S-1-5-21-3623811015-3361044348-30300820-1013",
        name,
    );
}

test "global mutex name: instance key (local) inserts a distinct segment" {
    // The whole point of T89d1: local and relay never collide. A non-empty key
    // sits between the prefix and the user id with a single hyphen separator.
    var buf: [256]u8 = undefined;
    const relay = try composeGlobalMutexName(&buf, Instance.relay.key, "S-1-5-21-1");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-S-1-5-21-1", relay);

    var buf2: [256]u8 = undefined;
    const local = try composeGlobalMutexName(&buf2, Instance.local.key, "S-1-5-21-1");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-local-S-1-5-21-1", local);

    var buf3: [256]u8 = undefined;
    const dbg = try composeGlobalMutexName(&buf3, Instance.local_debug.key, "S-1-5-21-1");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-local-debug-S-1-5-21-1", dbg);

    // Distinct names ⇒ distinct kernel objects ⇒ coexistence.
    try std.testing.expect(!std.mem.eql(u8, relay, local));
    try std.testing.expect(!std.mem.eql(u8, local, dbg));
}

test "global mutex name: username fallback — backslash and control chars sanitized (key + id)" {
    // A mutex name may not contain '\' past the namespace prefix; neither a
    // DOMAIN\user-shaped id NOR a stray key may smuggle one in (it would
    // silently create the object under a nested name).
    var buf: [256]u8 = undefined;
    const name = try composeGlobalMutexName(&buf, "ke\\y\x02", "CORP\\dzearing\x01");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-ke_y_-CORP_dzearing_", name);
    // Exactly one backslash total: the Global\ namespace separator.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, name, "\\"),
    );
}

test "global mutex name: oversized id errors instead of truncating" {
    var buf: [64]u8 = undefined;
    const long_id = "S-1-5-21-" ++ "9" ** 100;
    try std.testing.expectError(error.NameTooLong, composeGlobalMutexName(&buf, "", long_id));
    try std.testing.expectError(error.NameTooLong, composeGlobalMutexName(&buf, "local", long_id));
}

test "local mutex name: empty key is the legacy literal; a key appends a segment" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Local\\GhozttyAgentDaemon",
        try composeLocalMutexName(&buf, Instance.relay.key),
    );
    var buf2: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Local\\GhozttyAgentDaemon-local",
        try composeLocalMutexName(&buf2, Instance.local.key),
    );
    var buf3: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Local\\GhozttyAgentDaemon-local-debug",
        try composeLocalMutexName(&buf3, Instance.local_debug.key),
    );
    // Must match the legacy compile-time literal byte-for-byte (no regression
    // for sandboxed relay agents that fall back to Local\).
    var legacy16: [64]u16 = undefined;
    const legacy_name = try composeLocalMutexName(&buf, "");
    const n = try std.unicode.utf8ToUtf16Le(&legacy16, legacy_name);
    const literal = std.unicode.utf8ToUtf16LeStringLiteral("Local\\GhozttyAgentDaemon");
    try std.testing.expectEqualSlices(u16, literal, legacy16[0..n]);
}

test "instance suffix: absent reproduces the build's own key; present forks it (T167)" {
    var buf: [64]u8 = undefined;
    // Production: no suffix anywhere, so every name is byte-identical to before.
    try std.testing.expectEqualStrings(
        Instance.local_debug.key,
        (try instanceWithSuffix(&buf, .local_debug, null)).key,
    );
    var buf2: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        Instance.relay.key,
        (try instanceWithSuffix(&buf2, .relay, null)).key,
    );

    // A sandbox names its own lineage — mutex, lock file and heartbeat all
    // follow the key, so all three fork together.
    var buf3: [64]u8 = undefined;
    const sbx = try instanceWithSuffix(&buf3, .local_debug, "sbx1");
    try std.testing.expectEqualStrings("local-debug-sbx1", sbx.key);

    var m1: [256]u8 = undefined;
    var m2: [256]u8 = undefined;
    const box = try composeGlobalMutexName(&m1, Instance.local_debug.key, "S-1-5-21-1");
    const sandbox = try composeGlobalMutexName(&m2, sbx.key, "S-1-5-21-1");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-local-debug-S-1-5-21-1", box);
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-local-debug-sbx1-S-1-5-21-1", sandbox);
    try std.testing.expect(!std.mem.eql(u8, box, sandbox)); // ⇒ they coexist

    var f1: [64]u8 = undefined;
    var f2: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "agent-local-debug.heartbeat",
        try composeStateFileName(&f1, Instance.local_debug.key, ".heartbeat"),
    );
    try std.testing.expectEqualStrings(
        "agent-local-debug-sbx1.heartbeat",
        try composeStateFileName(&f2, sbx.key, ".heartbeat"),
    );
}

test "instance suffix: two sandboxes never share a guard" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const one = try instanceWithSuffix(&a, .local_debug, "sbx1");
    const two = try instanceWithSuffix(&b, .local_debug, "sbx2");
    var m1: [256]u8 = undefined;
    var m2: [256]u8 = undefined;
    try std.testing.expect(!std.mem.eql(
        u8,
        try composeGlobalMutexName(&m1, one.key, "S-1-5-21-1"),
        try composeGlobalMutexName(&m2, two.key, "S-1-5-21-1"),
    ));
    var l1: [128]u8 = undefined;
    var l2: [128]u8 = undefined;
    try std.testing.expect(!std.mem.eql(
        u8,
        try composeLocalMutexName(&l1, one.key),
        try composeLocalMutexName(&l2, two.key),
    ));
}

test "state filename: legacy vs keyed, separator sanitized" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("agent.lock", try composeStateFileName(&buf, "", ".lock"));
    try std.testing.expectEqualStrings("agent.heartbeat", try composeStateFileName(&buf, "", ".heartbeat"));
    try std.testing.expectEqualStrings("agent-local.lock", try composeStateFileName(&buf, "local", ".lock"));
    try std.testing.expectEqualStrings(
        "agent-local-debug.heartbeat",
        try composeStateFileName(&buf, "local-debug", ".heartbeat"),
    );
    // A key must never inject a path separator into a filename.
    try std.testing.expectEqualStrings("agent-a_b.lock", try composeStateFileName(&buf, "a/b", ".lock"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, composeStateFileName(&tiny, "local", ".lock"));
}

test "flock guard: second acquire fails, release frees it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const lock_path = try std.fs.path.join(std.testing.allocator, &.{ path, "agent.lock" });
    defer std.testing.allocator.free(lock_path);

    // First acquire wins.
    var g1 = try acquirePath(lock_path);

    // Second acquire — a fresh open() of the same path is a fresh open-file-
    // description, so flock semantics here are IDENTICAL to a second process
    // contending for the lock (flock is per-OFD, not per-process).
    try std.testing.expectError(error.AlreadyRunning, acquirePath(lock_path));

    // Release the first; now the lock is free and a new acquire succeeds.
    g1.release();
    var g2 = try acquirePath(lock_path);
    g2.release();
}

/// Spawn a genuinely separate process (python3, present on macOS and every
/// Linux CI base) that tries to flock `lock_path` non-blocking. Returns its
/// exit code: 0 = child got the lock, 183 = child was refused. Returns
/// error.SkipZigTest when python3 is unavailable.
fn childTryLock(alloc: Allocator, lock_path: []const u8) !u32 {
    const script = try std.fmt.allocPrint(
        alloc,
        \\import fcntl,sys
        \\f=open('{s}','a')
        \\try:
        \\    fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        \\except OSError:
        \\    sys.exit(183)
        \\sys.exit(0)
    ,
        .{lock_path},
    );
    defer alloc.free(script);

    var child = std.process.Child.init(&.{ "python3", "-c", script }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.SkipZigTest; // no python3 → skip
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        else => error.ChildDidNotExit,
    };
}

test "flock guard: two real processes — holder blocks the child, release frees it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const lock_path = try std.fs.path.join(alloc, &.{ dir_path, "agent.lock" });
    defer alloc.free(lock_path);

    // While THIS process holds the lock, a separate child process must be
    // refused (exits 183 — the same code the real daemon uses).
    var g = try acquirePath(lock_path);
    try std.testing.expectEqual(@as(u32, 183), try childTryLock(alloc, lock_path));

    // After release, a fresh child must win it (exit 0) — proving the lock,
    // not the file's existence, is what gates.
    g.release();
    try std.testing.expectEqual(@as(u32, 0), try childTryLock(alloc, lock_path));
}
