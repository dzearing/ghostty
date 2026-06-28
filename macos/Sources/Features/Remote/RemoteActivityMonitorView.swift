import SwiftUI
import AppKit
import GhosttyKit
#if canImport(Charts)
import Charts
#endif

// MARK: - Source

/// The data source backing an Activity Monitor panel. Identity drives the
/// in-panel machine switcher.
///
/// - `.local`: in-process provider (`ghostty_local_*`). No connection handle.
/// - `.remote(Machine)`: an agent over a `ghostty_remote_connection_t`. The
///   handle and whether the model OWNS it are tracked separately (see
///   `RemoteActivityMonitorModel.SourceState`), because the panel may be opened
///   reusing a remote window's connection (non-owned) or switch to a freshly
///   dialed one (owned).
enum MonitorSource: Hashable {
    case local
    case remote(Machine)

    /// Display label for the switcher.
    var label: String {
        switch self {
        case .local: return "Local"
        case .remote(let m): return m.name
        }
    }
}

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

/// A snapshot of a host's load for the monitor header. For remote sources CPU% is
/// driven by the LIVE metrics subscription; for local it comes from the local
/// proc-list's host field (the local sampler persists, so it carries real CPU).
/// Mem/ncpu/uptime come from the latest proc-list `host` for both.
struct HostReading: Equatable {
    var cpuPct: Float = 0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var ncpu: UInt32 = 0
    var uptimeS: UInt64 = 0
    var load1: Float? = nil
}

/// One point in the header's rolling CPU/Memory trend charts. `seq` is a
/// monotonically increasing sample index used as the chart X value (we only show
/// the trend shape, so the X unit is arbitrary).
struct HostSample: Identifiable, Equatable {
    let seq: Int
    /// CPU%, normalized 0..100 across all cores.
    let cpuPct: Double
    /// Memory used, as a fraction 0..1 of total (so the chart Y is 0..100%).
    let memFraction: Double
    /// Absolute memory used in bytes (for the hover annotation's "X GB").
    let memUsed: UInt64
    /// Wall-clock time the sample was taken (for the hover "Xs ago"). `Date` is
    /// fine on the Swift side; only the Zig agent forbids wall-clock time.
    let at: Date
    var id: Int { seq }
}

/// Owns the live data for a single Activity Monitor panel, parameterized over a
/// `MonitorSource`. Drives a periodically-refreshed process table and (for remote
/// sources) a host-metrics subscription for header CPU%. Supports switching the
/// source in place (`switchTo`) without opening a new window.
///
/// ## Connection ownership (remote sources)
/// A remote source carries a `ghostty_remote_connection_t` and an `owned` flag:
/// - Opened reusing a remote window's connection → `owned == false`; the model
///   never frees it (the window's `RemoteConnection` is the sole owner).
/// - Switched to a different remote machine via the switcher → a FRESH handle is
///   dialed off-main → `owned == true`; freed (unsubscribe-first) on the next
///   switch or window close.
/// `.local` carries no handle and uses the `ghostty_local_*` API.
///
/// ## Threading
/// - The metrics callback fires on the connection's control-reader thread; the
///   trampoline copies out and hops to main (mirrors `MachineMetricsProbe`).
/// - `proc_list`/`kill`/`spawn` are BLOCKING and always issued on a background
///   queue; results are marshaled (strings copied) before the matching `_free`,
///   then a hop to main publishes.
@MainActor
final class RemoteActivityMonitorModel: ObservableObject {
    /// Header host reading (CPU% live for remote / local-sampled; mem/ncpu/uptime
    /// from the last snapshot).
    @Published private(set) var host = HostReading()
    /// Rolling time-series for the header trend charts (oldest → newest), capped at
    /// `maxSamples`. Appended once per host update (each metrics tick for remote,
    /// each refresh for local) and CLEARED on every source switch so one machine's
    /// history never bleeds into another's.
    @Published private(set) var samples: [HostSample] = []

    /// Max points retained in the trend ring buffers (~60 samples ≈ 90s at 1.5s).
    private let maxSamples = 60
    /// Monotonic sample index used as the chart X value.
    private var sampleSeq = 0
    /// The most recent process table.
    @Published private(set) var procs: [ProcRow] = []
    /// True while we have never received a proc snapshot for the current source.
    @Published private(set) var isLoading = true
    /// True if the last snapshot was clipped by the agent's row cap.
    @Published private(set) var truncated = false
    /// Set when the last refresh failed (connection lost / timeout / dial failed).
    @Published private(set) var lastRefreshFailed = false
    /// The current data source (drives the switcher binding + the header).
    @Published private(set) var source: MonitorSource
    /// True while a source switch is dialing a fresh remote connection.
    @Published private(set) var switching = false
    /// A transient user-facing error (kill/spawn failure), shown as a banner.
    @Published var actionError: String?
    /// The machine list for the switcher, mirrored from the registry.
    @Published private(set) var machines: [Machine] = MachineRegistry.shared.machines

    /// The connection state of the active source. `nil` for `.local`.
    private struct RemoteState {
        let handle: ghostty_remote_connection_t
        let owned: Bool
    }
    private var remote: RemoteState?

    /// Retained userdata box for the metrics callback; released after unsubscribe.
    private var metricsBox: Unmanaged<MetricsBox>?
    /// Drives periodic proc-list refreshes.
    private var refreshTimer: Timer?
    /// Guards against work landing after `stop()`.
    private var stopped = false
    /// Coalesces overlapping refreshes (one outstanding RPC at a time).
    private var refreshing = false
    /// When tearing down an OWNED remote handle while a background `proc_list` RPC
    /// is still in flight (it captured the handle by value), the free is deferred
    /// to the RPC-completion hop so we never free a handle mid-RPC. Holds the
    /// handle to free once the in-flight RPC returns.
    private var freeAfterRefresh: ghostty_remote_connection_t?

    /// Bridges the C metrics callback to this model. Held by C as retained
    /// userdata; `model` is weak so the box never keeps the model alive.
    fileprivate final class MetricsBox {
        weak var model: RemoteActivityMonitorModel?
        init(model: RemoteActivityMonitorModel) { self.model = model }
    }

    /// - Parameters:
    ///   - source: the initial source.
    ///   - handle: a connection handle for a `.remote` source, else nil.
    ///   - ownsConnection: whether the model owns (and must free) `handle`.
    init(source: MonitorSource, handle: ghostty_remote_connection_t?, ownsConnection: Bool) {
        self.source = source
        if case .remote = source, let handle {
            self.remote = RemoteState(handle: handle, owned: ownsConnection)
        }
    }

    // MARK: Lifecycle

    /// Begin observing the initial source (subscribe metrics for remote, start the
    /// poll timer for all). Call once after construction.
    func start() {
        guard !stopped else { return }
        beginCurrentSource()
    }

    /// Tear down everything for good: stop the active source and forbid restart.
    /// Idempotent.
    func stop() {
        guard !stopped else { return }
        stopped = true
        teardownCurrentSource()
    }

    /// Switch the panel to a different source. Tears down the current source
    /// (unsubscribe, invalidate timer, free owned handle race-safely), then starts
    /// the new one. For a remote target it dials a FRESH owned connection off-main.
    func switchTo(_ newSource: MonitorSource) {
        guard !stopped, newSource != source else { return }

        teardownCurrentSource()

        // Reset published state for the new source. Clearing the trend buffers
        // here guarantees one machine's history never bleeds into another's.
        source = newSource
        procs = []
        host = HostReading()
        samples = []
        sampleSeq = 0
        truncated = false
        lastRefreshFailed = false
        isLoading = true
        actionError = nil

        switch newSource {
        case .local:
            remote = nil
            switching = false
            beginCurrentSource()
        case .remote(let machine):
            // Dial a fresh, owned connection off-main, then begin.
            remote = nil
            switching = true
            let host = machine.host
            let port = machine.port
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let handle = host.withCString {
                    ghostty_remote_connection_new_tcp($0, port)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else {
                            if let handle { ghostty_remote_connection_free(handle) }
                            return
                        }
                        // If we were stopped or switched again mid-dial, drop it.
                        guard !self.stopped, self.source == newSource else {
                            if let handle { ghostty_remote_connection_free(handle) }
                            return
                        }
                        self.switching = false
                        guard let handle else {
                            self.lastRefreshFailed = true
                            self.isLoading = false
                            return
                        }
                        self.remote = RemoteState(handle: handle, owned: true)
                        self.beginCurrentSource()
                    }
                }
            }
        }
    }

    /// Start observing whatever `source`/`remote` is currently set: subscribe
    /// metrics (remote only), kick a refresh, and arm the poll timer.
    private func beginCurrentSource() {
        if case .remote = source, let r = remote {
            let box = MetricsBox(model: self)
            let unmanaged = Unmanaged.passRetained(box)
            let ok = ghostty_remote_connection_metrics_subscribe(
                r.handle, 1500, metricsTrampoline, unmanaged.toOpaque()
            )
            if ok { metricsBox = unmanaged } else { unmanaged.release() }
        }

        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = timer
    }

    /// Tear down the active source: stop the timer, unsubscribe metrics, and free
    /// the handle iff owned (race-safe against an in-flight `proc_list`). Leaves
    /// `stopped` untouched so this is reusable by `switchTo`.
    private func teardownCurrentSource() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if let r = remote {
            // Unsubscribe FIRST: guarantees no further metrics callback fires.
            ghostty_remote_connection_metrics_unsubscribe(r.handle)
            metricsBox?.release()
            metricsBox = nil

            if r.owned {
                if refreshing {
                    // A background proc_list captured this handle by value; defer
                    // the free to the RPC-completion hop.
                    freeAfterRefresh = r.handle
                } else {
                    ghostty_remote_connection_free(r.handle)
                }
            }
        } else {
            metricsBox?.release()
            metricsBox = nil
        }
        remote = nil
        switching = false
    }

    // MARK: Refresh

    /// Force an immediate process-table refresh against the current source.
    func refresh() {
        guard !stopped, !refreshing, !switching else { return }
        // Remote source not yet connected (mid-dial / dial failed): nothing to do.
        if case .remote = source, remote == nil { return }
        refreshing = true

        let isLocal = remote == nil
        let handle = remote?.handle

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // BLOCKING — off main by contract. 0 => default timeout.
            let list: ghostty_proc_list_s = isLocal
                ? ghostty_local_proc_list(0)
                : ghostty_remote_connection_proc_list(handle!, 0)

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

            // Free with the MATCHING free (local frees via app allocator, no
            // handle; remote frees take the handle). Never cross them.
            if isLocal {
                ghostty_local_proc_list_free(list)
            } else {
                ghostty_remote_connection_proc_list_free(handle!, list)
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshing = false
                    // A teardown deferred an owned-handle free until this RPC
                    // returned — perform it now.
                    if let toFree = self.freeAfterRefresh {
                        self.freeAfterRefresh = nil
                        ghostty_remote_connection_free(toFree)
                    }
                    if self.stopped { return }
                    self.lastRefreshFailed = !ok
                    if ok {
                        self.truncated = truncated
                        self.procs = rows
                        var merged = self.host
                        merged.memUsed = host.memUsed
                        merged.memTotal = host.memTotal
                        merged.ncpu = host.ncpu
                        merged.uptimeS = host.uptimeS
                        if host.load1 != nil { merged.load1 = host.load1 }
                        // Local: the local sampler persists, so the snapshot's
                        // cpu_pct is real — use it. Remote: keep the live
                        // subscription's cpuPct (snapshot cpu is one-shot zero).
                        if isLocal { merged.cpuPct = host.cpuPct }
                        self.host = merged
                        // Local has no metrics subscription, so drive the trend
                        // charts off each refresh's host snapshot. (Remote drives
                        // them from the live metrics tick in `ingest`.)
                        if isLocal { self.appendSample(from: merged) }
                        self.isLoading = false
                    } else {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    /// Apply a live metrics sample (header CPU% + host fields). Main-actor.
    /// Ignored for local sources (they have no subscription).
    func ingest(raw: ghostty_host_metrics_s) {
        guard !stopped, remote != nil else { return }
        var h = host
        h.cpuPct = raw.cpu_pct
        h.memUsed = raw.mem_used
        h.memTotal = raw.mem_total
        h.ncpu = raw.ncpu
        if raw.uptime_s != 0 { h.uptimeS = raw.uptime_s }
        h.load1 = raw.load1 < 0 ? nil : raw.load1
        host = h
        // Remote: drive the trend charts off the live metrics tick.
        appendSample(from: h)
    }

    /// Append one point to the rolling trend buffers, dropping the oldest beyond
    /// `maxSamples`. Main-actor.
    private func appendSample(from h: HostReading) {
        let cpu = Double(max(0, min(100, h.cpuPct)))
        let memFrac = h.memTotal > 0 ? Double(h.memUsed) / Double(h.memTotal) : 0
        sampleSeq += 1
        samples.append(HostSample(
            seq: sampleSeq,
            cpuPct: cpu,
            memFraction: max(0, min(1, memFrac)),
            memUsed: h.memUsed,
            at: Date()
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    // MARK: Process control (Kill / Spawn)

    /// Kill `row` on the current source (signal "TERM"), then force a refresh so it
    /// disappears. Surfaces failures via `actionError`.
    func kill(_ row: ProcRow) {
        guard !stopped else { return }
        let isLocal = remote == nil
        let handle = remote?.handle
        let pid = row.pid
        let name = row.name

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok: Bool = "TERM".withCString { sig in
                if isLocal {
                    return ghostty_local_proc_kill(pid, sig)
                } else {
                    return ghostty_remote_connection_proc_kill(handle!, pid, sig, 0)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    if ok {
                        self.refresh()
                    } else {
                        self.actionError = "Couldn't kill \(name.isEmpty ? "process" : name) (PID \(pid)). It may require elevated privileges."
                    }
                }
            }
        }
    }

    /// Spawn `cmd` (in `cwd`, empty ⇒ default) on the current source. On success
    /// forces a refresh; on failure sets `actionError`. Calls `completion` on the
    /// main actor with the new pid (or nil on failure).
    func spawn(cmd: String, cwd: String, completion: @escaping (Int64?) -> Void) {
        guard !stopped else { completion(nil); return }
        let isLocal = remote == nil
        let handle = remote?.handle

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pid: Int64 = cmd.withCString { c in
                cwd.withCString { w in
                    if isLocal {
                        return ghostty_local_proc_spawn(c, w)
                    } else {
                        return ghostty_remote_connection_proc_spawn(handle!, c, w, 0)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { completion(nil); return }
                    if pid > 0 {
                        self.refresh()
                        completion(pid)
                    } else {
                        self.actionError = "Couldn't start “\(cmd)”."
                        completion(nil)
                    }
                }
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

/// A native Activity-Monitor-style panel: a header with a machine switcher + live
/// gauges, a filter field, a selectable/sortable process table, a Kill action for
/// the selected row, and a New Process button.
struct RemoteActivityMonitorView: View {
    @ObservedObject var model: RemoteActivityMonitorModel

    @State private var query: String = ""
    @State private var selectedPID: Int64?
    @State private var sortOrder: [KeyPathComparator<ProcRow>] = [
        .init(\.cpuPctPerCore, order: .reverse)
    ]
    @State private var confirmingKill: ProcRow?
    @State private var showingSpawn = false

    /// Processes filtered by the search query (name or pid substring), sorted.
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

    /// The currently selected row resolved from the selected pid.
    private var selectedRow: ProcRow? {
        guard let pid = selectedPID else { return nil }
        return model.procs.first { $0.pid == pid }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controlBar
            Divider()
            table
            if model.actionError != nil { errorBanner }
        }
        .frame(minWidth: 620, minHeight: 380)
        .confirmationDialog(
            confirmingKill.map { "Kill \($0.name.isEmpty ? "process" : $0.name) (PID \($0.pid))?" } ?? "Kill process?",
            isPresented: Binding(
                get: { confirmingKill != nil },
                set: { if !$0 { confirmingKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let row = confirmingKill {
                Button("Kill", role: .destructive) {
                    model.kill(row)
                    confirmingKill = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmingKill = nil }
        } message: {
            Text("This sends a termination signal to the process.")
        }
        .sheet(isPresented: $showingSpawn) {
            NewProcessSheet(sourceLabel: model.source.label) { cmd, cwd in
                model.spawn(cmd: cmd, cwd: cwd) { _ in }
            }
        }
    }

    // MARK: Header (switcher + gauges)

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                machineSwitcher
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TrendGaugeView(
                title: "CPU",
                value: String(format: "%.0f%%", normalizedHostCPU),
                detail: "\(model.host.ncpu) cores",
                tint: .blue,
                metric: .cpu,
                samples: model.samples,
                memTotal: model.host.memTotal
            )
            TrendGaugeView(
                title: "Memory",
                value: memString(model.host.memUsed),
                detail: "of \(memString(model.host.memTotal))",
                tint: .green,
                metric: .memory,
                samples: model.samples,
                memTotal: model.host.memTotal
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The machine switcher: a menu-style Picker listing Local + every registered
    /// machine. Changing it switches the source in place.
    private var machineSwitcher: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Picker("Machine", selection: Binding(
                get: { model.source },
                set: { model.switchTo($0) }
            )) {
                Text("Local").tag(MonitorSource.local)
                ForEach(model.machines) { machine in
                    Text(machine.name).tag(MonitorSource.remote(machine))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if model.switching {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusColor: Color {
        if model.switching { return .yellow }
        if model.lastRefreshFailed && model.procs.isEmpty { return .red }
        return .green
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

    // MARK: Control bar (filter at TOP + actions)

    private var controlBar: some View {
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

            // Kill appears only when a row is selected (the user asked for it "on
            // the right side when selected").
            if let row = selectedRow {
                Button(role: .destructive) {
                    confirmingKill = row
                } label: {
                    Label("Kill", systemImage: "xmark.octagon")
                }
                .help("Terminate \(row.name.isEmpty ? "PID \(row.pid)" : row.name)")
            }

            Button {
                showingSpawn = true
            } label: {
                Label("New Process", systemImage: "plus")
            }
            .help("Start a new process on \(model.source.label)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Table (selectable)

    private var table: some View {
        Table(of: ProcRow.self, selection: $selectedPID, sortOrder: $sortOrder) {
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

            // Full executable path (from ghostty_proc_s.cmd). May be empty until
            // the agent populates it; long paths truncate at the head with the
            // full path on hover.
            TableColumn("Path", value: \.cmd) { row in
                Text(row.cmd.isEmpty ? "—" : row.cmd)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(row.cmd.isEmpty ? "" : row.cmd)
            }
            .width(min: 120, ideal: 240)
        } rows: {
            ForEach(filtered) { row in
                TableRow(row)
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView(model.switching ? "Connecting…" : "Loading…")
                    .controlSize(.small)
            } else if model.lastRefreshFailed && model.procs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Couldn't connect")
                        .font(.headline)
                    Text("The \(model.source.label) source is unreachable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Error banner

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(model.actionError ?? "")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                model.actionError = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    // MARK: Formatting helpers

    /// Host CPU% normalized to 0..100 across all cores.
    private var normalizedHostCPU: Float {
        max(0, min(100, model.host.cpuPct))
    }

    /// Normalize a per-core process CPU% to a 0..100 total.
    private func normalized(_ perCore: Float) -> Float {
        let n = model.host.ncpu
        guard n > 0 else { return perCore }
        return perCore / Float(n)
    }

    /// The header subline: uptime if known, else the source endpoint.
    private var subline: String {
        let s = model.host.uptimeS
        if s > 0 {
            let days = s / 86_400
            let hours = (s % 86_400) / 3_600
            let mins = (s % 3_600) / 60
            if days > 0 { return "up \(days)d \(hours)h" }
            if hours > 0 { return "up \(hours)h \(mins)m" }
            return "up \(mins)m"
        }
        switch model.source {
        case .local: return "This Mac"
        case .remote(let m): return m.endpoint
        }
    }

    private func memString(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - New Process sheet

/// A small sheet to spawn a process: a command field plus an optional working
/// directory. Submit runs the supplied closure (which calls the model's spawn).
private struct NewProcessSheet: View {
    let sourceLabel: String
    let onSubmit: (_ cmd: String, _ cwd: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cmd: String = ""
    @State private var cwd: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Process on \(sourceLabel)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. open -a Safari", text: $cmd)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Working Directory (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Default", text: $cwd)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !c.isEmpty else { return }
                    onSubmit(c, cwd.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Trend gauge

/// Which header metric a trend gauge plots.
enum TrendMetric { case cpu, memory }

/// A prominent header gauge: a title + current value over a live area/line
/// sparkline of the metric's recent history, with faint 0/50/100 Y reference
/// gridlines (so a spike's height reads against full scale) and a hover lollipop
/// (`RuleMark` + annotation) showing the value at the pointer and how long ago.
///
/// Y is fixed 0..100 for both metrics (CPU% directly; memory as
/// `memFraction*100`, i.e. % of total RAM). Falls back to a plain text block on
/// systems without Swift Charts.
struct TrendGaugeView: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let metric: TrendMetric
    let samples: [HostSample]
    /// Total RAM in bytes, used to label the 100% reference for memory.
    let memTotal: UInt64

    /// Chart dimensions — notably larger than the original 140×34 sparkline.
    private static let chartWidth: CGFloat = 240
    private static let chartHeight: CGFloat = 64

    /// The seq of the sample under the pointer, or nil when not hovering.
    @State private var hoverSeq: Int?

    /// The y-value (0..100) plotted for a sample under this gauge's metric.
    private func y(_ s: HostSample) -> Double {
        metric == .cpu ? s.cpuPct : s.memFraction * 100
    }

    private var hoveredSample: HostSample? {
        guard let hoverSeq else { return nil }
        return samples.first { $0.seq == hoverSeq }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            chart
                .frame(width: Self.chartWidth, height: Self.chartHeight)
        }
    }

    @ViewBuilder
    private var chart: some View {
        #if canImport(Charts)
        if #available(macOS 13.0, *) {
            chartBody
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    #if canImport(Charts)
    @available(macOS 13.0, *)
    private var chartBody: some View {
        let hovered = hoveredSample
        return Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("t", s.seq), y: .value("v", y(s)))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [tint.opacity(0.35), tint.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                LineMark(x: .value("t", s.seq), y: .value("v", y(s)))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            // Hover lollipop: a vertical rule + dot at the hovered sample.
            if let hovered {
                RuleMark(x: .value("t", hovered.seq))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", hovered.seq), y: .value("v", y(hovered)))
                    .foregroundStyle(tint)
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        // Faint reference gridlines + labels at 0 / 50 / 100 so the scale and the
        // headroom up to 100% are readable.
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let iv = v.as(Int.self) {
                        Text(yLabel(iv))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
        )
        // Map pointer X → nearest HostSample by `seq` (the chart's X value).
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            // `plotAreaFrame` is the macOS-13 spelling (plotFrame
                            // is 14+). Resolve the anchor in our geometry.
                            let xInPlot = pt.x - geo[proxy.plotAreaFrame].origin.x
                            guard let rawSeq: Double = proxy.value(atX: xInPlot) else {
                                hoverSeq = nil; return
                            }
                            hoverSeq = nearestSeq(to: rawSeq)
                        case .ended:
                            hoverSeq = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let hovered { tooltip(for: hovered) }
        }
    }
    #endif

    /// The nearest sample's seq to a (possibly fractional) X value from the chart.
    private func nearestSeq(to rawSeq: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        return samples.min(by: {
            abs(Double($0.seq) - rawSeq) < abs(Double($1.seq) - rawSeq)
        })?.seq
    }

    /// The trailing Y-axis label for a reference value. For memory, 100% is total
    /// RAM, so we annotate it with the GB figure to make "% of total" clear.
    private func yLabel(_ iv: Int) -> String {
        if metric == .memory, iv == 100, memTotal > 0 {
            return "100% · \(Self.gb(memTotal))"
        }
        return "\(iv)%"
    }

    /// A small hover annotation showing the value at the pointer + how long ago.
    private func tooltip(for s: HostSample) -> some View {
        let ago = max(0, Int(Date().timeIntervalSince(s.at).rounded()))
        let valueText: String
        switch metric {
        case .cpu:
            valueText = "CPU \(Int(s.cpuPct.rounded()))%"
        case .memory:
            valueText = "Mem \(Self.gb(s.memUsed)) (\(Int((s.memFraction * 100).rounded()))%)"
        }
        return VStack(alignment: .leading, spacing: 1) {
            Text(valueText)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
            Text(ago <= 0 ? "now" : "\(ago)s ago")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
                .shadow(radius: 1)
        )
        .padding(4)
        .allowsHitTesting(false)
    }

    private static func gb(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    /// A static placeholder used when Swift Charts isn't available.
    private var fallback: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(0.12))
            .overlay(
                Rectangle()
                    .fill(tint.opacity(0.4))
                    .frame(height: 1),
                alignment: .bottom
            )
    }
}
