//! The `ghoztty://` URL scheme — a second, *deliberately tiny* front door onto
//! the same target registry the IPC endpoint drives (T695; the Windows half of
//! main's `GhozttyURLScheme.swift`).
//!
//! It exposes **exactly one capability: focus a window or pane that already
//! exists.** No window creation, no command execution, no input injection, no
//! banners, no viewers. That is not a staging plan; it is the design.
//!
//! The reason is the threat model, and it is the whole reason the scope is
//! drawn here. A registered URL scheme is reachable by **any web page the user
//! visits** — no prompt, no gesture beyond a click, no same-origin check, no
//! way for the app to know who asked. Everything the IPC endpoint can do is
//! safe there because a named pipe with an owner-only DACL (a 0600 unix socket
//! on macOS) is reachable only by code already running as the user. None of
//! that holds for a link. A scheme that could spawn a shell or type into a pane
//! would be remote code execution behind an `<a href>`. Raising an
//! already-existing window is the one verb whose worst case is a nuisance: a
//! hostile page can make a window it cannot see, name, or read jump to the
//! front.
//!
//! So: **do not add a verb here without re-deriving that argument for it.** The
//! parser reads a verb out of the URL rather than hardcoding one shape, so a
//! future verb *can* be added — but wanting a second verb to make something
//! work is a signal to stop and ask, not a signal to add one.
//!
//! ## Canonical form
//!
//! ```
//! ghoztty://focus/<target>
//! ```
//!
//! `<target>` is percent-decoded and handed to the target resolver verbatim, so
//! it accepts everything `--target` accepts — a registered window name, an
//! auto-assigned `window-N`, a registered pane name, or a pane id (the UUID in
//! `$GHOZTTY_PANE_ID`, case-insensitive). There is one resolver and therefore
//! one naming system.
//!
//! The path form is canonical over `ghoztty://<target>` (no room for a verb)
//! and over `ghoztty://focus?target=<name>` (a second escaping context for no
//! gain). Everything after the verb is ONE target, so an unencoded `/` in a
//! name is part of the name rather than a second argument.
//!
//! ## Which build answers
//!
//! A debug build registers **`ghoztty-debug://`** and the release build
//! registers `ghoztty://`, mirroring the split IPC endpoint. Otherwise the
//! shell would pick between them and the user's links would start landing in a
//! debug build.
//!
//! Parsing, by contrast, accepts **both** spellings in **either** build. Links
//! clicked *inside* Ghoztty — a viewer pane, a pane banner — are
//! short-circuited in process and never reach the shell, so a generated
//! document that hardcodes `ghoztty://` still focuses the right pane when a
//! debug build is the one rendering it.
//!
//! ## When it doesn't work
//!
//! A link that resolves to nothing says so (`Failure`): a closed window and a
//! link this build doesn't understand are both ordinary situations the user can
//! act on, and a click that appears to do nothing is indistinguishable from a
//! broken app. What the scheme still refuses to do on failure is ACT: nothing
//! is created and no "closest" window is focused as a consolation.

const std = @import("std");

/// The scheme a RELEASE build registers with the shell.
pub const scheme = "ghoztty";

/// The scheme a DEBUG build registers, so the two never compete.
pub const debug_scheme = "ghoztty-debug";

/// The one supported form, quoted verbatim in the failure text so a user who
/// clicked a link this build cannot answer is told what a working one looks
/// like.
pub const canonical_form = "ghoztty://focus/<window-or-pane>";

/// Everything the scheme can ask for. One case, on purpose — see above.
pub const Command = union(enum) {
    /// Raise the window owning `focus` and focus the pane within it. The slice
    /// points into the caller's decode buffer, not into the URL.
    focus: []const u8,
};

/// Whether `url` addresses Ghoztty at all — asked *before* validity, so a
/// malformed `ghoztty://` link is swallowed rather than leaking out to the
/// browser or into a viewer pane as a bogus location.
pub fn handles(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const s = url[0..colon];
    return std.ascii.eqlIgnoreCase(s, scheme) or
        std.ascii.eqlIgnoreCase(s, debug_scheme);
}

/// Parse `url` into a command, or null if it isn't one. The target is
/// percent-decoded into `buf`, which is why this takes one: the decoded name
/// can differ from every byte range of the input.
///
/// Strict by design: an unknown verb, a missing target, and a bare
/// `ghoztty://<name>` all yield null rather than a lenient guess, because the
/// caller is untrusted.
pub fn parse(url: []const u8, buf: []u8) ?Command {
    if (!handles(url)) return null;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    var rest = url[colon + 1 ..];

    // Hierarchical spellings only. `ghoztty:focus/dev` has no authority to read
    // a verb out of — which is exactly the nil `URLComponents.host` the Mac
    // half rejects — and guessing that the opaque body is "verb/target" is the
    // lenient reading this parser does not do.
    if (!std.mem.startsWith(u8, rest, "//")) return null;
    rest = rest[2..];

    // A query or a fragment ends the path. Neither carries anything: the
    // target lives in the path, and a second escaping context would be a
    // second way to spell the same link.
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const verb = rest[0..slash];
    const raw_path = rest[slash..];

    // Decode first, then trim: a `%2F` inside the target is part of the NAME,
    // so trimming before decoding would eat a character the user typed.
    var target = percentDecode(raw_path, buf) orelse return null;
    if (target.len > 0 and target[0] == '/') target = target[1..];
    while (target.len > 0 and target[target.len - 1] == '/') {
        target = target[0 .. target.len - 1];
    }
    if (target.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(verb, "focus")) return .{ .focus = target };
    return null;
}

/// Percent-decode `s` into `buf`. A truncated or non-hex escape is kept
/// literally rather than dropped — it is data in a name, and inventing a byte
/// for it would silently change the target. Returns null when `buf` is too
/// small (the caller then treats the link as unsupported rather than acting on
/// a truncated name).
fn percentDecode(s: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n >= buf.len) return null;
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                buf[n] = c;
                n += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                buf[n] = c;
                n += 1;
                i += 1;
                continue;
            };
            buf[n] = hi * 16 + lo;
            n += 1;
            i += 3;
            continue;
        }
        buf[n] = c;
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

/// Why a link did nothing. A clicked link that appears to do nothing at all is
/// indistinguishable from a broken app, so each of these is SHOWN to the user
/// rather than only logged — the failures are ordinary (the window was closed;
/// the document is older than this build) and the user is the one who can act
/// on them.
///
/// The wording lives here, apart from any dialog, so it is testable in the
/// `none` lane; a `MessageBoxW` is not.
pub const Failure = union(enum) {
    /// The URL is one of ours but not a command this build understands.
    unsupported_link: []const u8,
    /// A well-formed focus, but nothing open answers to that name.
    target_not_found: []const u8,

    /// The dialog caption. Kept free of the curly quotes the Mac wording uses,
    /// because a window title is what a script matches on here.
    pub fn title(self: Failure, buf: []u8) []const u8 {
        return switch (self) {
            .unsupported_link => "Unsupported Ghoztty link",
            .target_not_found => |t| std.fmt.bufPrint(
                buf,
                "Can't focus \"{s}\"",
                .{t},
            ) catch "Can't focus that window",
        };
    }

    /// The body text.
    pub fn body(self: Failure, buf: []u8) []const u8 {
        return switch (self) {
            .unsupported_link => |url| std.fmt.bufPrint(
                buf,
                "{s} isn't a link this version of Ghoztty understands. " ++
                    "The only supported form is " ++ canonical_form ++ ".",
                .{url},
            ) catch "That isn't a link this version of Ghoztty understands. " ++
                "The only supported form is " ++ canonical_form ++ ".",
            .target_not_found => "No open Ghoztty window or pane has that name. " ++
                "It may have been closed, or it may belong to a different " ++
                "Ghoztty instance.",
        };
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn parseFocus(url: []const u8, buf: []u8) ?[]const u8 {
    const cmd = parse(url, buf) orelse return null;
    return switch (cmd) {
        .focus => |t| t,
    };
}

test "handles: both spellings, in either build, case-insensitively" {
    try testing.expect(handles("ghoztty://focus/dev"));
    try testing.expect(handles("ghoztty-debug://focus/dev"));
    try testing.expect(handles("GHOZTTY://FOCUS/dev"));
    // Malformed ones are still OURS — that is the whole point of asking this
    // before validity, so a bad link is swallowed instead of leaking out to
    // the browser or into a viewer pane as a bogus location.
    try testing.expect(handles("ghoztty://"));
    try testing.expect(handles("ghoztty:focus"));
    // ...and nothing else is.
    try testing.expect(!handles("https://example.com"));
    try testing.expect(!handles("ghoztty-other://focus/dev"));
    try testing.expect(!handles("ghozttyx://focus/dev"));
    try testing.expect(!handles("dev"));
    try testing.expect(!handles(""));
}

test "parse: the canonical form" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("dev", parseFocus("ghoztty://focus/dev", &buf).?);
    try testing.expectEqualStrings("dev", parseFocus("ghoztty-debug://focus/dev", &buf).?);
    // A trailing slash means the same link.
    try testing.expectEqualStrings("dev", parseFocus("ghoztty://focus/dev/", &buf).?);
    // The verb is case-insensitive (the scheme's host is, everywhere).
    try testing.expectEqualStrings("dev", parseFocus("GHOZTTY://Focus/dev", &buf).?);
    // The TARGET is not lowercased: pane ids are matched case-insensitively by
    // the resolver, but a registered name is whatever the user registered.
    try testing.expectEqualStrings("Dev-Two", parseFocus("ghoztty://focus/Dev-Two", &buf).?);
}

test "parse: a pane id is just a target" {
    var buf: [256]u8 = undefined;
    const id = "F08888B0-A73E-4554-86DB-5A11F6BCEFDB";
    try testing.expectEqualStrings(
        id,
        parseFocus("ghoztty://focus/" ++ id, &buf).?,
    );
}

test "parse: everything after the verb is ONE percent-decoded target" {
    var buf: [256]u8 = undefined;
    // An encoded slash is part of the NAME...
    try testing.expectEqualStrings("a/b", parseFocus("ghoztty://focus/a%2Fb", &buf).?);
    // ...and so is a bare one, so both spellings reach the resolver the same.
    try testing.expectEqualStrings("a/b", parseFocus("ghoztty://focus/a/b", &buf).?);
    try testing.expectEqualStrings("my pane", parseFocus("ghoztty://focus/my%20pane", &buf).?);
    // A truncated escape is data in a name, not a decode.
    try testing.expectEqualStrings("a%2", parseFocus("ghoztty://focus/a%2", &buf).?);
    try testing.expectEqualStrings("a%zz", parseFocus("ghoztty://focus/a%zz", &buf).?);
}

test "parse: strict — an unknown verb, an empty target and a bare host yield nothing" {
    var buf: [256]u8 = undefined;
    // A bare `ghoztty://dev` has nowhere to put a verb, so it is not a lenient
    // spelling of focus — it is not a command at all.
    try testing.expect(parse("ghoztty://dev", &buf) == null);
    try testing.expect(parse("ghoztty://focus", &buf) == null);
    try testing.expect(parse("ghoztty://focus/", &buf) == null);
    try testing.expect(parse("ghoztty://focus///", &buf) == null);
    try testing.expect(parse("ghoztty://", &buf) == null);
    try testing.expect(parse("ghoztty://open/dev", &buf) == null);
    try testing.expect(parse("ghoztty://focus?target=dev", &buf) == null);
    // The verbs that would be a security hole if they ever existed.
    try testing.expect(parse("ghoztty://new-window/dev", &buf) == null);
    try testing.expect(parse("ghoztty://send-keys/dev", &buf) == null);
    // Non-hierarchical: no authority, therefore no verb.
    try testing.expect(parse("ghoztty:focus/dev", &buf) == null);
    // Not ours at all.
    try testing.expect(parse("https://example.com/focus/dev", &buf) == null);
}

test "parse: a query or fragment ends the path rather than adding an argument" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("dev", parseFocus("ghoztty://focus/dev?x=1", &buf).?);
    try testing.expectEqualStrings("dev", parseFocus("ghoztty://focus/dev#top", &buf).?);
}

test "parse: a target that does not fit the buffer is not a command" {
    // Truncating would focus a DIFFERENT window than the link named, which is
    // the one outcome worse than doing nothing.
    var small: [4]u8 = undefined;
    try testing.expect(parse("ghoztty://focus/a-much-longer-name", &small) == null);
}

test "failure wording names the target and the one supported form" {
    var buf: [256]u8 = undefined;
    var body_buf: [512]u8 = undefined;

    const nf: Failure = .{ .target_not_found = "dev" };
    try testing.expectEqualStrings("Can't focus \"dev\"", nf.title(&buf));
    try testing.expect(std.mem.indexOf(u8, nf.body(&body_buf), "closed") != null);

    const un: Failure = .{ .unsupported_link = "ghoztty://open/dev" };
    try testing.expectEqualStrings("Unsupported Ghoztty link", un.title(&buf));
    const text = un.body(&body_buf);
    try testing.expect(std.mem.indexOf(u8, text, "ghoztty://open/dev") != null);
    try testing.expect(std.mem.indexOf(u8, text, canonical_form) != null);
}

test "failure wording degrades rather than failing when the buffer is short" {
    var tiny: [8]u8 = undefined;
    const nf: Failure = .{ .target_not_found = "a-long-window-name" };
    // Some sentence, never a crash and never a truncated target passed off as
    // the real one.
    try testing.expect(nf.title(&tiny).len > 0);
    try testing.expect(std.mem.indexOf(u8, nf.title(&tiny), "a-long-window") == null);
}
