//! Is this exe build OUTPUT, or an install? (T1124, T1146)
//!
//! Several launch-time self-heals write something that OUTLIVES the process —
//! a `HKCU\Software\Classes` protocol handler, an `HKCU\...\Run` autostart
//! entry — and each of them bakes in the path of the exe that wrote it. That is
//! exactly right for an install and exactly wrong for a build we made ten
//! minutes ago: the staging release lives at `zig-out-release\bin` INSIDE this
//! checkout, it IS a release build, and ordinary development rebuilds, moves
//! and deletes that directory. A single GUI launch of it was enough to point
//! the user's `ghoztty://` links (T1124) — and, until T1146, the agent Windows
//! starts at sign-in — at a scratch path.
//!
//! The build-mode split does not catch this on its own, because the staging
//! build is a release build by construction. So the callers gate on LOCATION
//! too, and this is the one place that answers the question, so the two gates
//! cannot drift apart.

const std = @import("std");
const testing = std.testing;

/// How far up the tree the checkout marker is looked for. A build output
/// directory sits a couple of levels under the repo root (`zig-out\bin`); the
/// bound exists so a pathological path cannot turn a launch into a long walk.
const max_checkout_depth: usize = 16;

/// Does `dir` sit inside a source checkout — i.e. does it, or any ancestor,
/// hold a `build.zig`?
///
/// This is what tells build OUTPUT apart from an install. Both `zig-out\bin`
/// and `zig-out-release\bin` answer yes; `%LOCALAPPDATA%\Programs\Ghoztty` and
/// a portable unpack on the Desktop answer no, so neither of the two real
/// install shapes loses its registration. The marker is the build file rather
/// than `.git`, because a checkout with no git dir (an archive, a worktree's
/// copy) still builds and still must not claim the user's persistent state.
pub fn inSourceCheckout(alloc: std.mem.Allocator, dir: []const u8) bool {
    var cur: []const u8 = dir;
    var depth: usize = 0;
    while (depth < max_checkout_depth) : (depth += 1) {
        const marker = std.fs.path.join(alloc, &.{ cur, "build.zig" }) catch return false;
        defer alloc.free(marker);
        if (std.fs.accessAbsolute(marker, .{})) |_| return true else |_| {}

        const parent = std.fs.path.dirname(cur) orelse return false;
        // `dirname` of a root ("D:\\", "\\\\host\\share") returns the root or
        // null; either way there is nowhere further up to look.
        if (parent.len >= cur.len) return false;
        cur = parent;
    }
    return false;
}

test "build output is recognised as a source checkout, an install is not" {
    const alloc = testing.allocator;

    // Deliberately NOT `testing.tmpDir`: that lands under `.zig-cache` INSIDE
    // this checkout, where every path in the test has THIS repo's `build.zig`
    // as an ancestor and the negative cases could not fail. The OS temp dir is
    // the only place on the box guaranteed to be outside a source tree.
    const tmp_root = std.process.getEnvVarOwned(alloc, "TEMP") catch return error.SkipZigTest;
    defer alloc.free(tmp_root);
    const root = try std.fmt.allocPrint(alloc, "{s}{c}ghoztty-checkout-test", .{
        tmp_root,
        std.fs.path.sep,
    });
    defer alloc.free(root);
    std.fs.deleteTreeAbsolute(root) catch {};
    defer std.fs.deleteTreeAbsolute(root) catch {};

    var dir = try std.fs.cwd().makeOpenPath(root, .{});
    defer dir.close();

    // A checkout: build.zig at the root, build output a couple of levels down.
    try dir.makePath("repo" ++ std.fs.path.sep_str ++ "zig-out-release" ++ std.fs.path.sep_str ++ "bin");
    try dir.writeFile(.{
        .sub_path = "repo" ++ std.fs.path.sep_str ++ "build.zig",
        .data = "// marker\n",
    });
    const staging = try std.fs.path.join(alloc, &.{ root, "repo", "zig-out-release", "bin" });
    defer alloc.free(staging);
    try testing.expect(inSourceCheckout(alloc, staging));

    // The repo root itself, and the debug output beside it, answer the same.
    const repo = try std.fs.path.join(alloc, &.{ root, "repo" });
    defer alloc.free(repo);
    try testing.expect(inSourceCheckout(alloc, repo));

    // An install: same tree, no build.zig above it. This is the shape of both
    // %LOCALAPPDATA%\Programs\Ghoztty and a portable unpack, and both must keep
    // registering.
    try dir.makePath("Programs" ++ std.fs.path.sep_str ++ "Ghoztty");
    const install = try std.fs.path.join(alloc, &.{ root, "Programs", "Ghoztty" });
    defer alloc.free(install);
    try testing.expect(!inSourceCheckout(alloc, install));

    // A directory that does not exist is not a checkout, and does not error.
    const missing = try std.fs.path.join(alloc, &.{ root, "nope", "bin" });
    defer alloc.free(missing);
    try testing.expect(!inSourceCheckout(alloc, missing));
}
