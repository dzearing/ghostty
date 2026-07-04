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

## 2026-07-03 EVENING SESSION (tip `03ca52586`) — dup-agent + reconnect overhaul

Eight commits landed (all worktree-subagent work, cherry-picked, rebuilt, and
live-verified in the GUI; agent exe deployed to the SMB share AND `/dl/`):

- `27e639ae6` chooser live polling (5s while open; item 10 DONE).
- `14515562c` relay.env hot-reload after re-enroll (item 9 DONE).
- `4a55acef1` `+new-remote-window --name` now registers TCP windows in the IPC
  registry (was relay-only — `+send-keys`/`+read`/`+close` now work on TCP
  windows); CLI prints the server's real error instead of the misleading
  "not supported on this platform" (sendIpc parses the `error` field).
- `1b6b873e0` dup-daemon holes closed: Windows mutex was `Local\` (per LOGON
  SESSION — a scheduled-task supervisor lives in a different session than an
  interactive one, so two same-user daemons never collided) → now
  `Global\GhozttyAgentDaemon-<user-SID>` (fallback: username, then legacy
  Local\). Plus fast-drop backoff: control conn that dies <30s after connect
  escalates 3s→…→120s cap ±20% jitter (dup-token fights converge to ~2min
  knocks, not 3s pegging); cred-bounce and dial-failures exempt.
- `05ccc9051` "THERE SHOULD BE ONLY ONE" takeover protocol: holder writes
  `agent.heartbeat` (PID, touched every 10s; next to relay.env / agent.lock);
  a challenger finding the guard held reads it — fresh (<45s) → yield (exit
  183), stale → image-verify the PID (must be ghoztty-agent — no PID-reuse
  friendly fire) → kill → re-acquire (5×200ms) → take over; still held → die.
  `--force-replace` (alias `--replace`) skips the ping. No heartbeat file =
  old-binary holder → yield (upgrade rule).
- `38ff0c0e3` + `03ca52586` WP-D1 long-outage overhaul (see item 7).

**MaximusHome pegging incident — RESOLVED + VERIFIED.** The relay was taking
~1100 "agent online"/hr from the box (two agents sharing one device token,
dup-control-kicking each other every ~3s; user confirmed 2 ghoztty-agent.exe).
Cause: two supervisors (scheduled task `GhozttyAgent` from install.ps1 + the
user's SMB watcher script) × the Local\ mutex hole × old binary. Fix rollout:
new exe dropped on the SMB share (temp+rename; watcher hot-swaps within ~3s)
— relay went from 33 onlines/2min to ZERO, single stable conn, user confirmed
1 process. Both supervisors now launch the SAME new exe so the loser exits 183;
`Unregister-ScheduledTask -TaskName 'GhozttyAgent' -Confirm:$false` is optional
cosmetics now. The watcher script still embeds a DEAD fallback DEVICE_TOKEN —
delete someday. `/dl/ghoztty-agent.exe` refreshed to the same build.

**New gotchas (bit us today):**
- ~~The pill text is NOT in the AX window `title` and `AXGhosttyMachine` doesn't
  carry link state — automation must screenshot to read pill state.~~ FIXED
  07-03 late (`97530c9ac`): every terminal window now exposes
  **`AXGhosttyLinkState`** — `connected` | `reconnecting:<attempt>` (1-based) |
  `disconnected` | `local`; updates live from the same didSet that recolors the
  pill dot. VERIFIED via loopback freeze/thaw: `connected` → `reconnecting:1`
  (~12s after SIGSTOP) → `connected` after SIGCONT (`disconnected` not
  exercised live; mapping unit-tested). Read it with:
  `osascript -e 'tell application "System Events" to tell (first application
  process whose bundle identifier is "com.dzearing.ghoztty.debug") to get
  {value of attribute "AXGhosttyMachine", value of attribute
  "AXGhosttyLinkState"} of every window'`.
  Bonus learned: `--name`-pinned windows report the pinned name in
  `AXGhosttyMachine` (loopback window read `lb`, not `127.0.0.1`).
- A `kill -STOP`'d process started by a Bash tool call gets pending teardown
  signals DELIVERED AT SIGCONT (nohup doesn't cover it) — run whole
  freeze/thaw cycles in ONE tool call, and verify the exact PID is alive
  before drawing conclusions ("agent alive" once matched the *other* agent).
- AppleScript can't match a window by emoji title (`"👻"`); index via the
  `AXGhosttyMachine` values-list instead. AX-clicking sheets: button 1 may be
  Cancel — click by name ("Close").
- Loopback TCP windows report `AXGhosttyMachine="127.0.0.1"`, not "Local" —
  undecided whether that's right for ztabby.

## 2026-07-03 LATE SESSION (tip `81792453a`) — automation follow-ups

Two worktree-subagent commits cherry-picked, rebuilt, relaunched, live-verified:
- `97530c9ac` `AXGhosttyLinkState` AX attribute (see gotchas — the screenshot
  workaround is dead).
- `81792453a` IPC registry names persist in the manifest across restore (see
  item 5).
Relay health checked: MaximusHome churn stopped EXACTLY at the evening exe
rollout (~18 onlines/min → silence at 23:35Z); since then one reconnect at
00:01Z + a 2-device blip 04:27–04:30Z, zero errors — the dup-agent fix holds.
Keychain stable-signing carry-over held again this session (rebuild →
relaunch → manifest restore dialed MaximusHome with NO prompt).

## Standing items (the queue)

**Needs the USER:**
1. Register the **`ghoztty-web`** OAuth client (Google Console → Credentials →
   OAuth client ID → **Web application**; authorized redirect URI EXACTLY
   `https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com/enroll/callback`),
   paste id+secret → orchestrator sets `GOOGLE_WEB_CLIENT_ID/_SECRET` in
   `/etc/ghoztty-relay.env`, restarts relay (log shows `web_enroll=true`),
   then live-verify one-click browser enrollment. This secret IS confidential.
2. ~~Re-sign-in once~~ DONE 07-03 evening (user). Keychain item exists under
   `com.dzearing.ghoztty.relay-account`; account dials work (MaximusHome
   relay window round-tripped `hostname`). NOTE: the post-rebuild relaunch
   popped the password-form Keychain prompt (ad-hoc re-sign = "new app");
   user clicked through — expect an occasional repeat after rebuilds.
3. ~~MaximusHome installer re-run / pick one supervisor~~ MOSTLY DONE via the
   evening-session rollout (see above): new exe live, single agent, loop dead.
   STILL PENDING on-box: tray Disconnect/Reconnect + tooltip eyeball, and the
   optional `Unregister-ScheduledTask GhozttyAgent` + watcher fallback-token
   removal.
4. `windows-remote` (corp Cloud PC): its DEVICE WAS REMOVED from the relay
   store (only 2 devices remain: this Mac + MaximusHome); its old agent still
   knocks with a revoked token from an Azure IP (harmless). Installer re-run
   there someday re-enrolls it.

**GUI verifications not yet done:**
5. ~~Title-restore round trip~~ DONE 07-03 evening: `+rename --target=mx
   --title="My MaximusHome"` → remote `title ClobberAttempt` (cmd.exe OSC)
   did NOT clobber it, while an un-titled sibling window correctly FOLLOWED
   OSC titles; quit → relaunch → manifest replayed and the user title
   SURVIVED. Bonus verified: sign-in manifest replay (user's re-sign-in
   auto-restored an old MaximusHome window). ~~Follow-up: IPC registry
   names do NOT survive restore~~ FIXED + VERIFIED 07-03 late
   (`81792453a`): manifest `Entry.ipcName` (optional — legacy entries
   decode fine, confirmed against the live pre-fix manifest); restore
   re-registers via `IPCServer.registerRestoredRemoteWindow` (name-taken
   ⇒ existing live target wins, idempotent CLI semantics); both launch
   and sign-in replay paths covered; 18/18 manifest tests. Live round
   trip: `+new-remote-window --relay=… --device=<MaximusHome>
   --name=mx` → `+send-keys`/`+read` OK → quit → relaunch → `+read
   --name=mx` and `+send-keys --target=mx` still work (replayed
   scrollback even kept the pre-quit output). NOTE: local-window
   `+new-window --target=` names still don't survive relaunch (no
   manifest for local windows — separate, probably fine).
6. ~~Rename→open-window propagation~~ DONE (fix `37f81c4a7` cherry-picked,
   rebuilt, VERIFIED live): device rename via chooser ⋯ now flips a
   manifest-RESTORED window's pill/`AXGhosttyMachine` within ~1s (verified
   "MaximusHome"→"Home PC"→back, twice). Root causes fixed: rename
   propagation was gated on a registry-row lookup that could silently fail
   after the PATCH; poll-path renames (other Macs/processes) updated chooser
   rows only; explicit `--name` windows now PIN their label (`namePinned` in
   Machine + manifest — intentional, survives renames/restores). NOTE from
   that investigation: running TWO debug instances (zig-out + the
   macos/build/Debug xcodebuild product share the bundle id — LaunchServices
   can launch either on `open -b`) breaks process-local notification paths;
   kill the duplicate before GUI verification.
   ALSO FIXED tonight: Keychain "Always Allow" now SURVIVES rebuilds — the
   debug bundle is signed with the stable local "Ztabby Debug Signing" cert
   instead of ad-hoc (`GHOSTTY_CODESIGN_IDENTITY` overrides; falls back to
   ad-hoc when no cert). Verified: rebuild → relaunch → restore dialed with
   NO password prompt.
   ~~takeAll() crash-safety~~ FIXED + VERIFIED (`564c54d6f` cherry-picked):
   `snapshotForRestore()` marks entries in-flight WITHOUT draining disk;
   success does an atomic `register(replacing:)` swap; unreachable/no-token
   → `releaseRestore` (entry stays for next launch); gone → explicit remove;
   `reinstate()` deleted. 16/16 manifest tests. Live kill-test: kill -9
   during a Keychain-blocked restore → manifest intact → next launch
   restored the window. Also: the unit-test HOST app now skips IPC start +
   restore under XCTest (it used to steal the live app's IPC socket and
   drain its manifest). Historical loss from before the fix: two orphaned
   sessions remain on MaximusHome (idle cmd.exe — harmless).
   Keychain carry-over CONFIRMED for the stable-signed lineage: quit →
   relaunch restores with NO prompt ("Always Allow" bound to the stable
   designated requirement `identifier + certificate leaf`; the one repeat
   prompt tonight was the earlier grant landing on the last AD-HOC build).
7. ~~WP-D1 pill walkthrough~~ DONE (loopback TCP agent, screenshots): yellow
   "reconnecting… (N)" on freeze/kill with local-suppression correctly lifted;
   green re-attach after short outage (grid + I/O intact); red "disconnected"
   after the 10-attempt budget, window kept. FOUND + FIXED two deep bugs on
   the long-outage path (`38ff0c0e3`, `03ca52586`): (a) dial handshake had no
   deadline — a frozen listener still TCP-accepts, so attempt (1) hung forever
   (now 10s `HandshakeTimeout`); re-attach REPLAY was discarded client-side
   (blank grid — the §7.3 resync filter dropped the agent's gap-fill; restored
   windows now replay retained scrollback too); stale DETACH from the replaced
   connection silenced the re-attached session (ownership guards in agent
   handleDetach/handleFlow); (b) the REAL wedge: the agent PANICKED at
   SIGCONT — backlog sockets made `setsockopt(SO_NOSIGPIPE)` return EINVAL,
   declared `unreachable` in zig std (now raw libc, best-effort). Client also
   gained a forever background re-dial after exhaustion (45s+jitter; pill
   stays red until a probe truly succeeds; session-gone stays terminal).
   Final independent verify: 130s freeze → red → thaw → SELF-HEALED in 6s,
   agent survived, I/O round-trips. wp4-e2e gained Phase 4 (SIGSTOP/SIGCONT
   regression; 175s soak behind `GHOZTTY_E2E_LONG_FREEZE=1`); `test-agent`
   now runs the formerly-orphaned agent-core suite (375 tests).
8. Real sleep/wake keepalive confirmation (happens organically overnight —
   check the device stays/returns Online after the Mac sleeps). Partial
   organic evidence 07-03: this Mac's agent re-onlined cleanly 3× in an hour
   and held a stable conn all day; late-session relay check: agent process
   up since 6:11AM local, both devices quiet on the relay for hours (one
   clean 2-device re-online blip 04:27Z). Looking good — call it done after
   one overnight pass.

**Engineering follow-ups (small, noted by subagents):**
9. ~~Agent daemon doesn't re-read `relay.env` after a re-enroll (needs restart);
   enroll's relay.env write racing a live daemon deserves atomic write+signal.~~
   DONE: `saveRelayEnv` is atomic (tmp+rename, both OSes); the relay daemon
   watches relay.env (5s stat poll, `src/remote/agent/relay_creds.zig`) and
   on a token change bounces the control link and redials with the new
   credential. `GHOSTTY_DEVICE_TOKEN` still wins (change logged + ignored);
   tray Disconnect stays parked. Verified live (rotate relay.env under a
   running `--relay` daemon → "reconnecting with the new credential").
10. ~~Chooser list is fetch-on-open only~~ DONE (`27e639ae6`): 5s poll while
    open (skips when signed out; in-flight guard; quiet failures keep the
    last-known list, footer error only after 3 consecutive misses; selection
    anchored by UUID). GUI eyeball of live dot-flips still worthwhile once
    signed in.
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
