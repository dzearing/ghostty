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
        /// The USER-set window title (`BaseTerminalController.titleOverride`,
        /// i.e. a manual rename via Change Title / the inline tab-title
        /// editor / IPC set-title), captured so a restored window comes back
        /// under the same title. Nil when the user never renamed the window
        /// (the shell-computed title is transient and not persisted). Optional
        /// so manifests persisted before this field decode fine (missing key
        /// ⇒ nil, same as `Machine.hostname`).
        var windowTitle: String? = nil
        /// The USER-set WINDOW-level title (`windowTitleOverride`) that pins
        /// the titlebar over any tab/pane title. Optional so older manifests
        /// decode fine (missing key ⇒ nil).
        var windowTitleOverride: String? = nil
        /// True when `name` was explicitly supplied by the caller (IPC
        /// `+new-remote-window --name=...`, see `Machine.namePinned`).
        /// Account renames (`updateName`) skip pinned entries so a restore
        /// brings the window back under its caller-supplied label. Optional
        /// so older manifests decode fine (missing ⇒ nil ⇒ not pinned).
        var namePinned: Bool? = nil
        /// The IPC target-registry name this window was registered under
        /// (`+new-remote-window --name=...`), persisted so a restored window
        /// is re-registered and stays addressable by `+read` / `+send-keys` /
        /// `+close --target=` across a quit/relaunch. Nil for windows not
        /// opened through the named IPC path. Optional so older manifests
        /// decode fine (missing key ⇒ nil).
        var ipcName: String? = nil
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [Entry]

    /// Ids of entries currently being restored (`snapshotForRestore()` was
    /// called and their fate is not yet decided). Transient — NEVER persisted:
    /// if the app dies mid-restore the set evaporates and the still-persisted
    /// entries are retried on the next launch. Guarded by `lock`. This is what
    /// keeps the launch restore and the sign-in replay from double-restoring
    /// the same entry (a second ATTACH would evict the first window, spec
    /// §5.3) now that snapshotting no longer drains.
    private var restoresInFlight: Set<UUID> = []

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
    ///
    /// `replacing`: the id of the OLD manifest entry this window supersedes
    /// (restore path — the new window re-ATTACHes the old entry's session).
    /// The old entry is removed and the fresh one appended under one lock and
    /// ONE defaults write, so there is no on-disk window where the session is
    /// recorded zero times (kill ⇒ lost window) — at worst a crash straddling
    /// the write leaves the old entry, which the next launch retries.
    @discardableResult
    func register(
        relayBase: String,
        deviceID: String,
        name: String?,
        sessionID: String? = nil,
        windowTitle: String? = nil,
        namePinned: Bool = false,
        ipcName: String? = nil,
        replacing replacedID: UUID? = nil
    ) -> UUID {
        let entry = Entry(
            id: UUID(),
            relayBase: relayBase,
            deviceID: deviceID,
            sessionID: sessionID,
            name: name,
            windowTitle: windowTitle,
            namePinned: namePinned ? true : nil,
            ipcName: ipcName)
        lock.lock()
        defer { lock.unlock() }
        if let replacedID {
            entries.removeAll { $0.id == replacedID }
            restoresInFlight.remove(replacedID)
        }
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

    /// Record the USER-set window title for an entry (nil ⇒ the user cleared
    /// the rename, back to the shell-computed title). Called from the
    /// `titleOverride` seam in `BaseTerminalController` on every user rename,
    /// so the persisted title is correct even if the app never gets a clean
    /// quit. Unknown ids are a no-op.
    func updateWindowTitle(_ id: UUID, windowTitle: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[idx].windowTitle != windowTitle else { return }
        entries[idx].windowTitle = windowTitle
        saveLocked()
    }

    /// Record the user-set WINDOW-level title (nil ⇒ cleared). Called from
    /// the `windowTitleOverride` seam in `BaseTerminalController`, same
    /// contract as `updateWindowTitle`. Unknown ids are a no-op.
    func updateWindowTitleOverride(_ id: UUID, title: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[idx].windowTitleOverride != title else { return }
        entries[idx].windowTitleOverride = title
        saveLocked()
    }

    /// Update the display name of EVERY entry for a device (account rename,
    /// WP-C2): windows restored after a quit must come back under the
    /// machine's current name, whether their entry is bound to an open window
    /// or waiting for a later launch. Entries whose name is PINNED (explicit
    /// IPC `--name=`) keep their caller-supplied label — that override is
    /// intentional and survives renames. Unknown device ids are a no-op.
    func updateName(deviceID: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for idx in entries.indices where entries[idx].deviceID == deviceID {
            guard entries[idx].namePinned != true else { continue }
            guard entries[idx].name != name else { continue }
            entries[idx].name = name
            changed = true
        }
        if changed { saveLocked() }
    }

    /// Remove an entry (clean close: user closed the window or the remote
    /// child exited; or a restore decided the entry's session is gone).
    /// Also releases any restore-in-flight mark for the id. Removing an
    /// unknown id is a no-op.
    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        restoresInFlight.remove(id)
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        saveLocked()
    }

    /// Snapshot every entry not already being restored, marking the returned
    /// ids restore-in-flight. **Mark, don't drain**: nothing is removed from
    /// memory or disk — the persisted manifest is only mutated when each
    /// entry's fate is actually decided, so a crash/kill at ANY point during
    /// the (async, possibly Keychain-blocked) restore leaves every undecided
    /// entry intact for the next launch. Per returned entry the caller MUST
    /// eventually do exactly one of:
    /// - restore succeeded → `register(..., replacing: entry.id)` (the fresh
    ///   window entry atomically supersedes the old one)
    /// - session gone / nothing to attach to → `remove(entry.id)`
    /// - could not attempt (unreachable, no token, out of scope, bound to an
    ///   open window) → `releaseRestore([entry.id])` — the entry stays put
    ///   and a later launch/sign-in retries.
    /// A concurrent snapshot (launch restore racing the sign-in replay) sees
    /// only entries the first snapshot didn't claim.
    func snapshotForRestore() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let available = entries.filter { !restoresInFlight.contains($0.id) }
        restoresInFlight.formUnion(available.map(\.id))
        return available
    }

    /// Release the restore-in-flight mark for entries whose restore could not
    /// be attempted (relay unreachable / no token / filtered out / bound to an
    /// open window). The entries themselves were never removed — they remain
    /// persisted for the next launch or sign-in replay to retry.
    func releaseRestore(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        restoresInFlight.subtract(ids)
    }

    /// Read-only snapshot of every entry (tests/diagnostics). Marks nothing
    /// in flight and mutates nothing.
    func allEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Split snapshotted entries into those safe to restore and those that
    /// must be released via `releaseRestore(_:)` untouched because they are
    /// still bound to an OPEN window (a live controller carries the entry id
    /// as its `remoteManifestEntryID`). Re-attaching a session that already
    /// has a live window would EVICT that window's client (spec §5.3); the
    /// sign-in restore path can hit this when a window was opened via the
    /// dev token while signed out. Pure and order-preserving, so the
    /// suspend/replay bookkeeping is unit-testable.
    static func partitionForRestore(
        _ entries: [Entry],
        openEntryIDs: Set<UUID>
    ) -> (restore: [Entry], skipOpen: [Entry]) {
        var restore: [Entry] = []
        var skipOpen: [Entry] = []
        for entry in entries {
            if openEntryIDs.contains(entry.id) {
                skipOpen.append(entry)
            } else {
                restore.append(entry)
            }
        }
        return (restore, skipOpen)
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
    /// that snapshots the live entry list under the lock. Read-only, so the
    /// chooser can query freely. Entries with a restore already in flight are
    /// excluded — they are being handled and offering them as "restorable"
    /// would just double-attach.
    func restorableEntries(
        relayBase: String,
        deviceID: String,
        openEntryIDs: Set<UUID>
    ) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Self.restorableEntries(
            entries.filter { !restoresInFlight.contains($0.id) },
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
            .flatMap { (pane: PaneView) -> String? in
                guard let surface = pane.surface else { return nil }
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
