# Hero Mode — Pending Work

Continuation of hero mode implementation. The core feature is functional: Cmd+Shift+Space toggles hero mode, Cmd+Shift+Up/Down navigates panes, carousel shows snapshots, hero pane uses Core Animation for sliding. The following issues remain.

## 1. New panes not added to carousel and auto-selected

**Current**: When a new split is created (Ctrl+D) while in hero mode, the carousel doesn't add the new pane and select it.

**Expected**: New panes appear at the bottom of the carousel and are auto-selected as the hero. The `surfaceTreeDidChange` handler in `BaseTerminalController` already clamps the hero index, but it doesn't detect new leaves or update the selection.

**Fix**: In `surfaceTreeDidChange`, compare the old and new leaf lists. If a new leaf was added, find its index and call `heroModeState.select(newIndex, leafCount:)`.

## 2. Hero pane gap between windows

**Current**: The hero pane strip has a 60px gap but it uses the default background, making transitions between panes hard to see.

**Expected**: Each pane in the hero strip should have ~40px visible gap between them filled with the window background color, so during the slide animation you clearly see the division between windows.

**Fix**: In `HeroPaneContainer`, set the strip's background to the window/terminal background color. Reduce gap from 60px to 40px. The gap area between `HeroPaneSlot` views should show the background color clearly.

## 3. Carousel scroll is ~3fps

**Current**: Scrolling the carousel with the mouse wheel feels like 3fps. The `scrollWheel(with:)` handler calls `repositionStrip(animated: false)` which sets `strip.frame.origin.y` directly, but something is causing expensive redraws.

**Root cause candidates**:
- `refreshSnapshots()` timer fires every 0.15s and captures bitmaps for ALL tiles using `CALayer.render(in:)` — this is expensive and likely causes frame drops during scroll
- The strip repositioning might be triggering layout passes on all tiles

**Fix options**:
- Pause the snapshot timer while scrolling (resume after scroll ends with a short debounce)
- Only refresh snapshots for visible tiles (check if tile frame intersects the visible carousel bounds)
- Use `CATransaction.begin()` / `CATransaction.setDisableActions(true)` when setting strip position during scroll to avoid implicit animations
- Consider using the strip layer's `position` instead of `frame.origin` for scroll — layer position changes are cheaper than frame changes

## 4. Ctrl+D rebuilds entire carousel

**Current**: When a new split is created, `rebuildTiles` detects the leaf count changed and tears down all tiles, then recreates them. This causes a visible flash.

**Expected**: Incrementally add/remove tiles. When a new leaf appears, create one new `CarouselTile` and append it. When a leaf is removed, remove only that tile.

**Fix**: In `rebuildTiles`, diff the old and new leaf lists instead of comparing counts. For new leaves, create and insert tiles at the correct position. For removed leaves, remove their tiles. For unchanged leaves, keep them. This avoids the full teardown/rebuild.

## 5. Carousel scroll not bounded

**Current**: You can scroll the carousel far past the first/last item until no tiles are visible.

**Expected**: Scroll should be bounded so the first item can't go below the center and the last item can't go above the center. Rubber-band effect at the limits would be ideal.

**Fix**: In `scrollWheel(with:)`, compute proper min/max scroll bounds:
```
let stride = thumbSize.height + gap
let totalContentHeight = CGFloat(tiles.count) * stride - gap
let maxScrollUp = -(totalContentHeight - thumbSize.height) / 2
let maxScrollDown = (totalContentHeight - thumbSize.height) / 2
scrollOffset = max(maxScrollUp, min(maxScrollDown, scrollOffset))
```
The current `maxScroll = totalHeight * 0.8` is too generous.

## Files involved

| File | Issues |
|---|---|
| `macos/Sources/Features/Terminal/BaseTerminalController.swift` | #1 (new pane detection) |
| `macos/Sources/Features/HeroMode/HeroPaneView.swift` | #2 (gap + bg color) |
| `macos/Sources/Features/HeroMode/HeroCarouselView.swift` | #3, #4, #5 (scroll perf, incremental rebuild, bounds) |
| `macos/Sources/Features/HeroMode/HeroModeState.swift` | potentially #1 (selection logic) |
