//! Single-instance guard for the `ghoztty-agent` DAEMON modes (`--listen`,
//! `--relay`).
//!
//! ## Why
//! Multiple supervisors can (and did, live) race to keep the agent alive on the
//! same box — the installer's scheduled-task launcher AND an SMB deploy-watcher
//! script both respawn-on-exit, and each happily launched its own agent (two
//! tray icons, two daemons fighting over the listen port / relay control
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

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Exit code used when another daemon instance already holds the lock.
/// 183 == Windows ERROR_ALREADY_EXISTS, reused verbatim on POSIX so the code
/// reads the same in any supervisor's log.
pub const already_running_exit_code: u8 = 183;

pub const AcquireError = error{
    /// Another daemon instance holds the guard in this user session.
    AlreadyRunning,
    /// The guard infrastructure itself failed (couldn't create the mutex /
    /// lock file). Callers should log and CONTINUE serving — daemon
    /// availability beats guard integrity (mirrors the tray-failure policy).
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
pub fn acquire(alloc: Allocator) AcquireError!Guard {
    if (builtin.os.tag == .windows) return acquireWindows();
    const path = lockFilePath(alloc) catch return error.GuardUnavailable;
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

/// Legacy pre-SID name, kept verbatim as the last-resort fallback (`Local\` =
/// per-logon-session namespace — see the module doc for why that's too weak
/// as the primary): sandboxed contexts without Global\ access still get
/// today's per-session guard rather than none at all.
const local_mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\GhozttyAgentDaemon");

/// Compose `Global\GhozttyAgentDaemon-<user_id>` into `buf`. The id is
/// sanitized: backslashes (illegal in a mutex name anywhere past the
/// namespace prefix) and control characters become `_`. Pure — testable on
/// any host; the Windows path converts the result to UTF-16 for CreateMutexW.
pub fn composeGlobalMutexName(buf: []u8, user_id: []const u8) error{NameTooLong}![]const u8 {
    const total = global_mutex_name_prefix.len + user_id.len;
    if (total > buf.len) return error.NameTooLong;
    @memcpy(buf[0..global_mutex_name_prefix.len], global_mutex_name_prefix);
    for (user_id, global_mutex_name_prefix.len..) |c, i| {
        buf[i] = if (c == '\\' or c < 0x20) '_' else c;
    }
    return buf[0..total];
}

fn acquireWindows() AcquireError!Guard {
    if (builtin.os.tag != .windows) unreachable;

    // Preferred: Global\ + per-user id (SID, else username). Any failure on
    // this path degrades to the legacy Local\ guard — never below it.
    var id_buf: [768]u8 = undefined; // UNLEN=256 UTF-16 units ≤ 768 UTF-8 bytes
    if (windowsUserId(&id_buf)) |id| global: {
        var name8: [800]u8 = undefined;
        const name = composeGlobalMutexName(&name8, id) catch break :global;
        var name16: [801]u16 = undefined;
        const n16 = std.unicode.utf8ToUtf16Le(name16[0..800], name) catch break :global;
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

    // Fallback: the legacy per-logon-session guard (today's behavior).
    return switch (tryCreateMutex(local_mutex_name)) {
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
} else struct {};

// -----------------------------------------------------------------------------
// POSIX: flock on a per-user lock file
// -----------------------------------------------------------------------------

/// Resolve the lock-file path (POSIX only):
///   1. `GHOSTTY_AGENT_LOCK` (explicit full-path override; tests use this),
///   2. `$XDG_CONFIG_HOME/ghoztty/agent.lock`,
///   3. `$HOME/.config/ghoztty/agent.lock`.
/// Same directory family as `enroll.relayEnvPath` so all agent state cohabits.
/// Owned by the caller.
pub fn lockFilePath(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "GHOSTTY_AGENT_LOCK")) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    } else |_| {}

    if (std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME")) |xdg| {
        defer alloc.free(xdg);
        if (xdg.len > 0) return std.fs.path.join(alloc, &.{ xdg, "ghoztty", "agent.lock" });
    } else |_| {}
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".config", "ghoztty", "agent.lock" });
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
// Tests. The Windows MUTEX mechanics are compile-verified only (by the
// x86_64-windows-gnu agent build); the NAME composition is pure and tested
// here on every host. The flock mechanics are tested for real (POSIX).
// -----------------------------------------------------------------------------

test "global mutex name: SID suffix composes verbatim" {
    var buf: [256]u8 = undefined;
    const name = try composeGlobalMutexName(&buf, "S-1-5-21-3623811015-3361044348-30300820-1013");
    try std.testing.expectEqualStrings(
        "Global\\GhozttyAgentDaemon-S-1-5-21-3623811015-3361044348-30300820-1013",
        name,
    );
}

test "global mutex name: username fallback — backslash and control chars sanitized" {
    // A mutex name may not contain '\' past the namespace prefix; a
    // DOMAIN\user-shaped id must not smuggle one in (it would silently
    // create the object under a nested name).
    var buf: [256]u8 = undefined;
    const name = try composeGlobalMutexName(&buf, "CORP\\dzearing\x01");
    try std.testing.expectEqualStrings("Global\\GhozttyAgentDaemon-CORP_dzearing_", name);
    // Exactly one backslash total: the Global\ namespace separator.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, name, "\\"),
    );
}

test "global mutex name: oversized id errors instead of truncating" {
    var buf: [64]u8 = undefined;
    const long_id = "S-1-5-21-" ++ "9" ** 100;
    try std.testing.expectError(error.NameTooLong, composeGlobalMutexName(&buf, long_id));
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
