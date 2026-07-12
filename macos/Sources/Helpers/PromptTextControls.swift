import AppKit

/// Standard edit-menu key equivalents (⌘V/⌘C/⌘X/⌘A/⌘Z/⇧⌘Z) handled locally
/// by prompt text controls.
///
/// Ghostty's Edit menu items deliberately have no key equivalents for
/// copy/paste: those bindings are `performable`, so the terminal surface
/// decides at runtime whether to consume the key, and a menu shortcut would
/// consume it unconditionally (see `Binding.Set.putFlags` track_reverse and
/// `MenuShortcutManager`). The side effect is that text fields in modal
/// prompts (NSAlert accessory views) never receive ⌘V etc. through the
/// menu — so the controls below implement the standard equivalents
/// themselves.
enum EditKeyEquivalent {
    /// Handle a standard edit key equivalent against the given text
    /// responder. Returns true if the event was handled.
    static func handle(_ event: NSEvent, in text: NSText) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (key, mods) {
        case ("v", [.command]):
            text.paste(nil)
        case ("c", [.command]):
            text.copy(nil)
        case ("x", [.command]):
            text.cut(nil)
        case ("a", [.command]):
            text.selectAll(nil)
        case ("z", [.command]):
            guard let undo = text.undoManager, undo.canUndo else { return false }
            undo.undo()
        case ("z", [.command, .shift]):
            guard let undo = text.undoManager, undo.canRedo else { return false }
            undo.redo()
        default:
            return false
        }
        return true
    }
}

/// Single-line text field for alert prompts that handles standard edit key
/// equivalents itself. See `EditKeyEquivalent`.
class PromptTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor = currentEditor(), EditKeyEquivalent.handle(event, in: editor) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Multi-line text view for alert prompts that handles standard edit key
/// equivalents itself. See `EditKeyEquivalent`.
class PromptTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditKeyEquivalent.handle(event, in: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Build a multi-line prompt editor wrapped in a bordered scroll view,
    /// sized for use as an NSAlert accessory view.
    static func scrollablePrompt(width: CGFloat, height: CGFloat) -> (NSScrollView, PromptTextView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let textView = PromptTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        scroll.documentView = textView

        return (scroll, textView)
    }
}
