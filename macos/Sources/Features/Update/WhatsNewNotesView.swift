import SwiftUI

/// The "What's new" area shown as the agent-update dialog's accessory view.
/// A fixed frame + internal ScrollView means expanding the disclosure never
/// resizes the host NSAlert. The scrollable content lives in
/// `WhatsNewNotesContent` so it can be laid out (and rendered) independently.
struct WhatsNewNotesView: View {
    let newNotes: [VersionNotes]
    let installedNotes: [VersionNotes]

    /// The size the host NSHostingView is pinned to.
    static let preferredSize = NSSize(width: 420, height: 240)

    var body: some View {
        ScrollView {
            WhatsNewNotesContent(newNotes: newNotes, installedNotes: installedNotes)
                .padding(14)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }
}

/// The notes body: new-since-last-version notes always visible, older
/// ("already installed") notes behind a collapsed disclosure. Fully offline —
/// rendered from bundled JSON.
struct WhatsNewNotesContent: View {
    let newNotes: [VersionNotes]
    let installedNotes: [VersionNotes]

    @State private var showInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What’s new")
                .font(.headline)

            if newNotes.isEmpty {
                Text("No new release notes since your last update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(newNotes, id: \.version) { versionBlock($0) }
            }

            if !installedNotes.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showInstalled) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(installedNotes, id: \.version) { versionBlock($0) }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Show changes already installed")
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func versionBlock(_ v: VersionNotes) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(v.version)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(v.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        itemRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ReleaseNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.title {
                    Text(Self.inline(title)).font(.body.weight(.semibold))
                    Text(Self.inline(item.text)).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(Self.inline(item.text)).font(.body)
                }
            }
        }
    }

    /// Render inline markdown (bold, italic, `code`, links) natively via the
    /// system parser — offline, no external library. Falls back to the raw
    /// string if it isn't valid markdown.
    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
