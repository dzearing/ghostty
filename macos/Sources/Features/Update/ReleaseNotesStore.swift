import Foundation

/// One bullet in a release-notes section. `title` is the bold lead of a
/// `- **Title** — text` bullet; a plain bullet stores the whole line as `text`.
struct ReleaseNote: Decodable, Equatable {
    let title: String?
    let text: String
}

/// A titled group of notes within a version (e.g. "Fork Changes").
struct ReleaseNoteSection: Decodable, Equatable {
    let title: String
    let items: [ReleaseNote]
}

/// The release notes for one app version, as bundled in
/// `Contents/Resources/ghostty/release-notes/<version>.json`.
struct VersionNotes: Decodable, Equatable {
    let version: String
    let sections: [ReleaseNoteSection]
}

/// Loads bundled per-version release notes and splits them, relative to the
/// version the user last ran, into "new since your last version" and
/// "already installed". Pure and offline — no network, no UserDefaults.
struct ReleaseNotesStore {
    let all: [VersionNotes]

    /// Test seam.
    init(all: [VersionNotes]) { self.all = all }

    /// Decode every `*.json` in `directory`, skipping unreadable/garbage files.
    init(directory: URL?) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { self.all = []; return }
        let decoder = JSONDecoder()
        self.all = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(VersionNotes.self, from: data)
            }
    }

    /// The bundled AGENT release-notes directory inside the app Resources, or
    /// nil if absent. These are scoped to session-persistence / background-agent
    /// changes — the reasons a user would restart the agent (and reset live
    /// sessions). Client/app-wide notes, if ever surfaced, live in a sibling
    /// `release-notes/client` directory.
    static var agentNotesDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("release-notes", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    /// The bundled CLIENT release-notes directory inside the app Resources, or
    /// nil if absent. Scoped to app/UI/viewer/banner changes (NOT the
    /// session-persistence/agent items under `agentNotesDirectory`).
    static var clientNotesDirectory: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("release-notes", isDirectory: true)
            .appendingPathComponent("client", isDirectory: true)
    }

    /// Decode a single version's notes from an appcast item's `<description>`
    /// (embedded JSON, delivered over the network). Returns nil for nil, empty,
    /// or non-JSON input (e.g. an HTML description) so callers degrade to
    /// showing no notes rather than failing.
    static func versionNotes(fromAppcastDescription description: String?) -> VersionNotes? {
        guard let description,
              let data = description.data(using: .utf8),
              let notes = try? JSONDecoder().decode(VersionNotes.self, from: data)
        else { return nil }
        return notes
    }

    /// True iff dotted-numeric version `a` is strictly newer than `b`
    /// (`.numeric` handles `1.10.0` > `1.9.0`).
    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Split notes relative to `previousSeen`, capping "new" at `current` so a
    /// bundle carrying notes newer than the running build never shows them.
    /// Both groups are newest-first.
    func partitioned(previousSeen: String?, current: String)
        -> (new: [VersionNotes], installed: [VersionNotes])
    {
        var newer: [VersionNotes] = []
        var installed: [VersionNotes] = []
        for n in all {
            let atOrBelowCurrent = !Self.isNewer(n.version, than: current)
            let aboveSeen = previousSeen.map { Self.isNewer(n.version, than: $0) } ?? true
            if aboveSeen {
                if atOrBelowCurrent { newer.append(n) }  // else: > current → drop
            } else {
                installed.append(n)
            }
        }
        let byVersionDesc: (VersionNotes, VersionNotes) -> Bool = {
            Self.isNewer($0.version, than: $1.version)
        }
        return (newer.sorted(by: byVersionDesc), installed.sorted(by: byVersionDesc))
    }
}
