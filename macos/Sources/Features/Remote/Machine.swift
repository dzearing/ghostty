import Foundation
import GhosttyKit

/// A remote machine that can host terminal sessions over the Ghoztty remote
/// transport (TCP only for now). See remote-machines design WP4.
struct Machine: Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16

    init(id: UUID = UUID(), name: String, host: String, port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }

    /// A human-friendly "host:port" string for display.
    var endpoint: String { "\(host):\(port)" }
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
        self.machines = [
            Machine(name: "maximushome", host: "100.110.48.108", port: 7777),
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
