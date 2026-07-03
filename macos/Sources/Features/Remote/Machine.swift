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

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        relayBase: String? = nil,
        deviceID: String? = nil,
        online: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.relayBase = relayBase
        self.deviceID = deviceID
        self.online = online
    }

    /// True when this machine is reached through a rendezvous relay.
    var isRelay: Bool { relayBase != nil && deviceID != nil }

    /// A human-friendly string for display: the device id for relay machines,
    /// otherwise "host:port".
    var endpoint: String { isRelay ? (deviceID ?? host) : "\(host):\(port)" }

    /// True when this machine's display name (the agent-reported hostname when
    /// the agent delivered one in its HELLO) refers to THIS Mac. Used to
    /// suppress remote-only UI (e.g. the titlebar hostname pill) for a "remote"
    /// window whose agent actually runs on the local machine.
    var isLocalMachine: Bool { Self.isLocalHostname(name) }

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
/// chooser opens. A seeded fallback entry keeps the feature usable before the
/// first successful fetch (and with no token configured); a successful fetch
/// replaces every relay entry with the authoritative account list. Non-relay
/// (direct TCP) entries are never touched by the fetch.
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

    /// Seeded entries that exist before (and independent of) any relay fetch.
    private let seeded: [Machine]

    /// Stable UUID per relay device id so SwiftUI identity (selection, rows)
    /// survives refreshes that rebuild the `Machine` values.
    private var deviceUUIDs: [String: UUID] = [:]

    /// True when a relay token source is available (signed-in Google account
    /// or dev token), i.e. the account device list is reachable. The chooser
    /// opens even with zero machines when this is set (the list populates on
    /// fetch).
    var hasRelayAccount: Bool { RelayAccount.hasCredentials }

    init() {
        // maximushome is reached through the rendezvous relay (WP-A1). The
        // `host` carries the relay base for display/filtering; the actual dial
        // uses `relayBase`/`deviceID`. The token is read from the environment
        // (GHOSTTY_RELAY_TOKEN) at connect time, never hardcoded here. This
        // seed is only the pre-fetch fallback: a successful directory fetch
        // (WP-C2) replaces all relay entries with the live account list.
        let relayBase = RelayDirectoryClient.defaultBase
        self.seeded = [
            Machine(
                name: "maximushome",
                host: relayBase,
                port: 0,
                relayBase: relayBase,
                deviceID: "14e75262-0fe2-4126-91db-efceb2f15665"
            ),
        ]
        self.machines = seeded
        // Keep row identity stable when the fetch replaces a seeded entry
        // with the same device from the account list.
        for m in seeded {
            if let d = m.deviceID { deviceUUIDs[d] = m.id }
        }
    }

    func add(_ machine: Machine) {
        machines.append(machine)
    }

    /// Refresh the relay account's device list (WP-C2). On success, relay
    /// machines are replaced by the fetched list (with online status); TCP
    /// machines are untouched. On failure the current list is kept and
    /// `lastRefreshError` is set. No-op when no token source is configured.
    func refreshFromRelay() async {
        guard RelayAccount.hasCredentials else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }
        // Token via the WP-B2 seam (account ID token, dev-token fallback);
        // may await a token refresh before the directory call.
        guard let client = await RelayDirectoryClient.current() else {
            lastRefreshError =
                RelayDirectoryClient.DirectoryError.noAccount.localizedDescription
            return
        }
        do {
            apply(devices: try await client.listDevices())
        } catch {
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

    /// Rename a device on the relay account and update the registry row with
    /// the relay's response. Throws `DirectoryError` on failure.
    func renameOnAccount(deviceID: String, to name: String) async throws {
        guard let client = await RelayDirectoryClient.current() else {
            throw RelayDirectoryClient.DirectoryError.noAccount
        }
        let dev = try await client.rename(deviceID: deviceID, to: name)
        if let idx = machines.firstIndex(where: { $0.deviceID == deviceID }) {
            machines[idx].name = dev.name
            machines[idx].online = dev.online
        }
    }

    /// Rebuild `machines` from a fetched device list: authoritative relay
    /// entries (stable UUIDs per device id) after any seeded TCP entries.
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
                online: dev.online
            )
        }
        machines = seeded.filter { !$0.isRelay } + relayMachines
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
    let machine: Machine

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
