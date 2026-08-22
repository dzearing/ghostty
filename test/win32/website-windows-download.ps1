# The website offers the Windows build, and keeps offering the right one (T39).
#
# T38 made every release PRODUCE the Windows artifacts. This is the other
# half: a user who lands on the site can actually get them. The failure mode
# it guards is the one T38 already paid for once -- the macOS channel reached
# v1.28.0 while Windows sat at win-v1.4.1, because the Windows half of the
# release needed a human to remember it. So the site's Windows links are NOT
# hand-edited: release-windows.yml retargets them from the release it just
# published, using dist/website/update-windows-links.py.
#
# What this asserts:
#
#   A  page shape: the Windows card sits beside the macOS card, its href is a
#      real win-v<version> asset whose FILENAME carries the same version plus
#      the arch, the portable ZIP alternative is offered as its own asset URL
#      on that same release (T354), and the minimum-OS
#      note is there, and the unsigned/SmartScreen caveat warns the user
#      before they download rather than after the scary dialog (T349). Also
#      that the card and the caveat reuse existing CSS classes rather than
#      inventing their own (the design-system rule, applied to the site).
#   B  name agreement: the asset names in the rewrite script are the names the
#      workflow publishes and the shared build script produces. Three writers,
#      one convention -- the same check release-artifacts.ps1 makes.
#   C  the rewrite script, run for real: it moves all three Windows anchors,
#      it does NOT touch the macOS download (a version regex loose enough to
#      find "the version" also finds Ghoztty-X.Y.Z-arm64.dmg), it is
#      idempotent, and a page it cannot find an anchor in is an ERROR rather
#      than a silent no-op. "Reported success and changed nothing" is the
#      failure shape this repo keeps re-learning (T214, T303).
#   D  wiring: the workflow really calls it, after the publish and gated on
#      it, and both writers of the gh-pages branch retry on a rejected push
#      (release.yml pushes appcast.xml on the same tag push -- concurrent).
#   E  live: the URLs on the page answer 200. Needs network; SKIPs without.
#   F  drift: the in-repo mirror matches the deployed gh-pages page. It has
#      silently drifted twice.
#   G  the gh-pages publish script, RUN, against bare repos on disk -- with a
#      rival push staged so its rejected-push retry actually executes (T353).
#      That loop is dead code on a normal release, so until this section the
#      first execution of it would have been a release depending on it.
#
# Read-only apart from a temp dir. Never launches the app, never publishes.
#
#   powershell -NoProfile -File test\win32\website-windows-download.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    # No network is a SKIP by default (only E and F need it);
    # -RequireNetwork turns those skips into failures.
    [switch]$RequireNetwork
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Skip($name, $why) {
    if ($RequireNetwork) { "  FAIL $name ($why)"; $script:failures++ }
    else { "  SKIP $name ($why)"; $script:skipped++ }
}

$indexPath = Join-Path $Repo 'relay\deploy\ghpages\index.html'
$cssPath   = Join-Path $Repo 'relay\deploy\ghpages\landing\styles.css'
$pyPath    = Join-Path $Repo 'dist\website\update-windows-links.py'
$pubPath   = Join-Path $Repo 'dist\website\publish-windows-links.sh'
$wfPath    = Join-Path $Repo '.github\workflows\release-windows.yml'
$macWfPath = Join-Path $Repo '.github\workflows\release.yml'
$sharedSh  = Join-Path $Repo 'dist\windows-installer\build-release-artifacts.sh'

foreach ($p in @($indexPath, $cssPath, $pyPath, $pubPath, $wfPath, $macWfPath, $sharedSh)) {
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        "1 FAILURE(S)"
        exit 1
    }
}

$html   = Get-Content -LiteralPath $indexPath -Raw
$css    = Get-Content -LiteralPath $cssPath -Raw
$py     = Get-Content -LiteralPath $pyPath -Raw
$wf     = Get-Content -LiteralPath $wfPath -Raw
$macWf  = Get-Content -LiteralPath $macWfPath -Raw
$shared = Get-Content -LiteralPath $sharedSh -Raw
$pub    = Get-Content -LiteralPath $pubPath -Raw

"=== A. page shape ==="

$msiMatches = [regex]::Matches($html, 'id="win-msi-link"[^>]*?href="([^"]+)"')
AssertEq 'A1 exactly one win-msi-link with an href' 1 $msiMatches.Count

$msiHref = ''
if ($msiMatches.Count -eq 1) { $msiHref = $msiMatches[0].Groups[1].Value }

# The tag version and the FILENAME version must be the same number: a link
# whose tag says win-v1.5.0 and whose filename says 1.4.1 is a 404 that looks
# fine in review.
$msiRe = '^https://github\.com/dzearing/ghoztty/releases/download/win-v(\d+\.\d+\.\d+)/Ghoztty-(\d+\.\d+\.\d+)-x64\.msi$'
$msiOk = $msiHref -match $msiRe
Assert 'A2 msi href is a win-v release asset URL' $msiOk

$winVersion = ''
if ($msiOk) {
    $winVersion = $Matches[1]
    AssertEq 'A3 msi filename version matches its tag' $Matches[1] $Matches[2]
} else {
    Assert 'A3 msi filename version matches its tag' $false
}
Assert 'A4 msi filename carries the arch' ($msiHref -match '-x64\.msi$')

$zipMatches = [regex]::Matches($html, 'id="win-zip-link"[^>]*?href="([^"]+)"')
AssertEq 'A5 exactly one win-zip-link with an href' 1 $zipMatches.Count
$zipHref = ''
if ($zipMatches.Count -eq 1) { $zipHref = $zipMatches[0].Groups[1].Value }
# The ZIP link must be the portable-ZIP ASSET of the same win-v release as the
# MSI card, with the tag version and the filename version agreeing -- the same
# bar A2/A3 hold the MSI to. It used to be allowed to point at the release
# PAGE instead, because win-v1.4.1 (MSI only) was the newest published Windows
# release and a release page is never a 404. Every release since win-v1.31.0
# publishes the ZIP and the live page has carried the direct asset URL since
# win-v1.34.0, so as of T354 that allowance can only hide the one thing worth
# catching: a rewrite that failed to promote the link.
$zipRe = '^https://github\.com/dzearing/ghoztty/releases/download/win-v(\d+\.\d+\.\d+)/Ghoztty-portable-(\d+\.\d+\.\d+)-x64\.zip$'
$zipOk = $zipHref -match $zipRe
Assert 'A6 zip href is a portable-ZIP release asset URL' $zipOk
if ($zipOk) {
    # Captured before anything else runs: $Matches belongs to the last -match.
    $zipTagVersion = $Matches[1]
    $zipFileVersion = $Matches[2]
    AssertEq 'A6b zip filename version matches its tag' $zipTagVersion $zipFileVersion
    AssertEq 'A6c zip link targets the same win-v release as the msi' $winVersion $zipTagVersion
} else {
    # Not vacuously green: an href that never matched cannot agree with anything.
    Assert 'A6b zip filename version matches its tag' $false
    Assert 'A6c zip link targets the same win-v release as the msi' $false
}
Assert 'A7 zip link is offered as the portable alternative' `
    ($html -match 'id="win-zip-link"[^>]*>\s*portable ZIP\s*</a>')

Assert 'A8 win-version label agrees with the msi link' `
    ($winVersion -ne '' -and $html -match ('<span id="win-version">v' + [regex]::Escape($winVersion) + '</span>'))

# Minimum-OS note. 1809 is the ConPTY floor the app actually requires
# (src/apprt/win32 targets it; see windows-parity-details.md).
Assert 'A9 minimum-OS note names the Windows floor' ($html -match 'Windows 10 1809\+')
Assert 'A10 minimum-OS note names the architecture' ($html -match '64-bit')

# The Windows artifacts are unsigned (no code-signing cert -- the macOS half
# is signed and notarized, which the page says two lines up). A download that
# trips "Windows protected your PC" with no warning on the page reads as
# broken, and a user who backs out of that dialog never runs Ghoztty. The
# portable ZIP's READ-ME-FIRST already says this (build-portable-zip.sh); the
# page is where a user reads it BEFORE downloading. T349.
$ssNote = [regex]::Match($html, '(?s)<p class="download-note" id="win-smartscreen-note">(.*?)</p>')
Assert 'A15 the page carries the unsigned/SmartScreen caveat' $ssNote.Success
if ($ssNote.Success) {
    $ssText = $ssNote.Groups[1].Value
    Assert 'A15b it names SmartScreen and the dialog wording' `
        ($ssText -match 'SmartScreen' -and $ssText -match 'Windows protected your PC')
    Assert 'A15c it says what to click' `
        ($ssText -match 'More info' -and $ssText -match 'Run anyway')
    # It must not claim the Windows build is signed -- the section header
    # says "signed and notarized on macOS" and this line is the other half.
    Assert 'A15d it says the build is not signed' ($ssText -match 'not code-signed|unsigned')
}
# Same design-system rule as A14: the caveat reuses .download-note rather
# than introducing a class of its own.
Assert 'A16 the caveat reuses the existing download-note class' `
    ($html -match 'class="download-note" id="win-smartscreen-note"')

# The Windows card must live in the SAME .download-cards container as the
# macOS one -- "alongside the existing platform links", not a section of its
# own further down the page.
$cardsBlock = [regex]::Match($html, '(?s)<div class="download-cards">(.*?)</div>\s*<p class="download-note">')
Assert 'A11 download-cards block found' $cardsBlock.Success
if ($cardsBlock.Success) {
    $cards = $cardsBlock.Groups[1].Value
    Assert 'A12 macOS dmg card is in it' ($cards -match 'Ghoztty-\d+\.\d+\.\d+-arm64\.dmg')
    Assert 'A13 windows msi card is in it' ($cards -match 'id="win-msi-link"')
}

# Design-system rule, applied to the site: reuse the existing vocabulary
# instead of inventing a class for the new card.
$newClasses = @('download-card', 'download-icon', 'download-info', 'download-action', 'download-note')
$missingClass = @()
foreach ($c in $newClasses) {
    if ($css -notmatch ('\.' + [regex]::Escape($c) + '[\s,{:]')) { $missingClass += $c }
}
AssertEq 'A14 the windows card reuses only existing CSS classes' 0 $missingClass.Count

"=== B. asset names agree across their three writers ==="

Assert 'B1 rewrite script MSI name is Ghoztty-<v>-x64.msi' `
    ($py -match 'MSI_NAME\s*=\s*"Ghoztty-\{v\}-x64\.msi"')
Assert 'B2 rewrite script ZIP name is Ghoztty-portable-<v>-x64.zip' `
    ($py -match 'ZIP_NAME\s*=\s*"Ghoztty-portable-\{v\}-x64\.zip"')
Assert 'B3 workflow publishes that MSI name' `
    ($wf -match 'MSI=zig-out/Ghoztty-\$VERSION-x64\.msi')
Assert 'B4 workflow publishes that ZIP name' `
    ($wf -match 'ZIP=zig-out/Ghoztty-portable-\$VERSION-x64\.zip')
Assert 'B5 workflow tag is win-v<version>' ($wf -match 'TAG=win-v\$VERSION')
Assert 'B6 shared build script produces the same names' `
    ($shared -match 'Ghoztty-\$\{?SEMVER' -or $shared -match 'Ghoztty-\$SEMVER' -or $shared -match 'Ghoztty-.*-x64\.msi')

"=== C. the rewrite script, run for real ==="

# Find an interpreter. On this box `python3` is the Microsoft Store alias
# (prints an ad and exits non-zero); CI has a real python3.
$interp = $null
foreach ($cand in @('python', 'python3', 'py')) {
    $v = & $cand --version 2>&1
    if ($LASTEXITCODE -eq 0 -and "$v" -match 'Python 3') { $interp = $cand; break }
}

if (-not $interp) {
    Skip 'C1-C7 rewrite script behavior' 'no python 3 interpreter on PATH'
} else {
    $work = Join-Path $env:TEMP ('ghoztty-t39-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $target = '9.9.9'
        $sample = Join-Path $work 'index.html'
        Copy-Item -LiteralPath $indexPath -Destination $sample

        $macBefore = [regex]::Matches($html, 'Ghoztty-\d+\.\d+\.\d+-arm64\.dmg') |
            ForEach-Object { $_.Value }

        $out1 = & $interp $pyPath $sample $target 2>&1
        $rc1 = $LASTEXITCODE
        AssertEq 'C1 rewrite exits 0' 0 $rc1

        $after = Get-Content -LiteralPath $sample -Raw
        Assert 'C2 msi link moved to the new release' `
            ($after -match ('id="win-msi-link"[^>]*?href="https://github\.com/dzearing/ghoztty/releases/download/win-v' + [regex]::Escape($target) + '/Ghoztty-' + [regex]::Escape($target) + '-x64\.msi"'))
        Assert 'C3 zip link moved to the new release asset' `
            ($after -match ('id="win-zip-link"[^>]*?href="https://github\.com/dzearing/ghoztty/releases/download/win-v' + [regex]::Escape($target) + '/Ghoztty-portable-' + [regex]::Escape($target) + '-x64\.zip"'))
        Assert 'C4 version label moved' `
            ($after -match ('<span id="win-version">v' + [regex]::Escape($target) + '</span>'))

        # The whole reason the script matches by element id.
        $macAfter = [regex]::Matches($after, 'Ghoztty-\d+\.\d+\.\d+-arm64\.dmg') |
            ForEach-Object { $_.Value }
        AssertEq 'C5 macOS dmg link is untouched' ($macBefore -join ',') ($macAfter -join ',')

        # Idempotent: a re-run must not churn the file (the workflow diffs
        # before committing, and a no-op commit on every release is noise).
        $out2 = & $interp $pyPath $sample $target 2>&1
        $rc2 = $LASTEXITCODE
        $after2 = Get-Content -LiteralPath $sample -Raw
        AssertEq 'C6 second run exits 0' 0 $rc2
        Assert 'C6b second run says nothing to do' ("$out2" -match 'nothing to do')
        AssertEq 'C6c second run changed nothing' $after $after2

        # A page it cannot find an anchor in must FAIL, not quietly succeed.
        $broken = Join-Path $work 'broken.html'
        ($html -replace 'id="win-msi-link"', 'id="win-msi-link-renamed"') |
            Set-Content -LiteralPath $broken -Encoding UTF8
        $out3 = & $interp $pyPath $broken $target 2>&1
        $rc3 = $LASTEXITCODE
        Assert 'C7 missing anchor is an error, not a silent no-op' ($rc3 -ne 0)
        Assert 'C7b and it says which id it could not find' ("$out3" -match 'win-msi-link')

        # A bad version must be rejected before it reaches the page.
        $out4 = & $interp $pyPath $sample 'v9.9.9' 2>&1
        Assert 'C8 leading-v version is rejected' ($LASTEXITCODE -ne 0)
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

"=== D. release wiring ==="

Assert 'D1 workflow updates the site through the publish script' `
    ($wf -match 'dist/website/publish-windows-links\.sh')
Assert 'D1b the publish script is what calls the rewrite script' `
    ($pub -match 'update-windows-links\.py')
Assert 'D2 the website step is gated on PUBLISH' `
    ($wf -match "(?s)Update website Windows download links.*?if:\s*env\.PUBLISH == 'true'")
# Ordering matters: links must never precede the assets they point at.
$iPublish = $wf.IndexOf('Publish win-v release')
$iWeb     = $wf.IndexOf('Update website Windows download links')
Assert 'D3 the website step runs after the publish step' `
    ($iPublish -ge 0 -and $iWeb -gt $iPublish)
Assert 'D4 windows gh-pages push retries on rejection' `
    ($pub -match 'git pull --rebase origin gh-pages')
Assert 'D5 mac appcast push retries on rejection too' `
    ($macWf -match 'git pull --rebase origin gh-pages')
Assert 'D6 both writers target the gh-pages branch' `
    (($pub -match 'clone --branch gh-pages') -and ($macWf -match 'clone --branch gh-pages'))
# The workflow invokes the script directly (not `bash script`), so a file that
# lost its executable bit is a release that dies at the last step. git's index
# mode is the one that travels to the runner; the working-tree bit on this box
# is not.
$pubMode = ''
Push-Location $Repo
try { $pubMode = (& git ls-files -s -- 'dist/website/publish-windows-links.sh' 2>$null) } finally { Pop-Location }
Assert 'D6b the publish script is executable in the index (100755)' `
    ("$pubMode" -match '^100755\s')

# T577. The workflow was correct for two weeks and had still never run once,
# because a workflow runs from the tree of the ref that triggered it and the
# only trigger was `v*` -- a tag cut from main, which carries neither this
# file nor the win32 apprt it builds. So the wiring check is not "does the
# file exist", it is "is there a tag shape THIS tree can be tagged with that
# reaches this workflow", plus "does the version parse survive that shape".
$tagBlock = ''
if ($wf -match '(?s)on:\s*\r?\n\s*push:\s*\r?\n(.*?)\r?\n\s*workflow_dispatch:') { $tagBlock = $Matches[1] }
Assert 'D7 workflow triggers on a tag the windows branch can carry (win-v*)' `
    ($tagBlock -match '(?m)^\s*-\s*"win-v\*"\s*$')
Assert 'D8 workflow still triggers on v* for after the merge-back' `
    ($tagBlock -match '(?m)^\s*-\s*"v\*"\s*$')
# A win-v tag must parse to a bare X.Y.Z or the version regex rejects it and
# the release dies on a version that was never malformed.
Assert 'D9 the version parse strips the win- prefix before the v' `
    ($wf -match '(?s)VERSION=\$\{TAG_NAME#win-\}.*?VERSION=\$\{VERSION#v\}')
# What the workflow builds has to be present in the same tree as the
# workflow, which is the whole point of D7.
Assert 'D10 this tree carries the win32 apprt the workflow builds' `
    (Test-Path -LiteralPath (Join-Path $Repo 'src\apprt\win32'))

"=== E. the links answer (live) ==="

function Test-Url($url) {
    try {
        # HEAD first; GitHub's asset redirect answers HEAD fine. -MaximumRedirection
        # default follows to the S3 blob.
        $r = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 25
        return [int]$r.StatusCode
    } catch {
        $resp = $_.Exception.Response
        if ($resp -ne $null) { return [int]$resp.StatusCode }
        return -1
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$online = (Test-Url 'https://github.com') -eq 200

if (-not $online) {
    Skip 'E1-E2 live link checks' 'github.com unreachable'
} else {
    $codeMsi = Test-Url $msiHref
    AssertEq "E1 msi link answers 200 ($msiHref)" 200 $codeMsi
    $codeZip = Test-Url $zipHref
    AssertEq "E2 portable-zip link answers 200 ($zipHref)" 200 $codeZip
}

"=== F. the in-repo mirror matches the deployed page ==="

Push-Location $Repo
try {
    $live = & git show origin/gh-pages:index.html 2>$null
    $haveLive = ($LASTEXITCODE -eq 0 -and $live -ne $null)
} catch {
    $haveLive = $false
}
Pop-Location

if (-not $haveLive) {
    Skip 'F1 mirror == deployed gh-pages index.html' 'origin/gh-pages not fetched'
} else {
    # Compare line-by-line so a CRLF/LF checkout difference is not a failure.
    $liveText   = ($live -join "`n").TrimEnd()
    $mirrorText = (($html -split "`r?`n") -join "`n").TrimEnd()
    if ($liveText -ceq $mirrorText) {
        "  PASS F1 mirror == deployed gh-pages index.html"
    } else {
        "  FAIL F1 mirror != deployed gh-pages index.html (the mirror has drifted twice before; sync it)"
        $script:failures++
        $lm = ($mirrorText -split "`n")
        $ll = ($liveText -split "`n")
        $n = [Math]::Max($lm.Count, $ll.Count)
        $shown = 0
        for ($i = 0; $i -lt $n -and $shown -lt 6; $i++) {
            $a = if ($i -lt $lm.Count) { $lm[$i] } else { '<eof>' }
            $b = if ($i -lt $ll.Count) { $ll[$i] } else { '<eof>' }
            if ($a -cne $b) {
                "       line $($i + 1):"
                "         mirror: $a"
                "         live  : $b"
                $shown++
            }
        }
    }
}

"=== G. the publish script, run for real against a staged collision ==="

# T353. Everything above is text-matching. This section RUNS
# dist/website/publish-windows-links.sh end to end against bare repos on
# disk -- and, on purpose, makes its push lose the race the way release.yml's
# concurrent appcast push makes it lose one during a real release. That retry
# loop is dead code on a normal run, so before this section the first
# execution of it would have been the first release that needed it, with a
# broken download page as the way anyone found out.
#
# The collision is staged with a pre-push hook planted through GIT_TEMPLATE_DIR
# (the fresh clone the script makes picks it up): on the first push, a rival
# clone commits appcast.xml and pushes it first, so our push is rejected
# non-fast-forward exactly as a real appcast push would reject it.

function Get-BashPath {
    foreach ($p in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $cand = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}
function ConvertTo-MsysPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLower() + $Matches[2] }
    return $p
}
# The script calls `python3`, which is what ubuntu-latest has and what this box
# does not (the Store alias prints an ad and exits non-zero). A one-line shim on
# PATH lets the UNMODIFIED script run here -- so what is exercised is the exact
# command line CI runs, not a special-cased one.
function New-Python3Shim([string]$WorkDir, [string]$Interp) {
    $exe = (Get-Command $Interp -ErrorAction SilentlyContinue)
    if (-not $exe) { return $null }
    $shimDir = Join-Path $WorkDir 'shim'
    New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
    $body = "#!/bin/sh`nexec `"" + (ConvertTo-MsysPath $exe.Source) + "`" `"`$@`"`n"
    [IO.File]::WriteAllText((Join-Path $shimDir 'python3'), $body, (New-Object Text.UTF8Encoding $false))
    return $shimDir
}

$bash = Get-BashPath
if (-not $bash) {
    Skip 'G1-G12 publish script behavior' 'no Git Bash on this box'
} elseif (-not $interp) {
    Skip 'G1-G12 publish script behavior' 'no python 3 interpreter on PATH'
} else {
    $g = Join-Path $env:TEMP ('ghoztty-t353-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $g -Force | Out-Null
    $savedPath = $env:PATH
    try {
        $gu       = ConvertTo-MsysPath $g
        $originW  = Join-Path $g 'origin.git'
        $brokenW  = Join-Path $g 'origin-broken.git'
        $shimDir  = New-Python3Shim $g $interp
        if ($shimDir) { $env:PATH = "$shimDir;$savedPath" }

        # -- fixture: a bare gh-pages with the real page on it, a second bare
        #    one whose page is missing the anchor, and a rival clone to push
        #    the colliding commit from.
        $setup = @'
#!/bin/sh
set -e
W="$1"; SRC_INDEX="$2"
export GIT_AUTHOR_NAME=harness GIT_AUTHOR_EMAIL=harness@example.invalid
export GIT_COMMITTER_NAME=harness GIT_COMMITTER_EMAIL=harness@example.invalid
cd "$W"
git init -q --bare origin.git
git init -q --bare origin-broken.git
git init -q seed
cd seed
git checkout -q -b gh-pages
cp "$SRC_INDEX" index.html
printf '<rss>appcast base</rss>\n' > appcast.xml
git add index.html appcast.xml
git commit -qm "base"
git remote add origin "$W/origin.git"
git push -q origin gh-pages
sed 's/id="win-msi-link"/id="win-msi-link-renamed"/' index.html > broken.html
mv broken.html index.html
git add index.html
git commit -qm "page with no windows anchor"
git remote add broken "$W/origin-broken.git"
git push -q broken gh-pages
cd "$W"
git clone -q --branch gh-pages --single-branch "$W/origin.git" rival
echo SETUP-OK
'@
        $hook = @'
#!/bin/sh
# The concurrent appcast push, staged. Fires once unless RIVAL_ALWAYS=1.
if [ "${RIVAL_ALWAYS:-0}" != "1" ]; then
    [ -e "$RIVAL_MARKER" ] && exit 0
    : > "$RIVAL_MARKER"
fi
{
    # The rival has to be CURRENT to win the race -- a rejected rival push is
    # no collision at all, and it would leave our push succeeding on attempt 1
    # while the assertions below read as a broken retry.
    git -C "$RIVAL" fetch -q origin gh-pages
    git -C "$RIVAL" reset -q --hard FETCH_HEAD
    printf '<rss>appcast %s</rss>\n' "$(date +%s)-$$" > "$RIVAL/appcast.xml"
    git -C "$RIVAL" add appcast.xml
    git -C "$RIVAL" -c user.name=rival -c user.email=rival@example.invalid \
        commit -qm "appcast push racing the website update"
    git -C "$RIVAL" push origin gh-pages
} >> "$RIVAL_LOG" 2>&1
echo "hook rc=$? at $(date +%s)" >> "$RIVAL_LOG"
# Always 0: this hook stages a race, it does not veto the push. A rival that
# could not push must let our push SUCCEED, so a broken fixture reads as
# "the retry was never exercised" rather than as a passing retry test.
exit 0
'@
        $setupPath = Join-Path $g 'setup.sh'
        [IO.File]::WriteAllText($setupPath, ($setup -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        $tmplHooks = Join-Path $g 'tmpl\hooks'
        New-Item -ItemType Directory -Path $tmplHooks -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tmplHooks 'pre-push'), ($hook -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))

        $setupOut = & $bash (ConvertTo-MsysPath $setupPath) "$gu" (ConvertTo-MsysPath $indexPath) 2>&1
        if ("$setupOut" -notmatch 'SETUP-OK') {
            Assert "G0 fixture repos built ($setupOut)" $false
        } else {
            $pubU = ConvertTo-MsysPath $pubPath
            # git.exe reads these out of the environment, and MSYS does not
            # path-convert environment variables the way it converts argv --
            # so they are drive-letter paths with forward slashes, which both
            # bash and native git resolve.
            $gw = $g -replace '\\', '/'
            $rivalLog = Join-Path $g 'rival.log'
            $env:WEBSITE_PUSH_BACKOFF = '0'   # the loop's sleep, not its logic
            $env:RIVAL = "$gw/rival"
            $env:RIVAL_MARKER = "$gw/collided.once"
            $env:RIVAL_LOG = "$gw/rival.log"

            function Invoke-Publish($originPath, $version, $clone) {
                $out = & $bash $pubU $originPath $version "$gu/$clone" 2>&1
                return [pscustomobject]@{ Out = ("$out"); Code = $LASTEXITCODE }
            }
            function GhPages($repo, $file) {
                $t = & git -C $repo show "gh-pages:$file" 2>$null
                return ($t -join "`n")
            }
            function CommitCount($repo) {
                return [int](& git -C $repo rev-list --count gh-pages 2>$null)
            }

            # -- G1: the ordinary path. Clone, rewrite, commit, push, first try.
            $r1 = Invoke-Publish "$gu/origin.git" '9.9.9' 'clone1'
            AssertEq 'G1 publish exits 0 on an uncontended push' 0 $r1.Code
            Assert 'G1b it says which attempt succeeded' ($r1.Out -match 'website updated \(attempt 1\)')
            $page1 = GhPages $originW 'index.html'
            Assert 'G2 gh-pages now offers win-v9.9.9' ($page1 -match 'win-v9\.9\.9')
            Assert 'G2b and the macOS download is untouched' ($page1 -match 'arm64\.dmg')
            $countAfter1 = CommitCount $originW

            # -- G3: same version again. A republish must not pile empty
            #    commits onto the branch.
            $r2 = Invoke-Publish "$gu/origin.git" '9.9.9' 'clone2'
            AssertEq 'G3 a second run for the same version exits 0' 0 $r2.Code
            Assert 'G3b and says the site is already current' ($r2.Out -match 'already current')
            AssertEq 'G3c and pushed nothing' $countAfter1 (CommitCount $originW)

            # -- G4: THE POINT OF THIS SECTION. A rival push lands between our
            #    clone and our push; the retry must rebase and win.
            $env:GIT_TEMPLATE_DIR = "$gw/tmpl"
            $r3 = Invoke-Publish "$gu/origin.git" '9.9.10' 'clone3'
            Remove-Item Env:\GIT_TEMPLATE_DIR -ErrorAction SilentlyContinue
            AssertEq 'G4 publish still exits 0 when its push is rejected' 0 $r3.Code
            Assert 'G4b the rejection was real (attempt 1 lost)' `
                ($r3.Out -match 'push rejected \(attempt 1\)')
            Assert 'G4c the rebase-retry then landed it' `
                ($r3.Out -match 'website updated \(attempt 2\)')
            $page2 = GhPages $originW 'index.html'
            Assert 'G5 gh-pages carries the new version after the retry' `
                ($page2 -match 'win-v9\.9\.10')
            # The half a force-push would have destroyed: the concurrent
            # writer's file must survive, which is why this is a rebase.
            Assert 'G5b and the rival appcast push survived the retry' `
                ((GhPages $originW 'appcast.xml') -match 'appcast \d')

            # -- G6: retries are bounded. Losing every race must fail loudly
            #    rather than spin, and must leave the branch as it was.
            $env:GIT_TEMPLATE_DIR = "$gw/tmpl"
            $env:RIVAL_ALWAYS = '1'
            $env:WEBSITE_PUSH_ATTEMPTS = '2'
            $r4 = Invoke-Publish "$gu/origin.git" '9.9.11' 'clone4'
            Remove-Item Env:\GIT_TEMPLATE_DIR -ErrorAction SilentlyContinue
            Remove-Item Env:\RIVAL_ALWAYS -ErrorAction SilentlyContinue
            Remove-Item Env:\WEBSITE_PUSH_ATTEMPTS -ErrorAction SilentlyContinue
            Assert 'G6 losing every race fails' ($r4.Code -ne 0)
            Assert 'G6b and says so as a workflow error' `
                ($r4.Out -match 'could not push the website update after 2 attempts')
            Assert 'G6c and the page was left at the last version that landed' `
                ((GhPages $originW 'index.html') -match 'win-v9\.9\.10')

            # -- G7: a page the rewrite cannot retarget must fail the step,
            #    not report success over an unchanged site (T214/T303 shape).
            $r5 = Invoke-Publish "$gu/origin-broken.git" '9.9.9' 'clone5'
            Assert 'G7 a page with no windows anchor fails the publish' ($r5.Code -ne 0)
            Assert 'G7b and nothing was committed to that branch' `
                ((CommitCount $brokenW) -eq 2)

            # -- G8: called wrong is a usage error, not a mystery.
            $out6 = & $bash $pubU 2>&1
            $code6 = $LASTEXITCODE
            AssertEq 'G8 no arguments exits 2' 2 $code6
            Assert 'G8b and prints usage' ("$out6" -match 'usage: publish-windows-links\.sh')
        }
    } finally {
        $env:PATH = $savedPath
        foreach ($v in @('WEBSITE_PUSH_BACKOFF', 'WEBSITE_PUSH_ATTEMPTS', 'RIVAL', 'RIVAL_MARKER',
                         'RIVAL_ALWAYS', 'RIVAL_LOG', 'GIT_TEMPLATE_DIR')) {
            Remove-Item ("Env:\" + $v) -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $g -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A clean green run stamps the files this harness covers (T783), so an edit to
# the publish script or the rewrite script reads as DUE until someone runs this
# again. Sections E and F need the network and SKIP without it; they cover
# neither script, so a skip there must not withhold the stamp -- the T898
# lesson about a bar that can never be met on this box.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard website-windows-links -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:skipped -gt 0) { "$($script:skipped) SKIPPED" }
if ($script:failures -eq 0) { "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
