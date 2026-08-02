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
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
}

# ---------------------------------------------------------------------------
# The oracle's own color math, mirroring src/apprt/win32/color_math.zig and
# chrome_theme.zig. DERIVED, never pasted: `Wash` is the app's rule, so a
# change to the wash direction or to `bar_wash` moves this script with it.
# ---------------------------------------------------------------------------

$BAR_WASH = 0.08          # chrome_theme.bar_wash
$TEXT_FLOOR = 4.5         # WCAG 1.4.3, the design system's text floor

# chrome_theme.debugChromeBase (T43): a Debug/ReleaseSafe build drags the
# chrome background toward warning amber before anything is derived from it, so
# the window is unmistakably not the installed release. Mirrored here because
# this script measures the band a DEBUG build paints - an oracle that expected
# the release band would fail on every run and be "fixed" by deleting the
# marker.
$DEBUG_TINT = @(0xFF, 0xB0, 0x00)           # chrome_theme.debug_tint
$DEBUG_TINT_FALLBACK = @(0x7B, 0x2F, 0xF7)  # chrome_theme.debug_tint_fallback
$DEBUG_TINT_AMOUNT = 0.35                   # chrome_theme.debug_tint_amount
$DEBUG_MIN_DELTA = 48                       # chrome_theme.debug_min_delta

function Get-Lum601([int]$r, [int]$g, [int]$b) {
    return (0.299 * $r + 0.587 * $g + 0.114 * $b) / 255.0
}

function Test-IsLight([int]$r, [int]$g, [int]$b) {
    return (Get-Lum601 $r $g $b) -gt 0.5
}

# color_math.wash: composite toward the background's own contrasting side.
function Get-Wash([int[]]$Rgb, [double]$A) {
    $toward = if (Test-IsLight $Rgb[0] $Rgb[1] $Rgb[2]) { 0.0 } else { 255.0 }
    $out = @()
    foreach ($c in $Rgb) {
        $v = [double]$c
        $w = [Math]::Round($v + ($toward - $v) * $A, [MidpointRounding]::AwayFromZero)
        $out += [int][Math]::Max(0, [Math]::Min(255, $w))
    }
    return , $out
}

# color_math.mix: composite $Fg over $Bg at $A, resolved to an opaque color.
function Get-Mix([int[]]$Bg, [int[]]$Fg, [double]$A) {
    $out = @()
    for ($i = 0; $i -lt 3; $i++) {
        $v = [double]$Bg[$i] * (1.0 - $A) + [double]$Fg[$i] * $A
        $out += [int][Math]::Max(0, [Math]::Min(255, [Math]::Round($v, [MidpointRounding]::AwayFromZero)))
    }
    return , $out
}

function Get-ChannelDistance([int[]]$A, [int[]]$B) {
    return [Math]::Abs($A[0] - $B[0]) + [Math]::Abs($A[1] - $B[1]) + [Math]::Abs($A[2] - $B[2])
}

# chrome_theme.debugChromeBase.
function Get-DebugChromeBase([int[]]$Base) {
    $amber = Get-Mix $Base $DEBUG_TINT $DEBUG_TINT_AMOUNT
    if ((Get-ChannelDistance $amber $Base) -ge $DEBUG_MIN_DELTA) { return , $amber }
    return , (Get-Mix $Base $DEBUG_TINT_FALLBACK $DEBUG_TINT_AMOUNT)
}

# Does the exe under test mark itself (T43)? Read off `+version`'s own "build
# mode" line rather than assumed from the path: T350 is the standing hazard of
# a non-Debug zig-out silently aiming a script at a build it was not written
# for, and here the EXPECTED PIXEL differs between the two.
function Test-ExeIsDebugBuild([string]$Path) {
    $out = (& $Path +version 2>&1 | Out-String)
    # Zig prints the enum with its leading dot (`build mode    : .Debug`).
    if ($out -notmatch 'build mode\s*:\s*\.?(\w+)') {
        throw "chrome-theme: could not read the build mode out of '$Path +version'"
    }
    return @('Debug', 'ReleaseSafe') -contains $Matches[1]
}

function Get-WcagChannel([int]$c) {
    $s = $c / 255.0
    if ($s -le 0.03928) { return $s / 12.92 }
    return [Math]::Pow(($s + 0.055) / 1.055, 2.4)
}

function Get-WcagLum([int]$r, [int]$g, [int]$b) {
    return 0.2126 * (Get-WcagChannel $r) + 0.7152 * (Get-WcagChannel $g) + 0.0722 * (Get-WcagChannel $b)
}

function Get-Contrast([int[]]$A, [int[]]$B) {
    $la = Get-WcagLum $A[0] $A[1] $A[2]
    $lb = Get-WcagLum $B[0] $B[1] $B[2]
    $hi = [Math]::Max($la, $lb); $lo = [Math]::Min($la, $lb)
    return ($hi + 0.05) / ($lo + 0.05)
}

function Format-Rgb([int[]]$Rgb) { return ('#{0:x2}{1:x2}{2:x2}' -f $Rgb[0], $Rgb[1], $Rgb[2]) }

# ---------------------------------------------------------------------------
# Capture helpers
# ---------------------------------------------------------------------------

# Every pixel of a screen-coordinate box, summarised: the MODE (the color the
# most pixels are, i.e. the band fill by construction - the title and the
# button glyphs are a small minority of a caption band) and the two luminance
# extremes with their colors.
function Measure-Box($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1) {
    $hist = @{}
    $minL = 2.0; $maxL = -1.0
    $minC = $null; $maxC = $null
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
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

$isDebugBuild = Test-ExeIsDebugBuild $exe
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

            $shot = Get-TestWindowPixels -Window $g.Top
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

    $shot = Get-TestWindowPixels -Window $panel
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
    $shot = Get-TestWindowPixels -Window $panel
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
    $shot = Get-TestWindowPixels -Window $panel
    try {
        Assert (Test-ShotHasColor $shot $ACCENT_B) "B3 after the accent-change message the panel paints $(Format-Rgb $ACCENT_B)"
        Assert (-not (Test-ShotHasColor $shot $ACCENT_A)) 'B3 and the old accent is gone - the pixel MOVED'
    } finally { Close-TestWindowPixels -Shot $shot }

    Assert (-not ($script:app.Process -and $script:app.Process.HasExited)) 'B the app survived every accent change'
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
