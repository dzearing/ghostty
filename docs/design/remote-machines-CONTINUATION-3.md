# CONTINUATION 3 — remote machines / relay (2026-07-03, end of dogfooding day)

> **Resume protocol:** read this file, then `remote-relay-roadmap.md` §0 (the
> canonical rolling snapshot — every landing today is recorded there), then
> `git log --oneline -20` on `feature/remote-machines`. Delegate implementation
> to worktree subagents (user's standing preference); orchestrator cherry-picks
> reported SHAs, rebuilds, RELAUNCHES the debug app (verify process start time
> > binary mtime — a raced quit dialog once left a stale instance and caused
> "I still see the same bugs"), and live-verifies in the GUI.

## Where things stand (all VERIFIED live unless noted)

- **Google auth is LIVE in production posture.** `DEV_AUTH=false` on the Azure
  relay; dual OAuth clients (Desktop `ghoztty-client` for the Mac app,
  TV/limited-input `ghoztty-agent` for device-code); in-app sign-in (PKCE,
  Keychain, profile photo avatar); device-code self-enroll proven on real
  Google. Old dev client token is DEAD — client-API curls need a real ID token
  (runbook §3) or the signed-in app.
- **The full account-centric vision works:** sign in → your machines; enroll a
  box → it appears; rename (display name wins, "(hostname)" subtext);
  remove = delete + revoke (live-kicks connections); Cmd-Shift-N chooser
  ("New" / "Restore (N)" primary button); windows restore across quit,
  relaunch, AND sign-out→sign-in (user-defined sign-out contract: windows
  close, dials refused pre-flight, manifest replays on sign-in); user-set
  window titles survive restore; reconnect state machine + pill dot
  (green/yellow/red); Activity Monitor works over the relay; agent keepalive
  survives laptop sleep (detects dead link ≤ ~70s after wake); agent
  single-instance guard (exit 183); Windows tray Disconnect/Reconnect;
  remote sessions get `TERM=xterm-256color` + `COLORTERM=truecolor`.
- **Namespace purge (`912299319`): NO `com.mitchellh.*` anywhere** — hard rule,
  see the `ghoztty-no-mitchellh-namespace` memory. Debug app is now
  **`com.dzearing.ghoztty.debug`** (ALL automation — osascript `app id`,
  `defaults` — must use this). Defaults were migrated old→new domain.
- **Infra:** relay = Azure VM `ghoztty-relay`
  (`ghoztty-relay-dz17575.westus2.cloudapp.azure.com`, RG `ghoztty-relay-rg`);
  ssh as `azureuser`. `/dl/` serves the CURRENT installer + agent exe
  (single-instance + tray + keepalive + COLORTERM). Browser-enrollment code is
  DEPLOYED but dormant (`web_enroll=false`) until the Web OAuth client exists.
  Devices: `Home PC` (= MaximusHome, hostname subtext works),
  `windows-remote` (corp PC, OLD binary), `Davids-Personal-Macbook-Pro.local`
  (this Mac; hidden from chooser as "this Mac" == Local).

## Standing items (the queue)

**Needs the USER:**
1. Register the **`ghoztty-web`** OAuth client (Google Console → Credentials →
   OAuth client ID → **Web application**; authorized redirect URI EXACTLY
   `https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/enroll/callback`),
   paste id+secret → orchestrator sets `GOOGLE_WEB_CLIENT_ID/_SECRET` in
   `/etc/ghoztty-relay.env`, restarts relay (log shows `web_enroll=true`),
   then live-verify one-click browser enrollment. This secret IS confidential.
2. **Re-sign-in once** after the namespace purge (Keychain service renamed).
3. **MaximusHome: re-run the installer one-liner** (`irm https://<fqdn>/dl/install.ps1 | iex`)
   to pick up the new exe; then on-box verify: single tray icon even when
   double-supervised (second launch exits 183), tray Disconnect/Reconnect +
   status tooltip, relay-mode-only menu items. Pick ONE supervisor
   (recommended: installer autostart; retire the SMB watcher there).
4. `windows-remote` (corp Cloud PC) still runs the OLD agent — installer
   re-run there someday brings hostname/keepalive/single-instance.

**GUI verifications not yet done:**
5. Title-restore round trip (rename windows → sign out/in or Restore (N) →
   titles kept; then `printf '\e]0;x\a'` must NOT clobber the user title).
6. Rename→open-window propagation (pill + `AXGhosttyMachine` update live;
   ztabby consumes the AX attribute — check via
   `osascript … attribute "AXGhosttyMachine" of every window`).
7. WP-D1 pill walkthrough: freeze/kill local agent → yellow "reconnecting" →
   green re-attach (kill -STOP/-CONT) or red "disconnected" (agent killed).
8. Real sleep/wake keepalive confirmation (happens organically overnight —
   check the device stays/returns Online after the Mac sleeps).

**Engineering follow-ups (small, noted by subagents):**
9. Agent daemon doesn't re-read `relay.env` after a re-enroll (needs restart);
   enroll's relay.env write racing a live daemon deserves atomic write+signal.
10. Chooser list is fetch-on-open only — live online/offline updates while the
    chooser is open would be nice.
11. WP-E1 productionization: move relay to the home NUC behind a Cloudflare
    Tunnel, audit logging, rate limits, credential rotation. Last roadmap phase.

## Gotchas that will bite again (also in memories)
- Debug rebuilds re-sign ad-hoc → Keychain permission prompt ("Always Allow")
  or occasional full re-sign-in; each rebuild is a "new app" to the Keychain.
- Dial to an OFFLINE device: ~2min block → modal OK alert (AX-click
  `button "OK" of window 1` of the app process to clear).
- Quit with windows → "Close Ghoztty" confirm dialog (AX-click it).
- A wrong/stale DEVICE token = agent control WS connect→drop 3s loop
  (dup-control kick); this Mac's creds live in `~/.config/ghoztty/relay.env`.
- `grep -c` exits 1 on zero matches — don't let it kill a `&&` deploy chain.
- Toolchain: `export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH;
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Relay deploy: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build` in `relay/`,
  scp + `sudo install` + `systemctl restart ghoztty-relay`; agents auto-reconnect.
  Windows agent: `zig build agent -Dtarget=x86_64-windows-gnu` → scp exe to
  `/var/www/ghoztty-dl/`.
