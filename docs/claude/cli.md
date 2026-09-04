# Ghoztty CLI reference

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this when driving
> ghoztty from a script or agent, using or changing ANY CLI verb or its IPC
> semantics, targeting windows/panes, or handling `ghoztty://` links and links
> in terminal output. Remote-machine dialing (`+new-remote-window`, the
> connection pill, relay sign-in) lives in `docs/claude/remote.md`; viewer-pane
> behavior in `docs/claude/viewers.md`.

## CLI Window Management

IPC commands communicate with a running Ghoztty instance over a local IPC
endpoint (a Unix domain socket on macOS, a named pipe on Windows — see
Architecture in `/CLAUDE.md`). All commands are idempotent — named targets that already exist
are focused instead of recreated. Since T135, that focus is no longer silent
about what it dropped: `+new-window` against an existing target replies
`outcome: "focused"` (vs `"created"`) and, when create-only flags
(`--command`, an explicit `--working-directory`, `--view`, …) were passed, a
`note` naming them — which the CLI prints to stderr while keeping exit 0. The
CLI's auto-inserted cwd is marked `--cwd-implicit` on the wire so a bare
re-focus stays quiet. (win32 server done; Mac server half is T523 — the
shared CLI already prints any note it receives.) The verbs, flags, and semantics below are the
same on both platforms.

**A flag this list does not contain is an error, not a no-op** (T489, T852).
Every verb — the ones that parse their own flags and the ones that forward
their whole command line to the running instance — rejects an unknown `--flag`
by name, suggests the nearest real spelling when the typo is close, and exits
non-zero without doing its work:

```
$ ghoztty +split --dirction=right
+split: unknown flag --dirction (did you mean --direction?)
run 'ghoztty +split --help' for usage
```

The SERVER stays tolerant of flags it does not know — that is the
compatibility contract that lets a week-old running instance accept a
CLI that learned a flag this morning — so the check lives in the CLI, which
knows exactly what each verb accepts (`src/cli/verb_flags.zig` for the
forwarding verbs). Two things are deliberately never checked: everything after
`-e`, which is the command, and single-dash arguments, which are content. To
pass literal text starting with `--` (banner text, `+send-keys` payloads), put
it after a bare `--`, which stops flag parsing.

### `ghoztty +new-window`

Create or focus a terminal window. Auto-launches Ghoztty if no instance is running.

```
ghoztty +new-window --target=<name> --working-directory=<path> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --no-activate -e <args...>
```

- `--shell`: Shell to use for `--command`/`--split-command`, invoked with `-lic` so profile is loaded. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`.
  On Windows the fallback is `command-shell` then `cmd.exe`, and the invocation is per-flavor (the shell stays alive after the command): `pwsh`/`powershell` → `-NoExit -Command`, `cmd` → `/K`, `wsl` → `-e /bin/sh -lic "<cmd>; exec \"$SHELL\" -li"` in the default distro, `nu` → `-e`, anything else (e.g. git-bash) → `-lic "<cmd>; exec shell -li"`.
  **The keep-alive is argv-shaped here, and that is why the agent-backed path needs its own wiring** (T468). With `session-persistence` on — the default — every local pane's shell is spawned by `ghoztty-agent`, which synthesizes its own `<shell> /c <cmd>` and exits the moment the command returns. POSIX hides this because its keep-alive lives INSIDE the command string (`<cmd>; exec <shell> -li`), which rides `OPEN.command` untouched; `cmd /K` and `-NoExit -Command` cannot. So a local-agent pane sends the wrapped invocation as `OPEN.argv` (the agent's exec-verbatim seam) while `OPEN.command` still carries the raw command as the session's label. Only for the LOCAL agent — a cross-machine agent is a different machine and applies its own convention. `-e` is never wrapped, on either path: it means "exec exactly this". Acceptance: `test/win32/ipc-command-keepalive.ps1`.
  **`wsl` is the row that takes an ARGV rather than a command string, which is why it looks different** (T656). `wsl -- <cmd>` hands the rest of the *Windows* command line to the distro's default shell **as written**, so the quoting Windows applies to a spaced argument survived into the distro and bash looked for a program literally named `"echo hi"` — `command not found` naming the whole line, on both paths, with the pane dying with it. `-e` execs an argv instead, so the command reaches the inner shell as one properly-unquoted argument. `/bin/sh` because it is the one interpreter every distro is guaranteed to have (dash on Ubuntu, and dash accepts `-lic`); `exec "$SHELL" -li` because the pane must be left in the user's REAL login shell, exactly as the posix row leaves it — `$SHELL` comes from the distro's passwd entry, with `/bin/sh` as the fallback. Acceptance: arm I of `test/win32/ipc-command-keepalive.ps1`.
- `--view`: Open a window whose single pane is a **viewer** (see `docs/claude/viewers.md`) instead of a terminal — a file, a local **HTML page**, a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes in that doc). Mutually exclusive with `--command`/`-e`.
- `--title`: Set the **window title**. A window title pins the titlebar — it wins over any tab or pane title and survives pane focus changes and shell OSC title updates — until cleared. The titlebar falls back to window title → active tab's title → active pane's title. Interactive equivalents: Cmd+Shift+R ("Change Window Title", also sets/clears it), plus separate "Change Tab Title" and "Change Pane Title" commands in the menu and command palette. `ghoztty +rename --target=<name> --title=<title>` changes it later (`--title=""` clears the pin).

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --working-directory=<path> -e <args...>
```

- `--direction`: Split direction. Default: `right`.
- `--target`: Named window to split in. Default: **the pane the command was
  invoked from** (see Caller anchoring), falling back to the most recently
  focused window.
- `--name`: Register the new pane with a name for later targeting.
- `--view`: Open a **viewer** pane (see `docs/claude/viewers.md`) instead of a terminal — a file, a local **HTML page**, a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes in that doc). Mutually exclusive with `--command`/`-e`. Works with `--pane` targeting, including splitting off an existing viewer pane.

On Windows, `ghoztty +list --pid=<pid>` prints just the name of the pane
whose shell is an ancestor of the given process id — the tty-less way for a
process inside a pane to discover its own pane (e.g. `ghoztty +list
--pid=$(cat /proc/$$/winpid)` from git-bash — `$$`, not `self`: the pid must
still be alive when the server walks ancestry, and `/proc/self` read via
`cat` names the already-exited `cat` — or `--pid=$PID` from PowerShell).

### `ghoztty +close`

Close a named pane or window. Closing a nonexistent target succeeds silently.
For a session-persistence pane this ENDS the agent session (the process is
killed once the close's undo window expires) — same as closing the pane in the
GUI. Only an app quit keeps sessions alive for re-attach.

```
ghoztty +close --target=<name>
```

### `ghoztty +rearrange`

Replace a window's active tab's whole split layout with one given as JSON —
every leaf names an already-existing pane, so this MOVES panes rather than
creating them.

```
ghoztty +rearrange --target=<name> --layout='{"direction":"horizontal","ratio":30,"left":{"pane":"a"},"right":{"pane":"b"}}'
```

**A pane the new layout omits is CLOSED, session and all** (T128, win32; the
Mac half is T683). Dropping a pane out of the layout destroys it, so it ends
its agent session exactly as `+close` on that pane would — it used to DETACH
instead, leaving the child running under the agent forever, pinned against the
idle reaper with no pane anywhere that could reach it. A pane the new layout
still names is only being moved and is never touched: the marking runs through
`agent_recovery.closesDepartingLeaf` → `sessionSpared`, so a session the new
tree still references is never ended (main's `e65cfa4d5` invariant, which is
what keeps recovery-style tree swaps safe). Acceptance:
`test/win32/rearrange-session-drop.ps1`.

### `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout.

```
ghoztty +read --name=<pane> --lines=<N>
```

- `--name`: Named pane to read from (required).
- `--lines`: Number of lines from the end of scrollback (default: 50).

**An empty pane is an answer, not an error** (T181, win32; the Mac half is
T481). A terminal pane that has printed nothing yet exits 0 with empty output,
the way `tail` of an empty file does — that is the state of *every* pane for
the first fraction of a second of its life (the window is registered, and
`+list --json` already reports its pane id and its child's pid, before the
shell has painted a prompt) and the permanent state of a pane running something
silent. It used to answer `failed to read terminal content from '<pane>'`,
which a caller could not tell apart from a missing or wedged pane — so a caller
that read once recorded "the pane produced no output" as a verdict. Every
remaining failure names a distinct state: `not found in registry`, `is no
longer alive`, `is a viewer pane, not a terminal`, `is not readable: its
terminal never finished starting up`, and `failed to read terminal content`
(now only a genuine internal failure). `+send-keys` splits the same two
liveness states apart. The "last N lines" rule itself lives in
`src/apprt/ipc/read_tail.zig` so both platforms describe it identically.

**A pane on the alternate screen reads back the visible screen** (T193,
win32; the Mac half rides with T481). A TUI pane — htop, a pager, a
full-screen installer — answers `+read` with what a user looking at the pane
sees, because the dump reads the *active* screen; the alternate screen has no
scrollback by design, so the visible frame is the whole truthful answer. When
the program leaves the alt screen (`ESC[?1049l`), the primary screen's
scrollback is readable again. Regression arm: G in
`test/win32/ipc-read-race.ps1`.

### `ghoztty +list`

List open windows, tabs, and panes (human-readable tree, or `--json`). Listing auto-registers every pane it discovers, so returned names are immediately usable as targets.

```
ghoztty +list [--json] [--tty=<tty>]
```

- `--tty`: Print only the registered name of the pane whose terminal matches the given tty (`ttys014` or `/dev/ttys014`; raw padded `ps -o tty=` output is accepted), then exit. Exits 1 if no match. Lets a process find its own pane: `ghoztty +list --tty="$(ps -o tty= -p $PPID)"`.

`--json` windows carry a **`chrome`** object reporting where the tab strip's
clickable regions ARE (T231) — `{"dpi": 120, "tab_strip": {"band", "tabs",
"new_tab", "menu"}}`, every rect in the window's CLIENT coordinates, physical
pixels, right/bottom exclusive. They are not a fresh layout pass: they are the
rects the window's own hit tests read, so what is reported and what a click
reaches cannot drift. **`null` means there is nothing there to hit** — the
`menu` on a window whose caption hosts the menu (T260), a tab the strip could
not fit, every region of a strip that has not painted yet — and `tab_strip:
null` means the window shows no strip at all, which is a different answer from
the whole `chrome` key being absent (a server that cannot say). `band` is where
strip content may sit: inside both insets, the buttons' own vertical band, and
on a merged caption row its right edge is the seam rather than the window edge.

This exists because the alternative is a second implementation of
`tab_strip_layout` in whatever language the caller is written in, and that
cannot be type-checked against the first: the win32 acceptance harness kept one
and it rotted twice — a fixed "46px left of the right edge" that landed inside
the menu button at 125% DPI, then a modelled tab width that stopped matching
when T235 sized tabs to their titles. Both produced failing assertions against
a completely healthy product. Consumers ask
`Get-TestStripRegions` (`test/win32/lib/ChromeGeometry.ps1`); a pixel scan is
now only for asserting that something is PAINTED, never for finding a click
target. (win32 server since T231; the Mac server half is T735.)

`--json` terminal panes carry a `session_id` field when the pane is bound to a
session-persistence agent session — the join key against `+sessions --json`,
so a script can answer "which pane is this session open in" (and vice versa)
without app logs. Absent for plain non-persistent panes and viewers. (win32
server since T332; the Mac server half is T553.)

### `ghoztty +sessions`

List the persistent terminal sessions owned by the local `ghoztty-agent` (the daemon that keeps session-persistence PTYs alive across app restarts). Unlike the other IPC commands, this dials the agent **directly** over its 0600 unix socket (`~/.config/ghoztty/local-agent[-debug]/agent.sock`) — NOT the app's IPC socket — so it works even when the Ghoztty app is not running (as long as the agent is). Requires `session-persistence = on`. On Windows the agent's local transport is instead an owner-only-DACL **named pipe** (`\\.\pipe\ghoztty-agent[-debug]-<user>`); the endpoint is discovered from the agent's `pipe` field in `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\port.json`, and the same-uid guarantee comes from the pipe DACL rather than a peercred check.

```
ghoztty +sessions [--json] [--agent]
```

Each row reports the session id, liveness (`alive`; `dead(relaunchable)` for a tombstone that RELAUNCH can still revive — e.g. after a reboot or agent restart; or `dead(<code>)` for a genuinely exited session), whether a viewer is currently `attached`, the activity state (`idle`/`busy`/`needs_input`), the child pid, `pinned` when the session is protected from the agent's idle-TTL reaper (persistent local panes are pinned so they survive the viewer quitting indefinitely; cross-machine sessions are not), the working directory (when known), and the command. `--json` emits one object per session for scripts and agents.

```bash
ghoztty +sessions
ghoztty +sessions --json
```

**`--agent` answers which BUILD is running** (T662), instead of listing
sessions. The agent outlives the app on purpose, so it is routinely a different
build than everything around it — and until this existed that comparison
happened only in an app log line, on a box where the app had already been
restarted past the interesting moment:

```
running:  20260719-574fe0805  (pid 24228)
bundled:  20260730-e69d41755
status:   stale - 11 days behind, 4 live sessions
next:     Ghoztty restarts it onto the bundled build when no sessions are open, or when you confirm the restart it offers.
```

`status` is a machine token — `current`, `stale`, `newer`, `unknown` (the
bundled binary could not be read), `not_running` — and `--json` emits it with
`running`, `bundled`, `days_behind`, `live_sessions`, `sessions`, `agent_pid`,
`handoff` and `legacy_sessions`. **No agent running is an answer, not an error**: it exits 0 with
`not_running`, because the next persistent session simply starts the bundled
build. `days_behind` is calendar days between the two `YYYYMMDD` stamps, and is
absent rather than 0 or negative whenever there is no honest number to give (a
`dev` stamp, a pre-versioned agent, a same-day rebuild, a newer running agent).
Staleness itself is defined in exactly one place for both readers —
`src/remote/agent_build.zig`, shared by this CLI and the win32 upgrade policy
(`agent_upgrade.zig`) — so the number a user reads and the decision the app acts
on cannot disagree. Acceptance: `test/win32/sessions-agent-build.ps1`.

**How a long-lived box adopts a newer agent** (the state this command exists to
make visible). Since **T907** the answer on Windows is: **the agent replaces
itself, and no session closes.** `handoff` is the machine token for that, and it
is what the `next:` line is written from:

- `ready` — a newer build beside it is adopted on the agent's own schedule, with
  nothing asked and nothing lost. `next:` says so.
- `draining` — it will, but not yet: `legacy_sessions` counts the live sessions
  whose ConPTY the agent owns DIRECTLY. Those cannot be carried across a process
  boundary at all, so each one has to close first. (`draining` is also what an
  unreadable roster reports, because "your update costs nothing" is a promise and
  that case did not verify it.)
- `unsupported` — an older agent, or a seat where the mechanism has not landed.
  Then the pre-T907 answer applies, and it is the one that could go unreached
  indefinitely: restart at zero live sessions, or the mandatory confirmation. On
  a box whose panes never all close, neither happens — the morning app-only
  refresh (T525) deliberately never swaps `ghoztty-agent.exe` and defers that
  confirmation, and the check re-runs only at launch and when the last persistent
  window closes. There the documented path stays an **attended full delivery**
  (`scripts/launch-upgrade.ps1` without `-AppOnly`, which does prompt).

Mechanism and contract: `docs/claude/sessions.md`; design:
`docs/design/agent-nondestructive-handoff.md`.

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
- `--when-idle`: Poll the target pane's recent output every 500ms until it looks idle before sending: the tail unchanged across ~1s (busy TUIs animate spinners/timers every second; an idle prompt is static — this catches any working program, no tool-specific marker needed) AND none of the caller's `--busy-marker` texts present. Sends anyway after `--idle-timeout=<seconds>` (default 30) or if the pane can't be read.
- `--busy-marker=<text>`: Extra busy signal for `--when-idle` — while `<text>` appears in the pane's last lines, the pane counts as busy even if its tail is static. Repeatable; any match counts. The CLI deliberately bakes in no tool's chrome (T517/D11): a caller that knows what its program prints while working names it here (e.g. older Claude Code rendered `esc to interrupt`; current versions animate, which motion detection already catches).
- `--keys-file=<path>`: Send the file's bytes **verbatim** — no key notation, no
  `\n` escape processing. It keeps its position among the positional arguments,
  so `--keys-file=p.txt Enter` sends the file and then a carriage return. **Use
  this for any text the caller did not author by hand** (a prompt, a path,
  anything with quotes or backslashes): PowerShell 5.1 does not escape an
  embedded `"` when it builds a native command line, so such text arrives as a
  positional argument with its quotes stripped, re-tokenized and concatenated
  without separators, or broken outright. Length is not the hazard — the
  transport is byte-exact at 10,000 characters (T210). **The trailing-newline
  rule below does not apply to it**: the CLI sends a file exactly as it is on
  disk, trailing newline included, because "verbatim" is the flag's whole reason
  to exist and a generated prompt file routinely ends in a newline nobody meant
  as "submit". Submit one with a following `Enter` (or `--enter`). Like any
  text run it follows the paste convention below, so the file's own trailing
  newline reaches a bracketed-paste program (every TUI) as a literal newline
  and does not submit.
- Positional arguments are text or key names, written to the PTY in order.
  Adjacent arguments of the same kind merge into one **run**, and the run
  boundaries survive to the PTY write: a text run is framed as a **bracketed
  paste** (`ESC[200~` … `ESC[201~`, one write) when the program in the pane has
  mode 2004 enabled, and key runs are written bare, outside the frame. That is
  what makes `+send-keys --target=t "a long prompt" Enter` submit — an unframed
  trailing `\r` reads to a TUI as a newline *inside* pasted text, and the
  message sits in the composer unsent. Framing is a property of the bytes, not
  of their timing, so no sleep in the path substitutes for it.
- Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term --enter "ls -la"
ghoztty +send-keys --target=term C-c
```

**A trailing newline is a keypress; an interior one is content.** The trailing run of `\n`/`\r` is peeled off a text argument and delivered as that many Enter presses, so `"a\nb\n"` pastes two lines and then submits. **What is counted is line endings, not bytes** (T658): a trailing `\r\n` is ONE line ending written the Windows way and presses Enter once, while repeated endings still count separately (`"a\n\n"` and `"a\r\n\r\n"` both press twice, and a bare `"a\r\r"` still presses twice). Counting bytes there submitted a CRLF-terminated argument twice — the caller's message, then an empty line after it, which a chat-style TUI reads as a second, blank turn — and Windows is where CRLF text comes from. This is a deliberate divergence from upstream main's byte-counting peel (`a7f7476e1`), which T604 ported verbatim; round 17 of `test/win32/send-keys-bracketed.ps1` is the on-wire oracle. This runs after escape processing, so `\n` written as the two-character escape and a real newline byte behave identically. The accepted cost: there is no way to paste text ending in a literal newline without submitting — a trailing newline in a paste means "commit" essentially always, and a program that has not enabled bracketed paste sees `\r` mapped back to `\n` by the tty's `ICRNL` anyway. (`--keys-file=` is exempt; see above.)

**A newline inside a text run follows the paste convention, on both platforms** (T661). A program that has enabled bracketed paste receives it as a literal `\n` — it is a line break in the pasted content, which is what makes `"a\nb\n"` type two lines into a composer and then submit. A program that has NOT receives `\n` mapped to `\r`, which is what xterm has always done for an unbracketed paste (`src/input/paste.zig`) and what makes the same send run two commands in a shell. macOS reaches the second half for free, because a POSIX pty accepts LF as a line terminator; Windows has to do the mapping, because conhost's VT input translation **swallows a bare LF** — without it `+send-keys "echo A\necho B\n"` reaches `cmd.exe` as `echo Aecho B`. The win32 rule is `IpcHandlers.prepareSendKeysRun`; rounds 11, 12 and 15 of `test/win32/send-keys-bracketed.ps1` measure both halves on the wire.

That rule needs to know the CLI already spelled `Enter` as CR, and a flat `--keys=` payload cannot say so by itself, so **every `+send-keys` request carries `--keys-resolved=1`**. A request without it came from a CLI old enough that a bare `\n` meant Enter and is normalized unconditionally, exactly as before — a server ignores the argument it does not know, and macOS, which never normalized at all, ignores it forever. Round 16 is that control.

**Any unknown `--flag` is a hard error** (exit 1), naming the submit spellings. `--press-enter` used to become a text positional and get typed into the pane at exit 0, which is how agents got this wrong without noticing. Single-dash arguments (`-la`, `-p`) are ordinary text. To send literal text starting with `--`, put it after a bare `--`, which stops flag parsing but not key notation:

```bash
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

**Text and keys stay distinguishable.** Argument boundaries survive all the way to the write. When a call mixes text with keys, adjacent arguments of the same kind merge into a run, and each **text** run is written to the pane as a **bracketed paste** (`ESC[200~` … `ESC[201~`) while each **key** run is written bare, outside the frame.

This is what makes `+send-keys --target=t "some message" Enter` actually submit. Flattened into one burst of bytes ending in `\r`, a TUI's paste detection reads that `\r` as a newline inside pasted text — correctly, since that is exactly how a real multi-line paste looks — and the message sits unsent in the composer. Framing states which bytes were pasted, so the `\r` after the closing fencepost is unambiguously a keypress. It is a property of the bytes, not of their timing, so there is no delay anywhere in the path.

Two consequences worth knowing:

- A text run is framed **in a single PTY write**. Splitting the frame across writes lets the opening fencepost land in its own `read()` on the far side, and a receiver that sees a lone `ESC[200~` does not reliably associate it with the content after it (measured against Claude Code, which then falls back to its length heuristic and swallows the `\r` again).
- Framing only happens when the program running in the pane has **enabled bracketed paste** (DEC mode 2004) — which every modern TUI and interactive shell does. A pane running something that has not (`cat`, a shell script's `read`) gets the bytes verbatim, so nothing can inject literal `[200~` junk into a program that would not understand it. Text containing `ESC[201~` is also sent unframed, rather than emitting a frame that would close early.

Single-kind calls — `"text"` on its own, `Enter` on its own, `C-c` on its own — have no boundary to disambiguate and are sent byte-for-byte as they always were.

**Delivery integrity is measured, not assumed** (T664). A pane read cannot tell a byte that never arrived from a byte the grid lost, which is how one sighting of a text run missing its FIRST character — a `--keys-file` run landing a beat after a bare Enter — stayed an anecdote. Rounds 13–14 of `test/win32/send-keys-bracketed.ps1` pin that shape on the wire, byte for byte, including a payload long enough to cross the 64-byte pooled write buffer in `termio.Exec.queueWrite` (the only seam that splits one run across two PTY writes). `test/win32/send-keys-soak.ps1` repeats it a few hundred times with randomised gaps, judged by a receipt file the in-pane shell writes rather than by the screen; it is **on-demand, not part of P1–P3**. 315 measured sends found no loss, so nothing in our write path is known to truncate a run — the unexplained leg, if it recurs, is conhost's VT input translation and cygwin's console reader.

**A boundary the CLI cannot see is a boundary it cannot encode.** Framing spans one call, so a caller that must split the text and the Enter into two calls — the self-upgrade does, because it verifies the prompt arrived before submitting it — gets a flat text run and a naked CR no matter what the CLI does. Such a caller submits with `" " Enter` rather than a bare `Enter`: the throwaway space makes the *submitting* call a mixed send, so a closing fencepost lands immediately before the CR. A trailing space means nothing to the receiver, which is what makes it safe — a submit that instead withheld the prompt's own last character would submit a truncated prompt if that character were dropped. Shared helper: `Get-LoopSubmitArgs` in `scripts/loop-session.ps1` (T438); byte-level oracle: rounds 6–8 of `test/win32/send-keys-bracketed.ps1`.

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

### `ghoztty +set-banner`

Set or clear the sticky banner of a named pane or window. The banner is a native overlay rendered above the terminal content of a pane — it persists (survives scrolling, screen clears, and content updates) until changed or cleared. Setting a banner on a window target applies it to that window's focused pane (banners are per-pane).

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

- `--target`: Named pane or window. Required.
- `--clear`: Remove the banner (empty text does the same).
- All other arguments are treated as the banner text (multiple are joined with spaces).

Banner text supports a small markdown subset: `**bold**`, `*italic*` or `_italic_`, `__underline__`, `` `code` ``, and `[text](url)` clickable links (URL must include a scheme, e.g. `https://`). Note `__underline__` intentionally differs from CommonMark (where `__` is bold). `\` escapes the next character. Unterminated delimiters render literally. A literal `\n` in CLI banner text becomes a line break — banners can span multiple lines (display is capped at 10 lines).

**Autolinking.** Bare URLs and bare file paths become clickable without `[text](url)` syntax. A URL must carry a scheme — only `http://` and `https://` linkify, never a bare `www.example.com` or `config.io`, so prose is never falsely linked. A file path must start with `/`, `~/`, `./`, or `../` — **plus, on Windows, a drive path (`D:\…`, `D:/…`), a UNC share (`\\server\share\…`), and the backslash spelling of each relative sigil (`~\`, `.\`, `..\`)**; the sigil is the whole signal (there is no filesystem check), which is why a bare relative `macos/Sources/Foo.swift` or `docs\design\foo.md` stays plain text. `~/` expands to the home directory and `./`/`../` resolve against **the pane's current working directory** at render time — a dot-relative path in a pane with no known cwd stays plain text rather than resolving against a guess. Trailing sentence punctuation stays outside the link (`See https://x.com.` links `https://x.com`), while brackets balanced *inside* the link are kept (`…/Foo_(bar)`). Autolinking never fires inside a `` `code` `` span, after a `\` escape, or inside an explicit `[label](url)` — the explicit link always owns its whole label. Shared rules, one implementation per platform: `SurfacePaneBanner`'s `autolink` on macOS, `banner_markdown.autolink` on Windows (T539), where the pass runs **ahead of the backslash-escape branch** because a UNC path opens with the escape character itself — `\\server\share` would otherwise be eaten one `\` at a time. Acceptance: section 6j of `test\win32\pane-banner.ps1`.

**Link clicks.** A plain click hands the link *out* of Ghoztty; the modifiers bring it back in. Cmd (**Ctrl on Windows**) opens a **viewer side pane** for either kind of link, and Cmd-Shift (**Ctrl-Shift**) gives the link a surface of its own.

| | plain click | Cmd / Ctrl | Cmd-Shift / Ctrl-Shift |
|---|---|---|---|
| **URL** | default browser | side pane | new Ghoztty window |
| **file path** | reveal in Finder / File Explorer | side pane | open with default app |

A URL goes to the real browser by default because Ghoztty's `WKWebView` (WebView2 on Windows) keeps its own cookie store with no relationship to Safari/Chrome/Edge — anything behind a login renders logged-out in a viewer pane, and OAuth sign-in never completes. A file path is only *revealed*, never opened, so a click can't launch whatever app claims the extension. The right-click menu offers all of them (its first item is by contract the left-click default) plus Copy Link / Copy Path.

**Link hover affordance.** A banner link's underline is **dotted at rest and solid while the pointer is over it** (plus the pointing-hand cursor), so a link reads as a link before you click and tells you which one a click would take. Hovering lights the WHOLE link, not the fragment under the pointer — a link split by wrapping or by nested styling goes solid together. The underline is drawn by hand rather than by the font's own underline attribute, because there is exactly one of those and it is solid: a link would otherwise either always look hovered or never look like a link. Shared with the same click/menu model on both platforms (win32: `banner_link.zig` + `banner_layout.linkUnderline`, T165).

**Lists.** Consecutive lines that begin with a list marker render as a list block with table-like row spacing and a **shared marker gutter**, so every item's content left-aligns regardless of marker kind (bullets, numbers, and checkboxes in one run all line up). Supported markers:

- `- ` or `* ` → an unordered **bullet** (`•`).
- `1.`, `2.`, … (digits, a period, then a space) → an **ordered** item, rendered with the source number. A decimal like `1.5` (no space after the dot) stays plain text.
- `[x]`/`[X]` (checked) and `[ ]` (single space, unchecked) → a read-only **task-list checkbox**, drawn as a **native box** (rounded 2px corners; checked shows a green check on a faint green wash), not a plaintext glyph. A `- `/`* ` directly before a checkbox is the checkbox's marker, not a separate bullet (`- [x] done`). Checkboxes are display-only (no interactivity), and `[x](url)` is still a link (the `x` is link text). Checkboxes in **table cells** render the same native box. A checkbox that appears mid-paragraph in a wrapping (non-list) text line falls back to the `☑`/`☐` glyph.

**Separators.** A line of 3+ of the same `-`, `*`, or `_` (spaces allowed — `---`, `***`, `___`, `- - -`) is a **thematic break**, rendered as a full-width horizontal divider between the blocks above and below it (e.g. to separate a title, a table, and a trailing note). A `- `/`* ` bullet or `**bold**` on its own line is unaffected (they carry non-marker content or mixed characters). Each rule counts as one line toward the 10-line display cap.

Banners also support standard markdown pipe tables, rendered as an aligned grid with a bold header row: a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows. Separator cells may carry `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged body rows are padded/truncated to the header width. The separator row doesn't render; every other table row counts toward the 10-line display cap (a row still counts once no matter how many lines its cells wrap to). **Long cell text word-wraps** onto multiple lines and the row grows to fit, rather than truncating to one line — matching a normal markdown renderer. Column widths derive from the pane's current width, so the banner reflows live as the pane is resized and never blocks the pane from shrinking (even a long unbroken token breaks mid-string). A cell is capped at **3 wrapped lines** — a cell that would wrap further (e.g. a long unbroken string in a very narrow pane) is tail-truncated with an ellipsis on its last visible line, so one nasty cell can't blow up the banner height. A cell that contains an *inline* task-list checkbox stays a single line (its native box can't reflow around wrapping text).

**Everything wraps, by one rule.** Paragraphs, headings and list rows wrap exactly the way table cells do (T377) — greedy word wrap against the pane's current content width, a long unbroken token broken mid-string, and the same **3-line cap** with a tail ellipsis on the last visible line. A wrapped list row's continuation lines start at the shared marker gutter, not back under the marker, and a task-list row wraps like any other (its checkbox is the row's *marker*, drawn in the gutter, so nothing has to reflow around it). The wrapped height is what the renderer reports upward, so the band, the pane inset and the terminal below all follow it. The 10-line display cap still counts a wrapped block **once**, the way a wrapped table row counts once.

**The collapse chevron owns the card's right strip.** Content — every block, not just the first line — stops a clear 4 DIP short of the chevron's box, so no paragraph, heading, list row, table cell or rule ever paints under it. The reservation is pure geometry (`banner_layout.contentWidth`, asserted at 1.0/1.25/1.5/2.0) and applies only when the banner is collapsible, i.e. when a chevron is actually drawn.

**Collapsing animates the card and only the card.** The card eases between its expanded and collapsed heights over 180ms (`banner_layout.COLLAPSE_MS`, Mac's `easeInOut(0.18)`), while the band the window layout reserves — and therefore the terminal grid below it — moves to the settled height in ONE step per click. Both platforms arrive there from opposite directions: Mac drives its inset off a hidden, animation-free copy of the banner content so the Metal surface never chases intermediate frames; win32 simply never lets the animation into `stripHeight()`, and lets the still-tall card overhang the terminal for the length of a collapse. A second click mid-flight reverses from the height the card is actually at, and users who turned off Windows' "animation effects" (`SPI_GETCLIENTAREAANIMATION`, read in one place: `App.clientAreaAnimationsEnabled`) get the instant toggle. What win32 does NOT do yet is Mac's parallel cross-fade of the body — it clips the content to the animating card with the existing bottom fade instead, filed as T677. Acceptance: section 6f2 of `test/win32/pane-banner.ps1` (T149).

```bash
ghoztty +set-banner --target=dev "**Build status**\n| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |"
```

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev --clear
```

Processes can also set the banner from inside the pane via OSC escape sequence: `\033]7778;<text>\007` (empty text clears). The interactive equivalent is Cmd+R ("Set Pane Banner…", also in the command palette), which opens a multi-line editor for the focused pane's banner (Return inserts a newline, Cmd+Return saves, Escape cancels). Cmd+R only reaches this while a **terminal** pane is focused — a focused viewer pane takes Cmd+R for reload (see `docs/claude/viewers.md`). On Windows the editor chord is Ctrl+Shift+B and Ctrl+Enter saves (plain Ctrl+R belongs to the shell).

Banners are persisted per pane in the session-layout manifest (keyed to the stable pane id), so a session-persistence restore brings them back with their text intact — across app quit/relaunch/upgrade re-attach and across an agent-restart relaunch alike. **The banner slot belongs to the pane** (T422): the session-interrupted notice an agent-restart prints is always folded into the pane's scrollback, but only claims the banner slot when the pane has no banner of its own — a restored banner is never overwritten by it. `+list --json` reports each terminal pane's current banner in a `banner` field (absent when no banner is set), which is also the CLI way to read a banner back.

### `ghoztty +reload`

Reload a named **viewer pane** (see `docs/claude/viewers.md`) in place — no
close/reopen. Website viewers re-fetch the page from origin (bypassing
caches); file viewers re-render the file preserving scroll position (they
already live-reload on their own, so this mainly matters for URL viewers);
**diff viewers re-run their git command**, picking up commits, staging, and
edits, and keeping the open file and its scroll position. A rendered `.html`
file is re-fetched bypassing caches like a website — the verb is the explicit
"these bytes are stale" one, which is how it picks up an edited sibling
stylesheet that the file watcher never saw.

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

### Caller anchoring

A command that needs a pane or window and was given none anchors at **the pane
it was invoked from**, not at whatever window happens to be focused. The CLI
forwards `$GHOZTTY_PANE_ID` as `--caller-pane=<id>`; the app prefers it over its
own focused-window fallback.

This is the same shape as Instance addressability below (the CLI reads a baked
env var; one resolution site each side) and exists for the same reason: the
default used to be read on the app's side **at handle time**, so the answer was
whichever window was key by then. An agent in pane A asking for a viewer side
pane, plus a user clicking window B in the meantime, put the pane in B. The race
does not need a user, either — an agent's command is asynchronous with respect
to focus.

- **Applies to `+split` and `+rearrange`.** Both took the focused-window
  fallback. `+new-window` creates a window and needs no anchor, and
  `--from-focused` (on `+split` and `+new-window`) is the caller asking for the
  focused window BY NAME, so neither changed.
- **Anything explicit wins**: `--target`, `--pane`, `--from-focused`.
- **Absent or empty ⇒ the old behavior**, so a CLI run from a plain non-Ghoztty
  shell, or from a pane baked by an older app/agent, is unchanged.
- **A pane id that no longer resolves falls back rather than failing** — a
  script outliving its own pane is ordinary. That is why the wire flag is
  `--caller-pane=` and not `--pane=`: an explicit `--pane=` naming nothing is a
  typo and stays a hard error.
- One resolution site on the CLI side for both platforms:
  `apprt.ipc.seedCallerPane()` (`src/apprt/ipc.zig`), which inserts the flag
  ahead of anything from `-e` on. One on each server side too:
  `IPCServer.callerAnchorPane` (Swift) on macOS, and
  `apprt.ipc.args.callerAnchorPane` — the pure precedence rule, unit tested in
  both zig lanes — behind `IpcHandlers.callerAnchorPaneView` on Windows (T1079).
  Acceptance: `test/win32/caller-anchor.ps1`, which drives two windows and asks
  where each split went.

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
- **Windows uses the same var for a pipe name** (T118): the value is
  `\\.\pipe\ghoztty[-debug]-<user>`, not a socket path, and the name was kept
  identical rather than adding a sibling — the var is baked into long-lived
  panes that outlive the app, and neither side ever parses the value. The CLI
  resolves it in `ipc_client.clientEndpointPath()`
  (`src/os/ipc_client.zig`), which `apprt.ipc.socketPath()` delegates to there.
- **An explicit `GHOZTTY_PIPE_SUFFIX` outranks the baked value** on Windows.
  The suffix is how a harness aims at the instance it just launched, and a
  script inherits the environment of the pane it was started from — without
  this rule every `test\win32\*.ps1` run from one of the user's panes would
  drive the user's terminal. Precedence: suffix → baked → derivation.
- **Only clients read it.** The IPC *server* binds `ipc_client.endpointPath()`,
  the pure derivation, and the win32 App drops any inherited
  `$GHOZTTY_IPC_SOCKET` from its own environment at startup — otherwise a dev
  build launched from a pane of the installed release would try to bind (or
  forward its startup `new-window` to) that release instance's endpoint.
  Acceptance: `test/win32/ipc-instance-addressability.ps1`.

### Starting Ghoztty when Ghoztty is already running

**A second launch does not become a second app.** It loses the race for the IPC
endpoint (`FILE_FLAG_FIRST_PIPE_INSTANCE`; `IpcServer.init` answers
`AlreadyRunning`), forwards a `new-window` to the winner and exits — one app,
one tray icon, one session list, a new window. That is the Mac app-bundle
behavior and Windows Terminal's, and the user chose it in D79 over two copies
quietly sharing one agent and one saved layout.

- **The launch's own arguments ride along** (T487): the working directory and
  `-e`/`--command` are re-emitted as `+new-window` flags
  (`App.forwardedNewWindowArgs`), so `ghoztty -e pwsh` typed in a project
  directory opens *that* command in *that* directory rather than a bare shell
  wherever the running app happens to sit. The handoff happens in `App.init`
  before any window, tray icon or agent connection exists, so nothing of the
  second app is ever half-created.
- **The instance identity is the endpoint, which is keyed on the build
  LINEAGE** — the `-debug` suffix, or an explicit `GHOZTTY_PIPE_SUFFIX`. A
  debug `zig-out` build and the installed release therefore never join each
  other, which is what keeps side-by-side development (and every acceptance
  script) working.
- **Two copies of ONE lineage do join**, because they already share that
  endpoint, the agent and the saved layout. The installed release and the
  Desktop portable copy are exactly that pair — so a shortcut pointing at one
  can hand you a window belonging to the other, which D79 named as its one con.
- **A build mismatch is therefore not silent** (T1022). The launch carries its
  own `{version, commit, exe}` across the handoff as an additive `handoff`
  object on the request (`ipc_client.buildRequestWithHandoff`); when it differs
  from the running instance's, the reply carries a `note` (the CLI prints it to
  stderr) and the app shows a desktop balloon naming the copy that actually
  owns the window. Same build ⇒ nothing is said: the two copies are the same
  bits and the join is invisible on purpose. Text and comparison:
  `src/os/ipc_handoff.zig`. Acceptance:
  `test/win32/single-instance-join.ps1`.

### Every verb answers or explains — it never just waits

**No CLI verb blocks indefinitely on the app** (T755). The bound is 30s per
exchange, with a "still waiting" line on stderr at 5s, and `GHOZTTY_IPC_TIMEOUT_MS`
overrides it (`0` waits forever, for a caller who genuinely wants that — a
debugger attached to a stopped app). The timeout message names the verb, which
half of the exchange was waiting, and the env var: *"Timed out after 30.0s
trying to get a response from Ghoztty for '+list'."*

It is a structural hazard, not a rare one. The server reads a request on a
listener thread and marshals it to the GUI thread with no timeout of its own,
and from the client side a GUI thread that is busy — a cold start, a session
restore — is indistinguishable from one that is wedged. On 2026-08-11 a
`+list` fired during `ipc-p1.ps1`'s cold auto-launch was still blocked **34
minutes later** with 0.06s of CPU, against an app that was alive and rendering.
There was no way out because a synchronous `ReadFile` on a named pipe cannot be
interrupted: no output, no error, no exit code, and a caller capturing that
child's stdout hung with it. So the client's pipe is opened
`FILE_FLAG_OVERLAPPED` and every read carries an OVERLAPPED that can be
cancelled; posix gets the same bound from `SO_RCVTIMEO`/`SO_SNDTIMEO`, so the
Mac CLI is bounded by the same policy without a second implementation of it.

Two things that look like details and are not:

- **The bound and the handle are separate facts.** `Conn.owned` says this
  process opened the handle (and may therefore bound it); `Conn.timeout_ms`
  says how long. Folding them into one field made `GHOZTTY_IPC_TIMEOUT_MS=0`
  hand an overlapped handle to a synchronous `ReadFile` — documented as
  unpredictable, and measured here as a read that neither completed nor timed
  out. The win32 IPC **server** wraps each accepted pipe instance in a `Conn`
  it did not open, which is exactly what the `owned: false` default protects.
- **A typo must not reinstate the hang.** An unparseable
  `GHOZTTY_IPC_TIMEOUT_MS` falls back to the 30s default, never to forever;
  only a literal `0` opts out.

The auto-launch wait `+new-window` performs is a different question and has its
own budget (`ipc_timeout.auto_launch_ms`, 30s): there the peer is a process we
just started, and its cold start includes the loader, Defender scanning a
freshly built binary, config parsing and a session restore. The old budget —
20 fixed attempts of 500ms — was reached in the wild, costing `ipc-p1.ps1`'s
first section three assertions on one cold run that passed clean on the re-run,
which reads as a regression and is not one. Waiting nearly three times as long
is only safe because the wait now WATCHES the process it launched: an instance
that dies during startup ends the wait immediately rather than burning the
budget on a peer that is never coming.

Policy (numbers, env parsing, wording) is pure and asserted in the `none` lane:
`src/os/ipc_timeout.zig`. Acceptance: `test/win32/ipc-timeout.ps1`, driven by
`ipc-fake-server.ps1 -Wedge` — a peer that accepts, reads the request and
answers nothing, so nothing there depends on timing luck — with a replying
server as the control and the harness itself capped, so a regression of the
bound fails the script instead of hanging it.

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

One verb, one shape. `<target>` is percent-decoded and passed to the same
target resolver `--target` uses, so there is one naming system, not two: a
registered window name, an auto `window-N`, a registered pane name, or a pane
id (`$GHOZTTY_PANE_ID`, case-insensitive). Everything after the verb is ONE
target, so a name containing `/` survives encoded (`focus/feat%2Flogin`) or not
(`focus/feat/login`). The path form is canonical over `ghoztty://<target>`
(nowhere to put a verb) and over `ghoztty://focus?target=…` (a second escaping
context for no gain). Parsing is strict: unknown verb, empty target, and bare
`ghoztty://<name>` all yield nothing rather than a lenient guess. **There is no
`+focus` CLI verb on either platform** — the scheme is a link surface, and a
verb that existed on one CLI and not the other is the divergence this project
does not ship.

**Focus is the only capability, and that is the design, not a first
increment.** A registered URL scheme is reachable by any web page the user
visits — no prompt, no gesture beyond a click, no same-origin check, no way to
know who asked. Everything the IPC endpoint exposes is safe there only because
a 0600 unix socket (an owner-only-DACL named pipe on Windows) is reachable only
by code already running as the user; none of that holds for a link. A scheme
that could spawn a shell (`--command`), type into a pane (`+send-keys`), or open
a viewer would be remote code execution behind an `<a href>`. Raising an
already-existing window is the one verb whose worst case is a nuisance. The
parser reads a verb rather than hardcoding one shape so a future verb *could* be
added — but wanting a second verb to make something work is a signal to stop and
ask, not to add one.

Consequences, all deliberate and the same on both platforms:

- **The debug build registers `ghoztty-debug://`**, the release builds
  `ghoztty://` — the same split as the IPC endpoint (and, on macOS, the bundle
  id). Otherwise the shell picks between them and the user's links start landing
  in a debug build. macOS declares it in `CFBundleURLTypes` (the
  `GHOSTTY_URL_SCHEME` build setting); Windows has no `Info.plist`, so the app
  writes its own per-user handler at launch —
  `HKCU\Software\Classes\<scheme>` with the `URL Protocol` marker and
  `shell\open\command` = `"<this exe>" "%1"`, off the GUI thread, idempotent and
  rewritten every launch so an upgrade or a move re-points it. `HKCU`, never
  `HKLM`: Ghoztty installs per user and a machine-wide association would need
  elevation. `GHOZTTY_URL_SCHEME=0`/`off` skips registration.
- **On Windows the release scheme is also gated by LOCATION** (T1124): a build
  whose exe sits inside a source checkout — any ancestor directory holding
  `build.zig` — registers nothing. The build-mode split alone was not enough,
  because the staging release we package deliveries from lives at
  `zig-out-release\bin` *in the checkout*: it is a release build, so one launch
  of it pointed the user's `ghoztty://` links at a scratch directory that
  ordinary development rebuilds and deletes. The installed release and a
  portable unpack are both outside a checkout and are unaffected.
  `GHOZTTY_URL_SCHEME=force` skips the gate; `=gate` applies it to a debug build
  too, which is how `test\win32\url-scheme.ps1` measures it.
- **Both spellings parse in both builds.** Links clicked *inside* Ghoztty are
  short-circuited in process and never reach the shell, so a document that
  hardcodes `ghoztty://` still focuses the right pane when a debug build is
  rendering it.
- **A link that resolves to nothing says so** (`url_scheme.Failure`): a warning
  naming the target for `target_not_found`, or naming the URL plus the one
  supported form for `unsupported_link`. A click that appears to do nothing is
  indistinguishable from a broken app, and both failures are ordinary (the
  window was closed; the document predates this build). What failure never does
  is *act*: no window is created and no "closest" window is focused as a
  consolation. Presentation is **coalesced** so a burst — any page can fire a
  scheme — is one dialog, not one per link: macOS behind an
  `isPresentingFailure` flag (`application(_:open:)` takes a whole array),
  Windows behind a named mutex as well, because there every click is its own
  short-lived process and a flag cannot see the burst. A URL that isn't ours at
  all is ignored silently; nobody clicked a Ghoztty link. The wording lives on
  `Failure` rather than in the presenter so it is testable.
- **App not running:** the honest answer is the same as any other miss —
  nothing is open by that name — because a focus link must never create a
  window as a side effect. macOS cannot decline the launch LaunchServices does,
  so the app comes up with its normal `initial-window` behavior (that belongs to
  *launching Ghoztty*, exactly as `open -a` does, not to the focus verb) and the
  link reports not-found. On Windows the activation process reports it and
  exits without starting a terminal at all.
- **Viewer panes** intercept `ghoztty://` ahead of the live-page passthrough
  (the engine cannot load the scheme, so an allowed navigation is a dead click,
  and handing it to the shell would route it to whichever BUILD registered the
  scheme). A `target="_blank"` focus link resolves to a *command* destination
  instead of falling through "non-web scheme ⇒ open a Ghoztty window", which is
  how it used to create a viewer window pointed at the command string.
- **Rendered markdown** needs `viewer.js` to widen DOMPurify's
  `ALLOWED_URI_REGEXP` by exactly these two schemes. markdown-it keeps a
  `ghoztty://` href, and the sanitizer then stripped it — the link rendered as
  dead text. Keep the regex in sync when the vendored DOMPurify is bumped.
- **Banner links** ignore the Cmd / Ctrl modifier scheme: the link names a
  window, not content, so there is nothing to open in a side pane or a new
  window. The right-click menu is **Focus in Ghoztty** + **Copy Link**.

The grammar and the failure wording are ONE definition per platform —
`src/apprt/ipc/url_scheme.zig` on Windows, `GhozttyURLScheme.swift` on macOS —
so the launcher, the viewer and the banner cannot disagree about what a link
means. Windows entry points: `main_ghostty.zig` (an activation is answered
before the single-instance bind, or it would forward a `new-window` and open a
terminal), `ViewerPane` for viewer link clicks and popups, `BannerOverlay` for
banner clicks; all funnel into `apprt/win32/url_scheme.zig` →
`IpcHandlers.focusTarget` (the external path through the internal `focus` IPC
action). Acceptance: `test/win32/url-scheme.ps1`.

## Links in terminal output

Text a program prints into a pane becomes clickable — ctrl-hover (⌘ on macOS)
underlines it, ctrl-click opens it — by matching one regex against the hovered
LINE. That regex is shared core, `src/config/url.zig`, wired in as the default
`link` in `Config.default`, and it is the same string on both platforms.

**Windows paths are part of it** (T757). Before that the regex had three
branches and every one of them was POSIX-only: all three path branches were
built from a `path_chars` class with **no backslash**, and none knew a drive
letter, so `D:\Users\me\clip.mp4` printed by any tool could not match anything
and stayed dead text — on the surface a Windows user looks at all day, and for
most of what a path in a terminal is *for*. Branch 4 adds a drive prefix
(`D:\…`, `D:/…`, either case) and a UNC share (`\\server\share\…`), and reuses
the POSIX branch's own dotted/undotted split so `C:\Program Files\app.exe`
matches whole while `D:\a\b C:\c\d` stays two paths. `foo\bar.md` with no
sigil stays text, exactly as it does in a pane banner (T539, whose sigil set
this follows).

Two consequences worth knowing:

- **The branch is live on EVERY platform**, not comptime-gated on Windows. A
  `D:\…` string means nothing on macOS so it costs that seat nothing, a Mac
  window attached to a Windows agent shows Windows paths in its panes, and a
  shared core that quietly matches different text per platform is the kind of
  divergence that rots. `test "url regex"` therefore runs the Windows cases on
  both seats.
- **A single letter and a colon is never a URI scheme**, which is what keeps
  the `s:/` inside `https://` from reading as a drive — the same call
  `banner_link.kindOf` makes on the banner side. It is a lookbehind, not a
  scheme list, so it also protects every scheme nobody has added yet.

**What a click DOES is open, not reveal** — and that is deliberate, not an
oversight of the banner rule. A banner link only ever *reveals* a file
(T165), because a banner is chrome; the TERMINAL's link click opens with the
default application, on macOS (`NSWorkspace.shared.open`) as on Windows
(`App.openUrl` → `ShellExecuteW("open")`). Making Windows reveal instead
would be the divergence, not the parity.

Acceptance: `test/win32/terminal-link-paths.ps1`, whose oracle is a
**ctrl+right-click** — a right-press selects the link the terminal found
(else the plain word) before showing the context menu, so the selection is
the terminal's own answer, readable through ctrl+c, and nothing is launched.
Column 0 is what makes it unambiguous: `:` is a word boundary and `\` `/` `.`
are not, so the `Q` of `Q:\Users\…` selects as the whole path when the link
is found and as the lone character `Q` when it is not. The double-click
gesture is NOT the oracle: it reaches link detection with no modifier at all
and finds the link, and then the selection is replaced by a plain word-select
before anything can read it — filed as **T802**.

