import Foundation
import OSLog

/// Sets up the Ghoztty plugin for the Claude Code CLI. Idempotent: running it
/// again when everything is installed reports success.
enum ClaudeCodeIntegration {
    private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: "ClaudeCodeIntegration"
    )

    static let marketplace = "dzearing/ghoztty-claude-plugin"
    static let plugin = "ghoztty@ghoztty-claude-plugin"

    enum Outcome {
        case installed
        case alreadyInstalled
        case claudeNotFound
        case failed(String)
    }

    /// Finds the claude CLI. Blocking: run off the main thread.
    static func findClaude() -> String? {
        if let result = LoginShell.run("command -v claude"),
           result.exitCode == 0,
           let path = result.stdout.split(separator: "\n").last(where: { $0.hasPrefix("/") }) {
            return String(path)
        }

        // Common install locations, in case the login shell PATH misses them.
        let home = LoginShell.homePath
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Adds the plugin marketplace and installs the plugin. Blocking: run off
    /// the main thread.
    static func install() -> Outcome {
        guard let claude = findClaude() else { return .claudeNotFound }

        let add = runClaude(claude, "plugin marketplace add \(marketplace)")
        guard add.ok else { return .failed(add.detail) }

        let install = runClaude(claude, "plugin install \(plugin)")
        guard install.ok else { return .failed(install.detail) }

        if add.alreadyDone && install.alreadyDone { return .alreadyInstalled }
        return .installed
    }

    private struct StepResult {
        let ok: Bool
        let alreadyDone: Bool
        let detail: String
    }

    private static func runClaude(_ claude: String, _ args: String) -> StepResult {
        guard let result = LoginShell.run("'\(claude)' \(args)", timeout: 120) else {
            return StepResult(ok: false, alreadyDone: false, detail: "Claude Code did not respond.")
        }

        let output = result.stdout + "\n" + result.stderr
        let alreadyDone = output.lowercased().contains("already")
        let ok = result.exitCode == 0 || alreadyDone
        let detail = String(
            output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
        logger.info("claude \(args, privacy: .public): exit=\(result.exitCode) already=\(alreadyDone)")
        return StepResult(ok: ok, alreadyDone: alreadyDone, detail: detail)
    }
}
