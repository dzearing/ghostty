import AppKit
import Testing
@testable import Ghostty

/// Pasting a screenshot must insert a chip. Uses a REAL private pasteboard
/// loaded exactly the way a Cmd-Shift-Ctrl-4 screenshot loads the general one
/// (TIFF + PNG data), so this reproduces the user-facing path rather than a
/// convenient stand-in.
@MainActor
@Suite(.serialized)
struct ViewerFeedbackPasteTests {
    private func makeScreenshotLikeImage() -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 40, height: 24))
        image.addRepresentation(rep)
        return image
    }

    /// A pasteboard carrying raw PNG data — what a screen capture actually
    /// puts there. NOT an NSImage object written via writeObjects, which is a
    /// friendlier shape than reality.
    private func pasteboardWithPNGData() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("ghoztty-feedback-paste-test"))
        pb.clearContents()
        let image = makeScreenshotLikeImage()
        let rep = image.representations.first as! NSBitmapImageRep
        let png = rep.representation(using: .png, properties: [:])!
        let tiff = image.tiffRepresentation!
        pb.setData(tiff, forType: .tiff)
        pb.setData(png, forType: .png)
        return pb
    }

    /// The reproduction: reading images off a screenshot-shaped pasteboard.
    @Test func imagesAreReadFromScreenshotPasteboard() {
        let pb = pasteboardWithPNGData()
        let images = ViewerFeedbackTextView.images(from: pb)
        #expect(images.count == 1, "no image read off a PNG+TIFF pasteboard")
        if let first = images.first {
            #expect(!first.1.isEmpty, "PNG encoding produced no bytes")
        }
    }

    /// End of the path: the chip actually lands in the storage.
    @Test func pasteInsertsChip() {
        let model = ViewerFeedbackModel()
        let layoutManager = NSLayoutManager()
        model.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = ViewerFeedbackTextView(frame: .zero, textContainer: container)
        textView.model = model
        textView.isRichText = true

        let handled = textView.pasteImagesFromPasteboard(pasteboardWithPNGData())
        #expect(handled, "paste was not handled as an image")
        #expect(model.attachments.count == 1)
        #expect(model.textStorage.string == "\u{FFFC}")
    }
}

/// Does the composer actually RECEIVE `paste:` the way Cmd-V delivers it?
/// The pure paste logic passes, so a user-visible "can't paste" failure has to
/// be focus/routing, not encoding.
@MainActor
@Suite(.serialized)
struct ViewerFeedbackPasteRoutingTests {
    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func makeRepo() throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", created.path, "init"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let file = created.appendingPathComponent("README.md")
        try "# x\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Opening the composer must put keyboard focus in the text view.
    @Test func openingComposerFocusesTextView() async throws {
        let file = try makeRepo()
        ViewerWorktreeCache.shared.invalidateAll()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: file.path)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        defer { window.contentView?.subviews.forEach { $0.removeFromSuperview() } }

        for _ in 0..<50 where viewer.worktree == nil { await wait(0.05) }
        #expect(viewer.worktree != nil, "precondition: worktree resolved")

        viewer.setFeedbackOpen(true)
        for _ in 0..<50 { await wait(0.05) }
        viewer.layoutSubtreeIfNeeded()

        let textView = ViewerView.firstTextView(in: viewer)
        #expect(textView != nil, "composer text view never mounted")
        if let textView {
            #expect(window.firstResponder === textView,
                    "text view is not first responder; got \(String(describing: window.firstResponder))")
        }
    }
}

/// Mechanism probe: `importsGraphics` decides whether image types appear in
/// `readablePasteboardTypes`, and NSTextView validates the Edit▸Paste menu
/// item against exactly that list. With images absent from it, Cmd-V is
/// DISABLED for an image-only pasteboard and the paste override never runs.
@MainActor
struct ViewerFeedbackPasteValidationTests {
    private func makeTextView(importsGraphics: Bool) -> ViewerFeedbackTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let c = NSTextContainer(size: NSSize(width: 300, height: 1e6))
        lm.addTextContainer(c)
        let tv = ViewerFeedbackTextView(frame: .zero, textContainer: c)
        tv.isRichText = true
        tv.importsGraphics = importsGraphics
        return tv
    }

    /// The composer advertises image types NO MATTER how `importsGraphics` is
    /// set. That flag alone does not put them in the list — measured — so
    /// relying on it is what left Cmd-V disabled for screenshots. The override
    /// is unconditional precisely so a future edit to the flag cannot silently
    /// disable pasting again.
    @Test func imageTypesAreReadableRegardlessOfImportsGraphics() {
        let imageTypes: Set<String> = [NSPasteboard.PasteboardType.png.rawValue,
                                       NSPasteboard.PasteboardType.tiff.rawValue]
        for flag in [false, true] {
            let types = Set(makeTextView(importsGraphics: flag)
                .readablePasteboardTypes.map(\.rawValue))
            #expect(!types.isDisjoint(with: imageTypes),
                    "image types missing with importsGraphics=\(flag); Cmd-V would be disabled")
        }
    }
}

/// Cmd-C/V/X/A (and undo/redo) must be recognized so the composer can service
/// them itself — the app's Edit menu ships those items WITHOUT key equivalents
/// (Cmd-C/V are terminal copy/paste on the surface), so an unclaimed shortcut
/// in a focused composer just beeps. This tests the pure key-mapping; the
/// routing (only while first responder) is exercised by the composer live.
@MainActor
struct ViewerFeedbackEditingShortcutTests {
    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    @Test func recognizesStandardEditingShortcuts() {
        let cmd: NSEvent.ModifierFlags = [.command]
        #expect(ViewerFeedbackTextView.editingCommand(for: keyEvent("c", cmd)) == .copy)
        #expect(ViewerFeedbackTextView.editingCommand(for: keyEvent("v", cmd)) == .paste)
        #expect(ViewerFeedbackTextView.editingCommand(for: keyEvent("x", cmd)) == .cut)
        #expect(ViewerFeedbackTextView.editingCommand(for: keyEvent("a", cmd)) == .selectAll)
        #expect(ViewerFeedbackTextView.editingCommand(for: keyEvent("z", cmd)) == .undo)
        #expect(ViewerFeedbackTextView.editingCommand(
            for: keyEvent("z", [.command, .shift])) == .redo)
    }

    @Test func ignoresNonEditingAndModifierMismatches() {
        // No command modifier: plain typing must never be swallowed.
        #expect(ViewerFeedbackTextView.editingCommand(for: keyEvent("c", [])) == nil)
        // The app's own composer shortcuts stay out of this path.
        #expect(ViewerFeedbackTextView.editingCommand(
            for: keyEvent("s", [.command, .shift])) == nil) // ⇧⌘S snapshot
        #expect(ViewerFeedbackTextView.editingCommand(
            for: keyEvent("\r", [.command])) == nil)        // ⌘↩ send
        // Control/option-carrying combos are not our editing shortcuts.
        #expect(ViewerFeedbackTextView.editingCommand(
            for: keyEvent("c", [.command, .control])) == nil)
        #expect(ViewerFeedbackTextView.editingCommand(
            for: keyEvent("v", [.command, .option])) == nil)
    }
}
