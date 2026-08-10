//! The message a pane shows when it could not RE-JOIN the session it was
//! supposed to come back to (T657).
//!
//! `open_failed_notice` is the same idea for a pane that never started; this is
//! the resume half, and it is the half a user meets after a reboot, after an
//! app upgrade, or when they pick a session out of the machine chooser. Until
//! now every one of those failures arrived at the pane as a bare
//! `error.RemoteAttachFailed`, so the generic IO-thread paint told the user
//! their pane was blank because the system was "exhausting a system resource" —
//! a sentence that is true of none of these and names none of them.
//!
//! Two things feed it, and the difference matters:
//!
//!   1. **The `ATTACHED.status` the agent already sent.** `not_found`, `dead`
//!      and `attached_elsewhere` are complete answers that arrive at once, on
//!      an agent of ANY age. `reasonForStatus` turns one into a token here, so
//!      the message costs no wire change and works against every agent that
//!      has ever shipped.
//!   2. **An `ATTACH_FAILED` token** (0x07), for the refusals no `Attached`
//!      payload can express — today a request the agent could not parse. That
//!      one IS capability-gated, so against an older agent the pane still takes
//!      the slow road (timeout, generic text), exactly as before.
//!
//! The MAPPING lives here, on the client, for the reason the agent contract
//! exists: the agent routinely outlives the app talking to it, so an agent that
//! shipped prose would pin this text to whatever build happens to be resident.
//!
//! Pure: bytes in, bytes out. No allocator, no terminal, no I/O — so the exact
//! user-visible text is pinned by unit tests in the none-runtime lane rather
//! than being observable only by wedging a real agent.
//!
//! Output is PLAIN TEXT with `\n` line breaks and no escape sequences (see
//! `open_failed_notice` for why the detail is sanitized).

const std = @import("std");

/// Longest agent-supplied detail rendered into the message.
pub const max_detail_len: usize = 160;

/// A buffer of this size always holds the full message for any input.
pub const max_len: usize = 640 + max_detail_len;

/// The first line, shared by every reason. It states the OUTCOME first, and it
/// is about THIS pane rather than about Ghoztty: the other panes in a restored
/// window are usually fine, and a message that reads like the app broke would
/// be a lie.
const headline = "Ghoztty could not reconnect this pane to its session.";

/// The reason tokens this module renders. A superset of
/// `protocol.AttachFailed.Reason`: the first three are derived CLIENT-side from
/// the `AttachStatus` the agent sent (see `reasonForStatus`), so they need no
/// wire support and work against an agent of any age.
pub const reason = struct {
    /// The agent has no session with that id — it was closed, reaped, or lost
    /// with the agent's own state.
    pub const session_not_found = "session_not_found";
    /// The session exists but its process is gone, and it cannot be revived.
    pub const session_ended = "session_ended";
    /// Another viewer holds the session, and we did not take it.
    pub const attached_elsewhere = "attached_elsewhere";
    /// The agent could not understand the request (wire token).
    pub const malformed_request = "malformed_request";
    /// The agent declined to take on the attachment (wire token).
    pub const attach_refused = "attach_refused";
};

/// The token for an `ATTACHED` reply that yielded no live pane.
///
/// `status` is `protocol.AttachStatus` spelled as its tag name, so this module
/// stays free of the protocol import (and therefore of the agent build) — the
/// one caller has the enum in hand and passes `@tagName`.
///
/// `attached_elsewhere` wins over the status because it is the more specific
/// fact: such a reply carries `status == .alive`, and "the session is alive"
/// is not the reason the pane has nothing to show.
pub fn reasonForStatus(status_tag: []const u8, elsewhere: bool) []const u8 {
    if (elsewhere) return reason.attached_elsewhere;
    if (std.mem.eql(u8, status_tag, "not_found")) return reason.session_not_found;
    if (std.mem.eql(u8, status_tag, "dead")) return reason.session_ended;
    // `.alive` with no pane and no steal is not a state the agent produces; if
    // it ever does, the generic sentence is the honest answer.
    return "unknown_status";
}

/// The explanation for each token, hard-wrapped the way the sibling messages in
/// `termio.Thread` are (the paint does not wrap, so the text carries its own
/// line breaks).
///
/// Every entry ends with what to DO. A failure message that explains without
/// suggesting leaves the reader exactly as stuck as a blank pane did.
fn explain(r: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, r, reason.session_not_found)) return
    \\The background terminal service no longer has the session this pane was
    \\restored from. It was most likely closed, or lost when the service last
    \\restarted.
    \\
    \\Close this pane and open a new one to start a fresh shell.
    ;
    if (eql(u8, r, reason.session_ended)) return
    \\The program this pane was running has ended, and the session cannot be
    \\started again.
    \\
    \\Close this pane and open a new one to start a fresh shell.
    ;
    if (eql(u8, r, reason.attached_elsewhere)) return
    \\This session is already open in another Ghoztty window, and a session can
    \\only be shown in one place at a time.
    \\
    \\Switch to the window that already has it, or close it there and try
    \\again.
    ;
    if (eql(u8, r, reason.malformed_request)) return
    \\The background terminal service could not understand the request to
    \\reconnect this pane. This is a bug; please report it.
    ;
    if (eql(u8, r, reason.attach_refused)) return
    \\The background terminal service declined to reconnect this pane right
    \\now.
    \\
    \\Close some panes or windows you are no longer using, then try again.
    ;
    // An unknown token — a NEWER agent naming a reason this build has not
    // learned yet, or a status we do not map. Say the true part and lean on the
    // detail below for the rest, rather than inventing an explanation or
    // discarding a refusal we were told about.
    return
    \\The background terminal service could not reconnect it, and this copy of
    \\Ghoztty does not recognize the reason it gave. That usually means the
    \\service is newer than the app.
    \\
    \\Restarting Ghoztty will bring the two back into step.
    ;
}

/// Render the pane message for an ATTACH that yielded no pane.
///
/// `r` is a token from `reason` (or an unrecognized one from a newer agent,
/// which is rendered generically and never echoed raw — it is a machine token,
/// not something a user should be shown). `detail` is free-form supporting text
/// and IS shown, sanitized and truncated.
///
/// Returns a slice of `buf`. `buf` must be at least `max_len` bytes; a shorter
/// buffer yields as much as fits rather than panicking, because a truncated
/// message still beats a blank pane.
pub fn format(buf: []u8, r: []const u8, detail: ?[]const u8) []const u8 {
    var w: Writer = .{ .buf = buf };

    w.put(headline);
    w.put("\n\n");
    w.put(explain(r));

    if (detail) |d| {
        if (d.len > 0) {
            w.put("\n\nDetails: ");
            w.putSanitized(d);
        }
    }

    return w.written();
}

/// Appends until the buffer is full, then silently stops. Every write here is a
/// fixed literal or a bounded, sanitized field, so "stops" only ever happens to
/// a caller that passed a buffer smaller than `max_len`.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Writer, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    /// Write agent-supplied text with every C0/C1 control byte and DEL replaced
    /// by a space, truncating past `max_detail_len` with an ellipsis.
    ///
    /// SANITIZING IS THE POINT, not a nicety: this text arrived over a socket
    /// from another process and is about to be written into a VT parser; an
    /// embedded escape sequence would be EXECUTED by the very pane that is
    /// supposed to be showing the failure inertly.
    fn putSanitized(self: *Writer, s: []const u8) void {
        const clipped = s.len > max_detail_len;
        const take = if (clipped) max_detail_len else s.len;
        for (s[0..take]) |c| {
            if (self.len >= self.buf.len) return;
            const safe: u8 = if (c < 0x20 or c == 0x7f or (c >= 0x80 and c <= 0x9f)) ' ' else c;
            self.buf[self.len] = safe;
            self.len += 1;
        }
        if (clipped) self.put("...");
    }

    fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

test "format: a missing session says so, and never blames a timeout" {
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, reason.session_not_found, null);

    try testing.expect(std.mem.startsWith(u8, out, headline));
    try testing.expect(std.mem.indexOf(u8, out, "no longer has the session") != null);
    // Actionable, not just descriptive.
    try testing.expect(std.mem.indexOf(u8, out, "open a new one") != null);
    // The sentence this whole task exists to delete.
    try testing.expect(std.mem.indexOf(u8, out, "Timeout") == null);
    try testing.expect(std.mem.indexOf(u8, out, "system resource") == null);
}

test "format: each known reason gets its own explanation" {
    const reasons = [_][]const u8{
        reason.session_not_found,
        reason.session_ended,
        reason.attached_elsewhere,
        reason.malformed_request,
        reason.attach_refused,
    };
    var seen: [reasons.len][]const u8 = undefined;
    for (reasons, 0..) |r, i| seen[i] = explain(r);

    // No two tokens render the same sentence — otherwise the token carries no
    // information to the reader and the distinction is decorative.
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
        // ...and none of them is the unknown-token fallback.
        try testing.expect(!std.mem.eql(u8, a, explain("no_such_reason_token")));
    }
}

test "format: an unknown reason is explained generically, never echoed raw" {
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "attach_quota_v9", null);

    try testing.expect(std.mem.indexOf(u8, out, "attach_quota_v9") == null);
    try testing.expect(std.mem.indexOf(u8, out, "does not recognize the reason") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Restarting Ghoztty") != null);
}

test "reasonForStatus: the status the agent already sent names the failure" {
    // The three that need no wire change: they ride `ATTACHED.status` and have
    // done since long before `attach_failed` existed, so they work against an
    // agent of any age. This is the load-bearing half of T657.
    try testing.expectEqualStrings(reason.session_not_found, reasonForStatus("not_found", false));
    try testing.expectEqualStrings(reason.session_ended, reasonForStatus("dead", false));

    // A steal reply carries `status == .alive`; "the session is alive" is not
    // why the pane is empty, so the more specific fact wins.
    try testing.expectEqualStrings(reason.attached_elsewhere, reasonForStatus("alive", true));
    try testing.expectEqualStrings(reason.attached_elsewhere, reasonForStatus("not_found", true));

    // A status we do not map renders the generic sentence rather than a wrong
    // one — and, crucially, is still a message rather than silence.
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, reasonForStatus("alive", false), null);
    try testing.expect(std.mem.indexOf(u8, out, "does not recognize") != null);
}

test "format: no detail means no Details line" {
    var buf: [max_len]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, format(&buf, reason.session_ended, null), "Details:") == null);
    try testing.expect(std.mem.indexOf(u8, format(&buf, reason.session_ended, ""), "Details:") == null);
}

test "format: control bytes in the detail are neutralized before they can mean anything" {
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, reason.malformed_request, "a\x1b]0;pwned\x07b\r\nc\x7f\u{009b}d");

    for (out) |c| {
        try testing.expect(c != 0x1b);
        try testing.expect(c != 0x07);
        try testing.expect(c != '\r');
        try testing.expect(c != 0x7f);
    }
    // The printable payload is still readable — it is text now, shown inertly.
    try testing.expect(std.mem.indexOf(u8, out, "pwned") != null);
    // The detail's own newline became a space, so it cannot forge an extra line.
    const details_at = std.mem.indexOf(u8, out, "Details: ").?;
    try testing.expect(std.mem.indexOfScalar(u8, out[details_at..], '\n') == null);
}

test "format: a long detail truncates with an ellipsis instead of running away" {
    var buf: [max_len]u8 = undefined;
    const long = "x" ** (max_detail_len * 3);
    const out = format(&buf, reason.session_not_found, long);

    try testing.expect(out.len < max_len);
    try testing.expect(std.mem.endsWith(u8, out, "..."));
    const details_at = std.mem.indexOf(u8, out, "Details: ").? + "Details: ".len;
    try testing.expectEqual(max_detail_len + 3, out.len - details_at);
}

test "format: a short buffer truncates rather than panicking" {
    var small: [12]u8 = undefined;
    const out = format(&small, reason.session_not_found, "x");
    try testing.expectEqual(@as(usize, 12), out.len);
    try testing.expectEqualStrings(headline[0..12], out);
}

test "max_len holds the longest message this module can produce" {
    // The buffer contract every caller relies on: a `[max_len]u8` is always
    // enough, so `format` never silently clips a real message.
    const reasons = [_][]const u8{
        reason.session_not_found,
        reason.session_ended,
        reason.attached_elsewhere,
        reason.malformed_request,
        reason.attach_refused,
        "an_unknown_token",
    };
    const long = "x" ** (max_detail_len * 2);
    for (reasons) |r| {
        var buf: [max_len]u8 = undefined;
        const out = format(&buf, r, long);
        try testing.expect(out.len < max_len);
    }
}
