# T158 acceptance: every launch in test\win32 says what it wants session
# persistence to do, and the flag that says "don't restore" actually stops the
# restore.
#
#   powershell -NoProfile -File test\win32\persistence-flag.ps1
#
# THE DEFECT THIS GUARDS. Session persistence is ON by default, so a GUI
# launched without `--session-persistence=false` restores whatever panes the
# last launch left behind - and the script's own setup assertions then describe
# someone else's layout. It is not a dirty-box problem: each launch writes the
# manifest the NEXT one restores, so a multi-section script poisons itself on a
# clean machine. T131 hit it in pane-banner.ps1 and T155 hit it again in
# split-dim.ps1 and split-zoom-nav.ps1, where both scripts failed
# `default setup: 2 visible panes` against a build whose geometry was
# independently verified correct. The cost is misattribution: it presents as a
# product regression in whatever change happens to be in flight.
#
# WHAT IS ASSERTED
#
#   A (sweep)   every launch of the app under test in test\win32 declares its
#               intent - by passing the flag, by passing something built from
#               it, by every caller of its helper passing it, or by a
#               `# persistence: <reason>` marker for a site where none of those
#               fit (a CLI verb, a throwaway-LOCALAPPDATA launch, a forward-and-
#               exit second instance).
#   B (teeth)   the sweep can say NO. Synthetic scripts in a temp directory
#               exercise each declaration form and one undeclared launch, so a
#               sweep that has quietly stopped finding launch sites at all fails
#               here instead of reporting a clean A.
#   C (control) the class negative control, live: build a two-pane window under
#               persistence, kill the app, and relaunch twice. Without the flag
#               the panes come back (the hazard is real, and the restored pane
#               is LIVE, not a picture); with `--session-persistence=false` they
#               do not (the flag every other script relies on works).
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Section C runs on the BACKGROUND test desktop.
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
$root = Join-Path $env:TEMP "ghoztty-persistence-flag-$PID"

. (Join-Path $PSScriptRoot 'lib\PersistenceSweep.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: "attached is not alive" - section C's restored pane is proved by typing
# into it, not by finding it in a tree.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T350: refuse a non-debug zig-out before anything is launched.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
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

# Kill ONLY the app: the detached agent keeps its PTYs, which is the scenario a
# restore comes out of (quit / crash / upgrade).
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
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

function Count-Leaves($node) {
    if (-not $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}

# Panes in the window whose target is $target, or -1 when no such window.
function Get-PaneCount($target) {
    foreach ($w in Get-Windows) {
        if ([string]$w.target -ne $target) { continue }
        $n = 0
        foreach ($t in @($w.tabs)) { $n += (Count-Leaves $t.splits) }
        return $n
    }
    return -1
}

function Wait-PaneCount($target, $count, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $seen = -1
    while ((Get-Date) -lt $deadline) {
        $seen = Get-PaneCount $target
        if ($seen -eq $count) { return $seen }
        Start-Sleep -Milliseconds 400
    }
    return $seen
}

# ---------------------------------------------------------------------------
# A: the sweep over the real suite
# ---------------------------------------------------------------------------
Say '== A: every launch site in test\win32 declares its persistence intent'
$sites = @(Get-GhozttyLaunchSites -Root $PSScriptRoot)
Assert ($sites.Count -ge 100) "A0 the sweep found the suite's launch sites (found $($sites.Count))"
$undeclared = @($sites | Where-Object { -not $_.Declared })
foreach ($u in $undeclared) {
    Say ("      undeclared: {0}:{1}  {2}" -f $u.File, $u.Line, $u.Stmt)
}
Assert ($undeclared.Count -eq 0) `
    "A1 no launch leaves persistence unstated (undeclared: $($undeclared.Count) of $($sites.Count))"
$byHow = $sites | Group-Object { ($_.How -split ':')[0] } | ForEach-Object { "$($_.Name)=$($_.Count)" }
Say ("      declared by: " + ($byHow -join ', '))

# ---------------------------------------------------------------------------
# B: the sweep's own teeth
# ---------------------------------------------------------------------------
Say '== B: the sweep can say no'
$fix = Join-Path $root 'sweepfix'
New-Item -ItemType Directory -Force $fix | Out-Null

# The fixtures spell the launch call as @@LAUNCH@@ and substitute it below,
# because section A sweeps THIS file too: a literal `Start-OnTestDesktop` inside
# a here-string reads to the sweep as an undeclared launch site, and the teeth
# check would fail the very assertion it exists to protect.
$literal = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--session-persistence=false')
'@
$viaVar = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$launchArgs = @('--session-persistence=false') + $extra
$sp = @{ Exe = $exe; Arguments = $launchArgs }
$app = @@LAUNCH@@ @sp
'@
$viaMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: on (default) - a reason a reader can weigh.
$app = @@LAUNCH@@ -Exe $exe
'@
$viaCallers = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
function Launch-Gui([string[]]$ExtraArgs) {
    return (@@LAUNCH@@ -Exe $exe -Arguments $ExtraArgs)
}
$a = Launch-Gui @('--session-persistence=false')
$b = Launch-Gui @('--session-persistence=true')
'@
$undeclaredFix = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@
$otherImage = @'
$agentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
$a = @@LAUNCH@@ -Exe $agentExe -Arguments @('--listen', '127.0.0.1:7777')
'@
$badValue = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--session-persistence=nope')
'@

foreach ($pair in @(
        @{ Name = 'literal.ps1'; Body = $literal },
        @{ Name = 'viavar.ps1'; Body = $viaVar },
        @{ Name = 'viamarker.ps1'; Body = $viaMarker },
        @{ Name = 'viacallers.ps1'; Body = $viaCallers },
        @{ Name = 'undeclared.ps1'; Body = $undeclaredFix },
        @{ Name = 'otherimage.ps1'; Body = $otherImage },
        @{ Name = 'badvalue.ps1'; Body = $badValue })) {
    $body = $pair.Body -replace '@@LAUNCH@@', 'Start-OnTestDesktop'
    Set-Content -Path (Join-Path $fix $pair.Name) -Value $body -Encoding ASCII
}

$fixSites = @(Get-GhozttyLaunchSites -Root $fix)
function Fix-How($file) {
    $row = $fixSites | Where-Object { $_.File -eq $file } | Select-Object -First 1
    if (-not $row) { return '<no site found>' }
    return $row.How
}
Assert ((Fix-How 'literal.ps1') -eq 'literal') "B1 a flag in the launch statement declares it (got '$(Fix-How 'literal.ps1')')"
Assert ((Fix-How 'viavar.ps1') -like 'var:*') "B2 a flag reached through a splat declares it (got '$(Fix-How 'viavar.ps1')')"
Assert ((Fix-How 'viamarker.ps1') -eq 'marker') "B3 a '# persistence:' marker declares it (got '$(Fix-How 'viamarker.ps1')')"
Assert ((Fix-How 'viacallers.ps1') -like 'callers:*') "B4 a helper whose every caller passes the flag declares it (got '$(Fix-How 'viacallers.ps1')')"
$bad = @($fixSites | Where-Object { $_.File -eq 'undeclared.ps1' })
Assert ($bad.Count -eq 1 -and -not $bad[0].Declared) `
    "B5 a launch that never mentions persistence is reported UNDECLARED (got $($bad.Count) site(s), declared=$(if ($bad.Count) { $bad[0].Declared } else { 'n/a' }))"
Assert (@($fixSites | Where-Object { $_.File -eq 'otherimage.ps1' }).Count -eq 0) `
    'B6 a launch of a different image (the agent) is not swept at all'
# A value `parseBool` rejects is logged and dropped, so the setting keeps its
# default: the launch looks explicit and restores anyway. That must not read as
# a declaration.
$badRow = @($fixSites | Where-Object { $_.File -eq 'badvalue.ps1' })
Assert ($badRow.Count -eq 1 -and -not $badRow[0].Declared) `
    "B7 a flag with a value the CLI rejects is NOT a declaration (got $($badRow.Count) site(s), declared=$(if ($badRow.Count) { $badRow[0].Declared } else { 'n/a' }))"

# ---------------------------------------------------------------------------
# C: the class negative control, live
# ---------------------------------------------------------------------------
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = '-t158flag'

Stop-RepoInstances
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'C0 ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'C0 ghoztty-agent exe exists in zig-out'

    Say '== C1: build a two-pane window under persistence'
    # persistence: on, EXPLICITLY - this arm is the fixture the two relaunches
    # below are measured against, so it must not depend on what the default
    # happens to be.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') `
        -StdErr (Join-Path $root 'app1.err.txt')
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    $r = Invoke-Verb @('+new-window', '--target=t158-pair')
    Assert ($r.Code -eq 0) "C1a +new-window --target=t158-pair exits 0 (got $($r.Code))"
    $r = Invoke-Verb @('+split', '--target=t158-pair', '--direction=right')
    Assert ($r.Code -eq 0) "C1b +split exits 0 (got $($r.Code))"
    $panes = Wait-PaneCount 't158-pair' 2
    Assert ($panes -eq 2) "C1c the fixture window has 2 panes (got $panes)"

    Say '== C2: relaunch WITHOUT the flag - the panes come back'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    # persistence: on (default) - this is the hazard being demonstrated.
    $restored = Start-OnTestDesktop -Exe $exe -StdErr (Join-Path $root 'app2.err.txt')
    if ((Wait-TestWindow -ProcessId $restored.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: relaunched app has no GhozttyWindow'
    }
    $back = Wait-PaneCount 't158-pair' 2 60
    Assert ($back -eq 2) `
        "C2a a launch with no persistence flag RESTORES the previous run's window (2 panes, got $back)"
    # T652: attached is not alive. A restored pane that came back as a frozen
    # picture satisfies every assertion above, so type into it and require an
    # answer - otherwise C3 could be passing against a restore that never worked.
    Assert (Test-PaneLive -Exe $exe -Target 't158-pair' -Tmp $root -Tag 'T158') `
        'C2b the restored pane is LIVE: input reaches its child and output returns'

    Say '== C3: relaunch WITH --session-persistence=false - they do not'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    $clean = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') `
        -StdErr (Join-Path $root 'app3.err.txt')
    if ((Wait-TestWindow -ProcessId $clean.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: the non-persistent app has no GhozttyWindow'
    }
    # Give the restore the same wall-clock it had in C2 before concluding it did
    # not happen: an assertion that fires immediately would pass on a slow box
    # for the wrong reason.
    $late = Wait-PaneCount 't158-pair' 2 20
    Assert ($late -eq -1) `
        "C3a --session-persistence=false restores nothing (expected no t158-pair window, got $late pane(s))"
    $wins = @(Get-Windows)
    Assert ($wins.Count -eq 1) `
        "C3b the non-persistent launch comes up with exactly its own window (got $($wins.Count))"

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

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
