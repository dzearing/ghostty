# T181 acceptance: `+read` must not report an EMPTY pane as a failure.
#
# A terminal pane that has printed nothing dumps an empty screen, and `+read`
# used to answer that with
#
#     failed to read terminal content from '<pane-id>'
#
# which a caller cannot tell apart from "no such pane", "the pane is wedged",
# or "the app is broken". Two panes are in that state routinely: one running
# something silent, and - for the first fraction of a second of its life -
# EVERY pane, because the window is registered (and `+list --json` already
# reports its pane id and its child's pid) before the shell has painted a
# prompt. The second one is transient, which is what made it dangerous: an
# agent that reads once and believes the answer records "the pane produced no
# output" as a product verdict rather than as a race it lost.
#
#   powershell -NoProfile -File test\win32\ipc-read-race.ps1
#
# Arms:
#   A  a SILENT pane (a child that writes nothing) reads back as exit 0 with
#      empty output. This is the deterministic form of the defect and the arm
#      that reproduces it: pre-fix it is exit 1 every time.
#   B  the race as filed - create, `+list`, `+read`, no sleep anywhere - over
#      -Rounds rounds. It did NOT reproduce on this box (a CLI process launch
#      is long enough for cmd.exe to paint its prompt), so it is kept as the
#      caller shape from the field rather than as the repro.
#   C  `+send-keys` aimed at that same freshly created pane is not lost.
# Controls, which must hold in both builds:
#   D  a pane with real output still reads back its content
#   E  an unknown name still FAILS, and says "not found in registry" - the
#      error the empty-screen case used to be indistinguishable from
#   F  a viewer pane still FAILS with its own message
#   G  (T193) a pane showing the ALTERNATE screen reads back the VISIBLE
#      screen with exit 0 - not scrollback (the alt screen has none by
#      design), and not the old blanket failure - and recovers the primary
#      screen's scrollback when the program leaves the alt screen. This is
#      what an agent watching a pane that happens to run htop, a pager, or a
#      full-screen installer needs. The child prints markers around the
#      switch because a +read failure is NOT a usable oracle for "on the alt
#      screen" (it fires for other reasons too - the T190 lesson).
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) so it
# never takes the user's foreground.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$Rounds = 6,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-read-race-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GHOZTTY_PIPE_SUFFIX = '-readracetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

# Same thing, named for what it is at the call site: a control or a setup
# precondition, true in BOTH builds. A failure here means the harness or the
# build is broken, not that the fix regressed.
function AssertAlways($name, $cond) { Assert $name $cond }

# `ghoztty +verb > file` from PowerShell writes 0 bytes (T245); go through cmd.
function Invoke-Ghoztty([string]$ArgLine, [string]$OutFile) {
    cmd /c "`"$Exe`" $ArgLine > `"$OutFile`" 2>&1" | Out-Null
    $code = $LASTEXITCODE
    $text = ''
    try { $text = Get-Content $OutFile -Raw } catch { }
    if ($null -eq $text) { $text = '' }
    [pscustomobject]@{ Code = $code; Text = $text }
}

function Get-ListJson {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    try { Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json } catch { $null }
}

function Get-FirstLeaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node }
    $l = Get-FirstLeaf $node.left
    if ($null -ne $l) { return $l }
    Get-FirstLeaf $node.right
}

function Get-Leaf($target) {
    $j = Get-ListJson
    if ($null -eq $j) { return $null }
    $win = $j.data.windows | Where-Object { $_.target -eq $target }
    if ($null -eq $win) { return $null }
    (Get-FirstLeaf $win.tabs[0].splits).terminal
}

Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
try {
    "== setup: launch the debug build on the background desktop"
    # persistence: off. Nothing here is about sessions, and with it on the launch
    # RESTORES the panes an earlier run left behind - which every `+read`
    # assertion below would then be reading (T158).
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') `
        -StdErr (Join-Path $tmp 'app.err')
    $hwnd = Wait-TestWindow -ProcessId $app.Pid
    if ($hwnd -eq [IntPtr]::Zero) {
        "  SETUP FAIL app window never appeared"
        exit 1
    }
    "  app pid=$($app.Pid)"

    # ------------------------------------------------------------------
    "== A: a silent pane is readable, and reads back empty"
    # ------------------------------------------------------------------
    # `-e` runs the command directly, and `timeout ... > nul` writes nothing to
    # the terminal - so this pane's screen stays empty for 20 s while being a
    # perfectly live, attached terminal with a real child.
    Invoke-Ghoztty "+new-window --target=silent -e cmd /c `"timeout /t 20 /nobreak > nul`"" "$tmp\new-silent.txt" | Out-Null
    $silent = Get-Leaf 'silent'
    AssertAlways "A +list reports the silent pane" ($null -ne $silent)
    AssertAlways "A the silent pane has a real child (pid != 0)" ($silent.pid -gt 0)
    if ($silent) {
        $r = Invoke-Ghoztty "+read --name=$($silent.id) --lines=5" "$tmp\read-silent.txt"
        Assert "A +read of a silent pane exits 0 (was: failed to read terminal content)" ($r.Code -eq 0)
        Assert "A +read of a silent pane says nothing rather than failing" (
            $r.Text.Trim() -eq '' -and $r.Text -notmatch 'failed to read')
    }
    Invoke-Ghoztty "+close --target=silent" "$tmp\close-silent.txt" | Out-Null

    # ------------------------------------------------------------------
    "== B/C: create, +list, +read/+send-keys with no sleep ($Rounds rounds)"
    # ------------------------------------------------------------------
    $raceFails = 0
    $keyFails = 0
    for ($i = 1; $i -le $Rounds; $i++) {
        $target = "race$i"
        $new = Invoke-Ghoztty "+new-window --target=$target" "$tmp\new-$i.txt"
        $leaf = Get-Leaf $target
        if ($null -eq $leaf) {
            "  SETUP FAIL round $i - +list reported no pane for $target (new exit=$($new.Code))"
            $script:failures++
            continue
        }
        $paneId = $leaf.id
        $read = Invoke-Ghoztty "+read --name=$paneId --lines=5" "$tmp\read-$i.txt"

        $marker = "T181MARK$i"
        $keys = Invoke-Ghoztty "+send-keys --target=$paneId `"echo $marker`" Enter" "$tmp\keys-$i.txt"
        $sawMarker = $false
        for ($t = 0; $t -lt 40; $t++) {
            Start-Sleep -Milliseconds 250
            $tail = Invoke-Ghoztty "+read --name=$paneId --lines=40" "$tmp\tail-$i.txt"
            if ($tail.Text -match [regex]::Escape($marker)) { $sawMarker = $true; break }
        }

        if ($read.Code -ne 0) {
            $raceFails++
            "  round $i read exit=$($read.Code) stderr=$(($read.Text -replace '\s+', ' ').Trim())"
        }
        if (-not $sawMarker) {
            $keyFails++
            "  round $i send-keys exit=$($keys.Code) marker never echoed"
        }
        Invoke-Ghoztty "+close --target=$target" "$tmp\close-$i.txt" | Out-Null
    }
    Assert "B no round failed to read a pane +list had just reported (failed=$raceFails/$Rounds)" ($raceFails -eq 0)
    Assert "C every round's keystrokes reached the shell (lost=$keyFails/$Rounds)" ($keyFails -eq 0)

    # ------------------------------------------------------------------
    "== D: control - a pane with real output reads back its content"
    # ------------------------------------------------------------------
    Invoke-Ghoztty "+new-window --target=ctl" "$tmp\new-ctl.txt" | Out-Null
    $ctl = Get-Leaf 'ctl'
    AssertAlways "D +list reports the control pane" ($null -ne $ctl)
    if ($ctl) {
        Invoke-Ghoztty "+send-keys --target=$($ctl.id) `"echo T181CTL`" Enter" "$tmp\keys-ctl.txt" | Out-Null
        $found = $false
        for ($t = 0; $t -lt 40; $t++) {
            Start-Sleep -Milliseconds 250
            $r = Invoke-Ghoztty "+read --name=$($ctl.id) --lines=40" "$tmp\read-ctl.txt"
            if ($r.Text -match 'T181CTL') { $found = $true; break }
        }
        AssertAlways "D the control pane's output comes back through +read" $found
    }

    # ------------------------------------------------------------------
    "== E: control - an unknown name still fails, and says which"
    # ------------------------------------------------------------------
    $unknown = Invoke-Ghoztty "+read --name=no-such-pane-t181" "$tmp\read-unknown.txt"
    AssertAlways "E unknown pane exits nonzero" ($unknown.Code -ne 0)
    AssertAlways "E unknown pane says 'not found in registry'" ($unknown.Text -match 'not found in registry')

    # ------------------------------------------------------------------
    "== F: control - a viewer pane still fails with its own message"
    # ------------------------------------------------------------------
    if ($ctl) {
        $doc = Join-Path $tmp 'note.md'
        "# t181" | Set-Content -Path $doc -Encoding ascii
        Invoke-Ghoztty "+split --target=$($ctl.id) --name=t181view --view=`"$doc`"" "$tmp\split-view.txt" | Out-Null
        Start-Sleep -Milliseconds 800
        $viewRead = Invoke-Ghoztty "+read --name=t181view" "$tmp\read-view.txt"
        AssertAlways "F viewer pane exits nonzero" ($viewRead.Code -ne 0)
        AssertAlways "F viewer pane says it is a viewer, not a terminal" ($viewRead.Text -match 'viewer pane, not a terminal')
    }

    # ------------------------------------------------------------------
    "== G: a pane on the ALTERNATE screen reads back the visible screen (T193)"
    # ------------------------------------------------------------------
    # The child prints a primary-screen marker, enters the alt screen
    # (ESC[?1049h), paints alt content, holds it for 10 s, then leaves
    # (ESC[?1049l) and prints a return marker. Every phase is detected by its
    # marker, never by a failing read.
    $altScript = 'Write-Host T193PRIMARY; [Console]::Write([char]27+''[?1049h''); ' +
        '[Console]::Write(''T193ALTCONTENT''); Start-Sleep 10; ' +
        '[Console]::Write([char]27+''[?1049l''); Write-Host T193BACK; Start-Sleep 120'
    Invoke-Ghoztty "+new-window --target=altscr -e powershell -NoProfile -Command `"$altScript`"" "$tmp\new-alt.txt" | Out-Null
    $alt = $null
    for ($t = 0; $t -lt 40 -and -not $alt; $t++) { Start-Sleep -Milliseconds 250; $alt = Get-Leaf 'altscr' }
    AssertAlways "G +list reports the alt-screen pane" ($null -ne $alt)
    if ($alt) {
        # Phase 1: poll until a read shows the alt-screen content. Any read
        # that FAILS while the pane is coming up or on the alt screen is the
        # T193 defect shape.
        $altRead = $null
        $altReadFails = 0
        for ($t = 0; $t -lt 60; $t++) {
            Start-Sleep -Milliseconds 250
            $r = Invoke-Ghoztty "+read --name=$($alt.id) --lines=50" "$tmp\read-altscr.txt"
            if ($r.Code -ne 0) { $altReadFails++; continue }
            if ($r.Text -match 'T193ALTCONTENT') { $altRead = $r; break }
        }
        Assert "G +read on the alt screen exits 0 and returns the visible screen" ($null -ne $altRead)
        Assert "G no read failed on the way there (failed=$altReadFails)" ($altReadFails -eq 0)
        if ($altRead) {
            Assert "G the alt-screen read is the VISIBLE screen, not scrollback (no primary marker)" (
                $altRead.Text -notmatch 'T193PRIMARY')
        }

        # Phase 2: after the child leaves the alt screen, the primary screen's
        # scrollback is readable again - both markers visible.
        $backRead = $null
        for ($t = 0; $t -lt 80; $t++) {
            Start-Sleep -Milliseconds 250
            $r = Invoke-Ghoztty "+read --name=$($alt.id) --lines=50" "$tmp\read-altback.txt"
            if ($r.Code -eq 0 -and $r.Text -match 'T193BACK') { $backRead = $r; break }
        }
        Assert "G +read recovers the primary screen after ESC[?1049l" ($null -ne $backRead)
        if ($backRead) {
            Assert "G the recovered read has the primary scrollback (both markers)" (
                $backRead.Text -match 'T193PRIMARY' -and $backRead.Text -match 'T193BACK')
        }
    }
    Invoke-Ghoztty "+close --target=altscr" "$tmp\close-altscr.txt" | Out-Null

    "== foreground"
    $fgSeen = @(Stop-TestForegroundWatch)
    $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    AssertAlways "the user's foreground was never taken" ($leaked.Count -eq 0)
} finally {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
    if ($td) { Remove-TestDesktop $td }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
