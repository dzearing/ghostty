# Acceptance for `+send-keys` bracketed-paste framing (T428): a text argument
# followed by a key argument must reach the pane as a FRAMED paste plus a BARE
# carriage return, so the receiving TUI reads the CR as a submit rather than as
# a newline inside pasted text.
#
#   powershell -NoProfile -File test\win32\send-keys-bracketed.ps1
#
# The defect this exists for: `/reset-context` cleared the session, typed a
# 706-character continuation, sent Enter with rc=0 - and the prompt sat unsent
# in the composer until the user pressed Enter by hand. `+send-keys` flattened
# every positional into one `--keys=` payload, so the pane received a single
# burst of bytes ending in `\r` and paste detection (correctly, for an
# unframed burst) read that CR as pasted content.
#
# What makes this an oracle rather than a demonstration:
#
#   * The capture is BYTE-EXACT and taken from RAW VT INPUT. The in-pane
#     helper switches its stdin to ENABLE_VIRTUAL_TERMINAL_INPUT with no line
#     input and no echo - the same console mode a real TUI uses - so the bytes
#     are recorded exactly as they left the terminal. A screen read could not
#     see a fencepost at all.
#   * Every framed case has a NEGATIVE CONTROL with the same payload against a
#     pane that has NOT enabled mode 2004. Without it a green run cannot tell
#     "the framing works" from "these bytes were never the problem" - and it is
#     also the regression guard for every ordinary pane, which must keep
#     receiving exactly what it received before.
#
# Rounds 13-14 (T664) extend the same capture to DELIVERY INTEGRITY: the shape
# that once lost a text run's first character - a bare Enter, a beat, then a
# `--keys-file` run plus `Enter` - measured byte for byte, with a payload long
# enough to cross the 64-byte pooled write buffer in termio.Exec.queueWrite.
# `test\win32\send-keys-soak.ps1` is the on-demand soak for the same shape.
#
# NOT interactive: everything here is IPC (+split / +send-keys / +read), so it
# needs no foreground and does not belong on the T211 test desktop.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-skb-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$win = "skbw$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ESC = [char]27
$FRAME_START = '1b5b3230307e'   # ESC [ 2 0 0 ~
$FRAME_END = '1b5b3230317e'     # ESC [ 2 0 1 ~
$CR = '0d'

function To-Hex([string]$s) {
    ($s.ToCharArray() | ForEach-Object { ([int]$_).ToString('x2') }) -join ''
}

# The in-pane capture. It puts its stdin in raw VT mode - exactly what a
# full-screen TUI does - and records every byte it receives as hex. -Mode on
# also enables bracketed paste (DEC 2004), which is what tells the terminal
# this program wants its pastes framed; -Mode off is the negative control.
$capture = @'
param([string]$Out, [int]$N, [double]$Secs, [string]$Tag, [string]$Mode)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConMode {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
"@
$hIn = [ConMode]::GetStdHandle(-10)
$hOut = [ConMode]::GetStdHandle(-11)
$om = [uint32]0
[void][ConMode]::GetConsoleMode($hOut, [ref]$om)
[void][ConMode]::SetConsoleMode($hOut, [uint32]($om -bor 0x0004))
# ENABLE_VIRTUAL_TERMINAL_INPUT only: no ENABLE_LINE_INPUT, no ENABLE_ECHO_INPUT,
# no ENABLE_PROCESSED_INPUT. Bytes arrive as they were written.
[void][ConMode]::SetConsoleMode($hIn, [uint32]0x0200)
$e = [char]27
if ($Mode -eq 'on') { [Console]::Out.Write("$e[?2004h") } else { [Console]::Out.Write("$e[?2004l") }
[Console]::Out.Write("READY-$Tag`r`n")
[Console]::Out.Flush()
$stdin = [Console]::OpenStandardInput()
$buf = New-Object byte[] 4096
$sb = New-Object System.Text.StringBuilder
$total = 0
$deadline = (Get-Date).AddSeconds($Secs)
while ($total -lt $N -and (Get-Date) -lt $deadline) {
    $k = $stdin.Read($buf, 0, $buf.Length)
    if ($k -le 0) { break }
    for ($i = 0; $i -lt $k; $i++) { [void]$sb.Append($buf[$i].ToString('x2')) }
    $total += $k
    # Written after every chunk so a send that arrives SHORT is still visible
    # instead of vanishing into a blocked read.
    [IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}
[Console]::Out.Write("DONE-$Tag $total`r`n")
'@
$capPath = Join-Path $tmp 'capture.ps1'
[IO.File]::WriteAllText($capPath, $capture, (New-Object System.Text.UTF8Encoding($false)))

function Read-Pane([string]$name, [int]$lines = 20) {
    return ((& $Exe +read "--name=$name" "--lines=$lines" 2>&1) | Out-String)
}
function Wait-Pane([string]$name, [string]$pat, [int]$sec = 30) {
    $d = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $d) {
        if ((Read-Pane $name) -match $pat) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Open a fresh capture pane, send it $SendArgs, and return the hex of every
# byte that arrived. A pane per round, spawned with --command, so no shell ever
# sees the payload and no round can inherit the previous one's state.
$script:round = 0
#
# $ThenArgs, when given, is a SECOND `+send-keys` call into the same pane a
# beat later (T438). Two calls is the shape the upgrade's reuse path is stuck
# with - it verifies the prompt arrived before submitting - and the point of
# capturing it is that no CLI-side framing can span two calls, so the bytes it
# produces are the thing the fix has to work around rather than rely on.
#
# $FirstArgs, when given, is a `+send-keys` call made a beat BEFORE the payload
# (T664). The one report of a lost first character described exactly that shape
# — a framed text run landing about a second after a bare Enter — so the leading
# keypress is part of what has to be measured, not context around it.
function Invoke-Round(
    [string]$Mode,
    [int]$Expect,
    [string[]]$SendArgs,
    [string[]]$ThenArgs,
    [string[]]$FirstArgs,
    [int]$FirstGapMs = 1000
) {
    $script:round++
    $tag = "R$($script:round)"
    $pane = "skb$PID-$($script:round)"
    $out = Join-Path $tmp "cap-$tag.txt"
    Remove-Item $out -ErrorAction SilentlyContinue

    # Ask for MORE bytes than the framed form needs, so a send that arrives too
    # LONG is captured rather than truncated to the expected length.
    $want = $Expect + 32
    $cmd = "powershell -NoProfile -File $capPath -Out $out -N $want -Secs 12 -Tag $tag -Mode $Mode"
    & $Exe +split "--target=$win" "--name=$pane" "--command=$cmd" 2>&1 | Out-Null
    if (-not (Wait-Pane $pane "READY-$tag" 30)) {
        & $Exe +close "--target=$pane" 2>&1 | Out-Null
        return '<never ready>'
    }
    Start-Sleep -Milliseconds 600

    if ($FirstArgs) {
        $first = @("--target=$pane") + $FirstArgs
        & $Exe +send-keys @first 2>&1 | Out-Null
        Start-Sleep -Milliseconds $FirstGapMs
    }
    $all = @("--target=$pane") + $SendArgs
    & $Exe +send-keys @all 2>&1 | Out-Null
    if ($ThenArgs) {
        # A real gap, not a race: the reuse path polls the pane for seconds
        # between its two calls, so the capture must see them as two separate
        # writes the way the pane does.
        Start-Sleep -Milliseconds 1500
        $then = @("--target=$pane") + $ThenArgs
        & $Exe +send-keys @then 2>&1 | Out-Null
    }
    # The capture keeps reading until $want bytes or its own timeout, so it
    # never returns early on a short send. Poll until the file stops growing
    # rather than sleeping a guessed interval: a send that lands in two chunks
    # would otherwise be read half-arrived and fail for the wrong reason.
    $got = ''
    $stable = 0
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $now = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
        if ($now -ne '' -and $now -eq $got) { $stable++; if ($stable -ge 2) { break } }
        else { $stable = 0 }
        $got = $now
    }
    & $Exe +send-keys "--target=$pane" C-c 2>&1 | Out-Null
    & $Exe +close "--target=$pane" 2>&1 | Out-Null
    return $got
}

# T441: this run's own IPC endpoint. CleanSlate drops the caller pane's baked
# `$GHOZTTY_IPC_SOCKET` (T118), which already keeps a Debug zig-out off the
# user's release pipe — but every debug script still shares the ONE derived
# `-debug` endpoint, so two runs (or a developer's own debug instance) collide,
# and a non-Debug zig-out puts the whole suite back on the user's endpoint. The
# suffix makes the endpoint per-run, and the asserts make it checked.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'skbrk')

Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== setup: app + host window (no persistence, no activation)"
Start-Process -FilePath $Exe -ArgumentList '--session-persistence=false' | Out-Null
Start-Sleep -Seconds 4
& $Exe +new-window "--target=$win" --no-activate 2>&1 | Out-Null
Start-Sleep -Seconds 3
Assert "window $win exists" (((& $Exe +list 2>&1) | Out-String) -match [regex]::Escape($win))
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe

$msg = 'hello world'
$msgHex = To-Hex $msg

"== 1: mode 2004 ON - the text is framed and the CR lands OUTSIDE the frame"
$r1 = Invoke-Round 'on' 24 @($msg, 'Enter')
"     got: $r1"
Assert "text run is bracketed and the Enter is bare" ($r1 -eq ($FRAME_START + $msgHex + $FRAME_END + $CR))

"== 2: NEGATIVE CONTROL - mode 2004 OFF gets exactly the old bytes"
$r2 = Invoke-Round 'off' 12 @($msg, 'Enter')
"     got: $r2"
Assert "unframed, byte-for-byte what it was before framing" ($r2 -eq ($msgHex + $CR))
Assert "no fencepost anywhere" (-not ($r2.Contains($FRAME_START) -or $r2.Contains($FRAME_END)))

"== 3: the /reset-context shape - --keys-file= then Enter is framed too"
$pf = Join-Path $tmp 'prompt.txt'
[IO.File]::WriteAllText($pf, $msg, (New-Object System.Text.UTF8Encoding($false)))
$r3 = Invoke-Round 'on' 24 @("--keys-file=$pf", 'Enter')
"     got: $r3"
Assert "file payload is a text run, framed, CR outside" ($r3 -eq ($FRAME_START + $msgHex + $FRAME_END + $CR))

"== 4: a text-only send is NOT framed (one segment, nothing to disambiguate)"
# `+send-keys "cmd\n"` must keep executing in a shell, so a lone text run
# stays exactly the bytes it always was.
$r4 = Invoke-Round 'on' 12 @($msg)
"     got: $r4"
Assert "single text argument sent flat" ($r4 -eq $msgHex)

"== 5: text carrying a closing fencepost is sent unframed, never malformed"
# Framing it would end the frame early and leave the tail outside it.
$evil = 'x' + $ESC + '[201~y'
$r5 = Invoke-Round 'on' 24 @($evil, 'Enter')
"     got: $r5"
Assert "no frame was opened" (-not $r5.StartsWith($FRAME_START))
Assert "the bytes still arrived intact, CR last" ($r5 -eq ((To-Hex $evil) + $CR))

$SPACE = '20'

"== 6: PRE-FIX ORACLE (T438) - two calls can never be framed, whatever the CLI does"
# The upgrade's reuse path types the prompt, VERIFIES it arrived, and only then
# submits, because a post-submit check races /reset-context clearing the pane
# (T210). That gate is not negotiable, so its Enter is a second call - and a
# boundary the CLI never sees is a boundary it cannot encode. This round is what
# that costs at the byte level: a flat text run and a naked CR, exactly the
# shape T428 measured a TUI swallow.
$r6 = Invoke-Round 'on' 12 @($msg) @('Enter')
"     got: $r6"
Assert "split across two calls, nothing is framed" ($r6 -eq ($msgHex + $CR))
Assert "no fencepost anywhere, even with mode 2004 on" `
    (-not ($r6.Contains($FRAME_START) -or $r6.Contains($FRAME_END)))

"== 7: T438 FIX - the submitting call brings its own text run, so the CR is framed out"
# Get-LoopSubmitArgs (scripts\loop-session.ps1): submit with `" " Enter`, not a
# bare `Enter`. The space is a text run, so this call is a mixed send and the
# CLI frames it - which puts a CLOSING fencepost immediately before the CR and
# makes it unambiguously a keypress. The prompt itself is still delivered and
# verified by the earlier call, unframed per decision D4.
$r7 = Invoke-Round 'on' 25 @("--keys-file=$pf") @(' ', 'Enter')
"     got: $r7"
Assert "the prompt arrives unframed, as D4 decided" ($r7.StartsWith($msgHex))
Assert "the submit is a framed space with the CR outside it" `
    ($r7 -eq ($msgHex + $FRAME_START + $SPACE + $FRAME_END + $CR))

"== 8: NEGATIVE CONTROL - the same submit against a pane with mode 2004 OFF"
# A pane that never asked for framing gets the plain bytes: one space and a CR.
# So the fix cannot inject fencepost junk into a program that would not
# understand it, and the space is the only thing it adds anywhere.
$r8 = Invoke-Round 'off' 13 @("--keys-file=$pf") @(' ', 'Enter')
"     got: $r8"
Assert "unframed space then CR" ($r8 -eq ($msgHex + $SPACE + $CR))
Assert "no fencepost anywhere" (-not ($r8.Contains($FRAME_START) -or $r8.Contains($FRAME_END)))

# --- T604: main's submission semantics, at the byte level -------------------
#
# The peel and `--enter` are pinned in the none lane, but what they exist for
# is what a TUI RECEIVES - and only this capture can see that. Each of the
# three spellings below has to produce the same bytes as `"text" Enter` does
# in round 1, or they are not the same feature.

"== 9: a trailing \n is peeled into a keypress - framed text, CR outside"
# The spelling agents reach for first. Before T604 this took the flat path: one
# text run ending in a literal 0a, no frame, no keypress - typed into the
# composer and never submitted.
$r9 = Invoke-Round 'on' 24 @("$msg\n")
"     got: $r9"
Assert "same bytes as an explicit trailing Enter (round 1)" `
    ($r9 -eq ($FRAME_START + $msgHex + $FRAME_END + $CR))
Assert "no literal newline survived inside the frame" `
    (-not $r9.Contains($FRAME_START + $msgHex + '0a'))

"== 10: --enter is the same send as a trailing Enter argument"
$r10 = Invoke-Round 'on' 24 @('--enter', $msg)
"     got: $r10"
Assert "framed text with the CR outside" `
    ($r10 -eq ($FRAME_START + $msgHex + $FRAME_END + $CR))

"== 11: --keys-file= is exempt from the peel, but ConPTY normalization is not"
# Two layers, and only the first is the CLI's. The CLI genuinely exempts a file
# from the trailing-newline peel (D52) and emits 0a - pinned in the none lane
# by "keys-file: a trailing newline in the file stays content, unpeeled".
#
# The SERVER then runs verb_args.normalizeConptyInput over every run
# (IpcHandlers.handleSendKeys), which turns LF and CRLF into CR because Enter
# on a ConPTY is CR. So on Windows the file's trailing newline reaches the pane
# as 0d and submits after all. That is pre-existing win32 behavior, older than
# T604 - this round exists so it is a MEASURED fact rather than a surprise, and
# so the docs cannot go on claiming a file is byte-exact on the wire here.
# Tracked as T661.
$pfn = Join-Path $tmp 'prompt-nl.txt'
[IO.File]::WriteAllText($pfn, "$msg`n", (New-Object System.Text.UTF8Encoding($false)))
$r11 = Invoke-Round 'on' 13 @("--keys-file=$pfn")
"     got: $r11"
Assert "one text run, so unframed (round 4's rule)" `
    (-not ($r11.Contains($FRAME_START) -or $r11.Contains($FRAME_END)))
Assert "the file's LF is normalized to CR by the server, not left as 0a" `
    ($r11 -eq ($msgHex + $CR))

"== 12: an INTERIOR newline is normalized to CR too (win32 divergence, T661)"
# Main's contract for the peel is 'interior newlines stay literal inside the
# paste, so "a\nb\n" pastes two lines and then submits'. The peel half holds
# here - the trailing newline leaves the frame as a keypress - but the interior
# 0a does NOT survive as 0a, because normalizeConptyInput rewrites it inside
# the text run. The bytes below are what a TUI on Windows actually receives.
$r12 = Invoke-Round 'on' 16 @("a\nb\n")
"     got: $r12"
Assert "the trailing newline still became a keypress outside the frame" `
    ($r12.EndsWith($FRAME_END + $CR))
Assert "the interior newline arrived as CR, not LF" `
    ($r12 -eq ($FRAME_START + '610d62' + $FRAME_END + $CR))

# --- T664: a text run that follows a bare Enter arrives WHOLE ---------------
#
# One run of test\win32\reset-context.ps1 in five once showed section B's pane
# receiving `RC-TEXT[ontinue-marker-B]` — the FIRST character of a `--keys-file`
# text run gone, about a second after a bare Enter. A screen read cannot say
# whether the byte never arrived or the grid lost it, and nothing in the suite
# measured this shape on the wire; that is why the report stayed an anecdote.
# These two rounds are that measurement, and they are byte-exact: the leading
# `0d` is the Enter, then the frame, then the payload, then the frame, then the
# submitting CR. A lost leading character shows up as a missing byte here and
# nowhere else.

"== 13: T664 shape - a keys-file text run a beat after a bare Enter, intact"
$r13 = Invoke-Round 'on' 26 @("--keys-file=$pf", 'Enter') $null @('Enter')
"     got: $r13"
Assert "the Enter, then the framed payload with the CR outside" `
    ($r13 -eq ($CR + $FRAME_START + $msgHex + $FRAME_END + $CR))
Assert "the payload's FIRST byte survived the preceding keypress" `
    ($r13.Contains($FRAME_START + $msgHex))

"== 14: T664 shape with a payload that crosses the pty write chunk"
# termio.Exec.queueWrite copies a write into 64-byte pooled buffers, so a run
# longer than that is split across two pty writes — the only seam in our path
# that can divide a frame. The realistic payload is the loop's own handoff
# sentence, which is ~90 bytes before framing, so every real reset-context
# delivery takes this path and none of the rounds above did.
$long = 'Read C:/Users/David/AppData/Local/Temp/reset-context-cont-4182.txt - it contains your instructions.'
$longHex = To-Hex $long
$pfl = Join-Path $tmp 'prompt-long.txt'
[IO.File]::WriteAllText($pfl, $long, (New-Object System.Text.UTF8Encoding($false)))
$r14 = Invoke-Round 'on' ($long.Length + 14) @("--keys-file=$pfl", 'Enter') $null @('Enter')
"     got: $r14"
Assert "a chunk-crossing payload arrives whole, framed, CR outside" `
    ($r14 -eq ($CR + $FRAME_START + $longHex + $FRAME_END + $CR))

"== teardown"
& $Exe +close "--target=$win" 2>&1 | Out-Null
Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) {
    "SEND-KEYS BRACKETED ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "SEND-KEYS BRACKETED ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
