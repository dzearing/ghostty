//! The notice a restored pane prints when its persisted session did NOT come
//! back and we deliberately refused to re-run what it was running (T230).
//!
//! Background: when the local agent restarts (a reboot, or the mandatory
//! agent upgrade), it materializes its recorded sessions as dead-but-
//! relaunchable tombstones. The old default was to RELAUNCH the recorded
//! command in place. The user rejected that outright, verbatim: *"We should not
//! ever re-execute the commands which were previously ran, but, the console
//! message which says the session was closed could list the previous command
//! executed so the user can choose to copy/paste it."* Re-running a recorded
//! command is unsafe as a default — it was recorded in a world that no longer
//! exists, and nobody asked for it a second time.
//!
//! So the pane comes up on a FRESH shell and prints this notice above it. This
//! module is the notice itself and nothing else: bytes in, bytes out, no
//! allocator, no I/O — so the exact text is unit-testable in the none-runtime
//! lane rather than only observable by driving a GUI.
//!
//! SANITIZING IS THE POINT, not a nicety. The command text is DATA that came
//! off a disk file written by another process, and we are about to write it
//! into a VT parser. An unsanitized `\x1b]0;pwned\x07` (or a bare `\r`, or a
//! newline that breaks the block into a fake second line) would be executed as
//! terminal control by the very pane that is supposed to be showing it inertly.
//! Every C0/C1 control byte and DEL becomes a space here, before it can mean
//! anything.

const std = @import("std");

/// Longest command text rendered into the notice. A recorded command is
/// normally a shell path or a short argv label, but nothing guarantees that, and
/// a multi-kilobyte one would push the fresh prompt off the screen — the exact
/// opposite of "land the user at a usable shell". Longer text is truncated with
/// an ellipsis; the session is gone either way, so a clipped label costs the
/// user nothing they can't retype.
pub const max_command_len: usize = 240;

/// A buffer of this size always holds the full notice for any input. Sized from
/// the longest possible rendering: both fixed lines plus a max-length command
/// (doubled, since banner-markdown escaping can add one byte per byte).
pub const max_len: usize = 512 + max_command_len * 2;

/// Render the notice for a session whose process is gone and whose command we
/// refused to re-run. `command` is the agent's recorded label, or null when the
/// agent never recorded one / is too old to report it — in which case the
/// "previous command" line is simply omitted rather than printed empty.
///
/// Returns a slice of `buf`. `buf` must be at least `max_len` bytes; a shorter
/// buffer yields as much of the notice as fits (never a partial escape
/// sequence, never a panic) because a truncated notice still beats no pane.
pub fn format(buf: []u8, command: ?[]const u8) []const u8 {
    var w: Writer = .{ .buf = buf };

    w.put("\r\n\x1b[2m--- session interrupted: the background terminal process was restarted ---\x1b[0m\r\n");

    if (sanitizedCommand(command)) |cmd| {
        var cmd_buf: [max_command_len + 3]u8 = undefined;
        w.put("\x1b[2m    previous command:\x1b[0m ");
        w.put(sanitize(&cmd_buf, cmd));
        w.put("\r\n");
    }

    w.put("\x1b[2m    nothing was re-run; this is a fresh shell.\x1b[0m\r\n");
    return w.written();
}

/// Render the same notice as a **sticky pane banner**, as an OSC 7778 sequence
/// ready to be written into the pane's own stream (the app's stream handler
/// turns it into the native overlay).
///
/// This exists because the in-stream notice alone does not survive on Windows.
/// MEASURED on box: a fresh `cmd.exe` under ConPTY opens with its copyright
/// banner and a full-screen repaint (`ESC[H ESC[2J`), which erases everything
/// already on the pane — including a notice printed microseconds earlier. And
/// printing it AFTER the shell's paint would put it below the prompt, i.e.
/// below where the user is typing. The banner has neither problem: it is a
/// native overlay above the terminal content, so a screen clear cannot touch
/// it, and it stays put until it is replaced or cleared.
///
/// The two carriers are complementary, not redundant: the in-stream text is
/// real, selectable scrollback the user can COPY the old command out of (which
/// is the point of naming it at all), and the banner is the copy that is
/// guaranteed to still be on screen once the shell has finished painting.
pub fn formatBanner(buf: []u8, command: ?[]const u8) []const u8 {
    var w: Writer = .{ .buf = buf };
    w.put("\x1b]7778;**Session interrupted** — the background terminal process was restarted, so this session was closed. Nothing was re-run.");
    if (sanitizedCommand(command)) |cmd| {
        var cmd_buf: [max_command_len + 3]u8 = undefined;
        var esc_buf: [(max_command_len + 3) * 2]u8 = undefined;
        w.put(" Previous command: `");
        w.put(escapeMarkdown(&esc_buf, sanitize(&cmd_buf, cmd)));
        w.put("`");
    }
    w.put("\x07");
    return w.written();
}

/// Escape the banner-markdown metacharacters that would otherwise let a
/// recorded command restyle the banner — or, with a backtick, break OUT of the
/// code span it is quoted inside and have the rest of it parsed as markup.
/// `\` escapes the next character in that dialect, so it is escaped first.
fn escapeMarkdown(buf: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    for (src) |c| {
        if (n + 2 > buf.len) break;
        switch (c) {
            '\\', '`', '*', '_', '[', ']' => {
                buf[n] = '\\';
                n += 1;
            },
            else => {},
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// The command text to render, or null when there is nothing worth printing.
/// Whitespace-only is treated as absent: a line reading "previous command:"
/// followed by nothing is worse than no line at all.
fn sanitizedCommand(command: ?[]const u8) ?[]const u8 {
    const cmd = command orelse return null;
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Copy `src` into `buf` with every C0/C1 control byte and DEL replaced by a
/// space, truncated to `max_command_len` with a trailing `...`.
///
/// Truncation backs off to a UTF-8 boundary so a clipped multi-byte codepoint
/// cannot emit a lone continuation byte into the terminal. Bytes >= 0x80 are
/// otherwise passed through untouched: a command may legitimately contain a
/// non-ASCII path, and this is not the place to decide it is invalid.
fn sanitize(buf: []u8, src: []const u8) []const u8 {
    var end = @min(src.len, max_command_len);
    const truncated = end < src.len;
    if (truncated) {
        // Back off to a UTF-8 sequence boundary (continuation bytes are 10xxxxxx).
        while (end > 0 and src[end] & 0xC0 == 0x80) end -= 1;
    }

    var n: usize = 0;
    for (src[0..end]) |c| {
        buf[n] = if (c < 0x20 or c == 0x7f) ' ' else c;
        n += 1;
    }
    if (truncated) {
        @memcpy(buf[n..][0..3], "...");
        n += 3;
    }
    return buf[0..n];
}

/// A bounded appender: writes what fits and silently drops the rest. Deliberate —
/// the caller's job is to bring a pane up, and a notice that would not fit must
/// never be the thing that fails it.
const Writer = struct {
    buf: []u8,
    n: usize = 0,

    fn put(self: *Writer, s: []const u8) void {
        const room = self.buf.len - self.n;
        const take = @min(room, s.len);
        @memcpy(self.buf[self.n..][0..take], s[0..take]);
        self.n += take;
    }

    fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.n];
    }
};

test "format: names the command and says nothing was re-run" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "zig build -Doptimize=Debug");

    try testing.expect(std.mem.indexOf(u8, out, "session interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "background terminal process was restarted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "previous command:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig build -Doptimize=Debug") != null);
    try testing.expect(std.mem.indexOf(u8, out, "nothing was re-run") != null);
}

test "format: no recorded command omits the command line entirely" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, null);

    try testing.expect(std.mem.indexOf(u8, out, "session interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "previous command") == null);
    try testing.expect(std.mem.indexOf(u8, out, "nothing was re-run") != null);
}

test "format: a whitespace-only command counts as no command" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "   \t\r\n ");
    try testing.expect(std.mem.indexOf(u8, out, "previous command") == null);
}

test "format: control bytes in the command never reach the terminal" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    // An OSC that would retitle the window, a bare CR that would overwrite the
    // line, and a newline that would fake a second block line.
    const out = format(&buf, "sh -c 'x'\x1b]0;pwned\x07\rmore\nlines\x7f");

    // Exactly the two escape sequences the notice itself opens with per line,
    // and no smuggled ESC from the payload: count them.
    var esc: usize = 0;
    for (out) |c| {
        try testing.expect(c != '\x07');
        if (c == 0x1b) esc += 1;
    }
    // 2 per rendered line (open + reset) x 3 lines.
    try testing.expectEqual(@as(usize, 6), esc);
    try testing.expect(std.mem.indexOf(u8, out, "pwned") != null); // shown inertly
    try testing.expect(std.mem.indexOf(u8, out, "]0;pwned") != null);
}

test "format: quotes and backslashes are preserved verbatim" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const cmd = "pwsh -NoProfile -Command \"& 'C:\\a b\\x.ps1' --y=\\\"z\\\"\"";
    const out = format(&buf, cmd);
    try testing.expect(std.mem.indexOf(u8, out, cmd) != null);
}

test "format: an over-long command is truncated with an ellipsis" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    var long: [max_command_len * 3]u8 = undefined;
    @memset(&long, 'a');
    const out = format(&buf, &long);

    try testing.expect(out.len <= max_len);
    try testing.expect(std.mem.indexOf(u8, out, "aaa...") != null);
    // The whole overlong body must NOT be present.
    try testing.expect(std.mem.indexOf(u8, out, long[0 .. max_command_len + 1]) == null);
}

test "format: truncation never splits a UTF-8 codepoint" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    // Three-byte codepoints so the cut lands mid-sequence for some lengths.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    for (0..max_command_len) |_| try long.appendSlice(testing.allocator, "→");

    const out = format(&buf, long.items);
    // Everything between "previous command: " and the trailing "..." must be
    // valid UTF-8 — a split codepoint would fail this.
    const start = std.mem.indexOf(u8, out, "\x1b[0m ").? + 5;
    const end = std.mem.indexOf(u8, out[start..], "...").? + start;
    try testing.expect(std.unicode.utf8ValidateSlice(out[start..end]));
}

test "formatBanner: a well-formed OSC 7778 naming the command" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = formatBanner(&buf, "zig build -Doptimize=Debug");

    try testing.expect(std.mem.startsWith(u8, out, "\x1b]7778;"));
    try testing.expect(std.mem.endsWith(u8, out, "\x07"));
    try testing.expect(std.mem.indexOf(u8, out, "Session interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Nothing was re-run") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`zig build -Doptimize=Debug`") != null);
    // Exactly one BEL — the terminator. A payload that could inject its own
    // would end the sequence early and spill the rest onto the screen.
    var bel: usize = 0;
    for (out) |c| if (c == 0x07) {
        bel += 1;
    };
    try testing.expectEqual(@as(usize, 1), bel);
}

test "formatBanner: no command still produces a complete banner" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = formatBanner(&buf, null);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]7778;"));
    try testing.expect(std.mem.endsWith(u8, out, "\x07"));
    try testing.expect(std.mem.indexOf(u8, out, "Previous command") == null);
}

test "formatBanner: a command cannot break out of its code span or inject OSC" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    // Backtick closes the span; the rest would become live markdown, and the
    // BEL/ESC would end the OSC itself.
    const out = formatBanner(&buf, "sh -c '`**x**[a](b)`'\x07\x1b]0;t\x07");

    var bel: usize = 0;
    var esc: usize = 0;
    for (out) |c| {
        if (c == 0x07) bel += 1;
        if (c == 0x1b) esc += 1;
    }
    try testing.expectEqual(@as(usize, 1), bel); // only the terminator
    try testing.expectEqual(@as(usize, 1), esc); // only the introducer
    try testing.expect(std.mem.indexOf(u8, out, "\\`\\*\\*x\\*\\*\\[a\\](b)\\`") != null);
}

test "format: a short buffer truncates instead of overflowing" {
    const testing = std.testing;
    var buf: [16]u8 = undefined;
    const out = format(&buf, "cmd");
    try testing.expect(out.len <= buf.len);
}
