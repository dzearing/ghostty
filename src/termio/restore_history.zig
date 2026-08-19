//! T922: bringing the dead session's last screen back on the `restore` path.
//!
//! When the local agent restarts (a reboot, or the mandatory agent upgrade) the
//! default `restore` policy refuses to put the recorded command back on a CPU
//! and opens a BRAND-NEW session instead (T230, `session_notice`). Until D78
//! that also meant the pane came back EMPTY: the app's own persisted screen
//! snapshot (WP-D3, `Remote.restore_snapshot`) was deliberately not painted for
//! this path, on the argument that a fresh shell showing an old screen is a lie
//! about what the pane is. The Mac keeps the dead session's scrollback, and the
//! user settled the divergence in favour of the Mac (D78, 2026-08-18):
//!
//! > you can read the error, the build output or the last thing your agent said
//! > before the reboot took it
//!
//! So the restored screen is painted ABOVE the notice, and the notice's own fold
//! (`session_notice.foldIntoScrollback`) carries both into the scrollback before
//! the fresh shell's first repaint can erase them.
//!
//! What lives here is the part that is pure arithmetic over bytes and flags —
//! whether there is anything worth painting, and what has to follow the paint —
//! so it is asserted in the `none` lane instead of only being observable by
//! rebooting a box. The caller (`Remote.threadEnter`) owns the terminal reads
//! and the writes. Same split as `restore_park.zig`.

const std = @import("std");
const testing = std.testing;

/// Leave the alternate screen, in the three spellings a snapshot can have
/// entered it with.
///
/// The snapshot is a structured repaint that reproduces the DIFFERING MODES it
/// recorded, alt-screen included (`Surface.sessionSnapshot`, `extra = .all`) —
/// so a pane that died inside a TUI comes back on the ALTERNATE screen. Left
/// there, the fresh shell would run inside the alt screen: no scrollback to
/// scroll, and the notice folded above a viewport nobody can reach. The
/// restored alt-screen content is lost by leaving it (an alt screen has no
/// history to keep), which is the pre-D78 outcome for that one pane shape and
/// strictly better than a pane the user cannot scroll.
///
/// Emitted ONLY when the terminal actually ended up on the alternate screen —
/// `switchScreenMode` restores the saved cursor / erases the display even when
/// the mode is already off, which on the overwhelmingly common primary-screen
/// snapshot would throw away the very rows this exists to keep. That is the
/// same trap `Remote.replay_mode_reset` documents and avoids by omission; here
/// the mode is READ first, so it can be spelled explicitly.
pub const alt_screen_exit =
    "\x1b[?1049l" ++ // xterm alt screen with cursor save/restore
    "\x1b[?1047l" ++ // alt screen, no cursor save
    "\x1b[?47l"; // the original DECSET alt screen

/// The persisted screen bytes to paint above the session-interrupted notice, or
/// null when this pane has nothing to bring back.
///
/// Null cases, all of them "restore the pre-D78 way" rather than errors — a
/// snapshot is a fidelity win layered on a restore that has to work without it:
///
///   - no snapshot at all: a hard crash before the first manifest write, a
///     legacy manifest, or a snapshot dropped for being over the layout file's
///     budget (`App.captureLeafSnapshot`).
///   - an EMPTY snapshot: a pane that had produced nothing worth capturing.
///   - `attach_offset == 0`: the offset is what says the snapshot reflects a
///     real stream position. `Surface.sessionSnapshot` refuses to record one at
///     offset 0 for the same reason, and the live-attach paint is gated on it
///     identically — so a pane the two paths disagree about cannot exist.
pub fn historyToPaint(snapshot: ?[]const u8, attach_offset: u64) ?[]const u8 {
    const snap = snapshot orelse return null;
    if (snap.len == 0) return null;
    if (attach_offset == 0) return null;
    return snap;
}

test "historyToPaint: a real snapshot at a real offset is painted" {
    const snap = "\x1b[H hello";
    try testing.expectEqualStrings(snap, historyToPaint(snap, 4096).?);
}

test "historyToPaint: no snapshot means nothing to bring back" {
    try testing.expect(historyToPaint(null, 4096) == null);
}

test "historyToPaint: an empty snapshot is not painted" {
    try testing.expect(historyToPaint("", 4096) == null);
}

test "historyToPaint: a snapshot at offset 0 is not painted" {
    try testing.expect(historyToPaint("\x1b[H hello", 0) == null);
}

test "alt_screen_exit leaves every alt-screen spelling" {
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "\x1b[?1049l") != null);
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "\x1b[?1047l") != null);
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "\x1b[?47l") != null);
}

test "alt_screen_exit does not home the cursor or erase the display" {
    // The whole point of gating it on the live mode is that it may not touch the
    // primary screen's rows. Anything that homes (CUP) or erases (ED) here would
    // do exactly that on the way back.
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "H") == null);
    try testing.expect(std.mem.indexOf(u8, alt_screen_exit, "J") == null);
}
