// macos/Tests/Ghostty/RuntimeAgentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct RuntimeAgentTests {
    @Test func configDirsAndNames() {
        #expect(RuntimeAgent.claude.configDirectoryName == ".claude")
        #expect(RuntimeAgent.copilot.configDirectoryName == ".copilot")
        #expect(RuntimeAgent.copilot.displayName == "Copilot CLI")
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(RuntimeAgent.claude.configDirectoryURL(homeDirectoryURL: home).path == "/tmp/home/.claude")
    }
}
