# T52 acceptance: build provenance visible in-app. Non-interactive; exits
# nonzero on any failure. Only touches ghoztty processes from zig-out.
#
# Covers:
#   1. `+version` prints a "Running Instance" section whose commit/mode/
#      runtime/exe/pid identify the serving instance.
#   2. `+list --json` carries the same provenance as data.build.
#   3. Palette "About Ghoztty" entry opens the About box (chord-injected;
#      the palette-popup assert is the input-injection positive control).
#   4. `+version` with no instance still succeeds and says so.
#
#   powershell -NoProfile -File test\win32\ipc-version.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-version-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

# Trimmed chord/typing driver (recipe from hero-mode.ps1 / kb-actions.ps1).
Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class VerDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, UIntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static IntPtr FindByClass(uint pid, IntPtr not, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && h != not && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // First visible CHILD of `parent` with the given class (the terminal
    // surface is a child window; EnumWindows only sees top-level ones).
    public static IntPtr FindChild(IntPtr parent, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
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

    // ctrl+shift+p with focus on `surface` (foreground-grab retries).
    public static string Chord(IntPtr top, IntPtr surface, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            Key(0x11, false); Key(0x10, false);
            Thread.Sleep(20);
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(20);
            Key(0x10, true); Key(0x11, true);
            Thread.Sleep(450);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Type plain VKs into `edit` in one attachment burst.
    public static string TypeKeys(IntPtr owner, IntPtr edit, ushort[] vks) {
        uint pid; uint tid = GetWindowThreadProcessId(owner, out pid);
        uint cur = GetCurrentThreadId();
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(edit);
            Thread.Sleep(60);
            foreach (var vk in vks) {
                Key(vk, false); Thread.Sleep(15); Key(vk, true); Thread.Sleep(30);
            }
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }
}
'@

Stop-DebugGhoztty

"== setup: one debug window"
& $Exe +new-window --target=vt 2>&1 | Out-Null
Start-Sleep -Seconds 3
$proc = Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $Exe } | Select-Object -First 1
Assert "debug instance running" ($null -ne $proc)
$expectCommit = (git -C $Repo log --pretty=format:%h -n 1)

"== 1: +version reports the running instance"
cmd /c "`"$Exe`" +version > `"$tmp\version.txt`" 2>&1"
Assert "exit 0" ($LASTEXITCODE -eq 0)
$vtxt = Get-Content "$tmp\version.txt" -Raw
Assert "Running Instance section" ($vtxt -match 'Running Instance')
Assert "commit matches HEAD ($expectCommit)" ($vtxt -match "commit\s*:\s*$([regex]::Escape($expectCommit))")
Assert "mode is Debug" ($vtxt -match 'mode\s*:\s*Debug')
Assert "runtime is win32" ($vtxt -match 'runtime\s*:\s*win32')
Assert "exe is the zig-out exe" ($vtxt -match [regex]::Escape($Exe))
Assert "pid matches server" ($vtxt -match "pid\s*:\s*$($proc.ProcessId)")
Assert "modified stamp shape" ($vtxt -match 'modified:\s*\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC')

"== 2: +list --json carries build metadata"
cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1"
$j = Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json
Assert "build object present" ($null -ne $j.data.build)
Assert "build.commit matches" ($j.data.build.commit -eq $expectCommit)
Assert "build.pid matches" ($j.data.build.pid -eq $proc.ProcessId)
Assert "build.runtime is win32" ($j.data.build.runtime -eq 'win32')
Assert "build.exe is the zig-out exe" ($j.data.build.exe -eq $Exe)

"== 3: palette About entry opens the About box"
$top = [VerDrv]::FindByClass([uint32]$proc.ProcessId, [IntPtr]::Zero, 'GhozttyWindow')
$surface = [VerDrv]::FindChild($top, 'GhozttyTerminal')
# The chord can lose the foreground race on a busy desktop (hero-mode.ps1
# has the same caveat), so retry the whole open-palette attempt.
$r = 'NOT ATTEMPTED'
$popup = [IntPtr]::Zero
foreach ($try in 1..3) {
    $r = [VerDrv]::Chord($top, $surface, 0x50)   # ctrl+shift+p
    if ($r -ne 'SENT') { continue }
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        $popup = [VerDrv]::FindByClass([uint32]$proc.ProcessId, $top, 'GhozttyTerminal')
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -ne [IntPtr]::Zero) { break }
}
if ($r -ne 'SENT') {
    "  SKIP palette test: $r"
} else {
    Assert "palette popup opened (positive control)" ($popup -ne [IntPtr]::Zero)
    $edit = [VerDrv]::FindWindowExW($popup, [IntPtr]::Zero, 'EDIT', $null)
    Assert "palette edit found" ($edit -ne [IntPtr]::Zero)
    if ($edit -ne [IntPtr]::Zero) {
        # "about" + Enter: A B O U T = 0x41 0x42 0x4F 0x55 0x54, Enter = 0x0D
        $r = [VerDrv]::TypeKeys($popup, $edit, [uint16[]]@(0x41, 0x42, 0x4F, 0x55, 0x54, 0x0D))
        Assert "about keys typed ($r)" ($r -eq 'SENT')
        $dlg = [IntPtr]::Zero
        foreach ($i in 1..20) {
            Start-Sleep -Milliseconds 250
            $dlg = [VerDrv]::FindWindowExW([IntPtr]::Zero, [IntPtr]::Zero, '#32770', 'About Ghoztty')
            if ($dlg -ne [IntPtr]::Zero) { break }
        }
        Assert "About box appeared" ($dlg -ne [IntPtr]::Zero)
        if ($dlg -ne [IntPtr]::Zero) {
            [VerDrv]::PostMessageW($dlg, 0x10, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
            Start-Sleep -Milliseconds 500
        }
        $procNow = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
        Assert "no crash after About round-trip" ($null -ne $procNow)
    }
}

"== 4: +version with no instance still succeeds"
& $Exe +close --target=vt 2>&1 | Out-Null
Start-Sleep -Seconds 1
Stop-DebugGhoztty
cmd /c "`"$Exe`" +version > `"$tmp\version2.txt`" 2>&1"
Assert "exit 0 without instance" ($LASTEXITCODE -eq 0)
Assert "none detected" ((Get-Content "$tmp\version2.txt" -Raw) -match 'none detected')

"== teardown"
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) {
    "T52 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "T52 ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
