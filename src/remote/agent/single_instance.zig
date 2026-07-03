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
//! ## Mechanism (per platform, per user session)
//!   - **Windows**: a named mutex `Local\GhozttyAgentDaemon` via `CreateMutexW`.
//!     The `Local\` prefix scopes it to the current LOGON SESSION, so two
//!     different logged-in users each get their own agent (they don't block
//!     each other) while two supervisors in the SAME session collide. The
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

/// Acquire the per-user-session daemon guard. See the module doc for the
/// platform mechanisms. `alloc` is only used transiently (path resolution on
/// POSIX); the returned `Guard` owns no heap memory.
pub fn acquire(alloc: Allocator) AcquireError!Guard {
    if (builtin.os.tag == .windows) return acquireWindows();
    const path = lockFilePath(alloc) catch return error.GuardUnavailable;
    defer alloc.free(path);
    return acquirePath(path);
}

// -----------------------------------------------------------------------------
// Windows: named mutex
// -----------------------------------------------------------------------------

/// `Local\` = current logon session's namespace: same-session supervisors
/// collide, different logged-in users don't.
const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\GhozttyAgentDaemon");

fn acquireWindows() AcquireError!Guard {
    if (builtin.os.tag != .windows) unreachable;
    // bInitialOwner = FALSE: we never wait on / own the mutex — its mere
    // EXISTENCE (first creator wins) is the whole signal, which also means
    // abandoned-mutex semantics can never bite us.
    const handle = win32.CreateMutexW(null, 0, mutex_name) orelse {
        return error.GuardUnavailable;
    };
    if (std.os.windows.GetLastError() == .ALREADY_EXISTS) {
        // Another instance created it first. Drop our handle (the winner's
        // handle keeps the mutex alive) and report the conflict.
        std.os.windows.CloseHandle(handle);
        return error.AlreadyRunning;
    }
    return .{ .impl = .{ .handle = handle } };
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CreateMutexW(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: std.os.windows.BOOL,
        lpName: ?[*:0]const u16,
    ) callconv(.winapi) ?std.os.windows.HANDLE;
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
// Tests (POSIX-only mechanics; the Windows branch is compile-verified by the
// x86_64-windows-gnu agent build)
// -----------------------------------------------------------------------------

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
