# Windows registration sites — what a Ghoztty build may write outside itself

**T1151.** This is the inventory the build-mode isolation rule (T350) never
had. That rule covers **endpoints** — the IPC pipe, the agent pipe, the state
directory — so a debug build cannot drive the user's terminal. It says nothing
about **registrations**: writes to `HKCU`, to the user's profile, or to anything
else the shell acts on for them. Those are invisible to every lane, because a
unit test can see the key name and the command string but never the decision to
write them.

Two real incidents made the class worth enumerating rather than meeting one
site at a time:

- **T1124** — the staging release under `zig-out-release\` rewrote
  `HKCU\Software\Classes\ghoztty\shell\open\command` to a scratch path. For
  days, clicking a `ghoztty://` link would have run a half-built exe.
- **T1146** — the agent autostart `Run` entry had the same shape and a worse
  blast radius, since the entry survives a reboot.

## The rule

> **A build that lives in a source checkout registers nothing.**

The one place that answers "is this exe build output?" is
`src/os/source_checkout.zig` (`inSourceCheckout`) — an exe with a `build.zig`
in any ancestor directory. It lives under `src/os/` rather than under the win32
apprt because the **agent** needs the same answer (`adopt.zig` retires the
user's standalone MSI product), and the agent does not import the apprt;
`src/apprt/win32/source_checkout.zig` re-exports it for the call sites that
already used that name.

Several sites carry a **stricter** gate instead: they act only from the
canonical install directory `%LOCALAPPDATA%\Programs\Ghoztty`
(`install_location.isInstallDir`). That implies the checkout rule — build
output is never the canonical install — so it satisfies this inventory.

Three launch-time self-heals spell their escape hatches the same way, on
purpose: `off`/`0` disables, `force` skips every gate, `gate` skips only the
build-mode gate so an acceptance script can prove the LOCATION gate refuses
without anyone launching a release build at the user's endpoints.

## The inventory

Each row is a write that OUTLIVES the process and that the OS, the shell, or
another program reads on the user's behalf. `test\win32\registration-sites.ps1`
asserts that this table covers every such site in the tree, so a new
registration added without a row goes red.

| # | Site | What it writes | Gate | Seam |
|---|------|----------------|------|------|
| 1 | `src/apprt/win32/url_scheme.zig` (`register`) | `HKCU\Software\Classes\ghoztty[-debug]` — the `ghoztty://` protocol handler, `shell\open\command` naming this exe | **location** (`inSourceCheckout`) + build-mode lineage in the class name | `GHOZTTY_URL_SCHEME` |
| 2 | `src/apprt/win32/LocalAgent.zig` (`ensureAutostart` / `writeAutostart`) | `HKCU\...\CurrentVersion\Run` — the agent Windows starts at sign-in | **location** (`inSourceCheckout`) + build-mode (debug uses a lineage-suffixed value name and only under a hook) | `GHOZTTY_AGENT_AUTOSTART` |
| 3 | `src/apprt/win32/PathInstaller.zig` (`ensureOnPath`) | `HKCU\Environment\Path` — the directory the `ghoztty` CLI resolves from, plus a `WM_SETTINGCHANGE` broadcast | **canonical install only** (stricter than the checkout rule) | `GHOZTTY_PATH_SELFHEAL` |
| 4 | `src/apprt/win32/AgentIntegration.zig` (`setupEnabled` → `agent_integration_service.install` → `BannerScriptInstaller`, `HookComponent`, `SkillComponent`) | `%USERPROFILE%\.config\ghoztty\hooks\*.sh` and the coding agent's own hook/skill config under `%USERPROFILE%` | **canonical install only** for the automatic first-run offer | `GHOZTTY_CLAUDE_SETUP` |
| 5 | `src/remote/agent/adopt.zig` (`maybeStart`) | uninstalls the standalone **Ghoztty Agent** MSI product (`msiexec /x`) and rewrites `HKCU\...\Run\GhozttyAgent` | **location** (`inSourceCheckout`) + build-mode — location gate added by T1151 | both `GHOSTTY_ADOPT_INSTALL_DIR` and `GHOSTTY_ADOPT_UNINSTALL_CMD` |

### Deliberately ungated, with the reason

| Site | What it writes | Why no location gate |
|------|----------------|----------------------|
| `src/apprt/win32/AgentIntegrationsDialog.zig`, `src/apprt/win32/ipc_agent_integration.zig` → `agent_integration_service.install` → `src/apprt/win32/BannerScriptInstaller.zig` | the same `%USERPROFILE%` hook/skill files as row 4 | An **explicit user action** (a dialog button, a CLI verb) is a request, not a self-heal, and the files it writes name the stable home paths — never a build directory (T867). A dev build performing it leaves nothing pointing into the checkout. |
| `src/remote/agent/msi_ca.zig` | deletes `schtasks /TN GhozttyAgent` and `%APPDATA%\...\Startup\ghoztty-agent.cmd` | Reachable only as an **MSI custom action**, i.e. from inside `msiexec` running an installer package. A repo build cannot enter it. |
| `scripts\go-loop-*.ps1`, `scripts\install-ownership.ps1` and the other repo scripts | the loop's own `HKCU\...\Run` entry and its per-user scheduled task | **Development infrastructure the loop owns**, not the app. These are run deliberately by name; nothing in them is a launch-time self-heal, and none of them is reachable by launching a build. |

### The state directory is a different class

`%LOCALAPPDATA%\ghoztty\*` — `session-layout.json`, `window_memory`,
`viewer_prefs`, `host_defaults`, the WebView2 profile, `updates\`, the log — is
**not** in this inventory. Those are the endpoints T350 already covers: every
one of them is lineage-suffixed (`-debug`) so a debug build has its own, and
nothing outside Ghoztty reads them. A repo **release** build does share the
user's state files, which is one more reason `-Doptimize=Debug` is mandatory
for development builds (`docs/claude/build.md`); it is not a registration and
gating it on location would break the portable and dev-install shapes that are
supposed to keep their own state.

## When you add a registration

1. Ask the location question at the site, with `inSourceCheckout` — do not
   invent a second mechanism.
2. Give it an env seam using the `off` / `force` / `gate` vocabulary, so the
   refusal can be demonstrated without a release build at the user's endpoints.
3. Add a row above.
4. Assert it in `test\win32\registration-sites.ps1` and, if the behavior has
   its own harness, there too.
