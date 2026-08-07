# The oracles' own color math, mirroring src/apprt/win32/color_math.zig,
# chrome_theme.zig and panel_theme.zig.
#
# It lives in one file for the reason the Zig side does (T304/T308): a pixel
# oracle that PASTES the color it expects stops being an oracle the moment the
# app derives that color instead. chrome-theme.ps1 and activity-monitor.ps1 both
# score painted chrome/panel surfaces; two private copies of `wash` would be two
# chances to disagree with the app and with each other.
#
# DERIVED, never pasted: change a wash amount in the Zig and these scripts move
# with it.

# --- the amounts, by their Zig names ---------------------------------------
$BAR_WASH = 0.08                # chrome_theme.bar_wash
$TEXT_WASH = 0.90               # chrome_theme.text_wash
$TEXT_SECONDARY_WASH = 0.55     # chrome_theme.text_secondary_wash
$PANEL_HEADER_WASH = 0.04       # panel_theme.header_wash
$PANEL_SURFACE_WASH = 0.06      # panel_theme.surface_wash
$PANEL_RAISED_WASH = 0.12       # panel_theme.raised_wash
$PANEL_BANNER_ALPHA = 0.12      # panel_theme.banner_alpha
$PANEL_WARN_BASE = @(220, 165, 90)   # panel_theme.warn_base
$PANEL_CPU_BASE = @(80, 160, 235)    # panel_theme.cpu_base
$PANEL_MEM_BASE = @(90, 190, 120)    # panel_theme.mem_base

$TEXT_FLOOR = 4.5               # WCAG 1.4.3, the design system's text floor
$UI_FLOOR = 3.0                 # WCAG 1.4.11, chrome_theme.ui_contrast_target

# chrome_theme.debugChromeBase (T43): a Debug/ReleaseSafe build drags the chrome
# background toward warning amber before anything is derived from it, so the
# window is unmistakably not the installed release.
$DEBUG_TINT = @(0xFF, 0xB0, 0x00)           # chrome_theme.debug_tint
$DEBUG_TINT_FALLBACK = @(0x7B, 0x2F, 0xF7)  # chrome_theme.debug_tint_fallback
$DEBUG_TINT_AMOUNT = 0.35                   # chrome_theme.debug_tint_amount
$DEBUG_MIN_DELTA = 48                       # chrome_theme.debug_min_delta

# --- primitives -------------------------------------------------------------

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

# panel_theme.recede: the mirror of `wash` - toward the surface's OWN side, so a
# field or a chart well reads as inset. (The extremes fall back to a wash in the
# app; a probe background at 0 or 255 would need the same branch here.)
function Get-Recede([int[]]$Rgb, [double]$A) {
    $toward = if (Test-IsLight $Rgb[0] $Rgb[1] $Rgb[2]) { 255.0 } else { 0.0 }
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

function Get-DebugChromeBase([int[]]$Base) {
    $amber = Get-Mix $Base $DEBUG_TINT $DEBUG_TINT_AMOUNT
    if ((Get-ChannelDistance $amber $Base) -ge $DEBUG_MIN_DELTA) { return , $amber }
    return , (Get-Mix $Base $DEBUG_TINT_FALLBACK $DEBUG_TINT_AMOUNT)
}

# --- WCAG -------------------------------------------------------------------

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

# --- the derived colors a probe asks for ------------------------------------
#
# Only the ones whose contrast clamp is a NO-OP on the surfaces these scripts
# probe, and each caller says so. The clamp is a binary search in CIELAB and
# reimplementing it here would be a second implementation of the thing under
# test; where it would bite, the script picks a probe background where it does
# not, and a future change that makes it bite fails loudly instead of silently
# measuring nothing.

function Get-PanelText([int[]]$Bg) { return , (Get-Wash $Bg $TEXT_WASH) }
function Get-PanelSecondary([int[]]$Bg) { return , (Get-Wash $Bg $TEXT_SECONDARY_WASH) }
function Get-PanelHeader([int[]]$Bg) { return , (Get-Wash $Bg $PANEL_HEADER_WASH) }
function Get-PanelSurface([int[]]$Bg) { return , (Get-Wash $Bg $PANEL_SURFACE_WASH) }
function Get-PanelRaised([int[]]$Bg) { return , (Get-Wash $Bg $PANEL_RAISED_WASH) }
function Get-PanelBanner([int[]]$Bg) { return , (Get-Mix $Bg $PANEL_WARN_BASE $PANEL_BANNER_ALPHA) }
