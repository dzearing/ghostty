//! Pure text search shared by every win32 filter box (T288): the one
//! case-insensitive substring test behind the machine chooser's filter
//! (`MachineChooser.filterRows`, T172) and the Activity Monitor's process
//! filter (`activity_rows.matches`, T285).
//!
//! Both of those grew a private copy of the same scan, which is two copies of
//! the chance to be wrong and no way to notice (the T257 lesson). More to the
//! point, the fold's ALPHABET is a product decision — see below — and a
//! decision that lives in two files is a decision nobody can revisit.
//!
//! ## The fold is ASCII, and that is a known divergence from macOS
//!
//! `std.ascii.indexOfIgnoreCase` folds `A`-`Z` only. macOS folds the same two
//! filters with `localizedCaseInsensitiveContains`
//! (`MachineChooserView.swift:244-245,253`, `RemoteActivityMonitorView.swift:808`),
//! which is Unicode- and locale-aware — so a user filtering for `İ`, `Ä` or a
//! Cyrillic machine name gets hits on the Mac and nothing here. That gap is
//! filed as T790, with the approach question filed as D71; what this
//! module buys is that closing it is a change to ONE function with one set of
//! tests, rather than a hunt for every filter box that grew its own scan.
//!
//! No OS imports, so it runs in every app-runtime test lane — same deal as
//! `chooser_rows.zig` and `activity_rows.zig`, whose HWND-owning siblings
//! cannot be reached from the `none` lane at all.

const std = @import("std");
const testing = std.testing;

/// True when `needle` appears anywhere in `haystack`, folding ASCII case.
///
/// An empty needle matches everything (a filter box nobody has typed into
/// hides nothing), and a needle longer than the haystack matches nothing.
/// Bytes outside `A`-`Z`/`a`-`z` compare exactly, which for a multi-byte UTF-8
/// sequence means it matches itself and no other casing of itself — the
/// conservative direction: a miss narrows a list, it never shows the wrong row.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "containsIgnoreCase: basic matches" {
    try testing.expect(containsIgnoreCase("Winbox", "box"));
    try testing.expect(containsIgnoreCase("Winbox", ""));
    try testing.expect(!containsIgnoreCase("Winbox", "mac"));
    try testing.expect(!containsIgnoreCase("ab", "abc")); // needle longer
}

test "containsIgnoreCase: needle longer than haystack is not a match" {
    try testing.expect(!containsIgnoreCase("ab", "abc"));
    try testing.expect(containsIgnoreCase("abc", "abc"));
    try testing.expect(containsIgnoreCase("abc", ""));
}

test "containsIgnoreCase: the fold runs in both directions, anywhere in the string" {
    try testing.expect(containsIgnoreCase("ghoztty-agent.exe", "AGENT"));
    try testing.expect(containsIgnoreCase("GHOZTTY-AGENT.EXE", "agent"));
    // Head and tail, not just the middle.
    try testing.expect(containsIgnoreCase("Winbox", "WIN"));
    try testing.expect(containsIgnoreCase("Winbox", "BOX"));
    // An empty haystack is only matched by an empty needle.
    try testing.expect(containsIgnoreCase("", ""));
    try testing.expect(!containsIgnoreCase("", "a"));
}

test "containsIgnoreCase: past 51 bytes std switches algorithms; both agree" {
    // `std.ascii.indexOfIgnoreCasePos` runs a linear scan under 52 haystack
    // bytes or a needle of 4 or fewer, and Boyer-Moore-Horspool otherwise. A
    // process table's `cmd` column is routinely longer than that, so the long
    // path is the one a user actually filters against.
    const long = "C:\\Users\\David\\AppData\\Local\\Programs\\Ghoztty\\ghoztty-agent.exe";
    try testing.expect(long.len > 52);
    try testing.expect(containsIgnoreCase(long, "PROGRAMS"));
    try testing.expect(containsIgnoreCase(long, "ghoztty-AGENT.exe"));
    try testing.expect(!containsIgnoreCase(long, "ghoztty-agent.dll"));
    // The last byte of the haystack is reachable by the skip table too.
    try testing.expect(containsIgnoreCase(long, "E"));
}

test "containsIgnoreCase: non-ASCII bytes compare exactly (the documented ASCII limit)" {
    // Latin-1 supplement in UTF-8: `Ä` is C3 84 and `ä` is C3 A4, so the fold
    // does not see them as the same letter. This test states the limit rather
    // than asserting it is desirable — see the module header and T790.
    try testing.expect(containsIgnoreCase("Zürich", "ü"));
    try testing.expect(!containsIgnoreCase("Zürich", "Ü"));
    // ASCII either side of a multi-byte sequence still folds.
    try testing.expect(containsIgnoreCase("Zürich", "z"));
    try testing.expect(containsIgnoreCase("Zürich", "RICH"));
}
