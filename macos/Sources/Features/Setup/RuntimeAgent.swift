// macos/Sources/Features/Setup/RuntimeAgent.swift
import Foundation

/// A coding-agent runtime Ghoztty can register with. One case per supported CLI.
enum RuntimeAgent: String, CaseIterable, Sendable {
    case claude
    case copilot

    /// Home-relative config directory the runtime owns.
    var configDirectoryName: String {
        switch self {
        case .claude: ".claude"
        case .copilot: ".copilot"
        }
    }

    /// User-facing name for dialogs and summaries.
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .copilot: "Copilot CLI"
        }
    }

    /// Whether Ghoztty offers to set this runtime up in first-launch and the
    /// manage UI. Copilot's per-turn instruction envelope and normalizer keys
    /// are unverified against a live hook (see agent-integration review H3), so
    /// it is gated off until a real payload is captured and the fix is verified.
    /// Existing installs are unaffected — they still surface in the manage panel
    /// and can be removed.
    var isOffered: Bool {
        switch self {
        case .claude: true
        case .copilot: false
        }
    }

    func configDirectoryURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(configDirectoryName, isDirectory: true)
    }
}
