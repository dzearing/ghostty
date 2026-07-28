import SwiftUI
import GhosttyKit

struct HeroPaneView: View {
    let leaves: [PaneView]
    @ObservedObject var state: HeroModeState

    var body: some View {
        HeroPaneRepresentable(
            leaves: leaves,
            selectedIndex: state.selectedIndex
        )
    }
}

struct HeroPaneRepresentable: NSViewRepresentable {
    let leaves: [PaneView]
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
    private var slots: [HeroPaneSlot] = []
    private var currentIndex: Int = -1
    private let gap: CGFloat = 40

    /// Pending debounced reflow, used to coalesce the expensive grid reflow during
    /// a continuous divider drag (see scheduleReflow).
    private var pendingReflow: DispatchWorkItem?
    private let reflowDebounce: TimeInterval = 0.08

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.wantsLayer = true
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        relayout()
    }

    func update(leaves: [PaneView], selectedIndex: Int) {
        let changed = rebuildIfNeeded(leaves: leaves)
        if changed { relayout() }
        updateBackgroundColor()
        animateToIndex(selectedIndex)

        // When hero mode first activates (or the pane set changes) our bounds are
        // often still zero during this SwiftUI update pass, so the reflows above
        // no-op. Defer one reflow to the next runloop tick, by which point AppKit
        // has laid us out with real bounds.
        //
        // Gated on `changed` on purpose: SwiftUI also calls update() on every
        // divider-drag tick (the parent re-renders). An ungated reflow here would
        // fire immediately (synchronously) every tick, bypassing the debounce
        // below and blocking the main thread. During a drag `changed` is false,
        // so the drag's reflows go solely through the debounced layout() path.
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleReflow(immediate: true)
            }
        }
    }

    private func rebuildIfNeeded(leaves: [PaneView]) -> Bool {
        let currentPanes = slots.map(\.pane)
        guard currentPanes != leaves else { return false }

        var slotsByPane: [ObjectIdentifier: HeroPaneSlot] = [:]
        for slot in slots {
            slotsByPane[ObjectIdentifier(slot.pane)] = slot
        }

        var newSlots: [HeroPaneSlot] = []
        for pane in leaves {
            let id = ObjectIdentifier(pane)
            if let existing = slotsByPane.removeValue(forKey: id) {
                newSlots.append(existing)
            } else {
                let slot = HeroPaneSlot(pane: pane)
                strip.addSubview(slot)
                newSlots.append(slot)
            }
        }

        for (_, slot) in slotsByPane {
            slot.removeFromSuperview()
        }

        slots = newSlots
        return true
    }

    private func updateBackgroundColor() {
        // Viewers have no terminal config; tint off the first terminal pane,
        // falling back to the window background when the tree is all viewers.
        let bgColor: CGColor
        if let surface = slots.compactMap({ $0.pane.surfaceView }).first {
            bgColor = NSColor(surface.derivedConfig.backgroundColor).cgColor
        } else {
            bgColor = NSColor.windowBackgroundColor.cgColor
        }
        layer?.backgroundColor = bgColor
        strip.layer?.backgroundColor = bgColor
    }

    private func relayout() {
        let h = bounds.height
        let w = bounds.width
        guard h > 0, w > 0 else { return }

        let stride = h + gap

        for (i, slot) in slots.enumerated() {
            slot.frame = NSRect(x: 0, y: CGFloat(i) * stride, width: w, height: h)
            slot.contentView.frame = slot.bounds
        }

        let totalHeight = CGFloat(slots.count) * stride
        strip.frame = NSRect(x: 0, y: strip.frame.origin.y, width: w, height: totalHeight)

        if currentIndex >= 0 {
            strip.frame.origin.y = -CGFloat(currentIndex) * stride
        }

        // Reflow the terminal grid for the visible hero pane only. layout() runs
        // on every divider-drag tick, and a grid reflow (ghostty_surface_set_size)
        // is expensive — doing it synchronously here would block the main thread
        // and make the divider stutter instead of gliding with the cursor. So the
        // layout-driven reflow is debounced: the pane visually resizes immediately
        // (frames above) and the grid re-wraps once the drag settles. Off-screen
        // carousel slots are left stale and reflow lazily when selected.
        scheduleReflow(immediate: false)
    }

    /// Reflows the visible hero pane's terminal grid to match its slot bounds via
    /// the same path the normal split chain uses (sizeDidChange ->
    /// ghostty_surface_set_size). Only the selected slot is reflowed; off-screen
    /// slots reflow lazily the moment they are selected/scrolled into view.
    ///
    /// `immediate` reflows synchronously — used for discrete events (activation,
    /// selecting a different pane) that should re-wrap right away. Otherwise the
    /// reflow is debounced so a stream of layout passes during a divider drag
    /// collapses into a single reflow when the drag settles, keeping the drag
    /// smooth.
    private func scheduleReflow(immediate: Bool) {
        pendingReflow?.cancel()
        pendingReflow = nil

        guard !immediate else {
            reflowSelectedSlotNow()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.pendingReflow = nil
            self?.reflowSelectedSlotNow()
        }
        pendingReflow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reflowDebounce, execute: work)
    }

    private func reflowSelectedSlotNow() {
        guard currentIndex >= 0, currentIndex < slots.count else { return }
        slots[currentIndex].notifyReflowIfNeeded()
    }

    private func animateToIndex(_ index: Int) {
        let indexChanged = currentIndex != index
        let shouldAnimate = currentIndex >= 0 && currentIndex != index
        currentIndex = index

        // Only reflow here on an actual selection change. update() calls this on
        // every SwiftUI re-render (including each divider-drag tick); an ungated
        // immediate reflow would block the main thread every tick. On a real
        // selection change we reflow the newly visible pane right away so its grid
        // matches the hero area before/as it scrolls in.
        if indexChanged {
            scheduleReflow(immediate: true)
        }

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
    let pane: PaneView

    /// The NSView actually mounted in this slot (the surface for terminals,
    /// the ViewerView for viewers). PaneView itself is never in the hierarchy.
    var contentView: NSView { pane.contentView }

    /// The last size we notified the terminal core about. Used to skip
    /// redundant (expensive) reflows when the size hasn't actually changed.
    private var lastNotifiedSize: CGSize = .zero

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        let content = pane.contentView
        content.removeFromSuperview()
        // SwiftUI mounts pane content with translatesAutoresizingMaskIntoConstraints
        // off and positions it via its own constraints. Hero mode lays out by
        // assigning frames, so re-enable the autoresizing translation to make
        // the assigned frame authoritative in the constraint engine. Without
        // this a viewer's WKWebView — edge-pinned to the ViewerView with Auto
        // Layout — solves against an ambiguous 0×0 parent and renders nothing.
        // (SwiftUI switches it back off when it re-adopts the view on exit.)
        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }

    /// Notify the terminal core that this slot's surface has resized so its
    /// grid re-wraps to the new dimensions. This is the same entry point the
    /// normal split-resize chain uses (SurfaceScrollView -> sizeDidChange ->
    /// ghostty_surface_set_size). Hero mode bypasses that chain by assigning
    /// frames directly, so the visible slot must call it explicitly.
    ///
    /// Viewer panes have no terminal grid — their WKWebView is pinned to the
    /// ViewerView's edges with constraints, so the frame assignment alone is
    /// a complete resize and the grid notification is skipped.
    ///
    /// No-ops if the size is zero or unchanged since the last notification,
    /// which lets the container call this freely on every layout pass.
    func notifyReflowIfNeeded() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastNotifiedSize else { return }
        lastNotifiedSize = size
        // Disable implicit CALayer animations so the surface jumps straight to
        // the new size instead of interpolating its bounds.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.frame = bounds
        pane.surfaceView?.sizeDidChange(size)
        CATransaction.commit()
    }
}
