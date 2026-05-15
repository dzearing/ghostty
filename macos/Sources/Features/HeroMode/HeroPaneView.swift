import SwiftUI
import GhosttyKit

struct HeroPaneView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState

    var body: some View {
        ZStack {
            if state.selectedIndex < leaves.count {
                Ghostty.InspectableSurface(
                    surfaceView: leaves[state.selectedIndex],
                    isSplit: false
                )
                .id(leaves[state.selectedIndex].id)
                .transition(.asymmetric(
                    insertion: .move(edge: state.lastDirection == .down ? .bottom : .top),
                    removal: .move(edge: state.lastDirection == .down ? .top : .bottom)
                ))
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: state.selectedIndex)
    }
}
