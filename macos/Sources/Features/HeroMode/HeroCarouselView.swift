import SwiftUI
import GhosttyKit

struct HeroCarouselView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState
    let heroAspectRatio: CGFloat

    @State private var hoveredIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let thumbWidth = geo.size.width * 0.88
            let thumbHeight = thumbWidth / heroAspectRatio
            let gap: CGFloat = 8
            let stride = thumbHeight + gap

            let centeredOffset = geo.size.height / 2
                - (CGFloat(state.selectedIndex) * stride + thumbHeight / 2)

            ZStack(alignment: .top) {
                VStack(spacing: gap) {
                    ForEach(Array(leaves.enumerated()), id: \.element.id) { index, surface in
                        HeroCarouselItem(
                            surfaceView: surface,
                            isSelected: index == state.selectedIndex,
                            isHovered: index == hoveredIndex,
                            thumbnailSize: CGSize(width: thumbWidth, height: thumbHeight)
                        )
                        .contentShape(Rectangle())
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
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onScrollWheel { delta in
                state.scrollOffset -= delta.y
                let totalHeight = CGFloat(leaves.count) * stride
                let maxScroll = totalHeight * 0.8
                state.scrollOffset = max(-maxScroll, min(maxScroll, state.scrollOffset))
            }
        }
        .background(Color.black.opacity(0.3))
    }
}

struct ScrollWheelModifier: ViewModifier {
    let handler: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.overlay(
            ScrollWheelView(handler: handler)
        )
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let handler: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }

    class ScrollWheelNSView: NSView {
        var handler: ((CGPoint) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            handler?(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
        }
    }
}

extension View {
    func onScrollWheel(_ handler: @escaping (CGPoint) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}
