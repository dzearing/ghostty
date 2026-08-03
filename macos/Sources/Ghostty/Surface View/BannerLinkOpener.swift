#if canImport(AppKit)
import AppKit

/// The standard set of actions for a clickable banner link, plus the
/// right-click menu that exposes them. Kept as one component so link behavior
/// is consistent wherever banner links render — and so other link surfaces
/// (terminal, viewer) can adopt the same menu later.
///
/// A banner link is either a web URL or a local file (bare file paths
/// autolink). A plain click hands the link *out* of Ghoztty — a URL to the
/// system default browser, a file revealed in Finder. The modifiers bring it
/// back in: `Cmd` opens it in a viewer side pane (either kind), and
/// `Cmd-Shift` gives it a surface of its own — a new Ghoztty viewer window for
/// a URL, the file's own default app for a path.
///
/// A URL leaves by default because Ghoztty's `WKWebView` keeps its own cookie
/// store with no relationship to Safari or Chrome: anything behind a login
/// renders logged-out in a viewer pane and OAuth sign-in never completes. The
/// browser is where the user's session already lives. Viewing in Ghoztty is
/// still one modifier — or one right-click — away.
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

    /// What a click on a banner link does. Naming the outcome instead of
    /// calling the method directly gives the modifier scheme one home, so the
    /// mouse routing in `BannerText`, the menu order below, and the tests
    /// can't drift apart.
    enum Action: Equatable {
        /// Hand it to the system: the default browser for a URL, the file's
        /// own app for a path.
        case openWithSystem
        /// Select the file in Finder without opening it.
        case revealInFinder
        /// A viewer split beside the banner's pane.
        case openInSidePane
        /// A new one-pane Ghoztty viewer window.
        case openInNewWindow
    }

    /// What a click on `url` with `modifiers` held does. Plain click leaves
    /// Ghoztty, `Cmd` opens a side pane, `Cmd-Shift` asks for a surface of the
    /// link's own — which for a file is the app that owns it, since a viewer
    /// can display a file but never edit one.
    static func action(for url: URL, modifiers: NSEvent.ModifierFlags) -> Action {
        guard modifiers.contains(.command) else {
            return url.isFileURL ? .revealInFinder : .openWithSystem
        }
        guard modifiers.contains(.shift) else { return .openInSidePane }
        return url.isFileURL ? .openWithSystem : .openInNewWindow
    }

    /// Run `action` against `url`.
    func perform(_ action: Action, on url: URL) {
        switch action {
        case .openWithSystem: openWithSystem(url)
        case .revealInFinder: revealInFinder(url)
        case .openInSidePane: openInSidePane(url)
        case .openInNewWindow: openInNewWindow(url)
        }
    }

    /// What a viewer pane should be pointed at. `ViewerView` reads any
    /// non-`http`/`about` location as a literal filesystem path, so a file
    /// link hands over its path — `file:///tmp/a.md` would send it looking for
    /// a file by that name.
    func viewerLocation(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    /// Cmd-Shift-click on a URL: open the link in a new Ghoztty viewer window
    /// — the same one-pane viewer tree the CLI `+new-window --view=<url>`
    /// builds. A menu item for either kind of link.
    func openInNewWindow(_ url: URL) {
        guard let controller else { openWithSystem(url); return }
        let pane = PaneView(viewer: ViewerView(
            location: viewerLocation(for: url),
            originDirectory: surface?.pwd))
        _ = TerminalController.newWindow(
            controller.ghostty,
            tree: SplitTree<PaneView>(root: .leaf(view: pane), zoomed: nil))
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Cmd-click, for either kind of link: open it in a viewer split beside
    /// the banner's pane — the same thing `+split --view=<url>` does. The
    /// viewer renders local files too, so this works for a file path.
    func openInSidePane(_ url: URL) {
        guard let controller, let surface else { openWithSystem(url); return }
        controller.newViewerSplit(
            at: surface,
            direction: .right,
            viewer: ViewerView(location: viewerLocation(for: url), originDirectory: surface.pwd))
    }

    /// Left-click default for a file path: select it in Finder rather than
    /// opening it, so a click never launches an editor the user didn't ask for.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Hand the link to the system — the default browser for a web URL, the
    /// file's default app for a file URL. The left-click default for a URL
    /// (the browser is where the user's session lives) and the Cmd-Shift
    /// action for a file. Also the fallback whenever there's no controller to
    /// open a Ghoztty window with, so a link is never dead.
    func openWithSystem(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// What `copy` puts on the pasteboard: a plain filesystem path for a file
    /// link (a `file://` string is useless in a shell or another editor), the
    /// full URL for anything web.
    func pasteboardString(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    /// Copy the link to the general pasteboard.
    func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pasteboardString(for: url), forType: .string)
    }

    /// The right-click menu for a link, in modifier order — the first item is
    /// by contract the left-click default, then the group that keeps the link
    /// inside Ghoztty, then the rest. A file leads with Reveal in Finder and
    /// keeps Open with Default App (its Cmd-Shift action) as a separate item;
    /// a URL leads with the browser, which is both its plain click and its
    /// only system handoff, so it appears once.
    func menu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        if url.isFileURL {
            menu.addItem(item("Reveal in Finder", symbol: "folder", url) { revealInFinder($0) })
        } else {
            menu.addItem(item(
                "Open in Default Browser", symbol: "safari", url) { openWithSystem($0) })
        }
        menu.addItem(.separator())
        menu.addItem(item("Open in Side Pane", symbol: "sidebar.right", url) { openInSidePane($0) })
        menu.addItem(item("Open in New Window", symbol: "macwindow", url) { openInNewWindow($0) })
        if url.isFileURL {
            menu.addItem(.separator())
            menu.addItem(item(
                "Open with Default App", symbol: "arrow.up.forward.app", url) { openWithSystem($0) })
        }
        menu.addItem(.separator())
        menu.addItem(item(
            url.isFileURL ? "Copy Path" : "Copy Link", symbol: "doc.on.doc", url) { copy($0) })
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
