// macos/Tests/Ghostty/GhosttyAssetsTests.swift
import Foundation
import Testing
@testable import Ghostty

struct GhosttyAssetsTests {
    @Test func bundlesSkillsAndBannerScript() throws {
        #expect(try GhosttyAssets.skillMarkdown("ghoztty").contains("Ghoztty"))
        #expect(try GhosttyAssets.skillMarkdown("process-feedback").contains("feedback"))
        let script = try GhosttyAssets.bannerScript()
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    /// These skills are vendored from the standalone Claude plugin, which
    /// installs its banner script at `~/.claude/scripts/ghoztty-banner.sh` (a
    /// symlink its own SessionStart hook re-points every session). The app
    /// installs to a stable, runtime-agnostic path instead, and a skill that
    /// still names the plugin's path tells the agent to run a script that does
    /// not exist wherever the plugin is absent — which is every Copilot install
    /// and every Claude install the app manages.
    ///
    /// Re-vendoring from a newer plugin release is a copy, so this is the check
    /// that the copy was rewritten rather than pasted.
    @Test func bundledSkillsNameTheAppsBannerPathNotThePlugins() throws {
        for name in SkillComponent.skillNames {
            let text = try GhosttyAssets.skillMarkdown(name)
            #expect(!text.contains(".claude/scripts/ghoztty-banner.sh"),
                    "\(name) still points at the plugin-owned banner path")
            #expect(!text.contains("CLAUDE_PLUGIN_ROOT"),
                    "\(name) still references the plugin root")
        }
    }

    /// The app installs these skills into every user's agent config, so a
    /// commit-message template carrying an AI-attribution trailer would put that
    /// trailer in their commits by default. That is the user's call, not a
    /// bundled default's.
    @Test func bundledSkillsCarryNoAIAttribution() throws {
        for name in SkillComponent.skillNames {
            let text = try GhosttyAssets.skillMarkdown(name).lowercased()
            #expect(!text.contains("co-authored-by: claude"), "\(name) carries a Co-Authored-By trailer")
            #expect(!text.contains("generated with [claude"), "\(name) carries a generated-with footer")
        }
    }
}
