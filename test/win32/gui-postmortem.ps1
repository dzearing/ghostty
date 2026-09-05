# T527 - a process that dies during an acceptance run must say WHY.
#
# WHY THIS FILE EXISTS. Twice on 2026-08-06 the Debug GUI vanished mid-run with
# no panic and no crash-looking tail: the stderr log's last line was an ordinary
# `info(win32_ipc): IPC: received action 'read'` and then end of file. Twenty-six
# later asserts failed for the wrong reason and the investigation had nothing to
# work with, because the harness had never read the one number that separates
# the two possible stories - the exit code. An unhandled exception leaves an
# NTSTATUS there and an `Application Error` record in the Windows log; a
# deliberate ExitProcess leaves a small integer and no record. Those are
# different bugs.
#
# So what is under test is not "does the helper run". It is: does a REAL access
# violation launched through the same path the GUI is launched through come back
# named, does a silent ExitProcess come back distinguished FROM a crash rather
# than folded into it, is the exit code readable at all once the process is gone
# (it is not, unless a handle was held from launch), and does the teardown report
# a death nobody asked about while staying silent about the processes it killed
# itself.
#
# isolation: none - this script never launches ghoztty and never runs a CLI
# verb. It builds a scratch crasher, runs cmd.exe, and reads the Application
# event log; there is no IPC endpoint to isolate.
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'

# T675: this harness tracks the pids it launches; a self-escaping child would
# hand its work to a respawned twin and the postmortem would read the wrong one.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:failures = 0
$script:skipped = 0
$script:asserted = 0
function Assert($name, $cond) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name" }
    else { Write-Host "  FAIL $name"; $script:failures++ }
}
function Skip($name) { Write-Host "  SKIP $name"; $script:skipped++ }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("gui-postmortem-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Wait for a pid to be gone. Returns $true if it went, $false on timeout.
function Wait-Gone([int]$ProcessId, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $live = $null
        try { $live = Get-Process -Id $ProcessId -ErrorAction Stop } catch { $live = $null }
        if (-not $live) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

try {

# --------------------------------------------------------- A. the exit verdict

Write-Host 'A the exit-code verdict'
$a1 = ConvertTo-GuiExitVerdict -ExitCode 0
Assert 'A1 exit 0 is not a crash' ((-not $a1.IsCrash) -and $a1.Hex -eq '0x00000000')

$a2 = ConvertTo-GuiExitVerdict -ExitCode 3
Assert 'A2 exit 3 is not a crash (it is the T527 shape, not an exception)' `
    ((-not $a2.IsCrash) -and $a2.Hex -eq '0x00000003')

$a3 = ConvertTo-GuiExitVerdict -ExitCode -1073741819
Assert 'A3 0xC0000005 is named as an access violation' `
    ($a3.IsCrash -and $a3.Hex -eq '0xC0000005' -and $a3.Name -like '*ACCESS_VIOLATION*')

$a4 = ConvertTo-GuiExitVerdict -ExitCode -1073741309   # 0xC0000203, not in the table
Assert 'A4 an NTSTATUS the table has never seen is still a crash, named as unknown' `
    ($a4.IsCrash -and $a4.Hex -eq '0xC0000203' -and $a4.Name -eq 'unnamed NTSTATUS')

$a5 = ConvertTo-GuiExitVerdict -ExitCode -1073740791
Assert 'A5 0xC0000409 is named as the fastfail it is' `
    ($a5.IsCrash -and $a5.Name -like '*STACK_BUFFER_OVERRUN*')

# --------------------------------------------------------- B. the stderr tail

Write-Host 'B the stderr tail'
$clean = Join-Path $tmp 'clean.log'
[System.IO.File]::WriteAllText($clean, "one`r`ntwo`r`ninfo(win32_ipc): IPC: received action 'read'`r`n")
$b1 = Get-GuiStdErrTail -Path $clean
Assert 'B1 a log ending on a newline is read as ending between writes' `
    ($b1.Found -and (-not $b1.EndsMidLine) -and $b1.Tail -like "*received action 'read'*")

$mid = Join-Path $tmp 'mid.log'
[System.IO.File]::WriteAllText($mid, "one`r`ntwo`r`ninfo(win32_ipc): half a li")
$b2 = Get-GuiStdErrTail -Path $mid
Assert 'B2 a log stopping mid-line is read as dying while writing' ($b2.Found -and $b2.EndsMidLine)

$b3 = Get-GuiStdErrTail -Path (Join-Path $tmp 'nope.log')
Assert 'B3 a missing log is absent, not an error' ((-not $b3.Found) -and $b3.Tail -eq '')

$b4 = Get-GuiStdErrTail -Path ''
Assert 'B4 no log path at all is absent, not an error' (-not $b4.Found)

# The tail is bounded: a 500-line log must not paste 500 lines into a verdict.
$big = Join-Path $tmp 'big.log'
[System.IO.File]::WriteAllText($big, ((1..500 | ForEach-Object { "line $_" }) -join "`r`n") + "`r`n")
$b5 = Get-GuiStdErrTail -Path $big -Lines 12
Assert 'B5 the tail is bounded to the lines asked for' `
    ((@($b5.Tail -split "`n")).Count -eq 12 -and $b5.Tail -like '*line 500*')

# --------------------------------------------------- C. a REAL crash, live

Write-Host 'C a real access violation through the launch path'
$td = New-TestDesktop
$src = Join-Path $tmp 'av.zig'
@(
    'pub fn main() void {',
    '    const p: *volatile u8 = @ptrFromInt(0x10);',
    '    p.* = 1;',
    '}'
) | Set-Content -Path $src -Encoding ASCII
if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    # CLAUDE.md: the global cache must sit on the repo's drive.
    $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache')
}
Push-Location $tmp
# ReleaseFast on purpose: a Debug build installs Zig's own segfault handler and
# panics, which is the case that already reports itself. What T527 is about is
# the death that reaches Windows unannounced.
$buildOut = & zig build-exe av.zig -OReleaseFast 2>&1
Pop-Location
$avExe = Join-Path $tmp 'av.exe'
Assert 'C1 the crasher built' (Test-Path $avExe)

if (Test-Path $avExe) {
    $avErr = Join-Path $tmp 'av.err.log'
    $av = Start-OnTestDesktop -Exe $avExe -StdErr $avErr
    $gone = Wait-Gone -ProcessId $av.Pid -TimeoutSec 60
    Assert 'C2 the crasher died' $gone

    $r = Write-TestGuiPostmortem -ProcessId $av.Pid -WaitSeconds 40
    Assert 'C3 the postmortem was produced for a pid this harness launched' ($null -ne $r)
    if ($r) {
        Assert 'C4 it is reported as a crash' $r.Crashed
        Assert 'C5 with the access violation named' `
            ($r.ExitCodeHex -eq '0xC0000005' -and $r.Status -like '*ACCESS_VIOLATION*')
        Assert 'C6 the verdict line leads with CRASHED' ($r.Verdict -like 'CRASHED*')
        if ($r.CrashEvent) {
            Assert 'C7 the Windows Application Error record was found and names the exe' `
                ($r.CrashEvent.App -like 'av.exe')
        } else {
            # WER can be disabled by policy, and the log lags. The verdict above
            # does not depend on it, so this is a skip rather than a failure.
            Skip 'C7 (no Application Error record within the wait - WER may be off here)'
        }
        $block = @(Get-LastGuiPostmortem)
        Assert 'C8 the printed block names the pid and the status' `
            (($block -join "`n") -like "*pid $($av.Pid)*" -and ($block -join "`n") -like '*ACCESS_VIOLATION*')
    } else {
        Skip 'C4-C8 (no report)'; $script:skipped += 4
    }
} else {
    Write-Host "     build output: $buildOut"
    Skip 'C2-C8 (crasher did not build)'; $script:skipped += 6
}

# -------------------------------------- D. the T527 shape: a silent ExitProcess

Write-Host 'D a silent exit is told apart from a crash'
# `ping` rather than an immediate exit: StartProcess closes its own handle, so
# the harness has to open one of its own, and a process that is gone before it
# can is unreadable through no fault of the diagnosis.
$dErr = Join-Path $tmp 'd.err.log'
$d = Start-OnTestDesktop -Exe $env:ComSpec -Arguments @('/c', 'ping -n 3 127.0.0.1 >nul & echo info(win32_ipc): IPC: received action read 1>&2 & exit 3') -StdErr $dErr
$dGone = Wait-Gone -ProcessId $d.Pid -TimeoutSec 60
Assert 'D1 the child exited' $dGone

$dr = Write-TestGuiPostmortem -ProcessId $d.Pid -WaitSeconds 2
Assert 'D2 the exit code survived the process (a handle was held from launch)' `
    ($null -ne $dr -and $null -ne $dr.ExitCode)
if ($dr -and $null -ne $dr.ExitCode) {
    Assert 'D3 exit 3 is read as an ordinary exit' ((-not $dr.Crashed) -and $dr.ExitCode -eq 3)
    Assert 'D4 the verdict says out loud that this was not an unhandled exception' `
        ($dr.Verdict -like '*NOT an unhandled exception*')
    Assert 'D5 the stderr tail is carried into the report' `
        ($dr.StdErrFound -and $dr.StdErrTail -like '*received action read*')
} else {
    Skip 'D3-D5 (no exit code)'; $script:skipped += 2
}

# ------------------------------------------ E. the teardown reports it by itself

Write-Host 'E the teardown reports a death nobody asked about'
Clear-LastGuiPostmortem
$eErr = Join-Path $tmp 'e.err.log'
$e = Start-OnTestDesktop -Exe $env:ComSpec -Arguments @('/c', 'ping -n 3 127.0.0.1 >nul & exit 4') -StdErr $eErr
Assert 'E1 nothing is reported while it is still running' ((@(Get-LastGuiPostmortem)).Count -eq 0)
$eGone = Wait-Gone -ProcessId $e.Pid -TimeoutSec 60
Assert 'E2 the child exited' $eGone
Remove-TestDesktop
$eBlock = @(Get-LastGuiPostmortem)
Assert 'E3 tearing down reported it without any script asking' `
    ($eBlock.Count -gt 0 -and ($eBlock -join "`n") -like "*pid $($e.Pid)*")
Assert 'E4 the report names the exit code' (($eBlock -join "`n") -like '*exited with 4*')

# ------------------------------- F. a process WE killed is not a mystery death

Write-Host 'F a deliberate kill is not reported as a death'
$td2 = New-TestDesktop
Assert 'F1 a new desktop starts with no postmortem' ((@(Get-LastGuiPostmortem)).Count -eq 0)
$f = Start-OnTestDesktop -Exe $env:ComSpec -Arguments @('/c', 'ping -n 60 127.0.0.1 >nul')
Start-Sleep -Milliseconds 500
Remove-TestDesktop
Assert 'F2 the process the teardown killed is not reported' ((@(Get-LastGuiPostmortem)).Count -eq 0)

# -------------------------------------------- G. a clean exit stays quiet

Write-Host 'G a clean exit stays quiet'
$td3 = New-TestDesktop
$g = Start-OnTestDesktop -Exe $env:ComSpec -Arguments @('/c', 'ping -n 3 127.0.0.1 >nul & exit 0')
$gGone = Wait-Gone -ProcessId $g.Pid -TimeoutSec 60
Assert 'G1 the child exited' $gGone
$reported = Write-TestDesktopPostmortems -WaitSeconds 1
Assert 'G2 an exit 0 produces no block' (($reported -eq 0) -and (@(Get-LastGuiPostmortem)).Count -eq 0)
Remove-TestDesktop

# --------------------------------------------- H. the records outlive teardown

Write-Host 'H the launch records outlive the teardown'
$recs = @(Get-TestLaunchRecords)
Assert 'H1 every launch is still on the record after the desktop is gone' ($recs.Count -ge 1)
Assert 'H2 a record carries what a postmortem needs' `
    ($null -ne $recs[-1].Name -and $null -ne $recs[-1].StartedAt)

} finally {
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this been run against the code as it now stands?". A run with
# skipped arms does not stamp - the question is about coverage, not about
# whether the script exited zero.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard gui-postmortem -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    "ALL PASS ($($script:asserted) assertions$(if ($script:skipped) { ", $($script:skipped) SKIPPED" }))"
    exit 0
} else {
    "$($script:failures) FAILURE(S)"
    exit 1
}
