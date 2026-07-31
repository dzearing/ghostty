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

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
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
if ($dlgD -ne [IntPtr]::Zero) {
    # Focus starts on the dismissive button (MB_DEFBUTTON2 parity), so Tab
    # moves to "Update Now" and Enter takes it.
    Send-TestControlKey -Control $dlgD -Key Tab | Out-Null
    Start-Sleep -Milliseconds 200
    $r = Send-TestControlKey -Control $dlgD -Key Enter
    Say "    Tab+Enter => $r"
}
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

} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
    $env:GHOZTTY_AGENT_BUNDLED_VERSION = $savedOverride
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
