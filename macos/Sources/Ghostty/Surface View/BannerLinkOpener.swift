#if canImport(AppKit)
import AppKit

/// The standard set of actions for a clickable banner link, plus the
/// right-click menu that exposes them. Kept as one component so link behavior
/// is consistent wherever banner links render — and so other link surfaces
/// (terminal, viewer) can adopt the same menu later.
///
/// Everything is resolved from a weak anchor surface at action time: the
/// window's `BaseTerminalController` (for the `ghostty` app instance and viewer
/// splits) and the surface's working directory (viewer provenance). With no
/// anchor or controller, every action falls back to the system browser so a
/// link is never dead.
@MainActor
struct BannerLinkOpener {
    /// The pane the banner belongs to; supplies the controller and the viewer
    /// origin directory. Weak so the opener never keeps a pane alive.
    weak var surface: Ghostty.SurfaceView?

    private var controller: BaseTerminalController? {
        surface?.window?.windowController as? BaseTerminalController
    }

    /// Cmd-click: open the URL in a new Ghoztty viewer window — the same
    /// one-pane viewer tree the CLI `+new-window --view=<url>` builds.
    func openInNewWindow(_ url: URL) {
        guard let controller else { openInDefaultBrowser(url); return }
        let pane = PaneView(viewer: ViewerView(
            location: url.absoluteString,
            originDirectory: surface?.pwd))
        _ = TerminalController.newWindow(
            controller.ghostty,
            tree: SplitTree<PaneView>(root: .leaf(view: pane), zoomed: nil))
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Left-click default: open the URL in a viewer split beside the banner's
    /// pane — the same thing `+split --view=<url>` does.
    func openInSidePane(_ url: URL) {
        guard let controller, let surface else { openInDefaultBrowser(url); return }
        controller.newViewerSplit(
            at: surface,
            direction: .right,
            viewer: ViewerView(location: url.absoluteString, originDirectory: surface.pwd))
    }

    /// Cmd-Shift-click / menu: hand the URL to the system default browser.
    func openInDefaultBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Copy the URL to the general pasteboard.
    func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// The right-click menu for a link, in standard order (the first item is
    /// the left-click default).
    func menu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open in Side Pane", symbol: "sidebar.right", url) { openInSidePane($0) })
        menu.addItem(item("Open in New Window", symbol: "macwindow", url) { openInNewWindow($0) })
        menu.addItem(.separator())
        menu.addItem(item("Open in Default Browser", symbol: "safari", url) { openInDefaultBrowser($0) })
        menu.addItem(.separator())
        menu.addItem(item("Copy Link", symbol: "doc.on.doc", url) { copy($0) })
        return menu
    }

    private func item(
        _ title: String,
        symbol: String,
        _ url: URL,
        _ action: @escaping (URL) -> Void
    ) -> NSMenuItem {
        let target = BannerLinkMenuTarget { action(url) }
        let item = NSMenuItem(
            title: title, action: #selector(BannerLinkMenuTarget.fire), keyEquivalent: "")
        item.target = target
        // NSMenuItem.target is weak; keep the target alive via representedObject
        // (retained) for as long as the menu itself lives.
        item.representedObject = target
        item.setImageIfDesired(systemSymbolName: symbol)
        return item
    }
}

/// Carries a menu item's closure to an ObjC selector (NSMenuItem needs a
/// target/action pair, not a closure).
@MainActor
private final class BannerLinkMenuTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
#endif
