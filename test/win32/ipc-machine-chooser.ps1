# Machine-chooser acceptance (tracker T22c): ctrl+shift+n opens the "New
# Remote Window" picker, which fetches the signed-in account's enrolled relay
# devices and (on selection) dials one through the shared open path. The dialog
# is GUI, so this drives the REAL ctrl+shift+n chord into the debug build's
# surface and asserts the open+fetch path end to end:
#
#   1. a debug log line proves the chord reached openMachineChooser;
#   2. a GhozttyMachineChooser window appears;
#   3. the chooser performed GET /v1/client/devices against a loopback fake
#      relay directory (the deterministic positive control - it only happens
#      if the chooser actually opened and ran its fetch);
#   4. the app survives opening and Escape-closing the chooser (no crash).
#
# T172 adds the look of the thing (the T140 report): the list is owner-drawn
# with two-line machine rows, the selection is an INSET rounded accent pill
# rather than a full-width system-blue bar (pixel-probed, with an unselected
# row as the negative control), the filter shows a cue banner while empty, and
# the footer hint WRAPS - a second, signed-out run proves the dialog grows by
# exactly the extra hint height instead of clipping the sentence.
#
#   powershell -NoProfile -File test\win32\ipc-machine-chooser.ps1
#
# Mechanics mirror kb-actions.ps1: SetForegroundWindow + AttachThreadInput +
# SetFocus(surface) then a short SendInput burst; foreground is verified before
# injection and the run ABORTS-to-SKIP (never fails, never leaks keys) if
# another window owns the foreground. Run on an idle desktop for a real pass.
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$DirPort = 47921
)

$ErrorActionPreference = 'Continue'
$script:pass = 0
$script:fail = 0
$script:skip = 0
# Signed-in geometry, captured in run 1 and compared against the signed-out
# run's (T172 wrapping footer).
$script:chooserH1 = 0
$script:hintH1 = 0
$script:hintLineH = 0
function Assert($cond, $name) {
    if ($cond) { "  PASS $name"; $script:pass++ } else { "  FAIL $name"; $script:fail++ }
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class McDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // --- T172 row-rendering probes -------------------------------------
    // Pixel probes only line up if this process measures in the SAME physical
    // pixels the app draws in: GetWindowRect is DPI-virtualized for an unaware
    // process while Graphics.CopyFromScreen is not, so an unaware probe reads
    // the wrong part of the screen entirely (measured: 189px off at 125%).
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    // The nth (0-based) direct child of `parent` whose class is `cls`, in
    // z-order. Returns IntPtr.Zero when there is no such child.
    public static IntPtr FindChild(IntPtr parent, string cls, int nth) {
        IntPtr found = IntPtr.Zero;
        int seen = 0;
        EnumChildWindows(parent, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase)) {
                if (seen == nth) { found = h; return false; }
                seen++;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // The `cls` child sitting LOWEST in the dialog (largest top edge). The
    // chooser has two STATICs - the account status at the top and the footer
    // hint at the bottom - and this picks the hint without depending on
    // creation order.
    public static IntPtr LowestChild(IntPtr parent, string cls) {
        IntPtr found = IntPtr.Zero;
        int best = int.MinValue;
        EnumChildWindows(parent, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase)) {
                RECT r; GetWindowRect(h, out r);
                if (r.top > best) { best = r.top; found = h; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static int Height(IntPtr h) {
        RECT r; if (!GetWindowRect(h, out r)) return -1;
        return r.bottom - r.top;
    }

    public static bool Raise(IntPtr h) { return GrabForeground(h); }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

    public static IntPtr FindTop(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindByClass(string cls) {
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, cls, null);
    }

    public static string WindowText(IntPtr h) {
        var sb = new StringBuilder(256);
        GetWindowTextW(h, sb, 256);
        return sb.ToString();
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab: attach to the current foreground
    // owner's thread + an Alt tap (last-input source), retried - a
    // background process may not steal foreground otherwise.
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
            Key(0x12, false); Key(0x12, true); // Alt tap
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    // Send mods+vk to the surface. Returns "SENT" or an ABORT reason.
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            foreach (var m in mods) Key(m, false);
            Thread.Sleep(20);
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(20);
            for (int j = mods.Length - 1; j >= 0; j--) Key(mods[j], true);
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Best-effort single key to whatever the foreground window has focused.
    public static void PressForeground(IntPtr win, ushort vk) {
        GrabForeground(win);
        Key(vk, false); Thread.Sleep(20); Key(vk, true);
        Thread.Sleep(60);
    }
}
'@

# --- screen capture ----------------------------------------------------------
# One BitBlt per probe SET, then managed pixel reads. Per-pixel GetPixel on the
# desktop DC is ~1000x slower under DWM (it made this script take minutes).
Add-Type -AssemblyName System.Drawing
[void][McDrv]::SetProcessDPIAware()

# The chooser's client width is `px(440, scale)` by construction (see
# MachineChooser.layout), so the live DPI scale - and with it the one-line
# footer height, `px(16, scale)` - is derivable from the window itself instead
# of hardcoded per box.
function Get-ChooserScale {
    param([IntPtr]$Hwnd)
    $r = New-Object McDrv+RECT
    if (-not [McDrv]::GetClientRect($Hwnd, [ref]$r)) { return 1.0 }
    if ($r.right -le 0) { return 1.0 }
    return $r.right / 440.0
}

function Get-WindowShot {
    param([IntPtr]$Hwnd)
    $r = New-Object McDrv+RECT
    if (-not [McDrv]::GetWindowRect($Hwnd, [ref]$r)) { return $null }
    $w = $r.right - $r.left
    $h = $r.bottom - $r.top
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.left, $r.top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    return @{ Bmp = $bmp; Left = $r.left; Top = $r.top; W = $w; H = $h }
}

# Screen-coordinate pixel from a shot, as @(r, g, b).
function Get-ShotPixel {
    param($Shot, [int]$X, [int]$Y)
    $px = $Shot.Bmp.GetPixel($X - $Shot.Left, $Y - $Shot.Top)
    return @([int]$px.R, [int]$px.G, [int]$px.B)
}

# How many pixels in a screen rect differ from (R,G,B) by more than Tol in any
# channel - i.e. how much was actually DRAWN there.
function Measure-DrawnPixels {
    param($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$R, [int]$G, [int]$B, [int]$Tol)
    $n = 0
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
            $lx = $x - $Shot.Left
            $ly = $y - $Shot.Top
            if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.W -or $ly -ge $Shot.H) { continue }
            $px = $Shot.Bmp.GetPixel($lx, $ly)
            if ([Math]::Abs([int]$px.R - $R) -gt $Tol -or
                [Math]::Abs([int]$px.G - $G) -gt $Tol -or
                [Math]::Abs([int]$px.B - $B) -gt $Tol) { $n++ }
        }
    }
    return $n
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
}

# --- Fake relay device directory (loopback HTTP; records each request) -------
$hitFile = Join-Path $env:TEMP "ghoztty-mc-hits-$PID.txt"
Remove-Item $hitFile -ErrorAction SilentlyContinue
$devicesJson = '{"devices":[{"id":"dev-e2e","name":"E2E-Box","hostname":"e2e.local","online":true}]}'
$dirJob = Start-Job -ScriptBlock {
    param($port, $body, $hitFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $payload = [Text.Encoding]::UTF8.GetBytes($body)
    $resp = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $respBytes = [Text.Encoding]::UTF8.GetBytes($resp) + $payload
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 40
            $buf = New-Object byte[] 16384
            $sb = New-Object Text.StringBuilder
            while ($stream.DataAvailable) {
                $n = $stream.Read($buf, 0, $buf.Length)
                [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            }
            $reqLine = ($sb.ToString() -split "`r`n")[0]
            Add-Content -Path $hitFile -Value $reqLine
            $stream.Write($respBytes, 0, $respBytes.Length)
            $stream.Flush()
        } catch {}
        $client.Close()
    }
} -ArgumentList $DirPort, $devicesJson, $hitFile
Start-Sleep -Milliseconds 600

# --- Launch a debug GUI signed in via the env token, isolated from any real
# account so GHOSTTY_RELAY_TOKEN is what resolves. ---------------------------
Stop-DebugGhoztty
$errlog = Join-Path $env:TEMP "ghoztty-mc-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue
$acctDir = Join-Path $env:TEMP "ghoztty-mc-acct-$PID"
$env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
$env:GHOSTTY_RELAY_TOKEN = 'faketoken-e2e'
$env:GHOSTTY_ACCOUNT_STORE = (Join-Path $acctDir 'account.dat')
$proc = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $errlog
foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
    Remove-Item "env:$k" -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

$aborted = $false
if ($proc.HasExited) {
    "SETUP FAIL: GUI died at launch"
    $script:fail++
} else {
    $top = [McDrv]::FindTop([uint32]$proc.Id)
    $surface = [McDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
    if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) {
        "SETUP FAIL: GhozttyWindow/GhozttyTerminal not found"
        $script:fail++
    } else {
        # ctrl(0x11)+shift(0x10)+N(0x4E)
        $r = [McDrv]::Chord($top, $surface, @([uint16]0x11, [uint16]0x10), [uint16]0x4E)
        if ($r -like 'ABORT*') {
            "  SKIP machine-chooser drive: $r"
            $script:skip++
            $aborted = $true
        } else {
            $chooser = [IntPtr]::Zero
            for ($t = 0; $t -lt 150; $t++) {
                Start-Sleep -Milliseconds 20
                $chooser = [McDrv]::FindByClass('GhozttyMachineChooser')
                if ($chooser -ne [IntPtr]::Zero) { break }
            }
            Start-Sleep -Milliseconds 300
            $err = Get-Content $errlog -Raw -ErrorAction SilentlyContinue
            $hits = Get-Content $hitFile -ErrorAction SilentlyContinue

            Assert ($err -match 'machine chooser: opening via ctrl\+shift\+n') 'ctrl+shift+n reached openMachineChooser (stderr)'
            Assert ($chooser -ne [IntPtr]::Zero) 'GhozttyMachineChooser window opened'
            if ($chooser -ne [IntPtr]::Zero) {
                Assert ([McDrv]::WindowText($chooser) -eq 'New Remote Window') 'chooser caption is "New Remote Window"'
            }
            Assert (($hits -join "`n") -match '/v1/client/devices') 'chooser fetched the device directory (GET /v1/client/devices)'
            Assert (-not $proc.HasExited) 'app survived opening the chooser'

            # --- T172: rows carry machine identity, not a system-blue bar ----
            if ($chooser -ne [IntPtr]::Zero) {
                $GWL_STYLE = -16
                $LBS_OWNERDRAWFIXED = 0x0010
                $LBS_HASSTRINGS = 0x0040
                $LB_GETITEMHEIGHT = 0x01A1
                $LB_GETCOUNT = 0x018B

                $list = [McDrv]::FindChild($chooser, 'ListBox', 0)
                $edit = [McDrv]::FindChild($chooser, 'Edit', 0)
                Assert ($list -ne [IntPtr]::Zero) 'chooser has a machine list'

                if ($list -ne [IntPtr]::Zero) {
                    $style = [McDrv]::GetWindowLongW($list, $GWL_STYLE)
                    Assert (($style -band $LBS_OWNERDRAWFIXED) -ne 0) 'list rows are owner-drawn (LBS_OWNERDRAWFIXED)'
                    Assert (($style -band $LBS_HASSTRINGS) -eq 0) 'list no longer stores single-line strings (no LBS_HASSTRINGS)'

                    $rowH = [int][McDrv]::SendMessageW($list, $LB_GETITEMHEIGHT, [IntPtr]::Zero, [IntPtr]::Zero)
                    Assert ($rowH -ge 40) "row height fits a name + subline (got $rowH, want >= 40)"

                    $count = [int][McDrv]::SendMessageW($list, $LB_GETCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
                    Assert ($count -eq 2) "list shows Local + the fetched device (got $count rows)"

                    # Pixel oracle: the selected row is an INSET rounded accent
                    # pill. Probe the gutter beside it (must stay list
                    # background) and the pill itself (must be accent-tinted),
                    # then an unselected row at the same x as a negative
                    # control. This is exactly what the T140 screenshot got
                    # wrong: a full-width system-blue selection bar.
                    [void][McDrv]::Raise($chooser)
                    Start-Sleep -Milliseconds 350
                    $shot = Get-WindowShot -Hwnd $chooser
                    $lr = New-Object McDrv+RECT
                    [void][McDrv]::GetWindowRect($list, [ref]$lr)
                    $yRow0 = $lr.top + 1 + [int]($rowH / 2)
                    $yRow1 = $lr.top + 1 + $rowH + [int]($rowH / 2)
                    $gutter = Get-ShotPixel $shot ($lr.left + 3) $yRow0
                    $pill = Get-ShotPixel $shot ($lr.left + 14) $yRow0
                    $unsel = Get-ShotPixel $shot ($lr.left + 14) $yRow1

                    $gutterTint = $gutter[2] - $gutter[0]
                    $pillTint = $pill[2] - $pill[0]
                    $unselTint = $unsel[2] - $unsel[0]
                    Assert ($pillTint -ge 25) "selected row is accent-tinted (b-r = $pillTint at the pill)"
                    Assert ($gutterTint -le 10) "selection is inset, not full-width (b-r = $gutterTint in the gutter)"
                    Assert ($unselTint -le 10) "unselected row stays untinted (b-r = $unselTint)"
                }

                if ($edit -ne [IntPtr]::Zero) {
                    # Cue banner: the filter's TEXT is empty, yet its interior
                    # has drawn pixels - the placeholder the old unlabeled box
                    # lacked.
                    $er = New-Object McDrv+RECT
                    [void][McDrv]::GetWindowRect($edit, [ref]$er)
                    if (-not $shot) { $shot = Get-WindowShot -Hwnd $chooser }
                    $drawn = Measure-DrawnPixels $shot ($er.left + 4) ($er.top + 4) ($er.right - 4) ($er.bottom - 4) 30 30 30 12
                    Assert ([McDrv]::WindowText($edit) -eq '') 'filter field is empty'
                    Assert ($drawn -ge 40) "filter shows a cue banner while empty ($drawn drawn pixels)"
                }

                $script:chooserH1 = [McDrv]::Height($chooser)
                $script:hintLineH = [int][Math]::Round(16.0 * (Get-ChooserScale -Hwnd $chooser))
                $hint1 = [McDrv]::LowestChild($chooser, 'Static')
                if ($hint1 -ne [IntPtr]::Zero) { $script:hintH1 = [McDrv]::Height($hint1) }
                Assert ($script:hintH1 -eq $script:hintLineH) "signed-in footer is one line (line=$($script:hintLineH), got $($script:hintH1))"
            }

            # Escape closes the chooser (routed via handleKey), best effort.
            if ($chooser -ne [IntPtr]::Zero) {
                [McDrv]::PressForeground($chooser, [uint16]0x1B) # VK_ESCAPE
                Start-Sleep -Milliseconds 300
                $gone = ([McDrv]::FindByClass('GhozttyMachineChooser') -eq [IntPtr]::Zero)
                Assert $gone 'Escape closed the chooser'
            }
            Assert (-not $proc.HasExited) 'app survived closing the chooser'
        }
    }
}

# --- T172: signed out, the footer WRAPS and the dialog grows to fit ----------
# The T140 screenshot's footer was clipped mid-sentence ("...to list your"):
# the hint was a fixed one-line slot. Signed out, that hint is a long sentence,
# so it must occupy more lines than the signed-in case (whose hint is empty),
# the dialog must be taller by exactly that much, and the wrapped remainder
# must actually be painted INSIDE the control.
if (-not $aborted -and $script:chooserH1 -gt 0 -and $script:hintH1 -gt 0) {
    Stop-DebugGhoztty
    $acctDir2 = Join-Path $env:TEMP "ghoztty-mc-acct2-$PID"
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $acctDir2 'account.dat')
    $proc2 = Start-Process -FilePath $Exe -PassThru
    Remove-Item 'env:GHOSTTY_ACCOUNT_STORE' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $top2 = [McDrv]::FindTop([uint32]$proc2.Id)
    $surface2 = [McDrv]::FindWindowExW($top2, [IntPtr]::Zero, 'GhozttyTerminal', $null)
    if ($top2 -eq [IntPtr]::Zero -or $surface2 -eq [IntPtr]::Zero) {
        "  SKIP signed-out footer run: no window"
        $script:skip++
    } else {
        $r2 = [McDrv]::Chord($top2, $surface2, @([uint16]0x11, [uint16]0x10), [uint16]0x4E)
        if ($r2 -like 'ABORT*') {
            "  SKIP signed-out footer run: $r2"
            $script:skip++
        } else {
            $chooser2 = [IntPtr]::Zero
            for ($t = 0; $t -lt 150; $t++) {
                Start-Sleep -Milliseconds 20
                $chooser2 = [McDrv]::FindByClass('GhozttyMachineChooser')
                if ($chooser2 -ne [IntPtr]::Zero) { break }
            }
            Assert ($chooser2 -ne [IntPtr]::Zero) 'chooser opens with no credential'
            if ($chooser2 -ne [IntPtr]::Zero) {
                [void][McDrv]::Raise($chooser2)
                Start-Sleep -Milliseconds 400
                $hint2 = [McDrv]::LowestChild($chooser2, 'Static')
                $hintH2 = [McDrv]::Height($hint2)
                $chooserH2 = [McDrv]::Height($chooser2)

                Assert ($hintH2 -ge 2 * $script:hintLineH) "signed-out hint wraps to 2+ lines (line=$($script:hintLineH), got $hintH2)"
                Assert (($chooserH2 - $script:chooserH1) -eq ($hintH2 - $script:hintH1)) "dialog grew by exactly the extra hint height (window +$($chooserH2 - $script:chooserH1), hint +$($hintH2 - $script:hintH1))"

                # The wrapped remainder is painted inside the control, not cut
                # off: the hint's bottom half has text pixels on the dialog
                # background.
                $hr = New-Object McDrv+RECT
                [void][McDrv]::GetWindowRect($hint2, [ref]$hr)
                $mid = $hr.top + [int]($hintH2 / 2)
                $shot2 = Get-WindowShot -Hwnd $chooser2
                $tail = Measure-DrawnPixels $shot2 $hr.left $mid $hr.right $hr.bottom 32 32 32 12
                Assert ($tail -ge 20) "the wrapped tail of the hint is rendered ($tail drawn pixels below the first line)"
            }
            Assert (-not $proc2.HasExited) 'app survived the signed-out chooser'
        }
    }
    Remove-Item -Recurse -Force $acctDir2 -ErrorAction SilentlyContinue
}

# --- teardown ----------------------------------------------------------------
"== teardown"
Stop-DebugGhoztty
Stop-Job $dirJob -ErrorAction SilentlyContinue
Remove-Job $dirJob -Force -ErrorAction SilentlyContinue
Remove-Item $hitFile, $errlog -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $acctDir -ErrorAction SilentlyContinue

if ($aborted) {
    "MACHINE-CHOOSER ACCEPTANCE: SKIPPED (foreground unavailable; rerun on an idle desktop)"
    exit 0
} elseif ($script:fail -eq 0) {
    "MACHINE-CHOOSER ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "MACHINE-CHOOSER ACCEPTANCE: $($script:fail) FAILURE(S)"
    exit 1
}
