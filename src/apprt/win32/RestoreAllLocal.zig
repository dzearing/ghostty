//! T618: the LOCAL "Restore All" (T335) with its agent RPCs off the GUI thread.
//!
//! T339 did this for the cross-machine arm and deliberately left this one alone:
//! every RPC here is a bounded named-pipe round trip to a daemon on this box,
//! which is milliseconds in the normal case, and a change is only worth making
//! where the network cannot be trusted. That reasoning holds for the MEDIAN and
//! not for the TAIL. The pull (`GET_LAYOUTS`) and the liveness probe
//! (`LIST_SESSIONS`) each carry a `restore_probe_timeout_ns` budget, so an agent
//! that is wedged, paused, swapping or mid-upgrade costs ~4 s of a STOPPED
//! message loop — no cursor, no paint, no way to cancel — and a wedged agent is
//! exactly when a user reaches for Restore All.
//!
//! So the work is split down the same line T339 drew:
//!
//!   worker thread   GET_LAYOUTS → decode → LIST_SESSIONS (the liveness probe)
//!   GUI thread      decide + `restoreWindow` per window (it creates windows)
//!
//! This arm is strictly simpler than the relay's: there are no per-window dials,
//! because a local rebuild BORROWS `LocalAgent`'s one warm connection instead of
//! owning a transport per window. That borrow is what the two threads have to be
//! careful about, and the rule is in two halves:
//!
//!   * The worker may USE it. `LocalAgent.retire` never frees a replaced
//!     connection — surfaces hold the raw pointer and nothing refcounts it
//!     (T145) — so the pointer cannot dangle, and a retired one merely fails
//!     every send cleanly. `SessionRoster.fetch` borrows it from a worker on
//!     exactly this basis.
//!   * The rebuild may NOT assume it is still current. The agent can crash and
//!     be re-dialed while the worker is blocked, and building windows on the
//!     retired connection would hand the user panes that are dead on arrival. So
//!     `App.adoptRestoreAllLocal` RE-RESOLVES the shared connection on the GUI
//!     thread and attaches over that one.
//!
//! Everything else is the relay module's rules verbatim: one `Job` allocation
//! travels both ways, the reply is posted to the APP's message window rather
//! than the chooser's (a `DestroyWindow` discards a window's queued messages,
//! and a discarded reply here would leak the decode and the roster), and the
//! chooser is matched on the way back by ID and never by pointer.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const layout_blobs = @import("layout_blobs.zig");
const remote_connection = @import("../../remote/connection.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message window when a local restore worker is done.
/// wparam = `*Job`, owned by the handler.
pub const WM_APP_RESTORE_ALL_LOCAL: u32 = w32.WM_APP + 35;

/// The whole job, allocated on the GUI thread and freed there: the worker only
/// ever fills fields in. One allocation for both directions, so there is exactly
/// one free path for everything a restore holds.
pub const Job = struct {
    alloc: Allocator,
    /// The app's message window — the reply's destination.
    hwnd: w32.HWND,
    /// Which chooser asked, matched on the way back by ID and never by pointer.
    chooser_id: u64,
    /// The shared local-agent connection as it stood when the restore started.
    /// BORROWED (see the module header): the worker pulls over it, and the GUI
    /// thread re-resolves rather than rebuilding on it.
    pull: *remote_connection.Connection,
    /// A deliberate stall in front of the pull, in nanoseconds. Zero in every
    /// real run; see `stallNs`.
    stall_ns: u64 = 0,

    // --- filled in by the worker ---------------------------------------
    /// Non-null ⇒ the pull never completed, so there is nothing to rebuild; the
    /// chooser turns it into a sentence.
    err: ?App.RestoreAllError = null,
    decoded: ?layout_blobs.Decoded = null,
    probe: App.AttachProbe = .{},
    /// How many layout blobs the agent holds, for the "nothing to rebuild"
    /// line — an agent with none is a different fact from one whose windows are
    /// all already open here.
    held: usize = 0,

    pub fn destroy(self: *Job) void {
        self.probe.deinit();
        if (self.decoded) |d| d.deinit();
        self.alloc.destroy(self);
    }
};

/// A deliberate stall in front of the pull, in nanoseconds (0 ⇒ none).
///
/// A TEST SEAM, and it earns its place the way `GHOZTTY_RESTORE_PROBE_UNKNOWN`
/// (T657) does. The behaviour this module exists to fix is only visible while
/// the agent is SLOW to answer, and a healthy local agent on a named pipe
/// answers in single-digit milliseconds — so an acceptance script has no way to
/// hold the restore open long enough to ask whether the app is still pumping.
/// The relay script produces the same interval by telling its fake relay to
/// defer every connect (`-SlowConnectMs`); there is no equivalent lever in front
/// of a real agent's pipe, short of wedging the daemon that owns the user's
/// sessions.
///
/// It is read on the GUI thread and PAID inside `worker`, immediately in front
/// of the RPC it describes — so it moves with that code. A build that put the
/// pull back on the GUI thread would stall the GUI thread, which is exactly what
/// the assertion is looking for.
///
/// Unset (every real run) leaves the code below byte-identical.
fn stallNs(alloc: Allocator) u64 {
    const v = std.process.getEnvVarOwned(alloc, "GHOZTTY_RESTORE_PULL_DELAY_MS") catch return 0;
    defer alloc.free(v);
    const ns = parseStallNs(v);
    if (ns > 0) log.warn(
        "restore all: pull stalled {d}ms by GHOZTTY_RESTORE_PULL_DELAY_MS",
        .{ns / std.time.ns_per_ms},
    );
    return ns;
}

/// The seam's value, as nanoseconds. Anything that is not a positive whole
/// number of milliseconds is NO stall rather than an error: a malformed seam
/// must leave a real run behaving exactly as an unset one does.
fn parseStallNs(raw: []const u8) u64 {
    const ms = std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return 0;
    // A ceiling, because this is reachable from the user's environment: the
    // restore is still cancellable (the app pumps throughout, which is the
    // point), but a typo must not park a worker thread for a week.
    const capped: u64 = @min(ms, max_stall_ms);
    return capped * std.time.ns_per_ms;
}

/// The most a test seam may stall the pull by.
const max_stall_ms: u64 = 60_000;

/// GUI thread: start a LOCAL Restore All over `pull`. Returns false when nothing
/// was started (out of memory, no message window, no thread) — the caller then
/// says so instead of waiting for a reply that will never come.
///
/// Resolving the connection happens in the CALLER, on the GUI thread, because
/// that is where the state that owns it lives — the same division
/// `SessionRoster.fetch` draws.
pub fn start(app: *App, chooser_id: u64, pull: *remote_connection.Connection) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const alloc = app.core_app.alloc;
    const hwnd = app.msg_hwnd orelse return false;

    const job = alloc.create(Job) catch return false;
    job.* = .{
        .alloc = alloc,
        .hwnd = hwnd,
        .chooser_id = chooser_id,
        .pull = pull,
        .stall_ns = stallNs(alloc),
    };

    const thread = std.Thread.spawn(.{}, worker, .{job}) catch |err| {
        log.warn("restore all: local worker thread spawn failed err={}", .{err});
        job.destroy();
        return false;
    };
    thread.detach();
    return true;
}

fn worker(job: *Job) void {
    const alloc = job.alloc;

    // In front of the RPC it describes, so it is paid on whichever thread that
    // RPC ends up running on (see `stallNs`).
    if (job.stall_ns > 0) std.Thread.sleep(job.stall_ns);

    const payload = job.pull.requestLayouts(App.restore_probe_timeout_ns) catch |err| {
        log.warn("restore all: GET_LAYOUTS failed err={}", .{err});
        job.err = error.PullFailed;
        return finish(job);
    };
    defer alloc.free(payload);

    const decoded = layout_blobs.decodeLayouts(alloc, payload) catch |err| {
        log.warn("restore all: layouts payload unreadable err={}", .{err});
        job.err = error.PullFailed;
        return finish(job);
    };
    job.decoded = decoded;
    job.held = decoded.windows.len;
    if (decoded.skipped > 0) {
        // Said out loud rather than silently: "3 of 5 windows" is a different
        // fact from "3 windows", and only one of them is worth investigating.
        log.warn("restore all: {d} blob(s) skipped as unreadable", .{decoded.skipped});
    }

    // T851: the same no-stealing rule launch restore follows, and the local
    // arm keeps `.skip_live_holders` where the relay arm takes `.attachable` —
    // locally an app that dies drops its pipe and the agent's flag is accurate
    // again within milliseconds, so an ATTACHED session really is somebody's.
    // This arm needs no settle window either: the button is pressed long after
    // any crash that orphaned these sessions.
    job.probe = App.AttachProbe.take(alloc, job.pull, .skip_live_holders);

    finish(job);
}

/// Hand the job back to the GUI thread, or free it when there is no longer a
/// GUI thread to hand it to.
fn finish(job: *Job) void {
    if (w32.PostMessageW(job.hwnd, WM_APP_RESTORE_ALL_LOCAL, @intFromPtr(job), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        job.destroy();
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "a malformed pull stall is no stall at all" {
    // Every real run reads no variable at all; these are the shapes a mistyped
    // one takes, and none of them may change how a restore behaves.
    try testing.expectEqual(@as(u64, 0), parseStallNs(""));
    try testing.expectEqual(@as(u64, 0), parseStallNs("0"));
    try testing.expectEqual(@as(u64, 0), parseStallNs("soon"));
    try testing.expectEqual(@as(u64, 0), parseStallNs("-5"));
    try testing.expectEqual(@as(u64, 0), parseStallNs("1.5"));
}

test "a well-formed pull stall is milliseconds, and bounded" {
    try testing.expectEqual(1500 * std.time.ns_per_ms, parseStallNs("1500"));
    // Surrounding whitespace is a shell artifact, not a different value.
    try testing.expectEqual(250 * std.time.ns_per_ms, parseStallNs("  250\r\n"));
    // The ceiling holds however big the typo was.
    try testing.expectEqual(max_stall_ms * std.time.ns_per_ms, parseStallNs("999999999"));
}
