import AppKit

/// Decides *when* a hero carousel thumbnail may be captured, and *at what
/// resolution*.
///
/// Thumbnails are a glance affordance, not a live mirror, and capturing one is
/// not free. Measured on a 1200×900 viewer pane being scrolled continuously
/// (`WKWebView`, 2× display, 6s runs):
///
/// | capture                    | cost per capture | page frames over 25ms |
/// |----------------------------|------------------|-----------------------|
/// | none                       | —                | 0 / 390               |
/// | full pane size, every 150ms| 29.7ms           | 39 / 360  (10.8%)     |
/// | tile width,     every 150ms|  3.2ms           | 1 / 330   (0.3%)      |
///
/// Two things were wrong, and this type fixes both:
///
/// 1. **The cost is in the web process, not on the main thread.** The
///    synchronous part of `takeSnapshot` is 0.03ms; the ~30ms is WebKit
///    painting the whole view out of band, competing with the very scroll the
///    user is performing. So the old `snapshotInFlight` guard could not help
///    (30ms < the 150ms period, so every tick fired), and neither could a
///    main-thread "is the carousel busy" flag. What helps is not capturing at
///    all while the user is interacting — see ``isQuiet``.
/// 2. **We captured at the hero pane's full resolution** and then squeezed the
///    result into a ~200pt-wide tile. Capturing at the size actually displayed
///    is both ~10× cheaper and no less sharp — see ``captureRatio``.
///
/// The schedule is pure and clock-injected so it is testable without timers.
final class HeroSnapshotScheduler {
    /// Panes differ in capture cost by more than an order of magnitude, so they
    /// get different idle cadences.
    enum PaneKind {
        /// The surface's layer is an `IOSurfaceLayer`; capturing it is a blit
        /// (~1.2ms at full pane resolution, ~0.05ms at thumbnail resolution).
        case terminal
        /// `WKWebView.takeSnapshot` forces an out-of-band paint in the web
        /// process (~3ms at thumbnail resolution).
        case viewer
    }

    /// How long the window must go without user input before captures resume.
    ///
    /// Momentum scrolling keeps delivering `.scrollWheel` events after the
    /// fingers lift, so this is measured from the true end of the gesture, not
    /// from the last touch.
    static let quietPeriod: TimeInterval = 0.3

    /// Timers fire with jitter in both directions. Without a little slack a
    /// tick that lands a hair early would push a capture out by a whole extra
    /// heartbeat, which for a terminal tile means a visibly stuttering
    /// thumbnail rather than a smooth one.
    static let jitterTolerance: TimeInterval = 0.01

    /// How long an async capture may stay outstanding before it is presumed
    /// lost and a fresh one is allowed.
    ///
    /// `WKWebView.takeSnapshot` normally calls back within milliseconds, but it
    /// calls back only when the web content paints — and a web view whose window
    /// is never composited (a hung web process, a page wedged mid-load) may
    /// never get there. Without a deadline that tile's in-flight guard latches
    /// and its thumbnail is frozen for the life of the pane. Long enough that a
    /// merely slow capture is never superseded.
    static let staleCaptureTimeout: TimeInterval = 5

    /// Minimum time between two captures of the same tile while idle.
    static func minimumInterval(for kind: PaneKind) -> TimeInterval {
        switch kind {
        case .terminal: return 0.15  // cheap: keep terminal thumbnails live
        case .viewer: return 1.0     // expensive: a page rarely changes on its own
        }
    }

    /// Injected so tests drive the schedule without waiting on wall time.
    var now: () -> TimeInterval

    private var lastInteraction: TimeInterval?

    init(now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }) {
        self.now = now
    }

    /// Record that the user just did something in the carousel's window.
    func noteInteraction() {
        lastInteraction = now()
    }

    /// True when the window has been free of user input for ``quietPeriod``.
    ///
    /// The first tick that finds this true is the trailing refresh: the
    /// heartbeat keeps running through the whole gesture and simply declines to
    /// capture, so no separate "settled" timer can be missed or cancelled.
    var isQuiet: Bool {
        guard let lastInteraction else { return true }
        return now() - lastInteraction >= Self.quietPeriod - Self.jitterTolerance
    }

    /// Whether a tile of `kind` should capture on this tick.
    ///
    /// - Parameters:
    ///   - lastCapture: when this tile last captured, or nil if never.
    ///   - inFlightSince: when this tile's outstanding async capture started,
    ///     or nil if none is outstanding.
    func shouldCapture(kind: PaneKind, lastCapture: TimeInterval?, inFlightSince: TimeInterval?) -> Bool {
        if let inFlightSince, now() - inFlightSince < Self.staleCaptureTimeout { return false }
        guard isQuiet else { return false }
        guard let lastCapture else { return true }
        return now() - lastCapture >= Self.minimumInterval(for: kind) - Self.jitterTolerance
    }

    // MARK: - Capture resolution

    /// The fraction of the pane's own resolution a thumbnail actually needs.
    ///
    /// Never above 1: a thumbnail larger than the pane would be upscaled noise.
    /// Falls back to 1 (full resolution, the old behavior) when either size is
    /// not known yet, so a tile that has not been laid out still gets a correct
    /// picture rather than a degenerate one.
    static func captureRatio(paneSize: CGSize, tileSize: CGSize) -> CGFloat {
        guard paneSize.width > 0, paneSize.height > 0,
              tileSize.width > 0, tileSize.height > 0 else { return 1 }
        let ratio = max(tileSize.width / paneSize.width, tileSize.height / paneSize.height)
        return min(1, ratio)
    }

    /// The width, in points, to ask `WKSnapshotConfiguration` for — or nil to
    /// capture at full size. WebKit returns that width at the display's backing
    /// scale, so a 240pt request on a 2× display yields a 480×360px bitmap:
    /// exactly Retina-sharp for a 240pt tile.
    static func snapshotWidth(paneSize: CGSize, tileSize: CGSize) -> CGFloat? {
        let ratio = captureRatio(paneSize: paneSize, tileSize: tileSize)
        guard ratio < 1 else { return nil }
        return max(1, (paneSize.width * ratio).rounded())
    }

    // MARK: - What counts as interaction

    /// Event types that mean the user is driving something and thumbnails
    /// should hold still.
    ///
    /// This is the crux of the original bug: interaction used to be detected
    /// only by the carousel's own `scrollWheel(with:)`, so scrolling the *web
    /// page in the hero pane* — the one interaction whose frames the snapshots
    /// were stealing — never registered at all. Interaction is a property of
    /// the window, not of the carousel view, so it is read off the event
    /// stream.
    ///
    /// Pointer movement is deliberately excluded: drifting the mouse across the
    /// carousel is not driving anything, and letting it suppress captures would
    /// stall thumbnails for as long as the pointer keeps twitching.
    private static let interactionEventTypes: Set<NSEvent.EventType> = [
        .scrollWheel, .magnify, .smartMagnify, .swipe, .rotate,
        .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        .keyDown,
    ]

    /// The mask to install a local event monitor with, derived from
    /// ``interactionEventTypes`` so the monitor and the predicate cannot drift
    /// apart. (`EventTypeMask` is by AppKit's definition the event type's bit
    /// position; `interactionEventMaskMatchesTheTypes` pins that against
    /// AppKit's own constants.)
    static var interactionEventMask: NSEvent.EventTypeMask {
        interactionEventTypes.reduce(into: NSEvent.EventTypeMask()) { mask, type in
            mask.insert(NSEvent.EventTypeMask(rawValue: 1 << UInt64(type.rawValue)))
        }
    }

    /// Whether `event` counts as interaction for a carousel living in `window`.
    ///
    /// Events belonging to some other window are ignored — another window's
    /// scrolling says nothing about this hero pane.
    static func isInteraction(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard isInteractionType(event.type) else { return false }
        guard let window else { return false }
        return event.window === window
    }

    /// Whether an event of this type means the user is driving something.
    static func isInteractionType(_ type: NSEvent.EventType) -> Bool {
        interactionEventTypes.contains(type)
    }
}
