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
# the status strip WRAPS - a second, signed-out run proves it never clips.
#
# T175 adds the SHAPE (Mac's master-detail chooser): a fixed 840x540 dialog, a
# washed machine column at the left separated by a hairline rule, a detail pane
# at the right that names the selected machine and carries the "New Window"
# primary action, and Cancel alone in the footer. The detail pane is asserted to
# FOLLOW the selection (arrow down must repaint it), and - since the window no
# longer grows - the wrapping strip now takes its extra lines out of the LIST.
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
$script:listH1 = 0
$script:rowH1 = 0
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
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }

    // Screen coordinates of a window's client origin, so client-space layout
    // numbers (which is what MachineChooser.layout produces) can be probed on
    // the captured screenshot without guessing the caption height.
    public static POINT ClientOrigin(IntPtr h) {
        POINT p; p.x = 0; p.y = 0;
        ClientToScreen(h, ref p);
        return p;
    }

    // "text|left|top|right|bottom" (screen coords) for every `cls` child, so a
    // test can find a control by its LABEL instead of by creation order.
    public static string[] ChildInfo(IntPtr parent, string cls) {
        var rows = new System.Collections.Generic.List<string>();
        EnumChildWindows(parent, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase)) {
                var t = new StringBuilder(256);
                GetWindowTextW(h, t, 256);
                RECT r; GetWindowRect(h, out r);
                rows.Add(t.ToString() + "|" + r.left + "|" + r.top + "|" + r.right + "|" + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return rows.ToArray();
    }

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

# The chooser's client width is `px(840, scale)` by construction (T175, see
# chooser_layout.layout), so the live DPI scale - and with it the one-line
# status-strip height, `px(16, scale)` - is derivable from the window itself
# instead of hardcoded per box.
function Get-ChooserScale {
    param([IntPtr]$Hwnd)
    $r = New-Object McDrv+RECT
    if (-not [McDrv]::GetClientRect($Hwnd, [ref]$r)) { return 1.0 }
    if ($r.right -le 0) { return 1.0 }
    return $r.right / 840.0
}

# A DIP measurement in the chooser's physical pixels.
function Dip($scale, $v) { return [int][Math]::Round($v * $scale) }

# Parse one ChildInfo row into an object with screen-space edges.
function Get-Controls($chooser, $cls) {
    foreach ($row in [McDrv]::ChildInfo($chooser, $cls)) {
        $f = $row -split '\|'
        [pscustomobject]@{
            Text   = $f[0]
            Left   = [int]$f[1]
            Top    = [int]$f[2]
            Right  = [int]$f[3]
            Bottom = [int]$f[4]
        }
    }
}

# A cheap position-weighted checksum of a screen rect: two different strings
# rendered in the same box give different values, where a bare drawn-pixel
# COUNT can collide.
function Get-RegionSignature {
    param($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1)
    $sig = 0
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
            $lx = $x - $Shot.Left
            $ly = $y - $Shot.Top
            if ($lx -lt 0 -or $ly -lt 0 -or $lx -ge $Shot.W -or $ly -ge $Shot.H) { continue }
            $px = $Shot.Bmp.GetPixel($lx, $ly)
            $sig = ($sig + ($lx + 1) * [int]$px.R + ($ly + 1) * [int]$px.B) % 2147483647
        }
    }
    return $sig
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
                $scale = Get-ChooserScale -Hwnd $chooser
                $script:hintLineH = Dip $scale 16
                $hint1 = [McDrv]::LowestChild($chooser, 'Static')
                if ($hint1 -ne [IntPtr]::Zero) { $script:hintH1 = [McDrv]::Height($hint1) }
                Assert ($script:hintH1 -eq $script:hintLineH) "signed-in status strip is one line (line=$($script:hintLineH), got $($script:hintH1))"
                if ($list -ne [IntPtr]::Zero) {
                    $script:listH1 = [McDrv]::Height($list)
                    $script:rowH1 = $rowH
                }

                # --- T175: the master-detail shell -----------------------
                # T140's report was that the dialog "looks nothing like the mac
                # dialog". Mac's is 840x540 with a washed machine column at the
                # left, a detail pane at the right carrying the machine's
                # identity and its primary action, and Cancel alone in the
                # footer. Each of those is asserted here against the real
                # window, not against the layout function.
                $cr = New-Object McDrv+RECT
                [void][McDrv]::GetClientRect($chooser, [ref]$cr)
                Assert ([Math]::Abs($cr.bottom - (Dip $scale 540)) -le 2) "chooser client is Mac's 540 tall at this DPI (got $($cr.bottom), want $(Dip $scale 540))"

                $org = [McDrv]::ClientOrigin($chooser)
                $masterRight = Dip $scale 260
                $footerY = Dip $scale 480
                if (-not $shot) { $shot = Get-WindowShot -Hwnd $chooser }

                # The column is a wash: brighter than the dialog surface beside
                # it, at the same height, below the last row.
                $yBody = $org.y + (Dip $scale 300)
                $washPx = Get-ShotPixel $shot ($org.x + (Dip $scale 200)) $yBody
                $panePx = Get-ShotPixel $shot ($org.x + (Dip $scale 600)) $yBody
                Assert (($washPx[0] - $panePx[0]) -ge 4) "machine column sits on a wash (col r=$($washPx[0]) vs pane r=$($panePx[0]))"

                # ...and a hairline rule divides them. Sample the 3 candidate
                # columns so a rounding-off-by-one does not read as absence.
                $ruleR = 0
                foreach ($dx in -1, 0, 1) {
                    $p = Get-ShotPixel $shot ($org.x + $masterRight + $dx) $yBody
                    if ($p[0] -gt $ruleR) { $ruleR = $p[0] }
                }
                Assert (($ruleR - $washPx[0]) -ge 8) "a rule separates the columns (rule r=$ruleR vs wash r=$($washPx[0]))"

                # The primary action is Mac's "New Window", it lives in the
                # detail pane, and the footer holds Cancel alone.
                $buttons = @(Get-Controls $chooser 'Button')
                $primary = $buttons | Where-Object { $_.Text -eq 'New Window' }
                $cancel = $buttons | Where-Object { $_.Text -eq 'Cancel' }
                Assert ($null -ne $primary) "the primary action is labeled 'New Window' (saw: $(($buttons | ForEach-Object { $_.Text }) -join ', '))"
                Assert ($null -ne $cancel) 'the footer has a Cancel button'
                if ($primary) {
                    Assert ((($primary.Left - $org.x) -gt $masterRight)) "the primary action is in the detail pane (left=$($primary.Left - $org.x), column ends at $masterRight)"
                    Assert ((($primary.Bottom - $org.y) -lt $footerY)) 'the primary action is above the footer, not in it'
                }
                $inFooter = @($buttons | Where-Object { ($_.Top - $org.y) -ge $footerY })
                Assert ($inFooter.Count -eq 1 -and $inFooter[0].Text -eq 'Cancel') "Cancel is alone in the footer (found: $(($inFooter | ForEach-Object { $_.Text }) -join ', '))"

                # The detail pane names the selected machine, and it FOLLOWS
                # the selection: arrowing onto the relay device must repaint it.
                $dx0 = $org.x + (Dip $scale 300)
                $dx1 = $org.x + (Dip $scale 620)
                $dy0 = $org.y + (Dip $scale 60)
                $dy1 = $org.y + (Dip $scale 110)
                $headDrawn = Measure-DrawnPixels $shot $dx0 $dy0 $dx1 $dy1 32 32 32 12
                Assert ($headDrawn -ge 40) "the detail pane renders the machine's identity ($headDrawn drawn pixels)"
                $sigLocal = Get-RegionSignature $shot $dx0 $dy0 $dx1 $dy1

                [McDrv]::PressForeground($chooser, [uint16]0x28) # VK_DOWN
                Start-Sleep -Milliseconds 350
                $shotDown = Get-WindowShot -Hwnd $chooser
                $sigDevice = Get-RegionSignature $shotDown $dx0 $dy0 $dx1 $dy1
                Assert ($sigDevice -ne $sigLocal) "the detail pane follows the selection (signature $sigLocal -> $sigDevice)"
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
if (-not $aborted -and $script:chooserH1 -gt 0 -and $script:hintH1 -gt 0 -and $script:listH1 -gt 0) {
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
                $list2 = [McDrv]::FindChild($chooser2, 'ListBox', 0)
                $listH2 = if ($list2 -ne [IntPtr]::Zero) { [McDrv]::Height($list2) } else { 0 }

                Assert ($hintH2 -ge 2 * $script:hintLineH) "signed-out status strip wraps to 2+ lines (line=$($script:hintLineH), got $hintH2)"
                # Since T175 the dialog is Mac's fixed 840x540, so the extra
                # lines come out of the LIST's height instead of the window's -
                # same no-clipping invariant, measured on the thing that flexes.
                Assert ($chooserH2 -eq $script:chooserH1) "dialog stayed a fixed size (was $($script:chooserH1), now $chooserH2)"
                # The list sheds the room in WHOLE rows (an owner-drawn listbox
                # must never render a clipped half row), so the accounting is
                # "the extra strip height, to the nearest row" - and the list
                # must end above the strip, which is the actual no-overlap
                # invariant the old grow-the-dialog assertion stood for.
                $shed = $script:listH1 - $listH2
                $grew = $hintH2 - $script:hintH1
                Assert ($shed -ge ($grew - $script:rowH1) -and $shed -le ($grew + $script:rowH1)) "the list gave up the extra strip height, to the nearest row (list -$shed, strip +$grew, row $($script:rowH1))"
                Assert ($script:rowH1 -gt 0 -and ($listH2 % $script:rowH1) -eq 0) "the list still holds whole rows only ($listH2 / row $($script:rowH1))"
                $lr2 = New-Object McDrv+RECT
                [void][McDrv]::GetWindowRect($list2, [ref]$lr2)
                $hr2 = New-Object McDrv+RECT
                [void][McDrv]::GetWindowRect($hint2, [ref]$hr2)
                Assert ($lr2.bottom -le $hr2.top) "the list stops above the wrapped strip (list ends $($lr2.bottom), strip starts $($hr2.top))"

                # The wrapped remainder is painted inside the control, not cut
                # off: the strip's bottom half has text pixels on the column
                # wash it sits on.
                $hr = New-Object McDrv+RECT
                [void][McDrv]::GetWindowRect($hint2, [ref]$hr)
                $mid = $hr.top + [int]($hintH2 / 2)
                $shot2 = Get-WindowShot -Hwnd $chooser2
                $tail = Measure-DrawnPixels $shot2 $hr.left $mid $hr.right $hr.bottom 40 40 40 12
                Assert ($tail -ge 20) "the wrapped tail of the strip is rendered ($tail drawn pixels below the first line)"
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
