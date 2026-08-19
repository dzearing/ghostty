# T947 acceptance: a copy issued while another process holds the clipboard must
# still land.
#
# THE DEFECT. `OpenClipboard` does not queue. It fails outright while any other
# process on the desktop holds the clipboard, and something routinely does for a
# few milliseconds after a copy - the copying app itself, Explorer, a
# clipboard-history service, an RDP clipboard bridge. Both clipboard call sites
# in `Surface.zig` took a single attempt and gave up, so the user's copy (or
# paste) silently did nothing, at random, with no message. `clipboard_open.open`
# (eight attempts, 15ms apart) is the fix; this script is what proves the retry
# is actually in the terminal's path rather than merely present in the tree.
#
# HOW A COPY IS ISSUED WITHOUT TOUCHING THE GUI. OSC 52 is the terminal escape
# for "put this on the clipboard", and it lands on the same `Surface.setClipboard`
# the copy keybinding does. ConPTY passes it through, so a command run IN the
# pane can perform a real copy - no desktop, no SendInput, no selection. That is
# the whole reason this script is headless and cheap enough to gate on.
#
# THE THREE ARMS, and why each is needed:
#
#   A  ORACLE SENSITIVITY (the negative control). A hold far LONGER than the
#      retry budget must produce a LOST copy - the token never reaches the
#      clipboard, and the app says so on stderr. Without this arm, arm B could
#      pass because the harness cannot create the condition at all, which is the
#      classic way a retry test proves nothing.
#   B  THE FIX. A hold SHORTER than the budget, repeated so that a single
#      attempt would lose most of the time (45ms held, 25ms free), must not cost
#      a single copy: every one of eight tokens lands. The numbers are worked
#      out at the arm itself - the retry wins deterministically, and eight
#      single attempts surviving the same churn is a 1-in-3500 accident.
#   C  NO SINGLE-ATTEMPT OPEN LEFT. The source guard that keeps the next
#      clipboard call site from reintroducing the bug - `w32.OpenClipboard`
#      appears only inside `clipboard_open.zig`. This is also what covers the
#      PASTE site, whose behavior belongs to clipboard-paste.ps1 (it needs real
#      ctrl+v on a desktop) but whose retry is the same one line.
#
# THE CLIPBOARD IS NOT ISOLATABLE. It is one machine-wide resource scoped to the
# window station, so unlike the IPC endpoint it cannot be given a private twin:
# this script necessarily writes the real clipboard. It saves the user's text
# first and puts it back at the end, and it never runs longer than a few seconds
# with the clipboard held.
#
# Non-interactive; asserts and exits nonzero on any failure. Private IPC
# endpoint (T441). Only ever kills ghoztty processes launched from this repo's
# zig-out.
#
#   powershell -NoProfile -File test\win32\clipboard-retry.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

$script:failures = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

$root = Join-Path $env:TEMP "ghoztty-clipboard-retry-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$errlog = Join-Path $root 'app-stderr.log'
$outlog = Join-Path $root 'app-stdout.log'
$holderPs1 = Join-Path $root 'holder.ps1'
$holderReady = Join-Path $root 'holder-ready'
$holderStop = Join-Path $root 'holder-stop'

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

Add-Type -AssemblyName System.Windows.Forms

# The same two entry points the app uses, so this script can measure a hold
# rather than trust it.
Add-Type -Namespace T947Probe -Name Clip -MemberDefinition @"
[DllImport("user32.dll", SetLastError=true)] public static extern int OpenClipboard(IntPtr hWnd);
[DllImport("user32.dll", SetLastError=true)] public static extern int CloseClipboard();
"@

# powershell.exe is STA by default, which System.Windows.Forms.Clipboard
# requires. Bail loudly rather than producing confusing failures if not.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    'SETUP FAIL: run under an STA host (powershell.exe, not -MTA)'
    exit 1
}

function Stop-TestProcs {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
}

function Get-ClipText {
    # Long enough to outlast a churning holder: the clipboard is a shared
    # resource here, so a read is retried for the same reason a write is.
    for ($t = 0; $t -lt 20; $t++) {
        try { return [System.Windows.Forms.Clipboard]::GetText() } catch { Start-Sleep -Milliseconds 30 }
    }
    return $null
}
function Set-ClipText([string]$text) {
    for ($t = 0; $t -lt 12; $t++) {
        try {
            if ($text -eq '') { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetText($text) }
            return $true
        } catch { Start-Sleep -Milliseconds 40 }
    }
    return $false
}

# ---- the holder -------------------------------------------------------------
# A separate PROCESS is not a convenience here, it is the mechanism: clipboard
# ownership is per-task, so a second thread of this process would be HANDED the
# clipboard rather than refused, and would reproduce nothing.
#
# The hold must be taken with a real HWND. `OpenClipboard(NULL)` succeeds and
# looks like a hold, but it excludes nobody - the refusal test is "another
# WINDOW has the clipboard open", and a null owner is not a window (measured
# while writing this: with a null owner every probing process opened the
# clipboard straight through, and the arms below passed vacuously). A hidden
# Form supplies the window.
#
# -HoldMs 0 means "hold continuously until told to stop" (arm A); a positive
# value churns - hold that long, release for -GapMs, take it again (arm B).
@'
param([string]$Ready, [string]$Stop, [int]$HoldMs = 0, [int]$GapMs = 25)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace T947 -Name Clip -MemberDefinition @"
[DllImport("user32.dll", SetLastError=true)] public static extern int OpenClipboard(IntPtr hWnd);
[DllImport("user32.dll", SetLastError=true)] public static extern int CloseClipboard();
"@
$form = New-Object System.Windows.Forms.Form
$hwnd = $form.Handle
$held = $false
for ($i = 0; $i -lt 200; $i++) {
    if ([T947.Clip]::OpenClipboard($hwnd) -ne 0) { $held = $true; break }
    [Threading.Thread]::Sleep(20)
}
if (-not $held) { [IO.File]::WriteAllText("$Ready.err", 'could not take the clipboard'); exit 1 }
[IO.File]::WriteAllText($Ready, "$hwnd")
# Pure .NET below: a cmdlet round trip is far coarser than the millisecond
# windows this is shaping.
if ($HoldMs -le 0) {
    while (-not [IO.File]::Exists($Stop)) { [Threading.Thread]::Sleep(20) }
} else {
    while (-not [IO.File]::Exists($Stop)) {
        [Threading.Thread]::Sleep($HoldMs)
        [void][T947.Clip]::CloseClipboard()
        [Threading.Thread]::Sleep($GapMs)
        [void][T947.Clip]::OpenClipboard($hwnd)
    }
}
[void][T947.Clip]::CloseClipboard()
'@ | Set-Content -Path $holderPs1 -Encoding UTF8

function Start-Holder([int]$HoldMs, [int]$GapMs) {
    Remove-Item $holderReady, "$holderReady.err", $holderStop -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $holderPs1,
        '-Ready', $holderReady, '-Stop', $holderStop, '-HoldMs', $HoldMs, '-GapMs', $GapMs
    )
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $holderReady) { return $p }
        if (Test-Path "$holderReady.err") { return $null }
        Start-Sleep -Milliseconds 100
    }
    return $null
}
function Stop-Holder($p) {
    New-Item -ItemType File -Force $holderStop | Out-Null
    if ($null -ne $p) {
        if (-not $p.WaitForExit(5000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 200
}

# ---- driving a copy from inside the pane ------------------------------------
# The pane's shell is cmd, which cannot emit a raw ESC on its own, so the copy
# is performed by a one-line powershell it launches. Warming that launch once
# matters: a cold powershell start is most of a second, and arm A's hold has to
# still be up when the escape arrives.
$sq = [char]39
function Copy-Command([string]$token) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($token))
    return 'powershell -NoProfile -Command "[Console]::Out.Write([char]27+' + $sq + ']52;c;' + $b64 + $sq + '+[char]7)"'
}
function Send-Copy($pane, [string]$token) {
    $null = (& $Exe +send-keys "--target=$pane" --enter -- (Copy-Command $token) 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String)
}
function Wait-Clip([string]$token, [int]$timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ClipText) -eq $token) { return $true }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function First-Pane {
    $out = (& $Exe +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    if ($out -match '"id"\s*:\s*"([0-9A-Fa-f-]{36})"') { return $matches[1] }
    return $null
}

# ============================================================================
'== setup'
# ============================================================================
Assert 'ghoztty.exe exists in zig-out' (Test-Path $Exe)
Assert-GhozttyIsolatedBuild -Exe $Exe
[void](Set-GhozttyTestIsolation -Tag 'clipretry')
Stop-TestProcs
Assert-GhozttyPrivateEndpoint -Exe $Exe

$savedClip = Get-ClipText

try {
    $app = Start-Process -FilePath $Exe -PassThru `
        -ArgumentList '--session-persistence=false' `
        -RedirectStandardError $errlog -RedirectStandardOutput $outlog
    $null = $app.Handle

    $pane = $null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $pane = First-Pane
        if ($pane) { break }
    }
    Assert 'the app opened a terminal pane' ($null -ne $pane)
    if (-not $pane) { throw 'no pane; nothing below can run' }
    Assert-GhozttyIsolated -Exe $Exe

    # Warm the copy path once, with nobody holding the clipboard. This doubles
    # as the positive control: if an unobstructed OSC 52 copy does not land,
    # every arm below would fail for a reason that has nothing to do with the
    # retry.
    [void](Set-ClipText 'clipboard-retry-warmup')
    $warm = "t947-warm-$PID"
    Send-Copy $pane $warm
    $warmed = Wait-Clip $warm 20000
    Assert 'an unobstructed OSC 52 copy reaches the clipboard (positive control)' $warmed
    if (-not $warmed) { throw 'the copy path itself is not working; the arms below would be vacuous' }

    # ========================================================================
    '== A: a hold LONGER than the retry budget loses the copy (oracle sensitivity)'
    # ========================================================================
    # 8 attempts x 15ms is ~120ms of budget. A continuous hold is two orders of
    # magnitude past it, so the write cannot succeed however hard it retries -
    # which is exactly what makes arm B's "every copy landed" mean something.
    $lostToken = "t947-lost-$PID"
    [void](Set-ClipText 'clipboard-retry-before-A')
    $errBefore = if (Test-Path $errlog) { (Get-Content $errlog -Raw) } else { '' }

    $holderA = Start-Holder 0 0
    Assert 'A1 the holder took the clipboard' ($null -ne $holderA)
    if ($null -ne $holderA) {
        # The hold is asserted, not assumed: a single attempt from THIS process
        # must be refused while it stands. Without this, A2/A3 could pass or
        # fail for reasons that have nothing to do with the app.
        Assert 'A1b a single OpenClipboard attempt is refused while it is held' `
            ([T947Probe.Clip]::OpenClipboard([IntPtr]::Zero) -eq 0)
        $sentAt = Get-Date
        Send-Copy $pane $lostToken
        "      (copy issued $([int]((Get-Date) - $sentAt).TotalMilliseconds)ms after the send call returned)"
        # Long enough for the warmed powershell to run and the app to exhaust
        # its budget several times over, and still well inside the hold.
        Start-Sleep -Milliseconds 4000
        $errAfter = if (Test-Path $errlog) { (Get-Content $errlog -Raw) } else { '' }
        $newErr = if ($errAfter.Length -gt $errBefore.Length) { $errAfter.Substring($errBefore.Length) } else { '' }
        $sawRefusal = ($newErr -match 'OpenClipboard failed for clipboard write')
        Assert 'A2 the app reports the refused clipboard write' $sawRefusal
        if (-not $sawRefusal) {
            "      (stderr since the arm began, $($newErr.Length) chars:)"
            ($newErr -split "`r?`n" | Select-Object -Last 12) | ForEach-Object { "      | $_" }
        }
        Stop-Holder $holderA
        # Nothing re-drives a write that already gave up, so the token must
        # still be absent after the clipboard is free again.
        Start-Sleep -Milliseconds 1200
        Assert 'A3 the copy is LOST - the token never reached the clipboard' `
            ((Get-ClipText) -ne $lostToken)
    }

    # ========================================================================
    '== B: a hold SHORTER than the budget costs no copies (the fix)'
    # ========================================================================
    # 45ms held / 25ms free, and both halves of that are chosen, not guessed.
    #
    #   the retry ALWAYS wins: 15ms between attempts means a 45ms hold can cover
    #   at most three consecutive ones, and the budget allows eight - so a free
    #   window is reached every time, however the two clocks line up. There is
    #   room for a sleep to overshoot by half again before that stops being
    #   true (it takes a >105ms hold to starve the whole budget).
    #
    #   a single attempt USUALLY loses: the clipboard is held 45 of every 70ms,
    #   so one attempt lands in a gap about a third of the time. Eight copies in
    #   a row surviving that is a 1-in-3500 accident, which is why the arm asks
    #   for all eight rather than most of them.
    $holderB = Start-Holder 45 25
    Assert 'B1 the churning holder took the clipboard' ($null -ne $holderB)
    if ($null -ne $holderB) {
        $landed = 0
        for ($i = 1; $i -le 8; $i++) {
            $tok = "t947-churn-$PID-$i"
            Send-Copy $pane $tok
            if (Wait-Clip $tok 15000) { $landed++ } else { "  (copy $i never landed)" }
        }
        Stop-Holder $holderB
        Assert "B2 all eight copies landed through the churn (got $landed/8)" ($landed -eq 8)
    }

    # ========================================================================
    '== C: no single-attempt OpenClipboard is left in src/'
    # ========================================================================
    # The regression guard. Every clipboard user goes through the retry helper,
    # so a new call site cannot quietly reintroduce the give-up-at-once shape -
    # including the PASTE read, whose behavior is clipboard-paste.ps1's to
    # prove but whose retry is this same one line.
    $zigFiles = @(Get-ChildItem -Path (Join-Path $repo 'src') -Filter '*.zig' -Recurse -File |
        Select-Object -ExpandProperty FullName)
    $hits = @(Select-String -Path $zigFiles -Pattern 'w32\.OpenClipboard' -ErrorAction SilentlyContinue)
    $outside = @($hits | Where-Object { $_.Path -notlike '*clipboard_open.zig' })
    Assert 'C1 the helper itself calls OpenClipboard (the search works at all)' `
        (@($hits | Where-Object { $_.Path -like '*clipboard_open.zig' }).Count -ge 1)
    Assert "C2 no other call site opens the clipboard directly ($($outside.Count) found)" `
        ($outside.Count -eq 0)
    foreach ($o in $outside) { "      $($o.Path):$($o.LineNumber)" }
} finally {
    New-Item -ItemType File -Force $holderStop | Out-Null
    Stop-TestProcs
    if ($null -ne $savedClip -and $savedClip -ne '') { [void](Set-ClipText $savedClip) }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this harness been run against the code as it now stands?". Only a
# green run stamps, so a red one stays due.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard clipboard-retry -Repo $repo 2>&1 | ForEach-Object { "  $($_.ToString())" }
}

if ($script:failures -eq 0) {
    "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
    exit 0
} else {
    "$($script:failures) FAILURE(S)$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
    exit 1
}
