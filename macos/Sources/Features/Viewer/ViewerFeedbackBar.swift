import AppKit
import SwiftUI

/// The feedback composer toolbar: slides in below the viewer's navigation bar
/// and above the content. A multi-line rich input on the left, a send button
/// on the right, a thumbnail carousel beneath, and a footer naming the
/// worktree the report will land in.
struct ViewerFeedbackBar: View {
    @ObservedObject var viewerView: ViewerView
    @ObservedObject var model: ViewerFeedbackModel

    /// Height of the text input. Roughly five lines — enough to write a real
    /// report in without the toolbar eating the pane it is describing.
    private static let inputHeight: CGFloat = 92
    private static let thumbnailHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                ViewerFeedbackTextEditor(
                    model: model,
                    onSend: { viewerView.sendFeedback() },
                    onEscape: { viewerView.setFeedbackOpen(false) })
                    .frame(height: Self.inputHeight)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Feedback message")

                Button(action: { viewerView.sendFeedback() }) {
                    Label("Send", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isEmpty)
                .help("Send feedback (⌘↩)")
            }

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
            Text("⌘↩ send · ⎋ close")
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

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

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
        textView.textContainerInset = NSSize(width: 6, height: 6)
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
        weak var textView: ViewerFeedbackTextView?
        var lastRevealToken = 0

        init(model: ViewerFeedbackModel) {
            self.model = model
        }

        /// Every edit re-derives the carousel from the text. A chip deleted
        /// with one Backspace loses its thumbnail here, with no separate
        /// delete path to keep in sync.
        func textDidChange(_ notification: Notification) {
            model.syncAttachments()
            // The user is composing again — clear a stale "filed" banner so
            // it can never be mistaken for confirmation of the NEW report.
            if model.status != nil { model.status = nil }
        }
    }
}
