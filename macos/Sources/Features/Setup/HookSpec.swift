// macos/Sources/Features/Setup/HookSpec.swift
import Foundation

enum HookOwnership { case dedicatedFile, mergedFragment }
enum HookPurpose { case sessionStart, promptSubmit, stop }

protocol HookSpec {
    var ownership: HookOwnership { get }
    var marker: String { get }
    func hookFileURL(homeDirectoryURL: URL) -> URL
    func renderedFile(bannerScriptPath: String) -> String
}

/// Builds the per-event `bash` command that the generated hook file runs. The
/// command just invokes the shared banner script with the event mode and the
/// invoking runtime (`--runtime=<name>`); the script itself reads the runtime's
/// payload with jq (both snake_case and camelCase), so there is no per-runtime
/// normalizer to embed and the shared script is never edited to add a runtime.
/// `SCRIPT` is the stable banner-script path; the payload is passed on stdin,
/// never interpolated into the command.
enum HookCommand {
    static func perEvent(purpose: HookPurpose, bannerScriptPath: String, runtime: RuntimeAgent) -> String {
        let s = shellQuote(bannerScriptPath)
        let mode: String
        switch purpose {
        case .sessionStart: mode = "session-start-hook"
        case .promptSubmit: mode = "prompt-hook"
        case .stop: mode = "stop-hook"
        }
        return "bash \(s) \(mode) --runtime=\(runtime.rawValue)"
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
