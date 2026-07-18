import Testing
import SwiftUI
@testable import Ghostty

struct BannerMarkdownTests {
    typealias Block = Ghostty.BannerMarkdown.Block

    private func plain(_ str: AttributedString) -> String {
        String(str.characters)
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
        let headerBold = table.header[0].runs.first {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(headerBold != nil)
        let codeRun = table.rows[0][0].runs.first {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        #expect(codeRun != nil)
        #expect(table.rows[0][1].runs.first?.link != nil)
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
}
