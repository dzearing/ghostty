# T65 acceptance: child-exited UI is the core in-terminal fallback, not a
# modal dialog. Runs the debug build with a private config
# (wait-after-command=true, abnormal-command-exit-runtime=5000) via
# XDG_CONFIG_HOME so exits keep the pane open and fast nonzero exits count
# as abnormal deterministically.
#
#   powershell -NoProfile -File test\win32\ipc-child-exited.ps1
#
# Covers: clean exit + wait-after-command shows the press-any-key notice
# (previously showed NOTHING), abnormal exit shows the rich in-terminal
# diagnostic (command + runtime), no modal dialog exists, and a REAL key
# press (posted to the surface — `+send-keys` writes to the PTY and cannot
# exercise the close-on-key path) closes the waited pane.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private T65Drv driver (GrabForeground + SendInput) is gone; the harness
# supplies the equivalents. The app is launched ONTO the desktop rather than
# auto-spawned by `+new-window`, which would have put it on the user's.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-t65-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# Isolate the IPC endpoint: the app inherits this through CreateProcessW and
# so does every `& $Exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = '-childexitedtest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

function Get-ListJson {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    try { Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json } catch { $null }
}

# Depth-first first leaf of a splits node.
function Get-FirstLeaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node }
    $l = Get-FirstLeaf $node.left
    if ($null -ne $l) { return $l }
    Get-FirstLeaf $node.right
}

function Get-PaneName($target) {
    $j = Get-ListJson
    if ($null -eq $j) { return $null }
    $win = $j.data.windows | Where-Object { $_.target -eq $target }
    if ($null -eq $win) { return $null }
    (Get-FirstLeaf $win.tabs[0].splits).terminal.name
}

function Read-Pane($name, $lines) {
    cmd /c "`"$Exe`" +read --name=$name --lines=$lines > `"$tmp\read.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\read.txt" -Raw
}

Stop-DebugGhoztty

"== setup: private config (wait-after-command, generous abnormal window)"
$cfgDir = Join-Path $tmp 'xdg\ghostty'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
@(
    'wait-after-command = true'
    'abnormal-command-exit-runtime = 5000'
) | Set-Content -Path (Join-Path $cfgDir 'config') -Encoding ascii
$env:XDG_CONFIG_HOME = Join-Path $tmp 'xdg'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {

# The app is started here (inheriting XDG_CONFIG_HOME and the pipe suffix)
# so that every window it opens lives on the test desktop; letting
# `+new-window` auto-spawn it would put the GUI on the user's desktop.
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false')
Start-Sleep -Seconds 3
Assert "app launched" (-not ($app.Process -and $app.Process.HasExited))
$launched += $app.Pid
$boot = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
if ($boot -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

"== 1: clean exit 0 + wait-after-command -> press-any-key notice"
& $Exe +new-window --target=ce0 -e cmd /c exit 0 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 4
$list = Get-ListJson
Assert "window stayed open" ($null -ne ($list.data.windows | Where-Object { $_.target -eq 'ce0' }))
$pane0 = Get-PaneName 'ce0'
Assert "pane discovered" (-not [string]::IsNullOrEmpty($pane0))
$txt0 = Read-Pane $pane0 10
Assert "press-any-key notice shown" ($txt0 -match 'Process exited')

"== 2: abnormal exit 3 -> rich in-terminal diagnostic"
& $Exe +new-window --target=ce3 -e cmd /c exit 3 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 3
$pane3 = Get-PaneName 'ce3'
Assert "pane discovered" (-not [string]::IsNullOrEmpty($pane3))
$txt3 = Read-Pane $pane3 20
Assert "diagnostic header shown" ($txt3 -match 'failed to launch')
Assert "command echoed" ($txt3 -match 'exit 3')
Assert "runtime shown" ($txt3 -match 'Runtime:')

"== 3: no modal dialog anywhere"
Assert "app process still running" (-not ($app.Process -and $app.Process.HasExited))
# Both dialog flavors: the win32 MessageBox class AND the native dialog the
# app has used for its own modals since T50. Checking only '#32770' would
# pass against a GhozttyConfirmDialog that had regressed into existence.
$modal = [IntPtr]::Zero
foreach ($cls in '#32770', 'GhozttyConfirmDialog') {
    $h = Get-TestWindow -ProcessId $app.Pid -Class $cls
    if ($h -ne [IntPtr]::Zero) { $modal = $h; break }
}
Assert "no modal dialog owned by ghoztty" ($modal -eq [IntPtr]::Zero)
& $Exe +list 2>&1 | Out-Null
Assert "IPC responsive" ($LASTEXITCODE -eq 0)

"== 4: real key press closes the waited pane"
$win0 = $list.data.windows | Where-Object { $_.target -eq 'ce0' }
$top0 = [IntPtr][int64]$win0.id
Assert "list id is the top hwnd" ((Get-TestWindowClass -Window $top0) -eq 'GhozttyWindow')
$surf0 = Get-TestChildWindow -Window $top0 -Class 'GhozttyTerminal'
Assert "surface child found" ($surf0 -ne [IntPtr]::Zero)
# -NegativeControl skips the key press while still asserting the pane
# closed, so the run MUST fail - proof the assertion discriminates.
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting ce0 closed WITHOUT pressing a key - this run MUST fail'
} else {
    $r = Send-TestKeys -Window $top0 -Target $surf0 -Key A   # plain 'a'
    Assert "key injected" $r
}
Start-Sleep -Seconds 2
$list = Get-ListJson
Assert "ce0 closed by key press" ($null -eq ($list.data.windows | Where-Object { $_.target -eq 'ce0' }))
Assert "ce3 still open (abnormal path waits)" ($null -ne ($list.data.windows | Where-Object { $_.target -eq 'ce3' }))

"== teardown"
& $Exe +close --target=ce3 2>&1 | Out-Null

} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
"foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

if ($script:failures -eq 0) { "ALL PASS" ; exit 0 }
else { "$script:failures FAILURE(S)" ; exit 1 }
