import SwiftUI

extension Ghostty {
    /// Sticky banner rendered above the terminal content of a pane. Set via
    /// `ghoztty +set-banner` IPC or the OSC 7778 escape sequence; persists
    /// (survives scrolling and screen clears) until changed or cleared.
    struct SurfacePaneBanner: View {
        /// Raw banner source text in the banner markdown subset.
        let text: String

        var body: some View {
            HStack(spacing: 0) {
                Text(BannerMarkdown.parse(text))
                    .font(.system(size: 12))
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    /// Minimal, well-specified inline markdown parser for pane banners.
    ///
    /// Supported syntax:
    ///   - `**bold**`
    ///   - `*italic*` or `_italic_`
    ///   - `__underline__` (differs from CommonMark, which treats `__` as bold)
    ///   - `` `code` `` (monospaced, contents not further parsed)
    ///   - `[text](url)` clickable links; the label may contain other styles
    ///   - `\` escapes the next character (e.g. `\*`, `\[`, `\\`)
    ///
    /// Styles nest (`**bold with [link](…)**`). Unterminated delimiters are
    /// rendered literally. We hand-roll this instead of using Foundation's
    /// markdown parser because the latter has no underline syntax.
    enum BannerMarkdown {
        static func parse(_ source: String) -> AttributedString {
            parseInline(Substring(source))
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
