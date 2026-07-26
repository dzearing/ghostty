import AppKit
import Testing
import WebKit
@testable import Ghostty

/// Cmd-R (reload) and Cmd-D (focus the address field) belong to a focused
/// viewer pane. Both override a global Ghoztty binding — `prompt_surface_banner`
/// and `new_split` respectively — so the classification has to be exact and the
/// gating has to be precise: a terminal pane (or an unfocused viewer split) in
/// the same window must keep the global behavior, because
/// `performKeyEquivalent` is offered to every view, not just the focused one.
@MainActor
struct ViewerPaneChordClassificationTests {
    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    @Test func recognizesReloadAndAddressChords() {
        #expect(ViewerView.paneChord(for: keyEvent("r", [.command])) == .reload)
        #expect(ViewerView.paneChord(for: keyEvent("d", [.command])) == .focusAddress)
        // Caps lock / a capital character still reads as the same chord.
        #expect(ViewerView.paneChord(for: keyEvent("R", [.command])) == .reload)
    }

    @Test func leavesShiftedAndUnmodifiedKeysAlone() {
        // Cmd+Shift+R is "Change Window Title"; Cmd+Shift+D splits down.
        #expect(ViewerView.paneChord(for: keyEvent("r", [.command, .shift])) == nil)
        #expect(ViewerView.paneChord(for: keyEvent("d", [.command, .shift])) == nil)
        // Plain typing is never a chord.
        #expect(ViewerView.paneChord(for: keyEvent("r", [])) == nil)
        // Control/option combos belong to something else.
        #expect(ViewerView.paneChord(for: keyEvent("r", [.command, .control])) == nil)
        #expect(ViewerView.paneChord(for: keyEvent("d", [.command, .option])) == nil)
    }

    @Test func unrelatedKeysAreNotPaneChords() {
        #expect(ViewerView.paneChord(for: keyEvent("c", [.command])) == nil)
        #expect(ViewerView.paneChord(for: keyEvent("=", [.command])) == nil)
    }
}

/// Live routing: the chords are consumed only while the viewer pane holds
/// keyboard focus, and Cmd-D really does land the caret in the address field
/// with the whole address selected.
@MainActor
@Suite(.serialized)
struct ViewerPaneChordRoutingTests {
    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    /// A viewer pane mounted beside a plain sibling view in an offscreen key
    /// window. The sibling stands in for a terminal split: focusing it must
    /// hand both chords back to their global bindings.
    private func makePane(location: String) -> (NSWindow, ViewerView, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: location)
        viewer.frame = NSRect(x: 0, y: 0, width: 450, height: 600)
        let sibling = FocusableView(frame: NSRect(x: 450, y: 0, width: 450, height: 600))
        window.contentView!.addSubview(viewer)
        window.contentView!.addSubview(sibling)
        viewer.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        return (window, viewer, sibling)
    }

    private func markdownFile() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-chord-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.md")
        try "# Doc\n\nbody\n".write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Cmd-D focuses the address field and selects the whole address, in a FILE
    /// viewer (the mode where the nav bar is easiest to forget about).
    @Test func cmdDFocusesAndSelectsTheAddressInAFileViewer() async throws {
        let (window, viewer, _) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        // The address the bar will show is only known once the file has
        // loaded; pressing Cmd-D before that would focus an empty field.
        for _ in 0..<150 where viewer.currentURL.isEmpty { await wait(0.02) }
        #expect(!viewer.currentURL.isEmpty, "file viewer never resolved an address")

        // Focus starts on the page, as it does after clicking into the pane.
        window.makeFirstResponder(viewer.webView)

        #expect(window.performKeyEquivalent(with: keyEvent("d", [.command])),
                "Cmd-D was not handled by the focused viewer pane")

        var editor: NSText?
        for _ in 0..<150 {
            await wait(0.02)
            viewer.layoutSubtreeIfNeeded()
            if let text = window.firstResponder as? NSText, !text.string.isEmpty {
                editor = text
                break
            }
        }
        let editorText = try #require(editor, "address field never took focus")
        #expect(editorText.string == viewer.currentURL,
                "address field did not show the pane's location")
        #expect(editorText.selectedRange.length == (editorText.string as NSString).length,
                "Cmd-D did not select the whole address")
    }

    /// Cmd-R is consumed by a focused viewer (it reloads in place) and handed
    /// back when the pane is not focused, so a terminal keeps "Set Pane Banner".
    @Test func cmdRIsConsumedOnlyWhileTheViewerIsFocused() async throws {
        let (window, viewer, sibling) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        window.makeFirstResponder(viewer.webView)
        #expect(window.performKeyEquivalent(with: keyEvent("r", [.command])),
                "Cmd-R was not handled by the focused viewer pane")

        // Focus a sibling (a terminal split, in the real window): both chords
        // must fall through to their global bindings.
        window.makeFirstResponder(sibling)
        #expect(!window.performKeyEquivalent(with: keyEvent("r", [.command])),
                "Cmd-R was swallowed while the viewer was NOT focused")
        #expect(!window.performKeyEquivalent(with: keyEvent("d", [.command])),
                "Cmd-D was swallowed while the viewer was NOT focused")
    }

    /// Escape must throw away a half-typed address (browser omnibox rule): the
    /// field goes back to showing where the pane actually IS, and focus returns
    /// to the page. Leaving the abandoned text in the field is a lie about the
    /// pane's location — only Return commits an edit.
    @Test func escapeRevertsAHalfTypedAddressAndReturnsFocusToThePage() async throws {
        let (window, viewer, _) = makePane(location: try markdownFile())
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        for _ in 0..<150 where viewer.currentURL.isEmpty { await wait(0.02) }
        let original = viewer.currentURL
        #expect(!original.isEmpty, "file viewer never resolved an address")

        window.makeFirstResponder(viewer.webView)
        #expect(window.performKeyEquivalent(with: keyEvent("d", [.command])))

        var editor: NSText?
        for _ in 0..<150 {
            await wait(0.02)
            viewer.layoutSubtreeIfNeeded()
            if let text = window.firstResponder as? NSText, !text.string.isEmpty {
                editor = text
                break
            }
        }
        let editorText = try #require(editor, "address field never took focus")

        // Type over the selected address, as a user would before changing
        // their mind. insertText (not `string =`) so the change notifies the
        // text field — that is what a real keystroke does, and what carries
        // the edit into the bar's SwiftUI binding.
        editorText.insertText("example.com/typed")
        for _ in 0..<50 where ViewerView.firstTextField(in: viewer)?.stringValue != "example.com/typed" {
            await wait(0.02)
        }
        #expect(ViewerView.firstTextField(in: viewer)?.stringValue == "example.com/typed",
                "precondition: the typed edit never reached the field")

        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        #expect(viewer.handleChromeKeyDown(escape),
                "Escape was not consumed while the address field was being edited")

        for _ in 0..<150 {
            await wait(0.02)
            viewer.layoutSubtreeIfNeeded()
            if ViewerView.firstTextField(in: viewer)?.stringValue == original { break }
        }
        #expect(ViewerView.firstTextField(in: viewer)?.stringValue == original,
                "Escape left the abandoned edit in the address field")
        #expect(window.firstResponder === viewer.webView,
                "Escape did not hand focus back to the page")
    }

    /// A viewer that is not in a window has no chrome bar to mount and so no
    /// address field: Cmd-D must report that it could not service the chord
    /// rather than swallowing the key.
    @Test func focusAddressBarReportsFailureWithNoAddressField() {
        let viewer = ViewerView(location: ViewerView.blankPage)
        #expect(!viewer.focusAddressBar(),
                "a windowless viewer claimed it could focus an address field")
    }
}

/// Minimal first-responder-taking view standing in for a terminal split.
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
