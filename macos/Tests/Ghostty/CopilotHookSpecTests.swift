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

    // H3/H8: the generated hook command is just the shared script with the
    // event mode and the invoking runtime — no embedded awk/jq normalizer (the
    // script parses the payload itself), and no pipe.
    @Test func perEventIsScriptInvocationWithRuntimeFlag() {
        let copilot = HookCommand.perEvent(purpose: .promptSubmit,
                                           bannerScriptPath: "/x/banner.sh", runtime: .copilot)
        #expect(copilot == "bash '/x/banner.sh' prompt-hook --runtime=copilot")
        let claude = HookCommand.perEvent(purpose: .sessionStart,
                                          bannerScriptPath: "/x/banner.sh", runtime: .claude)
        #expect(claude == "bash '/x/banner.sh' session-start-hook --runtime=claude")
        // No hand-rolled parser embedded in the hook command anymore.
        #expect(!copilot.contains("awk"))
        #expect(!copilot.contains(" | "))
    }
}
