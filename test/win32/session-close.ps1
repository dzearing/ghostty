# Session close-vs-quit semantics (tracker T89e). Proves the win32 rule that
# mirrors macOS: a USER close of a pane / tab / window ENDS the agent session
# (CLOSE — the child is killed, the session freed), while an app-EXIT path
# (graceful quit, crash, upgrade, logoff kill) LEAVES sessions alive so they
# re-attach on the next launch (DETACH — the agent keeps its pinned PTYs).
#
# Each scenario is its own hermetic GUI launch whose startup window is
# agent-backed (T89d); T99 made IPC-created splits/windows agent-backed too, so
# scenario D can stand up a SECOND session over the CLI and prove a single-pane
# close ends only that session.
#
#   A. +close the startup PANE by id -> the session ENDS. Exercises
#      closeSplitPane -> closeTab -> closeTabByIndex's close-intent wiring.
#   B. +close the startup WINDOW (--target=window-1) -> the session ENDS.
#      Exercises Window.close -> markAllSessionsClose.
#   C. hard-kill the GUI with NO close -> the session SURVIVES (alive, now
#      detached). The app-exit (quit / crash / upgrade / logoff) class, which
#      sends no CLOSE so the agent keeps the pinned PTY. (The graceful `.quit`
#      action shares this outcome via Window.deinit's no-mark teardown; a hard
#      kill is the deterministic, GUI-input-free proxy the design groups in the
#      same keep-sessions class.)
#   D. +split -> two agent sessions, then +close ONE pane -> only that session
#      ends; the sibling survives (the close-intent wiring is per-surface). This
#      scenario is what T99 (agent-backed IPC splits) unblocks.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (never
# the user's real release instance, which uses a different IPC socket + agent
# lineage).
#
#   powershell -NoProfile -File test\win32\session-close.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-session-close-$PID"

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

# Kill ONLY the zig-out GUI (ghoztty.exe), leaving the local agent running — the
# app-exit (quit / crash / upgrade) class that must keep sessions alive.
function Stop-GuiOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
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

# One hermetic GUI launch (fresh LOCALAPPDATA + agent-bin override). Waits for
# the startup pane and the single agent session. Returns
# @{ Tmp; PaneId; SessId; Ok }.
function Start-Backed($label) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default) - session persistence IS this script's subject.
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @('--title=t89e-session-close') | Out-Null
    $pane = Wait-FirstPane $tmp 25
    $paneId = if ($null -ne $pane) { $pane.id } else { '' }
    $rows = Wait-AliveCount $tmp 'setup' 1 18
    $sid = ''
    if ((Count-Alive $rows) -eq 1) { $sid = (@($rows | Where-Object { $_.alive -eq $true })[0]).id }
    return @{ Tmp = $tmp; PaneId = $paneId; SessId = $sid; Ok = ($null -ne $pane -and $sid -ne '') }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# T441: a private IPC endpoint, which the per-section LOCALAPPDATA redirect does
# NOT cover — the endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it. This script's verbs are
# +close: pointed at the user's installed release it would close their panes.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'sessclose')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: +close the startup PANE ends its agent session"
# ============================================================================
$a = Start-Backed 'close-pane'
Assert "A1 startup pane is agent-backed (one live session)" $a.Ok
# Before the first +close: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe
Run-Cli "+close --target=$($a.PaneId)" "$($a.Tmp)\closepane.txt" 12 | Out-Null
$rowsA = Wait-AliveCount $a.Tmp 'after' 0 15
Assert "A2 the session ended after the pane close (0 alive)" ((Count-Alive $rowsA) -eq 0)
Stop-TestProcs

# ============================================================================
"== B: +close the startup WINDOW ends its agent session"
# ============================================================================
$b = Start-Backed 'close-window'
Assert "B1 startup pane is agent-backed (one live session)" $b.Ok
Run-Cli "+close --target=window-1" "$($b.Tmp)\closewin.txt" 12 | Out-Null
$rowsB = Wait-AliveCount $b.Tmp 'after' 0 15
Assert "B2 the session ended after the window close (0 alive)" ((Count-Alive $rowsB) -eq 0)
Stop-TestProcs

# ============================================================================
"== C: hard-kill the GUI with NO close keeps the session (quit/crash class)"
# ============================================================================
$c = Start-Backed 'quit-keeps'
Assert "C1 startup pane is agent-backed (one live session)" $c.Ok
$sidC = $c.SessId
Stop-GuiOnly
$rowsC = Wait-AliveCount $c.Tmp 'after' 1 12
Assert "C2 the session survived the app exit (still alive)" ((Count-Alive $rowsC) -eq 1)
$survC = @($rowsC | Where-Object { $_.id -eq $sidC }) | Select-Object -First 1
Assert "C3 same session id survived, now detached (no viewer)" (
    $null -ne $survC -and $survC.alive -eq $true -and $survC.attached -eq $false)

# ============================================================================
"== D: +close ONE pane of a 2-pane window ends only that session (T99)"
# ============================================================================
# Section C deliberately left its agent running (Stop-GuiOnly). That agent
# holds the per-user pipe + single-instance guard, so a fresh GUI would fail to
# stand up its own agent. Clear it before D.
Stop-TestProcs
$d = Start-Backed 'close-split'
Assert "D1 startup pane is agent-backed (one live session)" $d.Ok
# A CLI split now opens under the SAME agent (T99): a second live session.
Run-Cli '+split --direction=right --name=t99sib' "$($d.Tmp)\split.txt" 15 | Out-Null
$rows2 = Wait-AliveCount $d.Tmp 'split' 2 15
Assert "D2 +split opened a second agent-backed session (2 alive)" ((Count-Alive $rows2) -eq 2)
# Close ONLY the split pane -> its session ENDS; the startup sibling SURVIVES.
Run-Cli "+close --target=t99sib" "$($d.Tmp)\closesplit.txt" 12 | Out-Null
$rows1 = Wait-AliveCount $d.Tmp 'after' 1 15
Assert "D3 exactly one session survives the single-pane close" ((Count-Alive $rows1) -eq 1)
$survD = @($rows1 | Where-Object { $_.alive -eq $true }) | Select-Object -First 1
Assert "D4 the survivor is the startup sibling, not the closed split" (
    $null -ne $survD -and $survD.id -eq $d.SessId)
Stop-TestProcs

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
