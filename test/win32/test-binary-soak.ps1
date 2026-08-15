<#
.SYNOPSIS
    T832 - the soak harness must measure the condition the T443 corruption
    actually occurs in, and say which condition it measured.

.DESCRIPTION
    `scripts\test-binary-soak.ps1` used to do exactly one thing: run a built
    test binary straight out of .zig-cache. On 2026-08-14 that was measured
    against the build runner and found to be a condition the defect has never
    once occurred in -- ~200 direct runs with 0 crashes (including the exact
    binary that had dumped three times that morning) against 5 aborts in 26
    `zig build` lane runs on the same box. Every "it will not reproduce"
    finding T443 ever recorded came out of the wrong condition.

    So this script proves three things, none of which needs a real
    intermittent crash:

    - the DEFAULT for -Lane is the build runner, and the summary names the
      mode it used,
    - the build-runner path classifies PASS / FAIL / CRASH from a staged lane
      (floor-lane.ps1 -Command, the same hook floor-lane grew to make its own
      crash wiring testable), and finds the victim test in the lane log,
    - the standalone path still works, and says in its own output that it is
      the condition T443 has never reproduced in.

    The fixtures are cmd scripts, so a full run is under two minutes and needs
    no zig lane.

.OUTPUTS
    One scored verdict line last (`ALL PASS (N assertions)` / `N FAILURE(S)` /
    `ASSERTED NOTHING`), via test\win32\lib\TestScore.ps1.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$Repo\test\win32\lib\TestScore.ps1"

$passes = 0
$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS $Name"; $script:passes++ }
    else { Write-Host "FAIL $Name $Detail"; $script:failures++ }
}

$soak = Join-Path $Repo 'scripts\test-binary-soak.ps1'
if (-not (Test-Path -LiteralPath $soak)) {
    Write-TestAssertedNothing -Reason "scripts\test-binary-soak.ps1 not found under $Repo"
}

$work = Join-Path $env:TEMP ('soakacc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$out = Join-Path $work 'out'

# Splatted in-process rather than through `powershell -File`: an array
# parameter cannot survive the -File command line (`-Arguments /c,exit,0`
# arrives as the single string "/c,exit,0"), and the standalone fixtures need
# one. `*>&1` is what captures Write-Host, which `2>&1` does not.
function Invoke-Soak {
    param([hashtable]$P = @{})
    $P = $P.Clone()
    $P['OutDir'] = $out
    $P['Repo'] = $Repo
    # -Width, or Out-String wraps at the host width (80 in a hidden console)
    # and an assertion about the one-line summary fails on a line break rather
    # than on the thing it is asserting.
    $text = (& $soak @P *>&1 | Out-String -Width 4096)
    return [pscustomobject]@{ Text = $text; Code = $LASTEXITCODE }
}

# ------------------------------------------------- 1. guard rails, not hangs

$r = Invoke-Soak @{}
Check 'no target exits 2 with guidance' ($r.Code -eq 2 -and $r.Text -match '-Lane') "got $($r.Code)"

$r = Invoke-Soak @{ Exe = $env:ComSpec; Mode = 'build-runner' }
Check '-Exe cannot be build-runner (there is no lane to build)' `
($r.Code -eq 2 -and $r.Text -match 'no lane to build') "got $($r.Code): $($r.Text)"

$r = Invoke-Soak @{ LaneCommand = 'cmd /c exit 0'; Mode = 'standalone' }
Check '-LaneCommand cannot be standalone' ($r.Code -eq 2) "got $($r.Code)"

# --------------------------------- 2. the default for a lane is the build runner

# -Runs 0 exercises the mode decision without spending a lane run on it.
$r = Invoke-Soak @{ Lane = 'agent'; Runs = 0; Label = 'modedefault' }
Check '-Lane defaults to build-runner' ($r.Text -match 'SOAK modedefault: mode=build-runner') `
    ($r.Text -replace '\s+', ' ')
Check 'the mode is in the summary line, not only the preamble' `
($r.Text -match 'SOAK \S+: mode=\S+ runs=')

# ------------------------------------- 3. build-runner: PASS / FAIL / CRASH

$r = Invoke-Soak @{ LaneCommand = 'cmd /c exit 0'; Runs = 2; Label = 'brpass' }
Check 'a clean build-runner round is PASS' ($r.Text -match 'SOAK brpass: mode=build-runner runs=2 concurrency=1 pass=2 fail=0 crash=0') `
    ($r.Text -replace '\s+', ' ')
Check 'a clean build-runner soak exits 0' ($r.Code -eq 0) "got $($r.Code)"

# A red lane: tests ran, some failed, nothing died.
$redCmd = Join-Path $work 'red.cmd'
@(
    '@echo off',
    'echo 3800/3913 terminal.PageList.test.PageList grow',
    'echo error: 2 tests failed',
    'exit /b 1'
) | Set-Content -LiteralPath $redCmd -Encoding ASCII
$r = Invoke-Soak @{ LaneCommand = "cmd /c $redCmd"; Runs = 1; Label = 'brfail'; NoCatch = $true }
Check 'a red build-runner round is FAIL, not CRASH' `
($r.Text -match 'SOAK brfail: mode=build-runner runs=1 concurrency=1 pass=0 fail=1 crash=0') `
    ($r.Text -replace '\s+', ' ')
Check 'a red round does not exit 1 (only a crash or a hang does)' ($r.Code -eq 0) "got $($r.Code)"

# An abort: the 2026-08-14 T443 signature, which the pre-T832 pattern list
# classified as a red test because it is a panic rather than a fault.
$abortCmd = Join-Path $work 'abort.cmd'
@(
    '@echo off',
    'echo 1234/3913 terminal.PageList.test.PageList resize reflow grapheme map capacity exceeded',
    'echo thread 12188 panic: page map metadata pointer corrupted',
    'exit /b 3'
) | Set-Content -LiteralPath $abortCmd -Encoding ASCII
$r = Invoke-Soak @{ LaneCommand = "cmd /c $abortCmd"; Runs = 1; Label = 'brcrash'; NoCatch = $true }
Check 'an abort in the lane log is CRASH' `
($r.Text -match 'SOAK brcrash: mode=build-runner runs=1 concurrency=1 pass=0 fail=0 crash=1') `
    ($r.Text -replace '\s+', ' ')
Check 'a crashed build-runner soak exits 1' ($r.Code -eq 1) "got $($r.Code)"
Check 'the crash line is quoted in the run row' ($r.Text -match 'panic: page map metadata pointer corrupted')
Check 'the victim test is named from the lane log' `
($r.Text -match 'victim: 1234/3913 terminal\.PageList') ($r.Text -replace '\s+', ' ')
Check 'the lane log is named so the evidence is findable' ($r.Text -match 'lane log: .+floor-lane-command-')

# --------------------------------------------- 3b. -LoadWorkers (T443 turn 6)

# The cell with all of T443's sightings in it and no measurement is
# `build-runner x loaded`: load was only ever soaked in standalone mode, which
# cannot reproduce the defect, and the build runner was only ever soaked on a
# quiet box. What is asserted here is that the knob really loads the box, that
# it cleans up after itself, and that the summary names the condition -- not
# that a crash appears, which is what the soak itself is for.
# Counted by command line, not by process name: this box runs several
# powershell sessions of its own, and a count of those is noise.
function Get-LoadWorkerCount {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*1000003*' }).Count
}

$r = Invoke-Soak @{ LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'brload'; LoadWorkers = 3 }
$leftOver = Get-LoadWorkerCount
Check '-LoadWorkers reports the workers it started' `
($r.Text -match '-LoadWorkers 3: 3 worker\(s\) holding the box busy') ($r.Text -replace '\s+', ' ')
Check 'the load level lands in the summary line, so a pasted number names its condition' `
($r.Text -match 'SOAK brload:.*load=3') ($r.Text -replace '\s+', ' ')
Check 'the workers are all still alive at the end (a soak that quiesced silently is not a loaded soak)' `
($r.Text -match 'load: 3 worker\(s\) requested, 3 still running at the end') ($r.Text -replace '\s+', ' ')
Check 'a loaded soak still classifies its rounds' `
($r.Text -match 'pass=1 fail=0 crash=0') ($r.Text -replace '\s+', ' ')
Check 'the workers are killed when the soak ends' ($leftOver -eq 0) "$leftOver left running"

# The condition is named even when there is none, or a green number read later
# is ambiguous between "quiesced" and "nobody recorded it".
$r = Invoke-Soak @{ LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'brnoload' }
Check 'an unloaded build-runner soak still says load=0' ($r.Text -match 'SOAK brnoload:.*load=0') `
    ($r.Text -replace '\s+', ' ')

# ------------------------------- 4. standalone still works, and admits what it is

# A lane-shaped NAME is what turns the warning on: a fixture exe has no build
# runner to be the wrong side of. powershell.exe rather than cmd.exe as the
# body -- the soak quotes every argument, and cmd refuses a quoted "/c",
# which makes a fixture that silently exits 1 look like a classification bug.
$psExe = (Get-Process -Id $PID).Path
$fake = Join-Path $work 'ghostty-test.exe'
Copy-Item -LiteralPath $psExe -Destination $fake -Force
$r = Invoke-Soak @{ Exe = $fake; Arguments = @('-NoProfile', '-Command', 'exit 0'); Runs = 2; Label = 'sapass' }
Check 'a standalone soak still runs and passes' `
($r.Text -match 'SOAK sapass: mode=standalone runs=2 concurrency=1 pass=2 fail=0 crash=0') `
    ($r.Text -replace '\s+', ' ')
Check 'standalone exits 0 when clean' ($r.Code -eq 0) "got $($r.Code)"
Check 'standalone warns that it is not the T443 condition' `
($r.Text -match 'MODE=standalone' -and $r.Text -match 'NEVER been observed in this condition') `
    ($r.Text -replace '\s+', ' ')
Check 'the warning cites the task that measured it' ($r.Text -match 'T832')
Check 'the summary repeats the caveat' ($r.Text -match 'says nothing about T443')

$r = Invoke-Soak @{ Exe = $fake; Arguments = @('-NoProfile', '-Command', 'exit 0'); Runs = 1; Label = 'saload'; LoadWorkers = 4 }
Check 'standalone says it is ignoring -LoadWorkers rather than loading a condition that cannot fire' `
($r.Text -match 'LoadWorkers is build-runner only') ($r.Text -replace '\s+', ' ')
Check 'standalone carries no load= claim in its summary' (-not ($r.Text -match 'SOAK saload:.*load=')) `
    ($r.Text -replace '\s+', ' ')

$r = Invoke-Soak @{ Exe = $fake; Arguments = @('-NoProfile', '-Command', 'exit 5'); Runs = 1; Label = 'sacrash' }
Check 'standalone still classifies a fatal NTSTATUS as CRASH' `
($r.Text -match 'SOAK sacrash: mode=standalone runs=1 concurrency=1 pass=0 fail=0 crash=1') `
    ($r.Text -replace '\s+', ' ')

# A plain non-crash exit code stays a red test, in both modes.
$r = Invoke-Soak @{ Exe = $fake; Arguments = @('-NoProfile', '-Command', 'exit 1'); Runs = 1; Label = 'safail' }
Check 'standalone keeps a plain nonzero exit as FAIL' `
($r.Text -match 'SOAK safail: mode=standalone runs=1 concurrency=1 pass=0 fail=1 crash=0') `
    ($r.Text -replace '\s+', ' ')

# An exe that is not one of ours must NOT carry the T443 warning.
$plain = Join-Path $work 'fixture.exe'
Copy-Item -LiteralPath $psExe -Destination $plain -Force
$r = Invoke-Soak @{ Exe = $plain; Arguments = @('-NoProfile', '-Command', 'exit 0'); Runs = 1; Label = 'plain' }
Check 'a fixture exe gets no T443 warning' (-not ($r.Text -match 'NEVER been observed')) `
    ($r.Text -replace '\s+', ' ')

# --------------------------------------------------------------------- cleanup

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

# --- stamp (T783) ---------------------------------------------------------
# This harness has a guard row in scripts\guard-due.ps1 but never stamped, so
# the only way its DUE was ever cleared was somebody running `guard-due update`
# by hand -- an assertion that the harness had been run, in the one place that
# is supposed to MEASURE it. Only a clean green run stamps; a red run must stay
# due.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard test-binary-soak -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $passes -Fail $failures
