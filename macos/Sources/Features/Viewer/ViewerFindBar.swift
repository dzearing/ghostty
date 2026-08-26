import AppKit
import SwiftUI

/// What the page reported for the current find query.
///
/// A plain value rather than state smeared across the view, because the
/// interesting behavior is all in how it reads: a count is a lie if the
/// query has been emptied, and a *capped* count is a lie if it is printed
/// like an exact one.
struct ViewerFindResult: Equatable {
    /// Matches the page found, capped by find.js's `MAX_MATCHES`.
    var total: Int = 0
    /// 1-based position of the current match; 0 when there is none.
    var index: Int = 0
    /// The page stopped counting at the cap — `total` is a floor.
    var truncated: Bool = false
    /// What the page is NOT searching, in the page's own words (a diff pane
    /// holds one file's patch at a time; see `find.js` → `scopeNote`).
    var note: String?

    static let none = ViewerFindResult()

    init(total: Int = 0, index: Int = 0, truncated: Bool = false, note: String? = nil) {
        self.total = total
        self.index = index
        self.truncated = truncated
        self.note = note
    }

    /// Decode a `find` message from the page's script bridge. Every field is
    /// optional: the bridge is shared with the TOC, quoting, and the link
    /// menu, and a partial payload must degrade rather than throw the pane's
    /// find state away.
    init(payload: [String: Any]) {
        self.init(
            total: payload["total"] as? Int ?? 0,
            index: payload["index"] as? Int ?? 0,
            truncated: payload["truncated"] as? Bool ?? false,
            note: (payload["note"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The browser-style count — "3/17" — or nil when there is nothing to say.
    ///
    /// `hasQuery` is the FIELD's state, not this value's: a count left over
    /// from the query the user just deleted must disappear with it.
    func label(hasQuery: Bool) -> String? {
        guard hasQuery else { return nil }
        guard total > 0 else { return "No results" }
        // A capped scan knows only that there are AT LEAST this many; printing
        // "12/5000" would read as an exact count of a page nobody counted.
        return truncated ? "\(index)/\(total)+" : "\(index)/\(total)"
    }
}

/// The find-in-page bar: a glass card floating at the pane's top-trailing
/// corner, below whatever top chrome is currently showing.
///
/// A FLOATING card rather than a strip under the nav bar, deliberately. The
/// nav bar reserves its space and a markdown/code pane hides it until you
/// reach for it (see `chromeAlwaysVisible`); making find a second strip would
/// mean Cmd-F both pins the nav bar open AND adds a row under it, reflowing a
/// reading surface by ~80pt and scrolling the very text you are searching. The
/// card costs no layout, appears identically in every viewer mode, and is the
/// shape Chrome trained people to expect. The cost — it covers the document's
/// top-right corner — is paid back by scrolling matches to the middle of the
/// pane rather than the top (see find.js → `reveal`), so the card is never
/// over the match it just found.
struct ViewerFindBar: View {
    @ObservedObject var viewerView: ViewerView

    @FocusState private var queryFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Square edge of the card's buttons. Smaller than the nav bar's 24pt: the
    /// card is a transient overlay over content, not a permanent toolbar.
    private static let controlSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if let note = viewerView.findResult.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Find scope: \(note)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(GlassCard.shape)
        .modifier(GlassCardBackground(
            fill: GlassCard.fill(isLightBackground: colorScheme == .light)))
        // An OPAQUE base under the glass, for the same reason the side panel
        // card has one: this floats over the document, and body text showing
        // through the field you are typing into is unreadable.
        .background(GlassCard.shape.fill(
            SidePanelCard.documentBackground(for: colorScheme)))
        .padding(GlassCard.outerMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in page")
        .onAppear { queryFocused = true }
        .onChange(of: viewerView.findFocusRequest) { _ in queryFocused = true }
        .onChange(of: queryFocused) { viewerView.findFieldFocusChanged($0) }
    }

    private var row: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)

            TextField("Find", text: Binding(
                get: { viewerView.findQuery },
                set: { viewerView.setFindQuery($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($queryFocused)
                // Return/Shift-Return are consumed by the pane's key monitor
                // (see `fieldKeyAction`) so they step matches even though a
                // shifted Return is not a submit; this is the belt to that
                // braces for anything that reaches SwiftUI anyway.
                .onSubmit { viewerView.stepFind(1) }
                .frame(minWidth: 60)

            if let count = viewerView.findResult.label(
                hasQuery: !viewerView.findQuery.isEmpty) {
                Text(count)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(viewerView.findResult.total > 0 ? .secondary : .tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel("\(count) matches")
            }

            // Match stepping. Deliberately the same chevrons the nav bar uses
            // for next/previous CHANGE in a diff pane — they are the platform's
            // "step through a list" glyphs and swapping in a second pair would
            // read as a different KIND of action rather than a different list.
            // What keeps the two apart is where they are (a diff's change
            // stepper lives in the nav bar, beside the revspec) and what they
            // say (their labels are "match", not "change").
            stepButton(
                systemName: "chevron.up", delta: -1,
                label: "Previous match", shortcut: "⇧⏎")
            stepButton(
                systemName: "chevron.down", delta: 1,
                label: "Next match", shortcut: "⏎")

            Button(action: { viewerView.closeFind() }) {
                Image(systemName: "xmark")
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close find (Escape)")
            .accessibilityLabel("Close find")
        }
    }

    private func stepButton(
        systemName: String, delta: Int, label: String, shortcut: String
    ) -> some View {
        Button(action: { viewerView.stepFind(delta) }) {
            Image(systemName: systemName)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(viewerView.findResult.total == 0)
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
    }
}
