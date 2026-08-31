# Windows offers exactly ONE installer, and it stays that way (T1175).
#
# The failure this guards is not a crash, it is a shape. The download page
# used to offer two Windows installers -- Ghoztty's MSI and a standalone
# Remote Agent MSI served from the relay -- so a new user could install half a
# product, and the half-installed case fails with no window, no dialog and no
# feedback until a late agent-probe timeout. `ghoztty-agent.exe` has been a
# required sibling of `ghoztty.exe` inside the Ghoztty MSI since T89h, so the
# second installer added nothing to a box that had Ghoztty and everything to a
# box that did not.
#
# A retirement like this rots back in one careless edit: a link restored "for
# convenience", an MSI target added back to a publish script, a doc paragraph
# that still tells someone to paste a one-liner. Nothing else in the tree
# looks at these files, so this harness is the only thing that would notice.
#
# What this asserts:
#
#   A  no second installer is OFFERED: neither landing page links an agent
#      MSI, an agent exe download, or an install one-liner, and the page
#      script no longer fetches a separate agent version to advertise.
#   B  the MSI pipeline is GONE, not flagged off: relay/deploy/msi/ does not
#      exist and publish-agent.sh neither builds nor uploads an MSI.
#   C  what must KEEP working still does: /dl/install.ps1 still has a source
#      file (an old one-liner must inform, not 404) that installs NOTHING,
#      and publish-agent.sh still ships the exe + version.json the agent's
#      self-updater reads -- with the field names self_update.zig parses.
#   D  the pages send people to the ONE installer instead.
#   E  the docs describe one install path, not two.
#
# Every assertion is a predicate over file CONTENT, so -TeethCheck can
# feed each check the mutation it exists to catch and prove it scores red.
# A gate nobody has watched fail is indistinguishable from a gate that cannot
# fail (T1133).
#
# Read-only. Never launches the app, never publishes, needs no network.
#
#   powershell -NoProfile -File test\win32\one-installer.ps1
#   powershell -NoProfile -File test\win32\one-installer.ps1 -TeethCheck
param(
    [string]$Repo = 'D:\git\ghoztty',
    # Re-run every check against a deliberately broken copy of each surface
    # and assert it goes red. Proves the checks measure what they claim.
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$script:failures = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

$paths = [ordered]@{
    ghpages   = 'relay\deploy\ghpages\index.html'
    mainjs    = 'relay\deploy\ghpages\landing\main.js'
    www       = 'relay\deploy\www\index.html'
    installps = 'relay\deploy\install.ps1'
    publish   = 'relay\deploy\publish-agent.sh'
    caddy     = 'relay\deploy\Caddyfile.example'
    readme    = 'relay\README.md'
    release   = '.claude\commands\release.md'
    selfupd   = 'src\remote\agent\self_update.zig'
}

$text = [ordered]@{}
foreach ($k in $paths.Keys) {
    $p = Join-Path $Repo $paths[$k]
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        "1 FAILURE(S)"
        exit 1
    }
    $text[$k] = (Get-Content -LiteralPath $p -Raw)
}

$msiDir = Join-Path $Repo 'relay\deploy\msi'

# ---------------------------------------------------------------------------
# The checks. Each takes the content map and returns $true when the tree is in
# the one-installer shape. Named so a failure says which invariant broke.
# ---------------------------------------------------------------------------

$checks = [ordered]@{
    # A - nothing offers a second installer.
    'A1 ghpages links no agent MSI' =
        { param($t) $t.ghpages -notmatch 'ghoztty-agent\.msi|Ghoztty-Agent-' }
    'A2 ghpages offers no install one-liner' =
        { param($t) $t.ghpages -notmatch '/dl/install\.ps1' }
    'A3 ghpages offers no raw agent exe download' =
        { param($t) $t.ghpages -notmatch '/dl/ghoztty-agent\.exe' }
    'A4 ghpages has no standalone agent download button' =
        { param($t) $t.ghpages -notmatch 'agent-msi-link' }
    'A5 page script advertises no separate agent version' =
        { param($t) $t.mainjs -notmatch '/dl/version\.json' -and $t.mainjs -notmatch 'agent-msi-link' }
    'A6 relay landing page links no agent MSI or one-liner' =
        { param($t) $t.www -notmatch 'ghoztty-agent\.msi|/dl/install\.ps1|/dl/ghoztty-agent\.exe' }

    # B - the pipeline is gone rather than switched off.
    'B1 publish-agent builds no MSI' =
        { param($t) $t.publish -notmatch 'msi/build-msi\.sh|--skip-msi|SKIP_MSI' }
    'B2 publish-agent uploads no MSI' =
        { param($t) $t.publish -notmatch 'MSI_BASENAME|ghoztty-agent\.msi' }
    'B3 Caddyfile advertises no hosted agent MSI' =
        { param($t) $t.caddy -notmatch 'ghoztty-agent\.msi' }

    # C - what must keep answering, keeps answering.
    'C1 install.ps1 names where to get Ghoztty' =
        { param($t) $t.installps -match 'dzearing\.github\.io/ghoztty' }
    'C2 install.ps1 installs nothing' =
        { param($t) $t.installps -notmatch 'msiexec|Start-Process|Invoke-WebRequest|Invoke-RestMethod|\bcurl\b' }
    'C3 publish-agent still ships the exe and manifest' =
        { param($t) $t.publish -match 'ghoztty-agent\.exe' -and $t.publish -match 'version\.json' }
    'C4 publish-agent still uploads the install.ps1 signpost' =
        { param($t) $t.publish -match 'INSTALL_PS1' }
    'C5 manifest carries the fields self_update.zig parses' =
        { param($t)
          $ok = $true
          foreach ($f in @('version', 'sha256', 'path')) {
              if ($t.publish -notmatch ('"' + $f + '"')) { $ok = $false }
              if ($t.selfupd -notmatch ('"' + $f + '"')) { $ok = $false }
          }
          $ok }
    'C6 the manifest path both sides use still agrees' =
        { param($t) $t.selfupd -match '/dl/version\.json' -and $t.publish -match 'version\.json' }

    # D - the pages point at the one installer.
    # The Remote Agent section this used to check was REMOVED on 2026-08-31
    # (341f48c39): its card carried a second "Get the Windows installer" button,
    # which is the two-installers-on-one-page failure T1175 exists to end,
    # rebuilt out of page parts instead of binaries. So the invariant moved with
    # it - what matters now is that the page offers the Windows installer
    # exactly ONCE, wherever a future section might be tempted to offer it again.
    'D1 the page offers the Windows installer exactly once' =
        { param($t)
          ([regex]::Matches($t.ghpages, 'id="win-msi-link"').Count -eq 1) -and
          ([regex]::Matches($t.ghpages, '\.msi').Count -eq 1) }
    'D2 relay landing page sends you to the product site' =
        { param($t) $t.www -match 'dzearing\.github\.io/ghoztty' }

    # E - the docs describe one path.
    'E1 relay README does not present a standalone installer as live' =
        { param($t) $t.readme -notmatch 'Ghoztty-Agent-|ghoztty-agent\.msi' }
    'E2 release runbook publishes no agent MSI' =
        { param($t) $t.release -notmatch 'ghoztty-agent\.msi|Ghoztty-Agent-X' }
}

# The mutation each check must catch. Keyed by check name; the value is the
# content key to poison and the text to splice in. A check with no mutation
# listed here is a check that has never been seen to fail, and that is a
# failure of this harness (asserted below).
$mutations = @{
    'A1 ghpages links no agent MSI'                           = @('ghpages',   'href="/dl/ghoztty-agent.msi"')
    'A2 ghpages offers no install one-liner'                  = @('ghpages',   'irm https://relay/dl/install.ps1 | iex')
    'A3 ghpages offers no raw agent exe download'             = @('ghpages',   'href="/dl/ghoztty-agent.exe"')
    'A4 ghpages has no standalone agent download button'      = @('ghpages',   'id="agent-msi-link"')
    'A5 page script advertises no separate agent version'     = @('mainjs',    'fetch("/dl/version.json")')
    'A6 relay landing page links no agent MSI or one-liner'   = @('www',       'href="/dl/ghoztty-agent.msi"')
    'B1 publish-agent builds no MSI'                          = @('publish',   '"$SCRIPT_DIR/msi/build-msi.sh" "$EXE"')
    'B2 publish-agent uploads no MSI'                         = @('publish',   'MSI_BASENAME="Ghoztty-Agent-x64.msi"')
    'B3 Caddyfile advertises no hosted agent MSI'             = @('caddy',     '#   /dl/ghoztty-agent.msi')
    'C1 install.ps1 names where to get Ghoztty'               = @('installps', '')   # emptied
    'C2 install.ps1 installs nothing'                         = @('installps', 'msiexec /i $msi /qn')
    'C3 publish-agent still ships the exe and manifest'       = @('publish',   '')   # emptied
    'C4 publish-agent still uploads the install.ps1 signpost' = @('publish',   '')   # emptied
    'C5 manifest carries the fields self_update.zig parses'   = @('publish',   '')   # emptied
    'C6 the manifest path both sides use still agrees'        = @('selfupd',   '')   # emptied
    'D1 the page offers the Windows installer exactly once'   = @('ghpages',   '<a id="win-msi-link" href="/dl/Ghoztty-x64.msi">Get the Windows installer</a>')
    'D2 relay landing page sends you to the product site'     = @('www',       '')   # emptied
    'E1 relay README does not present a standalone installer as live' = @('readme',  'Ghoztty-Agent-1.2.3-x64.msi')
    'E2 release runbook publishes no agent MSI'               = @('release',   'curl -I https://relay/dl/ghoztty-agent.msi')
}

if (-not $TeethCheck) {
    "== one-installer: the shipped tree =="
    Assert 'B0 relay/deploy/msi/ is gone' (-not (Test-Path -LiteralPath $msiDir))
    foreach ($name in $checks.Keys) {
        Assert $name (& $checks[$name] $text)
    }

    "== one-installer: every check has a demonstration =="
    $missing = @($checks.Keys | Where-Object { -not $mutations.ContainsKey($_) })
    Assert "F1 no check ships without a mutation (-TeethCheck covers all $($checks.Count))" ($missing.Count -eq 0)
    if ($missing.Count -gt 0) { $missing | ForEach-Object { "       undemonstrated: $_" } }
} else {
    "== one-installer -TeethCheck: each check, fed the state it exists to catch =="
    foreach ($name in $checks.Keys) {
        if (-not $mutations.ContainsKey($name)) {
            "  FAIL $name (no mutation declared)"; $script:failures++; continue
        }
        $key, $inject = $mutations[$name]
        # Copy the content map, poison one surface, re-run just this check.
        $poisoned = [ordered]@{}
        foreach ($k in $text.Keys) { $poisoned[$k] = $text[$k] }
        if ($inject -eq '') { $poisoned[$key] = '' } else { $poisoned[$key] = $text[$key] + "`n" + $inject + "`n" }
        $stillPasses = & $checks[$name] $poisoned
        if ($stillPasses) { "  FAIL $name (mutation not caught)"; $script:failures++ }
        else { "  PASS $name (caught)" }
    }
    # And the directory check, whose "mutation" is the directory coming back.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("one-installer-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $back = Join-Path $tmp 'msi'
        New-Item -ItemType Directory -Path $back | Out-Null
        if (Test-Path -LiteralPath $back) { "  PASS B0 relay/deploy/msi/ is gone (caught)" }
        else { "  FAIL B0 relay/deploy/msi/ is gone (mutation not caught)"; $script:failures++ }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A clean green run stamps the files this harness covers (T783). The negative
# control deliberately scores red on every check, so it never stamps.
if ($script:failures -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard one-installer -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
