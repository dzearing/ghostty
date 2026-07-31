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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint p, out RECT r, uint winini);
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

    // ================= mouse =================
    // SendInput is dead here (T207), so mouse input is POSTED too. Two things
    // make that survivable rather than a fiction:
    //
    //   * The app reads shift/ctrl for a click from the message's own MK_*
    //     wparam (Surface.handleMouseButton), not from GetKeyState, so a
    //     posted click carries its modifiers correctly.
    //   * `SetCursorPos` DOES work on a background desktop - the cursor
    //     position is a property of the desktop, and the worker thread is
    //     bound to ours. So code that reads GetCursorPos (menu placement,
    //     hover, TrackPopupMenuEx's own modal loop) sees a coherent position
    //     even though no physical pointer moved.
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
                        Thread.Sleep(30);
                        PostMessageW(dst, dbl, (IntPtr)MouseMk(mods, held), lp);
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
Launch an executable ON the test desktop (STARTUPINFO.lpDesktop). Returns
{ Pid, Process }; Process is the usual System.Diagnostics.Process, so
$app.Process.HasExited works exactly as with Start-Process.
#>
function Start-OnTestDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [string]$StdErr,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
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

# All child windows of $Class as objects: Hwnd, Visible, Left/Top/Right/Bottom,
# Class. -Class '*' returns every child, class name included.
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
function Get-TestWindowClass {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).ClassName($Window)
}

# The focused HWND of $Window's GUI thread (GetGUIThreadInfo, no attach). Poll
# it - the T48 fix makes the app's SetFocus asynchronous.
function Get-TestFocusedWindow {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).FocusedHwnd($Window)
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

# Post WM_CLOSE to a window or dialog. Use this rather than a posted
# Enter/Escape for standard dialogs: dialog keyboard handling runs through
# the dialog manager, which never sees a posted message.
function Send-TestWindowClose {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    return (Resolve-TestDesktop $Desktop).CloseWindow($Window)
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

# Move the TEST desktop's cursor without posting anything. Useful when the
# product reads GetCursorPos on its own schedule (menu placement, hover).
function Set-TestCursorPos {
    param([Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y, $Desktop)
    return (Resolve-TestDesktop $Desktop).MoveCursor($X, $Y)
}

function Get-TestCursorPos {
    param($Desktop)
    $p = (Resolve-TestDesktop $Desktop).CursorPos()
    return [pscustomobject]@{ X = $p[0]; Y = $p[1] }
}

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
function Get-TestWindowPixels {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    $td = Resolve-TestDesktop $Desktop
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
