// macos/Sources/Features/Setup/AgentIntegrationsController.swift
import Cocoa
import SwiftUI

/// Code-only window that hosts the Agent Integrations management view.
@MainActor
final class AgentIntegrationsController: NSWindowController {
    static let shared = AgentIntegrationsController()

    private let viewModel = AgentIntegrationsViewModel()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Agent Integrations"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        self.init(window: window)
        let hostingView = NSHostingView(rootView: AgentIntegrationsView(viewModel: viewModel, onDone: { [weak window] in
            window?.performClose(nil)
        }))
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
    }

    func show() {
        viewModel.refresh()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
