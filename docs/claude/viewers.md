# Viewer panes

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this when working
> on viewer panes (markdown/HTML/text/website rendering, navigation chrome,
> keyboard chords, popups), git diff panes, or the worktree feedback capture
> path (composer, quoting, screenshots, report format).

## Viewer Panes

A pane (or a whole window) can render **content** instead of a terminal: a
markdown file, a local **HTML page**, a plain text/code file, a website, or a
**git diff**. Viewers live in the normal split tree — they resize, focus, zoom,
close, and persist like any pane. View-only, no editing.

```bash
ghoztty +new-window --view=README.md                 # viewer window
ghoztty +split --target=dev --name=doc --view=docs/design.md
ghoztty +split --pane=doc --direction=down --view=https://example.com
ghoztty +split --target=dev --name=diff --view=git-status:   # a git diff
ghoztty +close --target=doc
```

- **Markdown** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdwn`): GitHub-style
  rendering via bundled markdown-it + highlight.js (offline, zero network) —
  headings, GFM tables, nested/task lists, fenced code with syntax
  highlighting, blockquotes, images (relative paths resolve against the
  file's directory), links. Light/dark follows the window appearance. Body
  text is set in the **system font** and code in the system monospace, so a
  viewer reads as native content rather than a web page. One stack serves both
  platforms: `system-ui` leads it (San Francisco on macOS, Segoe UI on
  Windows), with the `-apple-system`/SF spellings and the `"Segoe UI"` /
  `Consolas` entries behind it as insurance for an engine that does not answer
  `system-ui`. A stack that names only the macOS families falls through to the
  GENERIC family on Windows — Arial, Courier New — next to chrome that is Segoe
  UI, which is what T386 fixed in `selection.js` and `viewer.css`. The same
  hole is still open in `diff.css` and rides the win32 diff pane (T595).
- **Table of contents** (markdown only, and only with two or more headings) —
  one of the two contents of the pane's shared **side panel** (the other is a
  diff's file tree; see Git diff panes). Everything in this bullet is the
  *panel*, and therefore true of both: only the rows differ.
  A native card listing the document's headings, nested by level, with the
  section you are reading highlighted as you scroll. The card reads as a
  macOS sidebar: the selected row is a rounded pill in the system's own
  selection colors — accent-filled with white text while the window is key,
  the neutral unemphasized gray otherwise — and hover is a separate faint
  wash. **Clicking a row pins the selection to it**: the smooth scroll on the
  way there fires a scroll event per frame, and the highlight must not walk
  off the row you asked for. Your next scroll gesture hands the selection
  back to the scroll spy. A pinned "CONTENTS" header sits on Liquid Glass
  (`glassBackdrop()`, macOS 26; an `NSVisualEffectView` before that) with the
  rows scrolling *under* it, and the scroller's track stops below it —
  both from one `safeAreaInset`, not a ZStack.
  In a **wide pane** the card sits in a left gutter and the document column
  reflows beside it; **drag the card's right edge** to resize it (the gutter
  and the document's text column follow in the same layout pass). The width
  is a preference in defaults, shared by every viewer pane.
  In a **narrow pane** (< 720pt) the gutter would crowd the text, so the card
  becomes an overlay: the navigation bar stays pinned open and gains a
  contents button as its first item, which slides the card in and out. The
  switch follows the *pane* width live, so dragging a split divider reflows
  it. The card is the same glass card as the pane banner overlay (shared
  `GlassCardBackground`), opaque so document text never shows through it.
  Panel open/closed state is ephemeral — it does not survive a session
  restore, since restoring an overlay would hide the content it covers.
- **Margins are one number.** `GlassCard.outerMargin` (12pt) is the gap every
  glass card leaves around itself, on all four sides, and the document leaves
  the same 12px on all four of its own — so a TOC card and a banner in the
  pane next door line up at their corners, and the text starts exactly one
  margin right of the card. Per-component fudges are what break that; there
  are none. Enforced by `documentAlignsToTheCard` in `ViewerTOCTests`.
- **HTML files** (`.html`, `.htm`): rendered as the **live page**, not as
  markup — its own CSS, scripts, images and fonts run exactly as they would if
  it were hosted. Rendering is unconditional; there is no source-view toggle to
  carry through history and session restore. This is what removes the
  `python3 -m http.server` (or `scripts\task-dashboard.ps1`'s localhost server)
  workaround for something already sitting on disk.

  **Read access is the file's own directory, recursively** — narrow by default,
  because widening a grant later is easy and taking one back is not. The cost is
  a page reaching UP out of its folder (`../shared/app.css`), which needs the
  assets moved under the page or the project served. **A local HTML file is a
  page, not a document**: it navigates in the pane like a website (links, Back,
  Forward), and what it adds over a plain website is the file watcher — a save
  re-loads it in place, keeping the reader's scroll and replacing its history
  entry rather than filling the Back stack. Only the viewed file is watched, so
  an edited sibling stylesheet needs `+reload`, which bypasses caches.

  One structural subtlety, on both platforms: an HTML file is **not** recorded
  as the pane's file location. That field means "the file the bundled TEMPLATE
  page is holding" and is what Back out of a website re-renders, so overwriting
  it with a directly-loaded page would lose the markdown document still sitting
  behind it in history.

  **Windows serves it from a second virtual host** (`https://ghoztty-page/…`,
  T601) through the pane's existing `WebResourceRequested` handler, rather than
  from `file://`. Mac passes its grant to `loadFileURL(allowingReadAccessTo:)`;
  WebView2 has no per-navigation grant to pass, and a `file://` document's
  subresource loads reach the whole filesystem — a wider grant than the feature
  asks for and one that cannot be taken back per pane. The host is separate from
  the template's `ghoztty-viewer` because the two roots differ: a page asking
  for `vendor/markdown-it.min.js` must get its own or nothing, never ours. Every
  page-host response is `Cache-Control: no-store`, which is what lets a plain
  in-place reload still show the bytes now on disk. Acceptance:
  `test/win32/viewer-html.ps1`.
- **Images** (`.png`, `.apng`, `.jpg`/`.jpeg`/`.jpe`/`.jfif`, `.gif`, `.webp`,
  `.avif`, `.heic`/`.heif`, `.tif`/`.tiff`, `.bmp`, `.ico`, `.icns`, `.svg`):
  shown as a **picture**, zoomable and pannable, not as bytes. The list is
  fixed rather than "whatever this machine can decode", so what a `--view=`
  path does is predictable from the path; `.svg` is on it because it is a
  picture, and reading its source is what an editor is for.

  Three rules decide everything a person can argue about, and they are the same
  on both platforms:

  - **100% is one image pixel per DEVICE pixel.** It is the only definition
    under which nothing is resampled, and most of what these panes show is
    screen capture — taken at device resolution, so 100% shows it at exactly
    the size it was on screen.
  - **Best-fit never upscales.** A 16px icon opens crisp at 16px rather than
    blown across the pane.
  - **The double-click toggle always toggles.** Fit ⇄ 100%, except where those
    two coincide (any picture smaller than the pane), where the first
    double-click goes to 200% instead — a gesture that visibly does nothing
    reads as a broken gesture.

  A pane that is still at best-fit re-fits when it is resized; one the user has
  zoomed keeps their zoom, re-derived when the pane crosses to a display at
  another scale so 100% stays 100%.

  **Mac draws it on a native `NSScrollView`** (`ViewerImageView.swift`), because
  AppKit's own gesture handling — pinch anchored at the gesture centroid,
  elastic edges, momentum — is not reproducible in a page, and `WKWebView`'s
  pinch is page magnification, which knows nothing about the image's natural
  size. **Windows draws it in the bundled template** (`src/viewer/image.js`,
  T1183): win32 has no elastic, momentum-y scroller to inherit, while a
  Chromium scroll container brings precision-touchpad panning, inertia and
  overlay scrollbars with it — and staying in the page keeps history, the
  address, Home, `+list`'s url, session restore and the standard error card for
  free. The ZOOM is not the page's to decide either way: the Windows page
  reports what it measured and what the user did, and every scale it applies
  came back from `src/apprt/win32/viewer_image.zig`, which asserts the three
  rules above without a browser. The picture itself is served from a sentinel
  path (`https://ghoztty-viewer/__image?v=<n>`) under the template's own host,
  `no-store`, with the revision bumped per load — an `<img>` pointed at a `src`
  it already has does not go back to disk, which would make `+reload` on an
  image do nothing. Acceptance: `test/win32/viewer-image.ps1`.

  Find, text selection and quoting are meaningless in a picture and are not
  offered. An undecodable file gets the same in-page error card every other
  file mode falls through to, rather than a blank matte.
- **Text/code files** (anything else): syntax-highlighted by extension.
- **Websites** (`http://`/`https://`): the pane navigates there directly.
- **Git diffs** (`git-status:` / `git-diff:<revspec>`): see Git diff panes.
- **A terminal split off a viewer starts where that WINDOW is.** A viewer runs
  no shell, so there is no parent cwd to inherit: a file viewer contributes the
  viewed file's own directory (Mac's `splitConfigFromViewer`), and a viewer with
  no file — a website, a blank browser pane, a diff — contributes nothing. What
  answers then is the terminal the user was last in **in the window being
  split**: the app's focused surface when it belongs to that window, else the
  nearest terminal pane in the viewer's own tab (`SplitTree.nearestLeaf`, whose
  facing-side search returns the pane the viewer shares a divider with — almost
  always the pane it was split off). The core's own inheritance is app-GLOBAL
  (`apprt/surface.zig` `newConfig` reads `app.focusedSurface`), so leaving the
  answer to it opened the new pane in whatever window last had focus, or — with
  nothing focused at all — in the shell's home directory (T538, win32; the Mac
  half is T759). Acceptance: section 11 of `test/win32/viewer-panes.ps1`, whose
  cross-window arm parks the focus in a second window first, so the assertion
  cannot pass by luck.
- **Links** in file viewers: http(s) opens the default browser; a relative
  `.md` or `.html` link opens another viewer split (both render here, so handing
  either to the default app would launch the browser for a page the pane next
  door was about to show); other local files open in their default app.
- **Links out of a LIVE page** (a website or a rendered `.html` file) open the
  **default browser** too, and the pane stays where it was (**T825**; Mac
  18acc4f6f). Same cookie-store reason as popups: a hop to another site renders
  logged-out in a store nothing else shares. "Another site" is host + the port
  as written — an `http`→`https` upgrade on one host stays in the pane,
  `localhost:3000` → `localhost:5173` does not, and a subdomain is another
  site. Only the person's own click on the top-level page leaves: a page's own
  redirects, script navigations, form posts and iframes are the page working,
  and so are the pane's own loads (`--view=<url>`, the address bar, a restored
  session).
- **Right-clicking a link** in ANY viewer page — the bundled template, a
  rendered `.html` file, a website — shows **Ghoztty's own link menu**, the same
  one a terminal banner link shows: the left-click default first, then Open in
  Side Pane / Open in New Window, then Copy (**T826**; Mac 18acc4f6f). The rows,
  the order and the ids are `banner_link.zig`'s on Windows and
  `BannerLinkOpener`'s on Mac — neither surface forks the menu. What decides
  whether a right-click is one of ours is the SHARED `src/viewer/links.js`,
  injected into every page (win32 rides the same blob as `selection.js`, behind
  the `viewerTOC` shim): it declines `mailto:`, `javascript:`, `data:`, a
  same-document `#anchor`, and a click inside a selection, and in each of those
  the page keeps the browser's own menu.

  The menu acts on what the link IS, not on the URL the page holds: a relative
  doc link and a link inside a rendered `.html` page both live under a synthetic
  host that means nothing outside this process, so win32 resolves them to the
  FILE first (`viewer_content.linkMenuTarget` + the pane's resolution, which is
  the click path's own). Copy on a doc link gives a path you can paste into a
  shell. **Known win32 divergence**: a link inside an **iframe** keeps WebView2's
  menu, because a subframe's `postMessage` reaches `ICoreWebView2Frame`'s event
  and not the web view's — suppressing the page's menu there would leave the
  right-click with nothing to show (T928). Mac runs the script in subframes.
- **Links that open a new surface** in a website viewer — `target="_blank"` or
  `window.open()` — go to the **system default browser**, not a new Ghoztty
  window, for the same cookie-store reason banner URLs do. Same-pane
  navigation is untouched, WITHIN the site: a live-page viewer follows ordinary
  links in place as long as they stay on the page's own site.
  **Cmd-click** (**Ctrl** on Windows) keeps the popup in Ghoztty as its own
  viewer window (honoring the size the opener asked for), and so does a popup
  the browser can't be handed — a bare `window.open()` with no URL, or a
  non-web scheme. The modifier belongs to the **click**: a popup a script opens
  on its own routes normally whatever keys are down, since win32 reads Ctrl off
  the whole desktop's keyboard and would otherwise let a Ctrl held in another
  app decide where a background popup lands (T860, `viewer_popup.ctrlEscape`). The tradeoff: a popup that lands in the browser can't
  `window.close()` itself back to the Ghoztty page that opened it, so an OAuth
  flow finishes in the browser. That flow wasn't authenticating in Ghoztty
  anyway.

  **A kept popup is ADOPTED, never re-opened** (T163). The window's one pane
  hands its own web view to the runtime — Mac returns a `WKWebView` built from
  WebKit's `configuration` out of `createWebViewWith`; win32 parks the request
  on a WebView2 deferral and answers it with `put_NewWindow` once its pane's
  controller exists — and the runtime navigates that view itself. Opening a
  pane at the same URL instead is the mistake the whole path exists to avoid:
  it is a *different* window as far as the opening script is concerned, so
  `window.opener`, a write through the handle `window.open()` returned, and
  `window.close()` are all dead. `window.close()` closes the popup's pane and
  nothing else (Mac `webViewDidClose`, win32 `add_WindowCloseRequested` →
  posted, never handled inline, because closing a pane tears down the very
  controller whose callback you are in). The one thing win32 cannot copy is
  where the modifier comes from: WebView2 puts no modifier state on the popup
  args, so Ctrl is read with `GetAsyncKeyState` — `GetKeyState` there answers
  for the browser-process message being dispatched, not for the click.
  Acceptance: `test/win32/viewer-popup.ps1`, plus the live ABI test in the
  win32 unit lane (`ViewerPane.zig`, "T163: a popup is adopted as a pane,
  sized, and can close itself").
- **Live reload**: file viewers watch the file (including atomic saves) and
  re-render preserving scroll position. A rendered `.html` file reloads the
  page in place instead of re-rendering into the template — same promise, the
  engine's own scroll restoration rather than the template's.
- **Navigation chrome**: every mode gets a bar with back / forward / reload /
  **home** and an **editable address field**; what differs is whether it is
  always there. A **live page** — a website, or a local HTML file the web view
  renders as one — **pins it open**: that is something you navigate, so the
  address and the history controls are part of using it, and a blank browser
  pane is nothing but its address field. A **markdown or code** viewer is a
  reading surface whose address rarely changes, so it keeps the **hover peek**:
  the bar slides in when the cursor reaches the thin strip at the pane's top and
  auto-hides after inactivity. The pin follows the pane's CURRENT mode, not the
  location it was opened with — a markdown pane that browses to a website gains
  the pinned bar, and Back to the file hands it back to the hover timer. Either
  way a visible bar **reserves** its band (the page is inset below it, never
  covered), so a pinned pane's content is laid out below the bar from its first
  frame. The compact table-of-contents layout pins it too, for its own reason
  (see Table of contents). Typing an `http(s)` address (or a
  bare `example.com`, completed omnibox-style) navigates the pane to the web;
  typing an absolute or `~` path points it back at a file. Back and forward
  reflect real history (disabled when there is none) and work across the
  file↔web boundary — going Back from a website re-renders the file. **Home**
  returns to the location the pane was originally opened with, which is
  remembered separately from where the user has navigated to (and both
  survive a session restore). Clicking into the address field selects the
  whole address; clicking again inside it just moves the caret.
- **Keyboard** (pane-scoped: live only while keyboard focus is inside a
  viewer pane — its page, its nav bar, or its feedback composer — in any
  viewer mode):
  - **Cmd+R** reloads the pane in place, exactly like `+reload` (web
    re-fetches from origin, files re-render with scroll preserved).
  - **Cmd+D** slides the nav bar in if hidden and puts the caret in the
    address field with the whole address selected — the keyboard version of
    clicking into it.
  - The standard editing chords (Cmd+C/V/X/A) reach whichever field inside the
    pane holds focus — the address bar, or a diff panel's filter — which they
    otherwise would not, because Cmd+C/V are terminal keybindings.
  - Both **override their global binding only while the viewer holds focus**
    (Cmd+R = "Set Pane Banner…", Cmd+D = split right). Focus a terminal pane
    and they do their global thing again; Cmd+Shift+R ("Change Window Title")
    and Cmd+Shift+D (split down) are never affected.
  - **On Windows** (T161) the pane-scoped chords are **Ctrl+R** (reload),
    **Ctrl+D / Ctrl+L / Alt+D** (address bar — the latter two are
    Windows-native aliases), and **Ctrl+Plus/Minus/0** (page zoom, same ×1.1
    step and [0.5, 3.0] clamp as the Mac Cmd+/−/0), under the identical
    override-only-while-focused rule: a focused terminal keeps ctrl+r for
    the shell, ctrl+d for split-right, and ctrl+plus/minus/0 for font size.
    Zoom is content-scoped (not live in the address field), matching Mac.
- `--view=about:blank` opens a **blank browser pane**. The command palette's
  "Viewer: Open Browser Pane" does the same interactively and puts the caret
  straight in the address field — the equivalent of `+split --view=<url>` for
  when the URL is not known up front.
- Because any viewer can browse, `+list --json`'s `"url"` (and the session
  manifest) report where a pane currently IS, not where it was opened.
- Relative `--view` paths resolve against `--working-directory` if given,
  else the caller's cwd. A `git-*:` spec is NOT a path — its text is a revspec,
  so it is never path-resolved; the same `--working-directory` decides which
  *repository* it applies to.
- `+list` marks viewer panes with a `view:` prefix (JSON: `"type": "viewer"`
  plus `"url"`); they auto-register names like terminal panes.
- `+read`/`+send-keys`/`+set-state`/`+set-banner` against a viewer fail with
  `... is a viewer pane, not a terminal` (exit 1). `+close` works normally
  and never prompts for viewers.
- Session persistence: viewer panes restore by re-opening their file/URL, and
  a diff pane by RE-RUNNING its spec against the origin directory the manifest
  persisted — so a restored `git-status:` pane shows today's working tree, not
  a snapshot of the one it was closed on. (Terminals in the same window
  re-attach as usual.) A missing file restores as an in-page error card.
- File → Open (or dragging onto the dock icon, or `open -a Ghoztty file.md`)
  opens `.md`-family files as a viewer window.

### Find in page

`Ctrl+F` opens a small find card at the pane's top-trailing corner, in every
viewer mode — markdown, code, a local HTML page, a website, and a git diff.
The behaviour is the browser one people already have:

- Typing highlights every match (yellow, current one orange) and shows a live
  count: `3/17`. The count stays live while the page changes underneath an
  open search, so a diff still streaming its rows keeps counting up.
- `Enter` / `Shift+Enter`, the card's chevrons, and `Ctrl+G` / `Ctrl+Shift+G`
  step through matches, wrapping. `F3` / `Shift+F3` are the Windows spelling of
  the same pair and do the same thing; Mac has only `Cmd+G` / `Cmd+Shift+G`.
- `Escape` closes the card and clears the highlights but KEEPS the query, so
  the next-match chord resumes it and `Ctrl+F` comes back to it selected.
- The card FLOATS over the document rather than adding a band under the nav
  bar: a markdown pane hides its nav bar until you reach for it, so a band
  would make `Ctrl+F` reflow the very text you are about to search. Matches
  scroll to the middle of the pane, so the card is never over the match it
  just found.
- It is honest about what it is not searching: unlaid-out text is excluded, a
  page with a visible frame says `frames not searched`, past 5000 matches the
  count reads `12/5000+`, and a diff pane names the file it is searching (a
  diff pane holds one file's patch at a time) plus whether its row cap is in
  force.

The search itself is shared JavaScript — `src/viewer/find.js`, one file for
both platforms — injected into every document rather than loaded from
`viewer.js`, which never reaches a real web page. It paints with the CSS
Custom Highlight API and mutates no DOM, so a find on a live dev server cannot
corrupt its rendering. The win32 half is the card (`ViewerFindBar.zig`), its
geometry and the Escape/Return precedence across the pane's text fields
(`viewer_find.zig`, unit-tested in the `none` lane), and the chords
(`viewer_accel.paneChord`). Acceptance: `test/win32/viewer-find.ps1`.

### Git diff panes

`--view=git-status:` / `--view=git-diff:<revspec>` opens a pane that renders a
git diff: a native file tree on the left, traditional red/green
syntax-highlighted hunks on the right, and next/previous-change +
unified⇄side-by-side controls in the nav bar.

**Both platforms render one now** (T463, win32). The CLI half was always shared
— `cli/view_arg.zig` knows both schemes and passes them through path resolution
untouched, mirroring `ViewerDiffSpec.parse` — and so are the page assets
(`src/viewer/diff.js`, `diff.css`); what T463 added on Windows is the third
thing the bundled template can render (`content.Mode.diff`), the git plumbing
behind it, and the two payloads the page reads. What the win32 pane still lacks
is CHROME, filed rather than left undocumented: **T464** (the file-tree side
panel, which is also how a many-file diff is navigated) and **T817**
(next/previous-change and the unified⇄side-by-side toggle). Until T464 lands a
win32 diff pane opens its FIRST file and stays there.

The win32 split mirrors the Mac's: `src/apprt/win32/viewer_diff.zig` is pure —
the spec parse, the table of git invocations, the `-z` output parsing and the
`window.__viewer.setDiffListing` / `setDiffFile` calls — and asserts in the
`none` lane; `ViewerDiffProbe.zig` is the half that spawns `git` on a worker
thread and posts `WM_APP_VIEWER_DIFF` back, because the viewer's message loop is
the one the terminal next door draws on. Two Windows-shaped details worth
knowing: the file list is read to **EOF with an overflow discard**
(`git_run.captureAlloc`) rather than into a fixed buffer, since a `readAll` that
stops on a full buffer leaves git blocked writing into a pipe nobody drains and
the `wait` after it never returns; and every invocation carries
`GIT_TERMINAL_PROMPT=0` + `GIT_OPTIONAL_LOCKS=0`, which is what keeps a
credential prompt from wedging a worker the pane's teardown has to join (the
remaining deadline is **T818**). Acceptance: `test/win32/viewer-diff.ps1`, whose
oracle is the app's own log — `+list --json` cannot see inside a WebView2 — plus
the win32 lane's live host-floor test, which reads the rendered DOM back and is
what proves the log line was true.

```bash
# changes in this branch against main (three-dot: the merge base, which is
# what "changes in this branch" means to a person)
ghoztty +split --target=dev --name=diff --view=git-diff:main...HEAD

# the working tree — staged, unstaged, and untracked, kept apart
ghoztty +new-window --target=review --working-directory=~/git/repo --view=git-status:

# one commit's own changes, and an arbitrary range
ghoztty +split --view=git-diff:a1b2c3d
ghoztty +split --view=git-diff:v1.2.0..v1.3.0

# this branch against main/master/origin HEAD, whichever the repo has
ghoztty +split --view=git-diff:

ghoztty +reload --target=diff        # re-run the diff
```

**The location IS the diff spec**, which is what buys every existing viewer
affordance for free — the address bar shows and accepts it, `+list --json`
reports it as the pane's `url`, `+reload`/Cmd+R re-runs it, back/forward cross
into and out of it, and the session manifest restores the pane by re-running
it. Four forms:

| `--view=` | Means |
|---|---|
| `git-status:` | Working tree: staged, unstaged, and untracked |
| `git-diff:<a>...<b>` | Three-dot range — `<b>` against the merge base |
| `git-diff:<a>..<b>` | Two-dot range, handed to git verbatim |
| `git-diff:<sha>` | That ONE commit's changes (`git show`, first-parent for merges) |
| `git-diff:` | This branch against `origin/HEAD`, else `main`/`master` |

A bare revision means *that commit*, not "diff against it" — `git-diff:abc123`
answers "what changed in abc123". Use `a..b` when you mean a comparison.

- **Which repository**: the one containing `--working-directory` (else the
  caller's cwd, which `+split`/`+new-window` insert for you), resolved with
  `git rev-parse --show-toplevel`. A directory in no repo renders an
  explanatory card, not a blank pane.
- **The file tree is the table-of-contents card**, not a lookalike: same glass
  card, same pinned header, same row metrics and macOS selection pill, same
  gutter⇄overlay switch at 720pt, same drag-to-resize handle and shared width
  preference (`ViewerSidePanel` owns all of it). What it adds is a **filter
  field pinned under the header** — terms are ANDed against the whole path, a
  non-empty filter flattens the tree to a hit list, Return opens the top hit,
  Escape clears it — plus folder/file hierarchy with git's own status letter
  (A/M/D/R…) and each file's `+N −M`. Chains of single-child directories
  collapse into one row (`macos/Sources/Features/Viewer`), and clicking a
  folder folds it.
- **Working-tree sections**: staged, unstaged, and untracked are three lists,
  in that order, because which changes are staged is the thing `git status`
  exists to tell you. A file modified both staged and unstaged appears in both
  (they are different diffs), and clicking each shows that side.
- **Scale**: the file list is eager (one `--numstat`/`--name-status` pass —
  cheap for thousands of files) and each file's PATCH is fetched only when its
  row is clicked. Rows are appended to the page in chunks across frames, with
  a 20 000-row cap and a "Show the rest" button past it. Binary files and
  unreadable ones render a stub, never a hang. All git work runs off the main
  thread.
- **Rendering** is hand-rolled over parsed unified hunks (no new vendored
  dependency, zero added bundle weight) on the already-bundled highlight.js.
  Each hunk is highlighted as two contiguous texts — the old side and the new
  side — rather than line by line, so a block comment or template literal is
  not restarted on every row, and the result is split back into lines with the
  open tags carried across the break. Paired removed/added lines get an
  **intra-line word highlight** so a one-character change reads as one
  character. Deliberately NOT Monaco: this pane is read-only, and a
  multi-megabyte editor would blow up an offline bundle to lose on scroll
  performance.
- **Unified vs side-by-side**: unified is one column with sticky line-number
  gutters and horizontal scroll (code keeps its shape); side-by-side is a
  four-column CSS grid, so a pair stays aligned even when a long line wraps.
  The choice is a preference in defaults, shared by every diff pane.
- **Next/previous change** steps *change blocks* (a `@@` hunk can hold
  several), and rolls over into the adjacent FILE when the open one runs out —
  entering it at its first or last change so walking a diff reads continuously.
  It steps from a remembered index, not from the scroll position, so a fast
  double-press advances twice instead of re-picking the change the smooth
  scroll has not reached yet; your own next scroll hands it back.
- **Live**, on both platforms: a `git-status:` pane re-checks the working tree
  every 2s and updates only when the file list actually moved, so an edit or a
  `git add` in another pane shows up without a reload and without a flicker. A
  commit or a range is a fixed pair of trees and is not polled. A poll rather
  than a file watcher because the thing being watched is a whole REPOSITORY: a
  watcher would have to cover every tracked file, the index and HEAD, and would
  still miss a `git add` made in another checkout of the same repo.
- The nav bar **stays pinned open** in a diff pane (it carries the change and
  layout controls, and shows the revspec). macOS only — the win32 nav bar has
  no diff controls to pin it open FOR yet (T817).

The four bullets above this one — the file tree, the unified⇄side-by-side
choice, next/previous change, and the pinned nav bar — are the Mac's chrome and
are the whole of what T464/T817 owe Windows. Everything else in this section
(the four spec forms, repository resolution, the working-tree sections, the
scale rule, the rendering, and the live poll) holds on both.

### Worktree feedback capture

When a viewer pane's content can be attributed to a **git worktree**, its
navigation bar gains a **feedback button** (labeled with the worktree's
basename, full path on hover) that opens a composer toolbar below the nav bar.
On send it writes a report — plus any pasted screenshots — into
`<worktree>/temp/feedback/new/` for an external watcher to drain (Ghoztty produces
the queue; consuming it is separate and not built here).

- **Provenance (strategy D — port lookup first, pane-origin fallback).** The
  worktree is derived live from the pane's *current* location, re-resolved on
  every navigation (a pane can move between a file, `localhost:3000`, and a
  remote site, each a different worktree or none):
  1. **File viewers** → the viewed file's own directory.
  2. **`http://localhost:PORT` / `127.0.0.1` / `0.0.0.0` viewers** → the port's
     listening pid's cwd, via `lsof` (`-iTCP:<port> -sTCP:LISTEN -t`, then
     `-p <pid> -d cwd -Fn`) run off the main thread. lsof, not
     `proc_pidinfo`, because there is no port→pid syscall.
  3. **Fallback** (remote site, blank pane, or a port with no listener) → the
     pane's **origin directory**: `--working-directory` at `+split --view=` /
     `+new-window --view=` time, else the caller's cwd. `+split` now seeds the
     caller's cwd as `--working-directory` for `--view=` splits (terminal
     splits are unchanged so cwd inheritance still works). The origin is
     persisted in the session manifest (`viewerOriginDirectory`).

  Whatever directory results is resolved to a repo root via `git -C <dir>
  rev-parse --show-toplevel` (**any** working tree counts — a linked worktree
  or the main checkout). No repo ⇒ no feedback button. Resolutions are cached
  per (location, origin) for 15s so navigation never stutters and a dev server
  started later still makes the button appear.
  **Windows has all three legs and the button** (T633, T638): the strategy, the
  classification and the 15s cache are `src/apprt/win32/viewer_worktree.zig`
  (pure, asserted in the none lane), and the `git rev-parse` runs on a worker
  thread that posts `WM_APP_VIEWER_WORKTREE` back at the pane —
  `ViewerWorktreeProbe.zig` — because the viewer's message loop is the one the
  terminal next door draws on. Leg 2's translation of `lsof` is
  `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)` for the listening pid
  (`src/os/listening_pid.zig`, both address families) and the PEB walk
  `src/os/process_cwd.zig` already does for that pid's working directory —
  Windows exposes no documented API for another process's cwd, and the
  alternative on offer, guessing from its command line, is exactly the
  confidently-wrong answer the report format avoids everywhere else. Both are
  syscalls against an untrusted process, so they ride the SAME worker as git:
  `viewer_worktree.plan` settles legs 1 and 3 on the message loop (string work)
  and hands a `.port` plan to the worker. Every failure — no listener, another
  user's process, a pid that exits mid-lookup — degrades to leg 3, never to a
  wrong repo. Acceptance: `test/win32/viewer-worktree.ps1` (legs 1 and 3) and
  `test/win32/viewer-worktree-port.ps1` (leg 2).

  The button is **icon-only**, in the same 24pt square as the other chrome
  controls; the destination is on its tooltip and in the composer footer.
- **Composer.** A **pill** that grows with its content (one line up to ~6),
  with two **circular buttons inside its trailing edge**: `+` takes an
  interactive screen snapshot (`screencapture -i -o` to a temp file — never
  `-c`, which would clobber the user's clipboard), and `↑` sends. `Enter`
  inserts a newline, `Cmd-Enter` sends, `Escape` closes.
  **Windows has the composer's chrome** (T634): the same pill and the same two
  circular actions, opened and closed by the same button, with `Ctrl+Enter` for
  Mac's `Cmd-Enter`. It is a native owner-painted child window under the nav
  bar — the page is inset by its band and gets the space back as the pill
  shrinks — and the nav bar stays pinned open while it is up, since the button
  that closes it lives there. The pill is a **capsule**, a named exception to
  the win32 radius scale (design system §3.1), with the radius pinned to the
  collapsed height so a six-line pill does not become an oval. Geometry:
  `src/apprt/win32/viewer_feedback_layout.zig` (asserted at 1.0/1.25/1.5/2.0);
  chrome: `ViewerFeedbackBar.zig`; acceptance: `test/win32/viewer-feedback.ps1`.
  **The composer's TEXT and its open flag live on the pane, not on the toolbar
  window**, which is what makes contents survive a close/reopen on both
  platforms.

  **The win32 editing surface is a WebView2 contenteditable** (T934) — a
  SECOND `ICoreWebView2Controller` filling the pill's text rect, on the pane's
  own environment, hosting a page we author
  (`ViewerFeedbackWeb.zig` + `viewer_feedback_page.zig` +
  `src/viewer/composer.{css,js}`). D43 was answered *against* its own
  recommendation for the reason the answer gives: caret, selection, wrap, undo,
  clipboard, drag-drop, IME composition and a screen reader that can read the
  field all come from the browser engine rather than from us. Four things to
  know before touching it:

  - **The direction of truth is inverted.** A RichEdit answers `caret()` and
    `lineCount()` on the caller's stack; a WebView2 cannot. So the PAGE owns the
    live document and pushes a snapshot up (`{t:"state", text, lines, caret,
    gen}`) on every edit, and native keeps the last snapshot as what it lays out
    and serializes from. Native writes go down as `{t:"seed", …}` — "make the
    document equal the buffer", the only write there is, because it cannot drift
    from the buffer.
  - **`gen` is not optional.** Every seed is stamped and every snapshot echoes
    the stamp, so a snapshot measured before the latest seed is recognisable and
    dropped. Without it a keystroke racing a native write silently resurrects
    the text that write replaced. `ViewerPane.feedbackSetText` re-seeds the page
    itself, so every native writer is covered rather than the ones somebody
    remembered.
  - **The controller is created on the first OPEN and destroyed on CLOSE** —
    D43's own mitigation for the memory and startup cost. Nothing a user would
    miss lives on it; the report text is the pane's.
  - **Keys reach Chromium, not the app's message loop.** The composer's chords
    and the whole pane/keybind table are claimed in `AcceleratorKeyPressed` with
    `put_Handled`, which is also the only thing that stops the browser acting on
    a chord we took (an unclaimed Ctrl+R would reload the composer's own page).
  - **The design numbers come from the layout module**, pushed in as CSS custom
    properties on each theme or scale change (D43's other mitigation); the
    stylesheet states no size or colour of its own, and a unit test asserts that.

  **The RichEdit below it is the FALLBACK**, not dead code: a box whose
  environment cannot produce a controller still gets a composer, and
  `GHOZTTY_COMPOSER_SURFACE=richedit` forces it. **T937** retires it. Which one
  is live is stated on every open —
  `viewer feedback composer surface=web|richedit(...)`. Acceptance is split to
  match: `test/win32/viewer-composer.ps1` proves the web surface's lifecycle and
  its round trip, `test/win32/viewer-feedback.ps1` pins itself to the fallback
  and keeps proving the editing semantics (window messages cannot drive a
  Chromium window off the input desktop, T233), and the in-process `host floor`
  test in `ViewerPane.zig` drives a real controller end to end — open, seed,
  quote, send, report on disk.

  The RichEdit half, as it was and as the fallback still is (T635): the
  control is the storage while the composer is open and every change mirrors
  back into the pane from `EN_CHANGE`; the pane is still what outlives the
  window. Three win32 details worth knowing: RichEdit sends **no** notifications
  until `EM_SETEVENTMASK`/`ENM_CHANGE` asks for them; it does **not**
  answer `EM_SETCUEBANNER`, so the empty composer's placeholder is painted by
  a subclass over the control's own `WM_PAINT`; and the mirror reads the
  control with `EM_GETTEXTEX`/`GT_DEFAULT` rather than `WM_GETTEXT`, because
  the latter expands each paragraph mark to CR+LF and every quote offset the
  composer computes has to index the control and the pane's buffer the same
  way.
  **The composer's two indexings are BYTES and CODE UNITS, and it converts
  between them** (T648). Every pure module here works in byte offsets into the
  pane's UTF-8 buffer — which is right, since that buffer is what the report is
  written from — and every edit message (`EM_EXSETSEL`, `EM_EXGETSEL`,
  `EM_POSFROMCHAR`) works in UTF-16 code units. Those agree **only for ASCII**:
  `é` is 2 bytes and 1 unit, an emoji is 4 bytes and 2 units. Handed straight
  across, a quote or an image chip landed short by the accumulated difference —
  silent corruption of what the user wrote, invisible to anyone typing plain
  English. So a `CHARRANGE` is never filled from a byte offset directly: it
  goes through `ViewerFeedbackBar.charIndex`, and a number out of the control
  goes through `.byteOffset`, both over the pure `utf16_offset.zig`. The
  conversion has exactly ONE home — the address bar and the banner editor only
  ever `EM_SETSEL(0, -1)`, so they compute no offset to get wrong. Line endings
  need no conversion (see `GT_DEFAULT` above); the encoding does. Acceptance:
  `test/win32/viewer-feedback-utf16.ps1`, whose every arm compares the WHOLE
  composer text — its first draft used a `[Image` substring needle and passed
  against a deliberately broken build that had left `[Imag` behind.
  **Send files the report on Windows too** (T636): `↑`/Ctrl+Enter writes the
  same folder into the same queue, off the UI thread on a worker
  (`ViewerFeedbackSend.zig`) because two `git rev-parse` spawns and a source
  file read have no business on the message loop the terminal next door draws
  on. The format, the `sourceLine` resolver and the staging+rename publish are
  pure and asserted in the none lane
  (`src/apprt/win32/viewer_feedback_report.zig`). Two Windows-shaped details:
  the folder stem is `yyyymmddTHHMMSSZ-<6 hex>` because NTFS reserves `:`, so
  a naive port of Mac's ISO-8601 stem cannot be a directory name here at all;
  and the **selection** is TRACKED as it changes by the injected blob
  (`viewer_bridge.selection_tracker_js`, debounced and capped) rather than
  asked for at send time, so the send stays synchronous and a page that never
  answers costs a missing field instead of a stranded composer (D48). The
  revision is resolved on the SEND rather than cached with the worktree (D47),
  so a pane left open across a branch switch still names what the user saw.
  What Windows does not have yet: the long-lived DRAFT staging folder and its
  footer link (**T645**); the quoted block landed in
  **T641** (below), the image half of the composer in **T637**, its
  thumbnail carousel in **T646** and the screenshot capture in **T647**.

  **The `+` button takes a screenshot on Windows too** (T647), and it is
  D44's answer rather than a translation: the two obvious Windows equivalents
  (`ms-screenclip:`, `SnippingTool /clip`) publish their result through the
  CLIPBOARD, which is the one thing Mac's `screencapture -i -o` comment
  forbids. So Ghoztty draws its own region selector. The desktop is
  photographed ONCE before the overlay exists (`screen_capture.zig`:
  `BitBlt` + `CAPTUREBLT` of the whole virtual screen into a top-down 32bpp
  DIB, so layered chrome is in the shot and the origin may be negative); a
  darkened copy of that photograph is what the full-desktop opaque popup
  paints (`RegionSelector.zig`), with the original showing bright inside the
  drag rectangle; mouse-up crops the original. Nothing on the path opens the
  clipboard. **Ctrl+Shift+S** is Mac's ⇧⌘S while the composer has focus.
  Escape, a right-click, losing activation, and a click with no drag all
  cancel — a zero-area drag is a cancel, never a zero-pixel picture. Rect math
  and the hint card's geometry are pure (`region_select.zig`, asserted at
  1.0/1.25/1.5/2.0); every input is read out of a message's `lparam` rather
  than from `GetCursorPos`, which is what lets the acceptance script POST a
  drag on a desktop where `SendInput` is dead. Acceptance:
  `test/win32/viewer-feedback-capture.ps1`.

  **The region can be selected from the keyboard alone** (T671) — a chord that
  starts a capture nobody can finish without a mouse promises a keyboard path
  that is not there. **Arrows** move a caret (starting in the middle of the
  monitor you are on), **Ctrl+arrow** steps 32 px so crossing a 4K screen is not
  a marathon, **Enter** pins the first corner and **Enter** again captures,
  **Shift+arrow** is the shortcut that does both in one press, and **Escape**
  still cancels. Keyboard and mouse drive the SAME `anchor`/`cursor` pair
  (`region.moveCaret` / `dropAnchor`, pure), so they interleave freely, and a
  plain arrow never collapses a selection the way a text caret would — losing a
  rectangle you spent thirty presses framing has no undo anywhere in the
  gesture. Modifiers are tracked from the `WM_KEYDOWN`/`WM_KEYUP` of `VK_SHIFT`
  and `VK_CONTROL` rather than read with `GetKeyState`, for the same reason
  coordinates come from `lparam`: a posted message carries no key state, so a
  `GetKeyState` Shift would be unreachable from the harness and therefore
  untested. `begin` seeds the pair once, because Ctrl+Shift+S is itself a chord
  still held when the overlay appears. The live caret position and selection
  size are **announced, not just drawn**: they go into the hint card AND into
  the window's text, which is the name assistive tech reads — and, not by
  accident, the only oracle a background-desktop script has for painted text.
  Pasting a screenshot inserts an **`[Image #N]` chip** — one atomic
  `NSTextAttachment` (a single `U+FFFC` character), so it selects, copies, and
  deletes (one Backspace) as a unit. A **thumbnail carousel** below the input
  mirrors the chips; clicking a chip scrolls to its thumbnail and vice versa.
  **Chip numbers are stable, not positional** — deleting `[Image #2]` leaves
  the sequence 1, 3 in both the text and the carousel (never renumbered), so a
  number always points at the same image. Composer contents survive
  toggling the toolbar closed/open and a detach/undo (they live on the pane,
  not the toolbar).

  **Windows pastes pictures too** (T637), by the same two rules and with the
  same consequences. A chip there is literally the characters `[Image #3]` —
  RichEdit has no attachment run to hang an image off, the same hole quoting
  works around — so the NUMBER is the identity and the report's `images` array
  is derived by scanning the composer text for chips, exactly as `quotes` is
  derived by scanning it for passages. Delete a chip and its picture leaves the
  report; nothing has to be told about the deletion. Atomicity is restored by
  hand: Backspace or Delete against a chip selects the whole run first, because
  eating the `]` alone would leave text that still LOOKS attached and no longer
  parses (`src/apprt/win32/viewer_feedback_images.zig`, pure and asserted in
  the none lane).
  The paste path has Mac's `readablePasteboardTypes` trap in win32 dress: a
  RichEdit asks the clipboard for text and nothing else, so an image-only
  clipboard would paste as silence. The composer therefore asks first
  (`clipboard_image.zig`), preferring the registered **`"PNG"`** format — which
  browsers publish and which is copied **byte for byte**, never re-encoded —
  then `CF_DIBV5`/`CF_DIB`/`CF_BITMAP`, which are normalised through one
  `StretchDIBits` into a 32-bit top-down DIB section (GDI already knows every
  palette, mask and row order; `dib_packed.zig` supplies the one thing it will
  not, where the pixels start inside the packed block) and encoded by
  `png_encode.zig`. That encoder is **pure** — `std.compress.flate` produces
  the zlib stream `IDAT` is defined as, so there is no new vendored dependency
  and no COM on the paste path, and it asserts against a decoder written in its
  own test rather than against itself. Alpha is dropped on the normalised path
  (a clipboard DIB's fourth byte is routinely all zeroes, and honouring that
  turns a good screenshot into a blank one). Acceptance:
  `test/win32/viewer-feedback-images.ps1`.

  **And Windows has the carousel** (T646): a row of square tiles under the pill,
  one per live chip, with the two-way sync. It follows the same
  derive-from-storage rule as everything else in the composer — the strip holds
  no list of its own, it is `Store.carousel(text)`, the set the report's
  `images` array comes from — so a deleted chip's thumbnail disappears with no
  second bookkeeping path to get wrong. Three win32-shaped details: the row and
  its gap **cost nothing when there are no images**, so a composer nobody
  pasted into is exactly as tall as it was before (geometry in
  `viewer_feedback_layout.zig`, asserted at 1.0/1.25/1.5/2.0 with the scroll
  clamp and the hit test); a tile is **letterboxed, never stretched or
  cropped**, because a cropped thumbnail of a screenshot is a thumbnail of its
  middle; and tiles are decoded once through `gdiplus_decode.decodeBytes` and
  **cached by (chip number, tile size)**, which is why filing a report has to
  tell the bar its store was reset — the number sequence restarts at 1 and the
  cache would otherwise paint the picture that was just sent. The sync is a
  click on a tile → `EM_EXSETSEL` over its whole chip, and a caret inside a chip
  → that tile ringed and scrolled into view (the caret side rides `EN_CHANGE`
  plus the RichEdit subclass's post-dispatch hook, since RichEdit only notifies
  what it is asked to). Acceptance:
  `test/win32/viewer-feedback-carousel.ps1`.

  **⇧⌘S** adds a screenshot from the keyboard while the composer has focus
  (free: the app's shift+cmd letters are t/z/w/d/f/g/v/n/r/[/], and macOS's own
  capture shortcuts are ⇧⌘3/4/5).

  The text view **must** override `readablePasteboardTypes` to include image
  types. AppKit validates the Edit▸Paste menu item against that list, so
  without it Cmd-V is *disabled* for an image-only clipboard and the paste
  override never runs — a silent no-op. `importsGraphics = true` does **not**
  add those types; only the override does.
- **Quoting.** Selecting text in a viewer pops a small **Quote / Copy**
  toolbar (standard `format_quote` / `content_copy` glyphs) above the
  selection. It lives in `src/viewer/selection.js` and is injected as a
  **`WKUserScript` into every page** — it cannot ship inside `viewer.js`,
  which is a `<script src>` in `viewer.html` and therefore only ever runs on
  the bundled template, which is why quoting used to work on markdown and do
  nothing on a website. Because it runs inside pages we do not control, its UI
  lives in a **shadow root** so page CSS cannot restyle or hide it. *Copy* puts it on the clipboard; *Quote* opens
  the composer (if closed) and inserts the passage at the caret as its own
  block — indented, with a tinted panel and an accent bar down the left, drawn
  in `drawBackground(in:)` (a background-color attribute paints only tight line
  boxes, with no bar and no rounding). The run carries a `feedbackQuoteID`
  attribute, so deleting it drops its metadata from the report — the same
  derive-from-storage rule the image carousel uses. The body renders it as a
  real markdown blockquote. Typing never inherits quote styling: AppKit
  carries `typingAttributes` over from text around the caret *including text
  just deleted*, so select-all + delete + type used to leave the user trapped
  writing inside the quote (and resurrected its metadata). The delegate
  refuses quote attributes at the source.

  **Windows has the same two-button toolbar and the same quoted block** (T641).
  Quote used to be hidden here (`window.__ghozttyHideQuote`, set by the
  injected blob) because there was nowhere to put the text; T635 built the
  composer and that flag is gone, so the shared `selection.js` now ships both
  buttons on both platforms. What differs is only how identity survives an
  edit: RichEdit has **no per-run user field** to hang a `feedbackQuoteID` on,
  so a quote is recovered from the TEXT — a registry entry is live when its
  passage still occupies a **complete run of lines** at or after the previous
  quote's end (`src/apprt/win32/viewer_feedback_doc.zig`, pure and asserted in
  the none lane). Same consequence as Mac's: delete the block and its metadata
  leaves the report, quote the same passage twice and you get two quotes; plus
  one Mac does not have — *editing* a quote's characters drops its context,
  which is the honest answer once the text is no longer the passage the
  context describes. The block is drawn with a wash (`CFM_BACKCOLOR`), a
  paragraph indent (`PFM_STARTINDENT`) and a **hand-painted accent bar**,
  because RichEdit's background colour paints tight line boxes with no bar —
  the same limitation that makes Mac draw its own. The typing trap has a win32
  spelling too: RichEdit carries character formatting forward from the
  character before the caret, so the composer resets typing attributes to
  plain **before** each `WM_CHAR`/paste/Enter that lands outside a quote.

  Each quote carries **referential context** so an agent can find what was
  being discussed (text alone is ambiguous — the same sentence can appear
  twice): the containing section's `headingId`/`headingText`, the containing
  block's `blockSelector` and full `blockText`, `offsetInBlock`,
  `documentOffset`, and — for file viewers — a 1-based **`sourceLine`**,
  resolved natively at send time by searching the file for the passage
  (mapping rendered DOM back to markdown source is unreliable; searching is
  not). It reports nil rather than a confidently wrong line.
- **Report output.** One **self-contained folder per submission**, so a report
  can be moved or handed to an agent as a unit:

  ```
  <worktree>/temp/feedback/new/<timestamp>-<suffix>/
      report.json
      images/image-1.png
  ```

  The whole folder is built under `temp/feedback/.staging/` and moved into place
  with a single **atomic `rename`** (same filesystem), so a watcher sees either
  nothing or a complete report with every image already present. Promoting one
  to an `in-progress/` queue is likewise a single `mv` — image paths in the
  report are folder-relative, so they survive the move. On Windows the rename is
  `std.fs`'s `MoveFileExW` **without** `MOVEFILE_COPY_ALLOWED`, so a staging
  area that somehow ended up on another volume fails loudly rather than
  degrading into the non-atomic copy this design exists to avoid.
  The queue lives under **`temp/`** because that name is already gitignored
  here (`.gitignore`) and conventionally elsewhere; a top-level `.feedback/`
  was not, so every filed report showed up as untracked in `git status`.
  **Format is JSON** (not markdown-frontmatter: a multi-line prose body with a
  `---` or `key:` line breaks naive frontmatter splitting; JSON has one parse
  path). `body` is markdown with each chip rendered as a
  `![Image #N](images/image-N.png)` reference relative to the folder.
  Alongside it, deliberately generous context so a downstream agent needn't ask
  follow-ups: `source` (`location`, `kind`, `filePath`, **`relativePath`** —
  repo-relative, `pageTitle`, **`selection`** — the text the user had selected,
  i.e. what they were pointing at, `paneID`, `viewport`), `worktree` (`path`,
  `name`, **`branch`**, **`commit`** — the exact revision they saw), `app`,
  `quotes` (see above), and `images` (with pixel dimensions and byte size). On success the composer
  clears and the toolbar shows a "Filed …" confirmation before closing.
  Absent optionals are **dropped, not written as `null`** (Swift's
  `JSONEncoder` omits a nil property, and the win32 writer matches it), so a
  report written on either platform has the same key set for the same content.
  The JSON keys are the contract and are spelled exactly as Mac emits them —
  `paneID` with a capital D and `headingId` with a small one, which disagree
  with each other and stay that way, because the watcher reading them is shared.

