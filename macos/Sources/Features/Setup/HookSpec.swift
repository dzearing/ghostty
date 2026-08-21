// macos/Sources/Features/Setup/HookSpec.swift
import Foundation

enum HookOwnership { case dedicatedFile, mergedFragment }

/// Every hook Ghoztty registers, and which bundled script serves it.
///
/// The banner purposes keep the pane's sticky banner current; the activity
/// purposes own the pane's `idle`/`busy`/`needs_input` state machine (see
/// `ghoztty-activity-state.sh`, which is the single owner of that ordering).
enum HookPurpose {
    case sessionStart, promptSubmit, stop
    case activitySessionStart, activityPause, activityToolTick
    case activityAgentStart, activityAgentStop, activitySettle

    /// The verb this purpose passes to its script.
    var verb: String {
        switch self {
        case .sessionStart: "session-start-hook"
        case .promptSubmit: "prompt-hook"
        case .stop: "stop-hook"
        case .activitySessionStart: "session-start"
        case .activityPause: "pause"
        case .activityToolTick: "tool-tick"
        case .activityAgentStart: "agent-start"
        case .activityAgentStop: "agent-stop"
        case .activitySettle: "settle"
        }
    }

    /// Whether this purpose runs the activity-state script rather than the banner.
    var usesActivityScript: Bool {
        switch self {
        case .sessionStart, .promptSubmit, .stop: false
        default: true
        }
    }
}

/// Where the hook scripts live once installed. They are siblings in one
/// Ghoztty-owned directory, and the BANNER path is what gets threaded through
/// the specs — it predates the second script and uniquely identifies the
/// install location. Every other script is resolved as its sibling here, so
/// exactly one place knows the layout.
enum HookScripts {
    static let bannerName = "ghoztty-banner.sh"
    static let activityStateName = "ghoztty-activity-state.sh"

    /// The owned directory both scripts sit in. This — not either script path —
    /// is the hook-ownership signature, so a merged fragment's activity-state
    /// elements are recognized as ours alongside the banner ones. A pre-existing
    /// install that only has banner commands still matches, since its path is
    /// inside this directory.
    static func directory(bannerScriptPath: String) -> String {
        (bannerScriptPath as NSString).deletingLastPathComponent
    }

    static func activityState(bannerScriptPath: String) -> String {
        (directory(bannerScriptPath: bannerScriptPath) as NSString)
            .appendingPathComponent(activityStateName)
    }

    static func path(for purpose: HookPurpose, bannerScriptPath: String) -> String {
        purpose.usesActivityScript
            ? activityState(bannerScriptPath: bannerScriptPath)
            : bannerScriptPath
    }
}

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
        let s = shellQuote(HookScripts.path(for: purpose, bannerScriptPath: bannerScriptPath))
        return "bash \(s) \(purpose.verb) --runtime=\(runtime.rawValue)"
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
