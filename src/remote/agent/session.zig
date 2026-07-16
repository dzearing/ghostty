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

// -----------------------------------------------------------------------------
// Caps (§7.1 "Resource caps & TTL")
// -----------------------------------------------------------------------------

/// Maximum concurrent sessions per agent (§7.1: ≤ 64 sessions/daemon). An `OPEN`
/// past this is refused. Kept small/const for this increment; a configurable
/// limit is a later concern.
pub const max_sessions: usize = 64;

/// Default per-session raw-output ring size (§7.1: default 2 MB scrollback). Holds
/// the most recent child-output bytes so `(last_byte_offset, S]` gap-fill is
/// possible on reattach (§7.3). Lowered freely in tests.
pub const default_ring_bytes: usize = 2 * 1024 * 1024;

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
};

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

    /// Recent raw child output for gap-fill/scrollback (§7.1/§7.3).
    ring: OutputRing,

    /// The per-channel outbound byte offset (§4.2/§7.3). Every child→client DATA
    /// frame's `byte_offset` comes from `out_offset.advance(n)`; the SAME counter
    /// the client uses to discard already-applied DATA after a snapshot.
    out_offset: protocol.ByteOffset = .{},

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
        if (self.cwd) |c| self.alloc.free(c);
        if (self.title) |t| self.alloc.free(t);
        if (self.argv) |a| self.alloc.free(a);
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
        self.last_activity_ms = now_ms;
        return at;
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

    fn reaperLoop(self: *SessionStore) void {
        // Wake at most once a second (or on stop) to check for idle orphans.
        const tick_ns: u64 = 1 * std.time.ns_per_s;
        while (true) {
            self.reaper_mutex.lock();
            if (!self.reaper_stop) self.reaper_cond.timedWait(&self.reaper_mutex, tick_ns) catch {};
            const stop = self.reaper_stop;
            self.reaper_mutex.unlock();
            if (stop) break;
            self.reapIdle();
        }
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
        for (unlinked.items) |s| self.table.freeUnlinked(s);
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
        if (unlinked) |u| self.table.freeUnlinked(u);
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
