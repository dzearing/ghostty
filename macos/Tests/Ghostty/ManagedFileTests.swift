// macos/Tests/Ghostty/ManagedFileTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ManagedFileTests {
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesThenReportsInstalled() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ghoztty.json")
        let body = "{}\n// ghoztty-managed"
        try ManagedFile.write(body, to: url, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        #expect(ManagedFile.state(at: url, expected: body, marker: "ghoztty-managed") == .installed)
    }

    @Test func driftReportsOutdated() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ghoztty.json")
        try ManagedFile.write("old // ghoztty-managed", to: url, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        #expect(ManagedFile.state(at: url, expected: "new // ghoztty-managed", marker: "ghoztty-managed") == .outdated)
    }

    @Test func refusesUnmanagedOverwrite() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ghoztty.json")
        try "user's own file".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ManagedFileError.self) {
            try ManagedFile.write("x // ghoztty-managed", to: url, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "user's own file")
    }

    @Test func removeOnlyManaged() throws {
        let dir = try tempDir()
        let managed = dir.appendingPathComponent("a")
        let foreign = dir.appendingPathComponent("b")
        try ManagedFile.write("m // ghoztty-managed", to: managed, marker: "ghoztty-managed", mode: 0o600, fileManager: .default)
        try "foreign".write(to: foreign, atomically: true, encoding: .utf8)
        try ManagedFile.removeIfManaged(at: managed, marker: "ghoztty-managed", fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
        #expect(throws: ManagedFileError.self) {
            try ManagedFile.removeIfManaged(at: foreign, marker: "ghoztty-managed", fileManager: .default)
        }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }
}
