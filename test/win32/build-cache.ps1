<#
.SYNOPSIS
    build-cache acceptance (T1054): the build cache is cleared on a cadence the
    loop owns, and a near-full drive is named as a near-full drive.

.DESCRIPTION
    On 2026-08-21 D: hit exactly 0 bytes free - 31,359 entries and 1,235 GB in
    `.zig-cache\o`, which nothing had ever evicted - and every floor lane then
    died in five seconds with a bare `error: Unexpected` from zig. That message
    reads as red code, so the failure mode is not "the box is full", it is "a
    turn spends its context debugging a compiler error that is really a disk".

    Sections:

      A. The cheap state question (`Get-BuildCacheState`) against FIXTURE cache
         directories: under the limits it says ok, over the entry ceiling it
         says over and names `entries`, and the free-space trigger wins over the
         entry one when both apply.
      B. The clear is WHOLE. Pruning `o\` alone leaves Zig's manifests in `h\`
         naming outputs that no longer exist, which is how the first attempt at
         this broke the next lane with `failed to spawn build runner ...
         FileNotFound`. So: every subdirectory goes, not just `o`.
      C. `build-cache.ps1` on the wire, over fixtures - `sweep` clears an
         over-limit cache, `sweep` leaves an under-limit one ALONE (the half
         that stops this from being a daily cold rebuild), `clear` refuses
         without -Force, and every action exits 0 because this runs inside the
         claim.
      D. `floor-lane.ps1`'s disk pre-flight: with the floor set above the real
         free space it fails with the disk message and NEVER launches zig; with
         the floor at its default it does not fire on a healthy box.
      E. The claim reports it, and the cost is bounded: `go-loop-exec.ps1` calls
         the sweeper, and a state check over a large fixture cache stays well
         inside a second.
      F. The OTHER drive (T1431). Zig's C/C++ compile steps scratch in %TEMP%,
         which on this box is C: while everything the cache sweeper measures is
         on D: - so on 2026-09-07 a claim printed a terabyte free while C: held
         0.1 GB and every lane died with the same bare `error: Unexpected`.
         Two halves: the build shells scratch on the REPO's drive so a full C:
         cannot stop a build at all, and the drive %TEMP% is really on is
         measured and named so the box state is visible before a turn spends its
         context on a fake compile error.

    Launches no GUI and touches no real cache: every section works on throwaway
    directories under $TEMP. Section D runs the real `floor-lane.ps1` but only
    on the path that refuses before launching anything.

.NOTES
    # persistence: launches no GUI and no app - this exercises scripts.
#>
[CmdletBinding()]
param(
    # Invert one assertion, to prove a green run here is evidence rather than a
    # script that asserts nothing (T221's shape).
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $repo 'scripts\lib\BuildCache.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-buildcache-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

# A throwaway cache shaped like a real one: `o\<hash>` output entries plus the
# `h\` manifests and `c\` generated sources that make a partial prune dangerous.
function New-FixtureCache([string]$name, [int]$entries) {
    $root = Join-Path $tmp $name
    foreach ($d in @('o', 'h', 'c', 'tmp')) { New-Item -ItemType Directory -Force (Join-Path $root $d) | Out-Null }
    for ($i = 0; $i -lt $entries; $i++) {
        $e = Join-Path $root ("o\{0:x16}" -f $i)
        New-Item -ItemType Directory -Force $e | Out-Null
        Set-Content -LiteralPath (Join-Path $e 'artifact.bin') -Value "entry $i" -Encoding ascii
    }
    Set-Content -LiteralPath (Join-Path $root 'h\manifest.txt') -Value 'points at o\ entries' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $root 'c\options.zig') -Value 'const a = 1;' -Encoding ascii
    return $root
}

try {

# ===========================================================================
Write-Host ''
Write-Host '== A: the cheap state question'
# ===========================================================================

$small = New-FixtureCache 'cache-small' 5
$big = New-FixtureCache 'cache-big' 40

$okState = Get-BuildCacheState -CacheDirs @($small) -MinFreeGB 0 -MaxEntries 1000
AssertEq 'A1 an under-limit cache is not over' $false ([bool]$okState.Over)
AssertEq 'A2 and it counted the entries it has' 5 $okState.Entries
Assert 'A3 and its summary says ok' ($okState.Summary -match '^build cache ok:')

$overState = Get-BuildCacheState -CacheDirs @($big) -MinFreeGB 0 -MaxEntries 40
AssertEq 'A4 an at-ceiling cache is over' $true ([bool]$overState.Over)
AssertEq 'A5 and names the entry ceiling as the reason' 'entries' $overState.Reason

# The free-space trigger is the one that matters on the day it matters, so it
# must WIN when both apply: the message a full drive produces has to say
# free-space, not entries.
$bothState = Get-BuildCacheState -CacheDirs @($big) -MinFreeGB 999999 -MaxEntries 40
AssertEq 'A6 free space wins over the entry ceiling when both trip' 'free-space' $bothState.Reason
Assert 'A7 and the summary names the free-space floor' ($bothState.Summary -match 'floor 999999 GB')

# The warning band: not over, but close enough that the next few days of
# building will get there. It has to be distinguishable from ok.
$warnState = Get-BuildCacheState -CacheDirs @($small) -MinFreeGB 1 -MaxEntries 1000 -WarnFreeGB 999999
AssertEq 'A8 the warning band is not "over"' $false ([bool]$warnState.Over)
AssertEq 'A9 but it is flagged as a warning' $true ([bool]$warnState.Warn)
Assert 'A10 and says so in words' ($warnState.Summary -match 'getting large')

# The whole point of the design: no full walk. A state check over the biggest
# fixture here must not stat its way through the tree.
$multi = Get-BuildCacheState -CacheDirs @($small, $big) -MinFreeGB 0 -MaxEntries 1000
AssertEq 'A11 several caches report the largest entry count' 40 $multi.Entries
AssertEq 'A12 and one record per cache' 2 @($multi.Caches).Count

# A cache directory that does not exist is a normal state (a fresh clone, or
# the turn right after a clear) and must not throw or read as enormous.
$absent = Get-BuildCacheState -CacheDirs @((Join-Path $tmp 'no-such-cache')) -MinFreeGB 0 -MaxEntries 1000
AssertEq 'A13 an absent cache counts zero entries and is not over' $false ([bool]$absent.Over)

# ===========================================================================
Write-Host ''
Write-Host '== B: the clear is whole, not an age prune of o\'
# ===========================================================================

$whole = New-FixtureCache 'cache-whole' 6
$cleared = Clear-BuildCache -CacheDir $whole
AssertEq 'B1 the clear reports the directory removed' $true ([bool]$cleared.Removed)
Assert 'B2 and the cache directory is gone' (-not (Test-Path -LiteralPath $whole))
# The specific failure this prevents: `h\` surviving a prune of `o\` makes zig
# resolve a manifest hit to an output that no longer exists, and the next build
# dies with `failed to spawn build runner ... FileNotFound`.
Assert 'B3 the manifest directory went with it (no dangling h\ entries)' `
    (-not (Test-Path -LiteralPath (Join-Path $whole 'h')))
Assert 'B4 and so did the generated-source directory' `
    (-not (Test-Path -LiteralPath (Join-Path $whole 'c')))

$missing = Clear-BuildCache -CacheDir (Join-Path $tmp 'never-existed')
AssertEq 'B5 clearing an absent cache is not an error' 'absent' $missing.Error

# ===========================================================================
Write-Host ''
Write-Host '== C: build-cache.ps1 on the wire'
# ===========================================================================

$cacheScript = Join-Path $repo 'scripts\build-cache.ps1'
Assert 'C1 the sweeper exists' (Test-Path -LiteralPath $cacheScript)

function Invoke-Sweeper([string[]]$sweeperArgs) {
    # Stringify PER RECORD, never format the merged stream (T883): a merged
    # native stream handed to Out-String arrives as ErrorRecord blocks whose
    # wrapping tracks the console width, so an assertion over its text would
    # pass or fail by terminal size.
    $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cacheScript @sweeperArgs 2>&1 |
        ForEach-Object { $_.ToString() }) -join "`n"

    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

# The half that clears.
$sweepOver = New-FixtureCache 'sweep-over' 12
$r = Invoke-Sweeper @('sweep', '-Repo', $tmp, '-CacheDir', $sweepOver, '-MinFreeGB', '0', '-MaxEntries', '12')
AssertEq 'C2 sweep over the limit exits 0 (a claim must never fail over housekeeping)' 0 $r.Code
Assert 'C3 and says it cleared, with the reason' ($r.Out -match 'BUILD CACHE CLEARED over limit \(entries\)')
Assert 'C4 and the cache is actually gone' (-not (Test-Path -LiteralPath $sweepOver))

# The half that does NOT clear - without this the loop would pay a cold
# rebuild every single turn, which is a worse bug than the one being fixed.
$sweepUnder = New-FixtureCache 'sweep-under' 3
$r = Invoke-Sweeper @('sweep', '-Repo', $tmp, '-CacheDir', $sweepUnder, '-MinFreeGB', '0', '-MaxEntries', '1000')
$underKept = (Test-Path -LiteralPath (Join-Path $sweepUnder 'o'))
if ($NegativeControl) { $script:negReached = $true; $underKept = -not $underKept }
Assert 'C5 sweep under the limit leaves the cache alone' $underKept
Assert 'C6 and reports it as ok rather than silently' ($r.Out -match 'build cache ok:')
AssertEq 'C7 and exits 0' 0 $r.Code

# `check` never deletes, whatever the numbers say.
$checkOver = New-FixtureCache 'check-over' 8
$r = Invoke-Sweeper @('check', '-Repo', $tmp, '-CacheDir', $checkOver, '-MinFreeGB', '0', '-MaxEntries', '8')
Assert 'C8 check reports over-limit' ($r.Out -match 'build cache over limit')
Assert 'C9 but deletes nothing' (Test-Path -LiteralPath (Join-Path $checkOver 'o'))

# `clear` is the manual hatch and it costs a cold rebuild, so it asks.
$manual = New-FixtureCache 'clear-manual' 2
$r = Invoke-Sweeper @('clear', '-Repo', $tmp, '-CacheDir', $manual, '-MinFreeGB', '0', '-MaxEntries', '1000')
Assert 'C10 clear without -Force refuses' ($r.Out -match 'refusing to clear without -Force')
Assert 'C11 and leaves the cache in place' (Test-Path -LiteralPath (Join-Path $manual 'o'))
$r = Invoke-Sweeper @('clear', '-Force', '-Repo', $tmp, '-CacheDir', $manual, '-MinFreeGB', '0', '-MaxEntries', '1000')
Assert 'C12 clear -Force clears on request' (-not (Test-Path -LiteralPath $manual))
Assert 'C13 and says it was on request' ($r.Out -match 'CLEARED on request')

# Stale scratch dirs are REPORTED and never deleted - they sit outside a cache,
# so "entirely regenerable" is an assumption rather than a fact.
$scratchRepo = Join-Path $tmp 'scratch-repo'
New-Item -ItemType Directory -Force (Join-Path $scratchRepo 'zig-out-t999') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $scratchRepo 'zig-out') | Out-Null
$r = Invoke-Sweeper @('check', '-Repo', $scratchRepo, '-CacheDir', (Join-Path $scratchRepo '.zig-cache'), '-MinFreeGB', '0', '-MaxEntries', '1000')
Assert 'C14 a stale scratch dir is reported' ($r.Out -match 'stale scratch dirs: 1')
Assert 'C15 and it is left on disk' (Test-Path -LiteralPath (Join-Path $scratchRepo 'zig-out-t999'))
Assert 'C16 while the live zig-out is not reported as stale' ($r.Out -notmatch '\(zig-out,')

# The per-task scratch dirs this project leaves behind (`t508-*`) sit under the
# REPO cache, not the global one, so the report has to look at every cache it
# manages rather than only the one zig owns.
$scratchCache = Join-Path $scratchRepo '.zig-cache'
foreach ($d in @('o', 'h', 't999-scratch')) { New-Item -ItemType Directory -Force (Join-Path $scratchCache $d) | Out-Null }
$r = Invoke-Sweeper @('check', '-Repo', $scratchRepo, '-CacheDir', $scratchCache, '-MinFreeGB', '0', '-MaxEntries', '1000')
Assert 'C17 a scratch dir under a cache is reported too' ($r.Out -match 't999-scratch')
Assert "C18 but zig's own o\ and h\ are not called scratch" ($r.Out -notmatch 'stale scratch dirs: [3-9]')

# ===========================================================================
Write-Host ''
Write-Host '== D: the floor lane says "disk", not "error: Unexpected"'
# ===========================================================================

$floor = Join-Path $repo 'scripts\floor-lane.ps1'
# Where Invoke-Lane actually writes: $env:TEMP\floor-lane-<lane>-<stamp>.log.
# Counting the wrong directory would make D6 below compare 0 with 0 and pass
# whatever the pre-flight did - the exact fail-open shape T1039/T962 closed.
$laneLogGlob = 'floor-lane-*.log'
function Measure-LaneLog { @(Get-ChildItem -LiteralPath $env:TEMP -Filter $laneLogGlob -ErrorAction SilentlyContinue).Count }
# Positive control for the probe itself, so D6 cannot pass by looking in a
# directory where nothing is ever written (0 == 0 forever) - the exact fail-open
# shape T1039/T962 closed. A sentinel named like a lane log must be SEEN.
$sentinel = Join-Path $env:TEMP "floor-lane-probe-$PID.log"
$countNoSentinel = Measure-LaneLog
Set-Content -LiteralPath $sentinel -Value 'probe' -Encoding ascii
$countWithSentinel = Measure-LaneLog
Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
AssertEq 'D0 the lane-log probe sees a file where lanes actually log' ($countNoSentinel + 1) $countWithSentinel
$laneLogsBefore = Measure-LaneLog

# A floor nothing can satisfy: the pre-flight must fire.
$out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane lib -MinFreeGB 9999999 2>&1 |
    ForEach-Object { $_.ToString() }) -join "`n"
$code = $LASTEXITCODE
Assert 'D1 an impossible free-space floor refuses the run' ($out -match 'FLOOR PREFLIGHT FAIL')
Assert 'D2 and the message names the disk, not the compiler' ($out -match 'DISK: .* has .* GB free')
Assert 'D3 and points at the remedy' ($out -match 'build-cache\.ps1 clear -Force')
Assert 'D4 and says no lane was launched' ($out -match 'no lane was launched')
AssertEq 'D5 and exits FAIL' 1 $code
# The claim in D4 has to be true, not just printed: a refused run must not have
# produced a lane log.
$laneLogsAfter = Measure-LaneLog
AssertEq 'D6 and really launched nothing (no new lane log)' $laneLogsBefore $laneLogsAfter
Assert 'D7 the same drive is reported once, not once per path' `
    (@([regex]::Matches($out, 'DISK: ')).Count -eq 1)

# The default must not fire on a healthy box, or the gate is just a new outage.
$state = Get-BuildCacheState -CacheDirs @((Join-Path $repo '.zig-cache')) -MinFreeGB 0 -MaxEntries 999999
if ($null -eq $state.FreeGB) {
    Write-Host '  SKIP D8: could not read free space on the repo drive'
} else {
    Assert 'D8 the repo drive is above the 10 GB default, so ordinary runs are unaffected' ($state.FreeGB -gt 10)
}

# ===========================================================================
Write-Host ''
Write-Host '== E: the loop owns the cadence, and it is cheap'
# ===========================================================================

$exec = Get-Content -LiteralPath (Join-Path $repo 'scripts\go-loop-exec.ps1') -Raw
Assert 'E1 the claim runs the sweeper' ($exec -match "build-cache\.ps1")
Assert 'E2 as a sweep, so being over the limit is what authorizes the clear' ($exec -match "cacheScript sweep")

$lane = Get-Content -LiteralPath $floor -Raw
Assert 'E3 floor-lane derives the global cache from the one shared rule' ($lane -match 'Resolve-ZigGlobalCacheDir')
Assert 'E4 and there is no second copy of that rule left in it' `
    ($lane -notmatch "return \(Join-Path \`$drive '\\\\zig-global-cache'\)")

# Bounded cost: the check on a healthy box must not walk the cache. 40 fixture
# entries in well under a second is a weak bound on its own, so the assertion
# that carries the weight is the REAL repo cache below.
$sw = [Diagnostics.Stopwatch]::StartNew()
$realState = Get-BuildCacheState -CacheDirs @((Join-Path $repo '.zig-cache'), (Resolve-ZigGlobalCacheDir -RepoPath $repo)) `
    -MinFreeGB 0 -MaxEntries 999999
$sw.Stop()
Write-Host "  (state of the real caches: $($realState.Entries) entries, $($realState.FreeGB) GB free, $($sw.ElapsedMilliseconds) ms)"
Assert 'E5 a state check on the real caches costs under a second' ($sw.ElapsedMilliseconds -lt 1000)

# ===========================================================================
Write-Host ''
Write-Host '== F: the drive %TEMP% is on is measured too, and builds do not scratch there'
# ===========================================================================

# The rule, and the fact that there is exactly ONE of it.
$repoDrive = Split-Path -Qualifier $repo
AssertEq 'F1 the build temp dir sits on the repo drive' `
    $repoDrive (Split-Path -Qualifier (Resolve-BuildTempDir -RepoPath $repo))
AssertEq 'F2 and an explicit path is left alone' `
    'X:\somewhere' (Resolve-BuildTempDir -RepoPath $repo -Explicit 'X:\somewhere')
$prevEnvTemp = $env:GHOZTTY_BUILD_TEMP
try {
    $env:GHOZTTY_BUILD_TEMP = 'Y:\from-env'
    AssertEq 'F3 and GHOZTTY_BUILD_TEMP overrides, which is what lets a harness drive a fixture' `
        'Y:\from-env' (Resolve-BuildTempDir -RepoPath $repo)
} finally { $env:GHOZTTY_BUILD_TEMP = $prevEnvTemp }

# Push/Pop actually moves TMP and TEMP, creates the directory, and puts back
# exactly what was there - a helper that leaked would relocate the %TEMP% of
# every acceptance script that loads BuildFresh.
$fixtureTemp = Join-Path $tmp 'buildtemp-fixture'
$beforeTmp = $env:TMP
$beforeTemp = $env:TEMP
$token = Push-BuildTempEnv -RepoPath $repo -Explicit $fixtureTemp
AssertEq 'F4 the push points TMP at the build scratch dir' $fixtureTemp $env:TMP
AssertEq 'F5 and TEMP with it - zig reads both' $fixtureTemp $env:TEMP
Assert 'F6 and creates it, so the first build does not fail on a missing directory' `
    (Test-Path -LiteralPath $fixtureTemp)
Pop-BuildTempEnv -Previous $token
AssertEq 'F7 the pop restores TMP' $beforeTmp $env:TMP
AssertEq 'F8 and TEMP' $beforeTemp $env:TEMP
$env:TMP = 'Z:\scratch'
Pop-BuildTempEnv -Previous $null
AssertEq 'F9 a null token is a no-op, so a finally can call it unconditionally' 'Z:\scratch' $env:TMP
$env:TMP = $beforeTmp

# The reporting half: a full %TEMP% drive is NAMED, and the summary says
# whether it would actually stop a build.
$low = Get-SystemTempState -RepoPath $repo -LowFreeGB 99999999
Assert 'F10 an out-of-room %TEMP% drive reads as low' ([bool]$low.Low)
Assert 'F11 and the summary names the drive rather than the compiler' `
    ($low.Summary -match 'system temp low: \w:.*free')
$onRepoDrive = Get-SystemTempState -RepoPath $repo -TempPath $repo -LowFreeGB 99999999
Assert 'F12 %TEMP% already on the repo drive is not "redirected"' (-not $onRepoDrive.Redirected)
Assert 'F13 and that case says a build WILL fail, because nothing moves it elsewhere' `
    ($onRepoDrive.Summary -match "error: Unexpected")
$healthy = Get-SystemTempState -RepoPath $repo -LowFreeGB 0
Assert 'F14 a healthy box reads ok and still names where builds scratch' `
    ((-not $healthy.Low) -and ($healthy.Summary -match 'system temp ok'))

# And the wiring: the sweeper the claim runs asks the question, and the build
# paths take the answer.
$sweeper = Get-Content -LiteralPath (Join-Path $repo 'scripts\build-cache.ps1') -Raw
Assert 'F15 the sweeper the claim runs measures the %TEMP% drive' ($sweeper -match 'Get-SystemTempState')
Assert 'F16 floor-lane resolves the build temp from the shared rule' ($lane -match 'Resolve-BuildTempDir')
Assert 'F17 and sets TMP and TEMP on the build shell it spawns' `
    ($lane -match 'set .*TMP=' -and $lane -match 'set .*TEMP=')
Assert 'F18 and its disk pre-flight covers that directory too' ($lane -match '\$Repo, \$cacheDir, \$buildTemp')
$fresh = Get-Content -LiteralPath (Join-Path $repo 'test\win32\lib\BuildFresh.ps1') -Raw
Assert 'F19 the acceptance rebuild scratches there as well' ($fresh -match 'Push-BuildTempEnv')
Assert 'F20 and restores what it replaced' ($fresh -match 'Pop-BuildTempEnv')
$publish = Get-Content -LiteralPath (Join-Path $repo 'scripts\publish-windows-release.ps1') -Raw
Assert 'F21 so does the release build' ($publish -match 'Push-BuildTempEnv')
$upgrade = Get-Content -LiteralPath (Join-Path $repo 'scripts\launch-upgrade.ps1') -Raw
Assert 'F22 and the staging build the delivery makes' ($upgrade -match 'Push-BuildTempEnv')
$databreak = Get-Content -LiteralPath (Join-Path $repo 'scripts\crash-databreak.ps1') -Raw
Assert 'F22b and the lane the databreak runner drives through its own .cmd' `
    ($databreak -match 'Resolve-BuildTempDir' -and $databreak -match 'set .*TMP=')

# END TO END, because F16-F22 only read source. The wrapper really is asked for
# a command and the CHILD SHELL really answers with the repo drive - which is
# the only assertion here that would have caught the quoting trap the
# ZIG_GLOBAL_CACHE_DIR line beside it carries a comment about. `/v:on` and
# `!TMP!` on purpose: `%TMP%` would be expanded by the OUTER cmd while it parses
# the line, i.e. before `set` has run, and the arm would read C: and fail for a
# reason that has nothing to do with the code.
$probe = (& powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Command 'cmd /v:on /c echo TMPIS-!TMP! TEMPIS-!TEMP!' 2>&1 |
    ForEach-Object { $_.ToString() }) -join "`n"
$wantTemp = Resolve-BuildTempDir -RepoPath $repo
Assert 'F23 the wrapper announces where the build will scratch' ($probe -match 'build TMP/TEMP=')
Assert 'F24 and the build shell really answers with it for TMP' `
    ($probe -match ('TMPIS-' + [regex]::Escape($wantTemp)))
Assert 'F25 and for TEMP' `
    ($probe -match ('TEMPIS-' + [regex]::Escape($wantTemp)))

Write-Host ''
if ($NegativeControl -and -not $script:negReached) {
    Assert 'NEGATIVE CONTROL never reached its inverted assertion' $false
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard build-cache -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'build-cache' -MinPass 50
