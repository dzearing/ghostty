// macos/Sources/Features/Setup/BannerScriptInstaller.swift
import Foundation

/// Copies the bundled banner script to a STABLE owned path so generated hooks
/// never reference a volatile `Ghoztty.app` bundle path.
struct BannerScriptInstaller {
    static let marker = "# ghoztty-managed"

    let homeDirectoryURL: URL
    let fileManager: FileManager

    static func scriptURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh")
    }

    private var url: URL { Self.scriptURL(homeDirectoryURL: homeDirectoryURL) }
    private func expected() throws -> String { try GhosttyAssets.bannerScript() }

    func state() -> ComponentInstallState {
        guard let want = try? expected() else { return .outdated }
        return ManagedFile.state(at: url, expected: want, marker: Self.marker)
    }

    func install() throws {
        try ManagedFile.write(try expected(), to: url, marker: Self.marker, mode: 0o700, fileManager: fileManager)
    }

    func uninstall() throws {
        try ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
    }
}
