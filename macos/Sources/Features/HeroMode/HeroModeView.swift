import SwiftUI
import GhosttyKit

struct HeroModeView: View {
    let tree: SplitTree<PaneView>
    @ObservedObject var state: HeroModeState

    @State private var navigator = HeroKeyNavigator()

    /// Highlight state for the divider. It lives here rather than in
    /// `HeroDivider` because the thing the pointer actually touches is the
    /// AppKit grab handle, not the SwiftUI line.
    @State private var isDividerHovering = false
    @State private var isDividerDragging = false

    var body: some View {
        // Every pane participates: terminals and viewers alike. This must stay
        // the full leaf list — the controller's selection/count logic
        // (BaseTerminalController) indexes the same list.
        let leaves = tree.root?.leaves() ?? []

        // Republish the live pane list to the key monitor. The monitor is
        // installed once (onAppear) while SwiftUI hands this struct a new
        // `tree` on every split change, so it must never navigate a captured
        // one — body is the one place guaranteed to run with the current tree.
        let _ = navigator.update(state: state, leaves: leaves)

        GeometryReader { geo in
            let carouselWidth = geo.size.width * state.carouselRatio
            let heroWidth = geo.size.width - carouselWidth - dividerWidth
            let heroAspectRatio = heroWidth / geo.size.height

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    HeroPaneView(
                        leaves: leaves,
                        state: state
                    )
                    .frame(width: heroWidth, height: geo.size.height)

                    HeroDivider(isActive: isDividerHovering || isDividerDragging)

                    HeroCarouselView(
                        leaves: leaves,
                        state: state,
                        heroAspectRatio: heroAspectRatio
                    )
                    .frame(width: carouselWidth, height: geo.size.height)
                }

                // The grab target is an AppKit view layered ABOVE the panes, the
                // same arrangement SplitView uses and for the same reason: the
                // panes host AppKit views (terminal surfaces, web views) that
                // out-hit-test any SwiftUI gesture area, which leaves a
                // SwiftUI-only divider grabbable only on its drawn line however
                // wide its invisible frame is. It also means one view owns both
                // the cursor (resetCursorRects) and the drag, so the resize
                // cursor can no longer appear somewhere you cannot actually grab.
                DividerHandle(
                    direction: .horizontal,
                    onDragBegan: { isDividerDragging = true },
                    onDragDelta: { delta, startRatio in
                        // Cumulative from mouse-down against the ratio captured
                        // there, so the divider tracks the pointer rather than
                        // integrating per-tick deltas. Dragging right shrinks the
                        // carousel, which sits on the right.
                        state.carouselRatio = startRatio - delta / geo.size.width
                        state.clampCarouselRatio()
                        state.scrollOffset = 0
                    },
                    onDragEnded: { isDividerDragging = false },
                    onDoubleClick: nil,
                    onHoverChanged: { isDividerHovering = $0 },
                    currentSplit: { state.carouselRatio }
                )
                .frame(width: dividerGrabWidth, height: geo.size.height)
                .position(x: heroWidth + dividerWidth / 2, y: geo.size.height / 2)
            }
        }
        .onAppear { navigator.install() }
        .onDisappear { navigator.remove() }
    }

    private let dividerWidth: CGFloat = 6

    /// The pointer target: the visible line plus ~4pt of grab zone into each
    /// pane, matching SplitView's splitter.
    private let dividerGrabWidth: CGFloat = 9
}

/// The drawn divider line. Purely visual: the pointer never interacts with it.
/// Both the cursor and the drag belong to the `DividerHandle` layered over it
/// (see HeroModeView), which is an AppKit view and therefore actually wins hit
/// testing against the panes' AppKit content.
struct HeroDivider: View {
    /// Whether the pointer is on the grab handle or dragging it.
    let isActive: Bool

    private let visibleWidth: CGFloat = 1
    private let totalWidth: CGFloat = 6

    var body: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(width: visibleWidth)
            .frame(width: totalWidth)
    }

    private var dividerColor: Color {
        isActive
            ? Color(red: 0.416, green: 0.416, blue: 1.0)
            : Color.gray.opacity(0.3)
    }
}
