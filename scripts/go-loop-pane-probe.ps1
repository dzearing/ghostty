# Pane helpers for the go-loop watchdog (T241): who is sitting in this pane -
# a Claude Code TUI, or a shell prompt? - and how to type a path into it
# without the escape layer eating half of it.
#
# The go-loop watchdog re-enters a dead loop by TYPING into the loop's pane,
# and the right thing to type depends entirely on what is listening:
#
#   shell prompt  -> the resume shim path (a .cmd that starts claude)
#   Claude TUI    -> the resume PROMPT as ordinary text
#
# Getting that backwards is silent. On 2026-07-31 the watchdog typed the shim
# PATH into a pane running Claude Code; the path became a chat message,
# send-keys reported exit 0, and nothing re-entered the loop (T241). The
# watchdog had asked "is the pid I recorded still alive?" - a question about a
# process, when the question that matters is about the PANE.
#
# The recorded pid cannot answer it: a claude relaunched in the pane (by the
# upgrade, by the user, by a crash-restart) has a NEW pid and has not claimed
# the lock yet, so the lock points at a corpse while the pane is very much
# occupied. So this probe reads the pane instead.
#
# The probe leads with an EXACT check (T244): since T41/T153 the pane's shell
# pid in `+list --json` is real on a session-persistence box (the agent reports
# each session's child pid; the app publishes it), so "is a claude alive in
# THIS pane" is answerable from the process table - shell pid -> descendants ->
# a live claude.exe. A hit is definitive whatever the screen shows (the busy
# claude whose chrome scrolled off, measured 2026-08-04, classified 'unknown'
# by the tail heuristic alone). A miss is NOT proof of absence - the pid read
# or the table walk can fail, and an app without the fix still reports 0 - so
# a miss falls through to the tail heuristic below, which also remains the
# only way to tell 'shell' from 'unknown'.
#
# Tail-classification rule, in order:
#   1. The last non-empty line looks like a shell prompt  -> shell.
#      A live full-screen TUI always owns the bottom of the screen, so a shell
#      prompt down there beats any amount of Claude output in the scrollback
#      above it (that is exactly the "claude ran and exited" case).
#   2. Otherwise, a Claude Code chrome marker anywhere in the tail -> claude.
#   3. Otherwise, one of Claude Code's own transcript glyphs -> claude. Chrome
#      WORDING is version-specific and has already drifted twice; the glyphs
#      have not.
#   4. Otherwise -> unknown (an unreadable or blank pane; the caller decides).
#
# Dot-source it for the pure classifier, or run it:
#   . scripts\go-loop-pane-probe.ps1 ; Get-PaneOccupant -Tail $text
#   powershell -File scripts\go-loop-pane-probe.ps1 -ProbeClassify -ProbeTail "D:\x>"
#   powershell -File scripts\go-loop-pane-probe.ps1 -ProbePane <id>
#
# Every CLI parameter carries a Probe prefix on purpose. Dot-sourcing a script
# also declares its param() variables in the CALLER's scope, so a plain
# -GhozttyExe here would silently overwrite the watchdog's own (which the
# acceptance test points at zig-out), and a plain -Exe would overwrite the
# acceptance test's. The functions take ordinary parameter names; only the
# script's own surface is prefixed.
param(
    [string]$ProbeTail = '',
    [string]$ProbePane = '',
    [string]$ProbeExe = "$env:LOCALAPPDATA\Programs\Ghoztty\ghoztty.exe",
    [int]$ProbeLines = 15,
    [switch]$ProbeClassify
)

# T663: Resolve-GhozttyCliExe lives in loop-session.ps1 (one place decides which
# binary a CLI answer is read from). This file is dot-sourced by callers that
# have already loaded it and run standalone by callers that have not, so load it
# only when the function is missing. loop-session.ps1 is documented as free of
# top-level side effects, which is what makes that safe.
if (-not (Get-Command Resolve-GhozttyCliExe -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'loop-session.ps1')
}

# ASCII only, deliberately: these scripts are read by PowerShell 5.1, which
# decodes a BOM-less UTF-8 file as ANSI and mojibakes every box-drawing glyph.
# So the markers are the TUI's words, never its border characters.
$script:ClaudeMarkers = @(
    'esc to interrupt',
    'to interrupt',
    'for shortcuts',
    'bypass permissions',
    'shift+tab to cycle',
    'Welcome to Claude Code',
    'Claude Code',
    # The busy screen's token counter, e.g. "(15m 9s - 47.1k tokens)". Every
    # marker above belongs to the IDLE composer, and a working Claude Code
    # scrolls all of them off: measured on this box 2026-08-04, a pane with a
    # live session mid-task classified as 'unknown', which is the answer that
    # makes the watchdog type a shell command at it (the T241 failure).
    'tokens)'
)

# Claude Code's own transcript glyphs, built from code points so this file stays
# ASCII (see the encoding note above): U+25CF is the bullet on every
# assistant/tool line, U+23BF the connector under a tool result. Between them
# they are on screen for any pane that has Claude Code output in it, whatever
# the version's chrome wording happens to be this month - and wording is what
# has drifted twice now.
#
# Matching SCROLLBACK is safe here only because rule 1 outranks this: a claude
# that ran and exited leaves its glyphs behind, but it also leaves a shell
# prompt at the bottom, and that is what the pane gets classified by.
$script:ClaudeGlyphs = @(0x25CF, 0x23BF) | ForEach-Object { [string][char]$_ }

# Anchored whole-line prompts. Loose ones ("ends with >") would match the
# composer border, which is the failure this file exists to prevent.
$script:ShellPromptPatterns = @(
    '^[A-Za-z]:\\[^>]*>\s*$',      # cmd.exe            C:\dir>
    '^PS [^>]*>\s*$',              # powershell         PS C:\dir>
    '^[^$#]*\$\s*$',               # sh / git-bash      user@host ... $
    '^[^$#]*#\s*$'                 # root sh
)

function Get-PaneOccupant {
    param([string]$Tail)

    if ([string]::IsNullOrWhiteSpace($Tail)) { return 'unknown' }

    $lines = @($Tail -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
    $last = ''
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if (-not [string]::IsNullOrWhiteSpace($lines[$i])) { $last = $lines[$i].Trim(); break }
    }

    foreach ($p in $script:ShellPromptPatterns) {
        if ($last -match $p) { return 'shell' }
    }
    foreach ($m in $script:ClaudeMarkers) {
        if ($Tail -like "*$m*") { return 'claude' }
    }
    foreach ($g in $script:ClaudeGlyphs) {
        if ($Tail.Contains($g)) { return 'claude' }
    }
    return 'unknown'
}

# `+send-keys` interprets backslash escapes in its text arguments (\n, \t, \r,
# \e, \\), so a Windows path is not safe to hand it raw: %TEMP% under a user
# called "tom" makes the shim path C:\Users\tom\... and the pane receives a TAB
# where \t was. Caught 2026-07-31 building the T241 negative control, whose own
# temp dir was ...\Temp\t241-negctl\ - the pane ran "C:\Users\David\AppData\
# Local\Temp241-negctl\fake-tui.cmd" and cmd said "cannot find the path".
# Doubling every backslash makes it arrive verbatim.
function ConvertTo-SendKeysLiteral {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('\', '\\')
}

# The pane's shell pid, from `+list --json` (0 when the pane is not found, has
# no terminal, or the app cannot say). $PaneId matches the leaf's stable id
# (the $GHOZTTY_PANE_ID uuid) or its registered name, case-insensitively -
# the same values `+read --name=` accepts.
function Get-PaneShellPid {
    param([string]$PaneId, [string]$GhozttyExe)

    if (-not $PaneId) { return 0 }
    $json = ''
    # T663: `2>$null` against the GUI-subsystem ghoztty.exe captures NOTHING and
    # leaves $LASTEXITCODE empty, so this probe answered 0 for every pane. The
    # console twin is what makes the capture real; `--json` is also why `2>&1`
    # (the other thing that forces the capture) is not the fix here - it would
    # fold any warning line into the payload ConvertFrom-Json has to parse.
    $cli = Resolve-GhozttyCliExe $GhozttyExe
    try { $json = (& $cli +list --json 2>$null | Out-String) } catch { return 0 }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return 0 }
    $tree = $null
    try { $tree = $json | ConvertFrom-Json } catch { return 0 }
    $root = if ($tree.PSObject.Properties.Name -contains 'data') { $tree.data } else { $tree }
    foreach ($w in @($root.windows)) {
        foreach ($t in @($w.tabs)) {
            $stack = New-Object System.Collections.Stack
            $stack.Push($t.splits)
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                if ($null -eq $n) { continue }
                if ($n.type -eq 'leaf') {
                    if (-not $n.terminal) { continue }
                    $hit = ($n.terminal.id -and ($n.terminal.id -ieq $PaneId)) -or
                           ($n.terminal.name -and ($n.terminal.name -ieq $PaneId))
                    if ($hit) { return [int]$n.terminal.pid }
                } else {
                    if ($n.right) { $stack.Push($n.right) }
                    if ($n.left) { $stack.Push($n.left) }
                }
            }
        }
    }
    return 0
}

# Pure: the pid of the first live Claude Code process among $ShellPid's
# descendants in $Procs (objects with ProcessId/ParentProcessId/Name/
# CommandLine, i.e. a Win32_Process snapshot), or 0. Chrome's native-messaging
# host is also claude.exe but is not a TUI in any pane, so it never counts -
# a browser launched from the pane would otherwise make every probe say
# 'claude'. Separated from the CIM read so the walk is unit-testable
# (go-loop-guard.ps1 section M).
function Find-ClaudeDescendant {
    param([int]$ShellPid, [object[]]$Procs)

    if ($ShellPid -le 0 -or -not $Procs) { return 0 }
    $kids = @{}
    foreach ($p in $Procs) {
        $parent = [int]$p.ParentProcessId
        if (-not $kids.ContainsKey($parent)) { $kids[$parent] = New-Object System.Collections.ArrayList }
        [void]$kids[$parent].Add($p)
    }
    # BFS with a seen-set: Windows reuses pids, so a stale snapshot can contain
    # a parent "cycle"; without the guard that is an infinite loop.
    $seen = @{ $ShellPid = $true }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($ShellPid)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $kids.ContainsKey($cur)) { continue }
        foreach ($p in $kids[$cur]) {
            $cpid = [int]$p.ProcessId
            if ($seen.ContainsKey($cpid)) { continue }
            $seen[$cpid] = $true
            if (($p.Name -ieq 'claude.exe') -or ($p.Name -ieq 'claude')) {
                if (([string]$p.CommandLine) -notmatch 'chrome-native-host') { return $cpid }
            }
            $queue.Enqueue($cpid)
        }
    }
    return 0
}

# The exact claude-in-this-pane check (T244). $true means a Claude Code
# process is ALIVE under this pane's shell right now - definitive, whatever
# the screen shows. $false only means "could not prove it": fall back to the
# tail heuristic, never conclude the pane is free.
function Test-ClaudeInPane {
    param([string]$PaneId, [string]$GhozttyExe)

    $shell = Get-PaneShellPid -PaneId $PaneId -GhozttyExe $GhozttyExe
    if ($shell -le 0) { return $false }
    $procs = $null
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, Name, CommandLine)
    } catch { return $false }
    return ((Find-ClaudeDescendant -ShellPid $shell -Procs $procs) -gt 0)
}

# Read the pane and classify it. The exact process-table check leads; the tail
# heuristic is the fallback. Any IPC failure is 'unknown', never a guess: a
# caller that cannot see the pane must not be told it is safe to type a
# shell command into it.
function Read-PaneOccupant {
    param([string]$PaneId, [string]$GhozttyExe, [int]$Lines = 15)

    if (-not $PaneId) { return 'unknown' }
    if (Test-ClaudeInPane -PaneId $PaneId -GhozttyExe $GhozttyExe) { return 'claude' }
    $out = ''
    # T663: the console twin, and therefore `2>$null` rather than `2>&1` - a
    # merged stderr line becomes part of the text this function CLASSIFIES.
    try { $out = (& (Resolve-GhozttyCliExe $GhozttyExe) +read "--name=$PaneId" "--lines=$Lines" 2>$null | Out-String) } catch { return 'unknown' }
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    return Get-PaneOccupant -Tail $out
}

if ($ProbeClassify) { Get-PaneOccupant -Tail $ProbeTail }
elseif ($ProbePane) { Read-PaneOccupant -PaneId $ProbePane -GhozttyExe $ProbeExe -Lines $ProbeLines }
