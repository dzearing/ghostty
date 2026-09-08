# Feature-ideas ledger

Every idea ever suggested in the digest's **Feature ideas** tab, dated. The
daily generator (go.md step 0.7) reads this FIRST and must not re-suggest
anything here — an old idea may return only with a materially new angle,
marked as such. Append-only; one dated section per day, in the same commit
as the digest that showed them.

## 2026-08-09

- Jump to any pane (fuzzy switcher)
- Reopen closed tab/pane (Ctrl+Shift+T)
- Smart paste guard (multi-line paste warning + prompt stripping)
- Layout presets (save/spawn named split layouts)
- Watch rules (user-defined pane notifications)
- Broadcast typing (input to many panes at once)
- Keyboard copy mode (mouse-free selection)
- Scrollback search with a results minimap
- Pre-warmed instant first window

## 2026-08-10

- Clickable file paths in terminal output
- Command blocks (per-command jump, fold, copy)
- Select-and-act toolbar in terminal panes
- Open a pane's scrollback as a viewer document
- Search across every open pane at once
- Drag-and-drop a file onto a pane to insert its path
- Dim inactive panes
- A pane whose shell died stays readable, with restart in place

## 2026-08-11

- Per-project window identity (accent color + badge from the repo/worktree)
- Drag a tab to reorder, tear out, or move to another window
- Notify me when this pane finishes (toast + tab badge + exit status)
- "What happened while I was away" return summary banner
- Tab titles that name the running command and its outcome
- A badge naming the pane's machine and shell flavor (WSL / pwsh / cmd / remote)
- Copy terminal output as markdown (fenced block + the command)
- Spill older scrollback to disk so a long-lived pane keeps hours of history

## 2026-08-12

- A command palette that also searches panes, directories and saved layouts
- Undo the last layout change (reopen the pane/split/divider you just lost)
- Zoom a pane to fill the window and back, without disturbing the split tree
- Detach a running pane into its own window (and re-attach it later)
- Command-boundary and error markers in the scrollbar
- Confirm before closing a pane that is busy (and never when it is idle)
- Paint the window before restore/chooser/daemon work finishes
- Derive activity state from the output stream instead of polling the pane tail

## 2026-08-13

- Anchor a line while output streams underneath it
- Follow the Windows light/dark setting, instantly
- Collapse repeated output lines into one row with a count
- Quick-look the file path or URL under the cursor
- A per-pane timestamp gutter you can toggle
- Drop a pane onto an edge to split
- Remote panes that reconnect visibly after sleep
- Never a blank window over RDP (renderer fallback)

## 2026-08-14

- Build progress on the taskbar button
- An elevated (administrator) pane looks elevated
- Recent projects and saved layouts on the taskbar jump list
- Open this pane's folder in Explorer or your editor
- Copy the selection as an image
- Predictive echo on remote panes
- Snap groups that survive a restart

## 2026-08-15

- A drop-down terminal on a global hotkey (quake mode)
- Paste guard for multi-line text
- Pictures in the terminal (inline-graphics protocol on Windows)
- A "new build is ready" toast with restart-and-restore
- Search everything you ever ran (persistent cross-day command history)
- Safe mode after a crash loop (plain launch: default config, no restore)
- Locked side-by-side scrolling for two panes

## 2026-08-16

- A real settings window (native GUI config editor)
- WSL distros as first-class shells (auto-detected, path translation)
- "A pane is waiting on you" alert (stuck-at-prompt detection)
- Theme browser with live preview
- Acrylic window background (Windows translucency)
- Record a pane as a shareable replay
- Screen-reader support (UI Automation for Narrator/NVDA)

## 2026-08-17

- Split a pane and keep the half-typed command
- A "recording" indicator and one-click transcript export
- Per-pane environment badges (prod / subscription / branch)
- Instant scroll-to-bottom on typing
- A pane you can pin always-on-top
- Cold-start budget with a visible first frame
- Automatic crash breadcrumb in the feedback report

## 2026-08-18

- Type the same command into a whole group of panes (grouped broadcast)
- A per-pane task list built from what you actually ran
- Bring back the pane I closed by accident, with its scrollback
- Explain this error (plain-language reading of selected output)
- A quiet warning before a destructive command
- Remember where I was in this project (cwd + last command per pane)
- A pane that never blocks on a wedged program
- Show me what this build is (running vs installed version, in-app)

## 2026-08-19

- Pick up where the crash left off (restore prompt with a layout preview)
- A scrollback you can leave and come back to (named marks, across restarts)
- Compare two panes side by side (diff view of their output)
- Type into the terminal with the composer's editing (multi-line input line)
- Name a window after what it is for, and have it stick
- A pane that tells you what it is waiting on (working / input / network)
- Never a red suite as background noise (new failures louder than old ones)
- Open the window before the work (first frame before session attach)

## 2026-08-20

- Put my windows back on the right monitors (multi-monitor restore placement)
- Copy what that command printed, without selecting it (copy last output)
- Tell me how long that took, and whether it is slower than usual (per-command timing vs baseline)
- A link to a line of output that you can paste anywhere (deep link into scrollback)
- Follow the system's text size, not just its colors (Windows text scaling)
- A "why is this slow" readout you can actually send (frame time / backlog / RTT panel)
- A first run that finds your shells for you (guided shell-flavor setup)

## 2026-08-21

- Finish my command before I type it (inline autosuggestion from history)
- Press a key, every link on screen gets a label (hint-mode link/path jumping)
- My terminal looks the same on every machine I sign into (settings sync over the relay account)
- Let someone watch this pane (read-only live share link)
- A cheat sheet for the keys you have (searchable keybinding overlay)
- Zoom just this pane, and remember it (per-pane font size, persisted)
- Stay responsive when a pane floods (decoupled render rate under output floods)
- Tell me when a saved session's program has died (dead-session marker in the chooser)

## 2026-08-22

- Make Ghoztty the terminal Windows opens by default (default terminal host registration)
- "Open Ghoztty here" in the Explorer right-click menu
- Bring this session to the machine I am sitting at (session roaming over the relay)
- Find in the viewer pane (Ctrl+F for rendered docs, diffs and pages)
- A password prompt that does not look frozen (masked-input indicator)
- One key hides every piece of chrome (presentation mode)
- Mute a chatty pane (per-pane bell/notification control)
- Tab-completion for the ghoztty command itself (pwsh completer with live pane ids)

## 2026-08-23

- Copy a wrapped line and get one line (unwrap soft line breaks on copy)
- The port a pane just opened becomes a link (listening-port detection)
- Resizing the window rewraps what is already on screen (scrollback reflow)
- The wheel scrolls inside programs that do not handle it (alt-screen wheel translation)
- Snap Layouts from our own maximize button (Windows 11 snap flyout on custom chrome)
- Paste from a history of what you copied here (terminal clipboard ring)
- Drag a selection out of the pane (drag-and-drop selected output)
- Scrolling that feels like the rest of Windows (precision-touchpad momentum)

## 2026-08-30

- Print or share what a viewer pane is showing (PDF / self-contained HTML export)
- A viewer pane that keeps your place when the file changes
- Jump from a diff line into your editor at that line
- An outline for code files, like markdown gets (contents card of functions and types)
- Fold enormous output automatically (collapse a huge block to one expandable row)
- A shortlist of docs you keep opening in side panes (pinned quick-open)
- Zoom the viewer's content, and remember it per pane
- A viewer pane that survives its renderer crashing (reload card, keeps address and history)

## 2026-08-31

- Tell me plainly which build I am running, everywhere (one version string across About, --version, Apps and Features, and the update notification)
- A first-run welcome that proves the install worked
- Install without the scary warning (signed installer, no SmartScreen wall)
- Update quietly while I work, apply when I close
- Show me what changed in this version (human release note from the update notification and About)
- The installer asks the running Ghoztty to step aside (Restart Manager)
- A scripted clean-machine rehearsal (install, re-install over a running copy, read the version back everywhere)
- Let CI MSI build clear the packaging guard

## 2026-09-02

- Pipe anything into a viewer pane (`| ghoztty +view` renders a command's output as a document)
- Filter a pane while it is still streaming (live pattern filter over arriving output)
- Lock a pane so stray keys cannot reach it (read-only toggle for a production shell)
- A tray of every link and path a pane printed (clickable, newest first)
- Hovering a pane focuses it (opt-in focus-follows-mouse across splits)
- Hide the tab strip when there is only one tab
- Which pane is eating my CPU (per-pane child-process CPU/memory readout)
- Quieter on battery (power-aware render cadence when unplugged and unfocused)

## 2026-09-03

- Copy out of a remote or WSL pane and have it land in Windows (clipboard bridge for remote/WSL panes)
- Blur the secrets before you share it (secret redaction in screenshots and feedback captures)
- Turn what you just ran into a script (select command history, save a runnable .ps1/.sh)
- A scratch pad beside the shell (non-terminal notes pane, persisted with the session)
- Choose where a link opens (viewer pane vs browser, remembered per link kind)
- Tidy a window full of tabs (close others / close to the right, with a preview of what goes)
- Respect Windows high contrast (chrome and palette follow the OS high-contrast theme)

## 2026-09-04

- Run this one elevated, right here (per-command UAC elevation without a new window)
- Come back to the environment you left, not just the shell (restore activated virtualenv/conda/module state)
- What did that command change on disk? (per-command file-change and repo-status summary)
- Pick the shell from the new-tab button (split-button flavor menu on `+`)
- Flip back to the pane I was just in (last-focused pane toggle binding)
- Search a session you are not looking at (cross-session scrollback search with attach)
- A release you can verify byte for byte (published checksums plus reproducible builds)

## 2026-09-05

- Run this project's scripts without remembering them (palette offers package.json/justfile/Makefile targets from the pane's directory)
- Scrollback that survives a restart (bounded on-disk scrollback for persistent sessions)
- Know which machine you are about to type into (remote/WSL pane marking plus confirmation on dangerous commands)
- Do not close a window that is still working (close confirmation naming the running command, with keep-session-alive)
- The tab knows which branch you are on (git branch and dirty-state chip in the tab)
- Send a colleague your layout (export/import a named layout as a file)
- Rewind what a pane printed (scrubber replay over the last few minutes of output)

## 2026-09-06

- Put the release you are missing in front of you (About card names the version gap and its headline changes)
- Undo the pane you just closed (Ctrl+Shift+T for panes and windows, geometry and cwd restored)
- Name a window and get back to it from anywhere (global fuzzy jump across every window and pane)
- Type once into several panes (broadcast input toggle with marked receivers)
- A quiet mode for a demo (one switch: no tab strip, no notifications, bigger font, high contrast)
- Publish on a clock the loop cannot miss (daily release trigger on the supervisor tick, not the turn)
- A red harness counts as due (guard-due treats a failing last run as unrun)
- Warm the first frame (measure and cut double-click to first usable prompt)

## 2026-09-07

- Ship the evening's work, not the morning's (publish on the day's last good commit, not a clock)
- See what you are about to update to (update prompt names the changes, not a version number)
- Drag a pane out into its own window (and drop it back onto another window's strip)
- Zoom one pane to fill the window, temporarily (chord to swell the focused pane and back)
- A pane that remembers where it was looking (restore scrollback position, not just the text)
- Tell me when this finishes, whatever I am doing (per-pane toast on command exit, click to focus)
- A test that cannot pass while switched off (harness rule: prove a live-update assertion can fail)
- Say how far behind the installed build is (surface the commits-since-release gap in About)

## 2026-09-08

- Paste that shows you what you are about to paste (preview card for multi-line/long clipboard)
- A pane that tells you when it stopped needing you ("waiting on me" mark that clears at the prompt)
- Reopen the file I just saw scroll past (recent-paths tray built from pane output)
- Session names you did not have to invent (auto-named persistent sessions from cwd + command)
- Dim the panes that are not yours right now (contrast falloff on unfocused panes)
- A release the loop cannot forget to cut (publish on the day's last good commit, supervisor as backstop)
- Tell me the gap in the app, not the digest (About names commits and headline fixes waiting)
- A harness that has never gone red is not a harness (extend the demonstration rule to acceptance scripts)
