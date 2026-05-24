## Release Ghoztty

Follow these steps exactly to release a new version of Ghoztty (custom Ghostty fork).

### Step 1: Analyze Changes

Run `git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)..HEAD --oneline` to see all commits since the last release.

Categorize changes into: new features, improvements, bug fixes, upstream syncs.

Recommend a version tag (e.g. `v1.4.1`) with clear reasoning:
- Use standard semver — bump patch for fixes, minor for features, major for breaking changes
- The base version should stay in sync with the upstream Ghostty version when syncing

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

### Step 3: Tag and Push

```bash
git tag vX.Y.Z
git push origin main --tags
```

This triggers the release workflow which builds, signs, notarizes, and publishes a DMG to GitHub Releases.

### Step 4: Monitor Build

Watch the release workflow:
```bash
gh run list --repo dzearing/ghoztty --workflow release.yml --limit 1
```

Monitor it until completion. If it fails, check logs with `gh run view <id> --repo dzearing/ghoztty --log-failed` and fix the issue.

### Step 5: Publish Release

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

### Step 6: Update Website

Update the version on the gh-pages landing page:

```bash
git worktree add /tmp/ghoztty-gh-pages gh-pages
```

In `/tmp/ghoztty-gh-pages/index.html`, replace all occurrences of the old version with `vX.Y.Z` (download button text, DMG download URL including filename, and footer version string).

```bash
cd /tmp/ghoztty-gh-pages && git add index.html && git commit -m "Update website version to vX.Y.Z" && git push origin gh-pages
git worktree remove /tmp/ghoztty-gh-pages
```

### Step 7: Report

Show a summary:
- Version released
- Release notes
- Link to the GitHub release
- Link to the GitHub Actions run
