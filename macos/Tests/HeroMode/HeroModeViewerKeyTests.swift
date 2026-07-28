import AppKit
import Testing
@testable import Ghostty

/// A focused viewer pane must not let its inner WKWebView also react to the
/// hero-navigation chord (Cmd+Shift+Up/Down).
///
/// Hero mode navigates with an app-wide key monitor that consumes the chord,
/// but a viewer's first responder is a WKWebView that receives the keystroke
/// anyway: it beeped on the unhandled key AND re-injected the event, so the
/// monitor fired twice and the selection double-stepped (skipped a pane).
/// `ViewerView.performKeyEquivalent` swallows the chord before WebKit sees it.
@MainActor
struct HeroModeViewerKeyTests {
    private func makeViewer() throws -> ViewerView {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-viewer-key-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.md")
        try "# doc".write(to: file, atomically: true, encoding: .utf8)
        return ViewerView(location: file.path)
    }

    /// Build a key-equivalent event. For arrows, `characters` must be the
    /// function-key scalar so `event.specialKey` resolves (mirrors the harness
    /// in `HeroModeKeyNavigationTests`).
    private func keyEvent(
        _ special: NSEvent.SpecialKey? = nil,
        character: String = "x",
        keyCode: UInt16 = 0,
        _ mods: NSEvent.ModifierFlags
    ) -> NSEvent {
        let characters = special.map { String($0.unicodeScalar) } ?? character
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: mods,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode)!
    }

    // MARK: - isHeroNavChord

    @Test func recognizesCmdShiftUpDown() {
        #expect(ViewerView.isHeroNavChord(keyEvent(.upArrow, keyCode: 126, [.command, .shift])))
        #expect(ViewerView.isHeroNavChord(keyEvent(.downArrow, keyCode: 125, [.command, .shift])))
        // Extra flags AppKit sets on arrow keys must not matter.
        #expect(ViewerView.isHeroNavChord(
            keyEvent(.upArrow, keyCode: 126, [.command, .shift, .function, .numericPad])))
    }

    @Test func rejectsNonNavChords() {
        // Missing a required modifier.
        #expect(!ViewerView.isHeroNavChord(keyEvent(.upArrow, keyCode: 126, [.command])))
        #expect(!ViewerView.isHeroNavChord(keyEvent(.upArrow, keyCode: 126, [.shift])))
        #expect(!ViewerView.isHeroNavChord(keyEvent(.upArrow, keyCode: 126, [])))
        // Wrong arrows: left/right are swap_split, not hero nav.
        #expect(!ViewerView.isHeroNavChord(keyEvent(.leftArrow, keyCode: 123, [.command, .shift])))
        #expect(!ViewerView.isHeroNavChord(keyEvent(.rightArrow, keyCode: 124, [.command, .shift])))
        // A letter with the same modifiers (e.g. Cmd+Shift+D = new_split).
        #expect(!ViewerView.isHeroNavChord(keyEvent(character: "d", keyCode: 2, [.command, .shift])))
    }

    // MARK: - performKeyEquivalent

    /// The chord is swallowed (returns true) so WebKit never processes it —
    /// this is what stops the beep and the double-step on a viewer pane.
    @Test func swallowsHeroNavChord() throws {
        let viewer = try makeViewer()
        #expect(viewer.performKeyEquivalent(with: keyEvent(.upArrow, keyCode: 126, [.command, .shift])))
        #expect(viewer.performKeyEquivalent(with: keyEvent(.downArrow, keyCode: 125, [.command, .shift])))
    }
}
