//! Pure logic for Windows `;`-separated PATH values: deciding whether a
//! directory is already on one and building the appended value when it is
//! not. No OS imports, so the unit tests run in every app-runtime lane (the
//! hero_math/dim_math pattern).
//!
//! Two callers share it, which is why it lives in `src/os` rather than under
//! an apprt (T42): the GUI's user-PATH self-heal (T70,
//! `apprt/win32/PathInstaller.zig`, which owns the registry write) and the
//! agent's user-environment overlay (`os/user_env.zig`, which owns the
//! registry read). A second copy of `normalize`/`eqlDir` is exactly the
//! four-copies-four-chances-to-be-wrong trap T257 wrote down.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Normalize a single PATH entry for comparison: trim whitespace, strip one
/// pair of surrounding double quotes (cmd.exe accepts quoted entries), and
/// strip trailing path separators — except the one in a bare drive root
/// ("C:\"), which is meaningful. Returns a slice into `entry`.
pub fn normalize(entry: []const u8) []const u8 {
    var s = std.mem.trim(u8, entry, " \t");
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        s = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    while (s.len > 0 and (s[s.len - 1] == '\\' or s[s.len - 1] == '/')) {
        // Keep the separator of a drive root: "C:\" != "C:" (the latter
        // means "current directory on C:").
        if (s.len == 3 and s[1] == ':') break;
        s = s[0 .. s.len - 1];
    }
    return s;
}

/// Whether two directory paths refer to the same PATH entry after
/// normalization. Case-insensitive (ASCII), like Windows path resolution.
pub fn eqlDir(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(normalize(a), normalize(b));
}

/// Whether the `;`-separated PATH value already contains `dir`. Empty
/// segments (";;") are skipped. Callers wanting `%VAR%`-aware matching
/// expand the value first and call this on both raw and expanded forms.
pub fn contains(path_value: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_value, ';');
    while (it.next()) |entry| {
        if (normalize(entry).len == 0) continue;
        if (eqlDir(entry, dir)) return true;
    }
    return false;
}

/// Build the PATH value with `dir` appended. The caller owns the result.
pub fn append(alloc: Allocator, path_value: []const u8, dir: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, path_value, " \t");
    if (trimmed.len == 0) return alloc.dupe(u8, dir);
    const sep: []const u8 = if (trimmed[trimmed.len - 1] == ';') "" else ";";
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ trimmed, sep, dir });
}

test "normalize: quotes, trailing separators, drive root" {
    const testing = std.testing;
    try testing.expectEqualStrings("C:\\x\\bin", normalize("C:\\x\\bin\\"));
    try testing.expectEqualStrings("C:\\x\\bin", normalize(" \"C:\\x\\bin\\\" "));
    try testing.expectEqualStrings("C:\\x", normalize("C:\\x\\\\"));
    try testing.expectEqualStrings("C:\\", normalize("C:\\"));
    try testing.expectEqualStrings("", normalize("  "));
    try testing.expectEqualStrings("%LOCALAPPDATA%\\Programs", normalize("%LOCALAPPDATA%\\Programs\\"));
}

test "eqlDir: case and trailing-separator insensitive" {
    const testing = std.testing;
    try testing.expect(eqlDir("C:\\Users\\D\\bin", "c:\\users\\d\\BIN\\"));
    try testing.expect(eqlDir("\"C:\\a b\\bin\"", "C:\\a b\\bin"));
    try testing.expect(!eqlDir("C:\\a\\bin", "C:\\a\\bin2"));
    try testing.expect(!eqlDir("C:\\", "C:"));
}

test "contains: finds entries in any accepted form" {
    const testing = std.testing;
    const dir = "C:\\Users\\D\\AppData\\Local\\Programs\\Ghoztty";
    try testing.expect(contains("C:\\w;" ++ dir ++ ";C:\\x", dir));
    try testing.expect(contains(dir ++ "\\", dir));
    try testing.expect(contains("\"" ++ dir ++ "\\\";C:\\x", dir));
    try testing.expect(contains("c:\\users\\d\\appdata\\local\\programs\\ghoztty", dir));
    try testing.expect(!contains("", dir));
    try testing.expect(!contains(";;", dir));
    try testing.expect(!contains("C:\\w;C:\\x", dir));
    // Prefix is not membership.
    try testing.expect(!contains(dir ++ "2", dir));
}

test "append: empty, trailing semicolon, normal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const a = try append(alloc, "", "C:\\g");
    defer alloc.free(a);
    try testing.expectEqualStrings("C:\\g", a);

    const b = try append(alloc, "C:\\x;", "C:\\g");
    defer alloc.free(b);
    try testing.expectEqualStrings("C:\\x;C:\\g", b);

    const c = try append(alloc, "C:\\x", "C:\\g");
    defer alloc.free(c);
    try testing.expectEqualStrings("C:\\x;C:\\g", c);
}
