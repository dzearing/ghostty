//! Filing one feedback report, off the UI thread (T636; Mac's
//! `ViewerView.writeFeedback`, which does the same job on a
//! `DispatchQueue.global`).
//!
//! The FORMAT, the source-line resolver and the staging+rename publish are
//! `viewer_feedback_report.zig`, which is pure and asserts in the none lane.
//! What lives here is the part that has to touch the OS: two `git rev-parse`
//! spawns, reading the source file, writing the folder, and posting a
//! completion back to the pane's host window.
//!
//! ## Why a worker at all, for one click
//!
//! Sending is user-initiated and the report is a few kilobytes, so the write
//! itself would be unnoticeable. The REVISION is not: `git rev-parse` is a
//! process spawn, and the viewer's message loop is the same one the terminal
//! next door draws on — the rule `ViewerWorktreeProbe` states ("the git call
//! must never run on the UI thread") is about which loop is blocked, not about
//! how often. Reading the quoted file is the same argument with a size on it: a
//! multi-megabyte document is a real read.
//!
//! ## Why the revision is resolved HERE and not on the worktree probe
//!
//! The probe answers "which repo is this pane's content in", and it caches that
//! for 15 seconds because it is asked on every navigation. A revision cached
//! the same way would be as old as the pane: a viewer left open all day, with
//! branches switched under it, would file a report naming the branch it was
//! opened on. `worktree.path` is a fact about the pane; `branch`/`commit` are
//! facts about the MOMENT the user pressed send, and Mac resolves them at send
//! time for exactly that reason. So the argv+parse halves live in the pure
//! `viewer_worktree.zig` beside the root query (where they assert without a
//! process), and the CALL is here.
const Sender = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const worktree = @import("viewer_worktree.zig");
const git_run = @import("git_run.zig");
const report = @import("viewer_feedback_report.zig");

const log = std.log.scoped(.viewer_feedback);

/// Bytes of a source file read to resolve `sourceLine`. A viewer can be
/// pointed at anything, and a report is not worth paging in a gigabyte —
/// past this the quotes simply have no line number, which is a state the
/// format already allows.
const source_cap = 8 * 1024 * 1024;

/// Stdout accepted from `git rev-parse`. It prints one short line; anything
/// longer is not an answer this understands.
const git_stdout_cap = 512;

/// The longest confirmation/failure line kept for the composer's footer.
const status_cap = 160;

/// Everything one send owns. Allocated by `begin`, filled by the worker,
/// consumed and freed by `complete` — so no field is touched by two threads at
/// once, and the thread `join` in `complete` is what publishes the worker's
/// writes.
///
/// One arena holds every string, including the ones the worker allocates, so
/// the whole job is freed by dropping it — a send has no partial-cleanup path.
const Job = struct {
    arena: std.heap.ArenaAllocator,
    ctx: report.Context,
    body: []const u8,
    quotes: []report.Quote,
    images: []report.Image,
    epoch_secs: u64,
    suffix: u24,
    /// The composer's own draft folder, empty when the caller has none and the
    /// worker should mint a fresh stem.
    draft_stem: []const u8 = "",

    /// Filled by the worker.
    ok: bool = false,
    stem: []const u8 = "",
    err_name: []const u8 = "",

    fn destroy(self: *Job, alloc: Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

/// What the caller hands `begin`. Every slice is COPIED into the job's arena,
/// so the caller may free or overwrite its own buffers the moment `begin`
/// returns — which matters because the composer's text is exactly the thing
/// the user keeps typing into.
pub const Request = struct {
    worktree_path: []const u8,
    worktree_name: []const u8,
    location: []const u8,
    /// `"file"` or `"web"`.
    kind: []const u8,
    file_path: ?[]const u8 = null,
    page_title: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    pane_id: ?[]const u8 = null,
    viewport: ?[]const u8 = null,
    app_version: ?[]const u8 = null,
    /// The rendered markdown body.
    body: []const u8,
    /// The live quotes, WITHOUT `source_line` — the worker resolves that
    /// against the file.
    quotes: []const report.Quote,
    /// The live images, PNG-encoded. Copied like everything else here: the
    /// composer's store is the user's to keep editing while the write is out.
    images: []const report.Image = &.{},
    epoch_secs: u64,
    suffix: u24,
    /// The stem of the folder the composer has been drafting into (T645), so
    /// the publish carries any file the user dropped in there. Null for a
    /// caller with no draft behind it.
    draft_stem: ?[]const u8 = null,
};

/// What `complete` hands back. `text` is the line the composer's footer shows,
/// borrowed from the sender and valid until the next `begin`.
pub const Result = struct {
    ok: bool,
    text: []const u8,
    /// The published folder's name, empty on failure.
    stem: []const u8,
};

alloc: Allocator,

/// Where a completion is posted. Null until the pane has a host window, which
/// is also every unit test — such a sender refuses to start, since a send
/// nobody can be told about is a send that would silently strand the composer.
hwnd: ?w32.HWND = null,
message: u32 = 0,

thread: ?std.Thread = null,
job: ?*Job = null,

/// The last result's text and stem, copied out of the job before it is freed.
status_buf: [status_cap]u8 = undefined,
status_len: usize = 0,
stem_buf: [report.stem_len]u8 = undefined,
stem_len: usize = 0,

pub fn init(alloc: Allocator) Sender {
    return .{ .alloc = alloc };
}

/// Join any worker and drop everything. Safe from any state.
///
/// The join is not optional: the worker writes into a `Job` this then frees,
/// and a pane can be closed while `git` is still starting up. A queued
/// completion post is harmless — it is delivered to a window that is about to
/// be destroyed, and destroyed windows drop their posted messages.
pub fn deinit(self: *Sender) void {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    if (self.job) |j| {
        j.destroy(self.alloc);
        self.job = null;
    }
}

/// Where completions are posted. Called once the pane has a host window.
pub fn attach(self: *Sender, hwnd: w32.HWND, message: u32) void {
    self.hwnd = hwnd;
    self.message = message;
}

/// True while a send is out. A second press of `↑` must not file the report
/// twice, and the composer is not cleared until the first one lands.
pub fn busy(self: *const Sender) bool {
    return self.thread != null;
}

/// Start a send. False when one is already out, when there is nowhere to post
/// the completion, or when the job could not be built — in every case nothing
/// was written and the composer keeps its text.
pub fn begin(self: *Sender, req: Request) bool {
    if (self.thread != null) return false;
    if (self.hwnd == null) return false;

    const job = self.alloc.create(Job) catch return false;
    job.* = .{
        .arena = .init(self.alloc),
        .ctx = .{ .location = "", .kind = "", .worktree_path = "", .worktree_name = "" },
        .body = "",
        .quotes = &.{},
        .images = &.{},
        .epoch_secs = req.epoch_secs,
        .suffix = req.suffix,
    };

    fill(job, req) catch {
        job.destroy(self.alloc);
        return false;
    };

    self.job = job;
    self.thread = std.Thread.spawn(.{}, work, .{ self, job }) catch |err| {
        log.warn("feedback send thread failed err={}", .{err});
        self.job = null;
        job.destroy(self.alloc);
        return false;
    };
    return true;
}

/// Copy the request into the job's arena. Everything or nothing: a job that
/// could not be built is destroyed whole by `begin`, so there is no half-copied
/// state for the worker to read.
fn fill(job: *Job, req: Request) !void {
    const aa = job.arena.allocator();
    job.body = try aa.dupe(u8, req.body);
    if (req.draft_stem) |stem| job.draft_stem = try aa.dupe(u8, stem);
    job.ctx = .{
        .location = try aa.dupe(u8, req.location),
        .kind = try aa.dupe(u8, req.kind),
        .file_path = try dupeOpt(aa, req.file_path),
        .page_title = try dupeOpt(aa, req.page_title),
        .selection = try dupeOpt(aa, req.selection),
        .pane_id = try dupeOpt(aa, req.pane_id),
        .viewport = try dupeOpt(aa, req.viewport),
        .app_version = try dupeOpt(aa, req.app_version),
        .worktree_path = try aa.dupe(u8, req.worktree_path),
        .worktree_name = try aa.dupe(u8, req.worktree_name),
    };
    // Repo-relative, `/`-separated: the form a coding agent wants, derived here
    // rather than asked of the caller so there is one derivation of it.
    if (job.ctx.file_path) |p| {
        const buf = try aa.alloc(u8, p.len);
        job.ctx.relative_path = report.relativePath(buf, p, job.ctx.worktree_path);
    }

    const quotes = try aa.alloc(report.Quote, req.quotes.len);
    for (req.quotes, 0..) |q, i| {
        quotes[i] = .{
            .number = q.number,
            .text = try aa.dupe(u8, q.text),
            .heading_id = try dupeOpt(aa, q.heading_id),
            .heading_text = try dupeOpt(aa, q.heading_text),
            .block_selector = try dupeOpt(aa, q.block_selector),
            .block_text = try dupeOpt(aa, q.block_text),
            .offset_in_block = q.offset_in_block,
            .document_offset = q.document_offset,
        };
    }
    job.quotes = quotes;

    const images = try aa.alloc(report.Image, req.images.len);
    for (req.images, 0..) |img, i| {
        images[i] = .{
            .number = img.number,
            .png = try aa.dupe(u8, img.png),
            .pixel_width = img.pixel_width,
            .pixel_height = img.pixel_height,
        };
    }
    job.images = images;
}

fn dupeOpt(alloc: Allocator, value: ?[]const u8) !?[]const u8 {
    const v = value orelse return null;
    return try alloc.dupe(u8, v);
}

/// The worker: revision, source lines, write, post. Runs on its own thread and
/// touches nothing on the sender but the two handles it was attached with
/// (which are set before any worker can exist and never change).
fn work(self: *Sender, job: *Job) void {
    const aa = job.arena.allocator();
    job.ctx.branch = revision(aa, job.ctx.worktree_path, .branch);
    job.ctx.commit = revision(aa, job.ctx.worktree_path, .commit);
    resolveSourceLines(aa, job);

    if (report.write(
        aa,
        job.ctx,
        job.body,
        job.quotes,
        job.images,
        job.epoch_secs,
        job.suffix,
        if (job.draft_stem.len != 0) job.draft_stem else null,
    )) |written| {
        job.ok = true;
        job.stem = written.stem;
    } else |err| {
        job.err_name = @errorName(err);
    }

    if (self.hwnd) |h| {
        if (w32.PostMessageW(h, self.message, 0, 0) == 0) {
            log.debug("feedback completion could not be posted", .{});
        }
    }
}

const Which = enum { branch, commit };

/// One `git rev-parse` against the worktree root, duped into `alloc`. Null for
/// every state that is not an answer — no git, a detached HEAD, an unborn
/// repository — because the report says so rather than guessing. BLOCKING.
fn revision(alloc: Allocator, root: []const u8, which: Which) ?[]const u8 {
    for (worktree.git_paths, 0..) |_, i| {
        var buf: [git_stdout_cap]u8 = undefined;
        const out = switch (which) {
            .branch => blk: {
                const argv = worktree.branchArgv(i, root);
                break :blk git_run.capture(alloc, &argv, &buf);
            },
            .commit => blk: {
                const argv = worktree.commitArgv(i, root);
                break :blk git_run.capture(alloc, &argv, &buf);
            },
            // A git that could not be LAUNCHED is the only case worth trying
            // the next candidate path for; one that ran has answered.
        } orelse continue;
        const parsed = switch (which) {
            .branch => worktree.parseBranch(out),
            .commit => worktree.parseCommit(out),
        } orelse return null;
        return alloc.dupe(u8, parsed) catch null;
    }
    return null;
}

/// Locate each quote in the SOURCE file. Mapping the rendered DOM back to
/// markdown source is unreliable; searching the file for the passage is not,
/// and a line number is what a reader actually wants. A web pane has no source
/// file, so its quotes keep the null they arrived with. BLOCKING.
fn resolveSourceLines(alloc: Allocator, job: *Job) void {
    if (job.quotes.len == 0) return;
    const path = job.ctx.file_path orelse return;
    const source = std.fs.cwd().readFileAlloc(alloc, path, source_cap) catch |err| {
        log.debug("feedback source read failed path={s} err={}", .{ path, err });
        return;
    };
    for (job.quotes) |*q| q.source_line = report.sourceLine(alloc, source, q.text);
}

/// The completion post landed on the GUI thread: take the worker's answer and
/// say what to tell the user. Null when there was no send to complete.
pub fn complete(self: *Sender) ?Result {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    const job = self.job orelse return null;
    self.job = null;
    defer job.destroy(self.alloc);

    self.stem_len = 0;
    if (job.ok) {
        // Mac's "Filed …": the confirmation names the folder, so a user who
        // wants to look at what they just sent has its name on screen.
        @memcpy(self.stem_buf[0..job.stem.len], job.stem);
        self.stem_len = job.stem.len;
        self.setStatus("Filed {s}/{s}", .{ report.queue_relative_path, job.stem });
    } else {
        self.setStatus("Could not file this report ({s})", .{job.err_name});
    }
    return .{
        .ok = job.ok,
        .text = self.status_buf[0..self.status_len],
        .stem = self.stem_buf[0..self.stem_len],
    };
}

fn setStatus(self: *Sender, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&self.status_buf, fmt, args) catch blk: {
        // A destination too long to state in full still has to say what
        // happened, so the message degrades rather than disappearing.
        break :blk std.fmt.bufPrint(&self.status_buf, "Filed", .{}) catch unreachable;
    };
    self.status_len = written.len;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a sender with nowhere to post a completion refuses to start" {
    // Every unit-test pane is in this state. Starting anyway would file the
    // report and then strand the composer holding text that was already sent.
    var s = Sender.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.begin(.{
        .worktree_path = "D:\\repo",
        .worktree_name = "repo",
        .location = "D:\\repo\\a.md",
        .kind = "file",
        .body = "something",
        .quotes = &.{},
        .epoch_secs = 0,
        .suffix = 1,
    }));
    try testing.expect(!s.busy());
    try testing.expect(s.complete() == null);
}
