import SwiftUI
import GhosttyKit

struct HeroModeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    @ObservedObject var state: HeroModeState

    @State private var keyMonitor: Any? = nil
    @State private var scrollMonitor: Any? = nil
    @State private var carouselFrame: CGRect = .zero

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
                .background(GeometryReader { carouselGeo in
                    Color.clear.preference(
                        key: CarouselFrameKey.self,
                        value: carouselGeo.frame(in: .global)
                    )
                })
            }
        }
        .onPreferenceChange(CarouselFrameKey.self) { carouselFrame = $0 }
        .onAppear { installMonitors(leafCount: leaves.count) }
        .onDisappear { removeMonitors() }
        .onChange(of: state.isActive) { newValue in
            if newValue {
                installMonitors(leafCount: leaves.count)
            } else {
                removeMonitors()
            }
        }
    }

    private let dividerWidth: CGFloat = 6

    private func installMonitors(leafCount: Int) {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard state.isActive else { return event }
                let leaves = tree.root?.leaves() ?? []
                guard leaves.count > 1 else { return event }

                let hasShiftCmd = event.modifierFlags.contains([.shift, .command])
                if hasShiftCmd && event.keyCode == 126 { // Up arrow
                    state.selectPrevious(leafCount: leaves.count)
                    return nil
                } else if hasShiftCmd && event.keyCode == 125 { // Down arrow
                    state.selectNext(leafCount: leaves.count)
                    return nil
                }
                return event
            }
        }

        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard state.isActive else { return event }
                guard let window = event.window else { return event }

                let windowPoint = event.locationInWindow
                let screenPoint = window.convertPoint(toScreen: windowPoint)

                if isPointInCarousel(screenPoint) {
                    let leaves = tree.root?.leaves() ?? []
                    let heroAR = carouselFrame.width > 0 ? (carouselFrame.width * 0.88) : 1.0
                    let gap: CGFloat = 8
                    let totalHeight = CGFloat(leaves.count) * (heroAR + gap)
                    let maxScroll = max(totalHeight, carouselFrame.height) * 0.8

                    state.scrollOffset += event.scrollingDeltaY
                    state.scrollOffset = max(-maxScroll, min(maxScroll, state.scrollOffset))
                    return nil
                }
                return event
            }
        }
    }

    private func isPointInCarousel(_ screenPoint: CGPoint) -> Bool {
        guard carouselFrame.width > 0 else { return false }
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        guard let screenHeight = mainScreen?.frame.height else { return false }
        let flippedY = screenHeight - screenPoint.y
        let flippedPoint = CGPoint(x: screenPoint.x, y: flippedY)
        return carouselFrame.contains(flippedPoint)
    }

    private func removeMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
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
