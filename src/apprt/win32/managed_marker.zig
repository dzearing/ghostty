//! The ownership token stamped into every Ghoztty-managed artifact, and the
//! pure install-state grammar built on it (T865, the win32 half of Mac's
//! `GhosttyManagedMarker` + `ComponentInstallState`).
//!
//! ONE token, `ghoztty-managed`, with per-format comment wrappers. Every
//! marker-guarded write and drift check keys off this substring, so CHANGING
//! THE TOKEN ORPHANS every already-installed file (it keeps the old token,
//! stops matching, and can no longer be updated or uninstalled). It must
//! never change in isolation — hence one source of truth rather than a
//! literal copied into each component.
//!
//! No OS imports, so the unit tests run in every app-runtime lane (the
//! hero_math/dim_math pattern). The file-ops half — the writer that enforces
//! this grammar on disk — lives in `managed_file.zig`.
const std = @import("std");

/// The ownership token. See the module doc for why this may never change.
pub const token = "ghoztty-managed";

/// `# ghoztty-managed` — shell scripts (the banner script).
pub const shell_comment = "# " ++ token;

/// `<!-- ghoztty-managed -->` — markdown (bundled skills).
pub const html_comment = "<!-- " ++ token ++ " -->";

/// Install state of a single managed artifact, and (aggregated across an
/// agent's components) of a whole runtime integration. One shared type: the
/// component and runtime levels use the same three-state vocabulary, so a
/// second identical enum only invited them to drift apart.
pub const InstallState = enum {
    not_installed,
    installed,
    outdated,
};

/// The aggregate state of a runtime's integration is the same three-state
/// value as a single component; an alias so call sites read intentionally.
pub const RuntimeIntegrationState = InstallState;

/// Mac's `ManagedFile.state` classification table, minus the file read:
/// unreadable/absent (`null`) → not_installed; no marker → not_installed
/// (the file is not ours, whatever it says); byte-identical to `expected` →
/// installed; ours but different → outdated. Containment is over raw bytes,
/// not lines: the marker arrives via a comment wrapper above, so a substring
/// match is exact enough and never misfires on partial tokens (the wrappers
/// bound the token with comment syntax on both sides).
pub fn classify(contents: ?[]const u8, expected: []const u8, marker: []const u8) InstallState {
    const c = contents orelse return .not_installed;
    if (std.mem.indexOf(u8, c, marker) == null) return .not_installed;
    return if (std.mem.eql(u8, c, expected)) .installed else .outdated;
}

/// Whether an existing file may be overwritten or removed by a managed
/// write: only if it carries the marker. Split out of `classify` because
/// `write` needs exactly this half (ownership) without the staleness half.
pub fn isManaged(contents: []const u8, marker: []const u8) bool {
    return std.mem.indexOf(u8, contents, marker) != null;
}

const testing = std.testing;

test "wrappers carry the token" {
    try testing.expect(std.mem.indexOf(u8, shell_comment, token) != null);
    try testing.expect(std.mem.indexOf(u8, html_comment, token) != null);
    // The wrappers are what land in files, so they must never be empty or
    // degenerate to the bare token (a bare token is not a comment in any
    // target format).
    try testing.expect(shell_comment.len > token.len);
    try testing.expect(html_comment.len > token.len);
}

test "classify: absent or unreadable is not_installed" {
    try testing.expectEqual(InstallState.not_installed, classify(null, "x", token));
}

test "classify: unmarked content is not_installed regardless of match" {
    // Even byte-identical content without the marker is NOT ours: expected
    // content always embeds the marker in practice, and an unmarked file must
    // never be claimed.
    try testing.expectEqual(
        InstallState.not_installed,
        classify("echo hi\n", "echo hi\n", token),
    );
}

test "classify: marked and identical is installed" {
    const body = shell_comment ++ "\necho hi\n";
    try testing.expectEqual(InstallState.installed, classify(body, body, token));
}

test "classify: marked but different is outdated" {
    const old = shell_comment ++ "\necho v1\n";
    const new = shell_comment ++ "\necho v2\n";
    try testing.expectEqual(InstallState.outdated, classify(old, new, token));
}

test "classify: marker anywhere in the file counts" {
    const body = "#!/bin/sh\n" ++ shell_comment ++ "\necho hi\n";
    try testing.expectEqual(InstallState.installed, classify(body, body, token));
}

test "isManaged" {
    try testing.expect(isManaged(html_comment ++ "\n# skill\n", token));
    try testing.expect(!isManaged("# my own file\n", token));
    try testing.expect(!isManaged("", token));
}
