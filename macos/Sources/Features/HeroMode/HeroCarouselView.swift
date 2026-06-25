import SwiftUI
import GhosttyKit

struct HeroCarouselView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState
    let heroAspectRatio: CGFloat

    var body: some View {
        HeroCarouselRepresentable(
            leaves: leaves,
            state: state,
            heroAspectRatio: heroAspectRatio
        )
    }
}

struct HeroCarouselRepresentable: NSViewRepresentable {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState
    let heroAspectRatio: CGFloat

    func makeNSView(context: Context) -> HeroCarouselContainer {
        HeroCarouselContainer()
    }

    func updateNSView(_ container: HeroCarouselContainer, context: Context) {
        container.update(
            leaves: leaves,
            state: state,
            heroAspectRatio: heroAspectRatio
        )
    }
}

class HeroCarouselContainer: NSView {
    override var isFlipped: Bool { true }

    private let strip = CarouselStrip()
    private var tiles: [CarouselTile] = []
    private var currentIndex: Int = -1
    private var scrollOffset: CGFloat = 0
    private let gap: CGFloat = 8
    private var heroAspectRatio: CGFloat = 1.5
    private weak var state: HeroModeState?
    private var currentLeaves: [Ghostty.SurfaceView] = []
    private var snapshotTimer: Timer?
    private var needsInitialSnapshot = false
    private var isScrolling = false
    private var scrollEndTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        strip.wantsLayer = true
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        relayout(animated: false)
        if needsInitialSnapshot {
            needsInitialSnapshot = false
            DispatchQueue.main.async { [weak self] in
                self?.refreshSnapshots()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimers()
        }
    }

    func update(leaves: [Ghostty.SurfaceView], state: HeroModeState, heroAspectRatio: CGFloat) {
        self.state = state
        self.heroAspectRatio = heroAspectRatio

        let tilesChanged = rebuildTiles(leaves: leaves)
        self.currentLeaves = leaves
        if tilesChanged {
            needsInitialSnapshot = true
        }

        // Defer bounds-driven layout to layout(), which always runs with the
        // final frame. Relaying out here too is redundant and can position the
        // strip from stale bounds: during a divider drag SwiftUI hasn't applied
        // the new frame yet, so our bounds are still the previous tick's value.
        // layout() runs on every drag tick (the carousel width changes each
        // tick), so a single relayout there is sufficient.
        needsLayout = true

        if state.selectedIndex != currentIndex {
            scrollOffset = 0
            state.scrollOffset = 0
            animateToIndex(state.selectedIndex)
        }

        startSnapshotTimer()
    }

    private var thumbSize: CGSize {
        // Thumbnails mirror the hero pane's aspect ratio. Width is driven by the
        // carousel width, but we must cap the resulting height to the carousel's
        // visible height — otherwise dragging the divider to widen the carousel
        // (which shrinks heroAspectRatio) makes the selected tile grow taller and
        // taller, spilling out of the viewport. When the height would exceed the
        // cap we shrink the width instead, preserving the aspect ratio.
        let ar = max(heroAspectRatio, 0.1)
        let maxW = bounds.width * 0.88
        let maxH = bounds.height * 0.7
        var w = maxW
        var h = w / ar
        if h > maxH {
            h = maxH
            w = h * ar
        }
        return CGSize(width: w, height: h)
    }

    @discardableResult
    private func rebuildTiles(leaves: [Ghostty.SurfaceView]) -> Bool {
        let oldSurfaces = currentLeaves
        guard oldSurfaces != leaves else {
            for (i, tile) in tiles.enumerated() {
                tile.isSelected = i == (state?.selectedIndex ?? 0)
            }
            return false
        }

        var tilesBySurface: [ObjectIdentifier: CarouselTile] = [:]
        for tile in tiles {
            tilesBySurface[ObjectIdentifier(tile.surfaceView)] = tile
        }

        var newTiles: [CarouselTile] = []
        for surface in leaves {
            let id = ObjectIdentifier(surface)
            if let existing = tilesBySurface.removeValue(forKey: id) {
                newTiles.append(existing)
            } else {
                let tile = CarouselTile(surfaceView: surface)
                strip.addSubview(tile)
                newTiles.append(tile)
            }
        }

        for (_, tile) in tilesBySurface {
            tile.removeFromSuperview()
        }

        tiles = newTiles

        for (i, tile) in tiles.enumerated() {
            tile.isSelected = i == (state?.selectedIndex ?? 0)
            tile.onTap = { [weak self, weak tile] in
                guard let self = self, let tile = tile else { return }
                guard let idx = self.tiles.firstIndex(where: { $0 === tile }) else { return }
                self.state?.select(idx, leafCount: self.currentLeaves.count)
            }
        }

        return true
    }

    private func relayout(animated: Bool) {
        let ts = thumbSize
        guard ts.width > 0, ts.height > 0 else { return }
        let padding = bounds.width * 0.06

        for (i, tile) in tiles.enumerated() {
            let y = CGFloat(i) * (ts.height + gap)
            tile.frame = NSRect(x: padding, y: y, width: ts.width, height: ts.height)
        }

        let totalHeight = CGFloat(tiles.count) * (ts.height + gap)
        strip.frame = NSRect(x: 0, y: strip.frame.origin.y, width: bounds.width, height: totalHeight)

        repositionStrip(animated: animated)
    }

    private func repositionStrip(animated: Bool) {
        let ts = thumbSize
        guard ts.height > 0 else { return }
        let stride = ts.height + gap
        let idx = currentIndex >= 0 ? currentIndex : 0
        let centeredY = bounds.height / 2 - (CGFloat(idx) * stride + ts.height / 2)
        let targetY = centeredY + scrollOffset

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                strip.animator().frame.origin.y = targetY
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            strip.frame.origin.y = targetY
            CATransaction.commit()
        }
    }

    private func animateToIndex(_ index: Int) {
        let wasFirst = currentIndex < 0
        currentIndex = index

        for (i, tile) in tiles.enumerated() {
            tile.isSelected = i == index
        }

        repositionStrip(animated: !wasFirst)
    }

    override func scrollWheel(with event: NSEvent) {
        let ts = thumbSize
        guard ts.height > 0 else { return }

        isScrolling = true
        scrollEndTimer?.invalidate()
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.isScrolling = false
            self?.refreshSnapshots()
        }

        scrollOffset += event.scrollingDeltaY

        let stride = ts.height + gap
        let totalContentHeight = CGFloat(tiles.count) * stride - gap
        let maxScrollDown = max(0, (totalContentHeight - ts.height) / 2)
        let maxScrollUp = -maxScrollDown
        scrollOffset = max(maxScrollUp, min(maxScrollDown, scrollOffset))

        state?.scrollOffset = scrollOffset
        repositionStrip(animated: false)
    }

    private func startSnapshotTimer() {
        guard snapshotTimer == nil else { return }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self, !self.isScrolling else { return }
            self.refreshVisibleSnapshots()
        }
    }

    private func stopTimers() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        scrollEndTimer?.invalidate()
        scrollEndTimer = nil
    }

    private func refreshSnapshots() {
        for tile in tiles {
            tile.refreshSnapshot()
        }
    }

    private func refreshVisibleSnapshots() {
        let visibleRect = bounds
        for tile in tiles {
            let tileFrameInSelf = strip.convert(tile.frame, to: self)
            if tileFrameInSelf.intersects(visibleRect) {
                tile.refreshSnapshot()
            }
        }
    }

    deinit {
        stopTimers()
    }
}

private class CarouselStrip: NSView {
    override var isFlipped: Bool { true }
}

private class CarouselTile: NSView {
    let surfaceView: Ghostty.SurfaceView
    var onTap: (() -> Void)?
    private let imageView = NSImageView()
    private let borderLayer = CAShapeLayer()

    private let selectedColor = NSColor(red: 0.416, green: 0.416, blue: 1.0, alpha: 1.0)
    private let hoverColor = NSColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0)
    private let normalColor = NSColor(white: 0.5, alpha: 0.3)

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    private var isHovered = false

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.strokeColor = normalColor.cgColor
        layer?.addSublayer(borderLayer)

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 6, cornerHeight: 6, transform: nil
        )
    }

    func refreshSnapshot() {
        guard let surfaceLayer = surfaceView.layer else { return }
        let size = surfaceView.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = surfaceView.window?.backingScaleFactor ?? 2.0
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)
        guard let cgCtx = ctx?.cgContext else { return }

        cgCtx.scaleBy(x: scale, y: scale)
        surfaceLayer.render(in: cgCtx)

        let image = NSImage(size: size)
        image.addRepresentation(bitmapRep)
        imageView.image = image
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onTap?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    private func updateAppearance() {
        if isSelected {
            borderLayer.strokeColor = selectedColor.cgColor
            borderLayer.lineWidth = 2
            layer?.shadowColor = selectedColor.cgColor
            layer?.shadowRadius = 15
            layer?.shadowOpacity = 0.4
            layer?.shadowOffset = .zero
            alphaValue = 1.0
        } else if isHovered {
            borderLayer.strokeColor = hoverColor.cgColor
            borderLayer.lineWidth = 1
            layer?.shadowOpacity = 0
            alphaValue = 0.6
        } else {
            borderLayer.strokeColor = normalColor.cgColor
            borderLayer.lineWidth = 1
            layer?.shadowOpacity = 0
            alphaValue = 0.35
        }
    }
}
