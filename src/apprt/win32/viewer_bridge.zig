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

/// The shared right-click-on-a-link decider (T826), verbatim for the same P1
/// reason `selection.js` is. It decides whether a right-click landed on a link
/// Ghoztty has actions for, suppresses the browser's own menu when it did, and
/// posts the href up; the menu itself is native, so the scheme list, the
/// same-document rule and the inside-a-selection rule live in ONE file for both
/// platforms.
///
/// One deliberate divergence from Mac, and it is the wrapper's rather than this
/// file's: Mac injects it into subframes too, and here it rides the main-frame
/// blob. WebView2 delivers a subframe's `postMessage` to
/// `ICoreWebView2Frame`'s own event rather than to `add_WebMessageReceived`, so
/// a subframe copy would suppress the browser's menu and then have nowhere to
/// send the href — a right-click that opens nothing, which is the exact outcome
/// the file's own "only suppress once we know we can replace it" guard exists to
/// prevent. A link inside an iframe therefore keeps WebView2's menu until the
/// frame plumbing lands (T928).
pub const links_js = @embedFile("../../viewer/links.js");

const prologue =
    "(function () {\n" ++
    "  \"use strict\";\n" ++
    "  if (window.top !== window) return;\n";

/// What the user currently has SELECTED in the page, kept current so the
/// feedback report can name it (T636). Ours, not upstream's — `selection.js`
/// only speaks when its Quote button is pressed.
///
/// Mac reads the selection at send time with one `evaluateJavaScript`, and
/// win32 deliberately does not: an async round trip on the send path needs a
/// timeout for a wedged or hostile page, and a page that never answers would
/// strand the composer holding text it had already filed. Tracking it as it
/// changes makes the send SYNCHRONOUS in the one place it matters — reading a
/// value the pane already has — and moves the failure mode from "the send
/// hangs" to "the report has no selection", which the format already allows.
///
/// Three properties keep an every-selection listener cheap on pages we do not
/// own: it is debounced to one post per 200ms of settling, it posts only when
/// the text actually CHANGED (a caret move inside the same selection is
/// silent), and it caps what it sends — a select-all on a large document is
/// not context, and nobody points at a megabyte.
pub const selection_tracker_js =
    \\  var ghozttyLastSelection = null;
    \\  var ghozttySelectionTimer = 0;
    \\  var ghozttyPostSelection = function () {
    \\    ghozttySelectionTimer = 0;
    \\    var s = "";
    \\    try { s = String(window.getSelection()); } catch (e) {}
    \\    s = s.replace(/^\s+|\s+$/g, "");
    \\    if (s.length > 16384) s = s.slice(0, 16384);
    \\    if (s === ghozttyLastSelection) return;
    \\    ghozttyLastSelection = s;
    \\    var mh = window.webkit && window.webkit.messageHandlers;
    \\    var h = mh && mh.
++ handler_name ++
    \\;
    \\    if (h) h.postMessage({ type: "selection", text: s });
    \\  };
    \\  document.addEventListener("selectionchange", function () {
    \\    if (ghozttySelectionTimer) return;
    \\    ghozttySelectionTimer = window.setTimeout(ghozttyPostSelection, 200);
    \\  }, true);
    \\
;

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
pub const injected_js =
    prologue ++ shim_js ++ selection_js ++ selection_tracker_js ++ links_js ++ epilogue;

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
/// referential context that lets an agent find it again (docs/claude/viewers.md's
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

/// What an image pane's page reports (T1183). The page measures and gestures;
/// every zoom it then applies came back down from `viewer_image.Geometry`.
///
/// One message shape rather than four, because three of the four fields are
/// wanted by all of them: a resize carries a viewport, a load carries a natural
/// size too, and a gesture carries where it landed. The page always sends what
/// it currently knows, so a dropped message costs a frame rather than
/// desynchronising the two sides.
pub const Image = struct {
    /// What happened. Unknown events are dropped by `parse` rather than
    /// guessed at: the bridge is open to any page.
    event: Event,
    /// The `<img>`'s intrinsic size in its own units, 0 when unknown.
    natural_w: f64 = 0,
    natural_h: f64 = 0,
    /// The scroll container's client area, in CSS pixels.
    viewport_w: f64 = 0,
    viewport_h: f64 = 0,
    /// `window.devicePixelRatio` — what makes 100% one image pixel per DEVICE
    /// pixel, and what changes when the pane crosses to a display at another
    /// scale.
    dpr: f64 = 1,
    /// True for art with no pixel grid (an SVG with no intrinsic pixel size),
    /// where 100% means the drawing's own size instead.
    vector: bool = false,

    pub const Event = enum {
        /// The picture decoded and its natural size is known: fit it.
        loaded,
        /// The pane, or the display's scale factor, changed size.
        viewport,
        /// A double-click or two-finger double-tap: fit ⇄ 100%.
        toggle,
        /// A ctrl+wheel notch, or a keyboard zoom chord the page saw first.
        zoom_in,
        zoom_out,
        /// Ctrl+0.
        reset,
        /// Nothing here could decode the file; show the error card instead.
        failed,
    };
};

/// The messages the injected blob posts. The first three are the shared JS's,
/// which Mac's `handleTOCMessage` switches on by the same strings; the fourth
/// is `selection_tracker_js`'s, which only win32 has (see its doc comment).
/// Everything else is ignored, here as there.
pub const Message = union(enum) {
    /// The document's headings, in order. Empty is a real value — it is what
    /// `clearHeadingIndex` posts when a document goes away.
    headings: []const Heading,
    /// The heading the reader is in, or null when the page says there is none.
    active: ?[]const u8,
    quote: Quote,
    /// What the user has selected right now, or null when the selection was
    /// cleared. Null is a real value: it is how a click into the page takes
    /// yesterday's selection back out of the next report.
    selection: ?[]const u8,
    /// An image pane reported something the zoom rules have to answer (T1183).
    /// Only the bundled template's `image.js` sends these, and only while the
    /// pane is in image mode — a website posting one finds a pane with no
    /// picture in it, which answers nothing and changes nothing.
    image: Image,
    /// A right-click landed on a link the native menu has actions for, and the
    /// page's own menu has already been suppressed (T826). The href is the
    /// DOM's absolute resolution of the attribute, so a relative link arrives
    /// resolved against the page's base.
    link_menu: []const u8,
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
    if (std.mem.eql(u8, kind, "selection")) {
        const raw = stringField(obj, "text") orelse "";
        return .{ .selection = nonEmpty(std.mem.trim(u8, raw, " \t\r\n")) };
    }
    if (std.mem.eql(u8, kind, "image")) {
        return .{ .image = parseImage(obj) orelse return null };
    }
    if (std.mem.eql(u8, kind, "linkMenu")) {
        // No href is no link: the page suppressed its own menu for nothing, and
        // popping ours over an empty target would offer to open the void. The
        // shared script never sends one, but this bridge is open to any page.
        return .{ .link_menu = nonEmpty(stringField(obj, "href")) orelse return null };
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

fn parseImage(obj: std.json.ObjectMap) ?Image {
    const event = std.meta.stringToEnum(Image.Event, blk: {
        const raw = stringField(obj, "event") orelse return null;
        break :blk raw;
    }) orelse return null;
    return .{
        .event = event,
        .natural_w = numberField(obj, "w"),
        .natural_h = numberField(obj, "h"),
        .viewport_w = numberField(obj, "vw"),
        .viewport_h = numberField(obj, "vh"),
        // A missing or nonsense ratio is 1, not 0: a `dpr` of zero would make
        // 100% infinitely large, and the page's own default is 1 anyway.
        .dpr = blk: {
            const v = numberField(obj, "dpr");
            break :blk if (v > 0) v else 1;
        },
        .vector = switch (obj.get("vector") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        },
    };
}

/// A JSON number field as an `f64`, 0 when absent or of the wrong type. JS
/// hands whole values across as integers, so both cases have to be read.
fn numberField(obj: std.json.ObjectMap, name: []const u8) f64 {
    return switch (obj.get(name) orelse return 0) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
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
        prologue.len + shim_js.len + selection_js.len +
            selection_tracker_js.len + links_js.len + epilogue.len,
        injected_js.len,
    );
    // And the shared file is the one on disk, not a copy under apprt/win32 —
    // a marker only that file has.
    try testing.expect(std.mem.indexOf(u8, selection_js, "window.__ghozttySelection") != null);
}

test "T826: links.js is embedded VERBATIM too, and it is the shared file" {
    // Same claim as the selection toolbar's, for the same reason: the decline
    // rules (which schemes have actions, what a same-document link is, what a
    // right-click inside a selection means) are ONE file for both platforms, so
    // a Mac change to them arrives here without a translation.
    try testing.expect(std.mem.indexOf(u8, injected_js, links_js) != null);
    try testing.expect(std.mem.indexOf(u8, links_js, "window.__ghozttyLinks") != null);
    // The message it posts is the one this module parses, spelled the same way.
    try testing.expect(std.mem.indexOf(u8, links_js, "type: \"linkMenu\"") != null);
    // And it reaches native through the same handler everything else does,
    // which is what makes the shim the whole of the Windows half.
    try testing.expect(std.mem.indexOf(u8, links_js, "messageHandlers." ++ handler_name) != null);
}

test "T826: the link script runs AFTER the shim installed the bridge" {
    // It declines a click outright when the bridge is missing — "only suppress
    // the page's menu once we know we can replace it" — so an order that put it
    // first would leave every right-click with the browser's menu instead of
    // ours, silently and on every page.
    const shim = std.mem.indexOf(u8, injected_js, "window.chrome && window.chrome.webview").?;
    const links = std.mem.indexOf(u8, injected_js, "window.__ghozttyLinks").?;
    try testing.expect(shim < links);
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

test "the selection tracker is ours, is debounced, and is bounded" {
    // It runs AFTER the shim, or its handler lookup finds nothing on the very
    // first selection of a page.
    const shim = std.mem.indexOf(u8, injected_js, "window.chrome && window.chrome.webview").?;
    const tracker = std.mem.indexOf(u8, injected_js, "selectionchange").?;
    try testing.expect(shim < tracker);

    // The three properties that make an every-selection listener acceptable on
    // a page we do not own: it settles before it speaks, it stays quiet when
    // nothing changed, and it never ships an unbounded string.
    try testing.expect(std.mem.indexOf(u8, selection_tracker_js, "setTimeout") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        selection_tracker_js,
        "if (s === ghozttyLastSelection) return;",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, selection_tracker_js, "s.slice(0, 16384)") != null);

    // It posts through the same handler the shared scripts use, so there is
    // exactly one bridge to keep working.
    try testing.expect(std.mem.indexOf(
        u8,
        selection_tracker_js,
        "mh && mh." ++ handler_name,
    ) != null);

    // And it is not a fork: `selection.js` knows nothing about it.
    try testing.expect(std.mem.indexOf(u8, selection_js, "selectionchange") == null);
}

test "parse: selection, including the empty one that clears it" {
    const parsed = parse(testing.allocator,
        \\{"type":"selection","text":"  the sentence they meant  "}
    ).?;
    defer parsed.deinit();
    try testing.expectEqualStrings("the sentence they meant", parsed.message.selection.?);

    // A click into the page clears the selection, and the report must stop
    // claiming the user was pointing at something.
    for ([_][]const u8{
        "{\"type\":\"selection\",\"text\":\"\"}",
        "{\"type\":\"selection\",\"text\":\"  \\n \"}",
        "{\"type\":\"selection\"}",
    }) |case| {
        const cleared = parse(testing.allocator, case).?;
        defer cleared.deinit();
        try testing.expectEqual(@as(?[]const u8, null), cleared.message.selection);
    }
}

test "parse: linkMenu carries the href the right-click landed on" {
    const parsed = parse(testing.allocator,
        \\{"type":"linkMenu","href":"https://ghoztty-viewer/docs/design.md"}
    ).?;
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "https://ghoztty-viewer/docs/design.md",
        parsed.message.link_menu,
    );
}

test "parse: a linkMenu with no href is dropped" {
    // The page has already suppressed its own menu by the time this arrives, so
    // the temptation is to show SOMETHING — but a menu over an empty target
    // offers to open the void. The shared script never sends one; a page posting
    // straight into the bridge can.
    for ([_][]const u8{
        "{\"type\":\"linkMenu\"}",
        "{\"type\":\"linkMenu\",\"href\":\"\"}",
        "{\"type\":\"linkMenu\",\"href\":42}",
    }) |case| {
        if (parse(testing.allocator, case)) |p| {
            p.deinit();
            return error.MessageShouldHaveBeenIgnored;
        }
    }
}

test "parse: an image pane's measurements and gestures" {
    {
        const parsed = parse(testing.allocator,
            \\{"type":"image","event":"loaded","w":4000,"h":3000,
            \\ "vw":800.5,"vh":600,"dpr":2,"vector":false}
        ).?;
        defer parsed.deinit();
        const img = parsed.message.image;
        try testing.expectEqual(Image.Event.loaded, img.event);
        // Whole values arrive as JSON integers and fractions as floats; both
        // have to read back as the same f64 the geometry works in.
        try testing.expectApproxEqAbs(@as(f64, 4000), img.natural_w, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 3000), img.natural_h, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 800.5), img.viewport_w, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 600), img.viewport_h, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 2), img.dpr, 1e-9);
        try testing.expect(!img.vector);
    }
    {
        // A gesture carries only the viewport; the sizes default to zero and
        // the pane answers from what it already knows.
        const parsed = parse(testing.allocator,
            \\{"type":"image","event":"toggle","vw":900,"vh":700,"dpr":1}
        ).?;
        defer parsed.deinit();
        try testing.expectEqual(Image.Event.toggle, parsed.message.image.event);
        try testing.expectApproxEqAbs(@as(f64, 0), parsed.message.image.natural_w, 1e-9);
    }
    {
        // A vector has no pixel grid, and says so.
        const parsed = parse(testing.allocator,
            \\{"type":"image","event":"loaded","w":24,"h":24,"vector":true}
        ).?;
        defer parsed.deinit();
        try testing.expect(parsed.message.image.vector);
        // No `dpr` at all is 1, never 0 — a zero would make 100% infinite.
        try testing.expectApproxEqAbs(@as(f64, 1), parsed.message.image.dpr, 1e-9);
    }
    {
        const parsed = parse(testing.allocator,
            \\{"type":"image","event":"failed"}
        ).?;
        defer parsed.deinit();
        try testing.expectEqual(Image.Event.failed, parsed.message.image.event);
    }
}

test "parse: an image message with no event, or an invented one, is dropped" {
    // Same rule as every other message here: the bridge is open to any page,
    // so an unrecognized event is ignored rather than guessed at.
    for ([_][]const u8{
        "{\"type\":\"image\"}",
        "{\"type\":\"image\",\"event\":\"\"}",
        "{\"type\":\"image\",\"event\":\"explode\"}",
        "{\"type\":\"image\",\"event\":7}",
    }) |case| {
        if (parse(testing.allocator, case)) |p| {
            p.deinit();
            return error.MessageShouldHaveBeenIgnored;
        }
    }
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
