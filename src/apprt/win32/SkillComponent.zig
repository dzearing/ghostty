//! Installs the bundled `ghoztty` and `process-feedback` skills into a
//! runtime's `skills/` directory (T867, the win32 half of Mac's
//! `SkillComponent`). Portable across runtimes: only the config dir differs.
//!
//! Every write goes through the marker-guarded atomic writer, so a user's
//! own `SKILL.md` at one of our paths is refused and survives byte-identical.
//! All skills are rendered before any is written (a missing asset fails
//! before the first write — comptime-embedded here, so only OOM remains),
//! and a partial failure rolls back IN REVERSE ORDER the files this call
//! CREATED — one deliberate improvement over Mac, whose rollback removes
//! everything it wrote and thereby deletes a skill that was already
//! installed before the failing upgrade began.
//!
//! Plain `std.fs` + the T865 writer, no direct OS imports, so the tempdir
//! tests run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const managed_file = @import("managed_file.zig");
const GhosttyAssets = @import("GhosttyAssets.zig");
const runtime_agent = @import("runtime_agent.zig");

const SkillComponent = @This();

pub const RuntimeAgent = runtime_agent.RuntimeAgent;
pub const InstallState = marker_mod.InstallState;
pub const marker = marker_mod.html_comment;
pub const skill_names = GhosttyAssets.skill_names;

/// The runtime whose config dir receives the skills.
agent: RuntimeAgent,
/// The user's home directory (a tempdir in tests).
home: std.fs.Dir,

/// Home-relative `SKILL.md` path for one skill.
fn skillSubPath(self: SkillComponent, alloc: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/skills/{s}/SKILL.md", .{
        self.agent.configDirectoryName(), name,
    });
}

/// The exact bytes an installed skill must hold: the bundled markdown plus
/// the ownership marker line. Byte-identical to Mac's composition
/// (`asset + "\n" + marker + "\n"`), so the two platforms' installs agree on
/// what "current" means.
fn expectedText(alloc: Allocator, name: []const u8) (Allocator.Error || GhosttyAssets.Error)![]u8 {
    const body = try GhosttyAssets.skillMarkdown(name);
    return std.mem.concat(alloc, u8, &.{ body, "\n", marker, "\n" });
}

/// Aggregate install state: all installed → installed; all absent →
/// not_installed; any mix → outdated (actionable). An allocation failure
/// reads as outdated — the safe, actionable answer.
pub fn state(self: SkillComponent, alloc: Allocator) InstallState {
    var saw_installed = false;
    var saw_missing = false;
    var saw_outdated = false;
    inline for (skill_names) |name| {
        const one = self.skillState(alloc, name) catch .outdated;
        switch (one) {
            .installed => saw_installed = true,
            .not_installed => saw_missing = true,
            .outdated => saw_outdated = true,
        }
    }
    if (saw_outdated or (saw_installed and saw_missing)) return .outdated;
    return if (saw_installed) .installed else .not_installed;
}

fn skillState(self: SkillComponent, alloc: Allocator, name: []const u8) Allocator.Error!InstallState {
    const sub = try self.skillSubPath(alloc, name);
    defer alloc.free(sub);
    const want = expectedText(alloc, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownAsset => unreachable, // names come from skill_names
    };
    defer alloc.free(want);
    return managed_file.state(alloc, self.home, sub, want, marker);
}

pub const InstallError = managed_file.WriteError;

/// Install every skill, or nothing: on a partial failure the files THIS call
/// created are removed again in reverse order (see module doc), and the
/// original error is returned. A skill that already existed managed keeps
/// the freshly written content — it stays ours and a retry converges it.
pub fn install(self: SkillComponent, alloc: Allocator) InstallError!void {
    const n = skill_names.len;

    // Render all up front so any failure lands before the first write.
    var subs: [n][]u8 = undefined;
    var bodies: [n][]u8 = undefined;
    var rendered: usize = 0;
    defer for (0..rendered) |i| {
        alloc.free(subs[i]);
        alloc.free(bodies[i]);
    };
    inline for (skill_names, 0..) |name, i| {
        subs[i] = try self.skillSubPath(alloc, name);
        errdefer alloc.free(subs[i]);
        bodies[i] = expectedText(alloc, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownAsset => unreachable, // names come from skill_names
        };
        rendered = i + 1;
    }

    var created: [n]bool = .{false} ** n;
    for (0..n) |i| {
        // Absent before the write (an unmarked file would fail the write, so
        // a successful write from .not_installed means we created the file).
        const pre = managed_file.state(alloc, self.home, subs[i], bodies[i], marker);
        managed_file.write(alloc, self.home, subs[i], bodies[i], marker) catch |err| {
            var j = i;
            while (j > 0) {
                j -= 1;
                if (created[j])
                    managed_file.removeIfManaged(alloc, self.home, subs[j], marker) catch {};
            }
            return err;
        };
        created[i] = pre == .not_installed;
    }
}

pub const UninstallError = managed_file.RemoveError || Allocator.Error;

/// Remove every managed skill file; a user's own file at one of the paths is
/// a typed refusal and stops the pass (nothing of theirs is touched).
pub fn uninstall(self: SkillComponent, alloc: Allocator) UninstallError!void {
    inline for (skill_names) |name| {
        const sub = try self.skillSubPath(alloc, name);
        defer alloc.free(sub);
        try managed_file.removeIfManaged(alloc, self.home, sub, marker);
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn testComponent(tmp: *testing.TmpDir) SkillComponent {
    return .{ .agent = .claude, .home = tmp.dir };
}

test "fresh install writes both skills marker-stamped and reports installed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));

    inline for (skill_names) |name| {
        const got = try tmp.dir.readFileAlloc(
            alloc,
            ".claude/skills/" ++ name ++ "/SKILL.md",
            managed_file.max_managed_bytes,
        );
        defer alloc.free(got);
        try testing.expect(std.mem.indexOf(u8, got, marker) != null);
        try testing.expect(std.mem.endsWith(u8, got, "\n" ++ marker ++ "\n"));
    }
}

test "copilot component installs under .copilot, not .claude" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: SkillComponent = .{ .agent = .copilot, .home = tmp.dir };

    try c.install(alloc);
    _ = try tmp.dir.statFile(".copilot/skills/ghoztty/SKILL.md");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
}

test "hand-edited but still-marked skill reports outdated; reinstall converges" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/skills/ghoztty/SKILL.md",
        .data = "# tweaked by hand\n" ++ marker ++ "\n",
    });
    try testing.expectEqual(InstallState.outdated, c.state(alloc));

    try c.install(alloc);
    try testing.expectEqual(InstallState.installed, c.state(alloc));
}

test "a user's own unmarked SKILL.md refuses install and survives byte-identical" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    const users_own = "# my very own skill\n";
    try tmp.dir.makePath(".claude/skills/ghoztty");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/ghoztty/SKILL.md", .data = users_own });

    try testing.expectError(error.NotManaged, c.install(alloc));

    const after = try tmp.dir.readFileAlloc(
        alloc,
        ".claude/skills/ghoztty/SKILL.md",
        managed_file.max_managed_bytes,
    );
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
    // A mix of "user file blocks one skill" and "nothing of ours installed"
    // must read as not_installed, never installed.
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));
}

test "failure on the second skill rolls back the first" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    // User's own file at the SECOND install path (skill_names order).
    const users_own = "# mine, hands off\n";
    try tmp.dir.makePath(".claude/skills/process-feedback");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/process-feedback/SKILL.md", .data = users_own });

    try testing.expectError(error.NotManaged, c.install(alloc));

    // The first skill was created by the failing call, so it was removed.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
    const after = try tmp.dir.readFileAlloc(
        alloc,
        ".claude/skills/process-feedback/SKILL.md",
        managed_file.max_managed_bytes,
    );
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
}

test "rollback never removes a skill that was installed before the call" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    // First skill installed by an earlier, successful run…
    try c.install(alloc);
    // …then the second skill's file is replaced by the user's own.
    try tmp.dir.deleteFile(".claude/skills/process-feedback/SKILL.md");
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/skills/process-feedback/SKILL.md",
        .data = "# mine now\n",
    });

    try testing.expectError(error.NotManaged, c.install(alloc));

    // The pre-existing managed skill must survive the rollback.
    const got = try tmp.dir.readFileAlloc(
        alloc,
        ".claude/skills/ghoztty/SKILL.md",
        managed_file.max_managed_bytes,
    );
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, marker) != null);
}

test "uninstall removes exactly the marked files and leaves user files" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    // A user file elsewhere in the skills tree is untouched by uninstall.
    try tmp.dir.makePath(".claude/skills/my-skill");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/my-skill/SKILL.md", .data = "# mine\n" });

    try c.uninstall(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/process-feedback/SKILL.md"));
    _ = try tmp.dir.statFile(".claude/skills/my-skill/SKILL.md");
    try testing.expectEqual(InstallState.not_installed, c.state(alloc));

    // Uninstalling again over nothing is a no-op, not an error.
    try c.uninstall(alloc);
}

test "state aggregation: one installed + one absent reads outdated" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = testComponent(&tmp);

    try c.install(alloc);
    try tmp.dir.deleteFile(".claude/skills/process-feedback/SKILL.md");
    try testing.expectEqual(InstallState.outdated, c.state(alloc));
}
