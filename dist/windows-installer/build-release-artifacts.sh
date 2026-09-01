#!/usr/bin/env bash
# build-release-artifacts.sh -- produce the full set of Windows release
# artifacts for one version (T38).
#
# This is the single definition of "what a Windows release ships", shared by
# the two callers that ship it:
#
#   * .github/workflows/release-windows.yml -- fires on the same vX.Y.Z tag
#     push that builds the macOS DMG, so one release produces both
#     platforms' artifacts at the same version.
#   * scripts/publish-windows-release.ps1 -- the on-box manual path
#     (cross-checks and publishes from the Windows machine).
#
# Both end up with byte-identical artifact SETS because the layout, the
# names, and the build flags live here and nowhere else.
#
# Produces, in --out-dir (default zig-out):
#   Ghoztty-<semver>-x64.msi           per-user installer (build-msi.sh)
#   Ghoztty-portable-<semver>-x64.zip  no-installer layout (build-portable-zip.sh)
#
# Usage:
#   dist/windows-installer/build-release-artifacts.sh --semver <X.Y.Z>
#       [--build-num <N>] [--stamp <s>] [--out-dir <dir>] [--skip-build]
#
#   --skip-build  reuse zig-out/bin/ghoztty.exe + zig-out/share. The exe
#                 must ALREADY carry -Dversion-string=<semver>+<hash> (the
#                 on-box script builds natively on Windows, then packages
#                 here); this script verifies that rather than assuming it.
#
# Requires: wixl + msiinfo + python3 (packaging), and zig unless
# --skip-build. Everything runs on Linux/macOS -- no Windows box needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

SEMVER=""
BUILD_NUM=1
STAMP=""
OUT_DIR=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --semver)      SEMVER="${2:?--semver needs a value}"; shift 2 ;;
    --semver=*)    SEMVER="${1#*=}"; shift ;;
    --build-num)   BUILD_NUM="${2:?--build-num needs a value}"; shift 2 ;;
    --build-num=*) BUILD_NUM="${1#*=}"; shift ;;
    --stamp)       STAMP="${2:?--stamp needs a value}"; shift 2 ;;
    --stamp=*)     STAMP="${1#*=}"; shift ;;
    --out-dir)     OUT_DIR="${2:?--out-dir needs a value}"; shift 2 ;;
    --out-dir=*)   OUT_DIR="${1#*=}"; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    -h|--help)     sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SEMVER" ]] || { echo "error: --semver <X.Y.Z> is required" >&2; exit 2; }
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: --semver must be X.Y.Z (got '$SEMVER')" >&2; exit 2; }

cd "$REPO_ROOT"
HASH="$(git rev-parse --short HEAD)"
[[ -n "$STAMP" ]] || STAMP="$(date +%Y%m%d)-$HASH"
[[ -n "$OUT_DIR" ]] || OUT_DIR="$REPO_ROOT/zig-out"
mkdir -p "$OUT_DIR"

MSI="$OUT_DIR/Ghoztty-$SEMVER-x64.msi"
ZIP="$OUT_DIR/Ghoztty-portable-$SEMVER-x64.zip"

# The FILEVERSION rule lives in build-msi.sh; ask for it (see its
# --print-file-version) instead of keeping a second copy of the formula.
FILE_VERSION="$(bash "$SCRIPT_DIR/build-msi.sh" --print-file-version --build-num "$BUILD_NUM")"

echo "== windows release artifacts: $SEMVER+$HASH (stamp $STAMP, FILEVERSION $FILE_VERSION) =="

# -- 1. the exe ----------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  command -v zig >/dev/null || { echo "error: zig not found (needed without --skip-build)" >&2; exit 1; }
  echo "==> zig build (ReleaseFast, x86_64-windows-gnu, win32 apprt)"
  # -Dwindows-update-check=true: only channel builds phone home (T24).
  # -Dagent-semver: the agent sibling's VERSIONINFO matches the tag (T89h).
  # -Dstrip=false: a stripped release produces undebuggable crash dumps --
  # the same reason the on-box delivery build carries it (CLAUDE.md).
  # The public Google OAuth client id, baked so a SHIPPED build can start the
  # relay-brokered sign-in (T795). release.yml's macOS job has passed this from
  # the same GOOGLE_CLIENT_ID secret since T93; the Windows path never did, so
  # every published MSI and portable ZIP shipped with sign-in unavailable while
  # the DMG beside it worked. The confidential client secret lives only on the
  # relay and never here - this id is public and appears in the browser URL.
  #
  # Passed only when non-empty, and that is load-bearing: an explicit
  # `-Dgoogle-client-id=""` SATISFIES the build option and so short-circuits
  # src/build/Config.zig's fallback to a git-ignored google-client-id.txt, which
  # is how a developer's on-box release build gets one (D72). A fork with no
  # secret configured must still build, so an absent id is a loud note rather
  # than an error.
  GOOGLE_CLIENT_ID_ARGS=()
  if [[ -n "${GOOGLE_CLIENT_ID:-}" ]]; then
    GOOGLE_CLIENT_ID_ARGS+=("-Dgoogle-client-id=$GOOGLE_CLIENT_ID")
    echo "    relay sign-in: baking the client id from \$GOOGLE_CLIENT_ID"
  else
    echo "    relay sign-in: NO \$GOOGLE_CLIENT_ID in the environment;" \
      "falling back to google-client-id.txt if this tree has one, else this" \
      "build ships with sign-in unavailable"
  fi
  zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
    -Dstrip=false \
    "-Dwindows-file-version=$FILE_VERSION" \
    "-Dversion-string=$SEMVER+$HASH" \
    "-Dagent-semver=$SEMVER" \
    "-Dwindows-update-check=true" \
    "${GOOGLE_CLIENT_ID_ARGS[@]+"${GOOGLE_CLIENT_ID_ARGS[@]}"}"
fi

EXE="$REPO_ROOT/zig-out/bin/ghoztty.exe"
[[ -f "$EXE" ]] || { echo "error: $EXE not found" >&2; exit 1; }

# The exe must carry the release semver: it is what the in-app update check
# compares against the win-v<semver> tag (T24), and under --skip-build it is
# the only thing standing between a stale zig-out and a mislabelled release.
# Scanned out of the binary rather than executed, so this works on a Linux
# CI runner where the exe cannot run at all.
python3 - "$EXE" "$SEMVER+$HASH" <<'PYEOF'
import sys
exe, want = sys.argv[1], sys.argv[2]
data = open(exe, "rb").read()
needle = want.encode("utf-8")
if needle not in data and needle.decode().encode("utf-16-le") not in data:
    sys.exit(f"error: {exe} does not embed version string {want} "
             "(stale zig-out, or the build lost -Dversion-string)")
print(f"==> exe embeds {want}")
PYEOF

# -- 1b. sign the payload ------------------------------------------------
# Before the packages are cut, not after: the MSI and the portable ZIP are
# both built FROM these three files, so signing them here is what makes both
# packages carry signed bits. Signing only the MSI wrapper would leave every
# portable-ZIP user, and every exe the MSI lays down, exactly as unknown to
# SmartScreen as before (T1203).
#
# ghoztty.com carries ghoztty.exe's identity as the console twin, and the
# agent is a required sibling the installer runs on its own, so all three are
# in scope. Absent certificate config is a no-op with a banner -- see the
# script.
bash "$SCRIPT_DIR/sign-artifacts.sh" \
  "$REPO_ROOT/zig-out/bin/ghoztty.exe" \
  "$REPO_ROOT/zig-out/bin/ghoztty.com" \
  "$REPO_ROOT/zig-out/bin/ghoztty-agent.exe" || exit 1

# -- 2. MSI + portable ZIP ----------------------------------------------
echo "==> MSI"
bash "$SCRIPT_DIR/build-msi.sh" --skip-build \
  --semver "$SEMVER" --build-num "$BUILD_NUM" --version "$STAMP" --out "$MSI"

# The MSI is signed as a package in its own right, on top of the signed
# payload above: it is the file the user downloads and double-clicks, so it
# is the one SmartScreen judges. The portable ZIP has no Authenticode
# equivalent -- a zip cannot be signed -- which is why the three binaries
# inside it were signed before it was built.
bash "$SCRIPT_DIR/sign-artifacts.sh" "$MSI" || exit 1

echo "==> portable ZIP"
bash "$SCRIPT_DIR/build-portable-zip.sh" \
  --semver "$SEMVER" --stamp "$STAMP" --out "$ZIP"

# -- 3. report ------------------------------------------------------------
for f in "$MSI" "$ZIP"; do
  [[ -f "$f" ]] || { echo "error: $f missing after build" >&2; exit 1; }
done
echo ""
echo "== windows release artifacts for $SEMVER =="
ls -lh "$MSI" "$ZIP" | sed 's/^/    /'
