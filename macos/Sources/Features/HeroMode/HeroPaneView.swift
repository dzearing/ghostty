import SwiftUI
import GhosttyKit

struct HeroPaneView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState
    let gap: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let paneHeight = geo.size.height
            let stride = paneHeight + gap
            let offset = -CGFloat(state.selectedIndex) * stride

            VStack(spacing: gap) {
                ForEach(Array(leaves.enumerated()), id: \.element.id) { index, surface in
                    Ghostty.InspectableSurface(
                        surfaceView: surface,
                        isSplit: false
                    )
                    .frame(width: geo.size.width, height: paneHeight)
                }
            }
            .frame(width: geo.size.width, alignment: .top)
            .offset(y: offset)
            .animation(.easeInOut(duration: 0.35), value: state.selectedIndex)
        }
        .clipped()
    }
}
