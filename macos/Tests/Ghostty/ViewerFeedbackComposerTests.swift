import AppKit
import Testing
@testable import Ghostty

/// The composer model: chips are atomic single-character attachments, the
/// carousel is derived from the text storage, and chip numbers stay stable
/// across deletions.
@MainActor
struct ViewerFeedbackComposerTests {
    private func png(_ color: NSColor = .red) -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return ViewerFeedbackTextView.pngData(from: image)!
    }

    private func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return image
    }

    /// A pasted image occupies exactly ONE character in the storage — the
    /// object-replacement character — which is what makes it atomic.
    @Test func chipIsSingleCharacter() {
        let model = ViewerFeedbackModel()
        model.insertImage(image(), png: png(), at: NSRange(location: 0, length: 0))
        #expect(model.textStorage.length == 1)
        #expect(model.textStorage.string == "\u{FFFC}")
        #expect(model.attachments.count == 1)
    }

    /// Deleting a chip's single character (one Backspace) removes it from the
    /// carousel — the "chip deleted mid-text" case.
    @Test func deletingChipMidTextUpdatesCarousel() {
        let model = ViewerFeedbackModel()
        // "a[#1]b[#2]c"
        model.textStorage.append(NSAttributedString(string: "a"))
        model.insertImage(image(), png: png(), at: NSRange(location: 1, length: 0))
        model.textStorage.append(NSAttributedString(string: "b"))
        model.insertImage(image(), png: png(.green), at: NSRange(location: 3, length: 0))
        model.textStorage.append(NSAttributedString(string: "c"))
        model.syncAttachments()
        #expect(model.attachments.map(\.number) == [1, 2])

        // Delete the FIRST chip (the one at index 1). One character.
        let range = try! #require(model.range(ofChip: model.attachments[0].id))
        model.textStorage.deleteCharacters(in: range)
        model.syncAttachments()

        // Only #2 remains, and its number did NOT shift down to 1.
        #expect(model.attachments.map(\.number) == [2])
        // The text is now "ab" + chip#2 + "c".
        #expect(model.textStorage.string == "ab\u{FFFC}c")
    }

    /// Chip numbers are stable, not positional: deleting #1 leaves #2 as #2 in
    /// both the text (its rendered label) and the carousel, so `[Image #2]`
    /// always points at the same thumbnail.
    @Test func chipNumbersStayStableAfterDeletion() {
        let model = ViewerFeedbackModel()
        model.insertImage(image(), png: png(), at: NSRange(location: 0, length: 0))
        model.insertImage(image(), png: png(.green), at: NSRange(location: 1, length: 0))
        model.insertImage(image(), png: png(.blue), at: NSRange(location: 2, length: 0))
        model.syncAttachments()
        #expect(model.attachments.map(\.number) == [1, 2, 3])

        // Delete the middle chip.
        let range = try! #require(model.range(ofChip: model.attachments[1].id))
        model.textStorage.deleteCharacters(in: range)
        model.syncAttachments()

        // The gap is preserved: 1, 3 — never renumbered to 1, 2.
        #expect(model.attachments.map(\.number) == [1, 3])

        // A new paste continues the monotonic sequence (4), never refilling 2.
        model.insertImage(image(), png: png(.yellow), at: NSRange(location: model.textStorage.length, length: 0))
        model.syncAttachments()
        #expect(model.attachments.map(\.number) == [1, 3, 4])
    }

    /// The segments handed to the report writer preserve document order and
    /// carry each chip's stable number.
    @Test func segmentsPreserveOrderAndNumbers() {
        let model = ViewerFeedbackModel()
        model.textStorage.append(NSAttributedString(
            string: "before ", attributes: ViewerFeedbackModel.typingAttributes))
        model.insertImage(image(), png: png(), at: NSRange(location: model.textStorage.length, length: 0))
        model.textStorage.append(NSAttributedString(
            string: " after", attributes: ViewerFeedbackModel.typingAttributes))
        model.syncAttachments()

        let segments = model.segments()
        #expect(segments == [
            .text("before "),
            .image(number: 1),
            .text(" after"),
        ])
    }

    /// After a delete, the report the composer would file has no dangling
    /// reference: segments and image payloads agree.
    @Test func imagePayloadsMatchRemainingChips() {
        let model = ViewerFeedbackModel()
        model.insertImage(image(), png: png(), at: NSRange(location: 0, length: 0))
        model.insertImage(image(), png: png(.green), at: NSRange(location: 1, length: 0))
        model.syncAttachments()
        let range = try! #require(model.range(ofChip: model.attachments[0].id))
        model.textStorage.deleteCharacters(in: range)
        model.syncAttachments()

        let payloadNumbers = Set(model.imagePayloads().map(\.number))
        let chipNumbers: Set<Int> = Set(model.segments().compactMap {
            if case .image(let n) = $0 { return n }
            return nil
        })
        #expect(payloadNumbers == chipNumbers)
    }

    /// Reset clears everything after a send.
    @Test func resetClearsComposer() {
        let model = ViewerFeedbackModel()
        model.textStorage.append(NSAttributedString(string: "text"))
        model.insertImage(image(), png: png(), at: NSRange(location: model.textStorage.length, length: 0))
        model.syncAttachments()
        #expect(!model.isEmpty)

        model.reset()
        #expect(model.isEmpty)
        #expect(model.attachments.isEmpty)
        #expect(model.textStorage.length == 0)
    }

    /// PNG re-encoding preserves the pixel resolution of a Retina screenshot
    /// (going through tiffRepresentation would silently halve it).
    @Test func pngEncodingPreservesPixelSize() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // A Retina image: 20x10 pixels shown at 10x5 points.
        let image = NSImage(size: NSSize(width: 10, height: 5))
        image.addRepresentation(rep)

        let data = try! #require(ViewerFeedbackTextView.pngData(from: image))
        let decoded = try! #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 20)
        #expect(decoded.pixelsHigh == 10)
    }
}

/// Send/cancel key routing on the composer's text view.
@MainActor
struct ViewerFeedbackTextViewTests {
    private func keyEvent(keyCode: UInt16, command: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: keyCode)!
    }

    @Test func cmdReturnIsSend() {
        #expect(ViewerFeedbackTextView.isSendShortcut(keyEvent(keyCode: 36, command: true)))
        #expect(ViewerFeedbackTextView.isSendShortcut(keyEvent(keyCode: 76, command: true)))
    }

    /// Plain Return is NOT send — it inserts a newline.
    @Test func plainReturnIsNotSend() {
        #expect(!ViewerFeedbackTextView.isSendShortcut(keyEvent(keyCode: 36, command: false)))
    }
}
