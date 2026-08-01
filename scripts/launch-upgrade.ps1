# Launch upgrade-ghoztty-windows.ps1 detached, and PROVE it started (T200).
#
# The delivery at a task boundary is fire-and-forget by necessity: nothing in
# the Claude session's process tree can swap the exe out from under its own GUI,
# so the upgrade has to outlive the turn that starts it. That makes the launch
# the one step no one is watching, and on 2026-07-30 it failed with zero
# evidence anywhere - `Start-Process -ArgumentList @(...)` does not quote its
# elements, so a multi-word -ResumePrompt was re-tokenized into positional
# arguments and PowerShell rejected the bind BEFORE the script's first line ran.
# Nothing was logged (the script never started), and nothing was printed (the
# child was detached and hidden). The turn reported "upgrading now" and the loop
# sat dead for 45 minutes until the T139 watchdog re-entered it.
#
# So this wrapper does four things the open-coded incantation cannot:
#
#   1. the prompt travels as a FILE, never through argv, so no quoting, hyphen,
#      %VAR%, quote or newline in it can reach the parameter binder;
#   2. it gates success on the child's OUTPUT - a NEW `=== upgrade start` line
#      in the upgrade log - not on Start-Process returning a process object.
#      Failing here is the whole point: the launching turn is the last moment
#      anyone is still watching.
#   3. it BUILDS the staging release first (T208). The upgrade script never
#      builds - it copies whatever sits in the staging prefix - and that
#      precondition was documented nowhere the caller reads, so a delivery
#      shipped the previous delivery's binary with every signal reporting OK.
#   4. it refuses to launch unless the staged exe's baked commit IS this tree's
#      HEAD, and hands that commit to the child so the pre-swap abort and the
#      post-swap check measure the same number.
#
# Usage - call it IN-PROCESS so -Prompt binds as one string:
#
#   & D:\git\ghoztty\scripts\launch-upgrade.ps1 `
#       -Prompt '/reset-context <verify this delivery...> Then read go.md and go'
#
# Across a command line (`powershell -File ...`) the very shredding described
# above applies to THIS script's own -Prompt too, so use -PromptFile there.
# Either way a mis-bind is loud: PositionalBinding=$false means a stray word is
# rejected by name instead of landing in -LoopClaudePid.
#
# Exits 0 once the upgrade is confirmed RUNNING (not finished - it deliberately
# outlives this process), non-zero with the child's stderr if it never started.
[CmdletBinding(PositionalBinding = $false)]
param(
    # Typed into the surviving Claude pane after the swap. Free text; anything
    # goes, including quotes, hyphens and newlines. Safe ONLY when this script
    # is invoked in-process; from a command line use -PromptFile.
    [string]$Prompt = '',
    # The same value, already on disk. Wins over -Prompt when both are given.
    [string]$PromptFile = '',
    [string]$Staging = 'D:\git\ghoztty\zig-out-release',
    [string]$UpgradeScript = (Join-Path $PSScriptRoot 'upgrade-ghoztty-windows.ps1'),
    # The tree the delivery is meant to ship. Its HEAD is what the staged exe
    # must carry (T208).
    [string]$Repo = 'D:\git\ghoztty',
    # Skip the staging build. The freshness check below still runs, so this is
    # "I already built it", never "ship whatever is there".
    [switch]$SkipBuild,
    # Ship a staged exe that is NOT this tree's HEAD (a deliberate rollback, or
    # a delivery from a detached build). Loud in the log; never the default.
    [switch]$AllowStaleStaging,
    # The commit this delivery is FOR. Empty (the normal case) means "$Repo's
    # HEAD". Naming it explicitly is what lets the acceptance test drive both
    # sides of the gate without a build.
    [string]$ExpectedCommit = '',
    # A cold ReleaseFast build of this tree runs several minutes; the cache makes
    # a no-op rebuild seconds. The bound only has to catch a wedged build.
    [int]$BuildTimeoutSeconds = 1800,
    # 0 => let the upgrade script resolve it from $env:CLAUDE_PID / ancestry.
    [int]$LoopClaudePid = 0,
    [int]$DelaySeconds = 8,
    # The child logs its start line as its first statement, well before the
    # -DelaySeconds sleep, so this only has to cover process startup.
    [int]$StartTimeoutSeconds = 30,
    # Anything else to forward verbatim (e.g. -ForceRelaunch, -NoResume).
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

# Write-Error under EAP=Stop THROWS, so the `exit 2` after it would never run
# and the caller would read exit 1 - "the launch failed" rather than "you called
# it wrong". Two different problems deserve two different codes.
function Fail-Launch([string]$msg, [int]$code) {
    [Console]::Error.WriteLine($msg)
    Write-Host $msg
    exit $code
}

. (Join-Path $PSScriptRoot 'delivery-version.ps1')

if (-not (Test-Path -LiteralPath $UpgradeScript -PathType Leaf)) {
    Fail-Launch "upgrade script not found: $UpgradeScript" 2
}

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
        Fail-Launch "prompt file not found: $PromptFile" 2
    }
    $Prompt = [IO.File]::ReadAllText($PromptFile) -replace '\r?\n\z', ''
}
if (-not $Prompt) {
    Fail-Launch 'nothing to resume with: pass -Prompt (in-process) or -PromptFile' 2
}

# The argv guard below runs over the fully assembled command line, but two of
# its elements are known already - and a caller-supplied path with a space in it
# must not cost a multi-minute build before anyone says so. Same message and
# same exit code as the full guard; this is only the earlier half of it.
foreach ($a in (@($UpgradeScript, $Staging) + $ExtraArgs)) {
    if ($a -match '\s') {
        Fail-Launch "refusing to launch: argument [$a] contains whitespace and would be re-tokenized by the child (T200)" 2
    }
}

# ---- T208: BUILD the staging release, then prove it is this tree ------------
#
# The upgrade script deliberately has no build step - it copies whatever sits in
# $Staging. That precondition lived only in the upgrade script's own header, so
# a turn that followed go.md exactly shipped the PREVIOUS delivery's binary and
# every signal it got back said success. Building here makes the build part of
# the delivery instead of a remembered precondition, and it is idempotent: an
# unchanged tree rebuilds in seconds.
$buildStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $SkipBuild) {
    if (-not (Test-Path -LiteralPath $Repo -PathType Container)) {
        Fail-Launch "repo not found (needed to build the staging release): $Repo" 2
    }
    $buildLog = Join-Path $env:TEMP "ghoztty-staging-build-$buildStamp.log"
    Write-Host "building the staging release into $Staging (log: $buildLog)"
    $buildArgs = @(
        'build', '-Dapp-runtime=win32', '-Doptimize=ReleaseFast',
        '-Dtarget=x86_64-windows-gnu', '-Dstrip=false', '--prefix', $Staging
    )
    # cmd.exe redirection, not PowerShell's: zig writes a lot and this keeps the
    # transcript out of the caller's stdout while still capturing everything.
    $bp = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -WorkingDirectory $Repo `
        -ArgumentList "/c `"zig $($buildArgs -join ' ') > `"$buildLog`" 2>&1`""
    $null = $bp.Handle
    if (-not $bp.WaitForExit($BuildTimeoutSeconds * 1000)) {
        try { $bp.Kill() } catch {}
        Fail-Launch "staging build did not finish within ${BuildTimeoutSeconds}s; see $buildLog. The installed release was NOT upgraded." 3
    }
    if ($bp.ExitCode -ne 0) {
        Write-Host "staging build FAILED (exit $($bp.ExitCode)); see $buildLog"
        Select-String -LiteralPath $buildLog -Pattern 'error:' -SimpleMatch -ErrorAction SilentlyContinue |
            Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.Line)" }
        Fail-Launch 'The installed release was NOT upgraded. Do not report the delivery as done.' 3
    }
    Write-Host "staging build OK"
}

if (-not (Test-Path -LiteralPath $Staging -PathType Container)) {
    Fail-Launch "staging directory not found: $Staging" 2
}
$stagedExe = Join-Path $Staging 'bin\ghoztty.exe'
if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) {
    Fail-Launch "staged exe not found: $stagedExe. The installed release was NOT upgraded." 3
}

# The gate itself. A mismatch is a hard error, not a log line - the entire
# failure mode this exists for is that every status signal said OK.
$head = if ($ExpectedCommit) { $ExpectedCommit.Trim().ToLowerInvariant() } else { Get-RepoHeadCommit -Repo $Repo }
$staged = Resolve-GhozttyExeCommit -Exe $stagedExe
Write-Host "staging freshness: staged=$($staged.Commit) want=$head"
if (-not $head) {
    Fail-Launch "cannot read HEAD in $Repo, so the staged binary cannot be verified. The installed release was NOT upgraded." 3
}
if (-not $staged.Commit) {
    Fail-Launch "cannot read the staged exe's commit ($($staged.Why)). The installed release was NOT upgraded." 3
}
if (-not (Test-CommitsMatch $staged.Commit $head)) {
    if (-not $AllowStaleStaging) {
        Fail-Launch ("STALE STAGING: $stagedExe carries +$($staged.Commit) but HEAD is $head. " +
            'Nothing was delivered. Rebuild the staging prefix, or pass -AllowStaleStaging if the mismatch is deliberate.') 3
    }
    Write-Host "WARNING: shipping +$($staged.Commit) against HEAD $head because -AllowStaleStaging was passed"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$promptFile = Join-Path $env:TEMP "ghoztty-upgrade-prompt-$stamp.txt"
$errFile = Join-Path $env:TEMP "ghoztty-upgrade-launch-$stamp.err.txt"
$outFile = Join-Path $env:TEMP "ghoztty-upgrade-launch-$stamp.out.txt"
$log = Join-Path $env:TEMP 'ghoztty-upgrade.log'

# UTF8 without BOM: the child reads it with ReadAllText, which would keep a BOM
# as a leading U+FEFF and type it into the pane.
[IO.File]::WriteAllText($promptFile, $Prompt, (New-Object Text.UTF8Encoding($false)))
Write-Host "prompt ($($Prompt.Length) chars) -> $promptFile"

# The marker we will wait for. Counting occurrences rather than comparing file
# length means a concurrent writer cannot fake success.
$marker = '=== upgrade start'
function Get-MarkerCount {
    if (-not (Test-Path -LiteralPath $log)) { return 0 }
    # -SimpleMatch takes the pattern LITERALLY, so it must be the raw marker.
    # Regex-escaping it first made this search for `===\ upgrade\ start`, which
    # is in no log ever written - the launcher then declared every healthy
    # launch a failure. Caught by L19 (the stub logged, the launcher denied it).
    try { return @(Select-String -LiteralPath $log -Pattern $marker -SimpleMatch).Count }
    catch { return 0 }
}
$before = Get-MarkerCount

$argv = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $UpgradeScript,
    '-Staging', $Staging,
    '-ResumePromptFile', $promptFile,
    '-DelaySeconds', "$DelaySeconds",
    # T208: hand the child the commit we verified, so its own pre-swap abort and
    # its post-swap check measure against the same number this gate used - and
    # keep working on a box where the detached child cannot reach git.
    '-ExpectedCommit', $head
)
if ($AllowStaleStaging) { $argv += '-AllowStaleStaging' }
if ($LoopClaudePid -gt 0) { $argv += @('-LoopClaudePid', "$LoopClaudePid") }
$argv += $ExtraArgs

# Every element here is a single token by construction - no free text, no
# spaces. That is the invariant this wrapper exists to hold.
foreach ($a in $argv) {
    if ($a -match '\s') {
        Fail-Launch "refusing to launch: argument [$a] contains whitespace and would be re-tokenized by the child (T200)" 2
    }
}

$child = Start-Process powershell -WindowStyle Hidden -PassThru `
    -RedirectStandardError $errFile -RedirectStandardOutput $outFile -ArgumentList $argv
# Cache the handle NOW: .ExitCode reads back empty if the process exits before
# anything has opened it, which is exactly when we most want to report it.
$null = $child.Handle

$deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
$started = $false
while ((Get-Date) -lt $deadline) {
    if ((Get-MarkerCount) -gt $before) { $started = $true; break }
    # A child that has already exited will never log; stop waiting on it.
    if ($child.HasExited) {
        Start-Sleep -Milliseconds 300   # let a last write land
        if ((Get-MarkerCount) -gt $before) { $started = $true }
        break
    }
    Start-Sleep -Milliseconds 250
}

if (-not $started) {
    $exited = if ($child.HasExited) { "exited with $($child.ExitCode)" } else { "still running (pid $($child.Id))" }
    Write-Host "LAUNCH FAILED: no new '$marker' in $log after ${StartTimeoutSeconds}s; child $exited"
    foreach ($f in @($errFile, $outFile)) {
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0) {
            Write-Host "--- $f"
            Get-Content -LiteralPath $f | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        }
    }
    Write-Host 'The installed release was NOT upgraded. Do not report the delivery as done.'
    exit 1
}

Write-Host "LAUNCH OK: upgrade running (pid $($child.Id)); prompt file $promptFile"
Get-Content -LiteralPath $log -Tail 4 | ForEach-Object { Write-Host "    $_" }
exit 0
