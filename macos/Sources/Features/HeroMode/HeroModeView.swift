import SwiftUI
import GhosttyKit

struct HeroModeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    @ObservedObject var state: HeroModeState

    @State private var keyMonitor: Any? = nil

    var body: some View {
        let leaves = tree.root?.leaves() ?? []

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
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private let dividerWidth: CGFloat = 6

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard state.isActive else { return event }
            let leaves = tree.root?.leaves() ?? []
            guard leaves.count > 1 else { return event }

            let hasShiftCmd = event.modifierFlags.contains([.shift, .command])
            if hasShiftCmd && event.keyCode == 126 {
                state.selectPrevious(leafCount: leaves.count)
                return nil
            } else if hasShiftCmd && event.keyCode == 125 {
                state.selectNext(leafCount: leaves.count)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
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
            DragGesture()
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
