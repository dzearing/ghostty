import AppKit

/// First-launch and on-demand setup for the ghoztty command-line tool and
/// available coding-agent integrations.
extension AppDelegate {
    private enum SetupDefaults {
        /// The user answered the one-time setup dialog (either way).
        static let promptAnswered = "CommandLineToolPromptAnswered"

        /// The user accepted CLI setup, so future repairs happen silently.
        static let installAccepted = "CommandLineToolInstallAccepted"
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
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(agents.count) * 22)
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
                    Self.showSetupAlert(title: "Command Setup Failed",
                        message: "\(cliFailure) You can try again from the Ghoztty menu.", style: .warning)
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
