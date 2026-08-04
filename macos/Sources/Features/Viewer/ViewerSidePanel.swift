import AppKit
import SwiftUI

/// The card in a viewer pane's left gutter.
///
/// One pane, two contents: a markdown document gets its table of contents, a
/// diff gets its file tree. They are deliberately the SAME component rather
/// than two that look alike — the card chrome, the row metrics, the selection
/// colors, the pinned header, the gutter/overlay switch, and the drag-to-resize
/// handle all live here or in `ViewerView`, so the two panels cannot drift
/// apart the way a copied lookalike would.
struct ViewerSidePanel: View {
    @ObservedObject var viewerView: ViewerView

    /// Card width, and the height it may grow to before its list scrolls.
    let width: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        Group {
            if viewerView.isDiffMode {
                ViewerDiffPanel(viewerView: viewerView, width: width, maxHeight: maxHeight)
            } else {
                ViewerTOCPanel(viewerView: viewerView, width: width, maxHeight: maxHeight)
            }
        }
    }
}

/// The card's own chrome: shape, glass, opaque base, size, and outer margin.
///
/// Applied identically by both panels, so "the file tree looks like the table
/// of contents" is a fact about the code rather than a thing to keep checking.
struct SidePanelCard: ViewModifier {
    let width: CGFloat
    let maxHeight: CGFloat
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12))
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: maxHeight, alignment: .top)
            // Clip the CONTENT to the card's shape before the card's own
            // layers go on: the list runs edge to edge, and un-clipped it
            // would square off the rounded corners it scrolls into.
            .clipShape(GlassCard.shape)
            .modifier(GlassCardBackground(
                fill: GlassCard.fill(isLightBackground: colorScheme == .light)))
            // An OPAQUE base under the glass layers. In the narrow layout this
            // card floats over the document, and a translucent panel let body
            // text show through it — unreadable. The wash above still lifts the
            // card a shade off the page, so it reads as raised rather than flat.
            .background(GlassCard.shape.fill(
                SidePanelCard.documentBackground(for: colorScheme)))
            .padding(GlassCard.outerMargin)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
    }

    /// The page's own background, kept in step with viewer.css so the card's
    /// opaque base is the same color as the document it sits on.
    static func documentBackground(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 1, green: 1, blue: 1)
            : Color(red: 13.0 / 255, green: 17.0 / 255, blue: 23.0 / 255)
    }
}

/// The pinned title bar, on the platform's own Liquid Glass.
///
/// This is the one backdrop that does what a native sidebar header does: a row
/// passing beneath stays a recognizable shape without turning into an
/// unreadable smear. The older recipes each failed at one end —
/// `NSVisualEffectView`/`Material` blur at a single fixed radius sized for a
/// window-wide surface (a row under it dissolved into one flat band), while a
/// plain translucent tint left the row perfectly legible and wasn't glass at
/// all. Neither radius is adjustable: Core Image's `backgroundFilters` — the
/// one API that takes a radius — does nothing inside a hosting view (see the
/// note in GlassCard.swift).
///
/// Tinted with the card's own base color so the bar stays part of the card.
/// Untinted, the glass takes the color of whatever is passing behind it — a
/// selected row turned the whole header accent-blue on its way past.
struct SidePanelHeader<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .glassBackdrop(
                tint: SidePanelCard.documentBackground(for: colorScheme).opacity(0.3))
    }
}

/// A header's caption, at the banner's secondary label scale. Shared so the
/// "CONTENTS" and "FILES" titles are the same typography, not two guesses at it.
struct SidePanelCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.6)
            .lineLimit(1)
    }
}

/// Row metrics and selection colors, taken off a macOS sidebar rather than
/// invented: the selection fill insets from the card's edges, the label insets
/// again inside the fill, and the row is tall enough that the fill reads as a
/// pill around the label instead of a stripe behind it. A sidebar row is
/// roughly twice its text size tall — cramming the fill against the text is the
/// single thing that makes a hand-rolled list look non-native.
enum SidePanelRow {
    static let fillInset: CGFloat = 8
    static let textInset: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    /// A macOS sidebar row is a rounded pill, not a bar: measured off System
    /// Settings it is ~6pt at this row height.
    static let cornerRadius: CGFloat = 6
    /// One indent step. The TOC uses it per heading level, the file tree per
    /// directory level.
    static let indentStep: CGFloat = 11

    /// Where a row's LABEL sits, measured from the card's edge. The header
    /// aligns to this, not to the card's own inner padding — in a sidebar the
    /// section header lines up with the row text, and the selection fill is
    /// what extends past it.
    static var labelInset: CGFloat { fillInset + textInset }

    /// The selected row's background.
    ///
    /// AppKit draws a selected sidebar row two ways, and both are on screen
    /// constantly, so the card has to do both: in the KEY window the fill is
    /// the accent-colored `selectedContentBackgroundColor` with white
    /// (`alternateSelectedControlTextColor`) label text; everywhere else it
    /// drops to the neutral `unemphasizedSelectedContentBackgroundColor` with
    /// the ordinary label color. Hard-coding either one is what makes a
    /// hand-rolled list read as "not quite a macOS list" — the row either stays
    /// lit in a background window or never lights up at all.
    ///
    /// Both are system colors rather than approximations, so they follow the
    /// user's accent color, Increase Contrast, and light/dark for free.
    @ViewBuilder
    static func fill(isActive: Bool, isHovered: Bool, isEmphasized: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if isActive {
            shape.fill(Color(nsColor: isEmphasized
                ? .selectedContentBackgroundColor
                : .unemphasizedSelectedContentBackgroundColor))
        } else if isHovered {
            shape.fill(Color.primary.opacity(0.06))
        } else {
            shape.fill(Color.clear)
        }
    }

    /// Label color for a row. Only the emphasized (accent) fill needs its own
    /// text color — white on the accent, whatever the accent is. The
    /// unemphasized fill is a light wash that the ordinary label color reads on
    /// unchanged, which is exactly why AppKit swaps the fill and not the text
    /// there.
    static func foreground(isActive: Bool, isEmphasized: Bool) -> AnyShapeStyle {
        guard isActive else { return AnyShapeStyle(.secondary) }
        return isEmphasized
            ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
            : AnyShapeStyle(Color(nsColor: .labelColor))
    }
}

/// The drag target that resizes the side-panel card, straddling its right edge.
///
/// An AppKit view rather than a SwiftUI gesture for the same reason the split
/// divider is one: the card's hosting view and the web view beside it are both
/// AppKit, and they out-hit-test a SwiftUI gesture area — a SwiftUI handle here
/// would be a target that only sometimes responds.
final class SidePanelResizeHandle: NSView {
    /// Total grab width, centered on the card's edge — about 3pt of slop on
    /// each side of a 1pt rim.
    static let grabWidth: CGFloat = 7

    /// Called continuously while dragging with (dx since mouse-down, the card
    /// width when the drag started), so the caller derives an absolute width
    /// and the card can't drift from accumulated deltas.
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    /// Reads the card's current width at mouse-down.
    var widthAtDragStart: (() -> CGFloat)?
    /// Called on mouse-up, when the chosen width is worth persisting.
    var onDragEnded: (() -> Void)?

    private var mouseDownX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        // The handle moves with the card's edge; its cursor rect has to move
        // with it or the resize cursor is left behind at the old width.
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownX = event.locationInWindow.x
        startWidth = widthAtDragStart?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x - mouseDownX, startWidth)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
