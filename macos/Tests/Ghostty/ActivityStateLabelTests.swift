import Testing
@testable import Ghostty

/// An activity state has two names, and they are deliberately not the same
/// string.
///
/// `rawValue` is the MACHINE token: it is what `+set-state --state=` accepts,
/// what an OSC 7777 payload carries, and what the `AXWindowActivityState`
/// accessibility attribute publishes. Those three are a public API — hooks in
/// user config call the CLI and external tools (ztabby) read the AX attribute —
/// so renaming a token silently breaks live configuration.
///
/// `displayLabel` is the HUMAN name, and the only thing that reaches the window
/// title. `needs_input` reads as `question` there because a snake_case
/// identifier in a titlebar is an implementation detail leaking into UI.
@Suite struct ActivityStateLabelTests {
    @Test func machineTokensAreStable() {
        #expect(Ghostty.ActivityState.idle.rawValue == "idle")
        #expect(Ghostty.ActivityState.busy.rawValue == "busy")
        #expect(Ghostty.ActivityState.needsInput.rawValue == "needs_input")
    }

    @Test func needsInputDisplaysAsQuestion() {
        #expect(Ghostty.ActivityState.needsInput.displayLabel == "question")
    }

    @Test func idleAndBusyDisplayAsTheirToken() {
        #expect(Ghostty.ActivityState.idle.displayLabel == "idle")
        #expect(Ghostty.ActivityState.busy.displayLabel == "busy")
    }
}
