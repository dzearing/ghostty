import SwiftUI
import GhosttyKit

struct HeroPaneView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState
    private let gap: CGFloat = 60

    var body: some View {
        GeometryReader { geo in
            let stride = geo.size.height + gap
            let targetOffset = -CGFloat(state.selectedIndex) * stride

            HeroPaneStrip(
                leaves: leaves,
                paneSize: geo.size,
                gap: gap
            )
            .modifier(SmoothSlide(offset: targetOffset))
            .animation(.easeInOut(duration: 0.35), value: state.selectedIndex)
        }
        .clipped()
    }
}

private struct HeroPaneStrip: View {
    let leaves: [Ghostty.SurfaceView]
    let paneSize: CGSize
    let gap: CGFloat

    var body: some View {
        VStack(spacing: gap) {
            ForEach(Array(leaves.enumerated()), id: \.element.id) { _, surface in
                Ghostty.InspectableSurface(
                    surfaceView: surface,
                    isSplit: false
                )
                .frame(width: paneSize.width, height: paneSize.height)
            }
        }
        .frame(width: paneSize.width, alignment: .top)
    }
}

private struct SmoothSlide: GeometryEffect {
    var offset: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: offset))
    }
}
