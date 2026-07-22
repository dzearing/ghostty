# Ghoztty

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds CLI-driven window management for AI agents and automation.

## CLI Window Management

IPC commands communicate with a running Ghoztty instance over a Unix domain socket. All commands are idempotent — named targets that already exist are focused instead of recreated.

### `ghoztty +new-window`

Create or focus a terminal window. Auto-launches Ghoztty if no instance is running.

```
ghoztty +new-window --target=<name> --working-directory=<path> --command=<cmd> --view=<path-or-url> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --no-activate -e <args...>
```

- `--shell`: Shell to use for `--command`/`--split-command`, invoked with `-lic` so profile is loaded. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`.
- `--view`: Open a window whose single pane is a **viewer** (see Viewer Panes below) instead of a terminal. Mutually exclusive with `--command`/`-e`.
- `--title`: Set the **window title**. A window title pins the titlebar — it wins over any tab or pane title and survives pane focus changes and shell OSC title updates — until cleared. The titlebar falls back to window title → active tab's title → active pane's title. Interactive equivalents: Cmd+Shift+R ("Change Window Title", also sets/clears it), plus separate "Change Tab Title" and "Change Pane Title" commands in the menu and command palette. `ghoztty +rename --target=<name> --title=<title>` changes it later (`--title=""` clears the pin).

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --view=<path-or-url> --shell=<path> --working-directory=<path> -e <args...>
```

- `--direction`: Split direction. Default: `right`.
- `--target`: Named window to split in (default: most recently focused).
- `--name`: Register the new pane with a name for later targeting.
- `--view`: Open a **viewer** pane (see Viewer Panes below) instead of a terminal. Mutually exclusive with `--command`/`-e`. Works with `--pane` targeting, including splitting off an existing viewer pane.

### `ghoztty +close`

Close a named pane or window. Closing a nonexistent target succeeds silently.
For a session-persistence pane this ENDS the agent session (the process is
killed once the close's undo window expires) — same as closing the pane in the
GUI. Only an app quit keeps sessions alive for re-attach.

```
ghoztty +close --target=<name>
```

### `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout.

```
ghoztty +read --name=<pane> --lines=<N>
```

- `--name`: Named pane to read from (required).
- `--lines`: Number of lines from the end of scrollback (default: 50).

### `ghoztty +list`

List open windows, tabs, and panes (human-readable tree, or `--json`). Listing auto-registers every pane it discovers, so returned names are immediately usable as targets.

```
ghoztty +list [--json] [--tty=<tty>]
```

- `--tty`: Print only the registered name of the pane whose terminal matches the given tty (`ttys014` or `/dev/ttys014`; raw padded `ps -o tty=` output is accepted), then exit. Exits 1 if no match. Lets a process find its own pane: `ghoztty +list --tty="$(ps -o tty= -p $PPID)"`.

### `ghoztty +sessions`

List the persistent terminal sessions owned by the local `ghoztty-agent` (the daemon that keeps session-persistence PTYs alive across app restarts). Unlike the other IPC commands, this dials the agent **directly** over its 0600 unix socket (`~/.config/ghoztty/local-agent[-debug]/agent.sock`) — NOT the app's IPC socket — so it works even when the Ghoztty app is not running (as long as the agent is). Requires `session-persistence = on`.

```
ghoztty +sessions [--json]
```

Each row reports the session id, liveness (`alive`, or `dead(<code>)` for a tombstoned session), whether a viewer is currently `attached`, the activity state (`idle`/`busy`/`needs_input`), the child pid, `pinned` when the session is protected from the agent's idle-TTL reaper (persistent local panes are pinned so they survive the viewer quitting indefinitely; cross-machine sessions are not), the working directory (when known), and the command. `--json` emits one object per session for scripts and agents.

```bash
ghoztty +sessions
ghoztty +sessions --json
```

### `ghoztty +send-keys`

Send text input to a named pane's terminal PTY.

```
ghoztty +send-keys --target=<name> <text|key>...
```

- `--target`: Named pane or window to send input to. Required.
- `--when-idle`: Poll the target pane's recent output every 500ms until it no longer contains `esc to interrupt` (Claude Code's busy marker) before sending; sends anyway after `--idle-timeout=<seconds>` (default 30) or if the pane can't be read.
- Positional arguments are text or key names, concatenated and written to the PTY.
- Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term C-c
ghoztty +send-keys --target=term "hello\tworld\n"
```

### `ghoztty +set-state`

Set the activity state of a named window or pane. The state is aggregated across all panes in a window (priority: `needs_input` > `busy` > `idle`) and shown as a title suffix and custom `AXWindowActivityState` accessibility attribute.

```
ghoztty +set-state --target=<name> --state=<idle|busy|needs_input>
```

- `--target`: Named window or pane. Required.
- `--state`: Activity state. Required. One of `idle`, `busy`, `needs_input`.

```bash
ghoztty +set-state --target=dev --state=busy
ghoztty +set-state --target=dev --state=needs_input
ghoztty +set-state --target=dev --state=idle
```

Processes can also set state via OSC escape sequence: `\033]7777;<state>\007`

### `ghoztty +set-banner`

Set or clear the sticky banner of a named pane or window. The banner is a native overlay rendered above the terminal content of a pane — it persists (survives scrolling, screen clears, and content updates) until changed or cleared. Setting a banner on a window target applies it to that window's focused pane (banners are per-pane).

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

- `--target`: Named pane or window. Required.
- `--clear`: Remove the banner (empty text does the same).
- All other arguments are treated as the banner text (multiple are joined with spaces).

Banner text supports a small markdown subset: `**bold**`, `*italic*` or `_italic_`, `__underline__`, `` `code` ``, and `[text](url)` clickable links (URL must include a scheme, e.g. `https://`). Note `__underline__` intentionally differs from CommonMark (where `__` is bold). `\` escapes the next character. Unterminated delimiters render literally. A literal `\n` in CLI banner text becomes a line break — banners can span multiple lines (display is capped at 10 lines).

**Lists.** Consecutive lines that begin with a list marker render as a list block with table-like row spacing and a **shared marker gutter**, so every item's content left-aligns regardless of marker kind (bullets, numbers, and checkboxes in one run all line up). Supported markers:

- `- ` or `* ` → an unordered **bullet** (`•`).
- `1.`, `2.`, … (digits, a period, then a space) → an **ordered** item, rendered with the source number. A decimal like `1.5` (no space after the dot) stays plain text.
- `[x]`/`[X]` (checked) and `[ ]` (single space, unchecked) → a read-only **task-list checkbox**, drawn as a **native box** (rounded 2px corners; checked shows a green check on a faint green wash), not a plaintext glyph. A `- `/`* ` directly before a checkbox is the checkbox's marker, not a separate bullet (`- [x] done`). Checkboxes are display-only (no interactivity), and `[x](url)` is still a link (the `x` is link text). Checkboxes in **table cells** render the same native box. A checkbox that appears mid-paragraph in a wrapping (non-list) text line falls back to the `☑`/`☐` glyph.

**Separators.** A line of 3+ of the same `-`, `*`, or `_` (spaces allowed — `---`, `***`, `___`, `- - -`) is a **thematic break**, rendered as a full-width horizontal divider between the blocks above and below it (e.g. to separate a title, a table, and a trailing note). A `- `/`* ` bullet or `**bold**` on its own line is unaffected (they carry non-marker content or mixed characters). Each rule counts as one line toward the 10-line display cap.

Banners also support standard markdown pipe tables, rendered as an aligned grid with a bold header row: a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows. Separator cells may carry `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged body rows are padded/truncated to the header width. The separator row doesn't render; every other table row counts toward the 10-line display cap (a row still counts once no matter how many lines its cells wrap to). **Long cell text word-wraps** onto multiple lines and the row grows to fit, rather than truncating to one line — matching a normal markdown renderer. Column widths derive from the pane's current width, so the banner reflows live as the pane is resized and never blocks the pane from shrinking (even a long unbroken token breaks mid-string). A cell is capped at **3 wrapped lines** — a cell that would wrap further (e.g. a long unbroken string in a very narrow pane) is tail-truncated with an ellipsis on its last visible line, so one nasty cell can't blow up the banner height. A cell that contains a task-list checkbox stays a single line (its native box can't reflow around wrapping text), like list checkbox rows.

```bash
ghoztty +set-banner --target=dev "**Build status**\n| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |"
```

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev --clear
```

Processes can also set the banner from inside the pane via OSC escape sequence: `\033]7778;<text>\007` (empty text clears). The interactive equivalent is Cmd+R ("Set Pane Banner…", also in the command palette), which opens a multi-line editor for the focused pane's banner (Return inserts a newline, Cmd+Return saves, Escape cancels).

Banners are persisted per pane in the session-layout manifest (keyed to the stable pane id), so a session-persistence restore brings them back with their text intact — across app quit/relaunch/upgrade re-attach and across an agent-restart relaunch alike. `+list --json` reports each terminal pane's current banner in a `banner` field (absent when no banner is set), which is also the CLI way to read a banner back.

### `ghoztty +reload`

Reload a named **viewer pane** (see Viewer Panes below) in place — no
close/reopen. Website viewers re-fetch the page from origin (bypassing
caches); file viewers re-render the file preserving scroll position (they
already live-reload on their own, so this mainly matters for URL viewers).

```
ghoztty +reload --target=<name>
```

- `--target`: Named window or pane (or a pane id). Required. For a window
  target the reload applies to its focused pane.
- Targeting a terminal pane fails with `... is a terminal pane, nothing to
  reload` (exit 1), mirroring how terminal-only commands reject viewer panes.

```bash
ghoztty +split --target=dev --name=preview --view=http://localhost:3000
ghoztty +reload --target=preview
```

### `ghoztty +new-remote-window`

Open a terminal window whose shell runs on a remote machine via a `ghoztty-agent`
reached over TCP. Drives the same flow as the Cmd-Shift-N "New Remote Window" menu
action (dial the agent, build a remote surface, open the window), so the remote
path is scriptable/testable from the shell.

```
ghoztty +new-remote-window --host=<host> --port=<port> --working-directory=<path> --shell=<path> --command=<cmd>
```

- `--host`: Agent host (DNS name or literal IP). Required.
- `--port`: Agent TCP port. Required.
- `--working-directory`: Working directory ON THE REMOTE MACHINE for the new
  session. Overrides the machine's per-host default.
- `--shell`: Shell ON THE REMOTE MACHINE to run (e.g. `wsl.exe`,
  `powershell.exe`, `/bin/zsh`). Overrides the machine's per-host default.
- `--command`: Command to run in the remote session instead of an interactive
  shell. Runs through the resolved shell using its native convention (POSIX
  `-lic`, cmd `/c`, powershell/pwsh `-Command`, wsl `--`).

```bash
ghoztty +new-remote-window --host=127.0.0.1 --port=7777
ghoztty +new-remote-window --host=winbox --port=7777 --shell=wsl.exe --working-directory='C:\dev'
```

The remote session uses the remote machine's own default shell and working
directory (the local shell/pwd are NOT forwarded — they would not exist on a
different OS such as a Windows ConPTY agent) unless a **per-host default** or
an explicit flag says otherwise. Per-host defaults (default working directory
+ default shell per machine) are edited in the machine chooser (Cmd-Shift-N →
row `⋯` menu → "Host Settings…") and persist in UserDefaults keyed by relay
device id or `host:port`; explicit `--working-directory`/`--shell` flags
override them per window. New tabs/splits on a remote window use the per-host
default shell too (their cwd inherits from the parent pane).

### Naming

- `+new-window --target=<name>` registers a **window**
- `+split --name=<name>` registers a **pane**
- `+split --target`, `+close --target`, and `+send-keys --target` reference either kind

### Pane identity

Every pane has a **stable, ghoztty-owned pane id** (a UUID):

- Exported to the pane's processes as `$GHOZTTY_PANE_ID` (baked at spawn).
- Shown as the leaf `id` in `+list --json`.
- Accepted directly by every `--target`/`--name` (case-insensitive), with no
  prior registration or `+list` needed: `ghoztty +set-banner
  --target=$GHOZTTY_PANE_ID …` works from inside any local pane.
- Stable for the pane's whole life: persisted in the session-layout manifest and
  restored on app relaunch (session-persistence panes keep the same id AND the
  same baked env), preserved across remote reconnect swaps, and re-applied to
  the respawned shell when the agent relaunches a session after its own restart
  (the RELAUNCH carries the pane's env/TERM/argv).

Prefer the pane id over pid/tty matching for self-identification: pids and ttys
belong to the machine the process runs on and are meaningless for remote panes.
(`+list --tty=<tty>` still works for local panes as a fallback.)

### Instance addressability

An IPC command run inside a pane targets **the app instance that owns that
pane**, not whichever build the `ghoztty` binary on `$PATH` happens to be. Every
pane's env is baked with `$GHOZTTY_IPC_SOCKET` — the absolute path of its own
app's IPC socket — and the CLI prefers it over the compile-time
`ghostty[-debug]-<uid>.sock` derivation. So `ghoztty +split` run from a
debug-build pane splits the **debug** window even though `ghoztty` on `$PATH` is
the release binary (before this, it silently drove the release app).

- Baked on every pane path: plain local spawn, session-persistence agent panes
  (the agent replays the pane env on RELAUNCH), and remote panes — a remote
  pane's IPC still belongs to the *local* app.
- Absent or empty ⇒ today's derivation, so a CLI run from a plain non-Ghoztty
  shell is unchanged, as is a pane baked by an older app or agent.
- Override it (`GHOZTTY_IPC_SOCKET=<path> ghoztty +list`) to aim a single
  command at a specific instance.
- One resolution site each side: `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`)
  for the CLI, `IPCSocket.path` (Swift) for the server.

### Example: three-pane layout

```bash
ghoztty +new-window --target=ide --command="nvim ."
ghoztty +split --target=ide --name=term --direction=down --command=zsh
ghoztty +split --target=ide --name=logs --direction=right --command="tail -f app.log"
# read output from a pane
ghoztty +read --name=logs --lines=5
# teardown
ghoztty +close --target=logs
ghoztty +close --target=term
ghoztty +close --target=ide
```

## Viewer Panes

A pane (or a whole window) can render **content** instead of a terminal: a
markdown file, a plain text/code file, or a website. Viewers live in the
normal split tree — they resize, focus, zoom, close, and persist like any
pane. View-only, no editing.

```bash
ghoztty +new-window --view=README.md                 # viewer window
ghoztty +split --target=dev --name=doc --view=docs/design.md
ghoztty +split --pane=doc --direction=down --view=https://example.com
ghoztty +close --target=doc
```

- **Markdown** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdwn`): GitHub-style
  rendering via bundled markdown-it + highlight.js (offline, zero network) —
  headings, GFM tables, nested/task lists, fenced code with syntax
  highlighting, blockquotes, images (relative paths resolve against the
  file's directory), links. Light/dark follows the window appearance. Body
  text is set in the **system font** (SF Pro via `-apple-system`) and code in
  SF Mono, so a viewer reads as macOS content rather than a web page.
- **Table of contents** (markdown only, and only with two or more headings):
  a native card listing the document's headings, nested by level, with the
  section you are reading highlighted as you scroll. Clicking a row scrolls
  to it; the list scrolls independently when it is long. In a **wide pane**
  the card sits in a left gutter and the document column reflows beside it.
  In a **narrow pane** (< 720pt) the gutter would crowd the text, so the card
  becomes an overlay: the navigation bar stays pinned open and gains a
  contents button as its first item, which slides the card in and out. The
  switch follows the *pane* width live, so dragging a split divider reflows
  it. The card is the same glass card as the pane banner overlay (shared
  `GlassCardBackground`), opaque so document text never shows through it.
  Panel open/closed state is ephemeral — it does not survive a session
  restore, since restoring an overlay would hide the content it covers.
- **Text/code files** (anything else): syntax-highlighted by extension.
- **Websites** (`http://`/`https://`): the pane navigates there directly.
- **Links** in file viewers: http(s) opens the default browser; a relative
  `.md` link opens another viewer split; other local files open in their
  default app.
- **Live reload**: file viewers watch the file (including atomic saves) and
  re-render preserving scroll position.
- **Navigation chrome**: hovering the thin strip at a pane's top slides in a
  bar with back / forward / reload / **home** and an **editable address
  field** — in every mode, files included. Typing an `http(s)` address (or a
  bare `example.com`, completed omnibox-style) navigates the pane to the web;
  typing an absolute or `~` path points it back at a file. Back and forward
  reflect real history (disabled when there is none) and work across the
  file↔web boundary — going Back from a website re-renders the file. **Home**
  returns to the location the pane was originally opened with, which is
  remembered separately from where the user has navigated to (and both
  survive a session restore). Clicking into the address field selects the
  whole address; clicking again inside it just moves the caret.
- `--view=about:blank` opens a **blank browser pane**. The command palette's
  "Viewer: Open Browser Pane" does the same interactively and puts the caret
  straight in the address field — the equivalent of `+split --view=<url>` for
  when the URL is not known up front.
- Because any viewer can browse, `+list --json`'s `"url"` (and the session
  manifest) report where a pane currently IS, not where it was opened.
- Relative `--view` paths resolve against `--working-directory` if given,
  else the caller's cwd.
- `+list` marks viewer panes with a `view:` prefix (JSON: `"type": "viewer"`
  plus `"url"`); they auto-register names like terminal panes.
- `+read`/`+send-keys`/`+set-state`/`+set-banner` against a viewer fail with
  `... is a viewer pane, not a terminal` (exit 1). `+close` works normally
  and never prompts for viewers.
- Session persistence: viewer panes restore by re-opening their file/URL
  (terminals in the same window re-attach as usual); a missing file restores
  as an in-page error card.
- File → Open (or dragging onto the dock icon, or `open -a Ghoztty file.md`)
  opens `.md`-family files as a viewer window.

### Worktree feedback capture

When a viewer pane's content can be attributed to a **git worktree**, its
navigation bar gains a **feedback button** (labeled with the worktree's
basename, full path on hover) that opens a composer toolbar below the nav bar.
On send it writes a report — plus any pasted screenshots — into
`<worktree>/.feedback/new/` for an external watcher to drain (Ghoztty produces
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
  The button is **icon-only**, in the same 24pt square as the other chrome
  controls; the destination is on its tooltip and in the composer footer.
- **Composer.** A **pill** that grows with its content (one line up to ~6),
  with two **circular buttons inside its trailing edge**: `+` takes an
  interactive screen snapshot (`screencapture -i -o` to a temp file — never
  `-c`, which would clobber the user's clipboard), and `↑` sends. `Enter`
  inserts a newline, `Cmd-Enter` sends, `Escape` closes.
  Pasting a screenshot inserts an **`[Image #N]` chip** — one atomic
  `NSTextAttachment` (a single `U+FFFC` character), so it selects, copies, and
  deletes (one Backspace) as a unit. A **thumbnail carousel** below the input
  mirrors the chips; clicking a chip scrolls to its thumbnail and vice versa.
  **Chip numbers are stable, not positional** — deleting `[Image #2]` leaves
  the sequence 1, 3 in both the text and the carousel (never renumbered), so a
  number always points at the same image. Composer contents survive
  toggling the toolbar closed/open and a detach/undo (they live on the pane,
  not the toolbar).

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
  <worktree>/.feedback/new/<timestamp>-<suffix>/
      report.json
      images/image-1.png
  ```

  The whole folder is built under `.feedback/.staging/` and moved into place
  with a single **atomic `rename`** (same filesystem), so a watcher sees either
  nothing or a complete report with every image already present.
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

## Session Persistence

Terminal processes can be made independent of the GUI app so they survive app
crashes, quits, and binary upgrades (and relaunch across reboots / agent
crashes). It is **on by default** (disable with `session-persistence = off`).

- `session-persistence = off|on` (macOS, default `on`). When `on`, new local
  windows/tabs/splits run their shell under the local `ghoztty-agent` (found or
  spawned on demand) instead of directly under the app process, so the child
  processes outlive the app. On next launch the app re-attaches: layout, split
  ratios, titles, working dirs, and gap-filled scrollback come back with the
  **same PIDs** (no restart) as long as the agent stayed alive.
- `session-relaunch = auto|prompt` (default `auto`). Only matters across an
  **agent** restart (reboot / agent upgrade), where the child is gone but its
  metadata was materialized from disk as a relaunchable tombstone. `auto`
  respawns the recorded command in-place with a `--- session restarted ---`
  divider; `prompt` leaves the pane in its exited state for the user to decide.

Session lifecycle: a process DIES when the user closes its pane/tab/window (or
`+close`s it — the CLOSE lands when the close's undo window expires), when the
shell itself exits, or when the agent dies (children then relaunch as
tombstones per `session-relaunch`). It SURVIVES app quit/crash/upgrade (quit
never prompts for persistent windows — their sessions re-attach on relaunch).
E2E: `scripts/e2e/session-persistence.py` (incl. `--winsize` for re-attach
PTY-geometry integrity).

The agent owns the PTYs, keeps a per-session output ring (2 MB default;
snapshotted to disk for reboot scrollback), persists session metadata to
`sessions.json`, and is packaged as a per-user LaunchAgent so it comes back
after a crash/reboot. The app dials it over a 0600 AF_UNIX socket
(`~/.config/ghoztty/local-agent[-debug]/agent.sock`) with a same-uid peercred
check. Use `+sessions` (above) to enumerate live sessions directly from the
agent, even when the app is not running. Design + measured E2E results:
`docs/design/session-persistence.md`; E2E harness: `scripts/e2e/session-persistence.py`.

Cross-machine session *move* (browse another machine's live sessions from the
Cmd-Shift-N chooser and resume them locally over the relay) is **scoped but not
yet built** — see tasks T16–T18 in `docs/design/session-persistence-tasks.json`.

### Agent contract & upgrade compatibility

The `ghoztty-agent` outlives the app on purpose (per-user LaunchAgent; survives
quit/crash/upgrade). The direct consequence: **a running agent is frequently a
DIFFERENT build than the app talking to it** — an app upgrade replaces the app
binary while the old agent process keeps running with every PTY attached. The
app↔agent wire contract is therefore a **compatibility boundary.** Forward
compatibility across it is the **default and strongly preferred** path; a
breaking change is allowed but only as a *conscious* decision routed through the
mandatory agent-update process (below), never as an accident. What is never
acceptable is an *unhandled* skew — garbled output, a wedged socket, or a crash.
Treat this boundary with the same care as an on-disk format or a public API.

Rules for any change to the agent↔app protocol (messages, fields, framing, the
ring/snapshot/gap-fill replay, HELLO handshake):

- **Old agent + new app MUST keep working, and new agent + old app MUST keep
  working.** Neither side may assume the peer is its own build. A skew must
  degrade to reduced function, never to garbled output, a wedged socket, or a
  crash. (The 1.14.0 re-attach corruption — new app replaying an old agent's
  scrollback into smeared, non-interactive panes — is exactly the failure this
  rule exists to prevent.)
- **Evolve additively.** New messages and new fields only. Never change the
  meaning, type, or framing of an existing message or field, and never remove
  one that an older peer still sends or expects. Readers ignore unknown fields
  and tolerate absent ones (fall back, don't fail). A field that goes missing
  because the peer is older must degrade gracefully — the way agent-side
  pid/tty already reports null to an app that doesn't understand it.
- **Detect capability at runtime — never at compile time.** Attach begins with
  a **HELLO handshake** that exchanges a protocol/capability version so each
  side negotiates behavior from what the peer *actually* advertises, not from
  what this build happens to ship. Gate every new behavior on the negotiated
  capability, and document each protocol version and what it added in the agent
  protocol source so the compatibility matrix is checkable at runtime and in
  review.
- **Breaking changes are allowed — deliberately, never accidentally.** Forward
  compatibility is the default because it's the cheapest path (no disruption),
  but a break is a legitimate tool when additive evolution would be worse. What
  makes a break acceptable is that it is *conscious* and *backed by the
  mandatory agent-update process* — not that it's forbidden. When you break the
  contract: bump the protocol version, and on an incompatible skew the app must
  NOT replay across it. Instead the mandatory-update mechanism takes over:
  - **Prefer a lazy, non-destructive agent upgrade.** Carry sessions across by
    upgrading the agent when it is safe — on idle, or as each session naturally
    closes — draining/snapshotting and resuming so no work is lost, then proceed
    with the app upgrade transparently. This is what makes most breaks painless.
  - **When a session cannot be carried across**, show a **mandatory, explicit
    confirmation before resetting**: *"Upgrading will reset all windows.
    Continue?"* Never silently reset live sessions, and never silently replay
    across a version the handshake flagged as incompatible.

  The mandatory-update process is the safety net that makes breaking changes
  survivable; the HELLO handshake is what lets us detect when we need it. Build
  and keep both robust, and a breaking change becomes a conscious, bounded cost
  rather than a corrupted-session incident.

Design + status: `docs/design/session-persistence.md`.

## Build & Test

```bash
zig build -Doptimize=Debug
```

**NEVER modify, replace, copy over, or touch `/Applications/Ghoztty.app` in any way.** The installed app is the user's primary terminal. Always test with the debug build at `zig-out/Ghoztty-Debug.app`. The debug build uses a separate socket (`ghostty-debug-<uid>.sock`) and a separate bundle identifier so it can run alongside the release app.

## Architecture

- **Zig core** (`src/`): terminal emulation, input handling, CLI commands, IPC client
- **Swift macOS app** (`macos/`): SwiftUI frontend, IPC server, split tree layout
- Split panes use a binary tree (`SplitTree`) with a ratio (0.0–1.0) per split node
- IPC uses JSON messages over a Unix domain socket at `$TMPDIR/ghostty[-debug]-<uid>.sock`, overridden per pane by `$GHOZTTY_IPC_SOCKET` (see Instance addressability)
