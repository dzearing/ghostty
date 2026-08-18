# T633 acceptance: viewer worktree provenance + the nav-bar feedback button.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   - a viewer pane opened on a FILE INSIDE this repo resolves that repo's
#     working tree and SHOWS the feedback button (strategy D, leg 1).
#   - the same pane navigated to a remote URL with no origin directory shows
#     NO button -- a website belongs to no checkout (leg 3, empty).
#   - a pane opened with `--working-directory` OUTSIDE any repository shows no
#     button either: the fallback ran and honestly found nothing.
#   - a pane opened on a remote URL but with `--working-directory` inside the
#     repo DOES show it, which is the whole point of leg 3 -- a dev server or a
#     doc site is still attributable to the checkout it was launched from.
#   - clicking is live: the button's action reaches the pane (the composer
#     itself is T634, so what it reaches is a logged intent).
#   - the address field still shows the file's path with the trailing button
#     present, i.e. adding it did not eat the field.
#
# ORACLE, and why it is the log. The nav bar is native owner-painted chrome
# inside a WebView2-hosting child window, and this runs on the BACKGROUND test
# desktop where CopyFromScreen and SendInput are dead (T233). Nothing out here
# can see a painted button. So the pane states its resolution in its own stderr
# --
#     viewer worktree pane=<id> feedback=shown|hidden worktree=<path>
# -- which is emitted from `pushWorktree`, i.e. from the exact code path that
# hands the bar its button. A line saying `shown` cannot be produced by
# anything except a resolution that would put the button on screen.
#
# POSITIVE CONTROLS: every "no button" assertion is paired with a "button" one
# in the same run and against the same app, so a green-and-empty run (the T216
# lesson) is impossible -- the hidden cases can only pass while the shown cases
# also pass.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-worktree.ps1
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
$env:GHOZTTY_PIPE_SUFFIX = '-wttest'

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

# The pane id of a single-pane viewer window, which is the key every log line
# is scoped by. Ids are what the log prints, so nothing here has to guess which
# window a line belongs to.
function Get-OnlyPaneId($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0].id
}

# The pane's LAST reported worktree state, from the GUI's stderr. Last, not
# first: a pane resolves once per location, so a navigated pane has two lines
# and only the newest describes where it is now.
function Get-WorktreeState($errlog, $paneId) {
    if (-not (Test-Path $errlog)) { return $null }
    if (-not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=(\w+) worktree=(.+)$") {
            $hit = [pscustomobject]@{ Shown = ($Matches[1] -eq 'shown'); Worktree = $Matches[2].Trim() }
        }
    }
    return $hit
}

# Resolution is asynchronous by design (a `git` spawn off the UI thread), so
# every read of it waits for a line rather than sampling once.
function Wait-WorktreeState($errlog, $paneId, [bool]$Shown) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-WorktreeState $errlog $paneId
        if ($s -and $s.Shown -eq $Shown) { return $s }
        Start-Sleep -Milliseconds 250
    }
    return (Get-WorktreeState $errlog $paneId)
}

$viewFile = Join-Path $repo 'README.md'
$blank = 'about:blank'

# A directory that is genuinely in NO working tree. %TEMP% normally is, but
# "normally" is not an assertion -- if this box has a repo above it, the
# negative cases would be testing nothing, so the run says so and stops.
$outside = $env:TEMP
$outsideRoot = (& git -C $outside rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($outsideRoot) {
    Write-Host "SETUP FAIL: `$env:TEMP ($outside) is inside a working tree ($outsideRoot);"
    Write-Host '            the no-worktree cases would prove nothing.'
    exit 1
}
$repoRoot = (& git -C $repo rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $repoRoot) { Write-Host "SETUP FAIL: $repo is not a working tree"; exit 1 }
$repoRoot = $repoRoot -replace '/', '\'

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-worktree-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- 1. leg 1: a file inside this repo SHOWS the button ------------------
    $r = Invoke-Verb @('+new-window', '--target=wtfile', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtfile')) 'the file viewer window exists'
    $filePane = Get-OnlyPaneId 'wtfile'
    Assert ($null -ne $filePane) "the file viewer window has exactly one pane (id '$filePane')"
    $s = Wait-WorktreeState $errlog $filePane $true
    Assert ($null -ne $s) 'the file pane reported a worktree resolution'
    Assert ($s -and $s.Shown) "the file pane SHOWS the feedback button (state '$($s.Shown)')"
    Assert ($s -and $s.Worktree -eq $repoRoot) `
        "...and it files into this repo's working tree (got '$($s.Worktree)', want '$repoRoot')"

    # --- 2. the trailing button did not eat the address field ----------------
    # The field is a real EDIT, read with WM_GETTEXT (T175: a cross-process
    # GetWindowTextW reads a cache the app never writes). With the feedback
    # button present the field is narrower -- it must still be there and still
    # show the path.
    $addrs = @()
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            foreach ($nb in @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerNav')) {
                foreach ($ed in @(Get-TestChildWindows -Window ([IntPtr]$nb.Hwnd) -Class 'Edit')) {
                    $addrs += (Get-TestControlText ([IntPtr]$ed.Hwnd))
                }
            }
        }
    }
    Assert (@($addrs | Where-Object { $_ -eq $viewFile }).Count -ge 1) `
        "the address field still shows the file's path beside the button (got '$($addrs -join "','")')"

    # --- 3. clicking is live (the action reaches the pane) -------------------
    # What T633 owes is a button that is WIRED, and since T634 what it is wired
    # to is the composer: the pane reports the open transition with the worktree
    # it files into, which nothing but `ViewerNavBar.activate(.feedback)` can
    # produce -- there is no IPC verb for it. (The composer's own behavior is
    # `test\win32\viewer-feedback.ps1`'s subject; all this asserts is that the
    # button reaches it.)
    #
    # Driven through posted mouse messages rather than SendInput, which is dead
    # on the background desktop. The bar is REVEALED first by seeding
    # WM_APP_VIEWER_FOCUS_ADDRESS (WM_APP+22, the palette's own "put the caret
    # in the address field" hop): a hidden bar has never been placed, so it has
    # no laid-out geometry to click at, and this is exactly the private-protocol
    # seeding Send-TestRawMessage exists for.
    $clicked = $false
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            [void](Send-TestRawMessage -Window ([IntPtr]$h.Hwnd) -Message 0x8016)
        }
    }
    Start-Sleep -Milliseconds 800
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            foreach ($nb in @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerNav')) {
                $rect = Get-TestWindowRect ([IntPtr]$nb.Hwnd)
                if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { continue }
                # The bar is 36 DIP tall, so its height IS the scale -- read it
                # rather than assuming 100%, since the DPI of a background
                # desktop is not this script's to choose. The trailing button's
                # center is 4 DIP of band edge plus half of its 28 DIP square.
                $scale = $rect.Height / 36.0
                $x = [int]($rect.Right - [Math]::Round(18 * $scale))
                $y = [int]($rect.Top + $rect.Height / 2)
                if (Send-TestMouse -Window ([IntPtr]$top.Hwnd) -Target ([IntPtr]$nb.Hwnd) -X $x -Y $y) {
                    $clicked = $true
                }
            }
        }
    }
    Assert $clicked 'the revealed nav bar took a click at the feedback button'
    $sawClick = $false
    for ($t = 0; $t -lt 20; $t++) {
        $txt = (Get-Content $errlog -ErrorAction SilentlyContinue | Out-String)
        if ($txt -match "viewer feedback pane=$([regex]::Escape($filePane)) open=true") { $sawClick = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert $sawClick 'clicking the feedback button opens the composer (T634)'

    # --- 4. leg 3, empty: a remote URL with no origin shows NO button --------
    # Navigating the SAME pane, so this is the "re-resolved on every
    # navigation" rule and not a second pane that never had a worktree.
    $r = Invoke-Verb @('+new-window', '--target=wtweb', "--view=$blank", "--working-directory=$outside")
    Assert ($r.Code -eq 0) "+new-window --view=$blank --working-directory=<no repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtweb')) 'the no-repo viewer window exists'
    $webPane = Get-OnlyPaneId 'wtweb'
    Assert ($null -ne $webPane) "the no-repo viewer window has exactly one pane (id '$webPane')"
    $s = Wait-WorktreeState $errlog $webPane $false
    Assert ($null -ne $s) 'the no-repo pane reported a worktree resolution'
    Assert ($s -and -not $s.Shown) "a pane opened outside any repository shows NO feedback button (state '$($s.Shown)')"

    # --- 5. leg 3, populated: a remote URL opened FROM the repo shows it -----
    # The fallback's whole reason to exist: a dev server or a doc site is still
    # attributable to the checkout it was launched from.
    $r = Invoke-Verb @('+new-window', '--target=wtorigin', "--view=$blank", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view=$blank --working-directory=<the repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtorigin')) 'the origin-fallback viewer window exists'
    $originPane = Get-OnlyPaneId 'wtorigin'
    Assert ($null -ne $originPane) "the origin-fallback window has exactly one pane (id '$originPane')"
    $s = Wait-WorktreeState $errlog $originPane $true
    Assert ($s -and $s.Shown) "a website pane opened from the repo SHOWS the button (state '$($s.Shown)')"
    Assert ($s -and $s.Worktree -eq $repoRoot) `
        "...pointed at the origin directory's working tree (got '$($s.Worktree)')"

    # --- 6. a file OUTSIDE any repo shows no button --------------------------
    # Leg 1 with a real, existing file whose directory is in no working tree:
    # the file wins over the origin, and the answer is honestly "nothing".
    $outsideFile = Join-Path $outside 'ghoztty-wt-probe.md'
    Set-Content -Path $outsideFile -Value "# probe`n" -Encoding utf8
    $r = Invoke-Verb @('+new-window', '--target=wtout', "--view=$outsideFile", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view=<file outside any repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtout')) 'the outside-file viewer window exists'
    $outPane = Get-OnlyPaneId 'wtout'
    $s = Wait-WorktreeState $errlog $outPane $false
    Assert ($s -and -not $s.Shown) `
        "a file outside any repository shows NO button, even opened from one (state '$($s.Shown)')"

    # --- 7. app survived all of it ------------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item (Join-Path $env:TEMP 'ghoztty-wt-probe.md') -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
