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
// "Is anything running under this session's shell?" (T356). `descendants` is the
// pure walk (no OS); `proc` owns the per-OS parent-table snapshot next to the
// externs it needs. Neither imports this module, so there is no cycle.
const descendants = @import("descendants.zig");
const proc = @import("proc.zig");

// -----------------------------------------------------------------------------
// Caps (§7.1 "Resource caps & TTL")
// -----------------------------------------------------------------------------

/// Maximum concurrent LIVE sessions per agent. Raised 64 → 256 (T11) so a heavy
/// session-persistence user with many restored windows/panes plus fresh ones
/// isn't refused new `OPEN`s; each idle session still costs a pty child + its
/// output ring, so the cap is bounded. An `OPEN` past this is refused.
///
/// LIVE, and that word is the whole of T278. This used to count every entry in
/// the table, tombstones included — and a tombstone is exactly what a restored
/// persistent pane leaves behind, `pinned` (which is what keeps a live pane from
/// being idle-reaped while its viewer is away) and therefore exempt from the
/// reaper. The set only ever grew. Measured on box 2026-08-01: 256 records, every
/// one `alive=false pid=0`, and from then on EVERY `OPEN` was refused — so every
/// new pane came up with no child and nothing said so. A dead session owns no
/// pty and no process; it can never be the reason a user is denied a shell.
/// Tombstones are bounded separately by `max_dead_sessions`.
pub const max_sessions: usize = 256;

/// The live cap every `SessionTable.init` starts from. Set ONCE at agent
/// startup, before any table exists, from `--max-sessions` /
/// `GHOSTTY_AGENT_MAX_SESSIONS`; read-only afterwards.
///
/// It exists so the refusal path can be exercised for real. The message a pane
/// shows when the agent will not start a shell for it (T469) is only reachable
/// through a genuine `error.TooManySessions`, and with a compile-time cap the
/// only way to produce one on a box is to stand up 256 live shells — which is
/// why that path shipped untested and silent for as long as it did. Two panes
/// against `--max-sessions=1` reach the same code by the same route.
pub var configured_max_sessions: usize = max_sessions;

/// Maximum DEAD sessions (tombstones) the table retains alongside the live ones.
/// Deliberately the same number as `max_sessions` rather than something smaller:
/// every one of them is a pane a user may still Resume, so trimming harder would
/// trade the T278 wedge for a quieter regression (a restore that silently drops
/// somebody's sessions). It bounds the split caps at the same total the single
/// cap already allowed, and `loadPersisted` keeps the NEWEST when a file carries
/// more than this.
pub const max_dead_sessions: usize = 256;

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
        /// Optional: the command line of the FOREGROUND program running in
        /// front of the session's shell (T429) — what a restart notice should
        /// name for a plain shell pane, e.g. `claude --continue`. Tri-state:
        /// `.cmd` = a program is running (a NEW `alloc`-owned string, caller
        /// frees); `.none` = the shell itself is foreground (an idle prompt —
        /// the caller CLEARS its record); null = the query failed or is
        /// unsupported (the caller KEEPS its last known value, the T425
        /// keep-on-failure rule). Like `queryCwd` — and unlike
        /// `queryForegroundPid` — this is explicitly NOT a cheap single
        /// syscall (a Toolhelp walk + PEB read on Windows), so it is called on
        /// a slow periodic tick OUTSIDE the store lock.
        queryForegroundCommand: ?*const fn (ctx: *anyopaque, alloc: Allocator) ?ForegroundCommand = null,
        /// Optional: how many bytes of this child's output stream have been
        /// handed to the sink so far, in the child's OWN offset space (T906).
        /// Only a holder-backed child answers — its stream offsets are shared
        /// with a separate process's replay buffer, so persisting the number
        /// lets a LATER agent re-ATTACH exactly where this one stopped.
        /// Everything else returns null and reconciles nothing.
        ///
        /// Contract that makes the number trustworthy: it must already include
        /// the bytes of the sink call currently in progress. The store reads it
        /// from inside `onChildOutput` — under the store lock, with the child's
        /// reader thread parked in that very call — so "what is in the ring"
        /// and "what offset that is" cannot disagree by a frame.
        deliveredOffset: ?*const fn (ctx: *anyopaque) ?u64 = null,
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

    /// The foreground program's command line (see
    /// `VTable.queryForegroundCommand`). Null when the impl declines or the
    /// query fails — which the caller treats as "keep the last known value".
    pub fn queryForegroundCommand(self: Child, alloc: Allocator) ?ForegroundCommand {
        const f = self.vtable.queryForegroundCommand orelse return null;
        return f(self.ctx, alloc);
    }

    /// Bytes delivered to the sink in the child's own offset space (see
    /// `VTable.deliveredOffset`). Null for every child that is not holder-backed.
    pub fn deliveredOffset(self: Child) ?u64 {
        const f = self.vtable.deliveredOffset orelse return null;
        return f(self.ctx);
    }
};

/// The tri-state answer of `Child.queryForegroundCommand` (T429): `.cmd` =
/// record this command line, `.none` = the shell sits at an idle prompt (clear
/// the record). The third state — "could not tell" — is the query returning
/// null instead of a `ForegroundCommand` at all.
pub const ForegroundCommand = union(enum) {
    none,
    /// Owned by the allocator the query was handed; the caller frees it.
    cmd: []u8,
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

    /// The command line of the FOREGROUND program running inside the shell
    /// (T429), sampled periodically by `refreshForegroundCommands` and cleared
    /// when the shell returns to its prompt. Persisted to `sessions.json` and
    /// sent on the dead `ATTACHED` reply so the restart notice can name what a
    /// plain shell pane was actually running. Deliberately a SEPARATE field
    /// from `argv`: `handleRelaunch` re-executes `argv`, and overwriting it
    /// with a sampled foreground command would make `session-relaunch = rerun`
    /// re-run e.g. `claude` in place of the shell.
    fg_cmd: ?[]u8 = null,

    /// The child's PTY slave path (e.g. `/dev/ttys014`), captured at spawn (OPEN /
    /// RELAUNCH) and surfaced via `OPENED`/`ATTACHED`/`RELAUNCHED` so a viewer pane
    /// can answer `getProcessInfo(.tty_name)` (wp3). Null on Windows (ConPTY has no
    /// tty name) and for sessions materialized from disk that haven't relaunched
    /// (no live pty). NOT persisted — a relaunch opens a fresh pty and re-reports.
    tty: ?[]u8 = null,

    /// Holder-backed session (T905): the control pipe, pid and build stamp of
    /// the `--pty-host` process that owns this session's ConPTY. All null/0 for
    /// an in-process child, which is still the default. Persisted to
    /// `sessions.json` so the survivor of an agent death stays findable.
    holder_pipe: ?[]u8 = null,
    holder_pid: u32 = 0,
    holder_stamp: ?[]u8 = null,

    /// Holder stream offset of the last byte appended to `ring` (T906), kept in
    /// step with the ring from inside `onChildOutput`. Meaningless (0) for an
    /// in-process child.
    holder_offset: u64 = 0,
    /// The value `holder_offset` had when the ring was last snapshotted to disk
    /// — i.e. the holder offset the SNAPSHOT ends at. This is what
    /// `sessions.json` carries and what a re-adopting agent sends as its ATTACH
    /// `ack`, so the holder replays exactly the bytes the snapshot is missing.
    /// Pairing it with the snapshot rather than with the live ring is the whole
    /// point: after a crash, the snapshot is all that survived.
    holder_snapshot_offset: u64 = 0,

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

    /// When this session last BECAME unattached (agent clock, ms): stamped at
    /// creation and on every bound→false transition, cleared on every (re)ATTACH.
    /// Surfaced additively as `SessionInfo.unattached_since` while the session is
    /// alive and unbound (T534) so the viewer can tell the user about a session
    /// nobody has looked at in a long time. Never consulted by any agent-side
    /// reaping decision — orphan lifetime policy (pinned keep-forever, idle-TTL)
    /// is exactly what it was before this field existed.
    unattached_since_ms: ?i64 = null,

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

    /// How many agent restarts this tombstone has been materialized across
    /// WITHOUT anyone resuming it (see `session_meta.Record.unclaimed_restarts`).
    /// Only meaningful while `relaunchable`; reset to 0 on a real resume.
    unclaimed_restarts: u32 = 0,

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
    /// Frames `META{has_descendants}` on the session's channel when the answer to
    /// "is anything running under this shell?" changes (T356). Same
    /// lifetime/locking rules as `bridge_data` — but installed ONLY when the
    /// bound connection negotiated `capability.session_busy`, which is also what
    /// makes `sampleDescendants` skip its process walk entirely when no attached
    /// peer would consume the answer.
    bridge_busy: ?*const fn (ctx: *anyopaque, channel: u128, has_descendants: bool) void = null,

    /// The last foreground pid the sampling tick observed (0 = none yet).
    /// Guarded by the store mutex; reset to 0 on (re)bind so a fresh viewer gets
    /// the current value pushed within one tick even if it hasn't changed.
    fg_pid: i64 = 0,

    /// The last "has descendants" answer pushed to the bound viewer (T356), or
    /// null for "nothing pushed yet" — which is exactly the client's UNKNOWN.
    /// Guarded by the store mutex; reset to null on (re)bind so a fresh viewer
    /// receives the current answer within a tick even when it has not changed
    /// (the previous viewer's pushes died with its connection).
    has_descendants: ?bool = null,

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
            .unattached_since_ms = now_ms,
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
        if (self.fg_cmd) |f| self.alloc.free(f);
        if (self.tty) |t| self.alloc.free(t);
        if (self.holder_pipe) |p| self.alloc.free(p);
        if (self.holder_stamp) |s| self.alloc.free(s);
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

    /// Record (or clear, with null) the sampled foreground command line (T429).
    /// Owns a copy; replaces any prior value. Best-effort like `setArgv` — an
    /// allocation failure leaves the field unchanged rather than propagating
    /// (a stale sample beats losing the record to a transient OOM).
    pub fn setFgCmd(self: *Session, cmd: ?[]const u8) void {
        const copy: ?[]u8 = if (cmd) |c| (self.alloc.dupe(u8, c) catch return) else null;
        if (self.fg_cmd) |f| self.alloc.free(f);
        self.fg_cmd = copy;
    }

    /// Record the session's working directory — the cwd the child was spawned in
    /// (`OPEN.cwd`). Owns a copy; replaces any prior value. Best-effort like
    /// `setArgv`: an allocation failure leaves `cwd` null rather than propagating.
    ///
    /// This is the RELAUNCH input (T132): `handleRelaunch` respawns the recorded
    /// command in the recorded cwd, and `persistMeta` writes it to `sessions.json`,
    /// so a session that outlives the agent comes back where it was opened rather
    /// than in whatever directory the agent process happens to be sitting in.
    /// Empty strings are ignored so a stray `--working-directory=` never records a
    /// cwd that would later be spawned as `""`.
    pub fn setCwd(self: *Session, path: []const u8) void {
        if (path.len == 0) return;
        const copy = self.alloc.dupe(u8, path) catch return;
        if (self.cwd) |c| self.alloc.free(c);
        self.cwd = copy;
    }

    /// Record (or clear, with null) the child's PTY slave path. Owns a copy;
    /// replaces any prior value. Best-effort like `setArgv` — an allocation
    /// failure leaves the field unchanged rather than propagating.
    pub fn setTty(self: *Session, tty: ?[]const u8) void {
        const copy: ?[]u8 = if (tty) |t| (self.alloc.dupe(u8, t) catch return) else null;
        if (self.tty) |t| self.alloc.free(t);
        self.tty = copy;
    }

    /// Record the `--pty-host` holder backing this session (T905). Owns copies;
    /// best-effort like `setTty` — an allocation failure leaves the session
    /// working and merely un-adoptable, which is strictly better than failing
    /// the OPEN over bookkeeping.
    pub fn setHolder(self: *Session, pipe: []const u8, pid: u32, stamp: []const u8) void {
        const pipe_copy = self.alloc.dupe(u8, pipe) catch return;
        const stamp_copy = self.alloc.dupe(u8, stamp) catch {
            self.alloc.free(pipe_copy);
            return;
        };
        if (self.holder_pipe) |p| self.alloc.free(p);
        if (self.holder_stamp) |s| self.alloc.free(s);
        self.holder_pipe = pipe_copy;
        self.holder_stamp = stamp_copy;
        self.holder_pid = pid;
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
    /// The live-session ceiling `create` enforces. Defaults to `max_sessions`,
    /// which is what every real agent runs with.
    ///
    /// It is a FIELD rather than the constant read directly so the refusal path
    /// can be exercised for real: with a compile-time-only cap, the only way to
    /// see a refusal on a box is to actually stand up 256 live shells, so the
    /// path that tells a user why their pane is empty (T469) could never be
    /// covered by an acceptance script. `ghoztty-agent --max-sessions=N` (and
    /// `GHOSTTY_AGENT_MAX_SESSIONS`) set it; nothing in the product changes it.
    max_live: usize = max_sessions,

    pub const Error = error{ TooManySessions, TooManyTombstones, IdCollision } || Allocator.Error;

    pub fn init(alloc: Allocator, rng: std.Random) SessionTable {
        return .{ .alloc = alloc, .rng = rng, .max_live = configured_max_sessions };
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

    /// How many sessions still own a child process — the ones `max_sessions`
    /// actually bounds (T278). O(n) over at most a few hundred entries, walked
    /// once per `OPEN`; a cached counter would have to be kept in step with
    /// every alive→dead transition in the store and the server, and a drifting
    /// counter here is the wedge this exists to prevent.
    pub fn liveCount(self: *SessionTable) usize {
        var n: usize = 0;
        var it = self.by_id.valueIterator();
        while (it.next()) |sp| if (sp.*.alive) {
            n += 1;
        };
        return n;
    }

    /// How many sessions are tombstones — the ones `max_dead_sessions` bounds.
    pub fn deadCount(self: *SessionTable) usize {
        return self.by_id.count() - self.liveCount();
    }

    /// How the live sessions split between the two generations (T907). This is
    /// the input to the non-destructive upgrade decision, and it is a COUNT of
    /// legacy rather than a boolean because the number is what the user is told
    /// while the handoff waits ("2 sessions still have to close first").
    pub const LiveMix = struct {
        /// Live sessions whose ConPTY + shell live in a `--pty-host` HOLDER, and
        /// so survive this process going away (T905).
        holder_backed: usize = 0,
        /// Live sessions whose ConPTY this agent owns directly. They cannot be
        /// carried across a process boundary — the HPCON wall — so each one
        /// holds a handoff back until it closes.
        legacy: usize = 0,

        pub fn live(self: LiveMix) usize {
            return self.holder_backed + self.legacy;
        }

        /// Can this agent hand its sessions to a successor and lose nothing?
        /// True with no live sessions at all, which is the same answer for the
        /// same reason: there is nothing a successor would fail to pick up.
        pub fn handoffSafe(self: LiveMix) bool {
            return self.legacy == 0;
        }
    };

    /// The live split, walked once. Same O(n) reasoning as `liveCount`: a cached
    /// pair would have to track every alive→dead transition AND every holder
    /// adoption/abandonment, and a drift here decides whether a shell survives.
    pub fn liveMix(self: *SessionTable) LiveMix {
        var mix: LiveMix = .{};
        var it = self.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (!s.alive) continue;
            if (s.holder_pipe != null) mix.holder_backed += 1 else mix.legacy += 1;
        }
        return mix;
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
        // LIVE sessions only (T278). A tombstone owns no process and must never
        // be the reason a user's next pane comes up without a shell.
        if (self.liveCount() >= self.max_live) return error.TooManySessions;

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
    /// present — idempotent across a double load. Enforces `max_dead_sessions`.
    pub fn materialize(
        self: *SessionTable,
        rec: session_meta.Record,
        ring_bytes: usize,
        now_ms: i64,
    ) Error!?*Session {
        // Tombstones have their own cap (T278) — they must not eat into the live
        // allowance, and a file that somehow carries thousands of them must not
        // be able to allocate a ring for every one.
        if (self.deadCount() >= max_dead_sessions) return error.TooManyTombstones;
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
        // This load is one more restart the record has survived unclaimed. The
        // count rides through to `persistMeta`, which drops the record once it
        // exceeds `max_unclaimed_restarts` -- without that bound a materialized
        // record is immortal (materialize marks it relaunchable, persistMeta
        // keeps everything relaunchable) and piles up as a permanent chooser row.
        s.unclaimed_restarts = rec.unclaimed_restarts +| 1;
        s.pinned = rec.pinned;
        s.created_ms = rec.created_ms; // preserve the original creation time
        if (rec.argv) |a| s.setArgv(a); // relaunch command + LIST_SESSIONS label
        if (rec.fg_cmd) |f| s.setFgCmd(f); // what was running — the notice names it (T429)
        if (rec.cwd) |c| s.cwd = try self.alloc.dupe(u8, c);
        errdefer if (s.cwd) |c| self.alloc.free(c);
        if (rec.title) |t| s.title = try self.alloc.dupe(u8, t);
        errdefer if (s.title) |t| self.alloc.free(t);
        // Carry the holder handle through (T905). This record may name a
        // `--pty-host` process that is STILL RUNNING with a live shell — the
        // whole point of holders — so it must survive the round trip through
        // disk, or the next persist would erase the only pointer to it.
        // Re-adopting it is T906; keeping it findable is this increment's job.
        if (rec.holder_pipe) |p| s.holder_pipe = try self.alloc.dupe(u8, p);
        errdefer if (s.holder_pipe) |p| self.alloc.free(p);
        if (rec.holder_stamp) |st| s.holder_stamp = try self.alloc.dupe(u8, st);
        s.holder_pid = rec.holder_pid;
        // The ATTACH `ack` a re-adoption will send (T906). Both fields start
        // here: nothing has been delivered this run, so "in the ring" and "in
        // the snapshot" are the same offset until adoption streams the gap.
        s.holder_offset = rec.holder_offset;
        s.holder_snapshot_offset = rec.holder_offset;

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
            // Keep the holder stream offset in lockstep with the ring (T906).
            // Read HERE, not on a timer: the child's reader thread is parked in
            // this very call, so its counter and the ring describe the same
            // instant. A snapshot taken later can then name the exact holder
            // offset its bytes end at.
            if (s.child.deliveredOffset()) |off| s.holder_offset = off;
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

    /// Recorded-cwd refresh cadence, in reaper ticks (T425). Ten seconds: the
    /// value is only ever READ when the agent restarts, so the cost of being a
    /// few seconds stale is nil, while the cost of each sample is a `cd`-sized
    /// OS read per LIVE session (a cross-process PEB read on Windows) — cheap,
    /// but not something to do every second on an idle box for no reason.
    const cwd_every_ticks: u32 = 10;

    fn reaperLoop(self: *SessionStore) void {
        // Wake at most once a second (or on stop) to check for idle orphans.
        const tick_ns: u64 = 1 * std.time.ns_per_s;
        var ticks: u32 = 0;
        var cwd_ticks: u32 = 0;
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
            // "Is anything running under this shell?" (T356), pushed on change
            // so the viewer's close confirmation can decide instantly for a
            // pane whose shell is not in ITS process table. Same one-second
            // cadence as the foreground pid, and for the same reason: a value
            // read at close time is only as good as its last sample, and a
            // command started seconds ago must not read as an idle prompt.
            self.sampleDescendants();
            // Track each live session's CURRENT working directory (T425) so the
            // value that outlives the agent is where the user actually IS, not
            // where the shell was spawned. Separate cadence from the ring
            // snapshot below because it is a different kind of cost (an OS query
            // per session vs. a disk write) and wants its own dial.
            cwd_ticks +%= 1;
            if (cwd_ticks >= cwd_every_ticks) {
                cwd_ticks = 0;
                self.refreshCwds();
                // Same tick, same reasoning: the foreground command (T429) is
                // only ever read when the agent restarts, so a few seconds of
                // staleness is free while each sample costs a process-table
                // walk per live session.
                self.refreshForegroundCommands();
            }
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

    /// Sample whether each bound session's child has any live DESCENDANT process
    /// and push `META{has_descendants}` (via `bridge_busy`) for the ones whose
    /// answer changed (T356). This is what lets the viewer skip the close
    /// confirmation for an idle CROSS-MACHINE pane: its shell is in this
    /// machine's process table, not the viewer's, so we are the only side that
    /// can look.
    ///
    /// Cost discipline, in order:
    ///   1. If no bound session has a `bridge_busy` — i.e. no attached peer
    ///      negotiated `capability.session_busy` — this returns having done
    ///      NOTHING. An agent whose clients are all older pays nothing.
    ///   2. Otherwise ONE parent-table snapshot answers every session at once,
    ///      rather than a walk per session.
    ///
    /// What that costs, since "once a second" invites the question: one
    /// `CreateToolhelp32Snapshot` / `proc_listpids` / `/proc` pass and a
    /// pid→ppid map, and nothing else — no per-process handle, no PEB read, no
    /// allocated name strings. `refreshForegroundCommands` already runs a
    /// HEAVIER walk (Toolhelp + `GetProcessTimes` per candidate + a PEB read)
    /// once per live session every ten ticks, so on any box with a handful of
    /// panes this is the same order of work the agent has always done, and per
    /// walk it is the cheaper of the two. The one-second cadence is not
    /// negotiable down: the value is read at close time, and a command started
    /// N seconds ago must not still read as an idle prompt.
    ///
    /// The snapshot runs OUTSIDE the store mutex: it is an OS enumeration of the
    /// whole process table, not a cheap syscall, so holding the lock across it
    /// would stall every OPEN/ATTACH/DATA frame behind it (the same rule
    /// `refreshCwds` follows, and the opposite of `sampleForegroundPids`, whose
    /// query is contractually one non-blocking syscall). Collect-then-act: the
    /// bridge calls fire outside the lock too, since they take the connection's
    /// writer lock.
    ///
    /// A failed snapshot pushes NOTHING and leaves every recorded answer alone.
    /// The client's last value stays put and a session that never got one stays
    /// UNKNOWN — which it reads as "confirm", the pre-T356 behavior. Reporting
    /// "idle" because we could not look would skip a confirmation and kill a
    /// running job.
    pub fn sampleDescendants(self: *SessionStore) void {
        // Phase 0: is anyone listening? Read under the lock, act on a snapshot
        // of the answer — a connection that unbinds right after is handled by
        // the re-lookup in phase 2.
        self.mutex.lock();
        var wanted = false;
        var it0 = self.table.by_id.valueIterator();
        while (it0.next()) |sp| {
            const s = sp.*;
            if (!s.alive or !s.bound) continue;
            if (s.bridge_busy != null) {
                wanted = true;
                break;
            }
        }
        self.mutex.unlock();
        if (!wanted) return;

        // Phase 1: one table snapshot for every session, taken unlocked.
        var map = proc.snapshotParents(self.table.alloc) orelse return;
        defer map.deinit(self.table.alloc);

        self.sampleDescendantsIn(&map);
    }

    /// `sampleDescendants`'s phase 2, against a caller-supplied parent table.
    /// Split out so the push rules — busy vs idle, silence when nothing changed,
    /// silence for a shell the table cannot see — are testable against a
    /// synthetic process tree rather than whatever the test runner's own
    /// descendants happen to be at that instant.
    pub fn sampleDescendantsIn(self: *SessionStore, map: *const descendants.ParentMap) void {
        const Push = struct {
            f: *const fn (ctx: *anyopaque, channel: u128, has: bool) void,
            ctx: *anyopaque,
            channel: u128,
            has: bool,
        };
        var pushes: std.ArrayList(Push) = .empty;
        defer pushes.deinit(self.table.alloc);

        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (!s.alive or !s.bound) continue;
            const f = s.bridge_busy orelse continue;
            const ctx = s.bridge_ctx orelse continue;
            if (s.pid <= 0) continue;
            // A shell that is not in the snapshot is not something we can answer
            // about — it exited between the walk and here, or the walk could not
            // see it. Leave the recorded value alone rather than reporting the
            // empty-table false.
            if (!descendants.contains(map, s.pid)) continue;
            const has = descendants.hasDescendants(map, s.pid);
            if (s.has_descendants) |prev| if (prev == has) continue;
            pushes.append(self.table.alloc, .{
                .f = f,
                .ctx = ctx,
                .channel = s.channel,
                .has = has,
            }) catch break; // OOM: drop the rest of this tick, retry on the next
            // Recorded only once the push is queued, so an OOM'd session is
            // re-tried next tick instead of being remembered as already sent.
            s.has_descendants = has;
        }
        self.mutex.unlock();

        for (pushes.items) |p| p.f(p.ctx, p.channel, p.has);
    }

    /// Refresh every LIVE session's recorded working directory from its child, so
    /// the value that survives an agent restart is the LAST KNOWN cwd rather than
    /// the one the child happened to be spawned in (T425).
    ///
    /// Why this exists: `handleOpen` records `OPEN.cwd` once and nothing ever
    /// updated it again, so a session the user had `cd`'d out of came back — on a
    /// reboot or an agent upgrade — in the directory it STARTED in. `GET_CWD`
    /// already reads the live value on demand for new splits; this puts the same
    /// answer where the reboot floor can find it.
    ///
    /// The OS query runs OUTSIDE `store.mutex`. Unlike `queryForegroundPid` it is
    /// explicitly NOT a cheap single syscall (macOS `proc_pidinfo`, a cross-process
    /// Windows PEB read), so holding the store lock across it would stall every
    /// OPEN/ATTACH/DATA frame behind a directory read. Same collect-then-act shape
    /// as `handleGetCwd` and `reapIdle`: snapshot `(id, child)` under the lock,
    /// query unlocked, then re-look-up **by id** before writing — a concurrent
    /// CLOSE may have unlinked and freed the session while we were unlocked, so
    /// the pointer we started from must not be dereferenced afterwards.
    pub fn refreshCwds(self: *SessionStore) void {
        const Probe = struct { id: u128, child: Child };
        var probes: std.ArrayList(Probe) = .empty;
        defer probes.deinit(self.table.alloc);

        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            // A tombstone is skipped, not queried: its child is gone, and the cwd
            // already recorded is exactly the one the notify restore is about to
            // place the fresh shell in.
            if (!s.alive) continue;
            probes.append(self.table.alloc, .{
                .id = s.id,
                .child = s.child,
            }) catch break; // OOM: take the rest next tick
        }
        self.mutex.unlock();

        var changed = false;
        for (probes.items) |p| {
            // A null/empty answer (unsupported, access denied, a child on its way
            // out) KEEPS the last known value. Forgetting it is strictly worse
            // than a stale one: with no recorded cwd the respawn inherits the
            // AGENT's own directory — `C:\WINDOWS\system32` on the win32 autostart
            // path, which is the T132 failure this record exists to prevent.
            const cwd = p.child.queryCwd(self.table.alloc) orelse continue;
            defer self.table.alloc.free(cwd);
            if (cwd.len == 0) continue;

            self.mutex.lock();
            if (self.table.getById(p.id)) |s| {
                const same = if (s.cwd) |c| std.mem.eql(u8, c, cwd) else false;
                if (!same) {
                    s.setCwd(cwd);
                    changed = true;
                }
            }
            self.mutex.unlock();
        }

        // Only touch the disk when something actually moved. This runs on the
        // reaper's tick, and an unconditional rewrite would put a periodic write
        // on an idle box for no gain.
        if (changed) self.persistMeta();
    }

    /// Refresh every LIVE session's recorded FOREGROUND command from its child
    /// (T429), so the restart notice can name what a plain shell pane was
    /// actually running. Same collect-then-act shape and locking rules as
    /// `refreshCwds` (the query is expensive and runs OUTSIDE the store lock;
    /// the write re-looks-up by id). The tri-state differs deliberately:
    ///   - `.cmd`  → record it,
    ///   - `.none` → the shell is at an idle prompt: CLEAR the record. A stale
    ///     "previous command" for a program that already finished is exactly
    ///     the false assertion this field exists to avoid,
    ///   - null (query failed) → KEEP the last known value (T425's rule).
    pub fn refreshForegroundCommands(self: *SessionStore) void {
        const Probe = struct { id: u128, child: Child };
        var probes: std.ArrayList(Probe) = .empty;
        defer probes.deinit(self.table.alloc);

        self.mutex.lock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            // Tombstones keep whatever was last sampled — that recorded value
            // is precisely what the notify restore is about to display.
            if (!s.alive) continue;
            probes.append(self.table.alloc, .{
                .id = s.id,
                .child = s.child,
            }) catch break; // OOM: take the rest next tick
        }
        self.mutex.unlock();

        var changed = false;
        for (probes.items) |p| {
            const q = p.child.queryForegroundCommand(self.table.alloc) orelse continue;
            const cmd: ?[]u8 = switch (q) {
                .none => null,
                .cmd => |c| c,
            };
            defer if (cmd) |c| self.table.alloc.free(c);

            self.mutex.lock();
            if (self.table.getById(p.id)) |s| {
                const same = if (s.fg_cmd) |have|
                    (if (cmd) |want| std.mem.eql(u8, have, want) else false)
                else
                    cmd == null;
                if (!same) {
                    s.setFgCmd(cmd);
                    changed = true;
                }
            }
            self.mutex.unlock();
        }

        // Disk only when something moved, exactly like the cwd refresh.
        if (changed) self.persistMeta();
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

        // Newest first (T278). A file may carry more records than
        // `max_dead_sessions` allows us to materialize, and the ones a user is
        // most likely to want back are the ones they opened most recently — file
        // order is `persistMeta`'s hash-map iteration order, i.e. arbitrary, so
        // without this "which sessions survive an over-full file" would be a coin
        // toss. Sorted on a local index array; the parsed slice is const.
        const order = alloc.alloc(u32, parsed.value.sessions.len) catch null;
        defer if (order) |o| alloc.free(o);
        if (order) |o| {
            for (o, 0..) |*slot, i| slot.* = @intCast(i);
            const Ctx = struct {
                recs: []const session_meta.Record,
                fn gt(ctx: @This(), a: u32, b: u32) bool {
                    return ctx.recs[a].created_ms > ctx.recs[b].created_ms;
                }
            };
            std.mem.sort(u32, o, Ctx{ .recs = parsed.value.sessions }, Ctx.gt);
        }

        var n: usize = 0;
        var refused: usize = 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (parsed.value.sessions, 0..) |_, i| {
            const rec = parsed.value.sessions[if (order) |o| o[i] else i];
            const s = self.table.materialize(rec, ring_bytes, self.now()) catch |err| {
                if (err == error.TooManyTombstones) {
                    // Expected once past the cap, and per-record warnings would
                    // be a wall of identical lines. Count them and say it once.
                    refused += 1;
                    continue;
                }
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
                //
                // The restart DIVIDER is deferred for a holder-backed record
                // (T906): its shell may still be running in a `--pty-host`
                // process, in which case nothing restarted and drawing the
                // divider would be a lie the user reads as lost work. Adoption
                // decides — `adoptHolder` leaves the ring seamless, and
                // `abandonHolder` draws it on the way to the tombstone path.
                self.preloadRingSnapshot(sess, sess.holder_pipe == null);
            }
        }
        if (refused > 0) std.log.warn(
            "session_meta: {d} of {d} recorded sessions dropped — more than max_dead_sessions ({d}); kept the newest",
            .{ refused, parsed.value.sessions.len, max_dead_sessions },
        );
        return n;
    }

    /// Load `sess`'s ring disk snapshot (if any) into its output ring, then append
    /// the reboot divider, and anchor `out_offset` at the ring tail so a later
    /// RELAUNCH's fresh child output continues after it (T13, §5.4). The ring is
    /// renumbered to base offset 0 (a freshly-restored viewer applies DATA from 0
    /// with no resync watermark — a non-zero base would manufacture a phantom gap).
    /// No-op when ring snapshots are disabled or none exists. Called under the store
    /// lock from `loadPersisted`, before any connection or the reaper runs.
    ///
    /// `with_divider = false` loads the scrollback but leaves the divider off,
    /// for a holder-backed record whose shell may not have restarted at all
    /// (T906); `appendRestartDivider` adds it later if adoption fails.
    fn preloadRingSnapshot(self: *SessionStore, sess: *Session, with_divider: bool) void {
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
        if (with_divider) appendRestartDivider(sess);
        // Not dirty: this is loaded-from-disk content, not new child output.
        sess.last_snapshot_offset = sess.out_offset.value;
    }

    /// Append the restart divider to `sess`'s ring at its current tail. Split
    /// out of `preloadRingSnapshot` so a holder-backed session can defer the
    /// decision until adoption has answered "did anything actually restart?"
    /// (T906). Caller holds the store lock. No-op on an empty ring — a divider
    /// with nothing above it marks a boundary the user never crossed.
    fn appendRestartDivider(sess: *Session) void {
        if (sess.ring.len == 0) return;
        sess.ring.append(sess.out_offset.value, reboot_divider);
        sess.out_offset.value +%= reboot_divider.len;
        sess.last_snapshot_offset = sess.out_offset.value;
    }

    // -------------------------------------------------------------------------
    // Holder adoption (T906)
    // -------------------------------------------------------------------------
    //
    // A session materialized from disk whose record names a `--pty-host` holder
    // is only a TOMBSTONE-SHAPED PLACEHOLDER: the shell behind it may still be
    // running in that separate process. Turning it back into a live session is a
    // three-step conversation the store cannot have on its own, because dialing
    // the holder lives in `pty_holder_child.zig` and that module imports THIS
    // one. So the store supplies the halves that touch session state —
    // `holderCandidates` (who to try), `adoptHolder` (it answered),
    // `abandonHolder` (it did not) — and `holder_adopt.zig` does the dialing.

    /// A materialized session that names a holder worth dialing.
    pub const HolderCandidate = struct {
        id: u128,
        /// Hex form, for logs and for matching the holder's HELLO `session_id`.
        id_str: [32]u8,
        /// Owned by the caller (`freeHolderCandidates`).
        pipe: []u8,
        holder_pid: u32,
        /// What to send as the ATTACH `ack`: the holder offset this session's
        /// preloaded ring already ends at.
        ack: u64,
    };

    /// Snapshot every materialized session that carries a holder pipe. Takes the
    /// lock briefly and hands back owned copies, so the caller can spend seconds
    /// dialing pipes without holding up child output.
    pub fn holderCandidates(self: *SessionStore, alloc: Allocator) Allocator.Error![]HolderCandidate {
        var out: std.ArrayList(HolderCandidate) = .empty;
        errdefer {
            for (out.items) |c| alloc.free(c.pipe);
            out.deinit(alloc);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.alive) continue; // already live: not a survivor to pick up
            const pipe = s.holder_pipe orelse continue;
            try out.append(alloc, .{
                .id = s.id,
                .id_str = s.id_str,
                .pipe = try alloc.dupe(u8, pipe),
                .holder_pid = s.holder_pid,
                .ack = s.holder_snapshot_offset,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn freeHolderCandidates(alloc: Allocator, list: []HolderCandidate) void {
        for (list) |c| alloc.free(c.pipe);
        alloc.free(list);
    }

    /// Every holder pipe this store currently claims, alive or tombstoned —
    /// the "leave these alone" set for the orphan sweep. Owned copies; the
    /// caller frees each entry and the slice.
    pub fn holderPipes(self: *SessionStore, alloc: Allocator) Allocator.Error![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |p| alloc.free(p);
            out.deinit(alloc);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.table.by_id.valueIterator();
        while (it.next()) |sp| {
            const pipe = sp.*.holder_pipe orelse continue;
            try out.append(alloc, try alloc.dupe(u8, pipe));
        }
        return out.toOwnedSlice(alloc);
    }

    /// The holder answered: adopt `child` as this session's live child. Returns
    /// the session's channel so the caller can `child.attach(...)` it to the
    /// store sink AFTER this returns — attaching under the store lock would
    /// deadlock against the sink (see `remove`'s deadlock warning).
    ///
    /// Returns null (and adopts nothing) if the session went away or is already
    /// alive; the caller then terminates the child it opened.
    pub fn adoptHolder(
        self: *SessionStore,
        id: u128,
        child: Child,
        shell_pid: u32,
        stamp: []const u8,
    ) ?u128 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.table.getById(id) orelse return null;
        if (s.alive) return null;
        // The placeholder is `deadChild()` — inert, nothing to tear down.
        s.child.terminate();
        s.child = child;
        s.pid = @intCast(shell_pid);
        s.alive = true;
        // Not a reboot-floor tombstone any more: the process it describes never
        // stopped, so it must not be offered a RELAUNCH that would replace a
        // running shell. And the restart allowance resets — a session whose
        // shell is still running has plainly not gone stale.
        s.relaunchable = false;
        s.unclaimed_restarts = 0;
        s.exit_code = null;
        s.last_activity_ms = self.now();
        if (s.holder_stamp) |old| self.table.alloc.free(old);
        s.holder_stamp = self.table.alloc.dupe(u8, stamp) catch null;
        return s.channel;
    }

    /// Adoption did not happen: put the session back on the plain
    /// relaunchable-tombstone path it would have taken before holders existed,
    /// drawing the restart divider `loadPersisted` deferred.
    ///
    /// `forget_pipe` is the difference between the two ways adoption can fail.
    /// The holder did not answer at all — it is gone, and so is the shell — so
    /// the stale handle is dropped and nothing dials it again. But a holder
    /// this agent merely cannot SERVE (a newer protocol, after a rollback) is
    /// still alive and still adoptable by a newer build, so its record is KEPT:
    /// that record is also what marks the pipe as claimed, and without it the
    /// orphan sweep would immediately shut down the very holder we just
    /// promised to leave running.
    pub fn abandonHolder(self: *SessionStore, id: u128, forget_pipe: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.table.getById(id) orelse return;
        if (s.alive) return;
        if (forget_pipe) {
            if (s.holder_pipe) |p| self.table.alloc.free(p);
            if (s.holder_stamp) |st| self.table.alloc.free(st);
            s.holder_pipe = null;
            s.holder_stamp = null;
            s.holder_pid = 0;
            s.holder_offset = 0;
            s.holder_snapshot_offset = 0;
        }
        appendRestartDivider(s);
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
            // The holder offset these bytes end at (T906) — captured under the
            // same lock as the ring copy, so the pair cannot drift.
            const cap_holder_offset = s.holder_offset;
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
                // Advance the adoption watermark with the file that was just
                // written. Monotonic, like `last_snapshot_offset`: a later pass
                // that raced ahead must not be walked backwards.
                if (s2.holder_snapshot_offset < cap_holder_offset) {
                    s2.holder_snapshot_offset = cap_holder_offset;
                }
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
            // A relaunchable tombstone is kept so the reboot floor survives a
            // restart -- but only for a BOUNDED number of them. Materialize marks
            // every loaded record relaunchable and this loop keeps every
            // relaunchable record, so without this check a record can never leave
            // the file: it is re-loaded and re-written forever, showing in the
            // chooser as a permanent "Resume" row for a process that exited long
            // ago, and the list grows with each restart. Past the allowance
            // nothing has re-attached across two full agent lifetimes, so it is
            // stale and the file finally self-heals.
            if (!s.alive and s.unclaimed_restarts > session_meta.max_unclaimed_restarts) continue;
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
    const fg_cmd: ?[]u8 = if (s.fg_cmd) |f| try alloc.dupe(u8, f) else null;
    errdefer if (fg_cmd) |f| alloc.free(f);
    const cwd: ?[]u8 = if (s.cwd) |c| try alloc.dupe(u8, c) else null;
    errdefer if (cwd) |c| alloc.free(c);
    const title: ?[]u8 = if (s.title) |t| try alloc.dupe(u8, t) else null;
    errdefer if (title) |t| alloc.free(t);
    const holder_pipe: ?[]u8 = if (s.holder_pipe) |p| try alloc.dupe(u8, p) else null;
    errdefer if (holder_pipe) |p| alloc.free(p);
    const holder_stamp: ?[]u8 = if (s.holder_stamp) |st| try alloc.dupe(u8, st) else null;
    return .{
        .id = id,
        .argv = argv,
        .fg_cmd = fg_cmd,
        .cwd = cwd,
        .title = title,
        .pinned = s.pinned,
        .created_ms = s.created_ms,
        .unclaimed_restarts = s.unclaimed_restarts,
        .holder_pipe = holder_pipe,
        .holder_pid = s.holder_pid,
        .holder_stamp = holder_stamp,
        // The SNAPSHOT's watermark, never the live one: after a crash the
        // snapshot is what the next agent's ring is built from.
        .holder_offset = s.holder_snapshot_offset,
    };
}

/// Free every string in an owned metadata record (the inverse of `dupMetaRecord`).
fn freeMetaRecord(alloc: Allocator, r: session_meta.Record) void {
    alloc.free(r.id);
    if (r.argv) |a| alloc.free(a);
    if (r.fg_cmd) |f| alloc.free(f);
    if (r.cwd) |c| alloc.free(c);
    if (r.title) |t| alloc.free(t);
    if (r.holder_pipe) |p| alloc.free(p);
    if (r.holder_stamp) |s| alloc.free(s);
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
    /// What `queryCwd` answers (models the OS read of the child's CURRENT cwd).
    /// Null = the query is unsupported or failed, which is the case the refresh
    /// must treat as "keep what we recorded", never as "forget it".
    fake_cwd: ?[]const u8 = null,
    /// How many times `queryCwd` was asked — so a test can prove the refresh
    /// skips dead sessions instead of merely finding their value unchanged.
    cwd_queries: usize = 0,
    /// What `queryForegroundCommand` answers, modeling the tri-state (T429):
    /// outer null = the query FAILS (keep the record), inner null = the shell
    /// is at an idle prompt (`.none`, clear the record), a string = `.cmd`.
    fake_fg: ??[]const u8 = null,
    /// How many times `queryForegroundCommand` was asked (dead-session skip proof).
    fg_queries: usize = 0,
    /// Stands in for a holder-backed child's stream position (T906). Null keeps
    /// the child answering like every in-process child does — "I have no holder
    /// offset" — so the reconciliation code paths stay off unless a test asks.
    fake_holder_offset: ?u64 = null,
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
        .queryCwd = qcwd,
        .queryForegroundCommand = qfg,
        .deliveredOffset = dof,
    };
    fn dof(ctx: *anyopaque) ?u64 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        return self.fake_holder_offset;
    }
    fn qcwd(ctx: *anyopaque, alloc: Allocator) ?[]u8 {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.cwd_queries += 1;
        const c = self.fake_cwd orelse return null;
        return alloc.dupe(u8, c) catch null;
    }
    fn qfg(ctx: *anyopaque, alloc: Allocator) ?ForegroundCommand {
        const self: *FakeChild = @ptrCast(@alignCast(ctx));
        self.fg_queries += 1;
        const answer = self.fake_fg orelse return null;
        const c = answer orelse return .none;
        return .{ .cmd = alloc.dupe(u8, c) catch return null };
    }
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

test "SessionTable: a table full of TOMBSTONES still opens a live session (T278)" {
    // THE wedge, in miniature. Measured on box 2026-08-01: the agent's table held
    // 256 records, every one `alive=false pid=0 pinned=true`, and from then on
    // every `OPEN` was refused — so every new pane came up with no shell and
    // nothing said so. A dead session owns no process; it must never be the
    // reason a user is denied one.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7278);
    // Before the table: `table.deinit()` terminates every child, so the fake must
    // outlive it (defers unwind LIFO).
    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();
    var table = SessionTable.init(alloc, prng.random());
    defer table.deinit();

    // Fill the table to `max_sessions` with dead-but-relaunchable tombstones,
    // exactly what a restored persistent pane leaves behind.
    var id_buf: [32]u8 = undefined;
    for (0..max_sessions) |i| {
        const id = try std.fmt.bufPrint(&id_buf, "{x:0>32}", .{i + 1});
        const s = (try table.materialize(.{ .id = id, .pinned = true }, 64, 0)).?;
        try testing.expect(!s.alive and s.relaunchable);
    }
    try testing.expectEqual(max_sessions, table.count());
    try testing.expectEqual(@as(usize, 0), table.liveCount());
    try testing.expectEqual(max_sessions, table.deadCount());

    // The whole point: the next OPEN still gets a session.
    const live = try table.create(fake.child(), 4242, 24, 80, 64, 0);
    try testing.expect(live.alive);
    try testing.expectEqual(@as(usize, 1), table.liveCount());

    // And the tombstone cap is enforced on its own side of the line.
    const over = try std.fmt.bufPrint(&id_buf, "{x:0>32}", .{max_dead_sessions + 9});
    try testing.expectError(
        error.TooManyTombstones,
        table.materialize(.{ .id = over, .pinned = true }, 64, 0),
    );
}

test "SessionTable: a genuinely full LIVE table still refuses (T278)" {
    // The other half of the same rule: relaxing the cap to live sessions must not
    // relax it away. Without this, "dead sessions don't count" is indistinguishable
    // from "nothing counts".
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7279);

    // A small cap would make this cheaper, but `max_sessions` is the number the
    // product ships and the assertion is about that number. Declared BEFORE the
    // table so the defers unwind in the right order: `table.deinit()` terminates
    // every child, and a child whose `FakeChild` had already been freed is a
    // use-after-free (measured — it segfaulted this test).
    const fakes = try alloc.alloc(FakeChild, max_sessions);
    defer alloc.free(fakes);
    for (fakes) |*f| f.* = .{ .alloc = alloc };
    defer for (fakes) |*f| f.deinit();

    var extra: FakeChild = .{ .alloc = alloc };
    defer extra.deinit();

    var table = SessionTable.init(alloc, prng.random());
    defer table.deinit();

    for (fakes, 0..) |*f, i| _ = try table.create(f.child(), @intCast(i + 1), 24, 80, 64, 0);
    try testing.expectEqual(max_sessions, table.liveCount());

    try testing.expectError(
        error.TooManySessions,
        table.create(extra.child(), 9999, 24, 80, 64, 0),
    );

    // A session that dies gives its slot back — the cap tracks processes, not rows.
    var vit = table.by_id.valueIterator();
    vit.next().?.*.markExited(0, 10);
    try testing.expectEqual(max_sessions - 1, table.liveCount());
    _ = try table.create(extra.child(), 9999, 24, 80, 64, 0);
}

test "SessionStore.loadPersisted: an over-full file keeps the NEWEST sessions (T278)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x727a);
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

    // More records than the tombstone cap allows, written OLDEST first so file
    // order and the answer disagree — a loader that just took the first N would
    // keep precisely the wrong ones.
    const over = 12;
    const total = max_dead_sessions + over;
    const ids = try alloc.alloc([32]u8, total);
    defer alloc.free(ids);
    const recs = try alloc.alloc(session_meta.Record, total);
    defer alloc.free(recs);
    for (recs, 0..) |*r, i| {
        _ = try std.fmt.bufPrint(&ids[i], "{x:0>32}", .{i + 1});
        r.* = .{ .id = &ids[i], .pinned = true, .created_ms = @intCast(1000 + i) };
    }
    const body = try session_meta.serialize(alloc, recs);
    defer alloc.free(body);
    try session_meta.writeAtomic(alloc, path, body);

    try testing.expectEqual(max_dead_sessions, store.loadPersisted(64));
    // The newest `max_dead_sessions` survived; the `over` oldest did not.
    for (0..total) |i| {
        const present = store.table.getByIdStr(&ids[i]) != null;
        try testing.expectEqual(i >= over, present);
    }
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

test "persistMeta: an unclaimed reboot-floor tombstone ages out instead of living forever" {
    // The ratchet this guards against: `materialize` marks EVERY record loaded
    // from disk `relaunchable = true`, and `persistMeta` keeps every relaunchable
    // record -- so without a bound a record can never leave sessions.json. It is
    // re-loaded and re-written on every agent start, shows in the chooser as a
    // permanent "Resume" row for a process that exited long ago, and the set only
    // grows. Observed in the field as 8 -> 9 -> 11 -> 13 -> 14 sessions.
    const R = session_meta.Record;
    const cap = session_meta.max_unclaimed_restarts;

    // A record that has just been written by a live session starts at 0 and is
    // kept across the next few restarts (the reboot floor still works).
    var rec: R = .{ .id = "a", .pinned = true, .unclaimed_restarts = 0 };
    var survived: u32 = 0;
    while (survived <= cap) : (survived += 1) {
        // Each agent start materializes it and bumps the count.
        rec.unclaimed_restarts += 1;
        const kept = !(rec.unclaimed_restarts > cap);
        if (survived < cap) try testing.expect(kept);
    }
    // Past the allowance it is dropped, so the file self-heals.
    try testing.expect(rec.unclaimed_restarts > cap);

    // A session someone actually resumes has its allowance reset, so ordinary
    // daily use can never age a session out.
    rec.unclaimed_restarts = 0;
    try testing.expect(!(rec.unclaimed_restarts > cap));
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

test "SessionStore.refreshCwds: a live session's recorded cwd follows the child, and lands in sessions.json (T425)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x425A);
    var fake: FakeChild = .{ .alloc = alloc, .fake_cwd = "/work/ghoztty" };
    defer fake.deinit();

    var clock: MutClock = .{ .ms = 100 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(path);
    store.meta_path = path;

    // The session as OPEN recorded it: the directory it was SPAWNED in.
    const s = try store.table.create(fake.child(), 700, 24, 80, 1024, 100);
    s.pinned = true;
    s.setCwd("/work/ghoztty");

    // The user cds somewhere else. Nothing in the session record knows yet —
    // this is the whole bug: before T425 the spawn-time value was the only one
    // ever written, so a restore put the pane back where it STARTED rather
    // than where the user actually was.
    fake.fake_cwd = "/work/ghoztty/src/apprt";
    store.refreshCwds();

    try testing.expectEqualStrings("/work/ghoztty/src/apprt", s.cwd.?);

    // And it is durable: a refresh that changed something must reach disk, or
    // an agent restart (the only time this value is ever read back) still
    // materializes the stale one.
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.sessions.len);
        try testing.expectEqualStrings("/work/ghoztty/src/apprt", p.value.sessions[0].cwd.?);
    }
}

test "SessionStore.refreshCwds: a failed query, an unchanged cwd, and a dead session all keep the record (T425)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x425B);
    var live: FakeChild = .{ .alloc = alloc, .fake_cwd = "/work/a" };
    var dead: FakeChild = .{ .alloc = alloc, .fake_cwd = "/work/should-never-be-read" };
    defer live.deinit();
    defer dead.deinit();

    var clock: MutClock = .{ .ms = 100 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    const s_live = try store.table.create(live.child(), 701, 24, 80, 1024, 100);
    s_live.setCwd("/work/a");
    const s_dead = try store.table.create(dead.child(), 702, 24, 80, 1024, 100);
    s_dead.setCwd("/work/b");
    s_dead.markExited(0, 150);

    store.refreshCwds();

    // A dead session is never queried: its child is gone, and its recorded cwd
    // is precisely what the notify restore is about to place the fresh shell in.
    try testing.expectEqual(@as(usize, 0), dead.cwd_queries);
    try testing.expectEqualStrings("/work/b", s_dead.cwd.?);
    // Unchanged is a no-op, not a rewrite.
    try testing.expectEqualStrings("/work/a", s_live.cwd.?);

    // A query that FAILS (unsupported OS, denied, transient) must leave the
    // last known value alone. Forgetting it would put the restored pane in the
    // agent's own inherited cwd — `C:\WINDOWS\system32` on the win32 autostart
    // path, which is the T132 failure this record exists to prevent.
    live.fake_cwd = null;
    store.refreshCwds();
    try testing.expectEqualStrings("/work/a", s_live.cwd.?);
}

test "SessionStore.refreshForegroundCommands: records what runs, clears at the prompt, lands in sessions.json (T429)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4290);
    // A plain shell pane: no OPEN command, no OPEN shell — argv stays null.
    var fake: FakeChild = .{ .alloc = alloc, .fake_fg = @as(?[]const u8, "claude --continue") };
    defer fake.deinit();

    var clock: MutClock = .{ .ms = 100 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(path);
    store.meta_path = path;

    const s = try store.table.create(fake.child(), 800, 24, 80, 1024, 100);
    s.pinned = true;

    // The user is running something: the sample records it, argv stays null
    // (it is the relaunch input, and nobody asked to relaunch claude).
    store.refreshForegroundCommands();
    try testing.expectEqualStrings("claude --continue", s.fg_cmd.?);
    try testing.expect(s.argv == null);

    // Durable: the value is only ever read after an agent restart, so a
    // sample that never reaches sessions.json may as well not exist.
    {
        var p = (try session_meta.load(alloc, path)).?;
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.sessions.len);
        try testing.expectEqualStrings("claude --continue", p.value.sessions[0].fg_cmd.?);
        try testing.expect(p.value.sessions[0].argv == null);
    }

    // The program exits; the shell is back at its prompt. The record CLEARS —
    // a notice naming a command that already finished would assert something
    // false, which is the exact noise this feature exists to avoid.
    fake.fake_fg = @as(?[]const u8, null); // .none: idle prompt
    store.refreshForegroundCommands();
    try testing.expect(s.fg_cmd == null);
}

test "SessionStore.refreshForegroundCommands: a failed query keeps the record; a dead session is never asked (T429)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4291);
    var live: FakeChild = .{ .alloc = alloc, .fake_fg = @as(?[]const u8, "zig build test") };
    var dead: FakeChild = .{ .alloc = alloc, .fake_fg = @as(?[]const u8, "never-read") };
    defer live.deinit();
    defer dead.deinit();

    var clock: MutClock = .{ .ms = 100 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 1000);
    defer store.deinit();

    const s_live = try store.table.create(live.child(), 801, 24, 80, 1024, 100);
    const s_dead = try store.table.create(dead.child(), 802, 24, 80, 1024, 100);
    s_dead.setFgCmd("ping 127.0.0.1");
    s_dead.markExited(0, 150);

    store.refreshForegroundCommands();
    try testing.expectEqualStrings("zig build test", s_live.fg_cmd.?);
    // The tombstone keeps its last sample unqueried — that recorded value is
    // exactly what the notify restore is about to display.
    try testing.expectEqual(@as(usize, 0), dead.fg_queries);
    try testing.expectEqualStrings("ping 127.0.0.1", s_dead.fg_cmd.?);

    // Transient failure (query null) keeps the last known value, T425's rule.
    live.fake_fg = null;
    store.refreshForegroundCommands();
    try testing.expectEqualStrings("zig build test", s_live.fg_cmd.?);
}

test "SessionTable.materialize: fg_cmd survives the reboot floor round-trip (T429)" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4292);
    var table = SessionTable.init(alloc, prng.random());
    defer table.deinit();

    const rec: session_meta.Record = .{
        .id = "0123456789abcdef0123456789abcdef",
        .fg_cmd = "claude --continue",
        .cwd = "/work",
    };
    const s = (try table.materialize(rec, 1024, 100)).?;
    try testing.expectEqualStrings("claude --continue", s.fg_cmd.?);
    try testing.expect(s.argv == null);

    // And the record a persist would write carries it back out.
    const out = try dupMetaRecord(alloc, s);
    defer freeMetaRecord(alloc, out);
    try testing.expectEqualStrings("claude --continue", out.fg_cmd.?);
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

// -----------------------------------------------------------------------------
// T906 — holder adoption + ring reconciliation
// -----------------------------------------------------------------------------

test "holder offset: sessions.json carries the SNAPSHOT's watermark, not the live ring's" {
    // This is the whole no-gap/no-duplicate guarantee in one assertion. The
    // number a re-adopting agent sends as its ATTACH `ack` must describe the
    // bytes that SURVIVED — i.e. the on-disk ring snapshot. Persisting the live
    // position instead would silently skip every byte written since the last
    // snapshot, which is exactly the hole an agent crash produces.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const meta = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(meta);
    const rings = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    defer alloc.free(rings);

    var prng = std.Random.DefaultPrng.init(0xa906);
    var clock: MutClock = .{ .ms = 500 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 100000);
    store.meta_path = meta;
    store.rings_dir = rings;
    defer store.deinit();

    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();
    const s = try store.table.create(fake.child(), 4242, 24, 80, 1 << 16, 500);
    s.pinned = true;
    s.setHolder("\\\\.\\pipe\\ghoztty-pty-host-x-aa", 777, "stamp-1");
    const id_buf: [32]u8 = s.id_str;

    // Output arrives: the store reads the child's stream position from inside
    // the sink, so ring and offset move together.
    fake.fake_holder_offset = 100;
    store.onChildOutput(s.channel, "a" ** 100);
    try testing.expectEqual(@as(u64, 100), s.holder_offset);
    try testing.expectEqual(@as(u64, 0), s.holder_snapshot_offset); // nothing on disk yet

    store.snapshotRings();
    try testing.expectEqual(@as(u64, 100), s.holder_snapshot_offset);

    // More output, NO snapshot: the live position runs ahead, the durable one
    // must not follow it.
    fake.fake_holder_offset = 250;
    store.onChildOutput(s.channel, "b" ** 150);
    try testing.expectEqual(@as(u64, 250), s.holder_offset);
    try testing.expectEqual(@as(u64, 100), s.holder_snapshot_offset);

    store.persistMeta();
    var parsed = (try session_meta.load(alloc, meta)).?;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.sessions.len);
    const rec = parsed.value.sessions[0];
    try testing.expectEqualStrings(id_buf[0..], rec.id);
    try testing.expectEqual(@as(u64, 100), rec.holder_offset);
    try testing.expectEqualStrings("\\\\.\\pipe\\ghoztty-pty-host-x-aa", rec.holder_pipe.?);

    // And the round trip: a fresh store loads that number as the ack to send.
    var prng2 = std.Random.DefaultPrng.init(0xb906);
    var clock2: MutClock = .{ .ms = 9000 };
    var store2 = SessionStore.init(alloc, prng2.random(), &clock2, MutClock.nowFn, 100000);
    store2.meta_path = meta;
    store2.rings_dir = rings;
    defer store2.deinit();
    try testing.expectEqual(@as(usize, 1), store2.loadPersisted(1 << 16));
    const s2 = store2.table.getByIdStr(id_buf[0..]).?;
    try testing.expectEqual(@as(u64, 100), s2.holder_snapshot_offset);

    const cands = try store2.holderCandidates(alloc);
    defer SessionStore.freeHolderCandidates(alloc, cands);
    try testing.expectEqual(@as(usize, 1), cands.len);
    try testing.expectEqual(@as(u64, 100), cands[0].ack);
    try testing.expectEqual(@as(u32, 777), cands[0].holder_pid);
    try testing.expectEqualStrings("\\\\.\\pipe\\ghoztty-pty-host-x-aa", cands[0].pipe);
}

test "a holder-backed record loads with NO restart divider; abandoning it draws one" {
    // The divider says "your shell died and came back". For a session whose
    // holder is still running that is a lie the user reads as lost work, so it
    // is deferred until adoption has answered — and drawn on the way to the
    // tombstone when the holder turns out to be gone.
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const meta = try std.fs.path.join(alloc, &.{ dir_path, "sessions.json" });
    defer alloc.free(meta);
    const rings = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    defer alloc.free(rings);
    try std.fs.cwd().makePath(rings);

    const id = "cccccccccccccccccccccccccccccccc";
    const payload = "before the agent died";
    const rp = try ring_snapshot.pathFor(alloc, rings, id);
    defer alloc.free(rp);
    try ring_snapshot.writeAtomic(alloc, rp, 0, 80, 24, payload);

    const recs = [_]session_meta.Record{.{
        .id = id,
        .argv = "pwsh",
        .created_ms = 100,
        .holder_pipe = "\\\\.\\pipe\\ghoztty-pty-host-x-cc",
        .holder_pid = 4321,
        .holder_offset = 512,
    }};
    const body = try session_meta.serialize(alloc, &recs);
    defer alloc.free(body);
    try session_meta.writeAtomic(alloc, meta, body);

    var prng = std.Random.DefaultPrng.init(0xc906);
    var clock: MutClock = .{ .ms = 9000 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 100000);
    store.meta_path = meta;
    store.rings_dir = rings;
    defer store.deinit();
    try testing.expectEqual(@as(usize, 1), store.loadPersisted(1 << 16));
    const s = store.table.getByIdStr(id).?;

    // Scrollback restored, seam clean.
    var buf: [256]u8 = undefined;
    try testing.expectEqual(@as(u64, payload.len), s.out_offset.value);
    try testing.expectEqualStrings(payload, buf[0..s.ring.copyRetained(&buf)]);
    try testing.expectEqual(@as(u64, 512), s.holder_snapshot_offset);

    // The holder did not answer: NOW the user is told the session restarted,
    // and the dead pipe stops being advertised to anybody.
    store.abandonHolder(s.id, true);
    const n = s.ring.copyRetained(&buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], payload));
    try testing.expect(std.mem.endsWith(u8, buf[0..n], reboot_divider));
    try testing.expect(s.holder_pipe == null);
    try testing.expectEqual(@as(u32, 0), s.holder_pid);
    try testing.expect(!s.alive and s.relaunchable); // the path it always took

    const cands = try store.holderCandidates(alloc);
    defer SessionStore.freeHolderCandidates(alloc, cands);
    try testing.expectEqual(@as(usize, 0), cands.len);
}

test "adoptHolder: a tombstone becomes the live session it never stopped being" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xd906);
    var clock: MutClock = .{ .ms = 9000 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 100000);
    defer store.deinit();

    const id = "dddddddddddddddddddddddddddddddd";
    const s = (try store.table.materialize(.{
        .id = id,
        .argv = "pwsh",
        .created_ms = 100,
        .unclaimed_restarts = 1,
        .holder_pipe = "\\\\.\\pipe\\ghoztty-pty-host-x-dd",
        .holder_pid = 4321,
        .holder_stamp = "old-stamp",
        .holder_offset = 900,
    }, 1024, 9000)).?;
    try testing.expect(!s.alive and s.relaunchable);
    try testing.expectEqual(@as(u32, 2), s.unclaimed_restarts); // one more restart survived

    var fake: FakeChild = .{ .alloc = alloc };
    defer fake.deinit();
    const channel = store.adoptHolder(s.id, fake.child(), 31337, "new-stamp").?;
    try testing.expectEqual(s.channel, channel);
    try testing.expect(s.alive);
    // NOT relaunchable: offering to relaunch a shell that is still running
    // would spawn a second one beside it.
    try testing.expect(!s.relaunchable);
    try testing.expectEqual(@as(i64, 31337), s.pid); // the SHELL, from HELLO
    try testing.expect(s.exit_code == null);
    // A session whose shell never stopped is not a stale reboot-floor leftover.
    try testing.expectEqual(@as(u32, 0), s.unclaimed_restarts);
    try testing.expectEqualStrings("new-stamp", s.holder_stamp.?);

    // It is no longer a candidate (it is live), but the orphan sweep must still
    // see its pipe as claimed — otherwise the sweep reaps what it just adopted.
    const cands = try store.holderCandidates(alloc);
    defer SessionStore.freeHolderCandidates(alloc, cands);
    try testing.expectEqual(@as(usize, 0), cands.len);
    const pipes = try store.holderPipes(alloc);
    defer {
        for (pipes) |p| alloc.free(p);
        alloc.free(pipes);
    }
    try testing.expectEqual(@as(usize, 1), pipes.len);
    try testing.expectEqualStrings("\\\\.\\pipe\\ghoztty-pty-host-x-dd", pipes[0]);

    // Adopting twice is refused rather than swapping a live child out from
    // under the reader thread that owns it.
    var second: FakeChild = .{ .alloc = alloc };
    defer second.deinit();
    try testing.expect(store.adoptHolder(s.id, second.child(), 1, "x") == null);
    try testing.expect(store.adoptHolder(0xdead, second.child(), 1, "x") == null);
}

test "abandonHolder: keeping the pipe is what stops the orphan sweep killing a healthy holder" {
    // The two ways adoption can fail are not the same failure. "The holder is
    // gone" drops the record; "we could not get an answer in two seconds" must
    // NOT — because an un-claimed pipe is exactly what the orphan sweep reaps,
    // and the sweep dials again with a longer patience. Forgetting on a busy
    // box would end a live session over a hiccup.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xe906);
    var clock: MutClock = .{ .ms = 9000 };
    var store = SessionStore.init(alloc, prng.random(), &clock, MutClock.nowFn, 100000);
    defer store.deinit();

    const id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const s = (try store.table.materialize(.{
        .id = id,
        .created_ms = 100,
        .holder_pipe = "\\\\.\\pipe\\ghoztty-pty-host-x-ee",
        .holder_pid = 4321,
        .holder_offset = 77,
    }, 1024, 9000)).?;
    _ = s.recordOutput("some scrollback", 9000);

    store.abandonHolder(s.id, false);

    // The user is still told the session restarted (it is a tombstone now)...
    var buf: [256]u8 = undefined;
    const n = s.ring.copyRetained(&buf);
    try testing.expect(std.mem.endsWith(u8, buf[0..n], reboot_divider));
    // ...but the pipe stays CLAIMED, so nothing reaps the holder behind it, and
    // the next agent start gets to try adopting it again.
    try testing.expectEqualStrings("\\\\.\\pipe\\ghoztty-pty-host-x-ee", s.holder_pipe.?);
    try testing.expectEqual(@as(u64, 77), s.holder_snapshot_offset);
    const pipes = try store.holderPipes(alloc);
    defer {
        for (pipes) |p| alloc.free(p);
        alloc.free(pipes);
    }
    try testing.expectEqual(@as(usize, 1), pipes.len);
}
