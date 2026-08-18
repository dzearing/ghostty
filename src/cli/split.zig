const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const lib = @import("../lib/main.zig");
const view_arg = @import("view_arg.zig");
const verb_flags = @import("verb_flags.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// All of the arguments after `+split`. They will be sent to Ghostty
    /// for processing.
    _arguments: std.ArrayList([:0]const u8) = .empty,

    /// Enable arg parsing diagnostics so that we don't get an error if
    /// there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// The server ignores a flag it does not know, on purpose, so the CLI is
    /// where a typo has to be caught (T852). The `-e` tail never reaches
    /// this: it is appended straight to `_arguments` by the parse hook.
    _flags: verb_flags.Checker = .{ .spec = verb_flags.split },

    /// Manual parse hook, collect all of the arguments after `+split`.
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        var e_seen: bool = std.mem.eql(u8, arg, "-e");

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (e_seen) {
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (std.mem.eql(u8, param, "-e")) {
                e_seen = true;
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        if (!try self._flags.accept(alloc, arg)) return null;
        if (lib.cutPrefix(u8, arg, "--color=")) |rest| {
            const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (!isValidColor(trimmed))
                return error.InvalidValue;
            return try alloc.dupeZ(u8, arg);
        }
        return try alloc.dupeZ(u8, arg);
    }

    fn isValidColor(value: []const u8) bool {
        if (std.mem.eql(u8, value, "random")) return true;
        return isValidHexColor(value);
    }

    fn isValidHexColor(value: []const u8) bool {
        if (value.len != 7 and value.len != 4) return false;
        if (value[0] != '#') return false;
        for (value[1..]) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Create a new split pane in a running Ghoztty window.
///
/// If `--target` is specified, the split will be added to the window
/// with that name. If not specified, the split is added to the most
/// recently focused window.
///
/// This command is idempotent: if `--name` is specified and a pane with
/// that name already exists, the existing pane is focused instead of
/// creating a new split.
///
/// Flags:
///
///   * `--target=<name>`: The target window name to add the split to.
///     The target must have been created with `+new-window --target=<name>`.
///
///   * `--name=<name>`: Register this split pane with a name for later
///     targeting. If a pane with this name already exists, it will be
///     focused instead of creating a new split.
///
///   * `--direction=right|down|left|up`: The direction to split. Defaults
///     to `right` if not specified.
///
///   * `--percent=<1-99>`: The percentage of space allocated to the
///     new split pane. Defaults to 50 if not specified. Values outside
///     1-99 return an error.
///
///   * `--pane=<name>`: Split adjacent to the named pane instead of the
///     focused surface. The pane must exist (returns an error if not
///     found). Can be used without `--target` to search across all
///     registered targets.
///
///   * `--from-focused`: Split the app's currently focused window/surface,
///     mirroring a keyboard split exactly. On a remote window the new pane
///     inherits the SAME machine/connection plus the parent's command and
///     cwd (full remote inheritance). Ignores `--command`/`--name`/`--target`.
///
///   * `--view=<path-or-url-or-diff>`: Open a VIEWER pane instead of a
///     terminal: a rendered markdown file, a syntax-highlighted text/code
///     file, a website (http/https URL), or a GIT DIFF. Relative paths
///     resolve against `--working-directory` if given, else the caller's
///     cwd. Mutually exclusive with `--command`/`-e`.
///
///     Diff forms (the repository is the one containing
///     `--working-directory`, else the caller's cwd):
///       - `git-status:` — working tree: staged, unstaged and untracked
///       - `git-diff:<a>...<b>` — a range (three-dot = merge base)
///       - `git-diff:<sha>` — that commit's own changes
///       - `git-diff:` — this branch against main/master/origin HEAD
///
///   * `--command=<command>`: The command to run in the split pane.
///
///   * `--shell=<path>`: The shell to use when running `--command`.
///     The shell is invoked with `-lic` so the user's profile is loaded.
///     Defaults to the `command-shell` config, then `$SHELL`, then
///     `/bin/zsh`.
///
///   * `--env=<KEY=VALUE>`: Set an environment variable in the spawned
///     process. Can be specified multiple times for multiple variables.
///     Values are passed through literally (no shell expansion).
///
///   * `--color=<#hex>`: A hex color (e.g. `#1a1a2e` or `#abc`) to apply
///     as a background tint on the split pane.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute in the split pane.
///
/// Any other argument starting with `--` is an error, so a misspelled
/// flag is rejected instead of being dropped by the server. Everything
/// after `-e` is the command and is never checked.
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

    if (opts._flags.help_requested) return Action.help_error;

    if (try opts._flags.report(stderr)) return 1;

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    try view_arg.resolve(alloc, opts._arguments.items);
    try seedViewWorkingDirectory(alloc, &opts._arguments);

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .split,
        .{
            .arguments = if (opts._arguments.items.len == 0) null else opts._arguments.items,
        },
    ) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("No running Ghoztty instance found. Start one with +new-window first.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    // sendIpc already printed the server's error text (if any) to stderr.
    try stderr.print("+split failed.\n", .{});
    return 1;
}

/// For a `--view=` split with no explicit `--working-directory=`, insert the
/// caller's cwd as one.
///
/// A viewer pane records this as its ORIGIN DIRECTORY, which is the fallback
/// leg of worktree provenance: a pane showing a remote site or a blank page
/// has no directory of its own, so without this the feedback affordance could
/// never appear for it. `+new-window` already inserts the cwd unconditionally;
/// `+split` does not, because a terminal split inherits cwd from its parent
/// surface and an injected `--working-directory` would override that
/// inheritance. Restricting the insert to `--view=` splits keeps terminal
/// behavior exactly as it was.
fn seedViewWorkingDirectory(
    alloc: Allocator,
    arguments: *std.ArrayList([:0]const u8),
) !void {
    var has_view = false;
    for (arguments.items) |a| {
        if (std.mem.startsWith(u8, a, "--view=")) has_view = true;
        if (std.mem.startsWith(u8, a, "--working-directory=")) return;
    }
    if (!has_view) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &buf) catch return;
    try arguments.append(
        alloc,
        try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{cwd}, 0),
    );
}
