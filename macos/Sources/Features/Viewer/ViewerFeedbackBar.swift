import AppKit
import SwiftUI

/// The feedback composer toolbar: slides in below the viewer's navigation bar
/// and above the content.
///
/// The input is a **pill** that grows with its content, with the snapshot and
/// send controls as circular buttons sitting INSIDE it on the trailing edge —
/// a chat composer, not a form. A thumbnail carousel and a destination footer
/// sit beneath.
struct ViewerFeedbackBar: View {
    @ObservedObject var viewerView: ViewerView
    @ObservedObject var model: ViewerFeedbackModel

    /// Live content height of the text view, so the pill grows as the report
    /// is written instead of committing a tall box up front.
    @State private var contentHeight: CGFloat = ViewerFeedbackBar.minInputHeight

    /// One line of text plus the pill's own padding. At this height the shape
    /// is a true capsule — the composer starts as a single-line pill.
    static let minInputHeight: CGFloat = 22
    /// Roughly six lines; past this the text view scrolls rather than eating
    /// the pane the feedback is about.
    static let maxInputHeight: CGFloat = 116
    private static let thumbnailHeight: CGFloat = 52
    /// Diameter of the in-pill circular buttons.
    static let actionButtonSize: CGFloat = 24
    static let pillVerticalPadding: CGFloat = 5

    /// The pill's height with the input collapsed to a single line. The
    /// circular actions are the taller element at that point, so they set it.
    static var collapsedPillHeight: CGFloat {
        max(minInputHeight, actionButtonSize) + pillVerticalPadding * 2
    }

    /// Corner radius, FIXED at half the collapsed height.
    ///
    /// Deliberately not a `Capsule`: a capsule recomputes its radius as
    /// height/2 at every height, so a pill that grows to six lines stops being
    /// a pill and becomes an oval. Pinning the radius to the one-line value
    /// keeps the corners exactly as round as they start and lets the straight
    /// sides lengthen instead — a true capsule at one line, the same corner
    /// roundness beyond it.
    static var pillCornerRadius: CGFloat { collapsedPillHeight / 2 }

    private var inputHeight: CGFloat {
        min(max(contentHeight, Self.minInputHeight), Self.maxInputHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            composerPill

            if !model.attachments.isEmpty {
                carousel
            }

            footer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .modifier(ChromeBarBackground())
        .onHover { viewerView.holdChrome($0) }
    }

    /// The pill: text on the left, circular actions pinned bottom-right inside
    /// it. Bottom-aligned so the buttons stay put as the pill grows upward.
    private var composerPill: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ViewerFeedbackTextEditor(
                model: model,
                onSend: { viewerView.sendFeedback() },
                onEscape: { viewerView.setFeedbackOpen(false) },
                onHeightChange: { contentHeight = $0 })
                .frame(height: inputHeight)
                .accessibilityLabel("Feedback message")

            snapshotButton
            sendButton
        }
        .padding(.leading, 12)
        .padding(.trailing, Self.pillVerticalPadding)
        .padding(.vertical, Self.pillVerticalPadding)
        .background(pillShape.fill(.quaternary.opacity(0.5)))
        .overlay(pillShape.strokeBorder(.quaternary, lineWidth: 1))
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.pillCornerRadius, style: .continuous)
    }

    /// Grab a region of the screen without leaving the composer — the whole
    /// point of feedback about a UI is pointing at the UI.
    private var snapshotButton: some View {
        Button(action: { viewerView.captureFeedbackScreenshot() }) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .background(Circle().fill(.quaternary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Add a screenshot of the screen (⇧⌘S)")
        .accessibilityLabel("Add screenshot")
    }

    private var sendButton: some View {
        Button(action: { viewerView.sendFeedback() }) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .frame(width: Self.actionButtonSize, height: Self.actionButtonSize)
                .background(Circle().fill(model.isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white))
        .disabled(model.isEmpty)
        .help("Send feedback (⌘↩)")
        .accessibilityLabel("Send feedback")
    }

    /// One thumbnail per pasted image, labeled with the same stable number as
    /// its chip. Selecting one reveals and selects its chip in the text.
    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(model.attachments) { attachment in
                        thumbnail(attachment)
                            .id(attachment.id)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 2)
            }
            .frame(height: Self.thumbnailHeight + 18)
            // A chip clicked in the text scrolls its thumbnail into view.
            .onChange(of: model.scrollCarouselToken) { _ in
                guard let id = model.selectedChipID else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func thumbnail(_ attachment: ViewerFeedbackModel.Attachment) -> some View {
        let selected = model.selectedChipID == attachment.id
        return VStack(spacing: 3) {
            Image(nsImage: attachment.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.thumbnailHeight * 1.4, height: Self.thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            lineWidth: selected ? 2 : 1))
            Text("[Image #\(attachment.number)]")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.thumbnailClicked(attachment.id) }
        .help("Reveal [Image #\(attachment.number)] in the message")
        .accessibilityLabel("Image \(attachment.number)")
    }

    /// Where the report lands, plus the send/close hints — and, after a send,
    /// the confirmation. Feedback going quietly to the wrong repo is the main
    /// failure mode, so the destination is always on screen while composing.
    private var footer: some View {
        HStack(spacing: 6) {
            switch model.status {
            case .filed(let name):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Filed \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case nil:
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let worktree = viewerView.worktree {
                    Text(verbatim: "\(worktree.name)/.feedback/new")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(worktree.path)
                }
            }
            Spacer()
            Text("⌘↩ send · ⇧⌘S shot · ⎋ close")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Text editor bridge

/// Hosts the composer's `NSTextView`.
///
/// AppKit rather than SwiftUI's `TextEditor` because the chips have to be
/// attachment-backed runs in an attributed string — that is the only way an
/// inline `[Image #N]` is a single atomic character rather than eleven
/// editable ones, and `TextEditor` cannot express it.
struct ViewerFeedbackTextEditor: NSViewRepresentable {
    @ObservedObject var model: ViewerFeedbackModel
    let onSend: () -> Void
    let onEscape: () -> Void
    /// Reports the laid-out text height so the pill can grow with content.
    var onHeightChange: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // The model's storage is reused across mounts, so any layout manager
        // from a previous mount has to go — an NSTextStorage keeps every
        // layout manager ever added, and a stale one would keep laying out
        // (and retaining) a dead text view.
        let storage = model.textStorage
        for manager in storage.layoutManagers { storage.removeLayoutManager(manager) }

        // An explicit TextKit 1 stack. `NSTextAttachmentCell` — which is what
        // draws the chips in the view's live appearance — is a TextKit 1 API,
        // and a programmatically created NSTextView would otherwise come up
        // on TextKit 2, where the cell is never consulted.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = ViewerFeedbackTextView(frame: .zero, textContainer: container)
        textView.model = model
        textView.onSend = onSend
        textView.onEscape = onEscape
        textView.onChipClick = { [weak model] id in model?.chipClicked(id) }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        // Required for attachments to survive in the storage at all; the
        // paste override keeps the *typed* content plain regardless.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // The pill supplies the padding; insetting again would double it.
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.typingAttributes = ViewerFeedbackModel.typingAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onSend = onSend
        textView.onEscape = onEscape

        // A thumbnail was clicked: select its chip and scroll it into view.
        if context.coordinator.lastRevealToken != model.revealChipToken {
            context.coordinator.lastRevealToken = model.revealChipToken
            if let id = model.selectedChipID, let range = model.range(ofChip: id) {
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // Same reasoning as `makeNSView`: leave the storage with no layout
        // manager pointing at a view that is going away.
        guard let textView = coordinator.textView, let manager = textView.layoutManager else { return }
        textView.textStorage?.removeLayoutManager(manager)
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ViewerFeedbackModel
        let onHeightChange: ((CGFloat) -> Void)?
        weak var textView: ViewerFeedbackTextView?
        var lastRevealToken = 0
        private var lastReportedHeight: CGFloat = -1

        init(model: ViewerFeedbackModel, onHeightChange: ((CGFloat) -> Void)?) {
            self.model = model
            self.onHeightChange = onHeightChange
        }

        /// Every edit re-derives the carousel from the text. A chip deleted
        /// with one Backspace loses its thumbnail here, with no separate
        /// delete path to keep in sync.
        func textDidChange(_ notification: Notification) {
            model.syncAttachments()
            // The user is composing again — clear a stale "filed" banner so
            // it can never be mistaken for confirmation of the NEW report.
            if model.status != nil { model.status = nil }
            reportHeight()
        }

        /// Push the laid-out text height up so the pill can size to content.
        /// Only on change: this runs from layout, and feeding SwiftUI an
        /// identical value every pass re-enters layout forever.
        func reportHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let height = ceil(used + textView.textContainerInset.height * 2)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            onHeightChange?(height)
        }
    }
}
