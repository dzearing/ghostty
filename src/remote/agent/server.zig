//! Agent session-server core (WP2, increment 1) — the remote-host side of the
//! remote-machines wire protocol. It is the **symmetric peer** of the client
//! `src/remote/connection.zig`: where the client opens/attaches and renders, the
//! agent spawns/owns the child processes and streams their output back.
//!
//! Scope of THIS increment (§4.1–4.2 bootstrap/handshake, §7.1 session model):
//!
//!   - Read the client HELLO on control, reply with the agent HELLO echoing the
//!     pinned `transfer_encoding`, confirm via `protocol.negotiate` (§4.2).
//!   - A serialized MPSC writer thread that frames via `protocol.writeFrame` onto
//!     the correct channel (control vs data), assigning the per-connection
//!     `FrameSeq` at send time so seq order == wire order (mirrors the client).
//!   - A control reader thread that handshakes then dispatches every inbound
//!     control frame, and a data reader thread that routes inbound DATA to the
//!     owning session's child (keystrokes).
//!   - Frame handling: OPEN→OPENED + live DATA streaming; client DATA→child;
//!     ATTACH (alive/dead/not_found) with a byte-offset-anchored snapshot;
//!     RESIZE/SIGNAL/DETACH/CLOSE; EXIT-after-final-DATA on child exit; PING→PONG;
//!     FLOW pause/resume gating.
//!
//! Untrusted input (§15 M3): `protocol.Reader` bounds every frame; we additionally
//! validate session/channel **ownership** (an inbound channel must belong to a
//! session this connection opened) — unknown ids/channels are ignored, never a
//! crash.
//!
//! ## Stubbed vs real (increment 1)
//!
//!   - **Transport** (`Stream`): abstract vtable; tests drive it over an in-memory
//!     loopback. Real impl wraps the two ssh-channel pipe fds — out of scope.
//!   - **Child**: abstract (`session.Child`); the real pty/ConPTY impl is
//!     `pty_child.zig` (wired in `main.zig`), while tests inject a fake,
//!     pipe/buffer-backed child.
//!   - **Snapshot**: `ATTACHED.snapshot_at_offset` is the session's current
//!     outbound offset `S`; reconnect replays the ring forward from there. A true
//!     grid-model snapshot at `S` (§7.3), so ring eviction is invisible, is
//!     future work.
//!   - RPC, tunnels: out of scope.
//!
//! ## Driving it (test harness pattern)
//!
//!   var server = try Server.create(alloc, control_stream, data_stream, .{...});
//!   try server.start();                 // spawns writer + 2 readers
//!   _ = try server.waitHandshake();     // blocks until HELLOs exchanged
//!   ... a mock client drives frames over the loopback ...
//!   server.shutdown();                  // unblocks + joins all threads
//!   server.destroy(alloc);
//!
//! ## Running the tests
//!
//! These modules import `../protocol.zig` relatively (the same path the real
//! `zig build agent` graph uses). A `zig test` rooted at this file's directory
//! can't reach `../protocol.zig` ("import outside module path"), so root the test
//! one level up via the aggregator `src/remote/agent_test.zig`:
//!
//!   zig test -Mroot=src/remote/agent_test.zig
//!
//! The real build wires the agent exe via `build.zig` (`zig build agent`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const protocol = @import("../protocol.zig");
const session = @import("session.zig");
const metrics = @import("metrics.zig");
const proc = @import("proc.zig");
const descendants = @import("descendants.zig");
const proc_control = @import("proc_control.zig");

/// Scratch read buffer per reader thread's blocking `Stream.read`.
const read_buf_size = 64 * 1024;

// -----------------------------------------------------------------------------
// Stream — an abstract bidirectional byte stream for ONE ssh channel
// -----------------------------------------------------------------------------

/// A blocking, bidirectional byte stream abstracting one ssh channel. Identical in
/// shape to the client's `connection.Stream` (the agent is the symmetric peer) but
/// defined here so the agent module is self-contained (depends only on `protocol`).
///
/// Threading: one reader thread calls `read` and the single writer thread calls
/// `writeAll` per stream, so an impl need not make `read`/`write` mutually
/// thread-safe — only `close` must be safe to call concurrently with a blocked
/// `read` (it unblocks it) and idempotent.
pub const Stream = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Blocking read of up to `buf.len` bytes; returns the count. `0` ⇒ EOF.
        read: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        /// Write some of `bytes`; returns count written (writeAll loops).
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        /// Unblock any pending `read` and mark EOF. Idempotent, concurrency-safe.
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn read(self: Stream, buf: []u8) anyerror!usize {
        return self.vtable.read(self.ctx, buf);
    }

    pub fn writeAll(self: Stream, bytes: []const u8) anyerror!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try self.vtable.write(self.ctx, bytes[off..]);
            if (n == 0) return error.WriteZero;
            off += n;
        }
    }

    pub fn close(self: Stream) void {
        self.vtable.close(self.ctx);
    }
};

// -----------------------------------------------------------------------------
// Clock — injectable monotonic-ms source (deterministic in tests)
// -----------------------------------------------------------------------------

/// A millisecond clock. The real agent uses the wall clock; tests inject a fixed
/// one so timestamps/runtime are deterministic.
pub const Clock = struct {
    ctx: *anyopaque,
    nowFn: *const fn (ctx: *anyopaque) i64,

    pub fn now(self: Clock) i64 {
        return self.nowFn(self.ctx);
    }

    fn realNow(_: *anyopaque) i64 {
        return std.time.milliTimestamp();
    }

    /// A wall-clock implementation.
    pub fn real() Clock {
        return .{ .ctx = undefined, .nowFn = realNow };
    }
};

// -----------------------------------------------------------------------------
// Spawner — how the agent turns an OPEN into a Child (injectable)
// -----------------------------------------------------------------------------

/// Spawns a child for an `OPEN` request. The real spawner (`pty_child.zig`) forks
/// a process on a pty/ConPTY and returns a pid + a `Child` whose output-reader
/// thread calls the session's sink; tests inject a fake spawner that hands back a
/// buffer-backed `FakeChild`.
///
/// The returned `Result.child` must remain valid until the session's child is
/// `terminate()`d. The spawner owns any backing storage and frees it on terminate.
pub const Spawner = struct {
    ctx: *anyopaque,
    spawnFn: *const fn (ctx: *anyopaque, open: protocol.Open) anyerror!Result,
    /// Launch a DETACHED process (no session/pty) for `PROC_SPAWN` (§9.3, inc 5).
    /// Injected (rather than imported by `server.zig`) so `server.zig`'s transport
    /// graph stays free of `CommandCore` — see `proc_spawn.zig`'s module doc. The
    /// real agent wires `pty_child.PtySpawner.spawnDetachedTrampoline`.
    spawnDetachedFn: *const fn (ctx: *anyopaque, cmd: []const u8, cwd: ?[]const u8) SpawnResult,

    pub const Result = struct {
        child: session.Child,
        pid: i64,
        /// The child's PTY slave path (wp3), or null when unavailable (Windows
        /// ConPTY, or the tty-name query failed). BORROWS storage owned by the
        /// child (stable until `terminate`); consumers must copy before any
        /// window where the child could be torn down.
        tty: ?[]const u8 = null,

        /// Set when this session's ConPTY lives in a separate `--pty-host`
        /// HOLDER process (T905) instead of in the agent — the arrangement that
        /// lets a shell outlive its agent. Null for the in-process child, which
        /// is still the default. Same borrow rule as `tty`: valid until
        /// `terminate`, so the store copies it on the spot.
        holder: ?Holder = null,
    };

    /// The durable handle on a holder-backed session's owner process. Declared
    /// here rather than imported from `pty_holder_child.zig` for the same reason
    /// `SpawnResult` is: `server.zig`'s transport graph stays free of the
    /// spawning machinery.
    pub const Holder = struct {
        /// Full `\\.\pipe\...` control-pipe path.
        pipe: []const u8,
        /// The holder process's OS pid.
        pid: u32,
        /// The holder binary's build stamp.
        stamp: []const u8,
    };

    /// Result of a detached spawn (mirrors `proc_spawn.SpawnOutcome` but defined
    /// here so `server.zig` needn't import `proc_spawn.zig`). `@"error"` is usually a
    /// static string, but when `free_error` is true it was allocated from the
    /// agent's allocator (the Windows diagnostic note) and `handleProcSpawn` frees it
    /// after encoding the reply.
    pub const SpawnResult = struct {
        ok: bool = false,
        pid: ?i64 = null,
        @"error": ?[]const u8 = null,
        free_error: bool = false,
    };

    pub fn spawn(self: Spawner, open: protocol.Open) anyerror!Result {
        return self.spawnFn(self.ctx, open);
    }

    pub fn spawnDetached(self: Spawner, cmd: []const u8, cwd: ?[]const u8) SpawnResult {
        return self.spawnDetachedFn(self.ctx, cmd, cwd);
    }
};

// -----------------------------------------------------------------------------
// Outbound queue (MPSC → single writer thread), mirroring the client
// -----------------------------------------------------------------------------

/// Which ssh channel a queued frame is destined for.
const StreamId = enum { control, data };

/// One queued outbound frame; the writer owns `payload` (a private heap copy) and
/// frees it after emit.
const OutFrame = struct {
    stream: StreamId,
    ftype: protocol.FrameType,
    channel: u128,
    payload: []u8,
};

// -----------------------------------------------------------------------------
// Server
// -----------------------------------------------------------------------------

/// The agent's per-connection server: owns the two streams, the writer thread, and
/// the reader threads, and BRIDGES frames to/from a SHARED, daemon-scoped
/// `SessionStore` (the table + lock + children outlive this Server, so sessions
/// survive a client disconnect — §7.1 close-laptop). One `Server` per accepted
/// connection. Heap-allocated (`create`) so its address is stable for the threads.
pub const Server = struct {
    alloc: Allocator,
    control: Stream,
    data: Stream,
    encoding: protocol.TransferEncoding,
    local_hello: protocol.Hello,
    clock: Clock,
    spawner: Spawner,

    /// DAEMON-scoped session registry (§7.1 survival). SHARED across connections —
    /// owned by the daemon (`main.zig`), NOT by this per-connection Server, so
    /// sessions outlive a client disconnect (the close-laptop scenario). All table
    /// access goes through `store.mutex`. The previous design owned a per-connection
    /// `SessionTable`+mutex here; lifting it to the store is what makes reconnect
    /// catch-up possible.
    store: *session.SessionStore,
    /// Channels this connection currently has bound (so disconnect can DETACH just
    /// its own sessions, leaving others — future multi-client — untouched). Guarded
    /// by `store.mutex`.
    bound_channels: std.ArrayList(u128) = .empty,

    /// Outbound MPSC queue + the single writer thread (§3.4).
    write_mutex: std.Thread.Mutex = .{},
    write_cond: std.Thread.Condition = .{},
    write_queue: std.ArrayList(OutFrame) = .empty,
    frame_seq: protocol.FrameSeq = .{},

    /// Handshake completion gate + result.
    handshake_done: std.Thread.ResetEvent = .{},
    negotiated: anyerror!protocol.Negotiated = error.Incompatible,

    started: bool = false,
    closed: bool = false,

    writer_thread: ?std.Thread = null,
    control_thread: ?std.Thread = null,
    data_thread: ?std.Thread = null,

    /// Latched true by `shutdown()` BEFORE it stops the pumps, and read by every
    /// `*_sub` handler while holding that pump's mutex. Without it, a `*_sub`
    /// arriving on the control reader thread can spawn a pump AFTER shutdown has
    /// already taken the handle — the pump then outlives the Server and writes
    /// into freed memory forever (T442: the corruption that made the agent test
    /// binary segfault in whatever ran next, usually an unrelated terminal test).
    /// Atomic rather than mutex-guarded because the three pumps have three
    /// different mutexes and one flag has to be visible under all of them.
    pumps_closed: std.atomic.Value(bool) = .init(false),

    /// Host-metrics push pump (§9.3). A per-connection thread, lazily spawned on the
    /// first `metrics_sub` and torn down on `metrics_unsub` or shutdown. It samples
    /// the host every `metrics_interval_ms` and pushes a `metrics` frame on the
    /// control channel. Its own mutex/cond gate a timed wait so a stop request wakes
    /// it promptly (rather than sleeping out the full interval). MUST NOT outlive the
    /// Server — joined in `shutdown()`, asserted null in `destroy()` (UAF discipline).
    metrics_thread: ?std.Thread = null,
    metrics_mutex: std.Thread.Mutex = .{},
    metrics_cond: std.Thread.Condition = .{},
    metrics_interval_ms: u32 = 0, // 0 ⇒ unsubscribed
    metrics_stop: bool = false,

    /// Per-session CPU push pump (`session_cpu`). Same shape and same lifetime
    /// discipline as the metrics pump above: a per-connection thread, lazily
    /// spawned on the first `session_cpu_sub`, torn down on unsub or shutdown,
    /// joined before the Server dies. Separate from the metrics pump because the
    /// two run at different cadences and this one throttles itself under load.
    session_cpu_thread: ?std.Thread = null,
    session_cpu_mutex: std.Thread.Mutex = .{},
    session_cpu_cond: std.Thread.Condition = .{},
    session_cpu_interval_ms: u32 = 0, // 0 ⇒ unsubscribed
    session_cpu_stop: bool = false,
    /// Identity of the CURRENT pump. Bumped on every start and every stop, and
    /// checked by the pump each iteration, so a predecessor always terminates
    /// even when a re-subscribe resets `session_cpu_stop` before it woke up.
    /// Guarded by `session_cpu_mutex`, like every field above it.
    session_cpu_generation: u64 = 0,

    /// True while this connection has subscribed to the pushed session roster
    /// (`sessions_sub`). Plain bool, no pump: the roster is EVENT-driven — the
    /// agent pushes when it changes, not on a clock — so there is nothing to
    /// time and nothing to tear down but the flag.
    sessions_push: bool = false,

    /// Roster push pump. Unlike the metrics/session-cpu pumps this has no
    /// interval — it sleeps until something actually changes the roster.
    roster_thread: ?std.Thread = null,
    roster_mutex: std.Thread.Mutex = .{},
    roster_cond: std.Thread.Condition = .{},
    roster_dirty: bool = false,
    roster_stop: bool = false,

    /// Process-table sampler for `proc_list` (§9.3 process view). Unlike the metrics
    /// pump it needs no thread: `proc_list` is request/reply, sampled synchronously on
    /// the control reader. It holds per-pid CPU baselines across calls so a repeated
    /// `proc_list` yields real per-process CPU% (the first call on a pid reads 0).
    /// Owned by the Server; init in `create`, freed in `destroy`.
    proc_sampler: proc.ProcSampler = undefined,

    /// Per-session ring size (from Options), read by `create`'s table inserts.
    ring_bytes: usize = session.default_ring_bytes,

    /// Backing storage for `local_hello.capabilities` — `Options.capabilities`
    /// minus the suppression set (see `suppressCapabilities`).
    advertised_caps: [max_advertised_caps][]const u8 = undefined,

    /// Capability strings this agent will NOT advertise, however `Options` lists
    /// them — a comma-separated set copied here once at startup.
    ///
    /// A TEST SEAM (T469), and the reason it earns its place: the agent contract
    /// says every capability must degrade gracefully in BOTH skew directions,
    /// and until now that could only be checked in unit tests, because a single
    /// tree builds both peers from the same capability list. There was no way to
    /// produce an OLD agent on a box short of keeping an old binary around. This
    /// turns any capability off at the source, so an acceptance script can watch
    /// the real fallback happen against the real app.
    ///
    /// Set-once from `GHOSTTY_AGENT_SUPPRESS_CAPS` before any connection exists,
    /// read-only afterwards → no synchronization. An env var rather than a flag
    /// because the agent an acceptance script cares about is the one the APP
    /// auto-spawns, and the script cannot add arguments to that — but the app
    /// spawns it with an inherited environment block, so a var set around the
    /// app reaches it. Empty in every real agent.
    var suppress_buf: [256]u8 = undefined;
    var suppress_len: usize = 0;

    /// Record the suppression set (truncating past the buffer, which only a
    /// nonsense value could reach). Idempotent; last call wins.
    pub fn suppressCapabilities(list: []const u8) void {
        suppress_len = @min(list.len, suppress_buf.len);
        @memcpy(suppress_buf[0..suppress_len], list[0..suppress_len]);
    }

    /// True iff `name` appears in the suppression set. Whitespace around an
    /// entry is ignored so `"a, b"` behaves like `"a,b"`.
    fn isSuppressed(name: []const u8) bool {
        if (suppress_len == 0) return false;
        var it = std.mem.splitScalar(u8, suppress_buf[0..suppress_len], ',');
        while (it.next()) |raw| {
            if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), name)) return true;
        }
        return false;
    }

    /// Upper bound on advertised capabilities — the `Options` default is the
    /// longest list that exists, and this is comfortably above it.
    const max_advertised_caps = 32;

    /// `capability.agent_handoff`, but only on the seat that has the mechanism
    /// (T907). Advertising it is a PROMISE — "a newer build beside me replaces me
    /// without losing your sessions, so do not restart me" — and a peer that
    /// believes it stands down. On a seat where the holder half has not landed
    /// (the Mac increment 5 of the T705 split) that promise would be a lie, and
    /// the cost of the lie is an agent nothing ever upgrades. Comptime, so the
    /// string is simply absent from the list rather than conditionally filtered
    /// at handshake time.
    const handoff_caps: []const []const u8 = if (builtin.os.tag == .windows)
        &.{protocol.capability.agent_handoff}
    else
        &.{};

    /// Everything this agent build advertises in its HELLO, in one comptime
    /// list so the seat-conditional tail (`handoff_caps`) is appended in exactly
    /// one place rather than at each `Options` construction site.
    pub const default_capabilities: []const []const u8 = base_capabilities ++ handoff_caps;

    const base_capabilities: []const []const u8 = &.{
        protocol.capability.resync,
        protocol.capability.flow,
        protocol.capability.close_session,
        protocol.capability.grid_snapshot,
        protocol.capability.session_cpu,
        protocol.capability.sessions_push,
        // This build's `proc.zig` converts macOS mach ticks to nanoseconds,
        // so every `cpu_pct` it reports is in corrected units. Advertising it
        // is what lets a new app distinguish us from a pre-fix agent whose
        // numbers are ~24× low on Apple Silicon.
        protocol.capability.cpu_units,
        // `handleRelaunch` splices the viewer's `RELAUNCH.notice` into the ring
        // ahead of the replay, so the mode reset that undoes what the replay
        // re-armed lands where the respawned child cannot race it (T824).
        protocol.capability.relaunch_notice,
        // This build samples each bound session's process subtree and pushes
        // `META{has_descendants}`, so a viewer can skip the close
        // confirmation for an idle CROSS-MACHINE pane (T356).
        protocol.capability.session_busy,
        // This build ANSWERS a refused OPEN instead of dropping it, so the
        // pane says why in milliseconds rather than blaming a timeout ten
        // seconds later (T469).
        protocol.capability.open_failed,
        // ...and the same for an ATTACH it cannot answer at all, which is
        // the resume path a user meets after a reboot (T657).
        protocol.capability.attach_failed,
        // This build FRAMES the repaints it injects on ATTACH (the
        // scrollback-lost marker, the grid snapshot) as `DATA_REPAINT`, so
        // the client stops recording a resume point past our stream head by
        // the size of our own repaint (T739).
        protocol.capability.repaint_data,
    };

    pub const Options = struct {
        /// The pinned transfer encoding for this connection (§4.2). The agent
        /// echoes it in its HELLO; both sides must already agree.
        encoding: protocol.TransferEncoding,
        /// Capabilities the agent advertises in its HELLO.
        capabilities: []const []const u8 = default_capabilities,
        /// Per-session raw-output ring size (§7.1). Lowered in tests.
        ring_bytes: usize = session.default_ring_bytes,
        clock: ?Clock = null,
        /// This machine's hostname, advertised in the HELLO for client display
        /// (the window pill). Must outlive `start()` (encoded there). Optional.
        hostname: ?[]const u8 = null,
        /// This agent's build stamp ("YYYYMMDD-<hash>"), advertised in the HELLO
        /// so the app can detect it is running an older build than it bundles and
        /// lazily refresh it. Must outlive `start()` (encoded there). Optional.
        build_version: ?[]const u8 = null,
        /// The pty flavour this agent's children run on, advertised in the HELLO
        /// so a client can pick a per-pane terminal policy from the CHILD rather
        /// than from its own OS (T471 — the scrollback guard). Defaults to what
        /// this build actually spawns; overridden only by the `pty_flavor` test
        /// seam, which is how an on-box script reaches the cross-OS case with one
        /// machine.
        pty_flavor: protocol.PtyFlavor = .local,
        /// The `proto_version` to advertise, overriding this build's pinned one.
        /// A TEST SEAM (T125) and nothing else: an incompatible protocol skew is
        /// otherwise unreproducible from one tree, because both ends are built
        /// from the same `protocol.proto_version` constant. Null = the pinned
        /// version, which is what every real agent uses.
        proto_version: ?u16 = null,
    };

    /// Stand up a per-connection Server over a SHARED daemon `store` (the registry
    /// that outlives connections, §7.1 survival). The store owns the session table,
    /// its lock, the id RNG, and the idle-TTL reaper; this Server only bridges
    /// frames to/from it for the life of one connection.
    pub fn create(
        alloc: Allocator,
        control: Stream,
        data: Stream,
        spawner: Spawner,
        store: *session.SessionStore,
        opts: Options,
    ) Allocator.Error!*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .control = control,
            .data = data,
            .encoding = opts.encoding,
            .local_hello = .{
                .proto_version = opts.proto_version orelse protocol.proto_version,
                .transfer_encoding = opts.encoding,
                .capabilities = opts.capabilities,
                .hostname = opts.hostname,
                .build_version = opts.build_version,
                .pty_flavor = opts.pty_flavor.toString(),
            },
            .clock = opts.clock orelse Clock.real(),
            .spawner = spawner,
            .store = store,
            .ring_bytes = opts.ring_bytes,
        };
        // Advertise everything `opts` asked for, minus anything suppressed for a
        // skew test. Points into `self`, which is heap-allocated and stable for
        // the connection's life, so the HELLO encode below borrows safely.
        var n: usize = 0;
        for (opts.capabilities) |c| {
            if (isSuppressed(c)) continue;
            if (n == max_advertised_caps) break;
            self.advertised_caps[n] = c;
            n += 1;
        }
        self.local_hello.capabilities = self.advertised_caps[0..n];

        self.proc_sampler = proc.ProcSampler.init(alloc);
        return self;
    }

    /// Start the writer + reader threads. Queues our HELLO first so it is the first
    /// control frame (the §4.2 "HELLO first in each direction" rule).
    pub fn start(self: *Server) !void {
        assert(!self.started);

        const hello_json = try self.local_hello.encode(self.alloc);
        defer self.alloc.free(hello_json);
        try self.enqueue(.control, .hello, protocol.control_channel, hello_json);

        self.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        errdefer {
            self.signalClose();
            if (self.writer_thread) |t| t.join();
            self.writer_thread = null;
        }
        self.control_thread = try std.Thread.spawn(.{}, controlReaderLoop, .{self});
        errdefer {
            self.control.close();
            if (self.control_thread) |t| t.join();
            self.control_thread = null;
        }
        self.data_thread = try std.Thread.spawn(.{}, dataReaderLoop, .{self});
        errdefer {
            self.data.close();
            if (self.data_thread) |t| t.join();
            self.data_thread = null;
        }
        self.started = true;
    }

    /// Block until the handshake completes; return the negotiated params or the
    /// negotiation error.
    pub fn waitHandshake(self: *Server) !protocol.Negotiated {
        self.handshake_done.wait();
        return self.negotiated;
    }

    /// Stop everything for THIS connection: DETACH every session this connection
    /// bound (clear its bridge so the store stops framing to our dying writer, but
    /// KEEP the child running and ringing — the close-laptop survival path, §7.1),
    /// then close streams (unblocks reader threads at EOF), wake + drain the writer,
    /// and join all OUR threads. The sessions and their pty children are untouched;
    /// they live on in the store until reattached or idle-reaped. Safe to call once.
    ///
    /// CRITICAL (the wedge fix): we detach by clearing per-session bridge pointers
    /// under the store lock — we do NOT terminate any child here. Terminating a
    /// child joins its pty reader thread, whose output sink takes the store lock; if
    /// we did that while holding the lock (as the old `handleClose` did) the reader
    /// could never make progress and the join would hang, wedging the accept loop.
    pub fn shutdown(self: *Server) void {
        self.detachAll();
        // Reboot scrollback (T13, §5.4): a viewer disconnecting is the moment its
        // sessions become vulnerable to a subsequent reboot (the agent could be
        // killed before the next periodic snapshot). Flush dirty rings to disk now
        // so a restart can replay the scrollback up to this instant. No-op when
        // ring snapshots are disabled or nothing is dirty; best-effort.
        self.store.snapshotRings();
        // Stop + join the metrics pump BEFORE the streams close path completes: it
        // is a per-connection thread that frames onto our writer, so it must never
        // outlive the Server (the just-fixed UAF class). Signalling stop wakes its
        // timed cond wait immediately rather than waiting out the interval.
        // Latch BEFORE the stops: the control reader is still running here and can
        // be mid-`*_sub`. Once this is set, no handler will spawn another pump, so
        // the three stops below are final rather than a snapshot a later subscribe
        // can undo (T442).
        self.pumps_closed.store(true, .release);
        self.stopMetricsPump();
        self.stopSessionCpuPump();
        self.stopRosterPump();
        self.signalClose();
        self.control.close();
        self.data.close();
        if (self.control_thread) |t| t.join();
        self.control_thread = null;
        if (self.data_thread) |t| t.join();
        self.data_thread = null;
        if (self.writer_thread) |t| t.join();
        self.writer_thread = null;
        // In case a handshake never completed, release any waiter.
        if (!self.handshake_done.isSet()) {
            self.negotiated = error.Incompatible;
            self.handshake_done.set();
        }
    }

    /// DETACH every session this connection bound: under the store lock, clear the
    /// session's bridge (point output nowhere) + `bound` flag and stop streaming, so
    /// the orphaned session keeps ringing output but frames nothing to our dead
    /// writer. Does NOT terminate children (survival, §7.1). Idempotent.
    fn detachAll(self: *Server) void {
        // Ids of sessions that just became DEAD + UNBOUND (a tombstone whose last
        // viewer detached) — reaped AFTER we drop the store lock (reap frees a
        // child; never under the lock, cf. reapIdle/handleClose two-phase rule).
        var tombstones: std.ArrayListUnmanaged(u128) = .empty;
        defer tombstones.deinit(self.alloc);
        self.store.mutex.lock();
        for (self.bound_channels.items) |ch| {
            const s = self.store.table.getByChannel(ch) orelse continue;
            if (s.bridge_ctx == @as(?*anyopaque, self)) {
                s.bridge_ctx = null;
                s.bridge_data = null;
                s.bridge_exit = null;
                s.bridge_busy = null;
                s.has_descendants = null;
                s.bound = false;
                s.unattached_since_ms = self.clock.now();
                s.streaming = false;
                s.last_activity_ms = self.clock.now();
                // A dead, now-unbound, non-relaunchable session is unreconnectable
                // garbage — mark it for immediate reaping below so it can't linger
                // as a dead-end chooser row or be re-materialized after a restart.
                if (!s.alive and !s.relaunchable) tombstones.append(self.alloc, s.id) catch {};
            }
        }
        self.bound_channels.clearRetainingCapacity();
        self.store.mutex.unlock();
        for (tombstones.items) |id| self.store.reapUnboundTombstone(id);
    }

    /// Free the server (must be shut down first). Frees per-connection state only;
    /// the SHARED session store (and its children) is owned by the daemon and
    /// outlives this Server — `destroy` never touches the table.
    pub fn destroy(self: *Server, alloc: Allocator) void {
        assert(self.control_thread == null and self.data_thread == null and self.writer_thread == null);
        assert(self.metrics_thread == null);
        assert(self.session_cpu_thread == null and self.roster_thread == null);
        self.proc_sampler.deinit();
        self.bound_channels.deinit(self.alloc);
        for (self.write_queue.items) |f| self.alloc.free(f.payload);
        self.write_queue.deinit(self.alloc);
        alloc.destroy(self);
    }

    fn signalClose(self: *Server) void {
        self.write_mutex.lock();
        self.closed = true;
        self.write_cond.signal();
        self.write_mutex.unlock();
    }

    // --- Outbound -------------------------------------------------------------

    /// Enqueue a frame for the writer thread. Dups `payload` into queue-owned
    /// memory. On OOM the frame is dropped (best effort) since the caller (a reader
    /// thread) has nowhere useful to surface it.
    fn enqueue(
        self: *Server,
        stream: StreamId,
        ftype: protocol.FrameType,
        channel: u128,
        payload: []const u8,
    ) Allocator.Error!void {
        const owned = try self.alloc.dupe(u8, payload);
        errdefer self.alloc.free(owned);
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.closed) {
            self.alloc.free(owned);
            return;
        }
        try self.write_queue.append(self.alloc, .{
            .stream = stream,
            .ftype = ftype,
            .channel = channel,
            .payload = owned,
        });
        self.write_cond.signal();
    }

    /// Enqueue a JSON control frame (OPENED/ATTACHED/EXIT/META/...).
    fn sendJson(self: *Server, ftype: protocol.FrameType, channel: u128, value: anytype) !void {
        const json = try protocol.encodeJson(self.alloc, value);
        defer self.alloc.free(json);
        try self.enqueue(.control, ftype, channel, json);
    }

    /// Enqueue a DATA frame on the data channel (the §4.2 binary payload header).
    fn sendData(self: *Server, channel: u128, byte_offset: u64, bytes: []const u8) !void {
        try self.sendDataFramed(.data, channel, byte_offset, bytes);
    }

    /// Enqueue an INJECTED REPAINT (T739): bytes the client must render but must
    /// NOT count as stream position, because they are ours rather than the
    /// child's. Framed as `DATA_REPAINT` (0x15) when the peer negotiated
    /// `repaint_data`; otherwise it rides plain `DATA`, which is exactly the
    /// pre-T739 wire and leaves the client over-counting as it always did — an
    /// unknown opcode would be a fatal framing error for that peer, so the
    /// degrade is mandatory, not a nicety.
    fn sendRepaint(self: *Server, channel: u128, byte_offset: u64, bytes: []const u8) !void {
        const framed: protocol.FrameType = if (self.repaintDataNegotiated()) .data_repaint else .data;
        try self.sendDataFramed(framed, channel, byte_offset, bytes);
    }

    /// True iff both peers advertised `capability.repaint_data`. A handshake that
    /// failed (or has not landed) answers false, i.e. the safe, older wire.
    fn repaintDataNegotiated(self: *Server) bool {
        return if (self.negotiated) |n| n.repaint_data else |_| false;
    }

    fn sendDataFramed(
        self: *Server,
        ftype: protocol.FrameType,
        channel: u128,
        byte_offset: u64,
        bytes: []const u8,
    ) !void {
        const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
        defer self.alloc.free(payload);
        const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
        _ = dp.encodeInto(payload);
        try self.enqueue(.data, ftype, channel, payload);
    }

    // --- Child output delivery ------------------------------------------------
    //
    // The pty reader thread's output sink points at the STORE (stable across
    // reconnects), not at this per-connection Server — see `store.onChildOutput`.
    // The store records into the ring + reaps, and (when a connection is bound)
    // calls back into the bound Server's bridge to actually frame DATA / EXIT onto
    // the wire. These two trampolines are that bridge.

    /// Bridge: frame a live child-output chunk as DATA on `channel`. Installed on a
    /// session (`bridge_data`) when this connection binds it; called by
    /// `store.onChildOutput` under the store lock.
    fn bridgeData(ctx: *anyopaque, channel: u128, byte_offset: u64, bytes: []const u8) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendData(channel, byte_offset, bytes) catch {};
    }

    /// Bridge: frame EXIT on `channel` (ordered after the final DATA). Installed as
    /// `bridge_exit`; called by `store.onChildOutput` when the child reaps.
    fn bridgeExit(ctx: *anyopaque, channel: u128, code: i64, runtime_ms: u64) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendJson(.exit, channel, protocol.Exit{
            .code = code,
            .runtime_ms = runtime_ms,
        }) catch {};
        // A child exited on its own -- the case a poll handled worst:
        // the row stayed 'alive' until the next tick, which is how exited
        // sessions came to be shown as live "Resume" rows.
        self.markRosterDirty();
    }

    /// Push the session's changed foreground pid as `META{foreground_pid}` on
    /// its channel (wp3 live-fg sampling; see `SessionStore.sampleForegroundPids`).
    fn bridgeFgPid(ctx: *anyopaque, channel: u128, fg_pid: i64) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendJson(.meta, channel, protocol.Meta{
            .foreground_pid = fg_pid,
        }) catch {};
    }

    /// Push the session's changed "is anything running under this shell?" answer
    /// as `META{has_descendants}` on its channel (T356; see
    /// `SessionStore.sampleDescendants`). Installed only when the peer negotiated
    /// `capability.session_busy`, which is also what gates the sampling itself.
    fn bridgeBusy(ctx: *anyopaque, channel: u128, has_descendants: bool) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.sendJson(.meta, channel, protocol.Meta{
            .has_descendants = has_descendants,
        }) catch {};
    }

    /// Test/back-compat shim: deliver child output through the store (which bridges
    /// to this Server if bound). Real production output arrives via the store sink
    /// installed on the pty child; tests still call `server.onChildOutput(...)`.
    pub fn onChildOutput(self: *Server, channel: u128, bytes: []const u8) void {
        self.store.onChildOutput(channel, bytes);
    }

    /// Explicitly poll every live session for exit (tests call it after marking a
    /// fake child exited). Delegates a zero-length nudge per channel through the
    /// store so any exited child reaps + emits EXIT via the bridge.
    pub fn reapAll(self: *Server) void {
        self.store.mutex.lock();
        var channels: std.ArrayList(u128) = .empty;
        defer channels.deinit(self.alloc);
        var it = self.store.table.by_id.valueIterator();
        while (it.next()) |sp| channels.append(self.alloc, sp.*.channel) catch {};
        self.store.mutex.unlock();
        for (channels.items) |ch| self.store.onChildOutput(ch, &.{});
    }

    // --- Writer thread (single writer; seq == wire order) ---------------------

    fn writerLoop(self: *Server) void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        var batch: std.ArrayList(OutFrame) = .empty;
        defer batch.deinit(self.alloc);

        while (true) {
            self.write_mutex.lock();
            while (self.write_queue.items.len == 0 and !self.closed) {
                self.write_cond.wait(&self.write_mutex);
            }
            // Swap the whole pending queue out so we hold the lock minimally.
            const pending = self.write_queue;
            self.write_queue = batch;
            batch = pending;
            const done = self.closed and batch.items.len == 0;
            self.write_mutex.unlock();

            for (batch.items) |f| {
                const frame: protocol.Frame = .{
                    .type = f.ftype,
                    .channel = f.channel,
                    .seq = self.frame_seq.next(), // single writer ⇒ seq == wire order
                    .payload = f.payload,
                };
                wire.clearRetainingCapacity();
                protocol.writeFrame(self.alloc, self.encoding, frame, &wire) catch {
                    self.alloc.free(f.payload);
                    continue;
                };
                const stream = switch (f.stream) {
                    .control => self.control,
                    .data => self.data,
                };
                stream.writeAll(wire.items) catch {};
                self.alloc.free(f.payload);
            }
            batch.clearRetainingCapacity();

            if (done) break;
        }
    }

    // --- Reader threads -------------------------------------------------------

    fn controlReaderLoop(self: *Server) void {
        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;

        // Handshake: consume frames until the client HELLO arrives.
        handshake: while (!self.handshake_done.isSet()) {
            while (reader.next() catch {
                self.completeHandshake(error.Incompatible);
                break :handshake;
            }) |frame| {
                if (frame.type != .hello) continue; // ignore pre-HELLO noise
                self.completeHandshake(self.negotiatePeerHello(frame.payload));
                break :handshake;
            }
            const n = self.control.read(&scratch) catch 0;
            if (n == 0) {
                self.completeHandshake(error.Incompatible);
                return;
            }
            reader.push(scratch[0..n]) catch {
                self.completeHandshake(error.Incompatible);
                break :handshake;
            };
        }
        if (std.meta.isError(self.negotiated)) return;

        // Routing: dispatch each control frame.
        while (true) {
            while (reader.next() catch return) |frame| {
                self.handleControlFrame(frame);
            }
            const n = self.control.read(&scratch) catch return;
            if (n == 0) return; // EOF
            reader.push(scratch[0..n]) catch return;
        }
    }

    fn dataReaderLoop(self: *Server) void {
        // The data lane only carries DATA frames (client keystrokes inbound). Wait
        // for the handshake so we never route before negotiation (the encoding is
        // fixed at construction, but ordering keeps semantics clean).
        self.handshake_done.wait();
        if (std.meta.isError(self.negotiated)) return;

        var reader = protocol.Reader.init(self.alloc, self.encoding);
        defer reader.deinit();
        var scratch: [read_buf_size]u8 = undefined;
        while (true) {
            while (reader.next() catch return) |frame| {
                if (frame.type == .data) self.handleInboundData(frame);
                // Any non-DATA on the data lane is malformed routing → ignore.
            }
            const n = self.data.read(&scratch) catch return;
            if (n == 0) return; // EOF
            reader.push(scratch[0..n]) catch return;
        }
    }

    // --- Handshake ------------------------------------------------------------

    fn completeHandshake(self: *Server, result: anyerror!protocol.Negotiated) void {
        if (self.handshake_done.isSet()) return;
        self.negotiated = result;
        self.handshake_done.set();
    }

    fn negotiatePeerHello(self: *Server, payload: []const u8) anyerror!protocol.Negotiated {
        var parsed = protocol.Hello.parse(self.alloc, payload) catch return error.Incompatible;
        defer parsed.deinit();
        return protocol.negotiate(self.local_hello, parsed.value);
    }

    // --- Control frame handling ----------------------------------------------

    /// Dispatch one inbound control frame. All payloads are untrusted; a malformed
    /// payload or unknown id is ignored (never a crash, §15 M3).
    fn handleControlFrame(self: *Server, frame: protocol.Frame) void {
        switch (frame.type) {
            .open => self.handleOpen(frame.channel, frame.payload),
            .attach => self.handleAttach(frame.payload),
            .resize => self.handleResize(frame.channel, frame.payload),
            .signal => self.handleSignal(frame.channel, frame.payload),
            .detach => self.handleDetach(frame.channel),
            .close => self.handleClose(frame.channel),
            .close_session => self.handleCloseSession(frame.channel, frame.payload),
            .get_cwd => self.handleGetCwd(frame.channel, frame.payload),
            .list_sessions => self.handleListSessions(frame.channel),
            .set_layout => self.handleSetLayout(frame.channel, frame.payload),
            .get_layouts => self.handleGetLayouts(frame.channel),
            .relaunch => self.handleRelaunch(frame.payload),
            .ping => self.handlePing(frame.payload),
            .flow => self.handleFlow(frame.payload),
            .metrics_sub => self.handleMetricsSub(frame.payload),
            .metrics_unsub => self.handleMetricsUnsub(),
            .session_cpu_sub => self.handleSessionCpuSub(frame.payload),
            .session_cpu_unsub => self.handleSessionCpuUnsub(),
            .sessions_sub => self.handleSessionsSub(),
            .sessions_unsub => self.sessions_push = false,
            .proc_list => self.handleProcList(frame.channel, frame.payload),
            .proc_kill => self.handleProcKill(frame.channel, frame.payload),
            .proc_spawn => self.handleProcSpawn(frame.channel, frame.payload),
            // The remaining types are agent→client replies (the agent produces
            // them) or out of scope: ignore.
            else => {},
        }
    }

    /// Tell the client we will NOT open a session, and why (T469).
    ///
    /// Silent on a peer that did not negotiate `capability.open_failed`: 0x06 is
    /// a new opcode and an unknown opcode is a FATAL FRAMING ERROR for the
    /// receiver, so emitting it to an older app would turn a refused pane into a
    /// dropped connection — every other pane on that link with it. Such a peer
    /// gets the pre-T469 behavior (silence, then its own 10 s timeout), which is
    /// the graceful degradation the agent-contract rules require.
    ///
    /// Best-effort by design: if the reply cannot be enqueued the client still
    /// has its timeout, so a failure here costs latency, never correctness.
    fn sendOpenFailed(
        self: *Server,
        channel: u128,
        reason: []const u8,
        detail: ?[]const u8,
    ) void {
        const ok = if (self.negotiated) |n| n.open_failed else |_| false;
        if (!ok) return;
        self.sendJson(.open_failed, channel, protocol.OpenFailed{
            .reason = reason,
            .detail = detail,
        }) catch {};
    }

    /// Tell the client we cannot answer its ATTACH, and why (T657).
    ///
    /// Only for refusals `ATTACHED` has no way to express — `not_found`, `dead`
    /// and `attached_elsewhere` are answered with an ordinary `ATTACHED`
    /// carrying that status, and always have been. Same gate, same
    /// best-effort posture and same reasoning as `sendOpenFailed`: an unknown
    /// opcode is a fatal framing error, so an older peer gets silence and its
    /// own timeout rather than a dropped connection.
    ///
    /// Sent on the CONTROL channel, like the `not_found` reply: there is no
    /// session, so there is no session channel to speak on.
    fn sendAttachFailed(self: *Server, reason: []const u8, detail: ?[]const u8) void {
        const ok = if (self.negotiated) |n| n.attach_failed else |_| false;
        if (!ok) return;
        self.sendJson(.attach_failed, protocol.control_channel, protocol.AttachFailed{
            .reason = reason,
            .detail = detail,
        }) catch {};
    }

    fn handleOpen(self: *Server, req_channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Open, self.alloc, payload) catch |err| {
            self.sendOpenFailed(
                req_channel,
                protocol.OpenFailed.Reason.malformed_request,
                @errorName(err),
            );
            return;
        };
        defer parsed.deinit();
        const open = parsed.value;

        // Spawn the child (real pty).
        const spawned = self.spawner.spawn(open) catch |err| {
            // SAY SO (T469). A spawn failure is the most common refusal a user
            // can actually fix — a shell path that does not exist, a command
            // that is not on PATH — and it used to be the one that looked
            // identical to every other: a blank pane and, ten seconds later,
            // "error starting IO thread: error.Timeout".
            std.log.warn("OPEN refused: spawn failed err={s}", .{@errorName(err)});
            self.sendOpenFailed(
                req_channel,
                protocol.OpenFailed.Reason.spawn_failed,
                @errorName(err),
            );
            return;
        };

        // Stable copy of the child's tty path (wp3): `Result.tty` borrows storage
        // the child frees on terminate, so copy it before any window where an
        // exit/teardown could race the OPENED send below.
        var tty_buf: [128]u8 = undefined;
        const tty_copy: ?[]const u8 = if (spawned.tty) |t| blk: {
            const n = @min(t.len, tty_buf.len);
            @memcpy(tty_buf[0..n], t[0..n]);
            break :blk tty_buf[0..n];
        } else null;

        self.store.mutex.lock();
        const s = self.store.table.create(
            spawned.child,
            spawned.pid,
            open.rows,
            open.cols,
            self.ring_bytes,
            self.clock.now(),
        ) catch |err| {
            // Cap hit or OOM: terminate the orphaned child OUTSIDE the lock (the
            // terminate→reader-join deadlock rule), then drop.
            //
            // SAY SO (T278). The client gets no OPENED and eventually times out
            // with a pane that has no shell in it; before this, the agent's own
            // log said nothing either, so the one place that knew WHY kept it to
            // itself. Counts, not just the error name — "at the live cap" and
            // "out of memory" are different problems with the same symptom.
            const live = self.store.table.liveCount();
            const dead = self.store.table.deadCount();
            const cap = self.store.table.max_live;
            self.store.mutex.unlock();
            std.log.warn(
                "OPEN refused: {s} (live={d}/{d} dead={d}/{d})",
                .{ @errorName(err), live, cap, dead, session.max_dead_sessions },
            );
            // ...and tell the CLIENT, which is the half T278 left undone: the
            // log entry above only ever reached whoever went looking for it,
            // while the person watching the blank pane learned nothing.
            var detail_buf: [protocol.OpenFailedCopy.detail_max]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "live={d}/{d} dead={d}/{d}",
                .{ live, cap, dead, session.max_dead_sessions },
            ) catch null;
            self.sendOpenFailed(req_channel, switch (err) {
                error.TooManySessions => protocol.OpenFailed.Reason.session_cap,
                else => protocol.OpenFailed.Reason.out_of_memory,
            }, detail);
            spawned.child.terminate();
            return;
        };
        // Record a human-readable command label for LIST_SESSIONS (T10): the
        // explicit command if the client asked for one, else the resolved shell.
        // Best-effort (setArgv swallows OOM) — a missing label just lists as null.
        if (open.command) |cmd| {
            s.setArgv(cmd);
        } else if (open.shell) |sh| {
            s.setArgv(sh);
        }
        // Record the working directory the child was spawned in (T132). Without
        // this the field stayed null for every session ever opened, so it was
        // never written to `sessions.json` and `handleRelaunch` passed a null cwd
        // — a session that outlived the agent (reboot, agent upgrade) respawned in
        // the AGENT's own inherited cwd. On the win32 auto-launch path that is the
        // launching process's cwd (`C:\Windows\System32` for a detached script),
        // which is how a relaunched pane came back in the wrong directory.
        if (open.cwd) |c| s.setCwd(c);
        // Record WHICH PANE this session belongs to (T552). The agent keeps no
        // other part of a session's env — `protocol.Relaunch` explains why
        // RELAUNCH has to re-send it — but this one key is identity rather than
        // environment: it is the only answer to "which pane is this session in?"
        // once the app is closed and `+list --json`'s `session_id` (T332, the
        // same join in the other direction) cannot be asked at all.
        if (protocol.Open.paneIdOf(open.env)) |pane| s.setPaneId(pane);
        // Pin persistent local sessions so the idle-TTL reaper never evicts them
        // while orphaned (§7.1, T11). Set by the local-agent client for panes the
        // viewer's session-layout manifest references; false for cross-machine.
        s.pinned = open.pinned;
        // Record the pty slave path (wp3) so a later ATTACH can re-report it.
        s.setTty(tty_copy);
        // A holder-backed session (T905) records where its ConPTY actually
        // lives, so `sessions.json` names a survivor an agent restart can find.
        if (spawned.holder) |h| s.setHolder(h.pipe, h.pid, h.stamp);
        // Bind the new session to THIS connection: install the outbound bridge so
        // live output frames to our writer, mark it bound (so the idle reaper leaves
        // it alone), and track its channel so disconnect detaches just our sessions.
        self.bindLocked(s);
        const channel = s.channel;
        const id_copy = s.id_str; // value copy; safe to use after unlock
        const pid = s.pid;
        const child = s.child; // value copy of the vtable handle
        self.store.mutex.unlock();

        // Arm the durability gate BEFORE the reader thread exists (T911): from
        // here on a holder-backed child acks what is on disk rather than what it
        // delivered, so an agent crash cannot take the stretch since the last
        // ring snapshot with it. Zero releases nothing — `snapshotRings` raises
        // the watermark from there. Only when this store actually snapshots
        // rings; with persistence off there is no durability to wait for.
        if (self.store.rings_dir != null and self.store.durable_ack) child.releaseTo(0);

        // Hand the (real pty) child its channel + output sink so its reader thread
        // routes master-fd output to the STORE (stable across reconnects). Done
        // AFTER unlock because the sink itself takes the store lock. The fake child
        // ignores this (attach == null).
        child.attach(self.store, session.SessionStore.onChildOutputTrampoline, channel);

        self.sendJson(.opened, channel, protocol.Opened{
            .session_id = id_copy[0..],
            .pid = pid,
            .tty = tty_copy,
        }) catch {};

        // A new session entered the alive set — durably record the reboot-floor
        // metadata (§5.4, T12). Runs after our unlock; no-op when persistence is
        // disabled (meta_path null, e.g. every test + non-persistent serve path).
        self.store.persistMeta();
        // A new session exists.
        self.markRosterDirty();
    }

    /// Bind session `s` to this connection: point its outbound bridge at us, mark it
    /// bound + streaming, and record its channel for detach-on-disconnect. Caller
    /// holds `store.mutex`. Idempotent-ish: re-binding repoints the bridge.
    fn bindLocked(self: *Server, s: *session.Session) void {
        s.bridge_ctx = self;
        s.bridge_data = bridgeData;
        s.bridge_exit = bridgeExit;
        s.bridge_fgpid = bridgeFgPid;
        // The busy bridge is the capability gate (T356): with it absent the store's
        // `sampleDescendants` skips its process-table walk entirely, so an agent
        // whose attached clients are all too old to understand
        // `META{has_descendants}` does no sampling work at all.
        s.bridge_busy = if (self.negotiated) |n|
            (if (n.session_busy) bridgeBusy else null)
        else |_|
            null;
        // Reset the sampler baseline so a freshly-(re)bound viewer receives the
        // CURRENT foreground pid on the next tick even if it hasn't changed —
        // the previous viewer's pushes died with its connection (wp3). Same
        // reasoning for the descendants answer: null is the client's UNKNOWN, and
        // a fresh viewer must be told rather than inherit a dead one's state.
        s.fg_pid = 0;
        s.has_descendants = null;
        s.bound = true;
        // A viewer is looking at it again: the long-unattached clock (T534)
        // restarts from the NEXT detach, not from some earlier one.
        s.unattached_since_ms = null;
        // A client attached: the session is in use, so it is not a stale
        // reboot-floor leftover -- reset its unclaimed-restart allowance.
        s.unclaimed_restarts = 0;
        s.streaming = true;
        // Track the channel once (avoid dupes across re-attach within one conn).
        for (self.bound_channels.items) |c| if (c == s.channel) return;
        self.bound_channels.append(self.alloc, s.channel) catch {};
    }

    fn handleAttach(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Attach, self.alloc, payload) catch |err| {
            // SAY SO (T657). This was the one genuinely silent ATTACH path: the
            // client's parked `.attached` slot had no frame to wake on, so a
            // request we rejected in microseconds cost it the full 10 s
            // `rpc_open_timeout_ns` and then surfaced as `error.Timeout` — the
            // symptom we produced, never the cause we knew.
            std.log.warn("ATTACH refused: payload did not parse err={s}", .{@errorName(err)});
            self.sendAttachFailed(
                protocol.AttachFailed.Reason.malformed_request,
                @errorName(err),
            );
            return;
        };
        defer parsed.deinit();
        const att = parsed.value;

        self.store.mutex.lock();
        defer self.store.mutex.unlock();

        const s = self.store.table.getByIdStr(att.session_id) orelse {
            // Unknown session → not_found. We reply on the control channel; the
            // client correlates by session_id in its pending-attach table.
            self.sendJson(.attached, protocol.control_channel, protocol.Attached{
                .status = .not_found,
            }) catch {};
            return;
        };

        if (!s.alive) {
            // Tombstone → dead + exit_code (§7.1/§7.4). `relaunchable` distinguishes
            // a session materialized from disk (T12b, no exit_code, RELAUNCH-able)
            // from a child that genuinely exited this run.
            // cwd/argv ride the DEAD reply too (T230). The viewer's default
            // policy no longer respawns the recorded command — it opens a FRESH
            // shell in the recorded cwd and NAMES the old command in a notice —
            // so both are display/placement inputs it can only get from here.
            // Borrowing the session's strings is safe: we hold the store lock
            // across the encode, exactly like the alive branch below.
            self.sendJson(.attached, s.channel, protocol.Attached{
                .status = .dead,
                .exit_code = s.exit_code,
                .relaunchable = s.relaunchable,
                .rows = s.rows,
                .cols = s.cols,
                .cwd = if (s.cwd) |c| c else null,
                .argv = if (s.argv) |a| a else null,
                .foreground_cmd = if (s.fg_cmd) |f| f else null,
            }) catch {};
            return;
        }

        // Alive: (re)BIND the session to THIS connection — this is the close-laptop
        // reconnect path. The session may have been orphaned (its previous
        // connection dropped); binding repoints the bridge at our writer so live
        // output resumes flowing, and clears the orphan/idle-reap eligibility.
        self.bindLocked(s);

        // Capture the snapshot anchor S (= current outbound offset; a real grid
        // snapshot is `// TODO(snapshot)`). Resume the session's dims to the
        // attaching client's geometry — but FIRST record the geometry the ring
        // tail was drawn at, so the reply can tell the client what size to
        // replay at (T106; see protocol.Attached.replay_rows).
        const now = self.clock.now();
        const replay_rows = s.rows;
        const replay_cols = s.cols;
        s.rows = att.rows;
        s.cols = att.cols;
        s.last_activity_ms = now;
        s.child.resize(att.rows, att.cols, 0, 0) catch {};
        // Re-attach repaint: the geometry restored here is only the pre-layout
        // seed; the client sends an authoritative RESIZE once the pane is live
        // (threadEnter, 106dcdc9c). Latch a one-shot SIGWINCH onto that RESIZE so
        // alt-screen apps repaint even when the restored size is byte-identical
        // (else they stay blank until a manual resize). See winch_on_next_resize.
        s.winch_on_next_resize = true;
        const snapshot_at = s.snapshotOffset();

        self.sendJson(.attached, s.channel, protocol.Attached{
            .status = .alive,
            .rows = s.rows,
            .cols = s.cols,
            .cwd = if (s.cwd) |c| c else null,
            .title = if (s.title) |t| t else null,
            .snapshot_at_offset = snapshot_at,
            // pid/tty (wp3): re-attach is how an app relaunch recovers every
            // persistence pane, so `getProcessInfo` metadata must ride ATTACHED
            // too (OPENED went to the previous app process). Sent under the
            // store lock, so borrowing the session's strings is safe.
            .pid = s.pid,
            .tty = if (s.tty) |t| t else null,
            .replay_rows = replay_rows,
            .replay_cols = replay_cols,
        }) catch {};

        // Gap-fill / CATCH-UP (§7.3) + grid snapshot (FIX 2). Replay everything the
        // client missed while it was gone; then, when the peer negotiated
        // `grid_snapshot`, append a self-contained VT repaint of the CURRENT
        // visible screen so the pane is exact and NEVER blank — even when the paint
        // predates the ring (deep scrollback evicted, or a full-screen app whose
        // `?1049h` enter-alt scrolled out). Live DATA then resumes from offset > S.
        const want_snapshot = if (self.negotiated) |n| n.grid_snapshot else |_| false;

        // On the ALTERNATE screen the raw ring tail is alt-screen paint written
        // WITHOUT its (evicted) `?1049h` enter — replaying it onto the client's
        // primary screen is exactly what smeared/blanked the pane. With a snapshot
        // in hand we SKIP that replay for alt sessions and let the snapshot (which
        // re-enters alt and repaints) stand alone. A primary session still gets its
        // raw replay for scrollback continuity, with the snapshot then repainting
        // the visible rows over it. Without a snapshot we keep today's replay for
        // both (an older/ring-only peer).
        const skip_replay = want_snapshot and s.gridOnAltScreen();

        if (att.last_byte_offset < snapshot_at) {
            const base = s.ring.base_offset;
            var replay_from = att.last_byte_offset;
            if (replay_from < base) {
                // The exact resume point was evicted. Emit a marker for the
                // genuinely-lost deep scrollback ABOVE the visible screen, then
                // replay from the oldest byte we still have.
                const lost = base - att.last_byte_offset;
                var marker_buf: [96]u8 = undefined;
                const marker = std.fmt.bufPrint(
                    &marker_buf,
                    "\r\n[ghoztty: {d} bytes of scrollback lost during disconnect]\r\n",
                    .{lost},
                ) catch "";
                // A repaint, not stream bytes (T739): the marker is OUR sentence
                // about the hole, anchored at the client's resume point. Counted
                // as stream, it pushes the client's recorded offset past a
                // position the session never produced.
                if (marker.len > 0) self.sendRepaint(s.channel, att.last_byte_offset, marker) catch {};
                replay_from = base;
            }
            if (!skip_replay) {
                const want: usize = @intCast(snapshot_at - replay_from);
                if (want > 0) {
                    const tmp = self.alloc.alloc(u8, want) catch return;
                    defer self.alloc.free(tmp);
                    if (s.ring.slice(replay_from, snapshot_at, tmp)) |n| {
                        self.sendData(s.channel, replay_from, tmp[0..n]) catch {};
                    }
                }
            }
        }

        // Grid snapshot: a clean repaint of the visible screen AT offset S (plain
        // VT any emulator renders) at the live continuation point, so the client
        // paints it right before live output resumes. `gridSnapshotAlloc` returns
        // null for a session that produced no output (no emulator yet), in which
        // case the ring replay above already stands alone.
        //
        // Framed as a REPAINT (T739): its bytes are anchored at S and the stream
        // continues at S, so a client that counted them would record a resume
        // point S + snap.len — past our own head, by exactly the size of the
        // repaint we just injected. That is indistinguishable from live output at
        // S unless we say which it is, which is what `sendRepaint` does (and
        // degrades to `sendData` for a peer that cannot be told).
        if (want_snapshot) {
            const snap = s.gridSnapshotAlloc(self.alloc);
            defer if (snap) |b| self.alloc.free(b);
            // The size of what we INJECT, which is exactly the error a client
            // that counts it will carry (T739) — and the only place that number
            // is visible from, since this frame looks like ordinary output on
            // the wire. 0 means a session with no emulator yet: nothing to
            // repaint, the ring replay above stands alone.
            std.log.info("ATTACH ch={x}: grid snapshot {d} byte(s) at {d}", .{
                s.channel,
                if (snap) |b| b.len else 0,
                snapshot_at,
            });
            if (snap) |b| {
                if (b.len > 0) self.sendRepaint(s.channel, snapshot_at, b) catch {};
            }
        }
    }

    fn handleResize(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Resize, self.alloc, payload) catch {
            std.log.warn("RESIZE parse failed ch={x} payload={s}", .{ channel, payload });
            return;
        };
        defer parsed.deinit();
        const rz = parsed.value;
        std.log.debug("RESIZE recv ch={x} rows={} cols={}", .{ channel, rz.rows, rz.cols });
        // Update dims + snapshot the child under the lock; do the (potentially
        // blocking) ConPTY resize OUTSIDE it — never hold the global store lock
        // across child I/O (see handleInboundData).
        self.store.mutex.lock();
        var winch_after = false;
        const child: ?session.Child = blk: {
            const s = self.store.table.getByChannel(channel) orelse {
                std.log.warn("RESIZE: no session for ch={x}", .{channel});
                break :blk null;
            };
            if (!s.alive) {
                std.log.warn("RESIZE: session for ch={x} not alive", .{channel});
                break :blk null;
            }
            s.rows = rz.rows;
            s.cols = rz.cols;
            s.px_w = rz.px_w;
            s.px_h = rz.px_h;
            // First authoritative RESIZE after an ATTACH/RELAUNCH: deliver one
            // SIGWINCH after applying the size so alt-screen apps repaint even
            // when the geometry is unchanged (TIOCSWINSZ alone raises SIGWINCH
            // only on a delta). One-shot — cleared here so live resizes don't
            // pay for a redundant signal.
            winch_after = s.winch_on_next_resize;
            s.winch_on_next_resize = false;
            break :blk s.child;
        };
        self.store.mutex.unlock();
        if (child) |c| {
            c.resize(rz.rows, rz.cols, rz.px_w, rz.px_h) catch |err| {
                std.log.warn("RESIZE: child.resize failed err={}", .{err});
            };
            // Ordered AFTER the resize: the app re-queries winsize on SIGWINCH,
            // so the child must already see the final dimensions.
            if (winch_after) c.signal("WINCH") catch {};
        }
    }

    fn handleSignal(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Signal, self.alloc, payload) catch return;
        defer parsed.deinit();
        const sig = parsed.value;
        // Record the signal + snapshot the child under the lock; DELIVER it outside
        // the lock. signal() writes to the child's input pipe (Ctrl-C → 0x03), the
        // SAME blocking-WriteFile hazard as handleInboundData — never hold the global
        // store lock across it.
        self.store.mutex.lock();
        const child: ?session.Child = blk: {
            const s = self.store.table.getByChannel(channel) orelse break :blk null;
            if (!s.alive) break :blk null;
            s.setSignal(sig.name) catch {};
            break :blk s.child;
        };
        self.store.mutex.unlock();
        if (child) |c| c.signal(sig.name) catch {};
    }

    fn handleDetach(self: *Server, channel: u128) void {
        // Explicit DETACH: stop streaming + unbind from this connection, but KEEP
        // the session alive + ringing (§4.2/§7.1). After this the session is an
        // orphan (idle-TTL eligible) until a new ATTACH.
        //
        // OWNERSHIP GUARD (WP-D1 wedged-window fix): only the connection that
        // currently OWNS the bridge may detach the session. During a reconnect
        // swap the NEW connection ATTACHes (rebinding the bridge to itself)
        // and only then does the old surface's teardown DETACH arrive over the
        // still-open OLD connection. Unguarded, that stale DETACH stopped
        // `streaming` out from under the new owner and the freshly re-attached
        // window went permanently silent.
        self.store.mutex.lock();
        const reap_id: ?u128 = blk: {
            const s = self.store.table.getByChannel(channel) orelse break :blk null;
            if (s.bridge_ctx != @as(?*anyopaque, self)) break :blk null; // stale: not ours
            s.streaming = false;
            s.bridge_ctx = null;
            s.bridge_data = null;
            s.bridge_exit = null;
            s.bridge_busy = null;
            s.has_descendants = null;
            s.bound = false;
            s.unattached_since_ms = self.clock.now();
            s.last_activity_ms = self.clock.now();
            // A dead, now-unbound, non-relaunchable session is unreconnectable
            // garbage: reap it immediately (below, off the lock) so it can't linger
            // as a dead-end chooser row or be re-materialized after a restart.
            break :blk if (!s.alive and !s.relaunchable) s.id else null;
        };
        self.store.mutex.unlock();
        if (reap_id) |id| self.store.reapUnboundTombstone(id);
        // The roster changed (a session is now detached, and possibly reaped).
        self.markRosterDirty();
    }

    fn handleClose(self: *Server, channel: u128) void {
        // Terminate the child + free the session (§4.2). Idempotent on a stale
        // channel (closing a nonexistent target succeeds silently). Two-phase to
        // avoid the deadlock: UNLINK under the lock, then terminate+free OUTSIDE it
        // (terminate joins the pty reader, whose sink takes this very lock).
        self.store.mutex.lock();
        const s = blk: {
            const sess = self.store.table.getByChannel(channel) orelse break :blk null;
            // OWNERSHIP GUARD (same rule as handleDetach/handleFlow, and the one
            // that matters most: this branch KILLS the child). During a
            // reconnect/rebuild swap the NEW connection ATTACHes — rebinding the
            // bridge to itself — and only then does the old surface's teardown
            // arrive over the still-open OLD connection. Unguarded, that stale
            // CLOSE terminated the session the new owner had just re-attached,
            // leaving a live-looking pane with a dead session behind it.
            //
            // The test is "bridged to SOMEONE ELSE", not handleDetach's stricter
            // "bridged to me": an UNBOUND session (bridge_ctx null — orphaned by
            // a DETACH or a dropped connection) has no owner to protect, and
            // refusing to close it would only leak it until the idle TTL.
            if (sess.bridge_ctx) |ctx| {
                if (ctx != @as(*anyopaque, self)) break :blk null;
            }
            break :blk sess;
        };
        const unlinked = if (s) |sess| self.store.table.unlink(sess.id) else null;
        self.store.mutex.unlock();
        if (unlinked) |u| {
            self.store.table.freeUnlinked(u);
            // The alive set shrank — refresh the reboot-floor metadata (§5.4,
            // T12). No-op when persistence is disabled or the channel was stale.
            self.store.persistMeta();
            // A closed session may have been the last one a stored layout blob
            // referenced (§5.4 "Resume all", T18) — reap orphaned blobs and
            // rewrite the layout file so it doesn't accumulate dead topology.
            if (self.store.reapLayouts() > 0) self.store.persistLayouts();
        }
        // A session was closed and freed.
        self.markRosterDirty();
    }

    /// `CLOSE_SESSION` (0x2c): end a session BY SESSION ID — the session-scoped
    /// equivalent of `handleClose`, for the chooser's "Kill" action on a BROWSED
    /// session that has no local pane (hence no channel to address `CLOSE` at).
    /// Resolves the session by id, then reuses the EXACT two-phase lock discipline
    /// of `handleClose` (UNLINK under the lock, then terminate+free OUTSIDE it, so
    /// the pty reader's sink — which takes this very lock — can't deadlock). Replies
    /// `CLOSE_SESSION_RESULT{session_id, ok, found}` on the request `channel`
    /// (same-channel RPC, like `handleGetCwd`). `found` = a session with that id
    /// existed; `ok` = it was closed.
    fn handleCloseSession(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.CloseSession, self.alloc, payload) catch {
            // Malformed request: we can't extract an id, but still give the client a
            // definitive answer (found=false, ok=false) rather than a silent hang.
            self.sendJson(.close_session_result, channel, protocol.CloseSessionResult{
                .session_id = "",
                .ok = false,
                .found = false,
            }) catch {};
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;

        // Stable copy of the session id for the reply (the parsed value is freed by
        // the trailing defer before sendJson runs through the writer queue).
        var id_buf: [64]u8 = undefined;
        const id_len = @min(req.session_id.len, id_buf.len);
        @memcpy(id_buf[0..id_len], req.session_id[0..id_len]);
        const id_copy = id_buf[0..id_len];

        // Phase 1: UNLINK under the lock (mirrors handleClose, but resolved by id).
        self.store.mutex.lock();
        const s = self.store.table.getByIdStr(req.session_id);
        const found = s != null;
        const unlinked = if (s) |sess| self.store.table.unlink(sess.id) else null;
        self.store.mutex.unlock();

        // Reply BEFORE the teardown (T326): `found` and `ok` are both decided by
        // the unlink and cannot change below, while phase 2 terminates a live
        // child and rewrites two files on disk — work that has exceeded the
        // client's 5s RPC budget on a loaded box, making a Kill that WORKED
        // report error.Timeout. The reply's latency must not depend on the
        // teardown's duration.
        self.sendJson(.close_session_result, channel, protocol.CloseSessionResult{
            .session_id = id_copy,
            .ok = unlinked != null,
            .found = found,
        }) catch {};
        // The roster changed the moment the unlink landed — subscribers that
        // refetch will no longer see the session, terminated or not.
        self.markRosterDirty();

        // Phase 2: terminate+free OUTSIDE the lock, then refresh reboot-floor
        // metadata and reap orphaned layout blobs — EXACTLY like handleClose.
        if (unlinked) |u| {
            self.store.table.freeUnlinked(u);
            self.store.persistMeta();
            if (self.store.reapLayouts() > 0) self.store.persistLayouts();
        }
    }

    /// `GET_CWD` (§WP4): on-demand "what is this session's child cwd?". Looks the
    /// session up by `session_id`, queries the OS for its child process's CURRENT
    /// working directory, and replies `CWD{session_id, path?, ok}` on the SAME
    /// request channel (the client correlates the reply by request channel).
    ///
    /// The OS query (`proc_pidinfo` / PEB read) runs OUTSIDE `store.mutex`: we
    /// snapshot the `session.Child` handle under the lock, drop the lock, then
    /// query. A `Child` handle stays valid until the child is `terminate`d, and a
    /// concurrent CLOSE only terminates after unlinking, so the worst case is the
    /// query failing gracefully (→ `ok = false`), never a use-after-free of the
    /// session table entry.
    fn handleGetCwd(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.GetCwd, self.alloc, payload) catch return;
        defer parsed.deinit();
        const req = parsed.value;

        // Snapshot the child handle (a value copy of the vtable handle) under the
        // lock; do the OS query unlocked.
        self.store.mutex.lock();
        const s = self.store.table.getByIdStr(req.session_id);
        const child: ?session.Child = if (s) |sess| (if (sess.alive) sess.child else null) else null;
        self.store.mutex.unlock();

        // Stable copy of the session_id for the reply (the parsed value is freed by
        // the trailing defer before sendJson runs through the writer queue).
        var id_buf: [64]u8 = undefined;
        const id_len = @min(req.session_id.len, id_buf.len);
        @memcpy(id_buf[0..id_len], req.session_id[0..id_len]);
        const id_copy = id_buf[0..id_len];

        const cwd: ?[]u8 = if (child) |c| c.queryCwd(self.alloc) else null;
        defer if (cwd) |p| self.alloc.free(p);

        self.sendJson(.cwd, channel, protocol.Cwd{
            .session_id = id_copy,
            .path = cwd,
            .ok = cwd != null,
            // POSITIVE existence signal (T06b): restore probes must be able to
            // tell "this session id is gone from the table" (safe to forget the
            // layout entry) apart from "the session exists but the cwd read
            // failed / child exited" (keep the entry; it is still attachable).
            .found = s != null,
        }) catch {};
    }

    /// `LIST_SESSIONS`: snapshot the entire session roster and reply with `SESSIONS`
    /// on the request channel. We build the reply array AND encode it while holding
    /// the store lock so the borrowed session strings (id/title/cwd/argv) stay valid
    /// through JSON encoding; `sendJson` only enqueues (the store→write_mutex lock
    /// order is the SAME one `bridgeData` already takes under the store lock, so
    /// there is no new deadlock risk). A pure in-memory snapshot — no OS I/O — so
    /// holding the lock across it is cheap (unlike `handleGetCwd`, which must query
    /// the OS and therefore unlocks first).
    fn handleListSessions(self: *Server, channel: u128) void {
        self.sendRoster(channel);
    }

    /// `SESSIONS_SUB`: start pushing the roster to this connection, and send one
    /// immediately so the subscriber starts from truth instead of waiting for the
    /// next change.
    fn handleSessionsSub(self: *Server) void {
        self.sessions_push = true;
        {
            // Under the mutex, and never after shutdown — same lifetime
            // discipline as the metrics pump (see `pumps_closed`).
            self.roster_mutex.lock();
            defer self.roster_mutex.unlock();
            if (self.roster_thread == null and !self.pumps_closed.load(.acquire)) {
                self.roster_stop = false;
                self.roster_thread = std.Thread.spawn(.{}, rosterPumpLoop, .{self}) catch null;
            }
        }
        // Send one immediately so the subscriber starts from truth rather than
        // waiting for the next change.
        self.sendRoster(protocol.control_channel);
    }

    /// Note that the roster CHANGED, so the pump sends a fresh one.
    ///
    /// Deliberately does not send inline. Several call sites run with
    /// `store.mutex` HELD — `bridgeExit` most importantly, which the pty reader
    /// invokes from inside the store's locked region (`session.zig`
    /// `onChildOutput`). Sending there would re-enter `store.mutex` via
    /// `sendRoster` and deadlock that thread on a non-recursive mutex, wedging
    /// the agent. So this only touches the roster mutex — never the store's —
    /// and is safe to call from anywhere, holding anything.
    ///
    /// Coalescing falls out for free: a burst of changes sets one flag and the
    /// pump sends one roster.
    fn markRosterDirty(self: *Server) void {
        if (!self.sessions_push) return;
        self.roster_mutex.lock();
        self.roster_dirty = true;
        self.roster_cond.signal();
        self.roster_mutex.unlock();
    }

    /// Roster pump: wait to be told the roster changed, then send it.
    ///
    /// LOCK ORDER: takes `roster_mutex` ONLY to read/clear the flag, and
    /// RELEASES it before `sendRoster` takes `store.mutex`. Never holds both, so
    /// it cannot invert against `markRosterDirty` (called under `store.mutex`).
    fn rosterPumpLoop(self: *Server) void {
        while (true) {
            self.roster_mutex.lock();
            while (!self.roster_dirty and !self.roster_stop and !self.closed) {
                self.roster_cond.wait(&self.roster_mutex);
            }
            const stop = self.roster_stop or self.closed;
            self.roster_dirty = false;
            self.roster_mutex.unlock();
            if (stop) return;
            self.sendRoster(protocol.control_channel);
        }
    }

    /// Stop + join the roster pump. Idempotent; safe with no pump running. MUST
    /// NOT outlive the Server (joined in `shutdown`).
    fn stopRosterPump(self: *Server) void {
        self.roster_mutex.lock();
        self.roster_stop = true;
        self.roster_cond.signal();
        const t = self.roster_thread;
        self.roster_thread = null;
        self.roster_mutex.unlock();
        if (t) |th| th.join();
    }

    /// Serialize the whole roster and send it on `channel` as a `sessions` frame
    /// — the same payload `LIST_SESSIONS` replies with, so a pushed roster and a
    /// polled one are byte-identical and the client needs one decode path.
    fn sendRoster(self: *Server, channel: u128) void {
        self.store.mutex.lock();
        defer self.store.mutex.unlock();

        var infos: std.ArrayListUnmanaged(protocol.SessionInfo) = .empty;
        defer infos.deinit(self.alloc);

        var it = self.store.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            // On OOM, stop and send what we have rather than dropping the reply.
            infos.append(self.alloc, .{
                .id = s.id_str[0..],
                .alive = s.alive,
                .exit_code = s.exit_code,
                .attached = s.bound,
                .activity = @tagName(s.state),
                .pid = s.pid,
                .title = if (s.title) |t| t else null,
                .cwd = if (s.cwd) |c| c else null,
                .argv = if (s.argv) |a| a else null,
                .created_at = s.created_ms,
                .last_activity = s.last_activity_ms,
                .pinned = s.pinned,
                .relaunchable = s.relaunchable,
                // Only meaningful for a live orphan; an attached or dead row
                // reports null so no reader ever times an attached session.
                .unattached_since = if (s.alive and !s.bound) s.unattached_since_ms else null,
                // T907: whether this session's shell can outlive the agent. A
                // recorded holder pipe IS the fact — it is what a starting agent
                // dials to re-adopt the session — so there is no second notion
                // of "holder-backed" that could disagree with adoption.
                .holder_backed = s.holder_pipe != null,
                // T545: what the shell is running right now. Already sampled for
                // the restart notice (T429); the roster is where a user scanning
                // their sessions can see "this one is running claude" — the only
                // answer there is for a plain shell pane, whose `argv` is null.
                .fg_cmd = if (s.fg_cmd) |f| f else null,
                // T552: the pane this session is bound to — the reverse of the
                // join `+list --json` answers, and the only direction that works
                // with the app closed, which is the state `+sessions` exists for.
                .pane_id = if (s.pane_id) |p| p else null,
            }) catch break;
        }

        self.sendJson(.sessions, channel, protocol.Sessions{
            .sessions = infos.items,
        }) catch {};
    }

    /// `SET_LAYOUT` (§5.4 cross-machine "Resume all", T18): store (or, with
    /// `delete`, remove) an OPAQUE per-window layout blob keyed by the owning
    /// viewer's manifest-entry id. The agent never parses the blob; it persists
    /// it verbatim so a viewer on another machine can pull it and rebuild the
    /// window topology. Reply `SET_LAYOUT_RESULT{ok}` on the request channel.
    fn handleSetLayout(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.SetLayout, self.alloc, payload) catch {
            self.sendJson(.set_layout_result, channel, protocol.SetLayoutResult{ .ok = false }) catch {};
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;

        var ok = true;
        if (req.delete) {
            self.store.removeLayout(req.key);
        } else if (req.blob) |blob| {
            self.store.setLayout(req.key, blob, req.session_ids) catch {
                ok = false;
            };
        } else {
            // No blob and not a delete: nothing to store.
            ok = false;
        }

        // Persist the updated set (best-effort; no-op when disabled). Runs after
        // the in-memory mutation so a subsequent agent restart re-materializes it.
        if (ok) self.store.persistLayouts();

        self.sendJson(.set_layout_result, channel, protocol.SetLayoutResult{ .ok = ok }) catch {};
    }

    /// `GET_LAYOUTS` (§5.4, T18): reply with every stored layout blob on the
    /// request channel. Snapshots owned copies under the store lock, then encodes
    /// + enqueues OUTSIDE it (the blobs can be large; unlike `handleListSessions`
    /// we don't hold the lock across encode).
    fn handleGetLayouts(self: *Server, channel: u128) void {
        const recs = self.store.snapshotLayouts(self.alloc) catch {
            // On OOM, still answer (empty) so the client gets a reply, not a timeout.
            self.sendJson(.layouts, channel, protocol.Layouts{}) catch {};
            return;
        };
        defer session.freeLayoutRecords(self.alloc, recs);

        var blobs: std.ArrayListUnmanaged(protocol.LayoutBlob) = .empty;
        defer blobs.deinit(self.alloc);
        for (recs) |r| {
            blobs.append(self.alloc, .{ .key = r.key, .blob = r.blob }) catch break;
        }

        self.sendJson(.layouts, channel, protocol.Layouts{
            .layouts = blobs.items,
        }) catch {};
    }

    /// `RELAUNCH` (§5.4 reboot floor, T12b): respawn a DEAD, relaunchable session
    /// (materialized from disk at start) — or idempotently rebind an already-alive
    /// one — under its recorded `argv`/`cwd`, re-keyed into the SAME session id +
    /// data channel, then stream fresh output and reply `RELAUNCHED` on that channel.
    ///
    /// Locking/spawn discipline mirrors `handleOpen`: validate + snapshot the
    /// relaunch inputs (argv/cwd copies, channel) UNDER the store lock, drop the
    /// lock, spawn the child OUTSIDE it (fork+exec must never run under the mutex
    /// that serializes every output chunk), then re-lock, re-find (the reaper could
    /// have evicted it during the spawn), install the child, and revive.
    fn handleRelaunch(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.Relaunch, self.alloc, payload) catch return;
        defer parsed.deinit();
        const req = parsed.value;

        // Stable copy of the session id for the reply/re-lookup (the parsed value is
        // freed by the trailing defer before the reply runs through the writer queue).
        var id_buf: [64]u8 = undefined;
        const id_len = @min(req.session_id.len, id_buf.len);
        @memcpy(id_buf[0..id_len], req.session_id[0..id_len]);
        const id_copy = id_buf[0..id_len];

        // Phase 1: validate + snapshot under the lock.
        self.store.mutex.lock();
        const s0 = self.store.table.getByIdStr(req.session_id);
        if (s0 == null) {
            self.store.mutex.unlock();
            // No such session — the client should fall back to a fresh OPEN.
            self.sendJson(.relaunched, protocol.control_channel, protocol.Relaunched{
                .session_id = id_copy,
                .ok = false,
                .found = false,
            }) catch {};
            return;
        }
        const s = s0.?;
        const channel = s.channel;

        if (s.alive) {
            // Already running (double RELAUNCH / a race): rebind to us + reply ok,
            // no respawn. The child reader is already attached to the store sink.
            self.bindLocked(s);
            const pid = s.pid;
            // Stable copy of the tty (wp3): the reply is sent after unlock, where
            // the session's string could be replaced/freed by a racing setTty.
            var tty_buf: [128]u8 = undefined;
            const tty_copy: ?[]const u8 = if (s.tty) |t| blk: {
                const n = @min(t.len, tty_buf.len);
                @memcpy(tty_buf[0..n], t[0..n]);
                break :blk tty_buf[0..n];
            } else null;
            self.store.mutex.unlock();
            self.sendJson(.relaunched, channel, protocol.Relaunched{
                .session_id = id_copy,
                .ok = true,
                .pid = pid,
                .found = true,
                .tty = tty_copy,
            }) catch {};
            return;
        }

        if (!s.relaunchable) {
            // A genuinely-exited tombstone with no relaunch metadata: found but not
            // relaunchable. The client shows the exited overlay (no auto-relaunch).
            self.store.mutex.unlock();
            self.sendJson(.relaunched, channel, protocol.Relaunched{
                .session_id = id_copy,
                .ok = false,
                .found = true,
            }) catch {};
            return;
        }

        // Snapshot the relaunch inputs into owned buffers so the spawn (unlocked)
        // can't race a concurrent free of the session's strings.
        const argv_copy: ?[]u8 = if (s.argv) |a| (self.alloc.dupe(u8, a) catch null) else null;
        defer if (argv_copy) |a| self.alloc.free(a);
        const cwd_copy: ?[]u8 = if (s.cwd) |c| (self.alloc.dupe(u8, c) catch null) else null;
        defer if (cwd_copy) |c| self.alloc.free(c);
        const pinned = s.pinned;
        // Refresh the recorded pane (T552) from the RELAUNCH's env, which is the
        // viewer's live answer to "which pane am I respawning this into". It
        // normally repeats what the OPEN recorded, since a pane id survives
        // restore by design — but a session materialized from a `sessions.json`
        // written by an agent too old to persist the field has none until now,
        // and this is the moment the viewer supplies it.
        if (protocol.Open.paneIdOf(req.env)) |pane| s.setPaneId(pane);
        self.store.mutex.unlock();

        // Phase 2: spawn the child OUTSIDE the lock. Synthesize an OPEN from the
        // recorded metadata (the recorded argv is treated as the command to run;
        // null → a plain login shell, the agent resolves its own default $SHELL)
        // PLUS the respawn-fidelity fields the viewer sent on the RELAUNCH (wp3):
        // env (GHOZTTY_PANE_ID & co.), TERM, and an explicit shell-integration
        // argv rewrite. When the viewer supplies argv (a plain interactive shell
        // with an argv-rewrite) it IS the full invocation, so the recorded
        // command label must not also run (same exclusivity as an original
        // OPEN). Older clients send none of these — recorded metadata alone,
        // the pre-wp3 behavior. `req`'s borrowed slices outlive the synchronous
        // spawn (parsed is freed at function exit).
        const open: protocol.Open = .{
            .command = if (req.argv != null) null else argv_copy,
            .cwd = cwd_copy,
            .rows = req.rows,
            .cols = req.cols,
            .px_w = req.px_w,
            .px_h = req.px_h,
            .pinned = pinned,
            .env = req.env,
            .term = req.term orelse "xterm-ghostty",
            .argv = req.argv,
        };
        const spawned = self.spawner.spawn(open) catch {
            // Spawn failed — the session stays a relaunchable tombstone; report
            // found-but-not-ok so the client can retry or show the overlay.
            self.sendJson(.relaunched, channel, protocol.Relaunched{
                .session_id = id_copy,
                .ok = false,
                .found = true,
            }) catch {};
            return;
        };

        // Phase 3: re-lock, re-find (the reaper could have evicted the tombstone
        // during the spawn), install the fresh child, and revive the session.
        self.store.mutex.lock();
        const s2 = self.store.table.getByIdStr(id_copy);
        if (s2 == null or s2.?.channel != channel or s2.?.alive) {
            // Gone, re-keyed, or already revived by a racing RELAUNCH — drop the
            // fresh child OUTSIDE the lock (terminate joins its reader).
            self.store.mutex.unlock();
            spawned.child.terminate();
            self.sendJson(.relaunched, channel, protocol.Relaunched{
                .session_id = id_copy,
                .ok = false,
                .found = s2 != null,
            }) catch {};
            return;
        }
        const rs = s2.?;
        rs.child = spawned.child; // replace the inert deadChild placeholder
        rs.pid = spawned.pid;
        rs.alive = true;
        rs.relaunchable = false;
        // Claimed: someone actually resumed this session, so it is not a stale
        // reboot-floor leftover. Reset the unclaimed-restart allowance
        // (`session_meta.Record.unclaimed_restarts`) or a session in daily use
        // could still age out of the file after a couple of restarts.
        rs.unclaimed_restarts = 0;
        rs.exit_code = null;
        // The vanish sweep's strike count described the OLD pid (T1162); a
        // respawned shell starts it over.
        rs.vanish_strikes = 0;
        rs.last_activity_ms = self.clock.now();
        // The sampled foreground command described the OLD child's world; a
        // respawned session starts at a fresh prompt, and the sampler will
        // re-record whatever runs next. Keeping it would let a later restart
        // notice name a command from two lifetimes ago (T429).
        rs.setFgCmd(null);
        // Fresh pty ⇒ fresh tty path (wp3); stable stack copy for the
        // after-unlock reply (`Result.tty` borrows child-owned storage).
        var tty_buf: [128]u8 = undefined;
        const tty_copy: ?[]const u8 = if (spawned.tty) |t| blk: {
            const n = @min(t.len, tty_buf.len);
            @memcpy(tty_buf[0..n], t[0..n]);
            break :blk tty_buf[0..n];
        } else null;
        rs.setTty(tty_copy);
        // Bind to THIS connection so live output frames flow to our writer.
        self.bindLocked(rs);
        // Same re-attach repaint latch as ATTACH: the client re-asserts geometry
        // with an authoritative RESIZE right after RELAUNCH; fire one SIGWINCH on
        // it so a relaunched full-screen program paints against the final size.
        rs.winch_on_next_resize = true;
        const pid = rs.pid;
        // Capture the replayed-scrollback capture geometry under the lock so the
        // reply (sent after unlock) can tell the viewer what width to replay at.
        const replay_cols = rs.replay_cols;
        const replay_rows = rs.replay_rows;
        const child = rs.child; // value copy of the vtable handle

        // Reboot scrollback (T13, §5.4): a session materialized from disk has its
        // pre-restart ring snapshot + the restart divider PRELOADED into the ring
        // (loadPersisted → preloadRingSnapshot), sitting at offsets
        // `[base, out_offset)`. The fresh child hasn't produced output yet (its
        // reader is attached below, after the unlock), so `out_offset` still marks
        // the end of that preloaded content. Copy it now (under the lock, ring
        // stable) and replay it to the reattaching viewer BEFORE the child's live
        // output — the client sees pre-restart scrollback → divider → fresh output,
        // with no offset hole (its relaunch pane keeps every byte from offset 0).
        //
        // The viewer's `notice` (if any) is appended to the ring FIRST, so it
        // rides the replay in the one slot where it is safe: after the restored
        // scrollback and the divider, before the respawned child's first byte.
        // The viewer's fallback is to inject the same bytes into its own terminal
        // the moment bring-up finishes, which RACES the child — for the `rerun`
        // policy that means it can disable the mouse tracking the re-run TUI has
        // just enabled, i.e. the opposite of what the reset is for. Ordering
        // against the child's output can only be done by the producer.
        //
        // `replayed` deliberately reports whether there was a real SNAPSHOT,
        // sampled BEFORE this append, so a notice on an otherwise-empty ring
        // doesn't make the viewer suppress its own divider.
        const had_snapshot = rs.ring.len > 0;
        // T1264: place the divider BEFORE the notice and before the replay copy.
        // The reboot path (agent restarted, ring preloaded from disk) already has
        // one and `appendRestartDivider` leaves it alone; a tombstone relaunched
        // under a still-running agent never had one, and the viewer suppresses its
        // own whenever anything was replayed (`replayed` below) — so on that path
        // the boundary between the dead session's output and the respawned child's
        // was simply missing. Only the producer can put it in the right place:
        // the viewer's inject is synchronous and would land ahead of the replay.
        session.SessionStore.appendRestartDivider(rs);
        if (req.notice) |notice| {
            if (notice.len > 0) {
                // Same append+advance the reboot divider does in
                // `preloadRingSnapshot`: `out_offset` must move with the ring or
                // the child's first output would claim these offsets too.
                const text = notice[0..@min(notice.len, protocol.Relaunch.max_notice_bytes)];
                rs.ring.append(rs.out_offset.value, text);
                rs.out_offset.value +%= text.len;
                rs.last_snapshot_offset = rs.out_offset.value;
            }
        }
        const replay_lo = rs.ring.base_offset;
        const replay_len = rs.ring.len;
        var replay_buf: ?[]u8 = null;
        var replay_n: usize = 0;
        if (replay_len > 0) {
            if (self.alloc.alloc(u8, replay_len)) |rb| {
                replay_buf = rb;
                replay_n = rs.ring.copyRetained(rb);
            } else |_| {}
        }
        self.store.mutex.unlock();

        // Replay the preloaded scrollback + divider first (outside the lock), so
        // its DATA frames are queued ahead of any live child output.
        if (replay_buf) |rb| {
            defer self.alloc.free(rb);
            if (replay_n > 0) self.sendData(channel, replay_lo, rb[0..replay_n]) catch {};
        }

        // Arm the durability gate before the reader exists, exactly as the OPEN
        // path does (T911) — a relaunched session gets a brand-new holder, and
        // its first seconds of output are as worth keeping as any other's.
        if (self.store.rings_dir != null and self.store.durable_ack) child.releaseTo(0);

        // Start the real child's reader routing output to the STORE sink on our
        // channel (done after unlock — the sink takes the store lock).
        child.attach(self.store, session.SessionStore.onChildOutputTrampoline, channel);

        self.sendJson(.relaunched, channel, protocol.Relaunched{
            .session_id = id_copy,
            .ok = true,
            .pid = pid,
            .found = true,
            // Tell the client we already replayed scrollback + the divider so it
            // suppresses its own snapshot-less divider (no double marker). This
            // means a real SNAPSHOT, sampled BEFORE any `notice` was appended —
            // a notice on an otherwise-empty ring must not read as scrollback.
            .replayed = had_snapshot and replay_n > 0,
            // Width the replayed bytes were drawn at (0 when unknown) so the client
            // can replay at that width then reflow — see Relaunched.replay_cols.
            .replay_cols = if (had_snapshot and replay_n > 0) replay_cols else 0,
            .replay_rows = if (had_snapshot and replay_n > 0) replay_rows else 0,
            // Where the respawned child's own output starts (T1264). Unlike
            // `replayed` this counts EVERYTHING queued ahead of it — divider and
            // notice included — because it is a stream position, not a claim
            // about scrollback.
            .replay_bytes = replay_lo + replay_n,
            .tty = tty_copy,
        }) catch {};

        // The alive set changed (a tombstone became alive) — refresh the on-disk
        // metadata so a subsequent restart re-materializes it.
        self.store.persistMeta();
        // A tombstone became alive again.
        self.markRosterDirty();
    }

    fn handlePing(self: *Server, payload: []const u8) void {
        // Echo the PING payload back verbatim as PONG (carries the client's
        // timestamp for RTT, §6.4). Payload is opaque to the agent.
        self.enqueue(.control, .pong, protocol.control_channel, payload) catch {};
    }

    fn handleFlow(self: *Server, payload: []const u8) void {
        const flow = protocol.Flow.decode(payload) catch return;
        self.store.mutex.lock();
        defer self.store.mutex.unlock();
        const s = self.store.table.getByChannel(flow.channel) orelse return;
        // OWNERSHIP GUARD (same rule as handleDetach): only the bridge-owning
        // connection may pause/resume the session's streaming — a stale FLOW
        // from a superseded connection must not wedge (or spuriously resume)
        // the new owner's stream.
        if (s.bridge_ctx != @as(?*anyopaque, self)) return;
        switch (flow.op) {
            .pause => s.streaming = false,
            .@"resume" => s.streaming = true,
            .credit => {}, // v2; ignored in v1
        }
    }

    // --- Host metrics push (§9.3) --------------------------------------------

    /// `METRICS_SUB`: record the requested interval and lazily spawn the pump thread
    /// (one per connection). A re-subscription just updates the interval; the running
    /// pump picks it up on its next loop. A malformed payload is ignored (untrusted).
    fn handleMetricsSub(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.MetricsSub, self.alloc, payload) catch return;
        defer parsed.deinit();
        // Clamp to a sane floor so a hostile/zero interval can't busy-spin the pump.
        const interval = @max(parsed.value.interval_ms, 50);

        // The spawn and the handle assignment happen UNDER the mutex, together
        // with the stop flag they pair with. Assigning outside it (as this used
        // to) let `stopMetricsPump` read a still-null handle, skip the join, and
        // leave a pump running past the Server's death — see `pumps_closed`.
        self.metrics_mutex.lock();
        defer self.metrics_mutex.unlock();
        self.metrics_interval_ms = interval;
        self.metrics_cond.signal(); // wake an existing pump to pick up a new interval
        if (self.metrics_thread != null) return;
        if (self.pumps_closed.load(.acquire)) return;
        self.metrics_stop = false;
        self.metrics_thread = std.Thread.spawn(.{}, metricsPumpLoop, .{self}) catch null;
    }

    /// `METRICS_UNSUB`: stop + join the pump (idempotent).
    fn handleMetricsUnsub(self: *Server) void {
        self.stopMetricsPump();
    }

    /// Signal the pump to stop, wake its timed wait, and join it. Idempotent and
    /// safe to call with no pump running. Called by `metrics_unsub` and `shutdown`.
    fn stopMetricsPump(self: *Server) void {
        self.metrics_mutex.lock();
        self.metrics_stop = true;
        self.metrics_interval_ms = 0;
        self.metrics_cond.signal();
        // TAKE the handle under the lock: exactly one caller can ever see it, so
        // two concurrent stops cannot both join the same thread and a concurrent
        // sub cannot slip a new one in behind us.
        const t = self.metrics_thread;
        self.metrics_thread = null;
        self.metrics_mutex.unlock();
        if (t) |th| th.join();
    }

    /// The metrics pump: own a `metrics.Sampler`, and until stopped, sample the host
    /// and push a `metrics` frame on the control channel, then wait `interval_ms`
    /// (a timed cond wait so stop wakes us immediately). Exits on stop or `closed`.
    fn metricsPumpLoop(self: *Server) void {
        var sampler = metrics.Sampler.init();
        while (true) {
            // Snapshot the interval + stop flag under the lock.
            self.metrics_mutex.lock();
            if (self.metrics_stop or self.closed) {
                self.metrics_mutex.unlock();
                return;
            }
            const interval_ms = self.metrics_interval_ms;
            self.metrics_mutex.unlock();

            const host = sampler.sample();
            self.sendJson(.metrics, protocol.control_channel, protocol.Metrics{
                .host = host,
            }) catch {};

            // Timed wait: wake early if stop is signalled mid-interval.
            self.metrics_mutex.lock();
            if (!self.metrics_stop and !self.closed) {
                self.metrics_cond.timedWait(
                    &self.metrics_mutex,
                    @as(u64, interval_ms) * std.time.ns_per_ms,
                ) catch {};
            }
            const stop = self.metrics_stop or self.closed;
            self.metrics_mutex.unlock();
            if (stop) return;
        }
    }

    // --- Per-session CPU push stream (`session_cpu`) --------------------------

    /// The cadence the agent actually uses for the per-session CPU stream.
    ///
    /// The client's `requested_ms` is a HINT, not a mandate. This is a push
    /// stream precisely so the machine doing the work decides how much work to
    /// do: the chooser has no idea whether the agent is idle or pinned, and a
    /// fixed client-side poll would hammer a box exactly when it can least
    /// afford it.
    ///
    /// So: clamp up to a floor (a hostile or zero interval must not busy-spin the
    /// pump), then stretch under load, then cap. The cap matters as much as the
    /// backoff — a throttle with no ceiling silently becomes a hang, and the
    /// client is told the real interval in every frame so it can distinguish a
    /// slow stream from a dead one.
    pub fn throttledIntervalMs(requested_ms: u32, host_cpu_pct: f32) u32 {
        const floor_ms: u32 = 500;
        const cap_ms: u32 = 10_000;
        var v: u32 = @max(requested_ms, floor_ms);
        if (host_cpu_pct >= 85) {
            v *|= 4;
        } else if (host_cpu_pct >= 60) {
            v *|= 2;
        }
        return @min(v, cap_ms);
    }

    /// `SESSION_CPU_SUB`: start (or re-interval) the per-session CPU pump.
    ///
    /// The spawn happens UNDER `session_cpu_mutex`, together with the
    /// `thread == null` test it depends on. Outside the lock, a concurrent
    /// `stopSessionCpuPump` could read the handle between the test and the
    /// assignment and either miss the new pump (it outlives the Server) or race
    /// the store. Spawning while holding the mutex does not deadlock: the new
    /// thread's first act is to take the same mutex, so it simply waits for the
    /// unlock below.
    fn handleSessionCpuSub(self: *Server, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.SessionCpuSub, self.alloc, payload) catch return;
        defer parsed.deinit();

        // Spawn + assign under the mutex, and never after shutdown latched
        // `pumps_closed` — same lifetime discipline as the metrics pump.
        self.session_cpu_mutex.lock();
        defer self.session_cpu_mutex.unlock();
        self.session_cpu_interval_ms = parsed.value.interval_ms;
        self.session_cpu_cond.broadcast(); // wake an existing pump for the new hint
        if (self.session_cpu_thread != null) return;
        if (self.pumps_closed.load(.acquire)) return;

        // A fresh pump gets a fresh generation, so any PREDECESSOR still winding
        // down exits on its own even though `stop` has just gone back to false.
        self.session_cpu_generation +%= 1;
        self.session_cpu_stop = false;
        self.session_cpu_thread = std.Thread.spawn(
            .{},
            sessionCpuPumpLoop,
            .{ self, self.session_cpu_generation },
        ) catch null;
    }

    /// `SESSION_CPU_UNSUB`: stop + join the pump (idempotent).
    fn handleSessionCpuUnsub(self: *Server) void {
        self.stopSessionCpuPump();
    }

    /// Signal the per-session CPU pump to stop, wake its timed wait, and join it.
    /// Idempotent and safe with no pump running. Called by `session_cpu_unsub` and
    /// `shutdown` — the pump MUST NOT outlive the Server.
    ///
    /// The handle is TAKEN under the mutex and joined outside it. Both halves
    /// matter:
    ///
    ///   * Taking it under the lock means two concurrent stoppers cannot both see
    ///     the same non-null handle. `Thread.join` on an already-joined handle
    ///     returns `EINVAL`, which std maps to `unreachable` — an agent PANIC, in a
    ///     process whose whole job is to outlive the app. The two stoppers are
    ///     real and adjacent: `session_cpu_unsub` arrives on the control-reader
    ///     thread while `shutdown` runs on the serve thread, which is exactly what
    ///     a client does when it unsubscribes and then drops the connection.
    ///   * Joining outside the lock is required for progress: the pump takes this
    ///     same mutex every iteration, so joining while holding it would deadlock.
    fn stopSessionCpuPump(self: *Server) void {
        self.session_cpu_mutex.lock();
        self.session_cpu_stop = true;
        self.session_cpu_interval_ms = 0;
        // Retire this generation too, so a pump that somehow misses the `stop`
        // flag (a re-subscribe flipping it back to false before the old pump has
        // observed it) still terminates.
        self.session_cpu_generation +%= 1;
        const thread = self.session_cpu_thread;
        self.session_cpu_thread = null;
        // `broadcast`, not `signal`: during a stop/re-subscribe overlap there can
        // briefly be two pumps waiting, and waking only one leaves the other
        // sleeping out its full interval before it notices it must exit.
        self.session_cpu_cond.broadcast();
        self.session_cpu_mutex.unlock();
        if (thread) |t| t.join();
    }

    /// The per-session CPU pump: sample the process table, roll each session's
    /// whole subtree up into one number, push a `session_cpu` frame, wait, repeat.
    ///
    /// Owns its OWN `ProcSampler`, deliberately. Per-process CPU% is a delta
    /// against per-pid baselines that each `sample()` REPLACES, so sharing the
    /// Server's request/reply `proc_sampler` would make this pump and `proc_list`
    /// silently destroy each other's deltas whenever their timings interleaved —
    /// the exact bug that made the local activity monitor report 0% for every row.
    /// `metricsPumpLoop` owns its own `metrics.Sampler` for the same reason.
    ///
    /// `generation` is the pump's identity. A stop retires the generation, so a
    /// pump whose `stop` flag was flipped back to false by a re-subscribe landing
    /// before it woke still exits — otherwise it would keep pushing frames beside
    /// its replacement, and the `join` waiting on it would never return.
    fn sessionCpuPumpLoop(self: *Server, generation: u64) void {
        var sampler = proc.ProcSampler.init(self.alloc);
        defer sampler.deinit();
        var host_sampler = metrics.Sampler.init();

        while (true) {
            self.session_cpu_mutex.lock();
            if (self.session_cpu_stop or self.closed or
                self.session_cpu_generation != generation)
            {
                self.session_cpu_mutex.unlock();
                return;
            }
            const requested = self.session_cpu_interval_ms;
            self.session_cpu_mutex.unlock();

            // How loaded are we? This decides the cadence, so sample it first.
            const host = host_sampler.sample();
            const interval_ms = throttledIntervalMs(requested, host.cpu_pct);

            self.pushSessionCpu(&sampler, interval_ms);

            self.session_cpu_mutex.lock();
            if (!self.session_cpu_stop and !self.closed and
                self.session_cpu_generation == generation)
            {
                self.session_cpu_cond.timedWait(
                    &self.session_cpu_mutex,
                    @as(u64, interval_ms) * std.time.ns_per_ms,
                ) catch {};
            }
            const stop = self.session_cpu_stop or self.closed or
                self.session_cpu_generation != generation;
            self.session_cpu_mutex.unlock();
            if (stop) return;
        }
    }

    /// One pump iteration: enumerate, roll up per session, send. Split out of the
    /// loop so every allocation is scoped to a single arena that dies here.
    fn pushSessionCpu(self: *Server, sampler: *proc.ProcSampler, interval_ms: u32) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var procs: std.ArrayListUnmanaged(protocol.Proc) = .empty;
        // The enumeration runs UNLOCKED — it queries the whole machine and touches
        // no session-store state (same discipline as `handleProcList`).
        _ = sampler.sample(aa, &procs, 0) catch return;

        // Snapshot session id + root pid under the store lock, copying the ids into
        // the arena. We must NOT hold the store mutex across the socket write, and
        // `id_str` lives on a session that could be reaped the moment we let go.
        var ids: std.ArrayListUnmanaged([]const u8) = .empty;
        var roots: std.ArrayListUnmanaged(i64) = .empty;
        {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            var it = self.store.table.by_id.valueIterator();
            while (it.next()) |sp| {
                const s = sp.*;
                // A dead session has no tree to roll up; reporting 0 for it would
                // be indistinguishable from an idle live one.
                if (!s.alive) continue;
                const id = aa.dupe(u8, s.id_str[0..]) catch break;
                ids.append(aa, id) catch break;
                roots.append(aa, s.pid) catch break;
            }
        }
        // NOTE: an empty roster still sends a frame. Skipping the push would mean
        // the client cannot tell a live-but-idle stream from a dead one, and — worse
        // — a client that had sessions and now has none would keep rendering the
        // last roster forever, because nothing ever told it they went away.
        const totals = aa.alloc(f32, roots.items.len) catch return;
        proc.rollUpByRoot(aa, procs.items, roots.items, totals);

        const rows = aa.alloc(protocol.SessionCpuRow, ids.items.len) catch return;
        for (ids.items, totals, 0..) |id, cpu, i| {
            rows[i] = .{ .id = id, .cpu_pct = cpu };
        }

        self.sendJson(.session_cpu, protocol.control_channel, protocol.SessionCpu{
            .interval_ms = interval_ms,
            .sessions = rows,
        }) catch {};
    }

    // --- Process table (§9.3 process view) -----------------------------------

    /// `PROC_LIST` (§9.3): enumerate the host's processes and reply
    /// `PROC_SNAPSHOT{ok, host, procs, truncated}` on the SAME request channel (the
    /// client correlates the reply by request channel, like `GET_CWD`/`CWD`).
    ///
    /// Synchronous request/reply — no pump thread. The OS enumeration runs UNLOCKED
    /// (it touches no session-store state; it queries the whole machine), matching the
    /// `handleGetCwd` discipline. `host.cpu_pct` here may read 0: a fresh local host
    /// `Sampler` has no prior tick baseline for a one-shot read — the panel subscribes
    /// to the live `metrics` stream separately for an accurate host CPU%. The
    /// per-process `proc_sampler` DOES persist baselines across `proc_list` calls, so
    /// repeated polls yield real per-process CPU%.
    ///
    /// All proc strings are owned by `self.alloc`; we free them (and the list) after
    /// `sendJson` has encoded the snapshot to JSON. On any error we reply `ok=false`.
    fn handleProcList(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.ProcList, self.alloc, payload) catch {
            self.sendJson(.proc_snapshot, channel, protocol.ProcSnapshot{ .ok = false }) catch {};
            return;
        };
        defer parsed.deinit();
        const limit: u32 = parsed.value.limit orelse 0;

        // A one-shot host sample (no baseline ⇒ cpu_pct may be 0; that's fine).
        var host_sampler = metrics.Sampler.init();
        const host = host_sampler.sample();

        var procs: std.ArrayList(protocol.Proc) = .empty;
        defer {
            for (procs.items) |p| {
                self.alloc.free(@constCast(p.name));
                if (p.user) |u| self.alloc.free(@constCast(u));
                if (p.cmd) |c| self.alloc.free(@constCast(c));
                if (p.tty) |t| self.alloc.free(@constCast(t));
            }
            procs.deinit(self.alloc);
        }

        const truncated = self.proc_sampler.sample(self.alloc, &procs, limit) catch {
            self.sendJson(.proc_snapshot, channel, protocol.ProcSnapshot{ .ok = false, .host = host }) catch {};
            return;
        };

        self.sendJson(.proc_snapshot, channel, protocol.ProcSnapshot{
            .ok = true,
            .host = host,
            .procs = procs.items,
            .truncated = truncated,
            .agent_pid = currentPid(),
        }) catch {};
    }

    /// This agent process's own pid, used by the client as the root of the
    /// "ghoztty-spawned" descendant tree. Cheap (one syscall); cross-OS.
    fn currentPid() i64 {
        if (builtin.os.tag == .windows) {
            const k32 = struct {
                extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
            };
            return @intCast(k32.GetCurrentProcessId());
        }
        return @intCast(std.c.getpid());
    }

    /// `PROC_KILL` (§9.3, inc 4): terminate the requested pid and reply
    /// `PROC_KILL_RESULT{pid, ok, error?}` on the SAME request channel (same-channel
    /// correlation, like `PROC_LIST`/`GET_CWD`). The OS kill runs UNLOCKED (it
    /// touches no session-store state). A malformed payload is ignored (untrusted).
    fn handleProcKill(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.ProcKill, self.alloc, payload) catch return;
        defer parsed.deinit();
        const pid = parsed.value.pid;

        const out = proc_control.killProc(pid, parsed.value.signal);
        self.sendJson(.proc_kill_result, channel, protocol.ProcKillResult{
            .pid = pid,
            .ok = out.ok,
            .@"error" = out.@"error",
        }) catch {};
    }

    /// `PROC_SPAWN` (§9.3, inc 5): launch a detached process via the platform shell
    /// and reply `PROC_SPAWN_RESULT{ok, pid?, error?}` on the request channel. The
    /// spawn runs UNLOCKED. A malformed payload is ignored (untrusted).
    fn handleProcSpawn(self: *Server, channel: u128, payload: []const u8) void {
        var parsed = protocol.parseJson(protocol.ProcSpawn, self.alloc, payload) catch return;
        defer parsed.deinit();

        // Spawn via the injected spawner (keeps `CommandCore` out of server.zig's
        // graph — see `proc_spawn.zig`). Runs UNLOCKED (no session-store state).
        const out = self.spawner.spawnDetached(parsed.value.cmd, parsed.value.cwd);
        // The Windows path may return an ALLOCATED diagnostic note in `@"error"`
        // (free_error). `sendJson` encodes synchronously, so free after it returns.
        defer if (out.free_error) {
            if (out.@"error") |m| self.alloc.free(@constCast(m));
        };
        self.sendJson(.proc_spawn_result, channel, protocol.ProcSpawnResult{
            .ok = out.ok,
            .pid = out.pid,
            .@"error" = out.@"error",
        }) catch {};
    }

    // --- Inbound DATA (client keystrokes) ------------------------------------

    fn handleInboundData(self: *Server, frame: protocol.Frame) void {
        const dp = protocol.DataPayload.decode(frame.payload) catch return;

        // Snapshot the owning session's child handle under the lock, then write
        // OUTSIDE it. `writeAll` is a blocking PTY/ConPTY input-pipe write that can
        // stall INDEFINITELY when the pipe is back-pressured or the peer conhost has
        // wedged. Holding the DAEMON-SCOPED `store.mutex` across it would wedge EVERY
        // session on this agent — both input (other `handleInboundData`s) AND output
        // (the child-output sink also takes `store.mutex`) — which is the remote-
        // window "sits there not responding" bug. A `session.Child` is a value-copy
        // vtable handle that stays valid until the child is `terminate`d, and CLOSE
        // only terminates AFTER unlinking under this lock, so the worst case is the
        // write failing gracefully, never a use-after-free of the table entry. (Same
        // lock→snapshot→unlock→IO discipline as `handleGetCwd`.)
        self.store.mutex.lock();
        const s = self.store.table.getByChannel(frame.channel);
        const child: ?session.Child = if (s) |sess| (if (sess.alive) sess.child else null) else null;
        self.store.mutex.unlock();

        // A short/failed write is non-fatal here.
        if (child) |c| c.writeAll(dp.bytes) catch {};
    }
};

// =============================================================================
// Tests — deterministic, over an in-memory loopback with a mock client
// =============================================================================

const testing = std.testing;
const all_encodings = [_]protocol.TransferEncoding{ .raw, .cobs, .base64 };

/// Wall-clock waiter for cross-thread effects (T346) — see test_util.zig.
const waitUntil = @import("test_util.zig").waitUntil;

// --- ByteFifo: thread-safe blocking byte pipe (mirrors connection.zig) --------

const ByteFifo = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    closed: bool = false,
    /// When set, `read` on an empty fifo gives up after this long with
    /// `error.LoopbackReadTimeout` instead of blocking forever. A liveness
    /// bound like `waitUntil`'s (T346), not a performance assertion: generous
    /// enough that a loaded box cannot spend it, so it only fires when the
    /// awaited bytes NEVER come — the T258 hang, where a test wedged ~11 min
    /// in this wait with no failure text. Left null on the agent-side
    /// direction, where idling between frames is the normal state.
    read_deadline_ns: ?u64 = null,
    alloc: Allocator,

    fn init(alloc: Allocator) ByteFifo {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *ByteFifo) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }
    fn write(self: *ByteFifo, bytes: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        try self.buf.appendSlice(self.alloc, bytes);
        self.cond.signal();
        return bytes.len;
    }
    fn read(self: *ByteFifo, dst: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.read_deadline_ns) |deadline_ns| {
            var timer = std.time.Timer.start() catch unreachable;
            while (self.head == self.buf.items.len and !self.closed) {
                const elapsed = timer.read();
                if (elapsed >= deadline_ns) return error.LoopbackReadTimeout;
                self.cond.timedWait(&self.mutex, deadline_ns - elapsed) catch {};
            }
        } else {
            while (self.head == self.buf.items.len and !self.closed) {
                self.cond.wait(&self.mutex);
            }
        }
        const avail = self.buf.items[self.head..];
        if (avail.len == 0) return 0;
        const n = @min(avail.len, dst.len);
        @memcpy(dst[0..n], avail[0..n]);
        self.head += n;
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
        }
        return n;
    }
    fn close(self: *ByteFifo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

// --- Loopback: client Stream + agent Stream over two ByteFifos ----------------

const Loopback = struct {
    client_to_agent: ByteFifo,
    agent_to_client: ByteFifo,

    /// Liveness bound for the CLIENT-read direction (agent → client). Every
    /// test wait for a frame — handshake reply, `waitControl`, `nextData` —
    /// funnels through this one read, so bounding it means a frame that never
    /// arrives fails the waiting test red instead of wedging the whole lane
    /// (T258: ~11 minutes of flat CPU, killed by hand, no failure text). The
    /// agent-side direction stays unbounded: a server idling between client
    /// frames is the normal state, and close() wakes it at teardown.
    /// 60s to match `waitUntil`'s bound: a box loaded enough to spend 10s of
    /// one liveness bound (T183) gets the same margin on this one.
    const client_read_deadline_ns: u64 = 60 * std.time.ns_per_s;

    fn init(alloc: Allocator) Loopback {
        var lb: Loopback = .{
            .client_to_agent = ByteFifo.init(alloc),
            .agent_to_client = ByteFifo.init(alloc),
        };
        lb.agent_to_client.read_deadline_ns = client_read_deadline_ns;
        return lb;
    }
    fn deinit(self: *Loopback) void {
        self.client_to_agent.deinit();
        self.agent_to_client.deinit();
    }
    /// The agent's view: writes → agent_to_client, reads ← client_to_agent.
    fn agentStream(self: *Loopback) Stream {
        return .{ .ctx = self, .vtable = &agent_vtable };
    }
    /// The client's view: writes → client_to_agent, reads ← agent_to_client.
    fn clientStream(self: *Loopback) Stream {
        return .{ .ctx = self, .vtable = &client_vtable };
    }
    const agent_vtable: Stream.VTable = .{ .read = agentRead, .write = agentWrite, .close = closeBoth };
    const client_vtable: Stream.VTable = .{ .read = clientRead, .write = clientWrite, .close = closeBoth };
    fn agentRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.client_to_agent.read(buf);
    }
    fn agentWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.agent_to_client.write(bytes);
    }
    fn clientRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.agent_to_client.read(buf);
    }
    fn clientWrite(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        return self.client_to_agent.write(bytes);
    }
    fn closeBoth(ctx: *anyopaque) void {
        const self: *Loopback = @ptrCast(@alignCast(ctx));
        self.client_to_agent.close();
        self.agent_to_client.close();
    }
};

test "ByteFifo: a deadlined read fails cleanly instead of wedging" {
    // The T258 hang: a test whose expected frame never arrives used to block
    // forever in ByteFifo.read's untimed cond.wait — 11 minutes of flat CPU
    // with no failure text until something killed the lane. A bounded read
    // turns that wedge into a red assert that names the waiting test.
    var fifo = ByteFifo.init(testing.allocator);
    defer fifo.deinit();
    fifo.read_deadline_ns = 50 * std.time.ns_per_ms;
    var buf: [16]u8 = undefined;
    try testing.expectError(error.LoopbackReadTimeout, fifo.read(&buf));
    // Data present → returned normally; the deadline is a liveness bound only.
    _ = try fifo.write("ok");
    try testing.expectEqual(@as(usize, 2), try fifo.read(&buf));
    // Closed → EOF (0), never a timeout error.
    fifo.close();
    try testing.expectEqual(@as(usize, 0), try fifo.read(&buf));
}

// --- A fixed test clock -------------------------------------------------------

const TestClock = struct {
    ms: i64 = 0,
    fn clock(self: *TestClock) Clock {
        return .{ .ctx = self, .nowFn = now };
    }
    fn now(ctx: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        return self.ms;
    }
};

// --- Fake child + spawner -----------------------------------------------------

/// A buffer-backed fake child. Keystrokes land in `input`. Output is delivered to
/// the server out-of-band by the test (calling `server.onChildOutput`), so the
/// child itself only sinks input and records control ops. `exit_code` is set by
/// the test to simulate the process exiting; `tryWait` then returns it.
const FakeChild = struct {
    input: std.ArrayList(u8) = .empty,
    /// Written by the server's control thread (`rz`/`sg`), read by the test
    /// thread — both only under `mutex` (the accessors below). `last_signal`
    /// is an OWNED copy: the vtable hands `sg` a slice into the control frame
    /// being parsed, whose lifetime ends with the handler.
    last_resize: ?[4]u16 = null,
    last_signal: ?[]u8 = null,
    exit_code: ?i64 = null,
    terminated: bool = false,
    /// When set, `queryCwd` returns a copy of this (models the OS cwd read). When
    /// null the vtable's `queryCwd` is still wired but returns null (query failed).
    fake_cwd: ?[]const u8 = null,
    /// When nonzero, `queryForegroundPid` reports this (models `tcgetpgrp` on the
    /// pty master, wp3). Zero → null (Windows / query failed / no fg tracking).
    fake_fg_pid: i64 = 0,
    /// Optional write gate (wedge test): when both are set, `write` signals
    /// `gate_entered` and then BLOCKS on `gate_release` before sinking the bytes —
    /// modeling a stalled ConPTY input pipe whose `WriteFile` never returns. Lets a
    /// test observe whether the agent holds the global store lock across a blocked
    /// child write. Null in every other test (no behavior change).
    gate_entered: ?*std.Thread.ResetEvent = null,
    gate_release: ?*std.Thread.ResetEvent = null,
    /// Optional terminate gate (T326): when both are set, `terminate` signals
    /// `term_gate_entered` and then BLOCKS on `term_gate_release` before marking
    /// the child terminated — modeling a slow child teardown (a real process
    /// kill plus persistence can take seconds). Lets a test assert that an RPC
    /// reply is NOT gated on the teardown. Null in every other test.
    term_gate_entered: ?*std.Thread.ResetEvent = null,
    term_gate_release: ?*std.Thread.ResetEvent = null,
    mutex: std.Thread.Mutex = .{},
    alloc: Allocator,

    fn child(self: *FakeChild) session.Child {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: session.Child.VTable = .{
        .write = wr,
        .resize = rz,
        .signal = sg,
        .tryWait = tw,
        .terminate = tm,
        .queryCwd = qcwd,
        .queryForegroundPid = qfg,
    };
    fn qcwd(ctx: *anyopaque, alloc: Allocator) ?[]u8 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        const c = self.fake_cwd orelse return null;
        return alloc.dupe(u8, c) catch null;
    }
    fn qfg(ctx: *anyopaque) ?i64 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.fake_fg_pid == 0) return null;
        return self.fake_fg_pid;
    }
    fn wr(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        // Optional wedge gate: announce we're inside the write, then block until
        // the test releases us (models a stalled ConPTY input pipe).
        if (self.gate_entered) |e| e.set();
        if (self.gate_release) |r| r.wait();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.input.appendSlice(self.alloc, bytes);
        return bytes.len;
    }
    fn rz(ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.last_resize = .{ rows, cols, px_w, px_h };
    }
    fn sg(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        const copy = try self.alloc.dupe(u8, name);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_signal) |s| self.alloc.free(s);
        self.last_signal = copy;
    }
    fn tw(ctx: *anyopaque) ?i64 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exit_code;
    }
    fn tm(ctx: *anyopaque) void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        // Optional teardown gate: announce we're inside terminate, then block
        // until the test releases us (models a slow child teardown).
        if (self.term_gate_entered) |e| e.set();
        if (self.term_gate_release) |r| r.wait();
        // Under the mutex like `tw`/`setExit`: `terminate` runs on whichever
        // thread handled CLOSE, while the test thread reads the flag.
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminated = true;
    }

    /// Read `terminated` under the mutex. Tests must use this rather than
    /// touching the field: the writer is a different thread.
    fn wasTerminated(self: *FakeChild) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.terminated;
    }

    /// Wait (wall-clock bounded) until the child has been terminated.
    ///
    /// The reason this exists rather than tests asserting straight after the
    /// session disappears from the store: `handleClose` is deliberately
    /// two-phase — it UNLINKS under the store lock and terminates the child
    /// OUTSIDE it, because `terminate` joins the pty reader whose sink takes
    /// that same lock. So "the session is gone" becomes true STRICTLY BEFORE
    /// "the child was terminated", and a test that waits for the first and
    /// asserts the second fails whenever it wins that gap (~1 run in 8 here).
    /// The product ordering is correct; the tests were watching the wrong edge.
    fn waitTerminated(self: *FakeChild) bool {
        return waitUntil("the child to be terminated", wasTerminated, .{self});
    }
    fn inputCopy(self: *FakeChild, alloc: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return alloc.dupe(u8, self.input.items);
    }
    /// Read `last_resize` under the mutex (the writer is the control thread).
    fn lastResize(self: *FakeChild) ?[4]u16 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_resize;
    }
    /// Whether the recorded signal equals `want`, under the mutex.
    fn lastSignalIs(self: *FakeChild, want: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.last_signal orelse return false;
        return std.mem.eql(u8, s, want);
    }
    fn setExit(self: *FakeChild, code: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.exit_code = code;
    }
    fn deinit(self: *FakeChild) void {
        if (self.last_signal) |s| self.alloc.free(s);
        self.input.deinit(self.alloc);
    }
};

/// A spawner that hands out pre-created FakeChildren in order. Lets the test keep
/// direct handles to each child for assertions/output feeding.
const FakeSpawner = struct {
    children: []*FakeChild,
    next: usize = 0,
    pid_base: i64 = 1000,
    /// Reported as `Result.tty` (wp3) — the fake analogue of the real spawner's
    /// pty-slave path. Null models a Windows/no-tty spawn.
    tty: ?[]const u8 = null,

    /// Captured from the LAST spawn's OPEN (owned fixed-buffer copies — the
    /// OPEN's memory is freed when the handler returns), so relaunch-fidelity
    /// tests (wp3) can assert the viewer-sent env/TERM reached the respawn.
    last_env_count: usize = 0,
    last_env_key_buf: [64]u8 = undefined,
    last_env_key_len: usize = 0,
    last_env_val_buf: [64]u8 = undefined,
    last_env_val_len: usize = 0,
    last_term_buf: [32]u8 = undefined,
    last_term_len: usize = 0,
    /// The LAST spawn's `OPEN.cwd` (T132): null when the OPEN carried none, so a
    /// test can tell "spawned in the recorded directory" from "spawned wherever
    /// the agent happened to be".
    last_cwd_buf: [128]u8 = undefined,
    last_cwd_len: ?usize = null,

    fn lastCwd(self: *const FakeSpawner) ?[]const u8 {
        const len = self.last_cwd_len orelse return null;
        return self.last_cwd_buf[0..len];
    }

    fn lastEnvKey(self: *const FakeSpawner) []const u8 {
        return self.last_env_key_buf[0..self.last_env_key_len];
    }
    fn lastEnvValue(self: *const FakeSpawner) []const u8 {
        return self.last_env_val_buf[0..self.last_env_val_len];
    }
    fn lastTerm(self: *const FakeSpawner) []const u8 {
        return self.last_term_buf[0..self.last_term_len];
    }

    fn spawner(self: *FakeSpawner) Spawner {
        return .{ .ctx = self, .spawnFn = spawn, .spawnDetachedFn = spawnDetached };
    }
    fn spawn(ctx: *anyopaque, open: protocol.Open) anyerror!Spawner.Result {
        const self: *FakeSpawner = @ptrCast(@alignCast(ctx));
        if (self.next >= self.children.len) return error.NoMoreChildren;
        self.last_env_count = open.env.len;
        if (open.env.len > 0) {
            self.last_env_key_len = @min(open.env[0].key.len, self.last_env_key_buf.len);
            @memcpy(self.last_env_key_buf[0..self.last_env_key_len], open.env[0].key[0..self.last_env_key_len]);
            self.last_env_val_len = @min(open.env[0].value.len, self.last_env_val_buf.len);
            @memcpy(self.last_env_val_buf[0..self.last_env_val_len], open.env[0].value[0..self.last_env_val_len]);
        }
        self.last_term_len = @min(open.term.len, self.last_term_buf.len);
        @memcpy(self.last_term_buf[0..self.last_term_len], open.term[0..self.last_term_len]);
        if (open.cwd) |c| {
            const n = @min(c.len, self.last_cwd_buf.len);
            @memcpy(self.last_cwd_buf[0..n], c[0..n]);
            self.last_cwd_len = n;
        } else self.last_cwd_len = null;
        const fc = self.children[self.next];
        self.next += 1;
        return .{ .child = fc.child(), .pid = self.pid_base + @as(i64, @intCast(self.next)), .tty = self.tty };
    }
    /// REAL detached spawn so the `PROC_SPAWN`→`PROC_KILL` round-trip test
    /// exercises a genuine OS process. Uses `std.process.Child` directly (std-only,
    /// so this stays out of `CommandCore` and keeps `server.zig`'s graph importable
    /// by the client transport — the real agent injects `proc_spawn.spawnDetached`
    /// via `pty_child`). POSIX-only (the agent tests skip on Windows).
    fn spawnDetached(_: *anyopaque, cmd: []const u8, cwd: ?[]const u8) Spawner.SpawnResult {
        if (builtin.os.tag == .windows) return .{ .ok = false, .@"error" = "unsupported in test" };
        var child = std.process.Child.init(&.{ "/bin/sh", "-lc", cmd }, std.heap.page_allocator);
        child.cwd = cwd;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch |err| return .{ .ok = false, .@"error" = @errorName(err) };
        return .{ .ok = true, .pid = @intCast(child.id) };
    }
};

// --- MockClient: drives the agent over the loopback ---------------------------

/// A minimal client: handshakes, sends control/data frames, and reads/decodes the
/// agent's frames. Single-threaded with blocking reads — the test sequences it.
const MockClient = struct {
    control: Stream,
    data: Stream,
    encoding: protocol.TransferEncoding,
    ctrl_reader: protocol.Reader,
    data_reader: protocol.Reader,
    scratch: [read_buf_size]u8 = undefined,
    alloc: Allocator,

    fn init(alloc: Allocator, control: Stream, data: Stream, enc: protocol.TransferEncoding) MockClient {
        return .{
            .control = control,
            .data = data,
            .encoding = enc,
            .ctrl_reader = protocol.Reader.init(alloc, enc),
            .data_reader = protocol.Reader.init(alloc, enc),
            .alloc = alloc,
        };
    }
    fn deinit(self: *MockClient) void {
        self.ctrl_reader.deinit();
        self.data_reader.deinit();
    }

    fn sendFrameOn(self: *MockClient, stream: Stream, frame: protocol.Frame) !void {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.alloc);
        try protocol.writeFrame(self.alloc, self.encoding, frame, &wire);
        try stream.writeAll(wire.items);
    }
    fn sendControlJson(self: *MockClient, ftype: protocol.FrameType, channel: u128, value: anytype) !void {
        const json = try protocol.encodeJson(self.alloc, value);
        defer self.alloc.free(json);
        try self.sendFrameOn(self.control, .{ .type = ftype, .channel = channel, .seq = 0, .payload = json });
    }
    fn sendControlRaw(self: *MockClient, ftype: protocol.FrameType, channel: u128, payload: []const u8) !void {
        try self.sendFrameOn(self.control, .{ .type = ftype, .channel = channel, .seq = 0, .payload = payload });
    }
    fn sendDataInput(self: *MockClient, channel: u128, byte_offset: u64, bytes: []const u8) !void {
        const payload = try self.alloc.alloc(u8, protocol.DataPayload.encodedLen(bytes.len));
        defer self.alloc.free(payload);
        const dp: protocol.DataPayload = .{ .byte_offset = byte_offset, .bytes = bytes };
        _ = dp.encodeInto(payload);
        try self.sendFrameOn(self.data, .{ .type = .data, .channel = channel, .seq = 0, .payload = payload });
    }

    /// Read one control frame (blocking). null on EOF. Payload borrows the reader.
    fn nextControl(self: *MockClient) !?protocol.Frame {
        return self.nextOn(self.control, &self.ctrl_reader);
    }
    fn nextData(self: *MockClient) !?protocol.Frame {
        return self.nextOn(self.data, &self.data_reader);
    }
    fn nextOn(self: *MockClient, stream: Stream, reader: *protocol.Reader) !?protocol.Frame {
        while (true) {
            if (try reader.next()) |f| return f;
            const n = try stream.read(&self.scratch);
            if (n == 0) return null;
            try reader.push(self.scratch[0..n]);
        }
    }

    /// Send the client HELLO and consume the agent's HELLO reply.
    fn handshake(self: *MockClient) !void {
        // Advertise the app-side capabilities so capability negotiation (e.g.
        // close_session) reflects a modern peer, like the real Connection client.
        const caps = [_][]const u8{protocol.capability.close_session};
        try self.handshakeCaps(&caps);
    }
    /// HELLO with an explicit capability set (for negotiation tests, e.g.
    /// advertising — or withholding — `grid_snapshot`).
    fn handshakeCaps(self: *MockClient, caps: []const []const u8) !void {
        const hello: protocol.Hello = .{ .transfer_encoding = self.encoding, .capabilities = caps };
        const json = try hello.encode(self.alloc);
        defer self.alloc.free(json);
        try self.sendFrameOn(self.control, .{
            .type = .hello,
            .channel = protocol.control_channel,
            .seq = 0,
            .payload = json,
        });
        const reply = (try self.nextControl()) orelse return error.NoAgentHello;
        try testing.expectEqual(protocol.FrameType.hello, reply.type);
    }

    /// Skip control frames until one of `want` type; returns it.
    fn waitControl(self: *MockClient, want: protocol.FrameType) !protocol.Frame {
        while (true) {
            const f = (try self.nextControl()) orelse return error.Eof;
            if (f.type == want) return f;
        }
    }
};

/// Build a server + a mock client wired over two loopbacks, all on `enc`. Owns a
/// daemon-scoped `SessionStore` (shared registry), mirroring production: the store
/// outlives the Server, so tests reach the table via `h.server.store.{mutex,table}`.
const Harness = struct {
    alloc: Allocator,
    ctrl_lb: *Loopback,
    data_lb: *Loopback,
    store: *session.SessionStore,
    server: *Server,
    client: MockClient,
    clock: *TestClock,
    spawner: *FakeSpawner,

    fn init(
        alloc: Allocator,
        enc: protocol.TransferEncoding,
        clock: *TestClock,
        spawner: *FakeSpawner,
        ring_bytes: usize,
        rng: std.Random,
    ) !Harness {
        const ctrl_lb = try alloc.create(Loopback);
        ctrl_lb.* = Loopback.init(alloc);
        const data_lb = try alloc.create(Loopback);
        data_lb.* = Loopback.init(alloc);

        const store = try alloc.create(session.SessionStore);
        // No reaper thread in tests (deterministic): idle reaping is invoked
        // explicitly via `store.reapIdle()` where a test wants it. A huge TTL keeps
        // sessions from ever idling out under the fixed test clock.
        store.* = session.SessionStore.init(alloc, rng, clock, TestClock.now, std.math.maxInt(i64));

        const server = try Server.create(
            alloc,
            ctrl_lb.agentStream(),
            data_lb.agentStream(),
            spawner.spawner(),
            store,
            .{
                .encoding = enc,
                .ring_bytes = ring_bytes,
                .clock = clock.clock(),
            },
        );
        const client = MockClient.init(alloc, ctrl_lb.clientStream(), data_lb.clientStream(), enc);
        return .{
            .alloc = alloc,
            .ctrl_lb = ctrl_lb,
            .data_lb = data_lb,
            .store = store,
            .server = server,
            .client = client,
            .clock = clock,
            .spawner = spawner,
        };
    }

    fn deinit(self: *Harness) void {
        self.server.shutdown();
        self.client.deinit();
        self.server.destroy(self.alloc);
        self.store.deinit();
        self.alloc.destroy(self.store);
        self.ctrl_lb.deinit();
        self.data_lb.deinit();
        self.alloc.destroy(self.ctrl_lb);
        self.alloc.destroy(self.data_lb);
    }
};

/// Read `OPENED` and return (session_id_copy, channel). The OPENED frame's channel
/// IS the session's data channel (the agent sends OPENED on it).
fn doOpen(h: *Harness, open: protocol.Open) !struct { id: [32]u8, channel: u128 } {
    try h.client.sendControlJson(.open, protocol.control_channel, open);
    const f = try h.client.waitControl(.opened);
    var parsed = try protocol.parseJson(protocol.Opened, h.alloc, f.payload);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 32), parsed.value.session_id.len);
    var id: [32]u8 = undefined;
    @memcpy(&id, parsed.value.session_id[0..32]);
    return .{ .id = id, .channel = f.channel };
}

test "handshake: agent echoes pinned encoding, negotiates" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var clock: TestClock = .{};
        var fc: FakeChild = .{ .alloc = alloc };
        defer fc.deinit();
        var kids = [_]*FakeChild{&fc};
        var sp: FakeSpawner = .{ .children = &kids };
        var prng = std.Random.DefaultPrng.init(1);

        var h = try Harness.init(alloc, enc, &clock, &sp, 4096, prng.random());
        defer h.deinit();
        try h.server.start();
        try h.client.handshake();
        const neg = try h.server.waitHandshake();
        try testing.expectEqual(enc, neg.transfer_encoding);
        try testing.expectEqual(protocol.proto_version, neg.proto_version);
    }
}

test "GET_CWD→CWD: agent replies with the child's queried cwd on the request channel" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc, .fake_cwd = "/private/tmp" };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(7);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const opened = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Issue GET_CWD on a fresh request channel; the agent must echo CWD on it.
    const req_ch: u128 = 0xC0FFEE;
    try h.client.sendControlJson(.get_cwd, req_ch, protocol.GetCwd{
        .session_id = opened.id[0..],
    });
    const reply = try h.client.waitControl(.cwd);
    try testing.expectEqual(req_ch, reply.channel);
    var parsed = try protocol.parseJson(protocol.Cwd, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(parsed.value.ok);
    try testing.expect(parsed.value.path != null);
    try testing.expectEqualStrings("/private/tmp", parsed.value.path.?);
    try testing.expectEqualStrings(opened.id[0..], parsed.value.session_id);
    try testing.expectEqual(@as(?bool, true), parsed.value.found);
}

test "WEDGE: a session's blocking child write must NOT hold the global store lock" {
    // Reproduction + regression guard for the agent WEDGE. handleInboundData used
    // to call child.writeAll() WHILE HOLDING the daemon-scoped store.mutex. On
    // Windows a stalled ConPTY input pipe makes that WriteFile block indefinitely,
    // so the GLOBAL store lock is held indefinitely and EVERY other session wedges
    // — input (handleInboundData) AND output (the child-output sink also takes
    // store.mutex). Symptom: a remote window "sits there not responding", `exit`
    // never reaches the shell. The fix snapshots the child handle under the lock,
    // releases the lock, THEN writes (same pattern as handleGetCwd). This test
    // asserts the store lock is ACQUIRABLE while one session's child write blocks.
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var gate_entered: std.Thread.ResetEvent = .{};
    var gate_release: std.Thread.ResetEvent = .{};
    var fc: FakeChild = .{
        .alloc = alloc,
        .gate_entered = &gate_entered,
        .gate_release = &gate_release,
    };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(99);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit(); // runs LAST: joins the data thread (released below first)
    defer gate_release.set(); // runs BEFORE deinit so the blocked write can finish
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const opened = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Send keystrokes: the agent's data thread enters child.writeAll and BLOCKS
    // there (gate held), modeling a stalled input pipe.
    try h.client.sendDataInput(opened.channel, 0, "exit\r");
    // Bounded for the same reason as Loopback's client reads (T258): if the
    // DATA never reaches the gated write, fail here red rather than wedge.
    try gate_entered.timedWait(Loopback.client_read_deadline_ns); // the data thread is now inside the blocking write

    // THE ASSERTION: with that write in flight, the global store lock must be FREE.
    // Pre-fix the data thread holds store.mutex for the whole blocked write, so a
    // concurrent session (or the output sink) can never make progress → tryLock
    // returns false → wedge. Post-fix the lock was released before the write.
    const acquired = h.store.mutex.tryLock();
    if (acquired) h.store.mutex.unlock();
    try testing.expect(acquired);
}

test "GET_CWD→CWD: unknown session replies ok=false (graceful, no crash)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(8);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.get_cwd, 0xABCD, protocol.GetCwd{
        .session_id = "ffffffffffffffffffffffffffffffff",
    });
    const reply = try h.client.waitControl(.cwd);
    var parsed = try protocol.parseJson(protocol.Cwd, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(!parsed.value.ok);
    try testing.expect(parsed.value.path == null);
    // POSITIVE not-found (T06b): an unknown id must report found=false so a
    // restore probe may safely forget it (vs. a transient cwd-read failure).
    try testing.expectEqual(@as(?bool, false), parsed.value.found);
}

test "LIST_SESSIONS→SESSIONS: agent enumerates its sessions on the request channel" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc0: FakeChild = .{ .alloc = alloc };
    var fc1: FakeChild = .{ .alloc = alloc };
    defer fc0.deinit();
    defer fc1.deinit();
    var kids = [_]*FakeChild{ &fc0, &fc1 };
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(11);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Open two sessions: one with an explicit command AND pinned (persistent
    // local pane, T11), one falling back to shell and unpinned (cross-machine).
    const o0 = try doOpen(&h, .{ .rows = 24, .cols = 80, .command = "run-marker-0", .pinned = true });
    const o1 = try doOpen(&h, .{ .rows = 30, .cols = 100, .shell = "/bin/zsh" });

    // LIST_SESSIONS on a fresh request channel; the agent echoes SESSIONS on it.
    const req_ch: u128 = 0x5E5510;
    try h.client.sendControlJson(.list_sessions, req_ch, protocol.ListSessions{});
    const reply = try h.client.waitControl(.sessions);
    try testing.expectEqual(req_ch, reply.channel);

    var parsed = try protocol.parseJson(protocol.Sessions, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.sessions.len);

    // The roster is unordered (hash-map iteration); find each opened session and
    // assert its argv label + that it is alive and attached (this connection is
    // bound to both).
    var seen0 = false;
    var seen1 = false;
    for (parsed.value.sessions) |s| {
        try testing.expect(s.alive);
        try testing.expect(s.attached);
        try testing.expectEqualStrings("idle", s.activity);
        if (std.mem.eql(u8, s.id, o0.id[0..])) {
            seen0 = true;
            try testing.expect(s.argv != null);
            try testing.expectEqualStrings("run-marker-0", s.argv.?);
            try testing.expect(s.pinned); // OPEN.pinned reached the session + roster
        } else if (std.mem.eql(u8, s.id, o1.id[0..])) {
            seen1 = true;
            try testing.expect(s.argv != null);
            try testing.expectEqualStrings("/bin/zsh", s.argv.?);
            try testing.expect(!s.pinned); // unpinned by default
        }
    }
    try testing.expect(seen0 and seen1);
}

test "LIST_SESSIONS→SESSIONS: a session's row names the pane that opened it (T552)" {
    // The reverse of the join `+list --json`'s `session_id` answers: session ->
    // pane, which is the only direction available once the app is closed. The
    // agent keeps no other part of a session's env, so this asserts the ONE key
    // it lifts out — and asserts that a session opened without it reports null
    // rather than an empty string, since an older app bakes no pane id at all.
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc0: FakeChild = .{ .alloc = alloc };
    var fc1: FakeChild = .{ .alloc = alloc };
    defer fc0.deinit();
    defer fc1.deinit();
    var kids = [_]*FakeChild{ &fc0, &fc1 };
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0x552);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // A viewer-opened pane: the surface's env overrides carry its pane id, mixed
    // in among the other vars the OPEN forwards, so this also proves the lookup
    // is by key rather than by position.
    const paned_env = [_]protocol.Open.EnvPair{
        .{ .key = "GHOZTTY_WINDOW_NAME", .value = "work" },
        .{ .key = "GHOZTTY_PANE_ID", .value = "PANE-0BAD-CAFE" },
        .{ .key = "TERM_PROGRAM", .value = "ghostty" },
    };
    const paned = try doOpen(&h, .{ .rows = 24, .cols = 80, .env = &paned_env });
    // An older app (or a non-pane opener): no pane id in the env at all.
    const anon = try doOpen(&h, .{ .rows = 24, .cols = 80, .env = &.{} });

    const req_ch: u128 = 0x5520;
    try h.client.sendControlJson(.list_sessions, req_ch, protocol.ListSessions{});
    const reply = try h.client.waitControl(.sessions);
    var parsed = try protocol.parseJson(protocol.Sessions, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.sessions.len);

    var seen_paned = false;
    var seen_anon = false;
    for (parsed.value.sessions) |s| {
        if (std.mem.eql(u8, s.id, paned.id[0..])) {
            seen_paned = true;
            try testing.expectEqualStrings("PANE-0BAD-CAFE", s.pane_id.?);
        } else if (std.mem.eql(u8, s.id, anon.id[0..])) {
            seen_anon = true;
            try testing.expect(s.pane_id == null);
        }
    }
    try testing.expect(seen_paned and seen_anon);
}

test "LIST_SESSIONS→SESSIONS: empty roster is answered with an empty array" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(12);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.list_sessions, 0xABCD, protocol.ListSessions{});
    const reply = try h.client.waitControl(.sessions);
    var parsed = try protocol.parseJson(protocol.Sessions, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.sessions.len);
}

test "SET_LAYOUT stores a blob; GET_LAYOUTS returns it; delete removes it (T18)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc0: FakeChild = .{ .alloc = alloc };
    defer fc0.deinit();
    var kids = [_]*FakeChild{&fc0};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(41);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o0 = try doOpen(&h, .{ .rows = 24, .cols = 80, .command = "run-marker" });

    // A GET_LAYOUTS on a fresh agent answers with an empty (present) array.
    try h.client.sendControlJson(.get_layouts, 0x1000, protocol.GetLayouts{});
    {
        const reply = try h.client.waitControl(.layouts);
        var parsed = try protocol.parseJson(protocol.Layouts, alloc, reply.payload);
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 0), parsed.value.layouts.len);
    }

    // Push a layout blob keyed "win-1" referencing the open session.
    const ids = [_][]const u8{o0.id[0..]};
    const set_ch: u128 = 0x1A;
    try h.client.sendControlJson(.set_layout, set_ch, protocol.SetLayout{
        .key = "win-1",
        .blob = "{\"tree\":\"opaque\"}",
        .session_ids = &ids,
    });
    {
        const reply = try h.client.waitControl(.set_layout_result);
        try testing.expectEqual(set_ch, reply.channel);
        var parsed = try protocol.parseJson(protocol.SetLayoutResult, alloc, reply.payload);
        defer parsed.deinit();
        try testing.expect(parsed.value.ok);
    }

    // GET_LAYOUTS now returns the stored blob verbatim on the request channel.
    const get_ch: u128 = 0x2B;
    try h.client.sendControlJson(.get_layouts, get_ch, protocol.GetLayouts{});
    {
        const reply = try h.client.waitControl(.layouts);
        try testing.expectEqual(get_ch, reply.channel);
        var parsed = try protocol.parseJson(protocol.Layouts, alloc, reply.payload);
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 1), parsed.value.layouts.len);
        try testing.expectEqualStrings("win-1", parsed.value.layouts[0].key);
        try testing.expectEqualStrings("{\"tree\":\"opaque\"}", parsed.value.layouts[0].blob);
    }

    // A delete removes the blob; the next GET_LAYOUTS is empty again.
    try h.client.sendControlJson(.set_layout, 0x1B, protocol.SetLayout{
        .key = "win-1",
        .delete = true,
    });
    _ = try h.client.waitControl(.set_layout_result);
    try h.client.sendControlJson(.get_layouts, 0x2C, protocol.GetLayouts{});
    {
        const reply = try h.client.waitControl(.layouts);
        var parsed = try protocol.parseJson(protocol.Layouts, alloc, reply.payload);
        defer parsed.deinit();
        try testing.expectEqual(@as(usize, 0), parsed.value.layouts.len);
    }
}

test "METRICS_SUB pushes metrics frames; METRICS_UNSUB stops the pump cleanly" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(30);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Subscribe with a small interval; at least one metrics frame must arrive with a
    // decodable HostMetrics (cpu_pct may be 0 on the first sample, no baseline yet).
    try h.client.sendControlJson(.metrics_sub, protocol.control_channel, protocol.MetricsSub{
        .interval_ms = 10,
    });
    const m1 = try h.client.waitControl(.metrics);
    var mp = try protocol.parseJson(protocol.Metrics, alloc, m1.payload);
    defer mp.deinit();
    // ncpu is read directly each sample (not delta-based) so it must be > 0 on a
    // real host; cpu_pct is allowed to be 0 on the first push.
    try testing.expect(mp.value.host.ncpu >= 1);
    try testing.expect(mp.value.host.cpu_pct >= 0);

    // A second push should follow (the pump loops on the interval).
    const m2 = try h.client.waitControl(.metrics);
    var mp2 = try protocol.parseJson(protocol.Metrics, alloc, m2.payload);
    defer mp2.deinit();

    // Unsubscribe: the pump stops + joins. The harness deinit (shutdown) must then
    // tear down with no hang/leak (testing.allocator catches leaks).
    try h.client.sendControlJson(.metrics_unsub, protocol.control_channel, protocol.MetricsUnsub{});
    // Give the unsub a moment to be processed (control reader is async); wait
    // until the pump thread is torn down.
    const P = struct {
        fn pumpGone(s: *Server) bool {
            return s.metrics_thread == null;
        }
    };
    try testing.expect(waitUntil("the pump thread to exit", P.pumpGone, .{h.server}));
}

test "concurrent METRICS_UNSUB and shutdown: exactly one of them joins the pump (T420)" {
    const alloc = testing.allocator;
    const Racer = struct {
        fn unsub(s: *Server) void {
            s.handleMetricsUnsub();
        }
    };

    // The window is a few instructions wide, so one pass proves nothing —
    // loop. Before the fix this crashed inside `NtClose` on the second join of
    // an already-joined handle (T420's stack), or left the pump running past
    // the Server (T442).
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var clock: TestClock = .{};
        var sp: FakeSpawner = .{ .children = &.{} };
        var prng = std.Random.DefaultPrng.init(32 + round);

        var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
        try h.server.start();
        try h.client.handshake();
        _ = try h.server.waitHandshake();

        h.server.handleMetricsSub("{\"interval_ms\":50}");
        const t = try std.Thread.spawn(.{}, Racer.unsub, .{h.server});
        h.server.shutdown();
        t.join();
        try testing.expect(h.server.metrics_thread == null);

        h.deinit();
    }
}

test "a *_sub racing shutdown never spawns a pump that would outlive the Server (T442)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(31);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Shutdown runs while the control reader can still be inside a `*_sub`
    // handler — it joins the reader threads only AFTER stopping the pumps. So a
    // subscribe landing here used to spawn a pump the stop had already walked
    // past, and that pump then wrote into the freed Server forever.
    h.server.shutdown();
    try testing.expect(h.server.pumps_closed.load(.acquire));

    h.server.handleMetricsSub("{\"interval_ms\":10}");
    h.server.handleSessionCpuSub("{\"interval_ms\":10}");
    h.server.handleSessionsSub();

    try testing.expect(h.server.metrics_thread == null);
    try testing.expect(h.server.session_cpu_thread == null);
    try testing.expect(h.server.roster_thread == null);
}

test "throttledIntervalMs: the agent, not the client, decides the cadence" {
    // The client's hint is honored when the machine is idle...
    try testing.expectEqual(@as(u32, 2000), Server.throttledIntervalMs(2000, 5));
    // ...but a zero/hostile interval is floored so the pump can't busy-spin.
    try testing.expectEqual(@as(u32, 500), Server.throttledIntervalMs(0, 0));
    try testing.expectEqual(@as(u32, 500), Server.throttledIntervalMs(1, 0));
    // Loaded ⇒ back off, so the stream costs less exactly when the box is busy.
    try testing.expectEqual(@as(u32, 4000), Server.throttledIntervalMs(2000, 70));
    try testing.expectEqual(@as(u32, 8000), Server.throttledIntervalMs(2000, 95));
    // Backoff is BOUNDED: an unbounded throttle is indistinguishable from a hang.
    try testing.expectEqual(@as(u32, 10_000), Server.throttledIntervalMs(60_000, 0));
    try testing.expectEqual(@as(u32, 10_000), Server.throttledIntervalMs(5000, 95));
    // Saturating math: a huge hint must not wrap around to a tiny interval.
    try testing.expectEqual(@as(u32, 10_000), Server.throttledIntervalMs(std.math.maxInt(u32), 95));
}

test "SESSION_CPU_SUB pushes per-session CPU; SESSION_CPU_UNSUB stops the pump cleanly" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(31);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{protocol.capability.session_cpu};
    try h.client.handshakeCaps(&caps);
    const neg = try h.server.waitHandshake();
    // The stream is opcode-gated, so both peers must advertise the capability.
    try testing.expect(neg.session_cpu);

    try h.client.sendControlJson(.session_cpu_sub, protocol.control_channel, protocol.SessionCpuSub{
        .interval_ms = 10,
    });

    const f1 = try h.client.waitControl(.session_cpu);
    var p1 = try protocol.parseJson(protocol.SessionCpu, alloc, f1.payload);
    defer p1.deinit();
    // The agent reports the cadence it CHOSE, which is floored above the 10ms hint.
    try testing.expectEqual(@as(u32, 500), p1.value.interval_ms);
    for (p1.value.sessions) |row| {
        try testing.expect(row.id.len > 0);
        try testing.expect(row.cpu_pct >= 0);
    }

    // Unsubscribe: the pump stops and joins (testing.allocator catches any leak,
    // and a pump outliving the Server would be a UAF).
    try h.client.sendControlJson(.session_cpu_unsub, protocol.control_channel, protocol.SessionCpuUnsub{});
    const P = struct {
        fn pumpGone(s: *Server) bool {
            return s.session_cpu_thread == null;
        }
    };
    try testing.expect(waitUntil("the pump thread to exit", P.pumpGone, .{h.server}));
}

test "suppressCapabilities: turns a capability off at the source, in the HELLO (T469)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(472);

    // Restore the process-wide seam whatever happens — every later test in this
    // file handshakes through the same `create`.
    defer Server.suppressCapabilities("");
    Server.suppressCapabilities("open_failed, session_cpu");

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // The CLIENT still asks for both, so a non-empty intersection would mean the
    // agent advertised them anyway — which is the thing being ruled out.
    const caps = [_][]const u8{ protocol.capability.open_failed, protocol.capability.session_cpu, protocol.capability.close_session };
    try h.client.handshakeCaps(&caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(!neg.open_failed);
    try testing.expect(!neg.session_cpu);
    // Everything NOT named is untouched: this suppresses, it does not reset.
    try testing.expect(neg.close_session);
}

test "OPEN refused: the agent answers OPEN_FAILED with a reason, not silence (T469)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    // No children to hand out, so the very first spawn fails for real — the
    // same route a bad shell path takes on a box.
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(469);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{protocol.capability.open_failed};
    try h.client.handshakeCaps(&caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(neg.open_failed);

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{ .rows = 24, .cols = 80 });

    const f = try h.client.waitControl(.open_failed);
    var p = try protocol.parseJson(protocol.OpenFailed, alloc, f.payload);
    defer p.deinit();
    // The token names the actionable cause, and the detail names the error the
    // spawner actually raised — the two things the old silence threw away.
    try testing.expectEqualStrings(protocol.OpenFailed.Reason.spawn_failed, p.value.reason);
    try testing.expectEqualStrings("NoMoreChildren", p.value.detail.?);
    // And nothing was created: a refusal must not leave a half-session behind.
    h.store.mutex.lock();
    defer h.store.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), h.store.table.count());
}

test "OPEN refused at the live cap: the reply names the cap and the counts (T469)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    // TWO children: the second spawn must SUCCEED so the refusal comes from
    // `SessionTable.create` and not from the spawner running dry — those are
    // different reasons and the point of the test is which one is reported.
    var c0: FakeChild = .{ .alloc = alloc };
    var c1: FakeChild = .{ .alloc = alloc };
    var children = [_]*FakeChild{ &c0, &c1 };
    var sp: FakeSpawner = .{ .children = &children };
    var prng = std.Random.DefaultPrng.init(470);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    // One live session is the whole budget, so the second OPEN is refused by
    // `SessionTable.create` itself — the genuine `error.TooManySessions` path,
    // not a fault injected beside it.
    h.store.mutex.lock();
    h.store.table.max_live = 1;
    h.store.mutex.unlock();

    try h.server.start();
    const caps = [_][]const u8{protocol.capability.open_failed};
    try h.client.handshakeCaps(&caps);
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{ .rows = 24, .cols = 80 });
    _ = try h.client.waitControl(.opened);

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{ .rows = 24, .cols = 80 });
    const f = try h.client.waitControl(.open_failed);
    var p = try protocol.parseJson(protocol.OpenFailed, alloc, f.payload);
    defer p.deinit();
    try testing.expectEqualStrings(protocol.OpenFailed.Reason.session_cap, p.value.reason);
    // The counts are the part a user (or a bug report) can act on: "at the
    // limit" and "out of memory" look identical from the pane otherwise.
    try testing.expect(std.mem.startsWith(u8, p.value.detail.?, "live=1/1 "));
}

test "OPEN refused: a client that did not negotiate open_failed gets today's silence (T469)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(471);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // An OLDER app: it never advertises `open_failed`, and 0x06 would be a fatal
    // framing error to it. The agent must stay silent and let it time out, which
    // is exactly the pre-T469 behavior.
    const old_caps = [_][]const u8{protocol.capability.close_session};
    try h.client.handshakeCaps(&old_caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(!neg.open_failed);

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{ .rows = 24, .cols = 80 });

    // Silence is not observable by waiting (a wait that ends is just a slower
    // wait). Ask a question the agent WILL answer and prove that answer is the
    // next frame: the writer is FIFO, so an OPEN_FAILED — sent before it — would
    // have to arrive first.
    try h.client.sendControlJson(.list_sessions, protocol.control_channel, struct {}{});
    const next = (try h.client.nextControl()) orelse return error.Eof;
    try testing.expectEqual(protocol.FrameType.sessions, next.type);
}

test "ATTACH the agent cannot parse: it answers ATTACH_FAILED instead of dropping it (T657)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(657);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{protocol.capability.attach_failed};
    try h.client.handshakeCaps(&caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(neg.attach_failed);

    // Not JSON at all — the one ATTACH path that used to `return` in silence,
    // costing the client the full 10 s `rpc_open_timeout_ns` for a request the
    // agent rejected in microseconds.
    try h.client.sendControlRaw(.attach, protocol.control_channel, "{not json");

    const f = try h.client.waitControl(.attach_failed);
    // On the CONTROL channel: there is no session, so there is no session
    // channel to speak on.
    try testing.expectEqual(protocol.control_channel, f.channel);
    var p = try protocol.parseJson(protocol.AttachFailed, alloc, f.payload);
    defer p.deinit();
    try testing.expectEqualStrings(protocol.AttachFailed.Reason.malformed_request, p.value.reason);
    // The detail names the parse error, which is the part a bug report needs.
    try testing.expect(p.value.detail.?.len > 0);
}

test "ATTACH refused: a client that did not negotiate attach_failed gets today's silence (T657)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(658);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // An OLDER app: 0x07 would be a fatal framing error to it, so the agent
    // must stay silent and let it time out — the pre-T657 behavior exactly.
    const old_caps = [_][]const u8{protocol.capability.close_session};
    try h.client.handshakeCaps(&old_caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(!neg.attach_failed);

    try h.client.sendControlRaw(.attach, protocol.control_channel, "{not json");

    // Silence is not observable by waiting (a wait that ends is just a slower
    // wait). Ask a question the agent WILL answer and prove that answer is the
    // next frame: the writer is FIFO, so an ATTACH_FAILED — sent before it —
    // would have to arrive first.
    try h.client.sendControlJson(.list_sessions, protocol.control_channel, struct {}{});
    const next = (try h.client.nextControl()) orelse return error.Eof;
    try testing.expectEqual(protocol.FrameType.sessions, next.type);
}

test "ATTACH to an unknown session still answers ATTACHED{not_found}, not ATTACH_FAILED (T657)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(659);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{protocol.capability.attach_failed};
    try h.client.handshakeCaps(&caps);
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = "no-such-session",
        .rows = 24,
        .cols = 80,
    });

    // THE INVARIANT this frame exists not to break: a missing session is a
    // complete answer that `ATTACHED.status` has carried since long before
    // 0x07, on every agent that ever shipped. Saying it a second way would be
    // two vocabularies for one fact across a compatibility boundary — and it
    // would strand every caller that reads `AttachOutcome.status` (the chooser,
    // Restore All) behind a new error. The user-facing sentence is derived from
    // this status on the CLIENT (`termio/attach_failed_notice.zig`), which is
    // why it works against an agent of any age.
    const f = (try h.client.nextControl()) orelse return error.Eof;
    try testing.expectEqual(protocol.FrameType.attached, f.type);
    var p = try protocol.parseJson(protocol.Attached, alloc, f.payload);
    defer p.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.not_found, p.value.status);
}

test "SESSIONS_SUB pushes the roster immediately and again when it changes" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(33);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{protocol.capability.sessions_push};
    try h.client.handshakeCaps(&caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(neg.sessions_push);

    // Subscribing sends one straight away, so a subscriber starts from truth
    // instead of waiting for something to change.
    try h.client.sendControlJson(.sessions_sub, protocol.control_channel, struct {}{});
    const first = try h.client.waitControl(.sessions);
    var p1 = try protocol.parseJson(protocol.Sessions, alloc, first.payload);
    defer p1.deinit();

    // A push must arrive on the CONTROL channel: that is how the client tells a
    // push from a LIST_SESSIONS reply, which is echoed on the request channel.
    try testing.expectEqual(protocol.control_channel, first.channel);

    // Unsubscribe stops it. No pump to join -- the roster pump idles on its
    // condition variable until something marks it dirty.
    try h.client.sendControlJson(.sessions_unsub, protocol.control_channel, struct {}{});
    const P = struct {
        fn unsubscribed(s: *Server) bool {
            return !s.sessions_push;
        }
    };
    try testing.expect(waitUntil("the connection to unsubscribe", P.unsubscribed, .{h.server}));
}

test "sessions_push: an OLDER client that never advertises it leaves the stream off" {
    // New agent, old app: the negotiated flag must stay false so the agent never
    // pushes an opcode the client would treat as a fatal framing error, and the
    // client keeps its LIST_SESSIONS poll.
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(34);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const old_caps = [_][]const u8{protocol.capability.close_session};
    try h.client.handshakeCaps(&old_caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(!neg.sessions_push);
    try testing.expect(neg.close_session);
}

test "session_cpu: an OLDER client that never advertises it leaves the stream off" {
    // The compatibility direction that matters: a new agent talking to an app
    // that predates `session_cpu`. The negotiated flag must stay false so the
    // client never receives an opcode it would treat as a fatal framing error,
    // and the connection keeps working for everything else.
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(32);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const old_caps = [_][]const u8{protocol.capability.close_session};
    try h.client.handshakeCaps(&old_caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(!neg.session_cpu);
    // Unrelated capabilities still negotiate normally.
    try testing.expect(neg.close_session);
}

test "session_cpu: stopping the pump twice does not double-join (agent panic)" {
    // The crash this guards: `stopSessionCpuPump` used to read
    // `session_cpu_thread` OUTSIDE its mutex, so two stoppers could both see the
    // same non-null handle and both `join` it. The second join returns EINVAL,
    // which std maps to `unreachable` — a PANIC in the daemon that is supposed to
    // outlive the app.
    //
    // It is not a theoretical interleaving: a client unsubscribes (control-reader
    // thread) and then drops the connection (serve thread → `shutdown`), which is
    // exactly what the chooser does every time the user moves off a machine.
    // Sharing one warm connection between the roster and the CPU meter made that
    // pair land back-to-back on every selection change.
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(77);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{protocol.capability.session_cpu};
    try h.client.handshakeCaps(&caps);
    const neg = try h.server.waitHandshake();
    try testing.expect(neg.session_cpu);

    // Two stoppers AT THE SAME TIME, repeatedly. Sequential calls would not
    // reproduce it — the first stop nulls the handle, so the second is already a
    // no-op. The bug lives strictly in the window between reading the handle and
    // nulling it, so the test has to put two threads in that window.
    const Racer = struct {
        fn stop(srv: *Server, gate: *std.Thread.ResetEvent) void {
            gate.wait();
            srv.stopSessionCpuPump();
        }
    };

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        try h.client.sendControlJson(
            .session_cpu_sub,
            protocol.control_channel,
            protocol.SessionCpuSub{ .interval_ms = 500 },
        );
        // Wait for a frame, so a pump thread definitely exists to be joined.
        _ = try h.client.waitControl(.session_cpu);

        var gate: std.Thread.ResetEvent = .{};
        const a = try std.Thread.spawn(.{}, Racer.stop, .{ h.server, &gate });
        const b = try std.Thread.spawn(.{}, Racer.stop, .{ h.server, &gate });
        gate.set();
        a.join();
        b.join();

        // Whichever stopper won, the pump is gone and a re-subscribe on the next
        // round must still get a live one — the generation bookkeeping must not
        // leave the stream permanently retired.
        try testing.expect(h.server.session_cpu_thread == null);
    }
}

test "PROC_LIST→PROC_SNAPSHOT: agent enumerates real processes on the request channel" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(40);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Request the process table on a fresh request channel; the agent must echo
    // PROC_SNAPSHOT on it (same-channel correlation, like GET_CWD).
    const req_ch: u128 = 0xC0FFEE_F00D;
    try h.client.sendControlJson(.proc_list, req_ch, protocol.ProcList{ .limit = 50 });
    const reply = try h.client.waitControl(.proc_snapshot);
    try testing.expectEqual(req_ch, reply.channel);

    var parsed = try protocol.parseJson(protocol.ProcSnapshot, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(parsed.value.ok);
    // A real host always has running processes; the agent's own process is one.
    try testing.expect(parsed.value.procs.len > 0);
    // Each row must decode with a non-empty name and a non-negative cpu_pct.
    var saw_named = false;
    for (parsed.value.procs) |p| {
        try testing.expect(p.cpu_pct >= 0);
        if (p.name.len > 0) saw_named = true;
    }
    try testing.expect(saw_named);
    // ncpu is read directly each host sample → > 0 on a real machine.
    try testing.expect(parsed.value.host.ncpu >= 1);
}

test "PROC_SPAWN→PROC_SPAWN_RESULT then PROC_KILL→PROC_KILL_RESULT round-trip" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(41);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Spawn a harmless short sleeper on the request channel; the agent must echo
    // PROC_SPAWN_RESULT{ok=true, pid>0} on it (same-channel correlation).
    const req_ch: u128 = 0x5A11AD;
    try h.client.sendControlJson(.proc_spawn, req_ch, protocol.ProcSpawn{
        .cmd = "sleep 0.2",
    });
    const sreply = try h.client.waitControl(.proc_spawn_result);
    try testing.expectEqual(req_ch, sreply.channel);
    var sparsed = try protocol.parseJson(protocol.ProcSpawnResult, alloc, sreply.payload);
    defer sparsed.deinit();
    try testing.expect(sparsed.value.ok);
    try testing.expect(sparsed.value.pid != null);
    const pid = sparsed.value.pid.?;
    try testing.expect(pid > 0);

    // Kill that pid (default TERM). The agent replies PROC_KILL_RESULT; ok should be
    // true (the sleeper is alive), but accept either since it may have already
    // exited and been reaped — the contract is "no crash, a structured result".
    const kill_ch: u128 = 0x11A11;
    try h.client.sendControlJson(.proc_kill, kill_ch, protocol.ProcKill{ .pid = pid });
    const kreply = try h.client.waitControl(.proc_kill_result);
    try testing.expectEqual(kill_ch, kreply.channel);
    var kparsed = try protocol.parseJson(protocol.ProcKillResult, alloc, kreply.payload);
    defer kparsed.deinit();
    try testing.expectEqual(pid, kparsed.value.pid);
    try testing.expect(kparsed.value.ok or kparsed.value.@"error" != null);
}

test "PROC_KILL a bogus pid → ok=false (graceful)" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(42);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const req_ch: u128 = 0xB0_6051;
    try h.client.sendControlJson(.proc_kill, req_ch, protocol.ProcKill{ .pid = 2147483600 });
    const reply = try h.client.waitControl(.proc_kill_result);
    try testing.expectEqual(req_ch, reply.channel);
    var parsed = try protocol.parseJson(protocol.ProcKillResult, alloc, reply.payload);
    defer parsed.deinit();
    try testing.expect(!parsed.value.ok);
    try testing.expect(parsed.value.@"error" != null);
}

test "OPEN→OPENED then child output streams as DATA with advancing byte_offsets" {
    const alloc = testing.allocator;
    for (all_encodings) |enc| {
        var clock: TestClock = .{};
        var fc: FakeChild = .{ .alloc = alloc };
        defer fc.deinit();
        var kids = [_]*FakeChild{&fc};
        var sp: FakeSpawner = .{ .children = &kids };
        var prng = std.Random.DefaultPrng.init(2);

        var h = try Harness.init(alloc, enc, &clock, &sp, 4096, prng.random());
        defer h.deinit();
        try h.server.start();
        try h.client.handshake();
        _ = try h.server.waitHandshake();

        const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

        // Feed two output chunks; they must arrive as DATA at offsets 0 then 5.
        h.server.onChildOutput(o.channel, "hello");
        h.server.onChildOutput(o.channel, " world");

        const d1 = try h.client.nextData();
        const dp1 = try protocol.DataPayload.decode(d1.?.payload);
        try testing.expectEqual(o.channel, d1.?.channel);
        try testing.expectEqual(@as(u64, 0), dp1.byte_offset);
        try testing.expectEqualSlices(u8, "hello", dp1.bytes);

        const d2 = try h.client.nextData();
        const dp2 = try protocol.DataPayload.decode(d2.?.payload);
        try testing.expectEqual(@as(u64, 5), dp2.byte_offset);
        try testing.expectEqualSlices(u8, " world", dp2.bytes);
    }
}

test "client DATA reaches the child (input round-trip)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(3);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendDataInput(o.channel, 0, "ls -la\n");

    // Wait until the child observes the input (the data reader thread is async).
    const P = struct {
        fn sawInput(c: *FakeChild, a: Allocator) !bool {
            const got = try c.inputCopy(a);
            defer a.free(got);
            return std.mem.eql(u8, got, "ls -la\n");
        }
    };
    try testing.expect(waitUntil("the child to see the written input", P.sawInput, .{ &fc, alloc }));
    const got = try fc.inputCopy(alloc);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, "ls -la\n", got);
}

test "ATTACH alive returns snapshot anchor and streams forward from > S" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(4);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    // Produce some output so the snapshot offset S advances to 11.
    h.server.onChildOutput(o.channel, "hello world");
    _ = try h.client.nextData(); // drain the live DATA

    // Attach with last_byte_offset = 11 (already current) → no gap-fill, S = 11.
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 30,
        .cols = 100,
        .last_byte_offset = 11,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u64, 11), ap.value.snapshot_at_offset);
    try testing.expectEqual(@as(u16, 30), ap.value.rows);

    // New live output streams forward from offset 11 (> S not double-applied).
    h.server.onChildOutput(o.channel, "!");
    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 11), dp.byte_offset);
    try testing.expectEqualSlices(u8, "!", dp.bytes);
}

test "ATTACH with grid_snapshot negotiated replays a visible-screen repaint (FIX 2)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(7);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // The client advertises grid_snapshot (a modern app).
    try h.client.handshakeCaps(&.{
        protocol.capability.close_session,
        protocol.capability.grid_snapshot,
    });
    const neg = try h.server.waitHandshake();
    try testing.expect(neg.grid_snapshot);

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    // The blank-pane shape: enter the alt screen, then paint content. On the wire
    // the `?1049h` is just early output that (in a real deep-scrollback session)
    // would be evicted from the ring.
    h.server.onChildOutput(o.channel, "\x1b[?1049h");
    h.server.onChildOutput(o.channel, "SNAPSHOT-ME");
    _ = try h.client.nextData(); // drain live DATA (chunk 1)
    _ = try h.client.nextData(); // drain live DATA (chunk 2)

    // A FRESH attach (last_byte_offset = 0), exactly like the GUI after an app
    // relaunch/upgrade.
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 0,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    const s = ap.value.snapshot_at_offset;

    // On the alt screen the raw ring replay is skipped; the ONLY post-attach DATA
    // is the grid snapshot, sent at offset S. It must re-enter the alt screen and
    // repaint the content so the pane is never blank.
    const d = (try h.client.nextData()) orelse return error.NoSnapshot;
    const dp = try protocol.DataPayload.decode(d.payload);
    try testing.expectEqual(s, dp.byte_offset);
    try testing.expect(std.mem.indexOf(u8, dp.bytes, "?1049h") != null);
    try testing.expect(std.mem.indexOf(u8, dp.bytes, "SNAPSHOT-ME") != null);
}

test "T739: the ATTACH repaint is framed as DATA_REPAINT, and only for a peer that asked" {
    // Same shape as the grid_snapshot test above; what is measured here is the
    // FRAME TYPE of the injected repaint, which is what tells the client not to
    // count its bytes as stream position.
    const alloc = testing.allocator;
    for ([_]bool{ true, false }) |want_repaint_cap| {
        var clock: TestClock = .{ .ms = 100 };
        var fc: FakeChild = .{ .alloc = alloc };
        defer fc.deinit();
        var kids = [_]*FakeChild{&fc};
        var sp: FakeSpawner = .{ .children = &kids };
        var prng = std.Random.DefaultPrng.init(11);

        var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
        defer h.deinit();
        try h.server.start();
        if (want_repaint_cap) {
            try h.client.handshakeCaps(&.{
                protocol.capability.grid_snapshot,
                protocol.capability.repaint_data,
            });
        } else {
            // A client of the pre-T739 generation: it wants the repaint but has
            // no idea what 0x15 is, and an unknown opcode would be a fatal
            // framing error for it.
            try h.client.handshakeCaps(&.{protocol.capability.grid_snapshot});
        }
        const neg = try h.server.waitHandshake();
        try testing.expect(neg.grid_snapshot);
        try testing.expectEqual(want_repaint_cap, neg.repaint_data);

        const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
        // Alt screen so the raw ring replay is skipped and the ONLY post-attach
        // DATA-lane frame is the repaint itself.
        h.server.onChildOutput(o.channel, "\x1b[?1049h");
        h.server.onChildOutput(o.channel, "SNAPSHOT-ME");
        _ = try h.client.nextData();
        _ = try h.client.nextData();

        var id_buf: [32]u8 = o.id;
        try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
            .session_id = id_buf[0..],
            .rows = 24,
            .cols = 80,
            .last_byte_offset = 0,
        });
        const af = try h.client.waitControl(.attached);
        var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
        defer ap.deinit();
        const s = ap.value.snapshot_at_offset;

        const d = (try h.client.nextData()) orelse return error.NoSnapshot;
        // The payload is identical either way — same anchor, same VT. Only the
        // frame type says whether these bytes are the session's or ours.
        const dp = try protocol.DataPayload.decode(d.payload);
        try testing.expectEqual(s, dp.byte_offset);
        try testing.expect(std.mem.indexOf(u8, dp.bytes, "SNAPSHOT-ME") != null);
        try testing.expectEqual(
            if (want_repaint_cap) protocol.FrameType.data_repaint else protocol.FrameType.data,
            d.type,
        );
    }
}

test "ATTACH without grid_snapshot falls back to raw ring replay (skew safety, FIX 2)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(8);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // An OLDER client: advertises NOTHING (no grid_snapshot).
    try h.client.handshakeCaps(&.{});
    const neg = try h.server.waitHandshake();
    try testing.expect(!neg.grid_snapshot);

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    h.server.onChildOutput(o.channel, "\x1b[?1049h");
    h.server.onChildOutput(o.channel, "PLAINBYTES");
    _ = try h.client.nextData();
    _ = try h.client.nextData();

    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 0,
    });
    _ = try h.client.waitControl(.attached);

    // No snapshot: the ONLY post-attach DATA is today's raw ring replay from the
    // base (offset 0), byte-identical to what the child produced — no formatter
    // repaint sequence.
    const d = (try h.client.nextData()) orelse return error.NoReplay;
    const dp = try protocol.DataPayload.decode(d.payload);
    try testing.expectEqual(@as(u64, 0), dp.byte_offset);
    try testing.expectEqualSlices(u8, "\x1b[?1049hPLAINBYTES", dp.bytes);
}

test "OPEN/ATTACH carry the child's pid+tty (wp3 getProcessInfo metadata)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids, .tty = "/dev/ttys014" };
    var prng = std.Random.DefaultPrng.init(41);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // OPENED carries the spawner-reported tty (and the pid, as before).
    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{ .rows = 24, .cols = 80 });
    const of = try h.client.waitControl(.opened);
    var op = try protocol.parseJson(protocol.Opened, alloc, of.payload);
    defer op.deinit();
    try testing.expectEqual(@as(i64, 1001), op.value.pid);
    try testing.expectEqualStrings("/dev/ttys014", op.value.tty.?);
    var id: [32]u8 = undefined;
    @memcpy(&id, op.value.session_id[0..32]);

    // ATTACHED (alive) re-reports pid + tty — the app-relaunch recovery path,
    // where OPENED's metadata died with the previous app process.
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id[0..],
        .rows = 24,
        .cols = 80,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(i64, 1001), ap.value.pid);
    try testing.expectEqualStrings("/dev/ttys014", ap.value.tty.?);
}

test "foreground-pid sampling pushes META on change only (wp3)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(43);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // The shell puts a program in the foreground → next tick pushes META.
    fc.mutex.lock();
    fc.fake_fg_pid = 4321;
    fc.mutex.unlock();
    h.server.store.sampleForegroundPids();

    // Unchanged fg on later ticks must NOT re-push; then a change pushes again.
    h.server.store.sampleForegroundPids();
    fc.mutex.lock();
    fc.fake_fg_pid = 4322;
    fc.mutex.unlock();
    h.server.store.sampleForegroundPids();

    // Exactly two METAs arrive, in order (a spurious duplicate would make the
    // second read observe 4321 again — `waitControl` skips nothing here since
    // no other control frames are in flight).
    const m1 = try h.client.waitControl(.meta);
    try testing.expectEqual(o.channel, m1.channel);
    var p1 = try protocol.parseJson(protocol.Meta, alloc, m1.payload);
    defer p1.deinit();
    try testing.expectEqual(@as(i64, 4321), p1.value.foreground_pid.?);

    const m2 = try h.client.waitControl(.meta);
    var p2 = try protocol.parseJson(protocol.Meta, alloc, m2.payload);
    defer p2.deinit();
    try testing.expectEqual(@as(i64, 4322), p2.value.foreground_pid.?);
}

/// A synthetic parent table: `pairs` are `{pid, ppid}`. Lets the descendants
/// push rules be asserted against a KNOWN process tree instead of whatever the
/// test runner's own children happen to be at that instant.
fn parentMap(alloc: Allocator, pairs: []const [2]i64) !descendants.ParentMap {
    var map: descendants.ParentMap = .empty;
    errdefer map.deinit(alloc);
    for (pairs) |p| try map.put(alloc, p[0], p[1]);
    return map;
}

test "descendants sampling pushes META{has_descendants} on change only (T356)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(356);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // Both sides advertise `session_busy`, so the bridge is installed.
    const caps = [_][]const u8{ protocol.capability.close_session, protocol.capability.session_busy };
    try h.client.handshakeCaps(&caps);
    _ = try h.server.waitHandshake();

    // The fake spawner's first session gets pid 1001 (`pid_base + 0`).
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // An idle prompt: the shell is in the table with nothing under it.
    var idle = try parentMap(alloc, &.{.{ 1001, 1 }});
    defer idle.deinit(alloc);
    // Something starts: a child, and a grandchild that the direct child spawned.
    var busy = try parentMap(alloc, &.{ .{ 1001, 1 }, .{ 2001, 1001 }, .{ 3001, 2001 } });
    defer busy.deinit(alloc);
    // The shell is not in the table at all (a failed/partial enumeration).
    var absent = try parentMap(alloc, &.{.{ 9001, 1 }});
    defer absent.deinit(alloc);

    // First sample: idle. Pushed even though "no descendants" is the state the
    // session was born in — the client starts at UNKNOWN and must be told.
    h.server.store.sampleDescendantsIn(&idle);
    // Same answer again: silence.
    h.server.store.sampleDescendantsIn(&idle);
    // Now busy.
    h.server.store.sampleDescendantsIn(&busy);
    // A table that cannot see the shell must not report anything — in
    // particular not `false`, which would skip a close confirmation while a job
    // is running. Runs between the two real transitions so a spurious push
    // would land here and be read as the wrong value below.
    h.server.store.sampleDescendantsIn(&absent);
    // Back to idle.
    h.server.store.sampleDescendantsIn(&idle);

    const want = [_]bool{ false, true, false };
    for (want) |w| {
        const f = try h.client.waitControl(.meta);
        try testing.expectEqual(o.channel, f.channel);
        var p = try protocol.parseJson(protocol.Meta, alloc, f.payload);
        defer p.deinit();
        try testing.expectEqual(w, p.value.has_descendants.?);
    }
}

test "descendants sampling is silent for a peer without session_busy (T356)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(357);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    // An OLDER APP: it never advertises `session_busy`.
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // No bridge was installed, so the whole sampler is a no-op — and the outer
    // `sampleDescendants` never even takes a process snapshot.
    var busy = try parentMap(alloc, &.{ .{ 1001, 1 }, .{ 2001, 1001 } });
    defer busy.deinit(alloc);
    h.server.store.sampleDescendantsIn(&busy);
    h.server.store.sampleDescendants();

    // Prove the silence is the gate, not a dead channel: a foreground-pid push
    // on the SAME channel still arrives, and it is the FIRST meta frame — so a
    // stray `has_descendants` push would have been read here and failed.
    fc.mutex.lock();
    fc.fake_fg_pid = 777;
    fc.mutex.unlock();
    h.server.store.sampleForegroundPids();

    const f = try h.client.waitControl(.meta);
    try testing.expectEqual(o.channel, f.channel);
    var p = try protocol.parseJson(protocol.Meta, alloc, f.payload);
    defer p.deinit();
    try testing.expectEqual(@as(i64, 777), p.value.foreground_pid.?);
    try testing.expect(p.value.has_descendants == null);
}

test "descendants sampling re-pushes to a freshly re-bound viewer (T356)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(358);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    const caps = [_][]const u8{ protocol.capability.close_session, protocol.capability.session_busy };
    try h.client.handshakeCaps(&caps);
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    var idle = try parentMap(alloc, &.{.{ 1001, 1 }});
    defer idle.deinit(alloc);
    h.server.store.sampleDescendantsIn(&idle);
    const first = try h.client.waitControl(.meta);
    var fp = try protocol.parseJson(protocol.Meta, alloc, first.payload);
    defer fp.deinit();
    try testing.expect(!fp.value.has_descendants.?);

    // Re-ATTACH (the app-relaunch path). The previous viewer's pushes died with
    // its connection, so the agent's record must be cleared and the CURRENT
    // answer re-sent even though it has not changed.
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = o.id[0..],
        .rows = 24,
        .cols = 80,
    });
    _ = try h.client.waitControl(.attached);

    h.server.store.sampleDescendantsIn(&idle);
    const again = try h.client.waitControl(.meta);
    var ap = try protocol.parseJson(protocol.Meta, alloc, again.payload);
    defer ap.deinit();
    try testing.expect(!ap.value.has_descendants.?);
}

test "OPEN with a tty-less spawner elides tty (Windows / older-agent shape)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids }; // tty = null
    var prng = std.Random.DefaultPrng.init(42);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{ .rows = 24, .cols = 80 });
    const of = try h.client.waitControl(.opened);
    var op = try protocol.parseJson(protocol.Opened, alloc, of.payload);
    defer op.deinit();
    try testing.expect(op.value.tty == null);
}

test "ATTACH gap-fills retained ring bytes in (L, S]" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(5);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    h.server.onChildOutput(o.channel, "ABCDEFGHIJ"); // offsets 0..10, S = 10
    _ = try h.client.nextData(); // drain live

    // Client only saw up to offset 4; expects gap-fill of (4,10] = "EFGHIJ".
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 4,
    });
    _ = try h.client.waitControl(.attached);
    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 4), dp.byte_offset);
    try testing.expectEqualSlices(u8, "EFGHIJ", dp.bytes);
}

test "ATTACHED reports the pre-attach capture geometry (replay_rows/cols, T106)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(11);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Open at 5x20 — the geometry the retained ring bytes are drawn at.
    const o = try doOpen(&h, .{ .rows = 5, .cols = 20 });
    h.server.onChildOutput(o.channel, "hello");
    _ = try h.client.nextData(); // drain live

    // Re-attach with a DIFFERENT seed geometry: `rows`/`cols` echo the new
    // seed (the attach applied it), while `replay_rows`/`replay_cols` carry
    // the pre-attach geometry so the client can replay the geometry-bound
    // ring bytes at the size they were drawn at (T106).
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 40,
        .cols = 120,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u16, 40), ap.value.rows);
    try testing.expectEqual(@as(u16, 120), ap.value.cols);
    try testing.expectEqual(@as(u16, 5), ap.value.replay_rows);
    try testing.expectEqual(@as(u16, 20), ap.value.replay_cols);
    _ = try h.client.nextData(); // drain the full-ring gap-fill replay
}

test "ATTACH to unknown session → not_found" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(6);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const bogus = "ffffffffffffffffffffffffffffffff";
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = bogus,
        .rows = 24,
        .cols = 80,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.not_found, ap.value.status);
}

test "child exit emits EXIT after final DATA; reattach → dead+exit_code; CLOSE frees" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 500 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(7);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Final output, THEN the child exits. onChildOutput emits DATA then (reaping)
    // EXIT — so the client must see DATA before EXIT (§4.2 ordering).
    fc.setExit(3);
    clock.ms = 1500; // 1000ms runtime
    h.server.onChildOutput(o.channel, "bye");

    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqualSlices(u8, "bye", dp.bytes);

    const ef = try h.client.waitControl(.exit);
    var ep = try protocol.parseJson(protocol.Exit, alloc, ef.payload);
    defer ep.deinit();
    try testing.expectEqual(@as(i64, 3), ep.value.code);
    try testing.expectEqual(@as(u64, 1000), ep.value.runtime_ms);

    // Reattach → tombstone: dead + exit_code.
    var id_buf: [32]u8 = o.id;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.dead, ap.value.status);
    try testing.expectEqual(@as(i64, 3), ap.value.exit_code.?);

    // CLOSE frees the tombstone + terminates the child handle.
    try h.client.sendControlRaw(.close, o.channel, "");
    // Wait for the LAST of CLOSE's two phases (see `FakeChild.waitTerminated`):
    // the unlink lands under the store lock, the terminate after it, so waiting
    // only for the session to vanish would race the terminate assertion below.
    try testing.expect(fc.waitTerminated());
    {
        h.server.store.mutex.lock();
        defer h.server.store.mutex.unlock();
        try testing.expect(h.server.store.table.getByChannel(o.channel) == null);
    }
}

test "CLOSE_SESSION by id: frees the session + terminates the child; unknown id → found=false" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 500 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(11);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();

    // The agent advertises the close_session capability; with the mock client also
    // advertising it, the negotiated intersection is true (a new app can gate on it).
    const neg = try h.server.waitHandshake();
    try testing.expect(neg.close_session);

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // CLOSE_SESSION addressed BY ID on a distinct request channel (NOT the session
    // channel — this is the chooser's "Kill" of a session with no local pane). The
    // reply rides the request channel.
    const req_channel: u128 = 0xC0FFEE;
    try h.client.sendControlJson(.close_session, req_channel, protocol.CloseSession{
        .session_id = o.id[0..],
    });
    const rf = try h.client.waitControl(.close_session_result);
    try testing.expectEqual(req_channel, rf.channel);
    var rp = try protocol.parseJson(protocol.CloseSessionResult, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.found);
    try testing.expect(rp.value.ok);
    try testing.expectEqualStrings(o.id[0..], rp.value.session_id);

    // The session is gone and the child was terminated (same as a CLOSE) — and
    // the terminate is the LATER of the two, so wait on that one.
    try testing.expect(fc.waitTerminated());
    {
        h.server.store.mutex.lock();
        defer h.server.store.mutex.unlock();
        try testing.expect(h.server.store.table.getByChannel(o.channel) == null);
    }

    // CLOSE_SESSION for an unknown id → found=false, ok=false (definitive answer).
    const bogus = "ffffffffffffffffffffffffffffffff";
    try h.client.sendControlJson(.close_session, req_channel, protocol.CloseSession{
        .session_id = bogus,
    });
    const rf2 = try h.client.waitControl(.close_session_result);
    var rp2 = try protocol.parseJson(protocol.CloseSessionResult, alloc, rf2.payload);
    defer rp2.deinit();
    try testing.expect(!rp2.value.found);
    try testing.expect(!rp2.value.ok);
}

test "CLOSE_SESSION replies BEFORE the child teardown (T326: reply is not gated on terminate)" {
    // Regression guard for the reply-first ordering. handleCloseSession used to
    // terminate the child + persist metadata to disk BEFORE sending
    // CLOSE_SESSION_RESULT, so a Kill of a session with a LIVE child could
    // exceed the client's 5s RPC budget and report error.Timeout for a close
    // that WORKED. The outcome (found/ok) is fully decided by the unlink, so
    // the reply must arrive even while the child's teardown is still in
    // flight — asserted here by gating `terminate` shut and demanding the
    // reply anyway (ordering, not a wall-clock number).
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 500 };
    var term_entered: std.Thread.ResetEvent = .{};
    var term_release: std.Thread.ResetEvent = .{};
    var fc: FakeChild = .{
        .alloc = alloc,
        .term_gate_entered = &term_entered,
        .term_gate_release = &term_release,
    };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(23);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit(); // runs LAST: joins server threads (gate released below first)
    defer term_release.set(); // runs BEFORE deinit so a blocked terminate can finish
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    const req_channel: u128 = 0x326;
    try h.client.sendControlJson(.close_session, req_channel, protocol.CloseSession{
        .session_id = o.id[0..],
    });

    // THE ASSERTION: the reply arrives while terminate is still blocked. The
    // mock client's loopback reads are bounded (T258), so a pre-fix ordering
    // fails red with a read timeout here instead of wedging the lane.
    const rf = try h.client.waitControl(.close_session_result);
    try testing.expectEqual(req_channel, rf.channel);
    var rp = try protocol.parseJson(protocol.CloseSessionResult, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.found);
    try testing.expect(rp.value.ok);
    // The child has NOT been reaped yet: `terminated` only flips after the gate
    // releases, so reply-before-reap is proven by ordering alone.
    try testing.expect(!fc.wasTerminated());
    // But the session is already gone from the table — the unlink, which is
    // what the reply reports on, landed before the reply was sent.
    {
        h.server.store.mutex.lock();
        defer h.server.store.mutex.unlock();
        try testing.expect(h.server.store.table.getByChannel(o.channel) == null);
    }

    // Release the teardown; it must still complete normally.
    term_release.set();
    try testing.expect(fc.waitTerminated());
}

test "RELAUNCH: ATTACH to a materialized session is dead+relaunchable; RELAUNCH revives it" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids, .tty = "/dev/ttys099" };
    var prng = std.Random.DefaultPrng.init(0xB0B);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Materialize a dead, relaunchable session directly in the store (simulating a
    // load-at-start from sessions.json). Recorded id is fixed so we can target it.
    const rec_id = "abcabcabcabcabcabcabcabcabcabcab";
    h.server.store.mutex.lock();
    _ = (h.server.store.table.materialize(.{
        .id = rec_id,
        .argv = "sleep 600",
        .fg_cmd = "claude --continue",
        .pinned = true,
        .created_ms = 50,
    }, 4096, h.clock.ms) catch unreachable).?;
    h.server.store.mutex.unlock();

    // ATTACH → dead + relaunchable (no exit_code); reply rides the session channel.
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = rec_id,
        .rows = 40,
        .cols = 120,
    });
    const af = try h.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.dead, ap.value.status);
    try testing.expect(ap.value.relaunchable);
    try testing.expect(ap.value.exit_code == null);
    // The dead reply names BOTH labels (T230/T429): the recorded relaunch argv
    // and the sampled foreground command the notice prefers.
    try testing.expectEqualStrings("sleep 600", ap.value.argv.?);
    try testing.expectEqualStrings("claude --continue", ap.value.foreground_cmd.?);
    const channel = af.channel; // the session's data channel

    // RELAUNCH → the agent spawns the child, revives the session, and replies ok.
    // The viewer sends its live env/TERM (respawn fidelity, wp3): the agent must
    // apply them to the synthesized OPEN so the respawned shell keeps its
    // GHOZTTY_PANE_ID & co. and TERM.
    const relaunch_env = [_]protocol.Open.EnvPair{
        .{ .key = "GHOZTTY_PANE_ID", .value = "0BAD-CAFE" },
    };
    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = rec_id,
        .rows = 40,
        .cols = 120,
        .env = &relaunch_env,
        .term = "xterm-256color",
    });
    const rf = try h.client.waitControl(.relaunched);
    try testing.expectEqual(channel, rf.channel);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.ok and rp.value.found);
    try testing.expect(rp.value.pid != 0);
    // The fresh spawn's tty rides RELAUNCHED (wp3).
    try testing.expectEqualStrings("/dev/ttys099", rp.value.tty.?);
    // The respawn's OPEN carried the viewer-sent env + TERM (wp3 fidelity).
    try testing.expectEqual(@as(usize, 1), sp.last_env_count);
    try testing.expectEqualStrings("GHOZTTY_PANE_ID", sp.lastEnvKey());
    try testing.expectEqualStrings("0BAD-CAFE", sp.lastEnvValue());
    try testing.expectEqualStrings("xterm-256color", sp.lastTerm());

    // The session is now alive + not relaunchable, and streams fresh output.
    // The sampled foreground command was CLEARED (T429): it described the old
    // child's world, and the respawn starts at a fresh prompt.
    // Read under the lock, assert after it (T436): a `try` that returns while
    // holding `store.mutex` re-enters it in the test's own `defer h.deinit()`
    // and the failure reports as a deadlock in `shutdown` instead of as itself.
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByChannel(channel).?;
    const alive = s.alive;
    const relaunchable = s.relaunchable;
    const fg_cmd_cleared = s.fg_cmd == null;
    // ...and the pane the viewer respawned it into was RECORDED (T552). This
    // record was materialized from a `sessions.json` with no pane id in it — the
    // shape an agent too old to persist the field leaves behind — so the
    // RELAUNCH env is the only place the answer could have come from.
    const pane_id = if (s.pane_id) |p| alloc.dupe(u8, p) catch null else null;
    defer if (pane_id) |p| alloc.free(p);
    h.server.store.mutex.unlock();
    try testing.expect(alive and !relaunchable);
    try testing.expect(fg_cmd_cleared);
    try testing.expectEqualStrings("0BAD-CAFE", pane_id.?);

    h.server.onChildOutput(channel, "back!");
    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 0), dp.byte_offset); // fresh stream from 0
    try testing.expectEqualSlices(u8, "back!", dp.bytes);
}

test "RELAUNCH: reboot ring snapshot is replayed (scrollback + divider) before live output" {
    const ring_snapshot = @import("ring_snapshot.zig");
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0xD1CE);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 1 << 16, prng.random());

    // Point the store's reboot-floor state at a temp dir and seed BOTH files a real
    // agent restart would find: sessions.json (the roster) + rings/<id>.ring (the
    // pre-restart scrollback snapshot). Then loadPersisted materializes the session
    // AND preloads its ring — exactly the reboot path.
    var tmp = testing.tmpDir(.{});
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    const meta = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    const rings = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    h.store.meta_path = meta;
    h.store.rings_dir = rings;
    // Ordered teardown (one defer, not several). The store only BORROWS
    // meta_path/rings_dir, and the server's reader threads touch them AFTER acking a
    // frame: handleRelaunch sends .relaunched and THEN calls persistMeta on the control
    // thread, and shutdown() calls snapshotRings. h.deinit() is what joins those
    // threads, so the borrowed paths and the temp dir must outlive it. Splitting these
    // into separate `defer`s frees the paths (LIFO) BEFORE h.deinit() joins the
    // threads, so a still-running persistMeta/snapshotRings writes through the freed
    // slices into the deleted dir — a use-after-free that surfaces as a garbage path
    // and a spurious EILSEQ/Unexpected snapshot-write warning. Deinit-then-free here
    // guarantees the writers are quiesced first.
    defer {
        h.deinit();
        alloc.free(rings);
        alloc.free(meta);
        alloc.free(dir_path);
        tmp.cleanup();
    }

    const rec_id = "abcabcabcabcabcabcabcabcabcabcab";
    const scrollback = "PANE=3 PID=4242\r\ntick-3-0\r\ntick-3-1\r\n";
    {
        const recs = [_]@import("session_meta.zig").Record{.{ .id = rec_id, .argv = "sleep 600", .pinned = true, .created_ms = 50 }};
        const body = try @import("session_meta.zig").serialize(alloc, &recs);
        defer alloc.free(body);
        try @import("session_meta.zig").writeAtomic(alloc, meta, body);
        const rp = try ring_snapshot.pathFor(alloc, rings, rec_id);
        defer alloc.free(rp);
        try ring_snapshot.writeAtomic(alloc, rp, 0, 80, 24, scrollback);
    }
    try testing.expectEqual(@as(usize, 1), h.store.loadPersisted(1 << 16));

    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // ATTACH → dead + relaunchable.
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = rec_id,
        .rows = 40,
        .cols = 120,
    });
    const af = try h.client.waitControl(.attached);
    const channel = af.channel;

    // RELAUNCH → reply carries replayed=true; the agent replays [scrollback][divider]
    // as one DATA frame at offset 0 BEFORE any live output.
    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = rec_id,
        .rows = 40,
        .cols = 120,
    });
    const rf = try h.client.waitControl(.relaunched);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.ok and rp.value.found);
    try testing.expect(rp.value.replayed); // scrollback was replayed

    // First DATA frame: the replayed scrollback + divider at offset 0.
    const d0 = (try h.client.nextData()).?;
    const dp0 = try protocol.DataPayload.decode(d0.payload);
    try testing.expectEqual(@as(u64, 0), dp0.byte_offset);
    const want = scrollback ++ session.reboot_divider;
    try testing.expectEqualSlices(u8, want, dp0.bytes);

    // Live output continues immediately AFTER the replayed content (no offset hole).
    h.server.onChildOutput(channel, "fresh-prompt$ ");
    const d1 = (try h.client.nextData()).?;
    const dp1 = try protocol.DataPayload.decode(d1.payload);
    try testing.expectEqual(@as(u64, want.len), dp1.byte_offset);
    try testing.expectEqualSlices(u8, "fresh-prompt$ ", dp1.bytes);
}

test "T824 RELAUNCH: the viewer's notice is spliced into the tail of the replay" {
    // The raw reboot-scrollback replay re-arms every mode the DEAD program
    // enabled — mouse tracking above all — in a pane that program no longer
    // controls, so hovering types `35;1;12M` into the respawned shell. The undo
    // has to be ORDERED between the replay and the respawned child's first byte:
    // a viewer that injects it locally races the child, and under `rerun` can
    // switch off the tracking the re-run TUI has just switched on. Only the
    // producer can order it, hence `Relaunch.notice`.
    const ring_snapshot = @import("ring_snapshot.zig");
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0xC0DE5);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 1 << 16, prng.random());

    var tmp = testing.tmpDir(.{});
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    const meta = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    const rings = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    h.store.meta_path = meta;
    h.store.rings_dir = rings;
    // Same deinit-then-free ordering as the sibling replay test above: the store
    // only BORROWS these paths and the reader threads touch them after acking a
    // frame.
    defer {
        h.deinit();
        alloc.free(rings);
        alloc.free(meta);
        alloc.free(dir_path);
        tmp.cleanup();
    }

    const rec_id = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
    const scrollback = "PANE=3 PID=4242\r\n\x1b[?1003h\x1b[?1006htick-3-0\r\n";
    {
        const recs = [_]@import("session_meta.zig").Record{.{ .id = rec_id, .argv = "htop", .pinned = true, .created_ms = 50 }};
        const body = try @import("session_meta.zig").serialize(alloc, &recs);
        defer alloc.free(body);
        try @import("session_meta.zig").writeAtomic(alloc, meta, body);
        const rp = try ring_snapshot.pathFor(alloc, rings, rec_id);
        defer alloc.free(rp);
        try ring_snapshot.writeAtomic(alloc, rp, 0, 80, 24, scrollback);
    }
    try testing.expectEqual(@as(usize, 1), h.store.loadPersisted(1 << 16));

    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = rec_id,
        .rows = 24,
        .cols = 80,
    });
    const af = try h.client.waitControl(.attached);
    const channel = af.channel;

    const notice = "\x1b[?1003l\x1b[?1006l";
    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = rec_id,
        .rows = 24,
        .cols = 80,
        .notice = notice,
    });

    const d0 = (try h.client.nextData()).?;
    const dp0 = try protocol.DataPayload.decode(d0.payload);
    // Order is the whole point: restored scrollback, then the agent's divider,
    // then our reset — and the reset is the TAIL, so the respawned child's first
    // output continues after it instead of being undone by it.
    const idx_back = std.mem.indexOf(u8, dp0.bytes, "PANE=3 PID=4242").?;
    const idx_arm = std.mem.indexOf(u8, dp0.bytes, "\x1b[?1003h").?;
    const idx_div = std.mem.indexOf(u8, dp0.bytes, session.reboot_divider).?;
    const idx_notice = std.mem.indexOf(u8, dp0.bytes, notice).?;
    try testing.expect(idx_back < idx_arm);
    try testing.expect(idx_arm < idx_div);
    try testing.expect(idx_div < idx_notice);
    try testing.expectEqual(dp0.bytes.len, idx_notice + notice.len);

    const rf = try h.client.waitControl(.relaunched);
    var rp2 = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp2.deinit();
    try testing.expect(rp2.value.ok and rp2.value.found);
    // `replayed` still means "there was a real snapshot" — sampled BEFORE the
    // notice was appended — so a notice alone can never make the viewer suppress
    // its own divider.
    try testing.expect(rp2.value.replayed);

    // No offset hole: the child's first byte lands immediately after the notice,
    // so the reset can never be re-applied on top of the respawned program.
    h.server.onChildOutput(channel, "fresh-prompt$ ");
    const d1 = (try h.client.nextData()).?;
    const dp1 = try protocol.DataPayload.decode(d1.payload);
    try testing.expectEqual(@as(u64, dp0.bytes.len), dp1.byte_offset);
    try testing.expectEqualSlices(u8, "fresh-prompt$ ", dp1.bytes);
}

test "T824 RELAUNCH: a notice on an EMPTY ring does not read as replayed scrollback" {
    // `replayed` is what makes the viewer suppress its own "session restarted"
    // divider. Sampled after the notice append it would be true for a blank
    // relaunch too, and the pane would come back with no marker at all.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc0: FakeChild = .{ .alloc = alloc };
    defer fc0.deinit();
    var fc1: FakeChild = .{ .alloc = alloc };
    defer fc1.deinit();
    var kids = [_]*FakeChild{ &fc0, &fc1 };
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0xBEEF5);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{
        .command = "sleep 600",
        .rows = 24,
        .cols = 80,
    });
    const of = try h.client.waitControl(.opened);
    var op = try protocol.parseJson(protocol.Opened, alloc, of.payload);
    defer op.deinit();

    // A reboot-materialized tombstone in place, with nothing in its ring.
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByIdStr(op.value.session_id).?;
    s.alive = false;
    s.relaunchable = true;
    const sid = s.id_str;
    h.server.store.mutex.unlock();

    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = &sid,
        .rows = 24,
        .cols = 80,
        .notice = "\x1b[?1003l",
    });
    const rf = try h.client.waitControl(.relaunched);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.ok and rp.value.found);
    try testing.expect(!rp.value.replayed);
    try testing.expectEqual(@as(u16, 0), rp.value.replay_cols);
    try testing.expectEqual(@as(u16, 0), rp.value.replay_rows);
}

test "T1264 RELAUNCH: a tombstone the running agent never reloaded still gets ONE divider" {
    // The reboot path preloads [scrollback][divider] from disk. A session whose
    // shell died under a STILL-RUNNING agent has scrollback in its live ring and
    // never went near that path — but `replayed` is true for it all the same, so
    // the viewer suppresses its own divider and the restart used to be invisible.
    // The agent places it, because only the producer can place it between the old
    // output and the respawned child's first byte.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc0: FakeChild = .{ .alloc = alloc };
    defer fc0.deinit();
    var fc1: FakeChild = .{ .alloc = alloc };
    defer fc1.deinit();
    var kids = [_]*FakeChild{ &fc0, &fc1 };
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0x1264);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{
        .command = "sleep 600",
        .rows = 24,
        .cols = 80,
    });
    const of = try h.client.waitControl(.opened);
    var op = try protocol.parseJson(protocol.Opened, alloc, of.payload);
    defer op.deinit();

    // Live output lands in the ring, and reaches the attached viewer as it happens.
    const before = "tick-0\r\ntick-1\r\n";
    h.server.onChildOutput(of.channel, before);
    const d_live = (try h.client.nextData()).?;
    const dp_live = try protocol.DataPayload.decode(d_live.payload);
    try testing.expectEqualSlices(u8, before, dp_live.bytes);

    // The shell dies: a tombstone with a NON-empty ring and no disk snapshot.
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByIdStr(op.value.session_id).?;
    s.alive = false;
    s.relaunchable = true;
    const sid = s.id_str;
    h.server.store.mutex.unlock();

    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = &sid,
        .rows = 24,
        .cols = 80,
    });
    const rf = try h.client.waitControl(.relaunched);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.ok and rp.value.found);
    // Scrollback was replayed, so the viewer prints nothing of its own...
    try testing.expect(rp.value.replayed);

    // ...and what it replays ENDS with the divider, exactly once, with the
    // pre-kill output above it rather than below.
    const d0 = (try h.client.nextData()).?;
    const dp0 = try protocol.DataPayload.decode(d0.payload);
    try testing.expectEqual(@as(u64, 0), dp0.byte_offset);
    const want = before ++ session.reboot_divider;
    try testing.expectEqualSlices(u8, want, dp0.bytes);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dp0.bytes, session.reboot_divider));

    // The respawned child's first output continues after it — no offset hole, and
    // nothing of the fresh shell lands above the marker.
    h.server.onChildOutput(of.channel, "fresh-prompt$ ");
    const d1 = (try h.client.nextData()).?;
    const dp1 = try protocol.DataPayload.decode(d1.payload);
    try testing.expectEqual(@as(u64, want.len), dp1.byte_offset);
    try testing.expectEqualSlices(u8, "fresh-prompt$ ", dp1.bytes);
}

test "OPEN records cwd → sessions.json carries it (T132 reboot floor)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0x132);

    // The store only BORROWS `meta_path`, and the server's threads can write
    // through it until `h.deinit()` joins them — so the temp dir and the path
    // must be declared BEFORE the harness, making their (LIFO) cleanup run
    // AFTER it. The reverse order is a use-after-free, not a test-only nit.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const meta_path = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(meta_path);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    h.store.meta_path = meta_path;

    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // The exact shape the loop's relaunch script sends: run a command, in a
    // named directory, pinned (a persistent local pane).
    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{
        .command = "claude --continue",
        .cwd = "/work/ghoztty",
        .rows = 24,
        .cols = 80,
        .pinned = true,
    });
    const of = try h.client.waitControl(.opened);
    var op = try protocol.parseJson(protocol.Opened, alloc, of.payload);
    defer op.deinit();

    // The spawn itself got the directory (it always did) ...
    try testing.expectEqualStrings("/work/ghoztty", sp.lastCwd().?);

    // ... and so does the session, so the reboot floor on disk can relaunch
    // there. Before T132 `cwd` was dropped here and the record had none.
    h.store.mutex.lock();
    const s = h.store.table.getByIdStr(op.value.session_id).?;
    const s_cwd = s.cwd;
    h.store.mutex.unlock();
    try testing.expectEqualStrings("/work/ghoztty", s_cwd.?);

    // `handleOpen` persists on its own thread right after OPENED; persist here
    // so the read below is ordered rather than racing that write.
    h.store.persistMeta();

    const session_meta = @import("session_meta.zig");
    var parsed = (try session_meta.load(alloc, meta_path)).?;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.sessions.len);
    try testing.expectEqualStrings("/work/ghoztty", parsed.value.sessions[0].cwd.?);
    try testing.expectEqualStrings("claude --continue", parsed.value.sessions[0].argv.?);
}

test "RELAUNCH respawns in the RECORDED cwd, not the agent's (T132)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0x133);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // A tombstone materialized from sessions.json after an agent restart —
    // the state the loop's panes were in when the upgrade script replaced the
    // agent binary.
    const rec_id = "dededededededededededededededede";
    h.server.store.mutex.lock();
    _ = (h.server.store.table.materialize(.{
        .id = rec_id,
        .argv = "claude --continue",
        .cwd = "/work/ghoztty",
        .pinned = true,
        .created_ms = 50,
    }, 4096, h.clock.ms) catch unreachable).?;
    h.server.store.mutex.unlock();

    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = rec_id,
        .rows = 24,
        .cols = 80,
    });
    const rf = try h.client.waitControl(.relaunched);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.ok and rp.value.found);

    // The respawn ran in the recorded directory. With no recorded cwd this is
    // null and the child inherits the AGENT's cwd — on the win32 auto-launch
    // path, the launching script's (`C:\Windows\System32`).
    try testing.expectEqualStrings("/work/ghoztty", sp.lastCwd().?);
}

test "RELAUNCH: unknown session id → not found (client falls back to OPEN)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(0xF00D);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = "ffffffffffffffffffffffffffffffff",
        .rows = 24,
        .cols = 80,
    });
    const rf = try h.client.waitControl(.relaunched);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(!rp.value.ok and !rp.value.found);
}

test "RESIZE and SIGNAL are recorded on the child" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(8);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlJson(.resize, o.channel, protocol.Resize{ .rows = 50, .cols = 120, .px_w = 1, .px_h = 2 });
    try h.client.sendControlJson(.signal, o.channel, protocol.Signal{ .name = "INT" });

    // Wait until both are observed (control reader is async) — and fail HERE,
    // at the wait, if they never are. This bool used to be discarded, so a
    // timed-out wait fell through to a `.?` and the lane's headline was
    // `attempt to use null value` with no hint of what had been awaited (T183).
    const P = struct {
        fn both(c: *FakeChild) bool {
            return c.lastResize() != null and c.lastSignalIs("INT");
        }
    };
    try testing.expect(waitUntil("the child to see both the resize and the signal", P.both, .{&fc}));
    try testing.expectEqual([4]u16{ 50, 120, 1, 2 }, fc.lastResize().?);
    try testing.expect(fc.lastSignalIs("INT"));
    // Session dims updated.
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByChannel(o.channel).?;
    const s_rows = s.rows;
    h.server.store.mutex.unlock();
    try testing.expectEqual(@as(u16, 50), s_rows);
}

test "FLOW pause halts streaming; resume continues from buffered offset" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(9);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });

    // Pause the channel, then feed output — it must NOT be framed (only ringed).
    try h.client.sendControlRaw(.flow, protocol.control_channel, blk: {
        const fl: protocol.Flow = .{ .channel = o.channel, .op = .pause };
        var buf: [protocol.Flow.encoded_len]u8 = undefined;
        _ = fl.encodeInto(&buf);
        break :blk &buf;
    });
    // Wait until the pause is applied.
    const P = struct {
        fn streaming(s: *Server, ch: u128) bool {
            s.store.mutex.lock();
            defer s.store.mutex.unlock();
            return s.store.table.getByChannel(ch).?.streaming;
        }
        fn paused(s: *Server, ch: u128) bool {
            return !streaming(s, ch);
        }
    };
    try testing.expect(waitUntil("the session to stop streaming (paused)", P.paused, .{ h.server, o.channel }));
    h.server.onChildOutput(o.channel, "PAUSED"); // ringed at offset 0, not sent

    // Resume → subsequent output streams live (the buffered bytes recover via
    // attach gap-fill in production; here we assert the gate releases).
    try h.client.sendControlRaw(.flow, protocol.control_channel, blk: {
        const fl: protocol.Flow = .{ .channel = o.channel, .op = .@"resume" };
        var buf: [protocol.Flow.encoded_len]u8 = undefined;
        _ = fl.encodeInto(&buf);
        break :blk &buf;
    });
    try testing.expect(waitUntil("the session to resume streaming", P.streaming, .{ h.server, o.channel }));
    h.server.onChildOutput(o.channel, "LIVE"); // streams at offset 6

    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 6), dp.byte_offset); // offset advanced past PAUSED
    try testing.expectEqualSlices(u8, "LIVE", dp.bytes);
}

test "PING is answered with PONG echoing the payload" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var sp: FakeSpawner = .{ .children = &.{} };
    var prng = std.Random.DefaultPrng.init(10);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const stamp = "\x00\x00\x00\x00\x00\x00\x00\x2a"; // arbitrary 8-byte payload
    try h.client.sendControlRaw(.ping, protocol.control_channel, stamp);
    const pong = try h.client.waitControl(.pong);
    try testing.expectEqualSlices(u8, stamp, pong.payload);
}

test "DETACH stops streaming but keeps the session alive" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(11);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlRaw(.detach, o.channel, "");
    const P = struct {
        fn detached(s: *Server, ch: u128) bool {
            s.store.mutex.lock();
            defer s.store.mutex.unlock();
            const sess = s.store.table.getByChannel(ch).?;
            return !sess.streaming and sess.alive;
        }
    };
    try testing.expect(waitUntil("the session to detach (alive, not streaming)", P.detached, .{ h.server, o.channel }));
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByChannel(o.channel).?;
    const s_streaming = s.streaming;
    const s_alive = s.alive;
    h.server.store.mutex.unlock();
    try testing.expect(!s_streaming);
    try testing.expect(s_alive);
}

test "unknown channel DATA is ignored (no crash, no child write)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(12);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    // Send DATA to a channel that doesn't exist; then a valid one. Only the valid
    // one should reach the child.
    try h.client.sendDataInput(0xDEAD_BEEF, 0, "ghost");
    try h.client.sendDataInput(o.channel, 0, "real");
    const P = struct {
        fn sawInput(c: *FakeChild, a: Allocator) !bool {
            const got = try c.inputCopy(a);
            defer a.free(got);
            return std.mem.eql(u8, got, "real");
        }
    };
    try testing.expect(waitUntil("the child to see the written input", P.sawInput, .{ &fc, alloc }));
    const got = try fc.inputCopy(alloc);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, "real", got); // "ghost" never landed
}

test "clean shutdown joins all threads without hanging or leaking" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(13);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    // Open a session, leave it alive, then tear down via deinit (shutdown+destroy).
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    h.server.onChildOutput(o.channel, "some output"); // exercise the streaming path
    _ = try h.client.nextData();
    h.deinit(); // must not hang; testing.allocator catches leaks
}

// --- P1: session survival across disconnect + reconnect catch-up --------------

/// A second connection (Server + client + loopbacks) over an EXISTING shared store,
/// modeling a reconnect. The store/spawner/clock are owned by the first Harness.
const ReConn = struct {
    alloc: Allocator,
    ctrl_lb: *Loopback,
    data_lb: *Loopback,
    server: *Server,
    client: MockClient,

    fn init(h: *Harness, enc: protocol.TransferEncoding) !ReConn {
        const alloc = h.alloc;
        const ctrl_lb = try alloc.create(Loopback);
        ctrl_lb.* = Loopback.init(alloc);
        const data_lb = try alloc.create(Loopback);
        data_lb.* = Loopback.init(alloc);
        const server = try Server.create(
            alloc,
            ctrl_lb.agentStream(),
            data_lb.agentStream(),
            h.spawner.spawner(),
            h.store,
            .{ .encoding = enc, .ring_bytes = 4096, .clock = h.clock.clock() },
        );
        const client = MockClient.init(alloc, ctrl_lb.clientStream(), data_lb.clientStream(), enc);
        return .{ .alloc = alloc, .ctrl_lb = ctrl_lb, .data_lb = data_lb, .server = server, .client = client };
    }
    fn deinit(self: *ReConn) void {
        self.server.shutdown();
        self.client.deinit();
        self.server.destroy(self.alloc);
        self.ctrl_lb.deinit();
        self.data_lb.deinit();
        self.alloc.destroy(self.ctrl_lb);
        self.alloc.destroy(self.data_lb);
    }
};

test "P1: session survives connection drop; reattach replays the ring gap (catch-up)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(20);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Conn 1: open, see some live output (offsets 0..5), then DROP the connection
    // WITHOUT closing the session (shutdown DETACHes, never terminates).
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    var id_buf: [32]u8 = o.id;
    h.server.onChildOutput(o.channel, "hello"); // offset 0, S=5
    _ = try h.client.nextData();
    h.server.shutdown(); // laptop close: detach, keep session + ring alive

    // The session must STILL be in the shared store, alive, ringing.
    h.store.mutex.lock();
    const survived = h.store.table.getByChannel(o.channel);
    const survived_alive = if (survived) |sv| sv.alive else false;
    const survived_bound = if (survived) |sv| sv.bound else false;
    h.store.mutex.unlock();
    try testing.expect(survived != null);
    try testing.expect(survived_alive);
    try testing.expect(!survived_bound); // orphaned now

    // While disconnected, the child keeps producing — recorded into the ring even
    // though no connection is bound (offsets 5..16).
    h.server.onChildOutput(o.channel, "WORLD-GAP!!"); // offset 5, S=16

    // Conn 2: reconnect over the SAME store and ATTACH with last_byte_offset=5
    // (everything we'd seen). The agent must replay (5,16] = "WORLD-GAP!!".
    var rc = try ReConn.init(&h, .raw);
    defer rc.deinit();
    try rc.server.start();
    try rc.client.handshake();
    _ = try rc.server.waitHandshake();

    try rc.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 5,
    });
    const af = try rc.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u64, 16), ap.value.snapshot_at_offset);

    // The replayed gap arrives as DATA at offset 5 — the bytes produced WHILE GONE.
    const d = try rc.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 5), dp.byte_offset);
    try testing.expectEqualSlices(u8, "WORLD-GAP!!", dp.bytes);

    // And live streaming resumes on the NEW connection (offset 16 forward).
    h.server.onChildOutput(o.channel, "+live");
    const d2 = try rc.client.nextData();
    const dp2 = try protocol.DataPayload.decode(d2.?.payload);
    try testing.expectEqual(@as(u64, 16), dp2.byte_offset);
    try testing.expectEqualSlices(u8, "+live", dp2.bytes);
}

test "P1: explicit DETACH orphans the session (kept alive, unbound, not streaming)" {
    const alloc = testing.allocator;
    var clock: TestClock = .{};
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(21);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlRaw(.detach, o.channel, "");
    const P = struct {
        fn orphaned(st: *session.SessionStore, ch: u128) bool {
            st.mutex.lock();
            defer st.mutex.unlock();
            const s = st.table.getByChannel(ch).?;
            return !s.streaming and !s.bound and s.alive;
        }
    };
    try testing.expect(waitUntil("the session to be orphaned (alive, unbound, not streaming)", P.orphaned, .{ h.store, o.channel }));
    h.store.mutex.lock();
    const s = h.store.table.getByChannel(o.channel).?;
    const s_alive = s.alive;
    const s_streaming = s.streaming;
    const s_bound = s.bound;
    h.store.mutex.unlock();
    try testing.expect(s_alive and !s_streaming and !s_bound);
}

test "T534: unattached_since stamps the detach, resets on re-attach, and rides the roster" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(53);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // A LIST_SESSIONS reply echoes on the REQUEST channel; the roster pump
    // pushes byte-identical frames on the control channel whenever the roster
    // changes, so the helper skips pushes by channel rather than by luck.
    const L = struct {
        fn unattachedOf(hh: *Harness, ch: u128, id: []const u8) !?i64 {
            try hh.client.sendControlJson(.list_sessions, ch, protocol.ListSessions{});
            while (true) {
                const f = try hh.client.waitControl(.sessions);
                if (f.channel != ch) continue;
                var p = try protocol.parseJson(protocol.Sessions, testing.allocator, f.payload);
                defer p.deinit();
                for (p.value.sessions) |s| {
                    if (std.mem.eql(u8, s.id, id)) return s.unattached_since;
                }
                return error.SessionMissing;
            }
        }
    };

    // Attached from OPEN: no unattached clock on the wire.
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    var id_buf: [32]u8 = o.id;
    try testing.expectEqual(@as(?i64, null), try L.unattachedOf(&h, 0x111, id_buf[0..]));

    // DETACH at a known instant: the roster reports exactly that instant.
    clock.ms = 5000;
    try h.client.sendControlRaw(.detach, o.channel, "");
    try h.client.sendControlRaw(.ping, protocol.control_channel, "detach-sync");
    _ = try h.client.waitControl(.pong);
    try testing.expectEqual(@as(?i64, 5000), try L.unattachedOf(&h, 0x222, id_buf[0..]));

    // Re-ATTACH: the clock resets — "continuously unattached since" never
    // survives a viewer having looked at the session.
    clock.ms = 9000;
    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
    });
    _ = try h.client.waitControl(.attached);
    try testing.expectEqual(@as(?i64, null), try L.unattachedOf(&h, 0x333, id_buf[0..]));
}

test "WP-D1: stale DETACH from a superseded connection must not silence the new owner" {
    // The reconnect-swap wedge: conn 1 owns a session; conn 2 ATTACHes (the
    // agent rebinds the bridge — implicit steal); THEN conn 1's old surface
    // teardown sends DETACH for the same channel. That stale DETACH must be a
    // no-op: the session keeps streaming to conn 2. Pre-fix it stopped
    // `streaming` unconditionally and the freshly swapped window went silent.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(23);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // Conn 1: open; some output so the attach below can anchor past it.
    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    var id_buf: [32]u8 = o.id;
    h.server.onChildOutput(o.channel, "hello"); // offsets [0,5)
    _ = try h.client.nextData();

    // Conn 2 over the SAME store: ATTACH rebinds the bridge (conn 1 still open).
    var rc = try ReConn.init(&h, .raw);
    defer rc.deinit();
    try rc.server.start();
    try rc.client.handshake();
    _ = try rc.server.waitHandshake();
    try rc.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 5,
    });
    const af = try rc.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);

    // Conn 1: the STALE DETACH (the swapped-out surface tearing down). Sync
    // with a PING/PONG on the same control lane so we know it was processed.
    try h.client.sendControlRaw(.detach, o.channel, "");
    try h.client.sendControlRaw(.ping, protocol.control_channel, "stale-detach-sync");
    _ = try h.client.waitControl(.pong);

    // The session must STILL be bound + streaming to conn 2...
    h.store.mutex.lock();
    const s = h.store.table.getByChannel(o.channel).?;
    const s_alive = s.alive;
    const s_bound = s.bound;
    const s_streaming = s.streaming;
    h.store.mutex.unlock();
    try testing.expect(s_alive and s_bound and s_streaming);

    // ...and live output must still reach conn 2.
    h.server.onChildOutput(o.channel, "+live");
    const d = try rc.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 5), dp.byte_offset);
    try testing.expectEqualSlices(u8, "+live", dp.bytes);
}

test "stale CLOSE from a superseded connection must not kill the new owner's session" {
    // The 2026-07-21 session-kill incident, at the agent: conn 1 owns a session;
    // conn 2 ATTACHes (the agent rebinds the bridge — the in-place rebuild swap);
    // THEN conn 1's orphaned surface finally deallocates and sends CLOSE for the
    // same channel. Pre-fix that stale CLOSE unlinked the session and terminated
    // the child conn 2 was using, leaving a live-looking pane with nothing behind
    // it. It must be a no-op.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(29);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    const o = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    var id_buf: [32]u8 = o.id;
    h.server.onChildOutput(o.channel, "hello"); // offsets [0,5)
    _ = try h.client.nextData();

    // Conn 2 over the SAME store: ATTACH rebinds the bridge (conn 1 still open).
    var rc = try ReConn.init(&h, .raw);
    defer rc.deinit();
    try rc.server.start();
    try rc.client.handshake();
    _ = try rc.server.waitHandshake();
    try rc.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = id_buf[0..],
        .rows = 24,
        .cols = 80,
        .last_byte_offset = 5,
    });
    const af = try rc.client.waitControl(.attached);
    var ap = try protocol.parseJson(protocol.Attached, alloc, af.payload);
    defer ap.deinit();
    try testing.expectEqual(protocol.Attached.AttachStatus.alive, ap.value.status);

    // Conn 1: the STALE CLOSE. Sync with a PING/PONG on the same control lane so
    // we know it was processed before we assert.
    try h.client.sendControlRaw(.close, o.channel, "");
    try h.client.sendControlRaw(.ping, protocol.control_channel, "stale-close-sync");
    _ = try h.client.waitControl(.pong);

    // The session must still exist, still be bound + streaming, and the child
    // must NOT have been terminated.
    h.store.mutex.lock();
    const s = h.store.table.getByChannel(o.channel);
    const s_live = if (s) |sess| sess.alive and sess.bound and sess.streaming else false;
    h.store.mutex.unlock();
    try testing.expect(s != null);
    try testing.expect(s_live);
    try testing.expect(!fc.wasTerminated());

    // ...and live output must still reach conn 2.
    h.server.onChildOutput(o.channel, "+live");
    const d = try rc.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    try testing.expectEqual(@as(u64, 5), dp.byte_offset);
    try testing.expectEqualSlices(u8, "+live", dp.bytes);
}

test "CLOSE from the bridge owner still frees the session (guard is not a blanket refusal)" {
    // The guard's counterpart: a normal user close over the OWNING connection
    // must keep working, and so must a close of an UNBOUND (detached, orphaned)
    // session — nobody owns it, so there is nothing to protect and refusing
    // would only leak it until the idle TTL.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 1000 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var fc2: FakeChild = .{ .alloc = alloc };
    defer fc2.deinit();
    var kids = [_]*FakeChild{ &fc, &fc2 };
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(31);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    // 1) Owner closes its own session.
    const owned = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlRaw(.close, owned.channel, "");

    // 2) DETACH first (bridge_ctx → null), THEN close the orphan.
    const orphan = try doOpen(&h, .{ .rows = 24, .cols = 80 });
    try h.client.sendControlRaw(.detach, orphan.channel, "");
    try h.client.sendControlRaw(.close, orphan.channel, "");

    try h.client.sendControlRaw(.ping, protocol.control_channel, "close-sync");
    _ = try h.client.waitControl(.pong);

    // Both terminates land AFTER their unlinks (see `FakeChild.waitTerminated`),
    // so waiting on the terminates covers both phases for both sessions.
    try testing.expect(fc.waitTerminated());
    try testing.expect(fc2.waitTerminated());
    {
        h.store.mutex.lock();
        defer h.store.mutex.unlock();
        try testing.expect(h.store.table.getByChannel(owned.channel) == null);
        try testing.expect(h.store.table.getByChannel(orphan.channel) == null);
    }
}

test "P1: idle-TTL reaper evicts an orphaned session once past the TTL" {
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 0 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var prng = std.Random.DefaultPrng.init(22);

    // Build a store with a SMALL idle TTL (100ms) and no reaper thread; we invoke
    // reapIdle explicitly under the fixed clock.
    const store = try alloc.create(session.SessionStore);
    defer alloc.destroy(store);
    store.* = session.SessionStore.init(alloc, prng.random(), &clock, TestClock.now, 100);
    defer store.deinit();

    // A bound session is NEVER reaped, even past TTL.
    const s = try store.table.create(fc.child(), 1, 24, 80, 1024, 0);
    const channel = s.channel; // capture: `s` becomes dangling once reaped + freed
    s.bound = true;
    s.last_activity_ms = 0;
    clock.ms = 10_000; // way past TTL
    store.reapIdle();
    try testing.expect(store.table.getByChannel(channel) != null); // bound ⇒ kept

    // Orphan it; now it is reaped once last_activity is older than the TTL.
    s.bound = false;
    s.last_activity_ms = 10_000;
    clock.ms = 10_050; // only 50ms idle (< 100ms TTL) ⇒ still kept
    store.reapIdle();
    try testing.expect(store.table.getByChannel(channel) != null);

    clock.ms = 10_200; // 200ms idle (> 100ms TTL) ⇒ reaped + child terminated
    store.reapIdle();
    try testing.expect(store.table.getByChannel(channel) == null);
    try testing.expect(fc.wasTerminated());
}

test "OPEN records the session cwd so a RELAUNCH respawns in it" {
    // `session-relaunch=restore` promises "a shell in the session's recorded
    // working directory", and the recorded cwd is the only thing that can deliver
    // it — `RELAUNCH` carries no cwd, so `handleRelaunch` reads `s.cwd`. That
    // field was never written on `handleOpen`, so it was permanently null and
    // every reboot-floor respawn (this policy and the old re-run alike) landed in
    // whatever cwd the AGENT happened to have.
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc0: FakeChild = .{ .alloc = alloc };
    defer fc0.deinit();
    var fc1: FakeChild = .{ .alloc = alloc };
    defer fc1.deinit();
    var kids = [_]*FakeChild{ &fc0, &fc1 };
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 4096, prng.random());
    defer h.deinit();
    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.open, protocol.control_channel, protocol.Open{
        .cwd = "/tmp/worktree",
        .command = "cl --resume",
        .rows = 24,
        .cols = 80,
    });
    const of = try h.client.waitControl(.opened);
    var op = try protocol.parseJson(protocol.Opened, alloc, of.payload);
    defer op.deinit();
    try testing.expectEqualStrings("/tmp/worktree", sp.lastCwd().?);

    // Recorded on the session, hence in `sessions.json` and hence survivable
    // across the agent restart the reboot floor exists for.
    h.server.store.mutex.lock();
    const s = h.server.store.table.getByIdStr(op.value.session_id).?;
    const s_cwd = s.cwd;
    // Fake a reboot-materialized tombstone in place: the child is gone but the
    // relaunch metadata is what came back off disk.
    s.alive = false;
    s.relaunchable = true;
    const sid = s.id_str;
    h.server.store.mutex.unlock();
    try testing.expectEqualStrings("/tmp/worktree", s_cwd.?);

    // The `restore` client sends a plain login-shell argv, which nulls the
    // recorded command in the synthesized OPEN. The cwd must survive that.
    const shell_argv = [_][]const u8{ "/bin/zsh", "-li" };
    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = &sid,
        .rows = 24,
        .cols = 80,
        .argv = &shell_argv,
    });
    const rf = try h.client.waitControl(.relaunched);
    var rp = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp.deinit();
    try testing.expect(rp.value.ok and rp.value.found);
    try testing.expectEqualStrings("/tmp/worktree", sp.lastCwd().?);
}

test "RELAUNCH: the viewer's notice is spliced into the replay, not after it" {
    // Bug-1/bug-2 UX: a client that prints its "session was lost" line locally
    // loses it — the inject lands after the respawned shell owns the screen and
    // the shell's first prompt repaint blanks the line (the agent-baked divider
    // one row up survives, which is what makes the diagnosis unambiguous). So the
    // agent has to put it in the STREAM: after the restored scrollback + divider,
    // and before the child's first byte.
    const ring_snapshot = @import("ring_snapshot.zig");
    const alloc = testing.allocator;
    var clock: TestClock = .{ .ms = 100 };
    var fc: FakeChild = .{ .alloc = alloc };
    defer fc.deinit();
    var kids = [_]*FakeChild{&fc};
    var sp: FakeSpawner = .{ .children = &kids };
    var prng = std.Random.DefaultPrng.init(0xC0DE5);

    var h = try Harness.init(alloc, .raw, &clock, &sp, 1 << 16, prng.random());

    var tmp = testing.tmpDir(.{});
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    const meta = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    const rings = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    h.store.meta_path = meta;
    h.store.rings_dir = rings;
    // Same deinit-then-free ordering as the sibling replay test: the store only
    // BORROWS these paths and the reader threads touch them after acking a frame.
    defer {
        h.deinit();
        alloc.free(rings);
        alloc.free(meta);
        alloc.free(dir_path);
        tmp.cleanup();
    }

    const rec_id = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
    const scrollback = "PANE=3 PID=4242\r\ntick-3-0\r\n";
    {
        const recs = [_]@import("session_meta.zig").Record{.{ .id = rec_id, .argv = "cl --resume", .pinned = true, .created_ms = 50 }};
        const body = try @import("session_meta.zig").serialize(alloc, &recs);
        defer alloc.free(body);
        try @import("session_meta.zig").writeAtomic(alloc, meta, body);
        const rp = try ring_snapshot.pathFor(alloc, rings, rec_id);
        defer alloc.free(rp);
        try ring_snapshot.writeAtomic(alloc, rp, 0, 80, 24, scrollback);
    }
    try testing.expectEqual(@as(usize, 1), h.store.loadPersisted(1 << 16));

    try h.server.start();
    try h.client.handshake();
    _ = try h.server.waitHandshake();

    try h.client.sendControlJson(.attach, protocol.control_channel, protocol.Attach{
        .session_id = rec_id,
        .rows = 24,
        .cols = 80,
    });
    _ = try h.client.waitControl(.attached);

    const notice = "\r\n--- previous session was lost ---\r\n";
    try h.client.sendControlJson(.relaunch, protocol.control_channel, protocol.Relaunch{
        .session_id = rec_id,
        .rows = 24,
        .cols = 80,
        .notice = notice,
    });

    const d = try h.client.nextData();
    const dp = try protocol.DataPayload.decode(d.?.payload);
    const idx_back = std.mem.indexOf(u8, dp.bytes, "PANE=3 PID=4242").?;
    const idx_div = std.mem.indexOf(u8, dp.bytes, session.reboot_divider).?;
    const idx_notice = std.mem.indexOf(u8, dp.bytes, notice).?;
    try testing.expect(idx_back < idx_div);
    try testing.expect(idx_div < idx_notice);
    // The notice is the TAIL of the replay, so the respawned child's first output
    // continues immediately after it rather than landing on top of it.
    try testing.expectEqual(dp.bytes.len, idx_notice + notice.len);

    const rf = try h.client.waitControl(.relaunched);
    var rp2 = try protocol.parseJson(protocol.Relaunched, alloc, rf.payload);
    defer rp2.deinit();
    // `replayed` still means "there was a real snapshot" — sampled before the
    // notice was appended — so a notice alone can never make the viewer suppress
    // its own divider.
    try testing.expect(rp2.value.replayed);
}
