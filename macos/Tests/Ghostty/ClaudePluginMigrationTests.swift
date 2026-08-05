// macos/Tests/Ghostty/ClaudePluginMigrationTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ClaudePluginMigrationTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeManifest(_ json: String, in home: URL) throws {
        let dir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("installed_plugins.json"),
                       atomically: true, encoding: .utf8)
    }

    private static let twoMarketplaces = #"""
    {"version":2,"plugins":{
      "ghoztty@dzearing-claude-marketplace":[{"scope":"user","version":"0.8.0"}],
      "ghoztty@ghoztty-claude-plugin":[{"scope":"user","version":"0.8.0"}],
      "code-review@claude-plugins-official":[{"scope":"user"}]}}
    """#

    /// A recording runner: never shells out, remembers what it was asked to run.
    private final class Runner {
        var commands: [String] = []
        var exitCode: Int32 = 0
        func run(_ command: String) -> Int32? {
            commands.append(command)
            return exitCode
        }
    }

    // MARK: - Detection

    /// The plugin is registered through more than one marketplace in practice,
    /// and uninstalling one leaves the other owning the runtime.
    @Test func enumeratesEveryMarketplaceRegistration() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)

        let found = ClaudeHookSpec.externalPluginRegistrations(
            homeDirectoryURL: home, fileManager: .default)

        #expect(Set(found) == ["ghoztty@dzearing-claude-marketplace", "ghoztty@ghoztty-claude-plugin"])
    }

    @Test func migrationIsNotNeededWithoutThePlugin() throws {
        let home = try tempHome()
        try writeManifest(#"{"version":2,"plugins":{"code-review@claude-plugins-official":[{"scope":"user"}]}}"#, in: home)
        let runner = Runner()

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)

        #expect(!migration.isNeeded)
    }

    // MARK: - Uninstall

    /// Removal goes through Claude's OWN cli, never by deleting files out of
    /// `~/.claude/plugins/cache`: that tree is Claude Code's package-manager
    /// state, and deleting it leaves a dangling manifest entry that the next
    /// marketplace sync may act on.
    @Test func uninstallsEachRegistrationThroughClaudesOwnCLI() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)
        let runner = Runner()

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)
        try migration.uninstallPlugin()

        #expect(runner.commands.count == 2)
        #expect(runner.commands.allSatisfy { $0.hasPrefix("claude plugin uninstall ") })
        #expect(runner.commands.contains { $0.contains("ghoztty@dzearing-claude-marketplace") })
        #expect(runner.commands.contains { $0.contains("ghoztty@ghoztty-claude-plugin") })
    }

    /// A failed uninstall must leave the user exactly where they started: the
    /// plugin still owning the runtime, rather than half-removed with Ghoztty's
    /// copy layered on top.
    @Test func aFailedUninstallThrowsAndLeavesTheRestUntouched() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)
        let runner = Runner()
        runner.exitCode = 1

        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let link = scripts.appendingPathComponent("ghoztty-banner.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent(".claude/plugins/cache/x/ghoztty/0.8.0/hooks/ghoztty-banner.sh").path)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)

        #expect(throws: (any Error).self) { try migration.run() }
        // The symlink is only cleaned AFTER a successful uninstall. Asserted via
        // the link itself: `fileExists` follows it, and it points into a plugin
        // cache this test never created, so it would read false either way.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    /// A shell we could not launch is a failure, not a silent success.
    @Test func anUnavailableShellIsAFailure() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in nil })

        #expect(throws: (any Error).self) { try migration.uninstallPlugin() }
    }

    // MARK: - Symlink cleanup

    /// The plugin's SessionStart hook maintains
    /// `~/.claude/scripts/ghoztty-banner.sh` as a symlink into its own cache and
    /// re-points it every session. Once the plugin is gone nothing maintains it,
    /// so it dangles.
    @Test func removesTheSymlinkThatPointedIntoThePluginCache() throws {
        let home = try tempHome()
        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let link = scripts.appendingPathComponent("ghoztty-banner.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent(".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh").path)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.removeStalePluginSymlink()

        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    /// Only the plugin's own link is ours to remove. A real file at that path,
    /// or a link the user pointed somewhere else, belongs to them.
    @Test func leavesAScriptTheUserOwnsAlone() throws {
        let home = try tempHome()
        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

        let real = scripts.appendingPathComponent("ghoztty-banner.sh")
        try "#!/bin/bash\necho mine\n".write(to: real, atomically: true, encoding: .utf8)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.removeStalePluginSymlink()

        #expect(FileManager.default.fileExists(atPath: real.path))
    }

    // MARK: - Banner state

    /// The plugin keys banner state by tty under `~/.claude/ghoztty-banner/`;
    /// the app's script uses `~/.config/ghoztty/banner-state/`. Carrying the
    /// files across means a pane mid-session keeps its banner instead of going
    /// blank until the next prompt.
    @Test func carriesBannerStateIntoTheAppsStateDirectory() throws {
        let home = try tempHome()
        let old = home.appendingPathComponent(".claude/ghoztty-banner")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try #"{"title":"one"}"#.write(to: old.appendingPathComponent("ttys001.json"), atomically: true, encoding: .utf8)
        try #"{"title":"two"}"#.write(to: old.appendingPathComponent("ttys002.json"), atomically: true, encoding: .utf8)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.migrateBannerState()

        let new = home.appendingPathComponent(".config/ghoztty/banner-state")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("ttys001.json").path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("ttys002.json").path))
        // Copied, not moved: if the user keeps the plugin after all, their state
        // is still where the plugin expects it.
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("ttys001.json").path))
    }

    /// State the app already wrote is newer than anything the plugin left.
    @Test func doesNotOverwriteStateTheAppAlreadyHas() throws {
        let home = try tempHome()
        let old = home.appendingPathComponent(".claude/ghoztty-banner")
        let new = home.appendingPathComponent(".config/ghoztty/banner-state")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try #"{"title":"stale"}"#.write(to: old.appendingPathComponent("ttys001.json"), atomically: true, encoding: .utf8)
        try #"{"title":"current"}"#.write(to: new.appendingPathComponent("ttys001.json"), atomically: true, encoding: .utf8)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.migrateBannerState()

        let text = try String(contentsOf: new.appendingPathComponent("ttys001.json"), encoding: .utf8)
        #expect(text.contains("current"))
    }

    /// Nothing to carry across is a no-op, not a failure.
    @Test func missingPluginStateIsNotAnError() throws {
        let home = try tempHome()
        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.migrateBannerState()
    }

    // MARK: - Whole flow

    @Test func aSuccessfulRunUninstallsCarriesStateAndClearsTheLink() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)

        let old = home.appendingPathComponent(".claude/ghoztty-banner")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try #"{"title":"live"}"#.write(to: old.appendingPathComponent("ttys003.json"), atomically: true, encoding: .utf8)

        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let link = scripts.appendingPathComponent("ghoztty-banner.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent(".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh").path)

        let runner = Runner()
        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)
        try migration.run()

        #expect(runner.commands.count == 2)
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".config/ghoztty/banner-state/ttys003.json").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }
}
