# Windows parity — audit appendix (2026-07-12)

Reference only; not part of resume. Re-audit only if the win32 apprt
changes wholesale.


Three-way audit (action matrix, GUI features, config coverage) of win32 vs
Mac. Condensed; re-audit only if the win32 apprt changes wholesale.

**Action coverage:** the win32 `performAction` switch
(`src/apprt/win32/App.zig:462`) is exhaustive (no else arm). Only three
actions return `false`: `swap_split`, `toggle_hero_mode`, `activity_state`
(→ T14/T18/T19). Silent no-ops (`return true`, nothing happens):
`inspector`, `render_inspector`, `readonly`, `key_sequence`, `key_table`,
`pwd`, `cell_size`, `goto_window`, `toggle_tab_overview`, `secure_input`,
`undo`, `redo` (→ T28 + backlog). Everything else is genuinely
implemented, including: search overlay, command palette (~45 entries +
user entries), quick terminal (full position/size/screen/autohide/
animation), global hotkeys (`global:` keybinds via RegisterHotKey),
desktop notifications (tray balloons), taskbar progress (OSC 9;4),
clipboard confirmation flows (paste protection + OSC 52), IME/preedit,
file drag-drop, DPI changes, resize overlay, background opacity + blur,
DWM dark/light chrome, float-on-top, split management incl. zoom/equalize/
divider drag, custom tab bar with drag-reorder + context menu + inline
rename, config open/reload (soft+hard, rewires theme/hotkeys/QT live).

**Config coverage:** honored — background-opacity/blur (blur radius knob
N/A on DWM), window-theme, window-position, window-new-tab-position,
window-show-tab-bar, padding, resize-overlay, fullscreen/maximize,
quick-terminal-*, mouse-hide-while-typing, cursor-*, unfocused-split-*,
split-divider-color, confirm-close-surface (window granularity),
clipboard-*, desktop-notifications, notify-on-command-finish*,
progress-style, title, global keybinds, quit-after-last-window-closed(+
delay), command-palette-entry, custom-shader (shared GL renderer).
Ignored/missing — window-save-state (backlog), `class`/x11 (N/A),
macos-*/gtk-* (N/A), shell-integration under pwsh/cmd (→ T27), OS
light↔dark reactivity for terminal-side conditional config (→ T26),
auto-update disabled (→ T24). Config file on Windows:
`%LOCALAPPDATA%\ghostty\config.ghostty` (XDG fallback rules; note the
`ghostty` dir name, only the updater throttle uses `ghoztty`).

**Mac-side oddity:** `toggle_window_decorations`, `size_limit`,
`quit_timer`, `toggle_tab_overview` appear to fall through to
`showChildExited` in the Mac dispatch — suspected bad fork merge (→ T29).

