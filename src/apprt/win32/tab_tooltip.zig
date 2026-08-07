//! Pure tab-tooltip text derivation (T447) — the "what does hovering a tab
//! say" half of the tab tooltip, kept OS-free so the none lane can assert it
//! (the `tab_strip_layout.zig` pattern). The control plumbing lives in
//! `Window.zig`; nothing here touches an HWND.
//!
//! The tooltip surfaces the hovered tab's focused pane's working directory
//! (or a viewer pane's current location), so several tabs on several
//! checkouts can be told apart without running a command — the
//! Windows-native translation of the Mac titlebar proxy icon (translate the
//! feature, not the implementation). Two transforms, matching how a person
//! reads a path:
//!
//! - the home-directory prefix reads as `~` (Mac's `abbreviatedPath`), and
//! - a path longer than `max_len` drops MIDDLE components, never the tail:
//!   the deepest directories are what distinguish two checkouts of the same
//!   repo, so they are the part that must survive.

const std = @import("std");

/// Max UTF-8 bytes of tooltip text before middle components are elided.
/// Long enough for any realistic repo path, short enough that the tooltip
/// never spans half a monitor.
pub const max_len: usize = 96;

/// The elision mark. One character, three UTF-8 bytes.
const ellipsis = "…";

/// True when `c` separates path components. Both separators are accepted
/// everywhere: OSC 7 emits `/` from git-bash and `\` from PowerShell, and a
/// viewer location can be either.
inline fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// ASCII case-insensitive equality — Windows paths compare caseless, and
/// drive letters arrive in either case (`c:\` from MSYS, `C:\` from
/// PowerShell). Multibyte sequences compare byte-exact, which is the
/// conservative direction: a miss keeps the full path, never corrupts it.
fn eqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Replace the home-directory prefix of `path` with `~` into `out`.
/// Only a whole-component prefix matches: `C:\Users\Dav` does not abbreviate
/// `C:\Users\David`. Trailing separators on `home` are ignored. A null or
/// empty home, or no match, copies `path` verbatim.
///
/// `out.len >= path.len` is the caller's contract (the transform only ever
/// shrinks); a too-small buffer returns the unabbreviated tail-truncated
/// copy rather than tripping an assert in release.
pub fn tildeHome(out: []u8, path: []const u8, home: ?[]const u8) []const u8 {
    const n = @min(path.len, out.len);
    const h_raw = home orelse {
        @memcpy(out[0..n], path[0..n]);
        return out[0..n];
    };
    // Strip trailing separators from home so `C:\Users\David\` still
    // matches `C:\Users\David\git`.
    var h = h_raw;
    while (h.len > 0 and isSep(h[h.len - 1])) h = h[0 .. h.len - 1];
    if (h.len == 0 or path.len < h.len or !eqlNoCase(path[0..h.len], h) or
        (path.len > h.len and !isSep(path[h.len])))
    {
        @memcpy(out[0..n], path[0..n]);
        return out[0..n];
    }
    const rest = path[h.len..];
    const rest_n = @min(rest.len, out.len -| 1);
    out[0] = '~';
    @memcpy(out[1 .. 1 + rest_n], rest[0..rest_n]);
    return out[0 .. 1 + rest_n];
}

/// The largest index `>= from` in `s` that starts a UTF-8 codepoint, so a
/// cut never leaves a dangling continuation byte at the front of the kept
/// tail.
fn utf8CeilBoundary(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] & 0xC0) == 0x80) i += 1;
    return i;
}

/// Keep the LAST bytes of `path` that fit `max` (minus the ellipsis), cut on
/// a UTF-8 boundary — the fallback when component elision cannot help (no
/// separators, or even the final component alone is over budget). The tail
/// survives because it is the distinguishing part.
fn tailTruncate(out: []u8, path: []const u8, max: usize) []const u8 {
    const budget = max -| ellipsis.len;
    const start = utf8CeilBoundary(path, path.len -| budget);
    const tail = path[start..];
    @memcpy(out[0..ellipsis.len], ellipsis);
    @memcpy(out[ellipsis.len .. ellipsis.len + tail.len], tail);
    return out[0 .. ellipsis.len + tail.len];
}

/// Elide middle path components so the result fits `max` bytes: the root
/// component and as many TRAILING components as fit are kept, joined with
/// `…` — `~\git\ghoztty\src\apprt\win32` over budget becomes
/// `~\…\src\apprt\win32`, never a cut that loses the leaf. A path already
/// within budget is copied verbatim. `out.len >= max` is the caller's
/// contract.
pub fn elide(out: []u8, path: []const u8, max: usize) []const u8 {
    if (path.len <= max) {
        @memcpy(out[0..path.len], path);
        return out[0..path.len];
    }
    if (max <= ellipsis.len) return tailTruncate(out, path, max);

    // The separator style of the joined result is the path's own.
    var sep: u8 = '\\';
    for (path) |c| {
        if (isSep(c)) {
            sep = c;
            break;
        }
    }

    // Root component (drive letter, `~`, or a URL scheme's head) plus the
    // fixed elision infix: `root` + sep + `…` + sep.
    const root_end = for (path, 0..) |c, i| {
        if (isSep(c)) break i;
    } else path.len;
    const root = path[0..root_end];
    const overhead = root.len + 1 + ellipsis.len + 1;
    if (overhead >= max) return tailTruncate(out, path, max);
    const budget = max - overhead;

    // Grow the kept tail backwards a component at a time. `start` lands on
    // the byte AFTER a separator, so the kept tail is whole components.
    var start: usize = path.len;
    var i: usize = path.len;
    while (i > root_end + 1) {
        i -= 1;
        if (isSep(path[i])) {
            const cand = path[i + 1 ..];
            if (cand.len > budget) break;
            start = i + 1;
        }
    }
    if (start == path.len) return tailTruncate(out, path, max);
    const tail = path[start..];

    @memcpy(out[0..root.len], root);
    var at = root.len;
    out[at] = sep;
    at += 1;
    @memcpy(out[at .. at + ellipsis.len], ellipsis);
    at += ellipsis.len;
    out[at] = sep;
    at += 1;
    @memcpy(out[at .. at + tail.len], tail);
    return out[0 .. at + tail.len];
}

/// One-call composition for the control code: tilde-abbreviate, then elide
/// to `max_len`. Null for an empty location — an empty tooltip must not
/// show, the way an empty pane reads as an answer, not an error (T181).
/// `out.len >= max_len` is the caller's contract.
pub fn tipText(out: []u8, location: []const u8, home: ?[]const u8) ?[]const u8 {
    if (location.len == 0) return null;
    var scratch: [1024]u8 = undefined;
    const abbrev = if (location.len <= scratch.len)
        tildeHome(&scratch, location, home)
    else
        location;
    return elide(out, abbrev, max_len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tildeHome: replaces the home prefix with ~" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tildeHome(&buf, "C:\\Users\\David\\git\\ghoztty", "C:\\Users\\David"),
    );
}

test "tildeHome: exact home is just ~" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~",
        tildeHome(&buf, "C:\\Users\\David", "C:\\Users\\David"),
    );
}

test "tildeHome: case-insensitive and separator-style agnostic" {
    var buf: [256]u8 = undefined;
    // MSYS-style report of the same directory: lowercase drive, forward
    // slashes in the path half.
    try testing.expectEqualStrings(
        "~/git/x",
        tildeHome(&buf, "c:\\users\\david/git/x", "C:\\Users\\David"),
    );
}

test "tildeHome: trailing separator on home still matches" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git",
        tildeHome(&buf, "C:\\Users\\David\\git", "C:\\Users\\David\\"),
    );
}

test "tildeHome: a partial component never abbreviates" {
    var buf: [256]u8 = undefined;
    // `C:\Users\Dav` is a PREFIX of the string but not of the path.
    try testing.expectEqualStrings(
        "C:\\Users\\David2\\git",
        tildeHome(&buf, "C:\\Users\\David2\\git", "C:\\Users\\David"),
    );
}

test "tildeHome: null or empty home copies verbatim" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        tildeHome(&buf, "D:\\git\\ghoztty", null),
    );
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        tildeHome(&buf, "D:\\git\\ghoztty", ""),
    );
}

test "elide: a short path is untouched" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        elide(&buf, "~\\git\\ghoztty", max_len),
    );
}

test "elide: middle components go, root and leaf components stay" {
    var buf: [128]u8 = undefined;
    // 116 bytes: over budget by enough that the 80-byte component must go.
    const long = "~\\git\\" ++ ("A" ** 80) ++ "\\nested\\deeper\\src\\apprt\\win32";
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expectEqualStrings(
        "~\\" ++ ellipsis ++ "\\nested\\deeper\\src\\apprt\\win32",
        got,
    );
}

test "elide: keeps the path's own separator style" {
    var buf: [128]u8 = undefined;
    const long = "~/git/" ++ ("A" ** 80) ++ "/nested/deeper/src/apprt/win32";
    const got = elide(&buf, long, max_len);
    try testing.expect(std.mem.startsWith(u8, got, "~/" ++ ellipsis ++ "/"));
    try testing.expect(std.mem.endsWith(u8, got, "/src/apprt/win32"));
}

test "elide: the whole budget is used before eliding more" {
    var buf: [128]u8 = undefined;
    // Every trailing component fits: elision keeps them ALL, not just the
    // leaf — only the oversized middle component is dropped.
    const long = "C:\\" ++ ("x" ** 120) ++ "\\aa\\bb\\cc\\dd";
    const got = elide(&buf, long, max_len);
    try testing.expectEqualStrings("C:\\" ++ ellipsis ++ "\\aa\\bb\\cc\\dd", got);
}

test "elide: no separators falls back to a tail cut" {
    var buf: [128]u8 = undefined;
    const long = "z" ** 200;
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expect(std.mem.startsWith(u8, got, ellipsis));
    try testing.expect(std.mem.endsWith(u8, got, "zzz"));
}

test "elide: an oversized final component keeps its tail" {
    var buf: [128]u8 = undefined;
    const long = "C:\\a\\" ++ ("y" ** 150);
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expect(std.mem.startsWith(u8, got, ellipsis));
    try testing.expect(std.mem.endsWith(u8, got, "yyy"));
}

test "elide: a tail cut never splits a UTF-8 sequence" {
    var buf: [128]u8 = undefined;
    // 2-byte codepoints back to back: an arbitrary byte cut has ~50% odds
    // of landing mid-sequence, so a bad cut fails validity below.
    const long = "é" ** 120; // 240 bytes, no separators
    const got = elide(&buf, long, max_len);
    try testing.expect(got.len <= max_len);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "tipText: composes tilde + elision" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        tipText(&buf, "C:\\Users\\David\\git\\ghoztty", "C:\\Users\\David").?,
    );
}

test "tipText: empty location is null, not an empty tooltip" {
    var buf: [128]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), tipText(&buf, "", "C:\\Users\\David"));
}

test "tipText: a viewer URL passes through untouched" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "http://localhost:3000/",
        tipText(&buf, "http://localhost:3000/", "C:\\Users\\David").?,
    );
}
