import SwiftUI
#if canImport(AppKit)
import AppKit
private typealias OSFont = NSFont
#elseif canImport(UIKit)
import UIKit
private typealias OSFont = UIFont
#endif

extension Ghostty {
    /// Sticky banner rendered above the terminal content of a pane. Set via
    /// `ghoztty +set-banner` IPC or the OSC 7778 escape sequence; persists
    /// (survives scrolling and screen clears) until changed or cleared.
    struct SurfacePaneBanner: View {
        /// Raw banner source text in the banner markdown subset.
        let text: String

        /// The pane's terminal background color, when known. The banner
        /// renders as a shade off of it — lighter on dark backgrounds,
        /// darker on light — so it reads as a distinct sticky region.
        var background: Color?

        /// The hosting pane's current width, passed top-down (from a
        /// `GeometryReader` at the overlay level). Table column sizing derives
        /// from this so the banner always reflows to the pane and can never
        /// establish its own minimum width: measuring the banner's *content*
        /// width instead (as a preference fed back into state) deadlocks the
        /// moment the content overflows — the content is as wide as the
        /// columns, the columns are as wide as the measurement, and the pane
        /// can no longer shrink past it. 0 means "not yet known".
        var paneWidth: CGFloat = 0

        /// Total display cap in lines. Table rows (including the header)
        /// each count as one line; the separator row never renders.
        static let maxDisplayLines = 10

        /// Maximum wrapped display lines for a single table cell. A cell that
        /// would wrap past this (e.g. a long unbroken token in a very narrow
        /// pane) is tail-truncated with an ellipsis instead of growing the row
        /// unbounded. Counts *within* one table row — the row still counts
        /// once toward `maxDisplayLines`.
        static let maxCellWrapLines = 3

        /// Corner radius of the floating banner card.
        private static let cornerRadius = GlassCard.cornerRadius

        /// Uniform inner padding of the card. Equal on all sides so the
        /// collapsed card — which shows only the title row — is vertically
        /// centered around a title that hasn't moved from its expanded spot.
        private static let innerPadding = GlassCard.innerPadding

        /// Margin between the card and the pane edges (the card floats,
        /// Liquid Glass style, instead of running edge to edge). Sized so the
        /// card's elevation shadow has room to render instead of being cut at
        /// the pane edge. The bottom margin is part of the banner's measured
        /// height, so the terminal content below always starts a breath under
        /// the card — content is never hidden behind it.
        private static let outerMargin = GlassCard.outerMargin

        /// Fallback per-column cap used ONLY before the pane's real width is
        /// known (`paneWidth == 0`, e.g. the harness/preview case). Once the
        /// width is known, columns size to the available space instead (see
        /// `columnWidths(natural:available:)`), so a row uses the full pane
        /// width before wrapping rather than wrapping at this fixed bound
        /// with the pane half-empty.
        private static let maxCellWidth: CGFloat = 360

        /// Collapsed state is per-pane and ephemeral; it resets when the
        /// banner is cleared and set again.
        @State private var collapsed: Bool

        init(
            text: String,
            background: Color? = nil,
            paneWidth: CGFloat = 0,
            initiallyCollapsed: Bool = false
        ) {
            self.text = text
            self.background = background
            self.paneWidth = paneWidth
            self._collapsed = State(initialValue: initiallyCollapsed)
        }

        var body: some View {
            // Parsed blocks and measured natural column widths come from a
            // text-keyed cache: during a live divider drag this body runs
            // every frame, and neither parsing nor text measurement belongs
            // on that path — only the O(columns) fair-share division below
            // depends on the width.
            let layout = BannerLayout.shared.layout(for: text)
            let blocks = layout.blocks

            // The pane width drives all wrapping. Subtract the card's outer
            // margins and inner padding to get the content's usable width.
            // Floor a known-but-tiny width at 1 (not 0) so downstream sizing
            // can tell "pane is absurdly narrow" (stay bounded) apart from
            // "width not known yet" (fall back to the fixed cap).
            let availableWidth = paneWidth > 0
                ? max(1, paneWidth - 2 * (Self.outerMargin + Self.innerPadding))
                : 0
            // The first block is the title row; everything after it is the
            // collapsible body. A banner with nothing after the title has
            // nothing to collapse: hide the chevron, ignore background clicks.
            let collapsible = blocks.count > 1

            // Width budget for table layout. The title row shares its line
            // with the chevron column; body blocks get the full width.
            let titleBudget = availableWidth > 0
                ? max(1, availableWidth - 8 - (collapsible ? 26 : 0))
                : 0
            let bodyBudget = availableWidth

            cardContent(
                layout: layout, collapsible: collapsible,
                titleBudget: titleBudget, bodyBudget: bodyBudget
            )
            .font(.system(size: 12))
            .padding(Self.innerPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(GlassCardBackground(fill: cardFill))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .onTapGesture {
                guard collapsible else { return }
                toggleCollapsed()
            }
            .padding(.horizontal, Self.outerMargin)
            .padding(.top, Self.outerMargin * 0.8)
            .padding(.bottom, Self.outerMargin)
            // A hidden, animation-free copy of the same content measures the
            // height the banner is headed for and publishes it as the banner's
            // target height. The host insets the terminal from this — one
            // exact step per toggle — while the visible card above animates
            // its resize, so the terminal never chases intermediate frames.
            .background(alignment: .top) {
                cardContent(
                    layout: layout, collapsible: collapsible,
                    titleBudget: titleBudget, bodyBudget: bodyBudget
                )
                .font(.system(size: 12))
                .frame(width: availableWidth > 0 ? availableWidth : nil, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .transaction { $0.animation = nil }
                .hidden()
                .allowsHitTesting(false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BannerTargetHeightKey.self,
                            value: proxy.size.height + Self.chromeHeight
                        )
                    }
                )
            }
        }

        /// Vertical chrome around the banner content: inner card padding plus
        /// the card's outer margins. Added to the measured content height to
        /// produce the banner's total (target) height.
        private static var chromeHeight: CGFloat {
            innerPadding * 2 + outerMargin * 0.8 + outerMargin
        }

        /// The card's inner content: the title row (first block + collapse
        /// chevron) with the body blocks below it.
        @ViewBuilder
        private func cardContent(
            layout: BannerLayout.Entry,
            collapsible: Bool,
            titleBudget: CGFloat,
            bodyBudget: CGFloat
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                // Title row. The chevron is center-aligned against the title
                // in both states — collapsing removes the body below this row
                // and nothing in the row itself moves.
                HStack(alignment: .center, spacing: 8) {
                    if let title = layout.blocks.first {
                        blockView(title, natural: layout.naturalWidths[0], budget: titleBudget)
                    }
                    Spacer(minLength: 0)
                    if collapsible {
                        Button(action: toggleCollapsed) {
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(collapsed ? "Expand banner" : "Collapse banner")
                    }
                }
                // Body blocks, with a paragraph-style gap between them (lines
                // within a text run stay tight since a run is a single Text).
                if !(collapsed && collapsible) {
                    ForEach(
                        Array(layout.blocks.dropFirst().enumerated()),
                        id: \.offset
                    ) { offset, block in
                        blockView(
                            block,
                            natural: layout.naturalWidths[offset + 1],
                            budget: bodyBudget)
                    }
                }
            }
        }

        /// Animate the card only: the resize interpolates and the body
        /// content cross-fades (the default insertion/removal transition) in
        /// parallel. The terminal inset below is deliberately NOT driven by
        /// the visible card's animated frame — it reads the hidden
        /// measurement copy's target height (see `body`), which ignores this
        /// animation, so the terminal reflows in one instant step instead of
        /// dragging the Metal surface through per-frame resizes.
        private func toggleCollapsed() {
            withAnimation(.easeInOut(duration: 0.18)) {
                collapsed.toggle()
            }
        }

        /// The card's fill: a translucent wash over whatever sits behind the
        /// card — white on a dark pane, black on a light one. Compositing
        /// white at 6% is exactly `lighten(by: 0.06)` of the color behind
        /// (black at 4% is `darken(by: 0.04)`), so the card reads as a shade
        /// off the pane background without ever holding a color of its own:
        /// when the pane color changes, only the single element behind the
        /// banner repaints and the card follows in the same paint pass. The
        /// known `background` is consulted only for the light/dark direction.
        /// Falls back to the translucent material when the background isn't
        /// known.
        private var cardFill: AnyShapeStyle {
            guard let background else { return GlassCard.materialFill }
            return GlassCard.fill(isLightBackground: OSColor(background).isLightColor)
        }

        // The card surface itself (fill wash, sheen, rim, elevation shadow) lives in
        // GlassCardBackground so the viewer pane's table of contents renders the exact
        // same card — see Helpers/GlassCard.swift.

        /// Render one block. `natural` carries the cached natural column
        /// widths when the block is a table (nil otherwise).
        @ViewBuilder
        private func blockView(
            _ block: BannerMarkdown.Block,
            natural: [CGFloat]?,
            budget: CGFloat
        ) -> some View {
            switch block {
            case .text(let str, let lineLimit):
                Text(str)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            case .list(let items):
                // A two-column grid: markers share the first (auto-sized)
                // column so every item's content left-aligns in the second,
                // with table-like row spacing.
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            listMarkerView(item.marker)
                                // Center every marker in the shared gutter so a
                                // bullet dot sits under the middle of a checkbox
                                // rather than at the column's left edge.
                                .gridColumnAlignment(.center)
                            inlineRow(item.content)
                        }
                    }
                }
                // A checkbox-led first row draws a filled box whose hard top
                // edge rises above where a text cap sits, so the 8pt block gap
                // reads tighter above a checklist than above a table or a
                // bullet/ordered list (whose first row leads with text and
                // already clears the preceding line). Nudge a checkbox-led list
                // down so its leading gap matches the paragraph→table gap. Only
                // the checkbox case needs it; text-led lists already have parity.
                .padding(.top, leadsWithCheckbox(items) ? 2 : 0)
            case .heading(let str, let level):
                Text(str)
                    .font(.system(size: headingFontSize(level), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            case .rule:
                // A full-width separator between blocks. The 8pt block gap
                // above and below gives it breathing room without extra padding.
                Divider()
            case .table(let table):
                let showHeader = table.hasVisibleHeader
                // Fixed per-column widths (sized to the available banner width)
                // let a long cell wrap at a known width while the Grid grows
                // each row to its wrapped height — a greedy `frame(maxWidth:)`
                // would collapse layout, and a rigid `fixedSize` cell overflows
                // its row instead of growing it.
                let widths = columnWidths(
                    natural: natural ?? BannerLayout.naturalColumnWidths(for: table),
                    available: budget)
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 4) {
                    if showHeader {
                        GridRow(alignment: .top) {
                            ForEach(Array(table.header.enumerated()), id: \.offset) { col, cell in
                                inlineRow(cell, width: widths[col], alignment: table.alignments[col])
                                    .bold()
                            }
                        }
                        // Unsized so the divider spans the header without
                        // stretching the grid to the full banner width.
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow(alignment: .top) {
                            ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                                inlineRow(cell, width: widths[col], alignment: table.alignments[col])
                            }
                        }
                    }
                }
            }
        }

        /// Lay out one row of inline content — a table cell or a task-list
        /// item — drawing each `.checkbox` segment as a native box (see
        /// `CheckboxMark`) and each `.text` segment as styled text. Source
        /// spaces provide the gaps, so a leading `[x] ` renders "☑ done" with
        /// the box vertically centered.
        ///
        /// List items pass no `width` and stay a single non-wrapping line. A
        /// table cell passes its column's fixed `width`: a plain cell collapses
        /// its inline runs into one `Text` that word-wraps at that width (the
        /// Grid then grows the row to the wrapped height, instead of clipping
        /// to one line with an ellipsis), while a checkbox-bearing cell stays a
        /// single line — mixed native boxes and text can't reflow across each
        /// other, and a checkbox cell is a short status marker, like a list
        /// checkbox row. `alignment` (from the column's `:` markers) drives the
        /// content's horizontal placement and multi-line text alignment.
        @ViewBuilder
        private func inlineRow(
            _ segments: [BannerMarkdown.Inline],
            width: CGFloat? = nil,
            alignment: BannerMarkdown.ColumnAlignment? = nil
        ) -> some View {
            let hasCheckbox = segments.contains {
                if case .checkbox = $0 { return true }
                return false
            }
            if let width, !hasCheckbox {
                Text(BannerMarkdown.attributed(segments))
                    .multilineTextAlignment(textAlignment(alignment))
                    // A nasty cell (long unbroken token in a skinny pane)
                    // can't grow the row unbounded: cap the wrap and
                    // ellipsize the last visible line.
                    .lineLimit(Self.maxCellWrapLines)
                    .truncationMode(.tail)
                    // Vertical-only fixed size: wrap at the fixed column width,
                    // take whatever height the wrapped text needs.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: frameAlignment(alignment))
            } else {
                let row = HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        switch seg {
                        case .text(let str):
                            Text(str).lineLimit(1)
                        case .checkbox(let checked):
                            CheckboxMark(checked: checked)
                        }
                    }
                }
                if let width {
                    row.frame(width: width, alignment: frameAlignment(alignment))
                } else {
                    row
                }
            }
        }

        /// Whether a list block's first row leads with a checkbox marker. Such
        /// a row draws a filled box whose top edge sits higher than a text cap,
        /// so it needs extra leading padding to match the paragraph→table gap
        /// (see the `.list` case). Bullet/ordered lists lead with text and don't.
        private func leadsWithCheckbox(_ items: [BannerMarkdown.ListItem]) -> Bool {
            if case .checkbox = items.first?.marker { return true }
            return false
        }

        /// The leading marker of a list row, drawn in the shared gutter column.
        @ViewBuilder
        private func listMarkerView(_ marker: BannerMarkdown.ListMarker) -> some View {
            switch marker {
            case .checkbox(let checked):
                CheckboxMark(checked: checked)
            case .bullet:
                // A drawn dot reads more evenly than the "•" glyph and sizes
                // predictably relative to the 12pt box.
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
            case .ordered(let number):
                Text(verbatim: "\(number).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }

        /// A gentle scale over the 12pt banner base: headings read as
        /// slightly larger, never oversized (h1 tops out at 17pt).
        private func headingFontSize(_ level: Int) -> CGFloat {
            switch level {
            case 1: return 17
            case 2: return 16
            case 3: return 15
            case 4: return 14
            case 5: return 13
            default: return 12
            }
        }

        /// The fixed width of each table column, divided from the cached
        /// natural widths and the current width budget. Pure arithmetic —
        /// this runs every frame during a divider drag, so no parsing or
        /// text measurement happens here (see `BannerLayout`). Widths are
        /// exact (not a flexible max) so the Grid stays as wide as its
        /// content and grows each row to the height its cells wrap to.
        ///
        /// Sizing policy, given the banner's `available` inner width:
        /// - If every column's natural (single-line) width fits within
        ///   `available`, each column gets its exact natural width and nothing
        ///   wraps — so a row uses the full pane width it needs, no more.
        /// - If the natural widths together exceed `available`, columns share
        ///   the space max-min fair: narrow columns (e.g. the `**Goal**` label)
        ///   keep their natural width, and wide columns split the remainder, so
        ///   each column wraps only at the width the pane can actually give it —
        ///   never at a fixed cap that leaves the pane half-empty.
        /// - Before the pane width is known (`available <= 0`), fall back to
        ///   the fixed `maxCellWidth` cap so the initial render is never
        ///   absurdly wide.
        private func columnWidths(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
            let columns = natural.count
            guard columns > 0 else { return [] }

            // Budget for cell content = available width minus the inter-column
            // spacing the Grid inserts (18pt between adjacent columns).
            let budget = available - 18 * CGFloat(max(0, columns - 1))

            // No room once inter-column spacing is paid: with a KNOWN pane
            // width, stay bounded (tiny equal shares — the pane is being
            // squeezed to nothing and must never be blocked from shrinking);
            // with an UNKNOWN width, fall back to the fixed cap.
            guard budget > 0 else {
                if available > 0 {
                    return [CGFloat](
                        repeating: max(1, available / CGFloat(columns)),
                        count: columns)
                }
                return natural.map { min($0, Self.maxCellWidth) }
            }

            // Everything fits on one line: exact natural widths, no wrapping.
            if natural.reduce(0, +) <= budget { return natural }

            // Overflow: max-min fair share. Process columns narrowest-first —
            // a column that fits its equal share of the remaining budget takes
            // its natural width and hands the slack to the wider columns still
            // to be sized; a column that doesn't fit takes its fair share and
            // wraps there.
            var result = [CGFloat](repeating: 0, count: columns)
            var remaining = budget
            var left = columns
            for col in (0..<columns).sorted(by: { natural[$0] < natural[$1] }) {
                let share = remaining / CGFloat(left)
                let w = min(natural[col], share)
                result[col] = w
                remaining -= w
                left -= 1
            }
            return result
        }

        /// How the wrapped lines of a table cell align to each other.
        private func textAlignment(
            _ alignment: BannerMarkdown.ColumnAlignment?
        ) -> TextAlignment {
            switch alignment {
            case .center: return .center
            case .trailing: return .trailing
            case .leading, nil: return .leading
            }
        }

        /// How a cell's content sits within its fixed column-width frame.
        private func frameAlignment(
            _ alignment: BannerMarkdown.ColumnAlignment?
        ) -> Alignment {
            switch alignment {
            case .center: return .center
            case .trailing: return .trailing
            case .leading, nil: return .leading
            }
        }

        /// Text-keyed cache of everything about a banner that does NOT depend
        /// on the pane width: the parsed blocks and each table's natural
        /// (unwrapped, measured) column widths. The view's body re-runs every
        /// frame while a split divider drags the pane width around; with this
        /// cache that hot path does zero parsing and zero text measurement —
        /// only the cheap fair-share division in `columnWidths(natural:available:)`
        /// and SwiftUI's own native text layout depend on the width.
        final class BannerLayout {
            static let shared = BannerLayout()

            final class Entry {
                let blocks: [BannerMarkdown.Block]
                /// Natural column widths for each `.table` block, keyed by the
                /// block's index in `blocks` (slack included).
                let naturalWidths: [Int: [CGFloat]]

                init(blocks: [BannerMarkdown.Block], naturalWidths: [Int: [CGFloat]]) {
                    self.blocks = blocks
                    self.naturalWidths = naturalWidths
                }
            }

            private let cache = NSCache<NSString, Entry>()

            private init() {
                // Banners are one-per-pane and small; a handful of entries
                // covers every live pane plus a little churn.
                cache.countLimit = 64
            }

            func layout(for text: String) -> Entry {
                let key = text as NSString
                if let entry = cache.object(forKey: key) { return entry }
                let blocks = BannerMarkdown.parseBlocks(
                    text, maxLines: SurfacePaneBanner.maxDisplayLines)
                var naturals: [Int: [CGFloat]] = [:]
                for (i, block) in blocks.enumerated() {
                    if case .table(let table) = block {
                        naturals[i] = Self.naturalColumnWidths(for: table)
                    }
                }
                let entry = Entry(blocks: blocks, naturalWidths: naturals)
                cache.setObject(entry, forKey: key)
                return entry
            }

            /// Measure a table's natural (single-line) column widths.
            ///
            /// Each run is measured at the weight/face it actually renders
            /// (bold runs at bold, code runs monospaced); measuring bold body
            /// text as regular under-sized the column and force-wrapped bold
            /// labels like `**Prompt**` mid-word. Header cells render bold, so
            /// they force bold.
            static func naturalColumnWidths(for table: BannerMarkdown.Table) -> [CGFloat] {
                let columns = table.header.count
                guard columns > 0 else { return [] }
                var natural = [CGFloat](repeating: 0, count: columns)
                if table.hasVisibleHeader {
                    for (col, cell) in table.header.enumerated() where col < columns {
                        natural[col] = max(natural[col], cellNaturalWidth(cell, forceBold: true))
                    }
                }
                for row in table.rows {
                    for (col, cell) in row.enumerated() where col < columns {
                        natural[col] = max(natural[col], cellNaturalWidth(cell, forceBold: false))
                    }
                }
                // A hair of slack absorbs sub-pixel measurement differences so
                // a cell that fits on one line isn't wrapped by rounding.
                return natural.map { $0 + 2 }
            }

            /// The unwrapped width a cell's inline content occupies: the
            /// measured width of its text runs plus a fixed box per checkbox.
            private static func cellNaturalWidth(
                _ segments: [BannerMarkdown.Inline], forceBold: Bool
            ) -> CGFloat {
                segments.reduce(0) { acc, seg in
                    switch seg {
                    case .text(let a):
                        return acc + attrWidth(a, forceBold: forceBold)
                    case .checkbox:
                        return acc + CheckboxMark.side
                    }
                }
            }

            /// Width of an attributed run sequence in the 12pt banner font,
            /// each run measured at the weight/face it renders. Matches
            /// SwiftUI's `.system(size: 12)`. `forceBold` measures every run
            /// bold (header row).
            private static func attrWidth(_ a: AttributedString, forceBold: Bool) -> CGFloat {
                var total: CGFloat = 0
                for run in a.runs {
                    let s = String(a[run.range].characters)
                    if s.isEmpty { continue }
                    total += ceil((s as NSString).size(withAttributes: [.font: runFont(run, forceBold: forceBold)]).width)
                }
                return total
            }

            /// The font a run renders in: bold for a strongly-emphasized run
            /// (or a force-bold header), monospaced for a code run. SwiftUI
            /// draws the bold presentation intent at full bold weight, so
            /// measure it there.
            private static func runFont(
                _ run: AttributedString.Runs.Run, forceBold: Bool
            ) -> OSFont {
                let intent = run.inlinePresentationIntent ?? []
                let bold = forceBold || intent.contains(.stronglyEmphasized)
                return intent.contains(.code)
                    ? OSFont.monospacedSystemFont(ofSize: 12, weight: bold ? .bold : .regular)
                    : OSFont.systemFont(ofSize: 12, weight: bold ? .bold : .regular)
            }
        }

        /// A task-list checkbox drawn as a small native control rather than a
        /// glyph: a rounded (2pt-radius) box with a thin border, filled with a
        /// tinted wash and a colored check when checked. Sized to sit inline
        /// with the 12pt banner text like a character.
        private struct CheckboxMark: View {
            let checked: Bool

            /// The banner renders inside a window whose appearance follows
            /// the pane background, so the environment scheme tracks pane
            /// lightness. System green reads well on dark washes but sits
            /// too close to a light one — use a deeper green there.
            @Environment(\.colorScheme) private var colorScheme

            // `side` is read by the table column-width measurement.
            static let side: CGFloat = 12
            private static let radius: CGFloat = 2

            private var green: Color {
                colorScheme == .light
                    ? Color(red: 0.11, green: 0.44, blue: 0.16)
                    : Color.green
            }

            var body: some View {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(checked ? green.opacity(0.16) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(
                                checked ? green.opacity(colorScheme == .light ? 0.7 : 0.55)
                                        : Color.secondary.opacity(0.55),
                                lineWidth: 1
                            )
                    )
                    .overlay {
                        if checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(green)
                        }
                    }
                    .frame(width: Self.side, height: Self.side)
                    .accessibilityLabel(checked ? "checked" : "unchecked")
            }
        }
    }

    /// Minimal, well-specified markdown parser for pane banners.
    ///
    /// Supported inline syntax:
    ///   - `**bold**`
    ///   - `*italic*` or `_italic_`
    ///   - `__underline__` (differs from CommonMark, which treats `__` as bold)
    ///   - `` `code` `` (monospaced, contents not further parsed)
    ///   - `[text](url)` clickable links; the label may contain other styles
    ///   - `\` escapes the next character (e.g. `\*`, `\[`, `\\`, `\|`)
    ///
    /// Block syntax: ATX headings and standard markdown pipe tables. A
    /// heading is a line of 1–6 leading `#` followed by a space and text
    /// (`# Title` … `###### Title`), rendered bold at a size that grows
    /// modestly as the level shrinks. A table starts at a line
    /// whose trimmed text begins with `|`, immediately followed by a
    /// separator row (`|---|---|`, optionally with `:` alignment markers)
    /// with the same column count; subsequent `|`-leading lines are body
    /// rows. Cells support the full inline syntax; `\|` puts a literal pipe
    /// in a cell. Ragged body rows are padded/truncated to the header width.
    /// A header whose cells are all empty (e.g. `|  |  |`) is treated as a
    /// layout scaffold for an aligned key/value grid: the view renders the
    /// body rows only, with no header row and no divider above them.
    ///
    /// Styles nest (`**bold with [link](…)**`). Unterminated delimiters are
    /// rendered literally. We hand-roll this instead of using Foundation's
    /// markdown parser because the latter has no underline syntax.
    enum BannerMarkdown {
        /// How a table column aligns, from `:` markers in the separator row.
        enum ColumnAlignment: Equatable {
            case leading
            case center
            case trailing
        }

        /// One piece of inline content. Text spans are pre-styled
        /// `AttributedString`; a `checkbox` is a task-list mark that the view
        /// draws natively (a rounded box with a colored check) rather than a
        /// glyph, so it reads as a real control instead of plaintext.
        enum Inline: Equatable {
            case text(AttributedString)
            case checkbox(Bool)
        }

        /// The leading marker of a list item, drawn in a shared gutter so all
        /// item content aligns regardless of marker kind.
        enum ListMarker: Equatable {
            /// `[x]`/`[ ]` — a native checkbox (`- [x]` marker also lands here).
            case checkbox(Bool)
            /// `- ` or `* ` — an unordered bullet.
            case bullet
            /// `1.`, `2.`, … — an ordered item; the associated value is the
            /// parsed number, rendered verbatim (source numbering is kept).
            case ordered(Int)
        }

        struct ListItem: Equatable {
            var marker: ListMarker
            var content: [Inline]
        }

        struct Table: Equatable {
            var header: [[Inline]]
            /// One entry per column; nil when the separator had no `:` markers.
            var alignments: [ColumnAlignment?]
            var rows: [[[Inline]]]

            /// True when at least one header cell carries visible content. An
            /// all-empty header (e.g. `|  |  |`) is a layout scaffold — a
            /// caller wanting an aligned key/value grid with no column
            /// titles — so the view skips rendering that blank row.
            var hasVisibleHeader: Bool {
                header.contains { cell in cell.contains { seg in
                    if case .text(let a) = seg { return !a.characters.isEmpty }
                    return true // a checkbox is visible content
                } }
            }
        }

        enum Block: Equatable {
            /// `lineLimit` is the display-line budget the view should allow
            /// this block (source lines were already truncated to the cap;
            /// the extra headroom lets long lines soft-wrap like they always
            /// have without the total exceeding the banner cap).
            case text(AttributedString, lineLimit: Int)
            /// A run of consecutive list lines — bullets (`- `/`* `), ordered
            /// items (`1.`), and task-list checkboxes (`[x]`/`[ ]`, optionally
            /// after a `- `/`* ` marker), in any mix. Rendered as evenly spaced
            /// rows whose markers share a gutter so every item's content aligns,
            /// separate from `.text` so lists get table-like vertical rhythm
            /// instead of tight line spacing.
            case list([ListItem])
            /// An ATX heading (`# text` … `###### text`); `level` is 1–6.
            /// Rendered bold at a size that grows as the level shrinks.
            case heading(AttributedString, level: Int)
            case table(Table)
            /// A thematic break (`---`, `***`, or `___`, 3+ of one character
            /// on a line of its own). Rendered as a horizontal divider that
            /// separates the blocks above and below it.
            case rule
        }

        static func parse(_ source: String) -> AttributedString {
            parseInline(Substring(source))
        }

        /// Flatten inline segments to a single `AttributedString`, rendering a
        /// checkbox as its box glyph (`☑`/`☐`). Used for the plain-text
        /// fallback (a checkbox mid-paragraph), heading text, and tests.
        static func attributed(_ segments: [Inline]) -> AttributedString {
            var result = AttributedString()
            for seg in segments {
                switch seg {
                case .text(let a): result.append(a)
                case .checkbox(let checked):
                    result.append(AttributedString(checked ? "\u{2611}" : "\u{2610}"))
                }
            }
            return result
        }

        /// Parse banner source into displayable blocks, truncated to at most
        /// `maxLines` display lines (table rows count as one line each).
        static func parseBlocks(_ source: String, maxLines: Int = Int.max) -> [Block] {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            var blocks: [Block] = []
            var textLines: [Substring] = []
            var remaining = maxLines

            func flushText() {
                defer { textLines = [] }
                // Each source line becomes its own text block so consecutive
                // lines get the same 8pt inter-block gap as everything else
                // (a run used to be a single multi-line Text, which spaced hard
                // newlines with tight line spacing instead of the block gap).
                // A long line still soft-wraps tight within its own block.
                // Blank separator lines are dropped — the block gap now supplies
                // the space they used to add.
                for line in textLines {
                    guard remaining > 0 else { return }
                    if line.allSatisfy(\.isWhitespace) { continue }
                    let limit = remaining
                    remaining -= 1
                    blocks.append(.text(parseInline(line), lineLimit: limit))
                }
            }

            var i = 0
            while i < lines.count {
                if let (level, text) = headingLine(lines[i]) {
                    flushText()
                    if remaining > 0 {
                        remaining -= 1
                        blocks.append(.heading(parseInline(text), level: level))
                    }
                    i += 1
                    continue
                }
                if isThematicBreak(lines[i]) {
                    flushText()
                    if remaining > 0 {
                        remaining -= 1
                        blocks.append(.rule)
                    }
                    i += 1
                    continue
                }
                if isTableRow(lines[i]), i + 1 < lines.count, isTableRow(lines[i + 1]) {
                    let headerCells = splitCells(lines[i])
                    let sepCells = splitCells(lines[i + 1])
                    if !headerCells.isEmpty,
                       sepCells.count == headerCells.count,
                       sepCells.allSatisfy(isSeparatorCell) {
                        flushText()

                        var rawRows: [[String]] = []
                        var j = i + 2
                        while j < lines.count, isTableRow(lines[j]) {
                            rawRows.append(splitCells(lines[j]))
                            j += 1
                        }

                        if remaining > 0 {
                            let keptRows = rawRows.prefix(max(0, remaining - 1))
                            remaining -= 1 + keptRows.count
                            let columns = headerCells.count
                            blocks.append(.table(Table(
                                header: headerCells.map { segments(Substring($0)) },
                                alignments: sepCells.map(columnAlignment),
                                rows: keptRows.map { row in
                                    (0..<columns).map { col in
                                        col < row.count
                                            ? segments(Substring(row[col]))
                                            : []
                                    }
                                }
                            )))
                        }

                        i = j
                        continue
                    }
                }

                // A run of list lines (bullets, ordered items, checkboxes)
                // becomes its own block so the items get table-like vertical
                // rhythm and a shared marker gutter, instead of tight text
                // line spacing.
                if listItem(lines[i]) != nil {
                    flushText()
                    var items: [ListItem] = []
                    while i < lines.count, let item = listItem(lines[i]) {
                        if remaining > 0 {
                            items.append(ListItem(
                                marker: item.marker,
                                content: segments(item.content)
                            ))
                            remaining -= 1
                        }
                        i += 1
                    }
                    if !items.isEmpty { blocks.append(.list(items)) }
                    continue
                }

                textLines.append(lines[i])
                i += 1
            }
            flushText()
            return blocks
        }

        /// A line participates in a table when its trimmed text starts with
        /// an (unescaped) pipe.
        private static func isTableRow(_ line: Substring) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }

        /// A thematic break: a line of 3+ of the same `-`, `*`, or `_` with
        /// nothing else but optional spaces (`---`, `***`, `___`, `- - -`).
        /// Distinct from a `- `/`* ` bullet (those have non-marker content)
        /// and from `**bold**` on its own line (mixed characters).
        private static func isThematicBreak(_ line: Substring) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first,
                  first == "-" || first == "*" || first == "_" else { return false }
            let marks = trimmed.filter { $0 != " " }
            return marks.count >= 3 && marks.allSatisfy { $0 == first }
        }

        /// An ATX heading: 1–6 leading `#`, a required space, then non-empty
        /// text (e.g. `## Title`). Returns the level and heading text, or nil.
        private static func headingLine(_ line: Substring) -> (level: Int, text: Substring)? {
            let trimmed = line.drop { $0 == " " }
            var level = 0
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
                level += 1
                idx = trimmed.index(after: idx)
            }
            guard level > 0, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
            let text = trimmed[trimmed.index(after: idx)...].drop { $0 == " " }
            guard !text.isEmpty else { return nil }
            return (level, text)
        }

        /// Split a table row into trimmed cell texts on unescaped `|`,
        /// dropping the empty segments produced by the structural leading
        /// and trailing pipes.
        private static func splitCells(_ line: Substring) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var cells: [String] = []
            var current = ""
            var i = trimmed.startIndex
            while i < trimmed.endIndex {
                let c = trimmed[i]
                if c == "\\" {
                    let next = trimmed.index(after: i)
                    if next < trimmed.endIndex {
                        current.append(c)
                        current.append(trimmed[next])
                        i = trimmed.index(after: next)
                        continue
                    }
                }
                if c == "|" {
                    cells.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
                i = trimmed.index(after: i)
            }
            cells.append(current)
            if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                cells.removeFirst()
            }
            if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                cells.removeLast()
            }
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        /// `---`, `:---`, `---:`, or `:---:` (at least one dash).
        private static func isSeparatorCell(_ cell: String) -> Bool {
            var body = Substring(cell)
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }

        private static func columnAlignment(_ cell: String) -> ColumnAlignment? {
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":") && cell.count > 1
            if leading && trailing { return .center }
            if trailing { return .trailing }
            if leading { return .leading }
            return nil
        }

        /// Delimiters checked in order: two-character ones must win over
        /// their single-character prefixes.
        private static let delimiters: [(String, InlinePresentationIntent?)] = [
            ("**", .stronglyEmphasized),
            ("__", nil), // underline, applied separately
            ("*", .emphasized),
            ("_", .emphasized),
            ("`", .code),
        ]

        /// Parse inline markdown into a flat `AttributedString`, rendering any
        /// checkbox as its box glyph. Used for nested contexts (link labels,
        /// styled spans), heading text, and the wrapping-text fallback.
        private static func parseInline(_ s: Substring) -> AttributedString {
            attributed(segments(s))
        }

        /// Parse inline markdown into ordered segments, emitting a native
        /// `.checkbox` for each top-level `[x]`/`[X]`/`[ ]` token (optionally
        /// after a leading `- `/`* ` marker) and `.text` for everything else.
        /// A checkbox nested inside a link/bold/italic span stays a glyph (via
        /// the `parseInline` recursion) — native boxes are a top-level affair.
        static func segments(_ s: Substring) -> [Inline] {
            var out: [Inline] = []
            var run = AttributedString()
            var literal = ""
            var i = s.startIndex

            func flushLiteral() {
                guard !literal.isEmpty else { return }
                run.append(AttributedString(literal))
                literal = ""
            }
            func flushRun() {
                flushLiteral()
                if !run.characters.isEmpty {
                    out.append(.text(run))
                    run = AttributedString()
                }
            }

            while i < s.endIndex {
                let c = s[i]

                // Backslash escapes the next character.
                if c == "\\" {
                    let next = s.index(after: i)
                    if next < s.endIndex {
                        literal.append(s[next])
                        i = s.index(after: next)
                        continue
                    }
                }

                // Task-list list marker: a leading "- "/"* " directly before a
                // checkbox token is consumed so "- [x] done" renders "☑ done"
                // instead of leaving a stray dash. Only fires at the very start
                // and only when a checkbox follows.
                if i == s.startIndex,
                   s.hasPrefix("- ") || s.hasPrefix("* "),
                   checkboxToken(in: s, at: s.index(i, offsetBy: 2)) != nil {
                    i = s.index(i, offsetBy: 2)
                    continue
                }

                // Task-list checkbox → native segment. Runs before the link
                // parser so a bare [x] isn't swallowed by the [text](url) path;
                // a [x](url) token (checkbox NOT matched because "(" follows)
                // falls through and stays a link.
                if let (checked, after) = checkboxToken(in: s, at: i) {
                    flushRun()
                    out.append(.checkbox(checked))
                    i = after
                    continue
                }

                // Links: [text](url)
                if c == "[",
                   let closeBracket = find("]", in: s, from: s.index(after: i)),
                   s.index(after: closeBracket) < s.endIndex,
                   s[s.index(after: closeBracket)] == "(",
                   let closeParen = find(")", in: s, from: s.index(closeBracket, offsetBy: 2)),
                   let url = URL(string: String(s[s.index(closeBracket, offsetBy: 2)..<closeParen])),
                   url.scheme != nil {
                    flushLiteral()
                    var linked = parseInline(s[s.index(after: i)..<closeBracket])
                    linked.link = url
                    linked.underlineStyle = Text.LineStyle.single
                    run.append(linked)
                    i = s.index(after: closeParen)
                    continue
                }

                // Delimited style spans.
                if let (delim, intent) = delimiters.first(where: { s[i..<s.endIndex].hasPrefix($0.0) }) {
                    let contentStart = s.index(i, offsetBy: delim.count)
                    if let close = find(delim, in: s, from: contentStart), close > contentStart {
                        let inner = s[contentStart..<close]
                        flushLiteral()
                        // Code spans are literal; everything else nests.
                        var styled = delim == "`"
                            ? AttributedString(String(inner))
                            : parseInline(inner)
                        if let intent {
                            addIntent(&styled, intent)
                        } else {
                            styled.underlineStyle = Text.LineStyle.single
                        }
                        run.append(styled)
                        i = s.index(close, offsetBy: delim.count)
                        continue
                    }
                }

                literal.append(c)
                i = s.index(after: i)
            }

            flushRun()
            return out
        }

        /// Classify `line` as a list item, returning its marker and the content
        /// that follows (leading spaces stripped so item content aligns in the
        /// gutter). Returns nil when the line isn't a list item.
        ///
        /// Recognized: `- `/`* ` bullets, `1.`/`2.`… ordered items, and
        /// `[x]`/`[X]`/`[ ]` checkboxes (a `- `/`* ` before a checkbox is the
        /// checkbox's marker, not a separate bullet).
        static func listItem(_ line: Substring) -> (marker: ListMarker, content: Substring)? {
            let trimmed = line.drop { $0 == " " }
            guard !trimmed.isEmpty else { return nil }

            // A leading "- "/"* " may introduce a checkbox or a plain bullet.
            var afterDash = trimmed
            let hadDash = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
            if hadDash { afterDash = trimmed.dropFirst(2) }

            if let (checked, after) = checkboxToken(in: afterDash, at: afterDash.startIndex) {
                return (.checkbox(checked), afterDash[after...].drop { $0 == " " })
            }
            if hadDash {
                return (.bullet, afterDash.drop { $0 == " " })
            }
            if let (number, rest) = orderedPrefix(trimmed) {
                return (.ordered(number), rest.drop { $0 == " " })
            }
            return nil
        }

        /// Match a leading `<digits>. ` (period then a required space, so a
        /// decimal like `1.5` isn't a list). Returns the number and the rest.
        private static func orderedPrefix(_ s: Substring) -> (number: Int, rest: Substring)? {
            var idx = s.startIndex
            while idx < s.endIndex, s[idx] >= "0", s[idx] <= "9" {
                idx = s.index(after: idx)
            }
            guard idx > s.startIndex, let number = Int(s[s.startIndex..<idx]) else { return nil }
            guard idx < s.endIndex, s[idx] == "." else { return nil }
            let afterDot = s.index(after: idx)
            guard afterDot < s.endIndex, s[afterDot] == " " else { return nil }
            return (number, s[afterDot...])
        }

        /// If a task-list checkbox token (`[x]`, `[X]`, or `[ ]`) begins at
        /// `at`, return whether it's checked and the index just past the token.
        /// Returns nil when the token isn't a checkbox, or when a `(` follows
        /// the closing `]` (then it's a `[text](url)` link, not a checkbox).
        private static func checkboxToken(
            in s: Substring,
            at index: Substring.Index
        ) -> (checked: Bool, after: Substring.Index)? {
            guard index < s.endIndex, s[index] == "[" else { return nil }
            let i1 = s.index(after: index)
            guard i1 < s.endIndex else { return nil }
            let i2 = s.index(after: i1)
            guard i2 < s.endIndex, s[i2] == "]" else { return nil }
            let checked: Bool
            switch s[i1] {
            case "x", "X": checked = true
            case " ": checked = false
            default: return nil
            }
            let after = s.index(after: i2)
            // A trailing "(" means this is link text, e.g. [x](https://…).
            if after < s.endIndex, s[after] == "(" { return nil }
            return (checked, after)
        }

        /// Find the next unescaped occurrence of `needle` at or after `from`.
        private static func find(
            _ needle: String,
            in s: Substring,
            from: Substring.Index
        ) -> Substring.Index? {
            guard from <= s.endIndex else { return nil }
            var i = from
            while i < s.endIndex {
                if s[i] == "\\" {
                    // Skip the escape and the escaped character.
                    i = s.index(after: i)
                    if i < s.endIndex { i = s.index(after: i) }
                    continue
                }
                if s[i..<s.endIndex].hasPrefix(needle) { return i }
                i = s.index(after: i)
            }
            return nil
        }

        /// Union an inline presentation intent into every run so that
        /// nested styles (e.g. italic inside bold) combine instead of
        /// overwrite.
        private static func addIntent(
            _ str: inout AttributedString,
            _ intent: InlinePresentationIntent
        ) {
            for run in str.runs {
                var combined = run.inlinePresentationIntent ?? []
                combined.formUnion(intent)
                str[run.range].inlinePresentationIntent = combined
            }
        }
    }
}

/// The banner's total target height — the height the card will occupy once
/// any collapse/expand animation settles, measured off a hidden animation-free
/// copy of the content. The host insets the terminal below the banner from
/// this value so the scroll area moves in one exact step per state change
/// instead of tracking the animated frame.
struct BannerTargetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
