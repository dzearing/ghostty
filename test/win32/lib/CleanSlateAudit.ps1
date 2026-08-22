# CleanSlateAudit.ps1 - the analyzer behind test\win32\cleanslate-audit.ps1 (T351).
#
# THE RULE IT ENFORCES
#
# An acceptance script must not carry its own kill of the app under test or its
# sibling agent. There is exactly one, in lib\CleanSlate.ps1 - `Stop-RepoGhoztty`
# (path-exact, refuses an exe outside the repo) and the full pre-fixture reset
# `Reset-GhozttyTestState` on top of it.
#
# WHY. T248 hoisted the reset and converted 19 scripts; by T351 there were 133
# private copies again, under six different names, with four different filters
# and eight different settle times. Two divergences were live in them:
#
#   * `$_.CommandLine -like '*zig-out*'` also matches a detached instance
#     running from `zig-out-release` (T53b) and kills it. Exact-exe does not.
#   * a copy that killed only `ghoztty.exe` left the agent owning the PTY, so a
#     pane from the previous run survived and `+new-window --target=` FOCUSED it
#     instead of running this run's fixture.
#
# N copies of one datum is N chances to be wrong and no way to notice (T257).
# This analyzer is the way to notice.
#
# WHAT COUNTS AS A FINDING
#
# A `Get-CimInstance Win32_Process` query that names `ghoztty.exe` or
# `ghoztty-agent.exe` and whose pipeline reaches `Stop-Process` within the next
# few lines. Enumerations are NOT findings: plenty of scripts legitimately count
# or inspect processes, and only the KILL is the shared datum.
#
# THE EXEMPTION, AND WHY IT IS A COMMENT RATHER THAN A LIST
#
# Some kills are deliberately different - `agent-adopt.ps1` picks its fake agents
# out by a run marker, `agent-upgrade.ps1` matches `ghoztty-agent%` because the
# image name under test IS `ghoztty-agent.exe.bak`. Those are correct and must
# stay. A central allow-list of file names would go stale silently the moment one
# of them was rewritten; a marker ON the kill cannot, because it is deleted with
# the code it excuses:
#
#     # cleanslate-exempt: matches the t549 fake agents by run marker, not path
#
# within the six lines above the kill. The reason text is required - an empty
# marker is itself a finding, so "exempt" can never become a rubber stamp.

Set-StrictMode -Off

$script:CleanSlateAuditQuery = 'Get-CimInstance\s+Win32_Process'
$script:CleanSlateAuditNames = "ghoztty\.exe|ghoztty-agent\.exe|ghoztty-agent%|ghoztty\.exe'\s+OR"
# The reason is captured, not required by the pattern: a marker with an EMPTY
# reason has to be seen to be reported, and a pattern that demanded `\S` would
# simply not match it - leaving a rubber stamp indistinguishable from no stamp.
$script:CleanSlateAuditMarker = '#\s*cleanslate-exempt\s*:?(.*)$'

# How far a kill's pipeline may run past the query line before we stop looking.
# Six covers the widest real shape in the corpus (query, two Where-Object lines,
# ForEach-Object, Stop-Process, close brace).
$script:CleanSlateAuditWindow = 6

function Get-CleanSlateFindings {
    <#
    .SYNOPSIS
    Private ghoztty kills in one script's text.

    .DESCRIPTION
    -Text takes the script as an array of lines. Returns one object per finding:
    Line (1-based), Kind ('private-kill' or 'empty-exemption'), Text (the query
    line, trimmed).

    The result UNROLLS, deliberately: every call site wraps it in `@(...)`, and a
    `return , @(...)` under that wrap would NEST instead - an empty result would
    then count as one phantom finding and a green sweep would go red for nothing
    (PS 5.1).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text)

    $findings = @()
    for ($i = 0; $i -lt $Text.Count; $i++) {
        $line = $Text[$i]
        if ($line -notmatch $script:CleanSlateAuditQuery) { continue }

        # The query and the few lines under it are one pipeline as far as this
        # rule is concerned - but never PAST the end of the statement it is in.
        # Without the boundary an enumeration that happens to be followed by a
        # kill function reads as a kill itself (`agent-relay-session-e2e.ps1`
        # has exactly that pair), and the audit reports code that is fine.
        $last = [Math]::Min($Text.Count - 1, $i + $script:CleanSlateAuditWindow)
        for ($j = $i + 1; $j -le $last; $j++) {
            if ($Text[$j] -match '^\s*function\s' -or $Text[$j] -match '^\}') { $last = $j - 1; break }
        }
        $forward = ($Text[$i..$last] -join ' ')
        if ($forward -notmatch 'Stop-Process') { continue }

        # The image name is not always on the query line: the commonest copy in
        # the corpus looped `foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe'))`
        # and filtered on `$n`, so the name sits a line or two ABOVE.
        $back = [Math]::Max(0, $i - 3)
        if (($Text[$back..$last] -join ' ') -notmatch $script:CleanSlateAuditNames) { continue }

        # A comment ABOVE the kill excuses it, and must say why.
        $first = [Math]::Max(0, $i - $script:CleanSlateAuditWindow)
        $exempt = $false
        $blank = $false
        foreach ($above in $Text[$first..$i]) {
            if ($above -match $script:CleanSlateAuditMarker) {
                $exempt = $true
                if (-not $matches[1].Trim()) { $blank = $true }
            }
        }
        if ($exempt -and -not $blank) { continue }

        $findings += [pscustomobject]@{
            Line = $i + 1
            Kind = if ($blank) { 'empty-exemption' } else { 'private-kill' }
            Text = $line.Trim()
        }
    }
    return $findings
}

function Get-CleanSlateAuditScripts {
    <#
    .SYNOPSIS
    Every acceptance script the rule applies to: test\win32\*.ps1 plus its lib\.

    .DESCRIPTION
    Three files are excluded, and all three are the rule ITSELF rather than code
    the rule judges: lib\CleanSlate.ps1 (the one shared kill), this analyzer, and
    the acceptance script - the last two only ever mention a kill in prose or in
    a synthesized fixture, and auditing a rule against its own statement is a
    permanent finding that teaches nothing.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $skip = @('CleanSlate.ps1', 'CleanSlateAudit.ps1', 'cleanslate-audit.ps1')
    $files = @(Get-ChildItem -Path $Root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $lib = Join-Path $Root 'lib'
    if (Test-Path $lib) {
        $files += @(Get-ChildItem -Path $lib -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    }
    return ($files | Where-Object { $skip -notcontains $_.Name } | Sort-Object FullName)
}
