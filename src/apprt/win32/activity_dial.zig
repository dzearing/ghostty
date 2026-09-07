//! Activity monitor connection plane: dialing a machine, and letting go of one.
//!
//! Split out of `ActivityMonitor.zig` (T299). Everything with a LIFETIME in it
//! lives here — the dial thread, the metrics subscription, the borrow of a
//! window's live connection, and the teardown that has to undo all three in
//! the right order. This is the part where a mistake leaks a connection or
//! frees a live window's shell, which is exactly why it is worth reading on
//! its own.
//!
//! The rules, all of them enforced below:
//!
//!   * **Unsubscribe before join, join before free.** `teardownSource` drops
//!     the metrics subscription first, then waits for the dial thread, then
//!     frees the connection. Any other order can free memory a thread is still
//!     reading.
//!   * **A borrowed connection is never freed.** `borrowFromWindow` hands back
//!     a connection a WINDOW owns; `releaseBorrowed` gives it back rather than
//!     closing it, and the window's own teardown is what ends it.
//!   * **Bump the serial so a stale dial frees itself.** `resetForNewSource`
//!     takes a new serial; `onDialed` compares the serial it started under and
//!     closes what it was handed if the panel has moved on.
//!
//! The commentary this file inherited from the panel's header says where those
//! rules came from:
//!
//! ## Remote sources (T295)
//! A `.remote` panel samples through a `remote.Connection`, and who OWNS that
//! connection is the whole design (Mac's `RemoteActivityMonitor.swift:8-16`):
//!
//! - **Dialed** (the chooser's Activity button) — the panel dials a fresh relay
//!   connection and owns it, so `close` frees it.
//! - **Reused** (the palette on a remote window) — the panel borrows the
//!   WINDOW's connection and must never free it; closing the panel cannot be
//!   allowed to take that window's session down with it.
//!
//! The dial blocks through a handshake, so it runs on a detached thread and
//! lands via `WM_APP_ACTIVITY_DIALED` on the APP's message-only window, not on
//! the panel's. That is the difference between a result that always arrives and
//! one that Windows silently discards: `DestroyWindow` drops a window's queued
//! messages, so a dial posted to a panel that closes first would leak the
//! connection it just opened. The app's window outlives every panel, and the
//! `(slot, serial)` pair tells it whether the panel that asked is still there.
//!
//! Host CPU% comes from the pushed `metrics` stream, NOT from the snapshot: the
//! agent builds `PROC_SNAPSHOT.host` from a fresh sampler with no prior tick and
//! says so at `agent/server.zig:1607`. Reading that as CPU% would paint a
//! confident flat zero.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ActivityMonitor = @import("ActivityMonitor.zig");
const App = @import("App.zig");
const IpcHandlers = @import("IpcHandlers.zig");
const borrow_mod = @import("activity_borrow.zig");
const gauge = @import("trend_gauge.zig");
const relay_dial = @import("../../remote/relay_dial.zig");
const relay_directory = @import("../../remote/relay_directory.zig");
const remote_connection = @import("../../remote/connection.zig");
const remote_metrics = @import("../../remote/agent/metrics.zig");
const remote_protocol = @import("../../remote/protocol.zig");
const w32 = @import("win32.zig");

const WM_APP_ACTIVITY_DIALED = ActivityMonitor.WM_APP_ACTIVITY_DIALED;
const log = ActivityMonitor.log;
const max_monitors = ActivityMonitor.max_monitors;
const panelMatches = ActivityMonitor.panelMatches;

// ---------------------------------------------------------------------
// Remote connection
// ---------------------------------------------------------------------

/// The connection a remote panel samples through, and who owns it.
///
/// `dialed != null` ⇒ this panel dialed it and MUST tear it down on close.
/// `dialed == null` ⇒ borrowed from a remote window (Mac's `ownsConnection:
/// false`), and closing the panel must leave that window's session untouched.
pub const RemoteConn = struct {
    conn: *remote_connection.Connection,
    dialed: ?*relay_dial.Dialed = null,

    pub fn owned(self: RemoteConn) bool {
        return self.dialed != null;
    }
};

/// A finished dial, in flight to the GUI thread as `WM_APP_ACTIVITY_DIALED`'s
/// `wparam`. Owned by the handler, which frees it.
pub const DialResult = struct {
    alloc: Allocator,
    /// Which panel asked, and which incarnation of that slot.
    slot: usize,
    serial: u64,
    /// The dialed transport, or null when the dial failed.
    dialed: ?*relay_dial.Dialed,

    /// Free the result AND anything it still owns. Called when the panel that
    /// asked is gone — otherwise the panel adopts `dialed` first.
    pub fn destroy(self: *DialResult) void {
        const alloc = self.alloc;
        if (self.dialed) |d| {
            d.deinit();
            alloc.destroy(d);
        }
        alloc.destroy(self);
    }
};

/// Everything the dial thread needs, heap-owned so it outlives the call that
/// spawned it. The thread frees it.
pub const DialRequest = struct {
    alloc: Allocator,
    hwnd: w32.HWND,
    slot: usize,
    serial: u64,
    base: []u8,
    device: []u8,
    token: []u8,

    pub fn destroy(self: *DialRequest) void {
        const alloc = self.alloc;
        alloc.free(self.base);
        alloc.free(self.device);
        alloc.free(self.token);
        alloc.destroy(self);
    }
};

// ---------------------------------------------------------------------
// Dialing
// ---------------------------------------------------------------------

/// Kick off a relay dial for this panel's remote source on a detached thread.
/// The credentials are resolved HERE, on the GUI thread, because that is where
/// the account store lives; the blocking part (TCP + TLS + WebSocket upgrade +
/// HELLO) is all the thread does.
pub fn startDial(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    const msg_hwnd = self.app.msg_hwnd orelse {
        log.warn("activity monitor: no message window, cannot dial", .{});
        self.refresh_failed = true;
        self.loading = false;
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = IpcHandlers.resolveToken(arena) orelse {
        // Mac's WP-B2 rule: signed out is not an error dialog here, it is a
        // source that cannot be reached.
        log.warn("activity monitor: no relay credential (signed out) source={s}", .{self.source.label()});
        self.refresh_failed = true;
        self.loading = false;
        return;
    };
    const base = relay_directory.resolveBase(arena) catch {
        self.refresh_failed = true;
        self.loading = false;
        return;
    };

    const req = alloc.create(DialRequest) catch return;
    req.* = .{
        .alloc = alloc,
        .hwnd = msg_hwnd,
        .slot = self.slot,
        .serial = self.serial,
        .base = alloc.dupe(u8, base) catch {
            alloc.destroy(req);
            return;
        },
        .device = undefined,
        .token = undefined,
    };
    req.device = alloc.dupe(u8, self.source.remote.id) catch {
        alloc.free(req.base);
        alloc.destroy(req);
        return;
    };
    req.token = alloc.dupe(u8, token) catch {
        alloc.free(req.base);
        alloc.free(req.device);
        alloc.destroy(req);
        return;
    };

    const thread = std.Thread.spawn(.{}, dialWorker, .{req}) catch |err| {
        log.warn("activity monitor: dial thread spawn failed err={}", .{err});
        req.destroy();
        self.refresh_failed = true;
        self.loading = false;
        return;
    };
    thread.detach();

    self.dialing = true;
    log.info("activity monitor: dialing source={s} slot={d}", .{ self.source.label(), self.slot });
}

/// The detached dial. Owns `req`; hands its outcome to the GUI thread as a
/// `*DialResult`, which the handler owns from that moment on.
pub fn dialWorker(req: *DialRequest) void {
    defer req.destroy();
    const alloc = req.alloc;

    var dialed: ?*relay_dial.Dialed = null;
    if (alloc.create(relay_dial.Dialed)) |d| {
        if (relay_dial.dial(alloc, req.base, req.device, req.token, .raw)) |ok| {
            d.* = ok;
            dialed = d;
        } else |err| {
            log.warn("activity monitor: dial failed device={s} err={}", .{ req.device, err });
            alloc.destroy(d);
        }
    } else |_| {}

    const res = alloc.create(DialResult) catch {
        if (dialed) |d| {
            d.deinit();
            alloc.destroy(d);
        }
        return;
    };
    res.* = .{
        .alloc = alloc,
        .slot = req.slot,
        .serial = req.serial,
        .dialed = dialed,
    };
    if (w32.PostMessageW(req.hwnd, WM_APP_ACTIVITY_DIALED, @intFromPtr(res), 0) == 0) {
        // The app is going away; nothing will ever collect this.
        res.destroy();
    }
}

/// GUI thread (App.msgWndProc): a dial finished. Takes ownership of `res`.
pub fn onDialed(res: *DialResult) void {
    var serials: [max_monitors]?u64 = @splat(null);
    for (ActivityMonitor.open_wins, 0..) |maybe, i| {
        if (maybe) |p| {
            if (!p.closing) serials[i] = p.serial;
        }
    }

    if (panelMatches(&serials, res.slot, res.serial)) {
        adoptDial(ActivityMonitor.open_wins[res.slot].?, res.dialed);
        res.dialed = null; // adopted (or mourned) by the panel
        res.destroy();
        return;
    }

    // The panel that asked is gone. Freeing here is the whole reason this
    // lands on the app's window instead of the panel's.
    log.info("activity monitor: dial landed after its panel closed slot={d}", .{res.slot});
    res.destroy();
}

/// Adopt (or mourn) a finished dial. GUI thread.
pub fn adoptDial(self: *ActivityMonitor, dialed: ?*relay_dial.Dialed) void {
    self.dialing = false;
    const d = dialed orelse {
        // A dial failure is an ANSWER, same as a failed sample: stop loading so
        // the overlay can say "Couldn't connect" instead of sitting on a
        // spinner forever.
        self.refresh_failed = true;
        self.loading = false;
        self.rebuildCards();
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        log.warn("activity monitor: dial failed source={s}", .{self.source.label()});
        return;
    };
    self.remote_conn = .{ .conn = d.conn, .dialed = d };
    beginMetrics(self);
    log.info("activity monitor: connected source={s}", .{self.source.label()});
    self.rebuildCards();
    self.kickSample();
}

/// Subscribe to the source's pushed host-metrics stream. Host CPU% is only
/// truthful from this stream (see the header); everything else the snapshot
/// already carries.
pub fn beginMetrics(self: *ActivityMonitor) void {
    const rc = self.remote_conn orelse return;
    rc.conn.subscribeMetrics(
        @intCast(gauge.sample_interval_ms),
        self,
        onMetrics,
    ) catch |err| {
        // Not fatal: the table still refreshes, the host CPU gauge just stays
        // at whatever the snapshot reports.
        log.warn("activity monitor: metrics subscribe failed err={}", .{err});
    };
}

/// Control-reader thread: park the newest reading for the sample worker. It
/// does NOT touch view state — see `Connection.MetricsHandler`'s threading
/// contract.
pub fn onMetrics(ctx: *anyopaque, host: remote_protocol.HostMetrics) void {
    const self: *ActivityMonitor = @ptrCast(@alignCast(ctx));
    self.metrics_mutex.lock();
    defer self.metrics_mutex.unlock();
    self.last_metrics = host;
}

/// The connection a live WINDOW is already riding to the machine `id` names, or
/// null when no window is — in which case the caller dials its own (T301).
///
/// The decision itself is pure (`activity_borrow.borrowFrom`), asked one window
/// at a time so the first-connected-match rule holds without building a list.
/// The identity key it compares — relay device id, else `host:port` — is the
/// same one `Surface.openActivityMonitor` builds when the palette opens a panel
/// on its window's connection, which is what makes the two entry points agree
/// about which machine a window IS.
///
/// This is deliberately NOT wired into the chooser's Activity button: dialing
/// your own connection is what that entry means on both platforms (Mac's
/// `presentDialing`), and it is the only entry that can reach a machine no
/// window is on. The switch is different — it is the panel returning to a
/// machine it was already borrowing.
pub fn borrowFromWindow(app: *App, id: []const u8) ?*remote_connection.Connection {
    for (app.windows.items) |win| {
        const dialed = win.remote_dialed orelse continue;
        const machine = win.remote_machine orelse continue;
        const cand = [_]borrow_mod.Candidate{.{
            .machine = switch (machine) {
                .relay => |r| .{ .relay = r.device },
                .tcp => |t| .{ .tcp = .{ .host = t.host, .port = t.port } },
            },
            // Only a window whose link is UP is worth borrowing: a connection
            // that cannot answer would report the machine unreachable when a
            // dial might still have reached it.
            .connected = win.reconnect.ladder == .connected,
        }};
        if (borrow_mod.borrowFrom(&cand, id) != null) return dialed.conn();
    }
    return null;
}

/// A window is about to FREE `conn` (T301). Any panel BORROWING it has to let go
/// first — the panel's sample worker holds it across an RPC, and the window's
/// teardown does not otherwise know a panel exists.
///
/// Called from `RemoteReconnect.releaseTransports`, which is the one place both
/// window-teardown paths meet and which runs for the live transport and every
/// retired one alike. Order inside: unsubscribe (no further metrics callback can
/// fire), shut the connection down so a worker parked on an unresponsive agent
/// returns at once, then JOIN it — the usual borrowed-connection rule against
/// shutdown does not apply when the owner is destroying it in the next breath.
/// The panel stays open and reports the machine as unreachable, which is the
/// truth: the link it was watching through has gone.
pub fn releaseBorrowed(conn: *remote_connection.Connection) void {
    for (ActivityMonitor.open_wins) |maybe| {
        const self = maybe orelse continue;
        const rc = self.remote_conn orelse continue;
        if (rc.owned() or rc.conn != conn) continue;

        log.info("activity monitor: borrowed connection is going away source={s}", .{self.source.label()});
        rc.conn.unsubscribeMetrics();
        rc.conn.shutdown();
        if (self.worker) |t| {
            t.join();
            self.worker = null;
            self.sampling = false;
        }
        self.remote_conn = null;
        self.metrics_mutex.lock();
        self.last_metrics = null;
        self.metrics_mutex.unlock();

        // A sample already parked by that worker described a machine we can no
        // longer reach; retiring the generation is what drops it.
        self.source_gen +%= 1;
        if (self.closing) continue;
        self.refresh_failed = true;
        self.loading = false;
        self.rebuildCards();
        _ = w32.InvalidateRect(self.hwnd, null, 0);
    }
}

/// A window has SWAPPED transports (T614). Any panel borrowing the old one has
/// to follow it onto the new one, or it samples a retired connection forever.
///
/// `RemoteReconnect.retire` deliberately leaves the old pointer valid — nothing
/// refcounts it, so it is kept until window teardown — which means a panel
/// holding it is safe and permanently wrong: every sample fails and the card
/// reads "Couldn't connect" while the window beside it is working. That is a
/// confident wrong answer, which is worse than a missing one.
///
/// Called from `applySwap` AFTER the panes are re-attached and the new state
/// handler is installed, the same ordering `releaseBorrowed` keeps. What it does
/// NOT do is shut the old connection down or join the sample worker: the worker
/// may be parked on an RPC the retiring window is already cutting loose in its
/// own thread, and joining it here would block the GUI for the whole rpc
/// timeout. Retiring the generation is what makes that worker's answer
/// droppable instead of adoptable, exactly as a source switch does.
pub fn rebindBorrowed(
    old_conn: *remote_connection.Connection,
    new_conn: *remote_connection.Connection,
) void {
    if (old_conn == new_conn) return;
    for (ActivityMonitor.open_wins) |maybe| {
        const self = maybe orelse continue;
        const rc = self.remote_conn orelse continue;
        if (rc.owned() or rc.conn != old_conn) continue;

        log.info(
            "activity monitor: borrowed connection swapped; following the window source={s}",
            .{self.source.label()},
        );
        // No further callback can fire from the old transport once this
        // returns (`connection.zig`'s unsubscribe contract).
        rc.conn.unsubscribeMetrics();

        // Anything the parked worker parks describes the retired transport.
        self.source_gen +%= 1;
        self.metrics_mutex.lock();
        self.last_metrics = null;
        self.metrics_mutex.unlock();

        self.remote_conn = .{ .conn = new_conn, .dialed = null };
        self.beginMetrics();

        if (self.closing) continue;
        // The panel is not broken any more, so it must stop saying it is: back
        // to "Loading…" until the first sample over the new link lands.
        self.refresh_failed = false;
        self.loading = true;
        self.logged_sample_error = false;
        self.rebuildCards();
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        // A no-op while the old worker is still parked; the timer's next tick
        // picks it up either way.
        self.kickSample();
    }
}

/// Stop everything the current source owns, leaving the panel ready to begin a
/// new one. Reusable by `switchTo` — unlike `close`, this leaves the window,
/// the timer and the panel itself alive.
pub fn teardownSource(self: *ActivityMonitor) void {
    // Any sample still running belongs to the old source. Retiring the
    // generation is what makes its result droppable instead of adoptable.
    self.source_gen +%= 1;

    const rc = self.remote_conn orelse {
        self.dialing = false;
        return;
    };
    // Unsubscribe FIRST: `unsubscribeMetrics` returning is the guarantee that no
    // further callback can fire (`connection.zig:1148-1162`).
    rc.conn.unsubscribeMetrics();

    if (rc.owned()) {
        // Cut the transport before the join so a worker parked on an
        // unresponsive agent returns at once. Then JOIN — the worker holds this
        // connection and we are about to free it.
        rc.conn.shutdown();
        if (self.worker) |t| {
            t.join();
            self.worker = null;
            self.sampling = false;
        }
        if (rc.dialed) |d| {
            d.deinit();
            self.app.core_app.alloc.destroy(d);
        }
    }
    // Borrowed: nothing to free and nothing to join. The worker may still be
    // mid-RPC on a connection that belongs to a live window, which is safe —
    // and joining it could block the GUI for the whole `rpc_timeout_ns`, which
    // is not.

    self.remote_conn = null;
    self.dialing = false;
    self.metrics_mutex.lock();
    self.last_metrics = null;
    self.metrics_mutex.unlock();
}

/// Clear every view field the old source filled in. Trend history is the one
/// that MUST be cleared (Mac clears `samples` for exactly this reason,
/// :312-323): a chart that carried one machine's history under another's name
/// would be a fabricated reading.
pub fn resetForNewSource(self: *ActivityMonitor) void {
    const alloc = self.app.core_app.alloc;
    if (self.snap) |s| {
        s.destroy(alloc);
        self.snap = null;
    }
    // The parked sample belongs to the previous generation; drop it now rather
    // than leaving it to be dropped later.
    self.pending_mutex.lock();
    if (self.pending) |p| {
        p.destroy(alloc);
        self.pending = null;
    }
    self.pending_failed = false;
    self.pending_mutex.unlock();

    // The local sampler's CPU deltas are differences against its previous tick.
    // Keeping it across a trip to another machine would make the first sample
    // home a delta over however long the detour took.
    if (self.proc_sampler) |*p| {
        p.deinit();
        self.proc_sampler = null;
    }
    self.host_sampler = remote_metrics.Sampler.init();

    self.ring_len = 0;
    self.order_len = 0;
    self.sel_len = 0;
    self.scroll = 0;
    self.hover_row = -1;
    self.loading = true;
    self.refresh_failed = false;
    self.logged_sample_error = false;
    self.err_len = 0;
    self.refreshChrome();
}
