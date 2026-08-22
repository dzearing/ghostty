# T305 acceptance: the win32 chrome takes its colors from `chrome_theme`, and
# they TRACK the two inputs that own them - the chrome background and the
# user's accent.
#
# Two claims, two oracles, because they fail in different ways:
#
#   A. THE BAND FOLLOWS THE BACKGROUND'S LUMINANCE. The caption band used to be
#      `background + 20` per channel. On a light background a per-channel add
#      clamps toward white, so the band, its hover and the text all converge on
#      the same near-white and the fixed `RGB(230,230,230)` title goes
#      illegible. The wash reverses direction instead. Three runs - `#f3f3f3`,
#      `#ffffff` (T274's own named failure, where a per-channel add cannot move
#      at all) and `#1e1e1e` - and the band is measured against the
#      value `color_math.wash(bg, chrome_theme.bar_wash)` DERIVES - recomputed
#      here rather than pasted, so a change to `bar_wash` moves the app and the
#      oracle together (the T257 rule).
#
#   B. THE ACCENT IS THE USER'S. The chooser and the Activity Monitor each held
#      an invented blue (`#3D8EF8` and `RGB(80,160,235)`); neither was the
#      color anybody picked. The panel's ACTIVE machine card is outlined in the
#      accent, so the oracle is an exact-RGB scan of the panel capture: the
#      accent is set to one value, captured, set to a second, captured, and the
#      painted pixel must have MOVED to the new one. A test that matched
#      whatever this box is already set to would prove nothing (the T174 rule).
#      Both probe accents are chosen to clear the 3:1 chrome floor against the
#      card unassisted, so `chrome_theme.accentOn` returns them untouched and
#      the expected pixel is the literal accent.
#
#      B also covers the CACHE and its invalidation, which is the half a
#      relaunch cannot see: the registry is changed with no notification and
#      the panel must still paint the OLD accent (the cache is real), and then
#      `WM_DWMCOLORIZATIONCOLORCHANGED` is posted to the top-level window and
#      the next panel must paint the NEW one (the invalidation is wired).
#
#      Two cases, and only ONE of them is the live-update claim. B3 closes and
#      reopens the panel around the message, so it scores the CACHE DROP only -
#      a panel that repaints because it was freshly constructed passes it, and
#      that close/reopen was the workaround standing in for the missing
#      repaint. **B4 is the live-update claim** (T307): the panel stays OPEN
#      across the notification and its accent pixel must move anyway, which is
#      the thing a user with the panel on screen actually sees.
#
#   C. THE DEBUG BUILD MARKS ITSELF (T43), and the release build does not.
#      A Debug/ReleaseSafe build drags the chrome background toward warning
#      amber before anything is derived from it, so the whole band is amber and
#      the window cannot be mistaken for the installed release; the taskbar half
#      is the " [DEBUG]" title suffix. Scored inside A rather than as its own
#      section, because A already measures the exact surface the marker changes
#      and a second copy of that machinery is what T257 spent a task deleting.
#      Both assertions are two-directional - `+version`'s own "build mode" line
#      says which build this is, and the expectation flips with it, so "release
#      build unaffected" is a real check rather than an untested half. That also
#      defuses T350 here: a non-Debug zig-out changes the expected pixel, and
#      this script would notice rather than fail mysteriously.
#
#   D. THE PANELS FOLLOW THE SAME SURFACE (T308). A. covers the chrome band;
#      the Activity Monitor and the machine chooser had their own ~35 hardcoded
#      constants and opened dark on a light theme. Scored on the panel's own
#      fill against an EXACT expectation - a panel paints from
#      `chrome_theme.chromeBase`, which under the default `window-theme = auto`
#      is `--background` itself, so the mode pixel must BE the background. One
#      assertion, three claims: the panel tracks the theme, it does not wash
#      (unlike the band, a panel abuts nothing), and it is not debug-tinted.
#      Its text is then scored by EXACT presence of the derived ramp color,
#      not by A's luminance-extreme oracle: a panel is full of controls, and
#      both probe backgrounds turn up a pure black/white pixel somewhere that
#      clears any floor by itself, so the extreme would pass without ever
#      touching our text.
#
# WHAT THIS SCRIPT CANNOT CLAIM, and why - T307's CHILD-WINDOW half. T307
# widened the reaction from "invalidate the chrome row" to "redraw this window
# and every child", because a child HWND never receives the broadcast (it goes
# to top-level windows only) and so its owner is the only place its repaint can
# come from. B4 above scores the live update on a PANEL, but a panel is
# top-level and gets the message itself, so it passes either way. Two oracles
# for the child half were built and BOTH were measured to be undiscriminating
# here; they are written down so the next attempt does not re-derive them:
#
#   - The hero carousel's accent-outlined selected tile. Measured PASS with
#     the repaint reverted: its thumbnail refresh timer repaints the band every
#     150ms unprompted, so it picks the new accent up from the cache drop
#     alone. A surface that repaints on its own cannot score whether anything
#     invalidated it.
#   - The viewer's contents card (`GhozttyViewerTOC`), a child HWND whose
#     ACTIVE row is filled with the raw accent. The card appears and captures
#     fine, but the accent fill is gated on `isEmphasized()`, i.e. on
#     `GetForegroundWindow`, and lib\TestDesktop.ps1's own header records that
#     a background desktop HAS no foreground window - the pill is therefore
#     always the unemphasized gray here. It would score on a real desktop.
#
# The child claim is left to code review and a manual check, and the gap is
# filed rather than papered over with an assertion that passes both ways.
#
# WHAT THIS SCRIPT DOES NOT CLAIM. T305's validation text asks for the
# ACTIVE-TAB INDICATOR to track the accent. There is no such pixel: the tab
# strip paints no accent at all - a tab's fill comes from `tab_shape.fillColor`
# (strip and content backgrounds), which is deliberate, matches WinUI's
# TabView, and is what T304's "the dark strip must not visibly move" note
# requires. The accent's real surfaces are the chooser row, this panel's card,
# and the carousel border, so the tracking claim is scored on one of those.
# Filed as the correction it is rather than fudged into a strip assertion.
#
# The band's TEXT is scored by extreme luminance (darkest pixel on a light
# band, lightest on a dark one) against the 4.5:1 floor. That direction is
# safe: ClearType fringing can only overshoot further from the band, never
# toward it, so a fringe cannot manufacture a pass. It says "the title is
# legible", not "the title is exactly `palette.text`" - the exact value is
# asserted in chrome_theme.zig's own sweep, in the none lane.
#
# SYSTEM STATE. Section B writes HKCU\...\DWM\AccentColor and restores it - the
# original value, or its ABSENCE - in a `finally`, so a mid-script failure
# cannot leave the box repainted (T179). The apps light/dark setting is NOT
# touched at all: section A varies `--background` instead, which reaches the
# same `chromeBase` input under the default `window-theme = auto` and leaves
# the user's Personalize key alone.
#
# CONTROLS. `-NegativeControl` inverts A's load-bearing direction claim - the
# light band is asserted to be LIGHTER than its background, which is exactly
# what `background + 20` produced - and that run MUST fail.
#
# T211/T217: runs on a BACKGROUND Win32 desktop. Every surface probed here is a
# native GDI-painted window, never the OpenGL terminal surface, so the T214
# capture limit does not apply.
#
# T248: the repo's agent is killed and the app launched with
# --session-persistence=false, so a restored manifest cannot hand this run a
# previous run's window.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive, [int]$DirPort = 45812)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-chrome-theme-stderr.log'
$isDebugBuild = $null   # resolved from `+version` once the helpers are defined
Remove-Item $errlog -ErrorAction SilentlyContinue
$env:GHOZTTY_PIPE_SUFFIX = '-chromethemetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# `+version`'s build mode, which section A's expectation flips on. TestDesktop
# does not pull this in, so it is sourced here explicitly.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

# The harness disables the T43 debug marker so every other GUI script measures
# the chrome that SHIPS. This script is the one that owns the marker, so it
# turns it back on - after the dot-source, which is where the default is set.
$env:GHOZTTY_DEBUG_MARKER = '1'

$script:pass = 0
$script:fail = 0
$script:app = $null
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

# ---------------------------------------------------------------------------
# The oracle's own color math lives in lib/ColorMath.ps1 (T308) - DERIVED,
# never pasted, so a change to a wash amount moves the app and every oracle
# together (the T257 rule). It moved out of this file when activity-monitor.ps1
# needed the same derivations for the panel surfaces.
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot 'lib\ColorMath.ps1')

# ---------------------------------------------------------------------------
# Capture helpers
# ---------------------------------------------------------------------------

# Every pixel of a screen-coordinate box, summarised: the MODE (the color the
# most pixels are, i.e. the band fill by construction - the title and the
# button glyphs are a small minority of a caption band) and the two luminance
# extremes with their colors.
#
# `-Step` samples every Nth pixel in both axes. A caption band is small enough
# to walk whole; a PANEL is ~900x700, and 630k `GetPixel` calls through
# PowerShell is minutes per capture. Sampling cannot change which color is the
# MODE (the fill is most of the box by construction) and still lands on plenty
# of glyph pixels for the extremes, because text strokes are not one pixel wide
# at these sizes.
function Measure-Box($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$Step = 1) {
    $hist = @{}
    $minL = 2.0; $maxL = -1.0
    $minC = $null; $maxC = $null
    for ($y = $Y0; $y -lt $Y1; $y += $Step) {
        for ($x = $X0; $x -lt $X1; $x += $Step) {
            $c = Get-TestPixel -Shot $Shot -X $x -Y $y
            if ($null -eq $c) { continue }
            $key = '{0},{1},{2}' -f $c.R, $c.G, $c.B
            if ($hist.ContainsKey($key)) { $hist[$key]++ } else { $hist[$key] = 1 }
            $l = Get-Lum601 $c.R $c.G $c.B
            if ($l -lt $minL) { $minL = $l; $minC = @([int]$c.R, [int]$c.G, [int]$c.B) }
            if ($l -gt $maxL) { $maxL = $l; $maxC = @([int]$c.R, [int]$c.G, [int]$c.B) }
        }
    }
    if ($hist.Count -eq 0) { return $null }
    $top = $hist.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
    $parts = $top.Key -split ','
    return [pscustomobject]@{
        Mode     = @([int]$parts[0], [int]$parts[1], [int]$parts[2])
        ModeN    = [int]$top.Value
        Darkest  = $minC
        Lightest = $maxC
        Distinct = $hist.Count
    }
}

# Is there a pixel of EXACTLY $Rgb anywhere in the capture? Exact on purpose:
# GDI strokes a solid pen with no antialiasing, so an accent border lands as its
# literal constant, and a "reddish" probe would match ClearType fringes on any
# text (the trap activity-monitor.ps1 documents).
function Test-ShotHasColor($Shot, [int[]]$Rgb) {
    for ($y = 0; $y -lt $Shot.Height; $y++) {
        for ($x = 0; $x -lt $Shot.Width; $x++) {
            $c = $Shot.Bitmap.GetPixel($x, $y)
            if ($c.R -eq $Rgb[0] -and $c.G -eq $Rgb[1] -and $c.B -eq $Rgb[2]) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Accent registry (section B). ABGR DWORD, the encoding chrome_theme.
# accentFromDword decodes - see its doc comment for why it is not ARGB.
# ---------------------------------------------------------------------------

$DWM_KEY = 'HKCU:\Software\Microsoft\Windows\DWM'

# The stored value, UNCONVERTED. PowerShell surfaces a REG_DWORD whose top bit
# is set as a value that does NOT fit Int32 (this box: 4286644328), so `[int]`
# on the way out throws and the restore in the `finally` never happens - which
# would leave the user's accent set to a test color. Round-trip the bytes.
function Get-AccentRaw {
    $p = Get-ItemProperty -Path $DWM_KEY -Name AccentColor -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$p.AccentColor), 0)
}

# An RGB triple as the DWORD Windows stores. `Set-ItemProperty -Type DWord`
# binds an Int32, and 0xFF...... overflows it - so the bytes are reinterpreted
# rather than cast (the PS5.1 hex-literal Int32 trap).
# Assembled as BYTES, not with shifts: PS5.1 parses `0xFF000000` as an Int32
# (-16777216), so `[uint32]0xFF000000` throws before any shift runs. x86 is
# little-endian, so laying the bytes down R,G,B,FF IS the 0xAABBGGRR DWORD.
# Checks out against the value T304 measured on this box: #680081 -> 68 00 81
# FF -> 0xFF810068 -> 4286644328.
function ConvertTo-AccentDword([int[]]$Rgb) {
    $bytes = [byte[]]@($Rgb[0], $Rgb[1], $Rgb[2], 0xFF)
    return [BitConverter]::ToInt32($bytes, 0)
}

function Set-Accent([int[]]$Rgb) {
    Set-ItemProperty -Path $DWM_KEY -Name AccentColor -Value (ConvertTo-AccentDword $Rgb) -Type DWord
}

function Restore-Accent($Raw) {
    if ($null -eq $Raw) {
        Remove-ItemProperty -Path $DWM_KEY -Name AccentColor -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $DWM_KEY -Name AccentColor -Value $Raw -Type DWord
    }
}

# ---------------------------------------------------------------------------
# App lifecycle
# ---------------------------------------------------------------------------

function Start-Gui([string[]]$ExtraArgs) {
    # NOT `$args`: that name is a read-only automatic in a PowerShell function
    # and assigning it is a terminating error, not a shadow.
    $argv = @('--session-persistence=false') + $ExtraArgs
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments $argv -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($script:app.Process -and $script:app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { return $null }
    return [pscustomobject]@{ Top = $top; Pane = $pane; Pid = $script:app.Pid }
}

function Invoke-Palette([IntPtr]$top, [IntPtr]$pane, [string]$filter) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -eq [IntPtr]::Zero) { return $false }
    Send-TestControlText -Control $edit -Text $filter | Out-Null
    $sent = Send-TestControlKey -Control $edit -Key Enter
    Start-Sleep -Milliseconds 900
    return $sent
}

function Get-Panels { return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyActivityMonitor') }

# Open the Activity Monitor and return its HWND, or IntPtr::Zero.
function Open-Panel([IntPtr]$top, [IntPtr]$pane) {
    if (-not (Invoke-Palette $top $pane 'ACTIVITY MONITOR')) { return [IntPtr]::Zero }
    return (Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000)
}

function Close-Panel([IntPtr]$panel) {
    $edit = Find-TestWindowEx -Parent $panel -Class 'EDIT'
    if ($edit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $edit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 900
    return ((Get-Panels).Count -eq 0)
}

# ---------------------------------------------------------------------------

# Composed from the two BuildMode helpers rather than a third one of our own:
# T43's marker gates on exactly `build_config.is_debug`, which is the predicate
# `Test-GhozttyIsolatedBuildMode` already mirrors. (It was written here as a
# call to a `Test-ExeIsDebugBuild` that never existed, which made this script
# unrunnable from its first line - fixed while validating T307.)
$isDebugBuild = Test-GhozttyIsolatedBuildMode (Get-GhozttyBuildMode -Exe $exe)
Write-Host ("build under test: " + $(if ($isDebugBuild) { 'marks itself (Debug/ReleaseSafe)' } else { 'release, unmarked' }))

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$origAccent = Get-AccentRaw
$dirJob = $null

try {
    # =======================================================================
    # A. The caption band follows the chrome background's luminance
    # =======================================================================
    #
    # One tab, so the strip is hidden (`auto` is `tab_count > 1 or
    # !customCaption`) and the caption band is a 36 DIP row carrying the window
    # title - the smallest surface that holds a band fill AND its text.
    #
    # `white` is T274's own named failure: at `background = ffffff` the retired
    # `+ 20` clamped the band to 255,255,255 and the frozen `RGB(230,230,230)`
    # title measured 1.25:1 on it. It is scored here because it is the case
    # where a per-channel add cannot move at all.
    foreach ($case in @(
            @{ Name = 'light'; Bg = @(0xF3, 0xF3, 0xF3) },
            @{ Name = 'white'; Bg = @(0xFF, 0xFF, 0xFF) },
            @{ Name = 'dark'; Bg = @(0x1E, 0x1E, 0x1E) })) {

        $bg = $case.Bg
        $hex = Format-Rgb $bg
        $g = Start-Gui @("--background=$hex")
        if (-not $g) { Write-Host "SETUP FAIL: GUI did not come up on $hex"; exit 1 }
        try {
            Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) "A/$($case.Name) window is NOT on the interactive desktop"

            # T43's other half, and the only one that reaches the taskbar and
            # Alt-Tab, where the app paints no pixel of its own. Same gate as
            # the tint (`Window.debug_build`), asserted in both directions for
            # the same reason.
            if ($case.Name -eq 'light') {
                $title = Get-TestWindowText -Window $g.Top
                Assert (($title -like '*[[]DEBUG]*') -eq $isDebugBuild) `
                    "A/T43 window title carries ' [DEBUG]' iff the build marks itself (title: '$title')"
            }

            $m = Get-TestChromeMetrics -Window $g.Top -StripVisible $false
            Assert ($m.CaptionH -gt 0) "A/$($case.Name) the window paints its own caption band"

            $shot = Get-TestWindowPixels -Window $g.Top -Sync
            try {
                # Client-relative band, in the screen coordinates Get-TestPixel
                # takes. Inset by 1 so a client edge cannot contribute.
                $x0 = $m.ClientLeft + 1
                $x1 = $m.ClientLeft + $m.ClientW - 1
                $y0 = $m.ClientTop + 1
                $y1 = $m.ClientTop + $m.CaptionH - 1
                $band = Measure-Box $shot $x0 $y0 $x1 $y1
                Assert ($null -ne $band) "A/$($case.Name) the caption band captured"
                if ($null -eq $band) { continue }

                # The base the band is washed FROM: the background, plus the
                # T43 debug tint when this exe is a build that marks itself.
                $base = if ($isDebugBuild) { Get-DebugChromeBase $bg } else { , $bg }
                $want = Get-Wash $base $BAR_WASH
                Assert ($band.Mode[0] -eq $want[0] -and $band.Mode[1] -eq $want[1] -and $band.Mode[2] -eq $want[2]) `
                    ("A/$($case.Name) band fill is wash(base, bar_wash) = $(Format-Rgb $want) (measured $(Format-Rgb $band.Mode))")

                # T43, both directions. A debug build's band must NOT be the
                # band the same background would paint in a release build, and
                # a release build's must BE it. Written as one assertion with
                # two answers because "release build unaffected" is half of
                # T43's validation and is otherwise never checked anywhere.
                $plain = Get-Wash $bg $BAR_WASH
                $marked = (Get-ChannelDistance $band.Mode $plain) -ge 16
                # `-NegativeControl` inverts this the same way it inverts the
                # direction claim below: it asserts a DEBUG build paints the
                # release band, which is exactly the regression "the debug
                # build looks like the release build" - so that run MUST fail
                # here too, and a probe that could not see the tint is caught.
                $wantMarked = if ($NegativeControl -and $case.Name -eq 'light') { -not $isDebugBuild } else { $isDebugBuild }
                Assert ($marked -eq $wantMarked) `
                    ("A/$($case.Name) T43 debug marker present == build marks itself ($(if ($isDebugBuild) { 'debug' } else { 'release' }) build; " +
                     "band $(Format-Rgb $band.Mode) vs untinted $(Format-Rgb $plain))")

                # The direction claim, and the whole point of the change: on a
                # LIGHT background the band goes DARKER. `background + 20` can
                # only ever go lighter, and near white it cannot move at all.
                $bandLum = Get-Lum601 $band.Mode[0] $band.Mode[1] $band.Mode[2]
                $bgLum = Get-Lum601 $bg[0] $bg[1] $bg[2]
                $onLight = ($case.Name -ne 'dark')
                if ($onLight) {
                    if ($NegativeControl -and $case.Name -eq 'light') {
                        Assert ($bandLum -gt $bgLum) 'A/light NEGATIVE CONTROL: band is LIGHTER than a light background'
                    } else {
                        Assert ($bandLum -lt $bgLum) "A/$($case.Name) band is DARKER than the light background it sits on"
                    }
                } else {
                    Assert ($bandLum -gt $bgLum) 'A/dark band is LIGHTER than the dark background it sits on'
                }

                # Text legibility, scored on the extreme AWAY from the band.
                $text = if ($onLight) { $band.Darkest } else { $band.Lightest }
                $ratio = Get-Contrast $text $band.Mode
                Assert ($ratio -ge $TEXT_FLOOR) `
                    ("A/$($case.Name) caption text clears $TEXT_FLOOR" + ':1 against the band (' + ('{0:n2}' -f $ratio) + ':1, ' + (Format-Rgb $text) + ')')
                Assert ($band.Distinct -ge 3) "A/$($case.Name) the band capture holds real content ($($band.Distinct) distinct colors)"
            } finally {
                Close-TestWindowPixels -Shot $shot
            }
        } finally {
            Kill-RepoInstances
        }
    }

    # =======================================================================
    # B. The accent is the user's, is cached, and tracks a change
    # =======================================================================
    #
    # Both probes clear 3:1 against the panel's card unassisted, so
    # `chrome_theme.accentOn` hands them back untouched and the pixel to look
    # for is the literal color.
    $ACCENT_A = @(0xFF, 0x00, 0x00)   # red
    $ACCENT_B = @(0x00, 0xC0, 0x00)   # green

    # The carousel - and with it the ACTIVE card's accent outline - only exists
    # with more than one machine (`activity_cards.hasCarousel`), and a signed-
    # out panel has exactly one. So the panel is given a loopback relay
    # directory with one device in it, the same fixture ipc-machine-chooser.ps1
    # uses. Without this the accent has nothing to paint and B fails against a
    # correct build - which is how this section failed on its first run.
    $devicesJson = '{"devices":[{"id":"dev-chrome-theme","name":"E2E-Box","hostname":"e2e.local","online":true}]}'
    $dirJob = Start-Job -ScriptBlock {
        param($port, $body)
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $payload = [Text.Encoding]::UTF8.GetBytes($body)
        $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
        $respBytes = [Text.Encoding]::UTF8.GetBytes($resp) + $payload
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                Start-Sleep -Milliseconds 40
                $buf = New-Object byte[] 16384
                while ($stream.DataAvailable) { [void]$stream.Read($buf, 0, $buf.Length) }
                $stream.Write($respBytes, 0, $respBytes.Length)
                $stream.Flush()
            } catch {}
            $client.Close()
        }
    } -ArgumentList $DirPort, $devicesJson
    Start-Sleep -Milliseconds 600

    Set-Accent $ACCENT_A
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
    $env:GHOSTTY_RELAY_TOKEN = 'faketoken-chrome-theme'
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $env:TEMP "ghoztty-ct-acct-$PID\account.dat")
    $g = Start-Gui @()
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    if (-not $g) { Write-Host 'SETUP FAIL: GUI did not come up for section B'; exit 1 }

    # Positive control: the palette opens at all, so a later "no panel" is a
    # product verdict and not a dead injection path.
    $panel = Open-Panel $g.Top $g.Pane
    Assert ($panel -ne [IntPtr]::Zero) 'B the Activity Monitor opened'
    if ($panel -eq [IntPtr]::Zero) { Write-Host 'ABORT: no panel to score'; exit 1 }

    $shot = Get-TestWindowPixels -Window $panel -Sync
    try {
        Assert ((Get-TestDistinctColors -Shot $shot) -ge 8) "B the panel capture holds real content ($(Get-TestDistinctColors -Shot $shot) distinct colors)"
        Assert (Test-ShotHasColor $shot $ACCENT_A) "B1 the panel paints the system accent $(Format-Rgb $ACCENT_A)"
        Assert (-not (Test-ShotHasColor $shot $ACCENT_B)) "B1 and nothing on it is $(Format-Rgb $ACCENT_B) yet"
    } finally { Close-TestWindowPixels -Shot $shot }

    # B2: the registry moves with NO notification. The accent is cached, so the
    # panel must still paint the OLD one - the assertion that proves the cache
    # is real and that B3 below is measuring the invalidation rather than a
    # per-paint registry read that never needed one.
    Assert (Close-Panel $panel) 'B2 Escape closed the panel'
    Set-Accent $ACCENT_B
    $panel = Open-Panel $g.Top $g.Pane
    Assert ($panel -ne [IntPtr]::Zero) 'B2 the panel reopened'
    if ($panel -eq [IntPtr]::Zero) { Write-Host 'ABORT: no panel to score'; exit 1 }
    $shot = Get-TestWindowPixels -Window $panel -Sync
    try {
        Assert (Test-ShotHasColor $shot $ACCENT_A) 'B2 with no notification the cached accent still paints'
        Assert (-not (Test-ShotHasColor $shot $ACCENT_B)) 'B2 the un-notified registry change did NOT leak through'
    } finally { Close-TestWindowPixels -Shot $shot }

    # B3: WM_DWMCOLORIZATIONCOLORCHANGED, the message DWM broadcasts when the
    # user picks a new accent. Posted to the TOP-LEVEL window, which is where
    # the handler lives.
    $WM_DWMCOLORIZATIONCOLORCHANGED = 0x0320
    Assert (Close-Panel $panel) 'B3 Escape closed the panel'
    Send-TestRawMessage -Window $g.Top -Message $WM_DWMCOLORIZATIONCOLORCHANGED -WParam 0 -LParam 0 | Out-Null
    Start-Sleep -Milliseconds 600
    $panel = Open-Panel $g.Top $g.Pane
    Assert ($panel -ne [IntPtr]::Zero) 'B3 the panel reopened'
    if ($panel -eq [IntPtr]::Zero) { Write-Host 'ABORT: no panel to score'; exit 1 }
    $shot = Get-TestWindowPixels -Window $panel -Sync
    try {
        Assert (Test-ShotHasColor $shot $ACCENT_B) "B3 after the accent-change message the panel paints $(Format-Rgb $ACCENT_B)"
        Assert (-not (Test-ShotHasColor $shot $ACCENT_A)) 'B3 and the old accent is gone - the pixel MOVED'
    } finally { Close-TestWindowPixels -Shot $shot }

    # B4: the LIVE-UPDATE claim (T307). B3 above closes and reopens the panel
    # around the message, so all it can prove is that the CACHE was dropped -
    # a panel that repaints only because it was just constructed would pass it.
    # This leaves the panel OPEN across the notification, which is what a user
    # who picks a new accent with the panel on screen actually does.
    #
    # DWM broadcasts to every top-level window, so the message goes to both the
    # main window and the panel; posting only to the main window would test a
    # broadcast Windows does not send. The colors run backwards - B -> A - so
    # the assertion reuses the two probes already vetted against the card.
    Set-Accent $ACCENT_A
    foreach ($h in @($g.Top, $panel)) {
        Send-TestRawMessage -Window $h -Message $WM_DWMCOLORIZATIONCOLORCHANGED -WParam 0 -LParam 0 | Out-Null
    }
    Start-Sleep -Milliseconds 900
    $shot = Get-TestWindowPixels -Window $panel -Sync
    try {
        Assert (Test-ShotHasColor $shot $ACCENT_A) "B4 the OPEN panel repaints to $(Format-Rgb $ACCENT_A) without being reopened"
        Assert (-not (Test-ShotHasColor $shot $ACCENT_B)) 'B4 and the accent it opened with is gone - it repainted, it did not just gain a pixel'
    } finally { Close-TestWindowPixels -Shot $shot }

    Assert (-not ($script:app.Process -and $script:app.Process.HasExited)) 'B the app survived every accent change'

    # =======================================================================
    # D. The PANELS follow the same surface (T308)
    # =======================================================================
    #
    # A. proves the caption band tracks the chrome background. The panels did
    # NOT: the Activity Monitor held ~30 `RGB(...)` constants and the chooser
    # four more, all picked against `RGB(32,32,32)`, so on a light theme a panel
    # opened dark with fixed light text on it. This scores the fix on the one
    # surface that cannot lie about it - the panel's own fill.
    #
    # The oracle is EXACT, not directional: a panel paints from
    # `chrome_theme.chromeBase`, and under the default `window-theme = auto`
    # that IS `--background`. So the panel's mode pixel must equal the
    # background exactly. That single assertion carries three claims at once -
    # the panel follows the theme, it does not wash the way the chrome band
    # does (a panel abuts nothing), and it is NOT debug-tinted (T43's marker is
    # the chrome band; this script has the marker ON, so an amber panel would
    # fail here).
    #
    # Then the text floor, scored like A's: the luminance extreme AWAY from the
    # fill, which ClearType fringing can only push further from the fill and so
    # cannot fake a pass.
    Kill-RepoInstances
    foreach ($case in @(
            @{ Name = 'light'; Bg = @(0xF3, 0xF3, 0xF3) },
            @{ Name = 'dark'; Bg = @(0x1E, 0x1E, 0x1E) })) {

        $bg = $case.Bg
        $hex = Format-Rgb $bg
        $g = Start-Gui @("--background=$hex")
        if (-not $g) { Write-Host "SETUP FAIL: GUI did not come up on $hex for section D"; exit 1 }
        try {
            foreach ($panel in @(
                    @{ Label = 'activity'; Filter = 'ACTIVITY MONITOR'; Class = 'GhozttyActivityMonitor' },
                    @{ Label = 'chooser'; Filter = 'NEW REMOTE WINDOW'; Class = 'GhozttyMachineChooser' })) {

                if (-not (Invoke-Palette $g.Top $g.Pane $panel.Filter)) {
                    Assert $false "D/$($case.Name)/$($panel.Label) the command palette accepted the opener"
                    continue
                }
                $h = Wait-TestWindow -ProcessId $g.Pid -Class $panel.Class -TimeoutMs 8000
                Assert ($h -ne [IntPtr]::Zero) "D/$($case.Name)/$($panel.Label) the panel opened"
                if ($h -eq [IntPtr]::Zero) { continue }

                $shot = Get-TestWindowPixels -Window $h -Sync
                try {
                    # The panel BODY: below the caption the frame draws (which
                    # is DWM's, not ours) and inside the border, so neither can
                    # contribute a pixel to the fill or to the extremes.
                    $x0 = $shot.Left + 8
                    $x1 = $shot.Left + $shot.Width - 8
                    $y0 = $shot.Top + [int]($shot.Height * 0.30)
                    $y1 = $shot.Top + $shot.Height - 8
                    $body = Measure-Box $shot $x0 $y0 $x1 $y1 3
                    Assert ($null -ne $body) "D/$($case.Name)/$($panel.Label) the panel body captured"
                    if ($null -eq $body) { continue }

                    Assert ($body.Distinct -ge 8) `
                        "D/$($case.Name)/$($panel.Label) the capture holds real content ($($body.Distinct) distinct colors)"

                    Assert ($body.Mode[0] -eq $bg[0] -and $body.Mode[1] -eq $bg[1] -and $body.Mode[2] -eq $bg[2]) `
                        ("D/$($case.Name)/$($panel.Label) panel surface IS chromeBase = $hex (measured $(Format-Rgb $body.Mode))")

                    # The text ramp, EXACTLY, not the capture's luminance
                    # extreme. The extreme is useless here: a panel is full of
                    # controls, and both probe backgrounds turn up a pure
                    # #000000 / #ffffff pixel somewhere (a control border, a
                    # ClearType overshoot) that clears any floor on its own -
                    # so the assertion passed without ever looking at our text.
                    #
                    # `chrome_theme.textOn` is `wash(surface, text_wash)`
                    # clamped to 4.5:1, and on both of these surfaces the wash
                    # already clears it, so the expected pixel is the wash -
                    # derived here, never pasted (the T257 rule). If a future
                    # change made the clamp bite, this fails loudly rather than
                    # silently measuring nothing.
                    $wantText = Get-PanelText $bg
                    Assert (Test-ShotHasColor $shot $wantText) `
                        "D/$($case.Name)/$($panel.Label) panel paints its derived primary text $(Format-Rgb $wantText)"
                    $ratio = Get-Contrast $wantText $body.Mode
                    Assert ($ratio -ge $TEXT_FLOOR) `
                        ("D/$($case.Name)/$($panel.Label) that text clears $TEXT_FLOOR" + ':1 on the measured surface (' +
                         ('{0:n2}' -f $ratio) + ':1)')
                } finally {
                    Close-TestWindowPixels -Shot $shot
                }

                # Escape closes both panels (each puts focus in its own EDIT).
                $edit = Find-TestWindowEx -Parent $h -Class 'EDIT'
                if ($edit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $edit -Key Escape | Out-Null }
                Start-Sleep -Milliseconds 700
            }
        } finally {
            Kill-RepoInstances
        }
    }

} finally {
    if ($dirJob) { Stop-Job $dirJob -ErrorAction SilentlyContinue; Remove-Job $dirJob -Force -ErrorAction SilentlyContinue }
    Restore-Accent $origAccent
    Remove-TestDesktop
    Kill-RepoInstances
    Stop-TestForegroundWatch | Out-Null
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) of $($script:pass + $script:fail)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
