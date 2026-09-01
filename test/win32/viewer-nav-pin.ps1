# T1185 acceptance: every viewer pane keeps its address bar on screen.
#
# THE CONTRACT, carried over from Mac's fc7e36356 (which finished what
# 5241d7bec started). The nav bar is part of a viewer pane's FRAME: it is there
# from the pane's first layout in every mode - website, local `.html` page,
# markdown document, code file, diff - with no hover and no cursor anywhere
# near it. There is no peek left to reveal it and no state in which it is
# absent, which is the whole point: the way out of a pane is never something to
# hunt for with the mouse, and nothing reflows when the pointer crosses the top
# edge.
#
# WHY THIS IS MEASURABLE (T1152). The old peek ran behind a `GetCursorPos`
# sample that fails on a background desktop, so a script running there could
# never reveal a bar by hovering - which is why the peek's own half was only
# ever assertable in the unit lanes. With the peek gone the whole contract is
# cursor-free, so all of it is assertable right here.
#
# THE ORACLE is window state, not pixels: the bar is a `GhozttyViewerNav` child
# window of the pane host, so "is it on screen" is `IsWindowVisible` plus a rect
# comparison, and "does it reserve its band rather than cover the page" is the
# WebView2 child's top edge against the bar's bottom. No composite, no
# foreground, no cursor - the three things the background desktop cannot give.
#
#   powershell -NoProfile -File test\win32\viewer-nav-pin.ps1
#
# -NegativeControl inverts the PRESENCE assertions (sections A-E): every pane is
# asserted to hide the bar it must show, so a correct build fails all five. A
# build that regressed one mode back to the peek would score that one green,
# which is the shape this control exists to make visible. Anything other than
# five failures means presence is not what is being measured.
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
# The five presence assertions, and the only ones -NegativeControl inverts.
function Assert-Pinned([bool]$cond, [string]$label) {
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
# again - so each flavor is a FRESH pane, measured in the state its very first
# layout left it in.
function Measure-Flavor([string]$target, [string]$location) {
    Invoke-Verb @('+new-window', "--target=$target") | Out-Null
    if (-not (Wait-Win $target)) { return $null }
    # --working-directory pins where a repo-relative view (git-diff:) resolves
    # from, rather than inheriting whatever the app was launched in.
    $r = Invoke-Verb @('+split', "--target=$target", "--view=$location", "--name=$target-v",
        "--working-directory=$repo")
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

    # A: a local .html page. This is also the section that proves the
    # measurement works at all, so it runs first and its containment checks are
    # the ones sections B-E lean on.
    Write-Host ''
    Write-Host 'A: a local HTML page keeps its address bar'
    $html = Measure-Flavor 'vpA' $htmlFile
    Assert ($null -ne $html) 'A: the HTML viewer pane and its nav bar exist'
    if ($html) {
        Write-Host ("      bar visible=$($html.BarVisible) rect=$($html.Bar.Left),$($html.Bar.Top).." +
            "$($html.Bar.Right),$($html.Bar.Bottom) host top=$($html.Host.Top) pageTop=$($html.PageTop)")
        Assert-Pinned $html.BarVisible 'A: the bar is on screen with no hover at all'
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
        Assert-Pinned $web.BarVisible 'B: the bar is on screen with no hover at all'
    }
    Invoke-Verb @('+close', '--target=vpB') | Out-Null
    Start-Sleep -Milliseconds 800

    # C: a markdown document - one of the two modes T1185 changed, and the one
    # the inset matters most in: this is where the document used to reflow
    # under the pointer as the bar peeked in over it.
    Write-Host ''
    Write-Host 'C: a markdown document keeps its address bar'
    $md = Measure-Flavor 'vpC' $mdFile
    Assert ($null -ne $md) 'C: the markdown viewer pane and its nav bar exist'
    if ($md) {
        Write-Host "      bar visible=$($md.BarVisible) height=$($md.Bar.Height) pageTop=$($md.PageTop)"
        Assert-Pinned $md.BarVisible 'C: the bar is on screen with no hover at all'
        Assert ($md.Bar.Top -eq $md.Host.Top) 'C: the bar sits at the top of its pane'
        Assert ($null -ne $md.PageTop) 'C: the page window under the bar was found (positive control)'
        if ($null -ne $md.PageTop) {
            Assert ($md.PageTop -ge $md.Bar.Bottom) `
                "C: the document starts below the bar (page top=$($md.PageTop), bar bottom=$($md.Bar.Bottom))"
        }
    }
    Invoke-Verb @('+close', '--target=vpC') | Out-Null
    Start-Sleep -Milliseconds 800

    # D: and so does a code file.
    Write-Host ''
    Write-Host 'D: a code file keeps its address bar'
    $code = Measure-Flavor 'vpD' $codeFile
    Assert ($null -ne $code) 'D: the code viewer pane and its nav bar exist'
    if ($code) {
        Write-Host "      bar visible=$($code.BarVisible) height=$($code.Bar.Height) pageTop=$($code.PageTop)"
        Assert-Pinned $code.BarVisible 'D: the bar is on screen with no hover at all'
        Assert ($code.Bar.Top -eq $code.Host.Top) 'D: the bar sits at the top of its pane'
        Assert ($null -ne $code.PageTop) 'D: the page window under the bar was found (positive control)'
        if ($null -ne $code.PageTop) {
            Assert ($code.PageTop -ge $code.Bar.Bottom) `
                "D: the code starts below the bar (page top=$($code.PageTop), bar bottom=$($code.Bar.Bottom))"
        }
    }
    Invoke-Verb @('+close', '--target=vpD') | Out-Null
    Start-Sleep -Milliseconds 800

    # E: a diff pane. Its OWN chrome - the change list and the layout controls
    # - is T817's, but the unconditional rule covers it today, and a mode that
    # quietly kept the old absence is exactly what this section catches.
    Write-Host ''
    Write-Host 'E: a diff pane keeps its address bar'
    $diff = Measure-Flavor 'vpE' 'git-diff:HEAD'
    Assert ($null -ne $diff) 'E: the diff viewer pane and its nav bar exist'
    if ($diff) {
        Write-Host "      bar visible=$($diff.BarVisible) height=$($diff.Bar.Height) pageTop=$($diff.PageTop)"
        Assert-Pinned $diff.BarVisible 'E: the bar is on screen with no hover at all'
        Assert ($diff.Bar.Top -eq $diff.Host.Top) 'E: the bar sits at the top of its pane'
    }
    Invoke-Verb @('+close', '--target=vpE') | Out-Null

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
