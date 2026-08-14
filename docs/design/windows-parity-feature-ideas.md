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
