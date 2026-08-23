# T207 deliverable 1 - the spike that decides the shape of the whole task.
#
# Question: can the GUI acceptance scripts run on a SEPARATE Win32 desktop
# (CreateDesktopW), so they stop stealing the user's foreground?
#
# Three sub-questions, all answered here against a real ghoztty launch:
#   1. ISOLATION - does a window created on a background desktop stay off the
#      interactive desktop (never enumerable there, never foreground there)?
#   2. INPUT     - does SendInput from a thread bound to that desktop reach the
#      app? (asserted end-to-end: ctrl+shift+t must add a tab, read back over
#      IPC from the normal desktop.)
#   3. CAPTURE   - is anything COMPOSED there? DWM composes only the input
#      desktop, so the 6 pixel-probe scripts are the known risk. Both capture
#      paths are measured: BitBlt from the desktop DC (what
#      Graphics.CopyFromScreen does) and PrintWindow(PW_RENDERFULLCONTENT).
#
# The app is launched with --window-theme=light on purpose: a light window is
# bright, so "capture returned black" is unambiguous rather than a plausible
# dark-terminal reading.
#
# ANSWERS (measured on box 2026-07-30; the assertions below encode them, so
# this script doubles as the regression test for the T211 harness):
#   isolation - total. Not enumerable on the interactive desktop, never
#               foreground there.
#   input     - SendInput is BLOCKED (0 events accepted, ACCESS_DENIED); a
#               background desktop is not the input desktop. Posted
#               WM_KEYDOWN works, and modifier chords work when the key state
#               is set on the input queue we share via AttachThreadInput.
#   capture   - CopyFromScreen/BitBlt is dead (DWM composes only the input
#               desktop), but PrintWindow(PW_RENDERFULLCONTENT) returns real
#               content. The pixel probes can migrate; they just cannot
#               screenshot.
#
# This script is SAFE to run while the user is working - that is the entire
# point of it. It asserts that itself (P3/P4).
#
# Only touches ghoztty processes running from this repo's zig-out, and it
# talks to its own IPC endpoint via GHOZTTY_PIPE_SUFFIX so the user's real
# instance is never queried or disturbed.
param([string]$ExePath)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# T1127: the teardown at the bottom is -AppOnly, and even the full one would
# miss the agent's `--pty-host` holders, which own the ConPTY and escape the
# job on purpose. Arm the build-scoped teardown so nothing from zig-out
# outlives the script - failure path included, which is this script's normal
# ending when the spike measures a regression.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-RepoBuildTeardown -Exe $exe | Out-Null

$env:GHOZTTY_PIPE_SUFFIX = "-desktopspike$PID"

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public class DeskSpike {
    // ---- desktop / process ----
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    // ---- windows ----
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern IntPtr GetActiveWindow();
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] s);
    [DllImport("user32.dll")] public static extern bool SetKeyboardState(byte[] s);

    // ---- gdi ----
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr d, int dx, int dy, int w, int h, IntPtr s, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hdc, int x, int y);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEKEYBD u; }
    [StructLayout(LayoutKind.Explicit, Size = 32)]
    public struct MOUSEKEYBD {
        [FieldOffset(0)] public int dx;
        [FieldOffset(4)] public int dy;
        [FieldOffset(8)] public uint mouseData;
        [FieldOffset(12)] public uint mouseFlags;
        [FieldOffset(16)] public uint time;
        [FieldOffset(24)] public IntPtr extra;
        [FieldOffset(0)] public ushort wVk;
        [FieldOffset(2)] public ushort wScan;
        [FieldOffset(4)] public uint kbFlags;
    }
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // ---- results, read back by the PowerShell assertions ----
    public static string Log = "";
    public static bool DesktopCreated = false;
    public static bool ThreadBound = false;
    public static bool ProcessStarted = false;
    public static int Pid = 0;
    public static bool WindowFoundOnTestDesktop = false;
    public static bool ForegroundTakenOnTestDesktop = false;
    public static int WinW = 0, WinH = 0;
    public static int BitBltMeanLum = -1;      // -1 = capture failed outright
    public static int BitBltDistinct = -1;
    public static int PrintMeanLum = -1;
    public static int PrintDistinct = -1;
    public static bool ChordSent = false;
    public static int SendInputAccepted = -1;
    public static int SendInputLastError = -1;

    static void note(string s) { Log += s + "\n"; }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1; i[0].u.wVk = vk; i[0].u.kbFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Returns how many events SendInput actually accepted (0 = blocked).
    static uint KeyChar(char c) {
        uint n = 0;
        var i = new INPUT[1];
        i[0].type = 1; i[0].u.wVk = (ushort)char.ToUpper(c); i[0].u.kbFlags = 0;
        n += SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        i[0].u.kbFlags = 2;
        n += SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        return n;
    }

    // Mean luminance + distinct-color count over a 4px grid of a memory DC.
    // A capture of a desktop that is not composed comes back uniformly black:
    // mean ~0 AND distinct == 1. Real window content is neither.
    static void Sample(IntPtr hdcMem, int w, int h, out int meanLum, out int distinct) {
        double sum = 0; int n = 0;
        var seen = new System.Collections.Generic.HashSet<uint>();
        for (int y = 2; y < h; y += 4) {
            for (int x = 2; x < w; x += 4) {
                uint c = GetPixel(hdcMem, x, y);
                if (c == 0xFFFFFFFF) continue; // CLR_INVALID
                uint r = c & 0xFF, g = (c >> 8) & 0xFF, b = (c >> 16) & 0xFF;
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                n++;
                if (seen.Count < 4096) seen.Add(c);
            }
        }
        meanLum = (n == 0) ? -1 : (int)(sum / n);
        distinct = (n == 0) ? -1 : seen.Count;
    }

    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    static IntPtr FindChildClass(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static IntPtr FindClassForPid(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Runs the whole spike on a dedicated thread bound to the test desktop.
    // SetThreadDesktop fails on a thread that already owns windows or hooks,
    // which is exactly why this cannot run on the PowerShell host thread.
    public static void Run(string exe, string desktopName, string extraArgs, int settleMs) {
        var t = new Thread(() => Body(exe, desktopName, extraArgs, settleMs));
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
    }

    static void Body(string exe, string desktopName, string extraArgs, int settleMs) {
        IntPtr hDesk = IntPtr.Zero;
        try {
            SetProcessDPIAware();
            hDesk = CreateDesktopW(desktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /*GENERIC_ALL*/, IntPtr.Zero);
            if (hDesk == IntPtr.Zero) { note("CreateDesktopW failed: " + Marshal.GetLastWin32Error()); return; }
            DesktopCreated = true;

            if (!SetThreadDesktop(hDesk)) { note("SetThreadDesktop failed: " + Marshal.GetLastWin32Error()); return; }
            ThreadBound = true;

            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            si.lpDesktop = "WinSta0\\" + desktopName;
            PROCESS_INFORMATION pi;
            var cmd = new StringBuilder("\"" + exe + "\" " + extraArgs);
            if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x08000000 /*CREATE_NO_WINDOW*/, IntPtr.Zero, null, ref si, out pi)) {
                note("CreateProcessW failed: " + Marshal.GetLastWin32Error());
                return;
            }
            ProcessStarted = true;
            Pid = pi.dwProcessId;
            note("launched pid " + Pid + " on desktop " + si.lpDesktop);

            IntPtr top = IntPtr.Zero;
            for (int i = 0; i < 60 && top == IntPtr.Zero; i++) {
                Thread.Sleep(250);
                top = FindClassForPid((uint)Pid, "GhozttyWindow");
            }
            if (top == IntPtr.Zero) { note("GhozttyWindow never appeared on the test desktop"); return; }
            WindowFoundOnTestDesktop = true;
            Thread.Sleep(settleMs);

            RECT r;
            GetWindowRect(top, out r);
            WinW = r.right - r.left; WinH = r.bottom - r.top;
            note("window rect " + r.left + "," + r.top + " " + WinW + "x" + WinH);

            // --- foreground ON THE TEST DESKTOP. Each desktop keeps its own
            // foreground window, so this must succeed here without ever
            // touching the interactive one.
            // A background desktop is not the INPUT desktop, so it has no
            // foreground window: SetForegroundWindow fails and
            // GetForegroundWindow is 0. Focus still exists per input queue,
            // so the way in is AttachThreadInput onto the app's GUI thread
            // and then SetActiveWindow/SetFocus - after which SendInput from
            // this thread routes to that focus window.
            bool sfw = SetForegroundWindow(top);
            Thread.Sleep(200);
            IntPtr fg = GetForegroundWindow();
            ForegroundTakenOnTestDesktop = (fg == top);
            note("SetForegroundWindow=" + sfw + " GetForegroundWindow=" + fg + " top=" + top);

            uint appPid; uint appTid = GetWindowThreadProcessId(top, out appPid);
            uint myTid = GetCurrentThreadId();
            bool att = AttachThreadInput(myTid, appTid, true);
            SetActiveWindow(top);
            SetFocus(top);
            Thread.Sleep(150);
            note("AttachThreadInput=" + att + " GetFocus=" + GetFocus() + " GetActiveWindow=" + GetActiveWindow());

            // --- capture path 1: BitBlt off the desktop DC (== CopyFromScreen)
            if (WinW > 0 && WinH > 0) {
                IntPtr hdcScreen = GetDC(IntPtr.Zero);
                IntPtr hdcMem = CreateCompatibleDC(hdcScreen);
                IntPtr hbmp = CreateCompatibleBitmap(hdcScreen, WinW, WinH);
                IntPtr old = SelectObject(hdcMem, hbmp);
                bool ok = BitBlt(hdcMem, 0, 0, WinW, WinH, hdcScreen, r.left, r.top, 0x00CC0020 /*SRCCOPY*/);
                note("BitBlt from desktop DC ok=" + ok);
                if (ok) { int m, d; Sample(hdcMem, WinW, WinH, out m, out d); BitBltMeanLum = m; BitBltDistinct = d; }
                SelectObject(hdcMem, old); DeleteObject(hbmp); DeleteDC(hdcMem); ReleaseDC(IntPtr.Zero, hdcScreen);

                // --- capture path 2: PrintWindow(PW_RENDERFULLCONTENT)
                IntPtr hdcWin = GetDC(top);
                IntPtr hdcMem2 = CreateCompatibleDC(hdcWin);
                IntPtr hbmp2 = CreateCompatibleBitmap(hdcWin, WinW, WinH);
                IntPtr old2 = SelectObject(hdcMem2, hbmp2);
                bool pok = PrintWindow(top, hdcMem2, 2 /*PW_RENDERFULLCONTENT*/);
                note("PrintWindow(PW_RENDERFULLCONTENT) ok=" + pok);
                if (pok) { int m, d; Sample(hdcMem2, WinW, WinH, out m, out d); PrintMeanLum = m; PrintDistinct = d; }
                SelectObject(hdcMem2, old2); DeleteObject(hbmp2); DeleteDC(hdcMem2); ReleaseDC(top, hdcWin);
            }

            IntPtr surf = FindChildClass(top, "GhozttyTerminal");
            note("GhozttyTerminal child: " + surf);
            IntPtr target = (surf != IntPtr.Zero) ? surf : top;

            // --- input path 1: SendInput, what all 36 driving scripts use.
            uint sent = 0;
            foreach (char c in "SPIKEA") { sent += KeyChar(c); }
            SendInputLastError = Marshal.GetLastWin32Error();
            SendInputAccepted = (int)sent;
            Thread.Sleep(400);
            note("SendInput events accepted: " + sent + " of 12 (last error " + SendInputLastError + ")");

            // --- input path 2: posted key messages. The terminal class skips
            // TranslateMessage (App.run) and calls ToUnicode itself, so a bare
            // WM_KEYDOWN is enough - posting WM_CHAR too would double every
            // character.
            foreach (char c in "SPIKEB") {
                PostMessageW(target, 0x0100 /*WM_KEYDOWN*/, (IntPtr)char.ToUpper(c), IntPtr.Zero);
                PostMessageW(target, 0x0101 /*WM_KEYUP*/, (IntPtr)char.ToUpper(c), IntPtr.Zero);
            }
            Thread.Sleep(800);

            // --- input path 3: a MODIFIER CHORD by the same route. Posted
            // messages do not move the key state that the app reads back for
            // modifiers, so set it explicitly - legal here because
            // AttachThreadInput has merged our input queue with the app's, and
            // on a background desktop no raw-input thread overwrites it.
            var ks = new byte[256];
            GetKeyboardState(ks);
            ks[0x11] = 0x80; ks[0xA2] = 0x80;   // VK_CONTROL, VK_LCONTROL
            ks[0x10] = 0x80; ks[0xA0] = 0x80;   // VK_SHIFT, VK_LSHIFT
            SetKeyboardState(ks);
            PostMessageW(target, 0x0100, (IntPtr)0x11, IntPtr.Zero);
            PostMessageW(target, 0x0100, (IntPtr)0x10, IntPtr.Zero);
            PostMessageW(target, 0x0100, (IntPtr)0x54, IntPtr.Zero); // 'T'
            Thread.Sleep(200);
            PostMessageW(target, 0x0101, (IntPtr)0x54, IntPtr.Zero);
            PostMessageW(target, 0x0101, (IntPtr)0x10, IntPtr.Zero);
            PostMessageW(target, 0x0101, (IntPtr)0x11, IntPtr.Zero);
            ks[0x11] = 0; ks[0xA2] = 0; ks[0x10] = 0; ks[0xA0] = 0;
            SetKeyboardState(ks);
            ChordSent = true;
            Thread.Sleep(1500);
            note("post-chord GetFocus=" + GetFocus());
            AttachThreadInput(myTid, appTid, false);
        } catch (Exception e) {
            note("EXCEPTION " + e.Message);
        } finally {
            // The desktop object lives until the last handle closes AND the
            // last window on it is destroyed; the process is killed by the
            // caller, so just drop our handle.
            if (hDesk != IntPtr.Zero) CloseDesktop(hDesk);
        }
    }

    // --- interactive-desktop side ---
    // A thread created here inherits the PROCESS desktop (the interactive
    // one) - only the spike thread is ever rebound - so this samples exactly
    // what the user is looking at while the spike runs.
    static volatile bool watchStop = false;
    static Thread watchThread = null;
    public static string ForegroundPidsSeen = "";
    public static void StartForegroundWatch() {
        watchStop = false;
        var seen = new System.Collections.Generic.HashSet<uint>();
        watchThread = new Thread(() => {
            while (!watchStop) {
                uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
                lock (seen) { seen.Add(p); }
                Thread.Sleep(150);
            }
            var sb = new StringBuilder();
            lock (seen) { foreach (uint p in seen) sb.Append(p).Append(","); }
            ForegroundPidsSeen = sb.ToString();
        });
        watchThread.IsBackground = true;
        watchThread.Start();
    }
    public static void StopForegroundWatch() {
        watchStop = true;
        if (watchThread != null) watchThread.Join(2000);
    }

    public static bool AnyVisibleWindowForPid(uint pid) {
        bool any = false;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) { any = true; return false; }
            return true;
        }, IntPtr.Zero);
        return any;
    }
    public static uint ForegroundPid() {
        uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p;
    }
}
'@

function Kill-SpikeInstances {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

Kill-SpikeInstances

# Watch the INTERACTIVE desktop for the whole run: no ghoztty of ours may
# ever become foreground there. This is the user's actual complaint, asserted.
[DeskSpike]::StartForegroundWatch()

Write-Host "--- running spike on desktop 'ghoztty-spike' (the user's desktop must not flicker) ---"
[DeskSpike]::Run($exe, 'ghoztty-spike', '--window-theme=light --window-show-tab-bar=always', 1500)

$spikePid = [DeskSpike]::Pid
Write-Host ([DeskSpike]::Log)

Assert ([DeskSpike]::DesktopCreated) "CreateDesktopW('ghoztty-spike') succeeded"
Assert ([DeskSpike]::ThreadBound) "SetThreadDesktop bound the harness thread to it"
Assert ([DeskSpike]::ProcessStarted) "ghoztty launched with STARTUPINFO.lpDesktop"
Assert ([DeskSpike]::WindowFoundOnTestDesktop) "GhozttyWindow is enumerable ON the test desktop"

# P1/P2: isolation. Enumerating from this thread (still on the interactive
# desktop) must not see it, and it must never have taken foreground here.
if ($spikePid -gt 0) {
    Assert (-not [DeskSpike]::AnyVisibleWindowForPid([uint32]$spikePid)) `
        "the window is NOT enumerable on the interactive desktop"
}

# P3: input reach - ctrl+shift+t on the background desktop must have made a
# second tab. Read it back over the spike's own IPC endpoint.
$tabs = -1
$json = ''
try {
    $json = (& $exe +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    if ($json.Trim()) {
        $tree = $json | ConvertFrom-Json
        $tabs = @($tree.data.windows[0].tabs).Count
    }
} catch { Write-Host "list parse error: $_"; $tabs = -1 }
# Read the pane back to see which input mechanism actually landed.
$paneText = ''
try {
    $pane = $tree.data.windows[0].tabs[0].splits.terminal.name
    if ($pane) { $paneText = (& $exe +read --name=$pane --lines=10 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String) }
} catch { Write-Host "read error: $_" }
$sawSendInput = [bool]($paneText -match 'SPIKEA')
$sawPost = [bool]($paneText -match 'spikeb')
$si = [DeskSpike]::SendInputAccepted; $sierr = [DeskSpike]::SendInputLastError

# INPUT-1: SendInput is BLOCKED on a non-input desktop. Asserted, not assumed:
# it is the single fact that decides the harness cannot just be relocated.
Assert ($si -eq 0 -and $sierr -eq 5 -and -not $sawSendInput) `
    "SendInput is blocked on a background desktop (accepted=$si, err=$sierr = ACCESS_DENIED)"
# INPUT-2: posted key messages DO reach the terminal there.
Assert ($sawPost) "posted WM_KEYDOWN reaches the terminal on a background desktop"
# INPUT-3: and a modifier chord survives the same route (key state set over
# the attached input queue). ctrl+shift+t must have opened a second tab.
Write-Host "tabs after the posted ctrl+shift+t: $tabs"
Assert ([DeskSpike]::ChordSent -and $tabs -ge 2) `
    "a posted ctrl+shift+t chord fires its keybind (tabs=$tabs, want >=2)"

# CAPTURE: the question the whole option was said to hang on.
$bl = [DeskSpike]::BitBltMeanLum; $bd = [DeskSpike]::BitBltDistinct
$pl = [DeskSpike]::PrintMeanLum;  $pd = [DeskSpike]::PrintDistinct
Write-Host "CAPTURE  BitBlt(desktop DC): meanLum=$bl distinct=$bd"
Write-Host "CAPTURE  PrintWindow(FULLCONTENT): meanLum=$pl distinct=$pd"
$bitbltReal = ($bl -gt 60 -and $bd -gt 4)
$printReal  = ($pl -gt 60 -and $pd -gt 4)
# CAP-1: CopyFromScreen/BitBlt is dead there - DWM composes only the input
# desktop, exactly as the task predicted. Recorded so it is not re-tried.
Assert (-not $bitbltReal) "CopyFromScreen/BitBlt off the desktop DC is dead on a background desktop"
# CAP-2: but PrintWindow(PW_RENDERFULLCONTENT) returns REAL content, so the
# pixel probes can migrate after all - they just cannot screenshot.
Assert ($printReal) "PrintWindow(PW_RENDERFULLCONTENT) returns real content (meanLum=$pl, distinct=$pd)"

if ($spikePid -gt 0) { Stop-Process -Id $spikePid -Force -ErrorAction SilentlyContinue }
Kill-SpikeInstances

# Drain the foreground watcher.
[DeskSpike]::StopForegroundWatch()
$fgSeen = @([DeskSpike]::ForegroundPidsSeen.Split(',') | Where-Object { $_ } | ForEach-Object { [int]$_ })
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if ($spikePid -gt 0) {
    Assert ($fgSeen.Count -gt 0) "the foreground watcher actually sampled (negative control)"
    Assert (-not ($fgSeen -contains [int]$spikePid)) `
        "the test-desktop app NEVER became foreground on the interactive desktop"
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
