# PipeBridge.ps1 - expose a named-pipe agent on a loopback TCP port (T336).
#
# WHY THIS EXISTS. `lib\FakeRelay.ps1` bridges `ws://.../v1/client/connect` to a
# TCP agent, which is everything the roster and single-session resume needed: a
# `ghoztty-agent --listen 127.0.0.1:<port>` with a couple of sessions opened
# through it is a perfectly good "other machine".
#
# Restore All cannot use that fixture, and the reason is worth stating because it
# is a real property of the product rather than a test inconvenience. The
# topology Restore All rebuilds comes from LAYOUT BLOBS, and the only thing that
# pushes a blob is an APP pushing to ITS OWN LOCAL AGENT (`App.pushLayoutBlobs`,
# T334). A bare `--listen` agent has no app, so it holds no layouts, so a
# cross-machine Restore All against it is a correct implementation returning
# zero. The machine has to be one an app has actually lived on.
#
# On this box there is exactly one such machine: this one. Its agent listens on
# a NAMED PIPE (`\\.\pipe\ghoztty-agent[-debug]-<user>`, `LocalAgent.pipeName`),
# and the relay speaks TCP. This is the adapter between them - so the fixture
# becomes "this box's own agent, reached the way a remote machine is reached",
# and everything the app sees on that path is the real cross-machine code.
#
# HOW THE READ LOOP WORKS. FakeRelay polls `NetworkStream.DataAvailable`;
# `NamedPipeClientStream` has no such property, and a blocking `Read` in a
# single-threaded loop would wedge every other pair. Instead each pair keeps ONE
# outstanding `ReadAsync` and the loop checks `IsCompleted` - the same
# never-block-the-loop discipline, expressed with the API a pipe actually has.
#
# The pipe is opened with `PipeOptions::Asynchronous` so that read is a real
# overlapped read rather than a thread-pool thread parked in a blocking one.
#
# Loopback only, one background job, `Stop-PipeBridge` kills it. The log is the
# independent evidence that bytes crossed.

Set-StrictMode -Off

function Start-PipeBridge {
    param(
        # The loopback TCP port to listen on (what FakeRelay dials).
        [Parameter(Mandatory = $true)][int]$Port,
        # The pipe's BARE name, e.g. `ghoztty-agent-debug-David`.
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    Remove-Item $LogPath -ErrorAction SilentlyContinue

    $job = Start-Job -ScriptBlock {
        param($port, $pipeName, $logPath)

        function Write-BridgeLog([string]$m) {
            Add-Content -Path $logPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m)
        }

        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        try { $listener.Start() } catch {
            Write-BridgeLog "FATAL listen failed: $($_.Exception.Message)"
            return
        }
        Write-BridgeLog "LISTEN 127.0.0.1:$port -> pipe $pipeName"

        $pairs = New-Object System.Collections.ArrayList
        while ($true) {
            $idle = $true
            try {

                if ($listener.Pending()) {
                    $idle = $false
                    $client = $listener.AcceptTcpClient()
                    $client.NoDelay = $true
                    $ns = $client.GetStream()
                    $ns.ReadTimeout = 5000
                    $ns.WriteTimeout = 5000
                    $pipe = $null
                    try {
                        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
                            '.', $pipeName,
                            [System.IO.Pipes.PipeDirection]::InOut,
                            [System.IO.Pipes.PipeOptions]::Asynchronous)
                        $pipe.Connect(5000)
                    } catch {
                        Write-BridgeLog "REJECT pipe connect failed: $($_.Exception.Message)"
                        try { $client.Close() } catch {}
                        $pipe = $null
                    }
                    if ($null -ne $pipe) {
                        [void]$pairs.Add([pscustomobject]@{
                                Client  = $client
                                Ns      = $ns
                                Pipe    = $pipe
                                # Per-pair buffers: an outstanding ReadAsync owns
                                # its own, so one shared array would be torn.
                                InBuf   = New-Object byte[] 65536
                                OutBuf  = New-Object byte[] 65536
                                Pending = $null
                            })
                        Write-BridgeLog "PAIR up (now $($pairs.Count))"
                    }
                }

                foreach ($p in @($pairs)) {
                    $dead = $false

                    # tcp -> pipe
                    try { $avail = $p.Ns.DataAvailable } catch { $avail = $false; $dead = $true }
                    if (-not $dead -and $avail) {
                        $idle = $false
                        try { $n = $p.Ns.Read($p.InBuf, 0, $p.InBuf.Length) } catch { $n = -1 }
                        if ($n -le 0) { $dead = $true }
                        else {
                            try {
                                $p.Pipe.Write($p.InBuf, 0, $n)
                                $p.Pipe.Flush()
                            } catch { $dead = $true }
                        }
                    }

                    # pipe -> tcp, via one outstanding overlapped read.
                    if (-not $dead) {
                        if ($null -eq $p.Pending) {
                            try { $p.Pending = $p.Pipe.ReadAsync($p.OutBuf, 0, $p.OutBuf.Length) }
                            catch { $dead = $true }
                        }
                        if (-not $dead -and $p.Pending.IsCompleted) {
                            $idle = $false
                            $n = -1
                            if ($p.Pending.IsFaulted) { $dead = $true }
                            else { try { $n = $p.Pending.Result } catch { $dead = $true } }
                            $p.Pending = $null
                            if (-not $dead) {
                                # 0 bytes from a pipe read means the far end
                                # closed it - the only EOF signal there is.
                                if ($n -le 0) { $dead = $true }
                                else {
                                    try {
                                        $p.Ns.Write($p.OutBuf, 0, $n)
                                        $p.Ns.Flush()
                                    } catch { $dead = $true }
                                }
                            }
                        }
                    }

                    if ($dead) {
                        Write-BridgeLog "PAIR down"
                        try { $p.Client.Close() } catch {}
                        try { $p.Pipe.Dispose() } catch {}
                        $pairs.Remove($p)
                    }
                }

            } catch {
                # Same rule FakeRelay keeps: a shim that dies silently is
                # indistinguishable from a product bug.
                Write-BridgeLog "ERROR $($_.Exception.Message)"
            }

            if ($idle) { Start-Sleep -Milliseconds 5 }
        }
    } -ArgumentList $Port, $PipeName, $LogPath

    # Hand back a bridge that is actually listening: one that has not bound yet
    # reads exactly like one that is broken.
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $LogPath) -and (Select-String -Path $LogPath -Pattern 'LISTEN' -Quiet)) { break }
        Start-Sleep -Milliseconds 100
    }
    return $job
}

function Stop-PipeBridge {
    param($Job)
    if ($null -eq $Job) { return }
    try { Stop-Job $Job -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job $Job -Force -ErrorAction SilentlyContinue } catch {}
}

# The local agent's pipe name for THIS lineage - the same derivation
# `LocalAgent.pipeName` makes (`ghoztty-agent[-debug]-<USERNAME>`, backslashes
# sanitized). Bare name, no `\\.\pipe\` prefix.
function Get-LocalAgentPipeName {
    param([switch]$Release)
    $suffix = if ($Release) { '' } else { '-debug' }
    $user = $env:USERNAME
    if (-not $user) { $user = 'user' }
    $user = $user -replace '[\\/]', '_'
    return "ghoztty-agent$suffix-$user"
}
