# Watchdog for the go.md parity loop (tracker T139b).
#
# go.md says outright "Nothing supervises this loop": it perpetuates itself
# only through the /reset-context at the end of every turn, so a single turn
# that ends with a summary instead kills it silently. That has happened twice -
# six dead days (2026-07-21 -> 07-27) and again on 2026-07-28. This script is
# the supervisor: it watches the loop lock's heartbeat (scripts\go-loop-lock.ps1)
# and re-enters the loop when the heartbeat goes stale while tasks remain.
#
# Per tick:
#   1. If the tracker has no remaining todo/in-progress/blocked rows, do
#      nothing - the loop is finished, not stuck.
#   2. Read the lock. Healthy (owner alive AND heartbeat fresh) -> do nothing.
#   3. Otherwise re-enter, choosing the cheapest action that fits:
#        a claude is alive IN THE PANE, pane not producing output
#                              -> send-keys "read go.md and go" + Enter
#                                 (the turn ended with a report; nudge it)
#        pane alive but sitting at a shell prompt
#                              -> send-keys the resume shim + Enter
#        no lock / pane gone   -> +new-window running the resume shim
#      then hold off for -RearmMinutes so a wedged box is not spammed.
#
# "A claude is alive IN THE PANE" is deliberately not "the pid I recorded is
# alive" (T241). A claude relaunched in the pane has a new pid and has not
# claimed the lock yet, so the recorded pid is a corpse while the pane is
# occupied - and on 2026-07-31 that made this script type the shim's PATH into
# a live Claude Code TUI, where it became a chat message. send-keys exit=0,
# nothing re-entered, no error anywhere. So the pane is asked directly
# (scripts\go-loop-pane-probe.ps1), and every typed re-entry is verified by
# reading the pane back afterwards.
#
# Run detached so it survives the terminal that started it:
#   Start-Process powershell -WindowStyle Hidden -ArgumentList `
#     '-NoProfile','-ExecutionPolicy','Bypass','-File',
#     'D:\git\ghoztty\scripts\go-loop-watchdog.ps1'
#
# Or register it to start at sign-in (per-user scheduled task, no elevation):
#   powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Install
#   powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Uninstall
#
# Every action is appended to %TEMP%\ghoztty-go-loop-watchdog.log.
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$LockPath,
    [string]$Tracker,
    [string]$GhozttyExe = "$env:LOCALAPPDATA\Programs\Ghoztty\ghoztty.exe",
    [string]$ResumePrompt = 'read go.md and go',
    # The same text, out of a FILE. Callers whose prompt is caller-authored (the
    # upgrade's resume prompt routinely carries quotes) must use this: passing it
    # as `powershell -File ... -ResumePrompt "<text>"` is the argv hop T210
    # exists to close. Wins over -ResumePrompt when the file is readable.
    [string]$ResumePromptFile,
    [string]$ClaudeCommand = 'claude --dangerously-skip-permissions --continue',
    [string]$WindowTarget = 'main',
    [int]$PollSeconds = 300,
    [int]$StaleMinutes = 45,
    [int]$RearmMinutes = 20,
    [int]$ProbeGapSeconds = 8,
    [int]$VerifySeconds = 6,    # how long to give a shim'd pane to paint claude
    [string]$LogPath,
    [string]$StatePath,
    [switch]$Once,          # single tick then exit (used by the acceptance test)
    # Re-enter even though the lock looks healthy (T439). The two gates this
    # skips - "state is held" and the rearm hold-off - both exist to keep the
    # watchdog from interrupting a session that is working. A caller that KNOWS
    # the loop is broken while the lock still looks fine (the upgrade script,
    # whose resume prompt never landed) is the case they get wrong: the lock was
    # beaten minutes ago by the turn that launched the upgrade, so without this
    # the loop stays dead for up to -StaleMinutes. Everything downstream of the
    # gates still applies, including "the pane is still producing output, do not
    # nudge" - -Force says the heartbeat is not evidence, not that nothing is.
    [switch]$Force,
    [switch]$DryRun,        # decide and log, but take no action
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'

if (-not $LockPath) { $LockPath = Join-Path (Join-Path $Repo 'temp') 'go-loop.lock.json' }
if (-not $Tracker) { $Tracker = Join-Path $Repo 'docs\design\windows-parity-tasks.md' }
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP 'ghoztty-go-loop-watchdog.log' }
if (-not $StatePath) { $StatePath = Join-Path (Join-Path $Repo 'temp') 'go-loop.watchdog.json' }

$lockScript = Join-Path $PSScriptRoot 'go-loop-lock.ps1'
$probeScript = Join-Path $PSScriptRoot 'go-loop-pane-probe.ps1'
. $probeScript      # Get-PaneOccupant / Read-PaneOccupant
# New-LoopPromptFile / Get-LoopPromptNeedle (T210). Functions only, no side
# effects at load.
. (Join-Path $PSScriptRoot 'loop-session.ps1')
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue = 'GhozttyGoLoopWatchdog'

function Log($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    try { $line | Add-Content $LogPath } catch { }
    # Write-Host, not the pipeline: Invoke-Tick returns its action string and a
    # log line leaking into that stream would make the return value an array.
    Write-Host $line
}

# -ResumePromptFile wins over -ResumePrompt, but only when it actually reads: an
# unreadable or empty file must fall back to the default prompt rather than
# re-enter the loop with an empty message. Which one won is logged, because a
# re-entry that types the wrong prompt is the failure this whole file exists to
# catch.
if ($ResumePromptFile) {
    $fromFile = ''
    try { $fromFile = (Get-Content -LiteralPath $ResumePromptFile -Raw -ErrorAction Stop) } catch { $fromFile = '' }
    if ($fromFile -and $fromFile.Trim()) {
        $ResumePrompt = $fromFile.Trim()
        Log "resume prompt read from file ($($ResumePrompt.Length) chars): $ResumePromptFile"
    } else {
        Log "WARNING: -ResumePromptFile '$ResumePromptFile' is missing or empty; falling back to -ResumePrompt"
    }
}

# --- install / uninstall --------------------------------------------------

# Autostart uses an HKCU Run entry, the same mechanism T89h gave the local
# agent. A scheduled task would be tidier, but /SC ONLOGON needs elevation and
# this loop must be installable from an ordinary session.
function Get-RunCommand {
    return "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Repo `"$Repo`""
}

# Ask the single-instance mutex, not the process list: a command-line match on
# the script name also matches the shell that is running -Install right now.
function Test-WatchdogRunning {
    $m = New-Object System.Threading.Mutex($false, 'Global\GhozttyGoLoopWatchdog')
    try {
        if ($m.WaitOne(0)) { $m.ReleaseMutex(); return $false }
        return $true
    } finally { $m.Dispose() }
}

# The long-running watchdog is the invocation with no mode switch; -Install /
# -Uninstall / -Once shells must never be mistaken for it.
function Get-WatchdogProcs {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like '*go-loop-watchdog.ps1*' -and
        $_.CommandLine -notlike '*-Install*' -and
        $_.CommandLine -notlike '*-Uninstall*' -and
        $_.CommandLine -notlike '*-Once*'
    })
}

if ($Install) {
    $cmd = Get-RunCommand
    Set-ItemProperty -Path $runKey -Name $runValue -Value $cmd
    Log "installed Run entry $runValue -> $cmd"
    if (Test-WatchdogRunning) {
        Log "watchdog already running (pid $((Get-WatchdogProcs).ProcessId -join ', '))"
        exit 0
    }
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Repo', $Repo) | Out-Null
    Log 'watchdog started'
    exit 0
}
if ($Uninstall) {
    Remove-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue
    Get-WatchdogProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Log "uninstalled Run entry $runValue and stopped any running watchdog"
    exit 0
}

# --- helpers --------------------------------------------------------------

function Get-RemainingTasks {
    if (-not (Test-Path $Tracker)) { return -1 }   # unknown: never blocks re-entry
    $pattern = '^\| T\S+ \|.*\| *(todo|in-progress|blocked)[^|]*\|[^|]*\|\s*$'
    return @(Select-String -Path $Tracker -Pattern $pattern).Count
}

function Get-Lock {
    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockScript status `
        -Repo $Repo -LockPath $LockPath -StaleMinutes $StaleMinutes -Json 2>&1 | Out-String
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Invoke-Ghoztty($argList) {
    $out = & $GhozttyExe @argList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Test-PaneExists($paneId) {
    if (-not $paneId) { return $false }
    $r = Invoke-Ghoztty @('+list', '--json')
    if ($r.Code -ne 0) { return $false }
    return ($r.Out -match [regex]::Escape($paneId))
}

# A stale heartbeat with a live claude means the turn ended without a reset -
# unless the session is simply mid-task and slow. Sample the pane's tail twice:
# output that is still moving means it is working, so leave it alone.
function Test-PaneProducing($paneId, $gapSeconds = $ProbeGapSeconds) {
    $a = Invoke-Ghoztty @('+read', "--name=$paneId", '--lines=5')
    if ($a.Code -ne 0) { return $false }
    Start-Sleep -Seconds $gapSeconds
    $b = Invoke-Ghoztty @('+read', "--name=$paneId", '--lines=5')
    if ($b.Code -ne 0) { return $false }
    return ($a.Out -ne $b.Out)
}

# The resume command carries a quoted prompt; sending it through send-keys or
# --command as one argument is exactly the quoting that T138's upgrade script
# got wrong (its log shows `--continue read`, the prompt truncated at the first
# space). A generated .cmd shim sidesteps every layer of quoting.
function New-ResumeShim {
    $path = Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd'
    $body = @(
        '@echo off',
        "cd /d `"$Repo`"",
        "$ClaudeCommand `"$ResumePrompt`""
    ) -join "`r`n"
    Set-Content -Path $path -Value $body -Encoding ascii
    return $path
}

# The lock names a dead pid but the pane holds a live claude (T241): point the
# lock at that claude so the next tick reads `healthy` instead of re-deciding.
# Only when it is unambiguous - guessing an owner is worse than leaving the
# lock stale, because the nudged session rewrites it at go.md step 0 anyway.
function Invoke-Adopt($lock, $paneId) {
    if (-not $lock -or -not $paneId) { return }
    $recorded = $null
    if ($lock.claude_start) {
        try {
            $recorded = [datetime]::Parse($lock.claude_start, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        } catch { $recorded = $null }
    }
    $cands = @(Get-Process claude -ErrorAction SilentlyContinue | Where-Object {
        $start = $null
        try { $start = $_.StartTime } catch { $start = $null }
        (-not $recorded) -or (-not $start) -or ($start -gt $recorded)
    })
    if ($cands.Count -ne 1) {
        Log "  adopt skipped: $($cands.Count) candidate claude process(es); the nudged session will reclaim the lock itself"
        return
    }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $lockScript adopt `
        -Repo $Repo -LockPath $LockPath -PaneId $paneId -ClaudePid $cands[0].Id 2>&1 | Out-String
    Log "  adopt pid=$($cands[0].Id): $($out.Trim())"
}

function Read-State {
    if (-not (Test-Path $StatePath)) { return $null }
    try { return (Get-Content $StatePath -Raw | ConvertFrom-Json) } catch { return $null }
}
function Write-State($action) {
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    ([ordered]@{
        last_action    = $action
        last_action_at = (Get-Date).ToString('o')
    } | ConvertTo-Json) | Out-File -FilePath $StatePath -Encoding utf8
}
function Get-MinutesSinceAction {
    $s = Read-State
    if (-not $s -or -not $s.last_action_at) { return [double]::PositiveInfinity }
    try { return ((Get-Date) - [datetime]::Parse($s.last_action_at, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)).TotalMinutes }
    catch { return [double]::PositiveInfinity }
}

# --- one tick -------------------------------------------------------------

function Invoke-Tick {
    $remaining = Get-RemainingTasks
    if ($remaining -eq 0) { Log 'idle: no remaining tracker rows'; return 'none' }

    $lock = Get-Lock
    $state = 'free'
    if ($lock -and $lock.state) { $state = $lock.state }
    if ($state -eq 'held' -and -not $Force) {
        Log "healthy: pane=$($lock.pane_id) pid=$($lock.claude_pid) age=$($lock.age_minutes)m remaining=$remaining"
        return 'none'
    }
    if ($Force) { Log "forced: re-entry requested despite state=$state (caller knows the loop is broken; T439)" }

    $since = Get-MinutesSinceAction
    if ($since -lt $RearmMinutes -and -not $Force) {
        Log ("stale ($state) but rearm not elapsed ({0:N1}m < {1}m); waiting" -f $since, $RearmMinutes)
        return 'none'
    }

    $paneId = ''
    if ($lock) { $paneId = $lock.pane_id }
    $paneAlive = Test-PaneExists $paneId
    $ownerAlive = $false
    if ($lock -and $null -ne $lock.owner_alive) { $ownerAlive = [bool]$lock.owner_alive }

    # T241: ask the PANE who is listening, not the lock. The recorded pid is
    # stale for the whole window between a claude relaunching in the pane and
    # that session running go.md step 0, and typing a shell command into a TUI
    # is a silent no-op.
    $occupant = 'unknown'
    if ($paneAlive) {
        $occupant = Read-PaneOccupant -PaneId $paneId -GhozttyExe $GhozttyExe
        Log "pane $paneId occupant=$occupant (lock owner_alive=$ownerAlive)"
    }

    if ($paneAlive -and ($ownerAlive -or $occupant -eq 'claude')) {
        if (Test-PaneProducing $paneId) {
            Log "stale heartbeat but pane $paneId is still producing output; not nudging"
            return 'none'
        }
        Log "re-entering: nudge live session in pane $paneId (state=$state, occupant=$occupant, remaining=$remaining)"
        if ($DryRun) { return 'nudge' }
        # T210: the prompt goes through a file when the exe supports it, never
        # blindly - PowerShell 5.1 does not escape an embedded `"` when it builds
        # a native command line, and +send-keys concatenates its positional
        # arguments with no separator, so a re-tokenized prompt arrives as
        # run-together prose. The default prompt has no quotes, but -ResumePrompt
        # is caller text and this is the loop's safety net.
        #
        # The capability probe is not optional here: this watchdog is a long-lived
        # HKCU Run process driving whichever ghoztty is INSTALLED, which is
        # routinely older than the repo. An exe without the flag would type
        # `--keys-file=C:\...` into the pane - the T241 failure, recreated by its
        # own fix.
        $keys = New-LoopSendKeysText -Exe $GhozttyExe -Text $ResumePrompt -Tag 'watchdog-nudge'
        if ($keys.Degraded) { Log '  note: this ghoztty predates --keys-file; prompt sent through argv' }
        $r = Invoke-Ghoztty (@('+send-keys', "--target=$paneId") + $keys.Args + @('Enter'))
        Log "  send-keys exit=$($r.Code) $($r.Out)"
        if ($keys.File) { Remove-Item -LiteralPath $keys.File -ErrorAction SilentlyContinue }
        # The lock still names a dead pid, so every later tick would re-decide
        # from scratch. Hand it the pane's own claude when that is unambiguous.
        if (-not $ownerAlive) { Invoke-Adopt $lock $paneId }
        Write-State 'nudge'
        return 'nudge'
    }

    $shim = New-ResumeShim
    if ($paneAlive) {
        Log "re-entering: no claude in pane $paneId (occupant=$occupant), running the resume shim there (remaining=$remaining)"
        if ($DryRun) { return 'restart-in-pane' }
        $r = Invoke-Ghoztty @('+send-keys', "--target=$paneId", (ConvertTo-SendKeysLiteral $shim), 'Enter')
        Log "  send-keys exit=$($r.Code) $($r.Out)"
        # Verify rather than assume: a shim path that landed in a TUI shows up
        # as text and re-enters nothing, which is the T241 failure exactly.
        Start-Sleep -Seconds $VerifySeconds
        $after = Read-PaneOccupant -PaneId $paneId -GhozttyExe $GhozttyExe
        if ($after -eq 'claude') { Log "  RESTART-IN-PANE OK: pane $paneId is running claude" }
        elseif ($after -eq 'shell') { Log "  RESTART-IN-PANE UNVERIFIED: pane $paneId is still at a shell prompt after ${VerifySeconds}s" }
        else { Log "  RESTART-IN-PANE UNVERIFIED: pane $paneId occupant is $after" }
        Write-State 'restart-in-pane'
        return 'restart-in-pane'
    }

    Log "re-entering: no live loop pane, opening a new window (state=$state, remaining=$remaining)"
    if ($DryRun) { return 'new-window' }
    $r = Invoke-Ghoztty @('+new-window', "--target=$WindowTarget", "--working-directory=$Repo", "--command=$shim")
    Log "  new-window exit=$($r.Code) $($r.Out)"
    Write-State 'new-window'
    return 'new-window'
}

# --- main -----------------------------------------------------------------

if ($Once) {
    $action = Invoke-Tick
    "ACTION $action"
    exit 0
}

# Single instance: a second watchdog would double every re-entry.
$mutex = New-Object System.Threading.Mutex($false, 'Global\GhozttyGoLoopWatchdog')
if (-not $mutex.WaitOne(0)) { Log 'another go-loop watchdog is running; exiting'; exit 0 }

Log "=== go-loop watchdog start (poll=${PollSeconds}s, stale=${StaleMinutes}m, rearm=${RearmMinutes}m, repo=$Repo)"
while ($true) {
    try { Invoke-Tick | Out-Null } catch { Log "tick error: $_" }
    Start-Sleep -Seconds $PollSeconds
}
