import AppKit
import SwiftUI

/// The changed-files card for a diff viewer pane.
///
/// The table of contents' twin: same card, same pinned header, same row
/// metrics, same selection pill, same gutter/overlay switch and drag-to-resize
/// (all of it from `ViewerSidePanel` / `ViewerView`). What it adds is the two
/// things a file list needs and a heading list does not — a filter field pinned
/// under the header so it stays put while rows scroll, and a folder hierarchy
/// with each file's status and line counts.
struct ViewerDiffPanel: View {
    @ObservedObject var viewerView: ViewerView

    let width: CGFloat
    let maxHeight: CGFloat

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hoveredID: String?
    @FocusState private var filterFocused: Bool

    var body: some View {
        list
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .modifier(SidePanelCard(
                width: width, maxHeight: maxHeight,
                accessibilityLabel: "Changed files"))
    }

    // MARK: - Header

    /// Title and filter in ONE pinned header, so the field never scrolls away
    /// from the list it filters. Both sit on the same glass backdrop the TOC's
    /// title bar uses, and rows pass beneath the whole thing.
    private var header: some View {
        SidePanelHeader {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SidePanelCaption(text: "Files")
                    Spacer(minLength: 4)
                    Text(viewerView.diffSummaryText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                filterField
            }
            .padding(.horizontal, SidePanelRow.labelInset)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Filter files", text: Binding(
                get: { viewerView.diffFilter },
                set: { viewerView.setDiffFilter($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($filterFocused)
                // Return jumps to the first match — the "type a few letters and
                // go" path that makes this a jump-to-file field rather than
                // just a way to shorten the list.
                .onSubmit { viewerView.openFirstFilteredFile() }
            if !viewerView.diffFilter.isEmpty {
                Button(action: { viewerView.setDiffFilter("") }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        // Same yield the address field performs: a terminal surface sharing
        // this window keeps its `focused` flag set even while this field holds
        // keyboard focus, and its performKeyEquivalent would eat Cmd-C/V before
        // the field editor ever saw them.
        .onChange(of: filterFocused) { viewerView.diffFilterFocusChanged($0) }
    }

    // MARK: - Rows

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if viewerView.diffRows.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewerView.diffRows) { row in
                            self.row(row)
                        }
                    }
                }
                .padding(.horizontal, SidePanelRow.fillInset)
                .padding(.vertical, SidePanelRow.fillInset)
            }
            .onChange(of: viewerView.activeDiffFileID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
            }
        }
    }

    private var emptyState: some View {
        Text(viewerView.diffFilter.isEmpty ? "No changes" : "No matching files")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, SidePanelRow.textInset)
            .padding(.vertical, SidePanelRow.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ row: ViewerDiffTree.Row) -> some View {
        switch row.kind {
        case .section(let title):
            sectionRow(title)
        case .folder(let title, let path):
            folderRow(row: row, title: title, key: path)
        case .file(let file):
            fileRow(row: row, file: file)
        }
    }

    private func sectionRow(_ title: String) -> some View {
        SidePanelCaption(text: title)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, SidePanelRow.textInset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderRow(row: ViewerDiffTree.Row, title: String, key: String) -> some View {
        let isCollapsed = viewerView.isDiffFolderCollapsed(key)
        let isHovered = row.id == hoveredID
        return Button(action: { viewerView.toggleDiffFolder(key) }) {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                Image(systemName: "folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.leading, SidePanelRow.textInset + indent(row))
            .padding(.trailing, SidePanelRow.textInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidePanelRow.fill(
                isActive: false, isHovered: isHovered, isEmphasized: isEmphasized))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover(row.id, $0) }
        .id(row.id)
        .help(title)
    }

    private func fileRow(row: ViewerDiffTree.Row, file: ViewerDiffFile) -> some View {
        let isActive = file.id == viewerView.activeDiffFileID
        let isHovered = row.id == hoveredID
        let foreground = SidePanelRow.foreground(
            isActive: isActive, isEmphasized: isEmphasized)
        return Button(action: { viewerView.selectDiffFile(file) }) {
            HStack(spacing: 6) {
                statusBadge(file.status, isActive: isActive)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.name)
                        .lineLimit(1)
                        // Head, not middle: a card this narrow truncates a lot
                        // of names, and `Viewer…eaf.swift` identifies nothing
                        // while `…SplitLeaf.swift` keeps both the
                        // distinguishing tail and the extension.
                        .truncationMode(.head)
                        .foregroundStyle(foreground)
                        .font(.system(size: 12))
                    // Filtering flattens the tree, so the directory has to come
                    // back on the row itself — otherwise two same-named files
                    // in different folders are indistinguishable hits.
                    if viewerView.isDiffFiltered, let parent = Self.parentPath(of: file.path) {
                        Text(parent)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .font(.system(size: 9.5))
                            .foregroundStyle(isActive ? foreground : AnyShapeStyle(.tertiary))
                            .opacity(isActive ? 0.75 : 1)
                    }
                }
                Spacer(minLength: 4)
                counts(file, isActive: isActive)
            }
            .padding(.vertical, 4)
            .padding(.leading, SidePanelRow.textInset + indent(row))
            .padding(.trailing, SidePanelRow.textInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidePanelRow.fill(
                isActive: isActive, isHovered: isHovered, isEmphasized: isEmphasized))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover(row.id, $0) }
        .id(file.id)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    /// The one-letter git status, in git's own alphabet so the pane reads like
    /// the CLI the user already knows.
    private func statusBadge(_ status: ViewerDiffFile.Status, isActive: Bool) -> some View {
        Text(status.letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(isActive
                ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                : AnyShapeStyle(Self.color(for: status)))
            .frame(width: 13, height: 13)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isActive
                        ? Color.white.opacity(0.22)
                        : Self.color(for: status).opacity(0.14)))
    }

    @ViewBuilder
    private func counts(_ file: ViewerDiffFile, isActive: Bool) -> some View {
        if file.isBinary {
            Text("bin")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
        } else {
            HStack(spacing: 3) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .foregroundStyle(isActive
                            ? AnyShapeStyle(.white.opacity(0.9))
                            : AnyShapeStyle(Self.addedColor))
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)")
                        .foregroundStyle(isActive
                            ? AnyShapeStyle(.white.opacity(0.9))
                            : AnyShapeStyle(Self.removedColor))
                }
            }
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        }
    }

    // MARK: - Helpers

    private func indent(_ row: ViewerDiffTree.Row) -> CGFloat {
        CGFloat(row.depth) * SidePanelRow.indentStep
    }

    private func hover(_ id: String, _ hovering: Bool) {
        hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID)
    }

    private var isEmphasized: Bool { controlActiveState == .key }

    static func parentPath(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// Diff colors, shared with the rendered page (see diff.css) so the badge
    /// beside a file and the lines inside it agree about what green means.
    static let addedColor = Color(red: 0.13, green: 0.55, blue: 0.24)
    static let removedColor = Color(red: 0.81, green: 0.21, blue: 0.24)

    static func color(for status: ViewerDiffFile.Status) -> Color {
        switch status {
        case .added: return addedColor
        case .deleted: return removedColor
        case .renamed, .copied: return Color(red: 0.22, green: 0.45, blue: 0.85)
        case .modified, .typeChanged: return Color(red: 0.72, green: 0.50, blue: 0.05)
        case .unmerged, .unknown: return Color.secondary
        }
    }
}
