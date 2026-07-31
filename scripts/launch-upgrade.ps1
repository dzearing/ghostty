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
# So this wrapper does two things the open-coded incantation cannot:
#
#   1. the prompt travels as a FILE, never through argv, so no quoting, hyphen,
#      %VAR%, quote or newline in it can reach the parameter binder;
#   2. it gates success on the child's OUTPUT - a NEW `=== upgrade start` line
#      in the upgrade log - not on Start-Process returning a process object.
#      Failing here is the whole point: the launching turn is the last moment
#      anyone is still watching.
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

if (-not (Test-Path -LiteralPath $UpgradeScript -PathType Leaf)) {
    Fail-Launch "upgrade script not found: $UpgradeScript" 2
}
if (-not (Test-Path -LiteralPath $Staging -PathType Container)) {
    Fail-Launch "staging directory not found: $Staging" 2
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
    '-DelaySeconds', "$DelaySeconds"
)
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
