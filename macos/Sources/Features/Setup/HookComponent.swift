// macos/Sources/Features/Setup/HookComponent.swift
import Foundation

struct HookComponent {
    let spec: HookSpec
    let homeDirectoryURL: URL
    let fileManager: FileManager

    private var bannerScriptPath: String {
        BannerScriptInstaller.scriptURL(homeDirectoryURL: homeDirectoryURL).path
    }

    private var fileURL: URL { spec.hookFileURL(homeDirectoryURL: homeDirectoryURL) }

    func state() -> ComponentInstallState {
        switch spec.ownership {
        case .dedicatedFile:
            return ManagedFile.state(
                at: fileURL,
                expected: spec.renderedFile(bannerScriptPath: bannerScriptPath),
                marker: spec.marker)
        case .mergedFragment:
            return ClaudeHookSpec.fragmentState(in: readJSON(), bannerScriptPath: bannerScriptPath)
        }
    }

    func install() throws {
        switch spec.ownership {
        case .dedicatedFile:
            try ManagedFile.write(
                spec.renderedFile(bannerScriptPath: bannerScriptPath),
                to: fileURL, marker: spec.marker, mode: 0o600, fileManager: fileManager)
        case .mergedFragment:
            let merged = ClaudeHookSpec.merge(into: readJSON(), bannerScriptPath: bannerScriptPath)
            try writeJSON(merged)
        }
    }

    func uninstall() throws {
        switch spec.ownership {
        case .dedicatedFile:
            try ManagedFile.removeIfManaged(at: fileURL, marker: spec.marker, fileManager: fileManager)
        case .mergedFragment:
            let json = readJSON()
            guard ClaudeHookSpec.fragmentState(in: json, bannerScriptPath: bannerScriptPath) != .notInstalled else { return }
            try writeJSON(ClaudeHookSpec.removeFragment(from: json))
        }
    }

    private func readJSON() -> [String: Any] {
        guard let data = fileManager.contents(atPath: fileURL.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeJSON(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
