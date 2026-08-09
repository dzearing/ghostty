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
//! Leg 2 of the strategy — a `localhost:PORT` pane's listening process and that
//! process's working directory (T638) — rides the same worker for the same
//! reason: it is a machine-wide TCP table fetch plus a PEB read on an untrusted
//! process. Which is why `kick` plans rather than resolves: `viewer_worktree`'s
//! `plan` settles legs 1 and 3 here (string work) and hands the port to `work`.
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
const git_run = @import("git_run.zig");
const internal_os = @import("../../os/main.zig");

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
    /// The candidate directory git is to be asked about. Owned. Null only for a
    /// `port` job with no origin behind it, where the listener is the pane's
    /// one and only chance of being attributable to anything.
    dir: ?[]u8,
    /// Leg 2: the loopback port to resolve BEFORE `dir` is used, when the
    /// location named one. The lookup is two syscalls against another process,
    /// which is why it rides the worker rather than the message loop.
    port: ?u16 = null,
    /// The resolved worktree root, written by the worker. Owned; null when the
    /// directory is in no repository at all.
    root: ?[]u8 = null,

    fn destroy(self: *Job) void {
        const alloc = self.alloc;
        alloc.free(self.key);
        if (self.dir) |d| alloc.free(d);
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

/// How the strategy's impure edges are reached. Overridden by tests; `init`
/// installs the real ones, leg 2's port lookup included (T638).
strategy: worktree.Strategy = .{},

pub fn init(alloc: Allocator) Probe {
    return .{
        .alloc = alloc,
        .cache = .{ .alloc = alloc },
        .strategy = .{ .port_lookup = listenerCwd },
    };
}

/// Leg 2 for real: the working directory of whatever is listening on `port`.
///
/// Two OS calls, each of which is allowed to fail without consequence beyond a
/// null. `GetExtendedTcpTable` names the owning process
/// (`os/listening_pid.zig`), and a PEB read gets that process's cwd
/// (`os/process_cwd.zig`) — Windows exposes no documented API for the latter,
/// and the alternative on offer is guessing from a command line, which is the
/// confidently-wrong answer this whole feature is built to avoid.
///
/// BLOCKING, and deliberately reachable only from `work`: both calls are
/// syscalls against another process, and the viewer's message loop is the one
/// the terminal next door draws on.
///
/// The trailing separator the PEB stores (`D:\git\ghoztty\`) is trimmed, so a
/// listener's directory is spelled the same way a file viewer's is and the two
/// cannot cache or compare as different strings. A drive root (`D:\`) keeps its
/// separator, since `D:` alone means "whatever the current directory on D: is".
fn listenerCwd(alloc: Allocator, port: u16, buf: []u8) ?[]const u8 {
    const pid = internal_os.listening_pid.forPort(alloc, port) orelse return null;
    const cwd = internal_os.process_cwd.fromPid(pid, alloc) orelse return null;
    defer alloc.free(cwd);

    var out: []const u8 = cwd;
    if (out.len > 3) out = std.mem.trimRight(u8, out, "\\/");
    if (out.len == 0 or out.len > buf.len) return null;
    @memcpy(buf[0..out.len], out);
    return buf[0..out.len];
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

    // Legs 1 and 3 are decided here, on the GUI thread, because they are string
    // work. Leg 2 is not — its port lookup goes with the job.
    var dir_buf: [path_cap]u8 = undefined;
    var dir: ?[]const u8 = null;
    var port: ?u16 = null;
    switch (worktree.plan(&dir_buf, location, origin, self.strategy.dir_exists)) {
        .none => {
            // Nothing to attribute this pane to at all — a negative answer worth
            // caching, since a website re-asks on every navigation.
            self.cache.put(key, null, now);
            return self.apply(null);
        },
        .directory => |d| dir = d,
        .port => |p| {
            port = p.port;
            dir = p.fallback;
        },
    }

    const job = self.alloc.create(Job) catch return self.apply(null);
    job.* = .{
        .alloc = self.alloc,
        .key = self.alloc.dupe(u8, key) catch {
            self.alloc.destroy(job);
            return self.apply(null);
        },
        .dir = if (dir) |d| (self.alloc.dupe(u8, d) catch {
            self.alloc.free(job.key);
            self.alloc.destroy(job);
            return self.apply(null);
        }) else null,
        .port = port,
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

/// The worker: leg 2's port lookup when the job carries one, then one
/// `git rev-parse --show-toplevel`, then a post. Runs on its own thread and
/// touches nothing on the probe but the two handles it was attached with (which
/// are set before any worker can exist and never change) and `port_lookup`,
/// which is set at construction.
fn work(self: *Probe, job: *Job) void {
    var dir_buf: [path_cap]u8 = undefined;
    const dir = if (job.port) |port| worktree.resolvePort(
        job.alloc,
        &dir_buf,
        .{ .port = port, .fallback = job.dir },
        self.strategy,
    ) else job.dir;

    var buf: [path_cap]u8 = undefined;
    if (dir) |d| {
        if (repositoryRoot(job.alloc, d, &buf)) |root| {
            job.root = job.alloc.dupe(u8, root) catch null;
        }
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
        const out = git_run.capture(alloc, &argv, &out_buf) orelse continue;
        // git prints nothing and exits non-zero outside a repository, which is
        // an ANSWER ("no worktree"), not a reason to try the next binary.
        return worktree.parseRoot(buf, out);
    }
    return null;
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

test "leg 2: a loopback port resolves to the LISTENER's worktree, not the origin" {
    var p = Probe.init(testing.allocator);
    defer p.deinit();

    // This test process is the listener, so the right answer is our own
    // working directory's worktree.
    const cwd = std.process.getCwdAlloc(testing.allocator) catch
        return error.SkipZigTest;
    defer testing.allocator.free(cwd);
    var root_buf: [path_cap]u8 = undefined;
    const want = repositoryRoot(testing.allocator, cwd, &root_buf) orelse
        return error.SkipZigTest;
    const want_owned = try testing.allocator.dupe(u8, want);
    defer testing.allocator.free(want_owned);

    // The pane's ORIGIN is deliberately outside that worktree, so a pass
    // cannot be leg 3 wearing leg 2's clothes.
    const tmp = std.process.getEnvVarOwned(testing.allocator, "TEMP") catch
        return error.SkipZigTest;
    defer testing.allocator.free(tmp);
    if (std.mem.startsWith(u8, tmp, want_owned)) return error.SkipZigTest;

    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(
        &loc_buf,
        "http://localhost:{d}/",
        .{server.listen_address.getPort()},
    );

    _ = p.refresh(loc, tmp);
    if (p.thread != null) _ = p.complete();
    try testing.expectEqualStrings(want_owned, p.worktreePath().?);
}

test "a loopback port with nobody behind it falls through to the origin" {
    var p = Probe.init(testing.allocator);
    defer p.deinit();

    // Bind and release: a port that was ours a moment ago is a far better
    // "free port" than a guessed number.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    const port = server.listen_address.getPort();
    server.deinit();

    var loc_buf: [64]u8 = undefined;
    const loc = try std.fmt.bufPrint(&loc_buf, "http://localhost:{d}/", .{port});

    const cwd = std.process.getCwdAlloc(testing.allocator) catch
        return error.SkipZigTest;
    defer testing.allocator.free(cwd);
    var root_buf: [path_cap]u8 = undefined;
    const want = repositoryRoot(testing.allocator, cwd, &root_buf) orelse
        return error.SkipZigTest;
    const want_owned = try testing.allocator.dupe(u8, want);
    defer testing.allocator.free(want_owned);

    // Leg 3 answers, which is the whole point: an unattributable port is not a
    // dead end, it is a pane that still belongs to where it was opened from.
    _ = p.refresh(loc, cwd);
    if (p.thread != null) _ = p.complete();
    try testing.expectEqualStrings(want_owned, p.worktreePath().?);
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
