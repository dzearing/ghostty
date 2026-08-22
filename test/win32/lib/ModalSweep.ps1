# Stray Windows error dialogs, seen and named by the harness (tracker T1098).
#
# The failure this exists for: on 2026-08-22 `test\win32\upgrade-staleness.ps1`
# provoked a system-modal `Unsupported 16-Bit Application` box on the USER's
# desktop - the Windows loader answering CreateProcess on a file that was not a
# PE image - and scored `ALL PASS (123 assertions)` with it on screen. A modal
# nobody scripted is invisible to every verdict this suite computes: it is not a
# failed assertion, it is not a nonzero exit, and it blocks whatever raised it
# until a human clicks OK. The only reason it was ever known about is that the
# user happened to be looking at the screen.
#
# Scope is deliberately narrow, for the same reason lib\CleanSlate.ps1 matches on
# path and never on image name: this sweep runs on the INTERACTIVE desktop, where
# the user's own applications keep their own dialogs open, and a harness that
# closes those is worse than the bug. A `#32770` is reported only when it is
# either
#
#   * titled like a Windows hard-error box (the list below is the loader's own
#     wording, which no ordinary app uses), or
#   * owned by a process running out of the repo's `zig-out` - our own build,
#     which nothing but a test run is ever driving.
#
# Usage:
#
#   . "$PSScriptRoot\lib\ModalSweep.ps1"
#   $modals = @(Get-StrayModalDialog -ZigOut $zigOut)
#   if ($modals.Count) { ... }            # each has Title/Class/ProcessId/Reason
#   $closed = Close-StrayModalDialog -Modals $modals

Set-StrictMode -Off

if (-not ('Ghoztty.ModalSweepNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Ghoztty {
    public class ModalSweepNative {
        delegate bool EnumProc(IntPtr h, IntPtr l);

        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);

        const uint WM_CLOSE = 0x0010;

        // Every visible top-level window, as "hwnd|pid|class|title". The caller
        // filters: which of them counts as stray is a policy question and
        // policy does not belong in a P/Invoke shim.
        public static string[] Tops() {
            var lines = new List<string>();
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                uint pid; GetWindowThreadProcessId(h, out pid);
                var cls = new StringBuilder(256);
                GetClassNameW(h, cls, 256);
                var txt = new StringBuilder(512);
                GetWindowTextW(h, txt, 512);
                lines.Add(string.Format("{0}|{1}|{2}|{3}",
                    h.ToInt64(), pid, cls.ToString(), txt.ToString().Replace("|", " ")));
                return true;
            }, IntPtr.Zero);
            return lines.ToArray();
        }

        // WM_CLOSE rather than a kill: the dialog's owner is usually somebody
        // else's process (cmd.exe, or csrss on its behalf), and the thing that
        // needs to end is the modal loop, not the program.
        public static bool Close(long hwnd) {
            IntPtr h = new IntPtr(hwnd);
            if (!IsWindow(h)) return true;
            SendMessageW(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            for (int i = 0; i < 20; i++) {
                if (!IsWindow(h) || !IsWindowVisible(h)) return true;
                System.Threading.Thread.Sleep(100);
            }
            return false;
        }
    }
}
'@ -ErrorAction SilentlyContinue
}

# The Windows loader / hard-error wordings. These are shipped strings, not app
# text: an application titling its own dialog `- Bad Image` is not a thing that
# happens, so a match here is always the OS reporting a broken image.
$script:GhozttyHardErrorTitlePatterns = @(
    '^Unsupported 16-Bit Application$',
    ' - Bad Image$',
    ' - Application Error$',
    ' - System Error$',
    ' - Entry Point Not Found$',
    '^Windows cannot find ',
    '^There is no disk in the drive'
)

function Test-HardErrorDialogTitle {
    param([AllowEmptyString()][AllowNull()][string]$Title)
    if (-not $Title) { return $false }
    foreach ($p in $script:GhozttyHardErrorTitlePatterns) {
        if ($Title -match $p) { return $true }
    }
    return $false
}

<#
Visible `#32770` dialogs that a test run must not have left standing.

-ZigOut adds the ownership arm: any dialog owned by a process whose image lives
under that prefix is ours by definition. Omit it and only the hard-error titles
are reported, which is the right default for a sweep running beside the user's
own applications.

Returns records with Handle / ProcessId / ProcessName / Class / Title / Reason.
Never throws: a sweep that dies is a sweep that reports nothing.
#>
function Get-StrayModalDialog {
    param(
        [string]$ZigOut = '',
        [string[]]$ExtraClasses = @()
    )

    if (-not ('Ghoztty.ModalSweepNative' -as [type])) { return @() }

    $classes = @('#32770') + @($ExtraClasses | Where-Object { $_ })
    $prefix = ''
    if ($ZigOut) { $prefix = $ZigOut.TrimEnd('\') + '\' }

    # One CIM query, not one per dialog: the common case is zero dialogs and the
    # sweep runs between every script in a suite of 270.
    $pathByPid = @{}
    $nameByPid = @{}

    $lines = @()
    try { $lines = @([Ghoztty.ModalSweepNative]::Tops()) } catch { return @() }

    $candidates = @()
    foreach ($line in $lines) {
        $parts = $line -split '\|', 4
        if ($parts.Count -lt 4) { continue }
        if ($classes -notcontains $parts[2]) { continue }
        $candidates += [pscustomobject]@{
            Handle = [int64]$parts[0]
            Pid    = [int]$parts[1]
            Class  = $parts[2]
            Title  = $parts[3]
        }
    }
    if (-not $candidates.Count) { return @() }

    if ($prefix) {
        try {
            foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
                $pathByPid[[int]$p.ProcessId] = $p.ExecutablePath
                $nameByPid[[int]$p.ProcessId] = $p.Name
            }
        } catch { }
    }

    $found = @()
    foreach ($c in $candidates) {
        $reason = ''
        if (Test-HardErrorDialogTitle -Title $c.Title) {
            $reason = 'windows hard-error dialog'
        } elseif ($prefix) {
            $exe = $pathByPid[$c.Pid]
            if ($exe -and $exe.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $reason = 'dialog owned by a zig-out process'
            }
        }
        if (-not $reason) { continue }
        $found += [pscustomobject]@{
            Handle      = $c.Handle
            ProcessId   = $c.Pid
            ProcessName = $nameByPid[$c.Pid]
            Class       = $c.Class
            Title       = $c.Title
            Reason      = $reason
        }
    }
    return @($found)
}

# Dismiss what the sweep found, so one stray modal cannot block every script
# after it. Returns how many are gone.
function Close-StrayModalDialog {
    param([object[]]$Modals = @())
    $closed = 0
    foreach ($m in @($Modals)) {
        if (-not $m) { continue }
        try { if ([Ghoztty.ModalSweepNative]::Close([int64]$m.Handle)) { $closed++ } } catch { }
    }
    return $closed
}

# One line per modal, for a log or a FAIL message.
function Format-StrayModalDialog {
    param([object[]]$Modals = @())
    $out = @()
    foreach ($m in @($Modals)) {
        if (-not $m) { continue }
        $owner = if ($m.ProcessName) { "$($m.ProcessName) pid $($m.ProcessId)" } else { "pid $($m.ProcessId)" }
        $out += ("'{0}' [{1}] ({2}, {3})" -f $m.Title, $m.Class, $owner, $m.Reason)
    }
    return $out
}
