# T976 acceptance: a launch that beat the local agent to the punch must FINISH
# the restore when the agent turns up - not defer it to the next launch.
#
#   powershell -NoProfile -File test\win32\restore-late-agent.ps1
#
# The bug: `LocalAgent.findOrSpawn` gives a freshly spawned agent 2s to bind its
# pipe, and the launch restore treated that one answer as final. Every window
# whose panes need an ATTACH was then carried forward ("keeping N unrestored
# manifest window(s) for the next launch") and the user sat looking at a blank
# terminal until they relaunched. On a loaded box - a login storm, a cold disk,
# twenty recorded sessions for the agent to re-materialize - two seconds is not
# a long time.
#
# The fix (restore_retry.zig + App.tickRestoreRetry): the launch arms a bounded
# retry, each tick asks whether the agent has come up (a FIND-only dial, never a
# spawn), and the first tick that finds one rebuilds exactly the windows the
# launch carried.
#
# Phases:
#   A. Healthy agent: a startup window, one more auto-named window, and a
#      `solo` window. Wait for the manifest to record all three, and capture the
#      command line the app spawned its agent with - that is how phase B starts
#      one by hand without re-deriving pipe names.
#   B. Kill app AND agent, point the agent binary override at a path that does
#      not exist, relaunch. The launch can restore nothing (B1, the negative
#      control: without it, C proves nothing) and carries the entries (B2).
#   C. Start the real agent BY HAND, with no app relaunch of any kind. The
#      windows must come back into the SAME app process (C1/C2), live rather
#      than merely listed (C3), and every target name must still be unique
#      (C4) - the launch reserved the carried `window-N` names so its own blank
#      startup window could not mint one out from under them.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop, so it never takes the
# user's foreground.
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-late-agent-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: the "attached is not alive" oracle. A restored window that came back as
# a frozen picture satisfies every list-shaped assertion in this file.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T350: refuse a non-debug zig-out before anything is launched - this script
# kills agents and takes the per-user pipe.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700)
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Windows {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    try { $doc = $json | ConvertFrom-Json } catch { return @() }
    if (-not $doc.data) { return @() }
    return @($doc.data.windows)
}

function Get-Targets {
    return @(Get-Windows | ForEach-Object { [string]$_.target } | Where-Object { $_ })
}

function Wait-Targets($want, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $t = @(Get-Targets)
        $missing = @($want | Where-Object { $t -notcontains $_ })
        if ($missing.Count -eq 0) { return $t }
        Start-Sleep -Milliseconds 500
    }
    return @(Get-Targets)
}

function Get-Duplicates($names) {
    $seen = @{}
    $dupes = @()
    foreach ($n in @($names)) {
        if ($seen.ContainsKey($n)) { $dupes += @($n) } else { $seen[$n] = $true }
    }
    return @($dupes)
}

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Wait-Manifest($tmp, $pred, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { if (& $pred $m) { return $m } }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Manifest-Names($m) {
    if ($null -eq $m) { return @() }
    return @(@($m.windows) | ForEach-Object { [string]$_.ipc_name } | Where-Object { $_ })
}

# The app spawns its agent with a fully quoted command line; lifting the tokens
# back out is how phase C starts the SAME agent (same pipe, same state files)
# without this script re-deriving a single lineage rule.
function Get-RepoAgentArgs {
    $p = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') })
    if ($p.Count -eq 0) { return @() }
    $cmd = [string]$p[0].CommandLine
    $tokens = @([regex]::Matches($cmd, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
    if ($tokens.Count -lt 2) { return @() }
    return @($tokens[1..($tokens.Count - 1)])
}

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = '-lateagent'

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:lateAgent = $null

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)

    # ---- A: record a layout against a healthy agent -------------------------
    Say '== A: capture three windows with live agent sessions'
    $app = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'GUI is NOT enumerable on the interactive desktop'

    # window-1 is the startup window; a bare +new-window mints window-2, and
    # `solo` is the explicitly named one. The auto names are what phase C's
    # uniqueness check needs - they are the ones a fresh launch can re-mint.
    $r = Invoke-Verb @('+new-window')
    Assert ($r.Code -eq 0) "A1 bare +new-window exits 0 (got $($r.Code))"
    $r = Invoke-Verb @('+new-window', '--target=solo')
    Assert ($r.Code -eq 0) "A2 +new-window --target=solo exits 0 (got $($r.Code))"

    $want = @('window-1', 'window-2', 'solo')
    $live = @(Wait-Targets $want 45)
    $missing = @($want | Where-Object { $live -notcontains $_ })
    Assert ($missing.Count -eq 0) `
        "A3 all three windows are live pre-quit (missing: $($missing -join ', '); got: $($live -join ', '))"

    $m0 = Wait-Manifest $tmp {
        param($mm)
        $names = @(@($mm.windows) | ForEach-Object { [string]$_.ipc_name })
        @(@('window-1', 'window-2', 'solo') | Where-Object { $names -notcontains $_ }).Count -eq 0
    } 40
    Assert ($null -ne $m0) 'A4 the manifest recorded all three windows'

    $agentArgs = @(Get-RepoAgentArgs)
    Assert ($agentArgs.Count -ge 3) `
        "A5 captured the agent's own command line for phase C (got $($agentArgs.Count) token(s))"

    # ---- B: a launch with no agent restores nothing -------------------------
    Say '== B: relaunch with an unspawnable agent - nothing can be restored yet'
    Stop-RepoInstances
    $env:GHOSTTY_LOCAL_AGENT_BIN = (Join-Path $root 'no-such-agent.exe')
    Assert (-not (Test-Path $env:GHOSTTY_LOCAL_AGENT_BIN)) `
        'B0 the agent binary override points at nothing (setup control)'

    $late = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $late.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: the agentless app has no GhozttyWindow'
    }
    # Give the launch restore, its 2s spawn deadline and the blank window's
    # debounced manifest write room to all be over.
    Start-Sleep -Seconds 6
    $blackout = @(Get-Targets)
    $restoredEarly = @($want | Where-Object { $blackout -contains $_ })
    Assert ($restoredEarly.Count -eq 0) `
        "B1 the agentless launch restored NONE of them (unexpectedly live: $($restoredEarly -join ', '))"
    Assert ($blackout.Count -ge 1) `
        "B2 the launch still opened its blank startup window (got: $($blackout -join ', '))"

    $mB = Read-Manifest $tmp
    $keptB = @($want | Where-Object { (Manifest-Names $mB) -contains $_ })
    Assert ($keptB.Count -eq 3) `
        "B3 all three entries were carried forward, not erased (kept: $($keptB -join ', '))"

    # ---- C: the agent turns up, and the restore FINISHES --------------------
    Say '== C: start the agent by hand - the same app must complete its restore'
    $agentOut = Join-Path $root 'late-agent-out.txt'
    $agentErr = Join-Path $root 'late-agent-err.txt'
    $script:lateAgent = Start-Process -FilePath $agent -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $agentOut -RedirectStandardError $agentErr `
        -ArgumentList $agentArgs
    # Cache the handle before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1).
    $null = $script:lateAgent.Handle
    Assert ($null -ne $script:lateAgent -and -not $script:lateAgent.HasExited) `
        'C0 the hand-started agent is running (setup control)'

    $after = @(Wait-Targets $want 60)
    $stillMissing = @($want | Where-Object { $after -notcontains $_ })
    Assert ($stillMissing.Count -eq 0) `
        "C1 the windows came back once the agent arrived (missing: $($stillMissing -join ', '); got: $($after -join ', '))"

    # The whole point: no relaunch. The process showing them is the one that
    # launched into the blackout.
    $ghosts = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { [int]$_.ProcessId })
    Assert ($ghosts -contains [int]$late.Pid) `
        "C2 the restore landed in the SAME app process (pid $($late.Pid); live: $($ghosts -join ', '))"

    Assert (Test-PaneLive -Exe $exe -Target 'solo' -Tmp $root -Tag 'LATE') `
        'C3 a deferred-restored window is LIVE: input reaches its child and output returns'

    $dupes = @(Get-Duplicates $after)
    Assert ($dupes.Count -eq 0) `
        "C4 every window still has a target name nobody else holds (dupes: $($dupes -join ', '); all: $($after -join ', '))"

} finally {
    Say '== cleanup'
    if ($null -ne $script:lateAgent) {
        Stop-Process -Id $script:lateAgent.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this harness been run against the restore path as it now stands?".
# Red leaves the stamp alone - red stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-late-agent -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
