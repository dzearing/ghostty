import Foundation
import os

// This defines the minimal information required so all other files can do
// `extension Ghostty` to add more to it. This purposely has minimal
// dependencies so things like our dock tile plugin can use it.
enum Ghostty {
    // The primary logger used by the GhosttyKit libraries.
    static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: "ghostty"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}
}

extension Bundle {
    /// The identifier to use as an `os.Logger` subsystem.
    ///
    /// `Bundle.main.bundleIdentifier` is `nil` when the executable is run
    /// directly from the command line (e.g. `ghoztty +help`) rather than
    /// launched as an app bundle. Force-unwrapping it there traps (SIGTRAP)
    /// and crashes the process during logger initialization — before the CLI
    /// error path can run — so we fall back to a fixed identifier. A logger
    /// must never crash the app.
    static var loggerSubsystem: String {
        Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty"
    }
}
