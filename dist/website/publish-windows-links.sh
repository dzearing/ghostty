#!/usr/bin/env bash
#
# Retarget the site's Windows download links at a release that was just
# published, and push the result to gh-pages (T39, extracted by T353).
#
# WHY THIS IS A SCRIPT AND NOT SIX MORE LINES OF YAML. Everything here used to
# live inline in `.github/workflows/release-windows.yml`, where the only thing
# that could ever run it was a real release -- and the interesting half is the
# retry loop at the bottom, which does not execute even then unless
# release.yml's appcast push happens to land on gh-pages first. So the one
# path whose failure would break a release was the one path nobody could
# exercise: "dead code on a normal run, and the first time it matters is the
# first time it is needed" (T353). As a file it can be run against a local
# bare repo with a collision staged deliberately, which is what section G of
# test\win32\website-windows-download.ps1 does on every run of that harness.
#
# Usage:
#   publish-windows-links.sh <gh-pages-repo-url> <X.Y.Z> [workdir]
#
# The repo url is anything `git clone` accepts -- in CI an
# https://x-access-token:...@github.com/... url, in the harness a path to a
# bare repo on disk. `workdir` defaults to a fresh mktemp -d; when it is given
# it is REPLACED, so a re-run in CI's fixed /tmp/gh-pages cannot half-reuse a
# previous clone.
#
# Environment:
#   PYTHON                  interpreter for update-windows-links.py (default
#                           python3, which is what ubuntu-latest has).
#   WEBSITE_PUSH_ATTEMPTS   how many times to try the push (default 5).
#   WEBSITE_PUSH_BACKOFF    seconds multiplied by the attempt number between
#                           tries (default 3; the harness sets 0 so proving
#                           the loop does not cost 45 seconds).
#
# Exit codes: 0 pushed, or already current. 1 could not push / rebase failed.
# 2 called wrong. Anything the rewrite script exits is propagated as-is -- a
# missing anchor is an error there and must stay an error here.
set -uo pipefail

REPO_URL="${1:-}"
VERSION="${2:-}"
WORKDIR="${3:-}"

if [ -z "$REPO_URL" ] || [ -z "$VERSION" ]; then
    echo "usage: publish-windows-links.sh <gh-pages-repo-url> <X.Y.Z> [workdir]" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON:-python3}"
ATTEMPTS="${WEBSITE_PUSH_ATTEMPTS:-5}"
BACKOFF="${WEBSITE_PUSH_BACKOFF:-3}"

if [ -z "$WORKDIR" ]; then
    WORKDIR="$(mktemp -d)"
else
    rm -rf "$WORKDIR"
fi

git clone --branch gh-pages --single-branch "$REPO_URL" "$WORKDIR" || exit 1

"$PY" "$SCRIPT_DIR/update-windows-links.py" "$WORKDIR/index.html" "$VERSION"
rc=$?
if [ "$rc" -ne 0 ]; then exit "$rc"; fi

cd "$WORKDIR" || exit 1

# Nothing to say is a success, not a commit. Re-running a release (or a
# republish of the same version) must not pile empty commits onto the branch.
if git diff --quiet -- index.html; then
    echo "website already current for win-v$VERSION"
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add index.html
git commit -m "Update website Windows download to win-v${VERSION}" || exit 1

# release.yml pushes appcast.xml to this same branch on this same tag push, so
# a plain push loses a coin flip roughly half the time. Rebase and retry
# rather than failing a release over it.
attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    if git push origin gh-pages; then
        echo "website updated (attempt $attempt)"
        exit 0
    fi
    echo "push rejected (attempt $attempt) -- rebasing onto origin/gh-pages"
    if ! git pull --rebase origin gh-pages; then
        echo "::error::rebase onto origin/gh-pages failed (attempt $attempt)" >&2
        exit 1
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ] && [ "$BACKOFF" -gt 0 ]; then
        sleep $(( attempt * BACKOFF ))
    fi
    attempt=$(( attempt + 1 ))
done

echo "::error::could not push the website update after $ATTEMPTS attempts"
exit 1
