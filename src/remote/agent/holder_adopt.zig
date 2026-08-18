//! Startup **re-adoption** of surviving `--pty-host` holders (T906, increment 3
//! of the T705 non-destructive agent upgrade — design:
//! `docs/design/agent-nondestructive-handoff.md`).
//!
//! T905 made a session's ConPTY, shell and kill-on-close job live in a separate
//! holder process, so an agent that dies — crashed, killed, replaced by a newer
//! build — leaves every shell running and its output piling up in the holder's
//! replay buffer. This module is the other half: the first thing a starting
//! agent does with the roster it just loaded from `sessions.json` is find those
//! survivors and plug them back in.
//!
//! ```
//!   sessions.json record ──dial holder_pipe──► HELLO (shell pid, retained
//!                                              window, exit state)
//!                        ──ATTACH(ack)───────► replay of exactly the bytes the
//!                                              on-disk ring snapshot is missing
//! ```
//!
//! What the user sees afterwards: nothing. The pane re-attaches to the same
//! running program, the scrollback has no hole and no restart divider, and the
//! shell pid is the one it was before. A holder that does NOT answer takes the
//! path it always took — the relaunch/tombstone notice — because in that case
//! the shell really is gone.
//!
//! ## Why the ordering is what it is
//!
//! 1. **Adopt, then reap.** The orphan sweep below shuts down holders that no
//!    session record claims. Running it before adoption would let it kill the
//!    very shells we are about to pick up.
//! 2. **Before the listener accepts anybody.** A viewer that ATTACHes to a
//!    holder-backed session mid-adoption would see it as a dead tombstone and
//!    offer a RELAUNCH — which would spawn a SECOND shell beside the running
//!    one. Adoption is finished before the agent serves its first connection.
//!
//! ## The orphan sweep
//!
//! A holder whose session record aged out (`max_unclaimed_restarts`), or that
//! no record ever named, is unreachable forever: no agent will dial a pipe name
//! nothing records, and no viewer can attach to a session that does not exist.
//! Its shell would run until the box rebooted. So after adoption we enumerate
//! the holder pipe namespace and shut down every holder no live session claims.
//!
//! Two properties keep that from being dangerous. The pipe name carries the
//! username AND the build-mode segment, so a debug agent can only ever see
//! debug holders (T350 endpoint isolation). And a holder serves ONE owner at a
//! time — if a connect succeeds, nobody owns it, which is the same fact the
//! sweep is testing for.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const proto = @import("pty_host_proto.zig");
const pty_host = @import("pty_host.zig");
const pty_holder_child = @import("pty_holder_child.zig");
const pipe_stream = @import("../pipe_stream.zig");
const session = @import("session.zig");

const is_windows = builtin.os.tag == .windows;
const log = std.log.scoped(.holder_adopt);

/// What one startup sweep did, for the log line and for tests.
pub const Outcome = struct {
    /// Holders re-adopted; their sessions are live again.
    adopted: usize = 0,
    /// Recorded holders that did not answer — the session fell back to the
    /// relaunchable-tombstone path.
    abandoned: usize = 0,
    /// Orphaned holders shut down (nothing could ever have reached them).
    reaped: usize = 0,
    /// Holders left running untouched because this agent could not serve them
    /// (protocol skew). Deliberately NOT killed: a rollback must not destroy
    /// sessions a newer build created.
    left: usize = 0,
};

/// The whole startup step. Best-effort throughout: any failure downgrades a
/// session to the behavior it had before holders existed, and never stops the
/// agent from starting.
pub fn run(alloc: Allocator, store: *session.SessionStore) Outcome {
    var out: Outcome = .{};
    if (!is_windows) return out;

    const candidates = store.holderCandidates(alloc) catch |err| {
        log.warn("could not enumerate holder-backed sessions: {}", .{err});
        return out;
    };
    defer session.SessionStore.freeHolderCandidates(alloc, candidates);

    for (candidates) |c| {
        const spawned = pty_holder_child.adopt(alloc, .{
            .pipe_name = c.pipe,
            .session_id = &c.id_str,
            .holder_pid = c.holder_pid,
            .ack = c.ack,
        }) catch |err| {
            // Whether to FORGET the recorded pipe is the consequential half of
            // this branch, because forgetting it also un-claims it for the
            // orphan sweep below — and the sweep kills what it reaps.
            //
            // So the record is dropped only when we positively learned the name
            // no longer belongs to the holder we recorded. Every failure that
            // is merely "we could not get an answer" KEEPS it: a two-second
            // dial timeout on a busy box would otherwise un-claim a perfectly
            // healthy holder, and the sweep — which dials again, and would
            // succeed — would end a live session over a hiccup. A kept record
            // costs one more adoption attempt next start, and ages itself out
            // through `max_unclaimed_restarts` if the holder really is gone.
            const forget = switch (err) {
                error.HolderSessionMismatch,
                error.HolderPidMismatch,
                error.HolderPidUnknown,
                error.HolderUnreachable,
                => true,
                else => false,
            };
            if (err == error.HolderProtocolMismatch) {
                // The skew rule: a holder this agent cannot serve is left
                // RUNNING and reported, never killed — a rollback must not
                // destroy sessions a newer build created.
                log.warn(
                    "session {s}: holder on '{s}' speaks a protocol this agent cannot serve; leaving it running",
                    .{ &c.id_str, c.pipe },
                );
                out.left += 1;
            } else {
                log.info(
                    "session {s}: holder on '{s}' did not answer ({s}); treating the session as ended{s}",
                    .{ &c.id_str, c.pipe, @errorName(err), if (forget) "" else " (its record is kept for the next start)" },
                );
                out.abandoned += 1;
            }
            store.abandonHolder(c.id, forget);
            continue;
        };

        const channel = store.adoptHolder(
            c.id,
            spawned.child,
            spawned.info.shell_pid,
            spawned.info.stamp,
        ) orelse {
            // The session vanished between the snapshot and now (it cannot, in
            // a single-threaded startup — but the store is the authority, and a
            // child nobody owns must not be left holding a pipe).
            spawned.child.terminate();
            continue;
        };
        // Arm the durability gate at the offset the ring snapshot ends at — the
        // very offset we just resumed from, so nothing is released that the file
        // does not already hold (T911).
        if (store.rings_dir != null and store.durable_ack) spawned.child.releaseTo(c.ack);

        // Outside the store lock, exactly like RELAUNCH: the sink takes it.
        spawned.child.attach(store, session.SessionStore.onChildOutputTrampoline, channel);
        out.adopted += 1;
    }

    out.reaped = reapOrphans(alloc, store);

    if (out.adopted > 0 or out.abandoned > 0 or out.reaped > 0 or out.left > 0) log.info(
        "holder sweep: {d} adopted, {d} abandoned, {d} orphan(s) reaped, {d} left for a newer agent",
        .{ out.adopted, out.abandoned, out.reaped, out.left },
    );
    return out;
}

/// Shut down every holder pipe in this user's (and this build mode's) namespace
/// that no session in the store claims. Returns how many were reaped.
fn reapOrphans(alloc: Allocator, store: *session.SessionStore) usize {
    if (!is_windows) return 0;

    const prefix = pipePrefix(alloc) catch return 0;
    defer alloc.free(prefix);

    var names = enumeratePipes(alloc, prefix) catch |err| {
        log.warn("could not enumerate the holder pipe namespace: {}", .{err});
        return 0;
    };
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    if (names.items.len == 0) return 0;

    // EVERY session's holder pipe, alive or not — the ones just adopted are
    // alive now, and a sweep that only looked at tombstones would reap exactly
    // the shells this run rescued.
    const claimed = store.holderPipes(alloc) catch return 0;
    defer {
        for (claimed) |p| alloc.free(p);
        alloc.free(claimed);
    }

    var reaped: usize = 0;
    for (names.items) |full| {
        var is_claimed = false;
        for (claimed) |p| {
            if (samePipe(p, full)) is_claimed = true;
        }
        if (is_claimed) continue;
        if (shutdownOrphan(alloc, full)) {
            log.warn("reaped orphaned holder '{s}': no session record names it", .{full});
            reaped += 1;
        }
    }
    return reaped;
}

/// Ask an unclaimed holder to shut down (which takes its shell subtree with it
/// — the holder owns the only handle to the kill-on-close job). Returns whether
/// the SHUTDOWN was delivered.
///
/// **The HELLO is the safety interlock, and connecting is not.** A holder serves
/// ONE owner at a time, but its listener replaces its pipe instance right after
/// each accept, so a second client connects successfully and simply waits —
/// unserved — until the current owner disconnects. Shutting down on the connect
/// alone would therefore be able to kill a session somebody is actively using.
/// A HELLO, on the other hand, is only ever sent by the holder's `serveOwner`
/// to the owner it is serving: receiving one proves this connection IS the
/// owner slot, which is the fact the sweep needs.
///
/// The wait for it is bounded by polling rather than a blocking read, because
/// this runs on the startup path — an unserved connection must cost the agent
/// two seconds and a skipped reap, never a wedge before it listens.
fn shutdownOrphan(alloc: Allocator, pipe_name: []const u8) bool {
    if (!is_windows) return false;
    const handle = pipe_stream.dialHandle(alloc, pipe_name) catch return false;
    var s = pipe_stream.PipeStream.init(handle);
    const stream = s.serverStream();
    defer stream.close();

    if (!waitReadable(handle, greeting_timeout_ms)) return false;
    var buf: [16 * 1024]u8 = undefined;
    const n = stream.read(&buf) catch return false;
    if (n == 0) return false;
    var accum = proto.Accum.init(alloc);
    defer accum.deinit();
    accum.push(buf[0..n]) catch return false;
    const frame = (accum.next() catch return false) orelse return false;
    if (frame.type != .hello) return false;

    var hdr: [proto.header_len]u8 = undefined;
    proto.frameHeader(.shutdown, 0, &hdr);
    stream.writeAll(&hdr) catch return false;
    return true;
}

/// How long an orphan probe waits for the holder's HELLO before giving up and
/// leaving it alone.
const greeting_timeout_ms: u64 = 2_000;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: std.os.windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: std.os.windows.DWORD,
    lpBytesRead: ?*std.os.windows.DWORD,
    lpTotalBytesAvail: ?*std.os.windows.DWORD,
    lpBytesLeftThisMessage: ?*std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

/// Whether `handle` has bytes waiting, within `timeout_ms`. `PeekNamedPipe`
/// never blocks and never consumes, so this turns "read with a deadline" — for
/// which there is no portable primitive on an overlapped pipe — into a poll.
fn waitReadable(handle: std.os.windows.HANDLE, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (true) {
        var avail: std.os.windows.DWORD = 0;
        if (PeekNamedPipe(handle, null, 0, null, &avail, null) == 0) return false;
        if (avail > 0) return true;
        if (waited >= timeout_ms) return false;
        std.Thread.sleep(50 * std.time.ns_per_ms);
        waited += 50;
    }
}

// -----------------------------------------------------------------------------
// Pure helpers (unit-tested — the classification rules decide whether a shell
// lives or dies, so they are not allowed to be a claim about untested code)
// -----------------------------------------------------------------------------

/// Named pipe names are case-insensitive, and this one is assembled from a
/// username and a recorded string, so a case difference is a real shape rather
/// than a hypothetical. Comparing them wrong reaps a live session.
pub fn samePipe(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The bare-name prefix every holder pipe of THIS user and THIS build mode
/// starts with: `ghoztty-pty-host[-debug]-<user>-`. Derived from the same
/// `pty_host.defaultPipeName` shape, with the `\\.\pipe\` root stripped, which
/// is the form `FindFirstFileW` enumerates.
pub fn pipePrefix(alloc: Allocator) ![]u8 {
    const full = try pty_host.defaultPipeName(alloc, "");
    defer alloc.free(full);
    return alloc.dupe(u8, stripPipeRoot(full));
}

/// `\\.\pipe\foo` → `foo`. Returns the input unchanged when it carries no root.
pub fn stripPipeRoot(name: []const u8) []const u8 {
    const root = "\\\\.\\pipe\\";
    if (name.len >= root.len and std.ascii.eqlIgnoreCase(name[0..root.len], root)) {
        return name[root.len..];
    }
    return name;
}

/// Whether an enumerated bare pipe name belongs to this agent's holder family.
/// A prefix match alone is not enough: the session-id segment must be present
/// and well-formed, so a name that merely starts the same way is not mistaken
/// for one of ours.
pub fn isHolderPipe(prefix: []const u8, bare: []const u8) bool {
    if (bare.len <= prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(bare[0..prefix.len], prefix)) return false;
    return proto.validSessionId(bare[prefix.len..]);
}

// -----------------------------------------------------------------------------
// Windows pipe-namespace enumeration
// -----------------------------------------------------------------------------

/// Every `\\.\pipe\<prefix><session-id>` currently bound, as full pipe paths
/// (owned by the caller). The named-pipe filesystem is enumerable as a
/// directory, which is the only supported way to answer "what holders exist"
/// without a registry of our own that a crash could desynchronize.
fn enumeratePipes(alloc: Allocator, prefix: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        out.deinit(alloc);
    }
    if (!is_windows) return out;

    const windows = std.os.windows;
    const pattern = std.unicode.utf8ToUtf16LeAllocZ(alloc, "\\\\.\\pipe\\*") catch return out;
    defer alloc.free(pattern);

    var data: windows.WIN32_FIND_DATAW = undefined;
    const h = windows.kernel32.FindFirstFileW(pattern, &data);
    if (h == windows.INVALID_HANDLE_VALUE) return out;
    defer _ = windows.kernel32.FindClose(h);

    var name_buf: [512]u8 = undefined;
    while (true) {
        const w = std.mem.sliceTo(&data.cFileName, 0);
        if (std.unicode.utf16LeToUtf8(&name_buf, w)) |n| {
            const bare = stripPipeRoot(name_buf[0..n]);
            if (isHolderPipe(prefix, bare)) {
                const full = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\{s}", .{bare});
                errdefer alloc.free(full);
                try out.append(alloc, full);
            }
        } else |_| {}
        if (FindNextFileW(h, &data) == 0) break;
    }
    return out;
}

extern "kernel32" fn FindNextFileW(
    hFindFile: std.os.windows.HANDLE,
    lpFindFileData: *std.os.windows.WIN32_FIND_DATAW,
) callconv(.winapi) std.os.windows.BOOL;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stripPipeRoot: the enumerated form and the recorded form meet in the middle" {
    // `FindFirstFileW` yields bare names; `sessions.json` records full paths.
    // Everything downstream compares one against the other, so this is where
    // the two spellings are reconciled.
    try testing.expectEqualStrings("ghoztty-pty-host-dave-ab", stripPipeRoot("\\\\.\\pipe\\ghoztty-pty-host-dave-ab"));
    try testing.expectEqualStrings("ghoztty-pty-host-dave-ab", stripPipeRoot("ghoztty-pty-host-dave-ab"));
    // Case-insensitive, like the filesystem it names.
    try testing.expectEqualStrings("x", stripPipeRoot("\\\\.\\PIPE\\x"));
    // Not a root, not stripped.
    try testing.expectEqualStrings("\\\\other\\pipe\\x", stripPipeRoot("\\\\other\\pipe\\x"));
}

test "samePipe: case never decides whether a session lives" {
    try testing.expect(samePipe("\\\\.\\pipe\\ghoztty-pty-host-Dave-aa", "\\\\.\\PIPE\\ghoztty-pty-host-dave-AA"));
    try testing.expect(!samePipe("\\\\.\\pipe\\a", "\\\\.\\pipe\\b"));
}

test "isHolderPipe: only OUR family, and only with a real session id" {
    const prefix = "ghoztty-pty-host-debug-dave-";
    const id = "0123456789abcdef0123456789abcdef";
    try testing.expect(isHolderPipe(prefix, prefix ++ id));

    // Another user's holder, another build mode's holder, another product's
    // pipe: all outside this agent's namespace, and reaping one would kill a
    // session that is not ours to end.
    try testing.expect(!isHolderPipe(prefix, "ghoztty-pty-host-debug-sam-" ++ id));
    try testing.expect(!isHolderPipe(prefix, "ghoztty-pty-host-dave-" ++ id));
    try testing.expect(!isHolderPipe(prefix, "chrome.nativeMessaging.in.1234"));

    // The prefix alone is not a holder — there is no session behind it.
    try testing.expect(!isHolderPipe(prefix, prefix));
    // Nor is a name whose id segment the holder itself would have refused.
    try testing.expect(!isHolderPipe(prefix, prefix ++ "not a session id"));

    // Deliberately as permissive as `pty_host.run`'s own check and no more:
    // the hand-driven `--pty-host --session-id` path (the ConPTY smoke) binds
    // short ids, and a sweep that only recognized 32-hex would walk straight
    // past those holders and leak them.
    try testing.expect(isHolderPipe(prefix, prefix ++ "smoke-1"));
}

test "pipePrefix: matches the name the holder actually binds" {
    if (!is_windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    const prefix = try pipePrefix(alloc);
    defer alloc.free(prefix);
    const id = "0123456789abcdef0123456789abcdef";
    const real = try pty_host.defaultPipeName(alloc, id);
    defer alloc.free(real);
    // The classification the sweep does, against a name produced by the code
    // that names holders — so the two cannot drift apart silently.
    try testing.expect(isHolderPipe(prefix, stripPipeRoot(real)));
}
