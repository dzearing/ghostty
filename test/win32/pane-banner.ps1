# T35/T91 acceptance: sticky pane banner — `+set-banner` IPC, OSC 7778,
# banner overlay strip on the glass, `+list` additive `banner` field, the
# ctrl+shift+b "Set Pane Banner" editor dialog, and the T91 markdown
# parity blocks (headings, rules, tables, native checkboxes, collapse).
#
# T217 batch 8: runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so
# it never steals the user's foreground.
#
# Oracles:
#   - `+list --json` panes carry an additive `banner` field with the raw
#     markdown source when set (absent otherwise).
#   - A visible GhozttyBannerOverlay popup is glued ABOVE the pane (its
#     bottom meets the pane HWND's top — T101: the strip band is reserved
#     by the window layout, so the grid starts below the banner, never
#     under it) and spans the pane width; its height grows with `\n` line
#     breaks (capped at 10 display lines). Setting/clearing/collapsing a
#     banner moves the pane top by exactly the strip height.
#   - A pixel probe inside the strip reads the card wash rather than the dark
#     pane background while the banner is up (proves the strip reaches the
#     glass, not just the data model).
#   - T131 (glass card): the banner is a FLOATING CARD, not a full-width
#     strip. The band's own corners read the pane background EXACTLY (the
#     card is inset by a uniform margin and nothing behind the band bleeds
#     through — that see-through was the "text scrolls behind the banner"
#     report), the card interior is the Mac wash `white @ 6%` over the pane
#     background, an elevation shadow darkens the band just under the card,
#     and the popup is fully OPAQUE.
#   - A heading is taller than a plain line; an `---` rule line is thinner
#     than a text line; a pipe table renders 3 display rows from 4 source
#     lines (the separator row never renders).
#   - A checked task-list box paints real green pixels (native box), not
#     a plaintext glyph.
#   - A multi-line banner collapses to a first-line sliver on click and
#     expands back on a second click.
#   - T165 (link affordance): a link's underline is DOTTED at rest and goes
#     SOLID under the pointer (measured as ink-over-span on the rule's own
#     row, so it needs no pixel constant); a right-click on a link opens the
#     Mac-parity action menu with the left-click default as its first row;
#     and Ctrl+click really opens a viewer side pane, read back from
#     `+list --json` rather than from a pixel.
#   - OSC 7778 emitted from inside the pane round-trips into +list.
#   - The editor dialog (GhozttyBannerDialog) opens on ctrl+shift+b, is modal
#     over its window, arrives prefilled and selected, commits on ctrl+enter,
#     cancels on Escape.
#
# CAPTURE, on the test desktop: every pixel probe here reads the BANNER
# OVERLAY's own GDI chrome, which is the half of the CAPTURE LIMIT that
# migrates — PrintWindow returns the real painted card (measured: 64 distinct
# colors, card wash 30,30,34, band corner 16,16,20, shadow 12,12,15). None of
# them touch the OpenGL terminal surface, which would come back a flat fill.
# Each capture is still guarded with Get-TestDistinctColors: a window captured
# mid-paint is solid black, and black satisfies a "was anything drawn?" probe
# while proving nothing (T216).
#
# OPACITY, on the test desktop: the pre-migration oracle for "the card is
# fully opaque" was `composited screen pixel == own-DC pixel`, and there is no
# screen composite off the input desktop to compare against. It is replaced by
# the attribute that DECIDES the composite — GetLayeredWindowAttributes must
# report alpha 255 with LWA_ALPHA and no colour key — plus the unchanged
# band-corner probe, which is what a translucent strip actually failed.
# Relabelling a single capture as "composited == own" instead would have been
# a vacuous assertion (T217 batch 3).
#
# Only touches ghoztty processes running from this repo's zig-out*.
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-bntest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) {
        if ($target -like 'id:*') { if ($w.id -eq $target.Substring(3)) { return $w } }
        elseif ($w.target -eq $target) { return $w }
    }
    return $null
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

# Poll for a pane banner: window $target, leaf index $i, expected exact
# value (or 'NONE' for absent). Returns the observed value or '(absent)'.
function Wait-Banner($target, [int]$i, [string]$expect) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) {
            $leaves = @(Get-Leaves $w.tabs[0].splits)
            if ($leaves.Count -gt $i) {
                $b = $leaves[$i].banner
                if ($expect -eq 'NONE' -and -not $b) { return '(absent)' }
                if ($b -ceq $expect) { return $b }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    $w = Get-Win $target
    if ($w) {
        $leaves = @(Get-Leaves $w.tabs[0].splits)
        if ($leaves.Count -gt $i -and $leaves[$i].banner) { return $leaves[$i].banner }
    }
    return '(absent)'
}

# Live pane rect #$i of window $top, sorted top-then-left so the index is
# geometric (0 = topmost pane), or $null.
function Get-Pane([IntPtr]$top, [int]$i = 0) {
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object { $_.Visible } | Sort-Object Top, Left)
    if ($panes.Count -le $i) { return $null }
    return $panes[$i]
}

# The banner overlay glued ABOVE live pane #$i (same left edge; overlay
# BOTTOM meets the pane's current top — T101 reserves the strip band above
# the terminal, so the grid starts below the banner, never under it), or
# $null. Queries the pane fresh: the pane top moves as strips come and go.
function Get-Overlay([int]$procId, [IntPtr]$top, [int]$i = 0) {
    $p = Get-Pane $top $i
    if (-not $p) { return $null }
    foreach ($o in @(Get-TestWindows -ProcessId $procId -Class 'GhozttyBannerOverlay')) {
        if ([math]::Abs($o.Left - $p.Left) -le 2 -and
            [math]::Abs($o.Bottom - $p.Top) -le 2) { return $o }
    }
    return $null
}

# Capture the overlay and hand back the shot plus its own distinct-color count,
# so every probe below can score the guard as its own assertion.
function Get-OverlayShot($overlay) {
    $shot = Get-TestWindowPixels -Window ([IntPtr]$overlay.Hwnd)
    return @{ Shot = $shot; Colors = (Get-TestDistinctColors -Shot $shot -Inset 2) }
}

# A pixel in OVERLAY-window coordinates as "r,g,b" (the capture is already in
# window coordinates, so this is the direct read the own-DC probe used to be).
function Get-ShotPx($shot, [int]$x, [int]$y) {
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $shot.Width -or $y -ge $shot.Height) { return '' }
    $c = $shot.Bitmap.GetPixel($x, $y)
    return "$($c.R),$($c.G),$($c.B)"
}

# Item strings of a LIVE popup menu, by position; separators come back as
# "---". Takes a menu HANDLE, so it is not desktop-bound and runs from this
# process — window enumeration is the desktop-bound half, and that already goes
# through the harness (the context-menu.ps1 pattern, T165).
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class BannerMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);

    public static string[] Items(IntPtr menu) {
        if (menu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(menu);
        var items = new List<string>();
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { items.Add("---"); continue; } // MF_SEPARATOR
            var sb = new StringBuilder(128);
            GetMenuStringW(menu, i, sb, 128, 0x400);
            items.Add(sb.ToString());
        }
        return items.ToArray();
    }
}
'@

# Clearly-green pixels (the native checked-box stroke) in a window-coordinate
# rect of the capture.
function Measure-ShotGreen($shot, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
    if ($x1 -gt $shot.Width) { $x1 = $shot.Width }
    if ($y1 -gt $shot.Height) { $y1 = $shot.Height }
    $hits = 0
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = $x0; $x -lt $x1; $x++) {
            $c = $shot.Bitmap.GetPixel($x, $y)
            if (($c.G - $c.R) -gt 60 -and ($c.G - $c.B) -gt 60) { $hits++ }
        }
    }
    return $hits
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Pinned dark background so the card pixel oracles are stable, and session
    # persistence OFF so the run starts from a BLANK layout. Without that, the
    # previous run's layout restores — including its own `bw` window with the
    # `bp1` split still in it — and `+new-window --target=bw` idempotently
    # focuses that stale window instead of making a fresh one, so every banner
    # lands on the restored split's focused pane and pane 0 reads empty. That
    # made run 1 pass and runs 2..N fail identically (T131).
    # (`=false`, not `=off`: the CLI bool parser takes true/false only — `off`
    # is silently rejected and the default `true` stays in force.)
    # Launched onto the test desktop rather than by IPC auto-spawn, which would
    # put the GUI on the user's desktop — the whole thing being fixed.
    # stderr captured for 6g's `banner chevron hover=` oracle (T209): the
    # chevron's hover cannot survive to a pixel capture on this desktop, so the
    # TRIGGER is read from the debug log. Empty on a release build, where
    # log.debug is compiled out - 6g then skips rather than lying.
    $errlog = Join-Path $env:TEMP 'ghoztty-pane-banner-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--background=#101014', '--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    & $exe +new-window --target=bw | Out-Null
    $bwWin = $null
    for ($t = 0; $t -lt 25 -and -not $bwWin; $t++) {
        $bwWin = Get-Win 'bw'
        if (-not $bwWin) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $bwWin) { Write-Host 'SETUP FAIL: bw window not registered'; exit 1 }
    # Window ids are the decimal HWND, so the glass probes target exactly the
    # window hosting the 'bw' pane (not the initial launch window).
    $top = [IntPtr]([int64]$bwWin.id)
    Assert ((Get-TestWindowClass -Window $top) -eq 'GhozttyWindow') 'the +list window id really is a GhozttyWindow'

    # Pre-banner pane snapshot for the T101 band asserts: the pane HWND must
    # shrink from the top by exactly the strip height once a banner is up.
    $panePre = $null
    for ($t = 0; $t -lt 20 -and -not $panePre; $t++) { $panePre = Get-Pane $top 0; if (-not $panePre) { Start-Sleep -Milliseconds 200 } }
    if (-not $panePre) { Write-Host 'SETUP FAIL: no pane HWND in bw'; exit 1 }

    # --- 1. +set-banner sets the model (additive +list field) -----------------
    & $exe +set-banner --target=bw "**PR #123** - ready [view](https://example.com/pr/123)" | Out-Null
    $b = Wait-Banner 'bw' 0 '**PR #123** - ready [view](https://example.com/pr/123)'
    Assert ($b -ceq '**PR #123** - ready [view](https://example.com/pr/123)') "+set-banner: +list reports banner source (got $b)"

    # --- 2. overlay strip on the glass: glued above the pane, full width ------
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $_.Visible })
    Assert ($panes.Count -ge 1) "pane HWND found ($($panes.Count))"
    $ov = $null
    for ($t = 0; $t -lt 20 -and -not $ov; $t++) { $ov = Get-Overlay $appPid $top; if (-not $ov) { Start-Sleep -Milliseconds 200 } }
    Assert ($null -ne $ov) 'overlay visible and glued above the pane (bottom meets grid top)'
    $paneRect = Get-Pane $top 0
    $oneLineH = 0
    if ($ov) {
        $oneLineH = $ov.Height
        Assert ($ov.Width -eq $paneRect.Width) 'overlay spans the pane width'
        # Band = card (2x padding + one line) + 2x the card's outer margin
        # (T131), so the sane bound is looser than the pre-card strip's.
        Assert ($oneLineH -gt 0 -and $oneLineH -lt 120) "one-line band height sane ($oneLineH px)"
    }

    # --- 2b. T101: the strip band is RESERVED — grid starts below the banner ---
    # The pane HWND top moved down by exactly the strip height (vs the
    # pre-banner snapshot) and the pane bottom is unchanged: the terminal
    # genuinely shrank into the band below the strip instead of being covered.
    if ($ov) {
        Assert (($paneRect.Top - $panePre.Top) -eq $oneLineH) "pane top moved down by the strip height ($($panePre.Top) -> $($paneRect.Top), strip $oneLineH)"
        Assert ($paneRect.Bottom -eq $panePre.Bottom) 'pane bottom unchanged (terminal shrank, not shifted)'
    } else { $script:fail += 2 }

    # --- 3. T131 glass card: floating, opaque, exact wash fill ---------------
    # The band is the pane background with a rounded card floating a uniform
    # margin inside it. Oracles are pinned to #101014: the card fill is Mac's
    # `white @ 6%` composite = rgb(30,30,34), the band is rgb(16,16,20).
    if ($ov) {
        # The move is kept from the pre-migration script — not to park the
        # window away from other windows (there is no screen composite here to
        # pollute) but because it exercises reposition tracking: WM_MOVE ->
        # updatePaneBanners re-glues the strip.
        Set-TestWindowPos -Window $top -X 100 -Y 100 | Out-Null
        Start-Sleep -Milliseconds 900
        $paneRect = Get-Pane $top 0
        $ov = Get-Overlay $appPid $top
        Assert ($null -ne $ov) 'overlay re-glued above the pane after a window move'
        if ($ov) {
            $cap = Get-OverlayShot $ov
            $shot = $cap.Shot
            try {
                Assert ($cap.Colors -ge 8) "the overlay capture holds real content ($($cap.Colors) distinct colors)"
                # Sample low in the card, where neither specular ramp is in play
                # (the sheen has faded, the bottom darkening starts at 75%).
                $cardY = [int]($oneLineH * 0.72)
                $sx = [int]($ov.Width * 0.9)
                $stripPx = Get-ShotPx $shot $sx $cardY
                $sp = $stripPx -split ','
                $okBand = ($sp.Count -eq 3) -and
                    ([math]::Abs([int]$sp[0] - 30) -le 3) -and
                    ([math]::Abs([int]$sp[1] - 30) -le 3) -and
                    ([math]::Abs([int]$sp[2] - 34) -le 3)
                # -NegativeControl inverts THIS one: it is the pixel oracle, so
                # inverting it proves the capture path really discriminates
                # rather than returning something every threshold accepts.
                $script:negReached = $true
                if ($NegativeControl) { $okBand = -not $okBand }
                Assert $okBand "composited card is the white@6% wash (got $stripPx, want ~30,30,34)"

                # The band's own top-left corner is OUTSIDE the card: it must
                # read the pane background EXACTLY. A translucent overlay (the
                # pre-T131 strip) leaks whatever is behind the band through here
                # — that is the "text scrolls behind the banner" bug.
                $cornerPx = Get-ShotPx $shot 2 2
                Assert ($cornerPx -eq '16,16,20') "band corner is the pane background, and the card is inset by a margin (got $cornerPx)"

                # Opacity, without a screen composite to compare against: the
                # popup is layered, and what made composited == own-DC in the
                # first place is alpha 255 with nothing keyed out.
                $la = Get-TestLayeredAttrs -Window ([IntPtr]$ov.Hwnd)
                Assert ($la.Ok -and $la.Alpha -eq 255 -and ($la.Flags -band 2) -ne 0 -and ($la.Flags -band 1) -eq 0) `
                    "card is fully opaque: layered alpha 255, LWA_ALPHA, no colour key (ok=$($la.Ok) alpha=$($la.Alpha) flags=$($la.Flags))"

                # Elevation shadow: somewhere in the bottom margin the band is
                # DARKER than the bare pane background (the margin is DPI-scaled,
                # so scan it rather than pinning one row).
                $darkest = 999
                $shadowPx = ''
                for ($dy = 2; $dy -le 14; $dy++) {
                    $s = Get-ShotPx $shot ([int]($ov.Width / 2)) ($oneLineH - $dy)
                    $parts = $s -split ','
                    if ($parts.Count -ne 3) { continue }
                    $sum = [int]$parts[0] + [int]$parts[1] + [int]$parts[2]
                    if ($sum -lt $darkest) { $darkest = $sum; $shadowPx = $s }
                }
                Assert ($darkest -lt 52) "elevation shadow darkens the band under the card (darkest $shadowPx vs bg 16,16,20)"
            } finally { Close-TestWindowPixels -Shot $shot }
        } else {
            $script:fail += 5
        }
    } else {
        $script:fail += 6
    }

    # --- 4. multi-line: \n grows the strip; 10-line display cap ---------------
    & $exe +set-banner --target=bw "line1\nline2\nline3" | Out-Null
    $b = Wait-Banner 'bw' 0 "line1`nline2`nline3"
    Assert ($b -ceq "line1`nline2`nline3") 'multi-line: +list carries real newlines'
    $ov3 = Get-Overlay $appPid $top
    $threeLineH = 0
    if ($ov3) { $threeLineH = $ov3.Height }
    Assert ($threeLineH -gt $oneLineH + 10) "3-line strip taller than 1-line ($oneLineH -> $threeLineH px)"

    # 12 source lines must clamp to 10 display lines: between 9 and 10 lines'
    # height (a 2-line pair adds $twoLines px = 2 * (line height + block gap)).
    & $exe +set-banner --target=bw "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl" | Out-Null
    Start-Sleep -Milliseconds 800
    $ovCap = Get-Overlay $appPid $top
    $capH = 0
    if ($ovCap) { $capH = $ovCap.Height }
    $twoLines = $threeLineH - $oneLineH
    Assert ($capH -gt ($oneLineH + 4 * $twoLines) -and $capH -le ($oneLineH + 4.5 * $twoLines + 8)) "12-line source capped at 10 display lines ($capH px)"

    # --- 5. --clear removes model + glass, reverts the pixel ------------------
    $paneWithCap = Get-Pane $top 0   # capped banner still up (T101)
    & $exe +set-banner --target=bw --clear | Out-Null
    $b = Wait-Banner 'bw' 0 'NONE'
    Assert ($b -eq '(absent)') '--clear: banner absent from +list'
    Start-Sleep -Milliseconds 500
    Assert ($null -eq (Get-Overlay $appPid $top)) '--clear: overlay gone'
    Assert ((@(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')).Count -eq 0) '--clear: no overlay windows remain on the glass'
    # T101: the vacated strip band went back to the terminal.
    $paneCleared = Get-Pane $top 0
    Assert (($paneWithCap.Top - $paneCleared.Top) -eq $capH) "--clear: grid grew back by the strip height ($capH px)"

    # --- 6. empty text equals clear; clearing when clear succeeds -------------
    & $exe +set-banner --target=bw "again" | Out-Null
    $null = Wait-Banner 'bw' 0 'again'
    & $exe +set-banner --target=bw "" | Out-Null
    $b = Wait-Banner 'bw' 0 'NONE'
    Assert ($b -eq '(absent)') 'empty text clears'
    & $exe +set-banner --target=bw --clear | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'clearing an already-clear banner succeeds'

    # --- 6b. T91: heading renders taller than a plain text line ----------------
    & $exe +set-banner --target=bw "# Big title" | Out-Null
    $null = Wait-Banner 'bw' 0 '# Big title'
    $ovHead = Get-Overlay $appPid $top
    $headH = 0
    if ($ovHead) { $headH = $ovHead.Height }
    Assert ($headH -gt ($oneLineH + 4)) "h1 heading strip taller than plain line ($oneLineH -> $headH px)"

    # --- 6c. T91: --- thematic break renders as a thin rule row ----------------
    # text + rule + text sits between a 2-line and a 3-line text banner: the
    # rule row is a 1px line, thinner than a text line.
    & $exe +set-banner --target=bw "top\n---\nbottom" | Out-Null
    $null = Wait-Banner 'bw' 0 "top`n---`nbottom"
    $ovR = Get-Overlay $appPid $top
    $hrH = 0
    if ($ovR) { $hrH = $ovR.Height }
    $twoLineH = $oneLineH + [int]($twoLines / 2)
    Assert ($hrH -gt $twoLineH -and $hrH -lt $threeLineH) "hr row is thinner than a text row ($twoLineH < $hrH < $threeLineH)"

    # --- 6d. T91: pipe table renders (separator row dropped) -------------------
    & $exe +set-banner --target=bw "| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |" | Out-Null
    $null = Wait-Banner 'bw' 0 "| Job | State |`n|---|---:|`n| lint | ok |`n| tests | **3 failed** |"
    $ovT = Get-Overlay $appPid $top
    $tblH = 0
    if ($ovT) { $tblH = $ovT.Height }
    # 4 source lines -> 3 display rows (header + 2 body; separator dropped):
    # taller than 2 text lines, no taller than ~3 text lines + header divider.
    Assert ($tblH -gt $twoLineH -and $tblH -le ($threeLineH + 10)) "table: 4 source lines render 3 rows ($tblH px)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'table banner: GUI alive after paint'

    # --- 6e. T91: checked task-list box paints native green --------------------
    & $exe +set-banner --target=bw "[x] done\n[ ] todo" | Out-Null
    $null = Wait-Banner 'bw' 0 "[x] done`n[ ] todo"
    Start-Sleep -Milliseconds 400
    $ovC = Get-Overlay $appPid $top
    if ($ovC) {
        $capC = Get-OverlayShot $ovC
        try {
            Assert ($capC.Colors -ge 8) "the checkbox capture holds real content ($($capC.Colors) distinct colors)"
            # First list row's marker gutter sits just inside the card's 12dip
            # padding, which is itself one 12dip card margin in from the band edge
            # (T131) — so scan from the band origin out past both.
            $green = Measure-ShotGreen $capC.Shot 5 5 80 80
            Assert ($green -ge 3) "checked box paints green check pixels ($green found)"
        } finally { Close-TestWindowPixels -Shot $capC.Shot }
    } else {
        $script:fail += 2
        Write-Host 'FAIL  checkbox overlay not found' -ForegroundColor Red
    }

    # --- 6f. T91: multi-line banner collapses on click, expands on click -------
    & $exe +set-banner --target=bw "head\nrow2\nrow3" | Out-Null
    $null = Wait-Banner 'bw' 0 "head`nrow2`nrow3"
    Start-Sleep -Milliseconds 400
    $ovE = Get-Overlay $appPid $top
    if ($ovE) {
        $expandH = $ovE.Height
        $paneExp = Get-Pane $top 0
        $ovHwnd = [IntPtr]$ovE.Hwnd
        $midX = $ovE.Left + [int]($ovE.Width / 2)
        Send-TestMouse -Window $top -Target $ovHwnd -X $midX -Y ($ovE.Top + [int]($oneLineH / 2)) | Out-Null
        $collapseH = $expandH
        for ($t = 0; $t -lt 20; $t++) {
            Start-Sleep -Milliseconds 150
            $ov2 = Get-Overlay $appPid $top
            if ($ov2) { $collapseH = $ov2.Height }
            if ($collapseH -lt $expandH) { break }
        }
        Assert ($collapseH -lt ($expandH - 20) -and $collapseH -gt 20) "click collapses the banner ($expandH -> $collapseH px)"
        # T101: the terminal band grew by exactly the collapsed delta (the
        # Get-Overlay matcher already proves the strip re-glued above the
        # moved pane top; this pins the magnitude).
        $paneCol = Get-Pane $top 0
        Assert (($paneExp.Top - $paneCol.Top) -eq ($expandH - $collapseH)) "collapse gave the band back to the grid ($expandH -> $collapseH strip, pane top $($paneExp.Top) -> $($paneCol.Top))"
        $ovCol = Get-Overlay $appPid $top
        if ($ovCol) {
            Send-TestMouse -Window $top -Target ([IntPtr]$ovCol.Hwnd) -X $midX -Y ($ovCol.Top + [int]($collapseH / 2)) | Out-Null
        }
        $reH = $collapseH
        for ($t = 0; $t -lt 20; $t++) {
            Start-Sleep -Milliseconds 150
            $ov2 = Get-Overlay $appPid $top
            if ($ov2) { $reH = $ov2.Height }
            if ($reH -eq $expandH) { break }
        }
        Assert ($reH -eq $expandH) "second click expands back ($collapseH -> $reH px)"
    } else {
        $script:fail += 3
        Write-Host 'FAIL  collapse overlay not found' -ForegroundColor Red
    }

    # --- 6g. T209 / T204: the chevron is an ICON BUTTON, and hot-tracks ------
    #
    # The user's report named it directly: "why doesn't the chevron in the
    # banner have a similar hover?" Pre-T204 it had no hover state at all - no
    # `hover_chevron`, no `TrackMouseEvent`, no fill - so it gave no feedback
    # that it was a button.
    #
    # Same split as tab-strip.ps1's 4c, and for the same measured reason: a
    # posted WM_MOUSEMOVE cannot HOLD a hover here (TrackMouseEvent watches the
    # real cursor, WM_MOUSELEAVE is posted, and posted messages are drained
    # before the WM_PAINT the move dirtied), so the hovered frame is never
    # painted at all. The TRIGGER is asserted from the debug oracle; the FILL
    # is probed best-effort and skips when the race is lost - its co-witness is
    # `paintIconButton`'s own pixels in caption-bar.ps1 (a pressed caption
    # button, which does survive, on the identical fill path).
    & $exe +set-banner --target=bw "chev1\nchev2\nchev3" | Out-Null
    $null = Wait-Banner 'bw' 0 "chev1`nchev2`nchev3"
    Start-Sleep -Milliseconds 500
    $ovC = Get-Overlay $appPid $top
    if (-not $ovC) {
        $script:fail += 1
        Write-Host 'FAIL  chevron overlay not found' -ForegroundColor Red
    } else {
        # `BannerOverlay.chevronBox`, in the overlay's own client space: the
        # shared 28 DIP square, one card MARGIN in from the right, centered on
        # the card's first content line.
        $ovHwnd2 = [IntPtr]$ovC.Hwnd
        $bScale = (Get-TestWindowDpi -Window $ovHwnd2) / 96.0
        $side   = Get-TestChromeDip -Dip 28.0 -Scale $bScale
        $margin = Get-TestChromeDip -Dip 12.0 -Scale $bScale
        $pad    = Get-TestChromeDip -Dip 12.0 -Scale $bScale
        $lineH  = Get-TestChromeDip -Dip 20.0 -Scale $bScale
        $chCy   = $margin + $pad + [int][Math]::Truncate($lineH / 2)
        $chL    = $ovC.Width - $margin - $side
        $chCx   = $chL + [int][Math]::Truncate($side / 2)
        Write-Host "INFO  chevron box: left=$chL cy=$chCy side=$side (overlay $($ovC.Width)x$($ovC.Height))"

        $chevLogged = $false
        if (Test-Path $errlog) {
            # ONE window over both moves, deliberately. Clearing the log
            # between them loses the un-hover: on this desktop WM_MOUSELEAVE
            # arrives a frame after the move (there is no real pointer to
            # leave with), so the `false` is already written - and then the
            # second move finds the state ALREADY false, changes nothing, and
            # logs nothing. What is being asserted is the state machine's
            # shape: it goes lit, and it comes back, in that order.
            Clear-Content $errlog -ErrorAction SilentlyContinue
            Send-TestMouse -Window $top -Target $ovHwnd2 -X ($ovC.Left + $chCx) -Y ($ovC.Top + $chCy) -Action move | Out-Null
            Start-Sleep -Milliseconds 300
            Send-TestMouse -Window $top -Target $ovHwnd2 -X ($ovC.Left + $margin + 4) -Y ($ovC.Top + $chCy) -Action move | Out-Null
            Start-Sleep -Milliseconds 300
            $chevLines = @(Select-String -Path $errlog -Pattern 'banner chevron hover=(true|false)' -ErrorAction SilentlyContinue |
                           ForEach-Object { $_.Matches[0].Groups[1].Value })
            $chevLogged = ($chevLines -contains 'true')
            if ($chevLogged) {
                Write-Host "INFO  chevron hover log: $($chevLines -join ',')"
                Assert ($chevLines[0] -eq 'true') `
                    'T204: the banner chevron hot-tracks - a move onto it sets hover'
                Assert ($chevLines -contains 'false') `
                    'T204: ...and it un-hovers again rather than latching lit'
            }
        }
        if (-not $chevLogged) {
            Write-Host 'SKIP T209 chevron trigger: no debug oracle in the log (release build?)'
        }

        # The FILL, best effort. `fillRegion` insets the square by 2 DIP and
        # rounds it by 4, so the fill's top edge at the square's horizontal
        # center is lit and its top-left CORNER pixel is cut away - the same
        # two probes tab-strip.ps1 uses, which is what distinguishes a rounded
        # fill from a square one.
        $inset = Get-TestChromeDip -Dip 2.0 -Scale $bScale
        $chTop = $chCy - [int][Math]::Truncate($side / 2)
        function Probe-Chev {
            $s = Get-TestWindowPixels -Window $ovHwnd2
            if ((Get-TestDistinctColors -Shot $s) -lt 8) { Close-TestWindowPixels $s; return $null }
            $e = $s.Bitmap.GetPixel($chCx, $chTop + $inset + 1)
            $c = $s.Bitmap.GetPixel($chL + $inset, $chTop + $inset)
            Close-TestWindowPixels $s
            return [pscustomobject]@{ Edge = [int]$e.R; Corner = [int]$c.R }
        }
        Send-TestMouse -Window $top -Target $ovHwnd2 -X ($ovC.Left + $margin + 4) -Y ($ovC.Top + $chCy) -Action move | Out-Null
        Start-Sleep -Milliseconds 250
        $chRest = Probe-Chev
        $chHot = $null
        if ($null -ne $chRest) {
            for ($i = 0; $i -lt 12; $i++) {
                for ($b = 0; $b -lt 25; $b++) {
                    Send-TestMouse -Window $top -Target $ovHwnd2 -X ($ovC.Left + $chCx) -Y ($ovC.Top + $chCy) -Action move | Out-Null
                }
                $p = Probe-Chev
                if ($null -ne $p -and $p.Edge -ge ($chRest.Edge + 6)) { $chHot = $p; break }
                Send-TestMouse -Window $top -Target $ovHwnd2 -X ($ovC.Left + $margin + 4) -Y ($ovC.Top + $chCy) -Action move | Out-Null
            }
        }
        Write-Host "INFO  chevron fill: rest=$(if($chRest){$chRest.Edge}) hot=$(if($chHot){$chHot.Edge})"
        if ($null -eq $chHot) {
            Write-Host 'SKIP T209 chevron fill: the hovered frame was never painted (harness limit, see the section header)'
        } else {
            Assert ($chHot.Edge -ge ($chRest.Edge + 6)) `
                "T204: hovering the chevron lights a fill (rest=$($chRest.Edge) hot=$($chHot.Edge))"
            Assert ($chHot.Corner -lt ($chHot.Edge - 4)) `
                "T204: that fill is ROUNDED - its corner is cut away (corner=$($chHot.Corner) edge=$($chHot.Edge))"
        }
    }

    & $exe +set-banner --target=bw --clear | Out-Null
    $null = Wait-Banner 'bw' 0 'NONE'

    # --- 6g. T123: table columns size to the PANE, not a fixed 360pt cap -------
    # The banner used to size every table column at min(natural, 360px), so a
    # value wider than 360 wrapped on a pane with hundreds of px to spare, and
    # narrowing the pane never rewrapped it. Every oracle here is the BAND
    # HEIGHT, which is the number of display rows the table produced — a
    # self-relative measure that needs no pixel constants.
    $oneRow = [int]($twoLines / 2)   # one text row incl. its row gap
    # Wide value: naturally ~2x the old 360px cap, but comfortably inside a
    # 1400px pane. Short value: the same table with a one-word value.
    $longVal = 'ready to merge after the final review pass lands on main'
    $tblLong = "| Goal | Value |\n|---|---|\n| ship | $longVal |"
    $tblShort = "| Goal | Value |\n|---|---|\n| ship | ok |"
    function Get-BandH([string]$text) {
        & $exe +set-banner --target=bw $text | Out-Null
        $null = Wait-Banner 'bw' 0 ($text -replace '\\n', "`n")
        Start-Sleep -Milliseconds 700
        $o = Get-Overlay $appPid $top
        if (-not $o) { return 0 }
        return $o.Height
    }

    # Wide pane: the long value must NOT wrap - it fits, so it gets its natural
    # width and the table is the same height as the short-value one.
    Set-TestWindowPos -Window $top -X 100 -Y 100 -Width 1400 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 900
    $wideShortH = Get-BandH $tblShort
    $wideLongH = Get-BandH $tblLong
    $paneWide = Get-Pane $top 0
    $wideW = $paneWide.Width
    Assert ($wideShortH -gt 0 -and $wideLongH -gt 0) "wide pane: banner measured ($wideShortH / $wideLongH px)"
    Assert ($wideLongH -eq $wideShortH) "wide pane: a >360px value does not wrap (short $wideShortH == long $wideLongH px)"

    # Narrow pane: the SAME banner must reflow - more rows, taller band. Before
    # the fix the columns were pinned at 360px and this height never moved.
    Set-TestWindowPos -Window $top -X 100 -Y 100 -Width 520 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 900
    $narrowLongH = Get-BandH $tblLong
    $paneNarrow = Get-Pane $top 0
    $narrowW = $paneNarrow.Width
    Assert ($narrowW -lt $wideW - 500) "the pane really shrank ($wideW -> $narrowW px): the banner is no minimum width"
    Assert ($narrowLongH -gt $wideLongH) "narrow pane: the table reflowed taller ($wideLongH -> $narrowLongH px)"
    # A wrapped line INSIDE a cell adds the bare line height, while $oneRow is
    # a line height plus the 8/20 inter-block gap - so a real extra display
    # line is always more than 60% of $oneRow, at any DPI. That separates a
    # genuine rewrap from a rounding wobble without hard-coding pixels.
    Assert (($narrowLongH - $wideLongH) -ge [int]($oneRow * 0.6)) "narrow pane: reflow added a whole display line (+$($narrowLongH - $wideLongH) px, row ~$oneRow px)"

    # A long UNBROKEN token has no space to wrap at, so it must break
    # mid-string; before the fix it took one over-wide line and clipped.
    $blob = 'A' * 90
    $narrowBlobH = Get-BandH "| K | V |\n|---|---|\n| x | $blob |"
    Assert ($narrowBlobH -gt ($wideShortH + $oneRow - 4)) "narrow pane: a 90-char unbroken token breaks mid-string ($narrowBlobH px vs 1-row $wideShortH px)"

    # A cell is capped at 3 display lines: 4x the text must not make the band
    # any taller than 2x did.
    $sentence = 'the quick brown fox jumps over the lazy dog and keeps on running '
    $cap2 = Get-BandH ("| K | V |\n|---|---|\n| x | " + ($sentence * 2).Trim() + " |")
    $cap8 = Get-BandH ("| K | V |\n|---|---|\n| x | " + ($sentence * 8).Trim() + " |")
    Assert ($cap8 -eq $cap2) "cell capped at 3 wrapped lines: 4x the text is the same height ($cap2 vs $cap8 px)"
    # 3 lines instead of 1 is +2 display lines, each smaller than $oneRow.
    Assert ($cap8 -le ($wideShortH + 2 * $oneRow)) "capped cell stays within header + 3 lines ($cap8 px, 1-row $wideShortH px, row ~$oneRow px)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'reflow section: GUI alive'

    # --- 6h. T377: EVERY block wraps, caps at 3 lines, clears the chevron -----
    # Table cells were the only thing that wrapped: `wrapTokens` had exactly one
    # call site. A paragraph, a heading and a list row were each drawn with one
    # `drawInlineLine` at a fixed line height, so they ran off the card edge and
    # under the collapse chevron - the user's two screenshots (2026-08-02,
    # 2026-08-04). Same oracle as 6g: the BAND HEIGHT, which is the number of
    # display rows the content produced.
    Set-TestWindowPos -Window $top -X 100 -Y 100 -Width 760 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 900

    # Short words on purpose: a greedy wrap then leaves only a few px of slack
    # at each line end, which the chevron-column probe below depends on.
    $para2 = ($sentence * 2).Trim()
    $wrapOne = Get-BandH 'wrap me'
    $wrapTwo = Get-BandH $para2
    Assert ($wrapOne -gt 0 -and $wrapTwo -gt 0) "wrap: bands measured ($wrapOne / $wrapTwo px)"
    Assert (($wrapTwo - $wrapOne) -ge [int]($oneRow * 0.6)) `
        "T377: a plain paragraph wraps instead of clipping (+$($wrapTwo - $wrapOne) px, row ~$oneRow px)"

    # ...and is capped at 3 display lines, like a table cell: 12x the text is
    # no taller than 8x, and both stay within one line plus two.
    $wrap8 = Get-BandH ($sentence * 8).Trim()
    $wrap12 = Get-BandH ($sentence * 12).Trim()
    Assert ($wrap12 -eq $wrap8) "T377: a paragraph caps at 3 wrapped lines (8x $wrap8 == 12x $wrap12 px)"
    Assert ($wrap8 -le ($wrapOne + 2 * $oneRow)) `
        "T377: the capped paragraph stays within 3 lines ($wrap8 px, 1-line $wrapOne px, row ~$oneRow px)"

    # A heading wraps in ITS font (the tokenizer used to measure every run in
    # the base font, which breaks a heading at the wrong words).
    $headOne = Get-BandH '# head'
    $headTwo = Get-BandH ('# ' + $para2)
    Assert (($headTwo - $headOne) -ge [int]($oneRow * 0.6)) `
        "T377: a heading wraps (+$($headTwo - $headOne) px, row ~$oneRow px)"

    # List rows wrap too - bullet AND checkbox. The leading "-" would bind as a
    # flag on the CLI, so both forms carry a one-line prefix block; that prefix
    # is in the baseline as well, so the delta is the wrap and nothing else.
    $bulOne = Get-BandH "list:\n- item"
    $bulTwo = Get-BandH ("list:\n- " + $para2)
    Assert (($bulTwo - $bulOne) -ge [int]($oneRow * 0.6)) `
        "T377: a bullet list row wraps (+$($bulTwo - $bulOne) px, row ~$oneRow px)"
    # A task-list row used to be pinned to one line on the grounds that its
    # native checkbox cannot reflow. The checkbox is the item's MARKER, drawn in
    # the shared gutter - the content beside it wraps like any other row.
    $chkOne = Get-BandH "list:\n- [x] item"
    $chkTwo = Get-BandH ("list:\n- [x] " + $para2)
    Assert (($chkTwo - $chkOne) -ge [int]($oneRow * 0.6)) `
        "T377: a checkbox list row wraps, keeping its box in the gutter (+$($chkTwo - $chkOne) px)"

    # The chevron owns the whole right strip: NOTHING may paint into the clear
    # gap left of its box. Pre-fix the content column ran to one card PADDING
    # (12 DIP) from the band edge, which is 20 DIP inside the chevron's own
    # column - so text crossed this gap on every long line.
    & $exe +set-banner --target=bw "$para2\ntail" | Out-Null
    $null = Wait-Banner 'bw' 0 "$para2`ntail"
    Start-Sleep -Milliseconds 800
    $ovW = Get-Overlay $appPid $top
    if (-not $ovW) {
        $script:fail += 2
        Write-Host 'FAIL  T377 chevron-column probe: no overlay' -ForegroundColor Red
    } else {
        $wHwnd = [IntPtr]$ovW.Hwnd
        $wScale = (Get-TestWindowDpi -Window $wHwnd) / 96.0
        $wSide = Get-TestChromeDip -Dip 28.0 -Scale $wScale
        $wMargin = Get-TestChromeDip -Dip 12.0 -Scale $wScale
        $wPad = Get-TestChromeDip -Dip 12.0 -Scale $wScale
        $wLine = Get-TestChromeDip -Dip 20.0 -Scale $wScale
        $wGap = Get-TestChromeDip -Dip 4.0 -Scale $wScale
        $chL = $ovW.Width - $wMargin - $wSide
        $rowTop = $wMargin + $wPad
        $refX = $wMargin + [int][Math]::Truncate($wPad / 2)
        Write-Host "INFO  T377 probe: chevronL=$chL gap=$wGap row=$rowTop..$($rowTop + $wLine) ref=$refX (overlay $($ovW.Width)x$($ovW.Height))"

        $shotW = Get-TestWindowPixels -Window $wHwnd
        try {
            if ((Get-TestDistinctColors -Shot $shotW) -lt 8) {
                $script:fail += 2
                Write-Host 'FAIL  T377 chevron-column probe: capture holds no content' -ForegroundColor Red
            } else {
                # "Ink" = a pixel that differs from its OWN row's empty-card
                # color. Reading the reference per row is what makes this
                # immune to the card's vertical sheen ramp.
                $yLo = $rowTop + 3
                $yHi = $rowTop + $wLine - 3
                $gapInk = 0
                $gapPx = ''
                $rightMost = -1
                for ($py = $yLo; $py -le $yHi; $py++) {
                    $ref = $shotW.Bitmap.GetPixel($refX, $py)
                    # The clear gap, minus one column of antialias slack at
                    # each end.
                    for ($px = ($chL - $wGap + 1); $px -lt $chL; $px++) {
                        $c = $shotW.Bitmap.GetPixel($px, $py)
                        if ([Math]::Abs([int]$c.R - [int]$ref.R) -gt 12) {
                            $gapInk++
                            if ($gapPx -eq '') { $gapPx = "($px,$py)=$($c.R),$($c.G),$($c.B) vs $($ref.R),$($ref.G),$($ref.B)" }
                        }
                    }
                    # ...and how far right the text actually got, so this
                    # cannot pass just because the line came up empty.
                    for ($px = ($wMargin + $wPad); $px -lt ($chL - $wGap); $px++) {
                        $c = $shotW.Bitmap.GetPixel($px, $py)
                        if ([Math]::Abs([int]$c.R - [int]$ref.R) -gt 12 -and $px -gt $rightMost) { $rightMost = $px }
                    }
                }
                Write-Host "INFO  T377 probe: gapInk=$gapInk rightmostInk=$rightMost $gapPx"
                Assert ($rightMost -ge ($chL - $wGap - 5 * $wLine)) `
                    "T377: the wrapped line really fills the content column (rightmost ink $rightMost, column ends $($chL - $wGap))"
                Assert ($gapInk -eq 0) `
                    "T377: nothing paints into the chevron's reserved column ($gapInk ink px$(if($gapPx){" first $gapPx"}))"
            }
        } finally { Close-TestWindowPixels -Shot $shotW }
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'T377 section: GUI alive'

    & $exe +set-banner --target=bw --clear | Out-Null
    $null = Wait-Banner 'bw' 0 'NONE'
    Set-TestWindowPos -Window $top -X 100 -Y 100 -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 900

    # --- 6i. T165: banner links have a hover affordance and an action menu ----
    # Mac parity (BannerText + BannerLinkOpener): a link's underline is DOTTED
    # at rest and SOLID while the pointer is over it, and a right-click opens
    # the action menu whose FIRST row is by contract the left-click default.
    #
    # Oracles, in order of how much they can be trusted on this desktop:
    #   * the rule itself, from the overlay's own capture. The link label is
    #     ALL CAPS on purpose - no descender can put glyph ink on the
    #     underline row and turn a dotted rule into a "solid" one.
    #   * the hover STATE, from the `banner link hover=` debug line, the same
    #     deal as 6f's chevron: hover cannot survive to a capture here, so the
    #     trigger is read from the log and the pixels are probed separately.
    #   * the MENU, read live out of the tracking popup with MN_GETHMENU.
    #   * Ctrl+click, end to end: the pane count in `+list --json` goes up and
    #     the new pane is a VIEWER. That is the whole modifier scheme's payoff
    #     and it needs no pixels at all.
    $linkLabel = 'LINKLINKLINK'
    & $exe +set-banner --target=bw "[$linkLabel](about:blank)" | Out-Null
    $null = Wait-Banner 'bw' 0 "[$linkLabel](about:blank)"
    Start-Sleep -Milliseconds 700
    $ovL = Get-Overlay $appPid $top
    if (-not $ovL) {
        $script:fail += 1
        Write-Host 'FAIL  T165: no banner overlay for the link banner' -ForegroundColor Red
    } else {
        $lHwnd = [IntPtr]$ovL.Hwnd
        $lScale = (Get-TestWindowDpi -Window $lHwnd) / 96.0
        $lMargin = Get-TestChromeDip -Dip 12.0 -Scale $lScale
        $lPad = Get-TestChromeDip -Dip 12.0 -Scale $lScale
        $lLine = Get-TestChromeDip -Dip 20.0 -Scale $lScale
        # A single-line banner is NOT collapsible, so there is no chevron and
        # content starts at one margin + one padding, on the first text row.
        $lx = $lMargin + $lPad
        $ly = $lMargin + $lPad + [int][Math]::Truncate($lLine / 2)
        Write-Host "INFO  T165 link box: x=$lx rowCy=$ly (overlay $($ovL.Width)x$($ovL.Height) scale=$lScale)"

        # Link-colored ink: link_fg is a blue (RGB 90,160,255 on dark), the
        # card wash is a near-neutral grey, so B-R separates them with room to
        # spare and needs no absolute constant.
        function Measure-LinkRows($shot) {
            $rows = @{}
            for ($py = 0; $py -lt $shot.Height; $py++) {
                $n = 0; $lo = -1; $hi = -1
                for ($px = 0; $px -lt $shot.Width; $px++) {
                    $c = $shot.Bitmap.GetPixel($px, $py)
                    if (([int]$c.B - [int]$c.R) -gt 40) {
                        $n++
                        if ($lo -lt 0) { $lo = $px }
                        $hi = $px
                    }
                }
                if ($n -gt 0) { $rows[$py] = [pscustomobject]@{ N = $n; Lo = $lo; Hi = $hi } }
            }
            return $rows
        }
        # The underline is the BOTTOM-most link-colored row: it sits at the
        # foot of the text box, under every (capital) glyph.
        function Get-RuleRow {
            $s = Get-TestWindowPixels -Window $lHwnd
            try {
                if ((Get-TestDistinctColors -Shot $s) -lt 8) { return $null }
                $rows = Measure-LinkRows $s
                if ($rows.Count -eq 0) { return $null }
                $last = ($rows.Keys | Sort-Object)[-1]
                return $rows[$last]
            } finally { Close-TestWindowPixels -Shot $s }
        }

        # Park the pointer away from the link first, so "at rest" really is.
        Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $ovL.Width - $lMargin - 2) -Y ($ovL.Top + $ly) -Action move | Out-Null
        Start-Sleep -Milliseconds 250
        $rest = Get-RuleRow
        if ($null -eq $rest) {
            $script:fail += 2
            Write-Host 'FAIL  T165: no link-colored ink in the overlay capture at all' -ForegroundColor Red
        } else {
            $span = $rest.Hi - $rest.Lo + 1
            Write-Host "INFO  T165 rest rule: ink=$($rest.N) span=$span ($($rest.Lo)..$($rest.Hi))"
            Assert ($span -gt 4 * $lScale) `
                "T165: a link carries an underline rule at rest (span $span px)"
            # DOTTED, not solid: the rule's own ink covers well under its span.
            # The pattern is 1 on / 2 off, so a solid rule would score ~1.0 and
            # this discriminates at any DPI.
            Assert ($rest.N -le [int]($span * 0.6)) `
                "T165: that rule is DOTTED at rest, not solid ($($rest.N) ink px over a $span px span)"
            # (No second -NegativeControl inversion here: the pair of
            # assertions above and the solid-on-hover one below already
            # discriminate in BOTH directions, which is what a negative
            # control buys. The script's one inverted assertion stays the band
            # oracle in section 3.)

            # Hover: the state machine, from the debug log.
            $linkLogged = $false
            if (Test-Path $errlog) {
                Clear-Content $errlog -ErrorAction SilentlyContinue
                Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $lx + 2) -Y ($ovL.Top + $ly) -Action move | Out-Null
                Start-Sleep -Milliseconds 300
                Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $ovL.Width - $lMargin - 2) -Y ($ovL.Top + $ly) -Action move | Out-Null
                Start-Sleep -Milliseconds 300
                $lLines = @(Select-String -Path $errlog -Pattern 'banner link hover=(true|false)' -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.Matches[0].Groups[1].Value })
                $linkLogged = ($lLines -contains 'true')
                if ($linkLogged) {
                    Write-Host "INFO  T165 link hover log: $($lLines -join ',')"
                    Assert ($lLines[0] -eq 'true') 'T165: moving onto a link sets the hover'
                    Assert ($lLines -contains 'false') 'T165: ...and moving off clears it rather than latching'
                }
            }
            if (-not $linkLogged) {
                Write-Host 'SKIP T165 hover trigger: no debug oracle in the log (release build?)'
            }

            # ...and the RULE going solid, best effort - the same harness limit
            # 6f documents for the chevron fill: the hovered frame has to be
            # captured before the un-hover lands.
            $hot = $null
            for ($i = 0; $i -lt 12; $i++) {
                for ($b = 0; $b -lt 25; $b++) {
                    Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $lx + 2) -Y ($ovL.Top + $ly) -Action move | Out-Null
                }
                $p = Get-RuleRow
                if ($null -ne $p -and $p.N -gt [int]($span * 0.8)) { $hot = $p; break }
                Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $ovL.Width - $lMargin - 2) -Y ($ovL.Top + $ly) -Action move | Out-Null
            }
            if ($null -eq $hot) {
                # Not a hole: the dotted->solid transition is asserted in
                # PIXELS by the zig test "banner overlay: a link's underline
                # is dotted at rest and solid on hover", which paints the same
                # banner twice into a DIB with only `hover_link` different and
                # so needs no pointer at all.
                Write-Host 'SKIP T165 solid rule: the hovered frame was never captured (harness limit, see 6f; covered by the zig pixel test)'
            } else {
                Write-Host "INFO  T165 hot rule: ink=$($hot.N) span=$($hot.Hi - $hot.Lo + 1)"
                Assert ($hot.N -gt $rest.N) `
                    "T165: hovering fills the rule in ($($rest.N) -> $($hot.N) ink px)"
            }
        }

        # The action menu. Right-click ON the link opens it; right-click on
        # empty card does NOT (the banner has no menu of its own).
        Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $lx + 2) -Y ($ovL.Top + $ly) `
            -Button right -Action up | Out-Null
        $menu = Wait-TestPopupMenu -ProcessId $appPid -TimeoutMs 4000
        Assert ($menu -ne [IntPtr]::Zero) 'T165: right-clicking a banner link opens a menu'
        if ($menu -ne [IntPtr]::Zero) {
            $r = Invoke-TestMessage -Window $menu -Message 0x01E1  # MN_GETHMENU
            $items = if ($r -eq [long]::MinValue -or $r -eq 0) { @() } else { [BannerMenuRead]::Items([IntPtr]$r) }
            Write-Host "      link menu items: $($items -join ' | ')"
            $expected = @(
                'Open in Default Browser', '---',
                'Open in Side Pane', 'Open in New Window', '---',
                'Copy Link'
            )
            Assert (($items -join '|') -eq ($expected -join '|')) `
                'T165: the web-link menu carries exactly the Mac-parity rows, in order'
            Assert ($items[0] -eq 'Open in Default Browser') `
                'T165: the first row IS the left-click default (menu contract)'
            # Dismiss without choosing: nothing here should actually launch a
            # browser on the user's box. WM_CANCELMODE goes to the window that
            # OWNS the menu — the SURFACE, since a WS_EX_NOACTIVATE overlay
            # cannot own a menu that takes the keyboard. Sent to the overlay
            # instead it is a no-op, the GUI thread stays parked inside
            # TrackPopupMenuEx, and every input-driven section after this one
            # fails for reasons that have nothing to do with what it tests —
            # which is why the dismissal is ASSERTED and not assumed.
            $paneForCancel = Get-Pane $top 0
            if ($paneForCancel) {
                [void](Invoke-TestMessage -Window ([IntPtr]$paneForCancel.Hwnd) -Message 0x001F)  # WM_CANCELMODE
            }
            $gone = $false
            for ($t = 0; $t -lt 40; $t++) {
                if ((Get-TestWindow -ProcessId $appPid -Class '#32768') -eq [IntPtr]::Zero) { $gone = $true; break }
                Start-Sleep -Milliseconds 50
            }
            Assert $gone 'T165: the link menu dismisses without choosing a row'
        }

        # Ctrl+click opens a VIEWER side pane - the modifier scheme, end to
        # end, with `+list --json` as the oracle rather than a pixel.
        $before = @(Get-Leaves (Get-Win 'bw').tabs[0].splits).Count
        Send-TestMouse -Window $top -Target $lHwnd -X ($ovL.Left + $lx + 2) -Y ($ovL.Top + $ly) `
            -Action up -Modifiers ctrl | Out-Null
        $after = $before
        $viewers = 0
        for ($t = 0; $t -lt 25; $t++) {
            Start-Sleep -Milliseconds 200
            $w = Get-Win 'bw'
            if (-not $w) { continue }
            $leaves = @(Get-Leaves $w.tabs[0].splits)
            $after = $leaves.Count
            $viewers = @($leaves | Where-Object { $_.type -eq 'viewer' }).Count
            if ($viewers -ge 1) { break }
        }
        Write-Host "INFO  T165 ctrl+click: panes $before -> $after, viewers=$viewers"
        Assert ($after -eq $before + 1) "T165: Ctrl+click on a link splits a new pane ($before -> $after)"
        Assert ($viewers -ge 1) 'T165: ...and that pane is a VIEWER, pointed at the link'
        # Put the window back to one pane for the sections that follow.
        $w = Get-Win 'bw'
        if ($w) {
            foreach ($leaf in @(Get-Leaves $w.tabs[0].splits)) {
                if ($leaf.type -eq 'viewer') { & $exe +close --target=$($leaf.id) | Out-Null }
            }
        }
        Start-Sleep -Milliseconds 800
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'T165 section: GUI alive'
    & $exe +set-banner --target=bw --clear | Out-Null
    $null = Wait-Banner 'bw' 0 'NONE'

    # --- 7. per-pane: named split pane gets its own banner ---------------------
    & $exe +split --target=bw --name=bp1 --direction=down | Out-Null
    Start-Sleep -Seconds 1
    & $exe +set-banner --target=bp1 "split banner" | Out-Null
    $b = Wait-Banner 'bw' 1 'split banner'
    Assert ($b -ceq 'split banner') "pane target: split pane banner set (got $b)"
    # T101: the strip band reserves the top of the SPLIT pane's slot too
    # (geometric pane index 1 = the lower pane of the down-split).
    $ovS = $null
    for ($t = 0; $t -lt 15 -and -not $ovS; $t++) { $ovS = Get-Overlay $appPid $top 1; if (-not $ovS) { Start-Sleep -Milliseconds 200 } }
    Assert ($null -ne $ovS) 'split pane: strip glued above the split pane (T101 band inside a split slot)'
    $b = Wait-Banner 'bw' 0 'NONE'
    Assert ($b -eq '(absent)') 'pane target: first pane untouched'

    # window target applies to the window's focused pane (the new split).
    & $exe +set-banner --target=bw "focused pane banner" | Out-Null
    $b = Wait-Banner 'bw' 1 'focused pane banner'
    Assert ($b -ceq 'focused pane banner') "window target hits the focused pane (got $b)"
    & $exe +set-banner --target=bp1 --clear | Out-Null

    # --- 8. markdown link renders (overlay still paints with styles) ----------
    # (Rendering correctness is pinned by the banner_markdown unit tests; here
    # we only prove a styled multi-run banner paints without crashing.)
    & $exe +set-banner --target=bw "**b** *i* __u__ ``c`` [l](https://x.io)" | Out-Null
    Start-Sleep -Milliseconds 800
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'styled banner: GUI alive after paint'
    & $exe +set-banner --target=bw --clear | Out-Null


    # --- 9. OSC 7778 round-trip from inside the pane ---------------------------
    # Spaces in the payload are built with [char]32: PS 5.1 mangles embedded
    # quotes when spawning natives, splitting spaced args, and +send-keys
    # concatenates positionals without separators.
    $oscSet = "powershell -NoProfile -Command `"[console]::Write([char]27+']7778;osc'+[char]32+'banner'+[char]32+'works'+[char]7)`""
    & $exe +send-keys --target=bp1 $oscSet Enter 2>&1 | Out-Null
    $b = Wait-Banner 'bw' 1 'osc banner works'
    Assert ($b -ceq 'osc banner works') "OSC 7778 sets the banner (got $b)"
    $oscClear = "powershell -NoProfile -Command `"[console]::Write([char]27+']7778;'+[char]7)`""
    & $exe +send-keys --target=bp1 $oscClear Enter 2>&1 | Out-Null
    $b = Wait-Banner 'bw' 1 'NONE'
    Assert ($b -eq '(absent)') 'OSC 7778 empty text clears'

    # --- 10. unknown target errors ---------------------------------------------
    & $exe +set-banner --target=nosuch "x" 2>$null | Out-Null
    Assert ($LASTEXITCODE -ne 0) 'unknown target: nonzero exit'

    # --- 11. editor dialog: ctrl+shift+b opens, ctrl+enter commits, esc cancels
    # Pre-migration this section sat behind `if (foreground grab failed) { SKIP
    # }`, so a busy box scored it without running it. On the test desktop the
    # chord always lands, so a chooser that does not open is a real failure.
    & $exe +set-banner --target=bw "prefill" | Out-Null
    $null = Wait-Banner 'bw' 1 'prefill'  # focused pane is still bp1's slot
    # The chord goes to the pane the APP considers active: GhozttyWindow hands
    # WM_KEYDOWN to DefWindowProc and only forwards FOCUS to that pane, so a
    # posted key aimed at the window itself is silently dropped (T217 batch 3).
    Focus-TestWindow -Window $top | Out-Null
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    Assert ((Get-TestWindowClass -Window $focused) -eq 'GhozttyTerminal') 'the window forwarded focus to a terminal surface'
    Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key B | Out-Null
    $dlg = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyBannerDialog' -TimeoutMs 4000
    Assert ($dlg -ne [IntPtr]::Zero) 'ctrl+shift+b opens the banner editor'
    if ($dlg -ne [IntPtr]::Zero) {
        # The editor is modal over its window (EnableWindow(owner, 0)), and a
        # disabled owner is the only cross-process-safe form of that claim.
        Assert (-not (Test-TestWindowEnabled -Window $top)) 'the owner window is disabled while the editor is up'
        $edit = Get-TestChildWindow -Window $dlg -Class 'Edit'
        Assert ($edit -ne [IntPtr]::Zero) 'the editor has an EDIT control'
        # GetWindowTextW is cross-process cached and reads stale; WM_GETTEXT is
        # what actually asks the control (T217 batch 2).
        Assert ((Get-TestControlText -Control $edit) -eq 'prefill') "the editor opens prefilled with the current banner (got '$(Get-TestControlText -Control $edit)')"

        # Prefill is select-all (EM_SETSEL 0,-1); typing 'x' replaces it, which
        # is the assertion. Ctrl+Enter saves — sent as a real chord so the
        # dialog's GetKeyState(VK_CONTROL) sees ctrl on the shared input queue
        # (a posted modifier alone does not reach it).
        Send-TestControlText -Control $edit -Text 'x' | Out-Null
        Start-Sleep -Milliseconds 150
        Send-TestKeys -Window $dlg -Target $edit -Modifiers ctrl -Key Enter | Out-Null
        $b = Wait-Banner 'bw' 1 'x'
        Assert ($b -ceq 'x') "editor commit: typing replaced the selected prefill (got $b)"
        Assert ((@(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerDialog')).Count -eq 0) 'editor closed after commit'
        Assert (Test-TestWindowEnabled -Window $top) 'the owner window is enabled again after the editor closes'

        # Escape cancels without applying.
        Focus-TestWindow -Window $top | Out-Null
        $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
        Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key B | Out-Null
        $dlg2 = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyBannerDialog' -TimeoutMs 4000
        Assert ($dlg2 -ne [IntPtr]::Zero) 'ctrl+shift+b reopens the editor'
        if ($dlg2 -ne [IntPtr]::Zero) {
            $edit2 = Get-TestChildWindow -Window $dlg2 -Class 'Edit'
            Send-TestControlText -Control $edit2 -Text 'y' | Out-Null
            Start-Sleep -Milliseconds 150
            Send-TestKeys -Window $dlg2 -Target $edit2 -Key Escape | Out-Null
            Start-Sleep -Milliseconds 400
            $b = Wait-Banner 'bw' 1 'x'
            Assert ($b -ceq 'x') "editor cancel: banner unchanged (got $b)"
            Assert ((@(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerDialog')).Count -eq 0) 'editor closed after cancel'
        } else { $script:fail += 2 }
    } else {
        $script:fail += 8
    }

    # --- 12. app alive, +list responsive ---------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    Assert ($json -match '"success":true') '+list still responds'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

# The user's actual complaint, asserted rather than assumed. Runs AFTER the
# cleanup, so it reads the surviving all-pids list — the live one is emptied by
# Remove-TestDesktop and would score against nothing (T217 batch 3).
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, and would otherwise report a clean pass.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
