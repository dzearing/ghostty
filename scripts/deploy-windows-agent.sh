#!/usr/bin/env bash
# Build the Windows ghoztty-agent.exe and atomically drop it on the share, where
# the Windows-side watcher (ghoztty-agent-watcher.ps1) hot-swaps it into the
# running agent. This is the "remove the human from the deploy loop" path.
#
#   ./scripts/deploy-windows-agent.sh
set -euo pipefail

export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SHARE="/Volumes/share/ghoztty-windows"
TARGET="${1:-x86_64-windows-gnu}"

cd "$REPO"
echo "==> building ghoztty-agent.exe ($TARGET)"
zig build agent -Dtarget="$TARGET"

if [ ! -d "$SHARE" ]; then
  echo "ERROR: $SHARE not mounted — cannot deploy." >&2
  exit 1
fi

SRC="$REPO/zig-out/bin/ghoztty-agent.exe"
HASH="$(shasum -a 256 "$SRC" | cut -c1-12)"
echo "==> deploying build $HASH -> $SHARE/ghoztty-agent.exe (atomic)"
# Atomic replace: copy to a temp on the same filesystem, then rename, so the
# watcher never reads a half-written file.
cp "$SRC" "$SHARE/.ghoztty-agent.exe.tmp"
mv -f "$SHARE/.ghoztty-agent.exe.tmp" "$SHARE/ghoztty-agent.exe"
echo "==> done. build $HASH live on the share; watcher will hot-swap within a few seconds."
