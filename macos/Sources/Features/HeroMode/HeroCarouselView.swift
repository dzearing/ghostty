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
    private var gap: CGFloat = 8
    private var thumbSize: CGSize = .zero
    private weak var state: HeroModeState?
    private var snapshotTimer: Timer?

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
        relayout(animated: false)
    }

    func update(leaves: [Ghostty.SurfaceView], state: HeroModeState, heroAspectRatio: CGFloat) {
        self.state = state

        let thumbWidth = bounds.width * 0.88
        let thumbHeight = thumbWidth / max(heroAspectRatio, 0.1)
        thumbSize = CGSize(width: thumbWidth, height: thumbHeight)

        rebuildTiles(leaves: leaves)
        relayout(animated: false)

        if state.selectedIndex != currentIndex {
            scrollOffset = 0
            animateToIndex(state.selectedIndex)
        }

        if state.scrollOffset != scrollOffset {
            scrollOffset = state.scrollOffset
            repositionStrip(animated: false)
        }

        refreshSnapshots()
        startSnapshotTimer(leaves: leaves)
    }

    private func rebuildTiles(leaves: [Ghostty.SurfaceView]) {
        guard tiles.count != leaves.count ||
              !zip(tiles, leaves).allSatisfy({ $0.surfaceView === $1 }) else {
            for (i, tile) in tiles.enumerated() {
                tile.isSelected = i == (state?.selectedIndex ?? 0)
            }
            return
        }

        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()

        for (i, surface) in leaves.enumerated() {
            let tile = CarouselTile(surfaceView: surface)
            tile.isSelected = i == (state?.selectedIndex ?? 0)
            tile.onTap = { [weak self] in
                self?.state?.select(i, leafCount: leaves.count)
            }
            strip.addSubview(tile)
            tiles.append(tile)
        }
    }

    private func relayout(animated: Bool) {
        guard bounds.height > 0, thumbSize.width > 0 else { return }
        let padding = bounds.width * 0.06

        for (i, tile) in tiles.enumerated() {
            let y = CGFloat(i) * (thumbSize.height + gap)
            tile.frame = NSRect(
                x: padding,
                y: y,
                width: thumbSize.width,
                height: thumbSize.height
            )
        }

        let totalHeight = CGFloat(tiles.count) * (thumbSize.height + gap)
        strip.frame = NSRect(x: 0, y: strip.frame.origin.y, width: bounds.width, height: totalHeight)

        repositionStrip(animated: animated)
    }

    private func repositionStrip(animated: Bool) {
        let stride = thumbSize.height + gap
        let centeredY = bounds.height / 2
            - (CGFloat(currentIndex >= 0 ? currentIndex : 0) * stride + thumbSize.height / 2)

        let targetY = centeredY + scrollOffset

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                strip.animator().frame.origin.y = targetY
            }
        } else {
            strip.frame.origin.y = targetY
        }
    }

    private func animateToIndex(_ index: Int) {
        let oldIndex = currentIndex
        currentIndex = index

        for (i, tile) in tiles.enumerated() {
            tile.isSelected = i == index
        }

        repositionStrip(animated: oldIndex >= 0)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let state = state else { return }
        scrollOffset += event.scrollingDeltaY
        let stride = thumbSize.height + gap
        let totalHeight = CGFloat(tiles.count) * stride
        let maxScroll = max(totalHeight, bounds.height) * 0.8
        scrollOffset = max(-maxScroll, min(maxScroll, scrollOffset))
        state.scrollOffset = scrollOffset
        repositionStrip(animated: false)
    }

    private func startSnapshotTimer(leaves: [Ghostty.SurfaceView]) {
        guard snapshotTimer == nil else { return }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshSnapshots()
        }
    }

    private func refreshSnapshots() {
        for tile in tiles {
            tile.refreshSnapshot()
        }
    }

    deinit {
        snapshotTimer?.invalidate()
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
    private let glowLayer = CALayer()
    private var isHovered = false

    private let selectedColor = NSColor(red: 0.416, green: 0.416, blue: 1.0, alpha: 1.0)
    private let hoverColor = NSColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0)
    private let normalColor = NSColor(white: 0.5, alpha: 0.3)

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

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
        imageView.image = surfaceView.asImage
    }

    override func mouseDown(with event: NSEvent) {
        // intentionally empty — wait for mouseUp
    }

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
