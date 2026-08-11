# ExitCodeAudit (T197) - find every `Start-Process -PassThru` whose ExitCode is
# read without the process handle having been cached first.
#
# The trap: PowerShell only keeps a process handle open if something touched
# `$p.Handle` while the process was still alive. Touch it later - after a TIMED
# `WaitForExit(ms)` has already returned - and `$p.ExitCode` reads back EMPTY.
# Every caller that gates on `if ($code -ne 0) { fail }` then scores a WORKING
# CLI as a failure, which is worse than missing a real one: it sends the next
# session hunting a defect that is not there. It cost a whole T147 turn (six
# assertions red against a build whose +list output sat complete in the
# redirect file), and the log had already recorded the same trap once (T145).
#
# WHAT ACTUALLY TRIGGERS IT (measured, T197, PowerShell 5.1.26100): passing
# `-RedirectStandardOutput` / `-RedirectStandardError` to Start-Process. That
# takes the non-ShellExecute path, and the Process object PowerShell hands back
# holds no handle - 8 of 8 uncached reads lost the code. The same call WITHOUT
# a redirect read it back correctly 8 of 8. That is why the trap looked random
# for two turns: most helpers here redirect inside `cmd /c ... > file`, which
# is unaffected, and they sit line-for-line next to the ones that do not.
#
# The rule is still enforced on EVERY site rather than only the redirecting
# ones. A site gains a redirect in a one-word edit, the fix is a single line
# that costs nothing, and "this one is safe for a reason you have to know" is
# exactly the distinction that failed to survive the last two turns.
#
# So the rule is mechanical and checkable rather than remembered:
#
#     $p = Start-Process ... -PassThru
#     $null = $p.Handle          # <- FIRST, before any wait
#     if (-not $p.WaitForExit($ms)) { ... }
#     $p.WaitForExit()
#     return $p.ExitCode
#
# Exemptions, both narrow:
#   * `-Wait` - Start-Process itself holds the handle for the process's whole
#     life, so ExitCode is readable with nothing extra.
#   * a `# exitcode-audit: <reason>` marker on, or in the three lines above,
#     the Start-Process call - the same "state your intent" convention the
#     `# persistence:` markers use.
#
# A site that never reads ExitCode is fine as-is and is not reported: gating on
# the OUTPUT is the preferred shape, not a lesser one.
#
# What this does NOT see, stated so nobody reads a clean sweep as more than it
# is: a Process object RETURNED out of the function that started it and read by
# a caller (the analyzer's window ends at the function). Two such pairs exist
# today and both are safe for their own reason - agent-instance-lineage.ps1
# caches the handle inside `Start-Agent` before returning it, and TestDesktop's
# `Start-OnTestDesktop` does not use Start-Process at all: it comes back from
# `[Process]::GetProcessById`, which opens its own handle and keeps it. If you
# add a third, cache the handle at the Start-Process, where the rule can see it.

# Deliberately sets no StrictMode: this file is dot-sourced INTO other scripts,
# and a mode set here would silently change how every one of them evaluates.

# Collapse backtick line continuations so a multi-line Start-Process reads as
# one logical line. Returns objects carrying the text and its FIRST physical
# line number, so a finding still points at a place a human can open.
function ConvertTo-LogicalLines([string[]]$Lines) {
    $out = New-Object System.Collections.ArrayList
    $buf = ''
    $start = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = ($Lines[$i] -replace '\s+$', '')
        if ($buf -eq '') { $start = $i + 1 }
        if ($t -match '`$') {
            $buf += ($t -replace '`$', '') + ' '
            continue
        }
        $buf += $t
        [void]$out.Add([pscustomobject]@{ Text = $buf; Line = $start })
        $buf = ''
    }
    if ($buf -ne '') { [void]$out.Add([pscustomobject]@{ Text = $buf; Line = $start }) }
    return $out
}

# The analyzer. Returns one object per VIOLATION; an empty result is a clean
# file. `$Text` may be passed instead of a path so the self-test can drive it
# from fixtures without writing them to disk.
function Get-ExitCodeAuditFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }
    $logical = @(ConvertTo-LogicalLines $lines)
    $findings = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $logical.Count; $i++) {
        $line = $logical[$i].Text
        # Comment lines never start a process.
        if ($line -match '^\s*#') { continue }
        if ($line -notmatch '^\s*\$([A-Za-z_][\w:]*)\s*=\s*Start-Process\b') { continue }
        $var = $Matches[1]
        if ($line -notmatch '-PassThru') { continue }
        # -Wait keeps the handle open for us.
        if ($line -match '-Wait\b') { continue }
        # Explicit marker, on the call or within the three lines above it.
        $markerFrom = [Math]::Max(0, $i - 3)
        $marked = $false
        for ($m = $markerFrom; $m -le $i; $m++) {
            if ($logical[$m].Text -match '#\s*exitcode-audit:') { $marked = $true; break }
        }
        if ($marked) { continue }

        # Walk forward collecting member touches on this variable, in order,
        # until the variable is reassigned or the file ends.
        $rx = [regex]("\`$" + [regex]::Escape($var) + "\.([A-Za-z]+)")
        $reassign = [regex]("^\s*\`$" + [regex]::Escape($var) + "\s*=")
        $handleAt = -1
        $gateAt = -1
        $gateName = ''
        $exitLine = 0
        for ($j = $i; $j -lt $logical.Count; $j++) {
            $t = $logical[$j].Text
            if ($j -gt $i -and $reassign.IsMatch($t)) { break }
            if ($t -match '^\s*#') { continue }
            foreach ($mm in $rx.Matches($t)) {
                $member = $mm.Groups[1].Value
                if ($member -eq 'Handle' -and $handleAt -lt 0) { $handleAt = $j }
                if ($gateAt -lt 0 -and @('ExitCode', 'WaitForExit', 'HasExited') -contains $member) {
                    $gateAt = $j
                    $gateName = $member
                }
                if ($member -eq 'ExitCode' -and $exitLine -eq 0) { $exitLine = $logical[$j].Line }
            }
        }

        if ($exitLine -eq 0) { continue }   # output-gated: nothing to get wrong
        if ($handleAt -ge 0 -and ($gateAt -lt 0 -or $handleAt -le $gateAt)) { continue }

        $reason = if ($handleAt -lt 0) {
            "handle never cached"
        } else {
            "handle cached at line $($logical[$handleAt].Line), after .$gateName at line $($logical[$gateAt].Line)"
        }
        [void]$findings.Add([pscustomobject]@{
            Path     = $Path
            Line     = $logical[$i].Line
            Variable = "`$$var"
            ExitLine = $exitLine
            Reason   = $reason
        })
    }
    return $findings
}

# Sweep a directory tree of .ps1 files. Returns every finding, flattened.
function Get-ExitCodeAuditSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File)) {
        foreach ($x in @(Get-ExitCodeAuditFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
