//! Installs a runtime's hook automation per its ownership strategy (T868,
//! the win32 half of Mac's `HookComponent.swift`): Copilot's dedicated file
//! goes through the marker-guarded T865 writer; Claude's fragment is merged
//! into the SHARED user-owned `~/.claude/settings.json` — read, merge,
//! atomic re-write — with a typed refusal instead of a clobber whenever that
//! file is not a JSON object we can safely merge into.
//!
//! NOTE (Mac's deferred refactor H9, kept deliberately): the merged-fragment
//! branch calls the concrete `ClaudeHookSpec` functions directly rather than
//! dispatching through a spec abstraction. Both shipped runtimes work, and a
//! new dedicated-file runtime needs no changes here; only a SECOND
//! merged-fragment runtime forces generalizing this, and it does not exist
//! on either platform.
//!
//! Windows translations already decided by the earlier slices and reused
//! here: the reparse-refusing atomic writer stands in for Mac's
//! symlink-refusing `ManagedFile` (T865), and Mac's `0o600` file mode is
//! dropped because default ACLs under `%USERPROFILE%` are already owner-only.
//! One divergence of our own: a settings.json that EXISTS but cannot be READ
//! (locked, permission) is a refusal here, where Mac's `fileManager.contents`
//! returning nil would treat it as absent and let install write a fresh file
//! over it. Refusing is the T865 stance: never overwrite what you could not
//! inspect.
//!
//! Plain `std.fs` + the T865 writer, no direct OS imports, so the tempdir
//! tests run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const managed_file = @import("managed_file.zig");
const hook_scripts = @import("hook_scripts.zig");
const hook_spec = @import("hook_spec.zig");
const ClaudeHookSpec = @import("ClaudeHookSpec.zig");
const CopilotHookSpec = @import("CopilotHookSpec.zig");
const stable_json = @import("stable_json.zig");

const HookComponent = @This();

pub const InstallState = marker_mod.InstallState;

/// One-time backup of the user's original shared config, taken before the
/// FIRST Ghoztty rewrite so a future merge regression stays recoverable.
pub const settings_backup_sub_path = ClaudeHookSpec.settings_sub_path ++ ".ghoztty.bak";

/// Which runtime's hooks this component manages (Mac's `spec:` field; an
/// enum rather than a vtable per the H9 note above).
pub const Spec = enum {
    claude,
    copilot,

    pub fn ownership(self: Spec) hook_spec.HookOwnership {
        return switch (self) {
            .claude => .merged_fragment,
            .copilot => .dedicated_file,
        };
    }
};

spec: Spec,
/// The user's home directory, for file operations (a tempdir in tests).
home: std.fs.Dir,
/// The same directory as an absolute path, for composing the banner-script
/// path that gets baked into hook commands.
home_path: []const u8,

pub const Error = error{
    /// The shared config file exists but is not a JSON object we can safely
    /// merge into — invalid JSON, a valid top-level array/scalar, or a file
    /// present but unreadable. Nothing was written (Mac's
    /// `HookComponentError.unparseableConfig`).
    UnparseableConfig,
} || managed_file.WriteError || managed_file.RemoveError;

pub fn state(self: HookComponent, alloc: Allocator) InstallState {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (self.spec) {
        .copilot => {
            const expected = CopilotHookSpec.renderedFile(arena, self.bannerPath(arena) catch
                return .not_installed) catch return .not_installed;
            return managed_file.state(
                arena,
                self.home,
                CopilotHookSpec.hook_file_sub_path,
                expected,
                marker_mod.token,
            );
        },
        .claude => {
            // A present-but-unparseable shared file must NOT read as
            // not_installed — that would offer a destructive "Set up".
            // Report outdated: the action is non-destructive and install()
            // re-reads and refuses instead of clobbering the user's config.
            const base = self.readSettings(arena) catch return .outdated;
            const banner = self.bannerPath(arena) catch return .outdated;
            return ClaudeHookSpec.fragmentState(arena, base, banner) catch .outdated;
        },
    }
}

pub fn install(self: HookComponent, alloc: Allocator) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (self.spec) {
        .copilot => {
            const rendered = try CopilotHookSpec.renderedFile(arena, try self.bannerPath(arena));
            try managed_file.write(
                arena,
                self.home,
                CopilotHookSpec.hook_file_sub_path,
                rendered,
                marker_mod.token,
            );
        },
        .claude => {
            const merged = try ClaudeHookSpec.merge(
                arena,
                try self.readSettings(arena),
                try self.bannerPath(arena),
            );
            try self.writeSettings(arena, merged);
        },
    }
}

pub fn uninstall(self: HookComponent, alloc: Allocator) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (self.spec) {
        .copilot => {
            try managed_file.removeIfManaged(
                arena,
                self.home,
                CopilotHookSpec.hook_file_sub_path,
                marker_mod.token,
            );
        },
        .claude => {
            const base = try self.readSettings(arena);
            const banner = try self.bannerPath(arena);
            if (try ClaudeHookSpec.fragmentState(arena, base, banner) == .not_installed) return;
            const removed = try ClaudeHookSpec.removeFragment(arena, base, banner);
            try self.writeSettings(arena, removed);
        },
    }
}

fn bannerPath(self: HookComponent, arena: Allocator) Allocator.Error![]u8 {
    return hook_scripts.bannerPathAlloc(arena, self.home_path);
}

/// Read the shared JSON config. Returns an empty object ONLY when the file
/// is genuinely absent or empty (a first-time install correctly starts from
/// `{}` — there is no user data to lose). Present with content but not a
/// JSON object → typed refusal, NEVER a fallback to `{}`, because
/// merge+write would then replace the user's real config with only
/// Ghoztty's hooks block.
fn readSettings(self: HookComponent, arena: Allocator) error{ UnparseableConfig, OutOfMemory }!std.json.Value {
    const contents = self.home.readFileAlloc(
        arena,
        ClaudeHookSpec.settings_sub_path,
        managed_file.max_managed_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = std.json.ObjectMap.init(arena) },
        error.OutOfMemory => return error.OutOfMemory,
        // Present but unreadable or over-cap: refuse (see module doc).
        else => return error.UnparseableConfig,
    };
    if (contents.len == 0) return .{ .object = std.json.ObjectMap.init(arena) };

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, contents, .{}) catch
        return error.UnparseableConfig;
    return switch (root) {
        .object => root,
        else => error.UnparseableConfig,
    };
}

/// Serialize deterministically and land atomically. The one-time backup and
/// the reparse-refusing writer are what make a merge regression recoverable
/// and a dotfiles symlink safe, respectively.
fn writeSettings(self: HookComponent, arena: Allocator, root: std.json.Value) Error!void {
    const text = try stable_json.prettyAlloc(arena, root);

    // One-time safety net, best-effort like Mac's `try?`: its absence must
    // not block the install the user asked for.
    if (self.home.statFile(ClaudeHookSpec.settings_sub_path)) |_| {
        if (self.home.statFile(settings_backup_sub_path)) |_| {} else |_| {
            self.home.copyFile(
                ClaudeHookSpec.settings_sub_path,
                self.home,
                settings_backup_sub_path,
                .{},
            ) catch {};
        }
    } else |_| {}

    // No marker requirement — settings.json is user-owned and unmarked —
    // but the same dotfiles-safety and atomicity as our own files.
    try managed_file.writeAtomicNoFollow(
        arena,
        self.home,
        ClaudeHookSpec.settings_sub_path,
        text,
    );
}

// -----------------------------------------------------------------------------
// Tests — mirroring Mac's HookComponentTests.
// -----------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

/// Any absolute-looking home spelling works: the path only feeds command
/// strings, while file ops go through the tempdir handle.
const test_home_path = "C:\\Users\\tester";

fn readFile(alloc: Allocator, dir: std.fs.Dir, sub_path: []const u8) ![]u8 {
    return dir.readFileAlloc(alloc, sub_path, managed_file.max_managed_bytes);
}

fn parseFile(arena: Allocator, dir: std.fs.Dir, sub_path: []const u8) !std.json.Value {
    const text = try readFile(arena, dir, sub_path);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "copilot dedicated-file lifecycle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: HookComponent = .{ .spec = .copilot, .home = tmp.dir, .home_path = test_home_path };

    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
    _ = try tmp.dir.statFile(CopilotHookSpec.hook_file_sub_path);

    // The file on disk is the deterministic rendering, marker included.
    const got = try readFile(alloc, tmp.dir, CopilotHookSpec.hook_file_sub_path);
    const banner = try hook_scripts.bannerPathAlloc(alloc, test_home_path);
    try testing.expectEqualStrings(try CopilotHookSpec.renderedFile(alloc, banner), got);

    try c.uninstall(alloc);
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
}

test "claude merged fragment preserves user keys through install and uninstall" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{ .sub_path = ClaudeHookSpec.settings_sub_path, .data = "{\"theme\":\"dark\"}" });
    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };

    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
    {
        const root = try parseFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
        try testing.expectEqualStrings("dark", root.object.get("theme").?.string);
        try testing.expect(root.object.get("hooks") != null);
    }

    try c.uninstall(alloc);
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
    {
        const root = try parseFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
        try testing.expectEqualStrings("dark", root.object.get("theme").?.string);
        try testing.expect(root.object.get("hooks") == null);
    }
}

test "claude merge preserves pre-existing user hooks on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{
        .sub_path = ClaudeHookSpec.settings_sub_path,
        .data = "{\"theme\":\"dark\",\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo mine\"}]}]}}",
    });
    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };

    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
    {
        const text = try readFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
        try testing.expect(std.mem.indexOf(u8, text, "echo mine") != null);
        const hooks = (try parseFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path)).object.get("hooks").?.object;
        try testing.expect(hooks.get("SessionStart") != null);
        try testing.expect(hooks.get("UserPromptSubmit") != null);
        try testing.expect(hooks.get("Stop") != null);
    }

    try c.uninstall(alloc);
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
    {
        const root = try parseFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
        try testing.expectEqualStrings("dark", root.object.get("theme").?.string);
        const hooks = root.object.get("hooks").?.object;
        const pretool = try stable_json.compactAlloc(alloc, hooks.get("PreToolUse").?);
        try testing.expect(std.mem.indexOf(u8, pretool, "echo mine") != null);
        try testing.expect(hooks.get("SessionStart") == null);
        try testing.expect(hooks.get("Stop") == null);
    }
}

test "unparseable settings.json: state outdated, install refused, bytes untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "{\"theme\":\"dark\", \"oops\": ,}";
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{ .sub_path = ClaudeHookSpec.settings_sub_path, .data = original });
    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };

    try testing.expectEqual(InstallState.outdated, c.state(alloc));
    try testing.expectError(error.UnparseableConfig, c.install(alloc));
    const after = try readFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
    try testing.expectEqualStrings(original, after);
    // The refusal also never took a backup: nothing was about to be rewritten.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(settings_backup_sub_path));
}

test "top-level array settings.json is refused, not replaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{ .sub_path = ClaudeHookSpec.settings_sub_path, .data = "[1,2,3]" });
    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };

    try testing.expectEqual(InstallState.outdated, c.state(alloc));
    try testing.expectError(error.UnparseableConfig, c.install(alloc));
    const after = try readFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
    try testing.expectEqualStrings("[1,2,3]", after);
}

test "absent and empty settings.json both install cleanly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Absent: no .claude directory at all.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };
        try testing.expectEqual(InstallState.not_installed, c.state(alloc));
        try c.install(alloc);
        try testing.expectEqual(InstallState.installed, c.state(alloc));
    }
    // Present but zero bytes.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makePath(".claude");
        try tmp.dir.writeFile(.{ .sub_path = ClaudeHookSpec.settings_sub_path, .data = "" });
        const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };
        try c.install(alloc);
        try testing.expectEqual(InstallState.installed, c.state(alloc));
    }
}

test "first rewrite backs up the original once; later rewrites never touch it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "{\"theme\":\"dark\"}";
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{ .sub_path = ClaudeHookSpec.settings_sub_path, .data = original });
    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };

    try c.install(alloc);
    {
        const backup = try readFile(alloc, tmp.dir, settings_backup_sub_path);
        try testing.expectEqualStrings(original, backup);
    }

    // Uninstall rewrites the file again — the backup must keep the ORIGINAL
    // bytes, not the merged intermediate.
    try c.uninstall(alloc);
    try c.install(alloc);
    {
        const backup = try readFile(alloc, tmp.dir, settings_backup_sub_path);
        try testing.expectEqualStrings(original, backup);
    }
}

test "installing twice is byte-stable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".claude");
    try tmp.dir.writeFile(.{
        .sub_path = ClaudeHookSpec.settings_sub_path,
        .data = "{\"zeta\":true,\"alpha\":{\"b\":2,\"a\":1}}",
    });
    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };

    try c.install(alloc);
    const first = try readFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
    try c.install(alloc);
    const second = try readFile(alloc, tmp.dir, ClaudeHookSpec.settings_sub_path);
    try testing.expectEqualStrings(first, second);
}

test "a symlinked settings.json is refused, target untouched (where privilege allows)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Real settings live outside (a "dotfiles repo"); settings.json links to it.
    try tmp.dir.makePath("dotfiles");
    try tmp.dir.writeFile(.{ .sub_path = "dotfiles/settings.json", .data = "{\"theme\":\"dark\"}" });
    try tmp.dir.makePath(".claude");
    tmp.dir.symLink("../dotfiles/settings.json", ClaudeHookSpec.settings_sub_path, .{}) catch |err| switch (err) {
        // No symlink privilege / developer mode on this box: managed_file's
        // junction test still covers the reparse refusal itself.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const c: HookComponent = .{ .spec = .claude, .home = tmp.dir, .home_path = test_home_path };
    try testing.expectError(error.ReparsePointRefused, c.install(alloc));
    const real = try readFile(alloc, tmp.dir, "dotfiles/settings.json");
    try testing.expectEqualStrings("{\"theme\":\"dark\"}", real);
}
