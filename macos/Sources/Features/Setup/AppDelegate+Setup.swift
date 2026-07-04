import AppKit

/// First-launch and on-demand setup for the ghoztty command-line tool and the
/// Claude Code integration.
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

            let claudeAvailable = ClaudeCodeIntegration.findClaude() != nil
            DispatchQueue.main.async {
                self.presentSetupDialog(probe: probe, claudeAvailable: claudeAvailable)
            }
        }
    }

    private func presentSetupDialog(probe: CommandLineInstaller.Probe, claudeAvailable: Bool) {
        let defaults = UserDefaults.ghostty
        defaults.set(true, forKey: SetupDefaults.promptAnswered)

        let alert = NSAlert()
        alert.messageText = "Set Up the ghoztty Command?"
        alert.informativeText = "Ghoztty can add the ghoztty command so terminals and tools can control it. This creates a link in ~/.local/bin. No admin access is needed."
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Not Now")

        var claudeCheckbox: NSButton?
        if claudeAvailable {
            let checkbox = NSButton(
                checkboxWithTitle: "Also set up Claude Code integration",
                target: nil,
                action: nil)
            checkbox.state = .on
            checkbox.sizeToFit()
            alert.accessoryView = checkbox
            claudeCheckbox = checkbox
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        defaults.set(true, forKey: SetupDefaults.installAccepted)
        let wantsClaude = claudeCheckbox?.state == .on

        DispatchQueue.global(qos: .userInitiated).async {
            var cliFailure: String?
            do {
                try CommandLineInstaller.install(
                    pathContainsUserBin: probe.pathContainsUserBin,
                    allowAdminPrompt: true)
            } catch {
                cliFailure = error.localizedDescription
            }

            var claudeFailure: String?
            if cliFailure == nil, wantsClaude {
                switch ClaudeCodeIntegration.install() {
                case .installed, .alreadyInstalled:
                    break
                case .claudeNotFound:
                    claudeFailure = "Claude Code was not found on this Mac."
                case .failed(let detail):
                    claudeFailure = detail
                }
            }

            DispatchQueue.main.async {
                if let cliFailure {
                    Self.showSetupAlert(
                        title: "Command Setup Failed",
                        message: "\(cliFailure) You can try again from the Ghoztty menu.",
                        style: .warning)
                } else if let claudeFailure {
                    Self.showSetupAlert(
                        title: "Claude Code Setup Failed",
                        message: "The ghoztty command was set up, but the Claude Code plugin was not. \(claudeFailure)",
                        style: .warning)
                }
                // Success is silent so the first launch stays quiet.
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

    @IBAction func setupClaudeCodeIntegration(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ClaudeCodeIntegration.install()
            DispatchQueue.main.async {
                switch outcome {
                case .installed:
                    Self.showSetupAlert(
                        title: "Claude Code Integration Ready",
                        message: "The Ghoztty plugin is installed in Claude Code.")
                case .alreadyInstalled:
                    Self.showSetupAlert(
                        title: "Already Set Up",
                        message: "The Ghoztty plugin is already installed in Claude Code.")
                case .claudeNotFound:
                    Self.showSetupAlert(
                        title: "Claude Code Not Found",
                        message: "This sets up the Ghoztty plugin for Claude Code. Install Claude Code on this Mac, then run this again.")
                case .failed(let detail):
                    Self.showSetupAlert(
                        title: "Claude Code Setup Failed",
                        message: detail,
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
