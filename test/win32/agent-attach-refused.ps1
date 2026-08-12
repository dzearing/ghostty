# T657 acceptance: an ATTACH that yields no pane must SAY WHY, in the pane.
#
# The defect: a restored pane whose session the agent could not hand back came
# up blank, and the generic bring-up paint told the user it was blank because
# the system was "exhausting a system resource". The agent had already ANSWERED
# - `ATTACHED{status: not_found}` arrives in milliseconds, and has on every
# agent that ever shipped - but the answer stopped at a log line inside
# `Remote.threadEnter`, which returned a bare `error.RemoteAttachFailed`. This
# is the resume path: a reboot, an app upgrade, a session picked from the
# chooser. It is the failure a user meets most and the one that explained
# itself least.
#
# The arms score by OUTCOME - what the pane says, and how fast - never by log
# scraping:
#
#   C: control. The SAME manifest, unedited, restores a pane that is LIVE
#      (typed input comes back). Scored FIRST and deliberately: without it arm A
#      proves nothing (a build that failed every restore would also "pass" A),
#      so read a C failure as a broken harness/build, not a T657 regression.
#   A: the fix. With the manifest's session id rewritten to one the agent has
#      never minted, the restored pane must name a missing session in well under
#      2 s, and must not blame a timeout or a system resource.
#
#      GHOZTTY_RESTORE_PROBE_UNKNOWN=1 is what makes that reachable from a
#      script. Normally the launch restore asks the agent for its roster first
#      and gives a leaf whose session is NOT listed a null id, so it OPENs fresh
#      rather than ATTACHing (T89g) - a good rule, and one that leaves this
#      failure to the case where the roster probe DID NOT LAND (a slow or wedged
#      agent past `restore_probe_timeout_ns`). That is a real production branch
#      and the seam reproduces exactly it, deterministically, instead of racing
#      the agent for a window of milliseconds. See `AttachProbe.take`.
#   B: the age test. The same arm with GHOSTTY_AGENT_SUPPRESS_CAPS=attach_failed
#      - an agent advertising the HELLO of a build that predates 0x07 - must
#      behave IDENTICALLY. That is the design claim being checked: the
#      user-facing sentence for `not_found`/`dead`/`attached_elsewhere` is
#      derived client-side from the status the agent already sends, so it needs
#      no capability and works against an agent of any age. A regression here
#      means somebody moved that mapping onto the wire.
#
# NOT covered here, on purpose: the `ATTACH_FAILED` (0x07) frame itself. Its one
# producer today is a payload the agent could not parse, and the app never sends
# one - provoking it needs a hand-built frame, which is what the unit tests in
# `src/remote/agent/server.zig` ("ATTACH the agent cannot parse...", "...gets
# today's silence...") and `src/remote/connection.zig`
# ("attachChannelRefusable...") do. Both skew directions are asserted there.
#
# Hermetic: a per-run LOCALAPPDATA, GHOSTTY_LOCAL_AGENT_BIN and IPC pipe suffix,
# run on a BACKGROUND Win32 desktop, and it only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\agent-attach-refused.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$repo = 'D:\git\ghoztty'
$root = Join-Path $env:TEMP "ghoztty-attach-refused-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the app: the detached agent keeps its sessions, which is exactly the
# scenario (quit / crash / upgrade, then re-attach).
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the whole subject is the restore path.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit: reading `.Handle` afterwards
    # yields an EMPTY ExitCode and every `-eq 0` gate scores a working CLI FAIL.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" $timeoutSec | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return , @() }
    if ($null -ne $tree.data) { return , @($tree.data.windows) }
    return , @($tree.windows)
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-Leaves($tag, $target, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        if ((All-Leaves $tree).Count -ge $target) { return $tree }
        Start-Sleep -Milliseconds 500
    }
    return (Get-List "$tag-last")
}
function Read-Pane($id, $tag, $lines = 60) {
    Run-CliArgs @('+read', "--name=$id", "--lines=$lines") "$tmp\read-$tag.txt" 12 | Out-Null
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '')
}

function Manifest-Path { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

# Poll until the manifest records at least one leaf with a real session id -
# i.e. the app has captured an agent-backed pane worth restoring.
function Wait-Manifest($timeoutSec = 30) {
    $p = Manifest-Path
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $p) {
            $raw = Out-Text $p
            if ($raw -match '"session_id"\s*:\s*"[0-9a-fA-F]{8,}"') { return $raw }
        }
        Start-Sleep -Milliseconds 500
    }
    return ''
}

# Rewrite every recorded session id to one the agent has never minted, leaving
# the topology (and everything else the restore reads) untouched. A textual
# substitution on purpose: it changes exactly one thing, so a failure cannot be
# a manifest this script re-serialized differently.
function Break-ManifestSessionIds($raw) {
    $bogus = 'deadbeefdeadbeefdeadbeefdeadbeef'
    $edited = [regex]::Replace($raw, '("session_id"\s*:\s*")[0-9a-fA-F]{8,}(")', "`${1}$bogus`${2}")
    # ASCII, not `-Encoding utf8`: PowerShell 5.1 writes a BOM for utf8, and a
    # manifest that fails to parse is not the scenario - it would skip the
    # restore entirely and the arm would score a fresh window as a pass.
    Set-Content -Path (Manifest-Path) -Value $edited -Encoding ascii -NoNewline
    return $edited
}

# The edit is the arm's premise, so prove it landed rather than assuming it: a
# manifest that still names a real session restores fine and the arm would be
# scoring the wrong thing entirely.
function Assert-ManifestBroken($arm) {
    $now = Out-Text (Manifest-Path)
    Assert "$arm the manifest on disk now names only the bogus session" `
        (($now -match 'deadbeefdeadbeefdeadbeefdeadbeef') -and
         ($now -notmatch '"session_id"\s*:\s*"(?!deadbeef)[0-9a-fA-F]{8,}"'))
}

# Relaunch the app and poll the restored pane until it prints something matching
# $pattern. `ms` is measured from AFTER the GUI window exists - i.e. the PANE's
# own latency, with app startup left out of the number 2 s is scored against.
function Measure-RestoredMessage($tag, $pattern, $timeoutSec) {
    $script:AppLog = Join-Path $tmp "applog-$tag.err.txt"
    # persistence: on (default) - a restore is the entire point of the arm.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @() -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return @{ up = $false } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List "m-$tag"
        foreach ($leaf in All-Leaves $tree) {
            $id = [string]$leaf.id
            if (-not $id) { continue }
            $last = Read-Pane $id "msg-$tag"
            if ($last -match $pattern) {
                return @{ up = $true; hit = $true; ms = [int]$sw.Elapsed.TotalMilliseconds; text = $last }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    return @{ up = $true; hit = $false; ms = [int]$sw.Elapsed.TotalMilliseconds; text = $last }
}

# The three assertions arm A and arm B share, so the age test really is the same
# test rather than a weaker lookalike of it.
function Assert-RefusalMessage($arm, $r) {
    Assert "$arm the restored pane says it could not reconnect" $r.hit
    if (-not $r.hit) {
        # A failure here is about WORDING or about a pane that never came up,
        # and those need different fixes - so show what the pane actually said.
        Say "   (pane text was: $((($r.text) -replace '\s+', ' ').Trim()))"
        return
    }
    Say "   (message appeared after $($r.ms) ms)"
    Assert "$arm it appeared in under 2 s (got $($r.ms) ms)" ($r.ms -lt 2000)
    Assert "$arm it names the missing session as the reason" ($r.text -match 'no longer has the session')
    Assert "$arm it tells the user what to do about it" ($r.text -match 'open a new one')
    Assert "$arm it no longer blames a timeout" ($r.text -notmatch 'Timeout')
    Assert "$arm it no longer blames a system resource" ($r.text -notmatch 'exhausting a system resource')
}

# ============================================================================
# Setup
# ============================================================================
$null = Assert-GhozttyIsolatedBuild -Exe $Exe

Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{
    lad  = $env:LOCALAPPDATA
    bin  = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe = $env:GHOZTTY_PIPE_SUFFIX
    supp = $env:GHOSTTY_AGENT_SUPPRESS_CAPS
    prb  = $env:GHOZTTY_RESTORE_PROBE_UNKNOWN
}
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Isolate the IPC endpoint: every `+list` / `+read` / `+send-keys` below is an
# oracle, and a user instance answering the shared pipe would answer them about
# somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-attachrefused'
$env:GHOSTTY_AGENT_SUPPRESS_CAPS = $null
$env:GHOZTTY_RESTORE_PROBE_UNKNOWN = $null

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
Say "== S: seed - one persistent pane, recorded in the manifest"
# ============================================================================
# persistence: on (default) - the arms below restore what this launch leaves.
$app = Start-OnTestDesktop -Exe $Exe -Arguments @() -StdErr (Join-Path $tmp 'applog-seed.err.txt')
$top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
Assert "S the GUI came up" ($top -ne [IntPtr]::Zero)
$null = Wait-Leaves 's0' 1 60
$goodManifest = Wait-Manifest 30
Assert "S the manifest recorded an agent-backed pane" ($goodManifest -ne '')
Stop-AppOnly

# ============================================================================
Say "== C: control - the unedited manifest restores a LIVE pane"
# ============================================================================
if ($goodManifest -ne '') {
    # persistence: on (default) - this arm's whole subject is that the manifest S
    # left behind restores a live pane, so the flag would delete the fixture.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @() -StdErr (Join-Path $tmp 'applog-c.err.txt')
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    Assert "C the GUI came up" ($top -ne [IntPtr]::Zero)
    $tree = Wait-Leaves 'c0' 1 60
    $leaves = All-Leaves $tree
    Assert "C a pane came back" ($leaves.Count -ge 1)
    if ($leaves.Count -ge 1) {
        $id = [string]$leaves[0].id
        # A restored pane that is a frozen picture is byte-identical to a working
        # one for anything that reads the screen (T652). Type into it.
        Assert "C the restored pane is LIVE: input reaches the child, output returns" `
            (Test-PaneLive -Exe $Exe -Target $id -Tmp $tmp)
    }
    Stop-AppOnly
}

# ============================================================================
Say "== A: a session the agent never had says so, fast"
# ============================================================================
if ($goodManifest -ne '') {
    $null = Break-ManifestSessionIds $goodManifest
    Assert-ManifestBroken 'A'
    # Take the roster prefilter out of the way (see the header): without this the
    # leaf gets a null session id and OPENs a fresh shell, which is the right
    # behavior and tests nothing about a refused ATTACH.
    $env:GHOZTTY_RESTORE_PROBE_UNKNOWN = '1'
    $r = Measure-RestoredMessage 'a' 'could not reconnect' 12
    Assert "A the GUI came up" ($r.up)
    if ($r.up) { Assert-RefusalMessage 'A' $r }
    Stop-AppOnly
}

# ============================================================================
Say "== B: an agent too old to know 0x07 renders the SAME message"
# ============================================================================
if ($goodManifest -ne '') {
    # The design claim: `not_found` rides `ATTACHED.status`, which every agent
    # has always sent, so the sentence is derived on the CLIENT and owes nothing
    # to the new capability. Suppressing it must change nothing at all - if this
    # arm goes red while A is green, the mapping moved onto the wire.
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'attach_failed'
    Stop-TestProcs   # the running agent negotiated WITH the cap; make a new one
    $null = Break-ManifestSessionIds $goodManifest
    Assert-ManifestBroken 'B'
    $env:GHOZTTY_RESTORE_PROBE_UNKNOWN = '1'
    $r = Measure-RestoredMessage 'b' 'could not reconnect' 12
    Assert "B the GUI came up" ($r.up)
    if ($r.up) { Assert-RefusalMessage 'B' $r }
    # Nothing garbled the link: the app is still answering IPC about its windows.
    $tree = Get-List 'b-final'
    Assert "B the connection survived the skew (+list still answers)" `
        ((All-Leaves $tree).Count -ge 1)
}

} finally {
    Stop-TestProcs
    Stop-TestForegroundWatch
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $saved.supp
    $env:GHOZTTY_RESTORE_PROBE_UNKNOWN = $saved.prb
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host "ALL PASS ($script:passes checks)" -ForegroundColor Green; exit 0 }
Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red
exit 1
