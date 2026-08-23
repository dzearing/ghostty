# T1131 acceptance: which viewer panes keep their address bar on screen.
#
# THE CONTRACT, carried over from Mac's 5241d7bec. A LIVE PAGE - a website, or
# a local `.html` file the web view renders as one - is something you NAVIGATE,
# so its address and history controls stay put: the bar is pinned open from the
# pane's first layout, with no hover and no cursor anywhere near it. A markdown
# or code viewer is a reading surface whose address rarely changes, so it keeps
# the HOVER PEEK and shows no bar until the mouse reaches the strip at the top.
#
# WHY THIS IS MEASURABLE WHERE THE HOVER PEEK IS NOT (T1152). The peek runs
# behind a `GetCursorPos` sample that fails on a background desktop, so a script
# running there can never reveal the bar by hovering. The PIN does not go
# through the cursor at all - it is applied at the moment the pane's mode is
# decided (`ViewerPane.updateNavPin`) - which is exactly why the pinned half is
# assertable here and the peek half is asserted in the none/win32 lanes
# (`viewer_nav_layout.zig`'s hover policy table).
#
# THE ORACLE is window state, not pixels: the bar is a `GhozttyViewerNav` child
# window of the pane host, so "is it on screen" is `IsWindowVisible` plus a rect
# comparison, and "does it reserve its band rather than cover the page" is the
# WebView2 child's top edge against the bar's bottom. No composite, no
# foreground, no cursor - the three things the background desktop cannot give.
#
#   powershell -NoProfile -File test\win32\viewer-nav-pin.ps1
#
# -NegativeControl inverts the FLAVOR SPLIT (sections A-D): every pane is
# asserted to do the opposite of what it should, so a correct build fails all
# four and a build that pinned everything (or nothing) would score some of them
# green. Anything other than four failures means the split is not what is being
# measured.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vnpin$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')

# T1127: everything running out of this build's directory is reaped when this
# PowerShell exits, including a detached `--pty-host` holder.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
# The four flavor assertions, and the only ones -NegativeControl inverts.
function Assert-Split([bool]$cond, [string]$label) {
    if ($NegativeControl) { Assert (-not $cond) "$label (INVERTED)" }
    else { Assert $cond $label }
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
function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 25; $t++) {
        $d = Get-Data
        if ($d) { foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } } }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

# One viewer pane's chrome state. The pane host is `GhozttyViewer`; the bar is
# its `GhozttyViewerNav` child. Returns $null when the pane is not there yet, so
# a caller can wait rather than assert on a half-built pane.
function Measure-Bar([IntPtr]$topHwnd) {
    $hosts = @(Get-TestChildWindows -Window $topHwnd -Class 'GhozttyViewer')
    if ($hosts.Count -ne 1) { return $null }
    $h = $hosts[0]
    $bars = @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerNav')
    if ($bars.Count -ne 1) { return $null }
    $bar = $bars[0]
    # The page itself: WebView2 parents its own window tree under the host, and
    # every class it uses starts with `Chrome_`. Which one is the render widget
    # is WebView2's business and changes between runtimes, so the topmost edge
    # of ALL of them is what the page occupies.
    $pageTop = $null
    foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class '*')) {
        if (-not $c.Visible) { continue }
        if ($c.Class -notlike 'Chrome_*') { continue }
        if ($null -eq $pageTop -or $c.Top -lt $pageTop) { $pageTop = $c.Top }
    }
    return [pscustomobject]@{
        Host = $h
        Bar = $bar
        BarVisible = ($bar.Visible -and $bar.Height -gt 0)
        PageTop = $pageTop
    }
}

# Open one viewer pane in its own window, measure it, and tear the window down
# again - so each flavor is a FRESH pane whose mode was decided at open, which
# is the moment the pin is applied.
function Measure-Flavor([string]$target, [string]$location) {
    Invoke-Verb @('+new-window', "--target=$target") | Out-Null
    if (-not (Wait-Win $target)) { return $null }
    $r = Invoke-Verb @('+split', "--target=$target", "--view=$location", "--name=$target-v")
    if ($r.Code -ne 0) {
        Write-Host "      +split --view exited $($r.Code): $($r.Out)" -ForegroundColor Yellow
        return $null
    }
    $m = $null
    for ($t = 0; $t -lt 30; $t++) {
        Start-Sleep -Milliseconds 400
        $top = [IntPtr]::Zero
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if (@(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
                $top = [IntPtr]$w.Hwnd
            }
        }
        if ($top -eq [IntPtr]::Zero) { continue }
        $m = Measure-Bar $top
        # A pane with a page under it is a settled pane; keep waiting otherwise.
        if ($m -and $null -ne $m.PageTop) { break }
    }
    return $m
}

$mdFile = Join-Path $repo 'README.md'
$codeFile = Join-Path $repo 'build.zig'
$htmlFile = Join-Path $env:TEMP "ghoztty-navpin-$PID.html"
Set-Content -Path $htmlFile -Encoding utf8 -Value @'
<!doctype html><meta charset="utf-8"><title>nav pin</title>
<body style="font:16px system-ui;margin:2rem">A live local page.</body>
'@

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$launched = @()
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-nav-pin-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    $launched += $script:GhozttyTestDesktopPids
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # A: a local .html page is a LIVE page - the bar is there without hovering.
    # This is also the section that proves the measurement works at all, so it
    # runs first and its containment/inset checks are the ones sections B-D
    # lean on.
    Write-Host ''
    Write-Host 'A: a local HTML page keeps its address bar'
    $html = Measure-Flavor 'vpA' $htmlFile
    Assert ($null -ne $html) 'A: the HTML viewer pane and its nav bar exist'
    if ($html) {
        Write-Host ("      bar visible=$($html.BarVisible) rect=$($html.Bar.Left),$($html.Bar.Top).." +
            "$($html.Bar.Right),$($html.Bar.Bottom) host top=$($html.Host.Top) pageTop=$($html.PageTop)")
        Assert-Split $html.BarVisible 'A: the bar is on screen with no hover at all'
        # It is the pane's OWN top band: a bar somewhere else on screen would
        # satisfy "visible" and be useless.
        Assert ($html.Bar.Top -eq $html.Host.Top) 'A: the bar sits at the top of its pane'
        Assert ($html.Bar.Left -ge $html.Host.Left -and $html.Bar.Right -le $html.Host.Right) `
            'A: the bar is inside its pane'
        # RESERVED, not overlaid: the page starts below the bar. This is the
        # criterion a bar that slid in over content would fail.
        Assert ($null -ne $html.PageTop) 'A: the page window under the bar was found (positive control)'
        if ($null -ne $html.PageTop) {
            Assert ($html.PageTop -ge $html.Bar.Bottom) `
                "A: the page starts below the bar (page top=$($html.PageTop), bar bottom=$($html.Bar.Bottom))"
        }
    }
    Invoke-Verb @('+close', '--target=vpA') | Out-Null
    Start-Sleep -Milliseconds 800

    # B: a website. Deliberately an address nothing answers: the pane's MODE is
    # decided from the location, not from what loads, so the bar must be pinned
    # over a failed page too - which is the case that matters most, since a
    # blank browser pane is nothing but its address field.
    Write-Host ''
    Write-Host 'B: a website keeps its address bar, even when the page does not load'
    $web = Measure-Flavor 'vpB' 'http://127.0.0.1:1/'
    Assert ($null -ne $web) 'B: the website viewer pane and its nav bar exist'
    if ($web) {
        Write-Host "      bar visible=$($web.BarVisible) height=$($web.Bar.Height)"
        Assert-Split $web.BarVisible 'B: the bar is on screen with no hover at all'
    }
    Invoke-Verb @('+close', '--target=vpB') | Out-Null
    Start-Sleep -Milliseconds 800

    # C: a markdown document is a READING surface - hover peek, so no bar until
    # the mouse asks for one, and nothing on this desktop can ask.
    Write-Host ''
    Write-Host 'C: a markdown document keeps the hover peek'
    $md = Measure-Flavor 'vpC' $mdFile
    Assert ($null -ne $md) 'C: the markdown viewer pane and its nav bar exist'
    if ($md) {
        Write-Host "      bar visible=$($md.BarVisible) height=$($md.Bar.Height)"
        Assert-Split (-not $md.BarVisible) 'C: no bar is showing until it is hovered'
    }
    Invoke-Verb @('+close', '--target=vpC') | Out-Null
    Start-Sleep -Milliseconds 800

    # D: and so is a code file.
    Write-Host ''
    Write-Host 'D: a code file keeps the hover peek'
    $code = Measure-Flavor 'vpD' $codeFile
    Assert ($null -ne $code) 'D: the code viewer pane and its nav bar exist'
    if ($code) {
        Write-Host "      bar visible=$($code.BarVisible) height=$($code.Bar.Height)"
        Assert-Split (-not $code.BarVisible) 'D: no bar is showing until it is hovered'
    }
    Invoke-Verb @('+close', '--target=vpD') | Out-Null

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived the whole run'
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
    Remove-Item $htmlFile -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due. A negative-control run is red by construction, so it
# never stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-nav-pin -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
