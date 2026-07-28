import SwiftUI
import GhosttyKit

struct HeroModeView: View {
    let tree: SplitTree<PaneView>
    @ObservedObject var state: HeroModeState

    @State private var navigator = HeroKeyNavigator()

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

            HStack(spacing: 0) {
                HeroPaneView(
                    leaves: leaves,
                    state: state
                )
                .frame(width: heroWidth, height: geo.size.height)

                HeroDivider(
                    ratio: Binding(
                        get: { state.carouselRatio },
                        set: { newRatio in
                            state.carouselRatio = newRatio
                            state.clampCarouselRatio()
                            state.scrollOffset = 0
                        }
                    ),
                    containerWidth: geo.size.width
                )

                HeroCarouselView(
                    leaves: leaves,
                    state: state,
                    heroAspectRatio: heroAspectRatio
                )
                .frame(width: carouselWidth, height: geo.size.height)
            }
        }
        .onAppear { navigator.install() }
        .onDisappear { navigator.remove() }
    }

    private let dividerWidth: CGFloat = 6
}

struct HeroDivider: View {
    @Binding var ratio: CGFloat
    let containerWidth: CGFloat

    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragStartRatio: CGFloat = 0

    private let visibleWidth: CGFloat = 1
    private let totalWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: totalWidth)
                .contentShape(Rectangle())

            Rectangle()
                .fill(dividerColor)
                .frame(width: visibleWidth)
        }
        .frame(width: totalWidth)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .gesture(
            // Measure the drag in the GLOBAL coordinate space, not the divider's
            // local space. The divider moves as `ratio` changes, so a .local
            // gesture re-bases its translation every frame as the view slides
            // under the cursor — that feedback makes the divider oscillate
            // between two positions (you see two copies of the line while
            // dragging). Global space is fixed, so translation tracks the cursor
            // cleanly and the divider glides.
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartRatio = ratio
                    }
                    let delta = value.translation.width / containerWidth
                    ratio = dragStartRatio - delta
                }
                .onEnded { _ in
                    isDragging = false
                    if !isHovering {
                        NSCursor.pop()
                    }
                }
        )
    }

    private var dividerColor: Color {
        (isHovering || isDragging)
            ? Color(red: 0.416, green: 0.416, blue: 1.0)
            : Color.gray.opacity(0.3)
    }
}
