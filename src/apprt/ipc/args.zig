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
    /// `+new-window --view` / `+split --view`: open a VIEWER pane (a file or
    /// a website) instead of a terminal. Parsed here so the win32 server can
    /// answer `--view` explicitly instead of dropping it as an unknown flag
    /// and silently opening a terminal (T90b; viewer panes land in T90c–T90h).
    view: ?[]const u8 = null,
    /// `--color` / `--split-color` (T67): background tint for the new
    /// window/pane and for `+new-window`'s inline split. Values are raw
    /// strings here (`#rgb`, `#rrggbb`, or `random`) — resolution happens
    /// in the handler so parse errors can be ignored Mac-style.
    color: ?[]const u8 = null,
    split_color: ?[]const u8 = null,
    no_activate: bool = false,
    /// `--cwd-implicit` (T135): the CLI auto-inserts `--working-directory=<its
    /// cwd>` when the caller gave none, and marks that insertion with this flag
    /// so the server can tell an explicit request apart from the default. Only
    /// consulted by the dropped-flag note on the idempotent focus path; both
    /// servers ignore it as an unknown flag when older.
    cwd_implicit: bool = false,
    /// `+new-window --from-focused` / `+split --from-focused`: mirror the
    /// keyboard "New Window"/split action on the focused window so the new
    /// frame inherits its remote host (T68, Mac §WP4 parity).
    from_focused: bool = false,
    /// `--caller-pane=<id>` (T1079): the pane the command was invoked FROM,
    /// forwarded from `$GHOZTTY_PANE_ID` by `apprt.ipc.seedCallerPane`. A
    /// DEFAULT anchor only — see `callerAnchorPane` below for the whole rule.
    caller_pane: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, arg, "--cwd-implicit")) {
            result.cwd_implicit = true;
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
        } else if (dropPrefix(arg, caller_pane_flag)) |v| {
            result.caller_pane = v;
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
        } else if (dropPrefix(arg, "--view=")) |v| {
            result.view = v;
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

/// The flag `apprt.ipc.seedCallerPane` adds to carry `$GHOZTTY_PANE_ID` to the
/// app (`apprt.ipc.caller_pane_flag` aliases this, so the spelling the CLI
/// writes and the spelling both servers read cannot drift).
///
/// It is deliberately NOT `--pane=`: an explicit `--pane=` that names nothing
/// is a typo and must stay a hard error, while an implicit caller pane that no
/// longer resolves (the script's own pane was closed - ordinary) must fall
/// back to the app's focused window. The server tells the two apart by which
/// flag carried the name.
pub const caller_pane_flag = "--caller-pane=";

/// The pane a command with no explicit target should anchor at: the one it was
/// invoked FROM, or null to keep the server's focused-window fallback.
///
/// This is the win32 twin of `IPCServer.callerAnchorPane` (Swift) and it is the
/// ONE place the win32 server decides, as `apprt.ipc.seedCallerPane` is the ONE
/// place the CLI produces the flag. It exists because the focused window is
/// read on the app's side at HANDLE time: the user can switch windows between
/// the CLI invocation and the app's turn, and an agent's command is
/// asynchronous with respect to focus even when nobody touches anything.
///
/// Four ways to get null, all of them ordinary:
///
///   * The caller named an anchor of its own. `--target`, `--pane`, and
///     `--from-focused` all say where the command should land, and each wins
///     over the environment's default.
///   * Nothing was forwarded - a plain non-Ghoztty shell, or a pane baked by
///     an app/agent that predates the flag.
///   * The value is empty, which is the same as absent.
///   * The pane id no longer resolves (`isAlive`). A script outliving its own
///     pane is normal, so this falls back rather than failing the command -
///     which is exactly why the CLI sends `--caller-pane=` and not `--pane=`,
///     where a name that resolves to nothing is a typo and a hard error.
pub fn callerAnchorPane(
    args: VerbArgs,
    context: anytype,
    comptime isAlive: fn (@TypeOf(context), []const u8) bool,
) ?[]const u8 {
    if (args.target != null) return null;
    if (args.pane != null) return null;
    if (args.from_focused) return null;
    const caller = args.caller_pane orelse return null;
    if (caller.len == 0) return null;
    if (!isAlive(context, caller)) return null;
    return caller;
}

pub fn dropPrefix(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

/// A viewer pane renders a file or a website; it has no shell, so there is
/// nothing for a command to run in. Byte-matches the Mac server's string
/// (`IPCServer.swift:387` for `+new-window`, `:574` for `+split`).
pub const view_command_conflict_error = "--view cannot be combined with --command/-e";

/// Which kind of viewer a `--view=` value asks for. The split is the one the
/// Phase K band is built on: T374 ships WEB mode (the pane navigates to the URL
/// directly) and T90e ships FILE mode (render the file's content offline).
pub const ViewMode = enum { web, file };

/// Classify a `--view=` value. Deliberately NOT "does it contain `://`":
/// `file:///c:/src/README.md` names a file, and handing it to a browser would
/// render a markdown document as raw text — the silently-wrong-pane defect that
/// the interim error below exists to prevent, one level down.
///
/// Scheme comparison is ASCII case-insensitive because URL schemes are
/// (RFC 3986 §3.1), and a pasted `HTTPS://…` is a URL by any reading.
pub fn viewMode(value: []const u8) ViewMode {
    if (hasSchemePrefix(value, "about:")) return .web;
    if (hasSchemePrefix(value, "http://")) return .web;
    if (hasSchemePrefix(value, "https://")) return .web;
    return .file;
}

fn hasSchemePrefix(value: []const u8, comptime prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

/// Whether `--view` was given alongside a command. `-e` counts: the Mac
/// parser folds trailing `-e` argv into `config.command` before the check,
/// so the two platforms reject the same command lines.
pub fn viewConflictsWithCommand(args: VerbArgs) bool {
    if (args.view == null) return false;
    return args.command != null or args.e_args.len > 0;
}

/// T135: the flags `+new-window` silently ignores when `--target` names a
/// window that already exists (the idempotent rule focuses it instead of
/// recreating). Returns a comma-joined list of the flag names the caller
/// actually passed and lost ("--command, --working-directory"), or null when
/// nothing meaningful was dropped — a bare re-focus stays silent. The CLI's
/// auto-inserted cwd (marked `--cwd-implicit`) is the default, not a request,
/// so it never counts.
pub fn droppedOnExistingTarget(arena: Allocator, args: VerbArgs) Allocator.Error!?[]const u8 {
    var dropped: std.ArrayList([]const u8) = .empty;
    if (args.command != null) try dropped.append(arena, "--command");
    if (args.e_args.len > 0) try dropped.append(arena, "-e");
    if (args.working_directory != null and !args.cwd_implicit)
        try dropped.append(arena, "--working-directory");
    if (args.view != null) try dropped.append(arena, "--view");
    if (args.title != null) try dropped.append(arena, "--title");
    if (args.split_direction != null) try dropped.append(arena, "--split");
    if (args.split_command != null) try dropped.append(arena, "--split-command");
    if (args.split_color != null) try dropped.append(arena, "--split-color");
    if (args.name != null) try dropped.append(arena, "--name");
    if (args.color != null) try dropped.append(arena, "--color");
    if (args.shell != null) try dropped.append(arena, "--shell");
    if (args.env.len > 0) try dropped.append(arena, "--env");
    if (dropped.items.len == 0) return null;
    return try std.mem.join(arena, ", ", dropped.items);
}

/// The directory a `+new-window` auto-launch should start the GUI in (T132),
/// or null to inherit the CLI's own cwd (today's behavior).
///
/// When `+new-window` finds no running instance it spawns one and re-sends the
/// request. Everything that instance starts inherits ITS cwd: the startup
/// window, any `working-directory = inherit` pane, and the session-persistence
/// agent — whose cwd is where a RELAUNCH lands a session that recorded none. A
/// detached launcher (a script, a scheduled task) sits in `C:\Windows\System32`,
/// so inheriting blindly puts the whole instance there even though the caller
/// said exactly where it wanted to be.
///
/// Only a real path is returned. `--working-directory=inherit` means "the
/// caller's cwd", which is what inheriting already does, and `home` is resolved
/// app-side against the user's profile — both leave the spawn unchanged. The
/// LAST occurrence wins, matching the request parser's last-flag-wins rule.
pub fn autoLaunchDirectory(arguments: ?[]const []const u8) ?[]const u8 {
    const args = arguments orelse return null;
    var found: ?[]const u8 = null;
    for (args) |arg| {
        const raw = dropPrefix(arg, "--working-directory=") orelse continue;
        const dir = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (dir.len == 0) continue;
        if (std.mem.eql(u8, dir, "inherit")) continue;
        if (std.mem.eql(u8, dir, "home")) continue;
        found = dir;
    }
    return found;
}

/// The `--working-directory=<dir>` argument an auto-launch appends to the
/// spawned GUI's command line, quoted for CreateProcessW command-line rules
/// (T236). Returns the full token, or null when it cannot be represented —
/// an embedded `"` (illegal in a Windows path anyway) or a buffer too small.
///
/// Why an argv argument at all, when the spawn already sets the new process's
/// working directory: the STARTUP window does not read the process cwd. Its
/// working directory comes from the resolved `working-directory` config, and
/// since T144 that resolved value is forwarded to the local agent on OPEN — so
/// it always outranks whatever directory the process happens to sit in. Saying
/// it on the command line makes the request explicit where inheriting was
/// accidental. (Since T506 that default is no longer unconditionally `home` on
/// Windows — a detached auto-launch has no console and no marker, so it still
/// resolves to `home`, but the argument is what pins the answer either way.)
///
/// Quoting: the whole token is wrapped in `"` only when the path contains
/// whitespace. Inside a quoted region a run of trailing backslashes would
/// escape the closing quote, so it is doubled (CommandLineToArgvW rules);
/// backslashes elsewhere are literal.
pub fn autoLaunchCwdArg(buf: []u8, cwd: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, cwd, '"') != null) return null;
    const prefix = "--working-directory=";

    if (std.mem.indexOfAny(u8, cwd, " \t") == null) {
        const needed = prefix.len + cwd.len;
        if (needed > buf.len) return null;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..needed], cwd);
        return buf[0..needed];
    }

    var trailing: usize = 0;
    while (trailing < cwd.len and cwd[cwd.len - 1 - trailing] == '\\')
        trailing += 1;

    const needed = 1 + prefix.len + cwd.len + trailing + 1;
    if (needed > buf.len) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..prefix.len], prefix);
    @memcpy(buf[1 + prefix.len ..][0..cwd.len], cwd);
    var i = 1 + prefix.len + cwd.len;
    for (0..trailing) |_| {
        buf[i] = '\\';
        i += 1;
    }
    buf[i] = '"';
    return buf[0..needed];
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

/// The interpreter the wsl row runs the command through inside the distro, and
/// the fallback it execs back into when `$SHELL` is unset. Absolute and POSIX:
/// a distro without `/bin/sh` cannot run anything.
pub const wsl_inner_shell = "/bin/sh";

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
///   wsl                -> shell -e /bin/sh -lic "<cmd>; exec \"$SHELL\" -li"
///                         (runs in the default distro — see below)
///   nu / nushell       -> shell -e <cmd>
///   anything else      -> shell -lic "<cmd>; exec \"shell\" -li"
///                         (posix shells, e.g. git-bash)
///
/// The wsl row is the one that takes an ARGV rather than a command string, and
/// that is why it needs `-e` and an inner shell (T656). `wsl -- <cmd>` hands
/// the rest of the Windows command line to the distro's default shell **as
/// written**, so the quoting Windows applies to a spaced argument survives into
/// the distro and bash looks for a program literally named `"echo hi"` —
/// `command not found`, naming the whole line. `-e` execs an argv instead, so
/// the command reaches `/bin/sh -lic` as one properly-unquoted argument.
///
/// `/bin/sh` because it is the one interpreter every distro is guaranteed to
/// have (it is dash on Ubuntu, and dash accepts `-lic`); `exec "$SHELL" -li`
/// because the pane must be left in the user's REAL login shell, exactly as the
/// posix row leaves it. `$SHELL` is set by WSL from the distro's passwd entry,
/// and falls back to `/bin/sh` if it somehow is not.
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
        try argv.append(arena, "-e");
        try argv.append(arena, wsl_inner_shell);
        try argv.append(arena, "-lic");
        try argv.append(arena, try std.fmt.allocPrintSentinel(
            arena,
            "{s}; exec \"${{SHELL:-{s}}}\" -li",
            .{ command, wsl_inner_shell },
            0,
        ));
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

/// The `+send-keys` argument that says "these bytes are final" (T661).
///
/// The CLI resolves every keypress to the byte a terminal sends for it before
/// the request leaves: `Enter` and a trailing newline both become CR, and a
/// newline in the MIDDLE of a text argument stays LF because it is content.
/// So every newline still in a marked request is CONTENT, and a server may
/// only touch it under the terminal-wide paste convention (`input.paste`:
/// verbatim to a program in bracketed-paste mode, LF mapped to CR otherwise)
/// — never unconditionally. Rewriting an interior LF for a TUI is the
/// divergence T604 documented and T661 removed, and rewriting a
/// `--keys-file=` trailing LF makes a prompt file submit itself against D52.
///
/// It exists because the flat `--keys=` payload from a resolved CLI and from a
/// pre-T604 one — where `\n` did mean Enter — are byte-indistinguishable. A
/// single all-text send carries no `--segments=` to key off (the CLI only
/// emits that when there is a boundary to preserve), so the generation has to
/// be stated rather than guessed.
///
/// Purely additive: a server that predates it ignores an argument it does not
/// know and normalizes as it always did, and the macOS server — which never
/// normalized in the first place — ignores it forever.
pub const keys_resolved_prefix = "--keys-resolved=";

/// The argument the CLI sends. A value is carried rather than a bare flag so
/// the wire shape matches every other `+send-keys` argument.
pub const keys_resolved_arg = keys_resolved_prefix ++ "1";

/// Whether a `--keys-resolved=` VALUE (everything after the prefix) means
/// resolved. Anything but an explicit `0` counts, so a value this build does
/// not recognize errs toward the newer, correct behavior rather than silently
/// reinstating the rewrite.
pub fn keysResolvedValue(value: []const u8) bool {
    return !std.mem.eql(u8, value, "0");
}

/// ConPTY input convention: Enter is CR. A bare LF never comes from a real
/// keyboard and Windows shells don't execute on it, but the send-keys `\n`
/// notation means "Enter" to the user — normalize LF and CRLF to CR.
/// Returns an owned slice (length <= bytes.len).
///
/// Unconditional, so it is only for a request WITHOUT `keys_resolved_arg`
/// above. A resolved CLI has already spelled Enter as CR, and every LF still
/// in its payload is content — content a bracketed-paste receiver must get
/// verbatim. See `IpcHandlers.prepareSendKeysRun` for the three-way rule.
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

test "autoLaunchDirectory: returns a real path, ignores inherit/home/empty" {
    // A real path is what the auto-launched instance should start in.
    try testing.expectEqualStrings("D:\\git\\ghoztty", autoLaunchDirectory(&[_][]const u8{
        "--target=main", "--working-directory=D:\\git\\ghoztty", "--command=claude",
    }).?);

    // The sentinels resolve elsewhere: `inherit` IS the fallback behavior and
    // `home` is expanded app-side, so neither changes the spawn.
    try testing.expect(autoLaunchDirectory(&[_][]const u8{"--working-directory=inherit"}) == null);
    try testing.expect(autoLaunchDirectory(&[_][]const u8{"--working-directory=home"}) == null);

    // Nothing to go on ⇒ inherit (null), never an empty string CreateProcessW
    // would reject.
    try testing.expect(autoLaunchDirectory(&[_][]const u8{"--working-directory="}) == null);
    try testing.expect(autoLaunchDirectory(&[_][]const u8{"--working-directory=   "}) == null);
    try testing.expect(autoLaunchDirectory(&[_][]const u8{"--target=main"}) == null);
    try testing.expect(autoLaunchDirectory(null) == null);

    // A flag that merely starts the same way is not a match.
    try testing.expect(autoLaunchDirectory(&[_][]const u8{"--working-directory-ish=/tmp"}) == null);

    // Last occurrence wins (the request parser's rule).
    try testing.expectEqualStrings("/second", autoLaunchDirectory(&[_][]const u8{
        "--working-directory=/first", "--working-directory=/second",
    }).?);
}

test "autoLaunchCwdArg: plain path is passed unquoted" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "--working-directory=D:\\git\\ghoztty",
        autoLaunchCwdArg(&buf, "D:\\git\\ghoztty").?,
    );
    // A trailing backslash outside quotes is literal — no doubling.
    try testing.expectEqualStrings(
        "--working-directory=C:\\x\\",
        autoLaunchCwdArg(&buf, "C:\\x\\").?,
    );
}

test "autoLaunchCwdArg: whitespace quotes the whole token" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "\"--working-directory=C:\\my dir\"",
        autoLaunchCwdArg(&buf, "C:\\my dir").?,
    );
    try testing.expectEqualStrings(
        "\"--working-directory=C:\\a\tb\"",
        autoLaunchCwdArg(&buf, "C:\\a\tb").?,
    );
}

test "autoLaunchCwdArg: trailing backslashes are doubled inside quotes" {
    var buf: [256]u8 = undefined;
    // One trailing backslash would escape the closing quote; it is doubled.
    try testing.expectEqualStrings(
        "\"--working-directory=C:\\my dir\\\\\"",
        autoLaunchCwdArg(&buf, "C:\\my dir\\").?,
    );
    // A whole run doubles, not just the last one.
    try testing.expectEqualStrings(
        "\"--working-directory=C:\\my dir\\\\\\\\\"",
        autoLaunchCwdArg(&buf, "C:\\my dir\\\\").?,
    );
    // Interior backslashes are untouched.
    try testing.expectEqualStrings(
        "\"--working-directory=C:\\a b\\c\"",
        autoLaunchCwdArg(&buf, "C:\\a b\\c").?,
    );
}

test "autoLaunchCwdArg: unrepresentable paths return null" {
    var buf: [256]u8 = undefined;
    // An embedded quote cannot appear in a Windows path and cannot be
    // round-tripped through the command line — refuse rather than mangle.
    try testing.expect(autoLaunchCwdArg(&buf, "C:\\evil\"dir") == null);

    // A buffer too small refuses rather than truncating to a wrong path.
    var tiny: [8]u8 = undefined;
    try testing.expect(autoLaunchCwdArg(&tiny, "D:\\git\\ghoztty") == null);
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

test "parseVerbArgs: --caller-pane= is captured, not dropped as an unknown flag" {
    var arena = testArena();
    defer arena.deinit();

    const parsed = try parseVerbArgs(arena.allocator(), &[_][]const u8{
        "--direction=right", "--caller-pane=PANE-1",
    });
    try testing.expectEqualStrings("PANE-1", parsed.caller_pane.?);
    // It is NOT --pane=: the two must stay distinguishable, because only one
    // of them is a hard error when it resolves to nothing.
    try testing.expect(parsed.pane == null);

    const none = try parseVerbArgs(arena.allocator(), &[_][]const u8{"--direction=right"});
    try testing.expect(none.caller_pane == null);
}

/// `isAlive` for the precedence tests: only "PANE-1" names a live pane.
fn testPaneAlive(_: void, name: []const u8) bool {
    return std.mem.eql(u8, name, "PANE-1");
}

test "callerAnchorPane: anchors at the invoking pane when the caller named none" {
    const args = try parseVerbArgs(testing.allocator, &[_][]const u8{
        "--direction=right", "--caller-pane=PANE-1",
    });
    try testing.expectEqualStrings(
        "PANE-1",
        callerAnchorPane(args, {}, testPaneAlive).?,
    );
}

test "callerAnchorPane: an anchor the caller named explicitly wins" {
    // --target, --pane and --from-focused are the caller saying WHERE it wants
    // the command to land; the caller pane is only the default.
    const with_target = try parseVerbArgs(testing.allocator, &[_][]const u8{
        "--target=dev", "--caller-pane=PANE-1",
    });
    try testing.expect(callerAnchorPane(with_target, {}, testPaneAlive) == null);

    const with_pane = try parseVerbArgs(testing.allocator, &[_][]const u8{
        "--pane=logs", "--caller-pane=PANE-1",
    });
    try testing.expect(callerAnchorPane(with_pane, {}, testPaneAlive) == null);

    const focused = try parseVerbArgs(testing.allocator, &[_][]const u8{
        "--from-focused", "--caller-pane=PANE-1",
    });
    try testing.expect(callerAnchorPane(focused, {}, testPaneAlive) == null);
}

test "callerAnchorPane: an absent or empty pane id keeps the focused-window fallback" {
    const absent = try parseVerbArgs(testing.allocator, &[_][]const u8{"--direction=right"});
    try testing.expect(callerAnchorPane(absent, {}, testPaneAlive) == null);

    const empty = try parseVerbArgs(testing.allocator, &[_][]const u8{"--caller-pane="});
    try testing.expect(callerAnchorPane(empty, {}, testPaneAlive) == null);
}

test "callerAnchorPane: a caller pane that no longer resolves falls back" {
    // A script outliving its own pane is ordinary, so this is a fallback and
    // never an error - the difference from an explicit `--pane=` that names
    // nothing, which stays a hard error in the handler.
    const gone = try parseVerbArgs(testing.allocator, &[_][]const u8{"--caller-pane=PANE-GONE"});
    try testing.expect(callerAnchorPane(gone, {}, testPaneAlive) == null);
}

test "droppedOnExistingTarget: names exactly the flags the caller passed" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parseVerbArgs(alloc, &[_][]const u8{
        "--target=main", "--working-directory=C:\\src", "--command=claude",
    });
    const dropped = (try droppedOnExistingTarget(alloc, parsed)).?;
    try testing.expectEqualStrings("--command, --working-directory", dropped);
}

test "droppedOnExistingTarget: the CLI's implicit cwd never counts" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // A bare `+new-window --target=x` always arrives with the CLI's own cwd
    // inserted and marked; that is the default, not a request.
    const bare = try parseVerbArgs(alloc, &[_][]const u8{
        "--target=main", "--working-directory=C:\\wherever", "--cwd-implicit",
    });
    try testing.expect(bare.cwd_implicit);
    try testing.expect(try droppedOnExistingTarget(alloc, bare) == null);

    // ...but an explicit --working-directory alongside the marker still counts
    // for OTHER flags: only the cwd mention is suppressed.
    const with_cmd = try parseVerbArgs(alloc, &[_][]const u8{
        "--target=main", "--working-directory=C:\\wherever", "--cwd-implicit",
        "--command=claude",
    });
    try testing.expectEqualStrings(
        "--command",
        (try droppedOnExistingTarget(alloc, with_cmd)).?,
    );
}

test "droppedOnExistingTarget: -e, --view, split flags and --env all count" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parseVerbArgs(alloc, &[_][]const u8{
        "--target=main", "--view=README.md",   "--title=T",
        "--split=down",  "--split-command=ls", "--name=p",
        "--color=#123",  "--env=A=1",          "-e",
        "cmd",           "/c",                 "dir",
    });
    try testing.expectEqualStrings(
        "-e, --view, --title, --split, --split-command, --name, --color, --env",
        (try droppedOnExistingTarget(alloc, parsed)).?,
    );

    // Target + --no-activate alone: nothing meaningful was dropped.
    const quiet = try parseVerbArgs(alloc, &[_][]const u8{
        "--target=main", "--no-activate",
    });
    try testing.expect(try droppedOnExistingTarget(alloc, quiet) == null);
}

test "parseVerbArgs: --view is captured, not dropped as an unknown flag" {
    var arena = testArena();
    defer arena.deinit();

    // A path and a URL are both just the flag's value here; classification
    // (and relative-path resolution) happens CLI-side in cli/view_arg.zig.
    const file = try parseVerbArgs(arena.allocator(), &[_][]const u8{
        "--target=dev", "--view=D:\\git\\ghoztty\\README.md",
    });
    try testing.expectEqualStrings("D:\\git\\ghoztty\\README.md", file.view.?);

    const url = try parseVerbArgs(arena.allocator(), &[_][]const u8{"--view=https://example.com"});
    try testing.expectEqualStrings("https://example.com", url.view.?);

    // Absent stays absent — a terminal request must not look like a viewer.
    const none = try parseVerbArgs(arena.allocator(), &[_][]const u8{"--target=dev"});
    try testing.expect(none.view == null);
}

test "viewConflictsWithCommand: --command and -e both conflict, alone neither does" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const with_command = try parseVerbArgs(alloc, &[_][]const u8{
        "--view=README.md", "--command=pwsh",
    });
    try testing.expect(viewConflictsWithCommand(with_command));

    // `-e` is a command too: Mac folds it into `config.command` before the
    // same check, so a `--view -e` line must be rejected on both platforms.
    const with_e = try parseVerbArgs(alloc, &[_][]const u8{
        "--view=README.md", "-e", "pwsh", "-NoLogo",
    });
    try testing.expect(viewConflictsWithCommand(with_e));

    // Each one on its own is a perfectly good request.
    const view_only = try parseVerbArgs(alloc, &[_][]const u8{"--view=README.md"});
    try testing.expect(!viewConflictsWithCommand(view_only));
    const command_only = try parseVerbArgs(alloc, &[_][]const u8{"--command=pwsh"});
    try testing.expect(!viewConflictsWithCommand(command_only));

    // `--split-command` is NOT a conflict: it configures the OTHER pane of an
    // inline split, which stays a terminal. Mac checks `config.command` only.
    const split_command = try parseVerbArgs(alloc, &[_][]const u8{
        "--view=README.md", "--split-command=pwsh",
    });
    try testing.expect(!viewConflictsWithCommand(split_command));
}

test "viewMode: web is http(s)/about, and everything else is a file" {
    // The three the win32 server builds a live pane for as of T374.
    try testing.expectEqual(ViewMode.web, viewMode("http://localhost:3000"));
    try testing.expectEqual(ViewMode.web, viewMode("https://example.com/a/b?c=d"));
    try testing.expectEqual(ViewMode.web, viewMode("about:blank"));

    // Schemes are case-insensitive (RFC 3986 §3.1); a pasted address is a URL
    // however the user's clipboard capitalized it.
    try testing.expectEqual(ViewMode.web, viewMode("HTTPS://example.com"));
    try testing.expectEqual(ViewMode.web, viewMode("Http://example.com"));

    // The reason this is not "does it contain `://`". A `file://` URL NAMES A
    // FILE: handing it to a browser renders markdown as raw text, which is the
    // silently-wrong-pane defect one level down from the unknown-flag drop.
    try testing.expectEqual(ViewMode.file, viewMode("file:///c:/src/README.md"));

    // Plain paths, in both platforms' spellings, plus a bare host (which the
    // omnibox will complete later — it is not a URL yet).
    try testing.expectEqual(ViewMode.file, viewMode("README.md"));
    try testing.expectEqual(ViewMode.file, viewMode("C:\\src\\repo\\README.md"));
    try testing.expectEqual(ViewMode.file, viewMode("/usr/share/doc/x.md"));
    try testing.expectEqual(ViewMode.file, viewMode("\\\\server\\share\\x.md"));
    try testing.expectEqual(ViewMode.file, viewMode("example.com"));

    // A prefix of a scheme is not a scheme, and an empty value is not a URL.
    try testing.expectEqual(ViewMode.file, viewMode("http"));
    try testing.expectEqual(ViewMode.file, viewMode("about"));
    try testing.expectEqual(ViewMode.file, viewMode(""));
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
        // T656: an argv, not a command string — `wsl -- <cmd>` lets Windows'
        // own quoting reach the distro's shell as part of the command.
        .{ .shell = "wsl.exe", .expect = &.{ "wsl.exe", "-e", "/bin/sh", "-lic", "echo hi; exec \"${SHELL:-/bin/sh}\" -li" } },
        .{ .shell = "WSL", .expect = &.{ "WSL", "-e", "/bin/sh", "-lic", "echo hi; exec \"${SHELL:-/bin/sh}\" -li" } },
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

// T661: the marker that turns the rewrite above OFF. Its whole job is to be
// unambiguous on the wire, so the two ways it could go wrong are pinned here.
test "keys_resolved_arg: spelling a server can key off" {
    try testing.expect(std.mem.startsWith(u8, keys_resolved_arg, keys_resolved_prefix));
    try testing.expect(keysResolvedValue(keys_resolved_arg[keys_resolved_prefix.len..]));

    // A server parses `--keys=` in the same loop, so the marker must not be
    // mistaken for a payload — which would send the literal text "resolved=1"
    // to the pane and drop the real keys entirely.
    try testing.expect(!std.mem.startsWith(u8, keys_resolved_arg, "--keys="));
}

test "keysResolvedValue: only an explicit 0 means unresolved" {
    try testing.expect(keysResolvedValue("1"));
    try testing.expect(keysResolvedValue("true"));
    // A value from a newer CLI errs toward verbatim rather than quietly
    // reinstating the newline rewrite this marker exists to prevent.
    try testing.expect(keysResolvedValue("2"));
    try testing.expect(keysResolvedValue(""));
    try testing.expect(!keysResolvedValue("0"));
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
