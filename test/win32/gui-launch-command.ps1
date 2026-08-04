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
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 900
}
function Count-TestProcs($name) {
    return @(Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $_.CommandLine -like '*zig-out*' }).Count
}

function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
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

# One hermetic GUI launch. $launchArgs is passed to Start-Process VERBATIM:
# PowerShell does not quote -ArgumentList elements, so any element that must
# survive as ONE argv entry (a `--command=` with spaces) has to carry its own
# quotes - the same trap that made an early T104 repro look like a parser bug.
function Launch($tmp, $launchArgs) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    if ($null -eq $launchArgs -or $launchArgs.Count -eq 0) {
        Start-Process -FilePath $Exe -WindowStyle Minimized | Out-Null
    } else {
        Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList $launchArgs | Out-Null
    }
}

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
# ONE argv entry, so it carries its own quotes (see Launch's note).
$tmpB = Join-Path $root 'b'
Launch $tmpB @("`"--command=$script gamma delta`"")
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

# ---- teardown --------------------------------------------------------------
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
