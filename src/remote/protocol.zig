//! Wire protocol for the remote-machines feature (WP1).
//!
//! This module is **pure and dependency-free** (only `std`) so it can be unit
//! tested standalone with `zig test src/remote/protocol.zig` and shared verbatim
//! by the client (`src/remote/connection.zig`, WP3) and the agent
//! (`src/remote/agent/`, WP2). It defines:
//!
//!   - The versioned `HELLO` handshake (proto version / transfer encoding /
//!     capabilities) negotiated before any other frame (§4.2).
//!   - The binary frame header `len u32 BE | type u8 | channel u128 | seq u64 |
//!     payload` and every frame type from the §4.2 table.
//!   - Two independent sequence spaces (§4.2 "per m2"): a per-connection frame
//!     `seq` (loss/RTT detection) carried in the header, and a per-channel raw
//!     `byte_offset` carried in the `DATA` payload header (resync anchoring,
//!     §7.3).
//!   - The CR/LF-immune transfer encodings (COBS and base64) used on a Windows
//!     hop because `ssh-shellhost.exe` may mangle CR/LF (§4.2, Win32-OpenSSH#1256),
//!     each enforcing a hard cap on the *decoded* length so a tiny frame can't
//!     expand into an allocation bomb (§15 NEW-3).
//!   - A streaming `Reader` that handles partial/short socket reads and treats
//!     **all** inbound bytes as untrusted (§15 M3): every `len` is bound-checked,
//!     unknown frame types are rejected, and malformed transfer encodings error
//!     out rather than panic.
//!   - The JSON-RPC 2.0 envelope (§9.5) and `FLOW` primitives (§4.3/§4.4).
//!
//! What this module does NOT do: it does not validate channel/session *ownership*
//! (whether an inbound `channel` belongs to a session this client opened — that is
//! connection state, §15 M3) and it does not interpret terminal escapes (that is
//! the VT parser, §9.8). It only frames bytes and bounds them structurally.
//!
//! ## Compatibility history (the agent contract's version log)
//!
//! The `ghoztty-agent` outlives the app, so a running agent is frequently a
//! DIFFERENT build than the app talking to it (see docs/claude/sessions.md, "Agent contract &
//! upgrade compatibility"). Every wire evolution is therefore recorded here, so
//! the compatibility matrix is checkable in review rather than inferred from
//! `git log`. `proto_version` is bumped only for a BREAKING change; everything
//! below rides version 1 and is negotiated additively as a `capability` string
//! (see `capability` and `negotiate`).
//!
//! | Since | Capability | What it added | Absent ⇒ |
//! | --- | --- | --- | --- |
//! | v1 | `resync` | sequence-anchored resync + grid snapshot (§7.3) | no resync |
//! | v1 | `flow` | per-channel flow control (§4.3) | unbounded writes |
//! | v1 | `rpc` | JSON-RPC control plane (§9.5) | no in-pane RPC |
//! | v1 | `tunnel` | port-forward tunneling (§8) | no tunnels |
//! | v1 | `close_session` | `CLOSE_SESSION` 0x2c (kill by session id) | channel-scoped `close` only |
//! | v1 | `grid_snapshot` | visible-screen repaint appended on ATTACH | ring-only replay |
//! | v1 | `session_cpu` | pushed per-session CPU 0x79-0x7b | chooser shows no meter |
//! | v1 | `sessions_push` | pushed session roster 0x7c-0x7d | client polls `LIST_SESSIONS` |
//! | v1 | `cpu_units` | `cpu_pct` carries CORRECTED units everywhere | `% CPU` marked unverifiable |
//! | v1 | `session_busy` | pushed `META{has_descendants}` per session | close always confirms |
//! | v1 | `open_failed` | `OPEN_FAILED` 0x06 (refused OPEN, with a reason) | silence ⇒ client times out |
//! | v1 | `attach_failed` | `ATTACH_FAILED` 0x07 (ATTACH the agent cannot answer) | silence ⇒ client times out |
//! | v1 | `repaint_data` | `DATA_REPAINT` 0x15 (injected repaint, advances no offset) | repaint counted as stream bytes |
//!
//! Two rules make that table load-bearing rather than decorative:
//!
//!   1. **New capabilities only ever describe ADDITIVE behavior**, so an older
//!      peer that never advertises one degrades to the "Absent ⇒" column — never
//!      to garbled output, a wedged socket, or a crash.
//!   2. **A capability may also pin the MEANING of an existing field**, not just
//!      the existence of an opcode. `cpu_units` is the first of that kind: the
//!      field `Proc.cpu_pct` predates it, but its VALUE changed (macOS mach ticks
//!      were being read as nanoseconds, ~24× low on Apple Silicon), and a value
//!      that silently changes meaning is exactly what the contract forbids
//!      shipping ungated.
//!
//! Not everything additive needs a capability. An optional HELLO FIELD that
//! gates no opcode and changes no existing value's meaning is safe on its own,
//! because an older peer simply omits it and `ignore_unknown_fields` swallows it
//! in the other direction: `hostname`, `build_version` and `pty_flavor` (T471)
//! are all of that kind. Each states its "absent ⇒" on the field itself.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// The protocol version pinned by this build. Bumped on any incompatible wire
/// change. Negotiated in `HELLO`; a mismatch is fatal (drop the connection).
pub const proto_version: u16 = 1;

/// Fixed frame header size: `len u32 | type u8 | channel u128 | seq u64`.
///   4 (len) + 1 (type) + 16 (channel) + 8 (seq) = 29.
/// The `len` field counts the **entire** frame including itself, so a frame's
/// payload length is `len - header_len` (the §4.2 table's `payload [len-29]`).
pub const header_len: usize = 29;

/// Hard cap on a single frame's total on-wire (decoded) length. Generous enough
/// for a viewport snapshot redraw yet bounded so a hostile `len` (or a tiny
/// COBS/base64 frame that claims to decode huge) can never trigger an unbounded
/// allocation (§15 M3 / NEW-3). 16 MiB.
pub const max_frame_len: u32 = 16 * 1024 * 1024;

/// The control channel id. Control frames (`HELLO`, `PING`/`PONG`, `SIGNAL`,
/// `FLOW`, `RPC`, lifecycle) ride this channel — and, on the wire, the *separate*
/// control SSH channel (§4.3). Data channels use cryptographically-random UUIDs
/// (§7.1), so `0` can never collide with a session channel.
pub const control_channel: u128 = 0;

// -----------------------------------------------------------------------------
// Frame types (§4.2 table)
// -----------------------------------------------------------------------------

/// Every frame type from the §4.2 table.
///
/// Note: the design groups "PING/PONG" under a single opcode `0x50`. A single
/// type byte cannot encode both directions, so WP1 (which *pins* the contract)
/// splits them into `ping = 0x50` / `pong = 0x51`. This is the only refinement
/// of the table's opcodes and is documented here as the normative wire mapping.
pub const FrameType = enum(u8) {
    /// Handshake: `{proto_version, transfer_encoding, capabilities[]}`. Must be
    /// the first frame in each direction; negotiated before anything else.
    hello = 0x00,

    open = 0x01, // C→A  {cwd, command, shell, term, env, rows, cols, px_w, px_h, name}
    opened = 0x02, // A→C  {session_id, pid}
    attach = 0x03, // C→A  {session_id, rows, cols, last_byte_offset}
    attached = 0x04, // A→C  {status, rows, cols, cwd, title, snapshot_at_offset, exit_code?}
    detached = 0x05, // A→C  server-initiated eviction notice (steal, §5.3)

    // "I will not open this." The negative reply to `OPEN`, so a refusal is an
    // ANSWER rather than silence. Without it a refused OPEN produced no frame at
    // all and the client's parked `.opened` slot waited out the full
    // `rpc_open_timeout_ns` (10 s) before failing with a bare `error.Timeout` —
    // and because by-type OPEN RPCs serialize on one mutex, a window of N panes
    // paid that 10 s N times, in turn, for a pane that was never coming.
    //
    // Gated on `capability.open_failed`: a new opcode is a fatal framing error to
    // a peer that does not know it, so the agent sends this ONLY to a client that
    // advertised the string. An older client gets today's silence-then-timeout,
    // which is the graceful degradation the agent-contract rules ask for.
    open_failed = 0x06, // A→C  {reason, detail?}  OPEN refused; no session exists

    // "I cannot answer this ATTACH." The negative reply to `ATTACH`, for the
    // refusals `ATTACHED` has no way to express (T657).
    //
    // Note what this is NOT: `not_found`, `dead` and `attached_elsewhere` are
    // already complete, immediate answers carried by `ATTACHED.status` — a
    // second vocabulary for them would be two ways to say one thing across a
    // compatibility boundary, which is exactly what the agent contract asks us
    // not to build. This frame covers what the status enum cannot say at all:
    // a request the agent could not even parse, and any future hard refusal
    // (an attach cap, an internal error) where no `Attached` payload exists to
    // fill in. Those paths used to `return` in silence, so the client's parked
    // `.attached` slot waited out the full `rpc_open_timeout_ns` (10 s) and
    // then blamed `error.Timeout`.
    //
    // Gated on `capability.attach_failed`, for the same reason `open_failed`
    // is: an unknown opcode is a fatal framing error to a peer that does not
    // know it, so an older client gets today's silence-then-timeout instead.
    attach_failed = 0x07, // A→C  {reason, detail?}  ATTACH refused; nothing attached

    data = 0x10, // both {byte_offset, bytes} for `channel`
    resize = 0x11, // C→A  {rows, cols, px_w, px_h}
    signal = 0x12, // C→A  {name}
    detach = 0x13, // C→A  stop streaming; keep session alive
    close = 0x14, // C→A  terminate the session's container, free it

    // An INJECTED repaint: bytes to feed the terminal that are NOT part of the
    // session's byte stream. Same payload shape as `data` (`DataPayload`), and
    // the client renders it identically — what differs is the accounting: the
    // stream position after a repaint is its `byte_offset`, NOT
    // `byte_offset + bytes.len`.
    //
    // Why it has to be said on the wire (T739): the agent injects two such
    // frames on ATTACH — the `[N bytes of scrollback lost]` marker anchored at
    // the client's resume point, and the `grid_snapshot` repaint anchored at the
    // ring head S — and a repaint anchored at S is byte-for-byte
    // indistinguishable from the first LIVE frame at S. No arithmetic over
    // (anchor, length) can separate them, so a client that counts every byte it
    // is fed records a resume point PAST the agent's stream head by exactly the
    // repaint's size. The next attach is then clamped back to the head (T532)
    // and whatever real output sat between the two is never replayed.
    //
    // Gated on `capability.repaint_data`, for the same reason `open_failed` and
    // `attach_failed` are: an unknown opcode is a fatal framing error to a peer
    // that does not know it, so the agent sends this ONLY to a client that
    // advertised the string. Both skew directions degrade to exactly the
    // pre-T739 behavior (the injection rides plain `DATA` and is counted).
    data_repaint = 0x15, // A→C  {byte_offset, bytes} — repaint; advances no offset

    exit = 0x20, // A→C  {code, runtime_ms} (ordered after final DATA)
    meta = 0x21, // A→C  {cwd?, title?, listening_ports?, foreground_cmd?}

    get_cwd = 0x22, // C→A  {session_id}  on-demand "what is this session's cwd?"
    cwd = 0x23, // A→C  {session_id, path?, ok}  reply to GET_CWD

    list_sessions = 0x24, // C→A  {}  enumerate every session this agent owns
    sessions = 0x25, // A→C  {sessions:[SessionInfo]}  reply to LIST_SESSIONS

    relaunch = 0x26, // C→A  {session_id, rows, cols}  respawn a loaded/dead session
    relaunched = 0x27, // A→C  {session_id, ok, pid, found}  reply to RELAUNCH

    set_layout = 0x28, // C→A  {key, blob?, session_ids, delete}  store/remove a layout blob
    set_layout_result = 0x29, // A→C  {ok}  reply to SET_LAYOUT
    get_layouts = 0x2a, // C→A  {}  fetch every stored layout blob
    layouts = 0x2b, // A→C  {layouts:[{key, blob}]}  reply to GET_LAYOUTS

    close_session = 0x2c, // C→A  {session_id}  end a session BY ID (session-scoped CLOSE)
    close_session_result = 0x2d, // A→C  {session_id, ok, found}  reply to CLOSE_SESSION

    rpc = 0x30, // C→A  JSON-RPC 2.0 request (§9.5)
    rpc_result = 0x31, // A→C  JSON-RPC 2.0 response / subscription notification

    tunnel = 0x40, // C→A  {op, type, listen, dest, autostart}

    ping = 0x50, // both heartbeat (control channel only)
    pong = 0x51, // both heartbeat reply (carries timestamp_reply)

    flow = 0x60, // both {channel, op, n}

    // Remote machine activity monitor (host metrics + process control). Pushed on
    // the control channel; metrics is a server→client stream gated by a sub/unsub.
    proc_list = 0x70, // C→A  {sort?, limit?}
    proc_snapshot = 0x71, // A→C  {ok, host, procs, truncated}
    metrics_sub = 0x72, // C→A  {interval_ms}
    metrics = 0x73, // A→C  {host}  (pushed every interval until unsub)
    metrics_unsub = 0x74, // C→A  {}
    proc_kill = 0x75, // C→A  {pid, signal?}
    proc_kill_result = 0x76, // A→C  {pid, ok, error?}
    proc_spawn = 0x77, // C→A  {cmd, cwd?, detached?}
    proc_spawn_result = 0x78, // A→C  {ok, pid?, error?}

    // Per-session CPU roll-up. A server→client stream gated by a sub/unsub, like
    // `metrics` — and, like it, only sent when the `session_cpu` capability was
    // negotiated by BOTH peers (a new opcode is a fatal framing error to a peer
    // that does not know it).
    session_cpu_sub = 0x79, // C→A  {interval_ms}     — a HINT; the agent decides
    session_cpu = 0x7a, // A→C  {interval_ms, sessions[]}
    session_cpu_unsub = 0x7b, // C→A  {}

    // Pushed session roster. The client subscribes once and the agent sends a
    // `sessions` frame (the SAME payload `list_sessions` replies with) whenever
    // the roster actually changes — created, exited, closed, attached, detached.
    // Event-driven, not polled: the chooser previously re-ran `list_sessions`
    // every 2s and still showed stale rows, because a poll can only ever be as
    // fresh as its last tick and its completion can be lost. Gated on the
    // `sessions_push` capability (new opcodes are a fatal framing error to a
    // peer that does not know them).
    sessions_sub = 0x7c, // C→A  {}
    sessions_unsub = 0x7d, // C→A  {}
};

/// True for the frame types that ride the DATA lane (§4.3). Everything else
/// rides control.
///
/// This is the demux rule both muxes fold a single transport back into two
/// logical lanes with — `client_mux.pumpInput` and the agent's
/// `mux.pumpInput` — and it is ONE definition on purpose. It used to be spelled
/// `frame.type == .data` at each site, which meant adding a data-lane opcode
/// silently misrouted it: `data_repaint` (0x15) went to the CONTROL lane, where
/// the control reader ignores what it does not recognize, so the agent's grid
/// snapshot was dropped by the very client that had asked for it. Nothing
/// crashed and nothing logged — the pane just never got its repaint. Any new
/// data-lane opcode belongs here and nowhere else.
pub fn onDataLane(t: FrameType) bool {
    return switch (t) {
        .data, .data_repaint => true,
        else => false,
    };
}

// -----------------------------------------------------------------------------
// Transfer encoding (§4.2)
// -----------------------------------------------------------------------------

/// CR/LF-immunity strategy for the byte stream, pinned at handshake. A frame in
/// the wrong encoding is a protocol error (§4.2). POSIX hops default to `raw`
/// (frames are self-delimiting via the length prefix); a Windows hop defaults to
/// `cobs`/`base64` because `ssh-shellhost.exe` can mangle CR/LF (#1256).
pub const TransferEncoding = enum {
    /// No wrapping — frames are delimited solely by their length prefix.
    raw,
    /// Consistent Overhead Byte Stuffing: removes all `0x00` from the body and
    /// uses a single `0x00` as the inter-frame delimiter (low overhead, binary).
    cobs,
    /// Base64 (standard alphabet) with a `\n` inter-frame delimiter. Larger but
    /// trivially CR/LF-safe and human-inspectable.
    base64,
};

// -----------------------------------------------------------------------------
// Errors
// -----------------------------------------------------------------------------

/// Errors a hostile or buggy peer can provoke. None of these should ever panic;
/// the connection layer drops the link on any of them.
pub const ProtocolError = error{
    /// `len` < `header_len` (frame can't even hold its own header).
    FrameTooSmall,
    /// `len` > `max_frame_len`, or a transfer-decoded frame exceeds the cap.
    FrameTooLarge,
    /// The type byte is not a known `FrameType`.
    UnknownType,
    /// A transfer-encoded block was structurally invalid (internal `0x00` in a
    /// COBS block, truncated COBS group, or invalid base64).
    MalformedEncoding,
    /// A typed payload (DATA/FLOW/JSON) was shorter than its fixed header or
    /// otherwise didn't parse.
    MalformedPayload,
    /// HELLO negotiation failed (version or encoding mismatch).
    Incompatible,
};

/// `Reader` operations can also fail to allocate while buffering, so its result
/// set is the protocol errors plus `Allocator.Error`.
pub const ReadError = ProtocolError || Allocator.Error;

// -----------------------------------------------------------------------------
// Sequence spaces (§4.2)
// -----------------------------------------------------------------------------

/// Per-connection frame sequence counter (the header `seq`). Drives loss/RTT
/// detection (§6.4); **resets per SSH connection** (a fresh counter each connect).
/// Monotonic, wrapping (a connection will never realistically reach 2^64 frames).
pub const FrameSeq = struct {
    value: u64 = 0,

    /// Return the next sequence number and advance.
    pub fn next(self: *FrameSeq) u64 {
        const v = self.value;
        self.value +%= 1;
        return v;
    }
};

/// Per-channel raw byte offset (the `DATA` payload header). Counts raw decoded
/// child-output bytes (post-transfer-decode, pre-terminal-parse) so it is stable
/// across reconnects where the transfer encoding may differ per hop (§4.2). The
/// agent **persists it across reconnects**; the client uses it to discard
/// already-applied `DATA` after a snapshot (§7.3).
pub const ByteOffset = struct {
    value: u64 = 0,

    /// Reserve `n` bytes and return the offset of the **first** byte of the
    /// chunk (the value carried in its `DATA` frame). Advances by `n`.
    pub fn advance(self: *ByteOffset, n: usize) u64 {
        const start = self.value;
        self.value +%= n;
        return start;
    }
};

// -----------------------------------------------------------------------------
// Frame (binary header + opaque payload)
// -----------------------------------------------------------------------------

/// A single decoded frame. `payload` is opaque at this layer — typed accessors
/// (`DataPayload`, `Flow`, the JSON payload structs) interpret it.
///
/// IMPORTANT: when produced by `Reader.next`, `payload` borrows reader-internal
/// storage and is only valid until the next call to `Reader.push`/`Reader.next`.
/// Copy it out if you need to retain it.
pub const Frame = struct {
    type: FrameType,
    channel: u128,
    seq: u64,
    payload: []const u8,

    /// Total encoded (binary, pre-transfer-encoding) length of a frame with a
    /// payload of `payload_len` bytes.
    pub fn encodedLen(payload_len: usize) usize {
        return header_len + payload_len;
    }

    /// Encode the binary frame (header + payload) into `dst`, which must be at
    /// least `encodedLen(payload.len)`. Returns the written slice. This is the
    /// pre-transfer-encoding form; use `writeFrame` to additionally COBS/base64
    /// wrap it for the wire.
    pub fn encodeInto(self: Frame, dst: []u8) []u8 {
        const total = header_len + self.payload.len;
        assert(dst.len >= total);
        assert(total <= max_frame_len);
        std.mem.writeInt(u32, dst[0..4], @intCast(total), .big);
        dst[4] = @intFromEnum(self.type);
        std.mem.writeInt(u128, dst[5..21], self.channel, .big);
        std.mem.writeInt(u64, dst[21..29], self.seq, .big);
        @memcpy(dst[header_len..][0..self.payload.len], self.payload);
        return dst[0..total];
    }

    /// Decode a frame from `buf`, which must contain at least one complete frame
    /// starting at offset 0. `buf` may be longer (trailing bytes are ignored;
    /// the caller advances by `len`). The returned `payload` borrows `buf`.
    pub fn decode(buf: []const u8) ProtocolError!Frame {
        if (buf.len < 4) return error.MalformedPayload; // can't read len
        const total = std.mem.readInt(u32, buf[0..4], .big);
        if (total < header_len) return error.FrameTooSmall;
        if (total > max_frame_len) return error.FrameTooLarge;
        if (buf.len < total) return error.MalformedPayload; // caller must buffer more
        const ft = std.meta.intToEnum(FrameType, buf[4]) catch
            return error.UnknownType;
        return .{
            .type = ft,
            .channel = std.mem.readInt(u128, buf[5..21], .big),
            .seq = std.mem.readInt(u64, buf[21..29], .big),
            .payload = buf[header_len..total],
        };
    }
};

// -----------------------------------------------------------------------------
// DATA payload (binary header: byte_offset u64 BE, then raw bytes)
// -----------------------------------------------------------------------------

/// The `DATA` (0x10) payload: an 8-byte big-endian `byte_offset` header (§4.2)
/// followed by the raw child-output bytes for the frame's `channel`.
pub const DataPayload = struct {
    /// Offset of the first byte of `bytes` in the channel's raw output stream.
    byte_offset: u64,
    /// The raw, byte-transparent child output (keys, mouse, SGR, etc. flow
    /// through unmodified — §6.5).
    bytes: []const u8,

    pub const header = 8;

    pub fn encodedLen(bytes_len: usize) usize {
        return header + bytes_len;
    }

    /// Encode into `dst` (≥ `encodedLen(bytes.len)`); returns the written slice.
    pub fn encodeInto(self: DataPayload, dst: []u8) []u8 {
        const total = header + self.bytes.len;
        assert(dst.len >= total);
        std.mem.writeInt(u64, dst[0..8], self.byte_offset, .big);
        @memcpy(dst[header..][0..self.bytes.len], self.bytes);
        return dst[0..total];
    }

    /// Parse from a `DATA` frame's payload. `bytes` borrows `payload`.
    pub fn decode(payload: []const u8) ProtocolError!DataPayload {
        if (payload.len < header) return error.MalformedPayload;
        return .{
            .byte_offset = std.mem.readInt(u64, payload[0..8], .big),
            .bytes = payload[header..],
        };
    }
};

// -----------------------------------------------------------------------------
// FLOW payload (binary: op u8, channel u128 BE, n u32 BE) — §4.3/§4.4
// -----------------------------------------------------------------------------

/// FLOW operation. `pause`/`resume` are the v1 ring backpressure primitives
/// (§3.4/§4.3); `credit` is reserved for the v2 WAN credit-window scheme (§4.3).
pub const FlowOp = enum(u8) {
    pause = 0,
    @"resume" = 1,
    credit = 2,
};

/// The `FLOW` (0x60) payload. The frame header's `channel` is the control
/// channel; the *target* channel being paused/resumed/credited is here in the
/// payload (§4.2 table: `{channel, op, n}`).
pub const Flow = struct {
    channel: u128,
    op: FlowOp,
    /// Credit amount for `credit`; unused (0) for `pause`/`resume`.
    n: u32 = 0,

    pub const encoded_len = 1 + 16 + 4; // op + channel + n

    pub fn encodeInto(self: Flow, dst: []u8) []u8 {
        assert(dst.len >= encoded_len);
        dst[0] = @intFromEnum(self.op);
        std.mem.writeInt(u128, dst[1..17], self.channel, .big);
        std.mem.writeInt(u32, dst[17..21], self.n, .big);
        return dst[0..encoded_len];
    }

    pub fn decode(payload: []const u8) ProtocolError!Flow {
        if (payload.len < encoded_len) return error.MalformedPayload;
        const op = std.meta.intToEnum(FlowOp, payload[0]) catch
            return error.MalformedPayload;
        return .{
            .op = op,
            .channel = std.mem.readInt(u128, payload[1..17], .big),
            .n = std.mem.readInt(u32, payload[17..21], .big),
        };
    }
};

// -----------------------------------------------------------------------------
// HELLO handshake (§4.2) — JSON payload
// -----------------------------------------------------------------------------

/// Capability strings advertised in `HELLO`. Kept as plain strings (not a bitset)
/// so a newer peer can advertise capabilities an older peer simply ignores.
pub const capability = struct {
    /// Sequence-anchored resync + grid snapshot (§7.3) supported.
    pub const resync = "resync";
    /// Per-channel flow control / backpressure (§4.3) supported.
    pub const flow = "flow";
    /// JSON-RPC control plane (§9.5) supported.
    pub const rpc = "rpc";
    /// Port-forward tunneling (§8) supported.
    pub const tunnel = "tunnel";
    /// Session-scoped `CLOSE_SESSION` (0x2c) — end a session BY SESSION ID even
    /// when no local pane is attached to it (the chooser's "Kill" action). Gated:
    /// a peer sends the `close_session` opcode ONLY when the other side advertised
    /// this string (an unknown opcode is a fatal framing error), so an older peer
    /// that omits it keeps working over the channel-scoped `close` alone.
    pub const close_session = "close_session";

    /// Pushed per-session CPU roll-up (`session_cpu_sub`/`session_cpu`/
    /// `session_cpu_unsub`, 0x79–0x7b): the agent reports each session's CPU%
    /// summed over its WHOLE process tree, so the chooser can show a runaway
    /// agent at a glance without pulling the entire process table.
    ///
    /// Gated because these are NEW OPCODES, not new fields — an older peer treats
    /// an unknown opcode as a fatal framing error, so the client must not send
    /// `session_cpu_sub` unless the agent advertised this string. When it is
    /// absent the chooser simply shows no meter (reduced function, never a wrong
    /// number and never a fallback poll the agent did not consent to).
    pub const session_cpu = "session_cpu";

    /// Pushed session roster (`sessions_sub`/`sessions_unsub`, 0x7c-0x7d; the
    /// agent replies on the existing `sessions` frame). The agent pushes the
    /// roster whenever it CHANGES, so a viewer never has to poll and can never
    /// show a session that has already exited.
    ///
    /// Gated because these are new opcodes. Without it the client falls back to
    /// its `list_sessions` poll, which still works — just less promptly.
    pub const sessions_push = "sessions_push";

    /// Re-attach **grid snapshot**: on ATTACH the agent, having tracked each
    /// session's visible screen in a headless emulator, replays a self-contained
    /// VT repaint of the current on-screen grid so the pane repaints EXACTLY and
    /// is never blank — even when the paint predates the raw-output ring (deep
    /// scrollback evicted, or a full-screen app whose alt-screen enter scrolled
    /// out). See `src/remote/agent/grid_snapshot.zig`.
    ///
    /// Purely additive — there is NO new opcode: the snapshot rides ordinary
    /// `DATA` frames (plain VT any emulator renders). This string only lets the
    /// two sides NEGOTIATE the behavior:
    ///   * the CLIENT advertises it to say "append a grid snapshot after your
    ///     replay"; a client that doesn't (older app) gets today's ring-only
    ///     replay,
    ///   * the AGENT advertises it so a new client knows an old agent (which
    ///     never sends one) will fall back to ring-only replay.
    /// Gated on the INTERSECTION (`Negotiated.grid_snapshot`), so every skew
    /// combination degrades gracefully to today's behavior — no garble, no wedge.
    pub const grid_snapshot = "grid_snapshot";

    /// Every `cpu_pct` this peer reports is in CORRECTED units.
    ///
    /// Unlike every capability above, this one gates no opcode and no field. It
    /// pins the MEANING of a field that already existed: `Proc.cpu_pct` in
    /// `PROC_SNAPSHOT`, and the same quantity in the `session_cpu` stream.
    ///
    /// The macOS sampler used to hand `pti_total_user`/`pti_total_system` to
    /// `cpuForPid` as if they were nanoseconds. They are mach absolute time
    /// units, so on an Apple Silicon box (timebase 125/3 ⇒ 41.67 ns/tick) every
    /// per-process percentage came out ~24× low; on Intel the timebase is 1:1,
    /// which is why it went unnoticed. `src/remote/agent/proc.zig` now converts
    /// through `mach_timebase_info`, matching what Linux (jiffies → ns) and
    /// Windows (100 ns FILETIME → ns) always did.
    ///
    /// That fix is AGENT-side, and an agent outlives the app that talks to it —
    /// so a new app can find itself reading a pre-fix agent's `cpu_pct` and has
    /// no way to tell from the number alone. This string is how it tells: an
    /// agent that advertises it guarantees corrected units; one that does not
    /// might be reporting ~24× low, and the app marks the column unverifiable
    /// rather than rendering a possibly-wrong number as fact.
    ///
    /// It deliberately does NOT let the app rescale: the app cannot know the
    /// remote machine's mach timebase, and assuming 125/3 would be wrong on an
    /// Intel remote (and on a Linux/Windows agent, whose numbers were always
    /// right). Reduced function, never invented data.
    ///
    /// Note that `session_cpu` implies this: the pushed CPU stream was added
    /// AFTER the units fix in the same change set, so no agent can advertise
    /// `session_cpu` without also having corrected units. The chooser's session
    /// meter therefore needs no separate gate; the Activity Monitor's process
    /// table, whose `cpu_pct` predates both, is what this exists for.
    pub const cpu_units = "cpu_units";

    /// Live "is anything running in this session's shell?" reporting: the agent
    /// samples each bound session's process subtree and pushes
    /// `META{has_descendants}` whenever the answer CHANGES (T356).
    ///
    /// What it is for: the close confirmation. A pane whose shell sits at an
    /// idle prompt has nothing to lose, so closing it should not ask — which on
    /// Windows is decided by walking the process table (`ProcessTree`,
    /// T41), because cmd.exe and stock PowerShell emit no OSC 133 marks for the
    /// core's `cursorIsAtPrompt` to read. A CROSS-MACHINE pane's shell is not in
    /// this box's process table at all, so the only machine that can answer is
    /// the one running it.
    ///
    /// PUSHED, not asked on demand, because `Surface.close` is a synchronous
    /// GUI-thread path that puts up a modal: a round-trip there would block the
    /// close behind the link, and a half-dead link would stall it (see D37).
    /// The client reads the last pushed value instantly and treats "never
    /// reported" and "link not connected" alike as UNKNOWN, i.e. confirm — the
    /// pre-T356 behavior.
    ///
    /// Gated even though `has_descendants` is an additive optional FIELD on an
    /// existing opcode (which would need no gate to be safe), because the gate
    /// buys something the field alone cannot: the sampling costs a process-table
    /// walk per tick, and the agent should only pay it when a peer that will
    /// actually consume the answer is attached. `bindLocked` installs the
    /// push bridge only for a negotiated connection, so an agent whose clients
    /// are all older does no work at all.
    ///
    /// Skew is safe in both directions: an older agent never sends the field
    /// (client stays at confirm-always for remote panes), and an older client
    /// ignores an unknown JSON field.
    pub const session_busy = "session_busy";

    /// Negative reply to `OPEN` (`open_failed`, 0x06): when the agent will not
    /// open a session it says so, immediately, with a reason — instead of
    /// dropping the request on the floor and letting the client's parked RPC
    /// discover it 10 s later as `error.Timeout`.
    ///
    /// Gated because this is a NEW OPCODE, and an unknown opcode is a fatal
    /// framing error for the receiver — so the agent must not emit it unless the
    /// client advertised this string. Skew degrades exactly to today's behavior
    /// in both directions: a new agent stays silent for an old client (which
    /// times out as it always did), and a new client never receives the frame
    /// from an old agent (same timeout). Neither garbles nor wedges.
    ///
    /// What the client does with it is the whole point: it fails the OPEN in
    /// milliseconds and paints the reason into the pane, so a refused pane says
    /// "the background terminal service is at its session limit" rather than
    /// coming up blank and then blaming a timeout.
    pub const open_failed = "open_failed";

    /// Negative reply to `ATTACH` (`attach_failed`, 0x07) for the refusals
    /// `ATTACHED.status` cannot express — today a payload the agent could not
    /// parse, tomorrow any hard refusal with no `Attached` to fill in. Those
    /// paths dropped the request on the floor, so the client discovered them
    /// 10 s later as `error.Timeout`.
    ///
    /// Deliberately NOT a re-statement of `not_found`/`dead`/
    /// `attached_elsewhere`: those already ride `ATTACHED` and arrive at once.
    /// What the user sees for THEM is a client-side mapping of that status
    /// (`termio/attach_failed_notice.zig`), which needs no wire change and so
    /// works against an agent of any age.
    ///
    /// Gated because this is a NEW OPCODE and an unknown opcode is a fatal
    /// framing error for the receiver. Skew degrades to today's behavior in
    /// both directions: a new agent stays silent for an old client, and a new
    /// client never receives the frame from an old agent. Neither garbles nor
    /// wedges.
    pub const attach_failed = "attach_failed";

    /// Injected repaints are FRAMED as repaints (`DATA_REPAINT`, 0x15) instead of
    /// riding ordinary `DATA`, so the client can feed them to the terminal
    /// without counting them as stream bytes (T739).
    ///
    /// What it fixes: `Remote.appliedOffset()` is the resume point persisted for
    /// the next re-attach, and it used to be "every byte we fed the parser". Two
    /// of the things the agent sends on ATTACH are not stream bytes — the
    /// scrollback-lost marker and the `grid_snapshot` repaint — so every
    /// re-attach recorded a point PAST the agent's head by their size, the next
    /// attach was clamped back to the head, and the real output in between was
    /// skipped. On a quiet pane that is invisible (the repaint covers it); on a
    /// busy one it is silently lost output.
    ///
    /// It cannot be a client-side inference: the repaint is anchored at the ring
    /// head S and so is the first live frame after it, which makes them
    /// identical on the wire. Only the sender knows.
    ///
    /// Gated because 0x15 is a NEW OPCODE and an unknown opcode is a fatal
    /// framing error for the receiver. Skew degrades to exactly today's
    /// behavior in both directions: a new agent sends plain `DATA` to an old
    /// client (which over-counts as it always did, and the T532 clamp keeps it
    /// safe), and a new client never sees 0x15 from an old agent. Neither
    /// garbles nor wedges.
    pub const repaint_data = "repaint_data";

    /// **Non-destructive agent upgrade** (T907): this peer understands that a
    /// stale agent replaces ITSELF — spawning the newer on-disk build, handing
    /// the per-session PTY holders over to it, and exiting only once the
    /// successor has reported READY — so no session is lost and nobody is asked.
    ///
    /// Advertised by the AGENT to mean "I will do this when a newer build lands
    /// beside me and every live session is holder-backed", and by the CLIENT to
    /// mean "I know that, so I will not restart you destructively for being
    /// stale". The INTERSECTION is what matters, which is why both sides say it:
    /// an older app talking to a handoff-capable agent must keep its existing
    /// behavior (refresh at idle, confirm while live), because standing down on
    /// a promise it cannot hear about would leave the agent stale forever from
    /// its point of view.
    ///
    /// Purely additive — no new opcode and no new required field. It gates a
    /// POLICY (`apprt/win32/agent_upgrade.zig`), and the per-session
    /// `SessionInfo.holder_backed` flag is what turns the promise into a
    /// live answer: an agent can only hand off once nothing legacy is left.
    /// Skew degrades in both directions to exactly the pre-T907 behavior.
    pub const agent_handoff = "agent_handoff";
};

/// The kind of pseudo-terminal a peer spawns its children on. Wire-visible
/// (`Hello.pty_flavor`) because it is the ONE thing about the far machine the
/// near side cannot infer: a pane's terminal behaviour depends on the child's
/// pty, and on a cross-OS remote pane that is not the local OS's (T471).
///
/// What it decides today: `termio/history_guard.zig`. A ConPTY child repaints
/// its whole viewport after every resize, so rows a resize drags out of
/// scrollback are erased — the guard that stops that must be armed for a ConPTY
/// child and left off for a POSIX one, whichever machine the WINDOW is on.
///
/// Deliberately a plain enum with a string encoding and no capability gate: it
/// is an additive optional FIELD (an older peer omits it and the reader falls
/// back to the local OS's flavour, which is exactly the pre-T471 behaviour), and
/// it gates no opcode, so there is nothing an older peer could choke on.
pub const PtyFlavor = enum {
    /// Windows ConPTY: conhost owns the viewport and repaints all of it after a
    /// resize, opening with `ESC[H ESC[2J`.
    conpty,
    /// A POSIX pty: the child gets `SIGWINCH` and repaints nothing on its own.
    posix,

    /// The flavour of pty THIS build spawns children on. The single derivation
    /// of that fact: an agent advertises it, a client advertises it, and
    /// `termio/history_guard.zig` falls back to it for a peer that reports
    /// none. (`builtin` is compiler-provided, so naming it here keeps this
    /// module standalone-testable.)
    pub const local: PtyFlavor = if (builtin.os.tag == .windows) .conpty else .posix;

    /// The wire spelling. Stable — this string is the protocol.
    pub fn toString(self: PtyFlavor) []const u8 {
        return @tagName(self);
    }

    /// Parse a wire spelling, or null for anything this build does not know.
    /// Unknown is NOT an error: a future peer may name a third flavour, and the
    /// contract is that we degrade to our own default rather than drop a
    /// connection over a field that only tunes a guard.
    pub fn fromString(s: []const u8) ?PtyFlavor {
        return std.meta.stringToEnum(PtyFlavor, s);
    }
};

/// The `HELLO` (0x00) payload, serialized as JSON so it is forward-compatible
/// (unknown fields ignored). Sent first in each direction; the connection layer
/// negotiates the intersection before any other frame (§4.2).
pub const Hello = struct {
    proto_version: u16 = proto_version,
    transfer_encoding: TransferEncoding,
    capabilities: []const []const u8 = &.{},
    /// The sender's machine hostname, for display (e.g. the client's window
    /// pill). Optional: absent from older peers, and never load-bearing.
    hostname: ?[]const u8 = null,

    /// The sender's build stamp ("YYYYMMDD-<git short hash>", the same string the
    /// agent bakes as `agent_build_options.agent_version` and prints for
    /// `--version`). Set by the AGENT so the app can detect at runtime that the
    /// running agent is a different build than the one it bundles and lazily
    /// refresh it (non-destructive agent upgrade). Additive/optional: older peers
    /// omit it and readers must tolerate its absence — never a parse error.
    /// Never load-bearing for the protocol itself.
    ///
    /// Absent ⇒ null, and the win32 policy (`agent_upgrade.isStale`) reads that
    /// as **STALE**, not as "unknown, leave alone": a peer too old to advertise
    /// a stamp necessarily predates the feature, so it is by definition an
    /// older build than any app that knows to look for one. (This comment used
    /// to claim the opposite — "never treated as stale" — which contradicted
    /// the code it describes; T201.)
    build_version: ?[]const u8 = null,

    /// The pty flavour this peer spawns children on (`PtyFlavor.toString`), or
    /// null from a peer too old to say. Set by the AGENT, whose children are the
    /// ones whose repaint behaviour matters; the client sets it too, so the
    /// field means the same thing in both directions and a future agent could
    /// read it.
    ///
    /// Additive/optional: absent ⇒ null, and the reader falls back to the LOCAL
    /// machine's flavour — the pre-T471 derivation, so an old agent behaves
    /// exactly as it did. A string rather than an enum so an unknown future
    /// spelling parses (to null) instead of failing the whole HELLO.
    pty_flavor: ?[]const u8 = null,

    /// The peer's pty flavour as a value, or null when it did not say (or named
    /// one this build does not know). Callers own the fallback — see
    /// `termio/history_guard.zig`, which reads null as "assume this machine's".
    pub fn ptyFlavor(self: Hello) ?PtyFlavor {
        return PtyFlavor.fromString(self.pty_flavor orelse return null);
    }

    /// Serialize to a JSON byte slice owned by `alloc`. Null optionals are
    /// elided rather than emitted as `"field":null`, matching every other
    /// encoder here, so a HELLO that sets none of them is byte-identical to
    /// one from a peer built before the field existed (the additive-field
    /// contract the tests pin).
    pub fn encode(self: Hello, alloc: Allocator) Allocator.Error![]u8 {
        return std.json.Stringify.valueAlloc(alloc, self, .{
            .emit_null_optional_fields = false,
        });
    }

    /// Parse a `HELLO` payload. The returned `Parsed` owns its backing memory;
    /// call `.deinit()` when done.
    pub fn parse(alloc: Allocator, json: []const u8) !std.json.Parsed(Hello) {
        return std.json.parseFromSlice(Hello, alloc, json, .{
            .ignore_unknown_fields = true,
        });
    }
};

/// The negotiated, agreed-upon parameters after exchanging `HELLO`s.
pub const Negotiated = struct {
    proto_version: u16,
    transfer_encoding: TransferEncoding,
    /// True iff BOTH peers advertised `capability.close_session` in their HELLO —
    /// i.e. the session-scoped `close_session` RPC is safe to send. Additive: an
    /// older peer that never advertises it leaves this false, so the app keeps
    /// using the channel-scoped `close` and never emits an opcode the peer would
    /// treat as a fatal framing error.
    close_session: bool = false,

    /// True iff BOTH peers advertised `capability.grid_snapshot` — i.e. the agent
    /// should append a grid-snapshot repaint on ATTACH and the client wants it.
    /// Additive: false against any older peer, so the agent falls back to today's
    /// ring-only replay and the client just renders whatever DATA arrives.
    grid_snapshot: bool = false,

    /// True iff BOTH peers advertised `capability.session_cpu` — i.e. the pushed
    /// per-session CPU stream (0x79-0x7b) is safe to use. False against any older
    /// peer, in which case the client never sends `session_cpu_sub` (an unknown
    /// opcode would be a fatal framing error) and the chooser shows no meter.
    session_cpu: bool = false,

    /// True iff BOTH peers advertised `capability.sessions_push` — the agent
    /// will push the roster on every change instead of the client polling.
    /// False against an older peer, which keeps the poll.
    sessions_push: bool = false,

    /// True iff BOTH peers advertised `capability.cpu_units` — i.e. the peer's
    /// `cpu_pct` values are in corrected units and may be rendered as fact.
    ///
    /// The load-bearing half is the AGENT's advertisement (the app consumes
    /// `cpu_pct`, it does not produce it), but this stays an intersection like
    /// every other flag so `negotiate`'s contract has no exception: the app also
    /// advertises the string, which costs nothing and means a future agent could
    /// learn that the client understands corrected units. False against a pre-fix
    /// agent, in which case the Activity Monitor marks its `% CPU` column
    /// unverifiable instead of printing a possibly-24×-low number.
    cpu_units: bool = false,

    /// True iff BOTH peers advertised `capability.session_busy` — the agent
    /// samples each bound session's process subtree and pushes
    /// `META{has_descendants}` on change, and the client wants it for the close
    /// confirmation (T356). False against any older peer, in which case the
    /// agent installs no sampling bridge (and does no walk) and the client keeps
    /// confirming every cross-machine close.
    session_busy: bool = false,

    /// True iff BOTH peers advertised `capability.open_failed` — the agent
    /// answers a refused `OPEN` with `open_failed{reason, detail}` and the
    /// client understands it. False against any older peer, in which case the
    /// agent stays silent (it must never emit an opcode the peer would treat as
    /// a fatal framing error) and the client falls back to its 10 s timeout.
    open_failed: bool = false,

    /// True iff BOTH peers advertised `capability.attach_failed` — the agent
    /// answers an unanswerable `ATTACH` with `attach_failed{reason, detail}`
    /// and the client understands it. False against any older peer, in which
    /// case the agent stays silent (it must never emit an opcode the peer
    /// would treat as a fatal framing error) and the client falls back to its
    /// 10 s timeout, exactly as before.
    attach_failed: bool = false,

    /// True iff BOTH peers advertised `capability.repaint_data` — the agent
    /// frames an injected repaint as `data_repaint` (0x15) and the client knows
    /// not to count its bytes as stream position (T739). False against any older
    /// peer, in which case the agent sends the repaint as plain `DATA` (it must
    /// never emit an opcode the peer would treat as a fatal framing error) and
    /// the client over-counts by the repaint's size, exactly as before.
    repaint_data: bool = false,

    /// True iff BOTH peers advertised `capability.agent_handoff` — the agent
    /// replaces itself non-destructively when a newer build lands beside it, and
    /// the client knows to stand down rather than restart it (T907). False
    /// against any older peer on either side, in which case the client keeps its
    /// pre-T907 policy (refresh at idle, confirm while live) — reduced function,
    /// never a lost session.
    agent_handoff: bool = false,
};

/// True iff `caps` contains the capability string `name`.
fn hasCapability(caps: []const []const u8, name: []const u8) bool {
    for (caps) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

/// Negotiate the local and remote `HELLO`s. v1 policy is strict: both sides must
/// agree on the exact `proto_version` and `transfer_encoding` (the encoding is
/// chosen by the side that knows the hop is a Windows hop and proposed in its
/// `HELLO`; the other side echoes it). A mismatch is fatal (§4.2 "mismatch → drop").
///
/// Capabilities evolve additively ON TOP of the pinned `proto_version`: each
/// negotiated capability flag is the INTERSECTION of both peers' advertised
/// capability strings, so a behavior is only enabled when both sides support it.
pub fn negotiate(local: Hello, remote: Hello) ProtocolError!Negotiated {
    if (local.proto_version != remote.proto_version) return error.Incompatible;
    if (local.transfer_encoding != remote.transfer_encoding) return error.Incompatible;
    return .{
        .proto_version = local.proto_version,
        .transfer_encoding = local.transfer_encoding,
        .close_session = hasCapability(local.capabilities, capability.close_session) and
            hasCapability(remote.capabilities, capability.close_session),
        .grid_snapshot = hasCapability(local.capabilities, capability.grid_snapshot) and
            hasCapability(remote.capabilities, capability.grid_snapshot),
        .session_cpu = hasCapability(local.capabilities, capability.session_cpu) and
            hasCapability(remote.capabilities, capability.session_cpu),
        .sessions_push = hasCapability(local.capabilities, capability.sessions_push) and
            hasCapability(remote.capabilities, capability.sessions_push),
        .cpu_units = hasCapability(local.capabilities, capability.cpu_units) and
            hasCapability(remote.capabilities, capability.cpu_units),
        .session_busy = hasCapability(local.capabilities, capability.session_busy) and
            hasCapability(remote.capabilities, capability.session_busy),
        .open_failed = hasCapability(local.capabilities, capability.open_failed) and
            hasCapability(remote.capabilities, capability.open_failed),
        .attach_failed = hasCapability(local.capabilities, capability.attach_failed) and
            hasCapability(remote.capabilities, capability.attach_failed),
        .repaint_data = hasCapability(local.capabilities, capability.repaint_data) and
            hasCapability(remote.capabilities, capability.repaint_data),
        .agent_handoff = hasCapability(local.capabilities, capability.agent_handoff) and
            hasCapability(remote.capabilities, capability.agent_handoff),
    };
}

// -----------------------------------------------------------------------------
// Control-frame JSON payloads (§4.2 table). Documented + round-tripped so the
// agent and client agree on field names. Hot-path frames (DATA, FLOW) stay
// binary above; lifecycle/metadata frames are JSON for evolvability.
// -----------------------------------------------------------------------------

/// `OPEN` (0x01). `env` is an allowlist (incl. TERM/LANG/LC_*, §4.2/§6.5).
pub const Open = struct {
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    term: []const u8 = "xterm-ghostty",
    env: []const EnvPair = &.{},
    rows: u16,
    cols: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,
    name: ?[]const u8 = null,

    /// Explicit shell argv to exec VERBATIM instead of the agent's synthesized
    /// `<shell> -lic/-li <command>` convention (§ local shell integration, T04c).
    /// Carries the argv-rewrite that `shell_integration.setup()` produces for
    /// shells that need one (bash → `<shell> --posix`, nushell → `<shell>
    /// --execute 'use ghostty *'`, powershell → `<shell> -NoExit -Command
    /// . '…ghostty.ps1'`, T27/T151) so an agent-backed local pane running those
    /// shells activates ghostty integration (prompt marks / OSC 7 / title) —
    /// env-only shells (zsh/fish/elvish) never set this (their integration rides
    /// `OPEN.env` alone). Set ONLY by the LOCAL-agent client for a plain
    /// interactive shell (no user `command`); a cross-machine window leaves it
    /// null. When present and non-empty the agent execs it as-is — POSIX uses
    /// its own resolved shell path as the binary with this array as argv;
    /// Windows builds the ConPTY command line from this array (argv[0] resolves
    /// through the standard program search) — when null the agent keeps its
    /// per-OS default synthesis. Additive/optional: older agents ignore the
    /// field (unknown-field-tolerant parser) and fall back to the default
    /// invocation (a pre-T151 Windows agent additionally ignored a present
    /// argv, degrading to no shell integration). `argv[0]` is conventionally
    /// the shell path.
    argv: ?[]const []const u8 = null,

    /// Pin this session so the agent's idle-TTL reaper NEVER evicts it while
    /// orphaned (§7.1, T11). The LOCAL-agent client sets this for every
    /// persistent local pane: the viewer's session-layout manifest (T05)
    /// references the session, so it must survive the viewer quitting until a
    /// restore re-ATTACHes it — a 24 h idle-TTL would still reap an overnight
    /// laptop-closed session before the next launch. Cross-machine windows leave
    /// it false and keep the idle-TTL. Additive/optional: older agents ignore
    /// the field (unknown-field-tolerant parser) and fall back to TTL reaping.
    pinned: bool = false,

    pub const EnvPair = struct { key: []const u8, value: []const u8 };
};

/// `OPENED` (0x02).
pub const Opened = struct {
    session_id: []const u8,
    pid: i64,

    /// The PTY slave path of the spawned child ON THE AGENT'S MACHINE (e.g.
    /// `/dev/ttys014`), so a viewer pane can answer `getProcessInfo(.tty_name)`
    /// (the `+list --tty` self-lookup path). POSIX agents report it; the Windows
    /// ConPTY agent has no tty name and leaves it null. Additive/optional:
    /// older agents omit it (unknown-field-tolerant parser → null) and the
    /// client degrades to its pre-field behavior (no tty).
    tty: ?[]const u8 = null,
};

/// `OPEN_FAILED` (0x06) — the negative reply to `OPEN`. Sent ONLY when
/// `Negotiated.open_failed` (a new opcode is a fatal framing error to a peer
/// that does not know it); an older client sees today's silence and times out.
///
/// No `session_id`: nothing was created, which is the entire message. The
/// session that would have existed does not, so there is nothing to close,
/// attach to, or retry against.
pub const OpenFailed = struct {
    /// A STABLE MACHINE TOKEN from `reason` below, never prose. The client maps
    /// it to the sentence a user reads, so the wording can be improved on the
    /// client without an agent upgrade — which matters because the agent
    /// routinely outlives the app that talks to it. A token this build does not
    /// know maps to the generic sentence; it is never rendered raw.
    reason: []const u8,

    /// Free-form supporting text for the same failure, shown verbatim after the
    /// sentence (e.g. `live=256/256 dead=3/256`, or the errno-ish name of a
    /// failed spawn). Optional: absent from a peer that has nothing to add.
    detail: ?[]const u8 = null,

    /// The `reason` vocabulary. Additive: new tokens may be introduced at any
    /// time and an older client renders the generic sentence for one it does
    /// not recognize, so these never need a capability of their own.
    pub const Reason = struct {
        /// The agent is already running `max_sessions` live sessions.
        pub const session_cap = "session_cap";
        /// The child (shell or command) could not be started at all.
        pub const spawn_failed = "spawn_failed";
        /// The agent could not allocate the session's bookkeeping.
        pub const out_of_memory = "out_of_memory";
        /// The `OPEN` payload did not parse.
        pub const malformed_request = "malformed_request";
    };
};

/// `ATTACH_FAILED` (0x07) — the negative reply to an `ATTACH` the agent cannot
/// answer with an `ATTACHED` at all. Sent ONLY when `Negotiated.attach_failed`
/// (a new opcode is a fatal framing error to a peer that does not know it); an
/// older client sees today's silence and times out.
///
/// Same shape as `OpenFailed` on purpose — one carrier (`RefusalCopy`), one
/// client-side token→sentence mapping shape — but its own vocabulary, because
/// the refusals differ: OPEN can hit a session cap, ATTACH cannot; ATTACH can
/// be handed an unparseable id, OPEN cannot.
pub const AttachFailed = struct {
    /// A STABLE MACHINE TOKEN from `Reason` below, never prose (see
    /// `OpenFailed.reason` for why the wording lives on the client).
    reason: []const u8,

    /// Free-form supporting text, shown verbatim after the sentence. Optional.
    detail: ?[]const u8 = null,

    /// The `reason` vocabulary. Additive: an older client renders the generic
    /// sentence for a token it does not recognize, so new ones never need a
    /// capability of their own.
    ///
    /// Note the absences. `session_not_found`, `session_ended` and
    /// `attached_elsewhere` are NOT here: the agent answers all three with an
    /// ordinary `ATTACHED` carrying the matching `AttachStatus`, immediately,
    /// and it has done so since long before this frame existed. They are
    /// reasons a USER sees — `termio/attach_failed_notice.zig` names them from
    /// that status — not reasons that need a wire frame.
    pub const Reason = struct {
        /// The `ATTACH` payload did not parse.
        pub const malformed_request = "malformed_request";
        /// The agent will not take on another attachment right now.
        pub const attach_refused = "attach_refused";
    };
};

/// A caller-owned, fixed-size copy of an `OPEN_FAILED` / `ATTACH_FAILED`
/// payload — the `{reason, detail}` pair either frame carries.
///
/// Why a copy and not the parsed value: the refusal has to outlive the frame
/// (the connection frees the payload as soon as the parked RPC caller returns)
/// and cross into the termio backend, which paints it into the pane after
/// bring-up has already failed. A Zig error carries no payload, so the reason
/// travels beside `error.OpenRefused`/`error.AttachRefused` in a
/// caller-provided struct rather than in a heap allocation somebody has to
/// remember to free on every error path.
///
/// Over-long fields are TRUNCATED, never rejected: a refusal that arrives with
/// a 4 KB detail is still a refusal, and losing the tail of the detail is
/// strictly better than degrading back to a blank pane.
pub const RefusalCopy = struct {
    pub const reason_max = 40;
    pub const detail_max = 160;

    reason_buf: [reason_max]u8 = undefined,
    reason_len: usize = 0,
    detail_buf: [detail_max]u8 = undefined,
    detail_len: usize = 0,

    pub fn reason(self: *const RefusalCopy) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    /// Null when the peer sent no detail (or an empty one), so a caller can
    /// tell "nothing to add" from "added an empty string".
    pub fn detail(self: *const RefusalCopy) ?[]const u8 {
        if (self.detail_len == 0) return null;
        return self.detail_buf[0..self.detail_len];
    }

    pub fn set(self: *RefusalCopy, reason_in: []const u8, detail_in: ?[]const u8) void {
        self.reason_len = @min(reason_in.len, reason_max);
        @memcpy(self.reason_buf[0..self.reason_len], reason_in[0..self.reason_len]);
        const d = detail_in orelse "";
        self.detail_len = @min(d.len, detail_max);
        @memcpy(self.detail_buf[0..self.detail_len], d[0..self.detail_len]);
    }
};

/// The pre-T657 name for `RefusalCopy`, from when a refused OPEN was the only
/// thing that carried one. Kept so an out-of-tree reference still resolves.
pub const OpenFailedCopy = RefusalCopy;

/// `ATTACH` (0x03). `last_byte_offset` anchors the sequence-anchored resync
/// (§7.3): the agent gap-fills `(last_byte_offset, snapshot_offset]`.
pub const Attach = struct {
    session_id: []const u8,
    rows: u16,
    cols: u16,
    last_byte_offset: u64 = 0,
    /// Set by a client retrying after `attached_elsewhere` to steal (§5.3).
    force: bool = false,
};

/// `ATTACHED` (0x04). `status` drives per-session recovery tiers (§7.4).
pub const Attached = struct {
    status: AttachStatus,
    rows: u16 = 0,
    cols: u16 = 0,
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// The byte offset `S` the grid snapshot was captured at; client discards any
    /// `DATA` with `byte_offset <= S` (§7.3).
    snapshot_at_offset: u64 = 0,
    /// Present iff `status == .dead` (a tombstone, §7.1/§7.4).
    exit_code: ?i64 = null,
    /// Set when the session already had an attached bridge (§5.3); the client may
    /// retry with `force = true` to steal.
    attached_elsewhere: bool = false,

    /// Set (with `status == .dead`) when this dead session is a RELAUNCHABLE
    /// tombstone materialized from the agent's on-disk metadata at start (§5.4
    /// reboot floor, T12b) — NOT a child that exited this run. The viewer uses it
    /// to decide whether to auto-fire `RELAUNCH` (T12c) rather than just showing an
    /// exited overlay. A genuinely-exited child leaves this false (it carries an
    /// `exit_code` instead). Additive/optional (older agents omit it → false).
    relaunchable: bool = false,

    /// The live child pid (set with `status == .alive`; 0 otherwise). ATTACH is
    /// the path that matters for `getProcessInfo` — the app relaunch re-attaches
    /// every persistence pane, and `OPENED.pid` from the original open is gone
    /// with the old app process. Additive/optional (older agents omit it → 0,
    /// today's behavior).
    pid: i64 = 0,

    /// The child's PTY slave path on the agent's machine (set with `status ==
    /// .alive`; see `Opened.tty`). Additive/optional (older agents omit it).
    tty: ?[]const u8 = null,

    /// The command the session was running, as the human-readable label the
    /// agent recorded at OPEN time (`SessionInfo.argv`). Sent with `status ==
    /// .dead` so a viewer that refuses to re-execute it (T230's `notify`
    /// policy, the default) can still NAME it in the notice it prints above the
    /// fresh shell — the user's own words: "the console message which says the
    /// session was closed could list the previous command executed so the user
    /// can choose to copy/paste it".
    ///
    /// Additive/optional: an older agent omits it and the viewer prints the
    /// notice without the command line rather than failing. Never load-bearing
    /// for correctness — it is display text, and the viewer sanitizes it before
    /// writing it to a terminal.
    argv: ?[]const u8 = null,

    /// The FOREGROUND command line last sampled inside the session's shell
    /// (T429) — e.g. `claude --continue` for a pane whose recorded `argv` is
    /// null because the user opened a plain shell and TYPED the command. Sent
    /// with `status == .dead` alongside `argv`; the viewer prefers this for
    /// the restart notice (it names what the user was actually running) and
    /// falls back to `argv`. Same trust posture as `argv`: display text only,
    /// sanitized by the viewer, never executed.
    ///
    /// Additive/optional both ways, the `argv`/`tty` precedent: an older agent
    /// omits it (the notice falls back to `argv`, today's behavior) and an
    /// older client ignores it (`ignore_unknown_fields`). No capability gate.
    foreground_cmd: ?[]const u8 = null,

    /// The geometry the session's retained ring tail was drawn at BEFORE this
    /// attach resized the pty to the client's seed (set with `status == .alive`;
    /// 0 = unknown). The raw ring replay is geometry-bound VT — conhost/pty
    /// paints with in-place redraws and bottom-row scrolls that only land
    /// correctly at the size they were emitted at — so the client replays at
    /// THIS geometry and then reflows to the live pane (T106; mirrors
    /// `Relaunched.replay_cols`). Additive/optional (older agents omit them →
    /// 0 → the client keeps today's live-width replay).
    replay_rows: u16 = 0,
    replay_cols: u16 = 0,

    pub const AttachStatus = enum { alive, dead, not_found };
};

/// `RESIZE` (0x11). Pixel geometry computed locally and sent verbatim (§6.5).
pub const Resize = struct {
    rows: u16,
    cols: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,
};

/// `SIGNAL` (0x12). Interactive interrupt (`INT`) is escalated, not a kill (§9.2).
pub const Signal = struct {
    name: []const u8,
};

/// `EXIT` (0x20). Ordered after the final `DATA` for the channel.
pub const Exit = struct {
    code: i64,
    runtime_ms: u64 = 0,
};

/// `META` (0x21). All fields optional; `listening_ports` powers auto-forward
/// (§8.5) and the activity view (§9.3).
pub const Meta = struct {
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    listening_ports: ?[]const u16 = null,
    foreground_cmd: ?[]const u8 = null,

    /// The session's current FOREGROUND pid (`tcgetpgrp` on the pty master),
    /// pushed by the agent whenever it changes (sampled on the agent's 1 s
    /// tick) so `getProcessInfo(.foreground_pid)` has live Exec parity for
    /// agent-backed panes (wp3). Absent on Windows (ConPTY has no foreground
    /// process group — matching WindowsPty, which returns null locally too)
    /// and from older agents; the client then falls back to the child pid.
    /// Additive/optional both ways (unknown-field-tolerant parsers).
    foreground_pid: ?i64 = null,

    /// Whether the session's child process currently has at least one live
    /// DESCENDANT process — i.e. something is running in front of the shell
    /// (T356). Pushed by the agent whenever the answer changes, and only when
    /// `capability.session_busy` was negotiated (the sampling costs a
    /// process-table walk, so an agent with no interested peer does none).
    ///
    /// Deliberately the same question `ProcessTree.hasDescendants` answers
    /// locally, so a cross-machine pane and a local one decide the close
    /// confirmation by the same rule rather than by two similar-looking ones.
    ///
    /// Additive/optional both ways: absent means UNKNOWN, never `false` — an
    /// older agent omits it and the client keeps confirming, and an older
    /// client ignores it. A wrong `false` here would skip a confirmation and
    /// kill a running job, so absence must never read as idle.
    has_descendants: ?bool = null,
};

/// `GET_CWD` (0x22). On-demand request for a session's child working directory.
/// The client sends this at split/tab time so a new remote pane can inherit the
/// parent pane's cwd. No continuous tracking: the agent answers by querying the
/// OS for the child process's CURRENT working directory (works even for shells
/// like cmd.exe that emit no OSC 7). Correlates by the request `Frame.channel`
/// (same-channel RPC), so any channel id may be used; the agent echoes the reply
/// on that same channel.
pub const GetCwd = struct {
    session_id: []const u8,
};

/// `CWD` (0x23). Reply to `GET_CWD`. `ok == false` (and `path == null`) when the
/// query failed (session gone, or the OS cwd read failed); the client then opens
/// the new pane with no cwd hint rather than failing.
///
/// `found` (additive, T06b) disambiguates the two `ok == false` causes: `false`
/// means the agent POSITIVELY does not have this session id in its table (it is
/// gone for good — safe to forget); `true` means the session exists (attachable)
/// but the cwd read failed. `null` ⇒ an older agent that predates the field, so
/// an `ok == false` reply stays INCONCLUSIVE — session-restore liveness probes
/// must not treat it as dead (losing a persisted layout on a transient probe
/// failure is worse than keeping a stale entry).
pub const Cwd = struct {
    session_id: []const u8,
    path: ?[]const u8 = null,
    ok: bool = false,
    found: ?bool = null,
};

/// `LIST_SESSIONS` (0x24). Enumerate every session this agent owns (live +
/// tombstoned). No arguments today (a future increment may add filters); an empty
/// `{}` payload keeps it additive/HELLO-compatible. Correlated by `Frame.channel`
/// (same-channel RPC, like `GET_CWD`): the agent echoes `SESSIONS` on that channel.
pub const ListSessions = struct {};

/// One row of a `SESSIONS` reply (design §5's `{id, state, title, cwd, argv,
/// attached, created_at, exit_code?}`). Strings borrow the agent's session
/// storage until the reply is encoded (the agent holds the store lock across the
/// snapshot+encode). `activity` is the idle/busy/needs_input state as a string so
/// this wire type need not import the agent's `ActivityState` enum. `alive == false`
/// is a tombstone (a dead session, still listed until reaped) — `exit_code` is set
/// then. `attached` is true while a viewer is currently bound to the stream.
pub const SessionInfo = struct {
    id: []const u8,
    alive: bool = true,
    exit_code: ?i64 = null,
    attached: bool = false,
    activity: []const u8 = "idle",
    pid: i64 = 0,
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    argv: ?[]const u8 = null,
    created_at: i64 = 0,
    last_activity: i64 = 0,
    /// True when the session is pinned against idle-TTL reaping (§7.1, T11) — a
    /// persistent local pane the viewer's session-layout manifest references.
    /// Surfaced so `+sessions` can show which sessions survive indefinitely.
    /// Additive/optional (defaults false; older agents omit it).
    pinned: bool = false,
    /// True when this is a DEAD session materialized from the agent's on-disk
    /// metadata at start and not yet relaunched (§5.4 reboot floor, T12b) — i.e.
    /// `alive == false` but the recorded argv/cwd can bring it back via `RELAUNCH`.
    /// A genuinely-exited child (`alive == false`, `exit_code` set) leaves this
    /// false. Additive/optional (defaults false; older agents omit it).
    relaunchable: bool = false,
    /// When the session last became UNATTACHED (agent clock, ms since epoch),
    /// reported only while `alive` and not `attached`; null otherwise. Reset by
    /// every ATTACH, so it always means "continuously unattached since" (T534:
    /// the viewer's long-unattached notification reads it — the agent itself
    /// never acts on it). Additive/optional: older agents omit it, and a reader
    /// that never heard of it changes nothing.
    unattached_since: ?i64 = null,
    /// True when this session's ConPTY, shell and kill-on-close job live in a
    /// separate `--pty-host` HOLDER process rather than inside the agent (T905),
    /// so the shell survives the agent going away.
    ///
    /// What reads it: the non-destructive upgrade policy (T907). An agent can
    /// only replace itself without losing anything once EVERY live session is
    /// holder-backed; a legacy session (ConPTY owned by the agent itself) cannot
    /// be carried across a process boundary — the HPCON wall — so it holds the
    /// handoff back until it closes. `+sessions --agent` counts the false ones
    /// and names them as the drain.
    ///
    /// Additive/optional (defaults false; older agents omit it, and reading a
    /// missing field as "not holder-backed" is the safe direction — it can only
    /// ever hold a handoff back, never permit one that would lose a session).
    holder_backed: bool = false,
};

/// `SESSIONS` (0x25). Reply to `LIST_SESSIONS`: the full session roster. An empty
/// roster encodes as `{"sessions":[]}` (a healthy agent with no sessions), never
/// elided — so the client can distinguish "answered, none" from "no reply".
pub const Sessions = struct {
    sessions: []const SessionInfo = &.{},
};

/// `SET_LAYOUT` (0x28). Store (or, with `delete`, remove) an OPAQUE per-window
/// layout blob keyed by `key` (the owning viewer's manifest-entry id — a
/// window/tab-group identity). The agent NEVER parses `blob`; it persists it
/// verbatim beside the session metadata (§5.4, T18) so a viewer on ANOTHER
/// machine can pull the full window/tab/split topology and rebuild it, attaching
/// each leaf to its live session. `session_ids` lists the sessions the blob
/// references so the agent can REAP the blob once none of them exist any more
/// (the agent stays topology-agnostic — it never inspects the blob to learn
/// this). `delete == true` removes `key` (a clean window close); `blob`/
/// `session_ids` are then ignored. Correlated by `Frame.channel` (same-channel
/// RPC, like `GET_CWD`): the agent echoes `SET_LAYOUT_RESULT` on that channel.
/// Additive/HELLO-compatible.
pub const SetLayout = struct {
    key: []const u8,
    blob: ?[]const u8 = null,
    session_ids: []const []const u8 = &.{},
    delete: bool = false,
};

/// `SET_LAYOUT_RESULT` (0x29). Reply to `SET_LAYOUT`: `ok` is true when the
/// upsert/remove was applied (a store failure — OOM, disk write — yields false).
pub const SetLayoutResult = struct {
    ok: bool = false,
};

/// `GET_LAYOUTS` (0x2a). Fetch EVERY stored layout blob this agent holds (the
/// resumer wants a machine's whole set of windows). No arguments today; an empty
/// `{}` payload keeps it additive/HELLO-compatible. Correlated by `Frame.channel`
/// (same-channel RPC): the agent echoes `LAYOUTS` on that channel.
pub const GetLayouts = struct {};

/// One stored layout in a `LAYOUTS` reply: the opaque `blob` and the `key` it was
/// stored under. `session_ids` are NOT echoed back (the resumer reads the leaf
/// session ids out of the blob it decodes).
pub const LayoutBlob = struct {
    key: []const u8,
    blob: []const u8,
};

/// `LAYOUTS` (0x2b). Reply to `GET_LAYOUTS`: every stored layout. An empty set
/// encodes as `{"layouts":[]}` (a healthy agent with no stored layouts), never
/// elided — so the client can distinguish "answered, none" from "no reply".
pub const Layouts = struct {
    layouts: []const LayoutBlob = &.{},
};

/// `CLOSE_SESSION` (0x2c). End a session BY SESSION ID — the session-scoped
/// equivalent of `CLOSE` (0x14). `CLOSE` is CHANNEL-scoped (the agent looks the
/// session up by the frame's channel), so it can only target a session a local
/// pane is attached to. The chooser's "Kill" action must end a BROWSED session
/// that has no local pane (hence no channel), so it addresses the session by id:
/// the agent unlinks + terminates + frees the session container (the same core as
/// `handleClose`). Correlated by `Frame.channel` (same-channel RPC, like
/// `GET_CWD`): the agent echoes `CLOSE_SESSION_RESULT` on that channel.
/// Additive/HELLO-compatible — gated on the `close_session` capability so the
/// opcode is NEVER sent to a peer that didn't advertise support (an unknown
/// opcode is a fatal framing error for the receiver).
pub const CloseSession = struct {
    session_id: []const u8,
};

/// `CLOSE_SESSION_RESULT` (0x2d). Reply to `CLOSE_SESSION`. `found` = whether a
/// session with that id existed in the agent's table; `ok` = it was closed
/// successfully (unlinked + terminated + freed). An unknown id yields
/// `{found = false, ok = false}` — a definitive "already gone" answer.
/// Additive/HELLO-compatible.
pub const CloseSessionResult = struct {
    session_id: []const u8,
    ok: bool = false,
    found: bool = false,
};

/// `RELAUNCH` (0x26). Ask the agent to respawn a DEAD session — a relaunchable
/// tombstone materialized from disk at agent start (§5.4 reboot floor, T12b), or
/// (idempotently) an already-alive one. The agent respawns the child under the
/// session's recorded argv/cwd, re-keys it into the SAME session id + data channel
/// (so the viewer's layout manifest reference and the already-known channel stay
/// valid), flips the tombstone to alive, and streams fresh output. `rows`/`cols`
/// carry the attaching viewer's current geometry so the respawned pty is sized
/// correctly. Correlated by `session_id` in the reply (the agent echoes
/// `RELAUNCHED` on the session's data channel). Additive/HELLO-compatible.
pub const Relaunch = struct {
    session_id: []const u8,
    rows: u16,
    cols: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,

    /// Respawn fidelity (wp3): the agent's on-disk session record keeps only
    /// argv-label/cwd, so a synthesized relaunch OPEN used to lose the pane's
    /// forwarded environment (GHOZTTY_PANE_ID / GHOZTTY_WINDOW_NAME / shell
    /// integration vars), its TERM, and any explicit shell-integration argv
    /// rewrite. RELAUNCH is always viewer-initiated, and the viewer still holds
    /// all three — so it sends them and the agent applies them to the respawn
    /// exactly like an original OPEN. All additive/optional: an older agent
    /// ignores them (env-less respawn, today's behavior); an older client omits
    /// them and a new agent falls back to the recorded metadata alone.
    env: []const Open.EnvPair = &.{},
    term: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
};

/// `RELAUNCHED` (0x27). Reply to `RELAUNCH`. `ok == true` ⇒ the session is now
/// alive under `pid` and live output is streaming on the reply frame's channel
/// (the client resets its applied-offset baseline to 0 — a relaunch is a FRESH
/// stream, not a resync). `ok == false` distinguishes two failures via `found`:
/// `found == false` means the agent has no such session id (reaped/closed — the
/// client should fall back to a fresh `OPEN`); `found == true` means the session
/// exists but is not relaunchable (a genuinely-exited child with no recorded
/// metadata) or the respawn itself failed.
pub const Relaunched = struct {
    session_id: []const u8,
    ok: bool = false,
    pid: i64 = 0,
    found: bool = false,
    /// True when the agent already replayed pre-restart scrollback + the "session
    /// restarted" divider from a ring disk snapshot (§5.4 reboot scrollback, T13).
    /// The client then SUPPRESSES its own snapshot-less divider so there is exactly
    /// one marker. Additive/defaulted → older agents (never set it) and older
    /// clients (ignore it) interoperate unchanged.
    replayed: bool = false,

    /// The width/height the replayed scrollback (`replayed == true`) was drawn at
    /// — the snapshot's capture geometry (§5.4). 0 = unknown (blank relaunch, or a
    /// legacy GRS1 snapshot with no width). The client replays the raw stream at
    /// this width and then reflows to the live pane, so in-place prompt redraws
    /// don't smear when the restored pane is a different size. Additive/defaulted →
    /// an older agent sends 0 and the client falls back to live-width replay.
    replay_cols: u16 = 0,
    replay_rows: u16 = 0,

    /// The respawned child's PTY slave path (set with `ok == true`; a relaunch
    /// opens a FRESH pty, so any previously-reported tty is stale). See
    /// `Opened.tty`. Additive/optional (older agents omit it).
    tty: ?[]const u8 = null,
};

/// `TUNNEL` (0x40). `-R`/`-D` are forbidden from in-pane RPC (§9.5); enforcement
/// is in the agent, but the type is modeled here for completeness.
pub const Tunnel = struct {
    op: Op,
    type: Type,
    listen: ?[]const u8 = null,
    dest: ?[]const u8 = null,
    autostart: bool = false,

    pub const Op = enum { add, start, stop, remove };
    pub const Type = enum { L, R, D };
};

// -----------------------------------------------------------------------------
// Remote machine activity monitor (§9.3 host/proc view) — JSON payloads
// -----------------------------------------------------------------------------
//
// The agent samples machine-wide host metrics and (later increments) the process
// table; the client renders an activity monitor. These ride the control channel.
// `metrics` is a server-push stream: the client subscribes (`metrics_sub`), the
// agent pushes a `metrics` frame every `interval_ms` until `metrics_unsub`.

/// Machine-wide host resource snapshot. Scalars only (no allocation), so a sampler
/// can return one by value. `cpu_pct` is the busy fraction since the previous
/// sample (0 on the first). `uptime_s`/`load1` are null where the OS has no cheap
/// equivalent (e.g. Windows has no load average).
pub const HostMetrics = struct {
    /// Busy CPU percentage 0..100 across all cores since the previous sample.
    cpu_pct: f32 = 0,
    /// Used physical memory in bytes.
    mem_used: u64 = 0,
    /// Total physical memory in bytes.
    mem_total: u64 = 0,
    /// Logical CPU count.
    ncpu: u32 = 0,
    /// Seconds since boot, if available.
    uptime_s: ?u64 = null,
    /// 1-minute load average, if the OS exposes one (POSIX only).
    load1: ?f32 = null,
};

/// One process-table row (later increments populate the table). Strings borrow the
/// agent's snapshot buffer until encoded; null `user`/`cmd` ⇒ unavailable.
pub const Proc = struct {
    pid: i64,
    ppid: i64 = 0,
    name: []const u8,
    cpu_pct: f32 = 0,
    mem_bytes: u64 = 0,
    user: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    /// Controlling terminal name WITHOUT the `/dev/` prefix (macOS `ttys004`,
    /// Linux `pts/4`), or null when the process has no controlling terminal
    /// (a daemon, or a child that called `setsid`). Windows always reports null.
    ///
    /// The client uses this to attribute a process to the pane it is running in:
    /// every process in a pane inherits the pane's tty, so a tty match seeds
    /// attribution and the ppid chain propagates it to setsid'd descendants.
    ///
    /// A NAME rather than the raw `dev_t` deliberately: device numbers are only
    /// meaningful on the machine that minted them, so a raw dev could never be
    /// matched against a remote pane's tty. Names compare across the wire.
    ///
    /// Additive and back-compatible: an older agent omits the field and it
    /// decodes as null (attribution simply reports nothing), and an older client
    /// ignores it (`ignore_unknown_fields`). No capability gate needed.
    tty: ?[]const u8 = null,
};

/// `PROC_LIST` (0x70). Request the process table; `sort`/`limit` shape the reply.
pub const ProcList = struct {
    sort: ?[]const u8 = null,
    limit: ?u32 = null,
};

/// `PROC_SNAPSHOT` (0x71). Reply to `PROC_LIST`: host metrics + a process slice.
/// `truncated` is set when `limit` clipped the table.
pub const ProcSnapshot = struct {
    ok: bool = false,
    host: HostMetrics = .{},
    procs: []const Proc = &.{},
    truncated: bool = false,
    /// The agent's own pid (0 = unknown / agent pre-dates this field). The client
    /// uses it as the root of the "ghoztty-spawned" descendant tree so the activity
    /// monitor can default to showing only processes the agent launched.
    agent_pid: i64 = 0,
};

/// `METRICS_SUB` (0x72). Subscribe to the pushed host-metrics stream.
pub const MetricsSub = struct {
    interval_ms: u32 = 1000,
};

/// `METRICS` (0x73). One pushed host-metrics sample (control channel).
pub const Metrics = struct {
    host: HostMetrics = .{},
};

/// `METRICS_UNSUB` (0x74). Stop the pushed metrics stream. No fields.
pub const MetricsUnsub = struct {};

// --- Per-session CPU roll-up (pushed stream, gated on `capability.session_cpu`) --
//
// The chooser wants one number per session: is this agent session busy? That is a
// property of the session's WHOLE process tree — a session is busy because the
// agent running in it is busy, not because its zsh is — so the roll-up happens
// AGENT-SIDE, where the session→child-pid table lives. The client would otherwise
// have to pull the entire process table on a timer just to sum a few subtrees.

/// One session's CPU roll-up.
pub const SessionCpuRow = struct {
    /// The session id, matching `SESSIONS`/`LIST_SESSIONS`.
    id: []const u8,
    /// Per-core CPU% summed over the session's shell and every descendant, in the
    /// same units as `Proc.cpu_pct`: ~100 per fully-busy core, so a session running
    /// four busy threads reads ~400. NOT clamped.
    cpu_pct: f32 = 0,
};

/// `SESSION_CPU_SUB` (0x79). Subscribe to the pushed per-session CPU stream.
pub const SessionCpuSub = struct {
    /// The cadence the client would LIKE, as a hint. The agent treats it as a
    /// floor and may push less often when the machine is loaded — see
    /// `SessionCpu.interval_ms` for what it actually chose.
    interval_ms: u32 = 2000,
};

/// `SESSION_CPU` (0x7a). One pushed per-session CPU sample (control channel).
pub const SessionCpu = struct {
    /// The cadence the agent ACTUALLY used for this sample, which may be longer
    /// than the client asked for (it throttles itself under load). Reported so the
    /// client can tell "idle" from "stale" instead of assuming its hint was honored.
    interval_ms: u32 = 0,
    sessions: []const SessionCpuRow = &.{},
};

/// `SESSION_CPU_UNSUB` (0x7b). Stop the pushed per-session CPU stream. No fields.
pub const SessionCpuUnsub = struct {};

/// `PROC_KILL` (0x75). Signal/kill a process by pid. `signal` defaults (agent-side)
/// to a terminate when null.
pub const ProcKill = struct {
    pid: i64,
    signal: ?[]const u8 = null,
};

/// `PROC_KILL_RESULT` (0x76). Reply to `PROC_KILL`.
pub const ProcKillResult = struct {
    pid: i64,
    ok: bool = false,
    @"error": ?[]const u8 = null,
};

/// `PROC_SPAWN` (0x77). Launch a process on the remote host. `detached` ⇒ not tied
/// to a session's child lifetime.
pub const ProcSpawn = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    detached: bool = true,
};

/// `PROC_SPAWN_RESULT` (0x78). Reply to `PROC_SPAWN`.
pub const ProcSpawnResult = struct {
    ok: bool = false,
    pid: ?i64 = null,
    @"error": ?[]const u8 = null,
};

/// Encode any of the JSON payload structs above to a byte slice owned by `alloc`.
pub fn encodeJson(alloc: Allocator, value: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{
        .emit_null_optional_fields = false,
    });
}

/// Parse one of the JSON payload structs. Returns a `Parsed(T)` owning its
/// backing memory; call `.deinit()` when done. Unknown fields are ignored so a
/// newer peer's extra fields don't break an older parser.
pub fn parseJson(comptime T: type, alloc: Allocator, json: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, json, .{
        .ignore_unknown_fields = true,
    });
}

// -----------------------------------------------------------------------------
// JSON-RPC 2.0 envelope (§9.5) — rides RPC (0x30) / RPC_RESULT (0x31)
// -----------------------------------------------------------------------------

/// JSON-RPC version string. Caller identity is kernel-derived (peer-cred), never
/// carried in-band (§9.5), so the envelope has no auth field.
pub const jsonrpc_version = "2.0";

/// A JSON-RPC request/notification. `id == null` ⇒ notification (used for the
/// subscription stream pushed as `RPC_RESULT`, §9.3). We restrict ids to integers
/// (we mint them), which keeps parsing total.
pub const RpcRequest = struct {
    jsonrpc: []const u8 = jsonrpc_version,
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?i64 = null,

    pub fn encode(self: RpcRequest, alloc: Allocator) Allocator.Error![]u8 {
        return encodeJson(alloc, self);
    }
};

/// A JSON-RPC error object.
pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// A JSON-RPC response. Exactly one of `result`/`@"error"` is set in a valid
/// response; this is enforced by `validateResponse`, not the type system.
pub const RpcResponse = struct {
    jsonrpc: []const u8 = jsonrpc_version,
    result: ?std.json.Value = null,
    @"error": ?RpcError = null,
    id: ?i64 = null,

    pub fn encode(self: RpcResponse, alloc: Allocator) Allocator.Error![]u8 {
        return encodeJson(alloc, self);
    }
};

/// Well-known JSON-RPC error codes (§10.2 maps a subset to CLI exit codes).
pub const rpc_error = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    /// In-pane RPC attempted an operation outside its capability grant (§9.5);
    /// surfaced to the CLI as exit 16 (§10.2).
    pub const capability_denied: i64 = -32000;
};

/// Validate a parsed request envelope: correct version and a non-empty method.
pub fn validateRequest(req: RpcRequest) ProtocolError!void {
    if (!std.mem.eql(u8, req.jsonrpc, jsonrpc_version)) return error.MalformedPayload;
    if (req.method.len == 0) return error.MalformedPayload;
}

/// Validate a parsed response envelope: correct version and exactly one of
/// result/error.
pub fn validateResponse(resp: RpcResponse) ProtocolError!void {
    if (!std.mem.eql(u8, resp.jsonrpc, jsonrpc_version)) return error.MalformedPayload;
    const has_result = resp.result != null;
    const has_error = resp.@"error" != null;
    if (has_result == has_error) return error.MalformedPayload; // need exactly one
}

// -----------------------------------------------------------------------------
// Transfer codecs (COBS, base64) with decoded-length bounds (§4.2 / §15 NEW-3)
// -----------------------------------------------------------------------------

/// Consistent Overhead Byte Stuffing. Removes all `0x00` bytes from a block so a
/// `0x00` can delimit frames. Worst-case overhead is 1 byte per 254 input bytes
/// plus a leading code byte. The `0x00` delimiter is NOT part of the encoded
/// block (the caller appends/strips it).
pub const cobs = struct {
    /// Maximum encoded length for `n` input bytes (excluding the delimiter).
    pub fn maxEncodedLen(n: usize) usize {
        return n + n / 254 + 1;
    }

    /// Encode `src` into `dst` (which must be ≥ `maxEncodedLen(src.len)`).
    /// Returns the encoded length. The caller appends a `0x00` delimiter.
    pub fn encode(src: []const u8, dst: []u8) usize {
        assert(dst.len >= maxEncodedLen(src.len));
        var read: usize = 0;
        var code_idx: usize = 0; // index of the pending code byte
        var write: usize = 1; // first byte is the code; data starts at 1
        var code: u8 = 1;
        while (read < src.len) : (read += 1) {
            const b = src[read];
            if (b == 0) {
                dst[code_idx] = code;
                code_idx = write;
                write += 1;
                code = 1;
            } else {
                dst[write] = b;
                write += 1;
                code += 1;
                if (code == 0xFF) {
                    // Group is full; start a new one.
                    dst[code_idx] = code;
                    code_idx = write;
                    write += 1;
                    code = 1;
                }
            }
        }
        dst[code_idx] = code;
        return write;
    }

    /// Decode a single COBS block (no trailing delimiter) into `dst`. Enforces
    /// the decoded length against `dst.len` (the caller sizes `dst` to the hard
    /// frame cap, §15 NEW-3). Errors on a malformed block (internal `0x00`, a
    /// group that runs past the end) or on overflow.
    pub fn decode(src: []const u8, dst: []u8) ProtocolError!usize {
        var read: usize = 0;
        var write: usize = 0;
        while (read < src.len) {
            const code = src[read];
            if (code == 0) return error.MalformedEncoding; // no zeros inside a block
            read += 1;
            const copy = code - 1;
            if (read + copy > src.len) return error.MalformedEncoding; // truncated group
            if (write + copy > dst.len) return error.FrameTooLarge;
            @memcpy(dst[write..][0..copy], src[read..][0..copy]);
            write += copy;
            read += copy;
            // A non-0xFF group that isn't the last group implies an elided zero.
            if (code != 0xFF and read < src.len) {
                if (write >= dst.len) return error.FrameTooLarge;
                dst[write] = 0;
                write += 1;
            }
        }
        return write;
    }
};

/// Base64 transfer codec (standard alphabet, `\n` delimiter). Thin wrappers over
/// `std.base64` that enforce the decoded-length bound *before* decoding.
pub const base64 = struct {
    const enc = std.base64.standard.Encoder;
    const dec = std.base64.standard.Decoder;

    pub fn maxEncodedLen(n: usize) usize {
        return enc.calcSize(n);
    }

    /// Encode `src` into `dst` (≥ `maxEncodedLen(src.len)`). Returns encoded len.
    pub fn encode(src: []const u8, dst: []u8) usize {
        const out = enc.encode(dst[0..enc.calcSize(src.len)], src);
        return out.len;
    }

    /// Decode a single base64 line (no trailing `\n`) into `dst`. Computes the
    /// decoded size first and rejects anything exceeding `dst.len` (the frame
    /// cap) before allocating/writing (§15 NEW-3).
    pub fn decode(src: []const u8, dst: []u8) ProtocolError!usize {
        const need = dec.calcSizeForSlice(src) catch return error.MalformedEncoding;
        if (need > dst.len) return error.FrameTooLarge;
        dec.decode(dst[0..need], src) catch return error.MalformedEncoding;
        return need;
    }
};

// -----------------------------------------------------------------------------
// Writer: encode a frame to the wire (binary + transfer encoding)
// -----------------------------------------------------------------------------

/// Encode `frame` to its full on-wire bytes (binary header + payload, then the
/// pinned transfer encoding) and append them to `out`. This is what the
/// connection's MPSC writer (§3.4) emits onto the socket.
pub fn writeFrame(
    alloc: Allocator,
    encoding: TransferEncoding,
    frame: Frame,
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    const inner_len = Frame.encodedLen(frame.payload.len);
    switch (encoding) {
        .raw => {
            // Frame is self-delimiting via its length prefix; append directly.
            const dst = try out.addManyAsSlice(alloc, inner_len);
            _ = frame.encodeInto(dst);
        },
        .cobs => {
            const inner = try alloc.alloc(u8, inner_len);
            defer alloc.free(inner);
            _ = frame.encodeInto(inner);
            const dst = try out.addManyAsSlice(alloc, cobs.maxEncodedLen(inner_len) + 1);
            const n = cobs.encode(inner, dst);
            dst[n] = 0; // delimiter
            out.shrinkRetainingCapacity(out.items.len - (dst.len - (n + 1)));
        },
        .base64 => {
            const inner = try alloc.alloc(u8, inner_len);
            defer alloc.free(inner);
            _ = frame.encodeInto(inner);
            const dst = try out.addManyAsSlice(alloc, base64.maxEncodedLen(inner_len) + 1);
            const n = base64.encode(inner, dst);
            dst[n] = '\n'; // delimiter
            out.shrinkRetainingCapacity(out.items.len - (dst.len - (n + 1)));
        },
    }
}

// -----------------------------------------------------------------------------
// Reader: streaming, partial-read-safe, untrusted-input frame parser (§15 M3)
// -----------------------------------------------------------------------------

/// A streaming frame reader. Bytes arrive from the socket in arbitrary chunks
/// (partial frames, multiple frames, mid-frame splits); `push` accumulates them
/// and `next` yields complete frames one at a time, transfer-decoding as needed.
///
/// All input is untrusted (§15 M3): `next` bound-checks every `len` (against the
/// configurable `max_frame`), rejects unknown frame types, and surfaces a
/// `ProtocolError` rather than panicking on any malformed input. The connection
/// drops the link on any error.
///
/// Returned `Frame.payload` borrows reader-internal storage and is valid only
/// until the next `push`/`next` call.
pub const Reader = struct {
    alloc: Allocator,
    encoding: TransferEncoding,
    /// Accumulated, not-yet-consumed wire bytes.
    buf: std.ArrayList(u8) = .empty,
    /// Offset of the first unconsumed byte in `buf` (avoids O(n) shifts per
    /// frame; we compact lazily, see `compact`).
    head: usize = 0,
    /// Scratch for transfer-decoded frame bytes (cobs/base64). A returned frame
    /// in those encodings borrows this.
    decoded: std.ArrayList(u8) = .empty,
    /// Hard cap on a single frame's decoded length. Defaults to `max_frame_len`;
    /// tests lower it to exercise the bound cheaply.
    max_frame: usize = max_frame_len,

    pub fn init(alloc: Allocator, encoding: TransferEncoding) Reader {
        return .{ .alloc = alloc, .encoding = encoding };
    }

    pub fn deinit(self: *Reader) void {
        self.buf.deinit(self.alloc);
        self.decoded.deinit(self.alloc);
        self.* = undefined;
    }

    /// Append freshly-read socket bytes. May invalidate a previously-returned
    /// frame's payload.
    pub fn push(self: *Reader, bytes: []const u8) Allocator.Error!void {
        self.compact();
        try self.buf.appendSlice(self.alloc, bytes);
    }

    /// Drop the consumed prefix when it's cheap/worthwhile, so `buf` doesn't grow
    /// unbounded across a long-lived connection. Called at the top of `push`/`next`
    /// (never while a returned frame still borrows `buf`, preserving validity for
    /// exactly one call as documented).
    fn compact(self: *Reader) void {
        if (self.head == 0) return;
        if (self.head == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        // Only pay the memmove once the dead prefix is sizable.
        if (self.head >= 64 * 1024) {
            const remaining = self.buf.items.len - self.head;
            std.mem.copyForwards(
                u8,
                self.buf.items[0..remaining],
                self.buf.items[self.head..],
            );
            self.buf.shrinkRetainingCapacity(remaining);
            self.head = 0;
        }
    }

    /// Yield the next complete frame, or `null` if more bytes are needed.
    pub fn next(self: *Reader) ReadError!?Frame {
        self.compact();
        return switch (self.encoding) {
            .raw => self.nextRaw(),
            .cobs => self.nextDelimited(0),
            .base64 => self.nextDelimited('\n'),
        };
    }

    /// `raw`: frames self-delimit via the 4-byte length prefix.
    fn nextRaw(self: *Reader) ProtocolError!?Frame {
        const avail = self.buf.items[self.head..];
        if (avail.len < 4) return null;
        const total = std.mem.readInt(u32, avail[0..4], .big);
        if (total < header_len) return error.FrameTooSmall;
        if (total > self.max_frame) return error.FrameTooLarge;
        if (avail.len < total) return null; // need more bytes
        const frame = try Frame.decode(avail[0..total]);
        self.head += total;
        return frame;
    }

    /// `cobs`/`base64`: frames are delimited by `delim` (`0x00` / `\n`). Empty
    /// blocks (e.g. a stray `\r\n` or leading delimiter) are skipped, not errors.
    fn nextDelimited(self: *Reader, delim: u8) ReadError!?Frame {
        while (true) {
            const avail = self.buf.items[self.head..];
            const idx = std.mem.indexOfScalar(u8, avail, delim) orelse return null;
            const block = avail[0..idx];
            self.head += idx + 1; // consume block + delimiter
            // Skip empties (and, for base64, a trailing CR before the LF).
            const trimmed = if (self.encoding == .base64 and block.len > 0 and
                block[block.len - 1] == '\r')
                block[0 .. block.len - 1]
            else
                block;
            if (trimmed.len == 0) continue;

            try self.decoded.ensureTotalCapacity(self.alloc, self.max_frame);
            self.decoded.clearRetainingCapacity();
            const scratch = self.decoded.allocatedSlice();
            const n = switch (self.encoding) {
                .cobs => try cobs.decode(trimmed, scratch),
                .base64 => try base64.decode(trimmed, scratch),
                .raw => unreachable,
            };
            self.decoded.items.len = n;
            return try Frame.decode(self.decoded.items);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// All three encodings, iterated by the round-trip tests.
const all_encodings = [_]TransferEncoding{ .raw, .cobs, .base64 };

/// Build a representative frame for every `FrameType` so "round-trip every frame"
/// is literal. Payloads are arbitrary bytes — the framing layer is payload-opaque.
fn sampleFrames(alloc: Allocator) ![]Frame {
    var list: std.ArrayList(Frame) = .empty;
    errdefer list.deinit(alloc);

    // A DATA frame with a real binary DATA payload.
    const data_bytes = "hello \x00\x01\xff world\r\n"; // includes NUL + CRLF + high byte
    const dp: DataPayload = .{ .byte_offset = 0xDEAD_BEEF_0000_1234, .bytes = data_bytes };
    const dp_buf = try alloc.alloc(u8, DataPayload.encodedLen(data_bytes.len));
    _ = dp.encodeInto(dp_buf);

    // A FLOW frame with a real binary FLOW payload.
    const fl: Flow = .{ .channel = 0xAABB, .op = .pause, .n = 0 };
    const fl_buf = try alloc.alloc(u8, Flow.encoded_len);
    _ = fl.encodeInto(fl_buf);

    try list.append(alloc, .{ .type = .hello, .channel = control_channel, .seq = 0, .payload = "{\"proto_version\":1}" });
    try list.append(alloc, .{ .type = .open, .channel = control_channel, .seq = 1, .payload = "{}" });
    try list.append(alloc, .{ .type = .opened, .channel = control_channel, .seq = 2, .payload = "{}" });
    try list.append(alloc, .{ .type = .attach, .channel = control_channel, .seq = 3, .payload = "{}" });
    try list.append(alloc, .{ .type = .attached, .channel = control_channel, .seq = 4, .payload = "{}" });
    try list.append(alloc, .{ .type = .detached, .channel = control_channel, .seq = 5, .payload = "" });
    try list.append(alloc, .{ .type = .data, .channel = 0x1111_2222_3333, .seq = 6, .payload = dp_buf });
    try list.append(alloc, .{ .type = .resize, .channel = control_channel, .seq = 7, .payload = "{}" });
    try list.append(alloc, .{ .type = .signal, .channel = control_channel, .seq = 8, .payload = "{}" });
    try list.append(alloc, .{ .type = .detach, .channel = control_channel, .seq = 9, .payload = "" });
    try list.append(alloc, .{ .type = .close, .channel = control_channel, .seq = 10, .payload = "" });
    try list.append(alloc, .{ .type = .exit, .channel = control_channel, .seq = 11, .payload = "{}" });
    try list.append(alloc, .{ .type = .meta, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .get_cwd, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .cwd, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .set_layout, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .set_layout_result, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .get_layouts, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .layouts, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .close_session, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .close_session_result, .channel = control_channel, .seq = 12, .payload = "{}" });
    try list.append(alloc, .{ .type = .rpc, .channel = control_channel, .seq = 13, .payload = "{}" });
    try list.append(alloc, .{ .type = .rpc_result, .channel = control_channel, .seq = 14, .payload = "{}" });
    try list.append(alloc, .{ .type = .tunnel, .channel = control_channel, .seq = 15, .payload = "{}" });
    try list.append(alloc, .{ .type = .ping, .channel = control_channel, .seq = 16, .payload = "" });
    try list.append(alloc, .{ .type = .pong, .channel = control_channel, .seq = 17, .payload = "" });
    try list.append(alloc, .{ .type = .flow, .channel = control_channel, .seq = 18, .payload = fl_buf });
    try list.append(alloc, .{ .type = .proc_list, .channel = control_channel, .seq = 19, .payload = "{}" });
    try list.append(alloc, .{ .type = .proc_snapshot, .channel = control_channel, .seq = 20, .payload = "{}" });
    try list.append(alloc, .{ .type = .metrics_sub, .channel = control_channel, .seq = 21, .payload = "{}" });
    try list.append(alloc, .{ .type = .metrics, .channel = control_channel, .seq = 22, .payload = "{}" });
    try list.append(alloc, .{ .type = .metrics_unsub, .channel = control_channel, .seq = 23, .payload = "{}" });
    try list.append(alloc, .{ .type = .proc_kill, .channel = control_channel, .seq = 24, .payload = "{}" });
    try list.append(alloc, .{ .type = .proc_kill_result, .channel = control_channel, .seq = 25, .payload = "{}" });
    try list.append(alloc, .{ .type = .proc_spawn, .channel = control_channel, .seq = 26, .payload = "{}" });
    try list.append(alloc, .{ .type = .proc_spawn_result, .channel = control_channel, .seq = 27, .payload = "{}" });

    return list.toOwnedSlice(alloc);
}

fn freeSampleFrames(alloc: Allocator, frames: []Frame) void {
    // Free only the two heap-allocated payloads (DATA, FLOW); the rest are literals.
    for (frames) |f| {
        if (f.type == .data or f.type == .flow) alloc.free(@constCast(f.payload));
    }
    alloc.free(frames);
}

test "round-trip every frame type, every encoding" {
    const alloc = testing.allocator;
    const frames = try sampleFrames(alloc);
    defer freeSampleFrames(alloc, frames);

    for (all_encodings) |enc| {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(alloc);
        for (frames) |f| try writeFrame(alloc, enc, f, &wire);

        var reader = Reader.init(alloc, enc);
        defer reader.deinit();
        try reader.push(wire.items);

        for (frames) |expected| {
            const got = (try reader.next()) orelse return error.MissingFrame;
            try testing.expectEqual(expected.type, got.type);
            try testing.expectEqual(expected.channel, got.channel);
            try testing.expectEqual(expected.seq, got.seq);
            try testing.expectEqualSlices(u8, expected.payload, got.payload);
        }
        // Stream fully consumed.
        try testing.expect((try reader.next()) == null);
    }
}

test "partial / short reads: one byte at a time" {
    const alloc = testing.allocator;
    const frames = try sampleFrames(alloc);
    defer freeSampleFrames(alloc, frames);

    for (all_encodings) |enc| {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(alloc);
        for (frames) |f| try writeFrame(alloc, enc, f, &wire);

        var reader = Reader.init(alloc, enc);
        defer reader.deinit();

        var produced: usize = 0;
        // Feed the wire one byte at a time, draining whatever completes.
        for (wire.items) |b| {
            try reader.push(&[_]u8{b});
            while (try reader.next()) |got| {
                const expected = frames[produced];
                try testing.expectEqual(expected.type, got.type);
                try testing.expectEqual(expected.seq, got.seq);
                try testing.expectEqualSlices(u8, expected.payload, got.payload);
                produced += 1;
            }
        }
        try testing.expectEqual(frames.len, produced);
    }
}

test "DATA payload binary header round-trips" {
    const bytes = "the quick brown fox";
    const dp: DataPayload = .{ .byte_offset = 1_000_000, .bytes = bytes };
    var buf: [64]u8 = undefined;
    const enc = dp.encodeInto(&buf);
    const dec = try DataPayload.decode(enc);
    try testing.expectEqual(@as(u64, 1_000_000), dec.byte_offset);
    try testing.expectEqualSlices(u8, bytes, dec.bytes);

    // Too-short payload (< 8-byte header) is rejected, not a panic.
    try testing.expectError(error.MalformedPayload, DataPayload.decode("abc"));
}

test "FLOW payload binary round-trips and rejects bad op" {
    const fl: Flow = .{ .channel = 0x1234_5678_9abc, .op = .credit, .n = 65536 };
    var buf: [Flow.encoded_len]u8 = undefined;
    const enc = fl.encodeInto(&buf);
    const dec = try Flow.decode(enc);
    try testing.expectEqual(fl.channel, dec.channel);
    try testing.expectEqual(FlowOp.credit, dec.op);
    try testing.expectEqual(@as(u32, 65536), dec.n);

    // Unknown op byte → malformed, not UB.
    var bad = buf;
    bad[0] = 0x7f;
    try testing.expectError(error.MalformedPayload, Flow.decode(&bad));
    // Truncated → malformed.
    try testing.expectError(error.MalformedPayload, Flow.decode(buf[0..3]));
}

test "oversized len is rejected (no huge allocation)" {
    const alloc = testing.allocator;
    var reader = Reader.init(alloc, .raw);
    defer reader.deinit();

    // A raw header claiming a 4 GiB frame.
    var hdr: [header_len]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0xFFFF_FFFF, .big);
    hdr[4] = @intFromEnum(FrameType.data);
    @memset(hdr[5..], 0);
    try reader.push(&hdr);
    try testing.expectError(error.FrameTooLarge, reader.next());
}

test "len smaller than header is rejected" {
    const alloc = testing.allocator;
    var reader = Reader.init(alloc, .raw);
    defer reader.deinit();
    var hdr: [header_len]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 3, .big); // < header_len
    @memset(hdr[4..], 0);
    try reader.push(&hdr);
    try testing.expectError(error.FrameTooSmall, reader.next());
}

test "unknown frame type is rejected" {
    const alloc = testing.allocator;
    var reader = Reader.init(alloc, .raw);
    defer reader.deinit();

    var f: [header_len]u8 = undefined;
    std.mem.writeInt(u32, f[0..4], header_len, .big); // empty payload
    f[4] = 0xEE; // not a known FrameType
    @memset(f[5..], 0);
    try reader.push(&f);
    try testing.expectError(error.UnknownType, reader.next());
}

test "COBS encode/decode round-trips incl. all-zero and high bytes" {
    const cases = [_][]const u8{
        "",
        "\x00",
        "\x00\x00\x00",
        "no zeros here",
        "embedded\x00zero",
        "\xff\xff\xff\xff",
    };
    var dst: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    for (cases) |c| {
        const n = cobs.encode(c, &dst);
        // Encoded block must contain no NUL (so the delimiter is unambiguous).
        try testing.expect(std.mem.indexOfScalar(u8, dst[0..n], 0) == null);
        const m = try cobs.decode(dst[0..n], &out);
        try testing.expectEqualSlices(u8, c, out[0..m]);
    }
}

test "COBS round-trips a 600-byte run (>0xFF group boundary)" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, 600);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @intCast((i % 255) + 1); // 1..255, no zeros

    const dst = try alloc.alloc(u8, cobs.maxEncodedLen(big.len));
    defer alloc.free(dst);
    const n = cobs.encode(big, dst);
    const out = try alloc.alloc(u8, big.len + 16);
    defer alloc.free(out);
    const m = try cobs.decode(dst[0..n], out);
    try testing.expectEqualSlices(u8, big, out[0..m]);
}

test "malformed COBS is rejected" {
    var out: [64]u8 = undefined;
    // Internal zero is illegal inside a COBS block.
    try testing.expectError(error.MalformedEncoding, cobs.decode("\x03ab\x00", &out));
    // Code points past the end of the block (truncated group).
    try testing.expectError(error.MalformedEncoding, cobs.decode("\x05ab", &out));
}

test "COBS decode respects the destination bound" {
    var tiny: [2]u8 = undefined;
    // A block that decodes to more than the dst can hold → FrameTooLarge.
    try testing.expectError(error.FrameTooLarge, cobs.decode("\x06abcde", &tiny));
}

test "malformed base64 is rejected" {
    var out: [64]u8 = undefined;
    try testing.expectError(error.MalformedEncoding, base64.decode("not valid base64!!", &out));
    try testing.expectError(error.MalformedEncoding, base64.decode("abc", &out)); // bad length
}

test "transfer-decoded length bound enforced via small max_frame" {
    const alloc = testing.allocator;
    // Encode a legitimately large-ish frame, then read it with a tiny cap.
    const payload = "x" ** 200;
    const frame: Frame = .{ .type = .data, .channel = 1, .seq = 0, .payload = payload };

    inline for (.{ TransferEncoding.cobs, TransferEncoding.base64 }) |enc| {
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(alloc);
        try writeFrame(alloc, enc, frame, &wire);

        var reader = Reader.init(alloc, enc);
        defer reader.deinit();
        reader.max_frame = 64; // decoded frame (229 bytes) exceeds this
        try reader.push(wire.items);
        try testing.expectError(error.FrameTooLarge, reader.next());
    }
}

test "HELLO encode / parse / negotiate" {
    const alloc = testing.allocator;
    const caps = [_][]const u8{ capability.resync, capability.flow };
    const hello: Hello = .{ .transfer_encoding = .cobs, .capabilities = &caps };

    const json = try hello.encode(alloc);
    defer alloc.free(json);

    var parsed = try Hello.parse(alloc, json);
    defer parsed.deinit();
    try testing.expectEqual(proto_version, parsed.value.proto_version);
    try testing.expectEqual(TransferEncoding.cobs, parsed.value.transfer_encoding);
    try testing.expectEqual(@as(usize, 2), parsed.value.capabilities.len);

    // Matching encodings negotiate; mismatched version/encoding are fatal.
    const local: Hello = .{ .transfer_encoding = .cobs };
    const agreed = try negotiate(local, parsed.value);
    try testing.expectEqual(TransferEncoding.cobs, agreed.transfer_encoding);

    try testing.expectError(error.Incompatible, negotiate(
        .{ .transfer_encoding = .raw },
        .{ .transfer_encoding = .cobs },
    ));
    try testing.expectError(error.Incompatible, negotiate(
        .{ .proto_version = 1, .transfer_encoding = .raw },
        .{ .proto_version = 2, .transfer_encoding = .raw },
    ));
}

test "negotiate: agent_handoff is the intersection, and skew keeps the old policy" {
    const both = [_][]const u8{capability.agent_handoff};
    const other = [_][]const u8{capability.rpc};

    // Both advertise ⇒ the agent replaces itself and the peer stands down.
    try testing.expect((try negotiate(
        .{ .transfer_encoding = .raw, .capabilities = &both },
        .{ .transfer_encoding = .raw, .capabilities = &both },
    )).agent_handoff);

    // Either side missing ⇒ false, in BOTH directions. This is the one that
    // matters: an app that stood down on an agent which never hands itself off
    // would leave that agent stale forever, which is the T662 defect restated.
    try testing.expect(!(try negotiate(
        .{ .transfer_encoding = .raw, .capabilities = &both },
        .{ .transfer_encoding = .raw, .capabilities = &other },
    )).agent_handoff);
    try testing.expect(!(try negotiate(
        .{ .transfer_encoding = .raw, .capabilities = &other },
        .{ .transfer_encoding = .raw, .capabilities = &both },
    )).agent_handoff);
    try testing.expect(!(try negotiate(
        .{ .transfer_encoding = .raw },
        .{ .transfer_encoding = .raw },
    )).agent_handoff);
}

test "SessionInfo.holder_backed is additive: absent decodes as legacy" {
    const alloc = testing.allocator;

    // An older agent's row has no such key. It must parse, and it must read as
    // NOT holder-backed — the direction that can only ever hold an upgrade back,
    // never permit one that would lose a session.
    var old = try parseJson(SessionInfo, alloc, "{\"id\":\"a\",\"alive\":true}");
    defer old.deinit();
    try testing.expect(!old.value.holder_backed);

    var new = try parseJson(SessionInfo, alloc, "{\"id\":\"a\",\"alive\":true,\"holder_backed\":true}");
    defer new.deinit();
    try testing.expect(new.value.holder_backed);
}

test "negotiate: open_failed capability is the intersection of both HELLOs" {
    const both = [_][]const u8{capability.open_failed};
    const other = [_][]const u8{capability.rpc};

    // Both advertise → the agent may answer a refused OPEN.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(n.open_failed);
    }
    // Either side missing → disabled, in BOTH directions. This is the whole
    // skew guarantee: a new agent must stay silent for an old app (which would
    // treat 0x06 as a fatal framing error), and a new app must not expect a
    // frame an old agent will never send.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &other },
        );
        try testing.expect(!n.open_failed);
    }
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &other },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(!n.open_failed);
    }
    // Neither: the pre-change world.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw },
            .{ .transfer_encoding = .raw },
        );
        try testing.expect(!n.open_failed);
    }
}

test "negotiate: attach_failed capability is the intersection of both HELLOs" {
    const both = [_][]const u8{capability.attach_failed};
    const other = [_][]const u8{capability.open_failed};

    // Both advertise → the agent may answer an unanswerable ATTACH.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(n.attach_failed);
    }
    // Either side missing → disabled, in BOTH directions: 0x07 is a fatal
    // framing error to a peer that does not know it, and a new app must not
    // expect a frame an old agent will never send. Note the `other` set here
    // is `open_failed` — the two gates are independent, and negotiating one
    // must never imply the other.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &other },
        );
        try testing.expect(!n.attach_failed);
        try testing.expect(!n.open_failed);
    }
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &other },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(!n.attach_failed);
    }
    // Neither: the pre-change world.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw },
            .{ .transfer_encoding = .raw },
        );
        try testing.expect(!n.attach_failed);
    }
}

test "T739: onDataLane keeps both data-lane opcodes off the control lane" {
    // The bug this exists to prevent, measured on box: with the fold spelled
    // `type == .data` at each mux, a `data_repaint` frame went to the CONTROL
    // lane, where the control reader ignores what it does not recognize. The
    // agent sent a 197-byte grid snapshot, the client had negotiated it, and it
    // vanished — no crash, no log, just a pane that never repainted.
    try testing.expect(onDataLane(.data));
    try testing.expect(onDataLane(.data_repaint));

    // Everything else is control, including the frames that talk ABOUT a
    // channel's data (FLOW) and the lifecycle frames around it.
    for ([_]FrameType{
        .hello, .open,  .opened, .attach, .attached, .detached,
        .flow,  .exit,  .meta,   .resize, .signal,   .detach,
        .close, .ping,  .pong,   .rpc,    .rpc_result,
        .open_failed,   .attach_failed,
    }) |t| try testing.expect(!onDataLane(t));
}

test "negotiate: repaint_data capability is the intersection of both HELLOs" {
    const both = [_][]const u8{capability.repaint_data};
    const other = [_][]const u8{capability.grid_snapshot};

    // Both advertise → the agent frames its injected repaints as 0x15.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(n.repaint_data);
    }
    // Either side missing → disabled, in BOTH directions: 0x15 is a fatal
    // framing error to a peer that does not know it. The `other` set is
    // `grid_snapshot` on purpose — the repaint this gate is ABOUT is the
    // grid snapshot, and negotiating that one must still not imply this one.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &other },
        );
        try testing.expect(!n.repaint_data);
    }
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &other },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(!n.repaint_data);
    }
    // Neither: the pre-T739 world, where the repaint rides plain DATA.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw },
            .{ .transfer_encoding = .raw },
        );
        try testing.expect(!n.repaint_data);
    }
}

test "AttachFailed: round-trips, and an unknown reason from a newer agent parses" {
    const alloc = testing.allocator;

    const json = try encodeJson(alloc, AttachFailed{
        .reason = AttachFailed.Reason.malformed_request,
        .detail = "UnexpectedEndOfInput",
    });
    defer alloc.free(json);

    var parsed = try parseJson(AttachFailed, alloc, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("malformed_request", parsed.value.reason);
    try testing.expectEqualStrings("UnexpectedEndOfInput", parsed.value.detail.?);

    const bare = try encodeJson(alloc, AttachFailed{ .reason = AttachFailed.Reason.attach_refused });
    defer alloc.free(bare);
    var p2 = try parseJson(AttachFailed, alloc, bare);
    defer p2.deinit();
    try testing.expect(p2.value.detail == null);

    var p3 = try parseJson(AttachFailed, alloc, "{\"reason\":\"attach_cap\",\"unknown\":1}");
    defer p3.deinit();
    try testing.expectEqualStrings("attach_cap", p3.value.reason);
}

test "OpenFailed: round-trips, and an absent detail stays absent" {
    const alloc = testing.allocator;

    const json = try encodeJson(alloc, OpenFailed{
        .reason = OpenFailed.Reason.session_cap,
        .detail = "live=256/256 dead=3/256",
    });
    defer alloc.free(json);

    var parsed = try parseJson(OpenFailed, alloc, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("session_cap", parsed.value.reason);
    try testing.expectEqualStrings("live=256/256 dead=3/256", parsed.value.detail.?);

    // No detail is a legitimate refusal, not a malformed one.
    const bare = try encodeJson(alloc, OpenFailed{ .reason = OpenFailed.Reason.spawn_failed });
    defer alloc.free(bare);
    var p2 = try parseJson(OpenFailed, alloc, bare);
    defer p2.deinit();
    try testing.expectEqualStrings("spawn_failed", p2.value.reason);
    try testing.expect(p2.value.detail == null);

    // An unknown reason from a NEWER agent must parse, not fail: the client
    // renders the generic sentence for it rather than dropping the refusal and
    // falling back to a blank pane.
    var p3 = try parseJson(OpenFailed, alloc, "{\"reason\":\"quota_exceeded\",\"unknown\":1}");
    defer p3.deinit();
    try testing.expectEqualStrings("quota_exceeded", p3.value.reason);
}

test "RefusalCopy: copies, reports an empty detail as null, and truncates" {
    var c: RefusalCopy = .{};
    c.set("session_cap", "live=2/2");
    try testing.expectEqualStrings("session_cap", c.reason());
    try testing.expectEqualStrings("live=2/2", c.detail().?);

    // Empty and absent details are indistinguishable to a reader, on purpose.
    c.set("spawn_failed", null);
    try testing.expect(c.detail() == null);
    c.set("spawn_failed", "");
    try testing.expect(c.detail() == null);

    // Over-long fields truncate rather than fail — a refusal with a huge detail
    // is still a refusal, and a truncated tail beats a blank pane.
    const long_reason = "r" ** (RefusalCopy.reason_max + 17);
    const long_detail = "d" ** (RefusalCopy.detail_max + 400);
    c.set(long_reason, long_detail);
    try testing.expectEqual(RefusalCopy.reason_max, c.reason().len);
    try testing.expectEqual(RefusalCopy.detail_max, c.detail().?.len);

    // The same carrier serves an ATTACH refusal — that is the whole reason it
    // stopped being named after OPEN (T657).
    c.set(AttachFailed.Reason.malformed_request, "InvalidCharacter");
    try testing.expectEqualStrings("malformed_request", c.reason());
    try testing.expectEqualStrings("InvalidCharacter", c.detail().?);
    // ...and the old name still resolves to it.
    try testing.expectEqual(RefusalCopy, OpenFailedCopy);
}

test "negotiate: close_session capability is the intersection of both HELLOs" {
    const both = [_][]const u8{capability.close_session};
    const other = [_][]const u8{capability.rpc};

    // Both advertise → enabled.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(n.close_session);
    }
    // Only one side, or neither → disabled (never enable a one-sided capability).
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &both },
            .{ .transfer_encoding = .raw, .capabilities = &other },
        );
        try testing.expect(!n.close_session);
    }
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &other },
            .{ .transfer_encoding = .raw, .capabilities = &both },
        );
        try testing.expect(!n.close_session);
    }
    {
        // Older peers advertise no capabilities at all.
        const n = try negotiate(
            .{ .transfer_encoding = .raw },
            .{ .transfer_encoding = .raw },
        );
        try testing.expect(!n.close_session);
    }
}

test "negotiate: cpu_units gates the MEANING of an existing field" {
    // The skew this exists for: a pre-fix agent advertises everything it knows
    // about — including capabilities NEWER than the units fix would suggest — but
    // never `cpu_units`, because its `cpu_pct` is ~24x low on Apple Silicon.
    const modern = [_][]const u8{
        capability.close_session,
        capability.session_cpu,
        capability.cpu_units,
    };
    const pre_fix = [_][]const u8{
        capability.close_session,
        capability.session_cpu,
    };

    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &modern },
            .{ .transfer_encoding = .raw, .capabilities = &modern },
        );
        try testing.expect(n.cpu_units);
    }
    // New app + pre-fix agent: the app must NOT trust the numbers.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &modern },
            .{ .transfer_encoding = .raw, .capabilities = &pre_fix },
        );
        try testing.expect(!n.cpu_units);
        // ...and everything else the pre-fix agent DOES support keeps working:
        // a units skew degrades one column, it does not disable the connection.
        try testing.expect(n.close_session);
        try testing.expect(n.session_cpu);
    }
    // New agent + old app (an app that never learned the string): still false,
    // and harmless — an app that doesn't ask cannot be misled.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw, .capabilities = &pre_fix },
            .{ .transfer_encoding = .raw, .capabilities = &modern },
        );
        try testing.expect(!n.cpu_units);
    }
    // The oldest peers advertise nothing at all.
    {
        const n = try negotiate(
            .{ .transfer_encoding = .raw },
            .{ .transfer_encoding = .raw },
        );
        try testing.expect(!n.cpu_units);
    }
}

test "HELLO parse ignores unknown fields (forward-compat)" {
    const alloc = testing.allocator;
    const json =
        \\{"proto_version":1,"transfer_encoding":"raw","capabilities":["rpc"],"future_field":true}
    ;
    var parsed = try Hello.parse(alloc, json);
    defer parsed.deinit();
    try testing.expectEqual(TransferEncoding.raw, parsed.value.transfer_encoding);
}

test "HELLO build_version: additive + back-compat" {
    const alloc = testing.allocator;

    // A newer agent advertises its build stamp; it round-trips.
    const newer: Hello = .{ .transfer_encoding = .raw, .build_version = "20260718-574fe0805" };
    const nj = try newer.encode(alloc);
    defer alloc.free(nj);
    var np = try Hello.parse(alloc, nj);
    defer np.deinit();
    try testing.expectEqualStrings("20260718-574fe0805", np.value.build_version.?);

    // An OLDER peer's HELLO has no build_version → decodes to null, never a
    // parse error. What the app DOES with that null is `agent_upgrade.isStale`'s
    // business (it treats it as stale); all this layer promises is that the
    // absence decodes cleanly.
    const legacy =
        \\{"proto_version":1,"transfer_encoding":"raw","capabilities":["rpc"]}
    ;
    var lp = try Hello.parse(alloc, legacy);
    defer lp.deinit();
    try testing.expect(lp.value.build_version == null);

    // When null, the field is elided from the encoding (no wire bloat / a peer
    // that never sends it is byte-compatible with today).
    const bare: Hello = .{ .transfer_encoding = .raw };
    const bj = try bare.encode(alloc);
    defer alloc.free(bj);
    try testing.expect(std.mem.indexOf(u8, bj, "build_version") == null);
}

test "HELLO pty_flavor: additive + back-compat + unknown spelling (T471)" {
    const alloc = testing.allocator;

    // A newer agent says what its children run on; it round-trips as a value.
    const newer: Hello = .{
        .transfer_encoding = .raw,
        .pty_flavor = PtyFlavor.conpty.toString(),
    };
    const nj = try newer.encode(alloc);
    defer alloc.free(nj);
    try testing.expect(std.mem.indexOf(u8, nj, "\"pty_flavor\":\"conpty\"") != null);
    var np = try Hello.parse(alloc, nj);
    defer np.deinit();
    try testing.expectEqual(PtyFlavor.conpty, np.value.ptyFlavor().?);

    // An OLDER peer omits it → null, never a parse error. The reader's fallback
    // (the local machine's flavour) is `history_guard`'s business; all this
    // layer promises is that the absence decodes cleanly.
    const legacy =
        \\{"proto_version":1,"transfer_encoding":"raw","capabilities":["rpc"]}
    ;
    var lp = try Hello.parse(alloc, legacy);
    defer lp.deinit();
    try testing.expect(lp.value.pty_flavor == null);
    try testing.expect(lp.value.ptyFlavor() == null);

    // A FUTURE peer naming a flavour this build never heard of parses to null
    // rather than failing the HELLO — the reason the field is a string on the
    // wire and not an enum.
    const future =
        \\{"proto_version":1,"transfer_encoding":"raw","pty_flavor":"tty37"}
    ;
    var fp = try Hello.parse(alloc, future);
    defer fp.deinit();
    try testing.expectEqualStrings("tty37", fp.value.pty_flavor.?);
    try testing.expect(fp.value.ptyFlavor() == null);

    // Null ⇒ elided, so a peer that never sends it stays byte-identical to one
    // built before the field existed.
    const bare: Hello = .{ .transfer_encoding = .raw };
    const bj = try bare.encode(alloc);
    defer alloc.free(bj);
    try testing.expect(std.mem.indexOf(u8, bj, "pty_flavor") == null);

    // And the wire spellings themselves, pinned: they ARE the protocol.
    try testing.expectEqualStrings("conpty", PtyFlavor.conpty.toString());
    try testing.expectEqualStrings("posix", PtyFlavor.posix.toString());
    try testing.expectEqual(PtyFlavor.posix, PtyFlavor.fromString("posix").?);
    try testing.expect(PtyFlavor.fromString("") == null);
}

test "OPEN/ATTACHED JSON payloads round-trip with null elision" {
    const alloc = testing.allocator;

    const open: Open = .{ .rows = 24, .cols = 80, .command = "vim" };
    const oj = try encodeJson(alloc, open);
    defer alloc.free(oj);
    // null optionals (cwd, shell, name, argv) are elided.
    try testing.expect(std.mem.indexOf(u8, oj, "cwd") == null);
    try testing.expect(std.mem.indexOf(u8, oj, "argv") == null);
    var op = try parseJson(Open, alloc, oj);
    defer op.deinit();
    try testing.expectEqual(@as(u16, 24), op.value.rows);
    try testing.expectEqualStrings("vim", op.value.command.?);
    // env defaults to an empty slice (encoded as an empty array, harmless).
    try testing.expectEqual(@as(usize, 0), op.value.env.len);
    // argv defaults to null (no explicit shell integration argv rewrite, T04c).
    try testing.expect(op.value.argv == null);
    // pinned defaults to false (cross-machine / non-persistent, T11).
    try testing.expect(!op.value.pinned);

    // An OPEN pinning its session (T11, persistent local pane) round-trips true.
    const open_pin: Open = .{ .rows = 24, .cols = 80, .pinned = true };
    const pj = try encodeJson(alloc, open_pin);
    defer alloc.free(pj);
    try testing.expect(std.mem.indexOf(u8, pj, "\"pinned\":true") != null);
    var pp = try parseJson(Open, alloc, pj);
    defer pp.deinit();
    try testing.expect(pp.value.pinned);

    // An OPEN carrying an explicit shell argv (T04c) round-trips: the elements
    // survive encode→decode intact and in order (bash rewrite `<shell> --posix`).
    const argv = [_][]const u8{ "/opt/homebrew/bin/bash", "--posix" };
    const open_argv: Open = .{ .rows = 24, .cols = 80, .argv = &argv };
    const gj = try encodeJson(alloc, open_argv);
    defer alloc.free(gj);
    try testing.expect(std.mem.indexOf(u8, gj, "--posix") != null);
    var gp = try parseJson(Open, alloc, gj);
    defer gp.deinit();
    try testing.expect(gp.value.argv != null);
    try testing.expectEqual(@as(usize, 2), gp.value.argv.?.len);
    try testing.expectEqualStrings("/opt/homebrew/bin/bash", gp.value.argv.?[0]);
    try testing.expectEqualStrings("--posix", gp.value.argv.?[1]);

    // An OPEN carrying a forwarded env allowlist (T04a) round-trips: the pairs
    // survive encode→decode with keys/values intact and in order.
    const pairs = [_]Open.EnvPair{
        .{ .key = "GHOZTTY_WINDOW_NAME", .value = "0x00000000deadbeef" },
        .{ .key = "GHOZTTY_PANE_NAME", .value = "logs" },
    };
    const open_env: Open = .{ .rows = 24, .cols = 80, .env = &pairs };
    const ej = try encodeJson(alloc, open_env);
    defer alloc.free(ej);
    try testing.expect(std.mem.indexOf(u8, ej, "GHOZTTY_WINDOW_NAME") != null);
    var ep = try parseJson(Open, alloc, ej);
    defer ep.deinit();
    try testing.expectEqual(@as(usize, 2), ep.value.env.len);
    try testing.expectEqualStrings("GHOZTTY_WINDOW_NAME", ep.value.env[0].key);
    try testing.expectEqualStrings("0x00000000deadbeef", ep.value.env[0].value);
    try testing.expectEqualStrings("GHOZTTY_PANE_NAME", ep.value.env[1].key);
    try testing.expectEqualStrings("logs", ep.value.env[1].value);

    const att: Attached = .{ .status = .alive, .rows = 24, .cols = 80, .snapshot_at_offset = 42 };
    const aj = try encodeJson(alloc, att);
    defer alloc.free(aj);
    var ap = try parseJson(Attached, alloc, aj);
    defer ap.deinit();
    try testing.expectEqual(Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u64, 42), ap.value.snapshot_at_offset);
    // pid/tty default when omitted (an older agent's ATTACHED) — no error, no tty.
    try testing.expectEqual(@as(i64, 0), ap.value.pid);
    try testing.expect(ap.value.tty == null);
}

test "OPENED/ATTACHED/RELAUNCHED pid+tty round-trip and default when omitted" {
    const alloc = testing.allocator;

    // OPENED with tty (a POSIX agent) round-trips.
    const opened: Opened = .{ .session_id = "abc123", .pid = 4242, .tty = "/dev/ttys014" };
    const oj = try encodeJson(alloc, opened);
    defer alloc.free(oj);
    var op = try parseJson(Opened, alloc, oj);
    defer op.deinit();
    try testing.expectEqual(@as(i64, 4242), op.value.pid);
    try testing.expectEqualStrings("/dev/ttys014", op.value.tty.?);

    // OPENED without tty (a Windows or pre-field agent): null tty is elided on
    // encode and defaults to null on parse — version skew degrades cleanly.
    const opened_old: Opened = .{ .session_id = "abc123", .pid = 4242 };
    const yj = try encodeJson(alloc, opened_old);
    defer alloc.free(yj);
    try testing.expect(std.mem.indexOf(u8, yj, "tty") == null);
    var yp = try parseJson(Opened, alloc, yj);
    defer yp.deinit();
    try testing.expect(yp.value.tty == null);

    // ATTACHED alive carries pid + tty (the app-relaunch re-attach path).
    const att: Attached = .{ .status = .alive, .rows = 24, .cols = 80, .pid = 777, .tty = "/dev/ttys020" };
    const aj = try encodeJson(alloc, att);
    defer alloc.free(aj);
    var ap = try parseJson(Attached, alloc, aj);
    defer ap.deinit();
    try testing.expectEqual(@as(i64, 777), ap.value.pid);
    try testing.expectEqualStrings("/dev/ttys020", ap.value.tty.?);

    // ATTACHED dead carries the foreground command when a new agent sampled
    // one (T429), and defaults to null from an older agent — the viewer then
    // falls back to `argv` and, with neither, prints no command line at all.
    const att_fg: Attached = .{ .status = .dead, .argv = "sleep 600", .foreground_cmd = "claude --continue" };
    const fj = try encodeJson(alloc, att_fg);
    defer alloc.free(fj);
    var fp = try parseJson(Attached, alloc, fj);
    defer fp.deinit();
    try testing.expectEqualStrings("sleep 600", fp.value.argv.?);
    try testing.expectEqualStrings("claude --continue", fp.value.foreground_cmd.?);
    const att_old: Attached = .{ .status = .dead, .argv = "sleep 600" };
    const gj = try encodeJson(alloc, att_old);
    defer alloc.free(gj);
    try testing.expect(std.mem.indexOf(u8, gj, "foreground_cmd") == null);
    var gp = try parseJson(Attached, alloc, gj);
    defer gp.deinit();
    try testing.expect(gp.value.foreground_cmd == null);

    // RELAUNCHED carries the fresh pty's tty on ok; defaults null when omitted.
    const rel: Relaunched = .{ .session_id = "abc123", .ok = true, .pid = 99, .found = true, .tty = "/dev/ttys021" };
    const rj = try encodeJson(alloc, rel);
    defer alloc.free(rj);
    var rp = try parseJson(Relaunched, alloc, rj);
    defer rp.deinit();
    try testing.expectEqualStrings("/dev/ttys021", rp.value.tty.?);
    const rel_old: Relaunched = .{ .session_id = "abc123", .ok = true, .pid = 99, .found = true };
    const sj = try encodeJson(alloc, rel_old);
    defer alloc.free(sj);
    var sp = try parseJson(Relaunched, alloc, sj);
    defer sp.deinit();
    try testing.expect(sp.value.tty == null);
}

test "META foreground_pid and RELAUNCH env/term/argv round-trip with skew defaults (wp3)" {
    const alloc = testing.allocator;

    // META{foreground_pid} round-trips; omitted (older agent) defaults null.
    const meta: Meta = .{ .foreground_pid = 4321 };
    const mj = try encodeJson(alloc, meta);
    defer alloc.free(mj);
    var mp = try parseJson(Meta, alloc, mj);
    defer mp.deinit();
    try testing.expectEqual(@as(i64, 4321), mp.value.foreground_pid.?);
    var op = try parseJson(Meta, alloc, "{\"title\":\"hi\"}");
    defer op.deinit();
    try testing.expect(op.value.foreground_pid == null);

    // RELAUNCH respawn-fidelity fields round-trip.
    const pairs = [_]Open.EnvPair{
        .{ .key = "GHOZTTY_PANE_ID", .value = "ABC-123" },
    };
    const argv = [_][]const u8{ "/bin/bash", "--posix" };
    const rel: Relaunch = .{
        .session_id = "s1",
        .rows = 24,
        .cols = 80,
        .env = &pairs,
        .term = "xterm-256color",
        .argv = &argv,
    };
    const rj = try encodeJson(alloc, rel);
    defer alloc.free(rj);
    var rp = try parseJson(Relaunch, alloc, rj);
    defer rp.deinit();
    try testing.expectEqual(@as(usize, 1), rp.value.env.len);
    try testing.expectEqualStrings("GHOZTTY_PANE_ID", rp.value.env[0].key);
    try testing.expectEqualStrings("ABC-123", rp.value.env[0].value);
    try testing.expectEqualStrings("xterm-256color", rp.value.term.?);
    try testing.expectEqual(@as(usize, 2), rp.value.argv.?.len);

    // An OLD client's RELAUNCH (no fidelity fields) parses with empty/null
    // defaults — the agent then falls back to recorded metadata alone.
    var old = try parseJson(Relaunch, alloc, "{\"session_id\":\"s1\",\"rows\":24,\"cols\":80}");
    defer old.deinit();
    try testing.expectEqual(@as(usize, 0), old.value.env.len);
    try testing.expect(old.value.term == null);
    try testing.expect(old.value.argv == null);
}

test "META has_descendants: tri-state round-trip, absent means UNKNOWN (T356)" {
    const alloc = testing.allocator;

    // Both concrete values survive the wire in both directions.
    for ([_]bool{ true, false }) |want| {
        const meta: Meta = .{ .has_descendants = want };
        const j = try encodeJson(alloc, meta);
        defer alloc.free(j);
        var p = try parseJson(Meta, alloc, j);
        defer p.deinit();
        try testing.expectEqual(want, p.value.has_descendants.?);
    }

    // A `false` must be EMITTED, not elided: it is the value that skips the
    // close confirmation, and an encoder that dropped it would leave the client
    // at "unknown" forever and the feature silently dead.
    const idle: Meta = .{ .has_descendants = false };
    const ij = try encodeJson(alloc, idle);
    defer alloc.free(ij);
    try testing.expect(std.mem.indexOf(u8, ij, "has_descendants") != null);

    // An OLDER AGENT's META omits it entirely — which must parse as null
    // (unknown ⇒ the client keeps confirming), never as `false` (idle).
    var old = try parseJson(Meta, alloc, "{\"foreground_pid\":42}");
    defer old.deinit();
    try testing.expect(old.value.has_descendants == null);

    // And a META that carries ONLY this field must not disturb the others.
    var solo = try parseJson(Meta, alloc, "{\"has_descendants\":true}");
    defer solo.deinit();
    try testing.expect(solo.value.has_descendants.?);
    try testing.expect(solo.value.foreground_pid == null);
    try testing.expect(solo.value.cwd == null);
}

test "negotiate: session_busy is the intersection of both HELLOs (T356)" {
    const both = [_][]const u8{capability.session_busy};
    const other = [_][]const u8{capability.rpc};

    try testing.expect((try negotiate(
        .{ .transfer_encoding = .raw, .capabilities = &both },
        .{ .transfer_encoding = .raw, .capabilities = &both },
    )).session_busy);

    // One side only, or neither: never enable a one-sided capability — the
    // agent would sample for nobody, or the client would wait for a push that
    // never comes and read staleness as fact.
    try testing.expect(!(try negotiate(
        .{ .transfer_encoding = .raw, .capabilities = &both },
        .{ .transfer_encoding = .raw, .capabilities = &other },
    )).session_busy);
    try testing.expect(!(try negotiate(
        .{ .transfer_encoding = .raw, .capabilities = &other },
        .{ .transfer_encoding = .raw, .capabilities = &both },
    )).session_busy);
    try testing.expect(!(try negotiate(
        .{ .transfer_encoding = .raw },
        .{ .transfer_encoding = .raw },
    )).session_busy);
}

test "METRICS/HostMetrics JSON round-trips with null optional elision" {
    const alloc = testing.allocator;

    // A POSIX-shaped sample carries uptime + load1; a Windows-shaped one leaves
    // both null. Encode the latter and confirm the null optionals are elided.
    const m: Metrics = .{ .host = .{
        .cpu_pct = 12.5,
        .mem_used = 8 * 1024 * 1024 * 1024,
        .mem_total = 16 * 1024 * 1024 * 1024,
        .ncpu = 10,
    } };
    const mj = try encodeJson(alloc, m);
    defer alloc.free(mj);
    try testing.expect(std.mem.indexOf(u8, mj, "uptime_s") == null); // null elided
    try testing.expect(std.mem.indexOf(u8, mj, "load1") == null);

    var mp = try parseJson(Metrics, alloc, mj);
    defer mp.deinit();
    try testing.expectEqual(@as(f32, 12.5), mp.value.host.cpu_pct);
    try testing.expectEqual(@as(u32, 10), mp.value.host.ncpu);
    try testing.expectEqual(@as(u64, 16 * 1024 * 1024 * 1024), mp.value.host.mem_total);
    try testing.expect(mp.value.host.uptime_s == null);
    try testing.expect(mp.value.host.load1 == null);

    // With the POSIX optionals present they round-trip as set.
    const m2: Metrics = .{ .host = .{ .ncpu = 4, .uptime_s = 3600, .load1 = 0.75 } };
    const mj2 = try encodeJson(alloc, m2);
    defer alloc.free(mj2);
    var mp2 = try parseJson(Metrics, alloc, mj2);
    defer mp2.deinit();
    try testing.expectEqual(@as(u64, 3600), mp2.value.host.uptime_s.?);
    try testing.expectEqual(@as(f32, 0.75), mp2.value.host.load1.?);
}

test "PROC_SNAPSHOT/Proc JSON round-trips (incl. null cmd/user elision)" {
    const alloc = testing.allocator;

    const procs = [_]Proc{
        .{ .pid = 1, .ppid = 0, .name = "init", .cpu_pct = 0.0, .mem_bytes = 4096 },
        .{ .pid = 4321, .ppid = 1, .name = "zsh", .cpu_pct = 3.5, .mem_bytes = 2_000_000, .user = "alice", .cmd = "-zsh" },
    };
    const snap: ProcSnapshot = .{
        .ok = true,
        .host = .{ .ncpu = 8, .mem_total = 1024 },
        .procs = &procs,
        .truncated = false,
        .agent_pid = 4321,
    };
    const sj = try encodeJson(alloc, snap);
    defer alloc.free(sj);
    // The first proc's null user/cmd are elided; the second's are present.
    try testing.expect(std.mem.indexOf(u8, sj, "\"alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, sj, "\"-zsh\"") != null);

    var sp = try parseJson(ProcSnapshot, alloc, sj);
    defer sp.deinit();
    try testing.expect(sp.value.ok);
    try testing.expectEqual(@as(usize, 2), sp.value.procs.len);
    try testing.expectEqual(@as(i64, 1), sp.value.procs[0].pid);
    try testing.expectEqualStrings("init", sp.value.procs[0].name);
    try testing.expect(sp.value.procs[0].user == null);
    try testing.expect(sp.value.procs[0].cmd == null);
    try testing.expectEqualStrings("alice", sp.value.procs[1].user.?);
    try testing.expectEqualStrings("-zsh", sp.value.procs[1].cmd.?);
    try testing.expectEqual(@as(u32, 8), sp.value.host.ncpu);
    try testing.expectEqual(@as(i64, 4321), sp.value.agent_pid);

    // Back-compat: a snapshot JSON from an old agent (no agent_pid) parses with
    // agent_pid defaulting to 0.
    var old = try parseJson(ProcSnapshot, alloc, "{\"ok\":true,\"host\":{},\"procs\":[],\"truncated\":false}");
    defer old.deinit();
    try testing.expectEqual(@as(i64, 0), old.value.agent_pid);
}

test "PROC_KILL / PROC_SPAWN JSON payloads round-trip (incl. null elision)" {
    const alloc = testing.allocator;

    // PROC_KILL with an explicit signal, and the result with an error.
    const kill: ProcKill = .{ .pid = 1234, .signal = "KILL" };
    const kj = try encodeJson(alloc, kill);
    defer alloc.free(kj);
    var kp = try parseJson(ProcKill, alloc, kj);
    defer kp.deinit();
    try testing.expectEqual(@as(i64, 1234), kp.value.pid);
    try testing.expectEqualStrings("KILL", kp.value.signal.?);

    // PROC_KILL with no signal: the field is elided (null default at the agent).
    const kill2: ProcKill = .{ .pid = 5 };
    const kj2 = try encodeJson(alloc, kill2);
    defer alloc.free(kj2);
    try testing.expect(std.mem.indexOf(u8, kj2, "signal") == null);

    const kres: ProcKillResult = .{ .pid = 1234, .ok = false, .@"error" = "permission denied" };
    const krj = try encodeJson(alloc, kres);
    defer alloc.free(krj);
    var krp = try parseJson(ProcKillResult, alloc, krj);
    defer krp.deinit();
    try testing.expectEqual(@as(i64, 1234), krp.value.pid);
    try testing.expect(!krp.value.ok);
    try testing.expectEqualStrings("permission denied", krp.value.@"error".?);

    // A success result elides the error field.
    const kok: ProcKillResult = .{ .pid = 7, .ok = true };
    const koj = try encodeJson(alloc, kok);
    defer alloc.free(koj);
    try testing.expect(std.mem.indexOf(u8, koj, "error") == null);

    // PROC_SPAWN with a cwd; the result carries a pid.
    const spawn: ProcSpawn = .{ .cmd = "calc.exe", .cwd = "C:\\Users" };
    const sj = try encodeJson(alloc, spawn);
    defer alloc.free(sj);
    var sp = try parseJson(ProcSpawn, alloc, sj);
    defer sp.deinit();
    try testing.expectEqualStrings("calc.exe", sp.value.cmd);
    try testing.expectEqualStrings("C:\\Users", sp.value.cwd.?);
    try testing.expect(sp.value.detached); // default true

    const sres: ProcSpawnResult = .{ .ok = true, .pid = 4242 };
    const srj = try encodeJson(alloc, sres);
    defer alloc.free(srj);
    var srp = try parseJson(ProcSpawnResult, alloc, srj);
    defer srp.deinit();
    try testing.expect(srp.value.ok);
    try testing.expectEqual(@as(i64, 4242), srp.value.pid.?);
    try testing.expect(srp.value.@"error" == null);
}

test "CLOSE_SESSION / CLOSE_SESSION_RESULT JSON payloads round-trip" {
    const alloc = testing.allocator;

    // Request carries just the session id.
    const req: CloseSession = .{ .session_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    const rj = try encodeJson(alloc, req);
    defer alloc.free(rj);
    var rp = try parseJson(CloseSession, alloc, rj);
    defer rp.deinit();
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", rp.value.session_id);

    // A found + closed result.
    const ok: CloseSessionResult = .{ .session_id = "s1", .ok = true, .found = true };
    const oj = try encodeJson(alloc, ok);
    defer alloc.free(oj);
    var op = try parseJson(CloseSessionResult, alloc, oj);
    defer op.deinit();
    try testing.expectEqualStrings("s1", op.value.session_id);
    try testing.expect(op.value.ok);
    try testing.expect(op.value.found);

    // An unknown-id result: found=false, ok=false (defaults), round-trips intact.
    const gone: CloseSessionResult = .{ .session_id = "s2" };
    const gj = try encodeJson(alloc, gone);
    defer alloc.free(gj);
    var gp = try parseJson(CloseSessionResult, alloc, gj);
    defer gp.deinit();
    try testing.expect(!gp.value.ok);
    try testing.expect(!gp.value.found);
}

test "LIST_SESSIONS / SESSIONS JSON payloads round-trip (T10)" {
    const alloc = testing.allocator;

    // LIST_SESSIONS is an empty object today.
    const req: ListSessions = .{};
    const rj = try encodeJson(alloc, req);
    defer alloc.free(rj);
    try testing.expectEqualStrings("{}", rj);

    // A populated roster: alive + dead rows survive with all fields intact and in
    // order. `argv`/`title` null on the dead row are elided; `exit_code` present.
    const rows = [_]SessionInfo{
        .{
            .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .alive = true,
            .attached = true,
            .activity = "busy",
            .pid = 4242,
            .cwd = "/home/dev",
            .argv = "vim .",
            .title = "editor",
            .created_at = 1000,
            .last_activity = 2000,
            .pinned = true,
        },
        .{
            .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .alive = false,
            .exit_code = 137,
            .activity = "idle",
            .pid = 99,
            .unattached_since = 1234,
        },
    };
    const sessions: Sessions = .{ .sessions = &rows };
    const sj = try encodeJson(alloc, sessions);
    defer alloc.free(sj);
    var sp = try parseJson(Sessions, alloc, sj);
    defer sp.deinit();
    try testing.expectEqual(@as(usize, 2), sp.value.sessions.len);

    const a = sp.value.sessions[0];
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", a.id);
    try testing.expect(a.alive and a.attached);
    try testing.expectEqualStrings("busy", a.activity);
    try testing.expectEqual(@as(i64, 4242), a.pid);
    try testing.expectEqualStrings("/home/dev", a.cwd.?);
    try testing.expectEqualStrings("vim .", a.argv.?);
    try testing.expectEqualStrings("editor", a.title.?);
    try testing.expect(a.pinned); // pinned round-trips (T11)
    try testing.expect(a.unattached_since == null); // omitted → null (older agent, T534)

    const b = sp.value.sessions[1];
    try testing.expect(!b.alive);
    try testing.expectEqual(@as(?i64, 137), b.exit_code);
    try testing.expect(b.argv == null and b.title == null and b.cwd == null);
    try testing.expect(!b.pinned); // defaults false when omitted
    try testing.expectEqual(@as(?i64, 1234), b.unattached_since); // round-trips (T534)

    // An empty roster still encodes the array key (never elided) so the client can
    // tell "answered, none" from "no reply".
    const empty: Sessions = .{};
    const ej = try encodeJson(alloc, empty);
    defer alloc.free(ej);
    try testing.expectEqualStrings("{\"sessions\":[]}", ej);

    // A relaunchable dead tombstone (T12b) round-trips its marker.
    const reln = [_]SessionInfo{.{
        .id = "cccccccccccccccccccccccccccccccc",
        .alive = false,
        .pinned = true,
        .relaunchable = true,
        .argv = "sleep 600",
    }};
    const rjs = try encodeJson(alloc, Sessions{ .sessions = &reln });
    defer alloc.free(rjs);
    var rsp = try parseJson(Sessions, alloc, rjs);
    defer rsp.deinit();
    try testing.expect(!rsp.value.sessions[0].alive);
    try testing.expect(rsp.value.sessions[0].relaunchable);
    try testing.expect(rsp.value.sessions[0].exit_code == null);
}

test "SET_LAYOUT / LAYOUTS JSON payloads round-trip (T18)" {
    const alloc = testing.allocator;

    // A SET_LAYOUT upsert: opaque blob + the sessions it references, null
    // `delete` elided (default false), `session_ids` array in order.
    const ids = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };
    const set: SetLayout = .{
        .key = "11111111-2222-3333-4444-555555555555",
        .blob = "{\"tree\":\"opaque\"}",
        .session_ids = &ids,
    };
    const setj = try encodeJson(alloc, set);
    defer alloc.free(setj);
    // `delete` defaults false; the wire omits nothing important but `blob`/
    // `session_ids` must survive a round-trip in order.
    var setp = try parseJson(SetLayout, alloc, setj);
    defer setp.deinit();
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", setp.value.key);
    try testing.expectEqualStrings("{\"tree\":\"opaque\"}", setp.value.blob.?);
    try testing.expectEqual(@as(usize, 2), setp.value.session_ids.len);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", setp.value.session_ids[0]);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", setp.value.session_ids[1]);
    try testing.expect(!setp.value.delete);

    // A delete carries no blob; the blob key is elided (null optional).
    const del: SetLayout = .{ .key = "gone", .delete = true };
    const delj = try encodeJson(alloc, del);
    defer alloc.free(delj);
    try testing.expect(std.mem.indexOf(u8, delj, "\"blob\"") == null);
    var delp = try parseJson(SetLayout, alloc, delj);
    defer delp.deinit();
    try testing.expect(delp.value.delete);
    try testing.expect(delp.value.blob == null);

    // SET_LAYOUT_RESULT.
    const okj = try encodeJson(alloc, SetLayoutResult{ .ok = true });
    defer alloc.free(okj);
    var okp = try parseJson(SetLayoutResult, alloc, okj);
    defer okp.deinit();
    try testing.expect(okp.value.ok);

    // GET_LAYOUTS is an empty object.
    const gj = try encodeJson(alloc, GetLayouts{});
    defer alloc.free(gj);
    try testing.expectEqualStrings("{}", gj);

    // A populated LAYOUTS reply round-trips key+blob in order.
    const blobs = [_]LayoutBlob{
        .{ .key = "w1", .blob = "{\"a\":1}" },
        .{ .key = "w2", .blob = "{\"b\":2}" },
    };
    const lj = try encodeJson(alloc, Layouts{ .layouts = &blobs });
    defer alloc.free(lj);
    var lp = try parseJson(Layouts, alloc, lj);
    defer lp.deinit();
    try testing.expectEqual(@as(usize, 2), lp.value.layouts.len);
    try testing.expectEqualStrings("w1", lp.value.layouts[0].key);
    try testing.expectEqualStrings("{\"a\":1}", lp.value.layouts[0].blob);
    try testing.expectEqualStrings("w2", lp.value.layouts[1].key);

    // An empty layout set keeps the array key (never elided).
    const empty = try encodeJson(alloc, Layouts{});
    defer alloc.free(empty);
    try testing.expectEqualStrings("{\"layouts\":[]}", empty);
}

test "RELAUNCH / RELAUNCHED JSON payloads round-trip (T12b)" {
    const alloc = testing.allocator;

    // Request carries the session id + the attaching viewer's geometry.
    const req: Relaunch = .{ .session_id = "0123456789abcdef0123456789abcdef", .rows = 40, .cols = 120 };
    const rj = try encodeJson(alloc, req);
    defer alloc.free(rj);
    var rp = try parseJson(Relaunch, alloc, rj);
    defer rp.deinit();
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", rp.value.session_id);
    try testing.expectEqual(@as(u16, 40), rp.value.rows);
    try testing.expectEqual(@as(u16, 120), rp.value.cols);

    // A successful reply carries the fresh pid; found/ok both true.
    const ok_reply: Relaunched = .{ .session_id = req.session_id, .ok = true, .pid = 7777, .found = true };
    const oj = try encodeJson(alloc, ok_reply);
    defer alloc.free(oj);
    var op = try parseJson(Relaunched, alloc, oj);
    defer op.deinit();
    try testing.expect(op.value.ok and op.value.found);
    try testing.expectEqual(@as(i64, 7777), op.value.pid);
    try testing.expect(!op.value.replayed); // defaults false; absent → false

    // A reboot-scrollback reply sets replayed=true (T13) so the client suppresses
    // its own divider; it round-trips.
    const replayed_reply: Relaunched = .{ .session_id = req.session_id, .ok = true, .pid = 42, .found = true, .replayed = true };
    const pj = try encodeJson(alloc, replayed_reply);
    defer alloc.free(pj);
    var pp = try parseJson(Relaunched, alloc, pj);
    defer pp.deinit();
    try testing.expect(pp.value.replayed);

    // A "no such session" reply: ok=false, found=false, pid defaults 0.
    const gone: Relaunched = .{ .session_id = req.session_id };
    const gj = try encodeJson(alloc, gone);
    defer alloc.free(gj);
    var gp = try parseJson(Relaunched, alloc, gj);
    defer gp.deinit();
    try testing.expect(!gp.value.ok and !gp.value.found);
    try testing.expectEqual(@as(i64, 0), gp.value.pid);
}

test "JSON-RPC request/response envelope" {
    const alloc = testing.allocator;

    const req: RpcRequest = .{ .method = "remote.whoami", .id = 7 };
    const rj = try req.encode(alloc);
    defer alloc.free(rj);
    var rp = try parseJson(RpcRequest, alloc, rj);
    defer rp.deinit();
    try validateRequest(rp.value);
    try testing.expectEqualStrings("remote.whoami", rp.value.method);
    try testing.expectEqual(@as(i64, 7), rp.value.id.?);

    // A response with exactly one of result/error validates; both/neither fail.
    const ok: RpcResponse = .{ .result = .{ .bool = true }, .id = 7 };
    try validateResponse(ok);
    try testing.expectError(error.MalformedPayload, validateResponse(.{ .id = 7 }));
    try testing.expectError(error.MalformedPayload, validateResponse(.{
        .result = .{ .bool = true },
        .@"error" = .{ .code = rpc_error.internal_error, .message = "x" },
        .id = 7,
    }));

    // Wrong jsonrpc version is rejected.
    try testing.expectError(error.MalformedPayload, validateRequest(.{
        .jsonrpc = "1.0",
        .method = "x",
    }));
}

test "sequence spaces: frame seq monotonic, byte offset advances by bytes" {
    var seq: FrameSeq = .{};
    try testing.expectEqual(@as(u64, 0), seq.next());
    try testing.expectEqual(@as(u64, 1), seq.next());
    try testing.expectEqual(@as(u64, 2), seq.next());

    var off: ByteOffset = .{};
    try testing.expectEqual(@as(u64, 0), off.advance(10)); // first chunk starts at 0
    try testing.expectEqual(@as(u64, 10), off.advance(5)); // next at 10
    try testing.expectEqual(@as(u64, 15), off.value); // total advanced
}

test "two interleaved channels demux without cross-contamination" {
    const alloc = testing.allocator;
    // Frames for two different channels, interleaved on one wire. The Reader is
    // channel-agnostic (routing is the connection's job) but must preserve each
    // frame's channel id exactly so the connection can route correctly (§15 M3).
    const ch_a: u128 = 0xAAAA;
    const ch_b: u128 = 0xBBBB;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(alloc);

    var i: u64 = 0;
    while (i < 8) : (i += 1) {
        const ch = if (i % 2 == 0) ch_a else ch_b;
        try writeFrame(alloc, .cobs, .{
            .type = .data,
            .channel = ch,
            .seq = i,
            .payload = "\x00\x00\x00\x00\x00\x00\x00\x00pkt", // DATA: offset 0 + "pkt"
        }, &wire);
    }

    var reader = Reader.init(alloc, .cobs);
    defer reader.deinit();
    try reader.push(wire.items);

    i = 0;
    while (try reader.next()) |f| : (i += 1) {
        const expected_ch = if (i % 2 == 0) ch_a else ch_b;
        try testing.expectEqual(expected_ch, f.channel);
        const dp = try DataPayload.decode(f.payload);
        try testing.expectEqualSlices(u8, "pkt", dp.bytes);
    }
    try testing.expectEqual(@as(u64, 8), i);
}

test "hostile-remote corpus: arbitrary garbage never panics" {
    const alloc = testing.allocator;
    // A deterministic PRNG (no Date/random reliance) fuzzes the demux with random
    // bytes, truncated frames, and bit-flipped valid frames. The contract: every
    // `next()` either yields a structurally-valid frame or returns a ProtocolError
    // — never a crash, hang, or OOB read (§15 M3, "fuzz the client demux").
    var prng = std.Random.DefaultPrng.init(0x9E37_79B9_7F4A_7C15);
    const rand = prng.random();

    for (all_encodings) |enc| {
        var round: usize = 0;
        while (round < 400) : (round += 1) {
            var reader = Reader.init(alloc, enc);
            defer reader.deinit();

            // Build a noisy buffer: some valid frames, some pure noise.
            var noise: std.ArrayList(u8) = .empty;
            defer noise.deinit(alloc);

            const segments = rand.intRangeAtMost(usize, 1, 6);
            var s: usize = 0;
            while (s < segments) : (s += 1) {
                if (rand.boolean()) {
                    // A valid frame with a random (possibly unknown-to-decode) type byte.
                    const payload_len = rand.intRangeAtMost(usize, 0, 48);
                    const payload = try alloc.alloc(u8, payload_len);
                    defer alloc.free(payload);
                    rand.bytes(payload);
                    const frame: Frame = .{
                        .type = .data,
                        .channel = rand.int(u128),
                        .seq = rand.int(u64),
                        .payload = payload,
                    };
                    const before = noise.items.len;
                    try writeFrame(alloc, enc, frame, &noise);
                    // Randomly corrupt one byte of the just-written frame.
                    if (rand.boolean() and noise.items.len > before) {
                        const idx = rand.intRangeLessThan(usize, before, noise.items.len);
                        noise.items[idx] ^= @as(u8, 1) << @intCast(rand.intRangeLessThan(u8, 0, 8));
                    }
                } else {
                    // Pure random noise.
                    const n = rand.intRangeAtMost(usize, 0, 64);
                    const junk = try alloc.alloc(u8, n);
                    defer alloc.free(junk);
                    rand.bytes(junk);
                    try noise.appendSlice(alloc, junk);
                }
            }

            // Feed it in random-sized chunks and drain. We don't assert *what*
            // comes out, only that nothing crashes and errors are surfaced cleanly.
            var pos: usize = 0;
            while (pos < noise.items.len) {
                const chunk = @min(
                    noise.items.len - pos,
                    rand.intRangeAtMost(usize, 1, 17),
                );
                reader.push(noise.items[pos .. pos + chunk]) catch unreachable;
                pos += chunk;
                while (true) {
                    const r = reader.next() catch break; // a clean protocol error
                    if (r) |_| continue else break; // null → need more bytes
                }
            }
        }
    }
}

test "hostile DATA payloads never over-read" {
    // Any payload < 8 bytes must be a clean MalformedPayload, never an OOB slice.
    const shorts = [_][]const u8{ "", "a", "1234567" };
    for (shorts) |p| {
        try testing.expectError(error.MalformedPayload, DataPayload.decode(p));
    }
    // Exactly 8 bytes → empty data, valid.
    const dp = try DataPayload.decode("\x00\x00\x00\x00\x00\x00\x00\x01");
    try testing.expectEqual(@as(u64, 1), dp.byte_offset);
    try testing.expectEqual(@as(usize, 0), dp.bytes.len);
}
