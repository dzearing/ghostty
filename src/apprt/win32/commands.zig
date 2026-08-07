//! The win32 command registry (T189): ONE list of every command the app
//! offers a user, with its display name and what it performs.
//!
//! Before this, the command palette owned a private `palette_entries` array
//! inside `Surface.zig`. That is fine while the palette is the only place a
//! command can be reached from — but the menu system (T143) is a second
//! surface over the same commands, and two hand-maintained lists of the same
//! thing drift. That drift is exactly what T57 already cost us once (fork
//! actions existed as keybinds but never made it into the palette's parallel
//! list, so hero mode was undiscoverable even though it worked).
//!
//! So the palette and the menu both read THIS list, and each command is named
//! by a stable `Id` rather than by its index. `menu_bar.zig` references ids;
//! `Surface.zig` renders `registry` in order as the palette. A command that
//! deliberately does not appear in the menu is listed in `menu_bar.omitted`
//! with a reason, and a static test fails if a command is in neither — so
//! adding a command forces a decision instead of silently landing in one
//! surface only.
//!
//! No OS imports, so the unit tests run in every app-runtime lane.

const std = @import("std");
const input = @import("../../input.zig");

/// How a command is performed. Most are a core binding action; a few are
/// apprt-local because there is no binding for them.
pub const Kind = enum {
    /// Perform `Command.action` through `performBindingAction` — the same
    /// path a keybind takes.
    binding,
    /// Open the machine chooser (there is no "new remote window" binding).
    remote,
    /// Open the Activity Monitor panel (T285). Like `remote`, apprt-local:
    /// macOS registers it as a palette-only opener too
    /// (TerminalCommandPalette.swift:179-188).
    activity,
    /// Show the About box (T52).
    about,
    /// Run the Claude Code plugin install (T71).
    claude,
    /// Open the documentation in the default browser (macOS "Ghoztty Help").
    help,
    /// Open a file-picker and show the chosen file in a viewer split (T396).
    /// Like `remote`, apprt-local: macOS registers the three viewer entries
    /// as palette-only openers too (TerminalCommandPalette.swift:195-219 →
    /// ViewerCommands.swift).
    viewer_open_file,
    /// Prompt for a web address and open it in a viewer split (T396).
    viewer_open_url,
    /// Open a blank browser viewer split with the caret in its address
    /// field (T396) — the interactive `+split --view=about:blank`.
    viewer_open_browser,
};

/// Stable identity for a command. The name is the identity — reordering
/// `registry` must never change what an id means, because menu items and
/// `TrackPopupMenuEx` command ids are keyed on it.
///
/// Ids are also used AS win32 menu command ids (`@intFromEnum + 1`, so that
/// zero stays "dismissed without choosing"); see `menu_bar.menuCommandId`.
pub const Id = enum {
    new_window,
    new_remote_window,
    activity_monitor,
    new_tab,
    close_surface,
    close_tab,
    close_window,
    close_all_windows,
    previous_tab,
    next_tab,
    last_tab,
    split_right,
    split_down,
    split_left,
    split_up,
    focus_split_right,
    focus_split_down,
    focus_split_left,
    focus_split_up,
    focus_split_previous,
    focus_split_next,
    swap_split_right,
    swap_split_down,
    swap_split_left,
    swap_split_up,
    toggle_split_zoom,
    toggle_hero_mode,
    equalize_splits,
    move_divider_up,
    move_divider_down,
    move_divider_left,
    move_divider_right,
    toggle_fullscreen,
    toggle_maximize,
    reset_window_size,
    toggle_window_decorations,
    toggle_background_opacity,
    toggle_quick_terminal,
    toggle_visibility,
    toggle_readonly,
    toggle_mouse_reporting,
    copy_to_clipboard,
    paste_from_clipboard,
    copy_url_to_clipboard,
    copy_title_to_clipboard,
    prompt_window_title,
    prompt_tab_title,
    prompt_surface_title,
    prompt_surface_banner,
    select_all,
    command_palette,
    find,
    find_next,
    find_previous,
    hide_find_bar,
    search_selection,
    jump_to_selection,
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    scroll_page_up,
    scroll_page_down,
    scroll_to_top,
    scroll_to_bottom,
    clear_screen,
    reset_terminal,
    open_config,
    reload_config,
    check_for_updates,
    help,
    about,
    claude_integration,
    quit,
    viewer_open_file,
    viewer_open_url,
    viewer_open_browser,
};

/// Where "Ghoztty Help" goes. The docs are the same for every platform, so
/// this is the one string both the menu and the palette open.
pub const help_url = "https://ghostty.org/docs";

pub const Command = struct {
    id: Id,
    /// Display name in the command palette. The MENU carries its own title
    /// (Mac's wording, plus a `&` mnemonic) — see `menu_bar.zig`. They are
    /// deliberately allowed to differ: "Toggle Read-Only" reads right in a
    /// searchable palette, "Terminal Read-only" reads right as a checkable
    /// menu row, and both are the same command.
    name: []const u8,
    action: input.Binding.Action,
    kind: Kind = .binding,
    /// The Quit command (T89e): its palette name becomes "Quit Ghoztty (keep
    /// sessions)" when session-persistence is on, to signal that quitting
    /// detaches persistent sessions for re-attach rather than ending them.
    quit_keep: bool = false,
};

/// Every command, in command-palette display order.
///
/// The order here IS the palette's order, so it stays the order the palette
/// shipped with (T57 and its follow-ups): the frequently used window/split
/// commands first, then clipboard/labels, then font/scroll, then config and
/// app-level commands. The menu imposes its own order (Mac's tree) on the
/// same set.
pub const registry = [_]Command{
    .{ .id = .new_window, .name = "New Window", .action = .new_window },
    .{ .id = .new_remote_window, .name = "New Remote Window", .action = .new_window, .kind = .remote },
    // macOS names it "Open Remote Activity Monitor"; on Windows the panel opens
    // on the LOCAL machine (T285) and grows remote sources in T287, so the name
    // does not promise a remote-only surface.
    .{ .id = .activity_monitor, .name = "Open Activity Monitor", .action = .new_window, .kind = .activity },
    // The three viewer entries (T396), names verbatim from Mac
    // (TerminalCommandPalette.swift:195-219): the only interactive way to
    // open a viewer pane, mirroring the CLI `+split --view=…`.
    .{ .id = .viewer_open_file, .name = "Viewer: Open File in Pane…", .action = .new_window, .kind = .viewer_open_file },
    .{ .id = .viewer_open_url, .name = "Viewer: Open URL in Pane…", .action = .new_window, .kind = .viewer_open_url },
    .{ .id = .viewer_open_browser, .name = "Viewer: Open Browser Pane", .action = .new_window, .kind = .viewer_open_browser },
    .{ .id = .new_tab, .name = "New Tab", .action = .new_tab },
    .{ .id = .close_surface, .name = "Close Surface", .action = .close_surface },
    .{ .id = .close_tab, .name = "Close Tab", .action = .{ .close_tab = .this } },
    .{ .id = .close_window, .name = "Close Window", .action = .close_window },
    .{ .id = .close_all_windows, .name = "Close All Windows", .action = .close_all_windows },
    .{ .id = .previous_tab, .name = "Previous Tab", .action = .previous_tab },
    .{ .id = .next_tab, .name = "Next Tab", .action = .next_tab },
    .{ .id = .last_tab, .name = "Last Tab", .action = .last_tab },
    .{ .id = .split_right, .name = "Split Right", .action = .{ .new_split = .right } },
    .{ .id = .split_down, .name = "Split Down", .action = .{ .new_split = .down } },
    .{ .id = .split_left, .name = "Split Left", .action = .{ .new_split = .left } },
    .{ .id = .split_up, .name = "Split Up", .action = .{ .new_split = .up } },
    .{ .id = .focus_split_right, .name = "Focus Split Right", .action = .{ .goto_split = .right } },
    .{ .id = .focus_split_down, .name = "Focus Split Down", .action = .{ .goto_split = .down } },
    .{ .id = .focus_split_left, .name = "Focus Split Left", .action = .{ .goto_split = .left } },
    .{ .id = .focus_split_up, .name = "Focus Split Up", .action = .{ .goto_split = .up } },
    .{ .id = .focus_split_previous, .name = "Focus Previous Split", .action = .{ .goto_split = .previous } },
    .{ .id = .focus_split_next, .name = "Focus Next Split", .action = .{ .goto_split = .next } },
    .{ .id = .swap_split_right, .name = "Swap Split Right", .action = .{ .swap_split = .right } },
    .{ .id = .swap_split_down, .name = "Swap Split Down", .action = .{ .swap_split = .down } },
    .{ .id = .swap_split_left, .name = "Swap Split Left", .action = .{ .swap_split = .left } },
    .{ .id = .swap_split_up, .name = "Swap Split Up", .action = .{ .swap_split = .up } },
    .{ .id = .toggle_split_zoom, .name = "Toggle Split Zoom", .action = .toggle_split_zoom },
    .{ .id = .toggle_hero_mode, .name = "Toggle Hero Mode", .action = .toggle_hero_mode },
    .{ .id = .equalize_splits, .name = "Equalize Splits", .action = .equalize_splits },
    .{ .id = .move_divider_up, .name = "Move Divider Up", .action = .{ .resize_split = .{ .up, DIVIDER_STEP } } },
    .{ .id = .move_divider_down, .name = "Move Divider Down", .action = .{ .resize_split = .{ .down, DIVIDER_STEP } } },
    .{ .id = .move_divider_left, .name = "Move Divider Left", .action = .{ .resize_split = .{ .left, DIVIDER_STEP } } },
    .{ .id = .move_divider_right, .name = "Move Divider Right", .action = .{ .resize_split = .{ .right, DIVIDER_STEP } } },
    .{ .id = .toggle_fullscreen, .name = "Toggle Fullscreen", .action = .toggle_fullscreen },
    .{ .id = .toggle_maximize, .name = "Toggle Maximize", .action = .toggle_maximize },
    .{ .id = .reset_window_size, .name = "Reset Window Size", .action = .reset_window_size },
    .{ .id = .toggle_window_decorations, .name = "Toggle Window Decorations", .action = .toggle_window_decorations },
    .{ .id = .toggle_background_opacity, .name = "Toggle Background Opacity", .action = .toggle_background_opacity },
    .{ .id = .toggle_quick_terminal, .name = "Toggle Quick Terminal", .action = .toggle_quick_terminal },
    .{ .id = .toggle_visibility, .name = "Show/Hide All Terminals", .action = .toggle_visibility },
    .{ .id = .toggle_readonly, .name = "Toggle Read-Only", .action = .toggle_readonly },
    .{ .id = .toggle_mouse_reporting, .name = "Toggle Mouse Reporting", .action = .toggle_mouse_reporting },
    .{ .id = .copy_to_clipboard, .name = "Copy to Clipboard", .action = .{ .copy_to_clipboard = .mixed } },
    .{ .id = .paste_from_clipboard, .name = "Paste from Clipboard", .action = .paste_from_clipboard },
    .{ .id = .copy_url_to_clipboard, .name = "Copy URL to Clipboard", .action = .copy_url_to_clipboard },
    .{ .id = .copy_title_to_clipboard, .name = "Copy Title to Clipboard", .action = .copy_title_to_clipboard },
    .{ .id = .prompt_window_title, .name = "Change Window Title…", .action = .prompt_window_title },
    .{ .id = .prompt_tab_title, .name = "Change Tab Title…", .action = .prompt_tab_title },
    .{ .id = .prompt_surface_title, .name = "Change Pane Title…", .action = .prompt_surface_title },
    .{ .id = .prompt_surface_banner, .name = "Set Pane Banner…", .action = .prompt_surface_banner },
    .{ .id = .select_all, .name = "Select All", .action = .select_all },
    .{ .id = .command_palette, .name = "Command Palette", .action = .toggle_command_palette },
    .{ .id = .find, .name = "Find", .action = .start_search },
    .{ .id = .find_next, .name = "Find Next", .action = .{ .navigate_search = .next } },
    .{ .id = .find_previous, .name = "Find Previous", .action = .{ .navigate_search = .previous } },
    .{ .id = .hide_find_bar, .name = "Hide Find Bar", .action = .end_search },
    .{ .id = .search_selection, .name = "Search Selection", .action = .search_selection },
    .{ .id = .jump_to_selection, .name = "Jump to Selection", .action = .scroll_to_selection },
    .{ .id = .increase_font_size, .name = "Increase Font Size", .action = .{ .increase_font_size = 1 } },
    .{ .id = .decrease_font_size, .name = "Decrease Font Size", .action = .{ .decrease_font_size = 1 } },
    .{ .id = .reset_font_size, .name = "Reset Font Size", .action = .reset_font_size },
    .{ .id = .scroll_page_up, .name = "Scroll Page Up", .action = .scroll_page_up },
    .{ .id = .scroll_page_down, .name = "Scroll Page Down", .action = .scroll_page_down },
    .{ .id = .scroll_to_top, .name = "Scroll to Top", .action = .scroll_to_top },
    .{ .id = .scroll_to_bottom, .name = "Scroll to Bottom", .action = .scroll_to_bottom },
    .{ .id = .clear_screen, .name = "Clear Screen", .action = .clear_screen },
    .{ .id = .reset_terminal, .name = "Reset Terminal", .action = .reset },
    .{ .id = .open_config, .name = "Open Config", .action = .open_config },
    .{ .id = .reload_config, .name = "Reload Config", .action = .reload_config },
    .{ .id = .check_for_updates, .name = "Check for Updates…", .action = .check_for_updates },
    .{ .id = .help, .name = "Ghoztty Help", .action = .new_window, .kind = .help },
    .{ .id = .about, .name = "About Ghoztty", .action = .new_window, .kind = .about },
    .{ .id = .claude_integration, .name = "Install Claude Code Integration", .action = .new_window, .kind = .claude },
    .{ .id = .quit, .name = "Quit", .action = .quit, .quit_keep = true },
};

/// Pixels a "Move Divider" command shifts a split by. Mac's menu items send
/// `moveSplitDivider*` with a 10pt step; `resize_split` takes pixels.
pub const DIVIDER_STEP: u16 = 10;

/// The registry entry for `id`.
pub fn get(id: Id) Command {
    // A linear scan over a comptime-known array; every caller is a menu
    // build or a single dispatch, so this is never hot.
    for (registry) |c| if (c.id == id) return c;
    unreachable; // exhaustiveness is asserted by a test below
}

/// The registry INDEX of `id`, which is also its command-palette index.
pub fn index(id: Id) usize {
    for (registry, 0..) |c, i| if (c.id == id) return i;
    unreachable;
}

test "every Id appears exactly once in the registry" {
    inline for (@typeInfo(Id).@"enum".fields) |field| {
        const id: Id = @enumFromInt(field.value);
        var count: usize = 0;
        for (registry) |c| if (c.id == id) {
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), count);
    }
    // ...and the registry has no entries beyond the enum.
    try std.testing.expectEqual(@typeInfo(Id).@"enum".fields.len, registry.len);
}

test "get/index agree with the registry" {
    for (registry, 0..) |c, i| {
        try std.testing.expectEqual(i, index(c.id));
        try std.testing.expectEqualStrings(c.name, get(c.id).name);
    }
}

test "names are unique and non-empty" {
    for (registry, 0..) |a, i| {
        try std.testing.expect(a.name.len > 0);
        for (registry[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "only the local kinds carry a placeholder action" {
    // `remote`/`activity`/`about`/`claude` have no binding to perform, so their
    // `action` is an unused placeholder and callers must not dispatch it.
    // Everything else is dispatched verbatim, so a placeholder there would
    // silently run the wrong command.
    for (registry) |c| switch (c.kind) {
        .binding => {},
        .remote,
        .activity,
        .about,
        .claude,
        .help,
        .viewer_open_file,
        .viewer_open_url,
        .viewer_open_browser,
        => try std.testing.expectEqual(
            input.Binding.Action.new_window,
            c.action,
        ),
    };
}

test "the viewer entries carry the Mac palette names verbatim (T396)" {
    // The names are cross-platform API surface: a user who reads the Mac
    // docs (or muscle-memory) types the same words into the win32 palette.
    try std.testing.expectEqualStrings("Viewer: Open File in Pane…", get(.viewer_open_file).name);
    try std.testing.expectEqualStrings("Viewer: Open URL in Pane…", get(.viewer_open_url).name);
    try std.testing.expectEqualStrings("Viewer: Open Browser Pane", get(.viewer_open_browser).name);
}

test "quit is the only quit_keep command" {
    for (registry) |c| {
        try std.testing.expectEqual(c.id == .quit, c.quit_keep);
    }
}
