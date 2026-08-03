// macos/Sources/Features/Setup/GhosttyManagedMarker.swift
import Foundation

/// The single ownership token stamped into every Ghoztty-managed artifact, plus
/// the comment wrappers each file format needs. Every marker-guarded write and
/// drift check keys off this substring, so CHANGING THE TOKEN ORPHANS every
/// already-installed file (it keeps the old token, stops matching, and can no
/// longer be updated or uninstalled). It must never change in isolation — hence
/// one source of truth rather than a literal copied into each component.
enum GhosttyManagedMarker {
    static let token = "ghoztty-managed"

    /// `# ghoztty-managed` — shell scripts (the banner script).
    static var shellComment: String { "# \(token)" }

    /// `<!-- ghoztty-managed -->` — markdown (bundled skills).
    static var htmlComment: String { "<!-- \(token) -->" }
}
