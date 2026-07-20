//! Pure model for the surface right-click context menu (T102): the item
//! list, ordering, enable/check flags. Mirrors the macOS surface menu
//! (SurfaceView_AppKit.swift `menu(for:)`) with the win32 extras that were
//! already shipped (Select All). No OS imports so the unit tests run in
//! every app-runtime lane; the HMENU construction and dispatch live in
//! Surface.zig.

const std = @import("std");

/// Stable command ids for TrackPopupMenuEx's TPM_RETURNCMD. Zero is
/// reserved (TrackPopupMenuEx returns 0 for "dismissed without choosing").
pub const Id = enum(usize) {
    copy = 1,
    paste = 2,
    select_all = 3,
    split_right = 4,
    split_down = 5,
    reset = 6,
    bg_color = 7,
    split_left = 8,
    split_up = 9,
    readonly = 10,
    tab_title = 11,
    pane_title = 12,
};

pub const Item = union(enum) {
    separator,
    cmd: struct {
        id: Id,
        /// UTF-16 title ready for AppendMenuW.
        title: [:0]const u16,
        enabled: bool = true,
        checked: bool = false,
    },
};

/// Surface state the menu reflects.
pub const State = struct {
    has_selection: bool,
    readonly: bool,
};

fn u16lit(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Mac menu order (menu(for:)): Copy, Paste | splits R/L/D/U | Reset,
/// Read-only | Background Color… | Change Tab Title…, Change Pane Title….
/// Windows keeps Select All after Paste (already shipped pre-T102; Edit-menu
/// convention) and grays Copy without a selection where the Mac omits it
/// (grayed-but-present is the Windows-native idiom).
pub fn build(state: State) [16]Item {
    return .{
        .{ .cmd = .{ .id = .copy, .title = u16lit("Copy"), .enabled = state.has_selection } },
        .{ .cmd = .{ .id = .paste, .title = u16lit("Paste") } },
        .{ .cmd = .{ .id = .select_all, .title = u16lit("Select All") } },
        .separator,
        .{ .cmd = .{ .id = .split_right, .title = u16lit("Split Right") } },
        .{ .cmd = .{ .id = .split_left, .title = u16lit("Split Left") } },
        .{ .cmd = .{ .id = .split_down, .title = u16lit("Split Down") } },
        .{ .cmd = .{ .id = .split_up, .title = u16lit("Split Up") } },
        .separator,
        .{ .cmd = .{ .id = .reset, .title = u16lit("Reset Terminal") } },
        .{ .cmd = .{ .id = .readonly, .title = u16lit("Terminal Read-only"), .checked = state.readonly } },
        .separator,
        .{ .cmd = .{ .id = .bg_color, .title = u16lit("Background Color...") } },
        .separator,
        .{ .cmd = .{ .id = .tab_title, .title = u16lit("Change Tab Title...") } },
        .{ .cmd = .{ .id = .pane_title, .title = u16lit("Change Pane Title...") } },
    };
}

test "mac-parity order and grouping" {
    const items = build(.{ .has_selection = false, .readonly = false });
    // Expected id sequence with separators as null.
    const expected = [_]?Id{
        .copy,        .paste,    .select_all, null,
        .split_right, .split_left, .split_down, .split_up,
        null,         .reset,    .readonly,   null,
        .bg_color,    null,      .tab_title,  .pane_title,
    };
    try std.testing.expectEqual(expected.len, items.len);
    for (items, expected) |item, exp| switch (item) {
        .separator => try std.testing.expect(exp == null),
        .cmd => |c| try std.testing.expectEqual(exp.?, c.id),
    };
}

test "copy enabled tracks selection" {
    const without = build(.{ .has_selection = false, .readonly = false });
    const with = build(.{ .has_selection = true, .readonly = false });
    try std.testing.expect(!without[0].cmd.enabled);
    try std.testing.expect(with[0].cmd.enabled);
    // Everything else stays enabled either way.
    for (without[1..]) |item| switch (item) {
        .separator => {},
        .cmd => |c| try std.testing.expect(c.enabled),
    };
}

test "readonly check mirrors state" {
    const off = build(.{ .has_selection = false, .readonly = false });
    const on = build(.{ .has_selection = false, .readonly = true });
    for (off, on) |a, b| switch (a) {
        .separator => {},
        .cmd => |c| {
            const checked_on = b.cmd.checked;
            if (c.id == .readonly) {
                try std.testing.expect(!c.checked);
                try std.testing.expect(checked_on);
            } else {
                try std.testing.expect(!c.checked);
                try std.testing.expect(!checked_on);
            }
        },
    };
}

test "command ids are unique and nonzero" {
    const items = build(.{ .has_selection = true, .readonly = true });
    var seen = std.StaticBitSet(64).initEmpty();
    for (items) |item| switch (item) {
        .separator => {},
        .cmd => |c| {
            const v = @intFromEnum(c.id);
            try std.testing.expect(v != 0);
            try std.testing.expect(!seen.isSet(v));
            seen.set(v);
        },
    };
}
