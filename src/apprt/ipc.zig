//! Inter-process Communication to a running Ghostty instance from a separate
//! process.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("../lib/main.zig");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");

/// Environment variable naming the IPC socket of the app instance that owns
/// the calling process's pane. Every pane's environment is baked with this by
/// the app that created it (see `IPCSocket.path` on the macOS side), so a CLI
/// run from inside a pane talks to THAT app — not to whichever build the
/// `ghoztty` binary on `$PATH` happens to be.
///
/// This matters because the socket name is per-BUILD (`-debug` suffix), not
/// per-binary: `ghoztty` on `$PATH` is normally the release app's binary, so
/// without this it would compile-time-derive the release socket even when run
/// from a debug-app pane and silently drive the wrong instance.
///
/// It holds a full absolute path rather than a build-flavor hint so it keeps
/// working if the socket name ever gains an instance discriminator.
///
/// On Windows the endpoint is a named PIPE, not a socket path, and the same
/// var carries it (T118) — one spelling for both platforms, aliased from the
/// transport helper below so the name cannot drift between them.
///
/// Absent (a plain non-Ghoztty shell, or a pane baked by an app/agent that
/// predates this var) means "derive it" — see `socketPath`.
pub const socket_env = internal_os.ipc_client.endpoint_env;

/// Resolve the IPC socket to dial: `$GHOZTTY_IPC_SOCKET` when the caller runs
/// inside a pane, else this build's own `<tmp>/ghostty[-debug]-<uid>.sock`
/// (which is what the app's IPC server binds — keep the two in sync).
///
/// This is the ONE place the socket address is resolved; every CLI command and
/// apprt IPC client goes through it so the derivation can't drift.
///
/// Caller owns the returned path.
pub fn socketPath(alloc: Allocator) Allocator.Error![:0]u8 {
    // Windows: `std.posix.getenv` does not exist there, and the win32 CLI
    // dials through `ipc_client` — which owns the identical preference rule
    // for every one of its callers. Defer to it rather than keeping a second
    // copy of the rule that only one of the two client stacks would exercise.
    if (comptime builtin.os.tag == .windows) {
        return internal_os.ipc_client.clientEndpointPath(alloc);
    }

    return socketPathFrom(alloc, std.posix.getenv(socket_env));
}

/// `socketPath` with the baked value injected, so the resolution rule is
/// testable without mutating the process environment.
fn socketPathFrom(alloc: Allocator, baked: ?[]const u8) Allocator.Error![:0]u8 {
    if (baked) |path| {
        if (path.len > 0) return alloc.dupeZ(u8, path);
    }

    // Windows has no uid and no unix-socket path: the IPC endpoint is a named
    // pipe. Defer to the helper the win32 CLI actually dials so the two can't
    // drift, rather than deriving a POSIX path that would never connect.
    // (`std.c.getuid` does not even link on this target.)
    if (comptime builtin.os.tag == .windows) {
        return internal_os.ipc_client.endpointPath(alloc);
    }

    const tmpdir = try internal_os.allocTmpDir(alloc);
    defer internal_os.freeTmpDir(alloc, tmpdir);
    const uid = std.c.getuid();
    const suffix = if (build_config.is_debug) "-debug" else "";
    return std.fmt.allocPrintSentinel(alloc, "{s}/ghostty{s}-{d}.sock", .{
        tmpdir, suffix, uid,
    }, 0);
}

test "socketPath: prefers the pane's baked socket over the compile-time guess" {
    const testing = std.testing;
    const baked = "/tmp/gz-test/ghostty-debug-501.sock";
    const path = try socketPathFrom(testing.allocator, baked);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(baked, path);
}

test "socketPath: falls back to this build's own socket when unset or empty" {
    const testing = std.testing;

    // An empty value means the same thing as absent: derive it. (A pane baked
    // by an app or agent that predates the var leaves it absent entirely.)
    const unset = try socketPathFrom(testing.allocator, null);
    defer testing.allocator.free(unset);
    const empty = try socketPathFrom(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings(unset, empty);

    // The remaining asserts describe the POSIX unix-socket shape. On Windows
    // the fallback is a named pipe (`\\.\pipe\ghoztty[-debug]-<user>`), which
    // `os/ipc_client.zig` owns and tests; the agreement checked above (absent
    // == empty) is what this test asserts on both.
    if (comptime builtin.os.tag == .windows) return;

    // Exactly one separator between the tmp dir and the socket name, whether or
    // not $TMPDIR carries a trailing slash.
    try testing.expect(std.mem.endsWith(u8, unset, ".sock"));
    try testing.expect(std.mem.indexOf(u8, unset, "//") == null);
    try testing.expect(std.mem.startsWith(
        u8,
        std.fs.path.basename(unset),
        if (build_config.is_debug) "ghostty-debug-" else "ghostty-",
    ));
}

/// Environment variable naming the pane the calling process runs in. Every
/// pane's environment is baked with its own stable, ghoztty-owned pane id at
/// spawn (and re-baked across session restore and agent relaunch), so a CLI
/// run from inside a pane knows WHERE IT IS without a `+list` round trip.
///
/// This is the targeting twin of `socket_env`: that one says which app to talk
/// to, this one says which pane is asking.
pub const pane_env = "GHOZTTY_PANE_ID";

/// The flag `seedCallerPane` adds to carry `$GHOZTTY_PANE_ID` to the app.
///
/// It is deliberately NOT `--pane=`: an explicit `--pane=` that names nothing
/// is a typo and must stay a hard error, while an implicit caller pane that no
/// longer resolves (the script's own pane was closed — ordinary) must fall
/// back to the app's focused window. The server tells the two apart by which
/// flag carried the name.
pub const caller_pane_flag = "--caller-pane=";

/// Tell the app which pane a command was invoked FROM, so a command that
/// anchors at a pane can default to the CALLER's rather than to whatever
/// window happens to be focused when the app gets around to the message.
///
/// Without this the default anchor is resolved on the app's main queue at
/// handle time, which is racy by construction: the user can switch windows
/// between the CLI invocation and the app's turn, and an agent's command is
/// asynchronous with respect to focus even when nobody touches anything.
///
/// This is the ONE place the implicit target is resolved on the CLI side;
/// `IPCServer.callerAnchorPane` is its one consumer on the app side.
pub fn seedCallerPane(
    alloc: Allocator,
    arguments: *std.ArrayList([:0]const u8),
) Allocator.Error!void {
    // Windows: `std.posix.getenv` is a hard compile error there (environment
    // strings are WTF-16), the same trap `socketPath` above steps around. Read
    // the variable the cross-platform way instead and free the copy as soon as
    // the flag has been formatted out of it — a missing/unset var is simply
    // "no caller pane", which is the same no-op as an empty one.
    if (comptime builtin.os.tag == .windows) {
        const baked = std.process.getEnvVarOwned(alloc, pane_env) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EnvironmentVariableNotFound,
            error.InvalidWtf8,
            => return seedCallerPaneFrom(alloc, arguments, null),
        };
        defer alloc.free(baked);
        return seedCallerPaneFrom(alloc, arguments, baked);
    }

    return seedCallerPaneFrom(alloc, arguments, std.posix.getenv(pane_env));
}

/// `seedCallerPane` with the baked value injected, so the rule is testable
/// without mutating the process environment.
fn seedCallerPaneFrom(
    alloc: Allocator,
    arguments: *std.ArrayList([:0]const u8),
    baked: ?[]const u8,
) Allocator.Error!void {
    const pane = baked orelse return;
    if (pane.len == 0) return;

    // Everything from `-e` on is the user's command, verbatim. The flag has to
    // go in FRONT of it — appended, it would be typed into their shell — and
    // the scan below has to stop there too, so a `--target=` that is an
    // argument of that command isn't read as an anchor.
    var insert_at: usize = arguments.items.len;
    for (arguments.items, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-e")) {
            insert_at = i;
            break;
        }

        // Only a DEFAULT. Anything the caller said about where the command
        // should land — a window/pane name, a pane id, or "wherever is
        // focused" — wins.
        if (std.mem.startsWith(u8, arg, "--target=")) return;
        if (std.mem.startsWith(u8, arg, "--pane=")) return;
        if (std.mem.startsWith(u8, arg, caller_pane_flag)) return;
        if (std.mem.eql(u8, arg, "--from-focused")) return;
    }

    try arguments.insert(alloc, insert_at, try std.fmt.allocPrintSentinel(
        alloc,
        caller_pane_flag ++ "{s}",
        .{pane},
        0,
    ));
}

/// Seed an argument list built out of `given` and return the whole result
/// joined by spaces, so both WHETHER and WHERE the flag landed are visible.
fn testSeed(given: []const []const u8, baked: ?[]const u8, out: *[256]u8) ![]const u8 {
    const testing = std.testing;
    var arguments: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (arguments.items) |a| testing.allocator.free(a);
        arguments.deinit(testing.allocator);
    }
    for (given) |a| try arguments.append(testing.allocator, try testing.allocator.dupeZ(u8, a));

    try seedCallerPaneFrom(testing.allocator, &arguments, baked);

    var len: usize = 0;
    for (arguments.items, 0..) |a, i| {
        if (i > 0) {
            out[len] = ' ';
            len += 1;
        }
        @memcpy(out[len..][0..a.len], a);
        len += a.len;
    }
    return out[0..len];
}

test "callerPane: seeds the invoking pane when the caller named no anchor" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "--direction=right --caller-pane=PANE-1",
        try testSeed(&.{"--direction=right"}, "PANE-1", &buf),
    );
}

test "callerPane: an anchor the caller named explicitly wins" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    // The env var is only the DEFAULT: --target, --pane, and --from-focused
    // are the caller saying where it wants the pane, and each one wins.
    try testing.expectEqualStrings(
        "--target=dev --direction=right",
        try testSeed(&.{ "--target=dev", "--direction=right" }, "PANE-1", &buf),
    );
    try testing.expectEqualStrings(
        "--pane=logs",
        try testSeed(&.{"--pane=logs"}, "PANE-1", &buf),
    );
    try testing.expectEqualStrings(
        "--from-focused",
        try testSeed(&.{"--from-focused"}, "PANE-1", &buf),
    );
}

test "callerPane: an absent or empty pane id changes nothing" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    // A plain non-Ghoztty shell, or a pane baked by an app/agent that predates
    // the var, leaves the server on its focused-window fallback.
    try testing.expectEqualStrings(
        "--direction=right",
        try testSeed(&.{"--direction=right"}, null, &buf),
    );
    try testing.expectEqualStrings(
        "--direction=right",
        try testSeed(&.{"--direction=right"}, "", &buf),
    );
}

test "callerPane: the flag goes in front of -e, never inside the command" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    // Everything after `-e` is the user's command, verbatim: appending there
    // would type `--caller-pane=<uuid>` into their shell.
    try testing.expectEqualStrings(
        "--direction=down --caller-pane=PANE-1 -e echo hi",
        try testSeed(&.{ "--direction=down", "-e", "echo", "hi" }, "PANE-1", &buf),
    );

    // And a flag-looking word inside that command is the command's, not an
    // anchor the caller named.
    try testing.expectEqualStrings(
        "--caller-pane=PANE-1 -e echo --target=x",
        try testSeed(&.{ "-e", "echo", "--target=x" }, "PANE-1", &buf),
    );
}

/// Connect to an IPC socket by path. Caller owns the returned fd.
pub fn connect(path: [:0]const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    );
    errdefer std.posix.close(fd);

    var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;

    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    return fd;
}

/// Pure verb-argument logic (flag parsing, shell wrap table, ConPTY input
/// normalization, layout validation) shared by IPC servers.
pub const args = @import("ipc/args.zig");

/// The `+list` response data model + serializer, shape-matched to the Mac
/// server's encoder and pinned by golden tests.
pub const List = @import("ipc/list.zig").List;

/// The `+send-keys` `--segments=` wire format. One definition for both the
/// CLI that writes it and the IPC server that reads it, so the two halves of
/// the format cannot drift apart.
pub const segments = @import("ipc/segments.zig");

/// The `+read` "last N lines" rule, and the contract that an empty screen is
/// an ANSWER rather than a failure (T181).
pub const read_tail = @import("ipc/read_tail.zig");

/// The `ghoztty://focus/<target>` URL scheme grammar and its failure wording
/// (T695). One definition for the launcher that decodes a clicked link and the
/// in-app paths that short-circuit one, so a link cannot mean two things.
pub const url_scheme = @import("ipc/url_scheme.zig");

/// The build identity a launch carries when it hands its window to the
/// instance already running, and the notice shown when the two builds differ
/// (T1022 / D79). Lives beside the transport in `os/` — the wire field is the
/// client's to write — and is aliased here so an apprt reads it off the same
/// namespace as every other IPC shape.
pub const handoff = internal_os.ipc_handoff;

test {
    _ = args;
    _ = segments;
    _ = read_tail;
    _ = url_scheme;
    _ = @import("ipc/list.zig");
}

pub const Errors = error{
    /// The IPC failed. If a function returns this error, it's expected that
    /// an a more specific error message will have been written to stderr (or
    /// otherwise shown to the user in an appropriate way).
    IPCFailed,

    /// No running instance was found (socket does not exist).
    NoRunningInstance,
};

/// The JSON response the IPC server sends for every request:
/// `{"success": <bool>, "error": <optional string>, ...}`. Unknown fields
/// (e.g. the `data` payload of a `+read` response) are ignored by
/// `parseResponse`.
pub const Response = struct {
    success: bool = false,
    @"error": ?[]const u8 = null,
};

/// Parse the raw JSON response body from the IPC server. On failure the
/// server includes a human-readable reason in `error` (e.g. "pane 'd1' not
/// found in registry") which callers should surface to the user instead of a
/// generic fallback. The returned `Parsed` owns the string memory; call
/// `deinit` when done.
pub fn parseResponse(
    alloc: Allocator,
    bytes: []const u8,
) error{InvalidResponse}!std.json.Parsed(Response) {
    return std.json.parseFromSlice(
        Response,
        alloc,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch error.InvalidResponse;
}

test "parseResponse: success" {
    const testing = std.testing;
    const parsed = try parseResponse(testing.allocator, "{\"success\":true}");
    defer parsed.deinit();
    try testing.expect(parsed.value.success);
    try testing.expect(parsed.value.@"error" == null);
}

test "parseResponse: failure carries the server's error text" {
    const testing = std.testing;
    const parsed = try parseResponse(
        testing.allocator,
        "{\"success\":false,\"error\":\"pane 'd1' not found in registry\"}",
    );
    defer parsed.deinit();
    try testing.expect(!parsed.value.success);
    try testing.expectEqualStrings(
        "pane 'd1' not found in registry",
        parsed.value.@"error".?,
    );
}

test "parseResponse: unknown fields are ignored" {
    const testing = std.testing;
    const parsed = try parseResponse(
        testing.allocator,
        "{\"success\":true,\"data\":{\"text\":\"hello\"}}",
    );
    defer parsed.deinit();
    try testing.expect(parsed.value.success);
}

test "parseResponse: invalid JSON" {
    const testing = std.testing;
    try testing.expectError(
        error.InvalidResponse,
        parseResponse(testing.allocator, "not json"),
    );
}

pub const Target = union(Key) {
    /// Open up a new window in a custom instance of Ghostty.
    class: [:0]const u8,

    /// Detect which instance to open a new window in.
    detect,

    // Sync with: ghostty_ipc_target_tag_e
    pub const Key = enum(c_int) {
        class,
        detect,

        test "ghostty.h Target.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_TARGET_");
        }
    };

    // Sync with: ghostty_ipc_target_u
    pub const CValue = extern union {
        class: [*:0]const u8,
        detect: void,
    };

    // Sync with: ghostty_ipc_target_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    /// Convert to ghostty_ipc_target_s.
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .class => |class| .{ .class = class.ptr },
                .detect => .{ .detect = {} },
            },
        };
    }
};

pub const Action = union(enum) {
    // A GUIDE TO ADDING NEW ACTIONS:
    //
    // 1. Add the action to the `Key` enum. The order of the enum matters
    //    because it maps directly to the libghostty C enum. For ABI
    //    compatibility, new actions should be added to the end of the enum.
    //
    // 2. Add the action and optional value to the Action union.
    //
    // 3. If the value type is not void, ensure the value is C ABI
    //    compatible (extern). If it is not, add a `C` decl to the value
    //    and a `cval` function to convert to the C ABI compatible value.
    //
    // 4. Update `include/ghostty.h`: add the new key, value, and union
    //    entry. If the value type is void then only the key needs to be
    //    added. Ensure the order matches exactly with the Zig code.

    /// The arguments to pass to Ghostty as the command.
    new_window: NewWindow,

    /// Create a split in an existing window.
    split: Split,

    /// Close a named pane or window.
    close: Close,

    /// Rename a named pane or window in the target registry.
    rename: Rename,

    /// Rearrange the pane layout of a window.
    rearrange: Rearrange,

    /// Send text input to a named pane's terminal.
    send_keys: SendKeys,

    /// Set the activity state of a named pane or window.
    set_state: SetState,

    /// Set or clear the sticky banner of a named pane or window.
    set_banner: SetBanner,

    /// Reload a named viewer pane's content in place.
    reload: Reload,

    pub const NewWindow = struct {
        /// A list of command arguments to launch in the new window. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *NewWindow.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *NewWindow, alloc: Allocator) Allocator.Error!NewWindow.C {
            var result: NewWindow.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Split = struct {
        /// A list of command arguments to launch in the split. If this is
        /// `null` the command configured in the config or the user's default
        /// shell should be launched.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Split.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Split, alloc: Allocator) Allocator.Error!Split.C {
            var result: Split.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Close = struct {
        /// A list of command arguments to pass to the close action. If this is
        /// `null` no additional arguments are sent.
        ///
        /// It is an error for this to be non-`null`, but zero length.
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            /// null terminated list of arguments
            /// it will be null itself if there are no arguments
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Close.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Close, alloc: Allocator) Allocator.Error!Close.C {
            var result: Close.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                // add null terminator
                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Rename = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Rename.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Rename, alloc: Allocator) Allocator.Error!Rename.C {
            var result: Rename.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Rearrange = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Rearrange.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Rearrange, alloc: Allocator) Allocator.Error!Rearrange.C {
            var result: Rearrange.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const SendKeys = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *SendKeys.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *SendKeys, alloc: Allocator) Allocator.Error!SendKeys.C {
            var result: SendKeys.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const SetState = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *SetState.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *SetState, alloc: Allocator) Allocator.Error!SetState.C {
            var result: SetState.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const SetBanner = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *SetBanner.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *SetBanner, alloc: Allocator) Allocator.Error!SetBanner.C {
            var result: SetBanner.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    pub const Reload = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Reload.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Reload, alloc: Allocator) Allocator.Error!Reload.C {
            var result: Reload.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };

    /// Sync with: ghostty_ipc_action_tag_e
    pub const Key = enum(c_int) {
        new_window,
        split,
        close,
        rename,
        rearrange,
        send_keys,
        set_state,
        set_banner,
        reload,

        /// The wire name of this action: the `action` field of the IPC JSON
        /// request (and the CLI `+<verb>` spelling).
        pub fn wireName(self: Key) [:0]const u8 {
            return switch (self) {
                .new_window => "new-window",
                .split => "split",
                .close => "close",
                .rename => "rename",
                .rearrange => "rearrange",
                .send_keys => "send-keys",
                .set_state => "set-state",
                .set_banner => "set-banner",
                .reload => "reload",
            };
        }

        test "ghostty.h Action.Key" {
            try lib.checkGhosttyHEnum(Key, "GHOSTTY_IPC_ACTION_");
        }
    };

    /// Sync with: ghostty_ipc_action_u
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var union_fields: [key_fields.len]std.builtin.Type.UnionField = undefined;
        for (key_fields, 0..) |field, i| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                // Types can provide custom types for their CValue.
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };

            union_fields[i] = .{
                .name = field.name,
                .type = Type,
                .alignment = @alignOf(Type),
            };
        }

        break :cvalue @Type(.{ .@"union" = .{
            .layout = .@"extern",
            .tag_type = null,
            .fields = &union_fields,
            .decls = &.{},
        } });
    };

    /// Sync with: ghostty_ipc_action_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    comptime {
        // For ABI compatibility, we expect that this is our union size.
        // At the time of writing, we don't promise ABI compatibility
        // so we can change this but I want to be aware of it.
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 4,
            8 => 8,
            else => unreachable,
        });
    }

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }

    /// Convert to ghostty_ipc_action_s.
    pub fn cval(self: Action, alloc: Allocator) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval(alloc) else v,
            ),
        };

        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};
