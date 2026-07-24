import Foundation
import Testing
@testable import Ghostty

struct ReleaseNotesStoreVersionCompareTests {
    @Test func numericOrderingBeatsLexicographic() {
        #expect(ReleaseNotesStore.isNewer("1.10.0", than: "1.9.0"))
        #expect(!ReleaseNotesStore.isNewer("1.9.0", than: "1.10.0"))
    }

    @Test func equalIsNotNewer() {
        #expect(!ReleaseNotesStore.isNewer("1.4.0", than: "1.4.0"))
    }

    @Test func patchAndMinorBumps() {
        #expect(ReleaseNotesStore.isNewer("1.4.1", than: "1.4.0"))
        #expect(ReleaseNotesStore.isNewer("2.0.0", than: "1.99.99"))
    }
}

struct ReleaseNotesStorePartitionTests {
    private func note(_ v: String) -> VersionNotes {
        VersionNotes(version: v, sections: [
            ReleaseNoteSection(title: "Fork Changes",
                               items: [ReleaseNote(title: "Feature \(v)", text: "did \(v)")])
        ])
    }

    private var store: ReleaseNotesStore {
        ReleaseNotesStore(all: ["1.3.0", "1.4.0", "1.5.0", "1.6.0"].map(note))
    }

    @Test func newIsAboveSeenAndCappedAtCurrent() {
        let (new, installed) = store.partitioned(previousSeen: "1.4.0", current: "1.6.0")
        #expect(new.map(\.version) == ["1.6.0", "1.5.0"])       // newest first, ≤ current
        #expect(installed.map(\.version) == ["1.4.0", "1.3.0"]) // ≤ seen, newest first
    }

    @Test func versionsNewerThanCurrentAreDropped() {
        // Dev case: bundle carries notes newer than the running build.
        let (new, _) = store.partitioned(previousSeen: "1.3.0", current: "1.4.0")
        #expect(new.map(\.version) == ["1.4.0"])                // 1.5/1.6 dropped (> current)
    }

    @Test func nilPreviousMeansEverythingUpToCurrentIsNew() {
        let (new, installed) = store.partitioned(previousSeen: nil, current: "1.5.0")
        #expect(new.map(\.version) == ["1.5.0", "1.4.0", "1.3.0"])
        #expect(installed.isEmpty)
    }

    @Test func repromptOnSameVersionHasNoNewNotes() {
        let (new, installed) = store.partitioned(previousSeen: "1.6.0", current: "1.6.0")
        #expect(new.isEmpty)
        #expect(installed.map(\.version) == ["1.6.0", "1.5.0", "1.4.0", "1.3.0"])
    }
}

struct ReleaseNotesStoreAppcastDescriptionTests {
    @Test func decodesValidJSON() {
        let json = #"{"version":"1.24.0","sections":[{"title":"Fork Changes","items":[{"title":"Viewer","text":"open a website in a side pane"}]}]}"#
        let notes = ReleaseNotesStore.versionNotes(fromAppcastDescription: json)
        #expect(notes?.version == "1.24.0")
        #expect(notes?.sections.first?.items.first?.title == "Viewer")
    }

    @Test func nilForNilEmptyOrNonJSON() {
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: nil) == nil)
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: "") == nil)
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: "not json") == nil)
        #expect(ReleaseNotesStore.versionNotes(fromAppcastDescription: "<h1>HTML release notes</h1>") == nil)
    }
}

struct ReleaseNotesStoreLoadTests {
    @Test func nilDirectoryLoadsNothing() {
        #expect(ReleaseNotesStore(directory: nil).all.isEmpty)
    }

    @Test func loadsAndSkipsGarbageFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":"1.4.0","sections":[{"title":"X","items":[{"text":"hi"}]}]}"#
            .write(to: dir.appendingPathComponent("1.4.0.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: dir.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        let store = ReleaseNotesStore(directory: dir)
        #expect(store.all.map(\.version) == ["1.4.0"])
    }
}
