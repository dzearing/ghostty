import AppKit

/// First-launch and on-demand setup for the ghoztty command-line tool and
/// available coding-agent integrations.
extension AppDelegate {
    private enum SetupDefaults {
        /// The user answered the one-time setup dialog (either way).
        static let promptAnswered = "CommandLineToolPromptAnswered"

        /// The user accepted CLI setup, so future repairs happen silently.
        static let installAccepted = "CommandLineToolInstallAccepted"

        /// The user answered the one-time "switch off the Claude plugin" prompt
        /// (either way). Set BEFORE the migration runs, so a failure — or a
        /// crash mid-migration — cannot turn the prompt into a nag.
        static let pluginMigrationAnswered = "ClaudePluginMigrationAnswered"
    }

    /// Called on every launch. Verifies the CLI in the background and repairs
    /// or prompts as needed. Never blocks launch and prompts at most once ever.
    func checkCommandLineToolOnLaunch() {
        #if DEBUG
        // Debug builds run next to the user's real install, so never touch the
        // CLI setup unless a test explicitly opts in.
        guard ProcessInfo.processInfo.environment["GHOZTTY_TEST_CLI_SETUP"] != nil else { return }
        #endif

        // Running from a DMG or a translocated path: a link would break as
        // soon as the app moves, so don't burn the one-time prompt on it.
        guard !CommandLineInstaller.isRunningFromTemporaryLocation else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let probe = CommandLineInstaller.probe()
            guard !probe.isHealthy else { return }

            let defaults = UserDefaults.ghostty
            if defaults.bool(forKey: SetupDefaults.installAccepted) {
                // The user already said yes once; repair quietly.
                try? CommandLineInstaller.install(
                    pathContainsUserBin: probe.pathContainsUserBin,
                    allowAdminPrompt: false)
                return
            }

            guard !defaults.bool(forKey: SetupDefaults.promptAnswered) else { return }

            let agents = AgentIntegrationService.availableAgents()
            DispatchQueue.main.async {
                self.presentSetupDialog(probe: probe, agents: agents)
            }
        }
    }

    private func presentSetupDialog(probe: CommandLineInstaller.Probe, agents: [RuntimeAgent]) {
        let defaults = UserDefaults.ghostty
        defaults.set(true, forKey: SetupDefaults.promptAnswered)

        let alert = NSAlert()
        alert.messageText = "Set Up the ghoztty Command?"
        alert.informativeText = "Ghoztty can add the ghoztty command so terminals and tools can control it. This creates a link in ~/.local/bin. No admin access is needed."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Not Now")

        var checkboxes: [(RuntimeAgent, NSButton)] = []
        if !agents.isEmpty {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            for agent in agents {
                let box = NSButton(checkboxWithTitle: "Also set up \(agent.displayName) integration", target: nil, action: nil)
                box.state = .on
                checkboxes.append((agent, box))
                stack.addArrangedSubview(box)
            }
            let note = NSTextField(wrappingLabelWithString:
                "Integrations add Ghoztty's status banner, skills, and hooks under each agent's config folder (e.g. ~/.claude). You can remove them anytime from Set Up Agent Integrations…")
            note.font = .preferredFont(forTextStyle: .caption1)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalToConstant: 320).isActive = true
            // Size the accessory to its content so long agent names, the note,
            // and larger Dynamic Type / bold-text settings are never clipped.
            stack.layoutSubtreeIfNeeded()
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            alert.accessoryView = stack
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        defaults.set(true, forKey: SetupDefaults.installAccepted)
        let chosen = checkboxes.filter { $0.1.state == .on }.map { $0.0 }

        DispatchQueue.global(qos: .userInitiated).async {
            var cliFailure: String?
            do {
                try CommandLineInstaller.install(pathContainsUserBin: probe.pathContainsUserBin, allowAdminPrompt: true)
            } catch { cliFailure = error.localizedDescription }

            var results: [(RuntimeAgent, IntegrationOutcome)] = []
            if cliFailure == nil {
                for agent in chosen { results.append((agent, AgentIntegrationService.install(agent: agent))) }
            }
            let jqMissing = !chosen.isEmpty && !AgentIntegrationService.jqAvailable

            DispatchQueue.main.async {
                if let cliFailure {
                    let agentNote = chosen.isEmpty ? "" :
                        " The agent integrations you selected were not set up either — run Set Up Agent Integrations… to add them."
                    Self.showSetupAlert(title: "Command Setup Failed",
                        message: "\(cliFailure) You can try again from the Ghoztty menu.\(agentNote)", style: .warning)
                } else if results.contains(where: { if case .failed = $0.1 { return true } else { return false } }) {
                    Self.showSetupAlert(title: "Some Integrations Failed",
                        message: AgentIntegrationService.summary(results) + ". Re-run Set Up Agent Integrations… to try again.", style: .warning)
                } else if jqMissing {
                    Self.showSetupAlert(title: "Almost Done",
                        message: "Integrations installed. The status banner needs jq — install it with: brew install jq")
                }
                // Otherwise success stays silent.
            }
        }
    }

    // MARK: Menu and command palette actions

    @IBAction func installCommandLineTool(_ sender: Any?) {
        if CommandLineInstaller.isRunningFromTemporaryLocation {
            Self.showSetupAlert(
                title: "Move Ghoztty First",
                message: "Ghoztty is running from a temporary location. Move Ghoztty to the Applications folder, then run this again.",
                style: .warning)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let probe = CommandLineInstaller.probe()
            let defaults = UserDefaults.ghostty

            if probe.isHealthy {
                defaults.set(true, forKey: SetupDefaults.promptAnswered)
                DispatchQueue.main.async {
                    Self.showSetupAlert(
                        title: "Already Set Up",
                        message: "The ghoztty command is ready to use.")
                }
                return
            }

            do {
                let outcome = try CommandLineInstaller.install(
                    pathContainsUserBin: probe.pathContainsUserBin,
                    allowAdminPrompt: true)
                defaults.set(true, forKey: SetupDefaults.promptAnswered)
                defaults.set(true, forKey: SetupDefaults.installAccepted)
                DispatchQueue.main.async {
                    if outcome.staleSystemLinkRemains {
                        Self.showSetupAlert(
                            title: "Almost Done",
                            message: "The ghoztty command was installed, but an older item at /usr/local/bin/ghoztty is still in the way. Run this again and approve the admin prompt to finish.",
                            style: .warning)
                    } else {
                        Self.showSetupAlert(
                            title: "Command Installed",
                            message: "The ghoztty command is ready. New terminal windows will pick it up.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    Self.showSetupAlert(
                        title: "Command Setup Failed",
                        message: error.localizedDescription,
                        style: .warning)
                }
            }
        }
    }

    @IBAction func setupAgentIntegrations(_ sender: Any?) {
        AgentIntegrationsController.shared.show()
    }

    // MARK: - Claude plugin migration

    /// Called on every launch, but asks at most once ever: the app now ships the
    /// skills the standalone Claude plugin used to, so an existing plugin user
    /// gets one prompt on their first launch after updating and never sees it
    /// again — whichever way they answer.
    ///
    /// Gated on the CLI prompt already being answered so a genuinely fresh
    /// install cannot stack two modals on its first launch; for the users this
    /// is actually aimed at, that flag is long since set.
    func checkClaudePluginMigrationOnLaunch() {
        #if DEBUG
        // A debug build runs alongside the user's real install and would
        // uninstall their real plugin. Never migrate unless a test opts in.
        guard ProcessInfo.processInfo.environment["GHOZTTY_TEST_PLUGIN_MIGRATION"] != nil else { return }
        #endif

        let defaults = UserDefaults.ghostty
        guard defaults.bool(forKey: SetupDefaults.promptAnswered),
              !defaults.bool(forKey: SetupDefaults.pluginMigrationAnswered)
        else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let migration = ClaudePluginMigration(
                homeDirectoryURL: URL(fileURLWithPath: LoginShell.homePath),
                fileManager: .default)
            guard migration.isNeeded else { return }
            DispatchQueue.main.async { Self.presentPluginMigrationDialog(migration) }
        }
    }

    private static func presentPluginMigrationDialog(_ migration: ClaudePluginMigration) {
        let alert = NSAlert()
        alert.messageText = "Ghoztty Now Manages Its Claude Integration"
        alert.informativeText = """
            The ghoztty Claude Code plugin is installed. Ghoztty now ships these \
            skills itself, tied to the version you have installed, so they can \
            never describe a command your Ghoztty does not have.

            Switching removes the plugin with Claude's own uninstaller and \
            installs Ghoztty's copy. Your banners keep working.
            """
        alert.addButton(withTitle: "Switch Over")
        alert.addButton(withTitle: "Keep Plugin")

        let switchOver = alert.runModal() == .alertFirstButtonReturn
        // Recorded either way, and BEFORE the work: answering is what retires
        // the prompt, not succeeding at it.
        UserDefaults.ghostty.set(true, forKey: SetupDefaults.pluginMigrationAnswered)
        guard switchOver else { return }

        DispatchQueue.global(qos: .utility).async {
            do {
                try migration.run()
            } catch {
                DispatchQueue.main.async {
                    Self.showSetupAlert(
                        title: "Could Not Remove the Plugin",
                        message: """
                            \(error.localizedDescription)

                            Nothing was changed — the plugin still manages Claude. \
                            You can try again from Ghoztty ▸ Agent Integrations.
                            """,
                        style: .warning)
                }
                return
            }

            let outcome = AgentIntegrationService.install(agent: .claude)
            DispatchQueue.main.async {
                switch outcome {
                case .installed, .upgraded, .upToDate:
                    break // Silent on success: the user already said do it.
                default:
                    Self.showSetupAlert(
                        title: "Claude Integration Needs Attention",
                        message: """
                            The plugin was removed, but installing Ghoztty's copy \
                            reported: \(outcome.label).

                            Open Ghoztty ▸ Agent Integrations to finish setting it up.
                            """,
                        style: .warning)
                }
            }
        }
    }

    private static func showSetupAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .informational
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
