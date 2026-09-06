import SwiftUI

/// The AppKit grab handle for a split divider. The panes host AppKit views
/// (terminal surfaces, WKWebViews) that win hit-testing over any SwiftUI
/// gesture area, so the drag target must itself be an NSView layered above
/// them. Placed by SplitView over the divider line, spanning the visible
/// line plus a few points of grab zone on each side.
struct DividerHandle: NSViewRepresentable {
    let direction: SplitViewDirection
    /// Called on mouse-down, before the divider has moved at all.
    let onDragBegan: () -> Void
    /// Called during a drag with (cumulative delta in points, split at drag start).
    let onDragDelta: (CGFloat, CGFloat) -> Void
    /// Called when a drag finishes. Not called for a double-click.
    let onDragEnded: () -> Void
    /// Called on a double-click. When nil a double-click is treated as an
    /// ordinary drag, which is what a divider with nothing to reset to wants.
    let onDoubleClick: (() -> Void)?
    /// Called when the pointer enters or leaves the grab zone, for dividers that
    /// highlight on hover. The handle owns the cursor (see `resetCursorRects`),
    /// so it is also the honest source of "is the pointer on the target".
    var onHoverChanged: ((Bool) -> Void)? = nil
    /// Reads the current split fraction (captured at mouse-down).
    let currentSplit: () -> CGFloat

    func makeNSView(context: Context) -> DividerHandleView {
        let view = DividerHandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DividerHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DividerHandleView) {
        view.direction = direction
        view.onDragBegan = onDragBegan
        view.onDragDelta = onDragDelta
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
        view.onHoverChanged = onHoverChanged
        view.currentSplit = currentSplit
    }

    final class DividerHandleView: NSView {
        var direction: SplitViewDirection = .horizontal
        var onDragBegan: (() -> Void)?
        var onDragDelta: ((CGFloat, CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        var currentSplit: (() -> CGFloat)?

        private var dragOrigin: CGPoint?
        private var dragStartSplit: CGFloat = 0.5

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil))
        }

        required init?(coder: NSCoder) { fatalError() }

        override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
        override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                dragOrigin = nil
                onDoubleClick()
                return
            }
            dragOrigin = event.locationInWindow
            dragStartSplit = currentSplit?() ?? 0.5
            onDragBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            let location = event.locationInWindow
            // Window coordinates are y-up; a downward drag grows a vertical
            // split's top pane, so flip the vertical delta.
            let delta: CGFloat = switch direction {
            case .horizontal: location.x - dragOrigin.x
            case .vertical: dragOrigin.y - location.y
            }
            onDragDelta?(delta, dragStartSplit)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragOrigin != nil else { return }
            dragOrigin = nil
            onDragEnded?()
        }

        override func resetCursorRects() {
            addCursorRect(
                bounds,
                cursor: direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }
}

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    struct Divider: View {
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        let split: CGFloat
        /// Called with the divider's new fractional position when it is adjusted
        /// from the keyboard via accessibility.
        let onAdjust: (CGFloat) -> Void

        private var visibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize
            case .vertical:
                return nil
            }
        }

        private var visibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize
            }
        }

        private var invisibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize + invisibleSize
            case .vertical:
                return nil
            }
        }

        private var invisibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize + invisibleSize
            }
        }

        private var pointerStyle: BackportPointerStyle {
            return switch direction {
            case .horizontal: .resizeLeftRight
            case .vertical: .resizeUpDown
            }
        }

        var body: some View {
            ZStack {
                Color.clear
                    .frame(width: invisibleWidth, height: invisibleHeight)
                    .contentShape(Rectangle()) // Makes it hit testable for pointerStyle
                Rectangle()
                    .fill(color)
                    .frame(width: visibleWidth, height: visibleHeight)
            }
            .backport.pointerStyle(pointerStyle)
            .onHover { isHovered in
                // macOS 15+ we use the pointerStyle helper which is much less
                // error-prone versus manual NSCursor push/pop
                if #available(macOS 15, *) {
                    return
                }

                if isHovered {
                    switch direction {
                    case .horizontal:
                        NSCursor.resizeLeftRight.push()
                    case .vertical:
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue("\(Int(split * 100))%")
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = 0.025
                switch direction {
                case .increment:
                    onAdjust(min(split + adjustment, 0.9))
                case .decrement:
                    onAdjust(max(split - adjustment, 0.1))
                @unknown default:
                    break
                }
            }
        }

        private var axLabel: String {
            switch direction {
            case .horizontal:
                return "Horizontal split divider"
            case .vertical:
                return "Vertical split divider"
            }
        }

        private var axHint: String {
            switch direction {
            case .horizontal:
                return "Drag to resize the left and right panes"
            case .vertical:
                return "Drag to resize the top and bottom panes"
            }
        }
    }
}
