//! Pure color math for the window/pane background tint feature (T67) —
//! platform-free ports of the Mac helpers so the unit tests run in every
//! app-runtime lane (the hero_math.zig pattern):
//!
//!   - hex parsing            (OSColor+Extension.swift `init?(hex:)`)
//!   - Rec.601 luminance      (`isLightColor` / `luminance`)
//!   - HSB lighten/darken     (`lighten(by:)` / `darken(by:)`)
//!   - split tint shift       (BaseTerminalController.shiftedTint)
//!   - contrast foreground    (IPCServer.applyColorScheme)
//!   - WCAG palette adjust    (SurfaceView_AppKit.adjustPaletteForContrast)
//!   - random dark color      (IPCServer.randomDarkColor)
const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// Parse `#rgb` or `#rrggbb` (the only forms the CLI accepts per
/// docs/design/window-color.md). Returns null for anything else.
pub fn parseHex(s: []const u8) ?Rgb {
    if (s.len != 4 and s.len != 7) return null;
    if (s[0] != '#') return null;
    const hex = s[1..];
    if (hex.len == 3) {
        const r = std.fmt.parseInt(u8, hex[0..1], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex[1..2], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex[2..3], 16) catch return null;
        // #abc == #aabbcc
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    return .{
        .r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
        .g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
        .b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
    };
}

/// Format as `#rrggbb` (lowercase) into the caller's buffer.
pub fn hexString(rgb: Rgb, buf: *[7]u8) []const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
        rgb.r, rgb.g, rgb.b,
    }) catch unreachable;
}

/// Rec.601 luminance in 0..1 — the Mac `OSColor.luminance` used for
/// isLightColor and the shift direction.
pub fn luminance(rgb: Rgb) f64 {
    const r = @as(f64, @floatFromInt(rgb.r)) / 255.0;
    const g = @as(f64, @floatFromInt(rgb.g)) / 255.0;
    const b = @as(f64, @floatFromInt(rgb.b)) / 255.0;
    return 0.299 * r + 0.587 * g + 0.114 * b;
}

pub fn isLight(rgb: Rgb) bool {
    return luminance(rgb) > 0.5;
}

/// Black-on-light / white-on-dark foreground (applyColorScheme parity).
pub fn contrastForeground(bg: Rgb) Rgb {
    return if (isLight(bg))
        .{ .r = 0, .g = 0, .b = 0 }
    else
        .{ .r = 255, .g = 255, .b = 255 };
}

pub const Hsb = struct { h: f64, s: f64, b: f64 };

pub fn rgbToHsb(rgb: Rgb) Hsb {
    const r = @as(f64, @floatFromInt(rgb.r)) / 255.0;
    const g = @as(f64, @floatFromInt(rgb.g)) / 255.0;
    const b = @as(f64, @floatFromInt(rgb.b)) / 255.0;
    const hi = @max(r, @max(g, b));
    const lo = @min(r, @min(g, b));
    const delta = hi - lo;

    var h: f64 = 0;
    if (delta > 0) {
        if (hi == r) {
            h = @mod((g - b) / delta, 6.0);
        } else if (hi == g) {
            h = (b - r) / delta + 2.0;
        } else {
            h = (r - g) / delta + 4.0;
        }
        h /= 6.0;
        if (h < 0) h += 1.0;
    }
    return .{ .h = h, .s = if (hi == 0) 0 else delta / hi, .b = hi };
}

pub fn hsbToRgb(hsb: Hsb) Rgb {
    const c = hsb.b * hsb.s;
    const hp = hsb.h * 6.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = hsb.b - c;

    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{
        .r = @intFromFloat(@min(@max((r + m) * 255.0 + 0.5, 0), 255)),
        .g = @intFromFloat(@min(@max((g + m) * 255.0 + 0.5, 0), 255)),
        .b = @intFromFloat(@min(@max((b + m) * 255.0 + 0.5, 0), 255)),
    };
}

/// HSB brightness lighten: `newB = b + (1 - b) * amount` (hue/sat kept).
pub fn lighten(rgb: Rgb, amount: f64) Rgb {
    var hsb = rgbToHsb(rgb);
    hsb.b = @min(hsb.b + (1.0 - hsb.b) * amount, 1.0);
    return hsbToRgb(hsb);
}

/// HSB brightness darken: `newB = b * (1 - amount)` (hue/sat kept).
pub fn darken(rgb: Rgb, amount: f64) Rgb {
    var hsb = rgbToHsb(rgb);
    hsb.b = @min(hsb.b * (1.0 - amount), 1.0);
    return hsbToRgb(hsb);
}

/// Split-inheritance shift (BaseTerminalController.shiftedTint): lighten a
/// dark parent, darken a light one, by 5% brightness. The design doc's
/// worked example uses 15%, but the shipping Mac code uses 0.05 — parity
/// follows the code.
pub const shift_amount: f64 = 0.05;

pub fn shiftedTint(rgb: Rgb) Rgb {
    return if (isLight(rgb))
        darken(rgb, shift_amount)
    else
        lighten(rgb, shift_amount);
}

/// `--color=random`: dark muted color (hue anywhere, sat 0.2–0.3,
/// brightness 0.1–0.15 — IPCServer.randomDarkColor parity).
pub fn randomDark(rand: std.Random) Rgb {
    return hsbToRgb(.{
        .h = rand.float(f64),
        .s = 0.2 + rand.float(f64) * 0.1,
        .b = 0.1 + rand.float(f64) * 0.05,
    });
}

/// The stock ANSI 0–15 palette (src/terminal/color.zig defaults) — the
/// baseline the contrast adjustment starts from, same table the Mac
/// hardcodes in SurfaceView_AppKit.
pub const default_ansi_colors: [16]Rgb = .{
    .{ .r = 0x1D, .g = 0x1F, .b = 0x21 }, // 0: black
    .{ .r = 0xCC, .g = 0x66, .b = 0x66 }, // 1: red
    .{ .r = 0xB5, .g = 0xBD, .b = 0x68 }, // 2: green
    .{ .r = 0xF0, .g = 0xC6, .b = 0x74 }, // 3: yellow
    .{ .r = 0x81, .g = 0xA2, .b = 0xBE }, // 4: blue
    .{ .r = 0xB2, .g = 0x94, .b = 0xBB }, // 5: magenta
    .{ .r = 0x8A, .g = 0xBE, .b = 0xB7 }, // 6: cyan
    .{ .r = 0xC5, .g = 0xC8, .b = 0xC6 }, // 7: white
    .{ .r = 0x66, .g = 0x66, .b = 0x66 }, // 8: bright black
    .{ .r = 0xD5, .g = 0x4E, .b = 0x53 }, // 9: bright red
    .{ .r = 0xB9, .g = 0xCA, .b = 0x4A }, // 10: bright green
    .{ .r = 0xE7, .g = 0xC5, .b = 0x47 }, // 11: bright yellow
    .{ .r = 0x7A, .g = 0xA6, .b = 0xDA }, // 12: bright blue
    .{ .r = 0xC3, .g = 0x97, .b = 0xD8 }, // 13: bright magenta
    .{ .r = 0x70, .g = 0xC0, .b = 0xB1 }, // 14: bright cyan
    .{ .r = 0xEA, .g = 0xEA, .b = 0xEA }, // 15: bright white
};

// --- WCAG relative luminance + contrast (the palette-adjust space; NOT the
// Rec.601 luminance above, which drives isLight/shift decisions) ---

fn srgbLinearize(c: f64) f64 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

pub fn wcagLuminance(rgb: Rgb) f64 {
    const r = srgbLinearize(@as(f64, @floatFromInt(rgb.r)) / 255.0);
    const g = srgbLinearize(@as(f64, @floatFromInt(rgb.g)) / 255.0);
    const b = srgbLinearize(@as(f64, @floatFromInt(rgb.b)) / 255.0);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

pub fn wcagContrastRatio(lum1: f64, lum2: f64) f64 {
    const lighter = @max(lum1, lum2);
    const darker = @min(lum1, lum2);
    return (lighter + 0.05) / (darker + 0.05);
}

// --- CIELAB (perceptual lightness search space for the palette adjust) ---

const Lab = struct {
    l: f64,
    a: f64,
    b: f64,

    fn fromRgb(rgb: Rgb) Lab {
        const rl = srgbLinearize(@as(f64, @floatFromInt(rgb.r)) / 255.0);
        const gl = srgbLinearize(@as(f64, @floatFromInt(rgb.g)) / 255.0);
        const bl = srgbLinearize(@as(f64, @floatFromInt(rgb.b)) / 255.0);

        const e: f64 = 0.008856;
        var x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047;
        var y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750;
        var z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883;
        x = if (x > e) std.math.cbrt(x) else 7.787 * x + 16.0 / 116.0;
        y = if (y > e) std.math.cbrt(y) else 7.787 * y + 16.0 / 116.0;
        z = if (z > e) std.math.cbrt(z) else 7.787 * z + 16.0 / 116.0;

        return .{
            .l = 116.0 * y - 16.0,
            .a = 500.0 * (x - y),
            .b = 200.0 * (y - z),
        };
    }

    fn toSrgb(self: Lab) struct { f64, f64, f64 } {
        const fy = (self.l + 16.0) / 116.0;
        const fx = self.a / 500.0 + fy;
        const fz = fy - self.b / 200.0;

        const e: f64 = 0.008856;
        const fx3 = fx * fx * fx;
        const fy3 = fy * fy * fy;
        const fz3 = fz * fz * fz;
        const xf = (if (fx3 > e) fx3 else (fx - 16.0 / 116.0) / 7.787) * 0.95047;
        const yf = if (fy3 > e) fy3 else (fy - 16.0 / 116.0) / 7.787;
        const zf = (if (fz3 > e) fz3 else (fz - 16.0 / 116.0) / 7.787) * 1.08883;

        var r = xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314;
        var g = -xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560;
        var b = xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252;

        r = if (r > 0.0031308) 1.055 * std.math.pow(f64, r, 1.0 / 2.4) - 0.055 else 12.92 * r;
        g = if (g > 0.0031308) 1.055 * std.math.pow(f64, g, 1.0 / 2.4) - 0.055 else 12.92 * g;
        b = if (b > 0.0031308) 1.055 * std.math.pow(f64, b, 1.0 / 2.4) - 0.055 else 12.92 * b;

        return .{
            @min(@max(r, 0), 1),
            @min(@max(g, 0), 1),
            @min(@max(b, 0), 1),
        };
    }

    fn toRgb(self: Lab) Rgb {
        const r, const g, const b = self.toSrgb();
        return .{
            .r = @intFromFloat(r * 255.0 + 0.5),
            .g = @intFromFloat(g * 255.0 + 0.5),
            .b = @intFromFloat(b * 255.0 + 0.5),
        };
    }
};

pub const contrast_target: f64 = 4.5;

/// One palette entry adjusted for contrast against `bg`: unchanged when it
/// already meets WCAG 4.5, otherwise its L* is binary-searched toward the
/// closest value that does (hue/chroma preserved) — the Mac
/// adjustPaletteForContrast loop body.
pub fn contrastAdjusted(base: Rgb, bg: Rgb) Rgb {
    const bg_lum = wcagLuminance(bg);
    const ratio = wcagContrastRatio(wcagLuminance(base), bg_lum);
    if (ratio >= contrast_target) return base;

    var lab: Lab = .fromRgb(base);
    const bg_is_light = bg_lum > 0.18;

    var lo: f64 = undefined;
    var hi: f64 = undefined;
    if (bg_is_light) {
        lo = 0;
        hi = lab.l;
    } else {
        lo = lab.l;
        hi = 100;
    }
    var best_l: f64 = if (bg_is_light) lo else hi;

    for (0..30) |_| {
        const mid = (lo + hi) / 2.0;
        lab.l = mid;
        const tr, const tg, const tb = lab.toSrgb();
        const test_lum = 0.2126 * srgbLinearize(tr) + 0.7152 * srgbLinearize(tg) + 0.0722 * srgbLinearize(tb);
        if (wcagContrastRatio(test_lum, bg_lum) >= contrast_target) {
            best_l = mid;
            if (bg_is_light) lo = mid else hi = mid;
        } else {
            if (bg_is_light) hi = mid else lo = mid;
        }
    }

    lab.l = best_l;
    return lab.toRgb();
}

/// The full 16-color palette adjusted against `bg`.
pub fn adjustedPalette(bg: Rgb) [16]Rgb {
    var out: [16]Rgb = undefined;
    for (default_ansi_colors, 0..) |base, i| out[i] = contrastAdjusted(base, bg);
    return out;
}

// -----------------------------------------------------------------------------

const testing = std.testing;

test "parseHex: #rrggbb and #rgb" {
    try testing.expectEqual(Rgb{ .r = 0x33, .g = 0x44, .b = 0x55 }, parseHex("#334455").?);
    try testing.expectEqual(Rgb{ .r = 0xFF, .g = 0x00, .b = 0xAB }, parseHex("#ff00ab").?);
    try testing.expectEqual(Rgb{ .r = 0xFF, .g = 0x00, .b = 0xAB }, parseHex("#FF00AB").?);
    // #abc expands per-digit: a→aa, b→bb, c→cc.
    try testing.expectEqual(Rgb{ .r = 0xAA, .g = 0xBB, .b = 0xCC }, parseHex("#abc").?);
    try testing.expectEqual(Rgb{ .r = 0x00, .g = 0x00, .b = 0x00 }, parseHex("#000").?);
}

test "parseHex: rejects malformed input" {
    for ([_][]const u8{ "", "#", "334455", "#33445", "#3344556", "#zzz", "#gg0000", "random", "#12 45 6" }) |bad| {
        try testing.expectEqual(@as(?Rgb, null), parseHex(bad));
    }
}

test "hexString round-trips parseHex" {
    var buf: [7]u8 = undefined;
    try testing.expectEqualStrings("#334455", hexString(.{ .r = 0x33, .g = 0x44, .b = 0x55 }, &buf));
    try testing.expectEqualStrings("#0a0b0c", hexString(.{ .r = 10, .g = 11, .b = 12 }, &buf));
    const c: Rgb = .{ .r = 0xDE, .g = 0xAD, .b = 0x00 };
    try testing.expectEqual(c, parseHex(hexString(c, &buf)).?);
}

test "isLight: Rec.601 threshold" {
    try testing.expect(!isLight(.{ .r = 0x1D, .g = 0x1F, .b = 0x21 }));
    try testing.expect(isLight(.{ .r = 0xFF, .g = 0xFF, .b = 0xFF }));
    try testing.expect(!isLight(.{ .r = 0x00, .g = 0x00, .b = 0xFF })); // pure blue is dark
    try testing.expect(isLight(.{ .r = 0x00, .g = 0xFF, .b = 0x00 })); // pure green is light
}

test "contrastForeground: black on light, white on dark" {
    try testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, contrastForeground(.{ .r = 0x10, .g = 0x10, .b = 0x20 }));
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, contrastForeground(.{ .r = 0xF0, .g = 0xF0, .b = 0xE0 }));
}

test "rgb<->hsb round-trip" {
    const cases = [_]Rgb{
        .{ .r = 0x33, .g = 0x44, .b = 0x55 },
        .{ .r = 0xFF, .g = 0x00, .b = 0x00 },
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0x12, .g = 0xEF, .b = 0x7A },
        .{ .r = 0x80, .g = 0x80, .b = 0x80 },
    };
    for (cases) |c| {
        const rt = hsbToRgb(rgbToHsb(c));
        // ±1 per channel: 8-bit HSB round-trips within a rounding step.
        try testing.expect(@abs(@as(i16, rt.r) - @as(i16, c.r)) <= 1);
        try testing.expect(@abs(@as(i16, rt.g) - @as(i16, c.g)) <= 1);
        try testing.expect(@abs(@as(i16, rt.b) - @as(i16, c.b)) <= 1);
    }
}

test "shiftedTint: dark parents lighten, light parents darken, hue/sat kept" {
    const dark: Rgb = .{ .r = 0x33, .g = 0x44, .b = 0x55 };
    const shifted = shiftedTint(dark);
    try testing.expect(luminance(shifted) > luminance(dark));
    const hsb_in = rgbToHsb(dark);
    const hsb_out = rgbToHsb(shifted);
    try testing.expect(@abs(hsb_in.h - hsb_out.h) < 0.02);
    try testing.expect(@abs(hsb_in.s - hsb_out.s) < 0.02);

    const light: Rgb = .{ .r = 0xEE, .g = 0xEE, .b = 0xDD };
    try testing.expect(luminance(shiftedTint(light)) < luminance(light));

    // Exact expected value, doubling as the validation script's oracle:
    // HSB(0.5833, 0.4, 0.3333) lightened to brightness 0.3667 → #384b5e.
    try testing.expectEqual(Rgb{ .r = 0x38, .g = 0x4b, .b = 0x5e }, shifted);
}

test "shiftedTint: pure black still lightens" {
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const shifted = shiftedTint(black);
    try testing.expect(shifted.r > 0 and shifted.g > 0 and shifted.b > 0);
}

test "randomDark: always dark and muted" {
    var prng = std.Random.DefaultPrng.init(0x7667);
    const rand = prng.random();
    for (0..100) |_| {
        const c = randomDark(rand);
        try testing.expect(!isLight(c));
        const hsb = rgbToHsb(c);
        try testing.expect(hsb.b <= 0.16);
    }
}

test "contrastAdjusted: passing colors unchanged" {
    // Bright white on near-black already exceeds 4.5:1.
    const bg: Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x14 };
    const white: Rgb = .{ .r = 0xEA, .g = 0xEA, .b = 0xEA };
    try testing.expectEqual(white, contrastAdjusted(white, bg));
}

test "contrastAdjusted: failing colors reach the 4.5 target" {
    // ANSI black (0x1D1F21) on a near-black bg fails badly and must be
    // lightened until it hits 4.5:1.
    const bg: Rgb = .{ .r = 0x10, .g = 0x10, .b = 0x14 };
    const adjusted = contrastAdjusted(default_ansi_colors[0], bg);
    const ratio = wcagContrastRatio(wcagLuminance(adjusted), wcagLuminance(bg));
    try testing.expect(ratio >= contrast_target - 0.1);

    // Light background: dark colors that pass stay, light ones darken.
    const light_bg: Rgb = .{ .r = 0xF5, .g = 0xF5, .b = 0xF0 };
    const bright_white = contrastAdjusted(default_ansi_colors[15], light_bg);
    const wr = wcagContrastRatio(wcagLuminance(bright_white), wcagLuminance(light_bg));
    try testing.expect(wr >= contrast_target - 0.1);
    try testing.expect(luminance(bright_white) < luminance(default_ansi_colors[15]));
}

test "adjustedPalette: all 16 meet the target against both extremes" {
    for ([_]Rgb{
        .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .{ .r = 0x33, .g = 0x44, .b = 0x55 },
    }) |bg| {
        const bg_lum = wcagLuminance(bg);
        for (adjustedPalette(bg)) |c| {
            const ratio = wcagContrastRatio(wcagLuminance(c), bg_lum);
            try testing.expect(ratio >= contrast_target - 0.1);
        }
    }
}
