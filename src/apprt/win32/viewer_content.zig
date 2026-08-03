//! File-mode viewer logic: which renderer a location gets, where a page's
//! resource requests are allowed to resolve, and the `window.__viewer` calls
//! that put a file's bytes on screen (T90e, T90a design §5/§6).
//!
//! Everything here is pure — path arithmetic and string building, no OS
//! surface, no filesystem, no COM — so it runs in the none-runtime lane on
//! either seat. `ViewerPane.zig` is the half that touches disk: it asks this
//! module for a CANDIDATE and then decides whether that candidate exists.
//! Splitting it that way is what makes the directory-escape guard testable
//! without staging a hostile file tree on the box.
//!
//! ## The three tiers, and why the guard is lexical
//!
//! Mac's `ViewerSchemeHandler.resolve` answers a page request in three steps:
//! the bundled template/assets directory first (`viewer.html`, `vendor/…`),
//! then the viewed file's own directory (relative images), then an absolute
//! path as written. The first two are guarded against `..` escaping their
//! root; the third is deliberately unguarded because it IS an absolute
//! reference the document asked for.
//!
//! Mac guards by resolving symlinks and prefix-checking the real paths. This
//! port normalizes LEXICALLY instead (`std.fs.path.resolve`, which folds `.`
//! and `..` without touching the disk) and prefix-checks that. The deviation
//! is deliberate and it is the reason this module is pure: the attack the
//! guard exists to stop is a document saying `![](../../../../secrets.txt)`,
//! which is lexical, and a check that needs a live filesystem is a check no
//! unit test ever runs.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ipc_args = @import("../ipc/args.zig");

/// The synthetic origin file-mode panes load from. Everything under it is
/// served by the pane's `WebResourceRequested` handler; nothing ever leaves
/// the machine, and the host does not resolve in DNS.
pub const virtual_host = "ghoztty-viewer";

/// The bundled template. A file-mode pane navigates HERE, not to the file —
/// the file's bytes arrive afterwards through `window.__viewer`.
pub const page_url = "https://" ++ virtual_host ++ "/viewer.html";

/// What `AddWebResourceRequestedFilter` is given, so the handler sees every
/// request the template makes (the document, its CSS, its vendor scripts, and
/// any image the rendered markdown references).
pub const resource_filter = "https://" ++ virtual_host ++ "/*";

/// The prefix a request URI carries when it belongs to us.
const origin_prefix = "https://" ++ virtual_host;

/// Which renderer a location gets (Mac's `ViewerView.Mode`, same extension
/// table).
pub const Mode = enum {
    /// Navigate the pane at the URL itself.
    web,
    /// Render through markdown-it in the bundled template.
    markdown,
    /// Render as syntax-highlighted text in the bundled template.
    code,

    /// Whether this mode loads the bundled template rather than the location.
    pub fn isFile(self: Mode) bool {
        return self != .web;
    }
};

/// Classify a `--view=` location. The web/file split is `ipc_args.viewMode`'s,
/// imported rather than repeated: the CLI, the IPC server and this renderer
/// must agree on what counts as a URL, and three copies of that test is three
/// chances to disagree (the T257 lesson).
pub fn modeFor(location: []const u8) Mode {
    if (ipc_args.viewMode(location) == .web) return .web;
    const ext = extension(location);
    for ([_][]const u8{ "md", "markdown", "mdown", "mkd", "mdwn" }) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m)) return .markdown;
    }
    return .code;
}

/// The extension of `path`, WITHOUT the dot and without any query/fragment,
/// or an empty slice. Borrowed from the input.
pub fn extension(path: []const u8) []const u8 {
    const clean = stripQuery(path);
    const base = std.fs.path.basename(clean);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    // A dotfile (".gitignore") has no extension; its name starts with the dot.
    if (dot == 0) return "";
    return base[dot + 1 ..];
}

fn stripQuery(s: []const u8) []const u8 {
    var out = s;
    if (std.mem.indexOfScalar(u8, out, '#')) |i| out = out[0..i];
    if (std.mem.indexOfScalar(u8, out, '?')) |i| out = out[0..i];
    return out;
}

// -------------------------------------------------------------------------
// Locations
// -------------------------------------------------------------------------

/// The filesystem path a FILE-mode location names, written into `buf`.
///
/// Handles the `file://` form because `ipc_args.viewMode` classifies it as a
/// file: `file:///C:/src/README.md` is a path with a URL wrapper, and handing
/// it to a browser would render a markdown document as raw text. Percent
/// escapes are decoded (a path with a space arrives as `%20`), and the extra
/// slash before a drive letter is dropped.
///
/// Returns null when the value does not fit `buf` or is not a file location.
pub fn filePath(buf: []u8, location: []const u8) ?[]const u8 {
    if (location.len == 0) return null;

    var rest = location;
    var was_url = false;
    if (rest.len >= 7 and std.ascii.eqlIgnoreCase(rest[0..7], "file://")) {
        rest = rest[7..];
        was_url = true;
        // `file:///C:/x` and `file://C:/x` both mean the same path here; the
        // triple-slash form is the correct one and the extra slash has to go
        // before a drive letter or the path is rooted at the wrong place.
        if (rest.len >= 3 and rest[0] == '/' and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') {
            rest = rest[1..];
        }
    }
    if (rest.len == 0) return null;
    if (!was_url) {
        if (rest.len > buf.len) return null;
        @memcpy(buf[0..rest.len], rest);
        return buf[0..rest.len];
    }
    return percentDecode(buf, stripQuery(rest));
}

/// The directory a file-mode pane resolves relative resources against: the
/// viewed file's own. Borrowed from `path`.
pub fn baseDirectory(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

/// The host part of a `scheme://` URL — `https://user@example.com:8080/x` is
/// `example.com`. Null when the location has no authority at all
/// (`about:blank`, a bare path), which is the case the caller falls back on.
///
/// This is `Foundation.URL.host` narrowed to what a viewer location can be, and
/// it exists because that is the property Mac titles a website with. An IPv6
/// literal keeps its brackets: the port has to be found AFTER the authority, or
/// the first colon inside `[::1]` reads as one.
pub fn urlHost(location: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, location, "://") orelse return null;
    var rest = location[sep + 3 ..];
    // The authority ends at the first path, query or fragment delimiter.
    for ([_]u8{ '/', '?', '#' }) |c| {
        if (std.mem.indexOfScalar(u8, rest, c)) |i| rest = rest[0..i];
    }
    // `user:password@host` — the LAST '@' wins, since a password may contain one.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
    if (rest.len == 0) return null;
    if (rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return rest;
        return rest[0 .. close + 1];
    }
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| rest = rest[0..i];
    if (rest.len == 0) return null;
    return rest;
}

/// The name a pane carries before — or without — a document title of its own
/// (Mac's `ViewerView.initialTitle`): a file is named by its basename, a
/// website by its host, and anything with neither by the location itself.
///
/// A file's name is ALSO its final title: Mac's title observer ignores
/// `document.title` while the pane is showing a file, because the bundled
/// template's own title is not the document's name. So this is the whole answer
/// in file mode, and only the pre-load answer in web mode.
///
/// Borrowed from the inputs. Non-empty for every location a pane can actually
/// have — a nameless pane is the defect this replaces — with the empty string
/// the one degenerate input, which nothing constructs a pane from.
pub fn initialTitle(mode: Mode, location: []const u8, file_path: ?[]const u8) []const u8 {
    if (!mode.isFile()) return urlHost(location) orelse location;
    // The decoded path when the pane has one (a `file://` location's basename
    // would otherwise still be percent-encoded), else the location as typed.
    const p = file_path orelse location;
    const base = std.fs.path.basename(stripQuery(p));
    return if (base.len == 0) location else base;
}

// -------------------------------------------------------------------------
// Resource requests
// -------------------------------------------------------------------------

/// The relative path a request URI is asking for, decoded into `buf`.
///
/// `https://ghoztty-viewer/vendor/markdown-it.min.js` -> `vendor/markdown-it.min.js`.
/// Returns null for a URI that is not ours, or one whose path is empty (the
/// bare origin names no resource).
pub fn requestPath(buf: []u8, uri: []const u8) ?[]const u8 {
    if (uri.len < origin_prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(uri[0..origin_prefix.len], origin_prefix)) return null;
    var rest = uri[origin_prefix.len..];
    // The origin has to end here or at a path separator — otherwise
    // `https://ghoztty-viewer.example.com/` would look like ours.
    if (rest.len == 0) return null;
    if (rest[0] != '/') return null;
    rest = stripQuery(rest[1..]);
    if (rest.len == 0) return null;
    return percentDecode(buf, rest);
}

/// A candidate path under `root`, or null when `rel` would escape it.
///
/// The guard is the whole point: `rel` comes from a document we did not write,
/// so `../../../secrets.txt` and `C:\Windows\win.ini` are both things a page
/// can ask for. Both are rejected here rather than at the filesystem, where
/// they would succeed.
///
/// Caller owns the result.
pub fn candidateUnder(
    alloc: Allocator,
    root: []const u8,
    rel: []const u8,
) Allocator.Error!?[]u8 {
    if (root.len == 0 or rel.len == 0) return null;
    // An absolute `rel` makes `resolve` discard `root` outright, which is the
    // escape this function exists to refuse. A drive-relative `C:x` is not
    // "absolute" by `isAbsolute` and is refused for the same reason: it is
    // rooted at that drive's own working directory, not at `root`.
    if (std.fs.path.isAbsolute(rel)) return null;
    if (hasDriveLetter(rel)) return null;

    const joined = try std.fs.path.resolve(alloc, &.{ root, rel });
    errdefer alloc.free(joined);
    const root_full = try std.fs.path.resolve(alloc, &.{root});
    defer alloc.free(root_full);

    if (!isUnder(joined, root_full)) {
        alloc.free(joined);
        return null;
    }
    return joined;
}

/// The third tier: an absolute reference the document wrote itself, e.g.
/// `![](/pics/x.png)`. Mac prepends `/`; the Windows-shaped equivalent roots it
/// at the DRIVE the viewed file lives on, because `/pics/x.png` on Windows
/// means "the current drive's root", and the viewed file's drive is the only
/// answer this code has to that.
///
/// A `rel` that is already absolute (`C:/Users/me/pic.png`, which is what
/// `![](/C:/Users/me/pic.png)` decodes to after the leading slash is dropped)
/// is used as written. Caller owns the result.
pub fn rootedCandidate(
    alloc: Allocator,
    base_dir: []const u8,
    rel: []const u8,
) Allocator.Error!?[]u8 {
    if (rel.len == 0) return null;
    if (std.fs.path.isAbsolute(rel)) return try alloc.dupe(u8, rel);
    if (hasDriveLetter(rel)) return null;
    var root_buf: [3]u8 = undefined;
    const root = driveRoot(&root_buf, base_dir) orelse return null;
    return try std.fs.path.resolve(alloc, &.{ root, rel });
}

/// The root `rel` is measured from, written into `buf`: the drive prefix of
/// `base_dir` on Windows, or `/` where paths have no drive.
///
/// The trailing separator is load-bearing rather than cosmetic. `D:` alone is
/// DRIVE-RELATIVE on Windows — it names that drive's own working directory,
/// which `std.fs.path.resolve` goes to the OS to look up — so the root of the
/// drive has to be spelled `D:\`.
fn driveRoot(buf: *[3]u8, base_dir: []const u8) ?[]const u8 {
    if (hasDriveLetter(base_dir)) {
        buf[0] = base_dir[0];
        buf[1] = ':';
        buf[2] = '\\';
        return buf[0..3];
    }
    const unc = base_dir.len >= 2 and
        (base_dir[0] == '\\' or base_dir[0] == '/') and
        (base_dir[1] == '\\' or base_dir[1] == '/');
    if (!unc and base_dir.len > 0 and (base_dir[0] == '/' or base_dir[0] == '\\')) {
        buf[0] = base_dir[0];
        return buf[0..1];
    }
    // A UNC base (`\\server\share\…`) has no drive letter and no meaningful
    // "root of the current drive"; a document's absolute reference cannot be
    // placed, so there is no candidate rather than a wrong one.
    return null;
}

fn hasDriveLetter(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

/// Whether `path` is `root` itself or sits inside it. Comparison is
/// case-insensitive on Windows, where two spellings of the same directory are
/// the same directory and a case-sensitive prefix check would reject a page's
/// own stylesheet.
pub fn isUnder(path: []const u8, root: []const u8) bool {
    if (path.len < root.len) return false;
    if (!eqlPath(path[0..root.len], root)) return false;
    if (path.len == root.len) return true;
    // `root` may or may not already end in a separator (a drive root does).
    if (isSep(root[root.len - 1])) return true;
    return isSep(path[root.len]);
}

fn isSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

fn eqlPath(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

/// Decode `%XX` escapes into `buf`. Returns null when the result would not
/// fit. An invalid escape is passed through as written rather than dropped —
/// a literal `%` in a filename is far likelier than a malformed URL from our
/// own template.
pub fn percentDecode(buf: []u8, s: []const u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (w >= buf.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                buf[w] = s[i];
                w += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                buf[w] = s[i];
                w += 1;
                i += 1;
                continue;
            };
            buf[w] = hi * 16 + lo;
            w += 1;
            i += 3;
            continue;
        }
        buf[w] = s[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

/// The MIME type to answer a served resource with (Mac's
/// `ViewerSchemeHandler.mimeType`, byte-identical table). `ext` carries no dot.
pub fn mimeType(ext: []const u8) []const u8 {
    const table = .{
        .{ "html", "text/html" },       .{ "htm", "text/html" },
        .{ "css", "text/css" },         .{ "js", "text/javascript" },
        .{ "mjs", "text/javascript" },  .{ "json", "application/json" },
        .{ "png", "image/png" },        .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },      .{ "gif", "image/gif" },
        .{ "svg", "image/svg+xml" },    .{ "webp", "image/webp" },
        .{ "ico", "image/x-icon" },     .{ "txt", "text/plain" },
        .{ "md", "text/plain" },        .{ "markdown", "text/plain" },
        .{ "woff", "font/woff" },       .{ "woff2", "font/woff2" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}

/// Map a file extension to a highlight.js language id, or null to render as
/// plain text (Mac's `ViewerView.highlightLanguage`, byte-identical table so
/// the same file colorizes the same way on both platforms). `ext` carries no
/// dot.
pub fn highlightLanguage(ext: []const u8) ?[]const u8 {
    const table = .{
        .{ "js", "javascript" },   .{ "mjs", "javascript" },  .{ "cjs", "javascript" },
        .{ "jsx", "javascript" },  .{ "ts", "typescript" },   .{ "tsx", "typescript" },
        .{ "mts", "typescript" },  .{ "py", "python" },       .{ "rb", "ruby" },
        .{ "rs", "rust" },         .{ "go", "go" },           .{ "c", "c" },
        .{ "h", "c" },             .{ "cpp", "cpp" },         .{ "cc", "cpp" },
        .{ "cxx", "cpp" },         .{ "hpp", "cpp" },         .{ "hh", "cpp" },
        .{ "cs", "csharp" },       .{ "m", "objectivec" },    .{ "mm", "objectivec" },
        .{ "java", "java" },       .{ "kt", "kotlin" },       .{ "kts", "kotlin" },
        .{ "swift", "swift" },     .{ "php", "php" },         .{ "pl", "perl" },
        .{ "pm", "perl" },         .{ "lua", "lua" },         .{ "r", "r" },
        .{ "sql", "sql" },         .{ "sh", "bash" },         .{ "bash", "bash" },
        .{ "zsh", "bash" },        .{ "fish", "bash" },       .{ "json", "json" },
        .{ "yaml", "yaml" },       .{ "yml", "yaml" },        .{ "toml", "ini" },
        .{ "ini", "ini" },         .{ "conf", "ini" },        .{ "xml", "xml" },
        .{ "html", "xml" },        .{ "htm", "xml" },         .{ "svg", "xml" },
        .{ "plist", "xml" },       .{ "css", "css" },         .{ "scss", "scss" },
        .{ "less", "less" },       .{ "diff", "diff" },       .{ "patch", "diff" },
        .{ "makefile", "makefile" }, .{ "mk", "makefile" },   .{ "graphql", "graphql" },
        .{ "gql", "graphql" },     .{ "vb", "vbnet" },        .{ "wat", "wasm" },
        .{ "wasm", "wasm" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return null;
}

// -------------------------------------------------------------------------
// The `window.__viewer` calls
// -------------------------------------------------------------------------

/// `window.__viewer.setMarkdown("…")`. Caller owns the result.
pub fn setMarkdownCall(alloc: Allocator, source: []const u8) Allocator.Error![]u8 {
    return try call(alloc, "setMarkdown", &.{source});
}

/// `window.__viewer.setCode("…", "lang")`. An unknown language is the empty
/// string, which is what the page treats as "plain text" — the same value
/// Mac's `lang ?? ""` passes.
pub fn setCodeCall(alloc: Allocator, source: []const u8, lang: ?[]const u8) Allocator.Error![]u8 {
    return try call(alloc, "setCode", &.{ source, lang orelse "" });
}

/// `window.__viewer.setError("title", "detail")` — the in-page error card for
/// a file that is missing, unreadable, or not text.
pub fn setErrorCall(alloc: Allocator, title: []const u8, detail: []const u8) Allocator.Error![]u8 {
    return try call(alloc, "setError", &.{ title, detail });
}

fn call(alloc: Allocator, name: []const u8, args: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "window.__viewer.");
    try out.appendSlice(alloc, name);
    try out.append(alloc, '(');
    for (args, 0..) |a, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try appendJsString(alloc, &out, a);
    }
    try out.append(alloc, ')');
    return try out.toOwnedSlice(alloc);
}

/// Write `s` as a JS string literal.
///
/// JSON string escaping is very nearly enough — JS string syntax is a superset
/// — with one exception that is not theoretical for a viewer: **U+2028 and
/// U+2029 are line terminators in JavaScript**, so a document containing one
/// would end the literal mid-string and turn a source file into a syntax
/// error. They are escaped explicitly here. Everything below 0x20 is escaped
/// for the same reason (a raw newline is not legal in a JS string).
pub fn appendJsString(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) Allocator.Error!void {
    try out.append(alloc, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => {
                try out.appendSlice(alloc, "\\\"");
                i += 1;
            },
            '\\' => {
                try out.appendSlice(alloc, "\\\\");
                i += 1;
            },
            0x08 => {
                try out.appendSlice(alloc, "\\b");
                i += 1;
            },
            0x0c => {
                try out.appendSlice(alloc, "\\f");
                i += 1;
            },
            '\n' => {
                try out.appendSlice(alloc, "\\n");
                i += 1;
            },
            '\r' => {
                try out.appendSlice(alloc, "\\r");
                i += 1;
            },
            '\t' => {
                try out.appendSlice(alloc, "\\t");
                i += 1;
            },
            // U+2028 / U+2029, in UTF-8: E2 80 A8 / E2 80 A9.
            0xE2 => {
                if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
                    try out.appendSlice(
                        alloc,
                        if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029",
                    );
                    i += 3;
                } else {
                    try out.append(alloc, c);
                    i += 1;
                }
            },
            else => {
                if (c < 0x20) {
                    var hex: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(alloc, &hex);
                } else {
                    try out.append(alloc, c);
                }
                i += 1;
            },
        }
    }
    try out.append(alloc, '"');
}

// -------------------------------------------------------------------------
// Reload (T390, design P8)
// -------------------------------------------------------------------------

/// What `+reload` should DO to a pane, given only what the pane knows about
/// itself. Mac's `reloadContent` switch, lifted out of the COM plumbing so the
/// three-way decision is checkable without a browser: the branch it picks is
/// the whole behavioral contract of the verb, and the rest is one API call
/// each.
pub const ReloadPlan = enum {
    /// Navigate from scratch, the same way the pane's first load did. The
    /// answer whenever there is no completed page to reload — reloading
    /// nothing is what leaves a pane blank forever.
    full_load,
    /// Web mode: re-fetch from ORIGIN, bypassing caches. An explicit reload
    /// exists to pick up server-side changes, so a cache hit is a wrong
    /// answer that looks exactly like a right one.
    refetch,
    /// File mode: re-read the file and re-render it in place (the page
    /// preserves scroll for us — `viewer.js`'s `restoreScroll`).
    rerender,
};

/// `mode` is where the pane currently points; `page_loaded` is whether a
/// navigation has COMPLETED there. Deliberately a function of those two and
/// nothing else — a plan that also depended on the controller's liveness would
/// be untestable, and "no controller" is already "no completed load".
pub fn reloadPlan(mode: Mode, page_loaded: bool) ReloadPlan {
    if (!page_loaded) return .full_load;
    return if (mode.isFile()) .rerender else .refetch;
}

/// The DevTools method that re-fetches bypassing caches, and its parameters.
/// `Reload()` alone is a normal reload: it revalidates, and a 200-with-cache
/// answer renders the bytes the user is trying to get rid of.
pub const devtools_reload_method = "Page.reload";
pub const devtools_reload_params = "{\"ignoreCache\":true}";

// -------------------------------------------------------------------------
// Error-card text
// -------------------------------------------------------------------------

/// Mac's three in-page error titles, byte-identical (`renderFileContent`).
pub const error_not_text = "Not a text file";
pub const error_unreadable = "Cannot read file";
/// Ours, and the reason it exists: a viewer reads the whole file into memory
/// to escape it into a script, so an unbounded read is an unbounded
/// allocation driven by whatever path a caller passed. Mac has no cap and
/// this is a deliberate, visible deviation rather than a silent one.
pub const error_too_large = "File is too large to display";

/// The largest file a viewer will render. Generous by document standards
/// (the largest file in this repo is two orders of magnitude smaller) and
/// small enough that the escaped copy plus its UTF-16 widening stay bounded.
pub const max_file_bytes: usize = 32 * 1024 * 1024;

// -------------------------------------------------------------------------

const testing = std.testing;

test "modeFor: the Mac extension table, and web wins over it" {
    try testing.expectEqual(Mode.web, modeFor("https://example.com/README.md"));
    try testing.expectEqual(Mode.web, modeFor("http://localhost:3000"));
    try testing.expectEqual(Mode.web, modeFor("about:blank"));

    for ([_][]const u8{ "md", "markdown", "mdown", "mkd", "mdwn" }) |ext| {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/docs/x.{s}", .{ext});
        try testing.expectEqual(Mode.markdown, modeFor(path));
    }
    // Case-insensitive: a README.MD is still markdown.
    try testing.expectEqual(Mode.markdown, modeFor("/docs/README.MD"));

    try testing.expectEqual(Mode.code, modeFor("/src/main.zig"));
    try testing.expectEqual(Mode.code, modeFor("/etc/hosts"));
    try testing.expectEqual(Mode.code, modeFor("Makefile"));
    // `file://` is a FILE, not a web page — the whole reason viewMode does not
    // key on "://".
    try testing.expectEqual(Mode.markdown, modeFor("file:///c:/src/README.md"));
}

test "reloadPlan: the branch is the verb's whole contract" {
    // A completed page reloads in the way its mode can: the web re-fetches,
    // a file re-renders. These two are the ordinary cases.
    try testing.expectEqual(ReloadPlan.refetch, reloadPlan(.web, true));
    try testing.expectEqual(ReloadPlan.rerender, reloadPlan(.markdown, true));
    try testing.expectEqual(ReloadPlan.rerender, reloadPlan(.code, true));

    // Nothing has finished loading yet — a pane whose first navigation failed
    // or is still in flight. Re-rendering into a page that has no
    // `window.__viewer` yet, or asking DevTools to reload a document that was
    // never fetched, both end in a pane that stays blank and says nothing; the
    // recovery is to load it again from scratch. This is the case `+reload`
    // exists for on a pane the user is staring at BECAUSE it is empty.
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.web, false));
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.markdown, false));
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.code, false));
}

test "the DevTools reload really asks to bypass the cache" {
    // The parameter is the entire point of using DevTools over `Reload()`, and
    // it is a JSON string that no compiler checks. A typo here is a reload that
    // succeeds, looks right, and serves the stale page — so the literal is
    // asserted, and it is asserted as PARSEABLE JSON with the flag set rather
    // than as a matching byte string, which would only prove it equals itself.
    const parsed = try std.json.parseFromSlice(
        struct { ignoreCache: bool },
        testing.allocator,
        devtools_reload_params,
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.ignoreCache);
    try testing.expectEqualStrings("Page.reload", devtools_reload_method);
}

test "extension: no dot, no query, and a dotfile has none" {
    try testing.expectEqualStrings("md", extension("README.md"));
    try testing.expectEqualStrings("js", extension("vendor/markdown-it.min.js"));
    try testing.expectEqualStrings("png", extension("/pics/a.png?v=2"));
    try testing.expectEqualStrings("css", extension("a.css#frag"));
    try testing.expectEqualStrings("", extension("Makefile"));
    try testing.expectEqualStrings("", extension(".gitignore"));
    try testing.expectEqualStrings("", extension("/a.b/c"));
}

test "filePath: file:// unwrapping and percent decoding" {
    var buf: [256]u8 = undefined;

    // A plain path passes through byte-for-byte.
    try testing.expectEqualStrings(
        "C:\\src\\README.md",
        filePath(&buf, "C:\\src\\README.md").?,
    );

    // The triple-slash form drops exactly one slash before the drive.
    try testing.expectEqualStrings(
        "C:/src/README.md",
        filePath(&buf, "file:///C:/src/README.md").?,
    );
    try testing.expectEqualStrings(
        "C:/src/README.md",
        filePath(&buf, "FILE://C:/src/README.md").?,
    );

    // A space arrives as %20 and has to come back a space, or the file is
    // reported missing under a name the user can see is right.
    try testing.expectEqualStrings(
        "C:/my docs/a b.md",
        filePath(&buf, "file:///C:/my%20docs/a%20b.md").?,
    );

    // A posix file URL keeps its leading slash (there is no drive to unwrap).
    try testing.expectEqualStrings("/src/README.md", filePath(&buf, "file:///src/README.md").?);

    try testing.expect(filePath(&buf, "") == null);
    try testing.expect(filePath(&buf, "file://") == null);
}

test "requestPath: ours, decoded, and nobody else's" {
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings(
        "viewer.html",
        requestPath(&buf, "https://ghoztty-viewer/viewer.html").?,
    );
    try testing.expectEqualStrings(
        "vendor/markdown-it.min.js",
        requestPath(&buf, "https://ghoztty-viewer/vendor/markdown-it.min.js").?,
    );
    try testing.expectEqualStrings(
        "pics/a b.png",
        requestPath(&buf, "https://ghoztty-viewer/pics/a%20b.png?v=2").?,
    );

    // A look-alike host is not ours. Without the separator check this would
    // resolve `.example.com/etc` against our resources directory.
    try testing.expect(requestPath(&buf, "https://ghoztty-viewer.example.com/x") == null);
    try testing.expect(requestPath(&buf, "https://example.com/viewer.html") == null);
    // The bare origin names no resource.
    try testing.expect(requestPath(&buf, "https://ghoztty-viewer/") == null);
    try testing.expect(requestPath(&buf, "https://ghoztty-viewer") == null);
}

test "candidateUnder: resolves inside the root and refuses every way out" {
    const alloc = testing.allocator;
    const root = if (builtin.os.tag == .windows) "C:\\app\\share\\viewer" else "/app/share/viewer";

    {
        const got = (try candidateUnder(alloc, root, "vendor/markdown-it.min.js")).?;
        defer alloc.free(got);
        const want = try std.fs.path.resolve(alloc, &.{ root, "vendor/markdown-it.min.js" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, got);
    }

    // A `..` that stays inside is fine — it is only an escape if it lands
    // outside.
    {
        const got = (try candidateUnder(alloc, root, "vendor/../viewer.css")).?;
        defer alloc.free(got);
        const want = try std.fs.path.resolve(alloc, &.{ root, "viewer.css" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, got);
    }

    // The attack the guard exists for.
    try testing.expect((try candidateUnder(alloc, root, "../../../secrets.txt")) == null);
    try testing.expect((try candidateUnder(alloc, root, "a/../../../secrets.txt")) == null);

    // An absolute `rel` would make `resolve` discard the root entirely.
    try testing.expect((try candidateUnder(alloc, root, "/etc/passwd")) == null);
    if (builtin.os.tag == .windows) {
        try testing.expect((try candidateUnder(alloc, root, "C:\\Windows\\win.ini")) == null);
        try testing.expect((try candidateUnder(alloc, root, "C:win.ini")) == null);
    }

    try testing.expect((try candidateUnder(alloc, root, "")) == null);
    try testing.expect((try candidateUnder(alloc, "", "a.png")) == null);
}

test "candidateUnder: a sibling directory sharing the root's prefix is outside it" {
    const alloc = testing.allocator;
    // `/app/viewer` and `/app/viewer-evil` share a string prefix and are not
    // the same tree. A naive startsWith would let the second one through.
    const root = if (builtin.os.tag == .windows) "C:\\app\\viewer" else "/app/viewer";
    const evil = if (builtin.os.tag == .windows) "C:\\app\\viewer-evil" else "/app/viewer-evil";
    try testing.expect(!isUnder(evil, root));
    try testing.expect((try candidateUnder(alloc, root, "../viewer-evil/x.png")) == null);
}

test "isUnder: the root itself counts, and case does on posix only" {
    const root = if (builtin.os.tag == .windows) "C:\\app\\viewer" else "/app/viewer";
    try testing.expect(isUnder(root, root));
    if (builtin.os.tag == .windows) {
        try testing.expect(isUnder("C:\\APP\\Viewer\\a.css", "C:\\app\\viewer"));
        // A drive root already ends in a separator; the check must not demand
        // a second one.
        try testing.expect(isUnder("C:\\a.png", "C:\\"));
    } else {
        try testing.expect(!isUnder("/APP/Viewer/a.css", "/app/viewer"));
        try testing.expect(isUnder("/a.png", "/"));
    }
}

test "rootedCandidate: the document's own absolute reference" {
    const alloc = testing.allocator;
    const base = if (builtin.os.tag == .windows) "D:\\docs\\project" else "/docs/project";

    {
        const got = (try rootedCandidate(alloc, base, "pics/a.png")).?;
        defer alloc.free(got);
        const root = if (builtin.os.tag == .windows) "D:\\" else "/";
        const want = try std.fs.path.resolve(alloc, &.{ root, "pics/a.png" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, got);
    }

    // Already absolute: used as written, which is what `![](/C:/pics/a.png)`
    // decodes to once the leading slash is stripped by `requestPath`.
    {
        const abs = if (builtin.os.tag == .windows) "C:/pics/a.png" else "/pics/a.png";
        const got = (try rootedCandidate(alloc, base, abs)).?;
        defer alloc.free(got);
        try testing.expectEqualStrings(abs, got);
    }

    try testing.expect((try rootedCandidate(alloc, base, "")) == null);
    if (builtin.os.tag == .windows) {
        // A UNC base has no drive to root against; no candidate beats a wrong
        // one.
        try testing.expect((try rootedCandidate(alloc, "\\\\srv\\share\\docs", "pics/a.png")) == null);
    }
}

test "percentDecode: escapes, a literal percent, and an overflow" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a b", percentDecode(&buf, "a%20b").?);
    try testing.expectEqualStrings("100%", percentDecode(&buf, "100%").?);
    try testing.expectEqualStrings("50%x", percentDecode(&buf, "50%x").?);
    try testing.expectEqualStrings("a/b.png", percentDecode(&buf, "a%2Fb.png").?);
    var tiny: [2]u8 = undefined;
    try testing.expect(percentDecode(&tiny, "abc") == null);
}

test "mimeType and highlightLanguage carry the Mac tables" {
    try testing.expectEqualStrings("text/html", mimeType("html"));
    try testing.expectEqualStrings("text/javascript", mimeType("js"));
    try testing.expectEqualStrings("image/png", mimeType("PNG"));
    try testing.expectEqualStrings("font/woff2", mimeType("woff2"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("zip"));
    try testing.expectEqualStrings("application/octet-stream", mimeType(""));

    try testing.expectEqualStrings("javascript", highlightLanguage("jsx").?);
    try testing.expectEqualStrings("typescript", highlightLanguage("TS").?);
    try testing.expectEqualStrings("cpp", highlightLanguage("hpp").?);
    try testing.expectEqualStrings("bash", highlightLanguage("zsh").?);
    try testing.expectEqualStrings("ini", highlightLanguage("toml").?);
    try testing.expectEqualStrings("xml", highlightLanguage("plist").?);
    try testing.expect(highlightLanguage("zig") == null);
    try testing.expect(highlightLanguage("") == null);
}

test "the __viewer calls are the shape the page exposes" {
    const alloc = testing.allocator;
    {
        const js = try setMarkdownCall(alloc, "# Hi");
        defer alloc.free(js);
        try testing.expectEqualStrings("window.__viewer.setMarkdown(\"# Hi\")", js);
    }
    {
        const js = try setCodeCall(alloc, "let x", "javascript");
        defer alloc.free(js);
        try testing.expectEqualStrings("window.__viewer.setCode(\"let x\", \"javascript\")", js);
    }
    {
        // An unknown extension renders as plain text, which the page spells as
        // an empty language id.
        const js = try setCodeCall(alloc, "x", null);
        defer alloc.free(js);
        try testing.expectEqualStrings("window.__viewer.setCode(\"x\", \"\")", js);
    }
    {
        const js = try setErrorCall(alloc, error_not_text, "C:\\a.bin");
        defer alloc.free(js);
        try testing.expectEqualStrings(
            "window.__viewer.setError(\"Not a text file\", \"C:\\\\a.bin\")",
            js,
        );
    }
}

test "appendJsString escapes what would break the literal" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // A markdown file full of quotes, backslashes and newlines is the normal
    // case, not the edge case.
    try appendJsString(alloc, &out, "a\"b\\c\nd\te\r\x00f");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\r\\u0000f\"", out.items);
}

test "appendJsString escapes the JS line terminators JSON does not" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // U+2028 and U+2029 are legal inside a JSON string and END a JavaScript
    // string literal. A document containing one would turn `setMarkdown(...)`
    // into a syntax error and the pane would render nothing at all.
    try appendJsString(alloc, &out, "a\u{2028}b\u{2029}c");
    try testing.expectEqualStrings("\"a\\u2028b\\u2029c\"", out.items);

    // A different three-byte sequence starting E2 80 is left alone.
    out.clearRetainingCapacity();
    try appendJsString(alloc, &out, "\u{2014}");
    try testing.expectEqualStrings("\"\u{2014}\"", out.items);
}

test "baseDirectory is the viewed file's own" {
    const path = if (builtin.os.tag == .windows) "D:\\docs\\a.md" else "/docs/a.md";
    const want = if (builtin.os.tag == .windows) "D:\\docs" else "/docs";
    try testing.expectEqualStrings(want, baseDirectory(path).?);
    try testing.expect(baseDirectory("a.md") == null);
}

test "urlHost strips scheme, userinfo and port" {
    try testing.expectEqualStrings("example.com", urlHost("https://example.com").?);
    try testing.expectEqualStrings("example.com", urlHost("https://example.com/a/b?q=1#f").?);
    try testing.expectEqualStrings("localhost", urlHost("http://localhost:3000/").?);
    // The port is stripped even with no path after it — the authority ends at
    // end-of-string as readily as at a slash.
    try testing.expectEqualStrings("localhost", urlHost("http://localhost:3000").?);
    // The LAST '@' delimits userinfo: a password may contain one.
    try testing.expectEqualStrings("example.com", urlHost("https://user:p@ss@example.com:8080/x").?);
    // An IPv6 literal keeps its brackets, and its inner colons are not a port.
    try testing.expectEqualStrings("[::1]", urlHost("http://[::1]:8080/x").?);

    // No authority at all: these are the fallback cases, not hosts.
    try testing.expect(urlHost("about:blank") == null);
    try testing.expect(urlHost("D:\\docs\\a.md") == null);
    try testing.expect(urlHost("https:///just-a-path") == null);
}

test "initialTitle: a file is its basename, a website its host" {
    // File modes name the pane after the file, and the DECODED path wins over
    // the location when they differ — a `file://` basename would otherwise
    // still carry its percent escapes.
    try testing.expectEqualStrings("README.md", initialTitle(.markdown, "docs/README.md", "docs/README.md"));
    try testing.expectEqualStrings("main.zig", initialTitle(.code, "src/main.zig", null));
    try testing.expectEqualStrings(
        "my notes.md",
        initialTitle(.markdown, "file:///D:/docs/my%20notes.md", "D:/docs/my notes.md"),
    );
    // A query on a file location is not part of its name.
    try testing.expectEqualStrings("a.md", initialTitle(.markdown, "a.md?v=2", null));

    // Web mode: the host, and the location itself when there is none. The
    // second is what a blank browser pane shows before it is pointed anywhere.
    try testing.expectEqualStrings("example.com", initialTitle(.web, "https://example.com/x", null));
    try testing.expectEqualStrings("about:blank", initialTitle(.web, "about:blank", null));

    // A path that names no file still yields something rather than nothing —
    // going nameless is the defect T383 exists to remove. (An EMPTY location
    // is the one input with no answer, and no pane ever has one.)
    try testing.expect(initialTitle(.markdown, "docs/", "docs/").len > 0);
}
