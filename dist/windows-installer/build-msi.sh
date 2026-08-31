#!/usr/bin/env bash
# build-msi.sh — build the per-user Windows MSI for the Ghoztty terminal.
#
# Generates a WiX source (wixl/WiX-v3 subset) that packages ghoztty.exe, its
# console twin ghoztty.com, the session-persistence agent and the share/
# resource tree (themes, shell-integration, terminfo sentinel that
# src/os/resourcesdir.zig climbs for), compiles it with wixl (GNOME msitools)
# and validates the result with msiinfo — no Windows box needed.
#
# Usage:
#   dist/windows-installer/build-msi.sh [--version <stamp>] [--build-num <N>]
#                                       [--out <path>] [--skip-build]
#                                       [--semver <X.Y.Z>]
#                                       [--test-identity <Name>]
#                                       [--print-file-version]
#
# Defaults:
#   version    $(date +%Y%m%d)-$(git rev-parse --short HEAD) build stamp,
#              shown in Apps & Features via ARPCOMMENTS. The numeric MSI
#              ProductVersion is derived as yy.m.dNN (e.g. 26.7.501 =
#              2026-07-05 build 01) so newer builds always compare greater
#              and MSI major upgrades fire.
#   build-num  1 — same-day rebuild counter (bump when publishing twice in
#              a day: same ProductVersion refuses to install over itself).
#   out        zig-out/Ghoztty-<yy.m.dNN>-x64.msi (Ghoztty-<semver>-x64.msi
#              when --semver is given: the release-asset name, T24).
#   --semver <X.Y.Z>  release-channel build (T24): the zig build is stamped
#              with -Dversion-string=X.Y.Z+<short-hash> (so the exe's
#              semver matches the win-vX.Y.Z GitHub release tag the update
#              check compares against) and -Dwindows-update-check=true
#              (enables the in-app update check; dev builds never check).
#   --skip-build  reuse zig-out/bin/ghoztty.exe + zig-out/share instead of
#              running zig build (which needs the zig@0.15 PATH exports).
#              NOTE with --semver the exe must already carry the matching
#              -Dversion-string/-Dwindows-update-check (the on-box publish
#              script builds natively, then runs this under Docker).
#   --print-file-version  print the per-build FILEVERSION (yy.m.d.NN) this
#              run would use and exit, so a caller that builds the exe
#              itself (build-release-artifacts.sh, T38) passes the SAME
#              -Dwindows-file-version instead of restating the formula.
#   --test-identity <Name>  build a THROWAWAY MSI under a distinct product
#              identity (Name, install dir, UpgradeCode, registry key, and
#              component-GUID namespace all derived from <Name>) so on-box
#              install/upgrade/uninstall E2E tests never touch the real
#              Ghoztty product or install dir. Never ship these.
#
# Upgrade-safety design (T23, the 26.7.502 vanishing-exe postmortem):
#   - ghoztty.exe is built with a real per-build FILEVERSION
#     (-Dwindows-file-version=yy.m.d.NN, strictly increasing), and this
#     script mirrors the exe's ACTUAL PE version into the MSI File table
#     (wixl cannot read PE resources, so it emits an empty Version column —
#     Windows Installer then treats the packaged exe as UNVERSIONED, refuses
#     to overwrite the versioned installed exe, and RemoveExistingProducts
#     deletes it: net result "upgrade removed the exe").
#   - The MsiFileHash table is dropped: costing runs BEFORE the early
#     RemoveExistingProducts removes the old product's files, so any
#     unversioned file whose hash matched the installed copy was skipped by
#     InstallFiles and then deleted with the old product. Without hashes,
#     unversioned files fall back to the created/modified-date rule, which
#     always recopies MSI-installed (never user-edited) files.
#
# Requires: wixl, msiinfo (brew install msitools), python3 (GUID derivation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

VERSION=""
BUILD_NUM=1
OUT=""
SKIP_BUILD=0
TEST_IDENTITY=""
SEMVER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)   VERSION="${1#*=}"; shift ;;
    --semver)      SEMVER="${2:?--semver needs a value}"; shift 2 ;;
    --semver=*)    SEMVER="${1#*=}"; shift ;;
    --build-num)   BUILD_NUM="${2:?--build-num needs a value}"; shift 2 ;;
    --build-num=*) BUILD_NUM="${1#*=}"; shift ;;
    --out)         OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*)       OUT="${1#*=}"; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    --test-identity)   TEST_IDENTITY="${2:?--test-identity needs a value}"; shift 2 ;;
    --test-identity=*) TEST_IDENTITY="${1#*=}"; shift ;;
    --print-file-version) PRINT_FILE_VERSION=1; shift ;;
    -h|--help)     sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Per-build FILEVERSION: yy.m.d.NN, strictly increasing across builds so MSI
# file versioning always prefers the newer package exe (see header). This is
# the ONE definition of the rule -- a caller that builds the exe itself asks
# for it with --print-file-version rather than restating the formula (four
# private copies of a chrome datum is how T257's DPI bug survived).
FILE_VERSION="$(date +%-y).$(date +%-m).$(date +%-d).$BUILD_NUM"
if [[ "${PRINT_FILE_VERSION:-0}" -eq 1 ]]; then
  echo "$FILE_VERSION"
  exit 0
fi

for tool in wixl msiinfo python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install msitools)" >&2; exit 1; }
done

cd "$REPO_ROOT"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  EXTRA_BUILD_ARGS=()
  if [[ -n "$SEMVER" ]]; then
    # Release-channel build: stamp the exe with the win-v tag's semver
    # (+ commit for provenance) and enable the in-app update check.
    EXTRA_BUILD_ARGS+=("-Dversion-string=$SEMVER+$(git rev-parse --short HEAD)")
    EXTRA_BUILD_ARGS+=("-Dwindows-update-check=true")
  fi
  echo "==> zig build (ReleaseFast, x86_64-windows-gnu, win32 apprt, FILEVERSION $FILE_VERSION${SEMVER:+, semver $SEMVER})"
  zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
    "-Dwindows-file-version=$FILE_VERSION" ${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"}
fi

EXE="$REPO_ROOT/zig-out/bin/ghoztty.exe"
COM_EXE="$REPO_ROOT/zig-out/bin/ghoztty.com"
AGENT_EXE="$REPO_ROOT/zig-out/bin/ghoztty-agent.exe"
SHARE="$REPO_ROOT/zig-out/share"
[[ -f "$EXE" ]] || { echo "error: $EXE not found (build first)" >&2; exit 1; }
# ghoztty.com is the console-subsystem twin (T245, src/cli/com_shim.zig) and it
# is what the MSI's PATH entry actually resolves: PATHEXT prefers .COM over
# .EXE, and the GUI ghoztty.exe is not waited for by PowerShell or cmd, so an
# install without the twin puts a dead `ghoztty` on the user's PATH (T1052).
[[ -f "$COM_EXE" ]] || { echo "error: $COM_EXE not found — the MSI puts INSTALLDIR on PATH, and without the console twin the ghoztty command line does nothing (T245); build first" >&2; exit 1; }
# The session-persistence agent ships as a REQUIRED sibling of ghoztty.exe
# (T89h): the app spawns it by that relative location (LocalAgent.zig), and
# a Windows install without it silently degrades every pane to non-persistent
# exec. The default `zig build` installs it on Windows targets.
[[ -f "$AGENT_EXE" ]] || { echo "error: $AGENT_EXE not found — the MSI must carry the session-persistence agent (T89h); build first" >&2; exit 1; }
[[ -f "$SHARE/terminfo/ghostty.terminfo" ]] || { echo "error: $SHARE/terminfo/ghostty.terminfo missing — resourcesDir sentinel would break" >&2; exit 1; }

# The exe's ACTUAL PE file version (authoritative even under --skip-build):
# scan for the VS_FIXEDFILEINFO signature (0xFEEF04BD little-endian) and read
# dwFileVersionMS/LS. This is what gets mirrored into the MSI File table.
EXE_FILE_VERSION="$(python3 - "$EXE" <<'PYEOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"\xbd\x04\xef\xfe")  # VS_FIXEDFILEINFO dwSignature
if i < 0:
    sys.exit("error: no VS_FIXEDFILEINFO in exe (version resource missing)")
ms, ls = struct.unpack_from("<II", data, i + 8)
print(f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}")
PYEOF
)"
if [[ "$SKIP_BUILD" -eq 0 && "$EXE_FILE_VERSION" != "$FILE_VERSION" ]]; then
  echo "error: built exe reports FILEVERSION $EXE_FILE_VERSION, expected $FILE_VERSION" >&2
  exit 1
fi
if [[ "$EXE_FILE_VERSION" == "0.1.0.0" ]]; then
  echo "warning: exe carries the 0.1.0.0 dev FILEVERSION — MSI upgrades over an equal/higher version will not replace it (rebuild without --skip-build, or with -Dwindows-file-version)" >&2
fi

# Build stamp + numeric MSI ProductVersion (yy.m.dNN).
if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y%m%d)-$(git rev-parse --short HEAD)"
fi
YY="$(date +%y)"; M="$(date +%-m)"; D="$(date +%-d)"
NN="$(printf '%02d' "$BUILD_NUM")"
PRODUCT_VERSION="$YY.$M.$D$NN"
if [[ -z "$OUT" ]]; then
  if [[ -n "$SEMVER" ]]; then
    OUT="$REPO_ROOT/zig-out/Ghoztty-$SEMVER-x64.msi"
  else
    OUT="$REPO_ROOT/zig-out/Ghoztty-$PRODUCT_VERSION-x64.msi"
  fi
fi

# What a PERSON reads in Apps & Features (T1205). ProductVersion above is the
# date-derived yy.m.dNN number that guarantees MSI upgrade sequencing; it is
# load-bearing and it is also not a version anybody publishes. On 2026-08-31
# the user installed Ghoztty-1.35.0-x64.msi, looked at Apps & Features, and
# read "26.8.3108" - a number that matches neither the file they downloaded,
# the website, nor the release tag. ARPDISPLAYVERSION is exactly the property
# for this: Windows shows it instead of ProductVersion, and upgrade logic
# never looks at it. Without --semver there is no marketing version to show,
# so it falls back to the number Windows would have shown anyway.
DISPLAY_VERSION="${SEMVER:-$PRODUCT_VERSION}"

echo "==> stamp:          $VERSION"
echo "==> ProductVersion: $PRODUCT_VERSION"
echo "==> DisplayVersion: $DISPLAY_VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WXS="$WORK/ghoztty.wxs"

# Generate the WiX source. Directory tree + one component per file with
# GUIDs derived deterministically from the install path (uuid5) so component
# identity is stable across builds (MSI component rules).
python3 - "$EXE" "$COM_EXE" "$AGENT_EXE" "$SHARE" "$WXS" "$TEST_IDENTITY" <<'PYEOF'
import os, sys, uuid, hashlib
from xml.sax.saxutils import escape

exe, com_exe, agent_exe, share, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
identity = sys.argv[6] if len(sys.argv) > 6 else ""

# Stable namespace for component GUID derivation. NEVER change this, or
# every component changes identity and upgrades misbehave.
NS = uuid.UUID("a934c3a7-a4fa-426d-8aab-2d260aa7563b")

# Throwaway test identity (--test-identity): distinct product name, install
# dir, UpgradeCode, registry key, AND component-GUID namespace, so a test
# install/upgrade/uninstall cycle shares nothing with the real product.
PRODUCT_NAME = identity or "Ghoztty"
UPGRADE_CODE = (
    "5EB02044-7F06-498B-B7A9-7EFD65486CFB"
    if not identity
    else str(uuid.uuid5(NS, "upgradecode::" + identity)).upper()
)
if identity:
    NS = uuid.uuid5(NS, "identity::" + identity)

def guid(install_path: str) -> str:
    return str(uuid.uuid5(NS, install_path)).upper()

# MSI Component/File/Directory key columns are s72 — max 72 chars. Deriving
# an identifier from the full install path blows past that for deeply nested
# files (e.g. share/ghostty/shell-integration/fish/vendor_conf.d/...), and
# Windows Installer then REJECTS the package at validation and silently rolls
# back the install. So identifiers are a short prefix + a hash of the install
# path: always well under 72 chars, unique, and stable across builds (the
# path is the identity). The human-readable path lives in File.Name /
# Directory.Name, which are l255/l255 and have no such limit.
def ident(prefix: str, install_path: str) -> str:
    h = hashlib.sha1(install_path.encode("utf-8")).hexdigest()[:20]
    return f"{prefix}{h}"  # e.g. c1a2b3... — <=21 chars, starts with a letter

lines = []
comp_refs = []

def emit_file_component(rel_install_dir, src_path, indent):
    """One component per file, file is the keypath (fine for per-user)."""
    name = os.path.basename(src_path)
    install_path = (rel_install_dir + "\\" + name) if rel_install_dir else name
    cid = ident("c", install_path)
    fid = ident("f", install_path)
    pad = " " * indent
    lines.append(f'{pad}<Component Id="{cid}" Guid="{guid(install_path)}">')
    lines.append(f'{pad}  <File Id="{fid}" Name="{escape(name)}" KeyPath="yes" Source="{escape(src_path)}"/>')
    lines.append(f'{pad}</Component>')
    comp_refs.append(cid)

def emit_dir(fs_dir, rel_install_dir, indent):
    pad = " " * indent
    entries = sorted(os.listdir(fs_dir))
    for e in entries:
        p = os.path.join(fs_dir, e)
        if os.path.islink(p):
            # zig terminfo trees can contain symlinks; skip them (MSI/Windows
            # ZIP-style consumers can't represent them; the .terminfo source
            # file is what resourcesDir needs).
            continue
        if os.path.isdir(p):
            rel = (rel_install_dir + "\\" + e) if rel_install_dir else e
            did = ident("d", rel)
            lines.append(f'{pad}<Directory Id="{did}" Name="{escape(e)}">')
            emit_dir(p, rel, indent + 2)
            lines.append(f'{pad}</Directory>')
        else:
            emit_file_component(rel_install_dir, p, indent)

# INSTALLDIR contents: ghoztty.exe + ghoztty.com + ghoztty-agent.exe + share
# tree. The agent is a required sibling: session persistence spawns it by
# relative location (T89h). The .com twin is what INSTALLDIR-on-PATH resolves
# for a bare `ghoztty` (T245/T1052).
emit_file_component("", exe, 12)
emit_file_component("", com_exe, 12)
emit_file_component("", agent_exe, 12)
lines.append(f'            <Directory Id="{ident("d", "share")}" Name="share">')
emit_dir(share, "share", 14)
lines.append('            </Directory>')

files_xml = "\n".join(lines)
refs_xml = "\n".join(f'      <ComponentRef Id="{c}"/>' for c in comp_refs)

template = """<?xml version="1.0" encoding="utf-8"?>
<!--
  ghoztty.wxs — per-user MSI for the Ghoztty terminal (Windows beta).
  GENERATED by dist/windows-installer/build-msi.sh — do not edit.

  Modeled on the standalone agent's wxs, the first proven wixl pipeline here
  (relay/deploy/msi/, retired with that installer in T1175):
  per-user (no elevation), %LOCALAPPDATA%\\Programs\\Ghoztty, Start Menu
  shortcut, permanent UpgradeCode for major upgrades, taskkill custom action
  so a running terminal doesn't trip files-in-use.
-->
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*"
           Name="@PRODUCT_NAME@"
           Manufacturer="dzearing"
           Version="@PRODUCT_VERSION@"
           UpgradeCode="@UPGRADE_CODE@"
           Language="1033">

    <Package InstallerVersion="500"
             InstallScope="perUser"
             Compressed="yes"
             Description="Ghoztty terminal emulator (Windows beta)"
             Comments="Build @STAMP@"/>

    <Media Id="1" Cabinet="ghoztty.cab" EmbedCab="yes"/>

    <Property Id="MSIINSTALLPERUSER" Value="1"/>
    <Property Id="ARPCOMMENTS" Value="Build @STAMP@"/>
    <!-- T1205: what Apps & Features SHOWS, which is not what the installer
         SEQUENCES on. See DISPLAY_VERSION in build-msi.sh. -->
    <Property Id="ARPDISPLAYVERSION" Value="@DISPLAY_VERSION@"/>
    <Property Id="ARPNOMODIFY" Value="1"/>

    <!-- T1204: a per-user terminal NEVER asks for a reboot.

         On 2026-08-31 an upgrade over a running Ghoztty ended by demanding a
         restart of the PC. The file replacement had already completed; what
         Windows Installer had done was pick up the machine's unrelated
         pending-reboot state (Windows Update and Component Based Servicing
         each had a flag set) and present it as this install's requirement.
         Nothing this package installs can need one: every file lands under
         %LOCALAPPDATA%, there is no service, no driver, no shared in-use
         system component, and the only processes that can hold a file here
         are ours - which the Restart Manager closes and reopens.

         ReallySuppress is the strong form: it suppresses the reboot AND the
         prompt, in UI and silent installs alike, where REBOOT=Suppress still
         leaves the "restart now?" question at the end.

         Deliberately NOT set beside it: MSIRESTARTMANAGERCONTROL. Its only
         value is "Disable", and disabling the Restart Manager is the opposite
         of what this task is for - RM is what closes the running terminal,
         lets the files be replaced, and starts it back up (the app asks to be
         restarted in src/apprt/win32/restart_manager.zig). The read-back
         below fails the build if that property ever appears. -->
    <Property Id="REBOOT" Value="ReallySuppress"/>

    <Upgrade Id="@UPGRADE_CODE@">
      <UpgradeVersion Minimum="0.0.0" IncludeMinimum="yes"
                      Maximum="@PRODUCT_VERSION@" IncludeMaximum="no"
                      Property="OLDERVERSIONFOUND" MigrateFeatures="yes"/>
      <UpgradeVersion Minimum="@PRODUCT_VERSION@" IncludeMinimum="yes"
                      OnlyDetect="yes"
                      Property="NEWERVERSIONFOUND"/>
    </Upgrade>

    <Condition Message="A newer version of Ghoztty is already installed.">NOT NEWERVERSIONFOUND</Condition>

    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="LocalAppDataFolder">
        <Directory Id="ProgramsDir" Name="Programs">
          <Directory Id="INSTALLDIR" Name="@PRODUCT_NAME@">
@FILES@
            <!-- Uninstall cleanup for the install root. -->
            <Component Id="C_InstallDirCleanup" Guid="@CLEANUP_GUID@">
              <RegistryValue Root="HKCU"
                             Key="Software\\dzearing\\@PRODUCT_NAME@"
                             Name="InstallDir" Value="[INSTALLDIR]"
                             Type="string" KeyPath="yes"/>
              <RemoveFolder Id="RemoveInstallDir" On="uninstall"/>
            </Component>
            <!-- User PATH entry so `ghoztty` resolves from any shell (T70).
                 Removed automatically on uninstall (Permanent=no). The app
                 also self-heals this entry on launch (PathInstaller.zig),
                 which covers pre-existing installs and manual deletion. -->
            <Component Id="C_UserPathEntry" Guid="@PATHENV_GUID@">
              <RegistryValue Root="HKCU"
                             Key="Software\\dzearing\\@PRODUCT_NAME@"
                             Name="PathEntry" Value="1"
                             Type="integer" KeyPath="yes"/>
              <Environment Id="E_UserPath" Name="PATH"
                           Value="[INSTALLDIR]"
                           Part="last" Action="set" Permanent="no"
                           System="no"/>
            </Component>
          </Directory>
        </Directory>
      </Directory>

      <Directory Id="ProgramMenuFolder">
        <Component Id="C_StartMenuShortcut" Guid="@SHORTCUT_GUID@">
          <RegistryValue Root="HKCU"
                         Key="Software\\dzearing\\Ghoztty"
                         Name="Shortcut" Value="1"
                         Type="integer" KeyPath="yes"/>
          <Shortcut Id="GhozttyStartMenuShortcut"
                    Name="@PRODUCT_NAME@"
                    Target="[INSTALLDIR]ghoztty.exe"
                    WorkingDirectory="INSTALLDIR"
                    Description="Ghoztty terminal emulator"/>
        </Component>
      </Directory>
    </Directory>

    <Feature Id="Ghoztty" Level="1" Title="@PRODUCT_NAME@">
@REFS@
      <ComponentRef Id="C_InstallDirCleanup"/>
      <ComponentRef Id="C_UserPathEntry"/>
      <ComponentRef Id="C_StartMenuShortcut"/>
    </Feature>

    <!-- The beta deliberately omits a taskkill custom action. A type-50 EXE
         custom action running taskkill.exe pops a console window during
         install (alarming for a first-time install) and buys nothing on a
         fresh install. If a future upgrade needs to replace a running exe,
         the user is told to close Ghoztty first. Keep the install a pure
         file-copy + shortcut + registry write for maximum robustness. -->

    <!-- Installing ends with a running terminal, not a Start Menu entry the
         user has to go find (T1176). The pair is the shape the retired agent
         MSI proved on this same wixl 0.106 pipeline: a type-51 action puts
         the exe path in a property, then a type-50 action runs THAT property
         as the command. ghoztty.exe is GUI-subsystem, so unlike the taskkill
         action above this spawns no console window.

         asyncNoWait: the terminal is a long-lived app — msiexec must not wait
         for it to exit, and its exit code must not fail the install.
         Immediate execution after InstallFinalize runs it as the installing
         user, which is what a per-user install wants.

         When it does NOT fire, and why:
           NOT Installed          — uninstall and repair leave nothing new to
                                    show; Installed is empty on a fresh
                                    install and on a major upgrade's new
                                    package.
           NOT OLDERVERSIONFOUND  — an upgrade-in-place is the updater's
                                    path: the user already has Ghoztty open,
                                    and a surprise second window on top of it
                                    is not what "update" means.
           UILevel > 3            — a silent (/qn, UILevel 2) or basic-UI
                                    (/qb, 3) install is scripted, and nothing
                                    scripted wants a window it did not ask
                                    for. Only reduced (4) and full (5) UI —
                                    i.e. somebody double-clicked the MSI —
                                    end with a terminal.
           LAUNCHAPP = "1"        — the escape hatch: LAUNCHAPP=0 on the
                                    msiexec command line suppresses the
                                    launch without suppressing the UI. -->
    <Property Id="LAUNCHAPP" Value="1"/>
    <CustomAction Id="SetLaunchAppCmd"
                  Property="LAUNCHAPPCMD"
                  Value="[INSTALLDIR]ghoztty.exe"/>
    <CustomAction Id="LaunchApp"
                  Property="LAUNCHAPPCMD"
                  ExeCommand=""
                  Execute="immediate"
                  Return="asyncNoWait"/>

    <InstallExecuteSequence>
      <RemoveExistingProducts After="InstallValidate"/>
      <Custom Action="SetLaunchAppCmd" Before="LaunchApp"/>
      <Custom Action="LaunchApp" After="InstallFinalize">NOT Installed AND NOT OLDERVERSIONFOUND AND UILevel &gt; 3 AND LAUNCHAPP = "1"</Custom>
    </InstallExecuteSequence>
  </Product>
</Wix>
"""

xml = template.replace("@FILES@", files_xml).replace("@REFS@", refs_xml)
xml = xml.replace("@CLEANUP_GUID@", guid("__installdir_cleanup__"))
xml = xml.replace("@SHORTCUT_GUID@", guid("__startmenu_shortcut__"))
xml = xml.replace("@PATHENV_GUID@", guid("__user_path_entry__"))
xml = xml.replace("@PRODUCT_NAME@", PRODUCT_NAME)
xml = xml.replace("@UPGRADE_CODE@", UPGRADE_CODE)
# Version/stamp substituted by the shell (python only handles layout).
with open(out, "w") as f:
    f.write(xml)
tag = f" [TEST IDENTITY: {PRODUCT_NAME} / {UPGRADE_CODE}]" if identity else ""
print(f"generated {out}: {len(comp_refs)} file components{tag}")
PYEOF

# Substitute version/stamp placeholders (portable across BSD/GNU sed).
sed -e "s/@PRODUCT_VERSION@/$PRODUCT_VERSION/g" -e "s/@STAMP@/$VERSION/g" \
    -e "s/@DISPLAY_VERSION@/$DISPLAY_VERSION/g" "$WXS" > "$WXS.tmp"
mv "$WXS.tmp" "$WXS"

echo "==> wixl compile (x64)"
# -a x64: without it wixl emits an x86 package (Template "Intel") for our
# 64-bit exe, and the product registers under the WOW6432Node registry view.
wixl -a x64 -o "$OUT" "$WXS"

# wixl (msitools <= 0.106) ignores Environment/@Permanent="no": it emits the
# Name column as `=PATH` instead of `=-PATH`, and without the `-` flag
# Windows Installer leaves the user PATH entry behind on uninstall (verified
# empirically on-box, T70). Patch the Environment table post-compile.
echo "==> patch Environment table (=PATH -> =-PATH for uninstall removal)"
TAB="$(printf '\t')"
msiinfo export "$OUT" Environment > "$WORK/Environment.idt"
grep -q "${TAB}=PATH${TAB}" "$WORK/Environment.idt" || {
  echo "error: Environment table has no =PATH row to patch (wixl behavior changed?)" >&2
  exit 1
}
sed -e "s/${TAB}=PATH${TAB}/${TAB}=-PATH${TAB}/" "$WORK/Environment.idt" > "$WORK/Environment.idt.new"
mv "$WORK/Environment.idt.new" "$WORK/Environment.idt"
msibuild "$OUT" -i "$WORK/Environment.idt"

# wixl cannot read PE version resources, so it leaves File.Version EMPTY for
# ghoztty.exe. Windows Installer then treats the packaged exe as UNVERSIONED
# and refuses to overwrite the (versioned) installed exe on major upgrade,
# while RemoveExistingProducts deletes the old copy — the 26.7.502
# vanishing-exe bug. Mirror the exe's actual PE version into the File table.
# ghoztty-agent.exe gets the SAME strictly-increasing per-build version in
# the File table — deliberately NOT its own PE version (which carries the
# release semver and can repeat or even decrease across rebuilds; an
# equal/lower table version would re-trigger the T23 vanishing-file rule on
# upgrade). Table version > on-disk version ⇒ InstallFiles always recopies.
# ghoztty.com carries ghoztty.exe's version resource verbatim (it IS that
# image with the subsystem word flipped), so it needs the same row or an
# upgrade would leave last release's CLI behind next to a fresh app (T1052).
echo "==> patch File table (ghoztty.exe + ghoztty.com + ghoztty-agent.exe Version = $EXE_FILE_VERSION)"
msiinfo export "$OUT" File > "$WORK/File.idt"
python3 - "$WORK/File.idt" "$EXE_FILE_VERSION" <<'PYEOF'
import sys
path, ver = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8", newline="") as f:
    content = f.read()
sep = "\r\n" if "\r\n" in content else "\n"
lines = content.split(sep)
want = {"ghoztty.exe": 0, "ghoztty.com": 0, "ghoztty-agent.exe": 0}
for i, line in enumerate(lines):
    fields = line.split("\t")
    if len(fields) >= 5 and fields[2] in want:
        fields[4] = ver
        lines[i] = "\t".join(fields)
        want[fields[2]] += 1
bad = [n for n, c in want.items() if c != 1]
if bad:
    sys.exit(f"error: expected exactly 1 File-table row for each exe, bad counts: {want}")
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(sep.join(lines))
PYEOF
msibuild "$OUT" -i "$WORK/File.idt"

# Drop all MsiFileHash rows (import an empty table). File costing runs BEFORE
# the early RemoveExistingProducts deletes the old product's files, so an
# unversioned file whose hash matches the installed copy is skipped by
# InstallFiles and then deleted with the old product — every unchanged
# share/ file would vanish on upgrade. Without hashes, unversioned files use
# the created/modified-date rule, which always recopies MSI-installed files.
echo "==> drop MsiFileHash table (force unversioned-file recopy on upgrade)"
printf 'File_\tOptions\tHashPart1\tHashPart2\tHashPart3\tHashPart4\r\ns72\ti2\ti4\ti4\ti4\ti4\r\nMsiFileHash\tFile_\r\n' > "$WORK/MsiFileHash.idt"
msibuild "$OUT" -i "$WORK/MsiFileHash.idt"

# Read the launch-on-finish wiring back out of the compiled package (T1176).
# wixl is a third-party compiler on a pinned version and the Environment/File
# patches above exist precisely because it does not always emit what the wxs
# says; "the wxs has a CustomAction in it" is not evidence that the MSI does.
# A build whose install would end WITHOUT a terminal fails here instead of
# shipping.
echo "==> verify launch-on-finish (CustomAction + InstallExecuteSequence)"
msiinfo export "$OUT" CustomAction > "$WORK/CustomAction.idt" || {
  echo "error: the MSI has no CustomAction table — wixl dropped the launch-on-finish actions entirely" >&2; exit 1; }
msiinfo export "$OUT" InstallExecuteSequence > "$WORK/InstallExecuteSequence.idt" || {
  echo "error: the MSI has no InstallExecuteSequence table" >&2; exit 1; }
python3 - "$WORK/CustomAction.idt" "$WORK/InstallExecuteSequence.idt" <<'PYEOF'
import sys

def rows(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        lines = f.read().replace("\r\n", "\n").split("\n")
    # .idt header: column names, column types, table name.
    return [l.split("\t") for l in lines[3:] if l.strip()]

ca = {r[0]: r for r in rows(sys.argv[1])}
seq = {r[0]: r for r in rows(sys.argv[2])}
errs = []

# msidbCustomActionTypeExe(2) + msidbCustomActionTypeProperty(48) = 50,
# plus Async(64) + Continue(128) for Return="asyncNoWait".
if "LaunchApp" not in ca:
    errs.append("CustomAction table has no LaunchApp row — the install would end with no terminal")
else:
    t = int(ca["LaunchApp"][1])
    if t & 0x3F != 50:
        errs.append(f"LaunchApp base type is {t & 0x3F}, expected 50 (exe from property)")
    if not (t & 64) or not (t & 128):
        errs.append(f"LaunchApp type {t} is not asyncNoWait — msiexec would block on the terminal or fail the install on its exit code")
    if ca["LaunchApp"][2] != "LAUNCHAPPCMD":
        errs.append(f"LaunchApp source is {ca['LaunchApp'][2]!r}, expected LAUNCHAPPCMD")

if "SetLaunchAppCmd" not in ca:
    errs.append("CustomAction table has no SetLaunchAppCmd row — LAUNCHAPPCMD would be empty and nothing would launch")
else:
    if int(ca["SetLaunchAppCmd"][1]) != 51:
        errs.append(f"SetLaunchAppCmd type is {ca['SetLaunchAppCmd'][1]}, expected 51 (property set)")
    if ca["SetLaunchAppCmd"][3] != "[INSTALLDIR]ghoztty.exe":
        errs.append(f"SetLaunchAppCmd target is {ca['SetLaunchAppCmd'][3]!r}, expected [INSTALLDIR]ghoztty.exe")

for action in ("LaunchApp", "SetLaunchAppCmd", "InstallFinalize"):
    if action not in seq:
        errs.append(f"InstallExecuteSequence has no {action} row")
if not errs:
    n_launch = int(seq["LaunchApp"][2])
    n_set = int(seq["SetLaunchAppCmd"][2])
    n_final = int(seq["InstallFinalize"][2])
    if n_launch <= n_final:
        errs.append(f"LaunchApp is sequenced at {n_launch}, before InstallFinalize at {n_final} — the exe would not be on disk yet")
    if n_set >= n_launch:
        errs.append(f"SetLaunchAppCmd is sequenced at {n_set}, not before LaunchApp at {n_launch}")
    cond = seq["LaunchApp"][1]
    for want in ("NOT Installed", "OLDERVERSIONFOUND", "UILevel", "LAUNCHAPP"):
        if want not in cond:
            errs.append(f"LaunchApp condition {cond!r} does not gate on {want}")

if errs:
    for e in errs:
        print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
print("launch-on-finish ok: SetLaunchAppCmd -> LaunchApp (asyncNoWait) after InstallFinalize")
PYEOF

# Read the no-reboot / Restart-Manager wiring back out of the compiled package
# (T1204). Same argument as the block above and the same history behind it:
# wixl has twice emitted an MSI that disagreed with the wxs it was given, and
# the cost of this one being wrong is the defect the user hit - an upgrade that
# ends by demanding a reboot of the whole PC for a per-user terminal.
echo "==> verify no-reboot + restart-manager wiring (Property table)"
msiinfo export "$OUT" Property > "$WORK/Property.idt" || {
  echo "error: the MSI has no Property table" >&2; exit 1; }
python3 - "$WORK/Property.idt" "$DISPLAY_VERSION" <<'PYEOF'
import sys

def rows(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        lines = f.read().replace("\r\n", "\n").split("\n")
    # .idt header: column names, column types, table name.
    return [l.split("\t") for l in lines[3:] if l.strip()]

props = {r[0]: (r[1] if len(r) > 1 else "") for r in rows(sys.argv[1])}
errs = []

if "REBOOT" not in props:
    errs.append(
        "Property table has no REBOOT row - Windows Installer is free to inherit "
        "the machine's unrelated pending-reboot state and demand a restart for a "
        "per-user install"
    )
elif props["REBOOT"] != "ReallySuppress":
    errs.append(
        f"REBOOT is {props['REBOOT']!r}, expected 'ReallySuppress' - "
        "'Suppress' still leaves the restart prompt at the end of the install"
    )

if props.get("MSIRESTARTMANAGERCONTROL", "").lower() == "disable":
    errs.append(
        "MSIRESTARTMANAGERCONTROL=Disable turns the Restart Manager OFF - the "
        "installer would then have no way to close and reopen a running Ghoztty, "
        "which is the whole graceful-upgrade path"
    )

if props.get("MSIDISABLERMRESTART", "0") not in ("0", ""):
    errs.append(
        f"MSIDISABLERMRESTART is {props['MSIDISABLERMRESTART']!r} - a non-zero "
        "value closes the running terminal for the install and never brings it back"
    )

# T1205: what a person reads in Apps & Features. The package must carry the
# marketing version, not the yy.m.dNN sequencing number - four surfaces
# disagreed about "which Ghoztty is this?" and this was the one nobody could
# even map back to a download.
want_display = sys.argv[2] if len(sys.argv) > 2 else ""
if want_display:
    if "ARPDISPLAYVERSION" not in props:
        errs.append(
            "Property table has no ARPDISPLAYVERSION row - Apps & Features would "
            "show the date-derived ProductVersion, which matches nothing the user "
            "downloaded"
        )
    elif props["ARPDISPLAYVERSION"] != want_display:
        errs.append(
            f"ARPDISPLAYVERSION is {props['ARPDISPLAYVERSION']!r}, expected "
            f"{want_display!r}"
        )

if errs:
    for e in errs:
        print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
print("no-reboot ok: REBOOT=ReallySuppress, Restart Manager left enabled")
if want_display:
    print(f"display version ok: Apps & Features will show {want_display}")
PYEOF

echo "==> validate"
msiinfo suminfo "$OUT" | head -12
SIZE="$(du -h "$OUT" | cut -f1)"
echo ""
echo "MSI created: $OUT ($SIZE)"
