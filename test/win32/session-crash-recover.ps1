# Crash-orphaned window recovery (tracker T194) - launch-time restore consults
# the AGENT's authoritative layouts, not just the app-local manifest.
#
# The defect: `App.restoreSessionLayout` trusted
# %LOCALAPPDATA%\ghoztty\session-layout[-debug].json alone and bailed the moment
# it was absent or empty. After an app CRASH that file can REGRESS - a relaunch
# that rebuilt nothing then overwrote it with the one blank window it did open -
# while the ever-running ghoztty-agent still holds a layout blob for every window
# whose PTYs are alive. The windows were simply lost, with their processes still
# running and nothing on screen pointing at them.
#
# The fix has two halves. The PUSH half already shipped (T334/T338 - proven by
# layout-blobs.ps1); this script is the oracle for the RECONCILE half: restore
# always pulls GET_LAYOUTS, unions it with the local manifest (local wins on key
# collision, agent-only windows are ADDED), rebuilds the union, and ADOPTS the
# recovered entries back into the local manifest.
#
#   A. Build a 2-window / 3-pane layout on a hermetic instance and let both the
#      manifest and the agent's blob store settle.
#   B. CRASH: hard-kill only the app, then DELETE the local manifest. The agent
#      keeps all 3 PTYs and both layout records - this is the exact state the
#      row describes, forced rather than waited for.
#   C. RECOVER: relaunch and assert both windows and all 3 panes come back by
#      re-ATTACHing the SAME sessions with the SAME shell pids - not fresh
#      OPENs, and not a blank startup window.
#   D. ADOPT: the local manifest is re-written from nothing back to the full
#      2-window / 3-session layout, so the NEXT launch needs no round trip.
#
# C is the assertion that was RED before T194 (restore returned false on the
# missing manifest and the app opened one blank window). `-NegativeControl`
# inverts it, so a run that scores this build's recovery as a failure is
# available on demand.
#
# Non-interactive and headless-safe: no foreground grabs and no synthetic input,
# so it needs no background-desktop harness. Fully hermetic: a per-run
# $env:LOCALAPPDATA, a per-run GHOSTTY_LOCAL_AGENT_BIN, a private IPC pipe
# suffix (T441), and it ONLY ever kills ghoztty / ghoztty-agent processes
# launched from the repo zig-out - never the user's installed release.
#
#   powershell -NoProfile -File test\win32\session-crash-recover.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-crash-recover-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

# Kill ONLY the zig-out GUI. The detached agent survives with every PTY - the
# crash class this whole script is about.
function Stop-GuiOnly {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Start-App($title) {
    # persistence: on (default) - session persistence IS this script's subject.
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
        "--title=$title", '--window-width=100', '--window-height=30') | Out-Null
}

# --- the agent's session roster ---------------------------------------------

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Rows($rows) { return @($rows | Where-Object { $_.alive -eq $true }) }
function Alive-Ids($rows) { return @(Alive-Rows $rows | ForEach-Object { $_.id }) }
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if (@(Alive-Ids $rows).Count -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

# id -> child pid, so "the SAME process came back" is checkable rather than
# inferred from the id alone.
function Pid-Map($rows) {
    $m = @{}
    foreach ($r in (Alive-Rows $rows)) { $m[[string]$r.id] = [int]$r.pid }
    return $m
}

# --- the agent's layout blob store ------------------------------------------

function Get-Layouts($tmp) {
    $path = Join-Path $tmp 'ghoztty\local-agent-debug\layouts.json'
    if (-not (Test-Path $path)) { return @() }
    $doc = $null
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return @() }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return @() }
    return @($doc.layouts)
}
function Wait-Records($tmp, $n, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $recs = @()
    while ((Get-Date) -lt $deadline) {
        $recs = Get-Layouts $tmp
        if (@($recs).Count -eq $n) { return @($recs) }
        Start-Sleep -Milliseconds 400
    }
    return @($recs)
}

# --- the app-local manifest (the thing we DELETE) ----------------------------

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }
function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}
# Every leaf session_id across every window, in order. The unary comma keeps a
# one-element result an array (PS 5.1 unrolls a function's array return).
function All-Sids($m) {
    $ids = @()
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf -and $n.leaf.session_id) { $ids += $n.leaf.session_id }
            }
        }
    }
    return , $ids
}
function Wait-Manifest($tmp, $pred, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 400
    }
    return $m
}

# --- the live topology, read back through the CLI ----------------------------

function Get-Tree($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($code -ne 0) { return $null }
    $tree = $null
    try { $tree = Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json } catch {}
    return $tree
}
function Tree-Windows($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Count-Leaf-Nodes($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    if ($node.type -eq 'split') { return (Count-Leaf-Nodes $node.left) + (Count-Leaf-Nodes $node.right) }
    return 0
}
function Count-Leaves($tree) {
    $c = 0
    foreach ($w in (Tree-Windows $tree)) {
        foreach ($t in @($w.tabs)) { $c += (Count-Leaf-Nodes $t.splits) }
    }
    return $c
}
# Poll until the live tree has $wins windows and $panes panes; returns the last
# reading either way so a failed assertion still shows what was there.
function Wait-Topology($tmp, $tag, $wins, $panes, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $tree = $null
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tmp $tag
        if ((Tree-Windows $tree).Count -eq $wins -and (Count-Leaves $tree) -eq $panes) { return $tree }
        Start-Sleep -Milliseconds 500
    }
    return $tree
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# T652: the "attached is not alive" oracle. Read its header before adding an
# assertion about a recovered pane.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
[void](Set-GhozttyTestIsolation -Tag 'crashrec')
Assert-GhozttyPrivateEndpoint -Exe $Exe

try {

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ============================================================================
"== A: a 2-window / 3-pane layout, mirrored to both the manifest and the agent"
# ============================================================================
Start-App 't194-crash-recover'
Wait-AliveCount $tmp 'a0' 1 30 | Out-Null
Assert-GhozttyIsolated -Exe $Exe

Run-Cli '+split --direction=right --name=cr-sib' "$tmp\split.txt" 20 | Out-Null
Run-Cli '+new-window --target=cr-second' "$tmp\newwin.txt" 25 | Out-Null

$rowsA = Wait-AliveCount $tmp 'a' 3 30
$idsA = @(Alive-Ids $rowsA)
Assert "A1 three agent-backed sessions are alive" ($idsA.Count -eq 3)

$treeA = Wait-Topology $tmp 'a' 2 3 40
Assert "A2 the live layout is two windows / three panes" (
    (Tree-Windows $treeA).Count -eq 2 -and (Count-Leaves $treeA) -eq 3)

$mA = Wait-Manifest $tmp {
    param($m) @($m.windows).Count -eq 2 -and (All-Sids $m).Count -eq 3
} 30
Assert "A3 the local manifest holds the full layout (the source that will be lost)" (
    $null -ne $mA -and @($mA.windows).Count -eq 2 -and (All-Sids $mA).Count -eq 3)

$recsA = Wait-Records $tmp 2 30
Assert "A4 the agent holds a layout record per window (the surviving source)" (
    @($recsA).Count -eq 2)

# ============================================================================
"== B: CRASH - kill the app, then delete the local manifest"
# ============================================================================
$pidsBefore = Pid-Map $rowsA
Assert "B1 every live session reported a shell pid before the crash" (
    $pidsBefore.Count -eq 3 -and @($pidsBefore.Values | Where-Object { $_ -gt 0 }).Count -eq 3)

Stop-GuiOnly
Remove-Item (Manifest-Path $tmp) -Force -ErrorAction SilentlyContinue
Assert "B2 the local manifest really is gone (restore has nothing local to read)" (
    -not (Test-Path (Manifest-Path $tmp)))

$rowsB = Wait-AliveCount $tmp 'b' 3 25
$idsB = @(Alive-Ids $rowsB)
Assert "B3 the agent kept all three PTYs alive with no viewer running" (
    $idsB.Count -eq 3 -and @($idsA | Where-Object { $idsB -contains $_ }).Count -eq 3)
Assert "B4 the agent still holds both layout records" (@(Get-Layouts $tmp).Count -eq 2)

# ============================================================================
"== C: RECOVER - the relaunch rebuilds both windows from the agent's copy"
# ============================================================================
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
Start-App 't194-recovered'

$treeC = Wait-Topology $tmp 'c' 2 3 45
$winsC = (Tree-Windows $treeC).Count
$panesC = (Count-Leaves $treeC)
"  (post-relaunch topology: $winsC window(s) / $panesC pane(s))"

$rowsC = Wait-AliveCount $tmp 'c' 3 30
$idsC = @(Alive-Ids $rowsC)
$pidsAfter = Pid-Map $rowsC
$sameThree = ($idsC.Count -eq 3 -and @($idsA | Where-Object { $idsC -contains $_ }).Count -eq 3)
$samePids = $sameThree
foreach ($id in $pidsBefore.Keys) {
    if (-not $pidsAfter.ContainsKey($id) -or $pidsAfter[$id] -ne $pidsBefore[$id]) { $samePids = $false }
}

if ($NegativeControl) {
    # Invert the claim T194 exists for. A control that PASSES here is scoring a
    # build that lost the user's windows to a deleted manifest.
    "NEGATIVE CONTROL: asserting the relaunch did NOT recover the windows - this run MUST fail"
    Assert "C1 the relaunch opened a blank window instead of recovering (inverted)" (
        -not ($winsC -eq 2 -and $panesC -eq 3))
} else {
    Assert "C1 the relaunch rebuilt both windows and all three panes" (
        $winsC -eq 2 -and $panesC -eq 3)
    Assert "C2 the same three sessions are alive (ATTACH, not re-OPEN)" $sameThree
    Assert "C3 every recovered pane came back on its ORIGINAL shell pid" $samePids
    Assert "C4 no fourth session was opened (no blank startup window)" ($idsC.Count -eq 3)
    # C5 (T652): ATTACHED IS NOT ALIVE. C1-C4 are all satisfied by a pane that
    # came back as a frozen picture: a topology is app-side bookkeeping, and an
    # alive session id with its original pid is the AGENT's view of a child that
    # may no longer be wired to anything on screen. That was the shape of the
    # 2026-08-06 regression, where every recovered pane painted correctly and
    # accepted nothing. Type into one pane in EACH recovered window, because a
    # window is where the attach is wired and one working window says nothing
    # about the other.
    Assert "C5 a recovered pane in the split window is LIVE (input in, new output back)" (
        Test-PaneLive -Exe $Exe -Target 'cr-sib' -Tmp $tmp -Tag 'CRA')
    Assert "C6 a recovered pane in the second window is LIVE (input in, new output back)" (
        Test-PaneLive -Exe $Exe -Target 'cr-second' -Tmp $tmp -Tag 'CRB')
}

# ============================================================================
"== D: ADOPT - the recovered windows are written back into the local manifest"
# ============================================================================
# Without this the next launch would have to recover them all over again, and a
# launch with no agent would lose them for good. Mac's
# `SessionLayoutManifest.adopt(_:)`; on win32 the manifest is regenerated from
# the live windows, so restore arms the debounced sync and this is what lands.
$mD = Wait-Manifest $tmp {
    param($m) @($m.windows).Count -eq 2 -and (All-Sids $m).Count -eq 3
} 30
$sidsD = if ($null -ne $mD) { @(All-Sids $mD) } else { @() }
if (-not $NegativeControl) {
    Assert "D1 the manifest went from ABSENT back to two windows" (
        $null -ne $mD -and @($mD.windows).Count -eq 2)
    Assert "D2 it records all three recovered session ids" (
        $sidsD.Count -eq 3 -and @($idsA | Where-Object { $sidsD -contains $_ }).Count -eq 3)
    Assert "D3 the agent still holds exactly two records (no key churn on recovery)" (
        @(Get-Layouts $tmp).Count -eq 2)
}

if ($script:failures -gt 0) {
    # Summarised, never dumped: a leaf carries a base64 screen snapshot, so
    # printing the manifest raw buries the failure under ~16KB of payload.
    $dp = Manifest-Path $tmp
    $mDiag = Read-Manifest $tmp
    if ($null -eq $mDiag) { "== DIAG: no readable manifest at $dp" }
    else {
        "== DIAG: manifest has $(@($mDiag.windows).Count) window(s), sids=$(@(All-Sids $mDiag) -join ' ')"
    }
    "== DIAG: session ids before=$($idsA -join ' ') after=$($idsC -join ' ')"
    "== DIAG: full manifest preserved at $dp"
}

} finally {
    "== cleanup"
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { "artifacts preserved at $root" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes assertions)"; exit 0 }
else { "$($script:failures) FAILURE(S) / $script:passes passed"; exit 1 }
