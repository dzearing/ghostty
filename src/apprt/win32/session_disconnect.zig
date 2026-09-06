//! Whether a close can offer **Disconnect** — walking away from the panes
//! being closed while their agent sessions (and the processes inside them)
//! keep running on the machine that hosts them — and what the confirmation
//! should say about it (T1390, the Windows half of Mac's
//! `SessionDisconnectPolicy`, `830ba93cd`).
//!
//! The mechanism already exists on both sides of the wire: freeing a surface
//! DETACHes its agent session by default and only CLOSEs it (terminating the
//! child) when the apprt marked it CLOSE-on-free — `Surface
//! .setSessionCloseIntent`. "Disconnect" is therefore nothing more than "close
//! the window locally, but do not mark the surfaces". What this module owns is
//! the *policy*: which panes that is honest to offer for, and how to phrase it.
//!
//! It is stated over plain facts rather than over `PaneView`/`Window`, so the
//! rules are checkable in a test lane without a desktop, an app or a live
//! agent. `Window.disconnectOffer` is the thin adapter that reads those facts
//! off live panes.

const std = @import("std");

/// The facts about one pane that decide whether a Disconnect would spare it.
/// Everything here is cheap to read off a live pane and trivial to fabricate.
pub const PaneFacts = struct {
    /// False for a viewer pane: no terminal, so no agent session to keep.
    has_surface: bool,

    /// True once the child is gone. There is nothing left to keep running, so
    /// offering to keep it would be a lie.
    process_exited: bool,

    /// `confirm-close-surface` is not `false`. A user who turned close
    /// confirmation off asked for no prompts; this feature does not get to
    /// reintroduce one for them.
    ///
    /// Liveness is deliberately NOT folded in here — an IDLE remote pane is
    /// exactly the case this feature exists for. Ending a process on another
    /// machine is not the recoverable thing an idle local shell is, so the
    /// window-close gate widens for a remote window even when every shell in
    /// it is sitting at its prompt.
    confirm_close_enabled: bool,
};

/// Whether a window whose terminals ride a remote transport hosts sessions a
/// Disconnect could spare.
///
/// `is_cross_machine` is `Window.remote_machine != null`: the window was dialed
/// to another box. A plain local window has no session to leave behind at all.
///
/// The LOCAL session-persistence agent is excluded DELIBERATELY, and it is not
/// the same exclusion. Those panes do have a session — they run through this
/// box's own `ghoztty-agent` — but "closing a pane ends its session" is that
/// feature's documented contract (see `docs/claude/cli.md` and `+close`), and
/// the way to leave one running is to quit the app, not to close the pane.
/// Offering Disconnect there would contradict a promise the CLI already makes.
/// A local-agent window carries `local_agent_conn` and NO `remote_machine`, so
/// passing that one field is the whole test.
pub fn machineIsDisconnectable(is_cross_machine: bool) bool {
    return is_cross_machine;
}

/// Whether a Disconnect would actually spare this pane.
pub fn isDisconnectable(facts: PaneFacts) bool {
    return facts.has_surface and !facts.process_exited and facts.confirm_close_enabled;
}

/// The longest machine name the confirmation will render inline. A hostname
/// past this is replaced by the neutral phrasing rather than truncated — half a
/// hostname is a worse answer to "where does this run" than none.
pub const machine_name_cap: usize = 48;

/// The confirmation's message for a close that can offer Disconnect.
///
/// Deliberately scope-neutral: the same sentence has to read correctly whether
/// the user is closing a pane, a tab or a whole window, so it talks about the
/// SESSIONS at stake rather than about the thing being closed. Callers supply
/// only the machine and the count; nobody hand-rolls this string.
///
/// Returns the slice of `buf` that was written. `buf` should be at least
/// `text_cap` bytes; a shorter one falls back to the machine-less wording and,
/// failing even that, to the bare question.
pub fn informativeText(buf: []u8, machine: ?[]const u8, count: usize) []const u8 {
    // A name is used when there is one and it fits; otherwise the neutral
    // phrase, because naming the wrong place is worse than naming none.
    const place: []const u8 = blk: {
        const m = machine orelse break :blk "the remote machine";
        if (m.len == 0 or m.len > machine_name_cap) break :blk "the remote machine";
        break :blk m;
    };

    if (count <= 1) {
        return std.fmt.bufPrint(
            buf,
            "This session runs on {s}.\n" ++
                "Close ends the remote process; Disconnect leaves it running " ++
                "so you can resume it later.",
            .{place},
        ) catch "Close ends the remote process; Disconnect leaves it running.";
    }
    return std.fmt.bufPrint(
        buf,
        "{d} sessions run on {s}.\n" ++
            "Close ends those remote processes; Disconnect leaves them running " ++
            "so you can resume them later.",
        .{ count, place },
    ) catch "Close ends the remote processes; Disconnect leaves them running.";
}

/// A buffer this size always holds `informativeText`'s longest output.
pub const text_cap: usize = 160 + machine_name_cap;

/// The "Disconnect" pin, kept here rather than as a bare bool on `Surface` so
/// the ordering invariant it exists for is checkable without a desktop.
///
/// A single close marks its surfaces CLOSE-on-free from more than one place —
/// `Window.close` marks every pane in the window, `closeTabByIndex` marks every
/// pane in the tab, `closeSplitPane` marks the departing leaf — and which of
/// them runs, and in what order, varies with how the window was closed. Any one
/// of them firing after the user answered **Disconnect** would silently kill
/// the session they asked to keep. So the answer is recorded as a pin that
/// REFUSES later CLOSE markings, rather than as a one-shot
/// `setSessionCloseIntent(false)` that whichever marking ran last would
/// overwrite. Any future close bookkeeping inherits that protection for free.
pub const DetachPin = struct {
    pinned: bool = false,

    /// Record the user's Disconnect.
    pub fn pin(self: *DetachPin) void {
        self.pinned = true;
    }

    /// Release the pin: the surface is live again (a pane kept by a
    /// `+rearrange`, i.e. re-adopted into a tree that still references it), so
    /// a LATER close is a close like any other.
    pub fn clear(self: *DetachPin) void {
        self.pinned = false;
    }

    /// The intent to actually push down for a requested `close_on_free`
    /// marking, or null when the request must be REFUSED because honoring it
    /// would undo the pin. A DETACH marking is never refused — it agrees with
    /// the pin.
    pub fn resolve(self: DetachPin, close_on_free: bool) ?bool {
        if (close_on_free and self.pinned) return null;
        return close_on_free;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "machineIsDisconnectable: only a cross-machine window" {
    // A window dialed to another box hosts sessions worth keeping.
    try testing.expect(machineIsDisconnectable(true));
    // A plain local window, and a LOCAL session-persistence window (which has
    // no remote_machine), do not: closing a pane ends its session there, by
    // documented contract.
    try testing.expect(!machineIsDisconnectable(false));
}

test "isDisconnectable: a live terminal pane with confirmations on" {
    try testing.expect(isDisconnectable(.{
        .has_surface = true,
        .process_exited = false,
        .confirm_close_enabled = true,
    }));
}

test "isDisconnectable: a viewer pane has no session to keep" {
    try testing.expect(!isDisconnectable(.{
        .has_surface = false,
        .process_exited = false,
        .confirm_close_enabled = true,
    }));
}

test "isDisconnectable: an exited pane has nothing left to keep running" {
    try testing.expect(!isDisconnectable(.{
        .has_surface = true,
        .process_exited = true,
        .confirm_close_enabled = true,
    }));
}

test "isDisconnectable: confirm-close-surface = false means no prompt at all" {
    try testing.expect(!isDisconnectable(.{
        .has_surface = true,
        .process_exited = false,
        .confirm_close_enabled = false,
    }));
}

test "isDisconnectable: an IDLE remote pane still qualifies" {
    // Liveness is not one of the facts: idle-on-another-machine is exactly the
    // case this feature exists for, so nothing here can exclude it.
    const facts: PaneFacts = .{
        .has_surface = true,
        .process_exited = false,
        .confirm_close_enabled = true,
    };
    try testing.expect(isDisconnectable(facts));
}

test "informativeText: one session names the machine" {
    var buf: [text_cap]u8 = undefined;
    const text = informativeText(&buf, "winbox", 1);
    try testing.expect(std.mem.startsWith(u8, text, "This session runs on winbox."));
    try testing.expect(std.mem.indexOf(u8, text, "Disconnect leaves it running") != null);
}

test "informativeText: several sessions are counted and pluralized" {
    var buf: [text_cap]u8 = undefined;
    const text = informativeText(&buf, "winbox", 3);
    try testing.expect(std.mem.startsWith(u8, text, "3 sessions run on winbox."));
    try testing.expect(std.mem.indexOf(u8, text, "Disconnect leaves them running") != null);
}

test "informativeText: no name falls back to neutral phrasing" {
    var buf: [text_cap]u8 = undefined;
    try testing.expect(std.mem.startsWith(
        u8,
        informativeText(&buf, null, 1),
        "This session runs on the remote machine.",
    ));
    try testing.expect(std.mem.startsWith(
        u8,
        informativeText(&buf, "", 1),
        "This session runs on the remote machine.",
    ));
}

test "informativeText: an absurd hostname is dropped, never truncated" {
    var buf: [text_cap]u8 = undefined;
    const long = "a" ** (machine_name_cap + 1);
    const text = informativeText(&buf, long, 2);
    try testing.expect(std.mem.startsWith(u8, text, "2 sessions run on the remote machine."));
}

test "informativeText: a buffer too small still says the important half" {
    var small: [8]u8 = undefined;
    const text = informativeText(&small, "winbox", 1);
    try testing.expect(std.mem.indexOf(u8, text, "Disconnect leaves it running") != null);
}

test "DetachPin: unpinned passes every marking through" {
    const p: DetachPin = .{};
    try testing.expectEqual(@as(?bool, true), p.resolve(true));
    try testing.expectEqual(@as(?bool, false), p.resolve(false));
}

test "DetachPin: a pin refuses CLOSE and still allows DETACH" {
    var p: DetachPin = .{};
    p.pin();
    // The whole point: a later CLOSE marking is refused, not applied.
    try testing.expectEqual(@as(?bool, null), p.resolve(true));
    // A DETACH marking agrees with the pin, so it is never refused.
    try testing.expectEqual(@as(?bool, false), p.resolve(false));
}

test "DetachPin: repeated CLOSE markings in any order cannot beat the pin" {
    // The ordering invariant: Window.close marks the window, closeTabByIndex
    // marks the tab and closeSplitPane marks the leaf, in an order that varies
    // by close path. None of them may undo the answer.
    var p: DetachPin = .{};
    p.pin();
    for (0..5) |_| try testing.expectEqual(@as(?bool, null), p.resolve(true));
    try testing.expect(p.pinned);
}

test "DetachPin: re-adoption releases it so a later close closes" {
    var p: DetachPin = .{};
    p.pin();
    p.clear();
    try testing.expectEqual(@as(?bool, true), p.resolve(true));
}
