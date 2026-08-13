import AppKit
import Foundation

/// The pure core of `+rearrange`: turn a `--layout=` JSON document plus the
/// panes a window already has into the split tree that layout describes.
///
/// Split out of `IPCServer` because everything here is a value in, a value
/// out — it needs no app, so it is testable (`RearrangeLayoutTests`). The
/// AppKit half — swapping the tree in, moving focus, pruning the target
/// registry — stays in `IPCServer.handleRearrange`.
enum RearrangeLayout {
    /// One node of the layout document: either a leaf naming a pane, or a
    /// split with a direction, a ratio (percent), and two children.
    final class Node: Decodable {
        let pane: String?
        let direction: String?
        let ratio: Double?
        let left: Node?
        let right: Node?
    }

    /// What the target registry knows about one name in a layout.
    ///
    /// A terminal pane is registered by its SURFACE, so the window's tree has
    /// to be asked which pane wraps it. A viewer pane has no surface at all —
    /// `IPCServer.TargetEntry.surfaceView` is deliberately nil for one, which
    /// is how `+read`/`+send-keys`/`+set-state`/`+set-banner` reject viewers —
    /// so it arrives as the `PaneView` it already is.
    struct Target {
        let surface: Ghostty.SurfaceView?
        let viewerPane: PaneView?

        /// False only when the registry entry's weak reference has been
        /// collected: the pane it named is genuinely gone.
        let isAlive: Bool

        init(
            surface: Ghostty.SurfaceView? = nil,
            viewerPane: PaneView? = nil,
            isAlive: Bool
        ) {
            self.surface = surface
            self.viewerPane = viewerPane
            self.isAlive = isAlive
        }

        /// The leaf of `tree` this target names, or nil when it names none —
        /// the pane belongs to some other window (or the target is a window,
        /// which has no pane of its own).
        @MainActor
        func pane(in tree: SplitTree<PaneView>) -> PaneView? {
            // A viewer pane IS the leaf, so it only has to be a member of
            // this window's tree. A terminal pane is registered by its
            // surface, so the tree is asked which pane wraps it.
            if let viewerPane {
                return tree.contains(where: { $0 === viewerPane }) ? viewerPane : nil
            }
            if let surface {
                return tree.pane(for: surface)
            }
            return nil
        }
    }

    /// A layout that cannot be built, carrying the message the CLI prints.
    struct Failure: Error, Equatable, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Build the tree `layoutJSON` describes out of panes that are already in
    /// `tree`, resolving each name through `resolve`.
    ///
    /// The existing `PaneView` wrappers are reused, so leaf identity — and
    /// therefore SwiftUI structural identity — survives the rearrange: a
    /// terminal keeps its process and scrollback, a viewer its rendered page
    /// and scroll position.
    @MainActor
    static func build(
        layoutJSON: String,
        in tree: SplitTree<PaneView>,
        resolve: (String) -> Target?
    ) -> Result<SplitTree<PaneView>.Node, Failure> {
        guard let data = layoutJSON.data(using: .utf8) else {
            return .failure(.init(message: "invalid UTF-8 in layout JSON"))
        }

        let layout: Node
        do {
            layout = try JSONDecoder().decode(Node.self, from: data)
        } catch {
            return .failure(.init(message: "invalid layout JSON: \(error.localizedDescription)"))
        }

        // Collect all pane names referenced in the layout
        var names: [String] = []
        if let error = collectPaneNames(layout, into: &names) {
            return .failure(.init(message: error))
        }

        // Check for duplicates
        if Set(names).count != names.count {
            let dupes = names.filter { name in
                names.filter { $0 == name }.count > 1
            }
            return .failure(.init(message: "duplicate pane name in layout: '\(Set(dupes).first ?? "")'"))
        }

        // Must have at least one pane
        if names.isEmpty {
            return .failure(.init(message: "layout must contain at least one pane"))
        }

        var panesByName: [String: PaneView] = [:]
        for name in names {
            guard let target = resolve(name) else {
                return .failure(.init(message: "pane '\(name)' not found in registry"))
            }
            guard target.isAlive else {
                return .failure(.init(message: "pane '\(name)' is no longer alive"))
            }
            guard let pane = target.pane(in: tree) else {
                return .failure(.init(message: "pane '\(name)' is not in the target window"))
            }
            panesByName[name] = pane
        }

        do {
            return .success(try node(from: layout, panes: panesByName))
        } catch {
            return .failure(.init(message: "failed to build layout: \(error)"))
        }
    }

    private static func collectPaneNames(_ node: Node, into names: inout [String]) -> String? {
        if let pane = node.pane {
            names.append(pane)
            return nil
        }

        guard node.direction != nil else {
            return "layout node must have either 'pane' or 'direction'"
        }
        guard let left = node.left else {
            return "split node must have 'left' child"
        }
        guard let right = node.right else {
            return "split node must have 'right' child"
        }

        if let error = collectPaneNames(left, into: &names) { return error }
        if let error = collectPaneNames(right, into: &names) { return error }
        return nil
    }

    @MainActor
    private static func node(
        from layout: Node,
        panes: [String: PaneView]
    ) throws -> SplitTree<PaneView>.Node {
        if let paneName = layout.pane {
            guard let pane = panes[paneName] else {
                throw BuildError.paneNotFound(paneName)
            }
            return .leaf(view: pane)
        }

        guard let dirStr = layout.direction else {
            throw BuildError.invalidNode
        }

        let direction: SplitTree<PaneView>.Direction = switch dirStr.lowercased() {
        case "horizontal": .horizontal
        case "vertical": .vertical
        default: throw BuildError.invalidDirection(dirStr)
        }

        guard let leftLayout = layout.left, let rightLayout = layout.right else {
            throw BuildError.missingSplitChildren
        }

        let ratioPercent = layout.ratio ?? 50
        let clampedRatio = min(0.9, max(0.1, ratioPercent / 100.0))

        return .split(.init(
            direction: direction,
            ratio: clampedRatio,
            left: try node(from: leftLayout, panes: panes),
            right: try node(from: rightLayout, panes: panes)
        ))
    }

    private enum BuildError: Error, CustomStringConvertible {
        case paneNotFound(String)
        case invalidNode
        case invalidDirection(String)
        case missingSplitChildren

        var description: String {
            switch self {
            case .paneNotFound(let name): return "pane '\(name)' not found"
            case .invalidNode: return "node must have 'pane' or 'direction'"
            case .invalidDirection(let dir): return "invalid direction '\(dir)' (expected 'horizontal' or 'vertical')"
            case .missingSplitChildren: return "split node must have 'left' and 'right' children"
            }
        }
    }
}
