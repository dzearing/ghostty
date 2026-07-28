import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Hero-mode navigation (Cmd+Shift+Up/Down) must always span the *current*
/// split tree.
///
/// The hero key monitor is installed once, when hero mode appears, but SwiftUI
/// hands `HeroModeView` a brand-new `tree` value on every split change. A
/// monitor that resolved keys against the tree captured at install time
/// navigated the pane list as it was when hero mode was entered: a pane added
/// afterwards was unreachable (Cmd+Shift+Down stopped one short) and a pane
/// closed afterwards left the selection pointing past the end.
@MainActor
struct HeroModeKeyNavigationTests {
    // MARK: - Harness

    /// A viewer pane is the cheapest real `PaneView`: no libghostty surface and
    /// no child process, and hero mode lays it out like any other pane.
    private func makePanes(_ count: Int) throws -> [PaneView] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-nav-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<count).map { i in
            let file = dir.appendingPathComponent("pane-\(i).md")
            try "# pane \(i)".write(to: file, atomically: true, encoding: .utf8)
            return PaneView(viewer: ViewerView(location: file.path))
        }
    }

    /// A vertical stack of panes, so `leaves()` is `panes` in order.
    private func makeTree(_ panes: [PaneView]) throws -> SplitTree<PaneView> {
        var tree = SplitTree<PaneView>(view: panes[0])
        for (previous, pane) in zip(panes, panes.dropFirst()) {
            tree = try tree.inserting(view: pane, at: previous, direction: .down)
        }
        return tree
    }

    /// Give SwiftUI a chance to run its update pass (onAppear, body, onChange).
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// Mount hero mode in an offscreen window, the way a terminal window does.
    ///
    /// `defer: false` so the window gets a real window number: hero navigation
    /// only claims keystrokes addressed to its own window, and a synthesized
    /// event carries that window by number.
    private func mount(
        _ tree: SplitTree<PaneView>,
        _ state: HeroModeState
    ) -> (NSWindow, NSHostingView<HeroModeView>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let host = NSHostingView(rootView: HeroModeView(tree: tree, state: state))
        host.frame = window.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(host)
        host.layoutSubtreeIfNeeded()
        settle()
        return (window, host)
    }

    /// Unmount so `onDisappear` removes the key monitor; a leaked monitor would
    /// keep answering keystrokes for every later test.
    private func unmount(_ window: NSWindow, _ host: NSHostingView<HeroModeView>) {
        host.removeFromSuperview()
        window.contentView = nil
        settle()
    }

    /// Push a Cmd+Shift+arrow through the app the way AppKit does, so the
    /// local key monitor hero mode installs actually sees it.
    private func press(_ key: NSEvent.SpecialKey, in window: NSWindow) {
        guard window.windowNumber > 0 else {
            Issue.record("test window has no window number; events cannot address it")
            return
        }
        let characters = String(key.unicodeScalar)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift, .function, .numericPad],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: key == .upArrow ? 126 : 125
        ) else {
            Issue.record("could not synthesize a \(key) key event")
            return
        }
        NSApp.sendEvent(event)
    }

    // MARK: - Tests

    /// Adding a pane while hero mode is up extends the cycle: every pane,
    /// including the new one, is reachable with Cmd+Shift+Down, and
    /// Cmd+Shift+Up walks all the way back to the first.
    @Test func navigationSpansPanesAddedWhileHeroModeIsUp() throws {
        let panes = try makePanes(3)
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2)

        let (window, host) = mount(try makeTree(Array(panes.prefix(2))), state)
        defer { unmount(window, host) }

        // Sanity check on the harness itself: the monitor is installed and
        // sees synthesized events.
        press(.downArrow, in: window)
        #expect(state.selectedIndex == 1, "hero key monitor did not handle Cmd+Shift+Down")

        // A third pane appears (a `+split`, say). SwiftUI re-renders hero mode
        // with the new tree.
        host.rootView = HeroModeView(tree: try makeTree(panes), state: state)
        settle()

        press(.downArrow, in: window)
        #expect(state.selectedIndex == 2, "the pane added after hero mode started is unreachable")

        press(.upArrow, in: window)
        press(.upArrow, in: window)
        #expect(state.selectedIndex == 0)
    }

    /// Closing a pane while hero mode is up shrinks the cycle: the selection
    /// can never point past the last remaining pane.
    @Test func navigationClampsToPanesClosedWhileHeroModeIsUp() throws {
        let panes = try makePanes(3)
        let state = HeroModeState()
        state.activate(focusedIndex: 2, leafCount: 3)

        let (window, host) = mount(try makeTree(panes), state)
        defer { unmount(window, host) }

        // The last pane closes while its slot is selected.
        host.rootView = HeroModeView(tree: try makeTree(Array(panes.prefix(2))), state: state)
        settle()

        press(.downArrow, in: window)
        #expect(state.selectedIndex == 1, "selection points past the end of the split tree")
    }

    /// The key monitor is app-wide, so it sees keystrokes aimed at every
    /// window. With two windows in hero mode at once, one Cmd+Shift+Down must
    /// step only the window the keystroke was addressed to — otherwise both
    /// advance and each pulls focus to its own newly selected pane.
    @Test func navigationOnlyStepsTheWindowTheKeyWasAimedAt() throws {
        let panesA = try makePanes(3)
        let panesB = try makePanes(3)
        let stateA = HeroModeState()
        let stateB = HeroModeState()
        stateA.activate(focusedIndex: 0, leafCount: 3)
        stateB.activate(focusedIndex: 0, leafCount: 3)

        let (windowA, hostA) = mount(try makeTree(panesA), stateA)
        let (windowB, hostB) = mount(try makeTree(panesB), stateB)
        defer {
            unmount(windowA, hostA)
            unmount(windowB, hostB)
        }

        press(.downArrow, in: windowA)
        #expect(stateA.selectedIndex == 1)
        #expect(stateB.selectedIndex == 0, "a keystroke aimed at one hero window also stepped another")

        press(.downArrow, in: windowB)
        #expect(stateB.selectedIndex == 1)
        #expect(stateA.selectedIndex == 1, "a keystroke aimed at one hero window also stepped another")
    }
}
