# FloorFixture.ps1 - T1285. The P1-P3 floor's fixture is a CHECKED
# precondition, and a floor that cannot reach the app says so ONCE.
#
# THE DEFECT THIS EXISTS TO PREVENT, measured 2026-09-02. `ipc-p2.ps1` scored
#
#     P2 ACCEPTANCE: 16 FAILURE(S) (2 assertions passed)
#
# and every one of those sixteen lines was a claim about the product: +split is
# broken, +send-keys is broken, +rename is broken. None of it was true. What had
# happened was that the app under test stopped answering IPC - the CLI's own
# 5-second "Waiting for Ghoztty to answer ..." notice is in the transcript - so
# every verb after the fixture was addressed to a window that was never built.
# The run before it and the run after it were ALL PASS.
#
# The floor could not tell those apart because the fixture threw its own answer
# away:
#
#     [void](Ghoz @('+new-window', '--target=p2ide'))
#     [void](Wait-ListMatch '\[target: p2ide\]')
#
# An exit code nobody reads is not a check, and a run that keeps asserting
# against a fixture that never came up manufactures failures that point at
# innocent code. That is what "the floor cries wolf" means in practice, and it
# is a harness defect rather than a product one: CLAUDE.md names P1-P3 as the
# bar for every change, so a red nobody can act on is worse than no red at all.
#
# THE SHAPE THIS FILE IMPOSES
#
#   $r = Need-Ghoz 'the p2ide fixture window' @('+new-window', '--target=p2ide')
#
# On success it is `Invoke-OnTestDesktop` and nothing else. On a nonzero exit, a
# harness timeout, or a CLI that had to print its still-waiting notice, it
# prints ONE `FAIL SETUP:` block naming the verb, the exit code, how long it
# took and what the CLI itself said on each stream, scores one failure, and
# throws `$script:FloorSetupFail` so the body stops there instead of cascading.
#
# Wrap the body with `Invoke-FloorBody { ... }`, which swallows exactly that
# sentinel and lets every other error keep its own trace.
#
# Not a retry. A retry would paper over the same unreachable app and hand back a
# green run; this converts an unreachable app from sixteen wrong answers into
# one right one.

Set-StrictMode -Off

$script:FloorSetupFail = 'GHOZTTY-FLOOR-SETUP-FAIL'

# The signatures the CLI prints when the app is slow or gone (src/os/
# ipc_timeout.zig). Seeing either means the exchange did not go the way a
# healthy box goes it, whatever the exit code says.
$script:FloorUnresponsivePattern = 'Waiting for Ghoztty to answer|Timed out after .* trying to'

# The evidence is PARKED, not printed, and `Invoke-FloorBody` prints it on the
# way out. A helper called as `[void](Need ...)` has its output stream
# discarded by the caller, so a FAIL line written here would vanish exactly
# when it is needed - which is how the first cut of this file scored a red run
# with nothing in the transcript saying why.
$script:FloorSetupEvidence = @()

function Add-FloorCallEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string[]]$GhozArgs,
        [Parameter(Mandatory = $true)]$Result,
        [int]$Ms
    )
    $lines = @(
        "  FAIL SETUP: $What"
        "    verb:   ghoztty $($GhozArgs -join ' ')"
    )
    $timedOut = if ($Result.TimedOut) { ' (harness timeout)' } else { '' }
    $lines += "    exit:   $($Result.ExitCode)$timedOut after ${Ms}ms"
    $streams = [ordered]@{ stdout = "$($Result.StdOut)"; stderr = "$($Result.StdErr)" }
    foreach ($name in $streams.Keys) {
        $text = ($streams[$name] -replace "`r?`n", ' | ').Trim()
        if ($text) { $lines += "    ${name}: $text" }
    }
    $script:FloorSetupEvidence = $lines
}

<#
Run a CLI call the rest of the script cannot continue without.

Returns the result on success. On failure it prints the evidence above, scores
ONE failure into $script:failures, and throws the sentinel.
#>
function Need-Ghoz {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string[]]$GhozArgs,
        [Parameter(Mandatory = $true)][string]$Exe
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
    $ms = [int]$sw.ElapsedMilliseconds
    $unresponsive = ("$($r.StdErr)$($r.StdOut)" -match $script:FloorUnresponsivePattern)
    if ($r.ExitCode -ne 0 -or $r.TimedOut -or $unresponsive) {
        $why = if ($unresponsive) {
            "$What - the app under test stopped answering IPC"
        } else { $What }
        Add-FloorCallEvidence -What $why -GhozArgs $GhozArgs -Result $r -Ms $ms
        $script:failures++
        throw $script:FloorSetupFail
    }
    return $r
}

<#
Assert a fixture is VISIBLE, from a `+list` text this run already polled for.
Same contract as Need-Ghoz: one evidence block, one failure, then stop.
#>
function Need-Listed {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [AllowNull()][AllowEmptyString()][string]$ListText
    )
    if ("$ListText" -match $Pattern) { return }
    $seen = ("$ListText" -replace "`r?`n", ' | ').Trim()
    $script:FloorSetupEvidence = @(
        "  FAIL SETUP: $What never appeared in +list"
        "    waited for: $Pattern"
        "    +list said: $(if ($seen) { $seen } else { '(nothing)' })"
    )
    $script:failures++
    throw $script:FloorSetupFail
}

<#
Run the acceptance body, swallowing ONLY the setup sentinel. Anything else is
re-thrown with its original error, so a real bug in a script still surfaces.
#>
function Invoke-FloorBody {
    param([Parameter(Mandatory = $true)][scriptblock]$Body)
    try { & $Body }
    catch {
        if ("$_" -ne $script:FloorSetupFail) { throw }
        $script:FloorSetupEvidence
        "  (run stopped after the setup failure above; the remaining assertions would have measured a fixture that does not exist)"
    }
}
