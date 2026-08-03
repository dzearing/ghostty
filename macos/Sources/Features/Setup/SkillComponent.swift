// macos/Sources/Features/Setup/SkillComponent.swift
import Foundation

/// Installs the bundled `ghoztty` and `process-feedback` skills into a runtime's
/// `skills/` directory. Portable: only the config dir differs per runtime.
struct SkillComponent {
    static let marker = GhosttyManagedMarker.htmlComment
    static let skillNames = ["ghoztty", "process-feedback"]

    let agent: RuntimeAgent
    let homeDirectoryURL: URL
    let fileManager: FileManager

    private func skillURL(_ name: String) -> URL {
        agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("skills/\(name)/SKILL.md")
    }

    private func expected(_ name: String) throws -> String {
        try GhosttyAssets.skillMarkdown(name) + "\n\(Self.marker)\n"
    }

    func state() -> ComponentInstallState {
        let states = Self.skillNames.map { name -> ComponentInstallState in
            guard let want = try? expected(name) else { return .outdated }
            return ManagedFile.state(at: skillURL(name), expected: want, marker: Self.marker)
        }
        if states.allSatisfy({ $0 == .installed }) { return .installed }
        if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
        return .outdated
    }

    func install() throws {
        // Render all up front so a missing bundled asset fails before any write.
        let rendered = try Self.skillNames.map { (url: skillURL($0), body: try expected($0)) }
        var written: [URL] = []
        do {
            for file in rendered {
                try ManagedFile.write(file.body, to: file.url, marker: Self.marker, mode: 0o600, fileManager: fileManager)
                written.append(file.url)
            }
        } catch {
            for url in written.reversed() {
                try? ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
            }
            throw error
        }
    }

    func uninstall() throws {
        for name in Self.skillNames {
            try ManagedFile.removeIfManaged(at: skillURL(name), marker: Self.marker, fileManager: fileManager)
        }
    }
}
