# T163 acceptance: a `window.open()` popup becomes a real ghoztty window.
#
# Before T163 every popup was handed to the default browser, unconditionally.
# That is still the right answer for an http(s) URL -- Ghoztty's WebView2 keeps
# its own cookie store, so an authenticated site opened here renders logged out
# -- but it is the WRONG answer for the two popups a browser cannot be handed:
# a bare `window.open()` with no URL, where the script goes on to write into the
# window it was given, and a non-web scheme. Those now become their own ghoztty
# window whose single viewer pane IS the popup.
#
# What is asserted, from OUTSIDE the app:
#
#   A. setup: the opener window comes up on a page served from loopback, and it
#      is the only window. The positive control for every count below.
#   B. a second window appears with exactly one pane, `"type":"viewer"`, at
#      `about:blank` -- the popup was ADOPTED, not shelled out to a browser.
#   C. that pane's title is what the OPENER wrote through the handle
#      `window.open()` returned. This is the load-bearing claim: the write can
#      only land here if this pane is the window the runtime handed the script,
#      which is what `put_NewWindow` + a deferral buy. A pane we had merely
#      opened at the same location would be a different window, the write would
#      go nowhere, and this title would stay `about:blank`.
#   D. the popup window honors the size the opener asked for
#      (`width=520,height=680`): it is PORTRAIT and clearly smaller than the
#      opener. Deliberately non-square, because `ICoreWebView2WindowFeatures`
#      puts `Height` before `Width` in its vtable and a square request could not
#      tell a swapped pair from a correct one. A window that ignored the request
#      outright is landscape at the ordinary default, so this one assertion
#      catches both failures.
#   E. `window.close()` from the opener closes the popup window and nothing
#      else: the popup is gone from `+list --json` and the opener is still
#      there with its pane. This is `add_WindowCloseRequested` wired all the way
#      through to the pane's close.
#
# What is NOT asserted here, on purpose: the DEFAULT-BROWSER leg. Exercising it
# from a test lane would launch the user's real browser over a green run. It is
# covered in the win32 unit lane instead, by the live test "T163: a popup is
# adopted as a pane, sized, and can close itself" (ViewerPane.zig), whose last
# section routes an http popup through a link sink and asserts `browser:<url>`.
#
# The popup is driven by a page on a raw-TCP loopback server (viewer-panes.ps1's
# shape -- no HttpListener URL-ACL to register). The close is script-driven
# rather than timed: the opener polls `/gate` and only calls `close()` once this
# script drops a flag file, so C and D are read from a window that is still
# there rather than raced against a timer.
#
# Hermetic: per-run LOCALAPPDATA, a private IPC pipe suffix, and it only ever
# kills ghoztty processes launched from this repo's zig-out. Runs on the
# BACKGROUND test desktop, so it never takes the user's foreground.
#
#   powershell -NoProfile -File test\win32\viewer-popup.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-viewer-popup-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700)
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Windows {
    $data = Get-Data
    if (-not $data) { return @() }
    return @($data.windows)
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-WinLeaves($w) {
    if ($null -eq $w) { return @() }
    return @(Get-Leaves $w.tabs[0].splits)
}

# The one window that was not already open. `$script:knownTargets` is snapshotted
# AFTER the opener comes up, which is what keeps the app's own startup window out
# of the answer -- a launch opens `window-1` with a shell in it, and a naive
# "the window that is not the opener" picks THAT and reports the popup as a
# terminal running cmd.exe.
$script:knownTargets = @()
function Get-PopupWin {
    foreach ($w in Get-Windows) {
        if ($script:knownTargets -notcontains [string]$w.target) { return $w }
    }
    return $null
}

function Wait-For($pred, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $pred) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# ---- the popup page server --------------------------------------------------
# Two routes. `/opener.html` opens the popup on load and writes a document into
# the handle it got back; `/gate` answers `wait` until this script drops the
# flag file, then `close`, which is what makes the close deterministic.
$ppPort = 47163
$ppGate = Join-Path $env:TEMP "ghoztty-popup-gate-$PID.flag"
Remove-Item $ppGate -ErrorAction SilentlyContinue
$ppUrl = "http://127.0.0.1:$ppPort/opener.html"
$popupTitle = 't163-adopted'
$wantW = 520
$wantH = 680

$script:ppJob = Start-Job -ScriptBlock {
    param($port, $gate, $title, $w, $h)
    $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>t163-opener</title></head>
<body>opener
<script>
window.addEventListener("load", function () {
  window.__w = window.open("", "t163pop", "width=$w,height=$h");
  if (window.__w) {
    window.__w.document.write("<!doctype html><title>$title</title><body>popup");
    window.__w.document.close();
  }
  setInterval(function () {
    fetch("/gate?" + Date.now()).then(function (r) { return r.text(); })
      .then(function (t) {
        if (t.indexOf("close") === 0 && window.__w) { window.__w.close(); }
      }).catch(function () {});
  }, 500);
});
</script>
</body></html>
"@
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 50
            $buf = New-Object byte[] 8192
            $req = ''
            while ($stream.DataAvailable) {
                $r = $stream.Read($buf, 0, $buf.Length)
                if ($r -le 0) { break }
                $req += [Text.Encoding]::UTF8.GetString($buf, 0, $r)
            }
            $line = ($req -split "`r`n")[0]
            if ($line -match '^GET ') {
                $body = $html
                $ctype = 'text/html'
                if ($line -match '^GET /gate') {
                    $ctype = 'text/plain'
                    $body = if (Test-Path $gate) { 'close' } else { 'wait' }
                }
                $payload = [Text.Encoding]::UTF8.GetBytes($body)
                $head = "HTTP/1.1 200 OK`r`nContent-Type: $ctype`r`nCache-Control: no-store`r`n" +
                    "Content-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
                $out = [Text.Encoding]::UTF8.GetBytes($head) + $payload
                $stream.Write($out, 0, $out.Length)
                $stream.Flush()
            }
        } catch {}
        $client.Close()
    }
} -ArgumentList $ppPort, $ppGate, $popupTitle, $wantW, $wantH

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = '-vpopup'

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'

    # persistence: off - this script counts WINDOWS, and a restore of whatever
    # the last run left would make every count wrong.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # Wait for the server to answer before pointing a pane at it, so a slow job
    # start does not read as a viewer that failed to load.
    $listening = Wait-For {
        try {
            $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $ppPort)
            $c.Close(); return $true
        } catch { return $false }
    } 30
    Assert $listening 'the popup page server is listening'

    # ---- A: the opener, and nothing else ------------------------------------
    Say '== A: the opener window'
    $r = Invoke-Verb @('+new-window', '--target=opener', "--view=$ppUrl")
    Assert ($r.Code -eq 0) "+new-window --view=<opener page> exits 0 (got $($r.Code))"

    $up = Wait-For { (@(Get-WinLeaves (@(Get-Windows) | Where-Object { $_.target -eq 'opener' })[0])).Count -eq 1 } 30
    Assert $up 'the opener window came up with one pane'

    # Everything open BEFORE the popup: the app's own startup window and the
    # opener. Anything past this set is the popup and nothing else.
    $script:knownTargets = @(@(Get-Windows) | ForEach-Object { [string]$_.target })
    Assert ($script:knownTargets -contains 'opener') 'the opener is registered under its target name'
    Say "   known windows: $($script:knownTargets -join ', ')"

    # ---- B: the popup became a window of its own ----------------------------
    Say '== B: the popup is adopted'
    $appeared = Wait-For { $null -ne (Get-PopupWin) } 40
    Assert $appeared 'a second window appeared for the popup (it was NOT handed to the browser)'

    $popup = Get-PopupWin
    $pleaves = @(Get-WinLeaves $popup)
    Assert ($pleaves.Count -eq 1) "the popup window has exactly one pane (got $($pleaves.Count))"
    Assert ($pleaves.Count -ge 1 -and $pleaves[0].type -eq 'viewer') `
        "the popup's pane is a viewer (got '$(if ($pleaves.Count -ge 1) { $pleaves[0].type } else { 'none' })')"
    Assert ($pleaves.Count -ge 1 -and $pleaves[0].url -eq 'about:blank') `
        "the popup pane is at about:blank (got '$(if ($pleaves.Count -ge 1) { $pleaves[0].url } else { '' })')"

    # ---- C: the opener wrote INTO that pane ---------------------------------
    Say '== C: the opener owns the popup'
    $titled = Wait-For {
        $p = Get-PopupWin
        if ($null -eq $p) { return $false }
        $l = @(Get-WinLeaves $p)
        return ($l.Count -ge 1 -and $l[0].title -eq $popupTitle)
    } 40
    $popup = Get-PopupWin
    $pleaves = @(Get-WinLeaves $popup)
    $gotTitle = if ($pleaves.Count -ge 1) { [string]$pleaves[0].title } else { '' }
    Assert $titled `
        "what the opener wrote through its window.open() handle landed in the popup pane (title '$gotTitle', wanted '$popupTitle')"

    # ---- D: the size the opener asked for ------------------------------------
    Say '== D: the requested size'
    $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')
    $popHwnd = [IntPtr]::Zero
    $openerHwnd = [IntPtr]::Zero
    foreach ($t in $tops) {
        $txt = [string](Get-TestWindowText -Window ([IntPtr]$t.Hwnd))
        if ($txt -like "*$popupTitle*") { $popHwnd = [IntPtr]$t.Hwnd }
        elseif ($txt -like '*t163-opener*') { $openerHwnd = [IntPtr]$t.Hwnd }
    }
    Assert ($popHwnd -ne [IntPtr]::Zero) 'the popup window is findable by its title on the test desktop'
    Assert ($openerHwnd -ne [IntPtr]::Zero) 'the opener window is findable by its title (control for the pair)'
    if ($popHwnd -ne [IntPtr]::Zero -and $openerHwnd -ne [IntPtr]::Zero) {
        $pr = Get-TestWindowRect -Window $popHwnd
        $orct = Get-TestWindowRect -Window $openerHwnd
        # PORTRAIT: the request was 520x680. A swapped Height/Width pair, or a
        # request ignored in favor of the ordinary default, is landscape.
        Assert ($pr.Height -gt $pr.Width) `
            "the popup window is portrait, as asked ($($pr.Width)x$($pr.Height))"
        Assert ($pr.Width -lt $orct.Width) `
            "the popup window is narrower than the opener ($($pr.Width) < $($orct.Width))"
    }

    # ---- E: window.close() closes it, and only it ---------------------------
    Say '== E: window.close()'
    Set-Content -Path $ppGate -Value 'close' -Encoding ascii
    $gone = Wait-For { $null -eq (Get-PopupWin) } 40
    Assert $gone 'window.close() from the opener closed the popup window'

    $openerStill = @(Get-Windows) | Where-Object { $_.target -eq 'opener' }
    Assert ($null -ne $openerStill) 'the opener window is still open (the close took only the popup)'
    if ($null -ne $openerStill) {
        Assert ((@(Get-WinLeaves $openerStill[0])).Count -eq 1) 'the opener still has its pane'
    }
} finally {
    Remove-Item $ppGate -ErrorAction SilentlyContinue
    if ($script:ppJob) {
        Stop-Job $script:ppJob -ErrorAction SilentlyContinue
        Remove-Job $script:ppJob -Force -ErrorAction SilentlyContinue
    }
    Stop-RepoInstances
    if ($td) { Remove-TestDesktop -Desktop $td }
    # The watcher's samples are an assertion, not console noise: nothing this
    # script launched may ever have taken the INTERACTIVE desktop's foreground.
    # Read after the cleanup, against the all-time launch list (the live one is
    # empty by now, which would score an assertion that checked nothing).
    $fgSeen = @(Stop-TestForegroundWatch)
    if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
        $launched = @(Get-TestLaunchedPids)
        Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
        Assert ((@($launched | Where-Object { $fgSeen -contains $_ })).Count -eq 0) `
            'Z2 no test-desktop app ever became foreground on the interactive desktop'
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) of $($script:pass + $script:fail)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
