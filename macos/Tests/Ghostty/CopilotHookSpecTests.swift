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

    // I2: the per-runtime awk normalizer must map Copilot's (unverified,
    // likely camelCase) payload keys AND Claude-shaped snake_case keys to the
    // canonical {prompt, session_id} the shared script consumes. Runs the real
    // normalizer segment of the composed hook command through a shell.
    @Test func copilotNormalizerYieldsCanonicalForBothShapes() throws {
        let cmd = HookCommand.perEvent(
            purpose: .promptSubmit,
            bannerScriptPath: "/Users/x/.config/ghoztty/hooks/ghoztty-banner.sh",
            runtime: .copilot)
        // The command is "<awk normalizer> | bash SCRIPT prompt-hook"; run just
        // the normalizer segment so the test doesn't depend on the banner script.
        let normalizer = try #require(cmd.components(separatedBy: " | bash").first)
        #expect(normalizer.contains("awk"))

        for payload in [#"{"prompt":"hi","sessionId":"abc"}"#,   // Copilot-shaped
                        #"{"prompt":"hi","session_id":"abc"}"#] { // Claude-shaped
            let out = try runShell(normalizer, stdin: payload)
            let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8))
            let json = try #require(parsed as? [String: Any])
            #expect(json["prompt"] as? String == "hi")
            #expect(json["session_id"] as? String == "abc")
        }
    }

    private func runShell(_ command: String, stdin: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
