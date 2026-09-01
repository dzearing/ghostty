# msi-test-identity.ps1 - T1194. Turn a PUBLISHED Ghoztty MSI into a throwaway
# product that installs beside the user's Ghoztty instead of over it.
#
# WHY THIS EXISTS. T1178 built the whole in-app update path and could not test
# its last inch: msiexec SUCCEEDING. A real published `Ghoztty-<v>-x64.msi`
# carries the real ProductCode and the real UpgradeCode, so installing one is a
# major upgrade of the user's daily-driver terminal - this repo's first
# non-negotiable. dist/windows-installer/build-msi.sh already knows the answer
# (`--test-identity`, which T23's harness uses), but that path REBUILDS the
# package with wixl, i.e. Linux and therefore Docker, and what came out would no
# longer be the bytes that were published.
#
# So the isolation is applied to the published package instead of to a rebuild
# of it. Everything that decides WHERE the product lands and WHAT it is called
# is rewritten - and nothing else is. The payload, the File/Media tables, the
# cabinet, the sequences and the custom actions are the published ones, which is
# the whole point: the thing under test is the update, and the update's subject
# has to be a real release.
#
# WHAT IS REWRITTEN, and why each one is load-bearing:
#
#   Property.ProductCode    a distinct product, so `/i` installs rather than
#                           upgrading the user's.
#   Property.UpgradeCode    ... and RemoveExistingProducts never sees theirs.
#   Upgrade.UpgradeCode     the same code in the table that DRIVES the major
#                           upgrade. A row still naming the real code would
#                           uninstall the user's terminal to make room for a
#                           test.
#   Property.ProductName    what Apps & Features shows.
#   Directory INSTALLDIR    %LOCALAPPDATA%\Programs\<Identity>, not \Ghoztty.
#   Component.ComponentId   ALL of them, remapped. Two products installing the
#                           SAME component GUID to DIFFERENT paths is the
#                           classic component-rules violation: Windows keeps one
#                           refcounted key path per GUID, so uninstalling the
#                           test product could take the user's files with it.
#   Registry.Key            Software\dzearing\<Identity>.
#   Shortcut.Name           so the Start Menu keeps one "Ghoztty" entry.
#   PackageCode             a rewritten package is a different package, and the
#                           installer cache is keyed on this.
#
# The new GUIDs are DERIVED (sha1 over the identity plus a seed, in the
# RFC-4122 v5 shape), never random: re-running this on the same input produces
# the same product, so a cleanup written today still matches a package built
# last week and a leaked install is always uninstallable.
#
# Acceptance: test\win32\update-real-msi.ps1, which installs the result.
param(
    [Parameter(Mandatory = $true)][string]$Msi,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Identity = 'GhozttyT1194Test',
    # Mint a SYNTHETIC PREDECESSOR of the package being rewritten (T1209): the
    # same payload, registered at a lower ProductVersion, so a harness can
    # install it and then let the published package upgrade it for real.
    #
    # This exists because the two newest published releases are not
    # interchangeable subjects. An upgrade is only graceful when the build being
    # REPLACED knows how to be closed by an installer, and that landed in
    # win-v1.36.0 - so measuring the graceful route against win-v1.35.0 measures
    # a build that predates it. One published package on both sides, with the
    # version moved underneath the older copy, keeps the payload honest and the
    # question answerable.
    #
    # Lower, never higher: the package's own OLDERVERSIONFOUND row carries
    # `VersionMax = <this package's version>` with the max NOT inclusive, so a
    # bumped-up copy would fail to detect the installed product and install
    # BESIDE it - a side-by-side pair that passes every version check while
    # testing the opposite of an upgrade.
    [string]$ProductVersion = ''
)
$ErrorActionPreference = 'Stop'

# msiViewModify* / msiOpenDatabaseMode* constants, named rather than magic.
$MODIFY_REPLACE = 4
$OPEN_TRANSACT = 1

# Joins the parts of a composite primary key into one dictionary key. U+0001
# cannot appear in an MSI identifier. (`u{1} is not an escape in PowerShell
# 5.1 - it renders literally - so the character is built, not written.)
$KEY_SEP = [string][char]1

# Tables the snapshot cannot read as text (streams and binaries), plus Upgrade,
# whose rows deliberately change primary key here and so have no stable
# identity to diff against. Upgrade is verified on its own at the bottom.
$skipTables = @('Binary', 'Icon', '_Streams', '_Storages', 'MsiDigitalCertificate',
    'MsiDigitalSignature', 'MsiPatchCertificate', 'Upgrade')

# The cells this script is ALLOWED to change, as "<table>|<column>". Anything
# else that moved between the published package and the finished one is
# collateral damage from the string-pool defect Get-DatabaseSnapshot describes,
# and gets written back.
$intendedCells = @(
    'Property|Value',
    'Directory|DefaultDir',
    'Component|ComponentId',
    'Registry|Key',
    'Shortcut|Name'
)

function New-DerivedGuid {
    <#
    An RFC-4122 v5 (sha1) UUID over "<identity>|<seed>". Deterministic, so the
    same identity always produces the same product; distinct per seed, so N
    components stay N distinct components.
    #>
    param([string]$Identity, [string]$Seed)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Identity|$Seed"))
    } finally { $sha.Dispose() }
    $b = $bytes[0..15]
    # Version 5, RFC-4122 variant.
    $b[6] = [byte](($b[6] -band 0x0F) -bor 0x50)
    $b[8] = [byte](($b[8] -band 0x3F) -bor 0x80)
    $hex = ($b | ForEach-Object { $_.ToString('x2') }) -join ''
    $g = '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4),
        $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
    return '{' + $g.ToUpperInvariant() + '}'
}

if (-not (Test-Path -LiteralPath $Msi)) { throw "source package not found: $Msi" }
$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
}
Copy-Item -LiteralPath $Msi -Destination $Out -Force

$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $null

function Open-MsiDb {
    <# One EDIT SESSION. See Close-MsiDb for why there is more than one. #>
    $script:db = $installer.OpenDatabase($Out, $OPEN_TRANSACT)
}

function Close-MsiDb {
    <#
    Commit and let go of the handle completely.

    There is a session boundary in the middle of this script because MSI's
    writer RENUMBERS THE STRING POOL when a row is structurally added, removed
    or re-keyed, and cells written earlier in the SAME session keep the old
    numbers. Measured on the published 1.35.0 package: re-keying the two
    Upgrade rows emptied `Property.UpgradeCode`, and a delete-then-insert of
    those same rows left ProductCode reading "OLDERVERSIONFOUND" and
    ProductVersion reading "0.0.0" - Upgrade values, in the Property table,
    from statements that never named it. Doing the structural edit in its own
    session and every column rewrite in the next one keeps the two apart, and
    the verification pass at the bottom is what proves it stayed that way.
    #>
    [void]$script:db.Commit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($script:db)
    $script:db = $null
    [void][System.GC]::Collect()
    [void][System.GC]::WaitForPendingFinalizers()
}

# Every COM call below is [void]-cast. These are IDispatch methods and several
# return a value PowerShell would otherwise fold into the enclosing function's
# output: a `return $out` next to a bare `$v.Close()` hands the caller an ARRAY
# whose extra element is that value, and interpolating it yields "  Ghoztty".
# Every view is also explicitly released - PowerShell holds the RCW until a GC
# that never comes, and a few hundred live MSI handles take the process down
# with an AccessViolation on whatever call happens to be next.

function Get-MsiRows {
    <#
    Every row of $Sql as a string[] of $Fields columns.

    `Write-Output -NoEnumerate` rather than `return`: PowerShell unrolls a
    collection on its way out of a function, so a two-row result would arrive
    as two separate values and a one-row result as a bare string[] whose [0] is
    a CHARACTER. Both shapes look like data right up to the point where a GUID
    turns into "{".
    #>
    param([string]$Sql, [int]$Fields)
    $v = $db.OpenView($Sql)
    [void]$v.Execute()
    $rows = New-Object System.Collections.ArrayList
    while ($true) {
        $r = $v.Fetch()
        if ($null -eq $r) { break }
        $vals = New-Object string[] $Fields
        for ($i = 1; $i -le $Fields; $i++) { $vals[$i - 1] = [string]$r.StringData($i) }
        [void]$rows.Add($vals)
    }
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    Write-Output -NoEnumerate $rows.ToArray()
}

function Get-MsiValue {
    <# The single cell a one-row, one-column SELECT returns. #>
    param([string]$Sql)
    $v = $db.OpenView($Sql)
    [void]$v.Execute()
    $r = $v.Fetch()
    if ($null -eq $r) { [void]$v.Close(); throw "no row for: $Sql" }
    $out = [string]$r.StringData(1)
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    return $out
}

function Update-MsiColumn {
    <#
    Rewrite one column of every row of $Table, keyed on $KeyColumn.

    READ EVERYTHING FIRST, then write. The obvious shape - fetch a row, poke
    the record, Modify(msiViewModifyUpdate), fetch the next - silently CORRUPTS
    the table: the update re-sorts the view under the cursor, so rows are
    skipped, and this repo has the evidence (a first cut of this script visited
    one of the three Registry rows and blanked the other two). A parameterised
    `UPDATE ... SET c=? WHERE k=?` per changed row touches exactly the row
    named and cannot disturb an enumeration, because the enumeration is over.

    Parameters rather than literals because MSI SQL refuses a literal
    assignment to a long-text column - `Property`.`Value` is one - and `?` is
    what it accepts everywhere.

    $Rewrite receives the current value and the whole row (string[]) and
    returns the new value, or $null to leave the row alone.
    #>
    param(
        [string]$Table,
        [string[]]$Columns,
        [string]$KeyColumn,
        [string]$Column,
        [scriptblock]$Rewrite,
        [string]$Where = ''
    )
    $select = "SELECT " + (Get-ColumnList $Columns) + " FROM ``$Table``"
    if ($Where) { $select += " WHERE $Where" }
    $rows = Get-MsiRows $select $Columns.Count
    $keyIdx = [Array]::IndexOf($Columns, $KeyColumn)
    $colIdx = [Array]::IndexOf($Columns, $Column)
    if ($keyIdx -lt 0 -or $colIdx -lt 0) { throw "column not in select list: $KeyColumn / $Column" }

    # ONE view, re-executed per row. Opening a view per row leaks an MSI handle
    # each time; several hundred of those took the process down mid-Commit,
    # which read exactly like a corrupt package.
    $changed = 0
    $u = $db.OpenView("UPDATE ``$Table`` SET ``$Column``=? WHERE ``$KeyColumn``=?")
    try {
        foreach ($row in $rows) {
            $new = & $Rewrite $row[$colIdx] $row
            if ($null -eq $new -or $new -eq $row[$colIdx]) { continue }
            $rec = $installer.CreateRecord(2)
            $rec.StringData(1) = $new
            $rec.StringData(2) = $row[$keyIdx]
            [void]$u.Execute($rec)
            [void]$u.Close()
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
            $changed++
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($u)
    }
    return $changed
}

function Get-TableNames {
    $names = @()
    foreach ($row in (Get-MsiRows "SELECT ``Name`` FROM ``_Tables``" 1)) { $names += $row[0] }
    return ($names | Sort-Object)
}

function Get-TableColumns {
    param([string]$Table)
    $cols = @()
    foreach ($row in (Get-MsiRows "SELECT ``Number``,``Name`` FROM ``_Columns`` WHERE ``Table``='$Table'" 2)) {
        $cols += , @([int]$row[0], $row[1])
    }
    $out = @()
    foreach ($c in ($cols | Sort-Object { $_[0] })) { $out += $c[1] }
    return $out
}

function Get-PrimaryKeyColumns {
    param([string]$Table)
    $rec = $db.PrimaryKeys($Table)
    $keys = @()
    for ($i = 1; $i -le 8; $i++) {
        $s = try { [string]$rec.StringData($i) } catch { '' }
        if ($s -eq '') { break }
        $keys += $s
    }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
    return $keys
}

function Get-DatabaseSnapshot {
    <#
    Every cell of every table, keyed by primary key, so the finished package
    can be DIFFED against the published one.

    This is not belt-and-braces; it is the repair pass, and it exists because
    of a real defect in the packages wixl produces. MSI stores strings in a
    refcounted pool, and wixl's refcounts do not account for every use: when
    the last count it knows about is replaced, the writer FREES a string other
    tables still reference, and those cells silently read back empty. Measured
    here: "Ghoztty" is ProductName, INSTALLDIR's name, the Start Menu shortcut
    name AND the one Feature's name. Rewriting the first three blanked
    `Feature`.`Feature` and all 578 `FeatureComponents` rows - the install
    still succeeded, and every later maintenance operation failed with "Error
    2711: the specified Feature name ('') not found in Feature Table". An
    upgrade that cannot run is exactly what this package exists to test.
    #>
    $snap = @{}
    foreach ($t in (Get-TableNames)) {
        if ($skipTables -contains $t) { continue }
        # @(...) around both: a function that returns a ONE-element array has
        # it unrolled to a bare string on the way out, and `$pk[0]` then reads
        # the first CHARACTER - which produced `WHERE `F`=?` for the Feature
        # table and an OpenView that would not parse.
        $cols = @(Get-TableColumns $t)
        if ($cols.Count -eq 0) { continue }
        $pk = @(Get-PrimaryKeyColumns $t)
        if ($pk.Count -eq 0) { continue }
        $rows = Get-MsiRows ("SELECT " + (Get-ColumnList $cols) + " FROM ``$t``") $cols.Count
        $byKey = @{}
        foreach ($row in $rows) {
            $keyParts = @()
            foreach ($k in $pk) { $keyParts += $row[[Array]::IndexOf($cols, $k)] }
            $byKey[($keyParts -join $KEY_SEP)] = $row
        }
        $snap[$t] = @{ Columns = [string[]]$cols; Pk = [string[]]$pk; Rows = $byKey }
    }
    return $snap
}

function Restore-DamagedKeys {
    <#
    Put back the rows whose PRIMARY KEY was blanked, and return how many.

    The defect, measured on the published 1.35.0 package and reduced to one
    statement: changing `Property`.`Value` for ProductName - one cell, nothing
    else - blanks `Feature`.`Feature`, `Feature`.`Title` and the `Feature_`
    column of all 578 `FeatureComponents` rows. MSI's string pool is
    refcounted and wixl records a count of 1 for "Ghoztty", which is also the
    feature's name, the install directory's name and the Start Menu shortcut's
    name. Replacing the count it knows about frees the string, and every other
    cell pointing at it reads back empty.

    The install still succeeds that way, which is what makes it dangerous: it
    is the UPGRADE and the UNINSTALL that then fail, with "Error 2711: The
    specified Feature name ('') not found in Feature Table" - and an upgrade
    that cannot run is precisely what a package built to test the updater must
    be able to do.

    A blanked cell that is a primary key cannot be repaired by an UPDATE, so
    the row is re-keyed with msiViewModifyReplace, taking every column from
    the snapshot. Damaged rows are recognised by shape rather than by a list
    of table names: a snapshot key with no row in the current table, matched
    to the single current row whose key agrees on every part that is not
    empty.
    #>
    param($Snapshot)
    $restored = 0
    foreach ($t in $Snapshot.Keys) {
        $b = $Snapshot[$t]
        $current = Get-MsiRows ("SELECT " + (Get-ColumnList $b.Columns) + " FROM ``$t``") $b.Columns.Count
        $currentKeys = @{}
        foreach ($row in $current) {
            $parts = @()
            foreach ($k in $b.Pk) { $parts += $row[[Array]::IndexOf($b.Columns, $k)] }
            $currentKeys[($parts -join $KEY_SEP)] = $row
        }
        foreach ($key in $b.Rows.Keys) {
            if ($currentKeys.ContainsKey($key)) { continue }
            $want = $key -split $KEY_SEP
            # The damaged row: same key except where a part went empty.
            $candidates = @()
            foreach ($haveKey in $currentKeys.Keys) {
                $have = $haveKey -split $KEY_SEP
                if ($have.Count -ne $want.Count) { continue }
                $blanks = 0
                $ok = $true
                for ($i = 0; $i -lt $want.Count; $i++) {
                    if ($have[$i] -eq $want[$i]) { continue }
                    if ($have[$i] -eq '') { $blanks++; continue }
                    $ok = $false; break
                }
                if ($ok -and $blanks -gt 0) { $candidates += $haveKey }
            }
            if ($candidates.Count -ne 1) { continue }

            $bRow = $b.Rows[$key]
            $damaged = $candidates[0] -split $KEY_SEP

            # The WHERE is built only from the key parts that SURVIVED. An
            # empty parameter is NULL to MSI SQL and matches nothing, so a
            # `WHERE `Feature`=?` bound to '' would fetch no row and silently
            # repair nothing - which is exactly what it did. For
            # FeatureComponents the surviving Component_ still identifies one
            # row; for the single-row Feature table nothing survives and the
            # whole table is the candidate set.
            $where = @()
            $bound = @()
            for ($i = 0; $i -lt $b.Pk.Count; $i++) {
                if ($damaged[$i] -eq '') { continue }
                $where += "``" + $b.Pk[$i] + "``=?"
                $bound += $damaged[$i]
            }
            $sql = "SELECT " + (Get-ColumnList $b.Columns) + " FROM ``$t``"
            if ($where.Count -gt 0) { $sql += " WHERE " + ($where -join ' AND ') }
            $v = try { $db.OpenView($sql) } catch { throw "OpenView failed for $t : $sql" }
            if ($bound.Count -gt 0) {
                $sel = $installer.CreateRecord($bound.Count)
                for ($i = 0; $i -lt $bound.Count; $i++) { $sel.StringData($i + 1) = $bound[$i] }
                [void]$v.Execute($sel)
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sel)
            } else {
                [void]$v.Execute()
            }
            while ($true) {
                $r = $v.Fetch()
                if ($null -eq $r) { break }
                $haveParts = @()
                foreach ($k in $b.Pk) { $haveParts += [string]$r.StringData(1 + [Array]::IndexOf($b.Columns, $k)) }
                if (($haveParts -join $KEY_SEP) -ne $candidates[0]) { continue }
                for ($c = 1; $c -le $b.Columns.Count; $c++) {
                    if ($bRow[$c - 1] -ne '') { $r.StringData($c) = $bRow[$c - 1] }
                }
                [void]$v.Modify($MODIFY_REPLACE, $r)
                $restored++
                break
            }
            [void]$v.Close()
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
        }
    }
    return $restored
}

function Get-ColumnList {
    <#
    `A`,`B`,`C` for an MSI SELECT. The separator is SINGLE-quoted on purpose:
    PowerShell collapses a doubled backtick inside double quotes and leaves it
    alone inside single quotes, so the double-quoted form silently produces two
    backticks per column and OpenView answers "OpenView,Sql".
    #>
    param([string[]]$Columns)
    return '`' + ($Columns -join '`,`') + '`'
}

# ---------------------------------------------------------------- identity
Open-MsiDb

$oldProduct = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductCode'"
$oldUpgrade = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='UpgradeCode'"
$oldName = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductName'"
$sourceVersion = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'"
$version = if ($ProductVersion) { $ProductVersion } else { $sourceVersion }
if ($ProductVersion -and ([version]$ProductVersion -ge [version]$sourceVersion)) {
    # Closed and deleted the way a verification failure is: a half-written $Out
    # carrying the real UpgradeCode is the artifact nobody may be handed.
    Close-MsiDb
    Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue
    throw ("-ProductVersion $ProductVersion is not BELOW the package's own $sourceVersion " +
        '(package deleted). See the parameter comment: a raised version installs beside ' +
        'the product it should have replaced.')
}

# The Upgrade table's version BOUNDS, captured before any write. They are not
# covered by the snapshot/repair machinery - `Upgrade` is in $skipTables,
# because its rows deliberately change primary key here - and they share their
# string pool entries with `Property.ProductVersion`, so a write to one can
# blank the others. Session 4 puts them back.
$upgradeBounds = @{}
foreach ($row in (Get-MsiRows "SELECT ``ActionProperty``,``VersionMin``,``VersionMax`` FROM ``Upgrade``" 3)) {
    # A bound spelled with the source's own version follows the version: this
    # package IS $version now, so "older than me" and "newer than me" have to
    # move with it. Anything else is left exactly as published.
    $vmin = if ($row[1] -eq $sourceVersion) { $version } else { $row[1] }
    $vmax = if ($row[2] -eq $sourceVersion) { $version } else { $row[2] }
    $upgradeBounds[$row[0]] = @($vmin, $vmax)
}

$newProduct = New-DerivedGuid -Identity $Identity -Seed "productcode::$version"
$newUpgrade = New-DerivedGuid -Identity $Identity -Seed 'upgradecode'
$newPackage = New-DerivedGuid -Identity $Identity -Seed "packagecode::$version"

Write-Host "  source      : $Msi"
Write-Host "  identity    : $Identity (was $oldName)"
Write-Host "  version     : $version$(if ($ProductVersion) { " (was $sourceVersion)" })"
Write-Host "  ProductCode : $oldProduct -> $newProduct"
Write-Host "  UpgradeCode : $oldUpgrade -> $newUpgrade"

# Read the published package in full BEFORE touching it. Everything after this
# is diffed against it.
$before = Get-DatabaseSnapshot
$beforeCells = 0
foreach ($t in $before.Keys) { $beforeCells += $before[$t].Rows.Count * $before[$t].Columns.Count }
Write-Host "  snapshot    : $($before.Keys.Count) tables, $beforeCells cells"

# ------------------------------------------ session 1a: the Upgrade table
#
# The STRUCTURAL edit, alone in its session (Close-MsiDb says why), and the
# most important write in the file.
#
# UpgradeCode is part of the primary key, which msiViewModifyUpdate cannot
# touch. msiViewModifyReplace can, and unlike a delete-then-insert it leaves
# the row count alone. One fresh view per row, selected by its ActionProperty,
# so nothing is ever modified underneath an open cursor.
$upgradeCols = @('UpgradeCode', 'VersionMin', 'VersionMax', 'Language', 'Attributes', 'Remove', 'ActionProperty')
$upgradeColList = Get-ColumnList $upgradeCols
# NOTE, and it applies to every Get-MsiRows caller in this file: the result is
# a non-enumerating string[][]. PIPING it hands the pipeline ONE object - the
# whole table - so `| ForEach-Object { $_[0] }` yields a single row rather than
# a column, and the loop below silently re-keyed one Upgrade row out of two.
# Always `foreach` over it or index it; never pipe it.
$actionRows = Get-MsiRows "SELECT ``ActionProperty`` FROM ``Upgrade``" 1
$actionProps = @()
foreach ($row in $actionRows) { $actionProps += $row[0] }
$upgraded = 0
foreach ($ap in $actionProps) {
    $v = $db.OpenView("SELECT $upgradeColList FROM ``Upgrade`` WHERE ``ActionProperty``='$ap'")
    [void]$v.Execute()
    $r = $v.Fetch()
    if ($null -ne $r) {
        $r.StringData(1) = $newUpgrade
        [void]$v.Modify($MODIFY_REPLACE, $r)
        $upgraded++
    }
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
}
Write-Host "  Upgrade     : $upgraded row(s) re-keyed"

Close-MsiDb

# ------------------------------------------ session 1b: every column rewrite
#
# Property is rewritten HERE, after the Upgrade edit that would otherwise have
# clobbered it. Each of the writes below sets its cell EXPLICITLY from the
# value this script computed, never by editing what it reads back - which
# matters, because the first write to a shared string blanks the others (see
# Restore-DamagedKeys) and a read-modify-write would then propagate a blank.
Open-MsiDb

$propMap = @{
    'ProductCode' = $newProduct
    'UpgradeCode' = $newUpgrade
    'ProductName' = $Identity
}
# Only when asked. Writing the value it already holds would be a no-op in the
# database and a lie in the "N rewritten" count.
if ($ProductVersion) { $propMap['ProductVersion'] = $version }
$propChanged = Update-MsiColumn -Table 'Property' -Columns @('Property', 'Value') `
    -KeyColumn 'Property' -Column 'Value' -Rewrite {
    param($cur, $row)
    if ($propMap.ContainsKey($row[0])) { $propMap[$row[0]] } else { $null }
}
Write-Host "  Property    : $propChanged rewritten"

# The install directory. INSTALLDIR's DefaultDir is the folder name under
# %LOCALAPPDATA%\Programs; wixl emits a plain long name for this package, but a
# "SHORT|Long" pair is legal MSI, so only the long half is replaced.
$dirChanged = Update-MsiColumn -Table 'Directory' -Columns @('Directory', 'DefaultDir') `
    -KeyColumn 'Directory' -Column 'DefaultDir' -Where "``Directory``='INSTALLDIR'" -Rewrite {
    param($cur, $row)
    if ($cur -match '\|') { ($cur -split '\|', 2)[0] + '|' + $Identity } else { $Identity }
}
Write-Host "  INSTALLDIR  : $dirChanged row(s) -> $Identity"

# Every component GUID. See the header: this is what keeps the two products
# from sharing refcounted key paths.
$compChanged = Update-MsiColumn -Table 'Component' -Columns @('Component', 'ComponentId') `
    -KeyColumn 'Component' -Column 'ComponentId' -Rewrite {
    param($cur, $row)
    if ([string]::IsNullOrEmpty($cur)) { return $null }
    New-DerivedGuid -Identity $Identity -Seed ("component::" + $row[0])
}
Write-Host "  Component   : $compChanged GUID(s) remapped"

# Registry keys, so the two products do not write each other's InstallDir.
$regChanged = Update-MsiColumn -Table 'Registry' -Columns @('Registry', 'Key') `
    -KeyColumn 'Registry' -Column 'Key' -Rewrite {
    param($cur, $row)
    if ([string]::IsNullOrEmpty($cur)) { return $null }
    $cur -replace ([regex]::Escape("\$oldName") + '$'), "\$Identity"
}
Write-Host "  Registry    : $regChanged key(s) rewritten"

# The Start Menu shortcut, so the user keeps exactly one "Ghoztty" entry.
$scChanged = Update-MsiColumn -Table 'Shortcut' -Columns @('Shortcut', 'Name') `
    -KeyColumn 'Shortcut' -Column 'Name' -Rewrite {
    param($cur, $row)
    if ($cur -match '\|') { ($cur -split '\|', 2)[0] + '|' + $Identity } else { $Identity }
}
Write-Host "  Shortcut    : $scChanged renamed"

Close-MsiDb

# ------------------------------------------ session 2: put the keys back
#
# Its own session, after every write that can free a shared string, so nothing
# it restores is freed again behind it.
Open-MsiDb
$keysRestored = Restore-DamagedKeys $before
Write-Host "  keys        : $keysRestored row(s) re-keyed after a freed string"
Close-MsiDb

# --------------------------------------------- session 3: the repair pass
#
# Diff the whole database against the published one and write back every cell
# that moved without being asked to. Iterated, because a repair is itself a
# write and can free another shared string; three passes have always been
# enough, and running out of passes is a failure rather than a shrug.
Open-MsiDb
$repairedTotal = 0
for ($pass = 1; $pass -le 3; $pass++) {
    $after = Get-DatabaseSnapshot
    $repaired = 0
    $unrepairable = @()
    foreach ($t in $before.Keys) {
        $b = $before[$t]
        $a = $after[$t]
        if ($null -eq $a) { $unrepairable += "$t (table vanished)"; continue }
        $upd = $null
        foreach ($key in $b.Rows.Keys) {
            $bRow = $b.Rows[$key]
            $aRow = $a.Rows[$key]
            if ($null -eq $aRow) { $unrepairable += "$t[$key] (row vanished)"; continue }
            for ($c = 0; $c -lt $b.Columns.Count; $c++) {
                $col = $b.Columns[$c]
                if ($bRow[$c] -eq $aRow[$c]) { continue }
                if ($intendedCells -contains "$t|$col") { continue }
                if ($b.Pk -contains $col) { $unrepairable += "$t[$key].$col (primary key)"; continue }
                if ($null -eq $upd) { $upd = @() }
                $upd += , @($key, $col, $bRow[$c])
            }
        }
        if ($null -eq $upd) { continue }
        # One row is addressed by its full primary key, which may be several
        # columns - hence a WHERE built from the key rather than a single `?`.
        foreach ($fix in $upd) {
            $keyParts = $fix[0] -split $KEY_SEP
            $where = @()
            for ($k = 0; $k -lt $b.Pk.Count; $k++) {
                $where += "``" + $b.Pk[$k] + "``=?"
            }
            $v = $db.OpenView("UPDATE ``$t`` SET ``$($fix[1])``=? WHERE " + ($where -join ' AND '))
            $rec = $installer.CreateRecord(1 + $b.Pk.Count)
            $rec.StringData(1) = $fix[2]
            for ($k = 0; $k -lt $b.Pk.Count; $k++) { $rec.StringData($k + 2) = $keyParts[$k] }
            [void]$v.Execute($rec)
            [void]$v.Close()
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
            $repaired++
        }
    }
    if ($unrepairable.Count -gt 0) {
        Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue
        throw ("rewrite damaged rows it cannot repair (package deleted): " +
            (($unrepairable | Select-Object -First 5) -join '; '))
    }
    $repairedTotal += $repaired
    if ($repaired -eq 0) { break }
    Write-Host "  repair p$pass  : $repaired cell(s) restored"
    if ($pass -eq 3) {
        Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue
        throw 'rewrite did not converge after 3 repair passes (package deleted)'
    }
}
Write-Host "  repaired    : $repairedTotal collateral cell(s)"

Close-MsiDb

# ------------------------------------- session 4: re-assert the identity
#
# The repair pass above cannot fix the identity's own cells: `Property|Value`
# is on the intended list, so a cell that went BLANK there reads as "changed on
# purpose" and is skipped. That is not hypothetical - it is the same freed
# shared string the header describes, arriving from the other direction.
# Measured on the published 1.36.0 package: `Property.ProductVersion` shares its
# pool entry with `Upgrade.VersionMax` (both `26.8.3110`), so re-keying the
# Upgrade rows frees it and the Property cell reads back as ''. Every other
# identity cell survived because each was written to a string nothing else
# holds, which is why this only ever showed up once -ProductVersion existed.
#
# So: read the identity back, write whatever is not what it should be, and
# repeat while anything moves. A write here can free another string in turn,
# hence the loop - and not converging is a failure, never a shrug.
function Set-MsiCell([string]$Update, [string]$Value) {
    $v = $db.OpenView($Update)
    $rec = $installer.CreateRecord(1)
    $rec.StringData(1) = $Value
    [void]$v.Execute($rec)
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
}

for ($pass = 1; $pass -le 3; $pass++) {
    Open-MsiDb
    $wrong = @()
    foreach ($k in $propMap.Keys) {
        $cur = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$k'"
        if ($cur -ne $propMap[$k]) { $wrong += "Property.$k" }
    }
    foreach ($row in (Get-MsiRows "SELECT ``ActionProperty``,``VersionMin``,``VersionMax`` FROM ``Upgrade``" 3)) {
        $want = $upgradeBounds[$row[0]]
        if ($null -eq $want) { continue }
        if ($row[1] -ne $want[0]) { $wrong += "Upgrade.$($row[0]).VersionMin" }
        if ($row[2] -ne $want[1]) { $wrong += "Upgrade.$($row[0]).VersionMax" }
    }
    if ($wrong.Count -eq 0) { Close-MsiDb; break }
    foreach ($k in $propMap.Keys) {
        $cur = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$k'"
        if ($cur -ne $propMap[$k]) {
            Set-MsiCell "UPDATE ``Property`` SET ``Value``=? WHERE ``Property``='$k'" $propMap[$k]
        }
    }
    # The bounds are PRIMARY KEY columns, so msiViewModifyUpdate cannot touch
    # them and an `UPDATE ... SET VersionMin` view fails to execute at all.
    # Same msiViewModifyReplace idiom the UpgradeCode re-key uses, and for the
    # same reason.
    foreach ($ap in @($upgradeBounds.Keys)) {
        $want = $upgradeBounds[$ap]
        $v = $db.OpenView("SELECT $upgradeColList FROM ``Upgrade`` WHERE ``ActionProperty``='$ap'")
        [void]$v.Execute()
        $r = $v.Fetch()
        if ($null -ne $r) {
            $r.StringData(2) = $want[0]
            $r.StringData(3) = $want[1]
            [void]$v.Modify($MODIFY_REPLACE, $r)
        }
        [void]$v.Close()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    }
    Close-MsiDb
    Write-Host "  identity p${pass}: $($wrong.Count) cell(s) re-asserted ($($wrong -join ', '))"
    if ($pass -eq 3) {
        Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue
        throw ('rewrite could not hold the identity cells after 3 passes (package deleted): ' +
            ($wrong -join ', '))
    }
}

# The package code lives in the summary stream rather than in a table, so it is
# a separate open-write-persist, and it needs the database handle to be gone
# first: `Database.SummaryInformation` on a live handle takes the process down
# with an AccessViolation.
$si = $installer.SummaryInformation($Out, 2)
$si.Property(9) = $newPackage
[void]$si.Persist()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($si)
Write-Host "  PackageCode : $newPackage"

# ------------------------------------------------------------- verification
#
# Re-open the finished package and PROVE the identity swap rather than trust
# that ten writes all landed. Every failure this script has had was silent - a
# corrupted cell reads back as a plausible string - so the checks are on the
# values a wrong package WOULD have, not on the absence of an error. A package
# that fails here is deleted: a half-rewritten one still carrying the real
# UpgradeCode is the single artifact nobody may be handed.
Open-MsiDb
$problems = New-Object System.Collections.ArrayList
function Check([bool]$ok, [string]$what) {
    if (-not $ok) { [void]$problems.Add($what) }
}

Check ((Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductCode'") -eq $newProduct) 'Property.ProductCode'
Check ((Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='UpgradeCode'") -eq $newUpgrade) 'Property.UpgradeCode'
Check ((Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductName'") -eq $Identity) 'Property.ProductName'
# Without -ProductVersion this asks that the version was NOT clobbered by the
# Upgrade edit; with it, that the requested one landed. `$version` is already
# whichever of the two this run means.
$versionAfter = Get-MsiValue "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'"
Check ($versionAfter -eq $version) "Property.ProductVersion (wanted $version, read '$versionAfter')"
Check ((Get-MsiValue "SELECT ``DefaultDir`` FROM ``Directory`` WHERE ``Directory``='INSTALLDIR'") -like "*$Identity") 'Directory.INSTALLDIR'

$upgradeAfter = Get-MsiRows "SELECT ``UpgradeCode``,``ActionProperty`` FROM ``Upgrade``" 2
$badUpgrade = 0
foreach ($row in $upgradeAfter) { if ($row[0] -ne $newUpgrade) { $badUpgrade++ } }
Check ($badUpgrade -eq 0) "Upgrade.UpgradeCode ($badUpgrade row(s) still on another code)"
# The row COUNT matters as much as the values: losing the OLDERVERSIONFOUND row
# would quietly turn the major upgrade into a second side-by-side install.
$boundsAfter = Get-MsiRows "SELECT ``ActionProperty``,``VersionMin``,``VersionMax`` FROM ``Upgrade``" 3
$badBounds = @()
foreach ($row in $boundsAfter) {
    $want = $upgradeBounds[$row[0]]
    if ($null -eq $want) { continue }
    if ($row[1] -ne $want[0]) { $badBounds += "$($row[0]).VersionMin='$($row[1])'" }
    if ($row[2] -ne $want[1]) { $badBounds += "$($row[0]).VersionMax='$($row[2])'" }
}
# A blanked bound is unbounded, and an unbounded NEWERVERSIONFOUND blocks every
# install of this package with "a newer version is already installed" - a
# package that is broken in a way nobody sees until they try to use it.
Check ($badBounds.Count -eq 0) ("Upgrade version bounds: " + ($badBounds -join ', '))
Check ($upgradeAfter.Count -eq $actionProps.Count) "Upgrade row count ($($upgradeAfter.Count), expected $($actionProps.Count))"

$comps = Get-MsiRows "SELECT ``Component``,``ComponentId`` FROM ``Component``" 2
$compIds = @()
$stray = 0
foreach ($row in $comps) {
    if ($row[1] -eq '') { continue }
    $compIds += $row[1]
    if ($row[1] -ne (New-DerivedGuid -Identity $Identity -Seed ("component::" + $row[0]))) { $stray++ }
}
Check ($stray -eq 0) "Component.ComponentId ($stray outside the derived namespace)"
Check ((@($compIds | Sort-Object -Unique).Count) -eq $compIds.Count) 'Component.ComponentId (duplicates)'

$regRows = Get-MsiRows "SELECT ``Registry``,``Key`` FROM ``Registry``" 2
$regBad = @()
foreach ($row in $regRows) { if ($row[1] -notlike "*$Identity") { $regBad += ($row[0] + '=' + $row[1]) } }
Check ($regBad.Count -eq 0) ("Registry.Key: " + ($regBad -join ', '))

Close-MsiDb

if ($problems.Count -gt 0) {
    Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue
    throw ("rewrite verification FAILED (package deleted): " + ($problems -join '; '))
}

Write-Host "  verified    : $($comps.Count) components, identity fully swapped"
Write-Host "OK $Out"
