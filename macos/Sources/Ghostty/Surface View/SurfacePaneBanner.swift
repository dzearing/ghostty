import SwiftUI

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

        /// Total display cap in lines. Table rows (including the header)
        /// each count as one line; the separator row never renders.
        static let maxDisplayLines = 10

        /// Content height when collapsed: the first line fully visible
        /// plus a sliver of the next, which the fade mask dissolves to
        /// hint that there's more to view.
        private static let collapsedContentHeight: CGFloat = 24

        /// Collapsed state is per-pane and ephemeral; it resets when the
        /// banner is cleared and set again.
        @State private var collapsed = false

        var body: some View {
            let blocks = BannerMarkdown.parseBlocks(text, maxLines: Self.maxDisplayLines)
            // Single-line banners have nothing to collapse; hide the
            // chevron and ignore background clicks.
            let collapsible = text.contains("\n")

            HStack(alignment: .top, spacing: 8) {
                // Paragraph-style gap between blocks (text runs, tables);
                // lines within a text run stay tight since a run is a
                // single Text.
                let content = VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                if collapsed {
                    content
                        .frame(height: Self.collapsedContentHeight, alignment: .topLeading)
                        .clipped()
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.55),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } else {
                    content
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
            .font(.system(size: 12))
            .padding(12)
            .background(backgroundStyle)
            .contentShape(Rectangle())
            .onTapGesture {
                guard collapsible else { return }
                toggleCollapsed()
            }
            .overlay(alignment: .bottom) {
                Divider()
            }
        }

        private func toggleCollapsed() {
            withAnimation(.easeInOut(duration: 0.18)) {
                collapsed.toggle()
            }
        }

        /// A shade deviated from the pane background (lighter when dark,
        /// darker when light); falls back to the translucent material
        /// when the background isn't known.
        private var backgroundStyle: AnyShapeStyle {
            guard let background else { return AnyShapeStyle(.ultraThinMaterial) }
            let os = OSColor(background)
            let shaded = os.isLightColor ? os.darken(by: 0.06) : os.lighten(by: 0.1)
            return AnyShapeStyle(Color(shaded))
        }

        @ViewBuilder
        private func blockView(_ block: BannerMarkdown.Block) -> some View {
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
            case .heading(let str, let level):
                Text(str)
                    .font(.system(size: headingFontSize(level), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            case .table(let table):
                let showHeader = table.hasVisibleHeader
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 4) {
                    if showHeader {
                        GridRow {
                            ForEach(Array(table.header.enumerated()), id: \.offset) { col, cell in
                                inlineRow(cell)
                                    .bold()
                                    .gridColumnAlignment(horizontalAlignment(table.alignments[col]))
                            }
                        }
                        // Unsized so the divider spans the header without
                        // stretching the grid to the full banner width.
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIdx, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                                // With no header row to carry it, the first
                                // body row sets each column's alignment.
                                if !showHeader && rowIdx == 0 {
                                    inlineRow(cell)
                                        .gridColumnAlignment(horizontalAlignment(table.alignments[col]))
                                } else {
                                    inlineRow(cell)
                                }
                            }
                        }
                    }
                }
            }
        }

        /// Lay out one line of inline content — a table cell or a task-list
        /// item — as a single non-wrapping row, drawing each `.checkbox`
        /// segment as a native box (see `CheckboxMark`) and each `.text`
        /// segment as styled text. Source spaces provide the gaps, so a
        /// leading `[x] ` renders "☑ done" with the box vertically centered.
        @ViewBuilder
        private func inlineRow(_ segments: [BannerMarkdown.Inline]) -> some View {
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let str):
                        Text(str).lineLimit(1)
                    case .checkbox(let checked):
                        CheckboxMark(checked: checked)
                    }
                }
            }
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

        private func horizontalAlignment(
            _ alignment: BannerMarkdown.ColumnAlignment?
        ) -> HorizontalAlignment {
            switch alignment {
            case .center: return .center
            case .trailing: return .trailing
            case .leading, nil: return .leading
            }
        }

        /// A task-list checkbox drawn as a small native control rather than a
        /// glyph: a rounded (2pt-radius) box with a thin border, filled with a
        /// tinted wash and a colored check when checked. Sized to sit inline
        /// with the 12pt banner text like a character.
        private struct CheckboxMark: View {
            let checked: Bool

            private static let side: CGFloat = 12
            private static let radius: CGFloat = 2

            var body: some View {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(checked ? Color.green.opacity(0.16) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(
                                checked ? Color.green.opacity(0.55)
                                        : Color.secondary.opacity(0.55),
                                lineWidth: 1
                            )
                    )
                    .overlay {
                        if checked {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.green)
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
                guard !textLines.isEmpty, remaining > 0 else { return }
                let limit = remaining
                let kept = textLines.prefix(remaining)
                remaining -= kept.count
                blocks.append(.text(
                    parseInline(Substring(kept.joined(separator: "\n"))),
                    lineLimit: limit
                ))
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
