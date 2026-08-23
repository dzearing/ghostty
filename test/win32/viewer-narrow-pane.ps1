# T1130 acceptance: a viewer pane squeezed narrow keeps every piece of its
# chrome INSIDE the pane.
#
# THE DEFECT, as measured on this box before the fix. A viewer pane dragged to
# 77px (an 800px window, `+rearrange` at ratio 90) still built its
# table-of-contents card at the compact layout's 120 DIP FLOOR - 150px at this
# box's 1.25 scale - so the card's right edge sat 88px past the pane. The card
# is a `WS_CHILD` of the pane host, so Windows clipped it rather than painting
# it over the pane next door: no spill, but a card whose rows, scrollbar and
# rounded right corner were simply cut off, and rows MEASURED for a width the
# card never got.
#
# That is the same shape as the Mac defect 463dcb0b4 fixed one level up
# (`ViewerNarrowPaneTests.swift`): chrome that insists on a minimum width the
# pane cannot pay. Mac's answer - and this script's contract - is that a viewer
# is a leaf in the split tree exactly like a terminal, so the TREE decides the
# width and the leaf compresses to it.
#
# WHY GEOMETRY AND NOT PIXELS. Every piece of viewer chrome on win32 is a child
# window of the pane host (`GhozttyViewerNav` + its `Edit`, `GhozttyViewerTOC`,
# `GhozttyViewerFeedback`), so "inside the pane" is a rect comparison and needs
# no composite, no cursor and no foreground. That is what lets this run on the
# background test desktop, where `CopyFromScreen` and `PrintWindow` are dead
# (lib\TestDesktop.ps1's capture limit).
#
# THE ONE THING IT CANNOT SEE is the nav bar's own button strip: the bar is
# hidden unless something reveals it, and the compact-TOC pin that should hold
# it open runs behind a `GetCursorPos` that FAILS on a background desktop
# (T1152). The strip's narrow-width contract - a button that does not fit whole
# is not painted, and nothing is placed outside the band - is asserted in the
# none/win32 lanes instead (`viewer_nav_layout.zig`, the two `T1130:` tests,
# both teeth-checked). What this script asserts about the bar is containment of
# whatever it finds, plus a positive control that SOMETHING was found, so a run
# where no chrome exists at all cannot score green.
#
#   powershell -NoProfile -File test\win32\viewer-narrow-pane.ps1
#
# -NegativeControl inverts the narrow-pane containment assertion and MUST fail
# with exactly THREE failures - one per width in section B - so a run that
# scores anything else is measuring something other than the containment.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vnp$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')

# T1127: everything running out of this build's directory is reaped when this
# PowerShell exits, including a detached `--pty-host` holder that no PID-based
# teardown at the bottom of the script could reach.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -Namespace VNP -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
'@

function Get-Rect([IntPtr]$h) {
    $r = New-Object VNP.U+RECT
    [void][VNP.U]::GetWindowRect($h, [ref]$r)
    return $r
}
function Rect-Width($r) { return ($r.right - $r.left) }
function Inside($inner, $outer) {
    return ($inner.left -ge $outer.left -and $inner.right -le $outer.right -and
            $inner.top -ge $outer.top -and $inner.bottom -le $outer.bottom)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}
function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}
function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 25; $t++) {
        $d = Get-Data
        if ($d) { foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } } }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# The chrome classes this script knows how to find, and whether each is
# expected to exist. `GhozttyViewerNav` and `GhozttyViewerFeedback` are created
# with the pane but sized to nothing until something shows them.
$chromeClasses = @('GhozttyViewerNav', 'GhozttyViewerTOC', 'GhozttyViewerFeedback')

# Measure one viewer host and everything under it. Returns the host rect, the
# named child rects, and a list of anything that reaches outside the host.
function Measure-Viewer([IntPtr]$topHwnd) {
    $hosts = @(Get-TestChildWindows -Window $topHwnd -Class 'GhozttyViewer')
    if ($hosts.Count -ne 1) { return $null }
    $hostRect = Get-Rect ([IntPtr]$hosts[0].Hwnd)
    $children = @()
    foreach ($cls in $chromeClasses) {
        foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$hosts[0].Hwnd) -Class $cls)) {
            $r = Get-Rect ([IntPtr]$c.Hwnd)
            $children += [pscustomobject]@{ Class = $cls; Rect = $r; Width = (Rect-Width $r) }
            # The address field lives inside the bar, and a field placed past
            # the band's edge is exactly what the fix had to stop.
            foreach ($e in @(Get-TestChildWindows -Window ([IntPtr]$c.Hwnd) -Class 'Edit')) {
                $er = Get-Rect ([IntPtr]$e.Hwnd)
                $children += [pscustomobject]@{ Class = "$cls/Edit"; Rect = $er; Width = (Rect-Width $er) }
            }
        }
    }
    $outside = @($children | Where-Object { $_.Width -gt 0 -and -not (Inside $_.Rect $hostRect) })
    return [pscustomobject]@{
        Host = $hostRect
        HostWidth = (Rect-Width $hostRect)
        Children = $children
        Outside = $outside
        Painted = @($children | Where-Object { $_.Width -gt 0 })
    }
}

function Describe-Outside($m) {
    foreach ($o in $m.Outside) {
        Write-Host ("      {0}: x={1}..{2} vs pane {3}..{4}" -f `
            $o.Class, $o.Rect.left, $o.Rect.right, $m.Host.left, $m.Host.right) -ForegroundColor Yellow
    }
}

$viewFile = Join-Path $repo 'README.md'
[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$launched = @()
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-narrow-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    $launched += $script:GhozttyTestDesktopPids
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    Invoke-Verb @('+new-window', '--target=vnp') | Out-Null
    if (-not (Wait-Win 'vnp')) { Write-Host 'SETUP FAIL: no vnp window'; exit 1 }
    $r = Invoke-Verb @('+split', '--target=vnp', "--view=$viewFile", '--name=vv')
    if ($r.Code -ne 0) { Write-Host "SETUP FAIL: +split --view exited $($r.Code): $($r.Out)"; exit 1 }
    Start-Sleep -Seconds 4

    $w = Wait-Win 'vnp'
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    $term = @($leaves | Where-Object { $_.type -ne 'viewer' })
    $view = @($leaves | Where-Object { $_.type -eq 'viewer' })
    if ($term.Count -ne 1 -or $view.Count -ne 1) {
        Write-Host "SETUP FAIL: expected one terminal + one viewer, got $($leaves.Count) leaves"; exit 1
    }

    # The `vnp` window's HWND: the only GhozttyWindow that owns a GhozttyViewer.
    $top = [IntPtr]::Zero
    foreach ($t in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        if (@(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
            $top = [IntPtr]$t.Hwnd
        }
    }
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no window carries a GhozttyViewer'; exit 1 }
    $dpi = [VNP.U]::GetDpiForWindow($top)
    $scale = $dpi / 96.0
    Write-Host "window dpi=$dpi scale=$scale"

    function Set-ViewerRatio([int]$leftPercent) {
        $layout = '{"direction":"horizontal","ratio":' + $leftPercent +
            ',"left":{"pane":"' + $term[0].name + '"},"right":{"pane":"' + $view[0].name + '"}}'
        $res = Invoke-Verb @('+rearrange', '--target=vnp', ('--layout=' + ($layout -replace '"', '\"')))
        Start-Sleep -Milliseconds 1200
        return $res
    }

    # -----------------------------------------------------------------------
    # A. Wide control: the card is at its PREFERRED width, not compressed.
    #
    # Without this the whole script would pass on a build that hid the card
    # entirely, or pinned it to a sliver at every width - "inside the pane" is
    # trivially true for chrome that is not there (the T216 lesson).
    # -----------------------------------------------------------------------
    $res = Set-ViewerRatio 20
    Assert ($res.Code -eq 0) "A: +rearrange to a wide viewer succeeded"
    $wide = Measure-Viewer $top
    Assert ($null -ne $wide) 'A: exactly one GhozttyViewer host under the window'
    $wideToc = @($wide.Painted | Where-Object { $_.Class -eq 'GhozttyViewerTOC' })
    Assert ($wideToc.Count -eq 1) "A: the wide pane shows a contents card (got $($wideToc.Count))"
    if ($wideToc.Count -eq 1) {
        # 240 DIP is `viewer_toc_layout.card_default_dip`. Rounding across the
        # DIP/pixel boundary is worth a pixel or two either way.
        $wantPx = [int][Math]::Round(240 * $scale)
        $gotPx = $wideToc[0].Width
        Assert ([Math]::Abs($gotPx - $wantPx) -le 2) `
            "A: the wide card is at the preferred width (want ~${wantPx}px, got ${gotPx}px)"
    }
    Assert ($wide.Outside.Count -eq 0) 'A: every painted chrome window is inside the wide pane'
    if ($wide.Outside.Count -ne 0) { Describe-Outside $wide }

    # -----------------------------------------------------------------------
    # B. The squeeze, at three widths. Ratio 90 is the width the defect was
    #    measured at (77px on an 800px window); 80 and 65 walk back up through
    #    the band where the 120 DIP floor used to bite.
    # -----------------------------------------------------------------------
    $narrowSeen = 0
    foreach ($ratio in @(90, 80, 65)) {
        $res = Set-ViewerRatio $ratio
        Assert ($res.Code -eq 0) "B[$ratio]: +rearrange succeeded"
        $m = Measure-Viewer $top
        if ($null -eq $m) { Assert $false "B[$ratio]: one GhozttyViewer host"; continue }
        Write-Host ("      pane is $($m.HostWidth)px wide; painted chrome: " +
            (($m.Painted | ForEach-Object { "$($_.Class)=$($_.Width)px" }) -join ' '))

        # The pane itself must stay inside its window - the containment this
        # whole family of defects is about, one level up.
        $topRect = Get-Rect $top
        Assert (Inside $m.Host $topRect) "B[$ratio]: the viewer pane is inside the window"

        # Positive control for THIS width: something was actually measured.
        Assert ($m.Painted.Count -ge 1) `
            "B[$ratio]: the narrow pane still paints chrome to measure (got $($m.Painted.Count))"
        if ($m.Painted.Count -ge 1) { $narrowSeen++ }

        $ok = ($m.Outside.Count -eq 0)
        if ($NegativeControl) {
            Write-Host "NEGATIVE CONTROL: asserting chrome DOES reach outside the pane - this run MUST fail"
            Assert (-not $ok) "B[$ratio]: chrome reaches outside the narrow pane (negative control)"
        } else {
            Assert $ok "B[$ratio]: every painted chrome window is inside the narrow pane"
        }
        if (-not $ok) { Describe-Outside $m }

        # The card specifically: never wider than the pane that holds it. This
        # is the number the defect got wrong (150px of card in a 77px pane).
        foreach ($c in @($m.Painted | Where-Object { $_.Class -eq 'GhozttyViewerTOC' })) {
            Assert ($c.Width -le $m.HostWidth) `
                "B[$ratio]: the contents card ($($c.Width)px) fits the pane ($($m.HostWidth)px)"
        }
    }
    Assert ($narrowSeen -eq 3) "B: all three narrow widths had chrome to measure (got $narrowSeen)"

    # -----------------------------------------------------------------------
    # C. Back to wide: the compression is not a one-way door. A clamp that
    #    latched would leave a sliver of a card on a pane dragged back open.
    # -----------------------------------------------------------------------
    [void](Set-ViewerRatio 20)
    $back = Measure-Viewer $top
    Assert ($null -ne $back) 'C: one GhozttyViewer host after widening back'
    if ($back) {
        $backToc = @($back.Painted | Where-Object { $_.Class -eq 'GhozttyViewerTOC' })
        Assert ($backToc.Count -eq 1) "C: the card came back (got $($backToc.Count))"
        if ($backToc.Count -eq 1 -and $wideToc.Count -eq 1) {
            Assert ($backToc[0].Width -eq $wideToc[0].Width) `
                "C: the card is the width it was before the squeeze ($($backToc[0].Width)px vs $($wideToc[0].Width)px)"
        }
        Assert ($back.Outside.Count -eq 0) 'C: every painted chrome window is inside the widened pane'
        if ($back.Outside.Count -ne 0) { Describe-Outside $back }
    }

    # -----------------------------------------------------------------------
    # D. A second viewer FLAVOR, squeezed the same way.
    #
    # The chrome is flavor-independent by construction - every flavor is the
    # same `GhozttyViewer` host with the same nav bar and the same TOC panel,
    # and the flavor only decides what the WebView2 inside renders - so this is
    # a spot check of that claim rather than a matrix. A code file is the
    # useful second case because it has no headings, which means NO contents
    # card: it proves the containment sweep is not silently measuring only the
    # one control that section B exercises.
    # -----------------------------------------------------------------------
    $codeFile = Join-Path $repo 'build.zig'
    Invoke-Verb @('+close', '--target=vv') | Out-Null
    Start-Sleep -Milliseconds 800
    $r = Invoke-Verb @('+split', '--target=vnp', "--view=$codeFile", '--name=vc')
    Assert ($r.Code -eq 0) 'D: +split --view=<code file> succeeded'
    Start-Sleep -Seconds 4
    $w2 = Wait-Win 'vnp'
    $leaves2 = @(Get-Leaves $w2.tabs[0].splits)
    $term2 = @($leaves2 | Where-Object { $_.type -ne 'viewer' })
    $view2 = @($leaves2 | Where-Object { $_.type -eq 'viewer' })
    if ($term2.Count -eq 1 -and $view2.Count -eq 1) {
        $layout = '{"direction":"horizontal","ratio":90,"left":{"pane":"' + $term2[0].name +
            '"},"right":{"pane":"' + $view2[0].name + '"}}'
        [void](Invoke-Verb @('+rearrange', '--target=vnp', ('--layout=' + ($layout -replace '"', '\"'))))
        Start-Sleep -Milliseconds 1200
        $code = Measure-Viewer $top
        Assert ($null -ne $code) 'D: one GhozttyViewer host for the code pane'
        if ($code) {
            Write-Host ("      pane is $($code.HostWidth)px wide; painted chrome: " +
                (($code.Painted | ForEach-Object { "$($_.Class)=$($_.Width)px" }) -join ' '))
            $topRect2 = Get-Rect $top
            Assert (Inside $code.Host $topRect2) 'D: the narrow code pane is inside the window'
            # The count is IN the label deliberately: a code pane paints no
            # chrome of its own, so this assertion is a tripwire for chrome
            # appearing outside the pane rather than a measurement of chrome
            # that is there. The section's real content is the two assertions
            # around it.
            Assert ($code.Outside.Count -eq 0) `
                "D: no chrome reaches outside the narrow code pane (over $($code.Painted.Count) painted)"
            if ($code.Outside.Count -ne 0) { Describe-Outside $code }
            # The control for "no card here": a code file has no headings, so
            # the card that section B measured must be absent, not merely small.
            $codeToc = @($code.Painted | Where-Object { $_.Class -eq 'GhozttyViewerTOC' })
            Assert ($codeToc.Count -eq 0) "D: a code file shows no contents card (got $($codeToc.Count))"
        }
    } else {
        Assert $false "D: expected one terminal + one code viewer, got $($leaves2.Count) leaves"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived the whole run'
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due. A negative-control run is red by construction, so it
# never stamps.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-narrow-pane -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
