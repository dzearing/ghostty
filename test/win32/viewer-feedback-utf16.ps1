# T648 acceptance: the feedback composer's offsets with NON-ASCII text in it.
#
# The defect this pins: every pure module behind the composer works in BYTES
# into the pane's UTF-8 buffer, and every edit message works in UTF-16 CODE
# UNITS. Those are the same number only for ASCII -- `e-acute` is 2 bytes and 1
# unit, an emoji is 4 bytes and 2 units -- so a composer holding any
# non-English text handed the control an offset short by the accumulated
# difference. Typing plain English never sees it, which is why it shipped.
#
# What is asserted:
#
#   A. The composer takes non-ASCII typing at all, surrogate pair included.
#      Everything below is a claim about offsets, so the text has to be the
#      text before any of it means anything.
#   B. A pasted image's chip lands EXACTLY at the caret. The caret is parked
#      mid-text, right after a space, so the correct answer carries no leading
#      space -- and the same number read as a byte offset lands inside a
#      multi-byte character, where the byte before is not a space and one would
#      be added. The whole composer text is compared, so the double space is a
#      FAIL. Every arm here compares the WHOLE text for that reason: a
#      substring needle is exactly what let a corrupted `[Imag` pass once.
#   C. The caret ends up past the chip that was just inserted, at the position
#      the insertion computed -- not 4 units past it, which is what a byte
#      offset handed to EM_EXSETSEL would ask for.
#   D. Backspace against a chip that follows non-ASCII text still removes the
#      WHOLE chip. This is the loud one: the chip lookup searches the pane's
#      buffer at the caret, so an unconverted offset finds no chip at all, the
#      control deletes one character, and `[Image #1` is left behind -- text
#      that still looks attached and no longer parses, i.e. a picture silently
#      dropped from the report.
#   E. The report the send publishes carries the non-ASCII body intact.
#
# The quote half of the same bug is asserted in the win32 lane instead
# (`ViewerPane.zig`, the T641 quote block): pressing the page's own Quote
# button means running script IN the page, which this harness cannot do.
#
# ORACLES. This runs on the BACKGROUND test desktop, where CopyFromScreen and
# SendInput are dead (T233). What stands in, and all of it is the real thing:
# the RichEdit's own text (WM_GETTEXT), its own selection (EM_GETSEL), the
# pane's stderr, and the report folder on disk.
#
# THIS FILE IS ASCII ONLY (PowerShell 5.1 reads a BOM-less UTF-8 script as
# ANSI). Every non-ASCII character below is built from its code point.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-utf16.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-fbu16'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Text is compared and printed as ESCAPED code points: a console that cannot
# render an emoji would otherwise turn a real difference into an unreadable
# one, and a mismatch nobody can read is a mismatch nobody can fix.
function Show-Text([string]$s) {
    if ($null -eq $s) { return '<null>' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        $n = [int]$c
        if ($n -ge 32 -and $n -lt 127) { [void]$sb.Append($c) }
        else { [void]$sb.AppendFormat('\u{0:X4}', $n) }
    }
    return $sb.ToString()
}

$EM_GETSEL = 0x00B0
$EM_SETSEL = 0x00B1

function Set-Caret([IntPtr]$Control, [int]$At) {
    return (Invoke-TestMessage -Window $Control -Message $EM_SETSEL `
            -WParam ([IntPtr]$At) -LParam ([IntPtr]$At))
}

# EM_GETSEL with null pointers answers with start in the low word and end in
# the high word -- no cross-process pointer needed, which EM_EXGETSEL would.
function Get-Caret([IntPtr]$Control) {
    $r = Invoke-TestMessage -Window $Control -Message $EM_GETSEL
    if ($r -eq [int64]::MinValue) { return $null }
    return [pscustomobject]@{
        Start = [int]($r -band 0xFFFF)
        End   = [int](($r -shr 16) -band 0xFFFF)
    }
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
    return , $bytes
}

# --- the fixture text --------------------------------------------------------
# `eee<sp><emoji><sp>YZ`, built from code points so this file stays ASCII.
#
#   9 UTF-16 code units:  e e e _ [hi lo] _ Y Z
#  14 UTF-8 bytes:        2 2 2 1  4       1 1 1
#
# The caret goes to unit 4 -- just past the space, right before the emoji --
# and that position is byte 7. The two numbers have to disagree ABOUT THE TEXT
# AROUND THEM for anything to be observable, which is what picking this one
# buys: byte 7 follows a space, so the chip needs no leading space of its own;
# byte 4 (unit 4 read as an offset) lands inside the third `e-acute`, where the
# preceding byte is not a space and one WOULD be added. Most other positions in
# this string happen to have a break on both sides and would agree by accident.
$EA = [char]0x00E9                                  # LATIN SMALL LETTER E WITH ACUTE
$EMOJI = [string][char]::ConvertFromUtf32(0x1F600)  # GRINNING FACE (a surrogate pair)
$seed = ($EA.ToString() * 3) + ' ' + $EMOJI + ' ' + 'YZ'
$caretUnit = 4
$chip = '[Image #1]'

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fbu16-accept-" + $PID)
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
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-utf16-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=u16win', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'u16win')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'u16win'
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

    # --- A. the composer takes non-ASCII typing ------------------------------
    [void](Send-TestControlText -Control $rich -Text $seed)
    Start-Sleep -Milliseconds 400
    $typed = (Get-TestControlText $rich)
    Assert ($typed -ceq $seed) `
        ("the composer holds the typed non-ASCII text, emoji included " +
         "(got '$(Show-Text $typed)', want '$(Show-Text $seed)')")
    Assert ($typed.Length -eq 9) `
        "...which is 9 UTF-16 code units and 14 UTF-8 bytes (got $($typed.Length) units)"

    # --- B. a chip lands exactly at the caret --------------------------------
    [void](Set-Caret $rich $caretUnit)
    $sel = Get-Caret $rich
    Assert ($sel -and $sel.Start -eq $caretUnit -and $sel.End -eq $caretUnit) `
        "the caret is parked at unit $caretUnit, just before the emoji (got $($sel.Start)..$($sel.End))"

    $png1 = Set-ClipboardPng 40 30 17
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    $img = Wait-Image $errlog $paneId 1
    Assert ($img -and $img.Number -eq 1) "the paste is taken as image #1 (got '$($img.Number)')"
    Assert ($img -and $img.Bytes -eq $png1.Length) `
        "...verbatim, byte for byte ($($img.Bytes) vs $($png1.Length))"

    # The correct insertion carries NO leading space -- the caret sits right
    # after one -- and a trailing space, because the emoji follows. An
    # unconverted offset lands inside the third `e-acute`, sees a non-space byte
    # behind it, and adds a second space.
    $wantB = ($EA.ToString() * 3) + ' ' + $chip + ' ' + $EMOJI + ' ' + 'YZ'
    $afterPaste = (Get-TestControlText $rich)
    Assert ($afterPaste -ceq $wantB) `
        ("the chip lands EXACTLY at the caret, with no doubled space " +
         "(got '$(Show-Text $afterPaste)', want '$(Show-Text $wantB)')")

    # --- C. the caret ends past the chip it just inserted --------------------
    $wantCaret = $wantB.IndexOf($chip) + $chip.Length + 1   # past the chip and its trailing space
    $sel = Get-Caret $rich
    Assert ($sel -and $sel.Start -eq $wantCaret) `
        "the caret is left just past the inserted run, at unit $wantCaret (got $($sel.Start))"

    # --- D. Backspace takes the WHOLE chip -----------------------------------
    # The caret goes to the chip's closing bracket, which is where a user
    # clicking at the end of a chip puts it.
    $chipEnd = $wantB.IndexOf($chip) + $chip.Length
    [void](Set-Caret $rich $chipEnd)
    $sel = Get-Caret $rich
    Assert ($sel -and $sel.Start -eq $chipEnd) `
        "the caret is at the chip's closing bracket, unit $chipEnd (got $($sel.Start))"

    [void](Send-TestControlKey -Control $rich -Key Backspace)
    Start-Sleep -Milliseconds 500
    # Compared WHOLE, not by "no `[Image` left": a chip lookup that missed
    # deletes one character, and `[Imag` does not match that needle either
    # while being exactly the corruption this arm exists to catch.
    $wantD = ($EA.ToString() * 3) + '  ' + $EMOJI + ' ' + 'YZ'
    $afterDelete = (Get-TestControlText $rich)
    Assert ($afterDelete -ceq $wantD) `
        ("one Backspace removes the WHOLE chip after non-ASCII text, leaving no " +
         "fragment (got '$(Show-Text $afterDelete)', want '$(Show-Text $wantD)')")

    # --- E. the report carries the non-ASCII body ----------------------------
    # A second picture goes in first, so the send has an image to write as well
    # as the words -- the chip numbering is stable, so this one is #2.
    [void](Set-Caret $rich $afterDelete.Length)
    $png2 = Set-ClipboardPng 20 12 91
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    $img = Wait-Image $errlog $paneId 2
    Assert ($img -and $img.Number -eq 2) "a second paste is #2 (got '$($img.Number)')"

    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)
    $folder = $null
    for ($t = 0; $t -lt 40; $t++) {
        $dirs = @(Get-ChildItem $queueDir -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -ge 1) { $folder = $dirs[0].FullName; break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $folder) "the send published a report folder into $queueDir"
    if ($folder) {
        $report = Get-Content (Join-Path $folder 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($report.body.Contains($EA.ToString() * 3)) `
            "report.json's body carries the accented text (holds '$(Show-Text $report.body)')"
        Assert ($report.body.Contains($EMOJI)) '...and the emoji, unmangled'
        Assert ($report.body -match '!\[Image #2\]\(images/image-2\.png\)') `
            '...and links the surviving picture'
        Assert ($report.body -notmatch 'Image #1') `
            '...with the deleted chip nowhere in it'
        Assert (Test-Path (Join-Path $folder 'images\image-2.png')) 'the folder holds images/image-2.png'
        Assert (-not (Test-Path (Join-Path $folder 'images\image-1.png'))) `
            'the deleted chip left no file behind'
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
