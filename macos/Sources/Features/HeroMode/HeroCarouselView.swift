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
                        state.select(index, leafCount: leaves.count)
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
    }
}
