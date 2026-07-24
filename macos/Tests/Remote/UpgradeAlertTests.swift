import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct UpgradeAlertTests {
    private func sampleStore() -> ReleaseNotesStore {
        ReleaseNotesStore(all: [
            VersionNotes(version: "1.5.0", sections: [
                ReleaseNoteSection(title: "Fork Changes",
                                   items: [ReleaseNote(title: "New thing", text: "does X")])
            ])
        ])
    }

    @Test func copyIsPluralAndBrandedGhoztty() {
        let alert = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 3, previousSeen: "1.4.0", current: "1.5.0", store: sampleStore())
        #expect(alert.messageText == "Restart to finish updating Ghoztty?")
        #expect(alert.informativeText.contains("3 open terminal sessions"))
        #expect(!alert.informativeText.lowercased().contains("ghostty ")) // no Z-less leak
        #expect(alert.buttons.map(\.title) == ["Update Now", "Later"])
        #expect(alert.alertStyle == .warning)
    }

    @Test func singularSessionText() {
        let alert = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 1, previousSeen: "1.4.0", current: "1.5.0", store: sampleStore())
        #expect(alert.informativeText.contains("1 open terminal session —"))
    }

    @Test func accessoryPresentWhenNotesExistAbsentWhenEmpty() {
        let withNotes = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 2, previousSeen: "1.4.0", current: "1.5.0", store: sampleStore())
        #expect(withNotes.accessoryView != nil)

        let noNotes = LocalAgentManager.makeUpgradeAlert(
            liveSessionCount: 2, previousSeen: "1.4.0", current: "1.5.0",
            store: ReleaseNotesStore(all: []))
        #expect(noNotes.accessoryView == nil)
    }
}
