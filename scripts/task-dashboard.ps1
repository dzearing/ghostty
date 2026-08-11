<#
.SYNOPSIS
  Start the Windows-parity task dashboard and open it in a Ghoztty viewer pane.

.DESCRIPTION
  Starts scripts\task-dashboard.js on localhost (hidden, detached, so it
  outlives this shell) and opens a viewer pane pointed at it. Both halves are
  idempotent: an already-listening server is reused, and a pane named
  -PaneName that already exists is focused rather than opened twice.

  The dashboard is served over http rather than written to a .html file
  because a Ghoztty viewer renders .md and treats every other extension as
  CODE - a local .html would display its own source. The page re-reads the
  task files on every poll, so adding or editing a task shows up on its own
  within a few seconds; nothing needs restarting.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  scripts\task-dashboard.ps1
  scripts\task-dashboard.ps1 -Port 9001 -NoPane
  scripts\task-dashboard.ps1 -Stop
#>
[CmdletBinding()]
param(
    [int]$Port = 7788,
    [string]$PaneName = 'tasks',
    [string]$Direction = 'right',
    # Which pane to split. Defaults to the pane this script was run FROM:
    # bare `+split` targets the most recently focused window, which is not
    # reliably the window you typed in, so the dashboard would open somewhere
    # else. $GHOZTTY_PANE_ID is baked into every pane's environment.
    [string]$Target = $env:GHOZTTY_PANE_ID,
    # Start the server but do not touch the window layout.
    [switch]$NoPane,
    # Stop whatever is serving this port from this repo.
    [switch]$Stop,
    # Register (or remove) the keep-alive scheduled task described below.
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Script = Join-Path $PSScriptRoot 'task-dashboard.js'
$Url = "http://localhost:$Port/"

function Test-Listening {
    param([int]$P)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $P)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# Match on the command line, never on the process name: node is a shared
# runtime and killing every node.exe on the box would take unrelated work with
# it (the same reasoning as the ghoztty-agent ExecutablePath rule in CLAUDE.md).
function Get-DashboardProcess {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*task-dashboard.js*' }
}

# --- keep-alive ------------------------------------------------------------
#
# The server is started from a Ghoztty pane, which puts it inside the app's
# kill-on-close job object - so it dies with the app, every time. On 2026-08-11
# Ghoztty restarted at 08:19:34 and the dashboard went with it: the port simply
# stopped listening, and nothing anywhere was going to bring it back. That is
# what "the tracker died" was.
#
# A per-user scheduled task fixes it at the root, because the Task Scheduler
# service creates the process - outside any job this repo's tooling can be
# caught in - and it re-runs on a timer, so a death from ANY cause (app
# restart, crash, reboot) self-heals within the interval. `/sc MINUTE` needs no
# elevation, which is the same reason T440's watchdog revive task uses it. The
# launcher no-ops when the port is already listening, so the tick is free.
$taskName = 'GhozttyTaskDashboard'

function Get-KeepAliveCommand {
    # schtasks wants the whole command as ONE /tr argument with its inner
    # quotes backslash-escaped; anything else silently loses everything after
    # the first space (the trap T440 documents).
    return '\"powershell.exe\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden' +
           " -File \`"$PSCommandPath\`" -Port $Port -NoPane"
}

if ($Uninstall) {
    schtasks /Delete /TN $taskName /F 2>&1 | Out-Null
    Write-Host "task-dashboard: keep-alive task '$taskName' removed"
    return
}

if ($Install) {
    schtasks /Create /TN $taskName /TR (Get-KeepAliveCommand) /SC MINUTE /MO 5 /F 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not register the keep-alive task '$taskName'" }
    Write-Host "task-dashboard: keep-alive task '$taskName' registered (every 5m)"
    # Fall through and start it now, so -Install also brings the server up.
}

if ($Stop) {
    $procs = @(Get-DashboardProcess)
    if ($procs.Count -eq 0) {
        Write-Host 'task-dashboard: nothing running'
    } else {
        foreach ($p in $procs) {
            Stop-Process -Id $p.ProcessId -Force
            Write-Host "task-dashboard: stopped pid $($p.ProcessId)"
        }
    }
    return
}

if (-not (Test-Path $Script)) { throw "missing $Script" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'node is required and was not found on PATH'
}

if (Test-Listening -P $Port) {
    Write-Host "task-dashboard: already serving $Url"
} else {
    # The server is detached and hidden, so without this its output goes
    # nowhere and a death leaves NO evidence at all - which is exactly what
    # "the tracker died" looked like on 2026-08-11: the port simply stopped
    # listening, with nothing in the Application log and nothing on disk. One
    # generation is kept (.prev), because the log you want is the one written
    # by the run that just died, and restarting is the first thing anyone does.
    $logDir = Join-Path $RepoRoot 'temp'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $outLog = Join-Path $logDir 'task-dashboard.log'
    $errLog = Join-Path $logDir 'task-dashboard.err.log'
    foreach ($f in @($outLog, $errLog)) {
        if (Test-Path $f) { Move-Item -LiteralPath $f -Destination "$f.prev" -Force }
    }

    Start-Process -FilePath 'node' `
        -ArgumentList @($Script, '--port', $Port) `
        -WorkingDirectory $RepoRoot -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog | Out-Null

    # The first run walks ~440 commits of git history to build the trend, so
    # allow for a slow start instead of declaring failure at one second.
    $ok = $false
    foreach ($i in 1..40) {
        if (Test-Listening -P $Port) { $ok = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ok) {
        $tail = if (Test-Path $errLog) { (Get-Content $errLog -Tail 10) -join "`n" } else { '' }
        throw "server did not come up on port $Port$(if ($tail) { "`n$tail" })"
    }
    Write-Host "task-dashboard: serving $Url (log: $outLog)"
}

if ($NoPane) { return }

$ghoztty = Get-Command ghoztty -ErrorAction SilentlyContinue
if (-not $ghoztty) {
    Write-Host "task-dashboard: ghoztty not on PATH - open $Url yourself"
    return
}

# +split is idempotent on a registered name: an existing pane is focused, not
# duplicated. Capture output through the pipeline, never a redirect (T245).
$splitArgs = @("--direction=$Direction", "--name=$PaneName", "--view=$Url")
if ($Target) { $splitArgs += "--target=$Target" }
$out = & ghoztty +split @splitArgs 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "task-dashboard: could not open the pane: $($out.Trim())"
    Write-Host "task-dashboard: the dashboard is still at $Url"
} else {
    Write-Host "task-dashboard: pane '$PaneName' -> $Url"
}
