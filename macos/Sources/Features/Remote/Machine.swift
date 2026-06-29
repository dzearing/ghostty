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

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        relayBase: String? = nil,
        deviceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.relayBase = relayBase
        self.deviceID = deviceID
    }

    /// True when this machine is reached through a rendezvous relay.
    var isRelay: Bool { relayBase != nil && deviceID != nil }

    /// A human-friendly string for display: the device id for relay machines,
    /// otherwise "host:port".
    var endpoint: String { isRelay ? (deviceID ?? host) : "\(host):\(port)" }
}

/// In-memory registry of known remote machines.
///
/// Seeded with a single hardcoded entry so the remote-window feature is
/// immediately usable. Config-file loading is a later phase.
///
/// TODO(wp4): load from ~/.config/ghostty (e.g. a `[machines]` section or a
/// dedicated machines.toml) instead of (or in addition to) the seeded list.
@MainActor
final class MachineRegistry: ObservableObject {
    static let shared = MachineRegistry()

    @Published private(set) var machines: [Machine]

    init() {
        // maximushome is reached through the rendezvous relay (WP-A1). The
        // `host` carries the relay base for display/filtering; the actual dial
        // uses `relayBase`/`deviceID`. The token is read from the environment
        // (GHOSTTY_RELAY_TOKEN) at connect time, never hardcoded here.
        let maximusRelayBase = "https://ghoztty-relay-dz17575.westus2.cloudapp.azure.com"
        self.machines = [
            Machine(
                name: "maximushome",
                host: maximusRelayBase,
                port: 0,
                relayBase: maximusRelayBase,
                deviceID: "14e75262-0fe2-4126-91db-efceb2f15665"
            ),
        ]
    }

    func add(_ machine: Machine) {
        machines.append(machine)
    }
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

    init(handle: ghostty_remote_connection_t, machine: Machine) {
        self.handle = handle
        self.machine = machine
    }

    /// Current round-trip latency to the agent in milliseconds, or nil if
    /// unavailable.
    var latencyMs: Int32? {
        let v = ghostty_remote_connection_latency_ms(handle)
        return v >= 0 ? v : nil
    }

    deinit {
        // Last reference gone (window closed): release the connection. This is
        // the single, authoritative free site for the handle.
        ghostty_remote_connection_free(handle)
    }
}
