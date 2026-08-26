import AppKit

/// Command-palette entry points for opening viewer panes interactively.
/// Both open the viewer as a split beside the pane the palette was invoked
/// from, mirroring the CLI `+split --view=...` behavior.
enum ViewerCommands {
    @MainActor
    static func openFileFromPalette(surfaceView: Ghostty.SurfaceView) {
        guard let window = surfaceView.window,
              let controller = window.windowController as? BaseTerminalController else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a markdown, code, or image file to view"
        // Sheet (not app-modal): the run loop keeps servicing IPC.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            openViewer(location: url.path, controller: controller, anchor: surfaceView)
        }
    }

    /// Open a browser pane with nothing loaded and the caret already in the
    /// address bar, so the user just types where they want to go. This is the
    /// interactive counterpart to `+split --view=<url>` for the common case
    /// where the URL is not known up front — no modal to fill in first.
    @MainActor
    static func openBrowserFromPalette(surfaceView: Ghostty.SurfaceView) {
        guard let window = surfaceView.window,
              let controller = window.windowController as? BaseTerminalController else { return }

        // A blank pane has no content to derive provenance from, so the
        // terminal it was opened beside supplies the origin directory — the
        // same relationship `+split --view=` gets from `--working-directory`.
        let viewer = ViewerView(
            location: ViewerView.blankPage,
            originDirectory: surfaceView.pwd)
        controller.newViewerSplit(at: surfaceView, direction: .right, viewer: viewer)
        // After the split lands and the bar's hosting view is mounted.
        DispatchQueue.main.async { viewer.focusAddressBar() }
    }

    @MainActor
    static func openURLFromPalette(surfaceView: Ghostty.SurfaceView) {
        guard let window = surfaceView.window,
              let controller = window.windowController as? BaseTerminalController else { return }

        let alert = NSAlert()
        alert.messageText = "Open URL in Viewer Pane"
        alert.informativeText = "Enter a web address to open beside the current pane."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if !text.contains("://") { text = "https://" + text }
            openViewer(location: text, controller: controller, anchor: surfaceView)
        }
    }

    @MainActor
    private static func openViewer(
        location: String,
        controller: BaseTerminalController,
        anchor: Ghostty.SurfaceView
    ) {
        controller.newViewerSplit(
            at: anchor,
            direction: .right,
            viewer: ViewerView(location: location, originDirectory: anchor.pwd))
    }
}
