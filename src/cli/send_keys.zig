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
///     output every 500ms until it no longer looks busy (no
///     "esc to interrupt" in the last lines — the marker Claude Code
///     shows while working). Sends anyway once `--idle-timeout` elapses
///     or if the pane's output cannot be read.
///
///   * `--idle-timeout=<seconds>`: Max time to wait with `--when-idle`.
///     Default: 30.
///
/// Positional arguments are the text to send. Each argument is
/// checked for key notation first, then processed for escape
/// sequences:
///
///   * Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), etc.
///   * Named keys: `Enter`, `Tab`, `Escape`, `Space`
///   * Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`
///
/// Examples:
///
///   ghoztty +send-keys --target=term "ls -la" Enter
///   ghoztty +send-keys --target=term C-c
///   ghoztty +send-keys --target=term "hello\tworld\n"
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

    // Extract --target and collect text arguments
    var target_arg: ?[:0]const u8 = null;
    var text_args: std.ArrayList([]const u8) = .empty;

    for (opts._arguments.items) |arg| {
        if (std.mem.startsWith(u8, arg, "--target=")) {
            target_arg = arg;
        } else {
            try text_args.append(alloc, arg);
        }
    }

    if (target_arg == null) {
        try stderr.print("+send-keys: --target is required\n", .{});
        return 1;
    }

    if (text_args.items.len == 0) {
        try stderr.print("+send-keys: at least one text argument is required\n", .{});
        return 1;
    }

    // Process each text argument: resolve key notation and escape sequences
    var keys_buf: std.ArrayList(u8) = .empty;
    for (text_args.items) |text_arg| {
        try resolveArgument(alloc, &keys_buf, text_arg);
    }

    if (keys_buf.items.len == 0) {
        try stderr.print("+send-keys: resolved text is empty\n", .{});
        return 1;
    }

    // Build the IPC arguments: --target=<name> --keys=<processed bytes>
    const prefix = "--keys=";
    const keys_arg = try alloc.allocSentinel(u8, prefix.len + keys_buf.items.len, 0);
    @memcpy(keys_arg[0..prefix.len], prefix);
    @memcpy(keys_arg[prefix.len..][0..keys_buf.items.len], keys_buf.items);

    var ipc_args_buf: [2][:0]const u8 = .{ target_arg.?, keys_arg };
    const ipc_args: [][:0]const u8 = &ipc_args_buf;

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

/// Resolve a single argument: if it matches a key name, append its byte(s);
/// otherwise process escape sequences in the text.
fn resolveArgument(alloc: Allocator, buf: *std.ArrayList(u8), arg: []const u8) Allocator.Error!void {
    // Ctrl key notation: C-a through C-z (case insensitive)
    if (arg.len == 3 and arg[0] == 'C' and arg[1] == '-') {
        const ch = arg[2];
        if (ch >= 'a' and ch <= 'z') {
            try buf.append(alloc, ch - 'a' + 1);
            return;
        }
        if (ch >= 'A' and ch <= 'Z') {
            try buf.append(alloc, ch - 'A' + 1);
            return;
        }
    }

    // Named keys
    if (eqlIgnoreCase(arg, "Enter") or eqlIgnoreCase(arg, "Return") or eqlIgnoreCase(arg, "CR")) {
        try buf.append(alloc, '\r');
        return;
    }
    if (eqlIgnoreCase(arg, "Tab")) {
        try buf.append(alloc, '\t');
        return;
    }
    if (eqlIgnoreCase(arg, "Escape") or eqlIgnoreCase(arg, "Esc")) {
        try buf.append(alloc, 0x1b);
        return;
    }
    if (eqlIgnoreCase(arg, "Space")) {
        try buf.append(alloc, ' ');
        return;
    }
    if (eqlIgnoreCase(arg, "BSpace") or eqlIgnoreCase(arg, "Backspace")) {
        try buf.append(alloc, 0x7f);
        return;
    }

    // Not a key name — process escape sequences in the text
    try processEscapes(alloc, buf, arg);
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

    try resolveArgument(alloc, &buf, "C-c");
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 3), buf.items[0]);
}

test "resolveArgument Enter" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try resolveArgument(alloc, &buf, "Enter");
    try std.testing.expectEqualStrings("\r", buf.items);
}

test "resolveArgument plain text with escapes" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try resolveArgument(alloc, &buf, "hello\\nworld");
    try std.testing.expectEqualStrings("hello\nworld", buf.items);
}

test "processEscapes tab" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try processEscapes(alloc, &buf, "col1\\tcol2");
    try std.testing.expectEqualStrings("col1\tcol2", buf.items);
}
