# HoverCapture.ps1 - capture a window's HOVERED frame off the background
# desktop (T282).
#
# WHY THIS EXISTS. A posted WM_MOUSEMOVE cannot survive to the paint it
# dirties. There is no real cursor on a background desktop, so TrackMouseEvent
# - which watches the real one - makes the OS post WM_MOUSELEAVE within a
# frame; WM_PAINT is the LOWEST-priority message in a thread's queue, so the
# leave is always drained before the paint, and the frame that gets painted is
# the un-hovered one. T209 measured it: 300 posted moves in bursts of 25,
# interleaved with PrintWindow captures, never once caught a lit fill - not on
# the close "x", not on the "+" that has lit a fill since long before T204.
# It is an ORDERING problem, not a timing one, so no faster capture wins it,
# and every hover FILL in the win32 chrome was therefore a SKIP (tab-strip's
# 4c, pane-banner's 6g) or a per-site workaround through a state that happens
# to survive a leave (split-divider's DRAG, caption-bar's caption_pressed).
#
# WHAT THIS DOES INSTEAD. The app runs the whole probe itself, inside one
# handler on its GUI thread: hit-test the point, SEND the move (a sent message
# is a direct call to the window procedure when sender and target share a
# thread), force the repaint with RedrawWindow(RDW_UPDATENOW) - also
# synchronous - and PrintWindow the result. The message loop is never reached
# between the move and the capture, and a POSTED message is only ever drained
# by the message loop, so the leave cannot land in the middle. Nothing has to
# be un-done: the leave arrives on the next pump and clears the hover exactly
# as it does today.
#
# The pixels are the same pixels Get-TestWindowPixels -Sync reads - the same
# synchronous PrintWindow (no flags, so WM_PRINT -> WM_PRINTCLIENT), made from
# inside instead of outside - so a probe migrates by swapping the capture call
# and keeping its math. It was PW_RENDERFULLCONTENT until T845, and that DWM
# copy is asynchronous: about one run in ten it handed back a frame painted
# BEFORE the hover, which pane-banner.ps1 saw as a chevron that never lit. Same
# consequence as the -Sync switch on this side, and the same fix.
#
# WHAT IT IS NOT. There is deliberately no `ghoztty +capture-hover` CLI verb,
# for the reason there is no `+capture-pane` one: `src/cli/ghostty.zig`'s
# action enum is shared by every apprt, so a verb there is a cross-platform CLI
# surface (the T141 rule). The action is reachable only over the IPC endpoint
# and only from a Debug/ReleaseSafe build - which is every build an acceptance
# script is allowed to run against anyway (T350). Hence the hand-framed request
# below rather than a `& $exe +...` call.

Set-StrictMode -Off
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# The IPC plumbing (Invoke-GhozttyIpc, Get-GhozttyPipeName) lives in
# PaneCapture.ps1 - one framer for both debug-only capture actions, rather than
# a second copy of the length-prefix protocol to keep in step.
if (-not (Get-Command Invoke-GhozttyIpc -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'PaneCapture.ps1')
}

<#
Capture a window painted while a SCREEN point of it is hovered:

    $shot = Get-TestHoverCapture -Hwnd $top -X $sx -Y $sy
    $px   = $shot.Bitmap.GetPixel($lx, $ly)
    Close-TestHoverCapture $shot

Returns the same shape as Get-TestWindowPixels - { Bitmap, Width, Height,
Left, Top } with Left/Top the window rect's screen origin - so Get-TestPixel /
Get-TestBrightness / Get-TestDistinctColors and every migrated probe's own
local-coordinate math work against it unchanged.

Also carries { Hit, NonClient }: the WM_NCHITTEST answer the app got at that
point and whether it therefore routed the NON-client twin of the move, the
same decision Send-TestMouse makes (T263). ASSERT THEM when the point is
supposed to be a particular control - a probe that landed on the wrong route
and a probe that landed on a control which did not light look identical in
pixels.

And { Changed }: whether the move altered a single pixel of the window, which
the app answers by photographing the window BEFORE the move as well (T845).
ASSERT IT on any probe whose point is supposed to light something - a capture
that silently came back un-hovered is the one failure of this action that looks
exactly like a success, and comparing it against a separately-taken "rest" shot
is a weaker test than asking the app whether anything moved. A probe hovering
dead space asserts $false and gets a sharper oracle than "these two pixels are
close".

-Client forces the client message even where the point hit-tests non-client,
the twin of Send-TestMouse -Client.

$null on failure, with the server's reason in Get-LastHoverCaptureError so a
caller can put it in the assertion label: a capture that failed for a fixture
reason and one that failed because nothing lit must not look the same.
#>
function Get-TestHoverCapture {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [switch]$Client,
        [string]$PipeName,
        [string]$Path,
        [switch]$KeepFile
    )
    $script:LastHoverCaptureError = $null
    if (-not $Path) {
        $Path = Join-Path $env:TEMP ("ghoztty-hover-capture-{0}.png" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    Remove-Item $Path -ErrorAction SilentlyContinue

    $args = @("--hwnd=$([int64]$Hwnd)", "--x=$X", "--y=$Y", "--path=$Path")
    if ($Client) { $args += '--client' }

    $resp = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments $args -PipeName $PipeName
    if ($null -eq $resp) {
        $script:LastHoverCaptureError = 'no response from the IPC endpoint'
        return $null
    }
    if (-not $resp.success) {
        $script:LastHoverCaptureError = "$($resp.error)"
        return $null
    }
    if (-not (Test-Path $Path)) {
        $script:LastHoverCaptureError = "server reported success but '$Path' does not exist"
        return $null
    }

    # Decode from memory so the file can be deleted immediately: Bitmap::FromFile
    # keeps the file locked for the object's whole life, which strands a temp
    # file behind every capture.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (-not $KeepFile) { Remove-Item $Path -ErrorAction SilentlyContinue }
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    try {
        $bmp = [System.Drawing.Image]::FromStream($ms)
    } catch {
        $script:LastHoverCaptureError = "capture is not a readable image: $($_.Exception.Message)"
        return $null
    }

    return [pscustomobject]@{
        Bitmap    = $bmp
        Width     = [int]$resp.data.width
        Height    = [int]$resp.data.height
        Left      = [int]$resp.data.left
        Top       = [int]$resp.data.top
        Hit       = [int]$resp.data.hit
        NonClient = [bool]$resp.data.nonclient
        Changed   = [bool]$resp.data.changed
        Path      = $Path
        Bytes     = [int]$resp.data.bytes
    }
}

function Close-TestHoverCapture {
    param($Shot)
    if ($Shot -and $Shot.Bitmap) { $Shot.Bitmap.Dispose() }
}

# The reason the last Get-TestHoverCapture returned $null.
function Get-LastHoverCaptureError { return $script:LastHoverCaptureError }

<#
Is this build's `capture-hover` seam reachable at all?

A ReleaseFast build answers "unknown action: capture-hover", exactly as it does
for a verb it has never heard of - so a script can tell "the seam is compiled
out" (a legitimate SKIP, named in the verdict) from "the capture failed",
without either wearing the other's clothes.
#>
function Test-HoverCaptureAvailable {
    param([string]$PipeName)
    # A deliberately invalid request: a build WITH the seam refuses it by
    # naming the flag, a build without it answers "unknown action".
    $resp = Invoke-GhozttyIpc -Action 'capture-hover' -Arguments @('--hwnd=0') -PipeName $PipeName
    if ($null -eq $resp) { return $false }
    if ($resp.success) { return $true }
    return ("$($resp.error)" -notmatch 'unknown action')
}
