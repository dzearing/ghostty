# T647 acceptance: taking a SCREENSHOT into the viewer's feedback composer.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   A. The `+` button puts a region selector up: a GhozttyRegionSelect window
#      covering the whole virtual screen, and the app says so.
#   B. A drag over it captures: `capture=done` names the rect, an `[Image #1]`
#      chip appears in the composer, and the overlay goes away.
#   C. THE CLIPBOARD SURVIVES. A known string is put on it before the capture
#      and read back after, byte for byte. This is the one hard constraint the
#      whole design (D44) turns on -- the Windows snipping tools were ruled out
#      precisely because they publish through the clipboard.
#   D. Escape cancels: no chip, no image, and the overlay is gone.
#   E. A CLICK with no drag cancels too. A zero-area drag must not become a
#      zero-pixel picture, which would look like the capture worked.
#   F. Ctrl+Shift+S is the same action from the keyboard (Mac's shift+cmd+S).
#   G. The captured picture reaches the report at the size that was dragged --
#      the end-to-end oracle for the crop math, read out of report.json's
#      pixelWidth/pixelHeight.
#
# ORACLES. This runs on the BACKGROUND test desktop, where SendInput and
# CopyFromScreen are dead (T233), so nothing here looks at painted pixels and
# nothing here moves a real mouse. Instead:
#
#   - the OVERLAY WINDOW itself (class, existence, rect), which is a fact about
#     the app's window list rather than about paint;
#   - the pane's stderr, which reports every capture it begins, finishes and
#     cancels;
#   - the RichEdit's own text, which is what the user sees;
#   - the report FOLDER on disk, which is the artifact the feature produces.
#
# The drag is POSTED (Send-TestMouse), which works because the selector reads
# every coordinate out of the message's lparam and never asks the OS where the
# pointer is. That is a deliberate property of RegionSelector.zig, not a
# coincidence -- see its header.
#
# The screenshot's CONTENT is deliberately not asserted: a background desktop
# has no display surface, so the pixels are legitimately blank there. What is
# asserted is that a picture of the right SIZE was produced and filed.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-capture.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-fbcap'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

Add-Type -AssemblyName System.Windows.Forms

$script:pass = 0
$script:fail = 0

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

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | Out-String)
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

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPaneId($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0].id
}

function Get-ViewerHost($appPid) {
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            return [pscustomobject]@{ Top = [IntPtr]$top.Hwnd; Pane = [IntPtr]$h.Hwnd }
        }
    }
    return $null
}

function Get-ChromeChild($paneHwnd, [string]$Class) {
    $c = @(Get-TestChildWindows -Window $paneHwnd -Class $Class)
    if ($c.Count -lt 1) { return $null }
    return [IntPtr]$c[0].Hwnd
}

function Wait-WorktreeShown($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=(\w+)") {
                if ($Matches[1] -eq 'shown') { return $true }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-FeedbackState($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) open=(\w+) bar_h=(\d+)") {
            $hit = [pscustomobject]@{ Open = ($Matches[1] -eq 'true') }
        }
    }
    return $hit
}

function Wait-FeedbackOpen($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-FeedbackState $errlog $paneId
        if ($s -and $s.Open) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Counts of the three capture outcomes the app reports, so an arm can assert
# "one MORE cancel happened" rather than "a cancel exists somewhere in the log".
function Get-CaptureTally($errlog) {
    $begin = 0; $done = 0; $cancel = 0
    $lastRect = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match 'viewer feedback capture=begin bounds=(-?\d+),(-?\d+) (\d+)x(\d+)') {
            $begin++
            $script:vsX = [int]$Matches[1]; $script:vsY = [int]$Matches[2]
            $script:vsW = [int]$Matches[3]; $script:vsH = [int]$Matches[4]
        } elseif ($line -match 'viewer feedback capture=done rect=(-?\d+),(-?\d+) (\d+)x(\d+) bytes=(\d+)') {
            $done++
            $lastRect = [pscustomobject]@{
                X = [int]$Matches[1]; Y = [int]$Matches[2]
                W = [int]$Matches[3]; H = [int]$Matches[4]
                Bytes = [int]$Matches[5]
            }
        } elseif ($line -match 'viewer feedback capture=cancelled') {
            $cancel++
        }
    }
    return [pscustomobject]@{ Begin = $begin; Done = $done; Cancel = $cancel; Rect = $lastRect }
}

function Wait-Tally($errlog, [string]$Field, [int]$Want) {
    for ($t = 0; $t -lt 40; $t++) {
        $tally = Get-CaptureTally $errlog
        if ($tally.$Field -ge $Want) { return $tally }
        Start-Sleep -Milliseconds 250
    }
    return (Get-CaptureTally $errlog)
}

function Get-LastImage($errlog, $paneId) {
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) image=#(\d+) bytes=(\d+) live=(\d+)") {
            $hit = [pscustomobject]@{
                Number = [int]$Matches[1]
                Bytes  = [int]$Matches[2]
                Live   = [int]$Matches[3]
            }
        }
    }
    return $hit
}

function Wait-Image($errlog, $paneId, [int]$Number) {
    for ($t = 0; $t -lt 40; $t++) {
        $i = Get-LastImage $errlog $paneId
        if ($i -and $i.Number -eq $Number) { return $i }
        Start-Sleep -Milliseconds 250
    }
    return (Get-LastImage $errlog $paneId)
}

function Get-Overlay($appPid) {
    $w = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyRegionSelect')
    if ($w.Count -lt 1) { return $null }
    return [IntPtr]$w[0].Hwnd
}

function Wait-Overlay($appPid, [bool]$Present) {
    for ($t = 0; $t -lt 40; $t++) {
        $o = Get-Overlay $appPid
        if ($Present -and $o) { return $o }
        if (-not $Present -and -not $o) { return $null }
        Start-Sleep -Milliseconds 250
    }
    return (Get-Overlay $appPid)
}

function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - [Math]::Round(18 * $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

# The composer's `+` action: the FIRST of the two circular buttons inside the
# pill's trailing edge.
#
# Derived from viewer_feedback_layout.zig's own construction rather than from a
# measured pixel: the actions are pinned to the pill's bottom-TRAILING corner,
# so from the band's right edge inward that is pad(8) + pill_pad(4) + the send
# button(28) + pill_pad(4) + half of this one(14) = 58 DIP, and from the band's
# top down pad(8) + pill_pad(4) + 14 = 26 DIP while the pill is collapsed.
function Invoke-SnapshotButton($view, $fb) {
    $rect = Get-TestWindowRect $fb
    if (-not $rect) { return $false }
    $dpi = Get-TestWindowDpi $fb
    if (-not $dpi -or $dpi -le 0) { $dpi = 96 }
    $s = $dpi / 96.0
    $x = [int]($rect.Right - [Math]::Round(58 * $s))
    $y = [int]($rect.Top + [Math]::Round(26 * $s))
    return (Send-TestMouse -Window $view.Top -Target $fb -X $x -Y $y)
}

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fbcap-accept-" + $PID)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8 -Value @(
    '# Throwaway',
    '',
    'a paragraph in the throwaway repo',
    ''
)
& git -C $work init --initial-branch=main *> $null
& git -C $work add -A *> $null
& git -C $work -c user.name='ghoztty test' -c user.email='test@ghoztty' commit -m 'throwaway' *> $null
$workRoot = (& git -C $work rev-parse --show-toplevel 2>$null | Out-String).Trim().Replace('/', '\')
if (-not $workRoot) { Write-Host "SETUP FAIL: could not make a throwaway repo at $work"; exit 1 }
$queueDir = Join-Path $work 'temp\feedback\new'
$viewFile = Join-Path $work 'README.md'

$script:vsX = 0; $script:vsY = 0; $script:vsW = 0; $script:vsH = 0

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-capture-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=capwin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'capwin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'capwin'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so it can file a report'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    Assert (Wait-FeedbackOpen $errlog $paneId) 'the pane reports the composer OPEN'

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback child window exists'
    if (-not $fb) { throw 'no composer window' }

    $rich = $null
    foreach ($c in @(Get-TestChildWindows -Window $fb -Class $null)) {
        if ([string]$c.Class -eq 'RichEdit50W') { $rich = [IntPtr]$c.Hwnd; break }
    }
    Assert ($null -ne $rich) 'the composer hosts its RichEdit50W text control'
    if (-not $rich) { throw 'no text control in the composer' }

    # --- C (first half). A known string goes on the clipboard BEFORE any
    # capture, so every arm below runs across it.
    $sentinel = 'clipboard-sentinel-' + [guid]::NewGuid().ToString('N')
    [System.Windows.Forms.Clipboard]::SetText($sentinel)
    Start-Sleep -Milliseconds 250
    Assert ([System.Windows.Forms.Clipboard]::GetText() -eq $sentinel) `
        'a known string is on the clipboard before the first capture'

    # --- A. the + button puts the selector up --------------------------------
    Assert (Invoke-SnapshotButton $view $fb) 'the composer took a click at its + button'
    $overlay = Wait-Overlay $appPid $true
    Assert ($null -ne $overlay) 'a GhozttyRegionSelect overlay window appeared'
    $tally = Wait-Tally $errlog 'Begin' 1
    Assert ($tally.Begin -ge 1) "the app reports a capture beginning (begin=$($tally.Begin))"
    Assert ($script:vsW -gt 0 -and $script:vsH -gt 0) `
        "...over a real virtual screen ($($script:vsW)x$($script:vsH) at $($script:vsX),$($script:vsY))"

    $orect = Get-TestWindowRect $overlay
    Assert ($orect -and $orect.Width -eq $script:vsW -and $orect.Height -eq $script:vsH) `
        "the overlay covers the WHOLE virtual screen ($($orect.Width)x$($orect.Height), want $($script:vsW)x$($script:vsH))"

    # --- D. Escape cancels ----------------------------------------------------
    # Taken first, while nothing has been captured yet, so "no chip appeared"
    # is unambiguous.
    [void](Send-TestRawMessage -Window $overlay -Message 0x0100 -WParam ([IntPtr]0x1B))
    $tally = Wait-Tally $errlog 'Cancel' 1
    Assert ($tally.Cancel -ge 1) "Escape cancels the capture (cancel=$($tally.Cancel))"
    Assert ($null -eq (Wait-Overlay $appPid $false)) '...and the overlay window is gone'
    Assert ($null -eq (Get-LastImage $errlog $paneId)) '...with no image attached'
    Assert ((Get-TestControlText $rich) -notmatch '\[Image') '...and no chip in the composer'

    # --- E. a click with no drag is a cancel, not an empty picture ------------
    Assert (Invoke-SnapshotButton $view $fb) 'the + button opens a second selector'
    $overlay = Wait-Overlay $appPid $true
    Assert ($null -ne $overlay) '...and the overlay is up again'
    $cx = $script:vsX + 200
    $cy = $script:vsY + 200
    [void](Send-TestMouse -Window $view.Top -Target $overlay -X $cx -Y $cy -Action down)
    Start-Sleep -Milliseconds 200
    [void](Send-TestMouse -Window $view.Top -Target $overlay -X $cx -Y $cy -Action up)
    $tally = Wait-Tally $errlog 'Cancel' 2
    Assert ($tally.Cancel -ge 2) "a zero-area drag cancels (cancel=$($tally.Cancel))"
    Assert ($tally.Done -eq 0) '...and produced no picture at all'
    Assert ($null -eq (Wait-Overlay $appPid $false)) '...and the overlay is gone'

    # --- F. Ctrl+Shift+S opens it from the keyboard ---------------------------
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key S -Modifiers Ctrl, Shift)
    $overlay = Wait-Overlay $appPid $true
    Assert ($null -ne $overlay) 'Ctrl+Shift+S puts the selector up too'
    $tally = Wait-Tally $errlog 'Begin' 3
    Assert ($tally.Begin -ge 3) "...reported as a third capture beginning (begin=$($tally.Begin))"

    # --- B. a real drag captures ---------------------------------------------
    # 160x120 at (120,140) inside the virtual screen. Screen coordinates:
    # Send-TestMouse converts them to the overlay's client space, which IS the
    # snapshot's own buffer space.
    $x1 = $script:vsX + 120
    $y1 = $script:vsY + 140
    $x2 = $x1 + 160
    $y2 = $y1 + 120
    [void](Send-TestMouse -Window $view.Top -Target $overlay -X $x1 -Y $y1 -Action down)
    Start-Sleep -Milliseconds 200
    [void](Send-TestMouse -Window $view.Top -Target $overlay -X ($x1 + 80) -Y ($y1 + 60) -Action move)
    Start-Sleep -Milliseconds 200
    [void](Send-TestMouse -Window $view.Top -Target $overlay -X $x2 -Y $y2 -Action move)
    Start-Sleep -Milliseconds 200
    [void](Send-TestMouse -Window $view.Top -Target $overlay -X $x2 -Y $y2 -Action up)

    $tally = Wait-Tally $errlog 'Done' 1
    Assert ($tally.Done -ge 1) "the drag produced a capture (done=$($tally.Done))"
    Assert ($tally.Rect -and $tally.Rect.W -eq 160 -and $tally.Rect.H -eq 120) `
        "...of exactly the dragged rect ($($tally.Rect.W)x$($tally.Rect.H), want 160x120)"
    Assert ($tally.Rect -and $tally.Rect.X -eq $x1 -and $tally.Rect.Y -eq $y1) `
        "...at the dragged origin ($($tally.Rect.X),$($tally.Rect.Y), want $x1,$y1)"
    Assert ($tally.Rect -and $tally.Rect.Bytes -gt 0) "...encoded to $($tally.Rect.Bytes) bytes of PNG"

    $img = Wait-Image $errlog $paneId 1
    Assert ($img -and $img.Number -eq 1) "the capture attaches as image #1 (got '$($img.Number)')"
    Assert ($img -and $img.Live -eq 1) "...and one image is live in the report ($($img.Live))"
    $text = (Get-TestControlText $rich)
    Assert ($text -match '\[Image #1\]') "the composer shows an '[Image #1]' chip (holds '$text')"
    Assert ($null -eq (Wait-Overlay $appPid $false)) 'the overlay came down after the drag'

    # --- C (second half). The clipboard is exactly as it was -----------------
    $after = [System.Windows.Forms.Clipboard]::GetText()
    Assert ($after -eq $sentinel) `
        "the clipboard survived every capture byte for byte (holds '$after')"

    # --- G. the picture reaches the report at the dragged size ---------------
    [void](Send-TestControlText -Control $rich -Text 'this bit here')
    Start-Sleep -Milliseconds 300
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)

    $folder = $null
    for ($t = 0; $t -lt 40; $t++) {
        $dirs = @(Get-ChildItem $queueDir -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -ge 1) { $folder = $dirs[0].FullName; break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $folder) "the send published a report folder into $queueDir"
    if ($folder) {
        Assert (Test-Path (Join-Path $folder 'images\image-1.png')) `
            'the folder holds images/image-1.png'
        $report = Get-Content (Join-Path $folder 'report.json') -Raw | ConvertFrom-Json
        $arr = @($report.images)
        Assert ($arr.Count -eq 1) "report.json carries the one captured image (got $($arr.Count))"
        Assert ($arr.Count -eq 1 -and $arr[0].pixelWidth -eq 160 -and $arr[0].pixelHeight -eq 120) `
            "...at the size that was dragged ($($arr[0].pixelWidth)x$($arr[0].pixelHeight), want 160x120)"
        Assert ($report.body -match '!\[Image #1\]\(images/image-1\.png\)') `
            'the body links the screenshot as a markdown image reference'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
