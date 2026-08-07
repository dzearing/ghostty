//! Pure model for what a click on a BANNER LINK does, and for the
//! right-click action menu that exposes the same set (T165 — the Windows
//! half of Mac's `BannerLinkOpener`). No OS imports, so it unit-tests in
//! every app-runtime lane; the `HMENU` construction, `ShellExecuteW` and
//! the viewer-split plumbing live in `BannerOverlay.zig`.
//!
//! A banner link is either a **web URL** or a **local file**. A plain click
//! hands the link *out* of Ghoztty — a URL to the system default browser, a
//! file revealed in File Explorer. The modifiers bring it back in: `Ctrl`
//! opens it in a viewer side pane (either kind), and `Ctrl+Shift` gives it a
//! surface of its own — a new Ghoztty viewer window for a URL, the file's own
//! default app for a path. That is Mac's scheme with `Cmd` → `Ctrl`, which is
//! the standing translation rule for this port.
//!
//! A URL leaves by default for the reason CLAUDE.md records: the viewer's
//! WebView2 keeps its own cookie store with no relationship to Edge or
//! Chrome, so anything behind a login renders logged-out in a viewer pane and
//! an OAuth sign-in never completes. A file is only *revealed*, never opened,
//! so a click can never launch whatever app claims the extension.

const std = @import("std");

/// Which of the two link families a target belongs to. Binary on purpose —
/// Mac keys everything off `URL.isFileURL` and a third case would give the
/// menu a shape neither platform has.
pub const Kind = enum { web, file };

/// Classify a link target.
///
/// `file:` is a file, and so is anything that is not a URL at all: a bare
/// Windows path. The banner's markdown parser gates `[text](target)` on
/// `hasScheme`, and `D:\Users\David\out.mp4` **passes that gate** — `D` then
/// `:` reads as a one-letter scheme — so a drive path is already a live link
/// shape here (it is the whole subject of T539). One letter followed by `:`
/// and a separator is a drive, never a scheme: no registered URI scheme is a
/// single character.
pub fn kindOf(target: []const u8) Kind {
    if (target.len == 0) return .web;
    if (std.ascii.startsWithIgnoreCase(target, "file:")) return .file;
    if (isDrivePath(target)) return .file;
    // UNC (`\\server\share`) and rooted/relative paths carry no scheme at
    // all, so the parser will only ever hand them over once T539 autolinks
    // them — classify them now rather than leaving a hole to find later.
    if (target[0] == '\\' or target[0] == '/' or target[0] == '~') return .file;
    if (std.mem.startsWith(u8, target, ".\\") or
        std.mem.startsWith(u8, target, "./") or
        std.mem.startsWith(u8, target, "..\\") or
        std.mem.startsWith(u8, target, "../")) return .file;
    return .web;
}

/// `C:\…` or `C:/…` — a drive letter, a colon, and a separator.
fn isDrivePath(target: []const u8) bool {
    if (target.len < 3) return false;
    if (!std.ascii.isAlphabetic(target[0])) return false;
    if (target[1] != ':') return false;
    return target[2] == '\\' or target[2] == '/';
}

/// What a link activation does. Naming the outcome instead of calling the
/// verb directly gives the modifier scheme, the menu order and the tests one
/// definition to share, so they cannot drift apart.
pub const Action = enum {
    /// Hand it to the shell: the default browser for a URL, the file's own
    /// app for a path.
    open_with_system,
    /// Select the file in File Explorer without opening it.
    reveal_in_explorer,
    /// A viewer split beside the banner's pane.
    open_in_side_pane,
    /// A new one-pane Ghoztty viewer window.
    open_in_new_window,
    /// Put the link on the clipboard.
    copy,
};

/// What a LEFT click on a link of `kind` does with `ctrl`/`shift` held.
/// Plain click leaves Ghoztty; `Ctrl` opens a side pane; `Ctrl+Shift` asks
/// for a surface of the link's own — which for a file is the app that owns
/// it, since a viewer can display a file but never edit one.
pub fn clickAction(kind: Kind, ctrl: bool, shift: bool) Action {
    if (!ctrl) return switch (kind) {
        .web => .open_with_system,
        .file => .reveal_in_explorer,
    };
    if (!shift) return .open_in_side_pane;
    return switch (kind) {
        .web => .open_in_new_window,
        .file => .open_with_system,
    };
}

/// Stable command ids for `TrackPopupMenuEx`'s `TPM_RETURNCMD`. Zero is
/// reserved (it is what "dismissed without choosing" returns).
pub const Id = enum(usize) {
    open_browser = 1,
    reveal = 2,
    side_pane = 3,
    new_window = 4,
    open_default_app = 5,
    copy = 6,
};

/// The action behind a menu row. `open_browser` and `open_default_app` are
/// two rows for one action because they read as different things to the
/// user — and for a file both can be present, one as the click default and
/// one as the Ctrl+Shift verb.
pub fn action(id: Id) Action {
    return switch (id) {
        .open_browser, .open_default_app => .open_with_system,
        .reveal => .reveal_in_explorer,
        .side_pane => .open_in_side_pane,
        .new_window => .open_in_new_window,
        .copy => .copy,
    };
}

pub const Item = union(enum) {
    separator,
    cmd: struct {
        id: Id,
        /// UTF-16 title ready for `AppendMenuW`.
        title: [:0]const u16,
    },
};

fn u16lit(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Longest menu (`.file`) — the caller's buffer never has to be sized by
/// kind.
pub const MAX_ITEMS: usize = 8;

/// The right-click menu for a link of `kind`, written into `buf`.
///
/// Order mirrors Mac's `BannerLinkOpener.menu(for:)`: the **first item is by
/// contract the left-click default**, then the group that keeps the link
/// inside Ghoztty, then the rest. A file leads with Reveal and keeps Open
/// with Default App (its Ctrl+Shift verb) as a separate row; a URL leads with
/// the browser, which is both its plain click and its only system handoff, so
/// it appears once.
///
/// Windows wording, not Mac's: "Reveal in File Explorer" (Finder does not
/// exist here) and the ellipsis-free titles the surface context menu already
/// uses for non-dialog rows.
pub fn build(kind: Kind, buf: *[MAX_ITEMS]Item) []const Item {
    var n: usize = 0;
    switch (kind) {
        .file => {
            buf[n] = .{ .cmd = .{ .id = .reveal, .title = u16lit("Reveal in File Explorer") } };
            n += 1;
        },
        .web => {
            buf[n] = .{ .cmd = .{ .id = .open_browser, .title = u16lit("Open in Default Browser") } };
            n += 1;
        },
    }
    buf[n] = .separator;
    n += 1;
    buf[n] = .{ .cmd = .{ .id = .side_pane, .title = u16lit("Open in Side Pane") } };
    n += 1;
    buf[n] = .{ .cmd = .{ .id = .new_window, .title = u16lit("Open in New Window") } };
    n += 1;
    if (kind == .file) {
        buf[n] = .separator;
        n += 1;
        buf[n] = .{ .cmd = .{ .id = .open_default_app, .title = u16lit("Open with Default App") } };
        n += 1;
    }
    buf[n] = .separator;
    n += 1;
    buf[n] = .{ .cmd = .{
        .id = .copy,
        .title = if (kind == .file) u16lit("Copy Path") else u16lit("Copy Link"),
    } };
    n += 1;
    return buf[0..n];
}

/// What `copy` puts on the clipboard, what Explorer selects, and what a
/// viewer pane is pointed at for a FILE link: a plain Windows path. A
/// `file://` URL is decoded (`%20` → space, `/` → `\`, and the leading slash
/// before a drive letter dropped) because a `file:` string is useless in a
/// shell, in Explorer's address bar, or pasted into another editor — the same
/// reason Mac's `pasteboardString(for:)` hands over `url.path`.
///
/// Written into `buf`; returns the used slice, or null when it does not fit.
/// A target that is already a plain path comes back unchanged.
pub fn filePath(target: []const u8, buf: []u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(target, "file:")) {
        if (target.len > buf.len) return null;
        @memcpy(buf[0..target.len], target);
        return buf[0..target.len];
    }

    var rest = target["file:".len..];
    // `file://host/share/x` keeps the host as a UNC root; `file:///C:/x` and
    // `file:/C:/x` do not. Only the empty authority is dropped.
    var unc = false;
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        if (rest.len > 0 and rest[0] != '/') unc = true;
    }
    // `/C:/x` → `C:/x`. A leading slash is only structural when a drive
    // letter follows it.
    if (!unc and rest.len >= 3 and rest[0] == '/' and
        std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') rest = rest[1..];

    var n: usize = 0;
    if (unc) {
        if (buf.len < 2) return null;
        buf[0] = '\\';
        buf[1] = '\\';
        n = 2;
    }
    var i: usize = 0;
    while (i < rest.len) {
        if (n >= buf.len) return null;
        const c = rest[i];
        if (c == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch {
                buf[n] = c;
                n += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch {
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
        buf[n] = if (c == '/') '\\' else c;
        n += 1;
        i += 1;
    }
    if (n == 0) return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "kindOf: schemes" {
    try testing.expectEqual(Kind.web, kindOf("https://example.com/pr/1"));
    try testing.expectEqual(Kind.web, kindOf("http://localhost:3000"));
    try testing.expectEqual(Kind.web, kindOf("mailto:a@b.io"));
    try testing.expectEqual(Kind.file, kindOf("file:///C:/tmp/a.md"));
    try testing.expectEqual(Kind.file, kindOf("FILE:///C:/tmp/a.md"));
    // Degenerate input is never a file: nothing to reveal.
    try testing.expectEqual(Kind.web, kindOf(""));
}

test "kindOf: a Windows drive path is a file, not a one-letter scheme" {
    // The T539 shape. `hasScheme` in banner_markdown accepts it as a link
    // target, so the menu has to classify it correctly TODAY.
    try testing.expectEqual(Kind.file, kindOf("D:\\Users\\David\\out.mp4"));
    try testing.expectEqual(Kind.file, kindOf("C:/tmp/a.md"));
    // ...but a real scheme of two or more letters is still web.
    try testing.expectEqual(Kind.web, kindOf("ms-settings:display"));
    // A drive letter with no separator is not a path.
    try testing.expectEqual(Kind.web, kindOf("d:notapath"));
}

test "kindOf: UNC and relative paths" {
    try testing.expectEqual(Kind.file, kindOf("\\\\homeassistant\\share\\x"));
    try testing.expectEqual(Kind.file, kindOf("/usr/local/bin"));
    try testing.expectEqual(Kind.file, kindOf("~/notes.md"));
    try testing.expectEqual(Kind.file, kindOf(".\\docs\\design.md"));
    try testing.expectEqual(Kind.file, kindOf("../README.md"));
    // A bare relative path with no sigil is not a link at all (Mac's rule).
    try testing.expectEqual(Kind.web, kindOf("docs/design.md"));
}

test "clickAction: plain click hands the link OUT of ghoztty" {
    try testing.expectEqual(Action.open_with_system, clickAction(.web, false, false));
    try testing.expectEqual(Action.reveal_in_explorer, clickAction(.file, false, false));
    // Shift alone changes nothing — the modifier scheme is Ctrl-led.
    try testing.expectEqual(Action.open_with_system, clickAction(.web, false, true));
    try testing.expectEqual(Action.reveal_in_explorer, clickAction(.file, false, true));
}

test "clickAction: Ctrl brings it back in, Ctrl+Shift gives it its own surface" {
    try testing.expectEqual(Action.open_in_side_pane, clickAction(.web, true, false));
    try testing.expectEqual(Action.open_in_side_pane, clickAction(.file, true, false));
    try testing.expectEqual(Action.open_in_new_window, clickAction(.web, true, true));
    // A viewer can display a file but never edit one, so Ctrl+Shift on a
    // path is the app that owns it, not a second viewer.
    try testing.expectEqual(Action.open_with_system, clickAction(.file, true, true));
}

test "menu: the first row IS the left-click default, for both kinds" {
    // The contract the surface context menu already keeps, and what makes
    // the menu self-teaching: whatever a click would have done is at the top.
    var buf: [MAX_ITEMS]Item = undefined;
    for ([_]Kind{ .web, .file }) |k| {
        const items = build(k, &buf);
        try testing.expectEqual(clickAction(k, false, false), action(items[0].cmd.id));
    }
}

test "menu: web rows and order" {
    var buf: [MAX_ITEMS]Item = undefined;
    const items = build(.web, &buf);
    const expected = [_]?Id{
        .open_browser, null, .side_pane, .new_window, null, .copy,
    };
    try testing.expectEqual(expected.len, items.len);
    for (items, expected) |item, exp| switch (item) {
        .separator => try testing.expect(exp == null),
        .cmd => |c| try testing.expectEqual(exp.?, c.id),
    };
    try testing.expectEqualSlices(u16, u16lit("Copy Link"), items[items.len - 1].cmd.title);
}

test "menu: file rows and order" {
    var buf: [MAX_ITEMS]Item = undefined;
    const items = build(.file, &buf);
    const expected = [_]?Id{
        .reveal, null, .side_pane, .new_window, null, .open_default_app, null, .copy,
    };
    try testing.expectEqual(expected.len, items.len);
    try testing.expect(items.len <= MAX_ITEMS);
    for (items, expected) |item, exp| switch (item) {
        .separator => try testing.expect(exp == null),
        .cmd => |c| try testing.expectEqual(exp.?, c.id),
    };
    try testing.expectEqualSlices(u16, u16lit("Copy Path"), items[items.len - 1].cmd.title);
    // Finder does not exist on Windows; the row names the native shell.
    try testing.expectEqualSlices(u16, u16lit("Reveal in File Explorer"), items[0].cmd.title);
}

test "menu: no kind offers a row for an action its click scheme cannot reach" {
    // Every modifier outcome is in the menu, and nothing else is: the menu
    // is the discoverable form of the same set, which is the whole point of
    // pairing the two halves in one task.
    var buf: [MAX_ITEMS]Item = undefined;
    for ([_]Kind{ .web, .file }) |k| {
        var seen = std.EnumSet(Action).initEmpty();
        for (build(k, &buf)) |item| switch (item) {
            .separator => {},
            .cmd => |c| seen.insert(action(c.id)),
        };
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ true, true } }) |m| {
            try testing.expect(seen.contains(clickAction(k, m[0], m[1])));
        }
        // Copy has no chord at all — it exists only in the menu.
        try testing.expect(seen.contains(.copy));
        // ...and the reveal/browser rows never cross kinds.
        try testing.expectEqual(k == .file, seen.contains(.reveal_in_explorer));
    }
}

test "menu: command ids are unique and nonzero" {
    var buf: [MAX_ITEMS]Item = undefined;
    for ([_]Kind{ .web, .file }) |k| {
        var seen = std.StaticBitSet(64).initEmpty();
        for (build(k, &buf)) |item| switch (item) {
            .separator => {},
            .cmd => |c| {
                const v = @intFromEnum(c.id);
                try testing.expect(v != 0);
                try testing.expect(!seen.isSet(v));
                seen.set(v);
            },
        };
    }
}

test "filePath: a file: URL decodes to a plain Windows path" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "C:\\tmp\\a.md",
        filePath("file:///C:/tmp/a.md", &buf).?,
    );
    // The two-slash and one-slash spellings mean the same local file.
    try testing.expectEqualStrings("C:\\tmp\\a.md", filePath("file:/C:/tmp/a.md", &buf).?);
    // Percent escapes come back as the characters they stand for.
    try testing.expectEqualStrings(
        "C:\\Program Files\\a b.md",
        filePath("file:///C:/Program%20Files/a%20b.md", &buf).?,
    );
}

test "filePath: a UNC file: URL keeps its host" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "\\\\homeassistant\\share\\x.md",
        filePath("file://homeassistant/share/x.md", &buf).?,
    );
}

test "filePath: a plain path passes through unchanged" {
    var buf: [512]u8 = undefined;
    // Including its forward slashes: this is what the user typed, and
    // Explorer and the shell both accept either separator.
    try testing.expectEqualStrings("D:\\a\\b.mp4", filePath("D:\\a\\b.mp4", &buf).?);
    try testing.expectEqualStrings("C:/tmp/a.md", filePath("C:/tmp/a.md", &buf).?);
}

test "filePath: degenerate input never overruns the buffer" {
    var small: [4]u8 = undefined;
    try testing.expect(filePath("file:///C:/a/very/long/path.md", &small) == null);
    try testing.expect(filePath("D:\\also\\too\\long", &small) == null);
    var buf: [512]u8 = undefined;
    try testing.expect(filePath("file://", &buf) == null);
    // A truncated escape at the end is data, not a decode: kept literally.
    try testing.expectEqualStrings("C:\\a%2", filePath("file:///C:/a%2", &buf).?);
}
