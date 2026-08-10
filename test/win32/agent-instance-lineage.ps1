# T167 acceptance: a test sandbox must be able to run its OWN local agent.
#
# THE TRAP THIS CLOSES
#
# The agent takes a per-user, per-LINEAGE single-instance guard (a named mutex),
# and the lineage is a compile-time fact: `local-debug` for every debug build on
# the box. So a debug agent already running - the one holding the loop's own
# panes, a leftover from an earlier suite - refuses every sandbox's agent with
# exit 183. The sandbox does not go red: `sharedConnection` answers null on a
# failed resolve by design, the app opens plain exec panes, and the suite goes on
# to report on "session persistence" while exercising the NON-persistent path.
# Measured 2026-07-29 building upgrade-no-fork.ps1: every sandbox run came up
# with an empty local-agent-debug\ until the box's zig-out agent was killed.
#
# `GHOZTTY_AGENT_INSTANCE=<suffix>` names a distinct lineage - guard, lock and
# heartbeat, plus the app's state dir, its agent pipe and the +sessions CLI - so
# a sandbox coexists with the box's agents instead of killing them.
#
# ARMS (each isolates exactly one variable):
#
#   A  control: TWO agents in the SAME lineage, same LOCALAPPDATA, different
#      pipes. The second must still be refused (183). Scored first: without it,
#      B proves nothing - a build that had simply removed the guard would pass
#      B and leave two daemons fighting over one pipe.
#   B  two more agents, differing from A1 ONLY in GHOZTTY_AGENT_INSTANCE, must
#      both come up and leave A1 running: three live agents, one box.
#   C  `+sessions` reads the SUFFIXED state dir - and cannot find that agent
#      with the suffix cleared, which is what proves the derivation moved.
#   D  end to end, the arm that matters: the same GUI launch, twice, differing
#      only in the value of GHOZTTY_AGENT_INSTANCE. With a suffix a live agent
#      holds it; with a suffix another agent already owns, the app comes up
#      SILENTLY non-persistent - the exact original failure, reproduced.
#
# Hermetic and considerate: private LOCALAPPDATA everywhere, an IPC pipe suffix,
# a background desktop, and it only ever kills processes IT started (by pid).
# It deliberately does NOT clear the debug lineage first - not needing to is the
# whole claim.
#
#   powershell -NoProfile -File test\win32\agent-instance-lineage.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Interactive,
    # Self-test for arm D's teeth: give D2 a lineage that is ALREADY held, i.e.
    # exactly the world before this feature existed. D2's two positive
    # assertions must then go red and nothing else may move. Without a knob like
    # this, "D2 passed" is only evidence that the app publishes a port.json,
    # not that the suffix is what let it.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-t167-$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# Every process this script starts, so cleanup can be by PID. Killing by name or
# by "*zig-out*" would take the loop's own agent with it - the exact rudeness
# this feature exists to make unnecessary.
$script:mine = New-Object System.Collections.Generic.List[int]

function Start-Agent($tag, $instance, $lad, $pipe, $portFile) {
    $savedInst = $env:GHOZTTY_AGENT_INSTANCE
    $savedLad = $env:LOCALAPPDATA
    if ($null -eq $instance) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $instance }
    $env:LOCALAPPDATA = $lad
    $sess = [System.IO.Path]::ChangeExtension($portFile, '.sessions.json')
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -ArgumentList "--listen-pipe=$pipe", "--port-file=$portFile", "--sessions-file=$sess", '--headless'
    # Cache the handle BEFORE the child can exit, or ExitCode reads back empty
    # and a refused agent scores as a running one.
    $null = $p.Handle
    if ($null -eq $savedInst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $savedInst }
    $env:LOCALAPPDATA = $savedLad
    $script:mine.Add([int]$p.Id)
    return $p
}

# Wait for an agent to publish its info file (the "I bound the pipe" signal).
function Wait-PortFile($path, $timeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-Exit($proc, $timeoutSec = 10) {
    if ($proc.WaitForExit($timeoutSec * 1000)) { $proc.WaitForExit(); return $proc.ExitCode }
    return $null
}

# `ghoztty <argv>` under an explicit lineage + LOCALAPPDATA. Returns the exit
# code (null on timeout); output lands in $out.
# persistence: a CLI invocation - it opens no window, so there is nothing to restore.
function Run-Cli($argv, $out, $instance, $lad, $timeoutSec = 20) {
    $savedInst = $env:GHOZTTY_AGENT_INSTANCE
    $savedLad = $env:LOCALAPPDATA
    if ($null -eq $instance) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $instance }
    if ($null -ne $lad) { $env:LOCALAPPDATA = $lad }
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    if ($null -eq $savedInst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $savedInst }
    $env:LOCALAPPDATA = $savedLad
    $code = $null
    if ($p.WaitForExit($timeoutSec * 1000)) { $p.WaitForExit(); $code = $p.ExitCode }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    return $code
}
function Out-Text($f) { if (Test-Path $f) { (Get-Content $f -Raw) -replace "`0", '' } else { '' } }

$null = Assert-GhozttyIsolatedBuild -Exe $Exe

New-Item -ItemType Directory -Force $root | Out-Null
$saved = @{
    lad  = $env:LOCALAPPDATA
    bin  = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe = $env:GHOZTTY_PIPE_SUFFIX
    inst = $env:GHOZTTY_AGENT_INSTANCE
}
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# The app arms use +list/+sessions as oracles; a user instance answering the
# shared IPC pipe would answer them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-t167'

# Lineage names. Short (the suffix is capped at 24 chars) and per-run unique, so
# two concurrent runs of this script do not collide either.
$lineA = "t167a$PID"
$lineB = "t167b$PID"
$lineC = "t167c$PID"
$lineD = "t167d$PID"

$stateShared = Join-Path $root 'shared'
New-Item -ItemType Directory -Force $stateShared | Out-Null

$td = $null
try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
Say "== A: control - the guard still guards WITHIN one lineage"
# ============================================================================
# Scored first. If A passes trivially (both agents up), the guard is gone and
# every claim below is meaningless.
$a1Port = Join-Path $stateShared 'a1.json'
$a1 = Start-Agent 'a1' $lineA $stateShared "\\.\pipe\ghoztty-t167-a1-$PID" $a1Port
Assert "A1 (lineage $lineA) published its info file" (Wait-PortFile $a1Port 12)
Assert "A1 is running" (-not $a1.HasExited)

$a2Port = Join-Path $stateShared 'a2.json'
$a2 = Start-Agent 'a2' $lineA $stateShared "\\.\pipe\ghoztty-t167-a2-$PID" $a2Port
$a2Code = Wait-Exit $a2 12
Assert "A2 in the SAME lineage was refused (exit 183, got '$a2Code')" ($a2Code -eq 183)
Assert "A2 published nothing" (-not (Test-Path $a2Port))
Assert "A1 survived the challenge" (-not $a1.HasExited)

# ============================================================================
Say "== B: a different lineage coexists - three live agents, one box"
# ============================================================================
# Differs from A2 in exactly one thing: the value of GHOZTTY_AGENT_INSTANCE.
$bPort = Join-Path $stateShared 'b.json'
$b = Start-Agent 'b' $lineB $stateShared "\\.\pipe\ghoztty-t167-b-$PID" $bPort
Assert "B (lineage $lineB) came up where A2 was refused" (Wait-PortFile $bPort 12)
Assert "B is running" (-not $b.HasExited)

$cPort = Join-Path $stateShared 'c.json'
$c = Start-Agent 'c' $lineC $stateShared "\\.\pipe\ghoztty-t167-c-$PID" $cPort
Assert "C (lineage $lineC) came up too" (Wait-PortFile $cPort 12)
Assert "A1 and B are both still alive alongside C" `
    ((-not $a1.HasExited) -and (-not $b.HasExited) -and (-not $c.HasExited))

# ============================================================================
Say "== C: +sessions reads the SUFFIXED state dir"
# ============================================================================
# The CLI derives `<LOCALAPPDATA>\ghoztty\local-agent-debug[-<suffix>]\port.json`.
# Put agent D's info file exactly where that derivation points and ask the real
# CLI to find it - then ask again with the suffix cleared, which must NOT.
$ladD = Join-Path $root 'cli'
$dirD = Join-Path $ladD "ghoztty\local-agent-debug-$lineD"
New-Item -ItemType Directory -Force $dirD | Out-Null
$dPort = Join-Path $dirD 'port.json'
$d = Start-Agent 'd' $lineD $ladD "\\.\pipe\ghoztty-t167-d-$PID" $dPort
Assert "D came up in its own lineage" (Wait-PortFile $dPort 12)

$outD = Join-Path $root 'sessions-suffixed.txt'
$codeD = Run-Cli @('+sessions') $outD $lineD $ladD 25
$textD = Out-Text $outD
Assert "+sessions with the suffix reached D (exit 0, got '$codeD')" ($codeD -eq 0)
Assert "+sessions reported an empty roster: $($textD.Trim())" ($textD -match 'No sessions')

$outN = Join-Path $root 'sessions-bare.txt'
$codeN = Run-Cli @('+sessions') $outN $null $ladD 25
Assert "+sessions WITHOUT the suffix cannot see D (nonzero, got '$codeN')" ($codeN -ne 0)

# ============================================================================
Say "== D: end to end - the same GUI launch, twice, one env var apart"
# ============================================================================
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

# One app arm. Returns @{ port; alive } - whether its agent published, and
# whether the agent roster has a live session behind the pane.
function Invoke-AppArm($tag, $instance) {
    $lad = Join-Path $root "app-$tag"
    New-Item -ItemType Directory -Force $lad | Out-Null
    $agentDir = Join-Path $lad "ghoztty\local-agent-debug-$instance"

    $savedInst = $env:GHOZTTY_AGENT_INSTANCE
    $savedLad = $env:LOCALAPPDATA
    $env:GHOZTTY_AGENT_INSTANCE = $instance
    $env:LOCALAPPDATA = $lad
    # persistence: ON, explicitly - this arm's whole subject is whether the
    # app's local agent comes up, which only happens with persistence enabled.
    $app = $null
    try {
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=true') `
            -StdErr (Join-Path $root "applog-$tag.txt")
    } catch { Write-Host "  (launch failed: $_)" }
    $env:GHOZTTY_AGENT_INSTANCE = $savedInst
    $env:LOCALAPPDATA = $savedLad
    if ($null -eq $app) { return @{ port = $false; alive = 0; pid = 0 } }
    $script:mine.Add([int]$app.Pid)
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return @{ port = $false; alive = 0; pid = [int]$app.Pid } }

    $port = Wait-PortFile (Join-Path $agentDir 'port.json') 20
    $alive = 0
    if ($port) {
        $out = Join-Path $root "roster-$tag.json"
        if ((Run-Cli @('+sessions', '--json') $out $instance $lad 25) -eq 0) {
            $raw = Out-Text $out
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                try {
                    $obj = $raw | ConvertFrom-Json
                    $rows = if ($obj -is [System.Array]) { $obj } else { @($obj) }
                    $alive = @($rows | Where-Object { $_.alive }).Count
                } catch {}
            }
        }
    }
    return @{ port = $port; alive = $alive; pid = [int]$app.Pid }
}

# D1 - the trap, reproduced: the app's own agent is refused because A1 already
# holds that lineage's guard. Nothing goes wrong loudly; there is simply no
# agent, and the app quietly opens exec panes.
$d1 = Invoke-AppArm 'blocked' $lineA
Assert "D1 the GUI came up" ($d1.pid -ne 0)
Assert "D1 with a lineage A1 already holds, NO agent published (the silent trap)" `
    (-not $d1.port)
if ($d1.pid -ne 0) { Stop-Process -Id $d1.pid -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

# D2 - the fix: the same launch, a lineage nobody holds. Its agent comes up in
# the sandbox's own state dir, with A1/B/C/D still running next to it.
$lineE = if ($TeethCheck) { $lineA } else { "t167e$PID" }
if ($TeethCheck) { Say "  (teeth check: D2 reuses lineage $lineA - its two positive assertions MUST fail)" }
$d2 = Invoke-AppArm 'own' $lineE
Assert "D2 the GUI came up" ($d2.pid -ne 0)
Assert "D2 with its own lineage, the sandbox's agent published port.json" ($d2.port)
Assert "D2 the pane is backed by a LIVE session (got $($d2.alive) alive)" ($d2.alive -ge 1)
Assert "D2 left every other agent on the box running" `
    ((-not $a1.HasExited) -and (-not $b.HasExited) -and (-not $c.HasExited) -and (-not $d.HasExited))

} finally {
    foreach ($id in $script:mine) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
    if ($td) {
        # Also the standing background-desktop claim: nothing this script
        # launched ever stole the user's foreground.
        $fgSeen = @(Stop-TestForegroundWatch)
        $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
        Assert "no test-desktop app ever became foreground" ($leaked.Count -eq 0)
        Remove-TestDesktop $td
    } else {
        $null = Stop-TestForegroundWatch
    }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    if ($null -eq $saved.inst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $saved.inst }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host "ALL PASS ($script:passes checks)" -ForegroundColor Green; exit 0 }
Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red
exit 1
