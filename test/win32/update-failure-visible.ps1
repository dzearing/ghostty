# T1206 acceptance: an in-app update that cannot be applied SAYS SO.
#
# The defect, from the clean-machine walk on 2026-08-31: a second installer
# transaction collided with the first, and the only thing the user saw was a
# window that said "configuring" and then vanished. Nothing named the cause,
# nothing stayed on screen, and there was no way to tell an update that failed
# from one that never started.
#
# The in-app update path is the half that is entirely ours (Windows Installer
# owns the UI of a double-clicked MSI), so it is the half made loud here: when
# msiexec comes back non-zero, the applier relaunches the terminal and then
# raises Ghoztty's own dialog naming the cause, the remedy, the log and the
# code — and that dialog stays until it is dismissed.
#
# Arms:
#   A  a real msiexec rejection -> dialog, with the terminal already back
#   B  the collision itself (1618) -> the dialog names it in words
#   C  negative control: an update that succeeds raises NO dialog
#   D  wiring the compiler does not check: the other silent path, and the
#      Debug-only seam arm B needs
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) with a
# private IPC endpoint and a per-run LOCALAPPDATA, and never installs anything:
# arm A's package is a fake msiexec rejects, and arms B/C never reach msiexec
# at all.
#
#   powershell -NoProfile -File test\win32\update-failure-visible.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

# The dialog's class and title as ConfirmDialog.zig / update_apply.zig spell
# them. Constants here so a rename has to be deliberate on both sides.
$DIALOG_CLASS = 'GhozttyConfirmDialog'
$DIALOG_TITLE = 'Ghoztty could not finish updating'
$WM_CLOSE = 0x0010

# How long the message may take to appear once the applier has its verdict.
$FEEDBACK_BUDGET_MS = 30000
# How long the dialog must still be there afterwards. The defect was a window
# that closed before it could be read; anything that auto-dismisses fails this.
$PERSIST_MS = 3000

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-t1206-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedApply = $env:GHOZTTY_UPDATE_APPLY
$savedCode = $env:GHOZTTY_UPDATE_MSI_CODE

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 't1206')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

# Production spawns the applier as a COPY in the staging directory, never as
# the installed exe (an applier running out of the directory it clears would
# rename its own image aside). The harness drives the same shape, so what is
# tested is what ships.
$applier = Join-Path $root 'ghoztty-updater.exe'
Copy-Item $Exe $applier -Force

# A file with the compound-document signature and enough bytes to pass the
# app's own "is this really a package" check, so the rejection under test comes
# from msiexec rather than from us.
function New-FakePackage($path) {
    $bytes = New-Object byte[] 65536
    [byte[]]$sig = 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
    [Array]::Copy($sig, $bytes, 8)
    [IO.File]::WriteAllBytes($path, $bytes)
}

# A pid the applier's wait is satisfied by immediately: one that has already
# exited. The wait itself is update-apply.ps1's subject, not this script's.
function New-DeadPid {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
    $null = $p.Handle
    [void]$p.WaitForExit(10000)
    return $p.Id
}

function Get-DialogBody($hwnd) {
    $parts = @()
    foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$hwnd) -Class '*')) {
        $t = Get-TestControlText -Control ([IntPtr]$c.Hwnd)
        if ($t) { $parts += $t }
    }
    return ($parts -join "`n")
}

function Wait-Dialog($procId, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $h = Get-TestWindow -ProcessId $procId -Class $DIALOG_CLASS
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}

function Test-Alive($procId) {
    try { return -not ([System.Diagnostics.Process]::GetProcessById($procId).HasExited) }
    catch { return $false }
}

# Start the applier on the test desktop with a spec, and return its pid plus
# the stderr file it is writing (Debug builds use the console subsystem, so
# std.log lands there).
function Start-Applier($tag, $spec) {
    $err = Join-Path $root "$tag.err.txt"
    $env:GHOZTTY_UPDATE_APPLY = $spec
    try {
        $p = Start-OnTestDesktop -Exe $applier -StdErr $err
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Pid = $p.Pid; Err = $err }
}

# Read the applier's stderr WHILE it still holds the file open - every arm here
# asserts on the log of a process that is deliberately still alive, sitting on
# its modal. `[IO.File]::ReadAllText` opens with FileShare.Read and throws on
# exactly that, so the share mode is spelled out.
function Get-ApplierLog($file) {
    if (-not (Test-Path $file)) { return '' }
    try {
        $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object IO.StreamReader($fs)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return '' }
}

try {
    # ========================================================================
    "== A: an update msiexec refuses is reported, with the terminal already back"
    # ========================================================================
    $tmpA = Join-Path $root 'a'
    New-Item -ItemType Directory -Force $tmpA | Out-Null
    $env:LOCALAPPDATA = $tmpA

    $msiA = Join-Path $root 'apply-me.msi'
    New-FakePackage $msiA
    $appA = Start-Applier 'a' "$(New-DeadPid)|$msiA|$Exe"

    $dlgA = Wait-Dialog $appA.Pid $FEEDBACK_BUDGET_MS
    Assert "A1 the failed update raised Ghoztty's own dialog" ($dlgA -ne [IntPtr]::Zero)

    $titleA = if ($dlgA -ne [IntPtr]::Zero) { Get-TestWindowText -Window $dlgA } else { '' }
    Assert "A2 titled for what happened, not for msiexec (got '$titleA')" ($titleA -eq $DIALOG_TITLE)

    $bodyA = if ($dlgA -ne [IntPtr]::Zero) { Get-DialogBody $dlgA } else { '' }
    # What a person needs: that their terminal survived, what went wrong, what
    # to do, and the two identifiers a bug report is matched on.
    Assert "A3 it says the old version is still there" ($bodyA -match 'still running the version')
    Assert "A4 it names a cause in words" ($bodyA -match 'Windows Installer stopped|package could not be opened|damaged')
    Assert "A5 it says what to do next" ($bodyA -match 'Check for updates again')
    Assert "A6 it points at the log" ($bodyA -match 'install\.log')
    Assert "A7 it carries the numeric code for a bug report" ($bodyA -match 'Windows Installer code \d+')

    # The order that matters: the terminal comes BACK first, and only then is
    # the modal raised. A message that arrives while the terminal is still
    # missing reads as "your terminal is gone".
    $logA = Get-ApplierLog $appA.Err
    Assert "A8 the terminal was relaunched before the dialog went up" `
        ($logA -match 'relaunched .*ghoztty\.exe as pid \d+')

    # The whole defect: a window nobody could read.
    Start-Sleep -Milliseconds $PERSIST_MS
    Assert "A9 the dialog is still on screen $PERSIST_MS ms later - it does not flash and close" `
        (($dlgA -ne [IntPtr]::Zero) -and (Test-TestWindowExists -Window $dlgA))
    Assert "A10 and the applier is still alive holding it" (Test-Alive $appA.Pid)

    if ($dlgA -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $dlgA -Message ([uint32]$WM_CLOSE))
    }
    Start-Sleep -Milliseconds 1500
    Assert "A11 dismissing it lets the applier finish" (-not (Test-Alive $appA.Pid))
    Assert "A12 a package msiexec rejected is kept, not deleted" (Test-Path $msiA)
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== B: the collision the user actually hit is named in words"
    # ========================================================================
    # 1618 (ERROR_INSTALL_ALREADY_RUNNING) cannot be manufactured from outside
    # msiexec - a user-created Global\_MSIExecute does not collide (measured on
    # box 2026-09-01: msiexec ran straight past it), and the only other way to
    # hold that mutex is a real installation, which this script may not start.
    # So the code is forced through the Debug-only seam and everything
    # downstream of it - the message, the reporter, the dialog - is the
    # shipping path.
    $tmpB = Join-Path $root 'b'
    New-Item -ItemType Directory -Force $tmpB | Out-Null
    $env:LOCALAPPDATA = $tmpB

    $msiB = Join-Path $root 'collide.msi'
    New-FakePackage $msiB
    $env:GHOZTTY_UPDATE_MSI_CODE = '1618'
    try {
        $appB = Start-Applier 'b' "$(New-DeadPid)|$msiB|$Exe"
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    }

    $dlgB = Wait-Dialog $appB.Pid $FEEDBACK_BUDGET_MS
    Assert "B1 the collided transaction raised a dialog" ($dlgB -ne [IntPtr]::Zero)
    $bodyB = if ($dlgB -ne [IntPtr]::Zero) { Get-DialogBody $dlgB } else { '' }
    Assert "B2 it says another installation is already running" `
        ($bodyB -match 'Another installation is already running')
    Assert "B3 it tells the user to wait for it and try again" `
        ($bodyB -match 'Wait for the other installation')
    Assert "B4 the code is there for a bug report, but not the whole message" `
        (($bodyB -match '1618') -and ($bodyB.Length -gt 200))
    $logB = Get-ApplierLog $appB.Err
    Assert "B5 the seam skipped msiexec rather than running one" ($logB -notmatch 'msiexec\.exe /i')
    Assert "B6 the terminal came back from the collision too" `
        ($logB -match 'relaunched .*ghoztty\.exe as pid \d+')

    if ($dlgB -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $dlgB -Message ([uint32]$WM_CLOSE))
    }
    Start-Sleep -Milliseconds 1500
    Assert "B7 dismissing it lets the applier finish" (-not (Test-Alive $appB.Pid))
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== C: negative control - an update that WORKS says nothing"
    # ========================================================================
    # Without this arm every assertion above is also satisfied by a build that
    # raises the dialog on every update, which would be a worse defect than the
    # silence it replaced.
    $tmpC = Join-Path $root 'c'
    New-Item -ItemType Directory -Force $tmpC | Out-Null
    $env:LOCALAPPDATA = $tmpC

    $msiC = Join-Path $root 'ok.msi'
    New-FakePackage $msiC
    $env:GHOZTTY_UPDATE_MSI_CODE = '0'
    try {
        $appC = Start-Applier 'c' "$(New-DeadPid)|$msiC|$Exe"
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Alive $appC.Pid) -and $sw.ElapsedMilliseconds -lt $FEEDBACK_BUDGET_MS) {
        Start-Sleep -Milliseconds 200
    }
    Assert "C1 a successful apply finishes on its own, with nothing to dismiss" `
        (-not (Test-Alive $appC.Pid))
    Assert "C2 and raised NO dialog" `
        (@(Get-TestWindows -ProcessId $appC.Pid -Class $DIALOG_CLASS -AllowHidden).Count -eq 0)
    Assert "C3 the applied package was cleaned up" (-not (Test-Path $msiC))
    $logC = Get-ApplierLog $appC.Err
    Assert "C4 and the log records a success, not a failure" `
        (($logC -match 'msiexec succeeded') -and ($logC -notmatch 'could not finish updating'))
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== D: the wiring no compiler checks"
    # ========================================================================
    $instSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\update_install.zig'))
    $applySrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\update_apply.zig'))

    # The other silent outcome on this path: the app never exited, so nothing
    # was installed and the user was told nothing. A 2-minute wait is not worth
    # a live arm; that it is REPORTED is.
    Assert "D1 the 'app never closed' path reports instead of returning quietly" `
        ($instSrc -match 'report\(update_apply\.describeAppStillRunning')
    Assert "D2 and a non-zero msiexec code reports too" `
        ($instSrc -match 'report\(update_apply\.describeFailure\(&buf, code, log_path\)\)')
    Assert "D3 the report goes up AFTER the relaunch, so the terminal is back first" `
        ($instSrc -match '(?s)const relaunched = relaunch\(arena, spec\.exe\);.*?if \(code != 0\) \{')
    # The seam arm B depends on must not exist in anything shipped.
    Assert "D4 the msiexec-code seam is compiled out of every non-Debug build" `
        ($instSrc -match 'if \(comptime builtin\.mode != \.Debug\) return null;')
    Assert "D5 the dialog title is the one constant both sides read" `
        ($applySrc -match 'pub const failure_title = "Ghoztty could not finish updating";')

    # LAST statement of the top-level try (T1039): an unwind from anywhere
    # above must not reach the verdict as if the run had finished.
    Complete-TestBody
} finally {
    Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
    if ($savedCode) { $env:GHOZTTY_UPDATE_MSI_CODE = $savedCode }
    if ($savedApply) { $env:GHOZTTY_UPDATE_APPLY = $savedApply }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Write-Host "logs kept in $root" }
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-failure-visible -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'update-failure-visible' -MinPass 24
