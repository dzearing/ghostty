# Session-layout re-attach (tracker T89f - same-PID restore). The WRITE half
# (T89f1) proves the win32 viewer-side manifest
# (%LOCALAPPDATA%\ghoztty\session-layout[-debug].json) is captured + atomically
# written as the topology changes; the RESTORE half (T89f2, section F) proves a
# relaunch rebuilds those windows and re-ATTACHes each pane to the session the
# ghoztty-agent kept alive across the app's death.
#
# A-E are the DEBOUNCED-WRITE path: each mutation arms a 250ms timer on the GUI
# thread; the assertions poll the on-disk manifest until it reflects the change.
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
#   F. RESTORE (T89f2): with the A-E 2-window/3-pane layout live, mark the split
#      pane's scrollback, KILL ONLY the app (the detached agent keeps every
#      PTY), relaunch, and assert restore rebuilt exactly 2 windows / 3 panes,
#      re-ATTACHed the SAME 3 sessions (no new OPENs), and brought back the
#      pane's IPC name + scrollback and the window title pin.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA, a per-run GHOSTTY_LOCAL_AGENT_BIN, a private IPC
# pipe suffix, and it ONLY ever kills ghoztty / ghoztty-agent processes launched
# from the repo zig-out (never the user's real release instance, which uses a
# different IPC endpoint + agent lineage).
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so
# it never takes the user's foreground - asserted at the end, not assumed. A-E
# and F1-F9 drive everything through the `+...` CLI and the on-disk manifest, so
# the migration only moves the three GUI LAUNCHES onto the test desktop; those
# CLI calls stay on cmd.exe, being console-only and windowless.
#
# F10/F11 WERE RED ON THE TEST DESKTOP WHEN THIS SCRIPT WAS MIGRATED, AND THAT
# WAS A PRODUCT BUG (T223), NOT A HARNESS FAULT. FIXED 2026-08-04; they are green
# now and must stay that way. `App.performDeferredFocus` used to BYPASS the T105
# guard off the input desktop - `shouldPerformDeferredFocus(false, ...)` returned
# true unconditionally, because a background desktop has no foreground window and
# guarding on one would otherwise drop every focus change (T211's fix, which this
# whole harness rests on). The expectation going in was that the storm needed
# foreground activation and so could not reproduce there. It did: measured
# focusFlips 43 and 39 in 3s, against a pre-T105 baseline of 36 and a post-fix 0.
# Since `onInputDesktop()` is also false on a LOCKED workstation, behind a secure
# desktop, and in a disconnected RDP session, that was a real user-facing path.
# T223 swapped the off-desktop proxy from `GetForegroundWindow` (input-desktop
# scoped, so always null there) to `GetActiveWindow` (message-queue scoped, so it
# still names one of our windows), which keeps focus moving AND restores the
# guard. Both counts read 0 now. These two assertions remain the oracle for that
# fix: do NOT relax their `-le 2` bound.
#
# The old F11b (foreground stays parked) is GONE rather than relabelled:
# GetForegroundWindow returns null for every window on a background desktop, so
# its oracle could only ever have scored zero.
#
#   powershell -NoProfile -File test\win32\session-reattach.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # T411 (F9c-F10b): opens the orphan session directly against the harness
    # agent's pipe. Built on demand: `zig build remote-test-client`.
    [string]$ClientExe = 'D:\git\ghoztty\zig-out\bin\remote-test-client.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-session-reattach-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PipeBridge.ps1')  # Get-LocalAgentPipeName (T411)

# Write-Host, not the pipeline: a helper that both asserts and returns a value
# would otherwise hand its caller @('  PASS ...', $realValue).
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) for the app and its
    # sibling agent - the private copies each filtered differently. The extra
    # process below is this script's own litter, so it stays local.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 0)
    Get-CimInstance Win32_Process -Filter "Name='remote-test-client.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the zig-out ghoztty APP (leave ghoztty-agent alive so its PTYs
# survive - the crash/upgrade re-attach scenario the restore half tests).
function Stop-AppOnly {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
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

# Poll a captured stderr log until $pattern shows (the restore log lines land a
# beat after the windows do). Returns $true/$false, never throws.
function Wait-LogLine($path, $pattern, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $path) -and (Select-String -Path $path -Pattern $pattern -Quiet)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

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

# Union of every leaf session_id across ALL windows of a manifest, in order.
# Built inline (not via Leaf-Sids) so there is no nested protective-comma array;
# callers wrap in @() to strip the single protective wrap.
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

# Count top-level windows in a +list --json tree (-1 on CLI failure).
function Count-Windows($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\lw-$tag.json" 10
    if ($code -ne 0) { return -1 }
    $tree = $null
    try { $tree = Out-Text "$tmp\lw-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $tree) { return -1 }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    return @($windows).Count
}
function Wait-Windows($tmp, $tag, $target, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $n = -1
    while ((Get-Date) -lt $deadline) {
        $n = Count-Windows $tmp $tag
        if ($n -eq $target) { return $n }
        Start-Sleep -Milliseconds 500
    }
    return $n
}

# Count terminal leaves across every window/tab in a +list --json tree.
function Count-Leaves($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\ll-$tag.json" 10
    if ($code -ne 0) { return -1 }
    $tree = $null
    try { $tree = Out-Text "$tmp\ll-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $tree) { return -1 }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    $c = 0
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) { $c += (Count-Leaf-Nodes $t.splits) }
    }
    return $c
}
function Count-Leaf-Nodes($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    if ($node.type -eq 'split') { return (Count-Leaf-Nodes $node.left) + (Count-Leaf-Nodes $node.right) }
    return 0
}

# ---- T105 focus-stability interop (section F10/F11) ------------------------
# Pre-fix, a 2-window restore live-locked: each restored window queued a
# WM_APP_SETFOCUS assert whose execution stole activation from the other
# window; every steal re-fired the loser's WM_SETFOCUS forwarding, queueing
# the next assert. The oracle samples the GUI thread's focus window
# (GetGUIThreadInfo, via the harness - wedge-immune, needs no foreground) and
# counts transitions between the two restored top-levels. See the header for
# what this does and does not prove off the input desktop.

# hwnd -> index of the restored top-level it belongs to. Built once from each
# window's descendants (EnumChildWindows is recursive), which is what turns a
# focused PANE hwnd back into "which window".
function Get-WindowOwnerMap($wins) {
    $map = @{}
    for ($i = 0; $i -lt $wins.Count; $i++) {
        $map[[int64]$wins[$i]] = $i
        foreach ($c in @(Get-TestChildWindows -Window $wins[$i] -Class '*')) {
            $map[[int64]$c.Hwnd] = $i
        }
    }
    return $map
}

# Transitions of the app GUI thread's focus window between the two top-levels.
# Both windows live on one GUI thread, so sampling via $wins[0] covers the app.
function Measure-FocusFlips($wins, $totalMs, $stepMs) {
    $map = Get-WindowOwnerMap $wins
    $flips = 0
    $last = -1
    $n = [int]($totalMs / $stepMs)
    for ($t = 0; $t -lt $n; $t++) {
        $f = [int64](Get-TestFocusedWindow -Window $wins[0])
        if ($map.ContainsKey($f)) {
            $idx = $map[$f]
            if ($last -ge 0 -and $idx -ne $last) { $flips++ }
            $last = $idx
        }
        Start-Sleep -Milliseconds $stepMs
    }
    return $flips
}

# One hermetic GUI launch ON THE TEST DESKTOP (fresh LOCALAPPDATA + agent-bin
# override, both inherited through CreateProcessW).
function Start-Backed($label, $title) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default) - the relaunch below has to RESTORE what this launch left.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @("--title=$title")
    $pane = Wait-FirstPane $tmp 25
    $rows = Wait-AliveCount $tmp 'setup' 1 18
    $ok = ($null -ne $pane -and (Count-Alive $rows) -eq 1)
    return @{ Tmp = $tmp; Ok = $ok; Pid = $app.Pid }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
# Isolate the IPC endpoint unconditionally: every assertion below is read back
# through `+list` / `+sessions` / `+read`, and an instance answering the shared
# pipe would answer them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-reattach'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ============================================================================
Say "== A: startup window is captured with its agent session id"
# ============================================================================
$g = Start-Backed 'capture' 't89f-reattach'
Assert "A1 startup pane is agent-backed (one live session)" $g.Ok
Assert "A1b the launched app has no window on the interactive desktop" `
    (-not (Test-TestDesktopLeak -ProcessId $g.Pid))
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
Say "== B: +split grows the captured tree to a split + two leaves"
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
Say "== C: +new-window adds a second captured window with its IPC name"
# ============================================================================
Run-Cli '+new-window --target=second' "$tmp\neww.txt" 15 | Out-Null
$mC = Wait-Manifest $tmp { param($m) @($m.windows).Count -ge 2 } 10
Assert "C1 manifest now has two windows" ($null -ne $mC -and @($mC.windows).Count -eq 2)
$second = @($mC.windows | Where-Object { $_.ipc_name -eq 'second' })
Assert "C2 the second window carries its IPC name" ($second.Count -eq 1)
Assert "C3 the second window's id equals its IPC name" (
    $second.Count -eq 1 -and $second[0].id -eq 'second')

# ============================================================================
Say "== D: +rename --title captures the window title pin"
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
Say "== E: every captured window has a real frame + boolean maximized"
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
Say "== F: quit-keep-sessions then relaunch re-ATTACHes the whole layout"
# ============================================================================
# Reuse the A-E state: window 1 (startup pane + the f89sib split) + window
# 'second' (title 'HelloTitle') = a 2-window / 3-pane layout with 3 live
# agent sessions. Mark scrollback in the split pane, record the live session
# ids, KILL ONLY THE APP (the agent keeps every PTY), relaunch, and prove the
# same sessions come back in the same layout with their scrollback + titles.
# A single space-free token: send-keys concatenates positional args (and cmd's
# /c nesting would collapse a quoted space anyway), so a bare marker + Enter is
# the robust way to plant text. cmd echoes it + errors ("'MARKER' is not
# recognized..."), both landing the token in scrollback. Matched with all
# whitespace stripped (the T99 section-D narrow-pane technique), so a marker
# that cmd wrapped across rows still counts.
$marker = "REATTACHMARKER$($PID)XYZ"  # no separators: survives per-glyph wrapping
function Read-HasMarker($f) { return ((Out-Text $f) -replace '\s', '') -match $marker }
Run-Cli "+send-keys --target=f89sib $marker Enter" "$tmp\mark.txt" 12 | Out-Null
# Poll +read until the marker shows (the shell printed it) pre-quit.
$preOk = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    Run-Cli '+read --name=f89sib --lines=200' "$tmp\read-pre.txt" 10 | Out-Null
    if (Read-HasMarker "$tmp\read-pre.txt") { $preOk = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "F1 marker is in the split pane's scrollback before quit" $preOk

# T422: the pane's sticky banner is APP-SIDE overlay state - it never enters the
# PTY, so the agent's replay cannot bring it back and the manifest is its only
# way home. Without the manifest field every restored pane came up bannerless.
# Space-free for the same reason the marker is (Run-Cli builds one command line);
# the `**` proves the raw markdown SOURCE round-trips, not a rendering of it.
$bannerText = "**T422BANNER$($PID)XYZ**"
Run-Cli "+set-banner --target=f89sib $bannerText" "$tmp\setban.txt" 12 | Out-Null
$banPre = $false
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if ((Run-Cli '+list --json' "$tmp\ban-pre.json" 10) -eq 0 -and
        (Out-Text "$tmp\ban-pre.json") -match [regex]::Escape("T422BANNER$($PID)XYZ")) {
        $banPre = $true; break
    }
    Start-Sleep -Milliseconds 500
}
Assert "F1b the banner is set on the split pane before quit (positive control)" $banPre

# The live session ids the agent is keeping (must all come back on re-attach).
$beforeIds = @(Alive-Ids (Wait-AliveCount $tmp 'f-before' 3 15))
Assert "F2 three agent sessions are alive before quit" ($beforeIds.Count -eq 3)

# Manifest must already reflect the full 2-window layout (debounced write) so
# the abrupt app kill loses nothing.
$mPre = Wait-Manifest $tmp {
    param($m)
    @($m.windows).Count -eq 2 -and (All-Sids $m).Count -eq 3
} 10
Assert "F3 manifest holds the full 2-window / 3-session layout pre-quit" (
    $null -ne $mPre -and @($mPre.windows).Count -eq 2 -and (All-Sids $mPre).Count -eq 3)

# Kill ONLY ghoztty.exe; the detached agent survives with all 3 PTYs.
Stop-AppOnly
$agentIds = @(Alive-Ids (Wait-AliveCount $tmp 'f-agent' 3 15))
Assert "F4 the agent kept all 3 sessions alive after the app died" (
    $agentIds.Count -eq 3 -and ($beforeIds | Where-Object { $agentIds -contains $_ }).Count -eq 3)

# Relaunch (same LOCALAPPDATA + agent bin). Restore must suppress the blank
# startup window and rebuild both windows by re-ATTACHing. The relaunch is
# VISIBLE on purpose (T106): pre-T106 the replayed scrollback only survived a
# minimized cycle (the raw ring replay parsed at the restored window's
# transient/live grid instead of the geometry it was drawn at, so the recorded
# scrolls never pushed content into scrollback and conhost's post-attach
# ESC[2J fresh-paint erased it). F8 is the oracle: baseline-proven RED on a
# visible relaunch pre-fix, green post-fix. On the test desktop every launch is
# a normal visible one, so this is the shape that runs.
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# persistence: on (default) - session persistence IS this script's subject.
$relaunched = Start-OnTestDesktop -Exe $Exe -StdErr "$tmp\restore1-err.txt"

$winCount = Wait-Windows $tmp 'f-post' 2 30
Assert "F5 relaunch restored exactly two windows (no extra blank)" ($winCount -eq 2)
$leafCount = Count-Leaves $tmp 'f-post'
Assert "F6 relaunch restored all three panes" ($leafCount -eq 3)
Assert "F6b the relaunched app has no window on the interactive desktop" `
    (-not (Test-TestDesktopLeak -ProcessId $relaunched.Pid))

# ATTACH proof: the agent still has EXACTLY the same 3 sessions alive (a fresh
# OPEN per pane would have spawned new ones on top of the survivors).
$afterIds = @(Alive-Ids (Wait-AliveCount $tmp 'f-after' 3 20))
$sameThree = ($afterIds.Count -eq 3 -and ($beforeIds | Where-Object { $afterIds -contains $_ }).Count -eq 3)
if ($NegativeControl) {
    # Invert the claim the whole restore half exists for: that the panes were
    # RE-ATTACHED rather than freshly re-OPENed. A control that passes here is
    # scoring a build that threw the user's live sessions away.
    Say 'NEGATIVE CONTROL: asserting restore re-OPENed new sessions instead of attaching - this run MUST fail'
    Assert "F7 restore replaced the live sessions with new ones (inverted)" (-not $sameThree)
} else {
    Assert "F7 the same 3 sessions are alive after relaunch (ATTACH, not re-OPEN)" $sameThree
}

# The restored split pane kept its IPC name (re-registered on restore) AND its
# scrollback (gap-fill replay from the agent ring). Whitespace-stripped match,
# same wrapping tolerance as F1.
$postOk = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    # 2000 lines (was 200): headroom against reflow/repaint after re-attach
    # pushing the wrapped replayed marker deeper into the tail.
    $code = Run-Cli '+read --name=f89sib --lines=2000' "$tmp\read-post.txt" 10
    if ($code -eq 0 -and (Read-HasMarker "$tmp\read-post.txt")) { $postOk = $true; break }
    Start-Sleep -Milliseconds 700
}
Assert "F8 restored pane keeps its IPC name and its pre-quit scrollback" $postOk

# F8b (T532): ATTACHED IS NOT ALIVE. F8 proves the agent REPLAYED what the pane
# had before the kill - a recording. It says nothing about whether the live
# stream ever wired up, and on 2026-08-06 the user hit exactly that gap: every
# restored pane painted correctly and was then a dead picture, with the app
# logging `attach:` + `restored N window(s)` + `attached N pane(s)` at every
# step. A replayed snapshot is indistinguishable from a working pane until
# something types into it, so this arm types into it: plant a NEW marker AFTER
# the restore and require it to come back. That exercises both halves the freeze
# takes out - input reaching the child, and the child's output reaching the pane.
$liveMarker = "REATTACHLIVE$($PID)XYZ"
Run-Cli "+send-keys --target=f89sib $liveMarker Enter" "$tmp\mark-live.txt" 12 | Out-Null
$liveOk = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    $code = Run-Cli '+read --name=f89sib --lines=2000' "$tmp\read-live.txt" 10
    if ($code -eq 0 -and ((Out-Text "$tmp\read-live.txt") -replace '\s', '') -match $liveMarker) {
        $liveOk = $true; break
    }
    Start-Sleep -Milliseconds 700
}
Assert "F8b restored pane is LIVE: input reaches the child and new output arrives" $liveOk

# The window title pin survived the round-trip (rewritten manifest post-restore).
# Direct poll (not Wait-Manifest): the manifest is rewritten atomically as the
# restored panes publish their session ids, so a single racy read can miss it -
# re-read until the 'second' window shows its restored title_override.
$f9 = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $m = Read-Manifest $tmp
    if ($null -ne $m) {
        $w = @($m.windows | Where-Object { $_.ipc_name -eq 'second' })
        if ($w.Count -eq 1 -and $w[0].title_override -eq 'HelloTitle') { $f9 = $true; break }
    }
    Start-Sleep -Milliseconds 400
}
Assert "F9 the restored window's title pin came back" $f9

# T422: the pane's own banner rehydrates. `+list --json`'s `banner` field reads
# the LIVE overlay, not the manifest, so a pass means the restored pane really is
# showing it again - which is what the user asked for ("I expected banners to be
# rehydrated"). F1b is its positive control: without that, a build that never set
# the banner at all would score this the same way a broken restore does.
$f9b = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    if ((Run-Cli '+list --json' "$tmp\ban-post.json" 10) -eq 0 -and
        (Out-Text "$tmp\ban-post.json") -match [regex]::Escape("T422BANNER$($PID)XYZ")) {
        $f9b = $true; break
    }
    Start-Sleep -Milliseconds 700
}
Assert "F9b the restored pane's sticky banner came back" $f9b

# ============================================================================
Say "== F9c-F9e: T411 - the restore log counts live sessions nothing attached"
# ============================================================================
# The FIRST relaunch had no orphan, so its restore log must say `0` explicitly:
# a counter that only appears when nonzero cannot be told from a counter that
# never runs. (The line is warn-level when nonzero, info at zero; both hit the
# debug build's stderr.)
Assert "F9c restore log reports the zero case (0 live sessions unattached)" `
    (Wait-LogLine "$tmp\restore1-err.txt" 'session-restore: attached 3 pane\(s\); 0 live agent session\(s\) unattached')

# Now manufacture the T411 orphan: OPEN a fourth session directly against the
# harness agent (the same pipe the app dials), then DETACH so it stays alive
# with no pane holding it - the exact shape T108 found on the release install
# (4 live sessions, the layout references 3). `--hold` opens a session, holds
# it briefly, then DETACHes; a detached session SURVIVES (only CLOSE ends one).
Assert "F9d remote-test-client exists in zig-out (zig build remote-test-client)" (Test-Path $ClientExe)
$pipe = "\\.\pipe\$(Get-LocalAgentPipeName)"
$pc = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
    -ArgumentList "/c `"`"$ClientExe`" --pipe=$pipe --hold=1 > `"$tmp\orphan-client.txt`" 2>&1`""
if (-not $pc.WaitForExit(25000)) { Stop-Process -Id $pc.Id -Force -ErrorAction SilentlyContinue }
$rowsOrphan = Wait-AliveCount $tmp 'orphan' 4 15
Assert "F9e the orphan session is alive on the agent (4 alive, layout holds 3)" `
    ((Count-Alive $rowsOrphan) -eq 4)

# ============================================================================
Say "== F10: restore-time focus settling across a second relaunch (T105/T223)"
# Do a SECOND app-only kill + relaunch and watch the GUI thread's focus window
# while restore builds both windows back-to-back. Pre-T105 this live-locked
# (baseline: fgFlips=38/focusFlips=36 in 3s pre-fix, 0/0 post-fix). Off the
# input desktop the T105 guard used to be bypassed (T211), and the storm came
# back with it at 43 flips; this assertion is the oracle T223 turned green. Do
# NOT relax the bound to make the suite quiet - the number IS the finding.
Stop-AppOnly
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# persistence: on (default) - session persistence IS this script's subject.
$relaunch2 = Start-OnTestDesktop -Exe $Exe -StdErr "$tmp\restore2-err.txt"
$wins = @()
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $w1 = Get-TestWindow -ProcessId $relaunch2.Pid -Class 'GhozttyWindow'
    if ($w1 -ne [IntPtr]::Zero) {
        $w2 = Get-TestWindow -ProcessId $relaunch2.Pid -Class 'GhozttyWindow' -Exclude $w1
        if ($w2 -ne [IntPtr]::Zero) { $wins = @($w1, $w2); break }
    }
    Start-Sleep -Milliseconds 100
}
Assert "F10a both restored top-level windows enumerated on the test desktop" ($wins.Count -eq 2)

# T411, the nonzero case: this relaunch restored the same 3 panes while the
# agent holds 4 live sessions, and the restore log must name the gap - one
# line that turns a future recurrence into a grep instead of a forensic
# exercise. F7 already proved the 3 restored panes still ATTACH (the orphan
# must not perturb the restore itself).
Assert "F10b restore log names the orphan (1 live agent session unattached)" `
    (Wait-LogLine "$tmp\restore2-err.txt" 'session-restore: attached 3 pane\(s\); 1 live agent session\(s\) unattached')

# And the orphan must not perturb the restore itself: the same 3 layout
# sessions re-ATTACHed (no re-OPEN spawning a 5th) and the orphan is still
# alive - reporting it is the whole fix; touching it is exactly what the
# reaper is not allowed to do.
$after2 = @(Alive-Ids (Wait-AliveCount $tmp 'f10-after' 4 20))
Assert "F10c the 3 layout sessions and the orphan are all still alive after restore" `
    ($after2.Count -eq 4 -and ($beforeIds | Where-Object { $after2 -contains $_ }).Count -eq 3)

if ($wins.Count -eq 2) {
    $storm = Measure-FocusFlips $wins 3000 40
    Say "  (restore-time focusFlips=$storm)"
    Assert "F10 restore-time focus does not churn between the two windows (T223 oracle)" ($storm -le 2)
}

# F11 (T105 floor): seed one pending WM_APP_SETFOCUS (0x8005 = WM_APP+5)
# assert per window, queued back-to-back with no drain gap, then require focus
# to settle. PostMessage needs no foreground rights, so this is wedge-immune
# and works identically on either desktop. The old F11b (foreground stays
# parked) is gone: GetForegroundWindow is null for every window on a background
# desktop, so its oracle could only ever have scored zero (see the header).
Say "== F11: seeded co-pending focus asserts must settle, not ping-pong (T105/T223)"
if ($wins.Count -eq 2) {
    $surf0 = Get-TestChildWindow -Window $wins[0] -Class 'GhozttyTerminal'
    $surf1 = Get-TestChildWindow -Window $wins[1] -Class 'GhozttyTerminal'
    Assert "F11a a terminal surface found in each restored window" (
        $surf0 -ne [IntPtr]::Zero -and $surf1 -ne [IntPtr]::Zero)
    if ($surf0 -ne [IntPtr]::Zero -and $surf1 -ne [IntPtr]::Zero) {
        Send-TestRawMessage -Window $surf0 -Message 0x8005 | Out-Null
        Send-TestRawMessage -Window $surf1 -Message 0x8005 | Out-Null
        Start-Sleep -Milliseconds 300
        $flips = Measure-FocusFlips $wins 3000 40
        Say "  (post-seed focusFlips=$flips)"
        Assert "F11 GUI-thread focus settles after seeded asserts (T223 oracle)" ($flips -le 2)
    }
} else {
    Assert "F11 could not run: the restored windows were not enumerated" $false
}

# ============================================================================
if ($script:failures -gt 0) {
    Say "== DIAG: final manifest =="
    $dp = Manifest-Path $tmp
    if (Test-Path $dp) { Say (Get-Content $dp -Raw) } else { Say "NO MANIFEST FILE at $dp" }
    Say "== DIAG: sid0=$sid0"
}

} finally {
    Say "== cleanup"
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
Say "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert "G1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "G2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

Say ""
if ($script:failures -eq 0) { Say "ALL PASS ($script:passes assertions)"; exit 0 }
else { Say "$($script:failures) FAILURE(S) / $script:passes passed"; exit 1 }
