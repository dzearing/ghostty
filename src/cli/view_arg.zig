//! Shared handling of `--view=`, used by both `+split` and `+new-window`.
//!
//! One implementation on purpose: the two commands must agree exactly on what
//! counts as a path (and therefore gets resolved CLI-side against the caller's
//! cwd) versus what is an opaque location the app interprets itself. They used
//! to carry a copy each, which is how a new scheme ends up working in one
//! command and silently mangled into a path in the other.

const std = @import("std");
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

/// Rewrite a relative `--view=` path to an absolute one, resolved against
/// `--working-directory=` when present (else the caller's cwd). The app
/// process can't know the caller's cwd, so this must happen CLI-side.
///
/// Passed through untouched: URLs (containing "://"), `about:` pages such as
/// the blank browser start page, git diff specs (see `isDiffView`), and paths
/// that are already absolute.
pub fn resolve(alloc: Allocator, arguments: [][:0]const u8) !void {
    for (arguments, 0..) |arg, i| {
        const rest = lib.cutPrefix(u8, arg, "--view=") orelse continue;
        if (rest.len == 0) return;
        if (rest[0] == '/') return;
        if (std.mem.indexOf(u8, rest, "://") != null) return;
        if (std.mem.startsWith(u8, rest, "about:")) return;
        if (isDiffView(rest)) return;

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

test "diff specs are not treated as paths" {
    try std.testing.expect(isDiffView("git-status:"));
    try std.testing.expect(isDiffView("git-status"));
    try std.testing.expect(isDiffView("git-diff:main...HEAD"));
    try std.testing.expect(isDiffView("git-diff:"));
    // Files that merely start with the same letters are still files.
    try std.testing.expect(!isDiffView("git-diff-report.md"));
    try std.testing.expect(!isDiffView("git-status.txt"));
    try std.testing.expect(!isDiffView("git-statuses:"));
    try std.testing.expect(!isDiffView("docs/git-status:notes.md"));
    try std.testing.expect(!isDiffView("README.md"));
    try std.testing.expect(!isDiffView(""));
}

test "relative paths resolve against --working-directory" {
    try expectResolved("--working-directory=/tmp/repo", "--view=docs/design.md", "--view=/tmp/repo/docs/design.md");
}

test "diff specs pass through resolve untouched" {
    try expectResolved("--working-directory=/tmp/repo", "--view=git-diff:main...HEAD", "--view=git-diff:main...HEAD");
    try expectResolved("--working-directory=/tmp/repo", "--view=git-status:", "--view=git-status:");
}

test "a file that starts with a scheme name still gets path-resolved" {
    try expectResolved("--working-directory=/tmp/repo", "--view=git-diff-notes.md", "--view=/tmp/repo/git-diff-notes.md");
}

/// Run `resolve` over one `--working-directory` + one `--view` and check what
/// the `--view` became.
///
/// The two originals are freed by their own owner, NOT through `args`:
/// `resolve` REPLACES the `--view` slot with an arena-allocated string, so
/// freeing `args[1]` afterwards would hand the testing allocator a pointer it
/// never handed out.
fn expectResolved(
    working_directory: []const u8,
    view: []const u8,
    expected: []const u8,
) !void {
    const alloc = std.testing.allocator;
    const wd = try alloc.dupeZ(u8, working_directory);
    defer alloc.free(wd);
    const original_view = try alloc.dupeZ(u8, view);
    defer alloc.free(original_view);

    var args = [_][:0]const u8{ wd, original_view };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try resolve(arena.allocator(), &args);
    try std.testing.expectEqualStrings(expected, args[1]);
}
