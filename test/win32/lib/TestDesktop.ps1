# T211: the shared test-desktop harness.
#
# Purpose: run the GUI acceptance scripts on a BACKGROUND Win32 desktop
# (CreateDesktopW) so they stop stealing the user's foreground. The user's
# complaint, verbatim (2026-07-30): "you KEEP STEALING FOCUS USE ANOTHER
# DESKTOP for testing".
#
# Dot-source it:
#
#     . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
#     $td   = New-TestDesktop
#     $app  = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
#     $top  = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
#     $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
#     Send-TestKeys -Window $top -Target $pane -Modifiers ctrl,shift -Key T
#     Remove-TestDesktop
#
# A background desktop is NOT the input desktop, and that costs two of the
# mechanisms every existing script is built on. The T207 spike
# (test-desktop-spike.ps1) measured all of this on box; this file is where
# the replacements live so no script has to re-derive them:
#
#   SendInput            BLOCKED there (0 accepted, ACCESS_DENIED). Replaced by
#                        posted WM_KEYDOWN/WM_KEYUP with modifier state set via
#                        SetKeyboardState over an AttachThreadInput-shared input
#                        queue. Chords included.
#   SetForegroundWindow  Fails, and GetForegroundWindow returns 0 - a background
#                        desktop has no foreground window at all. Replaced by
#                        AttachThreadInput + SetActiveWindow + SetFocus, which is
#                        what the T86 GrabForeground helper becomes here.
#   CopyFromScreen       Dead (DWM composes only the input desktop; BitBlt off
#   / BitBlt             the desktop DC returns false). Replaced by
#                        PrintWindow(PW_RENDERFULLCONTENT) - see the limit
#                        below, which is narrower than the spike concluded.
#
# CAPTURE LIMIT (measured here 2026-07-30, and it REVISES T207's answer):
# PrintWindow on a background desktop returns the window's GDI-painted CHROME
# only - titlebar, tab strip, menus, dialog controls, banners. The OpenGL
# TERMINAL surface comes back as a flat fill: PrintWindow on a GhozttyTerminal
# child measured meanLum 255 / 1 distinct color, unchanged after typing, and a
# `--background=000000` window read the same 255 as a `--background=ffffff`
# one. The spike's "PrintWindow returns real content (64 distinct colors)"
# was reading the tab strip it had enabled, not the terminal. So: probes of
# native chrome migrate; probes of rendered terminal content cannot, and must
# not be "migrated" into an assertion that passes against a blank fill.
#
# THE ROUTE for a terminal-content probe (T214, decided 2026-08-01). In order,
# and the first one that applies wins:
#
#   1. ASK WHICH THREAD PAINTED THE PIXELS, not which technology produced
#      them. GL content that the app itself moves onto the GDI side is
#      capturable: the hero carousel's thumbnails are renderer output, but the
#      renderer thread snapshots them into a DIB (Surface.heroSnap*) and the
#      GUI thread blits them into the PARENT's DC inside BeginPaint, so
#      PrintWindow sees them (101 distinct colors, measured). Probe the window
#      that PAINTED, not the surface that RENDERED.
#   2. FIND ANOTHER NATIVE PAINTER OF THE SAME VALUE. window-color's pane
#      centre tint probe became the banner band, a different consumer of the
#      same effective background (Surface.refreshBannerColors). Label what the
#      substitute does NOT cover - there, the glass itself.
#   3. DROP THE ASSERTION, in place, with the measured reason in the script
#      header. Never weaken it into something a flat fill can pass. hero-mode's
#      two Get-PaneColorCount probes went this way.
#   4. INTERACTIVE BY DESIGN - keep it on the input desktop and declare it
#      below. Only for a script whose whole oracle is terminal content.
#
# Route 0 - an app-side GL readback exposed over IPC - is NOT built, and the
# reason is that the app already has half of it: heroSnap proves the renderer
# can hand a DIB to the GUI thread. If routes 1-4 ever stop being enough,
# generalise heroSnap rather than inventing a second capture path (T275).
#
# TERMINAL-CONTENT PROBES THAT STAY ON THE INPUT DESKTOP (declared, not
# missed - an undeclared exception is indistinguishable from an oversight):
#
#   color-contrast.ps1   (T150) The whole script reads back colors the
#                        RENDERER chose - derived foreground, regenerated
#                        palette, draw-time contrast floor. None of it exists
#                        anywhere but in GL pixels. Screen-DC GetPixel.
#   profile-latency.ps1  (T53b) One assertion: the scroll-viewport pixel hash.
#                        The script is interactive anyway (SendInput timing IS
#                        the measurement) - see T272.
#
# The guard that keeps this from regrowing is in Get-TestWindowPixels: it
# REFUSES a GhozttyTerminal capture unless -AllowTerminalSurface is passed,
# so a new probe cannot silently score itself against a flat fill.
# terminal-capture-guard.ps1 is the measured proof that the fill is real.
#
# MECHANISM LIMIT - VK_PACKET (measured here 2026-07-31, T217 batch 4):
# SendInput(KEYEVENTF_UNICODE) is how screen readers, on-screen keyboards and
# automation inject text; the app sees it as a WM_KEYDOWN with wParam
# VK_PACKET that TranslateMessage turns into a WM_CHAR. That cannot be
# reproduced by posting, and the obvious trick does NOT work: a posted
# WM_KEYDOWN(VK_PACKET, char in the lParam HIWORD) is never translated -
# measured on box, the character simply never arrives (the real packet
# carries its 16-bit character out of band, not in the 8-bit scan-code field
# of a posted lParam). A posted WM_CHAR to the same surface DOES arrive.
# So Send-TestInjectedChar posts WM_CHAR, which covers the app's injected-text
# handling (App.zig's WM_CHAR handler names direct posts as one of its two
# sources) but NOT App.run's TranslateMessage exemption for VK_PACKET. Do not
# label a WM_CHAR assertion as covering the packet path.
#
# Everything that touches the test desktop runs on ONE persistent worker
# thread: SetThreadDesktop is per-thread, and it fails outright on a thread
# that already owns windows or hooks - which the PowerShell host thread does.
# So window enumeration, focus, input and capture are all marshalled onto that
# thread; the functions below hide the marshalling.
#
# ESCAPE HATCH: `New-TestDesktop -Interactive` (or GHOZTTY_TEST_INTERACTIVE=1)
# skips the desktop entirely and drives the app on the interactive desktop the
# old way (GrabForeground + SendInput), because nobody can watch a window on a
# desktop they cannot see. It is for debugging by hand only - it steals focus,
# so it is never how an acceptance run is scored.

# T118: never inherit an IPC endpoint. A script started from one of the user's
# own panes inherits $GHOZTTY_IPC_SOCKET naming the USER'S app, and the CLI
# prefers a baked endpoint over the derivation - so leaving it set would aim
# the run at their terminal instead of the build under test. Same drop as
# CleanSlate.ps1, repeated here because not every GUI script sources both.
Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

if (-not ('GhozttyTestDesktop' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public class GhozttyTestDesktop {
    // ---------------- desktop / process ----------------
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa,
        uint disposition, uint flags, IntPtr template);

    // ---------------- windows ----------------
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    // Class style, cross-process. Used to decide whether a target would really
    // receive WM_*BUTTONDBLCLK (see the doubleclick branch in MouseEvent).
    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")] static extern UIntPtr GetClassLongPtr64(IntPtr h, int index);
    [DllImport("user32.dll", EntryPoint = "GetClassLongW")] static extern uint GetClassLong32(IntPtr h, int index);
    const int GCL_STYLE = -26;
    const uint CS_DBLCLKS = 0x0008;
    static bool WantsDblClk(IntPtr h) {
        uint style = (IntPtr.Size == 8)
            ? (uint)GetClassLongPtr64(h, GCL_STYLE).ToUInt64()
            : GetClassLong32(h, GCL_STYLE);
        return (style & CS_DBLCLKS) != 0;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetFocus();
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    const uint GW_OWNER = 4;
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] static extern int GetWindowLongW(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint p, out RECT r, uint winini);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    // SendMessage, never plain: a SYNCHRONOUS cross-process send into a wedged
    // app would block the ONE worker thread the whole harness marshals through,
    // and every later call with it. The timeout form degrades to a failed call.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out IntPtr result);

    // ---------------- gdi ----------------
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public uint length, flags, showCmd;
        public int ptMinX, ptMinY, ptMaxX, ptMaxY;
        public RECT rcNormal;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public uint cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    delegate bool EnumProc(IntPtr h, IntPtr l);

    const uint WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_CHAR = 0x0102;
    const ushort VK_PACKET = 0xE7;
    const uint WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    const uint WM_MOUSEMOVE = 0x0200;
    const uint WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, WM_LBUTTONDBLCLK = 0x0203;
    const uint WM_RBUTTONDOWN = 0x0204, WM_RBUTTONUP = 0x0205;
    const uint WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208;
    const uint WM_MOUSEWHEEL = 0x020A;
    const uint MK_LBUTTON = 0x0001, MK_RBUTTON = 0x0002, MK_SHIFT = 0x0004;
    const uint MK_CONTROL = 0x0008, MK_MBUTTON = 0x0010;
    const uint PW_RENDERFULLCONTENT = 2;

    // ================= worker thread =================
    // SetThreadDesktop is per-thread and fails on a thread that owns windows
    // or hooks (the PowerShell host thread does), so ONE long-lived thread is
    // bound to the desktop and every desktop-side call is marshalled onto it.
    class WorkItem {
        public Func<object> fn;
        public object result;
        public Exception error;
        public ManualResetEvent done = new ManualResetEvent(false);
    }

    IntPtr hDesk = IntPtr.Zero;
    Thread worker;
    readonly object gate = new object();
    readonly Queue<WorkItem> queue = new Queue<WorkItem>();
    volatile bool stopping = false;

    public string Name = "";
    public bool Interactive = false;
    public bool Ready = false;
    public string SetupError = "";
    public string LastError = "";

    public static GhozttyTestDesktop Create(string name, bool interactive) {
        var td = new GhozttyTestDesktop();
        td.Name = name;
        td.Interactive = interactive;
        var ready = new ManualResetEvent(false);
        td.worker = new Thread(delegate() { td.WorkerLoop(ready); });
        td.worker.IsBackground = true;
        td.worker.SetApartmentState(ApartmentState.STA);
        td.worker.Start();
        ready.WaitOne(15000);
        return td;
    }

    void WorkerLoop(ManualResetEvent ready) {
        try {
            // Per-monitor-v2 first (what the pre-migration probes used, and
            // the only awareness under which another process's window rect is
            // never virtualized); SetProcessDPIAware is the pre-1703 fallback.
            // Both are no-ops once awareness is set, so calling twice is safe.
            if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware();
            if (Interactive) {
                Ready = true;
            } else {
                // GENERIC_ALL on a desktop we own; the desktop object lives
                // until the last handle closes AND its last window dies.
                hDesk = CreateDesktopW(Name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
                if (hDesk == IntPtr.Zero) {
                    SetupError = "CreateDesktopW failed: " + Marshal.GetLastWin32Error();
                } else if (!SetThreadDesktop(hDesk)) {
                    SetupError = "SetThreadDesktop failed: " + Marshal.GetLastWin32Error();
                } else {
                    Ready = true;
                }
            }
        } catch (Exception e) {
            SetupError = "worker init: " + e.Message;
        }
        ready.Set();

        while (true) {
            WorkItem w = null;
            lock (gate) {
                while (queue.Count == 0 && !stopping) Monitor.Wait(gate);
                if (queue.Count == 0 && stopping) break;
                w = queue.Dequeue();
            }
            try { w.result = w.fn(); } catch (Exception e) { w.error = e; }
            w.done.Set();
        }
        if (hDesk != IntPtr.Zero) { CloseDesktop(hDesk); hDesk = IntPtr.Zero; }
    }

    object Run(Func<object> fn) {
        if (!Ready) throw new InvalidOperationException("test desktop not ready: " + SetupError);
        var w = new WorkItem();
        w.fn = fn;
        lock (gate) { queue.Enqueue(w); Monitor.Pulse(gate); }
        if (!w.done.WaitOne(120000)) throw new TimeoutException("test-desktop worker did not answer in 120s");
        if (w.error != null) throw w.error;
        return w.result;
    }

    public void Dispose() {
        lock (gate) { stopping = true; Monitor.PulseAll(gate); }
        if (worker != null) worker.Join(5000);
    }

    // ================= process =================
    // lpDesktop puts the child on the test desktop; without it the child would
    // launch onto the interactive one and defeat the whole exercise.
    public int StartProcess(string exe, string args, string cwd, string stderrPath) {
        return (int)Run(delegate() {
            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            if (!Interactive) si.lpDesktop = "WinSta0\\" + Name;

            IntPtr hErr = IntPtr.Zero, hNul = IntPtr.Zero;
            bool inherit = false;
            uint flags = 0x08000000; // CREATE_NO_WINDOW: without it the child's
                                     // log floods the harness's own stdout.
            if (!string.IsNullOrEmpty(stderrPath)) {
                var sa = new SECURITY_ATTRIBUTES();
                sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
                sa.bInheritHandle = 1;
                // GENERIC_WRITE, share read+write, CREATE_ALWAYS, normal.
                hErr = CreateFileW(stderrPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
                hNul = CreateFileW("NUL", 0x80000000, 3, ref sa, 3, 0x80, IntPtr.Zero);
                if (hErr != IntPtr.Zero && hErr != new IntPtr(-1)) {
                    si.dwFlags |= 0x00000100; // STARTF_USESTDHANDLES
                    si.hStdError = hErr;
                    si.hStdOutput = hErr;
                    si.hStdInput = hNul;
                    inherit = true;
                }
            }

            PROCESS_INFORMATION pi;
            var cmd = new StringBuilder("\"" + exe + "\" " + (args == null ? "" : args));
            bool ok = CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, inherit, flags,
                IntPtr.Zero, string.IsNullOrEmpty(cwd) ? null : cwd, ref si, out pi);
            int err = Marshal.GetLastWin32Error();
            if (hErr != IntPtr.Zero && hErr != new IntPtr(-1)) CloseHandle(hErr);
            if (hNul != IntPtr.Zero && hNul != new IntPtr(-1)) CloseHandle(hNul);
            if (!ok) { LastError = "CreateProcessW failed: " + err; return 0; }
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return pi.dwProcessId;
        });
    }

    // ================= window discovery =================
    // PowerShell's .NET method binder converts $null to "" for a string
    // parameter, so a "no filter" argument arrives here as an empty string -
    // and win32 reads "" as "match a window whose class/text IS empty", which
    // silently matches nothing. Every filter is normalised through this.
    static string NoFilter(string s) { return string.IsNullOrEmpty(s) ? null : s; }

    static IntPtr FindTopImpl(uint pid, string cls, bool requireVisible, IntPtr exclude) {
        cls = NoFilter(cls);
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || h == exclude) return true;
            if (requireVisible && !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(128);
            GetClassNameW(h, sb, 128);
            if (cls == null || sb.ToString() == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public IntPtr FindTop(int pid, string cls, bool requireVisible, IntPtr exclude) {
        return (IntPtr)Run(delegate() { return FindTopImpl((uint)pid, cls, requireVisible, exclude); });
    }

    // Waits for a top-level window of `cls` owned by `pid`, polling on the
    // worker thread so the whole wait costs one marshal.
    public IntPtr WaitTop(int pid, string cls, bool requireVisible, int timeoutMs) {
        return (IntPtr)Run(delegate() {
            int waited = 0;
            while (waited < timeoutMs) {
                IntPtr h = FindTopImpl((uint)pid, cls, requireVisible, IntPtr.Zero);
                if (h != IntPtr.Zero) return h;
                Thread.Sleep(100);
                waited += 100;
            }
            return IntPtr.Zero;
        });
    }

    // "hwnd:visible:left,top,right,bottom:class" per child of `cls` (visible or
    // not). A null `cls` returns every child, which is how a migration finds
    // out what a dialog is actually made of.
    public string[] Children(IntPtr top, string clsArg) {
        string cls = NoFilter(clsArg);
        return (string[])Run(delegate() {
            var lines = new List<string>();
            EnumChildWindows(top, delegate(IntPtr h, IntPtr l) {
                var sb = new StringBuilder(128);
                GetClassNameW(h, sb, 128);
                if (cls == null || sb.ToString() == cls) {
                    RECT r; GetWindowRect(h, out r);
                    lines.Add(h.ToInt64() + ":" + (IsWindowVisible(h) ? 1 : 0) + ":" +
                              r.left + "," + r.top + "," + r.right + "," + r.bottom + ":" +
                              sb.ToString());
                }
                return true;
            }, IntPtr.Zero);
            return lines.ToArray();
        });
    }

    // Every top-level window of `pid` matching `cls`, in the same line format
    // as Children. FindTop answers "the window"; this answers "how many, and
    // where" - which is what a test asserting that a popup class is GONE, or
    // that there is exactly one of them, actually needs.
    public string[] Tops(int pid, string clsArg, bool requireVisible) {
        string cls = NoFilter(clsArg);
        return (string[])Run(delegate() {
            var lines = new List<string>();
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                uint p; GetWindowThreadProcessId(h, out p);
                if (p != (uint)pid) return true;
                bool vis = IsWindowVisible(h);
                if (requireVisible && !vis) return true;
                var sb = new StringBuilder(128);
                GetClassNameW(h, sb, 128);
                if (cls == null || sb.ToString() == cls) {
                    RECT r; GetWindowRect(h, out r);
                    lines.Add(h.ToInt64() + ":" + (vis ? 1 : 0) + ":" +
                              r.left + "," + r.top + "," + r.right + "," + r.bottom + ":" +
                              sb.ToString());
                }
                return true;
            }, IntPtr.Zero);
            return lines.ToArray();
        });
    }

    public IntPtr FirstChild(IntPtr top, string clsArg, bool requireVisible) {
        string cls = NoFilter(clsArg);
        return (IntPtr)Run(delegate() {
            IntPtr found = IntPtr.Zero;
            EnumChildWindows(top, delegate(IntPtr h, IntPtr l) {
                if (requireVisible && !IsWindowVisible(h)) return true;
                var sb = new StringBuilder(128);
                GetClassNameW(h, sb, 128);
                if (cls == null || sb.ToString() == cls) { found = h; return false; }
                return true;
            }, IntPtr.Zero);
            return found;
        });
    }

    public IntPtr FindWindowEx(IntPtr parent, string clsArg, string titleArg) {
        string cls = NoFilter(clsArg);
        string title = NoFilter(titleArg);
        return (IntPtr)Run(delegate() { return FindWindowExW(parent, IntPtr.Zero, cls, title); });
    }

    public bool IsVisible(IntPtr h) { return (bool)Run(delegate() { return IsWindowVisible(h); }); }
    public bool Exists(IntPtr h) { return (bool)Run(delegate() { return IsWindow(h); }); }
    // Modality's observable side: an owner window is DISABLED for as long as
    // its modal dialog is up, and re-enabled when the dialog closes.
    public bool Enabled(IntPtr h) { return (bool)Run(delegate() { return IsWindowEnabled(h); }); }

    public int[] Rect(IntPtr h) {
        return (int[])Run(delegate() {
            RECT r;
            if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 };
            return new int[] { r.left, r.top, r.right, r.bottom };
        });
    }

    // Client rect in SCREEN coordinates - what the pixel probes measure.
    public int[] ClientRect(IntPtr h) {
        return (int[])Run(delegate() {
            RECT c;
            if (!GetClientRect(h, out c)) return new int[] { 0, 0, 0, 0 };
            var p = new POINT(); p.x = 0; p.y = 0;
            ClientToScreen(h, ref p);
            return new int[] { p.x, p.y, p.x + (c.right - c.left), p.y + (c.bottom - c.top) };
        });
    }

    // Maximized state - the oracle several size tests use as their positive
    // control (toggle_maximize is observable without reading any pixels).
    public bool Zoomed(IntPtr h) { return (bool)Run(delegate() { return IsZoomed(h); }); }

    // Resize the WINDOW rect, keeping position and z-order. Marshalled like
    // everything else: a window on another desktop is not this thread's to
    // poke at directly.
    public bool SetSize(IntPtr h, int w, int ht) {
        return (bool)Run(delegate() {
            return SetWindowPos(h, IntPtr.Zero, 0, 0, w, ht, 0x0004 | 0x0002); // NOZORDER|NOMOVE
        });
    }

    // Move (and optionally resize) the window, z-order unchanged. The MOVE is
    // the point: a test that only ever resizes never exercises the WM_MOVE
    // path, and overlay popups glued to a pane are re-placed from it.
    public bool SetPos(IntPtr h, int x, int y, int w, int ht, bool resize) {
        return (bool)Run(delegate() {
            uint flags = 0x0004; // NOZORDER
            if (!resize) flags |= 0x0001; // NOSIZE
            return SetWindowPos(h, IntPtr.Zero, x, y, w, ht, flags);
        });
    }

    // The layered-window alpha, which on a background desktop is the ONLY way
    // left to ask "is this popup opaque?": there is no screen composite to
    // compare a painted pixel against (see the CAPTURE LIMIT header). Returns
    // { ok, alpha, flags, colorkey }; flags bit 0 is LWA_COLORKEY, bit 1 is
    // LWA_ALPHA, so fully opaque with nothing keyed out is alpha 255 / flags 2.
    public int[] LayeredAttrs(IntPtr h) {
        return (int[])Run(delegate() {
            uint key, flags; byte alpha;
            if (!GetLayeredWindowAttributes(h, out key, out alpha, out flags)) {
                LastError = "GetLayeredWindowAttributes failed: " + Marshal.GetLastWin32Error();
                return new int[] { 0, 0, 0, 0 };
            }
            return new int[] { 1, alpha, (int)flags, (int)key };
        });
    }

    // The RESTORED size, readable while the window is maximized - what a
    // placement-memory test needs, since GetWindowRect on a maximized window
    // reports the monitor, not the size that will be remembered.
    public int[] NormalRect(IntPtr h) {
        return (int[])Run(delegate() {
            var p = new WINDOWPLACEMENT();
            p.length = (uint)Marshal.SizeOf(typeof(WINDOWPLACEMENT));
            if (!GetWindowPlacement(h, ref p)) return new int[] { 0, 0, 0, 0 };
            return new int[] { p.rcNormal.left, p.rcNormal.top, p.rcNormal.right, p.rcNormal.bottom };
        });
    }

    // The work area OF THE TEST DESKTOP. It is not the interactive desktop's:
    // a background desktop has no taskbar, so its work area is the whole
    // monitor. A clamp assertion measured on the host thread would compare the
    // app's answer against the wrong rectangle.
    public int[] WorkArea() {
        return (int[])Run(delegate() {
            RECT r;
            if (!SystemParametersInfoW(0x0030, 0, out r, 0)) return new int[] { 0, 0, 0, 0 }; // SPI_GETWORKAREA
            return new int[] { r.left, r.top, r.right, r.bottom };
        });
    }

    // Timed-out SendMessage; returns false if the app did not answer.
    bool Send(IntPtr h, uint msg, IntPtr wp, IntPtr lp, out IntPtr result) {
        // SMTO_ABORTIFHUNG | SMTO_NORMAL
        return SendMessageTimeoutW(h, msg, wp, lp, 0x0002, 10000, out result) != IntPtr.Zero;
    }

    // Simulate a USER drag-resize: the exact message sequence a mouse drag
    // produces around the size change. Product code that persists a size reads
    // GetWindowRect at WM_EXITSIZEMOVE, so a bare SetWindowPos (SetSize) is a
    // PROGRAMMATIC resize and deliberately does not look like this one.
    public bool DragResize(IntPtr h, int dw, int dh) {
        return (bool)Run(delegate() {
            IntPtr res;
            Send(h, 0x0231, IntPtr.Zero, IntPtr.Zero, out res); // WM_ENTERSIZEMOVE
            RECT r;
            if (!GetWindowRect(h, out r)) return false;
            SetWindowPos(h, IntPtr.Zero, 0, 0, (r.right - r.left) + dw, (r.bottom - r.top) + dh, 0x0004 | 0x0002);
            Thread.Sleep(100);
            return Send(h, 0x0232, IntPtr.Zero, IntPtr.Zero, out res); // WM_EXITSIZEMOVE
        });
    }

    // WM_SYSCOMMAND - the real maximize/restore path (SC_MAXIMIZE 0xF030,
    // SC_RESTORE 0xF120), as opposed to ShowWindow, which skips it.
    public bool SysCommand(IntPtr h, int cmd) {
        return (bool)Run(delegate() {
            IntPtr res;
            return Send(h, 0x0112, (IntPtr)cmd, IntPtr.Zero, out res);
        });
    }

    // Read a control's text with WM_GETTEXT. NOT GetWindowTextW: across a
    // process boundary that returns a cached copy the app never refreshes, so
    // an EDIT the user has typed into reads back stale (or empty).
    public string ControlText(IntPtr h) {
        return (string)Run(delegate() {
            IntPtr buf = Marshal.AllocHGlobal(2048);
            try {
                Marshal.WriteInt16(buf, 0);
                IntPtr res;
                if (!Send(h, 0x000D, (IntPtr)1024, buf, out res)) return ""; // WM_GETTEXT
                return Marshal.PtrToStringUni(buf);
            } finally { Marshal.FreeHGlobal(buf); }
        });
    }

    // Set a control's text with WM_SETTEXT. The way to put an EXACT string in
    // an EDIT that is already prefilled - typing appends, and select-all needs
    // a modifier chord, which does not reach a standard control (see
    // SendControlKey).
    public bool SetControlText(IntPtr h, string text) {
        return (bool)Run(delegate() {
            IntPtr buf = Marshal.StringToHGlobalUni(text == null ? "" : text);
            try {
                IntPtr res;
                return Send(h, 0x000C, IntPtr.Zero, buf, out res); // WM_SETTEXT
            } finally { Marshal.FreeHGlobal(buf); }
        });
    }

    // Send an arbitrary message and hand back its RESULT - for the standard
    // controls' getters (LB_GETCOUNT, LB_GETITEMHEIGHT, CB_*, EM_*), whose
    // whole point is the return value. Sent through the timeout-guarded Send,
    // so a wedged app fails the call instead of blocking the worker thread;
    // long.MinValue means the send itself failed, which no getter returns.
    public long MessageResult(IntPtr h, uint msg, IntPtr wp, IntPtr lp) {
        return (long)Run(delegate() {
            IntPtr res;
            if (!Send(h, msg, wp, lp, out res)) return long.MinValue;
            return (long)res;
        });
    }

    // GetWindowLongW, for the style bits a test asserts directly (an
    // owner-drawn listbox is LBS_OWNERDRAWFIXED without LBS_HASSTRINGS, and
    // that IS the claim - there is no pixel that says it).
    public long WindowLong(IntPtr h, int index) {
        return (long)Run(delegate() { return (long)GetWindowLongW(h, index); });
    }

    // Per-monitor DPI of a window. Any geometry a script hard-codes in DIP
    // (grab bands, divider widths) has to be scaled by this before it can be
    // compared against a pixel measurement.
    public uint Dpi(IntPtr h) {
        return (uint)Run(delegate() { return GetDpiForWindow(h); });
    }

    public string WindowText(IntPtr h) {
        return (string)Run(delegate() {
            var sb = new StringBuilder(512);
            GetWindowTextW(h, sb, 512);
            return sb.ToString();
        });
    }

    public string ClassName(IntPtr h) {
        return (string)Run(delegate() {
            var sb = new StringBuilder(128);
            GetClassNameW(h, sb, 128);
            return sb.ToString();
        });
    }

    // The registered CLASS style (GCL_STYLE), not the per-window style that
    // WindowLong returns. CS_HREDRAW/CS_VREDRAW live here, and they decide
    // what a resize invalidates - which is a product decision a script can
    // read back off the live window (T456).
    public long ClassStyle(IntPtr h) {
        return (long)Run(delegate() {
            return (long)((IntPtr.Size == 8)
                ? (uint)GetClassLongPtr64(h, GCL_STYLE).ToUInt64()
                : GetClassLong32(h, GCL_STYLE));
        });
    }

    // The focused HWND of `top`'s GUI thread. No attach needed, so it is safe
    // to poll (the T48 deferred-SetFocus path makes focus asynchronous).
    public long FocusedHwnd(IntPtr top) {
        return (long)Run(delegate() {
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            var info = new GUITHREADINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
            if (!GetGUIThreadInfo(tid, ref info)) return 0L;
            return info.hwndFocus.ToInt64();
        });
    }

    // The ACTIVE HWND of `top`'s GUI thread. On a background desktop
    // GetForegroundWindow returns 0 for every window, so this is the stand-in
    // an activation claim is expressed against - see the ACTIVATION note in
    // the header (T224). Same GetGUIThreadInfo read as FocusedHwnd, so it is
    // equally safe to poll.
    public long ActiveHwnd(IntPtr top) {
        return (long)Run(delegate() {
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            var info = new GUITHREADINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
            if (!GetGUIThreadInfo(tid, ref info)) return 0L;
            return info.hwndActive.ToInt64();
        });
    }

    // ================= z-order =================
    // EnumWindows walks the CALLING THREAD's desktop top-down, so every
    // z-order read is marshalled like everything else: run on the host thread
    // it would enumerate the user's desktop and find none of these windows.

    // Index of `target` among the VISIBLE top-level windows, top first; -1
    // when it is not in the enumeration (hidden, or another desktop).
    public int ZIndex(IntPtr target) {
        return (int)Run(delegate() {
            int idx = -1, i = 0;
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                if (h == target) { idx = i; return false; }
                i++;
                return true;
            }, IntPtr.Zero);
            return idx;
        });
    }

    // GetWindow(GW_OWNER) - the popup's owner, which is what pins it above one
    // particular window and says nothing about the rest of the band.
    public long Owner(IntPtr h) {
        return (long)Run(delegate() { return GetWindow(h, GW_OWNER).ToInt64(); });
    }

    // The invariant an owned overlay must hold: it sits ABOVE its owner with
    // nothing FOREIGN sandwiched between the two. Anything else means the
    // overlay floats over a window that is in front of its own.
    // Returns "<count>:<classes>", "-1:missing" or "-2:below-owner".
    //
    // Expressed from ownership data rather than by re-walking the way the
    // product does: this is the specification, not a mirror of the
    // implementation. Other popups owned by the same window (a sibling pane's
    // overlay) are allowed in between - they belong to the same window.
    public string Sandwich(IntPtr overlay, IntPtr owner) {
        return (string)Run(delegate() {
            var list = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                if (IsWindowVisible(h)) list.Add(h);
                return true;
            }, IntPtr.Zero);
            int io = list.IndexOf(overlay), iw = list.IndexOf(owner);
            if (io < 0 || iw < 0) return "-1:missing";
            if (io > iw) return "-2:below-owner";
            int n = 0;
            var names = new List<string>();
            for (int i = io + 1; i < iw; i++) {
                if (GetWindow(list[i], GW_OWNER) == owner) continue;
                n++;
                var sb = new StringBuilder(64);
                GetClassNameW(list[i], sb, 64);
                names.Add(sb.ToString());
            }
            return n + ":" + string.Join(",", names.ToArray());
        });
    }

    // Inject (or clear) WS_EX_TOPMOST exactly the way a stray verification
    // probe does - HWND_TOPMOST / HWND_NOTOPMOST, nothing else touched.
    public bool SetTopmost(IntPtr h, bool on) {
        return (bool)Run(delegate() {
            return SetWindowPos(h, (IntPtr)(on ? -1 : -2), 0, 0, 0, 0, 0x0013); // NOSIZE|NOMOVE|NOACTIVATE
        });
    }

    // Hide, or re-show with SWP_SHOWWINDOW and no z-order request. This is the
    // probe for "does the window manager still lift a freshly shown popup to
    // the top of its band when no window holds the foreground?" (T224).
    public bool SetShown(IntPtr h, bool show) {
        return (bool)Run(delegate() {
            uint flags = 0x0001 | 0x0002 | 0x0004 | 0x0010; // NOSIZE|NOMOVE|NOZORDER|NOACTIVATE
            flags |= show ? 0x0040u : 0x0080u;              // SHOWWINDOW : HIDEWINDOW
            return SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, flags);
        });
    }

    // Who is visibly on top at a SCREEN point: "<hwnd>:<rootHwnd>:<class>".
    // WindowFromPoint respects the z-order and sees WS_EX_LAYERED popups, so
    // it answers "is the overlay what you would see here?" without any pixels
    // - which matters doubly on a desktop DWM never composites.
    public string TopAt(int x, int y) {
        return (string)Run(delegate() {
            POINT p; p.x = x; p.y = y;
            IntPtr h = WindowFromPoint(p);
            if (h == IntPtr.Zero) return "0:0:(none)";
            IntPtr root = GetAncestor(h, 2); // GA_ROOT
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            return (long)h + ":" + (long)root + ":" + sb.ToString();
        });
    }

    // ================= focus =================
    // Replaces the T86 GrabForeground that 30 scripts each copied. On a
    // background desktop there IS no foreground window, so focus is taken by
    // sharing the app's input queue and setting the queue's focus directly.
    // In -Interactive mode the old foreground grab is used instead, since a
    // window nobody can see defeats the point of that mode.
    public bool FocusWindow(IntPtr top, IntPtr child) {
        return (bool)Run(delegate() {
            if (Interactive) GrabForegroundImpl(top);
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            uint cur = GetCurrentThreadId();
            if (!AttachThreadInput(cur, tid, true)) { LastError = "AttachThreadInput failed"; return false; }
            try {
                SetActiveWindow(top);
                SetFocus(child == IntPtr.Zero ? top : child);
                Thread.Sleep(80);
                IntPtr want = (child == IntPtr.Zero) ? top : child;
                return GetFocus() == want;
            } finally { AttachThreadInput(cur, tid, false); }
        });
    }

    // Interactive-only: the T86-hardened grab, already-foreground guard
    // included (an unguarded Alt tap self-latches menu mode).
    static bool GrabForegroundImpl(IntPtr top) {
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            SendInputKey(0x12, false); SendInputKey(0x12, true); // Alt tap
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    static void SendInputKey(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.wScan = (ushort)MapVirtualKeyW(vk, 0);
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // KEYEVENTF_UNICODE: what a screen reader / on-screen keyboard / automation
    // tool actually injects. Interactive mode only - see SendInjectedChar.
    static void SendInputUnicode(char c, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = 0;
        i[0].ki.wScan = (ushort)c;
        i[0].ki.dwFlags = (up ? 2u : 0u) | 4u; // KEYEVENTF_UNICODE -> VK_PACKET
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // ================= input =================
    // Extended keys need bit 24 of lparam set, or the app reads them as their
    // numpad twins (Surface.handleKeyEvent reads it explicitly).
    static bool IsExtended(ushort vk) {
        switch (vk) {
            case 0x21: case 0x22: case 0x23: case 0x24: // PgUp PgDn End Home
            case 0x25: case 0x26: case 0x27: case 0x28: // arrows
            case 0x2D: case 0x2E:                       // Insert Delete
            case 0x2C:                                  // PrintScreen
            case 0x90:                                  // NumLock
            case 0x6F:                                  // Divide
            case 0xA3: case 0xA5:                       // RCtrl RAlt
                return true;
        }
        return false;
    }

    // The lparam a real WM_KEYDOWN carries: repeat count 1, the key's scancode
    // in bits 16-23 (ToUnicode needs it), extended flag in bit 24, and for the
    // up message the transition/previous-state bits. Posting 0 - what the T207
    // spike did - happens to work for plain letters and silently misroutes
    // extended keys.
    static IntPtr KeyLParam(ushort vk, bool up) {
        uint sc = MapVirtualKeyW(vk, 0) & 0xFF;
        uint lp = 1u | (sc << 16);
        if (IsExtended(vk)) lp |= (1u << 24);
        if (up) lp |= (1u << 30) | (1u << 31);
        return (IntPtr)(int)lp;
    }

    static void ApplyMods(byte[] ks, ushort[] mods, bool down) {
        byte v = down ? (byte)0x80 : (byte)0x00;
        foreach (ushort m in mods) {
            switch (m) {
                case 0x11: ks[0x11] = v; ks[0xA2] = v; break; // ctrl  + lctrl
                case 0x10: ks[0x10] = v; ks[0xA0] = v; break; // shift + lshift
                case 0x12: ks[0x12] = v; ks[0xA4] = v; break; // alt   + lalt
                case 0x5B: ks[0x5B] = v; break;               // lwin
                default: ks[m] = v; break;
            }
        }
    }

    static bool HasMod(ushort[] mods, ushort want) {
        foreach (ushort m in mods) if (m == want) return true;
        return false;
    }

    // Post a chord to `target`. Modifier state goes onto the input queue we
    // share with the app via AttachThreadInput - the app reads modifiers with
    // GetKeyState (queue state), not GetAsyncKeyState, so this is what it sees.
    // WM_CHAR is deliberately NOT posted: the terminal class skips
    // TranslateMessage (App.run) and calls ToUnicode itself, so posting both
    // doubles every character (the spike hit exactly that: "sSpPiIkKeEbB").
    public bool SendChord(IntPtr top, IntPtr target, ushort[] mods, ushort vk, int holdMs) {
        return (bool)Run(delegate() {
            if (Interactive) return SendChordInteractive(top, target, mods, vk, holdMs);
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            uint cur = GetCurrentThreadId();
            if (!AttachThreadInput(cur, tid, true)) { LastError = "AttachThreadInput failed"; return false; }
            try {
                SetActiveWindow(top);
                SetFocus(target == IntPtr.Zero ? top : target);
                Thread.Sleep(40);
                IntPtr dst = (target == IntPtr.Zero) ? top : target;

                var ks = new byte[256];
                GetKeyboardState(ks);
                ApplyMods(ks, mods, true);
                SetKeyboardState(ks);

                // Alt without Ctrl makes Windows send WM_SYSKEY*, and the app
                // routes those differently (App.zig 4042).
                bool sys = HasMod(mods, 0x12) && !HasMod(mods, 0x11);
                uint msgDown = sys ? WM_SYSKEYDOWN : WM_KEYDOWN;
                uint msgUp = sys ? WM_SYSKEYUP : WM_KEYUP;

                foreach (ushort m in mods) PostMessageW(dst, WM_KEYDOWN, (IntPtr)m, KeyLParam(m, false));
                PostMessageW(dst, msgDown, (IntPtr)vk, KeyLParam(vk, false));
                Thread.Sleep(holdMs);
                PostMessageW(dst, msgUp, (IntPtr)vk, KeyLParam(vk, true));
                for (int j = mods.Length - 1; j >= 0; j--)
                    PostMessageW(dst, WM_KEYUP, (IntPtr)mods[j], KeyLParam(mods[j], true));

                ApplyMods(ks, mods, false);
                SetKeyboardState(ks);
                Thread.Sleep(80);
                return true;
            } finally { AttachThreadInput(cur, tid, false); }
        });
    }

    // T394: a chord for a VIEWER pane. The keystrokes are posted to the
    // WebView2 (Chromium) child hwnd, which lives in ANOTHER PROCESS — but
    // the app's own UI thread is who answers the AcceleratorKeyPressed
    // callback and reads the modifiers back with GetKeyState. Attaching to
    // BOTH threads merges the input queues, so one SetKeyboardState is
    // visible to Chromium (which classifies the key as an accelerator) and
    // to the app (which resolves the binding). The modifier state is held
    // through a longer settle than SendChord's: the chord crosses two
    // process boundaries before anyone reads it.
    public bool SendChordCross(IntPtr appTop, IntPtr target, ushort[] mods, ushort vk, int holdMs) {
        return (bool)Run(delegate() {
            uint apid; uint appTid = GetWindowThreadProcessId(appTop, out apid);
            uint tpid; uint targetTid = GetWindowThreadProcessId(target, out tpid);
            uint cur = GetCurrentThreadId();
            if (!AttachThreadInput(cur, appTid, true)) { LastError = "AttachThreadInput(app) failed"; return false; }
            bool crossAttached = (targetTid != appTid) && AttachThreadInput(cur, targetTid, true);
            try {
                SetActiveWindow(appTop);
                SetFocus(target);
                Thread.Sleep(60);

                var ks = new byte[256];
                GetKeyboardState(ks);
                ApplyMods(ks, mods, true);
                SetKeyboardState(ks);

                bool sys = HasMod(mods, 0x12) && !HasMod(mods, 0x11);
                uint msgDown = sys ? WM_SYSKEYDOWN : WM_KEYDOWN;
                uint msgUp = sys ? WM_SYSKEYUP : WM_KEYUP;

                foreach (ushort m in mods) PostMessageW(target, WM_KEYDOWN, (IntPtr)m, KeyLParam(m, false));
                PostMessageW(target, msgDown, (IntPtr)vk, KeyLParam(vk, false));
                Thread.Sleep(holdMs);
                PostMessageW(target, msgUp, (IntPtr)vk, KeyLParam(vk, true));
                for (int j = mods.Length - 1; j >= 0; j--)
                    PostMessageW(target, WM_KEYUP, (IntPtr)mods[j], KeyLParam(mods[j], true));

                Thread.Sleep(400);
                ApplyMods(ks, mods, false);
                SetKeyboardState(ks);
                Thread.Sleep(80);
                return true;
            } finally {
                if (crossAttached) AttachThreadInput(cur, targetTid, false);
                AttachThreadInput(cur, appTid, false);
            }
        });
    }

    static bool SendChordInteractive(IntPtr top, IntPtr target, ushort[] mods, ushort vk, int holdMs) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForegroundImpl(top);
        if (!AttachThreadInput(cur, tid, true)) return false;
        try {
            SetFocus(target == IntPtr.Zero ? top : target);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return false;
            foreach (ushort m in mods) SendInputKey(m, false);
            Thread.Sleep(20);
            SendInputKey(vk, false); Thread.Sleep(holdMs); SendInputKey(vk, true);
            Thread.Sleep(20);
            for (int j = mods.Length - 1; j >= 0; j--) SendInputKey(mods[j], true);
            Thread.Sleep(100);
            return true;
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Type a literal string into a TERMINAL surface (WM_KEYDOWN only; the
    // terminal runs ToUnicode itself). Shift is applied for characters whose
    // VkKeyScan asks for it, so mixed case survives.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char c);

    public bool SendText(IntPtr top, IntPtr target, string text, int perKeyMs) {
        return (bool)Run(delegate() {
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            uint cur = GetCurrentThreadId();
            if (!AttachThreadInput(cur, tid, true)) { LastError = "AttachThreadInput failed"; return false; }
            try {
                SetActiveWindow(top);
                SetFocus(target == IntPtr.Zero ? top : target);
                Thread.Sleep(40);
                IntPtr dst = (target == IntPtr.Zero) ? top : target;
                var ks = new byte[256];
                foreach (char c in text) {
                    short scan = VkKeyScanW(c);
                    if (scan == -1) continue;
                    ushort vk = (ushort)(scan & 0xFF);
                    bool shift = (scan & 0x100) != 0;
                    if (Interactive) {
                        if (shift) SendInputKey(0x10, false);
                        SendInputKey(vk, false); SendInputKey(vk, true);
                        if (shift) SendInputKey(0x10, true);
                    } else {
                        GetKeyboardState(ks);
                        if (shift) { ks[0x10] = 0x80; ks[0xA0] = 0x80; SetKeyboardState(ks); }
                        PostMessageW(dst, WM_KEYDOWN, (IntPtr)vk, KeyLParam(vk, false));
                        PostMessageW(dst, WM_KEYUP, (IntPtr)vk, KeyLParam(vk, true));
                        if (shift) { ks[0x10] = 0; ks[0xA0] = 0; SetKeyboardState(ks); }
                    }
                    Thread.Sleep(perKeyMs);
                }
                Thread.Sleep(80);
                return true;
            } finally { AttachThreadInput(cur, tid, false); }
        });
    }

    // INJECTED text into a terminal surface: a WM_CHAR that did NOT come from
    // this surface's own WM_KEYDOWN. That is the shape screen readers,
    // on-screen keyboards and automation produce, and App.zig's WM_CHAR
    // handler names its two sources: VK_PACKET translation and direct
    // WM_CHAR posts. On the test desktop only the second is available, and
    // that is a MECHANISM LIMIT, not a preference - see the header.
    //
    // Interactive mode uses the real KEYEVENTF_UNICODE, so a run with
    // -Interactive covers the packet path as well.
    public bool SendInjectedChar(IntPtr top, IntPtr target, string text, int perKeyMs) {
        return (bool)Run(delegate() {
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            uint cur = GetCurrentThreadId();
            if (!AttachThreadInput(cur, tid, true)) { LastError = "AttachThreadInput failed"; return false; }
            try {
                SetActiveWindow(top);
                SetFocus(target == IntPtr.Zero ? top : target);
                Thread.Sleep(40);
                IntPtr dst = (target == IntPtr.Zero) ? top : target;
                foreach (char c in text) {
                    if (Interactive) {
                        SendInputUnicode(c, false);
                        SendInputUnicode(c, true);
                    } else {
                        PostMessageW(dst, WM_CHAR, (IntPtr)(int)c, (IntPtr)1);
                    }
                    Thread.Sleep(perKeyMs);
                }
                Thread.Sleep(80);
                return true;
            } finally { AttachThreadInput(cur, tid, false); }
        });
    }

    // Standard controls (EDIT, BUTTON, dialogs) are the OPPOSITE case: they
    // depend on TranslateMessage turning WM_KEYDOWN into WM_CHAR, and nothing
    // translates a posted message. So text goes in as WM_CHAR and only navigation
    // keys go in as WM_KEYDOWN/WM_KEYUP.
    public bool SendControlText(IntPtr ctl, string text, int perKeyMs) {
        return (bool)Run(delegate() {
            foreach (char c in text) {
                PostMessageW(ctl, WM_CHAR, (IntPtr)(int)c, (IntPtr)1);
                Thread.Sleep(perKeyMs);
            }
            Thread.Sleep(60);
            return true;
        });
    }

    // WM_CLOSE, posted. The polite way to dismiss a dialog or window we did
    // not open a keyboard path to (a posted Enter/Escape needs the dialog
    // manager's TranslateMessage, which nothing runs for a posted message).
    public bool CloseWindow(IntPtr h) {
        return (bool)Run(delegate() { return PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero); });
    }

    // BM_CLICK straight to a BUTTON control. Deliberately NOT a synthetic mouse
    // click: it keeps an assertion about what the button DOES independent of
    // whether a posted click landed on the right pixel, and it is unaffected by
    // the control's z-order or by anything overlapping it. SENT (through the
    // timeout-guarded Send, so a wedged app fails the call instead of blocking
    // the worker thread) rather than posted, so the handler has already run when
    // this returns - a posted BM_CLICK would race every assertion after it.
    public bool ControlClick(IntPtr h) {
        return (bool)Run(delegate() {
            IntPtr res;
            return Send(h, 0x00F5, IntPtr.Zero, IntPtr.Zero, out res); // BM_CLICK
        });
    }

    // Post an ARBITRARY message. For the app's own private WM_APP+n protocol
    // messages, which a test seeds directly to drive an internal code path
    // (e.g. WM_APP_SETFOCUS, whose co-pending pair is the T105 oracle). Posted,
    // never sent: these are handled at the top of the app's run loop, and a
    // synchronous send would block this worker thread on the app's GUI thread.
    public bool PostRaw(IntPtr h, uint msg, IntPtr wp, IntPtr lp) {
        return (bool)Run(delegate() { return PostMessageW(h, msg, wp, lp); });
    }

    public bool SendControlKey(IntPtr ctl, ushort vk, ushort[] mods) {
        return (bool)Run(delegate() {
            var ks = new byte[256];
            GetKeyboardState(ks);
            if (mods != null && mods.Length > 0) { ApplyMods(ks, mods, true); SetKeyboardState(ks); }
            PostMessageW(ctl, WM_KEYDOWN, (IntPtr)vk, KeyLParam(vk, false));
            Thread.Sleep(30);
            PostMessageW(ctl, WM_KEYUP, (IntPtr)vk, KeyLParam(vk, true));
            if (mods != null && mods.Length > 0) { ApplyMods(ks, mods, false); SetKeyboardState(ks); }
            Thread.Sleep(60);
            return true;
        });
    }

    // One HALF of a WM_SYSKEYDOWN/WM_SYSKEYUP pair - the messages F10 and
    // Alt-modified keys arrive as. Deliberately not a "tap": the menu
    // activation contract is a claim about the PAIRING (a lone Alt down-then-up
    // opens the menu; the same Alt with any key in between must not), so the
    // caller drives each half and decides what goes between them.
    //
    // up == false posts WM_SYSKEYDOWN, true posts WM_SYSKEYUP.
    public bool SysKey(IntPtr h, ushort vk, bool up) {
        return (bool)Run(delegate() {
            return PostMessageW(h, up ? WM_SYSKEYUP : WM_SYSKEYDOWN, (IntPtr)vk, KeyLParam(vk, up));
        });
    }

    // ================= mouse =================
    // SendInput is dead here (T207), so mouse input is POSTED too. Two things
    // make that survivable rather than a fiction:
    //
    //   * The app reads shift/ctrl for a click from the message's own MK_*
    //     wparam (Surface.handleMouseButton), not from GetKeyState, so a
    //     posted click carries its modifiers correctly.
    //   * The coordinates travel IN the message. A posted WM_MOUSEMOVE is the
    //     same evidence a hardware move is to any handler that reads its own
    //     lparam - which is how the focus-follows-mouse motion gate works
    //     (Surface.focusFollowsMouse compares ClientToScreen(lparam) against
    //     the last one), so hover behavior migrates honestly.
    //
    // What is NOT available is the CURSOR ITSELF. Measured T218 batch 3
    // (2026-07-31), correcting an earlier claim here: SetCursorPos returns
    // FALSE off the input desktop and GetCursorPos returns -1,-1. The
    // SetCursorPos call below is therefore best-effort and its result is
    // ignored; nothing may depend on it. Product code that decides from
    // GetCursorPos does not fire here at all - Window.zig's WM_SETCURSOR
    // (the split-divider resize cursor) measured as returning 0 at every
    // point on the grab band, because WM_SETCURSOR carries no coordinates and
    // its handler has nothing to read. Assert the decision underneath such a
    // handler (WM_NCHITTEST for the divider band), never the cursor.
    //
    // What is NOT reproduced: hit-testing. A posted message goes to the hwnd
    // you name, whatever is on top of it. That is a feature for tests (no
    // z-order flake) and a trap if you post to the parent expecting a child
    // to get it.
    static IntPtr PackPoint(int x, int y) {
        return (IntPtr)((int)(((uint)y << 16) | ((uint)x & 0xFFFF)));
    }

    static uint MouseMk(ushort[] mods, uint buttons) {
        uint mk = buttons;
        if (mods != null) {
            foreach (ushort m in mods) {
                if (m == 0x10) mk |= MK_SHIFT;
                if (m == 0x11) mk |= MK_CONTROL;
            }
        }
        return mk;
    }

    // button: 0 left, 1 right, 2 middle.
    // action: 0 move, 1 down, 2 up, 3 click, 4 double-click, 5 wheel.
    // x/y are SCREEN coordinates - the same math the pre-migration scripts
    // already do with GetWindowRect - and are converted per target hwnd.
    public bool MouseEvent(IntPtr top, IntPtr target, int sx, int sy,
                           int button, int action, int holdMs,
                           ushort[] mods, int wheelDelta) {
        return (bool)Run(delegate() {
            uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
            uint cur = GetCurrentThreadId();
            bool attached = AttachThreadInput(cur, tid, true);
            try {
                IntPtr dst = (target == IntPtr.Zero) ? top : target;
                var ks = new byte[256];
                bool haveMods = (mods != null && mods.Length > 0);
                if (haveMods) { GetKeyboardState(ks); ApplyMods(ks, mods, true); SetKeyboardState(ks); }

                SetCursorPos(sx, sy);

                var p = new POINT(); p.x = sx; p.y = sy;
                ScreenToClient(dst, ref p);
                IntPtr lp = PackPoint(p.x, p.y);

                uint down = WM_LBUTTONDOWN, up = WM_LBUTTONUP, dbl = WM_LBUTTONDBLCLK, held = MK_LBUTTON;
                if (button == 1) { down = WM_RBUTTONDOWN; up = WM_RBUTTONUP; dbl = WM_RBUTTONDOWN; held = MK_RBUTTON; }
                else if (button == 2) { down = WM_MBUTTONDOWN; up = WM_MBUTTONUP; dbl = WM_MBUTTONDOWN; held = MK_MBUTTON; }

                PostMessageW(dst, WM_MOUSEMOVE, (IntPtr)MouseMk(mods, 0), lp);
                Thread.Sleep(20);

                if (action == 0) {
                    // move only
                } else if (action == 5) {
                    // WM_MOUSEWHEEL's lparam is SCREEN coordinates, not client.
                    uint wp = (uint)((wheelDelta << 16) | (int)MouseMk(mods, 0));
                    PostMessageW(dst, WM_MOUSEWHEEL, (IntPtr)(int)wp, PackPoint(sx, sy));
                } else {
                    if (action == 1 || action == 3 || action == 4) {
                        PostMessageW(dst, down, (IntPtr)MouseMk(mods, held), lp);
                    }
                    if (action == 3 || action == 4) {
                        Thread.Sleep(holdMs);
                        PostMessageW(dst, up, (IntPtr)MouseMk(mods, 0), lp);
                    }
                    if (action == 4) {
                        // What the OS would really deliver depends on the
                        // TARGET's class: only a CS_DBLCLKS window ever sees
                        // WM_*BUTTONDBLCLK. Without that style Windows sends a
                        // plain second down/up pair, and a window that counts
                        // its own clicks (the terminal surface does - the
                        // GhozttyTerminal class is CS_OWNDC, not CS_DBLCLKS)
                        // would silently drop a posted DBLCLK and read the
                        // gesture as a single click. Posting the wrong one
                        // costs a word-select that never happens.
                        Thread.Sleep(30);
                        uint second = WantsDblClk(dst) ? dbl : down;
                        PostMessageW(dst, second, (IntPtr)MouseMk(mods, held), lp);
                        Thread.Sleep(holdMs);
                        PostMessageW(dst, up, (IntPtr)MouseMk(mods, 0), lp);
                    }
                    if (action == 2) {
                        PostMessageW(dst, up, (IntPtr)MouseMk(mods, 0), lp);
                    }
                }

                if (haveMods) { ApplyMods(ks, mods, false); SetKeyboardState(ks); }
                Thread.Sleep(40);
                return true;
            } finally { if (attached) AttachThreadInput(cur, tid, false); }
        });
    }

    // Unpaced posted down/up pairs, round-robin across targets. This is a
    // LOAD SHAPE, not a user gesture: the T48 deadlock repro needs thousands
    // of focus changes arriving faster than the GUI thread drains them, which
    // MouseEvent's per-click settling sleeps (~100ms) deliberately prevent.
    // Client coordinates, since every target is a different window.
    //
    // Returns the number of messages ACCEPTED (T107): PostMessageW fails when
    // the target thread's queue is full (the default cap is ~10000 posted
    // messages) or the window has died, and the whole point of this call is a
    // load shape - one that silently posted nothing would leave every
    // "under load" assertion downstream passing against no load at all.
    public int ClickStorm(IntPtr[] targets, int rounds, int cx, int cy) {
        return (int)Run(delegate() {
            IntPtr lp = PackPoint(cx, cy);
            int posted = 0;
            for (int r = 0; r < rounds; r++) {
                foreach (IntPtr t in targets) {
                    if (PostMessageW(t, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, lp)) posted++;
                    if (PostMessageW(t, WM_LBUTTONUP, IntPtr.Zero, lp)) posted++;
                }
            }
            return posted;
        });
    }

    // Does the window's GUI thread pump a WM_NULL within timeoutMs? The
    // hang oracle: SMTO_ABORTIFHUNG gives up early on a thread Windows has
    // already marked not-responding. This one call may block the worker for
    // up to timeoutMs by design - that wait IS the measurement.
    public bool Responsive(IntPtr h, uint timeoutMs) {
        return (bool)Run(delegate() {
            IntPtr res;
            // SMTO_ABORTIFHUNG | SMTO_BLOCK
            return SendMessageTimeoutW(h, 0x0000, IntPtr.Zero, IntPtr.Zero, 0x0002 | 0x0001, timeoutMs, out res) != IntPtr.Zero;
        });
    }

    // Cursor position on the TEST desktop (per-desktop state; the worker
    // thread is the one bound to it, so this must be marshalled).
    public bool MoveCursor(int x, int y) {
        return (bool)Run(delegate() { return SetCursorPos(x, y); });
    }

    public int[] CursorPos() {
        return (int[])Run(delegate() {
            POINT p;
            if (!GetCursorPos(out p)) return new int[] { -1, -1 };
            return new int[] { p.x, p.y };
        });
    }

    // ================= capture =================
    // PrintWindow(PW_RENDERFULLCONTENT) is the ONLY capture that works on a
    // background desktop: DWM composes the input desktop only, so BitBlt off
    // the desktop DC (== Graphics.CopyFromScreen) returns false there.
    // Returns { hbitmap, width, height, left, top }; hbitmap is handed to
    // Image.FromHbitmap on the caller's side and freed by ReleaseCapture.
    public long[] CaptureWindow(IntPtr h) {
        return (long[])Run(delegate() {
            RECT r;
            if (!GetWindowRect(h, out r)) { LastError = "GetWindowRect failed"; return new long[] { 0, 0, 0, 0, 0 }; }
            int w = r.right - r.left, ht = r.bottom - r.top;
            if (w <= 0 || ht <= 0) { LastError = "empty window rect"; return new long[] { 0, 0, 0, 0, 0 }; }
            IntPtr hdcWin = GetDC(h);
            IntPtr hdcMem = CreateCompatibleDC(hdcWin);
            IntPtr hbmp = CreateCompatibleBitmap(hdcWin, w, ht);
            IntPtr old = SelectObject(hdcMem, hbmp);
            bool ok = PrintWindow(h, hdcMem, PW_RENDERFULLCONTENT);
            SelectObject(hdcMem, old);
            DeleteDC(hdcMem);
            ReleaseDC(h, hdcWin);
            if (!ok) { DeleteObject(hbmp); LastError = "PrintWindow failed"; return new long[] { 0, 0, 0, 0, 0 }; }
            return new long[] { hbmp.ToInt64(), w, ht, r.left, r.top };
        });
    }

    public void ReleaseCapture(long hbmp) {
        if (hbmp != 0) DeleteObject(new IntPtr(hbmp));
    }

    // ================= interactive-desktop watcher =================
    // Threads created here inherit the PROCESS desktop (the interactive one) -
    // only the worker is ever rebound - so this samples exactly what the user
    // is looking at while a test runs. Every migrated script can then assert
    // the user's actual complaint: our app never became foreground for them.
    static volatile bool watchStop = false;
    static Thread watchThread = null;
    static string watchSeen = "";
    public static void StartForegroundWatch() {
        watchStop = false;
        watchSeen = "";
        var seen = new HashSet<uint>();
        watchThread = new Thread(delegate() {
            while (!watchStop) {
                uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
                lock (seen) { seen.Add(p); }
                Thread.Sleep(150);
            }
            var sb = new StringBuilder();
            lock (seen) { foreach (uint p in seen) sb.Append(p).Append(","); }
            watchSeen = sb.ToString();
        });
        watchThread.IsBackground = true;
        watchThread.Start();
    }
    public static string StopForegroundWatch() {
        watchStop = true;
        if (watchThread != null) watchThread.Join(3000);
        watchThread = null;
        return watchSeen;
    }

    // Enumeration from a thread that is NOT bound to the test desktop: the
    // isolation assertion. A window on a background desktop must never show up.
    public static bool AnyVisibleWindowOnInteractiveDesktop(int pid) {
        bool any = false;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == (uint)pid && IsWindowVisible(h)) { any = true; return false; }
            return true;
        }, IntPtr.Zero);
        return any;
    }
}
'@
}

# ---------------------------------------------------------------------------
# PowerShell surface
# ---------------------------------------------------------------------------

$script:GhozttyTestDesktop = $null
# Live processes, emptied by Remove-TestDesktop as it kills them...
$script:GhozttyTestDesktopPids = @()
# ...and every pid this run ever launched, which Remove-TestDesktop does NOT
# touch. The end-of-run leak assertion has to compare against the second list:
# it runs AFTER the cleanup, and reading the live list there silently scores
# an empty set - an assertion that passes because it checked nothing.
# Read it with Get-TestLaunchedPids.
$script:GhozttyTestDesktopAllPids = @()

# T43: measure the chrome the USER gets, not the chrome a dev build wears.
#
# A Debug/ReleaseSafe build tints its whole caption/tab band amber so it cannot
# be mistaken for the installed release. Every GUI script here runs a DEBUG
# build and reads its chrome pixels AS THE PROXY FOR WHAT SHIPS - so left on,
# the marker would quietly move every one of those claims onto a surface no
# user ever sees. It is not hypothetical: with the marker live, `tab-strip.ps1`
# went 8 red on a build that was behaving correctly, because every chrome
# surface is a fixed-fraction wash of the bar and a tinted bar is a lighter
# bar, so each wash steps less far ("an inactive tab is invisible against the
# strip" was one of them).
#
# Set HERE, at harness load, for the same reason `Clear-TestWindowPlacement`
# runs at launch rather than in each script's finally: a script must control
# the inputs its conditions are a function of (T267), and a new script gets it
# for free. `chrome-theme.ps1` is the one script whose SUBJECT is the marker;
# it re-enables it after dot-sourcing, which is the same opt-out shape
# `-KeepWindowPlacement` uses for the scripts that own the placement memory.
#
# Inherited by every child: `StartProcess` passes a null lpEnvironment.
$env:GHOZTTY_DEBUG_MARKER = '0'

# VK codes by friendly name. Single characters fall through to VkKeyScan-free
# uppercase mapping, which is what every existing script already assumes.
$script:GhozttyTestVk = @{
    'enter' = 0x0D; 'return' = 0x0D; 'escape' = 0x1B; 'esc' = 0x1B; 'tab' = 0x09
    'space' = 0x20; 'backspace' = 0x08; 'delete' = 0x2E; 'insert' = 0x2D
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
    'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22
    'ctrl' = 0x11; 'control' = 0x11; 'shift' = 0x10; 'alt' = 0x12; 'win' = 0x5B
    'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74; 'f6' = 0x75
    'f7' = 0x76; 'f8' = 0x77; 'f9' = 0x78; 'f10' = 0x79; 'f11' = 0x7A; 'f12' = 0x7B
    'plus' = 0xBB; 'minus' = 0xBD; 'comma' = 0xBC; 'period' = 0xBE
    'oem_1' = 0xBA; 'backtick' = 0xC0; 'lbracket' = 0xDB; 'rbracket' = 0xDD
}

function ConvertTo-TestVk([string]$Key) {
    if ($Key.Length -eq 1) { return [uint16][int][char]([char]::ToUpper($Key[0])) }
    $k = $Key.ToLower()
    if ($script:GhozttyTestVk.ContainsKey($k)) { return [uint16]$script:GhozttyTestVk[$k] }
    if ($k -match '^(0x)?[0-9a-f]{1,2}$') { return [uint16][Convert]::ToInt32($k.Replace('0x', ''), 16) }
    throw "ConvertTo-TestVk: unknown key '$Key'"
}

function Resolve-TestDesktop($Desktop) {
    if ($Desktop) { return $Desktop }
    if ($script:GhozttyTestDesktop) { return $script:GhozttyTestDesktop }
    throw 'No test desktop: call New-TestDesktop first.'
}

<#
Create the background desktop and bind the harness's worker thread to it.
Returns the handle object, and remembers it so every other function can
default to it. -Interactive (or GHOZTTY_TEST_INTERACTIVE=1) is the documented
debug escape hatch: no desktop is created and the app is driven the old way on
the interactive desktop, where you can watch it - and where it steals focus.
#>
function New-TestDesktop {
    param(
        [string]$Name,
        [switch]$Interactive
    )
    $interactiveMode = [bool]$Interactive
    if ($env:GHOZTTY_TEST_INTERACTIVE -eq '1') { $interactiveMode = $true }
    if (-not $Name) { $Name = 'ghoztty-test-' + [System.Diagnostics.Process]::GetCurrentProcess().Id }

    $td = [GhozttyTestDesktop]::Create($Name, $interactiveMode)
    if (-not $td.Ready) { throw "New-TestDesktop failed: $($td.SetupError)" }
    $script:GhozttyTestDesktop = $td
    $script:GhozttyTestDesktopPids = @()
    $script:GhozttyTestDesktopAllPids = @()
    if ($interactiveMode) {
        Write-Host "NOTE  test desktop DISABLED (-Interactive): running on the interactive desktop, this WILL steal focus"
    }
    return $td
}

<#
Delete the DEBUG window-placement memory (T85) so the next launch opens at the
app's built-in 800x600 default instead of whatever the LAST debug window was
left at - including maximized.

WHY (T267). Every GUI script clears `session-layout-debug.json` before it
launches, and NONE of them cleared this second file, so a script that sets no
size inherited its window from whichever script ran before it. That makes a
script's SETUP a function of run order, and nothing fails when it goes wrong -
the geometry is simply different. It cost two real red runs against a build
that was behaving correctly: `chrome-merged-row.ps1` failed its own second run
(its section 7 maximizes, so the next run opened maximized, where the top edge
hit-tests HTCAPTION instead of HTTOP), and `tab-strip.ps1` went three red once
that was clean, because every condition it sets up is a RATIO of the tab run
and it had never controlled the window the ratio is taken of.

Cleared at LAUNCH rather than in each script's `finally`: a script that dies
mid-run cannot poison the next one, and a new script gets it for free.

The path is derived from `$env:LOCALAPPDATA` at call time, which is the same
value `CreateProcessW` is about to hand the child - so the throwaway-LOCALAPPDATA
scripts resolve to THEIR dir, not the user's. Only ever the `-debug` file: a
release build writes `window_placement`, which belongs to the user's installed
Ghoztty (the `Clear-DebugSessionLayout` rule in lib\CleanSlate.ps1).

Returns $true if a file was removed.
#>
function Clear-TestWindowPlacement {
    $local = $env:LOCALAPPDATA
    if (-not $local) { return $false }
    $path = Join-Path $local 'ghoztty\window_placement-debug'
    if (-not (Test-Path $path)) { return $false }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path $path))
}

<#
Launch an executable ON the test desktop (STARTUPINFO.lpDesktop). Returns
{ Pid, Process }; Process is the usual System.Diagnostics.Process, so
$app.Process.HasExited works exactly as with Start-Process.

Launching ghoztty.exe also clears the debug window-placement memory
(Clear-TestWindowPlacement, T267) so window geometry never depends on run
order. -KeepWindowPlacement opts out, and is for the two scripts whose SUBJECT
is that memory (window-size-memory.ps1, reset-window-size.ps1): deleting the
file between their launches would delete the thing under test.
#>
function Start-OnTestDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [string]$StdErr,
        [switch]$KeepWindowPlacement,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    if (-not $KeepWindowPlacement -and (Split-Path -Leaf $Exe) -ieq 'ghoztty.exe') {
        Clear-TestWindowPlacement | Out-Null
    }
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $procId = $td.StartProcess($Exe, $argLine, $WorkingDirectory, $StdErr)
    if ($procId -eq 0) { throw "Start-OnTestDesktop failed: $($td.LastError)" }
    $script:GhozttyTestDesktopPids += $procId
    $script:GhozttyTestDesktopAllPids += $procId
    $p = $null
    try { $p = [System.Diagnostics.Process]::GetProcessById($procId) } catch { }
    return [pscustomobject]@{ Pid = $procId; Process = $p }
}

# Wait for a top-level window of $Class owned by $ProcessId. Returns IntPtr::Zero
# on timeout so callers can report their own SETUP FAIL.
function Wait-TestWindow {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        $Class = 'GhozttyWindow',
        [int]$TimeoutMs = 20000,
        [switch]$AllowHidden,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return $td.WaitTop($ProcessId, (ConvertTo-TestFilter $Class), (-not $AllowHidden), $TimeoutMs)
}

# A top-level window right now (no waiting). -AllowHidden finds windows that
# toggle_visibility has hidden; -Exclude skips a known window (popup finders).
function Get-TestWindow {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        $Class = 'GhozttyWindow',
        [switch]$AllowHidden,
        [IntPtr]$Exclude = [IntPtr]::Zero,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return $td.FindTop($ProcessId, (ConvertTo-TestFilter $Class), (-not $AllowHidden), $Exclude)
}

# PowerShell coerces $null to '' for a [string] parameter, and win32 treats ''
# as "match a window whose text is empty" - not "don't care". Every class/title
# argument therefore stays untyped and is normalised here.
function ConvertTo-TestFilter($Value) {
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ($s -eq '' -or $s -eq '*') { return $null }
    return $s
}

# All TOP-LEVEL windows of $ProcessId matching $Class, same object shape as
# Get-TestChildWindows. Get-TestWindow answers "the window"; this answers "how
# many, and where" - which is what an assertion like "no overlay windows remain"
# or "the strip glued above pane 1" needs. Wrap the call site in @(): PowerShell
# unrolls a one-element array return into a scalar whose .Count is $null.
function Get-TestWindows {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        $Class = 'GhozttyWindow',
        [switch]$AllowHidden,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return @($td.Tops($ProcessId, (ConvertTo-TestFilter $Class), (-not $AllowHidden)) | ForEach-Object {
        $hw, $vis, $r, $cls = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw; Visible = ($vis -eq '1')
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
            Width = [int]$c[2] - [int]$c[0]; Height = [int]$c[3] - [int]$c[1]
            Class = $cls
        }
    })
}

# All child windows of $Class as objects: Hwnd, Visible, Left/Top/Right/Bottom,
# Width/Height, Class. -Class '*' returns every child, class name included.
function Get-TestChildWindows {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Class = 'GhozttyTerminal',
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return @($td.Children($Window, (ConvertTo-TestFilter $Class)) | ForEach-Object {
        $hw, $vis, $r, $cls = $_ -split ':'
        $c = $r -split ','
        [pscustomobject]@{
            Hwnd = [int64]$hw; Visible = ($vis -eq '1')
            Left = [int]$c[0]; Top = [int]$c[1]; Right = [int]$c[2]; Bottom = [int]$c[3]
            # Width/Height are carried here and on Get-TestWindows so the two
            # shapes are interchangeable. Without them a `$child.Width` reads
            # $null, and `$null -eq <number>` is a quiet FAIL rather than an
            # error - which is exactly how it was found.
            Width = [int]$c[2] - [int]$c[0]; Height = [int]$c[3] - [int]$c[1]
            Class = $cls
        }
    })
}

function Get-TestChildWindow {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Class = 'GhozttyTerminal',
        [switch]$AllowHidden,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return $td.FirstChild($Window, (ConvertTo-TestFilter $Class), (-not $AllowHidden))
}

function Find-TestWindowEx {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Parent,
        $Class,
        $Title,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return $td.FindWindowEx($Parent, (ConvertTo-TestFilter $Class), (ConvertTo-TestFilter $Title))
}

function Get-TestWindowRect {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, [switch]$Client, $Desktop)
    $td = Resolve-TestDesktop $Desktop
    $r = if ($Client) { $td.ClientRect($Window) } else { $td.Rect($Window) }
    return [pscustomobject]@{
        Left = $r[0]; Top = $r[1]; Right = $r[2]; Bottom = $r[3]
        Width = $r[2] - $r[0]; Height = $r[3] - $r[1]
    }
}

function Test-TestWindowVisible {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).IsVisible($Window)
}

function Test-TestWindowExists {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).Exists($Window)
}

# Is the window maximized? (IsZoomed - no pixels involved, so it works on a
# background desktop and is the usual positive control for size tests.)
# IsWindowEnabled: false while a modal dialog owns the window, true again once
# it closes. The cross-process-safe way to assert modality.
function Test-TestWindowEnabled {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).Enabled($Window)
}

function Test-TestWindowZoomed {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).Zoomed($Window)
}

# Resize the window rect (position and z-order unchanged). -Grow adds to the
# current rect instead of setting it, which is what the size tests want when
# they stretch a window away from its default.
function Set-TestWindowSize {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [int]$Width, [int]$Height,
        [switch]$Grow,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    if ($Grow) {
        $r = $td.Rect($Window)
        $Width += ($r[2] - $r[0])
        $Height += ($r[3] - $r[1])
    }
    return $td.SetSize($Window, $Width, $Height)
}

# Move the window (z-order unchanged); -Width/-Height resize it in the same
# call. Set-TestWindowSize deliberately never moves, so this is what a test uses
# when the MOVE is the thing under test - e.g. an overlay popup that has to
# re-glue itself to its pane from WM_MOVE.
function Set-TestWindowPos {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [int]$Width = 0, [int]$Height = 0,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $resize = ($Width -gt 0 -and $Height -gt 0)
    return $td.SetPos($Window, $X, $Y, $Width, $Height, $resize)
}

<#
A layered popup's alpha, as { Ok, Alpha, Flags, ColorKey }. Flags bit 0 is
LWA_COLORKEY, bit 1 is LWA_ALPHA.

This is the background-desktop replacement for "composited screen pixel ==
own-DC pixel", the way an opaque overlay used to be asserted: there is no
screen composite off the input desktop to compare against (CAPTURE LIMIT,
above), so opacity is read from the window attribute that decides it. Fully
opaque with nothing keyed out is Alpha 255, Flags 2.
#>
function Get-TestLayeredAttrs {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    $a = (Resolve-TestDesktop $Desktop).LayeredAttrs($Window)
    return [pscustomobject]@{
        Ok = ($a[0] -eq 1); Alpha = $a[1]; Flags = $a[2]; ColorKey = $a[3]
    }
}

# The RESTORED window rect, valid while the window is maximized.
function Get-TestWindowNormalRect {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    $r = (Resolve-TestDesktop $Desktop).NormalRect($Window)
    return [pscustomobject]@{
        Left = $r[0]; Top = $r[1]; Right = $r[2]; Bottom = $r[3]
        Width = $r[2] - $r[0]; Height = $r[3] - $r[1]
    }
}

# The TEST desktop's work area (no taskbar there, so it is not the user's).
function Get-TestWorkArea {
    param($Desktop)
    $r = (Resolve-TestDesktop $Desktop).WorkArea()
    return [pscustomobject]@{
        Left = $r[0]; Top = $r[1]; Right = $r[2]; Bottom = $r[3]
        Width = $r[2] - $r[0]; Height = $r[3] - $r[1]
    }
}

# Resize the way a USER drag does: WM_ENTERSIZEMOVE -> SetWindowPos ->
# WM_EXITSIZEMOVE. Use this (not Set-TestWindowSize) when the behaviour under
# test distinguishes an interactive resize from a programmatic one.
function Invoke-TestDragResize {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [int]$DeltaWidth = 0, [int]$DeltaHeight = 0,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).DragResize($Window, $DeltaWidth, $DeltaHeight)
}

# Maximize / restore through the real WM_SYSCOMMAND path.
function Send-TestSysCommand {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][ValidateSet('maximize', 'restore', 'minimize', 'close')][string]$Command,
        $Desktop
    )
    $cmd = switch ($Command) {
        'maximize' { 0xF030 } 'restore' { 0xF120 } 'minimize' { 0xF020 } 'close' { 0xF060 }
    }
    return (Resolve-TestDesktop $Desktop).SysCommand($Window, $cmd)
}

function Get-TestWindowText {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).WindowText($Window)
}

# Read a CONTROL's text (WM_GETTEXT). Get-TestWindowText uses GetWindowTextW,
# which is cross-process cached and reads stale for an EDIT the app has
# updated - use this one for anything a dialog or the palette owns.
function Get-TestControlText {
    param([Parameter(Mandatory = $true)][IntPtr]$Control, $Desktop)
    return (Resolve-TestDesktop $Desktop).ControlText($Control)
}

# Replace a control's whole text (WM_SETTEXT) - how to commit an EXACT value
# into a prefilled EDIT, including the empty string.
function Set-TestControlText {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Control,
        [AllowEmptyString()][string]$Text,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SetControlText($Control, $Text)
}

# Win32 class of any hwnd - how a script checks that an hwnd it got from
# somewhere else (e.g. `+list --json`'s window id) really is what it claims.
<#
Send a message to a control and return its RESULT - the standard controls'
getters (LB_GETCOUNT, LB_GETITEMHEIGHT, EM_*, CB_*), where the answer IS the
return value. Returns [int64]::MinValue if the app did not answer in time.

Not for input, and not for anything whose effect is asynchronous: use
Send-TestRawMessage to POST into the app's own WM_APP+n protocol.
#>
function Invoke-TestMessage {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][uint32]$Message,
        [IntPtr]$WParam = [IntPtr]::Zero,
        [IntPtr]$LParam = [IntPtr]::Zero,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).MessageResult($Window, $Message, $WParam, $LParam)
}

# A window's style bits: -Style (GWL_STYLE, the default) or -ExStyle.
# For claims that have no pixel - "this listbox is owner-drawn", "this popup
# does not carry WS_EX_TOPMOST".
function Get-TestWindowStyle {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [switch]$ExStyle,
        $Desktop
    )
    $idx = if ($ExStyle) { -20 } else { -16 }
    return (Resolve-TestDesktop $Desktop).WindowLong($Window, $idx)
}

function Get-TestWindowClass {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).ClassName($Window)
}

# Registered CLASS style (GCL_STYLE) of $Window - CS_HREDRAW (0x2),
# CS_VREDRAW (0x1), CS_DBLCLKS (0x8), CS_OWNDC (0x20). Not the same thing as
# Get-TestWindowStyle, which reads the per-window GWL_STYLE.
function Get-TestWindowClassStyle {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).ClassStyle($Window)
}

# The focused HWND of $Window's GUI thread (GetGUIThreadInfo, no attach). Poll
# it - the T48 fix makes the app's SetFocus asynchronous.
function Get-TestFocusedWindow {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).FocusedHwnd($Window)
}

# The ACTIVE HWND of $Window's GUI thread. A background desktop has NO
# foreground window (GetForegroundWindow is 0 for every window), so this is
# what an activation claim is asserted against there - see ACTIVATION in the
# header. Poll it: activation, like focus, is asynchronous.
function Get-TestActiveWindow {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).ActiveHwnd($Window)
}

# Z-order index among the VISIBLE top-level windows of the test desktop, top
# first; -1 when the window is not enumerated. "Above" is MEASURED as a
# smaller index, never inferred.
function Get-TestZIndex {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).ZIndex($Window)
}

# GetWindow(GW_OWNER): the window an owned popup is pinned above.
function Get-TestWindowOwner {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).Owner($Window)
}

# "<count>:<classes>" of FOREIGN windows sandwiched between an owned overlay
# and its owner; "0:" is the healthy answer. "-2:below-owner" means the
# overlay fell behind its own window, "-1:missing" that one of them is gone.
function Get-TestOverlaySandwich {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Overlay,
        [Parameter(Mandatory = $true)][IntPtr]$Owner,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).Sandwich($Overlay, $Owner)
}

# Inject or clear WS_EX_TOPMOST the way a stray probe does. This is how the
# T142 defect is REPRODUCED in a test; the product never sets it.
function Set-TestWindowTopmost {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [bool]$On = $true,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SetTopmost($Window, $On)
}

# Hide, or re-show with SWP_SHOWWINDOW and no z-order request - the probe for
# whether the window manager still lifts a freshly shown popup to the top of
# its band on a desktop with no foreground window.
function Set-TestWindowShown {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [bool]$Show = $true,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SetShown($Window, $Show)
}

# Who is visibly on top at a screen point, as "<hwnd>:<rootHwnd>:<class>".
# The z-order-aware, pixel-free answer to "is the overlay in front here?" -
# and off the input desktop there are no composited pixels to ask instead.
function Get-TestWindowAt {
    param(
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).TopAt($X, $Y)
}

function Wait-TestFocus {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][int64]$Expected,
        [int]$TimeoutMs = 2000,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        if ($td.FocusedHwnd($Window) -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    return $false
}

# Replaces the copy-pasted T86 GrabForeground. On a background desktop there is
# no foreground to grab, so this shares the app's input queue and sets focus in
# it directly; -Interactive falls back to the real foreground grab.
function Focus-TestWindow {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [IntPtr]$Child = [IntPtr]::Zero,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).FocusWindow($Window, $Child)
}

<#
Send a key or chord to a TERMINAL surface.

    Send-TestKeys -Window $top -Target $pane -Key T -Modifiers ctrl,shift
    Send-TestKeys -Window $top -Target $pane -Key Up -Modifiers ctrl,alt

Modifiers are ctrl / shift / alt / win. The key may be a single character, a
friendly name (Enter, Escape, Up, F4 ...) or a hex VK.
#>
function Send-TestKeys {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [IntPtr]$Target = [IntPtr]::Zero,
        [Parameter(Mandatory = $true)][string]$Key,
        [string[]]$Modifiers = @(),
        [int]$HoldMs = 30,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $mods = @($Modifiers | ForEach-Object { ConvertTo-TestVk $_ })
    return $td.SendChord($Window, $Target, [uint16[]]$mods, (ConvertTo-TestVk $Key), $HoldMs)
}

<#
Send a chord to a VIEWER pane's WebView2 (Chromium) child window (T394).

    Send-TestViewerChord -Window $top -Target $chromiumChild -Modifiers ctrl -Key W

The target hwnd lives in the msedgewebview2 process; the app's UI thread is
who resolves the chord in its AcceleratorKeyPressed callback, so the helper
attaches to BOTH threads and holds the modifier state across the round trip.
#>
function Send-TestViewerChord {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][IntPtr]$Target,
        [Parameter(Mandatory = $true)][string]$Key,
        [string[]]$Modifiers = @(),
        [int]$HoldMs = 40,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $mods = @($Modifiers | ForEach-Object { ConvertTo-TestVk $_ })
    return $td.SendChordCross($Window, $Target, [uint16[]]$mods, (ConvertTo-TestVk $Key), $HoldMs)
}

# Type literal text into a terminal surface (WM_KEYDOWN only - the terminal
# runs ToUnicode itself, so posting WM_CHAR too would double every character).
function Send-TestText {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [IntPtr]$Target = [IntPtr]::Zero,
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$PerKeyMs = 25,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SendText($Window, $Target, $Text, $PerKeyMs)
}

<#
Inject text into a TERMINAL surface as something other than its own typing -
the screen-reader / on-screen-keyboard / automation case (T64).

Off the input desktop this is a posted WM_CHAR, which covers the app's
injected-text handling but NOT the VK_PACKET half of the real path. See
"MECHANISM LIMIT" in this file's header before writing an assertion on it.
#>
function Send-TestInjectedChar {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [IntPtr]$Target = [IntPtr]::Zero,
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$PerKeyMs = 25,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SendInjectedChar($Window, $Target, $Text, $PerKeyMs)
}

# Type into a STANDARD control (EDIT in a dialog or the command palette).
# Opposite convention to Send-TestText: standard controls need WM_CHAR, which
# nothing generates for a posted message.
function Send-TestControlText {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Control,
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$PerKeyMs = 20,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SendControlText($Control, $Text, $PerKeyMs)
}

# A navigation key (Enter / Escape / arrows / Tab) for a standard control.
# NOTE: -Modifiers does NOT reliably reach a standard control. The app runs
# TranslateMessage over dialog messages, and translation reads the queue's own
# key state rather than the state set around a posted message, so e.g. ctrl+a
# arrives as a literal 'a' instead of select-all. Drive dialogs with plain
# keys and text; modifier chords belong on terminal surfaces (Send-TestKeys).
function Send-TestControlKey {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Control,
        [Parameter(Mandatory = $true)][string]$Key,
        [string[]]$Modifiers = @(),
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $mods = @($Modifiers | ForEach-Object { ConvertTo-TestVk $_ })
    return $td.SendControlKey($Control, (ConvertTo-TestVk $Key), [uint16[]]$mods)
}

<#
Post ONE half of a WM_SYSKEYDOWN/WM_SYSKEYUP pair.

    Send-TestSysKey -Window $pane -Key F10 -Action down
    Send-TestSysKey -Window $pane -Key F10 -Action up

These are the messages F10 and Alt-modified keys arrive as, and the menu
activation contract (menu-bar.ps1 section G) is a claim about the PAIRING: a
lone Alt down-then-up opens the menu, the same Alt with a key pressed in
between must not. Send-TestKeys cannot express that - it owns both halves - so
this helper hands the caller each half and stays out of what goes between.

Not a general input path: for an ordinary chord use Send-TestKeys.
#>
function Send-TestSysKey {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][string]$Key,
        [ValidateSet('down', 'up')][string]$Action = 'down',
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return $td.SysKey($Window, (ConvertTo-TestVk $Key), ($Action -eq 'up'))
}

# Post WM_CLOSE to a window or dialog. Use this rather than a posted
# Enter/Escape for standard dialogs: dialog keyboard handling runs through
# the dialog manager, which never sees a posted message.
function Send-TestWindowClose {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).CloseWindow($Window)
}

<#
Activate a BUTTON control (BM_CLICK), for a script whose claim is about what
the button DOES rather than about hit testing. Sent, not posted, so the
handler has already run when this returns.

Prefer Send-TestMouse when the assertion IS about the click landing (hit
testing, a control's own hover/press feedback, a custom-drawn hot zone).
#>
function Send-TestControlClick {
    param([Parameter(Mandatory = $true)][IntPtr]$Control, $Desktop)
    return (Resolve-TestDesktop $Desktop).ControlClick($Control)
}

<#
Post a raw message to a window - for the app's PRIVATE WM_APP+n protocol, where
the test is deliberately seeding an internal code path rather than simulating a
user (session-reattach seeds a co-pending pair of WM_APP_SETFOCUS asserts, which
is the T105 oracle). Posted, never sent: the app handles these at the top of its
run loop, and a synchronous send would block the harness's one worker thread.

Not for input. Keys and clicks go through Send-TestKeys / Send-TestMouse, which
carry the modifier state and lParam encoding those messages need.
#>
function Send-TestRawMessage {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][uint32]$Message,
        [IntPtr]$WParam = [IntPtr]::Zero,
        [IntPtr]$LParam = [IntPtr]::Zero,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).PostRaw($Window, $Message, $WParam, $LParam)
}

<#
Post a mouse event at a SCREEN coordinate.

    Send-TestMouse -Window $top -Target $pane -X $cx -Y $cy -Button right
    Send-TestMouse -Window $top -Target $tabstrip -X $x -Y $y -Action down
    Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move

-Target is the hwnd the message is POSTED to: posted messages skip hit
testing, so name the window that would really have received the click (the
child pane, not its parent). Defaults to -Window.

-Action is click (default) / down / up / move / doubleclick / wheel.
-Button is left (default) / right / middle. -Delta applies to wheel only.

-Action doubleclick follows the TARGET's class style, because the OS does:
a CS_DBLCLKS window (GhozttyWindow - the split divider's equalize gesture)
gets down/up/DBLCLK/up, and a window without that style (GhozttyTerminal, the
terminal surface, which counts its own clicks) gets down/up/down/up. Posting
the CS_DBLCLKS form at a surface loses the second click entirely, so the
word-select it was meant to trigger never happens (measured in T218).
#>
function Send-TestMouse {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [IntPtr]$Target = [IntPtr]::Zero,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [ValidateSet('left', 'right', 'middle')][string]$Button = 'left',
        [ValidateSet('click', 'down', 'up', 'move', 'doubleclick', 'wheel')][string]$Action = 'click',
        [string[]]$Modifiers = @(),
        [int]$HoldMs = 40,
        [int]$Delta = 0,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $b = switch ($Button) { 'left' { 0 } 'right' { 1 } 'middle' { 2 } }
    $a = switch ($Action) {
        'move' { 0 } 'down' { 1 } 'up' { 2 } 'click' { 3 } 'doubleclick' { 4 } 'wheel' { 5 }
    }
    $mods = @($Modifiers | ForEach-Object { ConvertTo-TestVk $_ })
    return $td.MouseEvent($Window, $Target, $X, $Y, $b, $a, $HoldMs, [uint16[]]$mods, $Delta)
}

<#
Hammer unpaced left down/up pairs round-robin across several targets.

    Send-TestClickStorm -Targets $surfaces -Rounds 500

This is a LOAD SHAPE, not a gesture. Send-TestMouse settles ~100ms per click
so the app can act on it; a deadlock repro needs focus changes arriving faster
than the GUI thread drains them, which the same 1500 clicks through
Send-TestMouse would stretch to about four minutes. -X/-Y are CLIENT
coordinates (every target is a different window) and default to a point that
is inside any surface.

Returns the number of messages ACCEPTED, which is 2 * Rounds * Targets.Count
when every post landed. ASSERT IT (T107): a storm that posted nothing - dead
window, full queue - returns instantly and leaves every "under load"
assertion after it passing against no load.

But the count is a floor, not the oracle, and it was MEASURED not assumed
(T107 break-tests): an INVALID handle makes PostMessageW fail and the count
catches it, while a NULL handle SUCCEEDS - Windows posts to the calling
thread's own queue - so 3000 messages can be accepted by nobody. Always pair
the count with an oracle that the APP acted on the clicks: focus landing on
the storm's last target, which the storm ends every round on.
#>
function Send-TestClickStorm {
    param(
        [Parameter(Mandatory = $true)][IntPtr[]]$Targets,
        [int]$Rounds = 100,
        [int]$X = 10,
        [int]$Y = 10,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).ClickStorm($Targets, $Rounds, $X, $Y)
}

# Does the window's GUI thread still pump messages? The hang oracle for the
# T48 class of bug: a wedged thread never answers WM_NULL, and because the IPC
# listener lives on that thread, a wedge also silences +list.
function Test-TestWindowResponsive {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [int]$TimeoutMs = 3000,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).Responsive($Window, [uint32]$TimeoutMs)
}

# THE CURSOR IS NOT A CHANNEL HERE - MEASURED, T218 batch 3 (2026-07-31).
# SetCursorPos returns FALSE on a background desktop (it requires the calling
# thread's desktop to be the INPUT desktop) and GetCursorPos returns -1,-1.
# Both wrappers are kept because they are the honest way to find that out, and
# because -Interactive runs still have a real cursor - but do not build an
# oracle on them. Anything the product decides from GetCursorPos (the
# split-divider resize cursor is the worked example: WM_SETCURSOR carries no
# coordinates, so its handler must read the cursor) simply does not fire off
# the input desktop, and no amount of test-side setup makes it. Assert the
# underlying decision instead - WM_NCHITTEST answers the divider band directly.
function Set-TestCursorPos {
    param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y, $Desktop)
    return (Resolve-TestDesktop $Desktop).MoveCursor($X, $Y)
}

function Get-TestCursorPos {
    param($Desktop)
    $p = (Resolve-TestDesktop $Desktop).CursorPos()
    return [pscustomobject]@{ X = $p[0]; Y = $p[1] }
}

# Per-monitor DPI of a window - the scale for any DIP constant a script
# hard-codes (grab-band widths, divider thickness).
function Get-TestWindowDpi {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).Dpi($Window)
}

# Where the win32 chrome IS - caption height, strip height and origin, the
# right-anchored button band, and the tab run's measured right edge
# (`Get-TestChromeMetrics` / `Get-TestTabRunRight`, T257).
#
# Dot-sourced from here rather than pasted in so every script that already
# loads TestDesktop.ps1 gets it with no second load line, while this file stops
# growing - the chrome datum is its own concern and it changes on a different
# schedule (T205 moves it again).
#
# Dot-sourcing inside a dot-sourced script runs in the SAME scope, so these
# land in the caller's scope exactly like the functions above.
. (Join-Path $PSScriptRoot 'ChromeGeometry.ps1')

<#
Wait for a popup menu (win32 class '#32768') owned by $ProcessId.

TrackPopupMenuEx runs a MODAL loop on the app's GUI thread, so while a menu
is up the app answers no messages - but our worker thread is a different
thread, and EnumWindows/GetWindowRect/PrintWindow do not need the app's.
Dismiss with Send-TestControlKey (which posts without touching focus);
Send-TestKeys would SetFocus first and close the menu out from under you.

Returns IntPtr::Zero if no menu appeared.
#>
function Wait-TestPopupMenu {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutMs = 3000,
        $Desktop
    )
    return Wait-TestWindow -ProcessId $ProcessId -Class '#32768' -TimeoutMs $TimeoutMs -Desktop $Desktop
}

<#
Capture a window's pixels via PrintWindow(PW_RENDERFULLCONTENT) - the only
capture path that works on a background desktop, and only for GDI-painted
chrome (see CAPTURE LIMIT in this file's header; the OpenGL terminal surface
comes back as a flat fill).

Returns { Bitmap, Width, Height, Left, Top }. Bitmap is a System.Drawing.Bitmap
in WINDOW coordinates, so a screen coordinate maps to ($x - $shot.Left,
$y - $shot.Top). Dispose with Close-TestWindowPixels.
#>
<#
PrintWindow capture of a window, as a disposable Bitmap + its screen origin.

REFUSES the OpenGL terminal surface (T214). PrintWindow on a GhozttyTerminal
child returns a flat fill on a background desktop - one color, unchanged after
typing - so a probe aimed there reads a constant and scores green against a
pane that renders nothing. That is not a capture failure this function can
detect after the fact: a flat fill is a perfectly valid bitmap, and "is it
dark?" style assertions pass against it happily. So the refusal is by CLASS,
up front, before anyone can measure anything.

Pass -AllowTerminalSurface only to MEASURE the limit itself (that is what
terminal-capture-guard.ps1 does). For a real terminal-content probe, take one
of the four routes in the CAPTURE LIMIT header instead.
#>
function Get-TestWindowPixels {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop,
        [switch]$AllowTerminalSurface
    )
    $td = Resolve-TestDesktop $Desktop
    if (-not $AllowTerminalSurface) {
        $cls = $td.ClassName($Window)
        if ($cls -eq 'GhozttyTerminal') {
            throw ("Get-TestWindowPixels: refusing to capture the GhozttyTerminal surface. " +
                   "PrintWindow returns a flat fill for it off the input desktop, so any " +
                   "assertion on this capture would pass against nothing (T214). Probe the " +
                   "window that PAINTED the pixels, substitute another native painter of the " +
                   "same value, drop the assertion with its reason, or declare the script " +
                   "interactive-by-design - see the CAPTURE LIMIT header. " +
                   "-AllowTerminalSurface is for measuring the limit itself.")
        }
    }
    $r = $td.CaptureWindow($Window)
    if ($r[0] -eq 0) { throw "Get-TestWindowPixels failed: $($td.LastError)" }
    $hbmp = [IntPtr]$r[0]
    try {
        $bmp = [System.Drawing.Image]::FromHbitmap($hbmp)
    } finally {
        $td.ReleaseCapture($r[0])
    }
    return [pscustomobject]@{
        Bitmap = $bmp; Width = [int]$r[1]; Height = [int]$r[2]
        Left = [int]$r[3]; Top = [int]$r[4]
    }
}

function Close-TestWindowPixels {
    param([Parameter(Mandatory = $true)]$Shot)
    if ($Shot -and $Shot.Bitmap) { $Shot.Bitmap.Dispose() }
}

# One pixel from a capture, addressed in SCREEN coordinates so migrated probes
# keep their existing math. Returns $null when the point is off the capture.
function Get-TestPixel {
    param([Parameter(Mandatory = $true)]$Shot, [Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y)
    $lx = $X - $Shot.Left
    $ly = $Y - $Shot.Top
    if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.Width -or $ly -ge $Shot.Height) { return $null }
    return $Shot.Bitmap.GetPixel($lx, $ly)
}

# Mean luminance (0-255) over a screen rect of a capture, matching the
# Get-RectBrightness helpers the pixel-probe scripts already use.
function Get-TestBrightness {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int[]]$Rect,
        [int]$Inset = 8,
        [int]$Step = 4
    )
    # Parenthesised on purpose: in a PowerShell array literal the comma binds
    # tighter than `+`, so `@($a, $b, $c + $d)` concatenates arrays instead of
    # adding - it silently yields a 4-element list and every probe reads -1.
    if (-not $Rect) {
        $Rect = @($Shot.Left, $Shot.Top, ($Shot.Left + $Shot.Width), ($Shot.Top + $Shot.Height))
    }
    $x0 = $Rect[0] + $Inset - $Shot.Left
    $y0 = $Rect[1] + $Inset - $Shot.Top
    $x1 = $Rect[2] - $Inset - $Shot.Left
    $y1 = $Rect[3] - $Inset - $Shot.Top
    if ($x0 -lt 0) { $x0 = 0 }
    if ($y0 -lt 0) { $y0 = 0 }
    if ($x1 -gt $Shot.Width) { $x1 = $Shot.Width }
    if ($y1 -gt $Shot.Height) { $y1 = $Shot.Height }
    if ($x1 -le $x0 -or $y1 -le $y0) { return -1 }
    $sum = 0.0; $n = 0
    for ($y = $y0; $y -lt $y1; $y += $Step) {
        for ($x = $x0; $x -lt $x1; $x += $Step) {
            $c = $Shot.Bitmap.GetPixel($x, $y)
            $sum += (0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B)
            $n++
        }
    }
    if ($n -eq 0) { return -1 }
    return [int]($sum / $n)
}

<#
Number of distinct colors in a capture - the guard against scoring a probe
against nothing.

Two ways a capture is empty here, and BOTH sail through a naive threshold:
the OpenGL terminal surface always comes back as a flat fill (see CAPTURE
LIMIT above), and a window captured mid-paint comes back solid black, which
happily satisfies any "is it dark?" assertion. Measured in T216: the same
dark context menu read meanLum 0 / 1 color when captured 350ms after opening
and meanLum 52 / 53 colors at 400ms.

So a brightness probe should require real content before believing its own
number. Real GDI chrome (text, borders, separators) is always well into the
double digits.
#>
function Get-TestDistinctColors {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int]$Inset = 8,
        [int]$Step = 3,
        [int]$Max = 64
    )
    $seen = @{}
    $x1 = $Shot.Width - $Inset
    $y1 = $Shot.Height - $Inset
    for ($y = $Inset; $y -lt $y1; $y += $Step) {
        for ($x = $Inset; $x -lt $x1; $x += $Step) {
            $c = $Shot.Bitmap.GetPixel($x, $y)
            $seen["$($c.R),$($c.G),$($c.B)"] = 1
            if ($seen.Count -ge $Max) { return $seen.Count }
        }
    }
    return $seen.Count
}

# Watch the INTERACTIVE desktop for the whole run. Every migrated script should
# bracket itself with these two and assert the launched pid never appears - it
# is the user's actual complaint, asserted rather than assumed.
function Start-TestForegroundWatch { [GhozttyTestDesktop]::StartForegroundWatch() }

function Stop-TestForegroundWatch {
    $raw = [GhozttyTestDesktop]::StopForegroundWatch()
    return @($raw.Split(',') | Where-Object { $_ } | ForEach-Object { [int]$_ })
}

# Every pid this run launched onto the test desktop, dead ones included. This
# is what the end-of-run leak assertion compares the foreground samples
# against - it survives Remove-TestDesktop, which the live pid list does not:
#
#     $fgSeen = @(Stop-TestForegroundWatch)
#     $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
#     Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground'
function Get-TestLaunchedPids {
    return @($script:GhozttyTestDesktopAllPids | Select-Object -Unique)
}

# Is any window of $ProcessId visible on the INTERACTIVE desktop? Must be
# $false for anything launched onto a background test desktop.
function Test-TestDesktopLeak {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    return [GhozttyTestDesktop]::AnyVisibleWindowOnInteractiveDesktop($ProcessId)
}

# Kill everything this harness launched, unbind and drop the desktop. Safe to
# call twice.
function Remove-TestDesktop {
    param($Desktop, [switch]$KeepProcesses)
    $td = $Desktop
    if (-not $td) { $td = $script:GhozttyTestDesktop }
    if (-not $KeepProcesses) {
        foreach ($procId in $script:GhozttyTestDesktopPids) {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 400
    }
    $script:GhozttyTestDesktopPids = @()
    if ($td) { $td.Dispose() }
    if ($td -eq $script:GhozttyTestDesktop) { $script:GhozttyTestDesktop = $null }
}
