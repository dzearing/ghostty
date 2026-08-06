//! Agent-side layout-blob persistence — the disk side of cross-machine "Resume
//! all" (§5.4, T18). The agent keeps a durable, atomically-written
//! `layouts.json` recording an OPAQUE per-window layout blob (pushed by the
//! owning viewer via `SET_LAYOUT`) plus the session ids each blob references:
//!
//!   {"version":1,"layouts":[{"key":<uuid>,"blob":<opaque-json-string>,
//!                            "session_ids":[<32-hex>, ...]}, ...]}
//!
//! The agent is DELIBERATELY topology-agnostic: `blob` is stored and returned
//! verbatim (it is the owning viewer's `SessionLayoutManifest.Entry` JSON — the
//! window frame, split tree with per-leaf session ids, titles, ipc names). The
//! agent only inspects `session_ids`, and only to REAP a blob once none of its
//! sessions exist any more. A viewer on another machine pulls these blobs with
//! `GET_LAYOUTS` and rebuilds the full window/tab/split topology locally,
//! attaching each leaf to its live session.
//!
//! ## Layering
//!
//! Like `session_meta.zig`, this depends on nothing but `std`, so it unit-tests
//! standalone and `session.zig` can call it without an import cycle:
//! `SessionStore` owns the trigger policy (upsert on SET_LAYOUT, reap on
//! session removal → serialize → write); this module owns the bytes on disk.
//!
//! ## Crash safety
//!
//! `writeAtomic` delegates to `atomic_write.writeChunks`, like
//! `session_meta.writeAtomic` — safe under concurrent writers to the same
//! path (T183).

const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic_write = @import("atomic_write.zig");

/// On-disk schema version. Bumped only on an incompatible layout change; the
/// loader tolerates unknown fields so additive fields need no bump.
pub const format_version: u32 = 1;

/// A hard ceiling on the file we will read back. Layout blobs are small
/// (a split tree of session ids + titles); 8 MiB comfortably holds the
/// 256-session cap's worth of windows and rejects an implausibly large file as
/// corrupt rather than reading it into memory.
pub const max_file_bytes: usize = 8 * 1024 * 1024;

/// One persisted layout. On `serialize` the fields are BORROWED from the caller
/// (a `SessionStore` snapshot); on `parse` they are owned by the returned
/// `Parsed` arena. `key` is the owning viewer's manifest-entry id; `blob` is the
/// opaque per-window layout JSON; `session_ids` are the sessions it references
/// (used only for reaping).
pub const Record = struct {
    key: []const u8,
    blob: []const u8,
    session_ids: []const []const u8 = &.{},
};

/// The whole file. `layouts` is a present (possibly empty) array so a reader
/// distinguishes "no stored layouts" from a corrupt/absent file.
pub const File = struct {
    version: u32 = format_version,
    layouts: []const Record = &.{},
};

/// A parsed file whose backing memory (including every string) is owned by the
/// embedded arena; `deinit()` frees it all.
pub const Parsed = std.json.Parsed(File);

/// Serialize `records` into the on-disk JSON body. Caller frees.
pub fn serialize(alloc: Allocator, records: []const Record) ![]u8 {
    const file: File = .{ .version = format_version, .layouts = records };
    return std.json.Stringify.valueAlloc(alloc, file, .{ .emit_null_optional_fields = false });
}

/// Parse an on-disk body. The returned `Parsed` owns its strings; caller
/// `deinit`s it. Unknown fields are ignored (newer/older interop). Strings are
/// copied into the arena (`alloc_always`) so the file buffer can be freed
/// immediately.
pub fn parse(alloc: Allocator, bytes: []const u8) !Parsed {
    return std.json.parseFromSlice(File, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Atomically write `bytes` to `path` (creating parent directories as needed).
/// Mirrors `session_meta.writeAtomic`: concurrent writers to the same path are
/// safe — see `atomic_write` (T183).
pub fn writeAtomic(alloc: Allocator, path: []const u8, bytes: []const u8) !void {
    try atomic_write.writeChunks(alloc, path, &.{bytes});
}

/// Load + parse the file at `path`. Returns null when ABSENT (normal — a first
/// start, or no layouts ever pushed). Any other I/O or parse failure propagates.
/// Caller `deinit`s a non-null result.
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

test "serialize + parse round-trip preserves layouts and ids in order" {
    const alloc = testing.allocator;
    const ids0 = [_][]const u8{
        "0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210",
    };
    const recs = [_]Record{
        .{
            .key = "11111111-2222-3333-4444-555555555555",
            .blob = "{\"tree\":{\"leaf\":{\"sessionID\":\"0123\"}}}",
            .session_ids = &ids0,
        },
        .{
            .key = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            .blob = "{}",
        },
    };

    const body = try serialize(alloc, &recs);
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"version\":1") != null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.value.version);
    try testing.expectEqual(@as(usize, 2), parsed.value.layouts.len);

    const a = parsed.value.layouts[0];
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", a.key);
    try testing.expectEqualStrings("{\"tree\":{\"leaf\":{\"sessionID\":\"0123\"}}}", a.blob);
    try testing.expectEqual(@as(usize, 2), a.session_ids.len);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", a.session_ids[0]);
    try testing.expectEqualStrings("fedcba9876543210fedcba9876543210", a.session_ids[1]);

    const b = parsed.value.layouts[1];
    try testing.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", b.key);
    try testing.expectEqual(@as(usize, 0), b.session_ids.len);
}

test "serialize an empty set is a present empty array" {
    const alloc = testing.allocator;
    const body = try serialize(alloc, &.{});
    defer alloc.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"layouts\":[]") != null);

    var parsed = try parse(alloc, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.layouts.len);
}

test "writeAtomic + load round-trip; no .tmp leftover; missing file loads null" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "state", "layouts.json" });
    defer alloc.free(path);

    try testing.expect((try load(alloc, path)) == null);

    const ids = [_][]const u8{"abcabcabcabcabcabcabcabcabcabcab"};
    const recs = [_]Record{.{ .key = "w1", .blob = "{\"x\":1}", .session_ids = &ids }};
    const body = try serialize(alloc, &recs);
    defer alloc.free(body);
    try writeAtomic(alloc, path, body);

    // No staging leftover of any name — the parent holds exactly the file.
    {
        var dir = try std.fs.cwd().openDir(std.fs.path.dirname(path).?, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next()) |entry| {
            count += 1;
            try testing.expectEqualStrings("layouts.json", entry.name);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    var loaded = (try load(alloc, path)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.value.layouts.len);
    try testing.expectEqualStrings("w1", loaded.value.layouts[0].key);
    try testing.expectEqualStrings("abcabcabcabcabcabcabcabcabcabcab", loaded.value.layouts[0].session_ids[0]);
}
