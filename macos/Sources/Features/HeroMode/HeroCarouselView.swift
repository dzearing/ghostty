import SwiftUI
import GhosttyKit

struct HeroCarouselView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState
    let heroAspectRatio: CGFloat

    @State private var hoveredIndex: Int? = nil
    @State private var scrollMonitor: Any? = nil
    @State private var carouselFrame: CGRect = .zero

    var body: some View {
        GeometryReader { geo in
            let thumbWidth = geo.size.width * 0.88
            let thumbHeight = thumbWidth / heroAspectRatio
            let gap: CGFloat = 8
            let stride = thumbHeight + gap

            let centeredOffset = geo.size.height / 2
                - (CGFloat(state.selectedIndex) * stride + thumbHeight / 2)

            VStack(spacing: gap) {
                ForEach(Array(leaves.enumerated()), id: \.element.id) { index, surface in
                    HeroCarouselItem(
                        surfaceView: surface,
                        isSelected: index == state.selectedIndex,
                        isHovered: index == hoveredIndex,
                        thumbnailSize: CGSize(width: thumbWidth, height: thumbHeight)
                    )
                    .onHover { hovering in
                        hoveredIndex = hovering ? index : nil
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: state.animationDuration(
                            from: state.selectedIndex, to: index))) {
                            state.select(index, leafCount: leaves.count)
                        }
                    }
                }
            }
            .padding(.horizontal, geo.size.width * 0.06)
            .offset(y: centeredOffset + state.scrollOffset)
            .animation(.easeInOut(duration: 0.3), value: state.selectedIndex)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .background(Color.black.opacity(0.3))
        .background(GeometryReader { geo in
            Color.clear.preference(key: CarouselFrameKey.self, value: geo.frame(in: .global))
        })
        .onPreferenceChange(CarouselFrameKey.self) { carouselFrame = $0 }
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
    }

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let window = event.window else { return event }
            let windowPoint = event.locationInWindow
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            let flippedPoint = CGPoint(x: screenPoint.x, y: screenPoint.y)

            if carouselFrame.contains(flippedPoint) {
                let heroAR = heroAspectRatio
                let thumbWidth = carouselFrame.width * 0.88
                let thumbHeight = thumbWidth / heroAR
                let gap: CGFloat = 8
                let stride = thumbHeight + gap
                let totalHeight = CGFloat(leaves.count) * stride
                let maxScroll = totalHeight * 0.8

                state.scrollOffset += event.scrollingDeltaY
                state.scrollOffset = max(-maxScroll, min(maxScroll, state.scrollOffset))
                return nil
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}

private struct CarouselFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
