# Startup-failure visibility acceptance (tracker T1177).
#
# THE DEFECT: `ghoztty.exe` is a GUI-subsystem binary, so it has no console and
# nothing it writes to stderr is ever seen. Every startup error therefore
# unwound out of `main` into nothing at all - the process exited, no window
# appeared, and the user was left looking at a shortcut that did nothing. On a
# freshly installed machine that is the entire experience: silence, and then,
# minutes later, some unrelated probe timing out. The user's words were "this is
# a completely unacceptable user experience".
#
# THE CONTRACT this asserts:
#
#   1. A startup that ends with NO WINDOW raises a dialog instead of exiting
#      silently. The dialog is Ghoztty's own dark one (class
#      `GhozttyConfirmDialog`), titled "Ghoztty could not start".
#   2. It arrives FAST - seconds, not after any probe deadline. Asserted as a
#      measured elapsed time, not as "it eventually showed up".
#   3. Its text is written for a person: it names the stage, the error, a
#      remedy, and where the log is. A dialog that says only "error 5" would
#      pass a mere existence check and fail the user, so the BODY is read back
#      out of the live dialog (WM_GETTEXT on its statics) and asserted on.
#   4. Dismissing it ends the process with a NONZERO exit code - a failed launch
#      must not look like a successful one to whatever started it (the
#      installer's launch step, T1176, is now one such caller).
#   5. The negative control: with the seam off, the same build opens a real
#      window and raises NO such dialog. Without this arm every assertion above
#      would still pass against a build that shows the dialog unconditionally.
#   6. A display that cannot run the renderer is EXPLAINED rather than blamed on
#      the install (T1224). Over Remote Desktop the display driver offers
#      OpenGL 1.1, Ghoztty needs 4.3, and the dialog the user got said
#      "reinstall it" - the one remedy that cannot possibly work. Arm E reads
#      the live dialog back and asserts it names the version actually found,
#      names Remote Desktop as the usual cause, and does NOT send the user to
#      reinstall.
#
# The state in arm 1-4 is built with `GHOZTTY_STARTUP_FAIL=no-window`, a
# DEBUG-ONLY seam in `App.run` that suppresses the startup window. It is the
# same shape as the `GHOZTTY_RESTORE_SKIP` seam beside it and it exists for the
# same reason: there is no supported way to make window creation fail from
# outside the process, and the alternative is a guard nobody has ever seen fire.
# The seam suppresses the WINDOW, never the guard - so what runs here is the
# shipping guard, the shipping error, the shipping reporter and the shipping
# dialog.
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground, and hermetically: private IPC endpoint,
# per-run $env:LOCALAPPDATA, and it only ever kills ghoztty processes launched
# from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\startup-failure.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
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

# The dialog's own class and title, as ConfirmDialog.zig / startup_error.zig
# spell them. Asserted as constants here so a rename has to be deliberate.
$DIALOG_CLASS = 'GhozttyConfirmDialog'
$DIALOG_TITLE = 'Ghoztty could not start'
$WM_CLOSE = 0x0010

# How long a startup failure may take to become visible. The user-facing
# promise is "immediately, not after a probe timeout"; the agent probe alone is
# bounded at 2s, so anything past this is the old behaviour creeping back.
$FEEDBACK_BUDGET_MS = 10000

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-startup-failure-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedSeam = $env:GHOZTTY_STARTUP_FAIL
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedGlSeam = $env:GHOZTTY_GL_FORCE_VERSION

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

# Private endpoint first (T441), then the build-lineage check: a private pipe
# suffix moves the APP endpoint only, so the exe is checked for the -debug
# lineage rather than assumed (T1033).
[void](Set-GhozttyTestIsolation -Tag 'startupfail')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

# Read every static in the dialog and join it - the message, the buttons and
# any note, which is all a user can see. WM_GETTEXT (Get-TestControlText), not
# GetWindowTextW: the latter is cross-process cached and reads stale.
function Get-DialogBody($hwnd) {
    $parts = @()
    foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$hwnd) -Class '*')) {
        $t = Get-TestControlText -Control ([IntPtr]$c.Hwnd)
        if ($t) { $parts += $t }
    }
    return ($parts -join "`n")
}

# Poll for the first top-level $DIALOG_CLASS window of $procId, returning the
# elapsed milliseconds alongside the handle so arm A can assert on the WAIT
# rather than just on the outcome.
function Wait-Dialog($procId, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $h = Get-TestWindow -ProcessId $procId -Class $DIALOG_CLASS
        if ($h -ne [IntPtr]::Zero) {
            return [pscustomobject]@{ Hwnd = $h; ElapsedMs = $sw.ElapsedMilliseconds }
        }
        Start-Sleep -Milliseconds 100
    }
    return [pscustomobject]@{ Hwnd = [IntPtr]::Zero; ElapsedMs = $sw.ElapsedMilliseconds }
}

try {
    # ========================================================================
    "== A: a startup that produces no window raises a dialog, fast"
    # ========================================================================
    $tmpA = Join-Path $root 'a'
    New-Item -ItemType Directory -Force $tmpA | Out-Null
    $env:LOCALAPPDATA = $tmpA
    $env:GHOZTTY_STARTUP_FAIL = 'no-window'

    $appA = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1177-a')
    # Cache the process HANDLE now, while the process is alive: without it
    # `.ExitCode` reads back EMPTY once it exits, and `'' -ne 0` is $true - so
    # arm B2 would score a pass no matter what the app exited with
    # (lib\ExitCodeAudit.ps1; it has cost this suite six fabricated results).
    $procA = $appA.Process
    if ($procA) { $null = $procA.Handle }
    $found = Wait-Dialog $appA.Pid $FEEDBACK_BUDGET_MS

    Assert "A1 the failure raised Ghoztty's own error dialog" `
        ($found.Hwnd -ne [IntPtr]::Zero)
    Assert "A2 it arrived within ${FEEDBACK_BUDGET_MS}ms (measured $($found.ElapsedMs)ms)" `
        ($found.Hwnd -ne [IntPtr]::Zero -and $found.ElapsedMs -lt $FEEDBACK_BUDGET_MS)

    $title = if ($found.Hwnd -ne [IntPtr]::Zero) { Get-TestWindowText -Window $found.Hwnd } else { '' }
    Assert "A3 titled '$DIALOG_TITLE' (got '$title')" ($title -eq $DIALOG_TITLE)

    $body = if ($found.Hwnd -ne [IntPtr]::Zero) { Get-DialogBody $found.Hwnd } else { '' }
    Assert "A4 the body names what was underway" `
        ($body -match 'opening its first window')
    Assert "A5 the body names the error, so a bug report can quote it" `
        ($body -match 'NoStartupWindow')
    Assert "A6 the body tells the user what to DO about it" `
        ($body -match 'Restart it')
    Assert "A7 the body points at the log" ($body -match 'ghoztty\.log')

    # The whole point: no terminal window ever appeared, and the app did not
    # simply vanish either.
    Assert "A8 no terminal window came up (the state the dialog is reporting)" `
        (@(Get-TestWindows -ProcessId $appA.Pid -Class 'GhozttyWindow' -AllowHidden).Count -eq 0)

    # ========================================================================
    "== B: dismissing it ends the process with a failure exit code"
    # ========================================================================
    if ($found.Hwnd -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $found.Hwnd -Message ([uint32]$WM_CLOSE))
    }
    $exited = $false
    $exitCode = $null
    if ($procA) {
        $exited = $procA.WaitForExit(10000)
        if ($exited) { $exitCode = $procA.ExitCode }
    }
    Assert "B1 the process exited once the dialog was dismissed" $exited
    # `-is [int]` is the half that makes this an assertion rather than a wish:
    # an unreadable exit code is $null, and `$null -ne 0` is $true.
    Assert "B2 it exited NONZERO, so a launcher can tell the launch failed (got $exitCode)" `
        ($exited -and ($exitCode -is [int]) -and $exitCode -ne 0)

    # ========================================================================
    "== C: negative control - a healthy launch shows a window and no dialog"
    # ========================================================================
    # Without this arm every assertion above is also satisfied by a build that
    # raises the dialog on every launch, which would be a far worse defect than
    # the one being fixed.
    $env:GHOZTTY_STARTUP_FAIL = $null
    Remove-Item env:GHOZTTY_STARTUP_FAIL -ErrorAction SilentlyContinue
    $tmpC = Join-Path $root 'c'
    New-Item -ItemType Directory -Force $tmpC | Out-Null
    $env:LOCALAPPDATA = $tmpC

    $appC = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1177-c')
    $winC = Wait-TestWindow -ProcessId $appC.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    Assert "C1 the healthy launch opened a terminal window" ($winC -ne [IntPtr]::Zero)
    Assert "C2 and raised NO startup-failure dialog" `
        (@(Get-TestWindows -ProcessId $appC.Pid -Class $DIALOG_CLASS -AllowHidden).Count -eq 0)

    $stillUp = $false
    try { $stillUp = -not ([System.Diagnostics.Process]::GetProcessById($appC.Pid).HasExited) } catch { }
    Assert "C3 and is still running" $stillUp

    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)

    # ========================================================================
    "== D: a missing session agent is SAID, not silently absorbed"
    # ========================================================================
    # The other half of the same defect, and the half a half-installed Ghoztty
    # actually hits (T1175: the agent used to ship as its own installer). The
    # app can run without the agent - so this is a NOTICE beside a working
    # terminal, not a refusal - but the old behaviour was a `log.warn` nobody
    # would ever read and a feature that had quietly stopped existing.
    $tmpD = Join-Path $root 'd'
    New-Item -ItemType Directory -Force $tmpD | Out-Null
    $env:LOCALAPPDATA = $tmpD
    $env:GHOSTTY_LOCAL_AGENT_BIN = Join-Path $tmpD 'no-such-ghoztty-agent.exe'

    $appD = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1177-d')
    $winD = Wait-TestWindow -ProcessId $appD.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    Assert "D1 the terminal still opens without an agent (degraded, not fatal)" `
        ($winD -ne [IntPtr]::Zero)

    $noticeD = Wait-Dialog $appD.Pid 20000
    Assert "D2 and a notice says the session agent is missing" `
        ($noticeD.Hwnd -ne [IntPtr]::Zero)
    $titleD = if ($noticeD.Hwnd -ne [IntPtr]::Zero) { Get-TestWindowText -Window $noticeD.Hwnd } else { '' }
    Assert "D3 titled for what the user LOSES, not for the mechanism (got '$titleD')" `
        ($titleD -eq 'Session persistence unavailable')
    $bodyD = if ($noticeD.Hwnd -ne [IntPtr]::Zero) { Get-DialogBody $noticeD.Hwnd } else { '' }
    Assert "D4 the body names the consequence and the remedy" `
        ($bodyD -match 'not survive' -and $bodyD -match 'Reinstall Ghoztty')

    if ($noticeD.Hwnd -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $noticeD.Hwnd -Message ([uint32]$WM_CLOSE))
    }
    Start-Sleep -Milliseconds 800
    $stillUpD = $false
    try { $stillUpD = -not ([System.Diagnostics.Process]::GetProcessById($appD.Pid).HasExited) } catch { }
    Assert "D5 dismissing it leaves the terminal running (a notice, not a refusal)" $stillUpD

    # ========================================================================
    "== E: a display that cannot run the renderer is explained, not blamed on the install"
    # ========================================================================
    # The Remote Desktop failure (T1224). An RDP session's display driver offers
    # OpenGL 1.1 because the desktop is encoded and shipped over the wire rather
    # than scanned out of a GPU; Ghoztty needs 4.3, so it refuses to start - and
    # the refusal the user actually got told them to reinstall, which cannot
    # change a display driver. The state is built with
    # `GHOZTTY_GL_FORCE_VERSION=1.1`, a DEBUG-ONLY seam in the renderer's
    # context load, because there is no way to make a local GPU report 1.1 from
    # outside the process and an RDP box is not something this suite can stand
    # up. The seam moves the reported VERSION only: what runs here is the
    # shipping floor check, the shipping error, the shipping reporter and the
    # shipping dialog text.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $tmpE = Join-Path $root 'e'
    New-Item -ItemType Directory -Force $tmpE | Out-Null
    $env:LOCALAPPDATA = $tmpE
    Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
    $env:GHOZTTY_GL_FORCE_VERSION = '1.1'

    $appE = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1224-e')
    $procE = $appE.Process
    if ($procE) { $null = $procE.Handle }
    $foundE = Wait-Dialog $appE.Pid $FEEDBACK_BUDGET_MS
    Assert "E1 an unrunnable display raises the startup dialog" `
        ($foundE.Hwnd -ne [IntPtr]::Zero)

    $bodyE = if ($foundE.Hwnd -ne [IntPtr]::Zero) { Get-DialogBody $foundE.Hwnd } else { '' }
    Assert "E2 the body names the error, so a bug report can quote it" `
        ($bodyE -match 'OpenGLOutdated')
    Assert "E3 it names the OpenGL the display ACTUALLY offers" `
        ($bodyE -match 'OpenGL 1\.1')
    Assert "E4 it names the version Ghoztty needs" `
        ($bodyE -match 'OpenGL 4\.3')
    Assert "E5 it names Remote Desktop, the usual cause" `
        ($bodyE -match 'Remote Desktop')
    # The defect itself: reinstalling cannot change a display driver, so the
    # dialog must not send the user to do it.
    Assert "E6 it does NOT tell the user to reinstall" `
        ($bodyE -notmatch 'Reinstall Ghoztty' -and $bodyE -notmatch 'reinstall it')
    Assert "E7 it still points at the log" ($bodyE -match 'ghoztty\.log')

    if ($foundE.Hwnd -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $foundE.Hwnd -Message ([uint32]$WM_CLOSE))
    }
    $exitedE = $false
    $exitCodeE = $null
    if ($procE) {
        $exitedE = $procE.WaitForExit(10000)
        if ($exitedE) { $exitCodeE = $procE.ExitCode }
    }
    Assert "E8 it exited NONZERO, like every other failed launch (got $exitCodeE)" `
        ($exitedE -and ($exitCodeE -is [int]) -and $exitCodeE -ne 0)

    Remove-Item env:GHOZTTY_GL_FORCE_VERSION -ErrorAction SilentlyContinue

    # LAST statement of the top-level try (T1039): an unwind from anywhere above
    # must not be able to reach the verdict as if the run had finished.
    Complete-TestBody
} finally {
    Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
    if ($savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    if ($savedSeam) { $env:GHOZTTY_STARTUP_FAIL = $savedSeam }
    else { Remove-Item env:GHOZTTY_STARTUP_FAIL -ErrorAction SilentlyContinue }
    if ($savedGlSeam) { $env:GHOZTTY_GL_FORCE_VERSION = $savedGlSeam }
    else { Remove-Item env:GHOZTTY_GL_FORCE_VERSION -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard startup-failure -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'startup-failure' -MinPass 15
