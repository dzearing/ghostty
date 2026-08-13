//! Live per-session CPU for the machine chooser's session rows (T462) — the
//! win32 half of Mac's `SessionCPUProbe.swift`, fed by the agent's pushed
//! `session_cpu` stream.
//!
//! ## Pushed, not polled
//! The client asks for a cadence; the AGENT decides one. It floors the request,
//! stretches it when its own machine is loaded, and reports what it actually
//! used in every frame (`Server.throttledIntervalMs`). A fixed client-side poll
//! would hit a box hardest exactly when it is already struggling, and the
//! chooser has no way to know how loaded the far end is — only the agent does.
//! So the reported interval is READ, never assumed: that is what keeps a slow
//! stream distinguishable from a dead one.
//!
//! ## One subscription at a time
//! The chooser is transient master-detail UI, so this follows the SELECTED
//! machine and nothing else: moving the selection tears the old subscription
//! down before starting the new one, and closing the chooser guarantees no
//! stream — and no borrowed connection — outlives the dialog.
//!
//! ## Whose connection
//! Never its own. The LOCAL agent's is `LocalAgent`'s warm shared connection
//! (borrowed; a roster browse must never SPAWN an agent, so no warm connection
//! simply means no meter), and a remote machine's is the one warm connection
//! `MachineConnectionPool` holds for the chooser's lease (T461). Dialing a
//! second socket just to draw a meter is exactly what the pool exists to stop.
//!
//! ## Degrading against an older agent
//! `Connection.subscribeSessionCpu` returns `error.Unsupported` when the peer
//! never advertised `capability.session_cpu` — an unknown opcode is a FATAL
//! framing error to an older agent, so the gate is what keeps a working
//! connection alive rather than politeness. Unsupported ⇒ `supported()` is
//! false ⇒ the roster reserves no column and draws no meter. Never a stale
//! number, never an invented one, and never a poll the agent did not agree to.
//!
//! `capability.cpu_units` needs no separate gate HERE: `session_cpu` was added
//! after the units fix and implies it (`protocol.zig`'s comment at
//! `capability.cpu_units`). The Activity Monitor's process table, whose
//! `cpu_pct` predates both, is what that capability exists for.

const SessionCpuProbe = @This();

const std = @import("std");

const chooser_cpu = @import("chooser_cpu.zig");
const remote_connection = @import("../../remote/connection.zig");
const remote_protocol = @import("../../remote/protocol.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Posted to the app's message-only window when a pushed frame landed:
/// `wparam` = the chooser id it belongs to. Integer payload, no allocation.
///
/// It lands on the MESSAGE-ONLY window and is routed by chooser id, exactly as
/// the roster's reply is, rather than being posted at the dialog: a chooser that
/// closed first would have the message discarded with its queue, and — worse —
/// a posted message aimed at a destroyed HWND whose value was recycled is a
/// message delivered to somebody else's window.
pub const WM_APP_CHOOSER_SESSION_CPU: u32 = w32.WM_APP + 29;

/// The cadence we ASK for. Modest on purpose, and Mac's number: this is a
/// glanceable indicator on a transient page, and the agent stretches it anyway
/// under load.
pub const requested_interval_ms: u32 = 2000;

/// The newest readings. Written from the control-reader thread, read from the
/// GUI thread; every access is behind its own mutex (`chooser_cpu.Store`).
store: chooser_cpu.Store = .{},

/// The connection the subscription is installed on, or null. BORROWED, always —
/// `LocalAgent` owns the local one for the app's lifetime and the pool owns a
/// machine's for as long as the chooser's lease lives, so this is never freed
/// here. It is nulled the moment either owner says the connection is going away.
conn: ?*remote_connection.Connection = null,

/// Whether the peer can serve the stream. Starts true — "we have not been told
/// otherwise" — and goes false on the first `error.Unsupported`, which is what
/// takes the column out of the row layout.
peer_supports: bool = true,

/// Where a pushed frame is announced, and who it belongs to.
///
/// Written once per subscribe and NEVER cleared — deliberately. The handler
/// reads both from the reader thread, so clearing them on `stop` would be a
/// plain unsynchronized write against a live read for no gain: the target is
/// the app's message-only window, which outlives every chooser, and a frame
/// that races a teardown posts a chooser id nothing matches and is dropped by
/// the routing. There is no stale HWND to deliver to somebody else's window,
/// which is the failure this shape exists to avoid.
hwnd: ?w32.HWND = null,
chooser_id: u64 = 0,

/// Whether the meter column should be reserved and drawn at all: a peer that can
/// serve the stream AND a live subscription on it. A dropped connection takes
/// the column away rather than freezing the last numbers on screen.
pub fn supported(self: *const SessionCpuProbe) bool {
    return self.peer_supports and self.conn != null;
}

/// This session's newest reading, or null when the last frame did not name it.
pub fn get(self: *SessionCpuProbe, id: []const u8) ?f32 {
    if (!self.supported()) return null;
    return self.store.get(id);
}

/// Point the probe at a connection — the selected machine's, or null for "no
/// machine, or one with nothing warm to ride". Idempotent: the same connection
/// twice keeps the live subscription and its readings instead of churning it.
///
/// Returns true when the meter's VISIBILITY changed, so the caller knows the row
/// layout moved and the region needs a repaint.
pub fn retarget(
    self: *SessionCpuProbe,
    hwnd: ?w32.HWND,
    chooser_id: u64,
    conn: ?*remote_connection.Connection,
) bool {
    if (self.conn == conn and conn != null) return false;

    const was = self.supported();
    self.stop();

    const c = conn orelse return was != self.supported();
    const h = hwnd orelse return was != self.supported();

    // Publish the identity BEFORE subscribing: the first frame can land the
    // instant the subscription is live, and the handler reads both.
    self.hwnd = h;
    self.chooser_id = chooser_id;
    c.subscribeSessionCpu(requested_interval_ms, self, onFrame) catch |err| {
        // `error.Unsupported` is an agent older than the capability, and it is
        // the common case rather than a failure: no meter, no noise beyond one
        // line saying which machine could not serve it.
        self.peer_supports = false;
        log.info("chooser cpu: no per-session CPU stream from this agent err={}", .{err});
        return was != self.supported();
    };
    self.conn = c;
    self.peer_supports = true;
    log.info("chooser cpu: subscribed interval_hint={d}ms", .{requested_interval_ms});
    return was != self.supported();
}

/// Drop the subscription and forget every reading. Safe when not subscribed, and
/// safe to call from teardown — which is where it MUST be called, before the
/// pool lease is released: the pool may free the connection the moment the last
/// lease goes, and a handler still registered on it would then fire into freed
/// memory.
pub fn stop(self: *SessionCpuProbe) void {
    if (self.conn) |c| c.unsubscribeSessionCpu();
    self.conn = null;
    // A reading is a statement about ONE agent: holding the last one across a
    // target change would put machine A's numbers on machine B's rows.
    self.store.reset();
    self.peer_supports = true;
}

/// The connection is going away (the pool's link died, or its lease is being
/// released) — forget it WITHOUT touching it. `stop` would write an unsubscribe
/// down a socket whose owner has already decided to free it; the pool notifies
/// its leases before the free precisely so this can happen first.
pub fn forget(self: *SessionCpuProbe) void {
    self.conn = null;
    self.store.reset();
    self.peer_supports = true;
}

/// Control-reader thread: one pushed frame. Copies the borrowed rows into the
/// store — they die the moment this returns — and posts, touching no GUI state
/// (`Connection.SessionCpuHandler`'s contract).
///
/// The log line is the acceptance oracle: an owner-drawn meter has no HWND to
/// read back, so what ARRIVED is said out loud, with the interval the agent
/// chose and the readings themselves. It is capped at a few rows because a log
/// line is not a data channel.
fn onFrame(
    ctx: *anyopaque,
    rows: []const remote_protocol.SessionCpuRow,
    interval_ms: u32,
) void {
    const self: *SessionCpuProbe = @ptrCast(@alignCast(ctx));

    var ids: [chooser_cpu.max_rows][]const u8 = undefined;
    var pcts: [chooser_cpu.max_rows]f32 = undefined;
    var n: usize = 0;
    for (rows) |r| {
        if (n >= ids.len) break;
        ids[n] = r.id;
        pcts[n] = r.cpu_pct;
        n += 1;
    }
    self.store.ingest(ids[0..n], pcts[0..n], interval_ms);

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    const shown = @min(n, 8);
    for (ids[0..shown], pcts[0..shown], 0..) |id, pct, i| {
        w.print("{s}{s}={d:.1}", .{ if (i == 0) "" else " ", id, pct }) catch break;
    }
    log.info("chooser cpu: frame rows={d} interval_ms={d} [{s}]", .{
        n,
        interval_ms,
        buf[0..fbs.pos],
    });

    if (self.hwnd) |h| {
        _ = w32.PostMessageW(h, WM_APP_CHOOSER_SESSION_CPU, @intCast(self.chooser_id), 0);
    }
}
