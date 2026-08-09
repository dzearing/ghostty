# PaneLiveness.ps1 - the "attached is not alive" oracle (T652).
#
# THE RULE, for every acceptance script that restores or re-attaches a pane:
#
#   A pane that came back as a frozen picture is byte-identical to a working
#   one for every assertion that reads the screen. Proving the painted bytes
#   match a recorded snapshot proves nothing at all - a dead pane proves it
#   equally well. So a restore test does not get to stop at "it looks right":
#   it must TYPE INTO the pane and require new output back.
#
# That is what this file is. It came out of T532, where a build restored every
# pane correctly-painted and completely dead, and the whole acceptance suite
# passed over it (user, 2026-08-06).
#
# Usage - one line per restored pane, after the restore has settled:
#
#   . (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
#   Assert (Test-PaneLive -Exe $exe -Target 'mypane' -Tmp $tmp) `
#       'X1 the restored pane is LIVE: input reaches the child, output returns'
#
# TEETH-CHECK. An oracle nobody has seen go red is a decoration. Re-run any
# script with
#
#   $env:GHOZTTY_TEST_LIVENESS_BREAK = '1'
#
# and every Test-PaneLive in it matches a token that was never sent, so each
# liveness arm - and nothing else in the script - goes RED. Unset it again
# afterwards. This is the deliberate mismatch the arms were teeth-checked with,
# kept as a switch instead of a hand edit so the check is repeatable by anyone.
#
# A viewer pane has no shell to type into; its equivalent claim (the page still
# responds - a reload lands and its result reaches the app) is built where the
# page server lives, in test\win32\viewer-restore.ps1.

$script:PaneLiveSeq = 0

# Run one CLI verb through cmd.exe with a real redirect. Not `& $exe ... |`:
# ghoztty.exe is GUI-subsystem, and a bounded WaitForExit is what keeps a wedged
# server from hanging the script instead of failing it.
function Invoke-LivenessCli([string]$Exe, [string]$ArgsLine, [string]$Out, [int]$TimeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $ArgsLine > `"$Out`" 2>&1`""
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}

# Type a run-unique token into $Target and poll +read until it comes back.
# Returns $true/$false and never throws - it is meant to be the condition of an
# Assert, so a broken pane must fail the arm rather than the script.
#
# The token is space-free (a space would split it across two +send-keys
# positional arguments) and the read is whitespace-stripped, so a token that
# wraps across a terminal line still matches.
function Test-PaneLive {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Tmp,
        [int]$TimeoutSec = 25,
        [string]$Tag = 'X',
        [int]$MinHits = 2
    )
    if (-not $Tmp) { $Tmp = $env:TEMP }
    if (-not (Test-Path $Tmp)) { New-Item -ItemType Directory -Force $Tmp | Out-Null }

    $script:PaneLiveSeq++
    $token = "GLIVE$Tag$PID" + "N$($script:PaneLiveSeq)Z"

    # The teeth-check: look for something that was never typed. Everything else
    # about the run is unchanged, so only the liveness arms move.
    $want = $token
    if ($env:GHOZTTY_TEST_LIVENESS_BREAK -eq '1') { $want = $token + 'BREAK' }

    $sendOut = Join-Path $Tmp "panelive-send-$($script:PaneLiveSeq).txt"
    $readOut = Join-Path $Tmp "panelive-read-$($script:PaneLiveSeq).txt"

    # `echo <token>`, not a bare token: every shell a pane can be running has an
    # echo, and the command gives the token a SECOND appearance that only a
    # working child can produce.
    #
    # The separator is the `Space` KEY and not a space inside a quoted argument:
    # adjacent TEXT positionals are merged into one run with no separator
    # between them (`resolveSegments` in src/cli/send_keys.zig), so `echo` and
    # the token as two arguments would arrive as `echoGLIVE...`.
    Invoke-LivenessCli $Exe "+send-keys --target=$Target echo Space $token Enter" $sendOut 15 | Out-Null

    # TWICE, which is the whole point (this rule came from T230's probe): once as
    # the echoed input line, once as the command's output. ONE occurrence is
    # keystrokes landing in a line editor and proves only that bytes went in - a
    # pane whose child is gone can still show you what you typed.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Invoke-LivenessCli $Exe "+read --name=$Target --lines=2000" $readOut 12
        if ($code -eq 0 -and (Test-Path $readOut)) {
            $txt = ''
            try { $txt = Get-Content $readOut -Raw } catch { $txt = '' }
            if ($null -eq $txt) { $txt = '' }
            $hits = ([regex]::Matches(($txt -replace '\s', ''), [regex]::Escape($want))).Count
            if ($hits -ge $MinHits) { return $true }
        }
        Start-Sleep -Milliseconds 700
    }
    return $false
}
