import Foundation
import GhosttyKit

/// Owns short-lived "probe" connections to remote machines for the lifetime of a
/// single Cmd-Shift-N machine-picker presentation, surfacing each machine's live
/// CPU/memory so the picker can show activity in place of the IP:port.
///
/// ## Threading
/// Each probe dials `ghostty_remote_connection_new_tcp` on a background queue
/// (the dial blocks through the handshake). On success it subscribes to the
/// metrics stream. The C metrics callback fires on the connection's
/// CONTROL-READER thread — NOT the main actor — so the trampoline copies the
/// metrics struct out of its borrowed stack storage immediately, then hops to
/// the main queue before touching `@Published` state.
///
/// ## Lifetime / teardown safety
/// `stop()` unsubscribes BEFORE freeing each handle. `metrics_unsubscribe`
/// guarantees no further callback fires once it returns, so freeing the handle
/// afterward can't race a callback (no use-after-free). Each machine's
/// `ProbeBox` is held as a retained `Unmanaged` reference passed to C as
/// userdata; it is `.release()`d only after the corresponding unsubscribe.
@MainActor
final class MachineMetricsProbe: ObservableObject {
    /// A snapshot of a remote host's load, normalized for display.
    struct HostMetrics: Equatable {
        var cpuPct: Float
        var memUsed: UInt64
        var memTotal: UInt64
        var ncpu: UInt32
        /// 1-minute load average, or nil if the remote OS doesn't expose one.
        var load1: Float?
        /// Host uptime in seconds (0 if the remote OS doesn't report it). Surfaced
        /// so the Activity Monitor's machine cards can show "up Nd Nh".
        var uptimeS: UInt64
    }

    /// The per-machine probe state shown in the picker.
    enum Reading: Equatable {
        case connecting
        case failed
        case live(HostMetrics)
    }

    /// Per-machine readings, keyed by `Machine.id`. Drives the picker subline.
    @Published private(set) var readings: [Machine.ID: Reading] = [:]

    /// Live connection handles, one per successfully-dialed machine. Main-actor
    /// only.
    private var handles: [Machine.ID: ghostty_remote_connection_t] = [:]

    /// Retained `Unmanaged` boxes passed to C as callback userdata. Released in
    /// `stop()` after the matching unsubscribe. Main-actor only.
    private var boxes: [Machine.ID: Unmanaged<ProbeBox>] = [:]

    /// Guards against a double `stop()` (idempotency).
    private var stopped = false

    /// Bridges a C metrics callback back to a specific machine's probe. Held by
    /// C as userdata via a retained `Unmanaged` reference. The `probe` ref is
    /// weak so the box never keeps the probe alive past its picker.
    fileprivate final class ProbeBox {
        let id: Machine.ID
        weak var probe: MachineMetricsProbe?
        init(id: Machine.ID, probe: MachineMetricsProbe) {
            self.id = id
            self.probe = probe
        }
    }

    /// Begin probing the given machines. For each: mark `.connecting`, dial on a
    /// background queue, and on success subscribe to the metrics stream.
    func start(_ machines: [Machine]) {
        for machine in machines {
            readings[machine.id] = .connecting

            let host = machine.host
            let port = machine.port
            let id = machine.id

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Dial blocks through the handshake; nil on failure.
                let handle = host.withCString {
                    ghostty_remote_connection_new_tcp($0, port)
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else {
                            // Probe is gone; don't leak the connection we dialed.
                            if let handle {
                                ghostty_remote_connection_free(handle)
                            }
                            return
                        }
                        self.onDialed(id: id, handle: handle)
                    }
                }
            }
        }
    }

    /// Main-actor continuation of a dial: subscribe on success, else `.failed`.
    private func onDialed(id: Machine.ID, handle: ghostty_remote_connection_t?) {
        // If we were already torn down, just drop the connection.
        guard !stopped else {
            if let handle { ghostty_remote_connection_free(handle) }
            return
        }

        guard let handle else {
            readings[id] = .failed
            return
        }

        let box = ProbeBox(id: id, probe: self)
        let unmanaged = Unmanaged.passRetained(box)
        let ok = ghostty_remote_connection_metrics_subscribe(
            handle,
            1000,
            metricsTrampoline,
            unmanaged.toOpaque()
        )

        guard ok else {
            // Subscribe failed (connection not established): clean up.
            unmanaged.release()
            ghostty_remote_connection_free(handle)
            readings[id] = .failed
            return
        }

        handles[id] = handle
        boxes[id] = unmanaged
    }

    /// Apply a metrics sample to a machine's reading. Called on the main actor
    /// (hopped from the reader-thread trampoline).
    func ingest(id: Machine.ID, raw: ghostty_host_metrics_s) {
        guard !stopped else { return }
        let metrics = HostMetrics(
            cpuPct: raw.cpu_pct,
            memUsed: raw.mem_used,
            memTotal: raw.mem_total,
            ncpu: raw.ncpu,
            load1: raw.load1 < 0 ? nil : raw.load1,
            uptimeS: raw.uptime_s
        )
        readings[id] = .live(metrics)
    }

    /// Tear down every probe connection. Unsubscribes before freeing so no
    /// callback can fire after the handle is gone. Idempotent.
    func stop() {
        guard !stopped else { return }
        stopped = true

        for (id, handle) in handles {
            // Unsubscribe FIRST: guarantees no further callback fires.
            ghostty_remote_connection_metrics_unsubscribe(handle)
            ghostty_remote_connection_free(handle)
            // Now safe to release the box the (now-silent) callback referenced.
            boxes[id]?.release()
        }

        handles.removeAll()
        boxes.removeAll()
        readings.removeAll()
    }
}

/// Global, capture-free C callback. Fires on the connection's control-reader
/// thread. Copies the metrics out of borrowed stack storage, then hops to the
/// main actor to update the owning probe.
private func metricsTrampoline(
    _ m: UnsafePointer<ghostty_host_metrics_s>?,
    _ ud: UnsafeMutableRawPointer?
) {
    guard let m, let ud else { return }
    let hm = m.pointee // copy out of stack storage NOW
    let box = Unmanaged<MachineMetricsProbe.ProbeBox>
        .fromOpaque(ud)
        .takeUnretainedValue()
    let id = box.id
    DispatchQueue.main.async {
        // We're on the main queue, so it's safe to enter the main actor.
        MainActor.assumeIsolated {
            box.probe?.ingest(id: id, raw: hm)
        }
    }
}
