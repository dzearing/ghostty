//! The feedback composer's DOCUMENT: where a quoted passage goes when it is
//! inserted, and which quotes are still in the report when it is sent (T641,
//! the win32 half of Mac's `feedbackQuoteID` runs).
//!
//! Pure — text in, text out, no OS surface — so it is unit tested in the
//! `-Dapp-runtime=none` lane like the rest of `apprt/win32`'s pure modules.
//! `ViewerFeedbackBar` drives the RichEdit from what this decides, and
//! `ViewerPane` owns the `Registry`.
//!
//! ## Since T935, identity is a NODE — and this is the bridge to it
//!
//! The composer's text surface is a web page now, so a quote IS a
//! `<div class="q" data-qid="N">` and its identity is that attribute: deleting
//! the block drops the metadata with it, and editing the passage keeps it,
//! which is what the derivation below could never do. The page reports its live
//! blocks in every snapshot, and `ViewerPane` keeps those as the truth the
//! report is written from.
//!
//! What survives here, and why it is not dead code: the pane's buffer is PLAIN
//! TEXT and outlives the page (a composer closed and reopened, a report cleared
//! behind a send, the RichEdit fallback), so something has to say which runs of
//! a restored buffer are quotes before the page can build them as nodes. That
//! is `live` — run once at SEED time, not on every read. Everything below is
//! written for the old world, in which it was the only answer; it is still
//! correct, and it is now the on-ramp rather than the road.
//!
//! ## Identity is DERIVED, never stored
//!
//! Mac hangs a `feedbackQuoteID` attribute on the quote's text run, so deleting
//! the run drops its metadata from the report. RichEdit has no per-run user
//! field to hang an id on, and the two obvious substitutes are both worse than
//! the problem: tracking offsets across edits means re-implementing marker
//! maintenance the control will not tell us about, and walking `CHARFORMAT2`
//! runs to find the tinted ones means binary-searching the control's own
//! formatting on every serialize — neither of which can be unit tested without
//! a window.
//!
//! So identity is recovered from the TEXT, which is the one thing both sides
//! agree on: a registry entry is live when its passage still occupies a
//! complete run of LINES in the composer, at or after the previous live
//! quote's end. Matching in registry order against non-overlapping
//! line-aligned occurrences is what makes the same passage quoted twice two
//! quotes, and what makes a deleted block's metadata vanish with it — the same
//! derive-from-storage rule the image carousel uses, expressed without a field
//! RichEdit does not have.
//!
//! Line-aligned, not "appears anywhere", on purpose: a quote is inserted as its
//! own block, so a passage the user happens to TYPE mid-sentence is not
//! mistaken for the quote of it. The remaining ambiguity — retyping a passage
//! as its own whole line — is harmless: the metadata it would attach is the
//! metadata for that same text.
//!
//! ## Editing a quote
//!
//! Changing a quote's characters makes it stop matching, so its metadata drops
//! while the text stays in the report. That is deliberate and is the honest
//! answer for a control where the user CAN edit it: the referential context
//! (heading, block selector, document offset) describes the passage as it was
//! on the page, and once the text is not that passage any more, the context is
//! no longer true of it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const bridge = @import("viewer_bridge.zig");

/// One quoted passage and the referential context the report writer (T637)
/// needs. Owns every string; freed by `Registry.deinit`.
pub const Entry = struct {
    /// Stable within one composer session, and never reused — the number a
    /// future `[Quote #N]` affordance would show, allocated the way the image
    /// carousel allocates chip numbers.
    id: u32,
    text: []const u8,
    heading_id: ?[]const u8 = null,
    heading_text: ?[]const u8 = null,
    block_selector: ?[]const u8 = null,
    block_text: ?[]const u8 = null,
    offset_in_block: ?u32 = null,
    document_offset: ?u32 = null,
};

/// Where a live quote sits in the composer text, as a byte range over complete
/// lines. `index` is into the registry's `entries`.
pub const Span = struct {
    start: usize,
    end: usize,
    index: usize,
};

/// Every quote inserted into this composer, in insertion order. Entries are
/// never removed when the user deletes a block — `live` simply stops matching
/// them, which is what keeps "what is in the report" a function of the text
/// rather than of a side-channel someone has to remember to update.
pub const Registry = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_id: u32 = 1,

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        for (self.entries.items) |e| {
            alloc.free(e.text);
            if (e.heading_id) |v| alloc.free(v);
            if (e.heading_text) |v| alloc.free(v);
            if (e.block_selector) |v| alloc.free(v);
            if (e.block_text) |v| alloc.free(v);
        }
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// Copy one bridge message into the registry and return its id.
    ///
    /// The passage is normalised on the way in (see `normalize`) so the text
    /// stored here is byte-identical to the text that lands in the composer —
    /// which is the whole basis of `live`'s matching.
    pub fn add(self: *Registry, alloc: Allocator, q: bridge.Quote) !u32 {
        const text = try normalize(alloc, q.text);
        errdefer alloc.free(text);
        if (text.len == 0) return error.EmptyQuote;

        var e: Entry = .{
            .id = self.next_id,
            .text = text,
            .offset_in_block = q.offset_in_block,
            .document_offset = q.document_offset,
        };
        errdefer freeOptionals(alloc, &e);
        if (q.heading_id) |v| e.heading_id = try alloc.dupe(u8, v);
        if (q.heading_text) |v| e.heading_text = try alloc.dupe(u8, v);
        if (q.block_selector) |v| e.block_selector = try alloc.dupe(u8, v);
        if (q.block_text) |v| e.block_text = try alloc.dupe(u8, v);

        try self.entries.append(alloc, e);
        self.next_id += 1;
        return e.id;
    }

    fn freeOptionals(alloc: Allocator, e: *Entry) void {
        if (e.heading_id) |v| alloc.free(v);
        if (e.heading_text) |v| alloc.free(v);
        if (e.block_selector) |v| alloc.free(v);
        if (e.block_text) |v| alloc.free(v);
    }

    /// Where the entry with `id` sits in `entries`, or null when nothing does.
    ///
    /// The lookup the page's snapshots need (T935): a quote block names itself
    /// by id, and everything downstream — the report's metadata, the span the
    /// body is quoted from — is addressed by index. An id nobody knows is
    /// dropped rather than guessed at; that is a block from a composer session
    /// whose registry is gone, and inventing a match for it would attach one
    /// passage's heading to another's text.
    pub fn indexOfId(self: *const Registry, id: u32) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.id == id) return i;
        }
        return null;
    }

    /// The quotes still present in `text`, in document order. See the header:
    /// this is what the report's `quotes` array is built from, so a block the
    /// user deleted is simply not here.
    pub fn live(self: *const Registry, alloc: Allocator, text: []const u8) ![]Span {
        var out: std.ArrayListUnmanaged(Span) = .empty;
        errdefer out.deinit(alloc);
        var from: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            const at = findLineAligned(text, e.text, from) orelse continue;
            try out.append(alloc, .{ .start = at, .end = at + e.text.len, .index = i });
            from = at + e.text.len;
        }
        return out.toOwnedSlice(alloc);
    }
};

/// Canonical form of a passage: CRLF and bare CR become LF (the composer's
/// buffer speaks LF; RichEdit speaks CR, and `ViewerFeedbackBar` converts at
/// the boundary), and surrounding whitespace goes. A passage that trimmed away
/// to nothing is not a quote.
pub fn normalize(alloc: Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r') {
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
            buf.appendAssumeCapacity('\n');
        } else buf.appendAssumeCapacity(raw[i]);
    }
    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    const owned = try alloc.dupe(u8, trimmed);
    buf.deinit(alloc);
    return owned;
}

/// The edit that puts `passage` into `text` at `caret` as its own block.
///
/// `at` is where the delta goes (always the caret), `insert` is what to write
/// there, and `caret_after` is where the caret ends up: on a fresh line BELOW
/// the block, because the point of quoting is to say something about it.
pub const Insertion = struct {
    at: usize,
    insert: []u8,
    caret_after: usize,

    pub fn deinit(self: Insertion, alloc: Allocator) void {
        alloc.free(self.insert);
    }
};

/// Blank lines the block needs around it so it occupies complete lines with
/// air either side — computed from what is ALREADY there, so quoting twice in
/// a row does not stack up empty lines.
pub fn insertion(
    alloc: Allocator,
    text: []const u8,
    caret_in: usize,
    passage: []const u8,
) !Insertion {
    const caret = @min(caret_in, text.len);
    const lead = leadNewlines(text[0..caret]);
    const trail = trailNewlines(text[caret..]);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.ensureTotalCapacity(alloc, lead + passage.len + trail);
    buf.appendNTimesAssumeCapacity('\n', lead);
    buf.appendSliceAssumeCapacity(passage);
    buf.appendNTimesAssumeCapacity('\n', trail);

    return .{
        .at = caret,
        .insert = try buf.toOwnedSlice(alloc),
        // Past the blank line under the block, whether those newlines came
        // from `trail` or were already in the text. Clamped, because a caret
        // beyond the document is a caret RichEdit will refuse to place.
        .caret_after = @min(
            caret + lead + passage.len + 2,
            text.len + lead + passage.len + trail,
        ),
    };
}

/// How many newlines have to precede the block: enough that it starts on its
/// own line with one blank line above it, and none at all at the very top of
/// an empty composer.
fn leadNewlines(before: []const u8) usize {
    if (before.len == 0) return 0;
    var n: usize = 0;
    var i = before.len;
    while (i > 0 and before[i - 1] == '\n' and n < 2) : (i -= 1) n += 1;
    return 2 - n;
}

/// The same, after the block. Two newlines even at the end of the document:
/// that is the line the user is about to type on.
fn trailNewlines(after: []const u8) usize {
    var n: usize = 0;
    while (n < after.len and after[n] == '\n' and n < 2) n += 1;
    return 2 - n;
}

/// The first occurrence of `needle` in `haystack` at or after `from` that
/// occupies COMPLETE lines — see the header for why "anywhere" is the wrong
/// rule. An empty needle never matches.
pub fn findLineAligned(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i = @min(from, haystack.len);
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| : (i = at + 1) {
        const starts = at == 0 or haystack[at - 1] == '\n';
        const end = at + needle.len;
        const ends = end == haystack.len or haystack[end] == '\n';
        if (starts and ends) return at;
    }
    return null;
}

/// Whether `pos` is strictly inside one of `spans` — the question "does the
/// character about to be typed here inherit quote styling?", which
/// `ViewerFeedbackBar` asks before every keystroke.
///
/// The block's own END is deliberately NOT inside it: a caret sitting just
/// past the last quoted character is on its way out of the quote, and text
/// typed there belongs to the report, not to the passage.
pub fn insideQuote(spans: []const Span, pos: usize) bool {
    for (spans) |s| {
        if (pos >= s.start and pos < s.end) return true;
    }
    return false;
}

/// Whether the LINE `pos` sits on overlaps a quote — the paragraph-level
/// version of `insideQuote`, and a separate question on purpose.
///
/// Character formatting is per character, so the caret one past a quote's last
/// character must type PLAIN. Paragraph formatting (the block's indent) is per
/// paragraph, and that same caret is still inside the quote's LAST PARAGRAPH:
/// resetting the indent from there would un-indent the whole block the user is
/// typing at the end of.
pub fn lineTouchesQuote(text: []const u8, spans: []const Span, pos_in: usize) bool {
    const pos = @min(pos_in, text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |at| at + 1 else 0;
    const end = if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |at| at else text.len;
    for (spans) |s| {
        // Half-open ranges that touch at an endpoint do not overlap.
        if (s.start < end and start < s.end) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// Apply an insertion to a buffer, the way the control does — the little bit
/// of glue that lets a test assert on the RESULTING document rather than on a
/// delta and an offset.
fn applied(alloc: Allocator, text: []const u8, caret: usize, passage: []const u8) ![]u8 {
    const ins = try insertion(alloc, text, caret, passage);
    defer ins.deinit(alloc);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, text[0..ins.at]);
    try out.appendSlice(alloc, ins.insert);
    try out.appendSlice(alloc, text[ins.at..]);
    return out.toOwnedSlice(alloc);
}

test "normalize: line endings and surrounding space" {
    const alloc = testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "  hello  ", .want = "hello" },
        .{ .in = "a\r\nb", .want = "a\nb" },
        .{ .in = "a\rb", .want = "a\nb" },
        .{ .in = "\n\nkeep me\n\n", .want = "keep me" },
        .{ .in = "   \t\n ", .want = "" },
    };
    for (cases) |c| {
        const got = try normalize(alloc, c.in);
        defer alloc.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "insertion: an empty composer gets the block and nothing else" {
    const alloc = testing.allocator;
    const got = try applied(alloc, "", 0, "the passage");
    defer alloc.free(got);
    // No leading blank line at the very top — a report that opens with an
    // empty line is a report that looks broken.
    try testing.expectEqualStrings("the passage\n\n", got);

    const ins = try insertion(alloc, "", 0, "the passage");
    defer ins.deinit(alloc);
    // The caret lands under the block, on the line the user types on.
    try testing.expectEqual(@as(usize, "the passage\n\n".len), ins.caret_after);
}

test "insertion: a block always occupies complete lines" {
    const alloc = testing.allocator;
    // Caret mid-word: the block still starts on its own line, with air above.
    const got = try applied(alloc, "already typed", 7, "quoted");
    defer alloc.free(got);
    try testing.expectEqualStrings("already\n\nquoted\n\n typed", got);
}

test "insertion: existing blank lines are reused, not stacked" {
    const alloc = testing.allocator;
    // One newline before -> one more is added; two -> none.
    const one = try applied(alloc, "note\n", 5, "q");
    defer alloc.free(one);
    try testing.expectEqualStrings("note\n\nq\n\n", one);

    const two = try applied(alloc, "note\n\n", 6, "q");
    defer alloc.free(two);
    try testing.expectEqualStrings("note\n\nq\n\n", two);

    // Quoting twice in a row is the case that stacks blank lines if the
    // trailing side is not counted too.
    const ins = try insertion(alloc, "note\n\nq\n\n", 9, "r");
    defer ins.deinit(alloc);
    const twice = try applied(alloc, "note\n\nq\n\n", 9, "r");
    defer alloc.free(twice);
    try testing.expectEqualStrings("note\n\nq\n\nr\n\n", twice);
    try testing.expectEqual(twice.len, ins.caret_after);
}

test "insertion: a caret past the end is clamped rather than refused" {
    const alloc = testing.allocator;
    const got = try applied(alloc, "abc", 99, "q");
    defer alloc.free(got);
    try testing.expectEqualStrings("abc\n\nq\n\n", got);
}

test "insertion: a multi-line passage stays one block" {
    const alloc = testing.allocator;
    const got = try applied(alloc, "", 0, "line one\nline two");
    defer alloc.free(got);
    try testing.expectEqualStrings("line one\nline two\n\n", got);
}

/// A bridge quote with just the fields a test cares about.
fn quoteOf(text: []const u8) bridge.Quote {
    return .{ .text = text };
}

test "live: an inserted quote is found, and a deleted one is not" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);

    const id = try reg.add(alloc, .{
        .text = "the passage",
        .heading_id = "intro",
        .heading_text = "Intro",
        .block_selector = "article > p:nth-of-type(2)",
        .block_text = "the whole paragraph",
        .offset_in_block = 12,
        .document_offset = 345,
    });
    try testing.expectEqual(@as(u32, 1), id);

    const doc = try applied(alloc, "", 0, reg.entries.items[0].text);
    defer alloc.free(doc);

    {
        const spans = try reg.live(alloc, doc);
        defer alloc.free(spans);
        try testing.expectEqual(@as(usize, 1), spans.len);
        try testing.expectEqualStrings(
            "the passage",
            doc[spans[0].start..spans[0].end],
        );
        // ...and the metadata rides with it, which is what the report writer
        // reads.
        const e = reg.entries.items[spans[0].index];
        try testing.expectEqualStrings("intro", e.heading_id.?);
        try testing.expectEqual(@as(?u32, 345), e.document_offset);
    }

    // The user selects the block and deletes it. The entry is still in the
    // registry; it is simply not in the report any more.
    {
        const spans = try reg.live(alloc, "just my own words\n");
        defer alloc.free(spans);
        try testing.expectEqual(@as(usize, 0), spans.len);
    }
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}

test "live: typing around a quote does not disturb it" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("the passage"));

    const doc = "this is wrong:\n\nthe passage\n\nbecause of X";
    const spans = try reg.live(alloc, doc);
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("the passage", doc[spans[0].start..spans[0].end]);
    // The text typed after the block is NOT part of the quote — the span ends
    // at the passage, which is what keeps the report's `quotes` honest.
    try testing.expectEqual(@as(usize, 16), spans[0].start);
    try testing.expectEqual(@as(usize, 27), spans[0].end);
}

test "live: the same passage quoted twice is two quotes" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("same words"));
    _ = try reg.add(alloc, quoteOf("same words"));

    const doc = "same words\n\nsame words\n\n";
    const spans = try reg.live(alloc, doc);
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    // Non-overlapping, in document order: the second entry matches the SECOND
    // occurrence, not the first one again.
    try testing.expectEqual(@as(usize, 0), spans[0].start);
    try testing.expectEqual(@as(usize, 12), spans[1].start);

    // Delete one of them and exactly one quote survives.
    const one = try reg.live(alloc, "same words\n\n");
    defer alloc.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
}

test "live: a passage the user merely TYPED mid-sentence is not a quote" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("the passage"));

    // Line-aligned matching is the whole reason this is not a false positive.
    const spans = try reg.live(alloc, "I typed the passage myself\n");
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "live: editing a quote's text drops its metadata" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("the passage"));

    const spans = try reg.live(alloc, "the pssage\n\n"); // one character gone
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "live: a multi-line quote matches across its own newlines" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("line one\nline two"));

    const doc = "line one\nline two\n\nmy comment";
    const spans = try reg.live(alloc, doc);
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqualStrings("line one\nline two", doc[spans[0].start..spans[0].end]);
}

test "add: an empty passage is refused rather than stored" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    try testing.expectError(error.EmptyQuote, reg.add(alloc, quoteOf("   \n ")));
    try testing.expectEqual(@as(usize, 0), reg.entries.items.len);
}

test "add: ids are never reused" {
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), try reg.add(alloc, quoteOf("a")));
    try testing.expectEqual(@as(u32, 2), try reg.add(alloc, quoteOf("b")));
    // A refused add does not burn an id either.
    try testing.expectError(error.EmptyQuote, reg.add(alloc, quoteOf("")));
    try testing.expectEqual(@as(u32, 3), try reg.add(alloc, quoteOf("c")));
}

test "add: a quote arriving with CRLF is stored the way it will be inserted" {
    // The matching in `live` is byte equality against the composer's LF
    // buffer, so a stored CR would make a quote that can never be found again.
    const alloc = testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(alloc);
    _ = try reg.add(alloc, quoteOf("first\r\nsecond"));
    try testing.expectEqualStrings("first\nsecond", reg.entries.items[0].text);

    const doc = try applied(alloc, "", 0, reg.entries.items[0].text);
    defer alloc.free(doc);
    const spans = try reg.live(alloc, doc);
    defer alloc.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
}

test "insideQuote: the caret just past a block is OUTSIDE it" {
    // This is the "typing never inherits quote styling" rule, in its pure
    // form: the character position the caret sits at after the block must not
    // be reported as inside, or every keystroke after a quote would be styled
    // as part of it.
    const spans = [_]Span{.{ .start = 4, .end = 10, .index = 0 }};
    try testing.expect(!insideQuote(&spans, 3));
    try testing.expect(insideQuote(&spans, 4));
    try testing.expect(insideQuote(&spans, 9));
    try testing.expect(!insideQuote(&spans, 10));
    try testing.expect(!insideQuote(&spans, 99));
    try testing.expect(!insideQuote(&.{}, 0));
}

test "lineTouchesQuote: the caret at a block's end is still in its paragraph" {
    // "abc\n\nquoted\n\ntail": the quote is [5,11).
    const text = "abc\n\nquoted\n\ntail";
    const spans = [_]Span{.{ .start = 5, .end = 11, .index = 0 }};

    // Character-wise the caret at 11 is OUT of the quote (typing there is
    // plain)...
    try testing.expect(!insideQuote(&spans, 11));
    // ...but it is still on the quote's own line, so the block keeps its
    // indent rather than being flattened by a keystroke at its end.
    try testing.expect(lineTouchesQuote(text, &spans, 11));
    try testing.expect(lineTouchesQuote(text, &spans, 5));
    // The blank line above and the tail below are not the quote's.
    try testing.expect(!lineTouchesQuote(text, &spans, 4));
    try testing.expect(!lineTouchesQuote(text, &spans, 13));
    try testing.expect(!lineTouchesQuote(text, &.{}, 0));
    // A position past the end is clamped rather than an out-of-bounds slice.
    try testing.expect(!lineTouchesQuote(text, &spans, 999));
}

test "findLineAligned: the from-cursor is what keeps matches non-overlapping" {
    const doc = "aa\nbb\naa\n";
    try testing.expectEqual(@as(?usize, 0), findLineAligned(doc, "aa", 0));
    try testing.expectEqual(@as(?usize, 6), findLineAligned(doc, "aa", 1));
    try testing.expectEqual(@as(?usize, null), findLineAligned(doc, "aa", 7));
    try testing.expectEqual(@as(?usize, null), findLineAligned(doc, "", 0));
    try testing.expectEqual(@as(?usize, null), findLineAligned("a", "toolong", 0));
    // A from past the end is clamped, not an out-of-bounds slice.
    try testing.expectEqual(@as(?usize, null), findLineAligned(doc, "aa", 999));
}
