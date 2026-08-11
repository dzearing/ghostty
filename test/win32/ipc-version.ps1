# T52 acceptance: build provenance visible in-app. Non-interactive; exits
# nonzero on any failure. Only touches ghoztty processes from zig-out.
#
# Covers:
#   1. `+version` prints a "Running Instance" section whose commit/mode/
#      runtime/exe/pid identify the serving instance.
#   2. `+list --json` carries the same provenance as data.build.
#   3. Palette "About Ghoztty" entry opens the About box (chord-injected;
#      the palette-popup assert is the input-injection positive control).
#   4. `+version` with no instance still succeeds and says so.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private VerDrv driver (GrabForeground + SendInput) is gone; the harness
# supplies the equivalents. The app is launched ONTO the desktop rather than
# auto-spawned by `+new-window`, which would have put it on the user's.
#
#   powershell -NoProfile -File test\win32\ipc-version.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-version-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# Isolate the IPC endpoint: the app inherits this through CreateProcessW and
# so does every `& $Exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = '-ipcversiontest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# It kills the sibling agent too and drops the debug session-layout manifest,
# so a pane from a previous run cannot be focused in place of the fixture.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {

"== setup: one debug window on the test desktop"
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false')
Start-Sleep -Seconds 3
Assert "debug instance running" (-not ($app.Process -and $app.Process.HasExited))
$launched += $app.Pid
$first = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
if ($first -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
# The named window the teardown closes; it lands on the test desktop too,
# because the app process's threads live there.
& $Exe +new-window --target=vt 2>&1 | Out-Null
Start-Sleep -Seconds 2
$expectCommit = (git -C $Repo log --pretty=format:%h -n 1)

"== 1: +version reports the running instance"
cmd /c "`"$Exe`" +version > `"$tmp\version.txt`" 2>&1"
Assert "exit 0" ($LASTEXITCODE -eq 0)
$vtxt = Get-Content "$tmp\version.txt" -Raw
Assert "Running Instance section" ($vtxt -match 'Running Instance')
Assert "commit matches HEAD ($expectCommit)" ($vtxt -match "commit\s*:\s*$([regex]::Escape($expectCommit))")
Assert "mode is Debug" ($vtxt -match 'mode\s*:\s*Debug')
Assert "runtime is win32" ($vtxt -match 'runtime\s*:\s*win32')
Assert "exe is the zig-out exe" ($vtxt -match [regex]::Escape($Exe))
Assert "pid matches server" ($vtxt -match "pid\s*:\s*$($app.Pid)")
Assert "modified stamp shape" ($vtxt -match 'modified:\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC')

"== 2: +list --json carries build metadata"
cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1"
$j = Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json
Assert "build object present" ($null -ne $j.data.build)
Assert "build.commit matches" ($j.data.build.commit -eq $expectCommit)
Assert "build.pid matches" ($j.data.build.pid -eq $app.Pid)
Assert "build.runtime is win32" ($j.data.build.runtime -eq 'win32')
Assert "build.exe is the zig-out exe" ($j.data.build.exe -eq $Exe)

"== 3: palette About entry opens the About box"
# The `vt` window is the one that is NOT the launch window.
$top = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -Exclude $first
if ($top -eq [IntPtr]::Zero) { $top = $first }
$surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
Assert "terminal surface found" ($surface -ne [IntPtr]::Zero)
# The palette popup is a top-level GhozttyTerminal; retry the open in case
# the chord lands while the window is still settling.
$popup = [IntPtr]::Zero
$sent = $false
foreach ($try in 1..3) {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl,shift -Key P
    if (-not $sent) { continue }
    $popup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
    if ($popup -ne [IntPtr]::Zero) { break }
}
if (-not $sent) {
    "  SKIP palette test: chord not delivered"
    $script:skipped++
} else {
    Assert "palette popup opened (positive control)" ($popup -ne [IntPtr]::Zero)
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    Assert "palette edit found" ($edit -ne [IntPtr]::Zero)
    if ($edit -ne [IntPtr]::Zero) {
        # -NegativeControl runs a query that matches no command while still
        # asserting the About box appears, so the run MUST fail - proof the
        # assertion discriminates rather than being true of every query.
        $query = 'about'
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting the About box appears for a nonsense query - this run MUST fail'
            $query = 'zzznotacommand'
        }
        # A standard EDIT needs WM_CHAR (nothing translates a posted key),
        # and Enter goes in as a navigation key.
        Send-TestControlText -Control $edit -Text $query | Out-Null
        Send-TestControlKey -Control $edit -Key Enter | Out-Null
        # The About box is a NATIVE dialog (ConfirmDialog, class
        # GhozttyConfirmDialog) since the T50 chrome pass - NOT the
        # '#32770' MessageBox this script used to look for. That stale
        # expectation survived unnoticed because the old foreground-grab
        # chord kept failing and the whole section took its SKIP branch;
        # on the test desktop the chord always lands, so it surfaced.
        $dlg = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 5000
        Assert "About box appeared" ($dlg -ne [IntPtr]::Zero)
        if ($dlg -ne [IntPtr]::Zero) {
            Assert "About box is titled 'About Ghoztty'" ((Get-TestWindowText -Window $dlg) -eq 'About Ghoztty')
            Send-TestWindowClose -Window $dlg | Out-Null
            Start-Sleep -Milliseconds 500
        }
        Assert "no crash after About round-trip" (-not ($app.Process -and $app.Process.HasExited))
    }
}

"== 4: +version with no instance still succeeds"
& $Exe +close --target=vt 2>&1 | Out-Null
Start-Sleep -Seconds 1
Stop-DebugGhoztty
cmd /c "`"$Exe`" +version > `"$tmp\version2.txt`" 2>&1"
Assert "exit 0 without instance" ($LASTEXITCODE -eq 0)
Assert "none detected" ((Get-Content "$tmp\version2.txt" -Raw) -match 'none detected')

} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
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

""
if ($script:failures -eq 0) {
    "T52 ACCEPTANCE: ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
    exit 0
} else {
    "T52 ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
