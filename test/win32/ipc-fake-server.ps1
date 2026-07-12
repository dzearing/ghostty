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

param(
    [switch]$DebugPipe,
    [string]$Response = '{"success":true,"data":{"windows":[]}}'
)

$ErrorActionPreference = 'Stop'

$name = if ($DebugPipe) { "ghoztty-debug-$env:USERNAME" } else { "ghoztty-$env:USERNAME" }
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
