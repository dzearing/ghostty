import AppKit
import SwiftUI

/// One heading in a viewer pane's table of contents.
///
/// Extracted from the rendered markdown by the page (viewer.js) and handed
/// over the `viewerTOC` script-message bridge. The page reports the raw
/// heading level; `depth` is derived here, relative to the document's own
/// top-most level, so a file whose headings start at `##` is not indented a
/// step for no reason.
struct ViewerTOCItem: Identifiable, Equatable {
    /// The heading element's anchor id, used to scroll the page to it.
    let id: String
    let text: String
    let level: Int
    /// Indent steps from the document's top heading level, capped so a deeply
    /// nested section still fits the card.
    let depth: Int

    static let maxDepth = 3

    /// Build the display list, deriving depth from the shallowest heading.
    static func list(from raw: [(id: String, text: String, level: Int)]) -> [ViewerTOCItem] {
        guard let topLevel = raw.map(\.level).min() else { return [] }
        return raw.map { entry in
            ViewerTOCItem(
                id: entry.id,
                text: entry.text,
                level: entry.level,
                depth: min(maxDepth, max(0, entry.level - topLevel)))
        }
    }
}

/// The table-of-contents card for a viewer pane.
///
/// Renders as the same floating glass card as the sticky pane banner — it
/// uses `GlassCardBackground` directly rather than approximating it, so the
/// two surfaces cannot drift apart. In a wide pane this sits in a left gutter
/// (the web view is inset beside it); in a narrow one it slides over the
/// content from the toggle button.
struct ViewerTOCPanel: View {
    @ObservedObject var viewerView: ViewerView

    /// Card width, and the height it may grow to before the list scrolls.
    let width: CGFloat
    let maxHeight: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    /// Whether this card's window is the key window. AppKit draws a selected
    /// row two different ways depending on it (see `rowFill`), so the card has
    /// to know.
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hoveredID: String?

    /// Row metrics, taken off a macOS sidebar rather than invented: the
    /// selection fill insets from the card's edges, the label insets again
    /// inside the fill, and the row is tall enough that the fill reads as a
    /// pill around the label instead of a stripe behind it. A sidebar row is
    /// roughly twice its text size tall — cramming the fill against the text
    /// is the single thing that makes a hand-rolled list look non-native.
    private static let rowFillInset: CGFloat = 8
    private static let rowTextInset: CGFloat = 10
    private static let rowVerticalPadding: CGFloat = 7

    /// Where a row's LABEL sits, measured from the card's edge. The header
    /// aligns to this, not to the card's own inner padding — in a sidebar the
    /// section header lines up with the row text, and the selection fill is
    /// what extends past it.
    private static var labelInset: CGFloat { rowFillInset + rowTextInset }

    var body: some View {
        // The list is the full card and the header is a SAFE AREA INSET on
        // top of it — the same arrangement a native sidebar uses. That single
        // modifier buys all three behaviors: rows scroll *under* the header
        // and blur through it, the resting content starts below it, and the
        // scroller's track stops at its bottom edge instead of running up
        // behind the glass and being clipped in half. A plain ZStack gets the
        // first, silently loses the third.
        list
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .font(.system(size: 12))
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: maxHeight, alignment: .top)
        // Clip the CONTENT to the card's shape before the card's own layers
        // go on: the list runs edge to edge now, and un-clipped it would
        // square off the rounded corners it scrolls into.
        .clipShape(GlassCard.shape)
        .modifier(GlassCardBackground(
            fill: GlassCard.fill(isLightBackground: colorScheme == .light)))
        // An OPAQUE base under the glass layers. In the narrow layout this
        // card floats over the document, and a translucent panel let body
        // text show through it — unreadable. The wash above still lifts the
        // card a shade off the page, so it reads as raised rather than flat.
        .background(GlassCard.shape.fill(Self.documentBackground(for: colorScheme)))
        .padding(GlassCard.outerMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table of contents")
    }

    /// The pinned title bar. Matches the banner's secondary label scale (10pt
    /// semibold, muted) over the platform's own header backdrop, so rows
    /// passing beneath it stay recognizable through the glass — the way they
    /// do under a native sidebar header — instead of sliding out from behind
    /// a solid block.
    ///
    /// The pinned title bar, on the platform's own Liquid Glass.
    ///
    /// This is the one backdrop that does what a native sidebar header does:
    /// a row passing beneath stays a recognizable shape without turning into
    /// an unreadable smear. The older recipes each failed at one end —
    /// `NSVisualEffectView`/`Material` blur at a single fixed radius sized for
    /// a window-wide surface (a row under it dissolved into one flat band),
    /// while a plain translucent tint left the row perfectly legible and
    /// wasn't glass at all. Neither radius is adjustable: Core Image's
    /// `backgroundFilters` — the one API that takes a radius — does nothing
    /// inside a hosting view (see the note in GlassCard.swift).
    private var header: some View {
        headerLabel
            // Tinted with the card's own base color so the bar stays part of
            // the card. Untinted, the glass takes the color of whatever is
            // passing behind it — a selected row turned the whole header
            // accent-blue on its way past.
            .glassBackdrop(tint: Self.documentBackground(for: colorScheme).opacity(0.3))
    }

    private var headerLabel: some View {
        Text("Contents")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.6)
            .padding(.horizontal, Self.labelInset)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The markdown page's own background, kept in step with viewer.css so
    /// the card's opaque base is the same color as the document it sits on.
    private static func documentBackground(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 1, green: 1, blue: 1)
            : Color(red: 13.0 / 255, green: 17.0 / 255, blue: 23.0 / 255)
    }

    /// The scrolling heading list.
    ///
    /// Indicators are ON: a long document's TOC overflows the card, and a
    /// list you can scroll with no scroller is a list that looks complete
    /// when it isn't. macOS overlay scrollers fade in on scroll (or stay, per
    /// the user's "Show scroll bars" setting) — the native behavior.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(viewerView.tocItems) { item in
                        row(item)
                    }
                }
                // The fills inset from the card's edges; the row text insets
                // again inside them (see `rowFillInset`). The header's own
                // height is NOT added here — the safe area inset supplies it.
                .padding(.horizontal, Self.rowFillInset)
                .padding(.vertical, Self.rowFillInset)
            }
            .onChange(of: viewerView.activeHeadingID) { id in
                guard let id else { return }
                // No anchor: scroll the minimum needed to reveal the row, so
                // a long TOC doesn't jump around while the user reads.
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ item: ViewerTOCItem) -> some View {
        let isActive = item.id == viewerView.activeHeadingID
        let isHovered = item.id == hoveredID
        return Button(action: { viewerView.scrollToHeading(id: item.id) }) {
            Text(item.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // Selection is carried by the FILL, not by the weight: the
                // label keeps its regular weight so a row's metrics don't
                // shift as the reader scrolls past it.
                .foregroundStyle(rowForeground(isActive: isActive))
                .font(.system(size: 12))
                .padding(.vertical, Self.rowVerticalPadding)
                .padding(.leading, Self.rowTextInset + CGFloat(item.depth) * 11)
                .padding(.trailing, Self.rowTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowFill(isActive: isActive, isHovered: isHovered))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
        }
        .id(item.id)
        .help(item.text)
    }

    /// True when this card's window is the key window.
    ///
    /// `.key` is the only state AppKit calls emphasized; `.active` means the
    /// app is frontmost but some other window is key, and it draws the
    /// unemphasized selection there too.
    private var isEmphasized: Bool { controlActiveState == .key }

    /// The selected row's background.
    ///
    /// AppKit draws a selected sidebar row two ways, and both are on screen
    /// constantly, so the card has to do both: in the KEY window the fill is
    /// the accent-colored `selectedContentBackgroundColor` with white
    /// (`alternateSelectedControlTextColor`) label text; everywhere else it
    /// drops to the neutral `unemphasizedSelectedContentBackgroundColor` with
    /// the ordinary label color. Hard-coding either one is what makes a
    /// hand-rolled list read as "not quite a macOS list" — the row either
    /// stays lit in a background window or never lights up at all.
    ///
    /// Both are system colors rather than approximations, so they follow the
    /// user's accent color, Increase Contrast, and light/dark for free.
    @ViewBuilder
    private func rowFill(isActive: Bool, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.rowCornerRadius, style: .continuous)
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
    /// unemphasized fill is a light wash that the ordinary label color reads
    /// on unchanged, which is exactly why AppKit swaps the fill and not the
    /// text there.
    private func rowForeground(isActive: Bool) -> AnyShapeStyle {
        guard isActive else { return AnyShapeStyle(.secondary) }
        return isEmphasized
            ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
            : AnyShapeStyle(Color(nsColor: .labelColor))
    }

    /// Corner radius of a row's selection fill. A macOS sidebar row is a
    /// rounded pill, not a bar: measured off System Settings it is ~6pt at
    /// this row height.
    private static let rowCornerRadius: CGFloat = 6
}

/// The drag target that resizes the TOC card, straddling its right edge.
///
/// An AppKit view rather than a SwiftUI gesture for the same reason the split
/// divider is one: the card's hosting view and the web view beside it are both
/// AppKit, and they out-hit-test a SwiftUI gesture area — a SwiftUI handle
/// here would be a target that only sometimes responds.
final class TOCResizeHandle: NSView {
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
