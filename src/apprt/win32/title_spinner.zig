//! Pure logic for the leading **spinner cell** in a window/tab title (T60).
//! No OS imports, so its unit tests run in every app-runtime lane (the
//! `title_font.zig` / `split_geometry.zig` pattern).
//!
//! ## The bug this exists to remove
//!
//! An agent that animates its title — Claude Code is the one on this box —
//! cycles a single leading glyph on a timer and leaves the rest of the string
//! alone: `"* Review Go loop features"` where the `*` is one frame of
//! `. + * ~ x` drawn from the dingbat and math blocks. Those glyphs are not
//! one width. Measured in Segoe UI at the user's 125% (16 DIP title font, so
//! a 20 px em) with `GetTextExtentPoint32W`, the frames Claude Code uses:
//!
//! | frame | codepoint | advance |
//! |---|---|---|
//! | middle dot   | U+00B7 |  4 px |
//! | asterisk op  | U+2217 | 10 px |
//! | four-petal   | U+2726 | 16 px |
//! | teardrop     | U+2722 | 18 px |
//! | six-petal    | U+273B | 18 px |
//! | eight-petal  | U+273D | 18 px |
//! | eight-spoked | U+2733 | 27 px |
//! | eight-point  | U+2734 | 27 px |
//!
//! A **23 px** swing, several times a second. Everything after the glyph is
//! laid out from its advance, so every frame moved two things: the title text
//! shifted left/right inside its box, and — because a tab asks for the width
//! its own title needs (T235) — the chiclet, its close button, the "+" and
//! every tab after it shifted with it. That is the user's report: *"window
//! title jitters a few px left/right on a timer while busy"*.
//!
//! (The braille frames Claude Code uses for a PANE title — U+2801..U+2880 —
//! all measure 15 px, which is why the jitter is a tab/caption symptom and
//! not a universal one. A fix that only special-cased braille would have
//! fixed nothing.)
//!
//! ## The fix
//!
//! A title that begins with a symbol glyph and a space gets that glyph drawn
//! **centered in a fixed-width cell**, and the rest of the title starts at
//! the cell's right edge. The spinner then animates in place — which is what
//! a spinner is for — and nothing downstream of it can move, because nothing
//! downstream of it is measured from the glyph any more.
//!
//! Both halves have to use this: `measure` feeds the tab's preferred width
//! and `draw` paints it. Measuring the raw string and painting the cell (or
//! the reverse) would size a tab for a layout it does not use.

const std = @import("std");
const testing = std.testing;

/// Negative control for `test/win32/title-jitter.ps1` (project standard: an
/// acceptance script has to be SHOWN to fail, or it is not evidence). Flip to
/// `true`, rebuild `-Dapp-runtime=win32`, and re-run the script: the painter
/// falls back to laying the whole title out from the glyph's own advance, so
/// the "text past the cell is pixel-identical across frames" and "the tab
/// keeps its width across frames" assertions must fail — and the
/// title-is-actually-drawn control must NOT.
///
/// Left in the source rather than behind a build option so the control is one
/// edit away from any future reader (the `T202_NEUTERED` pattern), and routed
/// through `forPaint` so the unit tests below keep pinning the real detection
/// either way.
const T60_NEUTERED = false;

/// A title that leads with a spinner glyph, split into the parts the painter
/// lays out separately.
pub const Split = struct {
    /// UTF-16 code units of the leading glyph: 1, or 2 for a surrogate pair.
    /// Always starts at index 0.
    glyph_len: usize,
    /// Index of the first unit of the remaining text. Past the glyph AND past
    /// the run of spaces behind it — the cell owns that separation now, so
    /// painting the space again would re-introduce a (smaller) shift.
    rest: usize,
};

/// Does a title lead with an animated glyph? Returns how to split it, or
/// `null` when the title is ordinary and should be laid out as one string.
///
/// The rule is structural rather than a list of Claude Code's frames: a
/// **single non-ASCII symbol codepoint**, then a space, then something else.
/// Anything else — plain text, a leading letter, a symbol with no space, a
/// symbol with nothing after it — is not a spinner and is left alone.
pub fn split(title: []const u16) ?Split {
    if (title.len < 3) return null;

    const cp, const glyph_len = decode(title) orelse return null;
    if (!isSpinnerGlyph(cp)) return null;

    // Exactly one space is what an animated title uses, but consuming the
    // whole run means a two-space title cannot smuggle a shift back in.
    var rest = glyph_len;
    while (rest < title.len and title[rest] == ' ') rest += 1;
    if (rest == glyph_len) return null; // no separator: not a spinner
    if (rest >= title.len) return null; // nothing after it: not a spinner

    return .{ .glyph_len = glyph_len, .rest = rest };
}

/// What the PAINTER asks. Identical to `split` except that the negative
/// control can switch it off without disarming the unit tests.
pub fn forPaint(title: []const u16) ?Split {
    if (T60_NEUTERED) return null;
    return split(title);
}

/// Width of the cell reserved for the leading glyph, in physical pixels, from
/// the title font's em (`window-title-font-family` at 16 DIP, so `16 * scale`
/// here).
///
/// Derived from the font rather than being a DIP constant on the spacing
/// scale, because what has to fit is a GLYPH, and a fallback font's dingbat
/// routinely overruns the em: the widest frame above is 27 px against a 20 px
/// em, a ratio of 1.35. `3/2` clears that at every scale with room to spare
/// and stays an exact integer ratio, so the cell cannot round apart from
/// itself at fractional DPI. A glyph wider still simply overhangs into the
/// gap before the text rather than being clipped — a clipped spinner reads as
/// a rendering bug, a snug one does not.
pub fn cellWidth(font_em_px: i32) i32 {
    return @divTrunc(@max(font_em_px, 0) * 3, 2);
}

/// Decode the first codepoint, returning it with its UTF-16 length.
fn decode(title: []const u16) ?struct { u21, usize } {
    const hi = title[0];
    if (hi >= 0xD800 and hi < 0xDC00) {
        if (title.len < 2) return null;
        const lo = title[1];
        if (lo < 0xDC00 or lo > 0xDFFF) return null;
        const cp: u21 = 0x10000 +
            ((@as(u21, hi - 0xD800) << 10) | @as(u21, lo - 0xDC00));
        return .{ cp, 2 };
    }
    if (hi >= 0xDC00 and hi <= 0xDFFF) return null; // lone trail surrogate
    return .{ @as(u21, hi), 1 };
}

/// Is this codepoint the kind of thing an animated title leads with?
///
/// ASCII is deliberately excluded. `*` and `|` spinners exist, but a
/// monospaced-advance ASCII character does not jitter, and a rule that
/// reserved a cell for one would move real titles that merely start with
/// punctuation.
fn isSpinnerGlyph(cp: u21) bool {
    return switch (cp) {
        0x00B7 => true, // MIDDLE DOT — the narrowest Claude Code frame
        0x00D7 => true, // MULTIPLICATION SIGN
        // General Punctuation through Miscellaneous Symbols and Arrows: the
        // one contiguous run that holds every symbol block a spinner draws
        // from — math operators (U+2217), geometric shapes (U+25A0), misc
        // symbols (U+2600), dingbats (U+2700), braille (U+2800).
        0x2000...0x2BFF => true,
        // Emoji and pictographs.
        0x1F000...0x1FAFF => true,
        else => false,
    };
}

// -- tests -------------------------------------------------------------------

/// UTF-16 literal helper: the tests speak in codepoints, the code in units.
fn u16s(comptime s: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(s);
}

test "split: Claude Code's tab spinner frames all split the same way" {
    // Every frame yields the SAME `rest`, which is the whole point: the text
    // starts at one place no matter which glyph is up.
    const frames = [_][]const u16{
        u16s("\u{00B7} Review Go loop features"),
        u16s("\u{2217} Review Go loop features"),
        u16s("\u{2722} Review Go loop features"),
        u16s("\u{2726} Review Go loop features"),
        u16s("\u{2733} Review Go loop features"),
        u16s("\u{2734} Review Go loop features"),
        u16s("\u{273B} Review Go loop features"),
        u16s("\u{273D} Review Go loop features"),
    };
    for (frames) |f| {
        const s = split(f) orelse return error.TestExpectedSplit;
        try testing.expectEqual(@as(usize, 1), s.glyph_len);
        try testing.expectEqual(@as(usize, 2), s.rest);
    }
}

test "split: the braille pane-title frames split too" {
    // They do not jitter (all 15 px in Segoe UI), but they are spinners and
    // the rule is structural, not a width measurement — a font where they DO
    // differ must not reintroduce the bug.
    for ([_][]const u16{
        u16s("\u{2801} Read go.md"),
        u16s("\u{2840} Read go.md"),
        u16s("\u{2880} Read go.md"),
    }) |f| {
        const s = split(f) orelse return error.TestExpectedSplit;
        try testing.expectEqual(@as(usize, 2), s.rest);
    }
}

test "split: an ordinary title is left alone" {
    try testing.expect(split(u16s("D:\\git\\ghoztty")) == null);
    try testing.expect(split(u16s("C:\\WINDOWS\\system32\\cmd.exe")) == null);
    try testing.expect(split(u16s("zsh")) == null);
    try testing.expect(split(u16s("[go-loop] ghoztty parity")) == null);
    // A leading ASCII symbol is not a spinner: it has a fixed advance, so it
    // never jittered, and reserving a cell would move a title that was fine.
    try testing.expect(split(u16s("* wildcard build")) == null);
    try testing.expect(split(u16s("- dash first")) == null);
}

test "split: a symbol with no separator or no text is not a spinner" {
    try testing.expect(split(u16s("\u{2733}Review")) == null); // no space
    try testing.expect(split(u16s("\u{2733} ")) == null); // nothing after
    try testing.expect(split(u16s("\u{2733}   ")) == null); // only spaces after
    try testing.expect(split(u16s("\u{2733}")) == null); // too short
    try testing.expect(split(&[_]u16{}) == null);
}

test "split: a run of spaces is consumed into the cell" {
    const s = split(u16s("\u{2733}   Review")) orelse return error.TestExpectedSplit;
    try testing.expectEqual(@as(usize, 1), s.glyph_len);
    try testing.expectEqual(@as(usize, 4), s.rest);
}

test "split: an astral spinner is two code units" {
    const s = split(u16s("\u{1F680} Deploying")) orelse return error.TestExpectedSplit;
    try testing.expectEqual(@as(usize, 2), s.glyph_len);
    try testing.expectEqual(@as(usize, 3), s.rest);
}

test "split: a malformed surrogate is not a spinner" {
    // A lone lead or trail surrogate must fall through to the plain path
    // rather than being decoded into a bogus codepoint.
    try testing.expect(split(&[_]u16{ 0xD83D, 'a', 'b' }) == null);
    try testing.expect(split(&[_]u16{ 0xDE80, ' ', 'a' }) == null);
    try testing.expect(split(&[_]u16{0xD83D}) == null);
}

test "split: a leading CJK or letter is not a spinner" {
    try testing.expect(split(u16s("\u{65E5} \u{672C}")) == null);
    try testing.expect(split(u16s("A window")) == null);
}

test "cellWidth: clears the widest measured frame at every scale" {
    // The measurement that sets the ratio: U+2733 came back 27 px against a
    // 20 px em (Segoe UI, 125%). Scale that worst case to each DPI and the
    // cell must still hold it.
    const scales = [_]f32{ 1.0, 1.25, 1.5, 2.0 };
    for (scales) |s| {
        const em: i32 = @intFromFloat(16.0 * s);
        const widest_glyph: i32 = @intFromFloat(27.0 * (s / 1.25));
        try testing.expect(cellWidth(em) >= widest_glyph);
    }
}

test "cellWidth: scales monotonically and degenerate input is not negative" {
    try testing.expectEqual(@as(i32, 24), cellWidth(16));
    try testing.expectEqual(@as(i32, 30), cellWidth(20));
    try testing.expectEqual(@as(i32, 36), cellWidth(24));
    try testing.expectEqual(@as(i32, 48), cellWidth(32));
    try testing.expectEqual(@as(i32, 0), cellWidth(0));
    try testing.expectEqual(@as(i32, 0), cellWidth(-10));
}

test "forPaint agrees with split in the shipped build" {
    // Pins the control's default. When it is flipped for a negative-control
    // run this test fails, which is the intended loud reminder to flip it
    // back — the acceptance script is the thing being validated, not this.
    try testing.expect(!T60_NEUTERED);
    const t = u16s("\u{2733} Review");
    try testing.expectEqual(split(t).?.rest, forPaint(t).?.rest);
}
