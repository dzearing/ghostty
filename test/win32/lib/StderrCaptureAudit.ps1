# StderrCaptureAudit (T883) - find the captures whose TEXT depends on the host
# the script happened to run under.
#
# THE DEFECT, measured. `2>&1` does not merge bytes; it wraps each of a native
# command's stderr lines in an ErrorRecord and puts the OBJECT on the pipeline.
# `Out-String` then FORMATS that object, and formatting is a property of the
# host:
#
#   * in this box's tool session (buffer width 134) one `git --nosuchflag`
#     capture came back 774 characters; the identical call in a consoleless
#     child (width 120) came back 778. Same command, same box, different text -
#     because the NormalView block (`git.exe : `, `At line:1 char:...`,
#     `+ CategoryInfo ...`) is wrapped to the host's width, and a phrase an
#     assert matches on can land across a wrap.
#   * in a host PS 5.1 cannot format for at all, the whole record renders BLANK.
#     That is what T526 measured: 14 stderr-text asserts in `viewer-panes.ps1`
#     silently compared against '' and the suite read as one stale failure.
#
# Stringifying each object FIRST removes the formatter from the path entirely -
# `Out-String` passes plain strings through verbatim (measured: a 300-character
# string survives `Out-String` unwrapped at any width) - so the capture reads
# the same everywhere:
#
#     (& $exe @Args 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
#
# `cmd /c "exe args > file 2>&1"` is the other host-independent shape, and the
# one `cli-unknown-flag.ps1` and `ipc-target-exists-note.ps1` use: bytes on
# disk, written by cmd, with PowerShell never holding an object.
#
# TWO FINDING KINDS.
#
#   * `merged-formatted` - a merging redirection (`2>&1`, `6>&1`, `*>&1`) whose
#     result reaches `Out-String` (or a `Format-*`) with no per-record stringify
#     in between. This is the defect itself and must stay at zero.
#   * `merged-to-file`   - a merging or error stream redirected to a FILE by
#     PowerShell (`*> $log`), which formats through the same host-dependent
#     path on the way to disk (T531 measured a launcher refusal that never
#     reached the file). Reported with a ceiling rather than enforced: most
#     sites in this suite discard to `$null` or never read the file back, and
#     only a human can say which ones are oracles. A redirect to `$null` is not
#     a capture at all and is not reported.
#
# Exemption, narrow and stated: a `# capture-audit: <reason>` marker anywhere in
# the file - the same state-your-intent convention the `# persistence:`,
# `# exitcode-audit:`, `# skip-audit:`, `# verdict-audit:` and
# `# asserted-nothing-audit:` markers use.
#
# Read off the AST rather than the text, because the question is structural: a
# stringify three pipeline elements downstream still fixes the capture, and a
# `2>&1` inside a comment or a here-string is not a capture at all.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

function Get-CaptureAst {
    param([string]$Path, [string[]]$Text)
    $tokens = $null
    $errors = $null
    if ($null -ne $Text) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            ($Text -join "`n"), [ref]$tokens, [ref]$errors)
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)
    }
    return [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

# The formatters whose output is decided by the host. `Out-String` is the one
# this suite reaches for; the `Format-*` family is here because piping a record
# into one and then reading `.Trim()` off it is the same bug wearing a hat.
function Test-CaptureFormatter($CommandAst) {
    $name = $CommandAst.GetCommandName()
    if (-not $name) { return $false }
    return ($name -eq 'Out-String' -or $name -like 'Format-*' -or $name -eq 'oss')
}

# Does this pipeline element turn each object into a string? Both spellings the
# suite uses count: `ForEach-Object { $_.ToString() }` and `... { "$_" }`.
function Test-CaptureStringifier($CommandAst) {
    $name = $CommandAst.GetCommandName()
    if ($name -ne 'ForEach-Object' -and $name -ne '%' -and $name -ne 'foreach') { return $false }
    $t = $CommandAst.Extent.Text
    return ($t -match '\$_\s*\.\s*ToString\s*\(' -or $t -match '"\$_"' -or $t -match '\[string\]\s*\$_')
}

# `2>&1`, `6>&1`, `*>&1` - any stream merged into output. The error stream is
# the one T526 was filed for, but the INFORMATION stream is the same defect with
# a different record type: `Invoke-CacheHeal ... 6>&1 | Out-String` was measured
# wrapping a `CACHE HEAL` line at the host width, breaking a -match on a phrase
# that spans the wrap, while ToString() kept it whole. Any of them is a finding.
function Get-CaptureMergeRedirect($CommandAst) {
    foreach ($r in @($CommandAst.Redirections)) {
        if ($r -is [System.Management.Automation.Language.MergingRedirectionAst]) { return $r }
    }
    return $null
}

# A PowerShell-level redirect to a file. `$null` is a discard, not a capture.
function Get-CaptureFileRedirect($CommandAst) {
    foreach ($r in @($CommandAst.Redirections)) {
        if (-not ($r -is [System.Management.Automation.Language.FileRedirectionAst])) { continue }
        $from = [string]$r.FromStream
        if ($from -ne 'Error' -and $from -ne 'All') { continue }
        $target = $r.Location.Extent.Text.Trim()
        if ($target -eq '$null' -or $target -eq 'nul' -or $target -eq '$Null') { continue }
        return $r
    }
    return $null
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean file.
# `-Text` may be passed instead of `-Path` so the self-test drives it from
# fixtures without writing them to disk.
# ---------------------------------------------------------------------------
function Get-StderrCaptureFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $findings = New-Object System.Collections.ArrayList
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }

    foreach ($l in $lines) { if ($l -match '#\s*capture-audit:') { return $findings } }

    $parsed = Get-CaptureAst -Path $Path -Text $Text
    if ($parsed.Errors.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $parsed.Errors[0].Extent.StartLineNumber
            Kind = 'parse-error'; Detail = $parsed.Errors[0].Message })
        return $findings
    }

    $pipelines = @($parsed.Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.PipelineAst] }, $true))

    foreach ($p in $pipelines) {
        $elements = @($p.PipelineElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $e = $elements[$i]
            if (-not ($e -is [System.Management.Automation.Language.CommandAst])) { continue }

            $file = Get-CaptureFileRedirect $e
            if ($null -ne $file) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $Path; Line = $e.Extent.StartLineNumber; Kind = 'merged-to-file'
                    Detail = "a merged/error stream is formatted on its way to a file: $($file.Extent.Text.Trim())" })
            }

            if ($null -eq (Get-CaptureMergeRedirect $e)) { continue }

            # Walk downstream. A stringify anywhere before the formatter fixes
            # the capture; the FIRST formatter reached without one is the bug.
            for ($j = $i + 1; $j -lt $elements.Count; $j++) {
                $d = $elements[$j]
                if (-not ($d -is [System.Management.Automation.Language.CommandAst])) { continue }
                if (Test-CaptureStringifier $d) { break }
                if (Test-CaptureFormatter $d) {
                    [void]$findings.Add([pscustomobject]@{
                        Path = $Path; Line = $e.Extent.StartLineNumber; Kind = 'merged-formatted'
                        Detail = "a merged stream reaches $($d.GetCommandName()) unstringified: $($p.Extent.Text.Split("`n")[0].Trim())" })
                    break
                }
            }
        }
    }

    return $findings
}

# The kinds that are the defect and must stay at zero. `merged-to-file` is
# reported and counted, not enforced - see the header.
function Get-StderrCaptureHardKinds { return @('merged-formatted', 'parse-error') }

# Sweep the suite. Unlike the verdict audits this DOES read `lib\`: the trap is
# in the capture, not in the verdict, and `lib\BuildMode.ps1` held one of the 56
# sites the T883 sweep converted.
function Get-StderrCaptureSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    $files = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)
    $libDir = Join-Path $Root 'lib'
    if (Test-Path -LiteralPath $libDir) {
        $files += @(Get-ChildItem -LiteralPath $libDir -Filter *.ps1 -File)
    }
    foreach ($f in $files) {
        foreach ($x in @(Get-StderrCaptureFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
