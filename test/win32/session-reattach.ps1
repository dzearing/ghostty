# Session-layout manifest capture (tracker T89f1 — the WRITE half of same-PID
# re-attach restore). Proves the win32 viewer-side manifest
# (%LOCALAPPDATA%\ghoztty\session-layout[-debug].json) is captured and
# atomically written as the live window/tab/split topology changes, so a later
# launch (T89f2) has an accurate blueprint to rebuild + re-ATTACH from.
#
# This is the DEBOUNCED-WRITE path: each mutation arms a 250ms timer on the GUI
# thread; the assertions poll the on-disk manifest until it reflects the change.
# The RESTORE side (relaunch, same PIDs, scrollback, titles) is T89f2, which
# grows this script's section F onward.
#
#   A. Startup window -> manifest has one window / one tab / one leaf whose
#      session_id matches the single live agent session (+sessions).
#   B. +split -> that tab's flat node array grows to a split + two leaves, both
#      leaf session_ids matching the two live sessions; the split records a
#      layout + an in-range ratio.
#   C. +new-window --target=second -> manifest has two windows; the second
#      carries its IPC name.
#   D. +rename --title -> the target window's title_override is captured.
#   E. Every captured window has a real frame (w/h > 0) and a boolean maximized.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (never
# the user's real release instance, which uses a different IPC socket + agent
# lineage).
#
#   powershell -NoProfile -File test\win32\session-reattach.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-session-reattach-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# Walk +list --json for the first terminal leaf id.
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
function Alive-Ids($rows) {
    return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
}

# ---- Manifest helpers (the T89f artifact under test) -----------------------

# Debug builds write the -debug filename (session_layout.layoutPath).
function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

# Poll the manifest until $pred returns $true for the parsed object (or timeout).
# Returns the last parsed manifest (possibly not satisfying $pred).
function Wait-Manifest($tmp, $pred, $timeoutSec = 8) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 300
    }
    return $m
}

# All leaf session_ids across a manifest window's tabs, in node order.
function Leaf-Sids($win) {
    $ids = @()
    foreach ($t in @($win.tabs)) {
        foreach ($n in @($t.nodes)) {
            if ($null -ne $n.leaf -and $n.leaf.session_id) { $ids += $n.leaf.session_id }
        }
    }
    return , $ids  # unary comma: never let PS unwrap a 1-element array to a scalar
}
function Count-Splits($win) {
    $c = 0
    foreach ($t in @($win.tabs)) {
        foreach ($n in @($t.nodes)) { if ($null -ne $n.split) { $c++ } }
    }
    return $c
}

# One hermetic GUI launch (fresh LOCALAPPDATA + agent-bin override).
function Start-Backed($label, $title) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @("--title=$title") | Out-Null
    $pane = Wait-FirstPane $tmp 25
    $rows = Wait-AliveCount $tmp 'setup' 1 18
    $ok = ($null -ne $pane -and (Count-Alive $rows) -eq 1)
    return @{ Tmp = $tmp; Ok = $ok }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ============================================================================
"== A: startup window is captured with its agent session id"
# ============================================================================
$g = Start-Backed 'capture' 't89f-reattach'
Assert "A1 startup pane is agent-backed (one live session)" $g.Ok
$tmp = $g.Tmp
$sid0 = @(Alive-Ids (Get-Sessions $tmp 'a'))[0]

$mA = Wait-Manifest $tmp { param($m) @($m.windows).Count -ge 1 -and (Leaf-Sids $m.windows[0]).Count -ge 1 } 10
Assert "A2 manifest written with one window" ($null -ne $mA -and @($mA.windows).Count -eq 1)
Assert "A3 window has one tab with one leaf" (
    $null -ne $mA -and @($mA.windows[0].tabs).Count -eq 1 -and @($mA.windows[0].tabs[0].nodes).Count -eq 1)
$sidsA = if ($null -ne $mA) { Leaf-Sids $mA.windows[0] } else { @() }
Assert "A4 captured leaf session_id matches the live agent session" (
    $sidsA.Count -eq 1 -and $sid0 -and $sidsA[0] -eq $sid0)
Assert "A5 manifest declares schema version 1" ($null -ne $mA -and $mA.version -eq 1)

# ============================================================================
"== B: +split grows the captured tree to a split + two leaves"
# ============================================================================
Run-Cli '+split --direction=right --name=f89sib' "$tmp\split.txt" 15 | Out-Null
$rowsB = Wait-AliveCount $tmp 'b' 2 15
Assert "B1 +split opened a second agent-backed session (2 alive)" ((Count-Alive $rowsB) -eq 2)
$aliveB = @(Alive-Ids $rowsB)
$mB = Wait-Manifest $tmp { param($m) (Leaf-Sids $m.windows[0]).Count -ge 2 } 10
$sidsB = if ($null -ne $mB) { Leaf-Sids $mB.windows[0] } else { @() }
Assert "B2 the tab tree now records two leaves" ($sidsB.Count -eq 2)
Assert "B3 the tree records exactly one split node" ($null -ne $mB -and (Count-Splits $mB.windows[0]) -eq 1)
$split = $null
if ($null -ne $mB) { foreach ($n in $mB.windows[0].tabs[0].nodes) { if ($n.split) { $split = $n.split } } }
Assert "B4 split records a layout (horizontal|vertical)" (
    $null -ne $split -and @('horizontal', 'vertical') -contains $split.layout)
Assert "B5 split records an in-range ratio" (
    $null -ne $split -and $split.ratio -gt 0.0 -and $split.ratio -lt 1.0)
Assert "B6 both captured leaf session_ids are live agent sessions" (
    $sidsB.Count -eq 2 -and ($aliveB -contains $sidsB[0]) -and ($aliveB -contains $sidsB[1]))

# ============================================================================
"== C: +new-window adds a second captured window with its IPC name"
# ============================================================================
Run-Cli '+new-window --target=second' "$tmp\neww.txt" 15 | Out-Null
$mC = Wait-Manifest $tmp { param($m) @($m.windows).Count -ge 2 } 10
Assert "C1 manifest now has two windows" ($null -ne $mC -and @($mC.windows).Count -eq 2)
$second = @($mC.windows | Where-Object { $_.ipc_name -eq 'second' })
Assert "C2 the second window carries its IPC name" ($second.Count -eq 1)
Assert "C3 the second window's id equals its IPC name" (
    $second.Count -eq 1 -and $second[0].id -eq 'second')

# ============================================================================
"== D: +rename --title captures the window title pin"
# ============================================================================
Run-Cli '+rename --target=second --title=HelloTitle' "$tmp\rename.txt" 12 | Out-Null
$mD = Wait-Manifest $tmp {
    param($m)
    $w = @($m.windows | Where-Object { $_.ipc_name -eq 'second' })
    $w.Count -eq 1 -and $w[0].title_override -eq 'HelloTitle'
} 10
$w2 = @($mD.windows | Where-Object { $_.ipc_name -eq 'second' })
Assert "D1 the title pin was captured into title_override" (
    $w2.Count -eq 1 -and $w2[0].title_override -eq 'HelloTitle')

# ============================================================================
"== E: every captured window has a real frame + boolean maximized"
# ============================================================================
$mE = Read-Manifest $tmp
$framesOk = $true
$maxOk = $true
if ($null -ne $mE) {
    foreach ($w in @($mE.windows)) {
        if ($null -eq $w.frame -or $w.frame.w -le 0 -or $w.frame.h -le 0) { $framesOk = $false }
        if ($w.maximized -isnot [bool]) { $maxOk = $false }
    }
} else { $framesOk = $false; $maxOk = $false }
Assert "E1 every window records a frame with positive width/height" $framesOk
Assert "E2 every window records a boolean maximized flag" $maxOk

# ============================================================================
if ($script:failures -gt 0) {
    "== DIAG: final manifest =="
    $dp = Manifest-Path $tmp
    if (Test-Path $dp) { Get-Content $dp -Raw } else { "NO MANIFEST FILE at $dp" }
    "== DIAG: sid0=$sid0"
}

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
