import SwiftUI
import GhosttyKit

struct HeroPaneView: View {
    let leaves: [Ghostty.SurfaceView]
    @ObservedObject var state: HeroModeState

    @State private var animatingFrom: Int? = nil
    @State private var animationOffset: CGFloat = 0
    @State private var transitionSnapshots: [Int: NSImage] = [:]
    @State private var previousSelectedIndex: Int = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let from = animatingFrom {
                    transitionContent(from: from, to: state.selectedIndex, size: geo.size)
                } else {
                    activeContent(size: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear { previousSelectedIndex = state.selectedIndex }
        .onChange(of: state.selectedIndex) { [previousSelectedIndex] newValue in
            startTransition(from: previousSelectedIndex, to: newValue)
            self.previousSelectedIndex = newValue
        }
    }

    @ViewBuilder
    private func activeContent(size: CGSize) -> some View {
        if state.selectedIndex < leaves.count {
            Ghostty.InspectableSurface(
                surfaceView: leaves[state.selectedIndex],
                isSplit: false
            )
        }
    }

    @ViewBuilder
    private func transitionContent(from: Int, to: Int, size: CGSize) -> some View {
        let rangeStart = min(from, to)
        let rangeEnd = max(from, to)

        VStack(spacing: 0) {
            ForEach(rangeStart...rangeEnd, id: \.self) { index in
                if index == to {
                    Ghostty.InspectableSurface(
                        surfaceView: leaves[index],
                        isSplit: false
                    )
                    .frame(width: size.width, height: size.height)
                } else if let snapshot = transitionSnapshots[index] {
                    Image(nsImage: snapshot)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else {
                    Color.black
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .offset(y: animationOffset * size.height)
    }

    private func startTransition(from oldIndex: Int, to newIndex: Int) {
        guard oldIndex != newIndex else { return }
        guard oldIndex >= 0, oldIndex < leaves.count else { return }
        guard newIndex >= 0, newIndex < leaves.count else { return }

        let rangeStart = min(oldIndex, newIndex)
        let rangeEnd = max(oldIndex, newIndex)

        var snapshots: [Int: NSImage] = [:]
        for i in rangeStart...rangeEnd where i != newIndex {
            if i < leaves.count {
                snapshots[i] = leaves[i].asImage
            }
        }
        transitionSnapshots = snapshots

        animatingFrom = oldIndex
        animationOffset = -CGFloat(oldIndex - rangeStart)

        let duration = state.animationDuration(from: oldIndex, to: newIndex)

        withAnimation(.easeInOut(duration: duration)) {
            animationOffset = -CGFloat(newIndex - rangeStart)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            animatingFrom = nil
            animationOffset = 0
            transitionSnapshots = [:]
        }
    }
}
