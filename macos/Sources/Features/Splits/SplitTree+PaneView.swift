import AppKit

// Bridging helpers so the many existing call sites that think in terms of
// `Ghostty.SurfaceView` can keep operating on a `SplitTree<PaneView>`. These
// resolve a surface to the pane wrapping it (identity comparison) and forward
// to the generic tree API.

extension SplitTree where ViewType == PaneView {
    init(view surface: Ghostty.SurfaceView) {
        self.init(view: PaneView(surface: surface))
    }

    /// Find the pane that wraps the given surface view, if any.
    func pane(for surface: Ghostty.SurfaceView) -> PaneView? {
        first(where: { $0.surfaceView === surface })
    }

    func contains(_ surface: Ghostty.SurfaceView) -> Bool {
        pane(for: surface) != nil
    }

    /// Insert a new surface as a split relative to an existing surface's pane.
    func inserting(
        view surface: Ghostty.SurfaceView,
        at existing: Ghostty.SurfaceView,
        direction: NewDirection,
        ratio: Double = 0.5
    ) throws -> Self {
        guard let existingPane = pane(for: existing) else {
            throw SplitError.viewNotFound
        }
        return try inserting(
            view: PaneView(surface: surface),
            at: existingPane,
            direction: direction,
            ratio: ratio)
    }
}

extension SplitTree.Node where ViewType == PaneView {
    /// Find the leaf node whose pane wraps the given surface view.
    func node(view surface: Ghostty.SurfaceView) -> Self? {
        guard let pane = leaves().first(where: { $0.surfaceView === surface }) else {
            return nil
        }
        return node(view: pane)
    }
}

extension Ghostty {
    /// Move focus to a pane's content. Terminal panes go through the full
    /// surface focus path; viewer panes just become first responder.
    static func moveFocus(
        to pane: PaneView,
        from: Ghostty.SurfaceView? = nil,
        delay: TimeInterval? = nil
    ) {
        switch pane.content {
        case .terminal(let surface):
            moveFocus(to: surface, from: from, delay: delay)
        case .viewer(let viewer):
            DispatchQueue.main.async {
                viewer.window?.makeFirstResponder(viewer)
            }
        }
    }
}
