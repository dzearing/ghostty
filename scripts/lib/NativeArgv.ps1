# Handing text to a native command from PowerShell 5.1, byte-exact (T279).
#
# Dot-source it:
#   . (Join-Path $PSScriptRoot 'lib\NativeArgv.ps1')
#
# --- what is wrong -----------------------------------------------------------
#
# PowerShell 5.1 builds the command line for a native process itself, and its
# builder is not the inverse of the CRT parser every C/C++/Zig program uses to
# split that line back into argv. Measured on box 2026-08-11 with a
# GetCommandLineW oracle, its rule is:
#
#   * an argument is wrapped in `"` only when whitespace appears at a position
#     where an EVEN number of `"` characters precede it, and
#   * an embedded `"` is never escaped - it is copied through raw.
#
# Both halves corrupt text silently, at exit 0:
#
#   sent  --title=a "quoted phrase" mid string
#   got   --title=a quoted   |   phrase mid string        (two arguments)
#
#   sent  --working-directory=C:\my dir\
#   got   --working-directory=C:\my dir"                  (the closing quote ate it)
#
# The live case this was written for: the loop's own relaunch passed
# `--command=claude --dangerously-skip-permissions --continue "read go.md and go"`
# and the child received `--command=claude ... --continue read` plus `go.md`,
# `and`, `go` as three stray positionals - the resume prompt destroyed, nothing
# logged, exit 0.
#
# --- why there is no escaper -------------------------------------------------
#
# An escaper has to know whether PowerShell will wrap, because the escaping
# differs; it can predict that (the parity rule above is a pure function of the
# string). But prediction is not enough. Escaping `"` as `\"` leaves the `"`
# character in place, so it still counts toward PowerShell's parity while the
# CRT no longer treats it as structural. For a string whose first whitespace is
# preceded by an ODD number of quotes - `"a quoted phrase" then more`, an
# entirely ordinary banner or title - PowerShell declines to wrap, the CRT
# splits the argument at the spaces, and no choice of escaping can prevent it:
# the structural open quote we would need adds a second `"` and flips the parity
# back. That is a proof, not a limitation of one attempt.
#
# So do not escape FOR PowerShell's builder. Bypass the builder: compose the
# command line here, to the CRT's own rules, and hand it to CreateProcess
# through ProcessStartInfo.Arguments. That is total, and it fixes every flag of
# every verb at once rather than one `--<field>-file=` at a time.
#
# `+send-keys --keys-file=` stays the transport for a PROMPT: it is unbounded in
# length (a command line is capped at 32767 characters) and its own bytes must
# skip key notation as well as quoting. This is the answer for everything else.

# (No top-level side effects: this file is dot-sourced into other scripts'
# scopes, so a Set-StrictMode or a preference change here would silently retune
# whoever loaded it.)

# One argument, quoted so the CRT parses it back to exactly $Argument.
#
# The rules (they are the CRT's, not ours): backslashes are literal except in a
# run immediately before a `"`, where each must be doubled; a literal `"` is
# written `\"`; and a trailing backslash run must be doubled because the closing
# quote follows it. An argument with no whitespace and no quote needs no wrapper
# at all - and must not get one, since the empty string is the one value whose
# wrapper is load-bearing.
function ConvertTo-NativeArgToken {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Argument)

    if ($null -eq $Argument) { $Argument = '' }
    $special = [char[]]@(' ', "`t", "`n", "`r", [char]11, '"')
    if ($Argument.Length -gt 0 -and $Argument.IndexOfAny($special) -lt 0) { return $Argument }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $i = 0
    while ($i -lt $Argument.Length) {
        $slashes = 0
        while ($i -lt $Argument.Length -and $Argument[$i] -eq '\') { $slashes++; $i++ }
        if ($i -ge $Argument.Length) {
            # A trailing run: the closing quote is next, so double it.
            [void]$sb.Append('\' * ($slashes * 2))
            break
        }
        if ($Argument[$i] -eq '"') {
            [void]$sb.Append('\' * ($slashes * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $slashes)
            [void]$sb.Append($Argument[$i])
        }
        $i++
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# The argument portion of a command line: every element quoted, space-separated.
# The executable is NOT part of this - ProcessStartInfo.FileName carries it, and
# argv[0] is parsed by different rules anyway.
function ConvertTo-NativeCommandLine {
    param([AllowNull()][string[]]$Arguments)

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return '' }
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) { $tokens.Add((ConvertTo-NativeArgToken $a)) }
    return ($tokens -join ' ')
}

# Run a native command with an argument list that arrives BYTE-EXACT.
#
# Returns @{ Code; Out; Err; TimedOut; CommandLine }. Out/Err are captured
# separately (never merged), which is what lets a `--json` reader parse its own
# output. Both pipes are drained concurrently: a child that fills one while we
# block on the other deadlocks, and ghoztty's `+list --json` is easily large
# enough to fill a pipe buffer.
#
# This reaches CreateProcess directly, so it does NOT have the T245/T663
# subsystem problem - a GUI-subsystem `ghoztty.exe` redirects its stdout here
# exactly as the `.com` twin does, because the thing that could not capture it
# was PowerShell's own pipeline, not the OS. Callers may still prefer the `.com`;
# it changes nothing about this path.
function Invoke-NativeExact {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowNull()][string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutMs = 60000
    )

    $line = ConvertTo-NativeCommandLine $Arguments

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $line
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutMs)) {
        $timedOut = $true
        try { $p.Kill() } catch { }
        try { [void]$p.WaitForExit(5000) } catch { }
    }

    $out = ''
    $err = ''
    try { $out = $outTask.Result } catch { }
    try { $err = $errTask.Result } catch { }

    $code = -1
    if (-not $timedOut) { try { $code = $p.ExitCode } catch { $code = -1 } }
    $p.Dispose()

    return @{
        Code        = $code
        Out         = $out
        Err         = $err
        TimedOut    = $timedOut
        CommandLine = $line
    }
}
