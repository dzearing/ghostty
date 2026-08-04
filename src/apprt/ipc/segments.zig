//! The `+send-keys` `--segments=` wire format: argument boundaries that
//! survive the trip from the CLI to the app that owns the pane.
//!
//! `+send-keys --target=t "some message" Enter` used to flatten every
//! positional into one `--keys=` payload, so the pane received a single burst
//! of bytes ending in `\r`. A TUI's paste detection reads that trailing `\r`
//! as a newline *inside* pasted text — correctly, since that is exactly what
//! a real multi-line paste looks like — and the message stays in the
//! composer. Carrying the boundaries lets the server frame the text runs as a
//! bracketed paste and write the key runs bare, so the `\r` after the closing
//! fencepost is unambiguously a keypress.
//!
//! Format: one segment per comma-separated field, each a kind tag (`t` for
//! text, `k` for keys) followed by that segment's bytes in lowercase hex.
//! Hex because the payload travels as a JSON string and these bytes are
//! arbitrary — control characters and non-UTF-8 sequences are exactly what
//! `+send-keys` exists to deliver, and neither survives that trip raw.
//!
//! `--segments=` is always sent ALONGSIDE the flat `--keys=`, never instead
//! of it, and only when there is a boundary worth preserving. An app older
//! than the CLI driving it ignores the field it does not know and behaves
//! exactly as it did before (the agent-contract rule: readers tolerate
//! absent fields and ignore unknown ones).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The IPC argument this module encodes and decodes.
pub const prefix = "--segments=";

/// How the receiving program should understand a run of bytes.
pub const Kind = enum {
    /// Content, from a text positional. Delivered as a paste.
    text,
    /// A keypress, from `Enter` / `C-c` / `Tab` / … Delivered bare.
    key,

    /// The tag this kind is encoded with on the wire.
    pub fn tag(self: Kind) u8 {
        return switch (self) {
            .text => 't',
            .key => 'k',
        };
    }

    /// The kind a wire tag names, or null for a tag this build does not
    /// know — a newer CLI may name a kind that did not exist here.
    pub fn fromTag(t: u8) ?Kind {
        return switch (t) {
            't' => .text,
            'k' => .key,
            else => null,
        };
    }
};

/// A run of resolved bytes, tagged with how it should be delivered.
pub const Segment = struct {
    kind: Kind,
    bytes: []const u8,
};

/// Encode segments as the `--segments=` IPC argument.
pub fn encode(alloc: Allocator, segments: []const Segment) Allocator.Error![:0]const u8 {
    const hex = "0123456789abcdef";

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, prefix);

    for (segments, 0..) |segment, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, segment.kind.tag());
        for (segment.bytes) |byte| {
            try out.append(alloc, hex[byte >> 4]);
            try out.append(alloc, hex[byte & 0x0f]);
        }
    }

    return try out.toOwnedSliceSentinel(alloc, 0);
}

pub const DecodeError = error{Malformed} || Allocator.Error;

/// Decode a `--segments=` VALUE (everything after the prefix) into segments.
///
/// Returns `error.Malformed` for anything the encoder above could not have
/// produced: an unknown kind tag, an odd number of hex digits, a non-hex
/// digit, or an empty field. A caller that gets it should fall back to the
/// flat `--keys=` payload rather than fail the request — the bytes are the
/// same either way, only the framing is lost.
///
/// An empty value decodes to zero segments, not an error: it is what an
/// all-empty send would encode to.
///
/// Segment bytes are allocated from `alloc`; pass an arena, or free via
/// `freeSegments`.
pub fn decode(alloc: Allocator, value: []const u8) DecodeError![]Segment {
    var out: std.ArrayList(Segment) = .empty;
    errdefer {
        for (out.items) |segment| alloc.free(segment.bytes);
        out.deinit(alloc);
    }

    if (value.len == 0) return try out.toOwnedSlice(alloc);

    var fields = std.mem.splitScalar(u8, value, ',');
    while (fields.next()) |field| {
        if (field.len == 0) return error.Malformed;
        const kind = Kind.fromTag(field[0]) orelse return error.Malformed;

        const digits = field[1..];
        if (digits.len % 2 != 0) return error.Malformed;

        const bytes = try alloc.alloc(u8, digits.len / 2);
        errdefer alloc.free(bytes);
        for (bytes, 0..) |*byte, i| {
            const hi = hexDigit(digits[i * 2]) orelse return error.Malformed;
            const lo = hexDigit(digits[i * 2 + 1]) orelse return error.Malformed;
            byte.* = (hi << 4) | lo;
        }

        try out.append(alloc, .{ .kind = kind, .bytes = bytes });
    }

    return try out.toOwnedSlice(alloc);
}

/// Free what `decode` allocated.
pub fn freeSegments(alloc: Allocator, segments: []Segment) void {
    for (segments) |segment| alloc.free(segment.bytes);
    alloc.free(segments);
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        // Uppercase is not what `encode` emits, but accepting it costs
        // nothing and a hand-written request is a legitimate caller.
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

test "encode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("--segments=t6869,k0d", try encode(alloc, &.{
        .{ .kind = .text, .bytes = "hi" },
        .{ .kind = .key, .bytes = "\r" },
    }));
}

test "decode round-trips what encode produced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Bytes a real send carries: a non-UTF-8 tail and control characters,
    // which is why the format is hex in the first place.
    const original: []const Segment = &.{
        .{ .kind = .text, .bytes = "hello\x00\xff world" },
        .{ .kind = .key, .bytes = "\r\x03" },
        .{ .kind = .text, .bytes = "tail" },
    };

    const encoded = try encode(alloc, original);
    const decoded = try decode(alloc, encoded[prefix.len..]);

    try std.testing.expectEqual(original.len, decoded.len);
    for (original, decoded) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqualStrings(want.bytes, got.bytes);
    }
}

test "decode: an empty value is zero segments, not an error" {
    const decoded = try decode(std.testing.allocator, "");
    defer freeSegments(std.testing.allocator, decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "decode: an empty segment carries no bytes but keeps its kind" {
    const decoded = try decode(std.testing.allocator, "t");
    defer freeSegments(std.testing.allocator, decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(Kind.text, decoded[0].kind);
    try std.testing.expectEqual(@as(usize, 0), decoded[0].bytes.len);
}

test "decode: malformed input is rejected, never half-applied" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "x6869", // unknown kind tag
        "t686", // odd digit count
        "t68g9", // non-hex digit
        "t6869,", // empty trailing field
        ",k0d", // empty leading field
        "6869", // no kind tag (first digit reads as one)
    }) |bad| {
        try std.testing.expectError(error.Malformed, decode(alloc, bad));
    }
}

test "decode: uppercase hex is accepted" {
    const decoded = try decode(std.testing.allocator, "tFF");
    defer freeSegments(std.testing.allocator, decoded);
    try std.testing.expectEqual(@as(u8, 0xff), decoded[0].bytes[0]);
}
