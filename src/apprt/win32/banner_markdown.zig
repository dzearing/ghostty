//! Pure banner-markdown parser for the win32 pane banner (T35/T91). Zig
//! port of the Mac reference (`SurfacePaneBanner.swift` BannerMarkdown) so
//! both platforms accept the same subset.
//!
//! Inline syntax:
//!   - `**bold**`
//!   - `*italic*` or `_italic_`
//!   - `__underline__` (differs from CommonMark, which treats `__` as bold)
//!   - `` `code` `` (monospaced, contents not further parsed)
//!   - `[text](url)` clickable links (url must have a scheme); the label
//!     may contain other styles
//!   - `[x]`/`[X]`/`[ ]` task-list checkboxes, drawn natively by the view
//!     (a `[x](url)` token stays a link; a checkbox nested inside a
//!     styled span or link label falls back to the `☑`/`☐` glyph)
//!   - `\` escapes the next character (e.g. `\*`, `\[`, `\\`, `\|`)
//!
//! Block syntax (one block per source construct):
//!   - ATX headings `# text` … `###### text`
//!   - thematic breaks: 3+ of the same `-`, `*`, or `_` (spaces allowed)
//!   - lists: `- `/`* ` bullets, `1.` ordered items, `[x]`/`[ ]`
//!     checkboxes (a `- ` before a checkbox is the checkbox's marker);
//!     consecutive list lines form one block sharing a marker gutter
//!   - pipe tables: header row + `|---|` separator (with `:` alignment
//!     markers) + body rows; ragged rows pad/truncate to the header
//!     width; an all-empty header renders as a headerless aligned grid
//!   - anything else: one text block per non-blank source line
//!
//! Styles nest (`**bold with [link](…)**`). Unterminated delimiters render
//! literally. Display is capped at `max_lines` lines: text/heading/rule/
//! list-item lines count 1 each; a table costs 1 (header) + 1 per kept
//! body row (the separator row never renders).
//!
//! No OS imports: unit tested in every app-runtime lane (see apprt.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Display cap, matching the Mac banner's `maxDisplayLines`.
pub const max_lines: usize = 10;

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    code: bool = false,
};

/// How a table column aligns, from `:` markers in the separator row.
pub const ColumnAlignment = enum { leading, center, trailing };

/// One styled run of text. `text` and `link` are arena-allocated.
pub const Seg = struct {
    text: []const u8,
    style: Style = .{},
    link: ?[]const u8 = null,
};

/// One piece of inline content: a styled text run, or a task-list
/// checkbox the view draws natively (rounded box + check) rather than as
/// a glyph.
pub const Inline = union(enum) {
    seg: Seg,
    checkbox: bool,
};

/// The leading marker of a list item, drawn in a shared gutter so all
/// item content aligns regardless of marker kind.
pub const ListMarker = union(enum) {
    /// `[x]`/`[ ]` — a native checkbox (`- [x]` marker also lands here).
    checkbox: bool,
    /// `- ` or `* ` — an unordered bullet.
    bullet,
    /// `1.`, `2.`, … — the parsed number, rendered verbatim.
    ordered: u32,
};

pub const ListItem = struct {
    marker: ListMarker,
    content: []const Inline,
};

pub const Table = struct {
    header: []const []const Inline,
    /// One entry per column; null when the separator had no `:` markers.
    alignments: []const ?ColumnAlignment,
    rows: []const []const []const Inline,

    /// True when at least one header cell carries visible content. An
    /// all-empty header (e.g. `|  |  |`) is a layout scaffold for an
    /// aligned key/value grid: the view renders body rows only, with no
    /// header row and no divider.
    pub fn hasVisibleHeader(self: Table) bool {
        for (self.header) |cell| {
            for (cell) |item| switch (item) {
                .seg => |s| if (s.text.len > 0) return true,
                .checkbox => return true,
            };
        }
        return false;
    }
};

pub const Heading = struct {
    /// 1–6; rendered bold at a size that grows as the level shrinks.
    level: u8,
    content: []const Inline,
};

pub const Block = union(enum) {
    /// One source line of inline content (long lines clip in the strip).
    text: []const Inline,
    /// A run of consecutive list lines in any marker mix.
    list: []const ListItem,
    heading: Heading,
    /// A thematic break, rendered as a full-width horizontal divider.
    rule,
    table: Table,
};

/// Parse banner source into displayable blocks, truncated to at most
/// `max_lines` display lines. The caller owns the arena; all slices are
/// arena-allocated.
pub fn parseBlocks(arena: Allocator, source: []const u8) Allocator.Error![]Block {
    var blocks: std.ArrayList(Block) = .empty;
    var remaining: usize = max_lines;

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(arena, line);

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];

        if (headingLine(line)) |h| {
            if (remaining > 0) {
                remaining -= 1;
                try blocks.append(arena, .{ .heading = .{
                    .level = h.level,
                    .content = try parseSegs(arena, h.text, false),
                } });
            }
            i += 1;
            continue;
        }

        if (isThematicBreak(line)) {
            if (remaining > 0) {
                remaining -= 1;
                try blocks.append(arena, .rule);
            }
            i += 1;
            continue;
        }

        if (isTableRow(line) and i + 1 < lines.items.len and isTableRow(lines.items[i + 1])) table: {
            const header_cells = try splitCells(arena, line);
            const sep_cells = try splitCells(arena, lines.items[i + 1]);
            if (header_cells.len == 0 or sep_cells.len != header_cells.len) break :table;
            for (sep_cells) |c| if (!isSeparatorCell(c)) break :table;

            var raw_rows: std.ArrayList([]const []const u8) = .empty;
            var j = i + 2;
            while (j < lines.items.len and isTableRow(lines.items[j])) : (j += 1) {
                try raw_rows.append(arena, try splitCells(arena, lines.items[j]));
            }

            if (remaining > 0) {
                const kept = @min(raw_rows.items.len, remaining - 1);
                remaining -= 1 + kept;
                const columns = header_cells.len;

                const header = try arena.alloc([]const Inline, columns);
                for (header_cells, 0..) |cell, col| {
                    header[col] = try parseSegs(arena, cell, true);
                }
                const alignments = try arena.alloc(?ColumnAlignment, columns);
                for (sep_cells, 0..) |cell, col| alignments[col] = columnAlignment(cell);
                const rows = try arena.alloc([]const []const Inline, kept);
                for (raw_rows.items[0..kept], 0..) |raw, r| {
                    const row = try arena.alloc([]const Inline, columns);
                    for (0..columns) |col| {
                        row[col] = if (col < raw.len)
                            try parseSegs(arena, raw[col], true)
                        else
                            &.{};
                    }
                    rows[r] = row;
                }
                try blocks.append(arena, .{ .table = .{
                    .header = header,
                    .alignments = alignments,
                    .rows = rows,
                } });
            }

            i = j;
            continue;
        }

        // A run of list lines becomes one block so the items share a
        // marker gutter and get table-like vertical rhythm.
        if (listItem(line) != null) {
            var items: std.ArrayList(ListItem) = .empty;
            while (i < lines.items.len) : (i += 1) {
                const item = listItem(lines.items[i]) orelse break;
                if (remaining > 0) {
                    remaining -= 1;
                    try items.append(arena, .{
                        .marker = item.marker,
                        .content = try parseSegs(arena, item.content, true),
                    });
                }
            }
            if (items.items.len > 0) try blocks.append(arena, .{ .list = items.items });
            continue;
        }

        // Plain text line. Blank lines drop — the inter-block gap
        // supplies the space they used to add.
        if (!isBlank(line)) {
            if (remaining > 0) {
                remaining -= 1;
                try blocks.append(arena, .{ .text = try parseSegs(arena, line, false) });
            }
        }
        i += 1;
    }

    return blocks.items;
}

/// Number of display lines the blocks occupy (1 minimum: an empty banner
/// still paints one strip line — callers hide the overlay for empty text).
/// Wrapped table cells still count their row once.
pub fn displayLines(blocks: []const Block) usize {
    var n: usize = 0;
    for (blocks) |b| switch (b) {
        .text, .heading, .rule => n += 1,
        .list => |items| n += items.len,
        .table => |t| n += 1 + t.rows.len,
    };
    return @max(n, 1);
}

// ---------------------------------------------------------------------
// Layout math (pure; the overlay supplies measured widths)
// ---------------------------------------------------------------------

/// One wrapped line of a table cell: the token index range [start, end).
pub const WrapLine = struct { start: usize, end: usize };

/// Greedy word wrap over pre-measured tokens. `widths[i]` is token i's
/// measured width; `is_space[i]` marks whitespace tokens. A break happens
/// before a non-space token that would exceed `max_w`; space tokens at a
/// line start are dropped. A lone token wider than `max_w` gets its own
/// line (it clips rather than breaking mid-token — the sole divergence
/// from the Mac, which can break a super-long word mid-character).
pub fn wrapTokens(
    arena: Allocator,
    widths: []const f32,
    is_space: []const bool,
    max_w: f32,
) Allocator.Error![]WrapLine {
    std.debug.assert(widths.len == is_space.len);
    var lines: std.ArrayList(WrapLine) = .empty;
    var start: usize = 0;
    var x: f32 = 0;
    var i: usize = 0;
    while (i < widths.len) : (i += 1) {
        if (is_space[i] and x == 0 and start == i) {
            // Drop leading whitespace on a wrapped line.
            start = i + 1;
            continue;
        }
        if (!is_space[i] and x > 0 and x + widths[i] > max_w) {
            try lines.append(arena, .{ .start = start, .end = i });
            start = i;
            x = 0;
            // Re-check this token for leading-space semantics (it isn't
            // a space, so it just starts the new line).
        }
        x += widths[i];
    }
    if (start < widths.len) try lines.append(arena, .{ .start = start, .end = widths.len });
    if (lines.items.len == 0) try lines.append(arena, .{ .start = 0, .end = 0 });
    return lines.items;
}

// ---------------------------------------------------------------------
// Block scanners
// ---------------------------------------------------------------------

fn isBlank(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn trimSpaces(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t");
}

/// A line participates in a table when its trimmed text starts with `|`.
fn isTableRow(line: []const u8) bool {
    const t = trimSpaces(line);
    return t.len > 0 and t[0] == '|';
}

/// A thematic break: a line of 3+ of the same `-`, `*`, or `_` with
/// nothing else but optional spaces (`---`, `***`, `___`, `- - -`).
fn isThematicBreak(line: []const u8) bool {
    const t = trimSpaces(line);
    if (t.len == 0) return false;
    const first = t[0];
    if (first != '-' and first != '*' and first != '_') return false;
    var marks: usize = 0;
    for (t) |c| {
        if (c == ' ') continue;
        if (c != first) return false;
        marks += 1;
    }
    return marks >= 3;
}

/// An ATX heading: 1–6 leading `#`, a required space, then non-empty text.
fn headingLine(line: []const u8) ?struct { level: u8, text: []const u8 } {
    var t = line;
    while (t.len > 0 and t[0] == ' ') t = t[1..];
    var level: u8 = 0;
    while (level < 6 and level < t.len and t[level] == '#') level += 1;
    if (level == 0) return null;
    if (level >= t.len or t[level] != ' ') return null;
    var text = t[level + 1 ..];
    while (text.len > 0 and text[0] == ' ') text = text[1..];
    if (text.len == 0) return null;
    return .{ .level = level, .text = text };
}

/// Split a table row into trimmed cell texts on unescaped `|`, dropping
/// the empty segments produced by the structural leading/trailing pipes.
/// Escapes are preserved in the cell text (the inline parser resolves
/// them, so `\|` becomes a literal pipe).
fn splitCells(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    const t = trimSpaces(line);
    var cells: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        if (c == '\\' and i + 1 < t.len) {
            try current.append(arena, c);
            try current.append(arena, t[i + 1]);
            i += 2;
            continue;
        }
        if (c == '|') {
            try cells.append(arena, try arena.dupe(u8, current.items));
            current.clearRetainingCapacity();
        } else {
            try current.append(arena, c);
        }
        i += 1;
    }
    try cells.append(arena, try arena.dupe(u8, current.items));

    var items = cells.items;
    if (items.len > 0 and isBlank(items[0])) items = items[1..];
    if (items.len > 0 and isBlank(items[items.len - 1])) items = items[0 .. items.len - 1];
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |cell, idx| out[idx] = trimSpaces(cell);
    return out;
}

/// `---`, `:---`, `---:`, or `:---:` (at least one dash).
fn isSeparatorCell(cell: []const u8) bool {
    var body = cell;
    if (body.len > 0 and body[0] == ':') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == ':') body = body[0 .. body.len - 1];
    if (body.len == 0) return false;
    for (body) |c| if (c != '-') return false;
    return true;
}

fn columnAlignment(cell: []const u8) ?ColumnAlignment {
    const leading = cell.len > 0 and cell[0] == ':';
    const trailing = cell.len > 1 and cell[cell.len - 1] == ':';
    if (leading and trailing) return .center;
    if (trailing) return .trailing;
    if (leading) return .leading;
    return null;
}

/// Classify `line` as a list item, returning its marker and the content
/// that follows. A `- `/`* ` directly before a checkbox is the checkbox's
/// marker, not a separate bullet. A decimal like `1.5` (no space after
/// the dot) is not a list.
fn listItem(line: []const u8) ?struct { marker: ListMarker, content: []const u8 } {
    var t = line;
    while (t.len > 0 and t[0] == ' ') t = t[1..];
    if (t.len == 0) return null;

    var after_dash = t;
    const had_dash = std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ");
    if (had_dash) after_dash = t[2..];

    if (checkboxToken(after_dash, 0)) |cb| {
        var content = after_dash[cb.after..];
        while (content.len > 0 and content[0] == ' ') content = content[1..];
        return .{ .marker = .{ .checkbox = cb.checked }, .content = content };
    }
    if (had_dash) {
        var content = after_dash;
        while (content.len > 0 and content[0] == ' ') content = content[1..];
        return .{ .marker = .bullet, .content = content };
    }
    if (orderedPrefix(t)) |o| {
        var content = o.rest;
        while (content.len > 0 and content[0] == ' ') content = content[1..];
        return .{ .marker = .{ .ordered = o.number }, .content = content };
    }
    return null;
}

/// Match a leading `<digits>. ` (period then a required space). Returns
/// the number and the text after the space.
fn orderedPrefix(s: []const u8) ?struct { number: u32, rest: []const u8 } {
    var idx: usize = 0;
    while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') idx += 1;
    if (idx == 0) return null;
    const number = std.fmt.parseInt(u32, s[0..idx], 10) catch return null;
    if (idx >= s.len or s[idx] != '.') return null;
    if (idx + 1 >= s.len or s[idx + 1] != ' ') return null;
    return .{ .number = number, .rest = s[idx + 2 ..] };
}

/// If a task-list checkbox token (`[x]`, `[X]`, or `[ ]`) begins at `at`,
/// return whether it's checked and the index just past the token. Returns
/// null when a `(` follows the closing `]` (then it's a `[text](url)`
/// link, not a checkbox).
fn checkboxToken(s: []const u8, at: usize) ?struct { checked: bool, after: usize } {
    if (at + 2 >= s.len or s[at] != '[' or s[at + 2] != ']') return null;
    const checked = switch (s[at + 1]) {
        'x', 'X' => true,
        ' ' => false,
        else => return null,
    };
    const after = at + 3;
    if (after < s.len and s[after] == '(') return null;
    return .{ .checked = checked, .after = after };
}

// ---------------------------------------------------------------------
// Inline parser
// ---------------------------------------------------------------------

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

/// Parse inline markdown into ordered segments. When `native_checkbox` is
/// true (table cells, list content), each top-level `[x]`/`[ ]` becomes a
/// native `.checkbox` segment and a leading `- `/`* ` directly before one
/// is consumed as its marker. Nested contexts (styled spans, link labels)
/// and plain text/heading lines get the `☑`/`☐` glyph fallback instead.
pub fn parseSegs(
    arena: Allocator,
    s: []const u8,
    native_checkbox: bool,
) Allocator.Error![]const Inline {
    var out: std.ArrayList(Inline) = .empty;
    try parseInline(arena, &out, s, .{}, null, native_checkbox, true);
    return out.items;
}

fn parseInline(
    arena: Allocator,
    out: *std.ArrayList(Inline),
    s: []const u8,
    style: Style,
    link: ?[]const u8,
    native_checkbox: bool,
    at_line_start: bool,
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

        // Task-list list marker: a leading "- "/"* " directly before a
        // checkbox token is consumed so "- [x] done" renders "☑ done".
        if (i == 0 and at_line_start and native_checkbox and
            (std.mem.startsWith(u8, s, "- ") or std.mem.startsWith(u8, s, "* ")) and
            checkboxToken(s, 2) != null)
        {
            i = 2;
            continue;
        }

        // Task-list checkbox. Runs before the link parser so a bare [x]
        // isn't swallowed by the [text](url) path; [x](url) stays a link
        // (checkboxToken rejects it).
        if (checkboxToken(s, i)) |cb| {
            if (native_checkbox) {
                try flushLiteral(arena, out, &literal, style, link);
                try out.append(arena, .{ .checkbox = cb.checked });
            } else {
                try literal.appendSlice(arena, if (cb.checked) "\u{2611}" else "\u{2610}");
            }
            i = cb.after;
            continue;
        }

        // Links: [text](url), url must have a scheme.
        if (c == '[') link_blk: {
            const close_bracket = findUnescaped(s, i + 1, "]") orelse break :link_blk;
            if (close_bracket + 1 >= s.len or s[close_bracket + 1] != '(') break :link_blk;
            const close_paren = findUnescaped(s, close_bracket + 2, ")") orelse break :link_blk;
            const url = s[close_bracket + 2 .. close_paren];
            if (!hasScheme(url)) break :link_blk;

            try flushLiteral(arena, out, &literal, style, link);
            var linked_style = style;
            linked_style.underline = true;
            try parseInline(
                arena,
                out,
                s[i + 1 .. close_bracket],
                linked_style,
                try arena.dupe(u8, url),
                false,
                false,
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
            try flushLiteral(arena, out, &literal, style, link);
            var styled = style;
            switch (d.style) {
                .bold => styled.bold = true,
                .italic => styled.italic = true,
                .underline => styled.underline = true,
                .code => styled.code = true,
            }
            if (d.style == .code) {
                // Code spans are literal; everything else nests.
                try out.append(arena, .{ .seg = .{
                    .text = try arena.dupe(u8, inner),
                    .style = styled,
                    .link = link,
                } });
            } else {
                try parseInline(arena, out, inner, styled, link, false, false);
            }
            i = close + d.token.len;
            continue;
        }

        try literal.append(arena, c);
        i += 1;
    }

    try flushLiteral(arena, out, &literal, style, link);
}

fn flushLiteral(
    arena: Allocator,
    out: *std.ArrayList(Inline),
    literal: *std.ArrayList(u8),
    style: Style,
    link: ?[]const u8,
) Allocator.Error!void {
    if (literal.items.len == 0) return;
    try out.append(arena, .{ .seg = .{
        .text = try arena.dupe(u8, literal.items),
        .style = style,
        .link = link,
    } });
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

fn textSegs(block: Block) []const Inline {
    return switch (block) {
        .text => |t| t,
        else => unreachable,
    };
}

fn seg(inl: Inline) Seg {
    return switch (inl) {
        .seg => |s| s,
        else => unreachable,
    };
}

test "plain text is a single unstyled run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "hello world");
    try testing.expectEqual(@as(usize, 1), blocks.len);
    const segs = textSegs(blocks[0]);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("hello world", seg(segs[0]).text);
    try testing.expectEqual(Style{}, seg(segs[0]).style);
    try testing.expectEqual(@as(?[]const u8, null), seg(segs[0]).link);
}

test "bold italic underline code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "**b** *i* _i2_ __u__ `c`");
    const segs = textSegs(blocks[0]);
    try testing.expectEqual(@as(usize, 9), segs.len); // 5 styled + 4 spaces
    try testing.expect(seg(segs[0]).style.bold);
    try testing.expectEqualStrings("b", seg(segs[0]).text);
    try testing.expect(seg(segs[2]).style.italic);
    try testing.expect(seg(segs[4]).style.italic);
    try testing.expectEqualStrings("i2", seg(segs[4]).text);
    try testing.expect(seg(segs[6]).style.underline);
    try testing.expect(seg(segs[8]).style.code);
}

test "code span contents are literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "`**not bold**`");
    const segs = textSegs(blocks[0]);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expect(seg(segs[0]).style.code);
    try testing.expect(!seg(segs[0]).style.bold);
    try testing.expectEqualStrings("**not bold**", seg(segs[0]).text);
}

test "link with scheme; without scheme renders literally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const linked = textSegs((try parseBlocks(arena.allocator(), "[view](https://example.com/pr)"))[0]);
    try testing.expectEqual(@as(usize, 1), linked.len);
    try testing.expectEqualStrings("view", seg(linked[0]).text);
    try testing.expect(seg(linked[0]).style.underline);
    try testing.expectEqualStrings("https://example.com/pr", seg(linked[0]).link.?);

    const plain = textSegs((try parseBlocks(arena.allocator(), "[view](example.com)"))[0]);
    try testing.expectEqual(@as(usize, 1), plain.len);
    try testing.expectEqualStrings("[view](example.com)", seg(plain[0]).text);
    try testing.expectEqual(@as(?[]const u8, null), seg(plain[0]).link);
}

test "styles nest: bold containing a link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const segs = textSegs((try parseBlocks(arena.allocator(), "**PR [123](https://x.io/1)**"))[0]);
    try testing.expectEqual(@as(usize, 2), segs.len);
    try testing.expect(seg(segs[0]).style.bold);
    try testing.expectEqualStrings("PR ", seg(segs[0]).text);
    try testing.expect(seg(segs[1]).style.bold);
    try testing.expect(seg(segs[1]).style.underline);
    try testing.expectEqualStrings("https://x.io/1", seg(segs[1]).link.?);
}

test "unterminated delimiters render literally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const segs = textSegs((try parseBlocks(arena.allocator(), "**open _tail `code"))[0]);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("**open _tail `code", seg(segs[0]).text);
    try testing.expectEqual(Style{}, seg(segs[0]).style);
}

test "escapes suppress styling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const segs = textSegs((try parseBlocks(arena.allocator(), "\\*\\*not bold\\*\\* \\\\ \\[x](https://y.io)"))[0]);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("**not bold** \\ [x](https://y.io)", seg(segs[0]).text);
}

test "line cap: 12 text lines keep 10" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl");
    try testing.expectEqual(@as(usize, max_lines), blocks.len);
    try testing.expectEqual(@as(usize, max_lines), displayLines(blocks));
    try testing.expectEqualStrings("j", seg(textSegs(blocks[9])[0]).text);
}

test "blank lines drop; styling spans one line only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "**a\n\n   \nb**");
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqualStrings("**a", seg(textSegs(blocks[0])[0]).text);
    try testing.expectEqualStrings("b**", seg(textSegs(blocks[1])[0]).text);
}

test "empty source yields no blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), blocks.len);
    try testing.expectEqual(@as(usize, 1), displayLines(blocks));
}

test "headings: levels, no-space and 7-hash are text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "# Title\n###### deep\n#nospace\n####### seven");
    try testing.expectEqual(@as(usize, 4), blocks.len);
    try testing.expectEqual(@as(u8, 1), blocks[0].heading.level);
    try testing.expectEqualStrings("Title", seg(blocks[0].heading.content[0]).text);
    try testing.expectEqual(@as(u8, 6), blocks[1].heading.level);
    try testing.expect(blocks[2] == .text);
    try testing.expect(blocks[3] == .text);
}

test "heading text carries inline styles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "## a **b**");
    const content = blocks[0].heading.content;
    try testing.expectEqual(@as(usize, 2), content.len);
    try testing.expect(seg(content[1]).style.bold);
}

test "thematic breaks vs bullets and bold lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "---\n***\n___\n- - -\n**bold**\n- item\n--");
    try testing.expectEqual(@as(usize, 7), blocks.len);
    try testing.expect(blocks[0] == .rule);
    try testing.expect(blocks[1] == .rule);
    try testing.expect(blocks[2] == .rule);
    try testing.expect(blocks[3] == .rule);
    try testing.expect(blocks[4] == .text);
    try testing.expect(blocks[5] == .list);
    try testing.expect(blocks[6] == .text);
}

test "list run: mixed markers form one block, content parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(
        arena.allocator(),
        "- bullet\n* star\n1. first\n12. twelfth\n[x] done\n[ ] todo\n- [X] dashed",
    );
    try testing.expectEqual(@as(usize, 1), blocks.len);
    const items = blocks[0].list;
    try testing.expectEqual(@as(usize, 7), items.len);
    try testing.expect(items[0].marker == .bullet);
    try testing.expectEqualStrings("bullet", seg(items[0].content[0]).text);
    try testing.expect(items[1].marker == .bullet);
    try testing.expectEqual(@as(u32, 1), items[2].marker.ordered);
    try testing.expectEqual(@as(u32, 12), items[3].marker.ordered);
    try testing.expect(items[4].marker.checkbox);
    try testing.expect(!items[5].marker.checkbox);
    try testing.expect(items[6].marker.checkbox);
    try testing.expectEqualStrings("dashed", seg(items[6].content[0]).text);
}

test "decimal 1.5 is not a list; checkbox link stays a link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "1.5 things\n[x](https://x.io) go");
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expect(blocks[0] == .text);
    try testing.expect(blocks[1] == .text);
    const segs = textSegs(blocks[1]);
    try testing.expectEqualStrings("x", seg(segs[0]).text);
    try testing.expectEqualStrings("https://x.io", seg(segs[0]).link.?);
}

test "checkbox mid-paragraph falls back to glyph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "status [x] shipped");
    const segs = textSegs(blocks[0]);
    try testing.expectEqual(@as(usize, 1), segs.len);
    try testing.expectEqualStrings("status \u{2611} shipped", seg(segs[0]).text);
}

test "table: header, alignments, body, inline styles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(
        arena.allocator(),
        "| Job | State |\n|:---|---:|\n| lint | ok |\n| tests | **3 failed** |",
    );
    try testing.expectEqual(@as(usize, 1), blocks.len);
    const t = blocks[0].table;
    try testing.expectEqual(@as(usize, 2), t.header.len);
    try testing.expectEqualStrings("Job", seg(t.header[0][0]).text);
    try testing.expectEqual(ColumnAlignment.leading, t.alignments[0].?);
    try testing.expectEqual(ColumnAlignment.trailing, t.alignments[1].?);
    try testing.expectEqual(@as(usize, 2), t.rows.len);
    try testing.expect(seg(t.rows[1][1][0]).style.bold);
    try testing.expectEqualStrings("3 failed", seg(t.rows[1][1][0]).text);
    try testing.expect(t.hasVisibleHeader());
    try testing.expectEqual(@as(usize, 3), displayLines(blocks));
}

test "table: center alignment, escaped pipe, ragged rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(
        arena.allocator(),
        "| a | b | c |\n|:---:|---|---|\n| one \\| two | x |\n| 1 | 2 | 3 | 4 |",
    );
    const t = blocks[0].table;
    try testing.expectEqual(ColumnAlignment.center, t.alignments[0].?);
    try testing.expectEqual(@as(?ColumnAlignment, null), t.alignments[1]);
    try testing.expectEqualStrings("one | two", seg(t.rows[0][0][0]).text);
    try testing.expectEqual(@as(usize, 0), t.rows[0][2].len); // padded
    try testing.expectEqual(@as(usize, 3), t.rows[1].len); // truncated
}

test "table: all-empty header is headerless" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "|  |  |\n|---|---|\n| k | v |");
    const t = blocks[0].table;
    try testing.expect(!t.hasVisibleHeader());
    try testing.expectEqual(@as(usize, 1), t.rows.len);
}

test "table: pipe line without separator stays text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "| a | b |\n| not sep |");
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expect(blocks[0] == .text);
    try testing.expect(blocks[1] == .text);
}

test "table cell checkbox is native" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const blocks = try parseBlocks(arena.allocator(), "| t | done |\n|---|---|\n| build | [x] |");
    const cell = blocks[0].table.rows[0][1];
    try testing.expectEqual(@as(usize, 1), cell.len);
    try testing.expect(cell[0].checkbox);
}

test "line cap counts table rows and drops the tail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 3 text + header + 12 rows: text costs 3, header 1, rows fill to 10.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "a\nb\nc\n| h1 | h2 |\n|---|---|\n");
    for (0..12) |n| {
        try src.writer(testing.allocator).print("| r{d} | v |\n", .{n});
    }
    try src.appendSlice(testing.allocator, "tail after cap");
    const blocks = try parseBlocks(arena.allocator(), src.items);
    try testing.expectEqual(@as(usize, 4), blocks.len); // 3 text + table
    const t = blocks[3].table;
    try testing.expectEqual(@as(usize, 6), t.rows.len); // 10 - 3 - 1
    try testing.expectEqual(@as(usize, max_lines), displayLines(blocks));
}

test "wrapTokens: greedy fill, leading-space drop, wide token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Tokens: w(40) sp(10) w(40) sp(10) w(40) — max 100 → 2 lines.
    const widths = [_]f32{ 40, 10, 40, 10, 40 };
    const spaces = [_]bool{ false, true, false, true, false };
    const lines = try wrapTokens(arena.allocator(), &widths, &spaces, 100);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqual(@as(usize, 0), lines[0].start);
    try testing.expectEqual(@as(usize, 4), lines[0].end);
    // Line 2 starts at the word, not the space before it.
    try testing.expectEqual(@as(usize, 4), lines[1].start);
    try testing.expectEqual(@as(usize, 5), lines[1].end);

    // A single token wider than max gets its own line.
    const wide = try wrapTokens(arena.allocator(), &.{ 500, 10, 40 }, &.{ false, true, false }, 100);
    try testing.expectEqual(@as(usize, 2), wide.len);

    // Empty input still yields one (empty) line.
    const empty = try wrapTokens(arena.allocator(), &.{}, &.{}, 100);
    try testing.expectEqual(@as(usize, 1), empty.len);
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
