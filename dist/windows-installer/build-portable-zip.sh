#!/usr/bin/env bash
# build-portable-zip.sh -- package the portable Windows ZIP for the Ghoztty
# terminal (T38).
#
# The portable ZIP is the no-installer counterpart of the MSI: the SAME
# payload (ghoztty.exe + ghoztty.com + ghoztty-agent.exe + the share/ resource
# tree) laid out under a single top-level "Ghoztty" folder, so unzipping
# anywhere and double-clicking ghoztty.exe works. The layout must match the
# MSI's INSTALLDIR exactly -- src/os/resourcesdir.zig climbs from the exe to
# share/terminfo, and the session-persistence agent is spawned by relative
# location (T89h).
#
# ghoztty.com is the console-subsystem twin (T245, src/cli/com_shim.zig): the
# same image with one word of the PE optional header flipped. PATHEXT resolves
# .COM ahead of .EXE, so it is the binary a shell actually runs, and without it
# `ghoztty +list` from PowerShell prints nothing and redirects write 0 bytes --
# a windowed program is not waited for. Both released artifacts shipped without
# it until T1052, so every downloaded install had a dead command line.
#
# Usage:
#   dist/windows-installer/build-portable-zip.sh --semver <X.Y.Z>
#       [--stamp <build-stamp>] [--out <path>]
#
# Defaults:
#   stamp  $(date +%Y%m%d)-$(git rev-parse --short HEAD)
#   out    zig-out/Ghoztty-portable-<semver>-x64.zip
#
# Requires: python3 (zipfile -- no `zip` binary needed, so this runs
# unchanged on a CI runner, on macOS, and inside the msitools Docker image
# the on-box publish script already uses).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

SEMVER=""
STAMP=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --semver)    SEMVER="${2:?--semver needs a value}"; shift 2 ;;
    --semver=*)  SEMVER="${1#*=}"; shift ;;
    --stamp)     STAMP="${2:?--stamp needs a value}"; shift 2 ;;
    --stamp=*)   STAMP="${1#*=}"; shift ;;
    --out)       OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*)     OUT="${1#*=}"; shift ;;
    -h|--help)   sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }
[[ -n "$SEMVER" ]] || { echo "error: --semver <X.Y.Z> is required" >&2; exit 2; }
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: --semver must be X.Y.Z (got '$SEMVER')" >&2; exit 2; }

cd "$REPO_ROOT"

EXE="$REPO_ROOT/zig-out/bin/ghoztty.exe"
COM_EXE="$REPO_ROOT/zig-out/bin/ghoztty.com"
AGENT_EXE="$REPO_ROOT/zig-out/bin/ghoztty-agent.exe"
GL_DIR="$REPO_ROOT/zig-out/bin/gl"
SHARE="$REPO_ROOT/zig-out/share"
[[ -f "$EXE" ]] || { echo "error: $EXE not found (build first)" >&2; exit 1; }
# Same required-sibling rule the MSI enforces (T89h): a layout without the
# agent silently degrades every pane to non-persistent exec.
[[ -f "$AGENT_EXE" ]] || { echo "error: $AGENT_EXE not found -- the portable ZIP must carry the session-persistence agent (T89h); build first" >&2; exit 1; }
# And the console twin (T245/T1052): without it the ZIP is a terminal with no
# working command line. `zig build` installs it on every Windows target,
# cross-builds included, so a missing one means the build did not run.
[[ -f "$COM_EXE" ]] || { echo "error: $COM_EXE not found -- the portable ZIP must carry the console twin or the ghoztty command line does nothing from PowerShell (T245); build first" >&2; exit 1; }
[[ -f "$SHARE/terminfo/ghostty.terminfo" ]] || { echo "error: $SHARE/terminfo/ghostty.terminfo missing -- resourcesDir sentinel would break" >&2; exit 1; }
# The fallback OpenGL implementation (T1252). A layout without it starts fine
# on every machine with working graphics and REFUSES TO START on the ones this
# exists for -- a remote desktop, a stripped-down VM -- which is a defect only
# the affected user ever sees. It is a required payload for the same reason the
# agent is: silently shipping without it degrades the product invisibly.
[[ -f "$GL_DIR/opengl32.dll" ]] || { echo "error: $GL_DIR/opengl32.dll not found -- the portable ZIP must carry the fallback OpenGL implementation or Ghoztty cannot start over Remote Desktop (T1252); build first" >&2; exit 1; }
[[ -f "$GL_DIR/LICENSE-Mesa.txt" ]] || { echo "error: $GL_DIR/LICENSE-Mesa.txt not found -- the fallback OpenGL implementation may only be redistributed with its licence (T1252)" >&2; exit 1; }

if [[ -z "$STAMP" ]]; then
  STAMP="$(date +%Y%m%d)-$(git rev-parse --short HEAD)"
fi
if [[ -z "$OUT" ]]; then
  OUT="$REPO_ROOT/zig-out/Ghoztty-portable-$SEMVER-x64.zip"
fi
mkdir -p "$(dirname "$OUT")"

echo "==> portable ZIP: $OUT (semver $SEMVER, stamp $STAMP)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/Ghoztty"
mkdir -p "$ROOT"

cp "$EXE" "$ROOT/ghoztty.exe"
cp "$COM_EXE" "$ROOT/ghoztty.com"
cp "$AGENT_EXE" "$ROOT/ghoztty-agent.exe"
# -L would follow the symlinks zig's terminfo tree contains; the MSI skips
# them for the same reason (a ZIP consumer on Windows cannot represent one,
# and ghostty.terminfo is the file resourcesDir actually needs).
cp -R "$SHARE" "$ROOT/share"
find "$ROOT/share" -type l -delete
# gl/ is a SUBDIRECTORY on purpose, never beside ghoztty.exe: opengl32.dll is
# not a KnownDLL, so an adjacent copy would be loaded for every launch and would
# move every user with a working GPU onto it (T1251).
cp -R "$GL_DIR" "$ROOT/gl"

cat > "$ROOT/READ-ME-FIRST.txt" <<EOF
Ghoztty for Windows (x64) -- portable build $SEMVER ($STAMP)
============================================================

No installer. Just run the terminal:

  1. Keep this whole "Ghoztty" folder together (exe + agent + share + gl).
  2. Double-click  ghoztty.exe
  3. SmartScreen may say "Windows protected your PC" because this build is
     unsigned. Click "More info" -> "Run anyway".

Tip: copy this folder to a local disk first so it does not run off a
network share.

Want the "ghoztty" command line too? Add this folder to your PATH, then
"ghoztty +list" works from PowerShell or cmd. (ghoztty.com is what your
shell runs there -- keep it beside ghoztty.exe.)

Prefer an installer? Ghoztty-$SEMVER-x64.msi in the same release installs
per-user (no admin) and puts ghoztty on your PATH.
EOF

echo "==> staged payload:"
(cd "$WORK" && find Ghoztty -maxdepth 1 -mindepth 1 | sort | sed 's/^/    /')

python3 - "$WORK" "$OUT" <<'PYEOF'
import os, sys, zipfile

work, out = sys.argv[1], sys.argv[2]
root = os.path.join(work, "Ghoztty")
names = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, work).replace(os.sep, "/")
        names.append((full, rel))

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for full, rel in names:
        z.write(full, rel)
print(f"==> wrote {len(names)} entries")
PYEOF

# Validate what we produced, rather than trusting that the write succeeded:
# every payload the MSI guarantees must also be in the ZIP, under Ghoztty/.
python3 - "$OUT" <<'PYEOF'
import struct, sys, zipfile
out = sys.argv[1]
required = [
    "Ghoztty/ghoztty.exe",
    "Ghoztty/ghoztty.com",
    "Ghoztty/ghoztty-agent.exe",
    "Ghoztty/share/terminfo/ghostty.terminfo",
    "Ghoztty/gl/opengl32.dll",
    "Ghoztty/gl/LICENSE-Mesa.txt",
    "Ghoztty/READ-ME-FIRST.txt",
]
with zipfile.ZipFile(out) as z:
    names = set(z.namelist())
    bad = z.testzip()
    # The twin is only worth shipping if it is actually the console-subsystem
    # image: a plain copy of the GUI exe under a .com name is WORSE than no
    # twin at all, because PATHEXT prefers it and the shell still does not
    # wait. Read the packaged bytes rather than trusting the copy (T1052).
    if "Ghoztty/ghoztty.com" in names:
        head = z.read("Ghoztty/ghoztty.com")[:1024]
        pe = struct.unpack_from("<I", head, 0x3C)[0]
        subsystem = struct.unpack_from("<H", head, pe + 0x5C)[0]
        if subsystem != 3:
            sys.exit(f"error: Ghoztty/ghoztty.com has PE subsystem {subsystem}, expected 3 (console)")
    # T1252: the fallback GL must be in gl\ and NOWHERE ELSE. `opengl32.dll`
    # is not a KnownDLL, so a copy that landed at the archive root would be
    # loaded by the operating system on every launch and would put every user
    # with a working GPU onto the fallback renderer, silently. This is the one
    # packaging mistake in this whole change that has no symptom.
    hijack = [n for n in names
              if n.lower().endswith("/opengl32.dll") and n != "Ghoztty/gl/opengl32.dll"]
    if hijack:
        sys.exit(f"error: portable ZIP has an opengl32.dll outside Ghoztty/gl/: {hijack}")
missing = [r for r in required if r not in names]
if missing:
    sys.exit(f"error: portable ZIP is missing {missing}")
if bad is not None:
    sys.exit(f"error: portable ZIP has a corrupt entry: {bad}")
stray = sorted({n.split("/", 1)[0] for n in names} - {"Ghoztty"})
if stray:
    sys.exit(f"error: portable ZIP has entries outside Ghoztty/: {stray}")
print(f"==> validated {len(names)} entries, single Ghoztty/ root")
PYEOF

SIZE="$(du -h "$OUT" | cut -f1)"
echo ""
echo "portable ZIP created: $OUT ($SIZE)"
