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
/// One of the two side-panel contents (the other is the diff file tree); the
/// card chrome, row metrics, and selection colors come from `ViewerSidePanel`
/// so the two are the same component rather than two lookalikes. In a wide
/// pane this sits in a left gutter (the web view is inset beside it); in a
/// narrow one it slides over the content from the toggle button.
struct ViewerTOCPanel: View {
    @ObservedObject var viewerView: ViewerView

    let width: CGFloat
    let maxHeight: CGFloat

    /// Whether this card's window is the key window. AppKit draws a selected
    /// row two different ways depending on it (see `SidePanelRow.fill`), so
    /// the card has to know.
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hoveredID: String?

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
            .modifier(SidePanelCard(
                width: width, maxHeight: maxHeight,
                accessibilityLabel: "Table of contents"))
    }

    private var header: some View {
        SidePanelHeader {
            SidePanelCaption(text: "Contents")
                .padding(.horizontal, SidePanelRow.labelInset)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                // again inside them (see `SidePanelRow.fillInset`). The
                // header's own height is NOT added here — the safe area inset
                // supplies it.
                .padding(.horizontal, SidePanelRow.fillInset)
                .padding(.vertical, SidePanelRow.fillInset)
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
                .foregroundStyle(SidePanelRow.foreground(
                    isActive: isActive, isEmphasized: isEmphasized))
                .font(.system(size: 12))
                .padding(.vertical, SidePanelRow.verticalPadding)
                .padding(
                    .leading,
                    SidePanelRow.textInset + CGFloat(item.depth) * SidePanelRow.indentStep)
                .padding(.trailing, SidePanelRow.textInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SidePanelRow.fill(
                    isActive: isActive, isHovered: isHovered, isEmphasized: isEmphasized))
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
}
