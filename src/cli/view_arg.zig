//! Shared handling of `--view=`, used by both `+split` and `+new-window`.
//!
//! One implementation on purpose: the two commands must agree exactly on what
//! counts as a path (and therefore gets resolved CLI-side against the caller's
//! cwd) versus what is an opaque location the app interprets itself. They used
//! to carry a copy each — byte-identical, and both carrying the same bug, the
//! T257 lesson (four copies of the chrome datum, four chances to be wrong, no
//! way to notice) applied to a second subsystem. A new scheme handled in one
//! copy and not the other is silently mangled into a path by the other verb.
//!
//! The app process has no idea what the caller's cwd was, which is why the
//! rewrite has to happen CLI-side at all.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const lib = @import("../lib/main.zig");

/// The schemes that name a git diff rather than a file.
///
/// A diff spec's text is a REVSPEC — `main...HEAD`, a sha, or nothing at all —
/// so path resolution must never touch it. Which repository it applies to is
/// decided app-side from `--working-directory` (else the caller's cwd, which
/// both commands insert), exactly as a relative file path is.
const diff_schemes = [_][]const u8{ "git-diff", "git-status" };

/// True when `--view=<value>` names a diff.
///
/// The colon is what makes this a scheme, and it is optional ONLY when nothing
/// follows it: `git-diff` and `git-diff:main...HEAD` are diffs, while
/// `git-diff-notes.md` is a file that merely starts with the same letters. A
/// bare `startsWith` here would quietly stop resolving that file's path.
/// Mirrors `ViewerDiffSpec.parse` on the Swift side.
pub fn isDiffView(value: []const u8) bool {
    for (diff_schemes) |scheme| {
        if (std.mem.eql(u8, value, scheme)) return true;
        if (value.len > scheme.len and
            std.mem.startsWith(u8, value, scheme) and
            value[scheme.len] == ':') return true;
    }
    return false;
}

/// Whether a `--view=` value has to be resolved against a base directory.
///
/// Everything that already names its own location passes through untouched:
/// URLs (`https://…`, and any other scheme — the viewer routes by scheme, not
/// by a fixed list), `about:` pages such as the blank browser start page, git
/// diff specs (see `isDiffView`), and absolute paths.
///
/// "Absolute" is `std.fs.path.isAbsolute`, which is half the point of this
/// function existing: both call sites used to test `value[0] == '/'`, so on
/// Windows a real absolute path (`C:\src\README.md`, or a `\\server\share`
/// UNC) looked RELATIVE and got a cwd glued onto its front.
pub fn needsResolution(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.fs.path.isAbsolute(value)) return false;
    if (std.mem.indexOf(u8, value, "://") != null) return false;
    if (std.mem.startsWith(u8, value, "about:")) return false;
    if (isDiffView(value)) return false;
    return true;
}

/// Rewrite the first relative `--view=` argument in place, resolved against
/// `--working-directory=` when present (else the caller's cwd). `arguments`
/// entries are replaced with arena-allocated copies, so `alloc` must outlive
/// the request.
pub fn resolve(alloc: Allocator, arguments: [][:0]const u8) !void {
    for (arguments, 0..) |arg, i| {
        const rest = lib.cutPrefix(u8, arg, "--view=") orelse continue;
        if (!needsResolution(rest)) return;

        var base: ?[]const u8 = null;
        for (arguments) |a| {
            if (lib.cutPrefix(u8, a, "--working-directory=")) |wd| base = wd;
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = base orelse try std.fs.cwd().realpath(".", &buf);
        const resolved = try std.fs.path.resolve(alloc, &.{ cwd, rest });
        arguments[i] = try std.fmt.allocPrintSentinel(alloc, "--view={s}", .{resolved}, 0);
        return;
    }
}

// -----------------------------------------------------------------------------

const testing = std.testing;

test "diff specs are not treated as paths" {
    try testing.expect(isDiffView("git-status:"));
    try testing.expect(isDiffView("git-status"));
    try testing.expect(isDiffView("git-diff:main...HEAD"));
    try testing.expect(isDiffView("git-diff:"));
    // Files that merely start with the same letters are still files.
    try testing.expect(!isDiffView("git-diff-report.md"));
    try testing.expect(!isDiffView("git-status.txt"));
    try testing.expect(!isDiffView("git-statuses:"));
    try testing.expect(!isDiffView("docs/git-status:notes.md"));
    try testing.expect(!isDiffView("README.md"));
    try testing.expect(!isDiffView(""));
}

test "needsResolution: relative paths resolve, self-locating values do not" {
    // The reason this module exists.
    try testing.expect(needsResolution("README.md"));
    try testing.expect(needsResolution("docs/design/viewer-panes.md"));
    try testing.expect(needsResolution("./README.md"));
    try testing.expect(needsResolution("../sibling/README.md"));

    // Schemes are self-locating, and not just http(s): the viewer routes on
    // the scheme, so anything with one must survive untouched.
    try testing.expect(!needsResolution("https://example.com"));
    try testing.expect(!needsResolution("http://localhost:3000/x"));
    try testing.expect(!needsResolution("file:///c:/src/README.md"));
    try testing.expect(!needsResolution("about:blank"));

    // Diff specs are revspecs, not paths.
    try testing.expect(!needsResolution("git-diff"));
    try testing.expect(!needsResolution("git-diff:main...HEAD"));
    try testing.expect(!needsResolution("git-status:"));
    // ...but a file that merely starts with a scheme name still is one.
    try testing.expect(needsResolution("git-diff-notes.md"));

    // Empty is not a path to fix; the flag is effectively absent.
    try testing.expect(!needsResolution(""));
}

test "needsResolution: absolute is the platform's own rule" {
    // A POSIX absolute path is absolute on every target zig builds this for
    // (Windows accepts a rooted `/…` too), so this holds in both lanes.
    try testing.expect(!needsResolution("/usr/share/doc/README.md"));

    if (builtin.os.tag == .windows) {
        // The live bug: `rest[0] == '/'` said "relative" for every one of
        // these, so `+split --view=C:\src\README.md` got the caller's cwd
        // prepended and the file was never found.
        try testing.expect(!needsResolution("C:\\src\\README.md"));
        try testing.expect(!needsResolution("C:/src/README.md"));
        try testing.expect(!needsResolution("\\\\server\\share\\README.md"));
        // A drive-relative path (`C:README.md`) really is relative — to that
        // drive's own cwd, which we cannot resolve here either way; treating
        // it as needing resolution matches the pre-existing behavior.
        try testing.expect(needsResolution("C:README.md"));
    }
}

test "resolve: relative view is rewritten against --working-directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const base = if (builtin.os.tag == .windows) "C:\\src\\repo" else "/src/repo";
    var arguments = [_][:0]const u8{
        try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{base}, 0),
        try alloc.dupeZ(u8, "--view=docs/x.md"),
    };
    try resolve(alloc, &arguments);

    const want = try std.fs.path.resolve(alloc, &.{ base, "docs/x.md" });
    const got = lib.cutPrefix(u8, arguments[1], "--view=").?;
    try testing.expectEqualStrings(want, got);
}

test "resolve: self-locating values are left byte-for-byte alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const base = if (builtin.os.tag == .windows) "C:\\src\\repo" else "/src/repo";
    const untouched = [_][]const u8{
        "https://example.com",
        "about:blank",
        "git-diff:main...HEAD",
        "git-status:",
        if (builtin.os.tag == .windows) "C:\\other\\README.md" else "/other/README.md",
    };
    for (untouched) |value| {
        var arguments = [_][:0]const u8{
            try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{base}, 0),
            try std.fmt.allocPrintSentinel(alloc, "--view={s}", .{value}, 0),
        };
        try resolve(alloc, &arguments);
        try testing.expectEqualStrings(value, lib.cutPrefix(u8, arguments[1], "--view=").?);
    }
}

test "resolve: a file that starts with a scheme name still gets path-resolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const base = if (builtin.os.tag == .windows) "C:\\src\\repo" else "/src/repo";
    var arguments = [_][:0]const u8{
        try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{base}, 0),
        try alloc.dupeZ(u8, "--view=git-diff-notes.md"),
    };
    try resolve(alloc, &arguments);

    const want = try std.fs.path.resolve(alloc, &.{ base, "git-diff-notes.md" });
    const got = lib.cutPrefix(u8, arguments[1], "--view=").?;
    try testing.expectEqualStrings(want, got);
}

test "resolve: no --view argument is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arguments = [_][:0]const u8{
        try alloc.dupeZ(u8, "--target=dev"),
        try alloc.dupeZ(u8, "--command=pwsh"),
    };
    try resolve(alloc, &arguments);
    try testing.expectEqualStrings("--target=dev", arguments[0]);
    try testing.expectEqualStrings("--command=pwsh", arguments[1]);
}
