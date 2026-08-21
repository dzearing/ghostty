import Testing
@testable import Ghostty

/// A `+split` (or `+rearrange`) that names no target used to resolve its
/// anchor from `TerminalController.preferredParent` — read on the main queue
/// at HANDLE time, so the answer was whatever window happened to be key by
/// then. An agent in pane A asking for a side pane, plus a user clicking
/// window B in the meantime, put the pane in B.
///
/// The CLI now forwards `$GHOZTTY_PANE_ID` as `--caller-pane=` (see
/// `apprt.ipc.seedCallerPane`) and this is the one place the app consumes it.
/// What these pin is that it stays a DEFAULT: everything the caller said
/// explicitly still wins, and every way the pane id can be useless — absent,
/// empty, or naming a pane that has since closed — falls back to the old
/// focused-window behavior rather than failing.
struct CallerAnchorTests {
    private func parsed(
        callerPane: String? = nil,
        target: String? = nil,
        pane: String? = nil,
        fromFocused: Bool = false
    ) -> IPCServer.ParsedArguments {
        var result = IPCServer.ParsedArguments(config: Ghostty.SurfaceConfiguration())
        result.callerPane = callerPane
        result.target = target
        result.pane = pane
        result.fromFocused = fromFocused
        return result
    }

    private let alive: (String) -> Bool = { _ in true }
    private let dead: (String) -> Bool = { _ in false }

    @Test func anchorsAtTheInvokingPaneWhenNoTargetWasNamed() {
        #expect(IPCServer.callerAnchorPane(
            parsed(callerPane: "PANE-1"), isAlive: alive) == "PANE-1")
    }

    @Test func anExplicitWindowTargetWins() {
        #expect(IPCServer.callerAnchorPane(
            parsed(callerPane: "PANE-1", target: "dev"), isAlive: alive) == nil)
    }

    @Test func anExplicitPaneWins() {
        #expect(IPCServer.callerAnchorPane(
            parsed(callerPane: "PANE-1", pane: "logs"), isAlive: alive) == nil)
    }

    /// `--from-focused` is the caller asking for the focused window BY NAME.
    @Test func fromFocusedStaysFocusBased() {
        #expect(IPCServer.callerAnchorPane(
            parsed(callerPane: "PANE-1", fromFocused: true), isAlive: alive) == nil)
    }

    /// A plain non-Ghoztty shell, or a pane baked by an app/agent that predates
    /// the flag, sends nothing — and gets today's behavior unchanged.
    @Test func noCallerPaneFallsBack() {
        #expect(IPCServer.callerAnchorPane(parsed(), isAlive: alive) == nil)
        #expect(IPCServer.callerAnchorPane(
            parsed(callerPane: ""), isAlive: alive) == nil)
    }

    /// A script outliving its own pane is ordinary, so a pane id that no longer
    /// resolves falls back instead of failing the command.
    @Test func aStaleCallerPaneFallsBack() {
        #expect(IPCServer.callerAnchorPane(
            parsed(callerPane: "PANE-GONE"), isAlive: dead) == nil)
    }
}
