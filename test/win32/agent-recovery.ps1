# T145 acceptance: IN-PLACE local-agent crash recovery.
#
# The defect: when the local ghoztty-agent dies while the GUI stays up, every
# persistent pane is frozen — its PTY went with the agent and the app's shared
# connection is dead. Before T145 the panes stayed dead until the user quit and
# relaunched, which is the exact failure session persistence exists to prevent.
#
# Measured by OUTCOME, never by log scraping:
#
#   A: baseline — a 2-pane window, both panes agent-backed and RESPONSIVE
#      (a marker typed in and read back), with the app pid and shell pids
#      recorded.
#   B: kill ONLY the agent. The app process must still be the SAME pid and must
#      still answer IPC — that is what makes this "in place" rather than a
#      relaunch. This section also proves the trap is ARMED: with the agent
#      gone, the panes are genuinely broken before recovery is asserted.
#   C: recovery — within the settle window + re-dial, the window is back to 2
#      panes and BOTH ARE RESPONSIVE AGAIN (a fresh marker round-trips). The
#      shell pids are NEW (the children died with the agent; the respawned
#      agent RELAUNCHes them), which is what separates a real rebuild from a
#      pane that merely still exists.
#   D: the e65cfa4d5 lesson — recovery must not KILL the sessions it recovers.
#      The alive-session count is 2 after recovery AND still 2 after the
#      departing surfaces have had time to finish tearing down (their DETACH
#      must never have been a CLOSE).
#   E: topology is preserved, not flattened: still one window, one tab, a split
#      of exactly two leaves, and the pane's registered IPC name still resolves.
#
# Fully hermetic: a per-run $env:LOCALAPPDATA and GHOSTTY_LOCAL_AGENT_BIN, and
# it ONLY ever kills ghoztty / ghoztty-agent processes launched from the repo
# zig-out with THIS run's state dir — never the user's real release instance.
#
#   powershell -NoProfile -File test\win32\agent-recovery.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-agent-recovery-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
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

# The agent processes belonging to THIS run (their command line names this
# run's state dir). Never the user's, never another test's.
function Get-RunAgents($tmp) {
    # Unary comma: PowerShell unwraps a 1-element array on return, and every
    # caller here does arithmetic on .Count.
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$tmp*" })
}
function Show-Agents($tmp, $tag) {
    "    [$tag] agents for this run:"
    foreach ($a in (Get-RunAgents $tmp)) { "      pid=$($a.ProcessId) $($a.CommandLine)" }
}

function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}

# Same, but the arguments are passed as a real ARRAY straight to the exe.
# `cmd /c` re-parses the whole line and eats the inner quotes, so an argument
# containing a space (`+send-keys ... "echo MARKER"`) arrives split in two —
# which is how the first run of this script reported a healthy pane as
# unresponsive. Nothing that carries a space may go through Run-Cli.
function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    # The TIMED WaitForExit returns before the Process object has published
    # ExitCode; the argument-less overload is what makes it readable. Without
    # this every call reads back $null and a healthy pane looks unresponsive.
    # Touching .Handle caches the process handle; without it PowerShell cannot
    # read ExitCode once the process has exited (it comes back empty, which
    # every caller reads as failure).
    $null = $p.Handle
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tmp, $tag, $timeoutSec = 12) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" $timeoutSec
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return , @() }
    if ($null -ne $tree.data) { return , @($tree.data.windows) }
    return , @($tree.windows)
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
# Every terminal leaf across every window/tab, in tree order.
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Leaf-Count($tree) { return (All-Leaves $tree).Count }

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Rows($rows) { return @($rows | Where-Object { $_.alive -eq $true }) }
function Alive-Pids($rows) {
    return , @(Alive-Rows $rows | ForEach-Object { [int]$_.pid } | Sort-Object)
}
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Alive-Rows $rows).Count -eq $target) { return , $rows }
        Start-Sleep -Milliseconds 500
    }
    return , $rows
}

# THE liveness oracle for a pane: type a unique marker and read it back. A pane
# whose PTY is gone still EXISTS in +list — only a round-trip proves it works.
function Test-PaneResponsive($tmp, $target, $tag, $timeoutSec = 20) {
    $marker = "T145x$($tag)x$(Get-Random -Maximum 999999)"
    # The command is assembled from SPACE-FREE positional arguments plus the
    # `Space` key name. `+send-keys` concatenates its positionals, so this types
    # exactly `echo <marker>` — and nothing in the chain (PowerShell, the exe's
    # argv, cmd) ever sees a quoted argument to re-quote. A quoted `"echo M"`
    # reaches cmd WITH its quotes and dies as "not recognized as an internal or
    # external command", which is how the first run of this script scored a
    # working pane as broken.
    Run-CliArgs @('+send-keys', "--target=$target", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    # Deliberately NOT gated on send-keys' exit code: the marker coming back is
    # the oracle, and a stricter gate only adds a way for the harness to score
    # a working pane as broken.
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        # A wide line budget, because the wrap above means one MARKER costs one
        # line per character. At --lines=25 the marker fell off the top of the
        # window and the oracle reported a working pane as dead.
        $rc = Run-Cli "+read --name=$target --lines=300" "$tmp\read-$tag.txt" 12
        if ($rc -eq 0) {
            # The window is minimized, so a split pane can be a couple of
            # columns wide and the terminal WRAPS the echoed marker across
            # lines — it is really there, one character per row. Collapsing all
            # whitespace is what makes the oracle measure "did the shell run
            # it?" instead of "how wide is the pane?" (the marker is
            # deliberately space-free so this cannot create a false positive).
            $txt = (Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', ''
            if ($txt -match [regex]::Escape($marker)) { return $true }
        }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# ============================================================================
"== A: baseline - a 2-pane agent-backed window, both panes responsive"
# ============================================================================
Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @('--title=t145-recovery') | Out-Null

$appProc = $null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $tree = Get-List $tmp 'a0' 10
    if ((Leaf-Count $tree) -ge 1) {
        $appProc = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
            Where-Object { $_.CommandLine -like '*t145-recovery*' })[0]
        break
    }
    Start-Sleep -Milliseconds 500
}
Assert "A1 the GUI came up and answers +list" ($null -ne $appProc)
if ($null -eq $appProc) {
    "AGENT-RECOVERY: $script:failures FAILURE(S)"
    $env:LOCALAPPDATA = $savedLocalAppData
    exit 1
}
$appPid = [int]$appProc.ProcessId

# Name the first pane, then split it so the topology under test is a real tree.
$firstLeaf = (All-Leaves (Get-List $tmp 'a1' 10))[0]
Run-Cli "+split --pane=$($firstLeaf.id) --name=t145b --direction=right" "$tmp\split.txt" 15 | Out-Null

$treeA = $null
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $treeA = Get-List $tmp 'a2' 10
    if ((Leaf-Count $treeA) -eq 2) { break }
    Start-Sleep -Milliseconds 500
}
Assert "A2 the window has exactly 2 panes" ((Leaf-Count $treeA) -eq 2)

$paneA = (All-Leaves $treeA)[0]
$rowsA = Wait-AliveCount $tmp 'a' 2 25
Assert "A3 both panes are agent-backed (2 live sessions)" ((Alive-Rows $rowsA).Count -eq 2)
$pidsA = Alive-Pids $rowsA
Assert "A4 both live sessions report a real child pid" (@($pidsA | Where-Object { $_ -gt 0 }).Count -eq 2)

Assert "A5 the named pane is responsive before the crash" (Test-PaneResponsive $tmp 't145b' 'a' 25)

# ============================================================================
"== B: kill ONLY the agent - the app survives with the SAME pid"
# ============================================================================
$agents = Get-RunAgents $tmp
if ($agents.Count -ne 1) { Show-Agents $tmp 'B' }
Assert "B1 exactly one agent belongs to this run" ($agents.Count -eq 1)
$agentPid = if ($agents.Count -ge 1) { [int]$agents[0].ProcessId } else { 0 }
foreach ($a in $agents) { Stop-Process -Id $a.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

Assert "B2 the agent process is gone" (
    $null -eq (Get-Process -Id $agentPid -ErrorAction SilentlyContinue))

$stillHere = Get-Process -Id $appPid -ErrorAction SilentlyContinue
Assert "B3 the APP is still alive with the same pid (in place, not a relaunch)" ($null -ne $stillHere)

# The trap must be ARMED: with the agent dead the panes are genuinely broken.
# If this passes, the section-C assertions would be vacuous.
Assert "B4 the panes are BROKEN before recovery (trap armed)" (
    -not (Test-PaneResponsive $tmp 't145b' 'b' 4))

# ============================================================================
"== C: recovery - the panes come back, on NEW children, with no relaunch"
# ============================================================================
# Settle window (5s) + re-dial/spawn (<=2s) + agent restore + RELAUNCH.
$rowsC = Wait-AliveCount $tmp 'c' 2 45
Assert "C1 two sessions are alive again on the respawned agent" (
    (Alive-Rows $rowsC).Count -eq 2)

$newAgents = Get-RunAgents $tmp
Assert "C2 a fresh agent is running for this run" ($newAgents.Count -ge 1)
Assert "C3 it is NOT the process that was killed" (
    @($newAgents | Where-Object { [int]$_.ProcessId -eq $agentPid }).Count -eq 0)

$stillHere = Get-Process -Id $appPid -ErrorAction SilentlyContinue
Assert "C4 the app pid never changed across recovery" ($null -ne $stillHere)

$pidsC = Alive-Pids $rowsC
$newPids = @($pidsC | Where-Object { $pidsA -notcontains $_ })
if ($newPids.Count -ne 2) { "    [C5] before=$($pidsA -join ',') after=$($pidsC -join ',')" }
Assert "C5 the shells are NEW children (the old ones died with the agent)" (
    $newPids.Count -eq 2)

Assert "C6 the named pane is RESPONSIVE again - the actual defect" (
    Test-PaneResponsive $tmp 't145b' 'c' 30)

# ============================================================================
"== D: recovery must not kill the sessions it recovers (e65cfa4d5)"
# ============================================================================
# The departing surfaces tear down asynchronously. If any of them had been
# marked close-intent, its CLOSE would land AFTER the new panes attached and
# terminate a session a live pane is using. Waiting here is the point.
Start-Sleep -Seconds 6
$rowsD = Get-Sessions $tmp 'd'
Assert "D1 still exactly 2 live sessions after the old surfaces finished" (
    (Alive-Rows $rowsD).Count -eq 2)
Assert "D2 the pane still works after the teardown window" (
    Test-PaneResponsive $tmp 't145b' 'd' 20)

# ============================================================================
"== E: the topology was rebuilt, not flattened"
# ============================================================================
$treeE = Get-List $tmp 'e' 12
Assert "E1 still exactly one window" ((Windows-Of $treeE).Count -eq 1)
Assert "E2 still exactly 2 panes in a split" ((Leaf-Count $treeE) -eq 2)
$tabsE = @((Windows-Of $treeE)[0].tabs)
Assert "E3 still exactly one tab" ($tabsE.Count -eq 1)
Assert "E4 the tab's root is a split, not a lone leaf" ($tabsE[0].splits.type -eq 'split')
# The IPC name survived: it is re-registered onto the rebuilt pane, so a target
# that worked before the crash still resolves after it.
$rcE = Run-Cli "+read --name=t145b --lines=1" "$tmp\read-e.txt" 12
Assert "E5 the pane's IPC name still resolves after the rebuild" ($rcE -eq 0)
# The stable pane id (T113) is PRESERVED across the rebuild, exactly as it is
# across a launch restore: the id is baked into the shell as $GHOZTTY_PANE_ID,
# so a recovery that minted a fresh one would leave every pane unable to name
# itself. (The first version of this script asserted the opposite — that a
# rebuilt pane is a "new" surface — which would have passed only on a build
# that broke the guarantee.)
$paneE = (All-Leaves $treeE)[0]
Assert "E6 the rebuilt pane kept its stable pane id" ($paneE.id -eq $paneA.id)

# ============================================================================
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "AGENT-RECOVERY: ALL PASS ($script:passes)"; exit 0 }
"AGENT-RECOVERY: $script:failures FAILURE(S) / $script:passes passed"
exit 1
