# Local command one-shot acceptance (tracker T148): a new tab or split in a
# LOCAL session-persistence window must NOT re-run the parent pane's explicit
# `--command` - `-e`/`--command` is one-shot for the surface it was given
# (upstream Ghostty semantics; the Mac fixed the same regression in cdb689025).
# Command inheritance is for GENUINE remote machines only; a local split/tab
# opens a plain shell, inheriting only the parent's cwd.
#
#   powershell -NoProfile -File test\win32\local-split-no-command-rerun.ps1
#
# Covers: a local `+new-window --command=...` pane runs its command (control),
# ctrl+t on that window opens a tab WITHOUT re-running the command, a
# `+split --pane=<that pane>` with no command opens a plain shell that still
# inherits the parent's cwd (the agent GET_CWD path must survive the fix),
# and an EXPLICIT `+split --command=...` still runs its own command.
#
# Session persistence stays ON (the default) on purpose: the bug lives in the
# local-agent inheritance seam (`Window.buildRemoteInherit`), which only backs
# panes when persistence routes them through the agent.
#
# Runs on a background Win32 desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground - asserted at the end, not assumed.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-t148-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# Isolate the IPC endpoint (inherited through CreateProcessW) so this run's
# +verbs reach THIS instance and not whatever answers the shared pipe.
$env:GHOZTTY_PIPE_SUFFIX = '-t148'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

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
    # A marker cwd: cwd inheritance is asserted alongside "no command re-run"
    # so the fix can never overcut (the split must still land where its parent
    # is, via the agent's GET_CWD).
    $root = Join-Path $tmp 't148-root'
    New-Item -ItemType Directory -Force $root | Out-Null

    "== 0: start the GUI (session persistence ON - the default)"
    # persistence: on (default), as the section header says - the agent-backed split is the subject.
    $app = Start-OnTestDesktop -Exe $Exe
    Start-Sleep -Seconds 3
    Assert "GUI is running" (-not ($app.Process -and $app.Process.HasExited))
    $win0 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Assert "GUI window is up" ($win0 -ne [IntPtr]::Zero)
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $basePanes = @(Get-PaneNames)

    "== 1: a local window with an explicit --command runs it (control)"
    cmd /c "`"$Exe`" +new-window --target=cmdwin `"--working-directory=$root`" `"--command=echo T148-PARENT-MARKER`" > `"$tmp\open.txt`" 2>&1"
    Assert "open exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $afterOpen = @(Get-PaneNames)
    $parentPane = @($afterOpen | Where-Object { $basePanes -notcontains $_ })
    Assert "parent pane discovered" ($parentPane.Count -eq 1)
    $dump = Read-Pane $parentPane[0] 'read-parent.txt'
    Assert "parent pane ran the explicit command" ($dump -like "*T148-PARENT-MARKER*")

    "== 2: ctrl+t - the new tab must NOT re-run the parent's command"
    $hwnd = Get-WindowHwnd 'cmdwin'
    Assert "found the cmdwin HWND" ($hwnd -ne [IntPtr]::Zero)
    Focus-TestWindow -Window $hwnd | Out-Null
    Start-Sleep -Milliseconds 500
    $active = [IntPtr](Get-TestFocusedWindow -Window $hwnd)
    Assert "the window forwarded focus to a terminal surface" ((Get-TestWindowClass -Window $active) -eq 'GhozttyTerminal')
    $sent = Send-TestKeys -Window $hwnd -Target $active -Modifiers ctrl -Key T
    Assert "ctrl+t injected" $sent
    Start-Sleep -Seconds 3
    $afterTab = @(Get-PaneNames)
    Assert "new tab pane appeared" ($afterTab.Count -eq ($afterOpen.Count + 1))
    $tabPane = @($afterTab | Where-Object { $afterOpen -notcontains $_ })
    if ($tabPane.Count -eq 1) {
        $dump = Read-Pane $tabPane[0] 'read-tab.txt'
        # The tab still inherits the parent's cwd (cmd.exe's prompt names it),
        # which doubles as proof the pane painted before the absence check.
        Assert "new tab painted (inherited cwd visible)" ($dump -like "*t148-root*")
        Assert "new tab did NOT re-run the parent's command" (-not ($dump -like "*T148-PARENT-MARKER*"))
        # Put the marker pane's tab back in front for the split sections.
        & $Exe +close --target=$($tabPane[0]) 2>&1 | Out-Null
        Start-Sleep -Seconds 1
    } else {
        Assert "new tab pane identified" $false
    }

    "== 3: +split with no command opens a plain shell (cwd still inherited)"
    cmd /c "`"$Exe`" +split --pane=$($parentPane[0]) --name=sp1 > `"$tmp\split1.txt`" 2>&1"
    Assert "split exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $dump = Read-Pane 'sp1' 'read-sp1.txt'
    Assert "split pane painted and inherited the parent's cwd" ($dump -like "*t148-root*")
    Assert "split pane did NOT re-run the parent's command" (-not ($dump -like "*T148-PARENT-MARKER*"))

    "== 4: an EXPLICIT +split --command still runs its own command"
    cmd /c "`"$Exe`" +split --pane=$($parentPane[0]) --name=sp2 `"--command=echo T148-EXPLICIT`" > `"$tmp\split2.txt`" 2>&1"
    Assert "explicit split exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $dump = Read-Pane 'sp2' 'read-sp2.txt'
    Assert "explicit split ran its own command" ($dump -like "*T148-EXPLICIT*")

    "== cleanup"
    & $Exe +close --target=cmdwin 2>&1 | Out-Null
    Start-Sleep -Seconds 1
} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
"foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
