# T133 acceptance: the /reset-context helper's composer wipe and its
# verify-or-shout behavior (dzearing-skills plugin, scripts/reset-context.sh).
#
# This is the loop's own continuation mechanism, and it has failed twice by
# silently no-opping (2026-07-28: a stray "nn" in the composer turned the
# submit into the ordinary message "nn/clear", so nothing was cleared and the
# loop stalled). The helper now (a) kills the input line with C-u before
# typing, and (b) reads the pane back to VERIFY both the clear and the
# continuation, shouting into its log AND onto a pane banner when either
# fails. Both are validated here against a pane that models a Claude Code
# composer closely enough to reproduce the original defect:
#
#   proxy-normal   readline input (so C-u is really unix-line-discard, as in
#                  the composer), clears screen+scrollback on the EXACT line
#                  "/clear" and echoes anything else as RC-TEXT[...] - so
#                  "nn/clear" is text and "/clear" is a command, exactly the
#                  distinction the defect fell through.
#   proxy-amnesia  same, but keeps clearing the screen after the clear, so
#                  the continuation lands and then vanishes - a session that
#                  cleared but ate the prompt (the T132-class stall).
#   proxy-working  what a session that ACCEPTS the prompt looks like: no echo
#                  at all, then a spinner repainting for 15s. The only
#                  on-screen evidence of delivery is the paint (T182/T261),
#                  and every line it receives is logged to a file OUTSIDE the
#                  pane so a success verdict can be checked against the truth.
#
# Sections:
#   A  fixed helper + a stray "nn" pre-typed -> the pane receives "/clear"
#        (not "nn/clear"), the log says it verified the clear AND the
#        continuation, and NO banner is set (no false alarm).
#   B  negative control: the same run with the C-u line deleted from the
#        helper -> the pane receives "nn/clear" verbatim (the filed symptom,
#        reproduced), the log carries the loud RESET-CONTEXT FAILED block,
#        a banner tells the user, and the continuation is STILL sent
#        (liveness beats cleanliness).
#   C  a session that clears and then swallows the prompt -> the clear
#        verifies, the CONTINUATION check fails loudly, banner set.
#   D  durability: the active plugin cache carries the wipe AND the repaint
#        acceptance, and the source repo copy is byte-identical to it with a
#        bumped plugin version (T130's lesson: a plugin release silently
#        reverted a cache-only fix).
#   E  T182: a pane that ACCEPTED the continuation and is working on it is
#        verified as a success - the repaint is the proof - with no failure
#        in the log and no banner. An out-of-band receipt file proves the
#        continuation really arrived, so the verdict is right and not lucky.
#   F  negative control for E: the same pane driven by a helper copy with the
#        repaint branch cut out shouts FAILED over that same delivery, which
#        is the bug as filed. E only means something because F still fails.
#
# Oracles are the pane's own output (+read), the helper's log
# (/tmp/reset-context-last.log), and the banner in +list --json.
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [string]$HelperPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) {
    Write-Host 'SKIP: git-bash not found - the helper is a bash script, nothing to test' -ForegroundColor Yellow
    exit 1
}

# The helper under test: the ACTIVE plugin cache copy by default (what the
# box really runs), overridable with -HelperPath.
$cacheRoot = Join-Path $env:USERPROFILE '.claude\plugins\cache\dzearing-claude-marketplace\dzearing-skills'
$cacheHelper = $null
if (Test-Path $cacheRoot) {
    $cacheHelper = Get-ChildItem $cacheRoot -Directory |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } |
        ForEach-Object { Join-Path $_.FullName 'skills\reset-context\scripts\reset-context.sh' } |
        Where-Object { Test-Path $_ } | Select-Object -Last 1
}
$helper = if ($HelperPath) { $HelperPath } else { $cacheHelper }
if (-not $helper -or -not (Test-Path $helper)) {
    Write-Host 'SKIP: reset-context.sh not found (plugin not installed?)' -ForegroundColor Yellow
    exit 1
}
Write-Host "helper: $helper"

# ---- scratch dir, proxies, and the pre-fix helper copy -------------------
$work = Join-Path $env:TEMP 'ghoztty-rc-test'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
function Write-Sh([string]$path, [string]$text) {
    # LF endings, ASCII, no BOM: a BOM would land in front of the shebang.
    [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), (New-Object System.Text.ASCIIEncoding))
}
Write-Sh (Join-Path $work 'proxy-normal.sh') @'
#!/bin/bash
# Composer model: readline editing (C-u = unix-line-discard), the EXACT line
# "/clear" is a command that clears screen and scrollback, anything else is
# ordinary text that gets echoed back.
while IFS= read -r -e -p 'rc> ' l; do
  if [ "$l" = "/clear" ]; then printf '\033[2J\033[3J\033[H'; echo "RC-CLEARED"
  else echo "RC-TEXT[$l]"; fi
done
'@
Write-Sh (Join-Path $work 'proxy-amnesia.sh') @'
#!/bin/bash
# Same, but every line AFTER the clear also wipes the screen: a session that
# accepted /clear and then ate whatever was typed into it.
S=0
while IFS= read -r -e -p 'rc> ' l; do
  if [ "$l" = "/clear" ] || [ "$S" = "1" ]; then S=1; printf '\033[2J\033[3J\033[H'
  else echo "RC-TEXT[$l]"; fi
done
'@
Write-Sh (Join-Path $work 'proxy-working.sh') @'
#!/bin/bash
# The T182 case, modelled on what the real Claude Code TUI does with a prompt
# it ACCEPTS: nothing is echoed back, and the session immediately starts
# working, repainting a spinner. The text a naive verifier searches for is
# destroyed by the very success it is trying to confirm -- so the ONLY on-screen
# evidence of delivery is that the pane is painting.
#
# Echo is off (and the read is a plain one, so no readline echo either),
# which makes that deterministic rather than a race against the repaint.
# Every submitted line is appended to $1: an oracle OUTSIDE the pane, so the
# test can tell "the verifier was right" from "the verifier got lucky".
R="${1:-$(dirname "$0")/received.txt}"
stty -echo 2>/dev/null
printf 'rc-ready\n'
while IFS= read -r l; do
  l="${l%$'\r'}"
  [ -z "$l" ] && continue
  if [ "$l" = "/clear" ]; then printf '\033[2J\033[3J\033[H'; printf 'RC-CLEARED\n'; continue; fi
  printf '%s\n' "$l" >> "$R"
  i=0
  while [ "$i" -lt 15 ]; do i=$((i + 1)); printf '\r  * Working... (%ss)  ' "$i"; sleep 1; done
  printf '\n'
done
'@

function To-Unix([string]$p) { (& $bash -lc "cygpath -u '$($p -replace "'", "''")'").Trim() }
$helperU = To-Unix $helper
$prefixU = To-Unix (Join-Path $work 'reset-context-prefix.sh')
# Negative control built with sed, not PowerShell: the helper carries UTF-8
# comments and a backslash-sensitive sed expression, and rewriting it through
# PowerShell would mangle both.
& $bash -lc "sed '/--when-idle C-u/d' '$helperU' > '$prefixU'" | Out-Null
$prefixWin = Join-Path $work 'reset-context-prefix.sh'
if ((Get-Content $prefixWin | Select-String -SimpleMatch '--when-idle C-u')) {
    Write-Host 'SETUP FAIL: pre-fix copy still has the C-u line'; exit 1
}
# Second negative control (T182): the helper with the T261 repaint branch cut
# out, i.e. the version that only ever believed an echoed prompt. Section F
# runs it against the SAME pane section E passes on, so the run proves the fix
# is load-bearing rather than merely present. The sed program goes in a file:
# it matches "$cur"/"$prev", which PowerShell would expand inside a "..." arg.
Write-Sh (Join-Path $work 'drop-repaint.sed') @'
/elif \[ "$cur" != "$prev" \]; then/,+1d
'@
$norepaintWin = Join-Path $work 'reset-context-norepaint.sh'
$sedU = To-Unix (Join-Path $work 'drop-repaint.sed')
$norepaintU = To-Unix $norepaintWin
& $bash -lc "sed -f '$sedU' '$helperU' > '$norepaintU'" | Out-Null
$nrText = Get-Content $norepaintWin -Raw
# Match the ASSIGNMENT, not the phrase: the helper's comments explain the
# repaint branch too, so a bare 'pane is repainting' is true of a copy that
# no longer has it.
if ($nrText -match 'verdict="pane is repainting') {
    Write-Host 'SETUP FAIL: pre-T261 copy still has the repaint branch'; exit 1
}
if ($nrText -notmatch 'continuation is on screen') {
    Write-Host 'SETUP FAIL: pre-T261 copy lost the echoed-prompt branch too'; exit 1
}
$logWin = Join-Path (& $bash -lc 'cygpath -w /tmp' | ForEach-Object { $_.Trim() }) 'reset-context-last.log'

# ---- instance ------------------------------------------------------------
function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}
# The helper calls bare `ghoztty`, so zig-out goes FIRST on PATH, and the
# inherited GHOZTTY_IPC_SOCKET is cleared: this session's pane bakes the
# RELEASE app's socket, and a helper that picked it up would type /clear into
# the user's own window instead of the test instance.
$env:PATH = (Join-Path $repo 'zig-out\bin') + ';' + $env:PATH
$env:GHOZTTY_IPC_SOCKET = ''

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}
function All-Leaves {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    $out = @()
    foreach ($w in ($json | ConvertFrom-Json).data.windows) {
        foreach ($t in $w.tabs) { $out += @(Get-Leaves $t.splits | ForEach-Object { $_ | Add-Member -NotePropertyName winTarget -NotePropertyValue $w.target -PassThru -Force }) }
    }
    return $out
}
function Pane-Of([string]$winTarget) {
    foreach ($l in All-Leaves) { if ($l.winTarget -eq $winTarget) { return $l.id } }
    return $null
}
function Banner-Of([string]$paneId) {
    foreach ($l in All-Leaves) { if ($l.id -eq $paneId) { return $l.banner } }
    return $null
}
function Tail([string]$paneId, [int]$lines = 40) {
    # A pane that exists in +list can still be a moment away from readable
    # (the window is up before its terminal attaches), and in PS 5.1 a native
    # command's stderr is an ErrorRecord that would terminate the run under
    # $ErrorActionPreference='Stop'. Poll, don't die.
    # An EMPTY read is always transient here (every proxy pane at least shows
    # its "rc>" prompt), and a swallowed one would read exactly like a product
    # verdict - "the text never arrived" - so retry before believing it.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = ''
    for ($t = 0; $t -lt 15 -and -not $out; $t++) {
        try { $out = (& $exe +read --name=$paneId --lines=$lines 2>$null | Out-String) } catch { $out = '' }
        if (-not $out) { Start-Sleep -Milliseconds 200 }
    }
    $ErrorActionPreference = $old
    if (-not $out) { return '' }
    return $out
}
function Wait-Tail([string]$paneId, [string]$needle, [int]$secs = 10) {
    for ($t = 0; $t -lt ($secs * 5); $t++) {
        if ((Tail $paneId).Contains($needle)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function New-ProxyWindow([string]$target, [string]$proxy, [string]$proxyArg = '', [string]$ready = 'rc>') {
    $u = To-Unix (Join-Path $work $proxy)
    $cmd = if ($proxyArg) { "bash $u '$proxyArg'" } else { "bash $u" }
    & $exe +new-window --target=$target --shell="$bash" --command=$cmd | Out-Null
    $pane = $null
    for ($t = 0; $t -lt 40 -and -not $pane; $t++) { $pane = Pane-Of $target; if (-not $pane) { Start-Sleep -Milliseconds 250 } }
    if (-not $pane) { Write-Host "SETUP FAIL: no pane for $target"; exit 1 }
    if (-not (Wait-Tail $pane $ready 15)) { Write-Host "SETUP FAIL: proxy prompt never appeared in $target"; exit 1 }
    return $pane
}
function Run-Helper([string]$script, [string]$paneId, [string]$contText) {
    $cont = Join-Path $work ("cont-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    [IO.File]::WriteAllText($cont, $contText + "`n", (New-Object System.Text.ASCIIEncoding))
    $su = To-Unix $script
    $cu = To-Unix $cont
    & $bash -lc "bash '$su' '$paneId' '$cu'" | Out-Null
    return @{ log = (Get-Content $logWin -Raw -ErrorAction SilentlyContinue); cont = $cont }
}

Kill-RepoInstances

# T441: this run's own IPC endpoint, before any `& $exe` call. This script
# drives a helper that TYPES `/clear` and a continuation into a pane — pointed
# at the user's installed release by an inherited `$GHOZTTY_IPC_SOCKET` it
# would clear a live Claude session.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'resetctx')
Assert-GhozttyPrivateEndpoint -Exe $exe

$proc = Start-Process $exe -ArgumentList '--session-persistence=false' -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
Assert-GhozttyIsolated -Exe $exe

try {
    # --- A. fixed helper wipes the composer, verifies both sends ----------
    $p1 = New-ProxyWindow 'rc1' 'proxy-normal.sh'
    & $exe +send-keys --target=$p1 'nn' | Out-Null   # the stray characters
    Start-Sleep -Milliseconds 800
    $r = Run-Helper $helper $p1 'continue-marker-A'
    $t1 = Tail $p1
    Assert ($t1.Contains('RC-CLEARED')) 'A1 pane ran the bare /clear command (stray input was wiped)'
    Assert (-not $t1.Contains('RC-TEXT[nn/clear]')) 'A2 no "nn/clear" arrived as ordinary text'
    Assert ($r.log -match 'cleared input line rc=0') 'A3 log records the composer wipe'
    Assert ($r.log -match 'verified: /clear landed') 'A4 log records the VERIFIED clear'
    Assert (Wait-Tail $p1 'RC-TEXT[continue-marker-A]' 10) 'A5 continuation typed into the fresh session'
    Assert ($r.log -match 'verified: continuation is on screen') 'A6 log records the VERIFIED continuation'
    Assert ($r.log -notmatch 'RESET-CONTEXT FAILED') 'A7 no failure shouted on the happy path'
    $b1 = Banner-Of $p1
    Assert ([string]::IsNullOrEmpty($b1)) "A8 no banner set on the happy path (got '$b1')"
    Assert (-not (Test-Path $r.cont)) 'A9 continuation file cleaned up'

    # --- B. negative control: the C-u line deleted ------------------------
    $p2 = New-ProxyWindow 'rc2' 'proxy-normal.sh'
    & $exe +send-keys --target=$p2 'nn' | Out-Null
    Start-Sleep -Milliseconds 800
    $r = Run-Helper $prefixWin $p2 'continue-marker-B'
    $t2 = Tail $p2
    Assert ($t2.Contains('RC-TEXT[nn/clear]')) 'B1 pre-fix: "nn/clear" arrives as ordinary text (filed symptom)'
    Assert (-not $t2.Contains('RC-CLEARED')) 'B2 pre-fix: the session was never cleared'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'B3 failure is SHOUTED into the log'
    Assert ($r.log -match "still on screen after two submits") 'B4 log names the clear as the failing step'
    Assert ($r.log -match 'pane tail at the time of failure') 'B5 log carries the pane tail as evidence'
    $b2 = Banner-Of $p2
    Assert ($b2 -and $b2 -match 'reset-context FAILED') "B6 banner tells the user (got '$b2')"
    # Seen to fail intermittently (T483). The shared helper log is overwritten
    # by the sections after this one, so print the evidence AT the failure or
    # it is gone by the time anyone reads the run.
    $b7 = Wait-Tail $p2 'RC-TEXT[continue-marker-B]' 10
    if (-not $b7) {
        Write-Host '      B7 diag: helper log ->' -ForegroundColor Yellow
        ($r.log -split "`r?`n") | Where-Object { $_ -match 'continuation|send-keys|typed' } | ForEach-Object { Write-Host "        $_" }
        Write-Host ('      B7 diag: pane tail -> ' + ((Tail $p2) -replace "`r?`n", ' | ')) -ForegroundColor Yellow
    }
    Assert $b7 'B7 continuation still sent despite the failure'

    # --- C. cleared, then the prompt was eaten ----------------------------
    $p3 = New-ProxyWindow 'rc3' 'proxy-amnesia.sh'
    $r = Run-Helper $helper $p3 'continue-marker-C'
    Assert ($r.log -match 'verified: /clear landed') 'C1 the clear itself verified'
    # A silent, unchanging pane is the ONLY thing that still fails: no echo of
    # the prompt and no repaint. The wording moved with T261, so match the
    # thing the verdict is about, not the sentence it used to be phrased in.
    Assert ($r.log -match 'never echoed the continuation and did not repaint') 'C2 the missing continuation is caught'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'C3 and shouted'
    $b3 = Banner-Of $p3
    Assert ($b3 -and $b3 -match 'reset-context FAILED') "C4 banner tells the user (got '$b3')"

    # --- E. the prompt was ACCEPTED and the session is working (T182) ------
    # The case that used to false-FAIL on every good reset: submitting empties
    # the composer, so the text the check searched for is gone within a second
    # and the pane shows a working session instead. Nothing is broken here, so
    # nothing may be shouted.
    $recvE = Join-Path $work 'received-E.txt'
    $p4 = New-ProxyWindow 'rc4' 'proxy-working.sh' (To-Unix $recvE) 'rc-ready'
    $r = Run-Helper $helper $p4 'continue-marker-E'
    Assert ($r.log -match 'verified: /clear landed') 'E1 the clear verified against a non-echoing pane'
    Assert (Wait-Tail $p4 'Working...' 10) 'E2 the pane is visibly working on the continuation'
    # The out-of-band oracle: the continuation really did arrive, so a success
    # verdict here is CORRECT rather than lucky.
    # [string] because the receipt file does not exist until the pane writes it,
    # and a $null from Get-Content would make the NEXT .Contains() throw.
    $gotE = ''
    for ($t = 0; $t -lt 25 -and -not $gotE.Contains('continue-marker-E'); $t++) {
        $gotE = [string](Get-Content $recvE -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 200
    }
    Assert ($gotE -and $gotE.Contains('continue-marker-E')) 'E3 the pane really received the continuation'
    Assert ($r.log -match 'verified: pane is repainting') 'E4 delivery verified by the repaint, not by the vanished echo'
    Assert ($r.log -notmatch 'RESET-CONTEXT FAILED') 'E5 no failure shouted over a session that is answering'
    $b4 = Banner-Of $p4
    Assert ([string]::IsNullOrEmpty($b4)) "E6 no recover-by-hand banner painted over it (got '$b4')"

    # --- F. negative control: the same pane, minus the T261 repaint branch --
    # Proves E is load-bearing: cut the branch out and this exact success is
    # reported as a failure again, which is the bug T182 was filed for.
    $recvF = Join-Path $work 'received-F.txt'
    $p5 = New-ProxyWindow 'rc5' 'proxy-working.sh' (To-Unix $recvF) 'rc-ready'
    $r = Run-Helper $norepaintWin $p5 'continue-marker-F'
    $gotF = ''
    for ($t = 0; $t -lt 25 -and -not $gotF.Contains('continue-marker-F'); $t++) {
        $gotF = [string](Get-Content $recvF -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 200
    }
    Assert ($gotF -and $gotF.Contains('continue-marker-F')) 'F1 pre-T261: the continuation arrived just the same'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'F2 pre-T261: a delivered continuation is called a failure (the filed bug)'
    $b5 = Banner-Of $p5
    Assert ($b5 -and $b5 -match 'reset-context FAILED') "F3 pre-T261: and banners it at the user (got '$b5')"

    # --- D. durability of the fix (T130's lesson) -------------------------
    $cached = Get-Content $cacheHelper -Raw
    Assert ($cached -match '--when-idle C-u') 'D1 the ACTIVE plugin cache carries the composer wipe'
    Assert ($cached -match 'RESET-CONTEXT FAILED') 'D2 the ACTIVE plugin cache carries the loud verification'
    Assert ($cached -match 'verdict="pane is repainting') 'D5 the ACTIVE plugin cache accepts a repainting pane as delivery (T182)'
    Assert ($cached -notmatch 'continuation text never appeared') 'D6 and no longer carries the one-shot check that cried wolf'
    $srcRepo = 'D:\git\dzearing-claude-marketplace'
    $srcHelper = Join-Path $srcRepo 'skills\reset-context\scripts\reset-context.sh'
    if (Test-Path $srcHelper) {
        $a = [IO.File]::ReadAllBytes($cacheHelper)
        $b = [IO.File]::ReadAllBytes($srcHelper)
        $same = ($a.Length -eq $b.Length)
        if ($same) { for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } } }
        Assert $same 'D3 source repo copy is byte-identical to the cache (no cache-only fix)'
        $v = (Get-Content (Join-Path $srcRepo '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version
        Assert ([version]$v -ge [version]'0.11.0') "D4 source plugin version bumped to carry it (got $v)"
    } else {
        Write-Host 'SKIP  D3/D4: dzearing-claude-marketplace not cloned on this box' -ForegroundColor Yellow
    }
} finally {
    foreach ($w in @('rc1', 'rc2', 'rc3', 'rc4', 'rc5')) { & $exe +close --target=$w 2>$null | Out-Null }
    Start-Sleep -Milliseconds 500
    Kill-RepoInstances
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" -ForegroundColor Green; exit 0 }
Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red
exit 1
