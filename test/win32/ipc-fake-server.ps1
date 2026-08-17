# Fake Ghoztty IPC pipe server for validating the CLI client (task T03).
#
# Binds the same named pipe a real instance would own, accepts ONE
# connection, prints the framed JSON request it receives, and replies with
# a canned framed response. Run it in one shell, then in another:
#
#   .\ghoztty.exe +list            # against a ReleaseFast exe
#   .\ghoztty.exe +close --target=x
#
# The exe decides the pipe name from its build config:
#   ReleaseFast -> \\.\pipe\ghoztty-<username>          (default here)
#   Debug       -> \\.\pipe\ghoztty-debug-<username>    (use -DebugPipe)
#
# Framing (both directions): 4-byte big-endian length + UTF-8 JSON.
#
# verdict-audit: a helper process, not an acceptance script. It asserts nothing
# and has no verdict to report, so it prints no ALL PASS and scores no exit code
# (T221). Do not give it one - an invented verdict would be a green line about a
# script that never checked anything.

# -Wedge (T755) is the state a bounded client has to be measured against: a
# peer that CONNECTS and reads the request and then never answers. That is not
# a hypothetical - the real server marshals every request to its GUI thread and
# waits on it with no timeout, so a busy or wedged GUI thread looks exactly
# like this from the client side. Before T755 the client blocked on it forever
# (measured at 34 minutes on 2026-08-11).
#
# -Suffix names the pipe explicitly, so an acceptance script can bind a PRIVATE
# endpoint and point the CLI at it with $GHOZTTY_PIPE_SUFFIX instead of taking
# the name a real instance (the user's, or the build under test) would use.
param(
    [switch]$DebugPipe,
    [switch]$Wedge,
    [string]$Suffix,
    [string]$Response = '{"success":true,"data":{"windows":[]}}'
)

# isolation: none - this is the SERVER half: it binds a pipe and answers, and
# never dials one; the +verbs above are usage examples for the shell that runs
# the client. Callers isolate via -Suffix (T680 meta-check reads this marker).

$ErrorActionPreference = 'Stop'

$sfx = if ($PSBoundParameters.ContainsKey('Suffix')) { $Suffix }
       elseif ($DebugPipe) { '-debug' }
       else { '' }
$name = "ghoztty$sfx-$env:USERNAME"
$pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
    $name,
    [System.IO.Pipes.PipeDirection]::InOut,
    1  # maxNumberOfServerInstances
)

Write-Host "listening on \\.\pipe\$name (one request, then exit)"
$pipe.WaitForConnection()

function Read-Exact([System.IO.Pipes.NamedPipeServerStream]$stream, [int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stream.Read($buf, $off, $count - $off)
        if ($n -eq 0) { throw "pipe closed after $off/$count bytes" }
        $off += $n
    }
    return $buf
}

$lenBuf = Read-Exact $pipe 4
if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBuf) }
$len = [BitConverter]::ToUInt32($lenBuf, 0)
if ($len -eq 0 -or $len -gt 1MB) { throw "implausible request length: $len" }

$body = Read-Exact $pipe ([int]$len)
$json = [Text.Encoding]::UTF8.GetString($body)
Write-Host "request ($len bytes): $json"

if ($Wedge) {
    # Hold the connection open and answer nothing, until the caller kills us.
    # The client is the subject here; this process only has to keep existing.
    Write-Host "WEDGED: holding the connection open, sending no response"
    while ($true) { Start-Sleep -Seconds 3600 }
}

$respBytes = [Text.Encoding]::UTF8.GetBytes($Response)
$rlen = [BitConverter]::GetBytes([uint32]$respBytes.Length)
if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($rlen) }
$pipe.Write($rlen, 0, 4)
$pipe.Write($respBytes, 0, $respBytes.Length)
$pipe.Flush()
$pipe.WaitForPipeDrain()
$pipe.Disconnect()
$pipe.Dispose()

Write-Host "responded with: $Response"
Write-Host "OK"
