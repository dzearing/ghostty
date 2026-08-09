//! The message a pane shows when the background terminal service REFUSED to
//! start a shell for it (T469).
//!
//! Background: a pane whose `OPEN` the agent will not honor used to come up
//! completely blank and stay that way for ten seconds, after which the generic
//! IO-thread failure paint blamed `error.Timeout` and "exhausting a system
//! resource" — a sentence that is true of no failure the user can act on and
//! names none of the ones they can. The agent knew exactly why it refused; it
//! simply had no frame to say so on. `protocol.open_failed` (0x06) is that
//! frame, and this module turns its machine token into the paragraph a person
//! reads.
//!
//! The MAPPING lives here, on the client, and not in the agent's wording, for
//! the reason the agent contract exists: the agent routinely outlives the app
//! talking to it, so an agent that shipped prose would pin this text to
//! whatever build happens to be resident. The agent sends a stable token; the
//! app owns the sentence and can improve it in any release.
//!
//! Pure: bytes in, bytes out. No allocator, no terminal, no I/O — so the exact
//! user-visible text is pinned by unit tests in the none-runtime lane rather
//! than being observable only by wedging a real agent.
//!
//! Output is PLAIN TEXT with `\n` line breaks and no escape sequences, because
//! its one consumer is `termio.Thread`'s failure paint, which hands it to
//! `Terminal.printString`. That is also why the detail is sanitized: it is data
//! the agent put on the wire, and a `\x1b]0;pwned\x07` in it must never reach a
//! parser as control.

const std = @import("std");

/// Longest agent-supplied detail rendered into the message. Longer text is
/// truncated with an ellipsis: the pane is dead either way, and a clipped
/// diagnostic costs the reader nothing the log does not still hold in full.
pub const max_detail_len: usize = 160;

/// A buffer of this size always holds the full message for any input.
pub const max_len: usize = 640 + max_detail_len;

/// The first line, shared by every reason. It states the OUTCOME — which is the
/// part the user needs before any explanation — and it is deliberately about
/// this pane, not about Ghoztty as a whole: the other panes in the window are
/// still fine, and a message that reads like the app broke would be a lie.
const headline = "Ghoztty could not start a shell for this pane.";

/// The explanation for each `protocol.OpenFailed.Reason` token, hard-wrapped
/// the way the sibling messages in `termio.Thread` are (the paint does not
/// wrap, so the text carries its own line breaks).
///
/// Every entry ends with what to DO. A failure message that explains without
/// suggesting leaves the reader exactly as stuck as a blank pane did.
fn explain(reason: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, reason, "session_cap")) return 
    \\The background terminal service is already running the maximum number
    \\of sessions, so it refused to start another one.
    \\
    \\Close some panes or windows you are no longer using, then try again.
    ;
    if (eql(u8, reason, "spawn_failed")) return 
    \\The background terminal service could not start the shell or command
    \\this pane asked for.
    \\
    \\Check that the shell path and the command exist and are runnable, then
    \\try again.
    ;
    if (eql(u8, reason, "out_of_memory")) return 
    \\The background terminal service ran out of memory while setting up the
    \\session.
    \\
    \\Close some panes or windows to free memory, then try again.
    ;
    if (eql(u8, reason, "malformed_request")) return 
    \\The background terminal service could not understand the request to
    \\open this pane. This is a bug; please report it.
    ;
    // An unknown token — i.e. a NEWER agent naming a reason this build has not
    // learned yet. Say the true part (it was refused, deliberately) and lean on
    // the detail below for the rest, rather than either inventing an
    // explanation or discarding a refusal we were told about.
    return 
    \\The background terminal service declined to start it. This copy of
    \\Ghoztty does not recognize the reason it gave, which usually means the
    \\service is newer than the app.
    \\
    \\Restarting Ghoztty will bring the two back into step.
    ;
}

/// Render the pane message for a refused `OPEN`.
///
/// `reason` is the wire token (`protocol.OpenFailed.Reason.*`); an unrecognized
/// one is rendered generically and is never echoed raw — it is a machine token,
/// not something a user should be shown. `detail` is the agent's free-form
/// supporting text and IS shown, sanitized and truncated, because it is the
/// only place the concrete numbers live (`live=256/256 …`).
///
/// Returns a slice of `buf`. `buf` must be at least `max_len` bytes; a shorter
/// buffer yields as much as fits rather than panicking, because a truncated
/// message still beats a blank pane — which is the whole point of the task.
pub fn format(buf: []u8, reason: []const u8, detail: ?[]const u8) []const u8 {
    var w: Writer = .{ .buf = buf };

    w.put(headline);
    w.put("\n\n");
    w.put(explain(reason));

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
    /// SANITIZING IS THE POINT, not a nicety — the same rule `session_notice`
    /// states for the same reason. This text arrived over a socket from another
    /// process and is about to be written into a VT parser; an embedded escape
    /// sequence would be EXECUTED by the very pane that is supposed to be
    /// showing the failure inertly.
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

test "format: names the cap and what to do about it" {
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "session_cap", "live=256/256 dead=3/256");

    // The outcome leads, before any explanation.
    try testing.expect(std.mem.startsWith(u8, out, headline));
    // The explanation is specific to the cap, and actionable.
    try testing.expect(std.mem.indexOf(u8, out, "maximum number") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Close some panes") != null);
    // The concrete numbers survive.
    try testing.expect(std.mem.indexOf(u8, out, "live=256/256 dead=3/256") != null);
    // And the old lie is gone: nothing here blames a timeout.
    try testing.expect(std.mem.indexOf(u8, out, "Timeout") == null);
}

test "format: each known reason gets its own explanation" {
    const reasons = [_][]const u8{ "session_cap", "spawn_failed", "out_of_memory", "malformed_request" };
    var seen: [reasons.len][]const u8 = undefined;
    for (reasons, 0..) |r, i| seen[i] = explain(r);

    // No two tokens render the same sentence — otherwise the token carries no
    // information to the reader and the wire distinction is decorative.
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
        // ...and none of them is the unknown-token fallback.
        try testing.expect(!std.mem.eql(u8, a, explain("no_such_reason_token")));
    }
}

test "format: an unknown reason is explained generically, never echoed raw" {
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "quota_exceeded_v9", null);

    // A newer agent's token is a machine string; showing it to a user would be
    // noise at best. The generic sentence carries the actionable part instead.
    try testing.expect(std.mem.indexOf(u8, out, "quota_exceeded_v9") == null);
    try testing.expect(std.mem.indexOf(u8, out, "does not recognize the reason") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Restarting Ghoztty") != null);
}

test "format: no detail means no Details line" {
    var buf: [max_len]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, format(&buf, "spawn_failed", null), "Details:") == null);
    try testing.expect(std.mem.indexOf(u8, format(&buf, "spawn_failed", ""), "Details:") == null);
}

test "format: control bytes in the detail are neutralized before they can mean anything" {
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "spawn_failed", "a\x1b]0;pwned\x07b\r\nc\x7f\u{009b}d");

    // Not one control byte survives into the text handed to the VT parser.
    for (out) |c| {
        try testing.expect(c != 0x1b);
        try testing.expect(c != 0x07);
        try testing.expect(c != '\r');
        try testing.expect(c != 0x7f);
    }
    // The printable payload is still readable (the escape's letters remain —
    // they are text now, which is exactly the intent: shown inertly).
    try testing.expect(std.mem.indexOf(u8, out, "pwned") != null);
    // Only the literal newlines this module wrote remain; the detail's own
    // newline became a space, so it cannot forge an extra line.
    const details_at = std.mem.indexOf(u8, out, "Details: ").?;
    try testing.expect(std.mem.indexOfScalar(u8, out[details_at..], '\n') == null);
}

test "format: a long detail truncates with an ellipsis instead of running away" {
    var buf: [max_len]u8 = undefined;
    const long = "x" ** (max_detail_len * 3);
    const out = format(&buf, "session_cap", long);

    try testing.expect(out.len < max_len);
    try testing.expect(std.mem.endsWith(u8, out, "..."));
    // Exactly `max_detail_len` of the detail survives, no more.
    const details_at = std.mem.indexOf(u8, out, "Details: ").? + "Details: ".len;
    try testing.expectEqual(max_detail_len + 3, out.len - details_at);
}

test "format: a short buffer truncates rather than panicking" {
    // A pane that can only show the first line is still infinitely better than
    // a blank one, so an undersized buffer must degrade, not crash.
    var small: [12]u8 = undefined;
    const out = format(&small, "session_cap", "live=1/1");
    try testing.expectEqual(@as(usize, 12), out.len);
    try testing.expectEqualStrings(headline[0..12], out);
}
