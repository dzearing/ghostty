//! Pure "Focus: <pane>" jump-entry derivation for the command palette
//! (T555) — the OS-free half, so the none lane can assert it (the
//! `tab_tooltip.zig` pattern). The runtime glue — walking the live windows,
//! snapshotting entries, dispatching the focus — lives in `Surface.zig`.
//!
//! The Mac palette's `jumpOptions` (TerminalCommandPalette.swift) list every
//! open surface across every window as `Focus: <title>` with the pane's
//! `~`-abbreviated working directory as a dimmed subtitle, and selecting one
//! focuses that surface. Three rules carried over verbatim:
//!
//! - the display title falls back pane title → tab title → "Untitled",
//! - the subtitle is suppressed when the title already contains it (a shell
//!   whose title IS the cwd would otherwise say it twice), and
//! - the cwd is abbreviated exactly like the tab tooltip (`tab_tooltip`),
//!   so the two surfaces can never disagree about the same directory.

const std = @import("std");
const tab_tooltip = @import("tab_tooltip.zig");

/// The label prefix. Matching Mac's `"Focus: \(displayTitle)"`.
pub const prefix = "Focus: ";

/// What an untitled pane is called (Mac: `"Untitled"`).
pub const untitled = "Untitled";

/// Max jump entries snapshotted when the palette opens — bounds the
/// palette's fixed-size filter index array the same way
/// MAX_USER_PALETTE_ENTRIES does. 64 live panes is far past any real
/// session on one box.
pub const max_entries: usize = 64;

/// The display title for a pane: its own title when it has one, the tab's
/// title otherwise, "Untitled" when both are empty (Mac
/// TerminalCommandPalette.swift jumpOptions fallback chain).
pub fn displayTitle(pane_title: ?[]const u8, tab_title: []const u8) []const u8 {
    if (pane_title) |t| {
        if (t.len > 0) return t;
    }
    if (tab_title.len > 0) return tab_title;
    return untitled;
}

/// The subtitle for a pane: `location` home-abbreviated and middle-elided
/// (the tab tooltip's exact derivation), or null when there is nothing to
/// say or when `title` already contains the abbreviated path (Mac's
/// `!displayTitle.contains(pwd)` guard). `out.len >= tab_tooltip.max_len`
/// is the caller's contract.
pub fn subtitle(
    out: []u8,
    location: []const u8,
    home: ?[]const u8,
    title: []const u8,
) ?[]const u8 {
    const tip = tab_tooltip.tipText(out, location, home) orelse return null;
    if (std.mem.indexOf(u8, title, tip) != null) return null;
    return tip;
}

/// Whether a jump entry survives the palette filter: a case-insensitive
/// substring hit on its label OR its subtitle — filtering by directory is
/// how two same-shell panes are told apart, so the subtitle must count.
pub fn matches(filter: []const u8, label: []const u8, sub: ?[]const u8) bool {
    if (filter.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(label, filter) != null) return true;
    if (sub) |s| {
        if (std.ascii.indexOfIgnoreCase(s, filter) != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "displayTitle: pane title wins" {
    try testing.expectEqualStrings("claude", displayTitle("claude", "Tab 1"));
}

test "displayTitle: empty pane title falls back to the tab title" {
    try testing.expectEqualStrings("Tab 1", displayTitle("", "Tab 1"));
    try testing.expectEqualStrings("Tab 1", displayTitle(null, "Tab 1"));
}

test "displayTitle: both empty is Untitled" {
    try testing.expectEqualStrings(untitled, displayTitle("", ""));
    try testing.expectEqualStrings(untitled, displayTitle(null, ""));
}

test "subtitle: abbreviates like the tab tooltip" {
    var buf: [tab_tooltip.max_len]u8 = undefined;
    try testing.expectEqualStrings(
        "~\\git\\ghoztty",
        subtitle(&buf, "C:\\Users\\David\\git\\ghoztty", "C:\\Users\\David", "pwsh").?,
    );
}

test "subtitle: suppressed when the title already contains it" {
    var buf: [tab_tooltip.max_len]u8 = undefined;
    try testing.expectEqual(
        @as(?[]const u8, null),
        subtitle(&buf, "C:\\Users\\David\\git", "C:\\Users\\David", "pwsh in ~\\git"),
    );
}

test "subtitle: empty location is null" {
    var buf: [tab_tooltip.max_len]u8 = undefined;
    try testing.expectEqual(
        @as(?[]const u8, null),
        subtitle(&buf, "", "C:\\Users\\David", "pwsh"),
    );
}

test "matches: empty filter matches everything" {
    try testing.expect(matches("", "Focus: pwsh", null));
}

test "matches: case-insensitive hit on the label" {
    try testing.expect(matches("focus", "Focus: pwsh", null));
    try testing.expect(matches("PWSH", "Focus: pwsh", null));
    try testing.expect(!matches("zsh", "Focus: pwsh", null));
}

test "matches: the subtitle counts" {
    try testing.expect(matches("ghoztty", "Focus: pwsh", "~\\git\\ghoztty"));
    try testing.expect(!matches("ghoztty", "Focus: pwsh", null));
}
