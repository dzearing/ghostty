## Release Ghoztty

Follow these steps exactly to release a new version of Ghoztty (custom Ghostty fork).

### Step 1: Analyze Changes

Run `git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)..HEAD --oneline` to see all commits since the last release.

Categorize changes into: new features, improvements, bug fixes, upstream syncs.

**Determine which of the two artifacts actually changed** — the macOS app and the Windows agent version independently, and each is published only when its own inputs changed:

- **macOS app** — compare HEAD to the last release tag over the app's inputs:
  ```bash
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
  git diff --quiet "$LAST_TAG" HEAD -- src macos build.zig dist pkg po && echo "APP: unchanged" || echo "APP: changed"
  ```
- **Windows agent** — compare HEAD to the commit the *currently-deployed* agent was built from (recorded in the live `version.json`) over the agent's inputs:
  ```bash
  PREV=$(curl -fsS https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/dl/version.json \
         | sed -n 's/.*"commit"[^"]*"\([0-9a-f]*\)".*/\1/p')
  [ -z "$PREV" ] && PREV=$(curl -fsS https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/dl/version.json \
         | sed -n 's/.*"version"[^"]*"[0-9]\{8\}-\([0-9a-f]*\)".*/\1/p')  # pre-commit-field fallback
  git diff --quiet "$PREV" HEAD -- src/remote src/build/GhosttyAgent.zig build.zig relay/deploy && echo "AGENT: unchanged" || echo "AGENT: changed"
  ```
  (Step 4 runs `publish-agent.sh --if-changed`, which repeats this check and self-skips — so a wrong guess here is not fatal, it just informs the plan.)

Recommend a version tag (e.g. `v1.4.1`) with clear reasoning:
- Use standard semver — bump patch for fixes, minor for features, major for breaking changes
- The base version should stay in sync with the upstream Ghostty version when syncing

State plainly which artifacts will publish, e.g. "app + agent both changed → full release", "agent-only changed → skip the DMG/tag, just run Step 4", or "app-only → tag + DMG, agent auto-skips". If NEITHER changed, there is nothing to release — say so and stop. If only the agent changed you can skip the macOS tag/DMG entirely (Steps 3, 5, 6) and jump to Step 4.

Present the recommendation and ask the user to confirm or override. Do NOT proceed until confirmed.

### Step 2: Generate Release Notes

From the categorized commits, write user-facing release notes. Rules:
- Write in a friendly tone focused on what the user can now do or how their experience improved
- Do NOT use raw commit messages — rewrite them as benefits
- Group related commits into single bullet points
- Separate fork-specific changes from upstream syncs
- Format:
  ```
  ## What's new in Ghoztty vX.Y.Z

  ### Fork Changes
  - **Feature name** — What the user can now do, in plain language.
  - **Improvement** — How the experience got better.
  - **Fix** — What no longer happens / what works correctly now.

  ### Upstream Sync
  - Synced with Ghostty vX.Y.Z (if applicable)
  ```

Present the notes and ask the user to approve or edit. Do NOT proceed until approved.

**If the agent changed, author the bundled agent notes.** When this release
changes the background agent (session persistence, re-attach, agent lifecycle,
remote/relay — i.e. the `AGENT: changed` case from Step 1), write
`release-notes/agent/<version>.json` containing **only** the agent/session
changes — the reasons a user would restart the agent and reset live sessions.
This is the offline "What's new" shown in the agent-restart dialog (schema in
`release-notes/README.md`). Do NOT include viewer/banner/UI features here.
Commit it with the release commit **before** tagging (Step 3) so it ships in the
app bundle. Skip this when the agent didn't change. Example:

```json
{
  "version": "1.4.1",
  "sections": [
    { "title": "Session persistence",
      "items": [ { "title": "Seamless agent upgrades", "text": "What the user gains." } ] }
  ]
}
```

**Author the bundled client notes.** For every release that changes the app/UI
(viewer, banners, terminal UI, menus — anything a user sees that is NOT
session-persistence/agent), write `release-notes/client/<version>.json` with
**only** the client-scoped items (schema in `release-notes/README.md`; same
shape as the agent notes). Commit it with the release commit **before** tagging
(Step 3) so it both ships in the app bundle (the "What's New in Ghoztty…" menu
window) and is embedded into the Sparkle appcast `<description>` by `release.yml`
(the pre-update dialog on the update chip reads it from the appcast). Exclude the
agent/session items already captured under `release-notes/agent/`.

### Step 3: Tag and Push

```bash
git tag vX.Y.Z
git push origin main --tags
```

That starts the macOS half: `release.yml` builds, signs, notarizes, and publishes `Ghoztty-X.Y.Z-arm64.dmg` to the `vX.Y.Z` release.

**Until the Windows branch merges back, the Windows half needs its own tag** (T577). Push it too, at the head of the Windows branch:

```bash
git push origin users/dzearing/windows-amd64        # the tag must point at a pushed commit
git tag -a win-vX.Y.Z -m "Ghoztty for Windows vX.Y.Z" users/dzearing/windows-amd64
git push origin win-vX.Y.Z
```

A GitHub workflow runs from the tree of the ref that triggered it, and `main` has no Windows frontend at all — no `src/apprt/win32`, no `dist/windows-installer`, and an apprt enum of gtk/none/embedded, so `-Dapp-runtime=win32` is not a valid option there. A `vX.Y.Z` tag cut from main therefore cannot build a Windows terminal no matter which branch the workflow file sits on. `release-windows.yml` triggers on **both** `v*` and `win-v*` for exactly that reason: today the `win-v` tag is what fires it, and at merge-back the `vX.Y.Z` tag starts firing it on its own with nothing to rewire. Between now and then, **a release that skips the second tag ships macOS only**, silently — which is how Windows came to be offered a build from 2026-07-19 while macOS shipped v1.31.0.

Either trigger publishes `Ghoztty-X.Y.Z-x64.msi` + `Ghoztty-portable-X.Y.Z-x64.zip` to a `win-vX.Y.Z` release (`--latest=false`, so the Mac latest/Sparkle flow is untouched). The separate release tag is a contract with shipped binaries: installed Windows builds find updates by scanning the releases list for the newest `win-v` tag (`src/apprt/win32/update_check.zig`).

They are separate workflows so a Windows failure cannot interrupt the signing/notarization pipeline. Both artifacts are defined by `dist/windows-installer/build-release-artifacts.sh`, which the on-box path (`scripts/publish-windows-release.ps1`) runs too, so a hand publish and CI cannot drift.

**The release does not prove the Windows build — it expects to find it already green** (T578). `fork-ci.yml`'s `windows-cross` job runs that same `build-release-artifacts.sh` (exe + MSI + portable ZIP, msitools from the shared `dist/windows-installer/install-msitools.sh`) on every push to `users/dzearing/windows-amd64`, so a broken cross-compile is red on the commit that broke it. Before tagging, glance at the branch's latest Fork CI run (`gh run list --repo dzearing/ghoztty --branch users/dzearing/windows-amd64 --workflow "Fork CI" --limit 1`); a red `windows-cross` there means the release tag would fail the same way, and the fix belongs on the commit, not in the release.

### Step 4: Publish the Windows Agent Installer

Every release also publishes the Windows agent (installer + self-update manifest) so the two ship together. This runs LOCALLY from the tagged commit and is independent of the GitHub DMG build — do it while Step 5 monitors that build.

Prerequisites (all already set up on the release machine):
- Zig toolchain: `export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH; export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- `wixl` (msitools, `brew install msitools`) for building the MSI
- SSH access to the relay VM as a sudo-capable user (`azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com`)

Build the Windows agent and publish it (exe + per-user MSI + `version.json` + `install.ps1` + relay landing page) to the relay's `/dl/`:

```bash
zig build agent -Dtarget=x86_64-windows-gnu
relay/deploy/publish-agent.sh --if-changed
```

`--if-changed` makes this a no-op when nothing in the agent/installer/site changed since the deployed build (it compares HEAD to the `commit` recorded in the live `version.json` over the agent's input paths, and exits without uploading) — so it's always safe to run this step on every release; it publishes only when the agent actually changed. When it does publish, it stamps the build as `$(date +%Y%m%d)-$(git rev-parse --short HEAD)` (the same string the binary embeds), takes the release semver from the latest git tag (so the MSI ships as `Ghoztty-Agent-X.Y.Z-x64.msi`, matching the DMG's version — run this AFTER Step 3 has tagged), regenerates `version.json`, and uploads exe + versioned MSI (plus the stable `ghoztty-agent.msi` alias) + installer + landing page. Republishing the same semver (an agent-only publish between releases) auto-bumps the MSI build counter from the live manifest — no flag needed. Already-installed agents pick it up on their next self-update check (idle-gated, seamless — no session interruption).

Verify it went live:
```bash
curl -fsS  https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/dl/version.json
curl -fsSI https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/dl/ghoztty-agent.msi | head -1
```
`version.json` should show the new `date-hash` version and the download should be HTTP 200.

Note: this step is independent of the macOS release — if the SSH upload fails, the DMG release is still valid; just re-run the two commands above. Skip this step only if you deliberately want to hold the agent back (then say so in the report).

### Step 5: Monitor Build

Watch BOTH release workflows — the release is not out until each has published its own artifacts:
```bash
gh run list --repo dzearing/ghoztty --workflow release.yml --limit 1
gh run list --repo dzearing/ghoztty --branch win-vX.Y.Z --limit 5
```

The Windows run is listed by its **tag**, not by `--workflow release-windows.yml`: that flag resolves a workflow by filename against the **default branch**, and this one is not on main yet, so it answers `HTTP 404: workflow release-windows.yml not found on the default branch` even while a run of it is in progress. That 404 is not evidence of a missing run — check the tag.

Monitor them until completion. If one fails, check logs with `gh run view <id> --repo dzearing/ghoztty --log-failed` and fix the issue. They are independent: a Windows failure leaves the DMG release valid, and re-running the Windows half means moving the tag (`git tag -f win-vX.Y.Z <fixed-sha> && git push -f origin win-vX.Y.Z`) — `gh workflow run` needs the workflow on the default branch, so it is unavailable for the same reason the `--workflow` lookup is. The on-box fallback, from a Windows machine at the tagged commit, is `scripts\publish-windows-release.ps1` (it defaults `-Version` to the newest `vX.Y.Z` tag).

### Step 6: Publish Release

Once the DMG is built, update the GitHub release with the friendly notes:

```bash
gh release edit vX.Y.Z --repo dzearing/ghoztty --title "Ghoztty vX.Y.Z" --notes "$(cat <<'NOTES'
## What's new in Ghoztty vX.Y.Z

{the approved release notes from step 2}

---

### Installation
Download `Ghoztty.dmg`, open it, and drag to Applications.
Installs alongside official Ghostty — separate app with its own bundle ID.

### Requirements
- macOS 13+ (Apple Silicon)
NOTES
)"
```

If the agent changed, the bundled `release-notes/agent/<version>.json` (authored
in Step 2) carries the agent-scoped subset for the in-app agent-restart dialog;
this GitHub body is the full, general release notes.

### Step 7: Update Website

Update the **macOS app** version on the gh-pages landing page (only if the app was released this run — skip for an agent-only publish):

```bash
git worktree add /tmp/ghoztty-gh-pages gh-pages
```

In `/tmp/ghoztty-gh-pages/index.html`, replace the **macOS** occurrences of the old version with `vX.Y.Z` (download button text, DMG download URL including filename, and the `macOS vX.Y.Z` note line).

Do NOT touch two things by hand:

- The **Remote Agent** section — its version badge fetches the agent's `version.json` from the relay live, so it updates itself when Step 4 publishes.
- The **Windows** download card and its `Windows vX.Y.Z` note line (`id="win-msi-link"`, `id="win-zip-link"`, `id="win-version"`) — `release-windows.yml` retargets those at the `win-vX.Y.Z` release it just published, in the same run, via `dist/website/update-windows-links.py` (T39). Editing them by hand is how they would come to advertise a Windows build that does not exist. If a release ran with `publish=false`, the site correctly still points at the previous `win-v` release.

```bash
cd /tmp/ghoztty-gh-pages && git add index.html && git commit -m "Update website version to vX.Y.Z" && git push origin gh-pages
```

Then mirror the deployed page back into `relay/deploy/ghpages/index.html` so the in-repo copy does not drift from the live site. **Copy the whole file, do not re-apply the edit by hand** — `release-windows.yml` pushes its own commit to `gh-pages` in this same release (the Windows link rewrite), so the deployed page carries changes this step never made, and re-typing only the macOS edit reproduces exactly the drift this guards. Pull first for the same reason:

```bash
cd /tmp/ghoztty-gh-pages && git pull --rebase origin gh-pages
cp /tmp/ghoztty-gh-pages/index.html <repo>/relay/deploy/ghpages/index.html
# commit the mirror on the working branch, then:
git worktree remove /tmp/ghoztty-gh-pages
```

`test/win32/website-windows-download.ps1` (check F) fails when the mirror and the deployed page disagree. It has now drifted three times — 2026-08-07 was `v1.28.0` in the mirror against `v1.31.0` live — so run it before calling the release done.

### Step 8: Report

Show a summary:
- Version released (macOS app tag) — or "app unchanged, not re-released"
- Windows: `win-vX.Y.Z` with the MSI + portable ZIP (link) — or the workflow run that failed
- Agent: published `<date-hash>` (with download links) — or "unchanged, skipped"
- Release notes
- Link to the GitHub release
- Link to the GitHub Actions run
