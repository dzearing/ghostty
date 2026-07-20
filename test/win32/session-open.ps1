# Session-open acceptance (tracker T89d): win32 surfaces OPEN under the local
# session-persistence agent. Launches the real debug ghoztty GUI, lets its
# find-or-spawn stand up a local ghoztty-agent, and asserts via the IPC CLI
# that the initial window's pane is agent-backed (its shell is a child of the
# agent), that typing round-trips through the agent, that persistence=off falls
# back to a plain exec pane (no agent session), and that an unreachable agent
# binary falls back to exec within the bounded wait. Non-interactive; asserts
# and exits nonzero on any failure. Fully hermetic: a per-run $env:LOCALAPPDATA
# and a per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out (never the user's real
# release instance, which uses a different IPC socket + agent lineage).
#
#   powershell -NoProfile -File test\win32\session-open.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-session-open-$PID"

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

# Kill ONLY the zig-out GUI (ghoztty.exe), leaving any local agent running — so
# a test can prove a session outlives the app (the point of session persistence).
function Stop-GuiOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
# Returns exit code, or $null on timeout. Inherits the current (hermetic) env.
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

# Poll `+list --json` until a terminal pane appears (the GUI finished opening
# its initial window). Returns the first pane leaf object, or $null on timeout.
function Wait-FirstPane($tmp, $timeoutSec = 20) {
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

# Walk the +list --json response ({success, data:{windows:[{tabs:[{splits:
# <node>}]}]}}) for the first terminal leaf. A node is {type:"leaf",
# terminal:{id,name,pid,...}} or {type:"split", left:<node>, right:<node>}.
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

# Type a marker into $paneId and poll +read until it round-trips back.
function Test-Typing($tmp, $paneId, $timeoutSec = 15) {
    $mark = "T89DMARK$PID"
    Run-Cli "+send-keys --target=$paneId `"echo $mark`" Enter" "$tmp\sk.txt" 10 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
        Run-Cli "+read --name=$paneId --lines=40" "$tmp\read.txt" 10 | Out-Null
        if ((Out-Text "$tmp\read.txt") -match $mark) { return $true }
    }
    return $false
}

# One hermetic GUI launch. Sets a fresh LOCALAPPDATA + optional agent-bin
# override, launches the GUI with $extraArgs, returns @{ Tmp; Proc }.
function Start-Gui($label, $agentBin, $extraArgs) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    if ($null -ne $agentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $agentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $argList = @('--title=t89d-session-open') + $extraArgs
    $p = Start-Process -FilePath $Exe -PassThru -WindowStyle Minimized -ArgumentList $argList
    return @{ Tmp = $tmp; Proc = $p }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ============================================================================
"== A: persistence ON -> initial pane is agent-backed"
# ============================================================================
$a = Start-Gui 'on' $AgentExe @()
$pane = Wait-FirstPane $a.Tmp 25
Assert "A1 GUI opened a pane" ($null -ne $pane)
$paneId = if ($null -ne $pane) { $pane.id } else { '' }

# The agent should have been found-or-spawned and written its port.json.
$portFile = Join-Path $a.Tmp 'ghoztty\local-agent-debug\port.json'
$agentPid = 0
$info = $null
if (Test-Path $portFile) {
    try { $info = Get-Content $portFile -Raw | ConvertFrom-Json } catch {}
    if ($null -ne $info) { $agentPid = [int]$info.pid }
}
Assert "A2 agent wrote port.json with a pipe endpoint" ($null -ne $info -and $info.pipe -like '\\.\pipe\ghoztty-agent*')
Assert "A3 agent pid recorded and alive" ($agentPid -gt 0 -and $null -ne (Get-Process -Id $agentPid -ErrorAction SilentlyContinue))

# +sessions must show exactly one live, attached session (the initial pane).
$code = Run-Cli '+sessions --json' "$($a.Tmp)\sess.json"
$rows = $null
try { $rows = Out-Text "$($a.Tmp)\sess.json" | ConvertFrom-Json } catch {}
Assert "A4 +sessions lists exactly one session" ($null -ne $rows -and @($rows).Count -eq 1)
$sess = if ($null -ne $rows) { @($rows)[0] } else { $null }
Assert "A5 session is alive and attached" ($null -ne $sess -and $sess.alive -eq $true -and $sess.attached -eq $true)
Assert "A6 session pinned (survives the viewer quitting)" ($null -ne $sess -and $sess.pinned -eq $true)

# Typing round-trips through the agent-backed pane.
Assert "A7 typing round-trips (send-keys -> +read echo)" (Test-Typing $a.Tmp $paneId 18)

# The definitive proof the pane is AGENT-owned, not app-owned: kill ONLY the
# GUI and confirm the agent still lists the session alive (now detached). The
# agent owns the PTY, so the process outlives the app — the whole point of
# session persistence (T89d; re-ATTACH restore itself is T89f). +sessions dials
# the agent directly, so it answers with the app closed (T89c).
$sidA = if ($null -ne $sess) { $sess.id } else { '' }
Stop-GuiOnly
$agentStillAlive = ($agentPid -gt 0 -and $null -ne (Get-Process -Id $agentPid -ErrorAction SilentlyContinue))
Assert "A8 local agent still running after the GUI quit" $agentStillAlive
$code = Run-Cli '+sessions --json' "$($a.Tmp)\survive.json"
$rowsS = $null
try { $rowsS = Out-Text "$($a.Tmp)\survive.json" | ConvertFrom-Json } catch {}
$survivor = if ($null -ne $rowsS) { @($rowsS) | Where-Object { $_.id -eq $sidA } | Select-Object -First 1 } else { $null }
Assert "A9 session survived the app quit (still alive, agent-owned)" (
    $null -ne $survivor -and $survivor.alive -eq $true)
Assert "A10 surviving session is now detached (no viewer)" (
    $null -ne $survivor -and $survivor.attached -eq $false)

Stop-TestProcs

# ============================================================================
"== B: persistence OFF -> plain exec pane, no agent session"
# ============================================================================
$b = Start-Gui 'off' $AgentExe @('--session-persistence=false')
$pane = Wait-FirstPane $b.Tmp 25
Assert "B1 GUI opened a pane with persistence off" ($null -ne $pane)
$paneId = if ($null -ne $pane) { $pane.id } else { '' }
Assert "B2 typing works on the plain exec pane" (Test-Typing $b.Tmp $paneId 18)
# No agent should have been spawned (no port.json) and +sessions finds none.
$portFileB = Join-Path $b.Tmp 'ghoztty\local-agent-debug\port.json'
Assert "B3 no local agent was spawned (no port.json)" (-not (Test-Path $portFileB))
$code = Run-Cli '+sessions --json' "$($b.Tmp)\sess.json"
$rowsB = $null
try { $rowsB = Out-Text "$($b.Tmp)\sess.json" | ConvertFrom-Json } catch {}
# Either the CLI reports no agent (nonzero) or an empty roster.
Assert "B4 no agent-backed session exists" ($code -ne 0 -or ($null -ne $rowsB -and @($rowsB).Count -eq 0))

Stop-TestProcs

# ============================================================================
"== C: agent unreachable -> exec fallback within the bounded wait"
# ============================================================================
$bogus = Join-Path $root 'no-such-agent.exe'
$t0 = Get-Date
$c = Start-Gui 'fallback' $bogus @()
$pane = Wait-FirstPane $c.Tmp 25
$elapsed = ((Get-Date) - $t0).TotalSeconds
Assert "C1 GUI still opened a pane (exec fallback)" ($null -ne $pane)
$paneId = if ($null -ne $pane) { $pane.id } else { '' }
Assert "C2 typing works on the fallback exec pane" (Test-Typing $c.Tmp $paneId 18)
# The find-or-spawn is bounded (2s per resolve); the window must not have hung
# for anywhere near a stall. Generous ceiling to absorb GUI startup + polling.
Assert "C3 window opened promptly (no unbounded hang)" ($elapsed -lt 20)
$code = Run-Cli '+sessions --json' "$($c.Tmp)\sess.json"
$rowsC = $null
try { $rowsC = Out-Text "$($c.Tmp)\sess.json" | ConvertFrom-Json } catch {}
Assert "C4 no agent-backed session (spawn failed, fell back)" ($code -ne 0 -or ($null -ne $rowsC -and @($rowsC).Count -eq 0))

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
