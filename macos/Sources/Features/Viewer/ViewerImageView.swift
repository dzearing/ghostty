import AppKit
import OSLog

/// The zoom rules for an image pane, with no view state in them.
///
/// Everything a person can argue about — what "100%" means, whether best-fit
/// may enlarge a small image, where a double-click lands — lives here as
/// arithmetic so it can be tested without a window, a screen, or a real
/// image. `ViewerImageSurface` is then only plumbing.
struct ViewerImageGeometry: Equatable {
    /// The image's own size in its own units: PIXELS for a raster image,
    /// points for a vector one (an SVG has no pixel grid to be measured in).
    /// This is also the document view's coordinate space, so the document is
    /// literally the image's own grid and never has to be resized.
    let naturalSize: CGSize

    /// Points per natural unit at 100% zoom — the whole of the "what does
    /// 100% mean" decision, in one number.
    ///
    /// **For a raster image, 100% is one image pixel per DEVICE pixel**, so
    /// this is `1 / backingScaleFactor`. Two reasons, in order:
    ///
    /// 1. It is the only definition under which 100% is actually pixel-exact.
    ///    Every image pixel lands on exactly one screen pixel, nothing is
    ///    resampled, and a 1px hairline is a 1px hairline — which is the
    ///    entire reason anyone asks for 100% rather than "big enough to read".
    /// 2. Most of what gets opened in these panes is screen capture — the
    ///    feedback composer's own screenshots, an agent's render of a UI. Those
    ///    are captured at device resolution, so 100% shows them at exactly the
    ///    size they were on screen. One image pixel per *point* would show a 2x
    ///    screenshot at twice the size of the screen it came from.
    ///
    /// **For a vector image it is 1.0**: there are no pixels to be 1:1 with, so
    /// 100% is the drawing's intrinsic size in points, as in every other vector
    /// viewer.
    let unitScale: CGFloat

    /// The viewport (the scroll view's clip area) in points.
    let viewportSize: CGSize

    /// Hard zoom limits. Deliberately wide at the top — an image pane is where
    /// you go to count pixels — and loose at the bottom, since `minZoom` also
    /// has to admit whatever best-fit needs for a very large image.
    static let zoomFloor: CGFloat = 0.05
    static let zoomCeiling: CGFloat = 32

    /// Per-press step for Cmd+/Cmd−. Coarser than the web viewer's 1.1,
    /// because an image's useful zoom range spans two orders of magnitude
    /// where a page's spans one.
    static let zoomStep: CGFloat = 1.25

    /// Zoom that fits the whole image in the viewport, **never above 100%**.
    ///
    /// Refusing to upscale is the deliberate half: blowing a 16pt icon up to
    /// fill a 900pt pane makes a blurry lie out of the asset, and "fit" on an
    /// image that already fits is a no-op everywhere else on the platform. So a
    /// small image opens crisp, centered, at its real size.
    var fitZoom: CGFloat {
        guard naturalSize.width > 0, naturalSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0,
              unitScale > 0
        else { return 1 }
        let raw = min(
            viewportSize.width / (naturalSize.width * unitScale),
            viewportSize.height / (naturalSize.height * unitScale))
        return min(1, raw)
    }

    /// The lowest zoom the pane allows. Never above `fitZoom`, or a very large
    /// image could not be fit into a small pane at all.
    var minZoom: CGFloat { min(Self.zoomFloor, fitZoom) }
    var maxZoom: CGFloat { max(Self.zoomCeiling, fitZoom) }

    func clamped(_ zoom: CGFloat) -> CGFloat {
        min(maxZoom, max(minZoom, zoom))
    }

    /// `NSScrollView.magnification` for a user-facing zoom, given a document
    /// view whose frame is `naturalSize`.
    func magnification(forZoom zoom: CGFloat) -> CGFloat { zoom * unitScale }

    /// The inverse, for reading a pinch back out of the scroll view.
    func zoom(forMagnification magnification: CGFloat) -> CGFloat {
        unitScale > 0 ? magnification / unitScale : 1
    }

    /// Where a double-click / double-tap goes from `current`.
    ///
    /// The contract is "toggle between best-fit and 100%", with one honest
    /// exception: when the image is smaller than the pane those two are the
    /// SAME zoom, and a gesture that visibly does nothing reads as a broken
    /// gesture. In that case the first double-click goes to 200% instead, and
    /// the next one comes back to fit — so the toggle always toggles.
    func doubleClickZoom(from current: CGFloat) -> CGFloat {
        guard abs(current - fitZoom) < 0.0001 else { return fitZoom }
        return clamped(fitZoom >= 1 ? 2 : 1)
    }

    /// Cmd+/Cmd−/Cmd-0. Reset is 100% (Preview's "Actual Size"), not fit:
    /// it means the same thing here as it does in the other viewer modes, and
    /// fit is one double-click away.
    func stepped(from current: CGFloat, action: ViewerView.ZoomAction) -> CGFloat {
        switch action {
        case .zoomIn: return clamped(current * Self.zoomStep)
        case .zoomOut: return clamped(current / Self.zoomStep)
        case .reset: return clamped(1)
        }
    }

    /// The image's natural size, and whether it is vector art.
    ///
    /// `NSImage.size` is in POINTS and is derived from the file's DPI tag, so a
    /// 144-dpi PNG reports half its pixel count — useless for a viewer whose
    /// 100% is defined in pixels. The representations know the truth, so ask
    /// them; a rep with no pixel grid at all (`_NSSVGImageRep`) is the vector
    /// case, where `NSImage.size` IS the answer.
    static func naturalSize(of image: NSImage) -> (size: CGSize, isVector: Bool)? {
        var pixels = CGSize.zero
        for rep in image.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            pixels.width = max(pixels.width, CGFloat(rep.pixelsWide))
            pixels.height = max(pixels.height, CGFloat(rep.pixelsHigh))
        }
        if pixels.width > 0, pixels.height > 0 { return (pixels, false) }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        return (size, true)
    }
}

/// A viewer pane rendering an image: a native `NSScrollView` over the image's
/// own pixel grid.
///
/// **Why this is not in the web view.** Every other viewer mode is a page, and
/// the whole stack (find, quoting, the link menu, history) is web-side — so
/// rendering an `<img>` would have been the tidier choice architecturally. It
/// loses the actual requirement. `WKWebView`'s pinch is WebKit's page
/// magnification: it zooms the whole viewport, has no notion of the image's
/// natural size (so no "fit" and no pixel-exact "100%"), and its double-tap
/// smart-zoom targets DOM elements. `NSScrollView` is what Preview and Xcode's
/// canvas use, and it is where macOS's own gesture handling lives — pinch
/// anchored at the gesture centroid, rubber-banding past the zoom limits,
/// elastic edges and momentum on a two-finger pan, `smartMagnify` for a
/// two-finger double-tap. All of that is free and none of it is reproducible in
/// a page.
///
/// **What the pane gives up, and what it keeps.** Find-in-page, text selection,
/// and quoting are meaningless in an image and are declined rather than shown
/// broken (see `ViewerView.openFind`). Everything structural is kept, because
/// an image pane still navigates to the render template behind this surface:
/// the web view holds a real history entry, so Back out of a website lands on
/// the image, Home returns to it, the address bar shows and accepts its path,
/// and a failed load falls through to the template's own error card rather than
/// needing a second one.
final class ViewerImageSurface: NSView {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty",
        category: "ViewerImage")

    private let scrollView = ViewerImageScrollView()
    private let imageView = ViewerImageDocumentView()

    /// The file currently displayed, so a live-reload can tell a genuine
    /// re-render from a navigation to a different image.
    private(set) var url: URL?

    /// True while the pane is showing the image at best-fit, which is what
    /// makes a pane resize re-fit. Cleared by any deliberate zoom: once the
    /// user has chosen a magnification, dragging a split divider must not
    /// throw it away.
    private var isFitting = true

    /// Set while we are driving `magnification` ourselves, so the observer
    /// that watches for the USER zooming does not read our own writes as a
    /// manual zoom and clear `isFitting`.
    private var applyingZoom = false

    private var geometry = ViewerImageGeometry(
        naturalSize: .zero, unitScale: 1, viewportSize: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // The matte follows the window appearance the same way every other
        // viewer mode's page background does (see `underPageBackgroundColor`
        // in ViewerView) — `windowBackgroundColor` is a dynamic color, so
        // light/dark switches live with no observer of our own.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // The whole point of the native surface: AppKit's own pinch, anchored
        // at the gesture centroid, rubber-banding at the limits.
        scrollView.allowsMagnification = true
        // `.automatic` already stops a fitted image from jiggling (elasticity
        // only engages when the content overflows), so this is exactly the
        // Preview feel: elastic while zoomed in, solid while it fits.
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .automatic

        // A clip view that centers a document smaller than itself. AppKit
        // pins it to a corner otherwise, which puts a fitted portrait image
        // against one edge of a wide pane.
        let clip = ViewerImageClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip

        scrollView.documentView = imageView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        scrollView.onSmartMagnify = { [weak self] point in
            self?.toggleZoom(at: point)
        }
        imageView.onDoubleClick = { [weak self] point in
            self?.toggleZoom(at: point)
        }

        // Both ends of a pinch. The START matters as much as the end: a
        // `layout()` that ran mid-gesture while the pane still thought it was
        // fitting would snap the magnification back under the user's fingers.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userStartedMagnifying),
            name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationDidChange),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        setAccessibilityRoleDescription("image viewer")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The view keyboard focus belongs to while this pane is showing an
    /// image, so arrow keys and Page Up/Down scroll the image.
    var focusView: NSView { scrollView }

    // MARK: - Content

    /// Display `url`, resetting to best-fit. Returns false when the file is
    /// not an image this machine can decode — the caller then falls back to
    /// the template page's error card rather than leaving a blank matte.
    @discardableResult
    func show(_ url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url),
              let natural = ViewerImageGeometry.naturalSize(of: image)
        else {
            Self.logger.info("cannot decode image at \(url.path, privacy: .public)")
            self.url = nil
            imageView.image = nil
            return false
        }
        self.url = url
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: natural.size)
        imageView.isVector = natural.isVector
        isFitting = true
        updateGeometry()
        applyZoom(geometry.fitZoom)
        return true
    }

    /// Re-read the file after a save (live reload) or an explicit `+reload`.
    ///
    /// Zoom and scroll position survive a reload of the SAME image size — the
    /// analogue of the scroll preservation every other file mode gets — but a
    /// re-export at different dimensions re-fits, because the old
    /// magnification and scroll offset describe a picture that no longer
    /// exists.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let url else { return false }
        let previousSize = imageView.frame.size
        let previousZoom = currentZoom
        let previousCenter = visibleCenterInDocument
        let wasFitting = isFitting

        guard show(url) else { return false }

        guard !wasFitting, imageView.frame.size == previousSize else { return true }
        isFitting = false
        applyZoom(previousZoom, centeredAt: previousCenter)
        return true
    }

    /// Drop the image (leaving image mode, or detaching the pane) so a closed
    /// pane sitting in the undo stack is not holding a decoded bitmap.
    func clear() {
        url = nil
        imageView.image = nil
    }

    // MARK: - Zoom

    var currentZoom: CGFloat { geometry.zoom(forMagnification: scrollView.magnification) }

    /// Apply a Cmd+/Cmd−/Cmd-0 chord, anchored at the middle of the viewport.
    func applyZoomAction(_ action: ViewerView.ZoomAction) {
        updateGeometry()
        let target = geometry.stepped(from: currentZoom, action: action)
        isFitting = abs(target - geometry.fitZoom) < 0.0001
        applyZoom(target, centeredAt: visibleCenterInDocument)
    }

    /// Double-click / two-finger double-tap: fit ⇄ 100%, anchored where the
    /// gesture landed so zooming in goes to the detail you pointed at.
    private func toggleZoom(at pointInWindow: NSPoint) {
        updateGeometry()
        let target = geometry.doubleClickZoom(from: currentZoom)
        isFitting = abs(target - geometry.fitZoom) < 0.0001
        let anchor = imageView.convert(pointInWindow, from: nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            applyZoom(target, centeredAt: anchor)
        }
    }

    private func applyZoom(_ zoom: CGFloat, centeredAt anchor: NSPoint? = nil) {
        let magnification = geometry.magnification(forZoom: geometry.clamped(zoom))
        applyingZoom = true
        defer { applyingZoom = false }
        if let anchor {
            scrollView.setMagnification(magnification, centeredAt: anchor)
        } else {
            scrollView.magnification = magnification
            // A fresh fit starts at the top-left of the image; the centering
            // clip view takes over on whichever axis actually fits.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    @objc private func userStartedMagnifying() {
        guard !applyingZoom else { return }
        isFitting = false
    }

    /// The user finished a pinch. Their magnification is now the pane's, so
    /// a later resize must preserve it rather than snapping back to fit —
    /// unless they happened to land exactly on fit.
    @objc private func magnificationDidChange() {
        guard !applyingZoom else { return }
        isFitting = abs(currentZoom - geometry.fitZoom) < 0.0001
    }

    private var visibleCenterInDocument: NSPoint {
        let visible = scrollView.contentView.documentVisibleRect
        return NSPoint(x: visible.midX, y: visible.midY)
    }

    // MARK: - Geometry

    /// Recompute the inputs the zoom rules depend on: the viewport, and the
    /// backing scale that decides what 100% means.
    ///
    /// The viewport is THIS view's bounds rather than the clip view's frame:
    /// the scroll view is pinned to all four edges and its scrollers are
    /// overlays, so the two are the same rectangle — but the clip view is
    /// tiled by `NSScrollView` during its own layout, which is a pass behind
    /// ours, and a fit computed from a stale viewport is visibly wrong for one
    /// frame of every divider drag.
    private func updateGeometry() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        geometry = ViewerImageGeometry(
            naturalSize: imageView.frame.size,
            unitScale: imageView.isVector ? 1 : 1 / max(scale, 1),
            viewportSize: bounds.size)
        // Rubber-banding needs the limits to be the scroll view's, not ours:
        // clamping in our own code would make an over-pinch stop dead instead
        // of stretching and springing back.
        let low = geometry.magnification(forZoom: geometry.minZoom)
        let high = geometry.magnification(forZoom: geometry.maxZoom)
        if scrollView.minMagnification != low { scrollView.minMagnification = low }
        if scrollView.maxMagnification != high { scrollView.maxMagnification = high }
    }

    override func layout() {
        super.layout()
        guard imageView.image != nil else { return }
        let zoomBefore = currentZoom
        updateGeometry()
        // Fitting: the pane was resized (a divider drag, a window resize) and
        // the user had not chosen a zoom of their own, so "fit" has to keep
        // meaning fit. Otherwise keep the USER's zoom — but still re-derive
        // the magnification, because `unitScale` changes when the pane crosses
        // between a Retina and a non-Retina display and 100% has to stay 100%.
        let target = geometry.clamped(isFitting ? geometry.fitZoom : zoomBefore)
        // `layout()` runs on every frame of a divider drag; re-applying an
        // unchanged magnification would scroll and re-tile the scroll view
        // each time, which is both wasted work and a way to fight the user's
        // own scroll position.
        guard abs(geometry.magnification(forZoom: target) - scrollView.magnification) > 0.0001
        else { return }
        applyZoom(target, centeredAt: isFitting ? nil : visibleCenterInDocument)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// Scroll view that hands a two-finger double-tap to the pane's zoom toggle
/// instead of AppKit's default "magnify toward this region" behavior, which
/// has no idea what fit or 100% mean for this image.
private final class ViewerImageScrollView: NSScrollView {
    var onSmartMagnify: ((NSPoint) -> Void)?

    override func smartMagnify(with event: NSEvent) {
        guard let onSmartMagnify else {
            super.smartMagnify(with: event)
            return
        }
        onSmartMagnify(event.locationInWindow)
    }
}

/// Clip view that centers a document smaller than the viewport.
///
/// The canonical AppKit gap: `NSScrollView` pins a small document to a corner,
/// which puts a fitted portrait image hard against one edge of a wide pane.
/// Constraining the proposed bounds is the documented place to fix it, and it
/// stays correct through magnification because the document frame and the clip
/// bounds are both in the magnified coordinate space.
private final class ViewerImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let content = documentView.frame
        if content.width < rect.width {
            rect.origin.x = (content.width - rect.width) / 2
        }
        if content.height < rect.height {
            rect.origin.y = (content.height - rect.height) / 2
        }
        return rect
    }
}

/// The document view: the image's own pixel grid, one document unit per image
/// pixel, drawn at whatever scale the scroll view's magnification asks for.
private final class ViewerImageDocumentView: NSView {
    var onDoubleClick: ((NSPoint) -> Void)?

    /// True for art with no pixel grid (SVG), which changes what 100% means.
    var isVector = false

    var image: NSImage? {
        didSet {
            stopAnimating()
            startAnimatingIfNeeded()
            needsDisplay = true
        }
    }

    /// Top-left origin, so a tall image opens at its top rather than its
    /// bottom the way a non-flipped AppKit view would.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let interpolation = self.interpolation
        NSGraphicsContext.current?.imageInterpolation = interpolation
        image.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: interpolation.rawValue)])
    }

    /// Smooth while the image is at or below its natural resolution; **hard
    /// pixels from 2x up**, because the only reason to magnify a screenshot
    /// that far is to look at individual pixels, and a bilinear smear of them
    /// answers no question anyone had.
    ///
    /// Measured from the view's own transform rather than plumbed down from the
    /// surface, so it is right during a live pinch as well as after one:
    /// `convert(_:to: nil)` already carries the scroll view's magnification, and
    /// multiplying by the backing scale turns points into device pixels — which
    /// for a raster image is exactly device-pixels-per-image-pixel.
    private var interpolation: NSImageInterpolation {
        guard !isVector else { return .high }
        let pointsPerUnit = convert(NSSize(width: 1, height: 1), to: nil).width
        let devicePixelsPerImagePixel = pointsPerUnit * (window?.backingScaleFactor ?? 1)
        return devicePixelsPerImagePixel >= 2 ? .none : .high
    }

    // MARK: - Gestures

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let onDoubleClick else {
            super.mouseDown(with: event)
            return
        }
        onDoubleClick(event.locationInWindow)
    }

    // MARK: - Animated images

    /// Animation is driven by hand because the image is drawn by hand (see
    /// `draw`), and `NSImageView`'s built-in animation is not available to a
    /// custom `draw(_:)`. A `.gif` that sits on frame one reads as a broken
    /// image viewer, and GIFs are squarely in the set of files these panes get
    /// pointed at.
    private var animationTimer: Timer?
    private var animatedRep: NSBitmapImageRep?
    private var frameIndex = 0

    private func startAnimatingIfNeeded() {
        guard let image,
              let rep = image.representations
                .compactMap({ $0 as? NSBitmapImageRep })
                .first(where: {
                    (($0.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 0) > 1
                })
        else { return }
        animatedRep = rep
        frameIndex = 0
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        guard let rep = animatedRep else { return }
        // A 0-duration frame means "as fast as possible", which browsers cap at
        // 100ms; matching that keeps a pathological GIF from pinning a core.
        let raw = (rep.value(forProperty: .currentFrameDuration) as? NSNumber)?.doubleValue ?? 0
        let delay = raw > 0.011 ? raw : 0.1
        animationTimer = Timer.scheduledTimer(
            withTimeInterval: delay, repeats: false
        ) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func advanceFrame() {
        guard let rep = animatedRep,
              let count = (rep.value(forProperty: .frameCount) as? NSNumber)?.intValue,
              count > 1
        else { return }
        frameIndex = (frameIndex + 1) % count
        rep.setProperty(.currentFrame, withValue: NSNumber(value: frameIndex))
        needsDisplay = true
        scheduleNextFrame()
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        animatedRep = nil
    }

    /// A pane that leaves the window (close, or an undo-retained detach) must
    /// stop ticking; nothing is on screen to animate.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else if animationTimer == nil {
            startAnimatingIfNeeded()
        }
    }
}
