// macos/Sources/Features/Setup/RuntimeIntegrationFactory.swift
import Foundation

enum RuntimeIntegrationFactory {
    static let bannerComponentName = "banner-script"

    static func availableAgents(homeDirectoryURL: URL, fileManager: FileManager) -> [RuntimeAgent] {
        RuntimeAgent.allCases.filter {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: $0.configDirectoryURL(homeDirectoryURL: homeDirectoryURL).path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }
    }

    static func make(for agent: RuntimeAgent, homeDirectoryURL: URL, fileManager: FileManager) -> RuntimeIntegration {
        let banner = BannerScriptInstaller(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
        let skills = SkillComponent(agent: agent, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)

        var components: [IntegrationComponent] = [
            IntegrationComponent(name: bannerComponentName, state: banner.state, install: banner.install, uninstall: banner.uninstall),
            IntegrationComponent(name: "skills", state: skills.state, install: skills.install, uninstall: skills.uninstall),
        ]

        // Hooks — skip Claude hooks entirely if the external plugin already owns them.
        let spec: HookSpec = agent == .claude ? ClaudeHookSpec() : CopilotHookSpec()
        let skipHooks = agent == .claude &&
            (spec as? ClaudeHookSpec)?.isExternalPluginInstalled(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager) == true
        if !skipHooks {
            let hooks = HookComponent(spec: spec, homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
            components.append(IntegrationComponent(name: "hooks", state: hooks.state, install: hooks.install, uninstall: hooks.uninstall))
        }

        return RuntimeIntegration(
            agent: agent,
            components: components,
            requiredDirectory: agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL),
            fileManager: fileManager)
    }
}
