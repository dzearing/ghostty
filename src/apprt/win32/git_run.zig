//! Running `git` and capturing its stdout, in the one shape the viewer needs
//! (T636 — extracted from `ViewerWorktreeProbe` when the feedback report writer
//! became a second caller).
//!
//! There is deliberately ONE of these. The two flags below are both the kind
//! that are invisible until they are missing, and a second hand-rolled spawn
//! would eventually be missing one of them:
//!
//! - **`create_no_window`.** `git.exe` is a console program and the app is a
//!   GUI-subsystem process, so without it every call flashes a console window
//!   over the user's terminal.
//! - **stderr IGNORED, not piped.** With one pipe there is nothing to
//!   interleave, so the read below cannot deadlock against a second pipe
//!   filling up while nobody drains it.
//!
//! BLOCKING — worker threads only. The viewer's message loop is the one the
//! terminal next door draws on, and a `CreateProcess` on it is a visible
//! stutter in a pane that has nothing to do with the viewer.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Run `argv`, returning its stdout in `buf`. Null when the binary could not be
/// launched at all — the only case worth trying another `git` path for. A git
/// that ran and failed returns its (usually empty) stdout, because "git said
/// no" is an ANSWER: a directory outside a repository, a repository with no
/// commits.
pub fn capture(alloc: Allocator, argv: []const []const u8, buf: []u8) ?[]const u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
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

/// What a diff invocation produced (T463).
pub const Output = struct {
    /// stdout, up to the caller's cap. Owned by the caller.
    bytes: []u8,
    /// git exited 0. A diff caller must NOT treat a non-zero exit as an empty
    /// answer: `git diff nosuchref` prints nothing and fails, and rendering
    /// that as "no changes" is exactly the swallowed error T463 exists to fix.
    ok: bool,
    /// Output past `max` was read and discarded — see below.
    truncated: bool = false,
};

/// Run `argv` and read its stdout **to EOF**, retaining at most `max` bytes.
/// Null when the binary could not be launched at all.
///
/// The fixed-buffer `capture` above cannot serve a diff, and the reason is a
/// deadlock rather than a size limit: a `readAll` that stops on a full buffer
/// leaves git blocked writing into a pipe nobody is draining, and the `wait`
/// that follows then never returns. A whole-repository `--name-status` is
/// routinely megabytes, so that is not a theoretical shape here. Reading to EOF
/// and DISCARDING the overflow keeps the child able to exit no matter how much
/// it wants to say.
///
/// BLOCKING — worker threads only, for the reason in the file header.
pub fn captureAlloc(
    alloc: Allocator,
    argv: []const []const u8,
    max: usize,
) ?Output {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    // A git hook or config that reads the terminal would hang this worker
    // forever, and the pane's teardown JOINS it; this makes any such prompt
    // fail immediately instead. Optional locks off so a read-only diff never
    // fights a concurrent `git` running in a pane next door. (Mac's
    // `ViewerProcess.run` sets the same two.)
    var env = std.process.getEnvMap(alloc) catch return null;
    defer env.deinit();
    env.put("GIT_TERMINAL_PROMPT", "0") catch {};
    env.put("GIT_OPTIONAL_LOCKS", "0") catch {};
    child.env_map = &env;

    child.spawn() catch return null;
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };

    var out: std.ArrayList(u8) = .empty;
    var truncated = false;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = stdout.read(&chunk) catch break;
        if (n == 0) break;
        if (out.items.len >= max) {
            truncated = true;
            continue;
        }
        const take = @min(n, max - out.items.len);
        out.appendSlice(alloc, chunk[0..take]) catch {
            truncated = true;
            continue;
        };
        if (take < n) truncated = true;
    }

    const term = child.wait() catch {
        out.deinit(alloc);
        return null;
    };
    const bytes = out.toOwnedSlice(alloc) catch {
        out.deinit(alloc);
        return null;
    };
    return .{
        .bytes = bytes,
        .ok = term == .Exited and term.Exited == 0,
        .truncated = truncated,
    };
}
