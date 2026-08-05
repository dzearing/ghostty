// macos/Sources/Features/Setup/RuntimeIntegrationFactory.swift
import Foundation

enum RuntimeIntegrationFactory {
    static let bannerComponentName = "banner-script"
    static let hooksComponentName = "hooks"

    /// Which runtimes are installed, by probing for their BINARY.
    ///
    /// Not the config dir: Ghoztty writes into that, so it would report a
    /// removed CLI as present for as long as our own artifacts survive, and
    /// report a just-installed CLI as absent until its first run. See
    /// `RuntimeProbe`.
    static func availableAgents(homeDirectoryURL: URL,
                                fileManager: FileManager,
                                probe: RuntimeProbe = .binary) -> [RuntimeAgent] {
        RuntimeAgent.allCases.filter { probe.isInstalled($0, homeDirectoryURL) }
    }

    /// The agent's hooks component, or nil when Ghoztty must NOT own the hooks
    /// (Claude's external plugin already does). Extracted so the shared-banner
    /// refcount can inspect every agent's hooks state through one path.
    static func hooksComponent(for agent: RuntimeAgent,
                               homeDirectoryURL: URL,
                               fileManager: FileManager) -> IntegrationComponent? {
        let spec: HookSpec = agent == .claude ? ClaudeHookSpec() : CopilotHookSpec()
        let skipHooks = agent == .claude &&
            (spec as? ClaudeHookSpec)?.isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) == true
        guard !skipHooks else { return nil }
        let hooks = HookComponent(spec: spec, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        return IntegrationComponent(name: hooksComponentName, state: hooks.state, install: hooks.install, uninstall: hooks.uninstall)
    }

    /// Refcount for the SHARED banner script: true when ANY agent's hooks
    /// component still references it. Ghoztty-owned hooks are the only thing that
    /// invokes the banner, so when none are present it is safe to remove. A
    /// plugin-managed Claude has no Ghoztty hooks component (nil) and correctly
    /// contributes nothing — its external plugin ships its own banner path.
    /// Pass `excluding` to ask "would the banner survive uninstalling that agent?"
    /// (i.e. does any OTHER agent's hooks still reference it).
    static func anyHooksReferenceBanner(homeDirectoryURL: URL,
                                        fileManager: FileManager,
                                        excluding: RuntimeAgent? = nil) -> Bool {
        RuntimeAgent.allCases.contains { agent in
            guard agent != excluding,
                  let hooks = hooksComponent(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            else { return false }
            return hooks.state() != .notInstalled
        }
    }

    static func make(for agent: RuntimeAgent,
                     homeDirectoryURL: URL,
                     fileManager: FileManager,
                     probe: RuntimeProbe = .binary) -> RuntimeIntegration {
        let banner = BannerScriptInstaller(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        let skills = SkillComponent(agent: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)

        // The banner is a SHARED file (one path for every agent), so its uninstall
        // is refcounted: it removes the script only once NO agent's hooks
        // reference it. Correct-by-construction — both RuntimeIntegration.uninstall()
        // and install() rollback process components in reverse, and the hooks
        // component is ordered AFTER the banner (and is last), so THIS agent's
        // hooks are always removed (uninstall) or never written (failed install)
        // before this closure runs; the scan therefore sees only SIBLINGS. This
        // holds for ANY caller of RuntimeIntegration.uninstall(), including the
        // install()-rollback path (which the old Service-only guard bypassed).
        let bannerUninstall: () throws -> Void = {
            guard !anyHooksReferenceBanner(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) else { return }
            try banner.uninstall()
        }

        var components: [IntegrationComponent] = [
            IntegrationComponent(name: bannerComponentName, state: banner.state, install: banner.install, uninstall: bannerUninstall),
            IntegrationComponent(name: "skills", state: skills.state, install: skills.install, uninstall: skills.uninstall),
        ]

        // MUST remain last: the banner refcount above relies on hooks being
        // ordered after the banner so reverse-order processing removes them first.
        if let hooks = hooksComponent(for: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) {
            components.append(hooks)
        }

        return RuntimeIntegration(
            agent: agent,
            components: components,
            isAvailable: { probe.isInstalled(agent, homeDirectoryURL) },
            fileManager: fileManager)
    }
}
