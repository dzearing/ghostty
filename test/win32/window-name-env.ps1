# Window-name env acceptance (tracker T492): every window's canonical IPC name
# is exported to its panes as $GHOZTTY_WINDOW_NAME - AUTO-named windows
# included, which is the half win32 was missing.
#
# The contract (docs/claude/cli.md "Naming"): a window opened WITHOUT an explicit
# --target (Ctrl+N, a bare `+new-window`, the launch window) still gets an auto
# name (`window-1`, ...) which is exported to its panes as
# $GHOZTTY_WINDOW_NAME. Before T492 only the `--target=` IPC path delivered the
# variable (IpcHandlers appends it to the surface overrides); every other pane
# fell through to the core's per-surface hex id, so a script inside such a pane
# had no way to name its own window. The fix bakes the name from
# `Window.ipc_name` (claimed in Window.init before the first surface exists)
# into the surface config env - the same seam GHOZTTY_PANE_ID rides - only when
# nothing upstream already set the variable, so explicit `--target`/`--env`
# values still win.
#
# All three auto-name paths converge on `createWindow(ipc_name=null)`: the GUI
# launch window, the Ctrl+N accelerator, and a target-less `+new-window`. The
# launch window and the bare `+new-window` are exercised here; Ctrl+N is the
# same code path (keyboard synthesis is dead on the off-desktop harness).
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: private
# IPC endpoint, per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN,
# and it only ever kills ghoztty / ghoztty-agent processes launched from the
# repo zig-out.
#
#   powershell -NoProfile -File test\win32\window-name-env.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-window-name-$PID"

# Auto window names are `window-N` (App.ipcNextWindowName).
$AUTO_RE = 'window-\d+'

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, so every Launch here
# used to put one across whatever the user was reading. The CLI calls stay on
# `Run-Cli`: none of the verbs they use can create a process.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
}

# Kill ONLY the zig-out GUI, leaving the local agent (and its PTYs) alive.
function Stop-GuiOnly {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        & taskkill.exe /F /T /PID $p.Id *> $null
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }
# Whitespace-stripped read: a MINIMIZED test window's split panes wrap one
# glyph per line, so content matches strip whitespace first. Window names are
# whitespace-free (`window-N`, our explicit names), so stripping stays exact.
function Stripped($f) { return ((Out-Text $f) -replace '\s', '') }

# ---- +list --json helpers --------------------------------------------------
function Get-List($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Get-Windows($tree) {
    if ($null -eq $tree) { return @() }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    return @($windows)
}
function Walk-Leaves($node) {
    $acc = @()
    if ($null -eq $node) { return $acc }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') {
        $acc += Walk-Leaves $node.left
        $acc += Walk-Leaves $node.right
    }
    return $acc
}
function Window-Leaves($w) {
    $acc = @()
    foreach ($t in @($w.tabs)) { $acc += Walk-Leaves $t.splits }
    return $acc
}
function Window-ByTarget($tree, $target) {
    return @(Get-Windows $tree | Where-Object { [string]$_.target -eq $target })[0]
}
# Poll until at least $count windows exist; returns the window array.
function Wait-Windows($tmp, $tag, $count, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $wins = @()
    while ((Get-Date) -lt $deadline) {
        $wins = @(Get-Windows (Get-List $tmp $tag))
        if ($wins.Count -ge $count) { return $wins }
        Start-Sleep -Milliseconds 500
    }
    return $wins
}

# ---- in-pane env probe (pane-id.ps1's, same harness-expansion trap) --------
# Both cmd (%VAR%) and PowerShell ($env:VAR) spellings are sent; whichever
# shell runs in the pane expands exactly one. The var is cleared from OUR env
# for the duration of the sends: `Run-Cli` goes through cmd.exe /c, which
# expands %VAR% against the HARNESS env before ghoztty sees the text - and this
# harness runs inside a Ghoztty pane, so $GHOZTTY_WINDOW_NAME IS in its env.
function Probe-PaneEnv($tmp, $target, $var, $valueRe, $tag, $timeoutSec = 25) {
    $mark = "WN$tag"
    $savedVar = [Environment]::GetEnvironmentVariable($var)
    if ($null -ne $savedVar) { Remove-Item "env:$var" -ErrorAction SilentlyContinue }
    Run-Cli "+send-keys --target=$target `"echo $mark=%$var%`" Enter" "$tmp\p1-$tag.txt" 12 | Out-Null
    Start-Sleep -Milliseconds 400
    Run-Cli "+send-keys --target=$target `"echo $mark=`$env:$var`" Enter" "$tmp\p2-$tag.txt" 12 | Out-Null
    if ($null -ne $savedVar) { Set-Item "env:$var" $savedVar }
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
        Run-Cli "+read --name=$target --lines=800" "$tmp\pr-$tag.txt" 15 | Out-Null
        $hay = Stripped "$tmp\pr-$tag.txt"
        $m = [regex]::Match($hay, "$mark=($valueRe)")
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# One hermetic GUI launch. On $restore we pass NO --title so restore rebuilds
# the recorded layout instead of opening a blank window.
function Launch($tmp, $title, $restore) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $launchArgs = @('--session-relaunch=rerun')
    if (-not $restore) { $launchArgs += "--title=$title" }
    [void](Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs)
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

# Private IPC endpoint FIRST (T441), then the T116 pre-flight.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'winname')
# T1033: a private pipe suffix moves the APP endpoint only - the agent pipe and
# the state files stay build-mode derived - so the exe about to be launched is
# checked for the -debug lineage before the first launch, not assumed.
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$preflight = Run-Cli '+list --json' "$root\preflight.json" 10
if ($preflight -eq 0) {
    "ABORT: an instance is already answering on this exe's IPC endpoint."
    "       Build zig-out\bin\ghoztty.exe in Debug and retry."
    exit 2
}

# The poison control: the launched app (and the agent, and every child) will
# INHERIT this from us. The pane's own baked value - applied last, like
# GHOZTTY_PANE_ID's - must win over it. Pre-T492 this is also exactly what an
# auto-named window's pane would have shown.
$poison = 'T492POISON'
$savedWindowName = $env:GHOZTTY_WINDOW_NAME
$env:GHOZTTY_WINDOW_NAME = $poison

# ============================================================================
"== A: the LAUNCH window (auto-named, the Ctrl+N code path) exports its name"
# ============================================================================
$tmpA = Join-Path $root 'a'
Launch $tmpA 't492-a' $false
$winsA = @(Wait-Windows $tmpA 'a0' 1 30)
Assert "A1 GUI opened its launch window" ($winsA.Count -ge 1)
Assert-GhozttyIsolated -Exe $Exe

$winA = if ($winsA.Count -ge 1) { $winsA[0] } else { $null }
$targetA = if ($null -ne $winA) { [string]$winA.target } else { '' }
Assert "A2 the launch window carries an auto target in +list --json" (
    $targetA -match "^$AUTO_RE$")

$paneA = if ($null -ne $winA) { [string](@(Window-Leaves $winA))[0].name } else { '' }
$envA = Probe-PaneEnv $tmpA $paneA 'GHOZTTY_WINDOW_NAME' $AUTO_RE 'a' 30
Assert 'A3 the pane shell exports an auto-shaped $GHOZTTY_WINDOW_NAME' (
    $envA -match "^$AUTO_RE$")
Assert "A4 the exported name IS the +list window target" (
    $envA -ne '' -and $targetA -ne '' -and $envA -eq $targetA)
Assert "A5 the pane's own name won over the inherited launcher value" (
    $envA -ne '' -and $envA -ne $poison)

# The point of the variable: the pane can address its OWN window with it.
$bannerA = 'T492BANNERA'
Run-Cli "+set-banner --target=$envA $bannerA" "$tmpA\banner.txt" 15 | Out-Null
$gotBannerA = ''
$deadlineA = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadlineA) {
    Start-Sleep -Milliseconds 700
    $wA = Window-ByTarget (Get-List $tmpA 'a2') $targetA
    $lA = if ($null -ne $wA) { @(Window-Leaves $wA)[0] } else { $null }
    if ($null -ne $lA -and [string]$lA.banner -ne '') { $gotBannerA = [string]$lA.banner; break }
}
Assert "A6 +set-banner --target=`$GHOZTTY_WINDOW_NAME reached this window's pane" (
    $gotBannerA -eq $bannerA)

# ============================================================================
"== B: a bare +new-window (no --target) exports ITS auto name; splits inherit"
# ============================================================================
Run-Cli '+new-window' "$tmpA\new.txt" 20 | Out-Null
$winsB = @(Wait-Windows $tmpA 'b0' 2 30)
Assert "B1 bare +new-window opened a second window" ($winsB.Count -ge 2)
$winB = @($winsB | Where-Object { [string]$_.target -ne $targetA -and [string]$_.target -match "^$AUTO_RE$" })[0]
$targetB = if ($null -ne $winB) { [string]$winB.target } else { '' }
Assert "B2 the new window carries its OWN auto target" (
    $targetB -match "^$AUTO_RE$" -and $targetB -ne $targetA)

$paneB = if ($null -ne $winB) { [string](@(Window-Leaves $winB))[0].name } else { '' }
$envB = Probe-PaneEnv $tmpA $paneB 'GHOZTTY_WINDOW_NAME' $AUTO_RE 'b' 30
Assert 'B3 the bare-window pane exports $GHOZTTY_WINDOW_NAME' ($envB -match "^$AUTO_RE$")
Assert "B4 it names THIS window, not the launch window" (
    $envB -ne '' -and $envB -eq $targetB)

# A split of the auto-named window (no --name) inherits the window's name.
Run-Cli "+split --target=$targetB --direction=right --name=bsplit" "$tmpA\split.txt" 20 | Out-Null
$deadlineB = (Get-Date).AddSeconds(20)
$haveSplit = $false
while ((Get-Date) -lt $deadlineB) {
    $wB2 = Window-ByTarget (Get-List $tmpA 'b1') $targetB
    if ($null -ne $wB2 -and @(Window-Leaves $wB2).Count -ge 2) { $haveSplit = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "B5 the auto-named window now has a split pane" $haveSplit
$envBs = Probe-PaneEnv $tmpA 'bsplit' 'GHOZTTY_WINDOW_NAME' $AUTO_RE 'bs' 30
Assert 'B6 the split pane exports the WINDOW name (not a pane/surface id)' (
    $envBs -ne '' -and $envBs -eq $targetB)

# ============================================================================
"== C: explicit values still win over the bake"
# ============================================================================
# (1) A --target window's panes export the target (the pre-T492 behavior that
# must not regress).
Run-Cli '+new-window --target=t492c' "$tmpA\newc.txt" 20 | Out-Null
$winsC = @(Wait-Windows $tmpA 'c0' 3 30)
$winC = Window-ByTarget (Get-List $tmpA 'c1') 't492c'
Assert "C1 the --target window exists" ($null -ne $winC)
$envC = Probe-PaneEnv $tmpA 't492c' 'GHOZTTY_WINDOW_NAME' 't492c' 'c' 30
Assert 'C2 its pane exports the explicit target name' ($envC -eq 't492c')

# (2) An explicit --env GHOZTTY_WINDOW_NAME on a target-less window beats the
# bake: the window is auto-named, but the pane sees the caller's value.
Run-Cli '+new-window --env=GHOZTTY_WINDOW_NAME=T492CUSTOM' "$tmpA\newd.txt" 20 | Out-Null
$winsD = @(Wait-Windows $tmpA 'd0' 4 30)
Assert "C3 the --env window opened" ($winsD.Count -ge 4)
$knownTargets = @($targetA, $targetB, 't492c')
$winD = @($winsD | Where-Object { $knownTargets -notcontains [string]$_.target })[0]
$paneD = if ($null -ne $winD) { [string](@(Window-Leaves $winD))[0].name } else { '' }
$envD = Probe-PaneEnv $tmpA $paneD 'GHOZTTY_WINDOW_NAME' 'T492CUSTOM' 'd' 30
Assert 'C4 an explicit --env GHOZTTY_WINDOW_NAME wins over the bake' (
    $envD -eq 'T492CUSTOM')

# ============================================================================
"== D: a restored pane still names the window it is NOW in"
# ============================================================================
# Kill ONLY the app; the agent keeps the shells (and their baked env) alive.
# Restore re-adopts each window's persisted name (T121), so the re-attached
# shell's variable must still match its window's +list target.
Stop-GuiOnly
Launch $tmpA 't492-d' $true
$winsE = @(Wait-Windows $tmpA 'e0' 4 45)
Assert "D1 restore rebuilt the windows" ($winsE.Count -ge 4)
$winE = Window-ByTarget (Get-List $tmpA 'e1') $targetB
Assert "D2 the auto-named window re-adopted its name '$targetB'" ($null -ne $winE)
$envE = Probe-PaneEnv $tmpA 'bsplit' 'GHOZTTY_WINDOW_NAME' $AUTO_RE 'e' 35
Assert 'D3 the re-attached split shell still exports that window name' (
    $envE -ne '' -and $envE -eq $targetB)

# ============================================================================
"== cleanup"
Stop-TestProcs
if ($null -ne $savedWindowName) { $env:GHOZTTY_WINDOW_NAME = $savedWindowName }
else { Remove-Item env:GHOZTTY_WINDOW_NAME -ErrorAction SilentlyContinue }
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

# --- stamp (T783) -----------------------------------------------------------
# A green run records this harness's own content so scripts\guard-due.ps1 can
# answer "has anyone run window-name-env against the script as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard window-name-env -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures
