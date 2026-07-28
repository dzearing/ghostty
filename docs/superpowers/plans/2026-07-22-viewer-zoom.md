# Viewer Pane Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Ghoztty viewer panes browser-style zoom — trackpad pinch plus Cmd+/−/0 — across all viewer content (websites, markdown, code/text files).

**Architecture:** Two independent zoom mechanisms on the viewer's single `WKWebView`, matching Safari: trackpad pinch uses native pixel magnification (`allowsMagnification`); keyboard Cmd+/−/0 uses reflow page zoom (`pageZoom`), intercepted in `ViewerView.performKeyEquivalent(with:)` (the same override that already swallows hero-nav chords) and guarded so it only fires when this viewer's own web content is first responder. Zoom is in-session only — reset on session restore.

**Tech Stack:** Swift, AppKit, WebKit (`WKWebView`), Swift Testing.

## Global Constraints

- Fork is named **Ghoztty** (with a Z) — keep any user-facing strings consistent.
- Build the **debug** app only: `zig build -Doptimize=Debug`, test with `zig-out/Ghoztty-Debug.app`. **NEVER** modify/touch `/Applications/Ghoztty.app`.
- Swift tests run from `macos/`: `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'` then `xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/<SuiteName>`. Filter by SUITE (Swift Testing struct); function-level filters silently match nothing. Use `build-for-testing` + `test-without-building` (not plain `test`) to avoid running a stale incrementally-linked binary.
- No AI attribution in commits.
- Do not commit unless the user asks (the user's global rule overrides TDD's "commit" steps — treat commit steps as "stage and be ready to commit"; only actually commit on request).

---

### Task 1: Pure zoom logic — chord classifier + zoom stepping

The keyboard side has two pieces of pure logic worth isolating and unit-testing: classifying a key event as a zoom chord, and computing the next clamped zoom factor. Both are static, side-effect-free, and testable without a live web view.

**Files:**
- Modify: `macos/Sources/Features/Viewer/ViewerView.swift` (add the `ZoomAction` enum and two static helpers near the existing `performKeyEquivalent` / `isHeroNavChord`, around line 1917–1926)
- Test: `macos/Tests/Ghostty/ViewerZoomTests.swift` (new)

**Interfaces:**
- Produces (used by Task 2):
  - `enum ViewerView.ZoomAction { case zoomIn, zoomOut, reset }`
  - `static func ViewerView.zoomAction(for event: NSEvent) -> ViewerView.ZoomAction?`
  - `static func ViewerView.steppedZoom(from current: CGFloat, action: ZoomAction) -> CGFloat`
  - `static let ViewerView.minZoom: CGFloat` (0.5), `maxZoom: CGFloat` (3.0), `zoomStep: CGFloat` (1.1)

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/Ghostty/ViewerZoomTests.swift`:

```swift
import AppKit
import Testing
@testable import Ghostty

/// Classification of Cmd+/−/0 key events into viewer zoom actions, and the
/// clamped page-zoom stepping they drive. Pure logic — no live web view.
@MainActor
struct ViewerZoomTests {
    /// Build a key-equivalent NSEvent with the given base characters and mods.
    private func keyEvent(
        _ chars: String,
        _ mods: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: mods,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: 0)!
    }

    @Test func cmdEqualsAndPlusZoomIn() {
        #expect(ViewerView.zoomAction(for: keyEvent("=", .command)) == .zoomIn)
        // Shift+= produces "+"; charactersIgnoringModifiers keeps shift.
        #expect(ViewerView.zoomAction(for: keyEvent("+", [.command, .shift])) == .zoomIn)
    }

    @Test func cmdMinusZoomsOut() {
        #expect(ViewerView.zoomAction(for: keyEvent("-", .command)) == .zoomOut)
    }

    @Test func cmdZeroResets() {
        #expect(ViewerView.zoomAction(for: keyEvent("0", .command)) == .reset)
    }

    @Test func requiresCommandAndRejectsOptionOrControl() {
        // No command modifier at all.
        #expect(ViewerView.zoomAction(for: keyEvent("=", [])) == nil)
        // Command plus a disqualifying modifier.
        #expect(ViewerView.zoomAction(for: keyEvent("=", [.command, .option])) == nil)
        #expect(ViewerView.zoomAction(for: keyEvent("-", [.command, .control])) == nil)
    }

    @Test func unrelatedKeysAreNotZoom() {
        #expect(ViewerView.zoomAction(for: keyEvent("a", .command)) == nil)
        #expect(ViewerView.zoomAction(for: keyEvent("1", .command)) == nil)
    }

    @Test func steppingMovesByTheStepFactor() {
        #expect(ViewerView.steppedZoom(from: 1.0, action: .zoomIn) == 1.1)
        // Divide by the step factor for zoom out.
        #expect(abs(ViewerView.steppedZoom(from: 1.1, action: .zoomOut) - 1.0) < 0.0001)
        #expect(ViewerView.steppedZoom(from: 2.0, action: .reset) == 1.0)
    }

    @Test func steppingClampsToRange() {
        #expect(ViewerView.steppedZoom(from: ViewerView.maxZoom, action: .zoomIn) == ViewerView.maxZoom)
        #expect(ViewerView.steppedZoom(from: ViewerView.minZoom, action: .zoomOut) == ViewerView.minZoom)
    }
}
```

- [ ] **Step 2: Add the new test file to the Xcode test target**

`ViewerZoomTests.swift` must be a member of the `GhosttyTests` target or xcodebuild won't compile it. Ghostty's project generates its file list, but confirm: after creating the file, run the build-for-testing command in Step 4 — if the file is not picked up (tests "match nothing"), add it to the `GhosttyTests` target the same way sibling files under `macos/Tests/Ghostty/` are registered (check `macos/Ghostty.xcodeproj/project.pbxproj` for a `ViewerChromeBarTests.swift` reference and mirror it, or add via Xcode). Most likely the folder is a synchronized group and no edit is needed.

- [ ] **Step 3: Run the tests to verify they fail**

Run (from `macos/`):
```bash
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS'
```
Expected: BUILD FAILS — `zoomAction(for:)`, `steppedZoom(from:action:)`, and `ViewerView.ZoomAction` / `minZoom` / `maxZoom` are not defined yet.

- [ ] **Step 4: Implement the pure logic**

In `macos/Sources/Features/Viewer/ViewerView.swift`, in the `// MARK: - Focus` section immediately after `isHeroNavChord` (around line 1926), add:

```swift
    // MARK: - Zoom (keyboard page zoom)

    /// A Cmd+/−/0 keyboard-zoom request. Trackpad pinch is handled entirely by
    /// WebKit (`allowsMagnification`) and is independent of this.
    enum ZoomAction { case zoomIn, zoomOut, reset }

    /// Keyboard page-zoom bounds and per-press step. 1.0 is 100%.
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 3.0
    static let zoomStep: CGFloat = 1.1

    /// Classify a key event as a viewer zoom chord, or nil if it is not one.
    ///
    /// Matches the DEFAULT font-size chords (Cmd + `=`/`+`/`-`/`0`) — the same
    /// keys `Config.zig` binds to increase/decrease/reset_font_size. Deliberately
    /// does NOT consult user-remapped bindings (first-cut simplification).
    /// Requires Command and rejects Control/Option so it never collides with
    /// other chords. `charactersIgnoringModifiers` keeps Shift, so Shift+= ("+")
    /// still reads as zoom-in.
    static func zoomAction(for event: NSEvent) -> ZoomAction? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command),
              !mods.contains(.control),
              !mods.contains(.option),
              let chars = event.charactersIgnoringModifiers
        else { return nil }
        switch chars {
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        case "0": return .reset
        default: return nil
        }
    }

    /// The next page-zoom factor for an action, clamped to [minZoom, maxZoom].
    static func steppedZoom(from current: CGFloat, action: ZoomAction) -> CGFloat {
        switch action {
        case .zoomIn: return min(maxZoom, current * zoomStep)
        case .zoomOut: return max(minZoom, current / zoomStep)
        case .reset: return 1.0
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run (from `macos/`):
```bash
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' && \
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/ViewerZoomTests
```
Expected: all `ViewerZoomTests` tests PASS.

- [ ] **Step 6: Stage the change (commit only if the user asks)**

```bash
git add macos/Sources/Features/Viewer/ViewerView.swift macos/Tests/Ghostty/ViewerZoomTests.swift
# Commit only on user request:
# git commit -m "feat(viewer): add pure zoom chord classifier + stepping"
```

---

### Task 2: Wire zoom into the viewer web view

Enable pinch magnification, add the in-session `zoomFactor` state, intercept the zoom chords in `performKeyEquivalent` (focus-guarded), and reapply page zoom after in-pane navigation. This task is verified manually in the real debug build — the behavior depends on live `WKWebView` magnification/pageZoom and AppKit first-responder routing, which are not reliably exercisable headless.

**Files:**
- Modify: `macos/Sources/Features/Viewer/ViewerView.swift`
  - `setupWebView(adopting:)` — enable `allowsMagnification` (after line ~447, `allowsBackForwardNavigationGestures = isWebURL`)
  - add `zoomFactor` stored property + `pushZoomToWebView()` / `handleZoom(_:)` / `isViewerContentFocused` helpers (near the zoom logic from Task 1)
  - `performKeyEquivalent(with:)` — intercept zoom chords (lines ~1917–1920)
  - `webView(_:didFinish:)` — reapply zoom (lines ~2003–2010)

**Interfaces:**
- Consumes (from Task 1): `ZoomAction`, `zoomAction(for:)`, `steppedZoom(from:action:)`.
- Produces: no new API surface; internal behavior only.

- [ ] **Step 1: Enable trackpad pinch magnification**

In `setupWebView(adopting:)`, immediately after:
```swift
        webView.allowsBackForwardNavigationGestures = isWebURL
```
add:
```swift
        // Trackpad pinch magnifies the pane (native pixel zoom, like Safari's
        // two-finger pinch), for every viewer kind — web, markdown, and code all
        // render in this one web view. This is independent of keyboard page zoom
        // (Cmd+/−/0, see performKeyEquivalent) and is ephemeral: WebKit tracks
        // the magnification itself and we do not persist it, matching Safari.
        webView.allowsMagnification = true
```
(This is in the shared post-`if/else` section, so it applies to adopted popup web views too.)

- [ ] **Step 2: Add zoom state + helpers**

In the `// MARK: - Zoom (keyboard page zoom)` section added in Task 1, after `steppedZoom(...)`, add the instance state and helpers:

```swift
    /// The keyboard (Cmd+/−/0) page-zoom factor for this pane. 1.0 is 100%.
    /// In-session only — deliberately NOT persisted, so a restored pane comes
    /// back at 100%. Independent of trackpad pinch magnification, which WebKit
    /// tracks itself.
    private var zoomFactor: CGFloat = 1.0

    /// Push the current `zoomFactor` to the web view.
    private func pushZoomToWebView() {
        webView.pageZoom = zoomFactor
    }

    /// Apply a Cmd+/−/0 zoom chord: step the factor and push it to the page.
    private func handleZoom(_ action: ZoomAction) {
        zoomFactor = Self.steppedZoom(from: zoomFactor, action: action)
        pushZoomToWebView()
    }

    /// True when THIS viewer's own web content holds keyboard focus. The guard
    /// that keeps zoom chords from stealing Cmd+/−/0 from a focused terminal in
    /// the same window (performKeyEquivalent is offered to every view, not just
    /// the focused one) and from firing in an unfocused viewer split. The chrome
    /// bar's address field is a descendant of the pane but NOT of the web view,
    /// so it is excluded too.
    private var isViewerContentFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }
```

- [ ] **Step 3: Intercept the zoom chords in performKeyEquivalent**

Replace the existing override (lines ~1917–1920):
```swift
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isHeroNavChord(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
```
with:
```swift
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isHeroNavChord(event) { return true }
        // Cmd+/−/0 zoom the viewer instead of the terminal font size — but only
        // when this viewer's own content is focused, so a focused terminal in
        // the same window keeps its font-size behavior and an unfocused viewer
        // split stays put. Returning true stops the event before the menu's
        // font-size key equivalent (which runs AFTER the view hierarchy's
        // performKeyEquivalent walk) can route it to the terminal.
        if isViewerContentFocused, let action = Self.zoomAction(for: event) {
            handleZoom(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
```

- [ ] **Step 4: Reapply zoom after in-pane navigation**

In `webView(_:didFinish:)` (lines ~2003–2010), add the reapply as the first statement, BEFORE the `if case .web = mode { return }` early return:
```swift
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A fresh navigation can drop pageZoom; reapply so keyboard zoom sticks
        // as the user follows links / types addresses within the pane (all
        // modes). Cheap no-op at 100%.
        if zoomFactor != 1.0 { pushZoomToWebView() }
        if case .web = mode { return }
        pageLoaded = true
        renderFileContent()
        // A reload/renavigation resets the document, taking the body padding
        // the TOC gutter relies on with it.
        pushTOCGutter()
    }
```

- [ ] **Step 5: Build the debug app**

Run (from repo root):
```bash
zig build -Doptimize=Debug
```
Expected: build succeeds, producing `zig-out/Ghoztty-Debug.app`.

- [ ] **Step 6: Manually verify in the debug build**

Launch `zig-out/Ghoztty-Debug.app` (the debug build uses a separate socket/bundle id, so it runs alongside the release app — never touch `/Applications/Ghoztty.app`). Then, using the `ghoztty` CLI against the debug instance (or the menu/palette):

1. Open a **website** viewer: `ghoztty +new-window --view=https://example.com`. Trackpad-pinch → the page magnifies. Cmd+= / Cmd+- / Cmd+0 → page zooms in / out / resets.
2. Open a **markdown** viewer: `ghoztty +new-window --view=README.md`. Pinch magnifies; Cmd+/−/0 zoom the rendered document.
3. Open a **code-file** viewer: `ghoztty +new-window --view=<some source file>`. Pinch magnifies; Cmd+/−/0 zoom the highlighted code.
4. In a window with a terminal pane focused, Cmd+/−/0 still change the **terminal font size** (unchanged behavior).
5. Split a viewer beside a terminal (`ghoztty +split --view=README.md`), focus the terminal, press Cmd+/−/0 → the terminal font changes and the **unfocused viewer does NOT zoom**. Then click into the viewer and confirm Cmd+/−/0 now zoom it.
6. Zoom a viewer, click a link / type a new address in it → the new page stays at the zoom level (in-session stickiness).

Record the observed result for each check.

- [ ] **Step 7: Run the full viewer test suites (regression)**

Run (from `macos/`):
```bash
xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' && \
xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' -only-testing:GhosttyTests/ViewerZoomTests -only-testing:GhosttyTests/ViewerChromeBarTests
```
Expected: all PASS (zoom logic + chrome-bar regression).

- [ ] **Step 8: Stage the change (commit only if the user asks)**

```bash
git add macos/Sources/Features/Viewer/ViewerView.swift
# Commit only on user request:
# git commit -m "feat(viewer): browser-style zoom (pinch + Cmd+/−/0) for viewer panes"
```

---

## Self-Review

**Spec coverage:**
- Trackpad pinch, all content → Task 2 Step 1 (`allowsMagnification`), verified 2-Step 6 (1–3). ✓
- Cmd+/−/0, all content → Task 1 (classifier/stepping) + Task 2 Steps 2–3, verified 2-Step 6 (1–3). ✓
- Public `pageZoom` over private/CSS → Task 2 Step 2 (`webView.pageZoom`). ✓
- No terminal conflict / no stealing from terminals / unfocused viewer inert → Task 2 Step 3 focus guard, verified 2-Step 6 (4–5). ✓
- Reset-on-restore persistence (chosen) → no manifest changes; `zoomFactor` documented in-session only (Task 2 Step 2). ✓
- Out of scope (palette entries, cross-restore persistence, remapped bindings) → not implemented; documented in spec. ✓
- Ghoztty naming → no new user-facing strings introduced. ✓
- Debug-build-only verification → Task 2 Steps 5–6. ✓

**Placeholder scan:** none — every code step shows full code; commands have expected output.

**Type consistency:** `ZoomAction` (`.zoomIn`/`.zoomOut`/`.reset`), `zoomAction(for:)`, `steppedZoom(from:action:)`, `minZoom`/`maxZoom`/`zoomStep`, `zoomFactor`, `pushZoomToWebView()`, `handleZoom(_:)`, `isViewerContentFocused` — names match between Task 1 (definitions) and Task 2 (uses).
