//! Byte offsets in a UTF-8 buffer ⇄ character indices in a Windows edit
//! control (T648).
//!
//! Pure — bytes in, numbers out, no OS surface — so it is unit tested in the
//! `-Dapp-runtime=none` lane like its siblings.
//!
//! ## Why this exists
//!
//! Every pure module behind the feedback composer works in BYTES, and it is
//! right to: it operates on the pane's UTF-8 buffer, which is also what the
//! report is written from. Every win32 edit message — `EM_EXSETSEL`,
//! `EM_EXGETSEL`, `EM_POSFROMCHAR` — works in UTF-16 CODE UNITS, because that
//! is what a `W` control stores.
//!
//! Those two numbers are the same number **only for ASCII**. `é` is 2 bytes
//! and 1 unit; `世` is 3 bytes and 1 unit; `😀` is 4 bytes and 2 units. The
//! composer used to hand a byte offset straight to `EM_EXSETSEL`, so a quote
//! or an image chip inserted below any non-English text landed short by the
//! accumulated difference — silent corruption of what the user wrote, and
//! invisible to anyone typing plain English.
//!
//! This module is the conversion at that boundary, in both directions. It is
//! the ONLY home for it: the address bar (`ViewerNavBar`) and the banner
//! editor (`BannerDialog`) only ever select all (`EM_SETSEL 0, -1`), so they
//! never compute an offset and never needed one.
//!
//! ## Line endings are already 1:1
//!
//! RichEdit reports a paragraph mark as a bare CR and `readBack` canonicalises
//! it to LF one-for-one (`EM_GETTEXTEX`/`GT_DEFAULT`, never `WM_GETTEXT`,
//! which expands each mark to CR+LF). So a line break is one byte and one
//! unit, and this module has nothing to say about it — it converts encodings,
//! not line endings.
//!
//! ## Malformed input is clamped, never fatal
//!
//! The buffer comes from `utf16LeToUtf8Alloc` and is well-formed, but a
//! composer must not be able to crash on a stray byte. An invalid lead byte is
//! counted as one byte and one unit and the walk carries on; an offset that
//! lands mid-sequence, or past the end, is clamped to the nearest character
//! boundary at or before it. Both directions therefore always answer, and
//! always answer with a boundary.
const std = @import("std");

/// How many UTF-16 code units of `text` precede byte offset `byte`.
///
/// The number to put in a `CHARRANGE` when the offset came out of a pure
/// module. An offset past the end answers for the whole text; one that lands
/// inside a multi-byte sequence answers for the characters strictly before it,
/// never half of one.
pub fn unitsBeforeByte(text: []const u8, byte: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < text.len and i < byte) {
        const len = seqLen(text[i]);
        // A sequence that would straddle the requested offset stops the walk:
        // the caller asked for a position, and the position before this
        // character is the only boundary at or before it.
        if (i + len > byte) break;
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return units;
}

/// The inverse: the byte offset into `text` that is `units` UTF-16 code units
/// in.
///
/// The number to feed a pure module when the index came out of the control. A
/// `units` past the end answers `text.len`; one that lands between the halves
/// of a surrogate pair answers the byte offset of that character's start,
/// because there is no byte offset between them.
pub fn byteForUnits(text: []const u8, units: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len and seen < units) {
        const len = seqLen(text[i]);
        const w: usize = if (len == 4) 2 else 1;
        // The second half of a surrogate pair is not a boundary; stop before
        // the character rather than inside it.
        if (seen + w > units) break;
        seen += w;
        i += len;
    }
    return i;
}

/// How many UTF-16 code units the whole of `text` is.
pub fn unitLen(text: []const u8) usize {
    return unitsBeforeByte(text, text.len);
}

/// The length of the UTF-8 sequence a lead byte opens. An invalid lead byte —
/// a continuation byte on its own, or `0xF8`+ — answers 1, which is what keeps
/// the walk moving through malformed input instead of stalling or running off
/// the end.
fn seqLen(lead: u8) usize {
    return switch (lead) {
        0x00...0x7F => 1,
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF7 => 4,
        else => 1,
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "ascii: bytes and units are the same number" {
    const s = "hello world";
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        try testing.expectEqual(i, unitsBeforeByte(s, i));
        try testing.expectEqual(i, byteForUnits(s, i));
    }
    try testing.expectEqual(@as(usize, 11), unitLen(s));
}

test "latin-1: two bytes, one unit" {
    const s = "h\u{e9}llo"; // h é l l o -> 6 bytes, 5 units
    try testing.expectEqual(@as(usize, 6), s.len);
    try testing.expectEqual(@as(usize, 5), unitLen(s));

    try testing.expectEqual(@as(usize, 1), unitsBeforeByte(s, 1)); // before é
    try testing.expectEqual(@as(usize, 2), unitsBeforeByte(s, 3)); // after é
    try testing.expectEqual(@as(usize, 5), unitsBeforeByte(s, 6));

    try testing.expectEqual(@as(usize, 1), byteForUnits(s, 1));
    try testing.expectEqual(@as(usize, 3), byteForUnits(s, 2));
    try testing.expectEqual(@as(usize, 6), byteForUnits(s, 5));
}

test "cjk: three bytes, one unit" {
    const s = "a\u{4e16}\u{754c}b"; // a 世 界 b -> 8 bytes, 4 units
    try testing.expectEqual(@as(usize, 8), s.len);
    try testing.expectEqual(@as(usize, 4), unitLen(s));

    try testing.expectEqual(@as(usize, 1), unitsBeforeByte(s, 1));
    try testing.expectEqual(@as(usize, 2), unitsBeforeByte(s, 4));
    try testing.expectEqual(@as(usize, 3), unitsBeforeByte(s, 7));

    try testing.expectEqual(@as(usize, 4), byteForUnits(s, 2));
    try testing.expectEqual(@as(usize, 7), byteForUnits(s, 3));
    try testing.expectEqual(@as(usize, 8), byteForUnits(s, 4));
}

test "astral: four bytes, TWO units" {
    const s = "a\u{1f600}b"; // a 😀 b -> 6 bytes, 4 units
    try testing.expectEqual(@as(usize, 6), s.len);
    try testing.expectEqual(@as(usize, 4), unitLen(s));

    try testing.expectEqual(@as(usize, 1), unitsBeforeByte(s, 1));
    try testing.expectEqual(@as(usize, 3), unitsBeforeByte(s, 5)); // after the emoji
    try testing.expectEqual(@as(usize, 4), unitsBeforeByte(s, 6));

    try testing.expectEqual(@as(usize, 1), byteForUnits(s, 1));
    try testing.expectEqual(@as(usize, 5), byteForUnits(s, 3));
    try testing.expectEqual(@as(usize, 6), byteForUnits(s, 4));
}

test "surrogate half is not a boundary" {
    const s = "a\u{1f600}b";
    // Unit index 2 is the LOW half of the pair: the only byte offset at or
    // before it is the emoji's own start.
    try testing.expectEqual(@as(usize, 1), byteForUnits(s, 2));
}

test "round trip over every boundary of a mixed string" {
    const s = "h\u{e9}llo \u{1f600} \u{4e16}\u{754c} plain";
    var i: usize = 0;
    while (i < s.len) {
        const units = unitsBeforeByte(s, i);
        try testing.expectEqual(i, byteForUnits(s, units));
        i += seqLen(s[i]);
    }
    try testing.expectEqual(s.len, byteForUnits(s, unitLen(s)));
}

test "offsets past the end clamp to the whole text" {
    const s = "h\u{e9}llo";
    try testing.expectEqual(unitLen(s), unitsBeforeByte(s, 999));
    try testing.expectEqual(s.len, byteForUnits(s, 999));
    try testing.expectEqual(@as(usize, 0), unitsBeforeByte("", 5));
    try testing.expectEqual(@as(usize, 0), byteForUnits("", 5));
}

test "a byte offset inside a sequence answers for the characters before it" {
    const s = "a\u{1f600}b";
    // Offsets 2, 3 and 4 are inside the emoji; each answers 1 — the units
    // before the character that contains them — never a half character.
    try testing.expectEqual(@as(usize, 1), unitsBeforeByte(s, 2));
    try testing.expectEqual(@as(usize, 1), unitsBeforeByte(s, 3));
    try testing.expectEqual(@as(usize, 1), unitsBeforeByte(s, 4));
}

test "malformed bytes do not stall or overrun" {
    // A lone continuation byte and an out-of-range lead byte are each counted
    // as one byte, one unit, so the walk always terminates.
    const s = [_]u8{ 'a', 0x80, 0xF8, 'b' };
    try testing.expectEqual(@as(usize, 4), unitLen(&s));
    try testing.expectEqual(@as(usize, 4), byteForUnits(&s, 4));
    try testing.expectEqual(@as(usize, 2), unitsBeforeByte(&s, 2));
}

test "line breaks are one byte and one unit" {
    const s = "a\nb\nc";
    try testing.expectEqual(@as(usize, 5), unitLen(s));
    try testing.expectEqual(@as(usize, 2), unitsBeforeByte(s, 2));
    try testing.expectEqual(@as(usize, 4), byteForUnits(s, 4));
}
