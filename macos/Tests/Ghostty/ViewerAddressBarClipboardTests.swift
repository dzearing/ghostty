import AppKit
import Testing
import WebKit
@testable import Ghostty

/// Standard editing chords (Cmd-C/V/X/A) must reach the viewer's address field
/// so it behaves like a normal macOS text input. They otherwise don't:
/// `performKeyEquivalent` is offered to EVERY view in the pane, so the sibling
/// WKWebView (and, in a split, a focused terminal surface) claims these keys
/// during the view-tree walk — before the Edit menu could route
/// `copy:`/`paste:`/… to the focused field.
///
/// These are the pure key→selector classification tests; the live routing is
/// exercised by `ViewerAddressBarClipboardRoutingTests`.
@MainActor
struct ViewerAddressBarEditingSelectorTests {
    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    @Test func recognizesStandardEditingChords() {
        let cmd: NSEvent.ModifierFlags = [.command]
        #expect(ViewerView.editingSelector(for: keyEvent("c", cmd))
            == #selector(NSText.copy(_:)))
        #expect(ViewerView.editingSelector(for: keyEvent("v", cmd))
            == #selector(NSText.paste(_:)))
        #expect(ViewerView.editingSelector(for: keyEvent("x", cmd))
            == #selector(NSText.cut(_:)))
        #expect(ViewerView.editingSelector(for: keyEvent("a", cmd))
            == #selector(NSText.selectAll(_:)))
    }

    @Test func ignoresNonEditingAndModifierMismatches() {
        // Plain typing must never be swallowed.
        #expect(ViewerView.editingSelector(for: keyEvent("c", [])) == nil)
        // Zoom chords (Cmd-=/-/0) belong to the viewer, not this path.
        #expect(ViewerView.editingSelector(for: keyEvent("=", [.command])) == nil)
        #expect(ViewerView.editingSelector(for: keyEvent("0", [.command])) == nil)
        // Control/option/shift-carrying combos are not our editing chords.
        #expect(ViewerView.editingSelector(for: keyEvent("c", [.command, .control])) == nil)
        #expect(ViewerView.editingSelector(for: keyEvent("v", [.command, .option])) == nil)
        #expect(ViewerView.editingSelector(for: keyEvent("a", [.command, .shift])) == nil)
    }
}

/// The reproduction: with the address field focused, a Cmd-C key equivalent
/// must copy the field's selection. Before the fix nothing in the view-tree
/// walk services copy for the focused field (the menu route that would has
/// already been preempted by a sibling view), so the pasteboard stays empty.
@MainActor
@Suite(.serialized)
struct ViewerAddressBarClipboardRoutingTests {
    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    /// Focus the address field of a blank browser viewer mounted in `window`,
    /// returning its field editor primed with `text` fully selected. The window
    /// is made key because a text field only vends a field editor while its
    /// window is key.
    private func focusedAddressEditor(
        in window: NSWindow, viewer: ViewerView, text: String
    ) async -> NSText? {
        window.makeKeyAndOrderFront(nil)
        viewer.focusAddressBar()
        var editor: NSText?
        await poll {
            viewer.layoutSubtreeIfNeeded()
            guard let field = ViewerView.firstTextField(in: viewer) else { return false }
            window.makeFirstResponder(field)
            guard let current = field.currentEditor() else { return false }
            editor = current
            return true
        }
        guard let editor else { return nil }
        editor.string = text
        editor.selectedRange = NSRange(location: 0, length: (text as NSString).length)
        return editor
    }

    @Test func editingChordsReachTheFocusedAddressField() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: ViewerView.blankPage)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        let address = "https://example.com/some/path"
        let editor = await focusedAddressEditor(in: window, viewer: viewer, text: address)
        #expect(editor != nil, "address field never became first responder")
        #expect(window.firstResponder is NSText,
                "field editor is not first responder; got \(String(describing: window.firstResponder))")
        guard let editor else { return }

        // Cmd-A must reach the field editor. Asserted via the resulting selection
        // rather than the pasteboard (which `copy:` would use) so the test is
        // deterministic and does not race other tests over the shared clipboard.
        editor.selectedRange = NSRange(location: 0, length: 0)
        let selectedAll = window.performKeyEquivalent(with: keyEvent("a", [.command]))
        #expect(selectedAll, "Cmd-A was not handled while the address field was focused")
        #expect(editor.selectedRange.length == (address as NSString).length,
                "Cmd-A did not select the whole address")

        // Cmd-C is likewise routed to (and serviced by) the field editor.
        #expect(window.performKeyEquivalent(with: keyEvent("c", [.command])),
                "Cmd-C was not routed to the focused address field")
    }

    /// Submitting a URL must hand keyboard focus to the page (like a browser
    /// omnibox), not leave it stuck on the address field. If focus stays, a
    /// later click into the field is "already focused" and never re-selects the
    /// address.
    @Test func submittingAddressMovesFocusToThePage() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: ViewerView.blankPage)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        let editor = await focusedAddressEditor(in: window, viewer: viewer, text: "")
        #expect(editor != nil, "address field never became first responder")
        #expect(window.firstResponder is NSText, "precondition: address field focused")

        viewer.navigate(to: "https://example.com")
        #expect(window.firstResponder === viewer.webView,
                "focus did not move to the page after submitting the address; got \(String(describing: window.firstResponder))")
    }
}

/// Clicking into the address field must select the whole address every time it
/// GAINS focus — including after focus was on the web content. The regression:
/// clicking the web page moves first responder to the WKWebView, which SwiftUI's
/// @FocusState never observes, so a later click into the field is not seen as a
/// focus change and select-all silently stops firing.
@MainActor
@Suite(.serialized)
struct ViewerAddressBarFocusClickTests {
    @Test func clickSelectsAddressWhenGainingFocusFromWebContent() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: ViewerView.blankPage)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        // Mount + lay out the chrome bar so the address field has a real frame.
        // Poll for the mounted bar rather than sleeping a fixed span: an
        // offscreen window is never key, so the field loses focus shortly
        // after taking it and the bar's 2s auto-hide follows — which would
        // leave `addressClickSelectsAll` (it requires visible chrome)
        // answering false for reasons that have nothing to do with clicks.
        var field: NSTextField?
        window.makeKeyAndOrderFront(nil)
        viewer.focusAddressBar()
        await poll {
            viewer.layoutSubtreeIfNeeded()
            guard viewer.chromeVisible,
                  let mounted = ViewerView.firstTextField(in: viewer),
                  mounted.convert(mounted.bounds, to: viewer).width > 0
            else { return false }
            field = mounted
            return true
        }
        guard let field else { #expect(Bool(false), "address field never mounted"); return }
        let frame = field.convert(field.bounds, to: viewer)
        let inField = NSPoint(x: frame.midX, y: frame.midY)
        let inPage = NSPoint(x: viewer.bounds.midX, y: viewer.bounds.height * 0.25)

        // Focus is on the web content (as after clicking the page). A click into
        // the field is a focus-gaining click → should select the whole address.
        window.makeFirstResponder(viewer.webView)
        #expect(viewer.addressClickSelectsAll(at: inField),
                "click into unfocused address field did not trigger select-all")

        // The same click when the field ALREADY holds focus just places the
        // caret — must NOT re-select.
        window.makeFirstResponder(field)
        #expect(!viewer.addressClickSelectsAll(at: inField),
                "click into already-focused field wrongly triggered select-all")

        // A click in the page body is never an address selection.
        window.makeFirstResponder(viewer.webView)
        #expect(!viewer.addressClickSelectsAll(at: inPage),
                "click in the page body wrongly triggered address select-all")
    }
}

/// The web page itself — not just the address field — must copy/paste. When the
/// viewer's web content holds focus, the standard editing chords have to reach
/// that focused element. They otherwise don't: Ghoztty binds Cmd-C/V to
/// terminal copy/paste on the surface, so the Edit menu carries no plain
/// Cmd-C/V equivalent to route `copy:`/`paste:` to an ordinary responder, and a
/// focused web page is left with no handler.
@MainActor
@Suite(.serialized)
struct ViewerWebContentClipboardTests {
    private func keyEvent(
        _ chars: String, _ flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0)!
    }

    /// Editing chords aimed at the focused web content must reach it. The
    /// selectable web content is stood in for by a real `NSTextView` parented
    /// INSIDE the web view — `isViewerContentFocused` treats it exactly as it
    /// treats real page content (a descendant of the web view). Asserted via the
    /// resulting selection rather than the pasteboard so the test is
    /// deterministic and does not race the shared clipboard.
    @Test func editingChordsReachTheFocusedWebContent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        let viewer = ViewerView(location: ViewerView.blankPage)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        viewer.layoutSubtreeIfNeeded()
        defer {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            window.orderOut(nil)
        }

        let content = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        content.string = "selected web text"
        viewer.webView.addSubview(content)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        content.selectedRange = NSRange(location: 0, length: 0)
        #expect(window.firstResponder === content,
                "web-content stand-in did not become first responder")

        let selectedAll = window.performKeyEquivalent(with: keyEvent("a", [.command]))
        #expect(selectedAll, "Cmd-A was not handled while web content was focused")
        #expect(content.selectedRange.length == (content.string as NSString).length,
                "Cmd-A did not reach the focused web content")

        // Cmd-C is likewise routed to (and serviced by) the web content.
        #expect(window.performKeyEquivalent(with: keyEvent("c", [.command])),
                "Cmd-C was not routed to the focused web content")
    }
}
