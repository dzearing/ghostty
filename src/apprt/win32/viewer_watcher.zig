//! Watch one file for changes, so a viewer pane re-renders when the document
//! it is showing is saved (T391 — Mac's `startWatchingFile`/`scheduleReload`,
//! `ViewerView.swift:1953`).
//!
//! **This watches the DIRECTORY, not the file**, and that is the whole
//! translation. Mac's kqueue source is attached to an open file DESCRIPTOR, so
//! an atomic save — write a temp file, rename it over the target — leaves the
//! watcher holding the inode nobody will ever write to again; that platform
//! has to notice `.delete`/`.rename` and re-arm onto the new inode, which is
//! what `reloadNeedsRearm` is for. `ReadDirectoryChangesW` reports changes by
//! NAME within a directory, so the replacement arrives as an ordinary
//! notification for the same basename and there is nothing to re-arm. The
//! Windows equivalent of the Mac re-arm logic is its absence.
//!
//! The thread only ever decides "did the watched name change"; the debounce and
//! the re-render both live on the GUI thread (`ViewerPane.wndProc`), because a
//! render has to happen where the browser lives. All this end does is post.

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");

const log = std.log.scoped(.viewer_watcher);

/// Bytes of change records the kernel may hand back per read. A save produces a
/// handful of ~30-byte records, so this is generous; the overflow case (the
/// kernel dropping the detail and returning zero bytes) is handled anyway,
/// because a buffer big enough for every burst does not exist.
const buffer_bytes = 16 * 1024;

/// What counts as a change to a document. `FILE_NAME` is the atomic-save case
/// (the rename that replaces the file), the other three are the in-place ones.
const notify_filter: u32 =
    w32.FILE_NOTIFY_CHANGE_FILE_NAME |
    w32.FILE_NOTIFY_CHANGE_SIZE |
    w32.FILE_NOTIFY_CHANGE_LAST_WRITE |
    w32.FILE_NOTIFY_CHANGE_CREATION;

/// `FILE_NOTIFY_INFORMATION`'s three leading `DWORD`s: `NextEntryOffset`,
/// `Action`, `FileNameLength` (in BYTES), then `FileName` as UTF-16.
const header_bytes = 12;

pub const Watcher = struct {
    /// Set for exactly as long as the watcher owns `name`.
    alloc: ?Allocator = null,

    /// The watched file's directory, open for change notifications.
    dir: ?w32.HANDLE = null,

    /// Signalled by `stop` so a thread parked in `WaitForMultipleObjects`
    /// leaves. Manual-reset: the thread must see it however late it looks.
    stop_event: ?w32.HANDLE = null,

    /// The overlapped read's completion event.
    io_event: ?w32.HANDLE = null,

    thread: ?std.Thread = null,

    /// The watched file's basename in UTF-16, which is what the notification
    /// records carry. Owned.
    name: []u16 = &.{},

    /// Where to post when the file changes. The viewer pane's host window.
    hwnd: ?w32.HWND = null,
    message: u32 = 0,

    pub fn isRunning(self: *const Watcher) bool {
        return self.thread != null;
    }

    /// Watch `path` and post `message` to `hwnd` whenever it changes.
    ///
    /// Non-fatal in every failure mode, and deliberately so: a viewer whose
    /// watcher could not start still shows the document and still reloads on
    /// `+reload`. Losing live reload is a degradation; failing the open over it
    /// would be a regression.
    ///
    /// Re-arming is just calling this again — it stops any previous watch
    /// first, so a pane that navigates from one file to another never ends up
    /// watching both.
    pub fn start(
        self: *Watcher,
        alloc: Allocator,
        hwnd: w32.HWND,
        message: u32,
        path: []const u8,
    ) void {
        self.stop();

        const dir_path = std.fs.path.dirname(path) orelse {
            log.warn("viewer file has no directory to watch: {s}", .{path});
            return;
        };
        const base = std.fs.path.basename(path);
        if (dir_path.len == 0 or base.len == 0) return;

        const dir_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, dir_path) catch return;
        defer alloc.free(dir_w);
        // No sentinel: the name is only ever COMPARED against the notification
        // records, never passed to an API, and a `[:0]u16` stored in a `[]u16`
        // field would be freed one element short of its allocation.
        const name_w = std.unicode.utf8ToUtf16LeAlloc(alloc, base) catch return;

        // Every share flag: the point of watching a file is that OTHER
        // processes write to it, and an editor that cannot replace the file
        // because the viewer is holding it would be a far worse bug than no
        // live reload. `DELETE` is the one that makes atomic saves work.
        const dir = w32.CreateFileW(
            dir_w,
            w32.FILE_LIST_DIRECTORY,
            w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE | w32.FILE_SHARE_DELETE,
            null,
            w32.OPEN_EXISTING,
            w32.FILE_FLAG_BACKUP_SEMANTICS | w32.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (dir == w32.INVALID_HANDLE_VALUE) {
            log.warn("cannot watch {s}: directory did not open", .{dir_path});
            alloc.free(name_w);
            return;
        }

        const io_event = w32.CreateEventW(null, 1, 0, null) orelse {
            alloc.free(name_w);
            _ = w32.CloseHandle(dir);
            return;
        };
        const stop_event = w32.CreateEventW(null, 1, 0, null) orelse {
            alloc.free(name_w);
            _ = w32.CloseHandle(io_event);
            _ = w32.CloseHandle(dir);
            return;
        };

        self.* = .{
            .alloc = alloc,
            .dir = dir,
            .stop_event = stop_event,
            .io_event = io_event,
            .name = name_w,
            .hwnd = hwnd,
            .message = message,
        };

        // Spawned LAST, so the thread never reads a half-filled struct.
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            log.warn("viewer watcher thread did not start: {s}", .{@errorName(err)});
            self.stop();
            return;
        };
    }

    /// Stop watching and release everything. Idempotent, and safe on a watcher
    /// that never started — which is every web-mode pane.
    pub fn stop(self: *Watcher) void {
        if (self.stop_event) |e| _ = w32.SetEvent(e);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // Only after the join: the thread reads all three of these.
        if (self.dir) |h| _ = w32.CloseHandle(h);
        if (self.io_event) |h| _ = w32.CloseHandle(h);
        if (self.stop_event) |h| _ = w32.CloseHandle(h);
        if (self.alloc) |a| if (self.name.len > 0) a.free(self.name);
        self.* = .{};
    }

    fn run(self: *Watcher) void {
        const dir = self.dir orelse return;
        const io_event = self.io_event orelse return;
        const stop_event = self.stop_event orelse return;
        const hwnd = self.hwnd orelse return;

        // On the thread's own stack rather than in the struct: a 16 KiB field
        // would be carried by every viewer pane, including the web-mode ones
        // that never watch anything.
        var buf: [buffer_bytes]u8 align(4) = undefined;
        const handles = [_]w32.HANDLE{ io_event, stop_event };

        while (true) {
            var ov = std.mem.zeroes(w32.OVERLAPPED);
            ov.hEvent = io_event;
            _ = w32.ResetEvent(io_event);

            if (w32.ReadDirectoryChangesW(
                dir,
                &buf,
                buf.len,
                0, // this directory only; a document has no subtree
                notify_filter,
                null,
                &ov,
                null,
            ) == 0) {
                log.warn("ReadDirectoryChangesW failed; live reload is off for this pane", .{});
                return;
            }

            const which = w32.WaitForMultipleObjects(2, &handles, 0, w32.INFINITE);
            if (which != w32.WAIT_OBJECT_0) {
                // Stopping, or a wait that failed outright. Either way the read
                // is still outstanding and it writes into a buffer that is about
                // to leave scope, so cancel it and WAIT for the cancellation to
                // land before returning.
                _ = w32.CancelIoEx(dir, &ov);
                var drained: u32 = 0;
                _ = w32.GetOverlappedResult(dir, &ov, &drained, 1);
                return;
            }

            var bytes: u32 = 0;
            if (w32.GetOverlappedResult(dir, &ov, &bytes, 0) == 0) return;

            // Zero bytes means the kernel's own buffer overflowed and it threw
            // the detail away. Reload rather than ask which file it was: a
            // spurious re-render costs a repaint, a missed one costs the
            // feature.
            if (bytes == 0 or mentions(buf[0..bytes], self.name)) {
                _ = w32.PostMessageW(hwnd, self.message, 0, 0);
            }
        }
    }
};

/// Does this batch of `FILE_NOTIFY_INFORMATION` records name `name`?
///
/// Reads every field with `readInt` rather than overlaying a struct: the record
/// stream is packed, the name that follows each header is 2-byte data at a
/// 12-byte offset, and an `@alignCast` on that is a promise this format does
/// not make. It also lets the test build a buffer out of plain bytes.
///
/// A malformed stream ends the walk instead of trusting it — a `NextEntryOffset`
/// that does not advance past its own header would otherwise loop forever.
pub fn mentions(buf: []const u8, name: []const u16) bool {
    var off: usize = 0;
    while (true) {
        if (buf.len < off + header_bytes) return false;
        const next: usize = std.mem.readInt(u32, buf[off..][0..4], .little);
        const name_bytes: usize = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
        const start = off + header_bytes;
        if (buf.len < start +| name_bytes) return false;
        if (nameEquals(buf[start..][0..name_bytes], name)) return true;
        if (next == 0 or next < header_bytes) return false;
        off +|= next;
    }
}

/// Compare a record's raw UTF-16 name against ours, case-insensitively.
///
/// ASCII folding only. NTFS's case-insensitivity uses a full Unicode table, but
/// the mismatch this has to survive is the one the CALLER creates — a
/// `README.md` opened as `readme.md` from the command line — and a notification
/// carries the name as stored on disk. Non-ASCII case differences would cost a
/// missed reload, never a wrong render.
fn nameEquals(raw: []const u8, name: []const u16) bool {
    if (raw.len != name.len * 2) return false;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
        if (foldAscii(c) != foldAscii(name[i])) return false;
    }
    return true;
}

fn foldAscii(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// Build one `FILE_NOTIFY_INFORMATION` record into `out`, returning how many
/// bytes it used. `next` is written verbatim so a test can express a malformed
/// stream as easily as a well-formed one.
fn writeRecord(out: []u8, next: u32, action: u32, name: []const u8) usize {
    std.mem.writeInt(u32, out[0..4], next, .little);
    std.mem.writeInt(u32, out[4..8], action, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(name.len * 2), .little);
    for (name, 0..) |ch, i| {
        std.mem.writeInt(u16, out[header_bytes + i * 2 ..][0..2], ch, .little);
    }
    return header_bytes + name.len * 2;
}

test "mentions: the watched name, in any case, anywhere in the batch" {
    var buf: [256]u8 align(4) = undefined;
    const target = std.unicode.utf8ToUtf16LeStringLiteral("design.md");

    // A single record for our file.
    var used = writeRecord(&buf, 0, 3, "design.md");
    try testing.expect(mentions(buf[0..used], target));

    // The command line said `design.md`; the disk says `Design.MD`. That is
    // the mismatch the fold exists for.
    used = writeRecord(&buf, 0, 3, "Design.MD");
    try testing.expect(mentions(buf[0..used], target));

    // A save in the same directory that is not ours.
    used = writeRecord(&buf, 0, 3, "other.md");
    try testing.expect(!mentions(buf[0..used], target));

    // A prefix is not a match: `design.md.tmp` is the editor's scratch file,
    // and reloading on it would render a half-written document.
    used = writeRecord(&buf, 0, 3, "design.md.tmp");
    try testing.expect(!mentions(buf[0..used], target));
}

test "mentions: walks the chain, which is what an atomic save produces" {
    var buf: [256]u8 align(4) = undefined;

    const target = std.unicode.utf8ToUtf16LeStringLiteral("design.md");

    // The real shape of a temp-file-and-rename save: the scratch file appears,
    // then the rename lands on our name. Only the SECOND record is ours, so a
    // walk that stops at the first entry misses every atomic save there is.
    const first = header_bytes + "design.md~".len * 2;
    _ = writeRecord(&buf, @intCast(first), 1, "design.md~");
    const second = writeRecord(buf[first..], 0, 5, "design.md");
    try testing.expect(mentions(buf[0 .. first + second], target));

    // ...and a chain with no mention of us still terminates.
    const other = writeRecord(buf[first..], 0, 5, "notes.md");
    try testing.expect(!mentions(buf[0 .. first + other], target));
}

test "mentions: a malformed stream ends the walk instead of spinning" {
    var buf: [256]u8 align(4) = undefined;
    const target = std.unicode.utf8ToUtf16LeStringLiteral("design.md");

    // `NextEntryOffset` pointing at (or before) the record's own header is the
    // infinite loop. It has to terminate, and it has to say no.
    var used = writeRecord(&buf, 4, 1, "other.md");
    try testing.expect(!mentions(buf[0..used], target));

    // A name length that runs past the end of what the kernel returned.
    used = writeRecord(&buf, 0, 1, "other.md");
    std.mem.writeInt(u32, buf[8..12], 0xFFFF, .little);
    try testing.expect(!mentions(buf[0..used], target));

    // A truncated header.
    try testing.expect(!mentions(buf[0..8], target));
    try testing.expect(!mentions(buf[0..0], target));
}
