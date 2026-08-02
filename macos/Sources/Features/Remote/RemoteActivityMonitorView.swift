import SwiftUI
import AppKit
import Combine
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
    /// Per-core CPU%, displayed AS-IS: a fully-busy thread reads ~100 and a
    /// multithreaded process legitimately exceeds it (400 for four busy threads),
    /// exactly like top(1) and macOS Activity Monitor's "% CPU" column.
    ///
    /// This is deliberately NOT divided by `ncpu`. Doing so answers a different
    /// question — "what share of the whole machine is this?" — which the header's
    /// host gauge already reports, and on an 18-core box it renders a fully-pinned
    /// core as `5.6` and anything ordinary as `0.0`.
    let cpuPctPerCore: Float
    let memBytes: UInt64
    let name: String
    let user: String
    let cmd: String
    /// Controlling terminal, bare ("ttys004"), or "" when the process has none.
    /// Keys pane attribution — see `PaneAttribution`.
    let tty: String
    /// The Ghoztty pane this process is running in, or nil if it isn't one of
    /// ours. Filled in after the snapshot is marshaled, since attribution needs
    /// the whole table (it walks the ppid chain) plus the live pane list.
    var pane: AttributedPane?

    var id: Int64 { pid }

    /// Sort key for the "Window / Pane" column. Unattributed rows sort last
    /// rather than clumping at the top under an empty string, so ascending order
    /// puts the interesting rows first.
    var paneSortKey: String { pane?.label ?? "\u{10FFFF}" }
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
    /// Root pid of the "ghoztty-spawned" process tree for the current source
    /// (remote: the agent's own pid; local: this app's own pid). 0 ⇒ unknown (an
    /// old agent that doesn't report it) — the UI then falls back to showing all
    /// rows regardless of the toggle.
    @Published private(set) var rootPid: Int64 = 0
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

    /// Per-source summaries for the machine-card carousel (status dot + uptime +
    /// tiny cpu/mem). Driven for inactive REMOTE cards by a lifetime probe and for
    /// the LOCAL card by a light one-shot sampler; the ACTIVE card prefers the live
    /// `host`. Keyed by `MonitorSource`.
    struct CardSummary: Equatable {
        enum State: Equatable { case connecting, failed, live }
        var state: State = .connecting
        var uptimeS: UInt64 = 0
        var cpuPct: Float = 0
        var memUsed: UInt64 = 0
        var memTotal: UInt64 = 0
    }
    @Published private(set) var cardSummaries: [MonitorSource: CardSummary] = [:]

    /// Lifetime probe feeding the inactive remote cards' summaries (same dial +
    /// metrics-subscribe used by the ⌘⇧N picker). Torn down in `stop()`.
    private let cardProbe = MachineMetricsProbe()
    /// Light timer that samples the LOCAL host for its card summary.
    private var localCardTimer: Timer?
    /// Bridges the probe's `@Published readings` into `cardSummaries`.
    private var probeObserver: AnyCancellable?

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
        startCardSummaries()
        beginCurrentSource()
    }

    /// Tear down everything for good: stop the active source, the card probe, and
    /// forbid restart. Idempotent.
    func stop() {
        guard !stopped else { return }
        stopped = true
        teardownCurrentSource()
        probeObserver = nil
        cardProbe.stop()
        localCardTimer?.invalidate()
        localCardTimer = nil
    }

    // MARK: Card summaries (carousel)

    /// Spin up the lifetime sources that feed every card's summary: one
    /// `MachineMetricsProbe` across all registered machines (inactive remote cards)
    /// and a light local sampler (the Local card). The active card prefers `host`.
    private func startCardSummaries() {
        // Seed initial states so cards render immediately.
        cardSummaries[.local] = CardSummary(state: .connecting)
        for m in machines { cardSummaries[.remote(m)] = CardSummary(state: .connecting) }

        // Bridge the probe's readings → cardSummaries on every publish.
        probeObserver = cardProbe.$readings
            .receive(on: RunLoop.main)
            .sink { [weak self] readings in
                guard let self, !self.stopped else { return }
                for m in self.machines {
                    guard let reading = readings[m.id] else { continue }
                    let key = MonitorSource.remote(m)
                    var s = self.cardSummaries[key] ?? CardSummary()
                    switch reading {
                    case .connecting: s.state = .connecting
                    case .failed: s.state = .failed
                    case .live(let hm):
                        s.state = .live
                        s.cpuPct = hm.cpuPct
                        s.memUsed = hm.memUsed
                        s.memTotal = hm.memTotal
                        s.uptimeS = hm.uptimeS
                    }
                    self.cardSummaries[key] = s
                }
            }
        cardProbe.start(machines)

        // Sample Local now and on a light timer.
        sampleLocalCard()
        let t = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLocalCard() }
        }
        localCardTimer = t
    }

    /// The summary to show on a card. For the ACTIVE source we prefer the live
    /// `host` (freshest), falling back to the probe/local-sampled summary.
    func summary(for src: MonitorSource) -> CardSummary {
        if src == source, host.ncpu > 0 || host.uptimeS > 0 {
            let state: CardSummary.State =
                (lastRefreshFailed && procs.isEmpty) ? .failed
                : switching ? .connecting
                : .live
            return CardSummary(
                state: state,
                uptimeS: host.uptimeS,
                cpuPct: host.cpuPct,
                memUsed: host.memUsed,
                memTotal: host.memTotal
            )
        }
        return cardSummaries[src] ?? CardSummary()
    }

    /// One-shot local HOST sample (off-main) feeding the Local card summary.
    ///
    /// Uses `ghostty_local_host_metrics`, NOT `ghostty_local_proc_list`. The card
    /// only ever read `list.host`, but going through the proc list made it a second
    /// consumer of the shared per-process CPU sampler: every call replaces that
    /// sampler's prev-sample baselines, so this 5s timer landing near the table's
    /// 1.5s timer left the table measuring a delta over a near-zero wall window and
    /// reporting 0% for every row. (It also enumerated hundreds of processes every
    /// 5 seconds only to throw the rows away.)
    private func sampleLocalCard() {
        guard !stopped else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let h = ghostty_local_host_metrics()
            let cpu = h.cpu_pct, memU = h.mem_used, memT = h.mem_total, up = h.uptime_s
            // A host read has no failure mode of its own; a machine that reports no
            // memory at all is the one signal that sampling didn't work.
            let ok = memT > 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    var s = self.cardSummaries[.local] ?? CardSummary()
                    s.state = ok ? .live : .failed
                    s.cpuPct = cpu; s.memUsed = memU; s.memTotal = memT; s.uptimeS = up
                    self.cardSummaries[.local] = s
                }
            }
        }
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
        rootPid = 0
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
            let rootPid = list.agent_pid
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
                        cmd: String(cString: p.cmd),
                        tty: String(cString: p.tty)
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
                        self.rootPid = rootPid
                        // Attribute against the CURRENT pane list: panes open,
                        // close, and get renamed between refreshes, and a pid can
                        // be recycled into a different pane entirely. Runs here on
                        // main because reading the pane list touches AppKit.
                        let owners = PaneAttribution.attribute(
                            procs: rows,
                            panesByTTY: PaneAttribution.panesByTTY(for: self.source)
                        )
                        self.procs = owners.isEmpty ? rows : rows.map { row in
                            var r = row
                            r.pane = owners[row.pid]
                            return r
                        }
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
    /// disappears. Surfaces failures via `actionError`. Convenience for N==1.
    func kill(_ row: ProcRow) {
        killSelected([row])
    }

    /// Kill every row in `rows` on the current source (signal "TERM"), sequentially
    /// on one background hop, then force a SINGLE refresh at the end. Failures are
    /// aggregated into one `actionError` ("Killed 3 of 5 (2 failed: …)"). On full
    /// success `onAllSucceeded` runs on the main actor (used to clear selection).
    func killSelected(_ rows: [ProcRow], onAllSucceeded: (() -> Void)? = nil) {
        guard !stopped, !rows.isEmpty else { onAllSucceeded?(); return }
        let isLocal = remote == nil
        let handle = remote?.handle
        // Marshal the pid/name pairs up front so the closure captures plain values.
        let targets: [(pid: Int64, name: String)] = rows.map { ($0.pid, $0.name) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: [(pid: Int64, name: String)] = []
            for t in targets {
                let ok: Bool = "TERM".withCString { sig in
                    if isLocal {
                        return ghostty_local_proc_kill(t.pid, sig)
                    } else {
                        return ghostty_remote_connection_proc_kill(handle!, t.pid, sig, 0)
                    }
                }
                if !ok { failed.append(t) }
            }
            let total = targets.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    // One refresh after the whole batch so survivors/casualties
                    // settle in a single table update.
                    self.refresh()
                    if failed.isEmpty {
                        onAllSucceeded?()
                        return
                    }
                    let killed = total - failed.count
                    if total == 1 {
                        let only = failed[0]
                        self.actionError = "Couldn't kill \(only.name.isEmpty ? "process" : only.name) (PID \(only.pid)). It may require elevated privileges."
                    } else {
                        // List up to a few failed names so the cause is concrete.
                        let names = failed.prefix(3).map { $0.name.isEmpty ? "PID \($0.pid)" : $0.name }
                        var detail = names.joined(separator: ", ")
                        if failed.count > names.count { detail += ", …" }
                        self.actionError = "Killed \(killed) of \(total) (\(failed.count) failed: \(detail)). Some may require elevated privileges."
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
    /// Multi-row selection, keyed by `ProcRow.id` (pid). SwiftUI `Table` drives
    /// native Cmd/Shift-click multi-select into this set.
    @State private var selection = Set<Int64>()
    @State private var sortOrder: [KeyPathComparator<ProcRow>] = [
        .init(\.cpuPctPerCore, order: .reverse)
    ]
    /// The rows pending a kill confirmation (1 ⇒ single, N ⇒ bulk). nil ⇒ no dialog.
    @State private var confirmingKill: [ProcRow]?
    @State private var showingSpawn = false
    /// When false (default) the table shows ONLY ghoztty-spawned processes (the
    /// agent / this app and its descendant tree); when true it shows every process.
    @State private var showAll = false
    /// The carousel card the keyboard focus highlight is on. Arrows move it;
    /// Return/Space commits a `switchTo` (so arrowing doesn't dial on every press).
    /// Seeded to the active source's index on appear.
    @State private var focusedCardIndex: Int = 0

    /// Whether filtering to ghoztty-spawned processes is even possible: we need
    /// either a known root pid or at least one attributed pane. When the agent
    /// pre-dates the `agent_pid` field AND nothing attributes, we can't compute the
    /// set at all, so we always show everything.
    private var canFilterSpawned: Bool {
        model.rootPid != 0 || model.procs.contains { $0.pane != nil }
    }

    /// Whether the table is currently restricted to ghoztty-spawned processes.
    private var spawnedOnlyActive: Bool { canFilterSpawned && !showAll }

    /// The set of pids that are ghoztty-spawned: everything attributed to one of
    /// our panes, PLUS `rootPid` and its transitive descendants.
    ///
    /// The root-descendant BFS alone is not sufficient, and on this platform is
    /// usually empty. `rootPid` for a local source is the APP's pid, but with
    /// `session-persistence = on` (the default) every pane's shell is a child of
    /// `ghoztty-agent`, not of the app — the app process has no children at all, so
    /// the BFS finds only the app itself and the filter hides every pane process it
    /// exists to show. Pane attribution reaches those subtrees directly, and it also
    /// covers the remote case where the panes belong to that machine's agent.
    ///
    /// The BFS is kept because it still catches processes the app spawned itself
    /// (non-persistent panes, and helpers with no pane of their own). Robust to
    /// cycles (visited set) and missing parents (a pid with no path to the root is
    /// simply excluded).
    private var spawnedPIDs: Set<Int64> {
        var result = Set(model.procs.lazy.filter { $0.pane != nil }.map(\.pid))

        let root = model.rootPid
        guard root != 0 else { return result }
        // children[ppid] = [pid, …]
        var children: [Int64: [Int64]] = [:]
        for p in model.procs {
            children[p.ppid, default: []].append(p.pid)
        }
        result.insert(root)
        var queue: [Int64] = [root]
        while let pid = queue.popLast() {
            guard let kids = children[pid] else { continue }
            for kid in kids where !result.contains(kid) {
                result.insert(kid)
                queue.append(kid)
            }
        }
        return result
    }

    /// Processes for the table: ghoztty-spawned filter (unless "Show all" / no known
    /// root), THEN the search query (name or pid substring), THEN sort. The toggle
    /// and search compose.
    private var filtered: [ProcRow] {
        var base = model.procs
        if spawnedOnlyActive {
            let spawned = spawnedPIDs
            base = base.filter { spawned.contains($0.pid) }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            base = base.filter {
                $0.name.localizedCaseInsensitiveContains(q) ||
                String($0.pid).contains(q)
            }
        }
        return base.sorted(using: sortOrder)
    }

    /// The currently selected rows resolved from the selected pids (against the full
    /// proc list, so a row hidden by the current filter/search but still selected is
    /// still resolved). Order is unspecified; only used for counts + the kill batch.
    private var selectedRows: [ProcRow] {
        guard !selection.isEmpty else { return [] }
        return model.procs.filter { selection.contains($0.pid) }
    }

    /// The confirmation-dialog title: one process names it (PID); many give a count.
    private var killConfirmTitle: String {
        guard let rows = confirmingKill, !rows.isEmpty else { return "Kill process?" }
        if rows.count == 1 {
            let r = rows[0]
            return "Kill \(r.name.isEmpty ? "process" : r.name) (PID \(r.pid))?"
        }
        return "Kill \(rows.count) processes?"
    }

    var body: some View {
        VStack(spacing: 0) {
            cardCarousel
            Divider()
            header
            Divider()
            controlBar
            Divider()
            table
            if model.actionError != nil { errorBanner }
        }
        .frame(minWidth: 620, minHeight: 380)
        .confirmationDialog(
            killConfirmTitle,
            isPresented: Binding(
                get: { confirmingKill != nil },
                set: { if !$0 { confirmingKill = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rows = confirmingKill, !rows.isEmpty {
                Button(rows.count == 1 ? "Kill" : "Kill \(rows.count)", role: .destructive) {
                    model.killSelected(rows) { selection.removeAll() }
                    confirmingKill = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmingKill = nil }
        } message: {
            Text(confirmingKill?.count ?? 0 > 1
                ? "This sends a termination signal to each selected process."
                : "This sends a termination signal to the process.")
        }
        .sheet(isPresented: $showingSpawn) {
            NewProcessSheet(sourceLabel: model.source.label) { cmd, cwd in
                model.spawn(cmd: cmd, cwd: cwd) { _ in }
            }
        }
    }

    // MARK: Card carousel (machine switcher)

    /// All sources in card order: Local first, then every registered machine.
    private var allSources: [MonitorSource] {
        [.local] + model.machines.map { .remote($0) }
    }

    /// A horizontal carousel of machine cards above the charts. Clicking any card
    /// switches to that source in ONE click (`model.switchTo`). LEFT/RIGHT arrows
    /// move a focus ring between cards; Return/Space commits the switch (so arrowing
    /// never dials a remote connection). The active card has the accent
    /// fill/border; the focused card gets a distinct focus ring.
    private var cardCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack {
                // Invisible keyboard-shortcut buttons drive arrow/commit regardless
                // of which subview holds focus (the proven MachineChooserView
                // pattern; avoids macOS-14-only .onKeyPress).
                Group {
                    Button { moveFocus(-1) } label: { Color.clear }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { moveFocus(1) } label: { Color.clear }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button { commitFocusedCard() } label: { Color.clear }
                        .keyboardShortcut(.return, modifiers: [])
                    Button { commitFocusedCard() } label: { Color.clear }
                        .keyboardShortcut(.space, modifiers: [])
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                HStack(spacing: 10) {
                    ForEach(Array(allSources.enumerated()), id: \.element) { idx, src in
                        MachineCard(
                            source: src,
                            summary: model.summary(for: src),
                            isSelected: src == model.source,
                            isFocused: idx == focusedCardIndex,
                            switching: model.switching && src == model.source
                        ) {
                            focusedCardIndex = idx
                            model.switchTo(src)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .onAppear {
            // Seed the focus ring on the active card.
            if let i = allSources.firstIndex(of: model.source) { focusedCardIndex = i }
        }
    }

    /// Move the focus ring by `delta`, clamped to the card range.
    private func moveFocus(_ delta: Int) {
        let count = allSources.count
        guard count > 0 else { return }
        focusedCardIndex = min(max(focusedCardIndex + delta, 0), count - 1)
    }

    /// Commit (switch to) the currently focused card's source.
    private func commitFocusedCard() {
        guard allSources.indices.contains(focusedCardIndex) else { return }
        model.switchTo(allSources[focusedCardIndex])
    }

    // MARK: Header (gauges)

    /// The two trend charts, split 50/50 across the full panel width. The
    /// redundant active-machine title/uptime block is intentionally gone — the
    /// carousel above already shows the selected machine + its uptime.
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            TrendGaugeView(
                title: "CPU",
                value: String(format: "%.0f%%", normalizedHostCPU),
                detail: "\(model.host.ncpu) cores",
                tint: .blue,
                metric: .cpu,
                samples: model.samples,
                memTotal: model.host.memTotal
            )
            .frame(maxWidth: .infinity)
            TrendGaugeView(
                title: "Memory",
                value: memString(model.host.memUsed),
                detail: "of \(memString(model.host.memTotal))",
                tint: .green,
                metric: .memory,
                samples: model.samples,
                memTotal: model.host.memTotal
            )
            .frame(maxWidth: .infinity)
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

            // Show all vs. ghoztty-spawned only. Disabled (forced on) when the agent
            // pre-dates the agent_pid field so we never imply an empty list.
            Toggle("Show all", isOn: $showAll)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!canFilterSpawned)
                .help(canFilterSpawned
                    ? "When off, show only processes Ghoztty started (the agent and its descendants)."
                    : "This agent pre-dates spawned-process filtering, so all processes are shown.")

            Spacer()

            countLabel

            // Kill appears whenever one or more rows are selected; the label counts
            // them ("Kill" for 1, "Kill N" for N>1).
            if !selectedRows.isEmpty {
                let rows = selectedRows
                Button(role: .destructive) {
                    confirmingKill = rows
                } label: {
                    Label(rows.count == 1 ? "Kill" : "Kill \(rows.count)",
                          systemImage: "xmark.octagon")
                }
                .help(rows.count == 1
                    ? "Terminate \(rows[0].name.isEmpty ? "PID \(rows[0].pid)" : rows[0].name)"
                    : "Terminate \(rows.count) selected processes")
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

    /// The process-count label. When restricted to ghoztty-spawned processes, show
    /// "N of M" (visible of total) so the user knows more exist; otherwise the plain
    /// "M processes".
    @ViewBuilder
    private var countLabel: some View {
        let total = model.procs.count
        let shown = filtered.count
        Text(spawnedOnlyActive && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(shown) of \(total)"
            : "\(shown) processes")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(spawnedOnlyActive
                ? "Showing \(shown) Ghoztty-spawned of \(total) total processes."
                : "\(shown) processes")
    }

    // MARK: Table (selectable)

    private var table: some View {
        Table(of: ProcRow.self, selection: $selection, sortOrder: $sortOrder) {
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

            // Per-core %CPU, shown as-is (top / Activity Monitor convention): a
            // fully-busy thread is ~100 and a multithreaded process exceeds it.
            TableColumn("% CPU", value: \.cpuPctPerCore) { row in
                Text(String(format: "%.1f", row.cpuPctPerCore))
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

            // Which window/pane the process belongs to. This is the column that
            // makes a filtered list readable: without it, twenty agent sessions all
            // render as the same process name (Claude Code reports its version
            // string, "2.1.220", as its accounting name) with nothing to tell them
            // apart. Sorts by label so a window's processes group together.
            TableColumn("Window / Pane", value: \.paneSortKey) { row in
                let pane = row.pane
                Text(pane?.label ?? "—")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(pane == nil ? Color.secondary.opacity(0.6) : Color.primary)
                    .help(pane?.detail ?? "Not started by a Ghoztty pane.")
            }
            .width(min: 100, ideal: 180)

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
        // Prune pids that no longer exist (process exited, source/filter switched)
        // so the Kill count stays honest. The Table already ignores stale ids; this
        // keeps `selection` itself in sync.
        .onChange(of: model.procs) { newProcs in
            guard !selection.isEmpty else { return }
            let live = Set(newProcs.map { $0.pid })
            let pruned = selection.intersection(live)
            if pruned.count != selection.count { selection = pruned }
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

    /// Chart height (width expands to fill the gauge's half of the row).
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
                // Expand to fill the gauge's half of the row (the parent applies
                // `.frame(maxWidth: .infinity)` for the 50/50 split); keep height.
                .frame(maxWidth: .infinity, minHeight: Self.chartHeight, maxHeight: Self.chartHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // Soft reference gridlines at 0/25/50/75/100 (the 50% midline a touch
        // stronger; the 25/75 quarter lines fainter) so the scale + headroom read
        // at a glance without hard lines. Labels only at 0/50/100 to keep the
        // small chart uncluttered.
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { v in
                let iv = v.as(Int.self) ?? 0
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(
                        iv == 50 ? 0.20 : (iv == 0 || iv == 100 ? 0.15 : 0.10)
                    ))
                if iv == 0 || iv == 50 || iv == 100 {
                    AxisValueLabel {
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

    /// The trailing Y-axis label for a reference value. Plain percentages — the
    /// total RAM is already shown in the header ("of 64.0 GB"), so repeating it on
    /// the memory chart's 100% mark is redundant.
    private func yLabel(_ iv: Int) -> String {
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

// MARK: - Machine card

/// A single tappable card in the switcher carousel: status dot + name + a small
/// uptime/CPU/mem summary. The active (selected) card is accent-highlighted; the
/// keyboard-focused card gets a distinct focus ring (so "focused-but-not-yet-
/// switched" reads differently from "currently active"). Tapping switches in one
/// click. Pure presentation — `onSelect` does the source switch.
struct MachineCard: View {
    let source: MonitorSource
    let summary: RemoteActivityMonitorModel.CardSummary
    let isSelected: Bool
    /// True when the keyboard focus ring is on this card (arrow navigation).
    let isFocused: Bool
    /// True only for the active card while it is mid-dial.
    let switching: Bool
    let onSelect: () -> Void

    private var statusColor: Color {
        if switching { return .yellow }
        switch summary.state {
        case .connecting: return .yellow
        case .failed: return .red
        case .live: return .green
        }
    }

    private var summaryLine: String {
        switch summary.state {
        case .connecting where !switching: return "connecting…"
        case .failed: return "unreachable"
        default:
            if summary.uptimeS > 0 { return Self.uptimeString(summary.uptimeS) }
            return switching ? "connecting…" : "—"
        }
    }

    private var metricLine: String? {
        guard summary.state == .live, summary.memTotal > 0 else { return nil }
        let cpu = Int(max(0, min(100, summary.cpuPct)).rounded())
        let memPct = Int((Double(summary.memUsed) / Double(summary.memTotal) * 100).rounded())
        return "CPU \(cpu)% · Mem \(memPct)%"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(source.label)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                    if switching {
                        Spacer(minLength: 2)
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metricLine ?? " ")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(width: 160, height: 56, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.15)
                        : Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            // A distinct focus ring drawn OUTSIDE the card border for keyboard
            // focus (arrowed-to, not yet committed). Only shown when the focused
            // card is NOT the active one — otherwise the active card's own accent
            // border + this ring stack into a double border.
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .inset(by: -2.5)
                    .strokeBorder(
                        Color.accentColor.opacity(isFocused && !isSelected ? 0.9 : 0),
                        lineWidth: 2
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Switch to \(source.label)")
    }

    /// "up Nd Nh" / "up Nh Nm" / "up Nm" from a seconds count.
    static func uptimeString(_ s: UInt64) -> String {
        guard s > 0 else { return "—" }
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let mins = (s % 3_600) / 60
        if days > 0 { return "up \(days)d \(hours)h" }
        if hours > 0 { return "up \(hours)h \(mins)m" }
        return "up \(mins)m"
    }
}
