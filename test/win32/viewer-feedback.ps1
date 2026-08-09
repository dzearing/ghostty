# T634 acceptance: the viewer feedback composer's CHROME.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   A. the feedback button OPENS the composer: a `GhozttyViewerFeedback` child
#      window appears, visible, directly under the nav bar.
#   B. the nav bar stays visible the whole time the composer is open -- it
#      carries the only affordance that closes it, so it must not auto-hide
#      out from under it.
#   C. the page is INSET by the composer's band, and gets the space back when
#      it closes (the WebView2 widget's own top edge moves, both ways).
#   D. the pill GROWS with its content and SHRINKS again: typed newlines make
#      the band taller, backspacing them makes it shorter.
#   E. Escape closes it (a pane-scoped chord, live only in the composer).
#   F. text typed into the composer SURVIVES closing and reopening -- the
#      state lives on the pane, not on the toolbar window.
#   G. Ctrl+Enter sends, and reports the length the pane still holds, which is
#      the same assertion as F from the other side.
#   H. the composer's chords are PANE-SCOPED: Escape and Ctrl+Enter delivered
#      to a terminal pane produce no composer activity at all.
#
# ORACLES, and why they are what they are. This runs on the BACKGROUND test
# desktop, where CopyFromScreen and SendInput are dead (T233), so nothing out
# here can look at a painted pill. Two things are readable instead, and both
# are the real thing rather than a proxy:
#
#   * the composer is a REAL child window, so its class, visibility and rect
#     are readable with the ordinary window helpers -- that is what makes A,
#     C and D geometric assertions rather than log-scraping.
#   * the pane states each open/close in its own stderr:
#         viewer feedback pane=<id> open=<bool> bar_h=<px> worktree=<path>
#     and each send as
#         viewer feedback pane=<id> action=send len=<n> ...
#     which is what F and G read.
#
# KNOWN HARNESS LIMIT: a posted Ctrl+Enter needs the app's own GetKeyState to
# see the modifier, which a plain PostMessage cannot arrange. Send-TestViewerChord
# attaches to the app's input queue first, which is exactly why it is used for
# G. The pure classification (plain Enter is a NEWLINE, never a send) is pinned
# by unit tests in `viewer_accel.zig` -- this script asserts the wiring.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-fbtest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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

# --- window plumbing ---------------------------------------------------------
# One viewer host window is expected in this run (one viewer pane), so these
# return the first match rather than making every caller thread a handle.

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

# The WebView2 widget's own window, whose TOP is the page's real inset -- i.e.
# the thing `controller.setBounds` actually moves. `Chrome_WidgetWin_0` is the
# controller's own host window; the Chromium windows under it (_1, the render
# widget, the D3D intermediate) follow it and are not what the pane positions.
#
# `-Class $null` is load-bearing: Get-TestChildWindows DEFAULTS to
# 'GhozttyTerminal', so an unfiltered-looking call with no -Class silently
# enumerates nothing (which is how this returned empty on its first run).
function Get-ContentTop($paneHwnd) {
    $best = $null
    foreach ($c in @(Get-TestChildWindows -Window $paneHwnd -Class $null)) {
        if ([string]$c.Class -ne 'Chrome_WidgetWin_0') { continue }
        if ($c.Height -le 0) { continue }
        if ($null -eq $best -or $c.Top -lt $best) { $best = [int]$c.Top }
    }
    return $best
}

# The pane's LAST reported composer state, from the GUI's stderr.
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

# The last `action=send len=N` the pane reported, or $null.
function Get-LastSendLen($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) action=send len=(\d+)") {
            $hit = [int]$Matches[1]
        }
    }
    return $hit
}

function Wait-WorktreeShown($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=shown") { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Reveal the nav bar and click its trailing feedback button. Same mechanism as
# viewer-worktree.ps1 section 3: a hidden bar has never been placed, so it is
# seeded open with WM_APP_VIEWER_FOCUS_ADDRESS (WM_APP+22) first.
function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    # The bar is 36 DIP tall, so its height IS the scale. The trailing button's
    # center is 4 DIP of band edge plus half of its 28 DIP square.
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - [Math]::Round(18 * $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

$viewFile = Join-Path $repo 'README.md'

$repoRoot = (& git -C $repo rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $repoRoot) { Write-Host "SETUP FAIL: $repo is not a working tree"; exit 1 }

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- setup: a viewer pane on a file inside this repo ---------------------
    $r = Invoke-Verb @('+new-window', '--target=fbwin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'fbwin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'fbwin'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so the button is present'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    $contentBefore = Get-ContentTop $view.Pane
    Assert ($null -ne $contentBefore) "the WebView2 widget was found (page top $contentBefore)"

    # --- A. the button opens the composer ------------------------------------
    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) "the pane reports the composer OPEN (state '$($s.Open)')"
    Assert ($s -and $s.BarH -gt 0) "...reserving a band of $($s.BarH) px"

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback child window exists'
    Assert ($fb -and (Test-TestWindowVisible $fb)) 'the composer window is visible'

    $fbRect = Get-TestWindowRect $fb
    Assert ($fbRect -and $fbRect.Height -eq $s.BarH) `
        "the composer window is exactly the band it reported ($($fbRect.Height) vs $($s.BarH))"

    # --- B. the nav bar stays open under it ----------------------------------
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    Assert ($nb -and (Test-TestWindowVisible $nb)) 'the nav bar is still visible while the composer is open'
    $nbRect = Get-TestWindowRect $nb
    Assert ($nbRect -and $fbRect -and $fbRect.Top -eq $nbRect.Bottom) `
        "the composer sits directly under the nav bar ($($fbRect.Top) vs $($nbRect.Bottom))"

    # --- C. the page is inset by the band ------------------------------------
    $contentOpen = Get-ContentTop $view.Pane
    Assert ($null -ne $contentOpen -and $contentOpen -gt $contentBefore) `
        "the page moved down for the composer ($contentBefore -> $contentOpen)"

    # --- C2. the editing surface is a real text control (T635) ---------------
    # The band paints the pill; the text lives in a RichEdit child filling the
    # pill's text rect. Everything below types into THAT, which is also the
    # check that it exists at all -- a missing Msftedit.dll leaves the pane
    # with no composer, and this is where that shows up.
    $rich = $null
    $richClass = '<none>'
    foreach ($c in @(Get-TestChildWindows -Window $fb -Class $null)) {
        $rich = [IntPtr]$c.Hwnd; $richClass = [string]$c.Class; break
    }
    Assert ($null -ne $rich -and $richClass -eq 'RichEdit50W') `
        "the composer hosts a RichEdit50W text control (found '$richClass')"
    if (-not $rich) { throw 'no text control in the composer' }
    $richRect = Get-TestWindowRect $rich
    Assert ($richRect -and $richRect.Width -gt 0 -and $richRect.Height -gt 0) `
        "the text control is placed inside the pill ($($richRect.Width)x$($richRect.Height))"

    # The empty composer's placeholder rides on EM_SETCUEBANNER, which RichEdit
    # only understands from Msftedit 8 onwards. The app logs whether the
    # control accepted it, because a cue banner is the one piece of this chrome
    # nothing else can observe from outside the process.
    $cue = $null; $painted = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match 'composer created cue_banner=(\w+) painted_placeholder=(\w+)') {
            $cue = $Matches[1]; $painted = $Matches[2]
        }
    }
    Assert (($cue -eq 'true') -or ($painted -eq 'true')) `
        "the empty composer has a placeholder by one path or the other (cue=$cue painted=$painted)"

    # --- D. the pill grows with content, and shrinks again -------------------
    # Enter is pressed as a KEY, not typed as a CR: RichEdit breaks a paragraph
    # from WM_KEYDOWN(VK_RETURN) and ignores a bare WM_CHAR 0x0D, so posting
    # the character alone silently concatenates the lines. It is also the path
    # a person takes, and it proves the main loop does not eat a bare Enter on
    # its way to the control (only Ctrl+Enter is the composer's).
    $h1 = (Get-TestWindowRect $fb).Height
    [void](Send-TestControlText -Control $rich -Text 'one')
    [void](Send-TestControlKey -Control $rich -Key Enter)
    [void](Send-TestControlText -Control $rich -Text 'two')
    [void](Send-TestControlKey -Control $rich -Key Enter)
    [void](Send-TestControlText -Control $rich -Text 'three')
    Start-Sleep -Milliseconds 400
    $h3 = (Get-TestWindowRect $fb).Height
    Assert ($h3 -gt $h1) "three lines make the composer taller ($h1 -> $h3)"

    $contentTall = Get-ContentTop $view.Pane
    Assert ($null -ne $contentTall -and $contentTall -gt $contentOpen) `
        "...and the page followed it down ($contentOpen -> $contentTall)"

    # Backspace the last line away: the band must give the space BACK, which is
    # the half a "grows with content" implementation forgets.
    for ($i = 0; $i -lt 6; $i++) { [void](Send-TestControlKey -Control $rich -Key Backspace) }
    Start-Sleep -Milliseconds 400
    $h2 = (Get-TestWindowRect $fb).Height
    Assert ($h2 -lt $h3) "deleting a line gives the space back ($h3 -> $h2)"
    $contentTwoLine = Get-ContentTop $view.Pane
    Assert ($null -ne $contentTwoLine -and $contentTwoLine -lt $contentTall) `
        "...and the page came back up with it ($contentTall -> $contentTwoLine)"

    # --- E/F. Escape closes; the text survives the round trip ----------------
    # Escape is posted at the TEXT CONTROL, which is where focus really is: a
    # multi-line RichEdit swallows both Escape and Ctrl+Enter itself, so the
    # main loop intercepts them by the control's hwnd (App.zig, T635).
    [void](Send-TestControlKey -Control $rich -Key Escape)
    $s = Wait-FeedbackState $errlog $paneId $false
    Assert ($s -and -not $s.Open) "Escape closes the composer (state '$($s.Open)')"
    Assert (-not (Test-TestWindowVisible $fb)) 'the composer window is hidden once closed'

    # The page gets back EXACTLY the composer's band -- not all the way to
    # where it started, because the nav bar is still revealed (the composer
    # pinned it, and its ordinary auto-hide deadline has only just been armed).
    # That distinction is the whole point of measuring against the bar rather
    # than against the opening value.
    $contentClosed = Get-ContentTop $view.Pane
    Assert ($null -ne $contentClosed -and $contentClosed -eq ($contentTwoLine - $h2)) `
        "the page got the composer's band back ($contentTwoLine -> $contentClosed, band $h2)"
    Assert ($contentClosed -eq (Get-TestWindowRect $nb).Bottom) `
        'the page now starts at the nav bar, with nothing reserved for a closed composer'

    Assert (Invoke-FeedbackButton $view) 're-clicking the feedback button reaches the pane'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) 'the composer reopens'
    Start-Sleep -Milliseconds 300
    $hBack = (Get-TestWindowRect $fb).Height
    Assert ($hBack -eq $h2) `
        "the reopened composer is still the size its TEXT makes it ($hBack vs $h2) -- state lives on the pane"

    # --- G. Ctrl+Enter sends, and names the length the pane still holds ------
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)
    $len = $null
    for ($t = 0; $t -lt 20; $t++) {
        $len = Get-LastSendLen $errlog $paneId
        if ($null -ne $len) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $len) "Ctrl+Enter reaches the pane as a send (len=$len)"
    Assert ($null -ne $len -and $len -gt 0) `
        "...and the text typed before the close/reopen is still there (len=$len)"

    # --- I. it edits like a text control: caret and selection (T635) ---------
    # The T634 surface could only append and backspace, so every check here is
    # one it could not have passed. The oracle is the control's own text, read
    # with WM_GETTEXT (GetWindowTextW across processes reads a cache the app
    # never sees).
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key A -Modifiers Ctrl)
    [void](Send-TestControlKey -Control $rich -Key Delete)
    Start-Sleep -Milliseconds 250
    [void](Send-TestControlText -Control $rich -Text 'bcd')
    Start-Sleep -Milliseconds 250
    Assert ((Get-TestControlText $rich) -eq 'bcd') `
        "the control starts from a known state (got '$(Get-TestControlText $rich)')"

    # Home, then type: an appending buffer would put the 'a' at the END.
    [void](Send-TestControlKey -Control $rich -Key Home)
    [void](Send-TestControlText -Control $rich -Text 'a')
    Start-Sleep -Milliseconds 250
    $caretText = Get-TestControlText $rich
    Assert ($caretText -eq 'abcd') `
        "Home moves the caret and typing inserts there (got '$caretText', want 'abcd')"

    # Shift+Right twice selects 'ab'; typing replaces the SELECTION.
    [void](Send-TestControlKey -Control $rich -Key Home)
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key Right -Modifiers Shift)
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key Right -Modifiers Shift)
    [void](Send-TestControlText -Control $rich -Text 'Z')
    Start-Sleep -Milliseconds 250
    $selText = Get-TestControlText $rich
    Assert ($selText -eq 'Zcd') `
        "a keyboard selection is replaced by what is typed over it (got '$selText', want 'Zcd')"

    # Word wrap: one long unbroken-by-newlines line still grows the pill,
    # which only a control that wraps can do.
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key A -Modifiers Ctrl)
    [void](Send-TestControlKey -Control $rich -Key Delete)
    Start-Sleep -Milliseconds 250
    $hEmpty = (Get-TestWindowRect $fb).Height
    [void](Send-TestControlText -Control $rich -Text ('wrap ' * 60) -PerKeyMs 2)
    Start-Sleep -Milliseconds 600
    $hWrapped = (Get-TestWindowRect $fb).Height
    Assert ($hWrapped -gt $hEmpty) `
        "a long line with no newlines in it wraps and grows the pill ($hEmpty -> $hWrapped)"

    # --- J. the standard editing chords (T635) -------------------------------
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key A -Modifiers Ctrl)
    [void](Send-TestControlKey -Control $rich -Key Delete)
    Start-Sleep -Milliseconds 250
    [void](Send-TestControlText -Control $rich -Text 'copyme')
    Start-Sleep -Milliseconds 250

    # Shift+End selects the line, and Ctrl+X takes it. Deliberately NOT Ctrl+A
    # here: a select-ALL in RichEdit runs through the end of the document and
    # carries its final paragraph mark onto the clipboard, so pasting it back
    # would add a newline that has nothing to do with whether the chords work.
    # (Ctrl+A itself is covered above, where it clears the control.)
    [void](Send-TestControlKey -Control $rich -Key Home)
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key End -Modifiers Shift)
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key X -Modifiers Ctrl)
    Start-Sleep -Milliseconds 300
    $afterCut = Get-TestControlText $rich
    Assert ($afterCut -eq '') "Shift+End then Ctrl+X cuts the line away (got '$afterCut')"

    # ...and Ctrl+V brings it back, twice, which proves the clipboard round
    # trip rather than an undo that happens to look the same.
    #
    # Compared with line breaks stripped: a RichEdit selection that runs to the
    # end of the document carries its final paragraph mark onto the clipboard,
    # so each paste lands as "copyme" plus a break. That is the control's own
    # documented behaviour (WordPad does it too), and this test is about
    # whether the chords work, not about that mark.
    function Flatten([string]$s) { return ($s -replace "`r`n", '' -replace "`r", '' -replace "`n", '') }
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key V -Modifiers Ctrl)
    Start-Sleep -Milliseconds 400
    $afterPaste = Flatten (Get-TestControlText $rich)
    Assert ($afterPaste -eq 'copymecopyme') `
        "Ctrl+V pastes what Ctrl+X took (got '$afterPaste', want 'copymecopyme')"

    # Ctrl+Z undoes the last paste.
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key Z -Modifiers Ctrl)
    Start-Sleep -Milliseconds 400
    $afterUndo = Flatten (Get-TestControlText $rich)
    Assert ($afterUndo -eq 'copyme') `
        "Ctrl+Z undoes the last edit (got '$afterUndo', want 'copyme')"

    # The pane's own buffer tracked all of it. The oracle is the CONTROL's own
    # text, canonicalised to LF the way the mirror does -- the invariant is
    # "the buffer is what the control holds", not a hard-coded number, and it
    # is what the report writer (T637) will read.
    $ctlText = (Get-TestControlText $rich) -replace "`r`n", "`n" -replace "`r", "`n"
    $lenBefore = Get-LastSendLen $errlog $paneId
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)
    $lenAfter = $null
    for ($t = 0; $t -lt 20; $t++) {
        $lenAfter = Get-LastSendLen $errlog $paneId
        if ($lenAfter -ne $lenBefore) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($lenAfter -eq $ctlText.Length) `
        "the pane's buffer mirrors the control through all of it (len=$lenAfter, control holds $($ctlText.Length))"

    # --- H. the chords are pane-scoped ---------------------------------------
    # A terminal pane gets the same two chords. Nothing composer-shaped may
    # happen: no open/close transition, no send.
    $r = Invoke-Verb @('+new-window', '--target=fbterm')
    Assert ($r.Code -eq 0) "+new-window (terminal) exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'fbterm')) 'the terminal window exists'
    $sendsBefore = Get-LastSendLen $errlog $paneId
    $stateBefore = Get-FeedbackState $errlog $paneId
    $termTop = [IntPtr]::Zero
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        $h = [IntPtr]$top.Hwnd
        if (@(Get-TestChildWindows -Window $h -Class 'GhozttyViewer').Count -eq 0) { $termTop = $h; break }
    }
    Assert ($termTop -ne [IntPtr]::Zero) 'the terminal window was found'
    if ($termTop -ne [IntPtr]::Zero) {
        $surf = @(Get-TestChildWindows -Window $termTop -Class 'GhozttyTerminal')
        if ($surf.Count -gt 0) {
            [void](Send-TestKeys -Window $termTop -Target ([IntPtr]$surf[0].Hwnd) -Key Escape)
            [void](Send-TestKeys -Window $termTop -Target ([IntPtr]$surf[0].Hwnd) -Key Enter -Modifiers Ctrl)
            Start-Sleep -Milliseconds 800
        }
        Assert ($surf.Count -gt 0) 'the terminal surface window was found'
    }
    $sendsAfter = Get-LastSendLen $errlog $paneId
    $stateAfter = Get-FeedbackState $errlog $paneId
    Assert ($sendsAfter -eq $sendsBefore) `
        'Escape/Ctrl+Enter in a TERMINAL pane sent no feedback (the chords are pane-scoped)'
    Assert ($stateAfter.Open -eq $stateBefore.Open) `
        '...and did not open or close the viewer pane''s composer either'

    # --- app survived all of it ----------------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
