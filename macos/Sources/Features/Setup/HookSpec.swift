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

/// Builds the per-event `bash` command. Reads stdin, normalizes the runtime
/// payload to `{prompt, session_id}` with awk (NO jq), passes `prompt` to the
/// banner script on stdin (never interpolated into the command), and strips
/// control bytes. `SCRIPT` is the stable banner-script path.
enum HookCommand {
    static func perEvent(purpose: HookPurpose, bannerScriptPath: String) -> String {
        let s = shellQuote(bannerScriptPath)
        switch purpose {
        case .sessionStart:
            return "bash \(s) session-start-hook"
        case .stop:
            return "bash \(s) stop-hook"
        case .promptSubmit:
            // The banner script reads stdin itself (input=$(cat)) and does the
            // jq-free extraction + sanitization. No shell interpolation of
            // prompt text happens here.
            return "bash \(s) prompt-hook"
        }
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
