//! Agent-side **ring disk snapshots** — the scrollback half of the reboot floor
//! (§5.4, T13). `session_meta.zig` records WHICH sessions exist (so they can be
//! relaunched); this module records the recent OUTPUT of each session (so the
//! relaunched pane can replay its pre-restart scrollback instead of coming back
//! blank).
//!
//! A child process cannot outlive its agent, so on a reboot / crash / `kill -9`
//! the live pty and its in-RAM output ring are gone (POSIX). But the agent can
//! periodically flush each dirty session's ring to disk; after it restarts and
//! materializes the session (T12b), it preloads the snapshot into the fresh
//! ring, appends a "session restarted" divider, and replays the whole thing to
//! the reattaching viewer on `RELAUNCH` (server.zig). Best-effort by design: a
//! kernel panic loses ≤ the snapshot interval of tail output.
//!
//! ## On-disk format (`<rings_dir>/<session-id-hex>.ring`)
//!
//!   magic       : 4 bytes  "GRS2" (was "GRS1" — still read, see below)
//!   base_offset : u64 LE   absolute stream offset of the first retained byte
//!   cols        : u16 LE   pty width the retained bytes were produced at (GRS2)
//!   rows        : u16 LE   pty height at snapshot time (GRS2)
//!   byte_len    : u64 LE   number of ring bytes that follow
//!   bytes       : byte_len raw child-output bytes (VT-encoded, replayed as DATA)
//!
//! `cols`/`rows` (GRS2) record the CAPTURE WIDTH so the reattaching viewer can
//! replay the raw byte stream at the width it was drawn at and then reflow to the
//! live pane width — a raw stream full of in-place prompt redraws (`\r` + erase)
//! only lands cleanly at its original width; replayed narrower it smears (each
//! redraw wraps and the erase can't reclaim the row already pushed to
//! scrollback). A legacy **GRS1** file has no width; it loads with cols=rows=0
//! ("unknown") and the viewer falls back to live-width replay (today's behavior).
//!
//! `base_offset` is recorded for fidelity (it documents where in the raw stream
//! the snapshot sat), though the reboot loader renumbers the reloaded ring to
//! base 0 — a freshly-restored viewer applies DATA from offset 0 with no resync
//! watermark (connection.zig `prepareRelaunchPane`), so a non-zero base would
//! just manufacture a phantom gap.
//!
//! ## Layering / crash safety
//!
//! Depends only on `std` (like `session_meta`), so it unit-tests standalone and
//! `session.zig` imports it without a cycle. `writeAtomic` uses the same
//! tmp-in-the-same-dir + fsync + rename pattern as `session_meta.writeAtomic`:
//! a future agent start never observes a torn snapshot.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Current magic (written by `writeAtomic`). GRS2 adds cols/rows after
/// base_offset. `load` also accepts the legacy `magic_v1` ("GRS1", no width);
/// any OTHER magic is treated as absent (best-effort).
pub const magic = "GRS2";
/// Legacy width-less snapshot magic; still loaded (cols=rows=0 → unknown).
pub const magic_v1 = "GRS1";

/// GRS2 header: magic(4) + base_offset(8) + cols(2) + rows(2) + byte_len(8).
pub const header_len: usize = magic.len + 8 + 2 + 2 + 8;
/// GRS1 header: magic(4) + base_offset(8) + byte_len(8).
pub const header_len_v1: usize = magic_v1.len + 8 + 8;

/// A hard ceiling on a snapshot file we will read back. The ring is capped at
/// `persistent-scrollback-bytes` (default 16 MB, §5.2); allow generous slack so
/// a legitimately large ring loads while a corrupt length is rejected.
pub const max_file_bytes: usize = 64 * 1024 * 1024;

/// A parsed snapshot. `bytes` is owned by `alloc`; free via `free`. `cols`/`rows`
/// are the capture geometry (0 = unknown, e.g. a legacy GRS1 file).
pub const Loaded = struct {
    base_offset: u64,
    cols: u16 = 0,
    rows: u16 = 0,
    bytes: []u8,

    pub fn free(self: Loaded, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

/// Build the `<dir>/<id_str>.ring` path. Caller frees.
pub fn pathFor(alloc: Allocator, dir: []const u8, id_str: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.ring", .{ dir, id_str });
}

/// Atomically write a ring snapshot (header + `bytes`) to `path` via a
/// same-directory tmp + fsync + rename (creating parent dirs as needed). A
/// concurrent/subsequent reader sees only a complete file. Mirrors
/// `session_meta.writeAtomic` but streams the header and the (potentially large)
/// ring bytes in two writes rather than concatenating them into one buffer.
pub fn writeAtomic(
    alloc: Allocator,
    path: []const u8,
    base_offset: u64,
    cols: u16,
    rows: u16,
    bytes: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    {
        // Declared before the create/close pair so on error (LIFO) the file
        // closes BEFORE the delete — Windows can't delete an open file.
        errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
        const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();

        var header: [header_len]u8 = undefined;
        @memcpy(header[0..magic.len], magic);
        std.mem.writeInt(u64, header[magic.len..][0..8], base_offset, .little);
        std.mem.writeInt(u16, header[magic.len + 8 ..][0..2], cols, .little);
        std.mem.writeInt(u16, header[magic.len + 10 ..][0..2], rows, .little);
        std.mem.writeInt(u64, header[magic.len + 12 ..][0..8], @intCast(bytes.len), .little);
        try file.writeAll(&header);
        try file.writeAll(bytes);
        // Durable before the rename publishes it.
        try file.sync();
    }
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};
    try std.fs.cwd().rename(tmp_path, path);
}

/// Load + parse the snapshot at `path`. Returns null when the file is ABSENT (a
/// session with no snapshot yet — normal, non-error) or when it is corrupt /
/// mis-magic / mis-sized (best-effort: a bad snapshot must never stop a session
/// from relaunching — the pane just comes back without pre-restart scrollback).
/// Caller `free`s a non-null result.
pub fn load(alloc: Allocator, path: []const u8) !?Loaded {
    const raw = std.fs.cwd().readFileAlloc(alloc, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(raw);

    if (raw.len < magic.len) return null; // too short to even hold a magic

    // GRS2: base_offset + cols + rows + byte_len.
    if (std.mem.eql(u8, raw[0..magic.len], magic)) {
        if (raw.len < header_len) return null; // truncated header → treat as absent
        const base_offset = std.mem.readInt(u64, raw[magic.len..][0..8], .little);
        const cols = std.mem.readInt(u16, raw[magic.len + 8 ..][0..2], .little);
        const rows = std.mem.readInt(u16, raw[magic.len + 10 ..][0..2], .little);
        const byte_len = std.mem.readInt(u64, raw[magic.len + 12 ..][0..8], .little);
        if (byte_len != raw.len - header_len) return null; // length mismatch → corrupt
        const bytes = try alloc.dupe(u8, raw[header_len..]);
        return .{ .base_offset = base_offset, .cols = cols, .rows = rows, .bytes = bytes };
    }

    // Legacy GRS1: base_offset + byte_len, no width (cols=rows=0 → unknown). A
    // new agent must still read a snapshot an OLDER agent wrote (upgrade skew).
    if (std.mem.eql(u8, raw[0..magic_v1.len], magic_v1)) {
        if (raw.len < header_len_v1) return null;
        const base_offset = std.mem.readInt(u64, raw[magic_v1.len..][0..8], .little);
        const byte_len = std.mem.readInt(u64, raw[magic_v1.len + 8 ..][0..8], .little);
        if (byte_len != raw.len - header_len_v1) return null;
        const bytes = try alloc.dupe(u8, raw[header_len_v1..]);
        return .{ .base_offset = base_offset, .bytes = bytes };
    }

    return null; // unknown magic → treat as absent
}

/// Best-effort delete of a session's snapshot file (on CLOSE / reap). Missing
/// file is not an error.
pub fn delete(alloc: Allocator, dir: []const u8, id_str: []const u8) void {
    const path = pathFor(alloc, dir, id_str) catch return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "writeAtomic + load round-trip; no .tmp leftover; missing loads null" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    // Nested "rings" subdir exercises makePath.
    const rings_dir = try std.fs.path.join(alloc, &.{ dir_path, "rings" });
    defer alloc.free(rings_dir);
    const id = "0123456789abcdef0123456789abcdef";
    const path = try pathFor(alloc, rings_dir, id);
    defer alloc.free(path);

    // Absent → null.
    try testing.expect((try load(alloc, path)) == null);

    const payload = "PANE=3 PID=42\r\ntick-3-0\r\ntick-3-1\r\n";
    try writeAtomic(alloc, path, 1000, 120, 40, payload);

    // No staging file left behind.
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    try testing.expectError(error.FileNotFound, std.fs.cwd().statFile(tmp_path));

    var loaded = (try load(alloc, path)).?;
    defer loaded.free(alloc);
    try testing.expectEqual(@as(u64, 1000), loaded.base_offset);
    try testing.expectEqual(@as(u16, 120), loaded.cols);
    try testing.expectEqual(@as(u16, 40), loaded.rows);
    try testing.expectEqualStrings(payload, loaded.bytes);

    // Delete removes it (load → null again).
    delete(alloc, rings_dir, id);
    try testing.expect((try load(alloc, path)) == null);
}

test "empty ring round-trips (base only, zero bytes)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try pathFor(alloc, dir_path, "ffffffffffffffffffffffffffffffff");
    defer alloc.free(path);

    try writeAtomic(alloc, path, 0, 80, 24, "");
    var loaded = (try load(alloc, path)).?;
    defer loaded.free(alloc);
    try testing.expectEqual(@as(u64, 0), loaded.base_offset);
    try testing.expectEqual(@as(u16, 80), loaded.cols);
    try testing.expectEqual(@as(usize, 0), loaded.bytes.len);
}

test "legacy GRS1 (no width) still loads with cols=rows=0" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const path = try pathFor(alloc, dir_path, "1111111111111111111111111111111f");
    defer alloc.free(path);

    // Hand-assemble a GRS1 file: magic + base_offset + byte_len + bytes.
    const payload = "old-agent-scrollback\r\n";
    var buf: [header_len_v1 + payload.len]u8 = undefined;
    @memcpy(buf[0..magic_v1.len], magic_v1);
    std.mem.writeInt(u64, buf[magic_v1.len..][0..8], 500, .little);
    std.mem.writeInt(u64, buf[magic_v1.len + 8 ..][0..8], payload.len, .little);
    @memcpy(buf[header_len_v1..], payload);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = &buf });

    var loaded = (try load(alloc, path)).?;
    defer loaded.free(alloc);
    try testing.expectEqual(@as(u64, 500), loaded.base_offset);
    try testing.expectEqual(@as(u16, 0), loaded.cols); // unknown
    try testing.expectEqual(@as(u16, 0), loaded.rows);
    try testing.expectEqualStrings(payload, loaded.bytes);
}

test "corrupt files load as null (wrong magic, short header, length mismatch)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    // Wrong magic.
    {
        const p = try pathFor(alloc, dir_path, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        defer alloc.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "XXXX\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" });
        try testing.expect((try load(alloc, p)) == null);
    }
    // Short header (< header_len).
    {
        const p = try pathFor(alloc, dir_path, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        defer alloc.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "GRS1" });
        try testing.expect((try load(alloc, p)) == null);
    }
    // Length mismatch: byte_len claims 99 but only a few bytes follow (GRS2).
    {
        const p = try pathFor(alloc, dir_path, "cccccccccccccccccccccccccccccccc");
        defer alloc.free(p);
        var buf: [header_len + 3]u8 = undefined;
        @memcpy(buf[0..magic.len], magic);
        std.mem.writeInt(u64, buf[magic.len..][0..8], 0, .little); // base_offset
        std.mem.writeInt(u16, buf[magic.len + 8 ..][0..2], 80, .little); // cols
        std.mem.writeInt(u16, buf[magic.len + 10 ..][0..2], 24, .little); // rows
        std.mem.writeInt(u64, buf[magic.len + 12 ..][0..8], 99, .little); // byte_len (lie)
        buf[header_len] = 'a';
        buf[header_len + 1] = 'b';
        buf[header_len + 2] = 'c';
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = &buf });
        try testing.expect((try load(alloc, p)) == null);
    }
}
