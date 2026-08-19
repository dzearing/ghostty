//! Pure UTF-16 → UTF-8 conversion for win32 control text (T989): the one
//! bounded, non-panicking way to move what `GetWindowTextW` (or any other
//! wide-string API) handed us into a fixed byte buffer.
//!
//! ## Why this is not `std.unicode.utf16LeToUtf8`
//!
//! `utf16LeToUtf8` does NOT check its destination. Its error set covers
//! malformed UTF-16 only — a dangling surrogate half — so the `catch` that
//! every call site here was written with reads like an overflow guard and is
//! not one. When the destination is too small the ASCII fast path writes past
//! the end of the slice and the tail path `assert`s inside `utf8Encode`
//! (`std/unicode.zig:55`): `panic: reached unreachable code` in a Debug build,
//! a silent buffer overrun in a release one.
//!
//! That is not a theoretical edge. The Activity Monitor's filter box read a
//! 256-unit wide buffer into a 128-byte needle, so about 130 typed characters
//! — or one pasted path — took the whole terminal down, every pane in every
//! window with it. UTF-8 needs up to **three bytes per UTF-16 unit** (and a
//! surrogate pair costs four bytes for two units), so a destination sized by
//! what the author expected someone to type is a crash with a threshold.
//!
//! ## What this does instead
//!
//! Convert as much as fits and stop, always on a codepoint boundary: a filter
//! that is too long filters on its first N characters, which is the behavior
//! the truncating call sites already claimed to have. Never a partial UTF-8
//! sequence, never a write past `out`, never a panic — a text field is the
//! last place in the app that should be able to end the process.
//!
//! No OS imports, so it runs in every app-runtime test lane — same deal as
//! `text_search.zig` and `activity_rows.zig`.

const std = @import("std");
const testing = std.testing;

/// Convert `wide` (UTF-16LE) into `out` as UTF-8, truncating on a codepoint
/// boundary when it does not all fit. Returns the number of bytes written.
///
/// Truncation is silent by design: the callers are text fields, where showing
/// the first N characters' worth of an over-long entry beats both a crash and
/// a field that mysteriously reads as empty.
///
/// Malformed UTF-16 (a dangling or unpaired surrogate half) stops the
/// conversion at the bad unit and keeps everything before it, rather than
/// discarding the whole string the way a `catch ""` did. A wide buffer that
/// `GetWindowTextW` itself truncated can end in exactly that half pair, and
/// blanking the user's filter because their last character was an emoji is a
/// worse answer than dropping the emoji.
pub fn toUtf8Truncating(out: []u8, wide: []const u16) usize {
    return toUtf8Counting(out, wide).bytes;
}

/// What one `toUtf8Counting` pass moved. `units` is what a caller that must
/// not lose text needs in order to continue from where the destination ran
/// out (the IME commit path does exactly that).
pub const Converted = struct {
    /// Bytes written to `out`.
    bytes: usize,
    /// UTF-16 units of `wide` that produced them — always a codepoint
    /// boundary, so `wide[units..]` is a well-formed continuation.
    units: usize,
    /// True when all of `wide` was converted. False means the destination
    /// filled up, or the source held a malformed surrogate.
    complete: bool,
};

/// `toUtf8Truncating`, plus how much of the source it got through.
pub fn toUtf8Counting(out: []u8, wide: []const u16) Converted {
    var n: usize = 0;
    var units: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(wide);
    while (true) {
        const cp = (it.nextCodepoint() catch break) orelse break;
        const need = std.unicode.utf8CodepointSequenceLength(cp) catch break;
        if (n + need > out.len) break;
        n += std.unicode.utf8Encode(cp, out[n..]) catch break;
        // `it.i` is a BYTE index into the source, and only advances on a
        // whole codepoint — so this is the unit count of what is now in
        // `out`, recorded after the encode so a codepoint that did not fit
        // is not counted as consumed.
        units = it.i / 2;
    }
    return .{ .bytes = n, .units = units, .complete = units == wide.len };
}

/// Convert `wide` into `out` only if ALL of it fits; otherwise write nothing
/// meaningful and return 0.
///
/// This is the other half of the sizing rule, for the call sites whose text
/// is an identity rather than a search: a truncated device name, host name,
/// path or command is a DIFFERENT one, so those readers documented
/// themselves as returning "0 when it does not fit" long before anything
/// made that true. Malformed UTF-16 also returns 0 here — half a name is the
/// same problem as a short one.
///
/// `out` may be partially written when the answer is 0; callers read
/// `out[0..n]`, so there is nothing to see.
pub fn toUtf8AllOrNothing(out: []u8, wide: []const u16) usize {
    const r = toUtf8Counting(out, wide);
    return if (r.complete) r.bytes else 0;
}

test "toUtf8Truncating: ASCII that fits is copied whole" {
    var out: [16]u8 = undefined;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("ghoztty");
    const n = toUtf8Truncating(&out, wide);
    try testing.expectEqualStrings("ghoztty", out[0..n]);
}

test "toUtf8Truncating: empty input writes nothing" {
    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), toUtf8Truncating(&out, &.{}));
    try testing.expectEqual(@as(usize, 0), toUtf8Truncating(out[0..0], &.{}));
}

test "toUtf8Truncating: ASCII longer than the destination truncates, never overruns" {
    // The T989 repro in miniature: more source than destination. The old
    // `utf16LeToUtf8` panicked here instead of returning.
    var wide: [130]u16 = @splat('a');
    var out: [8]u8 = undefined;
    const n = toUtf8Truncating(&out, &wide);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualStrings("aaaaaaaa", out[0..n]);
}

test "toUtf8Truncating: a zero-length destination takes nothing" {
    var out: [0]u8 = undefined;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("nope");
    try testing.expectEqual(@as(usize, 0), toUtf8Truncating(&out, wide));
}

test "toUtf8Truncating: a multi-byte codepoint that does not fit is dropped whole" {
    // `é` is two bytes (C3 A9). With one byte left the whole character has to
    // go: half a sequence in a needle is a filter that matches nothing and a
    // string no logger can print.
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("aé");
    var out: [2]u8 = undefined;
    const n = toUtf8Truncating(&out, wide);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("a", out[0..n]);
    // One more byte and it fits exactly.
    var out3: [3]u8 = undefined;
    const n3 = toUtf8Truncating(&out3, wide);
    try testing.expectEqualStrings("aé", out3[0..n3]);
}

test "toUtf8Truncating: a surrogate pair is kept or dropped as one character" {
    // U+1F600 is one codepoint, two UTF-16 units, four UTF-8 bytes.
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("x\u{1F600}");
    var out: [4]u8 = undefined; // room for `x` + 3 of the emoji's 4 bytes
    const n = toUtf8Truncating(&out, wide);
    try testing.expectEqualStrings("x", out[0..n]);
    var out5: [5]u8 = undefined;
    const n5 = toUtf8Truncating(&out5, wide);
    try testing.expectEqualStrings("x\u{1F600}", out5[0..n5]);
}

test "toUtf8Truncating: filling the destination exactly writes the last byte" {
    var out: [7]u8 = undefined;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("ghoztty");
    try testing.expectEqual(@as(usize, 7), toUtf8Truncating(&out, wide));
    try testing.expectEqualStrings("ghoztty", &out);
}

test "toUtf8Truncating: a dangling surrogate half keeps the text before it" {
    // What a wide buffer truncated mid-emoji by GetWindowTextW looks like.
    const wide = [_]u16{ 'h', 'i', 0xD83D };
    var out: [8]u8 = undefined;
    const n = toUtf8Truncating(&out, &wide);
    try testing.expectEqualStrings("hi", out[0..n]);
}

test "toUtf8Counting: a full conversion reports every unit and completeness" {
    var out: [16]u8 = undefined;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("ghoztty");
    const r = toUtf8Counting(&out, wide);
    try testing.expectEqual(@as(usize, 7), r.bytes);
    try testing.expectEqual(@as(usize, 7), r.units);
    try testing.expect(r.complete);
}

test "toUtf8Counting: a truncated conversion names where to resume" {
    // Three three-byte characters into eight bytes: two fit, and `units`
    // points at the third so a chunking caller loses nothing.
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("日本語");
    var out: [8]u8 = undefined;
    const r = toUtf8Counting(&out, wide);
    try testing.expectEqual(@as(usize, 6), r.bytes);
    try testing.expectEqual(@as(usize, 2), r.units);
    try testing.expect(!r.complete);
    // The continuation converts the rest.
    const rest = toUtf8Counting(&out, wide[r.units..]);
    try testing.expectEqualStrings("語", out[0..rest.bytes]);
    try testing.expect(rest.complete);
}

test "toUtf8Counting: a surrogate pair counts as its two units" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("x\u{1F600}y");
    var out: [5]u8 = undefined; // x + the emoji, no room for y
    const r = toUtf8Counting(&out, wide);
    try testing.expectEqualStrings("x\u{1F600}", out[0..r.bytes]);
    try testing.expectEqual(@as(usize, 3), r.units);
    try testing.expect(!r.complete);
}

test "toUtf8Counting: a dangling surrogate half is incomplete, not a panic" {
    const wide = [_]u16{ 'h', 'i', 0xD83D };
    var out: [8]u8 = undefined;
    const r = toUtf8Counting(&out, &wide);
    try testing.expectEqualStrings("hi", out[0..r.bytes]);
    try testing.expectEqual(@as(usize, 2), r.units);
    try testing.expect(!r.complete);
}

test "toUtf8AllOrNothing: everything that fits is converted whole" {
    var out: [16]u8 = undefined;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\dave");
    const n = toUtf8AllOrNothing(&out, wide);
    try testing.expectEqualStrings("C:\\Users\\dave", out[0..n]);
}

test "toUtf8AllOrNothing: one byte short answers 0 rather than half a name" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("workstation");
    var out: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), toUtf8AllOrNothing(&out, wide));
    var exact: [11]u8 = undefined;
    try testing.expectEqual(@as(usize, 11), toUtf8AllOrNothing(&exact, wide));
}

test "toUtf8AllOrNothing: malformed UTF-16 answers 0" {
    const wide = [_]u16{ 'p', 'c', 0xDC00 }; // lone low surrogate
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), toUtf8AllOrNothing(&out, &wide));
}

test "toUtf8AllOrNothing: empty input is a complete conversion of nothing" {
    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), toUtf8AllOrNothing(&out, &.{}));
}

test "toUtf8Truncating: three-byte characters cost three bytes each" {
    // The worst per-unit ratio in the BMP, which is what sizes every
    // destination in this codebase: 256 units can need 768 bytes.
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("日本語");
    try testing.expectEqual(@as(usize, 3), wide.len);
    var out: [9]u8 = undefined;
    try testing.expectEqual(@as(usize, 9), toUtf8Truncating(&out, wide));
    var out8: [8]u8 = undefined;
    const n8 = toUtf8Truncating(&out8, wide);
    try testing.expectEqual(@as(usize, 6), n8);
    try testing.expectEqualStrings("日本", out8[0..n8]);
}
