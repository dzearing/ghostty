//! Which git working tree a viewer pane's content belongs to (T633, the win32
//! half of CLAUDE.md's "Worktree feedback capture"; Mac's
//! `ViewerWorktreeResolver` + `ViewerWorktreeCache` in `ViewerWorktree.swift`).
//!
//! "Worktree" here means any git working tree — a linked worktree AND a main
//! checkout both count, because `git rev-parse --show-toplevel` reports each
//! one's own root and either is a legitimate place to file feedback against.
//!
//! This module is PURE: the strategy, the cache and the parsing, with the two
//! genuinely impure steps — "does this directory exist" and "what is listening
//! on this port" — injected as function pointers so the whole thing asserts in
//! the none-runtime lane without a repo, a port or a process. The spawning half
//! (git off the UI thread, the completion post) is `ViewerWorktreeProbe.zig`,
//! which is where win32 enters the picture.
//!
//! Every path function here is the WINDOWS one by name (`dirnameWindows`,
//! `isAbsoluteWindows`, `basenameWindows`) rather than the native alias: this
//! module only ever reasons about Windows paths, and naming them explicitly is
//! what lets its tests mean the same thing when the none lane runs on the Mac
//! seat.

const std = @import("std");
const content = @import("viewer_content.zig");

/// Candidate `git` binaries, in order. The bare name first — a GUI app on
/// Windows inherits the user's `PATH` from Explorer, so the ordinary case is a
/// PATH hit — with the two default installer locations behind it, because a
/// PATH that lost git is a degraded environment rather than a repo-less one.
/// (Mac keeps the same kind of list in `ViewerProcess.gitPaths`, for the
/// stronger reason that a bundled app has almost no PATH at all.)
pub const git_paths = [_][]const u8{
    "git",
    "C:\\Program Files\\Git\\cmd\\git.exe",
    "C:\\Program Files (x86)\\Git\\cmd\\git.exe",
};

/// Does this directory exist? Injected so `candidateDirectory` is testable
/// without a filesystem.
pub const DirProbe = *const fn (path: []const u8) bool;

/// The working directory of whatever is listening on `port`, written into
/// `buf`; null when nothing is listening or its cwd cannot be read.
///
/// Leg 2 of the strategy, and the ONLY leg that is not portable: Windows has no
/// `lsof`, and picking its replacement is a real choice, so it is T638's. Until
/// that lands the hook is simply never installed and a localhost pane falls
/// through to leg 3 — its origin directory, which is usually the right answer
/// anyway.
pub const PortProbe = *const fn (port: u16, buf: []u8) ?[]const u8;

/// The impure edges of `candidateDirectory`, defaulted to the real ones.
pub const Strategy = struct {
    dir_exists: DirProbe = realDirExists,
    port_lookup: ?PortProbe = null,
};

pub fn realDirExists(path: []const u8) bool {
    if (path.len == 0) return false;
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

// -----------------------------------------------------------------------------
// Strategy D: which directory is this pane's content attributable to
// -----------------------------------------------------------------------------

/// The directory a location should be attributed to, before git is asked
/// anything. Null when there is nothing to attribute it to at all.
///
/// In order:
///   1. A file viewer contributes the viewed file's own directory.
///   2. An `http://localhost:PORT` viewer contributes the listening process's
///      working directory (T638; today the hook is absent and this never fires).
///   3. Anything else — a remote site, a blank pane, a diff spec, a port with
///      no listener — falls back to the directory the pane was OPENED from.
///
/// The result is borrowed from `buf`, from `location`, or from
/// `origin_directory`, so it lives exactly as long as the shortest of those.
pub fn candidateDirectory(
    buf: []u8,
    location: []const u8,
    origin_directory: ?[]const u8,
    strategy: Strategy,
) ?[]const u8 {
    // 1. A file's own directory. A file naming a directory that does not exist
    // still falls through to the origin: a viewer showing a missing file must
    // not misattribute feedback to a directory nobody has.
    if (fileDirectory(buf, location)) |dir| {
        if (strategy.dir_exists(dir)) return dir;
        return origin_directory;
    }

    // 2. Loopback dev servers: port -> pid -> cwd.
    if (loopbackPort(location)) |port| {
        if (strategy.port_lookup) |probe| {
            if (probe(port, buf)) |cwd| {
                if (strategy.dir_exists(cwd)) return cwd;
            }
        }
    }

    // 3. Everything else, a loopback port with no listener included.
    return origin_directory;
}

/// The directory of the file a location names, or null when it names anything
/// else. Mirrors `viewer_content.modeFor`'s split so the two can never
/// disagree about what counts as a file, and then adds what Mac's
/// `hasPrefix("/")` check adds: the path must be ABSOLUTE. That is what keeps a
/// `git-status:` / `git-diff:<rev>` spec — which is a revspec, not a path — out
/// of leg 1 and on the origin-directory fallback where it belongs.
pub fn fileDirectory(buf: []u8, location: []const u8) ?[]const u8 {
    if (location.len == 0) return null;
    if (!content.modeFor(location).isFile()) return null;
    const path = content.filePath(buf, location) orelse return null;
    if (!std.fs.path.isAbsoluteWindows(path)) return null;
    const dir = std.fs.path.dirnameWindows(path) orelse return null;
    if (dir.len == 0) return null;
    // `filePath` always writes into `buf`, so the dirname is a prefix of it and
    // can be normalized in place. It is normalized for the same reason
    // `parseRoot` normalizes git's answer: a `file:///D:/x/y.md` location and a
    // `D:\x\y.md` one name the same directory, and only one of the two spellings
    // should ever leave this module.
    const out = buf[0..dir.len];
    for (out) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return out;
}

/// The TCP port of a LOOPBACK http(s) URL, or null when the location points
/// somewhere else. `0.0.0.0` counts: a dev server bound to every interface and
/// browsed as `http://0.0.0.0:3000` is still a local process we could look up.
pub fn loopbackPort(location: []const u8) ?u16 {
    const scheme_len: usize = blk: {
        for ([_][]const u8{ "http://", "https://" }) |p| {
            if (location.len > p.len and std.ascii.eqlIgnoreCase(location[0..p.len], p)) {
                break :blk p.len;
            }
        }
        return null;
    };
    const https = scheme_len == "https://".len;

    var authority = location[scheme_len..];
    for ([_]u8{ '/', '?', '#' }) |c| {
        if (std.mem.indexOfScalar(u8, authority, c)) |i| authority = authority[0..i];
    }
    // `user:password@host` — the LAST '@' wins, since a password may hold one.
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |i| authority = authority[i + 1 ..];
    if (authority.len == 0) return null;

    // The port has to be found AFTER the authority's host, or the first colon
    // inside an IPv6 literal reads as one.
    var host = authority;
    var port_text: []const u8 = "";
    if (host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        if (close + 1 < host.len and host[close + 1] == ':') {
            port_text = host[close + 2 ..];
        }
        host = host[0 .. close + 1];
    } else if (std.mem.indexOfScalar(u8, host, ':')) |i| {
        port_text = host[i + 1 ..];
        host = host[0..i];
    }

    const loopback = [_][]const u8{ "localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0" };
    const is_loopback = for (loopback) |h| {
        if (std.ascii.eqlIgnoreCase(host, h)) break true;
    } else false;
    if (!is_loopback) return null;

    if (port_text.len == 0) return if (https) 443 else 80;
    return std.fmt.parseInt(u16, port_text, 10) catch null;
}

// -----------------------------------------------------------------------------
// Directory -> repo root
// -----------------------------------------------------------------------------

/// The argv for the repo-root query, using `git_paths[index]` as the binary.
/// `--show-toplevel` reports the LINKED worktree's own root inside a linked
/// worktree and the main checkout's root otherwise, so one command covers both
/// without special-casing `git worktree list`.
pub fn rootArgv(index: usize, dir: []const u8) [5][]const u8 {
    return .{ git_paths[index], "-C", dir, "rev-parse", "--show-toplevel" };
}

/// `git rev-parse --show-toplevel`'s stdout as a path, written into `buf`.
///
/// Git prints FORWARD slashes on Windows (`D:/git/ghoztty`), which is a
/// perfectly good path to pass back to git and a wrong-looking one to show a
/// user or to join with `\`-shaped paths — so it is normalized here, at the one
/// place the string enters the app, rather than at each of its readers.
/// Null for empty output, which is what a directory in no repo produces
/// (git also exits non-zero there, but the empty answer is the one that cannot
/// be missed).
pub fn parseRoot(buf: []u8, stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    for (trimmed, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    return buf[0..trimmed.len];
}

/// The last component of a worktree root — what the button and its accessible
/// name say, so a user can see at a glance which repo a report would land in.
pub fn worktreeName(root: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, root, "\\/");
    if (trimmed.len == 0) return root;
    return std.fs.path.basenameWindows(trimmed);
}

/// The feedback button's tooltip and accessible name, into `buf`. Mac's
/// `.help("Send feedback to \(worktree.path)")`; the FULL path, because the
/// button itself is icon-only on both platforms and the destination has to be
/// somewhere.
pub fn tooltipText(buf: []u8, root: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Send feedback to {s}", .{root}) catch root;
}

// -----------------------------------------------------------------------------
// Cache
// -----------------------------------------------------------------------------

/// Resolution costs a subprocess launch and a viewer re-resolves on EVERY
/// navigation — each step of a back/forward walk included — so an uncached
/// implementation would stutter the pane. Entries expire rather than living
/// forever because the port->cwd leg is genuinely volatile: starting a dev
/// server on :3000 has to make the button appear without reopening the pane.
pub const Cache = struct {
    /// How long a resolution stays good, NEGATIVE ones included (Mac's `ttl`).
    pub const ttl_ms: u64 = 15_000;

    /// How many (location, origin) pairs are remembered. A pane walks a handful
    /// of locations; past that the oldest slot is recycled, which costs one
    /// re-resolution and never a wrong answer.
    pub const capacity: usize = 8;

    const Entry = struct {
        key: []u8,
        /// The resolved root, or null for "cached as no worktree" — the
        /// negative answer is worth caching precisely because a website
        /// re-resolves on every navigation.
        root: ?[]u8,
        at_ms: u64,
    };

    alloc: std.mem.Allocator,
    entries: [capacity]?Entry = @splat(null),
    /// Round-robin eviction cursor. Not an LRU: with 8 slots and a 15s TTL the
    /// difference is unmeasurable, and an LRU is state that can be wrong.
    next: usize = 0,

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*slot| {
            if (slot.*) |e| self.free(e);
            slot.* = null;
        }
    }

    fn free(self: *Cache, e: Entry) void {
        self.alloc.free(e.key);
        if (e.root) |r| self.alloc.free(r);
    }

    /// The cache key for a pane at `location` opened from `origin`. Written
    /// into `buf`; null when the pair is too long to key (which reads as a
    /// permanent miss, i.e. correctness at the cost of a re-resolve).
    pub fn key(buf: []u8, location: []const u8, origin: ?[]const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}\x00{s}", .{ location, origin orelse "" }) catch null;
    }

    /// A still-valid answer, if there is one. The OUTER optional is "not
    /// cached"; the inner is "cached as no worktree". Borrowed from the cache,
    /// so it dies with the next `put` that evicts its slot.
    pub fn get(self: *const Cache, k: []const u8, now_ms: u64) ??[]const u8 {
        for (self.entries) |slot| {
            const e = slot orelse continue;
            if (!std.mem.eql(u8, e.key, k)) continue;
            if (now_ms -% e.at_ms >= ttl_ms) return null;
            return @as(?[]const u8, e.root);
        }
        return null;
    }

    /// Record `root` (or its absence) for `k`. Best-effort: a cache that cannot
    /// allocate simply does not remember, which costs a re-resolution and
    /// nothing else.
    pub fn put(self: *Cache, k: []const u8, root: ?[]const u8, now_ms: u64) void {
        const key_dup = self.alloc.dupe(u8, k) catch return;
        const root_dup: ?[]u8 = if (root) |r|
            (self.alloc.dupe(u8, r) catch {
                self.alloc.free(key_dup);
                return;
            })
        else
            null;

        // Replace the same key in place when it is already here, so a re-probe
        // refreshes an entry rather than filling the table with one location.
        for (&self.entries) |*slot| {
            if (slot.*) |e| {
                if (!std.mem.eql(u8, e.key, k)) continue;
                self.free(e);
                slot.* = .{ .key = key_dup, .root = root_dup, .at_ms = now_ms };
                return;
            }
        }
        for (&self.entries) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .key = key_dup, .root = root_dup, .at_ms = now_ms };
            return;
        }
        const victim = self.next % capacity;
        self.next = victim + 1;
        if (self.entries[victim]) |e| self.free(e);
        self.entries[victim] = .{ .key = key_dup, .root = root_dup, .at_ms = now_ms };
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const testing = std.testing;

fn noDirs(_: []const u8) bool {
    return false;
}

fn allDirs(_: []const u8) bool {
    return true;
}

fn fakePort(port: u16, buf: []u8) ?[]const u8 {
    if (port != 3000) return null;
    const dir = "D:\\git\\server";
    @memcpy(buf[0..dir.len], dir);
    return buf[0..dir.len];
}

test "leg 1: a file viewer is attributed to the file's own directory" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const s: Strategy = .{ .dir_exists = allDirs };

    try testing.expectEqualStrings(
        "D:\\git\\ghoztty\\docs",
        candidateDirectory(&buf, "D:\\git\\ghoztty\\docs\\design.md", null, s).?,
    );
    // A `file://` URL is the same file said another way.
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        candidateDirectory(&buf, "file:///D:/git/ghoztty/README.md", null, s).?,
    );
    // The file's directory WINS over the origin: the pane moved.
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty\\docs",
        candidateDirectory(&buf, "D:\\git\\ghoztty\\docs\\design.md", "D:\\elsewhere", s).?,
    );
}

test "leg 1 falls through when the file's directory does not exist" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const s: Strategy = .{ .dir_exists = noDirs };
    // A viewer showing a missing file must not misattribute feedback to a
    // directory nobody has — it falls back to where the pane was opened.
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        candidateDirectory(&buf, "D:\\gone\\design.md", "D:\\git\\ghoztty", s).?,
    );
    try testing.expect(candidateDirectory(&buf, "D:\\gone\\design.md", null, s) == null);
}

test "leg 3: an http location and a blank pane fall back to the origin" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const s: Strategy = .{ .dir_exists = allDirs };

    for ([_][]const u8{
        "https://example.com/docs",
        "http://localhost:3000/", // no port probe installed yet (T638)
        "about:blank",
        "",
        "git-status:", // a revspec is not a path
        "git-diff:main...HEAD",
        "README.md", // relative: not absolute, so not a file location
    }) |loc| {
        try testing.expectEqualStrings(
            "D:\\git\\ghoztty",
            candidateDirectory(&buf, loc, "D:\\git\\ghoztty", s).?,
        );
        try testing.expect(candidateDirectory(&buf, loc, null, s) == null);
    }
}

test "leg 2: a loopback port resolves through the probe when one is installed" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const s: Strategy = .{ .dir_exists = allDirs, .port_lookup = fakePort };

    try testing.expectEqualStrings(
        "D:\\git\\server",
        candidateDirectory(&buf, "http://localhost:3000/app", "D:\\git\\ghoztty", s).?,
    );
    // A port with no listener is leg 3, not a dead end.
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        candidateDirectory(&buf, "http://localhost:9999/", "D:\\git\\ghoztty", s).?,
    );
    // A REMOTE site never consults the probe.
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        candidateDirectory(&buf, "http://example.com:3000/", "D:\\git\\ghoztty", s).?,
    );
}

test "loopback classification" {
    try testing.expectEqual(@as(?u16, 3000), loopbackPort("http://localhost:3000/x"));
    try testing.expectEqual(@as(?u16, 8080), loopbackPort("http://127.0.0.1:8080"));
    try testing.expectEqual(@as(?u16, 5173), loopbackPort("http://0.0.0.0:5173/"));
    try testing.expectEqual(@as(?u16, 4000), loopbackPort("http://[::1]:4000/x"));
    // Default ports when the URL leaves them out.
    try testing.expectEqual(@as(?u16, 80), loopbackPort("http://localhost/"));
    try testing.expectEqual(@as(?u16, 443), loopbackPort("https://localhost/"));
    // Userinfo does not become the host.
    try testing.expectEqual(@as(?u16, 3000), loopbackPort("http://me:pw@localhost:3000/"));
    // Not loopback, not http, not a URL.
    try testing.expectEqual(@as(?u16, null), loopbackPort("http://example.com:3000/"));
    try testing.expectEqual(@as(?u16, null), loopbackPort("file:///D:/x"));
    try testing.expectEqual(@as(?u16, null), loopbackPort("D:\\git\\x\\README.md"));
    try testing.expectEqual(@as(?u16, null), loopbackPort("http://localhost:notaport/"));
}

test "the repo root is trimmed and normalized to backslashes" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty",
        parseRoot(&buf, "D:/git/ghoztty\n").?,
    );
    try testing.expectEqualStrings(
        "D:\\git\\ghoztty-wt",
        parseRoot(&buf, "  D:/git/ghoztty-wt \r\n").?,
    );
    // A directory in no repo prints nothing.
    try testing.expect(parseRoot(&buf, "") == null);
    try testing.expect(parseRoot(&buf, "\n") == null);
}

test "the worktree's name is its last path component" {
    try testing.expectEqualStrings("ghoztty", worktreeName("D:\\git\\ghoztty"));
    try testing.expectEqualStrings("ghoztty", worktreeName("D:\\git\\ghoztty\\"));
    try testing.expectEqualStrings("ghoztty", worktreeName("D:/git/ghoztty"));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "Send feedback to D:\\git\\ghoztty",
        tooltipText(&buf, "D:\\git\\ghoztty"),
    );
}

test "the cache answers inside its TTL and re-resolves after it" {
    var cache: Cache = .{ .alloc = testing.allocator };
    defer cache.deinit();

    var kbuf: [512]u8 = undefined;
    const k = Cache.key(&kbuf, "D:\\git\\ghoztty\\README.md", "D:\\git\\ghoztty").?;

    // Cold.
    try testing.expect(cache.get(k, 1_000) == null);

    cache.put(k, "D:\\git\\ghoztty", 1_000);
    try testing.expectEqualStrings("D:\\git\\ghoztty", cache.get(k, 1_000).?.?);
    try testing.expectEqualStrings("D:\\git\\ghoztty", cache.get(k, 1_000 + Cache.ttl_ms - 1).?.?);
    // Expired: a miss again, so a dev server started later still shows up.
    try testing.expect(cache.get(k, 1_000 + Cache.ttl_ms) == null);

    // A NEGATIVE answer is cached too, and is distinguishable from a miss.
    var kbuf2: [512]u8 = undefined;
    const k2 = Cache.key(&kbuf2, "https://example.com/", null).?;
    cache.put(k2, null, 2_000);
    const hit = cache.get(k2, 2_000);
    try testing.expect(hit != null);
    try testing.expect(hit.? == null);

    // The two keys are distinct, and origin is part of the key: the same
    // location opened from a different directory is a different question.
    var kbuf3: [512]u8 = undefined;
    const k3 = Cache.key(&kbuf3, "https://example.com/", "D:\\other").?;
    try testing.expect(cache.get(k3, 2_000) == null);
}

test "the cache refreshes a known key in place and recycles when full" {
    var cache: Cache = .{ .alloc = testing.allocator };
    defer cache.deinit();

    var kbuf: [512]u8 = undefined;
    const k = Cache.key(&kbuf, "D:\\a\\x.md", null).?;
    cache.put(k, "D:\\a", 0);
    cache.put(k, "D:\\b", 5_000);
    try testing.expectEqualStrings("D:\\b", cache.get(k, 5_000).?.?);

    // Overfill: every put lands, nothing leaks, and the newest is present.
    var i: usize = 0;
    while (i < Cache.capacity * 2) : (i += 1) {
        var b: [512]u8 = undefined;
        var loc: [64]u8 = undefined;
        const l = std.fmt.bufPrint(&loc, "D:\\x\\{d}.md", .{i}) catch unreachable;
        cache.put(Cache.key(&b, l, null).?, "D:\\x", 6_000);
    }
    var b: [512]u8 = undefined;
    var loc: [64]u8 = undefined;
    const last = std.fmt.bufPrint(&loc, "D:\\x\\{d}.md", .{Cache.capacity * 2 - 1}) catch unreachable;
    try testing.expectEqualStrings("D:\\x", cache.get(Cache.key(&b, last, null).?, 6_000).?.?);
}
