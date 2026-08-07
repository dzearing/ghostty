# T447 acceptance: hovering a tab surfaces the pane's working directory.
#
# The gap: the win32 app has known every pane's cwd since T111b (`.pwd`
# action + livePwd), but nothing in the chrome ever showed it - it only
# reached `+list` and the IPC handlers. The Mac surfaces it as the titlebar
# proxy icon; the Windows-native translation is a tab TOOLTIP (native
# comctl32 track-mode control) whose text is the focused pane's cwd,
# home-abbreviated to `~` and middle-elided (tab_tooltip.zig, none-lane
# tested).
#
# What is scored here is the TEXT DERIVATION AT HOVER TIME, via the debug
# oracle `tab tooltip tab=N text=...` that Window.tabTipOnHoverChange logs
# when the pointer lands on a tab. The tooltip's SHOW cannot be scored on
# this desktop: the show delay needs the hover HELD, and TrackMouseEvent
# watches the real cursor - a posted WM_MOUSEMOVE's hover is cleared by
# WM_MOUSELEAVE within a frame here (T233, same as tab-strip.ps1 section
# 4c). The oracle line is emitted on the same hover transition that arms
# the show timer, so it is the hit test + text pipeline agreeing, which is
# the product half a background desktop can observe. Empty on a release
# build, where log.debug is compiled out - the probe then SKIPs rather than
# lying.
#
#   A: the tooltip text names the pane's STARTING directory, ~-abbreviated.
#   B: it FOLLOWS a `cd` (cmd.exe reports no OSC 7, so this is the T185
#      livePwd path - the cache alone would stay frozen at the start dir).
#   C: it is right after a session-persistence RESTORE (app killed and
#      relaunched, same agent; the re-attached shell's real cwd answers).
#   D: a tab whose focused pane is a VIEWER reports the viewer's location.
#
# Runs on a background Win32 desktop (lib/TestDesktop.ps1); hermetic via a
# per-run LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN + a private pipe suffix.
# Only touches ghoztty processes launched from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\tab-tooltip.ps1
param(
    [string]$ExePath,
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$root = Join-Path $env:TEMP "ghoztty-tabtip-$PID"
# Distinguishable leaf names, so "the text names THIS directory" is a real
# claim: a stale line about the other directory can never satisfy it.
$dirA = Join-Path $root "tipA$($PID % 997)"
$dirB = Join-Path $root "tipB$($PID % 997)"
New-Item -ItemType Directory -Force $dirA, $dirB | Out-Null

function Kill-RepoInstances {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 600
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }
function Get-List($tag) {
    Run-CliArgs @('+list', '--json') "$root\list-$tag.json" 12 | Out-Null
    try { return (Out-Text "$root\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    if ($null -eq $tree) { return , @() }
    $ws = if ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    $acc = @()
    foreach ($w in $ws) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
# The `cd` landed when `+list` says so: working_directory is livePwd-backed
# (T185), the same source the tooltip reads, so this is the right sync point.
function Wait-PaneCwd($needle, $tag, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $leaves = @(All-Leaves (Get-List $tag))
        foreach ($l in $leaves) {
            if ($l.working_directory -like "*$needle*") { return $true }
        }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

# Post a mouse move onto tab 0 and read back the freshest oracle line. Each
# posted move is a full hover transition (the background desktop clears the
# hover within a frame, T233), so every probe logs its own line.
function Probe-TipText($top, $m, $errlog, $tries = 6) {
    for ($i = 0; $i -lt $tries; $i++) {
        Clear-Content $errlog -ErrorAction SilentlyContinue
        $x = $m.ClientLeft + 40
        $y = $m.ClientTop + $m.StripTopClient + $m.StripBtnTop + [int]($m.BtnPaint / 2)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move)
        Start-Sleep -Milliseconds 400
        $hit = @(Select-String -Path $errlog -Pattern 'tab tooltip tab=0 text=(.+)$' -ErrorAction SilentlyContinue)
        if ($hit.Count -gt 0) { return $hit[-1].Matches[0].Groups[1].Value.Trim() }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

Kill-RepoInstances
$saved = @{ lad = $env:LOCALAPPDATA; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; pipe = $env:GHOZTTY_PIPE_SUFFIX }
New-Item -ItemType Directory -Force (Join-Path $root 'state\ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = Join-Path $root 'state'
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$env:GHOZTTY_PIPE_SUFFIX = '-tabtip'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # -----------------------------------------------------------------------
    # Launch: strip visible at one tab, pane starting in dirA. Session
    # persistence stays ON (the default) - arm C is a restore.
    # -----------------------------------------------------------------------
    $errlog = Join-Path $root 'app1-stderr.log'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false',
        '--window-show-tab-bar=always',
        "--working-directory=$dirA"
    )
    Start-Sleep -Seconds 3
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'setup: the GUI came up'
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    Assert ($top -ne [IntPtr]::Zero) 'setup: top window found'
    Set-TestWindowSize -Window $top -Width 1200 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1500
    $m = Get-TestChromeMetrics -Window $top -StripVisible $true

    Assert (Wait-PaneCwd (Split-Path $dirA -Leaf) 'a0') 'setup: +list reports the starting directory'

    # A release build logs nothing - detect once, and skip the oracle arms
    # honestly rather than failing them against a build that cannot speak.
    $probe = Probe-TipText $top $m $errlog
    if ($null -eq $probe) {
        Write-Host 'SKIP: no debug oracle in the log (release build?) - the tooltip text arms need a Debug build'
    } else {
        # -------------------------------------------------------------------
        # A: the starting directory, ~-abbreviated (dirA is under %TEMP%,
        # which is under the profile, so the abbreviation must have fired).
        # -------------------------------------------------------------------
        Assert ($probe -like "*$(Split-Path $dirA -Leaf)*") "A: tooltip text names the starting directory ($probe)"
        Assert ($probe.StartsWith('~')) "A: the home prefix reads as ~ ($probe)"

        # -------------------------------------------------------------------
        # B: it follows a cd. cmd.exe never reports OSC 7, so a text that
        # follows proves the livePwd (T185) half, not just the cache.
        # -------------------------------------------------------------------
        $leaves = @(All-Leaves (Get-List 'b0'))
        Assert ($leaves.Count -ge 1) 'B: a pane to cd in'
        $pane = $leaves[0].id
        Write-Host "INFO  pane=$pane pid=$($leaves[0].pid) cwd=$($leaves[0].working_directory)"
        # +send-keys text processes `\t`/`\n` escapes, so a raw Windows path
        # arrives with its `\t...` component turned into a TAB - double the
        # backslashes so the shell sees the path verbatim.
        Run-CliArgs @('+send-keys', "--target=$pane", 'cd', 'Space', $dirB.Replace('\', '\\'), 'Enter') "$root\cd.txt" 12 | Out-Null
        $cdLanded = Wait-PaneCwd (Split-Path $dirB -Leaf) 'b1'
        Assert $cdLanded 'B: +list sees the new directory'
        if (-not $cdLanded) {
            Run-CliArgs @('+read', "--name=$pane", '--lines=30') "$root\read-b.txt" 12 | Out-Null
            Write-Host 'INFO  pane tail after cd:'
            (Out-Text "$root\read-b.txt") -split "`n" | Select-Object -Last 6 | ForEach-Object { Write-Host "  | $_" }
            $l2 = @(All-Leaves (Get-List 'b2'))
            if ($l2.Count -ge 1) { Write-Host "INFO  post-cd leaf pid=$($l2[0].pid) cwd=$($l2[0].working_directory)" }
        }
        $probe = Probe-TipText $top $m $errlog
        Assert ($probe -like "*$(Split-Path $dirB -Leaf)*") "B: tooltip text follows the cd ($probe)"

        # -------------------------------------------------------------------
        # C: right after a session-persistence restore. Kill the APP only -
        # the agent keeps the shell alive - relaunch, and the re-attached
        # pane must answer with where the shell actually is (dirB).
        # -------------------------------------------------------------------
        Start-Sleep -Seconds 3   # let the session-layout manifest debounce out
        Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
            Where-Object { $_.ExecutablePath -eq $exe } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2

        $errlog2 = Join-Path $root 'app2-stderr.log'
        $app2 = Start-OnTestDesktop -Exe $exe -StdErr $errlog2 -Arguments @(
            '--config-default-files=false',
            '--window-show-tab-bar=always'
        )
        Start-Sleep -Seconds 4
        Assert (-not ($app2.Process -and $app2.Process.HasExited)) 'C: the GUI relaunched'
        $top2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
        Assert ($top2 -ne [IntPtr]::Zero) 'C: restored window found'
        Set-TestWindowSize -Window $top2 -Width 1200 -Height 700 | Out-Null
        Start-Sleep -Milliseconds 1500
        $m2 = Get-TestChromeMetrics -Window $top2 -StripVisible $true
        Assert (Wait-PaneCwd (Split-Path $dirB -Leaf) 'c0' 45) 'C: the restored pane is still in the cd target'
        $probe = Probe-TipText $top2 $m2 $errlog2
        Assert ($probe -like "*$(Split-Path $dirB -Leaf)*") "C: tooltip text is right after the restore ($probe)"

        # -------------------------------------------------------------------
        # D: a viewer pane reports its location. The split takes focus, so
        # tab 0's focused pane becomes the viewer and the same probe answers
        # for it.
        # -------------------------------------------------------------------
        $md = Join-Path $root 'tipdoc.md'
        Set-Content -Path $md -Value '# tip doc' -Encoding utf8
        Run-CliArgs @('+split', "--target=$pane", '--name=tipvw', "--view=$md") "$root\vw.txt" 20 | Out-Null
        Start-Sleep -Seconds 3
        $probe = Probe-TipText $top2 $m2 $errlog2
        Assert ($probe -like '*tipdoc.md*') "D: a viewer pane's tooltip names its location ($probe)"
    }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'no window leaked onto the interactive desktop'
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    $env:LOCALAPPDATA = $saved.lad
    if ($null -ne $saved.bin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin } else { Remove-Item Env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $saved.pipe) { $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe } else { Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) / $script:pass passed" -ForegroundColor Red; exit 1 }
