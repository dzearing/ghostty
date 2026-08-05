// macos/Tests/Ghostty/SkillComponentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct SkillComponentTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rollsBackOnPartialFailure() throws {
        let home = try tempHome()
        // Force the process-feedback write to fail by placing a directory where its SKILL.md should go.
        let pfPath = home.appendingPathComponent(".copilot/skills/process-feedback/SKILL.md")
        try FileManager.default.createDirectory(at: pfPath, withIntermediateDirectories: true)
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(throws: (any Error).self) { try c.install() }
        // The first (ghoztty) skill must have been rolled back — no partial install left behind.
        let ghz = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        #expect(!FileManager.default.fileExists(atPath: ghz.path))
    }

    @Test func mixedStateReportsOutdated() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        try c.install()
        try FileManager.default.removeItem(at: home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md"))
        #expect(c.state() == .outdated)
    }

    @Test func installsBothSkillsIdempotentlyAndDetectsDrift() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .notInstalled)
        try c.install()
        #expect(c.state() == .installed)
        let ghz = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        let pf = home.appendingPathComponent(".copilot/skills/process-feedback/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: ghz.path))
        #expect(FileManager.default.fileExists(atPath: pf.path))
        try c.install() // idempotent
        #expect(c.state() == .installed)
        try "tampered <!-- ghoztty-managed -->".write(to: ghz, atomically: true, encoding: .utf8)
        #expect(c.state() == .outdated)
        try c.uninstall()
        #expect(c.state() == .notInstalled)
    }
}
