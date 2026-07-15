# Keyboard-action acceptance: drives REAL key chords into the debug build's
# surface HWND and asserts GUI-side behavior.
#
#   T44: ctrl+shift+r in a single-tab window (hidden tab bar) opens the
#        rename edit (no crash, no invisible "mystery box"); committing
#        with Enter changes the window title.
#   T47: ctrl+k clears the primary screen (+ scrollback); on the alternate
#        screen the performable binding is unconsumed and falls through.
#
# Mechanics: SetForegroundWindow + AttachThreadInput + SetFocus(surface)
# then a short SendInput burst. Foreground is verified immediately before
# each injection and the test ABORTS (not fails) if another window owns
# it, so keystrokes can never leak into other apps. Run on an idle desktop
# for reliable results.
#
# Only touches ghoztty processes running from this repo's zig-out.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP "ghoztty-kb-actions-stderr.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

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
public class KbDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

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

    // Send mods+vk to the surface. Returns "SENT" or an ABORT/failure reason.
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

    // Chord, then immediately grab the rename EDIT, set its text, and post
    // Enter — all in one burst so a foreground steal can't outrun us (the
    // EN_KILLFOCUS commit keeps the text we set anyway).
    public static string RenameChord(IntPtr top, IntPtr surface, string title) {
        string r = Chord(top, surface, new ushort[] { 0x11, 0x10 }, 0x52); // ctrl+shift+r
        if (r != "SENT") return r;
        IntPtr edit = IntPtr.Zero;
        for (int t = 0; t < 100 && edit == IntPtr.Zero; t++) {
            Thread.Sleep(10);
            edit = FindWindowExW(top, IntPtr.Zero, "EDIT", null);
        }
        if (edit == IntPtr.Zero) return "NO EDIT within 1s";
        SendMessageW(edit, 0x000C, IntPtr.Zero, title);                  // WM_SETTEXT
        PostMessageW(edit, 0x0100, (IntPtr)0x0D, (IntPtr)0x001C0001);    // Enter
        Thread.Sleep(150);
        return "RENAMED";
    }
}
'@

# --- Setup: fresh debug instance with stderr captured -----------------------
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out\*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errlog
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [KbDrv]::FindTop([uint32]$proc.Id)
$surface = [KbDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: windows not found'; exit 1 }

$listJson = & $exe +list --json | ConvertFrom-Json
$pane = $listJson.data.windows[0].tabs[0].splits.terminal.name
$win = $listJson.data.windows[0].target

# --- T44: rename overlay in a single-tab window -----------------------------
$r = [KbDrv]::RenameChord($top, $surface, 'KBTEST_TITLE')
if ($r -like 'ABORT*') { Write-Host "SKIP T44: $r"; }
else {
    Assert ($r -eq 'RENAMED') "T44 rename edit opened and committed ($r)"
    Start-Sleep -Milliseconds 500
    Assert (-not $proc.HasExited) 'T44 no crash after ctrl+shift+r'
    $list = & $exe +list --json | Out-String
    Assert ($list -match 'KBTEST_TITLE') 'T44 title changed via rename edit'
}

# --- T47: ctrl+k clears primary screen ---------------------------------------
& $exe +send-keys --target=$win "dir C:\Windows\System32\drivers& echo KBFILL_MARKER" Enter | Out-Null
Start-Sleep -Seconds 2
$before = & $exe +read --name=$pane --lines=40 | Out-String
if ($before -notmatch 'KBFILL_MARKER') { Write-Host 'SKIP T47: fill did not land'; }
else {
    $r = [KbDrv]::Chord($top, $surface, @([uint16]0x11), 0x4B)  # ctrl+k
    if ($r -like 'ABORT*') { Write-Host "SKIP T47: $r" }
    else {
        Start-Sleep -Milliseconds 800
        Assert (-not $proc.HasExited) 'T47 no crash after ctrl+k'
        $after = & $exe +read --name=$pane --lines=40 | Out-String
        Assert ($after -notmatch 'KBFILL_MARKER') 'T47 primary screen cleared'
        Assert ((Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -Quiet)) 'T47 clear_screen io message logged'

        # Alternate screen: the performable binding must be unconsumed.
        & $exe +send-keys --target=$win "powershell -nop -c `"[console]::Write([char]27+'[?1049h')`"" Enter | Out-Null
        Start-Sleep -Seconds 3
        $clearsBefore = (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -AllMatches | Measure-Object).Count
        $r2 = [KbDrv]::Chord($top, $surface, @([uint16]0x11), 0x4B)
        if ($r2 -like 'ABORT*') { Write-Host "SKIP T47-alt: $r2" }
        else {
            Start-Sleep -Milliseconds 800
            Assert (-not $proc.HasExited) 'T47 no crash after alt-screen ctrl+k'
            $clearsAfter = (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -AllMatches | Measure-Object).Count
            Assert ($clearsAfter -eq $clearsBefore) 'T47 alt screen: clear_screen NOT consumed (fell through)'
        }
    }
}

# --- Teardown ----------------------------------------------------------------
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
