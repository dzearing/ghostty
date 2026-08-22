# Machine-chooser TEXT FIELD acceptance (T990).
#
# T989 fixed one filter box; this measures the other one that crashed the same
# way. The chooser read its filter EDIT into a 256-unit UTF-16 buffer and
# converted it with `std.unicode.utf16LeToUtf8`, whose error set covers
# malformed UTF-16 and NOT an undersized destination - so the `catch` around it
# looked like an overflow guard and was not one. All three callers hand it a
# 256-BYTE buffer, and 256 UTF-16 units can need 768 bytes, so 256 typed ASCII
# characters (or 86 CJK ones) panicked inside `utf8Encode` and took every pane
# in every window with it.
#
# What is measured, all of it against a chooser that is open and filtering:
#
#   A. the field and the list are found, and an empty filter lists the Local
#      row - the baseline the later arms compare against;
#   B. TYPING past the old threshold leaves the app running. Typed, not set:
#      the crash was per-keystroke, so the arm has to walk through the
#      threshold rather than jump over it - in three-byte characters, because
#      the field caps at 255 UTF-16 units and 255 ASCII ones cannot overflow a
#      256-byte destination (the unfixed build survives 300 typed 'a's, and
#      dies on the 86th CJK one);
#   C. a PASTE of 300 characters, and of 300 three-byte CJK characters - the
#      worst per-unit ratio in the BMP, and the input that crashed at a third
#      of the ASCII length - leaves the app running, with no panic in the log;
#   D. the chooser is still a working chooser afterwards: clearing the filter
#      restores the baseline row count, and a needle that matches the Local row
#      still narrows to it. A survivor that stopped filtering is not a fix.
#
# Teeth: `-NegativeControl` inverts D's "the filter still narrows" assertion,
# which MUST fail. The arms in B and C were teeth-checked against the UNFIXED
# code (the `std.unicode.utf16LeToUtf8` call restored in MachineChooser.zig),
# where B kills the app mid-type and C never gets a chance to run.
#
#   powershell -NoProfile -File test\win32\machine-chooser.ps1
#
# T218-era rules: runs on a BACKGROUND test desktop, so it never takes the
# user's foreground (asserted at the end, not assumed), and only ever touches
# ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = "-t990$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChooserControls.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false
# A drive that throws part way unwinds to `finally` and would otherwise reach
# the summary having scored only the setup - i.e. announce a pass for a run
# that never typed anything.
$script:drove = $false

function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

# The list is owner-drawn and LBS_HASSTRINGS-less, so its item COUNT is the
# filter's whole visible output: `refilter` resets the content and adds one
# item per matching row.
$LB_GETCOUNT = 0x018B
function Get-RowCount([IntPtr]$List) {
    # [int64], never [int]: a dead app answers [int64]::MinValue (nobody
    # replied in time), and casting that to Int32 THROWS - which unwinds the
    # whole drive and replaces the assertion that would have named the crash
    # with a PowerShell stack trace. Let it come back as the sentinel and let
    # the arms score it.
    return [int64](Invoke-TestMessage -Window $List -Message $LB_GETCOUNT)
}

function Test-PidAlive([int]$ProcessId) {
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'MACHINE-CHOOSER ACCEPTANCE' -Reason "$Exe not found"
}
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$tmp = Join-Path $env:TEMP "ghoztty-t990-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'stderr.log'

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # persistence: explicitly off - this script restores nothing and must not
    # inherit whatever panes the previous run left in the manifest.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-Host 'SETUP FAIL: GUI died at launch'
        Write-TestVerdict -Label 'MACHINE-CHOOSER ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: GhozttyWindow not found'
        Write-TestVerdict -Label 'MACHINE-CHOOSER ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opened the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no chooser to score'
        Write-TestVerdict -Label 'MACHINE-CHOOSER ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    Start-Sleep -Milliseconds 600

    # --- A. the field, the list, and the baseline ---------------------------
    Write-Host ''
    Write-Host '=== A: the filter field and the row it starts with ==='
    $filter = Get-ChooserFilterField -Chooser $chooser
    $list = Get-ChooserList -Chooser $chooser
    Assert ($null -ne $filter -and $filter.Class -eq 'Edit') 'the filter field is an EDIT'
    Assert ($null -ne $list) 'the machine list is found'
    if (-not $filter -or -not $list) {
        Write-Host 'SETUP FAIL: no filter/list to drive'
        Write-TestVerdict -Label 'MACHINE-CHOOSER ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $filterHwnd = [IntPtr]$filter.Hwnd
    $listHwnd = [IntPtr]$list.Hwnd

    $baseline = Get-RowCount $listHwnd
    Assert ($baseline -ge 1) "an empty filter lists at least the Local row (rows=$baseline)"

    # --- B. typing past the old threshold -----------------------------------
    Write-Host ''
    Write-Host '=== B: typing a long filter leaves the app running ==='
    # THREE-BYTE characters, typed one at a time - which is how a user met
    # this, since the panic was per-EN_CHANGE. ASCII deliberately is NOT the
    # input here: `GetWindowTextW` caps this field at 255 units, and 255 ASCII
    # characters are 255 bytes, so no amount of ASCII can overflow a 256-byte
    # destination. Measured: the unfixed build survives 300 typed ASCII
    # characters and dies on the 86th CJK one. An arm typing 'a' would have
    # been green against the bug it was written for.
    [void](Send-TestControlText -Control $filterHwnd -Text ([string]([char]0x65E5) * 120) -PerKeyMs 3)
    # Settle before asking, and generously: a panic writes a stack trace for
    # every frame before the process goes, so a liveness check taken too soon
    # beats the death it is looking for. Measured against the unfixed build -
    # at 800ms this arm scored PASS and the corpse was found by the next
    # section, which is a green assertion over a dead app.
    Start-Sleep -Milliseconds 2000
    Assert (Test-PidAlive $app.Pid) 'B typing 120 three-byte characters into the filter leaves the app running'
    Assert (-not (Select-String -Path $errlog -Pattern 'panic:' -Quiet)) 'B no panic reached the app log while typing'
    Assert (Test-TestWindowExists -Window $chooser) 'B the chooser is still open'
    $typedRows = Get-RowCount $listHwnd
    Assert ($typedRows -eq 0) "B the unmatchable needle empties the list (rows=$typedRows)"

    # --- C. pasted text, ASCII and three-byte ------------------------------
    Write-Host ''
    Write-Host '=== C: a paste arrives in one message and still does not crash ==='
    [void](Set-TestControlText -Control $filterHwnd -Text ('b' * 300))
    Start-Sleep -Milliseconds 600
    Assert (Test-PidAlive $app.Pid) 'C a 300-character paste leaves the app running'

    # The widest characters in the BMP cost three UTF-8 bytes each, which is
    # what sizes every destination in this code: 256 units can need 768 bytes,
    # so this input crashed at a third of the ASCII length. Built from a code
    # point rather than pasted into the file, so the script stays ASCII.
    [void](Set-TestControlText -Control $filterHwnd -Text ([string]([char]0x65E5) * 300))
    Start-Sleep -Milliseconds 600
    Assert (Test-PidAlive $app.Pid) 'C a 300-character non-ASCII paste leaves the app running'
    Assert (Test-TestWindowExists -Window $chooser) 'C the chooser survived the non-ASCII paste'
    Assert (-not (Select-String -Path $errlog -Pattern 'panic:' -Quiet)) 'C no panic reached the app log'

    # --- D. and it is still a working chooser -------------------------------
    Write-Host ''
    Write-Host '=== D: the chooser still filters afterwards ==='
    [void](Set-TestControlText -Control $filterHwnd -Text '')
    Start-Sleep -Milliseconds 400
    Assert ((Get-RowCount $listHwnd) -eq $baseline) `
        "D clearing the filter restores every row (rows=$(Get-RowCount $listHwnd), baseline=$baseline)"

    [void](Set-TestControlText -Control $filterHwnd -Text 'loc')
    Start-Sleep -Milliseconds 400
    $narrowed = Get-RowCount $listHwnd
    if ($NegativeControl) {
        $script:negReached = $true
        Write-Host 'NEGATIVE CONTROL: asserting the Local row is filtered OUT by its own name - this run MUST fail'
        Assert ($narrowed -eq 0) "D (inverted): 'loc' matches nothing (really rows=$narrowed)"
    } else {
        Assert ($narrowed -ge 1) "D 'loc' still finds the Local row after the over-long entries (rows=$narrowed)"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D the app survived the whole drive'
    $script:drove = $true
    Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Assert $script:drove 'the drive ran to the end (nothing threw out of it)'
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) -----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
# This script has no skippable sections - it either drives the chooser or fails
# - so a green run is by definition a whole-harness run.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard machine-chooser -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Label 'MACHINE-CHOOSER ACCEPTANCE' -Pass $script:pass -Fail $script:fail
