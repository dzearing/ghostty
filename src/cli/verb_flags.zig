//! Flag allowlists for the FORWARDING verbs — the ones whose
//! `parseManuallyHook` collects the whole command line and hands it to the
//! running instance over IPC (`+close`, `+split`, `+new-window`, ...).
//!
//! Why the check lives here and not in the server: the server parses these
//! arguments with `apprt.ipc.args.parseVerbArgs`, which ignores an argument
//! it does not recognize ON PURPOSE. That tolerance is the app↔CLI
//! compatibility contract — a Ghoztty that has been running for a week must
//! not hard-fail on a flag a newer CLI learned this morning (`--cwd-implicit`
//! and `--keys-resolved=` both rely on it). So the server cannot be the one to
//! complain, and before T852 nobody was: a mistyped `--targt=dev` reached the
//! server, was dropped, and the verb did something ELSE at exit 0.
//!
//! "Hard error on an unknown flag is the CLI's rule, not the server's". The
//! CLI knows exactly which flags each verb has, so it is the honest place to
//! say so — the same call `+send-keys` made in T489.
//!
//! The allowlists below are the flags the SERVER HANDLERS actually read, not
//! the flags the doc comments happen to list: a spelling that works today
//! keeps working, including the aliases the shared parser maps
//! (`--split=`/`--direction=`, `--split-percent=`/`--percent=`), plus the
//! handful the CLI consumes itself (`--class=`) or inserts
//! (`--cwd-implicit`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");

/// One verb's accepted flags.
pub const Spec = struct {
    /// The verb as a user types it, `+split`. Used in the error message.
    verb: []const u8,

    /// Every flag the verb accepts, WITHOUT the leading `--` and without a
    /// trailing `=`. Whether a flag carries a value is not encoded: the check
    /// compares the name before the `=`, so `--target=dev` and `--target`
    /// both match the entry `target`. (A known flag written without its value
    /// is a separate defect — the server drops it just as silently — tracked
    /// on its own rather than folded in here.)
    flags: []const []const u8,
};

/// The flag name in `arg` when it is a `--flag` this verb does not accept;
/// null when the argument is fine to forward.
///
/// Only `--` arguments are checked. A single-dash argument is not a typo of
/// anything here — `-e` starts a command tail, and `+set-banner` text may
/// legitimately begin with a dash — so it passes through as content.
pub fn unknownFlag(spec: Spec, arg: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    if (arg.len == 2) return null;

    const body = arg[2..];
    const name = if (std.mem.indexOfScalar(u8, body, '=')) |i| body[0..i] else body;
    for (spec.flags) |flag| {
        if (std.mem.eql(u8, name, flag)) return null;
    }
    return name;
}

/// Per-verb flag state, embedded in a forwarding verb's `Options` as
/// `_flags`. Two jobs: remember the first flag that was not understood (so
/// `runArgs`, which has a writer, can report it) and honor a bare `--`.
pub const Checker = struct {
    spec: Spec,

    /// The first argument that looked like a flag and was not one. Recorded
    /// rather than thrown, because the parse hook has nothing to explain
    /// itself with.
    unknown: ?[]const u8 = null,

    /// Set by a bare `--`: nothing after it is a flag.
    flags_done: bool = false,

    /// `--help` past the first position, which `args.parse` only checks for
    /// at the front. Without this it would be reported as an unknown flag,
    /// which is a worse answer than the help it asked for. `-h` is NOT
    /// checked: a single dash is content on these verbs (`+set-banner` text).
    help_requested: bool = false,

    /// Classify one argument. Returns true when it should be FORWARDED to the
    /// server, false when the CLI consumed it.
    ///
    /// What is consumed: a bare `--`, which stops flag parsing, and a late
    /// `--help`. Neither must travel — `+set-banner` treats every non-flag
    /// argument as banner text, so a forwarded `--` would render as two
    /// literal dashes.
    pub fn accept(self: *Checker, alloc: Allocator, arg: []const u8) Allocator.Error!bool {
        if (self.flags_done) return true;

        if (std.mem.eql(u8, arg, "--")) {
            self.flags_done = true;
            return false;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            self.help_requested = true;
            return false;
        }

        if (unknownFlag(self.spec, arg)) |name| {
            if (self.unknown == null) self.unknown = try alloc.dupe(u8, name);
        }

        return true;
    }

    /// Report the first unknown flag, if there was one. Returns true when the
    /// verb must exit non-zero without doing its work.
    ///
    /// The message shape is T489's, so a typo reads the same whichever verb
    /// it landed on: the verb, the flag by name, the nearest valid spelling
    /// when it is close, and a `--help` pointer.
    pub fn report(self: *const Checker, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
        const name = self.unknown orelse return false;

        try writer.print("{s}: unknown flag --{s}", .{ self.spec.verb, name });
        if (args.nearestName(self.spec.flags, name)) |suggestion| {
            try writer.print(" (did you mean --{s}?)", .{suggestion});
        }
        try writer.writeAll("\n");
        try writer.print("run 'ghoztty {s} --help' for usage\n", .{self.spec.verb});
        return true;
    }
};

// -- The allowlists --------------------------------------------------------
//
// Each list is "what a server handler reads for this verb", taken from the
// win32 handlers (`apprt/win32/IpcHandlers.zig`) and the macOS ones
// (`macos/Sources/Features/IPC/IPCServer.swift`) together — the CLI is shared,
// so a flag EITHER server honors has to survive the check.

pub const close: Spec = .{
    .verb = "+close",
    .flags = &.{"target"},
};

pub const rename: Spec = .{
    .verb = "+rename",
    .flags = &.{ "target", "title" },
};

pub const rearrange: Spec = .{
    .verb = "+rearrange",
    .flags = &.{ "target", "layout" },
};

pub const read: Spec = .{
    .verb = "+read",
    .flags = &.{ "name", "lines" },
};

pub const set_banner: Spec = .{
    .verb = "+set-banner",
    .flags = &.{ "target", "clear" },
};

pub const set_state: Spec = .{
    .verb = "+set-state",
    .flags = &.{ "target", "state" },
};

pub const reload: Spec = .{
    .verb = "+reload",
    .flags = &.{"target"},
};

/// `--split=`/`--direction=` and `--split-percent=`/`--percent=` are aliases
/// in the shared parser, and the skill's own examples use the `--split-*`
/// spellings on `+split`, so both survive.
pub const split: Spec = .{
    .verb = "+split",
    .flags = &.{
        "target",
        "name",
        "pane",
        "direction",
        "split",
        "percent",
        "split-percent",
        "from-focused",
        "view",
        "command",
        "split-command",
        "shell",
        "env",
        "color",
        "working-directory",
    },
};

/// `--class=` is consumed by the CLI itself (it picks WHICH instance to talk
/// to) and `--cwd-implicit` is inserted by the CLI, so both belong here even
/// though no handler field is named for them.
pub const new_window: Spec = .{
    .verb = "+new-window",
    .flags = &.{
        "class",
        "target",
        "name",
        "title",
        "command",
        "view",
        "working-directory",
        "shell",
        "env",
        "color",
        "split-color",
        "split",
        "direction",
        "split-command",
        "split-percent",
        "percent",
        "no-activate",
        "from-focused",
        "cwd-implicit",
    },
};

pub const new_remote_window: Spec = .{
    .verb = "+new-remote-window",
    .flags = &.{
        "host",
        "port",
        "relay",
        "device",
        "token",
        "name",
        "title",
        "working-directory",
        "shell",
        "command",
        "no-activate",
    },
};

// -- Tests -----------------------------------------------------------------

const testing = std.testing;

test "unknownFlag: an accepted flag with a value passes" {
    try testing.expect(unknownFlag(split, "--target=dev") == null);
    try testing.expect(unknownFlag(split, "--from-focused") == null);
    try testing.expect(unknownFlag(close, "--target=dev") == null);
}

test "unknownFlag: a misspelling is named without its value" {
    try testing.expectEqualStrings("targt", unknownFlag(split, "--targt=dev").?);
    try testing.expectEqualStrings("bogus-flag", unknownFlag(close, "--bogus-flag=1").?);
}

test "unknownFlag: another verb's flag is still unknown here" {
    // The whole point of per-verb lists: `--layout=` is real, just not on
    // `+close`, and forwarding it there did nothing at exit 0.
    try testing.expectEqualStrings("layout", unknownFlag(close, "--layout={}").?);
    try testing.expectEqualStrings("state", unknownFlag(reload, "--state=busy").?);
}

test "unknownFlag: single-dash arguments and a bare -- are not flags" {
    // `-e` starts a command tail; `-la` is content. Neither is a typo of a
    // long flag, so neither is checked.
    try testing.expect(unknownFlag(split, "-e") == null);
    try testing.expect(unknownFlag(set_banner, "-la") == null);
    try testing.expect(unknownFlag(set_banner, "--") == null);
    try testing.expect(unknownFlag(set_banner, "ready to merge") == null);
}

test "Checker: records the FIRST unknown flag and keeps forwarding" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;

    try testing.expect(try checker.accept(alloc, "--target=dev"));
    try testing.expect(try checker.accept(alloc, "--dirction=right"));
    try testing.expect(try checker.accept(alloc, "--also-bogus=1"));
    defer alloc.free(checker.unknown.?);

    try testing.expectEqualStrings("dirction", checker.unknown.?);
}

test "Checker: a late --help asks for help rather than being a typo" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;

    // `args.parse` only looks for --help at the front; anywhere else it lands
    // here, and "unknown flag --help" would be a worse answer than the help.
    try testing.expect(try checker.accept(alloc, "--target=x"));
    try testing.expect(!try checker.accept(alloc, "--help"));

    try testing.expect(checker.help_requested);
    try testing.expect(checker.unknown == null);
}

test "Checker: a bare -- is consumed and stops flag checking" {
    var checker: Checker = .{ .spec = set_banner };
    const alloc = testing.allocator;

    // A banner line that starts with dashes is TEXT, and the escape hatch is
    // the same one `+send-keys` has. The `--` itself must not be forwarded:
    // the server would render it as banner text.
    try testing.expect(try checker.accept(alloc, "--target=dev"));
    try testing.expect(!try checker.accept(alloc, "--"));
    try testing.expect(try checker.accept(alloc, "--- build failed ---"));

    try testing.expect(checker.unknown == null);
    try testing.expect(checker.flags_done);
}

test "Checker.report: names the verb, the flag, and the nearest spelling" {
    var checker: Checker = .{ .spec = split };
    const alloc = testing.allocator;
    try testing.expect(try checker.accept(alloc, "--dirction=right"));
    defer alloc.free(checker.unknown.?);

    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try testing.expect(try checker.report(&out));

    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "+split: unknown flag --dirction") != null);
    try testing.expect(std.mem.indexOf(u8, text, "did you mean --direction?") != null);
    try testing.expect(std.mem.indexOf(u8, text, "run 'ghoztty +split --help' for usage") != null);
}

test "Checker.report: a distant typo gets no suggestion, and a clean parse says nothing" {
    var checker: Checker = .{ .spec = close };
    const alloc = testing.allocator;
    try testing.expect(try checker.accept(alloc, "--bogus-flag=1"));
    defer alloc.free(checker.unknown.?);

    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try testing.expect(try checker.report(&out));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "did you mean") == null);

    var clean: Checker = .{ .spec = close };
    try testing.expect(try clean.accept(alloc, "--target=dev"));
    var clean_buf: [64]u8 = undefined;
    var clean_out: std.Io.Writer = .fixed(&clean_buf);
    try testing.expect(!try clean.report(&clean_out));
    try testing.expectEqual(@as(usize, 0), clean_out.buffered().len);
}

// Every flag a verb accepts must be spelled the way it is written on the
// command line: no leading dashes, no trailing `=`. A stray one would make
// the flag it names unmatchable, which is the silent drop this file exists
// to remove — wearing the mask of a fix.
test "specs: flag names are bare" {
    const all = [_]Spec{
        close,    rename,     rearrange,  read,       set_banner,
        set_state, reload,    split,      new_window, new_remote_window,
    };
    for (all) |spec| {
        try testing.expect(std.mem.startsWith(u8, spec.verb, "+"));
        for (spec.flags) |flag| {
            try testing.expect(flag.len > 0);
            try testing.expect(flag[0] != '-');
            try testing.expect(flag[flag.len - 1] != '=');
        }
    }
}
