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

    // Send mods+vk to the surface. Returns "SENT" or an ABORT reason.
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(150);
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
        SetForegroundWindow(win);
        Thread.Sleep(80);
        Key(vk, false); Thread.Sleep(20); Key(vk, true);
        Thread.Sleep(60);
    }
}
'@

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
