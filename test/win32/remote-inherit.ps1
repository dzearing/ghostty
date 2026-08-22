# Remote-inheritance acceptance (tracker T68): --from-focused + New Window /
# split / tab on a remote window reuse the remote host, against a debug build
# + a loopback ghoztty-agent. Only ever touches ghoztty processes running from
# the repo zig-out.
#
#   powershell -NoProfile -File test\win32\remote-inherit.ps1
#
# Covers: +split --from-focused inherits the parent pane's LIVE cwd through
# the agent (GET_CWD), +split --target on a remote window opens a REMOTE
# session with a remote-native --command (never a local ConPTY pane), ctrl+t
# (new tab keybind) inherits the active pane's command, +new-window
# --from-focused dials the SAME agent (second TCP connection) and inherits,
# --from-focused with a local parent falls through to a local window, and a
# dead agent surfaces the reach error instead of a silent local window.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone. Three notes:
#
#   * The GUI is launched EXPLICITLY onto the test desktop. It used to be
#     auto-spawned by the first `+new-window`, which puts the window on the
#     USER's desktop - the whole thing being fixed.
#   * The ctrl+t chord goes to the ACTIVE SURFACE, found via
#     Get-TestFocusedWindow. Posting it to the window itself would be lost:
#     GhozttyWindow hands WM_KEYDOWN to DefWindowProc and only forwards
#     FOCUS to the active pane (Window.zig WM_SETFOCUS). SendInput used to
#     hide that by following focus on its own.
#   * A background desktop has no foreground window at all, so the app's
#     `--from-focused` resolution takes its documented headless fallback (the
#     last-created window). The sections below are ordered so that fallback
#     names the window each one means.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 47911,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-remote-inherit-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# Isolate the IPC endpoint (inherited through CreateProcessW) so this run's
# +verbs reach THIS instance and not whatever answers the shared pipe.
$env:GHOZTTY_PIPE_SUFFIX = "-reminherit$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Same app+agent kill as before, but exact-exe (a '*zig-out*' CommandLine
# match also catches a detached zig-out-release instance, T53b) and with the
# debug session-layout manifest dropped, which the private copy never did.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

function Get-ListJson {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    Get-Content "$tmp\list.json" -Raw
}

function Get-PaneNames {
    # Leaf terminals carry "name"; windows carry "target" - a flat regex on
    # "name" yields exactly the pane names.
    $json = Get-ListJson
    $names = @()
    foreach ($m in [regex]::Matches($json, '"name":"([^"]*)"')) {
        if ($m.Groups[1].Value -ne '') { $names += $m.Groups[1].Value }
    }
    $names
}

# HWND of a named window. `+list --json` reports each window's id as its hwnd
# (IpcHandlers.zig), which is how a script addresses a SPECIFIC window instead
# of trusting z-order enumeration.
function Get-WindowHwnd([string]$target) {
    $raw = Get-ListJson
    try { $j = $raw | ConvertFrom-Json } catch { return [IntPtr]::Zero }
    $w = @($j.data.windows | Where-Object { $_.target -eq $target })
    if ($w.Count -eq 0) { return [IntPtr]::Zero }
    return [IntPtr][int64]$w[0].id
}

function Read-Pane($name, $outfile) {
    cmd /c "`"$Exe`" +read --name=$name --lines=40 > `"$tmp\$outfile`" 2>&1" | Out-Null
    Get-Content "$tmp\$outfile" -Raw
}

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Marker directories: cwd inheritance is the remote-vs-local oracle. Only a
    # pane that inherited through the agent can start in these (cmd.exe has no
    # OSC 7, so there is no local cwd-inherit path to confuse the result).
    $root = Join-Path $tmp 't68-root'
    $sub = Join-Path $root 't68-sub'
    New-Item -ItemType Directory -Force $sub | Out-Null

    "== 0: start a loopback agent + a base window"
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $agent = Start-OnTestDesktop -Exe $AgentExe -Arguments @('--listen', "127.0.0.1:$Port", '--headless')
    Start-Sleep -Seconds 2
    Assert "agent is running" (-not ($agent.Process -and $agent.Process.HasExited))

    # The GUI is started HERE rather than being auto-spawned by +new-window:
    # auto-spawn would land it on the user's desktop. --session-persistence=false
    # keeps a restored layout manifest from adding panes this run did not open.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    Assert "GUI is running" (-not ($app.Process -and $app.Process.HasExited))
    $win0 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Assert "GUI window is up" ($win0 -ne [IntPtr]::Zero)
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    & $Exe +new-window --target=rembase 2>&1 | Out-Null
    Assert "base window exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 2
    $basePanes = @(Get-PaneNames)

    "== 1: open a remote window rooted in the marker dir"
    cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$Port --name=rem `"--working-directory=$root`" > `"$tmp\open.txt`" 2>&1"
    Assert "open exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $before = @(Get-PaneNames)
    # The launch window exists before rembase, so base state is already >1
    # pane; assert the delta, not an absolute count.
    Assert "one new pane listed for the remote window" ($before.Count -eq ($basePanes.Count + 1))
    $remPane = @($before | Where-Object { $basePanes -notcontains $_ })
    Assert "remote pane discovered" ($remPane.Count -eq 1)
    $dump = Read-Pane $remPane[0] 'read-parent.txt'
    Assert "remote pane starts in marker root" ($dump -like "*t68-root*")

    "== 2: cd the parent, +split --from-focused inherits the LIVE cwd"
    & $Exe +send-keys --target=rem "cd t68-sub" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    cmd /c "`"$Exe`" +split --from-focused --direction=right > `"$tmp\split1.txt`" 2>&1"
    Assert "split --from-focused exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $names = @(Get-PaneNames)
    Assert "one new pane after split" ($names.Count -eq ($before.Count + 1))
    $newPane = @($names | Where-Object { $before -notcontains $_ })
    Assert "new pane discovered" ($newPane.Count -eq 1)
    $dump = Read-Pane $newPane[0] 'read-split1.txt'
    # -NegativeControl inverts this one - the live-cwd inheritance is the
    # script's strongest remote-vs-local oracle AND it currently passes, so
    # inverting it proves the assertion discriminates. (Do not put the control
    # on a section-3/4/5 assertion: those are red on T178, so inverting one
    # would "pass" for the wrong reason.)
    if ($NegativeControl) {
        "NEGATIVE CONTROL: asserting the split did NOT inherit the cwd - this run MUST fail"
        Assert "split pane did NOT inherit the cd'd cwd (inverted)" (-not ($dump -like "*t68-sub*"))
    } else {
        Assert "split pane inherited the cd'd cwd (remote GET_CWD)" ($dump -like "*t68-sub*")
    }

    "== 3: +split --target with a remote-native --command stays remote"
    cmd /c "`"$Exe`" +split --target=rem --name=remsplit `"--command=echo t68-split-marker`" > `"$tmp\split2.txt`" 2>&1"
    Assert "split --target exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $dump = Read-Pane 'remsplit' 'read-split2.txt'
    Assert "explicit command ran through the agent" ($dump -like "*t68-split-marker*")

    "== 4: ctrl+t - the new-tab keybind inherits the active pane's command"
    $namesBeforeTab = @(Get-PaneNames)
    $remTop = Get-WindowHwnd 'rem'
    Assert "found the remote window HWND" ($remTop -ne [IntPtr]::Zero)
    Assert "the +list window id really is a GhozttyWindow" ((Get-TestWindowClass -Window $remTop) -eq 'GhozttyWindow')
    # Focus the window, then read back which SURFACE the app focused - that is
    # the pane the chord must go to, and the pane the new tab inherits from.
    Focus-TestWindow -Window $remTop | Out-Null
    Start-Sleep -Milliseconds 500
    $active = [IntPtr](Get-TestFocusedWindow -Window $remTop)
    Assert "the window forwarded focus to a terminal surface" ((Get-TestWindowClass -Window $active) -eq 'GhozttyTerminal')
    $sent = Send-TestKeys -Window $remTop -Target $active -Modifiers ctrl -Key T
    Assert "ctrl+t injected" $sent
    Start-Sleep -Seconds 3
    $namesAfterTab = @(Get-PaneNames)
    Assert "new tab pane appeared" ($namesAfterTab.Count -eq ($namesBeforeTab.Count + 1))
    $tabPane = @($namesAfterTab | Where-Object { $namesBeforeTab -notcontains $_ })
    if ($tabPane.Count -eq 1) {
        $dump = Read-Pane $tabPane[0] 'read-tab.txt'
        # The active pane at ctrl+t was remsplit (last split takes focus), so
        # the tab re-runs its command (Mac WP4 command inheritance). RED on
        # T178: section 3's marker never reaches the pane, so nothing
        # downstream can find it either.
        Assert "new tab re-ran the parent pane's remote command" ($dump -like "*t68-split-marker*")
    } else {
        Assert "new tab pane identified" $false
    }

    "== 5: +new-window --from-focused dials the SAME agent"
    $connsBefore = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
    cmd /c "`"$Exe`" +new-window --from-focused > `"$tmp\neww.txt`" 2>&1"
    Assert "new-window --from-focused exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $connsAfter = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
    Assert "a second agent connection exists" ($connsAfter.Count -eq ($connsBefore.Count + 1))
    $namesAfterWin = @(Get-PaneNames)
    $winPane = @($namesAfterWin | Where-Object { $namesAfterTab -notcontains $_ })
    Assert "new window's pane discovered" ($winPane.Count -eq 1)
    if ($winPane.Count -eq 1) {
        $dump = Read-Pane $winPane[0] 'read-neww.txt'
        # Inherits from rem's active pane (the ctrl+t tab, itself running the
        # marker command) - output proves the window opened on the agent.
        Assert "new window inherited the remote command" ($dump -like "*t68-split-marker*")
    }

    "== 6: --from-focused with a LOCAL parent falls through to local"
    & $Exe +new-window --target=locbase 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +new-window --target=locbase 2>&1 | Out-Null # idempotent re-call focuses it
    Start-Sleep -Seconds 1
    $namesBeforeLocal = @(Get-PaneNames)
    cmd /c "`"$Exe`" +split --from-focused > `"$tmp\lsplit.txt`" 2>&1"
    Assert "local split --from-focused exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 2
    $namesAfterLocal = @(Get-PaneNames)
    Assert "local from-focused split created a pane" ($namesAfterLocal.Count -eq ($namesBeforeLocal.Count + 1))
    $connsLocal = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
    Assert "no extra agent connection for the local split" ($connsLocal.Count -eq $connsAfter.Count)
    cmd /c "`"$Exe`" +new-window --from-focused > `"$tmp\lneww.txt`" 2>&1"
    Assert "local new-window --from-focused exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 2
    $namesAfterLocalWin = @(Get-PaneNames)
    Assert "local from-focused window created a pane" ($namesAfterLocalWin.Count -eq ($namesAfterLocal.Count + 1))
    $connsLocal2 = @(Get-NetTCPConnection -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
    Assert "no extra agent connection for the local window" ($connsLocal2.Count -eq $connsAfter.Count)

    "== 7: dead agent surfaces the reach error (no silent local window)"
    # Close everything but rem first: frontWindow falls back to the last-created
    # window when no ghoztty window owns the foreground (headless-run safety),
    # so rem must be the only window left for --from-focused to target it.
    & $Exe +close --target=locbase 2>&1 | Out-Null
    $list = Get-ListJson
    foreach ($m in [regex]::Matches($list, '"target":"(window-\d+)"')) {
        & $Exe +close --target=$($m.Groups[1].Value) 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 1
    Stop-Process -Id $agent.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    cmd /c "`"$Exe`" +new-window --from-focused > `"$tmp\dead.txt`" 2>&1"
    Assert "exit nonzero with dead agent" ($LASTEXITCODE -ne 0)
    $err = Get-Content "$tmp\dead.txt" -Raw
    Assert "error names the remote machine" ($err -like "*remote machine*")
    $list = Get-ListJson
    Assert "app still alive after failed re-dial" ($list -like '*"success":true*')

    "== cleanup"
    & $Exe +close --target=rem 2>&1 | Out-Null
    Start-Sleep -Seconds 1
} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
"foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run
    # by now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
