import AppKit
import Testing
@testable import Ghostty

/// Hero carousel thumbnails used to be captured on a flat 0.15s timer, at the
/// hero pane's full resolution, with the only "user is busy" guard driven by
/// the carousel's own `scrollWheel(with:)`.
///
/// Measured on a 1200×900 viewer pane scrolled continuously for 6s: each
/// full-size `WKWebView.takeSnapshot` cost ~30ms of web-process render time
/// (the synchronous part was 0.03ms — the cost is not on the main thread), and
/// at one per 150ms that pushed 10.8% of the page's frames from 17ms to
/// 36–51ms. Scrolling the page never touched the carousel's `isScrolling` flag,
/// so nothing suppressed it.
///
/// These tests pin the three properties that fix it: captures coalesce to a
/// cadence matched to their cost, they stop entirely while the user is
/// interacting *anywhere in the window*, and a trailing capture always follows
/// once things go quiet.
@MainActor
struct HeroSnapshotSchedulerTests {
    /// A scheduler whose clock the test drives by hand.
    private final class Clock {
        var t: TimeInterval = 1_000
        func advance(_ dt: TimeInterval) { t += dt }
    }

    private func makeScheduler() -> (HeroSnapshotScheduler, Clock) {
        let clock = Clock()
        return (HeroSnapshotScheduler(now: { clock.t }), clock)
    }

    /// Replays the container's 0.15s heartbeat and counts how many captures a
    /// single tile of `kind` actually performs.
    private func captures(
        kind: HeroSnapshotScheduler.PaneKind,
        ticks: Int,
        scheduler: HeroSnapshotScheduler,
        clock: Clock,
        interact: (Int) -> Bool = { _ in false }
    ) -> Int {
        var lastCapture: TimeInterval?
        var count = 0
        for tick in 0..<ticks {
            if interact(tick) { scheduler.noteInteraction() }
            if scheduler.shouldCapture(kind: kind, lastCapture: lastCapture, inFlightSince: nil) {
                lastCapture = clock.t
                count += 1
            }
            clock.advance(0.15)
        }
        return count
    }

    // MARK: - Coalescing

    @Test("Viewer captures coalesce to the idle cadence, not the heartbeat")
    func viewerCapturesCoalesce() {
        let (scheduler, clock) = makeScheduler()
        // 40 heartbeats = 6s. The old code captured on every one of them.
        let n = captures(kind: .viewer, ticks: 40, scheduler: scheduler, clock: clock)
        #expect(n == 6)
    }

    @Test("Terminal captures stay live: they are cheap enough for every tick")
    func terminalCapturesStayLive() {
        let (scheduler, clock) = makeScheduler()
        let n = captures(kind: .terminal, ticks: 40, scheduler: scheduler, clock: clock)
        #expect(n == 40)
    }

    // MARK: - Interaction suppression + trailing refresh

    @Test("No captures at all while the user is interacting")
    func interactionSuppressesCaptures() {
        let (scheduler, clock) = makeScheduler()
        // Interaction on every tick for the first 3s, exactly as a continuous
        // scroll (including its momentum tail) delivers events.
        let n = captures(kind: .terminal, ticks: 20, scheduler: scheduler, clock: clock) { $0 < 20 }
        #expect(n == 0)
    }

    @Test("A trailing capture fires once the interaction settles")
    func trailingCaptureFires() {
        let (scheduler, clock) = makeScheduler()
        scheduler.noteInteraction()

        // Still inside the quiet period: nothing may capture.
        #expect(scheduler.isQuiet == false)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: nil) == false)
        clock.advance(HeroSnapshotScheduler.quietPeriod / 2)
        #expect(scheduler.isQuiet == false)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: nil) == false)

        // The first tick past the quiet period is the trailing refresh, and it
        // fires even for a viewer that captured only a moment before the
        // gesture — a thumbnail left showing the pre-scroll page is a stale
        // thumbnail.
        clock.advance(HeroSnapshotScheduler.quietPeriod)
        #expect(scheduler.isQuiet == true)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: nil) == true)
    }

    @Test("A long gesture ends in exactly one trailing capture, not a burst")
    func settlingCapturesOnce() {
        let (scheduler, clock) = makeScheduler()
        // 3s of scrolling, then 1.5s of quiet, all at the 0.15s heartbeat.
        let n = captures(kind: .viewer, ticks: 30, scheduler: scheduler, clock: clock) { $0 < 20 }
        #expect(n == 2)  // one when it settles, one an idle interval later
    }

    @Test("An in-flight capture is never stacked on")
    func inFlightBlocksCapture() {
        let (scheduler, clock) = makeScheduler()
        clock.advance(10)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: clock.t) == false)
        #expect(scheduler.shouldCapture(kind: .terminal, lastCapture: nil, inFlightSince: clock.t) == false)
    }

    /// `WKWebView.takeSnapshot` calls back only when the web content paints, so
    /// a wedged page or a hung web process can leave a capture outstanding
    /// forever. Latching on that would freeze the thumbnail for the life of the
    /// pane, so an outstanding capture expires.
    @Test("A capture that never calls back stops blocking eventually")
    func staleCaptureIsSuperseded() {
        let (scheduler, clock) = makeScheduler()
        let started = clock.t

        clock.advance(HeroSnapshotScheduler.staleCaptureTimeout - 1)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: started) == false)

        clock.advance(2)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: started))
    }

    @Test("A fresh scheduler captures immediately — nothing to wait for yet")
    func freshSchedulerCaptures() {
        let (scheduler, _) = makeScheduler()
        #expect(scheduler.isQuiet == true)
        #expect(scheduler.shouldCapture(kind: .viewer, lastCapture: nil, inFlightSince: nil) == true)
    }

    // MARK: - What counts as interaction

    @Test("Scrolling counts as interaction; pointer drift does not")
    func interactionEventTypes() {
        // The regression: a scroll event is delivered to the hero pane's
        // WKWebView, never to the carousel, so the carousel's own
        // scrollWheel(with:) could not see the one gesture whose frames the
        // snapshots were stealing.
        #expect(HeroSnapshotScheduler.isInteractionType(.scrollWheel))
        #expect(HeroSnapshotScheduler.isInteractionType(.magnify))
        #expect(HeroSnapshotScheduler.isInteractionType(.leftMouseDragged))
        // Typing in a terminal pane is interaction too.
        #expect(HeroSnapshotScheduler.isInteractionType(.keyDown))

        // Moving the pointer over the carousel is not driving anything, and
        // letting it suppress captures would stall thumbnails for as long as
        // the pointer keeps twitching.
        #expect(HeroSnapshotScheduler.isInteractionType(.mouseMoved) == false)
        #expect(HeroSnapshotScheduler.isInteractionType(.mouseEntered) == false)
        #expect(HeroSnapshotScheduler.isInteractionType(.flagsChanged) == false)
    }

    @Test("Only this window's events count")
    func interactionIsScopedToTheWindow() throws {
        let mine = makeWindow()
        let theirs = makeWindow()

        let inMine = try #require(mouseDown(in: mine))
        try #require(inMine.window === mine)
        #expect(HeroSnapshotScheduler.isInteraction(inMine, in: mine))

        // Another window's scrolling says nothing about this hero pane.
        #expect(HeroSnapshotScheduler.isInteraction(inMine, in: theirs) == false)

        // And with no window at all there is no carousel to hold still for.
        #expect(HeroSnapshotScheduler.isInteraction(inMine, in: nil) == false)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func mouseDown(in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)
    }

    @Test("The monitor's mask and the predicate cannot drift apart")
    func interactionEventMaskMatchesTheTypes() {
        // Checked against AppKit's own mask constants, since the mask is derived
        // from the event types by bit position.
        let mask = HeroSnapshotScheduler.interactionEventMask
        #expect(mask.contains(.scrollWheel))
        #expect(mask.contains(.keyDown))
        #expect(mask.contains(.leftMouseDragged))
        #expect(mask.contains(.magnify))
        #expect(mask.contains(.mouseMoved) == false)
        #expect(mask.contains(.flagsChanged) == false)
    }

    // MARK: - Capture resolution

    @Test("A thumbnail is captured at the size it is displayed, not the pane's")
    func captureRatioMatchesTile() {
        let pane = CGSize(width: 1200, height: 900)
        let tile = CGSize(width: 240, height: 180)
        #expect(HeroSnapshotScheduler.captureRatio(paneSize: pane, tileSize: tile) == 0.2)

        // WebKit returns snapshotWidth points at the backing scale, so 240pt is
        // a 480×360px bitmap on a 2× display: exact for a 240pt tile.
        #expect(HeroSnapshotScheduler.snapshotWidth(paneSize: pane, tileSize: tile) == 240)
    }

    @Test("Never captures above the pane's own resolution")
    func captureRatioNeverUpscales() {
        let pane = CGSize(width: 300, height: 200)
        let tile = CGSize(width: 600, height: 400)
        #expect(HeroSnapshotScheduler.captureRatio(paneSize: pane, tileSize: tile) == 1)
        // nil == "capture at full size", which is what a full-size request means.
        #expect(HeroSnapshotScheduler.snapshotWidth(paneSize: pane, tileSize: tile) == nil)
    }

    @Test("An unlaid-out tile falls back to a full-resolution capture")
    func captureRatioFallsBackWhenSizeUnknown() {
        let pane = CGSize(width: 1200, height: 900)
        #expect(HeroSnapshotScheduler.captureRatio(paneSize: pane, tileSize: .zero) == 1)
        #expect(HeroSnapshotScheduler.captureRatio(paneSize: .zero, tileSize: pane) == 1)
    }

    @Test("A tile with a taller aspect than the pane still captures enough pixels")
    func captureRatioUsesTheLimitingDimension() {
        let pane = CGSize(width: 1200, height: 900)
        let tile = CGSize(width: 240, height: 450)  // half the pane's height
        #expect(HeroSnapshotScheduler.captureRatio(paneSize: pane, tileSize: tile) == 0.5)
    }
}
