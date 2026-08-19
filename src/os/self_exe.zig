//! Our own executable path, for the callers whose very next move is to LAUNCH
//! it: the ConPTY holder (`--pty-host`), the relaunch guard, the auto-launched
//! second instance, the agent re-registering its own command line.
//!
//! Those callers all reach for `std.fs.selfExePath`, and inside a TEST binary
//! that answer is a trap. "Our own executable" is then `ghoztty-agent-test.exe`
//! or `ghostty-test.exe` — a zig TEST RUNNER, not the product — so spawning it
//! does not start a holder, a guard or an app. It starts a copy of the test
//! suite, detached, and (because every one of these spawns deliberately escapes
//! the caller's kill-on-close job, which is the point of them) OUTSIDE anything
//! that would take it down with the lane that made it.
//!
//! Measured (T933, 2026-08-19): the agent lane's `PtySpawner` test spawned
//! `ghoztty-agent-test.exe --pty-host --spec …` through the shell-parent hop,
//! reparented to explorer.exe. That copy panics on the unrecognized argument
//! and usually dies in ~3s — but nothing waits for it, and the copies that do
//! NOT die quickly are what turned a 17.6-minute floor run into 61 minutes of
//! wall clock: test binaries alive 40+ minutes after their lane printed PASS,
//! burning a core each and hosting a tree of `msedgewebview2.exe` children. A
//! self-spawn whose argv the runner happens to ACCEPT is worse still: no args
//! at all runs the whole suite again (which re-runs the spawn), and the build
//! runner's own `--listen=-` leaves a copy blocked on a pipe forever.
//!
//! So the rule is structural rather than remembered: a test build has no
//! product exe to launch, and asking for one is an error every caller already
//! knows how to handle — they fall back, degrade or skip exactly as they do
//! when the spawn itself fails. Nothing here changes what the product does;
//! `builtin.is_test` is false in every shipped binary.
//!
//! Use `std.fs.selfExePath` directly when the path is being READ rather than
//! launched (locating a sibling resource, naming ourselves in a log, comparing
//! install lineage) — a test binary's answer is perfectly good for that.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// This is a test binary: there is no product executable to launch, and
    /// launching *this* one would start a second copy of the test suite.
    SelfSpawnFromTestBinary,
};

/// The product executable to spawn, allocated. Caller frees.
pub fn productExePathAlloc(alloc: Allocator) ![]u8 {
    if (comptime builtin.is_test) return Error.SelfSpawnFromTestBinary;
    return try std.fs.selfExePathAlloc(alloc);
}

/// The product executable to spawn, into a caller-owned buffer.
pub fn productExePath(buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (comptime builtin.is_test) return Error.SelfSpawnFromTestBinary;
    return try std.fs.selfExePath(buf);
}

const testing = std.testing;

test "productExePathAlloc: a test binary is never handed its own path to spawn" {
    // The whole guard: this runs INSIDE a test binary, so the answer must be
    // the error rather than a path a caller would then CreateProcess.
    try testing.expectError(
        Error.SelfSpawnFromTestBinary,
        productExePathAlloc(testing.allocator),
    );
}

test "productExePath: the buffer form refuses on the same rule" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(Error.SelfSpawnFromTestBinary, productExePath(&buf));
}

test "the refusal is its own error, so a caller can tell it from a real failure" {
    // A caller that reported "could not resolve our own exe" for an OOM and for
    // this would send the next reader hunting a bug that is not there.
    if (productExePathAlloc(testing.allocator)) |p| {
        testing.allocator.free(p);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == Error.SelfSpawnFromTestBinary);
    }
}
