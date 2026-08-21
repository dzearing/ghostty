# Ghoztty

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds CLI-driven window management for AI agents and automation.

## CLI Window Management

IPC commands communicate with a running Ghoztty instance over a Unix domain socket. All commands are idempotent — named targets that already exist are focused instead of recreated.

### `ghoztty +new-window`

Create or focus a terminal window. Auto-launches Ghoztty if no instance is running.

```
ghoztty +new-window --target=<name> --working-directory=<path> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --no-activate -e <args...>
```

- `--shell`: Shell to use for `--command`/`--split-command`, invoked with `-lic` so profile is loaded. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`.
- `--view`: Open a window whose single pane is a **viewer** (see Viewer Panes below) instead of a terminal — a file (markdown, HTML rendered as a live page, or code), a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes). Mutually exclusive with `--command`/`-e`.
- `--title`: Set the **window title**. A window title pins the titlebar — it wins over any tab or pane title and survives pane focus changes and shell OSC title updates — until cleared. The titlebar falls back to window title → active tab's title → active pane's title. Interactive equivalents: Cmd+Shift+R ("Change Window Title", also sets/clears it), plus separate "Change Tab Title" and "Change Pane Title" commands in the menu and command palette. `ghoztty +rename --target=<name> --title=<title>` changes it later (`--title=""` clears the pin).

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --working-directory=<path> -e <args...>
```

- `--direction`: Split direction. Default: `right`.
- `--target`: Named window to split in (default: most recently focused).
- `--name`: Register the new pane with a name for later targeting.
- `--view`: Open a **viewer** pane (see Viewer Panes below) instead of a terminal — a file (markdown, HTML rendered as a live page, or code), a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes). Mutually exclusive with `--command`/`-e`. Works with `--pane` targeting, including splitting off an existing viewer pane.

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
ghoztty +send-keys --target=<name> [flags] <text|key>...
```

> **To submit, end the text with `\n`** — `ghoztty +send-keys --target=t "prompt\n"`.
> (`--enter`, or a separate `Enter` argument, do the same thing. Use one, not
> two — they stack, and two of them submit twice.)

- `--target`: Named pane or window to send input to. Required.
- `--enter`: Press Enter after the text. Same as a trailing `\n` or a trailing `Enter` argument. On its own, with no text, it just presses Enter.
- `--when-idle`: Poll the target pane's recent output every 500ms until it no longer contains `esc to interrupt` (Claude Code's busy marker) before sending; sends anyway after `--idle-timeout=<seconds>` (default 30) or if the pane can't be read.
- Positional arguments are text or key names, written to the PTY in order.
- Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term --enter "ls -la"
ghoztty +send-keys --target=term C-c
```

**A trailing newline is a keypress; an interior one is content.** The trailing run of `\n`/`\r` is peeled off the text and delivered as that many Enter presses, so `"a\nb\n"` pastes two lines and then submits. This runs after escape processing, so `\n` written as the two-character escape and a real newline byte behave identically. The accepted cost: there is no way to paste text ending in a literal newline without submitting — a trailing newline in a paste means "commit" essentially always, and a program that has not enabled bracketed paste sees `\r` mapped back to `\n` by the tty's `ICRNL` anyway.

**Any unknown `--flag` is a hard error** (exit 1), naming the three submit spellings. `--press-enter` used to become a text positional and get typed into the pane at exit 0, which is how agents got this wrong without noticing. Single-dash arguments (`-la`, `-p`) are ordinary text. To send literal text starting with `--`, put it after a bare `--`, which stops flag parsing but not key notation:

```bash
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

**Text and keys stay distinguishable.** Argument boundaries survive all the way to the write. When a call mixes text with keys, adjacent arguments of the same kind merge into a run, and each **text** run is written to the pane as a **bracketed paste** (`ESC[200~` … `ESC[201~`) while each **key** run is written bare, outside the frame.

This is what makes `+send-keys --target=t "some message" Enter` actually submit. Flattened into one burst of bytes ending in `\r`, a TUI's paste detection reads that `\r` as a newline inside pasted text — correctly, since that is exactly how a real multi-line paste looks — and the message sits unsent in the composer. Framing states which bytes were pasted, so the `\r` after the closing fencepost is unambiguously a keypress. It is a property of the bytes, not of their timing, so there is no delay anywhere in the path.

Two consequences worth knowing:

- A text run is framed **in a single PTY write**. Splitting the frame across writes lets the opening fencepost land in its own `read()` on the far side, and a receiver that sees a lone `ESC[200~` does not reliably associate it with the content after it (measured against Claude Code, which then falls back to its length heuristic and swallows the `\r` again).
- Framing only happens when the program running in the pane has **enabled bracketed paste** (DEC mode 2004) — which every modern TUI and interactive shell does. A pane running something that has not (`cat`, a shell script's `read`) gets the bytes verbatim, so nothing can inject literal `[200~` junk into a program that would not understand it. Text containing `ESC[201~` is also sent unframed, rather than emitting a frame that would close early.

Single-kind calls — `"text"` on its own, `Enter` on its own, `C-c` on its own — have no boundary to disambiguate and are sent byte-for-byte as they always were.

### `ghoztty +set-state`

Set the activity state of a named window or pane. The state is aggregated across all panes in a window (priority: `needs_input` > `busy` > `idle`) and shown as a title suffix and custom `AXWindowActivityState` accessibility attribute.

`idle`/`busy`/`needs_input` are the **machine tokens** — the vocabulary of this flag, of the OSC 7777 payload, and of `AXWindowActivityState`. They are a public API (hooks call the CLI, external tools like ztabby read the attribute) and do not change for readability. The **title suffix** shows a human label instead, and the two differ for one state: `needs_input` renders as `(question)`. Consumers must read the accessibility attribute rather than parsing the title.

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

**An agent should not set the state of its own pane.** The installed hooks own
it (`macos/Resources/Ghoztty/hooks/ghoztty-activity-state.sh`, the single owner
of the `needs_input` > `busy` > `idle` ordering), including holding the pane
`busy` while background subagents outlive the main loop — `Stop` fires when the
main loop goes quiet, not when the work ends. Live subagents are tracked as one
marker file each under `/tmp/ghoztty-<runtime>-agents-<session_id>/`, recovered
either by the owner pid baked into the filename or by a missed heartbeat past
`GHOZTTY_AGENT_STALE_MIN` minutes (default 30, which must exceed the longest
single *tool call*). `+set-state` is for *other* panes. Tests:
`scripts/test-activity-state.sh`.

Wired for Claude Code; Copilot CLI gets only the session-start sweep and the
settle, because its event vocabulary for tool/subagent/permission hooks is not
documented (see `CopilotHookSpec`).

### `ghoztty +set-banner`

Set or clear the sticky banner of a named pane or window. The banner is a native overlay rendered above the terminal content of a pane — it persists (survives scrolling, screen clears, and content updates) until changed or cleared. Setting a banner on a window target applies it to that window's focused pane (banners are per-pane).

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

- `--target`: Named pane or window. Required.
- `--clear`: Remove the banner (empty text does the same).
- All other arguments are treated as the banner text (multiple are joined with spaces).

Banner text supports a small markdown subset: `**bold**`, `*italic*` or `_italic_`, `__underline__`, `` `code` ``, and `[text](url)` clickable links (URL must include a scheme, e.g. `https://`). Note `__underline__` intentionally differs from CommonMark (where `__` is bold). `\` escapes the next character. Unterminated delimiters render literally. A literal `\n` in CLI banner text becomes a line break — banners can span multiple lines (display is capped at 10 lines).

**Autolinking.** Bare URLs and bare file paths become clickable without `[text](url)` syntax. A URL must carry a scheme — only `http://` and `https://` linkify, never a bare `www.example.com` or `config.io`, so prose is never falsely linked. A file path must start with `/`, `~/`, `./`, or `../`; the sigil is the whole signal (there is no filesystem check), which is why a bare relative `macos/Sources/Foo.swift` stays plain text. `~/` expands to the home directory and `./`/`../` resolve against **the pane's current working directory** at render time — a dot-relative path in a pane with no known cwd stays plain text rather than resolving against a guess. Trailing sentence punctuation stays outside the link (`See https://x.com.` links `https://x.com`), while brackets balanced *inside* the link are kept (`…/Foo_(bar)`). Autolinking never fires inside a `` `code` `` span, after a `\` escape, or inside an explicit `[label](url)` — the explicit link always owns its whole label.

**Link clicks.** A plain click hands the link *out* of Ghoztty; the modifiers bring it back in. Cmd opens a **viewer side pane** for either kind of link, and Cmd-Shift gives the link a surface of its own.

| | plain click | Cmd | Cmd-Shift |
|---|---|---|---|
| **URL** | default browser | side pane | new Ghoztty window |
| **file path** | reveal in Finder | side pane | open with default app |

A URL goes to the real browser by default because Ghoztty's `WKWebView` keeps its own cookie store with no relationship to Safari/Chrome — anything behind a login renders logged-out in a viewer pane, and OAuth sign-in never completes. A file path is only *revealed*, never opened, so a click can't launch whatever app claims the extension. The right-click menu offers all of them (its first item is by contract the left-click default) plus Copy Link / Copy Path.

**This table is not banner-only.** It is `BannerLinkOpener`, and **viewer panes use the
same one** — for the links a viewer hands out (see Viewer Panes → Links) and for the
right-click menu on any link in a viewer page. One modifier scheme, one menu, one place
the ordering contract lives; a second copy is the drift the type exists to prevent. The
opener reaches its surface through a `LinkAnchor` (the terminal `SurfaceView` for a
banner, the `ViewerView` for a viewer pane), which is what supplies the window's
controller, the pane a side split anchors beside, and the origin directory a viewer
opened from the link inherits.

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

Processes can also set the banner from inside the pane via OSC escape sequence: `\033]7778;<text>\007` (empty text clears). The interactive equivalent is Cmd+R ("Set Pane Banner…", also in the command palette), which opens a multi-line editor for the focused pane's banner (Return inserts a newline, Cmd+Return saves, Escape cancels). Cmd+R only reaches this while a **terminal** pane is focused — a focused viewer pane takes Cmd+R for reload (see Viewer Panes).

Banners are persisted per pane in the session-layout manifest (keyed to the stable pane id), so a session-persistence restore brings them back with their text intact — across app quit/relaunch/upgrade re-attach and across an agent-restart relaunch alike. `+list --json` reports each terminal pane's current banner in a `banner` field (absent when no banner is set), which is also the CLI way to read a banner back.

### `ghoztty +reload`

Reload a named **viewer pane** (see Viewer Panes below) in place — no
close/reopen. Website viewers re-fetch the page from origin (bypassing
caches); file viewers re-render the file preserving scroll position (they
already live-reload on their own, so this mainly matters for URL viewers —
and for an **HTML** pane, whose save-watcher covers the HTML file but not the
sibling CSS/JS it pulls in, which this bypasses the cache for);
**diff viewers re-run their git command**, picking up commits, staging, and
edits, and keeping the open file and its scroll position.

```
ghoztty +reload --target=<name>
```

- `--target`: Named window or pane (or a pane id). Required. For a window
  target the reload applies to its focused pane.
- Targeting a terminal pane fails with `... is a terminal pane, nothing to
  reload` (exit 1), mirroring how terminal-only commands reject viewer panes.
- Interactive equivalent: **Cmd+R** while a viewer pane is focused (see
  Viewer Panes → Keyboard).

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

A window opened without an explicit `--target=` (Cmd-N, or a bare
`+new-window`) still gets an **auto name** — `window-1`, `window-2`, … — which
is exported to its panes as `$GHOZTTY_WINDOW_NAME` and shown as `target` in
`+list`. That name is targetable immediately: `resolveTarget` falls back to
scanning live windows by name, so no `+list` is needed first. (It used to be
registry-only, so every `--target=window-N` failed with `not found in
registry` until something walked the tree — invisibly, for the many callers
that discard stderr.)

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

## The `ghoztty://` URL scheme

A **link** can raise a Ghoztty window or pane. This is the piece that makes a
generated document (a worktree dashboard, a status report) able to say "jump to
that terminal" — from a browser, from a doc rendered in a viewer pane, or from
a pane banner.

```
ghoztty://focus/<target>
```

One verb, one shape. `<target>` is percent-decoded and passed to
`IPCServer.resolveTarget` — the same resolver `--target` uses, so there is one
naming system, not two: a registered window name, an auto `window-N`, a
registered pane name, or a pane id (`$GHOZTTY_PANE_ID`, case-insensitive).
Everything after the verb is ONE target, so a name containing `/` survives
encoded (`focus/feat%2Flogin`) or not (`focus/feat/login`). The path form is
canonical over `ghoztty://<target>` (nowhere to put a verb) and over
`ghoztty://focus?target=…` (a second escaping context for no gain). Parsing
(`GhozttyURLScheme.parse`) is strict: unknown verb, empty target, and bare
`ghoztty://<name>` all yield nothing rather than a lenient guess.

**Focus is the only capability, and that is the design, not a first
increment.** A registered URL scheme is reachable by any web page the user
visits — no prompt, no gesture beyond a click, no same-origin check, no way to
know who asked. Everything the IPC socket exposes is safe there only because a
0600 unix socket is reachable only by code already running as the user; none of
that holds for a link. A scheme that could spawn a shell (`--command`), type
into a pane (`+send-keys`), or open a viewer would be remote code execution
behind an `<a href>`. Raising an already-existing window is the one verb whose
worst case is a nuisance. The parser reads a verb rather than hardcoding one
shape so a future verb *could* be added — but wanting a second verb to make
something work is a signal to stop and ask, not to add one.

Consequences, all deliberate:

- **The debug build registers `ghoztty-debug://`**, the release builds
  `ghoztty://` (`CFBundleURLTypes` ← the `GHOZTTY_URL_SCHEME` build setting,
  per Xcode configuration) — the same split as the bundle id and the IPC
  socket. Otherwise LaunchServices picks between them nondeterministically and
  the user's links start landing in a debug build. Verified with
  `NSWorkspace.urlForApplication(toOpen:)`.
- **Both spellings parse in both builds.** Links clicked *inside* Ghoztty are
  short-circuited in process and never reach LaunchServices, so a document that
  hardcodes `ghoztty://` still focuses the right pane when a debug build is
  rendering it.
- **A link that resolves to nothing says so** (`GhozttyURLScheme.Failure`): a
  warning naming the target for `targetNotFound`, or naming the URL plus the
  one supported form for `unsupportedLink`. A click that appears to do nothing
  is indistinguishable from a broken app, and both failures are ordinary (the
  window was closed; the document predates this build). What failure never does
  is *act*: no window is created and no "closest" window is focused as a
  consolation. Presentation is **coalesced** behind `isPresentingFailure` so a
  burst — any page can fire a scheme, and `application(_:open:)` takes an
  array — is one dialog, not one per link. A URL that isn't ours at all is
  ignored silently; nobody clicked a Ghoztty link. The wording lives on
  `Failure` rather than in the presenter so it is testable.
- **App not running:** macOS launches the app for a registered scheme (we can't
  decline), and the registry is empty, so the focus resolves to nothing and
  reports that. The normal `initial-window` behavior still applies — that
  belongs to *launching Ghoztty*, exactly as `open -a Ghoztty` does, not to the
  focus verb, which creates nothing. Suppressing it would leave a windowless
  app that reads as broken in the one case where the link could never have
  worked.
- **Viewer panes** intercept `ghoztty://` at the top of `decidePolicyFor`,
  ahead of the live-page passthrough AND of the cross-origin external-link
  check (WebKit cannot load the scheme, so an allowed navigation is a dead
  click, and a focus link is not "content on another site" to hand to a
  browser). A `target="_blank"` focus link resolves
  to `PopupDestination.ghozttyCommand` instead of falling through to
  "non-web scheme ⇒ open a Ghoztty window", which is how it used to create a
  viewer window pointed at the command string.
- **Rendered markdown** needs `viewer.js` to widen DOMPurify's
  `ALLOWED_URI_REGEXP` by exactly these two schemes. markdown-it keeps a
  `ghoztty://` href, and the sanitizer then stripped it — the link rendered as
  dead text. Keep the regex in sync when the vendored DOMPurify is bumped.
- **Banner links** ignore the Cmd / Cmd-Shift modifier scheme
  (`BannerLinkOpener.Action.runGhozttyCommand`): the link names a window, not
  content, so there is nothing to open in a side pane or a new window. The
  right-click menu is **Focus in Ghoztty** + **Copy Link**. A focus link
  right-clicked in a **viewer page** gets that same two-item menu, since the
  viewer builds its menu from the same `BannerLinkOpener`.

Entry points: `application(_:open:)` (`AppDelegate.swift`) for LaunchServices,
`ViewerView` for viewer link clicks, popups, and the viewer link menu,
`BannerLinkOpener` for banner clicks. All of them funnel into
`GhozttyURLScheme.handle` → `IPCServer.focusTarget`. Tests:
`GhozttyURLSchemeTests`, plus the `ghoztty`-scheme cases in
`BannerLinkOpenerTests` and `ViewerPopupTests`.

## Viewer Panes

A pane (or a whole window) can render **content** instead of a terminal: a
markdown file, an HTML file (as a live page), a plain text/code file, a
website, or a **git diff**. Viewers live in the normal split tree — they
resize, focus, zoom, close, and persist like any pane. View-only, no editing.

```bash
ghoztty +new-window --view=README.md                 # viewer window
ghoztty +split --target=dev --name=doc --view=docs/design.md
ghoztty +split --target=dev --name=mock --view=mock/index.html   # a live page
ghoztty +split --pane=doc --direction=down --view=https://example.com
ghoztty +split --target=dev --name=diff --view=git-status:   # a git diff
ghoztty +close --target=doc
```

- **Markdown** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdwn`): GitHub-style
  rendering via bundled markdown-it + highlight.js (offline, zero network) —
  headings, GFM tables, nested/task lists, fenced code with syntax
  highlighting, blockquotes, images (relative paths resolve against the
  file's directory), links. Light/dark follows the window appearance. Body
  text is set in the **system font** (SF Pro via `-apple-system`) and code in
  SF Mono, so a viewer reads as macOS content rather than a web page.
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
- **HTML files** (`.html`, `.htm`): loaded into the web view as a **live
  page**, never as highlighted source. Its own CSS, JS, images, and fonts run,
  so a scaffolded mock or prototype is viewable straight from disk —
  `--view=mock/index.html` instead of standing up a `python3 -m http.server`
  first. The web view is granted read access to the file's **own directory**
  (recursively), which is what makes relative assets resolve; a page reaching
  UP out of its folder (`../shared/app.css`) is the deliberate cost of keeping
  that grant narrow — put shared assets under the page's directory, or serve
  the project over http. Rendering is unconditional: there is no source-view
  toggle. Because the page is the document, an HTML pane is navigable like a
  website — its links follow **in the pane** for anything inside that same
  grant, exactly as they would if the folder were hosted (Links, below, is the
  one exception) — and Back/Forward cross into and out of it. A file
  that cannot be opened shows the usual in-page error card.
- **Text/code files** (anything else): syntax-highlighted by extension.
- **Websites** (`http://`/`https://`): the pane navigates there directly.
- **Git diffs** (`git-status:` / `git-diff:<revspec>`): see Git diff panes.
- **Links.** Every viewer kind now hands a link that leads *out* of what the
  pane is showing to the same place a banner link goes (see Banners → Link
  clicks: plain click to the system, Cmd to a side pane, Cmd-Shift to a surface
  of its own), and **right-clicking any link gives the same menu** —
  `BannerLinkOpener`, adopted whole, not a viewer copy of it.
  - In **markdown/code** viewers (unchanged): http(s) opens the default browser;
    a relative `.md` or `.html` link opens another viewer split (both are things
    a viewer renders); other local files open in their default app.
  - In **live-page** viewers (a website, a local HTML file) a link is followed
    in the pane unless it is **cross-origin**, in which case a plain click
    leaves for the browser. This is what makes an authenticated site work: the
    `WKWebView`'s cookie store is Ghoztty's own, so a hop out to `github.com`
    renders logged-out here.
  - **"Origin" here is deliberately not the web platform's.** That one decides
    what a *script* may read; this one decides where a *person* wants a page to
    open (`ViewerView.isExternalLivePageLink`):
    **http(s)** is same-origin on the same **host** + the same **port as
    written** — the scheme is excluded so an `http`→`https` upgrade stays in the
    pane, and the port is included because `localhost:3000` → `localhost:5173`
    is a different dev server. A subdomain is a different host, so external.
    **`file://`** is same-origin inside the page's own directory, recursively —
    exactly the read grant the HTML bullet describes, so a mock clicks through
    its own pages and a link reaching UP out of the folder (which this pane
    could never load) stops being a dead click. Existence is not checked: a
    broken sibling link is the page's own 404, not Finder's problem.
    **Across the two** (a local mock linking to a website, a dev server linking
    to a `file://` path) there is no shared origin, so: external.
    **Every other scheme** — `javascript:`, `data:`, `blob:`, `about:`,
    `mailto:` — is untouched and followed in the pane. `javascript:` is ordinary
    page machinery, and handing an arbitrary scheme to `NSWorkspace` would
    resolve it to whatever handler is registered.
  - Only a **user's click on a main-frame link** (`.linkActivated`) is ever
    routed. A page's own redirects, form posts, script navigations, iframe
    loads, and subresource fetches are the page's business and pass through.
  - **The right-click menu** is Ghoztty's, on every page including ones we do
    not control. `src/viewer/links.js` is a `WKUserScript` — for the same reason
    `selection.js` is one: `viewer.js` is a `<script src>` in `viewer.html` and
    only ever runs on the bundled template, which would have left a website's
    links with WebKit's menu and the template's with ours. The script does
    nothing but decide whether the click landed on a link Ghoztty has actions
    for, `preventDefault()` if so, and report the href; the menu itself is
    native and pops up at the **pointer** (the click's page coordinates are CSS
    pixels inside a view that may be zoomed and pinch-magnified). It runs in
    **all frames**, unlike `selection.js`, precisely because it needs no page
    coordinates. It **declines** — leaving WebKit's own menu exactly as it is
    today — for a same-document `#fragment`, for a click inside the user's
    current selection (Copy / Look Up must survive), for `mailto:`/`javascript:`
    and other schemes with no Ghoztty action, and whenever the native bridge is
    missing. A relative template link (`ghoztty-viewer://…`) is resolved back to
    the file it names, so the menu offers file actions; a template link to a
    missing file gets no menu, matching a left-click on it doing nothing.
- **Links that open a new surface** in a website viewer — `target="_blank"` or
  `window.open()` — go to the **system default browser**, not a new Ghoztty
  window, for the same cookie-store reason banner URLs do. Same-pane
  navigation is untouched: a website viewer follows ordinary links in place.
  **Cmd-click** keeps the popup in Ghoztty as its own viewer window (honoring
  the size the opener asked for), and so does a popup the browser can't be
  handed — a bare `window.open()` with no URL, or a non-web scheme. The
  tradeoff: a popup that lands in the browser can't `window.close()` itself
  back to the Ghoztty page that opened it, so an OAuth flow finishes in the
  browser. That flow wasn't authenticating in Ghoztty anyway.
  **Cmd here means a new window, not a side pane** — deliberately out of step
  with the Link clicks table above, and left that way. `window.open()` is a
  request for a *window*; the code honors the `width=`/`height=` the opener
  asked for, and a sign-in popup crammed into a split is not what the page or
  the user meant. Cmd on an ordinary link (which asks for no such thing) still
  means a side pane.
- **Live reload**: file viewers watch the file (including atomic saves) and
  re-render preserving scroll position — an HTML pane re-fetches the page from
  disk, and WebKit restores the scroll offset across it, so a save does not
  throw you back to the top. Only the viewed file is watched: editing a
  sibling `style.css` does not trigger a reload, and a saved HTML file may
  still serve that stylesheet from WebKit's memory cache. `+reload`/Cmd+R
  bypasses the cache (`reloadFromOrigin`) and is the way to pick up a changed
  subresource.
- **Navigation chrome**: every mode gets a bar with back / forward / reload /
  **home** and an **editable address field**; what differs is whether it is
  always there. A **live page** — a website, or a local HTML file the web view
  renders as one — **pins it open**: that is something you navigate, so the
  address and the history controls are part of using it, and a blank browser
  pane is nothing but its address field. A **markdown or code** viewer is a
  reading surface whose address rarely changes, so it keeps the **hover peek**:
  the bar slides in when the mouse reaches the thin strip at the pane's top and
  auto-hides after inactivity. The pin follows the pane's CURRENT mode, not the
  location it was opened with — a markdown pane that browses to a website gains
  the pinned bar, and Back to the file hands it back to the hover timer. Either
  way a visible bar **reserves** its space (the page is inset below it, never
  covered), so a pinned pane's content is laid out below the bar from the first
  frame. (A diff pane and the compact side-panel layout pin it too, for their
  own reasons — see Git diff panes and Table of contents.) Typing an `http(s)`
  address (or a bare `example.com`, completed omnibox-style) navigates the pane
  to the web; typing an absolute or `~` path points it back at a file. Back and
  forward reflect real history (disabled when there is none) and work across
  the file↔web boundary — going Back from a website re-renders the file.
  **Home** returns to the location the pane was originally opened with, which
  is remembered separately from where the user has navigated to (and both
  survive a session restore). Clicking into the address field selects the whole
  address; clicking again inside it just moves the caret.
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

### Git diff panes

`--view=git-status:` / `--view=git-diff:<revspec>` opens a pane that renders a
git diff: a native file tree on the left, traditional red/green
syntax-highlighted hunks on the right, and next/previous-change +
unified⇄side-by-side controls in the nav bar.

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
- **Live**: a `git-status:` pane re-checks the working tree every 2s and
  updates only when the file list actually moved, so an edit or a `git add` in
  another pane shows up without a reload and without a flicker. A commit or a
  range is a fixed pair of trees and is not polled.
- The nav bar **stays pinned open** in a diff pane (it carries the change and
  layout controls, and shows the revspec) — one of several pinned cases, along
  with live pages and the compact side-panel layout (see Navigation chrome).

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
  <worktree>/temp/feedback/new/<timestamp>-<suffix>/
      report.json
      images/image-1.png
  ```

  The whole folder is built under `temp/feedback/.staging/` and moved into place
  with a single **atomic `rename`** (same filesystem), so a watcher sees either
  nothing or a complete report with every image already present. Promoting one
  to an `in-progress/` queue is likewise a single `mv` — image paths in the
  report are folder-relative, so they survive the move.
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
- `session-relaunch = restore|rerun|prompt` (default `restore`). Only matters
  across an **agent** restart (reboot / agent upgrade), where the child is gone
  but its metadata was materialized from disk as a relaunchable tombstone.
  - `restore` (default): the pane comes back as a **plain login shell in the
    session's recorded working directory**, under a
    `--- previous session was lost; new shell in its working directory ---`
    notice. The recorded command is **not** re-run. This is what makes a reboot
    safe to do: a `/wt` window opened with `--command="cl …"` used to come back
    by starting a brand-new Claude Code session, silently, in every pane.
  - `rerun`: re-execute the recorded command in place with a
    `--- session restarted ---` divider — the old `auto`, kept as an explicit
    opt-in for panes whose command is cheap and idempotent.
  - `prompt`: leave the pane in its exited state for the user to decide; the
    consenting keystroke does a `rerun`.

  The policy lives entirely client-side. `RELAUNCH` carries no argv, but the
  agent's synthesized relaunch OPEN already drops the *recorded* command
  whenever the viewer supplies `Relaunch.argv` — so `restore` just sends a
  `<shell> -li` argv and the agent's own recorded `cwd` does the rest. No wire
  change; an agent too old to honor those fields degrades to `rerun`.

  **The recorded cwd is `OPEN.cwd`, recorded at spawn.** The agent used to never
  write `Session.cwd` at all (only `materialize` set it, reading the field back
  off disk), so it was permanently null and every reboot-floor respawn — this
  policy and the old re-run alike — landed in whatever cwd the *agent* happened
  to have, which for a launchd-restarted agent is arbitrary. `handleOpen` now
  records it. Two limits remain, both benign: it is the **start** directory (the
  agent never re-samples the shell's live cwd, so a `cd`-ed shell comes back at
  the root it started in), and a bare `+new-window`/`+split` over IPC with no
  `--working-directory` still records nothing — GUI windows, tabs, and splits
  all inherit a cwd (`TerminalController.remoteWorkingDirectory`), and `/wt`
  passes one explicitly, so real windows have it.

  **Restoring scrollback also restores VT modes**, and the program that owned
  them is dead. `termio/Remote.zig`'s `replay_mode_reset` undoes them: mouse
  tracking above all (a dead TUI's `ESC[?1003h` makes a plain zsh read pointer
  motion as typed input — `zsh: command not found: 30M35`), plus bracketed
  paste, focus reporting, cursor keys/keypad, autowrap, cursor visibility, and
  SGR. It is **mode state only** — no `RIS`, and deliberately no alt-screen /
  origin / scroll-region reset, because ghostty applies those unconditionally
  (cursor restore, erase, home) and they would land the fresh prompt on top of
  the restored output. It is **not** applied on the ordinary alive re-attach:
  there the child still runs and still owns those modes.

  **The notice and the reset travel in the stream, not as a local print**
  (`RELAUNCH.notice`, gated on the `relaunch_notice` HELLO capability). The
  agent appends them to the ring before replaying, so they land after the
  scrollback + divider and before the respawned child's first byte — the same
  slot the divider occupies. A client-side inject does not survive: it reaches
  the terminal after the fresh shell owns the screen, and the shell's first
  prompt repaint blanks the line (measured — the agent-baked divider one row up
  survives while the client's line goes blank, which is what pinned the cause).
  Putting the reset there too removes a second hazard: injected locally it could
  land *after* a `rerun` TUI armed its own mouse tracking and switch it back off.
  Against an agent too old to advertise the capability the client falls back to
  printing both itself — visible, just repaintable.

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
