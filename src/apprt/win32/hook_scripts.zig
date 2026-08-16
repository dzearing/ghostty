//! Where the installed hook scripts live, and how siblings resolve (T867,
//! the win32 half of Mac's `HookScripts`). The two scripts are siblings in
//! ONE Ghoztty-owned directory, and the BANNER path is what gets threaded
//! through the hook specs — it predates the second script and uniquely
//! identifies the install location. Every other script resolves as its
//! sibling here, so exactly one place knows the layout; the directory (not
//! either script path) is the hook-ownership signature T868 keys on.
//!
//! The install directory is `<home>/.config/ghoztty/hooks` on Windows too —
//! NOT `%LOCALAPPDATA%`. That is forced, not a taste call: the bundled
//! assets already spell this path — `ghoztty-banner.sh` keeps its state in
//! `$HOME/.config/ghoztty/banner-state`, and the `process-feedback` skill
//! invokes `~/.config/ghoztty/hooks/ghoztty-banner.sh` by name — and the
//! hooks themselves run under Git Bash, where `~/.config/...` spells
//! identically on both platforms. One spelling keeps the merged-fragment
//! ownership signature and any shared tests platform-agnostic.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");

pub const banner_name = "ghoztty-banner.sh";
pub const activity_state_name = "ghoztty-activity-state.sh";

/// Home-relative install directory both scripts sit in (forward slashes:
/// composed paths feed `std.fs` calls, which accept them on Windows, and
/// bash-facing spellings, which require them).
pub const install_dir = ".config/ghoztty/hooks";

/// Home-relative path of each script.
pub const banner_sub_path = install_dir ++ "/" ++ banner_name;
pub const activity_state_sub_path = install_dir ++ "/" ++ activity_state_name;

/// The owned directory, derived from the banner script's full path — the
/// hook-ownership signature (see module doc). Handles both separators, since
/// a Windows-composed path may carry `\` where a bash-composed one has `/`.
pub fn directory(banner_script_path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, banner_script_path, "/\\") orelse
        return banner_script_path[0..0];
    return banner_script_path[0..cut];
}

/// The activity-state script's full path, resolved as the banner's sibling.
/// Joined with the same separator that precedes the banner's basename, so a
/// path stays consistently spelled whichever convention composed it.
pub fn activityStatePath(
    alloc: std.mem.Allocator,
    banner_script_path: []const u8,
) std.mem.Allocator.Error![]u8 {
    const cut = std.mem.lastIndexOfAny(u8, banner_script_path, "/\\") orelse
        return alloc.dupe(u8, activity_state_name);
    return std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
        banner_script_path[0..cut],
        banner_script_path[cut],
        activity_state_name,
    });
}

const testing = std.testing;

test "sub paths are the bash-facing spellings the bundled assets rely on" {
    try testing.expectEqualStrings(".config/ghoztty/hooks/ghoztty-banner.sh", banner_sub_path);
    try testing.expectEqualStrings(".config/ghoztty/hooks/ghoztty-activity-state.sh", activity_state_sub_path);
}

test "directory strips the basename under either separator" {
    try testing.expectEqualStrings(
        "/home/u/.config/ghoztty/hooks",
        directory("/home/u/.config/ghoztty/hooks/ghoztty-banner.sh"),
    );
    try testing.expectEqualStrings(
        "C:\\Users\\u\\.config\\ghoztty\\hooks",
        directory("C:\\Users\\u\\.config\\ghoztty\\hooks\\ghoztty-banner.sh"),
    );
    try testing.expectEqualStrings("", directory("ghoztty-banner.sh"));
}

test "activityStatePath resolves the sibling with the path's own separator" {
    const alloc = testing.allocator;
    {
        const got = try activityStatePath(alloc, "/home/u/.config/ghoztty/hooks/ghoztty-banner.sh");
        defer alloc.free(got);
        try testing.expectEqualStrings("/home/u/.config/ghoztty/hooks/ghoztty-activity-state.sh", got);
    }
    {
        const got = try activityStatePath(alloc, "C:\\hooks\\ghoztty-banner.sh");
        defer alloc.free(got);
        try testing.expectEqualStrings("C:\\hooks\\ghoztty-activity-state.sh", got);
    }
}
