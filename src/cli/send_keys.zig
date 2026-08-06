const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,

    _arguments: std.ArrayList([:0]const u8) = .empty,

    _diagnostics: diagnostics.DiagnosticList = .{},

    target: ?[:0]const u8 = null,
    when_idle: bool = false,
    idle_timeout: u32 = 30,
    enter: bool = false,

    /// The first argument that looked like a flag and was not one. Reported
    /// by `runArgs` rather than thrown from `checkArg`, which has no writer
    /// to explain itself with.
    unknown_flag: ?[]const u8 = null,

    /// Set by a bare `--`: everything after it is a positional.
    flags_done: bool = false,

    /// `--help` past the first position, which `args.parse` only checks for
    /// at the front.
    help_requested: bool = false,

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    /// Classify one argument: a recognized flag is consumed and returns null,
    /// anything else comes back as a positional.
    ///
    /// An unrecognized `--flag` is an error rather than text. Falling through
    /// to text is how `--press-enter` used to get typed into the pane, exit 0,
    /// and leave the caller with no way to notice. Single-dash arguments stay
    /// text: `-la` and `-p` are ordinary content this command exists to send.
    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        if (!self.flags_done and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--")) {
                self.flags_done = true;
                return null;
            }
            if (std.mem.eql(u8, arg, "--help")) {
                self.help_requested = true;
                return null;
            }
            if (std.mem.eql(u8, arg, "--when-idle")) {
                self.when_idle = true;
                return null;
            }
            if (std.mem.eql(u8, arg, "--enter")) {
                self.enter = true;
                return null;
            }
            if (std.mem.startsWith(u8, arg, "--idle-timeout=")) {
                self.idle_timeout = std.fmt.parseInt(u32, arg["--idle-timeout=".len..], 10) catch return error.InvalidValue;
                return null;
            }
            if (std.mem.startsWith(u8, arg, "--target=")) {
                self.target = try alloc.dupeZ(u8, arg);
                return null;
            }
            if (self.unknown_flag == null) self.unknown_flag = try alloc.dupeZ(u8, arg);
            return null;
        }

        return try alloc.dupeZ(u8, arg);
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Send text input to a named pane's terminal.
///
/// TO SUBMIT, END THE TEXT WITH `\n`:
///
///   ghoztty +send-keys --target=term "hello\tworld\n"
///
/// `--enter`, or a separate `Enter` argument, do the same thing. Use
/// one, not two — they stack, and two of them submit twice.
///
/// Text is written to the target pane's PTY as if the user typed it.
/// Supports escape sequences and key notation for sending control
/// characters and special keys.
///
/// Flags:
///
///   * `--target=<name>`: The named pane or window to send input to.
///     Required. The target must have been created with
///     `+new-window --target=<name>` or `+split --name=<name>`.
///
///   * `--enter`: Press Enter after the text, submitting it. Same as
///     ending the text with `\n` or passing a trailing `Enter`
///     argument. On its own, with no text, it just presses Enter.
///
///   * `--when-idle`: Before sending, poll the target pane's recent
///     output every 500ms until it no longer looks busy (no
///     "esc to interrupt" in the last lines — the marker Claude Code
///     shows while working). Sends anyway once `--idle-timeout` elapses
///     or if the pane's output cannot be read.
///
///   * `--idle-timeout=<seconds>`: Max time to wait with `--when-idle`.
///     Default: 30.
///
/// Any other argument starting with `--` is an error rather than
/// text, so a misspelled flag is rejected instead of being typed into
/// the pane. To send literal text that starts with `--`, put it after
/// a bare `--`, which stops flag parsing:
///
///   ghoztty +send-keys --target=term -- "--not-a-flag\n"
///
/// Single-dash arguments (`-la`, `-p`) are ordinary text and need no
/// escaping.
///
/// Positional arguments are the text to send. Each argument is
/// checked for key notation first, then processed for escape
/// sequences:
///
///   * Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), etc.
///   * Named keys: `Enter`, `Tab`, `Escape`, `Space`
///   * Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`
///
/// A newline at the END of a text argument is a keypress, not content:
/// it is peeled off and delivered as Enter. Newlines in the MIDDLE
/// stay literal, so `"a\nb\n"` pastes two lines and then submits.
///
/// Why the distinction exists: argument boundaries are preserved, and
/// when a send mixes text with keys the text runs are delivered to the
/// pane as a bracketed paste while the keys are delivered bare. A
/// program that treats pasted input differently from typed input —
/// most full-screen TUIs do — can then tell them apart. Flattened into
/// one burst ending in `\r`, a TUI reads that `\r` as a newline inside
/// pasted text, which is exactly what a real multi-line paste looks
/// like, and the message sits unsent in the composer. Panes whose
/// program has not enabled bracketed paste receive the bytes
/// unwrapped, exactly as before.
///
/// Examples:
///
///   ghoztty +send-keys --target=term "hello\tworld\n"
///   ghoztty +send-keys --target=term "ls -la" Enter
///   ghoztty +send-keys --target=term --enter "ls -la"
///   ghoztty +send-keys --target=term C-c
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (opts.help_requested) return Action.help_error;

    // A flag we don't know is a caller who thinks they're doing something we
    // aren't doing. Name the submit spellings here rather than leaving them
    // to the docs — this message is where a wrong guess actually lands.
    if (opts.unknown_flag) |flag| {
        try stderr.print(
            \\+send-keys: unknown flag '{s}'.
            \\To submit, use --enter, a trailing \n, or a separate Enter argument.
            \\Valid flags: --target= --when-idle --idle-timeout= --enter
            \\To send literal text starting with '--', put it after '--'.
            \\
        , .{flag});
        return 1;
    }

    const target_arg = opts.target orelse {
        try stderr.print("+send-keys: --target is required\n", .{});
        return 1;
    };

    const text_args = try positionalArgs(alloc, &opts);

    if (text_args.len == 0) {
        try stderr.print("+send-keys: at least one text argument is required\n", .{});
        return 1;
    }

    // Process each text argument: resolve key notation and escape sequences
    const resolved = try resolveSegments(alloc, text_args);

    if (resolved.bytes.len == 0) {
        try stderr.print("+send-keys: resolved text is empty\n", .{});
        return 1;
    }

    // Build the IPC arguments: --target=<name> --keys=<processed bytes>
    const prefix = "--keys=";
    const keys_arg = try alloc.allocSentinel(u8, prefix.len + resolved.bytes.len, 0);
    @memcpy(keys_arg[0..prefix.len], prefix);
    @memcpy(keys_arg[prefix.len..][0..resolved.bytes.len], resolved.bytes);

    var ipc_args_buf: [3][:0]const u8 = .{ target_arg, keys_arg, undefined };
    var ipc_args: [][:0]const u8 = ipc_args_buf[0..2];

    // Only send the segmented payload when there is a boundary worth
    // preserving. A send that is all text or all keys has nothing to
    // disambiguate, so it stays byte-for-byte what it has always been —
    // and `--keys=` alone is what an older Ghoztty build understands, so
    // a CLI newer than the app it is driving degrades to that behaviour
    // rather than failing.
    if (resolved.segments.len > 1) {
        ipc_args_buf[2] = try encodeSegments(alloc, resolved.segments);
        ipc_args = ipc_args_buf[0..3];
    }

    if (opts.when_idle) {
        waitForIdle(
            alloc,
            target_arg["--target=".len..],
            opts.idle_timeout,
            stderr,
        );
    }

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .send_keys,
        .{
            .arguments = ipc_args,
        },
    ) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("+send-keys requires a running Ghoztty instance.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    // sendIpc already printed the server's error text (if any) to stderr.
    try stderr.print("+send-keys failed.\n", .{});
    return 1;
}

/// The positional arguments to resolve: everything that survived flag
/// parsing, plus the synthetic `Enter` that `--enter` stands for.
///
/// Appending the Enter here, rather than at resolve time, is what makes a
/// bare `--enter` with no text a legal send that just presses Enter — it is
/// already a positional by the time the "at least one text argument" check
/// runs.
fn positionalArgs(alloc: Allocator, opts: *const Options) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (opts._arguments.items) |arg| try out.append(alloc, arg);
    if (opts.enter) try out.append(alloc, "Enter");
    return out.items;
}

/// Poll the target pane's recent output until it no longer contains
/// "esc to interrupt" (shown by Claude Code and similar TUIs while
/// busy), then return. Returns early — allowing the send to proceed —
/// after `timeout_secs`, or immediately if the pane's output cannot be
/// read (e.g. the target is a window name rather than a pane).
fn waitForIdle(alloc: Allocator, name: []const u8, timeout_secs: u32, stderr: *std.Io.Writer) void {
    const read_cli = @import("read.zig");
    var remaining_polls: u64 = @as(u64, timeout_secs) * 2;
    while (remaining_polls > 0) : (remaining_polls -= 1) {
        const text = read_cli.queryPaneText(alloc, name, 10, stderr) catch return;
        if (std.mem.indexOf(u8, text, "esc to interrupt") == null) return;
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

/// A run of resolved bytes, tagged with how the receiving program should
/// understand it.
const Segment = struct {
    kind: Kind,
    bytes: []const u8,

    const Kind = enum {
        /// Content, from a text positional. Delivered as a paste.
        text,
        /// A keypress, from `Enter` / `C-c` / `Tab` / … Delivered bare.
        key,

        /// The tag this kind is encoded with on the wire.
        fn tag(self: Kind) u8 {
            return switch (self) {
                .text => 't',
                .key => 'k',
            };
        }
    };
};

const Resolved = struct {
    /// Every resolved byte, concatenated in argument order.
    bytes: []const u8,

    /// The same bytes, split at every text↔key boundary.
    segments: []const Segment,
};

/// Resolve the positional arguments into ordered segments, merging runs of
/// the same kind so the result alternates strictly between text and keys.
///
/// The boundary between a text run and the key run after it is the whole
/// point: flattening `"some message" Enter` into one buffer hands the
/// receiving program a single burst of bytes ending in `\r`, which paste
/// detection reads as a pasted newline instead of a submit.
///
/// The returned segments point into the returned `bytes`, and the scratch
/// used along the way is never freed, so pass an arena.
fn resolveSegments(
    alloc: Allocator,
    text_args: []const []const u8,
) Allocator.Error!Resolved {
    // Record spans rather than slices while filling `buf`: appending to it
    // can reallocate, which would dangle any slice taken earlier.
    const Span = struct { kind: Segment.Kind, start: usize, end: usize };

    var buf: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;

    // Add one run, extending the previous span when the kind matches. Runs
    // arrive contiguously, so extending its end is all a merge takes. An
    // empty run — an empty argument, or an argument that is all text or all
    // key — is not a segment.
    const push = struct {
        fn f(
            alloc_: Allocator,
            spans_: *std.ArrayList(Span),
            kind: Segment.Kind,
            start: usize,
            end: usize,
        ) Allocator.Error!void {
            if (start == end) return;

            if (spans_.items.len > 0) {
                const prev = &spans_.items[spans_.items.len - 1];
                if (prev.kind == kind) {
                    prev.end = end;
                    return;
                }
            }

            try spans_.append(alloc_, .{ .kind = kind, .start = start, .end = end });
        }
    }.f;

    for (text_args) |arg| {
        const start = buf.items.len;
        const split = try resolveArgument(alloc, &buf, arg);

        try push(alloc, &spans, .text, start, start + split.text_len);
        try push(alloc, &spans, .key, start + split.text_len, buf.items.len);
    }

    const segments = try alloc.alloc(Segment, spans.items.len);
    for (spans.items, segments) |span, *segment| segment.* = .{
        .kind = span.kind,
        .bytes = buf.items[span.start..span.end],
    };

    return .{ .bytes = buf.items, .segments = segments };
}

/// Encode segments as the `--segments=` IPC argument: a kind tag (`t`/`k`)
/// followed by the segment's bytes in lowercase hex, segments joined by `,`.
///
/// Hex because the payload travels as a JSON string, and these bytes are
/// arbitrary — control characters and non-UTF-8 sequences are exactly what
/// `+send-keys` exists to deliver, and neither survives that trip raw.
fn encodeSegments(alloc: Allocator, segments: []const Segment) Allocator.Error![:0]const u8 {
    const hex = "0123456789abcdef";

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "--segments=");

    for (segments, 0..) |segment, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, segment.kind.tag());
        for (segment.bytes) |byte| {
            try out.append(alloc, hex[byte >> 4]);
            try out.append(alloc, hex[byte & 0x0f]);
        }
    }

    return try out.toOwnedSliceSentinel(alloc, 0);
}

/// How one argument's resolved bytes divide, in order, into a leading text
/// run and a trailing key run. Either half can be empty: a key name is all
/// key, ordinary text is all text, and `"prompt\n"` is one of each.
const Split = struct {
    text_len: usize = 0,
    key_len: usize = 0,
};

/// Resolve a single argument: if it matches a key name, append its byte(s);
/// otherwise process escape sequences in the text and peel any trailing
/// newline off as a keypress. Returns how the appended bytes divide.
fn resolveArgument(alloc: Allocator, buf: *std.ArrayList(u8), arg: []const u8) Allocator.Error!Split {
    const start = buf.items.len;

    // Ctrl key notation: C-a through C-z (case insensitive)
    if (arg.len == 3 and arg[0] == 'C' and arg[1] == '-') {
        const ch = arg[2];
        if (ch >= 'a' and ch <= 'z') {
            try buf.append(alloc, ch - 'a' + 1);
            return .{ .key_len = 1 };
        }
        if (ch >= 'A' and ch <= 'Z') {
            try buf.append(alloc, ch - 'A' + 1);
            return .{ .key_len = 1 };
        }
    }

    // Named keys
    if (eqlIgnoreCase(arg, "Enter") or eqlIgnoreCase(arg, "Return") or eqlIgnoreCase(arg, "CR")) {
        try buf.append(alloc, '\r');
        return .{ .key_len = 1 };
    }
    if (eqlIgnoreCase(arg, "Tab")) {
        try buf.append(alloc, '\t');
        return .{ .key_len = 1 };
    }
    if (eqlIgnoreCase(arg, "Escape") or eqlIgnoreCase(arg, "Esc")) {
        try buf.append(alloc, 0x1b);
        return .{ .key_len = 1 };
    }
    if (eqlIgnoreCase(arg, "Space")) {
        try buf.append(alloc, ' ');
        return .{ .key_len = 1 };
    }
    if (eqlIgnoreCase(arg, "BSpace") or eqlIgnoreCase(arg, "Backspace")) {
        try buf.append(alloc, 0x7f);
        return .{ .key_len = 1 };
    }

    // Not a key name — process escape sequences in the text
    try processEscapes(alloc, buf, arg);

    // A newline at the END means submit, so it leaves the paste and becomes
    // Enter. Newlines in the MIDDLE are line breaks in the pasted content and
    // stay literal. This runs after escape processing, so `\n` written as the
    // two-character escape and a real newline byte are the same input.
    //
    // The cost, accepted deliberately: there is no way to paste text ending
    // in a literal newline without submitting. A trailing newline in a paste
    // means "commit" essentially always, and for a program that has not
    // enabled bracketed paste the tty's ICRNL maps the `\r` back to `\n`, so
    // `cat` and a script's `read` see what they always saw.
    var end = buf.items.len;
    while (end > start and (buf.items[end - 1] == '\n' or buf.items[end - 1] == '\r')) end -= 1;
    for (buf.items[end..]) |*byte| byte.* = '\r';

    return .{ .text_len = end - start, .key_len = buf.items.len - end };
}

/// Process escape sequences within a text string.
fn processEscapes(alloc: Allocator, buf: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            switch (text[i + 1]) {
                'n' => {
                    try buf.append(alloc, '\n');
                    i += 2;
                },
                't' => {
                    try buf.append(alloc, '\t');
                    i += 2;
                },
                'r' => {
                    try buf.append(alloc, '\r');
                    i += 2;
                },
                'e' => {
                    try buf.append(alloc, 0x1b);
                    i += 2;
                },
                '\\' => {
                    try buf.append(alloc, '\\');
                    i += 2;
                },
                '0' => {
                    try buf.append(alloc, 0);
                    i += 2;
                },
                else => {
                    try buf.append(alloc, text[i]);
                    i += 1;
                },
            }
        } else {
            try buf.append(alloc, text[i]);
            i += 1;
        }
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

test "resolveArgument C-c" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.testing.expectEqual(Split{ .key_len = 1 }, try resolveArgument(alloc, &buf, "C-c"));
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 3), buf.items[0]);
}

test "resolveArgument Enter" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.testing.expectEqual(Split{ .key_len = 1 }, try resolveArgument(alloc, &buf, "Enter"));
    try std.testing.expectEqualStrings("\r", buf.items);
}

test "resolveArgument plain text with escapes" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.testing.expectEqual(Split{ .text_len = 11 }, try resolveArgument(alloc, &buf, "hello\\nworld"));
    try std.testing.expectEqualStrings("hello\nworld", buf.items);
}

test "processEscapes tab" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try processEscapes(alloc, &buf, "col1\\tcol2");
    try std.testing.expectEqualStrings("col1\tcol2", buf.items);
}

// The invariant this whole change exists to protect: a text argument
// followed by a key argument must survive as two ordered segments. Flatten
// them and the receiving program cannot tell the trailing `\r` apart from a
// newline inside a paste, so `"some message" Enter` never submits.
test "resolveSegments keeps text and a following key apart" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{ "some message", "Enter" });

    try std.testing.expectEqualStrings("some message\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("some message", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments merges runs of the same kind" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Adjacent text args concatenate, as do adjacent keys, so the segment
    // list alternates and single-kind sends stay a single segment.
    const resolved = try resolveSegments(alloc, &.{ "vim", " -p", "Enter", "Escape", "iabc" });

    try std.testing.expectEqualStrings("vim -p\r\x1biabc", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 3), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("vim -p", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r\x1b", resolved.segments[1].bytes);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[2].kind);
    try std.testing.expectEqualStrings("iabc", resolved.segments[2].bytes);
}

test "resolveSegments single-argument forms stay one segment" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // These are the forms that must keep working byte-for-byte. One segment
    // means the CLI sends only `--keys=`, which is exactly the old payload.
    for ([_][]const u8{ "text", "Enter", "C-c" }) |arg| {
        const resolved = try resolveSegments(alloc, &.{arg});
        try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    }
}

test "resolveSegments skips arguments that resolve to nothing" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{ "", "hi", "", "Enter" });

    try std.testing.expectEqualStrings("hi\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
}

test "encodeSegments" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{ "hi", "Enter" });
    try std.testing.expectEqualStrings(
        "--segments=t6869,k0d",
        try encodeSegments(alloc, resolved.segments),
    );
}

// A trailing newline is the spelling agents reach for first, so it has to be
// the one that works. These pin the peel: the newline leaves the paste and
// becomes a keypress after it.

test "resolveSegments peels a trailing newline off as an Enter keypress" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{"prompt\\n"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments peels a real trailing newline byte the same way" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The peel runs after escape processing, so `\n` typed as a literal byte
    // and `\n` written as the two-character escape are the same input.
    const resolved = try resolveSegments(alloc, &.{"prompt\n"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
}

test "resolveSegments keeps an interior newline inside the pasted text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{"a\\nb\\n"});

    try std.testing.expectEqualStrings("a\nb\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("a\nb", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments treats a trailing carriage return like a newline" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{"prompt\\r"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
}

test "resolveSegments a newline-only argument is a key and nothing else" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{"\\n"});

    try std.testing.expectEqualStrings("\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[0].kind);
}

test "resolveSegments multiple trailing newlines are multiple presses" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try resolveSegments(alloc, &.{"prompt\\n\\n"});

    try std.testing.expectEqualStrings("prompt\r\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r\r", resolved.segments[1].bytes);
}

test "resolveSegments a trailing newline and a following Enter stack" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Both spellings submit, so writing both submits twice. Merging keeps the
    // result one key run rather than two adjacent ones.
    const resolved = try resolveSegments(alloc, &.{ "prompt\\n", "Enter" });

    try std.testing.expectEqualStrings("prompt\r\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r\r", resolved.segments[1].bytes);
}

/// Drive the flag parser the way `parseManuallyHook` does, so tests can assert
/// on what a whole argv resolves to.
fn parseForTest(alloc: Allocator, argv: []const []const u8) !Options {
    var opts: Options = .{};
    for (argv) |arg| {
        if (try opts.checkArg(alloc, arg)) |a| try opts._arguments.append(alloc, a);
    }
    return opts;
}

test "positionalArgs appends an Enter for --enter" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try parseForTest(alloc, &.{ "--target=t", "--enter", "prompt" });
    const positionals = try positionalArgs(alloc, &opts);

    try std.testing.expectEqual(@as(usize, 2), positionals.len);
    try std.testing.expectEqualStrings("prompt", positionals[0]);
    try std.testing.expectEqualStrings("Enter", positionals[1]);
}

test "positionalArgs --enter with no text still presses Enter" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The synthetic Enter is appended before the "at least one text argument"
    // check, which is what makes a bare `--enter` a legal send.
    const opts = try parseForTest(alloc, &.{ "--target=t", "--enter" });
    const positionals = try positionalArgs(alloc, &opts);

    try std.testing.expectEqual(@as(usize, 1), positionals.len);

    const resolved = try resolveSegments(alloc, positionals);
    try std.testing.expectEqualStrings("\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[0].kind);
}

test "checkArg rejects an unknown flag" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The whole point: a misspelled flag must not silently become text that
    // gets typed into the pane.
    const opts = try parseForTest(alloc, &.{ "--target=t", "--press-enter", "hi" });

    try std.testing.expect(opts.unknown_flag != null);
    try std.testing.expectEqualStrings("--press-enter", opts.unknown_flag.?);
}

test "checkArg single-dash arguments stay text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try parseForTest(alloc, &.{ "--target=t", "-la", "-p" });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expectEqual(@as(usize, 2), opts._arguments.items.len);
    try std.testing.expectEqualStrings("-la", opts._arguments.items[0]);
    try std.testing.expectEqualStrings("-p", opts._arguments.items[1]);
}

test "checkArg -- stops flag parsing" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try parseForTest(alloc, &.{ "--target=t", "--", "--when-idle", "--press-enter" });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expect(!opts.when_idle);
    try std.testing.expectEqual(@as(usize, 2), opts._arguments.items.len);
    try std.testing.expectEqualStrings("--when-idle", opts._arguments.items[0]);
    try std.testing.expectEqualStrings("--press-enter", opts._arguments.items[1]);
}

test "checkArg key notation still applies after --" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `--` stops flag interpretation, not argument resolution.
    const opts = try parseForTest(alloc, &.{ "--target=t", "--", "--flag", "Enter" });
    const resolved = try resolveSegments(alloc, try positionalArgs(alloc, &opts));

    try std.testing.expectEqualStrings("--flag\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Segment.Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("--flag", resolved.segments[0].bytes);
    try std.testing.expectEqual(Segment.Kind.key, resolved.segments[1].kind);
}

test "checkArg records the known flags" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try parseForTest(alloc, &.{
        "--target=dev",
        "--when-idle",
        "--idle-timeout=90",
        "--enter",
    });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expectEqualStrings("--target=dev", opts.target.?);
    try std.testing.expect(opts.when_idle);
    try std.testing.expectEqual(@as(u32, 90), opts.idle_timeout);
    try std.testing.expect(opts.enter);
    try std.testing.expectEqual(@as(usize, 0), opts._arguments.items.len);
}
