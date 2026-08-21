import AppKit
import Testing
@testable import Ghostty

/// Tests for fixed-edge divider movement: moving one divider moves only that
/// edge, and every other divider in the tree keeps its pixel position.
struct SplitTreeDividerTests {
    // MARK: - Fixtures

    /// Three columns of 300pt in a 900pt-wide window, nested to the RIGHT:
    /// `A | (B | C)`.
    private func makeRightNestedColumns() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right, ratio: 1.0 / 3.0)
        tree = try tree.inserting(view: c, at: b, direction: .right, ratio: 0.5)
        return (tree, a, b, c)
    }

    /// Three columns of 300pt in a 900pt-wide window, nested to the LEFT:
    /// `(A | B) | C`.
    private func makeLeftNestedColumns() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: c, at: a, direction: .right, ratio: 2.0 / 3.0)
        tree = try tree.inserting(view: b, at: a, direction: .right, ratio: 0.5)
        return (tree, a, b, c)
    }

    /// Three rows of 300pt in a 900pt-tall window, nested DOWN: `A / (B / C)`.
    private func makeRightNestedRows() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .down, ratio: 1.0 / 3.0)
        tree = try tree.inserting(view: c, at: b, direction: .down, ratio: 0.5)
        return (tree, a, b, c)
    }

    /// The laid-out rect of each view, in the order given.
    private func rects(
        _ node: SplitTree<MockView>.Node,
        in size: CGSize,
        of views: [MockView]
    ) -> [CGRect] {
        let slots = node.spatial(within: size).slots
        return views.map { view in
            slots.first { slot in
                guard case .leaf(let candidate) = slot.node else { return false }
                return candidate === view
            }?.bounds ?? .null
        }
    }

    /// The laid-out width of each view, rounded so ratio round-trips compare cleanly.
    private func widths(
        _ node: SplitTree<MockView>.Node,
        in width: CGFloat,
        of views: MockView...
    ) -> [CGFloat] {
        rects(node, in: CGSize(width: width, height: 100), of: views).map { ($0.width * 1000).rounded() / 1000 }
    }

    /// The laid-out height of each view, rounded so ratio round-trips compare cleanly.
    private func heights(
        _ node: SplitTree<MockView>.Node,
        in height: CGFloat,
        of views: MockView...
    ) -> [CGFloat] {
        rects(node, in: CGSize(width: 100, height: height), of: views).map { ($0.height * 1000).rounded() / 1000 }
    }

    // MARK: - Minimum sizes

    @Test func minimumSizeAddsAlongTheSplitAxis() throws {
        let root = try #require(try makeRightNestedColumns().0.root)

        // Three panes stacked along the horizontal axis: three pane minimums.
        #expect(root.minimumSize(along: .horizontal) == 30)
    }

    @Test func minimumSizePeaksAcrossTheSplitAxis() throws {
        let root = try #require(try makeRightNestedColumns().0.root)

        // Nothing is stacked vertically, so vertically it's one pane's worth.
        #expect(root.minimumSize(along: .vertical) == 10)
    }

    @Test func minimumSizeOfALeafIsOnePane() {
        let node = SplitTree<MockView>.Node.leaf(view: MockView())
        #expect(node.minimumSize(along: .horizontal) == 10)
        #expect(node.minimumSize(along: .vertical) == 10)
    }

    // MARK: - Fixed edges

    @Test func movingADividerLeavesTheOneBeyondItAlone() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        let root = try #require(tree.root)

        // Drag the A|B divider 100pt right. B absorbs all of it; C must not move.
        let moved = root.movingDivider(to: 400, in: 900)

        #expect(widths(moved, in: 900, of: a, b, c) == [400, 200, 300])
    }

    @Test func movingADividerLeavesTheOneBehindItAlone() throws {
        let (tree, a, b, c) = try makeLeftNestedColumns()
        let root = try #require(tree.root)

        // Drag the B|C divider 100pt right. B absorbs all of it; A must not move.
        let moved = root.movingDivider(to: 700, in: 900)

        #expect(widths(moved, in: 900, of: a, b, c) == [300, 400, 200])
    }

    @Test func movingANestedDividerLeavesTheOuterOneAlone() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        let root = try #require(tree.root)
        guard case .split(let outer) = root else {
            Issue.record("unexpected node type")
            return
        }

        // The B|C divider lives in the nested node, which measures 600pt.
        let movedInner = outer.right.movingDivider(to: 400, in: 600)
        let moved = try root.replacingNode(at: .init(path: [.right]), with: movedInner)

        #expect(widths(moved, in: 900, of: a, b, c) == [300, 400, 200])
    }

    @Test func movingAVerticalDividerLeavesTheOneBeyondItAlone() throws {
        let (tree, a, b, c) = try makeRightNestedRows()
        let root = try #require(tree.root)

        let moved = root.movingDivider(to: 400, in: 900)

        #expect(heights(moved, in: 900, of: a, b, c) == [400, 200, 300])
    }

    @Test func movingADividerAcrossAPerpendicularSplitResizesBothOfItsPanes() throws {
        // (A over B) | C -- the left column is 600pt wide and split in half
        // vertically; C is 300pt wide.
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: c, at: a, direction: .right, ratio: 2.0 / 3.0)
        tree = try tree.inserting(view: b, at: a, direction: .down, ratio: 0.5)
        let root = try #require(tree.root)

        // Drag the column divider 100pt left. A and B share that edge, so both
        // narrow together, and the divider between them doesn't move.
        let moved = root.movingDivider(to: 500, in: 900)

        #expect(widths(moved, in: 900, of: a, b, c) == [500, 500, 400])
        #expect(heights(moved, in: 800, of: a, b, c) == [400, 400, 800])
    }

    // MARK: - Clamping

    @Test func aPanePushedToItsMinimumMakesTheFixedEdgeGive() throws {
        let (tree, a, b, c) = try makeLeftNestedColumns()
        let root = try #require(tree.root)

        // Drag the B|C divider from 600 to 200. B can only give up 290 of the
        // 400 before it hits the 10pt minimum, so A gives up the rest and the
        // A|B divider finally moves too.
        let moved = root.movingDivider(to: 200, in: 900)

        #expect(widths(moved, in: 900, of: a, b, c) == [190, 10, 700])
    }

    @Test func theDividerStopsWhenEveryPaneBehindItIsAtItsMinimum() throws {
        let (tree, a, b, c) = try makeLeftNestedColumns()
        let root = try #require(tree.root)

        let moved = root.movingDivider(to: -500, in: 900)

        #expect(widths(moved, in: 900, of: a, b, c) == [10, 10, 880])
    }

    @Test func theDividerStopsWhenEveryPaneAheadOfItIsAtItsMinimum() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        let root = try #require(tree.root)

        let moved = root.movingDivider(to: 5000, in: 900)

        #expect(widths(moved, in: 900, of: a, b, c) == [880, 10, 10])
    }

    @Test func aSplitWithNoRoomForItsMinimumsIsLeftAlone() throws {
        let root = try #require(try makeRightNestedColumns().0.root)

        // 25pt can't hold three 10pt panes, so there is no valid position to
        // move to: leave the ratios alone rather than invent out-of-range ones.
        #expect(root.movingDivider(to: 12, in: 25) == root)
    }

    @Test func aZeroSizedSplitIsLeftAlone() throws {
        let root = try #require(try makeRightNestedColumns().0.root)

        #expect(root.movingDivider(to: 100, in: 0) == root)
    }

    @Test func everyRatioStaysInRangeWhereverTheDividerIsPushed() throws {
        let root = try #require(try makeRightNestedColumns().0.root)

        for position in stride(from: -200.0, through: 1100.0, by: 37.0) {
            let moved = root.movingDivider(to: position, in: 900)
            for slot in moved.spatial(within: CGSize(width: 900, height: 100)).slots {
                guard case .split(let split) = slot.node else { continue }
                #expect(split.ratio > 0 && split.ratio < 1, "ratio \(split.ratio) at position \(position)")
            }
        }
    }

    // MARK: - Composition

    @Test func movingADividerInStepsLandsWhereOneBigMoveWould() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        let root = try #require(tree.root)

        let stepped = root
            .movingDivider(to: 350, in: 900)
            .movingDivider(to: 400, in: 900)
        let direct = root.movingDivider(to: 400, in: 900)

        #expect(widths(stepped, in: 900, of: a, b, c) == widths(direct, in: 900, of: a, b, c))
    }

    @Test func movingADividerOnALeafDoesNothing() {
        let node = SplitTree<MockView>.Node.leaf(view: MockView())
        #expect(node.movingDivider(to: 100, in: 900) == node)
    }

    // MARK: - Tree-level entry point

    @Test func treeMovesTheDividerOfANestedNode() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        guard case .split(let outer) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        let moved = try tree.movingDivider(of: outer.right, to: 400, in: 600)

        #expect(widths(try #require(moved.root), in: 900, of: a, b, c) == [300, 400, 200])
    }

    @Test func treeThrowsForANodeItDoesNotContain() throws {
        let (tree, _, _, _) = try makeRightNestedColumns()
        let stranger = SplitTree<MockView>.Node.leaf(view: MockView())

        var thrown: Error?
        do {
            _ = try tree.movingDivider(of: stranger, to: 400, in: 900)
        } catch {
            thrown = error
        }

        #expect(thrown is SplitTree<MockView>.SplitError)
    }

    @Test func treeKeepsTheZoomedPane() throws {
        let (columns, _, _, c) = try makeRightNestedColumns()
        let zoomedNode = try #require(columns.root?.node(view: c))
        let tree = SplitTree(root: columns.root, zoomed: zoomedNode)

        let moved = try tree.movingDivider(of: try #require(tree.root), to: 400, in: 900)

        #expect(moved.zoomed == zoomedNode)
    }

    // MARK: - Keyboard resize

    @Test func keyboardResizeKeepsTheFarDividerFixed() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)

        // resize_split:right,100 from A moves the A|B divider right by 100.
        let resized = try tree.resizing(node: .leaf(view: a), by: 100, in: .right, with: bounds)

        #expect(widths(try #require(resized.root), in: 900, of: a, b, c) == [400, 200, 300])
    }

    @Test func keyboardResizeStopsAtTheMinimum() throws {
        let (tree, a, b, c) = try makeRightNestedColumns()
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)

        let resized = try tree.resizing(node: .leaf(view: a), by: 5000, in: .right, with: bounds)

        #expect(widths(try #require(resized.root), in: 900, of: a, b, c) == [880, 10, 10])
    }

    @Test func keyboardResizeMatchesADragOfTheSameDivider() throws {
        let (tree, a, b, c) = try makeLeftNestedColumns()
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)

        // C's nearest horizontal parent is the root, whose divider sits at 600.
        let resized = try tree.resizing(node: .leaf(view: c), by: 400, in: .left, with: bounds)
        let dragged = try #require(tree.root).movingDivider(to: 200, in: 900)

        #expect(
            widths(try #require(resized.root), in: 900, of: a, b, c) ==
            widths(dragged, in: 900, of: a, b, c))
    }
}
