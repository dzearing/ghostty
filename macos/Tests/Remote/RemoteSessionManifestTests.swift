import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the WP-D2 remote-session manifest bookkeeping that the
/// sign-out/sign-in window lifecycle rides on: register/remove, the
/// crash-safe mark-don't-drain restore cycle (`snapshotForRestore` /
/// `releaseRestore` / `register(replacing:)`), persistence round-trips, and
/// the double-restore partition (`partitionForRestore`).
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

    /// The entries another launch would see: decoded straight from the
    /// persisted defaults (a fresh instance over the same suite).
    private func persisted(_ defaults: UserDefaults) -> [RemoteSessionManifest.Entry] {
        RemoteSessionManifest(defaults: defaults).allEntries()
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
        #expect(manifest.allEntries().isEmpty)
        #expect(persisted(defaults).isEmpty)
        // Removing an unknown id is a no-op.
        manifest.remove(UUID())
    }

    /// THE crash-safety property this contract exists for: snapshotting for
    /// restore must NOT touch the persisted manifest. If the app is killed
    /// while the restore is blocked (e.g. `RelayAccount.resolveToken()`
    /// sitting on a Keychain prompt), every entry must still be on disk for
    /// the next launch.
    @Test func snapshotForRestoreLeavesDiskAndMemoryIntact() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let a = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-a", name: "a",
            sessionID: "sess-a")
        let b = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-b", name: "b",
            sessionID: "sess-b")

        let snapshot = manifest.snapshotForRestore()
        #expect(snapshot.map(\.id) == [a, b])

        // Mark, don't drain: memory and disk still hold both entries — a
        // kill -9 right now loses nothing.
        #expect(manifest.allEntries().map(\.id) == [a, b])
        #expect(persisted(defaults).map(\.id) == [a, b])
    }

    /// While a snapshot is in flight, a second snapshot (the sign-in replay
    /// racing the launch restore) sees nothing — the same entry can never be
    /// double-restored (a second ATTACH would evict the first window).
    /// Releasing makes the entries snapshottable again (next retry).
    @Test func inFlightSetBlocksDoubleSnapshotUntilReleased() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let a = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-a", name: "a",
            sessionID: "sess-a")
        let b = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-b", name: "b",
            sessionID: "sess-b")

        let first = manifest.snapshotForRestore()
        #expect(first.count == 2)
        #expect(manifest.snapshotForRestore().isEmpty)

        // Release one (couldn't attempt: unreachable/no token/out of scope):
        // only it becomes available again; the other stays claimed.
        manifest.releaseRestore([a])
        let retry = manifest.snapshotForRestore()
        #expect(retry.map(\.id) == [a])
        #expect(manifest.snapshotForRestore().isEmpty)

        // Nothing was ever removed from disk throughout.
        #expect(persisted(defaults).map(\.id) == [a, b])
    }

    /// Restore SUCCESS: the fresh window's `register(..., replacing:)`
    /// supersedes the old entry — old gone, new persisted, and the old id is
    /// no longer restore-in-flight.
    @Test func registerReplacingSupersedesOldEntry() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let old = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box",
            sessionID: "sess-1", windowTitle: "build watcher")
        #expect(manifest.snapshotForRestore().map(\.id) == [old])

        let fresh = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box",
            sessionID: "sess-1", windowTitle: "build watcher",
            replacing: old)
        #expect(fresh != old)

        let onDisk = persisted(defaults)
        #expect(onDisk.map(\.id) == [fresh])
        #expect(onDisk[0].windowTitle == "build watcher")

        // The old id's in-flight mark was released with the replacement: a
        // later snapshot offers the FRESH entry (e.g. after the new window
        // is preserved at quit), not a phantom of the old one.
        #expect(manifest.snapshotForRestore().map(\.id) == [fresh])
    }

    /// Restore decided the session is GONE (agent probe failed): `remove`
    /// drops the entry from memory and disk, and clears its in-flight mark.
    @Test func removeDropsGoneSessionAndClearsInFlight() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let gone = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-a", name: "a",
            sessionID: "sess-gone")
        let kept = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-b", name: "b",
            sessionID: "sess-kept")

        #expect(manifest.snapshotForRestore().count == 2)
        manifest.remove(gone)

        #expect(manifest.allEntries().map(\.id) == [kept])
        #expect(persisted(defaults).map(\.id) == [kept])
        // `kept` is still claimed by the in-flight restore; `gone` is gone.
        #expect(manifest.snapshotForRestore().isEmpty)
    }

    /// Restore could NOT be attempted (relay unreachable / no token): the
    /// entry is simply released — untouched on disk — so the next launch
    /// retries it.
    @Test func unreachableEntryStaysUntouchedForNextLaunch() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let id = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box",
            sessionID: "sess-1", windowTitle: "prod logs")

        let snapshot = manifest.snapshotForRestore()
        #expect(snapshot.count == 1)
        manifest.releaseRestore([id])

        // Byte-for-byte survivor: same entry, same session, same title.
        let next = persisted(defaults)
        #expect(next.map(\.id) == [id])
        #expect(next[0].sessionID == "sess-1")
        #expect(next[0].windowTitle == "prod logs")

        // "Next launch" (fresh instance, empty in-flight set) can snapshot it.
        let relaunch = RemoteSessionManifest(defaults: defaults)
        #expect(relaunch.snapshotForRestore().map(\.id) == [id])
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
        let entries = second.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].id == id)
        #expect(entries[0].relayBase == "https://relay.test")
        #expect(entries[0].deviceID == "dev-1")
        #expect(entries[0].name == "box")
        #expect(entries[0].sessionID == "sess-42")
    }

    /// An account rename (WP-C2) renames EVERY entry for that device — open
    /// windows and restorable ones alike — and persists, so windows restored
    /// after a quit come back under the new name. Other devices are untouched.
    @Test func updateNameRenamesAllEntriesForDeviceAndPersists() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        _ = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "MaximusHome",
            sessionID: "sess-1")
        _ = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "MaximusHome",
            sessionID: "sess-2")
        _ = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-2", name: "other",
            sessionID: "sess-3")

        manifest.updateName(deviceID: "dev-1", name: "Home PC")
        // Unknown device is a no-op.
        manifest.updateName(deviceID: "dev-404", name: "nope")

        // Persisted: a fresh instance over the same defaults sees the rename.
        let reloaded = persisted(defaults)
        #expect(reloaded.count == 3)
        #expect(reloaded.filter { $0.deviceID == "dev-1" }.map(\.name) ==
                ["Home PC", "Home PC"])
        #expect(reloaded.first { $0.deviceID == "dev-2" }?.name == "other")
    }

    /// The user-set window title (a manual rename) round-trips through the
    /// manifest across instances — this is what puts the title back on a
    /// window restored after quit/relaunch or sign-out → sign-in. Clearing
    /// the rename (nil) persists too.
    @Test func windowTitleRoundTripsAcrossInstances() {
        let defaults = makeDefaults()
        let first = RemoteSessionManifest(defaults: defaults)

        // Captured at register time (the restore path re-registers with the
        // preserved title) ...
        let a = first.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box",
            sessionID: "sess-a", windowTitle: "build watcher")
        // ... or later via the rename seam (titleOverride didSet).
        let b = first.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "box",
            sessionID: "sess-b")
        first.updateWindowTitle(b, windowTitle: "prod logs")
        // Unknown id is a no-op.
        first.updateWindowTitle(UUID(), windowTitle: "nope")

        let entries = persisted(defaults)
        #expect(entries.count == 2)
        #expect(entries.first { $0.id == a }?.windowTitle == "build watcher")
        #expect(entries.first { $0.id == b }?.windowTitle == "prod logs")

        // Clearing the rename (user emptied the title ⇒ titleOverride nil)
        // persists as nil.
        let second = RemoteSessionManifest(defaults: defaults)
        second.updateWindowTitle(b, windowTitle: nil)
        let final = persisted(defaults)
        #expect(final.first { $0.id == b }?.windowTitle == nil)
    }

    /// A manifest persisted BEFORE the `windowTitle` field existed (no such
    /// key in the JSON) must still decode — the field is optional and simply
    /// comes back nil.
    @Test func decodesLegacyEntryWithoutWindowTitle() {
        let defaults = makeDefaults()
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001",\
        "relayBase":"https://relay.test",\
        "deviceID":"dev-legacy",\
        "sessionID":"sess-legacy",\
        "name":"old box"}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: RemoteSessionManifest.defaultsKey)

        let manifest = RemoteSessionManifest(defaults: defaults)
        let entries = manifest.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].deviceID == "dev-legacy")
        #expect(entries[0].sessionID == "sess-legacy")
        #expect(entries[0].name == "old box")
        #expect(entries[0].windowTitle == nil)
    }

    /// An explicit caller-supplied name (IPC `+new-remote-window --name=mx`)
    /// is PINNED: an account rename must not overwrite it — the window (and
    /// its restore) keeps the caller's label while unpinned entries for the
    /// same device adopt the new name. The pin round-trips through
    /// persistence so a restored window re-pins.
    @Test func updateNameSkipsPinnedEntries() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let pinned = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "mx",
            sessionID: "sess-1", namePinned: true)
        let unpinned = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "MaximusHome",
            sessionID: "sess-2")

        manifest.updateName(deviceID: "dev-1", name: "Home PC")

        let entries = persisted(defaults)
        #expect(entries.count == 2)
        let pinnedEntry = entries.first { $0.id == pinned }
        #expect(pinnedEntry?.name == "mx")
        #expect(pinnedEntry?.namePinned == true)
        #expect(entries.first { $0.id == unpinned }?.name == "Home PC")
    }

    /// A manifest persisted BEFORE the `namePinned` field existed decodes
    /// with the pin absent (nil ⇒ not pinned), so renames apply normally.
    @Test func decodesLegacyEntryWithoutNamePinned() {
        let defaults = makeDefaults()
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000002",\
        "relayBase":"https://relay.test",\
        "deviceID":"dev-legacy",\
        "sessionID":"sess-legacy",\
        "name":"old box"}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: RemoteSessionManifest.defaultsKey)

        let manifest = RemoteSessionManifest(defaults: defaults)
        manifest.updateName(deviceID: "dev-legacy", name: "new box")
        let entries = manifest.allEntries()
        #expect(entries.count == 1)
        #expect(entries[0].namePinned == nil)
        #expect(entries[0].name == "new box")
    }

    /// An account/machine rename (`updateName`) must not clobber the user-set
    /// WINDOW title — they are independent: the machine name feeds the pill
    /// and default naming, the window title is the user's manual rename.
    @Test func updateNameDoesNotClobberWindowTitle() {
        let defaults = makeDefaults()
        let manifest = RemoteSessionManifest(defaults: defaults)

        let id = manifest.register(
            relayBase: "https://relay.test", deviceID: "dev-1", name: "MaximusHome",
            sessionID: "sess-1", windowTitle: "deploy shell")

        manifest.updateName(deviceID: "dev-1", name: "Home PC")

        let entries = persisted(defaults)
        #expect(entries.count == 1)
        #expect(entries[0].id == id)
        #expect(entries[0].name == "Home PC")
        #expect(entries[0].windowTitle == "deploy shell")
    }

    /// The double-restore guard: entries whose id belongs to an OPEN window
    /// are skipped (re-attaching would evict the live window); everything
    /// else restores. Order is preserved on both sides.
    @Test func partitionForRestoreSplitsOnOpenEntryIDs() {
        func entry(_ device: String) -> RemoteSessionManifest.Entry {
            .init(id: UUID(), relayBase: "https://relay.test",
                  deviceID: device, sessionID: "sess-\(device)", name: device)
        }
        let a = entry("a"), b = entry("b"), c = entry("c")

        let (restore, skipOpen) = RemoteSessionManifest.partitionForRestore(
            [a, b, c], openEntryIDs: [b.id])
        #expect(restore.map(\.id) == [a.id, c.id])
        #expect(skipOpen.map(\.id) == [b.id])

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

    /// The instance wrapper reads the live manifest non-destructively —
    /// querying twice sees the same entries — but hides entries whose restore
    /// is currently in flight (offering them would just double-attach).
    @Test func restorableEntriesInstanceQueryIsNonDestructiveAndHidesInFlight() {
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

        // Non-destructive: same answer again.
        let second = manifest.restorableEntries(
            relayBase: "https://relay.test", deviceID: "dev-1", openEntryIDs: [])
        #expect(second.map(\.id) == [id])

        // A restore in flight hides the entry from the chooser query ...
        #expect(manifest.snapshotForRestore().count == 2)
        let during = manifest.restorableEntries(
            relayBase: "https://relay.test", deviceID: "dev-1", openEntryIDs: [])
        #expect(during.isEmpty)

        // ... and releasing it brings it back.
        manifest.releaseRestore([id])
        let after = manifest.restorableEntries(
            relayBase: "https://relay.test", deviceID: "dev-1", openEntryIDs: [])
        #expect(after.map(\.id) == [id])
    }
}
