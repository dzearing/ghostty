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
    N. Per-script declared timeout - a script that declares `# suite-timeout-sec`
       is measured against ITS number, an undeclared one against the run's, a
       garbled one falls back rather than becoming unbounded, and -MaxTimeoutSec
       bounds every declaration for a deliberately quick pass.
    O. The line the report quotes is the last thing the script said on STDOUT,
       not the stderr that is folded in after it.
    P. The confirm pass - every non-pass script is re-run once on its own, and
       what the second run said is recorded on the row. A red row that is green
       alone is a harness defect, not a broken feature (T1137).
    S. Whole-script SKIP - a script the BOX cannot answer (no composited pixels
       on a background desktop, no SendInput off the input desktop) is scored
       apart from both pass and fail, counted apart, listed by name, and not
       re-run by the confirm pass (T1100).

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
# preflight: none - section I launches `<fixture>\zig-out\bin\ghoztty.exe`,
# which is a COPY OF cmd.exe standing in for a leaked app so the sweep has
# something real to kill. There is no ghoztty build behind that path for
# `Assert-GhozttyIsolatedBuild` to vouch for, and the gate's whole subject -
# whether this run could reach the user's installed release - cannot arise: the
# path is under a throwaway %TEMP% fixture, and the sweep under test is given
# that same fixture as its repo root.

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# Section M asks the same question the runner asks: is a dialog still on screen?
. (Join-Path $PSScriptRoot 'lib\ModalSweep.ps1')

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
    # TWICE: once in the sweep, and once more by the confirm pass, which re-runs
    # a red row alone to tell a broken feature from a broken test (T1137). The
    # resumed row beside it is red too and is NOT re-run - it already carries
    # that answer from the run being resumed.
    Check 'F2 the unrecorded one IS run' ($afterC -eq $beforeC + 2) "$beforeC -> $afterC"
    $beforeC2 = Get-InvocationCount 'c-fail.ps1'
    $null = Invoke-Runner @('-Include', 'b-pass.ps1,c-fail.ps1', '-Resume', (Join-Path $dirF 'summary.json'), '-TimeoutSec', '30')
    Check 'F5 a row that already has an alone verdict is not re-confirmed' `
        ((Get-InvocationCount 'c-fail.ps1') -eq $beforeC2) "$beforeC2 -> $(Get-InvocationCount 'c-fail.ps1')"

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

    # --- M. stray modal sweep (T1098) --------------------------------------
    Write-Host ''
    Write-Host '-- M. stray modal dialogs'

    # The failure this is for: on 2026-08-22 `upgrade-staleness.ps1` raised a
    # system-modal `Unsupported 16-Bit Application` box on the USER's desktop and
    # scored ALL PASS (123 assertions). A modal is invisible to every verdict the
    # runner computes - it is not a failed assertion and not a nonzero exit - and
    # it BLOCKS whoever raised it until a human clicks OK, in a sweep that is
    # meant to run unattended.
    #
    # The fixture script raises one from a DETACHED process and exits 0 with a
    # clean ALL PASS, which is exactly the shape that scored green: the dialog
    # outlives the script that raised it.
    #
    # It WAITS for its own dialog to be on screen before exiting, rather than
    # sleeping a fixed three seconds and hoping (T1164). The sweep runs after the
    # script exits, so a box slow enough that WinForms had not finished painting
    # by then makes the sweep find nothing - and M1 through M4 all go red at once
    # with no defect behind them, which is what happened on 2026-08-23 during the
    # soak work and read as "M is flaky". A cold `Add-Type -AssemblyName
    # System.Windows.Forms` is 0.2s on an idle box and unbounded on a loaded one,
    # so the wait is the only version of this fixture that is not a race.
    # It waits on the SWEEP'S OWN predicate: "the thing the runner looks for is
    # there" is the only handshake that cannot be satisfied by a window the sweep
    # would not have counted anyway.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib\ModalSweep.ps1') `
        -Destination (Join-Path $FixTests 'lib\ModalSweep.ps1') -Force
    $modalPidFile = Join-Path $env:TEMP 'ghoztty-suite-modal-pid.txt'
    $modalUpFile = Join-Path $env:TEMP 'ghoztty-suite-modal-up.txt'
    Set-FixtureScript 'h-modal.ps1' @'
$body = "Add-Type -AssemblyName System.Windows.Forms; " +
    "[void][System.Windows.Forms.MessageBox]::Show('suite-run fixture','Unsupported 16-Bit Application')"
$p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$body)
Set-Content -LiteralPath (Join-Path $env:TEMP 'ghoztty-suite-modal-pid.txt') -Value $p.Id -Encoding ASCII
. (Join-Path $PSScriptRoot 'lib\ModalSweep.ps1')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 30) {
    if (@(Get-StrayModalDialog | Where-Object { $_.ProcessId -eq $p.Id }).Count -gt 0) {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'ghoztty-suite-modal-up.txt') `
            -Value ("up after {0:N2}s" -f $sw.Elapsed.TotalSeconds) -Encoding ASCII
        break
    }
    Start-Sleep -Milliseconds 100
}
"ALL PASS (1 assertions)"
exit 0
'@

    Remove-Item -LiteralPath $modalPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $modalUpFile -Force -ErrorAction SilentlyContinue
    $dirM = Join-Path $Fixture 'runM'
    $rM = Invoke-Runner @('-Include', 'h-modal.ps1', '-OutDir', $dirM, '-TimeoutSec', '60')
    $sM = Get-Summary $dirM
    Check 'M1 a script that leaves a dialog up is scored a FAILURE, not its own ALL PASS' `
        ((Get-Verdict $sM 'h-modal.ps1') -eq 'fail') (Get-Verdict $sM 'h-modal.ps1')
    $rowM = @($sM.results | Where-Object { $_.Name -eq 'h-modal.ps1' })
    Check 'M2 and the report names the dialog' `
        (($rowM.Count -eq 1) -and ($rowM[0].Line -match 'stray modal dialog')) `
        $(if ($rowM.Count) { $rowM[0].Line } else { '(no row)' })
    Check 'M3 the suite verdict goes red over it' ($rM.Exit -ne 0) "exit $($rM.Exit)"
    Check 'M4 the summary counts it' `
        (($rowM.Count -eq 1) -and ([int]$rowM[0].Modals -ge 1)) ''
    # And it is DISMISSED: the sweep exists so the rest of the suite is not run
    # behind a modal waiting for a human.
    $modalPid = 0
    if (Test-Path -LiteralPath $modalPidFile) {
        try { $modalPid = [int]((Get-Content -LiteralPath $modalPidFile -Raw).Trim()) } catch { $modalPid = 0 }
    }
    # The positive control is that the dialog was SEEN ON SCREEN, not that a pid
    # was written: the pid file is written before the box paints, so the old
    # version of this check passed in exactly the run where M1-M4 had nothing to
    # find. When this one fails, the four above it are explained rather than
    # mysterious - the fixture never got its dialog up, and no verdict of the
    # runner's is in question.
    $modalUp = ''
    if (Test-Path -LiteralPath $modalUpFile) {
        try { $modalUp = (Get-Content -LiteralPath $modalUpFile -Raw).Trim() } catch { $modalUp = '' }
    }
    Check 'M5 the fixture really got one on screen (positive control)' `
        (($modalPid -gt 0) -and $modalUp) "pid $modalPid, $(if ($modalUp) { $modalUp } else { 'never appeared' })"
    if ($modalPid -gt 0) {
        $stillUp = @(Get-StrayModalDialog | Where-Object { $_.ProcessId -eq $modalPid })
        Check 'M6 and the sweep dismissed it rather than leaving it on screen' ($stillUp.Count -eq 0) `
            "$($stillUp.Count) still up"
        try { & taskkill.exe /T /F /PID $modalPid *> $null } catch { }
    }
    Remove-Item -LiteralPath $modalPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $modalUpFile -Force -ErrorAction SilentlyContinue

    # --- N. per-script declared timeout (T1125) ----------------------------
    Write-Host ''
    Write-Host '-- N. per-script declared timeout'

    # The failure this is for: `soak.ps1` runs a 30-minute soak by design and
    # prints nothing while it samples, so the one global 600s cap killed it and
    # scored it `stall` on every full sweep. Long-session stability - the thing
    # the standing quality bar names - was therefore never measured, and the
    # stall read exactly like the app having hung.
    #
    # i-slow.ps1 is that shape in miniature: it declares 40s, sleeps 12s, and is
    # run under a 5s global cap. It must PASS.
    Set-FixtureScript 'i-slow.ps1' @'
# suite-timeout-sec: 40
Start-Sleep -Seconds 12
"ALL PASS (1 assertions)"
exit 0
'@

    $dirN = Join-Path $Fixture 'runN'
    $rN = Invoke-Runner @('-Include', 'i-slow.ps1', '-OutDir', $dirN, '-TimeoutSec', '5')
    $sN = Get-Summary $dirN
    $rowN = @($sN.results | Where-Object { $_.Name -eq 'i-slow.ps1' })
    Check 'N1 a script that declares its own cap outlives the global one' `
        ((Get-Verdict $sN 'i-slow.ps1') -eq 'pass') (Get-Verdict $sN 'i-slow.ps1')
    Check 'N2 it really ran past the global cap (positive control)' `
        (($rowN.Count -eq 1) -and ($rowN[0].Seconds -gt 5)) `
        $(if ($rowN.Count) { "$($rowN[0].Seconds)s" } else { '(no row)' })
    Check 'N3 the summary records the cap the row was measured against' `
        (($rowN.Count -eq 1) -and ([int]$rowN[0].Timeout -eq 40)) `
        $(if ($rowN.Count) { "timeout $($rowN[0].Timeout)" } else { '(no row)' })
    Check 'N4 and that the script asked for it' `
        (($rowN.Count -eq 1) -and ([int]$rowN[0].Declared -eq 40)) `
        $(if ($rowN.Count) { "declared $($rowN[0].Declared)" } else { '(no row)' })
    Check 'N5 the header says which scripts declared one' `
        ($rN.Text -match 'per-script timeout: i-slow\.ps1 40s') $rN.Text

    # -MaxTimeoutSec is the quick pass: the declaration is bounded rather than
    # obeyed, and the script goes back to being a stall. Without it a caller who
    # wanted a fast sweep would have to -Exclude the long scripts by name.
    $dirN2 = Join-Path $Fixture 'runN2'
    $rN2 = Invoke-Runner @('-Include', 'i-slow.ps1', '-OutDir', $dirN2, '-TimeoutSec', '5', '-MaxTimeoutSec', '6')
    $sN2 = Get-Summary $dirN2
    $rowN2 = @($sN2.results | Where-Object { $_.Name -eq 'i-slow.ps1' })
    Check 'N6 -MaxTimeoutSec bounds a declaration' `
        ((Get-Verdict $sN2 'i-slow.ps1') -eq 'stall') (Get-Verdict $sN2 'i-slow.ps1')
    Check 'N7 and the row names the cap it was actually held to' `
        (($rowN2.Count -eq 1) -and ([int]$rowN2[0].Timeout -eq 6)) `
        $(if ($rowN2.Count) { "timeout $($rowN2[0].Timeout)" } else { '(no row)' })
    Check 'N8 the header says the declaration was capped' `
        ($rN2.Text -match 'capped from 40s') $rN2.Text

    # An undeclared script is unaffected by any of this - the global cap is
    # still the cap, which is the case 241 of the 242 scripts are in.
    $dirN3 = Join-Path $Fixture 'runN3'
    $null = Invoke-Runner @('-Include', 'g-hang.ps1', '-OutDir', $dirN3, '-TimeoutSec', '5')
    $sN3 = Get-Summary $dirN3
    $rowN3 = @($sN3.results | Where-Object { $_.Name -eq 'g-hang.ps1' })
    Check 'N9 an undeclared script still gets the global cap' `
        (((Get-Verdict $sN3 'g-hang.ps1') -eq 'stall') -and ($rowN3.Count -eq 1) -and ([int]$rowN3[0].Timeout -eq 5)) `
        $(if ($rowN3.Count) { "$(Get-Verdict $sN3 'g-hang.ps1') timeout $($rowN3[0].Timeout)" } else { '(no row)' })
    Check 'N10 and declares nothing' `
        (($rowN3.Count -eq 1) -and ([int]$rowN3[0].Declared -eq 0)) ''

    # A garbled declaration falls back to the run's cap, never to "no bound" -
    # the same rule ipc_timeout.zig applies to its env var. Left unbounded, a
    # typo would hang the sweep forever, which is worse than the stall it was
    # trying to avoid.
    Set-FixtureScript 'j-garbled.ps1' @'
# suite-timeout-sec: soon
Start-Sleep -Seconds 90
"ALL PASS (1 assertions)"
exit 0
'@
    $dirN4 = Join-Path $Fixture 'runN4'
    $null = Invoke-Runner @('-Include', 'j-garbled.ps1', '-OutDir', $dirN4, '-TimeoutSec', '5')
    $sN4 = Get-Summary $dirN4
    $rowN4 = @($sN4.results | Where-Object { $_.Name -eq 'j-garbled.ps1' })
    Check 'N11 an unparseable declaration falls back to the global cap' `
        (((Get-Verdict $sN4 'j-garbled.ps1') -eq 'stall') -and ($rowN4.Count -eq 1) -and ([int]$rowN4[0].Timeout -eq 5)) `
        $(if ($rowN4.Count) { "timeout $($rowN4[0].Timeout)" } else { '(no row)' })

    # The real subject: soak.ps1 declares one, so the suite stops scoring it a
    # stall. Read from the SHIPPING script, not a fixture - a declaration this
    # harness proves in the abstract and the actual file has lost is the whole
    # regression.
    $soak = Join-Path $Repo 'test\win32\soak.ps1'
    $soakText = ''
    if (Test-Path -LiteralPath $soak) { $soakText = Get-Content -LiteralPath $soak -Raw }
    $soakOk = $soakText -match '(?m)^#\s*suite-timeout-sec:\s*(\d+)\s*$'
    $soakCap = $(if ($soakOk) { [int]$Matches[1] } else { 0 })
    Check 'N12 soak.ps1 declares a cap longer than its own 30-minute default' `
        ($soakOk -and ($soakCap -gt 1800)) "declared $soakCap"
    # A CRLF script declares its cap just as well as an LF one. `$` in .NET
    # multiline matches BEFORE the \n and leaves the \r inside the line, so a
    # pattern anchored with [ \t]*$ reads nothing at all out of a CRLF file -
    # which is what happened to soak.ps1 the day it was rewritten with CRLF
    # endings, putting it straight back to a 600s kill and a `stall` verdict.
    $crlfPath = Join-Path $FixTests 'p-crlf.ps1'
    $crlfBody = "# suite-timeout-sec: 77`r`n'ALL PASS (1 assertions)'`r`nexit 0`r`n"
    [System.IO.File]::WriteAllText($crlfPath, $crlfBody)
    $crlfList = & powershell -NoProfile -ExecutionPolicy Bypass -File $Runner `
        list -Repo $Fixture -Include 'p-crlf.ps1' | Out-String
    Check 'N14 a CRLF script declaration is read too' `
        ($crlfList -match 'p-crlf\.ps1\s+\(declares 77s\)') $crlfList
    Remove-Item -LiteralPath $crlfPath -Force -ErrorAction SilentlyContinue

    # Not Invoke-Runner: that one binds -Repo to the throwaway fixture, and the
    # claim here is about the real test\win32. Stdout only - merging stderr in
    # would make the captured text depend on the host's buffer width (T883).
    $soakList = & powershell -NoProfile -ExecutionPolicy Bypass -File $Runner `
        list -Repo $Repo -Include 'soak.ps1' | Out-String
    Check 'N13 and the runner reads it off the shipping script' `
        ($soakList -match 'soak\.ps1\s+\(declares \d+s\)') $soakList

    # --- O. stderr must not masquerade as the verdict line (T1125) ---------
    Write-Host ''
    Write-Host '-- O. the quoted line is what the script SAID'

    # stderr is folded onto the end of the log so one file is the whole story.
    # Scoring that folded file quotes the last stderr line as the verdict - so a
    # soak killed 20 minutes into its silent sampling loop was reported as
    # `Waiting for Ghoztty to answer '+list'`, a startup notice printed in its
    # first seconds, and a hung app was the leading hypothesis for a day.
    Set-FixtureScript 'k-noisy.ps1' @'
[Console]::Error.WriteLine("a notice from twenty minutes ago")
"the last thing stdout said"
Start-Sleep -Seconds 90
exit 0
'@
    $dirO = Join-Path $Fixture 'runO'
    $null = Invoke-Runner @('-Include', 'k-noisy.ps1', '-OutDir', $dirO, '-TimeoutSec', '8')
    $sO = Get-Summary $dirO
    $rowO = @($sO.results | Where-Object { $_.Name -eq 'k-noisy.ps1' })
    Check 'O1 a stalled script quotes its last STDOUT line' `
        (($rowO.Count -eq 1) -and ($rowO[0].Line -match 'the last thing stdout said')) `
        $(if ($rowO.Count) { $rowO[0].Line } else { '(no row)' })
    Check 'O2 not the stderr line folded in after it' `
        (($rowO.Count -eq 1) -and ($rowO[0].Line -notmatch 'twenty minutes ago')) `
        $(if ($rowO.Count) { $rowO[0].Line } else { '(no row)' })
    # The fold itself stays: the log is still the whole story, which is the
    # reason it exists.
    $logO = Join-Path $dirO 'k-noisy.log'
    $textO = ''
    if (Test-Path -LiteralPath $logO) { $textO = Get-Content -LiteralPath $logO -Raw }
    Check 'O3 the log still holds both halves' `
        (($textO -match 'twenty minutes ago') -and ($textO -match 'the last thing stdout said')) ''

    # A script that only ever spoke on stderr still gets a hint rather than a
    # blank: the rule is "stdout unless it said nothing", not "stdout only".
    Set-FixtureScript 'l-silent-out.ps1' @'
[Console]::Error.WriteLine("only stderr ever spoke")
exit 9
'@
    $dirO2 = Join-Path $Fixture 'runO2'
    $null = Invoke-Runner @('-Include', 'l-silent-out.ps1', '-OutDir', $dirO2, '-TimeoutSec', '30')
    $sO2 = Get-Summary $dirO2
    $rowO2 = @($sO2.results | Where-Object { $_.Name -eq 'l-silent-out.ps1' })
    Check 'O4 a script that spoke only on stderr is still quoted' `
        (($rowO2.Count -eq 1) -and ($rowO2[0].Line -match 'only stderr ever spoke')) `
        $(if ($rowO2.Count) { $rowO2[0].Line } else { '(no row)' })

    # --- P. the confirm pass (T1137) ---------------------------------------
    Write-Host ''
    Write-Host '-- P. a red script is re-run alone before the run ends'

    # The discriminator this pass exists for: a script that is red once and
    # green the moment it runs again is a harness or isolation defect, and the
    # sweep of 2026-08-22 had eight of those filed as P1 user-facing outages.
    # The fixture makes the two cases mechanical - one script flips on its
    # second invocation, one stays red however often it runs.
    # Invocation counting is the measurement here, and every section above has
    # been appending to the same log.
    Set-Content -LiteralPath $RunLog -Value '' -Encoding ASCII
    Remove-Item -LiteralPath (Join-Path $Fixture 'flake.marker') -Force -ErrorAction SilentlyContinue
    $flakeMarker = Join-Path $Fixture 'flake.marker'
    Set-FixtureScript 'p-flaky.ps1' @"
if (Test-Path -LiteralPath '$flakeMarker') { 'ALL PASS (1 assertions)'; exit 0 }
Set-Content -LiteralPath '$flakeMarker' -Value 'x'
'  FAIL only the first time'
'1 FAILURE(S) (0 passed)'
exit 1
"@
    Set-FixtureScript 'p-solid.ps1' @'
"  FAIL every single time"
"2 FAILURE(S) (1 passed)"
exit 1
'@

    $dirP = Join-Path $Fixture 'runP'
    $rP = Invoke-Runner @('-Include', 'p-flaky.ps1,p-solid.ps1,b-pass.ps1', '-OutDir', $dirP, '-TimeoutSec', '60')
    $sP = Get-Summary $dirP
    $flaky = @($sP.results | Where-Object { $_.Name -eq 'p-flaky.ps1' })
    $solid = @($sP.results | Where-Object { $_.Name -eq 'p-solid.ps1' })
    $green = @($sP.results | Where-Object { $_.Name -eq 'b-pass.ps1' })

    Check 'P1 the first run verdict is kept as it was' `
        (($flaky.Count -eq 1) -and ($flaky[0].Verdict -eq 'fail')) `
        $(if ($flaky.Count) { $flaky[0].Verdict } else { '(no row)' })
    Check 'P2 a script green on the re-run is marked NOT reproduced' `
        (($flaky.Count -eq 1) -and ($flaky[0].Alone -eq 'pass') -and ($flaky[0].Reproduced -eq 'no')) `
        $(if ($flaky.Count) { "alone=$($flaky[0].Alone) reproduced=$($flaky[0].Reproduced)" } else { '(no row)' })
    Check 'P3 a script red both times is marked reproduced' `
        (($solid.Count -eq 1) -and ($solid[0].Alone -eq 'fail') -and ($solid[0].Reproduced -eq 'yes')) `
        $(if ($solid.Count) { "alone=$($solid[0].Alone) reproduced=$($solid[0].Reproduced)" } else { '(no row)' })
    # Measured by counting real invocations, not by reading the runner's report:
    # a pass that re-ran everything would double a 2h46m sweep.
    Check 'P4 only the non-pass scripts are re-run' `
        ((Get-InvocationCount 'p-solid.ps1') -eq 2 -and (Get-InvocationCount 'b-pass.ps1') -eq 1) `
        "solid=$(Get-InvocationCount 'p-solid.ps1') pass=$(Get-InvocationCount 'b-pass.ps1')"
    Check 'P5 a passing row carries no alone verdict at all' `
        (($green.Count -eq 1) -and ($green[0].Verdict -eq 'pass') -and (-not $green[0].Reproduced)) `
        $(if ($green.Count) { "reproduced=$($green[0].Reproduced)" } else { '(no row)' })
    # The line somebody reads before writing the task up.
    Check 'P6 the table says the green-alone one is not the product' `
        ($rP.Text -match 'p-flaky\.ps1.*NOT reproduced') $rP.Text
    Check 'P7 and counts how many of the reds reproduced' `
        ($rP.Text -match 'reproduced alone: 1 of 2') $rP.Text
    # Two runs of a disagreeing script are only useful if BOTH logs survive:
    # writing the re-run over the sweep log destroys the evidence being compared.
    Check 'P8 the re-run log is kept beside the first one' `
        ((Test-Path -LiteralPath (Join-Path $dirP 'p-flaky.log')) -and `
         (Test-Path -LiteralPath (Join-Path $dirP 'p-flaky.alone.log'))) ''
    # The run's own exit code is still the FIRST pass's verdict: a flake that
    # goes green on the re-run is still a red suite, it is just a red suite for
    # a different reason.
    Check 'P9 the run still exits nonzero' ($rP.Exit -eq 1) "exit $($rP.Exit)"

    # -NoConfirm: no second run, and - the part that matters - no field that
    # could be mistaken for "it did not reproduce".
    Remove-Item -LiteralPath $flakeMarker -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $RunLog -Value '' -Encoding ASCII
    $dirQ = Join-Path $Fixture 'runQ'
    $rQ = Invoke-Runner @('-Include', 'p-flaky.ps1,p-solid.ps1', '-OutDir', $dirQ, '-TimeoutSec', '60', '-NoConfirm')
    $sQ = Get-Summary $dirQ
    $flakyQ = @($sQ.results | Where-Object { $_.Name -eq 'p-flaky.ps1' })
    Check 'P10 -NoConfirm re-runs nothing' `
        ((Get-InvocationCount 'p-flaky.ps1') -eq 1) "invocations=$(Get-InvocationCount 'p-flaky.ps1')"
    Check 'P11 and leaves the alone verdict empty, not no' `
        (($flakyQ.Count -eq 1) -and (-not $flakyQ[0].Reproduced)) `
        $(if ($flakyQ.Count) { "reproduced=$($flakyQ[0].Reproduced)" } else { '(no row)' })
    Check 'P12 which the table reports as not re-run' `
        ($rQ.Text -match 'p-flaky\.ps1.*alone: not re-run') $rQ.Text

    # The retrospective half: a summary that already exists gets the same three
    # fields filled in, in place. This is how a sweep that predates the pass is
    # re-priced from evidence instead of from memory.
    $rC = Invoke-Runner @('confirm', '-Resume', $dirQ)
    $sC = Get-Summary $dirQ
    $flakyC = @($sC.results | Where-Object { $_.Name -eq 'p-flaky.ps1' })
    $solidC = @($sC.results | Where-Object { $_.Name -eq 'p-solid.ps1' })
    Check 'P13 confirm fills in the flaky row of an existing summary' `
        (($flakyC.Count -eq 1) -and ($flakyC[0].Reproduced -eq 'no')) `
        $(if ($flakyC.Count) { "reproduced=$($flakyC[0].Reproduced)" } else { '(no row)' })
    Check 'P14 and the reproducing one' `
        (($solidC.Count -eq 1) -and ($solidC[0].Reproduced -eq 'yes')) `
        $(if ($solidC.Count) { "reproduced=$($solidC[0].Reproduced)" } else { '(no row)' })
    Check 'P15 the original verdicts are not overwritten' `
        (($flakyC.Count -eq 1) -and ($flakyC[0].Verdict -eq 'fail')) `
        $(if ($flakyC.Count) { $flakyC[0].Verdict } else { '(no row)' })
    Check 'P16 confirm exits 1 while something still reproduces' ($rC.Exit -eq 1) "exit $($rC.Exit)"

    # Nothing reproduced -> exit 0, and it says so in those words: that verdict
    # is the one that re-prices a queue of tasks, so it may not be silent.
    $dirR = Join-Path $Fixture 'runR'
    Remove-Item -LiteralPath $flakeMarker -Force -ErrorAction SilentlyContinue
    $null = Invoke-Runner @('-Include', 'p-flaky.ps1', '-OutDir', $dirR, '-TimeoutSec', '60', '-NoConfirm')
    $rC2 = Invoke-Runner @('confirm', '-Resume', $dirR)
    Check 'P17 confirm exits 0 when none of them reproduce' ($rC2.Exit -eq 0) "exit $($rC2.Exit)"
    Check 'P18 and names them as harness defects' `
        ($rC2.Text -match 'none of 1 reproduced alone') $rC2.Text

    # --- S. the whole-script SKIP (T1100) ----------------------------------
    Write-Host ''
    Write-Host '-- S. a script the box cannot answer is skipped, not failed'

    # WHY THIS KIND EXISTS. Some acceptance scripts ask a question the desktop
    # a run happens on cannot answer at all - the terminal surface does not
    # compose on a background desktop, SendInput is ACCESS_DENIED off the input
    # desktop, an input lock owns the foreground. Scored as failures they are
    # permanently red, and a permanently-red script teaches everyone to ignore
    # the colour. So the script declares the missing capability
    # (lib\DesktopCapability.ps1), prints SKIP ALL and exits 0, and the runner
    # scores that apart from both pass and fail.
    Set-Content -LiteralPath $RunLog -Value '' -Encoding ASCII
    Set-FixtureScript 's-skip.ps1' @'
"SKIP ALL: real-input is not available here - SendInput accepted 0 of 1 events"
exit 0
'@

    $dirS = Join-Path $Fixture 'runS'
    $rS = Invoke-Runner @('-Include', 's-skip.ps1,b-pass.ps1', '-OutDir', $dirS, '-TimeoutSec', '60')
    $sS = Get-Summary $dirS
    # Without this kind the row scored `error` - exit 0 with no ALL PASS - which
    # is the T221 shape and reads as a script that fell through its own body.
    Check 'S1 SKIP ALL at exit 0 scores skip' ((Get-Verdict $sS 's-skip.ps1') -eq 'skip') (Get-Verdict $sS 's-skip.ps1')
    Check 'S2 a skip is not counted red: the suite still exits 0' ($rS.Exit -eq 0) "exit $($rS.Exit)"
    Check 'S3 and the verdict line says how many were skipped' `
        ($rS.Text -match 'SUITE ALL PASS \(2 scripts, 1 SKIPPED') $rS.Text
    Check 'S4 the summary counts skips on their own line' `
        ($rS.Text -match '(?m)^\s*skipped\s*:\s*1\s*$') $rS.Text
    # Named, because the failure mode of a skip is that it goes unnoticed: the
    # reason it could not run has to be in front of whoever reads the sweep.
    Check 'S5 the skipped script is listed with its reason' `
        (($rS.Text -match 's-skip\.ps1') -and ($rS.Text -match 'real-input is not available here')) $rS.Text
    Check 'S6 a skip is NOT a pass' ((Get-Verdict $sS 'b-pass.ps1') -eq 'pass') (Get-Verdict $sS 'b-pass.ps1')
    # The confirm pass separates a product defect from an isolation artefact,
    # and a skip poses neither question - re-running it only spends the sweep's
    # most expensive minutes re-deriving 'the box still cannot do this'.
    Check 'S7 the confirm pass does not re-run a skip' `
        ((Get-InvocationCount 's-skip.ps1') -eq 1) "invocations=$(Get-InvocationCount 's-skip.ps1')"

    # A skip beside a real failure: the failure still decides the colour, and
    # the skip is still reported. A runner that let one hide the other would
    # make the suite's colour a property of the desktop it ran on.
    $dirS2 = Join-Path $Fixture 'runS2'
    $rS2 = Invoke-Runner @('-Include', 's-skip.ps1,c-fail.ps1', '-OutDir', $dirS2, '-TimeoutSec', '60', '-NoConfirm')
    Check 'S8 a real failure still reddens a run that also skipped' `
        (($rS2.Exit -eq 1) -and ($rS2.Text -match 'SUITE 1 FAILURE\(S\) of 2 scripts, 1 SKIPPED')) `
        "exit $($rS2.Exit)"
    Check 'S9 and the skip is not in the not-green table' `
        ($rS2.Text -notmatch '(?m)^\s*skip\s+s-skip\.ps1') $rS2.Text
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
Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 50
