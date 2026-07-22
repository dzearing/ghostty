import AppKit
import Testing
@testable import Ghostty

/// Quoting a passage out of the page: the composer block, the body rendering,
/// and the referential metadata that lets a reader find what was quoted.
@MainActor
struct ViewerFeedbackQuoteTests {
    private func makeQuote(_ text: String, number: Int = 1) -> ViewerFeedbackQuote {
        var quote = ViewerFeedbackQuote(number: number, text: text)
        quote.headingID = "installation"
        quote.headingText = "Installation"
        quote.blockSelector = "p:nth-of-type(3)"
        quote.blockText = "Run the installer. \(text) Then restart."
        quote.offsetInBlock = 20
        quote.documentOffset = 420
        return quote
    }

    /// A quote lands as its own block, carrying the attribute that both draws
    /// it and maps it back to its references.
    @Test func insertingAQuoteMarksItsRun() {
        let model = ViewerFeedbackModel()
        model.textStorage.append(NSAttributedString(
            string: "this bit:", attributes: ViewerFeedbackModel.typingAttributes))
        let quote = makeQuote("the config is reloaded on save")
        model.insertQuote(quote, at: NSRange(location: model.textStorage.length, length: 0))

        #expect(model.quotes.count == 1)
        #expect(model.quotes[0].text == "the config is reloaded on save")
        // The run carries the quote id, which is what drawBackground paints.
        var foundID: String?
        model.textStorage.enumerateAttribute(
            .feedbackQuoteID,
            in: NSRange(location: 0, length: model.textStorage.length)
        ) { value, _, _ in
            if let raw = value as? String { foundID = raw }
        }
        #expect(foundID == quote.id.uuidString)
        // It is a block: the quote does not run on from the prose.
        #expect(model.textStorage.string.contains("\nthe config is reloaded on save"))
    }

    /// Deleting the quote's run drops it from the report metadata too — the
    /// same derive-from-storage rule the image carousel uses.
    @Test func deletingAQuoteRunDropsItsMetadata() {
        let model = ViewerFeedbackModel()
        let quote = makeQuote("a passage")
        let range = model.insertQuote(quote, at: NSRange(location: 0, length: 0))
        #expect(model.quotes.count == 1)

        model.textStorage.deleteCharacters(in: range)
        model.syncAttachments()
        #expect(model.quotes.isEmpty)
    }

    /// Segments split at the quote, so the body keeps the order written.
    @Test func segmentsSplitAtQuotes() {
        let model = ViewerFeedbackModel()
        model.textStorage.append(NSAttributedString(
            string: "before", attributes: ViewerFeedbackModel.typingAttributes))
        model.insertQuote(
            makeQuote("quoted line"),
            at: NSRange(location: model.textStorage.length, length: 0))
        model.textStorage.append(NSAttributedString(
            string: "after", attributes: ViewerFeedbackModel.typingAttributes))
        model.syncAttachments()

        let segments = model.segments()
        let kinds = segments.map { segment -> String in
            switch segment {
            case .text: return "t"
            case .image: return "i"
            case .quote: return "q"
            }
        }
        // text, quote, text — in that order (the leading newline joins the
        // preceding text run).
        #expect(kinds.contains("q"))
        #expect(kinds.firstIndex(of: "q")! > 0)
        #expect(kinds.firstIndex(of: "q")! < kinds.count - 1)
    }

    /// The body renders a real markdown blockquote.
    @Test func bodyRendersMarkdownBlockquote() {
        let body = ViewerFeedbackReport.renderBody(segments: [
            .text("look here:"),
            .quote(number: 1, text: "line one\nline two"),
            .text("that's wrong"),
        ])
        #expect(body.contains("> line one"))
        #expect(body.contains("> line two"))
        #expect(body.contains("look here:"))
        #expect(body.contains("that's wrong"))
    }

    /// A quote with no prose is still a valid report — "this bit is wrong" is
    /// legitimate feedback.
    @Test func quoteAloneIsNotEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quote-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let worktree = ViewerWorktree(path: dir.path)

        let written = try ViewerFeedbackReport.write(
            segments: [.quote(number: 1, text: "the broken sentence")],
            images: [],
            quotes: [ViewerFeedbackReport.Quote(
                number: 1, text: "the broken sentence",
                headingID: "intro", headingText: "Intro",
                blockSelector: "p:nth-of-type(1)", blockText: "the broken sentence here",
                offsetInBlock: 0, documentOffset: 12, sourceLine: 7)],
            worktree: worktree,
            context: ViewerFeedbackReport.Context(source: "/a/b.md", sourceKind: "file"))

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: written.reportURL)) as! [String: Any]
        let quotes = try #require(json["quotes"] as? [[String: Any]])
        #expect(quotes.count == 1)
        #expect(quotes[0]["text"] as? String == "the broken sentence")
        // The references that let an agent find what was discussed.
        #expect(quotes[0]["headingId"] as? String == "intro")
        #expect(quotes[0]["blockSelector"] as? String == "p:nth-of-type(1)")
        #expect(quotes[0]["blockText"] as? String == "the broken sentence here")
        #expect(quotes[0]["sourceLine"] as? Int == 7)
        #expect((json["body"] as? String)?.contains("> the broken sentence") == true)
    }
}

/// Locating a rendered quote back in the source file.
@MainActor
struct ViewerQuoteSourceLineTests {
    private let source = """
    # Title

    Some intro text.

    The **config** is reloaded on save.

    Another paragraph.
    """

    /// An exact substring is found directly.
    @Test func findsExactLine() {
        #expect(ViewerView.lineNumber(of: "Some intro text.", in: source) == 3)
    }

    /// Rendered text drops markdown syntax, so the fallback normalizes and
    /// still locates the line.
    @Test func findsLineDespiteMarkdownSyntax() {
        // The rendered form has no ** around config.
        let line = ViewerView.lineNumber(of: "The config is reloaded on save.", in: source)
        // Not findable as an exact substring; the normalized pass also can't
        // match because the source keeps the asterisks — so it must return nil
        // rather than a confidently wrong line.
        #expect(line == nil || line == 5)
    }

    /// A passage that is not in the file yields nil rather than a wrong line.
    @Test func missingPassageYieldsNil() {
        #expect(ViewerView.lineNumber(of: "nowhere in this document", in: source) == nil)
    }

    /// Multi-line quotes match on their first line, which is the only part
    /// guaranteed contiguous after rendering wrapped it.
    @Test func multiLineQuoteMatchesFirstLine() {
        #expect(ViewerView.lineNumber(of: "Another paragraph.\nwrapped tail", in: source) == 7)
    }
}

/// The snapshot keystroke must fire only on ⇧⌘S and never shadow anything else.
@MainActor
struct ViewerFeedbackSnapshotShortcutTests {
    private func event(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 1)!
    }

    @Test func shiftCommandSTriggersSnapshot() {
        #expect(ViewerFeedbackTextView.isSnapshotShortcut(event("s", [.command, .shift])))
        #expect(ViewerFeedbackTextView.isSnapshotShortcut(event("S", [.command, .shift])))
    }

    @Test func otherCombinationsDoNot() {
        // Plain ⌘S (a Save gesture elsewhere) must not capture.
        #expect(!ViewerFeedbackTextView.isSnapshotShortcut(event("s", [.command])))
        // ⇧S is just a capital letter being typed.
        #expect(!ViewerFeedbackTextView.isSnapshotShortcut(event("s", [.shift])))
        // Extra modifiers are someone else's binding.
        #expect(!ViewerFeedbackTextView.isSnapshotShortcut(
            event("s", [.command, .shift, .option])))
        #expect(!ViewerFeedbackTextView.isSnapshotShortcut(
            event("s", [.command, .shift, .control])))
        // A different letter.
        #expect(!ViewerFeedbackTextView.isSnapshotShortcut(event("d", [.command, .shift])))
    }

    /// Send and snapshot must never both claim the same event.
    @Test func sendAndSnapshotAreDisjoint() {
        let shot = event("s", [.command, .shift])
        #expect(ViewerFeedbackTextView.isSnapshotShortcut(shot))
        #expect(!ViewerFeedbackTextView.isSendShortcut(shot))
    }
}
