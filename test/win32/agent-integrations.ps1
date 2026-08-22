# T872 acceptance: the whole agent-integration flow, end to end through the
# REAL app process, in a sandbox - install / idempotence / staleness /
# refusals / rollback / shared-banner refcount / uninstall exactness /
# migration ownership rules.
#
# RELATION TO claude-integration.ps1 (T870/T871). That harness proves the
# PROMPTS and the management window: first-run offer, decline remembered,
# palette window rows and buttons, migration happy/failing path. This one
# proves the INTEGRATION ENGINE'S behavior through the same app process for
# the scenarios the GUI cannot reach - the window offers exactly one action
# per state, so a second install onto a healthy tree (idempotence must
# REPORT up_to_date), an install onto a poisoned tree (typed refusals,
# rollback), and the two-agent banner-refcount walk have no GUI path at all.
#
# THE SEAM is the debug-only `agent-integration` IPC action
# (src/apprt/win32/ipc_agent_integration.zig), the capture-pane pattern: no
# CLI verb (the T141 cross-platform rule), reachable only over the IPC
# endpoint, only in a Debug/ReleaseSafe build - which is every build an
# acceptance script may run against anyway (T350). It calls the SAME service
# entry points the dialog's workers call, with home and probe resolved
# through the same GHOZTTY_AGENT_HOME override, so what this script drives
# is the app's own code path, not a parallel one.
#
# SANDBOXING. GHOZTTY_AGENT_HOME points the probe, the installers and the
# migration at a temp home - when set, the probe consults ONLY that home, so
# the box's real installs can never leak in. GHOZTTY_CLAUDE_STATE_DIR
# redirects the answer files, GHOZTTY_CLAUDE_EXE the migration's claude, and
# XDG_CONFIG_HOME the app config (T69). On top of the seams, a CANARY
# measures the claim instead of trusting it: the real user's integration
# surfaces (~\.claude settings/skills/plugins manifest, ~\.copilot,
# ~\.config\ghoztty\hooks) are manifest-hashed before the run and compared
# after - a run that touched them fails loudly.
#
# SECTIONS (the T872 floor):
#   A: fresh install for claude - banner+activity+skills land MARKED, and
#      the settings.json merge preserves the user's pre-seeded hooks.
#   B: idempotence - second install reports up_to_date, bytes identical.
#   C: staleness - a doctored marked file reads outdated; install upgrades
#      it back to the pristine bytes.
#   D: refusals, all typed, nothing altered - unmarked same-named skill
#      (NotManaged), unparseable settings.json (UnparseableConfig), reparse
#      point at a destination (ReparsePointRefused). Each is followed by a
#      recovery install proving the refusal came from the poison.
#   E: rollback - a poisoned last component fails the copilot install and
#      removes only what THAT call created; the pre-existing shared banner
#      and the whole claude install survive.
#   F: shared-banner refcount - both agents installed; removing one keeps
#      the scripts, removing both clears them; the user's settings.json
#      keeps its own hooks with Ghoztty's merged fragment gone.
#   G: uninstall exactness - user-added files in skills/ survive.
#   H: migration ownership - the arm claude-integration.ps1 does NOT cover:
#      a USER-owned ~\.claude\scripts\ghoztty-banner.sh (bytes differing
#      from every registered plugin copy) SURVIVES the accepted migration,
#      while the uninstall still runs and the state still carries.
#
# -NegativeControl inverts two load-bearing claims (the merge preserved the
# user's hooks; the refcounted banner is gone once no agent references it) -
# that run MUST fail, proving the oracles discriminate.
#
# T217: runs on a BACKGROUND Win32 desktop; the migration dialog reads raw
# WM_KEYDOWN in its own pump, so a POSTED Enter reaches it.
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
# instance answering the shared pipe cannot serve this run's requests.
$env:GHOZTTY_PIPE_SUFFIX = "-agentinteg$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
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

# ------------------------------------------------------------------- canary
# Manifest-hash of the REAL user's integration surfaces. Volatile trees the
# subsystem never touches (~\.claude\projects, banner-state) are excluded on
# purpose: live sessions write there and would false-fail the comparison.
function Get-CanaryManifest {
    $roots = @(
        (Join-Path $env:USERPROFILE '.claude\settings.json'),
        (Join-Path $env:USERPROFILE '.claude\skills'),
        (Join-Path $env:USERPROFILE '.claude\plugins\installed_plugins.json'),
        (Join-Path $env:USERPROFILE '.claude\scripts'),
        (Join-Path $env:USERPROFILE '.copilot'),
        (Join-Path $env:USERPROFILE '.config\ghoztty\hooks')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { $lines.Add("absent|$root"); continue }
        $item = Get-Item $root -Force
        if ($item.PSIsContainer) {
            Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName | ForEach-Object {
                    $lines.Add("$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)")
                }
        } else {
            $lines.Add("$($item.FullName)|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)")
        }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

# ------------------------------------------------------------------ helpers
function Invoke-AgentIpc([string]$op, [string]$agent) {
    $ipcArgs = @("--op=$op")
    if ($agent) { $ipcArgs += "--agent=$agent" }
    return Invoke-GhozttyIpc -Action 'agent-integration' -Arguments $ipcArgs
}

# The status row for one agent, or $null.
function Get-AgentStatus([string]$agent) {
    $r = Invoke-AgentIpc 'status' ''
    if ($null -eq $r -or -not $r.success) { return $null }
    foreach ($row in @($r.data.agents)) { if ($row.agent -eq $agent) { return $row } }
    return $null
}

# The install/uninstall outcome tag ('installed', 'up_to_date', ...), with a
# failed outcome rendered 'failed:<detail>' so refusal asserts see the type.
function Get-AgentOutcome([string]$op, [string]$agent) {
    $r = Invoke-AgentIpc $op $agent
    if ($null -eq $r) { return 'no-response' }
    if (-not $r.success) { return "error:$($r.error)" }
    if ($r.data.outcome -eq 'failed') { return "failed:$($r.data.detail)" }
    return "$($r.data.outcome)"
}

function Test-Marked([string]$path, [string]$marker) {
    if (-not (Test-Path $path)) { return $false }
    return ((Get-Content $path -Raw) -like "*$marker*")
}

# SHA-256 of each existing path, keyed by path.
function Get-Hashes([string[]]$paths) {
    $out = @{}
    foreach ($p in $paths) {
        if (Test-Path $p) { $out[$p] = (Get-FileHash $p -Algorithm SHA256).Hash }
        else { $out[$p] = 'absent' }
    }
    return $out
}

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

# ----------------------------------------------------------------- fixtures
$canaryBefore = Get-CanaryManifest

$base = Join-Path $env:TEMP 'ghoztty-t872'
Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $base | Out-Null

$cfgHome = Join-Path $base 'xdg'
New-Item -ItemType Directory -Force (Join-Path $cfgHome 'ghostty') | Out-Null
Set-Content -Path (Join-Path $cfgHome 'ghostty\config') -Value "# empty`n" -Encoding ascii

$sbHome = Join-Path $base 'home'
New-Item -ItemType Directory -Force (Join-Path $sbHome '.local\bin') | Out-Null
$stateDir = Join-Path $base 'state'
New-Item -ItemType Directory -Force $stateDir | Out-Null

# The stub claude: its presence in .local\bin (a probed location) is what
# makes claude "detected"; section H runs it as the migration's uninstaller.
$stubLog = Join-Path $base 'stub.log'
$manifest = Join-Path $sbHome '.claude\plugins\installed_plugins.json'
$emptyManifest = Join-Path $base 'empty_manifest.json'
Set-Content -Path $emptyManifest -Value '{"version":2,"plugins":{}}' -Encoding ascii
$stub = Join-Path $sbHome '.local\bin\claude.cmd'
@"
@echo off
>> "$stubLog" echo %*
if /i "%1"=="plugin" if /i "%2"=="uninstall" (
  copy /y "$emptyManifest" "$manifest" >nul
)
echo ok
exit /b 0
"@ | Set-Content -Path $stub -Encoding ascii

# Sandbox-home paths the engine manages.
$banner = Join-Path $sbHome '.config\ghoztty\hooks\ghoztty-banner.sh'
$activity = Join-Path $sbHome '.config\ghoztty\hooks\ghoztty-activity-state.sh'
$claudeSkill = Join-Path $sbHome '.claude\skills\ghoztty\SKILL.md'
$claudeSkillPf = Join-Path $sbHome '.claude\skills\process-feedback\SKILL.md'
$settings = Join-Path $sbHome '.claude\settings.json'
$copilotSkill = Join-Path $sbHome '.copilot\skills\ghoztty\SKILL.md'
$copilotHook = Join-Path $sbHome '.copilot\hooks\ghoztty.json'
$claudeManaged = @($banner, $activity, $claudeSkill, $claudeSkillPf, $settings)

function Launch-Gui([string]$setupMode) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_CLAUDE_SETUP = $setupMode
    $env:GHOZTTY_AGENT_HOME = $sbHome
    $env:GHOZTTY_CLAUDE_EXE = $stub
    $env:GHOZTTY_CLAUDE_STATE_DIR = $stateDir
    try {
        # persistence: every case relaunches the app; a restored layout would
        # hand a later case the previous case's panes.
        $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    } finally {
        'XDG_CONFIG_HOME', 'GHOZTTY_CLAUDE_SETUP', 'GHOZTTY_AGENT_HOME',
        'GHOZTTY_CLAUDE_EXE', 'GHOZTTY_CLAUDE_STATE_DIR' | ForEach-Object {
            Remove-Item "Env:$_" -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'GUI died at launch' -Label 'agent-integrations'
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'top window never appeared' -Label 'agent-integrations'
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    return @{ App = $app; Pid = $app.Pid; Top = $top }
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # App #1 serves sections A-G over IPC. GHOZTTY_CLAUDE_SETUP=0 keeps the
    # first-run prompt out of the way (that flow is claude-integration.ps1's).
    $g = Launch-Gui '0'
    $gpid = $g.Pid

    # --- wire sanity: the seam answers, and refuses malformed asks typed ---
    $st = Get-AgentStatus 'claude'
    if ($null -eq $st) {
        Write-TestAssertedNothing -Reason 'agent-integration status never answered' -Label 'agent-integrations'
    }
    Assert ($st.detected -eq $true) 'sandbox claude stub is detected by the probe'
    Assert ($st.state -eq 'not_installed') 'fresh sandbox reads not_installed'
    $stCop = Get-AgentStatus 'copilot'
    Assert ($stCop.detected -eq $false) 'copilot (no stub yet) is NOT detected - detection discriminates'
    $bad = Invoke-GhozttyIpc -Action 'agent-integration' -Arguments @('--op=explode')
    Assert ($bad -and -not $bad.success -and "$($bad.error)" -like '*--op must be*') 'a bad op is refused with its reason'
    $noAgent = Invoke-GhozttyIpc -Action 'agent-integration' -Arguments @('--op=install')
    Assert ($noAgent -and -not $noAgent.success -and "$($noAgent.error)" -like '*--agent=*') 'install without --agent is refused with its reason'

    # ------------------------------------------------------- A: fresh install
    # Pre-seeded USER settings.json: the merge must preserve both hooks the
    # user already had and unrelated top-level keys.
    New-Item -ItemType Directory -Force (Join-Path $sbHome '.claude') | Out-Null
    $userSettings = '{"model":"user-picked-model","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"echo user-own-hook"}]}]}}'
    Set-Content -Path $settings -Value $userSettings -Encoding ascii -NoNewline

    Assert ((Get-AgentOutcome 'install' 'claude') -eq 'installed') 'A: fresh claude install reports installed'
    Assert (Test-Marked $banner '# ghoztty-managed') 'A: banner script lands marked'
    Assert (Test-Marked $activity '# ghoztty-managed') 'A: activity-state script lands marked'
    Assert (Test-Marked $claudeSkill '<!-- ghoztty-managed -->') 'A: ghoztty skill lands marked'
    Assert (Test-Marked $claudeSkillPf '<!-- ghoztty-managed -->') 'A: process-feedback skill lands marked'
    $merged = if (Test-Path $settings) { Get-Content $settings -Raw } else { '' }
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the merge DROPPED the user hooks - this run MUST fail'
        Assert (-not ($merged -like '*user-own-hook*')) 'A(neg): merge dropped the user hooks (inverted)'
    } else {
        Assert ($merged -like '*user-own-hook*') 'A: settings merge preserves the pre-seeded user hook'
    }
    Assert ($merged -like '*user-picked-model*') 'A: settings merge preserves unrelated user keys'
    Assert ($merged -like '*.config/ghoztty/hooks*') 'A: settings merge added the Ghoztty fragment'
    Assert ((Get-AgentStatus 'claude').state -eq 'installed') 'A: status now reads installed'
    # Marker-oracle positive control: an unmarked file must NOT read marked.
    $plain = Join-Path $base 'plain.txt'
    Set-Content -Path $plain -Value 'no marker here' -Encoding ascii
    Assert (-not (Test-Marked $plain '# ghoztty-managed')) 'A: marker oracle reports an unmarked file unmarked (control)'

    # -------------------------------------------------------- B: idempotence
    $baseline = Get-Hashes $claudeManaged
    Assert ((Get-AgentOutcome 'install' 'claude') -eq 'up_to_date') 'B: second install reports up_to_date'
    $after = Get-Hashes $claudeManaged
    $identical = $true
    foreach ($p in $claudeManaged) { if ($baseline[$p] -ne $after[$p]) { $identical = $false } }
    Assert $identical 'B: second install is byte-identical across every managed file'

    # ---------------------------------------------------------- C: staleness
    # Marked but different bytes = OURS and stale. The hash oracle's own
    # control: the doctoring must CHANGE the hash B just baselined.
    Set-Content -Path $banner -Value "#!/bin/sh`n# ghoztty-managed`necho old`n" -Encoding ascii -NoNewline
    Assert ((Get-Hashes @($banner))[$banner] -ne $baseline[$banner]) 'C: doctoring changed the banner hash (hash-oracle control)'
    Assert ((Get-AgentStatus 'claude').state -eq 'outdated') 'C: a doctored marked file reads outdated'
    Assert ((Get-AgentOutcome 'install' 'claude') -eq 'upgraded') 'C: install over a stale file reports upgraded'
    Assert ((Get-Hashes @($banner))[$banner] -eq $baseline[$banner]) 'C: the upgrade restored the pristine bytes'

    # ----------------------------------------------------------- D: refusals
    # Save/restore is BYTE-exact ([IO.File]): Get/Set-Content re-encodes
    # UTF-8 through the ANSI codepage on PS 5.1, and a restored file that is
    # "ours but different" turns the recovery control into `upgraded`.
    # D1: an unmarked file at a skill's path is the USER'S; refused, untouched.
    $savedSkill = [System.IO.File]::ReadAllBytes($claudeSkill)
    Set-Content -Path $claudeSkill -Value '# my own skill' -Encoding ascii -NoNewline
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'failed:NotManaged') "D1: unmarked same-named skill refuses typed (got $got)"
    Assert ((Get-Content $claudeSkill -Raw) -eq '# my own skill') 'D1: the user file survives byte-identical'
    [System.IO.File]::WriteAllBytes($claudeSkill, $savedSkill)
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'up_to_date') "D1: recovery install succeeds - the refusal was the poison (control; got $got)"

    # D2: unparseable settings.json refuses typed; the broken file is the
    # user's to fix, never rewritten.
    $savedSettings = [System.IO.File]::ReadAllBytes($settings)
    Set-Content -Path $settings -Value '{not json at all' -Encoding ascii -NoNewline
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'failed:UnparseableConfig') "D2: unparseable settings.json refuses typed (got $got)"
    Assert ((Get-Content $settings -Raw) -eq '{not json at all') 'D2: the broken settings file is untouched'
    [System.IO.File]::WriteAllBytes($settings, $savedSettings)
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'up_to_date') "D2: recovery install succeeds (control; got $got)"

    # D3: a reparse point where a managed file goes is never written through.
    # Two arms, mirroring the managed_file unit tests. A directory JUNCTION
    # is unreadable as a file, so the marker guard's pre-read refuses it as
    # "present but unreadable" (WriteFailed) before the reparse check can
    # name it; a FILE symlink reads fine through the link and is refused by
    # the no-follow write itself (ReparsePointRefused). Both are typed, and
    # in both nothing is altered.
    $junkTarget = Join-Path $base 'junk-target'
    New-Item -ItemType Directory -Force $junkTarget | Out-Null
    Set-Content -Path (Join-Path $junkTarget 'canary.txt') -Value 'untouched' -Encoding ascii
    Remove-Item $banner -Force
    cmd /c mklink /J "$banner" "$junkTarget" | Out-Null
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'failed:WriteFailed') "D3: a junction at a destination refuses typed, never overwritten blind (got $got)"
    Assert ((Get-Content (Join-Path $junkTarget 'canary.txt') -Raw) -like 'untouched*') 'D3: the junction target is untouched'
    cmd /c rmdir "$banner" | Out-Null
    # `upgraded`, not `installed`: the activity-state sibling is still there,
    # and a partially-present banner component deliberately reads outdated -
    # ours to refresh (BannerScriptInstaller.state).
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'upgraded') "D3: recovery install rewrites the missing banner (control; got $got)"

    # D3b: the readable-reparse arm needs a real file symlink, which needs
    # Developer Mode / SeCreateSymbolicLink on this box.
    Remove-Item $banner -Force
    $realCopy = Join-Path $base 'banner-real.sh'
    Set-Content -Path $realCopy -Value "#!/bin/sh`n# ghoztty-managed`necho aside`n" -Encoding ascii -NoNewline
    $symlinkOk = $true
    try {
        New-Item -ItemType SymbolicLink -Path $banner -Target $realCopy -ErrorAction Stop | Out-Null
    } catch { $symlinkOk = $false }
    if ($symlinkOk) {
        $got = Get-AgentOutcome 'install' 'claude'
        Assert ($got -eq 'failed:ReparsePointRefused') "D3b: a file symlink at a destination refuses typed (got $got)"
        Assert ((Get-Content $realCopy -Raw) -like '*echo aside*') 'D3b: the symlink target was not written through'
        Remove-Item $banner -Force
    } else {
        Write-Host 'SKIP  D3b: no symlink privilege on this box (managed_file/HookComponent unit tests pin ReparsePointRefused)'
        $script:skipped++
    }
    $got = Get-AgentOutcome 'install' 'claude'
    Assert ($got -eq 'upgraded') "D3b: banner restored for the sections ahead (got $got)"

    # ----------------------------------------------------------- E: rollback
    # Copilot appears (stub binary) with the USER'S own file where the LAST
    # component (hooks) writes: banner and skills get created, hooks refuses,
    # and the rollback removes only what this call created.
    Set-Content -Path (Join-Path $sbHome '.local\bin\copilot.exe') -Value '' -Encoding ascii -NoNewline
    New-Item -ItemType Directory -Force (Join-Path $sbHome '.copilot\hooks') | Out-Null
    Set-Content -Path $copilotHook -Value '{"mine":true}' -Encoding ascii -NoNewline
    Assert ((Get-AgentStatus 'copilot').detected -eq $true) 'E: copilot stub is now detected'
    Assert ((Get-AgentOutcome 'install' 'copilot') -eq 'failed:NotManaged') 'E: poisoned last component fails the install typed'
    Assert (-not (Test-Path $copilotSkill)) 'E: the rollback removed the skills THIS call created'
    Assert ((Get-Content $copilotHook -Raw) -eq '{"mine":true}') 'E: the user hook file survives byte-identical'
    Assert (Test-Path $banner) 'E: the PRE-EXISTING shared banner survives the rollback'
    Assert (Test-Path $claudeSkill) 'E: the claude install is untouched by the copilot failure'

    # --------------------------------------------- F: shared-banner refcount
    Remove-Item -Recurse -Force (Join-Path $sbHome '.copilot')
    Assert ((Get-AgentOutcome 'install' 'copilot') -eq 'installed') 'F: clean copilot install succeeds (E control: the poison was the failure)'
    $stC = Get-AgentStatus 'claude'
    Assert ($stC.banner_shared -eq $true) 'F: claude reports the banner shared with another agent'
    Assert ((Get-AgentOutcome 'uninstall' 'copilot') -eq 'uninstalled') 'F: copilot uninstall reports uninstalled'
    Assert (Test-Path $banner) 'F: the shared banner SURVIVES while claude still references it'
    Assert (-not (Test-Path $copilotHook)) 'F: copilot own hook file is gone'
    Assert (-not (Test-Path $copilotSkill)) 'F: copilot own skills are gone'
    Assert ((Get-AgentOutcome 'uninstall' 'claude') -eq 'uninstalled') 'F: claude uninstall reports uninstalled'
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the unreferenced banner SURVIVES - this run MUST fail'
        Assert (Test-Path $banner) 'F(neg): unreferenced banner survives (inverted)'
    } else {
        Assert (-not (Test-Path $banner)) 'F: the banner goes once NO agent references it'
    }
    Assert (-not (Test-Path $activity)) 'F: the activity-state script goes with it'
    $afterUn = Get-Content $settings -Raw
    Assert ($afterUn -like '*user-own-hook*') 'F: the user own hooks survive the fragment removal'
    Assert (-not ($afterUn -like '*.config/ghoztty/hooks*')) 'F: the Ghoztty fragment is gone from settings.json'

    # -------------------------------------------- G: uninstall exactness
    Assert ((Get-AgentOutcome 'install' 'claude') -eq 'installed') 'G: reinstall claude for the exactness walk'
    New-Item -ItemType Directory -Force (Join-Path $sbHome '.claude\skills\my-own-skill') | Out-Null
    Set-Content -Path (Join-Path $sbHome '.claude\skills\my-own-skill\SKILL.md') -Value '# mine' -Encoding ascii -NoNewline
    Set-Content -Path (Join-Path $sbHome '.claude\skills\notes.md') -Value 'user notes' -Encoding ascii -NoNewline
    Assert ((Get-AgentOutcome 'uninstall' 'claude') -eq 'uninstalled') 'G: uninstall reports uninstalled'
    Assert (-not (Test-Path $claudeSkill)) 'G: the managed skill file is gone'
    Assert ((Get-Content (Join-Path $sbHome '.claude\skills\my-own-skill\SKILL.md') -Raw) -eq '# mine') 'G: a user-added skill in skills/ survives'
    Assert ((Get-Content (Join-Path $sbHome '.claude\skills\notes.md') -Raw) -eq 'user notes') 'G: a loose user file in skills/ survives'

    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------- H: migration ownership rules
    # The arm claude-integration.ps1 does NOT cover: the plugin-era script
    # copy holds the USER'S bytes (matching no registered install), so the
    # accepted migration must LEAVE it while still uninstalling the plugin
    # and carrying the banner state.
    $cacheDir = Join-Path $sbHome '.claude\plugins\cache\test-marketplace\ghoztty\0.8.0'
    New-Item -ItemType Directory -Force (Join-Path $cacheDir 'hooks') | Out-Null
    Set-Content -Path (Join-Path $cacheDir 'hooks\ghoztty-banner.sh') -Value "#!/bin/bash`necho plugin banner`n" -Encoding ascii -NoNewline
    $escaped = $cacheDir -replace '\\', '\\'
    New-Item -ItemType Directory -Force (Split-Path $manifest) | Out-Null
    Set-Content -Path $manifest -Value "{`"version`":2,`"plugins`":{`"ghoztty@test-marketplace`":[{`"installPath`":`"$escaped`"}]}}" -Encoding ascii
    New-Item -ItemType Directory -Force (Join-Path $sbHome '.claude\scripts') | Out-Null
    $userScript = "#!/bin/bash`necho my heavily customized banner`n"
    Set-Content -Path (Join-Path $sbHome '.claude\scripts\ghoztty-banner.sh') -Value $userScript -Encoding ascii -NoNewline
    New-Item -ItemType Directory -Force (Join-Path $sbHome '.claude\ghoztty-banner') | Out-Null
    Set-Content -Path (Join-Path $sbHome '.claude\ghoztty-banner\pane-a.json') -Value '{"title":"carried"}' -Encoding ascii -NoNewline
    # First-run already answered; migration unanswered.
    Set-Content -Path (Join-Path $stateDir 'claude_setup') -Value 'accepted' -Encoding ascii -NoNewline
    Remove-Item (Join-Path $stateDir 'claude_plugin_migration') -Force -ErrorAction SilentlyContinue

    $g = Launch-Gui 'force'
    $gpid = $g.Pid
    # The migration check sleeps 3s before posting.
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 12000
    Assert ($dlg -ne [IntPtr]::Zero) 'H: the migration offer appears'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ((Get-TestWindowText -Window $dlg) -eq 'Ghoztty Now Manages Its Claude Integration') 'H: offer title verified before any key is sent'
        Send-TestControlKey -Control $dlg -Key Enter | Out-Null  # Switch Over is the Enter default
        Wait-Class $gpid 'GhozttyConfirmDialog' $false | Out-Null
    }
    $migrated = $false
    for ($t = 0; $t -lt 80 -and -not $migrated; $t++) {
        $migrated = (Test-Path (Join-Path $sbHome '.config\ghoztty\banner-state\pane-a.json')) -and
            (Test-Path $claudeSkill)
        Start-Sleep -Milliseconds 100
    }
    Assert $migrated 'H: migration carries the banner state and installs the app integration'
    $lines = @()
    if (Test-Path $stubLog) { $lines = @(Get-Content $stubLog | Where-Object { $_.Trim() -ne '' }) }
    Assert (@($lines | Where-Object { $_ -match 'plugin uninstall ghoztty@test-marketplace' }).Count -eq 1) 'H: the uninstall ran through claude with the exact registration'
    $scriptAfter = Join-Path $sbHome '.claude\scripts\ghoztty-banner.sh'
    Assert ((Test-Path $scriptAfter) -and ((Get-Content $scriptAfter -Raw) -eq $userScript)) 'H: the USER-owned script copy SURVIVES the migration byte-identical'
    $mstate = Join-Path $stateDir 'claude_plugin_migration'
    Assert ((Test-Path $mstate) -and ((Get-Content $mstate -Raw).Trim() -eq 'accepted')) 'H: the migration answer records accepted'
    Start-Sleep -Milliseconds 1500
    Assert ((Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'H: success stays silent - no outcome dialog'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Kill-RepoInstances
    if ($td) { Remove-TestDesktop $td }
    Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}

# --------------------------------------------------- the canary, measured
$canaryAfter = Get-CanaryManifest
Assert ($canaryAfter -eq $canaryBefore) 'the real user integration surfaces are bit-for-bit undisturbed (canary)'

# ------------------------------------------------- foreground discipline
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A green run stamps the covered files (T783). Red leaves the stamp alone;
# a -NegativeControl run proves the harness discriminates, not the flow, so
# it must not stamp either.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-integrations -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'agent-integrations'
