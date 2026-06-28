import SwiftUI
import AppKit
import GhosttyKit

/// Presents and tracks Activity Monitor panels — one non-modal window per source.
/// Entry styles:
///
/// - `presentReusing`: opens on an EXISTING connection owned by a remote window.
///   The panel does NOT free it (the window's `RemoteConnection` is the sole
///   owner). The model's initial source is `.remote(machine)` with
///   `ownsConnection: false`.
/// - `presentDialing`: dials a FRESH connection off-main, opens the panel as its
///   sole owner (`ownsConnection: true`), and frees it via `model.stop()` when the
///   window closes.
/// - `presentLocal`: opens the panel on the in-process `.local` source (no
///   connection).
///
/// Once open, the panel's in-window machine switcher can move to any other source
/// (dialing fresh owned connections / freeing them) WITHOUT opening a second
/// window — the registry only governs the INITIAL open.
///
/// A registry keyed by `MonitorSource` focuses an existing panel instead of
/// opening a duplicate. Closing a panel always calls `model.stop()` exactly once
/// (window-close → delegate), so connections never leak.
@MainActor
enum RemoteActivityMonitor {
    /// Open windows keyed by their INITIAL source. A strong reference keeps each
    /// panel alive.
    private static var windows: [MonitorSource: NSWindow] = [:]

    /// Open (or focus) a monitor on an EXISTING, externally-owned connection.
    static func presentReusing(connection: ghostty_remote_connection_t, machine: Machine) {
        let source = MonitorSource.remote(machine)
        if focusExisting(source) { return }
        let model = RemoteActivityMonitorModel(
            source: source,
            handle: connection,
            ownsConnection: false
        )
        model.start()
        openWindow(for: source, title: "Activity — \(machine.name)", model: model)
    }

    /// Open (or focus) a monitor on the in-process LOCAL source.
    static func presentLocal() {
        let source = MonitorSource.local
        if focusExisting(source) { return }
        let model = RemoteActivityMonitorModel(
            source: source,
            handle: nil,
            ownsConnection: false
        )
        model.start()
        openWindow(for: source, title: "Activity — Local", model: model)
    }

    /// Dial a FRESH connection off-main and open a monitor that owns it. Shows a
    /// connecting placeholder window immediately; on dial failure replaces it with
    /// an error alert and closes.
    static func presentDialing(machine: Machine) {
        let source = MonitorSource.remote(machine)
        if focusExisting(source) { return }

        let host = machine.host
        let port = machine.port

        DispatchQueue.global(qos: .userInitiated).async {
            // Dial blocks through the handshake; nil on failure.
            let handle = host.withCString {
                ghostty_remote_connection_new_tcp($0, port)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A panel for this source may have appeared while we dialed.
                    if windows[source] != nil {
                        if let handle { ghostty_remote_connection_free(handle) }
                        focus(source)
                        return
                    }
                    guard let handle else {
                        presentDialFailure(machine)
                        return
                    }
                    let model = RemoteActivityMonitorModel(
                        source: source,
                        handle: handle,
                        ownsConnection: true
                    )
                    model.start()
                    openWindow(for: source, title: "Activity — \(machine.name)", model: model)
                }
            }
        }
    }

    /// Command-palette entry point. If the surface's window is a REMOTE window,
    /// open on its existing connection; otherwise present the machine chooser and
    /// open Local in-process or dial a fresh connection for the picked machine.
    static func openFromPalette(surfaceView: Ghostty.SurfaceView) {
        if let controller = surfaceView.window?.windowController as? BaseTerminalController,
           let connection = controller.remoteConnection {
            presentReusing(connection: connection.handle, machine: connection.machine)
            return
        }

        let machines = MachineRegistry.shared.machines
        guard !machines.isEmpty else {
            // No remote machines registered: just open the local monitor.
            presentLocal()
            return
        }
        MachineChooser.present(machines: machines) { selected in
            guard let selected else { return }
            switch selected {
            case .local:
                presentLocal()
            case .remote(let machine):
                presentDialing(machine: machine)
            }
        }
    }

    // MARK: - Internals

    /// Focus the existing panel for `source` if one is open. Returns true if so.
    private static func focusExisting(_ source: MonitorSource) -> Bool {
        guard windows[source] != nil else { return false }
        focus(source)
        return true
    }

    private static func focus(_ source: MonitorSource) {
        guard let window = windows[source] else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func openWindow(for source: MonitorSource, title: String, model: RemoteActivityMonitorModel) {
        let view = RemoteActivityMonitorView(model: model)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 700, height: 480))

        // On close: stop the model (unsubscribe + free if owned) exactly once and
        // drop our registry reference so the window deallocates.
        let delegate = MonitorWindowDelegate(source: source, model: model)
        window.delegate = delegate
        // Keep the delegate alive for the window's lifetime.
        objc_setAssociatedObject(window, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        windows[source] = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func presentDialFailure(_ machine: Machine) {
        let alert = NSAlert()
        alert.messageText = "Couldn't connect to \(machine.name)"
        alert.informativeText = "Failed to reach \(machine.endpoint). Make sure the Ghoztty agent is running and reachable."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Called by the window delegate when a panel closes.
    fileprivate static func windowClosed(source: MonitorSource, model: RemoteActivityMonitorModel) {
        model.stop()
        windows.removeValue(forKey: source)
    }

    private static var delegateKey: UInt8 = 0
}

/// Tears down a monitor model when its window closes. One per panel; retained via
/// associated object on the window so it lives exactly as long as the window.
private final class MonitorWindowDelegate: NSObject, NSWindowDelegate {
    private let source: MonitorSource
    private let model: RemoteActivityMonitorModel

    init(source: MonitorSource, model: RemoteActivityMonitorModel) {
        self.source = source
        self.model = model
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            RemoteActivityMonitor.windowClosed(source: source, model: model)
        }
    }
}
