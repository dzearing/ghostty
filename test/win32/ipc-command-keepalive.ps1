# T468 acceptance: a `--command=` pane must land at a LIVE shell.
#
# docs/claude/cli.md's `--shell` table is the contract: "the shell stays alive after the
# command in every case" - `cmd /K`, `pwsh -NoExit -Command`, and for a posix
# shell `-lic "<cmd>; exec <shell> -li"`. What actually happened was
#
#     KA-MARKER
#     Process exited. Press any key to close the terminal.
#
# and a pane `+send-keys` could not drive at all, which is every documented
# `--command=` workflow (docs/claude/cli.md's own three-pane example makes three dead
# panes) and the reason `conformance.ps1` S8.5 failed.
#
# The cause was NOT the wrap table, which was correct and unit-tested. It was
# that the table was only applied on the plain-ConPTY path, and with
# `session-persistence` on - the default - every local pane is agent-backed
# instead. That path forwarded the command as a RAW string in `OPEN.command`,
# and the agent synthesized `cmd.exe /c <cmd>`, which exits. The keep-alive
# convention is spelled in ARGV on Windows and argv cannot ride a command
# string, so the fix sends the wrapped invocation as `OPEN.argv`.
#
#   powershell -NoProfile -File test\win32\ipc-command-keepalive.ps1
#
# Arms - each is "the command ran" AND "the pane is still alive afterwards",
# because either half alone passes on a broken build (a dead pane still shows
# the command's output above the tombstone line):
#   A  `+new-window --command=` on the default shell (cmd.exe)
#   B  ... `--shell=powershell.exe`
#   C  ... `--shell=<git-bash>` (the posix `-lic ...; exec` row)
#   D  `+split --command=`
#   E  `+new-window --split=right --split-command=` (the inline split)
#   F  `--shell=pwsh.exe` / `nu.exe` when installed on this box, else SKIP
#   I  `--shell=wsl.exe` (T656). This row was the odd one out: `wsl -- <cmd>`
#      hands the rest of the WINDOWS command line to the distro's shell as
#      written, so the quoting Windows applies to a spaced argument survived
#      into the distro and bash answered `command not found` naming the whole
#      line. It is now `wsl -e /bin/sh -lic "<cmd>; exec \"$SHELL\" -li"`, so
#      the arm asserts the marker, the ABSENCE of `command not found`, and a
#      live prompt afterwards like every other flavor.
# Controls, which must hold in BOTH builds:
#   G  the `--command=` pane really is agent-backed (`session_id` in
#      `+list --json`). Without this the whole file goes vacuous the day
#      persistence is off by default - it would then exercise the path that
#      was never broken and still report ALL PASS.
#   H  `-e` is NOT keep-alived. `-e` means "exec exactly this"; widening the
#      wrap to it would be a different defect, so the tombstone line is the
#      CORRECT outcome there.
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) so it
# never takes the user's foreground.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-cmd-keepalive-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GHOZTTY_PIPE_SUFFIX = '-cmdkeepalive'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertAlways($name, $cond) { Assert $name $cond }
function Skip($name, $why) { $script:skipped++; "  SKIP $name - $why" }

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
function Get-Leaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}
function Get-WindowLeaves($target) {
    $j = Get-ListJson
    if ($null -eq $j) { return @() }
    $win = $j.data.windows | Where-Object { $_.target -eq $target }
    if ($null -eq $win) { return @() }
    @(Get-Leaves $win.tabs[0].splits)
}

# Poll a pane until `$Pattern` shows up, then return the whole tail. Polling
# rather than sleeping because a shell's startup cost varies by flavor (wsl and
# git-bash are seconds slower than cmd) and a fixed sleep would either be flaky
# or make the file crawl.
function Wait-Read($name, $Pattern, $TimeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Ghoztty "+read --name=$name --lines=40" "$tmp\read.txt"
        $last = $r.Text
        if ($r.Code -eq 0 -and $last -match $Pattern) { return $last }
        Start-Sleep -Milliseconds 400
    }
    return $last
}

# The whole assertion for one flavor, in the order that makes a broken build
# fail on the RIGHT line: the command ran, the pane did not die, and it still
# accepts input.
function Test-KeepAlive($Label, $Pane, $Marker, $TimeoutSec = 25) {
    $tail = Wait-Read $Pane ([regex]::Escape($Marker)) $TimeoutSec
    Assert "$Label the command ran" ($tail -match [regex]::Escape($Marker))
    Assert "$Label the pane did not exit (no 'Process exited' tombstone)" (
        $tail -notmatch 'Process exited')
    $probe = "ALIVE$($Marker)"
    Invoke-Ghoztty "+send-keys --target=$Pane `"echo $probe`" Enter" "$tmp\keys.txt" | Out-Null
    $after = Wait-Read $Pane "$probe\s*[\r\n]" $TimeoutSec
    # The echoed command line matches too, so require the OUTPUT: the marker on
    # a line of its own, i.e. at least twice in the tail.
    $hits = ([regex]::Matches($after, [regex]::Escape($probe))).Count
    Assert "$Label +send-keys runs in the pane afterwards" ($hits -ge 2)
}

Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
try {
    "== setup: launch the debug build on the background desktop"
    # persistence: on (default) - the keep-alive path under test is the agent-backed one (T468).
    $app = Start-OnTestDesktop -Exe $Exe -StdErr (Join-Path $tmp 'app.err')
    $hwnd = Wait-TestWindow -ProcessId $app.Pid
    if ($hwnd -eq [IntPtr]::Zero) {
        "  SETUP FAIL app window never appeared"
        exit 1
    }
    "  app pid=$($app.Pid)"

    # ------------------------------------------------------------------
    "== A: +new-window --command= on the default shell (cmd.exe)"
    # ------------------------------------------------------------------
    Invoke-Ghoztty "+new-window --target=kacmd `"--command=echo KAMARKERCMD`"" "$tmp\new-cmd.txt" | Out-Null
    $leaves = @(Get-WindowLeaves 'kacmd')
    AssertAlways "A +list reports the pane" ($leaves.Count -eq 1)
    if ($leaves.Count -eq 1) {
        Test-KeepAlive 'A cmd' $leaves[0].id 'KAMARKERCMD'

        # --------------------------------------------------------------
        "== G: control - that pane is agent-backed (the path the defect lived on)"
        # --------------------------------------------------------------
        AssertAlways "G the --command pane carries a session_id" (
            -not [string]::IsNullOrEmpty($leaves[0].session_id))
    }

    # ------------------------------------------------------------------
    "== B: --shell=powershell.exe"
    # ------------------------------------------------------------------
    Invoke-Ghoztty "+new-window --target=kaps --shell=powershell.exe `"--command=echo KAMARKERPS`"" "$tmp\new-ps.txt" | Out-Null
    $leaves = @(Get-WindowLeaves 'kaps')
    AssertAlways "B +list reports the pane" ($leaves.Count -eq 1)
    if ($leaves.Count -eq 1) { Test-KeepAlive 'B powershell' $leaves[0].id 'KAMARKERPS' }

    # ------------------------------------------------------------------
    "== C: --shell=<git-bash> (the posix -lic ...; exec row)"
    # ------------------------------------------------------------------
    $gitBash = 'C:\Program Files\Git\bin\bash.exe'
    if (Test-Path $gitBash) {
        Invoke-Ghoztty "+new-window --target=kagb `"--shell=$gitBash`" `"--command=echo KAMARKERGB`"" "$tmp\new-gb.txt" | Out-Null
        $leaves = @(Get-WindowLeaves 'kagb')
        AssertAlways "C +list reports the pane" ($leaves.Count -eq 1)
        if ($leaves.Count -eq 1) { Test-KeepAlive 'C git-bash' $leaves[0].id 'KAMARKERGB' }
    } else {
        Skip 'C git-bash' "not installed at $gitBash"
    }

    # ------------------------------------------------------------------
    "== D: +split --command="
    # ------------------------------------------------------------------
    Invoke-Ghoztty "+split --target=kacmd --name=kasplit `"--command=echo KAMARKERSPLIT`"" "$tmp\split.txt" | Out-Null
    Test-KeepAlive 'D +split' 'kasplit' 'KAMARKERSPLIT'

    # ------------------------------------------------------------------
    "== E: +new-window --split=right --split-command="
    # ------------------------------------------------------------------
    Invoke-Ghoztty ("+new-window --target=kainline `"--command=echo KAMARKERFIRST`" " +
        "--split=right `"--split-command=echo KAMARKERINLINE`"") "$tmp\new-inline.txt" | Out-Null
    $leaves = @(Get-WindowLeaves 'kainline')
    AssertAlways "E the inline split produced two panes" ($leaves.Count -eq 2)
    if ($leaves.Count -eq 2) {
        # The inline split pane is the one whose tail carries its own marker;
        # find it rather than assuming a side (the tree order is not the
        # contract this file is testing).
        $inline = $null
        foreach ($leaf in $leaves) {
            $t = Invoke-Ghoztty "+read --name=$($leaf.id) --lines=40" "$tmp\read-inline.txt"
            if ($t.Text -match 'KAMARKERINLINE') { $inline = $leaf; break }
        }
        AssertAlways "E the inline split pane ran its command" ($null -ne $inline)
        if ($inline) { Test-KeepAlive 'E --split-command' $inline.id 'KAMARKERINLINE' }
    }

    # ------------------------------------------------------------------
    "== F: pwsh / nu, when this box has them"
    # ------------------------------------------------------------------
    foreach ($flavor in @(
            @{ Exe = 'pwsh.exe'; Target = 'kapwsh'; Marker = 'KAMARKERPWSH' },
            @{ Exe = 'nu.exe'; Target = 'kanu'; Marker = 'KAMARKERNU' })) {
        $found = Get-Command $flavor.Exe -ErrorAction SilentlyContinue
        if (-not $found) { Skip "F $($flavor.Exe)" 'not installed on this box'; continue }
        Invoke-Ghoztty ("+new-window --target=$($flavor.Target) --shell=$($flavor.Exe) " +
            "`"--command=echo $($flavor.Marker)`"") "$tmp\new-$($flavor.Target).txt" | Out-Null
        $leaves = @(Get-WindowLeaves $flavor.Target)
        AssertAlways "F $($flavor.Exe) +list reports the pane" ($leaves.Count -eq 1)
        if ($leaves.Count -eq 1) { Test-KeepAlive "F $($flavor.Exe)" $leaves[0].id $flavor.Marker }
    }

    # ------------------------------------------------------------------
    "== I: --shell=wsl.exe (T656 - the argv row, not a command-string row)"
    # ------------------------------------------------------------------
    # Gate on a distro that actually RUNS, not on wsl.exe existing: the exe
    # ships with Windows and answers even with nothing installed, so keying on
    # the binary would turn a real regression into a green run.
    $wslOk = $false
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        cmd /c "wsl.exe -e /bin/true > `"$tmp\wsl-probe.txt`" 2>&1" | Out-Null
        $wslOk = ($LASTEXITCODE -eq 0)
    }
    if (-not $wslOk) {
        Skip 'I wsl.exe' 'no WSL distro on this box that can run /bin/true'
    } else {
        Invoke-Ghoztty "+new-window --target=kawsl --shell=wsl.exe `"--command=echo KAMARKERWSL`"" "$tmp\new-wsl.txt" | Out-Null
        $leaves = @(Get-WindowLeaves 'kawsl')
        AssertAlways "I +list reports the pane" ($leaves.Count -eq 1)
        if ($leaves.Count -eq 1) {
            # A cold distro takes seconds to boot before the marker can appear.
            Test-KeepAlive 'I wsl' $leaves[0].id 'KAMARKERWSL' 60
            # The defect's exact signature, asserted apart from the marker: a
            # broken build printed `command not found` naming the whole command
            # line, which no amount of "the pane is alive" would catch.
            $tail = Invoke-Ghoztty "+read --name=$($leaves[0].id) --lines=40" "$tmp\read-wsl.txt"
            Assert "I the command was not swallowed as one quoted word" (
                $tail.Text -notmatch 'command not found')
        }
    }

    # ------------------------------------------------------------------
    "== H: control - -e is NOT keep-alived (it means 'exec exactly this')"
    # ------------------------------------------------------------------
    Invoke-Ghoztty "+new-window --target=kaexec -e cmd /c `"echo KAMARKEREXEC`"" "$tmp\new-exec.txt" | Out-Null
    $leaves = @(Get-WindowLeaves 'kaexec')
    AssertAlways "H +list reports the -e pane" ($leaves.Count -eq 1)
    if ($leaves.Count -eq 1) {
        $tail = Wait-Read $leaves[0].id 'Process exited'
        AssertAlways "H the -e command ran" ($tail -match 'KAMARKEREXEC')
        AssertAlways "H the -e pane exits with its command (no wrap imposed)" (
            $tail -match 'Process exited')
    }

    "== foreground"
    $fgSeen = @(Stop-TestForegroundWatch)
    $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    AssertAlways "the user's foreground was never taken" ($leaked.Count -eq 0)
} finally {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
    if ($td) { Remove-TestDesktop $td }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
