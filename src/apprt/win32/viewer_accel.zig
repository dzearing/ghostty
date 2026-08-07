//! Viewer-pane accelerator forwarding, the pure half (T394).
//!
//! A focused viewer pane's keyboard lives inside WebView2's Chromium child
//! HWNDs, which never reach our WndProc — so the app keybind table (palette,
//! new tab, close) is dead there unless the controller's
//! `AcceleratorKeyPressed` event hands the chord back to us. This module is
//! the part of that path that needs no OS: mapping the event's Win32
//! virtual-key + modifier state to the `input.KeyEvent` the app keybind set
//! is consulted with, and naming WHICH bound actions a viewer pane may
//! perform at all.
//!
//! No OS imports, so the unit tests run in every app-runtime lane. The
//! virtual-key values are therefore literals; `Surface.zig` (win32 lane)
//! holds the drift guard that compares this table against its own
//! `mapVirtualKey` over the whole 8-bit VK space, so a transcription error
//! here fails the win32 lane rather than shipping.

const std = @import("std");
const input = @import("../../input.zig");

/// Map a Win32 virtual-key code to a Ghostty `input.Key`. The same table as
/// `Surface.mapVirtualKey`, with the `w32.VK_*` names spelled as their
/// values (this file cannot import an OS surface).
pub fn keyFromVk(vk: u16, extended: bool) input.Key {
    return switch (vk) {
        // Letter keys (A-Z: 0x41-0x5A)
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,

        // Number keys (0-9: 0x30-0x39)
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,

        // Function keys (VK_F1..VK_F24: 0x70-0x87)
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        0x7C => .f13,
        0x7D => .f14,
        0x7E => .f15,
        0x7F => .f16,
        0x80 => .f17,
        0x81 => .f18,
        0x82 => .f19,
        0x83 => .f20,
        0x84 => .f21,
        0x85 => .f22,
        0x86 => .f23,
        0x87 => .f24,

        // Navigation / editing keys
        0x0D => if (extended) .numpad_enter else .enter, // VK_RETURN
        0x08 => .backspace, // VK_BACK
        0x09 => .tab, // VK_TAB
        0x1B => .escape, // VK_ESCAPE
        0x20 => .space, // VK_SPACE
        0x21 => .page_up, // VK_PRIOR
        0x22 => .page_down, // VK_NEXT
        0x23 => .end, // VK_END
        0x24 => .home, // VK_HOME
        0x25 => .arrow_left, // VK_LEFT
        0x26 => .arrow_up, // VK_UP
        0x27 => .arrow_right, // VK_RIGHT
        0x28 => .arrow_down, // VK_DOWN
        0x2D => .insert, // VK_INSERT
        0x2E => .delete, // VK_DELETE

        // Modifier keys
        0xA0 => .shift_left, // VK_LSHIFT
        0xA1 => .shift_right, // VK_RSHIFT
        0xA2 => .control_left, // VK_LCONTROL
        0xA3 => .control_right, // VK_RCONTROL
        0xA4 => .alt_left, // VK_LMENU
        0xA5 => .alt_right, // VK_RMENU
        0x5B => .meta_left, // VK_LWIN
        0x5C => .meta_right, // VK_RWIN
        0x10 => if (extended) .shift_right else .shift_left, // VK_SHIFT
        0x11 => if (extended) .control_right else .control_left, // VK_CONTROL
        0x12 => if (extended) .alt_right else .alt_left, // VK_MENU

        // Lock keys
        0x14 => .caps_lock, // VK_CAPITAL
        0x90 => .num_lock, // VK_NUMLOCK
        0x91 => .scroll_lock, // VK_SCROLL

        // OEM keys (US keyboard layout)
        0xBA => .semicolon, // VK_OEM_1
        0xBB => .equal, // VK_OEM_PLUS
        0xBC => .comma, // VK_OEM_COMMA
        0xBD => .minus, // VK_OEM_MINUS
        0xBE => .period, // VK_OEM_PERIOD
        0xBF => .slash, // VK_OEM_2
        0xC0 => .backquote, // VK_OEM_3
        0xDB => .bracket_left, // VK_OEM_4
        0xDC => .backslash, // VK_OEM_5
        0xDD => .bracket_right, // VK_OEM_6
        0xDE => .quote, // VK_OEM_7

        // Numpad keys (0x60-0x6F)
        0x60 => .numpad_0,
        0x61 => .numpad_1,
        0x62 => .numpad_2,
        0x63 => .numpad_3,
        0x64 => .numpad_4,
        0x65 => .numpad_5,
        0x66 => .numpad_6,
        0x67 => .numpad_7,
        0x68 => .numpad_8,
        0x69 => .numpad_9,
        0x6A => .numpad_multiply, // VK_MULTIPLY
        0x6B => .numpad_add, // VK_ADD
        0x6C => .numpad_separator, // VK_SEPARATOR
        0x6D => .numpad_subtract, // VK_SUBTRACT
        0x6E => .numpad_decimal, // VK_DECIMAL
        0x6F => .numpad_divide, // VK_DIVIDE

        // Misc
        0x5D => .context_menu, // VK_APPS
        0x13 => .pause, // VK_PAUSE

        else => .unidentified,
    };
}

/// Build the `input.KeyEvent` the app keybind set is consulted with for an
/// accelerator chord, or null when the key can never name a binding here: a
/// bare modifier, or a key this table cannot identify (there is no ToUnicode
/// on this path, so an unidentified key has no codepoint to match either).
///
/// The event carries no UTF-8 (the accelerator event precedes translation),
/// so `Binding.Set.getEvent` matches on the physical key first and then on
/// the key's unshifted codepoint — which is exactly how the default
/// `ctrl+shift+p`-style bindings are stored (as unicode triggers).
pub fn keyEventFor(vk: u16, extended: bool, mods: input.Mods) ?input.KeyEvent {
    const key = keyFromVk(vk, extended);
    if (key == .unidentified) return null;
    if (key.modifier()) return null;
    return .{
        .action = .press,
        .key = key,
        .mods = mods,
        .consumed_mods = .{},
        .utf8 = "",
        .unshifted_codepoint = if (key.codepoint()) |cp| cp else 0,
    };
}

/// Whether a bound action is one a focused VIEWER pane forwards to the app
/// (T394). This is the app-keybind leg only — the pane-scoped viewer chords
/// (reload, address bar, zoom; T161) are a separate table checked before
/// this one.
///
/// The rule: an action is forwarded when it is window- or app-scoped and has
/// a meaning with no terminal underneath — closing/creating panes, tabs and
/// windows, split navigation and layout, the palette, config and app
/// commands. Everything else (clipboard, scrollback, font size, search,
/// terminal state) stays with the page, which has its own meaning for those
/// keys or none at all.
pub fn forwards(action: input.Binding.Action) bool {
    return switch (action) {
        .quit,
        .new_window,
        .new_tab,
        .close_surface,
        .close_tab,
        .close_window,
        .close_all_windows,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .new_split,
        .goto_split,
        .swap_split,
        .resize_split,
        .equalize_splits,
        .toggle_split_zoom,
        .toggle_fullscreen,
        .toggle_maximize,
        .toggle_window_decorations,
        .toggle_command_palette,
        .open_config,
        .reload_config,
        .prompt_window_title,
        => true,

        else => false,
    };
}

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "a letter chord resolves a default-style unicode binding" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    // The shape the Windows defaults use: `ctrl+shift+p` parses to a
    // UNICODE trigger, not a physical one.
    try set.put(
        alloc,
        .{ .key = .{ .unicode = 'p' }, .mods = .{ .ctrl = true, .shift = true } },
        .toggle_command_palette,
    );

    const event = keyEventFor(0x50, false, .{ .ctrl = true, .shift = true }).?; // 'P'
    try testing.expectEqual(input.Key.key_p, event.key);
    try testing.expectEqual(@as(u21, 'p'), event.unshifted_codepoint);

    const entry = set.getEvent(event).?;
    try testing.expectEqual(
        input.Binding.Action.toggle_command_palette,
        entry.value_ptr.*.leaf.action,
    );
}

test "a physical-key chord resolves a physical binding" {
    const alloc = testing.allocator;
    var set: input.Binding.Set = .{};
    defer set.deinit(alloc);

    // The Windows default `ctrl+f4 = close_tab:this` is stored physical.
    try set.put(
        alloc,
        .{ .key = .{ .physical = .f4 }, .mods = .{ .ctrl = true } },
        .{ .close_tab = .this },
    );

    const event = keyEventFor(0x73, false, .{ .ctrl = true }).?; // VK_F4
    const entry = set.getEvent(event).?;
    try testing.expectEqual(
        input.Binding.Action{ .close_tab = .this },
        entry.value_ptr.*.leaf.action,
    );

    // The same vk without ctrl matches nothing.
    const bare = keyEventFor(0x73, false, .{}).?;
    try testing.expect(set.getEvent(bare) == null);
}

test "bare modifiers and unidentified keys build no event" {
    // A modifier press arrives as its own accelerator event and must never
    // consult the table (a `ctrl+w` binding would otherwise fire on the
    // ctrl press alone via catch_all bindings).
    try testing.expect(keyEventFor(0x10, false, .{ .shift = true }) == null); // VK_SHIFT
    try testing.expect(keyEventFor(0xA2, false, .{ .ctrl = true }) == null); // VK_LCONTROL
    try testing.expect(keyEventFor(0x5B, false, .{ .super = true }) == null); // VK_LWIN
    // 0x15 (VK_KANA) is not in the table: no key, no codepoint, no lookup.
    try testing.expect(keyEventFor(0x15, false, .{ .ctrl = true }) == null);
}

test "the extended bit distinguishes the numpad enter" {
    try testing.expectEqual(input.Key.enter, keyEventFor(0x0D, false, .{ .ctrl = true }).?.key);
    try testing.expectEqual(input.Key.numpad_enter, keyEventFor(0x0D, true, .{ .ctrl = true }).?.key);
}

test "forwards: window/app commands yes, terminal-content commands no" {
    // The exact chords the user lost (2026-08-05): close, and the palette.
    try testing.expect(forwards(.close_surface));
    try testing.expect(forwards(.{ .close_tab = .this }));
    try testing.expect(forwards(.toggle_command_palette));
    try testing.expect(forwards(.new_tab));
    try testing.expect(forwards(.{ .new_split = .right }));
    try testing.expect(forwards(.{ .goto_split = .right }));
    try testing.expect(forwards(.quit));

    // Content-scoped actions stay with the page.
    try testing.expect(!forwards(.{ .copy_to_clipboard = .mixed }));
    try testing.expect(!forwards(.paste_from_clipboard));
    try testing.expect(!forwards(.scroll_page_up));
    try testing.expect(!forwards(.{ .increase_font_size = 1 }));
    try testing.expect(!forwards(.select_all));
    try testing.expect(!forwards(.start_search));
    try testing.expect(!forwards(.clear_screen));
    try testing.expect(!forwards(.prompt_surface_banner));
}
