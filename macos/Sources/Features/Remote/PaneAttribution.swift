import Foundation
import AppKit

/// The pane a process was traced back to, as shown in the activity monitor's
/// "Window / Pane" column.
struct AttributedPane: Hashable {
    /// The pane's stable ghoztty-owned id (wp3 pane identity) — the thing that
    /// actually identifies the pane. The label is for humans and may collide
    /// between two panes with the same title; this never does.
    let paneID: UUID
    /// Human-readable "which window/pane is this" label.
    let label: String
    /// Full detail for the row's tooltip (window, pane, cwd, tty).
    let detail: String
}

/// Maps processes to the Ghoztty pane they are running in.
///
/// ## Why the controlling terminal, and why that isn't enough on its own
///
/// Every process started inside a pane inherits that pane's controlling
/// terminal, so a tty match identifies a pane's processes without the app
/// needing to know the pane's shell pid. (It doesn't: `+list` reports each
/// pane's FOREGROUND pid, which for an agent session is `claude`, not the
/// shell that owns the subtree.)
///
/// But a tty match alone misses real work. Observed in a live pane:
///
///     38560 ttys004 zsh          ← the agent's child: the pane's shell
///       38577 ttys004 2.1.220    ← claude
///         38730 ttys004 node     ← keeps the tty            → tty match
///         57724 ??      bash     ← Bash tool call, setsid'd → tty MISSES
///           57826 ??    jq                                  → tty MISSES
///
/// So attribution runs in two passes: **seed** every process whose tty matches a
/// pane, then **propagate** to the rest by walking up the ppid chain to the
/// nearest already-attributed ancestor. The seed catches the workers that burn
/// CPU; the propagation catches the subprocesses that dropped their terminal.
enum PaneAttribution {
    /// Attribute each process to a pane. Pure — no AppKit, no I/O — so the
    /// interesting cases (setsid'd orphan, ppid cycle, missing parent) are
    /// directly testable. `panesByTTY` is keyed by BARE tty name ("ttys004"),
    /// matching `ghostty_proc_s.tty`.
    static func attribute(
        procs: [ProcRow],
        panesByTTY: [String: AttributedPane]
    ) -> [Int64: AttributedPane] {
        guard !panesByTTY.isEmpty, !procs.isEmpty else { return [:] }

        var parent: [Int64: Int64] = [:]
        var owner: [Int64: AttributedPane] = [:]
        parent.reserveCapacity(procs.count)

        // Pass 1 — seed from the controlling terminal.
        for p in procs {
            parent[p.pid] = p.ppid
            if !p.tty.isEmpty, let pane = panesByTTY[p.tty] {
                owner[p.pid] = pane
            }
        }

        // Pass 2 — propagate to processes with no tty of their own. Every seed is
        // already placed, so this is order-independent: a process resolves to the
        // same pane regardless of where it sits in `procs`.
        for p in procs where owner[p.pid] == nil {
            // The unattributed ancestors walked on the way to a hit. They all
            // resolve to the same pane by construction (we passed through them
            // without finding an owner), so we can memoize the whole prefix and
            // keep the total work linear rather than quadratic on deep trees.
            var walked: [Int64] = []
            var seen: Set<Int64> = [p.pid]
            var cursor = p.ppid
            var found: AttributedPane?

            while cursor != 0, !seen.contains(cursor) {
                seen.insert(cursor)
                if let hit = owner[cursor] { found = hit; break }
                walked.append(cursor)
                // No entry ⇒ the parent is outside this snapshot (it exited, or
                // the agent's row cap clipped it). Stop rather than guess.
                guard let next = parent[cursor] else { break }
                cursor = next
            }

            guard let found else { continue }
            owner[p.pid] = found
            for pid in walked { owner[pid] = found }
        }

        return owner
    }

    /// Build the bare-tty → pane map for `source` from the live window list.
    ///
    /// Scoped to the panes actually backed by `source`: a remote pane's processes
    /// run on ITS machine, and tty names are only unique per machine — without
    /// this filter a remote `ttys004` would claim a local pane's processes.
    @MainActor
    static func panesByTTY(for source: MonitorSource) -> [String: AttributedPane] {
        var result: [String: AttributedPane] = [:]

        for controller in TerminalController.all {
            guard paneProcessesLive(on: source, controller: controller) else { continue }

            let panes = controller.surfaceTree.root?.leaves() ?? []
            let windowLabel = windowLabel(for: controller)

            for pane in panes {
                guard let surface = pane.surfaceView,
                      let rawTTY = surface.surfaceModel?.ttyName,
                      case let tty = bareTTY(rawTTY),
                      !tty.isEmpty
                else { continue }

                let paneTitle = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let cwd = surface.pwd.map { ($0 as NSString).lastPathComponent } ?? ""

                // One pane in the window ⇒ the window label already identifies it.
                // Several ⇒ say which one, or the column can't tell them apart —
                // which is the whole reason the column exists.
                let label: String
                if panes.count > 1, !paneTitle.isEmpty, paneTitle != windowLabel {
                    label = "\(windowLabel) › \(paneTitle)"
                } else {
                    label = windowLabel
                }

                var detailParts = ["Window: \(windowLabel)"]
                if !paneTitle.isEmpty { detailParts.append("Pane: \(paneTitle)") }
                if !cwd.isEmpty { detailParts.append("Directory: \(cwd)") }
                detailParts.append("TTY: \(tty)")

                result[tty] = AttributedPane(
                    paneID: pane.id,
                    label: label,
                    detail: detailParts.joined(separator: "\n")
                )
            }
        }

        return result
    }

    /// Whether `controller`'s pane processes run on the machine `source`
    /// enumerates — i.e. whether its ttys can appear in that source's table at all.
    ///
    /// "Has a `remoteMachine`" is NOT the same as "is not local". A
    /// session-persistence pane runs its shell under an agent reached over
    /// loopback, so it carries a `Machine` whose name is `127.0.0.1` — and
    /// `Machine.isLocalMachine` is true for exactly those. Treating any non-nil
    /// machine as remote silently attributed nothing under the Local source (the
    /// default configuration), which is the case that matters most.
    ///
    /// Matching on where the processes actually LIVE also makes the two ways of
    /// looking at this Mac — the Local card and a loopback machine card — agree,
    /// instead of one of them showing a blank column.
    @MainActor
    private static func paneProcessesLive(
        on source: MonitorSource,
        controller: TerminalController
    ) -> Bool {
        let paneMachine = controller.remoteMachine
        switch source {
        case .local:
            // No machine ⇒ the app spawned the shell itself, here. A loopback /
            // this-host agent is also here.
            guard let paneMachine else { return true }
            return paneMachine.isLocalMachine
        case .remote(let machine):
            guard let paneMachine else {
                // An app-spawned pane runs on this Mac, so it belongs to a
                // "remote" source only when that source IS this Mac.
                return machine.isLocalMachine
            }
            if paneMachine == machine { return true }
            // Two different handles on the same host (e.g. the Local agent and a
            // 127.0.0.1 machine card) enumerate the same process table.
            return paneMachine.isLocalMachine && machine.isLocalMachine
        }
    }

    /// The most human-identifiable name for a window, mirroring the fallback
    /// chain the machine chooser documents for a session row
    /// (`BrowsedSession.label`): the most intentional name first, degrading to
    /// whatever is still distinguishing.
    ///
    /// A user-pinned window title beats an IPC target name, which beats the
    /// focused pane's title, which beats the working directory. The auto-minted
    /// `window-N` alias is skipped where anything real is available — it is a
    /// unique handle, not a name a human would recognise.
    @MainActor
    private static func windowLabel(for controller: TerminalController) -> String {
        if let pinned = controller.effectiveWindowTitleOverride,
           !pinned.isEmpty { return pinned }

        let name = controller.windowName
        if !isAutoMintedName(name) { return name }

        let panes = controller.surfaceTree.root?.leaves() ?? []
        if let focused = controller.focusedSurface ?? panes.first?.surfaceView {
            let title = focused.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
            if let pwd = focused.pwd, !pwd.isEmpty {
                return (pwd as NSString).lastPathComponent
            }
        }
        return name
    }

    /// True for the `window-N` alias `BaseTerminalController.mintWindowName()`
    /// hands out when nobody named the window.
    static func isAutoMintedName(_ name: String) -> Bool {
        guard name.hasPrefix("window-") else { return false }
        let suffix = name.dropFirst("window-".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// Normalize a tty to the bare device name the sampler reports: `/dev/ttys004`
    /// (what the surface hands us) and `ttys004` (what `ghostty_proc_s.tty` carries)
    /// must compare equal.
    static func bareTTY(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/dev/") { return String(trimmed.dropFirst("/dev/".count)) }
        return trimmed
    }
}
