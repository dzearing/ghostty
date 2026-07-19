//! Agent-side session model (WP2, §7.1) — the remote-host counterpart to the
//! client's `Pane`/`Channel`. A `Session` ties a spawned child process to one
//! data channel, tracks its dimensions / cwd / title / activity state, retains a
//! bounded **raw-output ring** (recent scrollback for sequence-anchored resync,
//! §7.3), and owns the per-channel outbound `ByteOffset` that anchors every
//! child→client `DATA` frame.
//!
//! This module is deliberately transport-agnostic: it knows nothing about
//! `Stream`, framing, or threads. The `Server` (`server.zig`) drives it. The only
//! cross-module dependency is `protocol.zig` (the pure wire contract) — so this
//! file unit-tests standalone.
//!
//! ## Child abstraction
//!
//! A `Child` is an interface (vtable) over "a process attached to a pty". The
//! real implementation is `pty_child.zig` (POSIX pty via `src/pty.zig`, Windows
//! ConPTY), wired into every production serve path in `main.zig`; a fake,
//! buffer-backed child is used only by the tests. The vtable seam means the
//! `Server` is identical for both.
//!
//! ## Real vs. a known limitation
//!
//!   - Session table, ids, caps, tombstones, ring, byte-offset: **real**.
//!   - Child process: **real** (`pty_child.zig`); tests inject a fake.
//!   - Idle-TTL / ring-memory GC: **real** — the background reaper
//!     (`startReaper`) evicts orphaned sessions past `default_idle_ttl_ms`.
//!   - Grid snapshot for resync: **known limitation** — `snapshotOffset()`
//!     anchors the current outbound offset `S` and reconnect replays the ring
//!     forward from the client's last offset (byte-exact within the ~2 MB ring;
//!     deeper scrollback is dropped with a visible marker). A true grid-model
//!     snapshot at `S` (§7.3), so eviction is invisible, is future work.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
// `protocol` is the shared wire contract (`src/remote/protocol.zig`), imported
// relatively — the same path the `zig build agent` graph uses. Standalone tests
// root one level up (`src/remote/agent_test.zig`) so this `../` stays inside the
// module path; see `server.zig`'s "Running the tests" note.
const protocol = @import("../protocol.zig");
// Metadata persistence (T12, §5.4 reboot floor). `session_meta` depends on
// nothing but `std`, so importing it here introduces no cycle.
const session_meta = @import("session_meta.zig");
// Ring disk snapshots (T13, §5.4 reboot scrollback). Like `session_meta`, depends
// only on `std`, so no import cycle.
const ring_snapshot = @import("ring_snapshot.zig");
// Opaque layout-blob persistence (T18, §5.4 cross-machine "Resume all"). Like
// `session_meta`, depends on nothing but `std`.
const layout_meta = @import("layout_meta.zig");
// Headless per-session terminal emulator for the re-attach grid snapshot (FIX 2).
// Imports src/terminal — the only heavyweight dependency this module pulls; kept
// behind an optional pointer so it costs nothing until a session produces output.
const grid_snapshot = @import("grid_snapshot.zig");

// -----------------------------------------------------------------------------
// Caps (§7.1 "Resource caps & TTL")
// -----------------------------------------------------------------------------

/// Maximum concurrent sessions per agent. Raised 64 → 256 (T11) so a heavy
/// session-persistence user with many restored windows/panes plus fresh ones
/// isn't refused new `OPEN`s; each idle session still costs a pty child + its
/// output ring, so the cap is bounded. An `OPEN` past this is refused.
pub const max_sessions: usize = 256;

/// Default per-session raw-output ring size (§7.1: default 2 MB scrollback). Holds
/// the most recent child-output bytes so `(last_byte_offset, S]` gap-fill is
/// possible on reattach (§7.3). Lowered freely in tests.
pub const default_ring_bytes: usize = 2 * 1024 * 1024;

/// The divider baked into a reboot-restored ring between the replayed pre-restart
/// scrollback and the freshly-relaunched shell's output (§5.4, T13). Byte-for-byte
/// the SAME string the client prints on a snapshot-less relaunch (termio/Remote.zig)
/// so there is exactly one canonical "restart" marker — when the agent replays a
/// snapshot it owns the divider (baked here, at the right place in the byte stream)
/// and the client suppresses its own (`Relaunched.replayed`).
pub const reboot_divider = "\r\n\x1b[2m--- session restarted ---\x1b[0m\r\n";

// -----------------------------------------------------------------------------
// Activity state (mirrors the local +set-state model: idle/busy/needs_input)
// -----------------------------------------------------------------------------

/// Per-session activity state. Carried in `META` to the client for the activity
/// view (§9.3). Priority for any future aggregation is needs_input > busy > idle.
pub const ActivityState = enum { idle, busy, needs_input };

// -----------------------------------------------------------------------------
// Child — an abstract spawned process attached to a pty
// -----------------------------------------------------------------------------

/// Vtable over "a process attached to a pty/ConPTY". The `Server` writes client
/// keystrokes via `write`, resizes via `resize`, delivers signals via `signal`,
/// and reaps via `tryWait`. Child OUTPUT is delivered the other direction: the
/// owner installs an `OutputSink` (see `Session.sink`) that the child impl calls
/// when bytes are available.
///
/// Threading: for the fake child everything is synchronous and single-threaded
/// (tests pump output explicitly). The real pty child (`pty_child.zig`) owns a
/// reader thread that calls the sink; the `Server`'s session lock serializes sink
/// delivery with frame handling.
pub const Child = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Optional: called once by the `Server` immediately after the session is
        /// registered, handing the child its owning channel and an opaque
        /// "deliver output" sink. A real pty child starts (or unblocks) its
        /// master-fd reader thread here so output is routed to the right channel;
        /// the fake child (tests pump output out-of-band) leaves this null. The
        /// sink is `fn(server_ctx, channel, bytes)` — exactly `Server.onChildOutput`
        /// bound to the server pointer. Best-effort; never fails.
        attach: ?*const fn (
            ctx: *anyopaque,
            sink_ctx: *anyopaque,
            sink: *const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void,
            channel: u128,
        ) void = null,
        /// Write `bytes` to the child's stdin/pty master. Returns bytes written
        /// (caller loops on a short write). Error ⇒ the child's input side is gone.
        write: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,
        /// Resize the child's pty window. Best-effort; errors are non-fatal.
        resize: *const fn (ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void,
        /// Deliver a signal by POSIX name ("INT", "TERM", "KILL", ...). For the
        /// fake child this records the last signal; the real child maps it to
        /// `kill(2)` on the child's pgid.
        signal: *const fn (ctx: *anyopaque, name: []const u8) anyerror!void,
        /// Non-blocking reap. Returns the exit code if the child has exited, else
        /// null. The real impl wraps `waitpid(WNOHANG)`.
        tryWait: *const fn (ctx: *anyopaque) ?i64,
        /// Terminate the child unconditionally (SIGKILL + reap) and release its
        /// handle. Idempotent. Called on `CLOSE` and on session teardown.
        terminate: *const fn (ctx: *anyopaque) void,
        /// Optional: query the child process's CURRENT working directory by asking
        /// the OS (e.g. macOS `proc_pidinfo(PROC_PIDVNODEPATHINFO)`, Windows PEB
        /// read). Returns a NEW `alloc`-owned UTF-8 slice (caller frees), or null
        /// if the query is unsupported or fails. The fake child leaves this null.
        queryCwd: ?*const fn (ctx: *anyopaque, alloc: Allocator) ?[]u8 = null,
        /// Optional: the pty's CURRENT foreground pid (`tcgetpgrp` on the master
        /// fd), or null when unsupported (Windows ConPTY has no foreground
        /// process group — parity with the local `WindowsPty`, which also
        /// answers null) or the query fails. MUST be cheap and non-blocking (a
        /// single syscall): the store's sampling tick calls it UNDER the store
        /// mutex so the child cannot be freed mid-query (wp3).
        queryForegroundPid: ?*const fn (ctx: *anyopaque) ?i64 = null,
    };

    /// Hand the child its owning channel + output sink (see `VTable.attach`).
    /// No-op when the impl declines (`attach == null`).
    pub fn attach(
        self: Child,
        sink_ctx: *anyopaque,
        sink: *const fn (sink_ctx: *anyopaque, channel: u128, bytes: []const u8) void,
        channel: u128,
    ) void {
        if (self.vtable.attach) |f| f(self.ctx, sink_ctx, sink, channel);
    }

    pub fn write(self: Child, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.ctx, bytes);
    }

    /// Write the entirety of `bytes`, looping over short writes.
    pub fn writeAll(self: Child, bytes: []const u8) anyerror!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try self.vtable.write(self.ctx, bytes[off..]);
            if (n == 0) return error.WriteZero;
            off += n;
        }
    }

    pub fn resize(self: Child, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
        return self.vtable.resize(self.ctx, rows, cols, px_w, px_h);
    }

    pub fn signal(self: Child, name: []const u8) anyerror!void {
        return self.vtable.signal(self.ctx, name);
    }

    pub fn tryWait(self: Child) ?i64 {
        return self.vtable.tryWait(self.ctx);
    }

    pub fn terminate(self: Child) void {
        self.vtable.terminate(self.ctx);
    }

    /// Query the child's current working directory (see `VTable.queryCwd`).
    /// Returns null when the impl declines or the OS query fails.
    pub fn queryCwd(self: Child, alloc: Allocator) ?[]u8 {
        const f = self.vtable.queryCwd orelse return null;
        return f(self.ctx, alloc);
    }

    /// The pty's current foreground pid (see `VTable.queryForegroundPid`).
    /// Null when the impl declines or the query fails.
    pub fn queryForegroundPid(self: Child) ?i64 {
        const f = self.vtable.queryForegroundPid orelse return null;
        return f(self.ctx);
    }
};

/// A stateless placeholder context for `deadChild` (the vtable ignores its `ctx`).
var dead_child_ctx: u8 = 0;

/// An inert `Child` for a DEAD session materialized from disk (§5.4 reboot floor,
/// T12b) before it is relaunched: the session sits in the table so `ATTACH` replies
/// `dead` and `LIST_SESSIONS` lists it, but there is no process behind it yet. Every
/// method is a no-op / error: `terminate` does nothing (so table teardown is safe
/// even if the session is never relaunched), `tryWait` reports "still running" (it is
/// never polled — a dead session installs no output reader), `write` fails (no stdin).
/// A successful `RELAUNCH` swaps this out for a real `pty_child`. Backed by a shared
/// stateless context — no allocation, so nothing to free.
pub fn deadChild() Child {
    return .{ .ctx = &dead_child_ctx, .vtable = &dead_child_vtable };
}

const dead_child_vtable: Child.VTable = .{
    .write = deadWrite,
    .resize = deadResize,
    .signal = deadSignal,
    .tryWait = deadTryWait,
    .terminate = deadTerminate,
};
fn deadWrite(_: *anyopaque, _: []const u8) anyerror!usize {
    return error.BrokenPipe;
}
fn deadResize(_: *anyopaque, _: u16, _: u16, _: u16, _: u16) anyerror!void {}
fn deadSignal(_: *anyopaque, _: []const u8) anyerror!void {}
fn deadTryWait(_: *anyopaque) ?i64 {
    return null;
}
fn deadTerminate(_: *anyopaque) void {}

// -----------------------------------------------------------------------------
// Raw-output ring — bounded recent-scrollback buffer (§7.1 / §7.3 gap-fill)
// -----------------------------------------------------------------------------

/// A bounded byte ring holding the most recent child-output bytes. The ring tracks
/// the absolute byte offset of its oldest retained byte so a `(L, S]` gap-fill can
/// answer "do I still have the bytes the client missed?" (§7.3). When full, the
/// oldest bytes are evicted (overwritten) — the visible grid is still exact from
/// the snapshot; only deep scrollback is lost (§7.3 "v1 honesty").
pub const OutputRing = struct {
    buf: []u8,
    /// Absolute offset (in the channel's raw stream) of `buf[start]`, i.e. the
    /// oldest byte still retained. `tail_offset - base_offset == len`.
    base_offset: u64 = 0,
    /// Number of valid bytes currently retained (≤ buf.len).
    len: usize = 0,
    /// Index in `buf` of the oldest retained byte.
    start: usize = 0,
    alloc: Allocator,

    pub fn init(alloc: Allocator, capacity: usize) Allocator.Error!OutputRing {
        assert(capacity > 0);
        return .{ .buf = try alloc.alloc(u8, capacity), .alloc = alloc };
    }

    pub fn deinit(self: *OutputRing) void {
        self.alloc.free(self.buf);
        self.* = undefined;
    }

    /// Absolute offset one past the newest retained byte (== the session's
    /// outbound offset at the last append).
    pub fn tailOffset(self: OutputRing) u64 {
        return self.base_offset + self.len;
    }

    /// Append `bytes` (which start at absolute offset `at`). Evicts oldest bytes
    /// if the ring would overflow, advancing `base_offset`. `at` must equal the
    /// current tail offset (output is append-only and contiguous).
    pub fn append(self: *OutputRing, at: u64, bytes: []const u8) void {
        assert(at == self.tailOffset());
        const cap = self.buf.len;
        // If the incoming chunk alone exceeds capacity, keep only its tail.
        var src = bytes;
        var src_at = at;
        if (src.len >= cap) {
            const drop = src.len - cap;
            src = src[drop..];
            src_at += drop;
            // Ring becomes exactly the last `cap` bytes of this chunk.
            self.start = 0;
            self.len = 0;
            self.base_offset = src_at;
        }
        // Evict from the front to make room for `src.len` bytes.
        const overflow = (self.len + src.len) -| cap;
        if (overflow > 0) {
            self.start = (self.start + overflow) % cap;
            self.len -= overflow;
            self.base_offset += overflow;
        }
        // Write `src` at the write index (= start + len), wrapping.
        var widx = (self.start + self.len) % cap;
        for (src) |b| {
            self.buf[widx] = b;
            widx = (widx + 1) % cap;
        }
        self.len += src.len;
    }

    /// Copy every retained byte, oldest→newest, into `out` (which must be at least
    /// `self.len` long). Returns the number copied (== `self.len`). Used by the
    /// disk-snapshot writer (T13) to flush the ring in stream order.
    pub fn copyRetained(self: OutputRing, out: []u8) usize {
        assert(out.len >= self.len);
        const cap = self.buf.len;
        var ridx = self.start;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            out[i] = self.buf[ridx];
            ridx = (ridx + 1) % cap;
        }
        return self.len;
    }

    /// Reset the ring to hold exactly `bytes` starting at absolute offset
    /// `base_offset` (T13 reboot preload of a disk snapshot). Discards any prior
    /// contents. If `bytes` exceeds capacity only its tail is kept (the same
    /// eviction rule `append` applies), with `base_offset` advanced to match.
    pub fn preload(self: *OutputRing, base_offset: u64, bytes: []const u8) void {
        self.start = 0;
        self.len = 0;
        self.base_offset = base_offset;
        self.append(base_offset, bytes);
    }

    /// Copy the retained bytes in the half-open absolute range `(lo, hi]` (i.e.
    /// offsets `lo .. hi`) into `out` (which must be large enough). Returns null if
    /// any requested byte has been evicted (caller emits a "scrollback truncated"
    /// marker, §7.3). `hi` must not exceed the tail offset.
    pub fn slice(self: OutputRing, lo: u64, hi: u64, out: []u8) ?usize {
        assert(hi <= self.tailOffset());
        if (hi < lo) return 0;
        const n: usize = @intCast(hi - lo);
        if (n == 0) return 0;
        if (lo < self.base_offset) return null; // requested bytes evicted
        assert(out.len >= n);
        const off_in_ring: usize = @intCast(lo - self.base_offset);
        const cap = self.buf.len;
        var ridx = (self.start + off_in_ring) % cap;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.buf[ridx];
            ridx = (ridx + 1) % cap;
        }
        return n;
    }
};

// -----------------------------------------------------------------------------
// Session (§7.1)
// -----------------------------------------------------------------------------

/// One remote terminal session: a child process bound to a data channel, with its
/// dimensions, recent-output ring, outbound byte offset, metadata, and lifecycle
/// state. Owned by the `SessionTable`.
pub const Session = struct {
    /// Cryptographically-random session id (§7.1: NEVER reused). Rendered as a
    /// lowercase-hex UUID-ish string for the JSON wire (`OPENED.session_id`). We
    /// keep the raw u128 too for fast table lookup.
    id: u128,
    id_str: [32]u8, // 128 bits as hex; not NUL-terminated, use id_str[0..]

    /// The data channel this session streams on. A fresh crypto-random u128 so it
    /// can never collide with `control_channel` (0) or another session (§7.1).
    channel: u128,

    /// The (fake, this increment) child process.
    child: Child,

    /// pid reported in `OPENED` (fake child supplies a synthetic one).
    pid: i64,

    rows: u16,
    cols: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,

    /// Re-attach repaint latch (§5.4). `TIOCSWINSZ` only raises `SIGWINCH` on a
    /// dimension *change*, so a re-attach that restores the SAME geometry leaves
    /// alt-screen apps (vim, htop, Claude Code) showing a stale/blank frame until
    /// the user manually resizes. Set on ATTACH (alive re-attach) and RELAUNCH;
    /// the first authoritative RESIZE that follows (the client's threadEnter
    /// re-assert, 106dcdc9c) delivers one explicit `SIGWINCH` to the child pgid
    /// and clears this, forcing the foreground app to re-query size and repaint.
    /// The design's "post-attach RESIZE (rows±0 trick or SIGWINCH) nudges" — done
    /// as a real SIGWINCH, because a rows±0 no-op changes nothing and so signals
    /// nothing.
    winch_on_next_resize: bool = false,

    /// Capture width/height of a PRELOADED reboot-scrollback snapshot (T13, §5.4),
    /// i.e. the pty geometry the ring bytes were drawn at. 0 = unknown (no
    /// snapshot, or a legacy width-less GRS1 file). Sent to the reattaching viewer
    /// on RELAUNCH (`Relaunched.replay_cols/rows`) so it can replay the raw stream
    /// at the original width and reflow to the live pane — replayed narrower, the
    /// stream's in-place prompt redraws smear. Only meaningful until the first live
    /// resize; the fresh child then owns the geometry.
    replay_cols: u16 = 0,
    replay_rows: u16 = 0,

    /// Recent raw child output for gap-fill/scrollback (§7.1/§7.3).
    ring: OutputRing,

    /// Headless emulator mirroring this session's VISIBLE screen, fed the same
    /// bytes as `ring` (FIX 2). Lazily created on first output so idle/tombstone
    /// sessions never allocate a terminal. On ATTACH, `gridSnapshotAlloc`
    /// serializes it to a VT repaint so the re-attached pane is never blank — even
    /// when the paint predates the ring (deep scrollback evicted, or a full-screen
    /// app whose alt-screen enter scrolled out). See `grid_snapshot.zig`.
    emulator: ?*grid_snapshot.GridEmulator = null,

    /// The per-channel outbound byte offset (§4.2/§7.3). Every child→client DATA
    /// frame's `byte_offset` comes from `out_offset.advance(n)`; the SAME counter
    /// the client uses to discard already-applied DATA after a snapshot.
    out_offset: protocol.ByteOffset = .{},

    /// The outbound offset captured at the last successful ring disk snapshot
    /// (T13, §5.4). The ring is "dirty" (needs re-snapshotting) when
    /// `out_offset.value != last_snapshot_offset`. Materialize sets it equal to a
    /// preloaded ring's tail so a just-loaded dead session isn't flagged dirty.
    last_snapshot_offset: u64 = 0,

    /// Streaming gate. When false (client sent `FLOW{pause}` or `DETACH`), child
    /// output is buffered in the ring but NOT framed onto the wire until resumed
    /// (§4.3/§4.4). A `bool` gate is sufficient for v1 (§3.4).
    streaming: bool = true,

    /// Metadata surfaced via `META`/`ATTACHED` (§7.1).
    cwd: ?[]u8 = null,
    title: ?[]u8 = null,
    state: ActivityState = .idle,

    /// The command this session is running, as a human-readable label captured at
    /// OPEN time (the explicit `command`, else the resolved `shell`). Surfaced by
    /// `LIST_SESSIONS` (T10) so a session browser can show "what is this". T12 will
    /// persist the full argv to disk; this in-memory copy is the live view.
    argv: ?[]u8 = null,

    /// The child's PTY slave path (e.g. `/dev/ttys014`), captured at spawn (OPEN /
    /// RELAUNCH) and surfaced via `OPENED`/`ATTACHED`/`RELAUNCHED` so a viewer pane
    /// can answer `getProcessInfo(.tty_name)` (wp3). Null on Windows (ConPTY has no
    /// tty name) and for sessions materialized from disk that haven't relaunched
    /// (no live pty). NOT persisted — a relaunch opens a fresh pty and re-reports.
    tty: ?[]u8 = null,

    /// Lifecycle: while `alive`, `DETACH`/drop keeps the session; only `CLOSE` or
    /// child exit frees it. On exit it becomes a **tombstone** retaining
    /// `exit_code` + final state until GC (§7.1).
    alive: bool = true,
    exit_code: ?i64 = null,

    /// True while a live connection (`Server`) is bound to this session — i.e. a
    /// client is currently attached and receiving its stream. Cleared when that
    /// connection disconnects (DETACH-on-drop, §7.1 survival): the session keeps
    /// running and ringing output, but is now an ORPHAN eligible for idle-TTL
    /// reaping. Re-set when a new connection ATTACHes. The idle reaper only evicts
    /// orphans (`!bound`), so an attached session never times out.
    bound: bool = false,

    /// When true, the idle-TTL reaper NEVER evicts this session, even while
    /// orphaned (`!bound`) and idle past the TTL (§7.1, T11). Set from
    /// `OPEN.pinned` by the local-agent client for persistent local panes: the
    /// viewer's session-layout manifest references them, so they must outlive the
    /// viewer quitting until a restore re-ATTACHes — an overnight laptop-closed
    /// session would otherwise be reaped before the next launch. Cross-machine
    /// sessions leave this false and keep the plain idle-TTL. Only `CLOSE` or
    /// child exit frees a pinned session.
    pinned: bool = false,

    /// True for a DEAD session MATERIALIZED FROM DISK at agent start (§5.4 reboot
    /// floor, T12b) that has not been relaunched yet: `alive == false`, no live
    /// `child` (a `deadChild()` placeholder), but the recorded `argv`/`cwd` are
    /// present so `RELAUNCH` can respawn the process and revive it. Distinguishes a
    /// relaunchable tombstone from a child that genuinely EXITED this run
    /// (`relaunchable == false`, `exit_code` set): the former is offered a relaunch,
    /// persisted across restarts, and never dropped by `persistMeta`; the latter is
    /// a plain tombstone. Set true by `SessionTable.materialize`, cleared back to
    /// false by a successful RELAUNCH (the session is then a normal alive one).
    relaunchable: bool = false,

    /// The currently-bound connection's outbound bridge: where live child→client
    /// DATA frames are enqueued. Null while orphaned (no live connection) — output
    /// still flows into `ring` but is not framed onto any wire. (Re)pointed under
    /// the store lock on OPEN/ATTACH and cleared on disconnect. `bridge_ctx` is the
    /// bound `*Server` as an opaque pointer; `bridge_data` frames a DATA chunk on
    /// the session's channel. Kept opaque so `session.zig` needn't import
    /// `server.zig` (avoids an import cycle).
    bridge_ctx: ?*anyopaque = null,
    bridge_data: ?*const fn (ctx: *anyopaque, channel: u128, byte_offset: u64, bytes: []const u8) void = null,
    /// Frames EXIT on the session's channel (ordered after final DATA). Same
    /// lifetime/locking rules as `bridge_data`.
    bridge_exit: ?*const fn (ctx: *anyopaque, channel: u128, code: i64, runtime_ms: u64) void = null,
    /// Frames `META{foreground_pid}` on the session's channel when the pty's
    /// foreground process group changes (wp3 live-fg sampling). Same
    /// lifetime/locking rules as `bridge_data`.
    bridge_fgpid: ?*const fn (ctx: *anyopaque, channel: u128, fg_pid: i64) void = null,

    /// The last foreground pid the sampling tick observed (0 = none yet).
    /// Guarded by the store mutex; reset to 0 on (re)bind so a fresh viewer gets
    /// the current value pushed within one tick even if it hasn't changed.
    fg_pid: i64 = 0,

    /// Timestamps (ms). `last_activity_ms` drives the idle-TTL reaper (`startReaper`).
    created_ms: i64,
    last_activity_ms: i64,

    /// Most recent signal name delivered (fake-child bookkeeping / test assertion).
    last_signal: ?[]u8 = null,

    alloc: Allocator,

    /// Lowercase hex digits for id rendering.
    const hex = "0123456789abcdef";

    /// Render `id` as 32 lowercase-hex chars into `dst`.
    fn renderId(id: u128, dst: *[32]u8) void {
        var v = id;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            dst[i] = hex[@intCast(v & 0xF)];
            v >>= 4;
        }
    }

    pub fn init(
        alloc: Allocator,
        id: u128,
        channel: u128,
        child: Child,
        pid: i64,
        rows: u16,
        cols: u16,
        ring_bytes: usize,
        now_ms: i64,
    ) Allocator.Error!Session {
        var self: Session = .{
            .id = id,
            .id_str = undefined,
            .channel = channel,
            .child = child,
            .pid = pid,
            .rows = rows,
            .cols = cols,
            .ring = try OutputRing.init(alloc, ring_bytes),
            .created_ms = now_ms,
            .last_activity_ms = now_ms,
            .alloc = alloc,
        };
        renderId(id, &self.id_str);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.ring.deinit();
        if (self.emulator) |emu| emu.destroy();
        if (self.cwd) |c| self.alloc.free(c);
        if (self.title) |t| self.alloc.free(t);
        if (self.argv) |a| self.alloc.free(a);
        if (self.tty) |t| self.alloc.free(t);
        if (self.last_signal) |s| self.alloc.free(s);
        self.* = undefined;
    }

    pub fn idStr(self: *const Session) []const u8 {
        return self.id_str[0..];
    }

    /// The byte offset `S` a resync would anchor to (§7.3). For this increment
    /// that is simply the current outbound tail — a real grid snapshot captured
    /// atomically under the pty lock is `// TODO(snapshot)`.
    pub fn snapshotOffset(self: *const Session) u64 {
        return self.out_offset.value;
    }

    /// Record child output: append to the ring and return the absolute offset of
    /// its first byte (for the DATA frame). Advances `out_offset` by `bytes.len`.
    /// Caller (the Server) frames it if `streaming` is true.
    pub fn recordOutput(self: *Session, bytes: []const u8, now_ms: i64) u64 {
        const at = self.out_offset.advance(bytes.len);
        self.ring.append(at, bytes);
        self.feedEmulator(bytes);
        self.last_activity_ms = now_ms;
        return at;
    }

    /// Mirror `bytes` into the headless grid emulator (FIX 2), lazily creating it
    /// on first output and keeping it sized to the session's live geometry. All
    /// best-effort: an allocation failure just leaves the emulator absent/stale so
    /// this session falls back to ring-only replay — it never disturbs the ring or
    /// the byte stream.
    fn feedEmulator(self: *Session, bytes: []const u8) void {
        const emu = self.emulator orelse blk: {
            const created = grid_snapshot.GridEmulator.create(
                self.alloc,
                self.rows,
                self.cols,
            ) catch return;
            self.emulator = created;
            break :blk created;
        };
        emu.ensureSize(self.rows, self.cols);
        emu.feed(bytes);
    }

    /// Serialize the current visible screen as a self-contained VT repaint owned
    /// by `gpa` (caller frees), sized to the session's current geometry. Returns
    /// null when there is no emulator yet (a session that produced no output) — the
    /// caller then falls back to ring-only replay. See `grid_snapshot.zig`.
    pub fn gridSnapshotAlloc(self: *Session, gpa: Allocator) ?[]u8 {
        const emu = self.emulator orelse return null;
        emu.ensureSize(self.rows, self.cols);
        return emu.snapshotAlloc(gpa) catch null;
    }

    /// True when the emulator shows the child is on the ALTERNATE screen. False
    /// when there is no emulator. The Server uses this to skip the raw ring replay
    /// for alt-screen sessions (see `gridSnapshotAlloc`).
    pub fn gridOnAltScreen(self: *const Session) bool {
        const emu = self.emulator orelse return false;
        return emu.onAlternateScreen();
    }

    /// Mark exited (tombstone): retain `code` + final state, drop alive. The child
    /// handle is terminated by the caller. Idempotent.
    pub fn markExited(self: *Session, code: i64, now_ms: i64) void {
        if (!self.alive) return;
        self.alive = false;
        self.exit_code = code;
        self.last_activity_ms = now_ms;
    }

    pub fn setSignal(self: *Session, name: []const u8) Allocator.Error!void {
        if (self.last_signal) |s| self.alloc.free(s);
        self.last_signal = try self.alloc.dupe(u8, name);
    }

    /// Record the command label surfaced by `LIST_SESSIONS`. Owns a copy; replaces
    /// any prior value. A best-effort field — a failure to allocate simply leaves
    /// `argv` null rather than propagating.
    pub fn setArgv(self: *Session, label: []const u8) void {
        const copy = self.alloc.dupe(u8, label) catch return;
        if (self.argv) |a| self.alloc.free(a);
        self.argv = copy;
    }

    /// Record (or clear, with null) the child's PTY slave path. Owns a copy;
    /// replaces any prior value. Best-effort like `setArgv` — an allocation
    /// failure leaves the field unchanged rather than propagating.
    pub fn setTty(self: *Session, tty: ?[]const u8) void {
        const copy: ?[]u8 = if (tty) |t| (self.alloc.dupe(u8, t) catch return) else null;
        if (self.tty) |t| self.alloc.free(t);
        self.tty = copy;
    }
};

// -----------------------------------------------------------------------------
// SessionTable — the agent's session registry (§7.1)
// -----------------------------------------------------------------------------

/// The agent's session registry: `session_id (u128)` → `*Session`, plus a
/// `channel (u128)` → `*Session` index for routing inbound DATA/FLOW by channel.
/// Enforces `max_sessions`. NOT internally locked — the `Server` holds its session
/// mutex around all table access (§3.4 single-lock discipline), keeping this type
/// a plain data structure that unit-tests without threads.
pub const SessionTable = struct {
    /// Owns the `*Session` storage (heap-allocated so pointers are stable across
    /// map growth — channels/ids both index the same `*Session`).
    by_id: std.AutoHashMapUnmanaged(u128, *Session) = .empty,
    by_channel: std.AutoHashMapUnmanaged(u128, *Session) = .empty,
    alloc: Allocator,
    /// Cryptographic RNG for id/channel minting (§7.1). Seeded from the OS by
    /// default; tests may inject a deterministic one.
    rng: std.Random,

    pub const Error = error{ TooManySessions, IdCollision } || Allocator.Error;

    pub fn init(alloc: Allocator, rng: std.Random) SessionTable {
        return .{ .alloc = alloc, .rng = rng };
    }

    /// Free every session (terminating its child) and the maps. Called on shutdown.
    pub fn deinit(self: *SessionTable) void {
        var it = self.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            s.child.terminate();
            s.deinit();
            self.alloc.destroy(s);
        }
        self.by_id.deinit(self.alloc);
        self.by_channel.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn count(self: *const SessionTable) usize {
        return self.by_id.count();
    }

    /// Mint a fresh, never-before-used crypto-random non-zero u128 not already in
    /// `map`. Retries on the (astronomically unlikely) collision.
    fn mintId(self: *SessionTable, map: anytype) u128 {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const v = self.rng.int(u128);
            if (v == protocol.control_channel) continue; // never 0
            if (!map.contains(v)) return v;
        }
        // 8 collisions on a 128-bit space is effectively impossible; treat as a
        // hard error rather than spin forever.
        return protocol.control_channel; // sentinel; caller maps to IdCollision
    }

    /// Create + register a session for a freshly-spawned child. Mints a
    /// crypto-random session id and a distinct crypto-random data channel (§7.1),
    /// returns the owned `*Session` (table retains ownership). Enforces the cap.
    pub fn create(
        self: *SessionTable,
        child: Child,
        pid: i64,
        rows: u16,
        cols: u16,
        ring_bytes: usize,
        now_ms: i64,
    ) Error!*Session {
        if (self.by_id.count() >= max_sessions) return error.TooManySessions;

        const id = self.mintId(&self.by_id);
        if (id == protocol.control_channel) return error.IdCollision;
        const channel = self.mintId(&self.by_channel);
        if (channel == protocol.control_channel) return error.IdCollision;

        const s = try self.alloc.create(Session);
        errdefer self.alloc.destroy(s);
        s.* = try Session.init(self.alloc, id, channel, child, pid, rows, cols, ring_bytes, now_ms);
        errdefer s.deinit();

        try self.by_id.put(self.alloc, id, s);
        errdefer _ = self.by_id.remove(id);
        try self.by_channel.put(self.alloc, channel, s);
        return s;
    }

    /// Materialize a DEAD, RELAUNCHABLE session from persisted metadata (§5.4 reboot
    /// floor, T12b). Re-keys the session to its RECORDED id (`rec.id`, the id the
    /// viewer's layout manifest references) with a freshly-minted data channel and a
    /// no-op `deadChild()`. Sets `alive = false` + `relaunchable = true` so `ATTACH`
    /// replies `dead(relaunchable)` and `RELAUNCH` can respawn under the recorded
    /// `argv`/`cwd`. Copies `argv`/`cwd`/`title` (owned) and `pinned`; preserves the
    /// original `created_ms`, but sets `last_activity_ms = now_ms` so a just-loaded
    /// session isn't instantly idle-reaped. Allocates a full `ring_bytes` output ring
    /// (used once relaunched). Returns null (skips) on a malformed id or one already
    /// present — idempotent across a double load. Enforces `max_sessions`.
    pub fn materialize(
        self: *SessionTable,
        rec: session_meta.Record,
        ring_bytes: usize,
        now_ms: i64,
    ) Error!?*Session {
        if (self.by_id.count() >= max_sessions) return error.TooManySessions;
        const id = parseId(rec.id) orelse return null; // malformed hex → skip
        if (self.by_id.contains(id)) return null; // already present → skip

        const channel = self.mintId(&self.by_channel);
        if (channel == protocol.control_channel) return error.IdCollision;

        const s = try self.alloc.create(Session);
        errdefer self.alloc.destroy(s);
        // Dead sessions carry no dimensions until an ATTACH/RELAUNCH sets them; a
        // sane default (24×80) keeps the ring/pty math well-formed in the interim.
        s.* = try Session.init(self.alloc, id, channel, deadChild(), 0, 24, 80, ring_bytes, now_ms);
        errdefer s.deinit();

        s.alive = false;
        s.relaunchable = true;
        s.pinned = rec.pinned;
        s.created_ms = rec.created_ms; // preserve the original creation time
        if (rec.argv) |a| s.setArgv(a); // relaunch command + LIST_SESSIONS label
        if (rec.cwd) |c| s.cwd = try self.alloc.dupe(u8, c);
        errdefer if (s.cwd) |c| self.alloc.free(c);
        if (rec.title) |t| s.title = try self.alloc.dupe(u8, t);

        try self.by_id.put(self.alloc, id, s);
        errdefer _ = self.by_id.remove(id);
        try self.by_channel.put(self.alloc, channel, s);
        return s;
    }

    pub fn getById(self: *SessionTable, id: u128) ?*Session {
        return self.by_id.get(id);
    }

    pub fn getByChannel(self: *SessionTable, channel: u128) ?*Session {
        return self.by_channel.get(channel);
    }

    /// Look up by the hex string form used on the wire (`session_id`). Returns null
    /// on a malformed or unknown id (untrusted input — never crashes, §15 M3).
    pub fn getByIdStr(self: *SessionTable, id_str: []const u8) ?*Session {
        const id = parseId(id_str) orelse return null;
        return self.getById(id);
    }

    /// Remove + free a session (terminating its child). Idempotent on a stale id.
    ///
    /// DEADLOCK WARNING: `child.terminate()` joins the child's pty reader thread,
    /// and that reader's output sink (`Server.onChildOutput`) takes the session
    /// lock. So this MUST NOT be called while the session lock is held, or the
    /// reader can never make progress and the join hangs forever. Callers that
    /// hold the lock must use the two-phase `unlink` + `freeUnlinked` instead
    /// (unlink under the lock, free outside it). This convenience form is for
    /// lock-free contexts (tests, single-threaded teardown).
    pub fn remove(self: *SessionTable, id: u128) void {
        const s = self.unlink(id) orelse return;
        self.freeUnlinked(s);
    }

    /// Phase 1 of removal: detach `id` from both indexes and return the orphaned
    /// `*Session` WITHOUT terminating its child. Safe to call under the session
    /// lock (it only touches the maps). Returns null on a stale id. The caller
    /// owns the returned session and MUST eventually `freeUnlinked` it.
    pub fn unlink(self: *SessionTable, id: u128) ?*Session {
        const s = self.by_id.get(id) orelse return null;
        _ = self.by_id.remove(id);
        _ = self.by_channel.remove(s.channel);
        return s;
    }

    /// Phase 2 of removal: terminate the child (joins its reader thread) and free
    /// the session. MUST be called WITHOUT the session lock held (terminate joins
    /// the reader, which needs the lock — see `remove`'s deadlock warning).
    pub fn freeUnlinked(self: *SessionTable, s: *Session) void {
        s.child.terminate();
        s.deinit();
        self.alloc.destroy(s);
    }

    /// Parse a 32-hex-char session id; null on anything malformed.
    fn parseId(s: []const u8) ?u128 {
        if (s.len != 32) return null;
        var v: u128 = 0;
        for (s) |c| {
            const d: u128 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            v = (v << 4) | d;
        }
        return v;
    }
};

// -----------------------------------------------------------------------------
// SessionStore — DAEMON-SCOPED session registry (P1 close-laptop survival)
// -----------------------------------------------------------------------------

/// Default idle-TTL before an orphaned (no live connection bound) session is
/// reaped (§7.1 "Resource caps & TTL"). 24 hours: a closed laptop lid must
/// survive overnight — the whole point of daemon-scoped sessions is that the
/// client reconnects and catches up, and a 5-minute TTL (the original value)
/// meant any real sleep reaped the session before the GUI could re-ATTACH.
/// Still bounded so truly abandoned sessions don't leak forever; an orphan
/// costs its pty child plus a ~2MB output ring. `last_activity_ms` is bumped
/// on every output chunk and on (re)attach, so an actively-running session
/// never idles out.
pub const default_idle_ttl_ms: i64 = 24 * 60 * 60 * 1000;

/// The agent's DAEMON-scoped session store: a `SessionTable` plus the single mutex
/// that guards ALL access to it, a clock, and a background idle-TTL reaper. It
/// OUTLIVES any individual connection (`Server`) — this is what makes the
/// close-laptop / reconnect-and-catch-up scenario work: when a client disconnects,
/// its `Server` is torn down but the sessions, their pty children, and their
/// output rings remain here, still streaming into their rings, until either a new
/// connection re-`ATTACH`es them or the idle-TTL reaps them.
///
/// Locking discipline (§3.4): the `mutex` is the ONE lock guarding the table and
/// every `Session`'s mutable fields. The deadlock rule from `SessionTable.remove`
/// applies store-wide: NEVER call `child.terminate()` (which joins a reader thread
/// whose sink takes this lock) while holding `mutex`. The store's own teardown
/// paths (`closeSession`, `reapIdle`, `deinit`) all unlink under the lock and free
/// outside it.
pub const SessionStore = struct {
    mutex: std.Thread.Mutex = .{},
    table: SessionTable,
    clock_ctx: *anyopaque,
    nowFn: *const fn (ctx: *anyopaque) i64,
    idle_ttl_ms: i64,

    /// When set, `persistMeta` atomically rewrites this path with the current
    /// alive-session metadata (§5.4 reboot floor, T12). BORROWED — the caller
    /// (main.zig) owns the string and keeps it alive for the store's lifetime.
    /// Null (the default) disables persistence entirely, so tests and any
    /// non-persistent serve path are byte-for-byte unchanged.
    meta_path: ?[]const u8 = null,

    /// When set, `snapshotRings` flushes each dirty ALIVE session's output ring to
    /// `<rings_dir>/<session-id>.ring` (§5.4 reboot scrollback, T13). BORROWED —
    /// main.zig owns the string for the store's lifetime. Null (the default)
    /// disables ring snapshots entirely (tests / non-persistent paths unchanged).
    rings_dir: ?[]const u8 = null,

    /// Opaque per-window layout blobs pushed by owning viewers (§5.4 "Resume
    /// all", T18), keyed by the viewer's manifest-entry id. The agent stores +
    /// returns each blob VERBATIM (topology-agnostic); it only inspects the
    /// associated `session_ids` to reap a blob once none of its sessions exist.
    /// Guarded by the same `mutex`. Freed in `deinit`.
    layouts: std.StringHashMapUnmanaged(OwnedLayout) = .empty,

    /// When set, `persistLayouts` atomically rewrites this path with the current
    /// layout set (§5.4, T18). BORROWED — main.zig owns the string for the
    /// store's lifetime. Null (the default) disables layout persistence (tests /
    /// non-persistent paths keep no on-disk layouts, but the in-memory map still
    /// works for a same-run push→pull).
    layouts_path: ?[]const u8 = null,

    /// Background reaper: wakes periodically to evict idle orphaned sessions.
    reaper: ?std.Thread = null,
    reaper_mutex: std.Thread.Mutex = .{},
    reaper_cond: std.Thread.Condition = .{},
    reaper_stop: bool = false,

    pub fn init(
        alloc: Allocator,
        rng: std.Random,
        clock_ctx: *anyopaque,
        nowFn: *const fn (ctx: *anyopaque) i64,
        idle_ttl_ms: i64,
    ) SessionStore {
        return .{
            .table = SessionTable.init(alloc, rng),
            .clock_ctx = clock_ctx,
            .nowFn = nowFn,
            .idle_ttl_ms = idle_ttl_ms,
        };
    }

    fn now(self: *SessionStore) i64 {
        return self.nowFn(self.clock_ctx);
    }

    /// The child output sink, bound to a session's channel via `child.attach`. This
    /// is store-scoped (NOT per-connection) so it stays valid across reconnects:
    /// the pty reader thread routes output here for the life of the child. It:
    ///   1. records `bytes` into the session ring (always — survives disconnect),
    ///   2. if a connection is bound + streaming, frames it as DATA via the bridge,
    ///   3. reap-checks the child; on exit, frames EXIT (after the final DATA) and
    ///      tombstones the session.
    /// Takes the store lock. Unknown channel ⇒ ignored. A zero-length call is a
    /// reap nudge (the pty reader sends one on EOF).
    pub fn onChildOutput(self: *SessionStore, channel: u128, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.table.getByChannel(channel) orelse return;
        if (!s.alive) return;
        const now_ms = self.now();
        if (bytes.len > 0) {
            const at = s.recordOutput(bytes, now_ms);
            if (s.streaming and s.bound) {
                if (s.bridge_data) |f| f(s.bridge_ctx.?, s.channel, at, bytes);
            }
        }
        // Reap-check: emit EXIT (after the final DATA already bridged) on exit.
        const code = s.child.tryWait() orelse return;
        s.markExited(code, now_ms);
        const runtime: u64 = @intCast(@max(0, now_ms - s.created_ms));
        if (s.bound) {
            if (s.bridge_exit) |f| f(s.bridge_ctx.?, s.channel, code, runtime);
        }
    }

    /// Trampoline matching `session.Child` sink signature; bound via `child.attach`.
    pub fn onChildOutputTrampoline(ctx: *anyopaque, channel: u128, bytes: []const u8) void {
        const self: *SessionStore = @ptrCast(@alignCast(ctx));
        self.onChildOutput(channel, bytes);
    }

    /// Start the background idle-TTL reaper thread. Optional — when not started
    /// (tests), idle reaping happens only via explicit `reapIdle` calls.
    pub fn startReaper(self: *SessionStore) !void {
        if (self.reaper != null) return;
        self.reaper = try std.Thread.spawn(.{}, reaperLoop, .{self});
    }

    /// Ring-snapshot cadence: flush dirty rings to disk every this-many reaper
    /// ticks (§5.4 "every 30 s"). The reaper wakes once a second, so 30 ticks.
    const snapshot_every_ticks: u32 = 30;

    fn reaperLoop(self: *SessionStore) void {
        // Wake at most once a second (or on stop) to check for idle orphans.
        const tick_ns: u64 = 1 * std.time.ns_per_s;
        var ticks: u32 = 0;
        while (true) {
            self.reaper_mutex.lock();
            if (!self.reaper_stop) self.reaper_cond.timedWait(&self.reaper_mutex, tick_ns) catch {};
            const stop = self.reaper_stop;
            self.reaper_mutex.unlock();
            if (stop) break;
            self.reapIdle();
            // Live foreground-pid sampling (wp3): push `META{foreground_pid}`
            // for any bound session whose pty foreground group changed since
            // the last tick, so viewer-side `getProcessInfo(.foreground_pid)`
            // tracks the running program (Exec `tcgetpgrp` parity) instead of
            // reporting the shell forever.
            self.sampleForegroundPids();
            // Periodic ring disk snapshot (T13): catch dirty rings whose viewer is
            // still attached / recently detached (the connection-drop trigger only
            // fires on disconnect). No-op when ring snapshots are disabled or
            // nothing is dirty.
            ticks +%= 1;
            if (ticks >= snapshot_every_ticks) {
                ticks = 0;
                self.snapshotRings();
            }
        }
    }

    /// Sample every bound+alive session's pty foreground pid and push
    /// `META{foreground_pid}` (via `bridge_fgpid`) for the ones that changed
    /// since the previous tick (wp3). The vtable query runs UNDER the store
    /// mutex — it is contractually a single non-blocking syscall
    /// (`tcgetpgrp`) — so a concurrent CLOSE/reap can never free the child
    /// mid-query. The bridge calls fire OUTSIDE the lock (they take the
    /// connection's writer lock; same collect-then-act shape as `reapIdle`).
    /// A child that answers null (Windows ConPTY, transient failure, fake
    /// children without the hook) is skipped — its viewer keeps the child-pid
    /// fallback.
    pub fn sampleForegroundPids(self: *SessionStore) void {
        const Push = struct {
            f: *const fn (ctx: *anyopaque, channel: u128, fg_pid: i64) void,
            ctx: *anyopaque,
            channel: u128,
            fg: i64,
        };
        var pushes: std.ArrayList(Push) = .empty;
        defer pushes.deinit(self.table.alloc);

        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (!s.alive or !s.bound) continue;
            const fg = s.child.queryForegroundPid() orelse continue;
            if (fg <= 0 or fg == s.fg_pid) continue;
            s.fg_pid = fg;
            const f = s.bridge_fgpid orelse continue;
            const ctx = s.bridge_ctx orelse continue;
            pushes.append(self.table.alloc, .{
                .f = f,
                .ctx = ctx,
                .channel = s.channel,
                .fg = fg,
            }) catch break; // OOM: drop this tick's remaining pushes, retry next tick
        }
        self.mutex.unlock();

        for (pushes.items) |p| p.f(p.ctx, p.channel, p.fg);
    }

    /// Evict any session whose `bound` connection is gone (orphaned) AND whose
    /// `last_activity_ms` is older than the idle-TTL. Tombstones (exited children)
    /// are also reaped once idle. Unlinks under the lock, frees outside it.
    pub fn reapIdle(self: *SessionStore) void {
        const cutoff = self.now() - self.idle_ttl_ms;
        // Phase 1: collect victims' ids under the lock.
        var victims: std.ArrayList(u128) = .empty;
        defer victims.deinit(self.table.alloc);
        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.bound) continue; // a live connection owns it; never reap
            // `pinned` shields only LIVE sessions from the idle-TTL reaper (a
            // persistent local pane the viewer will re-ATTACH to). A pinned DEAD
            // tombstone is NOT immortal: its child is gone, so nothing can
            // re-attach to a running process — leaving it pinned made dead rows
            // pile up in the chooser forever. Once dead, a pinned session falls
            // back to the normal orphan-reap rules below (and the unbind path
            // reaps a dead+unbound non-relaunchable tombstone immediately). A
            // relaunchable reboot-floor tombstone stays (it is resumable).
            if (s.pinned and s.alive) continue;
            if (s.last_activity_ms <= cutoff) {
                victims.append(self.table.alloc, s.id) catch {};
            }
        }
        // Phase 2: unlink each victim under the lock, free outside.
        var unlinked: std.ArrayList(*Session) = .empty;
        defer unlinked.deinit(self.table.alloc);
        for (victims.items) |id| {
            if (self.table.unlink(id)) |s| unlinked.append(self.table.alloc, s) catch {};
        }
        self.mutex.unlock();
        for (unlinked.items) |s| {
            // Delete the reaped session's ring snapshot BEFORE freeing it (id_str
            // is on the session). Best-effort; a stale file is harmless anyway.
            self.deleteRingSnapshot(s.idStr());
            self.table.freeUnlinked(s);
        }
        // Refresh the on-disk metadata if the alive set actually shrank (§5.4,
        // T12). No-op when persistence is disabled or nothing was reaped.
        if (unlinked.items.len > 0) self.persistMeta();
    }

    /// Reap a DEAD, UNBOUND, non-relaunchable tombstone IMMEDIATELY (not on the
    /// idle-TTL clock). The moment a viewer detaches from a session whose child
    /// already exited — window closed, app quit, `/wt-delete`, shell exit — the
    /// record is pure garbage: nothing can re-attach to a gone process, and it is
    /// not a pending reboot-floor relaunch. Left in the table it would show in the
    /// chooser as a dead-end `exited` row and (if pinned) be written to
    /// `sessions.json` and re-materialized after an agent restart. So we drop it
    /// here the way `handleClose` does a clean teardown: two-phase (unlink under
    /// the lock, free + delete the ring snapshot OUTSIDE it), then refresh the
    /// reboot-floor metadata (so it can't be re-materialized) and reap any orphaned
    /// layout blob it was the last referent of.
    ///
    /// Guarded + idempotent: re-checks `!alive and !bound and !relaunchable` under
    /// the lock, so a race that re-ATTACHed or RELAUNCHed the session between the
    /// caller unbinding it and this call leaves it untouched. Callers MUST NOT hold
    /// `self.mutex` (this takes it and then frees a child outside it, following the
    /// same discipline as `handleClose`/`reapIdle`).
    pub fn reapUnboundTombstone(self: *SessionStore, id: u128) void {
        self.mutex.lock();
        const s = self.table.getById(id) orelse {
            self.mutex.unlock();
            return;
        };
        // Only a dead, orphaned, non-relaunchable session is garbage. A still-bound
        // tombstone keeps its `[process exited]` pane; a relaunchable reboot-floor
        // tombstone is the legitimate Resume case; an alive session obviously stays.
        if (s.alive or s.bound or s.relaunchable) {
            self.mutex.unlock();
            return;
        }
        const unlinked = self.table.unlink(id);
        self.mutex.unlock();
        if (unlinked) |u| {
            self.deleteRingSnapshot(u.idStr()); // discard any persisted scrollback
            self.table.freeUnlinked(u);
            // The alive set shrank — rewrite reboot-floor metadata so the tombstone
            // is gone from `sessions.json` and can't be re-materialized on restart.
            self.persistMeta();
            // It may have been the last session a stored layout blob referenced —
            // reap orphaned blobs so dead topology doesn't accumulate.
            if (self.reapLayouts() > 0) self.persistLayouts();
        }
    }

    /// Explicit CLOSE: unlink the session on `channel` under the lock and free it
    /// outside (terminating its child). Idempotent on a stale channel.
    pub fn closeByChannel(self: *SessionStore, channel: u128) void {
        self.mutex.lock();
        const s = self.table.getByChannel(channel) orelse {
            self.mutex.unlock();
            return;
        };
        const unlinked = self.table.unlink(s.id);
        self.mutex.unlock();
        if (unlinked) |u| {
            self.deleteRingSnapshot(u.idStr()); // CLOSE discards persisted scrollback
            self.table.freeUnlinked(u);
        }
    }

    /// Best-effort delete of a session's ring disk snapshot (T13). No-op when ring
    /// snapshots are disabled. Called when a session is CLOSEd or reaped so its
    /// stale scrollback file doesn't linger.
    fn deleteRingSnapshot(self: *SessionStore, id_str: []const u8) void {
        const dir = self.rings_dir orelse return;
        ring_snapshot.delete(self.table.alloc, dir, id_str);
    }

    /// Load persisted session metadata (T12) and MATERIALIZE each record as a DEAD,
    /// relaunchable tombstone (§5.4 reboot floor, T12b). Call ONCE at agent start,
    /// BEFORE accepting connections (so a viewer's `ATTACH` to a persisted id finds a
    /// `dead(relaunchable)` session it can `RELAUNCH`) and before the reaper starts.
    /// `ring_bytes` sizes each materialized session's output ring (used once
    /// relaunched). No-op (and no error) when `meta_path` is null or the file is
    /// absent (a first start / clean box). Best-effort per record: a malformed / dup /
    /// oversized entry is skipped and logged; a whole-file read/parse failure is
    /// logged and swallowed (a corrupt file must not stop the agent from starting).
    /// Returns the number of sessions materialized.
    pub fn loadPersisted(self: *SessionStore, ring_bytes: usize) usize {
        const path = self.meta_path orelse return 0;
        const alloc = self.table.alloc;

        var parsed = (session_meta.load(alloc, path) catch |err| {
            std.log.warn("session_meta: load from {s} failed: {s}", .{ path, @errorName(err) });
            return 0;
        }) orelse return 0; // absent → nothing to restore
        defer parsed.deinit();

        var n: usize = 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (parsed.value.sessions) |rec| {
            const s = self.table.materialize(rec, ring_bytes, self.now()) catch |err| {
                std.log.warn("session_meta: materialize {s} failed: {s}", .{ rec.id, @errorName(err) });
                continue;
            };
            if (s) |sess| {
                n += 1;
                // Reboot scrollback (T13): if this session has a ring disk snapshot,
                // preload it into the fresh ring + bake the restart divider so the
                // eventual RELAUNCH replays pre-restart scrollback + divider + live
                // output. Best-effort; a missing/corrupt snapshot just leaves the
                // ring empty (the pane comes back without pre-restart scrollback).
                self.preloadRingSnapshot(sess);
            }
        }
        return n;
    }

    /// Load `sess`'s ring disk snapshot (if any) into its output ring, then append
    /// the reboot divider, and anchor `out_offset` at the ring tail so a later
    /// RELAUNCH's fresh child output continues after it (T13, §5.4). The ring is
    /// renumbered to base offset 0 (a freshly-restored viewer applies DATA from 0
    /// with no resync watermark — a non-zero base would manufacture a phantom gap).
    /// No-op when ring snapshots are disabled or none exists. Called under the store
    /// lock from `loadPersisted`, before any connection or the reaper runs.
    fn preloadRingSnapshot(self: *SessionStore, sess: *Session) void {
        const dir = self.rings_dir orelse return;
        const alloc = self.table.alloc;
        const path = ring_snapshot.pathFor(alloc, dir, sess.idStr()) catch return;
        defer alloc.free(path);
        var loaded = (ring_snapshot.load(alloc, path) catch |err| {
            std.log.warn("ring_snapshot: load {s} failed: {s}", .{ path, @errorName(err) });
            return;
        }) orelse return;
        defer loaded.free(alloc);
        if (loaded.bytes.len == 0) return; // nothing to replay

        // Remember the width these bytes were drawn at (0 for a legacy GRS1
        // snapshot) so RELAUNCH can tell the viewer to replay at that width.
        sess.replay_cols = loaded.cols;
        sess.replay_rows = loaded.rows;

        // Renumber to base 0: [snapshot bytes][divider]. out_offset := tail so the
        // relaunched child's first output lands immediately after the divider.
        sess.ring.preload(0, loaded.bytes);
        sess.out_offset.value = sess.ring.tailOffset();
        sess.ring.append(sess.out_offset.value, reboot_divider);
        sess.out_offset.value +%= reboot_divider.len;
        // Not dirty: this is loaded-from-disk content, not new child output.
        sess.last_snapshot_offset = sess.out_offset.value;
    }

    /// Flush every dirty ALIVE session's output ring to `<rings_dir>/<id>.ring`
    /// (§5.4 reboot scrollback, T13). No-op when `rings_dir` is null (disabled).
    /// Triggered periodically by the reaper and on a viewer disconnect (server
    /// `shutdown`). Best-effort: any per-session failure is logged and skipped.
    ///
    /// Bounded memory (mirrors `persistMeta`'s snapshot-then-IO discipline but one
    /// session at a time): collect the dirty ids under the lock, then for each id
    /// re-lock, copy just THAT ring into a single reused buffer, release the lock,
    /// and write the file outside it — so at most one ring (not all 256) is copied
    /// at once and no OS I/O ever runs under the lock (which serializes child output).
    pub fn snapshotRings(self: *SessionStore) void {
        const dir = self.rings_dir orelse return;
        const alloc = self.table.alloc;

        // Phase 1: collect dirty alive session ids under the lock.
        var ids: std.ArrayList(u128) = .empty;
        defer ids.deinit(alloc);
        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (!s.alive) continue; // dead/relaunchable: nothing new to persist
            if (s.out_offset.value == s.last_snapshot_offset) continue; // clean
            ids.append(alloc, s.id) catch {};
        }
        self.mutex.unlock();
        if (ids.items.len == 0) return;

        // A single reused copy buffer, grown to the largest ring encountered.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        for (ids.items) |id| {
            // Re-lock and copy just this ring (it may have been closed/reaped in
            // the meantime — skip if gone or now dead).
            self.mutex.lock();
            const s = self.table.getById(id) orelse {
                self.mutex.unlock();
                continue;
            };
            if (!s.alive) {
                self.mutex.unlock();
                continue;
            }
            const need = s.ring.len;
            buf.ensureTotalCapacity(alloc, need) catch {
                self.mutex.unlock();
                continue;
            };
            buf.items.len = need;
            const n = s.ring.copyRetained(buf.items);
            const base = s.ring.base_offset;
            const at = s.out_offset.value;
            // Capture the width these bytes were drawn at so replay can render at
            // it and then reflow to the live pane width (§5.4 smear fix).
            const cap_cols = s.cols;
            const cap_rows = s.rows;
            var id_str_buf: [32]u8 = s.id_str;
            self.mutex.unlock();

            // Write OUTSIDE the lock.
            const path = ring_snapshot.pathFor(alloc, dir, id_str_buf[0..]) catch continue;
            defer alloc.free(path);
            ring_snapshot.writeAtomic(alloc, path, base, cap_cols, cap_rows, buf.items[0..n]) catch |err| {
                std.log.warn("ring_snapshot: write {s} failed: {s}", .{ path, @errorName(err) });
                continue;
            };
            // Mark clean only after a successful write, and only if no newer output
            // arrived in the meantime (else leave it dirty so the next pass retries).
            self.mutex.lock();
            if (self.table.getById(id)) |s2| {
                if (s2.last_snapshot_offset < at) s2.last_snapshot_offset = at;
            }
            self.mutex.unlock();
        }
    }

    /// Persist the current ALIVE + RELAUNCHABLE session set to `meta_path` (§5.4
    /// reboot floor, T12/T12b). No-op when `meta_path` is null (disabled — default).
    /// Best-effort: any failure is logged and swallowed, never propagated — a
    /// failed metadata write must never take down a live session.
    ///
    /// Snapshot-then-IO discipline (mirrors the server's `handleGetCwd`): the
    /// alive set is copied into OWNED `session_meta.Record`s UNDER the store
    /// mutex, the mutex is released, and only THEN is the file serialized +
    /// atomically written — no OS I/O ever runs under the lock (which serializes
    /// every child output chunk). The owned dupes mean a session freed between
    /// the snapshot and the write cannot dangle. Callers invoke this AFTER their
    /// own unlocks (never while holding `mutex`); it takes the lock itself.
    ///
    /// ALIVE sessions and RELAUNCHABLE tombstones (T12b materialized-from-disk) are
    /// recorded; a genuinely EXITED child has nothing to relaunch and is excluded (the
    /// file self-heals on the next open/close trigger, so child-exit does not call this).
    pub fn persistMeta(self: *SessionStore) void {
        const path = self.meta_path orelse return;
        const alloc = self.table.alloc;

        // Phase 1: snapshot the persistable set into owned records under the lock.
        var recs: std.ArrayList(session_meta.Record) = .empty;
        defer {
            for (recs.items) |r| freeMetaRecord(alloc, r);
            recs.deinit(alloc);
        }
        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            // Persist ALIVE sessions and RELAUNCHABLE tombstones (§5.4 reboot floor,
            // T12b: a session loaded from disk but not yet relaunched must survive a
            // second restart — dropping it here would lose the intent). A genuinely
            // EXITED child (`!alive and !relaunchable`) has nothing to relaunch and
            // is excluded; the file self-heals on the next open/close.
            if (!s.alive and !s.relaunchable) continue;
            const rec = dupMetaRecord(alloc, s) catch continue; // best-effort per session
            recs.append(alloc, rec) catch {
                freeMetaRecord(alloc, rec); // not in the list → free here
                continue;
            };
        }
        self.mutex.unlock();

        // Phase 2: serialize + atomic write OUTSIDE the lock.
        const body = session_meta.serialize(alloc, recs.items) catch |err| {
            std.log.warn("session_meta: serialize failed: {s}", .{@errorName(err)});
            return;
        };
        defer alloc.free(body);
        session_meta.writeAtomic(alloc, path, body) catch |err| {
            std.log.warn("session_meta: write to {s} failed: {s}", .{ path, @errorName(err) });
        };
    }

    // --- Layout blobs (§5.4 cross-machine "Resume all", T18) ------------------

    /// One stored layout: the opaque `blob` (never parsed by the agent) and the
    /// `session_ids` it references (used only to reap the blob once its sessions
    /// are gone). All slices are owned by the store allocator; the map KEY (the
    /// viewer's manifest-entry id) is owned separately.
    pub const OwnedLayout = struct {
        blob: []u8,
        session_ids: [][]u8,
    };

    /// Upsert a layout blob under `key`. Replaces an existing blob in place
    /// (keeping its owned key). Best-effort — an allocation failure leaves the
    /// prior entry (if any) untouched and returns the error. Takes the lock.
    /// Does NOT persist — the caller pairs this with `persistLayouts`.
    pub fn setLayout(
        self: *SessionStore,
        key: []const u8,
        blob: []const u8,
        session_ids: []const []const u8,
    ) !void {
        const alloc = self.table.alloc;
        const val = try dupOwnedLayout(alloc, blob, session_ids);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.putLayoutLocked(key, val) catch |err| {
            freeOwnedLayoutValue(alloc, val);
            return err;
        };
    }

    /// Insert/replace `val` under `key` with the lock held. Consumes `val` on
    /// success; on failure `val` is left for the caller to free and the map is
    /// unchanged.
    fn putLayoutLocked(self: *SessionStore, key: []const u8, val: OwnedLayout) !void {
        const alloc = self.table.alloc;
        const gop = try self.layouts.getOrPut(alloc, key);
        if (gop.found_existing) {
            freeOwnedLayoutValue(alloc, gop.value_ptr.*);
            gop.value_ptr.* = val;
        } else {
            // getOrPut stored the BORROWED `key`; give the map an owned copy.
            const key_copy = alloc.dupe(u8, key) catch |err| {
                _ = self.layouts.remove(key);
                return err;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = val;
        }
    }

    /// Remove the layout stored under `key` (a clean window close). Takes the
    /// lock. Does NOT persist — the caller pairs this with `persistLayouts`.
    pub fn removeLayout(self: *SessionStore, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.removeLayoutLocked(key);
    }

    fn removeLayoutLocked(self: *SessionStore, key: []const u8) void {
        const alloc = self.table.alloc;
        if (self.layouts.fetchRemove(key)) |kv| {
            alloc.free(kv.key);
            freeOwnedLayoutValue(alloc, kv.value);
        }
    }

    /// Drop every stored layout whose referenced sessions are ALL gone from the
    /// table (reaped/closed) — a blob nobody can attach to any more. A layout
    /// with no recorded session ids references nothing attachable and is reaped
    /// too. Takes the lock; caller pairs it with `persistLayouts`. Returns the
    /// number reaped.
    pub fn reapLayouts(self: *SessionStore) usize {
        const alloc = self.table.alloc;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Collect dead keys first — can't remove while iterating.
        var dead: std.ArrayListUnmanaged([]const u8) = .empty;
        defer dead.deinit(alloc);
        var it = self.layouts.iterator();
        while (it.next()) |e| {
            var any_alive = false;
            for (e.value_ptr.session_ids) |sid| {
                if (self.table.getByIdStr(sid) != null) {
                    any_alive = true;
                    break;
                }
            }
            if (!any_alive) dead.append(alloc, e.key_ptr.*) catch {};
        }
        for (dead.items) |k| self.removeLayoutLocked(k);
        return dead.items.len;
    }

    /// Snapshot every stored layout into caller-owned `layout_meta.Record`s (key
    /// + blob duped) for a GET_LAYOUTS reply. Caller frees each via
    /// `freeLayoutMetaRecord` and the slice. `session_ids` are NOT included (the
    /// resumer reads leaf ids from the blob). Takes the lock briefly.
    pub fn snapshotLayouts(self: *SessionStore, alloc: Allocator) ![]layout_meta.Record {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged(layout_meta.Record) = .empty;
        errdefer {
            for (out.items) |r| freeLayoutMetaRecord(alloc, r);
            out.deinit(alloc);
        }
        var it = self.layouts.iterator();
        while (it.next()) |e| {
            const key = try alloc.dupe(u8, e.key_ptr.*);
            errdefer alloc.free(key);
            const blob = try alloc.dupe(u8, e.value_ptr.blob);
            try out.append(alloc, .{ .key = key, .blob = blob });
        }
        return out.toOwnedSlice(alloc);
    }

    /// Atomically rewrite `layouts_path` with the current layout set (mirrors
    /// `persistMeta`: snapshot owned records under the lock, serialize + write
    /// OUTSIDE it). No-op when layout persistence is disabled. Best-effort.
    pub fn persistLayouts(self: *SessionStore) void {
        const path = self.layouts_path orelse return;
        const alloc = self.table.alloc;

        var recs: std.ArrayList(layout_meta.Record) = .empty;
        defer {
            for (recs.items) |r| freeLayoutMetaRecord(alloc, r);
            recs.deinit(alloc);
        }
        self.mutex.lock();
        var it = self.layouts.iterator();
        while (it.next()) |e| {
            const rec = dupLayoutMetaRecord(alloc, e.key_ptr.*, e.value_ptr.*) catch continue;
            recs.append(alloc, rec) catch {
                freeLayoutMetaRecord(alloc, rec);
                continue;
            };
        }
        self.mutex.unlock();

        const body = layout_meta.serialize(alloc, recs.items) catch |err| {
            std.log.warn("layout_meta: serialize failed: {s}", .{@errorName(err)});
            return;
        };
        defer alloc.free(body);
        layout_meta.writeAtomic(alloc, path, body) catch |err| {
            std.log.warn("layout_meta: write to {s} failed: {s}", .{ path, @errorName(err) });
        };
    }

    /// Load persisted layout blobs from `layouts_path` into the in-memory map at
    /// agent start (mirrors `loadPersisted`). No-op when disabled or the file is
    /// absent. Best-effort per record.
    pub fn loadLayouts(self: *SessionStore) void {
        const path = self.layouts_path orelse return;
        const alloc = self.table.alloc;
        var parsed = (layout_meta.load(alloc, path) catch |err| {
            std.log.warn("layout_meta: load from {s} failed: {s}", .{ path, @errorName(err) });
            return;
        }) orelse return;
        defer parsed.deinit();

        self.mutex.lock();
        defer self.mutex.unlock();
        for (parsed.value.layouts) |rec| {
            const val = dupOwnedLayout(alloc, rec.blob, rec.session_ids) catch continue;
            self.putLayoutLocked(rec.key, val) catch {
                freeOwnedLayoutValue(alloc, val);
                continue;
            };
        }
    }

    /// Free the whole store: stop the reaper, then tear down every session. Unlinks
    /// all sessions under the lock, then terminates+frees them OUTSIDE the lock so a
    /// child reader thread mid-delivery (blocked on the lock) can drain and let its
    /// `terminate` join complete (the deadlock fix, applied store-wide).
    pub fn deinit(self: *SessionStore) void {
        if (self.reaper) |t| {
            self.reaper_mutex.lock();
            self.reaper_stop = true;
            self.reaper_cond.signal();
            self.reaper_mutex.unlock();
            t.join();
            self.reaper = null;
        }
        const alloc = self.table.alloc; // capture before `self.table` is invalidated
        // Free the layout-blob map (keys + values). Independent of sessions; no
        // child threads to join, so no two-phase dance is needed.
        var lit = self.layouts.iterator();
        while (lit.next()) |e| {
            alloc.free(e.key_ptr.*);
            freeOwnedLayoutValue(alloc, e.value_ptr.*);
        }
        self.layouts.deinit(alloc);
        // Phase 1: unlink everything under the lock.
        var unlinked: std.ArrayList(*Session) = .empty;
        defer unlinked.deinit(alloc);
        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| unlinked.append(alloc, sp.*) catch {};
        self.table.by_id.clearRetainingCapacity();
        self.table.by_channel.clearRetainingCapacity();
        self.mutex.unlock();
        // Phase 2: terminate + free OUTSIDE the lock.
        for (unlinked.items) |s| self.table.freeUnlinked(s);
        // The maps are now empty; deinit them (no children left to terminate).
        self.table.by_id.deinit(alloc);
        self.table.by_channel.deinit(alloc);
        self.table = undefined;
    }
};

/// Copy a live session's relaunch metadata into an OWNED `session_meta.Record`
/// (every string duped). Used by `persistMeta` under the store lock so the
/// snapshot survives the unlock + file write. On any allocation failure the
/// partial dupes are freed (errdefer) and the error propagates to the caller,
/// which skips that one session (best-effort).
fn dupMetaRecord(alloc: Allocator, s: *const Session) Allocator.Error!session_meta.Record {
    const id = try alloc.dupe(u8, s.idStr());
    errdefer alloc.free(id);
    const argv: ?[]u8 = if (s.argv) |a| try alloc.dupe(u8, a) else null;
    errdefer if (argv) |a| alloc.free(a);
    const cwd: ?[]u8 = if (s.cwd) |c| try alloc.dupe(u8, c) else null;
    errdefer if (cwd) |c| alloc.free(c);
    const title: ?[]u8 = if (s.title) |t| try alloc.dupe(u8, t) else null;
    return .{
        .id = id,
        .argv = argv,
        .cwd = cwd,
        .title = title,
        .pinned = s.pinned,
        .created_ms = s.created_ms,
    };
}

/// Free every string in an owned metadata record (the inverse of `dupMetaRecord`).
fn freeMetaRecord(alloc: Allocator, r: session_meta.Record) void {
    alloc.free(r.id);
    if (r.argv) |a| alloc.free(a);
    if (r.cwd) |c| alloc.free(c);
    if (r.title) |t| alloc.free(t);
}

/// Build a fully-owned `OwnedLayout` (blob + each session id duped). On any
/// allocation failure the partial dupes are freed (errdefer) and the error
/// propagates.
fn dupOwnedLayout(
    alloc: Allocator,
    blob: []const u8,
    session_ids: []const []const u8,
) Allocator.Error!SessionStore.OwnedLayout {
    const blob_copy = try alloc.dupe(u8, blob);
    errdefer alloc.free(blob_copy);
    const ids = try alloc.alloc([]u8, session_ids.len);
    var filled: usize = 0;
    errdefer {
        for (ids[0..filled]) |s| alloc.free(s);
        alloc.free(ids);
    }
    for (session_ids, 0..) |sid, i| {
        ids[i] = try alloc.dupe(u8, sid);
        filled = i + 1;
    }
    return .{ .blob = blob_copy, .session_ids = ids };
}

/// Free an `OwnedLayout`'s value strings (NOT its map key — the caller owns that).
fn freeOwnedLayoutValue(alloc: Allocator, val: SessionStore.OwnedLayout) void {
    alloc.free(val.blob);
    for (val.session_ids) |s| alloc.free(s);
    alloc.free(val.session_ids);
}

/// Copy a stored layout into an OWNED `layout_meta.Record` (key + blob duped;
/// `session_ids` intentionally omitted from the persisted-reply snapshot path
/// but duped for the persist path). Used under the store lock so the snapshot
/// survives the unlock + file write.
fn dupLayoutMetaRecord(
    alloc: Allocator,
    key: []const u8,
    val: SessionStore.OwnedLayout,
) Allocator.Error!layout_meta.Record {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const blob_copy = try alloc.dupe(u8, val.blob);
    errdefer alloc.free(blob_copy);
    const ids = try alloc.alloc([]const u8, val.session_ids.len);
    var filled: usize = 0;
    errdefer {
        for (ids[0..filled]) |s| alloc.free(@constCast(s));
        alloc.free(ids);
    }
    for (val.session_ids, 0..) |sid, i| {
        ids[i] = try alloc.dupe(u8, sid);
        filled = i + 1;
    }
    return .{ .key = key_copy, .blob = blob_copy, .session_ids = ids };
}

/// Free an owned `layout_meta.Record` (the inverse of `dupLayoutMetaRecord`, and
/// what `snapshotLayouts`/`persistLayouts` use to free their snapshots).
fn freeLayoutMetaRecord(alloc: Allocator, r: layout_meta.Record) void {
    alloc.free(@constCast(r.key));
    alloc.free(@constCast(r.blob));
    for (r.session_ids) |s| alloc.free(@constCast(s));
    alloc.free(@constCast(r.session_ids));
}

/// Free a slice of owned layout records returned by `SessionStore.snapshotLayouts`
/// (each record + the slice). Public so `server.zig` can free a GET_LAYOUTS
/// snapshot without importing `layout_meta`.
pub fn freeLayoutRecords(alloc: Allocator, recs: []layout_meta.Record) void {
    for (recs) |r| freeLayoutMetaRecord(alloc, r);
    alloc.free(recs);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A buffer-backed fake child: `write` sinks keystrokes into `input`, output is
/// pushed by the test via `feed` (the Server reads it via a pull each tick in the
/// real wiring; here the table test pokes `recordOutput` directly). `signal`/
/// `resize`/exit are recorded for assertions.
const FakeChild = struct {
    input: std.ArrayList(u8) = .empty,
    last_resize: ?[4]u16 = null,
    last_signal: ?[]const u8 = null,
    exit_code: ?i64 = null,
    terminated: bool = false,
    alloc: Allocator,

    fn child(self: *FakeChild) Child {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable: Child.VTable = .{
        .write = wr,
        .resize = rz,
        .signal = sg,
        .tryWait = tw,
        .terminate = tm,
    };
    fn wr(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        try self.input.appendSlice(self.alloc, bytes);
        return bytes.len;
    }
    fn rz(ctx: *anyopaque, rows: u16, cols: u16, px_w: u16, px_h: u16) anyerror!void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.last_resize = .{ rows, cols, px_w, px_h };
    }
    fn sg(ctx: *anyopaque, name: []const u8) anyerror!void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.last_signal = name;
    }
    fn tw(ctx: *anyopaque) ?i64 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        return self.exit_code;
    }
    fn tm(ctx: *anyopaque) void {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.terminated = true;
    }
    fn deinit(self: *FakeChild) void {
        self.input.deinit(self.alloc);
    }
};

test "OutputRing: append + slice within capacity" {
    const alloc = testing.allocator;
    var ring = try OutputRing.init(alloc, 64);
    defer ring.deinit();

    ring.append(0, "hello ");
    ring.append(6, "world");
    try testing.expectEqual(@as(u64, 11), ring.tailOffset());

    var out: [64]u8 = undefined;
    const n = ring.slice(0, 11, &out).?;
    try testing.expectEqualSlices(u8, "hello world", out[0..n]);
    // Sub-range (3, 8] = "lo wo".
    const m = ring.slice(3, 8, &out).?;
    try testing.expectEqualSlices(u8, "lo wo", out[0..m]);
}

test "OutputRing: eviction advances base_offset and reports truncation" {
    const alloc = testing.allocator;
    var ring = try OutputRing.init(alloc, 8);
    defer ring.deinit();

    ring.append(0, "abcdefgh"); // fills exactly
    ring.append(8, "ij"); // evicts "ab"
    try testing.expectEqual(@as(u64, 2), ring.base_offset);
    try testing.expectEqual(@as(u64, 10), ring.tailOffset());

    var out: [16]u8 = undefined;
    // Retained tail (2,10] = "cdefghij".
    const n = ring.slice(2, 10, &out).?;
    try testing.expectEqualSlices(u8, "cdefghij", out[0..n]);
    // Asking for evicted bytes → null (truncated).
    try testing.expect(ring.slice(0, 10, &out) == null);
}

test "OutputRing: oversized single append keeps only the tail" {
    const alloc = testing.allocator;
    var ring = try OutputRing.init(alloc, 4);
    defer ring.deinit();
    ring.append(0, "abcdefgh"); // 8 bytes into a 4-byte ring
    try testing.expectEqual(@as(u64, 4), ring.base_offset);
    try testing.expectEqual(@as(u64, 8), ring.tailOffset());
    var out: [8]u8 = undefined;
    const n = ring.slice(4, 8, &out).?;
    try testing.expectEqualSlices(u8, "efgh", out[0..n]);
}

test "OutputRing: copyRetained returns bytes oldest→newest, incl. after wrap" {
    const alloc = testing.allocator;
    var ring = try OutputRing.init(alloc, 4);
    defer ring.deinit();
    ring.append(0, "ab");
    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), ring.copyRetained(&out));
    try testing.expectEqualSlices(u8, "ab", out[0..2]);
    // Force a wrap (start advances), then copy in stream order.
    ring.append(2, "cdef"); // ring now holds "cdef" (base 2)
    try testing.expectEqual(@as(u64, 2), ring.base_offset);
    const n = ring.copyRetained(&out);
    try testing.expectEqualSlices(u8, "cdef", out[0..n]);
}

test "OutputRing: preload resets to bytes at a base offset (tail kept if oversized)" {
    const alloc = testing.allocator;
    var ring = try OutputRing.init(alloc, 8);
    defer ring.deinit();
    ring.append(0, "junk");
    ring.preload(1000, "hello");
    try testing.expectEqual(@as(u64, 1000), ring.base_offset);
    try testing.expectEqual(@as(u64, 1005), ring.tailOffset());
    var out: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, "hello", out[0..ring.copyRetained(&out)]);
    // Oversized preload keeps only the tail (base advances to match).
    ring.preload(0, "0123456789"); // 10 bytes into an 8-byte ring
    try testing.expectEqual(@as(u64, 2), ring.base_offset);
    try testing.expectEqualSlices(u8, "23456789", out[0..ring.copyRetained(&out)]);
}

test "SessionTable: create mints unique ids/channels, enforces cap, frees cleanly" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    var fakes: [3]FakeChild = .{
        .{ .alloc = alloc }, .{ .alloc = alloc }, .{ .alloc = alloc },
    };
    defer for (&fakes) |*f| f.deinit();

    var table = SessionTable.init(alloc, prng.random());
    defer table.deinit();

    const s0 = try table.create(fakes[0].child(), 100, 24, 80, 1024, 0);
    const s1 = try table.create(fakes[1].child(), 101, 24, 80, 1024, 0);
    try testing.expect(s0.id != s1.id);
    try testing.expect(s0.channel != s1.channel);
    try testing.expectEqual(@as(usize, 2), table.count());

    // id string round-trips through the wire parser.
    const looked = table.getByIdStr(s0.idStr()).?;
    try testing.expectEqual(s0.id, looked.id);
    // Channel routing.
    try testing.expectEqual(s1.id, table.getByChannel(s1.channel).?.id);
    // Malformed wire id → null, never crash.
    try testing.expect(table.getByIdStr("not-a-valid-id") == null);
    try testing.expect(table.getByIdStr("zzzz") == null);

    // Remove frees + terminates the child.
    table.remove(s0.id);
    try testing.expect(fakes[0].terminated);
    try testing.expectEqual(@as(usize, 1), table.count());
}

test "Session: recordOutput advances offset and feeds ring; tombstone retains exit" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(99);
    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();
    var table = SessionTable.init(alloc, prng.random());
    defer table.deinit();

    const s = try table.create(fake.child(), 7, 24, 80, 1024, 0);

    try testing.expectEqual(@as(u64, 0), s.recordOutput("abc", 1));
    try testing.expectEqual(@as(u64, 3), s.recordOutput("de", 2));
    try testing.expectEqual(@as(u64, 5), s.snapshotOffset());

    // Keystrokes reach the child.
    try s.child.writeAll("xy");
    try testing.expectEqualSlices(u8, "xy", fake.input.items);

    // Tombstone.
    s.markExited(42, 3);
    try testing.expect(!s.alive);
    try testing.expectEqual(@as(i64, 42), s.exit_code.?);
    s.markExited(99, 4); // idempotent: code unchanged
    try testing.expectEqual(@as(i64, 42), s.exit_code.?);
}

/// A mutable millisecond clock for reaper tests: `reapIdle` reads `now` through
/// `nowFn`, and the test fast-forwards it past the idle-TTL.
const MutClock = struct {
    ms: i64 = 0,
    fn nowFn(ctx: *anyopaque) i64 {
        const self: *MutClock = @ptrCast(@alignCast(ctx));
        return self.ms;
    }
};

test "SessionStore.reapIdle: pinned+ALIVE survives fast-forward, unpinned reaped, pinned+DEAD reaped" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xABCD);
    var fakes: [3]FakeChild = .{ .{ .alloc = alloc }, .{ .alloc = alloc }, .{ .alloc = alloc } };
    defer for (&fakes) |*f| f.deinit();

    var clock: MutClock = .{ .ms = 0 };
    const ttl_ms: i64 = 1000;
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, ttl_ms);
    defer store.deinit();

    // Three orphaned (bound=false, the create default) sessions born at t=0:
    //   pinned_alive — pinned + still alive → the persistent-pane case; immune.
    //   plain        — unpinned, alive → reaped once idle past the TTL.
    //   pinned_dead  — pinned but its child EXITED → a tombstone; `pinned` must NOT
    //                  shield it any more (the leak this change fixes).
    const pinned_alive = try store.table.create(fakes[0].child(), 200, 24, 80, 1024, 0);
    const plain = try store.table.create(fakes[1].child(), 201, 24, 80, 1024, 0);
    const pinned_dead = try store.table.create(fakes[2].child(), 202, 24, 80, 1024, 0);
    pinned_alive.pinned = true;
    pinned_dead.pinned = true;
    pinned_dead.markExited(0, 0); // pinned but dead tombstone
    const pinned_alive_id = pinned_alive.id;
    try testing.expectEqual(@as(usize, 3), store.table.count());

    // Not yet idle: nothing reaped (cutoff = now - ttl = -1 < last_activity 0).
    clock.ms = ttl_ms - 1;
    store.reapIdle();
    try testing.expectEqual(@as(usize, 3), store.table.count());

    // Fast-forward well past the TTL: the unpinned orphan AND the pinned-but-dead
    // tombstone are reaped; only the pinned+ALIVE session survives.
    clock.ms = ttl_ms * 100;
    store.reapIdle();
    try testing.expectEqual(@as(usize, 1), store.table.count());
    try testing.expect(store.table.getById(pinned_alive_id) != null);
    try testing.expect(fakes[1].terminated); // plain child terminated on reap
    try testing.expect(fakes[2].terminated); // pinned-but-dead tombstone reaped too
    try testing.expect(!fakes[0].terminated); // pinned+alive child untouched
    _ = plain;
}

test "SessionStore.reapUnboundTombstone: dead+unbound+non-relaunchable is reaped; live/bound/relaunchable survive" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7EAD);
    var fakes: [4]FakeChild = .{
        .{ .alloc = alloc }, .{ .alloc = alloc }, .{ .alloc = alloc }, .{ .alloc = alloc },
    };
    defer for (&fakes) |*f| f.deinit();

    var clock: MutClock = .{ .ms = 0 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    // garbage      — dead, unbound, non-relaunchable → the exact leak: reaped NOW.
    // alive        — still alive → not garbage, survives.
    // bound        — dead but a viewer is still attached (`[process exited]`) → survives.
    // relaunchable — dead reboot-floor tombstone (Resume case) → survives.
    const garbage = try store.table.create(fakes[0].child(), 300, 24, 80, 1024, 0);
    const alive = try store.table.create(fakes[1].child(), 301, 24, 80, 1024, 0);
    const bound = try store.table.create(fakes[2].child(), 302, 24, 80, 1024, 0);
    const relaunchable = try store.table.create(fakes[3].child(), 303, 24, 80, 1024, 0);
    garbage.markExited(1, 0); // pinned OR not — irrelevant to the unbind reap
    garbage.pinned = true;
    bound.markExited(0, 0);
    bound.bound = true;
    relaunchable.markExited(0, 0);
    relaunchable.relaunchable = true;
    const garbage_id = garbage.id;
    const alive_id = alive.id;
    const bound_id = bound.id;
    const relaunchable_id = relaunchable.id;
    try testing.expectEqual(@as(usize, 4), store.table.count());

    // Reaping the garbage id drops exactly that one, immediately (no TTL wait).
    store.reapUnboundTombstone(garbage_id);
    try testing.expectEqual(@as(usize, 3), store.table.count());
    try testing.expect(store.table.getById(garbage_id) == null);
    try testing.expect(fakes[0].terminated);

    // The other three are NOT garbage — reaping their ids is a guarded no-op.
    store.reapUnboundTombstone(alive_id);
    store.reapUnboundTombstone(bound_id);
    store.reapUnboundTombstone(relaunchable_id);
    try testing.expectEqual(@as(usize, 3), store.table.count());
    try testing.expect(store.table.getById(alive_id) != null);
    try testing.expect(store.table.getById(bound_id) != null);
    try testing.expect(store.table.getById(relaunchable_id) != null);

    // Idempotent: reaping an already-gone id is a safe no-op.
    store.reapUnboundTombstone(garbage_id);
    try testing.expectEqual(@as(usize, 3), store.table.count());
}

test "SessionStore.setLayout/reapLayouts: stores blobs, reaps when sessions vanish (T18)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x18);
    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();
    var clock: MutClock = .{ .ms = 0 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    const s = try store.table.create(fake.child(), 300, 24, 80, 1024, 0);
    // Copy the borrowed session-id string (it dangles once the session is freed).
    var buf: [64]u8 = undefined;
    const sid = s.idStr();
    @memcpy(buf[0..sid.len], sid);
    const sid_copy = buf[0..sid.len];

    // One layout references the LIVE session; one references a bogus id.
    const live_ids = [_][]const u8{sid_copy};
    try store.setLayout("live-win", "{\"a\":1}", &live_ids);
    const dead_ids = [_][]const u8{"ffffffffffffffffffffffffffffffff"};
    try store.setLayout("dead-win", "{\"b\":2}", &dead_ids);
    try testing.expectEqual(@as(usize, 2), store.layouts.count());

    // Reap drops the blob whose only session id is unknown to the table; the one
    // referencing a live session survives.
    try testing.expectEqual(@as(usize, 1), store.reapLayouts());
    try testing.expectEqual(@as(usize, 1), store.layouts.count());
    try testing.expect(store.layouts.get("live-win") != null);
    try testing.expect(store.layouts.get("dead-win") == null);

    // Upsert replaces the blob in place (same key), keeping the count at 1.
    try store.setLayout("live-win", "{\"a\":2}", &live_ids);
    try testing.expectEqual(@as(usize, 1), store.layouts.count());
    try testing.expectEqualStrings("{\"a\":2}", store.layouts.get("live-win").?.blob);

    // removeLayout drops it explicitly.
    store.removeLayout("live-win");
    try testing.expectEqual(@as(usize, 0), store.layouts.count());

    // Re-add, then remove the SESSION and reap: the last-referencing blob is gone.
    try store.setLayout("live-win", "{\"a\":3}", &live_ids);
    store.table.remove(s.id);
    try testing.expectEqual(@as(usize, 1), store.reapLayouts());
    try testing.expectEqual(@as(usize, 0), store.layouts.count());
}

test "SessionStore.persistMeta: writes alive set, excludes tombstones, refreshes on removal" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7E57);
    var fakes: [3]FakeChild = .{ .{ .alloc = alloc }, .{ .alloc = alloc }, .{ .alloc = alloc } };
    defer for (&fakes) |*f| f.deinit();

    var clock: MutClock = .{ .ms = 100 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    // A private temp file for the metadata store.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(path);
    store.meta_path = path;

    // No-op sanity: persisting an empty store writes an empty roster.
    store.persistMeta();
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.sessions.len);
    }

    // Two sessions: one pinned + a command label, one plain.
    const s0 = try store.table.create(fakes[0].child(), 500, 24, 80, 1024, 100);
    s0.pinned = true;
    s0.setArgv("sleep 600");
    const s1 = try store.table.create(fakes[1].child(), 501, 24, 80, 1024, 100);
    const s1_channel = s1.channel;

    store.persistMeta();
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 2), p.value.sessions.len);
        // Find s0's record by id and assert its captured fields survived the trip.
        var saw_pinned_argv = false;
        for (p.value.sessions) |r| {
            if (std.mem.eql(u8, r.id, s0.idStr())) {
                saw_pinned_argv = true;
                try testing.expect(r.pinned);
                try testing.expectEqualStrings("sleep 600", r.argv.?);
                try testing.expectEqual(@as(i64, 100), r.created_ms);
            }
        }
        try testing.expect(saw_pinned_argv);
    }

    // A tombstone (exited child) is excluded — nothing to relaunch.
    s1.markExited(0, 200);
    store.persistMeta();
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.sessions.len);
        try testing.expectEqualStrings(s0.idStr(), p.value.sessions[0].id);
    }

    // Closing the tombstoned session refreshes to the same single record.
    store.closeByChannel(s1_channel);
    store.persistMeta();
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.sessions.len);
    }

    // A null meta_path disables persistence: no crash, file untouched.
    store.meta_path = null;
    store.persistMeta();
}

test "SessionStore.reapIdle: a bound session is never reaped regardless of pin" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x55AA);
    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();

    var clock: MutClock = .{ .ms = 0 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    const s = try store.table.create(fake.child(), 300, 24, 80, 1024, 0);
    s.bound = true; // a live connection owns it
    clock.ms = 1_000_000;
    store.reapIdle();
    try testing.expectEqual(@as(usize, 1), store.table.count());
}

test "SessionTable.materialize: re-keys a dead relaunchable session from a record" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234);
    var table = SessionTable.init(alloc, prng.random());
    defer table.deinit();

    const rec: session_meta.Record = .{
        .id = "0123456789abcdef0123456789abcdef",
        .argv = "sleep 600",
        .cwd = "/Users/x/work",
        .title = "work",
        .pinned = true,
        .created_ms = 4242,
    };
    const s = (try table.materialize(rec, 1024, 9000)).?;

    // Re-keyed to the RECORDED id (viewer manifest reference stays valid).
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", s.idStr());
    try testing.expect(table.getByIdStr("0123456789abcdef0123456789abcdef") != null);
    // Dead + relaunchable, no exit code, metadata copied, times set correctly.
    try testing.expect(!s.alive);
    try testing.expect(s.relaunchable);
    try testing.expect(s.exit_code == null);
    try testing.expect(s.pinned);
    try testing.expectEqualStrings("sleep 600", s.argv.?);
    try testing.expectEqualStrings("/Users/x/work", s.cwd.?);
    try testing.expectEqualStrings("work", s.title.?);
    try testing.expectEqual(@as(i64, 4242), s.created_ms); // preserved
    try testing.expectEqual(@as(i64, 9000), s.last_activity_ms); // now, not idle
    // A distinct data channel was minted and indexed.
    try testing.expect(s.channel != protocol.control_channel);
    try testing.expectEqual(s.id, table.getByChannel(s.channel).?.id);

    // A malformed id is skipped (null), not a crash; a duplicate id is skipped too.
    try testing.expect((try table.materialize(.{ .id = "nope" }, 1024, 9000)) == null);
    try testing.expect((try table.materialize(rec, 1024, 9000)) == null);
    try testing.expectEqual(@as(usize, 1), table.count());
}

test "SessionStore.loadPersisted materializes + persistMeta keeps relaunchable tombstones" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x99);
    var clock: MutClock = .{ .ms = 500 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(path);
    store.meta_path = path;

    // Seed a sessions.json with one pinned command session.
    const recs = [_]session_meta.Record{.{
        .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .argv = "sleep 600",
        .pinned = true,
        .created_ms = 100,
    }};
    const body = try session_meta.serialize(alloc, &recs);
    defer alloc.free(body);
    try session_meta.writeAtomic(alloc, path, body);

    // Load → one dead, relaunchable tombstone in the table.
    try testing.expectEqual(@as(usize, 1), store.loadPersisted(1024));
    const s = store.table.getByIdStr("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").?;
    try testing.expect(!s.alive and s.relaunchable);

    // persistMeta must NOT drop the not-yet-relaunched tombstone (a second restart
    // would otherwise lose it). The file still lists it.
    store.persistMeta();
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.sessions.len);
        try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", p.value.sessions[0].id);
        try testing.expect(p.value.sessions[0].pinned);
    }

    // But a genuinely-exited tombstone (not relaunchable) IS excluded.
    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();
    const dead = try store.table.create(fake.child(), 7, 24, 80, 1024, 100);
    dead.markExited(0, 200); // alive=false, relaunchable=false
    store.persistMeta();
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.sessions.len); // only the relaunchable one
    }
}

test "SessionStore ring snapshot: dirty alive ring persists; reload preloads scrollback + divider" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const meta = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(meta);
    const rings = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    defer alloc.free(rings);

    const payload = "PANE=3 PID=4242\r\ntick-3-0\r\ntick-3-1\r\n";
    var id_buf: [32]u8 = undefined;

    // --- Agent run #1: an alive session produces output, then a viewer-disconnect
    //     (snapshotRings) flushes the ring and persistMeta records the roster.
    {
        var prng = std.Random.DefaultPrng.init(0x5151);
        var clock: MutClock = .{ .ms = 500 };
        var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 100000);
        store.meta_path = meta;
        store.rings_dir = rings;
        defer store.deinit();

        var fake: FakeChild = .{ .alloc = alloc };
        defer fake.deinit();
        const s = try store.table.create(fake.child(), 4242, 24, 80, 1 << 16, 500);
        s.pinned = true; // a persistent local pane
        s.setArgv("sleep 600");
        _ = s.recordOutput(payload, 600); // ring is now dirty
        @memcpy(&id_buf, s.id_str[0..]);

        // Clean → nothing written; then dirty → a file appears.
        store.snapshotRings();
        store.persistMeta();

        const rp = try ring_snapshot.pathFor(alloc, rings, id_buf[0..]);
        defer alloc.free(rp);
        var loaded = (try ring_snapshot.load(alloc, rp)).?;
        defer loaded.free(alloc);
        try testing.expectEqualStrings(payload, loaded.bytes);

        // A second snapshot with no new output must be a no-op (session now clean):
        // corrupt sentinel? Simpler: assert the dirty watermark advanced.
        try testing.expectEqual(s.out_offset.value, s.last_snapshot_offset);
    }

    // --- Agent run #2 (fresh store): loadPersisted materializes the tombstone AND
    //     preloads the ring snapshot + the restart divider, anchoring out_offset.
    {
        var prng = std.Random.DefaultPrng.init(0x6262);
        var clock: MutClock = .{ .ms = 9000 };
        var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 100000);
        store.meta_path = meta;
        store.rings_dir = rings;
        defer store.deinit();

        try testing.expectEqual(@as(usize, 1), store.loadPersisted(1 << 16));
        const s = store.table.getByIdStr(id_buf[0..]).?;
        try testing.expect(!s.alive and s.relaunchable);

        // The ring holds [payload][divider]; out_offset is anchored at the tail so a
        // RELAUNCH's fresh child output continues after the divider.
        const want_len = payload.len + reboot_divider.len;
        try testing.expectEqual(@as(u64, want_len), s.out_offset.value);
        try testing.expectEqual(@as(u64, want_len), s.ring.tailOffset());
        try testing.expectEqual(@as(u64, 0), s.ring.base_offset);
        const buf = try alloc.alloc(u8, want_len);
        defer alloc.free(buf);
        const n = s.ring.copyRetained(buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..n], payload));
        try testing.expect(std.mem.endsWith(u8, buf[0..n], reboot_divider));
    }
}
