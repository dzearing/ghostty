const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const lib = @import("../lib/main.zig");
const view_arg = @import("view_arg.zig");
const homedir = @import("../os/homedir.zig");
const global = &@import("../global.zig").state;

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, open up a new window in a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    /// Did the user specify a `--working-directory` argument on the command line?
    _working_directory_seen: bool = false,

    /// All of the arguments after `+new-window`. They will be sent to Ghosttty
    /// for processing.
    _arguments: std.ArrayList([:0]const u8) = .empty,

    /// Enable arg parsing diagnostics so that we don't get an error if
    /// there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Manual parse hook, collect all of the arguments after `+new-window`.
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || homedir.ExpandError || std.fs.Dir.RealPathAllocError || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        var e_seen: bool = std.mem.eql(u8, arg, "-e");

        // Include the argument that triggered the manual parse hook.
        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        // Gather up the rest of the arguments to use as the command.
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

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || homedir.ExpandError || std.fs.Dir.RealPathAllocError || Allocator.Error)!?[:0]const u8 {
        if (lib.cutPrefix(u8, arg, "--class=")) |rest| {
            self.class = try alloc.dupeZ(u8, std.mem.trim(u8, rest, &std.ascii.whitespace));
            return null;
        }

        if (lib.cutPrefix(u8, arg, "--color=")) |rest| {
            const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (!isValidColor(trimmed))
                return error.InvalidValue;
            return try alloc.dupeZ(u8, arg);
        }

        if (lib.cutPrefix(u8, arg, "--split-color=")) |rest| {
            const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (!isValidColor(trimmed))
                return error.InvalidValue;
            return try alloc.dupeZ(u8, arg);
        }

        if (lib.cutPrefix(u8, arg, "--working-directory=")) |rest| {
            const stripped = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (std.mem.eql(u8, stripped, "home")) return try alloc.dupeZ(u8, arg);
            if (std.mem.eql(u8, stripped, "inherit")) return try alloc.dupeZ(u8, arg);
            const cwd: std.fs.Dir = std.fs.cwd();
            var expandhome_buf: [std.fs.max_path_bytes]u8 = undefined;
            const expanded = try homedir.expandHome(stripped, &expandhome_buf);
            var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
            const realpath = try cwd.realpath(expanded, &realpath_buf);
            self._working_directory_seen = true;
            return try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{realpath}, 0);
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

/// The `new-window` will use native platform IPC to open up a new window in a
/// running instance of Ghostty.
///
/// If the `--class` flag is not set, the `new-window` command will try and
/// connect to a running instance of Ghostty based on what optimizations the
/// Ghostty CLI was compiled with. Otherwise the `new-window` command will try
/// and contact a running Ghostty instance that was configured with the same
/// `class` as was given on the command line.
///
/// All of the arguments after the `+new-window` argument (except for the
/// `--class` flag) will be sent to the remote Ghostty instance and will be
/// parsed as command line flags. These flags will override certain settings
/// when creating the first surface in the new window. Currently, only
/// `--working-directory`, `--command`, and `--title` are supported. `-e` will
/// also work as an alias for `--command`, except that if `-e` is found on the
/// command line all following arguments will become part of the command and no
/// more arguments will be parsed for configuration settings.
///
/// If `--working-directory` is found on the command line and is a relative
/// path (i.e. doesn't start with `/`) it will be resolved to an absolute path
/// relative to the current working directory that the `ghoztty +new-window`
/// command is run from. `~/` prefixes will also be expanded to the user's home
/// directory.
///
/// If `--working-directory` is _not_ found on the command line, the working
/// directory that `ghoztty +new-window` is run from will be passed to Ghoztty.
///
/// GTK uses an application ID to identify instances of applications. If Ghostty
/// is compiled with release optimizations, the default application ID will be
/// `com.dzearing.ghoztty`. If Ghostty is compiled with debug optimizations,
/// the default application ID will be `com.dzearing.ghoztty-debug`.  The
/// `class` configuration entry can be used to set up a custom application
/// ID. The class name must follow the requirements defined [in the GTK
/// documentation](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html)
/// or it will be ignored and Ghostty will use the default as defined above.
///
/// On GTK, D-Bus activation must be properly configured. Ghostty does not need
/// to be running for this to open a new window, making it suitable for binding
/// to keys in your window manager (if other methods for configuring global
/// shortcuts are unavailable). D-Bus will handle launching a new instance
/// of Ghostty if it is not already running. See the Ghostty website for
/// information on properly configuring D-Bus activation.
///
/// Supported on GTK and macOS.
///
/// Flags:
///
///   * `--class=<class>`: If set, open up a new window in a custom instance of
///     Ghostty. The class must be a valid GTK application ID.
///
///   * `--command`: The command to be executed in the first surface of the new window.
///
///   * `--view=<path-or-url-or-diff>`: Open a window whose single pane is a
///     VIEWER instead of a terminal: a rendered markdown file, a
///     syntax-highlighted text/code file, a website (http/https URL), or a
///     GIT DIFF. Relative paths resolve against `--working-directory` if
///     given, else the caller's cwd. Mutually exclusive with `--command`/`-e`.
///
///     Diff forms (the repository is the one containing
///     `--working-directory`, else the caller's cwd):
///       - `git-status:` — working tree: staged, unstaged and untracked
///       - `git-diff:<a>...<b>` — a range (three-dot = merge base)
///       - `git-diff:<sha>` — that commit's own changes
///       - `git-diff:` — this branch against main/master/origin HEAD
///
///   * `--working-directory=<directory>`: The working directory to pass to Ghoztty.
///
///   * `--title`: A title that will override the title of the first surface in
///     the new window. The title override may be edited or removed later.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute inside the first surface of the new window instead of the
///     default command.
///
///   * `--target=<name>`: Register this window with a name. If a window
///     with this name already exists, it is focused instead of creating
///     a new one. Named windows can be targeted by `+split` and `+close`.
///
///   * `--split=right|down|left|up`: After creating the new window, create a
///     split in the given direction.
///
///   * `--split-command=<command>`: The command to run in the split pane.
///     Only meaningful when `--split` is also specified.
///
///   * `--shell=<path>`: The shell to use when running `--command` or
///     `--split-command`. The shell is invoked with `-lic` so the user's
///     profile is loaded. Defaults to the `command-shell` config, then
///     `$SHELL`, then `/bin/zsh`.
///
///   * `--split-percent=<1-99>`: The percentage of space allocated to the
///     new split pane. Defaults to 50. Only meaningful when `--split` is
///     also specified. Values outside 1-99 return an error.
///
///   * `--env=<KEY=VALUE>`: Set an environment variable in the spawned
///     process. Can be specified multiple times for multiple variables.
///     Values are passed through literally (no shell expansion).
///
///   * `--color=<#hex>`: A hex color (e.g. `#1a1a2e` or `#abc`) to apply
///     as a background tint on the new window.
///
///   * `--split-color=<#hex>`: A hex color to apply as a background tint
///     on the initial split pane. Only meaningful when `--split` is also
///     specified.
///
///   * `--no-activate`: Create the window without activating the app or
///     stealing focus. The window is created and visible but remains in
///     the background. Also suppresses focus when an existing `--target`
///     is found.
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

    // Print out any diagnostics, unless it's likely that the diagnostic was
    // generated trying to parse a "normal" configuration setting. Exit with an
    // error code if any diagnostics were printed.
    if (!opts._diagnostics.empty()) {
        var exit: bool = false;
        outer: for (opts._diagnostics.items()) |diagnostic| {
            if (diagnostic.location != .cli) continue :outer;
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key)) {
                    try stderr.print("config error: {f}\n", .{diagnostic});
                    exit = true;
                }
            }
        }
        if (exit) return 1;
    }

    if (!opts._working_directory_seen) {
        const alloc = opts._arena.?.allocator();
        const cwd: std.fs.Dir = std.fs.cwd();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const wd = try cwd.realpath(".", &buf);
        // This should be inserted at the beginning of the list, just in case `-e` was used.
        try opts._arguments.insert(alloc, 0, try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{wd}, 0));
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    try view_arg.resolve(alloc, opts._arguments.items);

    const arguments = if (opts._arguments.items.len == 0) null else opts._arguments.items;

    if (apprt.App.performIpc(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .new_window,
        .{
            .arguments = arguments,
        },
    ) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("No running Ghoztty instance found. Launch Ghoztty first.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    // sendIpc already printed the server's error text (if any) to stderr.
    try stderr.print("+new-window failed.\n", .{});
    return 1;
}

// `--view=` resolution is shared with `+split`: see `cli/view_arg.zig`.
// (This command always inserts the caller's cwd as `--working-directory`
// when none was given, so the resolve base is always present here.)
