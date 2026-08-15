# What a Windows delivery CONSISTS of, as pure functions (tracker T198).
#
# The three install locations are the installed release, the Desktop portable
# and the network share; only the first has ever been scripted. The other two
# were re-derived from prose in the session log by whichever session was doing
# the delivery, and T196 is the evidence that costs correctness rather than
# time: a hand-built portable zip exited 0 and was wrong twice over - rooted at
# `Ghoztty-portable-x64\Ghoztty\...` instead of `Ghoztty\...`, and carrying both
# `.pdb` files, doubling a network-share download from 20.3 MB to 41.9 MB.
#
# So the SET of things a delivery ships is written down once, here, as data a
# test can assert on, and `deliver-windows-build.ps1` is the only consumer that
# turns it into file copies. Everything in this file is pure: no filesystem, no
# processes, no network. That is what lets the acceptance script check the rules
# without touching a real install location.

# The files a delivery copies into a portable install directory, in the order a
# reader would expect to see them logged.
#
# -AppOnly is the morning refresh (T525): the app and nothing else. The agent
# outlives the app on purpose, and an agent swapped underneath a portable copy
# would hand the mandatory agent-restart confirmation to whoever launches it
# next - "app-only except over there" is the per-location divergence this repo
# does not ship.
function Get-DeliveryFileSet {
    param([switch]$AppOnly)
    # ghoztty.com is NOT optional (T245): PATHEXT resolves .COM before .EXE, so
    # it is the binary a shell actually runs, and a location that has a fresh
    # .exe beside a stale .com is running last week's CLI.
    $app = @('ghoztty.exe', 'ghoztty.com', 'ghoztty.pdb', 'ghostty-vt.dll')
    if ($AppOnly) { return $app }
    return $app + @('ghoztty-agent.exe', 'ghoztty-agent.pdb', 'ghoztty-agent-ca.dll')
}

# The files whose replaced copy is worth keeping for a rollback. Deliberately
# NOT every delivered file: the two .pdb files are 85 MB and 11 MB, and backing
# them up on every delivery is what grew the Desktop portable directory to 62
# `.bak-*` files. A rollback needs the things you RUN.
function Get-BackupFileSet {
    param([switch]$All)
    if ($All) { return Get-DeliveryFileSet }
    return @('ghoztty.exe', 'ghoztty.com', 'ghostty-vt.dll', 'ghoztty-agent.exe', 'ghoztty-agent-ca.dll')
}

# Does this relative path belong in the portable zip?
#
# The zip is built from an explicit rule rather than from "whatever is in the
# portable directory right now", because what is in the portable directory right
# now includes 62 `.bak-*` files and two `.pdb` files nobody downloads.
function Test-PortableZipIncludes {
    param([AllowEmptyString()][AllowNull()][string]$Relative)
    if (-not $Relative) { return $false }
    $r = $Relative -replace '\\', '/'
    $leaf = $r.Substring($r.LastIndexOf('/') + 1)
    if ($leaf -like '*.pdb') { return $false }
    # `.bak`, `.bak-20260730-t196`, `ghoztty-agent-jul3.exe.bak` - all of them.
    if ($leaf -match '\.bak($|[-.])') { return $false }
    # What a delivery leaves behind when it had to shove a mapped image aside
    # (a portable instance running from the directory it is being delivered to).
    if ($leaf -match '\.locked-') { return $false }
    # A dotfile is refused only at the archive ROOT, where nothing legitimate
    # lives and stray tooling files might. Inside share\ they are SHIPPED
    # CONTENT: `share/ghostty/shell-integration/zsh/.zshenv` is how zsh
    # integration is loaded, and a blanket dotfile rule silently dropped it out
    # of the first archive this script built.
    if ($leaf -like '.*' -and $r -notmatch '/') { return $false }
    return $true
}

# A zip entry name, spelled the way the ZIP spec spells it. .NET Framework's
# ZipFile.CreateFromDirectory writes BACKSLASHES on Windows (fixed only in .NET
# Core), which is why the artifact this replaces has `Ghoztty\share\...` in it.
# We write forward slashes; the comparison below normalises both sides so that
# correction is not reported as a shape change.
function ConvertTo-ZipEntryName {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Relative
    )
    $r = ($Relative -replace '\\', '/').TrimStart('/')
    return "$Root/$r"
}

# The comparable shape of a zip: its FILE entries, normalised. Directory entries
# (trailing slash, zero length) are dropped on both sides - whether a zip writer
# emits them is a property of the writer, not of the artifact's contents, and
# every extractor creates the directories it needs.
function Get-ComparableZipEntries {
    param([AllowNull()][string[]]$Entries)
    if (-not $Entries) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Entries) {
        if (-not $e) { continue }
        $n = $e -replace '\\', '/'
        if ($n.EndsWith('/')) { continue }
        $out.Add($n)
    }
    # Returned WITHOUT the `,` wrap on purpose: every caller here writes
    # `@(Get-ComparableZipEntries ...)`, and `@( ,$array )` is an array of one
    # array, not the array. That nesting is invisible until something iterates
    # it and prints the whole list on one line.
    return ($out.ToArray() | Sort-Object -Unique)
}

# What changed between the artifact being replaced and the one just built.
#
# An entry-set change is the failure T196 shipped twice over: a wrong root prefix
# renames every entry, and stray `.pdb` files add two. Both show up here as
# Added/Removed lists, which is why this is the gate rather than a size check.
function Get-ZipShapeDiff {
    param(
        [AllowNull()][string[]]$Old,
        [AllowNull()][string[]]$New
    )
    $o = @(Get-ComparableZipEntries $Old)
    $n = @(Get-ComparableZipEntries $New)
    $oldSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$o)
    $newSet = New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]$n)
    $added = @($n | Where-Object { -not $oldSet.Contains($_) })
    $removed = @($o | Where-Object { -not $newSet.Contains($_) })
    return @{
        Added    = $added
        Removed  = $removed
        Changed  = (($added.Count + $removed.Count) -gt 0)
        OldCount = $o.Count
        NewCount = $n.Count
    }
}

# The generation stamp of a backup file name, or '' when it carries none.
#
#   ghoztty.exe.bak-20260730-t196  ->  20260730-t196
#   ghoztty.exe.bak                ->  ''            (the oldest convention)
#
# Returns $null for a name that is not a backup at all, so a caller can tell
# "no stamp" from "not mine".
function Get-BackupGeneration {
    param([AllowEmptyString()][AllowNull()][string]$Name)
    if (-not $Name) { return $null }
    if ($Name -match '\.bak-(.+)$') { return $Matches[1] }
    if ($Name -match '\.bak$') { return '' }
    return $null
}

# Which backup files to delete to keep the newest $Keep GENERATIONS.
#
# Grouped by generation rather than by file, so a delivery's five backups live
# and die together - keeping "the newest 3 files" would leave a generation with
# its exe but not its agent, which is not a rollback.
#
# Deleting is never done automatically (a user-gated action); this only says
# what a prune WOULD remove.
function Select-StaleBackups {
    param(
        [AllowNull()][string[]]$Names,
        [int]$Keep = 3
    )
    if (-not $Names) { return @() }
    if ($Keep -lt 0) { $Keep = 0 }
    $baks = @($Names | Where-Object { $null -ne (Get-BackupGeneration $_) })
    if (-not $baks.Count) { return @() }
    # Lexical descending on a `yyyyMMdd-...` stamp IS newest-first, and the
    # stampless `.bak` sorts last, which is where it belongs.
    $gens = @($baks | ForEach-Object { Get-BackupGeneration $_ } | Sort-Object -Unique |
        Sort-Object -Descending)
    if ($gens.Count -le $Keep) { return @() }
    $doomed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($g in ($gens | Select-Object -Skip $Keep)) { $null = $doomed.Add($g) }
    return @($baks | Where-Object { $doomed.Contains((Get-BackupGeneration $_)) } | Sort-Object)
}

# The PE subsystem WORD of a Windows binary: 2 = GUI, 3 = console.
#
# Not pure (it reads the file), but it is a two-field header read with no
# process and no network, and it is the one check that separates a RELEASE
# ghoztty.exe from a Debug one without trusting a version string: debug builds
# link the console subsystem so std.log reaches the shell, release builds link
# GUI (docs/claude/build.md, "Build, run & debug"). Returns 0 when it cannot be read.
function Get-PeSubsystem {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    } catch { return 0 }
    try {
        $head = New-Object byte[] 1024
        $read = $fs.Read($head, 0, 1024)
        if ($read -lt 0x100) { return 0 }
        if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { return 0 }   # MZ
        $peOff = [BitConverter]::ToInt32($head, 0x3C)
        if ($peOff -le 0 -or ($peOff + 0x60) -gt $read) { return 0 }
        if ($head[$peOff] -ne 0x50 -or $head[$peOff + 1] -ne 0x45) { return 0 }  # PE
        return [int][BitConverter]::ToUInt16($head, $peOff + 0x5C)
    } catch { return 0 } finally { $fs.Close() }
}

# What subsystem each shipped binary MUST have. `ghoztty.exe` is the GUI app;
# `ghoztty.com` is the same image with the subsystem WORD flipped to console so
# PowerShell redirects its output (T245). A `ghoztty.exe` that reports console
# is a Debug build, which is how a debug binary reached both portable install
# locations on 2026-08-10 while every log line said the copy succeeded.
function Get-ExpectedSubsystem {
    param([Parameter(Mandatory = $true)][string]$Name)
    switch ($Name) {
        'ghoztty.exe' { return 2 }
        'ghoztty.com' { return 3 }
        default { return 0 }
    }
}
