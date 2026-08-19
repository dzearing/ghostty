# T230 acceptance: an agent restart must NEVER re-execute a pane's recorded
# command.
#
# The defect: `session-relaunch` defaulted to `auto`, so when the local agent
# restarted (a reboot, or the T147 mandatory agent upgrade) every restored pane
# fired a RELAUNCH of the command it had been opened with. The user rejected
# that outright, verbatim (2026-07-31): "We should not ever re-execute the
# commands which were previously ran, but, the console message which says the
# session was closed could list the previous command executed so the user can
# choose to copy/paste it."
#
# The new default is `restore`: no respawn, a fresh shell in the recorded working
# directory, and a notice above it naming the command that was running.
#
# (T823 renamed the three values to the ones the Mac seat ships - `notify` ->
# `restore`, `auto` -> `rerun` - so the setting can be spelled the same way on
# both platforms. This file keeps its name so the evidence pointers in the task
# files that cite it still resolve; the behavior it measures is unchanged.)
#
# Measured by OUTCOME - whether the recorded process is RUNNING, what the pane
# actually shows, and whether the pane takes input - not by log scraping:
#
#   A: the contract. Two panes opened with two DISTINGUISHABLE long-lived
#      commands, agent killed, app relaunched. Neither command is running
#      afterwards (the process table is the oracle), each pane shows the notice
#      naming ITS OWN command and not the other's, and each pane accepts input
#      on a live shell. Since T423 it also proves the notice is in the pane's
#      own SCROLLBACK, above the shell's output - not only in the banner
#      overlay, which is all that used to survive. Since T922/D78 it also proves
#      the pane comes back showing WHAT THE DEAD SESSION LEFT ON SCREEN, above
#      that notice, instead of an empty prompt.
#   B: negative control / opt-in - `--session-relaunch=rerun` still respawns the
#      recorded command. Without this, A would also pass against a build that
#      simply broke restore.
#   C: a pane whose recorded cwd was DELETED while the agent was down still
#      comes up on a working prompt (a missing directory must not kill a pane).
#   D: the recorded cwd TRACKS the shell (T425) - a pane the user `cd`'d out of
#      restores where they actually were, not where the shell was spawned.
#      Scored on the agent's own sessions.json AND on what the restored shell
#      prints for `cd`.
#
# The commands are `ping -n <unique> 127.0.0.1`: long-lived, harmless, and each
# carries a unique count that makes it findable in Win32_Process.CommandLine -
# so "did the recorded command run again?" is a process-table question with a
# yes/no answer, not an inference from pane text.
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) so it never
# takes the user's foreground; hermetic via a per-run LOCALAPPDATA +
# GHOSTTY_LOCAL_AGENT_BIN + a private IPC pipe suffix, and it only ever kills
# ghoztty / ghoztty-agent processes launched from the repo zig-out (plus its own
# ping markers).
#
#   powershell -NoProfile -File test\win32\session-relaunch-notify.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Where to leave per-pane raw `+read` dumps for a failure that needs eyes on
    # the actual bytes. Off by default: the run's own temp tree is deleted at the
    # end, deliberately, so this has to be somewhere else.
    [string]$DumpPanesTo = '',
    [switch]$NegativeControl,
    # Keep the per-run temp tree (every arm's app stderr log, its CLI captures
    # and its session-layout manifest) instead of deleting it at the end. For
    # diagnosing an arm that `-DumpPanesTo` cannot explain: that flag only
    # reaches arm A's panes, and a failure in D/E/F leaves nothing behind.
    [switch]$KeepTemp,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-relaunch-notify-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: the "attached is not alive" oracle. Read its header before adding an
# assertion about a restored pane.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

# Write-Host, never the pipeline: a helper that asserts AND returns a value would
# hand its caller @('  PASS ...', $realValue) and the caller would silently read
# the wrong element.
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# Unique per run so a stale ping from an earlier run can never satisfy - or
# spoil - this run's oracle.
$MARK_A = 9700 + ($PID % 89)
$MARK_B = 8700 + ($PID % 89)
$MARK_F = 7700 + ($PID % 89)
$CMD_A = "ping -n $MARK_A 127.0.0.1"
$CMD_B = "ping -n $MARK_B 127.0.0.1"
$CMD_F = "ping -n $MARK_F 127.0.0.1"
# T422: per-pane banners and a window title pin for arm E. Distinguishable from
# each other so "each pane kept ITS OWN banner" is a real claim rather than "some
# banner survived", and space-free so `Run-CliArgs` cannot re-tokenize them.
# T922: what the plain pane prints before the kill, so the restore arm can ask
# whether the dead session's last screen came back. Space-free (`Run-CliArgs`
# joins with spaces and quotes nothing) and carrying this run's unique number,
# so a leftover pane from an earlier run cannot satisfy the assertion.
$HIST_MARK = "T922hist$MARK_A"
$BAN_A = "T422banA$MARK_A"
$BAN_B = "T422banB$MARK_B"
$WIN_TITLE = "T422title$MARK_A"

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Stop-MarkerPings
    Start-Sleep -Milliseconds 700
}
# THE reboot shape, and since T909 it is no longer "kill the agent".
#
# A persistent session's ConPTY now lives in its own holder process
# (`ghoztty-agent --pty-host --spec ...`, src\remote\agent\pty_holder_child.zig)
# precisely SO THAT it outlives the session manager: an agent that crashes or is
# upgraded comes back and ADOPTS its holders, and the panes re-attach to sessions
# that never died. That is the point of T909/T911 and it is right - but it means
# killing the agent pid alone no longer produces the dead-but-relaunchable
# tombstones this whole script is about. Measured on 2026-08-18: every notice arm
# scored FAIL against a correct build, because the restored panes had re-attached
# to LIVE sessions and there was nothing to notify about.
#
# A reboot takes the holders too, so this takes the holders too: every
# ghoztty-agent process launched from the repo zig-out, the manager and its
# holders alike. The `zig-out` filter is what keeps the user's installed agent -
# which owns their real sessions - out of it.
function Stop-AgentAndHolders($agentPid) {
    if ($agentPid) { Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
    return @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' }).Count
}
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}
# THE oracle for "did the recorded command run?": count live pings carrying this
# run's unique -n value.
function Count-MarkerPings($mark) {
    return @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" |
        Where-Object { $_.CommandLine -like "*-n $mark *" }).Count
}
function Stop-MarkerPings {
    Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" |
        Where-Object { $_.CommandLine -like "*-n $MARK_A *" -or $_.CommandLine -like "*-n $MARK_B *" -or $_.CommandLine -like "*-n $MARK_F *" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Wait-MarkerPings($mark, $want, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Count-MarkerPings $mark) -ge $want) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return ((Count-MarkerPings $mark) -ge $want)
}

function Get-RunAgentPid($t) {
    $a = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$t*" })
    if ($a.Count -eq 0) { return 0 }
    return [int]$a[0].ProcessId
}
function Wait-AgentPid($t, $timeoutSec = 25, $notPid = 0) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-RunAgentPid $t
        if ($p -ne 0 -and $p -ne $notPid) { return $p }
        Start-Sleep -Milliseconds 400
    }
    return (Get-RunAgentPid $t)
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - session persistence IS this script's subject.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit: touching `.Handle` afterwards
    # reads back an EMPTY ExitCode and every `-eq 0` gate scores a working CLI as
    # a failure.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    # Judged on the OUTPUT, not the exit code: the answer is the JSON.
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" $timeoutSec | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return , @() }
    if ($null -ne $tree.data) { return , @($tree.data.windows) }
    return , @($tree.windows)
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-Leaves($tag, $target, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        if ((All-Leaves $tree).Count -ge $target) { return $tree }
        Start-Sleep -Milliseconds 500
    }
    return (Get-List "$tag-last")
}
# Wait-Leaves, then wait for every restored pane to hold SOME banner.
#
# A leaf appears in `+list` as soon as its pane exists; its banner arrives later,
# from the pane's own IO thread, after the ATTACH round-trips and - since
# T922/D78 - after the dead session's screen is repainted into it. So a bare
# Wait-Leaves can answer with three leaves whose banner fields are simply not
# filled in yet, and the arms below would score "which banner did this pane end
# up with?" against a pane that has not chosen one. (Measured: arm E read
# `noticed=0` off a restore whose own manifest, written moments later, recorded
# the notice banner on exactly the pane E4 expects it on.)
#
# The settle condition is deliberately NOT the assertion: it asks only that
# every pane holds a banner, never which. A build that put the notice over a
# pane's own banner settles just as fast and still fails E3.
function Wait-BannerSettle($tag, $target, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    # NOT `@(All-Leaves ...)`: All-Leaves already hands back its array as one
    # pipeline item, so wrapping it re-wraps - `$leaves` becomes a one-element
    # array holding the leaf array, every `$leaf.banner` becomes every banner
    # joined, and the arms score nonsense. (Measured: A5/A8/A11/A13 all went red
    # against a build that had just passed them.)
    $leaves = All-Leaves (Wait-Leaves $tag $target 30)
    while ((Get-Date) -lt $deadline) {
        if ($leaves.Count -ge $target) {
            $withBanner = @($leaves | Where-Object { ([string]$_.banner) -ne '' }).Count
            if ($withBanner -eq $leaves.Count) { break }
        }
        Start-Sleep -Milliseconds 700
        $leaves = All-Leaves (Get-List "$tag-settle")
    }
    return , $leaves
}
function Read-Pane($id, $tag, $lines = 300) {
    Run-CliArgs @('+read', "--name=$id", "--lines=$lines") "$tmp\read-$tag.txt" 12 | Out-Null
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '')
}
# Like Wait-PaneText, but whitespace-insensitive and counted. A path is the
# thing being matched below and a pane WRAPS one across lines, so the raw text
# never contains it verbatim; and `want = 2` distinguishes "the user typed this
# path" from "the shell is actually AT this path" (the echoed input line is the
# first hit, the new prompt is the second) - the same two-hit trick
# Test-PaneResponsive uses to tell a live shell from a dead line editor.
function Wait-PaneTextTight($id, $tag, $needle, $want = 1, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $txt = (Read-Pane $id $tag) -replace '\s', ''
        if (([regex]::Matches($txt, [regex]::Escape($needle))).Count -ge $want) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}
# T922: has the app PERSISTED a pane screen carrying `$needle` yet?
#
# The restore paints the screen the session-layout manifest recorded, so what
# the restored pane can possibly show is decided before the kill, by whether
# that file has caught up with the pane. Waiting on the file itself rather than
# sleeping a guessed interval is the difference between an arm that measures the
# restore and one that measures the refresh cadence: the app re-captures a pane's
# screen a couple of seconds after its output goes quiet, and any sleep short
# enough to keep this script fast is long enough to be a coin flip.
function Wait-LayoutSnapshotHas($needle, $timeoutSec = 40) {
    $path = Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json'
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            try {
                $doc = Get-Content -Raw -Encoding utf8 $path | ConvertFrom-Json
                foreach ($w in @($doc.windows)) {
                    foreach ($t in @($w.tabs)) {
                        foreach ($n in @($t.nodes)) {
                            $b64 = [string]$n.leaf.screen_snapshot
                            if ($b64 -eq '') { continue }
                            $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                            if (($txt -replace '\s', '').Contains($needle)) { return $true }
                        }
                    }
                }
            } catch {
                # A torn read of the atomic replace, or a half-written file:
                # both are transient by construction, so just look again.
            }
        }
        Start-Sleep -Milliseconds 700
    }
    return $false
}
function Wait-PaneText($id, $tag, $pattern, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-Pane $id $tag) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}
# T423: where the notice sits in the pane's OWN scrollback, relative to the
# fresh shell's first output. Returns character offsets into the whitespace-
# stripped dump, which is what makes the answer wrap-proof: these panes are
# splits, narrow enough that the notice line wraps, and a line-index comparison
# would score a real pass as a FAIL. `>` is the shell's prompt terminator and
# appears nowhere in the notice or in a `ping -n N 127.0.0.1` label, so the
# first one marks where the shell's content begins.
#
# `shell` is the FIRST prompt in the dump and `fresh` the first one at or after
# the notice. The two differ since T922/D78: a restored pane now opens with the
# DEAD session's last screen painted above the notice, and that screen ends in
# the old shell's prompt - so "the first `>` in the pane" stopped meaning "the
# new shell painted" the day the restore started bringing history back, and
# scored a correct build FAIL. `shell` is still the positive control (something
# painted at all); `fresh` is what the placement claim is about.
function Get-NoticePlacement($id, $tag, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $out = @{ notice = -1; shell = -1; fresh = -1 }
    while ((Get-Date) -lt $deadline) {
        $tight = (Read-Pane $id $tag 400) -replace '\s', ''
        # Ordinal-ignore-case on purpose: String.IndexOf(string) is case
        # SENSITIVE, and T424 recapitalized the in-stream copy to
        # "Session interrupted:" to match the banner. The placement assertions
        # are about WHERE the notice is, not how it is cased - pin the wording
        # in the pure session_notice tests, not here.
        $out.notice = $tight.IndexOf('sessioninterrupted', [System.StringComparison]::OrdinalIgnoreCase)
        $out.shell = $tight.IndexOf('>')
        $out.fresh = if ($out.notice -ge 0) { $tight.IndexOf('>', $out.notice) } else { -1 }
        if ($out.notice -ge 0 -and $out.shell -ge 0 -and $out.fresh -ge 0) { break }
        Start-Sleep -Milliseconds 700
    }
    return $out
}

# THE liveness oracle for a pane: type a unique marker and read it back.
#
# T652: this probe is where the shared oracle came from - including the
# two-occurrence rule - so it now IS the shared oracle, which also brings this
# script's arms under the GHOZTTY_TEST_LIVENESS_BREAK teeth-check.
function Test-PaneResponsive($id, $tag, $timeoutSec = 30) {
    return (Test-PaneLive -Exe $Exe -Target $id -Tmp $tmp -TimeoutSec $timeoutSec -Tag 'RN')
}

function Start-App($title, $extraArgs = @()) {
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    # persistence: on (default) - session persistence IS this script's subject.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extraArgs -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    Assert "leak: '$title' has no window on the interactive desktop" `
        (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    return [int]$app.Pid
}

# Build the 2-pane layout, then take the app AND every session owner down so the
# next launch finds dead-but-relaunchable tombstones - the REBOOT shape.
#
# Since T909 that is no longer the same thing as the agent-upgrade shape: a
# holder-backed session survives its manager on purpose, so an upgrade now ends
# with the panes re-attached and alive, and nothing to notify about. See
# Stop-AgentAndHolders.
function Build-AndKill($cwdA, $withBanners = $false) {
    $appPid = Start-App 'build' @("--working-directory=$cwdA")
    Assert "setup: the GUI came up" ($appPid -ne 0)
    # T922: the plain shell pane is the one the history arm scores, and this is
    # the only moment its id is unambiguous - it is the sole leaf, before the
    # commanded window and its split exist. Remembered rather than re-derived,
    # because after the restore there is nothing in `+list` that says which leaf
    # used to be the plain one.
    $script:plainPane = ''
    $tree0 = Wait-Leaves 'b0' 1
    $leaves0 = All-Leaves $tree0
    if ($leaves0.Count -ge 1) { $script:plainPane = [string]$leaves0[0].id }
    # The `--command=` value MUST carry its own quotes: `Start-Process
    # -ArgumentList` joins the array with spaces and quotes NOTHING, so a bare
    # `--command=ping -n 9717 127.0.0.1` is re-tokenized into four positional
    # arguments and the pane opens on something else entirely. (Measured: the
    # first run of this script scored every marker assertion FAIL for exactly
    # this reason - the product was fine.)
    Run-CliArgs @('+new-window', '--target=nA', "--command=`"$CMD_A`"", "--working-directory=$cwdA") "$tmp\nwA.txt" 25 | Out-Null
    Start-Sleep -Seconds 2
    # T422: banner A goes on BEFORE the split. A banner set on a WINDOW target
    # lands on that window's FOCUSED pane, and after the split that is nB - so
    # setting both afterwards would put both banners on the same pane and leave
    # pane A bare. Space-free tokens: `Run-CliArgs` joins its array with spaces
    # and quotes nothing, so a multi-word banner arrives as positional junk.
    if ($withBanners) {
        Run-CliArgs @('+set-banner', '--target=nA', $BAN_A) "$tmp\banA.txt" 12 | Out-Null
    }
    Run-CliArgs @('+split', '--target=nA', '--name=nB', '--direction=right', "--command=`"$CMD_B`"") "$tmp\spB.txt" 25 | Out-Null
    if ($withBanners) {
        Start-Sleep -Seconds 1
        Run-CliArgs @('+set-banner', '--target=nB', $BAN_B) "$tmp\banB.txt" 12 | Out-Null
    }
    $tree = Wait-Leaves 'b1' 3 45
    Assert "setup: both commanded panes exist" ((All-Leaves $tree).Count -ge 3)
    Assert "setup: '$CMD_A' is actually running" (Wait-MarkerPings $MARK_A 1 30)
    Assert "setup: '$CMD_B' is actually running" (Wait-MarkerPings $MARK_B 1 30)
    $agent = Wait-AgentPid $tmp 25
    Assert "setup: an agent is running for this run" ($agent -ne 0)

    # T422: pin the window's title so arm E can score the other half of the
    # user's report ("window titles too"). `+rename` sets the WINDOW title
    # override whichever kind of target it is given.
    if ($withBanners) {
        Run-CliArgs @('+rename', '--target=nA', "--title=$WIN_TITLE") "$tmp\renA.txt" 12 | Out-Null
        Start-Sleep -Seconds 1
    }

    # T922/D78: leave something on the plain pane's screen that only THAT
    # session could have produced, so the restore arm can ask whether the dead
    # session's screen came back. `echo <token>`, waited for TWICE - the echoed
    # input line and the command's output - because one hit is keystrokes in a
    # line editor and would not prove the shell ever painted the token. It has
    # to land BEFORE the manifest debounce below: the snapshot the restore
    # paints is whatever the app had captured when the layout was last written.
    if ($script:plainPane -ne '') {
        Run-CliArgs @('+send-keys', "--target=$($script:plainPane)", 'echo', 'Space', $HIST_MARK, 'Enter') "$tmp\hist.txt" 15 | Out-Null
        Assert "setup: the plain pane printed the history marker before the kill" `
            (Wait-PaneTextTight $script:plainPane 'hist' $HIST_MARK 2 25)
        # …and that it reached the MANIFEST, which is the only copy that
        # survives the kill. This is the positive control for A15: without it,
        # a red A15 cannot be told apart from a screen that was never persisted.
        Assert "setup: the plain pane's screen was persisted with the history marker" `
            (Wait-LayoutSnapshotHas $HIST_MARK 45)
    }

    Start-Sleep -Seconds 3   # let the session-layout manifest debounce out
    Stop-AppOnly
    $ownersLeft = Stop-AgentAndHolders $agent
    Assert "setup: no session manager or PTY holder survived the reboot shape ($ownersLeft)" `
        ($ownersLeft -eq 0)
    Start-Sleep -Seconds 2
    # Killing the agent SHOULD take its ConPTY children with it. Sweep anyway:
    # a survivor would silently satisfy (or spoil) the "did it run again?" oracle
    # below, and an oracle that can be satisfied by the previous run's process is
    # not an oracle.
    Stop-MarkerPings
    Start-Sleep -Milliseconds 800
    Assert "setup: no marker process survived the agent kill" `
        (((Count-MarkerPings $MARK_A) + (Count-MarkerPings $MARK_B)) -eq 0)
    return $agent
}

# Each arm gets a VIRGIN state dir. The session-layout manifest and the agent's
# sessions.json both live under LOCALAPPDATA, so sharing one across arms means
# arm N+1's app restores arm N's windows before its own setup runs - and then
# `+new-window --target=nA` finds `nA` already registered and merely FOCUSES it,
# so no commanded pane is ever created and every marker assertion scores against
# the previous arm's leftovers. (Measured: that is exactly how arm C failed on
# the first green-ish run.)
function Reset-State($arm) {
    $script:tmp = Join-Path $root "run-$arm"
    New-Item -ItemType Directory -Force (Join-Path $script:tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $script:tmp
}

Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{ lad = $env:LOCALAPPDATA; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; pipe = $env:GHOZTTY_PIPE_SUFFIX }
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Isolate the IPC endpoint: every `+list` / `+read` / `+send-keys` below is an
# oracle, and a user instance answering the shared pipe would answer them about
# somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-relnotify'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

$workA = Join-Path $root 'workA'
New-Item -ItemType Directory -Force $workA | Out-Null

# ============================================================================
Say "== A: the default (restore) - the recorded commands are NOT re-run"
# ============================================================================
Reset-State 'a'
Build-AndKill $workA | Out-Null

$appPidA = Start-App 'restore'
Assert "A1 the GUI came back" ($appPidA -ne 0)
$treeA = Wait-Leaves 'a0' 3 60
Assert "A2 the layout restored (3 panes)" ((All-Leaves $treeA).Count -ge 3)

# Give a would-be relaunch every chance to show up before scoring its absence.
Start-Sleep -Seconds 8
Assert "A3 '$CMD_A' was NOT re-executed" ((Count-MarkerPings $MARK_A) -eq 0)
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the recorded command DID re-run - this run MUST fail'
    Assert "A4 '$CMD_B' was re-executed (inverted)" ((Count-MarkerPings $MARK_B) -ge 1)
} else {
    Assert "A4 '$CMD_B' was NOT re-executed" ((Count-MarkerPings $MARK_B) -eq 0)
}

# Each commanded pane must SAY what happened, and name its OWN command.
#
# Scored first on the PANE BANNER (`+list --json`'s `banner` field), which is a
# native overlay a screen clear cannot reach. A5-A8 below are the banner's arm;
# A10-A13 are the in-stream copy's, added by T423.
$leavesA = Wait-BannerSettle 'a1' 3 40
$sawNotice = 0; $sawA = 0; $sawB = 0; $crossTalk = 0
foreach ($leaf in $leavesA) {
    $b = [string]$leaf.banner
    if ($b -match 'Session interrupted') { $sawNotice++ }
    $hasA = $b -match [regex]::Escape("-n $MARK_A")
    $hasB = $b -match [regex]::Escape("-n $MARK_B")
    if ($hasA) { $sawA++ }
    if ($hasB) { $sawB++ }
    if ($hasA -and $hasB) { $crossTalk++ }
}
Assert "A5 both commanded panes show the interrupted notice" ($sawNotice -ge 2)
Assert "A6 a pane names '$CMD_A' as its previous command" ($sawA -ge 1)
Assert "A7 a pane names '$CMD_B' as its previous command" ($sawB -ge 1)
Assert "A8 no pane shows the OTHER pane's command" ($crossTalk -eq 0)
# The no-recorded-command case (a null `argv`) is NOT reachable from here, and
# the reason is worth knowing: every pane in this layout is opened with an
# EXPLICIT `--command=`, which is the one field that makes the agent record a
# label at all. A plain shell pane - the shape the user actually runs - records
# NOTHING, so its notice names nothing. That is T429, and it is invisible to
# this arm by construction. The null-label rendering itself is covered by the
# pure `session_notice` tests in the none-runtime lane.

# T423: the user asked for the notice "displayed inline, above the shell content
# but within the console logging" - the banner was never what they wanted, it
# was the only carrier that survived. A fresh cmd.exe under ConPTY opens with a
# full-screen repaint (`ESC[H ESC[2J`) that erased the in-stream copy, so the
# notice is now folded into the SCROLLBACK before the child's first byte lands:
# above the viewport is the one region conhost's repaint never addresses.
#
# A10 is the positive control for A12: without proof that the shell painted at
# all, "the notice is above the shell content" is satisfied by a pane where
# there IS no shell content.
#
# A12 scores the FRESH shell's prompt (`place.fresh`) since T922/D78 - see
# Get-NoticePlacement. The claim is unchanged ("the repaint never got above the
# notice"); what changed is that a restored pane now also carries the DEAD
# shell's prompt, above the notice, where it belongs.
$textNotice = 0; $textAbove = 0; $shellPainted = 0; $textCmd = 0
foreach ($leaf in $leavesA) {
    $short = $leaf.id.Substring(0, 4)
    $place = Get-NoticePlacement $leaf.id "atxt$short"
    if ($place.notice -ge 0) { $textNotice++ }
    if ($place.shell -ge 0) { $shellPainted++ }
    if ($place.notice -ge 0 -and $place.fresh -ge 0) { $textAbove++ }
    $tight = (Read-Pane $leaf.id "acmd$short" 400) -replace '\s', ''
    if ($tight.Contains("-n$MARK_A") -or $tight.Contains("-n$MARK_B")) { $textCmd++ }
}
Assert "A10 the fresh shell actually painted in every pane (positive control)" `
    ($shellPainted -eq $leavesA.Count)
Assert "A11 the notice is in the pane's OWN scrollback, not only in the banner ($textNotice)" `
    ($textNotice -ge 2)
Assert "A12 every pane showing the notice shows it ABOVE the shell content ($textAbove/$textNotice)" `
    ($textNotice -ge 2 -and $textAbove -eq $textNotice)
Assert "A13 the commanded panes name their previous command in the TEXT ($textCmd)" `
    ($textCmd -ge 2)

# T922/D78: the pane must also bring back WHAT THE DEAD SESSION LEFT ON SCREEN.
#
# Until D78 a restored pane came up holding only the notice and an empty prompt:
# the app's own persisted screen snapshot was deliberately not painted on this
# path, because the pane is running a brand-new session that shares no byte
# stream with it. The user settled that against the Mac's behavior - "you can
# read the error, the build output or the last thing your agent said before the
# reboot took it" - so the old screen is now painted as HISTORY, above the
# notice, and the notice's fold carries the pair into the scrollback.
#
# Scored on the marker `Build-AndKill` printed in the plain pane before the kill,
# which no fresh shell can produce. Offsets into the whitespace-stripped dump,
# for the same wrap-proofing Get-NoticePlacement documents: these panes are
# narrow enough that a line-index comparison would score a real pass FAIL.
$histPanes = 0; $histAbove = 0; $histBelowShell = 0
foreach ($leaf in $leavesA) {
    $short = $leaf.id.Substring(0, 4)
    $tight = (Read-Pane $leaf.id "ahist$short" 400) -replace '\s', ''
    $iHist = $tight.IndexOf($HIST_MARK, [System.StringComparison]::OrdinalIgnoreCase)
    if ($iHist -lt 0) { continue }
    $histPanes++
    $iNotice = $tight.IndexOf('sessioninterrupted', [System.StringComparison]::OrdinalIgnoreCase)
    if ($iNotice -ge 0 -and $iHist -lt $iNotice) { $histAbove++ }
    # The restored screen must be HISTORY, not the live frame: everything the
    # dead session left has to sit above the FRESH shell's first prompt, or it
    # is sharing the active screen with a shell that will erase it.
    #
    # "Fresh" is the first prompt at or after the notice, not the first prompt in
    # the dump - the restored screen ends in the DEAD shell's prompt, so the
    # naive index scores a correct restore FAIL. Same correction as A12; see
    # Get-NoticePlacement.
    $iFresh = if ($iNotice -ge 0) { $tight.IndexOf('>', $iNotice) } else { $tight.IndexOf('>') }
    if ($iFresh -ge 0 -and $iHist -lt $iFresh) { $histBelowShell++ }
}
Assert "A15 a restored pane brings back what the dead session left on screen ($histPanes)" `
    ($histPanes -ge 1)
Assert "A16 the restored screen sits ABOVE the interrupted notice ($histAbove/$histPanes)" `
    ($histPanes -ge 1 -and $histAbove -eq $histPanes)
Assert "A17 the restored screen is scrollback, above the fresh shell's prompt ($histBelowShell/$histPanes)" `
    ($histPanes -ge 1 -and $histBelowShell -eq $histPanes)
if ($DumpPanesTo -ne '') {
    New-Item -ItemType Directory -Force $DumpPanesTo | Out-Null
    foreach ($leaf in $leavesA) {
        Set-Content -Encoding utf8 -Path (Join-Path $DumpPanesTo "pane-$($leaf.id.Substring(0,8)).txt") `
            -Value (Read-Pane $leaf.id "dump$($leaf.id.Substring(0,4))" 400)
    }
    Copy-Item $script:AppLog (Join-Path $DumpPanesTo 'app.err.txt') -ErrorAction SilentlyContinue
    Say "  dumped $($leavesA.Count) pane(s) to $DumpPanesTo"
}

# The point of the whole exercise: a usable shell, not a corpse.
$respA = 0
foreach ($leaf in $leavesA) { if (Test-PaneResponsive $leaf.id "a$($leaf.id.Substring(0,4))") { $respA++ } }
Assert "A9 every restored pane is on a live, interactive shell ($respA/$($leavesA.Count))" `
    ($respA -eq $leavesA.Count)

# T237: the restore policy must also RETIRE the dead tombstone it replaced -
# the fire-and-forget CLOSE_SESSION (`closeSessionNoWait`, Remote.zig) - or
# every agent restart leaks one dead(relaunchable) row per pane into
# sessions.json forever. Scored on the agent's own sessions.json: the marker
# commands must be GONE from it (the tombstones were freed), while the file
# still lists the fresh live sessions - so an empty or missing file cannot
# trivially satisfy the check. A5-A8 above are the positive control that the
# tombstones existed at restore time (the notices were built from them).
$metaA = Join-Path $tmp 'ghoztty\local-agent-debug\sessions.json'
$tombGone = $false; $liveA14 = 0
$deadlineA14 = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadlineA14) {
    $rawA14 = ''
    if (Test-Path $metaA) { $rawA14 = [string](Get-Content -Raw $metaA -ErrorAction SilentlyContinue) }
    if ($rawA14 -ne '') {
        $liveA14 = 0
        try { $liveA14 = @((ConvertFrom-Json $rawA14).sessions).Count } catch {}
        if (-not $rawA14.Contains("-n $MARK_A") -and -not $rawA14.Contains("-n $MARK_B") `
            -and $liveA14 -ge $leavesA.Count) { $tombGone = $true; break }
    }
    Start-Sleep -Milliseconds 500
}
Assert "A14 the dead tombstones were retired from sessions.json (live=$liveA14)" $tombGone
Stop-TestProcs

# ============================================================================
Say "== B: opt-in - session-relaunch=rerun STILL respawns the recorded command"
# ============================================================================
Reset-State 'b'
Build-AndKill $workA | Out-Null
$appPidB = Start-App 'rerun' @('--session-relaunch=rerun')
Assert "B1 the GUI came back" ($appPidB -ne 0)
Wait-Leaves 'b2' 3 60 | Out-Null
Assert "B2 '$CMD_A' WAS respawned under the auto policy" (Wait-MarkerPings $MARK_A 1 40)
Assert "B3 '$CMD_B' WAS respawned under the auto policy" (Wait-MarkerPings $MARK_B 1 40)
# T652 (why there is no echo-probe liveness arm here): the echo probe asks a
# PROMPT a question, and under the auto policy these panes are not at a prompt -
# they are running the respawned command. B2/B3 are the liveness claim in the
# form this policy allows: the marker pings are produced by the new child, so a
# pane that came back as a frozen picture cannot make them appear. The input
# direction is covered on the same restore path by A9, C4 and E5b.
Stop-TestProcs

# ============================================================================
Say "== C: a recorded cwd that no longer exists still yields a working prompt"
# ============================================================================
Reset-State 'c'
$workC = Join-Path $root 'workC'
New-Item -ItemType Directory -Force $workC | Out-Null
Build-AndKill $workC | Out-Null
Remove-Item -Recurse -Force $workC -ErrorAction SilentlyContinue
Assert "C1 the recorded working directory is gone" (-not (Test-Path $workC))

$appPidC = Start-App 'nocwd'
Assert "C2 the GUI came back" ($appPidC -ne 0)
$treeC = Wait-Leaves 'c0' 3 60
Assert "C3 the layout restored anyway" ((All-Leaves $treeC).Count -ge 3)
$leavesC = All-Leaves $treeC
$respC = 0
foreach ($leaf in $leavesC) { if (Test-PaneResponsive $leaf.id "c$($leaf.id.Substring(0,4))") { $respC++ } }
Assert "C4 every pane is interactive despite the missing cwd ($respC/$($leavesC.Count))" `
    ($respC -eq $leavesC.Count)
Assert "C5 still nothing was re-executed" `
    (((Count-MarkerPings $MARK_A) + (Count-MarkerPings $MARK_B)) -eq 0)
Stop-TestProcs

# ============================================================================
Say "== D: the recorded cwd FOLLOWS the shell, so a restore lands where the user IS (T425)"
# ============================================================================
# The other half of the user's 2026-08-03 report: "I expected ... the last known
# CWD to be restored in the shell." The agent recorded `OPEN.cwd` once, at spawn,
# and nothing ever updated it - so a pane the user had `cd`'d out of came back in
# the directory it STARTED in. This arm moves the shell, then proves the move
# survives an agent restart. Arm C pins the opposite corner (a recorded cwd that
# no longer exists), so between them the recorded value is held from both sides.
Reset-State 'd'
$workD = Join-Path $root 'workD'
$deepD = Join-Path $workD 'deeper-cwd'
New-Item -ItemType Directory -Force $deepD | Out-Null

$appPidD = Start-App 'cwdtrack' @("--working-directory=$workD")
Assert "D1 the GUI came up" ($appPidD -ne 0)
$leavesD0 = All-Leaves (Wait-Leaves 'd0' 1 45)
Assert "D2 there is a pane to work with" ($leavesD0.Count -ge 1)
$paneD = $leavesD0[0].id
# Positive control: the pane takes input at all. Without it, a later FAIL cannot
# be told apart from "nothing was ever typed into anything".
Assert "D3 the pane is interactive before we move it" (Test-PaneResponsive $paneD 'd-pre')

# Move the shell. `/d` so the arm still works if $TEMP is on another drive.
Run-CliArgs @('+send-keys', "--target=$paneD", "cd /d $deepD", 'Enter') "$tmp\keys-d.txt" 12 | Out-Null
Assert "D4 the shell actually moved to the deeper directory" `
    (Wait-PaneTextTight $paneD 'd-moved' 'deeper-cwd' 2 30)

# THE oracle for the fix: the agent's OWN on-disk record. That file is the only
# thing a restart has to work from, so asserting on it is asserting on exactly
# what was broken - and it cannot say `deeper-cwd` unless the shell really moved
# AND the refresh really ran. The refresh rides a 10s reaper tick.
$metaD = Join-Path $tmp 'ghoztty\local-agent-debug\sessions.json'
$sawDeep = $false
$deadlineD = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadlineD) {
    if ((Test-Path $metaD) -and ((Out-Text $metaD) -match 'deeper-cwd')) { $sawDeep = $true; break }
    Start-Sleep -Milliseconds 700
}
Assert "D5 the agent recorded the LAST KNOWN cwd, not the spawn cwd" $sawDeep

# Take the app AND the agent down: the reboot / agent-upgrade shape.
$agentD = Wait-AgentPid $tmp 25
Assert "D6 an agent is running for this run" ($agentD -ne 0)
Start-Sleep -Seconds 3   # let the session-layout manifest debounce out
Stop-AppOnly
Stop-AgentAndHolders $agentD | Out-Null
Start-Sleep -Seconds 2

$appPidD2 = Start-App 'cwdrestore'
Assert "D7 the GUI came back" ($appPidD2 -ne 0)
$leavesD1 = All-Leaves (Wait-Leaves 'd2' 1 60)
Assert "D8 the pane restored" ($leavesD1.Count -ge 1)
$paneD2 = $leavesD1[0].id
# `cd` with no argument makes cmd.exe PRINT its working directory, so the
# assertion is on what the shell says it is - not on what the prompt happened to
# paint before the restore notice scrolled past.
Run-CliArgs @('+send-keys', "--target=$paneD2", 'cd', 'Enter') "$tmp\keys-d2.txt" 12 | Out-Null
Assert "D9 the restored fresh shell is in the LAST KNOWN directory" `
    (Wait-PaneTextTight $paneD2 'd-after' $deepD 1 40)
Stop-TestProcs

# ============================================================================
Say "== E: the notice never takes a banner slot the PANE already owns (T422)"
# ============================================================================
# The third of the user's 2026-08-03 symptoms: "When windows were reopened, all
# the previous banners were replaced with [the session-interrupted notice]. I
# expected banners to be rehydrated, window titles too."
#
# Their banners carry state unique to each pane (goal, status, PR links); the
# notice is the SAME sentence in every pane, so replacing N banners with N copies
# of it is strictly negative. Since T423 the notice also lives in the scrollback,
# which is what makes dropping the second carrier safe - so the rule is: the
# banner slot belongs to the pane, and the notice only ever uses one that is free.
#
# This arm is the mixed case on purpose. Two of the three restored panes carry a
# banner (E1/E2) and one does not (E4), so it scores the precedence rule rather
# than a blanket "notices are gone" or "banners are gone".
Reset-State 'e'
Build-AndKill $workA $true | Out-Null

$appPidE = Start-App 'notifyban'
Assert "E0 the GUI came back" ($appPidE -ne 0)
$leavesE = Wait-BannerSettle 'e0' 3 60
Assert "E0b the layout restored (3 panes)" ($leavesE.Count -ge 3)

$ownA = 0; $ownB = 0; $noticed = 0; $bannerless = 0
foreach ($leaf in $leavesE) {
    $b = [string]$leaf.banner
    if ($b -match [regex]::Escape($BAN_A)) { $ownA++ }
    if ($b -match [regex]::Escape($BAN_B)) { $ownB++ }
    if ($b -match 'Session interrupted') { $noticed++ }
    if ($b -eq '') { $bannerless++ }
}
# E3/E4 are counting assertions, and a bare "FAIL" on one leaves three different
# stories indistinguishable (the notice took a slot it shouldn't have / it took
# none at all / a fourth pane appeared). Print what was actually read.
"    DIAG E: ownA=$ownA ownB=$ownB noticed=$noticed bannerless=$bannerless leaves=$($leavesE.Count)"
foreach ($leaf in $leavesE) {
    "    DIAG E leaf: name='$($leaf.ipc_name)' banner='$(([string]$leaf.banner) -replace '\s+', ' ')'"
}
Assert "E1 the pane that had banner '$BAN_A' still shows it" ($ownA -eq 1)
Assert "E2 the pane that had banner '$BAN_B' still shows it" ($ownB -eq 1)
Assert "E3 neither of those panes had its banner replaced by the notice" `
    ($noticed -le 1 -and $bannerless -eq 0)
Assert "E4 the bannerless pane DID take the notice (the slot was free)" ($noticed -eq 1)

# Nothing is lost by yielding the slot: the notice is still in the scrollback of
# every pane, which is where the user asked for it (T423). Without this, E1-E3
# would also pass against a build that simply stopped emitting the notice.
$textE = 0
foreach ($leaf in $leavesE) {
    $place = Get-NoticePlacement $leaf.id "etxt$($leaf.id.Substring(0,4))"
    if ($place.notice -ge 0) { $textE++ }
}
Assert "E5 every restored pane still carries the notice in its scrollback ($textE/$($leavesE.Count))" `
    ($textE -eq $leavesE.Count)

# E5b (T652): ATTACHED IS NOT ALIVE. E1-E5 are read off the SCREEN and out of
# `+list --json`, and a pane that came back as a frozen picture satisfies every
# one of them - a restored banner and a notice in the scrollback are exactly
# what a recording looks like. Type into each one.
$respE = 0
foreach ($leaf in $leavesE) {
    if (Test-PaneResponsive $leaf.id "elive$($leaf.id.Substring(0,4))") { $respE++ }
}
Assert "E5b every pane whose banner came back is on a LIVE shell ($respE/$($leavesE.Count))" `
    ($respE -eq $leavesE.Count)

# The other half of the report: the window title pin comes back too.
$titleE = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $tree = Get-List 'e-title'
    $wins = @(Windows-Of $tree)
    if (@($wins | Where-Object { [string]$_.title -match [regex]::Escape($WIN_TITLE) }).Count -ge 1) {
        $titleE = $true; break
    }
    Start-Sleep -Milliseconds 700
}
Assert "E6 the restored window's title pin came back" $titleE
Stop-TestProcs

# ============================================================================
Say "== F: a TYPED command is named by the notice - the foreground sample (T429)"
# ============================================================================
# The arm A comment above says it: every arm-A pane is opened with an explicit
# `--command=`, the one field that made the agent record a label at all. The
# shape the user actually runs is a PLAIN shell pane where the command was
# TYPED at the prompt - and for that pane the notice could never name anything,
# because nothing ever recorded what was running. T429 makes the agent sample
# the shell's live FOREGROUND command (its most recent ConPTY child, read via
# the PEB) on the same slow tick that tracks the cwd (arm D), persist it to
# sessions.json, and hand it to the notice on the dead attach.
Reset-State 'f'
$workF = Join-Path $root 'workF'
New-Item -ItemType Directory -Force $workF | Out-Null

$appPidF = Start-App 'fgsample' @("--working-directory=$workF")
Assert "F1 the GUI came up" ($appPidF -ne 0)
$leavesF0 = All-Leaves (Wait-Leaves 'f0' 1 45)
Assert "F2 there is a plain shell pane (no --command)" ($leavesF0.Count -ge 1)
$paneF = $leavesF0[0].id
Assert "F3 the pane is interactive before typing anything" (Test-PaneResponsive $paneF 'f-pre')

# TYPE the command, the way a user does. `--keys-file` sends the bytes verbatim
# (no re-tokenizing hazards), the trailing Enter submits it.
$kfF = Join-Path $tmp 'fgcmd.txt'
Set-Content -NoNewline -Encoding ascii -Path $kfF -Value $CMD_F
Run-CliArgs @('+send-keys', "--target=$paneF", "--keys-file=$kfF", 'Enter') "$tmp\keys-f.txt" 12 | Out-Null
Assert "F4 the typed command is actually running" (Wait-MarkerPings $MARK_F 1 30)

# THE oracle for the sample: the agent's OWN on-disk record gains an `fg_cmd`
# naming the typed command. That file is all a restart has to work from, and it
# cannot say this unless the ping is really running AND the sampler really saw
# it. The sample rides the same 10s tick as the cwd refresh (arm D).
$metaF = Join-Path $tmp 'ghoztty\local-agent-debug\sessions.json'
$sawFg = $false
$deadlineF = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadlineF) {
    $mtext = Out-Text $metaF
    if ($mtext -match 'fg_cmd' -and $mtext -match [regex]::Escape("-n $MARK_F")) { $sawFg = $true; break }
    Start-Sleep -Milliseconds 700
}
Assert "F5 the agent sampled the TYPED foreground command into sessions.json" $sawFg

# Take the app AND the agent down: the reboot / agent-upgrade shape.
$agentF = Wait-AgentPid $tmp 25
Assert "F6 an agent is running for this run" ($agentF -ne 0)
Start-Sleep -Seconds 3   # let the session-layout manifest debounce out
Stop-AppOnly
Stop-AgentAndHolders $agentF | Out-Null
Start-Sleep -Seconds 2
Stop-MarkerPings
Start-Sleep -Milliseconds 800
Assert "F7 no marker process survived the agent kill" ((Count-MarkerPings $MARK_F) -eq 0)

$appPidF2 = Start-App 'fgnotify'
Assert "F8 the GUI came back" ($appPidF2 -ne 0)
$leavesF1 = All-Leaves (Wait-Leaves 'f1' 1 60)
Assert "F9 the pane restored" ($leavesF1.Count -ge 1)
$paneF2 = $leavesF1[0].id

# The notice names the TYPED command, in both carriers. The banner is the
# strong oracle (the only way the marker reaches it is through the notice); in
# the scrollback the typed command also appears as replayed history, so the
# in-stream assertion keys on the notice's own "Previous command:" label.
$sawBanF = $false
$deadlineF2 = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadlineF2) {
    $leavesF1 = All-Leaves (Get-List 'f2')
    $b = @($leavesF1 | ForEach-Object { [string]$_.banner }) -join ' '
    if ($b -match 'Session interrupted' -and $b -match [regex]::Escape("-n $MARK_F")) { $sawBanF = $true; break }
    Start-Sleep -Milliseconds 700
}
Assert "F10 the banner notice names the typed command" $sawBanF
Assert "F11 the scrollback notice names it under 'Previous command:'" `
    (Wait-PaneTextTight $paneF2 'f-txt' "Previouscommand:ping-n$MARK_F" 1 40)
Assert "F12 the typed command was NOT re-executed (restore policy)" ((Count-MarkerPings $MARK_F) -eq 0)
Assert "F13 the restored pane is on a live, interactive shell" (Test-PaneResponsive $paneF2 'f-post')
Stop-TestProcs

} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    if ($KeepTemp) { Write-Host "  kept the run tree: $root" }
    else { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Say "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert "G1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "G2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

# --- stamp (T783/T823) ------------------------------------------------------
# A green run records the content of every file this harness covers, so
# scripts\guard-due.ps1 can answer "has anything run it against the code as it
# now stands?". The reboot floor's promise - an agent restart never re-runs a
# recorded command - is invisible to every lane and to P1-P3, so without this a
# Remote.zig edit that broke it would surface at the user's next reboot. Red
# leaves the stamp alone, so a failure stays due.
if ($script:failures -eq 0) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\guard-due.ps1') `
        update -Guard session-relaunch -Repo $repoRoot 2>&1 | ForEach-Object { Say "  $_" }
}

Say ""
if ($script:failures -eq 0) { Say "SESSION-RELAUNCH-NOTIFY: ALL PASS ($script:passes)"; exit 0 }
else { Say "SESSION-RELAUNCH-NOTIFY: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
