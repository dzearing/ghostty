//! Pure banner-markdown parser for the win32 pane banner (T35). Zig port
//! of the Mac reference (`SurfacePaneBanner.swift` BannerMarkdown) so both
//! platforms accept the same subset:
//!
//!   - `**bold**`
//!   - `*italic*` or `_italic_`
//!   - `__underline__` (differs from CommonMark, which treats `__` as bold)
//!   - `` `code` `` (monospaced, contents not further parsed)
//!   - `[text](url)` clickable links (url must have a scheme); the label
//!     may contain other styles
//!   - `\` escapes the next character (e.g. `\*`, `\[`, `\\`)
//!
//! Styles nest (`**bold with [link](…)**`). Unterminated delimiters render
//! literally. Newlines split the banner into display lines, capped at
//! `max_lines` (extra lines are dropped).
//!
//! No OS imports: unit tested in every app-runtime lane (see apprt.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Display cap, matching the Mac banner's `lineLimit(6)`.
pub const max_lines: usize = 6;

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    code: bool = false,
};

/// One styled run of text on one display line. `text` and `link` are
/// allocated from the arena passed to `parse`.
pub const Run = struct {
    text: []const u8,
    style: Style = .{},
    link: ?[]const u8 = null,
    line: u16 = 0,
};

/// Parse banner source into styled runs. The caller owns the arena; runs
/// (and their text) are arena-allocated. Lines past `max_lines` drop.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error![]Run {
    var runs: std.ArrayList(Run) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_idx: u16 = 0;
    while (lines.next()) |line| {
        if (line_idx >= max_lines) break;
        try parseInline(arena, &runs, line, .{}, null, line_idx);
        line_idx += 1;
    }
    return runs.items;
}

/// Number of display lines the runs occupy (1 minimum: an empty banner
/// still paints one strip line — callers hide the overlay for empty text).
pub fn lineCount(runs: []const Run) usize {
    var max: u16 = 0;
    for (runs) |r| max = @max(max, r.line);
    return @as(usize, max) + 1;
}

const Delim = struct {
    token: []const u8,
    style: enum { bold, italic, underline, code },
};

/// Checked in order: two-character delimiters must win over their
/// single-character prefixes.
const delimiters = [_]Delim{
    .{ .token = "**", .style = .bold },
    .{ .token = "__", .style = .underline },
    .{ .token = "*", .style = .italic },
    .{ .token = "_", .style = .italic },
    .{ .token = "`", .style = .code },
};

fn parseInline(
    arena: Allocator,
    runs: *std.ArrayList(Run),
    s: []const u8,
    style: Style,
    link: ?[]const u8,
    line: u16,
) Allocator.Error!void {
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;

    while (i < s.len) {
        const c = s[i];

        // Backslash escapes the next character.
        if (c == '\\' and i + 1 < s.len) {
            try literal.append(arena, s[i + 1]);
            i += 2;
            continue;
        }

        // Links: [text](url), url must have a scheme.
        if (c == '[') link: {
            const close_bracket = findUnescaped(s, i + 1, "]") orelse break :link;
            if (close_bracket + 1 >= s.len or s[close_bracket + 1] != '(') break :link;
            const close_paren = findUnescaped(s, close_bracket + 2, ")") orelse break :link;
            const url = s[close_bracket + 2 .. close_paren];
            if (!hasScheme(url)) break :link;

            try flushLiteral(arena, runs, &literal, style, link, line);
            var linked_style = style;
            linked_style.underline = true;
            try parseInline(
                arena,
                runs,
                s[i + 1 .. close_bracket],
                linked_style,
                try arena.dupe(u8, url),
                line,
            );
            i = close_paren + 1;
            continue;
        }

        // Delimited style spans.
        if (matchDelim(s, i)) |d| delim: {
            const content_start = i + d.token.len;
            const close = findUnescaped(s, content_start, d.token) orelse break :delim;
            if (close <= content_start) break :delim; // empty span → literal

            const inner = s[content_start..close];
            try flushLiteral(arena, runs, &literal, style, link, line);
            var styled = style;
            switch (d.style) {
                .bold => styled.bold = true,
                .italic => styled.italic = true,
                .underline => styled.underline = true,
                .code => styled.code = true,
            }
            if (d.style == .code) {
                // Code spans are literal; everything else nests.
                try runs.append(arena, .{
                    .text = try arena.dupe(u8, inner),
                    .style = styled,
                    .link = link,
                    .line = line,
                });
            } else {
                try parseInline(arena, runs, inner, styled, link, line);
            }
            i = close + d.token.len;
            continue;
        }

        try literal.append(arena, c);
        i += 1;
    }

    try flushLiteral(arena, runs, &literal, style, link, line);
}

fn flushLiteral(
    arena: Allocator,
    runs: *std.ArrayList(Run),
    literal: *std.ArrayList(u8),
    style: Style,
    link: ?[]const u8,
    line: u16,
) Allocator.Error!void {
    if (literal.items.len == 0) return;
    try runs.append(arena, .{
        .text = try arena.dupe(u8, literal.items),
        .style = style,
        .link = link,
        .line = line,
    });
    literal.clearRetainingCapacity();
}

fn matchDelim(s: []const u8, i: usize) ?Delim {
    for (delimiters) |d| {
        if (std.mem.startsWith(u8, s[i..], d.token)) return d;
    }
    return null;
}

/// Find the next unescaped occurrence of `needle` at or after `from`.
fn findUnescaped(s: []const u8, from: usize, needle: []const u8) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] == '\\') {
            i += 2; // skip the escape and the escaped character
            continue;
        }
        if (std.mem.startsWith(u8, s[i..], needle)) return i;
        i += 1;
    }
    return null;
}

/// True when the text starts with a URL scheme (`letter (letter | digit |
/// + | - | .)* :`), the same gate the Mac applies via `URL.scheme != nil`.
fn hasScheme(url: []const u8) bool {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return false;
    for (url[1..], 1..) |c, idx| {
        if (c == ':') return idx > 0;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.')
            return false;
    }
    return false;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn parseTest(arena: Allocator, source: []const u8) ![]Run {
    return parse(arena, source);
}

test "plain text is a single unstyled run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "hello world");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("hello world", runs[0].text);
    try testing.expectEqual(Style{}, runs[0].style);
    try testing.expectEqual(@as(?[]const u8, null), runs[0].link);
}

test "bold italic underline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "**b** *i* _i2_ __u__ `c`");
    try testing.expectEqual(@as(usize, 9), runs.len); // 5 styled + 4 spaces
    try testing.expect(runs[0].style.bold);
    try testing.expectEqualStrings("b", runs[0].text);
    try testing.expect(runs[2].style.italic);
    try testing.expectEqualStrings("i", runs[2].text);
    try testing.expect(runs[4].style.italic);
    try testing.expectEqualStrings("i2", runs[4].text);
    try testing.expect(runs[6].style.underline);
    try testing.expectEqualStrings("u", runs[6].text);
    try testing.expect(runs[8].style.code);
    try testing.expectEqualStrings("c", runs[8].text);
}

test "code span contents are literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "`**not bold**`");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expect(runs[0].style.code);
    try testing.expect(!runs[0].style.bold);
    try testing.expectEqualStrings("**not bold**", runs[0].text);
}

test "link with scheme" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "[view](https://example.com/pr)");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("view", runs[0].text);
    try testing.expect(runs[0].style.underline);
    try testing.expectEqualStrings("https://example.com/pr", runs[0].link.?);
}

test "link without scheme renders literally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "[view](example.com)");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("[view](example.com)", runs[0].text);
    try testing.expectEqual(@as(?[]const u8, null), runs[0].link);
}

test "styles nest: bold containing a link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "**PR [123](https://x.io/1)**");
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expect(runs[0].style.bold);
    try testing.expectEqualStrings("PR ", runs[0].text);
    try testing.expect(runs[1].style.bold);
    try testing.expect(runs[1].style.underline);
    try testing.expectEqualStrings("123", runs[1].text);
    try testing.expectEqualStrings("https://x.io/1", runs[1].link.?);
}

test "italic nests inside bold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "**a *b* c**");
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expect(runs[0].style.bold and !runs[0].style.italic);
    try testing.expect(runs[1].style.bold and runs[1].style.italic);
    try testing.expectEqualStrings("b", runs[1].text);
    try testing.expect(runs[2].style.bold and !runs[2].style.italic);
}

test "unterminated delimiters render literally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "**open _tail `code");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("**open _tail `code", runs[0].text);
    try testing.expectEqual(Style{}, runs[0].style);
}

test "escapes suppress styling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "\\*\\*not bold\\*\\* \\\\ \\[x](https://y.io)");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("**not bold** \\ [x](https://y.io)", runs[0].text);
}

test "empty span is literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "****");
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("****", runs[0].text);
}

test "newlines split display lines and cap at max_lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7");
    try testing.expectEqual(@as(usize, max_lines), runs.len);
    try testing.expectEqual(@as(u16, 0), runs[0].line);
    try testing.expectEqual(@as(u16, 5), runs[5].line);
    try testing.expectEqualStrings("l5", runs[5].text);
    try testing.expectEqual(@as(usize, max_lines), lineCount(runs));
}

test "styling spans within one line only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The ** never closes on line 0, so it stays literal there.
    const runs = try parseTest(arena.allocator(), "**a\nb**");
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqualStrings("**a", runs[0].text);
    try testing.expectEqualStrings("b**", runs[1].text);
}

test "empty source yields no runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const runs = try parseTest(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), runs.len);
    try testing.expectEqual(@as(usize, 1), lineCount(runs));
}

test "hasScheme accepts letter-led schemes only" {
    try testing.expect(hasScheme("https://x"));
    try testing.expect(hasScheme("mailto:a@b"));
    try testing.expect(hasScheme("vscode-insiders://f"));
    try testing.expect(!hasScheme("example.com"));
    try testing.expect(!hasScheme("//x"));
    try testing.expect(!hasScheme("1http://x"));
    try testing.expect(!hasScheme(""));
}
