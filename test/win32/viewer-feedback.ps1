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
#   G. Ctrl+Enter sends, and a COMPLETE report folder lands in the throwaway
#      repo's `temp/feedback/new/` (T636): the queue is polled the way a
#      watcher polls it, so a folder seen without its `report.json` would fail
#      the atomicity assertion; the JSON's worktree branch/commit are the
#      throwaway repo's exact revision; and the composer empties and closes
#      itself behind the confirmation.
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
#         viewer feedback pane=<id> action=send bytes=<n> quotes=<n> ...
#         viewer feedback pane=<id> filed=<bool> stem=<name> status=<text>
#     which is what F and G read. G's real oracle, though, is the FILE the
#     send produced -- a watcher's view of the report rather than the pane's
#     view of itself.
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

# The last `action=send bytes=N quotes=M` the pane reported, or $null.
function Get-LastSendLen($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) action=send bytes=(\d+)") {
            $hit = [int]$Matches[1]
        }
    }
    return $hit
}

# The last `buffer=N` (the composer's RAW text length) the pane reported.
function Get-LastSendBuffer($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) action=send bytes=\d+ buffer=(\d+)") {
            $hit = [int]$Matches[1]
        }
    }
    return $hit
}

# Every report folder currently in the queue, with whether it is COMPLETE. A
# folder without its `report.json` is what a watcher must never see -- the
# publish is a rename of a finished folder, so such a state cannot exist.
function Get-QueueFolders($queueDir) {
    if (-not (Test-Path $queueDir)) { return @() }
    return @(Get-ChildItem -Path $queueDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            Complete = (Test-Path (Join-Path $_.FullName 'report.json'))
        }
    })
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

# A THROWAWAY working tree, not this repo (T636).
#
# Since the report writer landed, arm G's Ctrl+Enter FILES a report into the
# worktree the pane's content belongs to. Pointed at this checkout, every
# acceptance run would drop a junk report into the user's own
# `temp/feedback/new/` queue for their watcher to pick up. A temp repo is also
# what makes the revision assertions exact: this one's branch and commit are
# whatever the developer happens to be on.
$work = Join-Path $env:TEMP ("ghoztty-feedback-accept-" + $PID)
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
# git prints FORWARD slashes on Windows; the app normalizes them at the one
# place the string enters it (viewer_worktree.parseRoot), so the comparison
# below has to be against the normalized form rather than git's own.
$workRoot = (& git -C $work rev-parse --show-toplevel 2>$null | Out-String).Trim().Replace('/', '\')
if (-not $workRoot) { Write-Host "SETUP FAIL: could not make a throwaway repo at $work"; exit 1 }
$workCommit = (& git -C $work rev-parse HEAD 2>$null | Out-String).Trim()
$queueDir = Join-Path $work 'temp\feedback\new'
$stagingDir = Join-Path $work 'temp\feedback\.staging'

$viewFile = Join-Path $work 'README.md'

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

    # --- G. Ctrl+Enter sends, and a complete report lands on disk (T636) -----
    # `@(...)` at every call site, not just inside the function: PowerShell
    # unrolls a one-element array on return, and `.Count` on the bare object is
    # $null -- which reads as "0 folders" and passes a test that should fail.
    Assert (@(Get-QueueFolders $queueDir).Count -eq 0) 'the queue starts empty'
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)
    $len = $null
    for ($t = 0; $t -lt 20; $t++) {
        $len = Get-LastSendLen $errlog $paneId
        if ($null -ne $len) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $len) "Ctrl+Enter reaches the pane as a send (bytes=$len)"
    Assert ($null -ne $len -and $len -gt 0) `
        "...and the text typed before the close/reopen is still there (bytes=$len)"

    # Poll the queue the way a watcher does, and record whether one was ever
    # observed WITHOUT its report.json. The publish is a single rename of a
    # folder that is already finished, so the answer must be never -- that is
    # the atomicity property, asserted rather than assumed.
    $folders = @()
    $sawPartial = $false
    for ($t = 0; $t -lt 80; $t++) {
        $folders = @(Get-QueueFolders $queueDir)
        foreach ($f in $folders) { if (-not $f.Complete) { $sawPartial = $true } }
        if ($folders.Count -gt 0 -and -not $sawPartial) { break }
        Start-Sleep -Milliseconds 50
    }
    Assert ($folders.Count -eq 1) "exactly one report folder appeared (got $($folders.Count))"
    Assert (-not $sawPartial) 'no folder was ever visible in the queue without its report.json'
    Assert (-not (Test-Path (Join-Path $stagingDir $folders[0].Name))) `
        'the staging folder is gone -- it WAS the published one, renamed'

    $reportPath = Join-Path $queueDir (Join-Path $folders[0].Name 'report.json')
    $report = $null
    try { $report = Get-Content $reportPath -Raw | ConvertFrom-Json } catch { }
    Assert ($null -ne $report) "the report parses as JSON ($reportPath)"
    if ($report) {
        Assert ($report.version -ge 2) "...with the shared schema version (got $($report.version))"
        Assert ($report.body.Length -gt 0) "...a body ($($report.body.Length) chars)"
        Assert ($report.source.kind -eq 'file') "...the source kind ('$($report.source.kind)')"
        Assert ($report.source.relativePath -eq 'README.md') `
            "...the path repo-relative and forward-slashed ('$($report.source.relativePath)')"
        Assert ($report.source.paneID -eq $paneId) `
            "...the pane it came from ('$($report.source.paneID)')"
        Assert ($report.worktree.path -eq $workRoot) `
            "...the worktree it was filed into ('$($report.worktree.path)')"
        # The revision half T633 did not ship: this is the exact commit the
        # throwaway repo is on, so a stale or guessed value cannot pass.
        Assert ($report.worktree.branch -eq 'main') `
            "...the branch the user was on ('$($report.worktree.branch)')"
        Assert ($report.worktree.commit -eq $workCommit) `
            "...and the commit ('$($report.worktree.commit)')"
    }

    # On success the composer empties and says so, then closes itself behind
    # the confirmation.
    $filed = $false
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) filed=true stem=(\S+)") {
                $filed = $true
            }
        }
        if ($filed) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert $filed 'the pane reports the report as filed'
    Assert ((Get-TestControlText $rich) -eq '') `
        "the composer is empty after a successful send (got '$(Get-TestControlText $rich)')"
    $sClosed = Wait-FeedbackState $errlog $paneId $false
    Assert ($sClosed -and -not $sClosed.Open) 'the composer closes itself behind the confirmation'

    # ...and the rest of the arms need it open again.
    Assert (Invoke-FeedbackButton $view) 're-opening the composer after a send reaches the pane'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) 'the composer is open again for the editing arms'

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

    # ...and the wrap FOLLOWS the pane. Narrowing the window re-wraps the same
    # text onto more lines, which the composer only notices if it re-reads the
    # control's line count after being moved (a layout pass is driven by that
    # count, so the naive version leaves the pill a stale height until the next
    # keystroke).
    $winRect = Get-TestWindowRect $view.Top
    [void](Set-TestWindowSize -Window $view.Top -Width ([int]($winRect.Width * 0.6)) -Height $winRect.Height)
    Start-Sleep -Milliseconds 900
    $hNarrow = (Get-TestWindowRect $fb).Height
    Assert ($hNarrow -gt $hWrapped) `
        "narrowing the pane re-wraps and the pill follows without a keystroke ($hWrapped -> $hNarrow)"
    [void](Set-TestWindowSize -Window $view.Top -Width $winRect.Width -Height $winRect.Height)
    Start-Sleep -Milliseconds 900
    $hWide = (Get-TestWindowRect $fb).Height
    Assert ($hWide -eq $hWrapped) `
        "...and widening it back gives the height back ($hNarrow -> $hWide, want $hWrapped)"

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

    # ...and a second Ctrl+Z steps back again (the first paste) rather than
    # idling on a formatting record that changes no text (T644).
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key Z -Modifiers Ctrl)
    Start-Sleep -Milliseconds 400
    $afterUndo2 = Flatten (Get-TestControlText $rich)
    Assert ($afterUndo2 -eq '') `
        "a second Ctrl+Z undoes the first paste too (got '$afterUndo2', want '')"

    # Typed text undoes as the WORD, not a letter and not nothing: the
    # composer's per-keystroke plain-format reset must stay off the undo stack
    # AND leave RichEdit's group-typing aggregation alone (T644) — a message
    # sent between two keystrokes ends the group even when it is unrecorded.
    [void](Send-TestControlText -Control $rich -Text 'undome')
    Start-Sleep -Milliseconds 300
    [void](Send-TestKeys -Window $view.Top -Target $rich -Key Z -Modifiers Ctrl)
    Start-Sleep -Milliseconds 400
    $afterTypeUndo = Flatten (Get-TestControlText $rich)
    Assert ($afterTypeUndo -eq '') `
        "Ctrl+Z after typing a word removes the word (got '$afterTypeUndo', want '')"

    # Text back for the mirror check below, typed the ordinary way.
    [void](Send-TestControlText -Control $rich -Text 'copyme')
    Start-Sleep -Milliseconds 300

    # The pane's own buffer tracked all of it. The oracle is the CONTROL's own
    # text, canonicalised to LF the way the mirror does -- the invariant is
    # "the buffer is what the control holds", not a hard-coded number, and it
    # is what the report writer reads.
    #
    # `buffer=`, not `bytes=`: since T636 a send also reports the RENDERED body
    # length, which is deliberately not the same number (it is trimmed, and
    # quoted lines carry a `> `). This arm is about the mirror, so it reads the
    # raw buffer.
    $ctlText = (Get-TestControlText $rich) -replace "`r`n", "`n" -replace "`r", "`n"
    $bufBefore = Get-LastSendBuffer $errlog $paneId
    [void](Send-TestViewerChord -Window $view.Top -Target $rich -Key Enter -Modifiers Ctrl)
    $bufAfter = $null
    for ($t = 0; $t -lt 20; $t++) {
        $bufAfter = Get-LastSendBuffer $errlog $paneId
        if ($bufAfter -ne $bufBefore) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($bufAfter -eq $ctlText.Length) `
        "the pane's buffer mirrors the control through all of it (buffer=$bufAfter, control holds $($ctlText.Length))"

    # That probe was a REAL send (T636), so it filed a second report and the
    # composer is clearing and closing itself behind the confirmation. Wait it
    # out rather than letting it land in the middle of the next arm, which
    # compares the composer's open state across a terminal-pane chord.
    [void](Wait-FeedbackState $errlog $paneId $false)

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
    # The throwaway repo goes with the run, reports and all -- it exists so the
    # send has somewhere to file that is not the user's own queue.
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this harness been run against the composer as it now
# stands?". Red leaves the stamp alone - red stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-feedback -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
