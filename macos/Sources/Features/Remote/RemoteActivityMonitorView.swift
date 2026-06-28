import SwiftUI
import AppKit
import GhosttyKit

// MARK: - Model

/// One process-table row, marshaled out of `ghostty_proc_s` BEFORE the C list is
/// freed (every field copied; C strings turned into Swift `String`s up front).
struct ProcRow: Identifiable, Hashable {
    /// Process id. Unique within a single snapshot, so it serves as the table id.
    let pid: Int64
    let ppid: Int64
    /// Per-core CPU% (a fully-busy thread is ~100; multithreaded procs may exceed
    /// 100). Normalized to 0..100 for display by dividing by `ncpu`.
    let cpuPctPerCore: Float
    let memBytes: UInt64
    let name: String
    let user: String
    let cmd: String

    var id: Int64 { pid }
}

/// A snapshot of a remote host's load for the monitor header. Driven by the LIVE
/// metrics subscription for CPU%, supplemented by the proc-list snapshot's host
/// field for mem/ncpu/uptime (whose one-shot cpu_pct is unreliable).
struct HostReading: Equatable {
    var cpuPct: Float = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var ncpu: UInt32 = 0
    var uptimeS: UInt64 = 0
    var load1: Float? = nil
}

/// Owns the live data for a single Remote Activity Monitor panel: a host-metrics
/// subscription (header CPU%) plus a periodically-refreshed process table.
///
/// ## Connection ownership
/// The model NEVER frees the connection it observes. Whoever constructs the model
/// decides lifetime: `presentReusing` passes `ownsConnection: false` (the remote
/// window owns it); `presentDialing` passes a freshly-dialed handle with
/// `ownsConnection: true`, and `stop()` frees it after unsubscribing.
///
/// ## Threading
/// - The metrics callback fires on the connection's control-reader thread; the
///   trampoline copies out and hops to main (mirrors `MachineMetricsProbe`).
/// - `proc_list` is a BLOCKING RPC, always issued on a background queue; the
///   result is marshaled to `[ProcRow]` (strings copied) before `_free`, then a
///   hop to main publishes it.
@MainActor
final class RemoteActivityMonitorModel: ObservableObject {
    /// Header host reading (CPU% live; mem/ncpu/uptime from the last snapshot).
    @Published private(set) var host = HostReading()
    /// The most recent process table.
    @Published private(set) var procs: [ProcRow] = []
    /// True while we have never received a proc snapshot (initial spinner).
    @Published private(set) var isLoading = true
    /// True if the last snapshot was clipped by the agent's row cap.
    @Published private(set) var truncated = false
    /// Set when the last refresh failed (connection lost / timeout).
    @Published private(set) var lastRefreshFailed = false

    let machine: Machine

    private let handle: ghostty_remote_connection_t
    private let ownsConnection: Bool

    /// Retained userdata box for the metrics callback; released after unsubscribe.
    private var metricsBox: Unmanaged<MetricsBox>?
    /// Drives periodic proc-list refreshes.
    private var refreshTimer: Timer?
    /// Guards against a refresh landing after `stop()`.
    private var stopped = false
    /// Coalesces overlapping refreshes (one outstanding RPC at a time).
    private var refreshing = false
    /// Set by `stop()` when an owned connection's free had to be deferred because a
    /// background `proc_list` RPC was still in flight (it captured the handle by
    /// value). The refresh-completion hop performs the free instead, so we never
    /// free a handle mid-RPC.
    private var freeAfterRefresh = false

    /// Bridges the C metrics callback to this model. Held by C as retained
    /// userdata; `model` is weak so the box never keeps the model alive.
    fileprivate final class MetricsBox {
        weak var model: RemoteActivityMonitorModel?
        init(model: RemoteActivityMonitorModel) { self.model = model }
    }

    init(machine: Machine, handle: ghostty_remote_connection_t, ownsConnection: Bool) {
        self.machine = machine
        self.handle = handle
        self.ownsConnection = ownsConnection
    }

    /// Subscribe to host metrics and begin periodic proc-list refreshes.
    func start() {
        guard !stopped else { return }

        let box = MetricsBox(model: self)
        let unmanaged = Unmanaged.passRetained(box)
        let ok = ghostty_remote_connection_metrics_subscribe(
            handle,
            1500,
            metricsTrampoline,
            unmanaged.toOpaque()
        )
        if ok {
            metricsBox = unmanaged
        } else {
            // Subscribe failed; don't leak the retained box.
            unmanaged.release()
        }

        // Kick an immediate refresh, then poll every ~2s.
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Timer fires on the main runloop; we're main-actor isolated.
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = timer
    }

    /// Force an immediate process-table refresh (also used by the toolbar button).
    func refresh() {
        guard !stopped, !refreshing else { return }
        refreshing = true

        let handle = self.handle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // BLOCKING RPC — off main by contract. 0 => agent default timeout.
            let list = ghostty_remote_connection_proc_list(handle, 0)

            // Marshal everything out of the C structs BEFORE freeing.
            let ok = list.ok
            let truncated = list.truncated
            let host = HostReading(
                cpuPct: list.host.cpu_pct,
                memUsed: list.host.mem_used,
                memTotal: list.host.mem_total,
                ncpu: list.host.ncpu,
                uptimeS: list.host.uptime_s,
                load1: list.host.load1 < 0 ? nil : list.host.load1
            )

            var rows: [ProcRow] = []
            if ok, list.procs_len > 0 {
                rows.reserveCapacity(list.procs_len)
                for i in 0..<list.procs_len {
                    let p = list.procs[i]
                    rows.append(ProcRow(
                        pid: p.pid,
                        ppid: p.ppid,
                        cpuPctPerCore: p.cpu_pct,
                        memBytes: p.mem_bytes,
                        name: String(cString: p.name),
                        user: String(cString: p.user),
                        cmd: String(cString: p.cmd)
                    ))
                }
            }

            // Free takes BOTH the handle and the list.
            ghostty_remote_connection_proc_list_free(handle, list)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshing = false
                    // If stop() ran while this RPC was in flight and deferred the
                    // free, perform it now that the RPC has fully returned.
                    if self.stopped {
                        if self.freeAfterRefresh {
                            self.freeAfterRefresh = false
                            ghostty_remote_connection_free(self.handle)
                        }
                        return
                    }
                    self.lastRefreshFailed = !ok
                    if ok {
                        self.truncated = truncated
                        self.procs = rows
                        // Use the snapshot host only for mem/ncpu/uptime; keep the
                        // live cpuPct (the snapshot's one-shot value may be 0).
                        var merged = self.host
                        merged.memUsed = host.memUsed
                        merged.memTotal = host.memTotal
                        merged.ncpu = host.ncpu
                        merged.uptimeS = host.uptimeS
                        if host.load1 != nil { merged.load1 = host.load1 }
                        self.host = merged
                        self.isLoading = false
                    }
                }
            }
        }
    }

    /// Apply a live metrics sample (header CPU% + any host fields). Main-actor.
    func ingest(raw: ghostty_host_metrics_s) {
        guard !stopped else { return }
        var h = host
        h.cpuPct = raw.cpu_pct
        // Prefer live host fields too (they're as fresh as the snapshot's).
        h.memUsed = raw.mem_used
        h.memTotal = raw.mem_total
        h.ncpu = raw.ncpu
        if raw.uptime_s != 0 { h.uptimeS = raw.uptime_s }
        h.load1 = raw.load1 < 0 ? nil : raw.load1
        host = h
    }

    /// Tear down: unsubscribe metrics, stop the timer, and (if we own the
    /// connection) free it AFTER unsubscribe so no callback can race the free.
    /// Idempotent.
    func stop() {
        guard !stopped else { return }
        stopped = true

        refreshTimer?.invalidate()
        refreshTimer = nil

        // Unsubscribe FIRST: guarantees no further metrics callback fires.
        ghostty_remote_connection_metrics_unsubscribe(handle)
        metricsBox?.release()
        metricsBox = nil

        if ownsConnection {
            // We dialed this connection; we are its sole owner. Free it now that
            // metrics are silenced — UNLESS a background proc_list RPC is still in
            // flight (it captured the handle by value). In that case defer the free
            // to the RPC's completion hop so we never free a handle mid-RPC.
            if refreshing {
                freeAfterRefresh = true
            } else {
                ghostty_remote_connection_free(handle)
            }
        }
    }
}

/// Global, capture-free C metrics callback. Fires on the control-reader thread;
/// copies out of borrowed stack storage, then hops to main.
private func metricsTrampoline(
    _ m: UnsafePointer<ghostty_host_metrics_s>?,
    _ ud: UnsafeMutableRawPointer?
) {
    guard let m, let ud else { return }
    let hm = m.pointee // copy out of stack storage NOW
    let box = Unmanaged<RemoteActivityMonitorModel.MetricsBox>
        .fromOpaque(ud)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            box.model?.ingest(raw: hm)
        }
    }
}

// MARK: - View

/// A read-only, Activity-Monitor-style panel for a remote host: a live header
/// (CPU%, memory, cores, uptime) over a sortable, searchable process table.
struct RemoteActivityMonitorView: View {
    @ObservedObject var model: RemoteActivityMonitorModel

    @State private var query: String = ""
    @State private var sortOrder: [KeyPathComparator<ProcRow>] = [
        // Default: hottest processes first (normalized CPU% descending).
        .init(\.cpuPctPerCore, order: .reverse)
    ]

    /// Processes filtered by the search query (name or pid substring).
    private var filtered: [ProcRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [ProcRow]
        if q.isEmpty {
            base = model.procs
        } else {
            base = model.procs.filter {
                $0.name.localizedCaseInsensitiveContains(q) ||
                String($0.pid).contains(q)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(model.machine.name)
                        .font(.headline)
                }
                Text(uptimeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statBlock(
                label: "CPU",
                value: String(format: "%.0f%%", normalizedHostCPU),
                detail: "\(model.host.ncpu) cores"
            )
            statBlock(
                label: "Memory",
                value: memString(model.host.memUsed),
                detail: "of \(memString(model.host.memTotal))"
            )
            if let load1 = model.host.load1 {
                statBlock(
                    label: "Load",
                    value: String(format: "%.2f", load1),
                    detail: "1 min"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statBlock(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Table

    private var table: some View {
        // CPU% column shows the NORMALIZED 0..100 value (per-core / ncpu), matching
        // the header and Activity Monitor's "% CPU" semantics. Sorting still keys
        // off the raw per-core value (monotonic with the normalized one).
        Table(of: ProcRow.self, sortOrder: $sortOrder) {
            TableColumn("PID", value: \.pid) { row in
                Text(String(row.pid)).monospacedDigit()
            }
            .width(min: 50, ideal: 60, max: 80)

            TableColumn("Name", value: \.name) { row in
                Text(row.name.isEmpty ? "—" : row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.cmd.isEmpty ? row.name : row.cmd)
            }
            .width(min: 120, ideal: 200)

            TableColumn("% CPU", value: \.cpuPctPerCore) { row in
                Text(String(format: "%.1f", normalized(row.cpuPctPerCore)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70, max: 90)

            TableColumn("Memory", value: \.memBytes) { row in
                Text(memString(row.memBytes))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("User", value: \.user) { row in
                Text(row.user.isEmpty ? "—" : row.user)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        } rows: {
            ForEach(filtered) { row in
                TableRow(row)
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView("Connecting…")
                    .controlSize(.small)
            } else if model.lastRefreshFailed && model.procs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Couldn't connect")
                        .font(.headline)
                    Text("The remote agent is unreachable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer / toolbar

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by name or PID", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            if model.truncated {
                Label("List truncated", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("The agent capped the process table; some rows are not shown.")
            }
            if model.lastRefreshFailed && !model.procs.isEmpty {
                Label("Refresh failed", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Text("\(filtered.count) processes")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Formatting helpers

    /// Host CPU% normalized to 0..100 across all cores. The live subscription's
    /// `cpu_pct` is already 0..100 across all cores per the wire contract, so we
    /// surface it directly.
    private var normalizedHostCPU: Float {
        max(0, min(100, model.host.cpuPct))
    }

    /// Normalize a per-core process CPU% to a Task-Manager-style 0..100 total.
    private func normalized(_ perCore: Float) -> Float {
        let n = model.host.ncpu
        guard n > 0 else { return perCore }
        return perCore / Float(n)
    }

    private var uptimeString: String {
        let s = model.host.uptimeS
        guard s > 0 else { return model.machine.endpoint }
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let mins = (s % 3_600) / 60
        if days > 0 { return "up \(days)d \(hours)h" }
        if hours > 0 { return "up \(hours)h \(mins)m" }
        return "up \(mins)m"
    }

    private func memString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}
