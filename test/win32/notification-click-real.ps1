# T572 acceptance: a REAL click on a REAL Windows notification focuses the
# window that raised it.
#
# Why this script exists at all, and why it is not a section of
# notification-click-focus.ps1:
#
#   notification-click-focus.ps1 drives the ROUTING half, and it must - it runs
#   on the background test desktop (T218), where there is no shell, no
#   notification area and no toast. It POSTS WM_APP_TRAY itself, so by T240's
#   rule its 38 green assertions prove nothing about DELIVERY: whether the
#   shell really sends NIN_BALLOONUSERCLICK for our balloon when a human clicks
#   it. A test that synthesizes the trigger cannot validate the trigger.
#
#   T448 fixed the delivery defect (the balloon icon was never registered with
#   NIM_SETVERSION, so the shell kept it on its pre-5.0 behavior and the NIN_*
#   notifications were never sent at all) and left this half unwatched. This
#   script is that watch: it raises a real balloon, finds the toast the shell
#   drew, and clicks it with SendInput.
#
# INTERACTIVE-ONLY, AND NOT PART OF THE FLOOR. Balloons render on the input
# desktop and nowhere else, so this takes the user's foreground for a few
# seconds. It is declared in lib\TestDesktop.ps1's @input-desktop-exception
# list; scripts\floor-lane.ps1 and the P1-P3 sets do not run it.
#
# Cases:
#   1: pane in window A raises a notification, window B is made foreground, the
#      toast BODY is clicked - window A must come to the foreground.
#   2: the same raise, and the toast's DISMISS button is clicked instead - the
#      shell sends NIN_BALLOONHIDE, tray_notify.classify must not treat it as a
#      click, and the foreground must NOT move.
#
# -NegativeControl inverts case 1's assertion and MUST fail.
#
#   powershell -NoProfile -File test\win32\notification-click-real.ps1
#
# ---------------------------------------------------------------------------
# WHERE IT SKIPS, AND WHY THAT IS NOT A PASS (measured 2026-09-05, T572).
#
# This box shows NO desktop notifications at all: HKCU\...\PushNotifications
# ToastEnabled is 0 (Settings > System > Notifications, off). With it off, a
# stock System.Windows.Forms.NotifyIcon.ShowBalloonTip draws nothing either -
# confirmed by an EnumWindows diff AND by a CopyFromScreen of the notification
# corner, with the setting flipped on, WpnUserService restarted and explorer
# restarted. So there is no toast to click here, and this run is a declared
# SKIP naming the `desktop-toasts` capability rather than a red.
#
# TO TAKE THE OBSERVATION: turn Notifications on (Settings > System >
# Notifications), then run this script. It needs the interactive desktop, so
# run it from a session sitting on it, and expect the foreground to move about
# for ~20 seconds.
# ---------------------------------------------------------------------------
param([string]$ExePath, [switch]$NegativeControl)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE,
# ahead of any isolation setup, because it drops an inherited
# $GHOZTTY_IPC_SOCKET - a test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1100: the oracle is a PHYSICAL click on a shell-drawn toast, so this needs
# three things the box may not have - SendInput landing, a window it can bring
# to the foreground, and a shell that draws toasts at all. Asked BEFORE
# anything is launched: when the answer is no, this run is a declared SKIP with
# the capability named, never a red the product has to answer for.
. (Join-Path $PSScriptRoot 'lib\DesktopCapability.ps1')
Assert-TestDesktopCapability -Name real-input, foreground, desktop-toasts -Interactive
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to a
# respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
# T680: private per-PID IPC endpoint, claimed before any launch or CLI call -
# and Assert-GhozttyIsolated below proves every `+list`/`+send-keys` here
# reaches the instance launched by this script, never the pane the caller is
# sitting in.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'notifreal')
# T1033: a private pipe suffix moves the APP endpoint only, so the exe about to
# be launched is checked for the -debug lineage before the first launch.
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
public class NotifRealClick {
    // x64 INPUT is 40 bytes: 4 type + 4 pad + 32 union. MOUSEINPUT is already
    // 32 so it needs NO tail padding. Get it wrong and SendInput accepts 0
    // events and returns silently - the click never happens and the app looks
    // broken.
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MINPUT { public uint type; public MOUSEINPUT mi; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, MINPUT[] i, int cb);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    delegate bool EnumProc(IntPtr h, IntPtr p);

    static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }
    static string Txt(IntPtr h) { var sb = new StringBuilder(256); GetWindowTextW(h, sb, 256); return sb.ToString(); }

    public static IntPtr FindTop(int pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == (uint)pid && Cls(h) == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Every visible top-level window, as "hwnd|pid|class|l,t,r,b|title". The
    // toast is identified by DIFFERENCE against a snapshot taken before the
    // balloon was raised, not by a class allowlist: the shell has changed which
    // class hosts a banner at least twice across Windows 10 and 11, and a
    // hardcoded name is how this script would silently stop finding one.
    public static string[] VisibleWindows() {
        var list = new List<string>();
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            RECT r; GetWindowRect(h, out r);
            if (r.Right - r.Left < 40 || r.Bottom - r.Top < 20) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            // The TITLE goes LAST because it is the one field that can contain
            // the separator - a caller splits on '|' with a field limit and
            // lets the title keep whatever it holds.
            list.Add(string.Format("{0}|{1}|{2}|{3},{4},{5},{6}|{7}",
                h.ToInt64(), pid, Cls(h), r.Left, r.Top, r.Right, r.Bottom, Txt(h)));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static bool Rect(IntPtr h, out RECT r) { return GetWindowRect(h, out r); }

    public static uint Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(150);
        int cb = Marshal.SizeOf(typeof(MINPUT));
        uint n = SendInput(1, new MINPUT[] { new MINPUT { type = 0, mi = new MOUSEINPUT { dwFlags = 0x0002 } } }, cb); // LEFTDOWN
        System.Threading.Thread.Sleep(60);
        n += SendInput(1, new MINPUT[] { new MINPUT { type = 0, mi = new MOUSEINPUT { dwFlags = 0x0004 } } }, cb);     // LEFTUP
        return n;
    }

    public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }
    public static void MoveCursor(int x, int y) { SetCursorPos(x, y); }

    public static IntPtr Foreground() { return GetForegroundWindow(); }

    public static bool Present(IntPtr h) {
        uint dummy;
        uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out dummy);
        uint me = GetCurrentThreadId();
        AttachThreadInput(me, fgTid, true);
        ShowWindow(h, 5);
        SetForegroundWindow(h);
        AttachThreadInput(me, fgTid, false);
        System.Threading.Thread.Sleep(300);
        return GetForegroundWindow() == h;
    }
}
'@

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1). The installed
    # release runs its own ghoztty.exe and it is never a target here.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

# Raise a desktop notification FROM a named pane, via OSC 777 printed by the
# pane's own shell - the real path a program in a pane uses, not an IPC verb.
# Bodies must differ between raises: the core suppresses identical
# notifications for 5s and rate-limits all of them to one per second.
function Invoke-Notification([string]$Pane, [string]$Body) {
    $cmd = "powershell -NoProfile -Command `"[console]::Write([char]27+']777;notify;Ghoztty;$Body'+[char]7)`""
    & $exe +send-keys --target=$Pane $cmd Enter 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# The window the shell drew for our balloon: the one visible top-level window
# that was not there before the raise, is not ours, and is toast-shaped. Toast
# banners sit in the bottom corner of a monitor's work area and are a few
# hundred pixels across; the size band is what separates one from a menu, a
# tooltip or an app window that happened to open at the same moment.
function Wait-Toast([string[]]$Before, [int]$OurPid, [int]$TimeoutMs = 8000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 250) {
        $now = @([NotifRealClick]::VisibleWindows())
        foreach ($line in $now) {
            if ($Before -contains $line) { continue }
            $f = $line -split '\|', 5
            if ($f.Count -lt 5) { continue }
            if ([int]$f[1] -eq $OurPid) { continue }
            $r = $f[3] -split ','
            $w = [int]$r[2] - [int]$r[0]
            $h = [int]$r[3] - [int]$r[1]
            if ($w -lt 200 -or $w -gt 900) { continue }
            if ($h -lt 60 -or $h -gt 500) { continue }
            return [pscustomobject]@{
                Hwnd = [IntPtr][int64]$f[0]; ProcessId = [int]$f[1]; Class = $f[2]; Title = $f[4]
                Left = [int]$r[0]; Top = [int]$r[1]; Right = [int]$r[2]; Bottom = [int]$r[3]
                Line = $line
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Wait-Foreground([IntPtr]$Expected, [int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 100) {
        if ([NotifRealClick]::Foreground() -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

$script:cursorHome = [NotifRealClick]::Cursor()
$app = $null

try {

Kill-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

Write-Host '== setup: two windows, the notification raised from the first'
# --session-persistence=false: a restored layout would decide the window count
# and the foreground this test asserts on.
$app = Start-Process -FilePath $exe -PassThru `
    -ArgumentList @('--config-default-files=false', '--session-persistence=false')
Start-Sleep -Seconds 4
if ($app.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$appPid = [int]$app.Id

$winA = [NotifRealClick]::FindTop($appPid, 'GhozttyWindow')
if ($winA -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: window A not found'; exit 1 }
# Throws unless the instance answering on the private endpoint is the one just
# launched - so nothing below can drive, or grade, the caller's own panes.
Assert-GhozttyIsolated -Exe $exe
$listJson = & $exe +list --json | Out-String
$paneA = $null
if ($listJson -match '"name"\s*:\s*"([^"]+)"') { $paneA = $Matches[1] }
Assert ($null -ne $paneA) 'the launch window has a pane to raise from'

& $exe +new-window --target=nr-b 2>&1 | Out-Null
Start-Sleep -Seconds 3
$winB = [IntPtr]::Zero
foreach ($line in [NotifRealClick]::VisibleWindows()) {
    $f = $line -split '\|', 5
    if ([int]$f[1] -ne $appPid) { continue }
    if ($f[2] -ne 'GhozttyWindow') { continue }
    if ([int64]$f[0] -eq [int64]$winA) { continue }
    $winB = [IntPtr][int64]$f[0]
}
Assert ($winB -ne [IntPtr]::Zero) 'a second window exists to park the foreground on'
if ($winB -eq [IntPtr]::Zero) { throw 'no second window: the foreground oracle would be meaningless' }

# -----------------------------------------------------------------------
# Case 1: click the toast BODY - the raising window must come forward.
# -----------------------------------------------------------------------
Write-Host '== 1: a real click on the toast presents the window that raised it'
$before = @([NotifRealClick]::VisibleWindows())
Assert (Invoke-Notification $paneA 'real-click-one') '+send-keys delivered the OSC 777 notify (case 1)'
$toast = Wait-Toast -Before $before -OurPid $appPid
if ($null -eq $toast) {
    # The shell drew nothing. That is an answer about the BOX - notifications
    # off, a Do Not Disturb window, a shell that has stopped servicing the
    # notification area - and never a verdict on the product, so it skips with
    # the capability named rather than failing.
    Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    Exit-TestSkip -Capability desktop-toasts `
        -Reason 'the shell drew no toast for our balloon (turn Notifications on in Settings > System > Notifications)'
}
Write-Host "   toast: $($toast.Line)"
Assert ([NotifRealClick]::Present($winB)) 'the foreground was parked on the OTHER window'
$bodyX = [int](($toast.Left + $toast.Right) / 2)
$bodyY = [int]($toast.Top + ($toast.Bottom - $toast.Top) * 0.7)
Assert ([NotifRealClick]::Click($bodyX, $bodyY) -eq 2) 'SendInput accepted the press and the release (control)'
$came = Wait-Foreground $winA
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the click does NOT present the raiser - this run MUST fail'
    Assert (-not $came) 'NEGATIVE CONTROL: the click does not present the raising window'
} else {
    Assert $came 'a real click on the toast brought the raising window to the foreground'
}

# -----------------------------------------------------------------------
# Case 2: click the DISMISS button - NIN_BALLOONHIDE, and nothing moves.
# -----------------------------------------------------------------------
Write-Host '== 2: dismissing the toast does NOT move the foreground'
$before = @([NotifRealClick]::VisibleWindows())
Assert (Invoke-Notification $paneA 'real-click-two') '+send-keys delivered the OSC 777 notify (case 2)'
$toast2 = Wait-Toast -Before $before -OurPid $appPid
Assert ($null -ne $toast2) 'a second toast was drawn'
if ($null -ne $toast2) {
    Assert ([NotifRealClick]::Present($winB)) 'the foreground was parked on the OTHER window again'
    # The dismiss affordance is the X in the toast's top-right corner. It is
    # inset from the edge; 24px in and 24px down is inside it on every Windows
    # 11 toast measured, and a miss lands on the body - which would move the
    # foreground and fail LOUDLY rather than pass by accident.
    $xX = $toast2.Right - 24
    $xY = $toast2.Top + 24
    Assert ([NotifRealClick]::Click($xX, $xY) -eq 2) 'SendInput accepted the dismiss click (control)'
    Start-Sleep -Milliseconds 1500
    Assert ([NotifRealClick]::Foreground() -eq $winB) 'the dismiss left the foreground where it was'
}

Assert (-not $app.HasExited) 'the app survived both clicks'
& $exe +list 2>&1 | Out-Null
Assert ($LASTEXITCODE -eq 0) '+list still answers (the GUI thread survived the clicks)'

} finally {
    Write-Host '== teardown'
    [NotifRealClick]::MoveCursor($script:cursorHome.X, $script:cursorHome.Y)
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
    Kill-RepoInstances
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) assertions)"; exit 0 }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red; exit 1 }
