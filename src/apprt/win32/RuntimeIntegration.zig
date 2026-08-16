//! One runtime's Ghoztty integration as a single switch: install everything
//! or cleanly undo what the failed attempt created, uninstall in reverse,
//! and aggregate the component states into one answer (T869, the win32 half
//! of Mac's `RuntimeIntegration.swift` + `RuntimeIntegrationFactory.swift`).
//!
//! The factory functions live in this same module rather than a separate
//! file (where Mac keeps them) because the refcounted banner uninstall needs
//! the factory's hooks-scan and the factory builds this module's components
//! — one file avoids the mutual import Mac's closures never had to face.
//! The service layer (`agent_integration_service.zig`) stays separate.
//!
//! Components sit in a FIXED order — banner script, skills, hooks — and the
//! hooks MUST remain last: the shared banner's uninstall is refcounted (it
//! removes the scripts only when NO agent's hooks still reference them), and
//! that is correct-by-construction only because both `uninstall()` and the
//! `install()` rollback process components in reverse, so THIS agent's hooks
//! are always gone (or were never written) before the banner closure scans —
//! the scan therefore sees only siblings.
//!
//! Rollback removes ONLY what the failing call created. A component that was
//! already installed before we started is left alone: its `install()` was an
//! idempotent rewrite of a file the user already had, so "undoing" it means
//! deleting something this call never created. Without that distinction a
//! failure in the LAST component wipes the earlier ones on every retry —
//! Mac's measured regression: hooks file externally replaced, "Set Up"
//! offered again, banner and skills rewrite fine, hooks throws, and the
//! rollback deletes the working skills and the shared banner. `.outdated`
//! counts as pre-existing too: the file is the user's, we merely refreshed
//! it, and leaving a newer version behind beats deleting it outright.
//!
//! Plain `std.fs` + the earlier slices' components, no direct OS imports, so
//! the tempdir tests run in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
const runtime_agent = @import("runtime_agent.zig");
const runtime_probe = @import("runtime_probe.zig");
const claude_plugin_manifest = @import("claude_plugin_manifest.zig");
const BannerScriptInstaller = @import("BannerScriptInstaller.zig");
const SkillComponent = @import("SkillComponent.zig");
const HookComponent = @import("HookComponent.zig");

const log = std.log.scoped(.win32_agent_integration);

const RuntimeIntegration = @This();

pub const RuntimeAgent = runtime_agent.RuntimeAgent;
pub const RuntimeProbe = runtime_probe.RuntimeProbe;
pub const InstallState = marker_mod.InstallState;

pub const banner_component_name = "banner-script";
pub const skills_component_name = "skills";
pub const hooks_component_name = "hooks";

/// Banner + skills + hooks is the whole roster.
const max_components = 3;

/// The shared banner scripts plus what their refcounted uninstall needs to
/// scan every agent's hooks state (Mac's `bannerUninstall` closure).
pub const RefcountedBanner = struct {
    installer: BannerScriptInstaller,
    home: std.fs.Dir,
    home_path: []const u8,
};

/// One installable piece of an integration. A tagged union over the real
/// components rather than Mac's struct-of-closures: the components all
/// operate on a `std.fs.Dir`, so even the rollback and refcount tests run
/// against real files in tempdirs and no fake seam is needed.
pub const Component = union(enum) {
    banner: RefcountedBanner,
    skills: SkillComponent,
    hooks: HookComponent,

    /// Superset of every component's install/uninstall errors.
    pub const Error = HookComponent.Error || Allocator.Error;

    pub fn name(self: Component) []const u8 {
        return switch (self) {
            .banner => banner_component_name,
            .skills => skills_component_name,
            .hooks => hooks_component_name,
        };
    }

    pub fn state(self: Component, alloc: Allocator) InstallState {
        return switch (self) {
            .banner => |b| b.installer.state(alloc),
            .skills => |s| s.state(alloc),
            .hooks => |h| h.state(alloc),
        };
    }

    pub fn install(self: Component, alloc: Allocator) Error!void {
        return switch (self) {
            .banner => |b| b.installer.install(alloc),
            .skills => |s| s.install(alloc),
            .hooks => |h| h.install(alloc),
        };
    }

    /// The banner's uninstall is a no-op while ANY agent's Ghoztty hooks
    /// still reference the shared scripts (see the module doc for why the
    /// scan only ever sees siblings). An OOM during the scan reads as
    /// "referenced" via the error path: propagate rather than delete what
    /// could not be checked.
    pub fn uninstall(self: Component, alloc: Allocator) Error!void {
        switch (self) {
            .banner => |b| {
                if (try anyHooksReferenceBanner(alloc, b.home, b.home_path, null)) return;
                try b.installer.uninstall(alloc);
            },
            .skills => |s| try s.uninstall(alloc),
            .hooks => |h| try h.uninstall(alloc),
        }
    }
};

/// The runtime this integration registers Ghoztty with.
agent: RuntimeAgent,
/// The user's home directory (a tempdir in tests).
home: std.fs.Dir,
/// The same directory as an absolute path, for the banner path baked into
/// generated hook commands.
home_path: []const u8,
/// Whether the runtime's CLI is installed at all. A detection signal, NOT
/// the config dir this writes into — see `runtime_probe`. Components create
/// whatever directories they need, so a CLI that is installed but has never
/// been run still installs cleanly.
probe: RuntimeProbe,

component_buf: [max_components]Component,
component_len: usize,

pub fn components(self: *const RuntimeIntegration) []const Component {
    return self.component_buf[0..self.component_len];
}

/// Aggregate install state: any component missing → not_installed; any
/// merely stale → outdated; else installed.
pub fn state(self: *const RuntimeIntegration, alloc: Allocator) InstallState {
    var saw_outdated = false;
    for (self.components()) |c| {
        switch (c.state(alloc)) {
            .not_installed => return .not_installed,
            .outdated => saw_outdated = true,
            .installed => {},
        }
    }
    return if (saw_outdated) .outdated else .installed;
}

pub const InstallError = error{
    /// The runtime's CLI is not installed on this box; nothing was written
    /// (Mac's `AgentIntegrationError.notInstalled`).
    NotInstalled,
} || Component.Error;

/// Install every component in order, or roll back the ones THIS call
/// created (in reverse) and return the original error. See the module doc
/// for why pre-existing components are never rolled back.
pub fn install(self: *const RuntimeIntegration, alloc: Allocator) InstallError!void {
    if (!self.probe.isInstalled(alloc, self.agent)) return error.NotInstalled;

    const comps = self.components();
    var created = [_]bool{false} ** max_components;
    for (comps, 0..) |c, i| {
        const existed_before = c.state(alloc) != .not_installed;
        c.install(alloc) catch |err| {
            var j = i;
            while (j > 0) {
                j -= 1;
                if (!created[j]) continue;
                comps[j].uninstall(alloc) catch |uerr| log.debug(
                    "rollback of {s}/{s} failed: {s}",
                    .{ @tagName(self.agent), comps[j].name(), @errorName(uerr) },
                );
            }
            return err;
        };
        created[i] = !existed_before;
    }
}

/// Uninstall in reverse order, best-effort: every component gets its chance,
/// and the FIRST error is rethrown at the end (Mac's contract).
pub fn uninstall(self: *const RuntimeIntegration, alloc: Allocator) Component.Error!void {
    const comps = self.components();
    var first_err: ?Component.Error = null;
    var i = comps.len;
    while (i > 0) {
        i -= 1;
        comps[i].uninstall(alloc) catch |err| {
            log.debug("uninstall of {s}/{s} failed: {s}", .{
                @tagName(self.agent), comps[i].name(), @errorName(err),
            });
            if (first_err == null) first_err = err;
        };
    }
    if (first_err) |err| return err;
}

// -----------------------------------------------------------------------------
// Factory (Mac's RuntimeIntegrationFactory)
// -----------------------------------------------------------------------------

/// Does an external plugin already own this runtime? Only Claude has one.
///
/// The single gate for BOTH components Ghoztty would otherwise write into
/// the runtime's config dir. Gating only the hooks would leave the app's
/// skill sitting beside the plugin's own copy of the same skill: the two
/// differ, and the app's points the agent at our hooks directory while the
/// plugin's keeps state under its own path, so the split-state failure the
/// hooks gate prevents is simply reached through the skill instead.
pub fn isPluginManaged(alloc: Allocator, agent: RuntimeAgent, home: std.fs.Dir) Allocator.Error!bool {
    if (agent != .claude) return false;
    return claude_plugin_manifest.isExternalPluginInstalled(alloc, home);
}

/// The agent's hooks component, or null when Ghoztty must NOT own the hooks
/// (Claude's external plugin already does). Extracted so the shared-banner
/// refcount can inspect every agent's hooks state through one path.
pub fn hooksComponentFor(
    alloc: Allocator,
    agent: RuntimeAgent,
    home: std.fs.Dir,
    home_path: []const u8,
) Allocator.Error!?HookComponent {
    if (try isPluginManaged(alloc, agent, home)) return null;
    return .{ .spec = specFor(agent), .home = home, .home_path = home_path };
}

/// The agent's skills component, or null when the external plugin owns them.
/// Same gate as the hooks, for the reason spelled out on `isPluginManaged`.
pub fn skillsComponentFor(
    alloc: Allocator,
    agent: RuntimeAgent,
    home: std.fs.Dir,
) Allocator.Error!?SkillComponent {
    if (try isPluginManaged(alloc, agent, home)) return null;
    return .{ .agent = agent, .home = home };
}

fn specFor(agent: RuntimeAgent) HookComponent.Spec {
    return switch (agent) {
        .claude => .claude,
        .copilot => .copilot,
    };
}

/// Refcount for the SHARED banner scripts: true when ANY agent's hooks
/// component still references them. Ghoztty-owned hooks are the only thing
/// that invokes the banner, so when none are present it is safe to remove. A
/// plugin-managed Claude has no Ghoztty hooks component (null) and correctly
/// contributes nothing — its external plugin ships its own banner path. Pass
/// `excluding` to ask "would the banner survive uninstalling that agent?"
/// (i.e. does any OTHER agent's hooks still reference it).
pub fn anyHooksReferenceBanner(
    alloc: Allocator,
    home: std.fs.Dir,
    home_path: []const u8,
    excluding: ?RuntimeAgent,
) Allocator.Error!bool {
    inline for (std.meta.tags(RuntimeAgent)) |agent| {
        const skip = if (excluding) |ex| ex == agent else false;
        if (!skip) {
            if (try hooksComponentFor(alloc, agent, home, home_path)) |hooks| {
                if (hooks.state(alloc) != .not_installed) return true;
            }
        }
    }
    return false;
}

/// Which runtimes are installed, by probing for their BINARY (never the
/// config dir — see `runtime_probe`).
pub fn availableAgents(alloc: Allocator, probe: RuntimeProbe) std.EnumSet(RuntimeAgent) {
    var set = std.EnumSet(RuntimeAgent).initEmpty();
    inline for (std.meta.tags(RuntimeAgent)) |agent| {
        if (probe.isInstalled(alloc, agent)) set.insert(agent);
    }
    return set;
}

pub fn make(
    alloc: Allocator,
    agent: RuntimeAgent,
    home: std.fs.Dir,
    home_path: []const u8,
    probe: RuntimeProbe,
) Allocator.Error!RuntimeIntegration {
    var self: RuntimeIntegration = .{
        .agent = agent,
        .home = home,
        .home_path = home_path,
        .probe = probe,
        .component_buf = undefined,
        .component_len = 0,
    };
    self.component_buf[0] = .{ .banner = .{
        .installer = .{ .home = home },
        .home = home,
        .home_path = home_path,
    } };
    self.component_len = 1;
    if (try skillsComponentFor(alloc, agent, home)) |skills| {
        self.component_buf[self.component_len] = .{ .skills = skills };
        self.component_len += 1;
    }
    // MUST remain last: the banner refcount relies on hooks being ordered
    // after the banner so reverse-order processing removes them first.
    if (try hooksComponentFor(alloc, agent, home, home_path)) |hooks| {
        self.component_buf[self.component_len] = .{ .hooks = hooks };
        self.component_len += 1;
    }
    return self;
}

// -----------------------------------------------------------------------------
// Tests — mirroring Mac's RuntimeIntegrationTests/FactoryTests plus the T869
// validation criteria. All against the REAL components in tempdirs.
// -----------------------------------------------------------------------------

const testing = std.testing;
const hook_scripts = @import("hook_scripts.zig");
const CopilotHookSpec = @import("CopilotHookSpec.zig");
const ClaudeHookSpec = @import("ClaudeHookSpec.zig");
const managed_file = @import("managed_file.zig");

const test_home_path = "C:\\Users\\tester";
const all_probe = RuntimeProbe.stubOf(&.{ .claude, .copilot });

fn writePluginManifest(tmp: *testing.TmpDir) !void {
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{
        .sub_path = claude_plugin_manifest.manifest_sub_path,
        .data =
        \\{"version": 2, "plugins": {"ghoztty@dzearing-claude-marketplace": [{}]}}
        ,
    });
}

test "make: fixed component order banner, skills, hooks — hooks last" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    const comps = integ.components();
    try testing.expectEqual(@as(usize, 3), comps.len);
    try testing.expectEqualStrings(banner_component_name, comps[0].name());
    try testing.expectEqualStrings(skills_component_name, comps[1].name());
    try testing.expectEqualStrings(hooks_component_name, comps[2].name());
}

test "install on an unavailable runtime is a typed refusal, nothing written" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, RuntimeProbe.stubOf(&.{}));
    try testing.expectError(error.NotInstalled, integ.install(alloc));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
}

test "fresh install lands all three components and aggregate reads installed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try testing.expectEqual(InstallState.not_installed, integ.state(alloc));
    try integ.install(alloc);

    _ = try tmp.dir.statFile(hook_scripts.banner_sub_path);
    _ = try tmp.dir.statFile(hook_scripts.activity_state_sub_path);
    _ = try tmp.dir.statFile(".copilot/skills/ghoztty/SKILL.md");
    _ = try tmp.dir.statFile(CopilotHookSpec.hook_file_sub_path);
    try testing.expectEqual(InstallState.installed, integ.state(alloc));
}

test "failing last component rolls back only what this call created" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The user's own unmarked file where the hooks component writes.
    const users_own = "{\"mine\": true}";
    try tmp.dir.makePath(".copilot/hooks");
    try tmp.dir.writeFile(.{ .sub_path = CopilotHookSpec.hook_file_sub_path, .data = users_own });

    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try testing.expectError(error.NotManaged, integ.install(alloc));

    // Banner and skills were created by the failing call → rolled back.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".copilot/skills/ghoztty/SKILL.md"));
    // The user's file survives byte-identical.
    const after = try tmp.dir.readFileAlloc(alloc, CopilotHookSpec.hook_file_sub_path, managed_file.max_managed_bytes);
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
}

test "retry after external hook corruption never deletes the working components" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Fully installed…
    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try integ.install(alloc);
    // …then something replaces the hooks file with an unmarked one (the Mac
    // regression case: "Set Up" is offered again).
    try tmp.dir.deleteFile(CopilotHookSpec.hook_file_sub_path);
    try tmp.dir.writeFile(.{ .sub_path = CopilotHookSpec.hook_file_sub_path, .data = "{}" });
    try testing.expectEqual(InstallState.not_installed, integ.state(alloc));

    try testing.expectError(error.NotManaged, integ.install(alloc));

    // Banner and skills existed before the retry: they MUST survive it.
    _ = try tmp.dir.statFile(hook_scripts.banner_sub_path);
    _ = try tmp.dir.statFile(".copilot/skills/ghoztty/SKILL.md");
    _ = try tmp.dir.statFile(".copilot/skills/process-feedback/SKILL.md");
}

test "uninstalling one agent leaves the shared scripts while the other references them" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const claude = try make(alloc, .claude, tmp.dir, test_home_path, all_probe);
    const copilot = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try claude.install(alloc);
    try copilot.install(alloc);

    try copilot.uninstall(alloc);
    // Copilot's own artifacts are gone…
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(CopilotHookSpec.hook_file_sub_path));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".copilot/skills/ghoztty/SKILL.md"));
    // …but the shared banner survives: Claude's hooks still reference it.
    _ = try tmp.dir.statFile(hook_scripts.banner_sub_path);
    try testing.expect(try anyHooksReferenceBanner(alloc, tmp.dir, test_home_path, null));

    // Uninstalling the LAST referencing agent removes the shared scripts.
    try claude.uninstall(alloc);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.activity_state_sub_path));
}

test "plugin-managed claude gets only the banner component" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginManifest(&tmp);

    const integ = try make(alloc, .claude, tmp.dir, test_home_path, all_probe);
    try testing.expectEqual(@as(usize, 1), integ.components().len);
    try testing.expectEqualStrings(banner_component_name, integ.components()[0].name());

    try integ.install(alloc);
    // Neither skills nor a settings.json fragment were written.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(".claude/skills/ghoztty/SKILL.md"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(ClaudeHookSpec.settings_sub_path));
    // Copilot is unaffected by Claude's plugin.
    const copilot = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try testing.expectEqual(@as(usize, 3), copilot.components().len);
}

test "plugin-managed claude contributes nothing to the banner refcount" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginManifest(&tmp);

    const copilot = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try copilot.install(alloc);
    try copilot.uninstall(alloc);
    // No Ghoztty-owned hooks anywhere → the shared scripts go too, even
    // though a plugin-managed Claude "exists".
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
}

test "aggregate state: a missing component reads not_installed, a stale one outdated" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try integ.install(alloc);
    try testing.expectEqual(InstallState.installed, integ.state(alloc));

    // Still ours (marked) but stale → outdated.
    try tmp.dir.writeFile(.{
        .sub_path = hook_scripts.banner_sub_path,
        .data = "#!/bin/sh\n" ++ marker_mod.shell_comment ++ "\necho old version\n",
    });
    try testing.expectEqual(InstallState.outdated, integ.state(alloc));

    // A component gone entirely → not_installed (actionable "Set Up").
    try tmp.dir.deleteFile(CopilotHookSpec.hook_file_sub_path);
    try testing.expectEqual(InstallState.not_installed, integ.state(alloc));
}

test "uninstall is best-effort: later components still run, first error rethrown" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const integ = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try integ.install(alloc);
    // The user replaced a skill file with their own: that uninstall step
    // refuses, but hooks (before it) and banner (after it) still process.
    try tmp.dir.deleteFile(".copilot/skills/ghoztty/SKILL.md");
    try tmp.dir.writeFile(.{ .sub_path = ".copilot/skills/ghoztty/SKILL.md", .data = "# mine\n" });

    try testing.expectError(error.NotManaged, integ.uninstall(alloc));

    try testing.expectError(error.FileNotFound, tmp.dir.statFile(CopilotHookSpec.hook_file_sub_path));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(hook_scripts.banner_sub_path));
    // The user's file is untouched.
    const after = try tmp.dir.readFileAlloc(alloc, ".copilot/skills/ghoztty/SKILL.md", managed_file.max_managed_bytes);
    defer alloc.free(after);
    try testing.expectEqualStrings("# mine\n", after);
}

test "anyHooksReferenceBanner: excluding asks about the siblings only" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const copilot = try make(alloc, .copilot, tmp.dir, test_home_path, all_probe);
    try copilot.install(alloc);

    // Only copilot references the banner: excluding copilot → nobody else.
    try testing.expect(try anyHooksReferenceBanner(alloc, tmp.dir, test_home_path, null));
    try testing.expect(!try anyHooksReferenceBanner(alloc, tmp.dir, test_home_path, .copilot));
    try testing.expect(try anyHooksReferenceBanner(alloc, tmp.dir, test_home_path, .claude));
}

test "availableAgents filters by the probe" {
    const alloc = testing.allocator;
    const set = availableAgents(alloc, RuntimeProbe.stubOf(&.{.claude}));
    try testing.expect(set.contains(.claude));
    try testing.expect(!set.contains(.copilot));
}
