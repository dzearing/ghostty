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
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Agent Integrations"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        self.init(window: window)
        window.contentView = NSHostingView(rootView: AgentIntegrationsView(viewModel: viewModel))
        window.center()
    }

    func show() {
        viewModel.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
