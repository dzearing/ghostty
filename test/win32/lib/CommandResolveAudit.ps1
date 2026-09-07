# CommandResolveAudit (T586) - find the acceptance script that cannot START.
#
# THE DEFECT, measured. `test\win32\chrome-theme.ps1` was checked in on
# 2026-08-07 calling `Test-ExeIsDebugBuild`, a function that exists nowhere in
# this repo. PowerShell resolves a command name at CALL time, so the script
# parsed, ran, and died at line 299 with `The term 'Test-ExeIsDebugBuild' is not
# recognized` - before a single assertion. It sat that way for a week, because
# the only thing that runs an acceptance script is a person deciding to, and a
# script that cannot start and a script nobody ran read exactly alike: silence.
#
# A second one was live in the tree when this audit was written:
# `release-artifacts.ps1` had an if/elseif/else chain pasted twice, so the
# second `} elseif (...) {` parsed as a COMMAND named `elseif`. Zero parse
# errors, a green-looking file, and a run that threw two thirds of the way
# through section B. Neither defect is findable by parsing alone, and both are
# findable by asking the one question below.
#
# THE RULE:
#
#     Every command name an acceptance script names statically must resolve to
#     something: a function it defines, a function in a file it dot-sources, or
#     a cmdlet / alias / program that exists.
#
# WHAT IS AUDITED, AND FROM WHERE. The roots are the top-level
# `test\win32\*.ps1` scripts - the things a turn actually runs. A `lib\*.ps1`
# is NOT a root: a library legitimately calls helpers from its sibling
# libraries, which the consuming SCRIPT dot-sources, so a library read on its
# own would report a dozen names that resolve perfectly in every real run.
# Reading it through its consumers instead asks the question the run asks.
# (The consequence, stated rather than hidden: a library nothing dot-sources is
# not audited at all - `Get-UnreachableAuditLibraries` reports that set so it is
# visible rather than assumed empty.)
#
# HOW A NAME RESOLVES. In order:
#
#   1. a `function` defined anywhere in the file (including inside another
#      function or a scriptblock - the AST is walked fully),
#   2. a function defined in a file the script dot-sources, transitively.
#      Dot-source paths are resolved statically: a bare literal, a
#      `Join-Path $PSScriptRoot 'lib\X.ps1'`, and an expandable
#      `"$Repo\scripts\lib\X.ps1"` are all understood, with `$PSScriptRoot`
#      bound to the dot-sourcING file's directory and `$Repo`/`$repo`/
#      `$RepoRoot`/`$root` bound to the repository,
#   3. a cmdlet, alias, or program the session can see (`Get-Command`), with
#      external programs additionally checked against a fixed list so the
#      verdict does not silently depend on this box's PATH,
#   4. the widening below.
#
# THE WIDENING, and why it is not a hole. Three scripts here load helper
# functions in ways no static resolver can follow: `. $publishDecider` (a
# variable path), `Invoke-Expression $m.Value` (a function extracted from
# another script's TEXT by regex), and `[scriptblock]::Create(...)`. When a file
# does any of those, every `.ps1` path literal it mentions is treated as
# dot-sourced. That is deliberately generous - it can only ADD definitions - and
# it is scoped to the files that actually need it. The alternative was three
# exemption markers, which would have suppressed those files entirely rather
# than half-resolving them.
#
# EXEMPTION: a `# resolve-audit: <reason>` marker anywhere in the file drops it
# from the sweep, the same state-your-intent convention `# persistence:`,
# `# exitcode-audit:`, `# skip-audit:` and `# capture-audit:` already use.
#
# Read off the AST rather than the text, because the question is structural: a
# name inside a comment, a here-string, or a string literal is not a call, and
# `& $exe` and `Get-Command $name` name nothing statically at all.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

# External programs the suite is allowed to name. The list is fixed rather than
# "whatever Get-Command found", because a PATH-dependent answer would make this
# audit green here and red on the build machine for a reason that has nothing to
# do with the code. Anything not here and not resolvable is reported.
$script:CommandResolveKnownExternals = @(
    'cmd', 'cmd.exe', 'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe',
    'git', 'git.exe', 'gh', 'gh.exe', 'zig', 'zig.exe', 'docker', 'docker.exe',
    'tar', 'tar.exe', 'curl', 'curl.exe', 'where.exe', 'cdb', 'cdb.exe',
    'python', 'python.exe', 'py', 'py.exe', 'wsl', 'wsl.exe', 'reg', 'reg.exe',
    'schtasks', 'schtasks.exe', 'taskkill', 'taskkill.exe', 'tasklist',
    'tasklist.exe', 'robocopy', 'robocopy.exe', 'icacls', 'icacls.exe',
    'msiexec', 'msiexec.exe', 'node', 'node.exe', 'npm', 'npm.cmd',
    'ghoztty', 'ghoztty.exe', 'ghoztty-agent', 'ghoztty-agent.exe',
    'attrib', 'attrib.exe', 'findstr', 'findstr.exe', 'ping', 'ping.exe',
    'netstat', 'netstat.exe', 'sc.exe', 'wmic', 'wmic.exe', 'openssl',
    'openssl.exe', 'ssh', 'ssh.exe', 'code', 'code.cmd', 'dotnet', 'dotnet.exe'
)

function Get-CommandResolveExternals {
    @($script:CommandResolveKnownExternals)
}

# Parsing dominates the sweep's cost - 291 roots pull the same twenty libraries
# in over and over - so a file is parsed once per process. Keyed on the full
# path; `Reset-ResolveAuditCache` empties it for a test that edits a file and
# re-reads it in the same session.
$script:ResolveAuditAstCache = @{}

function Reset-ResolveAuditCache {
    $script:ResolveAuditAstCache = @{}
    $script:ResolveAuditFactCache = @{}
}

function Get-ResolveAuditAst {
    param([string]$Path, [string]$Text)
    $tokens = $null
    $errors = $null
    # `-not IsNullOrEmpty` rather than `$null -ne`: an unbound [string] param
    # arrives as '' here, and `ParseInput('')` yields an empty AST that reports
    # zero of everything - which is the shape of an audit that passes because it
    # never looked.
    if (-not [string]::IsNullOrEmpty($Text)) {
        return [System.Management.Automation.Language.Parser]::ParseInput(
            $Text, [ref]$tokens, [ref]$errors)
    }
    $key = $Path.ToLowerInvariant()
    if (-not $script:ResolveAuditAstCache.ContainsKey($key)) {
        $script:ResolveAuditAstCache[$key] =
            [System.Management.Automation.Language.Parser]::ParseFile(
                $Path, [ref]$tokens, [ref]$errors)
    }
    $script:ResolveAuditAstCache[$key]
}

# Turn a dot-source's path EXPRESSION into a path, or $null when it cannot be
# read statically. Handles the three shapes this suite actually writes:
# a literal, `Join-Path <a> <b> [<c>]`, and an expandable string.
function Resolve-ResolveAuditPath {
    param(
        [System.Management.Automation.Language.Ast]$Expr,
        [string]$ScriptDir,
        [string]$Repo
    )

    $expand = {
        param([string]$s)
        if ($null -eq $s) { return $null }
        $s = $s -replace '\$\{?PSScriptRoot\}?', [regex]::Escape($ScriptDir).Replace('\\', '\')
        $s = $s -replace '\$\{?(Repo|repo|RepoRoot|repoRoot|root|Root)\}?', [regex]::Escape($Repo).Replace('\\', '\')
        if ($s -match '\$') { return $null }
        $s
    }

    $node = $Expr
    while ($node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $node = $node.Pipeline
    }
    if ($node -is [System.Management.Automation.Language.PipelineAst] -and
        $node.PipelineElements.Count -eq 1) {
        $node = $node.PipelineElements[0]
    }
    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $node = $node.Expression
    }

    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return (& $expand $node.Value)
    }
    if ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return (& $expand $node.Value)
    }
    if ($node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Join-Path') {
        $parts = @()
        foreach ($el in $node.CommandElements) {
            if ($el -eq $node.CommandElements[0]) { continue }
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $p = Resolve-ResolveAuditPath -Expr $el -ScriptDir $ScriptDir -Repo $Repo
            if (-not $p) { return $null }
            $parts += $p
        }
        if ($parts.Count -eq 0) { return $null }
        return ($parts -join '\')
    }
    $null
}

# What ONE file contributes, read once and remembered: the function names it
# defines, and the files it pulls in. The transitive walk is a separate,
# iterative pass over these facts - 291 roots share the same twenty libraries,
# and re-walking each library's AST per root is what took the sweep from two
# seconds to two minutes on the first cut.
$script:ResolveAuditFactCache = @{}

function Get-ResolveAuditFileFacts {
    param([string]$Path, [string]$Repo)

    $full = $Path
    try { $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { }
    $key = $full.ToLowerInvariant()
    if ($script:ResolveAuditFactCache.ContainsKey($key)) {
        return $script:ResolveAuditFactCache[$key]
    }

    $facts = [pscustomobject]@{
        Path     = $full
        Names    = @()
        Includes = @()
    }
    if (-not (Test-Path -LiteralPath $full)) {
        $script:ResolveAuditFactCache[$key] = $facts
        return $facts
    }

    $ast = Get-ResolveAuditAst -Path $full
    $names = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        ForEach-Object { $_.Name })

    $dir = Split-Path -Parent $full
    $tryPaths = {
        param([string]$p)
        $out = @()
        if ([IO.Path]::IsPathRooted($p)) {
            if (Test-Path -LiteralPath $p) { $out += $p }
        } else {
            foreach ($base in @($dir, $Repo)) {
                $cand = Join-Path $base $p
                if (Test-Path -LiteralPath $cand) { $out += $cand }
            }
        }
        $out
    }

    $includes = @()
    $needsWidening = $false
    foreach ($c in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {

        if ($c.InvocationOperator -eq 'Dot') {
            $p = Resolve-ResolveAuditPath -Expr $c.CommandElements[0] -ScriptDir $dir -Repo $Repo
            if ($p) { $includes += (& $tryPaths $p) }
            else { $needsWidening = $true }
            continue
        }
        $cn = $c.GetCommandName()
        if ($cn -and ($cn -eq 'Invoke-Expression' -or $cn -eq 'iex')) { $needsWidening = $true }
    }
    if ($ast.Extent.Text -match '\[scriptblock\]::Create') { $needsWidening = $true }

    if ($needsWidening) {
        foreach ($s in $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
            if ($s.Value -notlike '*.ps1') { continue }
            $includes += (& $tryPaths $s.Value)
        }
    }

    $facts.Names = @($names)
    $facts.Includes = @($includes)
    $script:ResolveAuditFactCache[$key] = $facts
    $facts
}

# Every function name a file defines, plus every one it inherits by
# dot-sourcing, transitively. $Seen collects the files walked (a cycle
# terminates on it) and is readable afterwards, which is how
# `Get-UnreachableAuditLibraries` learns what the roots reach.
function Get-ResolveAuditDefinitions {
    param(
        [string]$Path,
        [string]$Repo,
        [hashtable]$Seen = @{}
    )

    $names = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Path)
    while ($queue.Count -gt 0) {
        $facts = Get-ResolveAuditFileFacts -Path $queue.Dequeue() -Repo $Repo
        $key = $facts.Path.ToLowerInvariant()
        if ($Seen.ContainsKey($key)) { continue }
        $Seen[$key] = $true
        $names += $facts.Names
        foreach ($inc in $facts.Includes) { $queue.Enqueue($inc) }
    }
    @($names)
}

# Which libraries no root script dot-sources - i.e. which ones this audit never
# looks at. Reported rather than assumed empty.
function Get-UnreachableAuditLibraries {
    param([string]$Repo, [string[]]$Roots)

    $reached = @{}
    foreach ($r in $Roots) {
        $seen = @{}
        Get-ResolveAuditDefinitions -Path $r -Repo $Repo -Seen $seen | Out-Null
        foreach ($k in $seen.Keys) { $reached[$k] = $true }
    }
    $libDir = Join-Path $Repo 'test\win32\lib'
    $out = @()
    foreach ($f in (Get-ChildItem -LiteralPath $libDir -Filter *.ps1 -ErrorAction SilentlyContinue)) {
        if (-not $reached.ContainsKey($f.FullName.ToLowerInvariant())) { $out += $f.Name }
    }
    @($out | Sort-Object)
}

# The analyzer. Returns one object per unresolved call site:
#   File (repo-relative), Line, Name.
function Get-CommandResolveFindings {
    param(
        [string]$Repo,
        [string[]]$Paths,
        [string[]]$ExtraKnown = @(),
        [hashtable]$SessionCache = @{}
    )

    $known = @{}
    foreach ($n in $script:CommandResolveKnownExternals) { $known[$n.ToLowerInvariant()] = $true }
    foreach ($n in $ExtraKnown) { $known[$n.ToLowerInvariant()] = $true }

    $findings = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $ast = Get-ResolveAuditAst -Path $path
        if ($ast.Extent.Text -match '(?m)^\s*#\s*resolve-audit:') { continue }

        $defs = @{}
        foreach ($n in (Get-ResolveAuditDefinitions -Path $path -Repo $Repo -Seen @{})) {
            $defs[$n.ToLowerInvariant()] = $true
        }

        $rel = $path
        if ($path.ToLowerInvariant().StartsWith($Repo.ToLowerInvariant())) {
            $rel = $path.Substring($Repo.Length).TrimStart('\', '/')
        }

        foreach ($c in $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {

            if ($c.InvocationOperator -ne 'Unknown') { continue }
            $name = $c.GetCommandName()
            if (-not $name) { continue }
            # A path, a drive-qualified name, or anything interpolated names
            # nothing statically - `& $exe` and `.\stub.ps1` are not this
            # audit's question.
            if ($name -match '[\$\\/:]') { continue }
            $lower = $name.ToLowerInvariant()
            if ($defs.ContainsKey($lower)) { continue }
            if ($known.ContainsKey($lower)) { continue }

            if (-not $SessionCache.ContainsKey($lower)) {
                $g = Get-Command -Name $name -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                # An Application resolves only through the fixed list above, so
                # this box's PATH cannot make the audit greener than the build
                # machine's.
                $SessionCache[$lower] =
                    ($null -ne $g) -and ($g.CommandType -ne 'Application')
            }
            if ($SessionCache[$lower]) { continue }

            $findings += [pscustomobject]@{
                File = $rel
                Line = $c.Extent.StartLineNumber
                Name = $name
            }
        }
    }
    @($findings)
}
