import Testing
import SwiftUI
@testable import Ghostty

struct BannerMarkdownTests {
    typealias Block = Ghostty.BannerMarkdown.Block

    typealias Inline = Ghostty.BannerMarkdown.Inline

    private func plain(_ str: AttributedString) -> String {
        String(str.characters)
    }

    /// Flatten inline segments (checkboxes → box glyph) for text assertions.
    private func plain(_ segments: [Inline]) -> String {
        String(Ghostty.BannerMarkdown.attributed(segments).characters)
    }

    /// Inline segments as a single AttributedString for run/style assertions.
    private func attr(_ segments: [Inline]) -> AttributedString {
        Ghostty.BannerMarkdown.attributed(segments)
    }

    // MARK: Inline (existing subset still intact)

    @Test func inlineBold() {
        let parsed = Ghostty.BannerMarkdown.parse("a **b** c")
        #expect(plain(parsed) == "a b c")
        let bold = parsed.runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(bold != nil)
    }

    @Test func inlineEscapedPipe() {
        #expect(plain(Ghostty.BannerMarkdown.parse("a \\| b")) == "a | b")
    }

    // MARK: Headings

    @Test func headingParsesLevelAndText() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("#### Banner hook redesign")
        #expect(blocks.count == 1)
        guard case .heading(let str, let level) = blocks[0] else {
            Issue.record("expected heading block, got \(blocks)")
            return
        }
        #expect(level == 4)
        #expect(plain(str) == "Banner hook redesign")
    }

    @Test func headingAboveTableIsSeparateBlock() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "#### Title\n|  |  |\n|---|---|\n| **Goal** | x |"
        )
        #expect(blocks.count == 2)
        guard case .heading(_, let level) = blocks[0],
              case .table(let table) = blocks[1] else {
            Issue.record("expected heading + table, got \(blocks)")
            return
        }
        #expect(level == 4)
        #expect(table.hasVisibleHeader == false)
        #expect(table.rows.map { $0.map(plain) } == [["Goal", "x"]])
    }

    @Test func hashWithoutSpaceIsText() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("#notaheading")
        #expect(blocks.count == 1)
        guard case .text(let str, _) = blocks[0] else {
            Issue.record("expected text block")
            return
        }
        #expect(plain(str) == "#notaheading")
    }

    @Test func headingInlineStyles() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("## a [b](https://x.com)")
        guard case .heading(let str, _) = blocks.first else {
            Issue.record("expected heading block")
            return
        }
        #expect(plain(str) == "a b")
        #expect(str.runs.contains { $0.link != nil })
    }

    // MARK: Block segmentation

    @Test func plainTextIsSingleBlock() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("hello\nworld")
        #expect(blocks.count == 1)
        guard case .text(let str, _) = blocks[0] else {
            Issue.record("expected text block")
            return
        }
        #expect(plain(str) == "hello\nworld")
    }

    @Test func tableBetweenTextProducesThreeBlocks() {
        let source = "title\n| a | b |\n|---|---|\n| 1 | 2 |\ntrailer"
        let blocks = Ghostty.BannerMarkdown.parseBlocks(source)
        #expect(blocks.count == 3)
        guard case .text(let before, _) = blocks[0],
              case .table(let table) = blocks[1],
              case .text(let after, _) = blocks[2] else {
            Issue.record("expected text/table/text, got \(blocks)")
            return
        }
        #expect(plain(before) == "title")
        #expect(table.header.map(plain) == ["a", "b"])
        #expect(table.rows.map { $0.map(plain) } == [["1", "2"]])
        #expect(plain(after) == "trailer")
    }

    // MARK: Table parsing

    @Test func tableBasic() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| Name | Count |\n|---|---|\n| foo | 1 |\n| bar | 2 |"
        )
        #expect(blocks.count == 1)
        guard case .table(let table) = blocks[0] else {
            Issue.record("expected table block")
            return
        }
        #expect(table.header.map(plain) == ["Name", "Count"])
        #expect(table.rows.map { $0.map(plain) } == [["foo", "1"], ["bar", "2"]])
        #expect(table.alignments == [nil, nil])
    }

    @Test func tableAlignmentMarkers() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| a | b | c | d |\n|:---|:---:|---:|---|\n| 1 | 2 | 3 | 4 |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing, nil])
    }

    @Test func tableInlineStylesInsideCells() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| **PR** | link |\n|---|---|\n| `code` | [x](https://example.com) |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(plain(table.header[0]) == "PR")
        let headerBold = attr(table.header[0]).runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(headerBold != nil)
        let codeRun = attr(table.rows[0][0]).runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        #expect(codeRun != nil)
        #expect(attr(table.rows[0][1]).runs.first?.link != nil)
    }

    @Test func tableEscapedPipeStaysInCell() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| a | b |\n|---|---|\n| x \\| y | z |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.rows[0].map(plain) == ["x | y", "z"])
    }

    @Test func tableRaggedRowsPadAndTruncate() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.rows.map { $0.map(plain) } == [["1", ""], ["1", "2"]])
    }

    @Test func tableWithoutTrailingPipes() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| a | b\n|---|---\n| 1 | 2"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.header.map(plain) == ["a", "b"])
        #expect(table.rows.map { $0.map(plain) } == [["1", "2"]])
    }

    @Test func emptyHeaderIsScaffold() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "|  |  |\n|---|---|\n| **Goal** | ship it |\n| **PR** | x |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.hasVisibleHeader == false)
        #expect(table.rows.map { $0.map(plain) } == [["Goal", "ship it"], ["PR", "x"]])
    }

    @Test func nonEmptyHeaderIsVisible() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| Name | Count |\n|---|---|\n| foo | 1 |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.hasVisibleHeader == true)
    }

    // MARK: Not-a-table fallbacks

    @Test func separatorColumnMismatchIsText() {
        let source = "| a | b |\n|---|\n| 1 | 2 |"
        let blocks = Ghostty.BannerMarkdown.parseBlocks(source)
        #expect(blocks.count == 1)
        guard case .text(let str, _) = blocks[0] else {
            Issue.record("expected text block")
            return
        }
        #expect(plain(str) == source)
    }

    @Test func missingSeparatorIsText() {
        let source = "| a | b |\n| 1 | 2 |"
        let blocks = Ghostty.BannerMarkdown.parseBlocks(source)
        #expect(blocks.count == 1)
        guard case .text = blocks[0] else {
            Issue.record("expected text block")
            return
        }
    }

    @Test func pipeInsideTextLineIsNotATable() {
        let source = "a | b\nc | d"
        let blocks = Ghostty.BannerMarkdown.parseBlocks(source)
        #expect(blocks.count == 1)
        guard case .text(let str, _) = blocks[0] else {
            Issue.record("expected text block")
            return
        }
        #expect(plain(str) == source)
    }

    // MARK: Display cap

    @Test func maxLinesTruncatesTableRows() {
        let rows = (1...20).map { "| r\($0) | x |" }.joined(separator: "\n")
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| a | b |\n|---|---|\n" + rows,
            maxLines: 5
        )
        #expect(blocks.count == 1)
        guard case .table(let table) = blocks[0] else {
            Issue.record("expected table block")
            return
        }
        // Header consumes one display line; 4 body rows remain.
        #expect(table.rows.count == 4)
        #expect(plain(table.rows.last![0]) == "r4")
    }

    @Test func maxLinesTruncatesTextLines() {
        let source = (1...20).map { "line\($0)" }.joined(separator: "\n")
        let blocks = Ghostty.BannerMarkdown.parseBlocks(source, maxLines: 3)
        #expect(blocks.count == 1)
        guard case .text(let str, let limit) = blocks[0] else {
            Issue.record("expected text block")
            return
        }
        #expect(plain(str) == "line1\nline2\nline3")
        #expect(limit == 3)
    }

    @Test func maxLinesDropsBlocksPastCap() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "one\ntwo\n| a |\n|---|\n| 1 |",
            maxLines: 2
        )
        #expect(blocks.count == 1)
        guard case .text = blocks[0] else {
            Issue.record("expected only the text block")
            return
        }
    }

    // MARK: Task-list checkboxes

    private func segs(_ s: String) -> [Inline] {
        Ghostty.BannerMarkdown.segments(Substring(s))
    }

    // Native segment output: checkbox tokens become `.checkbox`, not glyphs.

    @Test func checkboxSegmentsCheckedAndUnchecked() {
        #expect(segs("[x] a") == [.checkbox(true), .text(AttributedString(" a"))])
        #expect(segs("[X] a") == [.checkbox(true), .text(AttributedString(" a"))])
        #expect(segs("[ ] a") == [.checkbox(false), .text(AttributedString(" a"))])
    }

    @Test func checkboxSegmentsMixedLine() {
        let s = segs("[x] tests pass   [ ] docs TODO")
        #expect(s == [
            .checkbox(true),
            .text(AttributedString(" tests pass   ")),
            .checkbox(false),
            .text(AttributedString(" docs TODO")),
        ])
    }

    @Test func checkboxSegmentsLeadingListMarker() {
        // A leading "- "/"* " before a checkbox is consumed (no stray dash).
        #expect(segs("- [x] done") == [.checkbox(true), .text(AttributedString(" done"))])
        #expect(segs("* [ ] todo") == [.checkbox(false), .text(AttributedString(" todo"))])
        // A dash NOT followed by a checkbox stays literal text.
        #expect(segs("- item") == [.text(AttributedString("- item"))])
    }

    @Test func checkboxSegmentsNotFullTokenIsLiteral() {
        // [xx] and [y] are not checkbox tokens; left to link/literal logic.
        #expect(segs("[xx]") == [.text(AttributedString("[xx]"))])
        #expect(segs("[y]") == [.text(AttributedString("[y]"))])
    }

    @Test func checkboxSegmentsLinkIsNotCheckbox() {
        // [x](url) is a link (x is the link text), not a checkbox segment.
        let s = segs("[x](https://example.com)")
        #expect(s.count == 1)
        guard case .text(let a) = s.first else {
            Issue.record("expected a single text (link) segment")
            return
        }
        #expect(String(a.characters) == "x")
        #expect(a.runs.contains { $0.link != nil })
    }

    // Block-level: consecutive list lines form a `.list` block so the items
    // render with proper spacing and a shared marker gutter rather than tight
    // text lines.

    typealias ListItem = Ghostty.BannerMarkdown.ListItem

    private func item(_ marker: Ghostty.BannerMarkdown.ListMarker, _ text: String) -> ListItem {
        ListItem(marker: marker, content: text.isEmpty ? [] : [.text(AttributedString(text))])
    }

    @Test func checkboxListFromConsecutiveLines() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("- [x] done\n- [ ] todo\n[x] also")
        #expect(blocks.count == 1)
        guard case .list(let items) = blocks.first else {
            Issue.record("expected list block, got \(blocks)")
            return
        }
        // Marker is the checkbox; content follows with leading space stripped.
        #expect(items == [
            item(.checkbox(true), "done"),
            item(.checkbox(false), "todo"),
            item(.checkbox(true), "also"),
        ])
    }

    @Test func bulletList() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("- alpha\n* beta")
        guard case .list(let items) = blocks.first else {
            Issue.record("expected list block, got \(blocks)")
            return
        }
        #expect(items == [item(.bullet, "alpha"), item(.bullet, "beta")])
    }

    @Test func orderedList() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("1. first\n2. second\n10. tenth")
        guard case .list(let items) = blocks.first else {
            Issue.record("expected list block, got \(blocks)")
            return
        }
        #expect(items == [
            item(.ordered(1), "first"),
            item(.ordered(2), "second"),
            item(.ordered(10), "tenth"),
        ])
    }

    @Test func mixedMarkersShareOneListBlock() {
        // Bullets, ordered items, and checkboxes on consecutive lines all
        // belong to a single list so they align in a shared gutter.
        let blocks = Ghostty.BannerMarkdown.parseBlocks("- bullet\n1. one\n[x] check")
        #expect(blocks.count == 1)
        guard case .list(let items) = blocks.first else {
            Issue.record("expected one list block, got \(blocks)")
            return
        }
        #expect(items == [
            item(.bullet, "bullet"),
            item(.ordered(1), "one"),
            item(.checkbox(true), "check"),
        ])
    }

    @Test func listItemContentKeepsInlineStyles() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("- **bold** item")
        guard case .list(let items) = blocks.first, items.count == 1 else {
            Issue.record("expected one list item, got \(blocks)")
            return
        }
        #expect(items[0].marker == .bullet)
        #expect(plain(items[0].content) == "bold item")
        #expect(attr(items[0].content).runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
    }

    @Test func decimalIsNotAnOrderedList() {
        // "1.5" has no space after the dot, so it stays plain text.
        let blocks = Ghostty.BannerMarkdown.parseBlocks("1.5 kg")
        guard case .text = blocks.first else {
            Issue.record("expected text block, got \(blocks)")
            return
        }
    }

    @Test func listSeparatedFromSurroundingText() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks("Status:\n[x] shipped\nnote")
        #expect(blocks.count == 3)
        guard case .text = blocks[0], case .list(let items) = blocks[1],
              case .text = blocks[2] else {
            Issue.record("expected text / list / text, got \(blocks)")
            return
        }
        #expect(items == [item(.checkbox(true), "shipped")])
    }

    // Table cells render native checkboxes too (still a single `.table` block).

    @Test func checkboxInsideTableCell() {
        let blocks = Ghostty.BannerMarkdown.parseBlocks(
            "| Job | State |\n|---|---|\n| lint | [x] |\n| tests | [ ] |"
        )
        guard case .table(let table) = blocks.first else {
            Issue.record("expected table block")
            return
        }
        #expect(table.rows[0][1] == [.checkbox(true)])
        #expect(table.rows[1][1] == [.checkbox(false)])
        // The label cells are plain text.
        #expect(plain(table.rows[0][0]) == "lint")
    }

    // The inline glyph fallback (used for wrapping text and tests) still maps
    // checkboxes to ☑/☐.

    @Test func checkboxGlyphFallback() {
        #expect(plain(Ghostty.BannerMarkdown.parse("[x] a")) == "\u{2611} a")
        #expect(plain(Ghostty.BannerMarkdown.parse("[ ] a")) == "\u{2610} a")
    }
}
