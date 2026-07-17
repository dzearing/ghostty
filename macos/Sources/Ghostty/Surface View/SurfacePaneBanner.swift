import SwiftUI

extension Ghostty {
    /// Sticky banner rendered above the terminal content of a pane. Set via
    /// `ghoztty +set-banner` IPC or the OSC 7778 escape sequence; persists
    /// (survives scrolling and screen clears) until changed or cleared.
    struct SurfacePaneBanner: View {
        /// Raw banner source text in the banner markdown subset.
        let text: String

        /// Total display cap in lines. Table rows (including the header)
        /// each count as one line; the separator row never renders.
        static let maxDisplayLines = 10

        var body: some View {
            let blocks = BannerMarkdown.parseBlocks(text, maxLines: Self.maxDisplayLines)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }

        @ViewBuilder
        private func blockView(_ block: BannerMarkdown.Block) -> some View {
            switch block {
            case .text(let str, let lineLimit):
                Text(str)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            case .table(let table):
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { col, cell in
                            Text(cell)
                                .bold()
                                .lineLimit(1)
                                .gridColumnAlignment(horizontalAlignment(table.alignments[col]))
                        }
                    }
                    // Unsized so the divider spans the header without
                    // stretching the grid to the full banner width.
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
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
    /// Block syntax: standard markdown pipe tables. A table starts at a line
    /// whose trimmed text begins with `|`, immediately followed by a
    /// separator row (`|---|---|`, optionally with `:` alignment markers)
    /// with the same column count; subsequent `|`-leading lines are body
    /// rows. Cells support the full inline syntax; `\|` puts a literal pipe
    /// in a cell. Ragged body rows are padded/truncated to the header width.
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

        struct Table: Equatable {
            var header: [AttributedString]
            /// One entry per column; nil when the separator had no `:` markers.
            var alignments: [ColumnAlignment?]
            var rows: [[AttributedString]]
        }

        enum Block: Equatable {
            /// `lineLimit` is the display-line budget the view should allow
            /// this block (source lines were already truncated to the cap;
            /// the extra headroom lets long lines soft-wrap like they always
            /// have without the total exceeding the banner cap).
            case text(AttributedString, lineLimit: Int)
            case table(Table)
        }

        static func parse(_ source: String) -> AttributedString {
            parseInline(Substring(source))
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
                                header: headerCells.map { parseInline(Substring($0)) },
                                alignments: sepCells.map(columnAlignment),
                                rows: keptRows.map { row in
                                    (0..<columns).map { col in
                                        col < row.count
                                            ? parseInline(Substring(row[col]))
                                            : AttributedString()
                                    }
                                }
                            )))
                        }

                        i = j
                        continue
                    }
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

        private static func parseInline(_ s: Substring) -> AttributedString {
            var result = AttributedString()
            var literal = ""
            var i = s.startIndex

            func flushLiteral() {
                guard !literal.isEmpty else { return }
                result.append(AttributedString(literal))
                literal = ""
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
                    result.append(linked)
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
                        result.append(styled)
                        i = s.index(close, offsetBy: delim.count)
                        continue
                    }
                }

                literal.append(c)
                i = s.index(after: i)
            }

            flushLiteral()
            return result
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
