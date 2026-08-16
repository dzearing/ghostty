# T590 acceptance: a launch that restores nothing must NOT overwrite the
# session-layout manifest.
#
# The bug: win32 regenerates the manifest wholesale from the live topology on
# every sync. A launch where the agent is unspawnable restores no terminal-only
# window (T398 semantics - nothing to ATTACH to), opens the default blank
# window, and the blank window's first debounced sync then REPLACED the
# recorded layout with that one window. Both copies (manifest + agent blobs)
# were unavailable in exactly the same moment, so the layout was gone for good.
# macOS keeps entries untouched on the no-connection path; T590 carries the
# unrestored entries forward through every rewrite instead.
#
# Phases:
#   A. Healthy agent: open a terminal window named 'solo', wait for the
#      manifest to record it with a live agent session id.
#   B. Kill app AND agent, point the agent binary override at a path that does
#      not exist, relaunch. The restore drops 'solo' (terminal-only, no agent)
#      and opens a blank window; when the rewrite lands, 'solo' must STILL be
#      in the manifest with its recorded session id (B1/B2). Controls: solo has
#      no live panes (B4 - it truly was not restored) and no repo agent is
#      running (B5 - nothing quietly came back to make B1 true the easy way).
#   C. Kill the app only, restore the real agent override, relaunch. The fresh
#      agent materializes solo's session from its state dir as a relaunchable
#      tombstone, so the carried entry restores: 'solo' is a live window again.
#      This is the whole point of keeping the entry.
#   D. Not immortal: with the agent healthy, +close 'solo' - the manifest must
#      shrink (the carried entry was adjudicated by coming back live, so a real
#      close forgets it normally).
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\session-layout-preserve.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-slpreserve-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-PaneList($target) {
    $w = Get-Win $target
    if (-not $w) { return @() }
    return @(Get-Leaves $w.tabs[0].splits)
}

function Wait-Panes($target, $count, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $panes = @(Get-PaneList $target)
        if ($panes.Count -eq $count) { return $panes }
        Start-Sleep -Milliseconds 400
    }
    return @(Get-PaneList $target)
}

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Wait-Manifest($tmp, $pred, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { if (& $pred $m) { return $m } }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Manifest-Win($m, $name) {
    if ($null -eq $m) { return $null }
    $w = @($m.windows | Where-Object { $_.ipc_name -eq $name })
    if ($w.Count -ne 1) { return $null }
    return $w[0]
}

function Manifest-Leaves($w) {
    if ($null -eq $w) { return @() }
    $out = @()
    foreach ($tab in @($w.tabs)) {
        foreach ($n in @($tab.nodes)) { if ($n.leaf) { $out += @($n.leaf) } }
    }
    return $out
}

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = '-slpreserve'

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)

    # ---- A: a healthy launch records the 'solo' window ----------------------
    Say '== A: capture a terminal window with a live agent session'
    $app = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'GUI is NOT enumerable on the interactive desktop'

    $r = Invoke-Verb @('+new-window', '--target=solo')
    Assert ($r.Code -eq 0) "A1 +new-window --target=solo exits 0 (got $($r.Code))"

    $m0 = Wait-Manifest $tmp {
        param($mm)
        $w = Manifest-Win $mm 'solo'
        if ($null -eq $w) { return $false }
        $leaves = @(Manifest-Leaves $w)
        return ($leaves.Count -eq 1 -and $leaves[0].session_id)
    } 30
    $soloWin = Manifest-Win $m0 'solo'
    $soloLeaves = @(Manifest-Leaves $soloWin)
    Assert ($soloLeaves.Count -eq 1 -and $soloLeaves[0].session_id) `
        'A2 the manifest records solo with an agent session id'
    $soloSid = if ($soloLeaves.Count -eq 1) { [string]$soloLeaves[0].session_id } else { '' }
    $soloUuid = if ($null -ne $soloWin) { [string]$soloWin.uuid } else { '' }
    Assert ($soloUuid.Length -gt 0) 'A3 the solo window carries a cross-run uuid'

    # ---- B: an agentless launch must keep solo's entry ----------------------
    Say '== B: relaunch with an unspawnable agent - the manifest must survive'
    Stop-RepoInstances
    $env:GHOSTTY_LOCAL_AGENT_BIN = (Join-Path $root 'no-such-agent.exe')
    Assert (-not (Test-Path $env:GHOSTTY_LOCAL_AGENT_BIN)) `
        'B0 the agent binary override points at nothing (setup control)'
    $mtime0 = (Get-Item (Manifest-Path $tmp)).LastWriteTimeUtc

    $agentless = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $agentless.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: agentless app has no GhozttyWindow'
    }

    # The rewrite: the blank startup window's debounced sync. Wait for the file
    # to be REWRITTEN by the new process, not merely still-present.
    $deadline = (Get-Date).AddSeconds(30)
    $rewritten = $false
    while ((Get-Date) -lt $deadline) {
        $p = Manifest-Path $tmp
        if ((Test-Path $p) -and ((Get-Item $p).LastWriteTimeUtc -gt $mtime0)) { $rewritten = $true; break }
        Start-Sleep -Milliseconds 400
    }
    Assert $rewritten 'B1 the agentless launch rewrote the manifest (the moment the bug fired)'
    Start-Sleep -Milliseconds 600

    $m1 = Read-Manifest $tmp
    $soloB = Manifest-Win $m1 'solo'
    Assert ($null -ne $soloB) 'B2 solo SURVIVED the rewrite (carried forward, not erased)'
    if ($null -ne $soloB) {
        Assert ([string]$soloB.uuid -eq $soloUuid) `
            "B3 the carried entry is the same window (uuid $soloUuid)"
        $leavesB = @(Manifest-Leaves $soloB)
        Assert ($leavesB.Count -eq 1 -and [string]$leavesB[0].session_id -eq $soloSid) `
            'B3b it still records the original agent session id'
    }
    Assert ($null -eq (Get-Win 'solo')) `
        'B4 solo has no live window (control: it truly was not restored)'
    $agentProcs = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') })
    Assert ($agentProcs.Count -eq 0) `
        "B5 no local agent is running (control, got $($agentProcs.Count))"

    # ---- C: the next launch, agent back, restores the carried window --------
    Say '== C: relaunch with the real agent - the kept entry restores'
    Stop-AppOnly
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    $healthy = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $healthy.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: healthy relaunch has no GhozttyWindow'
    }
    $soloC = @(Wait-Panes 'solo' 1 45)
    Assert ($soloC.Count -eq 1) `
        "C1 solo is a live window again - the carried entry restored (got $($soloC.Count) panes)"
    $agentProcs2 = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') })
    Assert ($agentProcs2.Count -ge 1) 'C2 the local agent is back (control)'

    # ---- D: the manifest is not immortal ------------------------------------
    Say '== D: a real close still forgets the window'
    $r = Invoke-Verb @('+close', '--target=solo')
    Assert ($r.Code -eq 0) "D0 +close --target=solo exits 0 (got $($r.Code))"
    $m2 = Wait-Manifest $tmp {
        param($mm)
        return ($null -eq (Manifest-Win $mm 'solo'))
    } 20
    Assert ($null -ne $m2 -and $null -eq (Manifest-Win $m2 'solo')) `
        'D1 the closed window left the manifest (carry-forward did not make it immortal)'

} finally {
    Say '== cleanup'
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

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this harness been run against the layout module as it now
# stands?". Red leaves the stamp alone - red stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard session-layout-preserve -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
