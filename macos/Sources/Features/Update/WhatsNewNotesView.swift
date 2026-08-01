import SwiftUI

/// The "What's new" area shown as the agent-update dialog's accessory view.
/// A fixed frame + internal ScrollView means the notes never resize the host
/// NSAlert. The scrollable content lives in `WhatsNewNotesContent` so it can be
/// laid out (and rendered) independently.
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

/// The notes body: new-since-last-version notes first, then the ones already
/// installed under a labelled rule. Fully offline — rendered from bundled JSON.
///
/// Three hosts share this view and they are not the same size: the What's New
/// window can afford a real release-notes layout, while the update popover and
/// the agent-restart alert's accessory are small by nature. `Density` is the
/// single knob between them — the structure is identical either way, so a fix
/// here lands in all three (and in both the Client and Agent tabs).
struct WhatsNewNotesContent: View {
    let newNotes: [VersionNotes]
    let installedNotes: [VersionNotes]
    var density: Density = .compact

    /// Introduces the releases the user is already running. Replaces the old
    /// disclosure group: the older notes are always visible below this rule.
    static let installedDividerLabel = "Changes already installed"

    var body: some View {
        let m = density.metrics
        VStack(alignment: .leading, spacing: m.releaseSpacing) {
            if m.showsHeading {
                // Only for hosts with no titlebar of their own to say it. In
                // the window this would just repeat "What's New in Ghoztty".
                Text("What’s new")
                    .font(.system(m.headingTextStyle))
            }

            if newNotes.isEmpty {
                Text("No new release notes since your last update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(newNotes, id: \.version) { versionBlock($0, m) }
            }

            if !installedNotes.isEmpty {
                labelledRule(Self.installedDividerLabel)
                ForEach(installedNotes, id: \.version) { versionBlock($0, m) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether a release's section titles carry information. Every shipped
    /// release has exactly one section whose title only restates the tab it is
    /// under ("Fork Changes" / "Session persistence"), so it is noise; a release
    /// that ever splits into several sections needs them to stay readable.
    static func showsSectionTitles(_ v: VersionNotes) -> Bool {
        v.sections.count > 1
    }

    /// A full-width rule with a centred label — rule, label, rule. `Divider`
    /// inside an `HStack` draws vertically, hence the `VStack` around each one.
    @ViewBuilder
    private func labelledRule(_ label: String) -> some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
    }

    @ViewBuilder
    private func versionBlock(_ v: VersionNotes, _ m: Density.Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.sectionSpacing) {
            // The version is the banner of its release block, not a footnote.
            Text(v.version)
                .font(.system(m.versionTextStyle, weight: m.versionWeight))
                .foregroundStyle(m.versionIsSecondary ? Color.secondary : Color.primary)

            ForEach(Array(v.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: m.itemSpacing) {
                    if Self.showsSectionTitles(v) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        itemRow(item, m)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ReleaseNote, _ m: Density.Metrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Sized off its own text style rather than the item's: at body size
            // the glyph is a speck next to the text it marks.
            Text("•")
                .font(.system(m.bulletTextStyle))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.title {
                    Text(Self.inline(title))
                        .font(.system(m.itemTextStyle, weight: .semibold))
                    Text(Self.inline(item.text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.inline(item.text))
                        .font(.system(m.itemTextStyle))
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

extension WhatsNewNotesContent {
    /// How much room the host gives the notes.
    enum Density {
        /// The update popover and the agent-restart alert accessory: a few
        /// hundred points tall, so the notes stay dense.
        case compact
        /// The What's New window: room for the notes to read as release notes.
        case spacious

        /// Typography and spacing, in one place so the two layouts can be
        /// compared (and tested) instead of being scattered through the view.
        struct Metrics {
            /// Whether to draw the in-content "What's new" heading.
            let showsHeading: Bool
            let headingTextStyle: Font.TextStyle
            let versionTextStyle: Font.TextStyle
            let versionWeight: Font.Weight
            let versionIsSecondary: Bool
            let bulletTextStyle: Font.TextStyle
            let itemTextStyle: Font.TextStyle
            /// Gap between one release block and the next.
            let releaseSpacing: CGFloat
            /// Gap between a release's version heading and its sections.
            let sectionSpacing: CGFloat
            /// Gap between the bullets within a section.
            let itemSpacing: CGFloat
        }

        var metrics: Metrics {
            switch self {
            case .compact:
                Metrics(
                    showsHeading: true,
                    headingTextStyle: .headline,
                    versionTextStyle: .caption,
                    versionWeight: .semibold,
                    versionIsSecondary: true,
                    bulletTextStyle: .title3,
                    itemTextStyle: .body,
                    releaseSpacing: 14,
                    sectionSpacing: 8,
                    itemSpacing: 6)
            case .spacious:
                Metrics(
                    showsHeading: false,
                    headingTextStyle: .headline,
                    versionTextStyle: .title,
                    versionWeight: .bold,
                    versionIsSecondary: false,
                    bulletTextStyle: .title,
                    itemTextStyle: .body,
                    releaseSpacing: 32,
                    sectionSpacing: 12,
                    itemSpacing: 14)
            }
        }
    }
}
