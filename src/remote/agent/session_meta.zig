//! Agent-side session-metadata persistence — the **write side** of the reboot
//! floor (§5.4, T12). The agent keeps a durable, atomically-written
//! `sessions.json` recording just enough about every LIVE session to relaunch
//! it after the agent (or the whole machine) restarts:
//!
//!   {"version":1,"sessions":[{"id":<32-hex>,"argv":?,"cwd":?,"title":?,
//!                             "pinned":bool,"created_ms":i64}, ...]}
//!
//! The upgrade demo (T06–T08) keeps the agent process ALIVE across an app
//! restart, so it never touches disk. The reboot floor is the harder case: the
//! agent process itself dies (crash, `kill -9`, reboot). A child process cannot
//! outlive its agent, so scrollback + PIDs are unavoidably lost — but the
//! *intent* (which panes, running what, where) can be recorded here and the
//! commands RE-launched under their recorded metadata on the next start
//! (materialization + the `RELAUNCH` frame are T12b; this file is only the
//! format + atomic write + a standalone parse round-trip).
//!
//! ## Layering
//!
//! Deliberately transport- and store-agnostic: it depends on nothing but `std`,
//! so it unit-tests standalone and `session.zig` can call it without an import
//! cycle. `SessionStore` (session.zig) owns the trigger policy (snapshot the
//! alive set → serialize → write); this module owns the bytes on disk.
//!
//! ## Crash safety
//!
//! `writeAtomic` uses the same tmp-in-the-same-dir + fsync + rename pattern as
//! the agent's info-file writer (`main.zig writeInfoFile`, itself modeled on
//! `enroll.saveRelayEnv`): a reader (a future agent start) never observes a
//! torn or partially-flushed file — it sees either the previous complete file
//! or the new complete file, never a mix.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// On-disk schema version. Bumped only on an incompatible layout change; the
/// loader tolerates unknown fields (`ignore_unknown_fields`) so additive fields
/// need no bump.
pub const format_version: u32 = 1;

/// A hard ceiling on the file we will read back (T12b's loader). 256 sessions
/// (the `session.max_sessions` cap) × a generous per-record budget; a file
/// larger than this is treated as corrupt rather than read into memory.
pub const max_file_bytes: usize = 4 * 1024 * 1024;

/// One persisted session's relaunch metadata. On `serialize` the string fields
/// are BORROWED from the caller (a `SessionStore` snapshot); on `parse` they are
/// owned by the returned `Parsed` arena. `id` is the 32-hex session-id string
/// (`Session.idStr`); `created_ms` is the agent-clock creation timestamp.
pub const Record = struct {
    id: []const u8,
    argv: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    pinned: bool = false,
    created_ms: i64 = 0,
    /// How many agent restarts this record has been materialized across WITHOUT
    /// anyone resuming it. Bounds the reboot floor so the file self-heals.
    ///
    /// Without it the file is a ratchet that only grows. `materialize` marks
    /// every record it loads `relaunchable = true`, and `persistMeta` keeps any
    /// relaunchable tombstone — so a record, once written, is re-loaded and
    /// re-written forever. Each stale record then shows in the chooser as a
    /// permanent "Resume" row for a process that exited long ago, and the list
    /// grows with every restart (observed here: 8 → 9 → 11 → 13 → 14). The
    /// existing "the file self-heals on the next open/close" comment in
    /// `persistMeta` could never come true for exactly this reason.
    ///
    /// Reset to 0 the moment the session is genuinely resumed (RELAUNCH or a
    /// successful ATTACH), so a session someone actually uses is never aged out.
    ///
    /// Additive and back-compatible: an older agent omits the field, it decodes
    /// as 0, and the record simply gets a fresh allowance.
    unclaimed_restarts: u32 = 0,
};

/// How many agent restarts a never-resumed tombstone may survive before it is
/// dropped from the file. Two, not one: a reboot that immediately restarts the
/// agent (or an agent upgrade landing before the user returns) must not cost
/// them the session, which is the whole point of the reboot floor. Past that it
/// is stale — nothing has re-attached to it across two full agent lifetimes.
pub const max_unclaimed_restarts: u32 = 2;

/// The whole file. `sessions` is a present (possibly empty) array so a reader
/// distinguishes "no live sessions" from a corrupt/absent file.
pub const File = struct {
    version: u32 = format_version,
    sessions: []const Record = &.{},
};

/// A parsed file whose backing memory (including every record string) is owned
/// by the embedded arena; `deinit()` frees it all.
pub const Parsed = std.json.Parsed(File);

/// Serialize `records` into the on-disk JSON body. Caller frees. Null optional
/// fields are elided (`emit_null_optional_fields=false`) so a plain shell
/// session — no explicit command, no cwd/title yet — stays compact.
pub fn serialize(alloc: Allocator, records: []const Record) ![]u8 {
    const file: File = .{ .version = format_version, .sessions = records };
    return std.json.Stringify.valueAlloc(alloc, file, .{ .emit_null_optional_fields = false });
}

/// Parse an on-disk body. The returned `Parsed` owns its strings; caller
/// `deinit`s it. Unknown fields are ignored so a newer agent's additive fields
/// don't break an older reader (and vice-versa).
pub fn parse(alloc: Allocator, bytes: []const u8) !Parsed {
    return std.json.parseFromSlice(File, alloc, bytes, .{
        .ignore_unknown_fields = true,
        // Copy every string into the `Parsed` arena rather than slicing it out
        // of `bytes` (the default `alloc_if_needed` would alias the input). This
        // makes the result self-owning so `load` can free the file buffer
        // immediately and still hand back valid strings.
        .allocate = .alloc_always,
    });
}

/// Atomically write `bytes` to `path` via a same-directory tmp + fsync + rename
/// (creating parent directories as needed). A concurrent/subsequent reader sees
/// only a complete file. Mirrors `main.zig writeInfoFile`.
pub fn writeAtomic(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    {
        // Declared before the create/close pair so on error (LIFO) the file
        // closes BEFORE the delete — Windows can't delete an open file.
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
        // Durable before the rename publishes it.
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);
}

/// Load + parse the file at `path`. Returns null when the file is ABSENT (a
/// first start, or a clean box) — that is a normal, non-error state. Any other
/// I/O or parse failure propagates. Caller `deinit`s a non-null result.
pub fn load(alloc: Allocator, path: []const u8) !?Parsed {
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(bytes);
    return try parse(alloc, bytes);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "serialize + parse round-trip preserves records and elides nulls" {
    const alloc = testing.allocator;
    const recs = [_]Record{
        .{
            .id = "0123456789abcdef0123456789abcdef",
            .argv = "/bin/zsh -lic 'sleep 600'",
            .cwd = "/Users/x/work",
            .title = "work",
            .pinned = true,
            .created_ms = 1700,
        },
        // A plain shell: no command, no cwd/title captured yet.
        .{
            .id = "ffffffffffffffffffffffffffffffff",
            .pinned = false,
            .created_ms = 42,
        },
    };

    const body = try serialize(alloc, &recs);
    defer alloc.free(body);

    // Null optionals are elided, not emitted as `null`.
    try testing.expect(std.mem.indexOf(u8, body, "\"version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "null") == null);
    // The record with no argv must not carry an argv key at all.
    try testing.expect(std.mem.indexOf(u8, body, "\"argv\":\"/bin/zsh") != null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.value.version);
    try testing.expectEqual(@as(usize, 2), parsed.value.sessions.len);

    const a = parsed.value.sessions[0];
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", a.id);
    try testing.expectEqualStrings("/bin/zsh -lic 'sleep 600'", a.argv.?);
    try testing.expectEqualStrings("/Users/x/work", a.cwd.?);
    try testing.expectEqualStrings("work", a.title.?);
    try testing.expect(a.pinned);
    try testing.expectEqual(@as(i64, 1700), a.created_ms);

    const b = parsed.value.sessions[1];
    try testing.expectEqualStrings("ffffffffffffffffffffffffffffffff", b.id);
    try testing.expect(b.argv == null);
    try testing.expect(b.cwd == null);
    try testing.expect(b.title == null);
    try testing.expect(!b.pinned);
    try testing.expectEqual(@as(i64, 42), b.created_ms);
}

test "serialize an empty roster is a present empty array" {
    const alloc = testing.allocator;
    const body = try serialize(alloc, &.{});
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"sessions\":[]") != null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.sessions.len);
}

test "writeAtomic + load round-trip; no .tmp leftover; missing file loads null" {
    const alloc = testing.allocator;

    // A unique temp dir so parallel test runs don't collide.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    // Nested path exercises makePath (the parent dir does not exist yet).
    const path = try std.fs.path.join(alloc, &.{ dir_path, "state", "sessions.json" });
    defer alloc.free(path);

    // Absent → null (a first start).
    try testing.expect((try load(alloc, path)) == null);

    const recs = [_]Record{.{
        .id = "abcabcabcabcabcabcabcabcabcabcab",
        .argv = "top",
        .pinned = true,
        .created_ms = 9,
    }};
    const body = try serialize(alloc, &recs);
    defer alloc.free(body);
    try writeAtomic(alloc, path, body);

    // The staging file is consumed by the rename, never left behind.
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(tmp_path));

    var loaded = (try load(alloc, path)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.value.sessions.len);
    try testing.expectEqualStrings("top", loaded.value.sessions[0].argv.?);
    try testing.expect(loaded.value.sessions[0].pinned);

    // Rewrite (an agent restart reusing the same path) replaces the file.
    try writeAtomic(alloc, path, body);
    var loaded2 = (try load(alloc, path)).?;
    defer loaded2.deinit();
    try testing.expectEqual(@as(usize, 1), loaded2.value.sessions.len);
}
