// macos/Tests/Ghostty/GhosttyAssetsTests.swift
import Foundation
import Testing
@testable import Ghostty

struct GhosttyAssetsTests {
    @Test func bundlesSkillsAndBannerScript() throws {
        #expect(try GhosttyAssets.skillMarkdown("ghoztty").contains("Ghoztty"))
        #expect(try GhosttyAssets.skillMarkdown("process-feedback").contains("feedback"))
        let script = try GhosttyAssets.bannerScript()
        #expect(script.hasPrefix("#!/bin/bash"))
    }
}
