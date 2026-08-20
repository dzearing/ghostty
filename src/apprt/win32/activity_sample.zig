//! Activity monitor sampling: the poll loop and the snapshot it produces.
//!
//! Split out of `ActivityMonitor.zig` (T299). One worker thread at a time
//! enumerates processes (locally, or over the connection for a remote card),
//! builds an arena-backed `Snapshot`, and parks it in `pending` for the GUI
//! thread to adopt on WM_APP_ACTIVITY_SAMPLE.
//!
//! Two rules make that safe and they both live here:
//!
//!   * **Generation.** Every sample carries the generation it was started
//!     under. A sample whose generation no longer matches is DROPPED and freed
//!     by the GUI thread — that is how a source switch, a resize, or a close
//!     cannot be overtaken by a sample the panel no longer wants.
//!   * **The gate.** `sample_gate` decides whether a hidden, minimized or
//!     occluded panel should keep polling at all. Suspending clears the trend
//!     ring, because a CPU% delta across a suspension is a lie.
//!
//! The commentary this file inherited from the panel's header:
//!
//! ## Threading
//! `proc.ProcSampler.sample` enumerates every process on the box and opens each
//! one — far too much to run on the GUI thread every 1.5 s, and Mac runs the
//! equivalent on a background queue (RemoteActivityMonitorView.swift:99-101). So
//! the timer kicks a worker thread that samples into an arena-backed `Snapshot`,
//! parks it under a mutex and posts `WM_APP_ACTIVITY_SAMPLE`; the GUI thread
//! adopts it. Exactly one sample is ever in flight (`sampling`), so the two
//! samplers are only ever touched by that worker, and `close` JOINS it before
//! freeing anything it could still be writing to.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ActivityMonitor = @import("ActivityMonitor.zig");
const actions = @import("activity_actions.zig");
const gauge = @import("trend_gauge.zig");
const rows_mod = @import("activity_rows.zig");
const sample_gate = @import("sample_gate.zig");
const remote_connection = @import("../../remote/connection.zig");
const remote_proc = @import("../../remote/agent/proc.zig");
const remote_protocol = @import("../../remote/protocol.zig");
const w32 = @import("win32.zig");

const Snapshot = ActivityMonitor.Snapshot;
const WM_APP_ACTIVITY_SAMPLE = ActivityMonitor.WM_APP_ACTIVITY_SAMPLE;
const log = ActivityMonitor.log;
const max_rows = ActivityMonitor.max_rows;
const rpc_timeout_ns = ActivityMonitor.rpc_timeout_ns;

// ---------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------

/// What the OS says about this panel's window right now. Three cheap queries;
/// none of them enumerate anything, so asking on every tick costs nothing next
/// to the enumeration it can save.
pub fn visibility(self: *ActivityMonitor) sample_gate.Visibility {
    var cloaked: u32 = 0;
    // A pre-Windows-10 DWM (or a failure of any kind) answers non-zero and
    // leaves the out-param alone; `cloaked` stays 0, which is the safe default
    // — an unknown cloak state must read as "visible" so the gate can only ever
    // fail towards sampling a panel nobody is watching, never towards freezing
    // one somebody is.
    _ = w32.DwmGetWindowAttribute(self.hwnd, w32.DWMWA_CLOAKED, &cloaked, @sizeOf(u32));
    return .{
        .visible = w32.IsWindowVisible(self.hwnd) != 0,
        .minimized = w32.IsIconic(self.hwnd) != 0,
        .cloaked = cloaked != 0,
    };
}

/// Run one gate action. `.skip` is the whole point of the gate: no enumeration,
/// no repaint, no ring write.
///
/// `was_suspended` is the gate's state BEFORE the call that produced `action`,
/// so the only thing logged is a transition — a `skip` logged every 1.5 s for
/// the hours a panel sits minimized would be its own kind of waste.
pub fn applyGate(self: *ActivityMonitor, was_suspended: bool, action: sample_gate.Action) void {
    if (!was_suspended and self.gate.suspended) {
        // The probes go with it (T298/T290). N connections held open for the
        // hours a panel spends minimized is the same waste a per-tick process
        // enumeration is, and the two answers must agree — the only difference
        // is that a probe is re-established rather than merely resumed, which
        // costs one dial each on the way back.
        self.stopProbes();
        log.info(
            "activity monitor: sampling suspended source={s} probes=stopped",
            .{self.source.label()},
        );
    }
    switch (action) {
        .skip => {},
        .sample => kickSample(self),
        .resume_fresh => {
            // The rings are indexed by sample, not by time, so carrying them
            // across a suspension would draw however long the panel was away as
            // a single pixel — a chart lying about its own X axis. Clearing is
            // what a source switch already does (`switchSource`), and it is the
            // honest answer to "we have no data for that stretch".
            self.ring_len = 0;
            log.info(
                "activity monitor: sampling resumed source={s} trend=cleared",
                .{self.source.label()},
            );
            // Re-dial the probes the suspension stood down. They come back
            // `connecting` rather than resuming a reading, which is honest: we
            // have no idea what those machines did while nobody was looking.
            self.syncProbes();
            kickSample(self);
        },
    }
}

/// A poll tick: the gate decides whether it enumerates.
pub fn gateTick(self: *ActivityMonitor) void {
    const was = self.gate.suspended;
    applyGate(self, was, self.gate.onTick(visibility(self)));
}

/// The window says it is back in view. A no-op unless the gate is suspended,
/// which is what makes it safe from `WM_PAINT`.
pub fn gateShown(self: *ActivityMonitor) void {
    const was = self.gate.suspended;
    applyGate(self, was, self.gate.onShown(visibility(self)));
}

/// The window says it went away — suspend now rather than waiting up to a full
/// interval for the next tick to notice.
pub fn gateHidden(self: *ActivityMonitor) void {
    const was = self.gate.suspended;
    self.gate.onHidden();
    applyGate(self, was, .skip);
}

/// Start a background sample unless one is already running. Dropping a tick
/// rather than queueing one is deliberate: a machine slow enough to miss a tick
/// must not accumulate a backlog of enumerations.
pub fn kickSample(self: *ActivityMonitor) void {
    if (self.sampling) return;
    // Mid-dial there is nothing to sample, and keeping the worker out of the
    // way is what lets `adoptDial` publish `remote_conn` without a lock.
    if (self.dialing) return;
    if (self.worker) |t| {
        t.join();
        self.worker = null;
    }
    self.sampling = true;
    // The generation is captured HERE, on the GUI thread, so a switch that
    // happens while this worker runs can retire its result without racing it.
    self.worker = std.Thread.spawn(.{}, sampleWorker, .{ self, self.source_gen }) catch |err| {
        log.warn("activity monitor: sample thread spawn failed err={}", .{err});
        self.sampling = false;
        return;
    };
}

pub fn sampleWorker(self: *ActivityMonitor, gen: u32) void {
    const alloc = self.app.core_app.alloc;
    const snap = buildSnapshot(self, alloc) catch |err| {
        // A source that is not connected fails EVERY tick, and a panel can sit
        // open for hours — say it once. Only the worker touches this flag, and
        // the previous worker is joined before the next one starts.
        const spammy = err == error.RemoteSourceNotConnected;
        if (!spammy or !self.logged_sample_error) {
            log.warn("activity monitor: sample failed source={s} err={}", .{ self.source.label(), err });
        }
        // Only the always-fails case is silenced; a real sampling error stays
        // loud every time it happens.
        if (spammy) self.logged_sample_error = true;
        self.pending_mutex.lock();
        self.pending_failed = true;
        self.pending_gen = gen;
        self.pending_mutex.unlock();
        _ = w32.PostMessageW(self.hwnd, WM_APP_ACTIVITY_SAMPLE, 0, 0);
        return;
    };

    self.pending_mutex.lock();
    if (self.pending) |old| old.destroy(alloc);
    self.pending = snap;
    self.pending_failed = false;
    self.pending_gen = gen;
    self.pending_mutex.unlock();

    _ = w32.PostMessageW(self.hwnd, WM_APP_ACTIVITY_SAMPLE, 0, 0);
}

pub fn buildSnapshot(self: *ActivityMonitor, alloc: Allocator) !*Snapshot {
    if (self.source == .remote) {
        // No connection means the dial failed (or we are signed out). Sampling
        // THIS machine and captioning it with another machine's name would be a
        // lie the user has no way to catch, so the panel reports what is true:
        // it cannot reach that source (`paintEmptyState`'s "Couldn't connect").
        const rc = self.remote_conn orelse return error.RemoteSourceNotConnected;
        return buildRemoteSnapshot(self, alloc, rc.conn);
    }

    const snap = try alloc.create(Snapshot);
    errdefer alloc.destroy(snap);
    snap.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .rows = &.{},
        .host = .{},
        .truncated = false,
        .root_pid = selfPid(),
    };
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();

    snap.host = self.host_sampler.sample();

    if (self.proc_sampler == null) self.proc_sampler = remote_proc.ProcSampler.init(alloc);
    var procs: std.ArrayListUnmanaged(remote_protocol.Proc) = .empty;
    // The strings come from the arena, so there is nothing to free row by row —
    // retiring the snapshot retires them.
    snap.truncated = try self.proc_sampler.?.sample(arena, &procs, max_rows);

    const rows = try arena.alloc(rows_mod.Row, procs.items.len);
    for (procs.items, 0..) |p, i| {
        rows[i] = .{
            .pid = p.pid,
            .ppid = p.ppid,
            .cpu_pct = p.cpu_pct,
            .mem_bytes = p.mem_bytes,
            .name = p.name,
            .cmd = p.cmd orelse "",
        };
    }
    snap.rows = rows;
    return snap;
}

/// One poll against a REMOTE source, on the worker thread. Same shape as the
/// local path — one arena, strings copied into it — so adoption, retirement and
/// every consumer downstream cannot tell the two apart.
pub fn buildRemoteSnapshot(
    self: *ActivityMonitor,
    alloc: Allocator,
    conn: *remote_connection.Connection,
) !*Snapshot {
    var remote = try conn.requestProcSnapshot(null, max_rows, rpc_timeout_ns);
    defer remote.deinit();

    const snap = try alloc.create(Snapshot);
    errdefer alloc.destroy(snap);
    snap.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .rows = &.{},
        .host = remote.host,
        .truncated = remote.truncated,
        // The agent's own pid roots the "ghoztty-spawned" tree on THAT machine
        // (`PROC_SNAPSHOT.agent_pid`); ours is meaningless there. 0 from an
        // agent that predates the field, which the Show-all rule already
        // treats as "unknown".
        .root_pid = remote.agent_pid,
    };
    errdefer snap.arena.deinit();
    const arena = snap.arena.allocator();

    // Host CPU% comes from the pushed stream — the snapshot's is a one-shot
    // read with no baseline (see the header). Everything else in `host` is
    // instantaneous and already right.
    {
        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        if (self.last_metrics) |m| snap.host.cpu_pct = m.cpu_pct;
    }

    const rows = try arena.alloc(rows_mod.Row, remote.procs.len);
    for (remote.procs, 0..) |p, i| {
        rows[i] = .{
            .pid = p.pid,
            .ppid = p.ppid,
            .cpu_pct = p.cpu_pct,
            .mem_bytes = p.mem_bytes,
            .name = try arena.dupe(u8, p.name),
            .cmd = if (p.cmd) |c| try arena.dupe(u8, c) else "",
        };
    }
    snap.rows = rows;
    return snap;
}

pub fn selfPid() i64 {
    if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
        };
        return @intCast(k32.GetCurrentProcessId());
    }
    return 0;
}

/// GUI thread: adopt whatever the worker parked.
///
/// Runs during a modal dialog's nested pump like any other posted message
/// (T292), so the gauges and the table stay live behind the Kill confirmation.
/// What makes that safe is that the confirmation OWNS its target names by then
/// (`actions.copyNames`) rather than borrowing them from the snapshot this
/// retires.
pub fn adoptPending(self: *ActivityMonitor) void {
    self.sampling = false;

    self.pending_mutex.lock();
    const taken = self.pending;
    self.pending = null;
    const failed = self.pending_failed;
    self.pending_failed = false;
    const gen = self.pending_gen;
    self.pending_mutex.unlock();

    // A sample of the machine we just switched AWAY from. Adopting it would
    // paint one machine's processes under another's name — the same lie the
    // remote path refuses to tell when a dial has not landed.
    if (gen != self.source_gen) {
        if (taken) |s| s.destroy(self.app.core_app.alloc);
        return;
    }

    const snap = taken orelse {
        if (!failed) return;
        // A failure is an ANSWER: leaving `loading` set would sit on "Loading…"
        // forever while the overlay has "Couldn't connect" to say instead.
        self.refresh_failed = true;
        self.loading = false;
        _ = w32.InvalidateRect(self.hwnd, null, 0);
        return;
    };
    const alloc = self.app.core_app.alloc;
    if (self.snap) |old| old.destroy(alloc);
    self.snap = snap;
    self.loading = false;
    self.refresh_failed = false;

    // Prune before rebuilding: a selected process that exited must stop counting
    // toward the Kill button and its confirmation (Mac prunes on every `procs`
    // change, :1050-1056), and `rebuild` logs the count this produces.
    const before = self.sel_len;
    self.sel_len = actions.pruneSelection(&self.sel_pids, self.sel_len, snap.rows);

    pushSample(self, snap.host);
    self.rebuild();
    // The ACTIVE card's readout is this snapshot's host metrics, so the cards
    // are re-derived from the same data on the same tick.
    self.rebuildCards();
    if (self.sel_len != before) self.refreshChrome();
    _ = w32.InvalidateRect(self.hwnd, null, 0);
}

/// Append one point to both trend rings, dropping the oldest when full.
pub fn pushSample(self: *ActivityMonitor, host: remote_protocol.HostMetrics) void {
    const cpu = std.math.clamp(host.cpu_pct, 0, 100);
    const mem = gauge.memoryPercent(host.mem_used, host.mem_total);
    if (self.ring_len == gauge.ring_capacity) {
        std.mem.copyForwards(f32, self.cpu_ring[0 .. gauge.ring_capacity - 1], self.cpu_ring[1..]);
        std.mem.copyForwards(f32, self.mem_ring[0 .. gauge.ring_capacity - 1], self.mem_ring[1..]);
        self.cpu_ring[gauge.ring_capacity - 1] = cpu;
        self.mem_ring[gauge.ring_capacity - 1] = mem;
        return;
    }
    self.cpu_ring[self.ring_len] = cpu;
    self.mem_ring[self.ring_len] = mem;
    self.ring_len += 1;
}
