# WP4 — macOS UI: machine chooser + remote windows + inheritance

> Implementation blueprint (from code recon 2026-06-26). Feature: a debug Ghoztty
> on macOS where **Cmd-N** = local window, **Cmd-Shift-N** = machine-chooser →
> window whose terminal runs on a remote machine (over our TCP transport to a
> `ghoztty-agent`), and **new windows/splits from a machine window inherit that
> machine**. Anchored to file:line so implementers go straight there.

## Key seams (verified file:line)

| What | File | Line(s) |
|------|------|---------|
| Cmd-N action | `macos/Sources/App/macOS/AppDelegate.swift` | 968–970 `@IBAction newWindow:` → `TerminalController.newWindow(ghostty)` |
| New-window entry (inject baseConfig here) | `macos/Sources/Features/Terminal/TerminalController.swift` | 249–333 `static func newWindow(_, withBaseConfig:)` |
| New-tab | `TerminalController.swift` | 401–448 `newTab(from:withBaseConfig:)` |
| **Split inheritance hook** | `macos/Sources/Features/Terminal/BaseTerminalController.swift` | 276–339 `newSplit(...)` — `effectiveConfig = config ?? SurfaceConfiguration()` (line 288); children inherit whatever the parent's baseConfig carries |
| Per-window metadata (add `remoteMachine` here) | `BaseTerminalController.swift` | 104 `windowName`; 1031 `window.title` |
| Swift surface config model (add fields) | `macos/Sources/Ghostty/Surface View/SurfaceView.swift` | 616–742 `struct SurfaceConfiguration` + `withCValue()` |
| Swift→C surface creation | `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` | 221–357 (`ghostty_surface_new` at 356–357) |
| C surface config (already has the fields!) | `include/ghostty.h` | 490–500 — `ghostty_remote_connection_t connection;` + `const char* session_id;` (no change needed) |
| Existing SSH remote C API (reference) | `src/apprt/embedded.zig` | 2008–2069 `ghostty_remote_connection_new/_start/_wait_handshake/_latency_ms/_free` |
| **TCP dialer to call from new C API** | `src/remote/tcp_dial.zig` | `dial(alloc, host, port, encoding) -> Dialed{ .conn, ... }` |
| Menu shortcut sync | `macos/Sources/Ghostty/Ghostty.MenuShortcutManager.swift` | 23–98; `AppDelegate.syncMenuShortcuts` 1159–1228 |
| Dialog pattern to copy | `macos/Sources/Features/Command Palette/CommandPalette.swift` | 69–150 (filterable list + `@Binding isPresented`) |

## Phased plan (smallest first)

**Phase 1 — foundation (Zig + Swift model, no UI):**
1. **TCP C API** in `embedded.zig` (next to the SSH one): `export fn ghostty_remote_connection_new_tcp(host: [*:0]const u8, port: u16) ghostty_remote_connection_t` that calls `tcp_dial.dial(...)`, populating the same `RemoteConnectionHandle.transport` the SSH path uses (for TCP, dial blocks to handshake so a separate `_start` is a no-op / fold in). Declare in `include/ghostty.h`.
2. **Extend `SurfaceConfiguration`** (SwiftView.swift): add `remoteMachine: Machine?` + `remoteSessionId: String?`; in `withCValue()` set `config.connection` (from the machine's live handle) + `config.session_id`.
3. **`Machine` struct + registry** (Swift): `struct Machine: Codable, Identifiable { id; name; host; port; transport("tcp"); ... }`. Start with an in-memory/UserDefaults list in `AppDelegate` (config-file parsing is Phase 3).
4. **Attach machine to window** (`BaseTerminalController`): `var remoteMachine: Machine?`; title shows `… — <machine.name>`.

**Phase 2 — UI:**
5. **`MachineChooserView.swift`** (new) — copy CommandPalette’s filterable list; returns the chosen `Machine`.
6. **Cmd-Shift-N** (`AppDelegate` + `MainMenu.xib`): `@IBAction newRemoteWindow:` → show chooser → on pick: `ghostty_remote_connection_new_tcp(host, port)` → `_wait_handshake` → build `SurfaceConfiguration` with the connection handle + `remoteMachine` → `TerminalController.newWindow(ghostty, withBaseConfig:)`. Inheritance falls out for free because splits/tabs reuse the parent's baseConfig.

**Phase 3 — polish:** machine registry from a config file (`~/.config/ghostty/machines.toml` or a `[machines]` section); `machine:` title via OSC; latency indicator.

## Biggest risk
**Lifetime of `ghostty_remote_connection_t` across surfaces.** The handle may be shared by multiple surfaces/splits in a machine window and must NOT be freed when one surface closes — only when the last referencing surface/window goes away. Mitigation: ref-count the handle (Zig side `RemoteConnectionHandle` already owns transport+threads) or track strong refs Swift-side; verify `RemoteConnectionHandle.deinit` doesn't close the transport early and that `Surface.remoteBackend()` falls back to local if the connection is gone. Also relevant: the [[ghoztty-remote-progress-doc]] channel-rendezvous cleanup (client `openChannel` vs server-authoritative channel) should land before the GUI relies on `Connection.openChannel`.

## Dependencies / sequencing
- Phase 1 step 1 (TCP C API) depends on a STABLE `tcp_dial`/`connection` — do it AFTER the M2 catch-up/reconnect work integrates (that track may touch `tcp_dial`/`connection.zig`).
- The Swift work (steps 2–6) is in `macos/` — disjoint from the Zig agent/transport files, so it can be built in parallel once the C API symbol exists (the app links libghostty, so the C API must compile before the app builds).
