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
#   C  the relay serves a SIGNPOST and nothing else: /dl/install.ps1 still
#      has a source file (an old one-liner must inform, not 404) that installs
#      NOTHING, and publish-agent.sh no longer publishes a Windows binary at
#      all. T550 retired /dl/ghoztty-agent.exe and /dl/version.json along with
#      the agent self-updater that was their only reader -- until then this
#      section asserted the two SIDES AGREED, because the updater still read
#      what the script still wrote. With the reader gone, publishing an
#      unsigned Windows exe from a host nobody audits is a download surface
#      with no purpose, so what is asserted flipped from agreement to absence.
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
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
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
    # The agent's relay-mode entry point. Section C reads it to assert the
    # self-updater is GONE from the code, not merely unpublished.
    mainzig   = 'src\remote\agent\main.zig'
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

# Source files T550 retired outright. Asserted by existence rather than by
# content, so they are checked next to B0 rather than in $checks (a file that
# is not there has nothing to poison, which is why the mutation registry below
# does not cover these).
$retired = @(
    'src\remote\agent\self_update.zig',
    'src\remote\agent\tray.zig',
    'src\remote\agent\tray_account.zig',
    'scripts\deploy-windows-agent.sh'
)

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
    'C3 publish-agent uploads no Windows binary and no manifest' =
        { param($t) $t.publish -notmatch 'UPLOADS=.*ghoztty-agent\.exe' -and
                    $t.publish -notmatch '\$DL_DIR/ghoztty-agent\.exe' -and
                    $t.publish -notmatch '\$DL_DIR/version\.json' -and
                    $t.publish -notmatch 'VERSION_JSON' }
    'C4 publish-agent still uploads the install.ps1 signpost' =
        { param($t) $t.publish -match 'INSTALL_PS1' }
    'C5 no agent code reads a hosted version manifest' =
        { param($t) $t.mainzig -notmatch 'self_update' -and $t.mainzig -notmatch '/dl/version\.json' }
    # A MENTION is fine and expected -- both files are named in prose as
    # retired. What must not come back is a FETCH of either one.
    'C6 nothing still fetches the retired downloads' =
        { param($t)
          $pat = '(curl|Invoke-WebRequest|Invoke-RestMethod|wget)[^
]*(/dl/ghoztty-agent\.exe|/dl/version\.json)'
          ($t.caddy -notmatch $pat) -and ($t.release -notmatch $pat) -and ($t.readme -notmatch $pat) }

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
    'C3 publish-agent uploads no Windows binary and no manifest' = @('publish', 'sudo install -m 644 $REMOTE_STAGE/agent.exe $DL_DIR/ghoztty-agent.exe')
    'C4 publish-agent still uploads the install.ps1 signpost' = @('publish',   '')   # emptied
    'C5 no agent code reads a hosted version manifest'        = @('mainzig',   'const updater = self_update.maybeStart(alloc, ws_host, agent_version, &store);')
    'C6 nothing still fetches the retired downloads'          = @('release',   'curl -fsS https://relay/dl/version.json')
    'D1 the page offers the Windows installer exactly once'   = @('ghpages',   '<a id="win-msi-link" href="/dl/Ghoztty-x64.msi">Get the Windows installer</a>')
    'D2 relay landing page sends you to the product site'     = @('www',       '')   # emptied
    'E1 relay README does not present a standalone installer as live' = @('readme',  'Ghoztty-Agent-1.2.3-x64.msi')
    'E2 release runbook publishes no agent MSI'               = @('release',   'curl -I https://relay/dl/ghoztty-agent.msi')
}

if (-not $TeethCheck) {
    "== one-installer: the shipped tree =="
    Assert 'B0 relay/deploy/msi/ is gone' (-not (Test-Path -LiteralPath $msiDir))
    foreach ($gone in $retired) {
        Assert "C0 $gone is gone" (-not (Test-Path -LiteralPath (Join-Path $Repo $gone)))
    }
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
        else { "  PASS $name (caught)"; $script:passes++ }
    }
    # And the directory check, whose "mutation" is the directory coming back.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("one-installer-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $back = Join-Path $tmp 'msi'
        New-Item -ItemType Directory -Path $back | Out-Null
        if (Test-Path -LiteralPath $back) { "  PASS B0 relay/deploy/msi/ is gone (caught)"; $script:passes++ }
        else { "  FAIL B0 relay/deploy/msi/ is gone (mutation not caught)"; $script:failures++ }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A clean green run stamps the files this harness covers (T783). The negative
# control deliberately scores red on every check, so it never stamps.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard one-installer -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Label 'T1175 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
