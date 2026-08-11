# T255 acceptance: a window that ignores WM_CLOSE and WM_SYSCOMMAND is
# BLOCKED by a modal dialog, not broken and not a limitation of the desktop.
#
# The report this closes said a long-lived Ghoztty window on the background
# test desktop "ignores WM_CLOSE and WM_SYSCOMMAND", with three measurements
# behind it: our WM_NCLBUTTONDOWN handler still painted a pressed button, a
# posted AND a sent SC_MAXIMIZE both did nothing, and even a plain WM_CLOSE -
# which has no relationship to the caption bar - did nothing either. The
# conclusion drawn at the time was that the desktop could not adjudicate
# window state, and caption-bar.ps1 SKIPPED its whole window-state section
# on that basis, leaving minimize / maximize+restore / close and the
# maximized WM_NCCALCSIZE inset with no automated coverage at all.
#
# The desktop was never involved. `Window.wndProc`'s WM_CLOSE calls
# `confirmCloseIfNeeded`, which for a pane whose shell has a running child
# raises `ConfirmDialog.show` - and that calls `EnableWindow(owner, FALSE)`
# for the length of its own modal message loop. A DISABLED window is one
# `DefWindowProc` discards every WM_SYSCOMMAND for, so SC_MINIMIZE,
# SC_MAXIMIZE, SC_RESTORE and SC_CLOSE all become no-ops while it is up; a
# second WM_CLOSE only re-enters `confirmCloseIfNeeded` and raises another
# dialog. WM_NCHITTEST, WM_PAINT and our own caption handlers keep answering
# throughout, because the UI thread is pumping perfectly well - which is
# exactly what made a blocked window look like a wedged one.
#
# That state is self-perpetuating and, on a background desktop, invisible:
# nobody sees the dialog, and every probe after the first one reads as dead.
# On the interactive desktop you would simply have seen it.
#
# What this script measures, in one process each:
#
#   A. IDLE SHELL (the control). A pane sitting at a cmd.exe prompt with no
#      descendants: WM_CLOSE closes the window, no dialog is raised, and
#      Get-TestModalBlocker finds nothing. This is the state every GUI
#      acceptance script is actually in, which is why they can drive window
#      state at all.
#   B. BUSY SHELL (the reproduction). The same window with a child process
#      under its shell: WM_CLOSE leaves the window OPEN and DISABLED with a
#      GhozttyConfirmDialog owned by it, and SC_MINIMIZE is a no-op - all
#      three original measurements, on demand.
#   C. REVERSAL (the proof it is the dialog and nothing else). Dismiss that
#      dialog and nothing else changes: the same window is enabled again and
#      the same SC_MINIMIZE iconifies it. A cause you can switch off and back
#      on is a cause; a correlation is not.
#
# NEGATIVE CONTROL: -NegativeControl inverts arm A (asserts the idle window
# does NOT close on WM_CLOSE) and MUST fail. Without it a broken
# Test-TestWindowExists would let every arm here pass for free.
#
# Runs on the background test desktop, so it never takes the user's
# foreground. Only touches ghoztty processes it started from this repo's
# zig-out, on its own pipe suffix.
param([string]$ExePath, [switch]$NegativeControl)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$com = Join-Path (Split-Path $exe -Parent) 'ghoztty.com'
$env:GHOZTTY_PIPE_SUFFIX = '-modalblock'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe

$script:pass = 0
$script:fail = 0
function Ok([string]$m) { $script:pass++; Write-Host "  PASS  $m" }
function Bad([string]$m) { $script:fail++; Write-Host "  FAIL  $m" }
function Check([bool]$c, [string]$m) { if ($c) { Ok $m } else { Bad $m } }

$WM_CLOSE = 0x0010
$WS_MINIMIZE = 0x20000000

# A window with one terminal pane, sized and settled. `--session-persistence=
# false`: this script is about window state, and a restored layout from a
# previous run would change what is in the pane under test.
function Start-Subject {
    $p = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--session-persistence=false',
        '--background=#000000',
        '--window-show-tab-bar=never'
    )
    $w = Wait-TestWindow -ProcessId $p.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($w -eq [IntPtr]::Zero) { throw "SETUP FAIL: no GhozttyWindow for pid $($p.Pid)" }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $w -Width 1000 -Height 640 | Out-Null
    Start-Sleep -Milliseconds 1200
    return [pscustomobject]@{ Proc = $p; Hwnd = $w }
}

# The pane's ghoztty-owned id, via the app's own IPC. Read off the OUTPUT
# rather than an exit code (the harness exit-code rule): the JSON is the
# answer, and a CLI that printed it worked.
function Get-PaneId {
    $raw = & $com +list --json 2>&1 | Out-String
    $doc = $raw | ConvertFrom-Json
    return $doc.data.windows[0].tabs[0].splits.terminal.name
}

function Stop-Subject($s) {
    if ($null -eq $s) { return }
    Stop-Process -Id $s.Proc.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
}

New-TestDesktop | Out-Null
$exitCode = 1
$subject = $null
try {
    Write-Host "T255 modal-block acceptance"
    Write-Host "  exe: $exe"

    # --- A. the control: an idle shell closes on WM_CLOSE --------------------
    $subject = Start-Subject
    $h = $subject.Hwnd
    Check (Test-TestWindowEnabled -Window $h) "A1 a fresh window is enabled (nothing modal at rest)"
    Check ((Get-TestModalBlocker -Window $h) -eq [IntPtr]::Zero) `
        "A2 an enabled window reports no modal blocker"

    Send-TestRawMessage -Window $h -Message $WM_CLOSE | Out-Null
    Start-Sleep -Milliseconds 2000
    $closed = -not (Test-TestWindowExists -Window $h)
    if ($NegativeControl) {
        Check (-not $closed) "NEGATIVE CONTROL: an idle-shell window survives WM_CLOSE (it must not)"
    } else {
        Check $closed "A3 an IDLE shell closes on a plain WM_CLOSE - the desktop adjudicates window state fine"
    }
    Stop-Subject $subject
    $subject = $null

    # --- B. the reproduction: a busy shell blocks on its own dialog ----------
    $subject = Start-Subject
    $h = $subject.Hwnd
    $pane = Get-PaneId
    if (-not $pane) { throw 'SETUP FAIL: +list --json named no pane' }
    # A descendant of the pane's shell. `Surface.shellIsIdle` answers "not
    # idle" for a shell with children, which is what arms confirmCloseIfNeeded.
    # A long ping rather than a sleep: it exists on every Windows box and its
    # lifetime is bounded, so a stranded subject cannot outlive the run.
    & $com +send-keys --target=$pane "ping -n 60 127.0.0.1`n" | Out-Null
    Start-Sleep -Seconds 3

    Send-TestRawMessage -Window $h -Message $WM_CLOSE | Out-Null
    Start-Sleep -Milliseconds 2000

    Check (Test-TestWindowExists -Window $h) "B1 a BUSY shell does not close on WM_CLOSE - the window is still there"
    $blocker = Get-TestModalBlocker -Window $h
    Check ($blocker -ne [IntPtr]::Zero) "B2 something modal is owned by the window"
    $blockerClass = if ($blocker -ne [IntPtr]::Zero) { Get-TestWindowClass -Window $blocker } else { '<none>' }
    # The scrollbar overlay is ALSO a visible owned top-level of this window,
    # so this is the assertion that the blocker is found by behaviour and not
    # by "the first thing that is owned".
    Check ($blockerClass -eq 'GhozttyConfirmDialog') `
        "B3 the blocker is the close-confirmation dialog, not an owned overlay (got '$blockerClass')"
    Check (-not (Test-TestWindowEnabled -Window $h)) `
        "B4 the window is DISABLED while it is up - which is why DefWindowProc drops WM_SYSCOMMAND"

    Send-TestSysCommand -Window $h -Command 'minimize' | Out-Null
    Start-Sleep -Milliseconds 900
    Check (((Get-TestWindowStyle -Window $h) -band $WS_MINIMIZE) -eq 0) `
        "B5 SC_MINIMIZE is a no-op while the dialog is up - the original symptom, on demand"
    # The half that made it look like a wedge rather than a block: the UI
    # thread is answering SENT messages the whole time.
    $hit = Invoke-TestMessage -Window $h -Message 0x0084 `
        -LParam ([IntPtr](([int64]((Get-TestWindowRect -Window $h).Top + 4) -shl 16) -bor `
                          [int64]((Get-TestWindowRect -Window $h).Left + 40)))
    Check ($hit -gt 0) "B6 the window still answers WM_NCHITTEST ($hit) - it is blocked, not wedged"

    # --- C. the reversal: clear the dialog, the same command now works -------
    $cleared = Clear-TestModalBlocker -Window $h -Answer cancel
    Check ($cleared -eq 'GhozttyConfirmDialog') "C1 the blocker is dismissable and names itself (got '$cleared')"
    Start-Sleep -Milliseconds 800
    Check (Test-TestWindowEnabled -Window $h) "C2 the window is enabled again once the dialog is gone"
    Check (Test-TestWindowExists -Window $h) "C3 cancelling left the window open, as a cancel should"

    Send-TestSysCommand -Window $h -Command 'minimize' | Out-Null
    Start-Sleep -Milliseconds 900
    Check (((Get-TestWindowStyle -Window $h) -band $WS_MINIMIZE) -ne 0) `
        "C4 the SAME SC_MINIMIZE now iconifies the window - the dialog was the whole cause"

    Write-Host ""
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($script:pass assertions)"
        $exitCode = 0
    } else {
        Write-Host "$script:fail FAILURE(S) ($script:pass passed)"
        $exitCode = 1
    }
} catch {
    Write-Host ""
    Write-Host "1 FAILURE(S) - $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Stop-Subject $subject
    Remove-TestDesktop
}
exit $exitCode
