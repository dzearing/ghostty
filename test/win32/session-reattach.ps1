# Session-layout re-attach (tracker T89f — same-PID restore). The WRITE half
# (T89f1) proves the win32 viewer-side manifest
# (%LOCALAPPDATA%\ghoztty\session-layout[-debug].json) is captured + atomically
# written as the topology changes; the RESTORE half (T89f2, section F) proves a
# relaunch rebuilds those windows and re-ATTACHes each pane to the session the
# ghoztty-agent kept alive across the app's death.
#
# A-E are the DEBOUNCED-WRITE path: each mutation arms a 250ms timer on the GUI
# thread; the assertions poll the on-disk manifest until it reflects the change.
#
#   A. Startup window -> manifest has one window / one tab / one leaf whose
#      session_id matches the single live agent session (+sessions).
#   B. +split -> that tab's flat node array grows to a split + two leaves, both
#      leaf session_ids matching the two live sessions; the split records a
#      layout + an in-range ratio.
#   C. +new-window --target=second -> manifest has two windows; the second
#      carries its IPC name.
#   D. +rename --title -> the target window's title_override is captured.
#   E. Every captured window has a real frame (w/h > 0) and a boolean maximized.
#   F. RESTORE (T89f2): with the A-E 2-window/3-pane layout live, mark the split
#      pane's scrollback, KILL ONLY the app (the detached agent keeps every
#      PTY), relaunch, and assert restore rebuilt exactly 2 windows / 3 panes,
#      re-ATTACHed the SAME 3 sessions (no new OPENs), and brought back the
#      pane's IPC name + scrollback and the window title pin.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (never
# the user's real release instance, which uses a different IPC socket + agent
# lineage).
#
#   powershell -NoProfile -File test\win32\session-reattach.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-session-reattach-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the zig-out ghoztty APP (leave ghoztty-agent alive so its PTYs
# survive — the crash/upgrade re-attach scenario the restore half tests).
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# Walk +list --json for the first terminal leaf id.
function Find-Pane($tree) {
    if ($null -eq $tree) { return $null }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
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
function Wait-FirstPane($tmp, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Run-Cli '+list --json' "$tmp\list.json" 10
        if ($code -eq 0) {
            $tree = $null
            try { $tree = Out-Text "$tmp\list.json" | ConvertFrom-Json } catch {}
            $pane = Find-Pane $tree
            if ($null -ne $pane) { return $pane }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# The rows of `+sessions --json`, or @() if the CLI failed / no agent / empty.
function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Count-Alive($rows) { return @($rows | Where-Object { $_.alive -eq $true }).Count }
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Count-Alive $rows) -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}
function Alive-Ids($rows) {
    return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
}

# ---- Manifest helpers (the T89f artifact under test) -----------------------

# Debug builds write the -debug filename (session_layout.layoutPath).
function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

# Poll the manifest until $pred returns $true for the parsed object (or timeout).
# Returns the last parsed manifest (possibly not satisfying $pred).
function Wait-Manifest($tmp, $pred, $timeoutSec = 8) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 300
    }
    return $m
}

# All leaf session_ids across a manifest window's tabs, in node order.
function Leaf-Sids($win) {
    $ids = @()
    foreach ($t in @($win.tabs)) {
        foreach ($n in @($t.nodes)) {
            if ($null -ne $n.leaf -and $n.leaf.session_id) { $ids += $n.leaf.session_id }
        }
    }
    return , $ids  # unary comma: never let PS unwrap a 1-element array to a scalar
}
function Count-Splits($win) {
    $c = 0
    foreach ($t in @($win.tabs)) {
        foreach ($n in @($t.nodes)) { if ($null -ne $n.split) { $c++ } }
    }
    return $c
}

# Union of every leaf session_id across ALL windows of a manifest, in order.
# Built inline (not via Leaf-Sids) so there is no nested protective-comma array;
# callers wrap in @() to strip the single protective wrap.
function All-Sids($m) {
    $ids = @()
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf -and $n.leaf.session_id) { $ids += $n.leaf.session_id }
            }
        }
    }
    return , $ids
}

# Count top-level windows in a +list --json tree (-1 on CLI failure).
function Count-Windows($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\lw-$tag.json" 10
    if ($code -ne 0) { return -1 }
    $tree = $null
    try { $tree = Out-Text "$tmp\lw-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $tree) { return -1 }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    return @($windows).Count
}
function Wait-Windows($tmp, $tag, $target, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $n = -1
    while ((Get-Date) -lt $deadline) {
        $n = Count-Windows $tmp $tag
        if ($n -eq $target) { return $n }
        Start-Sleep -Milliseconds 500
    }
    return $n
}

# Count terminal leaves across every window/tab in a +list --json tree.
function Count-Leaves($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\ll-$tag.json" 10
    if ($code -ne 0) { return -1 }
    $tree = $null
    try { $tree = Out-Text "$tmp\ll-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $tree) { return -1 }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    $c = 0
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) { $c += (Count-Leaf-Nodes $t.splits) }
    }
    return $c
}
function Count-Leaf-Nodes($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    if ($node.type -eq 'split') { return (Count-Leaf-Nodes $node.left) + (Count-Leaf-Nodes $node.right) }
    return 0
}

# ---- T105 focus-stability interop (section F10/F11) ------------------------
# Pre-fix, a 2-window restore live-locked: each restored window queued a
# WM_APP_SETFOCUS assert whose execution stole activation from the other
# window; every steal re-fired the loser's WM_SETFOCUS forwarding, queueing
# the next assert — a perpetual activation ping-pong that made the app
# uncontrollable. The oracle samples the GUI thread's focus window (wedge-
# immune: needs no foreground) and the global foreground window, counting
# transitions between the two restored top-levels.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class T105Drv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public uint cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // All visible GhozttyWindow top-levels of a process.
    public static IntPtr[] TopWindows(uint pid) {
        var wins = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") wins.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return wins.ToArray();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab (best-effort; the wedge may swallow it).
    public static bool GrabForeground(IntPtr top) {
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            Key(0x12, false); Key(0x12, true); // Alt tap
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    // First GhozttyTerminal child of a top-level (a pane surface HWND).
    public static IntPtr FirstTerminal(IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Which of the app top-levels does hwnd belong to (itself or via root)?
    static IntPtr Belongs(IntPtr[] wins, IntPtr h) {
        if (h == IntPtr.Zero) return IntPtr.Zero;
        IntPtr root = GetAncestor(h, 2); // GA_ROOT
        foreach (var w in wins) if (w == h || w == root) return w;
        return IntPtr.Zero;
    }

    // Sample for totalMs at stepMs; count transitions of (a) the global
    // foreground window and (b) the GUI thread's focus window between
    // DIFFERENT app top-levels. Returns { fgFlips, focusFlips }.
    public static int[] SampleFlips(IntPtr[] wins, int totalMs, int stepMs) {
        uint pid; uint tid = GetWindowThreadProcessId(wins[0], out pid);
        int fgFlips = 0, focFlips = 0;
        IntPtr lastFg = IntPtr.Zero, lastFoc = IntPtr.Zero;
        for (int t = 0; t < totalMs; t += stepMs) {
            IntPtr fgApp = Belongs(wins, GetForegroundWindow());
            if (fgApp != IntPtr.Zero) {
                if (lastFg != IntPtr.Zero && fgApp != lastFg) fgFlips++;
                lastFg = fgApp;
            }
            var gi = new GUITHREADINFO();
            gi.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
            if (GetGUIThreadInfo(tid, ref gi)) {
                IntPtr focApp = Belongs(wins, gi.hwndFocus);
                if (focApp != IntPtr.Zero) {
                    if (lastFoc != IntPtr.Zero && focApp != lastFoc) focFlips++;
                    lastFoc = focApp;
                }
            }
            Thread.Sleep(stepMs);
        }
        return new int[] { fgFlips, focFlips };
    }
}
'@

# One hermetic GUI launch (fresh LOCALAPPDATA + agent-bin override).
function Start-Backed($label, $title) {
    $tmp = Join-Path $root $label
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @("--title=$title") | Out-Null
    $pane = Wait-FirstPane $tmp 25
    $rows = Wait-AliveCount $tmp 'setup' 1 18
    $ok = ($null -ne $pane -and (Count-Alive $rows) -eq 1)
    return @{ Tmp = $tmp; Ok = $ok }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

# ============================================================================
"== A: startup window is captured with its agent session id"
# ============================================================================
$g = Start-Backed 'capture' 't89f-reattach'
Assert "A1 startup pane is agent-backed (one live session)" $g.Ok
$tmp = $g.Tmp
$sid0 = @(Alive-Ids (Get-Sessions $tmp 'a'))[0]

$mA = Wait-Manifest $tmp { param($m) @($m.windows).Count -ge 1 -and (Leaf-Sids $m.windows[0]).Count -ge 1 } 10
Assert "A2 manifest written with one window" ($null -ne $mA -and @($mA.windows).Count -eq 1)
Assert "A3 window has one tab with one leaf" (
    $null -ne $mA -and @($mA.windows[0].tabs).Count -eq 1 -and @($mA.windows[0].tabs[0].nodes).Count -eq 1)
$sidsA = if ($null -ne $mA) { Leaf-Sids $mA.windows[0] } else { @() }
Assert "A4 captured leaf session_id matches the live agent session" (
    $sidsA.Count -eq 1 -and $sid0 -and $sidsA[0] -eq $sid0)
Assert "A5 manifest declares schema version 1" ($null -ne $mA -and $mA.version -eq 1)

# ============================================================================
"== B: +split grows the captured tree to a split + two leaves"
# ============================================================================
Run-Cli '+split --direction=right --name=f89sib' "$tmp\split.txt" 15 | Out-Null
$rowsB = Wait-AliveCount $tmp 'b' 2 15
Assert "B1 +split opened a second agent-backed session (2 alive)" ((Count-Alive $rowsB) -eq 2)
$aliveB = @(Alive-Ids $rowsB)
$mB = Wait-Manifest $tmp { param($m) (Leaf-Sids $m.windows[0]).Count -ge 2 } 10
$sidsB = if ($null -ne $mB) { Leaf-Sids $mB.windows[0] } else { @() }
Assert "B2 the tab tree now records two leaves" ($sidsB.Count -eq 2)
Assert "B3 the tree records exactly one split node" ($null -ne $mB -and (Count-Splits $mB.windows[0]) -eq 1)
$split = $null
if ($null -ne $mB) { foreach ($n in $mB.windows[0].tabs[0].nodes) { if ($n.split) { $split = $n.split } } }
Assert "B4 split records a layout (horizontal|vertical)" (
    $null -ne $split -and @('horizontal', 'vertical') -contains $split.layout)
Assert "B5 split records an in-range ratio" (
    $null -ne $split -and $split.ratio -gt 0.0 -and $split.ratio -lt 1.0)
Assert "B6 both captured leaf session_ids are live agent sessions" (
    $sidsB.Count -eq 2 -and ($aliveB -contains $sidsB[0]) -and ($aliveB -contains $sidsB[1]))

# ============================================================================
"== C: +new-window adds a second captured window with its IPC name"
# ============================================================================
Run-Cli '+new-window --target=second' "$tmp\neww.txt" 15 | Out-Null
$mC = Wait-Manifest $tmp { param($m) @($m.windows).Count -ge 2 } 10
Assert "C1 manifest now has two windows" ($null -ne $mC -and @($mC.windows).Count -eq 2)
$second = @($mC.windows | Where-Object { $_.ipc_name -eq 'second' })
Assert "C2 the second window carries its IPC name" ($second.Count -eq 1)
Assert "C3 the second window's id equals its IPC name" (
    $second.Count -eq 1 -and $second[0].id -eq 'second')

# ============================================================================
"== D: +rename --title captures the window title pin"
# ============================================================================
Run-Cli '+rename --target=second --title=HelloTitle' "$tmp\rename.txt" 12 | Out-Null
$mD = Wait-Manifest $tmp {
    param($m)
    $w = @($m.windows | Where-Object { $_.ipc_name -eq 'second' })
    $w.Count -eq 1 -and $w[0].title_override -eq 'HelloTitle'
} 10
$w2 = @($mD.windows | Where-Object { $_.ipc_name -eq 'second' })
Assert "D1 the title pin was captured into title_override" (
    $w2.Count -eq 1 -and $w2[0].title_override -eq 'HelloTitle')

# ============================================================================
"== E: every captured window has a real frame + boolean maximized"
# ============================================================================
$mE = Read-Manifest $tmp
$framesOk = $true
$maxOk = $true
if ($null -ne $mE) {
    foreach ($w in @($mE.windows)) {
        if ($null -eq $w.frame -or $w.frame.w -le 0 -or $w.frame.h -le 0) { $framesOk = $false }
        if ($w.maximized -isnot [bool]) { $maxOk = $false }
    }
} else { $framesOk = $false; $maxOk = $false }
Assert "E1 every window records a frame with positive width/height" $framesOk
Assert "E2 every window records a boolean maximized flag" $maxOk

# ============================================================================
"== F: quit-keep-sessions then relaunch re-ATTACHes the whole layout"
# ============================================================================
# Reuse the A-E state: window 1 (startup pane + the f89sib split) + window
# 'second' (title 'HelloTitle') = a 2-window / 3-pane layout with 3 live
# agent sessions. Mark scrollback in the split pane, record the live session
# ids, KILL ONLY THE APP (the agent keeps every PTY), relaunch, and prove the
# same sessions come back in the same layout with their scrollback + titles.
# A single space-free token: send-keys concatenates positional args (and cmd's
# /c nesting would collapse a quoted space anyway), so a bare marker + Enter is
# the robust way to plant text. cmd echoes it + errors ("'MARKER' is not
# recognized..."), both landing the token in scrollback. The minimized window's
# client area is a few columns wide, so cmd's line WRAPS the marker across rows —
# match with all whitespace stripped (the T99 section-D narrow-pane technique).
$marker = "REATTACHMARKER$($PID)XYZ"  # no separators: survives per-glyph wrapping
function Read-HasMarker($f) { return ((Out-Text $f) -replace '\s', '') -match $marker }
Run-Cli "+send-keys --target=f89sib $marker Enter" "$tmp\mark.txt" 12 | Out-Null
# Poll +read until the marker shows (the shell printed it) pre-quit.
$preOk = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    Run-Cli '+read --name=f89sib --lines=200' "$tmp\read-pre.txt" 10 | Out-Null
    if (Read-HasMarker "$tmp\read-pre.txt") { $preOk = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "F1 marker is in the split pane's scrollback before quit" $preOk

# The live session ids the agent is keeping (must all come back on re-attach).
$beforeIds = @(Alive-Ids (Wait-AliveCount $tmp 'f-before' 3 15))
Assert "F2 three agent sessions are alive before quit" ($beforeIds.Count -eq 3)

# Manifest must already reflect the full 2-window layout (debounced write) so
# the abrupt app kill loses nothing.
$mPre = Wait-Manifest $tmp {
    param($m)
    @($m.windows).Count -eq 2 -and (All-Sids $m).Count -eq 3
} 10
Assert "F3 manifest holds the full 2-window / 3-session layout pre-quit" (
    $null -ne $mPre -and @($mPre.windows).Count -eq 2 -and (All-Sids $mPre).Count -eq 3)

# Kill ONLY ghoztty.exe; the detached agent survives with all 3 PTYs.
Stop-AppOnly
$agentIds = @(Alive-Ids (Wait-AliveCount $tmp 'f-agent' 3 15))
Assert "F4 the agent kept all 3 sessions alive after the app died" (
    $agentIds.Count -eq 3 -and ($beforeIds | Where-Object { $agentIds -contains $_ }).Count -eq 3)

# Relaunch (same LOCALAPPDATA + agent bin). Restore must suppress the blank
# startup window and rebuild both windows by re-ATTACHing.
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$relaunched = Start-Process -FilePath $Exe -WindowStyle Minimized -PassThru

$winCount = Wait-Windows $tmp 'f-post' 2 30
Assert "F5 relaunch restored exactly two windows (no extra blank)" ($winCount -eq 2)
$leafCount = Count-Leaves $tmp 'f-post'
Assert "F6 relaunch restored all three panes" ($leafCount -eq 3)

# ATTACH proof: the agent still has EXACTLY the same 3 sessions alive (a fresh
# OPEN per pane would have spawned new ones on top of the survivors).
$afterIds = @(Alive-Ids (Wait-AliveCount $tmp 'f-after' 3 20))
Assert "F7 the same 3 sessions are alive after relaunch (ATTACH, not re-OPEN)" (
    $afterIds.Count -eq 3 -and ($beforeIds | Where-Object { $afterIds -contains $_ }).Count -eq 3)

# The restored split pane kept its IPC name (re-registered on restore) AND its
# scrollback (gap-fill replay from the agent ring). Whitespace-stripped match,
# same narrow-pane wrapping as F1.
$postOk = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    # 2000 lines (was 200): headroom against reflow/repaint after re-attach
    # pushing the narrow-wrapped replayed marker deeper into the tail.
    $code = Run-Cli '+read --name=f89sib --lines=2000' "$tmp\read-post.txt" 10
    if ($code -eq 0 -and (Read-HasMarker "$tmp\read-post.txt")) { $postOk = $true; break }
    Start-Sleep -Milliseconds 700
}
Assert "F8 restored pane keeps its IPC name and its pre-quit scrollback" $postOk

# The window title pin survived the round-trip (rewritten manifest post-restore).
# Direct poll (not Wait-Manifest): the manifest is rewritten atomically as the
# restored panes publish their session ids, so a single racy read can miss it —
# re-read until the 'second' window shows its restored title_override.
$f9 = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $m = Read-Manifest $tmp
    if ($null -ne $m) {
        $w = @($m.windows | Where-Object { $_.ipc_name -eq 'second' })
        if ($w.Count -eq 1 -and $w[0].title_override -eq 'HelloTitle') { $f9 = $true; break }
    }
    Start-Sleep -Milliseconds 400
}
Assert "F9 the restored window's title pin came back" $f9

# ============================================================================
"== F10: restore-time focus stability across a VISIBLE relaunch (T105)"
# The pre-fix live-lock needs the app to be foreground while restore builds
# both windows back-to-back (baseline-proven: fgFlips=38/focusFlips=36 in 3s
# pre-fix, 0/0 post-fix). Do a SECOND app-only kill + relaunch, this time
# visible, grabbing foreground onto the first restored window the moment it
# exists, and sample before any Run-Cli cmd.exe perturbs activation. The
# scrollback asserts stay in the minimized F5-F9 cycle above: a visible
# relaunch currently loses the replayed scrollback (pre-existing, tracked as
# T106) — THIS cycle asserts focus stability only.
Stop-AppOnly
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$relaunch2 = Start-Process -FilePath $Exe -PassThru
$wins = @()
$grabbedEarly = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    $wins = @([T105Drv]::TopWindows([uint32]$relaunch2.Id))
    if (-not $grabbedEarly -and $wins.Count -ge 1) {
        $grabbedEarly = [T105Drv]::GrabForeground($wins[0])
    }
    if ($wins.Count -ge 2) { break }
    Start-Sleep -Milliseconds 100
}
Assert "F10a both restored top-level windows enumerated (visible relaunch)" ($wins.Count -eq 2)
if ($wins.Count -eq 2) {
    $storm = [T105Drv]::SampleFlips($wins, 3000, 40)
    "  (restore-time fgFlips=$($storm[0]) focusFlips=$($storm[1]) grabbedEarly=$grabbedEarly)"
    Assert "F10 no restore-time focus storm between the two windows" ($storm[1] -le 2)
}

# F11 (T105 floor): seed one pending WM_APP_SETFOCUS (0x8005 = WM_APP+5)
# assert per window, queued back-to-back with no drain gap, then require
# focus/foreground to settle. This is an invariant floor, not the
# discriminating oracle (F10 is: the perpetual storm needs the app to be
# foreground DURING restore — baseline-proven). Post-fix the guard drops any
# assert whose window is not foreground, so the pair must always settle.
# PostMessage needs no foreground rights: wedge-immune.
"== F11: seeded co-pending focus asserts must settle, not ping-pong (T105)"
if ($wins.Count -eq 2) {
    $grabbed = [T105Drv]::GrabForeground($wins[0])  # realism, best-effort
    $surf0 = [T105Drv]::FirstTerminal($wins[0])
    $surf1 = [T105Drv]::FirstTerminal($wins[1])
    Assert "F11a a terminal surface found in each restored window" (
        $surf0 -ne [IntPtr]::Zero -and $surf1 -ne [IntPtr]::Zero)
    if ($surf0 -ne [IntPtr]::Zero -and $surf1 -ne [IntPtr]::Zero) {
        [T105Drv]::PostMessageW($surf0, 0x8005, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        [T105Drv]::PostMessageW($surf1, 0x8005, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 300
        $flips = [T105Drv]::SampleFlips($wins, 3000, 40)
        "  (post-seed fgFlips=$($flips[0]) focusFlips=$($flips[1]) grabbed=$grabbed)"
        Assert "F11 GUI-thread focus settles after seeded asserts" ($flips[1] -le 2)
        if ($grabbed) {
            Assert "F11b foreground stays parked after seeded asserts" ($flips[0] -le 2)
        } else {
            "  SKIP F11b (foreground grab failed - box wedge); focus oracle still ran"
        }
    }
} else {
    "  SKIP F11 (restored windows not enumerated)"
}

# ============================================================================
if ($script:failures -gt 0) {
    "== DIAG: final manifest =="
    $dp = Manifest-Path $tmp
    if (Test-Path $dp) { Get-Content $dp -Raw } else { "NO MANIFEST FILE at $dp" }
    "== DIAG: sid0=$sid0"
}

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
else { "artifacts preserved at $root" }

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
