# +rearrange session semantics (tracker T128). A `+rearrange` layout that omits
# a pane DESTROYS that pane — it is a close by another name — so its agent
# session must END (CLOSE), exactly as `+close` on that pane would. Before T128
# the handler swapped trees with no close intent anywhere, so a dropped pane
# DETACHed and its session lingered alive, pinned and unreferenced, forever:
# the child kept running with no window anywhere that could reach it.
#
# The other half is main's invariant (`agent_recovery.sessionSpared`, the
# `e65cfa4d5` lesson): a session the NEW tree still references is never marked
# close-on-free. Section B is that guard — a pure reshuffle that keeps every
# pane must end no session at all.
#
#   A. 2 agent-backed panes -> +rearrange to a layout naming only one ->
#      the dropped pane's session ENDS; the kept pane's survives, and is
#      still LIVE (typed-into, answers) rather than a painted leftover.
#   B. 2 agent-backed panes -> +rearrange that keeps BOTH (sides swapped) ->
#      both sessions still alive and attached. No session is ended by a
#      tree swap that spares it.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN + a private IPC
# endpoint, and it ONLY ever kills ghoztty / ghoztty-agent processes launched
# from the repo zig-out (never the user's release instance).
#
#   powershell -NoProfile -File test\win32\rearrange-session-drop.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, so the fixture here
# used to put one across whatever the user was reading. The CLI calls stay on
# `Run-Cli`: none of the verbs they use can create a process.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-rearrange-drop-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
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

# Walk +list --json for the first terminal leaf.
function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Find-Pane($tree) {
    if ($null -eq $tree) { return $null }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
# Every terminal leaf in the tree, in order.
function All-Leaves($node, $acc) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') { $acc.Add($node.terminal) | Out-Null; return }
    if ($node.type -eq 'split') { All-Leaves $node.left $acc; All-Leaves $node.right $acc }
}
function Get-Leaves($tmp, $tag) {
    $acc = New-Object System.Collections.ArrayList
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($code -ne 0) { return @() }
    $tree = $null
    try { $tree = Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $tree) { return @() }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    foreach ($w in @($windows)) { foreach ($t in @($w.tabs)) { All-Leaves $t.splits $acc } }
    return @($acc)
}

# Poll +list --json until a terminal pane appears; returns the leaf or $null.
function Wait-FirstPane($tmp, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Run-Cli '+list --json' "$tmp\list.json" 10
        if ($code -eq 0) {
            $tree = $null
            try { $tree = Out-Text "$tmp\list.json" | ConvertFrom-Json } catch {}
            $pane = Find-Pane $tree
            if ($null -ne $pane) { return $pane }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# The rows of `+sessions --json`, or @() if the CLI failed / no agent / empty.
function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Count-Alive($rows) { return @($rows | Where-Object { $_.alive -eq $true }).Count }

# Poll +sessions until the alive-session count equals $target (or timeout).
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Count-Alive $rows) -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

# One hermetic GUI launch (fresh LOCALAPPDATA + agent-bin override) with a
# second agent-backed pane split off it. Returns
# @{ Tmp; PaneId; SessId; SibId; SibSess; Ok }.
function Start-TwoPane($label) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default) - the dropped pane's SESSION is what this script asserts about.
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t128-rearrange'))
    $pane = Wait-FirstPane $tmp 25
    $paneId = if ($null -ne $pane) { $pane.id } else { '' }
    $rows = Wait-AliveCount $tmp 'setup' 1 18
    $sid = ''
    if ((Count-Alive $rows) -eq 1) { $sid = (@($rows | Where-Object { $_.alive -eq $true })[0]).id }
    Run-Cli '+split --direction=right --name=t128sib' "$tmp\split.txt" 20 | Out-Null
    $rows2 = Wait-AliveCount $tmp 'split' 2 20
    $sibSess = ''
    foreach ($r in @($rows2 | Where-Object { $_.alive -eq $true })) {
        if ($r.id -ne $sid) { $sibSess = $r.id }
    }
    return @{
        Tmp = $tmp; PaneId = $paneId; SessId = $sid; SibSess = $sibSess
        Ok = ($paneId -ne '' -and $sid -ne '' -and $sibSess -ne '' -and (Count-Alive $rows2) -eq 2)
    }
}

# PS 5.1 native-arg passing eats embedded quotes; escape them for Win32.
function Send-Rearrange($tmp, $tag, $layout) {
    return (Run-Cli ("+rearrange --target=window-1 --layout=" + ($layout -replace '"', '\"')) "$tmp\rearrange-$tag.txt" 15)
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# A private IPC endpoint: this script rearranges and closes panes, so pointed at
# the user's installed release it would destroy their work.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
[void](Set-GhozttyTestIsolation -Tag 't128')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: a pane the new layout drops ends its agent session"
# ============================================================================
$a = Start-TwoPane 'drop'
Assert "A1 two agent-backed panes (2 alive sessions)" $a.Ok
Assert-GhozttyIsolated -Exe $Exe
$codeA = Send-Rearrange $a.Tmp 'drop' ('{"pane":"' + $a.PaneId + '"}')
Assert "A2 +rearrange succeeded" ($codeA -eq 0)
Start-Sleep -Seconds 2
$leavesA = Get-Leaves $a.Tmp 'after'
Assert "A3 the window is down to one pane" (@($leavesA).Count -eq 1)
$rowsA = Wait-AliveCount $a.Tmp 'after' 1 20
Assert "A4 exactly one session survives the drop" ((Count-Alive $rowsA) -eq 1)
$survA = @($rowsA | Where-Object { $_.alive -eq $true }) | Select-Object -First 1
Assert "A5 the survivor is the KEPT pane's session, not the dropped one" (
    $null -ne $survA -and $survA.id -eq $a.SessId)
Assert "A6 the dropped pane's session is gone from the roster" (
    @($rowsA | Where-Object { $_.id -eq $a.SibSess -and $_.alive -eq $true }).Count -eq 0)
# T532: a surviving pane must be LIVE, not a picture of one.
Assert "A7 the kept pane still answers input" (Test-PaneLive -Exe $Exe -Target $a.PaneId)
Stop-TestProcs

# ============================================================================
"== B: a rearrange that keeps every pane ends no session (sessionSpared)"
# ============================================================================
$b = Start-TwoPane 'keep'
Assert "B1 two agent-backed panes (2 alive sessions)" $b.Ok
$swapped = '{"direction":"horizontal","ratio":40,"left":{"pane":"t128sib"},"right":{"pane":"' + $b.PaneId + '"}}'
$codeB = Send-Rearrange $b.Tmp 'keep' $swapped
Assert "B2 +rearrange succeeded" ($codeB -eq 0)
Start-Sleep -Seconds 3
$leavesB = Get-Leaves $b.Tmp 'after'
Assert "B3 both panes are still in the tree" (@($leavesB).Count -eq 2)
$rowsB = Get-Sessions $b.Tmp 'after'
Assert "B4 both sessions are still alive" ((Count-Alive $rowsB) -eq 2)
Assert "B5 both are still attached to a viewer" (
    @($rowsB | Where-Object { $_.alive -eq $true -and $_.attached -eq $true }).Count -eq 2)
Assert "B6 the reshuffled pane still answers input" (Test-PaneLive -Exe $Exe -Target 't128sib')
Stop-TestProcs

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
