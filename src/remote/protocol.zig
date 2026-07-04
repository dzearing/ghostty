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

const std = @import("std");
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

    data = 0x10, // both {byte_offset, bytes} for `channel`
    resize = 0x11, // C→A  {rows, cols, px_w, px_h}
    signal = 0x12, // C→A  {name}
    detach = 0x13, // C→A  stop streaming; keep session alive
    close = 0x14, // C→A  terminate the session's container, free it

    exit = 0x20, // A→C  {code, runtime_ms} (ordered after final DATA)
    meta = 0x21, // A→C  {cwd?, title?, listening_ports?, foreground_cmd?}

    get_cwd = 0x22, // C→A  {session_id}  on-demand "what is this session's cwd?"
    cwd = 0x23, // A→C  {session_id, path?, ok}  reply to GET_CWD

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
};

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

    /// Serialize to a JSON byte slice owned by `alloc`.
    pub fn encode(self: Hello, alloc: Allocator) Allocator.Error![]u8 {
        return std.json.Stringify.valueAlloc(alloc, self, .{});
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
};

/// Negotiate the local and remote `HELLO`s. v1 policy is strict: both sides must
/// agree on the exact `proto_version` and `transfer_encoding` (the encoding is
/// chosen by the side that knows the hop is a Windows hop and proposed in its
/// `HELLO`; the other side echoes it). A mismatch is fatal (§4.2 "mismatch → drop").
pub fn negotiate(local: Hello, remote: Hello) ProtocolError!Negotiated {
    if (local.proto_version != remote.proto_version) return error.Incompatible;
    if (local.transfer_encoding != remote.transfer_encoding) return error.Incompatible;
    return .{
        .proto_version = local.proto_version,
        .transfer_encoding = local.transfer_encoding,
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

    pub const EnvPair = struct { key: []const u8, value: []const u8 };
};

/// `OPENED` (0x02).
pub const Opened = struct {
    session_id: []const u8,
    pid: i64,
};

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
pub const Cwd = struct {
    session_id: []const u8,
    path: ?[]const u8 = null,
    ok: bool = false,
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

test "HELLO parse ignores unknown fields (forward-compat)" {
    const alloc = testing.allocator;
    const json =
        \\{"proto_version":1,"transfer_encoding":"raw","capabilities":["rpc"],"future_field":true}
    ;
    var parsed = try Hello.parse(alloc, json);
    defer parsed.deinit();
    try testing.expectEqual(TransferEncoding.raw, parsed.value.transfer_encoding);
}

test "OPEN/ATTACHED JSON payloads round-trip with null elision" {
    const alloc = testing.allocator;

    const open: Open = .{ .rows = 24, .cols = 80, .command = "vim" };
    const oj = try encodeJson(alloc, open);
    defer alloc.free(oj);
    // null optionals (cwd, shell, name) are elided.
    try testing.expect(std.mem.indexOf(u8, oj, "cwd") == null);
    var op = try parseJson(Open, alloc, oj);
    defer op.deinit();
    try testing.expectEqual(@as(u16, 24), op.value.rows);
    try testing.expectEqualStrings("vim", op.value.command.?);

    const att: Attached = .{ .status = .alive, .rows = 24, .cols = 80, .snapshot_at_offset = 42 };
    const aj = try encodeJson(alloc, att);
    defer alloc.free(aj);
    var ap = try parseJson(Attached, alloc, aj);
    defer ap.deinit();
    try testing.expectEqual(Attached.AttachStatus.alive, ap.value.status);
    try testing.expectEqual(@as(u64, 42), ap.value.snapshot_at_offset);
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
    var old = try parseJson(ProcSnapshot, alloc,
        "{\"ok\":true,\"host\":{},\"procs\":[],\"truncated\":false}");
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
