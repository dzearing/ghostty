# T71 acceptance: Claude Code integration setup — first-run offer + palette
# entry (win32 port of Mac ClaudeCodeIntegration.swift / AppDelegate+Setup).
#
# Covered:
#   1. First run (claude present, plugin absent, no answer on file) -> the
#        "Set Up Claude Code Integration?" dialog appears with Set Up /
#        Not Now buttons; Escape (=Not Now) declines: no claude invocation,
#        state file records "declined".
#   2. Relaunch with the declined state -> NO dialog (declining remembered).
#   3. Fresh state, prompt accepted via Enter (Set Up is the default) ->
#        the stub claude gets `plugin marketplace add` + `plugin install`
#        with the exact ids, state records "accepted", and first-run
#        success stays silent (no outcome dialog).
#   4. Palette entry: ctrl+shift+p -> "claude" -> Enter reruns the flow and
#        REPORTS the outcome ("Claude Code Integration Ready"), two more
#        stub invocations land in the log.
#   5. claude missing (override points at a nonexistent exe): launch shows
#        no prompt and burns nothing (no state file, so a later claude
#        install still gets the offer); the palette entry says
#        "Claude Code Not Found".
#
# The claude CLI is a stub .cmd (GHOZTTY_CLAUDE_EXE) that logs its args and
# answers per CLAUDE_STUB_MODE, so the box's real claude config is never
# touched. State/plugins-registry paths are redirected via
# GHOZTTY_CLAUDE_STATE_DIR / GHOZTTY_CLAUDE_PLUGINS_JSON; the config is
# isolated via XDG_CONFIG_HOME (the T69 pattern).
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone. Notes on the
# mechanics:
#
#   * Every env var above is inherited through CreateProcessW, so it reaches
#     the test-desktop child exactly as it reached Start-Process.
#   * The prompt/outcome dialogs are GhozttyConfirmDialog, which reads RAW
#     WM_KEYDOWN in its own nested pump, so a POSTED Enter/Escape reaches them
#     (Send-TestControlKey). The old script pressed a GLOBAL key and trusted
#     focus to be on the dialog; posting names the window instead.
#   * The palette popup is a top-level owned GhozttyTerminal window, found with
#     Get-TestWindow -Exclude $top; its query field is a standard EDIT, which
#     needs WM_CHAR - Send-TestControlText, not Send-TestText.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW) so a stray
# instance answering the shared pipe cannot open windows in this run.
$env:GHOZTTY_PIPE_SUFFIX = '-claudetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Wait for a visible window of $cls in $gpid to appear (or to go away).
function Wait-Class([int]$gpid, [string]$cls, [bool]$appear, [int]$timeoutMs = 3000) {
    if ($appear) { return Wait-TestWindow -ProcessId $gpid -Class $cls -TimeoutMs $timeoutMs }
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $d = Get-TestWindow -ProcessId $gpid -Class $cls
        if ($d -eq [IntPtr]::Zero) { return $d }
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    return (Get-TestWindow -ProcessId $gpid -Class $cls)
}

# Captions of every BUTTON child, read with WM_GETTEXT (GetWindowTextW is
# cross-process cached). Class comparison in the harness is exact, so
# enumerate every child and match case-insensitively.
function Get-ButtonTexts([IntPtr]$dlg) {
    $btns = @(Get-TestChildWindows -Window $dlg -Class '*' | Where-Object { $_.Class -match '^button$' })
    return @($btns | ForEach-Object { Get-TestControlText -Control ([IntPtr]$_.Hwnd) })
}

# ---------------------------------------------------------------- fixtures
$base = Join-Path $env:TEMP 'ghoztty-t71'
Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $base | Out-Null

# Isolated config home (T69 pattern) so the box's real config never leaks.
$cfgHome = Join-Path $base 'xdg'
New-Item -ItemType Directory -Force (Join-Path $cfgHome 'ghostty') | Out-Null
Set-Content -Path (Join-Path $cfgHome 'ghostty\config') -Value "# empty`n" -Encoding ascii

# Stub claude CLI: logs argument lines, answers per CLAUDE_STUB_MODE.
$stubLog = Join-Path $base 'stub.log'
$stub = Join-Path $base 'claude.cmd'
@"
@echo off
>> "$stubLog" echo %*
if /i "%CLAUDE_STUB_MODE%"=="fail" (
  echo Error: stub failure
  exit /b 1
)
if /i "%CLAUDE_STUB_MODE%"=="already" (
  echo already installed
  exit /b 0
)
echo Installed
exit /b 0
"@ | Set-Content -Path $stub -Encoding ascii

# Plugins registry WITHOUT any ghoztty plugin (so the prompt is offered).
$pluginsJson = Join-Path $base 'installed_plugins.json'
Set-Content -Path $pluginsJson -Value '{"version":2,"plugins":{}}' -Encoding ascii

$MARKETPLACE = 'dzearing/ghoztty-claude-plugin'
$PLUGIN = 'ghoztty@ghoztty-claude-plugin'

function Launch-Gui([string]$stateDir, [string]$claudeExe, [string]$stubMode) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_CLAUDE_SETUP = 'force'
    $env:GHOZTTY_CLAUDE_EXE = $claudeExe
    $env:GHOZTTY_CLAUDE_STATE_DIR = $stateDir
    $env:GHOZTTY_CLAUDE_PLUGINS_JSON = $pluginsJson
    $env:CLAUDE_STUB_MODE = $stubMode
    $env:CLAUDE_STUB_LOG = $stubLog
    try {
        # --session-persistence=false: every case here relaunches the app, and
        # a restored layout manifest would hand a later case the previous
        # case's panes while its write races the kill in between.
        $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    } finally {
        'XDG_CONFIG_HOME', 'GHOZTTY_CLAUDE_SETUP', 'GHOZTTY_CLAUDE_EXE',
        'GHOZTTY_CLAUDE_STATE_DIR', 'GHOZTTY_CLAUDE_PLUGINS_JSON',
        'CLAUDE_STUB_MODE', 'CLAUDE_STUB_LOG' | ForEach-Object {
            Remove-Item "Env:$_" -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    return @{ App = $app; Pid = $app.Pid; Top = $top }
}

# Open the palette, type "claude", Enter. Returns $true when everything
# was injected (palette opening doubles as the chord positive control).
function Invoke-PaletteClaude($g) {
    $surface = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; return $false }
    # The window hands WM_KEYDOWN to DefWindowProc and only forwards FOCUS to
    # the active pane, so the chord has to be aimed at the surface itself.
    Focus-TestWindow -Window $g.Top -Child $surface | Out-Null
    $r = Send-TestKeys -Window $g.Top -Target $surface -Modifiers ctrl, shift -Key P
    if (-not $r) { Write-Host 'SETUP FAIL: palette chord not injected'; return $false }
    # The palette is a top-level owned GhozttyTerminal popup, not a child of
    # the window - exclude the main window so the search cannot return it.
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 40
        $popup = Get-TestWindow -ProcessId $g.Pid -Class 'GhozttyTerminal' -Exclude $g.Top
    }
    if ($popup -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette popup did not open'; return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette edit not found'; return $false }
    # A standard EDIT needs WM_CHAR, which nothing generates for a posted key.
    if (-not (Send-TestControlText -Control $edit -Text 'claude')) { Write-Host 'SETUP FAIL: palette query not typed'; return $false }
    Start-Sleep -Milliseconds 200
    if (-not (Send-TestControlKey -Control $edit -Key Enter)) { Write-Host 'SETUP FAIL: palette Enter not posted'; return $false }
    Start-Sleep -Milliseconds 200
    return $true
}

function Get-StubLines {
    if (-not (Test-Path $stubLog)) { return @() }
    return @(Get-Content $stubLog | Where-Object { $_.Trim() -ne '' })
}

# Poll until the stub log holds $count lines (claude runs are async).
function Wait-StubLines([int]$count, [int]$tries = 150) {
    for ($t = 0; $t -lt $tries; $t++) {
        $lines = Get-StubLines
        if ($lines.Count -ge $count) { return $lines }
        Start-Sleep -Milliseconds 100
    }
    return (Get-StubLines)
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ------------------------------------------------------------ case 1:
    # first run -> prompt with Set Up / Not Now; Escape declines, no CLI run.
    $state1 = Join-Path $base 'state1'
    $g = Launch-Gui $state1 $stub 'ok'
    $gpid = $g.Pid

    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'first run shows the Set Up Claude Code Integration prompt'
    if ($dlg -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no prompt to score'; exit 1 }

    Assert ((Get-TestWindowText -Window $dlg) -eq 'Set Up Claude Code Integration?') 'prompt title is Set Up Claude Code Integration?'
    $btns = Get-ButtonTexts $dlg
    Assert (($btns -contains 'Set Up') -and ($btns -contains 'Not Now')) "buttons are Set Up / Not Now (got: $($btns -join ', '))"
    # Modality is the dialog's other observable half, and IsWindowEnabled is
    # the only cross-process-safe way to see it.
    Assert (-not (Test-TestWindowEnabled -Window $g.Top)) 'the prompt is modal: its owner window is disabled'

    Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
    Assert ($gone -eq [IntPtr]::Zero) 'Escape (Not Now) dismisses the prompt'
    Assert (Test-TestWindowEnabled -Window $g.Top) 'owner window is enabled again once the prompt closes'
    Start-Sleep -Milliseconds 500
    Assert ((Get-StubLines).Count -eq 0) 'declining runs no claude command'
    $stateFile = Join-Path $state1 'claude_setup'
    Assert ((Test-Path $stateFile) -and ((Get-Content $stateFile -Raw).Trim() -eq 'declined')) 'state file records declined'
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app keeps running after declining'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 2:
    # relaunch with the declined answer -> no prompt (case 1 proved this env
    # shows one when unanswered, so the negative is trustworthy).
    $g = Launch-Gui $state1 $stub 'ok'
    $gpid = $g.Pid
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 4000
    # -NegativeControl inverts the load-bearing "silence means remembered"
    # claim, so a passing run proves the assertion discriminates rather than
    # being true of any outcome.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting a DECLINED answer still prompts - this run MUST fail'
        Assert ($dlg -ne [IntPtr]::Zero) 'declined answer prompts again on relaunch (inverted)'
    } else {
        Assert ($dlg -eq [IntPtr]::Zero) 'declined answer is remembered: no prompt on relaunch'
    }
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 3:
    # fresh state, accept via Enter -> both claude commands run, silent success.
    $state3 = Join-Path $base 'state3'
    $g = Launch-Gui $state3 $stub 'ok'
    $gpid = $g.Pid

    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'fresh state shows the prompt again'
    if ($dlg -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no prompt to accept'; exit 1 }
    Send-TestControlKey -Control $dlg -Key Enter | Out-Null  # Set Up is the Enter default
    $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
    Assert ($gone -eq [IntPtr]::Zero) 'Enter (Set Up) dismisses the prompt'

    $lines = Wait-StubLines 2
    Assert ($lines.Count -eq 2) "accepting runs exactly two claude commands (got $($lines.Count))"
    Assert (@($lines | Where-Object { $_ -match [regex]::Escape("plugin marketplace add $MARKETPLACE") }).Count -eq 1) 'marketplace add ran with the exact id'
    Assert (@($lines | Where-Object { $_ -match [regex]::Escape("plugin install $PLUGIN") }).Count -eq 1) 'plugin install ran with the exact id'

    $stateFile3 = Join-Path $state3 'claude_setup'
    $stateOk = $false
    for ($t = 0; $t -lt 30 -and -not $stateOk; $t++) {
        if ((Test-Path $stateFile3) -and ((Get-Content $stateFile3 -Raw).Trim() -eq 'accepted')) { $stateOk = $true }
        Start-Sleep -Milliseconds 100
    }
    Assert $stateOk 'state file records accepted'

    # First-run success is silent: no outcome dialog shows up afterwards.
    Start-Sleep -Milliseconds 1500
    Assert ((Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'first-run success shows no outcome dialog'

    # ------------------------------------------------------------ case 4:
    # palette entry reruns the flow and reports the outcome (same instance).
    $paletteOk = Invoke-PaletteClaude $g
    Assert $paletteOk 'palette claude flow injectable'
    if ($paletteOk) {
        $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 20000
        Assert ($dlg -ne [IntPtr]::Zero) 'palette install reports an outcome dialog'
        if ($dlg -ne [IntPtr]::Zero) {
            Assert ((Get-TestWindowText -Window $dlg) -eq 'Claude Code Integration Ready') 'palette outcome title is Claude Code Integration Ready'
            Send-TestControlKey -Control $dlg -Key Escape | Out-Null
            $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
            Assert ($gone -eq [IntPtr]::Zero) 'outcome dialog dismisses'
        }
        $lines = Wait-StubLines 4
        Assert ($lines.Count -eq 4) "palette run adds two more claude commands (got $($lines.Count))"
    }
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app alive after palette flow'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 5:
    # claude missing: no prompt, nothing burned; palette says Not Found.
    $state5 = Join-Path $base 'state5'
    $g = Launch-Gui $state5 (Join-Path $base 'no-such-claude.exe') 'ok'
    $gpid = $g.Pid
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 4000
    Assert ($dlg -eq [IntPtr]::Zero) 'no claude CLI: no first-run prompt'
    Assert (-not (Test-Path (Join-Path $state5 'claude_setup'))) 'no claude CLI: prompt not burned (no state file)'

    $paletteOk = Invoke-PaletteClaude $g
    Assert $paletteOk 'palette claude flow injectable (no-claude case)'
    if ($paletteOk) {
        $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 10000
        Assert ($dlg -ne [IntPtr]::Zero) 'palette install without claude reports a dialog'
        if ($dlg -ne [IntPtr]::Zero) {
            Assert ((Get-TestWindowText -Window $dlg) -eq 'Claude Code Not Found') 'outcome title is Claude Code Not Found'
            Send-TestControlKey -Control $dlg -Key Escape | Out-Null
            $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
            Assert ($gone -eq [IntPtr]::Zero) 'not-found dialog dismisses'
        }
    }
    Assert (-not (Test-Path (Join-Path $state5 'claude_setup'))) 'not-found leaves no state file'
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run
    # by now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
# The old copy of this script printed its failure count and exited 0, so a
# suite run scored a red script as green. It exits 1 now.
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
