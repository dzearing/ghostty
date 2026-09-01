//! What the graphics stack said about itself, captured when the GL context
//! loaded (T1224).
//!
//! THE DEFECT this exists for: on a machine reached over Remote Desktop, the
//! display driver hands applications a minimal OpenGL — classically 1.1,
//! "GDI Generic" — because the desktop is encoded and shipped over the wire
//! rather than scanned out of a GPU. Ghoztty requires OpenGL 4.3, so it
//! refused to start, and the only thing the user was told was
//! `Error: OpenGLOutdated` followed by "reinstall it". Reinstalling cannot
//! change a display driver, so the one remedy offered was the one remedy that
//! could not work.
//!
//! Fixing that needs two facts to travel from the renderer, which discovers
//! them, to the startup dialog, which is the only thing the user reads: WHICH
//! OpenGL this display actually offers, and WHICH one Ghoztty needs. This
//! module is where they meet. It is a leaf — nothing but `std` — precisely so
//! that `apprt/win32/startup_error.zig` can read it without importing the
//! renderer, and so that the version floor has ONE definition rather than a
//! constant in the renderer and a number retyped into a sentence.
//!
//! It deliberately holds no allocator and no pointers into GL memory: the
//! strings are copied into fixed buffers at capture time, because the reader
//! is a fatal-error path that runs after the GL context has already been given
//! up on.

const std = @import("std");

/// The OpenGL version the renderer requires. The single definition:
/// `renderer/OpenGL.zig` aliases these, and the startup dialog formats them
/// into its message, so a bump cannot leave a stale number in the text a user
/// reads.
pub const min_version_major = 4;
pub const min_version_minor = 3;

/// Longest vendor/renderer string we keep. Real ones are short ("GDI Generic",
/// "NVIDIA GeForce RTX 4080"); a driver that returns an essay gets truncated
/// rather than a bigger buffer, since this ends up in a dialog either way.
pub const max_string = 96;

/// A fixed-capacity string, copied rather than borrowed. See the module note:
/// the reader runs after the context is gone.
pub const Str = struct {
    buf: [max_string]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Str) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Str, text: []const u8) void {
        const n = @min(text.len, max_string);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }

    pub fn of(text: []const u8) Str {
        var s: Str = .{};
        s.set(text);
        return s;
    }
};

/// What one loaded GL context turned out to be.
pub const Report = struct {
    major: u32 = 0,
    minor: u32 = 0,
    vendor: Str = .{},
    renderer: Str = .{},

    /// True when this context cannot run Ghoztty's renderer.
    pub fn belowFloor(self: Report) bool {
        return self.major < min_version_major or
            (self.major == min_version_major and self.minor < min_version_minor);
    }
};

var mutex: std.Thread.Mutex = .{};
var current: ?Report = null;

/// Record what a context load found. Called from the renderer thread; read
/// from whichever thread is putting the dialog up, hence the mutex.
pub fn record(report: Report) void {
    mutex.lock();
    defer mutex.unlock();
    current = report;
}

/// The last recorded context, or null when no context ever loaded far enough
/// to say anything (which is itself worth distinguishing: "your display offers
/// 1.1" and "we never got an answer" are different sentences).
pub fn get() ?Report {
    mutex.lock();
    defer mutex.unlock();
    return current;
}

/// Forget the recorded context. Tests only — the app records once and keeps it.
pub fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    current = null;
}

/// One plain sentence naming what the display actually offers, written into
/// `buf`. Empty when nothing was ever recorded, so a caller can simply omit
/// the line rather than print "OpenGL 0.0".
///
/// Pure, and takes the report rather than reading the global, so the wording
/// is testable without a GL context anywhere in sight.
pub fn describeDisplay(buf: []u8, report: Report) []const u8 {
    if (report.major == 0) return "";

    const name = report.renderer.slice();
    const vendor = report.vendor.slice();

    if (name.len > 0 and vendor.len > 0) {
        return std.fmt.bufPrint(
            buf,
            "This display offers OpenGL {d}.{d} ({s}, {s}).",
            .{ report.major, report.minor, name, vendor },
        ) catch "";
    }
    if (name.len > 0) {
        return std.fmt.bufPrint(
            buf,
            "This display offers OpenGL {d}.{d} ({s}).",
            .{ report.major, report.minor, name },
        ) catch "";
    }
    return std.fmt.bufPrint(
        buf,
        "This display offers OpenGL {d}.{d}.",
        .{ report.major, report.minor },
    ) catch "";
}

test "belowFloor: the RDP case is below, a modern GPU is not" {
    const testing = std.testing;
    try testing.expect((Report{ .major = 1, .minor = 1 }).belowFloor());
    try testing.expect((Report{ .major = 4, .minor = 2 }).belowFloor());
    try testing.expect((Report{ .major = 3, .minor = 3 }).belowFloor());
    try testing.expect(!(Report{ .major = 4, .minor = 3 }).belowFloor());
    try testing.expect(!(Report{ .major = 4, .minor = 6 }).belowFloor());
}

test "describeDisplay: names the version and who is providing it" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const text = describeDisplay(&buf, .{
        .major = 1,
        .minor = 1,
        .vendor = Str.of("Microsoft Corporation"),
        .renderer = Str.of("GDI Generic"),
    });
    try testing.expect(std.mem.indexOf(u8, text, "OpenGL 1.1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "GDI Generic") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Microsoft Corporation") != null);
}

test "describeDisplay: a driver that names nothing still yields a version" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const text = describeDisplay(&buf, .{ .major = 2, .minor = 0 });
    try testing.expectEqualStrings("This display offers OpenGL 2.0.", text);
}

test "describeDisplay: nothing recorded yields nothing, never OpenGL 0.0" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", describeDisplay(&buf, .{}));
}

test "describeDisplay: a buffer too small yields empty, never a panic" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("", describeDisplay(&buf, .{ .major = 4, .minor = 6 }));
}

test "Str: an overlong driver name truncates instead of overflowing" {
    const testing = std.testing;
    const long = "x" ** (max_string * 2);
    const s = Str.of(long);
    try testing.expectEqual(max_string, s.slice().len);
}

test "record/get: what the renderer found is what the dialog reads" {
    const testing = std.testing;
    reset();
    try testing.expect(get() == null);
    record(.{ .major = 1, .minor = 1, .renderer = Str.of("GDI Generic") });
    const got = get().?;
    try testing.expectEqual(@as(u32, 1), got.major);
    try testing.expectEqualStrings("GDI Generic", got.renderer.slice());
    reset();
}
