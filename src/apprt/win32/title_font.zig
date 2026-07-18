//! Pure logic for resolving the `window-title-font-family` config into a
//! GDI face name (T78). No OS imports, so its unit tests run in every
//! app-runtime lane (the hero_math/dim_math pattern).
//!
//! On Windows the DWM caption of a standard-frame window always draws with
//! the system caption font, so this config applies where the app itself
//! renders titles: the owner-drawn tab bar (and the resize overlay, which
//! shares the font). GDI maps unknown face names to a fallback font, so no
//! validation beyond UTF-8 sanity is needed here.

const std = @import("std");

/// GDI LF_FACESIZE: face names are capped at 32 u16s including the
/// terminator. CreateFontW ignores longer names entirely (you get a stock
/// font), so truncating beats passing an overlong name through.
pub const face_cap = 32;

/// The face used when the config is unset, empty, or not valid UTF-8.
pub const default_face = "Segoe UI";

/// Resolve the config value into a null-terminated UTF-16 face name for
/// CreateFontW. Truncates to LF_FACESIZE-1 code units without splitting a
/// surrogate pair.
pub fn faceName(family: ?[]const u8, out: *[face_cap]u16) void {
    @memset(out, 0);
    const chosen: []const u8 = pick: {
        const f = family orelse break :pick default_face;
        if (f.len == 0) break :pick default_face;
        if (!std.unicode.utf8ValidateSlice(f)) break :pick default_face;
        break :pick f;
    };
    var it = std.unicode.Utf8View.initUnchecked(chosen).iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            if (n >= face_cap - 1) break;
            out[n] = @intCast(cp);
            n += 1;
        } else {
            if (n + 2 > face_cap - 1) break;
            const v: u21 = cp - 0x10000;
            out[n] = @intCast(0xD800 + (v >> 10));
            out[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
    }
}

fn expectFace(expected: []const u8, family: ?[]const u8) !void {
    var out: [face_cap]u16 = undefined;
    faceName(family, &out);
    var exp: [face_cap]u16 = [_]u16{0} ** face_cap;
    _ = try std.unicode.utf8ToUtf16Le(exp[0 .. face_cap - 1], expected);
    try std.testing.expectEqualSlices(u16, &exp, &out);
}

test "faceName: unset falls back to Segoe UI" {
    try expectFace(default_face, null);
}

test "faceName: empty falls back to Segoe UI" {
    try expectFace(default_face, "");
}

test "faceName: explicit family passes through" {
    try expectFace("Cascadia Code", "Cascadia Code");
}

test "faceName: invalid UTF-8 falls back to Segoe UI" {
    try expectFace(default_face, "\xff\xfe bad");
}

test "faceName: overlong name truncates to LF_FACESIZE-1 units" {
    const long = "A really quite excessively long font family name";
    var out: [face_cap]u16 = undefined;
    faceName(long, &out);
    try std.testing.expectEqual(@as(u16, 0), out[face_cap - 1]);
    // 31 BMP chars kept, terminator at 31.
    var i: usize = 0;
    while (i < face_cap - 1) : (i += 1) {
        try std.testing.expectEqual(@as(u16, long[i]), out[i]);
    }
}

test "faceName: truncation never splits a surrogate pair" {
    // 30 ASCII chars then an astral codepoint: only 1 unit of space is
    // left, so the pair must be dropped whole.
    var name: [34]u8 = undefined;
    @memset(name[0..30], 'x');
    @memcpy(name[30..34], "\u{1F600}"); // 4 UTF-8 bytes, 2 UTF-16 units
    var out: [face_cap]u16 = undefined;
    faceName(&name, &out);
    try std.testing.expectEqual(@as(u16, 'x'), out[29]);
    try std.testing.expectEqual(@as(u16, 0), out[30]);
    try std.testing.expectEqual(@as(u16, 0), out[31]);
}
