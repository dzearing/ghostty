import Foundation
import GhosttyKit

/// A remote machine that can host terminal sessions over the Ghoztty remote
/// transport. See remote-machines design WP4 / WP-A1.
///
/// Two transports are supported:
/// - **TCP** (default): dial `host:port` directly.
/// - **Relay**: when `relayBase` and `deviceID` are both set, the machine is
///   reached through a rendezvous relay instead of a direct TCP dial. The TCP
///   `host`/`port` are then unused for connecting (`host` carries the relay
///   base for display/filtering, `port` is 0).
///
/// Optional relay fields (rather than a full transport enum) were chosen to keep
/// the many existing `host`/`port`/`endpoint` TCP call sites compiling unchanged
/// — only the connect dispatch needs to branch on `isRelay`.
struct Machine: Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    /// Relay base URL. When set together with `deviceID`, this machine uses the
    /// relay transport instead of direct TCP.
    var relayBase: String?
    /// Agent device id used by the relay transport.
    var deviceID: String?
    /// Live online status from the relay's device directory (WP-C2). Nil for
    /// non-relay machines and for relay machines that haven't been refreshed
    /// from the account list yet.
    var online: Bool?
    /// The machine's OS-reported hostname from the relay's device directory.
    /// Distinct from `name` (the user-facing display name, which a rename
    /// changes while the hostname stays put). Nil when the relay doesn't know
    /// it yet and for non-relay machines.
    var hostname: String?
    /// True when `name` was explicitly supplied by the caller (IPC
    /// `+new-remote-window --name=...`). A pinned name is INTENTIONAL and wins
    /// over account renames (WP-C2): the window keeps its caller-supplied
    /// label; only `hostname` refreshes on a rename. New tabs/splits inherit
    /// the pin through the shared connection's machine snapshot, and restored
    /// windows re-pin via `RemoteSessionManifest.Entry.namePinned`.
    var namePinned: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        relayBase: String? = nil,
        deviceID: String? = nil,
        online: Bool? = nil,
        hostname: String? = nil,
        namePinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.relayBase = relayBase
        self.deviceID = deviceID
        self.online = online
        self.hostname = hostname
        self.namePinned = namePinned
    }

    /// True when this machine is reached through a rendezvous relay.
    var isRelay: Bool { relayBase != nil && deviceID != nil }

    /// A human-friendly string for display: the device id for relay machines,
    /// otherwise "host:port".
    var endpoint: String { isRelay ? (deviceID ?? host) : "\(host):\(port)" }

    /// True when this machine refers to THIS Mac. Used to suppress remote-only
    /// UI (e.g. the titlebar machine pill) for a "remote" window whose agent
    /// actually runs on the local machine, and to hide this Mac's own relay
    /// device from the chooser list.
    ///
    /// Both identity fields are checked: the display `name` (which for a
    /// direct-TCP/loopback machine carries the hostname or address) AND the
    /// agent-reported `hostname`. The hostname check matters because `name` is
    /// the user-facing display name — a machine renamed to "My Mac" whose
    /// hostname is this Mac must still count as local.
    var isLocalMachine: Bool {
        if Self.isLocalHostname(name) { return true }
        if let hostname, Self.isLocalHostname(hostname) { return true }
        return false
    }

    /// Whether `hostname` names the local machine.
    ///
    /// Hostnames arrive in mixed forms — mDNS `Foo.local` from an agent's
    /// gethostname, bare `foo` from POSIX, arbitrary capitalization — so both
    /// sides are normalized before comparing: lowercase, then strip a trailing
    /// `.local` mDNS suffix. The local side considers both
    /// `ProcessInfo.processInfo.hostName` and every `Host.current()` name to
    /// cover the `.local`/bare variants macOS reports.
    static func isLocalHostname(_ hostname: String) -> Bool {
        let target = normalizeHostname(hostname)
        guard !target.isEmpty else { return false }
        if isLoopback(target) { return true }
        return localHostnames.contains(target)
    }

    /// Loopback endpoints are the local machine by definition: a TCP dial to
    /// 127.0.0.0/8, `::1`, or `localhost` never leaves this Mac, so the pill
    /// (remote-only UI) must not show for them either.
    private static func isLoopback(_ normalized: String) -> Bool {
        if normalized == "localhost" || normalized == "::1" { return true }
        return normalized.hasPrefix("127.")
    }

    /// Normalized names of the local machine, computed once (hostname lookups
    /// can be slow and the machine name effectively never changes mid-session).
    private static let localHostnames: Set<String> = {
        var names = Host.current().names
        names.append(ProcessInfo.processInfo.hostName)
        return Set(names.map(normalizeHostname))
    }()

    private static func normalizeHostname(_ s: String) -> String {
        var s = s.lowercased()
        if s.hasSuffix(".local") { s.removeLast(".local".count) }
        return s
    }
}

/// In-memory registry of known remote machines.
///
/// Relay machines are the account's resource list, fetched live from the
/// relay's device directory (`GET /v1/client/devices`, WP-C2) whenever the
/// chooser opens — and re-fetched on a quiet poll while it stays open, so
/// online status tracks reality. They exist ONLY while account credentials
/// exist: signing
/// out (or refreshing with no/rejected credentials) clears every relay entry
/// — machines are per-account, so a signed-out chooser must never show a
/// previous account's devices. Non-relay (direct TCP) entries are never
/// touched by the fetch or by sign-out.
///
/// TODO(wp4): load TCP machines from ~/.config/ghostty (e.g. a `[machines]`
/// section or a dedicated machines.toml) in addition to the account list.
@MainActor
final class MachineRegistry: ObservableObject {
    static let shared = MachineRegistry()

    @Published private(set) var machines: [Machine]

    /// True while a directory fetch is in flight (drives the chooser's
    /// footer spinner).
    @Published private(set) var isRefreshing = false

    /// The last directory-fetch failure, shown in the chooser footer. Cleared
    /// when a refresh starts.
    @Published private(set) var lastRefreshError: String?

    /// True while ANY directory fetch is in flight, including quiet background
    /// polls (which deliberately don't drive the published `isRefreshing`
    /// spinner). This is the overlap guard: a poll tick that lands while a
    /// fetch is still running simply no-ops instead of piling up requests.
    private var refreshInFlight = false

    /// Consecutive quiet-poll failures. A single blip while the chooser sits
    /// open must not flash error UI (the last-known list stays useful), but a
    /// PERSISTENT failure should surface the same way an initial-load failure
    /// does — after this many misses in a row.
    private var quietFailureCount = 0
    private static let quietFailureThreshold = 3

    /// Stable UUID per relay device id so SwiftUI identity (selection, rows)
    /// survives refreshes that rebuild the `Machine` values.
    private var deviceUUIDs: [String: UUID] = [:]

    /// True when a relay token source is available (signed-in Google account
    /// or dev token), i.e. the account device list is reachable. The chooser
    /// opens even with zero machines when this is set (the list populates on
    /// fetch).
    var hasRelayAccount: Bool { RelayAccount.hasCredentials }

    init() {
        // Relay machines are account resources and only ever come from the
        // directory fetch — there is deliberately no pre-auth seed (a
        // signed-out chooser must show no account devices). TCP machines can
        // still be `add`ed at runtime.
        self.machines = []
    }

    func add(_ machine: Machine) {
        machines.append(machine)
    }

    /// Drop every relay (account) machine, keeping direct-TCP entries.
    /// Called on sign-out and on credential-less/401 refreshes: the relay
    /// list belongs to an account, so without a valid account it must not be
    /// shown. Publishes immediately, so an open chooser re-renders live.
    func clearRelayMachines() {
        machines.removeAll { $0.isRelay }
        deviceUUIDs.removeAll()
    }

    /// Refresh the relay account's device list (WP-C2). On success, relay
    /// machines are replaced by the fetched list (with online status); TCP
    /// machines are untouched. With no credentials at all, relay entries are
    /// CLEARED (not kept stale) — same when the relay rejects the credentials
    /// (401, e.g. an expired session), which additionally surfaces the error.
    /// Other failures (network blips) keep the current list and set
    /// `lastRefreshError`.
    ///
    /// `quiet` marks a background poll tick (the chooser's live refresh):
    /// the footer spinner stays off and a transient failure keeps the
    /// last-known list WITHOUT flashing error text — only
    /// `quietFailureThreshold` consecutive misses surface the error, and the
    /// next success clears it. Auth failures are never quiet: an expired or
    /// rejected session clears the list either way (account devices must not
    /// outlive their authorization).
    func refreshFromRelay(quiet: Bool = false) async {
        guard !refreshInFlight else { return }
        guard RelayAccount.hasCredentials else {
            clearRelayMachines()
            return
        }
        refreshInFlight = true
        if !quiet {
            isRefreshing = true
            lastRefreshError = nil
        }
        defer {
            refreshInFlight = false
            if !quiet { isRefreshing = false }
        }
        // Token via the WP-B2 seam (account ID token, dev-token fallback);
        // may await a token refresh before the directory call.
        guard let client = await RelayDirectoryClient.current() else {
            // Credentials existed but no token could be resolved (e.g. the
            // refresh-token grant failed) — treat like signed out.
            clearRelayMachines()
            lastRefreshError =
                RelayDirectoryClient.DirectoryError.noAccount.localizedDescription
            return
        }
        do {
            apply(devices: try await client.listDevices())
            quietFailureCount = 0
            // Publish-only-on-change, like `apply`: a steady-state poll must
            // not churn observers every tick.
            if lastRefreshError != nil { lastRefreshError = nil }
        } catch RelayDirectoryClient.DirectoryError.unauthorized {
            // Expired/rejected session: don't keep showing an account list we
            // are no longer authorized for.
            clearRelayMachines()
            lastRefreshError =
                RelayDirectoryClient.DirectoryError.unauthorized.localizedDescription
        } catch {
            if quiet {
                quietFailureCount += 1
                guard quietFailureCount >= Self.quietFailureThreshold else { return }
            }
            lastRefreshError = error.localizedDescription
        }
    }

    /// Delete a device from the relay account (revoking its credential) and
    /// drop it from the registry. Throws `DirectoryError` on 401/404/etc so
    /// the caller can surface it; a 404 still removes the local row (the
    /// device is already gone server-side).
    func removeFromAccount(deviceID: String) async throws {
        guard let client = await RelayDirectoryClient.current() else {
            throw RelayDirectoryClient.DirectoryError.noAccount
        }
        do {
            try await client.delete(deviceID: deviceID)
        } catch RelayDirectoryClient.DirectoryError.notFound {
            machines.removeAll { $0.deviceID == deviceID }
            throw RelayDirectoryClient.DirectoryError.notFound
        }
        machines.removeAll { $0.deviceID == deviceID }
    }

    /// userInfo key carrying the updated `Machine` in a
    /// `.ghosttyMachineDidRename` notification.
    static let renamedMachineKey = "machine"

    /// Rename a device on the relay account and update the registry row with
    /// the relay's response. Throws `DirectoryError` on failure.
    ///
    /// A successful rename also propagates LIVE to everything that carries the
    /// old name:
    /// - open windows on that device (via `.ghosttyMachineDidRename`, observed
    ///   by `BaseTerminalController` — updates the titlebar pill, the window
    ///   title suffix, and the `AXGhosttyMachine` accessibility attribute)
    /// - the WP-D2 session manifest, so windows restored after a quit come
    ///   back under the new name.
    func renameOnAccount(deviceID: String, to name: String) async throws {
        guard let client = await RelayDirectoryClient.current() else {
            throw RelayDirectoryClient.DirectoryError.noAccount
        }
        let dev = try await client.rename(deviceID: deviceID, to: name)
        // Update the chooser row when it's still present — but the propagation
        // below deliberately does NOT depend on finding it. The registry list
        // can be rebuilt or cleared while the PATCH is in flight (quiet poll,
        // 401 sweep); the relay rename still SUCCEEDED, so open windows and
        // the restore manifest must hear about it either way.
        var renamed = Machine(
            name: dev.name,
            host: RelayDirectoryClient.defaultBase,
            port: 0,
            relayBase: RelayDirectoryClient.defaultBase,
            deviceID: deviceID,
            online: dev.online,
            hostname: dev.hostname)
        if let idx = machines.firstIndex(where: { $0.deviceID == deviceID }) {
            machines[idx].name = dev.name
            machines[idx].online = dev.online
            machines[idx].hostname = dev.hostname
            renamed = machines[idx]
        }
        propagateRename(renamed)
    }

    /// Push a device rename to everything that carries the old name:
    /// - the WP-D2 restore manifest (`updateName` — skips entries whose name
    ///   is pinned by an explicit `--name`), so future restores use the new
    ///   name, and
    /// - every open window on that device, via `.ghosttyMachineDidRename`
    ///   (observed by `BaseTerminalController`: pill, title suffix,
    ///   `AXGhosttyMachine`) — INCLUDING manifest-restored windows, which
    ///   match on the same device id.
    private func propagateRename(_ machine: Machine) {
        guard let deviceID = machine.deviceID else { return }
        RemoteSessionManifest.shared.updateName(deviceID: deviceID, name: machine.name)
        NotificationCenter.default.post(
            name: .ghosttyMachineDidRename,
            object: self,
            userInfo: [Self.renamedMachineKey: machine])
    }

    /// Rebuild `machines` from a fetched device list: authoritative relay
    /// entries (stable UUIDs per device id, relay's own — stable — order)
    /// after any direct-TCP entries. Publishes only when something actually
    /// changed, so a steady-state background poll doesn't churn observers
    /// every tick.
    ///
    /// A display-name change observed HERE also propagates like an in-app
    /// rename (`propagateRename`): the directory is the authoritative source,
    /// and a rename can originate outside this process (another Mac, the web,
    /// another app instance — whose NotificationCenter post this process can
    /// never receive). Without this, such a rename would update the chooser
    /// rows but leave every open window's pill/`AXGhosttyMachine` and the
    /// restore manifest stale.
    private func apply(devices: [RelayDirectoryClient.Device]) {
        let relayBase = RelayDirectoryClient.defaultBase
        let relayMachines = devices.map { dev -> Machine in
            let uuid: UUID
            if let existing = deviceUUIDs[dev.id] {
                uuid = existing
            } else {
                uuid = UUID()
                deviceUUIDs[dev.id] = uuid
            }
            return Machine(
                id: uuid,
                name: dev.name,
                host: relayBase,
                port: 0,
                relayBase: relayBase,
                deviceID: dev.id,
                online: dev.online,
                hostname: dev.hostname
            )
        }
        // Pre-refresh names, so renames can be detected after the swap. Only
        // devices KNOWN before the refresh count — a device seen for the
        // first time isn't a rename.
        let previousNames: [String: String] = Dictionary(
            machines.compactMap { m in m.deviceID.map { ($0, m.name) } },
            uniquingKeysWith: { first, _ in first })
        let updated = machines.filter { !$0.isRelay } + relayMachines
        if updated != machines {
            machines = updated
            for machine in relayMachines {
                guard let deviceID = machine.deviceID,
                      let old = previousNames[deviceID],
                      old != machine.name else { continue }
                propagateRename(machine)
            }
        }
    }
}

/// WP-D1: the per-WINDOW connection status shown in the titlebar pill and
/// driven by `BaseTerminalController`'s reconnect state machine. Distinct from
/// `RemoteConnection.LinkState` (the transport-level FSM of ONE connection
/// handle): a window can outlive its original connection handle by dialing a
/// replacement and re-`ATTACH`ing, so its status spans handles.
enum RemoteWindowConnectionState: Equatable {
    /// The window's connection is live.
    case connected
    /// The connection dropped; the controller is retrying (dial + re-ATTACH)
    /// with backoff. `attempt` is 1-based for the "attempt N" UI.
    case reconnecting(attempt: Int)
    /// Retries exhausted (or the session is gone / we were evicted). The
    /// window is kept, clearly marked; no further retries.
    case disconnected
}

extension Notification.Name {
    /// Posted (on the main queue) by `RemoteConnection` when its transport-level
    /// link state changes. Object is the `RemoteConnection`.
    static let ghosttyRemoteConnectionLinkDidChange =
        Notification.Name("ghosttyRemoteConnectionLinkDidChange")

    /// Posted (on the main thread) by `MachineRegistry` after a device rename
    /// succeeds on the relay account. userInfo[`MachineRegistry.renamedMachineKey`]
    /// is the updated `Machine` (registry row). Open windows on that device
    /// observe this to refresh their pill / title / `AXGhosttyMachine`.
    static let ghosttyMachineDidRename =
        Notification.Name("ghosttyMachineDidRename")
}

/// Strong owner of a live `ghostty_remote_connection_t`.
///
/// The underlying connection handle may be shared by every surface/split in a
/// remote window. It MUST NOT be freed while any surface still uses it. The
/// `TerminalController` (window) holds the only strong reference to this object,
/// and child surfaces/splits reuse the same `handle` via the inherited
/// `SurfaceConfiguration`. The connection is freed exactly once, when the owning
/// controller (and therefore this object) is deallocated.
final class RemoteConnection {
    let handle: ghostty_remote_connection_t

    /// The machine this connection is dialed to. The connection's IDENTITY
    /// (relay base + device id / host + port) never changes; the setter exists
    /// only so an account rename can refresh the display fields (`name`,
    /// `hostname`) — new tabs/splits inherit this snapshot, so it must not go
    /// stale. Main-thread only, like `linkState`.
    private(set) var machine: Machine

    /// Refresh the machine snapshot after an account rename (display fields
    /// only — see `machine`). Main-thread only.
    func updateMachine(_ machine: Machine) {
        self.machine = machine
    }

    /// Transport-level link state (spec §5.1), mirrored from the Zig FSM.
    /// Values match `GHOSTTY_REMOTE_CONN_*`.
    enum LinkState: Int32 {
        case connected = 0
        case degraded = 1
        case reconnecting = 2
        case reattaching = 3
        case dead = 4
    }

    /// The last observed transport link state. Main-thread only (updated by the
    /// main-queue hop in the state callback).
    private(set) var linkState: LinkState = .connected

    /// Stable, weakly-owning context for the C state callback. The dispatched
    /// main-queue blocks retain the box (not the connection), so a callback
    /// that raced our dealloc resolves `owner` to nil instead of crashing.
    private final class StateBox {
        weak var owner: RemoteConnection?
    }
    private let stateBox = StateBox()

    init(handle: ghostty_remote_connection_t, machine: Machine) {
        self.handle = handle
        self.machine = machine

        // Observe transport link-state transitions (WP-D1). The callback fires
        // on a connection-internal thread with an internal lock held, so it
        // must only capture the value and hop to the main queue.
        stateBox.owner = self
        ghostty_remote_connection_set_state_callback(handle, { state, userdata in
            guard let userdata else { return }
            let box = Unmanaged<StateBox>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let owner = box.owner else { return }
                let new = LinkState(rawValue: state) ?? .connected
                guard owner.linkState != new else { return }
                Ghostty.logger.info(
                    "remote link state: \(String(describing: owner.linkState)) -> \(String(describing: new)) (\(owner.machine.name, privacy: .public))")
                owner.linkState = new
                NotificationCenter.default.post(
                    name: .ghosttyRemoteConnectionLinkDidChange,
                    object: owner)
            }
        }, Unmanaged.passUnretained(stateBox).toOpaque())

        // Seed from the live FSM: a transition that happened BEFORE the
        // callback registered (e.g. the link dropped right after the dial)
        // would otherwise never be observed — the FSM only notifies on change.
        let seeded = ghostty_remote_connection_state(handle)
        if seeded >= 0, let state = LinkState(rawValue: seeded) {
            linkState = state
        }
    }

    /// Current round-trip latency to the agent in milliseconds, or nil if
    /// unavailable.
    var latencyMs: Int32? {
        let v = ghostty_remote_connection_latency_ms(handle)
        return v >= 0 ? v : nil
    }

    deinit {
        // Clear the state callback FIRST: this synchronizes with an in-flight
        // invocation (once it returns, no further callback can fire), so the
        // free below can never race a callback into freed memory. Blocks
        // already dispatched to main retain `stateBox` and no-op via the weak
        // `owner`.
        ghostty_remote_connection_set_state_callback(handle, nil, nil)
        // Last reference gone (window closed): release the connection. This is
        // the single, authoritative free site for the handle.
        ghostty_remote_connection_free(handle)
    }
}
