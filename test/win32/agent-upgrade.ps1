# T147 acceptance: NON-DESTRUCTIVE local-agent upgrade delivery.
#
# The defect: the upgrade script deliberately swaps ghoztty-agent.exe WITHOUT
# killing the running agent (T89h) - killing it is the silent session reset
# docs/claude/sessions.md's "Agent contract & upgrade compatibility" section forbids. But
# nothing then ever ADOPTED the new binary, so an agent-side fix reached the
# user only after a reboot. The app now compares the running agent's HELLO build
# stamp against the one it ships beside, and refreshes at the two safe moments -
# silently when nothing is live, and never silently when something is.
#
# Measured by OUTCOME (agent pids, dialogs on screen, panes that still answer),
# not by log scraping:
#
#   A: premise - `ghoztty-agent --version` prints a parseable stamp. Everything
#      below rests on it, so it is asserted rather than assumed.
#   B: negative control - a CURRENT agent is never touched. No dialog, same
#      agent pid, pane still responsive after a full check cycle.
#   C: stale + a live session => NOTHING HAPPENS. No dialog, the same agent pid,
#      the live pane untouched, and the decision logged as a deliberate
#      leave-alone. This is T1056's contract assert (see below).
#   E: the adoption promise - closing the last pane makes the agent idle, and the
#      refresh then happens SILENTLY (new agent pid, no dialog anywhere in the
#      arm). "Ghoztty updates automatically the next time no sessions are open"
#      is a promise the code has to keep, and it is the whole reason leaving a
#      live agent alone costs the user nothing.
#   F: negative control - session-persistence=off never runs the check at all.
#   H: T229/T1056 - the user's shape: RESTORED windows, several BUSY sessions, a
#      stale agent. The app leaves every one of them alone. This is the arm that
#      stands for the 95 sessions the Mac 1.33.0 update tombstoned.
#   I: negative control - a refresh that CANNOT re-dial says so, and the app
#      stays up. Driven through the skew path, the only one that still restarts
#      an agent whose sessions are live.
#   J: T125 - a PROTOCOL SKEW (the handshake itself fails, so there is no
#      connection to judge) takes the mandatory-update path, and answering it
#      actually replaces the agent, leaves the full step trail, and brings the
#      panes back in place.
#   K: T125 negative control - a skew where the AGENT is the newer side is never
#      acted on. The app is the out-of-date one; downgrading it would eat
#      sessions a newer app could still have attached to.
#   L: T907/T1056 - handoff-capable, but a session the agent owns DIRECTLY is
#      still live => the update drains and nobody is asked to hurry it along.
#   M: T907 - handoff-capable and every live session holder-backed => the app
#      STANDS DOWN. No dialog, the decision logged as such, no destructive
#      restart attempted, and the agent's own replacement carries the session
#      across.
#
# T1056 - what a STALE BUILD may cost the user, which is now nothing. An app
# update replaces ghoztty-agent.exe while the running agent keeps every PTY
# attached, and the staleness check used to read that build-stamp gap as grounds
# for a restart. It is not one: proto_version is negotiated in HELLO and a
# mismatch is fatal there, so an agent we can talk to has already agreed the wire
# contract, and everything since rides additive capabilities that degrade on
# their own. Mac's 1.33.0 update took that path and tombstoned 95 live sessions
# for a binary refresh nothing required.
#
# So the mandatory confirmation is now reserved for a skew the handshake actually
# flags as incompatible - arms J and I - and arms C/E/H/L assert that a stale
# BUILD produces no dialog and no restart while anything is live. Anyone reading
# "the confirmation never appears for a stale agent" as a regression should start
# here: it is the fix.
#
# T1037 - WHICH stale agent lands on WHICH policy arm, because the answer has
# changed twice under this harness and nothing was obliged to notice. T907 gave
# the agent the ability to replace ITSELF without losing a session (arm M);
# T1056 then made every OTHER live-session arm a leave-alone too. The three are
# told apart only by the decision line, so arms C/E/H/L each assert the reason
# they are named for rather than just "no dialog".
#
# Arms C/E/H/I run as the LEGACY generation via
# `GHOSTTY_AGENT_SUPPRESS_CAPS=agent_handoff` (the T469 test seam): the agent
# this tree builds then advertises what a pre-T907 agent advertised, so it cannot
# replace itself. That is the generation with the most to lose from a restart -
# it has no handoff to fall back on - and each of those arms asserts
# `handoff-capable=false` in the decision line, so an arm cannot silently stop
# exercising the case it names.
#
# The staleness INPUT is faked with GHOZTTY_AGENT_BUNDLED_VERSION (a debug-only
# hook): every stamp in a real build comes from the same binary the agent runs,
# so there is no way to fabricate an old agent from a new tree. The decision and
# the restart it drives are the shipping ones.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so
# it never takes the user's foreground - asserted at the end, not assumed. The
# private win32 driver this script used to carry (its own T86 GrabForeground +
# SendInput + EnumWindows) is gone. Notes on what the harness changes here:
#
#   * The GUI is launched with Start-OnTestDesktop, so its window is created on
#     the test desktop. The env this script sets (LOCALAPPDATA,
#     GHOSTTY_LOCAL_AGENT_BIN, GHOZTTY_AGENT_BUNDLED_VERSION,
#     GHOZTTY_PIPE_SUFFIX) still reaches it - CreateProcessW inherits the
#     harness process's block.
#   * ConfirmDialog is NOT a standard #32770: it runs its own nested pump
#     (ConfirmDialog.runModal) reading WM_KEYDOWN straight off the queue, so a
#     POSTED Escape/Tab/Enter drives it (Send-TestControlKey) with no foreground
#     grab and no focus call.
#   * The `+...` CLI invocations stay on Start-Process. They are console-only
#     and windowless; nothing about them can steal foreground, and routing them
#     through the desktop would buy nothing.
#
# Hermetic: per-run $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN + a private IPC
# pipe suffix, and it only ever kills ghoztty / ghoztty-agent processes launched
# from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\agent-upgrade.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-agent-upgrade-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# Write-Host, never the pipeline: a helper that asserts AND returns a value
# would otherwise hand its caller an array of @('  PASS ...', $realValue), and
# the caller's `.Pid` / `-eq` silently reads the wrong element. Start-App below
# does exactly that pairing.
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# Arm I runs its agent from a COPY under this script's temp root, so its command
# line never mentions zig-out and the `*zig-out*` filter alone left it running
# after the script exited. A leftover agent owns the agent pipe name (which is
# NOT namespaced by GHOZTTY_PIPE_SUFFIX), so the NEXT run's app dials the corpse
# instead of spawning its own: measured 2026-08-03 as 33 failures on a re-run of
# a script that had just passed 85. Match the temp root too.
$script:TestProcRoot = Join-Path $env:TEMP 'ghoztty-agent-upgrade-'
# T199: Stop-TestProcs below is the deliberate teardown; this is the one that
# runs when the script does NOT reach it (a throw, an early exit, a failed
# assertion), which is when a leak actually happens. Same rule, one root.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-HarnessGhozttyRoot -Root $root | Out-Null
function Stop-TestProcs {
    # T351: deliberately NOT the shared Stop-RepoGhoztty, which matches on the
    # exact image NAME of $Exe and its sibling. This script also runs agents from
    # a per-run staging root under a renamed image, and both are invisible to an
    # exact-name filter - see the next paragraph.
    #
    # `ghoztty-agent%`, not `ghoztty-agent.exe`: arm M runs its agent from
    # `ghoztty-agent.exe.bak` (the image name a real delivery leaves the RUNNING
    # agent with), and Win32_Process.Name is the image name recorded at
    # creation - so an exact-name filter would walk straight past the one
    # process that arm is about and leak it into the next run.
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent%')) {
        # cleanslate-exempt: LIKE, because the image under test is ghoztty-agent.exe.bak
        Get-CimInstance Win32_Process -Filter "Name LIKE '$n'" |
            Where-Object {
                $_.CommandLine -like '*zig-out*' -or
                $_.ExecutablePath -like "$script:TestProcRoot*"
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# The agents belonging to THIS run (their command line names this run's state
# dir). Never the user's release agent, never another test's.
function Get-RunAgents($tmp) {
    # `--pty-host` children are the same binary (T904): one per holder-backed
    # session, spawned by the agent under test. They are NOT the session manager,
    # and every `Agent-Pid` comparison in this script means the manager - so a
    # holder answering "the agent pid" would make "same pid" and "new pid" both
    # arbitrary. Holders became the default in T909, which is when this filter
    # started earning its place.
    # `LIKE 'ghoztty-agent%'` for arm M, whose agent runs from
    # `ghoztty-agent.exe.bak` - see Stop-TestProcs.
    return , @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ghoztty-agent%'" |
        Where-Object { $_.CommandLine -like "*$tmp*" -and $_.CommandLine -notmatch '--pty-host' })
}
function Agent-Pid($tmp) {
    $a = Get-RunAgents $tmp
    if ($a.Count -eq 0) { return 0 }
    return [int]$a[0].ProcessId
}
function Wait-AgentPid($tmp, $timeoutSec = 25, $notPid = 0) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Agent-Pid $tmp
        if ($p -ne 0 -and $p -ne $notPid) { return $p }
        Start-Sleep -Milliseconds 400
    }
    return (Agent-Pid $tmp)
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) unless a caller passes its own - section F launches with =false as its negative control.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit. Touching `.Handle` after
    # exit is too late: PowerShell then reads back an EMPTY ExitCode, and every
    # caller that gates on `-eq 0` scores a working CLI as a failure. (That is
    # exactly how this script's first run reported "no panes" against a build
    # whose +list output was sitting complete in the file.)
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tmp, $tag, $timeoutSec = 12) {
    # Judged on the OUTPUT, not the exit code: the answer is the JSON, and a
    # harness that discards a complete answer over a shell-plumbing detail is a
    # harness that fabricates failures.
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
    foreach ($w in Windows-Of $tree) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Leaf-Count($tree) { return (All-Leaves $tree).Count }

# THE liveness oracle for a pane: type a unique marker and read it back.
function Test-PaneResponsive($tmp, $target, $tag, $timeoutSec = 25) {
    $marker = "T147x$($tag)x$(Get-Random -Maximum 999999)"
    Run-CliArgs @('+send-keys', "--target=$target", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        # Same rule as Get-List: the marker coming back IS the oracle, so the
        # read is never gated on an exit code.
        Run-CliArgs @('+read', "--name=$target", '--lines=300') "$tmp\read-$tag.txt" 12 | Out-Null
        $txt = (Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', ''
        if ($txt -match [regex]::Escape($marker)) { return $true }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

# The confirmation, on the test desktop. Class-filtered by the harness, so
# "found" already means it is a GhozttyConfirmDialog owned by this app.
function Find-Dialog($appPid) {
    return Get-TestWindow -ProcessId ([int]$appPid) -Class 'GhozttyConfirmDialog'
}
function Wait-Dialog($appPid, $timeoutSec = 30) {
    return Wait-TestWindow -ProcessId ([int]$appPid) -Class 'GhozttyConfirmDialog' `
        -TimeoutMs ($timeoutSec * 1000)
}
# Take "Update Now", verified. A blind Tab+Enter is NOT safe here: measured on
# box, the confirmation can come up with focus on a control that is neither
# button, and one Tab then lands on "Later" - so the run silently measures the
# DECLINE path while asserting things about the accept path. Tab until the
# focused control's own text says Update, then Enter.
function Confirm-Update($dlg) {
    for ($k = 0; $k -lt 4; $k++) {
        $f = Get-TestFocusedWindow -Window $dlg
        $t = if ($f -ne [IntPtr]::Zero) { Get-TestControlText -Control $f } else { '' }
        if ($t -like '*Update*') { break }
        Send-TestControlKey -Control $dlg -Key Tab | Out-Null
        Start-Sleep -Milliseconds 300
    }
    $f = Get-TestFocusedWindow -Window $dlg
    $t = if ($f -ne [IntPtr]::Zero) { Get-TestControlText -Control $f } else { '' }
    Assert "  (focus is on 'Update Now' before Enter)" ($t -like '*Update*')
    return (Send-TestControlKey -Control $dlg -Key Enter)
}

function Wait-NoDialog($appPid, $timeoutSec = 12) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Find-Dialog $appPid) -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# The app's decision log (T201). The exe under test is a DEBUG build, i.e. the
# Console subsystem, so std.log goes to STDERR -- the
# %LOCALAPPDATA%\ghoztty\ghoztty.log sink is release-only. Each arm therefore
# captures its own stderr file, which also means no offset bookkeeping across
# arms. Opened with FileShare.ReadWrite because the app still holds it.
function Read-AppLog($path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le 0) { return '' }
            $buf = New-Object byte[] $fs.Length
            $n = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
# Poll rather than read once: the line we want may not be flushed yet, and a
# bare read would turn a timing gap into a false failure.
function Wait-LogMatch($path, $pattern, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-AppLog $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Launch the GUI ON THE TEST DESKTOP and wait for its window. Sets
# $script:AppLog (this launch's captured stderr, which is also its stdout - the
# harness points both handles at one file) and $script:AppTop (the owner hwnd,
# needed for the modality assertions). Returns the pid, or 0.
function Start-App($tmp, $title, $extraArgs = @()) {
    $argv = @("--title=$title") + $extraArgs
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    $script:AppTop = [IntPtr]::Zero
    # persistence: on (default) - the agent under test only owns sessions when persistence is on.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $argv -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    $script:AppTop = $top
    if ($top -eq [IntPtr]::Zero) { return 0 }
    Assert "leak: '$title' has no window on the interactive desktop" `
        (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    return [int]$app.Pid
}
function Wait-Panes($tmp, $tag, $target, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tmp $tag 10
        if ((Leaf-Count $tree) -ge $target) { return $tree }
        Start-Sleep -Milliseconds 500
    }
    return (Get-List $tmp "$tag-last" 10)
}

# A stamp that is unambiguously NEWER than any real build, so the policy's
# never-downgrade rule can't quietly turn the test into a no-op.
$FAKE_NEW = '29991231-t147fake'

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedOverride = $env:GHOZTTY_AGENT_BUNDLED_VERSION
$savedProto = $env:GHOZTTY_AGENT_PROTO_VERSION
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
# T1037: the three knobs that decide WHICH arm of the policy a stale agent lands
# on - whether it can replace itself at all, whether its sessions can be carried
# across when it does, and how long it waits before doing it.
$savedSuppress = $env:GHOSTTY_AGENT_SUPPRESS_CAPS
$savedHolder = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedForce = $env:GHOZTTY_AGENT_HANDOFF_FORCE
$savedInterval = $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $null
# Holders ON is the shipping default (T909) and every arm below depends on
# knowing which it got, so it is stated rather than inherited: arm L turns them
# off to build its legacy session, and arms B-K are unaffected either way.
$env:GHOZTTY_AGENT_PTY_HOLDER = '1'
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = $null
$env:GHOZTTY_AGENT_HANDOFF_FORCE = $null
$env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $null
# Isolate the IPC endpoint unconditionally: every `+list` / `+read` /
# `+send-keys` below is an oracle, and an instance answering the shared pipe
# would answer them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = "-agentupg$PID"

# T1033: this script launches the app itself (Start-Process, not the test
# desktop's helper), so it asks the pre-flight question the helper asks: are
# these bytes ours to drive, or the ones the user's installed Ghoztty owns?
# Here rather than at the top of the file so the `+version` it runs is itself
# inside the hermetic env above.
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
Say "== A: premise - the agent reports a parseable build stamp"
# ============================================================================
$verOut = Join-Path $tmp 'version.txt'
$vp = Start-Process -FilePath $AgentExe -ArgumentList @('--version') -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $verOut -RedirectStandardError "$verOut.err"
$null = $vp.Handle
$vp.WaitForExit()
$verText = (Out-Text $verOut).Trim()
Say "    --version => '$verText'"
Assert "A1 --version exits 0" ($vp.ExitCode -eq 0)
Assert "A2 --version prints 'ghoztty-agent <stamp>'" ($verText -match '^ghoztty-agent\s+\S+$')
$stamp = ($verText -split '\s+')[-1]
Assert "A3 the stamp is non-empty" ($stamp.Length -gt 0)
# The date prefix is what the never-downgrade rule orders on; a build with no
# date ('dev') still works, but say so out loud rather than silently.
if ($stamp -notmatch '^\d{8}-') { Say "    NOTE: stamp '$stamp' has no YYYYMMDD prefix (dev build)" }

# ============================================================================
Say "== B: negative control - a CURRENT agent is never touched"
# ============================================================================
$appPidB = Start-App $tmp 't147-current'
$logB = $script:AppLog
Assert "B1 the GUI came up" ($appPidB -ne 0)
$treeB = Wait-Panes $tmp 'b0' 1
Assert "B2 it has a pane" ((Leaf-Count $treeB) -ge 1)
$agentB = Wait-AgentPid $tmp 25
Assert "B3 an agent is running for this run" ($agentB -ne 0)
# The launch check has already run by the time +list answers; give it room
# anyway, then assert nothing happened.
Start-Sleep -Seconds 6
Assert "B4 no confirmation dialog for a current agent" ((Find-Dialog $appPidB) -eq [IntPtr]::Zero)
Assert "B5 the agent was NOT restarted (same pid)" ((Agent-Pid $tmp) -eq $agentB)
$leafB = (All-Leaves (Get-List $tmp 'b1' 10))[0]
Assert "B6 the pane still works" (Test-PaneResponsive $tmp $leafB.id 'b')
# T201: "nothing happened" must be SAID, not inferred from an absence. Before
# this, the .none arm logged nothing at all, so a current agent and a check that
# never ran produced identical logs.
Assert "B7 the no-op decision is logged with its reason" `
    (Wait-LogMatch $logB 'agent upgrade check: no action, running agent is the bundled build' 20)
Stop-TestProcs

# ============================================================================
Say "== C: stale LEGACY agent + a live session => the app leaves it strictly alone"
# ============================================================================
# THE T1056 contract assert. The agent is stale, it cannot replace itself (a
# pre-T907 generation), and it owns a live session - the exact state that used to
# put a modal on screen offering to end that session for a binary refresh. The
# app must now do nothing at all: the running agent is protocol-compatible by the
# fact that we are talking to it, so the newer build costs the user nothing until
# the next quiet moment (arm E) and everything to adopt right now.
#
# Measured as three separate facts, because each of them failed differently in
# the field: no dialog (the user is not asked), the same agent pid (nothing was
# restarted behind the ask), and a responsive pane (the session survived).
#
# T1037: the agent for arms C-I is made a pre-T907 one at the source. Suppressing
# the capability in its HELLO is the whole difference between the two
# generations, and it is what a box that has not yet taken the agent-side update
# actually advertises. Set here and left set through arm K; the new arms at the
# end clear it. The agent reads it once at startup, so it must be in place BEFORE
# the app spawns one - which is why Stop-TestProcs at the end of B matters.
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'agent_handoff'
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidC = Start-App $tmp 't147-stale-decline'
$logC = $script:AppLog
$topC = $script:AppTop
Assert "C1 the GUI came up" ($appPidC -ne 0)
$agentC = Wait-AgentPid $tmp 25
Assert "C2 an agent is running for this run" ($agentC -ne 0)

# The decision has to be logged even though nothing happens - in fact
# ESPECIALLY because nothing happens. This arm's whole outcome is an absence, and
# an absence is indistinguishable from a check that never ran unless the check
# says what it decided (T201). The clause also has to be THIS arm's: a
# leave-alone that silently became "current" or "bundled unknown" would pass
# every other assert here while measuring nothing.
Assert "C3 the decision is logged as a deliberate leave-alone" `
    (Wait-LogMatch $logC 'agent upgrade check: stale with live sessions, but protocol-compatible; leaving it alone' 25)
# T1037: and that the agent under test really is the generation with the most to
# lose - a pre-T907 one, which cannot replace itself. Without this, the day the
# seam stops working this arm silently becomes a re-test of arm M.
Assert "C4 the agent under test really is the legacy generation" `
    (Wait-LogMatch $logC 'agent upgrade check: stale with live sessions.*handoff-capable=false' 25)

# THE contract assert, in three parts. Give the app the same wall-clock it used
# to need to raise the dialog before concluding there is none.
$dlgC = Wait-Dialog $appPidC 25
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the stale agent DID raise a confirmation - this run MUST fail'
    Assert "C5 a confirmation was raised for a stale-but-compatible agent (inverted)" ($dlgC -ne [IntPtr]::Zero)
} else {
    Assert "C5 NO confirmation was raised (a build gap is not the user's problem)" `
        ($dlgC -eq [IntPtr]::Zero)
}
Assert "C6 the owner window was never disabled by a modal" `
    (($topC -ne [IntPtr]::Zero) -and (Test-TestWindowEnabled -Window $topC))
Assert "C7 the agent is still running, untouched (same pid)" ((Agent-Pid $tmp) -eq $agentC)
# "Left alone" means left alone: `agent restart: begin` is the first line of the
# destructive path (H/J), so its absence is the checkable form of "the app
# touched nothing".
Assert "C8 the app attempted no destructive restart of its own" `
    ((Read-AppLog $logC) -notmatch 'agent restart: begin')
$treeC = Wait-Panes $tmp 'c0' 1
$leafC = (All-Leaves $treeC)[0]
Assert "C9 the live pane is still responsive" (Test-PaneResponsive $tmp $leafC.id 'c')
Stop-TestProcs

# ============================================================================
Say "== E: the adoption promise - the agent refreshes SILENTLY once it goes idle"
# ============================================================================
# This is the other half of arm C, and the reason C costs the user nothing:
# leaving a stale agent alone is only acceptable if it is genuinely adopted at
# the next quiet moment. Here that moment is made to arrive - the last window
# closes, the agent goes idle, and the refresh happens with no UI at all.
$appPidE = Start-App $tmp 't147-idle'
$logE = $script:AppLog
Assert "E1 the GUI came up" ($appPidE -ne 0)
$agentE = Wait-AgentPid $tmp 25
Assert "E2 an agent is running for this run" ($agentE -ne 0)
Assert "E3 the stale agent was left alone while its session was live" `
    (Wait-LogMatch $logE 'agent upgrade check: stale with live sessions, but protocol-compatible' 25)
Assert "E4 the live agent was not restarted (same pid)" ((Agent-Pid $tmp) -eq $agentE)
$treeE = Wait-Panes $tmp 'e0' 1
$winE = (Windows-Of $treeE)[0]
# Close the only window: its session ENDS (user close intent), so the agent goes
# idle - the moment the deferral promised. Targeted by the registered NAME, not
# the numeric window id: `+close --target=<id>` is a silent no-op, and a close
# that never happened would make the rest of this section vacuous.
Run-CliArgs @('+close', "--target=$($winE.target)") "$tmp\close-e.txt" 15 | Out-Null
$closed = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    if ((Leaf-Count (Get-List $tmp 'e1' 10)) -eq 0) { $closed = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "E5 the window actually closed (the agent is now idle)" $closed
$agentE2 = Wait-AgentPid $tmp 40 $agentE
Assert "E6 the idle agent was refreshed without ever asking (new pid)" ($agentE2 -ne 0 -and $agentE2 -ne $agentE)
Assert "E7 no dialog was shown anywhere in this arm" ((Find-Dialog $appPidE) -eq [IntPtr]::Zero)
# The silent arm is the one most in need of a log line: it restarts the agent
# with no UI at all, so the log is the ONLY record that it happened.
Assert "E8 the silent idle refresh is logged with its reason" `
    (Wait-LogMatch $logE 'agent upgrade check: stale and idle, refreshing now' 20)
Stop-TestProcs

# ============================================================================
Say "== F: negative control - session-persistence=off never runs the check"
# ============================================================================
$appPidF = Start-App $tmp 't147-nopersist' @('--session-persistence=false')
$logF = $script:AppLog
Assert "F1 the GUI came up" ($appPidF -ne 0)
Wait-Panes $tmp 'f0' 1 | Out-Null
Start-Sleep -Seconds 6
Assert "F2 no dialog with persistence off" ((Find-Dialog $appPidF) -eq [IntPtr]::Zero)
Assert "F3 no agent was spawned at all" ((Agent-Pid $tmp) -eq 0)
# The other half of B7: now that a decision always logs, "the check never ran"
# is a checkable claim rather than the default silence.
Assert "F4 no decision line at all with persistence off" `
    ((Read-AppLog $logF) -notmatch 'agent upgrade check:')
Stop-TestProcs

# ============================================================================
Say "== H: T1056 - the user's shape: RESTORED windows, several BUSY sessions, a stale agent"
# ============================================================================
# Arm C passes with ONE freshly-created window holding ONE idle pane. What the
# user actually hits - and what cost 95 sessions on Mac's 1.33.0 update - is
# different in three ways, all of which this arm reproduces:
#
#   * the app RESTORED its windows from the manifest, so every pane is an
#     ATTACH to a session the agent already owned rather than a fresh spawn;
#   * there is more than one window and more than one session; and
#   * the sessions are STREAMING - real work in flight, the thing the user
#     would actually mourn.
#
# The oracle is that ALL of it survives the app noticing a stale agent: no
# dialog, no restart, three panes still answering. Before T1056 this arm asked
# the user to end all three for a binary refresh, and the accepted path is what
# T229 was filed for - so the destructive machinery those asserts covered now
# lives in arm J, which still reaches it through the skew.
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $null
$appPidH1 = Start-App $tmp 't229-build'
Assert "H1 the layout GUI came up" ($appPidH1 -ne 0)
Wait-Panes $tmp 'h0' 1 | Out-Null
Run-CliArgs @('+new-window', '--target=t229w2') "$tmp\h-nw.txt" 20 | Out-Null
Wait-Panes $tmp 'h1' 2 | Out-Null
Run-CliArgs @('+split', '--target=t229w2', '--name=t229p2', '--direction=down') "$tmp\h-sp.txt" 20 | Out-Null
$treeH = Wait-Panes $tmp 'h2' 3
Assert "H2 three panes across two windows" `
    (((Leaf-Count $treeH) -ge 3) -and ((Windows-Of $treeH).Count -ge 2))
foreach ($lf in (All-Leaves $treeH)) {
    Run-CliArgs @('+send-keys', "--target=$($lf.id)", 'for /l %i in (1,1,2000000) do @echo t229-noise %i', 'Enter') `
        "$tmp\h-busy-$($lf.id).txt" 15 | Out-Null
}
Start-Sleep -Seconds 5
$agentH = Wait-AgentPid $tmp 25
Assert "H3 an agent is running for this run" ($agentH -ne 0)
# Let the debounced session-layout manifest settle, then kill ONLY the app: the
# agent keeps every session, which is what makes the relaunch a RESTORE.
Start-Sleep -Seconds 4
Stop-Process -Id $appPidH1 -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Assert "H4 killing the app left the agent (and its sessions) alive" ((Agent-Pid $tmp) -eq $agentH)

$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidH2 = Start-App $tmp 't229-restore'
$logH = $script:AppLog
Assert "H5 the restoring GUI came up" ($appPidH2 -ne 0)
Assert "H6 the restored layout came back" ((Leaf-Count (Wait-Panes $tmp 'h3' 3 60)) -ge 3)
Assert "H7 the restoring app found the stale agent and said so" `
    (Wait-LogMatch $logH 'agent upgrade check: stale with live sessions, but protocol-compatible' 40)
Assert "H8 ... reporting the generation that cannot replace itself" `
    (Wait-LogMatch $logH 'agent upgrade check: stale with live sessions.*handoff-capable=false' 40)
# THE assert this arm exists for, in the shape the user reported it. Same wait
# the dialog needed when this arm still raised one.
$dlgH = Wait-Dialog $appPidH2 25
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the restored busy layout WAS offered up for a restart - this run MUST fail'
    Assert "H9 a confirmation was raised over the restored busy sessions (inverted)" ($dlgH -ne [IntPtr]::Zero)
} else {
    Assert "H9 NO confirmation was raised over the restored busy sessions" ($dlgH -eq [IntPtr]::Zero)
}
Assert "H10 the agent that owns all three sessions was never restarted" ((Agent-Pid $tmp) -eq $agentH)
Assert "H11 the app attempted no destructive restart of its own" `
    ((Read-AppLog $logH) -notmatch 'agent restart: begin')
Assert "H12 the app is still running" `
    (@(Get-Process -Id $appPidH2 -ErrorAction SilentlyContinue).Count -eq 1)
# The user-visible half: the busy sessions are still THERE, on the agent nobody
# touched. Retried per pane because these are streaming and a single write can
# land in a repaint - what has to survive is the pane, not one keystroke.
$aliveH = 0
foreach ($lf in (All-Leaves (Get-List $tmp 'h4' 15))) {
    for ($i = 1; $i -le 3; $i++) {
        if (Test-PaneResponsive $tmp $lf.id "h$($lf.id)-$i" 20) { $aliveH++; break }
    }
}
Assert "H13 all three busy sessions survived (they were never at risk)" ($aliveH -ge 3)
Stop-TestProcs

# ============================================================================
Say "== I: negative control - a refresh that CANNOT re-dial says so"
# ============================================================================
# The failure mode T229 is named for: consent to a destructive act, then
# nothing. `reconnectForRecovery() orelse return` was the one exit in the whole
# chain that logged nothing at all - on the path where the agent every pane was
# riding has just been terminated. Here the re-dial is made impossible (the
# agent binary is gone, so find-or-spawn cannot succeed) and the requirement is
# that the app SAYS so and STAYS UP, rather than vanishing.
#
# Driven through the SKEW, because since T1056 that is the only trigger left
# that restarts an agent on purpose - a stale build is left alone (arms C/H).
# The skew input is the agent-side proto hook, which the agent reads at startup
# and which is independent of whether its binary is still on disk afterwards.
#
# The break has to be arranged BEFORE the app starts: a process gets a SNAPSHOT
# of the environment at CreateProcess time, so changing GHOSTTY_LOCAL_AGENT_BIN
# in this harness afterwards is invisible to it (measured - the first cut of
# this arm did exactly that and the re-dial happily succeeded). So point the app
# at a COPY, then move the copy out from under it once the dialog is up. A
# running .exe cannot be deleted on Windows, but it CAN be renamed.
# Keep the copy's FILE NAME - Win32_Process.Name is the image name recorded at
# creation, and every agent-pid helper in this script filters on
# 'ghoztty-agent*'. A copy called anything else is invisible to them.
$agentCopyDir = Join-Path $tmp 'agentcopy'
New-Item -ItemType Directory -Force $agentCopyDir | Out-Null
$agentCopy = Join-Path $agentCopyDir 'ghoztty-agent.exe'
Copy-Item $AgentExe $agentCopy -Force
$env:GHOSTTY_LOCAL_AGENT_BIN = $agentCopy
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $null
$env:GHOZTTY_AGENT_PROTO_VERSION = '0'
$appPidI = Start-App $tmp 't229-nodial'
$logI = $script:AppLog
Assert "I1 the GUI came up" ($appPidI -ne 0)
$agentI = Wait-AgentPid $tmp 25
Assert "I2 an agent is running for this run" ($agentI -ne 0)
$dlgI = Wait-Dialog $appPidI 60
Assert "I3 the skew confirmation appeared" ($dlgI -ne [IntPtr]::Zero)
# Break the spawn between the ask and the answer. Rename, not delete: the copy
# is the running agent's own image.
Rename-Item $agentCopy (Join-Path $agentCopyDir 'ghoztty-agent.bak') -Force -ErrorAction SilentlyContinue
Assert "I3b the agent binary really is gone from the path the app holds" `
    (-not (Test-Path $agentCopy))
if ($dlgI -ne [IntPtr]::Zero) { Confirm-Update $dlgI }
# Not Wait-NoDialog: the FAILURE dialog (I7) is itself a GhozttyConfirmDialog,
# so "no dialog" is never true here and would score a working fix as broken.
Assert "I4 the confirmation was answered with 'Update Now'" `
    (Wait-LogMatch $logI 'user confirmed destructive agent restart to clear a protocol skew' 25)
Assert "I5 the app is STILL RUNNING after a failed refresh" `
    (@(Get-Process -Id $appPidI -ErrorAction SilentlyContinue).Count -eq 1)
Assert "I6 the failed re-dial is logged as an ABORT, not silence" `
    (Wait-LogMatch $logI 'in-place recovery ABORTED: no local agent could be re-dialed' 40)
Assert "I7 the user is TOLD, in the same modal channel that asked for consent" `
    ((Wait-LogMatch $logI 'agent refresh failed; telling the user' 30) -and `
     ((Wait-TestWindow -ProcessId $appPidI -Class 'GhozttyConfirmDialog' -TimeoutMs 20000) -ne [IntPtr]::Zero))
$env:GHOZTTY_AGENT_PROTO_VERSION = $null
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
Stop-TestProcs

# ============================================================================
Say "== J: T125 - a PROTOCOL SKEW takes the mandatory-update path"
# ============================================================================
# Arms B-I all measure the T147 question: "is the running agent an older
# BUILD?", which needs a working connection to ask. This arm is the case T147
# deliberately did not cover: the handshake itself fails, so there is NO
# connection to judge, and until T125 the app just gave up - no dialog, no
# explanation, session persistence quietly off for the rest of the run.
#
# The skew INPUT is GHOZTTY_AGENT_PROTO_VERSION, a debug-only hook on the AGENT
# (mirroring GHOZTTY_AGENT_BUNDLED_VERSION on the app) - both ends compile the
# same protocol.proto_version constant, so a skew cannot otherwise be produced
# from one tree. The agent inherits this harness's environment when the app
# spawns it, so setting it here is what makes the spawned agent disagree.
# proto_version is 1, so 0 is an agent from the past.
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $null
$env:GHOZTTY_AGENT_PROTO_VERSION = '0'
$appPidJ = Start-App $tmp 't125-skew-old'
$logJ = $script:AppLog
$topJ = $script:AppTop
Assert "J1 the GUI came up" ($appPidJ -ne 0)
$agentJ = Wait-AgentPid $tmp 30
Assert "J2 the skewed agent is running" ($agentJ -ne 0)
$dlgJ = Wait-Dialog $appPidJ 60
Assert "J3 the skew raised the mandatory confirmation (it used to raise nothing)" `
    ($dlgJ -ne [IntPtr]::Zero)
if ($dlgJ -ne [IntPtr]::Zero) {
    Assert "J4 it is the SAME dialog the staleness path uses" `
        ((Get-TestWindowText -Window $dlgJ) -like '*background terminal process*')
    Assert "J5 the owner is disabled while it is up (mandatory, not advisory)" `
        (($topJ -ne [IntPtr]::Zero) -and (-not (Test-TestWindowEnabled -Window $topJ)))
}
# Same contract as C5: consent comes BEFORE the destruction.
Assert "J6 nothing was killed while the dialog was up" ((Agent-Pid $tmp) -eq $agentJ)
Assert "J7 the decision is logged with its reason, while the dialog is still up" `
    (Wait-LogMatch $logJ 'agent upgrade check: protocol skew, running agent speaks an OLDER protocol' 25)
Assert "J8 the pending modal announces itself before it blocks" `
    (Wait-LogMatch $logJ 'showing mandatory protocol-skew confirmation.*waiting for the user' 25)
# Answering it must actually cure the skew. The replacement agent inherits the
# APP's environment, not this harness's - and the app was launched with the
# override set - so clear it first, exactly as a real upgrade would leave a
# binary that speaks the current protocol.
$env:GHOZTTY_AGENT_PROTO_VERSION = $null
if ($dlgJ -ne [IntPtr]::Zero) { Say "    Update Now => $(Confirm-Update $dlgJ)" }
Assert "J9 the confirmation was answered with 'Update Now'" `
    (Wait-LogMatch $logJ 'user confirmed destructive agent restart to clear a protocol skew' 25)
$agentJ2 = Wait-AgentPid $tmp 40 $agentJ
Assert "J10 the skewed agent was REPLACED (new pid)" ($agentJ2 -ne 0 -and $agentJ2 -ne $agentJ)
Assert "J11 the app survived the restart it promised to survive" `
    (@(Get-Process -Id $appPidJ -ErrorAction SilentlyContinue).Count -eq 1)
# --- the destructive-restart machinery (T229/T421/T426) ----------------------
# These asserts used to hang off the staleness path (arms D and H), which since
# T1056 no longer restarts anything while a session is live. The machinery is
# unchanged and shared - `restartForUpgrade` + `recoverLocalAgentInPlace`, one
# restart story rather than two - so it is measured here instead, on the only
# trigger that still reaches it. Losing them with arm D would have left the
# whole T229 step trail untested at HEAD.
#
# What this arm can and cannot reach, measured rather than assumed: the KILL half
# runs in full (every line below fires), but the RE-DIAL that follows it cannot
# succeed here. The app got GHOZTTY_AGENT_PROTO_VERSION in its environment
# SNAPSHOT at CreateProcess time, so every agent it spawns afterwards - the
# replacement included - is skewed too, and clearing the variable in this harness
# afterwards is invisible to it. The run therefore ends in `in-place recovery
# ABORTED`, which is a real production shape (arm I is where the user being told
# about it is asserted) but not the successful-rebuild one. That half is measured
# by OUTCOME rather than by a log line, in `test/win32/agent-recovery.ps1` arm H
# (surfaces replaced, sessions alive, pane responsive, topology intact) and in
# `test/win32/holder-adopt.ps1`.
$treeJ = Wait-Panes $tmp 'j0' 1 60
Assert "J12 the window still has its pane after the restart" ((Leaf-Count $treeJ) -ge 1)
$leafJ = (All-Leaves $treeJ)[0]
# Deliberately not "responsive ON THE NEW AGENT": with the re-dial aborted this
# pane is not agent-backed, and claiming otherwise would be a pass that means
# something it does not.
Assert "J13 the app's pane still works after the restart" (Test-PaneResponsive $tmp $leafJ.id 'j')
# T229: a hang inside the destructive restart used to leave the log ending at
# the confirm, with no way to tell WHICH step it stopped in.
Assert "J14 the destructive restart leaves a step trail (begin)" `
    (Wait-LogMatch $logJ 'agent restart: begin' 25)
Assert "J15 ... and names the step that can wedge (retiring the connection)" `
    (Wait-LogMatch $logJ 'agent restart: retiring the shared connection' 25)
Assert "J16 ... and the step after it (terminate)" `
    (Wait-LogMatch $logJ 'agent restart: terminating agent pid' 25)
Assert "J17 the restart reports its OUTCOME, not just its intent" `
    (Wait-LogMatch $logJ 'protocol-skew agent restart finished: \d+ window\(s\) rebuilt' 40)
# T421. J11 asserts the app survived; this asserts that it would have been
# BROUGHT BACK if it had not. The guard is armed inside the confirmed path
# itself, so this is the only place the arming half is exercised end to end -
# `test/win32/relaunch-guard.ps1` drives the watching half directly. Its DISARM
# is deliberately NOT asserted here: after the aborted re-dial the app raises the
# modal failure notice, which blocks the very function whose `defer` would
# disarm, so the guard stays armed and its marker stays on disk for as long as
# that notice is up. Filed as its own defect (T1069) rather than measured as
# correct here.
Assert "J18 T421: the destructive window is SUPERVISED (guard armed)" `
    (Wait-LogMatch $logJ 'relaunch guard: ARMED \(guard pid \d+ watching app pid \d+' 30)
# The identity gate (T421): the pid out of port.json is verified to be the agent
# before it is killed, so a stale/recycled pid can never make this a self-kill.
Assert "J19 T421: the kill target was VERIFIED as the agent binary first" `
    (Wait-LogMatch $logJ "agent restart: pid \d+ verified as '.*ghoztty-agent\.exe'" 30)
Assert "J20 T421: ... and the terminate step reports that it returned" `
    (Wait-LogMatch $logJ 'agent restart: pid \d+ terminate returned' 30)
# T426. Four times the app ended cleanly INSIDE that terminate call, and the
# only mechanism consistent with all four is a shared kill-on-close job dying
# with the process being killed. The restart now measures that BEFORE the kill,
# because by the time it matters the app is gone and nobody can ask.
Assert "J21 T426: the restart records the job facts before the kill" `
    (Wait-LogMatch $logJ 'agent restart: job facts before the kill' 30)
# ... and records the ANSWER, not just the question. `?` for every field would
# satisfy the line above while measuring nothing.
Assert "J22 T426: ... including whether the agent shares OUR job" `
    (Wait-LogMatch $logJ 'SHARED_JOB=(yes|no)' 30)
# The structural half: the agent this build spawns is not in the app's job in
# the first place, so there is no shared job left to tear down. Direct
# membership probe: test\win32\agent-job-escape.ps1.
Assert "J23 T426: the agent spawn NAMES which job escape it got" `
    (Wait-LogMatch $logJ 'spawned local agent pid \d+ \(job escape=[^)]+\)' 30)
# Escaping is environment-dependent - tier 1 needs a job chain that permits
# breakaway (this box's does not: ACCESS_DENIED, measured) and tier 2 needs a
# shell window, which THIS harness's background test desktop does not have. So
# the invariant asserted here is the one that holds everywhere: a degraded
# spawn is LOUD. The outcome itself - the agent is not a member of the app's
# job, and survives its teardown - is measured directly by
# test\win32\agent-job-escape.ps1, which runs on a desktop that has a shell.
$logTextJ = Read-AppLog $logJ
$escapedJ = $logTextJ -match 'spawned local agent pid \d+ \(job escape=(breakaway|shell-parent)\)'
$loudJ = $logTextJ -match 'local agent pid \d+ is INSIDE this app''s job object'
Assert "J24 T426: it either escaped, or said out loud that it did not" `
    ($escapedJ -or $loudJ)
Stop-TestProcs

# ============================================================================
Say "== K: T125 negative control - a NEWER agent is never downgraded"
# ============================================================================
# The other direction of the same skew, and the one that must NOT act: if the
# agent speaks a protocol newer than this app, the APP is the out-of-date side.
# Killing the agent there would replace a newer binary with an older one AND end
# sessions a newer app could still have attached to. Without this arm, an
# implementation that simply restarts on any skew would pass arm J and quietly
# eat the user's sessions on every rollback.
$env:GHOZTTY_AGENT_PROTO_VERSION = '9999'
$appPidK = Start-App $tmp 't125-skew-new'
$logK = $script:AppLog
Assert "K1 the GUI came up" ($appPidK -ne 0)
$agentK = Wait-AgentPid $tmp 30
Assert "K2 the newer-protocol agent is running" ($agentK -ne 0)
Assert "K3 the app noticed the skew and named its direction" `
    (Wait-LogMatch $logK 'running agent speaks a NEWER protocol' 40)
Start-Sleep -Seconds 6
Assert "K4 NO confirmation was shown (nothing for the user to consent to)" `
    ((Find-Dialog $appPidK) -eq [IntPtr]::Zero)
Assert "K5 the newer agent was NOT touched (same pid)" ((Agent-Pid $tmp) -eq $agentK)
Assert "K6 the app is still running (degraded, not broken)" `
    (@(Get-Process -Id $appPidK -ErrorAction SilentlyContinue).Count -eq 1)
$env:GHOZTTY_AGENT_PROTO_VERSION = $null
Stop-TestProcs

# ============================================================================
Say "== L: T907/T1056 - handoff-capable, but a session it owns DIRECTLY holds it back"
# ============================================================================
# The mixed-generation box: the agent CAN replace itself, but a ConPTY it owns
# in-process cannot be carried across a process boundary at any price, so the
# update drains instead - each such session that closes brings it nearer.
#
# Until T1056 the confirmation was still offered here, on the argument that
# forcing it early was the only thing left for a user to decide. Forcing it early
# meant ending those sessions, which is the act the fix removes: waiting costs
# the user nothing (the agent is compatible) and forcing costs them their work.
# So this arm now measures the same absence arms C and H do, and is told apart
# from them only by its reason clause.
#
# Built by keeping the capability and taking the HOLDERS away: with
# GHOZTTY_AGENT_PTY_HOLDER=0 every session this agent spawns is one it owns
# directly, which is exactly the state a box in the middle of the T909 rollout
# is in.
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = $null
$env:GHOZTTY_AGENT_PTY_HOLDER = '0'
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidL = Start-App $tmp 't907-draining'
$logL = $script:AppLog
Assert "L1 the GUI came up" ($appPidL -ne 0)
$agentL = Wait-AgentPid $tmp 25
Assert "L2 an agent is running for this run" ($agentL -ne 0)
$dlgL = Wait-Dialog $appPidL 40
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the draining agent DID raise a confirmation - this run MUST fail'
    Assert "L3 a confirmation was raised while the update drains (inverted)" ($dlgL -ne [IntPtr]::Zero)
} else {
    Assert "L3 NO confirmation appears while the update drains" ($dlgL -eq [IntPtr]::Zero)
}
Assert "L4 the app attempted no destructive restart of its own" `
    ((Read-AppLog $logL) -notmatch 'agent restart: begin')
# The decision, not just the absence: this arm, arm C and arm M all end in "no
# dialog", and only the log says which policy arm produced it.
Assert "L5 the decision names the DRAINING reason, not the legacy one" `
    (Wait-LogMatch $logL 'agent upgrade check: stale and self-replacing, but sessions the agent owns directly must close first' 25)
# At least one legacy session, and the capability still advertised - the two
# facts that separate this arm from arm C's. The count itself is deliberately
# not pinned: by this point in the run the app restores whatever the earlier
# arms left in the manifest, so "how many" is history, not policy.
Assert "L6 ... and reports the agent as handoff-capable with a legacy session" `
    (Wait-LogMatch $logL 'agent upgrade check: stale and self-replacing.*, [1-9]\d* of them legacy, handoff-capable=true' 25)
Assert "L7 the agent was not restarted (same pid)" ((Agent-Pid $tmp) -eq $agentL)
$treeL = Wait-Panes $tmp 'l0' 1
$leafL = (All-Leaves $treeL)[0]
Assert "L8 the legacy session is still responsive" (Test-PaneResponsive $tmp $leafL.id 'l')
Stop-TestProcs

# ============================================================================
Say "== M: T907 - handoff-capable + every session holder-backed => the app stands down"
# ============================================================================
# THE contract T1037 exists to write down. The running agent is stale, a session
# is live, and the app asks nobody and restarts nothing: the agent replaces
# itself, hands the per-session holders to its successor and exits, and the live
# session never notices. A dialog here would be the defect - it would be asking
# the user to consent to losing sessions that are not going to be lost.
#
# Two seams are needed to make the agent actually do it, and both are about the
# same limitation: one tree bakes one stamp into one binary, so there is no way
# to put a genuinely newer agent on disk here.
#
#   * GHOZTTY_AGENT_HANDOFF_FORCE (debug-only) skips the "is the file on disk
#     newer?" comparison. It is consumed by the agent that reads it (removed
#     from its own environment block), so the successor does not hand off again
#     forever.
#   * The running agent has to be started from `ghoztty-agent.exe.bak`, because
#     force does NOT skip the structural refusal: the candidate is our own image
#     path with the delivery's backup suffix stripped, and an agent running from
#     the canonical name resolves to ITSELF and is refused outright. That is the
#     shape a real delivery leaves behind - a running exe cannot be overwritten
#     on Windows, so the upgrade renames it and copies the new build into the
#     original path - which is why the copy beside it is what gets spawned.
$handoffDir = Join-Path $tmp 'handoff'
New-Item -ItemType Directory -Force $handoffDir | Out-Null
$runningAgentM = Join-Path $handoffDir 'ghoztty-agent.exe.bak'
Copy-Item $AgentExe $runningAgentM -Force
Copy-Item $AgentExe (Join-Path $handoffDir 'ghoztty-agent.exe') -Force
$env:GHOSTTY_LOCAL_AGENT_BIN = $runningAgentM
$env:GHOZTTY_AGENT_PTY_HOLDER = '1'
$env:GHOZTTY_AGENT_HANDOFF_FORCE = '1'
$env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = '2000'
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidM = Start-App $tmp 't907-standdown'
$logM = $script:AppLog
Assert "M1 the GUI came up" ($appPidM -ne 0)
$agentM = Wait-AgentPid $tmp 25
Assert "M2 an agent is running for this run" ($agentM -ne 0)
$treeM = Wait-Panes $tmp 'm0' 1
Assert "M3 it has a live session to lose" ((Leaf-Count $treeM) -ge 1)
$leafM = (All-Leaves $treeM)[0]
Assert "M4 the app STOOD DOWN and said so" `
    (Wait-LogMatch $logM 'agent upgrade check: stale, but the agent is replacing itself without losing any session' 30)
Assert "M5 ... reporting the agent as handoff-capable with nothing legacy" `
    (Wait-LogMatch $logM 'agent upgrade check: stale, but the agent.*, 0 of them legacy, handoff-capable=true' 30)
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting a confirmation appeared for a fully holder-backed agent - this run MUST fail'
    Assert "M6 a confirmation was raised for a handoff-capable agent (inverted)" `
        ((Wait-Dialog $appPidM 20) -ne [IntPtr]::Zero)
} else {
    # "No dialog appeared" is only evidence when the same wait, against the same
    # build, on the same desktop, is known to find one. Arm L used to be that
    # positive control; since T1056 it is a no-dialog arm too, so the control is
    # arms J and I - the skew confirmation, found by this same Wait-Dialog
    # earlier in this run.
    Assert "M6 NO confirmation was raised (nothing for the user to consent to)" `
        ((Wait-Dialog $appPidM 20) -eq [IntPtr]::Zero)
}
# Standing down means standing down: not a quieter restart, no restart at all.
# `agent restart: begin` is the first line of the destructive path (H11), so its
# absence is the checkable form of "the app touched nothing".
Assert "M7 the app attempted no destructive restart of its own" `
    ((Read-AppLog $logM) -notmatch 'agent restart: begin')
# ... and the stand-down was a stand-down from something REAL: the agent did
# replace itself. Without this, an agent whose supervisor never ran would pass
# every assert above.
$agentM2 = Wait-AgentPid $tmp 60 $agentM
Assert "M8 the agent replaced ITSELF (new pid, nobody asked)" `
    ($agentM2 -ne 0 -and $agentM2 -ne $agentM)
Assert "M9 the old agent is gone" `
    (@(Get-Process -Id $agentM -ErrorAction SilentlyContinue).Count -eq 0)
# THE user-visible half: the session was carried across the replacement. Retried
# because the app's link to the agent drops mid-handoff and the keystrokes of a
# single attempt can land in that gap - the pane is what has to survive, not one
# particular write to it.
$liveM = $false
for ($i = 1; $i -le 4; $i++) {
    if (Test-PaneResponsive $tmp $leafM.id "m$i" 20) { $liveM = $true; break }
}
Assert "M10 the live session came across to the successor" $liveM
Assert "M11 the app survived the replacement it stood down for" `
    (@(Get-Process -Id $appPidM -ErrorAction SilentlyContinue).Count -eq 1)
$env:GHOZTTY_AGENT_HANDOFF_FORCE = $null
$env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $null
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
Stop-TestProcs

} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
    $env:GHOZTTY_AGENT_BUNDLED_VERSION = $savedOverride
    $env:GHOZTTY_AGENT_PROTO_VERSION = $savedProto
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $savedSuppress
    $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolder
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = $savedForce
    $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $savedInterval
    # The per-run root holds every arm's APP LOG, and a failing Wait-LogMatch
    # assert is answerable only from it - so a failure that needs the log costs a
    # whole second run today, with the evidence deleted again at the end of it.
    # Set GHOZTTY_TEST_KEEP_ROOT=1 to keep it (and print where it is); unset,
    # which is every CI and sweep run, this is byte-identical to before.
    if ($env:GHOZTTY_TEST_KEEP_ROOT -eq '1') {
        Say "KEEPING test root for inspection: $root"
    } else {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$fgSeen = @(Stop-TestForegroundWatch)
Say "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert "G1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "G2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

# --- stamp (T783/T1037) ------------------------------------------------------
# This harness went 12 days red at HEAD because nothing tied an edit of the
# upgrade DECISION to a run of the only thing that measures it end to end.
# A clean green run stamps the code it covers; a red one leaves the stamp alone,
# so red stays due.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-upgrade -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Say ""
if ($script:failures -eq 0) { Say "AGENT-UPGRADE: ALL PASS ($script:passes)"; exit 0 }
else { Say "AGENT-UPGRADE: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
