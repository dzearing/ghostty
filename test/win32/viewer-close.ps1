# T1356 acceptance: closing a viewer pane - and the window around one - must
# not take the app down with it.
#
# WHAT BROKE. A ViewerPane's `deinit` calls `ICoreWebView2Controller::Close`,
# and that call PUMPS MESSAGES. Anything dispatched during the pump runs while
# the pane is half-freed: on 2026-09-05 a WM_SETFOCUS landed on the viewer's
# own host window, its arm called `Window.updateDimOverlays`, and that sweep
# walked `tab_trees` - which still held the pane being freed, because every
# teardown site deinit'ed the OLD tree while it was still installed in the
# window. `PaneView.showDimOverlay` then dereferenced a freed surface and the
# WHOLE PROCESS died with STATUS_FATAL_USER_CALLBACK_EXCEPTION, taking every
# other window and every unsaved pane with it.
#
# WHY NOTHING ELSE CAUGHT IT. Every viewer harness on this box opens viewers
# and lets the desktop teardown reap the process; none of them CLOSES a window
# that owns one and then keeps asserting. `viewer-narrow-pane.ps1` found the
# crash by accident and then stopped closing its probe window to get around it
# (the comment there names this task), which is the shape of a defect becoming
# permanent: the one script that could see it was edited until it could not.
# So the close is the subject here rather than the cleanup.
#
# WHAT IS ASSERTED, and why each case is a different code path:
#
#   A. `+close` on a WINDOW holding one viewer pane. The whole-window path
#      (`Window.close` -> `cleanupAllSurfaces`). The app must still be running
#      afterwards, the other window must still answer `+list`, and the closed
#      target must be gone.
#   B. `+close` on a window holding a TERMINAL pane AND a focused viewer pane.
#      THE SHAPE THAT ACTUALLY CRASHED, and the reason this script has five
#      sections instead of three: the fault dereferenced a freed *Surface*, so
#      the sweep needs a terminal leaf to walk back over. A window of viewers
#      alone (C) survived even the broken build.
#   C. `+close` on a window holding TWO viewer panes - two controllers closing
#      inside one teardown, so the second one pumps with the first already
#      freed.
#   D. `+close` on a single viewer PANE inside a split, beside a terminal. A
#      different site (`closeSplitPane`), which swaps in a new tree; the window
#      survives and keeps its other pane.
#   E. Closing the LAST window, where the close IS the shutdown. The process
#      must EXIT CLEANLY - `Get-GuiPostmortem` reads the real exit code, so a
#      crash here is named (`CRASHED - 0xC000041D ...`) rather than passing as
#      "the process is gone, which is what we wanted".
#
# Liveness is measured two ways on purpose. `HasExited` on the launched process
# object is the cheap answer; `+list` answering over the IPC pipe is the one
# that says the app is still SERVING rather than merely still resident, which
# is the difference between a survivor and a process stuck unwinding.
#
#   powershell -NoProfile -File test\win32\viewer-close.ps1
#
# -NegativeControl inverts every survival assertion - it demands the app be
# DEAD after each close. On a fixed build it MUST fail with exactly FIVE
# failures, one per section, which is what proves these assertions read real
# liveness rather than a constant.
#
# THE OTHER CONTROL, and the one that matters most, was run by hand against the
# pre-fix `Window.zig` on 2026-09-05: section B FAILED there with
# `CRASHED - 0xC000041D STATUS_FATAL_USER_CALLBACK_EXCEPTION`, the same code the
# original report carries. That is the evidence that this script can score red
# on the defect it exists for - a gate nobody has watched fail is not a gate
# (T1133). Getting there took three drafts: a window of viewers alone survives
# the broken build, and so does a terminal+viewer window with no contents card
# up. The card is load-bearing, which is why section B asserts it is there.
param([string]$ExePath, [switch]$Interactive, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vcl$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
# Arms the run (T1039): the dot-source itself, so a body that unwinds cannot
# reach `Complete-TestBody` and cannot be scored green - or stamp its guard.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1127: everything running out of this build's directory is reaped when this
# PowerShell exits.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The survival assertion, in one place so -NegativeControl can invert all four
# at once. `$Alive` is what the run measured; the control demands the opposite.
function Assert-Survived([bool]$Alive, [string]$Label) {
    if ($NegativeControl) {
        Assert (-not $Alive) "$Label (NEGATIVE CONTROL: asserting the app DIED)"
    } else {
        Assert $Alive $Label
    }
}

function Invoke-Verb([string[]]$VerbArgs) {
    # A PIPE, never a `>` redirect (T245), and each object stringified before
    # Out-String (T526): a consoleless host formats an ErrorRecord as a blank
    # line while its ToString() keeps the text.
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Win([string]$target) {
    $d = Get-Data
    if (-not $d) { return $null }
    foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Wait-NoWin([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        if (-not (Get-Win $target)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-PaneCount([string]$target) {
    $w = Get-Win $target
    if (-not $w) { return 0 }
    return @(Get-Leaves $w.tabs[0].splits).Count
}

# A viewer host window with real bounds under this process: the proof that the
# viewer pane actually EXISTS before we go and close it. Without this the
# sections would happily close windows that never grew a WebView2 and score a
# crash-free run that proved nothing.
function Wait-ViewerHost([int]$ProcessId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
            foreach ($h in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'GhozttyViewer')) {
                if ($h.Width -gt 0 -and $h.Height -gt 0) { return $true }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The viewer's CONTENTS CARD, if this pane has one up. It is a child window of
# the viewer host (`GhozttyViewerTOC`) and therefore a second thing the
# teardown destroys - and a focus target while it is up, which is what puts a
# focus message into the `Close` pump that follows. Section B asserts one
# exists before it closes anything, because a window WITHOUT a card is a
# simpler teardown than the one that crashed.
function Get-TocCard([int]$ProcessId) {
    foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
        foreach ($vh in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'GhozttyViewer')) {
            foreach ($c in @(Get-TestChildWindows -Window ([IntPtr][int64]$vh.Hwnd) -Class 'GhozttyViewerTOC')) {
                if ($c.Width -gt 0 -and $c.Height -gt 0) {
                    return [pscustomobject]@{ Top = [IntPtr][int64]$w.Hwnd; Card = [IntPtr][int64]$c.Hwnd }
                }
            }
        }
    }
    return $null
}

function Wait-TocCard([int]$ProcessId) {
    for ($t = 0; $t -lt 40; $t++) {
        $c = Get-TocCard $ProcessId
        if ($c) { return $c }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Still serving, not merely still resident (see the header).
function Test-AppServing {
    for ($t = 0; $t -lt 20; $t++) {
        if (Get-Data) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$docDir = Join-Path $env:TEMP "ghoztty-viewer-close-$PID"
New-Item -ItemType Directory -Force -Path $docDir | Out-Null
$doc1 = Join-Path $docDir 'one.md'
$doc2 = Join-Path $docDir 'two.md'
# Many headings on purpose: that is what makes the viewer build its CONTENTS
# CARD, which is a second popup window the pane owns and destroys during the
# same teardown. The reproduction found on 2026-09-05 had one open, and a card
# that is up is a focus target - so its destruction is what puts a focus
# message into the WebView2 `Close` pump that follows.
$headings = (1..60 | ForEach-Object { "## Heading $_`n`nSome text under heading $_.`n" }) -join "`n"
Set-Content -Path $doc1 -Value "# One`n`n$headings" -Encoding utf8
Set-Content -Path $doc2 -Value "# Two`n`n$headings" -Encoding utf8

$errlog = Join-Path $env:TEMP "ghoztty-viewer-close-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$since = Get-Date

try {
    # One app for the whole run. That is deliberate rather than economical:
    # sections A-C each close something and then keep asserting against the
    # SAME process, so "the app survived" accumulates instead of being re-asked
    # of a fresh launch that could not have died yet.
    # `--quit-after-last-window-closed=true` is what makes section D a
    # SHUTDOWN. It defaults to false on Windows (the app sits there with no
    # windows), so without it D's last close would be just another window
    # teardown and the case it exists to cover - the one where the crash is
    # indistinguishable from a clean quit - would never be entered. With no
    # delay configured the quit is immediate, so the wait below is bounded by
    # the app's own unwind rather than by a timer.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--session-persistence=false', '--config-default-files=false',
        '--quit-after-last-window-closed=true')
    Start-Sleep -Seconds 3
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI came up'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT on the interactive desktop'
    $baseTop = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 15000
    Assert ($baseTop -ne [IntPtr]::Zero) 'the launch window exists (the one that must OUTLIVE every close below)'

    # =====================================================================
    # A. +close on a window holding ONE viewer pane
    # =====================================================================
    Write-Host ''
    Write-Host 'A. a window with one viewer pane'
    $r = Invoke-Verb @('+new-window', '--target=vc1', "--view=$doc1")
    Assert ($r.Code -eq 0) "A: +new-window --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
    Assert ($null -ne (Wait-Win 'vc1')) 'A: the viewer window is listed'
    Assert (Wait-ViewerHost $app.Pid) 'A: a viewer host window with real bounds exists (the pane is really there)'

    $r = Invoke-Verb @('+close', '--target=vc1')
    Assert ($r.Code -eq 0) "A: +close exits 0 (got $($r.Code): $($r.Out.Trim()))"
    Start-Sleep -Milliseconds 1500
    $aliveA = (-not ($app.Process -and $app.Process.HasExited))
    Assert-Survived $aliveA 'A: the app is still running after closing the window that held the viewer'
    if ($aliveA) {
        Assert (Test-AppServing) 'A: the app still answers +list (serving, not stuck unwinding)'
        Assert (Wait-NoWin 'vc1') 'A: the closed window is gone from +list'
    }

    # =====================================================================
    # B. +close on a window holding a TERMINAL pane and a VIEWER pane
    # =====================================================================
    # THE REPORTED SHAPE, and the one that actually reproduces. The crash
    # dereferenced a freed *Surface* (`PaneView.showDimOverlay`'s `.terminal`
    # arm), so the window has to contain a terminal for the sweep to have one
    # to walk: the tree teardown frees the terminal leaf, the viewer leaf's
    # `deinit` then pumps inside `Close`, a focus message is dispatched, and
    # `updateDimOverlays` walks back over the leaf that is already gone. A
    # window of viewers alone - section C - never crashed on the broken build,
    # which is exactly why this case is separate from that one rather than
    # folded into it.
    Write-Host ''
    Write-Host 'B. a window with a terminal pane and a viewer pane (the reported repro)'
    $aliveB2 = $false
    if ($aliveA) {
        $r = Invoke-Verb @('+new-window', '--target=vc5')
        Assert ($r.Code -eq 0) "B: +new-window (terminal) exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc5')) 'B: the terminal window is listed'
        $r = Invoke-Verb @('+split', '--target=vc5', '--name=vc5b', "--view=$doc1")
        Assert ($r.Code -eq 0) "B: +split --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
        $panes = 0
        for ($t = 0; $t -lt 30 -and $panes -lt 2; $t++) { $panes = Get-PaneCount 'vc5'; if ($panes -lt 2) { Start-Sleep -Milliseconds 200 } }
        Assert ($panes -eq 2) "B: the window has a terminal and a viewer (got $panes panes)"
        Assert (Wait-ViewerHost $app.Pid) 'B: the viewer host window exists'
        # Focus the viewer, so the pane whose `Close` pumps is the one holding
        # focus - which is what puts a focus message into that pump. `+split`
        # with an existing `--name` is documented to FOCUS that pane instead of
        # creating a second one, so this is a focus request that needs no key
        # synthesis (dead on the background test desktop anyway).
        [void](Invoke-Verb @('+split', '--target=vc5', '--name=vc5b', "--view=$doc1"))
        # Long enough for the page to render and the contents card to slide in:
        # the card is the second popup the teardown destroys, and closing
        # before it exists tests a simpler window than the one that crashed.
        Start-Sleep -Seconds 3
        Assert ((Get-PaneCount 'vc5') -eq 2) 'B: focusing the viewer created no extra pane (the idempotent path)'

        # Give the viewer most of a WIDE window. The contents card only takes
        # its gutter presentation - the one that is on screen with no toggle -
        # past 720 DIP of pane, so a default-sized window has no card at all
        # and would test a simpler teardown than the one that crashed.
        $probeTop = [IntPtr]::Zero
        foreach ($t in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
            if (@(Get-TestChildWindows -Window ([IntPtr][int64]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
                $probeTop = [IntPtr][int64]$t.Hwnd
            }
        }
        if ($probeTop -ne [IntPtr]::Zero) {
            [void](Set-TestWindowPos -Window $probeTop -X 0 -Y 0 -Width 1400 -Height 900)
            Start-Sleep -Milliseconds 800
        }
        $wB = Get-Win 'vc5'
        if ($wB) {
            $leavesB = @(Get-Leaves $wB.tabs[0].splits)
            $termB = @($leavesB | Where-Object { $_.type -ne 'viewer' })
            $viewB = @($leavesB | Where-Object { $_.type -eq 'viewer' })
            if ($termB.Count -eq 1 -and $viewB.Count -eq 1) {
                $layoutB = '{"direction":"horizontal","ratio":15,"left":{"pane":"' +
                    $termB[0].name + '"},"right":{"pane":"' + $viewB[0].name + '"}}'
                [void](Invoke-Verb @('+rearrange', '--target=vc5',
                    ('--layout=' + ($layoutB -replace '"', '\"'))))
                Start-Sleep -Milliseconds 1500
            }
        }
        Assert ($null -ne (Wait-TocCard $app.Pid)) `
            'B: the viewer has its contents card up (the second popup the teardown has to destroy)'

        $r = Invoke-Verb @('+close', '--target=vc5')
        Assert ($r.Code -eq 0) "B: +close exits 0 (got $($r.Code))"
        Start-Sleep -Milliseconds 2000
        $aliveB2 = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveB2 'B: the app is still running after closing a window holding a terminal AND a viewer'
        if ($aliveB2) {
            Assert (Test-AppServing) 'B: the app still answers +list'
            Assert (Wait-NoWin 'vc5') 'B: the closed window is gone from +list'
        }
    } else {
        Write-Host '  SKIP B: the app did not survive section A'
    }

    # =====================================================================
    # C. +close on a window holding TWO viewer panes
    # =====================================================================
    Write-Host ''
    Write-Host 'C. a window with two viewer panes'
    if ($aliveB2) {
        $r = Invoke-Verb @('+new-window', '--target=vc2', "--view=$doc1")
        Assert ($r.Code -eq 0) "C: +new-window --view exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc2')) 'C: the window is listed'
        $r = Invoke-Verb @('+split', '--target=vc2', '--name=vc2b', "--view=$doc2")
        Assert ($r.Code -eq 0) "C: +split --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
        $panes = 0
        for ($t = 0; $t -lt 30 -and $panes -lt 2; $t++) { $panes = Get-PaneCount 'vc2'; if ($panes -lt 2) { Start-Sleep -Milliseconds 200 } }
        Assert ($panes -eq 2) "C: the window has both viewer panes (got $panes)"

        $r = Invoke-Verb @('+close', '--target=vc2')
        Assert ($r.Code -eq 0) "C: +close exits 0 (got $($r.Code))"
        Start-Sleep -Milliseconds 1500
        $aliveC2 = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveC2 'C: the app is still running after closing a window with TWO viewer panes'
        if ($aliveC2) {
            Assert (Test-AppServing) 'C: the app still answers +list'
            Assert (Wait-NoWin 'vc2') 'C: the closed window is gone from +list'
        }
    } else {
        Write-Host '  SKIP C: the app did not survive an earlier section'
    }

    # =====================================================================
    # D. +close on ONE viewer pane inside a split (closeSplitPane)
    # =====================================================================
    Write-Host ''
    Write-Host 'D. one viewer pane out of a split'
    $aliveD = $false
    if (-not ($app.Process -and $app.Process.HasExited)) {
        # A TERMINAL root with a viewer split, for the reason section B gives:
        # `closeSplitPane` frees the viewer, and the sweep that runs inside its
        # pump has to have a terminal leaf to walk back over.
        $r = Invoke-Verb @('+new-window', '--target=vc3')
        Assert ($r.Code -eq 0) "D: +new-window exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc3')) 'D: the window is listed'
        $r = Invoke-Verb @('+split', '--target=vc3', '--name=vc3b', "--view=$doc2")
        Assert ($r.Code -eq 0) "D: +split --view exits 0 (got $($r.Code))"
        $panes = 0
        for ($t = 0; $t -lt 30 -and $panes -lt 2; $t++) { $panes = Get-PaneCount 'vc3'; if ($panes -lt 2) { Start-Sleep -Milliseconds 200 } }
        Assert ($panes -eq 2) "D: the window has two panes before the pane close (got $panes)"

        $r = Invoke-Verb @('+close', '--target=vc3b')
        Assert ($r.Code -eq 0) "D: +close on the pane exits 0 (got $($r.Code))"
        Start-Sleep -Milliseconds 2000
        $aliveD = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveD 'D: the app is still running after closing ONE viewer pane out of a split'
        if ($aliveD) {
            Assert (Test-AppServing) 'D: the app still answers +list'
            $left = 0
            for ($t = 0; $t -lt 30; $t++) { $left = Get-PaneCount 'vc3'; if ($left -eq 1) { break }; Start-Sleep -Milliseconds 200 }
            Assert ($left -eq 1) "D: the window survived the pane close with its other pane (got $left)"
        }
    } else {
        Write-Host '  SKIP D: the app did not survive an earlier section'
    }

    # =====================================================================
    # E. the LAST window: the close IS the shutdown
    # =====================================================================
    Write-Host ''
    Write-Host 'E. the last window, where closing it ends the process'
    if ($aliveD) {
        # Put the app back to ONE window, and make that window the viewer one:
        # closing it is then both the window teardown and the app exit, which
        # is the case where a crash is easiest to mistake for a clean quit.
        [void](Invoke-Verb @('+close', '--target=vc3'))
        Start-Sleep -Milliseconds 800
        $r = Invoke-Verb @('+new-window', '--target=vc4', "--view=$doc1")
        Assert ($r.Code -eq 0) "E: +new-window --view exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc4')) 'E: the viewer window is listed'
        Assert (Wait-ViewerHost $app.Pid) 'E: its viewer host window exists'

        # Every OTHER window first, so the viewer window is genuinely last.
        $d = Get-Data
        if ($d) {
            foreach ($w in $d.windows) {
                if ($w.target -ne 'vc4') {
                    $t = $w.target
                    if ($t) { [void](Invoke-Verb @('+close', "--target=$t")) }
                    else { [void](Invoke-Verb @('+close', "--target=$($w.id)")) }
                }
            }
        }
        Start-Sleep -Milliseconds 1200

        [void](Invoke-Verb @('+close', '--target=vc4'))
        # Wait for the process to actually go. A crash and a clean quit both
        # end it; only the exit code tells them apart, which is the assertion
        # after this one - and that assertion says NOTHING while the process is
        # still running, so "it ended at all" has to be asserted first. The
        # first draft of this script scored a green E against a process that
        # had never exited.
        for ($t = 0; $t -lt 120; $t++) {
            if ($app.Process -and $app.Process.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
        Assert ($app.Process -and $app.Process.HasExited) `
            'E: closing the last window ended the process (without this, the crash check below is vacuous)'
        $pm = Get-GuiPostmortem -ProcessId $app.Pid -Name 'ghoztty' -Process $app.Process `
            -StdErr $errlog -Since $since -WaitSeconds 10
        Write-GuiPostmortem -Report $pm
        Assert-Survived (-not $pm.Crashed) `
            "E: closing the last window - the one holding the viewer - ended the process without a crash (verdict: $($pm.Verdict))"
        Assert ($null -eq $pm.DumpPath) `
            "E: no crash dump was written (dump: $(if ($pm.DumpPath) { $pm.DumpPath } else { 'none' }))"
    } else {
        Write-Host '  SKIP E: the app did not survive an earlier section'
    }

    Complete-TestBody
} finally {
    Remove-TestDesktop
    Remove-Item -Recurse -Force $docDir -ErrorAction SilentlyContinue
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due, and so does a run that unwound.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-close -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# -MinPass: a full run scores 33. A throw that unwinds a section leaves far
# less than that, and a partial score must not read as a pass (T271/T1039).
Write-TestVerdict -Label 'VIEWER CLOSE' -Pass $script:pass -Fail $script:fail -MinPass 30
