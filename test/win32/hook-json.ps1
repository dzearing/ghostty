# T866 acceptance: vendored agent-integration assets + the `+json` CLI verbs
# + the jq-free banner hook script, end to end with jq shadowed off PATH.
#
# Three sections:
#
#   A. VENDOR DRIFT - the pristine mirror under
#      src\apprt\win32\assets\ghoztty\upstream\ must be byte-identical to
#      tip-of-main's macos/Resources/Ghoztty/ (git blob compare), the two
#      unforked live copies (the SKILL.md files) byte-identical to the
#      mirror, and the two deliberate forks each carrying their divergence:
#      hooks\ghoztty-banner.sh jq-free and +json-native (T866), and
#      hooks\ghoztty-activity-state.sh carrying the OSTYPE-guarded Windows
#      owner/liveness probes (T605).
#      This is the loud-drift check T866's validation criteria demand: when
#      main moves an asset, this section goes red until someone re-vendors.
#
#   B. +JSON CLI - get (first-non-empty, escape decoding, --each line
#      alignment, missing/garbage input never fails), merge (create, preserve
#      non-string keys, self-heal corrupt state, no temp/lock litter, stale
#      lock reclaimed), encode (JSON string literal round-trip). All against
#      the repo debug exe, no app instance needed.
#
#   C. HOOK SCRIPT E2E - the vendored ghoztty-banner.sh runs a SessionStart
#      and a UserPromptSubmit payload end to end against a live debug app
#      pane, with `jq` SHADOWED by a sentinel stub that fails loudly if
#      anything calls it: session wipe recorded, banner delivered (read back
#      from `+list --json`'s additive banner field, never from pixels), the
#      additionalContext envelope emitted in both the Claude (nested) and
#      Copilot (flat) shapes, prompt paraphrase seeded with escapes decoded.
#
# Runs on the background test desktop; touches only ghoztty processes running
# from this repo's zig-out.
param(
    [string]$ExePath
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint: an instance answering the shared pipe would let
# another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-hjtest'

# PS 5.1 pipes strings to a native exe in $OutputEncoding, whose default here
# prepends a UTF-8 BOM. The exe tolerates a BOM on parse input (measured, and
# unit-tested), but `encode` is byte-faithful by design, so the harness sends
# clean bytes to keep the round-trip assertions about the product.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Note-Skip([string]$label) {
    $script:skipped++
    Write-Host "SKIP  $label"
}

function Stop-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

if (-not (Test-Path $exe)) {
    Write-TestAssertedNothing -Reason "no debug build at $exe (zig build -Dapp-runtime=win32 -Doptimize=Debug first)"
}
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$assetRoot = Join-Path $repo 'src\apprt\win32\assets\ghoztty'
$assetRel = @(
    'hooks/ghoztty-banner.sh',
    'hooks/ghoztty-activity-state.sh',
    'skills/ghoztty/SKILL.md',
    'skills/process-feedback/SKILL.md'
)

Write-Host ''
Write-Host '--- A. vendor drift ---'

# The mirror must match tip-of-main blob for blob. `git hash-object` and
# `rev-parse origin/main:<path>` compare CONTENT identity, so a checkout's
# line-ending config cannot fool either direction.
$mainOk = $true
& git -C $repo rev-parse --verify origin/main 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { $mainOk = $false }
if (-not $mainOk) {
    Note-Skip 'origin/main not present in this clone; mirror-vs-main blob compare not possible'
} else {
    foreach ($rel in $assetRel) {
        $mirror = Join-Path $assetRoot ("upstream\" + ($rel -replace '/', '\'))
        $local = (& git -C $repo hash-object $mirror 2>$null | Out-String).Trim()
        $upstream = (& git -C $repo rev-parse "origin/main:macos/Resources/Ghoztty/$rel" 2>$null | Out-String).Trim()
        Assert ($local -and $upstream -and ($local -eq $upstream)) "upstream mirror of $rel is byte-identical to origin/main ($local)"
    }
}

# The live copies: two unforked (byte-identical to the mirror), two forks.
foreach ($rel in @('skills/ghoztty/SKILL.md', 'skills/process-feedback/SKILL.md')) {
    $live = Join-Path $assetRoot ($rel -replace '/', '\')
    $mirror = Join-Path $assetRoot ("upstream\" + ($rel -replace '/', '\'))
    $a = (& git -C $repo hash-object $live 2>$null | Out-String).Trim()
    $b = (& git -C $repo hash-object $mirror 2>$null | Out-String).Trim()
    Assert ($a -and ($a -eq $b)) "live copy of $rel is byte-identical to the mirror"
}

$fork = Join-Path $assetRoot 'hooks\ghoztty-banner.sh'
$forkText = [System.IO.File]::ReadAllText($fork)
Assert ($forkText -notmatch 'jq') 'banner fork carries no jq reference at all'
Assert ($forkText -match [regex]::Escape('ghoztty +json')) 'banner fork parses through ghoztty +json'
Assert ($forkText.Contains("`n") -and -not $forkText.Contains("`r`n")) 'banner fork is LF-only (a CRLF script dies in bash)'
$forkBytes = [System.IO.File]::ReadAllBytes($fork)
Assert (-not ($forkBytes.Length -ge 3 -and $forkBytes[0] -eq 0xEF)) 'banner fork has no UTF-8 BOM (a BOM breaks the shebang)'

# The activity-state fork (T605): OSTYPE-guarded Windows owner/liveness
# probes. Without them MSYS kill -0 reads every native agent pid as dead and
# the reap deletes each subagent marker the moment it is written. The state
# machine's transitions themselves are the subject of
# test\win32\activity-state.ps1 (the vendored upstream oracle).
$fork2 = Join-Path $assetRoot 'hooks\ghoztty-activity-state.sh'
$fork2Text = [System.IO.File]::ReadAllText($fork2)
Assert ($fork2Text -match 'owner_winpid') 'activity-state fork resolves the owner over the native process tree'
Assert ($fork2Text -match [regex]::Escape('ps -W')) 'activity-state fork probes liveness through a ps -W snapshot'
Assert ($fork2Text.Contains("`n") -and -not $fork2Text.Contains("`r`n")) 'activity-state fork is LF-only (a CRLF script dies in bash)'
$fork2Bytes = [System.IO.File]::ReadAllBytes($fork2)
Assert (-not ($fork2Bytes.Length -ge 3 -and $fork2Bytes[0] -eq 0xEF)) 'activity-state fork has no UTF-8 BOM (a BOM breaks the shebang)'

Write-Host ''
Write-Host '--- B. +json CLI ---'

$sandbox = Join-Path $env:TEMP "ghoztty-hookjson-$PID"
if (Test-Path $sandbox) { Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $sandbox | Out-Null

# get: first non-empty key wins, escapes decoded. (Command substitution and
# PS variable capture both read the exe through a pipe, which is the shape
# that works for the GUI-subsystem exe.)
$payload = '{"session_id":"","sessionId":"abc-123","prompt":"line1\nline2 \"quoted\""}'
$got = ($payload | & $exe +json get session_id sessionId 2>$null | Out-String).Trim()
Assert ($got -eq 'abc-123') "+json get returns the first NON-EMPTY key (got '$got')"
$got = ($payload | & $exe +json get prompt 2>$null | Out-String)
Assert ($got.Contains('line1') -and $got.Contains('line2 "quoted"') -and -not $got.Contains('\n')) '+json get decodes JSON escapes to real text'
$got = ($payload | & $exe +json get missing 2>$null | Out-String).Trim()
Assert ($got -eq '') '+json get prints nothing for an absent key'
$got = ('garbage' | & $exe +json get a 2>$null | Out-String).Trim()
Assert ($got -eq '' -and $LASTEXITCODE -eq 0) '+json get on unparseable input prints nothing and exits 0'

# get --file / --each against a state file.
$state = Join-Path $sandbox 'state.json'
[System.IO.File]::WriteAllText($state, '{"title":"T866","goal":"","did":"a\nb","n":7}')
$got = (& $exe +json get title --file=$state 2>$null | Out-String).Trim()
Assert ($got -eq 'T866') '+json get --file reads a state file'
$got = (& $exe +json get nope --file=(Join-Path $sandbox 'absent.json') 2>$null | Out-String).Trim()
Assert ($got -eq '' -and $LASTEXITCODE -eq 0) '+json get on a missing file prints nothing and exits 0'
$lines = @(& $exe +json get --each title goal missing did n --file=$state 2>$null)
Assert ($lines.Count -eq 5 -and $lines[0] -eq 'T866' -and $lines[1] -eq '' -and $lines[2] -eq '' -and $lines[3] -eq 'a b' -and $lines[4] -eq '') '+json get --each emits one aligned line per key (newlines flattened, non-strings empty)'

# merge: create, then merge preserving a non-string value.
$mstate = Join-Path $sandbox 'merge.json'
& $exe +json merge $mstate title T866 | Out-Null
[System.IO.File]::WriteAllText($mstate, (Get-Content $mstate -Raw).Trim().TrimEnd('}') + ',"count":3}')
& $exe +json merge $mstate goal shipped | Out-Null
$obj = Get-Content $mstate -Raw | ConvertFrom-Json
Assert ($obj.title -eq 'T866' -and $obj.goal -eq 'shipped' -and $obj.count -eq 3) '+json merge creates, merges, and preserves unrelated non-string keys'

# merge self-heal: corrupt state resets to {} + the merged pairs.
[System.IO.File]::WriteAllText($mstate, '###corrupt###')
& $exe +json merge $mstate k v | Out-Null
$obj = Get-Content $mstate -Raw | ConvertFrom-Json
Assert ($obj.k -eq 'v') '+json merge self-heals an unparseable state file'

# merge leaves no temp or lock litter behind.
$litter = @(Get-ChildItem $sandbox -Force | Where-Object { $_.Name -like '.merge.*' -or $_.Name -like '*.lock' })
Assert ($litter.Count -eq 0) 'merge leaves no temp files and no lock behind'

# A STALE foreign lock (older than 60s) is reclaimed rather than waited out:
# the merge lands promptly and the lock directory is gone afterwards.
$lockDir = "$mstate.lock"
New-Item -ItemType Directory -Force $lockDir | Out-Null
(Get-Item $lockDir).LastWriteTime = (Get-Date).AddMinutes(-5)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $exe +json merge $mstate stale reclaimed | Out-Null
$sw.Stop()
$obj = Get-Content $mstate -Raw | ConvertFrom-Json
Assert ($obj.stale -eq 'reclaimed' -and $sw.ElapsedMilliseconds -lt 2000) "stale lock reclaimed promptly (merge took $($sw.ElapsedMilliseconds)ms)"
Assert (-not (Test-Path $lockDir)) 'reclaimed lock directory is cleaned up'

# encode: JSON string literal that round-trips. The input bytes go through a
# cmd file redirect, never a PS pipe: PS 5.1 prepends a UTF-8 BOM to native
# stdin whenever the console codepage is 65001 — measured, and neither
# $OutputEncoding nor [Console]::OutputEncoding stops it — so a piped
# assertion is about the invoking session's codepage, not about encode.
$encIn = Join-Path $sandbox 'encode-in.txt'
[System.IO.File]::WriteAllBytes($encIn, [System.Text.Encoding]::UTF8.GetBytes('a "b" c'))
$enc = (& cmd /c "`"$exe`" +json encode < `"$encIn`"" | Out-String).Trim()
$dec = $enc | ConvertFrom-Json
Assert ($dec -eq 'a "b" c') "+json encode emits a decodable JSON string literal (got $enc)"

# usage errors are loud: unknown subcommand and odd merge pairs exit 2.
& $exe +json frobnicate 2>$null | Out-Null
$rcA = $LASTEXITCODE
& $exe +json merge $mstate onlykey 2>$null | Out-Null
$rcB = $LASTEXITCODE
Assert ($rcA -eq 2 -and $rcB -eq 2) "usage errors exit 2 (unknown sub=$rcA, odd pairs=$rcB)"

Write-Host ''
Write-Host '--- C. hook script end-to-end, jq shadowed ---'

# Git for Windows bash, NEVER a bare `bash` lookup: from PowerShell that
# resolves to WSL's System32\bash.exe (measured on this box), which has no
# /d/ paths and no cygpath. Claude Code's own hooks run under Git Bash, so
# that is the environment this e2e must reproduce.
$gitBash = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe',
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $gitBash) {
    Note-Skip 'Git for Windows bash not found; the hook-script e2e cannot run on this box'
} else {
    Stop-RepoInstances

    # Sandbox layout: bin\ holds the PATH shadow (a jq stub that fails loudly
    # through a sentinel file, and a ghoztty shim resolving to the debug exe),
    # home\ isolates $HOME so the script's state dir never touches the user's.
    $bin = Join-Path $sandbox 'bin'
    $home2 = Join-Path $sandbox 'home'
    $payloads = Join-Path $sandbox 'payloads'
    $out = Join-Path $sandbox 'out'
    foreach ($d in @($bin, $home2, $payloads, $out)) { New-Item -ItemType Directory -Force $d | Out-Null }

    # POSIX spelling of the exe path for the bash shim (D:\x\y -> /d/x/y).
    $exePosix = '/' + $exe.Substring(0, 1).ToLower() + ($exe.Substring(2) -replace '\\', '/')

    [System.IO.File]::WriteAllText((Join-Path $bin 'jq'), "#!/bin/bash`ntouch `"`$JQ_SENTINEL`"`nexit 1`n")
    [System.IO.File]::WriteAllText((Join-Path $bin 'ghoztty'), "#!/bin/bash`nexec `"$exePosix`" `"`$@`"`n")
    Copy-Item (Join-Path $assetRoot 'hooks\ghoztty-banner.sh') (Join-Path $sandbox 'ghoztty-banner.sh')

    # SessionStart(startup) then UserPromptSubmit, per T866's validation
    # criterion. The prompt carries JSON escapes so the seeded paraphrase
    # proves decoding; session ids match so the prompt does not re-wipe.
    [System.IO.File]::WriteAllText((Join-Path $payloads 'session-start.json'), '{"session_id":"e2e-s1","source":"startup"}')
    [System.IO.File]::WriteAllText((Join-Path $payloads 'prompt.json'), '{"session_id":"e2e-s1","prompt":"prove the banner survives without any JSON tool\nsecond line never shows"}')
    [System.IO.File]::WriteAllText((Join-Path $payloads 'prompt-copilot.json'), '{"sessionId":"e2e-s1","prompt":"copilot flavored prompt"}')

    $driver = @(
        '#!/bin/bash',
        'set -u',
        'sd=$(cygpath -u "$1"); pane="$2"',
        'chmod +x "$sd/bin/"* 2>/dev/null',
        'export PATH="$sd/bin:$PATH" HOME="$sd/home" TERM_PROGRAM=ghostty',
        'export GHOZTTY_PANE_ID="$pane" GHOZTTY_PIPE_SUFFIX="-hjtest"',
        'export JQ_SENTINEL="$sd/out/jq-called"',
        'command -v jq >/dev/null && echo "shadow-jq-on-path" > "$sd/out/shadow.txt"',
        's="$sd/ghoztty-banner.sh"',
        'run() { n="$1"; shift',
        '  if [ -f "$sd/payloads/$n.json" ]; then',
        '    bash "$s" "$@" < "$sd/payloads/$n.json" > "$sd/out/$n.out" 2> "$sd/out/$n.err"',
        '  else',
        '    bash "$s" "$@" > "$sd/out/$n.out" 2> "$sd/out/$n.err"',
        '  fi',
        '  echo "$n:$?" >> "$sd/out/rc.txt"',
        '}',
        'run session-start session-start-hook',
        'run set set --title "E2E T866 banner" --goal "prove jq-free hooks" --status "measuring"',
        'run prompt-copilot prompt-hook --runtime=copilot',
        'run prompt prompt-hook',
        'run stop stop-hook',
        'ls "$sd/home/.config/ghoztty/banner-state" > "$sd/out/statedir.txt" 2>&1'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'driver.sh'), $driver + "`n")

    # Launch the app on the background desktop and make one named window.
    $td = New-TestDesktop
    $errlog = Join-Path $sandbox 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    $paneId = $null
    for ($t = 0; $t -lt 30 -and -not $paneId; $t++) {
        Start-Sleep -Milliseconds 500
        & $exe +new-window --target=hjw 2>$null | Out-Null
        $json = (& $exe +list --json 2>$null | Out-String).Trim()
        if ($json) {
            $data = ($json | ConvertFrom-Json).data
            foreach ($w in $data.windows) {
                if ($w.target -eq 'hjw') {
                    $node = $w.tabs[0].splits
                    while ($node.type -ne 'leaf') { $node = $node.left }
                    $paneId = $node.terminal.id
                }
            }
        }
    }
    if (-not $paneId) {
        Note-Skip 'no live pane came up; hook-script e2e could not run'
    } else {
        & $gitBash (Join-Path $sandbox 'driver.sh') $sandbox $paneId 2>$null | Out-Null

        $rc = @{}
        foreach ($line in (Get-Content (Join-Path $out 'rc.txt') -ErrorAction SilentlyContinue)) {
            $p = $line.Split(':'); $rc[$p[0]] = [int]$p[1]
        }
        Assert ((Get-Content (Join-Path $out 'shadow.txt') -ErrorAction SilentlyContinue) -eq 'shadow-jq-on-path') 'the jq shadow really was first on PATH (the e2e was at risk)'
        Assert (-not (Test-Path (Join-Path $out 'jq-called'))) 'nothing in the whole flow ever invoked jq'
        Assert ($rc['session-start'] -eq 0 -and $rc['set'] -eq 0 -and $rc['prompt'] -eq 0 -and $rc['stop'] -eq 0) "every hook invocation exited 0 ($(($rc.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))"

        # The state file the script kept: session recorded by the SessionStart
        # wipe, paraphrase seeded from the prompt's FIRST line with escapes
        # decoded, activity settled to idle by the stop hook.
        $stateDir = Join-Path $home2 '.config\ghoztty\banner-state'
        $stateFile = @(Get-ChildItem $stateDir -Filter 'pane-*.json' -ErrorAction SilentlyContinue) + @(Get-ChildItem $stateDir -Filter '*.json' -ErrorAction SilentlyContinue) | Select-Object -First 1
        Assert ($null -ne $stateFile) 'the script kept a per-pane state file under the sandboxed HOME'
        if ($stateFile) {
            $st = Get-Content $stateFile.FullName -Raw | ConvertFrom-Json
            Assert ($st.session -eq 'e2e-s1') 'SessionStart recorded the session id in state'
            Assert ($st.asked -eq 'prove the banner survives without any JSON tool') 'prompt paraphrase seeded from the decoded first line only'
            Assert ($st.activity -eq 'idle') 'stop-hook settled activity to idle'
        }

        # The banner really reached the pane: read back through +list.
        $bannerText = ''
        for ($t = 0; $t -lt 20 -and -not $bannerText; $t++) {
            $json = (& $exe +list --json 2>$null | Out-String).Trim()
            if ($json) {
                $data = ($json | ConvertFrom-Json).data
                foreach ($w in $data.windows) {
                    if ($w.target -eq 'hjw') {
                        $node = $w.tabs[0].splits
                        while ($node.type -ne 'leaf') { $node = $node.left }
                        if ($node.terminal.banner) { $bannerText = $node.terminal.banner }
                    }
                }
            }
            if (-not $bannerText) { Start-Sleep -Milliseconds 200 }
        }
        Assert ($bannerText.Contains('## E2E T866 banner')) 'banner delivered to the pane with the title heading (+list banner field)'
        Assert ($bannerText.Contains('prove jq-free hooks')) 'banner carries the goal row'
        Assert ($bannerText.Contains('Idle') -or $bannerText.Contains('Working')) 'banner carries the activity state'

        # The additionalContext envelopes, both runtime shapes.
        $envl = (Get-Content (Join-Path $out 'prompt.out') -Raw -ErrorAction SilentlyContinue)
        $ok = $false
        try {
            $e = $envl | ConvertFrom-Json
            $ok = ($e.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit') -and ($e.hookSpecificOutput.additionalContext.Length -gt 200)
        } catch {}
        Assert $ok 'Claude prompt-hook emits the NESTED hookSpecificOutput envelope with the banner help text'
        $envl = (Get-Content (Join-Path $out 'prompt-copilot.out') -Raw -ErrorAction SilentlyContinue)
        $ok = $false
        try {
            $e = $envl | ConvertFrom-Json
            $ok = ($e.additionalContext.Length -gt 200) -and ($null -eq $e.hookSpecificOutput)
        } catch {}
        Assert $ok 'Copilot prompt-hook emits the FLAT additionalContext envelope'
    }

    & $exe +close --target=hjw 2>$null | Out-Null
    Stop-RepoInstances
    Remove-TestDesktop
}

Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue

# --- stamp (T783) ----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard hook-json -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
} elseif ($script:fail -eq 0) {
    Write-Host "  stamp NOT updated: $script:skipped section(s) skipped, so this run did not cover the whole harness"
}

Write-Host ''
Write-TestVerdict -Label 'HOOK-JSON' -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
