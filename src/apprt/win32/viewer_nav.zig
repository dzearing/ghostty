//! Address-bar logic for the viewer nav chrome (T159): what a typed address
//! MEANS — a file path, a web address to complete, a diff spec to pass
//! through — and what the field should DISPLAY for wherever the pane is.
//!
//! Pure on purpose (design P4): every function is string classification and
//! string building, no OS surface, so the whole of it runs in the none-runtime
//! lane on either seat. `ViewerNavBar.zig` owns the EDIT control; this module
//! owns what its text means.
//!
//! The Mac sites being ported are named per function: `ViewerView.isFilePath`,
//! `completeAddress`, `addressText(for:)` and `navigate(to:)`.

const std = @import("std");

const view_arg = @import("../../cli/view_arg.zig");
const content = @import("viewer_content.zig");

/// Longest address the completion buffer accepts. An input that cannot fit
/// completed is handed back as typed — the navigation then fails loudly at the
/// browser rather than truncating to a different address silently.
pub const max_address = 2048;

/// A typed address that names a local file rather than a website. Mac's
/// `isFilePath` accepts `file://`, `/` and `~/`; on Windows that same test
/// must also accept `C:\`, `C:/`, `\\server\share` and `~\`, or typing a real
/// path into the address bar treats it as a hostname (design P4).
///
/// Deliberately NOT `std.fs.path.isAbsolute`: that classifies for the machine
/// the test happens to run on, and this module's tests run on both seats. The
/// address bar belongs to a Windows pane, so the rule is Windows-shaped
/// everywhere. (A bare word like "docs" stays a hostname, as in a browser.)
pub fn isFilePath(input: []const u8) bool {
    if (input.len == 0) return false;
    if (startsWithIgnoreCase(input, "file://")) return true;
    // Rooted or UNC — either separator flavor.
    if (input[0] == '/' or input[0] == '\\') return true;
    // `~`, `~/…`, `~\…`: the caller's home. `~foo` is POSIX's "another user's
    // home", which Windows has no answer for — hostname it stays (the same
    // rule `view_arg.tildeRemainder` applies on the CLI side).
    if (input[0] == '~') {
        if (input.len == 1) return true;
        return input[1] == '/' or input[1] == '\\';
    }
    // Drive-absolute. A bare `C:` is drive-RELATIVE and ambiguous with a
    // scheme, so the separator is required.
    if (input.len >= 3 and std.ascii.isAlphabetic(input[0]) and input[1] == ':' and
        (input[2] == '/' or input[2] == '\\')) return true;
    return false;
}

/// Complete a typed address the way a browser omnibox would (Mac's
/// `completeAddress`, ported case for case):
/// - an explicit scheme passes through untouched ("http://cnn")
/// - a scheme-less address gets https:// ("example.org" -> https://example.org)
/// - a single dotless word also gets .com ("cnn" -> https://cnn.com,
///   "cnn:8080/x" -> https://cnn.com:8080/x — port and path survive)
/// - localhost and 127.0.0.1 get http:// and never .com (dev servers are
///   plain HTTP; https://localhost would just fail)
///
/// Returns the input unchanged when it already carries a scheme or when the
/// completion does not fit `buf`.
pub fn completeAddress(buf: []u8, input: []const u8) []const u8 {
    if (std.mem.indexOf(u8, input, "://") != null) return input;

    // Split into authority (host[:port]) and the trailing path/query.
    const slash = std.mem.indexOfScalar(u8, input, '/');
    var authority = if (slash) |i| input[0..i] else input;
    const rest = if (slash) |i| input[i..] else "";

    var port: []const u8 = "";
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        port = authority[colon..];
        authority = authority[0..colon];
    }

    const is_local = std.ascii.eqlIgnoreCase(authority, "localhost") or
        std.mem.eql(u8, authority, "127.0.0.1");

    var needs_com = false;
    if (!is_local and authority.len > 0 and
        std.mem.indexOfScalar(u8, authority, '.') == null)
    {
        needs_com = true;
        for (authority) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-') {
                needs_com = false;
                break;
            }
        }
    }

    const scheme = if (is_local) "http://" else "https://";
    const suffix = if (needs_com) ".com" else "";
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}{s}", .{
        scheme, authority, suffix, port, rest,
    }) catch input;
}

/// What submitting the address field navigates to (Mac's `navigate(to:)`
/// resolution, minus the tilde expansion — `~` needs a home directory, which
/// is the caller's OS half). Null means "nothing to do": empty or
/// whitespace-only input.
///
/// A diff spec is neither a path nor a hostname — without the pass-through,
/// omnibox completion would turn `git-diff:main...HEAD` into an https:// URL.
/// `about:` pages pass through for the same reason (`about:blank` would
/// otherwise read as host "about" with port "blank").
pub fn resolveInput(buf: []u8, raw: []const u8) ?[]const u8 {
    const input = std.mem.trim(u8, raw, " \t\r\n");
    if (input.len == 0) return null;
    if (view_arg.isDiffView(input)) return input;
    if (startsWithIgnoreCase(input, "about:")) return input;
    if (isFilePath(input)) return input;
    return completeAddress(buf, input);
}

/// What the address field should show for where the pane IS (Mac's
/// `addressText(for:)`): the blank start page shows nothing at all, leaving
/// the field's placeholder visible to type into; a `file://` location shows
/// as the path the user can retype; everything else shows as itself. The
/// bundled template's URL is an implementation detail and never a location
/// the pane stores, but it is mapped to empty defensively for the same
/// reason Mac special-cases its scheme.
pub fn addressText(buf: []u8, location: ?[]const u8) []const u8 {
    const loc = location orelse return "";
    if (std.ascii.eqlIgnoreCase(loc, "about:blank")) return "";
    if (std.mem.eql(u8, loc, content.page_url)) return "";
    if (startsWithIgnoreCase(loc, "file://")) {
        return content.filePath(buf, loc) orelse loc;
    }
    return loc;
}

fn startsWithIgnoreCase(s: []const u8, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

// -----------------------------------------------------------------------------

const testing = std.testing;

test "isFilePath is Windows-shaped (design P4)" {
    // The Mac three.
    try testing.expect(isFilePath("file:///C:/src/README.md"));
    try testing.expect(isFilePath("/usr/local/notes.md"));
    try testing.expect(isFilePath("~/docs/x.md"));
    // The Windows additions the task exists for.
    try testing.expect(isFilePath("C:\\src\\README.md"));
    try testing.expect(isFilePath("C:/src/README.md"));
    try testing.expect(isFilePath("\\\\server\\share\\doc.md"));
    try testing.expect(isFilePath("~\\docs\\x.md"));
    try testing.expect(isFilePath("~"));
    try testing.expect(isFilePath("FILE://x"));

    // Hostnames, schemes, and near-misses stay web-shaped.
    try testing.expect(!isFilePath("docs"));
    try testing.expect(!isFilePath("example.org"));
    try testing.expect(!isFilePath("http://example.org"));
    try testing.expect(!isFilePath("C:")); // drive-relative, ambiguous
    try testing.expect(!isFilePath("C:notes.md"));
    try testing.expect(!isFilePath("~foo/x")); // another user's home
    try testing.expect(!isFilePath(""));
}

test "completeAddress matches the Mac omnibox case for case" {
    var buf: [max_address]u8 = undefined;
    // Explicit scheme passes through untouched.
    try testing.expectEqualStrings("http://cnn", completeAddress(&buf, "http://cnn"));
    try testing.expectEqualStrings(
        "ghoztty://x",
        completeAddress(&buf, "ghoztty://x"),
    );
    // Scheme-less gets https://.
    try testing.expectEqualStrings(
        "https://example.org",
        completeAddress(&buf, "example.org"),
    );
    try testing.expectEqualStrings(
        "https://example.org/a/b?q=1",
        completeAddress(&buf, "example.org/a/b?q=1"),
    );
    // A dotless word gets .com, with port and path surviving.
    try testing.expectEqualStrings("https://cnn.com", completeAddress(&buf, "cnn"));
    try testing.expectEqualStrings(
        "https://cnn.com:8080/x",
        completeAddress(&buf, "cnn:8080/x"),
    );
    // localhost and 127.0.0.1 get http:// and never .com.
    try testing.expectEqualStrings(
        "http://localhost:3000",
        completeAddress(&buf, "localhost:3000"),
    );
    try testing.expectEqualStrings(
        "http://LocalHost",
        completeAddress(&buf, "LocalHost"),
    );
    try testing.expectEqualStrings(
        "http://127.0.0.1:7788/",
        completeAddress(&buf, "127.0.0.1:7788/"),
    );
    // A dotless word with characters outside [a-z0-9-] is left a bare host.
    try testing.expectEqualStrings("https://a_b", completeAddress(&buf, "a_b"));
    // Hyphenated dotless words DO complete.
    try testing.expectEqualStrings(
        "https://my-site.com",
        completeAddress(&buf, "my-site"),
    );
}

test "resolveInput trims, rejects empty, and passes specials through" {
    var buf: [max_address]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), resolveInput(&buf, ""));
    try testing.expectEqual(@as(?[]const u8, null), resolveInput(&buf, "   \t"));
    // Whitespace trimmed before classification.
    try testing.expectEqualStrings(
        "C:\\x\\y.md",
        resolveInput(&buf, "  C:\\x\\y.md  ").?,
    );
    // Diff specs and about: pages must never be "completed".
    try testing.expectEqualStrings(
        "git-diff:main...HEAD",
        resolveInput(&buf, "git-diff:main...HEAD").?,
    );
    try testing.expectEqualStrings("git-status:", resolveInput(&buf, "git-status:").?);
    try testing.expectEqualStrings("about:blank", resolveInput(&buf, "about:blank").?);
    // A hostname completes.
    try testing.expectEqualStrings(
        "https://example.org",
        resolveInput(&buf, "example.org").?,
    );
    // A file path passes through for the caller to open.
    try testing.expectEqualStrings(
        "\\\\srv\\share\\a.md",
        resolveInput(&buf, "\\\\srv\\share\\a.md").?,
    );
}

test "addressText shows a retypable address or nothing" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("", addressText(&buf, null));
    try testing.expectEqualStrings("", addressText(&buf, "about:blank"));
    try testing.expectEqualStrings("", addressText(&buf, "ABOUT:BLANK"));
    try testing.expectEqualStrings("", addressText(&buf, content.page_url));
    // A file location shows as the path the user can retype.
    try testing.expectEqualStrings(
        "C:/src/README.md",
        addressText(&buf, "file:///C:/src/README.md"),
    );
    // Plain paths and web locations show as themselves.
    try testing.expectEqualStrings(
        "C:\\src\\README.md",
        addressText(&buf, "C:\\src\\README.md"),
    );
    try testing.expectEqualStrings(
        "https://example.org/x",
        addressText(&buf, "https://example.org/x"),
    );
}
