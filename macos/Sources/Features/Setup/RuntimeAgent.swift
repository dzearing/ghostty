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

    /// Executable whose presence means the runtime is installed.
    var binaryName: String {
        switch self {
        case .claude: "claude"
        case .copilot: "copilot"
        }
    }

    /// Common install locations, in case the login shell's PATH misses them.
    /// Carried over from `ClaudeCodeIntegration.findClaude()`, which probed
    /// exactly these before the runtime-agnostic rewrite.
    ///
    /// Note these point at the runtime's OWN binary. `~/.claude/local/claude`
    /// sits inside the config dir but is not something Ghoztty writes, so it
    /// still disappears when the user removes the CLI — which is the property
    /// that matters here.
    func fallbackBinaryPaths(homeDirectoryURL: URL) -> [String] {
        let home = homeDirectoryURL.path
        return [
            "\(home)/\(configDirectoryName)/local/\(binaryName)",
            "\(home)/.local/bin/\(binaryName)",
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
        ]
    }
}

/// Whether a runtime's CLI is actually installed.
///
/// Deliberately NOT "does its config dir exist". Ghoztty WRITES into that dir
/// (`skills/`, and for Copilot `hooks/`), so keying detection on it means our
/// own leftovers go on reporting a CLI the user has since removed, and a
/// freshly installed CLI that has not been run yet reports absent. The design
/// doc calls this out by name: `isAvailable` is "a detection signal, kept
/// separate from the config dir Ghoztty writes into ... so that Ghoztty leaving
/// skills/hooks artifacts behind never makes a removed CLI look installed."
///
/// A struct of closures rather than a protocol so tests get a hermetic seam
/// without spawning a login shell.
struct RuntimeProbe: Sendable {
    var isInstalled: @Sendable (RuntimeAgent, URL) -> Bool

    /// The real probe: the runtime's binary on the login shell's PATH, else one
    /// of its common install locations.
    static let binary = RuntimeProbe { agent, home in
        if let result = LoginShell.run("command -v \(agent.binaryName)"), result.exitCode == 0 {
            return true
        }
        return agent.fallbackBinaryPaths(homeDirectoryURL: home)
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Test seam: exactly `agents` are installed, with no process spawned.
    static func stub(_ agents: Set<RuntimeAgent>) -> RuntimeProbe {
        RuntimeProbe { agent, _ in agents.contains(agent) }
    }
}
