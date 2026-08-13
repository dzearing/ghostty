//! Off-UI-thread git for one diff viewer pane (T463; Mac's `ViewerDiffLoader`,
//! which does the same job on a `DispatchQueue`).
//!
//! The spec, the argv shaping and the output parsing are `viewer_diff.zig`,
//! which is pure and asserts in the none lane. What lives here is the part that
//! has to touch the OS: spawning `git`, reading untracked files off disk,
//! keeping both OFF the message loop, and posting a completion back to the
//! pane's host window.
//!
//! **Nothing here may run on the UI thread.** A listing is three to six process
//! spawns and a patch is one more, and the win32 viewer's message loop is the
//! same one the terminal next door draws on — a `git diff` on it is a visible
//! stall in a pane that has nothing to do with the viewer.
//!
//! ## Two requests, one worker
//!
//! A pane asks for two different things — the FILE LIST (eager, cheap even on a
//! thousand-file range) and ONE FILE'S PATCH (only when that file is opened) —
//! and they must not race each other into git. So there is exactly one worker
//! slot: a request arriving while one is out is remembered and re-issued from
//! the completion, which is also what keeps a live-refreshing status pane from
//! stacking spawns behind a slow repository.
//!
//! The same rule is what makes a stale answer harmless: only the newest request
//! of each kind survives, so a fast click-through of a file list never renders a
//! file the reader has already moved past.
const Probe = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const diff = @import("viewer_diff.zig");
const worktree = @import("viewer_worktree.zig");
const git_run = @import("git_run.zig");

const log = std.log.scoped(.viewer_diff);

/// Retained bytes of one file-list invocation. Past this the list is truncated
/// and says so — a repository whose `--name-status` runs to 16 MB is not a diff
/// anyone is reading, and the page caps its own row count long before this.
const listing_cap = 16 * 1024 * 1024;

/// Retained bytes of one file's patch. The page stops appending rows at 20 000
/// and offers a button, so anything past this is already beyond what it draws.
const patch_cap = 8 * 1024 * 1024;

/// An untracked file bigger than this is summarized rather than read: it is new
/// content, so "the diff" would be the whole file. Mac's `untrackedByteCap`.
const untracked_byte_cap = 2 * 1024 * 1024;

/// One entry in the file list, with its strings owned by the probe.
/// `viewer_diff.File` is the same thing borrowed from git's output; this is the
/// copy that outlives it.
pub const Entry = struct {
    path: []u8,
    old_path: ?[]u8 = null,
    status: diff.Status,
    origin: diff.Origin,
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,

    pub fn view(self: *const Entry) diff.File {
        return .{
            .path = self.path,
            .old_path = self.old_path,
            .status = self.status,
            .origin = self.origin,
            .additions = self.additions,
            .deletions = self.deletions,
            .binary = self.binary,
        };
    }

    /// Same file, same side, same counts — what a live refresh compares to
    /// decide whether the page has anything to redraw.
    fn eql(self: Entry, other: Entry) bool {
        if (self.status != other.status or self.origin != other.origin) return false;
        if (self.additions != other.additions or self.deletions != other.deletions) return false;
        if (self.binary != other.binary) return false;
        if (!std.mem.eql(u8, self.path, other.path)) return false;
        const a = self.old_path orelse "";
        const b = other.old_path orelse "";
        return std.mem.eql(u8, a, b);
    }

    fn destroy(self: *Entry, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.old_path) |o| alloc.free(o);
    }
};

/// Why a listing produced nothing, with its one string owned.
pub const Failure = struct {
    kind: enum { no_directory, not_a_repository, no_default_base, git_failed },
    /// The directory or the revspec the message names. Owned; null for the
    /// two cases whose sentence needs no argument.
    arg: ?[]u8 = null,

    /// The pure `viewer_diff.Failure` this stands for, borrowing `arg`.
    pub fn view(self: *const Failure) diff.Failure {
        return switch (self.kind) {
            .no_directory => .no_directory,
            .not_a_repository => .{ .not_a_repository = self.arg orelse "" },
            .no_default_base => .no_default_base,
            .git_failed => .{ .git_failed = self.arg orelse "" },
        };
    }

    fn destroy(self: *Failure, alloc: Allocator) void {
        if (self.arg) |a| alloc.free(a);
    }
};

/// What a completion post is about.
pub const Completion = enum { none, listing, patch };

const Kind = enum { listing, patch };

/// Everything a worker owns for one request. Allocated by the requester, filled
/// by the worker, consumed and freed by the completion — so no field is ever
/// touched by two threads at once, and the thread `join` in `complete` is what
/// publishes the worker's writes.
const Job = struct {
    alloc: Allocator,
    kind: Kind,

    /// The diff location this answers, owned, so the spec can be re-parsed on
    /// the worker without sharing the pane's buffer.
    location: []u8,
    /// The pane's origin directory (listing jobs), owned.
    directory: ?[]u8 = null,
    /// The repository the patch job runs in, owned.
    repo: ?[]u8 = null,
    /// The file a patch job is for, owned.
    file: ?Entry = null,
    /// Where the page should land in that file: `first`, `last`, or null.
    scroll_to: ?[]const u8 = null,

    // --- filled by the worker -------------------------------------------
    out_repo: ?[]u8 = null,
    /// The range a bare `git-diff:` resolved to, owned, so the pane's spec
    /// stops being `.branch` once git has answered.
    out_range: ?[]u8 = null,
    out_files: std.ArrayList(Entry) = .empty,
    out_failure: ?Failure = null,
    out_patch: ?[]u8 = null,

    fn destroy(self: *Job) void {
        const alloc = self.alloc;
        alloc.free(self.location);
        if (self.directory) |d| alloc.free(d);
        if (self.repo) |r| alloc.free(r);
        if (self.file) |*f| f.destroy(alloc);
        if (self.out_repo) |r| alloc.free(r);
        if (self.out_range) |r| alloc.free(r);
        for (self.out_files.items) |*f| f.destroy(alloc);
        self.out_files.deinit(alloc);
        if (self.out_failure) |*f| f.destroy(alloc);
        if (self.out_patch) |p| alloc.free(p);
        alloc.destroy(self);
    }
};

alloc: Allocator,

/// Where a completion is posted. Null until the pane has a host window, which
/// is also every unit test — such a probe runs nothing.
hwnd: ?w32.HWND = null,
message: u32 = 0,

// --- published state, read by the pane on the GUI thread ------------------

/// The repository the current listing came from. Owned.
repo: ?[]u8 = null,
/// The resolved range a `.branch` spec stands for. Owned.
range: ?[]u8 = null,
/// The current file list. Owned.
files: std.ArrayList(Entry) = .empty,
/// Why there is no listing. Owned.
failure: ?Failure = null,
/// The patch the last patch job produced, and which file it belongs to.
/// Owned; null when that file is binary or git had nothing to say.
patch: ?[]u8 = null,
patch_path: ?[]u8 = null,

// --- request bookkeeping --------------------------------------------------

thread: ?std.Thread = null,
job: ?*Job = null,
/// A listing was asked for while a worker was out.
want_listing: bool = false,
/// A patch was asked for while a worker was out, by index into `files`.
want_patch: ?usize = null,
want_scroll: ?[]const u8 = null,

pub fn init(alloc: Allocator) Probe {
    return .{ .alloc = alloc };
}

/// Join any worker and drop everything. Safe from any state.
///
/// The join is not optional: the worker writes into a `Job` this then frees,
/// and a pane can be closed while git is still starting up.
pub fn deinit(self: *Probe) void {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    if (self.job) |j| {
        j.destroy();
        self.job = null;
    }
    self.clearListing();
    self.clearPatch();
}

/// Where completions are posted. Called once the pane has a host window.
pub fn attach(self: *Probe, hwnd: w32.HWND, message: u32) void {
    self.hwnd = hwnd;
    self.message = message;
}

fn clearListing(self: *Probe) void {
    if (self.repo) |r| self.alloc.free(r);
    if (self.range) |r| self.alloc.free(r);
    self.repo = null;
    self.range = null;
    // The whole list goes, backing array included — a completion REPLACES
    // `files` with the worker's own list, so keeping this one's capacity would
    // leak the array it is stored in on every refresh (measured: a
    // `git-status:` pane polls every two seconds).
    for (self.files.items) |*f| f.destroy(self.alloc);
    self.files.deinit(self.alloc);
    self.files = .empty;
    if (self.failure) |*f| f.destroy(self.alloc);
    self.failure = null;
}

fn clearPatch(self: *Probe) void {
    if (self.patch) |p| self.alloc.free(p);
    if (self.patch_path) |p| self.alloc.free(p);
    self.patch = null;
    self.patch_path = null;
}

/// The spec this probe last resolved a listing for, including the range a bare
/// `git-diff:` turned out to mean. Borrows from the probe.
pub fn resolvedSpec(self: *const Probe, location: []const u8) ?diff.Spec {
    const spec = diff.parse(location) orelse return null;
    if (spec.kind == .branch) {
        const range = self.range orelse return spec;
        return .{ .kind = .{ .range = range } };
    }
    return spec;
}

/// Re-run the file list for a pane at `location`, opened from `directory`.
pub fn requestListing(self: *Probe, location: []const u8, directory: ?[]const u8) void {
    if (self.thread != null) {
        self.want_listing = true;
        return;
    }
    self.startListing(location, directory);
}

/// Fetch one file's patch. `index` is into `files`, which only the GUI thread
/// mutates, so it cannot move under a caller between these two calls.
pub fn requestPatch(self: *Probe, location: []const u8, index: usize, scroll_to: ?[]const u8) void {
    if (index >= self.files.items.len) return;
    if (self.thread != null) {
        self.want_patch = index;
        self.want_scroll = scroll_to;
        return;
    }
    self.startPatch(location, index, scroll_to);
}

fn startListing(self: *Probe, location: []const u8, directory: ?[]const u8) void {
    // No window is no completion, and a worker whose answer nothing can collect
    // is a process spawn nobody asked for. This is also every unit test.
    if (self.hwnd == null) return;
    const job = self.alloc.create(Job) catch return;
    job.* = .{
        .alloc = self.alloc,
        .kind = .listing,
        .location = self.alloc.dupe(u8, location) catch {
            self.alloc.destroy(job);
            return;
        },
    };
    if (directory) |d| {
        job.directory = self.alloc.dupe(u8, d) catch null;
    }
    self.spawn(job);
}

fn startPatch(self: *Probe, location: []const u8, index: usize, scroll_to: ?[]const u8) void {
    if (self.hwnd == null) return;
    const repo = self.repo orelse return;
    const entry = self.files.items[index];
    const job = self.alloc.create(Job) catch return;
    job.* = .{
        .alloc = self.alloc,
        .kind = .patch,
        .location = self.alloc.dupe(u8, location) catch {
            self.alloc.destroy(job);
            return;
        },
        .scroll_to = scroll_to,
    };
    job.repo = self.alloc.dupe(u8, repo) catch null;
    const path = self.alloc.dupe(u8, entry.path) catch {
        job.destroy();
        return;
    };
    job.file = .{
        .path = path,
        .old_path = if (entry.old_path) |o| (self.alloc.dupe(u8, o) catch null) else null,
        .status = entry.status,
        .origin = entry.origin,
        .additions = entry.additions,
        .deletions = entry.deletions,
        .binary = entry.binary,
    };
    // A `.branch` spec has already been resolved by the listing that produced
    // this file; carry that answer over so the patch runs the same range.
    if (self.range) |r| job.out_range = self.alloc.dupe(u8, r) catch null;
    self.spawn(job);
}

fn spawn(self: *Probe, job: *Job) void {
    self.job = job;
    self.thread = std.Thread.spawn(.{}, work, .{ self, job }) catch |err| {
        log.warn("diff worker thread failed err={}; pane will not render", .{err});
        job.destroy();
        self.job = null;
        return;
    };
}

/// The completion post landed on the GUI thread: take the worker's answer and
/// say what it was about, so the pane knows which page call to make.
pub fn complete(self: *Probe) Completion {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    var what: Completion = .none;
    if (self.job) |job| {
        self.job = null;
        switch (job.kind) {
            .listing => {
                self.clearListing();
                self.repo = job.out_repo;
                job.out_repo = null;
                self.range = job.out_range;
                job.out_range = null;
                self.failure = job.out_failure;
                job.out_failure = null;
                // The entries move wholesale; the job's list is emptied so its
                // destructor does not free strings this now owns.
                self.files = job.out_files;
                job.out_files = .empty;
            },
            .patch => {
                self.clearPatch();
                self.patch = job.out_patch;
                job.out_patch = null;
                if (job.file) |f| self.patch_path = self.alloc.dupe(u8, f.path) catch null;
            },
        }
        what = if (job.kind == .listing) .listing else .patch;
        job.destroy();
    }
    return what;
}

/// A request that arrived while the worker was out, re-issued. Called by the
/// pane AFTER it has consumed the completion, so a deferred patch is fetched
/// against the file list this completion just published.
pub fn drainDeferred(self: *Probe, location: []const u8, directory: ?[]const u8) void {
    if (self.thread != null) return;
    if (self.want_listing) {
        self.want_listing = false;
        self.startListing(location, directory);
        return;
    }
    if (self.want_patch) |index| {
        const scroll = self.want_scroll;
        self.want_patch = null;
        self.want_scroll = null;
        if (index < self.files.items.len) self.startPatch(location, index, scroll);
    }
}

/// True while the answer to something is still coming.
pub fn busy(self: *const Probe) bool {
    return self.thread != null;
}

/// Whether `files` differs from `previous` — what a live refresh asks before
/// redrawing, so a `git-status:` pane polling every two seconds does not
/// re-render (and re-scroll) a diff nobody changed.
pub fn listingDiffers(self: *const Probe, previous: []const Entry) bool {
    if (self.files.items.len != previous.len) return true;
    for (self.files.items, previous) |a, b| {
        if (!a.eql(b)) return true;
    }
    return false;
}

/// A snapshot of the current file list, owned by the caller, for that compare.
pub fn snapshot(self: *Probe, alloc: Allocator) []Entry {
    const out = alloc.alloc(Entry, self.files.items.len) catch return &.{};
    var n: usize = 0;
    for (self.files.items) |f| {
        out[n] = .{
            .path = alloc.dupe(u8, f.path) catch break,
            .old_path = if (f.old_path) |o| (alloc.dupe(u8, o) catch null) else null,
            .status = f.status,
            .origin = f.origin,
            .additions = f.additions,
            .deletions = f.deletions,
            .binary = f.binary,
        };
        n += 1;
    }
    return out[0..n];
}

pub fn freeSnapshot(alloc: Allocator, entries: []Entry) void {
    for (entries) |*e| e.destroy(alloc);
    alloc.free(entries);
}

// -------------------------------------------------------------------------
// The worker
// -------------------------------------------------------------------------

fn work(self: *Probe, job: *Job) void {
    switch (job.kind) {
        .listing => workListing(job),
        .patch => workPatch(job),
    }
    if (self.hwnd) |h| {
        if (w32.PostMessageW(h, self.message, 0, 0) == 0) {
            log.debug("diff completion could not be posted", .{});
        }
    }
}

fn workListing(job: *Job) void {
    const alloc = job.alloc;
    const spec = diff.parse(job.location) orelse {
        job.out_failure = .{ .kind = .git_failed, .arg = alloc.dupe(u8, job.location) catch null };
        return;
    };

    const dir = job.directory orelse {
        job.out_failure = .{ .kind = .no_directory };
        return;
    };
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = repositoryRoot(alloc, dir, &root_buf) orelse {
        job.out_failure = .{ .kind = .not_a_repository, .arg = alloc.dupe(u8, dir) catch null };
        return;
    };
    job.out_repo = alloc.dupe(u8, repo) catch return;

    // A bare `git-diff:` names no base; ask git for one before anything else,
    // and say so rather than diffing against a ref that does not exist.
    var range_buf: [512]u8 = undefined;
    var resolved = spec;
    if (spec.kind == .branch) {
        const base = defaultBase(alloc, repo) orelse {
            job.out_failure = .{ .kind = .no_default_base };
            return;
        };
        defer alloc.free(base);
        resolved = spec.resolved(&range_buf, base);
        if (resolved.kind == .range) {
            job.out_range = alloc.dupe(u8, resolved.kind.range) catch null;
        }
    }

    var any_succeeded = false;
    for (diff.origins(resolved)) |origin| {
        const name_status = diff.nameStatusArgv(resolved, origin, git_binary, repo) orelse continue;
        const listed = git_run.captureAlloc(alloc, name_status.slice(), listing_cap) orelse continue;
        defer alloc.free(listed.bytes);
        // A non-zero exit is git REFUSING, not an empty diff — a bad revspec
        // prints nothing and fails, and rendering that as "no changes" is the
        // swallowed error this whole path exists to report.
        if (!listed.ok) continue;
        any_succeeded = true;

        if (origin == .untracked) {
            appendUntracked(job, repo, listed.bytes);
            continue;
        }

        var counts_bytes: ?[]u8 = null;
        defer if (counts_bytes) |c| alloc.free(c);
        if (diff.numstatArgv(resolved, origin, git_binary, repo)) |numstat| {
            if (git_run.captureAlloc(alloc, numstat.slice(), listing_cap)) |counts| {
                if (counts.ok) counts_bytes = counts.bytes else alloc.free(counts.bytes);
            }
        }

        var it = diff.nameStatus(listed.bytes);
        while (it.next()) |entry| {
            var e: Entry = .{
                .path = alloc.dupe(u8, entry.path) catch continue,
                .old_path = if (entry.old_path) |o| (alloc.dupe(u8, o) catch null) else null,
                .status = entry.status,
                .origin = origin,
            };
            if (counts_bytes) |c| {
                var counts = diff.numstat(c);
                while (counts.next()) |lc| {
                    if (!std.mem.eql(u8, lc.path, entry.path)) continue;
                    e.additions = lc.additions;
                    e.deletions = lc.deletions;
                    e.binary = lc.binary;
                    break;
                }
            }
            job.out_files.append(alloc, e) catch {
                e.destroy(alloc);
                break;
            };
        }
    }

    if (!any_succeeded) {
        var loc_buf: [256]u8 = undefined;
        const named = resolved.canonicalLocation(&loc_buf) orelse job.location;
        job.out_failure = .{ .kind = .git_failed, .arg = alloc.dupe(u8, named) catch null };
        if (job.out_repo) |r| {
            alloc.free(r);
            job.out_repo = null;
        }
    }
}

/// One untracked file's entry. Every line is an addition, so the count is the
/// file's own line count — cheap to read, and capped so a stray gigabyte in the
/// working tree cannot stall the list.
fn appendUntracked(job: *Job, repo: []const u8, listed: []const u8) void {
    const alloc = job.alloc;
    var it = diff.fields(listed);
    while (it.next()) |path| {
        if (path.len == 0) continue;
        var e: Entry = .{
            .path = alloc.dupe(u8, path) catch continue,
            .status = .added,
            .origin = .untracked,
            // Anything unreadable is shown as a stub, which is also the honest
            // answer for a file too big to count.
            .binary = true,
        };
        if (readUntracked(alloc, repo, path)) |bytes| {
            defer alloc.free(bytes);
            const head = bytes[0..@min(bytes.len, 8000)];
            if (std.mem.indexOfScalar(u8, head, 0) == null) {
                e.binary = false;
                var lines: u32 = 0;
                for (bytes) |c| {
                    if (c == '\n') lines += 1;
                }
                // A last line with no trailing newline still counts.
                if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') lines += 1;
                e.additions = lines;
            }
        }
        job.out_files.append(alloc, e) catch {
            e.destroy(alloc);
            break;
        };
    }
}

fn readUntracked(alloc: Allocator, repo: []const u8, path: []const u8) ?[]u8 {
    const joined = std.fs.path.join(alloc, &.{ repo, path }) catch return null;
    defer alloc.free(joined);
    return std.fs.cwd().readFileAlloc(alloc, joined, untracked_byte_cap) catch null;
}

fn workPatch(job: *Job) void {
    const alloc = job.alloc;
    const file = job.file orelse return;
    const repo = job.repo orelse return;
    const parsed = diff.parse(job.location) orelse return;
    const spec: diff.Spec = if (job.out_range) |r| .{ .kind = .{ .range = r } } else parsed;

    // An untracked file has no other side for git to diff against, so its patch
    // is synthesized as an all-added file — the page then treats it exactly like
    // any other addition instead of needing a second code path.
    if (file.origin == .untracked) {
        job.out_patch = syntheticAddPatch(alloc, repo, file);
        return;
    }
    const argv = diff.patchArgv(spec, file.view(), git_binary, repo) orelse return;
    const out = git_run.captureAlloc(alloc, argv.slice(), patch_cap) orelse return;
    if (!out.ok) {
        alloc.free(out.bytes);
        return;
    }
    job.out_patch = out.bytes;
}

fn syntheticAddPatch(alloc: Allocator, repo: []const u8, file: Entry) ?[]u8 {
    if (file.binary) return null;
    const bytes = readUntracked(alloc, repo, file.path) orelse return null;
    defer alloc.free(bytes);

    var text = bytes;
    const ends_with_newline = text.len > 0 and text[text.len - 1] == '\n';
    if (ends_with_newline) text = text[0 .. text.len - 1];

    var lines: usize = if (text.len == 0) 0 else 1;
    for (text) |c| {
        if (c == '\n') lines += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    out.print(alloc,
        \\diff --git a/{s} b/{s}
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/{s}
        \\@@ -0,0 +1,{d} @@
        \\
    , .{ file.path, file.path, file.path, lines }) catch return null;

    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (text.len == 0 and first) break;
        out.append(alloc, '+') catch return null;
        // The line's bytes as they are on disk, a CR included: that is what git
        // itself would emit for a CRLF file, and the page renders both alike.
        out.appendSlice(alloc, line) catch return null;
        out.append(alloc, '\n') catch return null;
        first = false;
    }
    if (!ends_with_newline and text.len > 0) {
        out.appendSlice(alloc, "\\ No newline at end of file\n") catch return null;
    }
    return out.toOwnedSlice(alloc) catch null;
}

// -------------------------------------------------------------------------
// git
// -------------------------------------------------------------------------

/// The binary every invocation here names. A diff pane runs several commands
/// per refresh, so the PATH walk `viewer_worktree` does for the root query is
/// paid once, there, and everything after it uses the plain name — which is
/// what actually ran when the root query succeeded.
const git_binary = worktree.git_paths[0];

/// The top-level directory of the working tree containing `dir`, into `buf`;
/// null when it is not in one. BLOCKING — worker thread only.
fn repositoryRoot(alloc: Allocator, dir: []const u8, buf: []u8) ?[]const u8 {
    if (!worktree.realDirExists(dir)) return null;
    for (worktree.git_paths, 0..) |_, i| {
        const argv = worktree.rootArgv(i, dir);
        var out_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const out = git_run.capture(alloc, &argv, &out_buf) orelse continue;
        return worktree.parseRoot(buf, out);
    }
    return null;
}

/// The base a bare `git-diff:` compares the current branch against, owned by
/// the caller. Ordered by what a human means by "the mainline": the remote's
/// declared default branch, then the usual names. Null in a repo with none of
/// them, so the caller can SAY so.
fn defaultBase(alloc: Allocator, repo: []const u8) ?[]u8 {
    var buf: [1024]u8 = undefined;
    {
        const argv = diff.symbolicRefArgv(git_binary, repo);
        if (git_run.capture(alloc, argv.slice(), &buf)) |out| {
            if (diff.parseSymbolicRef(out)) |ref| return alloc.dupe(u8, ref) catch null;
        }
    }
    for (diff.default_base_candidates) |candidate| {
        const argv = diff.verifyRefArgv(git_binary, repo, candidate);
        const out = git_run.captureAlloc(alloc, argv.slice(), 1024) orelse continue;
        defer alloc.free(out.bytes);
        // `--verify --quiet` prints the sha and exits 0 only when the ref
        // exists; an unknown ref is a silent non-zero, which is the answer.
        if (out.ok and std.mem.trim(u8, out.bytes, " \t\r\n").len > 0) {
            return alloc.dupe(u8, candidate) catch null;
        }
    }
    return null;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a probe with no window resolves nothing and frees cleanly" {
    var p = Probe.init(testing.allocator);
    defer p.deinit();
    p.requestListing("git-status:", "D:\\git\\ghoztty");
    try testing.expect(!p.busy());
    try testing.expectEqual(Completion.none, p.complete());
}

test "the file list of this repository's own working tree" {
    if (!worktree.realDirExists("D:\\git\\ghoztty")) return error.SkipZigTest;
    var p = Probe.init(testing.allocator);
    defer p.deinit();
    // No window: drive the worker directly, which is what `work` does minus the
    // post. That is the whole impure surface worth asserting here.
    const job = try testing.allocator.create(Job);
    job.* = .{
        .alloc = testing.allocator,
        .kind = .listing,
        .location = try testing.allocator.dupe(u8, "git-status:"),
        .directory = try testing.allocator.dupe(u8, "D:\\git\\ghoztty\\src"),
    };
    defer job.destroy();
    workListing(job);

    // The repo root is the checkout, not the subdirectory it was asked about.
    try testing.expect(job.out_failure == null);
    try testing.expectEqualStrings("D:\\git\\ghoztty", job.out_repo.?);
}

test "a directory in no repository is a named failure, not an empty diff" {
    const tmp = std.process.getEnvVarOwned(testing.allocator, "TEMP") catch
        return error.SkipZigTest;
    defer testing.allocator.free(tmp);
    if (!worktree.realDirExists(tmp)) return error.SkipZigTest;

    const job = try testing.allocator.create(Job);
    job.* = .{
        .alloc = testing.allocator,
        .kind = .listing,
        .location = try testing.allocator.dupe(u8, "git-status:"),
        .directory = try testing.allocator.dupe(u8, tmp),
    };
    defer job.destroy();
    workListing(job);
    try testing.expectEqual(@as(?[]u8, null), job.out_repo);
    try testing.expect(job.out_failure != null);
    try testing.expectEqualStrings("Not a git repository", job.out_failure.?.view().title());
}

test "a bad revspec fails loudly instead of rendering as no changes" {
    if (!worktree.realDirExists("D:\\git\\ghoztty")) return error.SkipZigTest;
    const job = try testing.allocator.create(Job);
    job.* = .{
        .alloc = testing.allocator,
        .kind = .listing,
        .location = try testing.allocator.dupe(u8, "git-diff:no-such-ref-here..HEAD"),
        .directory = try testing.allocator.dupe(u8, "D:\\git\\ghoztty"),
    };
    defer job.destroy();
    workListing(job);
    try testing.expect(job.out_failure != null);
    try testing.expectEqual(
        @as([]const u8, "git could not produce this diff"),
        job.out_failure.?.view().title(),
    );
}

test "a synthesized untracked patch reads as an all-added file" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "new.txt", .data = "alpha\nbeta\n" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const new_path = try alloc.dupe(u8, "new.txt");
    defer alloc.free(new_path);
    const patch = syntheticAddPatch(alloc, root, .{
        .path = new_path,
        .status = .added,
        .origin = .untracked,
    }).?;
    defer alloc.free(patch);
    try testing.expectEqualStrings(
        "diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n" ++
            "+++ b/new.txt\n@@ -0,0 +1,2 @@\n+alpha\n+beta\n",
        patch,
    );

    // A file with no trailing newline says so, exactly as git would.
    try tmp.dir.writeFile(.{ .sub_path = "tail.txt", .data = "only" });
    const tail_path = try alloc.dupe(u8, "tail.txt");
    defer alloc.free(tail_path);
    const tail = syntheticAddPatch(alloc, root, .{
        .path = tail_path,
        .status = .added,
        .origin = .untracked,
    }).?;
    defer alloc.free(tail);
    try testing.expect(std.mem.endsWith(u8, tail, "+only\n\\ No newline at end of file\n"));
}
