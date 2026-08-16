//! Copies the bundled hook scripts to STABLE Ghoztty-owned paths so
//! generated hooks never reference a build directory or an install that a
//! delivery replaces (T867, the win32 half of Mac's `BannerScriptInstaller`).
//!
//! Two scripts, one directory (`hook_scripts.install_dir`, home-relative):
//! `ghoztty-banner.sh` keeps the pane's sticky banner current, and
//! `ghoztty-activity-state.sh` owns the pane's idle/busy/needs_input state
//! machine. They install and uninstall together because a runtime's hooks
//! reference both, so a half-installed pair would leave hook commands
//! pointing at a script that isn't there — and for the same reason a partial
//! install rolls back the files this call created (same deliberate
//! improvement over Mac as `SkillComponent`; Mac's installer leaves the
//! half-pair behind on a mid-install failure).
//!
//! The scripts carry the shell ownership marker in their own bytes (asserted
//! by `GhosttyAssets`' tests), so unlike the skills nothing is appended: the
//! bundled text IS the expected installed content.
//!
//! Plain `std.fs` + the T865 writer, no direct OS imports, so the tempdir
//! tests run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const managed_file = @import("managed_file.zig");
const GhosttyAssets = @import("GhosttyAssets.zig");
const hook_scripts = @import("hook_scripts.zig");

const BannerScriptInstaller = @This();

pub const InstallState = marker_mod.InstallState;
pub const marker = marker_mod.shell_comment;

/// The user's home directory (a tempdir in tests).
home: std.fs.Dir,

const Script = struct {
    sub_path: []const u8,
    body: []const u8,
};

/// Every script this component owns, paired with its bundled content. The
/// banner path stays the anchor threaded through the hook specs —
/// `hook_scripts` resolves the siblings from it.
fn scripts() [2]Script {
    return .{
        .{ .sub_path = hook_scripts.banner_sub_path, .body = GhosttyAssets.bannerScript() },
        .{ .sub_path = hook_scripts.activity_state_sub_path, .body = GhosttyAssets.activityStateScript() },
    };
}

/// Installed only when EVERY script is current. A missing or stale sibling
/// has to read as actionable rather than installed, or an upgrade that adds
/// a script would never offer to write it.
pub fn state(self: BannerScriptInstaller, alloc: Allocator) InstallState {
    var saw_installed = false;
    var saw_missing = false;
    var saw_outdated = false;
    for (scripts()) |script| {
        switch (managed_file.state(alloc, self.home, script.sub_path, script.body, marker)) {
            .installed => saw_installed = true,
            .not_installed => saw_missing = true,
            .outdated => saw_outdated = true,
        }
    }
    if (saw_outdated or (saw_installed and saw_missing)) return .outdated;
    return if (saw_installed) .installed else .not_installed;
}

pub const InstallError = managed_file.WriteError;

/// Install both scripts, or neither: a failure on the second removes a
/// first the call created (see module doc), then returns the original error.
pub fn install(self: BannerScriptInstaller, alloc: Allocator) InstallError!void {
    const all = scripts();
    var created: [all.len]bool = .{false} ** all.len;
    for (all, 0..) |script, i| {
        const pre = managed_file.state(alloc, self.home, script.sub_path, script.body, marker);
        managed_file.write(alloc, self.home, script.sub_path, script.body, marker) catch |err| {
            var j = i;
            while (j > 0) {
                j -= 1;
                if (created[j])
                    managed_file.removeIfManaged(alloc, self.home, all[j].sub_path, marker) catch {};
            }
            return err;
        };
        created[i] = pre == .not_installed;
    }
}

pub const UninstallError = managed_file.RemoveError;

/// Remove both managed scripts; a user's own file at either path is a typed
/// refusal and is left byte-identical.
pub fn uninstall(self: BannerScriptInstaller, alloc: Allocator) UninstallError!void {
    for (scripts()) |script| {
        try managed_file.removeIfManaged(alloc, self.home, script.sub_path, marker);
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "fresh install writes both scripts marker-stamped and reports installed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: BannerScriptInstaller = .{ .home = tmp.dir };

    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));

    for (scripts()) |script| {
        const got = try tmp.dir.readFileAlloc(alloc, script.sub_path, managed_file.max_managed_bytes);
        defer alloc.free(got);
        try testing.expectEqualStrings(script.body, got);
        try testing.expect(std.mem.indexOf(u8, got, marker) != null);
    }
}

test "hand-edited but still-marked script reads outdated; reinstall converges" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: BannerScriptInstaller = .{ .home = tmp.dir };

    try c.install(alloc);
    try tmp.dir.writeFile(.{
        .sub_path = hook_scripts.banner_sub_path,
        .data = "#!/bin/sh\n" ++ marker ++ "\necho tweaked\n",
    });
    try testing.expectEqual(InstallState.outdated, c.state(alloc));

    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
}

test "one script missing reads outdated, not installed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: BannerScriptInstaller = .{ .home = tmp.dir };

    try c.install(alloc);
    try tmp.dir.deleteFile(hook_scripts.activity_state_sub_path);
    try testing.expectEqual(InstallState.outdated, c.state(alloc));
}

test "a user's own file at the second path refuses install and rolls back the first" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: BannerScriptInstaller = .{ .home = tmp.dir };

    const users_own = "# my own script\n";
    try tmp.dir.makePath(hook_scripts.install_dir);
    try tmp.dir.writeFile(.{ .sub_path = hook_scripts.activity_state_sub_path, .data = users_own });

    try testing.expectError(error.NotManaged, c.install(alloc));

    // No half-pair: the banner script this call created was removed again.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
    const after = try tmp.dir.readFileAlloc(alloc, hook_scripts.activity_state_sub_path, managed_file.max_managed_bytes);
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
}

test "rollback keeps a banner script that was installed before the call" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: BannerScriptInstaller = .{ .home = tmp.dir };

    try c.install(alloc);
    try tmp.dir.deleteFile(hook_scripts.activity_state_sub_path);
    try tmp.dir.writeFile(.{ .sub_path = hook_scripts.activity_state_sub_path, .data = "# mine now\n" });

    try testing.expectError(error.NotManaged, c.install(alloc));

    // The pre-existing managed banner script survives.
    const got = try tmp.dir.readFileAlloc(alloc, hook_scripts.banner_sub_path, managed_file.max_managed_bytes);
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, marker) != null);
}

test "uninstall removes exactly the marked scripts and tolerates absence" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: BannerScriptInstaller = .{ .home = tmp.dir };

    try c.install(alloc);
    try c.uninstall(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.activity_state_sub_path));
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));

    // Again over nothing: a no-op, not an error.
    try c.uninstall(alloc);

    // A user's own script at the banner path is refused and survives.
    try tmp.dir.writeFile(.{ .sub_path = hook_scripts.banner_sub_path, .data = "# mine\n" });
    try testing.expectError(error.NotManaged, c.uninstall(alloc));
    _ = try tmp.dir.statFile(hook_scripts.banner_sub_path);
}
