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
# SECTIONS A-D assert containment of whatever chrome they find, plus a positive
# control that SOMETHING was found, so a run where no chrome exists at all
# cannot score green. Since T1185 the nav bar is part of every viewer pane's
# frame, so it is among what they find in every mode - there is no hover left
# for a background desktop to be unable to perform.
#
# SECTION E measures the narrow bar's LOOK (T1159): `GhozttyViewerNav` answers
# WM_PRINTCLIENT, which is the one capture that works off the input desktop, so
# a control always in the leading slot, a field that is legible or absent,
# nothing gained by narrowing, and a leading mark that visibly changes are all
# assertable here rather than only in the arithmetic the none/win32 lanes cover
# (`viewer_nav_layout.zig`, the `T1130:` and `T1159:` tests, all teeth-checked).
#
#   powershell -NoProfile -File test\win32\viewer-narrow-pane.ps1
#
# SECTION F measures the TOC card's pinned header (T543): it is translucent,
# so scrolling the list under it CHANGES its pixels, where the opaque band it
# replaced never did.
#
# -NegativeControl inverts the narrow-pane containment assertion and section
# F's header claim, and MUST fail with exactly FOUR failures - one per width in
# section B, plus the header - so a run that scores anything else is measuring
# something other than what those assertions name.
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

    # -----------------------------------------------------------------------
    # E. T1159 - the narrow bar looks DESIGNED, not trimmed.
    #
    # The bar is on screen from an .html pane's first layout, with no cursor
    # anywhere in the path (T1185 made that true of every mode) - so the strip
    # is there to look at, its EDIT is a real child window to measure, and the
    # bar answers WM_PRINTCLIENT, which is the one capture that works off the
    # input desktop.
    #
    # What is asserted here is behaviour, not the layout's own arithmetic
    # restated (that is `viewer_nav_layout.zig`'s job, and mirroring it would
    # only prove the mirror). Four claims, all measured:
    #   1. A control is ALWAYS painted in the leading slot, at every width down
    #      to a sliver - that is the "..." overflow taking over from a strip
    #      that no longer fits, and it is why a dropped command is still
    #      reachable.
    #   2. The address field is legible or absent - never a stub. This is the
    #      thing the user flagged as unproven ("1 button and 1 tiny input?").
    #   3. Widening never takes anything away: painted controls and field width
    #      both climb monotonically.
    #   4. The leading slot's mark CHANGES between the widest and the narrowest
    #      pane - a short "..." against a full-height chevron - so the narrow
    #      bar is demonstrably showing the overflow control rather than the
    #      first navigation button with everything after it cut off.
    # -----------------------------------------------------------------------
    $htmlFile = Join-Path $env:TEMP "ghoztty-vnp-$PID.html"
    Set-Content -Path $htmlFile -Encoding utf8 -Value @'
<!doctype html><title>vnp</title><body style="background:#123;color:#eee">
<h1>narrow pane probe</h1><p>T1159</p></body>
'@
    Invoke-Verb @('+close', '--target=vc') | Out-Null
    Start-Sleep -Milliseconds 800
    $r = Invoke-Verb @('+split', '--target=vnp', "--view=$htmlFile", '--name=vh')
    Assert ($r.Code -eq 0) 'E: +split --view=<html file> succeeded'
    Start-Sleep -Seconds 4
    $w3 = Wait-Win 'vnp'
    $leaves3 = @(Get-Leaves $w3.tabs[0].splits)
    $term3 = @($leaves3 | Where-Object { $_.type -ne 'viewer' })
    $view3 = @($leaves3 | Where-Object { $_.type -eq 'viewer' })
    if ($term3.Count -ne 1 -or $view3.Count -ne 1) {
        Assert $false "E: expected one terminal + one live-page viewer, got $($leaves3.Count) leaves"
    } else {
        # The layout's own numbers, in DIP, so the pixel maths below is scale
        # aware. These are READ from the module, not re-derived: a change to
        # either one has to be made here too, which is the point.
        $targetPx = [int][Math]::Round(28 * $scale)   # icon_button target
        $padPx = [int][Math]::Round(4 * $scale)       # band edge / inter-button gap
        $fieldMinPx = [int][Math]::Round(72 * $scale) # viewer_nav_layout.field_min_dip
        $slotPx = $targetPx + $padPx
        $topPx = [int][Math]::Round((36 * $scale - $targetPx) / 2)

        function Set-HtmlRatio([int]$leftPercent) {
            $layout = '{"direction":"horizontal","ratio":' + $leftPercent +
                ',"left":{"pane":"' + $term3[0].name + '"},"right":{"pane":"' + $view3[0].name + '"}}'
            [void](Invoke-Verb @('+rearrange', '--target=vnp', ('--layout=' + ($layout -replace '"', '\"'))))
            Start-Sleep -Milliseconds 1200
        }

        # One measurement of the nav bar: its rect, its EDIT's width, which
        # button slots carry ink, and how tall the ink in the leading slot is.
        function Measure-NavBar([IntPtr]$topHwnd) {
            $hosts = @(Get-TestChildWindows -Window $topHwnd -Class 'GhozttyViewer')
            if ($hosts.Count -ne 1) { return $null }
            $hostRect = Get-Rect ([IntPtr]$hosts[0].Hwnd)
            $bars = @(Get-TestChildWindows -Window ([IntPtr]$hosts[0].Hwnd) -Class 'GhozttyViewerNav')
            if ($bars.Count -ne 1) { return $null }
            $barH = [IntPtr]$bars[0].Hwnd
            $barRect = Get-Rect $barH
            $barW = Rect-Width $barRect
            if ($barW -le 0) { return $null }
            $editW = 0
            foreach ($e in @(Get-TestChildWindows -Window $barH -Class 'Edit')) {
                $editW = [Math]::Max($editW, (Rect-Width (Get-Rect ([IntPtr]$e.Hwnd))))
            }
            $shot = $null
            try { $shot = Get-TestWindowPixels -Window $barH -Sync -AllowUniform } catch { $shot = $null }
            $slots = 0; $leadRows = 0
            if ($shot) {
                try {
                    # The band's own background, sampled above the controls at
                    # its trailing edge - a pixel no control can reach.
                    $bg = $shot.Bitmap.GetPixel([Math]::Max($shot.Width - 2, 0), 1)
                    $maxSlots = [int][Math]::Floor(($barW - $padPx) / $slotPx)
                    for ($i = 0; $i -lt $maxSlots; $i++) {
                        $x0 = $padPx + $i * $slotPx
                        $x1 = [Math]::Min($x0 + $targetPx, $shot.Width - 1)
                        $rows = 0
                        for ($y = $topPx; $y -lt [Math]::Min($topPx + $targetPx, $shot.Height); $y++) {
                            $inked = $false
                            for ($x = $x0; $x -lt $x1; $x++) {
                                $c = $shot.Bitmap.GetPixel($x, $y)
                                if ([Math]::Abs($c.R - $bg.R) + [Math]::Abs($c.G - $bg.G) +
                                    [Math]::Abs($c.B - $bg.B) -gt 40) { $inked = $true; break }
                            }
                            if ($inked) { $rows++ }
                        }
                        if ($rows -gt 0) { $slots++ }
                        if ($i -eq 0) { $leadRows = $rows }
                    }
                    $png = Join-Path $env:TEMP ("ghoztty-vnp-band-$barW.png")
                    $shot.Bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
                } finally { if ($shot.Bitmap) { $shot.Bitmap.Dispose() } }
            }
            return [pscustomobject]@{
                Host = $hostRect; BarRect = $barRect; BarWidth = $barW
                EditWidth = $editW; Slots = $slots; LeadRows = $leadRows
            }
        }

        # Wide -> narrow, so the monotone claim is checked on the way back up.
        $bands = @()
        foreach ($ratio in @(55, 72, 80, 86, 92)) {
            Set-HtmlRatio $ratio
            $mb = Measure-NavBar $top
            if ($null -eq $mb) { Assert $false "E[$ratio]: the live page's nav bar is on screen to measure"; continue }
            Write-Host ("      ratio $ratio -> bar $($mb.BarWidth)px, edit $($mb.EditWidth)px, " +
                "inked slot boxes $($mb.Slots), lead-slot ink $($mb.LeadRows) rows")
            $bands += $mb

            Assert (Inside $mb.BarRect $mb.Host) "E[$ratio]: the nav bar is inside the viewer pane"
            # 1. Something is always reachable: the leading slot always carries
            #    a control, however narrow the pane gets.
            Assert ($mb.LeadRows -gt 0) `
                "E[$ratio]: a control is painted in the leading slot ($($mb.LeadRows) ink rows)"
            # 2. Legible or absent - never a stub.
            Assert ($mb.EditWidth -eq 0 -or $mb.EditWidth -ge $fieldMinPx) `
                "E[$ratio]: the address field is legible (${fieldMinPx}px min) or absent, not a $($mb.EditWidth)px stub"
        }

        Assert ($bands.Count -eq 5) "E: all five width bands were measured (got $($bands.Count))"
        if ($bands.Count -eq 5) {
            # 3. Widening never takes anything away. The list runs wide ->
            #    narrow, so each step may only shed.
            $monoSlots = $true; $monoEdit = $true; $monoWidth = $true
            for ($i = 1; $i -lt $bands.Count; $i++) {
                if ($bands[$i].BarWidth -gt $bands[$i - 1].BarWidth) { $monoWidth = $false }
                if ($bands[$i].Slots -gt $bands[$i - 1].Slots) { $monoSlots = $false }
                if ($bands[$i].EditWidth -gt $bands[$i - 1].EditWidth) { $monoEdit = $false }
            }
            Assert $monoWidth 'E: the five ratios really did narrow the pane (negative control for the two below)'
            Assert $monoSlots 'E: narrowing never ADDS ink to the strip'
            Assert $monoEdit 'E: narrowing never widens the address field'
            # And the squeeze did something: a run where every band measured
            # the same bar would pass everything above and prove nothing.
            Assert ($bands[0].Slots -gt $bands[-1].Slots -or $bands[0].EditWidth -gt $bands[-1].EditWidth) `
                'E: the narrowest band really is more compact than the widest'

            # 4. The leading mark CHANGES: "..." is three dots on one short
            #    band of rows, the widest pane's first control is a full-height
            #    glyph. If the narrow bar were merely the wide strip cut off,
            #    these two would be identical.
            Assert ($bands[-1].LeadRows -gt 0 -and $bands[0].LeadRows -gt 0) `
                'E: both the widest and the narrowest leading slot carry ink'
            Assert ($bands[-1].LeadRows -lt $bands[0].LeadRows) `
                ("E: the narrow bar's leading control is the '...' overflow, not the wide strip's " +
                 "first button ($($bands[-1].LeadRows) ink rows vs $($bands[0].LeadRows))")
        }
        Write-Host "      band captures written to $env:TEMP\ghoztty-vnp-band-*.png"
    }
    Remove-Item $htmlFile -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # F. T543 - the card's pinned header is TRANSLUCENT, so a row scrolling
    #    under it stays a recognizable shape.
    #
    # Mac's `SidePanelHeader` sits on `glassBackdrop()` and the list blurs
    # through it. GDI has no live blur, so the win32 header re-composites the
    # card's own backdrop over the rows at just under opaque - and what tells
    # that apart from the opaque band it replaces is that SCROLLING CHANGES
    # THE HEADER'S PIXELS. An opaque header is byte-identical however far the
    # list has moved beneath it, which makes this section its own negative
    # control: same capture, same rows, same comparison.
    #
    # Only the band's own top rows are compared, above the caption's glyphs,
    # so "CONTENTS" is not what is being measured. The rows well BELOW the
    # band are compared too, as the positive control that the wheel scrolled
    # anything at all - without it a card that ignored the wheel would score
    # this green by never changing either strip.
    # -----------------------------------------------------------------------
    $mdFile = Join-Path $env:TEMP "ghoztty-vnp-toc-$PID.md"
    $mdLines = @('# Translucent header probe', '')
    foreach ($i in 1..60) {
        $mdLines += "## Section $i"
        $mdLines += "Body text for section $i, long enough to be a paragraph."
        $mdLines += ''
    }
    Set-Content -Path $mdFile -Encoding utf8 -Value ($mdLines -join [Environment]::NewLine)

    Invoke-Verb @('+new-window', '--target=vnf') | Out-Null
    if (-not (Wait-Win 'vnf')) {
        Assert $false 'F: a window for the header probe'
    } else {
        $r = Invoke-Verb @('+split', '--target=vnf', "--view=$mdFile", '--name=vf')
        Assert ($r.Code -eq 0) 'F: +split --view=<60-heading markdown> succeeded'
        Start-Sleep -Seconds 5

        # The card has to be in the GUTTER layout to be measured without a
        # cursor: that is the one presentation where it is on screen with no
        # toggle. The threshold is 720 DIP of PANE, so the window is stretched
        # and the viewer given most of it.
        $wf = Wait-Win 'vnf'
        $probeWin = [IntPtr]::Zero
        foreach ($t in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([IntPtr]$t.Hwnd -eq $top) { continue }
            if (@(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
                $probeWin = [IntPtr]$t.Hwnd
            }
        }
        if ($probeWin -ne [IntPtr]::Zero) {
            $wantW = [int][Math]::Round(1100 * $scale)
            [void](Set-TestWindowPos -Window $probeWin -X 0 -Y 0 -Width $wantW -Height 900)
            Start-Sleep -Milliseconds 800
        }
        if ($wf) {
            $leavesF = @(Get-Leaves $wf.tabs[0].splits)
            $termF = @($leavesF | Where-Object { $_.type -ne 'viewer' })
            $viewF = @($leavesF | Where-Object { $_.type -eq 'viewer' })
            if ($termF.Count -eq 1 -and $viewF.Count -eq 1) {
                $layoutF = '{"direction":"horizontal","ratio":15,"left":{"pane":"' +
                    $termF[0].name + '"},"right":{"pane":"' + $viewF[0].name + '"}}'
                [void](Invoke-Verb @('+rearrange', '--target=vnf',
                    ('--layout=' + ($layoutF -replace '"', '\"'))))
                Start-Sleep -Milliseconds 1500
            }
        }

        # The probe window's TOC card.
        $tocH = [IntPtr]::Zero
        $probeTop = [IntPtr]::Zero
        $tocRect = $null
        $cardH = 0
        foreach ($t in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([IntPtr]$t.Hwnd -eq $top) { continue }
            foreach ($vh in @(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer')) {
                foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$vh.Hwnd) -Class 'GhozttyViewerTOC')) {
                    $cr = Get-Rect ([IntPtr]$c.Hwnd)
                    if ((Rect-Width $cr) -gt 0 -and ($cr.bottom - $cr.top) -gt 0) {
                        $tocH = [IntPtr]$c.Hwnd
                        $probeTop = [IntPtr]$t.Hwnd
                        $tocRect = $cr
                        $cardH = $cr.bottom - $cr.top
                    }
                }
            }
        }
        Assert ($tocH -ne [IntPtr]::Zero) 'F: the probe document built a contents card to measure'

        # Where the band IS, from the app rather than from a DIP constant: the
        # header's height is a FONT metric at this scale, so a script cannot
        # restate it, and the card reports its box on stderr for exactly this
        # (`viewer toc card ... header=<px> ... margin=<px>`).
        $marginPx = [int][Math]::Round(12 * $scale)
        $headerPx = 0
        foreach ($line in @(Get-Content $errlog -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match($line, 'viewer toc card pane=\S+ header=(\d+) card=\d+x\d+ margin=(\d+)')
            if ($m.Success) {
                $headerPx = [int]$m.Groups[1].Value
                $marginPx = [int]$m.Groups[2].Value
            }
        }
        Assert ($headerPx -gt 0) "F: the card reported its header band ($headerPx px)"

        if ($tocH -ne [IntPtr]::Zero -and $headerPx -gt 0) {
            # The band, and ONLY the band: the card sits one margin inside the
            # gutter window, so it runs from `margin` to `margin + header`.
            # Two pixels are dropped at each end - the top one is the card's
            # antialiased rim, the bottom one is the seam a row's first lit
            # pixel can straddle - so nothing outside the header can be what
            # this measures.
            $bandTop = $marginPx + 2
            $bandBot = $marginPx + $headerPx - 2

            function Get-TocStrips([IntPtr]$h) {
                $shot = $null
                # No -AllowUniform: a blank bitmap (which is what a card that
                # is not on screen gives back) must fail the capture rather
                # than pass every comparison below by being equal to itself.
                try { $shot = Get-TestWindowPixels -Window $h -Sync } catch { $shot = $null }
                if ($null -eq $shot) { return $null }
                try {
                    $band = New-Object System.Collections.Generic.List[int]
                    $rows = New-Object System.Collections.Generic.List[int]
                    $w = [Math]::Min($shot.Width, 200)
                    for ($y = $bandTop; $y -lt [Math]::Min($bandBot, $shot.Height); $y++) {
                        for ($x = 0; $x -lt $w; $x++) { $band.Add($shot.Bitmap.GetPixel($x, $y).ToArgb()) }
                    }
                    $y0 = [Math]::Min($marginPx * 6, [Math]::Max($shot.Height - 8, 0))
                    for ($y = $y0; $y -lt [Math]::Min($y0 + 6, $shot.Height); $y++) {
                        for ($x = 0; $x -lt $w; $x++) { $rows.Add($shot.Bitmap.GetPixel($x, $y).ToArgb()) }
                    }
                    return [pscustomobject]@{ Band = $band.ToArray(); Rows = $rows.ToArray() }
                } finally { if ($shot.Bitmap) { $shot.Bitmap.Dispose() } }
            }

            function Measure-StripDiff($a, $b) {
                if ($null -eq $a -or $null -eq $b -or $a.Count -ne $b.Count) { return -1 }
                $n = 0
                for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $b[$i]) { $n++ } }
                return $n
            }

            $before = Get-TocStrips $tocH
            Assert ($null -ne $before) 'F: the contents card paints under WM_PRINTCLIENT'
            if ($null -ne $before) {
                # Wheel the list down, addressed straight at the card's own
                # window: the panel handles WM_MOUSEWHEEL itself, so this needs
                # no cursor and no foreground. It goes through Send-TestMouse
                # because a message has to be posted from a thread ON THE TEST
                # DESKTOP to arrive at all.
                $wx = [int](($tocRect.left + $tocRect.right) / 2)
                $wy = [int](($tocRect.top + $tocRect.bottom) / 2)
                for ($i = 0; $i -lt 8; $i++) {
                    [void](Send-TestMouse -Window $probeTop -Target $tocH -X $wx -Y $wy `
                        -Action wheel -Delta -120)
                    Start-Sleep -Milliseconds 60
                }
                Start-Sleep -Milliseconds 600
                $after = Get-TocStrips $tocH

                $rowsMoved = Measure-StripDiff $before.Rows $after.Rows
                $bandMoved = Measure-StripDiff $before.Band $after.Band
                Write-Host ("      card ${cardH}px tall; the wheel changed $rowsMoved list pixels " +
                    "and $bandMoved header-band pixels")
                Assert ($rowsMoved -gt 0) `
                    "F: the wheel scrolled the list under the header ($rowsMoved list pixels changed)"
                $bandOk = ($bandMoved -gt 0)
                if ($NegativeControl) {
                    Write-Host 'NEGATIVE CONTROL: asserting the header is OPAQUE - this run MUST fail'
                    Assert (-not $bandOk) 'F: the pinned header is opaque (negative control)'
                } else {
                    Assert $bandOk `
                        ("F: rows read THROUGH the pinned header - scrolling changed $bandMoved " +
                         'of its pixels (an opaque band changes none)')
                }
            }
        }
        # The probe window is left open on purpose: closing a window that owns
        # a viewer pane crashes the app on this build (T1356 - the WebView2
        # Close pumps messages, and the window's dim-overlay sweep then walks
        # the pane it is in the middle of freeing). The desktop teardown below
        # takes it down either way; a probe must not carry an unrelated defect.
    }
    Remove-Item $mdFile -ErrorAction SilentlyContinue

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
