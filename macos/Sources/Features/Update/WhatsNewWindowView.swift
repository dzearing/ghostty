import AppKit
import SwiftUI

/// The post-install "What's New" window body. Tabs between client/app notes and
/// agent/session notes — both bundled offline and partitioned by the version
/// the user last ran. Reuses `WhatsNewNotesContent` for each tab, so the two
/// tabs can never drift apart.
struct WhatsNewWindowView: View {
    let clientNew: [VersionNotes]
    let clientInstalled: [VersionNotes]
    let agentNew: [VersionNotes]
    let agentInstalled: [VersionNotes]

    var body: some View {
        TabView {
            tab(new: clientNew, installed: clientInstalled)
                .tabItem { Text("Client") }
            tab(new: agentNew, installed: agentInstalled)
                .tabItem { Text("Agent") }
        }
        .padding(12)
    }

    @ViewBuilder
    private func tab(new: [VersionNotes], installed: [VersionNotes]) -> some View {
        ScrollView {
            WhatsNewNotesContent(newNotes: new, installedNotes: installed, density: .spacious)
                .padding(20)
        }
    }
}

// MARK: - Window chrome

extension WhatsNewWindowView {
    /// The content size the window opens at, before clamping to the screen.
    static let defaultContentSize = NSSize(width: 700, height: 740)

    /// How far down the window can be dragged. Below this the notes stop being
    /// readable, but it is well under `defaultContentSize` so the resize
    /// control has somewhere to go.
    static let minimumContentSize = NSSize(width: 420, height: 320)

    /// Build the window that hosts the notes: resizable, opened at a generous
    /// default size, centred on `screen`.
    ///
    /// The size lives here rather than in a `.frame` on the SwiftUI body. A
    /// fixed frame is what pinned the old window to 460×380 and left the resize
    /// control with nothing to do, and it also defeats centring: sizing has to
    /// happen BEFORE the origin is computed, or the window is centred as the
    /// zero-size frame it still has and lands off to one side.
    @MainActor
    static func makeWindow(
        _ view: WhatsNewWindowView,
        screen: NSScreen? = NSScreen.main
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        // Let the window drive the size, not SwiftUI's fitting size — the
        // default (`.preferredContentSize`) pushes the content's ideal size
        // back onto the window and re-pins it.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "What’s New in Ghoztty"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumContentSize
        window.setContentSize(defaultContentSize)

        if let screen {
            window.setFrame(openingFrame(size: window.frame.size, in: screen.visibleFrame),
                            display: false)
        } else {
            window.center()
        }
        return window
    }

    /// A window of `size`, clamped to `visible` and centred in it. Clamping
    /// keeps a tall default from opening with its bottom off a short display.
    static func openingFrame(size: NSSize, in visible: NSRect) -> NSRect {
        let clamped = NSSize(width: min(size.width, visible.width),
                             height: min(size.height, visible.height))
        return NSRect(x: visible.midX - clamped.width / 2,
                      y: visible.midY - clamped.height / 2,
                      width: clamped.width,
                      height: clamped.height)
    }
}
