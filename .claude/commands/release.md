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

**Also author the bundled notes.** From the same approved notes, write
`release-notes/<version>.json` (the offline "What's new" for the agent-update
dialog — schema in `release-notes/README.md`). Commit it with the release commit
**before** tagging (Step 3) so it ships in the app bundle. The JSON and the
GitHub release body (Step 6) are the same content in two shapes — keep them in
sync. Example:

```json
{
  "version": "1.4.1",
  "sections": [
    { "title": "Fork Changes",
      "items": [ { "title": "Feature", "text": "What the user can now do." } ] }
  ]
}
```

### Step 3: Tag and Push

```bash
git tag vX.Y.Z
git push origin main --tags
```

This triggers the release workflow which builds, signs, notarizes, and publishes a DMG to GitHub Releases.

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

Watch the release workflow:
```bash
gh run list --repo dzearing/ghoztty --workflow release.yml --limit 1
```

Monitor it until completion. If it fails, check logs with `gh run view <id> --repo dzearing/ghoztty --log-failed` and fix the issue.

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

The bundled `release-notes/<version>.json` (authored in Step 2) already carries
these notes for the in-app agent-update dialog; this GitHub body is the same
content as markdown.

### Step 7: Update Website

Update the **macOS app** version on the gh-pages landing page (only if the app was released this run — skip for an agent-only publish):

```bash
git worktree add /tmp/ghoztty-gh-pages gh-pages
```

In `/tmp/ghoztty-gh-pages/index.html`, replace all occurrences of the old version with `vX.Y.Z` (download button text, DMG download URL including filename, and footer version string). Do NOT touch the Remote Agent section — its version badge fetches the agent's `version.json` from the relay live, so it updates itself when Step 4 publishes; there is nothing to hand-edit for the agent.

```bash
cd /tmp/ghoztty-gh-pages && git add index.html && git commit -m "Update website version to vX.Y.Z" && git push origin gh-pages
git worktree remove /tmp/ghoztty-gh-pages
```

### Step 8: Report

Show a summary:
- Version released (macOS app tag) — or "app unchanged, not re-released"
- Agent: published `<date-hash>` (with download links) — or "unchanged, skipped"
- Release notes
- Link to the GitHub release
- Link to the GitHub Actions run
