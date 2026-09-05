import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The wiring between the hero window's event stream and the carousel's
/// thumbnail pacing, exercised through the real `HeroCarouselContainer`.
///
/// The bug: thumbnails were captured on a flat 0.15s timer whose only "user is
/// busy" guard was the carousel's own `scrollWheel(with:)`. Interaction with the
/// *hero pane* — scrolling the web page, typing in a terminal — went to that
/// pane's own view and never reached the carousel, so a full-resolution
/// `WKWebView.takeSnapshot` (~30ms of web-process paint, measured) kept firing
/// into the middle of the user's own scroll and dropped ~11% of the page's
/// frames to 36-51ms. Interaction is a property of the window, so the carousel
/// now reads it off the window's events.
///
/// What is asserted here is the wiring — that an event delivered to the window
/// reaches the carousel's scheduler, and that an event belonging to another
/// window does not. The schedule those states produce is covered exhaustively,
/// and deterministically, by `HeroSnapshotSchedulerTests`.
///
/// Interaction is delivered as a key event rather than a scroll: AppKit has no
/// public way to synthesize a window-addressed `.scrollWheel` (`NSEvent
/// .mouseEvent` rejects the type), and typing in a hero terminal pane travels
/// the identical path.
@MainActor
struct HeroCarouselCapturePacingTests {
    // MARK: - Harness

    /// A viewer pane is the cheapest real `PaneView`: no libghostty surface and
    /// no child process.
    private func makePanes(_ count: Int) throws -> [PaneView] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-capture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<count).map { i in
            let file = dir.appendingPathComponent("pane-\(i).md")
            try "# pane \(i)".write(to: file, atomically: true, encoding: .utf8)
            return PaneView(viewer: ViewerView(location: file.path))
        }
    }

    private func makeTree(_ panes: [PaneView]) throws -> SplitTree<PaneView> {
        var tree = SplitTree<PaneView>(view: panes[0])
        for (previous, pane) in zip(panes, panes.dropFirst()) {
            tree = try tree.inserting(view: pane, at: previous, direction: .down)
        }
        return tree
    }

    /// Pump the main runloop so SwiftUI updates and the carousel's snapshot
    /// heartbeat actually run.
    private func settle(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// `defer: false` so the window gets a real window number: the carousel only
    /// counts events addressed to its own window, and a synthesized event
    /// carries that window by number.
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

    /// Unmount so the carousel drops its event monitor; a leaked monitor would
    /// keep marking every later test's events as interaction.
    private func unmount(_ window: NSWindow, _ host: NSHostingView<HeroModeView>) {
        host.removeFromSuperview()
        window.contentView = nil
        settle()
    }

    private func findCarousel(_ view: NSView) -> HeroCarouselContainer? {
        if let carousel = view as? HeroCarouselContainer { return carousel }
        for subview in view.subviews {
            if let found = findCarousel(subview) { return found }
        }
        return nil
    }

    /// Deliver a keystroke the way AppKit does, so the carousel's local event
    /// monitor sees it.
    private func interact(inWindowNumber windowNumber: Int) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("could not synthesize a key event")
            return
        }
        NSApp.sendEvent(event)
    }

    // MARK: - Tests

    @Test func interactionInTheHeroWindowPausesCapturesAndThenReleasesThem() throws {
        let panes = try makePanes(3)
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: panes.count)

        let (window, host) = mount(try makeTree(panes), state)
        defer { unmount(window, host) }
        let carousel = try #require(findCarousel(host), "no carousel in the mounted hero mode")

        // Nothing has happened yet, so there is nothing to hold still for.
        #expect(carousel.scheduler.isQuiet)

        // An event the carousel itself never receives — it is addressed to the
        // window, and in a real hero window the hero pane's view consumes it —
        // still pauses capture. That is the whole fix.
        interact(inWindowNumber: window.windowNumber)
        #expect(carousel.scheduler.isQuiet == false)

        // Holding the interaction keeps it paused for as long as it lasts.
        for _ in 0..<8 {
            interact(inWindowNumber: window.windowNumber)
            settle(0.05)
        }
        #expect(carousel.scheduler.isQuiet == false)

        // ...and it is released once the gesture settles, which is what lets the
        // trailing refresh run.
        settle(HeroSnapshotScheduler.quietPeriod * 2)
        #expect(carousel.scheduler.isQuiet)
    }

    @Test func anotherWindowsEventsDoNotPauseThisCarousel() throws {
        let panes = try makePanes(2)
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: panes.count)

        let (window, host) = mount(try makeTree(panes), state)
        defer { unmount(window, host) }
        let carousel = try #require(findCarousel(host), "no carousel in the mounted hero mode")

        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        interact(inWindowNumber: other.windowNumber)
        #expect(carousel.scheduler.isQuiet, "another window's typing paused this carousel")
    }

    /// The initial-snapshot path is unconditional: a carousel that has never
    /// seen interaction must not sit blank waiting for one.
    @Test func freshCarouselCapturesWithoutAnyInteraction() throws {
        let panes = try makePanes(2)
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: panes.count)

        let (window, host) = mount(try makeTree(panes), state)
        defer { unmount(window, host) }
        let carousel = try #require(findCarousel(host), "no carousel in the mounted hero mode")

        settle(0.5)
        #expect(carousel.captureCount > 0)
    }
}
