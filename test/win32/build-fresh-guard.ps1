# build-fresh-guard acceptance (T1028): an acceptance run refuses, BEFORE it
# launches or types anything, to GRADE a zig-out exe that is older than the
# sources it is being asked to measure.
#
#   powershell -NoProfile -File test\win32\build-fresh-guard.ps1
#   powershell -NoProfile -File test\win32\build-fresh-guard.ps1 -NegativeControl
#
# Non-interactive and launches nothing: the subject is the gate itself. Both
# sides of it are played inside a THROWAWAY REPO under $TEMP - a `src\` tree,
# a `build.zig`, and a `zig-out\bin\ghoztty.cmd` stub that answers `+version`
# the way the real exe does - so the stale case can be produced by writing a
# file rather than by waiting for the real tree to drift, and the fresh case is
# the same fixture with the timestamps the other way round. The real zig-out
# exe still gets a positive control in section F: without it this file could
# pass while the gate rejected every ordinary run.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',

    # Invert one assertion, to prove a green run here is evidence and not a
    # script that asserts nothing (T221's shape).
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0
$script:negReached = $false
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$tmp = Join-Path $env:TEMP "ghoztty-buildfresh-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Run a scriptblock and return the exception message it threw, or $null.
function Get-Throw($block) {
    try { & $block | Out-Null; return $null } catch { return "$($_.Exception.Message)" }
}

# A throwaway repo: src\ with two .zig files, a docs-only .md, a gtk file, a
# build.zig, and a zig-out\bin stub exe that answers `+version` as Debug.
function New-FixtureRepo($name) {
    $root = Join-Path $tmp $name
    foreach ($d in @('src', 'src\apprt\win32', 'src\apprt\gtk', 'zig-out\bin')) {
        New-Item -ItemType Directory -Force (Join-Path $root $d) | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $root 'build.zig') -Value 'pub fn build() void {}' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $root 'src\main.zig') -Value 'const a = 1;' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $root 'src\apprt\win32\App.zig') -Value 'const b = 2;' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $root 'src\notes.md') -Value '# docs only' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $root 'src\apprt\gtk\App.zig') -Value 'const c = 3;' -Encoding ascii
    $exe = Join-Path $root 'zig-out\bin\ghoztty.cmd'
    Set-Content -LiteralPath $exe -Encoding ascii -Value @(
        '@echo off',
        'echo Ghostty 1.4.0-stub',
        'echo Build Config',
        'echo   - build mode    : .Debug',
        'echo   - app runtime   : .win32'
    )
    # Every fixture file starts four hours old, so a section that ages ONE file
    # is measuring that file. Without this the just-written ones all carry
    # "now" and hold the high-water mark themselves.
    foreach ($f in [System.IO.Directory]::EnumerateFiles($root, '*', 'AllDirectories')) {
        [System.IO.File]::SetLastWriteTimeUtc($f, [datetime]::UtcNow.AddMinutes(-240))
    }
    return [pscustomobject]@{ Root = $root; Exe = $exe }
}

# Stamp a file's mtime, in minutes relative to now.
function Set-Age($path, $minutesAgo) {
    [System.IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddMinutes(-$minutesAgo))
}

# The high-water scan is cached per repo per process; a fixture that moves its
# own timestamps has to drop that cache to be measured again.
function Reset-FreshCache {
    if ($script:GhozttyFreshCache) { $script:GhozttyFreshCache.Clear() }
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# ============================================================================
"== A: the high-water mark is the newest thing that can change the exe"
# ============================================================================
$fx = New-FixtureRepo 'a'
Set-Age (Join-Path $fx.Root 'src\main.zig') 90
Set-Age (Join-Path $fx.Root 'src\apprt\win32\App.zig') 60
Set-Age (Join-Path $fx.Root 'build.zig') 120
Set-Age (Join-Path $fx.Root 'src\notes.md') 1
Set-Age (Join-Path $fx.Root 'src\apprt\gtk\App.zig') 2
Reset-FreshCache

$high = Get-GhozttySourceHighWater -Repo $fx.Root
Assert "A1 the scan finds a high-water mark" ($null -ne $high)
Assert "A2 it is the newest .zig, not the newest file" ($high.Path -like '*App.zig')
Assert "A3 a docs-only edit under src\ does not raise it" ($high.Path -notlike '*notes.md')
Assert "A4 nor does Linux's frontend, which this exe cannot contain" `
    ($high.Path -notlike '*\gtk\*')
Assert "A5 build.zig is counted as a source" `
    ((Get-GhozttySourceHighWater -Repo $fx.Root).Count -ge 3)

# ============================================================================
"== B: the predicate compares that mark against the exe"
# ============================================================================
$fxB = New-FixtureRepo 'b'
Set-Age (Join-Path $fxB.Root 'src\main.zig') 120
Set-Age $fxB.Exe 30
Reset-FreshCache
$fresh = Test-GhozttyFreshBuild -Exe $fxB.Exe -Repo $fxB.Root
Assert "B1 an exe newer than every source is fresh" ($fresh.Fresh)
Assert "B2 and it is in scope, so the answer means something" ($fresh.InScope)

Set-Age (Join-Path $fxB.Root 'src\main.zig') 5
Reset-FreshCache
$stale = Test-GhozttyFreshBuild -Exe $fxB.Exe -Repo $fxB.Root
Assert "B3 a source edited after the build reads as stale" (-not $stale.Fresh)
Assert "B4 and the drift is reported in seconds" ($stale.DriftSeconds -gt 60)
Assert "B5 naming the file that holds the mark" ($stale.HighWaterPath -like '*main.zig')

# Out of scope: an exe that nobody claims was built from this tree.
$outside = Join-Path $tmp 'elsewhere.cmd'
Set-Content -LiteralPath $outside -Value '@echo off' -Encoding ascii
Assert "B6 an exe outside zig-out is out of scope, not stale" `
    ((Test-GhozttyFreshBuild -Exe $outside -Repo $fxB.Root).Fresh)
Assert "B7 and it says so, rather than claiming to have measured it" `
    (-not (Test-GhozttyFreshBuild -Exe $outside -Repo $fxB.Root).InScope)

# ============================================================================
"== C: the assert refuses a stale exe, and says how to clear it"
# ============================================================================
$msg = Get-Throw { Assert-GhozttyFreshBuild -Exe $fxB.Exe -Repo $fxB.Root }
Assert "C1 a stale exe throws" ($null -ne $msg)
Assert "C2 the message names the exe" ($msg -match [regex]::Escape($fxB.Exe))
Assert "C3 and the source that outran it" ($msg -match 'main\.zig')
Assert "C4 and how old it is" ($msg -match 'minutes|hours|seconds')
Assert "C5 and gives the build command" ($msg -match '-Doptimize=Debug')
Assert "C6 and says why a green would be worse than a red" ($msg -match 'STAMP')
Assert "C7 and names the rebuild opt-in for a no-relink edit" `
    ($msg -match 'GHOZTTY_TEST_REBUILD_STALE')
Assert "C8 and the explicit hatch for a box that cannot build" `
    ($msg -match 'GHOZTTY_TEST_ALLOW_STALE')

Set-Age $fxB.Exe 0
Reset-FreshCache
Assert "C9 a fresh exe passes silently" `
    ($null -eq (Get-Throw { Assert-GhozttyFreshBuild -Exe $fxB.Exe -Repo $fxB.Root }))

# ============================================================================
"== D: the hatches are explicit acts, and the witness clears a no-relink build"
# ============================================================================
$fxD = New-FixtureRepo 'd'
Set-Age $fxD.Exe 60
Set-Age (Join-Path $fxD.Root 'src\main.zig') 5
Reset-FreshCache
Assert "D1 stale by default" `
    ($null -ne (Get-Throw { Assert-GhozttyFreshBuild -Exe $fxD.Exe -Repo $fxD.Root }))
Assert "D2 -Allow lets it through" `
    ($null -eq (Get-Throw { Assert-GhozttyFreshBuild -Exe $fxD.Exe -Repo $fxD.Root -Allow }))

$env:GHOZTTY_TEST_ALLOW_STALE = '1'
Assert "D3 GHOZTTY_TEST_ALLOW_STALE=1 does the same" `
    ($null -eq (Get-Throw { Assert-GhozttyFreshBuild -Exe $fxD.Exe -Repo $fxD.Root }))
Remove-Item Env:GHOZTTY_TEST_ALLOW_STALE -ErrorAction SilentlyContinue
Assert "D4 and clearing it restores the refusal" `
    ($null -ne (Get-Throw { Assert-GhozttyFreshBuild -Exe $fxD.Exe -Repo $fxD.Root }))

# The wedge case, played without zig: a build that relinks nothing leaves the
# exe's mtime where it was, so only the witness can clear the drift.
Write-GhozttyFreshWitness -Exe $fxD.Exe -BuiltAtUtc ([datetime]::UtcNow)
Reset-FreshCache
Assert "D5 a witness written by a successful build clears the drift" `
    ((Test-GhozttyFreshBuild -Exe $fxD.Exe -Repo $fxD.Root).Fresh)
Assert "D6 the witness lives beside the exe, out of the repo's sight" `
    ((Get-GhozttyFreshWitnessPath -Exe $fxD.Exe) -like '*zig-out\bin\.build-fresh-witness.json')

# A real rebuild retires the witness: it is tied to the exe mtime it was
# written against, so it can never vouch for bytes it did not see.
Set-Age $fxD.Exe 90
Set-Age (Join-Path $fxD.Root 'src\main.zig') 1
Reset-FreshCache
Assert "D7 the witness stops applying once the exe itself moves" `
    (-not (Test-GhozttyFreshBuild -Exe $fxD.Exe -Repo $fxD.Root).Fresh)

# ============================================================================
"== E: the gate is wired into the pre-flight every acceptance script calls"
# ============================================================================
# Assert-GhozttyIsolatedBuild is called by 49 scripts directly and by
# CleanSlate/Isolation for the rest. A stale exe has to be refused THERE, with
# no -Repo and no -Exe of the caller's choosing, or the gate is a library
# nobody calls. So the stub for this section lives under the REAL repo's
# zig-out (gitignored, removed at the end): in scope by path, measured against
# the real src\ high-water mark, and old on purpose.
$fxDir = Join-Path $Repo "zig-out\buildfresh-fixture-$PID"
New-Item -ItemType Directory -Force $fxDir | Out-Null
$fxExe = Join-Path $fxDir 'ghoztty.cmd'
Set-Content -LiteralPath $fxExe -Encoding ascii -Value @(
    '@echo off',
    'echo Ghostty 1.4.0-stub',
    'echo Build Config',
    'echo   - build mode    : .Debug'
)
Set-Age $fxExe 600
Reset-FreshCache

$msgWire = Get-Throw { Assert-GhozttyIsolatedBuild -Exe $fxExe }
Assert "E1 a stale exe under the repo's zig-out is refused by the ordinary pre-flight" `
    ($null -ne $msgWire)
Assert "E2 and it is the freshness gate that speaks, not the build-mode one" `
    ($msgWire -match 'Assert-GhozttyFreshBuild')
Assert "E3 naming the source that outran it" ($msgWire -match '\\src\\')

Set-Age $fxExe 0
Reset-FreshCache
Assert "E4 the same exe, freshly built, passes the pre-flight" `
    ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $fxExe }))

# And the consequence that matters: a harness that would STAMP its guard dies
# before it gets there. Played end to end in a child process - a synthetic
# harness with the same shape as the real ones (pre-flight, then work, then
# stamp) pointed at the stale stub.
Set-Age $fxExe 600
$marker = Join-Path $tmp 'stamped.txt'
$fakeHarness = Join-Path $tmp 'fake-harness.ps1'
Set-Content -LiteralPath $fakeHarness -Encoding ascii -Value @(
    'param([string]$Exe, [string]$Marker, [string]$Lib)',
    '$ErrorActionPreference = ''Stop''',
    '. (Join-Path $Lib ''BuildMode.ps1'')',
    'Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null',
    '"ALL PASS"',
    'Set-Content -LiteralPath $Marker -Value ''stamped'' -Encoding ascii',
    'exit 0'
)
$harnessOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $fakeHarness `
        -Exe $fxExe -Marker $marker -Lib (Join-Path $Repo 'test\win32\lib') 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String)
$harnessExit = $LASTEXITCODE
Assert "E5 a harness run against a stale exe exits non-zero" ($harnessExit -ne 0)
Assert "E6 and never reaches its stamp" (-not (Test-Path -LiteralPath $marker))
Assert "E7 and never printed a verdict either" ($harnessOut -notmatch 'ALL PASS')

Remove-Item -Recurse -Force $fxDir -ErrorAction SilentlyContinue

$modeSrc = Get-Content -LiteralPath (Join-Path $Repo 'test\win32\lib\BuildMode.ps1') -Raw
Assert "E8 BuildMode dot-sources the freshness half" ($modeSrc -match 'BuildFresh\.ps1')
Assert "E9 and calls it on the mode-check pass path" `
    ($modeSrc -match '(?s)Test-GhozttyIsolatedBuildMode -Mode \$mode.*?Assert-GhozttyFreshBuild -Exe \$Exe')

# ============================================================================
"== F: positive control - the real build under test is unaffected"
# ============================================================================
if (Test-Path $Exe) {
    Reset-FreshCache
    $real = Test-GhozttyFreshBuild -Exe $Exe -Repo $Repo
    Assert "F1 the real zig-out exe is in scope" ($real.InScope)
    if ($real.Fresh) {
        $cond = ($null -eq (Get-Throw { Assert-GhozttyIsolatedBuild -Exe $Exe }))
        if ($NegativeControl) {
            $script:negReached = $true
            $cond = -not $cond
        }
        Assert "F2 it is fresh, so the ordinary pre-flight passes as before" $cond
    } else {
        # Not a failure: it is this gate speaking correctly about a tree that
        # has moved since the last build. Say so, and do not stamp.
        "  SKIP F2: zig-out is stale ($($real.DriftSeconds)s behind $($real.HighWaterPath)) - rebuild and re-run"
        $script:skipped++
    }
} else {
    "  SKIP F: $Exe not built"
    $script:skipped++
}

# ============================================================================
"== G: the rule is written down where the build-mode one is"
# ============================================================================
$testingDoc = Get-Content -LiteralPath (Join-Path $Repo 'docs\claude\testing.md') -Raw
Assert "G1 docs/claude/testing.md states the freshness rule" ($testingDoc -match 'BuildFresh\.ps1')
Assert "G2 and names the failure it prevents" ($testingDoc -match 'stale')
Assert "G3 and points at this script" ($testingDoc -match 'build-fresh-guard\.ps1')

""
if ($NegativeControl -and -not $script:negReached) {
    Assert "NEGATIVE CONTROL never reached its inverted assertion" $false
}

# --- stamp (T783) -----------------------------------------------------------
# A clean green run records the covered files, so guard-due can answer "has
# anyone run this against the code as it stands?". A run with a SKIPPED section
# left the positive control unmeasured and does not stamp; neither does a
# -NegativeControl run, which inverted an assertion on purpose.
if ($script:failures -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard build-fresh 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" }
else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
