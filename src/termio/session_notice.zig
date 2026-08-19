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
//! module is the notice AND the terminal moves that keep it above the shell:
//! bytes in, bytes out, plus `foldIntoScrollback` / `trackFold` / `holdAbove`
//! (T423), which need a `Terminal` but still no allocator and no I/O — so both
//! the exact text and its placement are unit-testable in the none-runtime lane
//! rather than only observable by driving a GUI.
//!
//! SANITIZING IS THE POINT, not a nicety. The command text is DATA that came
//! off a disk file written by another process, and we are about to write it
//! into a VT parser. An unsanitized `\x1b]0;pwned\x07` (or a bare `\r`, or a
//! newline that breaks the block into a fake second line) would be executed as
//! terminal control by the very pane that is supposed to be showing it inertly.
//! Every C0/C1 control byte and DEL becomes a space here, before it can mean
//! anything.

const std = @import("std");
const terminal = @import("../terminal/main.zig");

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
/// refused to re-run.
///
/// WORDING IS PART OF THE CONTRACT (T424). Both carriers open with the same
/// sentence, in the same shape: a `Label:` — a **colon**, never an em dash —
/// followed by the reason in lower case. The user asked for it by name
/// (*"I expected the messaging to NOT have a long emdash in it, but rather a
/// colon (Session interrupted: <reason>)"*), and the two carriers previously
/// said the same thing two different ways: `--- session interrupted: … ---`
/// in the stream, `**Session interrupted** — …` in the banner. If you change
/// one of these strings, change the other, and keep the tests below pinned to
/// the exact user-visible text rather than loosening them — pinning it is the
/// reason this module is pure.
///
/// `command` is the agent's recorded label, or null when the
/// agent never recorded one / is too old to report it — in which case the
/// "Previous command" line is simply omitted rather than printed empty.
///
/// Returns a slice of `buf`. `buf` must be at least `max_len` bytes; a shorter
/// buffer yields as much of the notice as fits (never a partial escape
/// sequence, never a panic) because a truncated notice still beats no pane.
pub fn format(buf: []u8, command: ?[]const u8) []const u8 {
    var w: Writer = .{ .buf = buf };

    w.put("\r\n\x1b[2mSession interrupted: the background terminal process was restarted, so this session was closed.\x1b[0m\r\n");

    if (sanitizedCommand(command)) |cmd| {
        var cmd_buf: [max_command_len + 3]u8 = undefined;
        w.put("\x1b[2m    Previous command:\x1b[0m ");
        w.put(sanitize(&cmd_buf, cmd));
        w.put("\r\n");
    }

    w.put("\x1b[2m    Nothing was re-run; this is a fresh shell.\x1b[0m\r\n");
    return w.written();
}

/// Move everything above the cursor off the active screen and into the
/// SCROLLBACK, then re-home. Call it on the last tick before the child's first
/// bytes are parsed — NOT where the notice is written, since a pane is still
/// being resized during bring-up and only `trackFold`/`holdAbove` defend
/// against what a resize does afterwards.
///
/// T423 — this is what makes the in-stream notice actually survive, and the
/// user asked for it by name: *"I expected the session interrupted message to
/// be displayed inline, above the shell content but within the console
/// logging."*
///
/// The scrollback is the only place it can live. A ConPTY child does not print
/// into our terminal, it hands conhost's whole 80x25 screen buffer to us as
/// ABSOLUTELY POSITIONED VT — a fresh `cmd.exe` opens with `ESC[H ESC[2J`
/// (measured on box), and every later repaint addresses rows from the top of
/// the viewport. So notice text left on the active screen is erased by that
/// first clear, and notice text that somehow survived would only shift conhost's
/// coordinate frame down and get painted over anyway. Above the viewport is the
/// one region conhost never addresses, and `ESC[2J` does not reach it.
///
/// `cursor.y` is the exact row count of everything written since the pane came
/// up, wrapping included — the notice ends every line with CRLF, so the cursor
/// sits on the first row below it. Scrolling by that much puts the notice
/// directly above the shell's first line with no blank filler between them.
///
/// T922: "everything written" is now the notice AND, above it, the restored
/// screen of the session that was lost (`termio.Remote` paints its persisted
/// snapshot first). One fold carries both, which is why that paint needs no park
/// of its own — and why this must keep measuring the cursor rather than the
/// notice's own known height.
///
/// Re-homing afterwards is not cosmetic. Conhost believes the cursor is at
/// (1,1) when the child starts; a shell flavor that does NOT open with a
/// repaint (the measurement is `cmd.exe`-specific) would otherwise paint from
/// wherever the notice left us, offset from conhost's model of the same screen.
pub fn foldIntoScrollback(t: *terminal.Terminal) void {
    const rows_used = t.screens.active.cursor.y;
    if (rows_used > 0) t.scrollUp(rows_used) catch |err| {
        // Out of memory growing the scrollback. The notice is a courtesy and
        // the pane is the product: leave the text where it is (the shell's
        // repaint will take it) rather than fail the bring-up.
        std.log.warn("session notice: fold into scrollback failed err={}", .{err});
    };
    t.setCursorPos(1, 1);
}

/// Start tracking the first row BELOW a just-folded notice, so `holdAbove` can
/// keep it there. Returns null if the pin cannot be made; the notice is a
/// courtesy and must never be a reason a pane fails to come up.
///
/// A tracked pin is the only handle that survives a reflow — it is what ghostty
/// tracks selections with — and a reflow is precisely the event this exists to
/// defend against. Row counts, history depths and byte offsets are all re-wrapped
/// out from under you when the pane changes width; the pin is not.
pub fn trackFold(t: *terminal.Terminal) ?*terminal.Pin {
    const p = t.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse return null;
    return t.screens.active.pages.trackPin(p) catch |err| {
        std.log.warn("session notice: could not track the fold err={}", .{err});
        return null;
    };
}

/// Put the notice back above the viewport if a resize dragged it down into it,
/// and do nothing otherwise. Call after every reflow for the pane's lifetime.
///
/// A ConPTY pane's viewport is mostly trailing blank rows — the shell paints
/// four lines into twenty — and ghostty's reflow refills those out of the
/// scrollback. So narrowing a pane pulls history DOWN into the active area,
/// where the child's next full repaint (conhost sends one after every resize)
/// erases it. Measured at 64x20 -> 31x20: the notice's last two lines came back
/// onto the screen and were gone a moment later. That is the reported bug — the
/// unsplit pane kept its whole notice, the split panes kept only the first line,
/// because only the split panes were narrowed.
///
/// `pin` marks the row after the notice, so its offset within the active area
/// is exactly how far the notice has been dragged in.
pub fn holdAbove(t: *terminal.Terminal, pin: *terminal.Pin) void {
    const pt = t.screens.active.pages.pointFromPin(.active, pin.*) orelse return;
    const rows = pt.coord().y;
    if (rows == 0) return;

    const old_x = t.screens.active.cursor.x;
    const old_y = t.screens.active.cursor.y;
    t.scrollUp(rows) catch |err| {
        std.log.warn("session notice: could not hold the notice above err={}", .{err});
        return;
    };
    // `scrollUp` restores the cursor to the row it was on, but every row moved
    // up by `rows` — leaving the cursor that far below its own content. Follow
    // the content instead.
    t.setCursorPos(@as(usize, if (old_y > rows) old_y - rows else 0) + 1, @as(usize, old_x) + 1);
}

/// Render the same notice as a **sticky pane banner**, as an OSC 7778 sequence
/// ready to be written into the pane's own stream (the app's stream handler
/// turns it into the native overlay).
///
/// The second carrier, and deliberately still here after T423 made the
/// in-stream copy survive. They are complementary, not redundant: the in-stream
/// text is real, selectable scrollback the user can COPY the old command out of
/// (which is the point of naming it at all), but it is ABOVE the viewport, so a
/// user who does not scroll never sees it. The banner is the copy that is on
/// screen without being asked.
///
/// T422 settled what it costs: the banner slot belongs to the PANE, and the
/// caller only emits this when that slot is genuinely free. A restored pane
/// whose own banner came back from the session-layout manifest keeps it — its
/// banner carries state unique to that pane, while this sentence is identical in
/// every one of them — and a pane that had no banner still gets the notice on
/// screen for free. See `termio.Remote.Config.pane_banner_restored`.
pub fn formatBanner(buf: []u8, command: ?[]const u8) []const u8 {
    var w: Writer = .{ .buf = buf };
    w.put("\x1b]7778;**Session interrupted:** the background terminal process was restarted, so this session was closed. Nothing was re-run; this is a fresh shell.");
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
/// Whitespace-only is treated as absent: a line reading "Previous command:"
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

    try testing.expect(std.mem.indexOf(u8, out, "Session interrupted: the background terminal process was restarted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Previous command:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig build -Doptimize=Debug") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Nothing was re-run") != null);
}

test "format: the label is a colon, never an em dash" {
    // T424, verbatim from the user: "I expected the messaging to NOT have a long
    // emdash in it, but rather a colon (Session interrupted: <reason>)." Asserted
    // on BOTH carriers here, because the bug was that they diverged.
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    var banner_buf: [max_len]u8 = undefined;

    for ([_][]const u8{
        format(&buf, "zig build"),
        formatBanner(&banner_buf, "zig build"),
    }) |out| {
        try testing.expect(std.mem.indexOf(u8, out, "—") == null); // em dash
        try testing.expect(std.mem.indexOf(u8, out, "–") == null); // en dash
        try testing.expect(std.mem.indexOf(u8, out, "---") == null); // the old divider rule
        try testing.expect(std.mem.indexOf(u8, out, "Session interrupted:") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Previous command:") != null);
    }
}

test "format: no recorded command omits the command line entirely" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, null);

    try testing.expect(std.mem.indexOf(u8, out, "Session interrupted:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Previous command") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Nothing was re-run") != null);
}

test "format: a whitespace-only command counts as no command" {
    const testing = std.testing;
    var buf: [max_len]u8 = undefined;
    const out = format(&buf, "   \t\r\n ");
    try testing.expect(std.mem.indexOf(u8, out, "Previous command") == null);
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
    // Everything between "Previous command: " and the trailing "..." must be
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

test "foldIntoScrollback: the notice lands above the viewport, not on it" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 24, .rows = 6, .max_scrollback = 4096 });
    defer t.deinit(alloc);

    try t.printString("Session interrupted:\nPrevious command: x\nNothing was re-run\n");
    // The notice ends every line with CRLF, so the cursor sits one row below it
    // and its row count is exact.
    try testing.expectEqual(@as(usize, 3), @as(usize, t.screens.active.cursor.y));

    foldIntoScrollback(&t);

    const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(view);
    try testing.expect(std.mem.indexOf(u8, view, "Session interrupted") == null);

    // Gone from the screen the shell is about to repaint, still in the
    // scrollback the user scrolls back through.
    const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "Session interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, all, "Previous command: x") != null);
    try testing.expect(std.mem.indexOf(u8, all, "Nothing was re-run") != null);

    // Homed, so a shell that does not open with a repaint still agrees with
    // conhost about where (1,1) is.
    try testing.expectEqual(@as(usize, 0), @as(usize, t.screens.active.cursor.x));
    try testing.expectEqual(@as(usize, 0), @as(usize, t.screens.active.cursor.y));
}

test "foldIntoScrollback: a wrapped line is folded by its REAL height" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 6, .max_scrollback = 4096 });
    defer t.deinit(alloc);

    // Twenty columns of text in a ten-column pane: two rows, not one. A fold
    // that counted notice LINES instead of reading the cursor would leave the
    // second half on screen for the shell's clear to eat.
    try t.printString("0123456789abcdefghij\n");
    try testing.expectEqual(@as(usize, 2), @as(usize, t.screens.active.cursor.y));

    foldIntoScrollback(&t);

    const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(view);
    try testing.expect(std.mem.indexOf(u8, view, "abcdefghij") == null);
    try testing.expect(std.mem.indexOf(u8, view, "0123456789") == null);
}

test "foldIntoScrollback: the whole notice survives the child's full-screen erase" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Narrow enough that every notice line wraps — the shape of a split pane,
    // which is where the first version of this fix lost the last two lines.
    var t = try terminal.Terminal.init(alloc, .{ .cols = 34, .rows = 8, .max_scrollback = 4096 });
    defer t.deinit(alloc);

    // The notice's own text, minus the SGR runs (printString has no parser and
    // would print a bare CR as a glyph; its `\n` is the same CR+LF the notice
    // emits). Layout is what is under test, not the escapes.
    try t.printString(
        "\nSession interrupted: the background terminal process was restarted, so this session was closed.\n" ++
            "    Previous command: ping -n 9717 127.0.0.1\n" ++
            "    Nothing was re-run; this is a fresh shell.\n",
    );
    foldIntoScrollback(&t);

    // What the fresh ConPTY shell does microseconds later.
    t.eraseDisplay(.complete, false);

    const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(all);
    const tight = try std.mem.replaceOwned(u8, alloc, all, "\n", "");
    defer alloc.free(tight);
    try testing.expect(std.mem.indexOf(u8, tight, "Session interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, tight, "ping -n 9717 127.0.0.1") != null);
    try testing.expect(std.mem.indexOf(u8, tight, "Nothing was re-run") != null);
}

test "foldIntoScrollback: survives the erase at every plausible pane geometry" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const body =
        "\nSession interrupted: the background terminal process was restarted, so this session was closed.\n" ++
        "    Previous command: ping -n 9717 127.0.0.1\n" ++
        "    Nothing was re-run; this is a fresh shell.\n";

    // A restored pane can be any shape, and the notice is several wrapped rows
    // in the narrow ones — including shapes where it is TALLER than the pane,
    // so rows scroll into the scrollback while it is still being printed and
    // `cursor.y` saturates. Every one of these must still keep the last line.
    for ([_]u16{ 12, 20, 34, 40, 60, 80, 120 }) |cols| {
        for ([_]u16{ 3, 4, 5, 8, 12, 24, 40 }) |rows| {
            var t = try terminal.Terminal.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = 4096,
            });
            defer t.deinit(alloc);

            try t.printString(body);
            foldIntoScrollback(&t);
            t.eraseDisplay(.complete, false);

            const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
            defer alloc.free(all);
            const tight = try std.mem.replaceOwned(u8, alloc, all, "\n", "");
            defer alloc.free(tight);
            testing.expect(std.mem.indexOf(u8, tight, "Nothing was re-run") != null) catch |err| {
                std.debug.print("lost the notice at {d}x{d}: '{s}'\n", .{ cols, rows, all });
                return err;
            };
        }
    }
}

test "foldIntoScrollback: a bring-up resize BEFORE the fold is harmless" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This is the ordering rule the caller has to honour, and it is not
    // cosmetic. A restored pane is not done resizing when the notice is
    // written: creating the sibling of a split NARROWS it, and a narrowing
    // reflow re-wraps scrollback rows back onto the active screen, where the
    // fresh shell's `ESC[H ESC[2J` erases them. Measured on box at 100x12 ->
    // 40x12: fold-then-reflow lost the last two lines of the notice (which is
    // exactly what the split panes showed and the unsplit pane did not).
    //
    // Reflow-then-fold cannot lose anything, because the notice is still on the
    // active screen when the re-wrap happens and `cursor.y` is read afterwards.
    // So `Remote` folds from the drain, on the last tick before the child's
    // first bytes are parsed.
    for ([_][4]u16{
        .{ 40, 6, 40, 24 }, // grow rows
        .{ 40, 24, 40, 6 }, // shrink rows
        .{ 40, 12, 100, 12 }, // widen (reflow)
        .{ 100, 12, 40, 12 }, // narrow (reflow) — the measured failure
        .{ 34, 5, 120, 40 }, // both, hard
    }) |g| {
        var t = try terminal.Terminal.init(alloc, .{
            .cols = g[0],
            .rows = g[1],
            .max_scrollback = 4096,
        });
        defer t.deinit(alloc);

        try t.printString(
            "\nSession interrupted: the background terminal process was restarted, so this session was closed.\n" ++
                "    Previous command: ping -n 9717 127.0.0.1\n" ++
                "    Nothing was re-run; this is a fresh shell.\n",
        );
        try t.resize(alloc, g[2], g[3]);
        foldIntoScrollback(&t);
        t.eraseDisplay(.complete, false);

        const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(all);
        const tight = try std.mem.replaceOwned(u8, alloc, all, "\n", "");
        defer alloc.free(tight);
        testing.expect(std.mem.indexOf(u8, tight, "Nothing was re-run") != null) catch |err| {
            std.debug.print("lost the notice across {d}x{d} -> {d}x{d}\n", .{ g[0], g[1], g[2], g[3] });
            return err;
        };
    }
}

test "holdAbove: a narrowing reflow drags the notice back, and the guard puts it away" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // THE measured bug, at the measured geometry. Restore opens the pane at the
    // window's full width and writes the notice; creating the split's sibling
    // then narrows it. Ghostty's reflow refills a blank viewport out of the
    // scrollback, so the tail of the notice lands back on the active screen -
    // and the shell's next full repaint (conhost sends one after every resize)
    // erases it. On box that showed up as the unsplit pane keeping the whole
    // notice while the split panes kept only its first line.
    var t = try terminal.Terminal.init(alloc, .{ .cols = 64, .rows = 20, .max_scrollback = 4096 });
    defer t.deinit(alloc);

    try t.printString(
        "\nSession interrupted: the background terminal process was restarted, so this session was closed.\n" ++
            "    Previous command: ping -n 9778 127.0.0.1\n" ++
            "    Nothing was re-run; this is a fresh shell.\n",
    );
    foldIntoScrollback(&t);
    const guard = trackFold(&t).?;
    defer t.screens.active.pages.untrackPin(guard);
    {
        const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(view);
        try testing.expectEqualStrings("", view);
    }

    // The child paints, the way it does after every bring-up.
    try t.printString("Microsoft Windows [Version 10.0.26200.8973]\nC:\\work>");

    try t.resize(alloc, 31, 20);
    {
        // Not an aspiration - this is what the terminal DOES, and the whole
        // reason the guard exists rather than a single well-timed fold.
        const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(view);
        try testing.expect(std.mem.indexOf(u8, view, "Nothing was re-run") != null);
    }

    holdAbove(&t, guard);
    {
        const view = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(view);
        try testing.expect(std.mem.indexOf(u8, view, "Nothing was re-run") == null);
        // The child's own content stays where the child can see it.
        try testing.expect(std.mem.indexOf(u8, view, "Microsoft Windows") != null);
    }

    // And what the child does next cannot reach it.
    t.eraseDisplay(.complete, false);
    const all = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(all);
    const tight = try std.mem.replaceOwned(u8, alloc, all, "\n", "");
    defer alloc.free(tight);
    try testing.expect(std.mem.indexOf(u8, tight, "Session interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, tight, "ping -n 9778 127.0.0.1") != null);
    try testing.expect(std.mem.indexOf(u8, tight, "Nothing was re-run") != null);
}

test "holdAbove: does nothing when the notice is already above the viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 40, .rows = 10, .max_scrollback = 4096 });
    defer t.deinit(alloc);

    try t.printString("--- session interrupted ---\n");
    foldIntoScrollback(&t);
    const guard = trackFold(&t).?;
    defer t.screens.active.pages.untrackPin(guard);

    try t.printString("C:\\work>dir\nvolume label\nC:\\work>");
    const before = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(before);

    // The guard runs after every resize for the pane's whole life, so the case
    // that must cost nothing is the one that happens every time.
    holdAbove(&t, guard);
    const after = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
    defer alloc.free(after);
    try testing.expectEqualStrings(before, after);
}

test "foldIntoScrollback: an empty screen is a homing no-op" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(alloc, .{ .cols = 24, .rows = 6, .max_scrollback = 4096 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    foldIntoScrollback(&t);
    try testing.expectEqual(@as(usize, 0), @as(usize, t.screens.active.cursor.x));
    try testing.expectEqual(@as(usize, 0), @as(usize, t.screens.active.cursor.y));
}

test "format: a short buffer truncates instead of overflowing" {
    const testing = std.testing;
    var buf: [16]u8 = undefined;
    const out = format(&buf, "cmd");
    try testing.expect(out.len <= buf.len);
}
