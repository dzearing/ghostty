# PaneCapture.ps1 - read the OpenGL terminal glass off the background desktop
# (T275).
#
# WHY THIS EXISTS. The harness's CAPTURE LIMIT (see TestDesktop.ps1's header) is
# that `PrintWindow` of a `GhozttyTerminal` child returns a FLAT FILL off the
# input desktop, and there is no composite there to `GetPixel` either. So every
# assertion about what the terminal is actually SHOWING had to be dropped
# (T214): two `Get-PaneColorCount` probes in hero-mode.ps1 and window-color.ps1's
# pane-centre tint. A flat fill is a perfectly valid bitmap, which is why those
# probes could not merely be weakened - they would have scored green against a
# pane rendering nothing at all.
#
# This is the route T214 named and did not build: ask the APP for the pixels.
# The pane's own renderer thread already captures its GL content for hero mode's
# carousel thumbnails (`Surface.heroSnap*` -> `OpenGL.captureThumb`), and it
# does so for HIDDEN panes - reading the offscreen target texture, not the
# window back buffer, so no desktop, no composite and no visibility is involved.
# The debug-only `capture-pane` IPC action drives that same readback and writes
# a PNG.
#
# WHAT IT IS NOT. There is deliberately no `ghoztty +capture-pane` CLI verb:
# `src/cli/ghostty.zig`'s action enum is shared by every apprt, so a verb there
# is a cross-platform CLI surface (the T141 rule). The action is reachable only
# over the IPC endpoint and only from a Debug/ReleaseSafe build - which is every
# build an acceptance script is allowed to run against anyway (T350). Hence the
# hand-framed request below rather than a `& $exe +...` call.
#
# THE FRAMING is the one every IPC client uses: 4-byte big-endian length, then
# the JSON body, both directions (`src/os/ipc_client.zig`).

Set-StrictMode -Off
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# The app's IPC pipe for THIS run: the same derivation `ipc_client.endpointPath`
# makes. GHOZTTY_PIPE_SUFFIX is what an acceptance script sets to aim at the
# instance it just launched, so it is honoured here exactly as the CLI honours
# it; absent, a debug build's suffix is '-debug'.
function Get-GhozttyPipeName {
    param([string]$Suffix)
    if (-not $PSBoundParameters.ContainsKey('Suffix')) {
        $Suffix = $env:GHOZTTY_PIPE_SUFFIX
        if ($null -eq $Suffix) { $Suffix = '-debug' }
    }
    $user = $env:USERNAME
    if (-not $user) { $user = 'default' }
    return "ghoztty$Suffix-$user"
}

<#
Send one framed IPC request and return the parsed response object
({ success, error, data, ... }), or $null if the pipe could not be reached.

Reads are overlapped with a bounded wait: a synchronous read on a pipe whose
server is wedged has no timeout at all, and a helper that can hang forever turns
one product bug into a suite that never finishes.

-Extra adds TOP-LEVEL fields beside `action`/`arguments`. Exactly one request
shape needs it today - the launch handoff's `handoff` object (T1022), which no
CLI verb can produce because only a losing LAUNCH sends one. A harness that
wants to see the server's answer to a build it is not running has to write that
field itself.
#>
function Invoke-GhozttyIpc {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string[]]$Arguments,
        [hashtable]$Extra,
        [string]$PipeName,
        [int]$TimeoutMs = 20000
    )
    if (-not $PipeName) { $PipeName = Get-GhozttyPipeName }

    $body = @{ action = $Action }
    if ($Arguments) { $body['arguments'] = @($Arguments) }
    if ($Extra) { foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] } }
    $json = $body | ConvertTo-Json -Compress -Depth 5
    $payload = [System.Text.Encoding]::UTF8.GetBytes($json)

    $pipe = $null
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
            '.', $PipeName,
            [System.IO.Pipes.PipeDirection]::InOut,
            [System.IO.Pipes.PipeOptions]::Asynchronous)
        $pipe.Connect(5000)
    } catch {
        if ($pipe) { try { $pipe.Dispose() } catch {} }
        return $null
    }

    try {
        $len = [System.BitConverter]::GetBytes([int]$payload.Length)
        [Array]::Reverse($len)   # big-endian on the wire
        $pipe.Write($len, 0, 4)
        $pipe.Write($payload, 0, $payload.Length)
        $pipe.Flush()

        $head = Read-PipeExact $pipe 4 $TimeoutMs
        if ($null -eq $head) { return $null }
        [Array]::Reverse($head)
        $respLen = [System.BitConverter]::ToInt32($head, 0)
        if ($respLen -le 0 -or $respLen -gt 16777216) { return $null }
        $bytes = Read-PipeExact $pipe $respLen $TimeoutMs
        if ($null -eq $bytes) { return $null }
        return ([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        try { $pipe.Dispose() } catch {}
    }
}

function Read-PipeExact($pipe, [int]$count, [int]$timeoutMs) {
    $buf = New-Object byte[] $count
    $got = 0
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ($got -lt $count) {
        $task = $pipe.ReadAsync($buf, $got, $count - $got)
        $left = [int]([math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds))
        if ($left -le 0 -or -not $task.Wait($left)) { return $null }
        $n = $task.Result
        # 0 bytes from a pipe read is the far end closing it - the only EOF
        # signal there is.
        if ($n -le 0) { return $null }
        $got += $n
    }
    return $buf
}

<#
Capture a named pane's rendered content and return it as a disposable shot:

    { Bitmap, Width, Height, Left, Top, Path, Error }

The shape matches Get-TestWindowPixels on purpose, so Get-TestPixel /
Get-TestBrightness work against a pane capture unchanged. Left/Top default to 0
(capture-local coordinates); pass -Origin @($x,$y) with the pane client area's
screen origin when a migrated probe wants to keep its screen-coordinate math.

$null on failure, with the server's reason in the -ErrorVariable-style
$script:LastPaneCaptureError so a caller can put it in the assertion label - a
capture that failed for a fixture reason and one that failed because the pane
renders nothing must not look the same.
#>
function Get-TestPaneCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Width,
        [int]$Height,
        [int[]]$Origin,
        [string]$PipeName,
        [string]$Path,
        [switch]$KeepFile
    )
    $script:LastPaneCaptureError = $null
    if (-not $Path) {
        $Path = Join-Path $env:TEMP ("ghoztty-pane-capture-{0}.png" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    Remove-Item $Path -ErrorAction SilentlyContinue

    $args = @("--target=$Target", "--path=$Path")
    if ($Width -gt 0) { $args += "--width=$Width" }
    if ($Height -gt 0) { $args += "--height=$Height" }

    $resp = Invoke-GhozttyIpc -Action 'capture-pane' -Arguments $args -PipeName $PipeName
    if ($null -eq $resp) {
        $script:LastPaneCaptureError = 'no response from the IPC endpoint'
        return $null
    }
    if (-not $resp.success) {
        $script:LastPaneCaptureError = "$($resp.error)"
        return $null
    }
    if (-not (Test-Path $Path)) {
        $script:LastPaneCaptureError = "server reported success but '$Path' does not exist"
        return $null
    }

    # Read the bytes and decode from memory, so the file can be deleted right
    # away: Bitmap::FromFile keeps the file locked for the object's whole life,
    # which strands a temp file behind every capture.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (-not $KeepFile) { Remove-Item $Path -ErrorAction SilentlyContinue }
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    try {
        $bmp = [System.Drawing.Image]::FromStream($ms)
    } catch {
        $script:LastPaneCaptureError = "capture is not a readable image: $($_.Exception.Message)"
        return $null
    }

    $left = 0; $top = 0
    if ($Origin -and $Origin.Count -ge 2) { $left = [int]$Origin[0]; $top = [int]$Origin[1] }
    return [pscustomobject]@{
        Bitmap = $bmp
        Width  = [int]$resp.data.width
        Height = [int]$resp.data.height
        Left   = $left
        Top    = $top
        Path   = $Path
        Bytes  = [int]$resp.data.bytes
    }
}

function Close-TestPaneCapture {
    param($Shot)
    if ($Shot -and $Shot.Bitmap) { $Shot.Bitmap.Dispose() }
}

# The reason the last Get-TestPaneCapture returned $null.
function Get-LastPaneCaptureError { return $script:LastPaneCaptureError }

<#
Distinct colors in a pane capture, sampled on a grid - the probe T214 dropped,
restored against pixels that are actually the pane's.

A rendered terminal with a prompt and some text is many colors; a pane that
renders nothing is one. `-Inset` skips the outermost pixels so a border or the
cell grid's edge padding cannot supply the variety on its own.
#>
function Get-TestPaneColorCount {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int]$Step = 4,
        [int]$Inset = 2
    )
    if (-not $Shot -or -not $Shot.Bitmap) { return 0 }
    $seen = @{}
    $x = $Inset
    while ($x -lt ($Shot.Bitmap.Width - $Inset)) {
        $y = $Inset
        while ($y -lt ($Shot.Bitmap.Height - $Inset)) {
            $p = $Shot.Bitmap.GetPixel($x, $y)
            $seen["$($p.R),$($p.G),$($p.B)"] = $true
            $y += $Step
        }
        $x += $Step
    }
    return $seen.Count
}

# The most common color in a pane capture, as "r,g,b" - what a terminal's
# BACKGROUND is by definition, since most of a pane is background. This is the
# oracle for a tint reaching the GL clear color.
function Get-TestPaneDominantColor {
    param(
        [Parameter(Mandatory = $true)]$Shot,
        [int]$Step = 4,
        [int]$Inset = 2
    )
    if (-not $Shot -or -not $Shot.Bitmap) { return $null }
    $counts = @{}
    $x = $Inset
    while ($x -lt ($Shot.Bitmap.Width - $Inset)) {
        $y = $Inset
        while ($y -lt ($Shot.Bitmap.Height - $Inset)) {
            $p = $Shot.Bitmap.GetPixel($x, $y)
            $key = "$($p.R),$($p.G),$($p.B)"
            if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
            $y += $Step
        }
        $x += $Step
    }
    if ($counts.Count -eq 0) { return $null }
    $best = $null; $bestN = -1
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $bestN) { $best = $k; $bestN = $counts[$k] } }
    return $best
}

# Channel-wise distance between an "r,g,b" string and a target triple. Captures
# come off a GL surface, so an exact match is not something to insist on: sRGB
# handling and any per-pixel blending can move a channel by a step or two.
function Test-PaneColorNear {
    param(
        [string]$Color,
        [int]$R, [int]$G, [int]$B,
        [int]$Tolerance = 6
    )
    if (-not $Color) { return $false }
    $parts = $Color -split ','
    if ($parts.Count -ne 3) { return $false }
    return ([math]::Abs([int]$parts[0] - $R) -le $Tolerance -and
            [math]::Abs([int]$parts[1] - $G) -le $Tolerance -and
            [math]::Abs([int]$parts[2] - $B) -le $Tolerance)
}
