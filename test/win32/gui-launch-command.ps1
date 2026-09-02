# GUI launch path: `ghoztty -e <args...>` and `ghoztty --command=...` (T104).
#
# The gap this covers: on Mac/Linux `ghostty -e cmd...` runs the command in the
# first window. On Windows the args were parsed into `initial-command` and then
# silently DROPPED - the pane came up on a plain default shell. `--command=` on
# the same launch path was dropped identically, and so was a `command` set in the
# user's config file.
#
# The cause was not the parser. Session persistence is ON by default on Windows,
# so every local pane's IO backend is the LOCAL AGENT, and the agent branch in
# `Surface.init` only forwarded a command when `wait-after-command` was set -
# which is a flag the APPRT sets when IT builds a command (the IPC / embedded
# `--command` paths), never something the app's own config sets. The launch
# path's command therefore matched nothing and was never sent in the OPEN.
# `Config._command-explicit` is the missing signal; see `Surface.init`.
#
# The oracle is the same in every section: read the pane back and look for the
# marker the launched command prints. A GUI that "opened a window" proves
# nothing - a window opens either way.
#
# Sections:
#   A  `-e <script> a b c` runs the command WITH ITS ARGUMENTS, with session
#      persistence at its default (on). Pre-fix: a bare shell prompt.
#   B  `--command=<script> a b` on the same launch path does the same.
#   C  a plain launch (no command asked for) still gets an interactive shell and
#      no command is forwarded to the agent - the default shell that
#      `Config.finalize` fills in must NOT be mistaken for an explicit request.
#   D  a launch command survives session restore (T406).
#   E  a SECOND launch against an already-running instance forwards its
#      `-e` command and `--working-directory` instead of dropping them (T487):
#      the AlreadyRunning arm used to forward a bare `new-window` with a null
#      payload, so the running instance opened an empty window and the command
#      vanished with exit 0 and no log line.
#   F  a command that is nothing but a BARE SHELL (`--command=powershell`, the
#      launch spelling of `command = powershell` in the config) runs that shell
#      UN-NESTED with shell integration (T514). Pre-fix the agent ran
#      `cmd /c powershell`: the user's shell nested under a hidden cmd.exe, the
#      integration argv rewrite dropped, and +list frozen on the wrapper's cwd.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: a per-run
# $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN (so no real session-layout is
# restored over the window under test), and it ONLY ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\gui-launch-command.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, and this script starts
# eight of them - so it used to throw eight across whatever the user was
# reading. The CLI reads stay on `Run-Cli`: none of their verbs can create a
# process.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-gui-launch-command-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
}
function Count-TestProcs($name) {
    return @(Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $_.CommandLine -like '*zig-out*' }).Count
}
# Kill the APP but leave the agent running - the "quit/crash, then relaunch"
# shape section D needs, since the agent is what keeps the sessions alive for
# the next launch to re-attach to.
function Stop-TestApp {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}

function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# ---- +list helpers ---------------------------------------------------------
function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
# Every terminal leaf in one `+list --json` snapshot, flattened across windows
# and tabs. Section D needs the whole tree, not just the head of it: after a
# restoring launch the requested pane and the rebuilt ones are siblings and
# nothing promises which comes first.
function Leaves-Of-Node($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') {
        return @(Leaves-Of-Node $node.left) + @(Leaves-Of-Node $node.right)
    }
    return @()
}
function Snapshot-Windows($tmp, $tag) {
    Run-Cli '+list --json' "$tmp\list-$tag.json" 20 | Out-Null
    $tree = $null
    try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch {}
    return @(Windows-Of $tree)
}
function Leaves-Of-Windows($windows) {
    $out = @()
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) { $out += @(Leaves-Of-Node $t.splits) }
    }
    return $out
}

# The name of the first pane of the first window, or '' if there is none yet.
function First-Pane($tmp, $tag, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-Cli '+list --json' "$tmp\list-$tag.json" 20 | Out-Null
        $tree = $null
        try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch {}
        foreach ($w in (Windows-Of $tree)) {
            foreach ($t in @($w.tabs)) {
                $leaf = Find-Leaf $t.splits
                if ($null -ne $leaf) { return $leaf.name }
            }
        }
        Start-Sleep -Milliseconds 700
    }
    return ''
}
# Poll a pane's scrollback until $needle shows up (or we run out of patience).
# Polling, not one read: the command is spawned asynchronously by the agent and
# a single early read is how a working feature reads as broken.
function Wait-PaneText($tmp, $tag, $pane, $needle, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        Run-Cli "+read --name=$pane --lines=60" "$tmp\read-$tag.txt" 15 | Out-Null
        $last = Out-Text "$tmp\read-$tag.txt"
        # Contains, never -like: the markers here carry `[` and `]`, which -like
        # reads as a wildcard CHARACTER CLASS. A malformed pattern throws, the
        # Assert around it never runs, and the script still prints ALL PASS -
        # green and empty, which is worse than a failure.
        if ([string]$last -ne '' -and ([string]$last).Contains($needle)) { return $last }
        Start-Sleep -Milliseconds 800
    }
    return $last
}
# Same idea across EVERY pane in the tree: returns the name of the first pane
# whose scrollback contains $needle, or '' if none does before the deadline.
function Wait-AnyPaneText($tmp, $tag, $needle, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        foreach ($leaf in (Leaves-Of-Windows (Snapshot-Windows $tmp "$tag-$i"))) {
            if ([string]$leaf.name -eq '') { continue }
            Run-Cli "+read --name=$($leaf.name) --lines=60" "$tmp\read-$tag-$i.txt" 15 | Out-Null
            $t = [string](Out-Text "$tmp\read-$tag-$i.txt")
            if ($t -ne '' -and $t.Contains($needle)) { return $leaf.name }
        }
        $i++
        Start-Sleep -Milliseconds 900
    }
    return ''
}

# One hermetic GUI launch, on the test desktop (T1240). $launchArgs is an argv
# LIST: an element that must survive as one entry (a `--command=` with spaces)
# is quoted by the harness, so it no longer has to carry its own quotes - the
# trap that made an early T104 repro look like a parser bug is now the harness's
# job rather than each call site's.
function Launch($tmp, $launchArgs) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default), into a throwaway $env:LOCALAPPDATA - section D asserts a launch command and a RESTORE both happen.
    if ($null -eq $launchArgs) { $launchArgs = @() }
    [void](Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs)
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

# T441: this run's own IPC endpoint, and the LOCALAPPDATA redirect in Launch()
# does not cover it — the endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it, so without this the +list
# and +read calls below answer from the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'guilaunch')
Assert-GhozttyPrivateEndpoint -Exe $Exe

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

# The command under test: a script that echoes its own arguments and then stays
# alive, so the pane is still readable when we get there. It lives at a path with
# no spaces so the assertion is about argument PASSING, not about quoting a path.
$script = Join-Path $root 'marker.cmd'
@(
    '@echo off'
    'echo T104ARGS=[%1][%2][%3]'
    'pause'
) | Set-Content -Path $script -Encoding ASCII
Assert "the marker script path has no spaces" (-not ($script -like '* *'))

# ============================================================================
"== A: -e <command> <args...> runs in the first window (persistence default)"
# ============================================================================
$tmpA = Join-Path $root 'a'
Launch $tmpA @('-e', $script, 'alpha', 'beta')
$paneA = First-Pane $tmpA 'a' 60
Assert "A1 the launch opened a window with a pane" ($paneA -ne '')
Assert-GhozttyIsolated -Exe $Exe

$textA = [string](Wait-PaneText $tmpA 'a' $paneA 'T104ARGS=' 60)
Assert "A2 the -e command RAN (pre-fix: a bare shell prompt)" ($textA.Contains('T104ARGS='))
Assert "A3 its arguments arrived in order" ($textA.Contains('T104ARGS=[alpha][beta][]'))

# Session persistence is at its default here, so this pane's process belongs to
# the agent - that is precisely the backend that used to drop the command.
Assert "A4 the pane is agent-backed (the backend the command was dropped on)" `
    ((Count-TestProcs 'ghoztty-agent.exe') -ge 1)

Stop-TestProcs

# ============================================================================
"== B: --command=... on the same launch path"
# ============================================================================
# ONE argv entry with spaces in it - the harness quotes it (see Launch's note).
$tmpB = Join-Path $root 'b'
Launch $tmpB @("--command=$script gamma delta")
$paneB = First-Pane $tmpB 'b' 60
Assert "B1 the launch opened a window with a pane" ($paneB -ne '')

$textB = [string](Wait-PaneText $tmpB 'b' $paneB 'T104ARGS=' 60)
Assert "B2 the --command RAN (pre-fix: a bare shell prompt)" ($textB.Contains('T104ARGS='))
Assert "B3 its arguments arrived in order" ($textB.Contains('T104ARGS=[gamma][delta][]'))

Stop-TestProcs

# ============================================================================
"== C: a plain launch forwards NO command"
# ============================================================================
# `Config.finalize` fills `command` with the default shell when nothing asked for
# one, so after finalize the field is never null. Treating that as an explicit
# request would send the local shell path to the agent as a COMMAND - the wedge
# the explicit-only rule exists to prevent. The oracle is the agent's own record.
$tmpC = Join-Path $root 'c'
Launch $tmpC @()
$paneC = First-Pane $tmpC 'c' 60
Assert "C1 the plain launch opened a window with a pane" ($paneC -ne '')

# One token plus Enter - `+send-keys` concatenates its positional arguments, so a
# space-free marker needs no quoting through the cmd.exe wrapper. cmd echoes what
# is typed and then complains it is not a command; either way the marker reaching
# the scrollback proves a LIVE interactive shell rather than a finished command.
Run-Cli "+send-keys --target=$paneC T104INTERACTIVE Enter" "$tmpC\sk.txt" 15 | Out-Null
$textC = [string](Wait-PaneText $tmpC 'c' $paneC 'T104INTERACTIVE' 40)
Assert "C2 the pane is an interactive shell" ($textC.Contains('T104INTERACTIVE'))
Assert "C3 no command marker leaked into a plain launch" (-not $textC.Contains('T104ARGS='))

# The agent records the command it was OPENed with; a plain launch must have none.
Run-Cli '+sessions --json' "$tmpC\sessions.json" 20 | Out-Null
$rows = @()
try { $rows = @((Out-Text "$tmpC\sessions.json") | ConvertFrom-Json) } catch {}
$withCmd = @($rows | Where-Object { $null -ne $_.argv -and $_.argv -ne '' })
Assert "C4 the agent recorded NO command for the plain launch" ($withCmd.Count -eq 0)

Stop-TestProcs

# ============================================================================
"== D: a launch command survives session restore (T406)"
# ============================================================================
# The defect: session persistence is ON by default, so the SECOND launch of the
# day has a layout to rebuild - and launch-time restore rebuilt it and dropped
# the command entirely. Nothing was logged and the exit code was 0, so it read
# as "the T104 fix does not work" (it was reproduced twice that way before it
# was understood). Core `Surface.init` hands `initial-command` to whichever
# surface is `app.first`, and on a restoring launch that is a RESTORED pane -
# which ATTACHes to a session that already exists and has nowhere to run it.
#
# The rule: do BOTH. Restore what the user left behind AND open the window they
# just asked for. The requested window is created before restore so it is the
# one `app.first` names.
$tmpD = Join-Path $root 'd'

# --- launch 1: seed a session to come back to -------------------------------
Launch $tmpD @()
$paneD0 = First-Pane $tmpD 'd0' 60
Assert "D1 the seeding launch opened a window with a pane" ($paneD0 -ne '')
$leavesD0 = @(Leaves-Of-Windows (Snapshot-Windows $tmpD 'd0-ids'))
$seedId = if ($leavesD0.Count -ge 1) { [string]$leavesD0[0].id } else { '' }
Assert "D2 the seed pane reports a stable pane id" ($seedId -ne '')

# Kill the APP only. The agent keeps the PTY alive, which is exactly the state a
# quit (or a crash) leaves behind and what the next launch re-attaches to. The
# sleep is for the 250ms debounced layout capture to reach disk.
Start-Sleep -Seconds 3
Stop-TestApp
Assert "D3 the agent outlived the app" ((Count-TestProcs 'ghoztty-agent.exe') -ge 1)
AssertEq "D4 the app is gone" 0 (Count-TestProcs 'ghoztty.exe')

# --- launch 2: same state dir (so there IS a restore) AND a command ---------
Launch $tmpD @('-e', $script, 'omega', 'psi')
$cmdPane = Wait-AnyPaneText $tmpD 'd1' 'T104ARGS=[omega][psi][]' 90
Assert "D5 the -e command RAN despite the restore (pre-fix: silently dropped)" `
    ($cmdPane -ne '')

# The negative control: without this, D5 could pass simply because restore did
# nothing at all, which is not the case under test.
$winsD = @(Snapshot-Windows $tmpD 'd2')
Assert "D6 restore also rebuilt the previous window (>= 2 windows)" ($winsD.Count -ge 2)
$idsD = @(Leaves-Of-Windows $winsD | ForEach-Object { [string]$_.id })
Assert "D7 the seed pane came back with its own pane id" ($idsD -contains $seedId)

Stop-TestProcs

# ============================================================================
"== E: a second launch forwards -e and --working-directory to the running instance (T487)"
# ============================================================================
# The AlreadyRunning arm in win32 App.init forwards `new-window` to whoever owns
# the IPC pipe. Pre-fix the payload was null: the second launch's parsed
# `initial-command` and working directory were thrown away, the running instance
# opened a PLAIN window, and the exit code was 0 - so E2/E4 fail without the fix
# while E1 (a window opened either way) passes, which is exactly the trap the
# header warns about.
$tmpE = Join-Path $root 'e'
$wdE = Join-Path $root 'wd487'
New-Item -ItemType Directory -Force $wdE | Out-Null

# A distinct marker script: echoes its args AND the directory it woke up in.
$scriptE = Join-Path $root 'marker487.cmd'
@(
    '@echo off'
    'echo T487ARGS=[%1][%2]'
    'echo T487CWD=[%CD%]'
    'pause'
) | Set-Content -Path $scriptE -Encoding ASCII

# --- launch 1: a plain instance that owns the pipe --------------------------
Launch $tmpE @()
$paneE0 = First-Pane $tmpE 'e0' 60
Assert "E1 the first launch opened a window with a pane" ($paneE0 -ne '')

# --- launch 2: same endpoint, WITH a command and a cwd ----------------------
# `--working-directory` must come BEFORE `-e`: the launch parser hands
# everything after `-e` to the command argv, exactly like the CLI verb.
Launch $tmpE @("--working-directory=$wdE", '-e', $scriptE, 'omega487', 'psi487')

$cmdPaneE = Wait-AnyPaneText $tmpE 'e1' 'T487ARGS=[omega487][psi487]' 90
Assert "E2 the -e command RAN in the running instance (pre-fix: dropped)" ($cmdPaneE -ne '')

# The forwarding process hands off and exits; only the first instance remains.
Start-Sleep -Milliseconds 1500
AssertEq "E3 the second launch process exited after forwarding" 1 (Count-TestProcs 'ghoztty.exe')

if ($cmdPaneE -ne '') {
    $textE = [string](Wait-PaneText $tmpE 'e2' $cmdPaneE 'T487CWD=' 40)
    Assert "E4 the launch's --working-directory reached the new pane" `
        ($textE.ToLower().Contains("t487cwd=[$($wdE.ToLower())]"))
} else {
    "  FAIL E4 the launch's --working-directory reached the new pane (no command pane to read)"
    $script:failures++
}

Stop-TestProcs

# ============================================================================
"== F: a bare-shell --command runs UN-NESTED with shell integration (T514)"
# ============================================================================
# `--command=powershell` is the launch spelling of `command = powershell` in
# the config file - same config key, same `_command-explicit` signal, same
# Surface.init path. A bare recognized shell is a shell CHOICE: it must travel
# as OPEN.shell (un-nested, integrated), not OPEN.command (`cmd /c powershell`).
$tmpF = Join-Path $root 'f'
$wdF = Join-Path $root 'wd514'
New-Item -ItemType Directory -Force $wdF | Out-Null

Launch $tmpF @('--command=powershell')
$paneF = First-Pane $tmpF 'f' 60
Assert "F1 the launch opened a window with a pane" ($paneF -ne '')

# The leaf's pid is the agent-reported shell process - the process the agent
# actually spawned. Pre-fix that was the cmd.exe wrapper; the user's shell ran
# nested one level below it. Poll: the pid arrives with the agent's OPENED.
$leafF = $null
$deadlineF = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadlineF) {
    $leaves = @(Leaves-Of-Windows (Snapshot-Windows $tmpF 'f-pid'))
    $leafF = @($leaves | Where-Object { [string]$_.name -eq $paneF })[0]
    if ($null -ne $leafF -and [int]$leafF.pid -gt 0) { break }
    Start-Sleep -Milliseconds 700
}
$shellProcF = $null
if ($null -ne $leafF -and [int]$leafF.pid -gt 0) {
    $shellProcF = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$leafF.pid)"
}
AssertEq "F2 the pane's shell IS powershell (pre-fix: a nested cmd.exe wrapper)" `
    'powershell.exe' ([string]$shellProcF.Name)
Assert "F3 the shell's command line carries the integration rewrite (ghostty.ps1)" `
    ([string]$shellProcF.CommandLine -match '(?i)ghostty\.ps1')

# Integration-visible behavior: a cd inside the pane shows up in +list. The
# quoted token keeps `cd <path>` one argument through the cmd.exe wrapper.
Run-Cli "+send-keys --target=$paneF `"cd $wdF`" Enter" "$tmpF\sk.txt" 15 | Out-Null
$gotWdF = ''
$deadlineF = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadlineF) {
    $leaves = @(Leaves-Of-Windows (Snapshot-Windows $tmpF 'f-wd'))
    $l = @($leaves | Where-Object { [string]$_.name -eq $paneF })[0]
    if ($null -ne $l -and ([string]$l.working_directory).ToLower() -eq $wdF.ToLower()) {
        $gotWdF = [string]$l.working_directory
        break
    }
    Start-Sleep -Milliseconds 800
}
Assert "F4 +list follows an in-pane cd (pre-fix: frozen on the wrapper's cwd)" ($gotWdF -ne '')

Stop-TestProcs

# ---- teardown --------------------------------------------------------------
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

# A green run stamps the covered files (T783) so guard-due can answer "has
# this harness been run as it now stands?". Red leaves the stamp alone.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard gui-launch-command -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
