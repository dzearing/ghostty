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
# Hermetic: per-run $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN, and it only
# ever kills ghoztty / ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\agent-upgrade.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-agent-upgrade-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class UpgDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // The visible ConfirmDialog of ANY of the given pids (0 = any process).
    public static IntPtr FindDialog(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if ((pid == 0 || p == pid) && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyConfirmDialog") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string TitleOf(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, 512);
        return sb.ToString();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab (kb-actions.ps1 recipe): attach to the
    // current foreground owner's thread + an Alt tap, retried. The
    // already-foreground guard is load-bearing - re-grabbing a window that is
    // already foreground can drop it.
    static bool GrabForeground(IntPtr top) {
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            Key(0x12, false); Key(0x12, true);
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    // Press a sequence of VKs into `dlg` after taking the foreground.
    public static string PressInto(IntPtr dlg, ushort[] vks) {
        if (!GrabForeground(dlg)) return "ABORT: could not foreground";
        foreach (var vk in vks) {
            Key(vk, false); Thread.Sleep(40); Key(vk, true);
            Thread.Sleep(120);
        }
        return "SENT";
    }
}
'@

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

function Wait-Dialog($appPid, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = [UpgDrv]::FindDialog([uint32]$appPid)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 400
    }
    return [IntPtr]::Zero
}
function Wait-NoDialog($appPid, $timeoutSec = 12) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ([UpgDrv]::FindDialog([uint32]$appPid) -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Launch the GUI and wait until it answers +list with at least one pane.
function Start-App($tmp, $title, $extraArgs = @()) {
    $argv = @("--title=$title") + $extraArgs
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList $argv | Out-Null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $proc = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
            Where-Object { $_.CommandLine -like "*$title*" })
        if ($proc.Count -gt 0) { return [int]$proc[0].ProcessId }
        Start-Sleep -Milliseconds 400
    }
    return 0
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

$VK_ESCAPE = [uint16]0x1B
$VK_TAB = [uint16]0x09
$VK_RETURN = [uint16]0x0D

# A stamp that is unambiguously NEWER than any real build, so the policy's
# never-downgrade rule can't quietly turn the test into a no-op.
$FAKE_NEW = '29991231-t147fake'

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedOverride = $env:GHOZTTY_AGENT_BUNDLED_VERSION

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $null

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
"== A: premise - the agent reports a parseable build stamp"
# ============================================================================
$verOut = Join-Path $tmp 'version.txt'
$vp = Start-Process -FilePath $AgentExe -ArgumentList @('--version') -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $verOut -RedirectStandardError "$verOut.err"
$null = $vp.Handle
$vp.WaitForExit()
$verText = (Out-Text $verOut).Trim()
"    --version => '$verText'"
Assert "A1 --version exits 0" ($vp.ExitCode -eq 0)
Assert "A2 --version prints 'ghoztty-agent <stamp>'" ($verText -match '^ghoztty-agent\s+\S+$')
$stamp = ($verText -split '\s+')[-1]
Assert "A3 the stamp is non-empty" ($stamp.Length -gt 0)
# The date prefix is what the never-downgrade rule orders on; a build with no
# date ('dev') still works, but say so out loud rather than silently.
if ($stamp -notmatch '^\d{8}-') { "    NOTE: stamp '$stamp' has no YYYYMMDD prefix (dev build)" }

# ============================================================================
"== B: negative control - a CURRENT agent is never touched"
# ============================================================================
$appPidB = Start-App $tmp 't147-current'
Assert "B1 the GUI came up" ($appPidB -ne 0)
$treeB = Wait-Panes $tmp 'b0' 1
Assert "B2 it has a pane" ((Leaf-Count $treeB) -ge 1)
$agentB = Wait-AgentPid $tmp 25
Assert "B3 an agent is running for this run" ($agentB -ne 0)
# The launch check has already run by the time +list answers; give it room
# anyway, then assert nothing happened.
Start-Sleep -Seconds 6
Assert "B4 no confirmation dialog for a current agent" ([UpgDrv]::FindDialog([uint32]$appPidB) -eq [IntPtr]::Zero)
Assert "B5 the agent was NOT restarted (same pid)" ((Agent-Pid $tmp) -eq $agentB)
$leafB = (All-Leaves (Get-List $tmp 'b1' 10))[0]
Assert "B6 the pane still works" (Test-PaneResponsive $tmp $leafB.id 'b')
Stop-TestProcs

# ============================================================================
"== C: stale + a live session => mandatory confirmation, nothing killed yet"
# ============================================================================
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $FAKE_NEW
$appPidC = Start-App $tmp 't147-stale-decline'
Assert "C1 the GUI came up" ($appPidC -ne 0)
$agentC = Wait-AgentPid $tmp 25
Assert "C2 an agent is running for this run" ($agentC -ne 0)

$dlgC = Wait-Dialog $appPidC 40
Assert "C3 the mandatory confirmation appeared" ($dlgC -ne [IntPtr]::Zero)
if ($dlgC -ne [IntPtr]::Zero) {
    $title = [UpgDrv]::TitleOf($dlgC)
    "    dialog title: '$title'"
    Assert "C4 it names the background process restart" ($title -like '*background terminal process*')
}
# THE contract assert: consent comes BEFORE the destruction, not after.
Assert "C5 the agent is still alive and unchanged while the dialog is up" ((Agent-Pid $tmp) -eq $agentC)

if ($dlgC -ne [IntPtr]::Zero) {
    $r = [UpgDrv]::PressInto($dlgC, @($VK_ESCAPE))
    "    Escape => $r"
}
Assert "C6 the dialog closed on 'Later'" (Wait-NoDialog $appPidC 15)
Start-Sleep -Seconds 3
Assert "C7 declining left the agent running (same pid)" ((Agent-Pid $tmp) -eq $agentC)
$treeC = Wait-Panes $tmp 'c0' 1
$leafC = (All-Leaves $treeC)[0]
Assert "C8 the live pane survived the decline" (Test-PaneResponsive $tmp $leafC.id 'c')
Stop-TestProcs

# ============================================================================
"== D: stale + 'Update Now' => the agent is replaced and panes come back"
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
    $r = [UpgDrv]::PressInto($dlgD, @($VK_TAB, $VK_RETURN))
    "    Tab+Enter => $r"
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
"== E: the deferral promise - idle after a decline refreshes SILENTLY"
# ============================================================================
$appPidE = Start-App $tmp 't147-idle'
Assert "E1 the GUI came up" ($appPidE -ne 0)
$agentE = Wait-AgentPid $tmp 25
Assert "E2 an agent is running for this run" ($agentE -ne 0)
$dlgE = Wait-Dialog $appPidE 40
Assert "E3 the confirmation appeared (a session is live)" ($dlgE -ne [IntPtr]::Zero)
if ($dlgE -ne [IntPtr]::Zero) { [UpgDrv]::PressInto($dlgE, @($VK_ESCAPE)) | Out-Null }
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
Assert "E7 no second dialog was shown" ([UpgDrv]::FindDialog([uint32]$appPidE) -eq [IntPtr]::Zero)
Stop-TestProcs

# ============================================================================
"== F: negative control - session-persistence=off never runs the check"
# ============================================================================
$appPidF = Start-App $tmp 't147-nopersist' @('--session-persistence=false')
Assert "F1 the GUI came up" ($appPidF -ne 0)
Wait-Panes $tmp 'f0' 1 | Out-Null
Start-Sleep -Seconds 6
Assert "F2 no dialog with persistence off" ([UpgDrv]::FindDialog([uint32]$appPidF) -eq [IntPtr]::Zero)
Assert "F3 no agent was spawned at all" ((Agent-Pid $tmp) -eq 0)
Stop-TestProcs

$env:LOCALAPPDATA = $savedLocalAppData
$env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
$env:GHOZTTY_AGENT_BUNDLED_VERSION = $savedOverride
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) { "AGENT-UPGRADE: ALL PASS ($script:passes)"; exit 0 }
else { "AGENT-UPGRADE: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
