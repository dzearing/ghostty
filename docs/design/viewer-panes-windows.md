# Windows viewer panes -- refreshed design (T127)

Status: design, 2026-07-29. Supersedes the pins in `T90a.md` where the two
disagree; everything `T90a.md` pinned that is NOT contradicted here still
stands and is not re-litigated.

Mac's viewer design (`docs/design/viewer-panes.md`) is approved and shipped.
This document is the PORT plan, refreshed against the Mac viewer as it exists
today rather than as it existed on 2026-07-19.

## Why this refresh exists

`T90a` was written 2026-07-19 against the first 8 Mac viewer commits and split
T90 into T90b--T90h. Main has since landed 27 viewer commits (inventory in
`T127.md`). None of the added capabilities -- address bar, table of contents,
zoom, popups, quoting, feedback capture, pane-scoped chords, `+reload` -- exist
in that split. T127's instruction is explicit: do not silently widen T90b--T90h
to absorb them. So this refresh does three things:

1. Enumerates the Mac viewer's CURRENT surface from source, not from commit
   subjects (commit messages describe intent; the code is what has to be
   ported).
2. Decides, per capability, what Windows v1 ships and what it defers -- with
   the reason on the record.
3. Re-scopes T90b--T90h and files the additions and the deferrals as their own
   tasks, so no scope hides inside an existing row.

Method note: the inventory below was read out of
`macos/Sources/Features/Viewer/*.swift` (8 files, ~232 KB) and
`src/viewer/*.js`. Every "Mac site" reference is a file and symbol that exists
at HEAD.

## Feature inventory and the v1 line

`shared` = the shared Zig/JS already on this branch, so the cost is host
wiring, not a reimplementation.

| # | Capability | Mac site | Windows cost | v1? |
|---|---|---|---|---|
| 1 | Web/markdown/code modes, offline render | `ViewerView.mode(for:)`, `viewer.js` | WebView2 host + shared JS | yes |
| 2 | Native error card (no runtime, missing file) | `ViewerView.setError` path | owner-painted child window | yes |
| 3 | 3-tier resource resolver | `ViewerSchemeHandler` | `WebResourceRequested` | yes |
| 4 | Live reload, atomic-save safe | `startWatchingFile`, `scheduleReload` | `ReadDirectoryChangesW` | yes |
| 5 | Link routing (browser / .md split / default app) | `handleFileModeLink`, `openViewerSplit` | `NavigationStarting` + `ShellExecute` | yes |
| 6 | IPC/CLI contract (`--view`, verb rejections, `+list`) | shared Zig | server side only | yes |
| 7 | Nav chrome: hover strip, back/fwd/reload/home | `setChromeVisible`, `goBack/goForward/reloadPage/goHome` | native child window | yes |
| 8 | Editable address field + omnibox completion + `file://` display | `navigate(to:)`, `completeAddress`, `addressText(for:)` | native EDIT + pure-Zig completion | yes |
| 9 | Markdown TOC card, scroll spy, gutter/overlay, resize | `ViewerTOC.swift`, `viewer.js` spy | native card via `banner_card.zig` | yes |
| 10 | Page zoom (keyboard) + pinch | `handleZoom`, `allowsMagnification` | `put_ZoomFactor`; pinch is Chromium's | yes |
| 11 | Pane-scoped chords (Cmd+R / Cmd+D) | `PaneChord`, `handle(_:)` | keybind override while viewer focused | yes |
| 12 | `+reload` verb | `reloadContent` | server verb + CDP reload | yes |
| 13 | Blank browser pane (`about:blank`) + palette entry | `ViewerCommands.openBrowserFromPalette` | palette + address focus | yes |
| 14 | Dark mode follows window | `underPageBackgroundColor`, profile scheme | `ICoreWebView2_13` profile | yes |
| 15 | Titles, hero PARTICIPATION, dim walk, split-from-viewer cwd | `ViewerSplitLeaf.swift`, `title`, `HeroCarouselView.takeSnapshot` | Zig walks; `CapturePreview` → GDI+ (T397) | yes |
| 16 | Session-persistence restore (location, home, origin) | `Codable` on `ViewerView` | manifest fields | yes |
| 17 | Selection toolbar: Copy | `selection.js` (shared) | injection + shim (see P1/P2) | yes, Copy only |
| 18 | Selection toolbar: Quote | `selection.js` + composer | needs the composer | no (#20) |
| 19 | Popups as ghoztty windows, `window.close()` | `WKUIDelegate.createWebViewWith`, `webViewDidClose` | `NewWindowRequested.put_NewWindow` | no |
| 20 | Worktree feedback capture (bar, composer, report) | `ViewerFeedbackBar/Composer/Report/Worktree.swift` (~85 KB) | large; see P10 | no |
| 21 | Detach/undo parking of hosts | `setDetached` | n/a on win32 (P13) | n/a |
| 22 | Raw HTML in markdown, DOMPurify | `viewer.js` + vendor | free with shared assets | yes |
| 23 | Media pause when parked, persistent data store | `pauseAllMediaPlayback` | shared UDF already pinned | partial |
| 24 | `.md` file association / File>Open | Mac app plumbing | installer work | no (already out of scope) |

v1 is therefore "a viewer pane you can actually live in": every mode, the
navigation chrome the user named, the TOC, zoom, reload, restore. The three
cuts are #19 (popups), #20 (feedback capture), #24 (file association).

Why cut #20 and not something else: it is ~85 KB of Swift across four files
whose hard parts are all platform-specific rather than portable -- an
`NSTextAttachment` chip model for `[Image #N]`, `screencapture -i -o` for
interactive capture, and `lsof` for port -> pid -> cwd provenance. Windows has
no port->cwd path at all (`GetExtendedTcpTable` gives the pid; a process's cwd
is not readable from another process without injection or WMI heuristics), so
strategy D's middle leg needs its own design decision, not a port. Shipping
viewer panes without it loses no viewer capability; shipping it inside T90g
would hide a multi-day task inside a chrome row. It becomes its own
design-first task.

Why #19 is a cut and not a bug: `NewWindowRequested -> Handled=TRUE +
ShellExecute` (already pinned in T90a) is correct, useful behavior -- a popup
opens in the user's browser. Adopting the popup into a ghoztty window is
strictly nicer and strictly optional.

## New pins (the delta decisions)

### P1. The shared viewer JS is WebKit-shaped; shim it, do not fork it

`viewer.js` and `selection.js` both talk to native through
`window.webkit.messageHandlers.viewerTOC.postMessage(obj)`
(`viewer.js:115-127`, `selection.js:132-146`). WebView2's bridge is
`window.chrome.webview.postMessage(obj)` + `add_WebMessageReceived`.

Pinned: inject a ~6-line shim that defines `window.webkit.messageHandlers`
in terms of `chrome.webview`, and change NO shared JS. Forking the JS is
rejected outright -- it is the one part of the viewer that came free with T117
and it must stay a single copy, or every future Mac viewer commit needs a
Windows translation.

Native receives `WebMessageReceived` and reads `get_WebMessageAsJson`, which
is the same JSON shape the Mac proxy sees, so the message handling code is a
straight port of `handleQuoteMessage` / `setTOCItems` / `reportActiveHeading`
handling.

### P2. Inject shim + `selection.js` as ONE blob into EVERY page

Mac's lesson is recorded in a comment at `ViewerView.swift:429-439`: the
selection toolbar cannot live inside `viewer.js`, because that is a
`<script src>` in `viewer.html` and therefore only ever runs on the bundled
template -- which is why quoting worked on markdown and did nothing on a
website. It ships as a `WKUserScript` injected into every page.

Windows equivalent: `AddScriptToExecuteOnDocumentCreated`, with the shim and
`selection.js` concatenated into a single injected source so their relative
order is not a question. Same rule as Mac: main frame only in spirit (the
toolbar positions itself in viewport coordinates); WebView2 injects into all
frames, so the script must no-op when `window.top !== window`.

Its UI lives in a shadow root already (`selection.js`), which is what keeps
arbitrary page CSS from restyling it. That carries over free.

### P3. Navigation chrome is a native child window, not web content

The bar is a hover-revealed strip with back / forward / reload / home, an
editable address field, and (deferred, #20) a feedback button. Mac hosts
SwiftUI in an `NSHostingView`.

Pinned for win32: an owner-painted child window with a real `EDIT` control for
the address field. Precedents on the box are `RenameDialog.zig`,
`BannerDialog.zig`, and `MachineChooser.zig` -- native controls with the
house's dark-mode and DPI handling. Rejected: rendering the chrome inside the
WebView2 as page content. It would have to be injected into arbitrary
third-party pages, it would fight their CSS and z-index, and it would put the
address field inside the very content it navigates.

Always on screen, in every mode, from the pane's first layout (T1185, Mac
`fc7e36356`). There is no reveal geometry and no hide timer: the bar is part of
the pane's frame and reserves its band, so nothing reflows under the pointer.

### P4. `isFilePath` must be Windows-shaped

Mac's `isFilePath` (`ViewerView.swift:562`) accepts `file://`, `/`, `~/`. On
Windows that must also accept `C:\`, `C:/`, `\\server\share`, and `~\`, or
typing a real path into the address bar treats it as a hostname.

This is the same defect class as the still-live CLI bug: `resolveViewArgument`
(`src/cli/split.zig:212`, `src/cli/new_window.zig`) returns early on
`rest[0] == '/'` only, so a `C:\...` relative-resolution decision is made on a
POSIX-only test. Both get `std.fs.path.isAbsolute` and a unit test in the
none-runtime lane. The address-bar classifier lives in the same pure module so
it is testable without a window.

### P5. The TOC card is `banner_card.zig`, already ported

**Done 2026-08-06 (T160).** Landed as `src/apprt/win32/viewer_toc_layout.zig`
(pure geometry/policy, four-scale asserts incl. the `documentAlignsToTheCard`
analog), `viewer_prefs.zig` (the persisted shared card width) and
`ViewerTOCPanel.zig` (the native window: `banner_card` glass over the
document background, macOS-style selection pill in the system accent, wheel
scrolling with an overflow thumb, the drag-resize handle, and a rounded
window region in the compact overlay). The nav bar grew its leading contents
button (`viewer_nav_layout` `with_contents`) and pins open while compact.
Deferred polish — the compact slide animation and the translucent pinned
header — is T543.

Mac's TOC panel and the pane banner share one `GlassCardBackground`
(`ViewerTOC.swift`, and CLAUDE.md's "Margins are one number" rule:
`GlassCard.outerMargin` = 12pt on all four sides, enforced by
`documentAlignsToTheCard`). T131 already ported that card to win32 as
`src/apprt/win32/banner_card.zig` for the banner overlay, so the TOC card
reuses it rather than growing a second card renderer. The 12pt margin rule
ports with it and gets the same test.

The parts that are genuinely new on Windows:

- scroll-spy plumbing: `viewer.js` already computes and posts the active
  heading; the host consumes it over P1's bridge and repaints the card.
- wide (gutter) vs narrow (overlay) layout switching on PANE width at 720pt,
  live as a divider is dragged (`desiredTOCLayout`, `updateTOCLayout`).
- the drag-to-resize handle and its shared width preference
  (`setTOCCardWidth`, `pushTOCGutter` -> `__viewer.setGutter`). Width persists
  in the same place win32 keeps window/pane preferences (`window_memory.zig`
  neighborhood), not in the session manifest -- it is a preference, not layout.
- panel open/closed state is deliberately NOT restored (Mac parity: restoring
  an overlay would hide the content it covers).

### P6. Zoom

`ICoreWebView2Controller::put_ZoomFactor` for keyboard zoom; pinch/ctrl+wheel
is Chromium's own and needs no code. Mac's steps and clamp
(`handleZoom`, `ZoomAction`) are copied exactly so the two clients zoom
identically.

### P7. Pane-scoped chords, mapped to Windows

Mac overrides two GLOBAL bindings while a viewer holds focus: Cmd+R (globally
"Set Pane Banner...") becomes reload, and Cmd+D (globally split-right) becomes
focus-address-bar. The override structure ports as-is; the chords do not,
because the Windows defaults differ (`src/config/Config.zig`: ctrl+d =
split right, ctrl+shift+d = split down, ctrl+shift+b = banner editor).

Pinned Windows mapping while a VIEWER pane holds focus:

| Chord | In a viewer | Globally (unchanged) |
|---|---|---|
| ctrl+r | reload the pane | belongs to the shell |
| ctrl+d | focus the address bar | split right |
| ctrl+l, alt+d | focus the address bar | clear-screen / n/a |
| ctrl+plus/minus/0 | page zoom | font size |

`ctrl+r` is free precisely because a viewer pane has no shell -- the reason
the banner editor had to take ctrl+shift+b does not apply here, and every
browser on Windows already means "reload" by it. `ctrl+l` and `alt+d` are
added as Windows-native aliases: `ctrl+d`-for-address-bar is Mac muscle
memory, and a Windows user reaches for `ctrl+l`. Terminal panes keep every
global meaning, which is the invariant the Mac side states and tests.

Mechanism: `add_AcceleratorKeyPressed` on the controller (T90a section 11)
already sees Ctrl/Alt/F-key combos before the page. It checks the pane-scoped
table first, then the app keybind table, then lets the page have it.

### P8. `+reload` semantics

The client verb already exists in the shared CLI (`src/cli/ghostty.zig`); the
win32 server does not implement it. Port `reloadContent`
(`ViewerView.swift:517`) exactly:

- web mode: re-fetch from ORIGIN, bypassing caches. WebView2's `Reload()` is
  a normal reload, so use
  `CallDevToolsProtocolMethod("Page.reload", {"ignoreCache":true})` and fall
  back to `Reload()` if the call fails. (Recording this because "reload"
  looking identical while silently serving cache is exactly the kind of
  half-parity that gets reported as a bug months later.)
- file mode: re-arm the watcher, then re-render preserving scroll.
- either mode with no completed load yet: full load.
- terminal target: `target '<name>' is a terminal pane, nothing to reload`,
  exit 1 (exact Mac string).

### P9. Popups (deferred, but do not paint into a corner)

v1 keeps `NewWindowRequested -> Handled=TRUE -> ShellExecute`. The deferred
task adopts the popup instead, via `put_NewWindow` with a controller hosted in
a new ghoztty window, plus `WindowCloseRequested` for `window.close()`. The
only thing v1 must not do is consume the event in a way that discards the
deferral (`get_Deferral` usage stays available).

### P10. Feedback capture (deferred, design-first)

**Split 2026-08-08 into T633 (provenance + nav-bar button), T634 (composer
chrome), T635 (text model + quote insertion), T636 (report writer), T637
(images + screenshot) and T638 (the localhost provenance leg).** T636 is where
a win32 viewer pane can file a report end to end. The two decisions below that
are genuine forks are filed as D43 (composer text control) and D44 (screenshot
primitive); the third is T638 itself. T164 and T384 were the same umbrella
filed twice and are both closed.

Deferred as its own task because it needs decisions, not translation:

- port -> cwd provenance has no Windows analog for `lsof`. Options to weigh:
  `GetExtendedTcpTable` for pid then a cwd strategy (NtQueryInformationProcess
  PEB read, WMI, or asking the pane's own shell), or narrowing v1 provenance to
  the file/origin legs and skipping the localhost leg.
- the `[Image #N]` chip model is `NSTextAttachment`-shaped. A win32 `EDIT`
  cannot carry attachments; RichEdit or an owner-drawn composer is a real
  choice.
- interactive screenshot: `screencapture -i -o` maps to a snip flow
  (`ms-screenclip:` / `SnippingTool /clip`) whose "never touch the clipboard"
  guarantee needs checking -- Mac's comment says the clipboard must not be
  clobbered, and the obvious Windows snip does exactly that.
  `ICoreWebView2::CapturePreview` covers "screenshot of THIS pane" without any
  of that, and may be the better v1 primitive.

The report format itself (`report.json`, staging + atomic rename, quote
context) is portable as-is and is the cheap half. Quote (#18) rides along,
since the Quote button needs somewhere to put text; v1's toolbar shows Copy
only rather than a dead button.

### P11. Blank browser pane is v1

`--view=about:blank` plus the palette entry "Viewer: Open Browser Pane" with
the caret already in the address field. Cheap once P3 exists, and it is the
interactive entry point a user reaches for when the URL is not known up front.
Mac's blank pane also seeds `originDirectory` from the pane it split from
(`ViewerCommands.swift:35-38`) -- keep that, it is what makes provenance work
later.

### P12. Manifest fields

T90a section 16 reserved `kind` and `viewer_location`. The current Mac viewer
persists more: the HOME location (where the pane was opened, distinct from
where it has navigated to) and the ORIGIN directory (`viewerOriginDirectory`,
the provenance fallback). Reserve four additive fields:
`kind`, `viewer_location`, `viewer_home_location`, `viewer_origin_directory`.
Absent `kind` means terminal, so old manifests keep loading.

### P13. No detach/undo parking on win32

Mac's `setDetached` exists because a closed pane can sit in an undo stack, so
it tears down hosting views and pauses media. Win32 has no close-undo (`undo`
/ `redo` are listed as macOS-only at `App.zig:2257`), so `ViewerPane` needs no
park/unpark path in v1. If a close-undo ever lands on Windows, it must
re-mount the host and pause media, and this pin is the reminder.

## Re-scoped T90b--T90h

Unchanged in intent; stated here so the boundaries are explicit.

- **T90b** IPC/CLI floor. Unchanged, plus P4's `isAbsolute` fix now cites the
  live line, and the interim `--view` error is confirmed still missing (today
  `--view` is silently dropped as an unknown flag on win32; `VerbArgs` has no
  `view` field).
- **T90c** PaneView retype. Unchanged. `SplitTree(Surface)` is already generic
  (`Window.zig:117`), so the retype is mechanical.
- **T90d** WebView2 host floor, web mode. Unchanged, plus the P1 bridge and
  the P2 injection blob land here (the TOC and quoting both need them, and
  they are host plumbing). SPLIT into T372 (COM floor + probe + env), T373
  (host window + controller + error card), T374 (`--view` E2E + verb
  rejections) and **T375** (P1 shim + P2 blob), all done as of 2026-08-02.
  P1/P2 live in `src/apprt/win32/viewer_bridge.zig`; the shared JS is embedded
  verbatim and a test asserts it byte-for-byte.
- **T90e** File viewers. **Done 2026-08-02.** Mode by extension, the
  `WebResourceRequested` 3-tier resolver with a **lexical** escape guard (the
  one deliberate divergence from `ViewerSchemeHandler`, and the reason the
  guard is unit-testable at all), `window.__viewer` injection from
  `NavigationCompleted`, and the in-page error card. Pure half:
  `src/apprt/win32/viewer_content.zig`. The interim
  `view_file_unsupported_error` is deleted. TOC is still NOT here (T160), and
  neither is live reload (T90f).
- **T90f** Live reload + link routing. SPLIT into **T390** (the `+reload` verb,
  P8), **T391** (the `ReadDirectoryChangesW` watcher + debounce) and **T392**
  (the `NavigationStarting` link policy). T390 is done as of 2026-08-02 and is
  first because the other two go through its `ViewerPane.reloadContent`: the
  watcher's re-render IS a file-mode reload. The three-way branch is pure
  (`viewer_content.reloadPlan`), the two new vtable slots are `Reload` (31) and
  `CallDevToolsProtocolMethod` (36), and the cache bypass is proven live rather
  than assumed -- see `docs/design/windows-parity-tasks/T390.md`.
  **T391 is done as of 2026-08-02** (`src/apprt/win32/viewer_watcher.zig`). The
  translation worth knowing: Windows watches the **directory**, not the file, so
  the atomic-save re-arm Mac needs (`reloadNeedsRearm`) has no counterpart here
  -- a rename over the target arrives as an ordinary notification for the same
  basename. Debounce is a `WM_TIMER` on the pane's host window, since `SetTimer`
  on an existing id resets it, which is Mac's cancel-and-reschedule exactly.
  **T392 is done as of 2026-08-06**: `add_NavigationStarting` (slot 7) cancels
  and routes file-mode links -- http(s) to the default browser, an existing
  relative `.md` to a viewer split on the pane's right, any other file to its
  default app -- with the whole policy pure in `viewer_content.zig`
  (`classifyLink`/`routesAsLink`/`navCandidate`/`fileLinkAction`). Three
  translations worth knowing: (1) relative links arrive under the `https://`
  virtual host rather than Mac's custom scheme, so the ours-check must run
  before the generic http(s) one or every relative link ships to the browser
  as a dead URL; (2) the FILE-mode gate keys on `NavigationKind == NEW_DOCUMENT`
  (Args3, QI'd with a graceful null on old runtimes) and not on
  `IsUserInitiated` -- in file mode the bundled template runs no navigating
  script of its own, so a new document IS a link activation, while reloads and
  history walks are exactly the two kinds excluded (see T825 below for what
  `IsUserInitiated` actually means, which is not what this originally assumed);
  (3) the pane reaches the split machinery through a
  trampoline `Window.createViewerPane` installs (`open_link_split`), because a
  direct `newViewerSplitAt` reference pulls the surface/renderer world -- and
  with it the GTK apprt branch -- into the win32 test binary's comptime
  analysis.
  **T825 extends that policy to LIVE pages as of 2026-08-17** (main 18acc4f6f):
  a click that leads out of a live page's own site is cancelled and handed to
  the default browser, because this web view's cookie store is nobody else's --
  the page would render logged-out in the pane with no way back. "Site" is host
  plus the port AS WRITTEN (so `http`->`https` on one host stays, and
  `:3000`->`:5173` does not), which is `isExternalLivePageLink` in
  `viewer_content.zig`; `classifyLink` now takes the page being LEFT (the web
  view's `Source`, which still names the committed document when
  `NavigationStarting` fires). Two translations worth knowing: (1) Mac's second
  rule -- `file://` containment inside the page's own directory -- has no
  counterpart, because a rendered `.html` file is served from the synthetic
  `ghoztty-page` host, so the read grant IS a host and a link cannot spell its
  way out from under it; (2) WebView2 has no `.linkActivated`, and
  `IsUserInitiated` means "not initiated by page script" -- it is TRUE for a
  host `Navigate` and for an `ExecuteScript` click, so the first draft cancelled
  the pane loading its own `--view=<url>`. The pane counts the navigations it
  issues (`self_nav_pending`) and subtracts them; what is left is a click. The
  known divergence: a script-synthesized `a.click()` routes on Mac and stays in
  the pane here, which errs toward leaving a page's own machinery working.
  **T826 is 18acc4f6f's other half** (2026-08-17): a right-click on a link in
  any viewer page shows Ghoztty's own menu instead of the browser's. The shared
  `src/viewer/links.js` decides (scheme list, same-document, inside-selection),
  posts `{type:"linkMenu",href}` through the existing `viewerTOC` shim, and the
  native half is `banner_link.zig`'s existing rows/order/ids -- so the viewer and
  the banner cannot drift, which is what Mac bought by re-anchoring
  `BannerLinkOpener` on a `LinkAnchor` protocol. Three win32-specific pieces:
  (1) the menu is TRACKED one message hop later
  (`WM_APP_VIEWER_LINK_MENU`), because `TrackPopupMenuEx` is modal and the
  browser process is blocked for the length of a WebView2 `Invoke`;
  (2) the href is RESOLVED first (`viewer_content.linkMenuTarget`) -- both
  synthetic hosts name files, and copying `https://ghoztty-page/...` would hand
  over something that exists only inside this process;
  (3) it rides the MAIN-FRAME blob, so an iframe link keeps WebView2's menu
  (T928) where Mac injects into subframes -- a subframe's `postMessage` reaches
  `ICoreWebView2Frame`'s event, so a copy there would suppress the page's menu
  with nowhere to send the href.
- **T90g** Chrome & command integration. NARROWED: titles, hero exclusion,
  accelerator forwarding, dim walk, split-from-viewer cwd, palette File/URL
  entries. The nav chrome, address bar, and zoom are NOT here (own tasks). Add
  the blank-browser palette entry (P11).
  **Hero "exclusion" is obsolete (T397, 2026-08-07):** Mac changed its answer
  to "every pane participates: terminals and viewers alike", so win32 does
  too. A viewer's tile picture comes from `ICoreWebView2::CapturePreview`
  (an encoded PNG into an `IStream`) decoded by the GDI+ flat API in
  `gdiplus_decode.zig`, where Mac's `WKWebView.takeSnapshot` hands back a
  bitmap directly — which is why the viewer refresh floor is 2s and the
  terminal's is 150ms (decision D25). The capture works on a leaf whose host
  window is `SW_HIDE`n, because hero mode keeps the controller's `IsVisible`
  true so every leaf keeps producing frames for its thumbnail.
- **T90h** Session-persistence restore + E2E hardening. Unchanged, with P12's
  four fields instead of two.

New v1 tasks (filed by this refresh):

- nav chrome + address bar + history/home (P3, P4)
- markdown TOC card (P5)
- zoom + pane-scoped chords (P6, P7) — **done in T161**: `viewer_accel.zig`
  carries the pure chord/zoom tables (Mac's step ×1.1, clamp [0.5, 3.0],
  verbatim), the accelerator handler checks pane chords before the app
  keybind table, `put_ZoomFactor` is typed on the controller, and the
  main loop routes the chords from the address field too (zoom stays
  content-only, Mac's `isViewerContentFocused` rule). Open question 3 is
  answered: plain `ctrl+l` DOES reach `add_AcceleratorKeyPressed` (asserted
  on-box by `viewer-panes.ps1` 11d).
- selection toolbar Copy + shim/injection verification on a real website (P1,
  P2, #17) — **done in T375**: the win32 lane's live test serves a loopback
  `http://` page whose script posts through `window.webkit.messageHandlers`
  and reports back whether `selection.js` ran from the same blob.

Deferred, filed as rows so the cuts stay visible:

- popups as ghoztty windows (P9)
- worktree feedback capture, design-first (P10, #18)

## Validation

One `test/win32/viewer-panes.ps1` still grows across the band
(`pane-banner.ps1` model), and it launches with
`--session-persistence=false` from the start -- the T131/T155 lesson is that a
script which does not is testing session restore's leftovers, and passes only
on its first run.

Per-task asserts are in the task files. The additions this refresh implies:

- address bar: type a path -> pane renders the file; type a bare host -> it is
  completed to `https://`; back crosses the file/web boundary; home returns to
  the opened location.
- TOC: a 2+ heading document shows the card; scrolling moves the highlight;
  clicking a row pins it; dragging the split narrower than 720pt switches to
  the overlay and back; the card and a neighboring banner agree on the 12pt
  margin.
- chords: ctrl+r reloads with a viewer focused and does NOT with a terminal
  focused; ctrl+d focuses the address field with a viewer focused and splits
  right with a terminal focused. Positive controls mandatory (T157's lesson:
  a keybind script that cannot prove it delivered the chord proves nothing).
- selection: Copy works on the bundled template AND on a real
  `http://localhost` page -- the exact gap the Mac user-script fix closed.

Pure-logic units in the none-runtime lane: mode-by-extension, `isFilePath` /
absolute-path classification, omnibox completion, the 3-tier resolver's escape
guard, TOC layout thresholds, zoom clamp.

## Open questions (not hidden)

1. WebView2 `AddScriptToExecuteOnDocumentCreated` ordering across multiple
   added scripts is documented as add-order, but P2's single blob makes this
   moot. If the blob ever splits, re-check.
2. Whether `CallDevToolsProtocolMethod("Page.reload")` is available on the
   oldest Evergreen runtime we accept. Fallback is already pinned, so this is
   a "does the good path fire" question, not a risk.
3. Whether `add_AcceleratorKeyPressed` sees plain `ctrl+l` (no alt/shift) --
   it fires for Ctrl-combos, but confirm on the box before relying on the
   alias. `ctrl+d` and `ctrl+r` are the load-bearing ones.
4. Focus-follows-mouse into a viewer pane and the T94 divider grab band inside
   a viewer both remain the known v1 gaps from T90a section 12. Unchanged, and
   Chromium's child-window mouse handling is the reason.
