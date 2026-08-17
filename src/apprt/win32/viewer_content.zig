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

/// The `ghoztty://` grammar (T695) — `handles` only, so link routing asks the
/// scheme itself whether a URI is a Ghoztty command rather than re-spelling it.
const url_scheme = @import("../ipc/url_scheme.zig");

const ipc_args = @import("../ipc/args.zig");

/// The CLI's own diff-scheme classification (T463). Imported rather than
/// repeated for the same reason `ipc_args.viewMode` is: the CLI decides on this
/// test whether to path-resolve a `--view=` value, and a renderer that
/// disagreed about which values are diffs would render a resolved path as a
/// revspec or a revspec as a file.
const view_arg = @import("../../cli/view_arg.zig");

/// The diff spec, for the two things a location alone has to answer here: which
/// mode it is, and what to call the pane. The import is mutual — `viewer_diff`
/// builds its page calls with `appendJsString` from this file — which Zig
/// resolves per-declaration, and neither direction is reached at comptime.
const viewer_diff = @import("viewer_diff.zig");

/// The synthetic origin file-mode panes load from. Everything under it is
/// served by the pane's `WebResourceRequested` handler; nothing ever leaves
/// the machine, and the host does not resolve in DNS.
pub const virtual_host = "ghoztty-viewer";

/// The bundled template. A file-mode pane navigates HERE, not to the file —
/// the file's bytes arrive afterwards through `window.__viewer`.
pub const page_url = "https://" ++ virtual_host ++ "/viewer.html";

/// The synthetic origin a directly-rendered `.html` FILE loads from (T601).
///
/// A second host rather than a path under the first, because the two grants are
/// different: everything under `ghoztty-viewer` is the bundled template we
/// wrote, and everything under this one is the user's page and its own assets,
/// resolved against the viewed file's directory and nothing else. Keeping them
/// apart is what stops a page asking for `vendor/markdown-it.min.js` and being
/// handed ours, and what makes the grant a single lexical prefix check.
///
/// Deliberately NOT `file://`. Mac loads the file with
/// `loadFileURL(allowingReadAccessTo:)`, whose whole point is that the grant is
/// the file's own directory, recursively — narrow by default. WebView2 has no
/// per-navigation grant to pass: a `file://` document's subresource loads reach
/// the entire filesystem, which is a wider grant than the feature asks for and
/// one that cannot be taken back per-pane.
pub const page_virtual_host = "ghoztty-page";

/// What `AddWebResourceRequestedFilter` is given for the page host.
pub const page_resource_filter = "https://" ++ page_virtual_host ++ "/*";

/// The prefix a request URI carries when it belongs to a rendered `.html` page.
const page_origin_prefix = "https://" ++ page_virtual_host;

/// The blank browser page — what `--view=about:blank` and the palette's
/// "Viewer: Open Browser Pane" open, and the location an adopted popup carries
/// when its opener named no URL at all (Mac's `ViewerView.blankPage`, T163).
pub const blank_page = "about:blank";

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
    /// A local `.html` file, loaded into the web view AS A PAGE (T601): its own
    /// CSS, scripts, images and fonts run exactly as they would if it were
    /// hosted. Mac's fourth `Mode` case, same extensions.
    html,
    /// A git diff, rendered through the same bundled template (T463; Mac's
    /// `.diff(ViewerDiffSpec)`). The location is a `git-status:` /
    /// `git-diff:<revspec>` scheme rather than a path, and the content arrives
    /// through `window.__viewer.setDiffListing` / `setDiffFile` once git has
    /// answered — see `viewer_diff.zig`.
    diff,

    /// Whether this mode has a FILE on disk behind it. True for a rendered
    /// HTML page as much as for a markdown document — the pane is titled by
    /// its basename, watches it for saves, and reports itself as a file to
    /// `+list`.
    ///
    /// False for a diff: what is behind that is a REPOSITORY, not a file.
    /// There is nothing to path-resolve, nothing to watch for saves (a status
    /// pane polls git instead), and no basename to title the pane with.
    pub fn isFile(self: Mode) bool {
        return self != .web and self != .diff;
    }

    /// Whether this mode loads the BUNDLED TEMPLATE and injects the file's
    /// bytes into it, rather than loading a page directly.
    ///
    /// Split from `isFile` by T601: `.html` is a file the web view loads
    /// itself, so everything the template implies — the injection call, the
    /// heading bridge behind the table of contents, the "re-render in place"
    /// reload, the relative-link routing that only exists because the template
    /// cannot navigate — is false for it, while everything the FILE implies is
    /// still true.
    ///
    /// A diff is the mirror image (T463): no file, but the template all the
    /// same — it is a third thing that one page can render, which is why the
    /// pane navigates to the template and pushes content into it afterwards.
    pub fn usesTemplate(self: Mode) bool {
        return self == .markdown or self == .code or self == .diff;
    }

    /// Whether the pane navigates like a browser here (Mac's `isLivePage`):
    /// links follow in place, Back and Forward walk real history, and the
    /// document, not us, decides what loads next.
    pub fn isLivePage(self: Mode) bool {
        return self == .web or self == .html;
    }
};

/// Classify a `--view=` location. The web/file split is `ipc_args.viewMode`'s,
/// imported rather than repeated: the CLI, the IPC server and this renderer
/// must agree on what counts as a URL, and three copies of that test is three
/// chances to disagree (the T257 lesson).
pub fn modeFor(location: []const u8) Mode {
    // The diff schemes come FIRST (T463), exactly as they do in Mac's
    // `ViewerView.classify`: `git-diff:main...HEAD` has neither a `://` nor a
    // useful extension, so every test below it would read it as a code file and
    // try to open a file by that name.
    if (view_arg.isDiffView(std.mem.trim(u8, location, " \t\r\n"))) return .diff;
    if (ipc_args.viewMode(location) == .web) return .web;
    const ext = extension(location);
    for ([_][]const u8{ "md", "markdown", "mdown", "mkd", "mdwn" }) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m)) return .markdown;
    }
    // A local page, not a document about one: `.html`/`.htm` render (T601).
    // Rendering is unconditional — there is no source-view toggle to carry
    // through history and session restore, exactly as on Mac.
    for ([_][]const u8{ "html", "htm" }) |h| {
        if (std.ascii.eqlIgnoreCase(ext, h)) return .html;
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

/// The working directory a TERMINAL split created FROM a viewer pane starts
/// in (T395; Mac `splitConfigFromViewer`,
/// `BaseTerminalController.swift:3048-3054`): the viewed FILE's own directory.
///
/// A viewer runs no shell, so a split off one has no parent cwd to inherit —
/// without this it lands in whatever the agent or the app process happens to
/// call home, which is never where the user is looking. The file's directory
/// is the only cwd a viewer actually knows.
///
/// Null means "no override", and every non-file case says that: a website has
/// no directory to speak of (Mac's `fileURL` is nil there), and neither does a
/// pane whose location did not resolve to a usable path. Borrowed from
/// `file_path`.
pub fn splitWorkingDirectory(file_path: ?[]const u8) ?[]const u8 {
    const path = file_path orelse return null;
    const dir = baseDirectory(path) orelse return null;
    // A dirname can come back empty for a bare relative name ("README.md").
    // Handing "" to the surface config would be a cwd of nowhere, so it is the
    // same answer as having none.
    return if (dir.len == 0) null else dir;
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
    // A diff is named by WHAT IT SHOWS, not by its scheme (T463; Mac's
    // `mode.title`): "Working tree" and "main...HEAD" are what a tab can be
    // read at a glance, where `git-status:` is the address that produced it.
    if (mode == .diff) {
        const spec = viewer_diff.parse(location) orelse return location;
        return spec.title();
    }
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
    return underOrigin(buf, origin_prefix, uri);
}

/// The relative path a PAGE-host request is asking for, decoded into `buf`
/// (T601). `https://ghoztty-page/sub/app.css` -> `sub/app.css`.
///
/// A separate function from `requestPath` rather than a parameterized one: the
/// two origins get different resolution — this one is the viewed page's own
/// directory and nothing else, with no bundled-assets tier in front of it — and
/// a shared parser whose caller has to remember which root to use is exactly
/// how the page would end up served OUR `viewer.css`.
pub fn pageRequestPath(buf: []u8, uri: []const u8) ?[]const u8 {
    return underOrigin(buf, page_origin_prefix, uri);
}

fn underOrigin(buf: []u8, prefix: []const u8, uri: []const u8) ?[]const u8 {
    if (uri.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix)) return null;
    var rest = uri[prefix.len..];
    // The origin has to end here or at a path separator — otherwise
    // `https://ghoztty-page.example.com/` would look like ours.
    if (rest.len == 0) return null;
    if (rest[0] != '/') return null;
    rest = stripQuery(rest[1..]);
    if (rest.len == 0) return null;
    return percentDecode(buf, rest);
}

/// Whether `uri` names something on the page host at all — the test
/// `syncCommitted` runs BEFORE its generic "https means the web" one, so a
/// rendered page committing its own URL is not mistaken for a website (T601).
pub fn isPageOrigin(uri: []const u8) bool {
    if (uri.len < page_origin_prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(uri[0..page_origin_prefix.len], page_origin_prefix)) return false;
    return uri.len == page_origin_prefix.len or uri[page_origin_prefix.len] == '/';
}

/// The page-host URL that serves `path`, whose grant root is `root` (T601).
///
/// Null when `path` does not sit under `root` — a page cannot be served from a
/// grant that does not contain it, and answering with a URL that the request
/// handler would then refuse is a worse failure than not navigating.
///
/// Separators are normalized to `/` and every byte outside the unreserved set
/// is percent-encoded, so a path with a space, a `#`, or a non-ASCII name
/// survives the round trip through `pageRequestPath`. Caller owns the result.
pub fn pageUrlFor(
    alloc: Allocator,
    root: []const u8,
    path: []const u8,
) Allocator.Error!?[:0]u8 {
    if (root.len == 0 or path.len == 0) return null;
    if (!isUnder(path, root)) return null;
    var rel = path[root.len..];
    while (rel.len > 0 and isSep(rel[0])) rel = rel[1..];
    if (rel.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, page_origin_prefix);
    try out.append(alloc, '/');
    for (rel) |c| {
        if (isSep(c) or c == '/') {
            try out.append(alloc, '/');
        } else if (isUnreserved(c)) {
            try out.append(alloc, c);
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(alloc, &hex);
        }
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
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

/// Whether two paths name the same file, by the platform's own case rules.
/// Purely textual, like everything else here — two spellings of one path (a
/// short name, a symlink) are not equal, and the callers only ever compare
/// paths this module produced.
pub fn samePath(a: []const u8, b: []const u8) bool {
    return a.len == b.len and eqlPath(a, b);
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
        .{ "html", "text/html" },      .{ "htm", "text/html" },
        .{ "css", "text/css" },        .{ "js", "text/javascript" },
        .{ "mjs", "text/javascript" }, .{ "json", "application/json" },
        .{ "png", "image/png" },       .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },     .{ "gif", "image/gif" },
        .{ "svg", "image/svg+xml" },   .{ "webp", "image/webp" },
        .{ "ico", "image/x-icon" },    .{ "txt", "text/plain" },
        .{ "md", "text/plain" },       .{ "markdown", "text/plain" },
        .{ "woff", "font/woff" },      .{ "woff2", "font/woff2" },
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
        .{ "js", "javascript" },     .{ "mjs", "javascript" }, .{ "cjs", "javascript" },
        .{ "jsx", "javascript" },    .{ "ts", "typescript" },  .{ "tsx", "typescript" },
        .{ "mts", "typescript" },    .{ "py", "python" },      .{ "rb", "ruby" },
        .{ "rs", "rust" },           .{ "go", "go" },          .{ "c", "c" },
        .{ "h", "c" },               .{ "cpp", "cpp" },        .{ "cc", "cpp" },
        .{ "cxx", "cpp" },           .{ "hpp", "cpp" },        .{ "hh", "cpp" },
        .{ "cs", "csharp" },         .{ "m", "objectivec" },   .{ "mm", "objectivec" },
        .{ "java", "java" },         .{ "kt", "kotlin" },      .{ "kts", "kotlin" },
        .{ "swift", "swift" },       .{ "php", "php" },        .{ "pl", "perl" },
        .{ "pm", "perl" },           .{ "lua", "lua" },        .{ "r", "r" },
        .{ "sql", "sql" },           .{ "sh", "bash" },        .{ "bash", "bash" },
        .{ "zsh", "bash" },          .{ "fish", "bash" },      .{ "json", "json" },
        .{ "yaml", "yaml" },         .{ "yml", "yaml" },       .{ "toml", "ini" },
        .{ "ini", "ini" },           .{ "conf", "ini" },       .{ "xml", "xml" },
        .{ "html", "xml" },          .{ "htm", "xml" },        .{ "svg", "xml" },
        .{ "plist", "xml" },         .{ "css", "css" },        .{ "scss", "scss" },
        .{ "less", "less" },         .{ "diff", "diff" },      .{ "patch", "diff" },
        .{ "makefile", "makefile" }, .{ "mk", "makefile" },    .{ "graphql", "graphql" },
        .{ "gql", "graphql" },       .{ "vb", "vbnet" },       .{ "wat", "wasm" },
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
    /// Template mode: re-read the file and re-render it in place (the page
    /// preserves scroll for us — `viewer.js`'s `restoreScroll`).
    rerender,
    /// A rendered `.html` file that CHANGED ON DISK: reload the page normally
    /// (T601). Mac's `reload()` rather than `reloadFromOrigin()` — the reload
    /// replaces its history entry instead of filling the Back stack, and the
    /// engine restores the scroll offset across it, so a save does not throw
    /// you back to the top of a long page. Page-host responses carry
    /// `Cache-Control: no-store`, so a normal reload still re-reads disk.
    reload_in_place,
};

/// Why a reload is happening. The two differ for exactly one mode — a rendered
/// `.html` file, where a SAVE must keep the reader where they were and an
/// explicit reload must get past every cache in the way (T601).
pub const ReloadReason = enum {
    /// `+reload`, or the chrome's reload button / Ctrl+R.
    chrome,
    /// The file watcher saw the viewed file change.
    file_changed,
};

/// `mode` is where the pane currently points; `page_loaded` is whether a
/// navigation has COMPLETED there. Deliberately a function of those three and
/// nothing else — a plan that also depended on the controller's liveness would
/// be untestable, and "no controller" is already "no completed load".
pub fn reloadPlan(mode: Mode, page_loaded: bool, reason: ReloadReason) ReloadPlan {
    if (!page_loaded) return .full_load;
    if (mode.usesTemplate()) return .rerender;
    if (mode == .html and reason == .file_changed) return .reload_in_place;
    return .refetch;
}

/// The DevTools method that re-fetches bypassing caches, and its parameters.
/// `Reload()` alone is a normal reload: it revalidates, and a 200-with-cache
/// answer renders the bytes the user is trying to get rid of.
pub const devtools_reload_method = "Page.reload";
pub const devtools_reload_params = "{\"ignoreCache\":true}";

// -------------------------------------------------------------------------
// Link routing (T392, design row 5)
// -------------------------------------------------------------------------

/// What a top-level navigation in a viewer pane should do — Mac's
/// `decidePolicyFor` + `handleFileModeLink`, folded into one classification so
/// the whole policy is checkable without a browser. The COM handler's only
/// jobs are to gate on the navigation KIND (`routesAsLink`), cancel, and
/// dispatch.
pub const LinkClass = enum {
    /// Let the navigation proceed in the pane. Every web-mode navigation
    /// (websites navigate freely), and the bundled template itself.
    allow,
    /// Cancel it and hand the URL to the default browser (Mac:
    /// `NSWorkspace.shared.open`).
    browser,
    /// Cancel it: the target is a path under the virtual host — a RELATIVE
    /// link in the rendered document, resolved against the viewed file
    /// (`requestPath` extracts it, `navCandidate`/`rootedCandidate` place it).
    relative,
    /// Cancel it: the target is an explicit `file://` URL, used as written.
    file_url,
    /// Cancel it and do nothing. Mac maps everything else (`mailto:`,
    /// `about:`, unknown schemes) to a nil file URL and returns.
    drop,
    /// Cancel it and run it as a `ghoztty://` command in process (T695).
    ghoztty_command,
};

/// Classify a navigation target for `mode`. `page` is the document the
/// navigation is leaving — the web view's committed `Source`, which live-page
/// mode needs to tell a hop inside the page's own site from one out of it; it
/// is unread in every other mode, and null when the pane has committed nothing
/// yet.
///
/// The virtual-host check runs BEFORE the generic http(s) one — unlike Mac,
/// whose relative links arrive on a custom scheme, ours live under an
/// `https://` origin, so the generic test would ship every relative link to the
/// default browser as a URL that resolves nowhere.
pub fn classifyLink(mode: Mode, page: ?[]const u8, uri: []const u8) LinkClass {
    // A `ghoztty://` link is Ghoztty addressing itself, and it is classified
    // FIRST — ahead of the web-mode passthrough below — for two reasons.
    // WebView2 cannot load the scheme at all, so an allowed navigation is a
    // dead click; and letting it out to the shell would route it to whichever
    // BUILD registered the scheme, so a link clicked in a debug build's pane
    // would raise a window in the release app. Handled here it always means
    // "this app" (T695).
    if (url_scheme.handles(uri)) return .ghoztty_command;
    // A website — and a local `.html` file, which IS a page (T601) — navigates
    // freely in the pane. That is Mac's `isLivePage` branch of `decidePolicyFor`,
    // and for the html half it is what the `python3 -m http.server` workaround
    // this replaces already did: links, Back and Forward all follow in place.
    //
    // The ONE exception (T825, Mac 18acc4f6f) is a link that leads OUT of the
    // page's own site: this web view keeps a cookie store nothing else shares,
    // so a hop to another site renders logged-out here and the browser is where
    // that session lives. The caller decides whether the navigation is a
    // user's click at all (`routesAsLivePageLink`) — everything a page does to
    // itself is still the page's business.
    if (mode.isLivePage()) {
        const from = page orelse return .allow;
        return if (isExternalLivePageLink(from, uri)) .browser else .allow;
    }
    // The template itself (with or without a query/fragment): the pane's own
    // document, never a link target to route.
    if (std.ascii.eqlIgnoreCase(stripQuery(uri), page_url)) return .allow;
    if (uri.len >= origin_prefix.len and
        std.ascii.eqlIgnoreCase(uri[0..origin_prefix.len], origin_prefix) and
        (uri.len == origin_prefix.len or uri[origin_prefix.len] == '/'))
    {
        return .relative;
    }
    for ([_][]const u8{ "http://", "https://" }) |p| {
        if (uri.len >= p.len and std.ascii.eqlIgnoreCase(uri[0..p.len], p)) return .browser;
    }
    if (uri.len >= 7 and std.ascii.eqlIgnoreCase(uri[0..7], "file://")) return .file_url;
    return .drop;
}

/// Whether a link clicked in a LIVE-PAGE viewer (a website, or a local `.html`
/// file, both of which own their own navigation) leads OUT of the page's own
/// site, and so belongs somewhere other than this pane. Mac's
/// `ViewerView.isExternalLivePageLink`, same rules.
///
/// "Site" here is deliberately NOT the web platform's origin. That one decides
/// what a script may read; this one decides where a PERSON wants a page to
/// open, and the two want different rules:
///
/// - **http(s) → http(s):** the same **host**, and the same **port as
///   written**. The scheme is excluded on purpose, so an `http` → `https`
///   upgrade on the same host — the most common same-site hop there is — keeps
///   navigating in the pane. The port is included on purpose:
///   `localhost:3000` → `localhost:5173` is a hop between two different dev
///   servers. A subdomain is a different host and therefore external, which is
///   what "a link out to another site" means to a person.
/// - **Every other link scheme** (`javascript:`, `data:`, `blob:`, `about:`,
///   `mailto:`, some app's custom scheme) is left exactly as it was and
///   followed in the pane. `javascript:` links are ordinary page machinery, and
///   handing an arbitrary scheme to `ShellExecuteW` would resolve it to
///   whatever handler happens to be registered.
/// - **A `file://` link from a web page** is the exception to that: the engine
///   refuses the navigation outright, so following it in the pane is a dead
///   click. It leaves, and the shell opens it in whatever owns that file type —
///   which is what `NSWorkspace.open` does with the same link on Mac.
///
/// Where Mac needs a second family of rules and we do not: a Mac `.html` pane
/// loads the file itself, so its same-site test is `loadFileURL`'s read grant —
/// the page's own directory, recursively. Ours serves that file from the
/// synthetic `ghoztty-page` host (see `page_virtual_host`), so the SAME grant
/// is already a host, a link reaching up out of the folder cannot even be
/// spelled (the URL normalizes back under the host), and the containment test
/// collapses into the host comparison above. Every live page here commits an
/// `https://` URL, which is why there is no `file://`-page branch at all.
pub fn isExternalLivePageLink(page: []const u8, link: []const u8) bool {
    // Not an http(s) document at all — `about:blank`, or a pane that has
    // committed nothing yet. There is no site to be outside of.
    const page_site = siteOf(page) orelse return false;
    const link_site = siteOf(link) orelse return isFileUrl(link);
    return !page_site.eql(link_site);
}

/// A live page's site: its host, plus the port as written when that port is not
/// the scheme's own default (so `http://x.com:80` and `https://x.com` are the
/// same site, and `http://x.com:443` is not).
const Site = struct {
    /// Never empty. Compared case-insensitively, like every host.
    host: []const u8,
    /// Null means "the scheme's default", however it was spelled.
    port: ?u16,

    fn eql(a: Site, b: Site) bool {
        return std.meta.eql(a.port, b.port) and
            std.ascii.eqlIgnoreCase(a.host, b.host);
    }
};

fn siteOf(uri: []const u8) ?Site {
    const sep = std.mem.indexOf(u8, uri, "://") orelse return null;
    const default_port: u16 = blk: {
        const scheme = uri[0..sep];
        if (std.ascii.eqlIgnoreCase(scheme, "http")) break :blk 80;
        if (std.ascii.eqlIgnoreCase(scheme, "https")) break :blk 443;
        return null;
    };

    var authority = uri[sep + 3 ..];
    if (std.mem.indexOfAny(u8, authority, "/?#")) |end| authority = authority[0..end];
    // `user:pass@host` — credentials are not part of the site, and the LAST
    // `@` starts the host (a password may legally contain one).
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0) return null;

    // An IPv6 literal is bracketed, and the colons inside it are not port
    // separators — the port, if any, follows the `]`.
    const port_scan_from: usize = if (authority[0] == '[')
        (std.mem.indexOfScalar(u8, authority, ']') orelse return null) + 1
    else
        0;

    var host = authority;
    var port: ?u16 = null;
    if (std.mem.indexOfScalarPos(u8, authority, port_scan_from, ':')) |colon| {
        host = authority[0..colon];
        const digits = authority[colon + 1 ..];
        // `http://x.com:/` is a host with no port, exactly as a browser reads
        // it. A port that is not a number is a URL we cannot classify, and an
        // unclassifiable link stays in the pane rather than being ejected.
        if (digits.len > 0) port = std.fmt.parseInt(u16, digits, 10) catch return null;
    }
    if (host.len == 0) return null;
    if (port) |p| {
        if (p == default_port) port = null;
    }
    return .{ .host = host, .port = port };
}

fn isFileUrl(uri: []const u8) bool {
    return uri.len >= 7 and std.ascii.eqlIgnoreCase(uri[0..7], "file://");
}

/// The navigation kinds WebView2 distinguishes
/// (`COREWEBVIEW2_NAVIGATION_KIND`), as this module's own enum so the policy
/// stays free of COM.
pub const NavKind = enum { reload, back_or_forward, new_document };

/// Whether a navigation is the kind link routing applies to. Null means the
/// runtime is too old to say (`ICoreWebView2NavigationStartingEventArgs3` is
/// where the kind lives), and is treated as routable — the two excluded kinds
/// are exactly the ones a file-mode pane issues about itself.
///
/// This is Mac's `navigationType == .linkActivated` guard, translated by
/// EFFECT rather than by field: WebKit reports a synthesized `a.click()` as
/// `.linkActivated`, so WebView2's `IsUserInitiated` (which reports it false)
/// is not the equivalent — and in file mode the only NEW_DOCUMENT navigations
/// the pane does not issue itself ARE link activations, because the bundled
/// template runs no navigating script of its own. Reloads and history walks —
/// the navigations the Mac guard exists to let through — are precisely the
/// two kinds excluded here.
pub fn routesAsLink(kind: ?NavKind) bool {
    const k = kind orelse return true;
    return k == .new_document;
}

/// Whether a LIVE-PAGE navigation is the kind a cross-site route applies to
/// (T825) — Mac's `navigationType == .linkActivated` on the main frame,
/// translated to the three things WebView2 says about a navigation.
///
/// Narrower than `routesAsLink` because the document here is not ours. A file
/// pane shows the bundled template, which runs no navigating script, so a new
/// document there IS a link activation; an arbitrary website navigates itself
/// constantly, and a page's own redirects, script navigations and form posts
/// are the page's business, not the user's click.
///
/// - `kind`: reloads and history walks are excluded by `routesAsLink`, exactly
///   as in file mode.
/// - `redirected`: a server hop out of the site is the page answering the
///   click, not a second click. Mac excludes it for the same reason.
/// - `user_initiated`: WebView2's own answer AND the caller's, because the
///   runtime's alone is not enough. `IsUserInitiated` means "not initiated by
///   page script", so it is TRUE for a host `Navigate` too — the pane loading
///   the website it was opened with reports as user-initiated, and routing
///   that cancels the pane's whole reason for existing. The caller subtracts
///   its own navigations (`ViewerPane.self_nav_pending`); what is left is a
///   click. The known divergence from Mac is a script-SYNTHESIZED `a.click()`:
///   WebKit calls that `.linkActivated` and would route it, WebView2 reports it
///   as not user-initiated and we leave it with the page. Erring that way keeps
///   a page's own machinery working, which is the failure a user would notice.
///
/// Main-frame-ness needs no test: `NavigationStarting` is the top-level frame's
/// event, and a subframe's navigation arrives on `FrameNavigationStarting`,
/// which nothing subscribes to.
pub fn routesAsLivePageLink(kind: ?NavKind, user_initiated: bool, redirected: bool) bool {
    if (!routesAsLink(kind)) return false;
    if (redirected) return false;
    return user_initiated;
}

/// Mac `resolveForNavigation`'s first try: the clicked link resolved against
/// the viewed file's own directory. The second try is `rootedCandidate`
/// (shared with the resource resolver); existence is the caller's check, as
/// everywhere in this module.
///
/// Deliberately UNGUARDED, unlike `candidateUnder`: nothing here is served to
/// the page — the result opens in a viewer split or the default app on the
/// user's behalf, exactly like a path they typed — and Mac's navigation
/// resolver has no escape guard for the same reason. Caller owns the result.
pub fn navCandidate(
    alloc: Allocator,
    base_dir: []const u8,
    rel: []const u8,
) Allocator.Error!?[]u8 {
    if (base_dir.len == 0 or rel.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{ base_dir, rel });
}

/// What a routed FILE target opens in (Mac `handleFileModeLink`'s final
/// switch): a document Ghoztty can RENDER gets a viewer split next to this
/// pane; everything else — code, images, archives — goes to its default app.
///
/// `.html` joined markdown on that side with T601: it renders here now, so
/// handing it to the default app would open the user's browser for a page the
/// pane next door was about to show them.
pub const FileLinkAction = enum { viewer_split, default_app };

pub fn fileLinkAction(path: []const u8) FileLinkAction {
    return switch (modeFor(path)) {
        // A diff is a Ghoztty view like the other two, and it reaches here only
        // from a document that LINKED to `git-diff:…` — which is a link to a
        // pane, not to a file the shell could open at all.
        .markdown, .html, .diff => .viewer_split,
        .code, .web => .default_app,
    };
}

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

    // T601: `.html`/`.htm` is a fourth mode, not code. Before this the pane
    // showed you the markup, which is why anything wanting to SEE the page had
    // to stand up an http server for a file already on disk.
    try testing.expectEqual(Mode.html, modeFor("/site/index.html"));
    try testing.expectEqual(Mode.html, modeFor("C:\\site\\INDEX.HTM"));
    try testing.expectEqual(Mode.html, modeFor("file:///c:/site/index.html"));
    // A URL is still the web, extension or not.
    try testing.expectEqual(Mode.web, modeFor("https://example.com/index.html"));
    // Neighbours that only LOOK like it.
    try testing.expectEqual(Mode.code, modeFor("/site/index.html.tmpl"));
    try testing.expectEqual(Mode.code, modeFor("/site/x.xhtml"));
}

test "the three mode predicates split file, template and live page" {
    // The T601 split: `.html` has a file behind it AND is a live page, and is
    // the only mode for which those two are true at once. Everything that used
    // to key on `isFile` had to choose which of the two it meant.
    for ([_]Mode{ .markdown, .code, .html }) |m| try testing.expect(m.isFile());
    try testing.expect(!Mode.web.isFile());

    for ([_]Mode{ .markdown, .code }) |m| try testing.expect(m.usesTemplate());
    for ([_]Mode{ .web, .html }) |m| try testing.expect(!m.usesTemplate());

    for ([_]Mode{ .web, .html }) |m| try testing.expect(m.isLivePage());
    for ([_]Mode{ .markdown, .code }) |m| try testing.expect(!m.isLivePage());

    // A diff (T463) is the mirror of `.html`: it uses the template and has no
    // file behind it, which is the combination nothing else has.
    try testing.expect(Mode.diff.usesTemplate());
    try testing.expect(!Mode.diff.isFile());
    try testing.expect(!Mode.diff.isLivePage());
}

test "the diff schemes classify ahead of every path test" {
    // `git-diff:main...HEAD` ends in something that looks like an extension and
    // contains no `://`, so it reaches every other test disguised as a file.
    try testing.expectEqual(Mode.diff, modeFor("git-status:"));
    try testing.expectEqual(Mode.diff, modeFor("git-status"));
    try testing.expectEqual(Mode.diff, modeFor("git-diff:"));
    try testing.expectEqual(Mode.diff, modeFor("git-diff:main...HEAD"));
    try testing.expectEqual(Mode.diff, modeFor("git-diff:a1b2c3d"));
    // The near-miss: a FILE whose name starts with the same letters.
    try testing.expectEqual(Mode.markdown, modeFor("git-diff-notes.md"));
    try testing.expectEqual(Mode.code, modeFor("git-status-report.txt"));
}

test "reloadPlan: the branch is the verb's whole contract" {
    // A completed page reloads in the way its mode can: the web re-fetches,
    // a file re-renders. These two are the ordinary cases.
    try testing.expectEqual(ReloadPlan.refetch, reloadPlan(.web, true, .chrome));
    try testing.expectEqual(ReloadPlan.rerender, reloadPlan(.markdown, true, .chrome));
    try testing.expectEqual(ReloadPlan.rerender, reloadPlan(.code, true, .chrome));

    // T601, and the one place the REASON matters. A save must leave the reader
    // where they were, so it is a normal reload (the engine restores scroll and
    // replaces the history entry); an explicit `+reload` is the user saying the
    // bytes on screen are stale, so it bypasses every cache.
    try testing.expectEqual(ReloadPlan.reload_in_place, reloadPlan(.html, true, .file_changed));
    try testing.expectEqual(ReloadPlan.refetch, reloadPlan(.html, true, .chrome));
    // The reason changes nothing for any other mode: a template re-render reads
    // the file either way, and a website has no local file to have changed.
    try testing.expectEqual(ReloadPlan.rerender, reloadPlan(.markdown, true, .file_changed));
    try testing.expectEqual(ReloadPlan.refetch, reloadPlan(.web, true, .file_changed));
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.html, false, .file_changed));

    // Nothing has finished loading yet — a pane whose first navigation failed
    // or is still in flight. Re-rendering into a page that has no
    // `window.__viewer` yet, or asking DevTools to reload a document that was
    // never fetched, both end in a pane that stays blank and says nothing; the
    // recovery is to load it again from scratch. This is the case `+reload`
    // exists for on a pane the user is staring at BECAUSE it is empty.
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.web, false, .chrome));
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.markdown, false, .chrome));
    try testing.expectEqual(ReloadPlan.full_load, reloadPlan(.code, false, .chrome));
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

test "splitWorkingDirectory: the viewed file's directory, and nothing else" {
    // The whole point: a terminal split off a file viewer starts where the
    // file is (Mac `splitConfigFromViewer`).
    try testing.expectEqualStrings(
        "C:\\src\\docs",
        splitWorkingDirectory("C:\\src\\docs\\design.md").?,
    );
    try testing.expectEqualStrings(
        "C:/src/docs",
        splitWorkingDirectory("C:/src/docs/design.md").?,
    );

    // A web viewer has no `file_path` at all, which is Mac's nil `fileURL`:
    // no override, so the split keeps whatever it would have inherited.
    try testing.expect(splitWorkingDirectory(null) == null);

    // A bare name has no directory part. `dirname` answers "" or null
    // depending on the shape; either way a cwd of nowhere must not be
    // forwarded as if it were a real one.
    try testing.expect(splitWorkingDirectory("README.md") == null);

    // A drive root still names a directory, so it is a legitimate answer.
    try testing.expectEqualStrings("C:\\", splitWorkingDirectory("C:\\a.md").?);
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

    // T601: the page host is a DIFFERENT origin, and the two parsers must not
    // answer for each other — a page asking for `vendor/markdown-it.min.js`
    // would otherwise be handed the bundled template's copy.
    try testing.expect(requestPath(&buf, "https://ghoztty-page/index.html") == null);
    try testing.expect(pageRequestPath(&buf, "https://ghoztty-viewer/viewer.html") == null);
}

test "pageRequestPath and isPageOrigin: the rendered page's own origin (T601)" {
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings(
        "index.html",
        pageRequestPath(&buf, "https://ghoztty-page/index.html").?,
    );
    try testing.expectEqualStrings(
        "assets/app.css",
        pageRequestPath(&buf, "https://ghoztty-page/assets/app.css").?,
    );
    try testing.expectEqualStrings(
        "my page.html",
        pageRequestPath(&buf, "https://ghoztty-page/my%20page.html#top").?,
    );
    try testing.expect(pageRequestPath(&buf, "https://ghoztty-page.evil.com/x") == null);
    try testing.expect(pageRequestPath(&buf, "https://ghoztty-page/") == null);

    // `isPageOrigin` is the coarser test `syncCommitted` runs BEFORE deciding
    // "https means the web": it must say yes for the bare origin too, where
    // there is no resource path to extract.
    try testing.expect(isPageOrigin("https://ghoztty-page/index.html"));
    try testing.expect(isPageOrigin("https://ghoztty-page"));
    try testing.expect(isPageOrigin("HTTPS://GHOZTTY-PAGE/x.html"));
    try testing.expect(!isPageOrigin("https://ghoztty-pages/x.html"));
    try testing.expect(!isPageOrigin("https://ghoztty-viewer/viewer.html"));
    try testing.expect(!isPageOrigin("https://example.com/"));
}

test "pageUrlFor: round-trips back through pageRequestPath (T601)" {
    const alloc = testing.allocator;
    const sep = std.fs.path.sep_str;

    {
        const root = "C:" ++ sep ++ "site";
        const path = "C:" ++ sep ++ "site" ++ sep ++ "index.html";
        const url = (try pageUrlFor(alloc, root, path)).?;
        defer alloc.free(url);
        try testing.expectEqualStrings("https://ghoztty-page/index.html", url);

        // The whole point of the pair: what the pane navigates to is what the
        // request handler resolves back to the same file.
        var buf: [256]u8 = undefined;
        const rel = pageRequestPath(&buf, url).?;
        const back = (try candidateUnder(alloc, root, rel)).?;
        defer alloc.free(back);
        try testing.expect(isUnder(back, root));
    }

    // A page in a subdirectory of the grant, and a name needing escapes. The
    // separators become `/` and everything outside the unreserved set is
    // percent-encoded, or the URL would carry a `#` that truncates the path.
    {
        const root = "C:" ++ sep ++ "site";
        const path = "C:" ++ sep ++ "site" ++ sep ++ "docs" ++ sep ++ "a b#c.html";
        const url = (try pageUrlFor(alloc, root, path)).?;
        defer alloc.free(url);
        try testing.expectEqualStrings("https://ghoztty-page/docs/a%20b%23c.html", url);

        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("docs/a b#c.html", pageRequestPath(&buf, url).?);
    }

    // A path outside the grant has no URL at all: navigating to one the handler
    // would then refuse is a blank pane with no explanation.
    {
        const root = "C:" ++ sep ++ "site";
        const outside = "C:" ++ sep ++ "other" ++ sep ++ "index.html";
        try testing.expect((try pageUrlFor(alloc, root, outside)) == null);
        try testing.expect((try pageUrlFor(alloc, root, root)) == null);
        try testing.expect((try pageUrlFor(alloc, "", "x.html")) == null);
    }
}

test "the bundled stylesheet names fonts that resolve on Windows" {
    // T386: `viewer.css` is the SHARED sheet the bundled markdown/code page
    // renders through on both platforms, and its stacks were macOS-only —
    // -apple-system / SF Pro Text / SF Mono, with the generic families behind
    // them. On Windows none of those resolve, so a document body drew in Arial
    // and its code blocks in whatever the generic monospace is, next to chrome
    // that is Segoe UI. `system-ui` leads the sans stack (San Francisco on
    // macOS, Segoe UI here) and the Windows monospace faces sit ahead of the
    // generic keyword; the sheet stays one file, unforked.
    const css = @embedFile("../../viewer/viewer.css");

    // Every font-family declaration in OUR half of the sheet — the vendored
    // GitHub stylesheet is not ours to edit — must offer a family Windows can
    // actually resolve before it reaches a generic keyword.
    try testing.expect(std.mem.indexOf(u8, css, "--fontStack-sansSerif: system-ui,") != null);
    try testing.expect(std.mem.indexOf(u8, css, "\"Segoe UI\"") != null);
    try testing.expect(std.mem.indexOf(u8, css, "Consolas") != null);

    // The error card is a separate declaration and had the same hole.
    const card = "font-family: system-ui, -apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Segoe UI\"";
    try testing.expect(std.mem.indexOf(u8, css, card) != null);

    // Nothing in our half may lead with the macOS-only spelling again: every
    // `font-family:`/`--fontStack-` declaration starts either with `system-ui`
    // or with `ui-monospace` (which Chromium answers on both platforms), never
    // with `-apple-system`.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, css, i, "font-family: ")) |at| : (i = at + 1) {
        const rest = css[at + "font-family: ".len ..];
        try testing.expect(
            std.mem.startsWith(u8, rest, "system-ui") or
                std.mem.startsWith(u8, rest, "ui-monospace") or
                std.mem.startsWith(u8, rest, "var(--fontStack") or
                std.mem.startsWith(u8, rest, "inherit"),
        );
    }
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

test "classifyLink: the Mac policy, with the virtual host carved out first" {
    // A pane that has committed nothing has no site to be outside of, so a
    // live page still follows every link in place — every target, even ones
    // the file policy would route.
    try testing.expectEqual(LinkClass.allow, classifyLink(.web, null, "https://example.com/x"));
    try testing.expectEqual(LinkClass.allow, classifyLink(.web, null, "file:///C:/a.md"));
    try testing.expectEqual(LinkClass.allow, classifyLink(.web, null, "mailto:a@b.c"));
    // Same once it HAS committed, as long as the link stays on the site.
    const site = "https://example.com/one";
    try testing.expectEqual(LinkClass.allow, classifyLink(.web, site, "https://example.com/x"));

    // The template is the pane's own document, fragment or query included —
    // without the stripQuery, `viewer.html#x` would read as a relative link
    // to `viewer.html` and open the TEMPLATE next to the file.
    try testing.expectEqual(LinkClass.allow, classifyLink(.markdown, null, page_url));
    try testing.expectEqual(LinkClass.allow, classifyLink(.markdown, null, page_url ++ "#frag"));
    try testing.expectEqual(LinkClass.allow, classifyLink(.markdown, null, page_url ++ "?v=1"));

    // A relative link in the document arrives under our origin. This must win
    // over the generic https test or it ships to the browser as a dead URL.
    try testing.expectEqual(LinkClass.relative, classifyLink(.markdown, null, "https://ghoztty-viewer/other.md"));
    try testing.expectEqual(LinkClass.relative, classifyLink(.code, null, "https://ghoztty-viewer/a/b.png"));
    // The bare origin is ours too (no resource named — the dispatch drops it),
    // NOT a website to open.
    try testing.expectEqual(LinkClass.relative, classifyLink(.markdown, null, "https://ghoztty-viewer"));
    try testing.expectEqual(LinkClass.relative, classifyLink(.markdown, null, "https://ghoztty-viewer/"));
    // A look-alike host is NOT ours — it is a real website.
    try testing.expectEqual(LinkClass.browser, classifyLink(.markdown, null, "https://ghoztty-viewer.example.com/x"));

    // External links go to the default browser, whatever the case of the
    // scheme.
    try testing.expectEqual(LinkClass.browser, classifyLink(.markdown, null, "https://example.com/x"));
    try testing.expectEqual(LinkClass.browser, classifyLink(.markdown, null, "HTTP://example.com"));

    // Explicit file URLs come through as written (markdown-it linkify or the
    // author's own `file://`).
    try testing.expectEqual(LinkClass.file_url, classifyLink(.markdown, null, "file:///C:/docs/a.md"));
    try testing.expectEqual(LinkClass.file_url, classifyLink(.code, null, "FILE:///C:/x.txt"));

    // Everything else is dropped, exactly as Mac's nil-fileURL return.
    try testing.expectEqual(LinkClass.drop, classifyLink(.markdown, null, "mailto:a@b.c"));
    try testing.expectEqual(LinkClass.drop, classifyLink(.markdown, null, "about:blank"));
    try testing.expectEqual(LinkClass.drop, classifyLink(.markdown, null, "vscode://open"));

    // The FILE policy never reads the page: a markdown pane is the bundled
    // template wherever it was navigated from.
    try testing.expectEqual(LinkClass.browser, classifyLink(.markdown, page_url, "https://example.com/x"));

    // T601: a rendered `.html` file is a PAGE. It navigates like a website —
    // its own links, its own relative targets — because that is exactly what it
    // did behind the http server this replaces. Routing its relative links out
    // to a viewer split would break every multi-page local site.
    const local = "https://ghoztty-page/index.html";
    try testing.expectEqual(LinkClass.allow, classifyLink(.html, local, "https://ghoztty-page/two.html"));
    try testing.expectEqual(LinkClass.allow, classifyLink(.html, local, "mailto:a@b.c"));
    // T825: but a link OUT of the page's own site leaves for the browser, in
    // both live modes — this pane's cookie store is nobody else's.
    try testing.expectEqual(LinkClass.browser, classifyLink(.html, local, "https://example.com/x"));
    try testing.expectEqual(LinkClass.browser, classifyLink(.html, local, "file:///C:/a.md"));
    try testing.expectEqual(LinkClass.browser, classifyLink(.web, site, "https://other.com/x"));

    // Except the one thing no engine can load: a `ghoztty://` link still means
    // "this app", in every mode — ahead of even the cross-site test, so a doc
    // hosted anywhere can address this app.
    try testing.expectEqual(
        LinkClass.ghoztty_command,
        classifyLink(.html, local, "ghoztty://focus/dev"),
    );
    try testing.expectEqual(
        LinkClass.ghoztty_command,
        classifyLink(.web, site, "ghoztty://focus/dev"),
    );
}

test "isExternalLivePageLink: host and port as written decide, not the origin" {
    const page = "https://example.com/a/b?q=1#f";

    // The same host is the same site, wherever on it the link points.
    try testing.expect(!isExternalLivePageLink(page, "https://example.com/"));
    try testing.expect(!isExternalLivePageLink(page, "https://example.com/deep/x?y#z"));
    // The scheme is excluded on purpose: an http -> https upgrade on one host
    // is the most common same-site hop there is.
    try testing.expect(!isExternalLivePageLink(page, "http://example.com/x"));
    try testing.expect(!isExternalLivePageLink("http://example.com/", "https://example.com/x"));
    // Hosts are case-insensitive.
    try testing.expect(!isExternalLivePageLink(page, "https://EXAMPLE.COM/x"));
    // Credentials are not part of the site.
    try testing.expect(!isExternalLivePageLink(page, "https://user:p@ss@example.com/x"));

    // Another site, including a subdomain — "a link out to another site" is
    // what a person means by it, not what a script may read.
    try testing.expect(isExternalLivePageLink(page, "https://other.com/x"));
    try testing.expect(isExternalLivePageLink(page, "https://www.example.com/x"));
    try testing.expect(isExternalLivePageLink(page, "https://example.com.evil.test/x"));

    // The port is part of the site as WRITTEN: two dev servers on one host are
    // two different places.
    try testing.expect(isExternalLivePageLink("http://localhost:3000/", "http://localhost:5173/"));
    try testing.expect(!isExternalLivePageLink("http://localhost:3000/", "http://localhost:3000/x"));
    // ...except a default port, which is the same site as no port at all.
    try testing.expect(!isExternalLivePageLink("http://example.com:80/", "https://example.com/x"));
    try testing.expect(!isExternalLivePageLink("https://example.com:443/", "http://example.com/x"));
    // A non-default port spelled out is still a different place, even when it
    // is the OTHER scheme's default.
    try testing.expect(isExternalLivePageLink("http://example.com:443/", "https://example.com/x"));
    // An empty port is no port, exactly as a browser reads it.
    try testing.expect(!isExternalLivePageLink("http://example.com:/", "http://example.com/x"));

    // IPv6 literals: the colons inside the brackets are not a port.
    try testing.expect(!isExternalLivePageLink("http://[::1]:8080/", "http://[::1]:8080/x"));
    try testing.expect(isExternalLivePageLink("http://[::1]:8080/", "http://[::1]:9090/x"));

    // Schemes with no destination the shell should own stay in the pane.
    for ([_][]const u8{
        "javascript:void(0)",
        "data:text/html,<p>x",
        "blob:https://example.com/1234",
        "about:blank",
        "mailto:a@b.c",
        "vscode://open",
    }) |link| try testing.expect(!isExternalLivePageLink(page, link));

    // A `file://` link is the exception: the engine refuses that navigation
    // from an https document, so following it in the pane is a dead click.
    try testing.expect(isExternalLivePageLink(page, "file:///C:/a.md"));
    try testing.expect(isExternalLivePageLink(page, "FILE:///C:/a.md"));

    // A page that is not an http(s) document has no site to be outside of.
    try testing.expect(!isExternalLivePageLink("about:blank", "https://other.com/x"));
    try testing.expect(!isExternalLivePageLink("", "https://other.com/x"));

    // A link we cannot classify is not ejected: an unparseable port leaves the
    // navigation exactly where it was.
    try testing.expect(!isExternalLivePageLink(page, "https://example.com:80x/y"));

    // The synthetic host a rendered `.html` file is served from is a site like
    // any other — which is the whole of Mac's file:// containment rule here,
    // because a link cannot spell its way out from under a host.
    const local = "https://" ++ page_virtual_host ++ "/mock/index.html";
    try testing.expect(!isExternalLivePageLink(local, "https://" ++ page_virtual_host ++ "/other/x.html"));
    try testing.expect(isExternalLivePageLink(local, "https://example.com/x"));
    try testing.expect(isExternalLivePageLink(local, "https://" ++ virtual_host ++ "/viewer.html"));
}

test "routesAsLivePageLink: only a user's click out of a live page routes" {
    // The click this exists for.
    try testing.expect(routesAsLivePageLink(.new_document, true, false));
    // A runtime too old to report a kind still gets the other two gates.
    try testing.expect(routesAsLivePageLink(null, true, false));
    try testing.expect(!routesAsLivePageLink(null, false, false));

    // The page's own business: a reload, a history walk, a server redirect,
    // and any navigation the host or a script started.
    try testing.expect(!routesAsLivePageLink(.reload, true, false));
    try testing.expect(!routesAsLivePageLink(.back_or_forward, true, false));
    try testing.expect(!routesAsLivePageLink(.new_document, true, true));
    try testing.expect(!routesAsLivePageLink(.new_document, false, false));
}

test "routesAsLink: new documents route, the pane's own kinds do not" {
    // A reload re-runs the pane's own document; a history walk is
    // `syncCommitted`'s job (Back from a website re-renders the file). Routing
    // either would cancel it.
    try testing.expect(!routesAsLink(.reload));
    try testing.expect(!routesAsLink(.back_or_forward));
    // A new document in file mode is a link activation (the template runs no
    // navigating script of its own) — and a runtime too old to report a kind
    // is read the same way, because degrading to "never route" would be the
    // whole feature silently off.
    try testing.expect(routesAsLink(.new_document));
    try testing.expect(routesAsLink(null));
}

test "navCandidate: next to the viewed file, unguarded on purpose" {
    const alloc = testing.allocator;
    const base = if (builtin.os.tag == .windows) "D:\\docs\\project" else "/docs/project";

    {
        const got = (try navCandidate(alloc, base, "other.md")).?;
        defer alloc.free(got);
        const want = try std.fs.path.resolve(alloc, &.{ base, "other.md" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, got);
    }

    // `..` may leave the base: a link one directory up is a link the AUTHOR
    // wrote and the USER clicked, opening on their behalf — not a resource
    // served to the page. (`candidateUnder` refuses this; the difference is
    // the point.)
    {
        const got = (try navCandidate(alloc, base, "../sibling/a.md")).?;
        defer alloc.free(got);
        const want = try std.fs.path.resolve(alloc, &.{ base, "..", "sibling", "a.md" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, got);
    }

    try testing.expect((try navCandidate(alloc, base, "")) == null);
    try testing.expect((try navCandidate(alloc, "", "a.md")) == null);
}

test "fileLinkAction: what Ghoztty can render splits, the rest opens in its app" {
    for ([_][]const u8{ "a.md", "a.markdown", "a.MD", "docs/b.mdown" }) |p| {
        try testing.expectEqual(FileLinkAction.viewer_split, fileLinkAction(p));
    }
    // T601: an `.html` link from a markdown doc opens a viewer split too, now
    // that the viewer renders one. Handing it to the default app would launch
    // the browser for a page the pane next door was about to show.
    for ([_][]const u8{ "a.html", "site/b.HTM" }) |p| {
        try testing.expectEqual(FileLinkAction.viewer_split, fileLinkAction(p));
    }
    for ([_][]const u8{ "a.zig", "a.png", "a.pdf", "Makefile", "a.txt" }) |p| {
        try testing.expectEqual(FileLinkAction.default_app, fileLinkAction(p));
    }
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
