import SwiftUI
import GhosttyKit

class HeroModeState: ObservableObject {
    enum Direction { case up, down }

    @Published var isActive: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var carouselRatio: CGFloat = 0.25
    @Published var scrollOffset: CGFloat = 0
    var lastDirection: Direction = .down

    private static let minCarouselRatio: CGFloat = 0.1
    private static let maxCarouselRatio: CGFloat = 0.6

    func activate(focusedIndex: Int, leafCount: Int) {
        guard leafCount > 1 else { return }
        selectedIndex = clampIndex(focusedIndex, leafCount: leafCount)
        scrollOffset = 0
        isActive = true
    }

    func deactivate() {
        isActive = false
        scrollOffset = 0
    }

    func select(_ index: Int, leafCount: Int) {
        let clamped = clampIndex(index, leafCount: leafCount)
        guard clamped != selectedIndex else { return }
        lastDirection = clamped > selectedIndex ? .down : .up
        selectedIndex = clamped
        scrollOffset = 0
    }

    func selectNext(leafCount: Int) {
        select(selectedIndex + 1, leafCount: leafCount)
    }

    func selectPrevious(leafCount: Int) {
        select(selectedIndex - 1, leafCount: leafCount)
    }

    func clampCarouselRatio() {
        carouselRatio = min(Self.maxCarouselRatio, max(Self.minCarouselRatio, carouselRatio))
    }

    func clampIndex(_ leafCount: Int) {
        selectedIndex = clampIndex(selectedIndex, leafCount: leafCount)
    }

    private func clampIndex(_ index: Int, leafCount: Int) -> Int {
        guard leafCount > 0 else { return 0 }
        return max(0, min(leafCount - 1, index))
    }

    func animationDuration(from oldIndex: Int, to newIndex: Int) -> Double {
        let distance = abs(newIndex - oldIndex)
        if distance <= 1 { return 0.3 }
        return 0.3 + 0.1 * log2(Double(distance))
    }
}
