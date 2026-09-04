<#
.SYNOPSIS
    T452 - what is the Windows hardware error log actually saying about this box?

.DESCRIPTION
    THE TRAP THIS SCRIPT EXISTS TO CLOSE. Corrected hardware errors are logged
    at WARNING level, not Error. T449 asked "is this box faulting?", queried
    Microsoft-Windows-WHEA-Logger filtered to Error level, found nothing, and
    wrote "zero WHEA events in 14 days" into its evidence section. There were
    6369 - roughly two hundred a day, every day, from one PCIe root port. A
    level-filtered WHEA query does not mean the hardware is quiet; it means the
    hardware has not yet failed in a way that lost data.

    So this script never filters by level. It reads every WHEA-Logger event in
    the window and splits them by what the event ID MEANS:

      CORRECTED     the hardware detected the fault and recovered from it. No
                    data was lost. A high count is still a real signal - a link
                    retrying hundreds of times a day is marginal, and marginal
                    gets worse - but it is not a crash cause and it is not a
                    reason to stop work.
      UNCORRECTED   the fault reached the machine. This is the class that
                    corrupts and bugchecks, and it is what the exit code is for.
      INFORMATIONAL a record the platform logged for context.
      UNCLASSIFIED  an ID this table has never seen. Named rather than folded
                    into any bucket, because the whole point of the file is not
                    to let an unread event pass as an absence of events.

    It also RESOLVES the device. A WHEA message names a PCI hardware ID and a
    bus:device:function, which is unreadable; what the person reading the report
    needs is "the link to the Samsung NVMe that carries D:". So for each error
    source the report walks PCI hardware ID -> PnP friendly name -> child device
    -> disk -> drive letters.

    Exit codes: 8 if any UNCORRECTED event is present in the window, 0
    otherwise (including a window full of corrected errors). Nothing in ghoztty
    can act on a marginal PCIe link; this reports, it never gates.

.PARAMETER Days
    Size of the window, in days, ending now. Default 30.

.PARAMETER Json
    Emit the report as JSON instead of text.

.PARAMETER InputPath
    Read events from a JSON fixture instead of the live event log - an array of
    objects with TimeCreated / Id / LevelDisplayName / Message. This is how
    test\win32\whea-report.ps1 scores the classification and the level trap on
    a box whose real log is whatever it happens to be.

.PARAMETER NoResolve
    Skip the PnP device walk (fast, and the only mode that works off a fixture
    naming devices this box does not have).
#>
[CmdletBinding()]
param(
    [int]$Days = 30,
    [switch]$Json,
    [string]$InputPath,
    [switch]$NoResolve
)

$ErrorActionPreference = 'Stop'

# What each WHEA-Logger event ID means. Deliberately explicit: an ID that is
# not in here is reported as UNCLASSIFIED rather than assumed harmless, because
# "we did not recognise it" and "it was fine" are the two readings this whole
# file exists to keep apart.
$script:WheaIds = @{
    1  = @{ Class = 'UNCORRECTED';   What = 'internal platform error (uncorrected)' }
    2  = @{ Class = 'UNCORRECTED';   What = 'fatal hardware error' }
    3  = @{ Class = 'INFORMATIONAL'; What = 'informational hardware event' }
    17 = @{ Class = 'CORRECTED';     What = 'corrected hardware error (PCI Express AER)' }
    18 = @{ Class = 'UNCORRECTED';   What = 'fatal hardware error' }
    19 = @{ Class = 'CORRECTED';     What = 'corrected machine check' }
    20 = @{ Class = 'UNCORRECTED';   What = 'fatal hardware error' }
    41 = @{ Class = 'UNCORRECTED';   What = 'uncorrectable machine check' }
    46 = @{ Class = 'UNCORRECTED';   What = 'uncorrected PCI Express error' }
    47 = @{ Class = 'CORRECTED';     What = 'corrected memory error (predictive failure)' }
}

function Get-WheaClass([int]$id) {
    if ($script:WheaIds.ContainsKey($id)) { return $script:WheaIds[$id].Class }
    return 'UNCLASSIFIED'
}

function Get-WheaWhat([int]$id) {
    if ($script:WheaIds.ContainsKey($id)) { return $script:WheaIds[$id].What }
    return 'unrecognised WHEA event id'
}

# The error source, as the message states it: the PCI hardware ID plus the
# bus:device:function. Events with neither are grouped under their component.
function Get-WheaSource($message) {
    $text = [string]$message
    $hw = ''
    $bdf = ''
    $component = ''
    if ($text -match 'Primary Device Name\s*:\s*(\S+)')            { $hw = $Matches[1] }
    if ($text -match 'Primary Bus:Device:Function\s*:\s*(\S+)')    { $bdf = $Matches[1] }
    if ($text -match 'Component\s*:\s*(.+)')                       { $component = $Matches[1].Trim() }
    if (-not $hw -and -not $bdf) { $hw = if ($component) { $component } else { '(unnamed source)' } }
    return [pscustomobject]@{ Hardware = $hw; Bdf = $bdf; Component = $component }
}

# PCI\VEN_8086&DEV_7A30&SUBSYS_...&REV_11 -> "Intel(R) PCI Express Root Port #9"
# -> the NVMe controller behind it -> the disk -> "D:". Best effort throughout:
# a device that is gone, or a fixture naming hardware this box never had, must
# degrade to the raw ID rather than throw.
function Resolve-WheaDevice([string]$hardwareId) {
    $result = [pscustomobject]@{ Name = ''; Behind = ''; Disks = @() }
    if (-not $hardwareId.StartsWith('PCI\')) { return $result }
    $prefix = $hardwareId
    try {
        $dev = Get-PnpDevice -PresentOnly -ErrorAction Stop |
               Where-Object { $_.InstanceId -like "$prefix*" } |
               Select-Object -First 1
    } catch { return $result }
    if (-not $dev) { return $result }
    $result.Name = $dev.FriendlyName

    $kids = @()
    try {
        $kids = @((Get-PnpDeviceProperty -InstanceId $dev.InstanceId `
                    -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop).Data)
    } catch { $kids = @() }
    $behind = @()
    $disks = @()
    foreach ($k in $kids) {
        if (-not $k) { continue }
        $kd = $null
        try { $kd = Get-PnpDevice -InstanceId $k -ErrorAction Stop } catch { }
        if ($kd) { $behind += $kd.FriendlyName }
        # One more hop: the storage controller's own child is the disk device,
        # whose instance id carries the same key as Get-Disk's device path.
        $gkids = @()
        try {
            $gkids = @((Get-PnpDeviceProperty -InstanceId $k `
                        -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop).Data)
        } catch { $gkids = @() }
        foreach ($g in $gkids) {
            if (-not $g) { continue }
            $key = ($g -split '\\')[-1]
            if (-not $key) { continue }
            $match = $null
            try {
                $match = Get-Disk -ErrorAction Stop |
                         Where-Object { $_.Path -and $_.Path.ToLower().Contains($key.ToLower()) } |
                         Select-Object -First 1
            } catch { }
            if (-not $match) { continue }
            $letters = @()
            try {
                $letters = @(Get-Partition -DiskNumber $match.Number -ErrorAction Stop |
                             Where-Object DriveLetter |
                             ForEach-Object { "$($_.DriveLetter):" })
            } catch { }
            $disks += [pscustomobject]@{
                Number  = $match.Number
                Model   = $match.FriendlyName
                Letters = $letters
            }
        }
    }
    $result.Behind = ($behind -join ', ')
    $result.Disks = $disks
    return $result
}

# --- gather ---------------------------------------------------------------

$since = (Get-Date).AddDays(-[math]::Abs($Days))
$events = @()
$source = 'System event log'

if ($InputPath) {
    $source = "fixture $InputPath"
    if (-not (Test-Path $InputPath)) { throw "fixture not found: $InputPath" }
    $raw = Get-Content -Path $InputPath -Raw | ConvertFrom-Json
    foreach ($e in @($raw)) {
        $events += [pscustomobject]@{
            TimeCreated = [datetime]$e.TimeCreated
            Id          = [int]$e.Id
            Level       = [string]$e.LevelDisplayName
            Message     = [string]$e.Message
        }
    }
} else {
    $raw = @()
    try {
        # NO Level filter, ever. That filter is the defect this script was
        # written to make impossible to reintroduce.
        $raw = @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-WHEA-Logger'
            StartTime    = $since
        } -ErrorAction Stop)
    } catch {
        # Get-WinEvent throws rather than returning empty when a filter matches
        # nothing, which is genuinely the clean case.
        $raw = @()
    }
    foreach ($e in $raw) {
        $events += [pscustomobject]@{
            TimeCreated = $e.TimeCreated
            Id          = [int]$e.Id
            Level       = [string]$e.LevelDisplayName
            Message     = [string]$e.Message
        }
    }
}

$rows = foreach ($e in $events) {
    $src = Get-WheaSource $e.Message
    [pscustomobject]@{
        TimeCreated = $e.TimeCreated
        Id          = $e.Id
        Level       = $e.Level
        Class       = Get-WheaClass $e.Id
        What        = Get-WheaWhat $e.Id
        Hardware    = $src.Hardware
        Bdf         = $src.Bdf
        Component   = $src.Component
    }
}
$rows = @($rows)

$counts = @{ CORRECTED = 0; UNCORRECTED = 0; INFORMATIONAL = 0; UNCLASSIFIED = 0 }
foreach ($r in $rows) { $counts[$r.Class] = $counts[$r.Class] + 1 }

$perDay = if ($Days -gt 0) { [math]::Round($rows.Count / $Days, 1) } else { 0 }
$verdict = if ($counts.UNCORRECTED -gt 0) {
    "WHEA UNCORRECTED $($counts.UNCORRECTED) event(s) in $Days days - the fault reached the machine"
} elseif ($rows.Count -eq 0) {
    "WHEA CLEAN no hardware events in $Days days"
} else {
    "WHEA CORRECTED $($counts.CORRECTED) corrected event(s) in $Days days (~$perDay/day) - recovered, nothing lost"
}
$exit = if ($counts.UNCORRECTED -gt 0) { 8 } else { 0 }

# --- per-source rollup ----------------------------------------------------

$sources = @()
foreach ($g in ($rows | Group-Object Hardware, Bdf)) {
    $first = $g.Group[0]
    $times = @($g.Group | ForEach-Object { $_.TimeCreated } | Sort-Object)
    $resolved = if ($NoResolve) { $null } else { Resolve-WheaDevice $first.Hardware }
    $sources += [pscustomobject]@{
        Hardware  = $first.Hardware
        Bdf       = $first.Bdf
        Component = $first.Component
        Class     = $first.Class
        Count     = $g.Count
        First     = if ($times.Count) { $times[0] } else { $null }
        Last      = if ($times.Count) { $times[-1] } else { $null }
        Name      = if ($resolved) { $resolved.Name } else { '' }
        Behind    = if ($resolved) { $resolved.Behind } else { '' }
        Disks     = if ($resolved) { @($resolved.Disks) } else { @() }
    }
}
$sources = @($sources | Sort-Object Count -Descending)

$byId = @()
foreach ($g in ($rows | Group-Object Id | Sort-Object { [int]$_.Name })) {
    $id = [int]$g.Name
    $byId += [pscustomobject]@{
        Id     = $id
        Class  = Get-WheaClass $id
        What   = Get-WheaWhat $id
        Levels = (@($g.Group | ForEach-Object { $_.Level } | Sort-Object -Unique) -join '/')
        Count  = $g.Count
    }
}

# --- report ---------------------------------------------------------------

if ($Json) {
    [pscustomobject]@{
        Window      = $Days
        Since       = $since
        Source      = $source
        Total       = $rows.Count
        Counts      = $counts
        Verdict     = $verdict
        Exit        = $exit
        ById        = $byId
        Sources     = $sources
    } | ConvertTo-Json -Depth 6
    exit $exit
}

"WHEA report - last $Days days, read from $source"
"  (level is never filtered: corrected errors log as Warning, and filtering to"
"   Error reads a noisy box as a silent one - that is how T449 recorded"
"   'zero WHEA events' over 6369 of them)"
""
"By event id"
if (-not $byId.Count) { "  none" }
foreach ($r in $byId) {
    "  id {0,-3} {1,-13} {2,7} event(s)  [{3}]  {4}" -f $r.Id, $r.Class, $r.Count, $r.Levels, $r.What
}
""
"By error source"
if (-not $sources.Count) { "  none" }
foreach ($s in $sources) {
    $where = if ($s.Bdf) { " at $($s.Bdf)" } else { '' }
    "  {0,7} x {1}{2}" -f $s.Count, $s.Hardware, $where
    if ($s.Component) { "          component: $($s.Component)" }
    if ($s.Name)      { "          device:    $($s.Name)" }
    if ($s.Behind)    { "          behind it: $($s.Behind)" }
    foreach ($d in $s.Disks) {
        $l = if ($d.Letters.Count) { ($d.Letters -join ' ') } else { '(no drive letter)' }
        "          disk $($d.Number): $($d.Model) -> $l"
    }
    if ($s.First -and $s.Last) {
        "          first: $($s.First)   last: $($s.Last)"
    }
}
""
$verdict
exit $exit
