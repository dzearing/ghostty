import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Unit tests for `SessionLayoutManifest`'s pure pieces: the codable layout
/// model round-trips exactly (T06 restore depends on directions/ratios coming
/// back bit-identical), the live-tree encoder preserves topology, and the
/// file store honors the register/update/remove lifecycle (entries survive
/// reload; the file disappears when the last entry is removed).
struct SessionLayoutManifestTests {
    // MARK: Helpers

    /// Minimal view satisfying SplitTree's `NSView & Codable & Identifiable`
    /// so tree encoding is testable without real terminal surfaces.
    final class DummyView: NSView, Codable, Identifiable {
        let id: UUID
        let tag2: String

        init(_ tag: String) {
            self.id = UUID()
            self.tag2 = tag
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("unsupported") }

        enum CodingKeys: String, CodingKey { case tag2 }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.tag2 = try container.decode(String.self, forKey: .tag2)
            super.init(frame: .zero)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tag2, forKey: .tag2)
        }
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-layout-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("session-layout.json")
    }

    /// `left` pane split horizontally against a vertical (top/bottom) right
    /// half — nontrivial topology with distinct ratios.
    private func sampleTree() -> SessionLayoutManifest.Node {
        .split(.init(
            direction: .horizontal,
            ratio: 0.3,
            left: .leaf(.init(sessionID: "s-left", title: "left", ipcName: "ide")),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.62,
                left: .leaf(.init(sessionID: "s-top", title: "top", ipcName: nil)),
                right: .leaf(.init(sessionID: nil, title: nil, ipcName: "logs"))))))
    }

    // MARK: Codable round-trip

    @Test func nodeTreeRoundTripsThroughJSON() throws {
        let tree = sampleTree()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SessionLayoutManifest.Node.self, from: data)
        #expect(decoded == tree)
    }

    @Test func entryRoundTripsThroughJSON() throws {
        let entry = SessionLayoutManifest.Entry(
            id: UUID(),
            frame: .init(NSRect(x: 10.5, y: -20, width: 800, height: 600)),
            titleOverride: "dev",
            ipcName: "ide",
            tabGroupID: UUID(),
            tabIndex: 2,
            tree: sampleTree())
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SessionLayoutManifest.Entry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.frame?.rect == NSRect(x: 10.5, y: -20, width: 800, height: 600))
    }

    // MARK: Live-tree encoding

    @Test func encodeNodePreservesTopologyAndMapsLeaves() {
        typealias Tree = SplitTree<DummyView>
        let a = DummyView("a"), b = DummyView("b"), c = DummyView("c")
        let live: Tree.Node = .split(.init(
            direction: .horizontal,
            ratio: 0.25,
            left: .leaf(view: a),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.75,
                left: .leaf(view: b),
                right: .leaf(view: c)))))

        let encoded = SessionLayoutManifest.encodeNode(live) { view in
            .init(sessionID: "sid-\(view.tag2)", title: view.tag2, ipcName: nil)
        }

        let expected: SessionLayoutManifest.Node = .split(.init(
            direction: .horizontal,
            ratio: 0.25,
            left: .leaf(.init(sessionID: "sid-a", title: "a", ipcName: nil)),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.75,
                left: .leaf(.init(sessionID: "sid-b", title: "b", ipcName: nil)),
                right: .leaf(.init(sessionID: "sid-c", title: "c", ipcName: nil))))))
        #expect(encoded == expected)
    }

    // MARK: Tree decoding (restore)

    @Test func makeTreeNodeRebuildsTopologyExactly() {
        // Codable → live → codable must be lossless for directions, ratios,
        // and leaf order — the T06 restore contract.
        let tree = sampleTree()
        let live: SplitTree<DummyView>.Node = SessionLayoutManifest.makeTreeNode(tree) { leaf in
            DummyView(leaf.sessionID ?? "uncaptured")
        }
        let reencoded = SessionLayoutManifest.encodeNode(live) { view in
            .init(
                sessionID: view.tag2 == "uncaptured" ? nil : view.tag2,
                title: nil,
                ipcName: nil)
        }

        let expected: SessionLayoutManifest.Node = .split(.init(
            direction: .horizontal,
            ratio: 0.3,
            left: .leaf(.init(sessionID: "s-left", title: nil, ipcName: nil)),
            right: .split(.init(
                direction: .vertical,
                ratio: 0.62,
                left: .leaf(.init(sessionID: "s-top", title: nil, ipcName: nil)),
                right: .leaf(.init(sessionID: nil, title: nil, ipcName: nil))))))
        #expect(reencoded == expected)
    }

    @Test func makeTreeNodeLeafFactoryOrderMatchesLeavesHelper() {
        // Restored views pair with manifest leaves by position: the factory
        // invocation order must equal `leaves(of:)` order (and both must be
        // depth-first left-to-right, like `SplitTree.Node.leaves()`).
        let tree = sampleTree()
        var factoryOrder: [String?] = []
        let live: SplitTree<DummyView>.Node = SessionLayoutManifest.makeTreeNode(tree) { leaf in
            factoryOrder.append(leaf.sessionID)
            return DummyView(leaf.sessionID ?? "-")
        }
        let helperOrder = SessionLayoutManifest.leaves(of: tree).map(\.sessionID)
        #expect(factoryOrder == helperOrder)
        #expect(helperOrder == ["s-left", "s-top", nil])
        #expect(live.leaves().map(\.tag2) == ["s-left", "s-top", "-"])
    }

    @Test func leavesReturnsEveryLeafInTreeOrder() {
        let leaves = SessionLayoutManifest.leaves(of: sampleTree())
        #expect(leaves.map(\.ipcName) == ["ide", nil, "logs"])
        #expect(SessionLayoutManifest.leaves(of: .leaf(.init(sessionID: "x", title: nil, ipcName: nil))).count == 1)
    }

    // MARK: Missing-session-id detection

    @Test func hasMissingSessionIDsFindsTheGapAnywhereInTheTree() {
        #expect(SessionLayoutManifest.hasMissingSessionIDs(nil))
        #expect(SessionLayoutManifest.hasMissingSessionIDs(sampleTree())) // s-right leaf has nil id

        let complete: SessionLayoutManifest.Node = .split(.init(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(.init(sessionID: "x", title: nil, ipcName: nil)),
            right: .leaf(.init(sessionID: "y", title: nil, ipcName: nil))))
        #expect(!SessionLayoutManifest.hasMissingSessionIDs(complete))
    }

    // MARK: Store lifecycle

    @Test func registerUpdatePersistAndReload() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SessionLayoutManifest(fileURL: url)
        let id = store.register()
        let groupID = UUID()
        store.update(
            id,
            frame: .init(NSRect(x: 1, y: 2, width: 300, height: 400)),
            titleOverride: "dev",
            ipcName: "ide",
            tabGroupID: groupID,
            tabIndex: 1,
            tree: sampleTree())

        // A fresh instance reading the same file sees the same entry.
        let reloaded = SessionLayoutManifest(fileURL: url).allEntries()
        #expect(reloaded.count == 1)
        let entry = try #require(reloaded.first)
        #expect(entry.id == id)
        #expect(entry.frame?.rect == NSRect(x: 1, y: 2, width: 300, height: 400))
        #expect(entry.titleOverride == "dev")
        #expect(entry.ipcName == "ide")
        #expect(entry.tabGroupID == groupID)
        #expect(entry.tabIndex == 1)
        #expect(entry.tree == sampleTree())
    }

    @Test func updateKeepsStickyFieldsWhenSnapshotLacksThem() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SessionLayoutManifest(fileURL: url)
        let id = store.register()
        store.update(
            id,
            frame: .init(NSRect(x: 0, y: 0, width: 100, height: 100)),
            titleOverride: nil,
            ipcName: "ide",
            tabGroupID: nil,
            tabIndex: 0,
            tree: sampleTree())

        // A later sync with nothing new for frame/ipcName/tree (window
        // hidden mid-teardown, name lookup raced, ...) must not wipe them.
        store.update(
            id,
            frame: nil,
            titleOverride: "renamed",
            ipcName: nil,
            tabGroupID: nil,
            tabIndex: 0,
            tree: nil)

        let entry = store.allEntries().first
        #expect(entry?.frame?.rect == NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(entry?.ipcName == "ide")
        #expect(entry?.tree == sampleTree())
        #expect(entry?.titleOverride == "renamed")
    }

    @Test func updateWindowTitleRoundTripsAndClears() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SessionLayoutManifest(fileURL: url)
        let id = store.register()
        store.updateWindowTitle(id, windowTitle: "my title")
        #expect(SessionLayoutManifest(fileURL: url).allEntries().first?.titleOverride == "my title")
        store.updateWindowTitle(id, windowTitle: nil)
        #expect(SessionLayoutManifest(fileURL: url).allEntries().first?.titleOverride == nil)
    }

    @Test func removeDeletesEntryAndEmptyManifestDeletesFile() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SessionLayoutManifest(fileURL: url)
        let a = store.register()
        let b = store.register()
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.remove(a)
        #expect(store.allEntries().map(\.id) == [b])
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Removing the last entry removes the file — a launch with no
        // manifest file is the "nothing to restore" fast path.
        store.remove(b)
        #expect(store.allEntries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unknownIDsAreNoOps() {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SessionLayoutManifest(fileURL: url)
        let id = store.register()
        store.update(
            UUID(), frame: nil, titleOverride: "x", ipcName: nil,
            tabGroupID: nil, tabIndex: 5, tree: nil)
        store.updateWindowTitle(UUID(), windowTitle: "x")
        store.remove(UUID())
        #expect(store.allEntries().map(\.id) == [id])
        #expect(!store.entryHasMissingSessionIDs(UUID()))
    }

    @Test func corruptManifestFileLoadsAsEmpty() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(SessionLayoutManifest(fileURL: url).allEntries().isEmpty)
    }
}
