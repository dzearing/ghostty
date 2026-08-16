//! Detection of Claude's own external `ghoztty` plugin (T869, the win32
//! half of Mac's `ClaudeHookSpec.externalPluginRegistrations`): when it is
//! registered, something other than Ghoztty already owns this runtime's
//! skills and hooks, and the factory must hand out NEITHER component —
//! half-gating recreates the split-state bug through the other component.
//!
//! Its own module rather than a `ClaudeHookSpec` method (where Mac keeps
//! it): that file is already 500+ lines of merge/ownership logic, and the
//! plugin-migration slice (T870) consumes `registrations` too, so the parse
//! site stands alone. One parse site, exactly like Mac: detection asks
//! whether the list is empty, migration asks what is in it.
//!
//! Parsed, never substring-matched. The manifest records each install's
//! `installPath` (and at project scope a `projectPath`), so a bare
//! "contains ghoztty" reports true for ANY plugin the user installed while
//! sitting in a ghoztty checkout — and Ghoztty would then silently decline
//! to install, believing its own plugin was already there.
//!
//! Plain `std.fs` + `std.json`, no OS imports, so the tempdir tests run in
//! every app-runtime lane on both seats.
const std = @import("std");
const Allocator = std.mem.Allocator;

const managed_file = @import("managed_file.zig");

/// Home-relative path of Claude's plugin manifest.
pub const manifest_sub_path = ".claude/plugins/installed_plugins.json";

/// The plugin name that means "an external install owns the integration".
pub const external_plugin_name = "ghoztty";

/// Every manifest key registering the external plugin, e.g.
/// `ghoztty@dzearing-claude-marketplace`. Plural because the same plugin is
/// registered through more than one marketplace in practice, and each
/// registration is separately installed — and separately uninstallable.
///
/// Returned slices alias the parsed manifest, so pass an ARENA. A missing,
/// unreadable or unrecognized manifest is the empty list: report absent
/// rather than guessing, so a manifest revision cannot silently suppress the
/// integration — the cost of a false negative is a duplicate skill, the cost
/// of a false positive is Ghoztty refusing to install at all.
pub fn registrations(arena: Allocator, home: std.fs.Dir) Allocator.Error![]const []const u8 {
    const contents = home.readFileAlloc(arena, manifest_sub_path, managed_file.max_managed_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, contents, .{}) catch
        return &.{};
    if (root != .object) return &.{};
    const plugins = root.object.get("plugins") orelse return &.{};

    var out: std.ArrayList([]const u8) = .empty;
    switch (plugins) {
        // `"version": 2` — an object keyed by `<name>@<marketplace>`. The
        // NAME half must match exactly; any marketplace counts.
        .object => |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, nameOfRegistration(key), external_plugin_name))
                    try out.append(arena, key);
            }
        },
        // Older shape — an array of entries carrying `name`.
        .array => |list| {
            for (list.items) |entry| {
                if (entry != .object) continue;
                const name = entry.object.get("name") orelse continue;
                if (name != .string) continue;
                if (std.mem.eql(u8, name.string, external_plugin_name))
                    try out.append(arena, name.string);
            }
        },
        // A shape we do not recognize: absent (see doc above).
        else => return &.{},
    }
    return out.items;
}

/// Is Claude's own `ghoztty` plugin installed — i.e. does something other
/// than Ghoztty already own this runtime's skills and hooks?
pub fn isExternalPluginInstalled(alloc: Allocator, home: std.fs.Dir) Allocator.Error!bool {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    return (try registrations(arena_state.allocator(), home)).len > 0;
}

fn nameOfRegistration(key: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, key, '@') orelse return key;
    return key[0..at];
}

// -----------------------------------------------------------------------------
// Tests — the Mac parsing table (v2 shape, old shape, unknown shape,
// same-name-other-marketplace, installPath decoy).
// -----------------------------------------------------------------------------

const testing = std.testing;

fn writeManifest(tmp: *testing.TmpDir, json: []const u8) !void {
    try tmp.dir.makePath(".claude/plugins");
    try tmp.dir.writeFile(.{ .sub_path = manifest_sub_path, .data = json });
}

test "absent manifest reads not installed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
}

test "v2 object shape: ghoztty@any-marketplace is installed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(&tmp,
        \\{"version": 2, "plugins": {
        \\  "other@market": [{"installPath": "/x"}],
        \\  "ghoztty@some-other-marketplace": [{"installPath": "/y"}]
        \\}}
    );
    try testing.expect(try isExternalPluginInstalled(testing.allocator, tmp.dir));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const regs = try registrations(arena_state.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 1), regs.len);
    try testing.expectEqualStrings("ghoztty@some-other-marketplace", regs[0]);
}

test "v2 shape: a name that merely starts with ghoztty does not match" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(&tmp,
        \\{"version": 2, "plugins": {"ghoztty-extras@market": [{}]}}
    );
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
}

test "old array shape: entries carrying name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(&tmp,
        \\{"plugins": [
        \\  {"name": "other", "installPath": "/x"},
        \\  {"name": "ghoztty", "installPath": "/y"}
        \\]}
    );
    try testing.expect(try isExternalPluginInstalled(testing.allocator, tmp.dir));
}

test "installPath decoy: a ghoztty checkout path never counts as the plugin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The substring-match trap: some OTHER plugin installed from inside a
    // ghoztty checkout. Parsed matching must report absent.
    try writeManifest(&tmp,
        \\{"version": 2, "plugins": {
        \\  "other@market": [{"installPath": "D:/git/ghoztty/plugins/other",
        \\                    "projectPath": "D:/git/ghoztty"}]
        \\}}
    );
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
}

test "unknown shapes read absent, never installed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // plugins is a scalar.
    try writeManifest(&tmp,
        \\{"plugins": "ghoztty"}
    );
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
    // Root is an array.
    try writeManifest(&tmp,
        \\["ghoztty"]
    );
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
    // Not JSON at all.
    try writeManifest(&tmp, "ghoztty {{{");
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
    // No plugins key.
    try writeManifest(&tmp,
        \\{"version": 3}
    );
    try testing.expect(!try isExternalPluginInstalled(testing.allocator, tmp.dir));
}
