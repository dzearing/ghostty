//! Remote implements the `termio` backend for a pane whose child process lives
//! on a remote machine, reached over a `RemoteConnection` (`src/remote/`). It is
//! the remote counterpart to `Exec` (the local subprocess+pty backend) and
//! exposes the EXACT same method set `termio/backend.zig` dispatches to, but does
//! NOT own a pty or a subprocess. Instead:
//!
//!   - A shared `connection.Connection` (one per conn-key, supplied by the caller —
//!     the C-API/Surface wiring lands in increment 4b) owns the two SSH channels,
//!     the MPSC writer, and the demux reader.
//!   - This backend OPENs a new session (or ATTACHes an existing one by
//!     `session_id`) on the connection to obtain a `*connection.Pane`. The pane
//!     carries a per-channel inbound ring (`inbound_ring.Channel`, §3.4).
//!   - There is NO per-pane read thread: the connection's single demux thread reads
//!     the data channel and `pushTo`s each frame's bytes into the target pane's
//!     ring, then wakes the pane's IO thread via a `Waker`. This backend backs that
//!     `Waker` with an `xev.Async` registered on the pane's OWN IO thread/loop
//!     (`Thread.zig` / `Termio.ThreadData.loop`); the async callback drains the
//!     ring and calls `Termio.processOutput` ON THIS PANE'S THREAD — the same call
//!     Exec's `ReadThread` makes — restoring per-pane parallelism with no cross-pane
//!     head-of-line blocking.
//!   - Input (`queueWrite`) is MPSC-enqueued as `DATA` via `connection.writeInput`
//!     (the pane owns its outbound byte offset). `resize` sends a `RESIZE` control
//!     frame. Teardown `DETACH`es (keep-alive) by default, NOT `CLOSE`.
//!
//! See design §3.1 (the union seam), §3.3 (the per-method behavior map this
//! mirrors), and §3.4 (thread topology, the inbound-ring mini-spec, and the
//! use-after-free teardown invariant).
//!
//! INCREMENT 4a SCOPE: this makes libghostty COMPILE with a structurally faithful
//! `.remote` arm wired to the already-built connection. The deepest `xev.Async`
//! drain wiring is implemented; a few agent-metadata refinements are marked
//! `// TODO(wp3)` where the protocol surface for them lands in a later increment.
const Remote = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const connection = @import("../remote/connection.zig");
const inbound_ring = @import("../remote/inbound_ring.zig");
const protocol = @import("../remote/protocol.zig");

const log = std.log.scoped(.io_remote);

/// The connection this pane rides on. Owned by the caller (the C-API/Surface
/// layer, increment 4b); shared across panes that target the same conn-key.
/// Never freed by this backend.
conn: *connection.Connection,

/// The agent session to ATTACH to, or null to OPEN a brand-new session. Duped
/// into `arena` so it is stable for this backend's lifetime.
session_id: ?[]const u8,

/// The command to run for an open-new session (null ⇒ the remote default shell).
/// Sent verbatim in the `OPEN` payload (§4.2). Duped into `arena`.
command: ?[]const u8,

/// The working directory hint for an open-new session and the terminal's initial
/// pwd. Duped into `arena`.
working_directory: ?[]const u8,

/// The TERM value advertised in `OPEN` (§4.2). Duped into `arena`.
term: []const u8,

/// Current grid/screen size, seeded by `initTerminal` and updated by `resize`.
/// Sent in `OPEN`/`RESIZE` (rows/cols + pixel geometry, §6.5).
grid_size: renderer.GridSize = .{},
screen_size: renderer.ScreenSize = .{ .width = 1, .height = 1 },

/// Cached exit code from an `EXIT` frame, surfaced by `childExitedAbnormally`.
/// Null until the agent reports the session exited.
exit_code: ?u32 = null,

/// Owns the duped config strings for this backend's lifetime.
arena: std.heap.ArenaAllocator,

/// The LIVE agent session id, published once `threadEnter` resolves the pane
/// (OPEN-new learns it from the agent's OPENED; ATTACH already knows it). Stored
/// here on the STABLE backend (`Termio.backend.remote`) so the GUI thread can
/// read it cross-thread for an on-demand cwd query (§WP4). It points into the IO
/// thread's `pane.session_id` (stable for the pane's lifetime). Published/cleared
/// with release/acquire ordering; readers must treat the slice as borrowed and
/// only valid while the pane is alive (the GUI reads it synchronously to issue a
/// query right after, well before any teardown).
live_session_id: std.atomic.Value(?[*]const u8) = .init(null),
live_session_id_len: std.atomic.Value(usize) = .init(0),

/// Configuration for a remote backend. Mirrors the subset of `Exec.Config` that
/// makes sense for a remote pane: there is no env/shell-integration/resources-dir
/// machinery here (that all lives on the agent side), but the connection handle
/// and the open-vs-attach decision are remote-specific.
///
/// The `conn` handle is supplied by the caller; increment 4b wires the C API /
/// `Surface` construction that actually resolves a connection for a conn-key and
/// populates this. For now nothing constructs a `.remote` Config — the milestone
/// is a complete, compiling union arm.
pub const Config = struct {
    /// The shared connection to ride on (caller-owned). Required.
    conn: *connection.Connection,

    /// Non-null ⇒ ATTACH to this existing agent session; null ⇒ OPEN a new one.
    session_id: ?[]const u8 = null,

    /// Command for an open-new session (null ⇒ remote default shell). Wire `OPEN`.
    command: ?[]const u8 = null,

    /// Working directory hint + the terminal's initial pwd.
    working_directory: ?[]const u8 = null,

    /// TERM value advertised to the agent.
    term: []const u8 = "xterm-ghostty",
};

/// Initialize the remote backend state. Like `Exec.init`, this does NOT touch the
/// wire — it only records what `threadEnter` will need. It does NOT open/attach a
/// channel (that happens on the IO thread in `threadEnter`).
pub fn init(alloc: Allocator, cfg: Config) !Remote {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const session_id = if (cfg.session_id) |s| try aa.dupe(u8, s) else null;
    const command = if (cfg.command) |c| try aa.dupe(u8, c) else null;
    const working_directory = if (cfg.working_directory) |w| try aa.dupe(u8, w) else null;
    const term = try aa.dupe(u8, cfg.term);

    return .{
        .conn = cfg.conn,
        .session_id = session_id,
        .command = command,
        .working_directory = working_directory,
        .term = term,
        .arena = arena,
    };
}

pub fn deinit(self: *Remote) void {
    self.arena.deinit();
    self.* = undefined;
}

/// The LIVE agent session id for this backend, or null if no pane is currently
/// resolved (pre-`threadEnter` or post-`threadExit`). Lock-free; safe to call
/// from any thread. The returned slice borrows the pane's `session_id` and is
/// only valid while the pane is alive — callers use it synchronously (e.g. to
/// issue a cwd query) and must not retain it. (§WP4)
pub fn liveSessionId(self: *const Remote) ?[]const u8 {
    const ptr = self.live_session_id.load(.acquire) orelse return null;
    const len = self.live_session_id_len.load(.acquire);
    if (len == 0) return null;
    return ptr[0..len];
}

/// The command this remote pane was OPENed with, or null if it uses the agent's
/// default shell. Immutable after `init` (duped into `arena` and never mutated),
/// so it is safe to read from any thread. The returned slice borrows the
/// backend's arena and is only valid while the backend is alive — callers use it
/// synchronously (e.g. to seed a new window's command) and must not retain it.
/// Used so a new window/tab/split inherits the parent remote frame's command
/// (§WP4): if the parent ran an explicit command we re-run it; if it used the
/// default shell (null) the new frame also uses the default shell.
pub fn remoteCommand(self: *const Remote) ?[]const u8 {
    const cmd = self.command orelse return null;
    if (cmd.len == 0) return null;
    return cmd;
}

/// Initialize the terminal state for this backend (mirrors `Exec.initTerminal`):
/// set the initial pwd if we have a working-directory hint and seed the grid /
/// screen size from the terminal. The pwd is otherwise resolved lazily from the
/// remote child's OSC 7 (§3.3).
pub fn initTerminal(self: *Remote, t: *terminal.Terminal) void {
    if (self.working_directory) |cwd| t.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };

    // Seed our grid/screen size from the terminal. This can't fail because we
    // haven't opened a channel yet (null `td`), so `resize` only records the
    // sizes; `threadEnter` sends them in `OPEN`.
    self.resize(null, .{
        .columns = t.cols,
        .rows = t.rows,
    }, .{
        .width = t.width_px,
        .height = t.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Remote,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Open a new session or attach to an existing one to obtain our pane.
    const pane: *connection.Pane = if (self.session_id) |sid| pane: {
        // ATTACH: re-attach to an existing agent session (§3.3 / §7.3).
        var outcome = try self.conn.attachChannel(
            sid,
            @intCast(@min(self.grid_size.rows, std.math.maxInt(u16))),
            @intCast(@min(self.grid_size.columns, std.math.maxInt(u16))),
            // We have no locally-applied byte offset yet (fresh attach from a new
            // GUI process); the agent snapshots from its current head (§7.3).
            0,
            false,
        );
        errdefer outcome.deinit();
        const p = outcome.pane orelse {
            // .dead / .not_found / attached_elsewhere(!force): nothing registered.
            // The caller (4b) decides recovery tier (§7.4); for now this is fatal
            // to the pane bring-up.
            outcome.deinit();
            log.warn(
                "attach did not yield a live pane status={} attached_elsewhere={}",
                .{ outcome.status, outcome.attached_elsewhere },
            );
            return error.RemoteAttachFailed;
        };
        outcome.deinit();
        break :pane p;
    } else pane: {
        // OPEN-new: start a brand-new remote session (§3.3 open-new).
        const open: protocol.Open = .{
            .command = self.command,
            .cwd = self.working_directory,
            .term = self.term,
            .rows = @intCast(@min(self.grid_size.rows, std.math.maxInt(u16))),
            .cols = @intCast(@min(self.grid_size.columns, std.math.maxInt(u16))),
            .px_w = @intCast(@min(self.screen_size.width, std.math.maxInt(u16))),
            .px_h = @intCast(@min(self.screen_size.height, std.math.maxInt(u16))),
        };
        break :pane try self.conn.openChannel(open);
    };
    // On any failure after this point we DETACH the pane (keep-alive teardown,
    // §3.3) so the remote session survives for a later re-attach.
    errdefer self.conn.detachChannel(pane);

    // Publish the resolved live session id on the STABLE backend so the GUI thread
    // can read it for an on-demand cwd query (§WP4). `pane.session_id` is stable
    // for the pane's lifetime; we publish the pointer + len with release ordering
    // (the len last so a reader that sees a non-null ptr also sees the right len).
    const sid = pane.session_id;
    if (sid.len > 0) {
        self.live_session_id.store(sid.ptr, .release);
        self.live_session_id_len.store(sid.len, .release);
    }

    // The async handle the demux thread notifies to wake THIS pane's IO thread.
    // It is registered on this thread's xev loop; its callback drains the ring.
    var ring_async = try xev.Async.init();
    errdefer ring_async.deinit();

    // Publish our thread-data backend state FIRST so the waker/callback ctx point
    // at the final, stable location (inside `td.backend.remote`).
    td.backend = .{ .remote = .{
        .conn = self.conn,
        .pane = pane,
        .io = io,
        .ring_async = ring_async,
    } };
    const rd = &td.backend.remote;

    // Point the pane's inbound ring at our async so the demux thread's
    // `Channel.push` wakes this thread. The pane (and its ring) were created with
    // a no-op waker by `openChannel`/`attachChannel`; we swap in ours now, before
    // any drain happens. Safe because the demux thread only ever reads the waker
    // under the channel-table lock during a push, and we have not yet begun
    // draining.
    pane.ring.waker = .{ .ctx = rd, .wakeFn = wakeFromDemux };

    // Arm the async wait: every notify drains the ring on this thread.
    rd.ring_async.wait(
        td.loop,
        &rd.ring_async_c,
        termio.Termio.ThreadData,
        td,
        ringReady,
    );

    // Drain once immediately in case DATA landed in the ring between registration
    // and arming the wait (the agent may stream a snapshot right after OPENED).
    drainRing(td);
}

pub fn threadExit(self: *Remote, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .remote);
    const rd = &td.backend.remote;

    // §3.4 teardown order (use-after-free guard): this IS the consumer thread, and
    // by the time `threadExit` runs the xev loop has stopped, so no further
    // `drainRing`/`ringReady` will run — the consumer has stopped draining. We may
    // now DETACH, which deregisters the channel under the connection's table lock
    // (after which no in-flight demux `pushTo` can touch the ring) and frees the
    // ring + pane. DETACH keeps the remote session alive for a later re-attach
    // (NOT CLOSE — a `+close` would route through a different path, §3.3).
    // Un-publish the live session id BEFORE the pane (and its `session_id`
    // backing) is freed by detach, so the GUI thread never reads a dangling
    // slice. Clear the len first, then the ptr (mirror of the publish order).
    self.live_session_id_len.store(0, .release);
    self.live_session_id.store(null, .release);

    self.conn.detachChannel(rd.pane);
    rd.pane = undefined;
}

pub fn focusGained(
    self: *Remote,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // §3.3: focus is "forwarded as DATA if enabled". The local terminal already
    // emits the focus-event escape (DECSET 1004) as normal output through
    // `queueWrite` when the remote child enables it, so there is nothing
    // backend-specific to forward here for the common path.
    // TODO(wp3): explicit focus-tracking forwarding if/when the agent opts in.
}

/// Resize the remote pane. Mirrors `Exec.resize`, which forwards the new geometry
/// to the local pty via `TIOCSWINSZ`; here we forward it to the agent's remote pty
/// via a `RESIZE` control frame.
///
/// `td` is null ONLY for the `initTerminal` seed call (before any channel exists):
/// then we just record the size, which `threadEnter` sends in `OPEN`. For every
/// live resize the IO thread passes its `ThreadData` (which owns the pane handle),
/// and we send the wire `RESIZE` so the remote shell is told its new window size
/// and repaints. Without this, a surface that starts at 0x0 (the GUI: the Cocoa
/// SurfaceView lays out AFTER `ghostty_surface_new`) would OPEN a 0x0 remote pty
/// and the resize that follows would never reach the agent — the remote shell
/// stays 0x0 and never paints, so the window renders BLANK (WP4 bug).
pub fn resize(
    self: *Remote,
    td: ?*termio.Termio.ThreadData,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;

    // No channel yet (the `initTerminal` seed): just record; `OPEN` carries it.
    const td_live = td orelse return;
    assert(td_live.backend == .remote);
    const rd = &td_live.backend.remote;
    rd.conn.sendResize(
        rd.pane,
        @intCast(@min(grid_size.rows, std.math.maxInt(u16))),
        @intCast(@min(grid_size.columns, std.math.maxInt(u16))),
        @intCast(@min(screen_size.width, std.math.maxInt(u16))),
        @intCast(@min(screen_size.height, std.math.maxInt(u16))),
    ) catch |err| log.warn("error sending RESIZE err={}", .{err});
}

pub fn queueWrite(
    self: *Remote,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc;
    assert(td.backend == .remote);
    const rd = &td.backend.remote;

    // If the agent reported the session exited we stop sending input.
    if (rd.exited) return;

    if (!linefeed) {
        // Fast path: enqueue the bytes as a single DATA frame (§3.4). The pane
        // owns its outbound byte offset; the connection's MPSC writer owns the
        // socket.
        try rd.conn.writeInput(rd.pane, data);
        return;
    }

    // Slow path: translate bare `\r` into `\r\n` (matches Exec's linefeed mode)
    // before framing. We chunk through a small stack buffer to bound the temp.
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) {
        var buf_i: usize = 0;
        while (i < data.len and buf_i < buf.len - 1) {
            const ch = data[i];
            i += 1;
            if (ch != '\r') {
                buf[buf_i] = ch;
                buf_i += 1;
                continue;
            }
            buf[buf_i] = '\r';
            buf[buf_i + 1] = '\n';
            buf_i += 2;
        }
        try rd.conn.writeInput(rd.pane, buf[0..buf_i]);
    }
}

pub fn childExitedAbnormally(
    self: *Remote,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    // §3.3: overlay from an `EXIT{code}`. The remote has no local `subprocess.args`
    // to render a command line into the overlay text, so increment 4a logs the
    // exit; the exit-diagnostics overlay text is wired when the agent surfaces the
    // remote command (a later increment).
    // TODO(wp3): render the remote command + a richer overlay from agent metadata.
    log.warn(
        "remote child exited abnormally code={} runtime={}ms",
        .{ exit_code, runtime_ms },
    );
}

pub fn getProcessInfo(self: *Remote, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    // §3.3: "cached agent metadata or null". The agent reports pid/tty/foreground
    // info via `META`/`OPENED` frames; until that metadata is plumbed through to
    // the backend (a later increment) we return null, which all callers handle.
    // TODO(wp3): return cached foreground pid from agent metadata.
    return null;
}

// -----------------------------------------------------------------------------
// Inbound ring drain path (the read side, §3.4)
// -----------------------------------------------------------------------------

/// Waker callback invoked by the connection's demux thread after it pushes DATA
/// into this pane's ring (`inbound_ring.Channel.push`). It MUST be cheap and
/// non-blocking — it only notifies our async handle, which schedules `ringReady`
/// to run on THIS pane's IO thread. `ctx` is the `ThreadData.remote` for this
/// pane (a stable pointer for the thread's life).
fn wakeFromDemux(ctx: *anyopaque) void {
    const rd: *ThreadData = @ptrCast(@alignCast(ctx));
    rd.ring_async.notify() catch |err|
        log.warn("error notifying ring async err={}", .{err});
}

/// xev callback: the demux thread woke us because bytes landed in the ring. Drain
/// the whole ring and feed `processOutput` on this thread (the same call Exec's
/// `ReadThread` makes, self-locking the renderer mutex). Re-arm to keep waiting.
fn ringReady(
    td_: ?*termio.Termio.ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in ring async wait err={}", .{err});
        return .rearm;
    };
    const td = td_ orelse return .rearm;
    drainRing(td);
    return .rearm;
}

/// Drain the pane's inbound ring fully into the terminal. Called on the pane's IO
/// thread (from `ringReady` or once eagerly in `threadEnter`). For each chunk:
///   1. pop from the ring (SPSC consumer side),
///   2. `processOutput` (parses + renders, self-locks the renderer mutex),
///   3. on the paused→flowing low-water edge, emit `FLOW{resume}` so the agent
///      resumes draining that session's PTY (§3.4 consumer-side flow control).
fn drainRing(td: *termio.Termio.ThreadData) void {
    assert(td.backend == .remote);
    const rd = &td.backend.remote;
    const ch = rd.pane.ring;

    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const res = ch.pop(&buf);
        if (res.read == 0) break;

        @call(.always_inline, termio.Termio.processOutput, .{ rd.io, buf[0..res.read] });

        if (res.send_resume) rd.conn.sendFlowResume(ch.id) catch |err|
            log.warn("error sending FLOW resume err={}", .{err});
    }
}

/// The thread-local data for the remote backend. Lives inside
/// `termio.Termio.ThreadData.backend` (a stable location for the IO thread's
/// life), so the demux waker and the xev callbacks can hold a `*ThreadData`.
pub const ThreadData = struct {
    /// The shared connection (caller-owned; not freed here).
    conn: *connection.Connection,

    /// Our pane handle on the connection. Owned by the connection; freed by
    /// `detachChannel`/`closeChannel` in `threadExit`. Set to `undefined` after
    /// teardown.
    pane: *connection.Pane,

    /// Back-reference to the Termio so the drain path can call `processOutput`.
    io: *termio.Termio,

    /// The async handle the demux thread notifies to wake this thread's drain.
    ring_async: xev.Async,
    ring_async_c: xev.Completion = .{},

    /// Set true once the agent reports the session exited (stops further input).
    exited: bool = false,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = alloc;
        // The pane/ring were already torn down by `threadExit` (`detachChannel`).
        // The connection is caller-owned. We only own the async handle here.
        self.ring_async.deinit();
        self.* = undefined;
    }
};

