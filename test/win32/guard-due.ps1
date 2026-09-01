<#
.SYNOPSIS
  Acceptance test for scripts\guard-due.ps1 and its two wirings (T783).

.DESCRIPTION
  guard-due answers ONE question: has anybody run acceptance harness X against
  the code as it now stands? It is a CHANGE gate over a committed stamp, so the
  claims worth measuring are the ones a mtime- or "did this turn touch it"-based
  check would get wrong:

    * a covered file edited and edited BACK is not due (content, not events),
    * a file whose only difference is CRLF-vs-LF or a UTF-8 BOM is not due (a
      gate that fires on a differently-configured clone is a gate nobody reads),
    * a file the row does not cover moving does not make the row due (scope),
    * a covered file that APPEARED or VANISHED is due, not just one that changed.

  Every arm here runs against a fixture repo this script writes itself - the
  real scripts\guard-due.ps1 driven with -Repo <fixture> - so no arm depends on
  what the live tree's stamp happens to say today, and no arm has to dirty the
  real repo to make the gate fire.

  Sections D and E are the ones that matter most, because they measure FORCE
  rather than function: the same staleness must FAIL `parity-tasks.ps1 validate`
  (the pre-commit gate, which is where the remedy is the work this exists to
  cause) and must NOT fail `go-loop-exec.ps1 claim` (a claim that could exit
  nonzero over a stale stamp would wedge the loop, which is the disease and not
  the cure). Both directions are asserted; a gate that only ever reports, and a
  gate that can wedge the loop, are the two ways this feature fails.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Stop'

# isolation: none - every arm drives a fixture repo, and the one claim run uses
# where.exe as the ghoztty stand-in, so no CLI verb ever reaches a real
# endpoint; the +list mention below is commentary (T680 meta-check reads this).

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$Due = Join-Path $Repo 'scripts\guard-due.ps1'
$Tasks = Join-Path $Repo 'scripts\parity-tasks.ps1'
$Exec = Join-Path $Repo 'scripts\go-loop-exec.ps1'
$TaskDir = Join-Path $Repo 'docs\design\windows-parity-tasks'

$script:passes = 0
$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:failures++
    }
}

# --- the fixture repo ------------------------------------------------------
# A tree with the same SHAPE the go-loop row describes, so the row's globs are
# what is exercised rather than a bespoke test row: three scripts\go-loop-*.ps1,
# scripts\loop-session.ps1, the harness itself, and one script the row does not
# cover (the scope control). That control file has a SYNTHETIC name on purpose:
# it used to be `scripts\parity-tasks.ps1`, which was uncovered right up until
# T892 gave the tracker CLI a row of its own - and then three arms here failed
# over a table entry that had nothing to do with them. A name no row can ever
# claim keeps the scope control measuring scope.
$Fixture = Join-Path $env:TEMP ("ghoztty-guard-due-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

function New-Fixture {
    New-Item -ItemType Directory -Force -Path (Join-Path $Fixture 'scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Fixture 'test\win32') | Out-Null
    Set-FixtureFile 'scripts\go-loop-lock.ps1'    "# fake lock v1`n"
    Set-FixtureFile 'scripts\go-loop-exec.ps1'    "# fake exec v1`n"
    Set-FixtureFile 'scripts\go-loop-watchdog.ps1' "# fake watchdog v1`n"
    Set-FixtureFile 'scripts\loop-session.ps1'    "# fake loop-session v1`n"
    Set-FixtureFile 'scripts\uncovered-by-any-row.ps1' "# not covered by the go-loop row`n"
    Set-FixtureFile 'test\win32\go-loop-guard.ps1' "# fake harness v1`n"
}

function Set-FixtureFile([string]$rel, [string]$text) {
    # LF, no BOM, always - so an arm that deliberately writes CRLF or a BOM is
    # measuring that difference and not inheriting one.
    $p = Join-Path $Fixture $rel
    [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Due {
    param([string]$Action = 'check', [string]$Guard, [switch]$Json, [string]$AtRepo)
    $target = if ($AtRepo) { $AtRepo } else { $Fixture }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Due, $Action, '-Repo', $target)
    if ($Guard) { $a += @('-Guard', $Guard) }
    if ($Json) { $a += '-Json' }
    # T1039: `update` refuses to stamp while its caller's run is unfinished,
    # and this harness IS an unfinished run every time it drives one - against
    # a throwaway fixture repo, which is the case the gate is not about.
    if ($Action -eq 'update') { $a += '-IgnoreRunState' }
    $out = & powershell.exe @a 2>&1
    return [pscustomobject]@{ Lines = @($out); Exit = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

try {
    New-Fixture

    # --- A. the answer, over a stamp that does not exist yet ---------------
    Write-Host "`n-- A. no stamp --"
    $r = Invoke-Due list
    Check 'A1 list names the covered files' `
        ($r.Text -match 'scripts/go-loop-lock\.ps1' -and $r.Text -match 'scripts/loop-session\.ps1' `
            -and $r.Text -match 'test/win32/go-loop-guard\.ps1') $r.Text
    Check 'A2 list excludes a script the row does not cover' `
        ($r.Text -notmatch 'uncovered-by-any-row\.ps1') $r.Text

    $r = Invoke-Due check
    Check 'A3 with no stamp the guard is DUE' ($r.Text -match 'GUARD DUE go-loop') $r.Text
    Check 'A4 and says the harness has never recorded a run' ($r.Text -match 'never recorded') $r.Text
    Check 'A5 DUE exits 1' ($r.Exit -eq 1) "exit=$($r.Exit)"
    Check 'A6 and names the command that fixes it' `
        ($r.Text -match 'run: powershell -NoProfile -File test\\win32\\go-loop-guard\.ps1') $r.Text

    # --- B. stamping, and what a stamp does and does not survive -----------
    Write-Host "`n-- B. the stamp --"
    $r = Invoke-Due update
    Check 'B1 update stamps' ($r.Text -match 'STAMPED go-loop \(5 files\)') $r.Text
    Check 'B2 the stamp file is written' `
        (Test-Path -LiteralPath (Join-Path $Fixture 'test\win32\go-loop-guard.stamp.json')) ''

    $r = Invoke-Due check
    Check 'B3 a stamped tree is CURRENT' ($r.Text -match 'GUARD CURRENT go-loop \(5 files') $r.Text
    Check 'B4 CURRENT exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)"

    # A green harness run must leave a clean working tree behind it.
    $before = [System.IO.File]::ReadAllText((Join-Path $Fixture 'test\win32\go-loop-guard.stamp.json'))
    Start-Sleep -Milliseconds 1100   # a second boundary, so a rewritten `generated` would show
    $r = Invoke-Due update
    $after = [System.IO.File]::ReadAllText((Join-Path $Fixture 'test\win32\go-loop-guard.stamp.json'))
    Check 'B5 a second update over unchanged files rewrites nothing' `
        ($r.Text -match 'STAMP UNCHANGED' -and $before -eq $after) $r.Text

    Set-FixtureFile 'scripts\go-loop-lock.ps1' "# fake lock v2 - now with a timestamp prefix`n"
    $r = Invoke-Due check
    Check 'B6 an edited covered file is DUE' ($r.Text -match 'GUARD DUE go-loop') $r.Text
    Check 'B7 and is named, as changed' `
        ($r.Text -match 'changed\s+scripts/go-loop-lock\.ps1') $r.Text
    Check 'B8 DUE over a change exits 1' ($r.Exit -eq 1) "exit=$($r.Exit)"

    Set-FixtureFile 'scripts\go-loop-lock.ps1' "# fake lock v1`n"
    $r = Invoke-Due check
    Check 'B9 edited BACK is CURRENT again (content, not events)' `
        ($r.Text -match 'GUARD CURRENT' -and $r.Exit -eq 0) $r.Text

    # --- C. the three ways a covered file moves, and the two that must not --
    Write-Host "`n-- C. appear, vanish, and the non-differences --"
    Set-FixtureFile 'scripts\go-loop-newthing.ps1' "# a loop script added later`n"
    $r = Invoke-Due check
    Check 'C1 a NEW file matching the glob is DUE' `
        ($r.Text -match 'new\s+scripts/go-loop-newthing\.ps1' -and $r.Exit -eq 1) $r.Text
    Remove-Item -LiteralPath (Join-Path $Fixture 'scripts\go-loop-newthing.ps1') -Force

    Remove-Item -LiteralPath (Join-Path $Fixture 'scripts\go-loop-watchdog.ps1') -Force
    $r = Invoke-Due check
    Check 'C2 a REMOVED covered file is DUE' `
        ($r.Text -match 'removed\s+scripts/go-loop-watchdog\.ps1' -and $r.Exit -eq 1) $r.Text
    Set-FixtureFile 'scripts\go-loop-watchdog.ps1' "# fake watchdog v1`n"
    $r = Invoke-Due check
    Check 'C3 restoring it is CURRENT again' ($r.Exit -eq 0) $r.Text

    # The same bytes with Windows line endings. A raw hash reports this as a
    # change; every fresh clone with core.autocrlf=true is exactly this.
    $p = Join-Path $Fixture 'scripts\loop-session.ps1'
    [System.IO.File]::WriteAllText($p, "# fake loop-session v1`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Due check
    Check 'C4 CRLF instead of LF is not a change' ($r.Exit -eq 0) $r.Text

    [System.IO.File]::WriteAllText($p, "# fake loop-session v1`n", (New-Object System.Text.UTF8Encoding($true)))
    $r = Invoke-Due check
    Check 'C5 a UTF-8 BOM is not a change' ($r.Exit -eq 0) $r.Text
    Set-FixtureFile 'scripts\loop-session.ps1' "# fake loop-session v1`n"

    Set-FixtureFile 'scripts\uncovered-by-any-row.ps1' "# an uncovered script changed a lot`n"
    $r = Invoke-Due check
    Check 'C6 an uncovered file changing does not make the row due' ($r.Exit -eq 0) $r.Text

    # Scoped to the row this fixture is shaped like: the table has other rows,
    # whose files do not exist here, and "one row must still be an array" is the
    # claim -- which -Guard states exactly rather than by accident of the table
    # having a single entry.
    $r = Invoke-Due check -Json -Guard 'go-loop'
    $j = $null
    try { $j = ($r.Text | ConvertFrom-Json) } catch { }
    Check 'C7 -Json emits an ARRAY even for one row' `
        ($null -ne $j -and $j -is [array] -and $j.Count -eq 1) $r.Text
    Check 'C8 -Json reports the machine token' `
        ($null -ne $j -and $j[0].Kind -eq 'current' -and $j[0].Name -eq 'go-loop') $r.Text

    # A row that covers nothing in THIS tree is not applicable, not due. Every
    # other row in the real table is in that state against this fixture, and
    # before it existed each new row failed eight arms here over an exit code
    # that had nothing to do with them.
    $r = Invoke-Due check
    Check 'C10 a row covering nothing here is N/A, not DUE' `
        ($r.Exit -eq 0 -and $r.Text -match 'GUARD N/A') "exit=$($r.Exit): $($r.Text)"
    Check 'C11 and N/A is not silent (a typo''d row still says so)' `
        ($r.Text -notmatch 'GUARD CURRENT crash-first-chance') $r.Text

    $r = Invoke-Due check -Guard 'no-such-harness'
    Check 'C9 an unknown guard name is an error, not a pass' `
        ($r.Exit -eq 2 -and $r.Text -match 'unknown guard') "exit=$($r.Exit): $($r.Text)"

    # --- D. the teeth: parity-tasks.ps1 validate ---------------------------
    # Asserted on the GUARD's own lines rather than on validate's overall
    # verdict alone, so an unrelated tracker problem cannot make an arm here
    # pass or fail for the wrong reason.
    Write-Host "`n-- D. validate has teeth --"
    Set-FixtureFile 'scripts\go-loop-lock.ps1' "# fake lock v3 - stale again`n"

    function Invoke-Validate {
        param([string]$GuardRepo, [switch]$NoGuardDue, [string]$UseTaskDir)
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Tasks, 'validate')
        if ($NoGuardDue) { $a += '-NoGuardDue' }
        if ($UseTaskDir) { $a += @('-TaskDir', $UseTaskDir) }
        $old = $env:GHOZTTY_GUARD_DUE_REPO
        $env:GHOZTTY_GUARD_DUE_REPO = $GuardRepo
        try {
            $out = & powershell.exe @a 2>&1
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Text = (@($out) -join "`n") }
        } finally {
            if ($null -eq $old) { Remove-Item Env:\GHOZTTY_GUARD_DUE_REPO -ErrorAction SilentlyContinue }
            else { $env:GHOZTTY_GUARD_DUE_REPO = $old }
        }
    }

    $r = Invoke-Validate -GuardRepo $Fixture
    Check 'D1 validate FAILS while a harness is due' `
        ($r.Exit -ne 0 -and $r.Text -match 'GUARD DUE go-loop') "exit=$($r.Exit): $($r.Text)"
    Check 'D2 and says what to do about it' `
        ($r.Text -match 'run it, or fix what it catches, before committing') $r.Text

    $r = Invoke-Validate -GuardRepo $Fixture -NoGuardDue
    Check 'D3 -NoGuardDue does not fail over it' `
        ($r.Text -notmatch 'GUARD DUE go-loop') $r.Text
    Check 'D4 but says out loud that the check was skipped' `
        ($r.Text -match 'GUARD DUE CHECK SKIPPED') $r.Text

    $r = Invoke-Validate -GuardRepo $Fixture -UseTaskDir $TaskDir
    Check 'D5 a caller-named -TaskDir is a fixture run and is not gated' `
        ($r.Text -notmatch 'GUARD DUE') $r.Text

    Invoke-Due update | Out-Null
    $r = Invoke-Validate -GuardRepo $Fixture
    Check 'D6 a current stamp raises nothing in validate' `
        ($r.Text -notmatch 'GUARD DUE') $r.Text

    # --- E. and the loop's own claim must NOT be able to fail over it ------
    Write-Host "`n-- E. claim reports, never enforces --"
    Set-FixtureFile 'scripts\go-loop-lock.ps1' "# fake lock v4 - stale at claim time`n"
    # A fixture repo and a stand-in for ghoztty: the lock is a fresh file under
    # the fixture, `+list --json` answers nothing, so no window anywhere is
    # marked, messaged or closed. where.exe is the stand-in rather than a path
    # that does not exist, because Invoke-NativeExact reaches CreateProcess
    # directly and a missing image THROWS there; where.exe fails the way a
    # ghoztty that is not running does, which is the state being simulated.
    # The pane id is cleared out of the child's
    # ENVIRONMENT rather than passed as `-PaneId ''` - PS 5.1's -File parser
    # drops an empty-string argument and then reports the parameter as missing -
    # which keeps this session's own pane out of the claim entirely.
    $oldPane = $env:GHOZTTY_PANE_ID
    Remove-Item Env:\GHOZTTY_PANE_ID -ErrorAction SilentlyContinue
    try {
        $claimOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Exec claim `
            -Repo $Fixture -GhozttyExe (Join-Path $env:SystemRoot 'System32\where.exe') `
            -NoSelfClose -NoClose 2>&1
        $claimCode = $LASTEXITCODE
    } finally {
        if ($oldPane) { $env:GHOZTTY_PANE_ID = $oldPane }
    }
    $claimText = (@($claimOut) -join "`n")
    Check 'E1 claim reports the stale harness' ($claimText -match 'GUARD DUE go-loop') $claimText
    Check 'E2 claim still exits 0 (a stale stamp must never wedge the loop)' `
        ($claimCode -eq 0) "exit=$($claimCode): $claimText"

    # --- F. the harness only stamps a run that proved the whole harness ----
    # Source-level, deliberately: the alternative is a multi-minute GUI run per
    # arm, and what is being asserted is a policy written in one `if`.
    Write-Host "`n-- F. red and skipped runs do not stamp --"
    $guardSrc = [System.IO.File]::ReadAllText((Join-Path $Repo 'test\win32\go-loop-guard.ps1'))
    Check 'F1 the stamp is inside a failures-eq-0 branch' `
        ($guardSrc -match '(?s)if \(\$script:failures -eq 0\) \{.*?guard-due\.ps1') ''
    Check 'F2 a run with skipped sections does not stamp' `
        ($guardSrc -match '(?s)if \(\$script:skipped -gt 0\) \{\s*\r?\n\s*"\s*stamp NOT updated') ''

    # --- G. a harness with a Docker-gated section: three rows, three bars ---
    # T898. release-artifacts.ps1 stamped ONE row and only on a zero-skip run.
    # That bar is right for the payload sections and wrong for the workflow
    # files, and on a box where Docker is deliberately kept down it made the
    # row unclearable: an edit to fork-ci.yml stayed due forever, twelve turns
    # filed a duplicate task about it, and every commit in between went out
    # under `-NoGuardDue`. The claims below are the two halves of the split -
    # a wiring edit clears WITHOUT Docker, a payload edit still does not.
    Write-Host "`n-- G. the release rows: wiring clears without Docker, payload does not --"

    # G1-G3 read the LIVE table (not the fixture): which files each row claims
    # is the whole substance of the split, so it is asserted where it ships.
    $wiring = Invoke-Due list -Guard 'release-artifacts' -AtRepo $Repo
    $packaging = Invoke-Due list -Guard 'release-artifacts-packaging' -AtRepo $Repo
    $ziprow = Invoke-Due list -Guard 'release-artifacts-zip' -AtRepo $Repo
    Check 'G1 the wiring row covers the workflow files' `
        ($wiring.Text -match '\.github/workflows/fork-ci\.yml' -and
         $wiring.Text -match '\.github/workflows/release-windows\.yml') $wiring.Text
    Check 'G2 and does NOT cover the payload scripts' `
        ($wiring.Text -notmatch 'build-msi\.sh' -and $wiring.Text -notmatch 'build-portable-zip\.sh') $wiring.Text
    # T1052 split the payload row in two: the MSI needs Linux msitools (Docker
    # here), the portable ZIP needs only bash + python3 and is built for real on
    # any box. One row for both meant the ZIP could not be proved where the work
    # happens - and a ZIP that had shipped for months without ghoztty.com was
    # the cost.
    Check 'G3 the packaging row covers the MSI builder and only it' `
        ($packaging.Text -match 'build-msi\.sh' -and
         $packaging.Text -notmatch 'build-portable-zip\.sh' -and
         $packaging.Text -notmatch 'fork-ci\.yml') $packaging.Text
    Check 'G3b the ZIP row covers the ZIP builder and only it' `
        ($ziprow.Text -match 'build-portable-zip\.sh' -and
         $ziprow.Text -notmatch 'build-msi\.sh' -and
         $ziprow.Text -notmatch 'fork-ci\.yml') $ziprow.Text
    Check 'G3c and the ZIP row does not demand Docker to clear it' `
        ($ziprow.Text -notmatch '-RequireDocker') $ziprow.Text

    # G4-G7 measure the behaviour itself, over a fixture shaped like both rows.
    $RelFixture = Join-Path $env:TEMP ("ghoztty-guard-due-rel-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    function Set-RelFile([string]$rel, [string]$text) {
        $p = Join-Path $RelFixture $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    Set-RelFile '.github\workflows\release-windows.yml'          "# fake release workflow v1`n"
    Set-RelFile '.github\workflows\fork-ci.yml'                  "# fake CI workflow v1`n"
    Set-RelFile 'dist\windows-installer\build-release-artifacts.sh' "# fake shared artifact script v1`n"
    Set-RelFile 'dist\windows-installer\install-msitools.sh'     "# fake msitools install v1`n"
    Set-RelFile 'dist\windows-installer\build-msi.sh'            "# fake msi builder v1`n"
    Set-RelFile 'dist\windows-installer\build-portable-zip.sh'   "# fake zip builder v1`n"
    Set-RelFile 'scripts\publish-windows-release.ps1'            "# fake on-box publish v1`n"
    Set-RelFile 'test\win32\release-artifacts.ps1'               "# fake harness v1`n"

    Invoke-Due update -Guard 'release-artifacts' -AtRepo $RelFixture | Out-Null
    Invoke-Due update -Guard 'release-artifacts-packaging' -AtRepo $RelFixture | Out-Null

    # The wiring edit: what a Docker-less green run has to be able to clear.
    Set-RelFile '.github\workflows\fork-ci.yml' "# fake CI workflow v2 - a trigger changed`n"
    $rw = Invoke-Due check -Guard 'release-artifacts' -AtRepo $RelFixture
    $rp = Invoke-Due check -Guard 'release-artifacts-packaging' -AtRepo $RelFixture
    Check 'G4 a workflow edit makes the WIRING row due' `
        ($rw.Exit -eq 1 -and $rw.Text -match 'changed\s+\.github/workflows/fork-ci\.yml') $rw.Text
    Check 'G5 and leaves the packaging row alone (no Docker needed to clear it)' `
        ($rp.Exit -eq 0 -and $rp.Text -match 'GUARD CURRENT release-artifacts-packaging') $rp.Text
    Invoke-Due update -Guard 'release-artifacts' -AtRepo $RelFixture | Out-Null
    $rw = Invoke-Due check -Guard 'release-artifacts' -AtRepo $RelFixture
    Check 'G6 stamping the wiring row alone clears it' ($rw.Exit -eq 0) $rw.Text

    # The negative control: the zero-skip bar must survive the split, or a
    # Docker-less run ends up vouching for the MSI/ZIP payload.
    Set-RelFile 'dist\windows-installer\build-msi.sh' "# fake msi builder v2 - payload rule changed`n"
    $rp = Invoke-Due check -Guard 'release-artifacts-packaging' -AtRepo $RelFixture
    $rw = Invoke-Due check -Guard 'release-artifacts' -AtRepo $RelFixture
    Check 'G7 a payload edit makes the PACKAGING row due' `
        ($rp.Exit -eq 1 -and $rp.Text -match 'changed\s+dist/windows-installer/build-msi\.sh') $rp.Text
    Check 'G8 and does not touch the wiring row' ($rw.Exit -eq 0) $rw.Text
    Check 'G9 the packaging row asks for the run that can actually clear it' `
        ($rp.Text -match 'run: powershell -NoProfile -File test\\win32\\release-artifacts\.ps1 -RequireDocker') $rp.Text

    # G10-G11: the policy that decides which stamp a run earns. Source-level
    # for the same reason F1/F2 are - the alternative is a Docker-up run per arm.
    $relSrc = [System.IO.File]::ReadAllText((Join-Path $Repo 'test\win32\release-artifacts.ps1'))
    Check 'G10 the wiring stamp is reached with NO skip condition in the way' `
        ($relSrc -match '(?s)if \(\$script:failures -eq 0\) \{(?:(?!skipped).)*?-Guard release-artifacts -Repo') ''
    Check 'G11 the packaging stamp is behind a zero-skip condition' `
        ($relSrc -match '(?s)if \(\$script:skipped -eq 0\) \{(?:(?!-Guard).)*?-Guard release-artifacts-packaging') ''
    # G12: the ZIP stamp is earned by having BUILT a ZIP, not by the run merely
    # reaching the end. A skipped ZIP half that stamped anyway would be the same
    # lie as a Docker-less run vouching for the MSI (T1052).
    Check 'G12 the ZIP stamp is behind having actually built a ZIP' `
        ($relSrc -match '(?s)if \(\$builtZip\) \{(?:(?!-Guard).)*?-Guard release-artifacts-zip') ''

    # H: every row must be CLEARABLE. A row whose harness never calls
    # `guard-due update` goes due the moment anything it covers moves and stays
    # due through every green run of the thing it watches - a permanent red that
    # trains the next turn to pass -NoGuardDue, which is the one outcome T783
    # exists to prevent. agent-adopt shipped in exactly that state and was found
    # by hand while working T1042; this is the check that finds the next one.
    "== H: every guard row's harness can actually clear it"
    $rowScripts = @()
    foreach ($line in (Invoke-Due list -AtRepo $Repo).Text -split "`r?`n") {
        if ($line -match '(test\\win32\\[A-Za-z0-9._-]+\.ps1)') { $rowScripts += $matches[1] }
    }
    Check 'H1 the table lists harnesses at all (the parse found rows)' ($rowScripts.Count -ge 40) `
        "found $($rowScripts.Count)"
    $noStamp = @()
    foreach ($rel in ($rowScripts | Sort-Object -Unique)) {
        $abs = Join-Path $Repo $rel
        if (-not (Test-Path $abs)) { $noStamp += "$rel (missing)"; continue }
        if (-not (Select-String -Path $abs -Pattern 'guard-due' -Quiet)) { $noStamp += $rel }
    }
    Check 'H2 every row names a harness that exists and stamps itself' ($noStamp.Count -eq 0) `
        ($noStamp -join ', ')

    # --- J. what `from <sha>` on a CURRENT line actually means --------------
    # T1164. The gate compares content and only content, so a green run over
    # uncommitted work is a correct stamp - but it records the HEAD it was taken
    # at, which is a commit that does not contain the stamped content. On
    # 2026-08-23 that produced `stamped 2026-08-23 from 820193367` over the tree
    # committed seven minutes later as 9d445b377, and a turn read the line as
    # the gate having let a changed file through and opened a question about it.
    # The claim here is that the line now distinguishes the two cases itself.
    Write-Host "`n-- J. a stamp taken over uncommitted work says so --"
    $ProvFixture = Join-Path $env:TEMP ("ghoztty-guard-due-prov-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    function Set-ProvFile([string]$rel, [string]$text) {
        $p = Join-Path $ProvFixture $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        [System.IO.File]::WriteAllText($p, ($text -replace "`r`n", "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    Set-ProvFile 'scripts\go-loop-lock.ps1'     "# fake lock v1`n"
    Set-ProvFile 'scripts\go-loop-exec.ps1'     "# fake exec v1`n"
    Set-ProvFile 'scripts\go-loop-watchdog.ps1' "# fake watchdog v1`n"
    Set-ProvFile 'scripts\loop-session.ps1'     "# fake loop-session v1`n"
    Set-ProvFile 'test\win32\go-loop-guard.ps1' "# fake harness v1`n"
    # A real git repo, because the question is literally "was this committed".
    & git -C $ProvFixture init -q 2>$null | Out-Null
    & git -C $ProvFixture config user.email 'harness@example.invalid' 2>$null | Out-Null
    & git -C $ProvFixture config user.name 'guard-due harness' 2>$null | Out-Null
    # No autocrlf translation: a warning on stderr from a native command is an
    # ErrorRecord under `$ErrorActionPreference = 'Stop'`, and this fixture's
    # files are written LF on purpose.
    & git -C $ProvFixture config core.autocrlf false 2>$null | Out-Null
    & git -C $ProvFixture add -A 2>$null | Out-Null
    & git -C $ProvFixture -c commit.gpgsign=false commit -q -m 'fixture v1' 2>$null | Out-Null
    $gitOk = (& git -C $ProvFixture rev-parse --short HEAD 2>$null | Out-String).Trim()
    Check 'J1 the fixture is a real repo with a commit (positive control)' ($gitOk -ne '') "head '$gitOk'"

    Invoke-Due update -Guard 'go-loop' -AtRepo $ProvFixture | Out-Null
    $rj = Invoke-Due check -Guard 'go-loop' -AtRepo $ProvFixture
    Check 'J2 a stamp taken over a clean tree names its commit and nothing more' `
        ($rj.Text -match "GUARD CURRENT go-loop \(5 files, stamped \d{4}-\d{2}-\d{2} from $gitOk\)") $rj.Text
    Check 'J3 and does not claim uncommitted work it did not see' `
        ($rj.Text -notmatch 'uncommitted') $rj.Text

    # Now the 2026-08-23 shape: the harness goes green over an edit that has not
    # been committed yet, so the stamp holds content this HEAD does not.
    Set-ProvFile 'scripts\go-loop-lock.ps1' "# fake lock v2 - green, not yet committed`n"
    Invoke-Due update -Guard 'go-loop' -AtRepo $ProvFixture | Out-Null
    $rj = Invoke-Due check -Guard 'go-loop' -AtRepo $ProvFixture
    Check 'J4 the tree is still CURRENT (content is what the gate compares)' `
        ($rj.Exit -eq 0 -and $rj.Text -match 'GUARD CURRENT go-loop') $rj.Text
    Check 'J5 and the line says the stamp was taken over uncommitted work' `
        ($rj.Text -match "from $gitOk \+1 uncommitted") $rj.Text
    $provStamp = Get-Content -LiteralPath (Join-Path $ProvFixture 'test\win32\go-loop-guard.stamp.json') -Raw | ConvertFrom-Json
    Check 'J6 and the stamp names which file it was' `
        (@($provStamp.uncommitted) -contains 'scripts/go-loop-lock.ps1') `
        (@($provStamp.uncommitted) -join ', ')

    # Committing it does not change the verdict - it changes the sentence.
    & git -C $ProvFixture add -A 2>$null | Out-Null
    & git -C $ProvFixture -c commit.gpgsign=false commit -q -m 'fixture v2' 2>$null | Out-Null
    Set-ProvFile 'scripts\go-loop-exec.ps1' "# fake exec v2`n"
    & git -C $ProvFixture add -A 2>$null | Out-Null
    & git -C $ProvFixture -c commit.gpgsign=false commit -q -m 'fixture v3' 2>$null | Out-Null
    $head3 = (& git -C $ProvFixture rev-parse --short HEAD 2>$null | Out-String).Trim()
    Invoke-Due update -Guard 'go-loop' -AtRepo $ProvFixture | Out-Null
    $rj = Invoke-Due check -Guard 'go-loop' -AtRepo $ProvFixture
    Check 'J7 a stamp taken after the commit drops the qualifier again' `
        ($rj.Text -match 'GUARD CURRENT go-loop' -and $rj.Text -notmatch 'uncommitted') $rj.Text
    Check 'J8 and names the commit that does hold the stamped content' `
        ($rj.Text -match "from $head3\b") $rj.Text

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
    if ($RelFixture) { Remove-Item -LiteralPath $RelFixture -Recurse -Force -ErrorAction SilentlyContinue }
    if ($ProvFixture) { Remove-Item -LiteralPath $ProvFixture -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 32
