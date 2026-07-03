import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the WP-D2 remote-session manifest bookkeeping that the
/// sign-out/sign-in window lifecycle rides on: register/remove, the
/// takeAll/reinstate suspend-replay cycle, persistence round-trips, and the
/// double-restore partition (`partitionForRestore`).
///
/// Every test uses its own scratch `UserDefaults` suite so nothing touches
/// the real app manifest (`UserDefaults.ghostty`).
struct RemoteSessionManifestTests {
    /// A fresh, empty defaults suite unique to one test run.
    private func makeDefaults() -> UserDefaults {
        let suite = "RemoteSessionManifestTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func registerThenCleanCloseRemoves() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let id = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box")
        #expect(manifest.sessionID(for: id) == nil)

        manifest.setSessionID(id, sessionID: "sess-1")
        #expect(manifest.sessionID(for: id) == "sess-1")

        manifest.remove(id)
        #expect(manifest.takeAll().isEmpty)
        // Removing an unknown id is a no-op.
        manifest.remove(UUID())
    }

    /// The suspend/replay cycle used by sign-out → sign-in: entries preserved
    /// at sign-out (kept in the manifest) are drained by `takeAll()` at
    /// restore, and entries that can't be restored are `reinstate`d so a
    /// later replay retries them.
    @Test func takeAllDrainsAndReinstatePutsBack() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let a = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-a", name: "a",
            sessionID: "sess-a")
        _ = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-b", name: "b",
            sessionID: "sess-b")

        let taken = manifest.takeAll()
        #expect(taken.count == 2)
        // Drained: a second takeAll (e.g. a concurrent/duplicate restore)
        // sees nothing — restores can't double-run over the same entries.
        #expect(manifest.takeAll().isEmpty)

        // Put one back (restore couldn't be attempted); only it survives.
        let entryA = taken.first { $0.id == a }!
        manifest.reinstate(entryA)
        let remaining = manifest.takeAll()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == a)
        #expect(remaining[0].sessionID == "sess-a")
    }

    /// Entries persist across instances (quit/relaunch, and the sign-out →
    /// sign-in window suspend) via the injected defaults.
    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = RemoteSessionManifest(defaults: defaults)
        let id = first.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box")
        first.setSessionID(id, sessionID: "sess-42")

        let second = RemoteSessionManifest(defaults: defaults)
        let entries = second.takeAll()
        #expect(entries.count == 1)
        #expect(entries[0].id == id)
        #expect(entries[0].relayBase == "https://relay.test")
        #expect(entries[0].deviceID == "dev-1")
        #expect(entries[0].name == "box")
        #expect(entries[0].sessionID == "sess-42")

        // takeAll persisted the drain too: a third instance sees nothing.
        let third = RemoteSessionManifest(defaults: defaults)
        #expect(third.takeAll().isEmpty)
    }

    /// The double-restore guard: entries whose id belongs to an OPEN window
    /// are reinstated (re-attaching would evict the live window); everything
    /// else restores. Order is preserved on both sides.
    @Test func partitionForRestoreSplitsOnOpenEntryIDs() {
        func entry(_ device: String) -> RemoteSessionManifest.Entry {
            .init(id: UUID(), relayBase: "https://relay.test",
                  deviceID: device, sessionID: "sess-\(device)", name: device)
        }
        let a = entry("a"), b = entry("b"), c = entry("c")

        let (restore, reinstate) = RemoteSessionManifest.partitionForRestore(
            [a, b, c], openEntryIDs: [b.id])
        #expect(restore.map(\.id) == [a.id, c.id])
        #expect(reinstate.map(\.id) == [b.id])

        // No open windows ⇒ everything restores (the launch case).
        let (all, none) = RemoteSessionManifest.partitionForRestore(
            [a, b, c], openEntryIDs: [])
        #expect(all.count == 3)
        #expect(none.isEmpty)

        // Everything open ⇒ nothing restores.
        let (nothing, everything) = RemoteSessionManifest.partitionForRestore(
            [a, b, c], openEntryIDs: [a.id, b.id, c.id])
        #expect(nothing.isEmpty)
        #expect(everything.count == 3)
    }

    /// The chooser's "Restore" query: only entries on the SAME relay base +
    /// device, with a captured session UUID, and not bound to an open window
    /// count as restorable. Order is preserved.
    @Test func restorableEntriesFiltersMachineSessionAndOpenWindows() {
        func entry(
            relayBase: String = "https://relay.test",
            deviceID: String = "dev-1",
            sessionID: String? = "sess"
        ) -> RemoteSessionManifest.Entry {
            .init(id: UUID(), relayBase: relayBase, deviceID: deviceID,
                  sessionID: sessionID, name: deviceID)
        }

        let match1 = entry()
        let match2 = entry()
        let openOnMachine = entry()                       // bound to an open window
        let noSession = entry(sessionID: nil)             // never captured an id
        let emptySession = entry(sessionID: "")           // degenerate: nothing to attach
        let otherDevice = entry(deviceID: "dev-2")
        let otherRelay = entry(relayBase: "https://other.test")

        let all = [match1, noSession, otherDevice, match2, emptySession,
                   otherRelay, openOnMachine]
        let restorable = RemoteSessionManifest.restorableEntries(
            all,
            relayBase: "https://relay.test",
            deviceID: "dev-1",
            openEntryIDs: [openOnMachine.id])
        #expect(restorable.map(\.id) == [match1.id, match2.id])

        // No open windows ⇒ the open entry becomes restorable too.
        let noneOpen = RemoteSessionManifest.restorableEntries(
            all,
            relayBase: "https://relay.test",
            deviceID: "dev-1",
            openEntryIDs: [])
        #expect(noneOpen.map(\.id) == [match1.id, match2.id, openOnMachine.id])
    }

    /// The instance wrapper reads the live manifest without draining it —
    /// unlike `takeAll()`, querying twice sees the same entries.
    @Test func restorableEntriesInstanceQueryIsNonDestructive() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let id = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box",
            sessionID: "sess-1")
        _ = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "pending")

        let first = manifest.restorableEntries(
            relayBase: "https://relay.test", deviceID: "dev-1", openEntryIDs: [])
        #expect(first.map(\.id) == [id])

        // Non-destructive: same answer again, and takeAll still drains both.
        let second = manifest.restorableEntries(
            relayBase: "https://relay.test", deviceID: "dev-1", openEntryIDs: [])
        #expect(second.map(\.id) == [id])
        #expect(manifest.takeAll().count == 2)
    }
}
