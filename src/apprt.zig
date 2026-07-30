//! "apprt" is the "application runtime" package. This abstracts the
//! application runtime and lifecycle management such as creating windows,
//! getting user input (mouse/keyboard), etc.
//!
//! This enables compile-time interfaces to be built to swap out the underlying
//! application runtime. For example: pure macOS Cocoa, GTK+, browser, etc.
//!
//! The goal is to have different implementations share as much of the core
//! logic as possible, and to only reach out to platform-specific implementation
//! code when absolutely necessary.
const build_config = @import("build_config.zig");

const structs = @import("apprt/structs.zig");

pub const action = @import("apprt/action.zig");
pub const ipc = @import("apprt/ipc.zig");
pub const gtk = @import("apprt/gtk.zig");
pub const none = @import("apprt/none.zig");
pub const win32 = @import("apprt/win32.zig");
pub const browser = @import("apprt/browser.zig");
pub const embedded = @import("apprt/embedded.zig");
pub const surface = @import("apprt/surface.zig");

pub const Action = action.Action;
pub const Runtime = @import("apprt/runtime.zig").Runtime;
pub const Target = action.Target;

pub const ContentScale = structs.ContentScale;
pub const Clipboard = structs.Clipboard;
pub const ClipboardContent = structs.ClipboardContent;
pub const ClipboardRequest = structs.ClipboardRequest;
pub const ClipboardRequestType = structs.ClipboardRequestType;
pub const ColorScheme = structs.ColorScheme;
pub const CursorPos = structs.CursorPos;
pub const IMEPos = structs.IMEPos;
pub const Selection = structs.Selection;
pub const SurfaceSize = structs.SurfaceSize;

/// The implementation to use for the app runtime. This is comptime chosen
/// so that every build has exactly one application runtime implementation.
/// Note: it is very rare to use Runtime directly; most usage will use
/// Window or something.
pub const runtime = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) {
        .none => none,
        .gtk => gtk,
        .win32 => win32,
    },
    .lib => embedded,
    .wasm_module => browser,
};

pub const App = runtime.App;
pub const Surface = runtime.Surface;

test {
    _ = Runtime;
    _ = runtime;
    _ = action;
    _ = structs;
    _ = ipc;

    // Pure win32 hero-mode geometry: no OS imports, so its unit tests run
    // in every app-runtime lane (T59a).
    _ = @import("apprt/win32/hero_math.zig");

    // Pure win32 unfocused-split dim logic (T74), same no-OS-imports deal.
    _ = @import("apprt/win32/dim_math.zig");

    // Pure win32 background-tint color math (T67), same no-OS-imports deal.
    _ = @import("apprt/win32/color_math.zig");

    // Pure win32 user-PATH self-heal logic (T70), same no-OS-imports deal.
    _ = @import("apprt/win32/path_env.zig");

    // Pure win32 Claude Code setup logic (T71), same no-OS-imports deal.
    _ = @import("apprt/win32/claude_setup.zig");

    // Pure win32 tab accent-color logic (T72), same no-OS-imports deal.
    _ = @import("apprt/win32/tab_color.zig");

    // Pure win32 title-font face resolution (T78), same no-OS-imports deal.
    _ = @import("apprt/win32/title_font.zig");

    // Pure win32 update-check tag scan/compare (T24), same no-OS-imports deal.
    _ = @import("apprt/win32/update_check.zig");

    // Pure win32 window-placement memory parse/format/clamp (T85), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/window_memory.zig");

    // Pure win32 banner-markdown parser (T35), same no-OS-imports deal.
    _ = @import("apprt/win32/banner_markdown.zig");

    // Pure win32 banner strip-inset clamp (T101), same no-OS-imports deal.
    _ = @import("apprt/win32/banner_layout.zig");

    // Pure win32 banner glass-card pixel math (T131), same no-OS-imports
    // deal.
    _ = @import("apprt/win32/banner_card.zig");

    // Pure win32 split-divider geometry (T155), same no-OS-imports deal.
    _ = @import("apprt/win32/split_geometry.zig");

    // Pure win32 layered-overlay z-order policy (T142), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/overlay_zorder.zig");

    // Pure win32 machine-chooser row model + geometry (T172), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/chooser_rows.zig");

    // Pure win32 machine-chooser master-detail layout (T175), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/chooser_layout.zig");

    // Pure win32 surface context-menu model (T102), same no-OS-imports deal.
    _ = @import("apprt/win32/context_menu.zig");

    // Pure win32 command registry — the one list the palette and the menu
    // system both render (T189), same no-OS-imports deal.
    _ = @import("apprt/win32/commands.zig");

    // Pure win32 menu-system tree, mnemonics and per-item state (T143/T189),
    // same no-OS-imports deal.
    _ = @import("apprt/win32/menu_bar.zig");

    // Pure win32 menu accelerator labeling — shared by the context menu and
    // the menu system (T190), same no-OS-imports deal.
    _ = @import("apprt/win32/menu_label.zig");

    // Pure win32 pane-identity (UUID generation + legacy surface-id target
    // aliases, T113), same no-OS-imports deal.
    _ = @import("apprt/win32/pane_id.zig");

    // Pure win32 session-layout manifest schema + JSON I/O (T89f1), same
    // no-OS-imports deal (LOCALAPPDATA path resolution degrades cleanly off
    // Windows / in the none lane).
    _ = @import("apprt/win32/session_layout.zig");
}
