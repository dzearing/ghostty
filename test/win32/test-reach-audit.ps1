# test-reach acceptance (T1191): a win32 module's unit tests may not sit un-run.
#
#   powershell -NoProfile -File test\win32\test-reach-audit.ps1
#   powershell -NoProfile -File test\win32\test-reach-audit.ps1 -TeethCheck
#
# isolation: none - this builds and runs the win32 TEST lane (a console test
# binary out of `.zig-cache`) and reads its string table. It launches no
# Ghoztty, takes no IPC endpoint, and touches no user state (T680 meta-check
# reads this marker).
#
# THE RULE: every `src\apprt\win32\*.zig` that contains a `test` block has that
# block executed by `zig build test -Dapp-runtime=win32`.
#
# Why it needs checking at all, and why the check is shaped the way it is, is
# written out in `lib\TestReachAudit.ps1`. The short version: Zig runs a file's
# tests only if the file's container is REFERENCED from an analyzed one, the
# hand-written `test { _ = @import("win32/X.zig"); }` list in
# `src\apprt\win32.zig` is what does the referencing, and a module left off it
# compiles, reads as covered, and is skipped in silence. T1177 measured that on
# `startup_error.zig`: a deliberately broken assertion inside it went GREEN
# through the full lane.
#
# The oracle is the compiled test binary rather than a PowerShell model of Zig's
# reachability rules - see the library header for why a model is the wrong
# answer here specifically.
#
# Sections:
#
#   A. The comparison itself, against fixtures. Cheap, no build: proves the
#      analyzer names a missing module and stays quiet on a complete set.
#   B. The sweep. Builds the lane, reads the binary it ran, and requires the
#      missing set to be EMPTY. Reports the covered count as a number.
#   C. `-TeethCheck` only: the negative control the rule is worth nothing
#      without. It removes one known-good entry from `win32.zig`'s list,
#      rebuilds, and requires section B's comparison to go red NAMING that
#      file - then puts the line back. This is a real rebuild and takes
#      minutes; it is not part of a routine run.
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestReachAudit.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t1191-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
'== A: the comparison, against fixtures'
# ===========================================================================

$fa = Get-TestReachFindings -WithTests @('alpha', 'beta', 'gamma') -InBinary @('alpha', 'beta', 'gamma')
Assert 'A1 a complete set yields no finding' (@($fa.Missing).Count -eq 0) `
    ("named: " + (@($fa.Missing) -join ', '))

$fb = Get-TestReachFindings -WithTests @('alpha', 'beta', 'gamma') -InBinary @('alpha', 'gamma')
Assert 'A2 a module the binary never heard of is named' `
    ((@($fb.Missing) -join ',') -eq 'beta') ("named: " + (@($fb.Missing) -join ', '))

# A module in the binary with no test block on disk should be impossible. It is
# reported rather than assumed away, because the way it would actually arise -
# a stale binary being read - is the one failure that could make section B pass
# over a tree it never measured.
$fc = Get-TestReachFindings -WithTests @('alpha') -InBinary @('alpha', 'ghost')
Assert 'A3 a binary-only module is reported, not swallowed' `
    ((@($fc.Extra) -join ',') -eq 'ghost') ("named: " + (@($fc.Extra) -join ', '))

# The source scan reads the tree, so it is checked against the tree: the four
# modules T1191 found are all real files with real test blocks, and the scan
# must see every one of them.
$withTests = @(Get-WinModulesWithTests $Repo)
Assert "A4 the source scan finds win32 modules with tests ($($withTests.Count))" `
    ($withTests.Count -ge 150) "found $($withTests.Count)"
foreach ($m in @('AgentIntegrationsDialog', 'ipc_agent_integration', 'provenance', 'restore_retry', 'startup_error')) {
    Assert "A5 the scan sees $m" ($withTests -contains $m)
}

# ===========================================================================
'== B: the sweep - every win32 module with tests is in the lane'
# ===========================================================================

$buildLog = Join-Path $tmp 'lane.log'
$lane = Resolve-WinTestBinary -Repo $Repo -LogPath $buildLog
Assert 'B1 the win32 test lane builds and passes' ($lane.ExitCode -eq 0) `
    "zig build test exited $($lane.ExitCode); log: $buildLog"
Assert 'B2 the lane names the test binary it ran' `
    ($lane.ExePath -and (Test-Path -LiteralPath $lane.ExePath)) "path: $($lane.ExePath)"

$inBinary = @()
if ($lane.ExePath -and (Test-Path -LiteralPath $lane.ExePath)) {
    $inBinary = @(Get-WinModulesInTestBinary $lane.ExePath)
}
Assert "B3 the binary names the modules whose tests it carries ($($inBinary.Count))" `
    ($inBinary.Count -ge 150) "found $($inBinary.Count)"

$found = Get-TestReachFindings -WithTests $withTests -InBinary $inBinary
$missing = @($found.Missing)
Assert 'B4 no win32 module has tests the lane never runs' ($missing.Count -eq 0) `
    ("un-run: " + ($missing -join ', ') + " -- add `_ = @import(""win32/<name>.zig"");` to src\apprt\win32.zig's test block")
Assert 'B5 the binary carries no module that has no test block on disk' `
    (@($found.Extra).Count -eq 0) ("stale binary? " + (@($found.Extra) -join ', '))

"  NOTE $($withTests.Count) win32 modules carry tests; $($inBinary.Count) of them run in the lane"

# ===========================================================================
if ($TeethCheck) {
    '== C: the negative control - drop a listed module and the sweep must go red'
    # ===========================================================================
    # The entry has to be one whose ONLY route into the lane is this list, and
    # picking that by eye does not work: the first draft wounded
    # `ConfirmDialog.zig` - the oldest entry in the block - and the control
    # FAILED, because ConfirmDialog is also reached transitively through
    # another listed module's own test block. Several entries in that list are
    # redundant in exactly that way and there is no way to tell which by
    # reading it.
    #
    # `provenance.zig` is the one shape that cannot be wrong: T1191 MEASURED
    # its absence from the binary before its line existed, so the list is
    # demonstrably its only route. Same for the other three it added.
    $listPath = Join-Path $Repo 'src\apprt\win32.zig'
    $original = [System.IO.File]::ReadAllText($listPath)
    $line = '    _ = @import("win32/provenance.zig");'
    try {
        Assert 'C1 the entry under test is in the list' ($original.Contains($line))
        $wounded = $original.Replace($line + "`r`n", '').Replace($line + "`n", '')
        [System.IO.File]::WriteAllText($listPath, $wounded)

        $tlog = Join-Path $tmp 'teeth.log'
        $tlane = Resolve-WinTestBinary -Repo $Repo -LogPath $tlog
        $tin = @()
        if ($tlane.ExePath -and (Test-Path -LiteralPath $tlane.ExePath)) {
            $tin = @(Get-WinModulesInTestBinary $tlane.ExePath)
        }
        $tfound = Get-TestReachFindings -WithTests $withTests -InBinary $tin
        $tmissing = @($tfound.Missing)
        Assert 'C2 the wounded tree is reported as missing provenance' `
            ($tmissing -contains 'provenance') ("named: " + ($tmissing -join ', '))
        # The whole subject of the bug: the LANE still passes. If dropping the
        # entry turned the lane red on its own, no sweep would be needed.
        Assert 'C3 the wounded tree still passes the lane (which is the defect)' `
            ($tlane.ExitCode -eq 0) "zig build test exited $($tlane.ExitCode)"
    } finally {
        [System.IO.File]::WriteAllText($listPath, $original)
        $restored = [System.IO.File]::ReadAllText($listPath)
        Assert 'C4 src\apprt\win32.zig is restored byte for byte' ($restored -eq $original)
    }
}

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard test-reach -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

''
Write-TestVerdict -Pass $script:passes -Fail $script:failures
