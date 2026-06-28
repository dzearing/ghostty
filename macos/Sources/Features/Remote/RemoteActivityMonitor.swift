import SwiftUI
import AppKit
import GhosttyKit

/// Presents and tracks Remote Activity Monitor panels — one non-modal window per
/// machine. Two entry styles:
///
/// - `presentReusing`: opens on an EXISTING connection owned by a remote window.
///   The panel does NOT free it (the window's `RemoteConnection` is the sole
///   owner). The model is created with `ownsConnection: false`.
/// - `presentDialing`: dials a FRESH connection off-main, opens the panel as its
///   sole owner (`ownsConnection: true`), and frees it via `model.stop()` when the
///   window closes.
///
/// A small registry keyed by `Machine.ID` focuses an existing panel instead of
/// opening a duplicate. Closing a panel always calls `model.stop()` exactly once
/// (window-close → delegate), so connections never leak.
@MainActor
enum RemoteActivityMonitor {
    /// Open windows keyed by machine. A strong reference keeps each panel alive.
    private static var windows: [Machine.ID: NSWindow] = [:]

    /// Open (or focus) a monitor on an EXISTING, externally-owned connection.
    static func presentReusing(connection: ghostty_remote_connection_t, machine: Machine) {
        if focusExisting(machine) { return }
        let model = RemoteActivityMonitorModel(
            machine: machine,
            handle: connection,
            ownsConnection: false
        )
        model.start()
        openWindow(for: machine, model: model)
    }

    /// Dial a FRESH connection off-main and open a monitor that owns it. Shows a
    /// connecting placeholder window immediately; on dial failure replaces it with
    /// an error alert and closes.
    static func presentDialing(machine: Machine) {
        if focusExisting(machine) { return }

        let host = machine.host
        let port = machine.port

        DispatchQueue.global(qos: .userInitiated).async {
            // Dial blocks through the handshake; nil on failure.
            let handle = host.withCString {
                ghostty_remote_connection_new_tcp($0, port)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A panel for this machine may have appeared while we dialed.
                    if windows[machine.id] != nil {
                        if let handle { ghostty_remote_connection_free(handle) }
                        focus(machine)
                        return
                    }
                    guard let handle else {
                        presentDialFailure(machine)
                        return
                    }
                    let model = RemoteActivityMonitorModel(
                        machine: machine,
                        handle: handle,
                        ownsConnection: true
                    )
                    model.start()
                    openWindow(for: machine, model: model)
                }
            }
        }
    }

    /// Command-palette entry point. If the surface's window is a REMOTE window,
    /// open on its existing connection; otherwise present the machine chooser and,
    /// on a remote selection, dial a fresh connection.
    static func openFromPalette(surfaceView: Ghostty.SurfaceView) {
        if let controller = surfaceView.window?.windowController as? BaseTerminalController,
           let connection = controller.remoteConnection {
            presentReusing(connection: connection.handle, machine: connection.machine)
            return
        }

        let machines = MachineRegistry.shared.machines
        guard !machines.isEmpty else { return }
        MachineChooser.present(machines: machines) { selected in
            guard let selected else { return }
            switch selected {
            case .local:
                break // No local Activity Monitor; the user picked Local.
            case .remote(let machine):
                presentDialing(machine: machine)
            }
        }
    }

    // MARK: - Internals

    /// Focus the existing panel for `machine` if one is open. Returns true if so.
    private static func focusExisting(_ machine: Machine) -> Bool {
        guard windows[machine.id] != nil else { return false }
        focus(machine)
        return true
    }

    private static func focus(_ machine: Machine) {
        guard let window = windows[machine.id] else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func openWindow(for machine: Machine, model: RemoteActivityMonitorModel) {
        let view = RemoteActivityMonitorView(model: model)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Activity — \(machine.name)"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 460))

        // On close: stop the model (unsubscribe + free if owned) exactly once and
        // drop our registry reference so the window deallocates.
        let delegate = MonitorWindowDelegate(machineID: machine.id, model: model)
        window.delegate = delegate
        // Keep the delegate alive for the window's lifetime.
        objc_setAssociatedObject(window, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)

        windows[machine.id] = window
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
    fileprivate static func windowClosed(machineID: Machine.ID, model: RemoteActivityMonitorModel) {
        model.stop()
        windows.removeValue(forKey: machineID)
    }

    private static var delegateKey: UInt8 = 0
}

/// Tears down a monitor model when its window closes. One per panel; retained via
/// associated object on the window so it lives exactly as long as the window.
private final class MonitorWindowDelegate: NSObject, NSWindowDelegate {
    private let machineID: Machine.ID
    private let model: RemoteActivityMonitorModel

    init(machineID: Machine.ID, model: RemoteActivityMonitorModel) {
        self.machineID = machineID
        self.model = model
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            RemoteActivityMonitor.windowClosed(machineID: machineID, model: model)
        }
    }
}
