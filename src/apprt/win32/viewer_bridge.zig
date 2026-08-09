//! The viewer pane's JS↔native bridge: the script win32 injects into every
//! page, and the messages that come back up it (T375, design P1/P2).
//!
//! Pure: text and JSON, no OS surface and no COM, so it is unit tested in the
//! `-Dapp-runtime=none` lane like the rest of `apprt/win32`'s pure modules.
//! `ViewerPane.zig` is the only caller — it hands `injected_js` to
//! `AddScriptToExecuteOnDocumentCreated` and `parse` whatever
//! `get_WebMessageAsJson` returns.
//!
//! ## P1 — the shared JS is WebKit-shaped, and stays that way
//!
//! `src/viewer/viewer.js` and `src/viewer/selection.js` talk to native through
//! `window.webkit.messageHandlers.viewerTOC.postMessage(obj)` because they were
//! written against a `WKWebView`. WebView2's bridge is
//! `window.chrome.webview.postMessage(obj)` + `add_WebMessageReceived`, and the
//! JSON the host reads back out of `get_WebMessageAsJson` is the same object
//! either way. So the whole translation is the ~10-line shim below and **no
//! shared JS is forked**: that file is the one part of the viewer that came
//! free with the upstream merge, and a Windows copy of it would mean every
//! future Mac viewer commit needs a Windows translation.
//!
//! ## P2 — shim and `selection.js` are ONE injected blob
//!
//! Mac's lesson is recorded at `ViewerView.swift:429-439`: the selection
//! toolbar cannot ship inside `viewer.js`, which is a `<script src>` in
//! `viewer.html` and therefore only ever runs on the bundled template — which
//! is why quoting worked on markdown and did nothing on a website. It is a
//! `WKUserScript` injected into every page.
//!
//! `AddScriptToExecuteOnDocumentCreated` is the Windows equivalent, and the two
//! halves go in as a SINGLE source so their relative order is not a question a
//! future reader has to answer. Two rules ride along:
//!
//! - **Main frame only.** Mac's user script is `forMainFrameOnly: true`;
//!   WebView2 injects into every frame, so the blob's outermost guard is
//!   `window.top !== window`. The toolbar positions itself in viewport
//!   coordinates a subframe does not share, and a subframe is content we did
//!   not render — it does not get to post to native.
//! - **A missing bridge is not a missing toolbar.** If `chrome.webview` is not
//!   there, the shim skips its install and `selection.js` still runs: its own
//!   `post` already no-ops without a handler, so Copy keeps working and only
//!   Quote goes quiet.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The one message-handler name, matching Mac's `ViewerView.tocMessageName`.
/// Both shared scripts look it up by this exact string.
pub const handler_name = "viewerTOC";

/// `window.webkit.messageHandlers.<handler_name>`, expressed in
/// `window.chrome.webview`. Everything P1 costs.
pub const shim_js =
    \\  var wv = window.chrome && window.chrome.webview;
    \\  if (wv) {
    \\    var target = {
    \\      postMessage: function (message) { wv.postMessage(message); }
    \\    };
    \\    if (!window.webkit) window.webkit = {};
    \\    if (!window.webkit.messageHandlers) window.webkit.messageHandlers = {};
    \\    window.webkit.messageHandlers.
++ handler_name ++ " = target;\n  }\n";

/// The shared selection toolbar, verbatim. Embedded rather than read off disk
/// so Windows has no "resource missing" degrade to reason about (Mac's own is
/// a `logger.warning` and no quoting): the blob either compiled in, or the
/// build failed.
pub const selection_js = @embedFile("../../viewer/selection.js");

const prologue =
    "(function () {\n" ++
    "  \"use strict\";\n" ++
    "  if (window.top !== window) return;\n";

const epilogue = "\n})();\n";

/// What win32 hands `AddScriptToExecuteOnDocumentCreated`: the P2 blob.
///
/// The `"use strict"` is the wrapper's own; `selection.js` declares its own
/// inside its IIFE, so nesting changes nothing for it.
///
/// There is deliberately NO `window.__ghozttyHideQuote = true` in here any
/// more. T162 set that flag because Quote had nowhere to put text — a button
/// wired to nothing is worse than no button — and T641 gave it somewhere (the
/// composer's quoted block), so the flag came out and Windows ships the same
/// two-button toolbar Mac does. The flag itself still exists in the shared
/// `selection.js`; nobody sets it.
pub const injected_js = prologue ++ shim_js ++ selection_js ++ epilogue;

// -------------------------------------------------------------------------
// Messages coming back up
// -------------------------------------------------------------------------

/// One document heading, as `viewer.js` indexes them.
pub const Heading = struct {
    id: []const u8,
    text: []const u8,
    level: u8,
};

/// A passage the selection toolbar's Quote button sent up, with the
/// referential context that lets an agent find it again (CLAUDE.md's
/// "Worktree feedback capture"). Empty strings and negative offsets arrive as
/// null, the same normalization `handleQuoteMessage` does on Mac.
pub const Quote = struct {
    text: []const u8,
    heading_id: ?[]const u8 = null,
    heading_text: ?[]const u8 = null,
    block_selector: ?[]const u8 = null,
    block_text: ?[]const u8 = null,
    offset_in_block: ?u32 = null,
    document_offset: ?u32 = null,
};

/// The three messages the shared JS posts. Mac's `handleTOCMessage` switches on
/// the same three strings and ignores everything else; so does `parse`.
pub const Message = union(enum) {
    /// The document's headings, in order. Empty is a real value — it is what
    /// `clearHeadingIndex` posts when a document goes away.
    headings: []const Heading,
    /// The heading the reader is in, or null when the page says there is none.
    active: ?[]const u8,
    quote: Quote,
};

/// A parsed message and the arena its strings live in.
pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    message: Message,

    pub fn deinit(self: Parsed) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }
};

/// Parse one `get_WebMessageAsJson` payload.
///
/// Returns null for anything this side does not act on — malformed JSON, a
/// non-object, a missing or unknown `type`, or a quote with no text. That is
/// deliberately the same shape as Mac's handler, which `guard`s out of every
/// one of those cases: the blob runs on arbitrary websites, so a page can post
/// whatever it likes through this bridge and "ignore it" has to be the default.
pub fn parse(alloc: Allocator, json_text: []const u8) ?Parsed {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return null;
    arena.* = .init(alloc);
    const message = parseMessage(arena.allocator(), json_text) orelse {
        // Not `errdefer`: this returns an optional, not an error union, so
        // every rejection below is a plain `null` that no errdefer would see.
        arena.deinit();
        alloc.destroy(arena);
        return null;
    };
    return .{ .arena = arena, .message = message };
}

fn parseMessage(aa: Allocator, json_text: []const u8) ?Message {
    // `alloc_always`: every string in the result must live in the arena rather
    // than point back into the caller's buffer — the JSON arrives as a COM-heap
    // string the caller frees the moment this returns.
    const doc = std.json.parseFromSliceLeaky(std.json.Value, aa, json_text, .{
        .allocate = .alloc_always,
    }) catch return null;

    const obj = switch (doc) {
        .object => |o| o,
        else => return null,
    };
    const kind = stringField(obj, "type") orelse return null;

    if (std.mem.eql(u8, kind, "headings")) {
        return .{ .headings = parseHeadings(aa, obj) orelse return null };
    }
    if (std.mem.eql(u8, kind, "active")) {
        return .{ .active = stringField(obj, "id") };
    }
    if (std.mem.eql(u8, kind, "quote")) {
        return .{ .quote = parseQuote(obj) orelse return null };
    }
    return null;
}

/// `payload["items"]`, dropping any entry that is missing a field or has one of
/// the wrong type — Mac's `compactMap`, which keeps one malformed entry from
/// taking the whole list with it.
fn parseHeadings(alloc: Allocator, obj: std.json.ObjectMap) ?[]const Heading {
    const empty: []const Heading = &.{};
    const items = switch (obj.get("items") orelse return empty) {
        .array => |a| a,
        // Mac reads a non-array `items` as an empty list and clears the TOC.
        else => return empty,
    };

    var out: std.ArrayList(Heading) = .empty;
    defer out.deinit(alloc);
    for (items.items) |item| {
        const entry = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const id = stringField(entry, "id") orelse continue;
        const text = stringField(entry, "text") orelse continue;
        const level = switch (entry.get("level") orelse continue) {
            .integer => |n| n,
            else => continue,
        };
        if (level < 1 or level > 6) continue;
        out.append(alloc, .{
            .id = id,
            .text = text,
            .level = @intCast(level),
        }) catch return null;
    }
    return out.toOwnedSlice(alloc) catch null;
}

fn parseQuote(obj: std.json.ObjectMap) ?Quote {
    // Mac guards on the TRIMMED text being non-empty and drops the message
    // otherwise: a quote with nothing in it is not a quote.
    const raw = stringField(obj, "text") orelse return null;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return null;
    return .{
        .text = text,
        .heading_id = nonEmpty(stringField(obj, "headingId")),
        .heading_text = nonEmpty(stringField(obj, "headingText")),
        .block_selector = nonEmpty(stringField(obj, "blockSelector")),
        .block_text = nonEmpty(stringField(obj, "blockText")),
        .offset_in_block = nonNegative(obj, "offsetInBlock"),
        .document_offset = nonNegative(obj, "documentOffset"),
    };
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn nonNegative(obj: std.json.ObjectMap, name: []const u8) ?u32 {
    const n = switch (obj.get(name) orelse return null) {
        .integer => |i| i,
        else => return null,
    };
    if (n < 0 or n > std.math.maxInt(u32)) return null;
    return @intCast(n);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "selection.js is embedded VERBATIM — P1's whole point" {
    // The blob is the wrapper, the shim, and the shared file, in that order,
    // with nothing edited in the middle. Asserting the LENGTH as well as the
    // substring is what makes this a "not forked" check rather than a "starts
    // with" one: a patched copy would still contain the original's opening
    // lines.
    try testing.expect(std.mem.indexOf(u8, injected_js, selection_js) != null);
    try testing.expectEqual(
        prologue.len + shim_js.len + selection_js.len + epilogue.len,
        injected_js.len,
    );
    // And the shared file is the one on disk, not a copy under apprt/win32 —
    // a marker only that file has.
    try testing.expect(std.mem.indexOf(u8, selection_js, "window.__ghozttySelection") != null);
}

test "the selection toolbar names a font that resolves on Windows" {
    // T386: the toolbar's stack used to be `-apple-system, BlinkMacSystemFont,
    // sans-serif`. Neither of the first two resolves here, so the popover drew
    // in Arial — the generic sans-serif — while every other piece of win32
    // chrome is Segoe UI. `system-ui` LEADS the stack because it is the one
    // keyword that is right on both platforms (San Francisco on macOS, Segoe
    // UI here), which is what keeps this a shared file rather than a fork.
    const decl = "font-family: system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;";
    try testing.expect(std.mem.indexOf(u8, selection_js, decl) != null);

    // Matching the whole declaration is what makes `system-ui` FIRST rather
    // than merely present — an entry behind `-apple-system` would never be
    // reached on macOS and would not fix Windows either, since the family that
    // decides the render is whichever one resolves first. And the toolbar has
    // exactly ONE font declaration, so this check covers all of it.
    var decls: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, selection_js, i, "font-family:")) |at| : (i = at + 1) decls += 1;
    try testing.expectEqual(@as(usize, 1), decls);
}

test "the injected blob is main-frame-only, and the guard comes first" {
    try testing.expect(std.mem.indexOf(u8, injected_js, "if (window.top !== window) return;") != null);

    // Order is the assertion: a subframe must be turned away BEFORE either the
    // shim installs a bridge or the toolbar starts listening.
    const guard = std.mem.indexOf(u8, injected_js, "window.top !== window").?;
    const shim = std.mem.indexOf(u8, injected_js, "window.chrome && window.chrome.webview").?;
    const toolbar = std.mem.indexOf(u8, injected_js, "window.__ghozttySelection").?;
    try testing.expect(guard < shim);
    try testing.expect(shim < toolbar);
}

test "the shim names the same handler the shared JS looks up" {
    // The one string that has to agree across three files. If `handler_name`
    // drifts, the shared JS's `bridge()` returns undefined and every message is
    // silently dropped — no error anywhere, which is exactly the failure this
    // assertion exists to make loud.
    try testing.expectEqualStrings("viewerTOC", handler_name);
    const shared_lookup = "window.webkit.messageHandlers." ++ handler_name;
    try testing.expect(std.mem.indexOf(u8, shim_js, shared_lookup ++ " = target;") != null);
    // Both shared scripts read it back through the same path.
    try testing.expect(std.mem.indexOf(u8, selection_js, "messageHandlers." ++ handler_name) != null);
}

test "the wrapper we wrote closes every brace it opens" {
    // Scoped to OUR text — prologue + shim + epilogue. A concatenation slip (a
    // missing `})();`, a stray brace) yields a script that throws on every page
    // and takes quoting down with it, and that failure would only ever show up
    // inside a browser. `selection.js` is deliberately outside the scan: it is
    // upstream's file, and a brace-counter that trips on a future Mac edit
    // would be a test failing for something it does not own.
    const ours = prologue ++ shim_js ++ epilogue;
    var depth: isize = 0;
    for (ours) |c| {
        switch (c) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
        // Never negative: a `}` before its `{` means the wrapper is inside out.
        try testing.expect(depth >= 0);
    }
    try testing.expectEqual(@as(isize, 0), depth);

    // The wrapper is an IIFE, so the shim runs at injection time rather than
    // defining a function nobody calls.
    try testing.expect(std.mem.endsWith(u8, epilogue, "})();\n"));
}

test "T641: the blob does NOT hide Quote any more" {
    // The inversion of T162's assertion, and the reason it is still a test
    // rather than a deleted one: this flag is the single line that decides
    // whether Windows ships one selection button or two, and re-adding it
    // anywhere in the blob would silently take quoting away again with no
    // error and nothing to grep for at runtime.
    //
    // The shared `selection.js` still READS the flag — Mac's file is not
    // forked — so the assertion is about what win32 injects, not about what
    // the toolbar understands.
    try testing.expect(std.mem.indexOf(u8, selection_js, "window.__ghozttyHideQuote") != null);
    // Any ASSIGNMENT to it, in any spelling — `= true`, `= 1`, whatever — is
    // what would hide Quote again, so the assertion is about the `=` rather
    // than about one exact line. (The shared file mentions the name twice: its
    // own `if (!window.…)` read, and the comment above it. Neither assigns.)
    var i: usize = 0;
    var assignments: usize = 0;
    while (std.mem.indexOfPos(u8, injected_js, i, "__ghozttyHideQuote")) |at| : (i = at + 1) {
        const after = std.mem.trimLeft(u8, injected_js[at + "__ghozttyHideQuote".len ..], " ");
        if (std.mem.startsWith(u8, after, "=") and !std.mem.startsWith(u8, after, "==")) {
            assignments += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), assignments);
}

test "the shim survives a page that already defines window.webkit" {
    // A site of our own is not the only thing this runs on. The install must
    // ADD a handler rather than replace whatever object is there, or the blob
    // breaks the page it was injected into.
    try testing.expect(std.mem.indexOf(u8, shim_js, "if (!window.webkit) window.webkit = {};") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        shim_js,
        "if (!window.webkit.messageHandlers) window.webkit.messageHandlers = {};",
    ) != null);
    // ...and a runtime with no `chrome.webview` skips the install instead of
    // throwing, which would take `selection.js` down with it.
    try testing.expect(std.mem.indexOf(u8, shim_js, "if (wv) {") != null);
}

test "parse: headings" {
    const parsed = parse(testing.allocator,
        \\{"type":"headings","items":[
        \\  {"id":"intro","text":"Intro","level":1},
        \\  {"id":"deep","text":"Deep","level":3}
        \\]}
    ).?;
    defer parsed.deinit();

    const items = parsed.message.headings;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("intro", items[0].id);
    try testing.expectEqualStrings("Intro", items[0].text);
    try testing.expectEqual(@as(u8, 1), items[0].level);
    try testing.expectEqualStrings("deep", items[1].id);
    try testing.expectEqual(@as(u8, 3), items[1].level);
}

test "parse: a malformed heading is dropped, not the whole list" {
    // Mac's `compactMap`. The list still has to arrive, or one bad entry blanks
    // a document's whole table of contents.
    const parsed = parse(testing.allocator,
        \\{"type":"headings","items":[
        \\  {"id":"ok","text":"Ok","level":2},
        \\  {"id":"no-level","text":"Nope"},
        \\  {"id":42,"text":"Wrong type","level":1},
        \\  {"id":"out-of-range","text":"Nope","level":9},
        \\  "not an object"
        \\]}
    ).?;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.message.headings.len);
    try testing.expectEqualStrings("ok", parsed.message.headings[0].id);
}

test "parse: an empty heading list is a real message" {
    // `clearHeadingIndex` posts exactly this when a document goes away, and it
    // must clear the TOC rather than be ignored as noise.
    const parsed = parse(testing.allocator, "{\"type\":\"headings\",\"items\":[]}").?;
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.message.headings.len);
}

test "parse: active" {
    const parsed = parse(testing.allocator, "{\"type\":\"active\",\"id\":\"deep\"}").?;
    defer parsed.deinit();
    try testing.expectEqualStrings("deep", parsed.message.active.?);

    // The page reports "no active heading" by leaving `id` off, and that has to
    // clear the highlight rather than be dropped.
    const cleared = parse(testing.allocator, "{\"type\":\"active\"}").?;
    defer cleared.deinit();
    try testing.expectEqual(@as(?[]const u8, null), cleared.message.active);
}

test "parse: quote carries its referential context" {
    const parsed = parse(testing.allocator,
        \\{"type":"quote","text":"  the passage  ","headingId":"intro",
        \\ "headingText":"Intro","blockSelector":"article > p:nth-of-type(2)",
        \\ "blockText":"the whole paragraph","offsetInBlock":12,
        \\ "documentOffset":345}
    ).?;
    defer parsed.deinit();

    const q = parsed.message.quote;
    // Trimmed, like Mac's — a selection usually carries the whitespace the drag
    // ended on.
    try testing.expectEqualStrings("the passage", q.text);
    try testing.expectEqualStrings("intro", q.heading_id.?);
    try testing.expectEqualStrings("Intro", q.heading_text.?);
    try testing.expectEqualStrings("article > p:nth-of-type(2)", q.block_selector.?);
    try testing.expectEqualStrings("the whole paragraph", q.block_text.?);
    try testing.expectEqual(@as(?u32, 12), q.offset_in_block);
    try testing.expectEqual(@as(?u32, 345), q.document_offset);
}

test "parse: quote normalizes empties and negatives to null" {
    // `selection.js` sends "" and -1 for "I could not work this out", and a
    // report that carried them through would claim a heading id of "".
    const parsed = parse(testing.allocator,
        \\{"type":"quote","text":"x","headingId":"","headingText":"",
        \\ "blockSelector":"","blockText":"","offsetInBlock":-1,
        \\ "documentOffset":-1}
    ).?;
    defer parsed.deinit();

    const q = parsed.message.quote;
    try testing.expectEqualStrings("x", q.text);
    try testing.expectEqual(@as(?[]const u8, null), q.heading_id);
    try testing.expectEqual(@as(?[]const u8, null), q.heading_text);
    try testing.expectEqual(@as(?[]const u8, null), q.block_selector);
    try testing.expectEqual(@as(?[]const u8, null), q.block_text);
    try testing.expectEqual(@as(?u32, null), q.offset_in_block);
    try testing.expectEqual(@as(?u32, null), q.document_offset);
}

test "parse: everything this side does not act on is ignored" {
    // The blob runs on arbitrary websites, so a page can post anything at all
    // through the same bridge. None of it may reach a switch that assumes a
    // shape — "ignore it" is the only safe default.
    const cases = [_][]const u8{
        "", // not JSON at all
        "not json",
        "[1,2,3]", // a valid document that is not an object
        "\"a string\"",
        "{}", // no type
        "{\"type\":42}", // a type of the wrong kind
        "{\"type\":\"something-else\"}", // a type we do not handle
        "{\"type\":\"quote\"}", // a quote with no text
        "{\"type\":\"quote\",\"text\":\"   \"}", // ...or only whitespace
        "{\"type\":\"quote\",\"text\":7}",
    };
    for (cases) |case| {
        if (parse(testing.allocator, case)) |p| {
            p.deinit();
            std.debug.print("expected a dropped message for: {s}\n", .{case});
            return error.MessageShouldHaveBeenIgnored;
        }
    }
}

test "parse: the result outlives the JSON it was parsed from" {
    // The payload is a COM-heap string the caller frees as soon as `parse`
    // returns, so `alloc_always` is load-bearing: without it the parser hands
    // back slices into that buffer and every string is a use-after-free the
    // moment a page posts one.
    const source = try testing.allocator.dupe(
        u8,
        "{\"type\":\"active\",\"id\":\"section-two\"}",
    );
    const parsed = parse(testing.allocator, source).?;
    defer parsed.deinit();
    @memset(source, 'X');
    testing.allocator.free(source);
    try testing.expectEqualStrings("section-two", parsed.message.active.?);
}
