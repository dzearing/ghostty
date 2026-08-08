//! Per-window remote reconnect ladder — the DRIVER (T366, WP-D1 spec §5.1).
//!
//! `remote_reconnect.zig` holds the DECISIONS (T365): what counts as a drop,
//! the backoff schedule, when to stop, the poisoned-session breaker, and the
//! generation that cancels a stale attempt. All of it is pure and tested in
//! every lane. This file is the moving half — the parts that cannot be pure:
//! an observer on a live transport, a blocking dial on a worker thread, and the
//! swap that re-points a window's panes onto the connection that dial produced.
//!
//! Before this, a cross-machine window whose agent died degraded to a clean dead
//! pane and stayed that way: no hang, no crash, and no way back short of closing
//! the window and losing the session. Mac has reconnected since WP-D1.
//!
//! ## Shape
//!
//!  1. **Notice.** `install` puts a link-state observer on the window's
//!     transport. It runs on the CONNECTION'S READER THREAD, so it does exactly
//!     one thing — post `WM_APP_REMOTE_LINK` to the app's message-only window —
//!     and every decision happens on the GUI thread. Re-installed on every swap
//!     so a retired connection stops being listened to.
//!  2. **Drive.** `tick` (a 250ms timer, the same cadence and for the same
//!     reason as `agent_recovery`'s settle watch) samples each remote window's
//!     link, asks the policy what it means, and starts / paces / ends the ladder.
//!     It is armed only while some window has something to wait for
//!     (`policy.needsTick`), so a healthy remote window costs nothing.
//!  3. **Dial.** `startAttempt` spawns a DETACHED worker that dials the window's
//!     recorded machine (TCP or relay), completes the bounded HELLO handshake,
//!     and asks the agent for its session roster. It posts the whole outcome
//!     back as a `*Result` the GUI thread owns from that moment. The worker
//!     holds NO pointer into the window — it carries the window's `layout_uuid`
//!     and a generation, and the GUI thread resolves both — so a window that
//!     closed mid-dial cannot be written through; the reply simply frees what it
//!     brought.
//!  4. **Swap.** `applySwap` re-ATTACHes the recorded sessions on the NEW
//!     connection FIRST and only then retires the old one, guarded by
//!     `policy.SwapGuard`. Backwards, this ends the session it is trying to
//!     save.
//!
//! ## Two rules that are not obvious
//!
//! **A replaced transport is RETIRED, never destroyed.** `Surface.remote_conn`
//! and each pane's `termio.Remote` backend hold the connection pointer borrowed,
//! and nothing refcounts it — so freeing a connection while any surface still
//! exists is a use-after-free. The old transport is shut down (idempotent;
//! unblocks anyone waiting and makes every later send fail cleanly) and kept
//! alive on the window until `Window.deinit` frees it after every surface is
//! gone. This is exactly `LocalAgent.retire`'s bargain: one live-forever
//! connection per drop beats a dangling pointer in the user's terminal.
//!
//! **Local-agent windows are not this ladder's business.** They recover through
//! `agent_recovery.zig` (one re-dial for the whole app, every local window
//! rebuilt in place), which is how Mac excludes `isLocalMachine` too. This
//! ladder only ever looks at windows with a `remote_dialed` transport.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const Window = @import("Window.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const policy = @import("remote_reconnect.zig");
const session_layout = @import("session_layout.zig");
const tcp_dial = @import("../../remote/tcp_dial.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const remote_connection = @import("../../remote/connection.zig");
const pane_id_mod = @import("pane_id.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted from a connection's reader thread when a watched remote link changes
/// state. Carries nothing: the GUI thread re-samples every remote window, which
/// is one atomic read each and cannot be made stale by a racing teardown.
pub const WM_APP_REMOTE_LINK: u32 = w32.WM_APP + 17;

/// Posted by a redial worker with a heap `*Result` in wparam. It lands on the
/// APP's message-only window rather than the terminal window on purpose:
/// `DestroyWindow` discards a window's queued messages, and a discarded reply
/// would leak the connection it just opened (the T295/T318 lesson).
pub const WM_APP_REMOTE_DIALED: u32 = w32.WM_APP + 18;

/// The reconnect poller's id on `App.msg_hwnd`.
pub const TIMER_ID: usize = 6;

/// How often the ladder is driven. Same 250ms as `agent_recovery.poll_ms`, for
/// the same reason: fine enough that a backoff lands when it says it does,
/// coarse enough to be free.
pub const poll_ms: u32 = 250;

/// How long the roster probe on a freshly dialed connection may take before the
/// attempt treats liveness as UNKNOWN. Runs on the worker, so this is not a GUI
/// stall — but an agent that accepts and then says nothing must not park the
/// ladder either.
const probe_timeout_ns: u64 = 5 * std.time.ns_per_s;

// =============================================================================
// Per-window state
// =============================================================================

/// The ladder's live state for one window. Lives ON the window (`Window
/// .reconnect`), so it is created and destroyed with it and there is no separate
/// registry to keep in sync.
pub const State = struct {
    /// The policy's window state — what T367's pill will paint.
    ladder: policy.WindowState = .connected,
    /// Poisoned-session circuit breaker, judged once per drop.
    breaker: policy.Breaker = .{},
    /// Cancellation. Bumped by every event that invalidates in-flight work.
    gen: policy.Generation = .{},
    /// The 1-based fast-ladder attempt currently being paced or run.
    attempt: u32 = 0,
    /// Wall-clock ms at which the next dial is due (0 ⇒ nothing scheduled).
    due_ms: i64 = 0,
    /// A worker is dialing right now. Keeps `tick` from stacking attempts and
    /// keeps the poller armed while a dial is outstanding.
    inflight: bool = false,

    /// Transports this window has replaced. Shut down but deliberately NOT
    /// freed — see the module doc. Emptied by `releaseTransports` at window
    /// teardown, which runs after every surface is gone.
    retired: std.ArrayList(Window.RemoteDialed) = .empty,

    /// Threads that are shutting a retired transport down. Joined at teardown so
    /// nothing is freed out from under one.
    teardowns: std.ArrayList(std.Thread) = .empty,
};

// =============================================================================
// Observation
// =============================================================================

/// Watch this window's CURRENT transport. Idempotent; call again after every
/// swap so the retired connection's dying transitions stop being reported and
/// the fresh one's are.
pub fn install(window: *Window) void {
    if (comptime builtin.os.tag != .windows) return;
    const dialed = window.remote_dialed orelse return;
    dialed.conn().setStateHandler(window.app, onLinkChange);
}

/// Link-state observer. Runs on the CONNECTION'S READER THREAD, under its
/// `state_mutex`: it may not touch GUI state, allocate into app structures, or
/// re-enter `Connection`. It posts and returns.
fn onLinkChange(
    ctx: *anyopaque,
    conn: *remote_connection.Connection,
    old: remote_connection.LinkState.State,
    new: remote_connection.LinkState.State,
) void {
    _ = conn;
    // Every edge is interesting here, unlike the local-agent watch: a link that
    // comes BACK is how a self-healable window recovers with no click, and
    // `policy.onLinkChange` is what decides which edges mean anything.
    if (old == new) return;

    const app: *App = @ptrCast(@alignCast(ctx));
    // `msg_hwnd` is created in `init` and cleared in `terminate`, both on the
    // GUI thread. A racing teardown at worst drops this post, and a teardown is
    // exactly when reconnecting is pointless anyway.
    const hwnd = app.msg_hwnd orelse return;
    _ = w32.PostMessageW(hwnd, WM_APP_REMOTE_LINK, 0, 0);
}

/// A watched link changed. GUI thread: re-sample every remote window.
pub fn onLinkPost(app: *App) void {
    tick(app);
}

// =============================================================================
// Driving
// =============================================================================

/// Arm the poller. Cheap and idempotent — `SetTimer` with a live id just resets
/// it — so every path that creates work may simply call this.
pub fn arm(app: *App) void {
    if (comptime builtin.os.tag != .windows) return;
    const hwnd = app.msg_hwnd orelse return;
    _ = w32.SetTimer(hwnd, TIMER_ID, poll_ms, null);
}

fn disarm(app: *App) void {
    if (app.msg_hwnd) |hwnd| _ = w32.KillTimer(hwnd, TIMER_ID);
}

/// One pass over every cross-machine window. GUI thread. Also the timer handler.
pub fn tick(app: *App) void {
    if (comptime builtin.os.tag != .windows) return;
    const now = std.time.milliTimestamp();
    var wanted = false;
    for (app.windows.items) |win| {
        if (win.remote_dialed == null) continue;
        drive(app, win, now);
        const rc = &win.reconnect;
        if (rc.inflight or policy.needsTick(rc.ladder)) wanted = true;
    }
    if (wanted) arm(app) else disarm(app);
}

/// Drive ONE window: fold the transport's current state into the ladder, then
/// run whatever the ladder has become due.
fn drive(app: *App, window: *Window, now: i64) void {
    const dialed = window.remote_dialed orelse return;
    const rc = &window.reconnect;
    const link = policy.classify(dialed.conn().state());

    switch (policy.onLinkChange(rc.ladder, link)) {
        .none => {},
        .recovered => {
            // Either a heartbeat blip that healed, or a frozen agent thawing
            // after the ladder gave up. Either way the surfaces ride THIS
            // connection, so the window works again — and any attempt still in
            // flight is now noise.
            _ = rc.gen.bump();
            rc.attempt = 0;
            rc.due_ms = 0;
            rc.ladder = .connected;
            rc.breaker.reset();
            log.info("remote reconnect: link recovered on its own for '{s}'", .{windowName(window)});
        },
        .begin_reconnect => beginLadder(app, window, now, false),
        .go_terminal => {
            // `dead` is only ever reached by eviction or a session the agent
            // says is gone (§5.3) — never by a socket dying, which lands in
            // `reconnecting`. So this really is unrecoverable, not a wobble.
            if (rc.ladder.isConnected() or rc.ladder == .reconnecting) {
                log.warn(
                    "remote reconnect: '{s}' is terminally disconnected (evicted or session gone)",
                    .{windowName(window)},
                );
            }
            goTerminal(rc);
        },
    }

    if (rc.inflight) return;
    if (rc.due_ms == 0 or now < rc.due_ms) return;
    rc.due_ms = 0;
    startAttempt(app, window);
}

/// A drop was seen on a live window (or the user clicked Reconnect). Consult the
/// breaker and the policy, then either schedule attempt 1 or go terminal.
fn beginLadder(app: *App, window: *Window, now: i64, manual: bool) void {
    const rc = &window.reconnect;

    // A click is fresh evidence: it clears the breaker's memory of the swaps it
    // condemned, because the user is explicitly asking us to try that session
    // again. The automatic path judges instead.
    const poisoned = if (manual) blk: {
        rc.breaker.reset();
        break :blk false;
    } else rc.breaker.judge(now);

    const has_session = windowHasSession(window);
    const decision = if (manual)
        policy.beginManualReconnect(rc.ladder)
    else
        policy.beginReconnect(rc.ladder, has_session, poisoned);

    switch (decision) {
        .ignore => return,
        .terminal_no_session => {
            log.warn(
                "remote reconnect: '{s}' dropped with no session to re-attach; nothing to come back to",
                .{windowName(window)},
            );
            goTerminal(rc);
        },
        .terminal_poisoned => {
            log.warn(
                "remote reconnect: '{s}' condemned after {d} swaps that died inside {d}ms",
                .{ windowName(window), policy.poison_limit, policy.poison_window_ms },
            );
            goTerminal(rc);
        },
        .start => |s| {
            _ = rc.gen.bump();
            rc.attempt = s.attempt;
            rc.ladder = .{ .reconnecting = .{ .attempt = s.attempt } };
            const delay = policy.backoffMs(s.attempt, manual);
            rc.due_ms = now + @as(i64, @intCast(delay));
            log.warn(
                "remote reconnect: '{s}' dropped; attempt {d}/{d} in {d}ms",
                .{ windowName(window), s.attempt, policy.max_attempts, delay },
            );
            arm(app);
        },
    }
}

fn goTerminal(rc: *State) void {
    _ = rc.gen.bump();
    rc.attempt = 0;
    rc.due_ms = 0;
    rc.ladder = policy.terminal_state;
}

/// The user asked for this window to reconnect NOW (T367's pill button). Starts
/// from ANY disconnected tier, terminal included, and dials without waiting out
/// a backoff.
pub fn manualReconnect(app: *App, window: *Window) void {
    if (comptime builtin.os.tag != .windows) return;
    if (window.remote_dialed == null) return;
    beginLadder(app, window, std.time.milliTimestamp(), true);
    tick(app);
}

/// Whether any pane of this window has a remote session id to re-ATTACH to. A
/// window with none has nothing a dial could bring back (`beginReconnect`).
fn windowHasSession(window: *const Window) bool {
    for (0..window.tab_count) |t| {
        var it = window.tab_trees[t].iterator();
        while (it.next()) |entry| {
            const surface = entry.view.surface() orelse continue;
            if (!surface.core_surface_ready) continue;
            if (surface.core_surface.remoteSessionId() != null) return true;
        }
    }
    return false;
}

fn windowName(window: *const Window) []const u8 {
    return window.ipc_name orelse "(unnamed)";
}

// =============================================================================
// The redial worker
// =============================================================================

/// The machine to dial, copied so the worker owns every byte it reads. A relay
/// target's bearer is resolved on the GUI thread (that is where the account
/// store lives) and travels with the request.
const Target = union(enum) {
    tcp: struct { host: []u8, port: u16 },
    relay: struct { base: []u8, device: []u8, token: []u8 },

    fn free(self: Target, alloc: Allocator) void {
        switch (self) {
            .tcp => |t| alloc.free(t.host),
            .relay => |r| {
                alloc.free(r.base);
                alloc.free(r.device);
                alloc.free(r.token);
            },
        }
    }
};

const Request = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    /// The window's stable layout identity (T338) — the ONLY handle the worker
    /// carries. A pointer would dangle the moment the window closed.
    uuid: pane_id_mod.Buf,
    gen: u64,
    target: Target,

    fn destroy(self: *Request) void {
        self.target.free(self.alloc);
        self.alloc.destroy(self);
    }
};

/// A finished attempt, in flight to the GUI thread, which owns it from the post.
pub const Result = struct {
    alloc: Allocator,
    uuid: pane_id_mod.Buf,
    gen: u64,
    dial: policy.DialResult,
    /// The transport this attempt opened, or null when the dial failed. The GUI
    /// thread either hands it to the window or frees it.
    dialed: ?Window.RemoteDialed = null,
    /// The agent's roster, or null when the probe never landed (liveness
    /// UNKNOWN — deliberately not the same as an empty roster).
    roster: ?remote_connection.OwnedSessions = null,

    pub fn destroy(self: *Result) void {
        if (self.dialed) |d| d.deinitDestroy(self.alloc);
        if (self.roster) |*r| r.deinit();
        self.alloc.destroy(self);
    }
};

/// Spawn the dial for this window's current attempt. GUI thread.
fn startAttempt(app: *App, window: *Window) void {
    const alloc = app.core_app.alloc;
    const rc = &window.reconnect;

    const hwnd = app.msg_hwnd orelse return;
    const machine = window.remote_machine orelse {
        // T68 records the machine at open time; without it there is nothing to
        // re-dial. Terminal rather than a retry loop against no address.
        log.warn(
            "remote reconnect: '{s}' has no recorded machine; cannot re-dial",
            .{windowName(window)},
        );
        goTerminal(rc);
        return;
    };

    const target: Target = switch (machine) {
        .tcp => |t| .{ .tcp = .{
            .host = alloc.dupe(u8, t.host) catch return failAttempt(app, window),
            .port = t.port,
        } },
        .relay => |r| blk: {
            // Credentials are resolved HERE: the account store is the GUI
            // thread's. Signed out is terminal until the user signs in, and says
            // so rather than blaming the network.
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const token = IpcHandlers.resolveToken(arena_state.allocator()) orelse {
                log.warn(
                    "remote reconnect: '{s}' needs a relay credential (signed out)",
                    .{windowName(window)},
                );
                goTerminal(rc);
                return;
            };
            const base = alloc.dupe(u8, r.base) catch return failAttempt(app, window);
            const device = alloc.dupe(u8, r.device) catch {
                alloc.free(base);
                return failAttempt(app, window);
            };
            const tok = alloc.dupe(u8, token) catch {
                alloc.free(base);
                alloc.free(device);
                return failAttempt(app, window);
            };
            break :blk .{ .relay = .{ .base = base, .device = device, .token = tok } };
        },
    };

    const req = alloc.create(Request) catch {
        target.free(alloc);
        return failAttempt(app, window);
    };
    req.* = .{
        .alloc = alloc,
        .hwnd = hwnd,
        .uuid = window.layout_uuid,
        .gen = rc.gen.value,
        .target = target,
    };

    const thread = std.Thread.spawn(.{}, worker, .{req}) catch |err| {
        log.warn("remote reconnect: dial thread spawn failed err={}", .{err});
        req.destroy();
        return failAttempt(app, window);
    };
    thread.detach();
    rc.inflight = true;
    arm(app);
}

/// An attempt did not bring the window back. Also the landing site for an
/// attempt that could not even be STARTED, so a spawn or allocation failure
/// paces and exhausts exactly as an unreachable agent does rather than silently
/// stalling with nothing scheduled.
fn failAttempt(app: *App, window: *Window) void {
    const rc = &window.reconnect;
    const has_session = windowHasSession(window);

    // A failed BACKGROUND re-dial is not a fast-ladder attempt. Restarting the
    // 1/2/4/8/15s burst here would both hammer a machine that is plainly gone
    // and tell the pill the window is "reconnecting" when what it is actually
    // doing is waiting — the exhausted state is the truthful one, and it is
    // sticky until something changes.
    if (rc.ladder == .disconnected) {
        rc.due_ms = if (rc.ladder.disconnected.self_healable and has_session)
            std.time.milliTimestamp() + @as(i64, @intCast(policy.redial_interval_ms))
        else
            0;
        arm(app);
        return;
    }

    switch (policy.onAttemptFailed(rc.attempt, has_session)) {
        .retry => |r| {
            rc.attempt = r.attempt;
            rc.ladder = .{ .reconnecting = .{ .attempt = r.attempt } };
            rc.due_ms = std.time.milliTimestamp() + @as(i64, @intCast(r.delay_ms));
        },
        .exhausted => |e| {
            rc.attempt = 0;
            // NOT terminal: the window is kept, the state is truthfully
            // self-healable, and a link that comes back later still recovers it
            // with no click (`onLinkChange`).
            rc.ladder = policy.exhausted_state;
            rc.due_ms = if (e.arm_background_redial)
                std.time.milliTimestamp() + @as(i64, @intCast(policy.redial_interval_ms))
            else
                0;
            log.warn(
                "remote reconnect: '{s}' exhausted its fast ladder; {s}",
                .{
                    windowName(window),
                    if (e.arm_background_redial)
                        "re-dialing in the background"
                    else
                        "no session to re-attach, waiting for the link",
                },
            );
        },
    }
    arm(app);
}

/// The detached dial. Owns `req`; hands its outcome to the GUI thread.
fn worker(req: *Request) void {
    defer req.destroy();
    const alloc = req.alloc;

    var dialed: ?Window.RemoteDialed = null;
    var dial: policy.DialResult = .failed;
    switch (req.target) {
        .tcp => |t| {
            if (alloc.create(tcp_dial.Dialed)) |d| {
                if (tcp_dial.dial(alloc, t.host, t.port, .raw)) |ok| {
                    d.* = ok;
                    dialed = .{ .tcp = d };
                    dial = .ok;
                } else |err| {
                    log.warn("remote reconnect: tcp dial {s}:{d} failed err={}", .{ t.host, t.port, err });
                    alloc.destroy(d);
                }
            } else |_| {}
        },
        .relay => |r| {
            if (alloc.create(relay_dial.Dialed)) |d| {
                if (relay_dial.dial(alloc, r.base, r.device, r.token, .raw)) |ok| {
                    d.* = ok;
                    dialed = .{ .relay = d };
                    dial = .ok;
                } else |err| {
                    log.warn("remote reconnect: relay dial device={s} failed err={}", .{ r.device, err });
                    // A rejected bearer is not an unreachable machine: retrying
                    // cannot sign anyone in, so the ladder must stop instead of
                    // spending five attempts on a 401.
                    if (err == error.WebSocketUnauthorized) dial = .unauthorized;
                    alloc.destroy(d);
                }
            } else |_| {}
        },
    }

    // The liveness probe rides this thread too. Doing it here is what lets the
    // GUI decide swap-vs-terminal without ever blocking on a machine that may
    // be gone.
    var roster: ?remote_connection.OwnedSessions = null;
    if (dialed) |d| {
        roster = d.conn().requestSessions(probe_timeout_ns) catch |err| blk: {
            log.warn("remote reconnect: liveness probe failed err={} (treating as unknown)", .{err});
            break :blk null;
        };
    }

    const res = alloc.create(Result) catch {
        if (dialed) |d| d.deinitDestroy(alloc);
        if (roster) |*r| r.deinit();
        return;
    };
    res.* = .{
        .alloc = alloc,
        .uuid = req.uuid,
        .gen = req.gen,
        .dial = dial,
        .dialed = dialed,
        .roster = roster,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_REMOTE_DIALED, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

// =============================================================================
// Landing an attempt
// =============================================================================

/// A redial finished. GUI thread; takes ownership of `res`.
pub fn onDialed(app: *App, res: *Result) void {
    defer res.destroy();
    if (comptime builtin.os.tag != .windows) return;

    const window = windowByUuid(app, &res.uuid) orelse {
        // The window closed while we were dialing. Nothing to write through —
        // the deferred destroy frees the connection this attempt opened, which
        // is the whole reason the worker carries a uuid instead of a pointer.
        log.info("remote reconnect: dial landed for a window that is gone; discarding", .{});
        return;
    };

    const rc = &window.reconnect;
    rc.inflight = false;
    if (!rc.gen.isCurrent(res.gen)) {
        // A newer ladder (or a recovery, or a close) overtook this attempt.
        log.info("remote reconnect: stale attempt for '{s}' discarded", .{windowName(window)});
        arm(app);
        return;
    }

    var probe = App.AttachProbe.fromRoster(app.core_app.alloc, res.roster);
    res.roster = null; // ownership moved into the probe
    defer probe.deinit();

    const outcome = policy.outcomeFromAttempt(res.dial, sessionPresent(window, &probe));
    switch (policy.onProbeOutcome(outcome, false)) {
        // `fresh_session_on_gone` is false: only a MANUAL reconnect may answer
        // "the session is gone" with an empty shell, because silently replacing
        // a user's grid with fresh prompts is a surprise, not a recovery.
        .swap => |s| {
            std.debug.assert(!s.fresh_session);
            const dialed = res.dialed orelse {
                // Cannot happen (a `.ok` dial always carries one) but the ladder
                // must not read the swap arm as a success it did not get.
                failAttempt(app, window);
                return;
            };
            if (applySwap(app, window, dialed, &probe)) {
                res.dialed = null; // the window owns it now
            } else {
                failAttempt(app, window);
            }
        },
        .retry => failAttempt(app, window),
        .terminal => {
            log.warn(
                "remote reconnect: '{s}' is terminal after attempt {d} ({s})",
                .{ windowName(window), rc.attempt, @tagName(outcome) },
            );
            goTerminal(rc);
        },
    }
    arm(app);
}

/// Whether the agent that just answered still owns any session this window is
/// holding. Tri-state, and the null must survive: a probe that never landed is
/// UNKNOWN, and `outcomeFromAttempt` reads that as "attempt the swap".
fn sessionPresent(window: *const Window, probe: *const App.AttachProbe) ?bool {
    if (probe.set == null) return null;
    for (0..window.tab_count) |t| {
        var it = window.tab_trees[t].iterator();
        while (it.next()) |entry| {
            const surface = entry.view.surface() orelse continue;
            if (!surface.core_surface_ready) continue;
            const sid = surface.core_surface.remoteSessionId() orelse continue;
            if (probe.owns(sid) orelse false) return true;
        }
    }
    return false;
}

fn windowByUuid(app: *App, uuid: *const pane_id_mod.Buf) ?*Window {
    for (app.windows.items) |win| {
        if (std.mem.eql(u8, win.layoutUuid(), uuid)) return win;
    }
    return null;
}

// =============================================================================
// The swap
// =============================================================================

/// Re-ATTACH this window's panes on `fresh`, then retire what they were riding.
/// Returns true when the window adopted `fresh` (the caller must NOT free it).
///
/// The ordering is the whole point and is asserted, not merely commented: the
/// old transport is retired only once `guard.mayRetireOld()` says every pane
/// that could come back has come back. Retiring first would tear down the
/// connection the departing surfaces DETACH over while their sessions are still
/// the ones we are re-attaching — the `sessionSpared` hazard, from the other end.
fn applySwap(
    app: *App,
    window: *Window,
    fresh: Window.RemoteDialed,
    probe: *const App.AttachProbe,
) bool {
    const rc = &window.reconnect;
    const gpa = app.core_app.alloc;
    var guard: policy.SwapGuard = .{};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Capture BEFORE anything moves: the live tree is the source of truth, and
    // the recorded session ids are what the rebuild re-ATTACHes by.
    const captured = app.captureOneWindow(arena, window, 0) catch |err| {
        log.warn("remote reconnect: layout capture failed err={}", .{err});
        guard.onAbandoned();
        return false;
    };

    const old = window.remote_dialed;
    // The window's transport pointer moves first: every surface the rebuild
    // creates below reads it, as does every future tab or split in this window.
    window.remote_dialed = fresh;

    const attached = app.rebuildWindowInPlace(arena, window, captured, .{
        .conn = fresh.conn(),
        // Cross-machine: `createWindow` must not hand these panes the LOCAL
        // agent, and `restoreAttachOverride` records the difference on each
        // surface's remote backend.
        .local_agent = false,
    }, probe.attachSet()) catch |err| {
        log.warn("remote reconnect: rebuild failed err={}", .{err});
        window.remote_dialed = old;
        guard.onAbandoned();
        return false;
    };

    if (attached == 0) {
        // Nothing re-attached, so nothing is riding the new transport and the
        // old one is still the only thing that knows these sessions. Put it
        // back and let the ladder count this as a failed attempt.
        log.warn("remote reconnect: rebuild attached no panes; keeping the old transport", .{});
        window.remote_dialed = old;
        guard.onAbandoned();
        return false;
    }
    guard.onAttached();

    // ONLY NOW may the old transport go. `retire` shuts it down off the GUI
    // thread and keeps the allocation alive until the window tears down.
    std.debug.assert(guard.mayRetireOld());
    if (old) |o| retire(app, window, o);
    guard.onRetired();

    // Watch the new connection, and stop watching the old one — otherwise a
    // retired transport's dying transitions keep waking the ladder.
    install(window);

    rc.attempt = 0;
    rc.due_ms = 0;
    rc.ladder = .connected;
    // Not `breaker.reset()`: a swap is not yet proof of recovery. The breaker
    // judges it if and when this link dies — that is what catches a session
    // that probes alive and then kills every connection attached to it.
    rc.breaker.onSwapCompleted(std.time.milliTimestamp());

    log.info(
        "remote reconnect: '{s}' is back on a fresh transport ({d} pane(s) re-attached)",
        .{ windowName(window), attached },
    );
    return true;
}

/// Stop using `d` without FREEING it — the exact bargain `LocalAgent.retire`
/// makes, and for the same reason: `Surface.remote_conn` and each pane's
/// `termio.Remote` hold this connection borrowed and nothing refcounts it, so
/// destroying it while any surface still exists is a use-after-free.
fn retire(app: *App, window: *Window, d: Window.RemoteDialed) void {
    const alloc = app.core_app.alloc;
    const rc = &window.reconnect;

    // Stop it observing FIRST. `clearStateHandler` returns only once any
    // in-flight handler has finished, so this is also the teardown-safe order.
    d.conn().clearStateHandler();

    rc.retired.append(alloc, d) catch {
        // Out of memory while retiring: dropping the struct leaks it outright,
        // which is still strictly safer than destroying a borrowed connection.
        log.warn("remote reconnect: retired transport could not be tracked; leaking it", .{});
        return;
    };

    // `shutdown` JOINS the connection's writer, reader and heartbeat threads.
    // On the GUI thread a peer that does not exit promptly does not slow the app
    // down — it WEDGES it, with no log line and no crash (the T229 shape). A
    // retired connection is never freed until window teardown, and teardown
    // joins these threads first, so nothing here needs the join to have
    // happened.
    const t = std.Thread.spawn(.{}, shutdownRetired, .{d.conn()}) catch |err| {
        log.warn("remote reconnect: async teardown unavailable ({}), shutting down inline", .{err});
        d.conn().shutdown();
        return;
    };
    rc.teardowns.append(alloc, t) catch {
        t.detach();
        log.warn("remote reconnect: retired teardown thread could not be tracked; detached", .{});
    };
}

fn shutdownRetired(conn: *remote_connection.Connection) void {
    conn.shutdown();
}

/// Free every transport this window retired. Called from BOTH window teardown
/// paths, and only ever AFTER `cleanupAllSurfaces` — the same precondition
/// `remote_dialed`'s own teardown has, for the same reason.
pub fn releaseTransports(window: *Window, alloc: Allocator) void {
    const rc = &window.reconnect;

    // Stop observing the live transport before it is torn down. Its dying
    // transitions are noise, and `clearStateHandler` returns only once any
    // in-flight handler has finished — the same teardown-safe ordering `retire`
    // keeps for a replaced one.
    if (window.remote_dialed) |d| d.conn().clearStateHandler();

    // Let every async shutdown finish before the allocations it is walking are
    // freed below.
    for (rc.teardowns.items) |t| t.join();
    rc.teardowns.deinit(alloc);
    rc.teardowns = .empty;

    for (rc.retired.items) |d| d.deinitDestroy(alloc);
    rc.retired.deinit(alloc);
    rc.retired = .empty;

    // A dial still in flight would post a Result naming this window's uuid.
    // Bumping the generation is not enough — the window itself is going away —
    // so the reply must fail to RESOLVE it, which it does: `windowByUuid` walks
    // the live window list, and this window leaves it before either teardown
    // path runs.
    _ = rc.gen.bump();
    rc.inflight = false;
}
