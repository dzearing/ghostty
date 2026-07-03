import Foundation
import GhosttyKit

/// WP-D2 (remote-relay-roadmap §2.4): a local manifest of open relay-backed
/// remote windows so they survive quitting and reopening the app.
///
/// The agent already persists sessions across disconnect (`SessionStore`,
/// detach ≠ terminate, remote-machines spec §7.1) — so restoring a window is
/// just re-`ATTACH`ing by session UUID through the relay. This class records
/// what to re-attach to:
///
/// - An entry is **registered** when a relay remote window opens (dial path or
///   restore path) and its session UUID is filled in once the termio thread
///   has opened/attached the agent session (the id is published async by
///   `ghostty_surface_remote_session_id`).
/// - The entry is **removed on a clean close** (user closes the window, or the
///   remote child exits) — see `BaseTerminalController.windowWillClose`.
/// - The entry is **kept on app quit** (`AppDelegate.isQuitting` guards the
///   removal) so `AppDelegate.restoreRemoteWindows()` can re-attach on the
///   next launch.
///
/// Persistence: a JSON-encoded array under a `UserDefaults.ghostty` key. The
/// debug and release apps have different bundle ids, so their manifests are
/// naturally separate defaults domains (the debug app never restores release
/// windows and vice versa).
final class RemoteSessionManifest {
    static let shared = RemoteSessionManifest()

    /// The UserDefaults key holding the JSON-encoded `[Entry]`.
    static let defaultsKey = "RemoteSessionManifest"

    /// One open (or restorable) relay remote window.
    struct Entry: Codable, Identifiable {
        /// Stable identity for this manifest entry (NOT the agent session id).
        let id: UUID
        /// Relay base URL (e.g. `https://relay.example.com`).
        let relayBase: String
        /// Agent device id on the relay.
        let deviceID: String
        /// The agent session UUID to re-`ATTACH` to. Nil until the termio
        /// thread has opened the session and we captured the id; entries that
        /// never resolve a session id are dropped at restore (nothing to
        /// attach to).
        var sessionID: String?
        /// Friendly display name (agent-reported hostname or chooser name).
        var name: String?
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [Entry]

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    /// Register a newly-opened relay remote window. Returns the entry id the
    /// window's controller should carry (`remoteManifestEntryID`) so a clean
    /// close can remove it.
    @discardableResult
    func register(
        relayBase: String,
        deviceID: String,
        name: String?,
        sessionID: String? = nil
    ) -> UUID {
        let entry = Entry(
            id: UUID(),
            relayBase: relayBase,
            deviceID: deviceID,
            sessionID: sessionID,
            name: name)
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        saveLocked()
        return entry.id
    }

    /// Record the agent session UUID for an entry once it is known.
    func setSessionID(_ id: UUID, sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].sessionID = sessionID
        saveLocked()
    }

    /// The recorded agent session UUID for an entry, if known. Used by the
    /// WP-D1 reconnect path as a fallback re-ATTACH target when the live
    /// surface hasn't published its session id.
    func sessionID(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first(where: { $0.id == id })?.sessionID
    }

    /// Update the display name of EVERY entry for a device (account rename,
    /// WP-C2): windows restored after a quit must come back under the
    /// machine's current name, whether their entry is bound to an open window
    /// or waiting for a later launch. Unknown device ids are a no-op.
    func updateName(deviceID: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for idx in entries.indices where entries[idx].deviceID == deviceID {
            guard entries[idx].name != name else { continue }
            entries[idx].name = name
            changed = true
        }
        if changed { saveLocked() }
    }

    /// Remove an entry (clean close: user closed the window or the remote
    /// child exited). Removing an unknown id is a no-op.
    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        saveLocked()
    }

    /// Atomically take every persisted entry for restore-at-launch. Successful
    /// restores re-register (a fresh entry bound to the new window); entries
    /// whose relay/agent was unreachable are put back via `reinstate` so the
    /// NEXT launch retries; entries whose session is gone are simply dropped.
    func takeAll() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let taken = entries
        entries = []
        saveLocked()
        return taken
    }

    /// Put back an entry taken by `takeAll` whose restore could not be
    /// attempted (relay unreachable / no token) so a later launch retries.
    func reinstate(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        saveLocked()
    }

    /// Split entries drained by `takeAll()` into those safe to restore and
    /// those that must go straight back via `reinstate(_:)` because they are
    /// still bound to an OPEN window (a live controller carries the entry id
    /// as its `remoteManifestEntryID`). Re-attaching a session that already
    /// has a live window would EVICT that window's client (spec §5.3); the
    /// sign-in restore path can hit this when a window was opened via the
    /// dev token while signed out. Pure and order-preserving, so the
    /// suspend/replay bookkeeping is unit-testable.
    static func partitionForRestore(
        _ entries: [Entry],
        openEntryIDs: Set<UUID>
    ) -> (restore: [Entry], reinstate: [Entry]) {
        var restore: [Entry] = []
        var reinstate: [Entry] = []
        for entry in entries {
            if openEntryIDs.contains(entry.id) {
                reinstate.append(entry)
            } else {
                restore.append(entry)
            }
        }
        return (restore, reinstate)
    }

    /// The entries for ONE machine that could actually be restored right now:
    /// same relay base + device id, a captured session UUID (something to
    /// re-`ATTACH` to — entries that never resolved one are dropped at restore
    /// anyway), and NOT currently bound to an open window (same open-entry
    /// bookkeeping as `partitionForRestore(_:openEntryIDs:)`; re-attaching a
    /// live window's session would evict it, spec §5.3). Drives the machine
    /// chooser's contextual "Restore" button. Pure and order-preserving so
    /// the query is unit-testable.
    static func restorableEntries(
        _ entries: [Entry],
        relayBase: String,
        deviceID: String,
        openEntryIDs: Set<UUID>
    ) -> [Entry] {
        entries.filter { entry in
            entry.relayBase == relayBase
                && entry.deviceID == deviceID
                && !(entry.sessionID?.isEmpty ?? true)
                && !openEntryIDs.contains(entry.id)
        }
    }

    /// Instance wrapper for `restorableEntries(_:relayBase:deviceID:openEntryIDs:)`
    /// that snapshots the live entry list under the lock. Read-only: nothing
    /// is drained (unlike `takeAll()`), so the chooser can query freely.
    func restorableEntries(
        relayBase: String,
        deviceID: String,
        openEntryIDs: Set<UUID>
    ) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Self.restorableEntries(
            entries,
            relayBase: relayBase,
            deviceID: deviceID,
            openEntryIDs: openEntryIDs)
    }

    private func saveLocked() {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: Session-id capture

    /// Poll the window's first surface for its live agent session UUID and
    /// record it in the manifest. The termio thread publishes the id only
    /// after OPEN/ATTACH completes (async, a network round-trip after window
    /// creation), so this retries on the main queue for up to ~30s and then
    /// gives up (an entry with no session id is dropped at restore).
    @MainActor
    static func captureSessionID(
        of controller: BaseTerminalController,
        entryID: UUID,
        attempt: Int = 0
    ) {
        // The window was closed (its entry removed) or re-tracked; stop.
        guard controller.remoteManifestEntryID == entryID else { return }

        let sid: String? = controller.surfaceTree
            .first(where: { _ in true })
            .flatMap { (view: Ghostty.SurfaceView) -> String? in
                guard let surface = view.surface else { return nil }
                let s = Ghostty.AllocatedString(
                    ghostty_surface_remote_session_id(surface)).string
                return s.isEmpty ? nil : s
            }
        if let sid {
            shared.setSessionID(entryID, sessionID: sid)
            return
        }

        guard attempt < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak controller] in
            guard let controller else { return }
            captureSessionID(of: controller, entryID: entryID, attempt: attempt + 1)
        }
    }
}
