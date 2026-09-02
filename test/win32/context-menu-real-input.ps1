# T240 acceptance: the right-click context menu under PHYSICAL mouse input.
#
# Why this script exists at all, and why it is not a section of
# context-menu.ps1:
#
#   context-menu.ps1 drives the menu with PostMessage, and it must - it runs
#   on the background test desktop (T218), where SendInput is dead. That makes
#   it wedge-immune and invisible to the user, but it also means its 19 green
#   assertions could never see the defect the user reported in T240: they post
#   the message that opens the menu, so they cannot observe whether a real
#   right-click produces one. A green suite over a broken feature.
#
#   The rule this encodes: an acceptance script that SYNTHESIZES the trigger
#   cannot validate the trigger. So this one takes the foreground and clicks
#   for real, on the interactive desktop.
#
# Cases:
#   A: plain pane (no mouse reporting) - a real press+release opens the menu
#      AND leaves it up. The physical WM_RBUTTONUP lands in the menu's modal
#      loop; a posted "down" alone can never test that.
#   B: pane with mouse reporting on - the menu still opens (the T240 fix).
#      This is the user's actual workflow: Claude Code, vim and lazygit all
#      turn reporting on, and before T240 that made the menu unreachable.
#   C: same reporting fixture with `right-click-action = paste` - NO menu, the
#      click goes to the app. Doubles as the oracle that reporting is really
#      live, so case B cannot pass on a fixture whose mode never landed.
#
# POSITIVE CONTROL, mandatory: before any mouse assertion, SendInput types a
# sentinel into the pane and the run aborts unless it arrives. Synthetic input
# fails silently and in more ways than it works - an oversized INPUT struct,
# a foreground lock (GameInputSvc), the wrong desktop - and every one of those
# looks exactly like "the feature is broken". A negative mouse result without
# this control proves nothing; during T240 it produced a confident, wrong
# "reproduction" of the bug.
#
# -NegativeControl flips case B to expect NO menu, which MUST fail on fixed
# code; it is how a run proves the assertion still discriminates.
#
# Takes the foreground while it runs (SendInput needs it). Only touches
# ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1100: this script's whole oracle is a PHYSICAL right-click, so it needs the
# input desktop's two capabilities - SendInput actually landing, and a window it
# can bring to the foreground. Neither exists on a background desktop, and on the
# interactive one an input lock can take them away (that is what the T1094 sweep
# recorded here as `SETUP FAIL ... could not take the foreground`, which reads
# like the context menu is broken). Asked BEFORE anything is launched: when the
# answer is no, this run is a declared SKIP with the capability named, never a
# red the product has to answer for.
. (Join-Path $PSScriptRoot 'lib\DesktopCapability.ps1')
Assert-TestDesktopCapability -Name real-input, foreground -Interactive
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to
# a respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
# T680: private per-PID IPC endpoint, claimed before any launch or CLI call -
# and Assert-GhozttyIsolated in Start-Gui proves every `+list`/`+read` below
# reads the instance launched here, never the pane the caller is sitting in.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ctxreal')
# T1033: a private pipe suffix moves the APP endpoint only - the agent pipe and
# the state files stay build-mode derived - so the exe about to be launched is
# checked for the -debug lineage before the first launch, not assumed.
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class CtxRealInput {
    // x64 INPUT is 40 bytes: 4 type + 4 pad + 32 union. MOUSEINPUT is already
    // 32 so it needs NO tail padding; KEYBDINPUT is 24 and needs 8. Get either
    // wrong and SendInput accepts 0 events and returns silently - the input
    // never happens and the app looks broken.
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MINPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct KINPUT { public uint type; public KEYBDINPUT ki; public long pad; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, MINPUT[] i, int cb);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, KINPUT[] i, int cb);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    delegate bool EnumProc(IntPtr h, IntPtr p);

    static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }

    public static IntPtr FindTop(int pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == (uint)pid && Cls(h) == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr FindChild(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, p) => { if (Cls(h) == cls) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }
    public static IntPtr FindPopup(int pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == (uint)pid && Cls(h) == "#32768" && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static uint TypeText(string s) {
        uint sent = 0;
        foreach (char c in s) {
            var d = new KINPUT { type = 1, ki = new KEYBDINPUT { vk = 0, scan = c, flags = 0x0004 } };
            var u = new KINPUT { type = 1, ki = new KEYBDINPUT { vk = 0, scan = c, flags = 0x0004 | 0x0002 } };
            sent += SendInput(1, new KINPUT[] { d }, Marshal.SizeOf(typeof(KINPUT)));
            sent += SendInput(1, new KINPUT[] { u }, Marshal.SizeOf(typeof(KINPUT)));
            System.Threading.Thread.Sleep(20);
        }
        return sent;
    }
    public static uint Press(int x, int y, bool shift) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        uint n = 0;
        if (shift) n += SendInput(1, new KINPUT[] { new KINPUT { type = 1, ki = new KEYBDINPUT { vk = 0x10 } } }, Marshal.SizeOf(typeof(KINPUT)));
        n += SendInput(1, new MINPUT[] { new MINPUT { type = 0, mi = new MOUSEINPUT { dwFlags = 0x0008 } } }, Marshal.SizeOf(typeof(MINPUT)));
        return n;
    }
    public static uint Release(bool shift) {
        uint n = SendInput(1, new MINPUT[] { new MINPUT { type = 0, mi = new MOUSEINPUT { dwFlags = 0x0010 } } }, Marshal.SizeOf(typeof(MINPUT)));
        if (shift) n += SendInput(1, new KINPUT[] { new KINPUT { type = 1, ki = new KEYBDINPUT { vk = 0x10, flags = 0x0002 } } }, Marshal.SizeOf(typeof(KINPUT)));
        return n;
    }
    public static bool Foreground(IntPtr h) {
        uint dummy;
        uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out dummy);
        uint me = GetCurrentThreadId();
        AttachThreadInput(me, fgTid, true);
        ShowWindow(h, 5);
        SetForegroundWindow(h);
        AttachThreadInput(me, fgTid, false);
        System.Threading.Thread.Sleep(250);
        return GetForegroundWindow() == h;
    }
}
'@

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

# The reporting fixture: a Windows TUI turns mouse reporting on with
# SetConsoleMode(ENABLE_MOUSE_INPUT), which conhost translates into an
# outward DECSET on the ConPTY (a raw ?1002h written by the child does NOT
# propagate out of ConPTY). The marker is printed AFTER the mode is set, so
# reading it means the DECSET has already gone out.
$inner = @'
$sig='[DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int n);[DllImport("kernel32.dll")]public static extern bool GetConsoleMode(IntPtr h,out uint m);[DllImport("kernel32.dll")]public static extern bool SetConsoleMode(IntPtr h,uint m);'
$k=Add-Type -MemberDefinition $sig -Name K -Namespace W -PassThru
$h=$k::GetStdHandle(-10)
$m=0
$k::GetConsoleMode($h,[ref]$m)|Out-Null
$k::SetConsoleMode($h, ($m -bor 0x10 -bor 0x80) -band (-bnot 0x40))|Out-Null
Write-Host "MOUSEMODE-ON"
Start-Sleep 120
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

$launched = @()

function Start-Gui([string]$label, [string[]]$extraArgs) {
    Kill-RepoInstances
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    # Start-Process does NOT quote the elements of -ArgumentList, so a
    # multi-word argument (--command=powershell -NoProfile ...) is re-tokenized
    # into positional arguments and the fixture silently comes up as a plain
    # shell - which then passes the "no reporting" assertions for the wrong
    # reason. Quote anything containing a space, here, once.
    $argList = @('--config-default-files=false', '--session-persistence=false') + $extraArgs |
        ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $p = Start-Process -FilePath $exe -ArgumentList $argList -PassThru
    Start-Sleep -Seconds 4
    if ($p.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = [CtxRealInput]::FindTop($p.Id, 'GhozttyWindow')
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    $pane = [CtxRealInput]::FindChild($top, 'GhozttyTerminal')
    if ($pane -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): pane not found"; exit 1 }
    if (-not [CtxRealInput]::Foreground($top)) {
        # T1100: the capability was there when this run started (asserted at the
        # top) and is not there now - a lock screen, a fullscreen app, another
        # window grabbing back. Still an answer about the BOX, so it skips with
        # the capability named rather than failing setup.
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Exit-TestSkip -Capability foreground `
            -Reason "could not take the foreground for '$label' (a fullscreen app or an input lock owns it)"
    }
    # Throws unless the instance answering on the private endpoint is the one
    # just launched - so the +read assertions below can never grade, or leak,
    # the contents of the caller's own panes (T680).
    Assert-GhozttyIsolated -Exe $exe
    $listJson = & $exe +list --json | Out-String
    $paneName = $null
    if ($listJson -match '"name"\s*:\s*"([^"]+)"') { $paneName = $Matches[1] }
    [pscustomobject]@{ Proc = $p; Pid = [int]$p.Id; Top = $top; Pane = $pane; PaneName = $paneName }
}

function Get-PaneCenter($g) {
    $r = New-Object CtxRealInput+RECT
    [void][CtxRealInput]::GetClientRect($g.Pane, [ref]$r)
    $pt = New-Object CtxRealInput+POINT
    $pt.X = [int](($r.Right - $r.Left) / 2); $pt.Y = [int](($r.Bottom - $r.Top) / 2)
    [void][CtxRealInput]::ClientToScreen($g.Pane, [ref]$pt)
    return $pt
}

function Wait-Popup([int]$gpid, [int]$ms = 2500) {
    for ($t = 0; $t -lt $ms; $t += 100) {
        $m = [CtxRealInput]::FindPopup($gpid)
        if ($m -ne [IntPtr]::Zero) { return $m }
        Start-Sleep -Milliseconds 100
    }
    return [IntPtr]::Zero
}

function Cancel-Menu($g) {
    [void][CtxRealInput]::SendMessageW($g.Pane, 0x001F, [IntPtr]::Zero, [IntPtr]::Zero) # WM_CANCELMODE
    Start-Sleep -Milliseconds 300
}

# Real keystrokes must land before any mouse result means anything.
function Assert-InputControl($g, [string]$label) {
    $sentinel = 'ZZCTXCONTROL'
    [void][CtxRealInput]::TypeText($sentinel)
    Start-Sleep -Milliseconds 900
    $tail = & $exe +read --name=$($g.PaneName) --lines=8 2>$null | Out-String
    $ok = $tail -match $sentinel
    Assert $ok "$label real SendInput keystrokes reach the pane (control)"
    if (-not $ok) {
        Write-Host 'ABORT: synthetic input is not reaching the app; every mouse assertion below would be a false negative.' -ForegroundColor Red
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

function Wait-MouseMode($g, [string]$label) {
    $on = $false
    for ($t = 0; $t -lt 30; $t++) {
        $tail = & $exe +read --name=$($g.PaneName) --lines=40 2>$null | Out-String
        if ($tail -match 'MOUSEMODE-ON') { $on = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert $on "$label fixture pane really did enable mouse reporting"
    return $on
}

# ---------------------------------------------------------------------------
# Case A: plain pane, physical press + release.
# ---------------------------------------------------------------------------
$g = Start-Gui 'plain' @('-e', 'cmd.exe')
$launched += $g.Pid
Assert-InputControl $g 'A:'
$pt = Get-PaneCenter $g
[void][CtxRealInput]::Press($pt.X, $pt.Y, $false)
$menu = Wait-Popup $g.Pid 2500
Assert ($menu -ne [IntPtr]::Zero) 'A: a real right-press opens the menu (no mouse reporting)'
[void][CtxRealInput]::Release($false)
Start-Sleep -Milliseconds 700
Assert ([CtxRealInput]::FindPopup($g.Pid) -ne [IntPtr]::Zero) `
    'A: the menu survives the physical button release'
Cancel-Menu $g
Assert (-not $g.Proc.HasExited) 'A: no crash'
Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Case B: mouse reporting on - the T240 case, and the user's whole workflow.
# ---------------------------------------------------------------------------
$g = Start-Gui 'reporting' @("--command=powershell -NoProfile -EncodedCommand $b64")
$launched += $g.Pid
[void](Wait-MouseMode $g 'B:')
$pt = Get-PaneCenter $g
[void][CtxRealInput]::Press($pt.X, $pt.Y, $false)
$menu = Wait-Popup $g.Pid 2500
if ($NegativeControl) {
    Assert ($menu -eq [IntPtr]::Zero) 'B: [NEGATIVE CONTROL] menu suppressed under mouse reporting'
} else {
    Assert ($menu -ne [IntPtr]::Zero) 'B: a real right-press opens the menu WITH mouse reporting on (T240)'
}
[void][CtxRealInput]::Release($false)
Start-Sleep -Milliseconds 500
Cancel-Menu $g

# Shift+right-click keeps working (redundant with the above now, not wrong).
[void][CtxRealInput]::Press($pt.X, $pt.Y, $true)
$menu = Wait-Popup $g.Pid 2500
Assert ($menu -ne [IntPtr]::Zero) 'B: shift+right-click opens the menu too'
[void][CtxRealInput]::Release($true)
Cancel-Menu $g
Assert (-not $g.Proc.HasExited) 'B: no crash'
Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Case C: reporting + right-click-action=paste. No menu - and the oracle that
# case B's fixture really was reporting.
# ---------------------------------------------------------------------------
$g = Start-Gui 'reporting-paste' @("--command=powershell -NoProfile -EncodedCommand $b64", '--right-click-action=paste')
$launched += $g.Pid
[void](Wait-MouseMode $g 'C:')
$pt = Get-PaneCenter $g
[void][CtxRealInput]::Press($pt.X, $pt.Y, $false)
$menu = Wait-Popup $g.Pid 1500
Assert ($menu -eq [IntPtr]::Zero) 'C: right-click-action=paste still gives the click to the reporting app'
if ($menu -ne [IntPtr]::Zero) { Cancel-Menu $g }
[void][CtxRealInput]::Release($false)
Assert (-not $g.Proc.HasExited) 'C: no crash'
Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

foreach ($id in $launched) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
Kill-RepoInstances

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
