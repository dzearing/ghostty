# Viewer Panes (markdown / text / website)

Approved plan (2026-07-17). A pane whose content is a rendered view of a markdown
file, a plain text/code file, or a website, instead of a terminal. Pane-based:
viewer content lives in a split-tree leaf; a viewer "window" is just a one-pane
tree. View-only, no editing. Task state: `viewer-panes-tasks.json` (same
protocol as the session-persistence effort).

## Decisions (do not re-litigate)

- **Pane-based**, not a standalone preview window type.
- **Engine: WKWebView + fully bundled offline assets** (markdown-it + task-lists
  plugin, highlight.js common-languages bundle, github-markdown-css). Zero
  network for the markdown/text path. Vendored in `src/viewer/vendor/`.
- One viewer type covers markdown file / text-code file / http(s) URL.
- Live reload for files in v1 (DispatchSource vnode watcher, preserve scroll).
- CLI: extend `+new-window` and `+split` with `--view=<path-or-url>` — no new
  command. `--view` is mutually exclusive with `--command`/`-e`.
- Leaf refactor: concrete `PaneView` wrapper class (below), tree becomes
  `SplitTree<PaneView>`. Approved over protocol/existential leaf.

## 1. Leaf refactor: `PaneView`

`SplitTree<ViewType: NSView & Codable & Identifiable>` (SplitTree.swift:5) is
already leaf-agnostic — identity via `===`/`ObjectIdentifier`, bounds via
`view.bounds`, id via `view.id`. Its serializer decodes the leaf as ONE concrete
type (`decode(ViewType.self)` SplitTree.swift:1154, encode :1173), which rules
out existential leaves. Therefore:

- `final class PaneView: NSView, Codable, Identifiable, ObservableObject` with
  `content: Content` where `enum Content { case terminal(Ghostty.SurfaceView);
  case viewer(ViewerView) }`. Content view is a subview pinned edge-to-edge so
  geometry/spatial nav keep working (PaneView IS the leaf view in the hierarchy).
- PaneView exposes the surface-shaped members call sites use so most of the
  ~50 hardcoded `SplitTree<Ghostty.SurfaceView>` sites are a mechanical rename:
  `surface` (nil for viewer), `needsConfirmQuit` (false for viewer),
  `@Published title` / `bell` / `activityState` (viewer: filename-or-page-title /
  constant false / .idle), `processExited`, `pwd`, `isFirstResponder` forwarding,
  `focusDidChange`, `flagsChanged` (viewer: no-op).
- PaneView.Codable: discriminator + payload. Terminal payload delegates to
  SurfaceView's existing Codable (pwd/uuid/title/isUserSetTitle,
  SurfaceView_AppKit.swift:2075-2117). Viewer payload = kind + path/URL + title.
  Viewer decode must NOT throw on missing file (render in-page error instead) so
  the all-or-nothing AppKit restore path (TerminalRestorable.swift:149-152)
  can't lose whole windows.

### Assumption-site map (from the 2026-07-17 sweep; compiler will force these)

- Tree declarations/rename (~50 sites, property always `surfaceTree`):
  BaseTerminalController.swift:44 (source of truth), TerminalView.swift:31,
  TerminalSplitTreeView.swift:12/29/54, TerminalRestorable*.swift,
  QuickTerminal*, TerminalController.swift (many), IPCServer.swift:1281-1639,
  SessionLayoutManifest.swift:312/337, SessionLayoutRestore.swift:321,
  ScriptTerminal.swift:214, NewTerminalIntent.swift:156, HeroModeView.swift:5.
- Surface-API leaf iteration: syncFocusToSurfaceTree BaseTerminalController:727,
  flagsChanged :1345, title/bell subscribe :1364, bell/activity aggregation
  :2977/:2995 (via `surfaceValuesPublisher` keypaths — PaneView needs the
  @Published properties), color-scheme sync :2962, needsConfirmQuit checks
  (TerminalController:1148,1497,1528,1555,1585; BaseTerminalController:1773),
  QuickTerminalController:301 processExited, equalize via leftmostLeaf().surface
  (TerminalSplitTreeView:85, InspectorView:36), drag/drop Transferable
  (TerminalSplitTreeView:104-196), focusedSurface typed SurfaceView?
  (BaseTerminalController:39; root-leaf assign TerminalController:1283).
- SwiftUI render switch point: TerminalSplitTreeView.swift:60-61 `.leaf` →
  TerminalSplitLeaf → InspectableSurface. Branch here on content: terminal →
  existing path (keep `.focusedValue(\.ghosttySurfaceView, ...)` behavior),
  viewer → ViewerRepresentable.
- Pane-nav: notifications originate from libghostty surfaces
  (ghosttyDidFocusSplit BaseTerminalController:1102). Viewer can be a nav
  TARGET (focusTarget returns it; makeFirstResponder works on WKWebView);
  viewer-as-SOURCE needs local keyboard equivalents — v1: rely on
  window-level shortcuts (they route via focused surface today; acceptable gap:
  when a viewer is focused, goto_split keybinds may not fire — document).

## 2. Viewer engine

- Assets: `src/viewer/` (template `viewer.html`, `viewer.css`, `viewer.js`
  authored in T03) + `src/viewer/vendor/` (already checked in: markdown-it
  14.3.0 min, markdown-it-task-lists 2.1.1 min, highlight.js 11.11.1 CDN
  common-languages bundle + github/github-dark styles, github-markdown-css
  5.9.0 auto light/dark variant, licenses).
- Install: new `addInstallDirectory` block in `src/build/GhosttyResources.zig`
  (mirror shell-integration block ~:118-126) → `share/ghostty/viewer`. The
  existing `ghostty` folder reference (project.pbxproj:74, Resources phase :579)
  copies the whole share/ghostty tree → lands at
  `Contents/Resources/ghostty/viewer` with ZERO pbxproj edits. Runtime:
  `Bundle.main.resourceURL/ghostty/viewer`.
- `ViewerView: NSView` hosts WKWebView. No existing WebKit usage in the app
  (greenfield). App is NOT sandboxed; no entitlement changes needed.
- Local content served via `WKURLSchemeHandler` (scheme `ghoztty-viewer`):
  `/page` = generated HTML from template, `/vendor/*` = bundled assets,
  `/local/*` = files under the markdown file's directory (relative images).
  This is the public-API way to mix local file access + offline assets.
  Websites: plain `load(URLRequest)`; network allowed only for that mode.
- Markdown: markdown-it with `html:false, linkify:true, typographer:true` +
  tables/strikethrough + task-lists plugin; fenced code via highlight.js.
  Text/code files: same page, content in `<pre><code class="language-<ext>">`.
- Dark/light: page uses `prefers-color-scheme` (github-markdown.css auto
  variant + both hljs styles behind media queries). WKWebView derives it from
  effectiveAppearance → follows system AND config `theme` (AppDelegate
  syncAppearance sets NSApplication.appearance) with live switching for free.
- Links (WKNavigationDelegate decidePolicyFor): http(s) → NSWorkspace.open;
  relative/absolute `.md` file link → open new viewer pane (split right of
  current, v1) — careful to allow the scheme handler's own loads through.
- Live reload: DispatchSource.makeFileSystemObjectSource on the file fd
  (.write|.delete|.rename|.extend); atomic-save editors rename → re-open fd and
  re-arm; 100ms debounce; JS `window.__update(md)` re-renders and restores
  scrollY.

## 3. CLI / IPC

Zig side is nearly free: `+split` and `+new-window` forward ALL unrecognized
args verbatim (parseManuallyHook split.zig:23-44, new_window.zig:31-54); the
IPC structs carry `arguments: [][:0]u8` unchanged.

- Zig changes: help-text blocks (split.zig:83-136, new_window.zig:118-214) +
  resolve a relative `--view` path against `--working-directory` (if given)
  else caller cwd BEFORE forwarding (the app can't know caller cwd). Values
  with `://` are URLs, pass through; bare paths become absolute.
- Swift `IPCServer.swift`:
  - ParsedArguments (+`view: String?`), parseArguments `--view=` case
    (:1649-1776).
  - handleNewWindow (:354-507) + handleSplit (:509-725): if view set —
    validate mutual exclusion with command/-e (clean IPCResponse error, copy
    --percent pattern :392-395), then create viewer pane instead of terminal.
    Idempotency unchanged (named target → focus).
  - TargetEntry (:22-46): `.pane` becomes PaneView-based (WeakRef<PaneView>);
    registry code mostly renames.
  - handleClose (:727-759): route through node removal; viewers never confirm.
  - handleRead (:1056-1122) / handleSendKeys (:1124-1175): if target is a
    viewer → `success:false, error:"target '<x>' is a viewer pane, not a
    terminal"` (exit 1 at CLI).
  - set-banner/set-state on viewer: same clean error (v1 unsupported).
  - handleList/buildSplitNodeData (:1406-1576): viewer leaves auto-registered
    like terminals (name fallback = pane uuid); human tree prefix `view:`;
    IPCMessage.swift TerminalData gains `type: "terminal"|"viewer"` +
    `url` (SplitNodeData leaf reuses it).

## 4. Persistence

Two systems (mutually exclusive per window):

- **Manifest path (`session-persistence = on`)** — SessionLayoutManifest.Leaf
  (:49-61) gains `kind: "terminal"|"viewer"` + `viewerLocation: String?`.
  Viewer leaves: never routed to the agent (guard at TerminalController.swift:
  92-112), excluded from probeSessions (SessionLayoutRestore.swift:96-117) and
  hasMissingSessionIDs capture loop (SessionLayoutManifest.swift:273-282),
  counted ALWAYS-RESTORABLE in the drop policy (:150-174) so a mixed tree can
  never be dropped as all-dead. Restore branch in makeSessionLayoutRoot
  (:316-334): viewer → reconstruct ViewerView from location. Viewer leaves
  never appear in the agent's sessions.json (correct: no PTY).
- **AppKit restoration (non-persistent windows)** — rides PaneView.Codable.
  Viewer decode is infallible (missing file → in-page error), so mixed trees
  restore whole; no per-leaf resilience work needed.

## 5. In-app open

- Ghostty-Info.plist CFBundleDocumentTypes: add markdown
  (`net.daringfireball.markdown`, md/markdown/mdown/mkd) + keep existing types.
- AppDelegate.application(_:openFile:) (AppDelegate.swift:601-670): branch on
  markdown extensions → viewer window via TerminalController.newWindow-style
  path with a one-viewer tree, instead of the execute-in-terminal behavior.
  (Deliberately narrow: only .md-family reroutes; .sh etc. keep today's
  behavior. Generic text files open via CLI `--view`, not File→Open, in v1.)
- Clickable .md paths in terminal output: DEFERRED (follow-up).

## 6. Environment / build

- Toolchain (macOS 26.4 box): `export PATH=/opt/homebrew/opt/zig@0.15/bin:
  /opt/homebrew/opt/gettext/bin:$PATH; export DEVELOPER_DIR=
  /Applications/Xcode.app/Contents/Developer` then
  `zig build -Doptimize=Debug` → `zig-out/Ghoztty-Debug.app`.
- NEVER touch /Applications/Ghoztty.app. Debug bundle/socket only.
- Bundle ids stay `com.dzearing.ghoztty.*`.
- After a build with user-facing change: kill + relaunch the debug app before
  testing (stale-instance trap; check process start time > binary mtime).

## 7. Shipped — E2E results (2026-07-17)

All verified live in the debug app (`zig-out/Ghoztty-Debug.app`) via CLI,
with screenshots captured during T02–T12:

- **Markdown torture test** (headings, GFM aligned tables, nested + task
  lists, zig/swift/plain fences with hljs highlighting, nested blockquotes,
  relative images via the scheme handler, hr, inline styles, typographer):
  renders GitHub-style in-pane; both palettes verified (dark in-app, light
  in the Chrome harness — the window appearance is pinned by the user's
  dark terminal theme, which is the intended semantics).
- **Website pane**: example.com loads, page title flows into pane title and
  `+list` ("Example Domain").
- **Mixed window**: terminal 45% | torture.md | example.com (35% down-split
  off the viewer). `--percent` honored; splits anchored ON viewer panes work
  (both viewer→viewer and viewer→terminal); zoom toggle with viewer siblings
  works; equalize anchors on the first terminal leaf.
- **Links**: real-click verified — external → default browser (pane
  untouched), relative `.md` → new viewer split, template/asset loads
  unaffected.
- **Live reload**: append → atomic rename (`os.replace`) → append → rewrite
  all re-rendered within the 100ms debounce; watcher survives inode swaps.
- **`+list`**: `view: <title> <url> [name: …]` human lines; `--json` leaves
  carry `"type": "viewer"` + `"url"`; auto-registration works.
- **Clean errors**: `+read`/`+send-keys`/`+set-state`/`+set-banner` on a
  viewer → `… is a viewer pane, not a terminal`, exit 1. `+close` silent.
- **Persistence (manifest)**: terminal+viewer split survived two
  quit/relaunch cycles — terminal re-ATTACHed (scrollback marker intact),
  viewer re-opened, ratios + IPC names preserved.
- **Persistence (AppKit)**: viewer-only windows round-trip through
  NSSecureCoding (verified with per-app NSQuitAlwaysKeepsWindows=YES since
  macOS defaults suppress AppKit restore on quit); a file deleted between
  quit and relaunch restores as the in-page "Cannot read file" card.
- **File → Open**: `open -a Ghoztty-Debug x.md` opens a viewer window;
  scripts/dirs keep terminal behavior.

## 8. Table of contents + native typography (2026-07-21)

Markdown viewers gained a heading navigator, and the document type moved onto
the system font stack.

**Split of responsibility — page is the data source, native draws the card.**
The first implementation was entirely in-page (HTML/CSS/JS). It worked, but
placed beside a real pane banner the two cards were visibly different, and CSS
cannot close the gap: `border-radius` is a circular-arc rect where SwiftUI
uses a `.continuous` squircle, and WebKit rasterizes SF differently from
AppKit. So the chrome is native and the page feeds it:

- `viewer.js` assigns heading anchor ids (AFTER DOMPurify, on the live nodes,
  so sanitization can never strip them), posts `{type:"headings", items}` on
  every render and `{type:"active", id}` on scroll-spy changes over the
  `viewerTOC` script-message bridge, and exposes `scrollToAnchor(id)` /
  `setGutter(px)`. It degrades to a no-op when the bridge is absent, so the
  page still renders standalone in a browser.
- The message-handler proxy holds the viewer **weakly**: the content
  controller retains its handlers and the web view retains the controller, so
  registering `ViewerView` directly would leak the whole pane.
- `ViewerTOCPanel` (SwiftUI) draws the card via the shared
  `GlassCardBackground`, extracted from `SurfacePaneBanner` into
  `Helpers/GlassCard.swift`. The banner uses the same type — the two surfaces
  are identical by construction, not by matched constants.

**The gutter is page padding, not a web-view inset.** Insetting the web view
natively is the obvious approach and is wrong: the reserved strip then paints
`ViewerView`'s background while the document beside it paints the markdown
page's, leaving a visible seam in both themes. Instead the web view always
spans the pane, the card floats over it, and the page reserves
`body { padding-left }`. Re-pushed on `didFinish` — a reload resets the
document and takes the padding with it.

**Compact layout.** Below 720pt the chrome bar pins open (single choke point
in `setChromeVisible`, so hover-out, the hide timer, and field blur all
respect it) and carries the contents toggle as its first button. The card is
an overlay, opaque over the document.

**The slide is a Core Animation transform**, on a layer-backed container
wrapping the hosting view. The first attempt animated the panel's leading
*constraint*, which re-runs Auto Layout every frame and re-lays-out the
SwiftUI list inside it — CPU work per frame, and visibly chunky. A layer
transform + opacity costs no layout at all. Consequences: the panel is parked
off-edge rather than unmounted (a destroyed view cannot animate), and it must
be `isHidden` while parked because AppKit hit-tests by frame, not by layer
transform.

**Typography.** `viewer.css` redefines the vendored stylesheet's own
`--fontStack-sansSerif` / `--fontStack-monospace` custom properties rather
than editing `vendor/github-markdown.css`, plus retuned size/leading/heading
tracking — SF has a larger x-height and looser tracking, so GitHub's 16px/1.5
metrics read oversized dropped straight in.

Tests: `macos/Tests/Ghostty/ViewerTOCTests.swift` drives a real WKWebView end
to end (headings over the bridge, gutter value *and* the page's computed
padding, narrow collapse + re-widen, single-heading/code cases, detach).

Known gaps (accepted): the TOC is markdown-only (a code viewer has no heading
structure); panel open state is deliberately ephemeral across restore.

Known v1 gaps (accepted): goto_split keybinds don't originate FROM a
focused viewer pane (nav INTO viewers works); hero mode skips viewers;
activity state/banners unsupported on viewers (clean error); web page
titles don't retitle viewer-only windows (pinned at open); backgrounded
apps blank their WKWebViews to volatile layers until reactivated (WebKit
suspension — cosmetic, not a hang).
