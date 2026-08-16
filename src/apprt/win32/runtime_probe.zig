//! Whether a coding-agent runtime's CLI is actually installed (T869, the
//! win32 half of Mac's `RuntimeProbe`).
//!
//! Deliberately NOT "does its config dir exist". Ghoztty WRITES into that
//! dir (`skills/`, and for Copilot `hooks/`), so keying detection on it
//! means our own leftovers go on reporting a CLI the user has since
//! removed, and a freshly installed CLI that has not been run yet reports
//! absent. Detection is the BINARY, exactly like Mac.
//!
//! Windows translation (decided in T869): NO login-shell spawn. Mac probes
//! through `zsh -lic 'command -v …'` because a Mac GUI app's PATH is not the
//! terminal's; on Windows the process environment plus a handful of
//! well-known install dirs IS the answer, so the probe reads `PATH` directly
//! and walks the same fallback locations `AgentIntegration.findClaude` was
//! measured against on this box (claude.exe at `~\.local\bin\` 2026-08-15).
//!
//! The seam is a tagged union rather than Mac's struct-of-closures — Zig has
//! no capturing closures, and `stub` gives tests the same "exactly these
//! agents are installed" hermeticity with no process or filesystem touched.
//! The real probe's path walk is itself testable through `ProbeEnv`, which
//! carries the environment values instead of reading the process env.
//!
//! `std.process`/`std.fs` only, no direct OS imports, so the unit tests run
//! in every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const path_env = @import("../../os/path_env.zig");
const RuntimeAgent = @import("runtime_agent.zig").RuntimeAgent;

/// Windows launchable extensions, in the order `where` would prefer them.
/// A fixed list rather than `%PATHEXT%`: these three are the only shapes a
/// CLI runtime ships as (native exe, npm shim, batch shim), and honoring an
/// arbitrary PATHEXT would have the probe report `claude.js` "installed".
const extensions = [_][]const u8{ ".exe", ".cmd", ".bat" };

/// The environment the binary probe consults, injectable so tests point it
/// at tempdirs. `fromProcess` fills it from the real process environment.
pub const ProbeEnv = struct {
    /// `PATH`, split on `std.fs.path.delimiter`.
    path: ?[]const u8 = null,
    /// `USERPROFILE` — roots `.local/bin` and the agent's own config dir.
    home: ?[]const u8 = null,
    /// `APPDATA` — roots the npm global prefix.
    appdata: ?[]const u8 = null,
    /// `LOCALAPPDATA` — roots the winget links dir.
    local_appdata: ?[]const u8 = null,

    /// Values are arena-owned; missing variables stay null and their
    /// locations are simply not probed.
    pub fn fromProcess(arena: Allocator) ProbeEnv {
        return .{
            .path = std.process.getEnvVarOwned(arena, "PATH") catch null,
            .home = std.process.getEnvVarOwned(arena, "USERPROFILE") catch null,
            .appdata = std.process.getEnvVarOwned(arena, "APPDATA") catch null,
            .local_appdata = std.process.getEnvVarOwned(arena, "LOCALAPPDATA") catch null,
        };
    }
};

pub const RuntimeProbe = union(enum) {
    /// The real probe: the runtime's binary on the process PATH, else in one
    /// of its well-known install locations.
    binary,
    /// The same path walk over an EXPLICIT environment — the sandbox seam
    /// the acceptance harness reaches through `GHOZTTY_AGENT_HOME` (T870):
    /// only the given locations are consulted, so the box's real installs
    /// can never leak into a sandboxed run. The env's slices must outlive
    /// the probe.
    env: ProbeEnv,
    /// Test seam: exactly these agents are installed, nothing consulted.
    stub: std.EnumSet(RuntimeAgent),

    pub fn stubOf(agents: []const RuntimeAgent) RuntimeProbe {
        var set = std.EnumSet(RuntimeAgent).initEmpty();
        for (agents) |agent| set.insert(agent);
        return .{ .stub = set };
    }

    pub fn isInstalled(self: RuntimeProbe, alloc: Allocator, agent: RuntimeAgent) bool {
        switch (self) {
            .stub => |set| return set.contains(agent),
            .env => |probe_env| {
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                defer arena_state.deinit();
                return binaryInstalled(arena_state.allocator(), agent, probe_env);
            },
            .binary => {
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                return binaryInstalled(arena, agent, ProbeEnv.fromProcess(arena));
            },
        }
    }
};

/// The path-walk half of the binary probe, over an explicit environment.
/// Allocation failure reads as "not installed" — the callers treat detection
/// as a gate, and refusing to install beats guessing.
pub fn binaryInstalled(arena: Allocator, agent: RuntimeAgent, env: ProbeEnv) bool {
    const bin = agent.binaryName();

    if (env.path) |path_value| {
        var it = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
        while (it.next()) |entry| {
            const dir = path_env.normalize(entry);
            if (dir.len == 0) continue;
            if (anyExtensionExists(arena, dir, bin)) return true;
        }
    }

    // Well-known install locations the process PATH may miss: the native
    // installer, the runtime's own bootstrap dir, an npm global install and
    // a winget-linked install. Forward slashes throughout — `std.fs` accepts
    // them on Windows and the composition stays testable on the Mac seat.
    if (env.home) |home| {
        const local_bin = std.mem.concat(arena, u8, &.{ home, "/.local/bin" }) catch return false;
        if (anyExtensionExists(arena, local_bin, bin)) return true;
        const config_local = std.mem.concat(
            arena,
            u8,
            &.{ home, "/", agent.configDirectoryName(), "/local" },
        ) catch return false;
        if (anyExtensionExists(arena, config_local, bin)) return true;
    }
    if (env.appdata) |appdata| {
        const npm = std.mem.concat(arena, u8, &.{ appdata, "/npm" }) catch return false;
        if (anyExtensionExists(arena, npm, bin)) return true;
    }
    if (env.local_appdata) |local| {
        const links = std.mem.concat(
            arena,
            u8,
            &.{ local, "/Microsoft/WinGet/Links" },
        ) catch return false;
        if (anyExtensionExists(arena, links, bin)) return true;
    }
    return false;
}

fn anyExtensionExists(arena: Allocator, dir: []const u8, bin: []const u8) bool {
    for (extensions) |ext| {
        const candidate = std.mem.concat(arena, u8, &.{ dir, "/", bin, ext }) catch
            return false;
        std.fs.cwd().access(candidate, .{}) catch continue;
        return true;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "stub probe answers exactly its set, touching nothing" {
    const alloc = testing.allocator;
    const probe = RuntimeProbe.stubOf(&.{.claude});
    try testing.expect(probe.isInstalled(alloc, .claude));
    try testing.expect(!probe.isInstalled(alloc, .copilot));

    const none = RuntimeProbe.stubOf(&.{});
    try testing.expect(!none.isInstalled(alloc, .claude));
}

test "binary probe finds the exe through PATH" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("bin");
    try tmp.dir.writeFile(.{ .sub_path = "bin/claude.exe", .data = "" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path_value = try std.mem.concat(alloc, u8, &.{ root, "/bin" });
    defer alloc.free(path_value);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(binaryInstalled(arena, .claude, .{ .path = path_value }));
    // The same PATH holds no copilot binary.
    try testing.expect(!binaryInstalled(arena, .copilot, .{ .path = path_value }));
}

test "binary probe walks .cmd shims and multi-entry PATHs" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("empty");
    try tmp.dir.makePath("shims");
    try tmp.dir.writeFile(.{ .sub_path = "shims/copilot.cmd", .data = "" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path_value = try std.fmt.allocPrint(alloc, "{s}/empty{c}{s}/shims", .{
        root, std.fs.path.delimiter, root,
    });
    defer alloc.free(path_value);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expect(binaryInstalled(arena_state.allocator(), .copilot, .{ .path = path_value }));
}

test "binary probe falls back to .local/bin and the config dir's local/" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".local/bin");
    try tmp.dir.writeFile(.{ .sub_path = ".local/bin/claude.exe", .data = "" });
    try tmp.dir.makePath(".copilot/local");
    try tmp.dir.writeFile(.{ .sub_path = ".copilot/local/copilot.exe", .data = "" });

    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(binaryInstalled(arena, .claude, .{ .home = home }));
    try testing.expect(binaryInstalled(arena, .copilot, .{ .home = home }));
}

test "binary probe falls back to the npm prefix and winget links" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("appdata/npm");
    try tmp.dir.writeFile(.{ .sub_path = "appdata/npm/claude.cmd", .data = "" });
    try tmp.dir.makePath("local/Microsoft/WinGet/Links");
    try tmp.dir.writeFile(.{ .sub_path = "local/Microsoft/WinGet/Links/copilot.exe", .data = "" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const appdata = try std.mem.concat(alloc, u8, &.{ root, "/appdata" });
    defer alloc.free(appdata);
    const local = try std.mem.concat(alloc, u8, &.{ root, "/local" });
    defer alloc.free(local);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(binaryInstalled(arena, .claude, .{ .appdata = appdata }));
    try testing.expect(binaryInstalled(arena, .copilot, .{ .local_appdata = local }));
}

test "a config dir without the binary does NOT read as installed" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Ghoztty's own leftovers: skills under the config dir, no CLI anywhere.
    try tmp.dir.makePath(".claude/skills/ghoztty");
    try tmp.dir.writeFile(.{ .sub_path = ".claude/skills/ghoztty/SKILL.md", .data = "x" });

    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    try testing.expect(!binaryInstalled(arena_state.allocator(), .claude, .{ .home = home }));
}

test "an empty environment reads nothing installed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(!binaryInstalled(arena_state.allocator(), .claude, .{}));
}
