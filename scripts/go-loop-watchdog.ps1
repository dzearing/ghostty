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
#        owner claude alive, pane alive, pane not producing output
#                              -> send-keys "read go.md and go" + Enter
#                                 (the turn ended with a report; nudge it)
#        owner claude dead, pane alive
#                              -> send-keys the resume shim + Enter
#        no lock / pane gone   -> +new-window running the resume shim
#      then hold off for -RearmMinutes so a wedged box is not spammed.
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
    [string]$ClaudeCommand = 'claude --dangerously-skip-permissions --continue',
    [string]$WindowTarget = 'main',
    [int]$PollSeconds = 300,
    [int]$StaleMinutes = 45,
    [int]$RearmMinutes = 20,
    [int]$ProbeGapSeconds = 8,
    [string]$LogPath,
    [string]$StatePath,
    [switch]$Once,          # single tick then exit (used by the acceptance test)
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
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue = 'GhozttyGoLoopWatchdog'

function Log($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    try { $line | Add-Content $LogPath } catch { }
    # Write-Host, not the pipeline: Invoke-Tick returns its action string and a
    # log line leaking into that stream would make the return value an array.
    Write-Host $line
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
    if ($state -eq 'held') {
        Log "healthy: pane=$($lock.pane_id) pid=$($lock.claude_pid) age=$($lock.age_minutes)m remaining=$remaining"
        return 'none'
    }

    $since = Get-MinutesSinceAction
    if ($since -lt $RearmMinutes) {
        Log ("stale ($state) but rearm not elapsed ({0:N1}m < {1}m); waiting" -f $since, $RearmMinutes)
        return 'none'
    }

    $paneId = ''
    if ($lock) { $paneId = $lock.pane_id }
    $paneAlive = Test-PaneExists $paneId
    $ownerAlive = $false
    if ($lock -and $null -ne $lock.owner_alive) { $ownerAlive = [bool]$lock.owner_alive }

    if ($paneAlive -and $ownerAlive) {
        if (Test-PaneProducing $paneId) {
            Log "stale heartbeat but pane $paneId is still producing output; not nudging"
            return 'none'
        }
        Log "re-entering: nudge live session in pane $paneId (state=$state, remaining=$remaining)"
        if ($DryRun) { return 'nudge' }
        $r = Invoke-Ghoztty @('+send-keys', "--target=$paneId", $ResumePrompt, 'Enter')
        Log "  send-keys exit=$($r.Code) $($r.Out)"
        Write-State 'nudge'
        return 'nudge'
    }

    $shim = New-ResumeShim
    if ($paneAlive) {
        Log "re-entering: owner claude is gone, restarting it in pane $paneId (remaining=$remaining)"
        if ($DryRun) { return 'restart-in-pane' }
        $r = Invoke-Ghoztty @('+send-keys', "--target=$paneId", $shim, 'Enter')
        Log "  send-keys exit=$($r.Code) $($r.Out)"
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
