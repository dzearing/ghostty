const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const Action = @import("ghostty.zig").Action;

fn padding(comptime name_len: usize) []const u8 {
    const col = 20;
    const pad_len = if (name_len < col) col - name_len else 2;
    return " " ** pad_len;
}

// Note that this options struct doesn't implement the `help` decl like other
// actions. That is because the help command is special and wants to handle its
// own logic around help detection.
pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// This must be registered so that it isn't an error to pass `--help`
    help: bool = false,

    /// `-h` is this action's own spelling: without a `help` decl (see the
    /// struct comment) the parser would report it as an unexpected
    /// argument. Everything from here on is help anyway, so stop parsing.
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!bool {
        _ = alloc;
        _ = iter;
        if (std.mem.eql(u8, arg, "-h")) {
            self.help = true;
            return false;
        }
        return true;
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

/// The `help` command shows general help about Ghostty. Recognized as either
/// `-h, `--help`, or like other actions `+help`.
///
/// You can also specify `--help` or `-h` along with any action such as
/// `+list-themes` to see help for a specific action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    if (args.reportCliDiagnosticsStderr(Options, &opts, "+help", null)) return 1;

    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\Usage: ghostty [+action] [options]
        \\
        \\Run the Ghostty terminal emulator or a specific helper action.
        \\
        \\If no `+action` is specified, run the Ghostty terminal emulator.
        \\All configuration keys are available as command line options.
        \\To specify a configuration key, use the `--<key>=<value>` syntax
        \\where key and value are the same format you'd put into a configuration
        \\file. For example, `--font-size=12` or `--font-family="Fira Code"`.
        \\
        \\To see a list of all available configuration options, please see
        \\the `src/config/Config.zig` file. A future update will allow seeing
        \\the list of configuration options from the command line.
        \\
        \\A special command line argument `-e <command>` can be used to run
        \\the specific command inside the terminal emulator. For example,
        \\`ghoztty -e top` will run the `top` command inside the terminal.
        \\
        \\On macOS, launching the terminal emulator from the CLI is not
        \\supported and only actions are supported. Use `open -na Ghoztty.app`
        \\instead, or `open -na Ghoztty.app --args --foo=bar --baz=quz` to pass
        \\arguments.
        \\
        \\Available actions:
        \\
        \\
    );

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = @field(Action, field.name);
        try stdout.print("  +{s}{s}{s}\n", .{
            field.name,
            padding(field.name.len),
            action.description(),
        });
    }

    try stdout.writeAll(
        \\
        \\Specify `+<action> --help` to see the help for a specific action,
        \\where `<action>` is one of actions listed above.
        \\
    );
    try stdout.flush();

    return 0;
}
