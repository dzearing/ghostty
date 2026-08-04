import Foundation

/// The file tree a diff pane's side panel renders.
///
/// A pure transform from git's flat list of changed paths to the rows on
/// screen, kept out of the view so the two behaviors that are easy to get
/// subtly wrong — single-child folder collapsing and filtering — are testable
/// without a window.
enum ViewerDiffTree {
    /// One row in the panel.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A working-tree section header ("Staged", "Changes", …). Only a
            /// `git-status:` diff has more than one.
            case section(String)
            /// A directory. `title` is the joined path of a collapsed chain
            /// (`macos/Sources/Features`), which is why it is not just a name.
            case folder(title: String, path: String)
            case file(ViewerDiffFile)
        }

        let id: String
        let kind: Kind
        let depth: Int

        /// The file this row selects, if any. Sections and folders select
        /// nothing — clicking them collapses instead.
        var file: ViewerDiffFile? {
            if case .file(let file) = kind { return file }
            return nil
        }

        /// The folder key this row toggles, if any.
        var folderKey: String? {
            if case .folder(_, let path) = kind { return path }
            return nil
        }
    }

    /// Build the rows for a file list.
    ///
    /// - `filter`: whitespace-separated terms, ALL of which must appear in a
    ///   file's path (case-insensitive). A non-empty filter switches the panel
    ///   to a flat list of matching files: when you are hunting for one file in
    ///   a thousand, the folder structure between you and it is in the way.
    /// - `collapsed`: folder keys the user has clicked shut.
    static func rows(
        for files: [ViewerDiffFile],
        filter: String = "",
        collapsed: Set<String> = []
    ) -> [Row] {
        let terms = filterTerms(filter)
        let matching = terms.isEmpty ? files : files.filter { matches($0, terms: terms) }
        guard !matching.isEmpty else { return [] }

        // Group into sections, preserving the order git status reads in.
        let order: [ViewerDiffFile.Origin] = [.committed, .staged, .unstaged, .untracked]
        var rows: [Row] = []
        for origin in order {
            let section = matching.filter { $0.origin == origin }
            guard !section.isEmpty else { continue }

            var depth = 0
            if let title = origin.sectionTitle {
                rows.append(Row(
                    id: "section:\(origin.rawValue)",
                    kind: .section("\(title) · \(section.count)"),
                    depth: 0))
                depth = 1
            }

            if terms.isEmpty {
                rows += folderRows(
                    for: section, origin: origin, depth: depth, collapsed: collapsed)
            } else {
                // Filtered: a flat hit list, ordered by path.
                rows += section
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                    .map { Row(id: $0.id, kind: .file($0), depth: depth) }
            }
        }
        return rows
    }

    /// Every file row in `rows`, in display order — what next/previous-file
    /// navigation steps through, so it follows exactly what the user can see.
    static func visibleFiles(in rows: [Row]) -> [ViewerDiffFile] {
        rows.compactMap(\.file)
    }

    /// Split a filter into terms. Multiple terms all have to match, which is
    /// what makes `viewer swift` a useful query rather than a literal one.
    static func filterTerms(_ filter: String) -> [String] {
        filter
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    static func matches(_ file: ViewerDiffFile, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        // The old path counts too: a rename is findable by either name.
        let haystack = (file.path + " " + (file.oldPath ?? "")).lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }

    // MARK: - Hierarchy

    /// A directory in the tree being built. Children keep insertion-agnostic
    /// order; they are sorted at flatten time.
    private final class Node {
        var folders: [String: Node] = [:]
        var files: [ViewerDiffFile] = []
    }

    private static func folderRows(
        for files: [ViewerDiffFile],
        origin: ViewerDiffFile.Origin,
        depth: Int,
        collapsed: Set<String>
    ) -> [Row] {
        let root = Node()
        for file in files {
            var components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            components.removeLast()
            var node = root
            for component in components {
                if let existing = node.folders[component] {
                    node = existing
                } else {
                    let child = Node()
                    node.folders[component] = child
                    node = child
                }
            }
            node.files.append(file)
        }
        var rows: [Row] = []
        flatten(
            node: root, prefix: "", origin: origin, depth: depth,
            collapsed: collapsed, into: &rows)
        return rows
    }

    private static func flatten(
        node: Node,
        prefix: String,
        origin: ViewerDiffFile.Origin,
        depth: Int,
        collapsed: Set<String>,
        into rows: inout [Row]
    ) {
        // Folders before files, each alphabetized the way Finder would.
        for name in node.folders.keys.sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        }) {
            guard let child = node.folders[name] else { continue }

            // Collapse a chain of single-child directories into one row —
            // `macos/Sources/Features/Viewer` rather than four rows of
            // indentation carrying no information.
            var title = name
            var path = prefix.isEmpty ? name : prefix + "/" + name
            var current = child
            while current.files.isEmpty, current.folders.count == 1,
                  let (childName, grandchild) = current.folders.first {
                title += "/" + childName
                path += "/" + childName
                current = grandchild
            }

            let key = "\(origin.rawValue):\(path)"
            rows.append(Row(
                id: "folder:\(key)",
                kind: .folder(title: title, path: key),
                depth: depth))
            guard !collapsed.contains(key) else { continue }
            flatten(
                node: current, prefix: path, origin: origin, depth: depth + 1,
                collapsed: collapsed, into: &rows)
        }

        for file in node.files.sorted(by: {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }) {
            rows.append(Row(id: file.id, kind: .file(file), depth: depth))
        }
    }
}
