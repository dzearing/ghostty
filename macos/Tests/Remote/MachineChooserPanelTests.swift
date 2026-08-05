import AppKit
import Testing
@testable import Ghostty

/// The chooser panel's responder-chain contract.
///
/// The "Close" (Cmd-W) and "Close Window" (Cmd-Shift-W) menu items are wired to
/// the FIRST RESPONDER, so whichever object in the key window's action chain
/// answers `close:` first wins — and if nothing in the chooser's chain does,
/// AppKit walks on into the MAIN window and closes the terminal behind the
/// dialog instead. A panel can't become main, so that fallback always had a
/// victim. These assert the chooser answers for itself.
@MainActor
struct MachineChooserPanelTests {
    @Test func closeActionDismissesTheChooser() {
        var closed = false
        let delegate = MachineChooserPanelDelegate { closed = true }
        delegate.close(self)
        #expect(closed)
    }

    @Test func closeWindowActionDismissesTheChooser() {
        var closed = false
        let delegate = MachineChooserPanelDelegate { closed = true }
        delegate.closeWindow(self)
        #expect(closed)
    }

    /// Responding to the selector is the half AppKit actually checks: it stops
    /// its `targetForAction:` search at the first responder that does. Losing
    /// either method — by rename, or by dropping `@IBAction`/`@objc` — silently
    /// restores the "closes the window behind" bug, which is why this asserts
    /// the ObjC-visible selectors rather than just calling the Swift methods.
    @Test func panelDelegateAnswersBothCloseSelectors() {
        let delegate = MachineChooserPanelDelegate {}
        #expect(delegate.responds(to: NSSelectorFromString("close:")))
        #expect(delegate.responds(to: NSSelectorFromString("closeWindow:")))
    }
}
