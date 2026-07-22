# Viewer pane zoom — design

## Goal

Give Ghoztty **viewer panes** browser-style zoom that feels like every other Mac
browser:

- **Trackpad pinch** zooms in/out.
- **Cmd + / Cmd − / Cmd 0** zoom in / out / reset from the keyboard.

This applies to **all viewer content** — http/https websites, rendered markdown,
and syntax-highlighted code/text files — not just websites.

## Context

Viewer panes are `WKWebView`-based (`macos/Sources/Features/Viewer/ViewerView.swift`).
Every viewer kind renders in that single web view:

- `.web` navigates the web view directly.
- `.markdown` / `.code` render through the bundled `ghoztty-viewer://` template
  page (markdown-it / highlight.js) via JS injection.

Because there is exactly one web view per pane, zoom applied at the web-view
level covers all three kinds in one shot.

### Keyboard dispatch (traced)

- The terminal font-size actions (`increase_font_size` / `decrease_font_size` /
  `reset_font_size`) are bound by default to `ctrlOrSuper` + `=` / `+` / `-` /
  `0` (`src/config/Config.zig`).
- On macOS these reach the app as **menu key equivalents** whose IBActions live
  on `BaseTerminalController` (`increaseFontSize` / `decreaseFontSize` /
  `resetFontSize`), each of which `guard let surface = focusedSurface?.surface`
  and no-ops when no terminal surface is focused.
- `NSWindow.performKeyEquivalent` walks the **entire** view hierarchy (not just
  the first-responder chain) before the main menu's key equivalents fire.
  `ViewerView` already overrides `performKeyEquivalent(with:)` to swallow the
  hero-nav chords, so it is the natural, precedent-following place to intercept
  the zoom chords **before** the menu can route them to the terminal.
- A focused viewer's first responder is the inner `WKWebView` (see
  `becomeFirstResponder`). Because `performKeyEquivalent` is offered to every
  view in the window, the override must **guard on this viewer's own web view
  being first responder** so it does not steal the event from a focused terminal
  in the same window, nor react in an unfocused viewer split.

## Approach

Two **independent** zoom mechanisms on the pane's `WKWebView`, matching Safari
(pinch = pixel magnification, Cmd+/− = reflow page zoom).

### 1. Trackpad pinch → `WKWebView.allowsMagnification`

Set `webView.allowsMagnification = true` in `setupWebView(adopting:)` for every
viewer (including adopted popup web views). This is the native smooth
pinch-to-zoom (pixel magnification). It is **ephemeral** — not persisted, exactly
like Safari's pinch — and needs no other wiring.

### 2. Cmd + / Cmd − / Cmd 0 → `WKWebView.pageZoom`

Use the public `WKWebView.pageZoom` API (reflow zoom), intercepted in
`ViewerView.performKeyEquivalent(with:)`.

- **Focus guard.** Handle only when this viewer's content is first responder:
  `window?.firstResponder === webView || responder.isDescendant(of: webView)`.
  The address field / chrome bar are descendants of the pane but **not** of the
  web view, so this naturally excludes them, and a focused terminal or an
  unfocused viewer split is excluded too. Otherwise return
  `super.performKeyEquivalent(with:)`.
- **Chord classification.** A pure static classifier `zoomAction(for:) ->
  ZoomAction?` (mirrors the existing `isHeroNavChord`) returns `.in` / `.out` /
  `.reset` / `nil`:
  - require `.command`; exclude `.control` and `.option`;
  - `=` or `+` (Shift allowed for `+`) → `.in`
  - `-` → `.out`
  - `0` → `.reset`
  - Uses `charactersIgnoringModifiers` for the base character.
  - **Deliberate simplification:** matches the *default* chords only, not
    user-remapped font-size bindings. First-cut tradeoff; the defaults are the
    documented Cmd+/−/0.
- **Apply.** A `zoomFactor: CGFloat` property (default `1.0`) is stepped ×1.1 for
  `.in`, ÷1.1 for `.out`, clamped to `[0.5, 3.0]`; `.reset` sets `1.0`. On change,
  set `webView.pageZoom = zoomFactor`. Return `true` so the menu never
  double-handles the chord.
- **In-session stickiness.** Reapply `webView.pageZoom = zoomFactor` in the
  navigation delegate (`didCommit` / `didFinish`) when `zoomFactor != 1.0`, so
  zoom survives clicking links or typing addresses within the pane during the
  session.

### Persistence

**Reset on restore (chosen).** Zoom applies live within the session only. A pane
comes back at 100% after an app quit/relaunch. No `SessionLayoutManifest` /
`SessionLayoutRestore` changes.

Tradeoff: a pane you had zoomed loses that zoom after a relaunch. Accepted for
the first cut; can be added later as an additive `viewerZoom` manifest field
(same pattern as `banner` / `viewerOriginDirectory`).

## Out of scope (first cut)

- **Command-palette entries** ("Viewer: Zoom In / Out / Reset"). Keyboard + pinch
  cover the need, and the palette plumbing targets terminal `SurfaceView`s, not
  viewers, so wiring it would mean resolving the focused viewer — extra
  complexity for no new capability. Noted as a straightforward future addition.
- Cross-restore zoom persistence (see above).
- Honoring user-remapped font-size keybindings for viewer zoom (see above).

## Files touched

- `macos/Sources/Features/Viewer/ViewerView.swift` — the entire change:
  `allowsMagnification`, the `zoomFactor` property + apply helper, the
  `performKeyEquivalent` interception + `zoomAction(for:)` classifier, and the
  `didCommit`/`didFinish` reapply.
- A viewer test file (e.g. `macos/Tests/Ghostty/ViewerChromeBarTests.swift` or a
  new `ViewerZoomTests.swift`) — unit tests for `zoomAction(for:)`.

## Verification

Build the debug app only (`zig build -Doptimize=Debug`, test with
`zig-out/Ghoztty-Debug.app`; never touch `/Applications/Ghoztty.app`):

1. Pinch-zoom a **website** viewer, a **markdown** viewer, and a **code-file**
   viewer — all magnify.
2. Cmd+/−/0 zoom a focused viewer (in, out, reset).
3. A focused **terminal** pane still changes **font size** with Cmd+/−/0.
4. An **unfocused** viewer split does not react to Cmd+/−/0 aimed at a focused
   terminal or another pane.
5. Unit test: `zoomAction(for:)` returns the right action for the zoom chords and
   `nil` for unrelated events.
