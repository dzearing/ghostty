# T870 acceptance: agent-integration first-run offer + Claude plugin
# migration (win32 port of Mac's new-flow AppDelegate+Setup.swift +
# ClaudePluginMigration.swift). Replaces the T71 plugin-install coverage —
# the app installs its own integration now; the only claude invocation left
# is the migration's uninstall.
#
# Covered:
#   1. First run (agent detected, no answer on file) -> the "Set Up Agent
#        Integrations?" dialog appears with a checkbox per detected agent
#        and Set Up / Not Now buttons; Escape (=Not Now) declines: nothing
#        installed, no claude invocation, state file records "declined".
#   2. Relaunch with the declined state -> NO dialog (declining remembered).
#   3. Fresh state, prompt accepted via Enter (Set Up is the default) ->
#        the integration lands from the app itself (skills + hooks +
#        banner scripts under the sandbox home), NO claude CLI runs, state
#        records "accepted", and first-run success stays silent.
#   4. Palette entry ("Set Up Agent Integrations...") opens the Agent
#        Integrations MANAGEMENT window (T871, GhozttyAgentIntegrations):
#        rows fill in off-thread (claude Installed, copilot Not detected),
#        Uninstall asks for confirmation with honest copy (cancel keeps
#        everything; Remove clears skills + banner scripts and flips the
#        row), Set Up reinstalls from the row, a corrupted managed file
#        reads Update available on reopen and Update heals it - all with
#        NO claude CLI spawned.
#   5. Old plugin registered + first-run already answered -> the one-time
#        "Ghoztty Now Manages Its Claude Integration" offer; accepting runs
#        `claude plugin uninstall <registration>` through the stub CLI,
#        carries banner state (never overwriting), removes the stale
#        byte-identical script copy, installs the app integration, and
#        stays silent on success.
#   6. Same setup with a FAILING uninstall -> "Could Not Remove the Plugin"
#        dialog, nothing changed (script + state + manifest intact) — and
#        the answer is still recorded, so the prompt never returns.
#   7. No agent CLI in the sandbox home -> no first-run prompt, nothing
#        burned; the management window shows both rows Not detected with
#        no action buttons.
#
# Sandboxing: GHOZTTY_AGENT_HOME points the probe, the installers and the
# migration at a temp home — when set, the probe consults ONLY that home,
# so the box's real installs can never leak in. The stub claude.cmd lives
# at <home>\.local\bin (a probed location), logs its args, and on
# `plugin uninstall` empties the sandbox manifest exactly like the real
# uninstaller. State/answer files are redirected via
# GHOZTTY_CLAUDE_STATE_DIR; the migration's CLI override is
# GHOZTTY_CLAUDE_EXE; the app config is isolated via XDG_CONFIG_HOME (T69).
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The prompt/outcome dialogs are GhozttyConfirmDialog, which reads RAW
# WM_KEYDOWN in its own nested pump, so a POSTED Enter/Escape reaches them
# (Send-TestControlKey). The palette popup is a top-level owned
# GhozttyTerminal window; its query field is a standard EDIT, which needs
# WM_CHAR - Send-TestControlText.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW) so a stray
# instance answering the shared pipe cannot open windows in this run.
$env:GHOZTTY_PIPE_SUFFIX = "-claudetest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
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
# cross-process cached). Checkboxes are BUTTON class too, so the first-run
# checkbox shows up here alongside Set Up / Not Now.
function Get-ButtonTexts([IntPtr]$dlg) {
    $btns = @(Get-TestChildWindows -Window $dlg -Class '*' | Where-Object { $_.Class -match '^button$' })
    return @($btns | ForEach-Object { Get-TestControlText -Control ([IntPtr]$_.Hwnd) })
}

# ---------------------------------------------------------------- fixtures
$base = Join-Path $env:TEMP 'ghoztty-t870'
Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $base | Out-Null

# Isolated config home (T69 pattern) so the box's real config never leaks.
$cfgHome = Join-Path $base 'xdg'
New-Item -ItemType Directory -Force (Join-Path $cfgHome 'ghostty') | Out-Null
Set-Content -Path (Join-Path $cfgHome 'ghostty\config') -Value "# empty`n" -Encoding ascii

# Sandbox agent home. The stub claude.cmd sits in .local\bin — one of the
# probe's fallback locations — so "claude" is detected there and nothing
# else is.
$home1 = Join-Path $base 'home'
New-Item -ItemType Directory -Force (Join-Path $home1 '.local\bin') | Out-Null

$stubLog = Join-Path $base 'stub.log'
$manifest = Join-Path $home1 '.claude\plugins\installed_plugins.json'
$emptyManifest = Join-Path $base 'empty_manifest.json'
Set-Content -Path $emptyManifest -Value '{"version":2,"plugins":{}}' -Encoding ascii

# Stub claude CLI: logs argument lines; `plugin uninstall` empties the
# sandbox manifest like the real uninstaller (unless CLAUDE_STUB_MODE=fail).
$stub = Join-Path $home1 '.local\bin\claude.cmd'
@"
@echo off
>> "$stubLog" echo %*
if /i "%CLAUDE_STUB_MODE%"=="fail" (
  echo Error: stub failure
  exit /b 1
)
if /i "%1"=="plugin" if /i "%2"=="uninstall" (
  copy /y "$emptyManifest" "$manifest" >nul
)
echo ok
exit /b 0
"@ | Set-Content -Path $stub -Encoding ascii

# Registers the sandbox plugin: manifest entry whose installPath points at a
# cache dir inside the sandbox home, with the plugin's own banner-script copy.
$cacheDir = Join-Path $home1 '.claude\plugins\cache\test-marketplace\ghoztty\0.8.0'
$pluginScriptText = "#!/bin/bash`necho plugin banner v0.8.0`n"
function Install-FakePlugin {
    New-Item -ItemType Directory -Force (Join-Path $cacheDir 'hooks') | Out-Null
    Set-Content -Path (Join-Path $cacheDir 'hooks\ghoztty-banner.sh') -Value $pluginScriptText -Encoding ascii -NoNewline
    $escaped = $cacheDir -replace '\\', '\\'
    New-Item -ItemType Directory -Force (Split-Path $manifest) | Out-Null
    Set-Content -Path $manifest -Value "{`"version`":2,`"plugins`":{`"ghoztty@test-marketplace`":[{`"installPath`":`"$escaped`"}]}}" -Encoding ascii
    # The plugin-maintained script copy (byte-identical => provably the
    # plugin's) and one pane's banner state.
    New-Item -ItemType Directory -Force (Join-Path $home1 '.claude\scripts') | Out-Null
    Set-Content -Path (Join-Path $home1 '.claude\scripts\ghoztty-banner.sh') -Value $pluginScriptText -Encoding ascii -NoNewline
    New-Item -ItemType Directory -Force (Join-Path $home1 '.claude\ghoztty-banner') | Out-Null
    Set-Content -Path (Join-Path $home1 '.claude\ghoztty-banner\pane-abc.json') -Value '{"title":"carried"}' -Encoding ascii -NoNewline
}

function Launch-Gui([string]$stateDir, [string]$agentHome, [string]$stubMode) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_CLAUDE_SETUP = 'force'
    $env:GHOZTTY_AGENT_HOME = $agentHome
    $env:GHOZTTY_CLAUDE_EXE = $stub
    $env:GHOZTTY_CLAUDE_STATE_DIR = $stateDir
    $env:CLAUDE_STUB_MODE = $stubMode
    try {
        # --session-persistence=false: every case here relaunches the app, and
        # a restored layout manifest would hand a later case the previous
        # case's panes while its write races the kill in between.
        $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    } finally {
        'XDG_CONFIG_HOME', 'GHOZTTY_CLAUDE_SETUP', 'GHOZTTY_AGENT_HOME',
        'GHOZTTY_CLAUDE_EXE', 'GHOZTTY_CLAUDE_STATE_DIR', 'CLAUDE_STUB_MODE' | ForEach-Object {
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

# T871: helpers for the Agent Integrations management window. Its rows are
# STATIC controls (WM_GETTEXT-readable); its action buttons are BUTTONs
# whose clicks are driven by POSTING WM_COMMAND with the button's own
# control id - a SENT BM_CLICK would block the harness's one worker thread
# for as long as Uninstall's nested confirm dialog stays open.
# NB: the Children class filter is an EXACT, case-sensitive GetClassNameW
# compare — 'Static'/'Button', never 'static'/'button'.
function Get-AgentStaticTexts([IntPtr]$dlg) {
    return @(Get-TestControls -Window $dlg -Class 'Static' | ForEach-Object { $_.Text })
}

function Get-AgentVisibleButtons([IntPtr]$dlg) {
    return @(Get-TestControls -Window $dlg -Class 'Button' -VisibleOnly)
}

# Wait until any row static matches $pattern (-like).
function Wait-AgentRowStatus([IntPtr]$dlg, [string]$pattern, [int]$timeoutMs = 12000) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (@(Get-AgentStaticTexts $dlg | Where-Object { $_ -like $pattern }).Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 150
        $waited += 150
    }
    return $false
}

# Press a visible action button by caption: post WM_COMMAND(BN_CLICKED,id).
function Invoke-AgentButton([IntPtr]$dlg, [string]$caption) {
    $b = @(Get-AgentVisibleButtons $dlg | Where-Object { $_.Text -eq $caption })
    if ($b.Count -lt 1) { return $false }
    return (Send-TestRawMessage -Window $dlg -Message 0x0111 -WParam ([IntPtr][int]$b[0].Id))
}

# Open the palette, type "agent", Enter — opens "Set Up Agent Integrations…".
function Invoke-PaletteAgentSetup($g) {
    $surface = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; return $false }
    Focus-TestWindow -Window $g.Top -Child $surface | Out-Null
    $r = Send-TestKeys -Window $g.Top -Target $surface -Modifiers ctrl, shift -Key P
    if (-not $r) { Write-Host 'SETUP FAIL: palette chord not injected'; return $false }
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 40
        $popup = Get-TestWindow -ProcessId $g.Pid -Class 'GhozttyTerminal' -Exclude $g.Top
    }
    if ($popup -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette popup did not open'; return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette edit not found'; return $false }
    if (-not (Send-TestControlText -Control $edit -Text 'agent')) { Write-Host 'SETUP FAIL: palette query not typed'; return $false }
    Start-Sleep -Milliseconds 200
    if (-not (Send-TestControlKey -Control $edit -Key Enter)) { Write-Host 'SETUP FAIL: palette Enter not posted'; return $false }
    Start-Sleep -Milliseconds 200
    return $true
}

function Get-StubLines {
    if (-not (Test-Path $stubLog)) { return @() }
    return @(Get-Content $stubLog | Where-Object { $_.Trim() -ne '' })
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ------------------------------------------------------------ case 1:
    # first run -> prompt with a checkbox per agent; Escape declines.
    $state1 = Join-Path $base 'state1'
    $g = Launch-Gui $state1 $home1 'ok'
    $gpid = $g.Pid

    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'first run shows the Set Up Agent Integrations prompt'
    if ($dlg -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no prompt to score'; exit 1 }

    Assert ((Get-TestWindowText -Window $dlg) -eq 'Set Up Agent Integrations?') 'prompt title is Set Up Agent Integrations?'
    $btns = Get-ButtonTexts $dlg
    Assert (($btns -contains 'Set Up') -and ($btns -contains 'Not Now')) "buttons are Set Up / Not Now (got: $($btns -join ', '))"
    Assert ($btns -contains 'Set up Claude Code integration') 'the detected agent gets a checkbox row'
    Assert (-not ($btns -contains 'Set up Copilot CLI integration')) 'an undetected agent gets NO checkbox row'
    Assert (-not (Test-TestWindowEnabled -Window $g.Top)) 'the prompt is modal: its owner window is disabled'

    # T600: the prompt must disclose, BEFORE anything is written, what an
    # integration writes (banner/skills/hooks under the agent's config
    # folder) and that it is removable afterwards. The disclosure is its own
    # STATIC (the secondary note), separate from the message STATIC.
    $statics = @(Get-TestControls -Window $dlg -Class 'Static' | ForEach-Object { $_.Text })
    $note = @($statics | Where-Object { $_ -like '*status banner, skills, and hooks*' })
    Assert ($note.Count -eq 1) 'the prompt carries the agent-config-write disclosure note'
    if ($note.Count -eq 1) {
        Assert ($note[0] -like '*configuration folder*.claude*') 'the note names where the files are written'
        Assert ($note[0] -like '*remove them anytime*Set Up Agent Integrations*') 'the note names the removal path'
        Assert (@($statics | Where-Object { $_ -like '*Choose which agents to set up*' }).Count -eq 1) 'the note is separate from the message text'
    }

    Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
    Assert ($gone -eq [IntPtr]::Zero) 'Escape (Not Now) dismisses the prompt'
    Assert (Test-TestWindowEnabled -Window $g.Top) 'owner window is enabled again once the prompt closes'
    Start-Sleep -Milliseconds 500
    Assert ((Get-StubLines).Count -eq 0) 'declining runs no claude command'
    Assert (-not (Test-Path (Join-Path $home1 '.claude\skills\ghoztty'))) 'declining installs nothing'
    $stateFile = Join-Path $state1 'claude_setup'
    Assert ((Test-Path $stateFile) -and ((Get-Content $stateFile -Raw).Trim() -eq 'declined')) 'state file records declined'
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app keeps running after declining'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 2:
    # relaunch with the declined answer -> no prompt (case 1 proved this env
    # shows one when unanswered, so the negative is trustworthy).
    $g = Launch-Gui $state1 $home1 'ok'
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
    # fresh state, accept via Enter -> the app itself installs the
    # integration (no claude CLI), silent success.
    $state3 = Join-Path $base 'state3'
    $g = Launch-Gui $state3 $home1 'ok'
    $gpid = $g.Pid

    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'fresh state shows the prompt again'
    if ($dlg -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no prompt to accept'; exit 1 }
    Send-TestControlKey -Control $dlg -Key Enter | Out-Null  # Set Up is the Enter default
    $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
    Assert ($gone -eq [IntPtr]::Zero) 'Enter (Set Up) dismisses the prompt'

    # The install lands from the app itself: skills + hooks + banner scripts.
    $installedOk = $false
    for ($t = 0; $t -lt 50 -and -not $installedOk; $t++) {
        $installedOk = (Test-Path (Join-Path $home1 '.claude\skills\ghoztty\SKILL.md')) -and
            (Test-Path (Join-Path $home1 '.config\ghoztty\hooks\ghoztty-banner.sh')) -and
            (Test-Path (Join-Path $home1 '.claude\settings.json'))
        Start-Sleep -Milliseconds 100
    }
    Assert $installedOk 'accepting installs skills, hooks and banner scripts under the sandbox home'
    Assert ((Get-StubLines).Count -eq 0) 'the new flow spawns NO claude CLI for the install'

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

    # ------------------------------------------------------------ case 4
    # (T871): the palette entry opens the Agent Integrations management
    # window; rows fill in off-thread and the row actions drive the
    # integration end to end.
    $paletteOk = Invoke-PaletteAgentSetup $g
    Assert $paletteOk 'palette agent-integrations flow injectable'
    if ($paletteOk) {
        $dlg = Wait-Class $gpid 'GhozttyAgentIntegrations' $true 10000
        Assert ($dlg -ne [IntPtr]::Zero) 'palette opens the Agent Integrations window'
        if ($dlg -ne [IntPtr]::Zero) {
            Assert ((Get-TestWindowText -Window $dlg) -eq 'Agent Integrations') 'window title is Agent Integrations'
            Assert (-not (Test-TestWindowEnabled -Window $g.Top)) 'the window is modal: its owner is disabled'

            # Case 3 installed claude; the probe fills the rows in off-thread.
            Assert (Wait-AgentRowStatus $dlg 'Installed') 'claude row reports Installed after the off-thread probe'
            Assert (Wait-AgentRowStatus $dlg 'Not detected*Copilot*') 'copilot row reports Not detected with an install hint'
            $vis = @(Get-AgentVisibleButtons $dlg | ForEach-Object { $_.Text })
            Assert (($vis -contains 'Uninstall') -and ($vis -contains 'Done')) "installed row offers Uninstall (visible: $($vis -join ', '))"
            Assert (-not ($vis -contains 'Set Up')) 'the undetected row offers no Set Up'

            # Uninstall, cancelled: honest confirm; Escape keeps everything.
            Assert (Invoke-AgentButton $dlg 'Uninstall') 'Uninstall pressable'
            $confirm = Wait-Class $gpid 'GhozttyConfirmDialog' $true 5000
            Assert ($confirm -ne [IntPtr]::Zero) 'Uninstall asks for confirmation first'
            if ($confirm -ne [IntPtr]::Zero) {
                Assert ((Get-TestWindowText -Window $confirm) -like 'Remove Ghoztty integration from Claude Code*') 'confirm title names the agent'
                $cbtns = Get-ButtonTexts $confirm
                Assert (($cbtns -contains 'Remove') -and ($cbtns -contains 'Cancel')) "confirm buttons are Remove / Cancel (got: $($cbtns -join ', '))"
                Send-TestControlKey -Control $confirm -Key Escape | Out-Null
                Wait-Class $gpid 'GhozttyConfirmDialog' $false | Out-Null
            }
            Assert (Test-Path (Join-Path $home1 '.claude\skills\ghoztty\SKILL.md')) 'a cancelled uninstall removes nothing'

            # Uninstall, confirmed. Enter defaults to Cancel (destructive
            # action), so Tab to Remove first.
            Assert (Invoke-AgentButton $dlg 'Uninstall') 'Uninstall pressable again'
            $confirm = Wait-Class $gpid 'GhozttyConfirmDialog' $true 5000
            if ($confirm -ne [IntPtr]::Zero) {
                Send-TestControlKey -Control $confirm -Key Tab | Out-Null
                Start-Sleep -Milliseconds 150
                Send-TestControlKey -Control $confirm -Key Enter | Out-Null
                Wait-Class $gpid 'GhozttyConfirmDialog' $false | Out-Null
            }
            Assert (Wait-AgentRowStatus $dlg 'Not set up') 'row flips to Not set up after Remove'
            # Managed FILES go; empty directories may stay (removeIfManaged
            # removes what it stamped, nothing else).
            $goneOk = $false
            for ($t = 0; $t -lt 50 -and -not $goneOk; $t++) {
                $goneOk = (-not (Test-Path (Join-Path $home1 '.claude\skills\ghoztty\SKILL.md'))) -and
                    (-not (Test-Path (Join-Path $home1 '.config\ghoztty\hooks\ghoztty-banner.sh')))
                Start-Sleep -Milliseconds 100
            }
            Assert $goneOk 'Remove clears the skills and the banner scripts (no other agent shares them)'

            # Set Up from the row: reinstall lands and the row flips back.
            Assert (Invoke-AgentButton $dlg 'Set Up') 'Set Up appears on the empty row and is pressable'
            Assert (Wait-AgentRowStatus $dlg 'Installed') 'row flips to Installed after Set Up'
            $backOk = $false
            for ($t = 0; $t -lt 50 -and -not $backOk; $t++) {
                $backOk = Test-Path (Join-Path $home1 '.claude\skills\ghoztty\SKILL.md')
                Start-Sleep -Milliseconds 100
            }
            Assert $backOk 'Set Up reinstalls the skills'

            # Close; corrupt a managed file; reopen: Update available, and
            # Update heals it.
            Send-TestControlKey -Control $dlg -Key Escape | Out-Null
            $goneDlg = Wait-Class $gpid 'GhozttyAgentIntegrations' $false
            Assert ($goneDlg -eq [IntPtr]::Zero) 'Escape closes the window'
            Assert (Test-TestWindowEnabled -Window $g.Top) 'owner window re-enabled on close'

            $bannerPath = Join-Path $home1 '.config\ghoztty\hooks\ghoztty-banner.sh'
            # Marked but stale: OURS to update, never a destructive set-up.
            Set-Content -Path $bannerPath -Value "#!/bin/sh`n# ghoztty-managed`necho old`n" -Encoding ascii -NoNewline

            if (Invoke-PaletteAgentSetup $g) {
                $dlg2 = Wait-Class $gpid 'GhozttyAgentIntegrations' $true 10000
                Assert ($dlg2 -ne [IntPtr]::Zero) 'window reopens from the palette'
                if ($dlg2 -ne [IntPtr]::Zero) {
                    Assert (Wait-AgentRowStatus $dlg2 'Update available') 'a corrupted managed file reads Update available'
                    $vis2 = @(Get-AgentVisibleButtons $dlg2 | ForEach-Object { $_.Text })
                    Assert (($vis2 -contains 'Update') -and ($vis2 -contains 'Uninstall')) "outdated row offers Update and Uninstall (visible: $($vis2 -join ', '))"
                    Assert (Invoke-AgentButton $dlg2 'Update') 'Update pressable'
                    Assert (Wait-AgentRowStatus $dlg2 'Installed') 'row flips back to Installed after Update'
                    $healed = $false
                    for ($t = 0; $t -lt 50 -and -not $healed; $t++) {
                        $healed = (Test-Path $bannerPath) -and ((Get-Content $bannerPath -Raw) -notmatch 'echo old')
                        Start-Sleep -Milliseconds 100
                    }
                    Assert $healed 'Update rewrites the stale managed file'
                    Send-TestControlKey -Control $dlg2 -Key Escape | Out-Null
                    Wait-Class $gpid 'GhozttyAgentIntegrations' $false | Out-Null
                }
            } else {
                Assert $false 'palette reopen injectable'
            }
        }
        Assert ((Get-StubLines).Count -eq 0) 'the management window spawns no claude CLI'
    }
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app alive after the management flow'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 5:
    # plugin migration, happy path. First-run already answered (pre-written
    # accepted), plugin registered -> the one-time switch-over offer.
    Install-FakePlugin
    # The app already wrote its own state for one pane: must NOT be
    # overwritten by the carried plugin state.
    New-Item -ItemType Directory -Force (Join-Path $home1 '.config\ghoztty\banner-state') | Out-Null
    Set-Content -Path (Join-Path $home1 '.config\ghoztty\banner-state\pane-xyz.json') -Value '{"title":"apps-own"}' -Encoding ascii -NoNewline
    $state5 = Join-Path $base 'state5'
    New-Item -ItemType Directory -Force $state5 | Out-Null
    Set-Content -Path (Join-Path $state5 'claude_setup') -Value 'accepted' -Encoding ascii -NoNewline

    $g = Launch-Gui $state5 $home1 'ok'
    $gpid = $g.Pid
    # The migration check sleeps 3s before posting.
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 12000
    Assert ($dlg -ne [IntPtr]::Zero) 'plugin on file + answered first-run shows the migration offer'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ((Get-TestWindowText -Window $dlg) -eq 'Ghoztty Now Manages Its Claude Integration') 'migration title names the switch-over'
        $btns = Get-ButtonTexts $dlg
        Assert (($btns -contains 'Switch Over') -and ($btns -contains 'Keep Plugin')) "buttons are Switch Over / Keep Plugin (got: $($btns -join ', '))"
        Send-TestControlKey -Control $dlg -Key Enter | Out-Null  # Switch Over is the Enter default
        $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
        Assert ($gone -eq [IntPtr]::Zero) 'Enter (Switch Over) dismisses the offer'
    }

    # Uninstall through the stub, cleanup, and the app install afterwards.
    $migrated = $false
    for ($t = 0; $t -lt 80 -and -not $migrated; $t++) {
        $migrated = (Test-Path (Join-Path $home1 '.config\ghoztty\banner-state\pane-abc.json')) -and
            (Test-Path (Join-Path $home1 '.claude\skills\ghoztty\SKILL.md'))
        Start-Sleep -Milliseconds 100
    }
    Assert $migrated 'migration carries banner state and installs the app integration'
    $lines = Get-StubLines
    Assert (@($lines | Where-Object { $_ -match 'plugin uninstall ghoztty@test-marketplace' }).Count -eq 1) 'uninstall ran through claude with the exact registration'
    Assert ((Get-Content (Join-Path $home1 '.config\ghoztty\banner-state\pane-xyz.json') -Raw) -eq '{"title":"apps-own"}') 'the app''s own newer state is never overwritten'
    Assert ((Get-Content (Join-Path $home1 '.config\ghoztty\banner-state\pane-abc.json') -Raw) -eq '{"title":"carried"}') 'the carried pane state arrives byte-identical'
    Assert (Test-Path (Join-Path $home1 '.claude\ghoztty-banner\pane-abc.json')) 'the plugin''s originals stay in place'
    Assert (-not (Test-Path (Join-Path $home1 '.claude\scripts\ghoztty-banner.sh'))) 'the stale byte-identical script copy is removed'
    $mstate = Join-Path $state5 'claude_plugin_migration'
    Assert ((Test-Path $mstate) -and ((Get-Content $mstate -Raw).Trim() -eq 'accepted')) 'migration answer records accepted'
    # Silent on success: no further dialog.
    Start-Sleep -Milliseconds 1500
    Assert ((Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'migration success shows no outcome dialog'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 6:
    # migration with a FAILING uninstall -> report, and nothing changed.
    Install-FakePlugin
    Clear-Content $stubLog -ErrorAction SilentlyContinue
    $state6 = Join-Path $base 'state6'
    New-Item -ItemType Directory -Force $state6 | Out-Null
    Set-Content -Path (Join-Path $state6 'claude_setup') -Value 'accepted' -Encoding ascii -NoNewline
    Remove-Item (Join-Path $home1 '.config\ghoztty\banner-state\pane-abc.json') -Force -ErrorAction SilentlyContinue

    $g = Launch-Gui $state6 $home1 'fail'
    $gpid = $g.Pid
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 12000
    Assert ($dlg -ne [IntPtr]::Zero) 'migration offer appears again for the fresh state dir'
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Enter | Out-Null
        # The failure dialog replaces the offer.
        $failDlg = [IntPtr]::Zero
        for ($t = 0; $t -lt 100 -and $failDlg -eq [IntPtr]::Zero; $t++) {
            Start-Sleep -Milliseconds 100
            $cand = Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog'
            if ($cand -ne [IntPtr]::Zero -and (Get-TestWindowText -Window $cand) -eq 'Could Not Remove the Plugin') { $failDlg = $cand }
        }
        Assert ($failDlg -ne [IntPtr]::Zero) 'a failed uninstall reports Could Not Remove the Plugin'
        if ($failDlg -ne [IntPtr]::Zero) {
            Send-TestControlKey -Control $failDlg -Key Escape | Out-Null
            Wait-Class $gpid 'GhozttyConfirmDialog' $false | Out-Null
        }
    }
    Assert (Test-Path (Join-Path $home1 '.claude\scripts\ghoztty-banner.sh')) 'failed uninstall leaves the script copy alone'
    Assert (-not (Test-Path (Join-Path $home1 '.config\ghoztty\banner-state\pane-abc.json'))) 'failed uninstall migrates nothing'
    Assert ((Get-Content $manifest -Raw) -match 'ghoztty@test-marketplace') 'failed uninstall leaves the manifest registered'
    $mstate6 = Join-Path $state6 'claude_plugin_migration'
    Assert ((Test-Path $mstate6) -and ((Get-Content $mstate6 -Raw).Trim() -eq 'accepted')) 'the answer is still recorded: answering retires the prompt, not succeeding'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 7:
    # no agent CLI in the sandbox: no prompt, nothing burned; palette
    # reports No Coding Agents Found.
    $home7 = Join-Path $base 'home-empty'
    New-Item -ItemType Directory -Force $home7 | Out-Null
    $state7 = Join-Path $base 'state7'
    $g = Launch-Gui $state7 $home7 'ok'
    $gpid = $g.Pid
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 4000
    Assert ($dlg -eq [IntPtr]::Zero) 'no agent CLI: no first-run prompt'
    Assert (-not (Test-Path (Join-Path $state7 'claude_setup'))) 'no agent CLI: prompt not burned (no state file)'

    $paletteOk = Invoke-PaletteAgentSetup $g
    Assert $paletteOk 'palette agent-integrations flow injectable (no-agent case)'
    if ($paletteOk) {
        $dlg = Wait-Class $gpid 'GhozttyAgentIntegrations' $true 10000
        Assert ($dlg -ne [IntPtr]::Zero) 'the management window opens with no agents installed'
        if ($dlg -ne [IntPtr]::Zero) {
            Assert (Wait-AgentRowStatus $dlg 'Not detected*Claude*') 'claude row reads Not detected'
            Assert (Wait-AgentRowStatus $dlg 'Not detected*Copilot*') 'copilot row reads Not detected'
            $vis = @(Get-AgentVisibleButtons $dlg | ForEach-Object { $_.Text })
            Assert (($vis -contains 'Done') -and ($vis.Count -eq 1)) "undetected rows offer no actions, only Done (visible: $($vis -join ', '))"
            Send-TestControlKey -Control $dlg -Key Escape | Out-Null
            $gone = Wait-Class $gpid 'GhozttyAgentIntegrations' $false
            Assert ($gone -eq [IntPtr]::Zero) 'the window dismisses'
        }
    }
    Assert (-not (Test-Path (Join-Path $state7 'claude_setup'))) 'opening the window burns no first-run state'
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

# A green run stamps the covered files (T783) so guard-due can answer "has
# this harness been run against the flow as it now stands?". Red leaves the
# stamp alone: red stays due. A -NegativeControl run must not stamp either —
# its passing assertions prove the harness discriminates, not the flow.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard claude-integration -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# A red script must exit 1 so a suite run cannot score it green.
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
