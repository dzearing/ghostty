import Foundation

enum GhosttyAssetsError: Error, LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self {
        case .missing(let what): "Bundled Ghoztty asset missing: \(what)"
        }
    }
}

/// Reads the skill markdown + banner script bundled under `Ghoztty/` in the app
/// bundle's Resources. The bundle is the source of truth for the app-install path.
enum GhosttyAssets {
    static var rootURL: URL {
        get throws {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Ghoztty", isDirectory: true),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw GhosttyAssetsError.missing("Ghoztty resources root")
            }
            return url
        }
    }

    static func skillMarkdown(_ name: String) throws -> String {
        let url = try rootURL
            .appendingPathComponent("skills/\(name)/SKILL.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GhosttyAssetsError.missing("skill \(name)")
        }
        return text
    }

    static func bannerScript() throws -> String {
        try hookScript(HookScripts.bannerName, describedAs: "banner script")
    }

    static func activityStateScript() throws -> String {
        try hookScript(HookScripts.activityStateName, describedAs: "activity-state script")
    }

    private static func hookScript(_ name: String, describedAs what: String) throws -> String {
        let url = try rootURL.appendingPathComponent("hooks/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GhosttyAssetsError.missing(what)
        }
        return text
    }
}
