//! Hands Claude's `ghoztty` integration over from the standalone plugin to
//! the app (T870, the win32 half of Mac's `ClaudePluginMigration.swift`):
//! the app now ships the same skills itself, tied to the installed Ghoztty
//! rather than to a separately-versioned marketplace release.
//!
//! The plugin is removed through **Claude's own CLI**, never by deleting
//! files out of `~/.claude/plugins/cache`. That tree is Claude Code's
//! package-manager state — it carries `.in_use`/`.orphaned_at` sentinels and
//! a versioned manifest whose schema is not ours — so deleting a directory
//! there leaves a dangling entry the next marketplace sync may act on, and
//! editing the manifest means writing another tool's lockfile. The CLI spawn
//! is injected (`Runner`), so the flow itself tests hermetically and the GUI
//! layer (`AgentIntegration.zig`) supplies the real `claude` invocation.
//!
//! Windows translation of the stale-script rule: Mac's plugin maintains
//! `~/.claude/scripts/ghoztty-banner.sh` as a SYMLINK into its own cache; on
//! Windows the plugin's SessionStart hook COPIES the script there instead
//! (measured on this box, 2026-08-15: a real file, byte-identical to the
//! plugin cache's copy). So ownership is proven two ways: a symlink whose
//! target points into `plugins/cache`, or a regular file byte-identical to
//! any registered ghoztty install's own copy. Anything else is the user's
//! and stays. The decision is taken BEFORE the uninstall runs, because
//! Claude's uninstaller may remove the very cache copy the comparison needs.
//!
//! Plain `std.fs` + the manifest parser, no OS imports, so the tempdir tests
//! run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const claude_plugin_manifest = @import("claude_plugin_manifest.zig");

/// Home-relative directory the plugin's banner hook keeps per-pane state in.
pub const plugin_state_sub_dir = ".claude/ghoztty-banner";

/// Home-relative directory the APP's banner script keeps the same state in
/// (see `hook_scripts.zig`: the bundled script spells this path itself).
pub const app_state_sub_dir = ".config/ghoztty/banner-state";

/// Home-relative path of the script copy/symlink the plugin maintained.
pub const plugin_script_sub_path = ".claude/scripts/ghoztty-banner.sh";

/// The plugin's own copy of the banner script, relative to a registration's
/// `installPath`.
pub const cache_script_rel_path = "hooks/ghoztty-banner.sh";

const max_script_bytes = 1024 * 1024;

pub const UninstallError = error{
    /// The claude CLI could not be run at all.
    ShellUnavailable,
    /// `claude plugin uninstall <registration>` exited nonzero.
    UninstallFailed,
    OutOfMemory,
};

/// The injected `claude plugin uninstall` seam (Mac's `runCommand` closure,
/// as a context + function pointer because Zig has no capturing closures).
pub const Runner = struct {
    ctx: ?*anyopaque = null,
    runFn: *const fn (ctx: ?*anyopaque, registration: []const u8) UninstallError!void,

    pub fn run(self: Runner, registration: []const u8) UninstallError!void {
        return self.runFn(self.ctx, registration);
    }
};

/// Whether the migration has anything to do: the external plugin is
/// registered in Claude's manifest.
pub fn isNeeded(alloc: Allocator, home: std.fs.Dir) Allocator.Error!bool {
    return claude_plugin_manifest.isExternalPluginInstalled(alloc, home);
}

/// Uninstall FIRST. Everything after it is cleanup that only makes sense
/// once the plugin is actually gone, so a failure here leaves the user
/// exactly where they started rather than half-migrated. The stale-script
/// ownership decision is the one thing taken BEFORE the uninstall (see the
/// module doc); acting on it still waits until the uninstall succeeded.
pub fn run(alloc: Allocator, home: std.fs.Dir, runner: Runner) UninstallError!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const regs = try claude_plugin_manifest.registrationsWithPaths(arena, home);
    const remove_script = scriptIsPluginOwned(arena, home, regs);

    for (regs) |reg| try runner.run(reg.key);

    migrateBannerState(home);
    if (remove_script) home.deleteFile(plugin_script_sub_path) catch {};
}

/// Carry the plugin's per-pane banner state into the app's state directory
/// so a pane mid-session keeps its banner instead of blanking until the next
/// prompt.
///
/// Copies rather than moves, and never overwrites: a file the app already
/// wrote is newer than anything the plugin left behind, and leaving the
/// originals in place means a user who reinstalls the plugin finds its state
/// where it expects. Best-effort throughout — a state file that cannot be
/// copied is a blank banner until the next prompt, never a failed migration.
pub fn migrateBannerState(home: std.fs.Dir) void {
    var src = home.openDir(plugin_state_sub_dir, .{ .iterate = true }) catch return;
    defer src.close();
    home.makePath(app_state_sub_dir) catch return;
    var dst = home.openDir(app_state_sub_dir, .{}) catch return;
    defer dst.close();

    var it = src.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (dst.statFile(entry.name)) |_| continue else |_| {}
        src.copyFile(entry.name, dst, entry.name, .{}) catch {};
    }
}

/// Is the script at `plugin_script_sub_path` provably the PLUGIN's, i.e.
/// ours to remove once the plugin is gone? See the module doc for the two
/// proofs. Everything else — a missing file, a link the user aimed
/// somewhere else, content the plugin cannot account for, or any read
/// failure — reads as "not ours": the cost of leaving a stale script is an
/// inert file, the cost of deleting the user's is their data.
pub fn scriptIsPluginOwned(
    arena: Allocator,
    home: std.fs.Dir,
    regs: []const claude_plugin_manifest.Registration,
) bool {
    // Symlink proof (the Mac rule): a link whose target points into the
    // plugin cache is the plugin's, dangling or not. Any readLink failure —
    // including the not-a-reparse-point case, which Zig's Windows ReadLink
    // surfaces as `error.Unexpected` rather than `error.NotLink` — falls
    // through to the byte proof, where a missing or unreadable file simply
    // reads as "not ours".
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (home.readLink(plugin_script_sub_path, &target_buf)) |target| {
        return symlinkTargetIsPluginCache(target);
    } else |_| {}

    // Byte proof (the Windows copy): identical to any registered install's
    // own copy of the script.
    const actual = home.readFileAlloc(arena, plugin_script_sub_path, max_script_bytes) catch
        return false;
    for (regs) |reg| {
        for (reg.install_paths) |install_path| {
            const candidate = std.fs.path.join(arena, &.{
                install_path, cache_script_rel_path,
            }) catch continue;
            const expected = std.fs.cwd().readFileAlloc(arena, candidate, max_script_bytes) catch
                continue;
            if (std.mem.eql(u8, actual, expected)) return true;
        }
    }
    return false;
}

/// The symlink half of the ownership proof, pure for tests (creating real
/// symlinks needs a privilege Windows test runs may lack). Both separators:
/// a Windows-created link may spell the cache path either way.
pub fn symlinkTargetIsPluginCache(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "/plugins/cache/") != null or
        std.mem.indexOf(u8, target, "\\plugins\\cache\\") != null;
}

// -----------------------------------------------------------------------------
// Tests — the Mac migration table plus the Windows byte-proof cases, all
// against real files in tempdirs.
// -----------------------------------------------------------------------------

const testing = std.testing;

const test_script = "#!/bin/bash\necho plugin banner v0.8.0\n";

/// Registers one ghoztty install whose installPath points into the tempdir's
/// own plugin cache, and puts the script copy there.
fn writePluginFixture(tmp: *testing.TmpDir, alloc: Allocator) ![]const u8 {
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    const install_path = try std.fs.path.join(alloc, &.{
        root, ".claude", "plugins", "cache", "m", "ghoztty", "0.8.0",
    });
    try tmp.dir.makePath(".claude/plugins/cache/m/ghoztty/0.8.0/hooks");
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh",
        .data = test_script,
    });
    const escaped = try std.mem.replaceOwned(u8, alloc, install_path, "\\", "\\\\");
    const manifest = try std.fmt.allocPrint(alloc,
        \\{{"version": 2, "plugins": {{"ghoztty@m": [{{"installPath": "{s}"}}]}}}}
    , .{escaped});
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data = manifest,
    });
    return install_path;
}

const RecordingRunner = struct {
    uninstalled: std.ArrayList([]const u8) = .empty,
    alloc: Allocator,
    fail: bool = false,
    /// Simulates Claude's uninstaller clearing the cache copy: the byte
    /// proof must already have been decided by the time this runs.
    delete_cache_from: ?std.fs.Dir = null,

    fn runner(self: *RecordingRunner) Runner {
        return .{ .ctx = self, .runFn = &call };
    }

    fn call(ctx: ?*anyopaque, registration: []const u8) UninstallError!void {
        const self: *RecordingRunner = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return error.UninstallFailed;
        if (self.delete_cache_from) |dir| {
            dir.deleteFile(".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh") catch {};
        }
        try self.uninstalled.append(self.alloc, try self.alloc.dupe(u8, registration));
    }

    fn deinit(self: *RecordingRunner) void {
        for (self.uninstalled.items) |item| self.alloc.free(item);
        self.uninstalled.deinit(self.alloc);
    }
};

test "isNeeded only when the ghoztty plugin is registered" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(!try isNeeded(alloc, tmp.dir));

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try testing.expect(try isNeeded(alloc, tmp.dir));
}

test "run uninstalls every registration through the runner, then cleans up" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    // The plugin-maintained copy, byte-identical to the cache's.
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });
    // One pane's state to carry over.
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{
        .sub_path = plugin_state_sub_dir ++ "/pane-abc.json",
        .data = "{\"title\": \"t\"}",
    });

    var rec: RecordingRunner = .{ .alloc = alloc };
    defer rec.deinit();
    try run(alloc, tmp.dir, rec.runner());

    try testing.expectEqual(@as(usize, 1), rec.uninstalled.items.len);
    try testing.expectEqualStrings("ghoztty@m", rec.uninstalled.items[0]);
    // Banner state copied (originals left in place), stale script removed.
    const carried = try tmp.dir.readFileAlloc(alloc, app_state_sub_dir ++ "/pane-abc.json", 1024);
    defer alloc.free(carried);
    try testing.expectEqualStrings("{\"title\": \"t\"}", carried);
    _ = try tmp.dir.statFile(plugin_state_sub_dir ++ "/pane-abc.json");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(plugin_script_sub_path));
}

test "a failed uninstall changes nothing" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-abc.json", .data = "{}" });

    var rec: RecordingRunner = .{ .alloc = alloc, .fail = true };
    defer rec.deinit();
    try testing.expectError(error.UninstallFailed, run(alloc, tmp.dir, rec.runner()));

    // Script and state untouched; nothing migrated.
    _ = try tmp.dir.statFile(plugin_script_sub_path);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(app_state_sub_dir ++ "/pane-abc.json"));
}

test "the byte proof is decided before the uninstall clears the cache copy" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{ .sub_path = plugin_script_sub_path, .data = test_script });

    var rec: RecordingRunner = .{ .alloc = alloc, .delete_cache_from = tmp.dir };
    defer rec.deinit();
    try run(alloc, tmp.dir, rec.runner());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(plugin_script_sub_path));
}

test "a script the plugin cannot account for is the user's and stays" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try writePluginFixture(&tmp, arena_state.allocator());
    try tmp.dir.makePath(".claude/scripts");
    try tmp.dir.writeFile(.{
        .sub_path = plugin_script_sub_path,
        .data = "#!/bin/bash\necho the user's own edit\n",
    });

    var rec: RecordingRunner = .{ .alloc = alloc };
    defer rec.deinit();
    try run(alloc, tmp.dir, rec.runner());
    // Uninstalled, but the differing script survives.
    try testing.expectEqual(@as(usize, 1), rec.uninstalled.items.len);
    _ = try tmp.dir.statFile(plugin_script_sub_path);
}

test "migrateBannerState never overwrites the app's newer state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(plugin_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-a.json", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/pane-b.json", .data = "carried" });
    try tmp.dir.writeFile(.{ .sub_path = plugin_state_sub_dir ++ "/notes.txt", .data = "not state" });
    try tmp.dir.makePath(app_state_sub_dir);
    try tmp.dir.writeFile(.{ .sub_path = app_state_sub_dir ++ "/pane-a.json", .data = "newer" });

    migrateBannerState(tmp.dir);

    const alloc = testing.allocator;
    const a = try tmp.dir.readFileAlloc(alloc, app_state_sub_dir ++ "/pane-a.json", 64);
    defer alloc.free(a);
    try testing.expectEqualStrings("newer", a);
    const b = try tmp.dir.readFileAlloc(alloc, app_state_sub_dir ++ "/pane-b.json", 64);
    defer alloc.free(b);
    try testing.expectEqualStrings("carried", b);
    // Only .json state files travel.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(app_state_sub_dir ++ "/notes.txt"));
}

test "migrateBannerState with no plugin state dir is a quiet no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    migrateBannerState(tmp.dir);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(app_state_sub_dir));
}

test "symlink targets: only plugins/cache paths count, either separator" {
    try testing.expect(symlinkTargetIsPluginCache("/Users/u/.claude/plugins/cache/m/ghoztty/1.0/hooks/ghoztty-banner.sh"));
    try testing.expect(symlinkTargetIsPluginCache("C:\\Users\\u\\.claude\\plugins\\cache\\m\\ghoztty\\1.0\\hooks\\ghoztty-banner.sh"));
    try testing.expect(!symlinkTargetIsPluginCache("/Users/u/.config/ghoztty/hooks/ghoztty-banner.sh"));
    try testing.expect(!symlinkTargetIsPluginCache(""));
}

test "scriptIsPluginOwned: absent script is not ours" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(!scriptIsPluginOwned(arena_state.allocator(), tmp.dir, &.{}));
}
