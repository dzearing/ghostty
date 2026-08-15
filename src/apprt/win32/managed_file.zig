//! Marker-guarded, reparse-refusing, atomic file writer for Ghoztty-managed
//! artifacts in shared config dirs (T865, the win32 half of Mac's
//! `ManagedFile`). Only ever overwrites/removes files that carry the
//! ownership marker from `managed_marker.zig`, so a user's own same-named
//! file is never touched; every write lands whole or not at all.
//!
//! Windows translations of the Mac guarantees, chosen per the D46 policy:
//!
//! - Mac's symlink refusal becomes a REPARSE-POINT refusal: the destination
//!   is probed with `FILE_OPEN_REPARSE_POINT` + `FileAttributeTagInformation`,
//!   which catches symlinks, junctions, and OneDrive-style placeholders
//!   alike. (Off Windows — this file compiles in every lane on both seats —
//!   the probe degrades to `readLink`, i.e. exactly Mac's symlink check.)
//! - Mac's `replaceItemAt` becomes an NT rename with
//!   `FILE_RENAME_POSIX_SEMANTICS | FILE_RENAME_REPLACE_IF_EXISTS`, done
//!   directly rather than through `Dir.rename` because a destination held
//!   open without `FILE_SHARE_DELETE` fails the swap in a way POSIX
//!   `rename(2)` cannot — and `Dir.rename` surfaces that sharing violation
//!   as `error.Unexpected` (plus a Debug-mode stack trace). Here it is the
//!   typed `error.ReplaceBlocked` the caller reports, the temp file is
//!   removed, and the destination is untouched.
//! - Mac's `mode_t`/`chmod` has no analog and is dropped: default ACLs
//!   inherit from the profile dir, which is already owner-only for
//!   `%USERPROFILE%` children.
//!
//! The temp file is `.ghoztty-<random>.tmp` IN THE DESTINATION DIRECTORY —
//! same volume, so the replace is a true rename and can never degrade into a
//! copy loop that a watcher would see half-written. The probe-then-rename
//! window is not a follow hazard: a reparse point racing into existence
//! after the probe is REPLACED by the rename (rename never dereferences its
//! destination), not written through.
//!
//! Pure classification (marker grammar, install states) lives in
//! `managed_marker.zig` with unit tests in every lane; the tempdir tests
//! here exercise the file ops themselves.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const marker_mod = @import("managed_marker.zig");
pub const InstallState = marker_mod.InstallState;

/// Cap on how much of an existing file is read for marker/state checks.
/// Managed artifacts are scripts and markdown a few KB long; a file at this
/// size is certainly not ours, and treating it as unmanaged (refuse to
/// touch) is the safe answer on both sides of the cap.
pub const max_managed_bytes = 4 * 1024 * 1024;

pub const WriteError = error{
    /// The destination exists and does not carry the marker: it is the
    /// user's file, and it was left byte-identical.
    NotManaged,
    /// The destination is a symlink/junction/placeholder; nothing was
    /// written (the dotfiles hazard Mac refuses symlinks for).
    ReparsePointRefused,
    /// The atomic swap was refused — destination locked by another process
    /// (`ERROR_SHARING_VIOLATION` et al). The old content is intact and the
    /// temp file was removed.
    ReplaceBlocked,
    /// Any other I/O failure creating, filling, or swapping the temp file.
    /// No half-written destination and no temp litter either way.
    WriteFailed,
    OutOfMemory,
};

pub const RemoveError = error{
    /// The file exists and does not carry the marker; it was not deleted.
    NotManaged,
    /// The file could not be read or deleted.
    RemoveFailed,
};

/// Mac's `ManagedFile.state`: unreadable → not_installed; unmarked →
/// not_installed; byte-identical to `expected` → installed; else outdated.
pub fn state(
    alloc: Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
    expected: []const u8,
    marker: []const u8,
) InstallState {
    const contents = dir.readFileAlloc(alloc, sub_path, max_managed_bytes) catch
        return .not_installed;
    defer alloc.free(contents);
    return marker_mod.classify(contents, expected, marker);
}

/// Marker-guarded atomic write: refuse to clobber an existing file that is
/// not ours, then `writeAtomicNoFollow`.
pub fn write(
    alloc: Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
    contents: []const u8,
    marker: []const u8,
) WriteError!void {
    if (dir.readFileAlloc(alloc, sub_path, max_managed_bytes)) |existing| {
        defer alloc.free(existing);
        if (!marker_mod.isManaged(existing, marker)) return error.NotManaged;
    } else |err| switch (err) {
        error.FileNotFound => {},
        // Over-cap: not ours (see max_managed_bytes), refuse to clobber.
        error.FileTooBig => return error.NotManaged,
        error.OutOfMemory => return error.OutOfMemory,
        // Present but unreadable: refuse rather than overwrite blind.
        else => return error.WriteFailed,
    }
    try writeAtomicNoFollow(alloc, dir, sub_path, contents);
}

/// Atomic, reparse-refusing write with NO ownership-marker requirement — for
/// a shared, user-owned file (e.g. Claude's `settings.json`) that
/// legitimately carries no Ghoztty marker but must still never be written
/// through a link or left half-written. Same guarantees as `write` minus the
/// marker guard the caller enforces (or doesn't).
pub fn writeAtomicNoFollow(
    alloc: Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
    contents: []const u8,
) WriteError!void {
    if (isReparsePoint(dir, sub_path)) return error.ReparsePointRefused;
    if (std.fs.path.dirname(sub_path)) |parent|
        dir.makePath(parent) catch return error.WriteFailed;

    // Unique dot-temp beside the destination (same volume — see module doc).
    var tmp_sub: []u8 = undefined;
    var file: std.fs.File = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const nonce = std.crypto.random.int(u64);
        tmp_sub = tempName(alloc, sub_path, nonce) catch return error.OutOfMemory;
        if (dir.createFile(tmp_sub, .{ .exclusive = true })) |f| {
            file = f;
            break;
        } else |err| {
            alloc.free(tmp_sub);
            if (err == error.PathAlreadyExists and attempt < 4) continue;
            return error.WriteFailed;
        }
    }
    defer alloc.free(tmp_sub);

    var filled = false;
    fill: {
        file.writeAll(contents) catch break :fill;
        // Flush before the swap so the rename publishes complete bytes (the
        // durability MOVEFILE_WRITE_THROUGH bought on the MoveFileExW path).
        file.sync() catch break :fill;
        filled = true;
    }
    file.close();
    if (!filled) {
        dir.deleteFile(tmp_sub) catch {};
        return error.WriteFailed;
    }

    replaceExisting(dir, tmp_sub, sub_path) catch |err| {
        dir.deleteFile(tmp_sub) catch {};
        return err;
    };
}

/// Mac's `removeIfManaged`: absent → ok; unmarked → refuse; marked → delete.
pub fn removeIfManaged(
    alloc: Allocator,
    dir: std.fs.Dir,
    sub_path: []const u8,
    marker: []const u8,
) RemoveError!void {
    const contents = dir.readFileAlloc(alloc, sub_path, max_managed_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        error.FileTooBig => return error.NotManaged,
        else => return error.RemoveFailed,
    };
    defer alloc.free(contents);
    if (!marker_mod.isManaged(contents, marker)) return error.NotManaged;
    dir.deleteFile(sub_path) catch return error.RemoveFailed;
}

/// `.ghoztty-<nonce>.tmp` next to `sub_path` (same directory component).
fn tempName(alloc: Allocator, sub_path: []const u8, nonce: u64) Allocator.Error![]u8 {
    return if (std.fs.path.dirname(sub_path)) |parent|
        std.fmt.allocPrint(alloc, "{s}{c}.ghoztty-{x:0>16}.tmp", .{
            parent, std.fs.path.sep, nonce,
        })
    else
        std.fmt.allocPrint(alloc, ".ghoztty-{x:0>16}.tmp", .{nonce});
}

/// Whether `sub_path` names a reparse point (Windows) / symlink (elsewhere).
/// Absent → false; a probe that cannot decide answers false and lets the
/// write itself surface the real error (the rename does not follow its
/// destination, so a false negative cannot turn into a write-through).
fn isReparsePoint(dir: std.fs.Dir, sub_path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const path_w = w.sliceToPrefixedFileW(dir.fd, sub_path) catch return false;
        const handle = w.OpenFile(path_w.span(), .{
            .dir = dir.fd,
            .access_mask = w.SYNCHRONIZE | w.FILE_READ_ATTRIBUTES,
            .creation = w.FILE_OPEN,
            .filter = .any,
            .follow_symlinks = false,
        }) catch return false;
        defer w.CloseHandle(handle);

        var io: w.IO_STATUS_BLOCK = undefined;
        var info: w.FILE_ATTRIBUTE_TAG_INFO = undefined;
        const rc = w.ntdll.NtQueryInformationFile(
            handle,
            &io,
            &info,
            @sizeOf(w.FILE_ATTRIBUTE_TAG_INFO),
            .FileAttributeTagInformation,
        );
        if (rc != .SUCCESS) return false;
        return info.FileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0;
    } else {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = dir.readLink(sub_path, &buf) catch |err| switch (err) {
            error.UnsupportedReparsePointType => return true,
            else => return false,
        };
        return true;
    }
}

/// Atomically move `tmp_sub` over `dest_sub` (both relative to `dir`),
/// replacing any existing destination. See the module doc for why this is
/// hand-rolled on Windows rather than `Dir.rename`.
fn replaceExisting(dir: std.fs.Dir, tmp_sub: []const u8, dest_sub: []const u8) WriteError!void {
    if (builtin.os.tag != .windows) {
        return dir.rename(tmp_sub, dest_sub) catch |err| switch (err) {
            error.AccessDenied => error.ReplaceBlocked,
            else => error.WriteFailed,
        };
    }

    const w = std.os.windows;
    const tmp_w = w.sliceToPrefixedFileW(dir.fd, tmp_sub) catch return error.WriteFailed;
    const dest_w = w.sliceToPrefixedFileW(dir.fd, dest_sub) catch return error.WriteFailed;
    const dest_span = dest_w.span();
    const dest_is_abs = std.fs.path.isAbsoluteWindowsWTF16(dest_span);

    const src = w.OpenFile(tmp_w.span(), .{
        .dir = dir.fd,
        .access_mask = w.SYNCHRONIZE | w.GENERIC_WRITE | w.DELETE,
        .creation = w.FILE_OPEN,
        .filter = .any,
        .follow_symlinks = false,
    }) catch return error.WriteFailed;
    defer w.CloseHandle(src);

    var io: w.IO_STATUS_BLOCK = undefined;

    // FileRenameInformationEx + POSIX semantics first: it allows replacing a
    // destination other processes hold open WITH FILE_SHARE_DELETE, which is
    // the closest Windows gets to rename(2).
    ex: {
        const buf_len = @sizeOf(w.FILE_RENAME_INFORMATION_EX) + w.PATH_MAX_WIDE * 2;
        var info_buf: [buf_len]u8 align(@alignOf(w.FILE_RENAME_INFORMATION_EX)) = undefined;
        const struct_len = @sizeOf(w.FILE_RENAME_INFORMATION_EX) - 2 + dest_span.len * 2;
        if (struct_len > buf_len) return error.WriteFailed;
        const info: *w.FILE_RENAME_INFORMATION_EX = @ptrCast(&info_buf);
        info.* = .{
            .Flags = w.FILE_RENAME_POSIX_SEMANTICS |
                w.FILE_RENAME_IGNORE_READONLY_ATTRIBUTE |
                w.FILE_RENAME_REPLACE_IF_EXISTS,
            .RootDirectory = if (dest_is_abs) null else dir.fd,
            .FileNameLength = @intCast(dest_span.len * 2),
            .FileName = undefined,
        };
        @memcpy((&info.FileName).ptr, dest_span);
        const rc = w.ntdll.NtSetInformationFile(
            src,
            &io,
            info,
            @intCast(struct_len),
            .FileRenameInformationEx,
        );
        switch (rc) {
            .SUCCESS => return,
            // Filesystem doesn't speak the Ex class; use the classic one.
            .INVALID_PARAMETER => break :ex,
            .SHARING_VIOLATION, .ACCESS_DENIED, .CANNOT_DELETE, .USER_MAPPED_FILE => return error.ReplaceBlocked,
            else => return error.WriteFailed,
        }
    }

    const buf_len = @sizeOf(w.FILE_RENAME_INFORMATION) + w.PATH_MAX_WIDE * 2;
    var info_buf: [buf_len]u8 align(@alignOf(w.FILE_RENAME_INFORMATION)) = undefined;
    const struct_len = @sizeOf(w.FILE_RENAME_INFORMATION) - 2 + dest_span.len * 2;
    if (struct_len > buf_len) return error.WriteFailed;
    const info: *w.FILE_RENAME_INFORMATION = @ptrCast(&info_buf);
    info.* = .{
        .Flags = w.TRUE, // ReplaceIfExists
        .RootDirectory = if (dest_is_abs) null else dir.fd,
        .FileNameLength = @intCast(dest_span.len * 2),
        .FileName = undefined,
    };
    @memcpy((&info.FileName).ptr, dest_span);
    const rc = w.ntdll.NtSetInformationFile(
        src,
        &io,
        info,
        @intCast(struct_len),
        .FileRenameInformation,
    );
    switch (rc) {
        .SUCCESS => return,
        .SHARING_VIOLATION, .ACCESS_DENIED, .CANNOT_DELETE, .USER_MAPPED_FILE => return error.ReplaceBlocked,
        else => return error.WriteFailed,
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;
const test_marker = marker_mod.shell_comment;

/// No `.ghoztty-*.tmp` may survive any outcome, success or refusal.
fn expectNoTempLitter(dir: std.fs.Dir) !void {
    var it_dir = try dir.openDir(".", .{ .iterate = true });
    defer it_dir.close();
    var it = it_dir.iterate();
    while (try it.next()) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".ghoztty-") == null);
    }
}

test "state: absent, unmarked, current, stale" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const expected = test_marker ++ "\necho v2\n";

    try testing.expectEqual(InstallState.not_installed, state(alloc, tmp.dir, "absent.sh", expected, marker_mod.token));

    try tmp.dir.writeFile(.{ .sub_path = "user.sh", .data = "echo mine\n" });
    try testing.expectEqual(InstallState.not_installed, state(alloc, tmp.dir, "user.sh", expected, marker_mod.token));

    try tmp.dir.writeFile(.{ .sub_path = "current.sh", .data = expected });
    try testing.expectEqual(InstallState.installed, state(alloc, tmp.dir, "current.sh", expected, marker_mod.token));

    try tmp.dir.writeFile(.{ .sub_path = "stale.sh", .data = test_marker ++ "\necho v1\n" });
    try testing.expectEqual(InstallState.outdated, state(alloc, tmp.dir, "stale.sh", expected, marker_mod.token));
}

test "write: refuses an unmarked existing file and leaves it byte-identical" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const users_own = "# my own script, hands off\n";
    try tmp.dir.writeFile(.{ .sub_path = "taken.sh", .data = users_own });

    try testing.expectError(
        error.NotManaged,
        write(alloc, tmp.dir, "taken.sh", test_marker ++ "\necho ours\n", marker_mod.token),
    );

    const after = try tmp.dir.readFileAlloc(alloc, "taken.sh", max_managed_bytes);
    defer alloc.free(after);
    try testing.expectEqualStrings(users_own, after);
    try expectNoTempLitter(tmp.dir);
}

test "write: creates fresh (with parent dirs), updates marked, leaves no litter" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const v1 = test_marker ++ "\necho v1\n";
    const v2 = test_marker ++ "\necho v2\n";

    try write(alloc, tmp.dir, "skills" ++ std.fs.path.sep_str ++ "banner.sh", v1, marker_mod.token);
    {
        const got = try tmp.dir.readFileAlloc(alloc, "skills" ++ std.fs.path.sep_str ++ "banner.sh", max_managed_bytes);
        defer alloc.free(got);
        try testing.expectEqualStrings(v1, got);
    }

    try write(alloc, tmp.dir, "skills" ++ std.fs.path.sep_str ++ "banner.sh", v2, marker_mod.token);
    {
        const got = try tmp.dir.readFileAlloc(alloc, "skills" ++ std.fs.path.sep_str ++ "banner.sh", max_managed_bytes);
        defer alloc.free(got);
        try testing.expectEqualStrings(v2, got);
    }

    var sub = try tmp.dir.openDir("skills", .{ .iterate = true });
    defer sub.close();
    try expectNoTempLitter(sub);
}

test "writeAtomicNoFollow: markerless write over a user-owned file works" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "settings.json", .data = "{\"user\": true}" });
    try writeAtomicNoFollow(alloc, tmp.dir, "settings.json", "{\"user\": true, \"hooks\": {}}");
    const got = try tmp.dir.readFileAlloc(alloc, "settings.json", max_managed_bytes);
    defer alloc.free(got);
    try testing.expectEqualStrings("{\"user\": true, \"hooks\": {}}", got);
    try expectNoTempLitter(tmp.dir);
}

test "removeIfManaged: absent ok, unmarked refused, marked deleted" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try removeIfManaged(alloc, tmp.dir, "never-there.sh", marker_mod.token);

    try tmp.dir.writeFile(.{ .sub_path = "user.sh", .data = "# mine\n" });
    try testing.expectError(error.NotManaged, removeIfManaged(alloc, tmp.dir, "user.sh", marker_mod.token));
    _ = try tmp.dir.statFile("user.sh"); // still there

    try tmp.dir.writeFile(.{ .sub_path = "ours.sh", .data = test_marker ++ "\necho hi\n" });
    try removeIfManaged(alloc, tmp.dir, "ours.sh", marker_mod.token);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile("ours.sh"));
}

/// Test-only, Windows-only: turn the empty directory `link_name` into a
/// junction (mount point) at `target_abs`. Junctions need no privilege,
/// unlike symlinks, which is what makes this testable on any box.
fn createJunction(dir: std.fs.Dir, link_name: []const u8, target_abs: []const u8) !void {
    const w = std.os.windows;
    try dir.makeDir(link_name);
    const link_w = try w.sliceToPrefixedFileW(dir.fd, link_name);
    const handle = try w.OpenFile(link_w.span(), .{
        .dir = dir.fd,
        .access_mask = w.SYNCHRONIZE | w.GENERIC_READ | w.GENERIC_WRITE,
        .creation = w.FILE_OPEN,
        .filter = .dir_only,
        .follow_symlinks = false,
    });
    defer w.CloseHandle(handle);

    // Substitute name is the NT spelling; print name the Win32 one.
    var sub_name: [512]u16 = undefined;
    var print_name: [512]u16 = undefined;
    const nt_prefix = [_]u16{ '\\', '?', '?', '\\' };
    @memcpy(sub_name[0..4], &nt_prefix);
    const target_len = try std.unicode.utf8ToUtf16Le(sub_name[4..], target_abs);
    const sub_len = 4 + target_len;
    @memcpy(print_name[0..target_len], sub_name[4..][0..target_len]);

    const sub_bytes: u16 = @intCast(sub_len * 2);
    const print_bytes: u16 = @intCast(target_len * 2);

    var buf: [w.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const wr = fbs.writer();
    try wr.writeInt(u32, w.IO_REPARSE_TAG_MOUNT_POINT, .little);
    try wr.writeInt(u16, 8 + sub_bytes + 2 + print_bytes + 2, .little); // ReparseDataLength
    try wr.writeInt(u16, 0, .little); // Reserved
    try wr.writeInt(u16, 0, .little); // SubstituteNameOffset
    try wr.writeInt(u16, sub_bytes, .little);
    try wr.writeInt(u16, sub_bytes + 2, .little); // PrintNameOffset
    try wr.writeInt(u16, print_bytes, .little);
    try wr.writeAll(std.mem.sliceAsBytes(sub_name[0..sub_len]));
    try wr.writeInt(u16, 0, .little);
    try wr.writeAll(std.mem.sliceAsBytes(print_name[0..target_len]));
    try wr.writeInt(u16, 0, .little);

    try w.DeviceIoControl(handle, w.FSCTL_SET_REPARSE_POINT, fbs.getWritten(), null);
}

test "writeAtomicNoFollow: refuses a junction destination (windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("jtarget");
    const target_abs = try tmp.dir.realpathAlloc(alloc, "jtarget");
    defer alloc.free(target_abs);
    try createJunction(tmp.dir, "jlink", target_abs);

    try testing.expectError(
        error.ReparsePointRefused,
        writeAtomicNoFollow(alloc, tmp.dir, "jlink", "payload"),
    );
    try expectNoTempLitter(tmp.dir);
}

test "writeAtomicNoFollow: refuses a file symlink destination where privilege allows (windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "real.txt", .data = "target\n" });
    tmp.dir.symLink("real.txt", "link.txt", .{}) catch |err| switch (err) {
        // No symlink privilege / developer mode on this box: the junction
        // test above still covers the reparse refusal.
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    try testing.expectError(
        error.ReparsePointRefused,
        writeAtomicNoFollow(alloc, tmp.dir, "link.txt", "payload"),
    );
    // And the symlink target was not written through.
    const got = try tmp.dir.readFileAlloc(alloc, "real.txt", max_managed_bytes);
    defer alloc.free(got);
    try testing.expectEqualStrings("target\n", got);
}

test "writeAtomicNoFollow: refuses a symlink destination (posix)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "real.txt", .data = "target\n" });
    try tmp.dir.symLink("real.txt", "link.txt", .{});
    try testing.expectError(
        error.ReparsePointRefused,
        writeAtomicNoFollow(alloc, tmp.dir, "link.txt", "payload"),
    );
    const got = try tmp.dir.readFileAlloc(alloc, "real.txt", max_managed_bytes);
    defer alloc.free(got);
    try testing.expectEqualStrings("target\n", got);
}

test "writeAtomicNoFollow: locked destination is ReplaceBlocked, intact, no litter (windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = test_marker ++ "\necho v1\n";
    try writeAtomicNoFollow(alloc, tmp.dir, "held.sh", original);

    // Hold the destination open with NO sharing — the FileShare.None of the
    // validation criteria — so the swap cannot take it.
    const w = std.os.windows;
    const held_w = try w.sliceToPrefixedFileW(tmp.dir.fd, "held.sh");
    const held = try w.OpenFile(held_w.span(), .{
        .dir = tmp.dir.fd,
        .access_mask = w.SYNCHRONIZE | w.GENERIC_READ,
        .share_access = 0,
        .creation = w.FILE_OPEN,
    });

    const blocked = writeAtomicNoFollow(alloc, tmp.dir, "held.sh", test_marker ++ "\necho v2\n");
    w.CloseHandle(held);
    try testing.expectError(error.ReplaceBlocked, blocked);

    const after = try tmp.dir.readFileAlloc(alloc, "held.sh", max_managed_bytes);
    defer alloc.free(after);
    try testing.expectEqualStrings(original, after);
    try expectNoTempLitter(tmp.dir);
}
