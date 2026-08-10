# T662 - `ghoztty +sessions --agent` reports which agent build is RUNNING.
#
# The local agent outlives the app on purpose, and on a box whose panes never
# all close it can sit on an old build indefinitely while everything around it
# advances. Nothing misbehaves - the wire contract is forward-compatible both
# ways - but until this command existed the staleness was not OBSERVABLE at all:
# the only place the comparison happened was an app log line, on a box where the
# app had already been restarted.
#
# Five arms, each a state a real box is actually in:
#
#   A  no agent running          -> `not_running`, exit 0 (an answer, not an error)
#   B  the agent we just started -> `current`, running == bundled, pid matches
#   C  a newer build shipped     -> `stale`, N days behind, and a "next:" line
#   D  a dev agent newer than us -> `newer`, no distance, no "next:"
#   E  --json                    -> every key present, token == the human row
#
# C and D are reachable only because the CLI honors the same DEBUG-ONLY
# `GHOZTTY_AGENT_BUNDLED_VERSION` hook the app's probe does: every stamp in one
# tree comes from one binary, so without it there is no way to fabricate an old
# (or new) agent and only the `current` arm would ever be measured.
#
# Everything runs in a private LOCALAPPDATA under a per-run agent lineage
# (T167), so this never touches the box's own agent or the loop's sessions.
#
# Usage:
#   powershell -NoProfile -File test\win32\sessions-agent-build.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Self-test for the teeth of arms C and D: feed the CLI a bundled stamp
    # EQUAL to the running one, so "stale"/"newer" have nothing to report. Both
    # arms' status assertions must go red and nothing else may move. Without it,
    # "C passed" is only evidence that the command printed something.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0

$root = Join-Path $env:TEMP "ghoztty-t662-$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# Every process this script starts, killed by PID at the end. Killing by name
# would take the loop's own agent - and the user's sessions - with it.
$script:mine = New-Object System.Collections.Generic.List[int]

function Start-Agent($instance, $lad, $pipe, $portFile) {
    $savedInst = $env:GHOZTTY_AGENT_INSTANCE
    $savedLad = $env:LOCALAPPDATA
    $env:GHOZTTY_AGENT_INSTANCE = $instance
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

function Wait-PortFile($path, $timeoutSec = 12) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Run the CLI under an explicit lineage + LOCALAPPDATA, optionally with a
# fabricated bundled stamp. Returns the exit code; stdout lands in $out.
# persistence: a CLI invocation - it opens no window, so there is nothing to restore.
function Run-Cli($argv, $out, $instance, $lad, $bundled, $timeoutSec = 30) {
    $savedInst = $env:GHOZTTY_AGENT_INSTANCE
    $savedLad = $env:LOCALAPPDATA
    $savedBundled = $env:GHOZTTY_AGENT_BUNDLED_VERSION
    $env:GHOZTTY_AGENT_INSTANCE = $instance
    $env:LOCALAPPDATA = $lad
    if ($null -eq $bundled) { Remove-Item env:GHOZTTY_AGENT_BUNDLED_VERSION -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_BUNDLED_VERSION = $bundled }
    # persistence: a CLI invocation - it opens no window, so there is nothing to
    # restore. (Repeated by the launch statement so the sweep sees it.)
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    if ($null -eq $savedInst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $savedInst }
    $env:LOCALAPPDATA = $savedLad
    if ($null -eq $savedBundled) { Remove-Item env:GHOZTTY_AGENT_BUNDLED_VERSION -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_BUNDLED_VERSION = $savedBundled }
    $code = $null
    if ($p.WaitForExit($timeoutSec * 1000)) { $p.WaitForExit(); $code = $p.ExitCode }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    return $code
}
function Out-Text($f) { if (Test-Path $f) { (Get-Content $f -Raw) -replace "`0", '' } else { '' } }

# The value of a "key:  value" row, trimmed. Null when the row is absent.
function Row($text, $key) {
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match "^$key\:\s+(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

$null = Assert-GhozttyIsolatedBuild -Exe $Exe

New-Item -ItemType Directory -Force $root | Out-Null
$saved = @{
    lad     = $env:LOCALAPPDATA
    bin     = $env:GHOSTTY_LOCAL_AGENT_BIN
    inst    = $env:GHOZTTY_AGENT_INSTANCE
    bundled = $env:GHOZTTY_AGENT_BUNDLED_VERSION
}
# Pin the bundled probe at the freshly built agent rather than at whatever sits
# beside the exe, so "current" means this tree's agent and not a leftover.
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

$line = "t662$PID"
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Force $state | Out-Null
$outA = Join-Path $root 'a.txt'
$outB = Join-Path $root 'b.txt'
$outC = Join-Path $root 'c.txt'
$outD = Join-Path $root 'd.txt'
$outE = Join-Path $root 'e.txt'

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
Say "== A: no agent running is an ANSWER, not an error"
# ============================================================================
# Scored first, before anything is started. If this exits 1 the command has
# inherited `+sessions`'s "no agent found" failure, and every scripted consumer
# has to tell a missing agent apart from a broken command by parsing stderr.
$codeA = Run-Cli @('+sessions', '--agent') $outA $line $state $null
$textA = Out-Text $outA
Assert "A: exit 0 with no agent running" ($codeA -eq 0)
Assert "A: status is not_running" ((Row $textA 'status') -like 'not_running*')
Assert "A: the running row says so in plain words" ((Row $textA 'running') -eq '(no agent running)')
# The bundled side is knowable with no agent at all - that is the whole reason
# the probe reads the binary rather than asking the daemon.
$bundledReal = Row $textA 'bundled'
Assert "A: the bundled build is named" ($bundledReal -match '^\d{8}-')
Assert "A: nothing to do, so no next step is offered" ($null -eq (Row $textA 'next'))

# ============================================================================
Say "== B: the agent we just started reads as current"
# ============================================================================
# The CLI DERIVES the info-file path from LOCALAPPDATA + the lineage (it has no
# --port-file of its own), so the agent has to publish exactly where the CLI
# will look. Pointing the agent somewhere convenient instead is how arm B first
# scored "not_running" against a healthy agent.
$agentDir = Join-Path $state "ghoztty\local-agent-debug-$line"
New-Item -ItemType Directory -Force $agentDir | Out-Null
$portFile = Join-Path $agentDir 'port.json'
$pipe = "\\.\pipe\ghoztty-t662-$PID"
$agent = Start-Agent $line $state $pipe $portFile
Assert "B: the agent published its info file" (Wait-PortFile $portFile 12)
Assert "B: the agent is running" (-not $agent.HasExited)

$codeB = Run-Cli @('+sessions', '--agent') $outB $line $state $null
$textB = Out-Text $outB
# The running row is "<stamp>  (pid N)": take the stamp alone to compare.
$runningReal = ((Row $textB 'running') -split '\s+')[0]
Assert "B: exit 0" ($codeB -eq 0)
Assert "B: status is current" ((Row $textB 'status') -eq 'current')
Assert "B: the running stamp is the bundled one" ($runningReal -eq $bundledReal)
# The pid makes the row actionable: it names WHICH process to look at.
Assert "B: the row names the agent's pid" ($runningReal -match '^\d{8}-' -and $textB -match "\(pid $($agent.Id)\)")
Assert "B: a current agent is offered no next step" ($null -eq (Row $textB 'next'))

# The dates the C/D arms fabricate, computed from the running stamp by an
# INDEPENDENT implementation (PowerShell's own calendar) rather than by the
# code under test.
$runDate = [datetime]::ParseExact($runningReal.Substring(0, 8), 'yyyyMMdd', $null)
$newerStamp = $runDate.AddDays(10).ToString('yyyyMMdd') + '-ffffffff0'
$olderStamp = $runDate.AddDays(-45).ToString('yyyyMMdd') + '-0000000aa'
if ($TeethCheck) {
    # Both fabrications collapse onto the running build: C can no longer be
    # stale and D can no longer be newer.
    $newerStamp = $runningReal
    $olderStamp = $runningReal
}

# ============================================================================
Say "== C: a newer build beside the app makes the running agent stale"
# ============================================================================
$codeC = Run-Cli @('+sessions', '--agent') $outC $line $state $newerStamp
$textC = Out-Text $outC
Assert "C: exit 0" ($codeC -eq 0)
Assert "C: status is stale" ((Row $textC 'status') -like 'stale*')
# The number is the point of the task: "how far behind" has to be answerable.
Assert "C: names the distance in days" ((Row $textC 'status') -match 'stale - 10 days behind')
Assert "C: names the live session count" ((Row $textC 'status') -match '0 live sessions')
Assert "C: a stale agent is told how it gets updated" ((Row $textC 'next') -match 'no sessions are open')

# ============================================================================
Say "== D: a running agent NEWER than the bundled one is never 'behind'"
# ============================================================================
$codeD = Run-Cli @('+sessions', '--agent') $outD $line $state $olderStamp
$textD = Out-Text $outD
Assert "D: exit 0" ($codeD -eq 0)
Assert "D: status is newer" ((Row $textD 'status') -like 'newer*')
Assert "D: says the newer agent is never downgraded" ((Row $textD 'status') -match 'never downgraded')
Assert "D: no next step - there is nothing to update to" ($null -eq (Row $textD 'next'))

# ============================================================================
Say "== E: --json carries every key, and agrees with the human rows"
# ============================================================================
$codeE = Run-Cli @('+sessions', '--agent', '--json') $outE $line $state $newerStamp
$textE = Out-Text $outE
Assert "E: exit 0" ($codeE -eq 0)
$json = $null
try { $json = $textE | ConvertFrom-Json } catch { $json = $null }
Assert "E: output parses as JSON" ($null -ne $json)
if ($null -ne $json) {
    $keys = $json.PSObject.Properties.Name
    foreach ($k in @('status', 'running', 'bundled', 'days_behind', 'live_sessions', 'sessions', 'agent_pid')) {
        Assert "E: key '$k' is present" ($keys -contains $k)
    }
    Assert "E: status token matches the human row" ($json.status -eq 'stale')
    Assert "E: days_behind is the number, not prose" ($json.days_behind -eq 10)
    Assert "E: running is the agent's real stamp" ($json.running -eq $runningReal)
    Assert "E: bundled is the fabricated one" ($json.bundled -eq $newerStamp)
    Assert "E: agent_pid is the agent we started" ($json.agent_pid -eq $agent.Id)
    Assert "E: live_sessions counts the empty roster" ($json.live_sessions -eq 0)
}

} finally {
    foreach ($id in $script:mine) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $saved.lad) { Remove-Item env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $saved.lad }
    if ($null -eq $saved.bin) { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue } else { $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin }
    if ($null -eq $saved.inst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue } else { $env:GHOZTTY_AGENT_INSTANCE = $saved.inst }
    if ($null -eq $saved.bundled) { Remove-Item env:GHOZTTY_AGENT_BUNDLED_VERSION -ErrorAction SilentlyContinue } else { $env:GHOZTTY_AGENT_BUNDLED_VERSION = $saved.bundled }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:failures -eq 0) { Write-Host "ALL PASS ($script:passes checks)" -ForegroundColor Green; exit 0 }
Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red
exit 1
