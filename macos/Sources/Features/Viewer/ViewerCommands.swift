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
        panel.message = "Choose a markdown or text file to view"
        // Sheet (not app-modal): the run loop keeps servicing IPC.
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            openViewer(location: url.path, controller: controller, anchor: surfaceView)
        }
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
            viewer: ViewerView(location: location))
    }
}
