//! Last-seen-version tracking for the What's New window (T624) — the Windows
//! counterpart of Mac's `WhatsNewTracking.swift`.
//!
//! The anchor the notes split on is "the version the user was running BEFORE
//! this launch". That has to be captured once, early, and then held for the
//! life of the process: the moment the app writes the current version down,
//! the old value is gone, and any later read would report "you already had
//! everything" for a user who has just been upgraded.
//!
//! Mac keeps it in `UserDefaults`; the Windows store is one small file,
//! `%LOCALAPPDATA%\ghoztty\whats-new-seen[-debug]`, holding the bare version
//! string. This module is the pure half — what the file means, what a launch
//! decides, and what (if anything) needs writing. The file IO lives in
//! `WhatsNewWindow.zig`, so these tests run in every lane.

const std = @import("std");

/// The stored version parsed out of the file's bytes: trimmed of whitespace
/// and a UTF-8 BOM, and rejected outright when empty or when it does not
/// begin with a digit.
///
/// The strictness is deliberate. A file that got truncated, or that some
/// other tool wrote a log line into, must read as "no anchor" — which shows
/// every bundled note as new — rather than as a version string nothing can
/// order, which would show NOTHING as new and hide a real upgrade.
pub fn parseStored(bytes: []const u8) ?[]const u8 {
    var text = bytes;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    text = std.mem.trim(u8, text, " \t\r\n");
    if (text.len == 0) return null;
    if (!std.ascii.isDigit(text[0])) return null;
    // One line only: anything after the first newline is not ours.
    if (std.mem.indexOfAny(u8, text, " \t\r\n") != null) return null;
    return text;
}

/// What a launch decided.
pub const Snapshot = struct {
    /// The version stored before this launch — the anchor the split uses.
    /// Null on the very first instrumented run (and on an unreadable store),
    /// which means "show everything bundled as new".
    previous_seen: ?[]const u8,
    /// The version to write back, or null when the store already says it and
    /// the write would be pure churn. A no-op launch of an unchanged build
    /// should not touch the disk.
    write: ?[]const u8,
};

/// Decide what this launch does, given the store's current contents.
/// `stored` is `parseStored`'s answer; `current` is this build's version.
pub fn decide(stored: ?[]const u8, current: []const u8) Snapshot {
    const seen = stored;
    const same = if (seen) |s| std.mem.eql(u8, s, current) else false;
    return .{ .previous_seen = seen, .write = if (same) null else current };
}

/// Holds the launch's answer for the life of the process. Mac's
/// `previousSeenVersion` is a static with the same contract: written once,
/// read many times, and never re-read from the store.
pub const Tracker = struct {
    previous_seen: ?[]const u8 = null,
    /// Whether `snapshot` has run. A second call is a no-op, so a caller that
    /// is unsure whether launch already ran it cannot destroy the anchor.
    taken: bool = false,

    /// Record the launch's anchor. Returns what (if anything) the caller
    /// should write to the store; a repeat call returns null and changes
    /// nothing.
    pub fn snapshot(
        self: *Tracker,
        stored: ?[]const u8,
        current: []const u8,
    ) ?[]const u8 {
        if (self.taken) return null;
        const decision = decide(stored, current);
        self.previous_seen = decision.previous_seen;
        self.taken = true;
        return decision.write;
    }
};

/// The store's filename, `-debug` suffixed on a debug build so a dev build
/// never advances (or reads) the installed release's anchor — the same
/// coexistence rule the orphan-notify and layout stores follow.
pub fn fileName(is_debug: bool) []const u8 {
    return if (is_debug) "whats-new-seen-debug" else "whats-new-seen";
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "parseStored: trims whitespace and a BOM" {
    try testing.expectEqualStrings("1.34.0", parseStored("1.34.0").?);
    try testing.expectEqualStrings("1.34.0", parseStored("1.34.0\r\n").?);
    try testing.expectEqualStrings("1.34.0", parseStored("  1.34.0  ").?);
    try testing.expectEqualStrings("1.34.0", parseStored("\xEF\xBB\xBF1.34.0\n").?);
}

test "parseStored: garbage reads as no anchor, not as a version" {
    // Empty, truncated, or something else's text. Each must mean "show
    // everything as new" rather than "you have seen everything".
    try testing.expect(parseStored("") == null);
    try testing.expect(parseStored("\n\n") == null);
    try testing.expect(parseStored("version=1.34.0") == null);
    try testing.expect(parseStored("1.34.0 and then some") == null);
    try testing.expect(parseStored("1.34.0\n1.35.0") == null);
}

test "decide: first run has no anchor and writes the current version" {
    const d = decide(null, "1.36.0");
    try testing.expect(d.previous_seen == null);
    try testing.expectEqualStrings("1.36.0", d.write.?);
}

test "decide: an upgrade anchors on the OLD version and advances the store" {
    const d = decide("1.34.0", "1.36.0");
    try testing.expectEqualStrings("1.34.0", d.previous_seen.?);
    try testing.expectEqualStrings("1.36.0", d.write.?);
}

test "decide: an unchanged build writes nothing" {
    const d = decide("1.36.0", "1.36.0");
    try testing.expectEqualStrings("1.36.0", d.previous_seen.?);
    try testing.expect(d.write == null);
}

test "Tracker: the anchor survives a second call" {
    var t: Tracker = .{};
    try testing.expectEqualStrings("1.36.0", t.snapshot("1.34.0", "1.36.0").?);
    try testing.expectEqualStrings("1.34.0", t.previous_seen.?);

    // A second snapshot must not re-read the (now advanced) store and decide
    // the user has already seen this build.
    try testing.expect(t.snapshot("1.36.0", "1.36.0") == null);
    try testing.expectEqualStrings("1.34.0", t.previous_seen.?);
}

test "fileName: the debug build has its own anchor" {
    try testing.expectEqualStrings("whats-new-seen", fileName(false));
    try testing.expectEqualStrings("whats-new-seen-debug", fileName(true));
}
