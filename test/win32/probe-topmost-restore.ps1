<#
T179 - a test probe can never leave a window topmost.

WHY THIS EXISTS

A pixel probe that raises a live window with HWND_TOPMOST and never puts it
back is what manufactured T142's phantom bug: a day spent chasing "windows in
the background have banners that overlap windows in the foreground", which
turned out to be a T131 verification probe (raiseshot.ps1, since deleted)
leaving WS_EX_TOPMOST on two overlays. The harness artifact presented as a
product defect, and there was nothing in the suite that could tell them apart.

The fix is not "remember to restore it". It is that the ONLY supported way to
topmost a window from a test - Set-TestWindowTopmost - ledgers the pin, and
three independent paths cash that ledger in:

  * Remove-TestDesktop, which every GUI script already calls from its `finally`
    (so a mid-run abort restores);
  * the PowerShell.Exiting handler the harness arms at load (so a script with
    no `finally` at all still restores);
  * Restore-TestWindowTopmost, if a script wants the answer mid-run.

Sections:
  A. the ledger records a pin, and the restore un-pins it and reports it
  B. an explicit un-pin leaves the ledger clean - a healthy run reports no leak
  C. teardown restores without being asked (the mid-run-abort path)
  D. interpreter exit restores with no `finally` anywhere (child process, dies
     mid-run exactly the way an aborted script does)
  E. no test script topmosts a window OUTSIDE the ledgered helper

The subject window is charmap.exe, not ghoztty: a plain Win32 window keeps
WS_EX_TOPMOST in every condition (measured in T277/T607), while the product
HEALS a stray pin on its next reposition - which is correct, and which would
make it useless as an oracle for whether the HARNESS put the bit back.

TEETH: re-run with GHOZTTY_TEST_TOPMOST_BREAK=1 and sections A, C and D must go
red (E is a static scan and is unaffected). That switch disables the restore and
nothing else. Every arm in here asserts an ABSENCE - a bit that is not set - and
an absence assertion passes just as happily when the thing that was supposed to
set it never ran, so this is how each one was shown to have teeth.
#>
param(
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Test-Topmost([IntPtr]$h) {
    return ((Get-TestWindowStyle -Window $h -ExStyle) -band 0x8) -ne 0
}

$charmap = Join-Path $env:SystemRoot 'System32\charmap.exe'
if (-not (Test-Path $charmap)) { Write-Host "SETUP FAIL: no charmap.exe at $charmap"; exit 1 }

$deskName = 'ghoztty-t179-' + [System.Diagnostics.Process]::GetCurrentProcess().Id
$td = New-TestDesktop -Name $deskName -Interactive:$Interactive

# Launch a plain Win32 window to pin. Returns { Pid, Hwnd } or $null.
# persistence: charmap.exe is not the app under test - it has no sessions and
# reads no manifest, so the session-persistence question does not arise here.
function Start-Subject {
    $p = Start-OnTestDesktop -Exe $charmap
    $h = Wait-TestWindow -ProcessId $p.Pid -Class '#32770'
    if ($h -eq [IntPtr]::Zero) {
        # charmap's dialog class is #32770; fall back to any top-level window of
        # the process rather than failing on a class-name assumption.
        for ($t = 0; $t -lt 25 -and $h -eq [IntPtr]::Zero; $t++) {
            $w = @(Get-TestWindows -ProcessId $p.Pid)
            if ($w.Count -gt 0) { $h = [IntPtr]$w[0].Hwnd; break }
            Start-Sleep -Milliseconds 200
        }
    }
    if ($h -eq [IntPtr]::Zero) { return $null }
    return [pscustomobject]@{ Pid = $p.Pid; Hwnd = $h }
}

try {
    # -----------------------------------------------------------------------
    # A. The ledger records a pin; the restore un-pins it and names it.
    # -----------------------------------------------------------------------
    $a = Start-Subject
    if (-not $a) { Write-Host 'SETUP FAIL: no charmap window for section A'; exit 1 }

    Assert (-not (Test-Topmost $a.Hwnd)) 'A: the subject window does not start out topmost'
    Assert ((Get-TestTopmostPending).Count -eq 0) 'A: the ledger starts empty'

    Set-TestWindowTopmost -Window $a.Hwnd -On $true | Out-Null
    Start-Sleep -Milliseconds 200
    Assert (Test-Topmost $a.Hwnd) 'A: the injection took (WS_EX_TOPMOST is set)'
    Assert ((Get-TestTopmostPending) -contains [int64]$a.Hwnd) 'A: the pin is LEDGERED, not left to the caller to remember'

    $freed = @(Restore-TestWindowTopmost)
    Assert ($freed -contains [int64]$a.Hwnd) 'A: the restore reports the window it had to un-pin'
    Assert (-not (Test-Topmost $a.Hwnd)) 'A: and the window is actually back to NOTOPMOST'
    Assert ((Get-TestTopmostPending).Count -eq 0) 'A: the ledger is empty again'
    Assert ((Get-TestTopmostRestored) -contains [int64]$a.Hwnd) 'A: the leak is recorded for the end-of-run assertion'

    # Idempotent: a second restore has nothing to do and invents nothing.
    Assert ((@(Restore-TestWindowTopmost)).Count -eq 0) 'A: a second restore is a no-op'

    # -----------------------------------------------------------------------
    # B. An explicit un-pin de-ledgers, so a healthy run reports NO leak.
    #
    # This is what keeps the end-of-run assertion honest. If every injection
    # counted as a leak regardless of what happened next, overlay-zorder.ps1
    # would fail on a run where the product healed every stray pin correctly -
    # an assertion that can only ever be red says nothing.
    # -----------------------------------------------------------------------
    $b = Start-Subject
    if (-not $b) { Write-Host 'SETUP FAIL: no charmap window for section B'; exit 1 }

    Set-TestWindowTopmost -Window $b.Hwnd -On $true | Out-Null
    Start-Sleep -Milliseconds 200
    Assert (Test-Topmost $b.Hwnd) 'B: injection took'
    Set-TestWindowTopmost -Window $b.Hwnd -On $false | Out-Null
    Start-Sleep -Milliseconds 200
    Assert (-not (Test-Topmost $b.Hwnd)) 'B: the explicit un-pin cleared the bit'
    Assert (-not ((Get-TestTopmostPending) -contains [int64]$b.Hwnd)) 'B: and took the window off the ledger'
    Assert (-not ((@(Restore-TestWindowTopmost)) -contains [int64]$b.Hwnd)) 'B: so the restore does not report it as a leak'

    # -----------------------------------------------------------------------
    # C. Teardown restores without being asked. This is the mid-run-abort path:
    #    every GUI script calls Remove-TestDesktop from its `finally`, and a
    #    `finally` runs on an exception AND on an `exit` inside the try.
    #    -KeepProcesses is what makes it observable - otherwise the subject
    #    window dies with the restore and there is nothing to read back.
    # -----------------------------------------------------------------------
    $c = Start-Subject
    if (-not $c) { Write-Host 'SETUP FAIL: no charmap window for section C'; exit 1 }

    Set-TestWindowTopmost -Window $c.Hwnd -On $true | Out-Null
    Start-Sleep -Milliseconds 200
    Assert (Test-Topmost $c.Hwnd) 'C: injection took'

    Remove-TestDesktop -KeepProcesses
    Start-Sleep -Milliseconds 200
    # Re-bind to the SAME desktop to read the answer back: teardown dropped the
    # binding, and the subject window (kept alive by -KeepProcesses) is what
    # holds the desktop open in the meantime.
    New-TestDesktop -Name $deskName -Interactive:$Interactive | Out-Null
    Assert (-not (Test-Topmost $c.Hwnd)) 'C: teardown un-pinned it, though nobody asked it to'
    Assert ((Get-TestTopmostRestored) -contains [int64]$c.Hwnd) 'C: and recorded it as a leak the run would have left'
} finally {
    Remove-TestDesktop
    foreach ($v in @($a, $b, $c)) {
        if ($v) { Stop-Process -Id $v.Pid -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# D. Interpreter exit restores, with no `finally` anywhere in the child.
#
# The child dies exactly the way an aborted script does - it pins a window and
# then exits mid-run, having never written a cleanup path. Nothing in ITS code
# puts the bit back; the PowerShell.Exiting handler armed at harness load does.
# It shares this run's desktop by name so the pinned window is one this parent
# can still read after the child is gone.
# ---------------------------------------------------------------------------
$dDesk = 'ghoztty-t179d-' + [System.Diagnostics.Process]::GetCurrentProcess().Id
$parentTd = New-TestDesktop -Name $dDesk
$d = $null
try {
    $d = Start-Subject
    if (-not $d) {
        Write-Host 'SETUP FAIL: no charmap window for section D'
    } else {
        $childBody = @'
param([string]$Desk, [int64]$Hwnd, [string]$Harness)
$ErrorActionPreference = 'Continue'
. $Harness
New-TestDesktop -Name $Desk | Out-Null
Set-TestWindowTopmost -Window ([IntPtr]$Hwnd) -On $true | Out-Null
Start-Sleep -Milliseconds 200
if (((Get-TestWindowStyle -Window ([IntPtr]$Hwnd) -ExStyle) -band 0x8) -ne 0) {
    Write-Host 'CHILD: pinned'
} else {
    Write-Host 'CHILD: pin did not take'
}
# No finally. No Remove-TestDesktop. Die mid-run, the way an aborted script does.
exit 9
'@
        # Written to TEMP, not into test\win32: a stray copy left by a crash
        # would otherwise be swept by every suite-wide enumerator in here.
        $childPath = Join-Path $env:TEMP "t179-abort-$PID.ps1"
        $harness = Join-Path $PSScriptRoot 'lib\TestDesktop.ps1'
        Set-Content -Path $childPath -Value $childBody -Encoding UTF8
        try {
            $out = & powershell -NoProfile -File $childPath -Desk $dDesk -Hwnd ([int64]$d.Hwnd) -Harness $harness 2>&1 | Out-String
            $childCode = $LASTEXITCODE
            Assert ($out -match 'CHILD: pinned') "D: the child really did pin the window (child said: $($out.Trim()))"
            Assert ($childCode -eq 9) "D: the child died mid-run without cleaning up (exit $childCode)"
            Start-Sleep -Milliseconds 400
            Assert (-not (Test-Topmost $d.Hwnd)) 'D: the window is NOT topmost after the child exited - the exit handler put it back'
        } finally {
            Remove-Item $childPath -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    Remove-TestDesktop
    if ($d) { Stop-Process -Id $d.Pid -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# E. No script topmosts a window outside the ledgered helper.
#
# The ledger only protects pins that go through it, so the property that keeps
# T142 from recurring is that there is no other way in. A raw
# SetWindowPos(h, HWND_TOPMOST, ...) in a test script is the exact idiom that
# caused the original incident; lib\TestDesktop.ps1 is the one file allowed to
# spell it, because that is where the ledger lives.
#
# Comment and here-doc lines are skipped: this file and float-on-top.ps1 both
# DISCUSS the idiom in prose, and a lint that cannot tell prose from code would
# be turned off within a week.
#
# Two files are exempt from the scan itself: lib\TestDesktop.ps1, which is where
# the ledgered spelling lives, and THIS file, whose detector line necessarily
# contains the very tokens it looks for. A self-exempt detector could quietly
# stop detecting, so the last assertion runs it against a synthetic offender -
# it has to be able to go red before its green means anything.
# ---------------------------------------------------------------------------
function Find-RawTopmost([string[]]$Lines, [string]$Name) {
    $found = @()
    $inBlockComment = $false
    $n = 0
    foreach ($line in $Lines) {
        $n++
        $t = $line.Trim()
        if ($inBlockComment) { if ($t -match '#>') { $inBlockComment = $false }; continue }
        if ($t -match '^<#') { if ($t -notmatch '#>') { $inBlockComment = $true }; continue }
        if ($t.StartsWith('#')) { continue }
        if ($t -notmatch 'SetWindowPos') { continue }
        # HWND_TOPMOST is -1; the literal spellings a probe would use.
        if ($t -match 'HWND_TOPMOST' -or $t -match 'IntPtr\)\s*\(?\s*-1' -or $t -match 'SetWindowPos\([^,]+,\s*-1\b') {
            $found += "${Name}:${n} : $t"
        }
    }
    return $found
}

$exempt = @((Join-Path $PSScriptRoot 'lib\TestDesktop.ps1'), $PSCommandPath)
$offenders = @()
foreach ($f in (Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -Recurse)) {
    if ($exempt -contains $f.FullName) { continue }
    $offenders += @(Find-RawTopmost -Lines (Get-Content -LiteralPath $f.FullName) -Name $f.Name)
}
$offenderNote = ''
if ($offenders.Count -gt 0) { $offenderNote = ' -> ' + ($offenders -join ' | ') }
Assert ($offenders.Count -eq 0) "E: no test script topmosts a window outside Set-TestWindowTopmost$offenderNote"

# Teeth: the detector catches a raw pin, and is not fooled into calling prose
# one. Built from fragments so this file's own source carries no offender.
$tok = 'HWND_' + 'TOPMOST'
$synthetic = @(
    '<#',
    "prose about SetWindowPos(h, $tok) that is documentation, not a probe",
    '#>',
    "# a commented-out SetWindowPos(h, $tok, 0, 0, 0, 0, 0) is not live code",
    "`$null = [W]::SetWindowPos(`$h, $tok, 0, 0, 0, 0, 0x13)"
)
$caught = @(Find-RawTopmost -Lines $synthetic -Name 'synthetic')
Assert ($caught.Count -eq 1) "E/teeth: the detector catches exactly the live raw pin, not the prose or the comment (caught $($caught.Count))"
Assert (($caught -join '') -match ':5 ') 'E/teeth: and it is line 5 - the executable one - that it named'

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
