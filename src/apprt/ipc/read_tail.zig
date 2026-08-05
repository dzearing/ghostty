//! The "last N lines" rule behind `+read`, and the contract for what an
//! EMPTY answer means.
//!
//! Extracted from the win32 `+read` handler (T181) so the rule is pure,
//! testable in the `-Dapp-runtime=none` lane, and stated in exactly one place
//! — the Swift handler applies the same rule with `components(separatedBy:)`
//! and `suffix(n)`, so the two implementations agree by description rather
//! than by coincidence.
//!
//! ## Empty is an answer, not a failure (T181)
//!
//! A terminal pane that has printed nothing yet dumps an EMPTY screen. That is
//! the normal state of a pane for the first fraction of a second of its life —
//! the window is registered (and `+list --json` already hands out its pane id
//! and its child's pid) before the shell has painted a prompt — and it is the
//! permanent state of a pane running something silent.
//!
//! `+read` used to report that as `failed to read terminal content from
//! '<pane>'`, which a caller cannot tell apart from "no such pane", "the pane
//! is wedged", or "the app is broken". It was also transient, which is what
//! made it dangerous: an agent that reads once and believes the answer records
//! "the pane produced no output" as a product verdict rather than as a race it
//! lost. So: an empty screen returns success with empty text, the way `tail`
//! of an empty file exits 0, and the error messages that remain each name a
//! DIFFERENT state.

const std = @import("std");

/// The last `lines` lines of `text`, as a slice into `text`.
///
/// One trailing newline is dropped first, so a dump ending in `"\n"` is not
/// treated as having a final empty line (the Swift side drops the same
/// trailing empty split element). `lines == 0` is not meaningful and is
/// treated as "everything", the same way the CLI's `--lines=0` falls back to
/// the default rather than returning nothing.
///
/// Returns an empty slice for empty input. That is a valid answer — see the
/// module comment.
pub fn tail(text: []const u8, lines: usize) []const u8 {
    var full = text;
    if (full.len > 0 and full[full.len - 1] == '\n') full = full[0 .. full.len - 1];
    if (lines == 0) return full;

    var newlines: usize = 0;
    var i: usize = full.len;
    while (i > 0) {
        i -= 1;
        if (full[i] == '\n') {
            newlines += 1;
            if (newlines == lines) return full[i + 1 ..];
        }
    }
    return full;
}

test "tail: empty input is empty output, not an error" {
    const testing = std.testing;
    try testing.expectEqualStrings("", tail("", 50));
    try testing.expectEqualStrings("", tail("\n", 50));
}

test "tail: fewer lines than asked for returns everything" {
    const testing = std.testing;
    try testing.expectEqualStrings("a\nb", tail("a\nb", 50));
    try testing.expectEqualStrings("a\nb", tail("a\nb\n", 50));
}

test "tail: takes the last N lines" {
    const testing = std.testing;
    try testing.expectEqualStrings("c", tail("a\nb\nc", 1));
    try testing.expectEqualStrings("b\nc", tail("a\nb\nc", 2));
    try testing.expectEqualStrings("a\nb\nc", tail("a\nb\nc", 3));
    try testing.expectEqualStrings("c", tail("a\nb\nc\n", 1));
}

test "tail: interior blank lines count as lines" {
    const testing = std.testing;
    try testing.expectEqualStrings("\nc", tail("a\nb\n\nc", 2));
    try testing.expectEqualStrings("", tail("a\n\n", 1));
}

test "tail: a single line with no newline" {
    const testing = std.testing;
    try testing.expectEqualStrings("only", tail("only", 5));
    try testing.expectEqualStrings("only", tail("only", 1));
}

test "tail: zero lines means everything" {
    const testing = std.testing;
    try testing.expectEqualStrings("a\nb", tail("a\nb\n", 0));
}
