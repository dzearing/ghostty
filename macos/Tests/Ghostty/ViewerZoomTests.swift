import AppKit
import Testing
@testable import Ghostty

/// Classification of Cmd+/−/0 key events into viewer zoom actions, and the
/// clamped page-zoom stepping they drive. Pure logic — no live web view.
@MainActor
struct ViewerZoomTests {
    /// Build a key-equivalent NSEvent with the given base characters and mods.
    private func keyEvent(
        _ chars: String,
        _ mods: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: mods,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: 0)!
    }

    @Test func cmdEqualsAndPlusZoomIn() {
        #expect(ViewerView.zoomAction(for: keyEvent("=", .command)) == .zoomIn)
        // Shift+= produces "+"; charactersIgnoringModifiers keeps shift.
        #expect(ViewerView.zoomAction(for: keyEvent("+", [.command, .shift])) == .zoomIn)
    }

    @Test func cmdMinusZoomsOut() {
        #expect(ViewerView.zoomAction(for: keyEvent("-", .command)) == .zoomOut)
    }

    @Test func cmdZeroResets() {
        #expect(ViewerView.zoomAction(for: keyEvent("0", .command)) == .reset)
    }

    @Test func requiresCommandAndRejectsOptionOrControl() {
        // No command modifier at all.
        #expect(ViewerView.zoomAction(for: keyEvent("=", [])) == nil)
        // Command plus a disqualifying modifier.
        #expect(ViewerView.zoomAction(for: keyEvent("=", [.command, .option])) == nil)
        #expect(ViewerView.zoomAction(for: keyEvent("-", [.command, .control])) == nil)
    }

    @Test func unrelatedKeysAreNotZoom() {
        #expect(ViewerView.zoomAction(for: keyEvent("a", .command)) == nil)
        #expect(ViewerView.zoomAction(for: keyEvent("1", .command)) == nil)
    }

    @Test func steppingMovesByTheStepFactor() {
        #expect(ViewerView.steppedZoom(from: 1.0, action: .zoomIn) == 1.1)
        // Divide by the step factor for zoom out.
        #expect(abs(ViewerView.steppedZoom(from: 1.1, action: .zoomOut) - 1.0) < 0.0001)
        #expect(ViewerView.steppedZoom(from: 2.0, action: .reset) == 1.0)
    }

    @Test func steppingClampsToRange() {
        #expect(ViewerView.steppedZoom(from: ViewerView.maxZoom, action: .zoomIn) == ViewerView.maxZoom)
        #expect(ViewerView.steppedZoom(from: ViewerView.minZoom, action: .zoomOut) == ViewerView.minZoom)
    }
}
