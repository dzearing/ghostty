import SwiftUI

/// The AppKit grab handle for a split divider. The panes host AppKit views
/// (terminal surfaces, WKWebViews) that win hit-testing over any SwiftUI
/// gesture area, so the drag target must itself be an NSView layered above
/// them. Placed by SplitView over the divider line, spanning the visible
/// line plus a few points of grab zone on each side.
struct DividerHandle: NSViewRepresentable {
    let direction: SplitViewDirection
    /// Called during a drag with (cumulative delta in points, split at drag start).
    let onDragDelta: (CGFloat, CGFloat) -> Void
    let onDoubleClick: () -> Void
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
        view.onDragDelta = onDragDelta
        view.onDoubleClick = onDoubleClick
        view.currentSplit = currentSplit
    }

    final class DividerHandleView: NSView {
        var direction: SplitViewDirection = .horizontal
        var onDragDelta: ((CGFloat, CGFloat) -> Void)?
        var onDoubleClick: (() -> Void)?
        var currentSplit: (() -> CGFloat)?

        private var dragOrigin: CGPoint?
        private var dragStartSplit: CGFloat = 0.5

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                dragOrigin = nil
                onDoubleClick?()
                return
            }
            dragOrigin = event.locationInWindow
            dragStartSplit = currentSplit?() ?? 0.5
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
            dragOrigin = nil
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
        @Binding var split: CGFloat

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
                    split = min(split + adjustment, 0.9)
                case .decrement:
                    split = max(split - adjustment, 0.1)
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
