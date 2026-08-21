# pty-host acceptance (T904): the per-session ConPTY holder process.
#
# Sections:
#   A. End-to-end smoke: `ghoztty-agent --pty-host-smoke` spawns REAL holder
#      processes and drives them over the real control pipe. Its checks (all
#      asserted here individually off its stdout): HELLO fields, output flow,
#      RESIZE reaching the shell (`mode con` reports the new width), owner
#      death leaving the shell alive, reconnect gap-replay with contiguous
#      offsets, EXIT carrying the shell's exit code, the holder finishing
#      after delivery, and a killed holder's Job Object taking the shell
#      subtree with it. Since T905 it also drives the PRODUCTION owner client
#      (`pty_holder_child.open`, the one the agent uses) through the
#      `session.Child` vtable: output to the sink, the spawn spec's forwarded
#      `OPEN.env` reaching the shell, resize, the exit code via `tryWait`, and
#      a terminate that leaves neither shell nor holder behind.
#   B. Pipe security: a live holder's control pipe carries an owner-only DACL
#      - every access rule on it names the current user, nobody else.
#
# The smoke's holder pipe names are read back from its own log (section A) so
# section B derives the real `[-debug]` segment instead of assuming the build
# mode. Holders use per-PID session ids and the agent's `--pty-host` mode only
# - no GUI is launched, no user endpoint is shared, and only processes spawned
# by this run are touched.
#
# The agent is a GUI-subsystem binary: launched via Start-Process with
# redirected streams (PowerShell would not wait for it otherwise), gated on
# its OUTPUT (the verdict line), not its exit code.

param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$SmokeTimeoutMs = 200000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'PTY-HOST' -Reason "agent exe not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

# --- Section A: the end-to-end smoke ----------------------------------------

$outLog = Join-Path $env:TEMP "pty-host-smoke-out-$PID.log"
$errLog = Join-Path $env:TEMP "pty-host-smoke-err-$PID.log"
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $AgentExe -ArgumentList '--pty-host-smoke' `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
    -NoNewWindow -PassThru
$null = $p.Handle   # cache BEFORE any wait (T197) - though the gate below is the OUTPUT
if (-not $p.WaitForExit($SmokeTimeoutMs)) {
    try { $p.Kill() } catch {}
    Assert 'A0 smoke completed within the timeout' $false
}

$smokeOut = @(Get-Content $outLog -ErrorAction SilentlyContinue)
$smokeErr = @(Get-Content $errLog -ErrorAction SilentlyContinue)
$joined = $smokeOut -join "`n"

Assert 'A1 smoke verdict is ALL PASS' ($joined -match 'PTY-HOST SMOKE: ALL PASS')
Assert 'A2 no FAIL lines in the smoke output' (-not ($smokeOut | Where-Object { $_ -match '^FAIL' }))
Assert 'A3 hello carried the holder build stamp' ($joined -match 'ok - hello: holder build stamp present')
Assert 'A4 output flowed through the holder' ($joined -match 'ok - output flows')
Assert 'A5 resize reached the shell' ($joined -match 'ok - resize: shell reports the new width')
Assert 'A6 owner death left the shell alive' ($joined -match 'ok - owner death leaves the shell alive')
Assert 'A7 reconnect replayed the ownerless gap' ($joined -match 'ok - reconnect: gap replayed')
Assert 'A8 replay offsets were contiguous (no bytes lost)' ($joined -match 'ok - reconnect: output offsets are contiguous')
Assert 'A9 EXIT carried the shell exit code' ($joined -match 'ok - exit: shell exit code carried')
Assert 'A10 holder finished after delivering EXIT' ($joined -match 'ok - holder exits after delivering EXIT')
Assert 'A11 killing the holder killed the shell subtree (job)' ($joined -match 'ok - job-kill: killing the holder terminates the shell subtree')

# T905's production owner (`pty_holder_child.open`) — the SAME client the agent
# uses for every holder-backed session, driven through the `session.Child`
# vtable so what is proven here is what the agent will get.
Assert 'A12 production owner: holder + shell both running' (($joined -match 'ok - production owner: shell running') -and ($joined -match 'ok - production owner: holder running'))
Assert 'A13 production owner: output reaches the session sink' ($joined -match 'ok - production owner: output reaches the session sink')
Assert 'A14 production owner: forwarded OPEN.env reached the shell' ($joined -match 'ok - production owner: OPEN.env reached the shell')
Assert 'A15 production owner: resize reaches the shell' ($joined -match 'ok - production owner: resize reaches the shell')
Assert 'A16 production owner: exit code arrives via tryWait' ($joined -match 'ok - production owner: exit code via tryWait')
Assert 'A17 production owner: terminate leaves no shell and no holder' (($joined -match 'ok - production owner: terminate leaves no shell') -and ($joined -match 'ok - production owner: terminate leaves no holder'))

# --- Section B: the control pipe is owner-only ------------------------------
#
# Derive the real pipe naming (including the [-debug] segment) from the pipe
# name the smoke's holders logged, then stand up one more holder and read the
# DACL off its live pipe.

$pipePrefix = $null
foreach ($line in $smokeErr) {
    if ($line -match '\\\\\.\\pipe\\(ghoztty-pty-host\S*?)-smoke-\d+-[ab]') {
        $pipePrefix = $Matches[1]
        break
    }
}
Assert 'B1 smoke log names the holder pipe (prefix derivable)' ($null -ne $pipePrefix)

if ($null -ne $pipePrefix) {
    $sid = "acc-$PID"
    $holder = Start-Process -FilePath $AgentExe `
        -ArgumentList @('--pty-host', '--session-id', $sid, '--exit-linger-ms', '3000') `
        -WindowStyle Hidden -PassThru
    $null = $holder.Handle  # exitcode-audit: holder is killed below; nothing scores its exit code
    try {
        $pipeName = "$pipePrefix-$sid"
        $npc = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, ([System.IO.Pipes.PipeDirection]::InOut))
        $connected = $false
        for ($i = 0; $i -lt 50 -and -not $connected; $i++) {
            try { $npc.Connect(200); $connected = $true } catch { Start-Sleep -Milliseconds 100 }
        }
        Assert 'B2 holder pipe accepts this user' $connected
        if ($connected) {
            $acl = $npc.GetAccessControl()
            $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $allowRules = @($rules | Where-Object { $_.AccessControlType -eq 'Allow' })
            $foreign = @($allowRules | Where-Object { $_.IdentityReference -ne $me })
            Assert 'B3 the pipe DACL has at least one ACE' ($rules.Count -ge 1)
            Assert 'B4 every allow ACE names the current user (owner-only)' ($allowRules.Count -ge 1 -and $foreign.Count -eq 0)
        } else {
            Assert 'B3 the pipe DACL has at least one ACE' $false
            Assert 'B4 every allow ACE names the current user (owner-only)' $false
        }
        if ($null -ne $npc) { $npc.Dispose() }
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of every file this harness covers, so
# scripts\guard-due.ps1 can answer "has anything run pty-host.ps1 against the
# code as it now stands?". A red run leaves the stamp alone - red must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pty-host -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'PTY-HOST' -Pass $script:passes -Fail $script:failures
