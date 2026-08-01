// macos/Sources/Features/Setup/CopilotHookSpec.swift
import Foundation

/// Copilot auto-loads every JSON in ~/.copilot/hooks/, so Ghoztty owns a
/// dedicated file. camelCase event names; version 1 envelope.
struct CopilotHookSpec: HookSpec {
    let ownership: HookOwnership = .dedicatedFile
    let marker = "ghoztty-managed"

    func hookFileURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".copilot/hooks/ghoztty.json")
    }

    func renderedFile(bannerScriptPath: String) -> String {
        func hook(_ cmd: String, _ timeout: Int) -> String {
            "[ { \"type\": \"command\", \"bash\": \(jsonString(cmd)), \"timeoutSec\": \(timeout) } ]"
        }
        let start = HookCommand.perEvent(purpose: .sessionStart, bannerScriptPath: bannerScriptPath, runtime: .copilot)
        let prompt = HookCommand.perEvent(purpose: .promptSubmit, bannerScriptPath: bannerScriptPath, runtime: .copilot)
        let stop = HookCommand.perEvent(purpose: .stop, bannerScriptPath: bannerScriptPath, runtime: .copilot)
        return """
        {
          "version": 1,
          "_comment": "\(marker)",
          "hooks": {
            "sessionStart": \(hook(start, 10)),
            "userPromptSubmitted": \(hook(prompt, 10)),
            "agentStop": \(hook(stop, 10))
          }
        }
        """
    }

    private func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
