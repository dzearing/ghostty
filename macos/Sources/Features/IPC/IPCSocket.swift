import Foundation
import GhosttyKit

/// The address of this app instance's IPC socket.
///
/// The socket name is per-BUILD (a `-debug` suffix for debug/release-safe
/// builds), so two Ghoztty builds can run side by side. The CLI binary, by
/// contrast, derives that name from ITS OWN compile-time build mode — and the
/// `ghoztty` on `$PATH` is normally the release app's binary. Without help,
/// a `ghoztty +split` run inside a debug-app pane would therefore dial the
/// RELEASE socket and drive the wrong instance.
///
/// The fix is to bake `path` into every pane's environment as
/// `GHOZTTY_IPC_SOCKET` (see `SurfaceView.init`) so an IPC command run inside
/// a pane always reaches the app that owns that pane. A full path (not a
/// build-flavor hint) is baked so this keeps working if the socket name ever
/// gains an instance discriminator.
///
/// Keep in sync with the CLI-side fallback derivation in
/// `src/apprt/ipc.zig` (`socketPath`), which is what a CLI invoked from a
/// plain non-Ghoztty shell — with no env var to consult — uses.
enum IPCSocket {
    /// Environment variable naming the socket, baked into every pane's env.
    static let envKey = "GHOZTTY_IPC_SOCKET"

    /// Absolute path of the AF_UNIX socket this app's IPC server binds.
    static let path: String = {
        let uid = getuid()
        let suffix = Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG
            || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE
            ? "-debug" : ""
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty\(suffix)-\(uid).sock").path
    }()
}
