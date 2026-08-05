// macos/Tests/Ghostty/BannerScriptInstallerTests.swift
import Foundation
import Testing
@testable import Ghostty

struct BannerScriptInstallerTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installsToStablePathWithNeutralStateDir() throws {
        let home = try tempHome()
        let i = BannerScriptInstaller(homeDirectoryURL: home, fileManager: .default)
        #expect(i.state() == .notInstalled)
        try i.install()
        #expect(i.state() == .installed)
        let url = home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh")
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains(".config/ghoztty/banner-state"))
        #expect(!body.contains(".claude/ghoztty-banner"))
        // executable bit
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(mode == 0o700)
    }

    @Test func bundledScriptHasNoClaudeStateDir() throws {
        #expect(try GhosttyAssets.bannerScript().contains(".config/ghoztty/banner-state"))
        #expect(try !GhosttyAssets.bannerScript().contains(".claude/ghoztty-banner"))
    }
}
