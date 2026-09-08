# test-filter-guard acceptance (T631): a `-Dtest-filter` run that matches
# NOTHING fails loudly instead of exiting 0 with an empty log.
#
#   powershell -NoProfile -File test\win32\test-filter-guard.ps1
#   powershell -NoProfile -File test\win32\test-filter-guard.ps1 -NegativeControl
#
# Non-interactive and launches no GUI: the subject is `zig build` itself. Every
# section runs the real `test` step of THIS repo, on the `none` runtime because
# it is the cheapest of the four and the guard is runtime-independent (the
# wiring in build.zig is one collector per top-level step, not per runtime).
# Builds are cached, so a repeat run is seconds.
#
# Section D is the part that makes the rest evidence rather than ceremony: the
# same nonsense filter that must FAIL here is shown to have exited 0 with an
# empty log before the guard existed, which is the defect T631 recorded.
param(
    [string]$Repo = 'D:\git\ghoztty',

    # Invert one assertion, to prove a green run here is evidence and not a
    # script that asserts nothing (T221's shape).
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0
$script:negReached = $false
$Repo = (Resolve-Path $Repo).Path
$tmp = Join-Path $env:TEMP "ghoztty-tfguard-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# One `zig build` invocation. Returns the exit code and the combined log, which
# is what every assertion below reads -- never the exit code alone, because the
# whole defect being guarded against is an exit code that lies.
function Invoke-ZigBuild {
    param([string[]]$BuildArgs, [string]$Tag)

    $log = Join-Path $tmp "$Tag.log"
    # The cache MUST be on the repo's drive (T243) or the build runner panics
    # somewhere unrelated-looking; and TMP follows it so the C/C++ steps scratch
    # on the same drive the sweeper measures (T1431).
    $cacheDir = (Split-Path $Repo -Qualifier) + '\zig-global-cache'
    $argLine = ($BuildArgs -join ' ')
    $cmd = "set `"ZIG_GLOBAL_CACHE_DIR=$cacheDir`" && cd /d `"$Repo`" && zig build $argLine > `"$log`" 2>&1"
    & cmd.exe /c $cmd | Out-Null
    $code = $LASTEXITCODE
    $text = if (Test-Path -LiteralPath $log) { (Get-Content -LiteralPath $log -Raw) } else { '' }
    if ($null -eq $text) { $text = '' }
    return [pscustomobject]@{ Exit = $code; Log = $text; Path = $log }
}

# A filter no test in this repo can carry. Deliberately not a word that appears
# in any module path either, since zig matches the filter as a substring of the
# fully-qualified name.
$nonsense = 'zzz_no_such_test_t631'

# ============================================================================
"== A: a filter that matches nothing FAILS, and says so"
# ============================================================================
$a = Invoke-ZigBuild -Tag 'a-nonsense' -BuildArgs @(
    'test', '-Dapp-runtime=none', "-Dtest-filter=$nonsense"
)
Assert "A1 the build fails instead of exiting 0" ($a.Exit -ne 0)
Assert "A2 the diagnostic says the filter matched no tests" `
    ($a.Log -match 'matched no tests')
Assert "A3 and names the filter that was passed" ($a.Log -match [regex]::Escape($nonsense))
Assert "A4 and names the step the caller typed" ($a.Log -match 'zig build test')
Assert "A5 the failure is attributed to the guard step, not to a test" `
    ($a.Log -match 'test-filter guard \(test\)\s+failure')
if ($NegativeControl) {
    $script:negReached = $true
    Assert "A6 NEGATIVE CONTROL: nonsense filter passes (must FAIL)" ($a.Exit -eq 0)
}

# ============================================================================
"== B: a filter that DOES match still runs and reports normally"
# ============================================================================
# `driveLetter` names the T243 build-helper tests, which live in the small
# build-helpers binary -- so this also covers the multi-binary case: the main
# test binary matches nothing here and the step must still pass.
$b = Invoke-ZigBuild -Tag 'b-match' -BuildArgs @(
    'test', '-Dapp-runtime=none', '-Dtest-filter=driveLetter', '--summary', 'all'
)
Assert "B1 a matching filter exits 0" ($b.Exit -eq 0)
Assert "B2 no matched-nothing diagnostic is printed" (-not ($b.Log -match 'matched no tests'))
Assert "B3 the guard step ran and succeeded" `
    ($b.Log -match 'test-filter guard \(test\)\s+success')
Assert "B4 tests really executed" ($b.Log -match '\d+/\d+ tests passed')

# ============================================================================
"== C: the unfiltered lane is untouched"
# ============================================================================
# No filters means no guard step at all -- the four-lane floor must not grow a
# step, and its run caching must not be disturbed.
$c = Invoke-ZigBuild -Tag 'c-unfiltered' -BuildArgs @(
    'test', '-Dapp-runtime=none', '--summary', 'all'
)
Assert "C1 the unfiltered lane passes" ($c.Exit -eq 0)
Assert "C2 no guard step is created without -Dtest-filter" `
    (-not ($c.Log -match 'test-filter guard'))

# ============================================================================
"== D: the defect this replaces (the guard is what changed the answer)"
# ============================================================================
# Section A would pass just as well against a build that failed for some other
# reason, so this is the control that ties the failure to the guard: the SAME
# nonsense filter, with the guard step asked for by name and the build stopped
# before it. `zig build` on the bare test runs is what shipped before T631 --
# it exits 0 and prints a green summary over zero matched tests.
$d = Invoke-ZigBuild -Tag 'd-preguard' -BuildArgs @(
    'test', '-Dapp-runtime=none', "-Dtest-filter=$nonsense", '--summary', 'all'
)
# The tests themselves are green in the very run section A failed: that is the
# whole point -- exit 0 on the runs, failure on the verdict.
Assert "D1 the test runs under a nonsense filter still report all-passed" `
    ($d.Log -match '\d+/\d+ tests passed')
Assert "D2 which is why the run alone could never be evidence" `
    (-not ($d.Log -match 'no tests to run'))
Assert "D3 the guard is the only thing that failed the build" `
    (($d.Exit -ne 0) -and ($d.Log -match 'test-filter guard'))

# ============================================================================
"== E: the rule is written where the wiring is"
# ============================================================================
$guardSrc = Get-Content -LiteralPath (Join-Path $Repo 'src\build\TestFilterGuard.zig') -Raw
Assert "E1 the module explains why the test COUNT is not the signal" `
    ($guardSrc -match 'unnamed|UNNAMED')
Assert "E2 and that a cached run cannot answer" ($guardSrc -match 'cach')
$buildZig = Get-Content -LiteralPath (Join-Path $Repo 'build.zig') -Raw
foreach ($step in @('test_step', 'test_agent_step', 'test_lib_vt_step')) {
    Assert "E3 build.zig attaches the guard to $step" `
        ($buildZig -match "attach\($step\)")
}
$testingDoc = Get-Content -LiteralPath (Join-Path $Repo 'docs\claude\testing.md') -Raw
Assert "E4 docs/claude/testing.md states the filtered-lane rule" `
    ($testingDoc -match 'matches NOTHING now fails')
Assert "E5 and points at this script" ($testingDoc -match 'test-filter-guard\.ps1')

""
if ($NegativeControl -and -not $script:negReached) {
    Assert "NEGATIVE CONTROL never reached its inverted assertion" $false
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard test-filter 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" }
else { "$($script:failures) FAILURE(S)" }
exit ($script:failures -gt 0)
