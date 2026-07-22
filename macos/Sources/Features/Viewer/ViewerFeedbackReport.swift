import Foundation

/// Writes one feedback report into a worktree's `temp/feedback/new/` queue.
///
/// The queue is drained by an external watcher, one report at a time — this
/// side only produces. Pure logic (no AppKit, no UI state) so the whole
/// format and the write ordering are unit-testable.
///
/// ## Format: JSON
///
/// A report is a single JSON object, not markdown-with-frontmatter. The body
/// is free-form multi-line prose the user typed; a body containing a `---`
/// line or a line that looks like `key: value` breaks naive frontmatter
/// splitting, whereas JSON escapes newlines inside a string and has exactly
/// one parse path in every language. The body value still holds markdown, so
/// a watcher that prints `report["body"]` gets a readable document with
/// working image links.
///
/// ## Layout on disk — one self-contained folder per report
///
/// ```
/// <worktree>/temp/feedback/new/20260721T214512Z-a3f9c2/
///     report.json
///     images/image-1.png
/// ```
///
/// Everything for a submission lives together, so a report can be moved,
/// archived, or handed to an agent as one unit (`mv new/<stem> in-progress/`
/// is a single rename, and the report's image paths are folder-relative so
/// they survive it).
///
/// The queue lives under `temp/` because that name is already gitignored in
/// this repo and conventionally in others; a top-level `.feedback/` was not,
/// so every filed report showed up as untracked in `git status`.
enum ViewerFeedbackReport {
    /// Schema version of the emitted JSON. Bumped to 2 when reports moved
    /// into per-report folders and gained the full source/worktree context.
    static let schemaVersion = 2

    /// `temp/` is gitignored here and in most repos; a bare `.feedback/` was
    /// not, so filed reports dirtied `git status`.
    static let tempDirectoryName = "temp"
    static let queueDirectoryName = "feedback"
    static let newDirectoryName = "new"
    static let stagingDirectoryName = ".staging"
    static let reportFileName = "report.json"
    static let imagesDirectoryName = "images"

    /// Worktree-relative path of the queue reports land in, for display.
    static let queueRelativePath =
        "\(tempDirectoryName)/\(queueDirectoryName)/\(newDirectoryName)"

    /// The `temp/feedback` directory inside a worktree.
    static func feedbackDirectory(in worktree: URL) -> URL {
        worktree
            .appendingPathComponent(tempDirectoryName)
            .appendingPathComponent(queueDirectoryName)
    }

    /// One piece of the composed message, in document order.
    enum Segment: Equatable {
        case text(String)
        /// A pasted-image chip, identified by its stable display number.
        case image(number: Int)
        /// A passage quoted out of the page, rendered as a markdown blockquote.
        case quote(number: Int, text: String)
    }

    /// A quoted passage plus the references that let a reader locate it.
    struct Quote: Equatable {
        let number: Int
        let text: String
        var headingID: String?
        var headingText: String?
        var blockSelector: String?
        var blockText: String?
        var offsetInBlock: Int?
        var documentOffset: Int?
        var sourceLine: Int?
    }

    /// A pasted image, already encoded.
    struct Image: Equatable {
        let number: Int
        let png: Data
        var pixelWidth: Int = 0
        var pixelHeight: Int = 0
    }

    /// Everything known about WHAT the feedback is about. The point of a
    /// feedback report is that a downstream agent can act on it without asking
    /// follow-up questions, so this is deliberately generous: where the user
    /// was, what they had selected, and which revision they were looking at.
    struct Context {
        /// The location as displayed (URL or absolute file path).
        var source: String
        /// `"file"` or `"web"` — lets a reader branch without parsing `source`.
        var sourceKind: String
        /// Absolute path of the viewed file, when file-backed.
        var filePath: String?
        /// `filePath` relative to the worktree root — the form a coding agent
        /// actually wants ("macos/Sources/…", not "/Users/me/git/…").
        var relativePath: String?
        /// The page's own title (web) or the file name.
        var pageTitle: String?
        /// Text the user had SELECTED in the page when they hit send — the
        /// quote of what they were pointing at.
        var selection: String?
        /// The viewer pane's stable ghoztty id.
        var paneID: String?
        /// Pane size in points, e.g. "820x540" — tells a reader whether a
        /// layout complaint was at a narrow width.
        var viewport: String?
        /// Branch and commit of the worktree, so a report can be replayed
        /// against the exact revision the user saw.
        var branch: String?
        var commit: String?
        var appVersion: String?

        init(source: String, sourceKind: String) {
            self.source = source
            self.sourceKind = sourceKind
        }
    }

    /// What landed on disk.
    struct Written: Equatable {
        /// The report folder.
        let folderURL: URL
        /// The report JSON inside it.
        let reportURL: URL
        /// The images, in the order they were written.
        let imageURLs: [URL]
        /// The sortable folder name.
        let stem: String
    }

    enum WriteError: Error, Equatable {
        /// Nothing to file: no text and no images.
        case empty
        /// A chip in the text has no matching image (or vice versa).
        case danglingImageReference(number: Int)
    }

    // MARK: - Naming

    /// A sortable, collision-free stem: UTC timestamp to the second plus a
    /// short random suffix. Lexicographic order equals chronological order,
    /// which is what lets a watcher drain the queue oldest-first with a plain
    /// directory sort.
    static func makeStem(date: Date, suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(formatter.string(from: date))-\(suffix)"
    }

    /// Six hex characters. The timestamp already separates reports filed in
    /// different seconds; this only has to break ties within one second.
    static func randomSuffix() -> String {
        String(format: "%06x", Int.random(in: 0..<0x100_0000))
    }

    static func imageFileName(number: Int) -> String { "image-\(number).png" }

    /// An image's path relative to the report folder.
    static func imageRelativePath(number: Int) -> String {
        "\(imagesDirectoryName)/\(imageFileName(number: number))"
    }

    // MARK: - Body rendering

    /// Render the composed segments as markdown, with each chip replaced by a
    /// path reference to its image.
    ///
    /// The reference is a markdown image link whose alt text is the chip's own
    /// label, so a downstream reader gets a resolvable path without having to
    /// parse chip metadata — the whole point of rendering rather than
    /// serializing the attachment. Paths are relative to the report folder, so
    /// the body renders correctly in a markdown viewer opened in place.
    static func renderBody(segments: [Segment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text):
                return text
            case .image(let number):
                return "![Image #\(number)](\(imageRelativePath(number: number)))"
            case .quote(_, let text):
                // A real markdown blockquote, so the body reads correctly in
                // any viewer. The structured references for each quote live in
                // the report's `quotes` array, matched by identical text.
                let quoted = text
                    .trimmingCharacters(in: .newlines)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }
                    .joined(separator: "\n")
                return "\n" + quoted + "\n"
            }
        }.joined()
    }

    /// The plain text of the segments, chips excluded — used to decide
    /// whether a submission is empty.
    static func plainText(segments: [Segment]) -> String {
        segments.map { segment -> String in
            switch segment {
            case .text(let text): return text
            // A quote counts as content: quoting a passage and hitting send
            // with no prose is a legitimate report ("this bit is wrong").
            case .quote(_, let text): return text
            case .image: return ""
            }
        }.joined()
    }

    // MARK: - Staging (while a draft is being composed)

    /// Worktree-relative path of the staging area, shown in the composer so the
    /// user can see — and open — exactly where the draft they are writing lives.
    static let stagingRelativePath =
        "\(tempDirectoryName)/\(queueDirectoryName)/\(stagingDirectoryName)"

    /// The `.staging/<stem>` folder a single draft is assembled in before it is
    /// published into `new/`. The stem is stable for the draft's whole life, so
    /// the footer link, the files the user drops into the folder, and the
    /// eventual atomic publish all refer to one folder.
    static func stagingDirectory(in worktree: ViewerWorktree, stem: String) -> URL {
        feedbackDirectory(in: worktree.url)
            .appendingPathComponent(stagingDirectoryName)
            .appendingPathComponent(stem)
    }

    /// Create or refresh a draft's staging folder *in place*: (over)write
    /// `report.json` and the draft's own `images/`, while leaving every other
    /// file untouched — in particular the ones the user dragged into the folder
    /// through the footer link, which must ride along into the published report.
    ///
    /// Unlike `write`, this tolerates an empty draft: a work-in-progress folder
    /// legitimately has nothing typed in it yet. Returns the staging directory.
    @discardableResult
    static func stage(
        segments: [Segment],
        images: [Image],
        quotes: [Quote] = [],
        worktree: ViewerWorktree,
        context: Context,
        stem: String,
        date: Date = Date()
    ) throws -> URL {
        let fm = FileManager.default
        let stagingDir = stagingDirectory(in: worktree, stem: stem)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Drafts that get composed but never sent would otherwise leave their
        // folders here forever; sweep the stale ones whenever a draft touches
        // disk — never this draft's folder, nor a recent one another pane may
        // still be composing into.
        pruneStaleStaging(in: worktree, keeping: stem, now: date)

        let sorted = images.sorted { $0.number < $1.number }
        if !sorted.isEmpty {
            let imagesDir = stagingDir.appendingPathComponent(imagesDirectoryName)
            try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            for image in sorted {
                try image.png.write(
                    to: imagesDir.appendingPathComponent(imageFileName(number: image.number)))
            }
        }

        let payload = makePayload(
            segments: segments, images: sorted, quotes: quotes,
            context: context, worktree: worktree, stem: stem, date: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload)
            .write(to: stagingDir.appendingPathComponent(reportFileName))

        return stagingDir
    }

    /// Remove staging folders left by drafts that were never sent, so the
    /// staging area doesn't accumulate abandoned work. Only folders whose last
    /// modification is older than `olderThan` are removed, and never `keeping`,
    /// so a draft being composed right now — in this pane or another — is safe.
    /// Returns the names removed. `olderThan`/`now` are injectable for testing.
    @discardableResult
    static func pruneStaleStaging(
        in worktree: ViewerWorktree,
        keeping stem: String,
        olderThan: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) -> [String] {
        let fm = FileManager.default
        let root = feedbackDirectory(in: worktree.url)
            .appendingPathComponent(stagingDirectoryName)
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var removed: [String] = []
        for entry in entries where entry.lastPathComponent != stem {
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantFuture
            guard now.timeIntervalSince(modified) > olderThan else { continue }
            if (try? fm.removeItem(at: entry)) != nil {
                removed.append(entry.lastPathComponent)
            }
        }
        return removed
    }

    // MARK: - Writing

    /// Write a report folder into `worktree/temp/feedback/new/`.
    ///
    /// The whole folder is built in a sibling staging directory and then moved
    /// into place with a single `rename`, which is atomic — a watcher scanning
    /// `new/` sees either nothing or a complete report folder with every image
    /// already present. Staging under `temp/feedback/` (not `/tmp`) keeps it on
    /// the same filesystem, since a cross-device rename fails with EXDEV and
    /// would silently degrade to a non-atomic copy.
    ///
    /// When `stem` is supplied the draft's own staging folder is reused and
    /// published as-is, so any files the user dropped into it while composing
    /// (see `stage`) are carried along. When it is nil a fresh one is minted
    /// from `date`/`suffix` — both injectable purely so tests can assert exact
    /// names.
    @discardableResult
    static func write(
        segments: [Segment],
        images: [Image],
        quotes: [Quote] = [],
        worktree: ViewerWorktree,
        context: Context,
        date: Date = Date(),
        suffix: String = randomSuffix(),
        stem explicitStem: String? = nil
    ) throws -> Written {
        let text = plainText(segments: segments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { throw WriteError.empty }

        // A chip whose image is gone would serialize a path to a file that
        // never gets written. That can only happen through a bug in the
        // composer's chip⇄image reconciliation, so fail loudly rather than
        // filing a report with a broken link.
        let available = Set(images.map(\.number))
        for segment in segments {
            if case .image(let number) = segment, !available.contains(number) {
                throw WriteError.danglingImageReference(number: number)
            }
        }

        let stem = explicitStem ?? makeStem(date: date, suffix: suffix)
        let fm = FileManager.default
        let queueDir = feedbackDirectory(in: worktree.url)
            .appendingPathComponent(newDirectoryName)
        try fm.createDirectory(at: queueDir, withIntermediateDirectories: true)

        // Build/refresh the draft folder (preserving any dragged-in files),
        // then publish it with a single atomic move.
        let stagingDir = try stage(
            segments: segments, images: images, quotes: quotes,
            worktree: worktree, context: context, stem: stem, date: date)

        let finalDir = queueDir.appendingPathComponent(stem)
        guard rename(
            (stagingDir as NSURL).fileSystemRepresentation,
            (finalDir as NSURL).fileSystemRepresentation) == 0
        else {
            let code = errno
            try? fm.removeItem(at: stagingDir)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        let sorted = images.sorted { $0.number < $1.number }
        return Written(
            folderURL: finalDir,
            reportURL: finalDir.appendingPathComponent(reportFileName),
            imageURLs: sorted.map {
                finalDir
                    .appendingPathComponent(imagesDirectoryName)
                    .appendingPathComponent(imageFileName(number: $0.number))
            },
            stem: stem)
    }

    /// Assemble the JSON payload for a report. Shared by `stage` (the
    /// work-in-progress folder) and the final publish so the two never drift.
    /// `images` is expected already sorted by number.
    private static func makePayload(
        segments: [Segment],
        images: [Image],
        quotes: [Quote],
        context: Context,
        worktree: ViewerWorktree,
        stem: String,
        date: Date
    ) -> Payload {
        Payload(
            version: schemaVersion,
            id: stem,
            created: ISO8601DateFormatter.feedbackFormatter.string(from: date),
            body: renderBody(segments: segments),
            source: PayloadSource(
                location: context.source,
                kind: context.sourceKind,
                filePath: context.filePath,
                relativePath: context.relativePath,
                pageTitle: context.pageTitle,
                selection: context.selection,
                paneID: context.paneID,
                viewport: context.viewport),
            worktree: PayloadWorktree(
                path: worktree.path,
                name: worktree.name,
                branch: context.branch,
                commit: context.commit),
            app: PayloadApp(name: "Ghoztty", version: context.appVersion),
            quotes: quotes.map {
                PayloadQuote(
                    number: $0.number, text: $0.text,
                    headingId: $0.headingID, headingText: $0.headingText,
                    blockSelector: $0.blockSelector, blockText: $0.blockText,
                    offsetInBlock: $0.offsetInBlock,
                    documentOffset: $0.documentOffset,
                    sourceLine: $0.sourceLine)
            },
            images: images.map {
                PayloadImage(
                    number: $0.number,
                    path: imageRelativePath(number: $0.number),
                    pixelWidth: $0.pixelWidth > 0 ? $0.pixelWidth : nil,
                    pixelHeight: $0.pixelHeight > 0 ? $0.pixelHeight : nil,
                    bytes: $0.png.count)
            })
    }

    // MARK: - Payload

    private struct PayloadImage: Codable {
        let number: Int
        let path: String
        let pixelWidth: Int?
        let pixelHeight: Int?
        let bytes: Int
    }

    private struct PayloadSource: Codable {
        let location: String
        let kind: String
        let filePath: String?
        let relativePath: String?
        let pageTitle: String?
        let selection: String?
        let paneID: String?
        let viewport: String?
    }

    private struct PayloadWorktree: Codable {
        let path: String
        let name: String
        let branch: String?
        let commit: String?
    }

    private struct PayloadQuote: Codable {
        let number: Int
        let text: String
        let headingId: String?
        let headingText: String?
        let blockSelector: String?
        let blockText: String?
        let offsetInBlock: Int?
        let documentOffset: Int?
        let sourceLine: Int?
    }

    private struct PayloadApp: Codable {
        let name: String
        let version: String?
    }

    private struct Payload: Codable {
        let version: Int
        let id: String
        let created: String
        let body: String
        let source: PayloadSource
        let worktree: PayloadWorktree
        let app: PayloadApp
        let quotes: [PayloadQuote]
        let images: [PayloadImage]
    }
}

private extension ISO8601DateFormatter {
    static let feedbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
