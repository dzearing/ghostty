// macos/Tests/Ghostty/CopilotHookSpecTests.swift
import Foundation
import Testing
@testable import Ghostty

struct CopilotHookSpecTests {
    @Test func rendersCamelCaseEventsAndStablePathNoBundle() {
        let spec = CopilotHookSpec()
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(spec.hookFileURL(homeDirectoryURL: home).path == "/tmp/home/.copilot/hooks/ghoztty.json")
        let file = spec.renderedFile(bannerScriptPath: "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh")
        #expect(file.contains("\"sessionStart\""))
        #expect(file.contains("\"userPromptSubmitted\""))
        #expect(file.contains("\"agentStop\""))
        #expect(file.contains("\"version\""))
        #expect(file.contains(spec.marker))
        #expect(!file.contains(".app/Contents"))
        // No jq in the hook command; prompt passed via stdin, control bytes stripped.
        #expect(!file.contains("jq "))
    }
}
