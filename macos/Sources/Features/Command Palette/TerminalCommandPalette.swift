import SwiftUI
import GhosttyKit

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            sections: commandSections
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// All commands available in the command palette, organized into sections.
    /// An optional "Recent" section surfaces the 10 most recently used commands
    /// in recency order; an "All Commands" section (or untitled section when there
    /// are no recent commands) lists every command alphabetically.
    private var commandSections: [CommandPaletteSection] {
        var sections: [CommandPaletteSection] = []

        let updates = updateOptions
        if !updates.isEmpty {
            sections.append(CommandPaletteSection(title: nil, options: updates))
        }

        let rest = jumpOptions + terminalOptions + setupOptions + remoteOptions + viewerOptions

        let defaultSorted = rest.sorted { a, b in
            let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
            let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
            let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                return aSortKey < bSortKey
            }
            return false
        }

        let recentIds = PaletteHistory.shared.recentIdentifiers(limit: 10)
        let recentOptions = recentIds.compactMap { id in
            defaultSorted.first { $0.commandIdentifier == id }
        }

        if !recentOptions.isEmpty {
            sections.append(CommandPaletteSection(title: "Recent", options: recentOptions))
            let recentIdSet = Set(recentIds)
            let remaining = defaultSorted.filter { $0.commandIdentifier == nil || !recentIdSet.contains($0.commandIdentifier!) }
            sections.append(CommandPaletteSection(title: "All Commands", options: remaining))
        } else {
            sections.append(CommandPaletteSection(title: nil, options: defaultSorted))
        }

        return sections
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []

        guard let updateViewModel, updateViewModel.state.isInstallable else {
            return options
        }

        // We override the update available one only because we want to properly
        // convey it'll go all the way through.
        let title: String
        if case .updateAvailable = updateViewModel.state {
            title = "Update Ghoztty and Restart"
        } else {
            title = updateViewModel.text
        }

        options.append(CommandOption(
            title: title,
            description: updateViewModel.description,
            leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
            badge: updateViewModel.badge,
            emphasis: true
        ) {
            (NSApp.delegate as? AppDelegate)?.updateController.installUpdate()
        })

        options.append(CommandOption(
            title: "Cancel or Skip Update",
            description: "Dismiss the current update process"
        ) {
            updateViewModel.state.cancel()
        })

        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                let symbols = appDelegate.ghostty.config.keyboardShortcut(for: c.action)?.keyList
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: symbols,
                    commandIdentifier: c.action
                ) {
                    PaletteHistory.shared.recordUsage(for: c.action)
                    onAction(c.action)
                }
            }
    }

    /// App setup commands, such as installing the command-line tool.
    private var setupOptions: [CommandOption] {
        [
            CommandOption(
                title: "Install Command-Line Tool",
                description: "Add the ghoztty command for terminals and tools",
                leadingIcon: "terminal"
            ) {
                (NSApp.delegate as? AppDelegate)?.installCommandLineTool(nil)
            },
            CommandOption(
                title: "Set Up Agent Integrations…",
                description: "Install Ghoztty integration for detected coding agents",
                leadingIcon: "puzzlepiece.extension"
            ) {
                (NSApp.delegate as? AppDelegate)?.setupAgentIntegrations(nil)
            },
        ]
    }

    /// Native (Swift-side) commands for the remote feature. Currently just the
    /// Remote Activity Monitor opener. These are NOT core binding actions — they
    /// run a closure directly (like `jumpOptions`/`updateOptions`).
    private var remoteOptions: [CommandOption] {
        var options: [CommandOption] = []
        options.append(CommandOption(
            title: "Open Remote Activity Monitor",
            description: "Show CPU, memory, and the process table for a remote machine",
            leadingIcon: "chart.bar.xaxis"
        ) {
            RemoteActivityMonitor.openFromPalette(surfaceView: surfaceView)
        })
        return options
    }

    /// Viewer pane commands: open a rendered file or website as a split
    /// beside the current pane (same as the CLI `+split --view=...`).
    private var viewerOptions: [CommandOption] {
        [
            CommandOption(
                title: "Viewer: Open File in Pane…",
                description: "Render a markdown or text file beside this pane",
                leadingIcon: "doc.richtext"
            ) {
                ViewerCommands.openFileFromPalette(surfaceView: surfaceView)
            },
            CommandOption(
                title: "Viewer: Open URL in Pane…",
                description: "Open a website beside this pane",
                leadingIcon: "globe"
            ) {
                ViewerCommands.openURLFromPalette(surfaceView: surfaceView)
            },
            CommandOption(
                title: "Viewer: Open Browser Pane",
                description: "Open a blank browser beside this pane and type an address",
                leadingIcon: "safari"
            ) {
                ViewerCommands.openBrowserFromPalette(surfaceView: surfaceView)
            },
        ]
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let terminalTitle = surface.title.isEmpty ? window.title : surface.title
                let displayTitle: String
                if let override = controller.titleOverride, !override.isEmpty {
                    displayTitle = override
                } else if !terminalTitle.isEmpty {
                    displayTitle = terminalTitle
                } else {
                    displayTitle = "Untitled"
                }
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

}

/// This is done to ensure that the given view is in the responder chain.
private struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
