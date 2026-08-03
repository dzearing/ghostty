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

    func configDirectoryURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(configDirectoryName, isDirectory: true)
    }
}
