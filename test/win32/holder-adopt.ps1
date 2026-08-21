# T906 acceptance: a restarted session manager RE-ADOPTS the shells that
# outlived it, instead of rebuilding them.
#
# In the user's terms: the background process that manages persistent terminal
# sessions can die - crash, be killed, be replaced by a newer build - and when
# it comes back your pane is still the SAME running program, with the same
# scrollback and nothing to redo.
#
# T905 made the first half true: the ConPTY, the shell and its kill-on-close job
# live in a per-session `--pty-host` holder that escapes the agent's job, so the
# shell survives. But a surviving shell nobody picks back up is just a leak.
# T906 is the picking up: at startup the agent reads `sessions.json`, dials each
# recorded holder, and re-attaches at the exact output offset its on-disk ring
# snapshot ends at.
#
# The measurement that separates this from what shipped before is ONE NUMBER:
# the shell pid. `test\win32\agent-recovery.ps1` section C asserts the shell
# pids are NEW after an agent kill - the children died with the agent and the
# replacement RELAUNCHed them. Here, with holders on, they must be THE SAME
# pids. Same pid = the process was never restarted = nothing was lost. A test
# that only checked "the pane works again" would pass on a relaunch, which is
# precisely the outcome this task exists to replace.
#
# Sections:
#   A. Baseline: a holder-backed, agent-backed pane, RESPONSIVE, with a marker
#      typed into its scrollback. Records the shell pid, the holder pid and the
#      holder control pipe the agent wrote to `sessions.json`.
#   B. Kill ONLY the session manager. The app stays up (same pid), the holder
#      and the shell survive - the T905 property this builds on.
#   C. ADOPTION. A replacement agent comes up (the app's in-place recovery) and:
#      the session is alive again with the SAME shell pid and the SAME holder,
#      the marker from section A is still in the scrollback, no "session
#      restarted" divider was drawn, and the pane answers fresh input.
#   D. ORPHAN REAP. A holder that no session record names can never be reached
#      again by anybody, so a starting agent shuts it down. Forced rather than
#      waited for: stop the app and agent (leaving the holder alive), delete
#      `sessions.json`, relaunch. The holder must be gone.
#
# `-NegativeControl` inverts section C's adoption assertions, so a run that
# scores this build as NOT adopting is available on demand.
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint (lib\Isolation),
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test, and only processes
# whose ExecutablePath is the exe/agent under test are ever stopped - never the
# user's installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\holder-adopt.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'HOLDER-ADOPT' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'HOLDER-ADOPT' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

# --- process helpers: ONLY ever the binaries under test ----------------------

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
# The session manager itself: an agent process that is NOT a per-session holder
# (holders are the same binary in `--pty-host` mode).
function Get-TestAgents {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
# Stop the app and the session manager but DELIBERATELY leave holders running -
# section D needs a live orphan, and section B needs the holder to outlive the
# agent it was serving.
function Stop-AppAndAgent {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}
function Stop-Everything {
    Stop-AppAndAgent
    foreach ($p in (Get-TestHolders)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Wait-NewAgent($excludePids, $timeoutSec = 45) {
    $excludePids = @($excludePids | ForEach-Object { [int]$_ })
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $fresh = @((Get-TestAgents) | Where-Object { $excludePids -notcontains [int]$_.ProcessId })
        if ($fresh.Count -gt 0) { return [int]$fresh[0].ProcessId }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

# --- CLI plumbing ------------------------------------------------------------

# ghoztty.exe is GUI-subsystem, so a pipe reads empty; redirect through cmd and
# bound the wait, or a wedged server hangs the script instead of failing it.
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
    return Run-Cli ($argv -join ' ') $out $timeoutSec
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Get-Sessions([string]$tmp, [string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Rows($rows) { return , @($rows | Where-Object { $_.alive -eq $true }) }
function Wait-AliveCount([string]$tmp, [string]$tag, [int]$target, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        $alive = Alive-Rows $rows
        if ($alive.Count -ge $target) { return , $rows }
        Start-Sleep -Milliseconds 600
    }
    return , $rows
}

# `sessions.json` under the (per-run) agent state dir. Found, not re-derived, so
# a state-dir move cannot silently turn this into a test of nothing.
function Find-SessionsFile([string]$root, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($c in @(Get-ChildItem -Path $root -Filter 'sessions.json' -Recurse -File -ErrorAction SilentlyContinue)) {
            $txt = Get-Content -LiteralPath $c.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -and $txt -match '"holder_pipe"') { return $c.FullName }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Read-HolderRecord([string]$metaPath, [string]$sessionId) {
    if (-not $metaPath -or -not (Test-Path $metaPath)) { return $null }
    $meta = $null
    try { $meta = (Get-Content -LiteralPath $metaPath -Raw) | ConvertFrom-Json } catch { return $null }
    foreach ($s in @($meta.sessions)) {
        if ($s.PSObject.Properties.Name -notcontains 'holder_pipe' -or -not $s.holder_pipe) { continue }
        if ($sessionId -and [string]$s.id -ne $sessionId) { continue }
        return $s
    }
    return $null
}

# Flatten +list's split tree to its terminal leaves. `+list --json` already
# reports each leaf's `session_id` (T332), which is the join key against
# `+sessions --json` and against `sessions.json` - so the pane under test is
# tied to ONE session rather than to whichever record happens to be first.
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    # The leaf's fields hang off `terminal`, not off the node itself.
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
# `+list --json` wraps its payload in a `data` envelope. Unwrapping it here (and
# tolerating a bare shape) is load-bearing: reading `$tree.windows` directly
# yields nothing, every leaf lookup comes back empty, and the assertions below
# fail for a reason that has nothing to do with the build under test.
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in (Windows-Of $tree)) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Get-Tree([string]$tmp, [string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}

# Whitespace-stripped pane text: a minimized window wraps a marker one character
# per row, so collapsing whitespace is what makes this measure "is it there"
# rather than "how wide is the pane".
function Read-PaneText([string]$tmp, [string]$target, [string]$tag) {
    $rc = Run-Cli "+read --name=$target --lines=2000" "$tmp\read-$tag.txt" 12
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
}

$root = Join-Path $env:TEMP "ghoztty-holder-adopt-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # The subject. Holder-backed spawning is the DEFAULT since T909, so this
    # arm sets NOTHING and asserts what a real box does - it only CLEARS an
    # inherited opt-out, because with holders off there is nothing to adopt and
    # the whole script would silently degrade into the relaunch path
    # agent-recovery.ps1 already covers.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'adopt906')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    # ========================================================================
    Say "== A: baseline - a holder-backed pane with a marker in its scrollback"
    # ========================================================================
    # persistence: on (default) - an agent-backed pane is the whole subject.
    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
        '--title=t906-adopt', '--window-width=100', '--window-height=30') | Out-Null

    $appPid = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-a.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-a.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like '*t906-adopt*' })
            if ($app.Count -ge 1) { $appPid = [int]$app[0].ProcessId; break }
        }
        Start-Sleep -Milliseconds 600
    }
    Assert 'A1 premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) {
        Write-TestVerdict -Label 'HOLDER-ADOPT' -Pass $script:passes -Fail $script:failures
    }
    Assert-GhozttyIsolated -Exe $Exe

    # Name a pane so +send-keys / +read have a stable target across the agent
    # restart (pane names are the app's, and the app never restarts here).
    $pane = 't906p'
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree $tmp 'a1'))) { if (-not $firstId) { $firstId = $lf.id } }
    if ($firstId) {
        Run-Cli "+split --pane=$firstId --name=$pane --direction=right" "$tmp\split.txt" 20 | Out-Null
    } else {
        Run-Cli "+new-window --name=$pane" "$tmp\newwin.txt" 20 | Out-Null
    }

    $agentPid = Wait-NewAgent $before 45
    Assert 'A2 premise: a session manager is running' ($agentPid -ne 0)

    # The pane under test, and the session behind it. Everything after this is
    # about THAT session - not "some session", which on a two-pane window would
    # let the assertions pass against the pane nobody typed into.
    $paneLeaf = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $lv = @((All-Leaves (Get-Tree $tmp 'a2')) | Where-Object { $_.name -eq $pane })
        if ($lv.Count -eq 1 -and $lv[0].session_id) { $paneLeaf = $lv[0]; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A3 the named pane exists and is agent-backed (it carries a session id)' (
        $null -ne $paneLeaf)
    if ($null -eq $paneLeaf) {
        # Say WHAT was there instead. A silent "no such pane" sends the next
        # reader hunting through the build for a defect in the app.
        Say "    diagnostic: leaves seen ->"
        foreach ($lf in (All-Leaves (Get-Tree $tmp 'diag'))) {
            Say "      id=$($lf.id) name=$($lf.name) type=$($lf.type) session=$($lf.session_id)"
        }
    }
    $sessionId = if ($paneLeaf) { [string]$paneLeaf.session_id } else { '' }

    $rowsA = Wait-AliveCount $tmp 'a' 1 45
    $aliveA = Alive-Rows $rowsA
    $shellPidA = 0
    foreach ($r in $aliveA) { if ([string]$r.id -eq $sessionId) { $shellPidA = [int]$r.pid } }
    # The pane's shell pid, from the agent's own roster - this is the number
    # section C compares against.
    Assert 'A4 the agent roster reports a shell pid for that session' ($shellPidA -gt 0)

    $metaPath = Find-SessionsFile $tmp 45
    $recA = Read-HolderRecord $metaPath $sessionId
    Assert 'A5 sessions.json names the holder control pipe for that session' (
        $null -ne $recA -and [string]$recA.holder_pipe -match 'pty-host')
    $holderPid = if ($recA) { [int]$recA.holder_pid } else { 0 }
    Assert 'A6 the recorded pid IS a live --pty-host holder' (
        $holderPid -gt 0 -and
        (@((Get-TestHolders) | Where-Object { [int]$_.ProcessId -eq $holderPid }).Count -eq 1))
    # How many holders exist now, so section C can prove adoption did not spawn
    # another one beside the shell it was supposed to pick up.
    $holderCountA = (Get-TestHolders).Count
    Assert 'A7 every alive session is holder-backed' (
        $holderCountA -gt 0 -and $holderCountA -eq $aliveA.Count)

    # A marker that must still be readable after the manager restarts. Typed,
    # not injected: only a working shell can echo it back.
    $marker = "T906MARK$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $marker, 'Enter') "$tmp\keys-a.txt" 12 | Out-Null
    $sawMarker = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $txt = Read-PaneText $tmp $pane 'a'
        if (([regex]::Matches($txt, [regex]::Escape($marker))).Count -ge 2) { $sawMarker = $true; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A8 the pane is LIVE and the marker is in its scrollback' $sawMarker

    # ========================================================================
    Say "== B: kill ONLY the session manager - app, holder and shell live on"
    # ========================================================================
    Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Assert 'B1 premise: the session manager is really gone' (-not (Test-Alive $agentPid))
    Assert 'B2 the app did NOT restart (recovery is in place)' (Test-Alive $appPid)
    Assert 'B3 the holder survived the manager (T905)' (Test-Alive $holderPid)
    Assert 'B4 the shell survived the manager (T905)' (Test-Alive $shellPidA)

    # ========================================================================
    Say "== C: adoption - the replacement manager picks the SAME shell back up"
    # ========================================================================
    $newAgentPid = Wait-NewAgent (@($before) + @($agentPid)) 60
    Assert 'C1 a replacement session manager came up' ($newAgentPid -ne 0 -and $newAgentPid -ne $agentPid)

    $rowsC = Wait-AliveCount $tmp 'c' 1 60
    $aliveC = Alive-Rows $rowsC
    $shellPidC = 0
    foreach ($r in $aliveC) { if ([string]$r.id -eq $sessionId) { $shellPidC = [int]$r.pid } }
    if ($shellPidC -le 0 -and $aliveC.Count -ge 1) { $shellPidC = [int]$aliveC[0].pid }

    # THE assertion. A relaunch would give a working pane with a DIFFERENT pid;
    # only adoption gives the same one.
    $adopted = ($shellPidA -gt 0 -and $shellPidC -eq $shellPidA -and (Test-Alive $shellPidA))
    if ($NegativeControl) { $adopted = -not $adopted }
    Assert 'C2 the session is alive again with the SAME shell pid (adopted, not relaunched)' $adopted

    $sameHolder = (Test-Alive $holderPid) -and
        (@((Get-TestHolders) | Where-Object { [int]$_.ProcessId -eq $holderPid }).Count -eq 1)
    if ($NegativeControl) { $sameHolder = -not $sameHolder }
    Assert 'C3 the same holder is still serving it (no second holder spawned)' $sameHolder

    Assert 'C4 no holder was added (adoption picked shells up, it did not respawn them)' (
        (Get-TestHolders).Count -eq $holderCountA)

    # Scrollback continuity: what the user typed before the manager died is
    # still on screen afterwards.
    $txtC = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $txtC = Read-PaneText $tmp $pane 'c'
        if ($txtC -match [regex]::Escape($marker)) { break }
        Start-Sleep -Milliseconds 700
    }
    $kept = ($txtC -match [regex]::Escape($marker))
    if ($NegativeControl) { $kept = -not $kept }
    Assert 'C5 the pre-restart marker is still in the pane scrollback' $kept

    # A session that never stopped must not be told it restarted.
    $divider = 'sessionrestarted'   # whitespace-stripped form of the divider text
    $noDivider = ($txtC -notmatch $divider)
    if ($NegativeControl) { $noDivider = -not $noDivider }
    Assert 'C6 no "session restarted" divider was drawn (nothing restarted)' $noDivider

    # And it still works: fresh input reaches the child and output comes back.
    Assert 'C7 the pane is LIVE again (fresh input round-trips)' (
        Test-PaneLive -Exe $Exe -Target $pane -Tmp $tmp -Tag 'C' -TimeoutSec 40)

    # ========================================================================
    Say "== D: orphan reap - a holder no record names is shut down at startup"
    # ========================================================================
    # Force the state the sweep exists for: the holder is alive, and nothing on
    # disk points at it any more. Before T906 that shell ran until the box
    # rebooted, unreachable by every agent and every viewer.
    Stop-AppAndAgent
    Assert 'D1 premise: the orphaned holder is still running' (Test-Alive $holderPid)
    $metaNow = @(Get-ChildItem -Path $tmp -Filter 'sessions.json' -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $metaNow) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    Assert 'D2 premise: no session record names it any more' (
        @(Get-ChildItem -Path $tmp -Filter 'sessions.json' -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0)

    $beforeD = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
        '--title=t906-reap', '--window-width=100', '--window-height=30') | Out-Null
    $reapAgent = Wait-NewAgent $beforeD 60
    Assert 'D3 premise: a fresh session manager started' ($reapAgent -ne 0)

    $gone = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Alive $holderPid)) { $gone = $true; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'D4 the orphaned holder was reaped by the starting manager' $gone
    $shellGone = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Alive $shellPidA)) { $shellGone = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert 'D5 its shell went with it (the holder owns the kill-on-close job)' $shellGone
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-Everything
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard holder-adopt -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'HOLDER-ADOPT' -Pass $script:passes -Fail $script:failures
