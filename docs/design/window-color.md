# Window & Pane Background Color

## Overview

Ghoztty supports custom background colors for windows and panes, settable via
CLI flags (`--color`, `--split-color`), IPC, or the macOS context menu color
picker. When a pane is split, the child inherits and shifts the parent's
background color to create visual depth.

## Setting a Background Color

| Method | Scope |
|--------|-------|
| `ghoztty +new-window --color=#1a1a2e` | Window background |
| `ghoztty +new-window --split=right --split-color=#ff0000` | Initial split |
| `ghoztty +split --color=#00ff00` | New split pane |
| Right-click → "Background Color..." | Active pane (live preview) |

Colors are validated as 4- or 7-character hex strings (`#rgb` or `#rrggbb`).

## Windows

Windows implements the same feature natively (T67): the CLI flags and split
inheritance behave identically; the context menu's "Background Color..."
opens the Win32 common color dialog (`ChooseColorW`) seeded with the pane's
effective background — modal, so no live preview. Explicit colors apply the
background, a black/white contrast foreground, and the WCAG-adjusted ANSI
palette directly to the terminal (there is no overlay layer on win32; the
auto-shifted split tint also sets the terminal background, without touching
the palette). `+list --json` panes report the tint as an additive
`background_tint` field. Pure color math lives in
`src/apprt/win32/color_math.zig`. Note the shipping shift amount is 5%
(`shiftedTint`, matching the Mac code); the 15% figures below are the
original design's worked example.

## Color Picker Behavior

The macOS context menu exposes "Background Color..." which opens
`NSColorPanel`. Requirements:

- **Initial color**: The panel MUST open showing the pane's current background
  tint. If no tint has been set, it defaults to `windowBackgroundColor`.
- **Live preview**: `isContinuous = true` with a 150ms debounce timer to avoid
  excessive palette recomputation.
- **Cleanup**: The panel is dismissed when the surface is deallocated or moved
  out of a window.

### Implementation detail

Colors are stored as `NSColor` internally (`backgroundTintNSColor`) and derived
to SwiftUI `Color` (`backgroundTint`) for the overlay rendering. The `NSColor`
is the source of truth — this avoids the lossy `Color → NSColor` roundtrip
through SwiftUI's catalog color system, which breaks `getHue`/`getRed`
extraction.

## Split Color Inheritance

Every split inherits a shifted background from its parent. When a pane is
split (via keybinding or IPC) without an explicit `--color`:

1. Determine the parent's effective background:
   - If the parent has an explicit `backgroundTintNSColor` (from color picker,
     IPC, or inherited from its own parent), use that.
   - Otherwise, read the terminal's configured background color from
     `derivedConfig.backgroundColor`.
2. Compute a shifted tint:
   - **Dark background** (luminance ≤ 0.5): lighten brightness by 15%.
   - **Light background** (luminance > 0.5): darken brightness by 15%.
3. Preserve hue and saturation — only brightness changes.
4. Apply the shifted color as the child's background tint.
5. Adjust the ANSI palette for contrast against the new background.

This creates a visual stacking effect: each split level is slightly lighter
(or darker) than its parent, making pane boundaries intuitive. The effect
compounds — a third-level split is noticeably lighter/darker than the
original window.

### Shift algorithm

Uses HSB color space. The shift preserves the color's identity while nudging
brightness away from the extremes:

- `lighten(by: 0.15)`: `newB = min(b + (1 - b) * 0.15, 1.0)`
- `darken(by: 0.15)`: `newB = min(b * (1 - 0.15), 1.0)`

## Palette Contrast Adjustment

When a background color is applied, all 16 ANSI palette colors (indices 0–15)
are adjusted to maintain a minimum contrast ratio of 0.35 (luminance
difference) against the background:

- Foreground is set to black or white depending on background luminance.
- Each ANSI color's brightness is shifted away from the background luminance if
  contrast falls below the threshold.
- Hue and saturation are preserved.

## Architecture

```
CLI (Zig)                    IPC (Swift)                   UI (Swift)
──────────                   ──────────                    ─────────
+new-window --color=#hex ──→ IPCServer.applyColorScheme ──→ SurfaceConfiguration.backgroundTint
+split --color=#hex ───────→ IPCServer.applyColorScheme    │
                                                           ├→ SurfaceView_AppKit.backgroundTintNSColor (NSColor, source of truth)
                                                           ├→ SurfaceView_AppKit.backgroundTint (SwiftUI Color, for overlay)
Context menu ──────────────→ pickBackgroundColor ──────────→│
                                                           └→ applyPaletteForColor → ghostty_surface_set_color (C API)

Keybinding split ──→ ghosttyDidNewSplit ──→ newSplit ──→ shiftedTint(parentNSColor) ──→ child config
```

## C API

- `ghostty_surface_set_color(surface, kind, index, r, g, b)` — set palette (0), foreground (1), or background (2)
- `ghostty_surface_reset_colors(surface)` — reset all colors to defaults
