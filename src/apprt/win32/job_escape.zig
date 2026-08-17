//! The startup self-escape from a hostile job object (T675).
//!
//! A child joins its parent's Windows job by default, and an app launched from
//! inside a Ghoztty pane is therefore a member of the AGENT's process-global
//! PTY job — created kill-on-close in `src/remote/agent/pty_child.zig`, its
//! handle held by the agent for the agent's entire life. That membership is a
//! standing death sentence with a known executioner: the destructive agent
//! refresh terminates the agent, the agent's death closes the job's last
//! handle, and the job teardown kills every member — including the app that
//! promised the user "your windows will be rebuilt" one dialog earlier. That
//! is the whole T229/T421/T426 family of unexplained mid-refresh deaths
//! (mechanism measured in T268).
//!
//! You cannot leave a job you are already in; the only way out is to not be
//! the process that is in it. So at startup, before any window or IPC endpoint
//! exists, the app asks where it is (`job_object.selfJob`): inside a
//! kill-on-close job, it respawns its own command line through the escape
//! tiers (`job_spawn.spawnEscapedOnly` — breakaway, then the shell-parent
//! hop) and exits, and the escaped twin carries on as THE app. This covers
//! every launch path at once — `ghoztty` typed in a pane, the upgrade script's
//! hidden relaunch, a script's `Start-Process` — instead of patching spawn
//! sites one at a time.
//!
//! Deliberate properties:
//!
//! - **One attempt, ever.** The respawn carries `GHOZTTY_JOB_ESCAPED` in its
//!   environment; the twin consumes the variable and never tries again, so a
//!   world where the escape does not work degrades to today's behavior (run
//!   jailed, loudly) rather than to a fork bomb.
//! - **Escaped or nothing.** The respawn uses `spawnEscapedOnly`: if neither
//!   tier gets a child OUT of the job, no child is created and THIS process
//!   keeps running — jailed, with a warning naming the consequence. A twin
//!   jailed right beside us would be a pure loss.
//! - **The command line and environment survive byte-exact.** The twin is
//!   `GetCommandLineW()` verbatim (flags, `-e`, `--config` intact) with our
//!   environment (the shell-parent tier passes it explicitly; T506's
//!   launched-from-CLI marker and the pane's variables ride along).
//! - **CLI verbs never do this.** The check is gated (in `main_ghostty`) on
//!   there being no `+action`: a verb lives milliseconds, its console wiring
//!   and exit code belong to its caller, and a job teardown is not a hazard it
//!   lives long enough to meet.
//!
//! Known limit: with NESTED jobs, the NULL-handle flags query answers for the
//! FIRST job this process joined, and there is no public API to walk the rest
//! of the chain. A killer job nested inside a benign outer one is therefore
//! not detected — no worse than before this module existed, and not the field
//! shape: a pane shell's one and only job is the agent's PTY job, and the
//! dying app's own diagnostic measured exactly its flags (0x2000, T426/T268).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const job_object = @import("job_object.zig");
const job_spawn = @import("job_spawn.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_job_escape);

/// Set on the respawned twin so it knows it IS the escape attempt. Consumed
/// (cleared) by the twin before anything else inherits it — a pane shell
/// carrying it would silence the escape for any app launched from that pane.
pub const env_var = "GHOZTTY_JOB_ESCAPED";

/// The harness seam: an acceptance script that launches this app and tracks
/// its PID cannot survive the pid handoff a startup escape performs — and a
/// script run from a Ghoztty pane hands every app it launches real pane
/// lineage, so the escape WOULD fire there. `test\win32\lib\BuildMode.ps1`
/// (which every acceptance script already dot-sources) sets this; nothing in
/// a real user launch path ever does. Deliberately NOT consumed: a harness's
/// nested launches must inherit the suppression.
pub const suppress_env_var = "GHOZTTY_NO_STARTUP_ESCAPE";

/// The decision, isolated from the syscalls that feed it. Escape when we are
/// KNOWN to be inside a job AND that job is a known hazard — either its flags
/// say kill-on-close outright, or this process has pane lineage
/// (`$GHOZTTY_PANE_ID` in its environment), which on this architecture means
/// the agent's kill-on-close PTY job is in our job chain whatever the flags
/// query happens to answer. The second signal exists because with NESTED jobs
/// the NULL-handle flags query answers only the FIRST job joined: a compat
/// job with no limits can sit in front of the killer and read as 0x0 (the
/// module doc's known limit — measured while building this task's acceptance
/// harness).
///
/// Unknowns stay put: a probe that could not answer is not evidence of a
/// hazard, and a re-exec on a guess would tax every clean launch. And the
/// escape attempt's own twin never escapes again, whatever it sees.
pub fn shouldEscape(
    in_job: ?bool,
    flags: ?u32,
    pane_lineage: bool,
    already_attempted: bool,
) bool {
    if (already_attempted) return false;
    if (!(in_job orelse false)) return false;
    if (pane_lineage) return true;
    const f = flags orelse return false;
    return f & job_object.limit_kill_on_job_close != 0;
}

/// Probe, and respawn outside the job if the probe says we must. True means a
/// twin is running escaped and THIS process must exit without touching
/// anything further; false means keep going — clean, or jailed-and-loud.
pub fn escapeAtStartup(alloc: Allocator) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return escapeImpl(alloc) catch |err| {
        log.warn("startup escape: not attempted err={}; running where we are", .{err});
        return false;
    };
}

fn escapeImpl(alloc: Allocator) !bool {
    const windows = std.os.windows;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name_w = std.unicode.utf8ToUtf16LeStringLiteral(env_var);

    // Consume the marker FIRST, whatever else happens: children of this
    // process must never inherit it.
    const attempted = blk: {
        const raw = std.process.getEnvVarOwned(arena, env_var) catch break :blk false;
        break :blk raw.len > 0;
    };
    if (attempted) _ = w32.SetEnvironmentVariableW(name_w, null);

    // The harness seam, checked before any probing: a suppressed launch is a
    // launch whose PID somebody is tracking.
    if (std.process.getEnvVarOwned(arena, suppress_env_var) catch null) |raw| {
        if (raw.len > 0) {
            log.debug("startup escape: suppressed by {s}", .{suppress_env_var});
            return false;
        }
    }

    const facts = job_object.selfJob();
    const pane_lineage = blk: {
        const raw = std.process.getEnvVarOwned(arena, "GHOZTTY_PANE_ID") catch break :blk false;
        break :blk raw.len > 0;
    };
    {
        // Permanent breadcrumb: the next "app died mid-refresh" incident must
        // be able to say what the startup probe SAW, not only what it did.
        var flags_buf: [64]u8 = undefined;
        log.debug("startup job probe: in_job={?} flags={s} pane_lineage={} attempted={}", .{
            facts.in_job,
            if (facts.flags) |f| job_object.describeFlags(&flags_buf, f) else "?",
            pane_lineage,
            attempted,
        });
    }
    if (!shouldEscape(facts.in_job, facts.flags, pane_lineage, attempted)) {
        if (attempted) {
            // The twin reports where it landed, so the log tells a successful
            // escape apart from one that went nowhere.
            var flags_buf: [64]u8 = undefined;
            const still_jailed = (facts.in_job orelse false) and
                (facts.flags orelse 0) & job_object.limit_kill_on_job_close != 0;
            if (still_jailed) {
                log.warn(
                    "startup escape: STILL inside a kill-on-close job after the respawn (flags {s}); running jailed",
                    .{job_object.describeFlags(&flags_buf, facts.flags orelse 0)},
                );
            } else {
                log.info("startup escape: landed outside any kill-on-close job", .{});
            }
        }
        return false;
    }

    var flags_buf: [64]u8 = undefined;
    log.warn(
        "startup escape: this process is inside a kill-on-close job it does not own (flags {s}); respawning outside it",
        .{job_object.describeFlags(&flags_buf, facts.flags orelse 0)},
    );

    // Set on US for the spawn so the twin inherits it (both tiers pass our
    // environment on). Cleared again if no twin materializes.
    if (w32.SetEnvironmentVariableW(name_w, std.unicode.utf8ToUtf16LeStringLiteral("1")) == 0)
        return error.SetEnvFailed;
    errdefer _ = w32.SetEnvironmentVariableW(name_w, null);

    // Our raw command line, verbatim. Mutable copy: CreateProcessW may rewrite
    // lpCommandLine.
    const raw_cmd = GetCommandLineW();
    const raw_len = std.mem.len(raw_cmd);
    const cmd = try arena.allocSentinel(u16, raw_len, 0);
    @memcpy(cmd, raw_cmd[0..raw_len]);

    // No CREATE_NEW_PROCESS_GROUP: it is inherited by every descendant and
    // disables Ctrl-C for all of them (T84).
    const spawned = job_spawn.spawnEscapedOnly(
        arena,
        cmd.ptr,
        job_spawn.DETACHED_PROCESS,
        "startup escape",
    ) catch {
        _ = w32.SetEnvironmentVariableW(name_w, null);
        log.warn(
            "startup escape: no escape tier available; running INSIDE the kill-on-close job " ++
                "(a destructive agent refresh will kill this app with the agent)",
            .{},
        );
        return false;
    };
    const twin_pid = w32.GetProcessId(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hProcess);
    windows.CloseHandle(spawned.pi.hThread);
    log.info(
        "startup escape: respawned as pid {d} ({s}); this jailed process exits",
        .{ twin_pid, spawned.tier.name() },
    );
    return true;
}

// Not in zig std's kernel32 as of 0.15.2.
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "shouldEscape fires on a known kill-on-close job" {
    // Flags answered honestly (the field's T426 diagnostic did): 0x2000.
    try testing.expect(shouldEscape(true, job_object.limit_kill_on_job_close, false, false));
    // Kill-on-close plus breakaway bits is still a job that kills its members.
    try testing.expect(shouldEscape(true, 0x3C00, false, false));
    // A job that does NOT kill on close is not a hazard worth a re-exec.
    try testing.expect(!shouldEscape(true, 0x0, false, false));
    try testing.expect(!shouldEscape(true, job_object.limit_breakaway_ok, false, false));
    // Not in a job at all.
    try testing.expect(!shouldEscape(false, job_object.limit_kill_on_job_close, false, false));
}

test "shouldEscape trusts pane lineage over a flagless first job" {
    // The nested-job blind spot: launched from a pane, in a job, but the
    // NULL-handle query answered a limitless compat job in front of the
    // killer. Pane lineage says the agent's kill-on-close job is in the
    // chain regardless.
    try testing.expect(shouldEscape(true, 0x0, true, false));
    try testing.expect(shouldEscape(true, null, true, false));
    // ... but lineage alone, with no job membership at all, stays put: there
    // is nothing to escape from.
    try testing.expect(!shouldEscape(false, null, true, false));
    try testing.expect(!shouldEscape(null, null, true, false));
}

test "shouldEscape treats unknowns as stay-put, never as escape" {
    // A probe that could not answer must not tax every clean launch with a
    // speculative re-exec.
    try testing.expect(!shouldEscape(null, job_object.limit_kill_on_job_close, false, false));
    try testing.expect(!shouldEscape(true, null, false, false));
    try testing.expect(!shouldEscape(null, null, false, false));
}

test "shouldEscape never fires twice" {
    // The marker is the fork-bomb guard: even a fully-jailed twin stays put.
    try testing.expect(!shouldEscape(true, job_object.limit_kill_on_job_close, false, true));
    try testing.expect(!shouldEscape(true, 0x0, true, true));
}
