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
# CAPTURE TEAR (measured 2026-08-14, T835): PW_RENDERFULLCONTENT asks DWM for a
# copy of a layered window's composited surface, and that copy is ASYNCHRONOUS -
# it can hand back a half-finished frame. Three back-to-back captures of ONE
# banner overlay, unchanged and long since painted, put the right edge of the
# same table row at 1062, 1283 and 1179 px while the app logged an identical
# paint every time. So a pixel measurement over the default capture is a coin
# flip, and it fails in the direction that looks like a rendering bug in the
# app: pane-banner.ps1 went red about one run in three and T835 was filed
# against the banner's column math, which was never wrong.
# Use `Get-TestWindowPixels -Sync` for pixel ASSERTIONS on chrome. It goes
# through the window's own WM_PRINTCLIENT instead of DWM, so the window draws
# the frame synchronously into our DC and the bitmap is exactly what it painted
# (60/60 identical after the switch). It needs a WM_PRINTCLIENT handler in the
# window - add one, it is three lines beside the WM_PAINT case - and it throws
# rather than returning the blank frame a window without one prints.
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
# THE GENERAL RULE (T303, 2026-08-20): PRINTWINDOW SEES GDI, NOT COMPOSITION.
# The terminal surface is one instance of it, not the extent of it. Anything
# that composites its pixels instead of painting them into the window DC comes
# back as a flat fill, and that covers every WinUI/XAML window - Settings, Task
# Manager, most of the Win11 shell. Measured: PrintWindow(PW_RENDERFULLCONTENT)
# on Task Manager's main window returned a flat black 1379x1134 bitmap, 1
# distinct color over a 7px grid, an 8 KB PNG, and reported SUCCESS; a
# vertical-seam scan over it found zero seams, which reads as "this app has no
# master-detail seam" rather than "there is no capture". The Win32 apps that DO
# capture are classic GDI dialogs. This is architectural and permanent, not a
# bug with a workaround.
#
# THE COROLLARY, for anyone reaching for a native reference: A WIN11 APP CANNOT
# BE USED AS A PIXEL REFERENCE AT ALL. A spec that needs Windows metrics
# measures them through SystemParametersInfoForDpi / GetSystemMetrics / uxtheme
# / DWM instead (what T302 did) and cites Fluent as DOCUMENTATION, never as a
# measurement. Second, smaller trap from the same probe: Task Manager launches
# elevated, so a non-elevated session cannot close it again - Stop-Process,
# CloseMainWindow and taskkill all return Access Denied. A fixture the harness
# cannot clean up is not a fixture.
#
# Get-TestWindowPixels enforces this half of the limit after the fact, since no
# class list could predict it: a non-trivial capture that is one color over its
# whole interior THROWS, after retrying long enough to rule out a window that
# simply had not painted yet. -AllowUniform opts out, for measuring the limit.
#
# THE ROUTE for a terminal-content probe (T214, decided 2026-08-01; route 0
# added by T275, 2026-08-11). In order, and the first one that applies wins:
#
#   0. ASK THE APP FOR ITS OWN PIXELS - `lib\PaneCapture.ps1`'s
#      Get-TestPaneCapture, over the debug-only `capture-pane` IPC action. The
#      pane's renderer thread reads back its OFFSCREEN target (the same
#      readback hero mode's thumbnails use) and the app writes a PNG, so no
#      desktop, no composite and no window visibility is involved - a HIDDEN
#      pane captures exactly as a focused one does (asserted in
#      pane-capture.ps1 section 5). This is the route for anything whose claim
#      really is "what the glass is showing": the tint that reached the GL
#      clear color, a pane that is rendering content at all.
#      Its own trap, and why it is route 0 rather than the only route: it
#      captures ONE PANE, not a composite, so it can say nothing about z-order,
#      chrome over glass, or a divider between two panes. For those, keep going.
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
#      substitute does NOT cover - there, the glass itself. (That one now has
#      BOTH: the band assertion stayed and route 0 added the glass beside it.)
#   3. DROP THE ASSERTION, in place, with the measured reason in the script
#      header. Never weaken it into something a flat fill can pass. hero-mode's
#      two Get-PaneColorCount probes went this way, and came back through route
#      0 - which is what T214 said would flip the trade.
#   4. INTERACTIVE BY DESIGN - keep it on the input desktop and declare it
#      below. Only for a script whose whole oracle is terminal content.
#
# THE FLAT-FILL LIMIT ITSELF HAS NOT MOVED. Route 0 is a way AROUND it, not a
# repeal of it: PrintWindow on a GhozttyTerminal child still returns one color,
# and Get-TestWindowPixels still refuses that capture. A probe that reaches for
# -AllowTerminalSurface because "T275 fixed capture" has misread this - route 0
# does not go through PrintWindow at all.
#
# ROUTE H - A HOVERED FRAME (`lib\HoverCapture.ps1`'s Get-TestHoverCapture,
# T282). Chrome, not terminal content, and a DIFFERENT limit from the one
# above: the pixels were always capturable, but the hovered FRAME was never
# painted. There is no real cursor here, so TrackMouseEvent makes the OS post
# WM_MOUSELEAVE within a frame of every posted WM_MOUSEMOVE, and WM_PAINT is
# the lowest-priority message in the queue - the leave is drained first and the
# frame that gets painted is the un-hovered one. An ORDERING problem, so no
# amount of retrying wins it (T209 measured 300 posted moves and never caught a
# lit fill). Get-TestHoverCapture has the APP hit-test, send the move, repaint
# and PrintWindow on ONE GUI-thread stack, which the message loop is never
# reached in the middle of. Use it for ANY hover fill; a Send-TestMouse move
# plus Get-TestWindowPixels cannot see one. The hover does not latch - the
# leave lands on the next pump exactly as before. That app-side PrintWindow is
# the SYNCHRONOUS one for the same reason -Sync is on this side (T845): the
# PW_RENDERFULLCONTENT copy it used at first is a DWM copy, and one in ten of
# them predated the hover paint.
#
# TERMINAL-CONTENT PROBES THAT STAY ON THE INPUT DESKTOP (declared, not
# missed - an undeclared exception is indistinguishable from an oversight):
#
#   profile-latency.ps1  (T53b) One assertion: the scroll-viewport pixel hash.
#                        The script is interactive anyway (SendInput timing IS
#                        the measurement) - see T272.
#
# `color-contrast.ps1` was the third entry here and is not one any more: route 0
# took it off the input desktop entirely (T275), which is what route 0 was for.
# Its old shape is the reason the audit's rule is written the way it is - it
# called neither SendInput nor SetForegroundWindow, and was input-desktop-only
# all the same because it read the composited screen (see T276).
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
#
# INTERACTIVE BY DESIGN - the scripts that can only run on the INPUT DESKTOP
# (T272, widened by T276). Two ways to end up here, one list: taking the
# foreground / injecting input, and reading the COMPOSITED SCREEN (a screen DC,
# CopyFromScreen), which DWM produces for the input desktop only. The second is
# not a footnote - `color-contrast.ps1` was input-desktop-only for years while
# grabbing no input at all, and the sweep that was written to find "scripts that
# steal focus" could not see it.
#
# T217 closed at 23 of 23 and T218 at 13 of 13, and the fleet-wide claim
# became "the acceptance scripts no longer steal the user's foreground" - while
# two scripts sat in neither bucket, still grabbing, because nothing counted the
# remainder. Those two were migrated (T224, T225); what stops the property
# regrowing is that the remaining exceptions are DECLARED here rather than
# remembered. An undeclared grab site is indistinguishable from an oversight,
# which is how the first two went quiet. `lib\ForegroundAudit.ps1` PARSES the
# marker lines below and fails on any script that grabs and is not among them,
# so the prose a human reads and the set the check enforces cannot drift apart.
#
# @input-desktop-exception: context-menu-real-input.ps1 -- (T240) the subject IS a real right-click: a script that synthesizes the trigger cannot validate the trigger.
# @input-desktop-exception: profile-latency.ps1 -- (T53b) injection timing is the measurement, so a posted message would time the wrong path.
# @input-desktop-exception: test-desktop-spike.ps1 -- (T207) the spike that measured what does and does not work off the input desktop; it has to reach both.
#
# LAUNCHES ON THE USER'S DESKTOP - the second list, and a different question
# (T1193). The one above asks which scripts CALL an API that only works on the
# input desktop. This one asks which scripts START THE APP from a process
# sitting on the user's desktop, which no API name answers: `+new-window` is
# the one verb that auto-launches, and the window it spawns lands wherever the
# spawning process was. 50 scripts were doing that - including ipc-p1/p2/p3,
# the floor CLAUDE.md names for every change - while the fleet-wide claim was
# that the suite no longer steals focus. `lib\DesktopLaunchAudit.ps1` parses
# these markers; `desktop-launch-audit.ps1` is the sweep.
#
# Migrate with `Invoke-OnTestDesktop` (the CLI half) and `Start-OnTestDesktop`
# (the GUI half), then DELETE the entry - a migration that leaves its line
# behind fails the sweep as a stale declaration, which is what makes this list
# burn down instead of settling.
#
# @user-desktop-launch: context-menu-real-input.ps1 -- (T240) already interactive-by-design above: the subject IS a real right-click, so its app has to be on the input desktop too.
# @user-desktop-launch: profile-latency.ps1 -- (T53b) already interactive-by-design above: injection timing is the measurement, and it can only be taken where input is injected.
# @user-desktop-launch: go-loop-guard.ps1 -- (T1193) the ONE bare launch is the fallback taken when New-TestDesktop throws - a desktop we cannot create must not cost the whole suite, and the fallback says so loudly before it runs.
#
# @user-desktop-launch: agent-job-escape.ps1 -- (T1238) its SUBJECT is the agent escaping a kill-on-close job, and the only escape tier that works from the pane-shell job chain is the shell-parent hop: measured on box, breakaway is ACCESS_DENIED and a background desktop has no shell window, so the app logs 'shell-parent spawn unavailable err=error.NoShellWindow' and spawns INSIDE the job. The measurement needs a desktop that has a shell.
# @user-desktop-launch: relaunch-guard.ps1 -- (T1238) same measured reason as agent-job-escape.ps1 above: its section F asserts the relaunched app lands OUTSIDE a kill-on-close job, and that escape needs the shell-parent hop, which needs a desktop with a shell window.

# T118: never inherit an IPC endpoint. A script started from one of the user's
# own panes inherits $GHOZTTY_IPC_SOCKET naming the USER'S app, and the CLI
# prefers a baked endpoint over the derivation - so leaving it set would aim
# the run at their terminal instead of the build under test. Same drop as
# CleanSlate.ps1, repeated here because not every GUI script sources both.
Remove-Item Env:GHOZTTY_IPC_SOCKET -ErrorAction SilentlyContinue

# T675: BuildMode.ps1 also carries the startup-escape suppression seam, and a
# GUI script that only sources this file must still get it - an app launched
# on the test desktop can still tier-1 breakaway out of a permissive job
# chain and hand its pid-tracked work to a twin. Repeated here for the same
# reason as the endpoint drop above.
. (Join-Path $PSScriptRoot 'BuildMode.ps1')

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
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint SuspendThread(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int ResumeThread(IntPtr h);
    const uint THREAD_SUSPEND_RESUME = 0x0002;
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr h, uint code);

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
    // A child window's control ID - the `hMenu` its creator passed to
    // CreateWindowEx, i.e. the APP's own name for the control (it is what
    // WM_COMMAND is routed on). Cross-process and free: a USER32 read of the
    // window's own storage, needing neither the owner's message loop nor a
    // pixel. See lib\ChooserControls.ps1 for why a test asks by id.
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
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
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr hdc, int x, int y);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint color);
    [DllImport("user32.dll")] static extern int FillRect(IntPtr hdc, ref RECT r, IntPtr brush);

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

    // The pseudo-parent that scopes FindWindowExW to message-only windows.
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);

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
    // The non-client twins (T263). Windows picks between these and the client
    // messages above by WM_NCHITTEST, and so does MouseEvent.
    const uint WM_NCHITTEST = 0x0084;
    const uint WM_NCMOUSEMOVE = 0x00A0;
    const uint WM_NCLBUTTONDOWN = 0x00A1, WM_NCLBUTTONUP = 0x00A2, WM_NCLBUTTONDBLCLK = 0x00A3;
    const uint WM_NCRBUTTONDOWN = 0x00A4, WM_NCRBUTTONUP = 0x00A5, WM_NCRBUTTONDBLCLK = 0x00A6;
    const uint WM_NCMBUTTONDOWN = 0x00A7, WM_NCMBUTTONUP = 0x00A8, WM_NCMBUTTONDBLCLK = 0x00A9;
    const int HTERROR = -2, HTTRANSPARENT = -1, HTNOWHERE = 0, HTCLIENT = 1;
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
            IntPtr hProc;
            int procId = SpawnCore(exe, args, cwd, stderrPath, out hProc);
            if (hProc != IntPtr.Zero) CloseHandle(hProc);
            return procId;
        });
    }

    // Start on the test desktop and WAIT for the process to exit. For the CLI
    // half of a migration (T1193): a script that drove the app with
    // `& $Exe +new-window` needs the CLI process itself to sit on the test
    // desktop, because `+new-window` from cold auto-launches the GUI and the
    // window lands on the desktop of whoever created the process.
    //
    // Returns "<exitcode>:<pid>:<exit|timeout>", or "" when the spawn failed
    // (LastError says why). A timeout terminates the child rather than leaking
    // it onto a desktop nobody will look at again.
    public string RunProcess(string exe, string args, string cwd, string outPath, int timeoutMs) {
        return (string)Run(delegate() {
            IntPtr hProc;
            int procId = SpawnCore(exe, args, cwd, outPath, out hProc);
            if (procId == 0) return "";
            uint waited = WaitForSingleObject(hProc, (uint)timeoutMs);
            uint code = 259;
            bool exited = (waited == 0);
            if (exited) {
                GetExitCodeProcess(hProc, out code);
            } else {
                TerminateProcess(hProc, 258);
                LastError = "RunProcess timed out after " + timeoutMs + " ms";
            }
            CloseHandle(hProc);
            return ((int)code) + ":" + procId + ":" + (exited ? "exit" : "timeout");
        });
    }

    int SpawnCore(string exe, string args, string cwd, string stderrPath, out IntPtr hProcess) {
        hProcess = IntPtr.Zero;
        {
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
            hProcess = pi.hProcess;
            return pi.dwProcessId;
        }
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
    // that there is exactly one of them, actually needs. pid <= 0 means ANY
    // process: what a test asserting a class is absent desktop-wide needs
    // (e.g. T291's "no console window appeared" - the console window belongs
    // to conhost, never to the app or the child that was spawned).
    public string[] Tops(int pid, string clsArg, bool requireVisible) {
        string cls = NoFilter(clsArg);
        return (string[])Run(delegate() {
            var lines = new List<string>();
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                uint p; GetWindowThreadProcessId(h, out p);
                if (pid > 0 && p != (uint)pid) return true;
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

    // A MESSAGE-ONLY window (an HWND_MESSAGE child) of class `cls` owned by
    // `pid`. Message-only windows are invisible to EnumWindows, so none of the
    // pid-filtered finders above can see them, and FindWindowEx alone would
    // hand back the FIRST match on the box - which may well be the user's own
    // running Ghoztty. Posting a private WM_APP message into that would drive
    // their terminal, so the pid filter here is a safety guard, not a
    // convenience: walk the HWND_MESSAGE list and take only our own.
    public IntPtr FindMessageWindow(string clsArg, uint pid) {
        string cls = NoFilter(clsArg);
        return (IntPtr)Run(delegate() {
            IntPtr h = IntPtr.Zero;
            while (true) {
                h = FindWindowExW(HWND_MESSAGE, h, cls, null);
                if (h == IntPtr.Zero) return IntPtr.Zero;
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner == pid) return h;
            }
        });
    }

    public bool IsVisible(IntPtr h) { return (bool)Run(delegate() { return IsWindowVisible(h); }); }
    public bool Exists(IntPtr h) { return (bool)Run(delegate() { return IsWindow(h); }); }
    // Modality's observable side: an owner window is DISABLED for as long as
    // its modal dialog is up, and re-enabled when the dialog closes.
    public bool Enabled(IntPtr h) { return (bool)Run(delegate() { return IsWindowEnabled(h); }); }
    public int CtrlId(IntPtr h) { return (int)Run(delegate() { return GetDlgCtrlID(h); }); }

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

    // T179: every window a probe has pinned and not yet put back, and every
    // window the restore had to put back itself. STATIC on purpose - the
    // ledger has to outlive the desktop object (Remove-TestDesktop disposes
    // it) and be reachable from a PowerShell.Exiting action, which does not
    // share the dot-sourcing script's variable scope.
    static readonly List<IntPtr> TopmostInjected = new List<IntPtr>();
    static readonly List<IntPtr> TopmostRestored = new List<IntPtr>();

    // Inject (or clear) WS_EX_TOPMOST exactly the way a stray verification
    // probe does - HWND_TOPMOST / HWND_NOTOPMOST, nothing else touched.
    //
    // A pin is LEDGERED here rather than left to the caller's discipline: a
    // probe that raised a window and never put it back is what manufactured
    // T142's phantom bug (a day spent on "background windows have banners that
    // overlap foreground windows", which was a T131 probe's leftover
    // HWND_TOPMOST on two overlays). RestoreTopmost is what cashes it in.
    public bool SetTopmost(IntPtr h, bool on) {
        lock (TopmostInjected) {
            if (on) { if (!TopmostInjected.Contains(h)) TopmostInjected.Add(h); }
            else TopmostInjected.Remove(h);
        }
        return (bool)Run(delegate() {
            return SetWindowPos(h, (IntPtr)(on ? -1 : -2), 0, 0, 0, 0, 0x0013); // NOSIZE|NOMOVE|NOACTIVATE
        });
    }

    // Put back every window a probe pinned that is STILL pinned, and answer
    // with the ones that needed it - those are the leaks. Empty is the healthy
    // answer: an injection the product healed (the T142 fix does exactly that
    // on the next reposition or activation) is already clear by the time this
    // runs, so it is not reported as a leak.
    //
    // Idempotent, and safe with no desktop bound: it walks handles, not the
    // desktop, so it works from a finally, from Remove-TestDesktop, and from a
    // PowerShell.Exiting action alike.
    public static string RestoreTopmost() {
        // GHOZTTY_TEST_TOPMOST_BREAK=1 disables the restore and nothing else,
        // so probe-topmost-restore.ps1's arms can be shown to go red. An arm
        // that cannot fail is not measuring anything, and this one guards a
        // property whose absence is invisible until it costs a day (T142).
        if (Environment.GetEnvironmentVariable("GHOZTTY_TEST_TOPMOST_BREAK") == "1") return "";
        IntPtr[] pending;
        lock (TopmostInjected) {
            pending = TopmostInjected.ToArray();
            TopmostInjected.Clear();
        }
        var freed = new List<string>();
        foreach (IntPtr h in pending) {
            if (!IsWindow(h)) continue;
            if ((GetWindowLongW(h, -20) & 0x8) == 0) continue; // GWL_EXSTYLE, WS_EX_TOPMOST
            SetWindowPos(h, (IntPtr)(-2), 0, 0, 0, 0, 0x0013); // HWND_NOTOPMOST
            lock (TopmostRestored) { if (!TopmostRestored.Contains(h)) TopmostRestored.Add(h); }
            freed.Add(((long)h).ToString());
        }
        return string.Join(",", freed.ToArray());
    }

    // Every window RestoreTopmost has ever had to put back this run. Survives
    // Remove-TestDesktop, so the end-of-run assertion can read it AFTER the
    // cleanup - the same reason the launched-pid list is kept separately.
    public static string RestoredTopmost() {
        lock (TopmostRestored) {
            var s = new List<string>();
            foreach (IntPtr h in TopmostRestored) s.Add(((long)h).ToString());
            return string.Join(",", s.ToArray());
        }
    }

    // Windows a probe has pinned and not yet put back. For the harness's own
    // test; scripts assert on RestoredTopmost.
    public static string PendingTopmost() {
        lock (TopmostInjected) {
            var s = new List<string>();
            foreach (IntPtr h in TopmostInjected) s.Add(((long)h).ToString());
            return string.Join(",", s.ToArray());
        }
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

                // Hold the faked modifiers until the app has actually read
                // them, rather than for a fixed 80ms - see PumpedTwice (T1104).
                PumpedTwice(top, 5000);
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
    // until the app has drained and then some: the chord crosses two process
    // boundaries before anyone reads it, and BOTH readers matter. Chromium
    // classifies the key as an accelerator from the modifier state, and only
    // then raises the event our UI thread resolves the binding on - so a
    // modifier released too early loses the chord in one place or the other,
    // and either way there is nothing to see but a shortcut that did nothing
    // (T1104).
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

                // The app pumps TWICE for one chord here (the modifier event,
                // then the key), with a browser hop in between that this side
                // cannot observe - hence: wait for a pumping app, then the
                // same 400ms grace this helper always had.
                PumpedTwice(appTop, 5000);
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

    // T1104: the same chord, delivered to an app that is TOO BUSY to answer
    // at once. The regression guard for the flake that filed the task.
    //
    // A viewer chord is resolved by two readers in turn - Chromium classifies
    // the key as an accelerator, then our UI thread matches the binding - and
    // both read the modifier state as they get to it. On a loaded box "as they
    // get to it" can be a second later, and SendChordCross used to drop the
    // faked modifiers on a fixed 400ms timer: past that, the chord resolves as
    // a bare letter and opens nothing. A real finger does not work that way,
    // which is why this is a harness bug and the shortcut is not broken.
    //
    // Modelled here by SUSPENDING the app's UI thread across the keystroke -
    // Chromium blocks against it, exactly as it does against a busy app - and
    // holding the modifiers down the whole time, as the user would. The
    // release waits for the app to drain, so a healthy harness still lands the
    // chord and a fixed-timer one does not.
    public bool SendChordCrossStarved(IntPtr appTop, IntPtr target, ushort[] mods, ushort vk, int holdMs, int starveMs) {
        return (bool)Run(delegate() {
            uint apid; uint appTid = GetWindowThreadProcessId(appTop, out apid);
            uint tpid; uint targetTid = GetWindowThreadProcessId(target, out tpid);
            uint cur = GetCurrentThreadId();
            IntPtr hThread = OpenThread(THREAD_SUSPEND_RESUME, false, appTid);
            if (hThread == IntPtr.Zero) { LastError = "OpenThread(app ui thread) failed"; return false; }
            if (!AttachThreadInput(cur, appTid, true)) { CloseHandle(hThread); LastError = "AttachThreadInput(app) failed"; return false; }
            bool crossAttached = (targetTid != appTid) && AttachThreadInput(cur, targetTid, true);
            bool suspended = false;
            try {
                SetActiveWindow(appTop);
                SetFocus(target);
                Thread.Sleep(60);

                var ks = new byte[256];
                GetKeyboardState(ks);
                ApplyMods(ks, mods, true);
                SetKeyboardState(ks);

                if (SuspendThread(hThread) == 0xFFFFFFFF) { LastError = "SuspendThread(app ui thread) failed"; return false; }
                suspended = true;

                foreach (ushort m in mods) PostMessageW(target, WM_KEYDOWN, (IntPtr)m, KeyLParam(m, false));
                PostMessageW(target, WM_KEYDOWN, (IntPtr)vk, KeyLParam(vk, false));
                Thread.Sleep(holdMs);
                PostMessageW(target, WM_KEYUP, (IntPtr)vk, KeyLParam(vk, true));
                for (int j = mods.Length - 1; j >= 0; j--)
                    PostMessageW(target, WM_KEYUP, (IntPtr)mods[j], KeyLParam(mods[j], true));

                // The app cannot look yet, and the modifiers stay down while
                // it cannot - that is the whole point of the case.
                Thread.Sleep(starveMs);
                ResumeThread(hThread);
                suspended = false;

                PumpedTwice(appTop, 5000);
                Thread.Sleep(400);
                ApplyMods(ks, mods, false);
                SetKeyboardState(ks);
                Thread.Sleep(80);
                return true;
            } finally {
                if (suspended) ResumeThread(hThread);
                CloseHandle(hThread);
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
    // What is NOT reproduced: Z-ORDER hit-testing. A posted message goes to
    // the hwnd you name, whatever is on top of it. That is a feature for tests
    // (no z-order flake) and a trap if you post to the parent expecting a
    // child to get it.
    //
    // What IS reproduced, since T263: the window's OWN hit test, i.e. which
    // message family the named target would really receive at that point. See
    // IsNonClientCode below.
    static IntPtr PackPoint(int x, int y) {
        return (IntPtr)((int)(((uint)y << 16) | ((uint)x & 0xFFFF)));
    }

    // ---- client vs non-client routing (T263) ----------------------------
    // Windows decides which FAMILY of mouse message a point produces by asking
    // the window WM_NCHITTEST first: HTCLIENT gets WM_LBUTTONDOWN & co., and
    // any other code gets the WM_NC* twin, with the hit code in wparam and the
    // SCREEN point in lparam. Since T254 the caption band is client PIXELS
    // that the window claims back through its hit test, so a posted client
    // message there reaches no handler at all and the click silently does
    // nothing (measured in T260: every menu-open assertion failed while F10
    // still passed). Doing the routing here means a script stops having to
    // know which band it is aiming at.
    //
    // The three "not me" answers are deliberately NOT converted:
    //
    //   HTNOWHERE      the point is outside the window we were told to post to
    //   HTTRANSPARENT  the window declines the hit so it falls to the one
    //                  below (the surface child does exactly this over the
    //                  split-divider grab band, App.surfaceWndProc)
    //   HTERROR        the window could not answer
    //
    // All three are the z-order question this harness deliberately does not
    // ask - "post to the hwnd you name, whatever is on top of it" - so they
    // keep today's client delivery to the named target rather than being
    // turned into an NC message with a nonsense hit code in wparam.
    static bool IsNonClientCode(int code) {
        return code != HTCLIENT && code != HTNOWHERE
            && code != HTTRANSPARENT && code != HTERROR;
    }

    // Ask the window itself. A window that does not answer within the timeout
    // (wedged, or dying) is reported HTCLIENT, i.e. today's behavior: a
    // routing question must never be the thing that hangs a mouse click. The
    // timeout is deliberately much shorter than Send()'s 10s - this call is on
    // the path of EVERY click, including the storm-shaped scripts.
    int HitTestCode(IntPtr h, int sx, int sy) {
        IntPtr res;
        // SMTO_ABORTIFHUNG
        if (SendMessageTimeoutW(h, WM_NCHITTEST, IntPtr.Zero, PackPoint(sx, sy),
                                0x0002, 1500, out res) == IntPtr.Zero) return HTCLIENT;
        return res.ToInt32();
    }

    // The routing decision, exposed so a script can assert it directly
    // (Get-TestMouseRoute) rather than inferring it from an effect.
    public int MouseRoute(IntPtr top, IntPtr target, int sx, int sy) {
        return (int)Run(delegate() {
            IntPtr dst = (target == IntPtr.Zero) ? top : target;
            return HitTestCode(dst, sx, sy);
        });
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
    //
    // clientOnly forces the client messages even where the window hit-tests
    // the point as non-client (the -Client escape hatch).
    public bool MouseEvent(IntPtr top, IntPtr target, int sx, int sy,
                           int button, int action, int holdMs,
                           ushort[] mods, int wheelDelta, bool clientOnly) {
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

                // T263: route the way Windows does. On the NC path the hit
                // code takes wparam's place, lparam is the SCREEN point, and
                // the second click of a double is ALWAYS the DBLCLK form -
                // CS_DBLCLKS governs client double-clicks only, which is why
                // a caption double-click maximizes any window.
                int hit = HTCLIENT;
                bool nc = false;
                if (!clientOnly && action != 5) {
                    hit = HitTestCode(dst, sx, sy);
                    nc = IsNonClientCode(hit);
                }
                uint move = WM_MOUSEMOVE;
                IntPtr moveWp = (IntPtr)MouseMk(mods, 0);
                if (nc) {
                    lp = PackPoint(sx, sy);
                    move = WM_NCMOUSEMOVE;
                    moveWp = (IntPtr)hit;
                    down = WM_NCLBUTTONDOWN; up = WM_NCLBUTTONUP; dbl = WM_NCLBUTTONDBLCLK;
                    if (button == 1) { down = WM_NCRBUTTONDOWN; up = WM_NCRBUTTONUP; dbl = WM_NCRBUTTONDBLCLK; }
                    else if (button == 2) { down = WM_NCMBUTTONDOWN; up = WM_NCMBUTTONUP; dbl = WM_NCMBUTTONDBLCLK; }
                }
                // The NC messages carry the hit code where the client ones
                // carry MK_* flags, so a button/modifier bit has nowhere to
                // ride: on that path the app reads modifiers with GetKeyState,
                // which is what the faked keyboard state above is for.
                IntPtr downWp = nc ? (IntPtr)hit : (IntPtr)MouseMk(mods, held);
                IntPtr upWp = nc ? (IntPtr)hit : (IntPtr)MouseMk(mods, 0);

                PostMessageW(dst, move, moveWp, lp);
                Thread.Sleep(20);

                if (action == 0) {
                    // move only
                } else if (action == 5) {
                    // WM_MOUSEWHEEL's lparam is SCREEN coordinates, not client.
                    uint wp = (uint)((wheelDelta << 16) | (int)MouseMk(mods, 0));
                    PostMessageW(dst, WM_MOUSEWHEEL, (IntPtr)(int)wp, PackPoint(sx, sy));
                } else {
                    if (action == 1 || action == 3 || action == 4) {
                        PostMessageW(dst, down, downWp, lp);
                    }
                    if (action == 3 || action == 4) {
                        Thread.Sleep(holdMs);
                        PostMessageW(dst, up, upWp, lp);
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
                        uint second = (nc || WantsDblClk(dst)) ? dbl : down;
                        PostMessageW(dst, second, downWp, lp);
                        Thread.Sleep(holdMs);
                        PostMessageW(dst, up, upWp, lp);
                    }
                    if (action == 2) {
                        PostMessageW(dst, up, upWp, lp);
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

    // Has `h`'s GUI thread caught up with the messages we just posted (T1104)?
    //
    // The chord helpers above fake the modifier state with SetKeyboardState,
    // which is an OUT-OF-BAND poke: real hardware modifiers travel with the
    // message stream, so a slow reader still sees the state that was in force
    // when the key went down, while a faked one is simply gone the moment we
    // clear it. Holding it for a fixed number of milliseconds therefore makes
    // every modified chord a race against box load - and on a loaded box that
    // race is lost. It cost viewer-panes.ps1 a red ctrl+t in a 242-script
    // sweep that was green every other time (T1104), which reads as a broken
    // keyboard shortcut and is not one.
    //
    // So the hold ends when the app has DEMONSTRABLY drained, not on a clock:
    // two consecutive answered pings, because a single one can be answered in
    // a gap between the messages we care about. A suspended or busy thread
    // does not answer at all, and the modifiers stay down meanwhile - which is
    // exactly what a real finger does.
    static bool PumpedTwice(IntPtr h, int timeoutMs) {
        int hits = 0;
        int started = Environment.TickCount;
        while (unchecked(Environment.TickCount - started) < timeoutMs) {
            IntPtr res;
            // SMTO_ABORTIFHUNG | SMTO_BLOCK
            if (SendMessageTimeoutW(h, 0x0000, IntPtr.Zero, IntPtr.Zero, 0x0002 | 0x0001, 200, out res) != IntPtr.Zero) {
                if (++hits >= 2) return true;
            } else hits = 0;
            Thread.Sleep(30);
        }
        return false;
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

    // ================= a window that is NOT the app's =================
    // A hidden STATIC owned by the HARNESS process, created on the test
    // desktop. The fixture for "this handle is somebody else's window", which
    // an app-side guard can only be tested against with a real one: a made-up
    // handle answers "not a window" long before any ownership check runs, and
    // a window on the INTERACTIVE desktop answers the same way (handles are
    // not reachable across desktops), so neither can reach the guard at all.
    // No message pump is needed - a caller that is refused on ownership never
    // sends this window anything.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowExW(uint exStyle, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);

    public long ForeignWindow() {
        return (long)Run(delegate() {
            IntPtr h = CreateWindowExW(0, "STATIC", "ghoztty-test-foreign",
                                       0x80000000, 0, 0, 10, 10,
                                       IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (h == IntPtr.Zero) LastError = "CreateWindowExW failed: " + Marshal.GetLastWin32Error();
            return h.ToInt64();
        });
    }

    // Same thread that created it: DestroyWindow refuses a window owned by
    // another thread.
    public bool CloseForeignWindow(long h) {
        return (bool)Run(delegate() { return DestroyWindow(new IntPtr(h)); });
    }

    // ================= capture =================
    // PrintWindow(PW_RENDERFULLCONTENT) is the ONLY capture that works on a
    // background desktop: DWM composes the input desktop only, so BitBlt off
    // the desktop DC (== Graphics.CopyFromScreen) returns false there.
    // Returns { hbitmap, width, height, left, top }; hbitmap is handed to
    // Image.FromHbitmap on the caller's side and freed by ReleaseCapture.
    public long[] CaptureWindow(IntPtr h) { return CaptureWindowMode(h, false); }

    // The SYNCHRONOUS capture (T835). `PrintWindow` with no flags takes the
    // WM_PRINT -> WM_PRINTCLIENT path, so the window itself draws the frame
    // into our DC before the call returns and the bitmap is exactly what its
    // paint produced. PW_RENDERFULLCONTENT instead asks DWM for a copy of the
    // composited surface, and that copy is ASYNCHRONOUS: three back-to-back
    // captures of one unchanged banner overlay read its table's value text as
    // ending at 1062, 1283 and 1179 px while the app's own paint logged the
    // identical line end (1290) every time. Any pixel assertion over such a
    // capture is a coin flip - which is what made pane-banner.ps1 fail about
    // one run in three and read as a rendering bug in the app.
    //
    // The cost of "synchronous" is that this is a cross-process SendMessage on
    // the one worker thread the whole harness marshals through, so an app whose
    // GUI thread is wedged hangs the capture instead of failing it. That is the
    // trade this file usually refuses (see the SendMessageTimeout note above),
    // and it is taken here because a wedged GUI is already a failed run, while
    // a torn capture is a green one that proves nothing.
    //
    // It is OPT-IN because it only works on a window whose WndProc answers
    // WM_PRINTCLIENT. When one does not, the client area comes back untouched:
    // the bitmap is pre-filled with a sentinel and a capture that is still
    // entirely sentinel FAILS rather than handing back a blank frame to assert
    // against. Add the handler to that window instead of falling back quietly.
    public long[] CaptureWindowSync(IntPtr h) { return CaptureWindowMode(h, true); }

    long[] CaptureWindowMode(IntPtr h, bool sync) {
        return (long[])Run(delegate() {
            RECT r;
            if (!GetWindowRect(h, out r)) { LastError = "GetWindowRect failed"; return new long[] { 0, 0, 0, 0, 0 }; }
            int w = r.right - r.left, ht = r.bottom - r.top;
            if (w <= 0 || ht <= 0) { LastError = "empty window rect"; return new long[] { 0, 0, 0, 0, 0 }; }
            IntPtr hdcWin = GetDC(h);
            IntPtr hdcMem = CreateCompatibleDC(hdcWin);
            IntPtr hbmp = CreateCompatibleBitmap(hdcWin, w, ht);
            IntPtr old = SelectObject(hdcMem, hbmp);
            if (sync) {
                RECT all = new RECT(); all.left = 0; all.top = 0; all.right = w; all.bottom = ht;
                IntPtr brush = CreateSolidBrush(SENTINEL);
                FillRect(hdcMem, ref all, brush);
                DeleteObject(brush);
            }
            bool ok = PrintWindow(h, hdcMem, sync ? 0u : PW_RENDERFULLCONTENT);
            bool blank = false;
            if (ok && sync) blank = AllSentinel(hdcMem, w, ht);
            SelectObject(hdcMem, old);
            DeleteDC(hdcMem);
            ReleaseDC(h, hdcWin);
            if (!ok) { DeleteObject(hbmp); LastError = "PrintWindow failed"; return new long[] { 0, 0, 0, 0, 0 }; }
            if (blank) {
                DeleteObject(hbmp);
                LastError = "WM_PRINTCLIENT drew nothing: this window cannot be captured synchronously";
                return new long[] { 0, 0, 0, 0, 0 };
            }
            return new long[] { hbmp.ToInt64(), w, ht, r.left, r.top };
        });
    }

    // A colour nothing in the chrome paints, so "still sentinel" means "not
    // drawn" rather than "drawn this colour".
    const uint SENTINEL = 0x00FF00FF;

    static bool AllSentinel(IntPtr hdc, int w, int ht) {
        for (int gy = 0; gy < 8; gy++) {
            for (int gx = 0; gx < 8; gx++) {
                int x = (int)((gx + 0.5) * w / 8.0);
                int y = (int)((gy + 0.5) * ht / 8.0);
                if (x >= w) x = w - 1;
                if (y >= ht) y = ht - 1;
                if (GetPixel(hdc, x, y) != SENTINEL) return false;
            }
        }
        return true;
    }

    public void ReleaseCapture(long hbmp) {
        if (hbmp != 0) DeleteObject(new IntPtr(hbmp));
    }


    // NOT here, deliberately (T1031): a WM_ERASEBKGND probe that hands the
    // window a DC THIS process created. It was written, it went green, and the
    // teeth check exposed it as vacuous - an HDC is a per-process handle, so
    // the app's `FillRect` was writing into a handle that means nothing on its
    // side and the assertion passed whether the fix was in or out. There is no
    // fixing it from here; a paint decision made in another process has to be
    // reported BY that process. resize-flicker.ps1 reads it out of the debug
    // build's stderr instead ("surface erase ... fill=").

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

Launching ghoztty.exe ALSO runs the build-mode pre-flight (T1033): a non-debug
zig-out derives the endpoints the user's installed Ghoztty owns, and a test
desktop does not change that - the launched app dials the user's agent and
writes the user's state files, off-screen where nobody sees it happen. 80 GUI
scripts reach the app through this one helper and none of them asked, so the
gate rides the launch rather than 80 copies of one line. -AllowReleaseBuild is
the same explicit opt-in Reset-GhozttyTestState takes, for a script whose
SUBJECT is a release build. It runs before the desktop is resolved so the
refusal costs nothing and speaks first.
#>
function Start-OnTestDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [string]$StdErr,
        [switch]$KeepWindowPlacement,
        [switch]$AllowReleaseBuild,
        $Desktop
    )
    if ((Split-Path -Leaf $Exe) -ieq 'ghoztty.exe') {
        Assert-GhozttyIsolatedBuild -Exe $Exe -Allow:$AllowReleaseBuild | Out-Null
    }
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

<#
Run a CLI invocation ON the test desktop and WAIT for it, the way `& $Exe +verb`
runs one on the caller's. Returns { ExitCode, Output, Pid, TimedOut }.

WHY THIS EXISTS (T1193). `Start-OnTestDesktop` covers the GUI half of a script -
the app itself. It does not cover the other half, and for 50 scripts the other
half WAS the script: they never launched a window handle at all, they drove the
app with `& $Exe +new-window --target=...` and read `+list`. `+new-window` is
the one verb that auto-launches (`performIpc` in `src\apprt\win32\App.zig`
answers `error.NoRunningInstance` by spawning the app, and does it for no other
verb), and the app it spawns inherits the desktop of the CLI process that
spawned it. Run the CLI here and the window lands on the test desktop; run it
with `&` and it lands on whatever the user is reading. Measured on box
2026-09-01: a cold `+new-window` through this helper put both the startup window
and the named one on the test desktop, and no ghoztty process reported a
MainWindowHandle to the user's session.

Output is stdout AND stderr, interleaved into one file the way the child wrote
them - `StartProcess` points both handles at the same file - so a caller that
used `2>&1` keeps what it had. It comes back as a single string, `''` when the
child printed nothing.

`-TimeoutSec` bounds a CLI that never returns; the child is terminated and
`TimedOut` is $true, which a caller should assert on rather than reading an
exit code that means nothing. The default is generous because a COLD auto-launch
on a busy box is slow by design (`ipc_timeout.auto_launch_ms`).
#>
function Invoke-OnTestDesktop {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSec = 60,
        [switch]$KeepWindowPlacement,
        [switch]$AllowReleaseBuild,
        $Desktop
    )
    if ((Split-Path -Leaf $Exe) -ieq 'ghoztty.exe') {
        Assert-GhozttyIsolatedBuild -Exe $Exe -Allow:$AllowReleaseBuild | Out-Null
    }
    $td = Resolve-TestDesktop $Desktop
    if (-not $KeepWindowPlacement -and (Split-Path -Leaf $Exe) -ieq 'ghoztty.exe') {
        Clear-TestWindowPlacement | Out-Null
    }
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $out = Join-Path $env:TEMP ("ghoztty-testdesk-cli-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
        $res = $td.RunProcess($Exe, $argLine, $WorkingDirectory, $out, [int]($TimeoutSec * 1000))
        if ([string]::IsNullOrEmpty($res)) { throw "Invoke-OnTestDesktop failed: $($td.LastError)" }
        $parts = $res -split ':'
        $text = ''
        if (Test-Path -LiteralPath $out) {
            $text = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
            if ($null -eq $text) { $text = '' }
        }
        $procId = [int]$parts[1]
        # A CLI that auto-launched the app leaves the GUI behind on purpose, and
        # it is the GUI - not this CLI - that the desktop's leak check should
        # see. Record the pid anyway: an auto-launch makes the app a CHILD of
        # this process, so a script that only ever used this helper still has
        # something to reap.
        $script:GhozttyTestDesktopAllPids += $procId
        return [pscustomobject]@{
            ExitCode = [int]$parts[0]
            Output   = $text
            Pid      = $procId
            TimedOut = ($parts[2] -eq 'timeout')
        }
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
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
        # 0 (or negative) enumerates EVERY process's top-levels on the desktop.
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

<#
The app's MESSAGE-ONLY window (class 'GhozttyMsg' by default), owned by
-ProcessId. Returns IntPtr::Zero when the process has none.

A message-only window carries the app's private WM_APP protocol - the tray
callback among them - and is invisible to every EnumWindows-based finder here,
so this is the only way to name one. -ProcessId is MANDATORY and filtered on
inside the search: message-only windows are not isolated by the test desktop
the way top-level windows are, so an unfiltered find can return the user's own
running Ghoztty and a posted WM_APP message would then drive their terminal.
#>
function Find-TestMessageWindow {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        $Class = 'GhozttyMsg',
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    return $td.FindMessageWindow((ConvertTo-TestFilter $Class), [uint32]$ProcessId)
}

<#
A window's rectangle in SCREEN coordinates - BOTH forms (T327).

    $wr = Get-TestWindowRect -Window $h            # the whole window
    $cr = Get-TestWindowRect -Window $h -Client    # its client area

-Client does NOT mean "client coordinates". It selects which RECTANGLE you
get - the client area rather than the frame - and returns it in the same
screen space as the other form, so `$cr.Left`/`$cr.Top` are the client
origin's position ON SCREEN and are exactly what an offset inside the client
is added to. A client rect that started at 0,0 would be useless here, since
everything downstream of this function is screen-space too.

That is deliberate, because it is what makes the two units line up: what
this returns is what Send-TestMouse, Get-TestMouseRoute and the pixel probes
all take. `$cr.Left + 40` is a screen point 40px inside the client, and it
can be passed to any of them unconverted.

The naming trap is real and has cost a red run: a local called `$cx`/`$cy`
built from `($r.Left + $r.Right) / 2` is a screen coordinate no matter what
it is called. Read the derivation, not the name.
#>
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

# A control's ID - the app's OWN name for it (GetDlgCtrlID). 0 when the creator
# passed no id, which is how a STATIC that is only ever painted looks. Prefer
# this over a label or a position when asking "which control is this": a label
# is a product decision (and is often what the test asserts), and a position
# moves the moment a neighbour is added - see lib\ChooserControls.ps1.
function Get-TestControlId {
    param([Parameter(Mandatory = $true)][IntPtr]$Control, $Desktop)
    return (Resolve-TestDesktop $Desktop).CtrlId($Control)
}

<#
Every descendant of `$Window` with class `$Class`, as
{Hwnd, Id, Text, Left, Top, Right, Bottom, Width, Height, Visible, Enabled,
Class} - so a control can be found by its ID, its LABEL or its GEOMETRY instead
of by creation order.

`Text` comes from WM_GETTEXT (`Get-TestControlText`), never GetWindowTextW: the
latter reads a cross-process CACHE and goes stale for a label the app just
changed in place, and "the label changed" is a claim several scripts make.

Hidden controls are INCLUDED and `Visible` reports the state, because a dialog
that hides rather than destroys (the chooser does, in three places) makes "is it
hidden" a result a test needs to read. Pass -VisibleOnly for "what is on
screen".

Four scripts each kept a private copy of this (T294); it is one function now.
#>
# The HWND of a control object (from Get-TestControls / the Get-Chooser*
# lookups), or IntPtr::Zero when there is no such control. The zero rather than
# a $null is deliberate: it binds to the [IntPtr] parameters of every other
# function here, so "the control is missing" flows through a script the same way
# it always did instead of failing at parameter binding with a type error.
function ConvertTo-TestHwnd {
    param($Control)
    if ($null -eq $Control) { return [IntPtr]::Zero }
    return [IntPtr]$Control.Hwnd
}

function Get-TestControls {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [string]$Class = '*',
        [switch]$VisibleOnly,
        $Desktop
    )
    if ($Window -eq [IntPtr]::Zero) { return @() }
    return @(Get-TestChildWindows -Window $Window -Class $Class -Desktop $Desktop |
        Where-Object { -not $VisibleOnly -or $_.Visible } | ForEach-Object {
            $h = [IntPtr]$_.Hwnd
            [pscustomobject]@{
                Hwnd    = $h
                Id      = (Get-TestControlId -Control $h -Desktop $Desktop)
                Text    = (Get-TestControlText -Control $h -Desktop $Desktop)
                Left    = $_.Left; Top = $_.Top; Right = $_.Right; Bottom = $_.Bottom
                Width   = $_.Width; Height = $_.Height
                Visible = $_.Visible
                Enabled = (Test-TestWindowEnabled -Window $h -Desktop $Desktop)
                Class   = $_.Class
            }
        })
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
#
# The pin is LEDGERED (T179), so a probe cannot leave a window topmost even if
# the script that pinned it dies: Remove-TestDesktop restores it, and so does
# the PowerShell.Exiting handler armed at the bottom of this file. This is the
# only supported way to topmost a window from a test - a raw
# SetWindowPos(h, HWND_TOPMOST, ...) is unledgered and is exactly the idiom
# that manufactured T142's phantom bug. `probe-topmost-restore.ps1` fails the
# suite if one reappears.
function Set-TestWindowTopmost {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [bool]$On = $true,
        $Desktop
    )
    return (Resolve-TestDesktop $Desktop).SetTopmost($Window, $On)
}

# Put back every probe-pinned window that is still pinned. Returns the hwnds it
# had to put back - each one a leak the run would otherwise have left behind.
# Idempotent, needs no bound desktop, and is called for you by
# Remove-TestDesktop and on interpreter exit; call it directly only when you
# want the answer mid-run.
function Restore-TestWindowTopmost {
    $raw = [GhozttyTestDesktop]::RestoreTopmost()
    return @($raw.Split(',') | Where-Object { $_ } | ForEach-Object { [int64]$_ })
}

# Every window the restore has had to put back this run. Read it AFTER the
# cleanup, the way the foreground-watch leak assertion is read - Remove-Test-
# Desktop does the restoring, so a check that runs before it scores nothing:
#
#     $stray = @(Get-TestTopmostRestored)
#     Assert ($stray.Count -eq 0) "no probe left a window topmost ($($stray -join ','))"
function Get-TestTopmostRestored {
    $raw = [GhozttyTestDesktop]::RestoredTopmost()
    return @($raw.Split(',') | Where-Object { $_ } | ForEach-Object { [int64]$_ })
}

# Windows a probe has pinned and NOT yet put back. The harness's own oracle;
# scripts assert on Get-TestTopmostRestored instead.
function Get-TestTopmostPending {
    $raw = [GhozttyTestDesktop]::PendingTopmost()
    return @($raw.Split(',') | Where-Object { $_ } | ForEach-Object { [int64]$_ })
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
# A chord posted at a viewer pane's Chromium input child. CHOOSE THE KEY WITH
# CARE (T682): most bare F-keys are Chromium's OWN accelerators and never reach
# a page keydown - F1 help, F3 find, F5 reload, F6 address bar, F7 caret
# browsing, F10 menu, F11 fullscreen, F12 devtools. F10 is the nasty one: it
# MOVES the browser's focus, so every chord posted after one silently lands
# nowhere and a script full of "the page did not see X" assertions passes for
# free. F2/F4/F8/F9 are inert. When a claim rests on a chord NOT arriving
# somewhere, prove it arrived at all first - the `accel key vk=…` debug line
# from ViewerPane.onAcceleratorKeyPressed is logged for every chord WebView2
# hands us, claimed or not (viewer-window-chords.ps1's Send-AtViewer).
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

<#
The same chord, pressed at an app too BUSY to answer at once (T1104).

    Send-TestViewerChordStarved -Window $top -Target $chromiumChild -Modifiers ctrl -Key T

Suspends the app's UI thread across the keystroke - Chromium blocks against it
exactly as it does against a busy app - while holding the modifiers down the
whole time, which is what a real finger does. The chord must still land. It is
the regression guard for the harness bug that dropped faked modifiers on a
fixed timer and made every modified chord a race against box load.

Keep -StarveMs modest. The app is genuinely frozen for that long.
#>
function Send-TestViewerChordStarved {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][IntPtr]$Target,
        [Parameter(Mandatory = $true)][string]$Key,
        [string[]]$Modifiers = @(),
        [int]$HoldMs = 40,
        [int]$StarveMs = 500,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $mods = @($Modifiers | ForEach-Object { ConvertTo-TestVk $_ })
    return $td.SendChordCrossStarved($Window, $Target, [uint16[]]$mods, (ConvertTo-TestVk $Key), $HoldMs, $StarveMs)
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
T255. The hwnd of a MODAL dialog the app has put in front of $Window, or
IntPtr::Zero when there is none.

This is the answer to "why does this window ignore everything I post at it".
`ConfirmDialog.show` calls `EnableWindow(owner, FALSE)` for the length of its
own message loop, and a DISABLED window is one `DefWindowProc` discards every
`WM_SYSCOMMAND` for - so SC_MINIMIZE / SC_MAXIMIZE / SC_RESTORE / SC_CLOSE all
become no-ops while it is up, and a second WM_CLOSE only re-enters
`confirmCloseIfNeeded` and raises another one. Meanwhile `WM_NCHITTEST`,
`WM_PAINT` and our own `WM_NCLBUTTONDOWN` handler all keep answering, because
the thread is pumping perfectly well. The window is not wedged; it is blocked.

On the INTERACTIVE desktop that state is obvious - there is a dialog on screen.
On a background test desktop nobody sees it, which is how it read for a while
as "this desktop cannot adjudicate window state" (the original T255 report).
Measured: a pane whose shell has a child process ("ping -n 60 127.0.0.1")
answers WM_CLOSE with enabled=False + a GhozttyConfirmDialog and ignores
SC_MINIMIZE; dismiss the dialog and the same SC_MINIMIZE iconifies the window.

Identified by BEHAVIOUR, not by class - so it finds the confirm dialog, the
rename dialog and anything else modal, with no list to keep in sync:

  1. the window must be DISABLED. That is what "blocked" means here, and it
     is the whole reason the posted commands vanish.
  2. among its owned, visible top-levels, the blocker is one that can take
     ACTIVATION. Every overlay this app owns - the scrollbar, the banner, the
     dim layer, the key-state indicator - is a visible owned popup too, and
     they are all WS_EX_NOACTIVATE precisely so they never steal focus. A
     window that cannot be activated cannot be the thing holding a modal
     loop, so that bit is the discriminator rather than a class allowlist.
#>
function Get-TestModalBlocker {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    if (-not (Test-TestWindowExists -Window $Window -Desktop $Desktop)) { return [IntPtr]::Zero }
    if (Test-TestWindowEnabled -Window $Window -Desktop $Desktop) { return [IntPtr]::Zero }
    $WS_EX_NOACTIVATE = 0x08000000
    # ProcessId 0 = every process on the desktop. An owned dialog belongs to
    # the same process in practice, but the owner test is the real filter and
    # asking for all of them keeps this honest if that ever stops being true.
    foreach ($w in (Get-TestWindows -ProcessId 0 -Class '*' -Desktop $Desktop)) {
        $h = [IntPtr]$w.Hwnd
        if ($h -eq $Window) { continue }
        if ((Get-TestWindowOwner -Window $h -Desktop $Desktop) -ne $Window) { continue }
        if (((Get-TestWindowStyle -Window $h -ExStyle -Desktop $Desktop) -band $WS_EX_NOACTIVATE) -ne 0) { continue }
        return $h
    }
    return [IntPtr]::Zero
}

<#
T255. Clear whatever modal dialog is blocking $Window and hand back what was
found, so a test can drive window state instead of guessing why it cannot.

Returns a string: 'none' (nothing was blocking), or "<class>" of the dialog it
dismissed, or "<class>:stuck" if the dialog outlived the dismissal. Answering
with the class rather than a bool is deliberate - a script that had to clear a
dialog should be able to SAY which one in its output, because a confirm dialog
appearing where none was expected is itself a finding.

-Answer cancel (the default) posts WM_CLOSE, which every dialog here treats as
its cancel path, so the blocked window is left in the state the test set up.
-Answer ok presses the default button instead, for a test that WANTS the
confirmed action to proceed.
#>
function Clear-TestModalBlocker {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [ValidateSet('cancel', 'ok')][string]$Answer = 'cancel',
        [int]$TimeoutMs = 3000,
        $Desktop
    )
    $dlg = Get-TestModalBlocker -Window $Window -Desktop $Desktop
    if ($dlg -eq [IntPtr]::Zero) { return 'none' }
    $cls = Get-TestWindowClass -Window $dlg -Desktop $Desktop
    if ($Answer -eq 'ok') {
        # IDOK through the dialog's own command path. WM_CLOSE would cancel.
        Send-TestKeys -Window $dlg -Key 'RETURN' -Desktop $Desktop | Out-Null
    } else {
        Send-TestWindowClose -Window $dlg -Desktop $Desktop | Out-Null
    }
    $deadline = [Environment]::TickCount + $TimeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        if (-not (Test-TestWindowExists -Window $dlg -Desktop $Desktop)) { return $cls }
        Start-Sleep -Milliseconds 100
    }
    return "${cls}:stuck"
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

-WParam/-LParam are passed through VERBATIM: nothing here packs a point or
converts a coordinate space (T327), so a message that carries one is the
caller's to encode, in whatever space that message defines. The WM_APP
protocol this exists for carries no coordinates at all.
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

    Send-TestMouse -Window $top -Target $pane -X $sx -Y $sy -Button right
    Send-TestMouse -Window $top -Target $tabstrip -X $x -Y $y -Action down
    Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move

-X/-Y ARE SCREEN COORDINATES, and this function does the conversion (T327):
it SetCursorPos'es the point and then ScreenToClient's it per target to build
the lparam. Hand it client coordinates and they are converted a SECOND time,
landing the click one client origin up and to the left of where you aimed -
usually outside the control entirely. That is a silent miss, not an error:
the post succeeds, this returns $true, and the assertion after it fails
against a feature that works, which sends you looking in the app. It cost
T318 exactly that (a Kill button that opened nothing because the click never
reached it).

Get the point from Get-TestWindowRect, whose BOTH forms are screen-space -
`-Client` picks the client RECTANGLE, still positioned on screen - so an
offset inside a control is `$r.Left + 40`, never a bare `40`. Get-TestPixel
and the Find-/Test-ExactPixel probes are screen-space too, so a point read
off a capture can be clicked as-is.

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
word-select it was meant to trigger never happens (measured in T218). On the
non-client path the DBLCLK form is always sent, because CS_DBLCLKS governs
client double-clicks only.

CLIENT OR NON-CLIENT IS DECIDED THE WAY WINDOWS DECIDES IT (T263): the target
is asked WM_NCHITTEST at the point first, and an answer other than HTCLIENT
delivers the WM_NC* twin (WM_NCLBUTTONDOWN & co.) with the hit code in wparam
and the SCREEN point in lparam. That is what makes a caption-band click - the
"..." menu button, minimize, close, since T254 all client PIXELS the window
claims back through its hit test - actually reach a handler. Use -Client to
force the client message anyway, for a test whose subject IS that path.

Two consequences worth knowing:

  * HTNOWHERE / HTTRANSPARENT / HTERROR keep the client delivery, because all
    three mean "not me" and this harness posts to the hwnd you NAME.
  * A down on HTCAPTION hands DefWindowProc a window-drag, exactly as a real
    press on the title area does. Aim at a button, or expect a move loop.
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
        [switch]$Client,
        $Desktop
    )
    $td = Resolve-TestDesktop $Desktop
    $b = switch ($Button) { 'left' { 0 } 'right' { 1 } 'middle' { 2 } }
    $a = switch ($Action) {
        'move' { 0 } 'down' { 1 } 'up' { 2 } 'click' { 3 } 'doubleclick' { 4 } 'wheel' { 5 }
    }
    $mods = @($Modifiers | ForEach-Object { ConvertTo-TestVk $_ })
    # GHOZTTY_TEST_MOUSE_CLIENT=1 forces every click through the client path,
    # i.e. reproduces the pre-T263 harness from this same tree. That is the
    # one-command answer to "did the routing break this script?" for a script
    # that is not about routing at all - and it is how T263 established that
    # tab-strip.ps1's failures were already there.
    $clientOnly = $Client -or ($env:GHOZTTY_TEST_MOUSE_CLIENT -eq '1')
    return $td.MouseEvent($Window, $Target, $X, $Y, $b, $a, $HoldMs, [uint16[]]$mods, $Delta, [bool]$clientOnly)
}

<#
The routing Send-TestMouse will use at a SCREEN point - the target's own answer
to WM_NCHITTEST, plus whether that makes the click non-client (T263).

    $r = Get-TestMouseRoute -Window $top -X $sx -Y $sy
    $r.Code        # 8 (HTMINBUTTON)
    $r.NonClient   # $true

This is the DECISION, not a guess at it: Send-TestMouse asks the same question
of the same window. Assert it when a script wants to say "this point is the
minimize button" before clicking, so a button that moved reads as a moved
button rather than as an action that did not happen.

A window that does not answer within 1.5s is reported HTCLIENT, which is the
delivery a wedged app gets anyway.
#>
function Get-TestMouseRoute {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [IntPtr]$Target = [IntPtr]::Zero,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        $Desktop
    )
    $code = [int](Resolve-TestDesktop $Desktop).MouseRoute($Window, $Target, $X, $Y)
    # Mirrors Native.IsNonClientCode: HTNOWHERE(0) / HTTRANSPARENT(-1) /
    # HTERROR(-2) all mean "not me", so they keep the client delivery.
    [pscustomobject]@{
        Code      = $code
        NonClient = ($code -ne 1 -and $code -ne 0 -and $code -ne -1 -and $code -ne -2)
    }
}

<#
Hammer unpaced left down/up pairs round-robin across several targets.

    Send-TestClickStorm -Targets $surfaces -Rounds 500

This is a LOAD SHAPE, not a gesture. Send-TestMouse settles ~100ms per click
so the app can act on it; a deadlock repro needs focus changes arriving faster
than the GUI thread drains them, which the same 1500 clicks through
Send-TestMouse would stretch to about four minutes.

THIS FUNCTION's -X/-Y are CLIENT coordinates, and it is the exception (T327):
one point is posted to every target as-is, and the targets are different
windows, so there is no single screen point that is inside all of them. The
default is a point inside any surface. Send-TestMouse next door takes SCREEN
coordinates and converts them itself - the two do not share a convention, so
do not carry a point from one to the other unconverted.

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

# HOVERED-FRAME CAPTURE (`Get-TestHoverCapture`, T282), dot-sourced for the
# same reason: a hover fill is unassertable from out here at any speed - the
# leave is posted within a frame and WM_PAINT is the lowest-priority message,
# so the frame that gets painted is always the un-hovered one (see the file's
# header, and route H in the CAPTURE LIMIT section above). Every GUI script
# that loads this file gets it, because a control that lights on hover is
# everywhere in this chrome and the workaround for the missing frame was
# per-site.
. (Join-Path $PSScriptRoot 'HoverCapture.ps1')

# WHICH CONTROL IS WHICH in the machine chooser (`Get-ChooserControl` and
# friends, T294), dot-sourced for the reason ChromeGeometry.ps1 is: seven
# scripts drive that dialog and each one kept a private copy of "find the
# management button", so one new button in the detail pane's action row (T177's
# Activity) silently made two of them click the wrong control. Identification is
# by the app's own control ID, so a relabel, a move or a new neighbour cannot
# reach it.
. (Join-Path $PSScriptRoot 'ChooserControls.ps1')

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

ALSO REFUSES A UNIFORM CAPTURE (T303). The class refusal above guards exactly
one window; the SAME flat fill comes back from every WinUI/XAML window, and
that family is most of the Win11 shell. PrintWindow on Task Manager's main
window returned a flat black 1379x1134 bitmap - one distinct color - and
reported SUCCESS, and a vertical-seam scan over it then found no seams, which
reads as "this app has no seam" rather than "there is no capture". So a capture
of a non-trivial window whose whole interior is one color is refused after the
fact, since there is no class list that could have predicted it. It RETRIES
first (-UniformTimeoutMs), because the other way a capture comes back uniform
is a window that has not painted yet - transient, where composition is
permanent - and the retry is what tells the two apart. -AllowUniform is the
opt-in, and it is separate from -AllowTerminalSurface on purpose: measuring the
terminal flat fill needs both, so neither switch quietly disarms the other.

-Sync captures through WM_PRINTCLIENT instead of DWM (T835). USE IT FOR EVERY
PIXEL ASSERTION on chrome that answers that message: the default DWM copy is
asynchronous and returns torn frames, so a measurement over it is a coin flip.
Three back-to-back default captures of one unchanged banner overlay put the end
of the same table row at 1062, 1283 and 1179 px while the app logged an
identical paint each time - a rendering bug that was never in the app. -Sync
throws on a window with no WM_PRINTCLIENT handler rather than returning the
blank frame such a window prints, so the answer there is to add the handler.
#>
<#
A hidden window on the test desktop that belongs to the HARNESS process, not
to the app under test.

    $foreign = New-TestForeignWindow
    ...
    Remove-TestForeignWindow $foreign

The fixture for an app-side "that handle is not mine" guard (T282's
`capture-hover`). It has to be a REAL window in another process: a made-up
handle is refused as "not a window" before any ownership check runs, and a
window on the INTERACTIVE desktop is refused the same way, since handles are
not reachable across desktops. Neither reaches the guard.

Returns [IntPtr]::Zero if the window could not be created.
#>
function New-TestForeignWindow {
    param($Desktop)
    $td = Resolve-TestDesktop $Desktop
    return [IntPtr]($td.ForeignWindow())
}

function Remove-TestForeignWindow {
    param([Parameter(Mandatory = $true)][IntPtr]$Window, $Desktop)
    if ($Window -eq [IntPtr]::Zero) { return $false }
    return (Resolve-TestDesktop $Desktop).CloseForeignWindow([int64]$Window)
}

<#
Is this capture a flat fill - one color over its whole interior?

The two ways that happens are told apart by TIME, not by looking at the bitmap:
a WinUI/XAML window composites through DirectComposition and never paints into
the window DC, so it is uniform forever; a window caught mid-paint is uniform
for a few hundred milliseconds. Get-TestWindowPixels uses this in a retry loop
for exactly that reason.

A trivially small window is exempt: a 16x16 tool window really can be one
color, and a guard that fires on it is noise.
#>
function Test-TestCaptureUniform {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int]$Inset = 8,
        [int]$MinSide = 64,
        [int]$Samples = 24
    )
    if ($Shot.Width -lt $MinSide -or $Shot.Height -lt $MinSide) { return $false }
    $x1 = $Shot.Width - $Inset
    $y1 = $Shot.Height - $Inset
    if ($x1 -le $Inset -or $y1 -le $Inset) { return $false }
    $stepX = [math]::Max(1, [int](($x1 - $Inset) / $Samples))
    $stepY = [math]::Max(1, [int](($y1 - $Inset) / $Samples))
    $first = $null
    for ($y = $Inset; $y -lt $y1; $y += $stepY) {
        for ($x = $Inset; $x -lt $x1; $x += $stepX) {
            $c = $Shot.Bitmap.GetPixel($x, $y)
            if ($null -eq $first) { $first = $c; continue }
            if ($c.R -ne $first.R -or $c.G -ne $first.G -or $c.B -ne $first.B) { return $false }
        }
    }
    return $true
}

<#
How much is in this capture? Test-TestCaptureUniform above answers the binary
question - is EVERY sampled pixel the same color - and a capture only has to
keep one stray pixel to slip past it. This answers the same question as a pair
of NUMBERS, so "the capture collapsed" is something a script can assert a floor
against instead of eyeballing a file size afterwards.

T1128: `hero-mode.ps1` saved a window shot on every run and asserted nothing
about it, and the saved file quietly went from 133921 to 41165 bytes - the
signature of an image that has lost most of its content - while the run scored
ALL PASS. A byte count is not available to the script that took the picture;
these two numbers are.

  Distinct  - how many distinct colors the grid sampled.
  TopShare  - the fraction of samples that are the single most common color.

A blank capture is `Distinct = 1, TopShare = 1.0`. Real window chrome over a
surface PrintWindow could not read scores around 23 / 0.60 (measured on this
box, 2026-09-02); a fully painted window of the same size scores 87 / 0.57. So
a floor of `Distinct >= 8` with `TopShare <= 0.90` separates "the capture died"
from "a known region of this window does not capture", which is a documented
limit and must not read as a regression.

Sampled on a grid rather than every pixel: GetPixel is a per-call marshal, and
2400 of them is milliseconds where 1.26M is a visible pause in every run.
#>
function Get-TestCaptureContent {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int]$Inset = 8,
        [int]$Samples = 48
    )
    $x1 = $Shot.Width - $Inset
    $y1 = $Shot.Height - $Inset
    if ($x1 -le $Inset -or $y1 -le $Inset) {
        return [pscustomobject]@{ Distinct = 0; TopShare = 1.0; Sampled = 0 }
    }
    $stepX = [math]::Max(1, [int](($x1 - $Inset) / $Samples))
    $stepY = [math]::Max(1, [int](($y1 - $Inset) / $Samples))
    $hist = @{}
    $n = 0
    for ($y = $Inset; $y -lt $y1; $y += $stepY) {
        for ($x = $Inset; $x -lt $x1; $x += $stepX) {
            $c = $Shot.Bitmap.GetPixel($x, $y).ToArgb()
            $n++
            if ($hist.ContainsKey($c)) { $hist[$c]++ } else { $hist[$c] = 1 }
        }
    }
    if ($n -eq 0) { return [pscustomobject]@{ Distinct = 0; TopShare = 1.0; Sampled = 0 } }
    $top = ($hist.Values | Measure-Object -Maximum).Maximum
    return [pscustomobject]@{
        Distinct = $hist.Count
        TopShare = [double]$top / $n
        Sampled  = $n
    }
}

function Get-TestWindowPixels {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        $Desktop,
        [switch]$AllowTerminalSurface,
        [switch]$AllowUniform,
        [switch]$Sync,
        # Long enough to outlast a mid-paint window by a wide margin (T216
        # measured a context menu solid at 350ms and painted at 400ms), and to
        # stay inside the retry budget the scripts that poll for real content
        # already allow themselves - tab-color.ps1 gives a window 20 tries at
        # 150ms. A guard that fails faster than the callers' own patience would
        # turn a slow paint into a red run, which is the opposite of the job.
        [int]$UniformTimeoutMs = 2000
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
    $deadline = [datetime]::UtcNow.AddMilliseconds($UniformTimeoutMs)
    $attempts = 0
    while ($true) {
        $r = if ($Sync) { $td.CaptureWindowSync($Window) } else { $td.CaptureWindow($Window) }
        if ($r[0] -eq 0) { throw "Get-TestWindowPixels failed: $($td.LastError)" }
        $hbmp = [IntPtr]$r[0]
        try {
            $bmp = [System.Drawing.Image]::FromHbitmap($hbmp)
        } finally {
            $td.ReleaseCapture($r[0])
        }
        $shot = [pscustomobject]@{
            Bitmap = $bmp; Width = [int]$r[1]; Height = [int]$r[2]
            Left = [int]$r[3]; Top = [int]$r[4]
        }
        $attempts++
        if ($AllowUniform -or -not (Test-TestCaptureUniform -Shot $shot)) { return $shot }
        $bmp.Dispose()
        if ([datetime]::UtcNow -ge $deadline) {
            throw ("Get-TestWindowPixels: the capture is UNIFORM - $($shot.Width)x$($shot.Height), one " +
                   "color over its whole interior, still uniform after $attempts attempt(s) across " +
                   "${UniformTimeoutMs}ms. That is not a picture of the window; it is what PrintWindow " +
                   "returns when there is nothing GDI-painted to copy, and it is a perfectly valid " +
                   "bitmap that 'is it dark?' assertions pass against for free (T303). The usual cause " +
                   "is a WinUI/XAML window - Settings, Task Manager, most of the Win11 shell - which " +
                   "composites through DirectComposition and never paints into the window DC: " +
                   "PrintWindow sees GDI, not composition. A Win11 app therefore cannot be a pixel " +
                   "REFERENCE at all; measure Windows metrics through SystemParametersInfoForDpi / " +
                   "GetSystemMetrics / uxtheme / DWM instead, and cite Fluent as documentation rather " +
                   "than as a measurement. The other cause is a window that had not painted yet, which " +
                   "is what the retries above rule out. See the CAPTURE LIMIT header. -AllowUniform is " +
                   "for measuring the limit itself.")
        }
        Start-Sleep -Milliseconds 150
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
#
# Un-pins any probe-injected WS_EX_TOPMOST FIRST (T179), before the processes
# are killed and while the handles are still real. Every GUI script already
# calls this from its `finally`, so the restore rides a path that a mid-run
# abort cannot skip - and a window this harness did not launch (the case that
# burned T142) is put back rather than dying with a process we own.
function Remove-TestDesktop {
    param($Desktop, [switch]$KeepProcesses)
    Restore-TestWindowTopmost | Out-Null
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

# T179: the last net under Remove-TestDesktop, for a script that pins a window
# and never reaches a `finally` at all. PowerShell.Exiting fires at the end of
# a `powershell -File` run - including after an `exit` inside a try, and after
# an unhandled terminating error - so a probe pin cannot outlive the
# interpreter that made it.
#
# The action calls the STATIC method rather than the wrapper function: an event
# action does not run in the dot-sourcing script's scope, so a function defined
# here may not be resolvable from it, while a loaded type always is. Armed once
# per session, and left visible to Get-EventSubscriber so the harness's own
# test can assert the net is actually there.
#
# The guard is a flag OF THIS FILE, not "is any PowerShell.Exiting subscriber
# armed" (T199): lib\HarnessLeak.ps1 arms its own handler on the same event, so
# a script that dot-sources that one first would have silently skipped this
# registration and lost the topmost net.
if (-not $global:GhozttyTestDesktopExitHooked) {
    Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
        [GhozttyTestDesktop]::RestoreTopmost() | Out-Null
    } | Out-Null
    $global:GhozttyTestDesktopExitHooked = $true
}
