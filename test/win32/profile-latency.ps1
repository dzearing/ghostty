# T53b interactive profiling: real-keyboard input latency + scrollback-seek
# feel at 100k+ lines, idle and under same-pane streaming load.
#
# Runs a fully ISOLATED instance: its own pipe suffix (-prof) and its own
# log file (LOCALAPPDATA is overridden to the run dir, so this instance's
# GHOZTTY_PERF lines cannot pollute a concurrently running soak's telemetry
# slice, which greps the real %LOCALAPPDATA% log).
#
# Measurements:
#   1. Input latency, real key path (SendInput unicode char -> poll +read
#      until the echo is visible), on a fresh pane and again on a 150k-line
#      scrollback -- degradation check.
#   2. Scrollback-seek: ctrl+home, 60x pgup with shift held, 60x pgdn,
#      ctrl+end; per-key WM_NULL round-trip on the GUI thread (user-visible
#      freeze proxy) + renderer fps/max_gap from the isolated perf log.
#      Positive control: PrintWindow pixel hash must CHANGE between bottom
#      and top of scrollback (viewport really moved).
#   3. Same seek burst while the SAME pane streams an endless echo storm
#      (the "scroll up while the agent streams" case), plus a timed +read
#      mid-storm (T62 regression bound on the release build).
#
# Only touches ghoztty processes running from $ExePath. Safe to run beside
# the detached soak (different exe, different pipe, different log).
param(
    [string]$ExePath = 'D:\git\ghoztty\zig-out-prof\bin\ghoztty.exe',
    [int]$SeekKeys = 60,
    [int]$LatencyProbes = 8
)
$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-prof\$stamp"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'
$rttCsv = Join-Path $outDir 'seek-rtt.csv'
$fakeLocal = Join-Path $outDir 'env'
New-Item -ItemType Directory -Force $fakeLocal | Out-Null
$profLog = Join-Path $fakeLocal 'ghoztty\ghoztty.log'

function Rep($m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; Rep "FAIL  $label" }
}

Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Text;
using System.Threading;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class ProfDrv {
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
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeoutMs, out IntPtr result);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L; public int T; public int R; public int B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() { SetProcessDpiAwarenessContext((IntPtr)(-4)); }

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

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    static void Uni(char c, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = 0;
        i[0].ki.wScan = (ushort)c;
        i[0].ki.dwFlags = (up ? 2u : 0u) | 4u; // KEYEVENTF_UNICODE
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // GUI-thread round trip in ms; -1 on timeout.
    public static long NullRtt(IntPtr top, uint timeoutMs) {
        IntPtr res;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        IntPtr ok = SendMessageTimeoutW(top, 0x0000, IntPtr.Zero, IntPtr.Zero, 0x0008, timeoutMs, out res); // SMTO_BLOCK
        sw.Stop();
        return ok == IntPtr.Zero ? -1 : sw.ElapsedMilliseconds;
    }

    // Focus state: we stay AttachThreadInput'ed for the whole profiling
    // session (kb-actions lesson: keys sent after detaching never reach
    // the surface - SetFocus only survives while attached).
    static uint attachedTid = 0;
    static IntPtr focusSurface = IntPtr.Zero;

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

    // Acquire foreground + focus the surface and STAY attached.
    public static string Focus(IntPtr top, IntPtr surface) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (attachedTid == 0) {
            if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
            attachedTid = tid;
        }
        focusSurface = surface;
        SetFocus(surface);
        Thread.Sleep(60);
        if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
        return "OK";
    }

    public static void Release() {
        if (attachedTid != 0) {
            AttachThreadInput(GetCurrentThreadId(), attachedTid, false);
            attachedTid = 0;
        }
    }

    // Type a short [a-z0-9] token via plain VK key events - the path real
    // keyboards use, which is what we want to measure. (Unicode/VK_PACKET
    // injection was broken until T64; kb-actions.ps1 covers it now.)
    public static string TypeToken(IntPtr top, string token) {
        if (GetForegroundWindow() != top) return "ABORT: foreground lost";
        if (focusSurface != IntPtr.Zero) SetFocus(focusSurface);
        foreach (char c in token) {
            ushort vk = (ushort)char.ToUpperInvariant(c);
            Key(vk, false); Thread.Sleep(2); Key(vk, true); Thread.Sleep(2);
        }
        return "SENT";
    }

    public static void PressVk(ushort vk) { Key(vk, false); Thread.Sleep(15); Key(vk, true); }

    // Chord with modifiers (e.g. ctrl+home). Caller must own foreground.
    public static string Chord(IntPtr top, ushort[] mods, ushort vk) {
        if (GetForegroundWindow() != top) return "ABORT: foreground lost";
        if (focusSurface != IntPtr.Zero) SetFocus(focusSurface);
        foreach (var m in mods) Key(m, false);
        Thread.Sleep(15);
        Key(vk, false); Thread.Sleep(15); Key(vk, true);
        Thread.Sleep(15);
        for (int j = mods.Length - 1; j >= 0; j--) Key(mods[j], true);
        return "SENT";
    }

    // Hold shift, press vk N times, sampling the GUI thread after each
    // press. Returns comma-joined per-key WM_NULL RTTs in ms (-1 timeout),
    // or "ABORT..." if foreground was lost mid-burst.
    public static string SeekBurst(IntPtr top, ushort vk, int n, uint timeoutMs) {
        if (GetForegroundWindow() != top) return "ABORT: foreground lost";
        if (focusSurface != IntPtr.Zero) SetFocus(focusSurface);
        var rtts = new StringBuilder();
        Key(0x10, false); // shift down
        try {
            for (int i = 0; i < n; i++) {
                if (i % 10 == 9 && GetForegroundWindow() != top) return "ABORT: foreground lost mid-burst";
                Key(vk, false); Thread.Sleep(5); Key(vk, true);
                long r = NullRtt(top, timeoutMs);
                if (rtts.Length > 0) rtts.Append(',');
                rtts.Append(r);
                Thread.Sleep(10);
            }
        } finally { Key(0x10, true); }
        return rtts.ToString();
    }

    // MD5 of the surface's PrintWindow capture (PW_RENDERFULLCONTENT).
    public static string PixelHash(IntPtr surface) {
        RECT r;
        if (!GetWindowRect(surface, out r)) return "NORECT";
        int w = r.R - r.L, h = r.B - r.T;
        if (w <= 0 || h <= 0) return "EMPTY";
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            bool ok = PrintWindow(surface, hdc, 2);
            g.ReleaseHdc(hdc);
            if (!ok) return "PRINTFAIL";
            var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var bytes = new byte[data.Stride * h];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            bmp.UnlockBits(data);
            using (var md5 = System.Security.Cryptography.MD5.Create())
                return BitConverter.ToString(md5.ComputeHash(bytes));
        }
    }
}
'@
[ProfDrv]::BeDpiAware()

function MedianOf($arr) {
    $v = @($arr | Sort-Object)
    if ($v.Count -eq 0) { return -1 }
    return $v[[int]($v.Count / 2)]
}

# Parse 'perf [pane=] fps= max_gap_ms=' lines appended to the isolated log since
# byte offset $from. Returns @{Fps=..; Gaps=..; NewLen=..}.
function PerfSlice([long]$from) {
    $fps = @(); $gaps = @(); $len = $from
    if (Test-Path $profLog) {
        $fs = [System.IO.FileStream]::new($profLog, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length
            if ($from -lt $len) {
                $fs.Seek($from, 'Begin') | Out-Null
                $sr = [System.IO.StreamReader]::new($fs)
                while ($null -ne ($line = $sr.ReadLine())) {
                    # `pane=` is optional: T1147 added it to every sample, and
                    # keeping the group optional means this profile still reads
                    # an older exe. It is not used here - this harness runs one
                    # pane, so the population and the pane are the same thing.
                    if ($line -match 'perf (?:pane=\S+ )?fps=(\d+) max_gap_ms=(\d+)') {
                        $fps += [int]$Matches[1]
                        $gaps += [int]$Matches[2]
                    }
                }
            }
        } finally { $fs.Close() }
    }
    return @{ Fps = $fps; Gaps = $gaps; NewLen = $len }
}

# Poll +read (last 5 lines) until $token shows up; returns elapsed ms or -1.
function WaitVisible([string]$pane, [string]$token, [int]$budgetMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $budgetMs) {
        $tail = & $exe +read --name=$pane --lines=5 | Out-String
        if ($tail -match [regex]::Escape($token)) { $sw.Stop(); return $sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 15
    }
    return -1
}

# One keyboard latency probe: type a unique token, time until +read sees it,
# then ESC to clear the cmd input line.
function LatencyProbe([string]$pane, [string]$token, [int]$budgetMs) {
    $r = [ProfDrv]::TypeToken($top, $token)
    if ($r -ne 'SENT') { return @{ Ms = -2; Why = $r } }
    $ms = WaitVisible $pane $token $budgetMs
    [ProfDrv]::PressVk(0x1B) | Out-Null # ESC clears the cmd input line
    Start-Sleep -Milliseconds 60
    return @{ Ms = $ms; Why = 'ok' }
}

if (-not (Test-Path $ExePath)) { Rep "ABORT: exe not found: $ExePath"; exit 1 }
$exe = $ExePath
$env:GHOZTTY_PIPE_SUFFIX = "-prof$PID"
$env:GHOZTTY_PERF = '1'
$realLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $fakeLocal
try {

$exeItem = Get-Item $exe
Rep "=== ghoztty latency/seek profile $stamp"
Rep "exe: $exe ($(($exeItem).LastWriteTime), $(($exeItem).Length) bytes)"
Rep "isolated log: $profLog"

# --- Fresh isolated instance --------------------------------------------------
# T248: "fresh" has to include the sibling agent and the debug session-layout
# manifest. Without them `--target=prof` focuses the PERSISTED pane from the
# previous run — a pane with its own scrollback and its own warmed-up state,
# which is not the cold instance these numbers are supposed to describe.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
Reset-GhozttyTestState -Exe $exe -SettleMs 500 | Out-Null

& $exe +new-window --target=prof --shell=cmd | Out-Null
Start-Sleep -Seconds 3
$gui = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe } |
    Where-Object {
        $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        $p -and $p.MainWindowHandle -ne 0 })
if ($gui.Count -ne 1) { Rep "ABORT: expected 1 prof GUI, got $($gui.Count)"; exit 1 }
$proc = Get-Process -Id $gui[0].ProcessId
Rep "gui pid: $($proc.Id)"

$top = [ProfDrv]::FindTop([uint32]$proc.Id)
$surface = [ProfDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) { Rep 'ABORT: HWNDs not found'; exit 1 }

$listJson = & $exe +list --json | ConvertFrom-Json
$win = $listJson.data.windows | Where-Object { $_.target -eq 'prof' }
$pane = $win.tabs[0].splits.terminal.name
if (-not $pane) { Rep 'ABORT: pane name not found in +list'; exit 1 }
Rep "pane: $pane"

$f = [ProfDrv]::Focus($top, $surface)
if ($f -ne 'OK') { Rep "ABORT: cannot acquire focus ($f) - box in use?"; exit 1 }

# Positive control for the whole key path: a typed token must reach the PTY.
$ctl = LatencyProbe $pane 'keyctl1' 5000
Assert ($ctl.Ms -ge 0) "key path control: typed token visible via +read ($($ctl.Ms)ms)"
if ($ctl.Ms -lt 0) { Rep 'ABORT: key path dead, everything else would be vacuous'; exit 1 }

# --- 1. Input latency, fresh pane ----------------------------------------------
$latFresh = @()
for ($i = 1; $i -le $LatencyProbes; $i++) {
    $p = LatencyProbe $pane "klata$i" 5000
    if ($p.Ms -ge 0) { $latFresh += $p.Ms } else { Rep "WARN probe klata$i failed: $($p.Why)/$($p.Ms)" }
}
Rep "input latency (fresh pane): n=$($latFresh.Count) median $(MedianOf $latFresh)ms max $(($latFresh | Measure-Object -Maximum).Maximum)ms"

# --- Fill 150k lines ------------------------------------------------------------
& $exe +send-keys --target=$pane 'for /l %i in (1,1,150000) do @echo PROFGROW %i abcdefghijklmnopqrstuvwxyz0123456789' Enter | Out-Null
$fillMs = WaitVisible $pane 'PROFGROW 150000' 180000
Assert ($fillMs -ge 0) "150k-line fill completed (${fillMs}ms)"
Start-Sleep -Seconds 2

# --- 2. Input latency, 150k scrollback ------------------------------------------
$latBig = @()
for ($i = 1; $i -le $LatencyProbes; $i++) {
    $p = LatencyProbe $pane "klatb$i" 5000
    if ($p.Ms -ge 0) { $latBig += $p.Ms } else { Rep "WARN probe klatb$i failed: $($p.Why)/$($p.Ms)" }
}
$medFresh = MedianOf $latFresh
$medBig = MedianOf $latBig
Rep "input latency (150k scrollback): n=$($latBig.Count) median ${medBig}ms max $(($latBig | Measure-Object -Maximum).Maximum)ms"
Assert (($latFresh.Count -ge 4) -and ($latBig.Count -ge 4)) 'enough latency probes landed on both sides'
Assert ($medBig -lt 500) "median keyboard latency at 150k lines < 500ms (${medBig}ms)"
Assert ($medBig -le ([Math]::Max($medFresh * 3, $medFresh + 100))) "no gross degradation vs fresh pane (${medFresh}ms -> ${medBig}ms)"

# --- 3. Scrollback-seek, idle ----------------------------------------------------
'phase,key_index,rtt_ms' | Set-Content -Encoding ascii $rttCsv
$hashBottom = [ProfDrv]::PixelHash($surface)
$slice0 = PerfSlice 0
$logMark = $slice0.NewLen

$r = [ProfDrv]::Chord($top, @([uint16]0x11), 0x24)  # ctrl+home = scroll_to_top
Assert ($r -eq 'SENT') "ctrl+home sent ($r)"
Start-Sleep -Milliseconds 300
$rttTop = [ProfDrv]::NullRtt($top, 2000)
$hashTop = [ProfDrv]::PixelHash($surface)
Assert (($hashTop -notmatch 'FAIL|EMPTY|NORECT') -and ($hashTop -ne $hashBottom)) 'viewport moved on scroll_to_top (pixel hash changed)'
Rep "GUI thread RTT right after scroll_to_top: ${rttTop}ms"

$burst = [ProfDrv]::SeekBurst($top, 0x22, $SeekKeys, 2000)  # shift+pgdn from top
if ($burst -like 'ABORT*') { Rep "SKIP idle seek burst: $burst"; $script:skipped++ }
else {
    $rtts = @($burst -split ',' | ForEach-Object { [long]$_ })
    $i = 0; foreach ($v in $rtts) { Add-Content -Encoding ascii $rttCsv "idle,$i,$v"; $i++ }
    $bad = @($rtts | Where-Object { $_ -lt 0 })
    Rep "idle seek burst (shift+pgdn x$($rtts.Count)): median RTT $(MedianOf $rtts)ms max $(($rtts | Measure-Object -Maximum).Maximum)ms timeouts $($bad.Count)"
    Assert ($bad.Count -eq 0) 'idle seek: no GUI-thread stall > 2s'
    Assert ((MedianOf $rtts) -lt 100) "idle seek: median GUI RTT < 100ms ($(MedianOf $rtts)ms)"
}
$r = [ProfDrv]::Chord($top, @([uint16]0x11), 0x23)  # ctrl+end
Start-Sleep -Milliseconds 300
$sliceIdle = PerfSlice $logMark
$logMark = $sliceIdle.NewLen
if ($sliceIdle.Fps.Count -gt 0) {
    Rep "idle seek renderer: fps median $(MedianOf $sliceIdle.Fps) worst gap $(($sliceIdle.Gaps | Measure-Object -Maximum).Maximum)ms ($($sliceIdle.Fps.Count) windows)"
}

# --- 4. Scrollback-seek under same-pane storm -------------------------------------
& $exe +send-keys --target=$pane 'for /l %i in (1,0,2) do @echo STORM %i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' Enter | Out-Null
Start-Sleep -Seconds 2

$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $exe +read --name=$pane --lines=50 | Out-Null
$sw.Stop()
Rep "+read mid-storm: $($sw.ElapsedMilliseconds)ms"
Assert ($sw.ElapsedMilliseconds -lt 2000) "+read mid-storm < 2s (T62 bound on this build: $($sw.ElapsedMilliseconds)ms)"

$f2 = [ProfDrv]::Focus($top, $surface)
if ($f2 -ne 'OK') { Rep "SKIP storm seek: $f2"; $script:skipped++ }
else {
    $r = [ProfDrv]::Chord($top, @([uint16]0x11), 0x24)  # ctrl+home
    Start-Sleep -Milliseconds 300
    $burst2 = [ProfDrv]::SeekBurst($top, 0x22, $SeekKeys, 5000)
    if ($burst2 -like 'ABORT*') { Rep "SKIP storm seek burst: $burst2"; $script:skipped++ }
    else {
        $rtts2 = @($burst2 -split ',' | ForEach-Object { [long]$_ })
        $i = 0; foreach ($v in $rtts2) { Add-Content -Encoding ascii $rttCsv "storm,$i,$v"; $i++ }
        $bad2 = @($rtts2 | Where-Object { $_ -lt 0 })
        Rep "storm seek burst (shift+pgdn x$($rtts2.Count)): median RTT $(MedianOf $rtts2)ms max $(($rtts2 | Measure-Object -Maximum).Maximum)ms timeouts $($bad2.Count)"
        Assert ($bad2.Count -eq 0) 'storm seek: no GUI-thread stall > 5s'
        Assert ((MedianOf $rtts2) -lt 250) "storm seek: median GUI RTT < 250ms ($(MedianOf $rtts2)ms)"
    }
    $r = [ProfDrv]::Chord($top, @([uint16]0x11), 0x23)  # ctrl+end
    Start-Sleep -Milliseconds 300
    $sliceStorm = PerfSlice $logMark
    if ($sliceStorm.Fps.Count -gt 0) {
        Rep "storm seek renderer: fps median $(MedianOf $sliceStorm.Fps) worst gap $(($sliceStorm.Gaps | Measure-Object -Maximum).Maximum)ms ($($sliceStorm.Fps.Count) windows)"
    }
}

Assert (-not $proc.HasExited) 'gui alive at end'
[ProfDrv]::Release()

# --- Teardown --------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $exe +close --target=prof 2>$null | Out-Null
$sw.Stop()
Rep "+close of storming window: $($sw.ElapsedMilliseconds)ms"
Assert ($sw.ElapsedMilliseconds -lt 10000) "+close returns < 10s (T63 bound: $($sw.ElapsedMilliseconds)ms)"
Start-Sleep -Seconds 2
$proc.Refresh()
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }

} finally { $env:LOCALAPPDATA = $realLocalAppData }

Rep ''
if ($script:fail -eq 0) { Rep "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" })) - report: $report" }
else { Rep "$script:fail FAILURE(S) / $script:pass passed - report: $report"; exit 1 }

