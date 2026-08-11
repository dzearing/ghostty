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

# Path compare that tolerates separator/case differences: `+list` reports the
# cwd as the shell sees it.
function Test-SameDir([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    return ($a.Replace('/', '\').TrimEnd('\')) -ieq ($b.Replace('/', '\').TrimEnd('\'))
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

# A leaf's reported cwd, retried: it lands on the leaf a moment after the pane
# does (seeded from termio by the first `+list` that sees it).
function Get-LeafCwd([string]$name, [string]$want) {
    $cwd = ''
    for ($t = 0; $t -lt 25; $t++) {
        $raw = Get-ListJson
        $j = $null
        try { $j = $raw | ConvertFrom-Json } catch { }
        if ($j) {
            foreach ($w in @($j.data.windows)) {
                foreach ($tab in @($w.tabs)) {
                    foreach ($leaf in @(Get-Leaves $tab.splits)) {
                        if ($leaf.name -eq $name) { $cwd = $leaf.working_directory }
                    }
                }
            }
        }
        if (Test-SameDir $cwd $want) { break }
        Start-Sleep -Milliseconds 200
    }
    return $cwd
}

# The same, for a window's first pane (which carries no name of our choosing).
function Get-WindowCwd([string]$target, [string]$want) {
    $cwd = ''
    for ($t = 0; $t -lt 25; $t++) {
        $raw = Get-ListJson
        $j = $null
        try { $j = $raw | ConvertFrom-Json } catch { }
        if ($j) {
            foreach ($w in @($j.data.windows | Where-Object { $_.target -eq $target })) {
                foreach ($leaf in @(Get-Leaves $w.tabs[0].splits)) { $cwd = $leaf.working_directory }
            }
        }
        if (Test-SameDir $cwd $want) { break }
        Start-Sleep -Milliseconds 200
    }
    return $cwd
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
    # T515: an explicit command must not cost the split its parent's cwd. The
    # local-agent branch used to build an override with a null working
    # directory whenever a command was given, so the agent opened the session
    # in ITS default cwd (%USERPROFILE%) - a split that silently walked away
    # from where the user was.
    Assert "explicit split still inherited the parent's cwd (T515)" ($dump -like "*t148-root*")

    "== 5: an explicit --working-directory still WINS over the parent's cwd (T515)"
    $other = Join-Path $tmp 't515-elsewhere'
    New-Item -ItemType Directory -Force $other | Out-Null
    cmd /c "`"$Exe`" +split --pane=$($parentPane[0]) --name=sp3 `"--working-directory=$other`" `"--command=echo T515-WD`" > `"$tmp\split3.txt`" 2>&1"
    Assert "explicit-wd split exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $dump = Read-Pane 'sp3' 'read-sp3.txt'
    Assert "explicit-wd split ran its own command" ($dump -like "*T515-WD*")
    Assert "explicit --working-directory beat the parent's cwd" ($dump -like "*t515-elsewhere*")
    Assert "explicit --working-directory did not fall back to the parent's cwd" (-not ($dump -like "*t148-root*"))

    "== 6: the parent's cwd wins over the FOCUSED window's (T515)"
    # The teeth of section 4. When the split parent IS the focused pane, a
    # split with no explicit cwd lands right for the wrong reason: the core's
    # own inheritance is app-GLOBAL (`apprt/surface.zig` newConfig reads
    # `app.focusedSurface`), so it happened to name the same pane. Park the
    # focus in a second window in a different directory first, and only a split
    # that asked ITS OWN parent can still answer t148-root.
    $far = Join-Path $tmp 't515-far'
    New-Item -ItemType Directory -Force $far | Out-Null
    cmd /c "`"$Exe`" +new-window --target=farwin `"--working-directory=$far`" > `"$tmp\far.txt`" 2>&1"
    Assert "far window exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $farCwd = Get-WindowCwd 'farwin' $far
    Assert "the far window's pane is in the far directory (control)" (Test-SameDir $farCwd $far)
    cmd /c "`"$Exe`" +split --pane=$($parentPane[0]) --name=sp4 `"--command=echo T515-CROSS`" > `"$tmp\split4.txt`" 2>&1"
    Assert "cross-window split exit 0" ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3
    $crossCwd = Get-LeafCwd 'sp4' $root
    Assert "the split opened in its own parent's cwd (got '$crossCwd')" (Test-SameDir $crossCwd $root)
    Assert "and NOT in the focused window's cwd" (-not (Test-SameDir $crossCwd $far))
    & $Exe +close --target=farwin 2>&1 | Out-Null
    Start-Sleep -Seconds 1

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
