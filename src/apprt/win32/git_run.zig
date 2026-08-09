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
