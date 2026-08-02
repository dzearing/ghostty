#!/usr/bin/env python3
"""Point the landing page's Windows downloads at a win-v<version> release.

The macOS half of the site is hand-edited at release time (Step 7 of
.claude/commands/release.md). The Windows half is not: release-windows.yml
runs this on the same tag push that publishes the win-v release, so the site
can never advertise a Windows build that does not exist yet -- which is the
exact failure T38 fixed on the artifact side (the Mac channel reached v1.28.0
while Windows sat at win-v1.4.1 because the Windows step needed a human).

Three things move, and they are found by their element id rather than by
matching a version number anywhere in the page. That is deliberate: a regex
loose enough to find "the version" also finds Ghoztty-1.28.0-arm64.dmg and
would silently retarget the macOS download at a Windows tag.

A missing anchor is an ERROR, not a no-op. A rewrite that matches nothing and
exits 0 is the "empty rather than absent" failure this repo keeps paying for
(T214, T303): the release reports success and the site never moves.

  python3 dist/website/update-windows-links.py <index.html> <X.Y.Z>
"""

import re
import sys

REPO_URL = "https://github.com/dzearing/ghoztty"

# The published asset names. These MUST match the names
# .github/workflows/release-windows.yml publishes and
# dist/windows-installer/build-release-artifacts.sh produces -- version and
# arch in the filename, per T38. test/win32/website-windows-download.ps1
# asserts all three agree.
MSI_NAME = "Ghoztty-{v}-x64.msi"
ZIP_NAME = "Ghoztty-portable-{v}-x64.zip"


def asset_url(version, name):
    return "{r}/releases/download/win-v{v}/{n}".format(
        r=REPO_URL, v=version, n=name.format(v=version)
    )


def replace_href(html, element_id, url):
    """Retarget the href of the one element carrying `element_id`.

    `[^>]*?` keeps the match inside a single start tag, so this cannot walk
    across elements the way a `.*?` would.
    """
    pattern = re.compile(
        r'(id="' + re.escape(element_id) + r'"[^>]*?href=")[^"]*(")'
    )
    html, n = pattern.subn(lambda m: m.group(1) + url + m.group(2), html)
    if n != 1:
        raise SystemExit(
            "error: expected exactly 1 element with id={0!r} and an href, "
            "found {1}. The landing page changed shape; fix this script "
            "rather than shipping a release whose site never moved.".format(
                element_id, n
            )
        )
    return html


def replace_text(html, element_id, text):
    pattern = re.compile(
        r'(<span id="' + re.escape(element_id) + r'"[^>]*>)[^<]*(</span>)'
    )
    html, n = pattern.subn(lambda m: m.group(1) + text + m.group(2), html)
    if n != 1:
        raise SystemExit(
            "error: expected exactly 1 <span id={0!r}>, found {1}.".format(
                element_id, n
            )
        )
    return html


def update(html, version):
    html = replace_href(html, "win-msi-link", asset_url(version, MSI_NAME))
    html = replace_href(html, "win-zip-link", asset_url(version, ZIP_NAME))
    html = replace_text(html, "win-version", "v" + version)
    return html


def main(argv):
    if len(argv) != 3:
        raise SystemExit("usage: update-windows-links.py <index.html> <X.Y.Z>")
    path, version = argv[1], argv[2]
    if not re.match(r"^\d+\.\d+\.\d+$", version):
        raise SystemExit(
            "error: version must be X.Y.Z with no leading v (got {0!r})".format(
                version
            )
        )

    with open(path, "r", encoding="utf-8", newline="") as f:
        before = f.read()

    after = update(before, version)

    if after == before:
        print("website already points at win-v" + version + "; nothing to do")
        return 0

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(after)
    print("website Windows downloads -> win-v" + version)
    print("  msi: " + asset_url(version, MSI_NAME))
    print("  zip: " + asset_url(version, ZIP_NAME))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
