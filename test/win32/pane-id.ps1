# Pane-identity acceptance (tracker T113): win32 honors docs/claude/cli.md's "Pane
# identity" contract.
#
# The contract: every pane has a stable, ghoztty-owned UUID that is
#   (a) exported to the pane's processes as $GHOZTTY_PANE_ID,
#   (b) reported as the `+list --json` leaf `id` (Mac golden shape),
#   (c) accepted directly by every --target/--name, case-insensitive, with NO
#       prior registration or `+list`, and
#   (d) STABLE for the pane's whole life - across app relaunch/re-attach and
#       across an agent restart that RELAUNCHes the session.
#
# Before T113 win32 had none of it: the id was never exported, the leaf `id`
# was the decimal surface id (freshly randomized on every re-attach), and the
# `0x...` spelling that IS in the pane's env ($GHOSTTY_SURFACE_ID) was
# rejected as a target. T112's /reset-context fix had to carry a three-step
# fallback chain because of that, which is why (c) also asserts the two LEGACY
# spellings still resolve - old panes keep the env their shell was baked with
# across an upgrade, so those aliases can never be dropped.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out.
# Pre-flight (T116 lesson): if anything already answers on the endpoint this
# exe would use, abort BEFORE touching a window - a release-build exe collides
# with the user's live instance and this script would drive it.
#
#   powershell -NoProfile -File test\win32\pane-id.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, so every Launch here
# used to put one across whatever the user was reading. The CLI calls below stay
# on `Run-Cli`: `+list`, `+read`, `+send-keys`, `+split` and `+set-banner` cannot
# create a process, so none of them can put a window anywhere.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-pane-id-$PID"

# The canonical pane-id shape: 8-4-4-4-12 hex (src/apprt/win32/pane_id.zig).
$UUID_RE = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
# The verbatim $GHOSTTY_SURFACE_ID spelling core bakes (0x + 16 hex).
$SURFID_RE = '0x[0-9a-fA-F]{16}'

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

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
# taskkill /F /T on timeout so an orphaned CLI child can't keep the redirect
# file open and fabricate later failures (the T111b harness trap).
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
# glyph per line, so every content match strips whitespace first (the same
# technique session-open/session-reattach use). Our patterns are fixed-shape
# hex, so stripping stays exact.
function Stripped($f) { return ((Out-Text $f) -replace '\s', '') }

# ---- +list --json helpers --------------------------------------------------
function Get-List($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
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
function All-Leaves($tree) {
    $acc = @()
    if ($null -eq $tree) { return $acc }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) { $acc += Walk-Leaves $t.splits }
    }
    return $acc
}
function Leaf-ByName($tree, $name) {
    return @(All-Leaves $tree | Where-Object { $_.name -eq $name })[0]
}
# Poll until at least $count terminal leaves exist; returns the leaf array.
function Wait-Leaves($tmp, $tag, $count, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $leaves = @()
    while ((Get-Date) -lt $deadline) {
        $leaves = @(All-Leaves (Get-List $tmp $tag))
        if ($leaves.Count -ge $count) { return $leaves }
        Start-Sleep -Milliseconds 500
    }
    return $leaves
}

# ---- in-pane env probe -----------------------------------------------------
# Ask the SHELL RUNNING INSIDE the pane to print an env var, and return what it
# printed. This is the only assert that proves the variable actually reached
# the child process (rather than merely being resolvable app-side).
#
# Both cmd (%VAR%) and PowerShell ($env:VAR) spellings are sent because the
# pane's shell depends on the box's `command-shell` config: whichever shell is
# running expands exactly one of them and prints the other literally, so the
# value-shaped regex picks the real one out. The command ECHO itself never
# matches ($UUID_RE cannot match "%GHOZTTY_PANE_ID%").
#
# The line counts are deliberately huge: a split pane inside a MINIMIZED test
# window has a near-zero client rect and wraps ONE GLYPH PER LINE, so a ~40
# character probe costs ~40 scrollback lines. Reading only the default tail
# silently loses the answer (this cost the first run of this script).
#
# THE TRAP THIS FUNCTION EXISTS TO AVOID (cost the first validation run 4 of its
# ~35 asserts, all of them FABRICATED): `Run-Cli` reaches ghoztty through
# `cmd.exe /c`, and cmd expands `%VAR%` against the HARNESS's OWN environment
# before ghoztty ever sees the text. So `echo $mark=%GHOZTTY_PANE_ID%` arrives
# at the pane already substituted with whatever the harness inherited from the
# Ghoztty pane it was started in - the pane then faithfully echoes a foreign
# value and the assert reads it as the pane's own. That is precisely how section
# F's poison (which is deliberately IN the harness env) came back as "the
# inherited id won", and how section C read the harness's $GHOSTTY_SURFACE_ID
# instead of the pane's. An UNDEFINED var passes through cmd untouched, so we
# clear the var from OUR env for the duration of the two sends and restore it
# after (section F needs the poison in the env at LAUNCH time, not here).
function Probe-PaneEnv($tmp, $target, $var, $valueRe, $tag, $timeoutSec = 25) {
    $mark = "PP$tag"
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

# Send a whitespace-free marker to $target and confirm it comes back from
# READING $expectPane (usually the same target - that is the point).
function Marker-LandsIn($tmp, $target, $expectPane, $tag, $timeoutSec = 20) {
    $mark = "PM$tag"
    Run-Cli "+send-keys --target=$target `"echo $mark`" Enter" "$tmp\m-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600
        Run-Cli "+read --name=$expectPane --lines=400" "$tmp\mr-$tag.txt" 15 | Out-Null
        if ((Stripped "$tmp\mr-$tag.txt") -match $mark) { return $true }
    }
    return $false
}

# One hermetic GUI launch. On $restore we pass NO --title so restore rebuilds
# the recorded layout instead of opening a blank window.
function Launch($tmp, $title, $restore) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $launchArgs = @('--session-relaunch=rerun')
    if (-not $restore) { $launchArgs += "--title=$title" }
    # persistence: on (default), into a throwaway $env:LOCALAPPDATA - the restore leg is what proves the pane id is stable. Launch-NoPersist is the =false twin.
    [void](Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs)
}

# A launch with session persistence OFF: plain exec (ConPTY) panes, no agent.
function Launch-NoPersist($tmp, $title) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty') | Out-Null
    $env:LOCALAPPDATA = $tmp
    Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false', "--title=$title"))
}

# ---- manifest helpers (debug lineage writes the -debug filename) -----------
function Read-Manifest($tmp) {
    $p = Join-Path $tmp 'ghoztty\session-layout-debug.json'
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}
function Manifest-Leaves($m) {
    $acc = @()
    if ($null -eq $m) { return $acc }
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) { if ($null -ne $n.leaf) { $acc += $n.leaf } }
        }
    }
    return $acc
}
function Wait-ManifestPaneIds($tmp, $count, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $ids = @()
    while ((Get-Date) -lt $deadline) {
        $ids = @(Manifest-Leaves (Read-Manifest $tmp) |
            Where-Object { $null -ne $_.pane_id } | ForEach-Object { $_.pane_id })
        if ($ids.Count -ge $count) { return $ids }
        Start-Sleep -Milliseconds 400
    }
    return $ids
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

# T441: a private IPC endpoint FIRST. Without it the pre-flight below was not
# just unhelpful but actively misleading: run from one of the user's own panes,
# the inherited `$GHOZTTY_IPC_SOCKET` means their installed release always
# answers, so the pre-flight aborted every run on this box with exit 2 — a
# harness that can never run reads as a broken build. The suffix moves BOTH
# ends (the CLI dials it and the instance we launch binds it), which is what
# makes the pre-flight mean what its comment says.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'paneid')
# T1033: a private pipe suffix moves the APP endpoint only - the agent pipe and
# the state files stay build-mode derived - so the exe about to be launched is
# checked for the -debug lineage before the first launch, not assumed.
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# T116 pre-flight: anything already answering means this exe's endpoints are
# shared with a live instance (a release-build exe collides with the user's).
# Abort before a single window is touched.
$preflight = Run-Cli '+list --json' "$root\preflight.json" 10
if ($preflight -eq 0) {
    "ABORT: an instance is already answering on this exe's IPC endpoint."
    "       This harness drives whatever answers, so it would drive that one."
    "       A RELEASE-build exe cannot be graded here (it shares the user's"
    "       endpoints); build zig-out\bin\ghoztty.exe in Debug and retry."
    exit 2
}

# ============================================================================
"== A: the id is baked into the pane, and is the +list leaf id"
# ============================================================================
$tmpA = Join-Path $root 'a'
Launch $tmpA 't113-a' $false
$leavesA = @(Wait-Leaves $tmpA 'a1' 1 30)
Assert "A1 GUI opened a pane" ($leavesA.Count -ge 1)
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe
$leaf0 = if ($leavesA.Count -ge 1) { $leavesA[0] } else { $null }
$listId = if ($null -ne $leaf0) { [string]$leaf0.id } else { '' }

# (b) Mac golden shape: the leaf id is the pane UUID, not the decimal surface
# id it used to be.
Assert "A2 +list --json leaf id is a pane UUID (Mac golden shape)" ($listId -match "^$UUID_RE$")

# (a) The definitive assert: the SHELL INSIDE the pane has the variable.
$paneName = if ($null -ne $leaf0) { [string]$leaf0.name } else { '' }
$envId = Probe-PaneEnv $tmpA $paneName 'GHOZTTY_PANE_ID' $UUID_RE 'a' 30
Assert 'A3 the pane shell exports $GHOZTTY_PANE_ID' ($envId -match "^$UUID_RE$")
Assert "A4 the baked id IS the +list leaf id" (
    $envId -ne '' -and $listId -ne '' -and $envId.ToLower() -eq $listId.ToLower())

# (c) The id resolves as a target, and case does not matter.
Assert "A5 --target=<pane id> resolves for +send-keys/+read" (
    $envId -ne '' -and (Marker-LandsIn $tmpA $envId $envId 'a5' 25))
Assert "A6 the lowercased id resolves too (case-insensitive)" (
    $envId -ne '' -and (Marker-LandsIn $tmpA $envId.ToLower() $envId.ToUpper() 'a6' 25))

# ---- T153: `+list --pid` works on a persistence-on box ---------------------
# This launch IS persistence-on (agent-backed panes), which is the default
# config and was the broken case: the shell is a child of ghoztty-agent, not of
# the app, so the app used to report pid 0 for every pane and the documented
# `--pid` self-identification route always failed. The agent reports each
# session's child pid in its OPENED/ATTACHED replies; +list must carry it and
# --pid must walk ancestry against it.
$leafPid = 0
$deadlinePid = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadlinePid) {
    $lp = Leaf-ByName (Get-List $tmpA 'a7') $paneName
    if ($null -ne $lp -and [int]$lp.pid -gt 0) { $leafPid = [int]$lp.pid; break }
    Start-Sleep -Milliseconds 500
}
Assert "A7 +list --json reports a non-zero pid for an agent-backed pane (T153)" (
    $leafPid -gt 0)
$codeA8 = Run-Cli "+list --pid=$leafPid" "$tmpA\pid-a8.txt" 12
Assert "A8 +list --pid=<pid inside the pane> answers this pane's name" (
    $codeA8 -eq 0 -and $paneName -ne '' -and
    (Stripped "$tmpA\pid-a8.txt") -match [regex]::Escape(($paneName -replace '\s', '')))
# The no-match error must exit 1 AND name the route that always works. Pid 4
# is the System process: alive, and never inside any pane.
$codeA9 = Run-Cli '+list --pid=4' "$tmpA\pid-a9.txt" 12
Assert "A9 --pid no-match exits 1 and names GHOZTTY_PANE_ID as the route" (
    $codeA9 -eq 1 -and (Out-Text "$tmpA\pid-a9.txt") -match 'GHOZTTY_PANE_ID')

Stop-TestProcs

# ============================================================================
"== B: the id names ONE pane in a multi-pane window (the window-name trap)"
# ============================================================================
# A window-scoped name (GHOZTTY_PANE_NAME holds the WINDOW name for
# +new-window panes - the T112 finding) picks the FOCUSED pane, so it cannot
# tell two panes apart. The pane id must.
$tmpB = Join-Path $root 'b'
Launch $tmpB 't113-b' $false
$leavesB = @(Wait-Leaves $tmpB 'b0' 1 30)
Assert "B1 GUI opened its first pane" ($leavesB.Count -ge 1)
Run-Cli '+split --direction=right --name=bsplit' "$tmpB\split.txt" 20 | Out-Null
$leavesB = @(Wait-Leaves $tmpB 'b1' 2 25)
Assert "B2 the window now has two panes" ($leavesB.Count -ge 2)

# `bsplit` is a REGISTERED name, so `+list` never auto-registers that pane's
# id - resolving it exercises the no-registration path the contract promises.
$idSplit = Probe-PaneEnv $tmpB 'bsplit' 'GHOZTTY_PANE_ID' $UUID_RE 'b1' 30
$firstName = @($leavesB | Where-Object { $_.name -ne 'bsplit' })[0].name
$idFirst = Probe-PaneEnv $tmpB $firstName 'GHOZTTY_PANE_ID' $UUID_RE 'b2' 30
Assert "B3 both panes export an id" (
    $idSplit -match "^$UUID_RE$" -and $idFirst -match "^$UUID_RE$")
Assert "B4 the two panes have DIFFERENT ids" (
    $idSplit -ne '' -and $idFirst -ne '' -and $idSplit.ToLower() -ne $idFirst.ToLower())
Assert "B5 an unregistered pane id resolves with no prior +list registration" (
    $idSplit -ne '' -and (Marker-LandsIn $tmpB $idSplit 'bsplit' 'b5' 25))

# +set-banner targeted by pane id must decorate THAT pane only (banners are
# per-pane; `+list --json` carries the banner source additively, T35).
$bannerText = 'T113BANNER'
Run-Cli "+set-banner --target=$idSplit $bannerText" "$tmpB\banner.txt" 15 | Out-Null
Start-Sleep -Milliseconds 800
$treeB = Get-List $tmpB 'b2'
$lSplit = Leaf-ByName $treeB 'bsplit'
$lFirst = Leaf-ByName $treeB $firstName
Assert "B6 +set-banner --target=<pane id> landed on that pane" (
    $null -ne $lSplit -and [string]$lSplit.banner -eq $bannerText)
Assert "B7 the sibling pane was NOT touched" (
    $null -ne $lFirst -and [string]$lFirst.banner -ne $bannerText)

Stop-TestProcs

# ============================================================================
"== C: the LEGACY surface-id spellings still resolve (upgrade safety)"
# ============================================================================
# A pane whose shell was spawned by a pre-T113 build has NO $GHOZTTY_PANE_ID
# and keeps that env across re-attach, so these two aliases must work forever.
#
# This section runs with persistence OFF on purpose. An AGENT-backed pane's
# $GHOSTTY_SURFACE_ID is not trustworthy today: the value is only forwarded by
# the local-shell-integration block, which bails when there is no resources
# dir, and the agent-spawned child then INHERITS whatever the launcher had -
# so every agent pane reports the id of the pane the harness was started from
# (both panes identical, matching no live surface). That is a pre-existing
# defect filed as T117, NOT the alias mechanism under test here; an exec pane
# gets the value baked by core (Surface.zig) and is the honest oracle.
$tmpC = Join-Path $root 'c'
Launch-NoPersist $tmpC 't113-c'
$leavesC = @(Wait-Leaves $tmpC 'c0' 1 30)
Assert "C0 exec-path GUI opened a pane" ($leavesC.Count -ge 1)
Run-Cli '+split --direction=right --name=csplit' "$tmpC\split.txt" 20 | Out-Null
$leavesC = @(Wait-Leaves $tmpC 'c0b' 2 25)
Assert "C0b exec-path window has two panes" ($leavesC.Count -ge 2)

$surfHex = Probe-PaneEnv $tmpC 'csplit' 'GHOSTTY_SURFACE_ID' $SURFID_RE 'c1' 30
Assert 'C1 the pane still exports $GHOSTTY_SURFACE_ID (0x... spelling)' (
    $surfHex -match "^$SURFID_RE$")
Assert 'C2 --target=$GHOSTTY_SURFACE_ID resolves VERBATIM (0x hex, was rejected)' (
    $surfHex -ne '' -and (Marker-LandsIn $tmpC $surfHex 'csplit' 'c2' 25))
$surfDec = if ($surfHex -ne '') { [string][System.Convert]::ToUInt64($surfHex.Substring(2), 16) } else { '' }
Assert "C3 the decimal spelling (the pre-T113 fallback name) resolves too" (
    $surfDec -ne '' -and (Marker-LandsIn $tmpC $surfDec 'csplit' 'c3' 25))

Stop-TestProcs

# ============================================================================
"== D: the id SURVIVES an app-quit re-attach (same shell, same id)"
# ============================================================================
$tmpD = Join-Path $root 'd'
Launch $tmpD 't113-d' $false
$leavesD = @(Wait-Leaves $tmpD 'd0' 1 30)
Assert "D1 GUI opened a pane" ($leavesD.Count -ge 1)
Run-Cli '+split --direction=down --name=dsplit' "$tmpD\split.txt" 20 | Out-Null
$leavesD = @(Wait-Leaves $tmpD 'd1' 2 25)
Assert "D2 two agent-backed panes are up" ($leavesD.Count -ge 2)

$idBefore = Probe-PaneEnv $tmpD 'dsplit' 'GHOZTTY_PANE_ID' $UUID_RE 'd1' 30
Assert "D3 the split pane exports an id before the app dies" ($idBefore -match "^$UUID_RE$")

# The manifest must RECORD the id - that is the mechanism that carries it
# across the restart (the re-attached shell keeps its baked env, so a restore
# that minted a fresh id would leave the pane unable to name itself).
$mIds = @(Wait-ManifestPaneIds $tmpD 2 15)
Assert "D4 the session-layout manifest recorded a pane_id per leaf" ($mIds.Count -ge 2)
Assert "D5 the manifest carries THIS pane's id" (
    $idBefore -ne '' -and @($mIds | ForEach-Object { $_.ToLower() }) -contains $idBefore.ToLower())

# Kill ONLY the app; the agent keeps every PTY (and its env) alive.
Stop-GuiOnly
Launch $tmpD 't113-d' $true
$leavesD2 = @(Wait-Leaves $tmpD 'd2' 2 40)
Assert "D6 restore rebuilt both panes" ($leavesD2.Count -ge 2)
$idAfterList = @($leavesD2 | Where-Object { [string]$_.id.ToLower() -eq $idBefore.ToLower() })
Assert "D7 +list reports the SAME pane id after re-attach" (
    $idBefore -ne '' -and $idAfterList.Count -eq 1)
# And the SAME shell still answers to it - the id and the process agree.
Assert "D8 --target=<id> still reaches that pane after re-attach" (
    $idBefore -ne '' -and (Marker-LandsIn $tmpD $idBefore $idBefore 'd8' 30))
$idAfterEnv = Probe-PaneEnv $tmpD $idBefore 'GHOZTTY_PANE_ID' $UUID_RE 'd9' 30
Assert "D9 the re-attached shell's baked id is unchanged" (
    $idAfterEnv -ne '' -and $idBefore -ne '' -and
    $idAfterEnv.ToLower() -eq $idBefore.ToLower())

Stop-TestProcs

# ============================================================================
"== E: the id SURVIVES an agent restart (tombstone RELAUNCH respawns the shell)"
# ============================================================================
# Here the child process is GONE and the agent respawns it from its recorded
# command + env (T89g). The app-side id comes from the manifest, the shell-side
# id from the agent's replayed env; both must still be the original.
$tmpE = Join-Path $root 'e'
Launch $tmpE 't113-e' $false
$leavesE = @(Wait-Leaves $tmpE 'e0' 1 30)
Assert "E1 GUI opened a pane" ($leavesE.Count -ge 1)
Run-Cli '+split --direction=right --name=esplit' "$tmpE\split.txt" 20 | Out-Null
$leavesE = @(Wait-Leaves $tmpE 'e1' 2 25)
Assert "E2 two agent-backed panes are up" ($leavesE.Count -ge 2)
$idE = Probe-PaneEnv $tmpE 'esplit' 'GHOZTTY_PANE_ID' $UUID_RE 'e1' 30
Assert "E3 the split pane exports an id before the agent dies" ($idE -match "^$UUID_RE$")
$mIdsE = @(Wait-ManifestPaneIds $tmpE 2 15)
Assert "E4 the manifest recorded it before the kill" (
    $idE -ne '' -and @($mIdsE | ForEach-Object { $_.ToLower() }) -contains $idE.ToLower())

# Kill the app AND the agent: every child dies, only sessions.json + rings
# survive, so the next launch RELAUNCHes tombstones instead of re-attaching.
Stop-TestProcs
Launch $tmpE 't113-e' $true
$leavesE2 = @(Wait-Leaves $tmpE 'e2' 2 45)
Assert "E5 restore rebuilt both panes after the agent restart" ($leavesE2.Count -ge 2)
$idE2 = @($leavesE2 | Where-Object { [string]$_.id.ToLower() -eq $idE.ToLower() })
Assert "E6 +list reports the SAME pane id after RELAUNCH" (
    $idE -ne '' -and $idE2.Count -eq 1)
Assert "E7 --target=<id> reaches the RELAUNCHed shell" (
    $idE -ne '' -and (Marker-LandsIn $tmpE $idE $idE 'e7' 35))
$idE3 = Probe-PaneEnv $tmpE $idE 'GHOZTTY_PANE_ID' $UUID_RE 'e8' 35
Assert "E8 the RESPAWNED shell was baked with the SAME id" (
    $idE3 -ne '' -and $idE -ne '' -and $idE3.ToLower() -eq $idE.ToLower())

Stop-TestProcs

# ============================================================================
"== F: a launcher's own GHOZTTY_PANE_ID cannot poison the panes it opens"
# ============================================================================
# The dangerous case, and the one that already bit $GHOSTTY_SURFACE_ID (T117):
# ghoztty is very often launched FROM INSIDE a pane (this whole harness is), so
# the GUI - and the agent it spawns, and every ConPTY child of that agent -
# inherits the launcher's environment. If an inherited GHOZTTY_PANE_ID could
# win, every agent-backed pane on the box would report the SAME id and pane
# self-identification would be silently wrong instead of absent. The id rides
# the surface config's `env` overrides, which the agent applies LAST over the
# inherited env (pty_child.spawnChild), so the pane's own value must win.
$poison = 'DEADBEEF-0000-4000-8000-000000000000'
$tmpF = Join-Path $root 'f'
$env:GHOZTTY_PANE_ID = $poison
Launch $tmpF 't113-f' $false
$leavesF = @(Wait-Leaves $tmpF 'f0' 1 30)
Assert "F1 GUI opened a pane with a poisoned launcher env" ($leavesF.Count -ge 1)
Run-Cli '+split --direction=right --name=fsplit' "$tmpF\split.txt" 20 | Out-Null
$leavesF = @(Wait-Leaves $tmpF 'f1' 2 25)
Assert "F2 two agent-backed panes are up" ($leavesF.Count -ge 2)
$idF = Probe-PaneEnv $tmpF 'fsplit' 'GHOZTTY_PANE_ID' $UUID_RE 'f1' 30
Assert "F3 the pane exports an id" ($idF -match "^$UUID_RE$")
Assert "F4 the pane's OWN id won over the inherited one" (
    $idF -ne '' -and $idF.ToLower() -ne $poison.ToLower())
Assert "F5 the id the shell sees is the one +list reports" (
    $idF -ne '' -and @($leavesF | Where-Object { [string]$_.id.ToLower() -eq $idF.ToLower() }).Count -eq 1)
Remove-Item env:GHOZTTY_PANE_ID -ErrorAction SilentlyContinue
Stop-TestProcs

# ============================================================================
"== G: the ghoztty plugin's banner hook paints THIS pane's banner (end-to-end)"
# ============================================================================
# The reason this task was raised from a contract nicety to a user-facing
# outage: the ghoztty Claude Code plugin resolves its own pane in
# `resolve_pane()` and, on Windows, had NO way to do it - $GHOZTTY_PANE_ID was
# never baked (this task) and both fallbacks need a tty, which an agent-backed
# pane does not have. The hooks then no-op silently (every call is
# `>/dev/null 2>&1`), so the only honest proof is to run the REAL hook script
# inside a real pane and look at the banner that comes back.
#
# The hook is driven exactly as Claude Code drives it - `bash <hook> set ...`
# with the pane's own environment - except that PATH is pointed at the build
# under test (otherwise `ghoztty` resolves to the installed release and the
# banner would land in one of the USER's windows, the T116 trap).
$hookDir = Join-Path $env:USERPROFILE '.claude\plugins\cache\dzearing-claude-marketplace\ghoztty'
$hook = @(Get-ChildItem -Path $hookDir -Filter 'ghoztty-banner.sh' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending)[0]
$bash = 'C:\Program Files\Git\bin\bash.exe'
$jq = @(Get-Command jq -ErrorAction SilentlyContinue)[0]
$jqDir = if ($null -ne $jq) { Split-Path $jq.Source } else { "$env:LOCALAPPDATA\Microsoft\WinGet\Links" }
$missing = @()
if ($null -eq $hook) { $missing += 'plugin hook script' }
if (-not (Test-Path $bash)) { $missing += 'git bash' }
if (-not (Test-Path (Join-Path $jqDir 'jq.exe'))) { $missing += 'jq' }

if ($missing.Count -gt 0) {
    "  SKIP G (end-to-end hook check needs: $($missing -join ', '))"
    $script:skipped++
} else {
    $tmpG = Join-Path $root 'g'
    New-Item -ItemType Directory -Force (Join-Path $tmpG 'home') | Out-Null
    Launch $tmpG 't113-g' $false
    $leavesG = @(Wait-Leaves $tmpG 'g0' 1 30)
    Assert "G1 GUI opened a pane" ($leavesG.Count -ge 1)
    $paneG = if ($leavesG.Count -ge 1) { [string]$leavesG[0].name } else { '' }

    # The driver runs INSIDE the pane, so $GHOZTTY_PANE_ID is the pane's own
    # (never the harness's - the whole point). HOME is hermetic and written
    # with forward slashes so MSYS bash can mkdir under it.
    $marker = 'T113HOOKGOAL'
    $homeFwd = ((Join-Path $tmpG 'home') -replace '\\', '/')
    $hookFwd = ($hook.FullName -replace '\\', '/')
    $binDir = Split-Path $Exe
    $driver = Join-Path $tmpG 'hook.ps1'
    Set-Content -Path $driver -Encoding ascii -Value @(
        "`$env:PATH = '$binDir;$jqDir;' + `$env:PATH"
        "`$env:HOME = '$homeFwd'"
        "`$env:TERM_PROGRAM = 'ghostty'"
        "& '$bash' '$hookFwd' set --title 'T113 hook' --goal '$marker'"
    )
    Run-Cli "+send-keys --target=$paneG `"powershell -NoProfile -File $driver`" Enter" `
        "$tmpG\send.txt" 15 | Out-Null

    # Poll the banner back through +list --json (the CLI way to read a banner).
    $bannerG = ''
    $deadlineG = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadlineG) {
        Start-Sleep -Milliseconds 1000
        $leafG = Leaf-ByName (Get-List $tmpG 'g1') $paneG
        if ($null -ne $leafG -and [string]$leafG.banner -ne '') { $bannerG = [string]$leafG.banner; break }
    }
    Assert "G2 the hook painted a banner on its OWN pane with no plugin edit" (
        $bannerG -match $marker)
    # A banner carrying the `## ` heading + table proves the CLI path (pane
    # resolved via $GHOZTTY_PANE_ID); the OSC fallback can only emit one line.
    Assert "G3 it used the pane-id CLI path, not the single-line OSC fallback" (
        $bannerG -match '## T113 hook' -and $bannerG -match '\|')
    Stop-TestProcs
}

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
