//! Tab accent colors (T72) — the win32 port of the Mac tab color tags
//! (macos/Sources/Features/Terminal/TerminalTabColor.swift): 10 named
//! values a user can assign to a tab from its context menu. Pure logic
//! only (color table, menu labels, swatch pixel rendering) so the unit
//! tests run in every app-runtime lane (the hero_math/dim_math pattern);
//! the GDI/menu plumbing lives in Window.zig.
const std = @import("std");
const Rgb = @import("color_math.zig").Rgb;

const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// Mirror of the Mac `TerminalTabColor` enum, same order (the raw values
/// double as menu-command offsets).
pub const TabColor = enum(u8) {
    none,
    blue,
    purple,
    pink,
    red,
    orange,
    yellow,
    green,
    teal,
    graphite,
};

pub const count = std.meta.fields(TabColor).len;

/// Display color, or null for `.none`. The values are the macOS *dark*
/// system-color variants — the win32 tab bar is dark-themed, and these
/// stay vibrant on it (the Mac side uses NSColor.systemBlue etc., which
/// resolve to these in dark appearance).
pub fn rgb(c: TabColor) ?Rgb {
    return switch (c) {
        .none => null,
        .blue => .{ .r = 10, .g = 132, .b = 255 },
        .purple => .{ .r = 191, .g = 90, .b = 242 },
        .pink => .{ .r = 255, .g = 55, .b = 95 },
        .red => .{ .r = 255, .g = 69, .b = 58 },
        .orange => .{ .r = 255, .g = 159, .b = 10 },
        .yellow => .{ .r = 255, .g = 214, .b = 10 },
        .green => .{ .r = 48, .g = 209, .b = 88 },
        .teal => .{ .r = 102, .g = 212, .b = 207 },
        .graphite => .{ .r = 152, .g = 152, .b = 157 },
    };
}

/// Menu label, matching the Mac localizedName strings.
pub fn labelW(c: TabColor) [:0]const u16 {
    return switch (c) {
        .none => W("None"),
        .blue => W("Blue"),
        .purple => W("Purple"),
        .pink => W("Pink"),
        .red => W("Red"),
        .orange => W("Orange"),
        .yellow => W("Yellow"),
        .green => W("Green"),
        .teal => W("Teal"),
        .graphite => W("Graphite"),
    };
}

/// Render a menu swatch into a size×size 32bpp premultiplied-ARGB pixel
/// buffer (0xAARGGBB u32s, top-down row order — the layout of a 32-bit
/// CreateDIBSection with negative biHeight). A color renders as an
/// anti-aliased filled circle; `.none` (null rgb) renders the Mac "none"
/// glyph: a thin gray ring with a diagonal slash.
pub fn writeSwatch(pixels: []u32, size: usize, color: ?Rgb) void {
    std.debug.assert(pixels.len >= size * size);
    @memset(pixels[0 .. size * size], 0);
    if (size < 4) return;

    const fsize: f32 = @floatFromInt(size);
    const c = (fsize - 1.0) / 2.0; // center (both axes)
    const radius = fsize / 2.0 - 1.5;
    const ring_gray = Rgb{ .r = 150, .g = 150, .b = 150 };

    for (0..size) |y| {
        for (0..size) |x| {
            const dx = @as(f32, @floatFromInt(x)) - c;
            const dy = @as(f32, @floatFromInt(y)) - c;
            const dist = @sqrt(dx * dx + dy * dy);

            var cov: f32 = 0;
            var col: Rgb = undefined;
            if (color) |fill| {
                // Filled disc, 1px anti-aliased edge.
                cov = std.math.clamp(radius - dist + 0.5, 0.0, 1.0);
                col = fill;
            } else {
                // Ring stroke (~1.2px) …
                const ring = std.math.clamp(
                    0.6 - @abs(dist - radius) + 0.5,
                    0.0,
                    1.0,
                );
                // … plus a diagonal slash through the disc (the Mac
                // swatch's bottom-left → top-right line).
                const slash_d = @abs(dx + dy) / std.math.sqrt2;
                var slash = std.math.clamp(0.6 - slash_d + 0.5, 0.0, 1.0);
                if (dist > radius) slash = 0; // clip to the disc
                cov = @max(ring, slash);
                col = ring_gray;
            }

            if (cov <= 0) continue;
            const a: u32 = @intFromFloat(@round(cov * 255.0));
            // Premultiplied channels.
            const r: u32 = @intFromFloat(@round(cov * @as(f32, @floatFromInt(col.r))));
            const g: u32 = @intFromFloat(@round(cov * @as(f32, @floatFromInt(col.g))));
            const b: u32 = @intFromFloat(@round(cov * @as(f32, @floatFromInt(col.b))));
            pixels[y * size + x] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
}

test "rgb: none is null, colors match the Mac dark palette" {
    try std.testing.expect(rgb(.none) == null);
    try std.testing.expect(rgb(.blue).?.eql(.{ .r = 10, .g = 132, .b = 255 }));
    try std.testing.expect(rgb(.graphite).?.eql(.{ .r = 152, .g = 152, .b = 157 }));
    // Every non-none color resolves.
    inline for (comptime std.meta.tags(TabColor)) |c| {
        if (c != .none) try std.testing.expect(rgb(c) != null);
    }
}

test "writeSwatch: color disc — opaque center, transparent corners" {
    const size = 16;
    var px: [size * size]u32 = undefined;
    writeSwatch(&px, size, rgb(.red));

    // Center pixel: fully opaque, exact premultiplied color.
    const center = px[8 * size + 8];
    try std.testing.expectEqual(@as(u32, 0xFF), center >> 24);
    try std.testing.expectEqual(@as(u32, 255), (center >> 16) & 0xFF);
    try std.testing.expectEqual(@as(u32, 69), (center >> 8) & 0xFF);
    try std.testing.expectEqual(@as(u32, 58), center & 0xFF);

    // Corners: fully transparent.
    try std.testing.expectEqual(@as(u32, 0), px[0]);
    try std.testing.expectEqual(@as(u32, 0), px[size - 1]);
    try std.testing.expectEqual(@as(u32, 0), px[(size - 1) * size]);
    try std.testing.expectEqual(@as(u32, 0), px[size * size - 1]);

    // Premultiplied invariant: every channel <= alpha.
    for (px) |p| {
        const a = p >> 24;
        try std.testing.expect((p >> 16) & 0xFF <= a);
        try std.testing.expect((p >> 8) & 0xFF <= a);
        try std.testing.expect(p & 0xFF <= a);
    }
}

test "writeSwatch: none glyph — ring and slash present, fill absent" {
    const size = 16;
    var px: [size * size]u32 = undefined;
    writeSwatch(&px, size, null);

    // Slash passes through the center → center is painted.
    try std.testing.expect(px[8 * size + 8] != 0);
    // Ring: a pixel at the top of the circle (x=center col, y≈1) is painted.
    try std.testing.expect(px[1 * size + 7] != 0 or px[1 * size + 8] != 0);
    // Interior off the ring and off the slash stays empty: (4,4) has
    // dist≈4.95 (ring at 6.5±1.1) and slash distance ≈4.95 — both zero.
    try std.testing.expectEqual(@as(u32, 0), px[4 * size + 4]);
    // Corners transparent.
    try std.testing.expectEqual(@as(u32, 0), px[0]);
}

test "writeSwatch: tiny buffer is cleared, no crash" {
    var px: [9]u32 = .{0xDEADBEEF} ** 9;
    writeSwatch(&px, 3, rgb(.blue));
    for (px) |p| try std.testing.expectEqual(@as(u32, 0), p);
}
