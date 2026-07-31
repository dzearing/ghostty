# T150 fixture: fill the ENTIRE pane with one color class at a time, and
# hand off to the driver between steps so it can probe a settled screen.
#
# Steps, in order:
#   1. default foreground (SGR 39)        -- the scheme's foreground
#   2. 256-color index 250 (SGR 38;5;250) -- the grayscale ramp, which only
#      a regeneration of palette indices 16-255 can move
#   3. truecolor 230,230,230 (SGR 38;2)   -- beyond every palette; only the
#      renderer's draw-time minimum-contrast pass can make this readable
#
# One class at a time, whole screen, rather than three bands in one screen:
# ConPTY reports a row count that does not match the grid the app actually
# renders (66 vs ~53 here), so ANY band arithmetic built on [Console]::
# WindowHeight aims the driver's probe at the wrong rows -- and it does so
# silently, landing in a neighbouring band that happens to assert fine.
# Painting the full screen removes the row math from the oracle entirely:
# every pixel in the pane is the color under test.
#
# Steps 1-2 are FULL BLOCK (U+2588): the glyph paints the whole cell, so the
# probed pixel IS the palette color the renderer resolved.
#
# Step 3 CANNOT use a block. `renderer/cell.zig:noMinContrast` exempts every
# graphics element -- box drawing, blocks, Powerline -- from the minimum
# contrast pass on purpose, so a block step would render its raw color no
# matter what the floor is and report a working renderer as broken. It uses
# dense TEXT instead, which the driver samples across a patch of pixels to
# find the glyph interiors.
#
# Handshake: this script writes "<step>" to -Out and waits for the driver to
# DELETE that file, which is its signal to paint the next step.
param([Parameter(Mandatory = $true)][string]$Out)

$ErrorActionPreference = 'Stop'
$e = [char]27
$block = [string][char]0x2588

# Let the pane settle before measuring it: the shell starts against the
# creation grid and the window then resizes to its real size.
Start-Sleep -Seconds 3
$w = [Console]::WindowWidth
$h = [Console]::WindowHeight
if ($w -lt 8 -or $h -lt 6) { Set-Content -Path $Out -Value 'ERROR' -Encoding ascii; exit 1 }

# Deliberately overshoot the row count. The reported height is an
# over-estimate here, but if it were ever an UNDER-estimate the tail of the
# screen would keep the previous step's color and the probe would read it
# as this step's answer. Overshooting only scrolls identical lines.
$lines = $h + 4

$steps = @(
    @{ name = 'foreground'; sgr = "$e[39m"; fill = $block * ($w - 1) },
    @{ name = 'palette256'; sgr = "$e[38;5;250m"; fill = $block * ($w - 1) },
    # 'M' is the densest common glyph: its stems are several pixels wide at
    # any reasonable cell size, so the run has interior pixels at the full
    # foreground color rather than an antialiased blend.
    @{ name = 'truecolor'; sgr = "$e[38;2;230;230;230m"; fill = 'M' * ($w - 1) }
)

foreach ($s in $steps) {
    [Console]::Out.Write("$e[2J$e[H")
    for ($i = 0; $i -lt $lines; $i++) {
        [Console]::Out.Write($s.sgr + $s.fill + "$e[0m`n")
    }
    Set-Content -Path $Out -Value $s.name -Encoding ascii
    # The driver deletes the file once it has probed this step.
    for ($t = 0; $t -lt 240 -and (Test-Path $Out); $t++) { Start-Sleep -Milliseconds 250 }
}

# Hold the pane. The driver kills the app when it is done.
while ($true) { Start-Sleep -Seconds 30 }
