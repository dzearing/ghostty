# T907 acceptance: the background session manager UPDATES ITSELF while you keep
# working - no dialog, no lost session.
#
# In the user's terms: a newer build of the process that keeps your terminal
# sessions alive lands on disk, and it takes it. Your panes keep running the same
# programs; nothing asks you anything; nothing closes. Before this, a box with one
# always-open pane could only adopt an agent fix by closing every session (the
# mandatory confirmation) or by rebooting - so in practice it stayed old (T662).
#
# The measurement that separates this from a restart is the SAME ONE T906 uses:
# the shell pid. A restart gives you a working pane with a NEW pid; a handoff
# gives you the same pid, because the shell never stopped - it lives in a
# per-session `--pty-host` holder (T905) that both agents talk to in turn.
#
# Sections:
#   A. Baseline. A holder-backed, agent-backed pane with a marker in its
#      scrollback, served by an agent running from `ghoztty-agent.exe.bak` -
#      exactly the shape every delivery leaves behind, since a running exe cannot
#      be overwritten and is renamed out of the way. `+sessions --agent --json`
#      must already report this agent as handoff-READY.
#   B. The handoff. A newer build sits at the canonical path; the agent spawns it,
#      waits for READY, and exits. Measured: the old agent process is GONE, a new
#      one is serving, and it is running the CANONICAL binary.
#   C. Nothing was lost. Same shell pid, same holder process, the marker from
#      section A still in the scrollback, and the pane answers fresh input.
#   D. ROLLBACK. The same handoff with a successor that starts and dies at once.
#      The ORIGINAL agent must still be serving and its pane must still work - the
#      "never neither" property. (The stand-in is `ping.exe`: it answers
#      `--version` with a parseable line and then refuses our arguments and exits,
#      which is precisely the failure mode the rollback exists for.)
#   E. LAZY DRAIN. With holder-backed spawning off, every live session is one the
#      agent owns directly and CANNOT be carried across a process boundary. The
#      handoff must WAIT - not proceed, not give up - and `+sessions --agent`
#      must name the count that is holding it back.
#
# `-NegativeControl` inverts the seven handoff-specific arms (B1-B3, C1-C4) and
# nothing else, so a run that scores this build as NOT handing off is available on
# demand - and exactly those seven go red, which is what makes them teeth-checked
# rather than decorative.
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint (lib\Isolation),
# a per-run COPY of the agent under test (never the installed one), and only
# processes whose ExecutablePath is under that per-run directory - or the exe
# under test - are ever stopped.
#
#   powershell -NoProfile -File test\win32\agent-handoff.ps1
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
    Write-TestAssertedNothing -Label 'AGENT-HANDOFF' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'AGENT-HANDOFF' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$root = Join-Path $env:TEMP "ghoztty-agent-handoff-$PID"
$tmp = Join-Path $root 'run'
$agentDir = Join-Path $root 'agentdir'
# The RUNNING agent's image, in the shape a delivery leaves it: renamed out of
# the way so the newer build could take the canonical name.
$runningAgent = Join-Path $agentDir 'ghoztty-agent.exe.bak'
# What a handoff would adopt.
$canonicalAgent = Join-Path $agentDir 'ghoztty-agent.exe'

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedForce = $env:GHOZTTY_AGENT_HANDOFF_FORCE
$savedInterval = $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS

# --- process helpers: ONLY the binaries under test ---------------------------
#
# The running agent's image name is `ghoztty-agent.exe.bak`, so a `Name=` filter
# for `ghoztty-agent.exe` would walk straight past the very process this script
# is about. Matched on ExecutablePath under the per-run directory instead, which
# is also what keeps the user's installed agent (and its live sessions) out of
# reach of every Stop-Process below.
function Get-RunAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ghoztty-agent%'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($agentDir, 'OrdinalIgnoreCase') })
}
function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
# The session manager: an agent process that is NOT a per-session holder.
function Get-TestAgents {
    return , @((Get-RunAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return , @((Get-RunAgentProcs) | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
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
        if ($fresh.Count -gt 0) { return $fresh[0] }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# --- CLI plumbing (ghoztty.exe is GUI-subsystem: redirect through cmd) --------

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

function Get-Sessions([string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Get-AgentReport([string]$tag) {
    $code = Run-Cli '+sessions --agent --json' "$tmp\agent-$tag.json" 12
    if ($code -ne 0) { return $null }
    try { return ((Out-Text "$tmp\agent-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
function Alive-Rows($rows) { return , @($rows | Where-Object { $_.alive -eq $true }) }
function Wait-AliveCount([string]$tag, [int]$target, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tag
        if ((Alive-Rows $rows).Count -ge $target) { return , $rows }
        Start-Sleep -Milliseconds 600
    }
    return , $rows
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in (Windows-Of $tree)) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Get-Tree([string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
# `Test-PaneLive`, retried with a FRESH token each time.
#
# Not padding, and not a longer timeout in disguise: the probe SENDS ONCE and
# then polls, so a send that lands while the app is rebuilding its windows in
# place is typed into a surface that is about to be destroyed - and no amount of
# polling afterwards can make those keystrokes reappear. That rebuild is exactly
# what a handoff triggers (the link drops, the app settles for 5s, then replaces
# every agent-backed leaf), and the assertions before this one all complete in
# less time than the settle window. Measured: the pane answered a hand-typed
# token seconds later, while the one-shot probe had already given up.
function Test-PaneLiveRetry([string]$target, [string]$tag, [int]$attempts = 5, [int]$perAttemptSec = 25) {
    for ($i = 1; $i -le $attempts; $i++) {
        if (Test-PaneLive -Exe $Exe -Target $target -Tmp $tmp -Tag "$tag$i" -TimeoutSec $perAttemptSec) { return $true }
    }
    return $false
}

function Read-PaneText([string]$target, [string]$tag) {
    $rc = Run-Cli "+read --name=$target --lines=2000" "$tmp\read-$tag.txt" 12
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
}

# Launch the app and wait until it answers IPC AND a session manager is up.
# Returns @{ App = <pid>; Agent = <proc> }.
#
# `stateTag` gives the section its OWN `%LOCALAPPDATA%`, and that is not tidiness:
# the app persists a session layout there, so a second section launched over the
# first one's state RESTORES that layout - and the pane this section then splits
# off is a restored TOMBSTONE with no live shell behind it. Every "the pane still
# works" assertion downstream would then be measuring the wrong pane, which is
# how the drain arm managed to observe zero live sessions on a box with a window
# open.
function Start-AppAndWait([string]$title, [string]$paneName, [string]$stateTag, [int]$timeoutSec = 60) {
    $state = Join-Path $root "state-$stateTag"
    New-Item -ItemType Directory -Force $state | Out-Null
    $env:LOCALAPPDATA = $state

    $before = @((Get-TestAgents) | ForEach-Object { [int]$_.ProcessId })
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
        "--title=$title", '--window-width=100', '--window-height=30') | Out-Null

    $appPid = 0
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-boot.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-boot.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like "*$title*" })
            if ($app.Count -ge 1) { $appPid = [int]$app[0].ProcessId; break }
        }
        Start-Sleep -Milliseconds 600
    }
    if ($appPid -le 0) { return @{ App = 0; Agent = $null } }

    # Name a pane so +send-keys / +read have a stable target across the agent
    # swap (pane names are the APP's, and the app never restarts here).
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree 'boot'))) { if (-not $firstId) { $firstId = $lf.id } }
    if ($firstId) {
        Run-Cli "+split --pane=$firstId --name=$paneName --direction=right" "$tmp\split.txt" 20 | Out-Null
    } else {
        Run-Cli "+new-window --name=$paneName" "$tmp\newwin.txt" 20 | Out-Null
    }
    return @{ App = $appPid; Agent = (Wait-NewAgent $before $timeoutSec) }
}

try {
    New-Item -ItemType Directory -Force $tmp | Out-Null
    New-Item -ItemType Directory -Force $agentDir | Out-Null
    # A placeholder until the first section claims its own state dir: the
    # isolation probe below needs SOME LOCALAPPDATA, and it must not be the
    # user's.
    $env:LOCALAPPDATA = Join-Path $root 'state-boot'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
    # THE test fixture: the app spawns the RENAMED copy, so from inside that
    # process "the newer build on disk" is the canonical name beside it. Both
    # copies are of the binary under test, which is why the handoff has to be
    # FORCED - one tree cannot produce two build stamps.
    #
    # The canonical name is deliberately NOT created yet. A delivery lands while
    # the agent is already running, and the baseline below has to be measurable
    # before anything moves - with the file already there, the supervisor's first
    # tick would hand off before there was a pane to measure.
    Copy-Item -LiteralPath $AgentExe -Destination $runningAgent -Force
    Remove-Item -LiteralPath $canonicalAgent -Force -ErrorAction SilentlyContinue
    $env:GHOSTTY_LOCAL_AGENT_BIN = $runningAgent
    $env:GHOZTTY_AGENT_PTY_HOLDER = '1'
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = '1'
    $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = '2000'

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'hndof907')
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    Stop-Everything

    # ========================================================================
    Say "== A: baseline - a holder-backed pane served by a RENAMED agent image"
    # ========================================================================
    $pane = 't907p'
    $boot = Start-AppAndWait 't907-handoff' $pane 'a' 60
    $appPid = [int]$boot.App
    Assert 'A1 premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) { Write-TestVerdict -Label 'AGENT-HANDOFF' -Pass $script:passes -Fail $script:failures }
    Assert-GhozttyIsolated -Exe $Exe

    $agentA = $boot.Agent
    Assert 'A2 premise: a session manager is running' ($null -ne $agentA)
    if ($null -eq $agentA) { Write-TestVerdict -Label 'AGENT-HANDOFF' -Pass $script:passes -Fail $script:failures }
    $agentPidA = [int]$agentA.ProcessId
    Assert 'A3 premise: it is running the RENAMED image, as it is after any delivery' (
        [string]$agentA.ExecutablePath -eq $runningAgent)

    $paneLeaf = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $lv = @((All-Leaves (Get-Tree 'a')) | Where-Object { $_.name -eq $pane })
        if ($lv.Count -eq 1 -and $lv[0].session_id) { $paneLeaf = $lv[0]; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A4 the named pane exists and is agent-backed (it carries a session id)' ($null -ne $paneLeaf)
    $sessionId = if ($paneLeaf) { [string]$paneLeaf.session_id } else { '' }

    $rowsA = Wait-AliveCount 'a' 1 45
    $shellPidA = 0
    foreach ($r in (Alive-Rows $rowsA)) { if ([string]$r.id -eq $sessionId) { $shellPidA = [int]$r.pid } }
    Assert 'A5 the agent roster reports a shell pid for that session' ($shellPidA -gt 0)

    $holdersA = Get-TestHolders
    $holderPid = if ($holdersA.Count -ge 1) { [int]$holdersA[0].ProcessId } else { 0 }
    Assert 'A6 the session is holder-backed (its shell can outlive the manager)' ($holderPid -gt 0)

    # The report a user would run to ask "what will an update cost me?". It must
    # already say: nothing.
    $repA = Get-AgentReport 'a'
    Assert 'A7 +sessions --agent reports this agent as handoff-READY, with an empty drain' (
        $null -ne $repA -and [string]$repA.handoff -eq 'ready' -and [int]$repA.legacy_sessions -eq 0)

    $marker = "T907MARK$PID" + "Z"
    Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $marker, 'Enter') "$tmp\keys-a.txt" 12 | Out-Null
    $sawMarker = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $txt = Read-PaneText $pane 'a'
        if (([regex]::Matches($txt, [regex]::Escape($marker))).Count -ge 2) { $sawMarker = $true; break }
        Start-Sleep -Milliseconds 700
    }
    Assert 'A8 the pane is LIVE and the marker is in its scrollback' $sawMarker

    # ========================================================================
    Say "== B: the handoff - the agent adopts the newer build on its own"
    # ========================================================================
    # The delivery: a newer build lands under the canonical name while the agent
    # is serving. Nobody kills anything and nobody is asked - the supervisor
    # thread inside the running agent notices it, spawns it, waits for READY and
    # exits.
    Assert 'B0 premise: no handoff happened before the newer build existed' (Test-Alive $agentPidA)
    Copy-Item -LiteralPath $AgentExe -Destination $canonicalAgent -Force

    $agentB = Wait-NewAgent @($agentPidA) 90
    $handedOff = ($null -ne $agentB)
    if ($NegativeControl) { $handedOff = -not $handedOff }
    Assert 'B1 a successor session manager took over, with nobody asked' $handedOff

    $oldGone = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Alive $agentPidA)) { $oldGone = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if ($NegativeControl) { $oldGone = -not $oldGone }
    Assert 'B2 the predecessor exited (it retired only AFTER the successor was up)' $oldGone

    $fromCanonical = ($null -ne $agentB -and [string]$agentB.ExecutablePath -eq $canonicalAgent)
    if ($NegativeControl) { $fromCanonical = -not $fromCanonical }
    Assert 'B3 the successor is running the NEWER binary, not the renamed one' $fromCanonical

    # ========================================================================
    Say "== C: nothing was lost - same shell, same holder, same scrollback"
    # ========================================================================
    # Guarded on B, and that is not bookkeeping: every assertion below is "the
    # thing that was here before is still here", which is trivially true when
    # NOTHING HAPPENED. Without this, a build that never hands off scores a clean
    # section C - the exact false pass this script exists to make impossible.
    if (-not $NegativeControl -and ($null -eq $agentB)) {
        Write-Host "  SKIP C: no handoff took place, so 'nothing was lost' would measure nothing" -ForegroundColor Yellow
        $script:failures++
        Write-TestVerdict -Label 'AGENT-HANDOFF' -Pass $script:passes -Fail $script:failures
    }

    $rowsC = Wait-AliveCount 'c' 1 60
    $shellPidC = 0
    foreach ($r in (Alive-Rows $rowsC)) { if ([string]$r.id -eq $sessionId) { $shellPidC = [int]$r.pid } }

    # THE assertion. A restart gives a working pane with a DIFFERENT pid; only a
    # handoff gives the same one, because the shell never stopped.
    $kept = ($shellPidA -gt 0 -and $shellPidC -eq $shellPidA -and (Test-Alive $shellPidA))
    if ($NegativeControl) { $kept = -not $kept }
    Assert 'C1 the session is alive under the NEW manager with the SAME shell pid' $kept

    $sameHolder = ((Test-Alive $holderPid) -and (Get-TestHolders).Count -eq $holdersA.Count)
    if ($NegativeControl) { $sameHolder = -not $sameHolder }
    Assert 'C2 the same holder is still serving it (no second shell was spawned)' $sameHolder

    $txtC = ''
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $txtC = Read-PaneText $pane 'c'
        if ($txtC -match [regex]::Escape($marker)) { break }
        Start-Sleep -Milliseconds 700
    }
    $keptText = ($txtC -match [regex]::Escape($marker))
    if ($NegativeControl) { $keptText = -not $keptText }
    Assert 'C3 the pre-handoff marker is still in the pane scrollback' $keptText

    $noDivider = ($txtC -notmatch 'sessionrestarted')
    if ($NegativeControl) { $noDivider = -not $noDivider }
    Assert 'C4 no "session restarted" divider was drawn (nothing restarted)' $noDivider

    $liveC = Test-PaneLiveRetry $pane 'C'
    Assert 'C5 the pane is LIVE under the new manager (fresh input round-trips)' $liveC
    if (-not $liveC) {
        # Say WHAT was there instead. "The pane is dead" and "there is no pane by
        # that name any more" are different defects with different fixes, and a
        # bare red arm sends the next reader hunting through the wrong half.
        Say "    diagnostic: leaves seen ->"
        foreach ($lf in (All-Leaves (Get-Tree 'cdiag'))) {
            Say "      id=$($lf.id) name=$($lf.name) session=$($lf.session_id)"
        }
        Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', 'CDIAG', 'Enter') "$tmp\keys-cdiag.txt" 12 | Out-Null
        Say "    diagnostic: +send-keys said -> $((Out-Text "$tmp\keys-cdiag.txt") -replace '\s+', ' ')"
        Start-Sleep -Seconds 6
        $diagTxt = Read-PaneText $pane 'cdiag'
        Say "    diagnostic: CDIAG hits -> $(([regex]::Matches($diagTxt, 'CDIAG')).Count)"
        Say "    diagnostic: pane tail -> $($diagTxt.Substring([Math]::Max(0, $diagTxt.Length - 260)))"
        Say "    diagnostic: agent report -> $((Get-AgentReport 'cdiag' | ConvertTo-Json -Compress))"
    }

    # ========================================================================
    Say "== D: rollback - a successor that dies leaves the ORIGINAL agent serving"
    # ========================================================================
    # The failure the whole choreography is built around. The stand-in answers
    # `--version` (so the candidate looks real) and then refuses our arguments and
    # exits at once (so READY never comes) - which is exactly what a broken newer
    # build would do.
    Stop-Everything
    Copy-Item -LiteralPath $AgentExe -Destination $runningAgent -Force
    Remove-Item -LiteralPath $canonicalAgent -Force -ErrorAction SilentlyContinue

    $paneD = 't907d'
    $bootD = Start-AppAndWait 't907-rollback' $paneD 'd' 60
    Assert 'D1 premise: the app came up for the rollback arm' ([int]$bootD.App -gt 0)
    $agentD = $bootD.Agent
    Assert 'D2 premise: a session manager is running' ($null -ne $agentD)
    $agentPidD = if ($agentD) { [int]$agentD.ProcessId } else { 0 }

    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ping.exe') -Destination $canonicalAgent -Force
    # Give the supervisor several intervals to try, fail and roll back.
    Start-Sleep -Seconds 12
    Assert 'D3 the ORIGINAL manager is still running after a failed handoff' (Test-Alive $agentPidD)
    Assert 'D4 no successor took over (it never reported READY, so nothing was handed over)' (
        @((Get-TestAgents) | Where-Object { [int]$_.ProcessId -ne $agentPidD }).Count -eq 0)
    Assert 'D5 its pane still works - "neither agent" never happened' (
        Test-PaneLiveRetry $paneD 'D')

    # ========================================================================
    Say "== E: lazy drain - a session the agent owns directly holds it back"
    # ========================================================================
    Stop-Everything
    Copy-Item -LiteralPath $AgentExe -Destination $runningAgent -Force
    Remove-Item -LiteralPath $canonicalAgent -Force -ErrorAction SilentlyContinue
    # Holder-backed spawning OFF: the agent owns this session's ConPTY itself,
    # and a ConPTY cannot be carried across a process boundary at any price.
    $env:GHOZTTY_AGENT_PTY_HOLDER = '0'

    $paneE = 't907e'
    $bootE = Start-AppAndWait 't907-drain' $paneE 'e' 60
    Assert 'E1 premise: the app came up for the drain arm' ([int]$bootE.App -gt 0)
    $agentE = $bootE.Agent
    Assert 'E2 premise: a session manager is running' ($null -ne $agentE)
    $agentPidE = if ($agentE) { [int]$agentE.ProcessId } else { 0 }
    [void](Wait-AliveCount 'e' 1 45)
    Assert 'E3 premise: the live session is NOT holder-backed' ((Get-TestHolders).Count -eq 0)

    $repE = Get-AgentReport 'e'
    Assert 'E4 +sessions --agent reports the handoff as DRAINING and names the count' (
        $null -ne $repE -and [string]$repE.handoff -eq 'draining' -and [int]$repE.legacy_sessions -ge 1)

    Copy-Item -LiteralPath $AgentExe -Destination $canonicalAgent -Force
    Start-Sleep -Seconds 12
    Assert 'E5 the handoff WAITED - the same manager is still serving' (Test-Alive $agentPidE)
    Assert 'E6 no successor was spawned while a legacy session was live' (
        @((Get-TestAgents) | Where-Object { [int]$_.ProcessId -ne $agentPidE }).Count -eq 0)
    Assert 'E7 the pane is untouched by the waiting' (
        Test-PaneLiveRetry $paneE 'E')
} finally {
    Stop-Everything
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($null -ne $savedForce) { $env:GHOZTTY_AGENT_HANDOFF_FORCE = $savedForce }
    else { Remove-Item env:GHOZTTY_AGENT_HANDOFF_FORCE -ErrorAction SilentlyContinue }
    if ($null -ne $savedInterval) { $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $savedInterval }
    else { Remove-Item env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-handoff -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'AGENT-HANDOFF' -Pass $script:passes -Fail $script:failures
