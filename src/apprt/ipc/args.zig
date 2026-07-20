//! Pure verb-argument logic shared by IPC servers: flag parsing (the Mac
//! server's prefix table), the Windows shell-flavor wrap table, and ConPTY
//! input normalization. No platform imports — everything here is unit
//! tested in the none-runtime test build.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const EnvVar = struct { key: []const u8, value: []const u8 };

/// Flags shared by the window/pane verbs, parsed with the same prefix table
/// as the Mac server (unknown flags are ignored there too). Slices reference
/// the input arguments except `e_args`, which are duped (sentinel needed).
pub const VerbArgs = struct {
    target: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    title: ?[]const u8 = null,
    split_direction: ?[]const u8 = null,
    split_command: ?[]const u8 = null,
    name: ?[]const u8 = null,
    state: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    percent: ?i64 = null,
    lines: ?i64 = null,
    layout: ?[]const u8 = null,
    /// `+new-remote-window --host/--port`: direct TCP dial to a listening
    /// ghoztty-agent. Port 0 ⇒ absent/invalid (0 is not a dialable port).
    host: ?[]const u8 = null,
    port: u16 = 0,
    /// `+new-remote-window --relay/--device/--token`: rendezvous-relay dial
    /// (T21). Parsed now so the T20 handler can refuse them explicitly.
    relay: ?[]const u8 = null,
    device: ?[]const u8 = null,
    token: ?[]const u8 = null,
    /// `+list --pid=<pid>`: resolve the pane whose shell is an ancestor
    /// of this process id (Windows; the tty-less equivalent of --tty).
    pid: ?u32 = null,
    /// `--color` / `--split-color` (T67): background tint for the new
    /// window/pane and for `+new-window`'s inline split. Values are raw
    /// strings here (`#rgb`, `#rrggbb`, or `random`) — resolution happens
    /// in the handler so parse errors can be ignored Mac-style.
    color: ?[]const u8 = null,
    split_color: ?[]const u8 = null,
    no_activate: bool = false,
    /// `+new-window --from-focused` / `+split --from-focused`: mirror the
    /// keyboard "New Window"/split action on the focused window so the new
    /// frame inherits its remote host (T68, Mac §WP4 parity).
    from_focused: bool = false,
    env: []const EnvVar = &.{},
    /// Trailing `-e` arguments: exec this argv directly, no shell wrap.
    e_args: []const [:0]const u8 = &.{},
};

pub fn parseVerbArgs(
    arena: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error!VerbArgs {
    var result: VerbArgs = .{};
    const args = arguments orelse return result;

    var env: std.ArrayList(EnvVar) = .empty;
    var e_args: std.ArrayList([:0]const u8) = .empty;
    var e_flag = false;

    for (args) |arg| {
        if (e_flag) {
            try e_args.append(arena, try arena.dupeZ(u8, arg));
            continue;
        }
        if (std.mem.eql(u8, arg, "-e")) {
            e_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-activate")) {
            result.no_activate = true;
        } else if (std.mem.eql(u8, arg, "--from-focused")) {
            result.from_focused = true;
        } else if (dropPrefix(arg, "--working-directory=")) |v| {
            result.working_directory = v;
        } else if (dropPrefix(arg, "--command=")) |v| {
            result.command = v;
        } else if (dropPrefix(arg, "--shell=")) |v| {
            result.shell = v;
        } else if (dropPrefix(arg, "--title=")) |v| {
            result.title = v;
        } else if (dropPrefix(arg, "--split=")) |v| {
            result.split_direction = v;
        } else if (dropPrefix(arg, "--direction=")) |v| {
            result.split_direction = v;
        } else if (dropPrefix(arg, "--split-command=")) |v| {
            result.split_command = v;
        } else if (dropPrefix(arg, "--target=")) |v| {
            result.target = v;
        } else if (dropPrefix(arg, "--name=")) |v| {
            result.name = v;
        } else if (dropPrefix(arg, "--state=")) |v| {
            result.state = v;
        } else if (dropPrefix(arg, "--pane=")) |v| {
            result.pane = v;
        } else if (dropPrefix(arg, "--lines=")) |v| {
            result.lines = std.fmt.parseInt(i64, v, 10) catch null;
        } else if (dropPrefix(arg, "--layout=")) |v| {
            result.layout = v;
        } else if (dropPrefix(arg, "--host=")) |v| {
            result.host = v;
        } else if (dropPrefix(arg, "--port=")) |v| {
            result.port = std.fmt.parseInt(u16, v, 10) catch 0;
        } else if (dropPrefix(arg, "--relay=")) |v| {
            result.relay = v;
        } else if (dropPrefix(arg, "--device=")) |v| {
            result.device = v;
        } else if (dropPrefix(arg, "--token=")) |v| {
            result.token = v;
        } else if (dropPrefix(arg, "--pid=")) |v| {
            result.pid = std.fmt.parseInt(u32, v, 10) catch null;
        } else if (dropPrefix(arg, "--percent=")) |v| {
            result.percent = std.fmt.parseInt(i64, v, 10) catch -1;
        } else if (dropPrefix(arg, "--split-percent=")) |v| {
            result.percent = std.fmt.parseInt(i64, v, 10) catch -1;
        } else if (dropPrefix(arg, "--color=")) |v| {
            result.color = v;
        } else if (dropPrefix(arg, "--split-color=")) |v| {
            result.split_color = v;
        } else if (dropPrefix(arg, "--env=")) |v| {
            if (std.mem.indexOfScalar(u8, v, '=')) |eq| {
                try env.append(arena, .{
                    .key = v[0..eq],
                    .value = v[eq + 1 ..],
                });
            }
        }
        // Unknown flags are ignored, matching the Mac server's prefix table.
    }

    result.env = env.items;
    result.e_args = e_args.items;
    return result;
}

pub fn dropPrefix(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

/// `+set-banner` arguments (T35), Mac handleSetBanner parity: `--target=`
/// and `--clear` are flags; every other argument is banner text, joined
/// with spaces. A literal `\n` becomes a line break so multi-line banners
/// can be set from one shell argument; surrounding whitespace/newlines are
/// trimmed (a stray trailing newline must not render as a blank line);
/// empty text implies clear.
pub const SetBannerArgs = struct {
    target: ?[]const u8 = null,
    /// Arena-allocated: joined, `\n`-unescaped, trimmed.
    text: []const u8 = "",
    clear: bool = false,
};

pub fn parseSetBannerArgs(
    arena: Allocator,
    arguments: ?[]const []const u8,
) Allocator.Error!SetBannerArgs {
    var result: SetBannerArgs = .{};
    const args = arguments orelse {
        result.clear = true;
        return result;
    };

    var parts: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (dropPrefix(arg, "--target=")) |v| {
            result.target = v;
        } else if (std.mem.eql(u8, arg, "--clear")) {
            result.clear = true;
        } else {
            try parts.append(arena, arg);
        }
    }

    const joined = try std.mem.join(arena, " ", parts.items);
    const unescaped = try std.mem.replaceOwned(u8, arena, joined, "\\n", "\n");
    result.text = std.mem.trim(u8, unescaped, " \t\r\n");
    if (result.text.len == 0) result.clear = true;
    return result;
}

/// The Windows shell-flavor table (spec, "Architecture decisions"): build
/// the argv that runs `command` inside `shell`. The config Command
/// `.direct` argv form is required on Windows — the `.shell` path
/// whitespace-splits with no quoting rules.
///
/// Every flavor keeps the shell ALIVE after the command (Mac behavior:
/// `shell -lic '<cmd>; exec shell -li'`).
///
///   pwsh / powershell  -> shell -NoExit -Command <cmd>
///   cmd                -> shell /K <cmd>
///   wsl                -> shell -- <cmd>   (runs in the default distro;
///                         exits with the command — no login shell there)
///   nu / nushell       -> shell -e <cmd>
///   anything else      -> shell -lic "<cmd>; exec \"shell\" -li"
///                         (posix shells, e.g. git-bash)
pub fn wrapShellCommandArgv(
    arena: Allocator,
    shell: []const u8,
    command: []const u8,
) Allocator.Error![]const [:0]const u8 {
    var base = std.fs.path.basename(shell);
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];

    var argv: std.ArrayList([:0]const u8) = .empty;
    try argv.append(arena, try arena.dupeZ(u8, shell));
    if (std.ascii.eqlIgnoreCase(base, "pwsh") or
        std.ascii.eqlIgnoreCase(base, "powershell"))
    {
        try argv.append(arena, "-NoExit");
        try argv.append(arena, "-Command");
        try argv.append(arena, try arena.dupeZ(u8, command));
    } else if (std.ascii.eqlIgnoreCase(base, "cmd")) {
        try argv.append(arena, "/K");
        try argv.append(arena, try arena.dupeZ(u8, command));
    } else if (std.ascii.eqlIgnoreCase(base, "wsl")) {
        try argv.append(arena, "--");
        try argv.append(arena, try arena.dupeZ(u8, command));
    } else if (std.ascii.eqlIgnoreCase(base, "nu") or
        std.ascii.eqlIgnoreCase(base, "nushell"))
    {
        try argv.append(arena, "-e");
        try argv.append(arena, try arena.dupeZ(u8, command));
    } else {
        // Mac parity: run the command, then exec a login shell so the pane
        // survives with the profile loaded. The exec target is quoted for
        // spaced Windows paths (C:\Program Files\Git\bin\bash.exe).
        try argv.append(arena, "-lic");
        try argv.append(arena, try std.fmt.allocPrintSentinel(
            arena,
            "{s}; exec \"{s}\" -li",
            .{ command, shell },
            0,
        ));
    }
    return argv.items;
}

/// ConPTY input convention: Enter is CR. A bare LF never comes from a real
/// keyboard and Windows shells don't execute on it, but the send-keys `\n`
/// notation means "Enter" to the user — normalize LF and CRLF to CR.
/// Returns an owned slice (length <= bytes.len).
pub fn normalizeConptyInput(alloc: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const normalized = try alloc.alloc(u8, bytes.len);
    errdefer alloc.free(normalized);
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b == '\n') {
            normalized[n] = '\r';
        } else if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            normalized[n] = '\r';
            i += 1;
        } else {
            normalized[n] = b;
        }
        n += 1;
    }
    return alloc.realloc(normalized, n) catch normalized[0..n];
}

/// Validate a `+rearrange` layout node (shape + direction) and collect its
/// pane names in traversal order. Returns an error MESSAGE (arena-owned)
/// or null when valid — callers wrap it in their error response.
pub fn validateLayout(
    arena: Allocator,
    node: std.json.Value,
    names: *std.ArrayList([]const u8),
) Allocator.Error!?[]u8 {
    if (node != .object)
        return try arena.dupe(u8, "layout node must have either 'pane' or 'direction'");
    const obj = node.object;

    if (obj.get("pane")) |pane| {
        if (pane != .string)
            return try arena.dupe(u8, "layout node must have either 'pane' or 'direction'");
        try names.append(arena, pane.string);
        return null;
    }

    const direction = obj.get("direction") orelse
        return try arena.dupe(u8, "layout node must have either 'pane' or 'direction'");
    if (direction != .string or
        (!std.ascii.eqlIgnoreCase(direction.string, "horizontal") and
            !std.ascii.eqlIgnoreCase(direction.string, "vertical")))
    {
        return try std.fmt.allocPrint(
            arena,
            "invalid direction '{s}' (expected 'horizontal' or 'vertical')",
            .{if (direction == .string) direction.string else "?"},
        );
    }
    const left = obj.get("left") orelse
        return try arena.dupe(u8, "split node must have 'left' child");
    const right = obj.get("right") orelse
        return try arena.dupe(u8, "split node must have 'right' child");

    if (try validateLayout(arena, left, names)) |err| return err;
    if (try validateLayout(arena, right, names)) |err| return err;
    return null;
}

/// First duplicate in `names`, or null. (+rearrange rejects duplicates.)
pub fn firstDuplicate(names: []const []const u8) ?[]const u8 {
    for (names, 0..) |a, i| {
        for (names[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) return a;
        }
    }
    return null;
}

// -----------------------------------------------------------------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "parseSetBannerArgs: text joined, \\n unescaped, trimmed" {
    var arena = testArena();
    defer arena.deinit();
    const args = [_][]const u8{ "--target=dev", "**PR #1**", "ready\\nline2 " };
    const parsed = try parseSetBannerArgs(arena.allocator(), &args);
    try testing.expectEqualStrings("dev", parsed.target.?);
    try testing.expectEqualStrings("**PR #1** ready\nline2", parsed.text);
    try testing.expect(!parsed.clear);
}

test "parseSetBannerArgs: --clear, empty text implies clear, no args" {
    var arena = testArena();
    defer arena.deinit();

    const cleared = try parseSetBannerArgs(arena.allocator(), &[_][]const u8{
        "--target=dev", "--clear", "ignored text",
    });
    try testing.expect(cleared.clear);
    try testing.expectEqualStrings("dev", cleared.target.?);

    const empty = try parseSetBannerArgs(arena.allocator(), &[_][]const u8{
        "--target=dev", "  ", "\\n",
    });
    try testing.expect(empty.clear);

    const none = try parseSetBannerArgs(arena.allocator(), null);
    try testing.expect(none.clear);
    try testing.expect(none.target == null);
}

test "parseVerbArgs: full flag set" {
    var arena = testArena();
    defer arena.deinit();
    const args = [_][]const u8{
        "--target=dev",              "--working-directory=C:\\src", "--command=npm run dev",
        "--shell=pwsh",              "--title=Dev",                 "--split=down",
        "--split-command=htop",      "--name=term",                 "--state=busy",
        "--pane=logs",               "--percent=30",                "--lines=10",
        "--no-activate",             "--env=A=1",                   "--env=B=x=y",
        "--layout={\"pane\":\"a\"}", "--pid=4242",
        "--from-focused",            "--color=#334455",
        "--split-color=random",
    };
    const parsed = try parseVerbArgs(arena.allocator(), &args);
    try testing.expectEqualStrings("dev", parsed.target.?);
    try testing.expectEqualStrings("C:\\src", parsed.working_directory.?);
    try testing.expectEqualStrings("npm run dev", parsed.command.?);
    try testing.expectEqualStrings("pwsh", parsed.shell.?);
    try testing.expectEqualStrings("Dev", parsed.title.?);
    try testing.expectEqualStrings("down", parsed.split_direction.?);
    try testing.expectEqualStrings("htop", parsed.split_command.?);
    try testing.expectEqualStrings("term", parsed.name.?);
    try testing.expectEqualStrings("busy", parsed.state.?);
    try testing.expectEqualStrings("logs", parsed.pane.?);
    try testing.expectEqual(@as(?i64, 30), parsed.percent);
    try testing.expectEqual(@as(?i64, 10), parsed.lines);
    try testing.expect(parsed.no_activate);
    try testing.expect(parsed.from_focused);
    try testing.expectEqualStrings("#334455", parsed.color.?);
    try testing.expectEqualStrings("random", parsed.split_color.?);
    try testing.expectEqual(@as(usize, 2), parsed.env.len);
    try testing.expectEqualStrings("A", parsed.env[0].key);
    try testing.expectEqualStrings("1", parsed.env[0].value);
    // --env values may themselves contain '=': split on the FIRST one.
    try testing.expectEqualStrings("B", parsed.env[1].key);
    try testing.expectEqualStrings("x=y", parsed.env[1].value);
    try testing.expectEqualStrings("{\"pane\":\"a\"}", parsed.layout.?);
    try testing.expectEqual(@as(?u32, 4242), parsed.pid);
}

test "parseVerbArgs: -e captures everything after, no flag parsing" {
    var arena = testArena();
    defer arena.deinit();
    const args = [_][]const u8{ "--target=x", "-e", "cmd", "/K", "--target=not-a-flag" };
    const parsed = try parseVerbArgs(arena.allocator(), &args);
    try testing.expectEqualStrings("x", parsed.target.?);
    try testing.expectEqual(@as(usize, 3), parsed.e_args.len);
    try testing.expectEqualStrings("--target=not-a-flag", parsed.e_args[2]);
}

test "parseVerbArgs: remote-window flags (--host/--port/--relay/--device/--token)" {
    var arena = testArena();
    defer arena.deinit();
    const args = [_][]const u8{
        "--host=winbox", "--port=7777",     "--relay=https://r.example",
        "--device=dev1", "--token=abc.def",
    };
    const parsed = try parseVerbArgs(arena.allocator(), &args);
    try testing.expectEqualStrings("winbox", parsed.host.?);
    try testing.expectEqual(@as(u16, 7777), parsed.port);
    try testing.expectEqualStrings("https://r.example", parsed.relay.?);
    try testing.expectEqualStrings("dev1", parsed.device.?);
    try testing.expectEqualStrings("abc.def", parsed.token.?);
}

test "parseVerbArgs: bad or out-of-range --port parses as 0 (absent)" {
    var arena = testArena();
    defer arena.deinit();
    for ([_][]const u8{ "--port=abc", "--port=70000", "--port=-1", "--port=" }) |bad| {
        const args = [_][]const u8{bad};
        const parsed = try parseVerbArgs(arena.allocator(), &args);
        try testing.expectEqual(@as(u16, 0), parsed.port);
    }
}

test "parseVerbArgs: --direction aliases --split" {
    var arena = testArena();
    defer arena.deinit();
    const args = [_][]const u8{"--direction=left"};
    const parsed = try parseVerbArgs(arena.allocator(), &args);
    try testing.expectEqualStrings("left", parsed.split_direction.?);
}

test "wrapShellCommandArgv: every flavor branch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { shell: []const u8, expect: []const []const u8 }{
        .{ .shell = "pwsh", .expect = &.{ "pwsh", "-NoExit", "-Command", "echo hi" } },
        .{ .shell = "pwsh.exe", .expect = &.{ "pwsh.exe", "-NoExit", "-Command", "echo hi" } },
        .{ .shell = "C:\\Program Files\\PowerShell\\7\\pwsh.exe", .expect = &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoExit", "-Command", "echo hi" } },
        .{ .shell = "PowerShell.exe", .expect = &.{ "PowerShell.exe", "-NoExit", "-Command", "echo hi" } },
        .{ .shell = "cmd.exe", .expect = &.{ "cmd.exe", "/K", "echo hi" } },
        .{ .shell = "CMD", .expect = &.{ "CMD", "/K", "echo hi" } },
        .{ .shell = "wsl.exe", .expect = &.{ "wsl.exe", "--", "echo hi" } },
        .{ .shell = "nu", .expect = &.{ "nu", "-e", "echo hi" } },
        .{ .shell = "nushell.exe", .expect = &.{ "nushell.exe", "-e", "echo hi" } },
        .{ .shell = "C:\\Program Files\\Git\\bin\\bash.exe", .expect = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "-lic", "echo hi; exec \"C:\\Program Files\\Git\\bin\\bash.exe\" -li" } },
        .{ .shell = "zsh", .expect = &.{ "zsh", "-lic", "echo hi; exec \"zsh\" -li" } },
    };
    for (cases) |case| {
        const argv = try wrapShellCommandArgv(alloc, case.shell, "echo hi");
        try testing.expectEqual(case.expect.len, argv.len);
        for (case.expect, argv) |want, got| try testing.expectEqualStrings(want, got);
    }
}

test "normalizeConptyInput: LF and CRLF become CR, lone CR unchanged" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "echo hi\n", .out = "echo hi\r" },
        .{ .in = "a\r\nb", .out = "a\rb" },
        .{ .in = "a\rb", .out = "a\rb" },
        .{ .in = "a\n\nb", .out = "a\r\rb" },
        .{ .in = "plain", .out = "plain" },
        .{ .in = "", .out = "" },
        .{ .in = "\r\n", .out = "\r" },
    };
    for (cases) |case| {
        const got = try normalizeConptyInput(testing.allocator, case.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.out, got);
    }
}

test "validateLayout: valid nested layout collects names in order" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const layout = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"direction":"horizontal","ratio":30,"left":{"pane":"a"},
        \\ "right":{"direction":"VERTICAL","left":{"pane":"b"},"right":{"pane":"c"}}}
    , .{});
    var names: std.ArrayList([]const u8) = .empty;
    try testing.expectEqual(@as(?[]u8, null), try validateLayout(alloc, layout, &names));
    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("a", names.items[0]);
    try testing.expectEqualStrings("b", names.items[1]);
    try testing.expectEqualStrings("c", names.items[2]);
}

test "validateLayout: error messages" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    const cases = [_]struct { json: []const u8, msg: []const u8 }{
        .{ .json = "{\"direction\":\"diagonal\",\"left\":{\"pane\":\"a\"},\"right\":{\"pane\":\"b\"}}", .msg = "invalid direction 'diagonal' (expected 'horizontal' or 'vertical')" },
        .{ .json = "{\"direction\":\"horizontal\",\"right\":{\"pane\":\"b\"}}", .msg = "split node must have 'left' child" },
        .{ .json = "{\"direction\":\"horizontal\",\"left\":{\"pane\":\"a\"}}", .msg = "split node must have 'right' child" },
        .{ .json = "{\"ratio\":50}", .msg = "layout node must have either 'pane' or 'direction'" },
        .{ .json = "[1,2]", .msg = "layout node must have either 'pane' or 'direction'" },
    };
    for (cases) |case| {
        const layout = try std.json.parseFromSliceLeaky(std.json.Value, alloc, case.json, .{});
        var names: std.ArrayList([]const u8) = .empty;
        const err = (try validateLayout(alloc, layout, &names)).?;
        try testing.expectEqualStrings(case.msg, err);
    }
}

test "firstDuplicate" {
    try testing.expectEqual(@as(?[]const u8, null), firstDuplicate(&.{ "a", "b", "c" }));
    try testing.expectEqualStrings("b", firstDuplicate(&.{ "a", "b", "c", "b" }).?);
    try testing.expectEqual(@as(?[]const u8, null), firstDuplicate(&.{}));
}
