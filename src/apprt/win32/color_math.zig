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
///
/// The side is chosen by WCAG contrast against `bg`, NOT by `isLight`: the
/// two disagree across a band of mid-tones where the Rec.601 answer lands
/// UNDER the 4.5:1 text floor (#777777 reads "dark", so Rec.601 picks white
/// at 4.42:1, while black gives 4.76:1). Choosing the better side is
/// self-correcting for every one of the 16.7M colors the picker accepts:
/// the worst case is the crossover background where both sides are equal,
/// and there both are 4.58:1. See the sweep test below.
pub fn contrastForeground(bg: Rgb) Rgb {
    const bg_lum = wcagLuminance(bg);
    const on_black = wcagContrastRatio(0.0, bg_lum);
    const on_white = wcagContrastRatio(1.0, bg_lum);
    return if (on_black > on_white)
        .{ .r = 0, .g = 0, .b = 0 }
    else
        .{ .r = 255, .g = 255, .b = 255 };
}

/// Composite white (over a dark background) or black (over a light one) at
/// alpha `a` — "a wash", the one primitive every layered win32 chrome surface
/// is built from: the banner card's fill, a tab's inactive/hovered lift, and
/// the tab bar's own band.
///
/// This is an ALPHA COMPOSITE, not `lighten`/`darken` above: those are HSB
/// brightness moves that preserve saturation and so land on a different color
/// than Mac's `Color.white.opacity(a)` over the same backdrop.
///
/// It lives HERE because three call sites had privately reimplemented it
/// (`banner_card.fillColor`, `tab_shape.lift`, and — as `bg + 20` per channel
/// — `Window.paintTabBar`), and the third one got it wrong: a per-channel add
/// clamps toward white on a light background instead of darkening, so the bar,
/// its hover and the active tab all converge on the same near-white. That is
/// T203's root cause #2, and the fix that lasts is one implementation, not
/// three careful ones (the T257 lesson: four copies meant four chances to be
/// wrong and no way to notice).
pub fn wash(bg: Rgb, a: f32) Rgb {
    const toward: f32 = if (isLight(bg)) 0.0 else 255.0;
    return .{
        .r = washChannel(bg.r, toward, a),
        .g = washChannel(bg.g, toward, a),
        .b = washChannel(bg.b, toward, a),
    };
}

fn washChannel(c: u8, toward: f32, a: f32) u8 {
    const v: f32 = @floatFromInt(c);
    return @intFromFloat(std.math.clamp(@round(v + (toward - v) * a), 0.0, 255.0));
}

/// Alpha-composite `fg` over `bg` at `alpha`. The sibling of `wash`: `wash`
/// picks its own destination from the background's luminance, `mix` is told
/// one. GDI has no alpha for flat fills, so every such blend is resolved up
/// front and drawn as an opaque color.
///
/// Hoisted here in T305 for the same reason `wash` was in T304 — it was a
/// private copy in `chooser_rows.blend`, and the carousel needed a second one.
pub fn mix(bg: Rgb, fg: Rgb, alpha: f64) Rgb {
    const a = std.math.clamp(alpha, 0.0, 1.0);
    return .{
        .r = mixChannel(bg.r, fg.r, a),
        .g = mixChannel(bg.g, fg.g, a),
        .b = mixChannel(bg.b, fg.b, a),
    };
}

fn mixChannel(bg: u8, fg: u8, a: f64) u8 {
    const v = @as(f64, @floatFromInt(bg)) * (1.0 - a) + @as(f64, @floatFromInt(fg)) * a;
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
}

test "mix: the endpoints are the endpoints, and the midpoint is between them" {
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    try testing.expectEqual(black, mix(black, white, 0.0));
    try testing.expectEqual(white, mix(black, white, 1.0));
    try testing.expectEqual(Rgb{ .r = 128, .g = 128, .b = 128 }, mix(black, white, 0.5));
    // Out-of-range alphas clamp rather than wrap a channel.
    try testing.expectEqual(black, mix(black, white, -1.0));
    try testing.expectEqual(white, mix(black, white, 2.0));
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

/// `--color=random`: dark muted color (hue anywhere, sat 0.33–0.46,
/// brightness 0.13–0.18 — IPCServer.randomDarkColor parity).
///
/// The floors were raised from 0.2–0.3 / 0.1–0.15 for the same reason Mac
/// raised them (IPCServer.swift `randomDarkColor`): the old ranges landed
/// every window on the same near-black and the hue was imperceptible, so
/// `--color=random` produced tints you could not tell apart. What actually
/// carries the hue is the CHROMA — `max - min` channel, which is `b * s * 255`
/// — and the old ranges capped it at ~11/255 while typically sitting near 8.
/// These keep windows comfortably dark but lift them off pure black.
pub const random_dark_sat_min: f64 = 0.33;
pub const random_dark_sat_max: f64 = 0.46;
pub const random_dark_bri_min: f64 = 0.13;
pub const random_dark_bri_max: f64 = 0.18;

pub fn randomDark(rand: std.Random) Rgb {
    return hsbToRgb(.{
        .h = rand.float(f64),
        .s = random_dark_sat_min + rand.float(f64) * (random_dark_sat_max - random_dark_sat_min),
        .b = random_dark_bri_min + rand.float(f64) * (random_dark_bri_max - random_dark_bri_min),
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
    return contrastAdjustedTo(base, bg, contrast_target);
}

/// `contrastAdjusted` against an arbitrary floor. The palette work wants the
/// 4.5 text ratio; chrome glyphs and meaningful boundaries want WCAG 1.4.11's
/// 3.0 (the win32 design system's §"contrast floors"), and the accent has to
/// stay recognizably the user's color, which a 4.5 search would push past.
/// One search, two floors — a second copy tuned to 3.0 is how the two answers
/// start disagreeing about what "hue-preserving" means.
pub fn contrastAdjustedTo(base: Rgb, bg: Rgb, target: f64) Rgb {
    const bg_lum = wcagLuminance(bg);
    const ratio = wcagContrastRatio(wcagLuminance(base), bg_lum);
    if (ratio >= target) return base;

    // Move away from the background first (darker on a light background),
    // then try the other side, and only then give up on the hue. A
    // hue-preserving L* move can miss the target on BOTH sides: a
    // saturated color clamps against the sRGB gamut long before its
    // luminance gets where it needs to be, and against a mid-tone
    // background neither direction has the room. Returning the best-effort
    // (still-failing) color there is how an under-contrast palette entry
    // survives a "contrast-adjusted" palette — so fall back to plain
    // black/white, which always clears the floor. Same order of preference
    // as `contrasted_color` in the shaders.
    const bg_is_light = bg_lum > 0.18;
    if (searchLightness(base, bg_lum, bg_is_light, target)) |c| return c;
    if (searchLightness(base, bg_lum, !bg_is_light, target)) |c| return c;
    return contrastForeground(bg);
}

/// Binary-search `base`'s CIELAB lightness toward black (`darker`) or white,
/// hue and chroma preserved, for the SMALLEST change that clears
/// `contrast_target` against `bg_lum`. Null when even the endpoint of that
/// direction misses the target, which is the caller's cue to try elsewhere.
fn searchLightness(base: Rgb, bg_lum: f64, darker: bool, target: f64) ?Rgb {
    var lab: Lab = .fromRgb(base);
    const base_l = lab.l;
    const endpoint: f64 = if (darker) 0 else 100;

    // The endpoint bounds what this direction can do, so it decides
    // reachability up front — a binary search converging toward it never
    // evaluates it, and would otherwise report its last (failing) probe as
    // a success.
    lab.l = endpoint;
    if (ratioAgainst(lab, bg_lum) < target) return null;

    var lo: f64 = if (darker) endpoint else base_l;
    var hi: f64 = if (darker) base_l else endpoint;
    var best_l: f64 = endpoint;

    for (0..30) |_| {
        const mid = (lo + hi) / 2.0;
        lab.l = mid;
        if (ratioAgainst(lab, bg_lum) >= target) {
            best_l = mid;
            if (darker) lo = mid else hi = mid;
        } else {
            if (darker) hi = mid else lo = mid;
        }
    }

    lab.l = best_l;
    return lab.toRgb();
}

/// WCAG contrast of a Lab color against an already-computed background
/// luminance. Works off `toSrgb` (not `toRgb`) so gamut clamping is seen
/// but 8-bit quantization is not.
fn ratioAgainst(lab: Lab, bg_lum: f64) f64 {
    const r, const g, const b = lab.toSrgb();
    const lum = 0.2126 * srgbLinearize(r) +
        0.7152 * srgbLinearize(g) +
        0.0722 * srgbLinearize(b);
    return wcagContrastRatio(lum, bg_lum);
}

/// The full 16-color palette adjusted against `bg`.
pub fn adjustedPalette(bg: Rgb) [16]Rgb {
    var out: [16]Rgb = undefined;
    for (default_ansi_colors, 0..) |base, i| out[i] = contrastAdjusted(base, bg);
    return out;
}

/// The draw-time contrast floor requested after a runtime background change
/// (Mac `ghostty_surface_set_min_contrast(surface, 3.0)`).
///
/// No palette work can reach TRUECOLOR content: a program that emitted
/// `38;2;r;g;b` chose those channels for the background it saw at startup,
/// and it never hears that the background moved. The renderer enforces this
/// ratio per cell at draw time instead, adjusting an under-contrast
/// foreground hue-preservingly (`contrasted_color` in the shaders). It only
/// ever STRENGTHENS the configured `minimum-contrast`, never weakens it.
///
/// 3.0 rather than 4.5 on purpose: this reaches every cell including
/// decorative and dim text, where forcing the full text floor would flatten
/// deliberate contrast hierarchies. The colors we control ourselves --
/// foreground and the base-16 palette below -- still meet 4.5.
pub const runtime_min_contrast: f64 = 3.0;

/// Every color derived from a runtime background pick, computed in ONE
/// shot so the caller can apply them under a single renderer-mutex hold.
///
/// Staggering them is the defect this shape exists to prevent: applying the
/// background first and the foreground a frame (or a debounce) later leaves
/// the pane showing the OLD theme's text on the NEW background, which is
/// exactly the unreadable intermediate state the user sees as a flash.
///
/// Selection and cursor are deliberately absent: with nothing configured
/// the renderer derives selection as a straight fg/bg swap and the cursor
/// as the foreground (`renderer/generic.zig`), so both follow this pair in
/// the same pass and the selection's contrast ratio is identical to the
/// text's. When the user HAS configured them explicitly, their choice wins
/// -- same as Mac.
pub const Scheme = struct {
    background: Rgb,
    foreground: Rgb,
    /// ANSI 0-15, each shifted to clear `contrast_target` against the
    /// background while keeping its hue and chroma.
    palette: [16]Rgb,
};

/// The complete accessible color scheme for a background.
pub fn scheme(bg: Rgb) Scheme {
    return .{
        .background = bg,
        .foreground = contrastForeground(bg),
        .palette = adjustedPalette(bg),
    };
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

test "contrastForeground: clears the 4.5:1 text floor for EVERY background" {
    // The picker accepts any of the 16.7M colors, so "usually readable" is
    // not a property -- sweep the whole grey ramp (where the Rec.601
    // lightness test and the WCAG answer disagree) plus saturated hues at
    // every lightness.
    for (0..256) |i| {
        const v: u8 = @intCast(i);
        const greys = [_]Rgb{
            .{ .r = v, .g = v, .b = v },
            .{ .r = v, .g = 0, .b = 0 },
            .{ .r = 0, .g = v, .b = 0 },
            .{ .r = 0, .g = 0, .b = v },
            .{ .r = v, .g = @intCast(255 - i), .b = v },
            .{ .r = @intCast(255 - i), .g = v, .b = 0 },
        };
        for (greys) |bg| {
            const ratio = wcagContrastRatio(
                wcagLuminance(contrastForeground(bg)),
                wcagLuminance(bg),
            );
            try testing.expect(ratio >= contrast_target);
        }
    }
}

test "contrastForeground: mid-greys take the higher-contrast side" {
    // #777777 is the regression: Rec.601 luminance 0.4667 reads "dark" and
    // picks white at 4.42:1 -- under the floor -- while black gives 4.76:1.
    const grey: Rgb = .{ .r = 0x77, .g = 0x77, .b = 0x77 };
    try testing.expect(!isLight(grey)); // Rec.601 still says dark...
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, contrastForeground(grey));
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
    for (0..1000) |_| {
        const c = randomDark(rand);
        try testing.expect(!isLight(c));
        const hsb = rgbToHsb(c);
        // Mac's ranges, both ends, read back through 8-bit RGB — so the
        // epsilons are quantization, not slop, and they are NOT the same size.
        // Brightness is `peak / 255`, one step = 0.004. Saturation is
        // `(peak - trough) / peak` at a peak of only ~33, so one step is
        // 1/33 = 0.030 and a single rounding of the trough moves it that far.
        // (Found by the negative control: at the RETIRED brightness the peak
        // is ~26, the step is 0.038, and saturation cannot be represented
        // faithfully at all -- itself a symptom of the defect.)
        try testing.expect(hsb.b >= random_dark_bri_min - 0.005);
        try testing.expect(hsb.b <= random_dark_bri_max + 0.005);
        try testing.expect(hsb.s >= random_dark_sat_min - 0.04);
        try testing.expect(hsb.s <= random_dark_sat_max + 0.04);
    }
}

test "randomDark: tints are distinguishable from each other" {
    // The defect this guards (T120, Mac 45f4f2250) is NOT "too bright" or
    // "not dark enough" — the old ranges passed a darkness assertion happily.
    // It is that every window came out the same near-black: what a viewer can
    // actually see is the chroma (`max - min` channel = b * s * 255), and the
    // retired sat 0.2-0.3 / bri 0.1-0.15 could only ever reach ~11 levels of
    // it, sitting near 8. So assert the floor no old sample could clear.
    var prng = std.Random.DefaultPrng.init(0xC010);
    const rand = prng.random();
    var min_chroma: u8 = 255;
    var min_peak: u8 = 255;
    for (0..1000) |_| {
        const c = randomDark(rand);
        const hi = @max(c.r, @max(c.g, c.b));
        const lo = @min(c.r, @min(c.g, c.b));
        min_chroma = @min(min_chroma, hi - lo);
        min_peak = @min(min_peak, hi);
    }
    // Old worst case ~5, old best case ~11; new floor is 0.33 * 0.13 * 255.
    try testing.expect(min_chroma >= 10);
    // Lifted off pure black: old floor was ~26/255.
    try testing.expect(min_peak >= 32);
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

test "contrastAdjustedTo: a lower floor moves the color less" {
    // The accent case: a floor of 3.0 has to stop as soon as it clears 3.0,
    // otherwise the user's color is dragged toward the text ramp and stops
    // being recognizably theirs.
    const bg: Rgb = .{ .r = 0x2A, .g = 0x2A, .b = 0x32 };
    const accent: Rgb = .{ .r = 0x68, .g = 0x00, .b = 0x81 }; // this box's real accent
    const at3 = contrastAdjustedTo(accent, bg, 3.0);
    const at45 = contrastAdjustedTo(accent, bg, contrast_target);

    const r3 = wcagContrastRatio(wcagLuminance(at3), wcagLuminance(bg));
    const r45 = wcagContrastRatio(wcagLuminance(at45), wcagLuminance(bg));
    try testing.expect(r3 >= 3.0 - 0.05);
    try testing.expect(r45 >= contrast_target - 0.1);
    // Both cleared their own floor, and the 3.0 answer stayed closer to the
    // color the user picked.
    try testing.expect(r3 < r45);
}

test "wash: direction follows the background, and a light background darkens" {
    const dark: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };
    const light: Rgb = .{ .r = 0xF5, .g = 0xF5, .b = 0xF5 };

    // Dark backgrounds lift toward white...
    const dw = wash(dark, 0.08);
    try testing.expect(dw.r > dark.r and dw.g > dark.g and dw.b > dark.b);

    // ...and light ones fall toward black. This is the assertion `bg + 20`
    // could never satisfy: a per-channel add moves a light background the
    // WRONG WAY, which is how the bar, its hover and the active tab all
    // converged on near-white in a light theme (T203 root cause #2).
    const lw = wash(light, 0.08);
    try testing.expect(lw.r < light.r and lw.g < light.g and lw.b < light.b);

    // A wash of 0 is a no-op, and a wash of 1 reaches the endpoint.
    try testing.expectEqual(dark, wash(dark, 0.0));
    try testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, wash(dark, 1.0));
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, wash(light, 1.0));
}

test "wash: on a dark background it lands within a few levels of `bg + 20`" {
    // The point of the port is that it is NOT a redesign of the dark look: on
    // the default background the new band lands essentially where the old
    // arithmetic put it, so the visible change is confined to light
    // backgrounds.
    //
    // "Essentially", not "exactly", and the gap is structural rather than a
    // tolerance nobody tightened: an add moves every channel by the same 20,
    // while a wash moves each one 8% of ITS OWN distance from white — so the
    // brighter a channel starts, the less it moves. On this background that is
    // 2 levels on r/g and 3 on b. A test that demanded equality would be
    // demanding the per-channel add back.
    const bg: Rgb = .{ .r = 0x1E, .g = 0x1E, .b = 0x2E };
    const w = wash(bg, 0.08);
    const old: Rgb = .{ .r = 0x1E + 20, .g = 0x1E + 20, .b = 0x2E + 20 };
    try testing.expect(@abs(@as(i32, w.r) - @as(i32, old.r)) <= 4);
    try testing.expect(@abs(@as(i32, w.g) - @as(i32, old.g)) <= 4);
    try testing.expect(@abs(@as(i32, w.b) - @as(i32, old.b)) <= 4);
    // The blue channel started highest, so it moved least.
    try testing.expect(@as(i32, w.b) - @as(i32, bg.b) < @as(i32, w.r) - @as(i32, bg.r));
}

test "scheme: every derived color clears its floor across the lightness range" {
    // The picker's whole range, not a couple of handpicked themes: greys
    // every 8 steps plus saturated mid-tones, which is where a "pick the
    // light/dark side" rule is weakest.
    var bgs: std.ArrayList(Rgb) = .empty;
    defer bgs.deinit(testing.allocator);
    var v: u16 = 0;
    while (v <= 255) : (v += 8) {
        const c: u8 = @intCast(v);
        const inv: u8 = @intCast(255 - v);
        try bgs.appendSlice(testing.allocator, &.{
            .{ .r = c, .g = c, .b = c },
            .{ .r = c, .g = inv, .b = 0x80 },
            .{ .r = 0x80, .g = c, .b = inv },
            .{ .r = inv, .g = 0x40, .b = c },
        });
    }

    for (bgs.items) |bg| {
        const s = scheme(bg);
        try testing.expectEqual(bg, s.background);

        const bg_lum = wcagLuminance(s.background);

        // Text floor (design system 2.3) for the default foreground...
        const fg_ratio = wcagContrastRatio(wcagLuminance(s.foreground), bg_lum);
        try testing.expect(fg_ratio >= contrast_target);

        // ...and for every ANSI color a program can select.
        for (s.palette) |c| {
            const ratio = wcagContrastRatio(wcagLuminance(c), bg_lum);
            try testing.expect(ratio >= contrast_target - 0.1);
        }

        // Unconfigured selection is a straight fg/bg swap, so its text
        // contrast is the foreground ratio by construction. Assert the
        // identity rather than trusting the comment.
        const sel_ratio = wcagContrastRatio(bg_lum, wcagLuminance(s.foreground));
        try testing.expectEqual(fg_ratio, sel_ratio);
    }
}

test "runtime_min_contrast: strengthens without reaching the text floor" {
    // Deliberately between "no floor" and the text floor -- see the doc
    // comment. A change here is a behavior change, not a tidy-up.
    try testing.expectEqual(@as(f64, 3.0), runtime_min_contrast);
    try testing.expect(runtime_min_contrast > 1.0);
    try testing.expect(runtime_min_contrast < contrast_target);
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
