# DesktopCapability (T1100) - what the desktop a run happens on CAN DO, asked
# before the run instead of discovered as a red.
#
# THE DEFECT THIS EXISTS FOR. The GUI acceptance scripts moved onto a
# background desktop (T211) so they stop stealing the user's foreground. A
# background desktop cannot capture composited pixels and cannot accept
# SendInput - both measured, both permanent (test-desktop-spike.ps1, and the
# CAPTURE LIMIT header in lib\TestDesktop.ps1). A script whose oracle needs one
# of those therefore fails THERE for a reason that has nothing to do with the
# product, and the T1094 sweep duly produced a cluster of reds that read exactly
# like defects:
#
#     SETUP FAIL (plain): could not take the foreground
#     Get-TestWindowPixels: the capture is UNIFORM - one color over its interior
#
# A permanently-red script teaches everyone to ignore the colour, which costs
# more than the assertion was ever worth. So a missing capability is reported as
# a SKIP with the capability named, and `scripts\suite-run.ps1` counts skips
# apart from failures - the suite's colour then means "the product is right",
# not "the box we ran on happened to be able to look".
#
# THE CAPABILITIES, and where each answer comes from:
#
#   chrome-pixels   The window's own GDI painting - title bar, tab strip, menus,
#                   dialog controls, banners. Available on BOTH desktops, via
#                   PrintWindow into a memory DC (`Get-TestWindowPixels -Sync`).
#                   Not via CopyFromScreen, which is `screen-pixels` below.
#   surface-pixels  Pixels of a COMPOSITED surface - the OpenGL terminal, any
#                   WinUI/XAML window. Unavailable on a background desktop: all
#                   three capture routes were measured there by T1115 and the
#                   surface reads 1-2 distinct colors against 102 on the
#                   interactive desktop. (Route 0 - asking the app for its own
#                   pane pixels over `capture-pane` IPC, lib\PaneCapture.ps1 -
#                   is NOT this capability: it needs no desktop at all and is
#                   the way around this limit rather than an instance of it.)
#   screen-pixels   CopyFromScreen / a screen DC. DWM composes only the input
#                   desktop; BitBlt off a background desktop's DC returns FALSE.
#   real-input      SendInput actually reaching a window. Blocked outright on a
#                   background desktop (0 of 12 events accepted, ACCESS_DENIED -
#                   asserted by test-desktop-spike.ps1's INPUT-1), and MEASURED
#                   on the interactive desktop, because an input lock can eat it
#                   there too (a fullscreen game overlay swallowing SendInput has
#                   already cost this suite a run of confident, wrong reds).
#   foreground      A window can be brought to the foreground. A background
#                   desktop has no foreground window at all (GetForegroundWindow
#                   returns 0); on the interactive desktop it is measured.
#
# HOW A SCRIPT USES IT. At the top, before it launches anything:
#
#     . (Join-Path $PSScriptRoot 'lib\DesktopCapability.ps1')
#     Assert-TestDesktopCapability -Name real-input, foreground -Interactive
#
# which prints `SKIP ALL: real-input is not available here - <reason>` and
# exits 0 when the capability is missing, and is silent when it is present.
# `-Interactive` says the script drives the INPUT desktop (the declared
# interactive-by-design exceptions in lib\TestDesktop.ps1); without it the
# question is asked of the background test desktop, which is where the rest of
# the suite runs.
#
# For a capability that can only be discovered during setup - the foreground
# grab that returns false after the script is already running - there is
# `Exit-TestSkip`, which prints the same shape and exits 0:
#
#     if (-not (Grab-Foreground $hwnd)) {
#         Exit-TestSkip -Capability foreground -Reason 'an input lock owns the foreground'
#     }
#
# THE DEMONSTRATION THAT IT CAN FIRE. A capability check that has only ever said
# "available" is indistinguishable from one that cannot say anything else, so
# `GHOZTTY_TEST_FORCE_MISSING_CAPS=<name>[,<name>]` forces named capabilities
# unavailable. test-desktop-harness.ps1's capability section drives the skip
# path through it; nothing else may set it.
#
# WHAT THIS IS NOT. It is not a way to quiet a script that fails for a real
# reason. A skip is legitimate only when the BOX cannot answer the question -
# never when the answer is inconvenient. The route table in lib\TestDesktop.ps1
# still comes first: a terminal-content probe re-expressed through route 0 or
# route 1 is worth more than a skipped one, and reaching for a skip before
# reading that table is how an assertion gets quietly deleted.

# Deliberately sets no StrictMode: dot-sourced INTO suite scripts, and a mode
# set here would silently change how every one of them evaluates.

if (-not ('GhozttyDesktopCapability' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;

public class GhozttyDesktopCapability {
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public MOUSEINPUT mi; public int pad0, pad1; }

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

    public static int LastError = 0;

    // Is there a foreground window at all? Zero means this thread's desktop is
    // not the input desktop (or the shell has not come up yet).
    public static bool HasForeground() { return GetForegroundWindow() != IntPtr.Zero; }

    // A zero-delta mouse move: the smallest event SendInput will take, and it
    // moves nothing and clicks nothing. Returns the number of events accepted -
    // 0 with LastError 5 (ACCESS_DENIED) is the background-desktop / locked
    // answer, 1 is a queue that takes our input.
    public static int ProbeSendInput() {
        INPUT[] i = new INPUT[1];
        i[0].type = 0;                  // INPUT_MOUSE
        i[0].mi.dwFlags = 0x0001;       // MOUSEEVENTF_MOVE
        i[0].mi.dx = 0; i[0].mi.dy = 0;
        uint n = SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        LastError = Marshal.GetLastWin32Error();
        return (int)n;
    }
}
'@
}

$script:GhozttyCapabilityNames = @(
    'chrome-pixels', 'surface-pixels', 'screen-pixels', 'real-input', 'foreground'
)

function Get-GhozttyForcedMissingCapability {
    $raw = $env:GHOZTTY_TEST_FORCE_MISSING_CAPS
    if (-not $raw) { return @() }
    return @($raw -split '[,;\s]+' | Where-Object { $_ })
}

<#
Answer one capability for the desktop a run will use.

-Interactive asks about the INPUT desktop (a declared interactive-by-design
script); without it the question is about the background test desktop, which is
where the rest of the suite runs.

Returns { Name, Available, Reason, Measured } - Measured is $true when the
answer came from probing the box rather than from the measured-once facts about
what a background desktop can do.
#>
function Get-TestDesktopCapability {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Interactive
    )

    if ($script:GhozttyCapabilityNames -notcontains $Name) {
        throw "Get-TestDesktopCapability: unknown capability '$Name' (known: $($script:GhozttyCapabilityNames -join ', '))"
    }

    $mk = {
        param($available, $reason, $measured)
        [pscustomobject]@{ Name = $Name; Available = $available; Reason = $reason; Measured = $measured }
    }

    if ((Get-GhozttyForcedMissingCapability) -contains $Name) {
        return & $mk $false 'forced unavailable by GHOZTTY_TEST_FORCE_MISSING_CAPS' $false
    }

    if (-not $Interactive) {
        # The background test desktop. These are measured facts about what such
        # a desktop can do, not guesses - see this file's header for where each
        # was taken, and test-desktop-spike.ps1 for the assertions that keep
        # them honest.
        switch ($Name) {
            'chrome-pixels'  { return & $mk $true  'PrintWindow into a memory DC reads GDI-painted chrome on a background desktop' $false }
            'surface-pixels' { return & $mk $false 'a background desktop composes nothing: all three capture routes read the terminal surface as 1-2 distinct colors (T1115)' $false }
            'screen-pixels'  { return & $mk $false 'DWM composes only the input desktop; BitBlt off a background desktop DC returns FALSE' $false }
            'real-input'     { return & $mk $false 'SendInput is ACCESS_DENIED off the input desktop (0 of 12 accepted, test-desktop-spike.ps1 INPUT-1)' $false }
            'foreground'     { return & $mk $false 'a background desktop has no foreground window (GetForegroundWindow returns 0)' $false }
        }
    }

    # The interactive desktop. Pixels are available there by construction - it
    # is the desktop DWM composes - so only the two input answers are probed.
    switch ($Name) {
        'chrome-pixels'  { return & $mk $true 'the input desktop composes and paints normally' $false }
        'surface-pixels' { return & $mk $true 'the input desktop composes and paints normally' $false }
        'screen-pixels'  { return & $mk $true 'the input desktop composes and paints normally' $false }
        'foreground' {
            if ([GhozttyDesktopCapability]::HasForeground()) {
                return & $mk $true 'a foreground window exists on this desktop' $true
            }
            return & $mk $false 'GetForegroundWindow returned 0 - this process is not on the input desktop, or nothing owns the foreground' $true
        }
        'real-input' {
            $n = [GhozttyDesktopCapability]::ProbeSendInput()
            $err = [GhozttyDesktopCapability]::LastError
            if ($n -ge 1) { return & $mk $true 'SendInput accepted a no-op event' $true }
            $why = if ($err -eq 5) { 'ACCESS_DENIED - not the input desktop, or an input lock owns it' } else { "last error $err" }
            return & $mk $false "SendInput accepted 0 of 1 events ($why)" $true
        }
    }
}

<#
Print the SKIP-ALL line for a capability the box cannot supply, and exit 0.

Exit 0 on purpose: the script asserted nothing, and it did not fail. The verdict
line is what scripts\suite-run.ps1 scores as `skip`, and what a human reading
one line sees. The capability is NAMED in it, so a skipped run says which
question could not be asked rather than only that one could not.
#>
function Exit-TestSkip {
    param(
        [Parameter(Mandatory = $true)][string]$Capability,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    Write-Host "SKIP ALL: $Capability is not available here - $Reason"
    exit 0
}

<#
Declare what a script needs, at the top, before it launches anything.

Silent when every named capability is present; otherwise prints the SKIP ALL
line for the FIRST missing one and exits 0.
#>
function Assert-TestDesktopCapability {
    param(
        [Parameter(Mandatory = $true)][string[]]$Name,
        [switch]$Interactive
    )
    foreach ($n in $Name) {
        $cap = Get-TestDesktopCapability -Name $n -Interactive:$Interactive
        if (-not $cap.Available) { Exit-TestSkip -Capability $cap.Name -Reason $cap.Reason }
    }
}
