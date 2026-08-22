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
# -Release (T269): run the SAME arms against the ReleaseFast staging build in
# zig-out-release, i.e. the lineage the user's own Ghoztty is in. That is the
# configuration the guard was actually blocking - `local`, held by the installed
# agent that owns the user's live panes - and until this switch existed there was
# no way to test it: a release-lineage run either lost the race (exit 183, the
# sandbox silently non-persistent) or, with a visible stale heartbeat, would have
# TERMINATED the user's agent and every session on it. The arms are unchanged;
# only the three isolating knobs are, and they are what the run proves:
#
#   GHOZTTY_AGENT_INSTANCE  guard mutex + heartbeat + agent pipe + state dir
#   GHOZTTY_PIPE_SUFFIX     the app's own IPC endpoint
#   LOCALAPPDATA            every file the app and the agent write
#
# Release-only launch hardening, because a release build self-heals things a
# debug build does not: GHOZTTY_URL_SCHEME=0 (it would repoint the user's real
# `ghoztty://` handler at a temp exe) and GHOZTTY_PATH_SELFHEAL=0 (belt and
# braces - the install-location gate already refuses a zig-out-release exe). The
# agent autostart Run key IS written in a release build; its value name carries
# the lineage suffix, so it can never be the user's `GhozttyAgent` entry, and the
# BYSTANDER assertions below prove that plus "the user's agent is still running"
# rather than assuming either.
#
#   powershell -NoProfile -File test\win32\agent-instance-lineage.ps1
#   powershell -NoProfile -File test\win32\agent-instance-lineage.ps1 -Release
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Run against the ReleaseFast staging build (zig-out-release) instead of the
    # debug one. Implies the release lineage, so every isolation knob above has
    # to hold: this is the arm that would drive the user's terminal if any of
    # them did not.
    [switch]$Release,
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
$script:skipped = 0
$root = Join-Path $env:TEMP "ghoztty-t167-$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# -Release retargets the two DEFAULT paths only; an explicit -Exe/-AgentExe is
# always obeyed (that is how a delivered install or a second staging tree gets
# measured). The staging tree is not built by this script: building it here would
# make one acceptance run take ten minutes, and the delivery scripts already own
# that build.
$DefaultDebugExe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
$DefaultDebugAgent = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
if ($Release) {
    if ($Exe -eq $DefaultDebugExe) { $Exe = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe' }
    if ($AgentExe -eq $DefaultDebugAgent) { $AgentExe = 'D:\git\ghoztty\zig-out-release\bin\ghoztty-agent.exe' }
    if (-not (Test-Path $Exe) -or -not (Test-Path $AgentExe)) {
        $script:skipped++
        Write-Host "SKIP  -Release: no staging build at $(Split-Path $Exe). Build it with:"
        Write-Host '        zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release'
        Write-Host ''
        # T271: this used to be `ALL PASS (0 checks, 1 SKIPPED)` at exit 0 - a
        # green verdict over a run that measured nothing at all.
        Write-TestVerdict -Pass 0 -Fail 0 -Skipped $script:skipped -Unit 'checks'
    }
}

# CLI invocations go through the `.com` twin when there is one (T245): a release
# `ghoztty.exe` is GUI-subsystem, and the whole point of the twin is that a
# console parent gets its stdout, its pipes and its exit code back. In the debug
# tree the `.exe` is already console-subsystem, so this is a no-op there.
$CliExe = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $CliExe)) { $CliExe = $Exe }

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
    # persistence: a CLI invocation - it opens no window, so there is nothing to
    # restore. (Repeated here rather than only on the function's own header: the
    # sweep looks six lines above the launch statement, and the header is seven.)
    $p = Start-Process -FilePath $CliExe -WindowStyle Hidden -PassThru `
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

# -Allow is the release mode's opt-in, and it is honest here for the reason the
# BuildMode doc gives: this script's SUBJECT is that build. What makes it SAFE is
# asserted below, not assumed - the lineage suffix on every launch, and the
# bystander checks at the end.
$buildMode = Assert-GhozttyIsolatedBuild -Exe $Exe -Allow:$Release
Say "build mode under test: $buildMode"
if ($Release) {
    # Positive control for the switch itself: a -Release run against a Debug
    # zig-out-release would exercise the -debug lineage and prove nothing about
    # the one the user is in.
    Assert "setup: -Release is measuring a release-lineage build (got '$buildMode')" `
        (-not (Test-GhozttyIsolatedBuildMode -Mode $buildMode))
}

# `local-agent` in the release lineage, `local-agent-debug` in the debug one -
# the same `build_config.is_debug` split the pipe name and the guard key use.
# Arms C and D derive the app's state dir from it, so a mode read wrong shows up
# as a missing port.json rather than as a silent pass.
$stateBase = if (Test-GhozttyIsolatedBuildMode -Mode $buildMode) { 'local-agent-debug' } else { 'local-agent' }

# BYSTANDERS (T269). Everything on the box that this run must leave exactly as it
# found it: the agents it did not start (in release mode that is the user's own,
# holding their live panes) and the autostart Run values it did not write.
function Get-BystanderAgentPids {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $script:mine -notcontains [int]$_.ProcessId } |
        ForEach-Object { [int]$_.ProcessId })
}
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
function Get-GhozttyRunValues {
    $props = (Get-ItemProperty $RunKey -ErrorAction SilentlyContinue)
    $map = @{}
    if ($props) {
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'GhozttyAgent*') { $map[$p.Name] = [string]$p.Value }
        }
    }
    return $map
}
$bystandersBefore = Get-BystanderAgentPids
$runValuesBefore = Get-GhozttyRunValues
Say "bystander agents before: $($bystandersBefore -join ' ')"

New-Item -ItemType Directory -Force $root | Out-Null
$saved = @{
    lad    = $env:LOCALAPPDATA
    bin    = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe   = $env:GHOZTTY_PIPE_SUFFIX
    inst   = $env:GHOZTTY_AGENT_INSTANCE
    scheme = $env:GHOZTTY_URL_SCHEME
    selfheal = $env:GHOZTTY_PATH_SELFHEAL
}
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# The app arms use +list/+sessions as oracles; a user instance answering the
# shared IPC pipe would answer them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = "-t167$PID"
if ($Release) {
    # A release build registers HKCU\Software\Classes\ghoztty at launch, pointed
    # at its own exe - i.e. it would hand the user's `ghoztty://` links to a
    # binary under zig-out-release. A debug build registers `ghoztty-debug://`
    # and never collides, which is why no other script has needed this.
    $env:GHOZTTY_URL_SCHEME = '0'
    $env:GHOZTTY_PATH_SELFHEAL = '0'
}

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
# The CLI derives `<LOCALAPPDATA>\ghoztty\<stateBase>[-<suffix>]\port.json`.
# Put agent D's info file exactly where that derivation points and ask the real
# CLI to find it - then ask again with the suffix cleared, which must NOT.
$ladD = Join-Path $root 'cli'
$dirD = Join-Path $ladD "ghoztty\$stateBase-$lineD"
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
    $agentDir = Join-Path $lad "ghoztty\$stateBase-$instance"

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
Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    foreach ($id in $script:mine) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    # Arm D's agents are spawned BY THE APP, detached, so they are not in
    # $script:mine and used to outlive the run: measured 2026-08-11 (T269), a
    # zig-out-release agent still holding this run's temp state dir - and its own
    # image file - after the script had exited and its $root was deleted. Matched
    # on THIS RUN'S root, never on the image name: the user's agent runs the same
    # image name and, in the release lineage, the same image path.
    # cleanslate-exempt: matched on THIS RUN's state root, never on the image path
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$root*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500

    # ========================================================================
    # BYSTANDERS (T269): what the box looked like before, still looks like now.
    # ========================================================================
    # In -Release mode `bystandersBefore` includes the user's OWN agent, holding
    # their live panes: it is the incumbent whose guard used to refuse this run,
    # and "it is still running" is half of what this script claims. A bystander
    # that exits for its own reasons scores a false FAIL here - that is the right
    # direction for this particular assertion.
    $stillAlive = @(Get-Process -Id $bystandersBefore -ErrorAction SilentlyContinue |
        ForEach-Object { [int]$_.Id })
    $gone = @($bystandersBefore | Where-Object { $stillAlive -notcontains $_ })
    Assert "bystander agents untouched (before: $($bystandersBefore.Count), gone: $($gone -join ' '))" `
        ($gone.Count -eq 0)

    # A RELEASE app writes the agent autostart Run value (a debug one does not,
    # unless forced). Its name carries the lineage suffix, so it can only ever be
    # a NEW value beside the user's - never an overwrite of theirs. Both halves
    # are measured, then ours is removed: a Run entry pointing into %TEMP% would
    # try to start a deleted agent at every logon.
    $runValuesAfter = Get-GhozttyRunValues
    $clobbered = @($runValuesBefore.Keys | Where-Object {
        -not $runValuesAfter.ContainsKey($_) -or $runValuesAfter[$_] -ne $runValuesBefore[$_]
    })
    Assert "the user's autostart Run values are untouched (changed: $($clobbered -join ' '))" `
        ($clobbered.Count -eq 0)
    $addedRun = @($runValuesAfter.Keys | Where-Object { -not $runValuesBefore.ContainsKey($_) })
    foreach ($name in $addedRun) {
        Say "  this run added Run value '$name' -> removing it"
        Assert "added Run value '$name' names a lineage of ours, not the user's" `
            ($name -like '*t167*')
        Remove-ItemProperty -Path $RunKey -Name $name -ErrorAction SilentlyContinue
    }
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
    if ($null -eq $saved.scheme) { Remove-Item env:GHOZTTY_URL_SCHEME -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_URL_SCHEME = $saved.scheme }
    if ($null -eq $saved.selfheal) { Remove-Item env:GHOZTTY_PATH_SELFHEAL -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_PATH_SELFHEAL = $saved.selfheal }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Unit 'checks'
