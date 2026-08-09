//! Off-UI-thread worktree resolution for one viewer pane (T633; Mac's
//! `ViewerWorktreeCache`, which does the same job on a `DispatchQueue`).
//!
//! The strategy, the cache and the parsing are `viewer_worktree.zig`, which is
//! pure and asserts in the none lane. What lives here is the part that has to
//! touch the OS: spawning `git`, keeping it OFF the message loop, and posting a
//! completion back to the pane's host window.
//!
//! **The git call must never run on the UI thread.** It is a process spawn on
//! every navigation, and the win32 viewer's message loop is the same one the
//! terminal draws on — a 30 ms `CreateProcess` on a back/forward walk is a
//! visible stutter in the pane next door. So the call site is the worker
//! (`work`), and the pane is repainted from the completion (`complete`), which
//! is the only function here the GUI thread runs that touches the answer.
//!
//! One worker at a time. A request arriving while one is in flight sets
//! `dirty` and is re-issued from the completion rather than racing a second
//! spawn — a pane can move three times in a second (a link, a redirect, a
//! back), and each move must not cost its own process.
const Probe = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const w32 = @import("win32.zig");
const worktree = @import("viewer_worktree.zig");

const log = std.log.scoped(.viewer_worktree);

/// Longest repo root this carries. `git rev-parse` cannot print a path the
/// filesystem could not hold, so this is a real bound rather than a guess.
const path_cap = std.fs.max_path_bytes;

/// Bytes of `git`'s stdout read before giving up. `--show-toplevel` prints one
/// path; anything larger is not an answer this understands.
const stdout_cap = path_cap + 64;

/// Everything a worker owns for one resolution. Allocated by the requester,
/// filled by the worker, consumed and freed by the completion — so no field is
/// ever touched by two threads at once, and the thread `join` in `complete` is
/// what publishes the worker's writes.
const Job = struct {
    alloc: Allocator,
    /// The cache key this answers (`location \0 origin`). Owned.
    key: []u8,
    /// The candidate directory git was asked about. Owned.
    dir: []u8,
    /// The resolved worktree root, written by the worker. Owned; null when the
    /// directory is in no repository at all.
    root: ?[]u8 = null,

    fn destroy(self: *Job) void {
        const alloc = self.alloc;
        alloc.free(self.key);
        alloc.free(self.dir);
        if (self.root) |r| alloc.free(r);
        alloc.destroy(self);
    }
};

alloc: Allocator,
cache: worktree.Cache,

/// Where a completion is posted. Null until the pane has a host window, which
/// is also every unit test — such a probe resolves nothing and answers "no
/// worktree", which is the honest answer for a pane with no window.
hwnd: ?w32.HWND = null,
message: u32 = 0,

/// The pane's currently-resolved worktree root, owned. Null means "no repo
/// here", which is what makes the feedback button absent.
current: ?[]u8 = null,

/// The last request, so a completion that finds `dirty` can re-issue without
/// the caller having to remember what it asked. Owned.
want_location: ?[]u8 = null,
want_origin: ?[]u8 = null,

thread: ?std.Thread = null,
job: ?*Job = null,
dirty: bool = false,

/// How the strategy's impure edges are reached. Overridden by tests; leg 2's
/// port lookup stays absent until T638 installs one.
strategy: worktree.Strategy = .{},

pub fn init(alloc: Allocator) Probe {
    return .{ .alloc = alloc, .cache = .{ .alloc = alloc } };
}

/// Join any worker and drop everything. Safe from any state.
///
/// The join is not optional: the worker writes into a `Job` this then frees,
/// and a pane can be closed while git is still starting up. A queued completion
/// post is harmless — it is delivered to a window that is about to be destroyed,
/// and destroyed windows drop their posted messages.
pub fn deinit(self: *Probe) void {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    if (self.job) |j| {
        j.destroy();
        self.job = null;
    }
    self.cache.deinit();
    if (self.current) |c| self.alloc.free(c);
    if (self.want_location) |l| self.alloc.free(l);
    if (self.want_origin) |o| self.alloc.free(o);
    self.current = null;
    self.want_location = null;
    self.want_origin = null;
}

/// Where completions are posted. Called once the pane has a host window.
pub fn attach(self: *Probe, hwnd: w32.HWND, message: u32) void {
    self.hwnd = hwnd;
    self.message = message;
}

/// The worktree the pane's content currently belongs to, or null. Borrowed —
/// valid until the next `refresh`/`complete` changes it.
pub fn worktreePath(self: *const Probe) ?[]const u8 {
    return self.current;
}

/// What a request or a completion did to `current`.
pub const Outcome = enum {
    /// A worker is out; the answer arrives on the completion message.
    pending,
    /// Settled, and the pane's worktree did not move.
    unchanged,
    /// Settled, and it did — the caller repaints.
    changed,
};

/// Re-resolve for a pane now at `location`, opened from `origin`.
///
/// Settles SYNCHRONOUSLY when the answer is cached — the common case on a
/// back/forward walk, and the reason navigating back to a location already
/// visited never flickers the button away and back — or when the location has
/// no candidate directory at all. Otherwise a worker runs and the completion
/// message carries the answer.
pub fn refresh(self: *Probe, location: []const u8, origin: ?[]const u8) Outcome {
    self.remember(&self.want_location, location);
    if (origin) |o| {
        self.remember(&self.want_origin, o);
    } else {
        if (self.want_origin) |o| self.alloc.free(o);
        self.want_origin = null;
    }
    return self.kick();
}

fn remember(self: *Probe, slot: *?[]u8, value: []const u8) void {
    const dup = self.alloc.dupe(u8, value) catch {
        if (slot.*) |old| self.alloc.free(old);
        slot.* = null;
        return;
    };
    if (slot.*) |old| self.alloc.free(old);
    slot.* = dup;
}

/// Start (or defer) a resolution for whatever `want_*` currently says.
fn kick(self: *Probe) Outcome {
    // A worker is already out. It will re-read `want_*` when it lands.
    if (self.thread != null) {
        self.dirty = true;
        return .pending;
    }

    const location = self.want_location orelse "";
    const origin: ?[]const u8 = self.want_origin;

    var key_buf: [path_cap * 2]u8 = undefined;
    const key = worktree.Cache.key(&key_buf, location, origin) orelse
        return self.apply(null);

    const now = w32.GetTickCount64();
    if (self.cache.get(key, now)) |hit| return self.apply(hit);

    var dir_buf: [path_cap]u8 = undefined;
    const dir = worktree.candidateDirectory(
        &dir_buf,
        location,
        origin,
        self.strategy,
    ) orelse {
        // Nothing to attribute this pane to at all — a negative answer worth
        // caching, since a website re-asks on every navigation.
        self.cache.put(key, null, now);
        return self.apply(null);
    };

    const job = self.alloc.create(Job) catch return self.apply(null);
    job.* = .{
        .alloc = self.alloc,
        .key = self.alloc.dupe(u8, key) catch {
            self.alloc.destroy(job);
            return self.apply(null);
        },
        .dir = self.alloc.dupe(u8, dir) catch {
            self.alloc.free(job.key);
            self.alloc.destroy(job);
            return self.apply(null);
        },
    };

    self.job = job;
    self.thread = std.Thread.spawn(.{}, work, .{ self, job }) catch |err| {
        log.warn("worktree probe thread failed err={}; feedback affordance off", .{err});
        job.destroy();
        self.job = null;
        return self.apply(null);
    };
    return .pending;
}

/// The worker: one `git rev-parse --show-toplevel`, then a post. Runs on its
/// own thread and touches nothing on the probe but the two handles it was
/// attached with (which are set before any worker can exist and never change).
fn work(self: *Probe, job: *Job) void {
    var buf: [path_cap]u8 = undefined;
    if (repositoryRoot(job.alloc, job.dir, &buf)) |root| {
        job.root = job.alloc.dupe(u8, root) catch null;
    }
    if (self.hwnd) |h| {
        if (w32.PostMessageW(h, self.message, 0, 0) == 0) {
            log.debug("worktree completion could not be posted", .{});
        }
    }
}

/// The completion post landed on the GUI thread: take the worker's answer,
/// cache it, and say whether the pane's worktree moved.
pub fn complete(self: *Probe) Outcome {
    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }
    var changed = false;
    if (self.job) |job| {
        self.job = null;
        self.cache.put(job.key, job.root, w32.GetTickCount64());
        changed = self.apply(job.root) == .changed;
        job.destroy();
    }
    if (self.dirty) {
        self.dirty = false;
        // A newer location arrived mid-flight; its answer may differ again.
        // A second worker leaves `current` as this one just set it, which is
        // the truth until that worker lands — so the outcome still describes
        // what the caller should paint NOW.
        if (self.kick() == .changed) changed = true;
    }
    return if (changed) .changed else .unchanged;
}

/// Adopt `root` as the pane's worktree, and say whether it actually moved — so
/// a caller only repaints when there is something to repaint.
fn apply(self: *Probe, root: ?[]const u8) Outcome {
    if (root) |r| {
        if (self.current) |c| {
            if (std.mem.eql(u8, c, r)) return .unchanged;
        }
        const dup = self.alloc.dupe(u8, r) catch return .unchanged;
        if (self.current) |c| self.alloc.free(c);
        self.current = dup;
        return .changed;
    }
    if (self.current) |c| {
        self.alloc.free(c);
        self.current = null;
        return .changed;
    }
    return .unchanged;
}

// -------------------------------------------------------------------------
// git
// -------------------------------------------------------------------------

/// The top-level directory of the working tree containing `dir`, into `buf`;
/// null when it is not in one. BLOCKING — worker thread only.
fn repositoryRoot(alloc: Allocator, dir: []const u8, buf: []u8) ?[]const u8 {
    if (!worktree.realDirExists(dir)) return null;
    for (worktree.git_paths, 0..) |_, i| {
        const argv = worktree.rootArgv(i, dir);
        var out_buf: [stdout_cap]u8 = undefined;
        const out = run(alloc, &argv, &out_buf) orelse continue;
        // git prints nothing and exits non-zero outside a repository, which is
        // an ANSWER ("no worktree"), not a reason to try the next binary.
        return worktree.parseRoot(buf, out);
    }
    return null;
}

/// Run `argv`, returning its stdout in `buf`. Null when the binary could not be
/// launched at all — the only case worth trying another path for.
///
/// `create_no_window` is load-bearing: `git.exe` is a console program and this
/// is a GUI-subsystem process, so without it every navigation flashes a console
/// window over the user's terminal.
fn run(alloc: Allocator, argv: []const []const u8, buf: []u8) ?[]const u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    // Ignored, not piped: with one pipe there is nothing to interleave, so the
    // read below cannot deadlock against a full second pipe.
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    child.spawn() catch return null;

    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    const n = stdout.readAll(buf) catch 0;
    _ = child.wait() catch return null;
    return buf[0..n];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a location with nothing to attribute it to is cached as no worktree" {
    var p = Probe.init(testing.allocator);
    defer p.deinit();

    // A website with no origin directory has no candidate at all, so this
    // resolves synchronously and spawns no process.
    try testing.expectEqual(Outcome.unchanged, p.refresh("https://example.com/", null));
    try testing.expect(p.thread == null);
    try testing.expect(p.worktreePath() == null);

    var key_buf: [512]u8 = undefined;
    const key = worktree.Cache.key(&key_buf, "https://example.com/", null).?;
    const hit = p.cache.get(key, w32.GetTickCount64());
    try testing.expect(hit != null);
    try testing.expect(hit.? == null);
}

test "a resolution completes, sticks, and answers from cache the second time" {
    var p = Probe.init(testing.allocator);
    defer p.deinit();

    // This source file's own directory, which is in this repo's working tree.
    const here = "D:\\git\\ghoztty\\src\\apprt\\win32\\ViewerWorktreeProbe.zig";
    if (!worktree.realDirExists("D:\\git\\ghoztty")) return error.SkipZigTest;

    try testing.expectEqual(Outcome.pending, p.refresh(here, null));
    try testing.expect(p.thread != null);
    try testing.expectEqual(Outcome.changed, p.complete()); // it found the repo
    const root_owned = try testing.allocator.dupe(u8, p.worktreePath().?);
    defer testing.allocator.free(root_owned);
    try testing.expectEqualStrings("ghoztty", worktree.worktreeName(root_owned));

    // Same question again: answered from the cache, synchronously, and the
    // answer did not MOVE — so the button must not flicker away and back.
    try testing.expectEqual(Outcome.unchanged, p.refresh(here, null));
    try testing.expect(p.thread == null);
    try testing.expectEqualStrings(root_owned, p.worktreePath().?);
}

test "a directory in no repository resolves to no worktree" {
    var p = Probe.init(testing.allocator);
    defer p.deinit();

    const tmp = std.process.getEnvVarOwned(testing.allocator, "TEMP") catch
        return error.SkipZigTest;
    defer testing.allocator.free(tmp);
    if (!worktree.realDirExists(tmp)) return error.SkipZigTest;

    // A pane opened with `--working-directory=%TEMP%` on a remote site: the
    // origin is the candidate, and %TEMP% is in no working tree.
    _ = p.refresh("https://example.com/", tmp);
    if (p.thread != null) _ = p.complete();
    try testing.expect(p.worktreePath() == null);
}
