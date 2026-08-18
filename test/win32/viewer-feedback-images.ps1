# T637 acceptance: pasting a PICTURE into the viewer's feedback composer.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   A. A clipboard carrying a registered "PNG" pastes as an image: a
#      `[Image #1]` chip appears in the composer and the pane reports it.
#   B. A chip deletes WHOLE. One Backspace against `[Image #1]` removes all of
#      it, never leaving `[Image #1` behind -- which would look attached and
#      silently not be, because the report is derived from the text.
#   C. Chip numbers are STABLE. The next paste is #2 even though #1's number
#      is now free, so a number always names the same picture.
#   D. A clipboard carrying only a BITMAP (no "PNG" format) pastes too -- the
#      Snipping Tool / Paint / Excel case, which goes through the DIB
#      normalisation rather than the verbatim copy.
#   E. Send files the images: the published folder holds `images/image-N.png`
#      for every live chip and for no deleted one, the bytes on disk are the
#      bytes that were pasted, `report.json`'s `images` array carries the
#      numbers, sizes and pixel dimensions, and `body` links each one as
#      `![Image #N](images/image-N.png)`.
#
# ORACLES. This runs on the BACKGROUND test desktop, where CopyFromScreen and
# SendInput are dead (T233), so nothing here can look at a painted composer.
# Three readable things stand in, and all three are the real thing:
#
#   - the RichEdit's own text (WM_GETTEXT), which is what the user sees;
#   - the pane's stderr, which reports every image it took
#     (`image=#N bytes=B live=L`);
#   - the report FOLDER on disk, which is the artifact the whole feature
#     exists to produce.
#
# THE CLIPBOARD REACHES THE APP because the test desktop is a desktop, not a
# window station (`WinSta0\<name>`), and the clipboard belongs to the station.
# A separate station would need the app to set it, which is why this does not.
#
# Ctrl+V is sent with Send-TestViewerChord rather than Send-TestKeys: the
# composer's interception asks the app's own GetKeyState for the modifier, and
# only the attaching variant arranges that. The WM_PASTE arm (a context-menu
# paste) is exercised by posting the message directly.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-images.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-fbimg'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
            # `feedback=` is `shown`/`hidden`, not a bool -- the pane logs which
            # affordance it decided on, not a flag.
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
            $hit = [pscustomobject]@{ Open = ($Matches[1] -eq 'true'); BarH = [int]$Matches[2] }
        }
    }
    return $hit
}

function Wait-FeedbackState($errlog, $paneId, [bool]$Open) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-FeedbackState $errlog $paneId
        if ($s -and $s.Open -eq $Open) { return $s }
        Start-Sleep -Milliseconds 250
    }
    return (Get-FeedbackState $errlog $paneId)
}

# The pane's LAST reported image attach: `image=#N bytes=B live=L`.
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

# --- clipboard fixtures ------------------------------------------------------
# Two shapes, because the composer reads two different ways.

function New-TestBitmap([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $c = [System.Drawing.Color]::FromArgb(
                255,
                ($x * 7 + $Seed) % 256,
                ($y * 11 + $Seed) % 256,
                (($x + $y) * 3 + $Seed) % 256)
            $bmp.SetPixel($x, $y, $c)
        }
    }
    return $bmp
}

# A registered "PNG" on the clipboard -- what every browser publishes, and the
# path that copies the bytes VERBATIM. Returns the exact bytes so the file on
# disk can be compared against them.
function Set-ClipboardPng([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-TestBitmap $W $H $Seed
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $bytes = $ms.ToArray()
    $do = New-Object System.Windows.Forms.DataObject
    $do.SetData('PNG', $false, (New-Object System.IO.MemoryStream(, $bytes)))
    [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
    Start-Sleep -Milliseconds 250
    # The unary comma keeps this a byte[]: a bare `return $bytes` unrolls the
    # array into the pipeline and the caller gets an Object[] of boxed bytes.
    return , $bytes
}

# A plain bitmap -- CF_BITMAP + CF_DIB and no "PNG" at all, which is what
# Snipping Tool, Paint and Excel put there.
function Set-ClipboardBitmap([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-TestBitmap $W $H $Seed
    [System.Windows.Forms.Clipboard]::SetImage($bmp)
    $bmp.Dispose()
    Start-Sleep -Milliseconds 250
}

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fbimg-accept-" + $PID)
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

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-images-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=imgwin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'imgwin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'imgwin'
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
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) "the pane reports the composer OPEN (state '$($s.Open)')"

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

    # --- A. a "PNG" clipboard pastes as a chip -------------------------------
    $png1 = Set-ClipboardPng 40 30 17
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    $img = Wait-Image $errlog $paneId 1
    Assert ($img -and $img.Number -eq 1) "the first paste is image #1 (got '$($img.Number)')"
    Assert ($img -and $img.Bytes -eq $png1.Length) `
        "...taken VERBATIM, byte for byte ($($img.Bytes) vs $($png1.Length) on the clipboard)"
    Assert ($img -and $img.Live -eq 1) "...and one image is live in the report ($($img.Live))"

    $text = (Get-TestControlText $rich)
    Assert ($text -match '\[Image #1\]') "the composer shows an '[Image #1]' chip (holds '$text')"

    # --- B. a chip deletes WHOLE ---------------------------------------------
    # The caret sits just past the chip's trailing space. One Backspace takes
    # the space; the next must take the entire chip, not its last character.
    [void](Send-TestControlKey -Control $rich -Key Backspace)
    Start-Sleep -Milliseconds 250
    [void](Send-TestControlKey -Control $rich -Key Backspace)
    Start-Sleep -Milliseconds 400
    $afterDelete = (Get-TestControlText $rich)
    Assert ($afterDelete -notmatch '\[Image') `
        "one Backspace removes the WHOLE chip, leaving no fragment (holds '$afterDelete')"

    # --- C. the next number is 2, not the freed 1 ----------------------------
    $png2 = Set-ClipboardPng 20 12 91
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    $img = Wait-Image $errlog $paneId 2
    Assert ($img -and $img.Number -eq 2) `
        "the next paste is #2 even though #1 was deleted (got '$($img.Number)')"
    Assert ($img -and $img.Live -eq 1) `
        "...and only IT is live -- the deleted one left the report ($($img.Live))"

    # --- D. a bitmap-only clipboard, pasted through WM_PASTE -----------------
    # No "PNG" format at all, so this is the DIB normalisation path; and the
    # message is posted directly, which is the context-menu Paste route.
    Set-ClipboardBitmap 24 16 200
    [void](Send-TestRawMessage -Window $rich -Message 0x0302)
    $img = Wait-Image $errlog $paneId 3
    Assert ($img -and $img.Number -eq 3) `
        "a BITMAP-only clipboard pastes too, as #3 (got '$($img.Number)')"
    Assert ($img -and $img.Bytes -gt 0) "...encoded to $($img.Bytes) bytes of PNG"
    Assert ($img -and $img.Live -eq 2) "...and two images are now live ($($img.Live))"

    $text = (Get-TestControlText $rich)
    Assert (($text -match '\[Image #2\]') -and ($text -match '\[Image #3\]')) `
        "the composer shows both surviving chips (holds '$text')"

    # --- E. send files the pictures ------------------------------------------
    [void](Send-TestControlText -Control $rich -Text 'look at these')
    Start-Sleep -Milliseconds 300
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)

    $folder = $null
    for ($t = 0; $t -lt 40; $t++) {
        $dirs = @(Get-ChildItem $queueDir -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -ge 1) { $folder = $dirs[0].FullName; break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $folder) "the send published a report folder into $queueDir"
    if (-not $folder) { throw 'no report folder' }

    $imagesDir = Join-Path $folder 'images'
    Assert (Test-Path (Join-Path $imagesDir 'image-2.png')) 'the folder holds images/image-2.png'
    Assert (Test-Path (Join-Path $imagesDir 'image-3.png')) 'the folder holds images/image-3.png'
    Assert (-not (Test-Path (Join-Path $imagesDir 'image-1.png'))) `
        'the DELETED chip left no file behind (no images/image-1.png)'

    $onDisk = [System.IO.File]::ReadAllBytes((Join-Path $imagesDir 'image-2.png'))
    Assert ($onDisk.Length -eq $png2.Length) `
        "the verbatim PNG reached disk unchanged ($($onDisk.Length) vs $($png2.Length))"
    $same = $true
    if ($onDisk.Length -eq $png2.Length) {
        for ($i = 0; $i -lt $onDisk.Length; $i++) {
            if ($onDisk[$i] -ne $png2[$i]) { $same = $false; break }
        }
    } else { $same = $false }
    Assert $same '...byte for byte, not re-encoded'

    $report = Get-Content (Join-Path $folder 'report.json') -Raw | ConvertFrom-Json
    $arr = @($report.images)
    Assert ($arr.Count -eq 2) "report.json carries exactly the two live images (got $($arr.Count))"
    $two = $arr | Where-Object { $_.number -eq 2 }
    $three = $arr | Where-Object { $_.number -eq 3 }
    Assert ($null -ne $two -and $null -ne $three) 'the entries are numbered 2 and 3, with 1 absent'
    Assert ($two -and $two.path -eq 'images/image-2.png') `
        "...each naming its folder-relative path ('$($two.path)')"
    Assert ($two -and $two.bytes -eq $png2.Length) `
        "...with the file's byte size ($($two.bytes) vs $($png2.Length))"
    Assert ($two -and $two.pixelWidth -eq 20 -and $two.pixelHeight -eq 12) `
        "...and its pixel dimensions ($($two.pixelWidth)x$($two.pixelHeight), want 20x12)"
    Assert ($three -and $three.pixelWidth -eq 24 -and $three.pixelHeight -eq 16) `
        "the normalised bitmap kept its size too ($($three.pixelWidth)x$($three.pixelHeight), want 24x16)"

    Assert ($report.body -match '!\[Image #2\]\(images/image-2\.png\)') `
        'the body links image 2 as a markdown image reference'
    Assert ($report.body -match '!\[Image #3\]\(images/image-3\.png\)') `
        '...and image 3'
    Assert ($report.body -notmatch 'Image #1') 'the deleted chip is nowhere in the body'
    Assert ($report.body -match 'look at these') 'the typed words are in the body too'

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
