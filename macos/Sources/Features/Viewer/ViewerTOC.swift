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
    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            list
        }
        .font(.system(size: 12))
        .padding(GlassCard.innerPadding)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: maxHeight, alignment: .top)
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

    /// Matches the banner's secondary label scale (10pt semibold, muted).
    private var header: some View {
        Text("Contents")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.6)
    }

    /// The markdown page's own background, kept in step with viewer.css so
    /// the card's opaque base is the same color as the document it sits on.
    private static func documentBackground(for scheme: ColorScheme) -> Color {
        scheme == .light
            ? Color(red: 1, green: 1, blue: 1)
            : Color(red: 13.0 / 255, green: 17.0 / 255, blue: 23.0 / 255)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(viewerView.tocItems) { item in
                        row(item)
                    }
                }
                // The rows' hover/active fills extend past the card's inner
                // padding so their TEXT still lands on the 12pt padding line.
                .padding(.horizontal, -rowInset)
            }
            .onChange(of: viewerView.activeHeadingID) { id in
                guard let id else { return }
                // No anchor: scroll the minimum needed to reveal the row, so
                // a long TOC doesn't jump around while the user reads.
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
            }
        }
    }

    /// Horizontal inset of a row's fill from the card's content edge.
    private var rowInset: CGFloat { 6 }

    private func row(_ item: ViewerTOCItem) -> some View {
        let isActive = item.id == viewerView.activeHeadingID
        let isHovered = item.id == hoveredID
        return Button(action: { viewerView.scrollToHeading(id: item.id) }) {
            Text(item.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .padding(.vertical, 4)
                .padding(.leading, rowInset + CGFloat(item.depth) * 11)
                .padding(.trailing, rowInset)
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

    @ViewBuilder
    private func rowFill(isActive: Bool, isHovered: Bool) -> some View {
        let opacity: Double = isActive ? 0.08 : (isHovered ? 0.06 : 0)
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(opacity))
    }
}
