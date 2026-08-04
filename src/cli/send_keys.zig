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

    when_idle: bool = false,
    idle_timeout: u32 = 30,

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        if (std.mem.eql(u8, arg, "--when-idle")) {
            self.when_idle = true;
            return null;
        }
        // NOTE: `--keys-file=` is deliberately NOT consumed here. It has to
        // keep its position relative to the positional text arguments so
        // `--keys-file=p.txt Enter` sends the file and THEN the newline, so it
        // rides along in _arguments and is handled in runArgs like --target=.
        if (std.mem.startsWith(u8, arg, "--idle-timeout=")) {
            self.idle_timeout = std.fmt.parseInt(u32, arg["--idle-timeout=".len..], 10) catch return error.InvalidValue;
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
///   * `--when-idle`: Before sending, poll the target pane's recent
///     output every 500ms until it no longer looks busy: no
///     "esc to interrupt" in the last lines (the marker older Claude
///     Code shows while working) AND the tail unchanged across ~1s
///     (busy TUIs animate spinners/timers; an idle prompt is static).
///     Sends anyway once `--idle-timeout` elapses or if the pane's
///     output cannot be read.
///
///   * `--idle-timeout=<seconds>`: Max time to wait with `--when-idle`.
///     Default: 30.
///
///   * `--keys-file=<path>`: Send the file's bytes VERBATIM — no key
///     notation, no `\n` escape processing, no shell in the way. Use
///     this for any text a caller did not author by hand: a prompt, a
///     path, anything containing quotes or backslashes. It keeps its
///     position among the positional arguments, so
///     `--keys-file=p.txt Enter` sends the file and then a carriage
///     return. May be given more than once. The file is sent exactly
///     as it is on disk, trailing newline included, so write it with
///     no trailing newline unless you want one typed.
///
/// Positional arguments are the text to send. Each argument is
/// checked for key notation first, then processed for escape
/// sequences:
///
///   * Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), etc.
///   * Named keys: `Enter`, `Tab`, `Escape`, `Space`
///   * Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`
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
///   ghoztty +send-keys --target=term "ls -la" Enter
///   ghoztty +send-keys --target=term C-c
///   ghoztty +send-keys --target=term "hello\tworld\n"
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

    // Extract --target and resolve the rest IN ORDER: a --keys-file= among
    // the positional arguments contributes its bytes where it appears, so
    // `--keys-file=p.txt Enter` sends the file and then the newline.
    var target_arg: ?[:0]const u8 = null;
    var bad_file: ?[]const u8 = null;
    var text_count: usize = 0;

    const resolved = resolveArguments(
        alloc,
        opts._arguments.items,
        &target_arg,
        &bad_file,
        &text_count,
    ) catch |err| {
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
    const saw_text = text_count > 0;

    if (target_arg == null) {
        try stderr.print("+send-keys: --target is required\n", .{});
        return 1;
    }

    if (!saw_text) {
        try stderr.print("+send-keys: at least one text argument is required\n", .{});
        return 1;
    }

    if (resolved.bytes.len == 0) {
        try stderr.print("+send-keys: resolved text is empty\n", .{});
        return 1;
    }

    // Build the IPC arguments: --target=<name> --keys=<processed bytes>
    const prefix = "--keys=";
    const keys_arg = try alloc.allocSentinel(u8, prefix.len + resolved.bytes.len, 0);
    @memcpy(keys_arg[0..prefix.len], prefix);
    @memcpy(keys_arg[prefix.len..][0..resolved.bytes.len], resolved.bytes);

    var ipc_args_buf: [3][:0]const u8 = .{ target_arg.?, keys_arg, undefined };
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
            target_arg.?["--target=".len..],
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

/// Poll the target pane's recent output until it looks idle, then
/// return. Busy is either signal:
///
///   * the literal "esc to interrupt" in the last lines (the marker
///     Claude Code < 2.1.207 shows while working), or
///   * the tail CHANGING between polls — busy TUIs animate a spinner
///     and a per-second timer, so their tail never holds still for a
///     full second, while an idle prompt is static. This catches
///     Claude Code versions that no longer render the marker.
///
/// Idle therefore requires no marker AND an identical tail across
/// three consecutive polls (spanning ~1s, so a ticking seconds timer
/// can never look stable). Returns early — allowing the send to
/// proceed — after `timeout_secs`, or immediately if the pane's output
/// cannot be read (e.g. the target is a window name rather than a
/// pane).
fn waitForIdle(alloc: Allocator, name: []const u8, timeout_secs: u32, stderr: *std.Io.Writer) void {
    const read_cli = @import("read.zig");
    var prev_hash: u64 = 0;
    var have_prev = false;
    var stable: u32 = 0;
    var remaining_polls: u64 = @as(u64, timeout_secs) * 2;
    while (remaining_polls > 0) : (remaining_polls -= 1) {
        const text = read_cli.queryPaneText(alloc, name, 10, stderr) catch return;
        const marker = std.mem.indexOf(u8, text, "esc to interrupt") != null;
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
const segments_wire = apprt.ipc.segments;
const Segment = segments_wire.Segment;
const Kind = segments_wire.Kind;

const Resolved = struct {
    /// Every resolved byte, concatenated in argument order.
    bytes: []const u8,

    /// The same bytes, split at every text↔key boundary.
    segments: []const Segment,
};

/// Resolve the whole argument list into ordered segments, IN ORDER, pulling
/// the `--target=` argument out along the way. A `--keys-file=` among the
/// positional arguments contributes its bytes where it appears — as a TEXT
/// run, since it is content the caller did not type — so
/// `--keys-file=p.txt Enter` sends the file and then the newline.
///
/// The boundary between a text run and the key run after it is the whole
/// point: flattening `"some message" Enter` into one buffer hands the
/// receiving program a single burst of bytes ending in `\r`, which paste
/// detection reads as a pasted newline instead of a submit.
///
/// `text_count` receives the number of arguments that were not `--target=`;
/// on a `--keys-file=` read failure, `bad_file` names the path so the caller
/// can say which one. The returned segments point into the returned `bytes`,
/// and the scratch used along the way is never freed, so pass an arena.
fn resolveArguments(
    alloc: Allocator,
    arguments: []const [:0]const u8,
    target: *?[:0]const u8,
    bad_file: *?[]const u8,
    text_count: *usize,
) !Resolved {
    // Record spans rather than slices while filling `buf`: appending to it
    // can reallocate, which would dangle any slice taken earlier.
    const Span = struct { kind: Kind, start: usize, end: usize };

    var buf: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;

    text_count.* = 0;
    for (arguments) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) {
            target.* = arg;
            continue;
        }
        text_count.* += 1;

        const start = buf.items.len;
        const kind: Kind = if (std.mem.startsWith(u8, arg, "--keys-file=")) kind: {
            const path = arg["--keys-file=".len..];
            appendFile(alloc, &buf, path) catch |err| {
                bad_file.* = path;
                return err;
            };
            break :kind .text;
        } else try resolveArgument(alloc, &buf, arg);

        // An empty argument resolves to no bytes and so is not a segment.
        if (buf.items.len == start) continue;

        if (spans.items.len > 0) {
            const prev = &spans.items[spans.items.len - 1];
            if (prev.kind == kind) {
                prev.end = buf.items.len;
                continue;
            }
        }

        try spans.append(alloc, .{
            .kind = kind,
            .start = start,
            .end = buf.items.len,
        });
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

/// Resolve a single argument: if it matches a key name, append its byte(s);
/// otherwise process escape sequences in the text. Returns which of the two
/// it was.
fn resolveArgument(alloc: Allocator, buf: *std.ArrayList(u8), arg: []const u8) Allocator.Error!Kind {
    // Ctrl key notation: C-a through C-z (case insensitive)
    if (arg.len == 3 and arg[0] == 'C' and arg[1] == '-') {
        const ch = arg[2];
        if (ch >= 'a' and ch <= 'z') {
            try buf.append(alloc, ch - 'a' + 1);
            return .key;
        }
        if (ch >= 'A' and ch <= 'Z') {
            try buf.append(alloc, ch - 'A' + 1);
            return .key;
        }
    }

    // Named keys
    if (eqlIgnoreCase(arg, "Enter") or eqlIgnoreCase(arg, "Return") or eqlIgnoreCase(arg, "CR")) {
        try buf.append(alloc, '\r');
        return .key;
    }
    if (eqlIgnoreCase(arg, "Tab")) {
        try buf.append(alloc, '\t');
        return .key;
    }
    if (eqlIgnoreCase(arg, "Escape") or eqlIgnoreCase(arg, "Esc")) {
        try buf.append(alloc, 0x1b);
        return .key;
    }
    if (eqlIgnoreCase(arg, "Space")) {
        try buf.append(alloc, ' ');
        return .key;
    }
    if (eqlIgnoreCase(arg, "BSpace") or eqlIgnoreCase(arg, "Backspace")) {
        try buf.append(alloc, 0x7f);
        return .key;
    }

    // Not a key name — process escape sequences in the text
    try processEscapes(alloc, buf, arg);
    return .text;
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

    try std.testing.expectEqual(Kind.key, try resolveArgument(alloc, &buf, "C-c"));
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 3), buf.items[0]);
}

test "resolveArgument Enter" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.testing.expectEqual(Kind.key, try resolveArgument(alloc, &buf, "Enter"));
    try std.testing.expectEqualStrings("\r", buf.items);
}

test "resolveArgument plain text with escapes" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.testing.expectEqual(Kind.text, try resolveArgument(alloc, &buf, "hello\\nworld"));
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

/// Resolve an argument list the way `runArgs` does, for tests that do not
/// care about the target or the failure paths.
fn testResolve(alloc: Allocator, arguments: []const [:0]const u8) !Resolved {
    var target: ?[:0]const u8 = null;
    var bad: ?[]const u8 = null;
    var n: usize = 0;
    return try resolveArguments(alloc, arguments, &target, &bad, &n);
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

    var target: ?[:0]const u8 = null;
    var bad: ?[]const u8 = null;
    var n: usize = 0;
    const resolved = try resolveArguments(alloc, &.{ "--target=x", keys_arg }, &target, &bad, &n);

    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("--target=x", target.?);
    try std.testing.expect(bad == null);
    try std.testing.expectEqualStrings(contents, resolved.bytes);

    // A file payload is CONTENT, so it is a text run — which is what makes
    // `--keys-file=p.txt Enter` frame the prompt and leave the CR outside it.
    try std.testing.expectEqual(@as(usize, 1), resolved.segments.len);
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

    var target: ?[:0]const u8 = null;
    var bad: ?[]const u8 = null;
    var n: usize = 0;

    // `pre` then the file then Enter: the CR must land LAST, or the prompt is
    // submitted before its own text arrives.
    const resolved = try resolveArguments(
        alloc,
        &.{ "pre-", keys_arg, "--target=x", "Enter" },
        &target,
        &bad,
        &n,
    );
    try std.testing.expectEqual(@as(usize, 3), n);
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

    var target: ?[:0]const u8 = null;
    var bad: ?[]const u8 = null;
    var n: usize = 0;

    const missing = "--keys-file=t210-no-such-file-8fbb1c.txt";
    try std.testing.expectError(
        error.FileNotFound,
        resolveArguments(alloc, &.{ "--target=x", missing }, &target, &bad, &n),
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

    var target: ?[:0]const u8 = null;
    var bad: ?[]const u8 = null;
    var n: usize = 0;

    const resolved = try resolveArguments(alloc, &.{ "--target=x", keys_arg }, &target, &bad, &n);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 0), resolved.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.segments.len);
}

test "positional text is still key-matched and escape-processed" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var target: ?[:0]const u8 = null;
    var bad: ?[]const u8 = null;
    var n: usize = 0;

    const resolved = try resolveArguments(
        alloc,
        &.{ "--target=x", "a\\tb", "Enter", "C-c" },
        &target,
        &bad,
        &n,
    );
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("a\tb\r\x03", resolved.bytes);
}

// The invariant this whole change exists to protect: a text argument
// followed by a key argument must survive as two ordered segments. Flatten
// them and the receiving program cannot tell the trailing `\r` apart from a
// newline inside a paste, so `"some message" Enter` never submits.
test "resolveArguments keeps text and a following key apart" {
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

test "resolveArguments merges runs of the same kind" {
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

test "resolveArguments single-argument forms stay one segment" {
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

test "resolveArguments skips arguments that resolve to nothing" {
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
