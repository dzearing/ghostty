const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

/// One surviving positional argument, plus whether it came after a bare
/// `--`.
///
/// The flag stops flag parsing but NOT key notation, so `-- Enter` is still
/// an Enter keypress. What it does stop is `--keys-file=`: after `--`, the
/// text `--keys-file=x` is the literal string a caller asked to send, not a
/// request to read a file. Carrying that as a field beats re-testing the
/// prefix later, which cannot tell the two apart at all.
const Positional = struct {
    text: [:0]const u8,
    after_dashdash: bool = false,
};

pub const Options = struct {
    _arena: ?ArenaAllocator = null,

    _arguments: std.ArrayList(Positional) = .empty,

    _diagnostics: diagnostics.DiagnosticList = .{},

    target: ?[:0]const u8 = null,
    when_idle: bool = false,
    idle_timeout: u32 = 30,
    _busy_markers: std.ArrayList([:0]const u8) = .empty,
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
    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?Positional {
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
            if (std.mem.startsWith(u8, arg, "--busy-marker=")) {
                const value = arg["--busy-marker=".len..];
                if (value.len == 0) return error.InvalidValue;
                try self._busy_markers.append(alloc, try alloc.dupeZ(u8, value));
                return null;
            }
            if (std.mem.startsWith(u8, arg, "--target=")) {
                self.target = try alloc.dupeZ(u8, arg);
                return null;
            }
            // `--keys-file=` is a RECOGNIZED flag that is deliberately not
            // consumed: it has to keep its position relative to the text
            // arguments so `--keys-file=p.txt Enter` sends the file and THEN
            // the carriage return. It rides along as a positional and is
            // expanded in resolveSegments.
            if (std.mem.startsWith(u8, arg, "--keys-file=")) {
                return .{ .text = try alloc.dupeZ(u8, arg) };
            }
            if (self.unknown_flag == null) self.unknown_flag = try alloc.dupeZ(u8, arg);
            return null;
        }

        return .{
            .text = try alloc.dupeZ(u8, arg),
            .after_dashdash = self.flags_done,
        };
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
///     output every 500ms until it no longer looks busy: the tail
///     unchanged across ~1s (busy TUIs animate spinners/timers; an
///     idle prompt is static) and no `--busy-marker` text present.
///     Sends anyway once `--idle-timeout` elapses or if the pane's
///     output cannot be read.
///
///   * `--idle-timeout=<seconds>`: Max time to wait with `--when-idle`.
///     Default: 30.
///
///   * `--busy-marker=<text>`: Extra busy signal for `--when-idle`:
///     while <text> appears in the pane's last lines, the pane counts
///     as busy even if its tail is static. May be given more than
///     once; any match counts. The CLI bakes in no particular tool's
///     chrome — a caller that knows what its program prints while
///     working passes it here.
///
///   * `--keys-file=<path>`: Send the file's bytes VERBATIM — no key
///     notation, no `\n` escape processing, no shell in the way. Use
///     this for any text a caller did not author by hand: a prompt, a
///     path, anything containing quotes or backslashes. It keeps its
///     position among the positional arguments, so
///     `--keys-file=p.txt Enter` sends the file and then a carriage
///     return. May be given more than once. The file is sent exactly
///     as it is on disk, trailing newline included — the trailing-
///     newline peel below does NOT apply to it, because "verbatim" is
///     the whole reason this flag exists and generated files routinely
///     end in a newline nobody meant as "submit". Use a following
///     `Enter` (or `--enter`) to submit a file.
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
/// A positional argument is the WRONG transport for generated text.
/// PowerShell 5.1 does not escape an embedded `"` when it builds a
/// native command line, so an argument containing one arrives with
/// its quotes stripped, re-tokenized and concatenated without
/// separators, or broken outright — which is how a `/reset-context`
/// resume prompt reached a pane as a fragment of prose and the reset
/// silently never fired (T210). Use `--keys-file=` there.
///
/// Argument boundaries are preserved. When a send mixes text with
/// keys, the text runs are delivered to the pane as a bracketed
/// paste and the keys are delivered bare, so a program that treats
/// pasted input differently from typed input — most full-screen
/// TUIs do — can tell them apart. That is what makes the trailing
/// `Enter` in `"some message" Enter` submit rather than land in the
/// buffer as a newline. Panes whose program has not enabled
/// bracketed paste receive the bytes unwrapped, exactly as before.
/// A `--keys-file=` payload is a text run like any other, so
/// `--keys-file=p.txt Enter` is the reliable shape for "send this
/// generated prompt, then submit it".
///
/// Examples:
///
///   ghoztty +send-keys --target=term "hello\tworld\n"
///   ghoztty +send-keys --target=term "ls -la" Enter
///   ghoztty +send-keys --target=term --enter "ls -la"
///   ghoztty +send-keys --target=term C-c
///   ghoztty +send-keys --target=term --keys-file=prompt.txt Enter
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
            \\Valid flags: --target= --when-idle --idle-timeout= --busy-marker= --keys-file= --enter
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

    // Resolve IN ORDER: a --keys-file= among the positional arguments
    // contributes its bytes where it appears, so `--keys-file=p.txt Enter`
    // sends the file and then the carriage return.
    var bad_file: ?[]const u8 = null;
    const resolved = resolveSegments(alloc, text_args, &bad_file) catch |err| {
        if (bad_file) |path| {
            try stderr.print(
                "+send-keys: cannot read --keys-file={s}: {s}\n",
                .{ path, @errorName(err) },
            );
        } else {
            try stderr.print("+send-keys: {s}\n", .{@errorName(err)});
        }
        return 1;
    };

    if (resolved.bytes.len == 0) {
        try stderr.print("+send-keys: resolved text is empty\n", .{});
        return 1;
    }

    // Build the IPC arguments: --target=<name> --keys=<processed bytes>
    const prefix = "--keys=";
    const keys_arg = try alloc.allocSentinel(u8, prefix.len + resolved.bytes.len, 0);
    @memcpy(keys_arg[0..prefix.len], prefix);
    @memcpy(keys_arg[prefix.len..][0..resolved.bytes.len], resolved.bytes);

    // T661: every keypress in the payload above is already the byte a terminal
    // sends for it — `Enter` and a peeled trailing newline are both CR — so an
    // interior LF that survived is content and must reach the pane as LF. The
    // marker says so, because the win32 server cannot tell these bytes from a
    // pre-T604 CLI's, where a bare `\n` did mean Enter, and rewrites them all
    // to CR when nobody says otherwise. A server that does not know the
    // argument ignores it.
    var ipc_args_buf: [4][:0]const u8 = .{
        target_arg,
        keys_arg,
        verb_args.keys_resolved_arg,
        undefined,
    };
    var ipc_args: [][:0]const u8 = ipc_args_buf[0..3];

    // Only send the segmented payload when there is a boundary worth
    // preserving. A send that is all text or all keys has nothing to
    // disambiguate, so it stays byte-for-byte what it has always been —
    // and `--keys=` alone is what an older Ghoztty build understands, so
    // a CLI newer than the app it is driving degrades to that behaviour
    // rather than failing.
    if (resolved.segments.len > 1) {
        ipc_args_buf[3] = try encodeSegments(alloc, resolved.segments);
        ipc_args = ipc_args_buf[0..4];
    }

    if (opts.when_idle) {
        waitForIdle(
            alloc,
            target_arg["--target=".len..],
            opts.idle_timeout,
            opts._busy_markers.items,
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
fn positionalArgs(alloc: Allocator, opts: *const Options) Allocator.Error![]const Positional {
    var out: std.ArrayList(Positional) = .empty;
    for (opts._arguments.items) |arg| try out.append(alloc, arg);
    if (opts.enter) try out.append(alloc, .{ .text = "Enter" });
    return out.items;
}

/// Poll the target pane's recent output until it looks idle, then
/// return. Busy is either signal:
///
///   * any caller-supplied `--busy-marker` text in the last lines
///     (the CLI itself knows no tool's chrome — the caller names what
///     its program prints while working), or
///   * the tail CHANGING between polls — busy TUIs animate a spinner
///     and a per-second timer, so their tail never holds still for a
///     full second, while an idle prompt is static. This needs no
///     marker and works for any program.
///
/// Idle therefore requires no marker AND an identical tail across
/// three consecutive polls (spanning ~1s, so a ticking seconds timer
/// can never look stable). Returns early — allowing the send to
/// proceed — after `timeout_secs`, or immediately if the pane's output
/// cannot be read (e.g. the target is a window name rather than a
/// pane).
fn waitForIdle(alloc: Allocator, name: []const u8, timeout_secs: u32, markers: []const [:0]const u8, stderr: *std.Io.Writer) void {
    const read_cli = @import("read.zig");
    var prev_hash: u64 = 0;
    var have_prev = false;
    var stable: u32 = 0;
    var remaining_polls: u64 = @as(u64, timeout_secs) * 2;
    while (remaining_polls > 0) : (remaining_polls -= 1) {
        const text = read_cli.queryPaneText(alloc, name, 10, stderr) catch return;
        const marker = for (markers) |m| {
            if (std.mem.indexOf(u8, text, m) != null) break true;
        } else false;
        const hash = std.hash.Wyhash.hash(0, text);
        const changed = !have_prev or hash != prev_hash;
        prev_hash = hash;
        have_prev = true;
        if (!marker and !changed) {
            stable += 1;
            if (stable >= 2) return;
        } else {
            stable = 0;
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

/// The biggest `--keys-file=` we will send. The IPC request as a whole is
/// capped at 1 MiB by the server (IpcServer.max_request_len), so this leaves
/// room for the JSON envelope and says so with a clear error instead of a
/// truncated write.
const max_keys_file_bytes: usize = 512 * 1024;

/// Append a file's bytes to the buffer VERBATIM: no key notation, no escape
/// processing. This is the transport for text the caller did not author by
/// hand, because a positional argument is not one — see the `--keys-file`
/// note in this action's doc comment (T210).
fn appendFile(alloc: Allocator, buf: *std.ArrayList(u8), path: []const u8) !void {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, path, max_keys_file_bytes);
    defer alloc.free(bytes);
    if (bytes.len == 0) return;
    try buf.appendSlice(alloc, bytes);
}

/// A run of resolved bytes, tagged with how the receiving program should
/// understand it. The wire format lives with the IPC server that reads it
/// (`apprt.ipc.segments`) so the encoder and the decoder cannot drift.
const verb_args = apprt.ipc.args;
const segments_wire = apprt.ipc.segments;
const Segment = segments_wire.Segment;
const Kind = segments_wire.Kind;

const Resolved = struct {
    /// Every resolved byte, concatenated in argument order.
    bytes: []const u8,

    /// The same bytes, split at every text↔key boundary.
    segments: []const Segment,
};

/// Resolve the positional arguments into ordered segments, merging runs of
/// the same kind so the result alternates strictly between text and keys. A
/// `--keys-file=` among them contributes its bytes where it appears — as a
/// TEXT run, since it is content the caller did not type — so
/// `--keys-file=p.txt Enter` sends the file and then the newline.
///
/// The boundary between a text run and the key run after it is the whole
/// point: flattening `"some message" Enter` into one buffer hands the
/// receiving program a single burst of bytes ending in `\r`, which paste
/// detection reads as a pasted newline instead of a submit.
///
/// On a `--keys-file=` read failure, `bad_file` names the path so the caller
/// can say which one. The returned segments point into the returned `bytes`,
/// and the scratch used along the way is never freed, so pass an arena.
fn resolveSegments(
    alloc: Allocator,
    text_args: []const Positional,
    bad_file: *?[]const u8,
) !Resolved {
    // Record spans rather than slices while filling `buf`: appending to it
    // can reallocate, which would dangle any slice taken earlier.
    const Span = struct { kind: Kind, start: usize, end: usize };

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
            kind: Kind,
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

        // A file payload is CONTENT and is sent VERBATIM: no key notation,
        // no escape processing, and no trailing-newline peel. See the
        // `--keys-file` note in this action's doc comment.
        if (!arg.after_dashdash and std.mem.startsWith(u8, arg.text, "--keys-file=")) {
            const path = arg.text["--keys-file=".len..];
            appendFile(alloc, &buf, path) catch |err| {
                bad_file.* = path;
                return err;
            };
            try push(alloc, &spans, .text, start, buf.items.len);
            continue;
        }

        const split = try resolveArgument(alloc, &buf, arg.text);

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

/// Encode segments as the `--segments=` IPC argument. The format itself
/// lives in `apprt.ipc.segments` next to the decoder that reads it.
const encodeSegments = segments_wire.encode;

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
    //
    // What is counted is LINE ENDINGS, not bytes: a `\r\n` pair is one line
    // ending written the Windows way and presses Enter ONCE. Counting bytes
    // submitted a CRLF-terminated argument twice — the caller's message, then
    // an empty line after it, which in a chat-style TUI is a whole extra turn
    // nobody asked for. Repeated endings still count separately, so
    // `"a\n\n"` and `"a\r\n\r\n"` both press twice.
    var end = buf.items.len;
    var presses: usize = 0;
    while (end > start) {
        switch (buf.items[end - 1]) {
            '\n' => end -= if (end - 1 > start and buf.items[end - 2] == '\r') 2 else 1,
            '\r' => end -= 1,
            else => break,
        }
        presses += 1;
    }
    buf.items.len = end;
    try buf.appendNTimes(alloc, '\r', presses);

    return .{ .text_len = end - start, .key_len = presses };
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

// --- T210: --keys-file sends bytes verbatim --------------------------------
//
// The whole point of the flag is that NOTHING interprets the text: not a
// shell, not key notation, not backslash escapes. These cases are the ones a
// resume prompt actually contains — a leading slash command, embedded double
// quotes, `\n` as two literal characters, a trailing backslash, and the words
// `Enter`/`C-c` in prose.

fn testKeysFile(alloc: Allocator, dir: std.fs.Dir, name: []const u8, contents: []const u8) ![:0]const u8 {
    try dir.writeFile(.{ .sub_path = name, .data = contents });
    const path = try dir.realpathAlloc(alloc, name);
    defer alloc.free(path);
    return try alloc.dupeZ(u8, path);
}

/// Wrap plain strings as positionals, the way flag parsing hands them over.
fn testPositionals(alloc: Allocator, arguments: []const [:0]const u8) ![]const Positional {
    const out = try alloc.alloc(Positional, arguments.len);
    for (arguments, out) |arg, *slot| slot.* = .{ .text = arg };
    return out;
}

/// Resolve an argument list the way `runArgs` does, for tests that do not
/// care about the failure paths.
fn testResolve(alloc: Allocator, arguments: []const [:0]const u8) !Resolved {
    var bad: ?[]const u8 = null;
    return try resolveSegments(alloc, try testPositionals(alloc, arguments), &bad);
}

test "keys-file: bytes are verbatim, not escape-processed or key-matched" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents =
        "/reset-context settle the \"DWM\\PrintWindow\" question. " ++
        "Literal \\n stays two chars, Enter and C-c stay words, trailing slash: \\";
    const path = try testKeysFile(alloc, tmp.dir, "prompt.txt", contents);
    const keys_arg = try std.fmt.allocPrintSentinel(alloc, "--keys-file={s}", .{path}, 0);

    var bad: ?[]const u8 = null;
    const resolved = try resolveSegments(
        alloc,
        try testPositionals(alloc, &.{keys_arg}),
        &bad,
    );

    try std.testing.expect(bad == null);
    try std.testing.expectEqualStrings(contents, resolved.bytes);

    // A file payload is CONTENT, so it is a text run — which is what makes
    // `--keys-file=p.txt Enter` frame the prompt and leave the CR outside it.
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
}

// The trailing-newline peel is a property of TEXT ARGUMENTS. `--keys-file=`
// is the "nothing interprets these bytes" transport, and a generated prompt
// file routinely ends in a newline its author never meant as "submit" — so
// the peel deliberately does not reach it. Submit a file with a following
// `Enter` (or `--enter`), which is the documented shape.
test "keys-file: a trailing newline in the file stays content, unpeeled" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testKeysFile(alloc, tmp.dir, "prompt.txt", "do the thing\n");
    const keys_arg = try std.fmt.allocPrintSentinel(alloc, "--keys-file={s}", .{path}, 0);

    var bad: ?[]const u8 = null;
    const resolved = try resolveSegments(
        alloc,
        try testPositionals(alloc, &.{keys_arg}),
        &bad,
    );

    // The `\n` is still a `\n`, still inside the one text run — not a `\r`
    // in a key run of its own.
    try std.testing.expectEqualStrings("do the thing\n", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
}

// After a bare `--`, `--keys-file=x` is the literal text a caller asked to
// send. Reading a file there would be the same class of silent wrong-thing
// this command's unknown-flag error exists to prevent.
test "keys-file: after a bare -- it is literal text, not a file read" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bad: ?[]const u8 = null;
    const resolved = try resolveSegments(alloc, &.{
        .{ .text = "--keys-file=t604-never-read.txt", .after_dashdash = true },
    }, &bad);

    try std.testing.expect(bad == null);
    try std.testing.expectEqualStrings("--keys-file=t604-never-read.txt", resolved.bytes);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
}

test "keys-file: keeps its position among positional arguments" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testKeysFile(alloc, tmp.dir, "prompt.txt", "hello");
    const keys_arg = try std.fmt.allocPrintSentinel(alloc, "--keys-file={s}", .{path}, 0);

    // `pre` then the file then Enter: the CR must land LAST, or the prompt is
    // submitted before its own text arrives.
    const resolved = try testResolve(alloc, &.{ "pre-", keys_arg, "Enter" });
    try std.testing.expectEqualStrings("pre-hello\r", resolved.bytes);

    // The text before the file and the file itself are one run; the CR is its
    // own. This is the /reset-context shape (T428).
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("pre-hello", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
}

test "keys-file: an unreadable path names itself in bad_file" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bad: ?[]const u8 = null;

    const missing = "--keys-file=t210-no-such-file-8fbb1c.txt";
    try std.testing.expectError(
        error.FileNotFound,
        resolveSegments(alloc, try testPositionals(alloc, &.{missing}), &bad),
    );
    try std.testing.expectEqualStrings("t210-no-such-file-8fbb1c.txt", bad.?);
}

test "keys-file: an empty file contributes nothing but still counts as text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try testKeysFile(alloc, tmp.dir, "empty.txt", "");
    const keys_arg = try std.fmt.allocPrintSentinel(alloc, "--keys-file={s}", .{path}, 0);

    const resolved = try testResolve(alloc, &.{keys_arg});
    try std.testing.expectEqual(@as(usize, 0), resolved.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.segments.len);
}

test "positional text is still key-matched and escape-processed" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{ "a\\tb", "Enter", "C-c" });
    try std.testing.expectEqualStrings("a\tb\r\x03", resolved.bytes);
}

// The invariant this whole change exists to protect: a text argument
// followed by a key argument must survive as two ordered segments. Flatten
// them and the receiving program cannot tell the trailing `\r` apart from a
// newline inside a paste, so `"some message" Enter` never submits.
test "resolveSegments keeps text and a following key apart" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{ "some message", "Enter" });

    try std.testing.expectEqualStrings("some message\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("some message", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments merges runs of the same kind" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Adjacent text args concatenate, as do adjacent keys, so the segment
    // list alternates and single-kind sends stay a single segment.
    const resolved = try testResolve(alloc, &.{ "vim", " -p", "Enter", "Escape", "iabc" });

    try std.testing.expectEqualStrings("vim -p\r\x1biabc", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 3), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("vim -p", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r\x1b", resolved.segments[1].bytes);
    try std.testing.expectEqual(Kind.text, resolved.segments[2].kind);
    try std.testing.expectEqualStrings("iabc", resolved.segments[2].bytes);
}

test "resolveSegments single-argument forms stay one segment" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // These are the forms that must keep working byte-for-byte. One segment
    // means the CLI sends only `--keys=`, which is exactly the old payload.
    for ([_][:0]const u8{ "text", "Enter", "C-c" }) |arg| {
        const resolved = try testResolve(alloc, &.{arg});
        try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    }
}

test "resolveSegments skips arguments that resolve to nothing" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{ "", "hi", "", "Enter" });

    try std.testing.expectEqualStrings("hi\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
}

test "encodeSegments" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{ "hi", "Enter" });
    try std.testing.expectEqualStrings(
        "--segments=t6869,k0d",
        try encodeSegments(alloc, resolved.segments),
    );
}

// --- Trailing-newline peel (main a7f7476e1) -------------------------------
//
// A trailing newline is the spelling agents reach for first, so it has to be
// the one that works. These pin the peel: the newline leaves the paste and
// becomes a keypress after it.

test "resolveSegments peels a trailing newline off as an Enter keypress" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"prompt\\n"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments peels a real trailing newline byte the same way" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The peel runs after escape processing, so `\n` typed as a literal byte
    // and `\n` written as the two-character escape are the same input.
    const resolved = try testResolve(alloc, &.{"prompt\n"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
}

test "resolveSegments keeps an interior newline inside the pasted text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"a\\nb\\n"});

    try std.testing.expectEqualStrings("a\nb\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqualStrings("a\nb", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments treats a trailing carriage return like a newline" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"prompt\\r"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Kind.text, resolved.segments[0].kind);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
}

test "resolveSegments a newline-only argument is a key and nothing else" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"\\n"});

    try std.testing.expectEqualStrings("\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Kind.key, resolved.segments[0].kind);
}

test "resolveSegments multiple trailing newlines are multiple presses" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"prompt\\n\\n"});

    try std.testing.expectEqualStrings("prompt\r\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r\r", resolved.segments[1].bytes);
}

test "resolveSegments a trailing CRLF is ONE press, not two" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `\r\n` is one line ending written the Windows way — and Windows is
    // where such text comes from. Counting its two bytes submitted the
    // caller's message and then an empty line after it.
    const resolved = try testResolve(alloc, &.{"prompt\\r\\n"});

    try std.testing.expectEqualStrings("prompt\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
    try std.testing.expectEqualStrings("\r", resolved.segments[1].bytes);
}

test "resolveSegments repeated CRLF endings are still one press each" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"prompt\\r\\n\\r\\n"});

    try std.testing.expectEqualStrings("prompt\r\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqualStrings("\r\r", resolved.segments[1].bytes);
}

test "resolveSegments a CRLF-only argument is one Enter and nothing else" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resolved = try testResolve(alloc, &.{"\\r\\n"});

    try std.testing.expectEqualStrings("\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Kind.key, resolved.segments[0].kind);
}

test "resolveSegments a bare CR run is still one press per CR" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Only `\r\n` pairs collapse. Two carriage returns are two Enter
    // presses, the same way two newlines are.
    const resolved = try testResolve(alloc, &.{"prompt\\r\\r"});

    try std.testing.expectEqualStrings("prompt\r\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("\r\r", resolved.segments[1].bytes);
}

test "resolveSegments a trailing newline and a following Enter stack" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Both spellings submit, so writing both submits twice. Merging keeps the
    // two presses in one key run, which is the honest description of what the
    // pane receives.
    const resolved = try testResolve(alloc, &.{ "prompt\\n", "Enter" });

    try std.testing.expectEqualStrings("prompt\r\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqualStrings("prompt", resolved.segments[0].bytes);
    try std.testing.expectEqualStrings("\r\r", resolved.segments[1].bytes);
}

// --- Flag layer -----------------------------------------------------------
//
// The peel and `--enter` are only half the fix; the other half is that a
// wrong guess is now LOUD. These drive `checkArg` directly, because that is
// where this branch differs from main: `--keys-file=` is a recognized flag
// that still has to come out the other side as a positional.

/// Feed arguments through flag parsing the way `parseManuallyHook` does.
fn testCheckArgs(alloc: Allocator, argv: []const []const u8) !Options {
    var opts: Options = .{};
    for (argv) |arg| {
        if (try opts.checkArg(alloc, arg)) |p| try opts._arguments.append(alloc, p);
    }
    return opts;
}

test "flags: an unknown --flag is recorded, not turned into text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // This is the exact shape that used to be typed into the pane at exit 0.
    const opts = try testCheckArgs(alloc, &.{ "--target=x", "--press-enter", "hi" });

    try std.testing.expectEqualStrings("--press-enter", opts.unknown_flag.?);
    try std.testing.expectEqualStrings("--target=x", opts.target.?);
    try std.testing.expectEqual(@as(usize, 1), opts._arguments.items.len);
    try std.testing.expectEqualStrings("hi", opts._arguments.items[0].text);
}

test "flags: single-dash arguments stay ordinary text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try testCheckArgs(alloc, &.{ "--target=x", "-la", "-p" });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expectEqual(@as(usize, 2), opts._arguments.items.len);
    try std.testing.expectEqualStrings("-la", opts._arguments.items[0].text);
}

test "flags: a bare -- stops flag parsing but not key notation" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try testCheckArgs(alloc, &.{ "--target=x", "--", "--not-a-flag", "Enter" });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expectEqual(@as(usize, 2), opts._arguments.items.len);
    try std.testing.expectEqualStrings("--not-a-flag", opts._arguments.items[0].text);
    try std.testing.expect(opts._arguments.items[0].after_dashdash);

    // Key notation still applies after `--`, so the Enter is still a key.
    var bad: ?[]const u8 = null;
    const resolved = try resolveSegments(alloc, opts._arguments.items, &bad);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
}

test "flags: --keys-file= survives flag parsing as a positional" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Recognized (so not an unknown flag) but NOT consumed (so its position
    // relative to the trailing Enter is preserved).
    const opts = try testCheckArgs(alloc, &.{ "--target=x", "--keys-file=p.txt", "Enter" });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expectEqual(@as(usize, 2), opts._arguments.items.len);
    try std.testing.expectEqualStrings("--keys-file=p.txt", opts._arguments.items[0].text);
    try std.testing.expect(!opts._arguments.items[0].after_dashdash);
}

test "flags: --busy-marker= collects values and stays out of the text" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try testCheckArgs(alloc, &.{
        "--target=x",
        "--busy-marker=esc to interrupt",
        "--busy-marker=Working…",
        "hi",
    });

    try std.testing.expect(opts.unknown_flag == null);
    try std.testing.expectEqual(@as(usize, 2), opts._busy_markers.items.len);
    try std.testing.expectEqualStrings("esc to interrupt", opts._busy_markers.items[0]);
    try std.testing.expectEqualStrings("Working…", opts._busy_markers.items[1]);
    try std.testing.expectEqual(@as(usize, 1), opts._arguments.items.len);
    try std.testing.expectEqualStrings("hi", opts._arguments.items[0].text);
}

test "flags: an empty --busy-marker= is invalid, not an empty match-everything" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var opts: Options = .{};
    try std.testing.expectError(error.InvalidValue, opts.checkArg(alloc, "--busy-marker="));
}

test "flags: after a bare -- a --busy-marker= is literal text, not a flag" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try testCheckArgs(alloc, &.{ "--target=x", "--", "--busy-marker=zzz" });

    try std.testing.expectEqual(@as(usize, 0), opts._busy_markers.items.len);
    try std.testing.expectEqual(@as(usize, 1), opts._arguments.items.len);
    try std.testing.expectEqualStrings("--busy-marker=zzz", opts._arguments.items[0].text);
}

test "flags: --enter becomes a synthetic trailing Enter positional" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try testCheckArgs(alloc, &.{ "--target=x", "--enter", "ls -la" });
    try std.testing.expect(opts.enter);

    const positionals = try positionalArgs(alloc, &opts);
    try std.testing.expectEqual(@as(usize, 2), positionals.len);
    try std.testing.expectEqualStrings("Enter", positionals[1].text);

    var bad: ?[]const u8 = null;
    const resolved = try resolveSegments(alloc, positionals, &bad);
    try std.testing.expectEqualStrings("ls -la\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 2), resolved.segments.len);
    try std.testing.expectEqual(Kind.key, resolved.segments[1].kind);
}

test "flags: a bare --enter with no text is a legal send that presses Enter" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try testCheckArgs(alloc, &.{ "--target=x", "--enter" });

    // The synthetic Enter is a positional BEFORE the "at least one text
    // argument" check runs, which is what makes this legal rather than an
    // error about missing text.
    const positionals = try positionalArgs(alloc, &opts);
    try std.testing.expectEqual(@as(usize, 1), positionals.len);

    var bad: ?[]const u8 = null;
    const resolved = try resolveSegments(alloc, positionals, &bad);
    try std.testing.expectEqualStrings("\r", resolved.bytes);
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
    try std.testing.expectEqual(Kind.key, resolved.segments[0].kind);
}
