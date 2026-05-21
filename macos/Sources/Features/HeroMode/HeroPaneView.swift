import SwiftUI
import GhosttyKit

struct HeroPaneView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState

    var body: some View {
        HeroPaneRepresentable(
            leaves: leaves,
            selectedIndex: state.selectedIndex
        )
    }
}

struct HeroPaneRepresentable: NSViewRepresentable {
    let leaves: [Ghostty.SurfaceView]
    let selectedIndex: Int

    func makeNSView(context: Context) -> HeroPaneContainer {
        HeroPaneContainer()
    }

    func updateNSView(_ container: HeroPaneContainer, context: Context) {
        container.update(leaves: leaves, selectedIndex: selectedIndex)
    }
}

class HeroPaneContainer: NSView {
    override var isFlipped: Bool { true }

    private let strip = HeroPaneStrip()
    private var currentIndex: Int = -1
    private let gap: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        relayout()
    }

    func update(leaves: [Ghostty.SurfaceView], selectedIndex: Int) {
        let changed = rebuildIfNeeded(leaves: leaves)
        if changed { relayout() }
        animateToIndex(selectedIndex)
    }

    private func rebuildIfNeeded(leaves: [Ghostty.SurfaceView]) -> Bool {
        let currentSurfaces = strip.subviews.compactMap { ($0 as? HeroPaneSlot)?.surfaceView }
        guard currentSurfaces != leaves else { return false }

        strip.subviews.forEach { $0.removeFromSuperview() }

        for surface in leaves {
            let slot = HeroPaneSlot(surfaceView: surface)
            strip.addSubview(slot)
        }
        return true
    }

    private func relayout() {
        let h = bounds.height
        let w = bounds.width
        guard h > 0, w > 0 else { return }

        let stride = h + gap

        for (i, slot) in strip.subviews.enumerated() {
            slot.frame = NSRect(x: 0, y: CGFloat(i) * stride, width: w, height: h)
            if let paneSlot = slot as? HeroPaneSlot {
                paneSlot.surfaceView.frame = paneSlot.bounds
            }
        }

        let totalHeight = CGFloat(strip.subviews.count) * stride
        strip.frame = NSRect(x: 0, y: strip.frame.origin.y, width: w, height: totalHeight)

        if currentIndex >= 0 {
            strip.frame.origin.y = -CGFloat(currentIndex) * stride
        }
    }

    private func animateToIndex(_ index: Int) {
        let shouldAnimate = currentIndex >= 0 && currentIndex != index
        currentIndex = index

        let h = bounds.height
        guard h > 0 else { return }
        let stride = h + gap
        let target = -CGFloat(index) * stride

        if !shouldAnimate {
            strip.layer?.removeAllAnimations()
            strip.frame.origin.y = target
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            strip.animator().frame.origin.y = target
        }
    }
}

private class HeroPaneStrip: NSView {
    override var isFlipped: Bool { true }
}

private class HeroPaneSlot: NSView {
    let surfaceView: Ghostty.SurfaceView

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        wantsLayer = true
        surfaceView.removeFromSuperview()
        addSubview(surfaceView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        surfaceView.frame = bounds
    }
}
