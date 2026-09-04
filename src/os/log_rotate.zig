//! Bounding the shared Windows log sink
//! (`%LOCALAPPDATA%\ghoztty\ghoztty.log`).
//!
//! That file is the ONLY diagnostic surface a release build leaves behind (the
//! GUI subsystem has no console), and it is appended to by the GUI app, the
//! agent and every one-shot `ghoztty +…` CLI invocation — several a second on a
//! box driving Ghoztty from scripts. Until T410 nothing ever bounded it: it was
//! 9.4 MB on this box with no rotation and no cap, so the file a user would be
//! asked to send back grows without limit, and the only way it ever got smaller
//! was somebody deleting it by hand.
//!
//! So the writer keeps at most TWO generations — the live `ghoztty.log` and one
//! `ghoztty.log.1` — each bounded by `max_bytes`. That is a pair a user can zip
//! and a window of history long enough to hold an incident.
//!
//! ## Why the rename goes through the HANDLE and not the path
//!
//! Rotation is decided independently by every writer, so two processes can both
//! cross the threshold in the same millisecond. A path rename (`dir.rename`) is
//! then a real hazard: the first renames `ghoztty.log` to `.log.1`, a third
//! writer immediately creates a fresh (tiny) `ghoztty.log`, and the second's
//! rename moves THAT over the archive — the whole history dropped by the
//! mechanism that exists to preserve it.
//!
//! Renaming by handle removes the race rather than narrowing it. The handle
//! names a file OBJECT, not a path, so the second writer renames the very file
//! the first one already renamed: `.log.1` → `.log.1`, which succeeds and
//! changes nothing. A writer that opened after the rotation opens the fresh
//! file, sees a small size on its own handle, and does not rotate at all.
//!
//! The other half of the arrangement is on the append side: every writer opens
//! the sink with the default share mode, which includes `FILE_SHARE_DELETE`, so
//! the rename is legal while other processes hold the file open. Their handles
//! follow the renamed file for the microseconds until their next log line, when
//! they reopen the path and land on the new live file.

const std = @import("std");
const builtin = @import("builtin");

/// The size at which the live log is archived, and therefore also the most a
/// single generation can hold. Two generations means at most twice this on
/// disk.
///
/// 4 MiB is chosen against the incident this exists for: the 9.4 MB file that
/// could not be searched was ~90k lines, and half that is still days of a busy
/// box while being small enough that "zip both files and send them" is a
/// reasonable thing to ask of a user.
pub const max_bytes: u64 = 4 * 1024 * 1024;

pub const live_name = "ghoztty.log";
pub const rotated_name = "ghoztty.log.1";

/// Whether a sink of `size` bytes has reached the point of being archived.
///
/// Pure, so the threshold is testable without a filesystem: the check is `>=`,
/// which means a file that lands exactly ON the limit rotates rather than
/// sitting one byte under it forever.
pub fn shouldRotate(size: u64) bool {
    return size >= max_bytes;
}

/// Cheap "is it time?" for the hot path, asked on the caller's own append
/// handle so the common answer (no) costs one `GetFileSizeEx` and no open.
///
/// A handle that cannot answer is reported as not-oversize: a failure to
/// measure must never turn logging into an error path.
pub fn oversize(file: std.fs.File) bool {
    const size = file.getEndPos() catch return false;
    return shouldRotate(size);
}

/// Archive the live log over `rotated_name` if it is still oversize.
///
/// Best effort by construction — every failure path is a `return`, because the
/// caller is `logFn` and has nowhere to report to. The size is re-checked on
/// the rename handle rather than trusted from `oversize`: that is what makes
/// two writers crossing the threshold together safe (see the header).
pub fn rotate(dir: std.fs.Dir) void {
    if (comptime builtin.os.tag != .windows) return;

    const w = std.os.windows;
    const live_w = std.unicode.utf8ToUtf16LeStringLiteral(live_name);
    const handle = w.OpenFile(live_w, .{
        .dir = dir.fd,
        .access_mask = w.SYNCHRONIZE | w.DELETE | w.FILE_READ_ATTRIBUTES,
        .creation = w.FILE_OPEN,
    }) catch return;
    defer w.CloseHandle(handle);

    const size = w.GetFileSizeEx(handle) catch return;
    if (!shouldRotate(size)) return;

    renameHandle(
        handle,
        dir.fd,
        std.unicode.utf8ToUtf16LeStringLiteral(rotated_name),
    ) catch return;
}

/// `NtSetInformationFile(FileRenameInformation)` — rename the file this handle
/// refers to, replacing the destination if it exists.
///
/// The plain (non-`Ex`) information class is used deliberately: it is supported
/// everywhere, and the `Ex` variant's extra flags (POSIX semantics, ignore
/// read-only) buy nothing for a log file we own.
fn renameHandle(
    handle: std.os.windows.HANDLE,
    dir_fd: std.os.windows.HANDLE,
    new_path_w: []const u16,
) !void {
    const w = std.os.windows;

    const struct_buf_len = @sizeOf(w.FILE_RENAME_INFORMATION) + (std.fs.max_path_bytes - 1);
    var rename_info_buf: [struct_buf_len]u8 align(@alignOf(w.FILE_RENAME_INFORMATION)) = undefined;
    const struct_len = @sizeOf(w.FILE_RENAME_INFORMATION) - 1 + new_path_w.len * 2;
    if (struct_len > struct_buf_len) return error.NameTooLong;

    const rename_info: *w.FILE_RENAME_INFORMATION = @ptrCast(&rename_info_buf);
    rename_info.* = .{
        .Flags = w.TRUE, // ReplaceIfExists: the previous generation is dropped
        .RootDirectory = dir_fd,
        .FileNameLength = @intCast(new_path_w.len * 2),
        .FileName = undefined,
    };
    @memcpy((&rename_info.FileName).ptr, new_path_w);

    var io_status_block: w.IO_STATUS_BLOCK = undefined;
    const rc = w.ntdll.NtSetInformationFile(
        handle,
        &io_status_block,
        rename_info,
        @intCast(struct_len),
        .FileRenameInformation,
    );
    if (rc != .SUCCESS) return error.RenameFailed;
}

test "shouldRotate: the threshold is inclusive and nothing under it rotates" {
    const testing = std.testing;
    try testing.expect(!shouldRotate(0));
    try testing.expect(!shouldRotate(max_bytes - 1));
    try testing.expect(shouldRotate(max_bytes));
    try testing.expect(shouldRotate(max_bytes * 3));
}

test "rotate: an oversize live log becomes the .1 generation" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSized(tmp.dir, live_name, max_bytes, 'a');
    rotate(tmp.dir);

    // The live file is gone (the next log line recreates it) and its bytes are
    // in the archive.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(live_name));
    const archived = try tmp.dir.statFile(rotated_name);
    try testing.expectEqual(max_bytes, archived.size);
    try testing.expectEqual(@as(u8, 'a'), try firstByte(tmp.dir, rotated_name));
}

test "rotate: a live log under the threshold is left alone" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSized(tmp.dir, live_name, max_bytes - 1, 'a');
    rotate(tmp.dir);

    const live = try tmp.dir.statFile(live_name);
    try testing.expectEqual(max_bytes - 1, live.size);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(rotated_name));
}

test "rotate: exactly two generations survive, and the newer one wins" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try writeSized(tmp.dir, live_name, max_bytes, 'a');
    rotate(tmp.dir);
    try writeSized(tmp.dir, live_name, max_bytes, 'b');
    rotate(tmp.dir);

    // The first generation was replaced rather than kept as a `.2`: the cap is
    // two files, not a growing pile of them.
    try testing.expectEqual(@as(u8, 'b'), try firstByte(tmp.dir, rotated_name));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile("ghoztty.log.2"));

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count); // live is gone until the next write
}

test "rotate: a missing live log is a no-op, not an error" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    rotate(tmp.dir); // nothing to rotate; must not crash or create anything
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(rotated_name));
}

test "rotate: the archive is written while a writer still holds the log open" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSized(tmp.dir, live_name, max_bytes, 'a');

    // The real caller rotates from inside `logFn`, holding an append handle to
    // the very file being renamed. If that sharing were wrong the rename would
    // fail and the sink would grow forever with no symptom.
    const held = try tmp.dir.openFile(live_name, .{});
    defer held.close();

    rotate(tmp.dir);
    const archived = try tmp.dir.statFile(rotated_name);
    try testing.expectEqual(max_bytes, archived.size);
}

fn writeSized(dir: std.fs.Dir, name: []const u8, size: u64, fill: u8) !void {
    const file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();

    var chunk: [64 * 1024]u8 = undefined;
    @memset(&chunk, fill);
    var left = size;
    while (left > 0) {
        const n = @min(left, chunk.len);
        try file.writeAll(chunk[0..n]);
        left -= n;
    }
}

fn firstByte(dir: std.fs.Dir, name: []const u8) !u8 {
    const file = try dir.openFile(name, .{});
    defer file.close();
    var one: [1]u8 = undefined;
    _ = try file.readAll(&one);
    return one[0];
}
