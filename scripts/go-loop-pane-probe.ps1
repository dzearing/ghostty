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
# Why not `+list --pid=<pid>` (ancestry, the obvious answer)? Because on a
# session-persistence box the agent owns the PTY and `+list --json` reports
# `"pid": 0` for every pane - `+list --pid` matches nothing at all (verified on
# the box 2026-07-31, IpcHandlers.zig:1185 skips shell_pid == 0). Filed as its
# own gap; the watchdog cannot wait for it.
#
# Classification rule, in order:
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

# Read the pane and classify it. Any IPC failure is 'unknown', never a guess:
# a caller that cannot see the pane must not be told it is safe to type a
# shell command into it.
function Read-PaneOccupant {
    param([string]$PaneId, [string]$GhozttyExe, [int]$Lines = 15)

    if (-not $PaneId) { return 'unknown' }
    $out = ''
    try { $out = (& $GhozttyExe +read "--name=$PaneId" "--lines=$Lines" 2>&1 | Out-String) } catch { return 'unknown' }
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    return Get-PaneOccupant -Tail $out
}

if ($ProbeClassify) { Get-PaneOccupant -Tail $ProbeTail }
elseif ($ProbePane) { Read-PaneOccupant -PaneId $ProbePane -GhozttyExe $ProbeExe -Lines $ProbeLines }
