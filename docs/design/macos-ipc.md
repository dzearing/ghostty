# macOS IPC for Declarative Terminal Workspaces

## Goal

Enable programmatic, declarative terminal workspace setup on macOS via CLI commands. All commands are idempotent — running a setup script twice focuses existing windows/panes rather than creating duplicates.

```bash
# Create a named workspace — re-running focuses instead of duplicating
ghoztty +new-window --target=dev --working-directory=~/project --command=vim
ghoztty +split --target=dev --name=server --direction=right --percent=30 --command="npm run dev"
ghoztty +split --pane=server --name=tests --direction=down --command="npm test"

# Tear down specific panes or entire windows
ghoztty +close --target=tests    # closes just the test pane
ghoztty +close --target=dev      # closes the entire window
```

## Background

The `+new-window` CLI action exists and works on Linux via D-Bus IPC. On macOS, `embedded.zig:performIpc` previously returned `false` because no IPC transport was implemented. The macOS app is a native Swift/Cocoa app that embeds the Ghostty Zig library via C function exports.

## Architecture

```
CLI (+new-window / +split / +close)
  → apprt.App.performIpc()
    → embedded.zig: Unix socket client
      → JSON over Unix socket
        → IPCServer.swift: parse, dispatch
          → TerminalController / NotificationCenter
```

### IPC Transport: Unix Domain Socket

Unix sockets are the simplest cross-language transport (Zig ↔ Swift) that avoids XPC entitlement complexity and deprecated distributed notifications.

**Socket path:** `$TMPDIR/ghostty[-debug]-$UID.sock`
- Debug/ReleaseSafe builds use `ghostty-debug-$UID.sock`
- ReleaseFast/ReleaseSmall builds use `ghostty-$UID.sock`
- This prevents debug builds from conflicting with a running release instance

**Instance addressability (`$GHOZTTY_IPC_SOCKET`):** because the name above is
per-BUILD while the CLI derives it from its OWN compile-time build mode — and
the `ghoztty` on `$PATH` is normally the release app's binary — a CLI run
inside a debug-app pane would dial the *release* socket and drive the wrong
instance. So every pane's environment is baked with the absolute socket path of
the app that owns it (`GHOZTTY_IPC_SOCKET`), and the CLI prefers it:

- Server: `IPCSocket.path` (`macos/Sources/Features/IPC/IPCSocket.swift`) is
  the single source of truth — `IPCServer` binds it, and `SurfaceView.init`
  bakes it into `surface_cfg.environmentVariables` for every pane (the one
  funnel covering local exec panes, session-persistence agent panes — the agent
  replays it on RELAUNCH — and remote panes, whose IPC still belongs to the
  local app).
- Client: `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`) is the single
  resolution site for every CLI command and apprt IPC client. Absent or empty
  ⇒ derive `<tmp>/ghostty[-debug]-<uid>.sock` as before, so a CLI invoked from
  a plain non-Ghoztty shell is unchanged, as is a pane baked by an app or agent
  that predates the variable.

A full path (not a build-flavor hint) is baked so this keeps working if the
socket name ever gains an instance discriminator.

**Socket security:**
- Mode `0600` (owner read/write only)
- `FD_CLOEXEC` set to prevent leaking into child processes
- Stale socket removed via `unlink()` before `bind()` on startup
- Socket removed in `applicationWillTerminate`

**Protocol:** Length-prefixed JSON messages.

```
[4 bytes: message length (big-endian uint32)][JSON payload]
```

Request:
```json
{
  "action": "new-window",
  "arguments": ["--target=dev", "--working-directory=/path", "--command=vim"]
}
```

Response:
```json
{
  "success": true
}
```

## CLI Actions

### `+new-window` — Create or Focus a Window

```bash
ghostty +new-window [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Register window with a name. If exists, focuses instead of creating. |
| `--working-directory=<path>` | Working directory for the initial surface |
| `--command=<cmd>` | Command to run in the initial surface |
| `--split=right\|down\|left\|up` | Create an initial split after window creation |
| `--split-command=<cmd>` | Command to run in the initial split pane |
| `--split-percent=<1-99>` | Percentage of space for the existing pane in the initial split. Defaults to 50. Only meaningful with `--split`. |
| `--name=<name>` | Name for the initial split pane (if `--split` is used) |
| `-e <cmd> [args...]` | Command (everything after `-e` becomes the command) |

**Idempotent behavior:** If `--target=X` is specified and a window named X already exists and is alive, the window is focused (`makeKeyAndOrderFront` + `NSApp.activate`) and no new window is created.

### `+split` — Create or Focus a Split Pane

```bash
ghostty +split [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Window to add the split to (by name). Defaults to frontmost. |
| `--name=<name>` | Register the pane with a name. If exists, focuses instead of creating. |
| `--direction=right\|down\|left\|up` | Split direction. Defaults to `right`. |
| `--percent=<1-99>` | Percentage of space for the existing pane. Defaults to 50. Values outside 1-99 return an error. |
| `--pane=<name>` | Split adjacent to the named pane instead of the focused surface. Returns an error if the pane doesn't exist. Can be used without `--target` to search across all registered targets. |
| `--command=<cmd>` | Command to run in the new pane |
| `--working-directory=<path>` | Working directory for the new pane |
| `-e <cmd> [args...]` | Command (everything after `-e` becomes the command) |

**Idempotent behavior:** If `--name=X` is specified and a pane named X already exists and is alive, the pane is focused via `BaseTerminalController.focusSurface()` and no new split is created.

**Target resolution:** If `--target` is specified, the named window's controller is looked up. If omitted, `TerminalController.preferredParent` (the most recently focused terminal window) is used.

### `+close` — Close a Named Pane or Window

```bash
ghostty +close --target=<name>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Required. The name of the pane or window to close. |

**Behavior by target type:**
- If target is a **pane name** → calls `closeSurface(_:withConfirmation: false)` on that surface
- If target is a **window name** → calls `closeWindowImmediately()` on the controller
- If target **doesn't exist** (already closed or never created) → returns success (idempotent)

`withConfirmation: false` skips the "process still running" dialog since this is a programmatic close.

## Target Registry

IPCServer maintains a `[String: TargetEntry]` dictionary that maps names to either windows or panes.

```swift
private enum TargetEntry {
    case window(WeakRef<TerminalController>)
    case pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)
}
```

- All references are **weak** — when a user manually closes a window/pane, the reference becomes `nil` automatically
- `pruneStaleTargets()` is called before lookups to remove dead entries
- Window names and pane names share a **single namespace** (last write wins if collision)
- Names are registered at creation time and removed on `+close`

## Implementation Details

### Auto-Launch

When `+new-window` is invoked and no running instance is found (socket connection fails), the binary becomes the master process instead of erroring. The CLI action stores the IPC request as JSON in `GlobalState.pending_ipc_json`, returns exit code 200, and `main` falls through to GUI startup. `GlobalState.skip_cli_args` prevents the config parser from interpreting IPC-specific flags (e.g. `--target`) as config keys. After the IPC server starts, `AppDelegate` dispatches the pending JSON through `IPCServer.dispatchPendingJson()`.

For `+split`, no auto-launch — it requires an existing window. For `+close`, no-op if no instance (idempotent).

### Split Creation (bypasses `ghostty_surface_split`)

Splits are created by calling `BaseTerminalController.newSplit()` directly rather than posting `Notification.ghosttyNewSplit`. This bypasses `ghostty_surface_split()` (which only accepts a direction) and also avoids a timing issue: `replaceSurfaceTree` moves focus via `DispatchQueue.main.async`, so checking `controller.focusedSurface` immediately after a notification would return the old surface, causing pane names to register to the wrong surface. Calling `newSplit()` directly returns the new `SurfaceView`, which is used for pane name registration.

### Thread Safety

- Socket server accepts connections on a background GCD serial queue
- All UI operations (`newWindow`, `closeSurface`, `focusSurface`) dispatch to `DispatchQueue.main`
- `stop()` uses `queue.sync` to safely cancel the accept source
- Window/split creation is fire-and-forget (response sent immediately, UI dispatched async)

### Zig JSON Serialization

Uses `std.json.Stringify` with `std.Io.Writer.Allocating` (same pattern as `src/terminal/c/types.zig`). Response parsing uses `std.json.parseFromSlice`. Reads use a `readFull` helper that loops to handle partial reads.

## Key Files

| File | Role |
|------|------|
| `src/apprt/embedded.zig` | Unix socket client: `performIpc` → `sendIpc` (shared helper) |
| `src/apprt/ipc.zig` | IPC action types, error set (`IPCFailed`, `NoRunningInstance`) |
| `src/global.zig` | `pending_ipc_json`, `skip_cli_args` fields for auto-launch |
| `src/main_c.zig` | `ghostty_cli_try_action` (exit code 200 handling), `ghostty_pending_ipc_json` export |
| `src/config/Config.zig` | `loadCliArgs` respects `skip_cli_args` flag |
| `src/cli/new_window.zig` | `+new-window` CLI action, auto-launch JSON builder |
| `src/cli/split.zig` | `+split` CLI action |
| `src/cli/close.zig` | `+close` CLI action |
| `src/cli/ghostty.zig` | CLI action registry (enum + runMain dispatch) |
| `include/ghostty.h` | C header for IPC action enums, structs, and pending IPC exports |
| `macos/Sources/Features/IPC/IPCServer.swift` | Socket server, target registry, action handlers, `dispatchPendingJson` |
| `macos/Sources/Features/IPC/IPCMessage.swift` | `IPCRequest` (Decodable) / `IPCResponse` (Encodable) |
| `macos/Sources/App/macOS/AppDelegate.swift` | Lifecycle: `ipcServer.start()` / `.stop()`, pending IPC dispatch |

## Build & Test

```bash
# Build (from repo root — requires Zig 0.15.2+, Xcode 26, Metal Toolchain)
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build -Doptimize=Debug

# +new-window auto-launches the app if no instance is running
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +new-window --target=test --title=test --command=bash
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +split --target=test --name=right --direction=right --percent=30 --command=top
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +close --target=right
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +close --target=test

# Re-runnable workspace script (no need to launch app separately)
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +new-window --target=dev --command=vim
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +split --target=dev --name=server --direction=right --percent=30 --command="npm start"
./zig-out/Ghoztty.app/Contents/MacOS/ghoztty +split --pane=server --name=tests --direction=down --command="npm test"
# Run again — focuses existing panes, no duplicates
```

Consult `HACKING.md` for full build prerequisites.

## Non-Goals

- Windows support (no macOS IPC on Windows)
- Replacing the existing GTK D-Bus implementation
- Full remote control API (focused on workspace setup/teardown)
- `--tab` support (could be added later)
