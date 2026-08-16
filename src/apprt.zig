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

    // (The pure user-PATH logic moved to `os/path_env.zig` with T42 — the
    // agent's user-env overlay needs it too — and is exercised from
    // `os/main.zig`'s test block, i.e. in every lane rather than just this one.)

    // Pure win32 Claude Code setup logic (T71), same no-OS-imports deal.
    _ = @import("apprt/win32/claude_setup.zig");

    // Pure win32 managed-artifact marker + install-state grammar (T865),
    // same no-OS-imports deal.
    _ = @import("apprt/win32/managed_marker.zig");

    // Win32 marker-guarded atomic writer (T865). Plain `std.fs` plus a
    // comptime-guarded Windows rename/reparse probe, so it compiles and its
    // tempdir tests run in every lane on both seats (the Windows-only tests
    // skip themselves elsewhere).
    _ = @import("apprt/win32/managed_file.zig");

    // Embedded agent-integration assets (T866): @embedFile only, no OS
    // imports, so the content checks run in every lane on both seats.
    _ = @import("apprt/win32/GhosttyAssets.zig");

    // Agent-runtime registry enum + hook-script layout (T867), pure logic in
    // every lane; the skill/script installers below are std.fs + the T865
    // writer, so their tempdir tests run everywhere too.
    _ = @import("apprt/win32/runtime_agent.zig");
    _ = @import("apprt/win32/hook_scripts.zig");
    _ = @import("apprt/win32/SkillComponent.zig");
    _ = @import("apprt/win32/BannerScriptInstaller.zig");

    // Hook registration (T868): deterministic JSON, the per-runtime hook
    // specs, and the component that lands them — Copilot's dedicated file
    // via the T865 writer, Claude's fragment merged into the shared
    // settings.json. Pure logic + std.fs tempdir tests, every lane.
    _ = @import("apprt/win32/stable_json.zig");
    _ = @import("apprt/win32/hook_spec.zig");
    _ = @import("apprt/win32/ClaudeHookSpec.zig");
    _ = @import("apprt/win32/CopilotHookSpec.zig");
    _ = @import("apprt/win32/HookComponent.zig");

    // Runtime registry + aggregate install flow (T869): the binary probe,
    // the external-plugin manifest gate, the rollback/refcount integration
    // and the UI-facing service. std.fs tempdir tests, every lane.
    _ = @import("apprt/win32/runtime_probe.zig");
    _ = @import("apprt/win32/claude_plugin_manifest.zig");
    _ = @import("apprt/win32/RuntimeIntegration.zig");
    _ = @import("apprt/win32/agent_integration_service.zig");

    // Agent Integrations dialog row derivation (T871): pure presentation
    // logic over the service statuses, no OS imports, every lane.
    _ = @import("apprt/win32/agent_integrations_vm.zig");

    // Claude plugin → app migration (T870): manifest-driven uninstall via
    // Claude's own CLI (injected), banner-state carry-over, stale-script
    // ownership proofs. std.fs tempdir tests, every lane.
    _ = @import("apprt/win32/claude_plugin_migration.zig");

    // Pure win32 tab accent-color logic (T72), same no-OS-imports deal.
    _ = @import("apprt/win32/tab_color.zig");

    // Pure win32 title-font face resolution (T78), same no-OS-imports deal.
    _ = @import("apprt/win32/title_font.zig");

    // Pure win32 leading-spinner-cell split (T60), same no-OS-imports deal.
    _ = @import("apprt/win32/title_spinner.zig");

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

    // Pure win32 banner-link click scheme + action menu model (T165), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/banner_link.zig");

    // Pure win32 read-only pane badge geometry + contrast floors (T445),
    // same no-OS-imports deal.
    _ = @import("apprt/win32/readonly_badge.zig");

    // Pure win32 key-state model — the key-table stack and the pending key
    // sequence behind the indicator pill (T446), same no-OS-imports deal.
    _ = @import("apprt/win32/key_state.zig");

    // Pure win32 key-state pill geometry, contrast floors and card pixels
    // (T446), same no-OS-imports deal.
    _ = @import("apprt/win32/key_state_pill.zig");

    // Pure win32 split-divider geometry (T155), same no-OS-imports deal.
    _ = @import("apprt/win32/split_geometry.zig");

    // Pure win32 split-divider drag SEMANTICS — which other boundaries hold
    // their pixel when one divider moves (T533), same no-OS-imports deal.
    _ = @import("apprt/win32/split_resize.zig");

    // Pure win32 tab-strip geometry (T202), same no-OS-imports deal.
    _ = @import("apprt/win32/tab_strip_layout.zig");

    // Pure win32 tab-tooltip text derivation — home→~ and middle-component
    // elision (T447), same no-OS-imports deal.
    _ = @import("apprt/win32/tab_tooltip.zig");

    // Pure win32 icon-button geometry shared by the tab strip and the pane
    // banner (T204), same no-OS-imports deal.
    _ = @import("apprt/win32/icon_button.zig");

    // Pure win32 caption-bar geometry (T254), same no-OS-imports deal.
    _ = @import("apprt/win32/caption_layout.zig");

    // Pure win32 per-pixel tab silhouette + rim (T206), same no-OS-imports
    // deal.
    _ = @import("apprt/win32/tab_shape.zig");

    // Pure win32 chrome color resolution — system accent + the derived
    // bar/hover/text palette (T304), same no-OS-imports deal.
    _ = @import("apprt/win32/chrome_theme.zig");

    // Pure win32 dialog type ramp — caption/body/subtitle in one place
    // (T310), same no-OS-imports deal.
    _ = @import("apprt/win32/type_ramp.zig");

    // Pure win32 PANEL color resolution — the Activity Monitor / chooser /
    // carousel surfaces, wells, marks and their floors (T308), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/panel_theme.zig");

    // Pure win32 viewer JS bridge — the injected shim/selection blob and the
    // messages that come back up it (T375), same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_bridge.zig");

    // Pure win32 layered-overlay z-order policy (T142), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/overlay_zorder.zig");

    // Pure win32 WebView2 path/version math — the arithmetic half of the
    // loader-less runtime probe (T372), same no-OS-imports deal.
    _ = @import("apprt/win32/webview2_paths.zig");

    // Pure win32 viewer error-card geometry (T373), same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_error_card.zig");

    // Pure win32 file-viewer content logic — mode by extension, the 3-tier
    // resource resolver's path math, and the `window.__viewer` calls (T90e),
    // same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_content.zig");

    // Pure win32 git-diff viewer logic — the `git-status:`/`git-diff:` spec,
    // the git invocations it shapes, the `-z` output parsing and the
    // `window.__viewer` diff calls (T463), same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_diff.zig");

    // Pure win32 viewer address-bar logic — Windows-shaped file-path
    // classification, omnibox completion, display text (T159), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_nav.zig");

    // Pure win32 viewer nav-bar geometry + reveal policy (T159), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_nav_layout.zig");

    // Pure win32 viewer worktree provenance — strategy D's classification and
    // the 15s resolution cache (T633), same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_worktree.zig");

    // Pure win32 viewer popup routing — which `window.open()` requests leave
    // for the default browser and which become ghoztty windows, plus the size
    // the opener asked for (T163), same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_popup.zig");

    // Pure win32 viewer feedback-composer geometry — the pill, its two
    // circular actions and the band the pane insets by (T634), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_feedback_layout.zig");

    // Pure win32 viewer feedback-composer DOCUMENT — where a quoted passage
    // is inserted and which quotes are still in the report (T641), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_feedback_doc.zig");

    // Pure win32 viewer feedback REPORT — the shared JSON format, the source
    // line resolver, and the staging+rename publish (T636), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_feedback_report.zig");

    // Pure win32 viewer feedback IMAGES — stable chip numbering, which chips
    // are still in the report, and the PNG header read (T637), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_feedback_images.zig");

    // Pure win32 byte-offset ⇄ UTF-16 code-unit conversion — the boundary
    // between the pane's UTF-8 buffer and a `W` edit control's character
    // indices (T648), same no-OS-imports deal.
    _ = @import("apprt/win32/utf16_offset.zig");

    // Pure win32 region-selector rect math — a drag pulled in any direction,
    // clipped to the desktop, with a zero-area drag as a cancel (T647), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/region_select.zig");

    // Pure win32 PNG encoder — what a clipboard bitmap becomes on its way into
    // a feedback report (T637), same no-OS-imports deal.
    _ = @import("apprt/win32/png_encode.zig");

    // Pure win32 pane-content capture — the `capture-pane` request shape, the
    // size a capture is taken at, and the bottom-up-BGRA → top-down-RGB
    // transform between the renderer's readback and the PNG encoder (T275),
    // same no-OS-imports deal.
    _ = @import("apprt/win32/pane_capture.zig");

    // Pure win32 hovered-frame capture — the `capture-hover` request shape,
    // the client/non-client routing decision, the 16-bit `lparam` point
    // packing and the top-down-BGRA → RGB transform (T282), same no-OS-imports
    // deal.
    _ = @import("apprt/win32/hover_capture.zig");

    // Pure win32 packed-DIB header reader — where a clipboard bitmap's pixels
    // actually start (T637), same no-OS-imports deal.
    _ = @import("apprt/win32/dib_packed.zig");

    // Pure win32 deferred pane-HWND reap gate — whether a posted reap is still
    // aimed at the dead pane window that posted it (T681), same no-OS-imports
    // deal.
    _ = @import("apprt/win32/surface_reap.zig");

    // Pure win32 surface-window routing — which of a Surface's three windows a
    // message arrived for, and what a WM_DESTROY on it may clear (T613), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/surface_window_role.zig");

    // Pure win32 activation reading — which proxy for "is this window the
    // active one" still carries information off the input desktop (T215),
    // same no-OS-imports deal.
    _ = @import("apprt/win32/window_active.zig");

    // Pure win32 viewer TOC-card geometry + policy (T160), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/viewer_toc_layout.zig");

    // Pure win32 viewer chrome-preference parse/format — the persisted
    // side-panel card width (T160), same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_prefs.zig");

    // Pure win32 machine-chooser row model + geometry (T172), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/chooser_rows.zig");

    // Pure win32 machine-chooser master-detail layout (T175), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/chooser_layout.zig");

    // Pure win32 machine-chooser session roster — the label ladder, the
    // connectable filter, badges and the card geometry (T318), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/chooser_sessions.zig");

    // Pure win32 machine-chooser per-session CPU meter — the column's
    // geometry, the bar's fill and tone, the number's spelling, and the bounded
    // store one pushed frame lands in (T462), same no-OS-imports deal.
    _ = @import("apprt/win32/chooser_cpu.zig");

    // Pure win32 machine connection-pool bookkeeping — endpoint keying, the
    // lease refcount and the re-dial policy behind one warm connection per
    // remote machine (T461), same no-OS-imports deal.
    _ = @import("apprt/win32/machine_pool.zig");

    // Pure win32 Activity Monitor panel layout (T284), same no-OS-imports
    // deal.
    _ = @import("apprt/win32/activity_layout.zig");

    // Pure win32 Activity Monitor trend-chart geometry (T284), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/trend_gauge.zig");

    // Pure win32 Activity Monitor sampling gate — whether a poll tick should
    // enumerate at all given what the OS says about the panel's visibility
    // (T290), same no-OS-imports deal.
    _ = @import("apprt/win32/sample_gate.zig");

    // Pure win32 Activity Monitor process-row model — filter, sort and cell
    // text (T285), same no-OS-imports deal.
    _ = @import("apprt/win32/activity_rows.zig");

    // Pure win32 filter-box text search — the ONE ASCII case-fold substring
    // test behind the machine chooser's and the Activity Monitor's filters
    // (T288), same no-OS-imports deal.
    _ = @import("apprt/win32/text_search.zig");

    // Pure win32 Activity Monitor process-control model — kill labels and
    // wording, failure text, empty state and selection pruning (T286), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/activity_actions.zig");

    // Pure win32 Activity Monitor machine-card model — the carousel's ordering,
    // per-card text, status dot and focus arithmetic (T296), same no-OS-imports
    // deal.
    _ = @import("apprt/win32/activity_cards.zig");

    // Pure win32 Activity Monitor connection-borrow model — which live window's
    // connection a panel switching machines should borrow instead of dialing a
    // second one (T301), same no-OS-imports deal.
    _ = @import("apprt/win32/activity_borrow.zig");

    // Pure win32 Activity Monitor metrics-probe policy — which machines get a
    // probe connection, the refused-dial backoff and the staleness rule that
    // stops a dead link being painted as a live reading (T298), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/activity_probe.zig");

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

    // Pure win32 agent-owned layout blobs — one window in and out of the
    // SET_LAYOUT/GET_LAYOUTS wire shape (T334), same no-OS-imports deal (its
    // only non-std import is `remote/protocol.zig`, which builds in every lane).
    _ = @import("apprt/win32/layout_blobs.zig");

    // Pure win32 cross-machine frame re-anchoring — a window frame authored on
    // another machine's monitors, clamped onto one of ours (T336), same
    // no-OS-imports deal.
    _ = @import("apprt/win32/restore_frame.zig");

    // Pure win32 window-placement rules: the workspace/screen coordinate
    // boundary a `WINDOWPLACEMENT` sits on, and which show command a restore
    // asks for (T748). Imports only `restore_frame.zig` for its `Rect`.
    _ = @import("apprt/win32/window_placement.zig");

    // Pure win32 local-agent crash-recovery policy: when a dropped shared link
    // is a real drop, and whose session a tree swap may never end (T145). Its
    // only non-std import is the shared-core `remote/connection.zig` link-state
    // enum, which builds in every lane.
    _ = @import("apprt/win32/agent_recovery.zig");

    // Pure win32 non-destructive agent-upgrade policy: is the running agent
    // older than the one we ship, and may it be restarted now or only after a
    // confirmation (T147). Pure std, same no-OS-imports deal.
    _ = @import("apprt/win32/agent_upgrade.zig");

    // Pure win32 per-window remote reconnect ladder policy (T365/WP-D1): what
    // counts as a drop, the backoff schedule, when to stop, and the
    // poisoned-session breaker. Same `remote/connection.zig`-only import as
    // `agent_recovery.zig`, so it builds and tests in every lane.
    _ = @import("apprt/win32/remote_reconnect.zig");

    // Pure win32 viewer accelerator forwarding: vkey+modifiers → the KeyEvent
    // the app keybind set is consulted with, plus which bound actions a
    // viewer pane forwards at all (T394). Same no-OS-imports deal.
    _ = @import("apprt/win32/viewer_accel.zig");

    // Pure win32 window-scoped chords that are NOT binding actions — today
    // just ctrl+shift+n → the machine chooser, defined once so every focus
    // target answers the same keystroke the same way (T746). Same
    // no-OS-imports deal.
    _ = @import("apprt/win32/window_chord.zig");

    // Pure win32 remote connection pill — the caption-band affordance's
    // wording, geometry and contrast floors (T367). Its only non-std imports
    // are sibling pure modules and the reconnect policy, so it builds and tests
    // in every lane.
    _ = @import("apprt/win32/remote_pill.zig");
}
