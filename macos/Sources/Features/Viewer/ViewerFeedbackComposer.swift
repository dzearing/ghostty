import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip attachment

/// A pasted image, rendered inline in the composer as an `[Image #N]` chip.
///
/// The chip is ONE `NSTextAttachment`, which occupies exactly one character
/// (`NSAttachmentCharacter`, U+FFFC) in the backing store. That is what makes
/// it genuinely atomic: selection, copy, caret traversal, and a single
/// Backspace all treat it as one unit because the storage layer has nothing
/// finer to address. No custom key handling is needed to achieve that — only
/// to react to it.
final class ViewerFeedbackChipAttachment: NSTextAttachment {
    let chipID: UUID
    /// The chip's display number. Assigned once at paste time and never
    /// reused or renumbered (see `ViewerFeedbackModel.nextNumber`).
    let number: Int

    init(chipID: UUID, number: Int) {
        self.chipID = chipID
        self.number = number
        super.init(data: nil, ofType: nil)
        attachmentCell = ViewerFeedbackChipCell(number: number)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Draws the `[Image #N]` chip.
///
/// A cell rather than a pre-rendered `NSImage` so the chip repaints in the
/// view's CURRENT appearance — a composer left open while the system flips to
/// dark mode would otherwise keep light-mode chips baked into its images.
final class ViewerFeedbackChipCell: NSTextAttachmentCell {
    private static let horizontalPadding: CGFloat = 7
    private static let verticalPadding: CGFloat = 2
    private static let cornerRadius: CGFloat = 4

    let number: Int

    init(number: Int) {
        self.number = number
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var label: String { "[Image #\(number)]" }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)]
    }

    override func cellSize() -> NSSize {
        let size = (label as NSString).size(withAttributes: labelAttributes)
        return NSSize(
            width: ceil(size.width) + Self.horizontalPadding * 2,
            height: ceil(size.height) + Self.verticalPadding * 2)
    }

    /// Sit the chip on the text baseline rather than hanging below it, so a
    /// line mixing prose and chips reads as one line of text.
    override func cellBaselineOffset() -> NSPoint {
        let font = labelAttributes[.font] as? NSFont
        return NSPoint(x: 0, y: (font?.descender ?? -3) - Self.verticalPadding)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        drawChip(in: cellFrame, controlView: controlView)
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        drawChip(in: cellFrame, controlView: controlView)
    }

    private func drawChip(in frame: NSRect, controlView: NSView?) {
        let render = {
            let path = NSBezierPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Self.cornerRadius,
                yRadius: Self.cornerRadius)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()

            var attributes = self.labelAttributes
            attributes[.foregroundColor] = NSColor.controlAccentColor
            let text = self.label as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: frame.minX + (frame.width - size.width) / 2,
                    y: frame.minY + (frame.height - size.height) / 2),
                withAttributes: attributes)
        }

        if let appearance = controlView?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }
    }
}

// MARK: - Model

/// A passage the user quoted out of the viewed page, with enough referential
/// context that a downstream agent can find what was being discussed.
///
/// Text alone is ambiguous — the same sentence can appear twice in a document
/// — so a quote carries its section, its containing block's full text, and its
/// offsets within both. `sourceLine` is filled in natively at send time for
/// file-backed viewers by locating the passage in the file on disk.
struct ViewerFeedbackQuote: Identifiable, Equatable {
    let id: UUID
    /// Display number, stable for the composer session (same rule as chips).
    let number: Int
    let text: String
    var headingID: String?
    var headingText: String?
    var blockSelector: String?
    var blockText: String?
    var offsetInBlock: Int?
    var documentOffset: Int?
    /// 1-based line in the source file, resolved at send time when the passage
    /// can be located there. Nil for web pages and unlocatable passages.
    var sourceLine: Int?

    init(number: Int, text: String) {
        self.id = UUID()
        self.number = number
        self.text = text
    }
}

/// Attribute marking a run of text as a quote block, valued with the quote's
/// id so the run can be mapped back to its reference metadata.
extension NSAttributedString.Key {
    static let feedbackQuoteID = NSAttributedString.Key("ghozttyFeedbackQuoteID")
}

/// The composer's contents for one viewer pane.
///
/// Owned by the `ViewerView`, NOT by the SwiftUI bar, so a half-written report
/// survives the toolbar being toggled closed and reopened (and survives the
/// pane being detached and re-attached by close/undo). The `NSTextStorage` is
/// the single source of truth for both the prose and which chips still exist —
/// the carousel is derived from it, never maintained in parallel.
@MainActor
final class ViewerFeedbackModel: ObservableObject {
    /// A pasted image that still has a chip in the text.
    struct Attachment: Identifiable, Equatable {
        let id: UUID
        let number: Int
        let image: NSImage
        let png: Data

        static func == (lhs: Attachment, rhs: Attachment) -> Bool { lhs.id == rhs.id }
    }

    enum Status: Equatable {
        case filed(String)
        case failed(String)
    }

    let textStorage = NSTextStorage()

    /// Chips currently present in the text, in document order. Recomputed from
    /// the storage after every edit, so deleting a chip removes its thumbnail
    /// without any separate bookkeeping.
    @Published private(set) var attachments: [Attachment] = []

    /// The chip the user last clicked or selected in the carousel.
    @Published var selectedChipID: UUID?

    /// Bumped to ask the carousel to scroll `selectedChipID` into view.
    @Published private(set) var scrollCarouselToken = 0
    /// Bumped to ask the text view to select and scroll to `selectedChipID`.
    @Published private(set) var revealChipToken = 0

    @Published var status: Status?

    /// Every image ever pasted, keyed by chip id. Kept across deletions so an
    /// undo (Cmd-Z) that restores a chip still has its image.
    private var pool: [UUID: Attachment] = [:]

    /// Every quote ever inserted, keyed by id. Like `pool`, retained across
    /// deletion so an undo that restores the run still has its references.
    private var quotePool: [UUID: ViewerFeedbackQuote] = [:]
    private var nextQuoteNumber = 1

    /// Quotes still present in the text, in document order.
    @Published private(set) var quotes: [ViewerFeedbackQuote] = []

    /// Paragraph style for a quote block: indented past the accent bar the
    /// text view draws, with air above and below so it reads as its own block.
    static var quoteParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 14
        style.headIndent = 14
        style.tailIndent = -6
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        return style
    }

    /// Insert a quote as its own block at `range`, returning the inserted range.
    ///
    /// Surrounded by newlines so it can never merge into the user's prose: a
    /// quote is a block, and half a line of it glued to a sentence would be
    /// neither quotable nor readable.
    @discardableResult
    func insertQuote(_ quote: ViewerFeedbackQuote, at range: NSRange) -> NSRange {
        quotePool[quote.id] = quote

        let existing = textStorage.string as NSString
        let needsLeadingNewline = range.location > 0
            && existing.substring(
                with: NSRange(location: range.location - 1, length: 1)) != "\n"

        var attributes = Self.typingAttributes
        attributes[.paragraphStyle] = Self.quoteParagraphStyle
        attributes[.feedbackQuoteID] = quote.id.uuidString
        attributes[.foregroundColor] = NSColor.secondaryLabelColor

        let block = NSMutableAttributedString()
        if needsLeadingNewline {
            block.append(NSAttributedString(
                string: "\n", attributes: Self.typingAttributes))
        }
        block.append(NSAttributedString(string: quote.text, attributes: attributes))
        // Trailing newline is PLAIN, so what the user types next is not
        // swallowed into the quote's styling.
        block.append(NSAttributedString(string: "\n", attributes: Self.typingAttributes))

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: block)
        textStorage.endEditing()
        syncAttachments()
        return NSRange(location: range.location, length: block.length)
    }

    /// Next chip number. Monotonic and never reset within a pane session:
    /// numbers are STABLE, not positional. Deleting `[Image #2]` leaves the
    /// sequence 1, 3 in both the text and the carousel — the two views agree
    /// because both read the same numbers off the same attachments. The
    /// alternative (renumber on delete) would mean rewriting every chip's
    /// rendered label after each edit, and any missed rewrite would leave
    /// `[Image #2]` pointing at the third thumbnail.
    private var nextNumber = 1

    var isEmpty: Bool {
        attachments.isEmpty
            && textStorage.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .isEmpty
    }

    /// The attributes new typing and pasted plain text take on.
    static var typingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    /// Insert a chip for `image` at `range`, returning the inserted range.
    @discardableResult
    func insertImage(_ image: NSImage, png: Data, at range: NSRange) -> NSRange {
        let id = UUID()
        let number = nextNumber
        nextNumber += 1
        pool[id] = Attachment(id: id, number: number, image: image, png: png)

        let attachment = ViewerFeedbackChipAttachment(chipID: id, number: number)
        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes(Self.typingAttributes, range: NSRange(location: 0, length: chip.length))

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: chip)
        textStorage.endEditing()
        syncAttachments()
        return NSRange(location: range.location, length: chip.length)
    }

    /// Recompute `attachments` from what is actually in the text storage.
    /// Call after every edit — this is what keeps the carousel honest.
    func syncAttachments() {
        var found: [Attachment] = []
        var seen = Set<UUID>()
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: full) { value, _, _ in
            guard let chip = value as? ViewerFeedbackChipAttachment,
                  let entry = pool[chip.chipID],
                  !seen.contains(chip.chipID)
            else { return }
            seen.insert(chip.chipID)
            found.append(entry)
        }
        if found != attachments || found.count != attachments.count {
            attachments = found
            if let selected = selectedChipID, !seen.contains(selected) {
                selectedChipID = nil
            }
        }
        syncQuotes()
    }

    /// Recompute `quotes` from the runs still carrying a quote attribute, so
    /// deleting a quote block drops its references from the report too.
    private func syncQuotes() {
        var found: [ViewerFeedbackQuote] = []
        var seen = Set<UUID>()
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.feedbackQuoteID, in: full) { value, _, _ in
            guard let raw = value as? String, let id = UUID(uuidString: raw),
                  let quote = quotePool[id], !seen.contains(id)
            else { return }
            seen.insert(id)
            found.append(quote)
        }
        guard found != quotes else { return }
        quotes = found
    }

    /// Next quote number (monotonic, never reused — same rule as chips).
    func takeQuoteNumber() -> Int {
        defer { nextQuoteNumber += 1 }
        return nextQuoteNumber
    }

    /// Update a quote's resolved references (the source line found at send
    /// time). Returns the updated list.
    func quotesWithSourceLines(_ lines: [UUID: Int]) -> [ViewerFeedbackQuote] {
        quotes.map { quote in
            var copy = quote
            copy.sourceLine = lines[quote.id]
            return copy
        }
    }

    /// The character range of a chip in the text, or nil if it is gone.
    func range(ofChip id: UUID) -> NSRange? {
        var result: NSRange?
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: full) { value, range, stop in
            if let chip = value as? ViewerFeedbackChipAttachment, chip.chipID == id {
                result = range
                stop.pointee = true
            }
        }
        return result
    }

    /// A chip was clicked in the text: select it and scroll the carousel to it.
    func chipClicked(_ id: UUID) {
        selectedChipID = id
        scrollCarouselToken += 1
    }

    /// A thumbnail was clicked: select it and reveal its chip in the text.
    func thumbnailClicked(_ id: UUID) {
        selectedChipID = id
        revealChipToken += 1
    }

    /// The composed message as ordered segments, ready for the report writer.
    ///
    /// Walks the storage once, splitting at every chip AND every quote run, so
    /// the body preserves the order the user actually wrote things in.
    func segments() -> [ViewerFeedbackReport.Segment] {
        var segments: [ViewerFeedbackReport.Segment] = []
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            segments.append(.text(pending))
            pending = ""
        }

        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttributes(in: full) { attributes, range, _ in
            let piece = textStorage.attributedSubstring(from: range).string
            if let chip = attributes[.attachment] as? ViewerFeedbackChipAttachment {
                flush()
                segments.append(.image(number: chip.number))
                return
            }
            if let raw = attributes[.feedbackQuoteID] as? String,
               let id = UUID(uuidString: raw), let quote = quotePool[id] {
                flush()
                segments.append(.quote(number: quote.number, text: piece))
                return
            }
            pending += piece
        }
        flush()
        return segments
    }

    /// The images still referenced by a chip, ready for the report writer.
    func imagePayloads() -> [ViewerFeedbackReport.Image] {
        attachments.map { attachment in
            let rep = NSBitmapImageRep(data: attachment.png)
            return ViewerFeedbackReport.Image(
                number: attachment.number,
                png: attachment.png,
                pixelWidth: rep?.pixelsWide ?? 0,
                pixelHeight: rep?.pixelsHigh ?? 0)
        }
    }

    /// Empty the composer after a successful send. The number counter is NOT
    /// reset — a fresh report starts at #1 only because its chips are gone,
    /// and reusing numbers across reports in one session would make the
    /// pane's own history ambiguous if the user scrolls back through undo.
    func reset() {
        textStorage.beginEditing()
        textStorage.setAttributedString(NSAttributedString(string: ""))
        textStorage.endEditing()
        pool.removeAll()
        nextNumber = 1
        selectedChipID = nil
        syncAttachments()
    }
}

// MARK: - Text view

/// The composer's text view.
///
/// `Enter` inserts a newline (NSTextView's default when it is not a field
/// editor); `Cmd-Enter` sends; `Escape` closes. Pasting an image inserts a
/// chip at the caret instead of an editable image.
final class ViewerFeedbackTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    var onChipClick: ((UUID) -> Void)?
    weak var model: ViewerFeedbackModel?

    /// Cmd-Return reaches a view through `performKeyEquivalent` before
    /// `keyDown`, because AppKit routes command-modified keys as key
    /// equivalents first. Handling it here is what makes it fire at all.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isSendShortcut(event) {
            onSend?()
            return true
        }
        if Self.isSnapshotShortcut(event) {
            captureScreenshot()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Paint quote blocks: a soft background panel with an accent bar down the
    /// left edge, so a quoted passage reads as quoted rather than as more
    /// prose. Drawn here (behind the glyphs) rather than as a background-color
    /// attribute, which paints only tight line boxes with no bar and no
    /// rounding.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0
        else { return }

        let origin = textContainerOrigin
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.feedbackQuoteID, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += origin.x
            box.origin.y += origin.y
            // Full-width panel: a quote is a block, so the backdrop should not
            // stop at the ragged right edge of its last line.
            box.origin.x = origin.x
            box.size.width = container.size.width - origin.x
            box = box.insetBy(dx: 0, dy: -2)

            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()

            let bar = NSRect(x: box.minX + 1, y: box.minY, width: 3, height: box.height)
            NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func keyDown(with event: NSEvent) {
        if Self.isSendShortcut(event) {
            onSend?()
            return
        }
        if Self.isSnapshotShortcut(event) {
            captureScreenshot()
            return
        }
        super.keyDown(with: event)
    }

    static func isSendShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        // Return (36) and the numeric keypad's Enter (76).
        return event.keyCode == 36 || event.keyCode == 76
    }

    /// ⇧⌘S — add a screenshot without leaving the keyboard.
    ///
    /// Chosen because it collides with nothing: the app's shift+cmd letters are
    /// t/z/w/d/f/g/v/n/r/[/], macOS's own capture shortcuts are ⇧⌘3/4/5, and
    /// this is only handled while the composer has focus, so it cannot shadow
    /// anything elsewhere in the app.
    static func isSnapshotShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.shift),
              !flags.contains(.option), !flags.contains(.control)
        else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "s"
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Paste an image from the clipboard as a chip; paste anything else as
    /// plain text (the composer's content model is prose plus chips — styled
    /// runs pasted from a browser would serialize to nothing meaningful).
    override func paste(_ sender: Any?) {
        if pasteImagesFromPasteboard() { return }
        pasteAsPlainText(sender)
    }

    /// Image types must appear here or Cmd-V is DEAD for a screenshot.
    ///
    /// AppKit validates the Edit▸Paste menu item against this list, so when it
    /// omits image types an image-only clipboard leaves the item DISABLED —
    /// the keystroke never dispatches and `paste(_:)` above never runs. That
    /// was the original "can't paste images" bug. Declaring the types
    /// explicitly (rather than trusting `importsGraphics`, which does not put
    /// them here) is what actually enables the command.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for type in [NSPasteboard.PasteboardType.png, .tiff, .fileURL]
        where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    /// Belt and braces for the same failure: some menu paths validate through
    /// here instead. An image on the pasteboard always enables Paste.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.paste(_:)),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Screenshots arrive as image data; a file dragged from Finder arrives as
    /// a file URL. Both are handled — a URL that is not an image falls
    /// through to a plain-text paste of the path.
    @discardableResult
    func pasteImagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let model else { return false }
        let images = Self.images(from: pasteboard)
        guard !images.isEmpty else { return false }

        var range = selectedRange()
        for (image, png) in images {
            let inserted = model.insertImage(image, png: png, at: range)
            range = NSRange(location: inserted.location + inserted.length, length: 0)
        }
        setSelectedRange(range)
        didChangeText()
        return true
    }

    /// Image + PNG encoding for every image on the pasteboard.
    ///
    /// The PNG is produced up front rather than at send time so the report
    /// writer never has to re-encode, and so a paste that cannot be encoded
    /// is rejected while the user is still looking at the composer.
    static func images(from pasteboard: NSPasteboard) -> [(NSImage, Data)] {
        let objects = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]])
        guard let images = objects as? [NSImage], !images.isEmpty else { return [] }
        return images.compactMap { image in
            guard let png = pngData(from: image) else { return nil }
            return (image, png)
        }
    }

    /// Re-encode any image representation as PNG.
    ///
    /// Going through a fresh `NSBitmapImageRep` sized in PIXELS (not points)
    /// is deliberate: `NSImage.tiffRepresentation` on a Retina screenshot
    /// yields a point-sized bitmap, which silently halves the resolution of
    /// every screenshot pasted on this machine.
    static func pngData(from image: NSImage) -> Data? {
        let pixelWidth = image.representations.map(\.pixelsWide).max() ?? 0
        let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1.0)
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// A click on a chip selects it and reveals its thumbnail. The click is
    /// still forwarded so the caret lands where AppKit would put it.
    override func mouseDown(with event: NSEvent) {
        if let id = chipID(at: event) { onChipClick?(id) }
        super.mouseDown(with: event)
    }

    /// Take an interactive screen snapshot and insert it as a chip.
    ///
    /// Captures to a temp FILE rather than `screencapture -c` (clipboard) on
    /// purpose: the user's clipboard is theirs, and silently overwriting it to
    /// implement our own button would destroy whatever they had copied.
    /// `-i` is interactive region select, `-o` drops the window shadow.
    /// Escaping the capture writes no file and inserts nothing.
    func captureScreenshot(completion: (() -> Void)? = nil) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghoztty-feedback-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-o", url.path]
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion?() }
                return
            }
            process.waitUntilExit()

            let data = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                defer { completion?() }
                // Cancelled selection ⇒ no file ⇒ nothing to insert.
                guard let self, let data, !data.isEmpty,
                      let image = NSImage(data: data) else { return }
                guard let model = self.model else { return }
                let range = self.selectedRange()
                let inserted = model.insertImage(image, png: data, at: range)
                self.setSelectedRange(
                    NSRange(location: inserted.location + inserted.length, length: 0))
                self.didChangeText()
                self.window?.makeFirstResponder(self)
            }
        }
    }

    /// The chip under a mouse event, if any.
    func chipID(at event: NSEvent) -> UUID? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0
        else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: inContainer, in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let chip = storage.attribute(.attachment, at: index, effectiveRange: nil)
        return (chip as? ViewerFeedbackChipAttachment)?.chipID
    }
}
