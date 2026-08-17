//! The **spawn spec** an agent hands a per-session ConPTY holder (T905,
//! increment 2 of the T705 non-destructive agent upgrade — design:
//! `docs/design/agent-nondestructive-handoff.md`).
//!
//! A holder must reproduce EXACTLY what the in-process `PtyChild` would have
//! spawned: the same shell resolution, the same explicit `argv` rewrite (the
//! shell-integration path, T151), the same forwarded `OPEN.env` allowlist, the
//! same `TERM`, the same cwd. That is `protocol.Open` — the struct the app
//! already sends — so this spec carries `Open` VERBATIM rather than restating
//! it flag by flag. Nothing can drift between what the agent was asked for and
//! what the holder spawns, because it is the same value.
//!
//! ## Why a file and not argv or the environment
//!
//! - **argv**: `OPEN.env` values and an explicit `argv` are arbitrary user
//!   strings (paths with spaces, quotes, `%` and `^`), and a Windows command
//!   line is one string with a 32 KiB ceiling. Every one of those is a quoting
//!   bug waiting for the one user whose value contains a `"`.
//! - **the environment**: the holder must ESCAPE the agent's kill-on-close job,
//!   and the escape's second tier spawns with a spoofed parent, which donates
//!   the *caller's* environment block. Per-session variables set on the agent
//!   to reach one holder would leak into the next.
//!
//! A file sidesteps both: JSON in, JSON out, no escaping rules. It lives in the
//! user's TEMP directory (per-user, ACL'd by Windows to that user) for the few
//! milliseconds between the agent writing it and the holder reading it —
//! `readAndDelete` unlinks it before the shell is spawned, so a spec carrying
//! forwarded env never outlives the spawn it configures.
//!
//! Layering: pure — `std` + `protocol` only — so the round-trip, the version
//! gate and the unknown-field tolerance all run in the `test-agent` lane on any
//! host.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("../protocol.zig");
const atomic_write = @import("atomic_write.zig");

/// On-disk schema version. Bumped only on an INCOMPATIBLE layout change; a
/// holder refuses a spec it cannot read rather than spawning a wrong shell.
/// Additive fields need no bump (the parser ignores unknown ones).
pub const format_version: u32 = 1;

/// Ceiling on a spec we will read back. `OPEN.env` is an allowlist of a few
/// dozen short pairs; anything near this is corruption, not a session.
pub const max_file_bytes: usize = 1024 * 1024;

/// Everything a holder needs to become one session's PTY owner.
pub const Spec = struct {
    version: u32 = format_version,
    /// Pipe-name-safe session id (`pty_host_proto.validSessionId`).
    session_id: []const u8,
    /// The full `\\.\pipe\...` control-pipe path the holder must bind. The
    /// AGENT derives it (so it knows where to dial) rather than letting the
    /// holder default it — two processes deriving the same name independently
    /// is a drift the spec makes impossible.
    pipe_name: []const u8,
    /// Bounded un-acked output ring, in bytes.
    replay_bytes: usize = 1024 * 1024,
    /// How long an ownerless holder outlives its exited shell so a (re)starting
    /// agent can still collect the exit code.
    exit_linger_ms: i64 = 10 * 60 * 1000,
    /// The OPEN this session was created from, verbatim.
    open: protocol.Open,
};

pub const Parsed = std.json.Parsed(Spec);

/// Serialize to the on-disk body. Null optionals are elided, matching every
/// other JSON the agent writes.
pub fn serialize(alloc: Allocator, spec: Spec) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, spec, .{ .emit_null_optional_fields = false });
}

/// Parse a spec body. Unknown fields are ignored (a NEWER agent may append
/// some), but a version this build does not understand is refused: a holder
/// that guessed would spawn the wrong shell, which is worse than not starting.
/// Strings are copied into the `Parsed` arena, so the caller may free `bytes`.
pub fn parse(alloc: Allocator, bytes: []const u8) !Parsed {
    const parsed = try std.json.parseFromSlice(Spec, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.value.version != format_version) {
        parsed.deinit();
        return error.UnsupportedSpecVersion;
    }
    return parsed;
}

/// Write `spec` to `path` atomically (staging file + rename), so a holder that
/// starts while the agent is still writing never reads half a spec.
pub fn write(alloc: Allocator, path: []const u8, spec: Spec) !void {
    const bytes = try serialize(alloc, spec);
    defer alloc.free(bytes);
    try atomic_write.writeChunks(alloc, path, &.{bytes}, .{});
}

/// Read `path`, DELETE it, and parse. The delete happens whether or not the
/// parse succeeds: the spec's whole life is this one read, and a leftover file
/// in TEMP holding a session's forwarded environment is exactly what the
/// short-lived design is avoiding.
pub fn readAndDelete(alloc: Allocator, path: []const u8) !Parsed {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes);
    defer alloc.free(bytes);
    std.fs.cwd().deleteFile(path) catch {};
    return parse(alloc, bytes);
}

/// Where the agent stages one session's spec: `%TEMP%\ghoztty-ptyhost-<id>.json`.
/// The session id is unique and charset-checked before it reaches here, so the
/// name cannot collide or escape the directory. Caller frees.
///
/// TEMP rather than the agent state directory on purpose: the spec is not agent
/// state, it is a handoff that has already been consumed by the time anyone
/// could look for it — and TEMP is the one per-user, always-writable directory
/// both processes agree on without either being told where it is.
pub fn tempPath(alloc: Allocator, session_id: []const u8) ![]u8 {
    const dir = std.process.getEnvVarOwned(alloc, "TEMP") catch
        (std.process.getEnvVarOwned(alloc, "TMP") catch return error.NoTempDir);
    defer alloc.free(dir);
    if (dir.len == 0) return error.NoTempDir;
    return std.fmt.allocPrint(alloc, "{s}\\ghoztty-ptyhost-{s}.json", .{ dir, session_id });
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "spec: round-trips the whole OPEN, including argv and forwarded env" {
    const env = [_]protocol.Open.EnvPair{
        .{ .key = "GHOZTTY_PANE_NAME", .value = "left pane \"quoted\"" },
        .{ .key = "PATH", .value = "C:\\Program Files\\x;C:\\y" },
    };
    const argv = [_][]const u8{ "pwsh", "-NoExit", "-Command", ". 'C:\\a b\\ghostty.ps1'" };
    const spec: Spec = .{
        .session_id = "0123456789abcdef0123456789abcdef",
        .pipe_name = "\\\\.\\pipe\\ghoztty-pty-host-debug-david-0123",
        .replay_bytes = 65536,
        .exit_linger_ms = 1234,
        .open = .{
            .rows = 41,
            .cols = 113,
            .px_w = 800,
            .px_h = 600,
            .cwd = "D:\\git\\ghoztty",
            .shell = "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
            .term = "xterm-ghostty",
            .env = &env,
            .argv = &argv,
            .pinned = true,
        },
    };

    const bytes = try serialize(testing.allocator, spec);
    defer testing.allocator.free(bytes);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    const got = parsed.value;

    try testing.expectEqualStrings(spec.session_id, got.session_id);
    try testing.expectEqualStrings(spec.pipe_name, got.pipe_name);
    try testing.expectEqual(@as(usize, 65536), got.replay_bytes);
    try testing.expectEqual(@as(i64, 1234), got.exit_linger_ms);
    try testing.expectEqual(@as(u16, 41), got.open.rows);
    try testing.expectEqual(@as(u16, 113), got.open.cols);
    try testing.expectEqual(@as(u16, 800), got.open.px_w);
    try testing.expectEqualStrings("D:\\git\\ghoztty", got.open.cwd.?);
    try testing.expectEqualStrings(spec.open.shell.?, got.open.shell.?);
    try testing.expect(got.open.pinned);
    // The two fields argv/env exist to survive: a quoted value and a path with
    // spaces are exactly what a command line would have mangled.
    try testing.expectEqual(@as(usize, 2), got.open.env.len);
    try testing.expectEqualStrings("left pane \"quoted\"", got.open.env[0].value);
    try testing.expectEqualStrings("C:\\Program Files\\x;C:\\y", got.open.env[1].value);
    try testing.expectEqual(@as(usize, 4), got.open.argv.?.len);
    try testing.expectEqualStrings(". 'C:\\a b\\ghostty.ps1'", got.open.argv.?[3]);
}

test "spec: a plain interactive session stays compact (null fields elided)" {
    const spec: Spec = .{
        .session_id = "abc",
        .pipe_name = "\\\\.\\pipe\\p",
        .open = .{ .rows = 24, .cols = 80 },
    };
    const bytes = try serialize(testing.allocator, spec);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"cwd\"") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"argv\"") == null);

    var parsed = try parse(testing.allocator, bytes);
    defer parsed.deinit();
    try testing.expect(parsed.value.open.cwd == null);
    try testing.expect(parsed.value.open.argv == null);
    try testing.expectEqual(@as(usize, 0), parsed.value.open.env.len);
    // Defaults survive the elision.
    try testing.expectEqual(@as(usize, 1024 * 1024), parsed.value.replay_bytes);
    try testing.expectEqualStrings("xterm-ghostty", parsed.value.open.term);
}

test "spec: newer fields are ignored, an unknown version is refused" {
    const body =
        \\{"version":1,"session_id":"s","pipe_name":"p","future_field":{"a":[1,2]},
        \\ "open":{"rows":24,"cols":80,"future_open_field":true}}
    ;
    var parsed = try parse(testing.allocator, body);
    defer parsed.deinit();
    try testing.expectEqualStrings("s", parsed.value.session_id);

    const newer =
        \\{"version":2,"session_id":"s","pipe_name":"p","open":{"rows":24,"cols":80}}
    ;
    try testing.expectError(error.UnsupportedSpecVersion, parse(testing.allocator, newer));
}

test "spec: write then readAndDelete leaves nothing behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, "spec.json" });
    defer testing.allocator.free(path);

    try write(testing.allocator, path, .{
        .session_id = "sid",
        .pipe_name = "pipe",
        .open = .{ .rows = 10, .cols = 20, .command = "echo hi" },
    });

    var parsed = try readAndDelete(testing.allocator, path);
    defer parsed.deinit();
    try testing.expectEqualStrings("echo hi", parsed.value.open.command.?);
    try testing.expectEqual(@as(u16, 10), parsed.value.open.rows);

    // Consumed: a second read finds nothing, so no forwarded env lingers.
    try testing.expectError(error.FileNotFound, readAndDelete(testing.allocator, path));
}
