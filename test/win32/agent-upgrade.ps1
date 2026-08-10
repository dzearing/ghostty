# T147 acceptance: NON-DESTRUCTIVE local-agent upgrade delivery.
#
# The defect: the upgrade script deliberately swaps ghoztty-agent.exe WITHOUT
# killing the running agent (T89h) - killing it is the silent session reset
# CLAUDE.md's "Agent contract & upgrade compatibility" section forbids. But
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
#   C: stale + a live session => the MANDATORY confirmation, and NOTHING is
#      killed before the user answers. Declining ("Later") leaves the agent pid
#      and the live pane exactly as they were - the contract assert.
#   D: stale + accept => the agent is actually replaced (new pid) and the panes
#      come back IN PLACE (same app pid, same window/pane count, pane responsive
#      again on the RELAUNCHed shell).
#   E: the deferral promise - after declining, closing the last pane makes the
#      agent idle, and the refresh then happens SILENTLY (new agent pid, no
#      second dialog). "Ghoztty updates automatically the next time no sessions
#      are open" is a promise the code has to keep.
#   F: negative control - session-persistence=off never runs the check at all.
#   J: T125 - a PROTOCOL SKEW (the handshake itself fails, so there is no
#      connection to judge) takes the same mandatory-update path, and answering
#      it actually replaces the agent.
#   K: T125 negative control - a skew where the AGENT is the newer side is never
#      acted on. The app is the out-of-date one; downgrading it would eat
#      sessions a newer app could still have attached to.
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
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
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
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$tmp*" })
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

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $null
# Isolate the IPC endpoint unconditionally: every `+list` / `+read` /
# `+send-keys` below is an oracle, and an instance answering the shared pipe
# would answer them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-agentupg'

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
Say "== C: stale + a live session => mandatory confirmation, nothing killed yet"
# ============================================================================
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidC = Start-App $tmp 't147-stale-decline'
$logC = $script:AppLog
$topC = $script:AppTop
Assert "C1 the GUI came up" ($appPidC -ne 0)
$agentC = Wait-AgentPid $tmp 25
Assert "C2 an agent is running for this run" ($agentC -ne 0)

$dlgC = Wait-Dialog $appPidC 40
Assert "C3 the mandatory confirmation appeared" ($dlgC -ne [IntPtr]::Zero)
if ($dlgC -ne [IntPtr]::Zero) {
    $title = Get-TestWindowText -Window $dlgC
    Say "    dialog title: '$title'"
    Assert "C4 it names the background process restart" ($title -like '*background terminal process*')
    # "Mandatory" is a modality claim, and IsWindowEnabled on the owner is the
    # only cross-process-safe way to check it: ConfirmDialog.show disables its
    # owner for exactly as long as it is up. Nothing asserted this before the
    # T217 migration - the old script could only see that a window existed.
    Assert "C4b the owner window is DISABLED while the confirmation is up" `
        (($topC -ne [IntPtr]::Zero) -and (-not (Test-TestWindowEnabled -Window $topC)))
}
# THE contract assert: consent comes BEFORE the destruction, not after.
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the agent was killed BEFORE the user answered - this run MUST fail'
    Assert "C5 the agent was destroyed while the dialog was still up (inverted)" ((Agent-Pid $tmp) -ne $agentC)
} else {
    Assert "C5 the agent is still alive and unchanged while the dialog is up" ((Agent-Pid $tmp) -eq $agentC)
}

# THE T201 assert, and it must run HERE -- before the dialog is answered.
# `ConfirmDialog.show` pumps its own loop and does not return until the user
# acts, which can be never; every message the old code emitted was contingent on
# that answer. So a live, correctly-working confirmation left the log ending at
# "bundled agent build is ..." and nothing more, indistinguishable from a check
# that decided nothing or never ran. (Field case, 2026-07-30: a dialog sat on a
# second monitor for ~20 minutes and the log gave no evidence it existed.)
Assert "C9 the decision is logged while the dialog is STILL UP" `
    (Wait-LogMatch $logC 'agent upgrade check: stale with live sessions, confirmation required' 20)
Assert "C10 the pending modal announces itself before it blocks" `
    (Wait-LogMatch $logC 'showing mandatory restart confirmation.*waiting for the user' 20)
Assert "C11 the dialog is still up after those asserts (they did not race it)" `
    ((Find-Dialog $appPidC) -ne [IntPtr]::Zero)

if ($dlgC -ne [IntPtr]::Zero) {
    # ConfirmDialog reads WM_KEYDOWN off its own nested pump, so a posted
    # Escape reaches it without any foreground grab.
    $r = Send-TestControlKey -Control $dlgC -Key Escape
    Say "    Escape => $r"
}
Assert "C6 the dialog closed on 'Later'" (Wait-NoDialog $appPidC 15)
Assert "C6b the owner window is enabled again once the modal is gone" `
    (($topC -ne [IntPtr]::Zero) -and (Test-TestWindowEnabled -Window $topC))
Start-Sleep -Seconds 3
Assert "C7 declining left the agent running (same pid)" ((Agent-Pid $tmp) -eq $agentC)
$treeC = Wait-Panes $tmp 'c0' 1
$leafC = (All-Leaves $treeC)[0]
Assert "C8 the live pane survived the decline" (Test-PaneResponsive $tmp $leafC.id 'c')
Stop-TestProcs

# ============================================================================
Say "== D: stale + 'Update Now' => the agent is replaced and panes come back"
# ============================================================================
$appPidD = Start-App $tmp 't147-stale-accept'
Assert "D1 the GUI came up" ($appPidD -ne 0)
$agentD = Wait-AgentPid $tmp 25
Assert "D2 an agent is running for this run" ($agentD -ne 0)
$dlgD = Wait-Dialog $appPidD 40
Assert "D3 the confirmation appeared" ($dlgD -ne [IntPtr]::Zero)
if ($dlgD -ne [IntPtr]::Zero) { Say "    Update Now => $(Confirm-Update $dlgD)" }
Assert "D4 the dialog closed on 'Update Now'" (Wait-NoDialog $appPidD 15)
$agentD2 = Wait-AgentPid $tmp 30 $agentD
Assert "D5 the agent was REPLACED (new pid)" ($agentD2 -ne 0 -and $agentD2 -ne $agentD)
Assert "D6 the old agent is gone" (@(Get-Process -Id $agentD -ErrorAction SilentlyContinue).Count -eq 0)
# In place: the app never relaunched.
Assert "D7 the app is the SAME process (in-place, not a relaunch)" (@(Get-Process -Id $appPidD -ErrorAction SilentlyContinue).Count -eq 1)
$treeD = Wait-Panes $tmp 'd0' 1 40
Assert "D8 the window still has its pane" ((Leaf-Count $treeD) -ge 1)
$leafD = (All-Leaves $treeD)[0]
Assert "D9 the rebuilt pane is responsive on the new agent" (Test-PaneResponsive $tmp $leafD.id 'd')
Stop-TestProcs

# ============================================================================
Say "== E: the deferral promise - idle after a decline refreshes SILENTLY"
# ============================================================================
$appPidE = Start-App $tmp 't147-idle'
$logE = $script:AppLog
Assert "E1 the GUI came up" ($appPidE -ne 0)
$agentE = Wait-AgentPid $tmp 25
Assert "E2 an agent is running for this run" ($agentE -ne 0)
$dlgE = Wait-Dialog $appPidE 40
Assert "E3 the confirmation appeared (a session is live)" ($dlgE -ne [IntPtr]::Zero)
if ($dlgE -ne [IntPtr]::Zero) { Send-TestControlKey -Control $dlgE -Key Escape | Out-Null }
Assert "E4 the dialog closed on 'Later'" (Wait-NoDialog $appPidE 15)
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
Assert "E6 the idle agent was refreshed without asking again (new pid)" ($agentE2 -ne 0 -and $agentE2 -ne $agentE)
Assert "E7 no second dialog was shown" ((Find-Dialog $appPidE) -eq [IntPtr]::Zero)
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
Say "== H: T229 - the user's shape: RESTORED windows, several BUSY sessions"
# ============================================================================
# Arm D above passes with ONE freshly-created window holding ONE idle pane, and
# it passed right through the field failure. What the user actually hits is
# different in three ways, all of which this arm reproduces:
#
#   * the app RESTORED its windows from the manifest, so every pane is an
#     ATTACH to a session the agent already owned rather than a fresh spawn;
#   * there is more than one window and more than one session; and
#   * the sessions are STREAMING. An idle cmd.exe leaves the agent
#     connection's reader/writer threads parked, which is the one state in
#     which the blocking `Connection.shutdown` join on the GUI thread cannot
#     wedge - i.e. the state arm D measures.
#
# The oracle is the same as D's (the app survives, the panes come back), plus
# the T229 step trail: a hang inside the destructive restart used to leave the
# log ending at the confirm, with no way to tell WHICH step it stopped in.
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
$dlgH = Wait-Dialog $appPidH2 40
Assert "H6 launch-restore found the stale agent and asked" ($dlgH -ne [IntPtr]::Zero)
if ($dlgH -ne [IntPtr]::Zero) { Confirm-Update $dlgH }
Assert "H7 the dialog closed on 'Update Now'" (Wait-NoDialog $appPidH2 15)
$agentH2 = Wait-AgentPid $tmp 40 $agentH
Assert "H8 the agent was REPLACED (new pid)" ($agentH2 -ne 0 -and $agentH2 -ne $agentH)
# THE assert this arm exists for. The field report is "the dialog disappears
# and Ghoztty never comes back"; a survivor that logged nothing is what made it
# undiagnosable.
Assert "H9 the app SURVIVED the refresh it promised to survive" `
    (@(Get-Process -Id $appPidH2 -ErrorAction SilentlyContinue).Count -eq 1)
$treeH2 = Wait-Panes $tmp 'h3' 3 60
Assert "H10 all three panes came back" ((Leaf-Count $treeH2) -ge 3)
Assert "H11 the destructive restart leaves a step trail (begin)" `
    (Wait-LogMatch $logH 'agent restart: begin' 20)
Assert "H12 ... and names the step that can wedge (retiring the connection)" `
    (Wait-LogMatch $logH 'agent restart: retiring the shared connection' 20)
Assert "H13 ... and the step after it (terminate)" `
    (Wait-LogMatch $logH 'agent restart: terminating agent pid' 20)
Assert "H14 the refresh reports its OUTCOME, not just its intent" `
    (Wait-LogMatch $logH 'destructive agent refresh finished: \d+ window\(s\) rebuilt' 30)
Assert "H15 the in-place rebuild logged how many windows it rebuilt" `
    (Wait-LogMatch $logH 'in-place recovery: rebuilt \d+ window\(s\)' 30)
# T421. H9 asserts the app survived; these assert that it would have been
# BROUGHT BACK if it had not. The guard is armed inside the confirmed path
# itself, so this is the only place the arming half is exercised end to end -
# `test\win32\relaunch-guard.ps1` drives the watching half directly.
Assert "H16 T421: the destructive window is SUPERVISED (guard armed)" `
    (Wait-LogMatch $logH 'relaunch guard: ARMED \(guard pid \d+ watching app pid \d+' 30)
Assert "H17 T421: ... and disarmed once the rebuild finished" `
    (Wait-LogMatch $logH 'relaunch guard: disarmed' 30)
# The marker is what a guard keys on; a leaked one would make the NEXT app exit
# look like a death inside a refresh.
$markerH = Join-Path $tmp 'ghoztty\agent-refresh-debug.marker'
Assert "H18 T421: the guard marker is gone afterwards" (-not (Test-Path $markerH))
# The identity gate (T421): the pid out of port.json is verified to be the agent
# before it is killed, so a stale/recycled pid can never make this a self-kill.
Assert "H19 T421: the kill target was VERIFIED as the agent binary first" `
    (Wait-LogMatch $logH "agent restart: pid \d+ verified as '.*ghoztty-agent\.exe'" 30)
Assert "H20 T421: ... and the terminate step reports that it returned" `
    (Wait-LogMatch $logH 'agent restart: pid \d+ terminate returned' 30)
# T426. Four times the app ended cleanly INSIDE that terminate call, and the
# only mechanism consistent with all four is a shared kill-on-close job dying
# with the process being killed. The refresh now measures that BEFORE the kill,
# because by the time it matters the app is gone and nobody can ask.
Assert "H21 T426: the refresh records the job facts before the kill" `
    (Wait-LogMatch $logH 'agent restart: job facts before the kill' 30)
# ... and records the ANSWER, not just the question. `?` for every field would
# satisfy the line above while measuring nothing.
Assert "H22 T426: ... including whether the agent shares OUR job" `
    (Wait-LogMatch $logH 'SHARED_JOB=(yes|no)' 30)
# The structural half: the agent this build spawns is not in the app's job in
# the first place, so there is no shared job left to tear down. Direct
# membership probe: test\win32\agent-job-escape.ps1.
Assert "H23 T426: the agent spawn NAMES which job escape it got" `
    (Wait-LogMatch $logH 'spawned local agent pid \d+ \(job escape=[^)]+\)' 30)
# Escaping is environment-dependent - tier 1 needs a job chain that permits
# breakaway (this box's does not: ACCESS_DENIED, measured) and tier 2 needs a
# shell window, which THIS harness's background test desktop does not have. So
# the invariant asserted here is the one that holds everywhere: a degraded
# spawn is LOUD. The outcome itself - the agent is not a member of the app's
# job, and survives its teardown - is measured directly by
# test\win32\agent-job-escape.ps1, which runs on a desktop that has a shell.
$logTextH = Read-AppLog $logH
$escapedH = $logTextH -match 'spawned local agent pid \d+ \(job escape=(breakaway|shell-parent)\)'
$loudH = $logTextH -match 'local agent pid \d+ is INSIDE this app''s job object'
Assert "H24 T426: it either escaped, or said out loud that it did not" `
    ($escapedH -or $loudH)
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
# The staleness input still comes from the debug stamp hook, which returns
# before it ever touches the binary - so a missing binary breaks the SPAWN
# without also disabling the check.
#
# The break has to be arranged BEFORE the app starts: a process gets a SNAPSHOT
# of the environment at CreateProcess time, so changing GHOSTTY_LOCAL_AGENT_BIN
# in this harness afterwards is invisible to it (measured - the first cut of
# this arm did exactly that and the re-dial happily succeeded). So point the app
# at a COPY, then move the copy out from under it once the dialog is up. A
# running .exe cannot be deleted on Windows, but it CAN be renamed.
# Keep the copy's FILE NAME - Win32_Process.Name is the image name recorded at
# creation, and every agent-pid helper in this script filters on
# 'ghoztty-agent.exe'. A copy called anything else is invisible to them.
$agentCopyDir = Join-Path $tmp 'agentcopy'
New-Item -ItemType Directory -Force $agentCopyDir | Out-Null
$agentCopy = Join-Path $agentCopyDir 'ghoztty-agent.exe'
Copy-Item $AgentExe $agentCopy -Force
$env:GHOSTTY_LOCAL_AGENT_BIN = $agentCopy
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidI = Start-App $tmp 't229-nodial'
$logI = $script:AppLog
Assert "I1 the GUI came up" ($appPidI -ne 0)
$agentI = Wait-AgentPid $tmp 25
Assert "I2 an agent is running for this run" ($agentI -ne 0)
$dlgI = Wait-Dialog $appPidI 40
Assert "I3 the confirmation appeared" ($dlgI -ne [IntPtr]::Zero)
# Break the spawn between the ask and the answer. Rename, not delete: the copy
# is the running agent's own image.
Rename-Item $agentCopy (Join-Path $agentCopyDir 'ghoztty-agent.bak') -Force -ErrorAction SilentlyContinue
Assert "I3b the agent binary really is gone from the path the app holds" `
    (-not (Test-Path $agentCopy))
if ($dlgI -ne [IntPtr]::Zero) { Confirm-Update $dlgI }
# Not Wait-NoDialog: the FAILURE dialog (I7) is itself a GhozttyConfirmDialog,
# so "no dialog" is never true here and would score a working fix as broken.
Assert "I4 the confirmation was answered with 'Update Now'" `
    (Wait-LogMatch $logI 'user confirmed destructive agent refresh' 25)
Assert "I5 the app is STILL RUNNING after a failed refresh" `
    (@(Get-Process -Id $appPidI -ErrorAction SilentlyContinue).Count -eq 1)
Assert "I6 the failed re-dial is logged as an ABORT, not silence" `
    (Wait-LogMatch $logI 'in-place recovery ABORTED: no local agent could be re-dialed' 40)
Assert "I7 the user is TOLD, in the same modal channel that asked for consent" `
    ((Wait-LogMatch $logI 'agent refresh failed; telling the user' 30) -and `
     ((Wait-TestWindow -ProcessId $appPidI -Class 'GhozttyConfirmDialog' -TimeoutMs 20000) -ne [IntPtr]::Zero))
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

} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
    $env:GHOZTTY_AGENT_BUNDLED_VERSION = $savedOverride
    $env:GHOZTTY_AGENT_PROTO_VERSION = $savedProto
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
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

Say ""
if ($script:failures -eq 0) { Say "AGENT-UPGRADE: ALL PASS ($script:passes)"; exit 0 }
else { Say "AGENT-UPGRADE: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
