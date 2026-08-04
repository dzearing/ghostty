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
# The new default is `notify`: no respawn, a fresh shell in the recorded working
# directory, and a notice above it naming the command that was running.
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
#      overlay, which is all that used to survive.
#   B: negative control / opt-in - `--session-relaunch=auto` still respawns the
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
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-relaunch-notify-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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
$CMD_A = "ping -n $MARK_A 127.0.0.1"
$CMD_B = "ping -n $MARK_B 127.0.0.1"

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Stop-MarkerPings
    Start-Sleep -Milliseconds 700
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
        Where-Object { $_.CommandLine -like "*-n $MARK_A *" -or $_.CommandLine -like "*-n $MARK_B *" } |
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
function Get-NoticePlacement($id, $tag, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $out = @{ notice = -1; shell = -1 }
    while ((Get-Date) -lt $deadline) {
        $tight = (Read-Pane $id $tag 400) -replace '\s', ''
        $out.notice = $tight.IndexOf('sessioninterrupted')
        $out.shell = $tight.IndexOf('>')
        if ($out.notice -ge 0 -and $out.shell -ge 0) { break }
        Start-Sleep -Milliseconds 700
    }
    return $out
}

# THE liveness oracle for a pane: type a unique marker and read it back.
function Test-PaneResponsive($id, $tag, $timeoutSec = 30) {
    $marker = "T230x$($tag)x$(Get-Random -Maximum 999999)"
    Run-CliArgs @('+send-keys', "--target=$id", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $txt = (Read-Pane $id "resp-$tag") -replace '\s', ''
        # Twice: once as the echoed input line, once as the command's output. One
        # occurrence is just the keystrokes landing in a dead pane's line editor.
        $hits = ([regex]::Matches($txt, [regex]::Escape($marker))).Count
        if ($hits -ge 2) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Start-App($title, $extraArgs = @()) {
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extraArgs -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    Assert "leak: '$title' has no window on the interactive desktop" `
        (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    return [int]$app.Pid
}

# Build the 2-pane layout, then take the app AND the agent down so the next
# launch finds dead-but-relaunchable tombstones - exactly the reboot / agent-
# upgrade shape.
function Build-AndKill($cwdA) {
    $appPid = Start-App 'build' @("--working-directory=$cwdA")
    Assert "setup: the GUI came up" ($appPid -ne 0)
    Wait-Leaves 'b0' 1 | Out-Null
    # The `--command=` value MUST carry its own quotes: `Start-Process
    # -ArgumentList` joins the array with spaces and quotes NOTHING, so a bare
    # `--command=ping -n 9717 127.0.0.1` is re-tokenized into four positional
    # arguments and the pane opens on something else entirely. (Measured: the
    # first run of this script scored every marker assertion FAIL for exactly
    # this reason - the product was fine.)
    Run-CliArgs @('+new-window', '--target=nA', "--command=`"$CMD_A`"", "--working-directory=$cwdA") "$tmp\nwA.txt" 25 | Out-Null
    Start-Sleep -Seconds 2
    Run-CliArgs @('+split', '--target=nA', '--name=nB', '--direction=right', "--command=`"$CMD_B`"") "$tmp\spB.txt" 25 | Out-Null
    $tree = Wait-Leaves 'b1' 3 45
    Assert "setup: both commanded panes exist" ((All-Leaves $tree).Count -ge 3)
    Assert "setup: '$CMD_A' is actually running" (Wait-MarkerPings $MARK_A 1 30)
    Assert "setup: '$CMD_B' is actually running" (Wait-MarkerPings $MARK_B 1 30)
    $agent = Wait-AgentPid $tmp 25
    Assert "setup: an agent is running for this run" ($agent -ne 0)

    Start-Sleep -Seconds 3   # let the session-layout manifest debounce out
    Stop-AppOnly
    Stop-Process -Id $agent -Force -ErrorAction SilentlyContinue
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
Say "== A: the default (notify) - the recorded commands are NOT re-run"
# ============================================================================
Reset-State 'a'
Build-AndKill $workA | Out-Null

$appPidA = Start-App 'notify'
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
$leavesA = All-Leaves (Wait-Leaves 'a1' 3 30)
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
$textNotice = 0; $textAbove = 0; $shellPainted = 0; $textCmd = 0
foreach ($leaf in $leavesA) {
    $short = $leaf.id.Substring(0, 4)
    $place = Get-NoticePlacement $leaf.id "atxt$short"
    if ($place.notice -ge 0) { $textNotice++ }
    if ($place.shell -ge 0) { $shellPainted++ }
    if ($place.notice -ge 0 -and $place.shell -ge 0 -and $place.notice -lt $place.shell) { $textAbove++ }
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
Stop-TestProcs

# ============================================================================
Say "== B: opt-in - session-relaunch=auto STILL respawns the recorded command"
# ============================================================================
Reset-State 'b'
Build-AndKill $workA | Out-Null
$appPidB = Start-App 'auto' @('--session-relaunch=auto')
Assert "B1 the GUI came back" ($appPidB -ne 0)
Wait-Leaves 'b2' 3 60 | Out-Null
Assert "B2 '$CMD_A' WAS respawned under the auto policy" (Wait-MarkerPings $MARK_A 1 40)
Assert "B3 '$CMD_B' WAS respawned under the auto policy" (Wait-MarkerPings $MARK_B 1 40)
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
Stop-Process -Id $agentD -Force -ErrorAction SilentlyContinue
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

} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Say "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert "G1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "G2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

Say ""
if ($script:failures -eq 0) { Say "SESSION-RELAUNCH-NOTIFY: ALL PASS ($script:passes)"; exit 0 }
else { Say "SESSION-RELAUNCH-NOTIFY: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
