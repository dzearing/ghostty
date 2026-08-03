import Foundation
import Testing
@testable import Ghostty

/// Unit tests for `PaneAttribution.attribute`, the pure half of mapping a
/// process to the Ghoztty pane it runs in.
///
/// The AppKit half (`panesByTTY`, which reads the live window list) needs a
/// running app and is covered by driving the real panel instead; everything
/// interesting about the ALGORITHM — the two-pass seed/propagate, and its
/// behavior on hostile ppid data — lives here.
struct PaneAttributionTests {
    private func pane(_ label: String) -> AttributedPane {
        AttributedPane(paneID: UUID(), label: label, detail: label)
    }

    private func proc(
        _ pid: Int64,
        ppid: Int64,
        tty: String = "",
        cpu: Float = 0
    ) -> ProcRow {
        ProcRow(
            pid: pid,
            ppid: ppid,
            cpuPctPerCore: cpu,
            memBytes: 0,
            name: "p\(pid)",
            user: "",
            cmd: "",
            tty: tty
        )
    }

    /// The seed pass: anything holding the pane's controlling terminal is that
    /// pane's, and a process on some other tty is nobody's.
    @Test func attributesByControllingTTY() {
        let dev = pane("dev")
        let owners = PaneAttribution.attribute(
            procs: [
                proc(100, ppid: 1, tty: "ttys004"),
                proc(200, ppid: 100, tty: "ttys004"),
                proc(900, ppid: 1, tty: "ttys099"),
            ],
            panesByTTY: ["ttys004": dev]
        )
        #expect(owners[100] == dev)
        #expect(owners[200] == dev)
        #expect(owners[900] == nil)
    }

    /// The propagate pass, and the reason it exists: Claude Code's Bash-tool
    /// subprocesses call setsid and lose the controlling terminal, so a tty
    /// match alone drops exactly the processes doing the work. They remain
    /// ppid-descendants, several levels deep.
    @Test func attributesSetsidDescendantsByPPID() {
        let dev = pane("dev")
        let owners = PaneAttribution.attribute(
            procs: [
                proc(100, ppid: 1, tty: "ttys004"),      // pane shell
                proc(200, ppid: 100, tty: "ttys004"),    // claude
                proc(300, ppid: 200, tty: ""),           // setsid'd bash
                proc(400, ppid: 300, tty: "", cpu: 99),  // its busy grandchild
            ],
            panesByTTY: ["ttys004": dev]
        )
        #expect(owners[300] == dev)
        #expect(owners[400] == dev)
    }

    /// A process whose ppid chain never reaches a pane stays unattributed —
    /// attribution must not guess, or every daemon on the machine would be
    /// claimed by whichever pane happened to be open.
    @Test func leavesUnrelatedProcessesUnattributed() {
        let owners = PaneAttribution.attribute(
            procs: [
                proc(100, ppid: 1, tty: "ttys004"),
                proc(500, ppid: 1, tty: ""),
                proc(501, ppid: 500, tty: ""),
            ],
            panesByTTY: ["ttys004": pane("dev")]
        )
        #expect(owners[500] == nil)
        #expect(owners[501] == nil)
    }

    /// A ppid cycle must terminate. Real snapshots are taken while processes
    /// come and go, and a recycled pid can produce a loop; hanging the UI
    /// thread over it is not an option.
    @Test func survivesPPIDCycle() {
        let owners = PaneAttribution.attribute(
            procs: [
                proc(100, ppid: 300, tty: ""),
                proc(200, ppid: 100, tty: ""),
                proc(300, ppid: 200, tty: ""),
            ],
            panesByTTY: ["ttys004": pane("dev")]
        )
        #expect(owners.isEmpty)
    }

    /// A parent outside the snapshot (it exited, or the agent's row cap clipped
    /// it) ends the walk instead of faulting.
    @Test func stopsAtAMissingParent() {
        let owners = PaneAttribution.attribute(
            procs: [proc(700, ppid: 12345, tty: "")],
            panesByTTY: ["ttys004": pane("dev")]
        )
        #expect(owners[700] == nil)
    }

    /// Two panes, two ttys: each keeps its own subtree. A shared propagation
    /// map that leaked between roots would show up here.
    @Test func keepsSeparatePanesSeparate() {
        let a = pane("alpha")
        let b = pane("beta")
        let owners = PaneAttribution.attribute(
            procs: [
                proc(100, ppid: 1, tty: "ttys001"),
                proc(101, ppid: 100, tty: ""),
                proc(200, ppid: 1, tty: "ttys002"),
                proc(201, ppid: 200, tty: ""),
            ],
            panesByTTY: ["ttys001": a, "ttys002": b]
        )
        #expect(owners[101] == a)
        #expect(owners[201] == b)
    }

    /// No panes ⇒ no work and no attribution (the "Show all" / remote-source
    /// case). Cheap early-out, and it must not claim anything.
    @Test func noPanesAttributesNothing() {
        let owners = PaneAttribution.attribute(
            procs: [proc(100, ppid: 1, tty: "ttys004")],
            panesByTTY: [:]
        )
        #expect(owners.isEmpty)
    }

    /// The surface reports `/dev/ttys004` while the sampler reports `ttys004`;
    /// they have to compare equal or nothing ever matches.
    @Test func normalizesDevPrefix() {
        #expect(PaneAttribution.bareTTY("/dev/ttys004") == "ttys004")
        #expect(PaneAttribution.bareTTY("ttys004") == "ttys004")
        #expect(PaneAttribution.bareTTY("") == "")
    }

    /// `window-7` is the auto-minted alias, not a name a human would recognise;
    /// `window-of-mine` is a real name that merely starts the same way.
    @Test func recognizesAutoMintedWindowNames() {
        #expect(PaneAttribution.isAutoMintedName("window-7"))
        #expect(PaneAttribution.isAutoMintedName("window-123"))
        #expect(!PaneAttribution.isAutoMintedName("window-of-mine"))
        #expect(!PaneAttribution.isAutoMintedName("window-"))
        #expect(!PaneAttribution.isAutoMintedName("ghoztty"))
    }
}
