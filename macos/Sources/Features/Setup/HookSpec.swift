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

/// Builds the per-event `bash` command. Each runtime's payload is normalized to
/// the canonical `{prompt, session_id}` shape with a jq-free awk seam BEFORE the
/// shared banner script runs, so the shared script is never edited to add a
/// runtime. The command passes `prompt` to the banner script on stdin (never
/// interpolated into the command). `SCRIPT` is the stable banner-script path.
enum HookCommand {
    static func perEvent(purpose: HookPurpose, bannerScriptPath: String, runtime: RuntimeAgent) -> String {
        let s = shellQuote(bannerScriptPath)
        let mode: String
        switch purpose {
        case .sessionStart: mode = "session-start-hook"
        case .promptSubmit: mode = "prompt-hook"
        case .stop: mode = "stop-hook"
        }
        // The Stop event carries no stdin fields the script reads, so it never
        // needs normalization. Otherwise pipe stdin through the runtime's
        // normalizer (identity for Claude) before the shared script.
        guard purpose != .stop, let norm = normalizer(for: runtime, purpose: purpose) else {
            return "bash \(s) \(mode)"
        }
        return "\(norm) | bash \(s) \(mode)"
    }

    /// The runtime's jq-free stdin normalizer, or nil when the payload is already
    /// canonical (identity). Maps that runtime's key names to the canonical
    /// `{prompt, session_id}` the shared script consumes.
    private static func normalizer(for runtime: RuntimeAgent, purpose: HookPurpose) -> String? {
        switch runtime {
        case .claude:
            // Claude's hook payload is already flat `{prompt, session_id}`, so its
            // normalizer is the identity — no rewrite needed.
            return nil
        case .copilot:
            // Copilot userPromptSubmitted payload keys are unverified against a
            // live hook — confirm and tighten. Until then, accept BOTH
            // snake_case and camelCase for the session id, and try several
            // likely prompt keys, so a key mismatch degrades to an empty field
            // rather than a broken banner.
            let promptKeys = purpose == .promptSubmit
                ? ["prompt", "userPrompt", "content", "message"]
                : ["prompt"]
            return awkNormalizer(promptKeys: promptKeys, sessionKeys: ["session_id", "sessionId"])
        }
    }

    /// A single-line, jq-free awk program that reassembles stdin, extracts the
    /// raw JSON-escaped string value for the first matching key from each list,
    /// and re-emits a canonical one-line `{"prompt":..,"session_id":..}` object.
    /// Single-line so it embeds safely inside a JSON hooks file.
    static func awkNormalizer(promptKeys: [String], sessionKeys: [String]) -> String {
        let pk = promptKeys.joined(separator: " ")
        let sk = sessionKeys.joined(separator: " ")
        let program = "{ rec = rec $0 } "
            + "END { printf \"{\\\"prompt\\\":\\\"%s\\\",\\\"session_id\\\":\\\"%s\\\"}\\n\", g(\"\(pk)\"), g(\"\(sk)\") } "
            + "function g(keys,   a,n,ki,i,c,o,e,p) { "
            + "n = split(keys, a, \" \"); "
            + "for (ki=1; ki<=n; ki++) { "
            + "p = \"\\\"\" a[ki] \"\\\"\"; i = index(rec, p); if (!i) continue; "
            + "i += length(p); "
            + "while (i<=length(rec) && substr(rec,i,1) ~ /[ \\t\\r\\n]/) i++; "
            + "if (substr(rec,i,1) != \":\") continue; i++; "
            + "while (i<=length(rec) && substr(rec,i,1) ~ /[ \\t\\r\\n]/) i++; "
            + "if (substr(rec,i,1) != \"\\\"\") continue; i++; "
            + "o=\"\"; e=0; "
            + "while (i<=length(rec)) { c=substr(rec,i,1); "
            + "if (e){o=o c; e=0; i++; continue}; "
            + "if (c==\"\\\\\"){o=o c; e=1; i++; continue}; "
            + "if (c==\"\\\"\") break; "
            + "o=o c; i++ }; "
            + "return o }; return \"\" }"
        return "LC_ALL=C awk '\(program)'"
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
