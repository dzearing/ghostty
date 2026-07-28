//! Stable, ghoztty-owned pane identity for the win32 apprt (T113).
//!
//! CLAUDE.md's "Pane identity" section is a cross-platform contract: every
//! pane has a stable UUID that is exported to the pane's processes as
//! `$GHOZTTY_PANE_ID`, reported as the `+list --json` leaf `id`, and accepted
//! directly by every `--target`/`--name` (case-insensitive) with no prior
//! registration or `+list`. macOS satisfies it with `SurfaceView.id.uuidString`
//! (baked in `SurfaceView_AppKit.swift`); win32 had none of it, so any tool
//! that followed the documented contract to address its own pane had to
//! special-case Windows (T112's `/reset-context` fallback chain exists purely
//! for that).
//!
//! This module is the pure half of the win32 side: generation, validation,
//! case-insensitive comparison, and the legacy surface-id spellings we keep
//! accepting as aliases so pre-T113 callers (and panes whose shells were baked
//! by an older build) keep resolving.
//!
//! No OS imports — unit-tested in the none-runtime lane via `src/apprt.zig`.

const std = @import("std");

/// Length of the canonical textual form: 8-4-4-4-12 hex with dashes.
pub const len: usize = 36;

/// A caller-owned buffer holding one formatted pane id.
pub const Buf = [len]u8;

/// Format 16 random bytes as an RFC 4122 version-4 UUID string, UPPERCASE —
/// matching Foundation's `UUID.uuidString`, which is what the Mac bakes into
/// `$GHOZTTY_PANE_ID`. The version/variant bits are stamped here so the two
/// platforms produce the same shape of value (comparisons are
/// case-insensitive, so the casing is cosmetic parity, not a requirement).
pub fn format(out: *Buf, bytes: [16]u8) []const u8 {
    var b = bytes;
    b[6] = (b[6] & 0x0F) | 0x40; // version 4
    b[8] = (b[8] & 0x3F) | 0x80; // variant 1 (RFC 4122)

    const hex = "0123456789ABCDEF";
    var i: usize = 0; // byte index
    var o: usize = 0; // output index
    while (i < 16) : (i += 1) {
        // Dashes after bytes 4, 6, 8 and 10.
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b[i] >> 4];
        out[o + 1] = hex[b[i] & 0x0F];
        o += 2;
    }
    std.debug.assert(o == len);
    return out[0..len];
}

/// Generate a fresh pane id from `random`. Split from `generate` so the
/// formatting is testable against a deterministic source.
pub fn generateFrom(random: std.Random, out: *Buf) []const u8 {
    var bytes: [16]u8 = undefined;
    random.bytes(&bytes);
    return format(out, bytes);
}

/// Generate a fresh pane id from the CSPRNG. Called once per surface.
pub fn generate(out: *Buf) []const u8 {
    return generateFrom(std.crypto.random, out);
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

/// True when `s` is a well-formed pane id (8-4-4-4-12 hex, either case). Used
/// to reject a garbage manifest value rather than restore an unaddressable
/// pane, and to skip the live-surface scan for targets that cannot be pane ids.
pub fn isValid(s: []const u8) bool {
    if (s.len != len) return false;
    for (s, 0..) |c, i| {
        const want_dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (want_dash) {
            if (c != '-') return false;
        } else if (!isHex(c)) return false;
    }
    return true;
}

/// Case-insensitive pane-id equality. CLAUDE.md promises `--target` accepts
/// the id "case-insensitive", and a shell that round-trips the value through
/// a lowercasing pipeline must still resolve.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

/// Parse a LEGACY surface-id target spelling into the `Surface.id` it names,
/// or null when `s` is not one.
///
/// Two spellings are accepted, both of which a process inside a pane can hold
/// without any help from us:
///
///   - `0x0123456789abcdef` — verbatim `$GHOSTTY_SURFACE_ID`, which core bakes
///     for every pane (`Surface.zig`). Before T113 this was REJECTED, so
///     T112's reset-context fix had to convert it to decimal by hand.
///   - `81985529216486895` — the decimal spelling, which is what `+list`
///     auto-registered as a pane's fallback name before T113 and therefore
///     what older callers cached.
///
/// Both remain aliases forever: a pane whose shell was spawned by a pre-T113
/// build has no `$GHOZTTY_PANE_ID` in its env at all, and re-attach keeps that
/// shell (and its env) alive across upgrades.
pub fn parseSurfaceIdAlias(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    if (s.len > 2 and (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))) {
        return std.fmt.parseInt(u64, s[2..], 16) catch null;
    }
    // Plain decimal only — no `+`/`-` sign, which parseInt would otherwise
    // accept and which never names a surface.
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

test "format stamps version 4 and variant 1" {
    const testing = std.testing;
    var buf: Buf = undefined;
    const s = format(&buf, [_]u8{0} ** 16);
    try testing.expectEqual(len, s.len);
    try testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", s);
    try testing.expect(isValid(s));
}

test "format lays out dashes and uppercase hex" {
    const testing = std.testing;
    var buf: Buf = undefined;
    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(0xF0 | i);
    const s = format(&buf, bytes);
    // Bytes 6 and 8 carry the stamped version/variant nibbles.
    try testing.expectEqualStrings("F0F1F2F3-F4F5-46F7-B8F9-FAFBFCFDFEFF", s);
    try testing.expect(isValid(s));
}

test "generateFrom is well-formed and varies" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xF00D);
    var a: Buf = undefined;
    var b: Buf = undefined;
    const sa = generateFrom(prng.random(), &a);
    const sb = generateFrom(prng.random(), &b);
    try testing.expect(isValid(sa));
    try testing.expect(isValid(sb));
    try testing.expect(!eql(sa, sb));
}

test "isValid rejects near-misses" {
    const testing = std.testing;
    try testing.expect(!isValid(""));
    try testing.expect(!isValid("00000000-0000-4000-8000-00000000000")); // short
    try testing.expect(!isValid("00000000-0000-4000-8000-0000000000000")); // long
    try testing.expect(!isValid("000000000000-4000-8000-000000000000")); // dashes moved
    try testing.expect(!isValid("0000000g-0000-4000-8000-000000000000")); // non-hex
    try testing.expect(!isValid("logs"));
    try testing.expect(!isValid("1234567890123456789"));
}

test "eql is case-insensitive and length-strict" {
    const testing = std.testing;
    try testing.expect(eql(
        "ABCDEF01-2345-4678-9ABC-DEF012345678",
        "abcdef01-2345-4678-9abc-def012345678",
    ));
    try testing.expect(!eql("A", "AB"));
    try testing.expect(!eql(
        "ABCDEF01-2345-4678-9ABC-DEF012345678",
        "ABCDEF01-2345-4678-9ABC-DEF012345679",
    ));
}

test "parseSurfaceIdAlias accepts hex and decimal spellings" {
    const testing = std.testing;
    // The exact `$GHOSTTY_SURFACE_ID` spelling core bakes (0x + 16 hex).
    try testing.expectEqual(
        @as(?u64, 0x0123456789abcdef),
        parseSurfaceIdAlias("0x0123456789abcdef"),
    );
    try testing.expectEqual(
        @as(?u64, 0x0123456789abcdef),
        parseSurfaceIdAlias("0X0123456789ABCDEF"),
    );
    // The decimal spelling `+list` used to auto-register.
    try testing.expectEqual(
        @as(?u64, 81985529216486895),
        parseSurfaceIdAlias("81985529216486895"),
    );
}

test "parseSurfaceIdAlias rejects non-ids" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias(""));
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias("logs"));
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias("0x"));
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias("0xzz"));
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias("-5"));
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias("+5"));
    try testing.expectEqual(@as(?u64, null), parseSurfaceIdAlias("12ab"));
    // A pane id is never an alias (it would otherwise be parsed as garbage).
    try testing.expectEqual(
        @as(?u64, null),
        parseSurfaceIdAlias("ABCDEF01-2345-4678-9ABC-DEF012345678"),
    );
    // Overflow must not resolve to a live surface.
    try testing.expectEqual(
        @as(?u64, null),
        parseSurfaceIdAlias("99999999999999999999999999"),
    );
}
