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
    if (-not $P.ContainsKey('OutDir')) { $P['OutDir'] = $out }
    if (-not $P.ContainsKey('Repo')) { $P['Repo'] = $Repo }
    # -Width, or Out-String wraps at the host width (80 in a hidden console)
    # and an assertion about the one-line summary fails on a line break rather
    # than on the thing it is asserting.
    $text = (& $soak @P *>&1 | ForEach-Object { $_.ToString() } | Out-String -Width 4096)
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

# ------------------------- 3a. the occurrence floor-lane already decoded (T877)
#
# The 2026-08-15 22:07 shape, reproduced line for line: a test binary that died
# by EXIT CODE alone -- zig's `exited with code 3`, no handler text anywhere,
# because the segfault handler printed nothing that time -- with floor-lane's
# own `-- crash diagnostics --` block in the same log naming the dead process.
# The soak counted it `crash=0`, which is the single number this script exists
# to produce.
$diagCmd = Join-Path $work 'diagcrash.cmd'
@(
    '@echo off',
    'echo 2851/3913 font.Collection.test.add full',
    "echo error: while executing test 'font.Collection.test.add full', the following command exited with code 3 (expected exited with code 0):",
    'echo -- crash diagnostics --',
    'echo   exit code 3 is the low byte of 0x80000003 STATUS_BREAKPOINT (Zig panic / segfault handler abort)',
    'echo   CRASH 22:07:14 ghostty-test.exe pid=0xE570 0x80000003 STATUS_BREAKPOINT (Zig panic / segfault handler abort) in ghostty-test.exe+0x0000000002a896c0',
    'exit /b 1'
) | Set-Content -LiteralPath $diagCmd -Encoding ASCII
$r = Invoke-Soak @{ LaneCommand = "cmd /c $diagCmd"; Runs = 1; Label = 'brdiag'; NoCatch = $true }
Check 'a CrashDiag-confirmed death with no handler text is CRASH, not FAIL' `
($r.Text -match 'SOAK brdiag: mode=build-runner runs=1 concurrency=1 pass=0 fail=0 crash=1') `
    ($r.Text -replace '\s+', ' ')
Check 'that soak exits 1 like any other crashed soak' ($r.Code -eq 1) "got $($r.Code)"
Check 'the run row quotes the decoded evidence rather than a bare exit code' `
($r.Text -match 'exited with code 3' -or $r.Text -match 'CRASH 22:07:14 ghostty-test\.exe') `
    ($r.Text -replace '\s+', ' ')

# The block is NOT name-filtered when floor-lane writes it -- it reports every
# crash in the window, ours or somebody else's -- so the classifier has to be.
# A CRASH line for an unrelated process must leave a red lane red.
$otherCmd = Join-Path $work 'othercrash.cmd'
@(
    '@echo off',
    'echo 2851/3913 font.Collection.test.add full',
    'echo error: 1 tests failed',
    'echo -- crash diagnostics --',
    'echo   CRASH 22:07:14 SomeOtherApp.exe pid=0x1234 0xC0000005 STATUS_ACCESS_VIOLATION in SomeOtherApp.exe+0x1000',
    'exit /b 1'
) | Set-Content -LiteralPath $otherCmd -Encoding ASCII
$r = Invoke-Soak @{ LaneCommand = "cmd /c $otherCmd"; Runs = 1; Label = 'brother'; NoCatch = $true }
Check 'a CRASH line naming somebody ELSE''s process does not count as our crash' `
($r.Text -match 'SOAK brother: mode=build-runner runs=1 concurrency=1 pass=0 fail=1 crash=0') `
    ($r.Text -replace '\s+', ' ')

# The classifier itself, against the exact lines of the 2026-08-15 transcript.
# Through the library rather than a fixture lane because one of its failure
# modes is invisible end to end: a Mandatory [string[]] implies
# ValidateNotNullOrEmpty per ELEMENT, so a transcript split into lines -- every
# real one has a blank line in it -- failed to bind and handed back nothing,
# while a second lookup path quietly covered for it.
. (Join-Path $Repo 'scripts\lib\CrashDiag.ps1')
$realLines = @(
    'LANE none FAIL in 5s (leaked webview hosts swept: 0) | build.exe test -Dapp-runtime=none',
    '-- errors --',
    "  error: while executing test 'font.Collection.test.add full', the following command exited with code 3 (expected exited with code 0):",
    '  error: the following build command failed with exit code 1:',
    '-- crash diagnostics --',
    '  exit code 3 is the low byte of 0x80000003 STATUS_BREAKPOINT (Zig panic / segfault handler abort)',
    '  CRASH 22:07:14 ghostty-test.exe pid=0xE570 0x80000003 STATUS_BREAKPOINT (Zig panic / segfault handler abort) in ghostty-test.exe+0x0000000002a896c0',
    '',
    'FLOOR SUMMARY: none#1=FAIL'
)
Check 'the classifier binds a transcript that contains a blank line' `
((Get-CrashOccurrenceLine -Lines $realLines) -ne '') 'empty-string element refused the bind'
Check 'the CRASH line alone is enough, with no handler text anywhere' `
((Get-CrashOccurrenceLine -Lines @('', '  CRASH 22:07:14 ghostty-test.exe pid=0xE570 0x80000003 X in ghostty-test.exe+0x1')) -ne '')
Check 'a CRASH line for a process that is not one of ours is ignored' `
((Get-CrashOccurrenceLine -Lines @('  CRASH 22:07:14 chrome.exe pid=0x1 0xC0000005 X in chrome.exe+0x1')) -eq '')
Check 'a clean transcript classifies as nothing' `
((Get-CrashOccurrenceLine -Lines @('', 'LANE none PASS in 190s', 'FLOOR SUMMARY: none#1=PASS')) -eq '')
Check 'a red lane exit code (1) is not a crash, and neither is the expected 0' `
((Get-CrashOccurrenceLine -Lines @(
            '  error: the following command exited with code 1 (expected exited with code 0):')) -eq '')

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

# ------------------------------ 3c. command-shaped load (T840)
#
# -LoadWorkers holds CPU spinners, and T443 turn 6 measured what that is worth:
# 16 of them cost the lane ~13% wall clock and produced 0 crashes in 8 runs.
# Every sighting instead had another COMPILE AND TEST LANE on the box. So the
# load has to be able to take a command's shape -- and the two things that can
# silently ruin such a soak are a load that never actually ran, and a load that
# wedges the lane it is supposed to be timing. Both are asserted here.

$loadWork = Join-Path $work 'load'

# One iteration of this fixture is instant, so a one-round soak completes
# several -- the count is the evidence the load was applied at all.
$r = Invoke-Soak @{
    LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'cmdload'; LoadWorkers = 2
    LoadCommand = 'cmd /c exit 0'; LoadWorkDir = $loadWork
}
Check '-LoadCommand implies a command-shaped load' `
($r.Text -match 'load kind=command') ($r.Text -replace '\s+', ' ')
Check 'the summary names the load KIND, not just the worker count' `
($r.Text -match 'SOAK cmdload:.*load=2:command') ($r.Text -replace '\s+', ' ')
$iters = if ($r.Text -match 'load-iters=(\d+)') { [int]$matches[1] } else { -1 }
Check 'the iterations the load completed are MEASURED and reported' ($iters -gt 0) `
    "load-iters=$iters"
Check 'the same count is in the end-of-soak load line' `
($r.Text -match 'load: 2 worker\(s\) requested, .* iteration\(s\) completed of \d+ started') `
    ($r.Text -replace '\s+', ' ')
Check 'a command-loaded soak still classifies its rounds' ($r.Text -match 'pass=1 fail=0 crash=0') `
    ($r.Text -replace '\s+', ' ')
Check 'each worker got its own scratch directory' `
((Test-Path (Join-Path $loadWork 'cmdload-*\w0\worker.ps1')) -and
    (Test-Path (Join-Path $loadWork 'cmdload-*\w1\worker.ps1'))) `
    ((Get-ChildItem -Path $loadWork -Recurse -Filter 'worker.ps1' -ErrorAction SilentlyContinue |
            ForEach-Object FullName) -join ', ')

# An iteration that outlives the soak is the NORMAL case for the heaviest load
# on offer -- a cold `zig build` of a whole lane takes longer than the round it
# is loading. So the measurement counts started as well as completed, and a
# started-but-unfinished iteration must read as load applied, not as no load.
# The same fixture leaves a long-running GRANDCHILD alive at kill time, which is
# the other half: killing the worker alone orphans the compiler onto the next
# soak's box.
$pingTag = '-n 45 127.0.0.1'
$r = Invoke-Soak @{
    LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'cmdslow'; LoadWorkers = 1
    LoadCommand = "cmd /c ping $pingTag > nul"; LoadWorkDir = $loadWork
}
$strays = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$pingTag*" }).Count
Check 'an iteration still in flight reads as load applied, not as an unloaded soak' `
($r.Text -match '0 completed, 1 in flight at the end' -and -not ($r.Text -match 'effectively UNLOADED')) `
    ($r.Text -replace '\s+', ' ')
Check 'the summary carries both numbers, so load-iters=0 is not ambiguous' `
($r.Text -match 'load-iters=0 started=1') ($r.Text -replace '\s+', ' ')
Check 'a worker GRANDCHILD is killed with the worker (no orphaned load on the next soak)' `
($strays -eq 0) "$strays ping(s) left running"

# The other end of the same measurement: a load that could not start at all
# must not leave a green soak implying a condition it never had.
$r = Invoke-Soak @{
    LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'cmddead'; LoadWorkers = 1
    LoadCommand = 'cmd /c exit 0'; LoadWorkDir = 'Q:\no-such-drive\soak'
}
Check 'a load that never started is called out as an UNLOADED soak' `
($r.Text -match 'WARNING no worker even started an iteration' -and $r.Text -match 'effectively UNLOADED') `
    ($r.Text -replace '\s+', ' ')
Check 'the worker log is named so the failure is findable' ($r.Text -match 'worker\.log') `
    ($r.Text -replace '\s+', ' ')

# The cache-lock hazard: a second `zig build` in this repo takes the same
# manifest locks as the lane being measured, and a wedged lane is not a data
# point (T401).
$r = Invoke-Soak @{ LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'cachelock'; LoadCommand = 'zig build test' }
Check 'a zig build load command with no --cache-dir is refused, not run' `
($r.Code -eq 2 -and $r.Text -match 'must pass its own --cache-dir') "got $($r.Code): $($r.Text)"
Check 'the refusal points at the mode that composes the isolated form' ($r.Text -match '-LoadKind build')

$r = Invoke-Soak @{
    LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'cacheok'; LoadDryRun = $true
    LoadCommand = 'zig build test --cache-dir D:\somewhere-else'; LoadWorkDir = $loadWork
}
Check 'an isolated zig build load command is accepted' ($r.Code -eq 0) "got $($r.Code): $($r.Text)"

# -LoadKind build composes that isolation itself, per worker, and the private
# caches must land on the REPO'S drive (zig asserts across drives -- T243).
$r = Invoke-Soak @{ LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'buildkind'; LoadWorkers = 2; LoadKind = 'build'; LoadDryRun = $true }
$drive = Split-Path -Qualifier $Repo
Check '-LoadKind build composes a real zig build per worker' `
($r.Text -match 'worker 0 runs: zig build test' -and $r.Text -match 'worker 1 runs: zig build test') `
    ($r.Text -replace '\s+', ' ')
Check 'each build worker gets its own local cache and prefix (the manifest lock is the hazard)' `
($r.Text -match '--cache-dir "[^"]*w0[^"]*"' -and $r.Text -match '--prefix "[^"]*w0[^"]*"') `
    ($r.Text -replace '\s+', ' ')
Check 'the populated global package cache is SHARED, so the load compiles this repo rather than freetype' `
($r.Text -match '--global-cache-dir "[^"]*"' -and -not ($r.Text -match '--global-cache-dir "[^"]*w0[^"]*"')) `
    ($r.Text -replace '\s+', ' ')
Check 'worker 0 and worker 1 do not share a cache directory' `
($r.Text -match '--cache-dir "[^"]*w1[^"]*"') ($r.Text -replace '\s+', ' ')
Check 'the private caches default to the repo drive (zig asserts across drives)' `
($r.Text -match ('--cache-dir "' + [regex]::Escape($drive) + '\\')) ($r.Text -replace '\s+', ' ')
Check '-LoadDryRun starts nothing and runs no rounds' `
($r.Code -eq 0 -and $r.Text -match 'started nothing' -and -not ($r.Text -match 'run  1/1')) `
    ($r.Text -replace '\s+', ' ')

# ------------------- 3d. a load worker can BE an occurrence, and be kept (T877)
#
# A `-LoadKind build` worker runs a whole `zig build test` lane per iteration,
# so it can crash exactly the way a measured round can -- and one did, on
# 2026-08-15 22:41 (segfault + recursive panic in terminal.formatter, exit 5, in
# w3). Nothing scanned worker logs, so it landed in no verdict line; and every
# soak cleared the flat `w<N>` slots, so two soaks later the evidence was gone
# along with 73 unscanned iterations.

$crashLoad = Join-Path $work 'loadcrash.cmd'
@(
    '@echo off',
    'echo 900/3913 terminal.formatter.test.PageList plain spanning two pages',
    'echo Segmentation fault at address 0x0',
    'exit /b 5'
) | Set-Content -LiteralPath $crashLoad -Encoding ASCII
$keepWork = Join-Path $work 'keep'
$r = Invoke-Soak @{
    LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'wcrash'; LoadWorkers = 1
    LoadCommand = "cmd /c $crashLoad"; LoadWorkDir = $keepWork
}
Check 'a crashed load-worker iteration is counted in the summary line' `
($r.Text -match 'SOAK wcrash:.*worker-crash=[1-9]') ($r.Text -replace '\s+', ' ')
Check 'the crashed worker is named with its slot and its log' `
($r.Text -match 'w0: .*(Segmentation fault|exited with .*code 5)' -and $r.Text -match 'worker\.log') `
    ($r.Text -replace '\s+', ' ')
Check 'the measured round is still classified on its own evidence, not the worker''s' `
($r.Text -match 'pass=1 fail=0 crash=0') ($r.Text -replace '\s+', ' ')

# The negative control: a clean load must report the field, and report zero.
# An ABSENT field would be ambiguous between "none" and "nobody counted", which
# is the complaint this whole task is about, one level down.
$r = Invoke-Soak @{
    LaneCommand = 'cmd /c exit 0'; Runs = 1; Label = 'wclean'; LoadWorkers = 1
    LoadCommand = 'cmd /c exit 0'; LoadWorkDir = $keepWork
}
Check 'a clean load still says worker-crash=0 rather than omitting the field' `
($r.Text -match 'SOAK wclean:.*worker-crash=0') ($r.Text -replace '\s+', ' ')

# ...and the second soak did not destroy the first soak's worker evidence.
$wcrashLogs = @(Get-ChildItem -Path (Join-Path $keepWork 'wcrash-*\w0\worker.log') -ErrorAction SilentlyContinue)
$wcleanLogs = @(Get-ChildItem -Path (Join-Path $keepWork 'wclean-*\w0\worker.log') -ErrorAction SilentlyContinue)
Check 'each soak keeps its worker logs in its own directory' `
($wcrashLogs.Count -eq 1 -and $wcleanLogs.Count -eq 1) `
    ((Get-ChildItem -Path $keepWork -Recurse -Filter 'worker.log' -ErrorAction SilentlyContinue |
            ForEach-Object FullName) -join ', ')
$keptText = if ($wcrashLogs.Count -eq 1) {
    (Get-Content -LiteralPath $wcrashLogs[0].FullName -ErrorAction SilentlyContinue) -join "`n"
}
else { '' }
Check 'a later soak does not delete the earlier soak''s crash evidence' `
($keptText -match 'Segmentation fault') "kept log: $keptText"

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

# The command-shaped load is build-runner only for the same reason: standalone
# is the condition T443 cannot occur in, so loading it harder measures nothing.
$r = Invoke-Soak @{
    Exe = $fake; Arguments = @('-NoProfile', '-Command', 'exit 0'); Runs = 1; Label = 'sacmdload'
    LoadCommand = 'cmd /c exit 0'; LoadWorkDir = (Join-Path $work 'load-sa')
}
Check 'standalone refuses a command-shaped load too, and says so' `
($r.Text -match 'LoadWorkers is build-runner only') ($r.Text -replace '\s+', ' ')
Check 'standalone starts no load workers when one was asked for' `
(@(Get-ChildItem -Path (Join-Path $work 'load-sa') -Recurse -Filter 'worker.ps1' `
        -ErrorAction SilentlyContinue).Count -eq 0) 'a worker script was written'

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

# ------------------ 5. a two-binary lane keeps BOTH binaries' logs (T509)
#
# `-Lane agent -Mode standalone` soaks two binaries in turn, and the per-run
# log name used to carry only {label}-{stamp}-{NN} with NN restarting per
# binary -- so the second binary's run NN overwrote the first's, and during
# T238 the failing binary's evidence was exactly what got lost. The lane is
# fixtured with a fake repo whose .zig-cache holds two powershell copies named
# like the agent test binaries; the FIRST fails (echoing its own path), the
# second passes.

$fakeRepo = Join-Path $work 'repo509'
$oDir = Join-Path $fakeRepo '.zig-cache\o\cafef00d'
New-Item -ItemType Directory -Force -Path $oDir | Out-Null
# The fixtures stand in for the lane's real binaries, so they have to be able to
# PROVE it: since T855 a lane is resolved by reading the test names zig embeds,
# and a copy of powershell.exe carries none of them. The names are appended past
# the end of the PE image, which the loader ignores -- the fixture still runs,
# and the resolution under test is the real one rather than a bypass.
$agentMarkers = "`nremote.agent.server.test.fixture remote.protocol.test.fixture remote.pipe_stream.test.fixture`n"
foreach ($fixName in @('ghoztty-agent-test.exe', 'ghoztty-agent-core-test.exe')) {
    $fixPath = Join-Path $oDir $fixName
    Copy-Item -LiteralPath $psExe -Destination $fixPath -Force
    $fixFs = [IO.File]::Open($fixPath, 'Append', 'Write')
    $fixBytes = [Text.Encoding]::ASCII.GetBytes($agentMarkers)
    $fixFs.Write($fixBytes, 0, $fixBytes.Length)
    $fixFs.Close()
}
# Single-quoted so $PID reaches the fixture unexpanded; the exe name is the
# only thing that tells the two binaries apart, since both get the same args.
$body509 = 'Write-Output ((Get-Process -Id $PID).Path); if ((Get-Process -Id $PID).Path -like ''*-core-*'') { exit 0 } else { exit 1 }'
$out509 = Join-Path $work 'out509'
$r = Invoke-Soak @{
    Lane = 'agent'; Mode = 'standalone'; Runs = 2; Label = 'twobin'
    Arguments = @('-NoProfile', '-Command', $body509)
    Repo = $fakeRepo; OutDir = $out509
}
$logs = @(Get-ChildItem -LiteralPath $out509 -Filter 'twobin-*.log' -ErrorAction SilentlyContinue)
Check 'a two-binary standalone soak keeps a distinct log per run per binary (4 files)' `
($logs.Count -eq 4) "found $($logs.Count): $(($logs | ForEach-Object Name) -join ', ')"
Check 'each log name carries the exe basename' `
((@($logs | Where-Object { $_.Name -match '^twobin-\d{8}-\d{6}-ghoztty-agent-test-\d\d\.log$' }).Count -eq 2) -and
    (@($logs | Where-Object { $_.Name -match '^twobin-\d{8}-\d{6}-ghoztty-agent-core-test-\d\d\.log$' }).Count -eq 2)) `
    (($logs | ForEach-Object Name) -join ', ')
$firstLog = @($logs | Where-Object { $_.Name -match '-ghoztty-agent-test-01\.log$' })
$firstText = if ($firstLog.Count -eq 1) { (Get-Content -LiteralPath $firstLog[0].FullName -ErrorAction SilentlyContinue) -join "`n" } else { '' }
Check 'the FIRST binary''s failing run is still readable after the second binary finished' `
($firstText -match 'ghoztty-agent-test\.exe' -and -not ($firstText -match '-core-')) `
    "log content: $firstText"
Check 'the totals line covers both binaries' `
($r.Text -match 'SOAK twobin: mode=standalone runs=4 concurrency=1 pass=2 fail=2 crash=0') `
    ($r.Text -replace '\s+', ' ')
Check 'the summary attributes fails per binary' `
(($r.Text -match 'ghoztty-agent-test\.exe: runs=2 pass=0 fail=2 crash=0') -and
    ($r.Text -match 'ghoztty-agent-core-test\.exe: runs=2 pass=2 fail=0 crash=0')) `
    ($r.Text -replace '\s+', ' ')
# Negative control: with one binary there is nothing to attribute, and an
# always-on breakdown would just repeat the totals line.
$r = Invoke-Soak @{ Exe = $plain; Arguments = @('-NoProfile', '-Command', 'exit 0'); Runs = 1; Label = 'onebin' }
Check 'a single-binary soak carries no per-exe breakdown line' `
(-not ($r.Text -match '\.exe: runs=')) ($r.Text -replace '\s+', ' ')

# ------------- 6. a lane soak never soaks the OTHER lane's binary (T855)
#
# `none` and `win32` both build `ghostty-test.exe`, and this resolved by newest
# write time -- so a soak labelled `-Lane none` ran the win32 binary and
# reported the count under the none lane. The fixture repo holds nothing but a
# win32-marked binary: the run must refuse rather than soak it, and say so.
$wrongRepo = Join-Path $work 'repo855'
$wrongDir = Join-Path $wrongRepo '.zig-cache\o\feedface'
New-Item -ItemType Directory -Force -Path $wrongDir | Out-Null
$wrongExe = Join-Path $wrongDir 'ghostty-test.exe'
Set-Content -LiteralPath $wrongExe -Encoding ASCII -Value @(
    'terminal.Screen.test.x', 'terminal.PageList.test.x', 'input.Binding.test.x',
    'config.Config.test.x', 'cli.args.test.x', 'datastruct.blocking_queue.test.x',
    'apprt.win32.Window.test.x', 'apprt.win32.Scrollbar.test.x', 'apprt.win32.IpcRegistry.test.x'
)
$r = Invoke-Soak @{
    Lane = 'none'; Mode = 'standalone'; Runs = 1; Label = 'wronglane'
    Repo = $wrongRepo; OutDir = (Join-Path $work 'out855')
}
Check 'a none-lane soak refuses the win32 binary' ($r.Code -eq 2) "got $($r.Code)"
Check 'it says the binary belongs to another lane' ($r.Text -match "another lane") ($r.Text -replace '\s+', ' ')
Check 'it soaked nothing' (-not ($r.Text -match 'SOAK wronglane')) ($r.Text -replace '\s+', ' ')
# And the same repo IS resolvable as the lane it really is -- the check is a
# lane test, not a blanket refusal.
$r = Invoke-Soak @{
    Lane = 'win32'; Mode = 'standalone'; Runs = 0; Label = 'rightlane'
    Repo = $wrongRepo; OutDir = (Join-Path $work 'out855b')
}
Check 'the win32 lane resolves that same binary' ($r.Text -match [regex]::Escape($wrongExe)) `
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
