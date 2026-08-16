//! Embedded agent-integration assets (T866): the Ghoztty skill documents and
//! the two hook helper scripts the app installs for a coding agent. The Mac
//! app carries these same files as loose resources in its bundle
//! (`macos/Resources/Ghoztty/`, read by `GhosttyAssets.swift`); the Windows
//! equivalent of the app bundle is the exe itself, so here they are
//! `@embedFile`d — nothing to go missing or go stale beside the exe, and the
//! portable-zip manifest stays untouched.
//!
//! Layout of `assets/ghoztty/` (chosen here, recorded for convergence):
//!   - `upstream/`   pristine byte-for-byte mirror of tip-of-main's
//!                   `macos/Resources/Ghoztty/` — NEVER edited by hand. The
//!                   acceptance harness (`test/win32/vendored-assets.ps1`)
//!                   compares every file against `origin/main`, so drift from
//!                   the Mac copies is loud.
//!   - `hooks/`, `skills/`  the copies the app ships. Three of the four are
//!                   byte-identical to `upstream/`; `hooks/ghoztty-banner.sh`
//!                   is the one deliberate fork — its `jq` plumbing is
//!                   replaced with `ghoztty +json` (native, dependency-free)
//!                   until that change lands on main (mac-seat task), at
//!                   which point the fork collapses back into the mirror and
//!                   the Mac and Windows builds can converge on one copy.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.
const std = @import("std");

pub const Error = error{UnknownAsset};

/// The skill names the app installs, mirroring the Mac flow's set.
pub const skill_names = [_][]const u8{ "ghoztty", "process-feedback" };

const skill_ghoztty = @embedFile("assets/ghoztty/skills/ghoztty/SKILL.md");
const skill_process_feedback = @embedFile("assets/ghoztty/skills/process-feedback/SKILL.md");
const banner_script = @embedFile("assets/ghoztty/hooks/ghoztty-banner.sh");
const activity_state_script = @embedFile("assets/ghoztty/hooks/ghoztty-activity-state.sh");

/// The bundled SKILL.md text for a skill name, `error.UnknownAsset` for a
/// name not in `skill_names` (the Mac flow's `GhosttyAssetsError.missing`).
pub fn skillMarkdown(name: []const u8) Error![]const u8 {
    if (std.mem.eql(u8, name, "ghoztty")) return skill_ghoztty;
    if (std.mem.eql(u8, name, "process-feedback")) return skill_process_feedback;
    return Error.UnknownAsset;
}

/// The banner updater hook script (the jq-free Windows fork; see header).
pub fn bannerScript() []const u8 {
    return banner_script;
}

/// The busy/idle activity-state hook script (byte-identical to main's).
pub fn activityStateScript() []const u8 {
    return activity_state_script;
}

test "every named skill resolves and looks like a skill document" {
    for (skill_names) |name| {
        const text = try skillMarkdown(name);
        try std.testing.expect(text.len > 0);
        // SKILL.md files open with YAML frontmatter.
        try std.testing.expect(std.mem.startsWith(u8, text, "---\n"));
    }
}

test "unknown skill is a typed error" {
    try std.testing.expectError(Error.UnknownAsset, skillMarkdown("nope"));
    try std.testing.expectError(Error.UnknownAsset, skillMarkdown(""));
}

test "hook scripts carry the shell ownership marker" {
    // Both scripts must be recognizable as ghoztty-managed (the marker the
    // T865 writer guards on) and start with a shebang.
    for ([_][]const u8{ bannerScript(), activityStateScript() }) |text| {
        try std.testing.expect(std.mem.startsWith(u8, text, "#!"));
        try std.testing.expect(std.mem.indexOf(u8, text, "# ghoztty-managed") != null);
    }
}

test "banner script fork is jq-free and json-native" {
    // The one deliberate divergence from main: every jq call site is gone,
    // replaced by `ghoztty +json`. If a re-vendor ever pastes main's jq
    // version over the fork, this is the tripwire.
    const text = bannerScript();
    try std.testing.expect(std.mem.indexOf(u8, text, "ghoztty +json") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jq ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jq -") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "command -v jq") == null);
}
