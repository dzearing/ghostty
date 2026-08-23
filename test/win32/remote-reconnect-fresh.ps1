# T611 acceptance: clicking Reconnect on a machine whose SESSIONS are gone must
# give the user a working window back, not a dead one.
#
# The case this is about is the ordinary one: a window is running shells on
# another machine, that machine reboots (or its agent restarts), and the pill
# offers Reconnect. The machine is plainly back - the dial succeeds and the
# agent answers - but the shells that were running on it are gone with the
# reboot. Until T611 the driver read that as terminal and left the window dead,
# so the one button whose whole job is "get me back in" answered no in the most
# common real case.
#
# The arms, in the order they are scored:
#
#   C  CONTROL. A remote window with a SPLIT (two panes) comes up over the
#      loopback agent and both panes are LIVE - typed input reaches the child
#      and its output comes back. Scored first and deliberately: without it,
#      arm B proves nothing, because a build that could not open a remote pane
#      at all would leave the same two-pane shape behind.
#   A  AUTOMATIC. The agent is killed and restarted, so the ladder's own retry
#      reaches an agent that owns nothing. It must go TERMINAL and must NOT
#      open fresh shells: replacing a grid the user arranged with empty prompts
#      is only ever allowed when they asked for it.
#   B  MANUAL. The Reconnect button is clicked (the WM_NCLBUTTONDOWN/UP pair
#      Windows posts on HTOBJECT after its own hit test - the handler reads the
#      hit code, not the point, which is what lets this be posted). The window
#      must come back: the SAME split layout, the SAME pane ids, and both panes
#      LIVE on the new transport. Liveness is the load-bearing half - a pane
#      rebuilt as a frozen picture is byte-identical to a working one for every
#      assertion that reads the screen (T532/T652).
#
# TEETH-CHECK: re-run with
#     $env:GHOZTTY_TEST_LIVENESS_BREAK = '1'
# and every Test-PaneLive arm here goes red and nothing else moves.
#
# Runs on a background test desktop with its own pipe suffix and its own agent
# lock, and only ever touches ghoztty processes it started itself.
#
#   powershell -NoProfile -File test\win32\remote-reconnect-fresh.ps1
param(
    [string]$ExePath,
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 47917
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-remfreshtest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

# T1127: the finally below kills the agent it started, and the agent's
# `--pty-host` holders survive that by design - they own the ConPTY and escape
# the job on purpose. This run left TWO of them behind on every pass. Arm the
# build-scoped teardown so nothing from zig-out outlives the script.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Check([bool]$cond, [string]$msg) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $msg" }
    else { $script:fail++; Write-Host "  FAIL  $msg" }
}

$HTOBJECT = 19
$WM_NCLBUTTONDOWN = 0x00A1; $WM_NCLBUTTONUP = 0x00A2
function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}

$tmp = Join-Path $env:TEMP "ghoztty-remfresh-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# The CONSOLE twin (T245), and it is load-bearing here rather than stylistic:
# `cmd /c "gui.exe > file"` does not WAIT for a GUI-subsystem process, so a
# single-shot read of the redirect file races the CLI and comes back empty. The
# `.com` is the same binary with a console subsystem, so cmd waits for it and
# the file is complete when the wait returns.
$cli = [IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $cli)) { $cli = $exe }

function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$cli`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # BEFORE any wait, or ExitCode reads empty (ExitCodeAudit)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } else { return '' } }

function Get-Tree([string]$tag) {
    Run-Cli '+list --json' "$tmp\list-$tag.json" 15 | Out-Null
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
# NO leading `,` on these returns. `return ,@(a,b)` hands the caller ONE object
# that happens to be an array, so `foreach ($w in Windows-Of $t)` iterates once
# with $w bound to the whole array - and `$w.target` then member-enumerates into
# "window-1 rw", which reads exactly like a window with a two-word name. The
# comma idiom protects a ONE-element array from unrolling; here it is the bug.
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Window-Named($tree, [string]$name) {
    foreach ($w in Windows-Of $tree) { if ([string]$w.target -eq $name) { return $w } }
    return $null
}
# Every terminal leaf of a window, in tree order, as @{ id; } - plus the shape
# of the split above them, which is what "the layout survived" means.
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Window-Leaves($w) {
    $acc = @()
    if ($null -eq $w) { return $acc }
    foreach ($t in @($w.tabs)) { $acc += @(Leaves-Of $t.splits) }
    return $acc
}
# Every leaf carries its pane under `terminal`, viewers included (the KIND is
# `terminal.type`) - see `apprt.ipc.List.Node`.
function Leaf-Id($leaf) {
    if ($null -ne $leaf.terminal) { return [string]$leaf.terminal.id }
    return ''
}
# The one number that says the split itself came back: the root node's kind,
# its direction and its ratio.
function Window-Shape($w) {
    if ($null -eq $w) { return '(none)' }
    $t = @($w.tabs)[0]
    if ($null -eq $t) { return '(no tabs)' }
    $s = $t.splits
    if ($null -eq $s) { return '(no splits)' }
    if ($s.type -ne 'split') { return "leaf" }
    return "split:$($s.direction):$([math]::Round([double]$s.ratio, 2))"
}

function Log-Has([string]$pattern) {
    if (-not (Test-Path $applog)) { return $false }
    return (@(Get-Content $applog -ErrorAction SilentlyContinue | Select-String -Pattern $pattern).Count -gt 0)
}
function Wait-Log([string]$pattern, [int]$timeoutSec) {
    for ($i = 0; $i -lt $timeoutSec; $i++) {
        if (Log-Has $pattern) { return $i }
        Start-Sleep -Seconds 1
    }
    return -1
}

New-TestDesktop | Out-Null
$agent = $null
$exitCode = 1
try {
    Write-Host "T611 fresh-session reconnect acceptance"
    Write-Host "  exe:   $exe"
    Write-Host "  agent: $AgentExe"

    # A loopback agent to be remote TO, with its own lock path so it can never
    # fight a real agent's single-instance guard.
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent1.lock'
    $agent = Start-Process -FilePath $AgentExe -ArgumentList '--listen', "127.0.0.1:$Port", '--headless' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if ($agent.HasExited) { throw 'SETUP FAIL: loopback agent exited immediately' }

    $applog = Join-Path $tmp 'app.log'
    $proc = Start-OnTestDesktop -Exe $exe -StdErr $applog -Arguments @(
        '--config-default-files=false',
        # `false`, not `off`: the bool parser takes true/false only (T137). The
        # subject is a CROSS-MACHINE window, whose panes ride the dialed
        # transport - local session persistence would only add a restore this
        # script never asked for.
        '--session-persistence=false',
        '--background=#000000'
    )
    $home_ = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($home_ -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 1500

    $before = @(Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })

    $rc = Run-Cli "+new-remote-window --name=rw --host=127.0.0.1 --port=$Port" "$tmp\open.txt"
    if ($rc -ne 0) { throw "SETUP FAIL: +new-remote-window exit $rc - $(Out-Text "$tmp\open.txt")" }
    Start-Sleep -Seconds 3

    $remote = [IntPtr]::Zero
    foreach ($w in (Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyWindow')) {
        if ($before -contains $w.Hwnd) { continue }
        $remote = [IntPtr]$w.Hwnd
    }
    if ($remote -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no remote GhozttyWindow appeared' }

    # --- C. control: a two-pane remote window, both panes live --------------
    $rc = Run-Cli '+split --target=rw --name=rp2 --direction=right' "$tmp\split.txt"
    if ($rc -ne 0) { throw "SETUP FAIL: +split exit $rc - $(Out-Text "$tmp\split.txt")" }
    Start-Sleep -Seconds 3

    $w0 = Window-Named (Get-Tree 'c') 'rw'
    $ids0 = @(@(Window-Leaves $w0) | ForEach-Object { Leaf-Id $_ })
    $shape0 = Window-Shape $w0
    Write-Host "  before: shape=$shape0 panes=$($ids0.Count) [$($ids0 -join ', ')]"
    Check ($ids0.Count -eq 2) "C1 the remote window has two panes before the drop"
    Check ($shape0 -like 'split:*') "C2 and they sit in a split ($shape0)"
    if ($ids0.Count -eq 2) {
        Check (Test-PaneLive -Exe $exe -Target $ids0[0] -Tmp $tmp -Tag 'C1') `
            "C3 the first remote pane is LIVE before the drop"
        Check (Test-PaneLive -Exe $exe -Target $ids0[1] -Tmp $tmp -Tag 'C2') `
            "C4 the second remote pane is LIVE before the drop"
    } else {
        Check $false "C3/C4 skipped: the two-pane control never came up"
    }

    # --- A. automatic: the ladder's own retry must NOT open fresh shells ----
    # Kill the agent and bring it straight back. The window's fast ladder is
    # already counting out its 1s backoff, so its own next attempt reaches an
    # agent that answers and owns nothing - `session_gone` on an AUTOMATIC
    # attempt, which is the arm that must stay terminal.
    Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
    $agent = $null
    Start-Sleep -Milliseconds 500
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent2.lock'
    $agent = Start-Process -FilePath $AgentExe -ArgumentList '--listen', "127.0.0.1:$Port", '--headless' -PassThru -WindowStyle Hidden

    $termAt = Wait-Log 'remote reconnect:.*(is terminal after attempt|terminally disconnected)' 90
    Check ($termAt -ge 0) "A1 an AUTOMATIC re-dial against an agent that owns nothing goes terminal (after ${termAt}s)"
    Check (-not (Log-Has 'opened fresh')) `
        "A2 and it opens NO fresh shells - a grid nobody asked to replace is left alone"

    # --- B. manual: the click brings the window back ------------------------
    # The pair Windows itself posts once its hit test has answered HTOBJECT.
    # `handleNcLButtonUp` reads the hit CODE out of wparam and never the point,
    # so this is the whole gesture as far as the app is concerned; that the OS
    # would really route a pointer here is remote-pill.ps1 section 3's job.
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONDOWN -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 150
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONUP -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null

    $freshAt = Wait-Log 'opened fresh' 45
    Check ($freshAt -ge 0) "B1 clicking Reconnect opens a fresh shell per pane (after ${freshAt}s)"
    if ($freshAt -lt 0 -and (Test-Path $applog)) {
        Write-Host "  -- app log, remote reconnect lines --"
        Get-Content $applog | Select-String -Pattern 'remote reconnect' | Select-Object -Last 12 | ForEach-Object { "    $($_.Line)" }
    }
    Start-Sleep -Seconds 2

    $w1 = Window-Named (Get-Tree 'b') 'rw'
    $ids1 = @(@(Window-Leaves $w1) | ForEach-Object { Leaf-Id $_ })
    $shape1 = Window-Shape $w1
    Write-Host "  after:  shape=$shape1 panes=$($ids1.Count) [$($ids1 -join ', ')]"
    Check ($ids1.Count -eq 2) "B2 the window still has both panes after the swap"
    Check ($shape1 -eq $shape0) "B3 and the SPLIT LAYOUT is the one the user arranged ($shape1)"
    Check (($ids0.Count -eq 2) -and ($ids1.Count -eq 2) -and
           ($ids0[0] -eq $ids1[0]) -and ($ids0[1] -eq $ids1[1])) `
        "B4 every pane keeps its own pane id across the fresh-session swap"

    if ($ids1.Count -eq 2) {
        Check (Test-PaneLive -Exe $exe -Target $ids1[0] -Tmp $tmp -Tag 'B1') `
            "B5 the first pane is LIVE on the new transport - a fresh shell, not a picture"
        Check (Test-PaneLive -Exe $exe -Target $ids1[1] -Tmp $tmp -Tag 'B2') `
            "B6 the second pane is LIVE on the new transport"
    } else {
        Check $false "B5/B6 skipped: the window did not come back with two panes"
    }

    Write-Host ""
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($($script:pass) checks$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
        $exitCode = 0
    } else {
        Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
        $exitCode = 1
    }
} catch {
    Write-Host "  FAIL  $($_.Exception.Message)"
    Write-Host "1 FAILURE(S)"
    $exitCode = 1
} finally {
    if ($null -ne $agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop | Out-Null
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
exit $exitCode
