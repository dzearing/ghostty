//! Menu item text: the base title plus a tab and the accelerator, when the
//! live keybind set has a trigger for the item's action.
//!
//! This is the Windows convention and the app's only self-teaching surface
//! for chords — T129: the pane banner's ctrl+shift+b differs from the Mac
//! cmd+r and was named nowhere, so users concluded the feature was broken.
//! Reading the trigger from config means a rebind relabels the menu, and an
//! unbound action simply shows no hint.
//!
//! It lives here rather than in `Surface.zig` because there are now two menu
//! surfaces over the same commands — the right-click context menu (T102) and
//! the menu system opened from the tab strip (T143/T190) — and a second
//! hand-written formatter is the same drift `commands.zig` exists to stop.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const input = @import("../../input.zig");

/// Longest label a menu row can carry: base title + '\t' + accelerator + NUL.
/// A row that would not fit falls back to its bare title rather than being
/// truncated mid-chord.
pub const BUF_LEN = 96;

pub const Buf = [BUF_LEN]u16;

/// Format a keybinding trigger as a human-readable string (e.g.
/// "Ctrl+Shift+T"). Returns the number of bytes written to `buf`.
///
/// Modifier order is Windows' own (Win, Ctrl, Alt, Shift), which is what the
/// system's menus and every shipped Windows app print.
pub fn formatTrigger(trigger: input.Binding.Trigger, buf: []u8) usize {
    var pos: usize = 0;

    inline for (.{
        .{ trigger.mods.super, "Win+" },
        .{ trigger.mods.ctrl, "Ctrl+" },
        .{ trigger.mods.alt, "Alt+" },
        .{ trigger.mods.shift, "Shift+" },
    }) |pair| {
        if (pair[0] and pos + pair[1].len <= buf.len) {
            @memcpy(buf[pos..][0..pair[1].len], pair[1]);
            pos += pair[1].len;
        }
    }

    switch (trigger.key) {
        .unicode => |cp| {
            if (pos < buf.len) {
                // Upper-case letters for display, like every Windows menu.
                if (cp >= 'a' and cp <= 'z') {
                    buf[pos] = @intCast(cp - 32);
                    pos += 1;
                } else if (cp >= ' ' and cp <= '~') {
                    buf[pos] = @intCast(cp);
                    pos += 1;
                }
            }
        },
        .physical => |k| {
            const name = keyName(k);
            if (name.len > 0 and pos + name.len <= buf.len) {
                @memcpy(buf[pos..][0..name.len], name);
                pos += name.len;
            }
        },
        .catch_all => {},
    }

    return pos;
}

/// Map physical key enum to display name.
pub fn keyName(k: input.Key) []const u8 {
    return switch (k) {
        .key_a => "A",
        .key_b => "B",
        .key_c => "C",
        .key_d => "D",
        .key_e => "E",
        .key_f => "F",
        .key_g => "G",
        .key_h => "H",
        .key_i => "I",
        .key_j => "J",
        .key_k => "K",
        .key_l => "L",
        .key_m => "M",
        .key_n => "N",
        .key_o => "O",
        .key_p => "P",
        .key_q => "Q",
        .key_r => "R",
        .key_s => "S",
        .key_t => "T",
        .key_u => "U",
        .key_v => "V",
        .key_w => "W",
        .key_x => "X",
        .key_y => "Y",
        .key_z => "Z",
        .digit_0 => "0",
        .digit_1 => "1",
        .digit_2 => "2",
        .digit_3 => "3",
        .digit_4 => "4",
        .digit_5 => "5",
        .digit_6 => "6",
        .digit_7 => "7",
        .digit_8 => "8",
        .digit_9 => "9",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .space => "Space",
        .enter => "Enter",
        .tab => "Tab",
        .backspace => "Backspace",
        .escape => "Escape",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end => "End",
        .insert => "Insert",
        .delete => "Delete",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .semicolon => ";",
        .quote => "'",
        .bracket_left => "[",
        .bracket_right => "]",
        .backslash => "\\",
        .minus => "-",
        .equal => "=",
        .backquote => "`",
        else => "",
    };
}

/// `title`, or `title\t<accel>` written into `buf` when `trigger` is
/// non-null and formats to something. Returns a pointer suitable for
/// `AppendMenuW` — either into `buf` or `title` itself, so the caller must
/// keep `buf` alive until the string is copied (AppendMenuW copies it).
pub fn withAccel(
    title: [:0]const u16,
    trigger: ?input.Binding.Trigger,
    buf: *Buf,
) [*:0]const u16 {
    const t = trigger orelse return title.ptr;

    var accel: [64]u8 = undefined;
    const accel_len = formatTrigger(t, &accel);
    if (accel_len == 0) return title.ptr;

    // title + '\t' + accel + NUL; fall back to the bare title if it can't
    // fit (accel is ASCII, so one u16 per byte).
    if (title.len + 1 + accel_len + 1 > buf.len) return title.ptr;
    @memcpy(buf[0..title.len], title[0..title.len]);
    var pos = title.len;
    buf[pos] = '\t';
    pos += 1;
    pos += std.unicode.utf8ToUtf16Le(buf[pos..], accel[0..accel_len]) catch
        return title.ptr;
    buf[pos] = 0;
    return @ptrCast(buf);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;

fn u16lit(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn fmt(trigger: input.Binding.Trigger, buf: []u8) []const u8 {
    return buf[0..formatTrigger(trigger, buf)];
}

test "modifiers print in Windows order" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+Shift+B", fmt(.{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .unicode = 'b' },
    }, &buf));
    try testing.expectEqualStrings("Win+Ctrl+Alt+Shift+K", fmt(.{
        .mods = .{ .super = true, .ctrl = true, .alt = true, .shift = true },
        .key = .{ .unicode = 'k' },
    }, &buf));
}

test "physical keys print their name, unbound-shaped triggers print nothing" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+F10", fmt(.{
        .mods = .{ .ctrl = true },
        .key = .{ .physical = .f10 },
    }, &buf));
    // catch_all has no printable key, so the accelerator is modifiers only —
    // `withAccel` still labels it, but a key we have no name for yields "".
    try testing.expectEqualStrings("", fmt(.{
        .mods = .{},
        .key = .{ .physical = .numpad_0 },
    }, &buf));
}

test "withAccel appends the chord after a tab" {
    var buf: Buf = undefined;
    const out = withAccel(u16lit("Set Pane Banner…"), .{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .unicode = 'b' },
    }, &buf);
    const len = std.mem.len(out);
    try testing.expectEqualSlices(
        u16,
        u16lit("Set Pane Banner…\tCtrl+Shift+B"),
        out[0..len],
    );
}

test "an unbound command keeps its bare title" {
    var buf: Buf = undefined;
    const title = u16lit("&About Ghoztty");
    // No trigger at all...
    try testing.expectEqual(title.ptr, withAccel(title, null, &buf));
    // ...and a trigger that formats to nothing (no printable key) must not
    // leave a dangling tab on the row.
    try testing.expectEqual(title.ptr, withAccel(title, .{
        .mods = .{},
        .key = .{ .physical = .numpad_0 },
    }, &buf));
}

test "an over-long title falls back to itself rather than truncating" {
    var buf: Buf = undefined;
    const long = u16lit("A" ** (BUF_LEN - 4));
    const out = withAccel(long, .{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .unicode = 'b' },
    }, &buf);
    try testing.expectEqual(long.ptr, out);
}
