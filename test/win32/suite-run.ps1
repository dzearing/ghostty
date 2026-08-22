<#
.SYNOPSIS
  Acceptance for scripts\suite-run.ps1 - the win32 acceptance-suite runner
  (tracker T361).

.DESCRIPTION
  The runner's whole value is that a human can trust its table without opening
  241 logs, so every claim it makes is measured here against a FIXTURE suite
  whose right answers are known by construction: a script that passes, one that
  fails, one that asserts nothing, one that exits 0 with no verdict at all, one
  that crashes with an odd code, and one that hangs.

  Sections:
    A. Enumeration - top-level only, gui/cli classification, lib\ and
       artifacts\ never enumerated.
    B. Scoring - the five verdict kinds, and the runner's own exit code.
    C. Timeout - a hanging script is killed and scored `stall`, and the suite
       CARRIES ON. One hang must never cost the other 240 scripts.
    D. Order - forward, reverse, an explicit list, and a typo in that list
       failing loudly instead of silently running fewer scripts.
    E. Incremental summary - a run killed part way through still leaves the
       rows it already bought. A suite measured in hours will be killed.
    F. Resume - recorded scripts are not re-run, measured by counting real
       invocations rather than by reading the runner's own report.
    G. Compare - identical verdict sets are STABLE at exit 0; one differing
       script is named and exits 1. This is what discharges an
       order-independence claim.
    H. -Include / -Exclude survive `powershell -File` argument parsing, where a
       comma-separated list binds as ONE literal string.
    I. The between-script leak sweep is repo-scoped: it kills a process running
       out of the given repo's zig-out and leaves everything else alone.
    J. The duration in the report is the duration that was measured.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Stop'

# isolation: none - every arm drives a FIXTURE repo whose scripts are echo
# statements. No ghoztty CLI verb is ever run, and the one process this launches
# is a copy of cmd.exe under the fixture's own zig-out.
#
# preflight: none - section I launches `<fixture>\zig-outin\ghoztty.exe`,
# which is a COPY OF cmd.exe standing in for a leaked app so the sweep has
# something real to kill. There is no ghoztty build behind that path for
# `Assert-GhozttyIsolatedBuild` to vouch for, and the gate's whole subject -
# whether this run could reach the user's installed release - cannot arise: the
# path is under a throwaway %TEMP% fixture, and the sweep under test is given
# that same fixture as its repo root.

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$Runner = Join-Path $Repo 'scripts\suite-run.ps1'

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

# --- the fixture suite -----------------------------------------------------

$Fixture = Join-Path $env:TEMP ("ghoztty-suite-run-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$FixTests = Join-Path $Fixture 'test\win32'
$RunLog = Join-Path $Fixture 'invocations.txt'

function Set-FixtureScript {
    param([string]$Name, [string]$Body)
    $path = Join-Path $FixTests $Name
    # Every fixture script records that it really ran, so section F can count
    # invocations instead of believing the runner's own "(from resume)" line.
    $preamble = "Add-Content -LiteralPath '$RunLog' -Value '$Name'`n"
    Set-Content -LiteralPath $path -Value ($preamble + $Body) -Encoding ASCII
}

function New-Fixture {
    New-Item -ItemType Directory -Force -Path $FixTests | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $FixTests 'lib') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $FixTests 'artifacts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Fixture 'zig-out\bin') | Out-Null
    Set-Content -LiteralPath $RunLog -Value '' -Encoding ASCII

    # One GUI script: the classifier's whole test is the New-TestDesktop call.
    Set-FixtureScript 'a-gui.ps1' @'
"  driving a window"
$null = "New-TestDesktop"
"ALL PASS (3 assertions)"
exit 0
'@
    Set-FixtureScript 'b-pass.ps1' @'
"ALL PASS (7 assertions)"
exit 0
'@
    Set-FixtureScript 'c-fail.ps1' @'
"  FAIL something"
"2 FAILURE(S) (5 passed)"
exit 1
'@
    Set-FixtureScript 'd-nothing.ps1' @'
"ASSERTED NOTHING (0 assertions, 1 skipped)"
exit 2
'@
    Set-FixtureScript 'e-silent.ps1' @'
"nothing to see here"
exit 0
'@
    Set-FixtureScript 'f-crash.ps1' @'
"about to die"
exit 7
'@
    Set-FixtureScript 'g-hang.ps1' @'
Start-Sleep -Seconds 90
"ALL PASS (1 assertions)"
exit 0
'@

    # Neither of these is an acceptance script, and neither may be enumerated:
    # lib\ is dot-sourced libraries, artifacts\ is fixtures.
    Set-Content -LiteralPath (Join-Path $FixTests 'lib\Helper.ps1') `
        -Value "function New-TestDesktop { }`n" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $FixTests 'artifacts\thing.ps1') `
        -Value "'ALL PASS (1)'`nexit 0`n" -Encoding ASCII
}

function Invoke-Runner {
    param([string[]]$Arguments)
    $out = Join-Path $Fixture ('runner-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner, '-Repo', $Fixture) + $Arguments
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle   # T197: read the handle BEFORE the wait or ExitCode is empty
    $null = $p.WaitForExit(240000)
    $p.WaitForExit()
    $text = ''
    if (Test-Path -LiteralPath $out) { $text = (Get-Content -LiteralPath $out -Raw) }
    if ($null -eq $text) { $text = '' }
    # A refusal (a typo in -Order, a one-run compare) arrives on STDERR, and a
    # check that only reads stdout would score the refusal as silence.
    if (Test-Path -LiteralPath "$out.err") {
        $errText = Get-Content -LiteralPath "$out.err" -Raw
        if ($errText) { $text = $text + "`n" + $errText }
    }
    return [pscustomobject]@{ Exit = $p.ExitCode; Text = $text; Path = $out }
}

function Get-Summary {
    param([string]$Dir)
    $p = Join-Path $Dir 'summary.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-Verdict {
    param($Summary, [string]$Name)
    if (-not $Summary) { return '(no summary)' }
    $hit = @($Summary.results | Where-Object { $_.Name -eq $Name })
    if ($hit.Count -eq 0) { return '(absent)' }
    return $hit[0].Verdict
}

function Get-InvocationCount {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $RunLog)) { return 0 }
    return @(Get-Content -LiteralPath $RunLog | Where-Object { $_ -eq $Name }).Count
}

New-Fixture

try {
    # --- A. enumeration ----------------------------------------------------
    Write-Host ''
    Write-Host '-- A. enumeration'

    $r = Invoke-Runner @('list')
    Check 'A1 list exits 0' ($r.Exit -eq 0) "exit $($r.Exit)"
    Check 'A2 list finds the 7 top-level scripts' ($r.Text -match '7 scripts selected') $r.Text
    Check 'A3 list classifies one of them gui' ($r.Text -match '1 gui, 6 cli') $r.Text
    Check 'A4 lib\ is not enumerated' ($r.Text -notmatch 'Helper\.ps1') ''
    # Anchored: an unanchored 'thing\.ps1' also matches d-noTHING.ps1, which is
    # supposed to be there - the check would have passed a real leak of the
    # artifacts directory and failed a correct run instead.
    Check 'A5 artifacts\ is not enumerated' ($r.Text -notmatch '(?m)^\s*\w+\s+thing\.ps1\s*$') ''

    $r = Invoke-Runner @('list', '-Set', 'gui')
    Check 'A6 -Set gui selects only the window-driving script' `
        (($r.Text -match 'a-gui\.ps1') -and ($r.Text -match '1 scripts selected')) $r.Text

    # --- B. scoring --------------------------------------------------------
    Write-Host ''
    Write-Host '-- B. verdict scoring'

    $dirB = Join-Path $Fixture 'runB'
    $r = Invoke-Runner @('-Exclude', 'g-hang.ps1', '-OutDir', $dirB, '-TimeoutSec', '30')
    $sB = Get-Summary $dirB
    Check 'B1 a passing script scores pass' ((Get-Verdict $sB 'b-pass.ps1') -eq 'pass') (Get-Verdict $sB 'b-pass.ps1')
    Check 'B2 a failing script scores fail' ((Get-Verdict $sB 'c-fail.ps1') -eq 'fail') (Get-Verdict $sB 'c-fail.ps1')
    Check 'B3 exit 2 scores asserted-nothing' ((Get-Verdict $sB 'd-nothing.ps1') -eq 'nothing') (Get-Verdict $sB 'd-nothing.ps1')
    # The T221 shape: exit 0 with no verdict line is NOT a pass. A runner that
    # scored it green would launder exactly the defect that audit exists for.
    Check 'B4 exit 0 with no verdict is not a pass' ((Get-Verdict $sB 'e-silent.ps1') -eq 'error') (Get-Verdict $sB 'e-silent.ps1')
    Check 'B5 an odd exit code scores error' ((Get-Verdict $sB 'f-crash.ps1') -eq 'error') (Get-Verdict $sB 'f-crash.ps1')
    Check 'B6 the verdict LINE is carried, not just the kind' `
        ((@($sB.results | Where-Object { $_.Name -eq 'c-fail.ps1' })[0].Line) -match '2 FAILURE\(S\)') ''
    Check 'B7 a red suite exits nonzero' ($r.Exit -ne 0) "exit $($r.Exit)"
    Check 'B8 the summary counts every selected script' (@($sB.results).Count -eq 6) "$(@($sB.results).Count) rows"
    Check 'B9 per-script seconds are recorded' `
        ((@($sB.results | Where-Object { $_.Seconds -ge 0 }).Count) -eq 6) ''

    $dirB2 = Join-Path $Fixture 'runB2'
    $r = Invoke-Runner @('-Include', 'a-gui.ps1,b-pass.ps1', '-OutDir', $dirB2, '-TimeoutSec', '30')
    Check 'B10 an all-green suite exits 0 and says so' `
        (($r.Exit -eq 0) -and ($r.Text -match 'SUITE ALL PASS \(2 scripts')) "exit $($r.Exit)"

    # Selecting exactly ONE script is the shape that broke: PS 5.1 unrolls a
    # one-element array on return, and a scalar's .Count is $null - so the
    # progress line printed "[  1/]" and the verdict "(  scripts)".
    $dirB3 = Join-Path $Fixture 'runB3'
    $r = Invoke-Runner @('-Include', 'b-pass.ps1', '-OutDir', $dirB3, '-TimeoutSec', '30')
    Check 'B11 a one-script run still counts to one' `
        (($r.Text -match 'SUITE ALL PASS \(1 scripts') -and ($r.Text -match '\[\s*1/1\]')) $r.Text

    # --- C. timeout --------------------------------------------------------
    Write-Host ''
    Write-Host '-- C. timeout'

    $dirC = Join-Path $Fixture 'runC'
    $r = Invoke-Runner @('-Order', 'g-hang.ps1,b-pass.ps1', '-OutDir', $dirC, '-TimeoutSec', '5')
    $sC = Get-Summary $dirC
    Check 'C1 a hanging script is scored stall' ((Get-Verdict $sC 'g-hang.ps1') -eq 'stall') (Get-Verdict $sC 'g-hang.ps1')
    Check 'C2 it is killed at the timeout, not waited out' `
        ((@($sC.results | Where-Object { $_.Name -eq 'g-hang.ps1' })[0].Seconds) -lt 30) ''
    Check 'C3 the suite carries on past a hang' ((Get-Verdict $sC 'b-pass.ps1') -eq 'pass') (Get-Verdict $sC 'b-pass.ps1')
    Check 'C4 the hung process is really gone' `
        (@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -like '*g-hang.ps1*' }).Count -eq 0) ''

    # --- D. order ----------------------------------------------------------
    Write-Host ''
    Write-Host '-- D. order'

    $dirD1 = Join-Path $Fixture 'runD1'
    $null = Invoke-Runner @('-Include', 'a-gui.ps1,b-pass.ps1,c-fail.ps1', '-OutDir', $dirD1, '-TimeoutSec', '30')
    $sD1 = Get-Summary $dirD1
    $fwd = @($sD1.results | Sort-Object Index | ForEach-Object { $_.Name })
    Check 'D1 forward is alphabetical' (($fwd -join ',') -eq 'a-gui.ps1,b-pass.ps1,c-fail.ps1') ($fwd -join ',')

    $dirD2 = Join-Path $Fixture 'runD2'
    $null = Invoke-Runner @('-Include', 'a-gui.ps1,b-pass.ps1,c-fail.ps1', '-Order', 'reverse', '-OutDir', $dirD2, '-TimeoutSec', '30')
    $sD2 = Get-Summary $dirD2
    $rev = @($sD2.results | Sort-Object Index | ForEach-Object { $_.Name })
    Check 'D2 reverse is the forward list backwards' (($rev -join ',') -eq 'c-fail.ps1,b-pass.ps1,a-gui.ps1') ($rev -join ',')

    $dirD3 = Join-Path $Fixture 'runD3'
    $null = Invoke-Runner @('-Order', 'c-fail.ps1,a-gui.ps1', '-OutDir', $dirD3, '-TimeoutSec', '30')
    $sD3 = Get-Summary $dirD3
    $lst = @($sD3.results | Sort-Object Index | ForEach-Object { $_.Name })
    Check 'D3 an explicit list runs exactly it, in that order' (($lst -join ',') -eq 'c-fail.ps1,a-gui.ps1') ($lst -join ',')

    $r = Invoke-Runner @('-Order', 'b-pass.ps1,nosuch.ps1', '-OutDir', (Join-Path $Fixture 'runD4'), '-TimeoutSec', '30')
    Check 'D4 a typo in the list fails loudly, it does not run fewer scripts' `
        (($r.Exit -ne 0) -and ($r.Text -match 'nosuch')) "exit $($r.Exit)"

    # --- E. incremental summary -------------------------------------------
    Write-Host ''
    Write-Host '-- E. incremental summary'

    $dirE = Join-Path $Fixture 'runE'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner, '-Repo', $Fixture,
        '-Order', 'b-pass.ps1,g-hang.ps1', '-OutDir', $dirE, '-TimeoutSec', '120')
    $pe = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $Fixture 'runE.log') -RedirectStandardError (Join-Path $Fixture 'runE.err')
    $null = $pe.Handle
    $deadline = (Get-Date).AddSeconds(60)
    $mid = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $mid = Get-Summary $dirE
        if ($mid -and @($mid.results).Count -ge 1) { break }
    }
    try { & taskkill.exe /T /F /PID $pe.Id *> $null } catch { }
    try { $null = $pe.WaitForExit(10000) } catch { }
    Check 'E1 the first row is on disk while the suite is still running' `
        ($mid -and (@($mid.results).Count -ge 1)) "rows: $(@($mid.results).Count)"
    Check 'E2 that row is the completed script, scored' `
        ($mid -and ((Get-Verdict $mid 'b-pass.ps1') -eq 'pass')) (Get-Verdict $mid 'b-pass.ps1')
    # A killed runner leaves the child behind unless something reaps it; the
    # next run's sweep is that something, but the hang must not survive HERE
    # into the following sections.
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*g-hang.ps1*' }) |
        ForEach-Object { try { & taskkill.exe /T /F /PID $_.ProcessId *> $null } catch { } }

    # --- F. resume ---------------------------------------------------------
    Write-Host ''
    Write-Host '-- F. resume'

    $dirF = Join-Path $Fixture 'runF'
    $null = Invoke-Runner @('-Include', 'b-pass.ps1', '-OutDir', $dirF, '-TimeoutSec', '30')
    $beforeB = Get-InvocationCount 'b-pass.ps1'
    $beforeC = Get-InvocationCount 'c-fail.ps1'
    $r = Invoke-Runner @('-Include', 'b-pass.ps1,c-fail.ps1', '-Resume', (Join-Path $dirF 'summary.json'), '-TimeoutSec', '30')
    $afterB = Get-InvocationCount 'b-pass.ps1'
    $afterC = Get-InvocationCount 'c-fail.ps1'
    Check 'F1 a recorded script is NOT run again' ($afterB -eq $beforeB) "$beforeB -> $afterB"
    Check 'F2 the unrecorded one IS run' ($afterC -eq $beforeC + 1) "$beforeC -> $afterC"
    $sF = Get-Summary $dirF
    Check 'F3 the resumed summary carries both rows' (@($sF.results).Count -eq 2) "$(@($sF.results).Count) rows"
    Check 'F4 the resumed run keeps the earlier verdict' ((Get-Verdict $sF 'b-pass.ps1') -eq 'pass') (Get-Verdict $sF 'b-pass.ps1')

    # --- G. compare --------------------------------------------------------
    Write-Host ''
    Write-Host '-- G. compare'

    $r = Invoke-Runner @('compare', '-Runs', "$dirD1\summary.json,$dirD2\summary.json")
    Check 'G1 the same verdicts in two orders compare STABLE' `
        (($r.Exit -eq 0) -and ($r.Text -match 'SUITE COMPARE STABLE')) "exit $($r.Exit): $($r.Text)"

    # Now make one script differ, exactly as a script that reads its
    # neighbour's leftovers would, and require the comparison to catch it.
    $dirG = Join-Path $Fixture 'runG'
    $null = Invoke-Runner @('-Include', 'a-gui.ps1,b-pass.ps1,c-fail.ps1', '-OutDir', $dirG, '-TimeoutSec', '30')
    $gJson = Join-Path $dirG 'summary.json'
    $raw = Get-Content -LiteralPath $gJson -Raw
    $raw = $raw.Replace('"Verdict":  "fail"', '"Verdict":  "pass"').Replace('"Verdict": "fail"', '"Verdict": "pass"')
    Set-Content -LiteralPath $gJson -Value $raw -Encoding UTF8
    $r = Invoke-Runner @('compare', '-Runs', "$dirD1\summary.json,$gJson")
    Check 'G2 one differing script is caught and named' `
        (($r.Exit -eq 1) -and ($r.Text -match 'DIFFER\s+c-fail\.ps1')) "exit $($r.Exit): $($r.Text)"
    Check 'G3 compare refuses a single run' `
        ((Invoke-Runner @('compare', '-Runs', "$dirD1\summary.json")).Exit -ne 0) ''

    # --- H. argv fidelity --------------------------------------------------
    Write-Host ''
    Write-Host '-- H. -Include / -Exclude under `powershell -File`'

    # The trap this measures: `-File` parses arguments as LITERAL text, so a
    # comma-separated value binds to a [string[]] parameter as the single
    # string "a,b" and the second pattern is silently dropped - a suite that
    # quietly runs half of what was asked for.
    $dirH = Join-Path $Fixture 'runH'
    $null = Invoke-Runner @('-Include', 'b-pass.ps1,d-nothing.ps1', '-OutDir', $dirH, '-TimeoutSec', '30')
    $sH = Get-Summary $dirH
    Check 'H1 both -Include patterns are honored' (@($sH.results).Count -eq 2) "$(@($sH.results).Count) rows"

    $dirH2 = Join-Path $Fixture 'runH2'
    $null = Invoke-Runner @('-Exclude', 'g-hang.ps1,f-crash.ps1,e-silent.ps1', '-OutDir', $dirH2, '-TimeoutSec', '30')
    $sH2 = Get-Summary $dirH2
    Check 'H2 all three -Exclude patterns are honored' (@($sH2.results).Count -eq 4) "$(@($sH2.results).Count) rows"

    # --- I. leak sweep scope ----------------------------------------------
    Write-Host ''
    Write-Host '-- I. leak sweep'

    # A copy of cmd.exe standing in for a leaked app, plus a control copy
    # OUTSIDE zig-out. The sweep must take the first and never the second: it
    # is the same repo-scoped, path-exact rule lib\CleanSlate.ps1 uses, and the
    # reason a mistyped path can never reach the user's installed Ghoztty.
    $leakExe = Join-Path $Fixture 'zig-out\bin\ghoztty.exe'
    $ctrlDir = Join-Path $Fixture 'control\bin'
    New-Item -ItemType Directory -Force -Path $ctrlDir | Out-Null
    $ctrlExe = Join-Path $ctrlDir 'ghoztty.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $leakExe -Force
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $ctrlExe -Force

    $leakProc = Start-Process -FilePath $leakExe -ArgumentList '/c', 'ping -n 120 127.0.0.1 > nul' -PassThru -WindowStyle Hidden
    $null = $leakProc.Handle
    $ctrlProc = Start-Process -FilePath $ctrlExe -ArgumentList '/c', 'ping -n 120 127.0.0.1 > nul' -PassThru -WindowStyle Hidden
    $null = $ctrlProc.Handle
    Start-Sleep -Milliseconds 700

    $dirI = Join-Path $Fixture 'runI'
    $null = Invoke-Runner @('-Include', 'b-pass.ps1', '-OutDir', $dirI, '-TimeoutSec', '30')
    Start-Sleep -Milliseconds 700

    $leakAlive = $null -ne (Get-Process -Id $leakProc.Id -ErrorAction SilentlyContinue)
    $ctrlAlive = $null -ne (Get-Process -Id $ctrlProc.Id -ErrorAction SilentlyContinue)
    Check 'I1 a process running out of the repo zig-out is swept' (-not $leakAlive) ''
    Check 'I2 a process outside zig-out is left alone' $ctrlAlive ''
    $sI = Get-Summary $dirI
    Check 'I3 the sweep is reported per script' `
        ((@($sI.results | Where-Object { $_.Name -eq 'b-pass.ps1' })[0].Leaked) -ge 1) ''

    $dirI2 = Join-Path $Fixture 'runI2'
    $leak2 = Start-Process -FilePath $leakExe -ArgumentList '/c', 'ping -n 120 127.0.0.1 > nul' -PassThru -WindowStyle Hidden
    $null = $leak2.Handle
    Start-Sleep -Milliseconds 700
    $null = Invoke-Runner @('-Include', 'b-pass.ps1', '-OutDir', $dirI2, '-TimeoutSec', '30', '-NoSweep')
    Start-Sleep -Milliseconds 500
    Check 'I4 -NoSweep really leaves it running' `
        ($null -ne (Get-Process -Id $leak2.Id -ErrorAction SilentlyContinue)) ''

    foreach ($p in @($leakProc, $ctrlProc, $leak2)) {
        try { & taskkill.exe /T /F /PID $p.Id *> $null } catch { }
    }

    # --- J. the duration in the report ------------------------------------
    Write-Host ''
    Write-Host '-- J. Format-Duration'

    # The one number in the report nobody can check by eye. Its first version
    # used `[int]$ts.TotalMinutes`, and .NET converts double to int by
    # ROUNDING - so a 116.2-second script was reported as "2m 56s" beside a
    # recorded 116.2 in the same summary.json.
    . (Join-Path $Repo 'scripts\lib\Duration.ps1')
    Check 'J1 under a minute keeps a decimal' ((Format-Duration 5.25) -eq '5.3s') (Format-Duration 5.25)
    Check 'J2 minutes TRUNCATE, they do not round up' ((Format-Duration 116.2) -eq '1m 56s') (Format-Duration 116.2)
    Check 'J3 exactly a minute' ((Format-Duration 60) -eq '1m 00s') (Format-Duration 60)
    Check 'J4 hours truncate too' ((Format-Duration 3596) -eq '59m 56s') (Format-Duration 3596)
    Check 'J5 an hours value reads as hours' ((Format-Duration 7325) -eq '2h 02m 05s') (Format-Duration 7325)

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$Fixture*" } |
        ForEach-Object { try { & taskkill.exe /T /F /PID $_.ProcessId *> $null } catch { } }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) {
    # A clean green run records the covered files so scripts\guard-due.ps1 can
    # answer "has anyone run this harness against the code as it now stands?"
    # (T783). Red runs leave the stamp alone - red must stay due.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard suite-run -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 34
