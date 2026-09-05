# T151 acceptance: an agent-backed pane gets shell integration injected.
#
#   powershell -NoProfile -File test\win32\agent-shell-integration.ps1
#
# The defect: with session persistence on (the default), every normal pane runs
# its shell under ghoztty-agent — and the Windows agent DROPPED the `OPEN.argv`
# shell-integration rewrite the app forwards (pty_child.zig gated it to POSIX,
# on a comment claiming the client never sends it on Windows; the client is
# platform-independent and always sends it). So a `--shell=powershell` pane
# started bare: no ghostty.ps1, no OSC 133 prompt marks, no OSC 7 cwd
# reporting. A second half of the defect sat client-side: with no explicit
# shell, detection fell back to `/bin/zsh` and fake-detected zsh for a pane the
# agent actually spawns as cmd.exe.
#
# Sections:
#   A  `+new-window --shell=powershell` (agent-backed): the pane's child
#      process command line carries the integration rewrite
#      (`-NoExit -Command . '…ghostty.ps1'`), the pane's env carries
#      GHOSTTY_POWERSHELL, and — the user-visible payoff — a `cd` inside the
#      pane updates the cwd `+list` reports, which only OSC 7 can do for
#      PowerShell (Set-Location never moves the process cwd, so the T185 PEB
#      fallback cannot explain it).
#   B  (T512) default pane (no --shell): spawns plain cmd.exe. Its argv stays
#      bare — cmd has no profile to dot-source, so a rewrite would be the old
#      defect — and its integration arrives instead as an injected PROMPT
#      whose `$E` renders ESC at every prompt (OSC 7 + OSC 133;A/133;B). The
#      user-visible payoff is a tab title that follows `cd` rather than saying
#      "cmd" forever — carried by OSC 7, deliberately not by an OSC 2, so
#      cmd's own `title` command still works.
#   C  (T513) `--shell=<full path to git-bash's bash.exe>`: detection must
#      survive the Windows spelling (full path + .exe), proven by the child
#      command line carrying bash's `--posix` integration rewrite. Uses the
#      8.3 short path so the space in "Program Files" needs no quoting.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: per-run
# LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN + private IPC suffix (Isolation.ps1),
# and it only ever kills ghoztty/ghoztty-agent processes launched from zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skips = 0
$root = Join-Path $env:TEMP "ghoztty-t151-shellint-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
}

# `ghoztty +verb > file` from PowerShell writes zero bytes (T245): route
# through cmd.exe's redirection.
function Run-Cli($argsLine, $out, $timeoutSec = 30) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Get-Tree($tag) {
    $code = Run-Cli '+list --json' "$root\list-$tag.json" 20
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$root\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function Pane-In($tree, $target) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
# Poll +list until the target pane reports a live pid (the agent's OPENED reply
# and the attach land moments after the window appears).
function Wait-Pane($tag, $target, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $pane = $null
    $n = 0
    while ((Get-Date) -lt $deadline) {
        $pane = Pane-In (Get-Tree "$tag$n") $target
        if ($null -ne $pane -and [int]$pane.pid -gt 0) { return $pane }
        $n++
        Start-Sleep -Milliseconds 800
    }
    return $pane
}
function Norm($p) {
    if ($null -eq $p) { return '' }
    return ($p.Trim().TrimEnd('\').ToLowerInvariant())
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$markerDir = Join-Path $root 'cwd-marker'
New-Item -ItemType Directory -Force $markerDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

"== 0: preconditions"
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent exe exists in zig-out" (Test-Path $AgentExe)
Assert "ghostty.ps1 is in the build's resources" `
    (Test-Path 'D:\git\ghoztty\zig-out\share\ghostty\shell-integration\powershell\ghostty.ps1')
if ($script:failures -gt 0) { "$($script:failures) FAILURE(S)"; exit 1 }

$state = Join-Path $root 'state'
New-Item -ItemType Directory -Force (Join-Path $state 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $state
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't151')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: agent-backed --shell=powershell pane gets the integration rewrite"
# ============================================================================
$codeA = Run-Cli '+new-window --target=t151ps --shell=powershell' "$root\new-a.txt" 60
Assert "A1 +new-window --shell=powershell succeeded (exit 0)" ($codeA -eq 0)

$paneA = Wait-Pane 'a' 't151ps' 40
Assert "A2 the pane is up with a live pid" ($null -ne $paneA -and [int]$paneA.pid -gt 0)
Assert-GhozttyIsolated -Exe $Exe

# THE argv-verbatim oracle: the agent spawned the child FROM OPEN.argv, so the
# child process's own command line carries the dot-source rewrite. Before the
# fix this was a bare `powershell`.
$procA = $null
if ($null -ne $paneA -and [int]$paneA.pid -gt 0) {
    $procA = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$paneA.pid)"
}
Assert "A3 the pane's child is powershell" `
    ($null -ne $procA -and $procA.Name -match '^(powershell|pwsh)')
Assert "A4 its command line carries the integration rewrite (-NoExit -Command)" `
    ($null -ne $procA -and $procA.CommandLine -match '-NoExit' -and $procA.CommandLine -match '-Command')
Assert "A5 its command line dot-sources ghostty.ps1" `
    ($null -ne $procA -and $procA.CommandLine -match 'ghostty\.ps1')

# The env half (OPEN.env, T04b): setupPowershell exports GHOSTTY_POWERSHELL.
Run-Cli '+send-keys --target=t151ps --when-idle --idle-timeout=20 "echo GHPS=$env:GHOSTTY_POWERSHELL" Enter' "$root\sk-a.txt" 45 | Out-Null
$envSeen = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not $envSeen) {
    Start-Sleep -Milliseconds 900
    Run-Cli '+read --name=t151ps --lines=40' "$root\read-a.txt" 20 | Out-Null
    if ((Out-Text "$root\read-a.txt") -match 'GHPS=.*ghostty\.ps1') { $envSeen = $true }
}
Assert "A6 GHOSTTY_POWERSHELL reached the pane's environment" $envSeen

# The user-visible payoff: OSC 7 cwd reporting. Set-Location never moves the
# PowerShell PROCESS cwd, so +list can only learn this directory from the
# shell integration's OSC 7 — the T185 PEB fallback cannot explain a pass.
Run-Cli "+send-keys --target=t151ps `"cd '$markerDir'`" Enter" "$root\sk-cd.txt" 30 | Out-Null
$cwdSeen = $false
$deadline = (Get-Date).AddSeconds(30)
$n = 0
while ((Get-Date) -lt $deadline -and -not $cwdSeen) {
    Start-Sleep -Milliseconds 900
    $p = Pane-In (Get-Tree "cwd$n") 't151ps'
    $n++
    if ($null -ne $p -and (Norm $p.working_directory) -eq (Norm $markerDir)) { $cwdSeen = $true }
}
Assert "A7 +list reports the cd'd directory (OSC 7 flowed from the integration)" $cwdSeen

# ============================================================================
"== B: a default cmd.exe pane is integrated through PROMPT, not through argv (T512)"
# ============================================================================
# cmd has no profile to dot-source, so its integration is carried entirely by
# an injected PROMPT whose `$E` renders ESC at every prompt. The argv must stay
# bare — a rewrite here would be the old defect, not the fix.
$codeB = Run-Cli '+new-window --target=t151def' "$root\new-b.txt" 60
Assert "B1 +new-window (no shell) succeeded (exit 0)" ($codeB -eq 0)

$paneB = Wait-Pane 'b' 't151def' 40
Assert "B2 the default pane is up with a live pid" ($null -ne $paneB -and [int]$paneB.pid -gt 0)

$procB = $null
if ($null -ne $paneB -and [int]$paneB.pid -gt 0) {
    $procB = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$paneB.pid)"
}
Assert "B3 the default pane's child is cmd.exe (COMSPEC default)" `
    ($null -ne $procB -and $procB.Name -ieq 'cmd.exe')
Assert "B4 no integration argv leaked into the default pane" `
    ($null -ne $procB -and $procB.CommandLine -notmatch 'ghostty\.ps1' -and $procB.CommandLine -notmatch '-NoExit')

# The env half. `set PROMPT` prints `PROMPT=<template>` out of cmd's own
# environment — deliberately NOT `echo %PROMPT%`, which Run-Cli's own outer
# cmd.exe would expand against the HARNESS's prompt and pass through as a
# literal `$P$G` that passes every assertion below for the wrong reason.
# The template reads back verbatim because `$E` is only interpreted by the
# prompt renderer, never by `set`.
$promptSeen = $false
$promptText = ''
Run-Cli '+send-keys --target=t151def --when-idle --idle-timeout=20 "set PROMPT" Enter' "$root\sk-b.txt" 45 | Out-Null
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not $promptSeen) {
    Start-Sleep -Milliseconds 900
    Run-Cli '+read --name=t151def --lines=40' "$root\read-b.txt" 20 | Out-Null
    # The template is longer than the pane is wide, so it comes back wrapped;
    # flatten before matching or every token straddles a line break.
    $promptText = (Out-Text "$root\read-b.txt") -replace '\r?\n', ''
    if ($promptText -match 'PROMPT=.*133;A') { $promptSeen = $true }
}
Assert "B5 the injected PROMPT reached the cmd pane" $promptSeen
Assert "B6 it emits OSC 133;A / 133;B prompt marks" `
    ($promptText -match '133;A' -and $promptText -match '133;B')
Assert "B7 it emits OSC 7 cwd reporting" ($promptText -match 'kitty-shell-cwd://localhost/')
Assert "B8 the user's own prompt survives inside it (append, not replace)" `
    ($promptText -match 'PROMPT=\$E\]133;A.*\$P\$G')

# The user-visible payoff, and the proof the OSCs are not merely EMITTED but
# arrive and parse: a cmd pane's title used to say "cmd" forever. The title
# moves here because OSC 7 reached the terminal and it titles an untitled
# window from the reported pwd — deliberately NOT because we sent an OSC 2,
# which would overwrite cmd's own `title` command a prompt later (B11).
$titleDir = 'C:\Windows'
Run-Cli "+send-keys --target=t151def `"cd /d $titleDir`" Enter" "$root\sk-bcd.txt" 30 | Out-Null
$titleSeen = $false
$deadline = (Get-Date).AddSeconds(30)
$n = 0
while ((Get-Date) -lt $deadline -and -not $titleSeen) {
    Start-Sleep -Milliseconds 900
    foreach ($w in (Windows-Of (Get-Tree "btitle$n"))) {
        if ($w.target -ne 't151def') { continue }
        foreach ($t in @($w.tabs)) {
            if ((Norm $t.title) -eq (Norm $titleDir)) { $titleSeen = $true }
        }
    }
    $n++
}
Assert "B9 the cmd pane's tab title followed the cd (OSC 7 arrived and parsed)" $titleSeen

# And the thing that must NOT have broken: cmd's `title` is how a user names a
# window, and it has to outlive the next prompt. An OSC 2 in the injected
# PROMPT (which is what the first cut of this shipped) clobbers it instantly.
Run-Cli '+send-keys --target=t151def "title T512-STICKS" Enter' "$root\sk-btitle.txt" 30 | Out-Null
$stuck = $false
$deadline = (Get-Date).AddSeconds(30)
$n = 0
while ((Get-Date) -lt $deadline -and -not $stuck) {
    Start-Sleep -Milliseconds 900
    foreach ($w in (Windows-Of (Get-Tree "bstick$n"))) {
        if ($w.target -ne 't151def') { continue }
        foreach ($t in @($w.tabs)) { if ($t.title -match 'T512-STICKS') { $stuck = $true } }
    }
    $n++
}
# Give the prompt several more renders to overwrite it, then look again.
Run-Cli '+send-keys --target=t151def "cd /d C:\Windows" Enter' "$root\sk-bre.txt" 30 | Out-Null
Start-Sleep -Seconds 3
$stillStuck = $false
foreach ($w in (Windows-Of (Get-Tree 'bstick-after'))) {
    if ($w.target -ne 't151def') { continue }
    foreach ($t in @($w.tabs)) { if ($t.title -match 'T512-STICKS') { $stillStuck = $true } }
}
Assert 'B11 cmd''s own `title` command still sets the tab title' $stuck
Assert "B12 and the prompt does not overwrite it on the next render" $stillStuck

# The cwd the pane reports. `cd` moves cmd's PROCESS cwd too, so the T185 PEB
# fallback could produce this string on its own — what neither mechanism could
# survive is the OSC 7 path being MANGLED: `$P` spells the directory natively
# ("C:\Windows"), so the URL carries backslashes and an unencoded drive colon,
# and a wrong normalization would report something other than the directory.
$paneB2 = Pane-In (Get-Tree 'bpwd') 't151def'
Assert "B13 +list reports the cd'd directory for the cmd pane" `
    ($null -ne $paneB2 -and (Norm $paneB2.working_directory) -eq (Norm $titleDir))

# ============================================================================
"== C: --shell=<full git-bash path> gets the --posix rewrite (T513)"
# ============================================================================
$bashPath = 'C:\Program Files\Git\bin\bash.exe'
$bashRes = 'D:\git\ghoztty\zig-out\share\ghostty\shell-integration\bash\ghostty.bash'
if (-not (Test-Path $bashPath)) {
    "  SKIP C: git-bash not found at $bashPath"
    $script:skips++
} else {
    Assert "C0 ghostty.bash is in the build's resources" (Test-Path $bashRes)
    # 8.3 short path: same file, no space, so no quoting layer can mangle it.
    $shortBash = (New-Object -ComObject Scripting.FileSystemObject).GetFile($bashPath).ShortPath
    if ($shortBash -match ' ') {
        "  SKIP C: volume has no space-free short path for $bashPath"
        $script:skips++
    } else {
        $codeC = Run-Cli "+new-window --target=t513bash --shell=$shortBash" "$root\new-c.txt" 60
        Assert "C1 +new-window --shell=<full bash.exe path> succeeded (exit 0)" ($codeC -eq 0)

        $paneC = Wait-Pane 'c' 't513bash' 40
        Assert "C2 the bash pane is up with a live pid" ($null -ne $paneC -and [int]$paneC.pid -gt 0)

        $procC = $null
        if ($null -ne $paneC -and [int]$paneC.pid -gt 0) {
            $procC = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$paneC.pid)"
        }
        Assert "C3 the pane's child is bash.exe" ($null -ne $procC -and $procC.Name -ieq 'bash.exe')
        Assert "C4 its command line carries the --posix integration rewrite" `
            ($null -ne $procC -and $procC.CommandLine -match '--posix')

        Run-Cli '+close --target=t513bash' "$root\close-c.txt" 15 | Out-Null
    }
}

# ---- teardown --------------------------------------------------------------
Run-Cli '+close --target=t151ps' "$root\close-a.txt" 15 | Out-Null
Run-Cli '+close --target=t151def' "$root\close-b.txt" 15 | Out-Null
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# A green run with no skipped sections stamps the covered files (T783) so
# guard-due can answer "has this harness been run against shell_integration.zig
# as it now stands?". Red or skipped leaves the stamp alone: both stay due.
if ($script:failures -eq 0 -and $script:skips -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-shell-integration -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) {
    "ALL PASS$(if ($script:skips) { " ($($script:skips) SKIPPED)" })"; exit 0
} else { "$($script:failures) FAILURE(S)"; exit 1 }
