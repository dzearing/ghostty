import Foundation

/// Writes one feedback report into a worktree's `.feedback/new/` queue.
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
/// ## Layout on disk
///
/// ```
/// <worktree>/.feedback/new/20260721T214512Z-a3f9c2.json
/// <worktree>/.feedback/new/20260721T214512Z-a3f9c2/image-1.png
/// ```
///
/// Image paths inside the report are relative to the report file's own
/// directory, so the queue can be moved or archived wholesale.
enum ViewerFeedbackReport {
    /// Schema version of the emitted JSON. Bump on any incompatible change so
    /// a watcher can refuse what it doesn't understand.
    static let schemaVersion = 1

    static let queueDirectoryName = ".feedback"
    static let newDirectoryName = "new"

    /// One piece of the composed message, in document order.
    enum Segment: Equatable {
        case text(String)
        /// A pasted-image chip, identified by its stable display number.
        case image(number: Int)
    }

    /// A pasted image, already encoded.
    struct Image: Equatable {
        let number: Int
        let png: Data
    }

    /// What landed on disk.
    struct Written: Equatable {
        /// The report JSON.
        let reportURL: URL
        /// The images, in the order they were written.
        let imageURLs: [URL]
        /// The sortable stem shared by the report and its image directory.
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

    // MARK: - Body rendering

    /// Render the composed segments as markdown, with each chip replaced by a
    /// path reference to its image.
    ///
    /// The reference is a markdown image link whose alt text is the chip's own
    /// label, so a downstream reader gets a resolvable path without having to
    /// parse chip metadata — the whole point of rendering rather than
    /// serializing the attachment.
    static func renderBody(segments: [Segment], stem: String) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text):
                return text
            case .image(let number):
                let path = "\(stem)/\(imageFileName(number: number))"
                return "![Image #\(number)](\(path))"
            }
        }.joined()
    }

    /// The plain text of the segments, chips excluded — used to decide
    /// whether a submission is empty.
    static func plainText(segments: [Segment]) -> String {
        segments.map { segment -> String in
            if case .text(let text) = segment { return text }
            return ""
        }.joined()
    }

    // MARK: - Writing

    /// Write a report (and its images) into `worktree/.feedback/new/`.
    ///
    /// Ordering is what makes this safe for a watcher: images land first —
    /// unobservable, because nothing references them yet — and the report is
    /// then written to a dot-prefixed temp file in the SAME directory and
    /// `rename`d onto its final name. `rename(2)` guarantees the destination
    /// appears whole or not at all, so a watcher globbing `*.json` can never
    /// read a half-written report, nor a report whose images are still being
    /// written.
    ///
    /// `date` and `suffix` are injectable purely so tests can assert exact
    /// file names.
    @discardableResult
    static func write(
        segments: [Segment],
        images: [Image],
        worktree: ViewerWorktree,
        source: String,
        date: Date = Date(),
        suffix: String = randomSuffix()
    ) throws -> Written {
        let text = plainText(segments: segments).trimmingCharacters(in: .whitespacesAndNewlines)
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

        let stem = makeStem(date: date, suffix: suffix)
        let queueDir = worktree.url
            .appendingPathComponent(queueDirectoryName)
            .appendingPathComponent(newDirectoryName)
        try FileManager.default.createDirectory(
            at: queueDir, withIntermediateDirectories: true)

        // 1. Images. Nothing points at them yet, so a watcher that wakes up
        // mid-write sees only an inert directory.
        var imageURLs: [URL] = []
        if !images.isEmpty {
            let imageDir = queueDir.appendingPathComponent(stem)
            try FileManager.default.createDirectory(
                at: imageDir, withIntermediateDirectories: true)
            for image in images.sorted(by: { $0.number < $1.number }) {
                let url = imageDir.appendingPathComponent(
                    imageFileName(number: image.number))
                try image.png.write(to: url, options: .atomic)
                imageURLs.append(url)
            }
        }

        // 2. The report, temp-then-rename inside the queue directory (same
        // directory ⇒ same filesystem ⇒ the rename is atomic; a cross-device
        // rename would fail with EXDEV and silently degrade to a copy).
        let payload = Payload(
            version: schemaVersion,
            id: stem,
            created: ISO8601DateFormatter.feedbackFormatter.string(from: date),
            source: source,
            worktree: worktree.path,
            body: renderBody(segments: segments, stem: stem),
            images: images
                .sorted(by: { $0.number < $1.number })
                .map { PayloadImage(number: $0.number, path: "\(stem)/\(imageFileName(number: $0.number))") })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)

        let reportURL = queueDir.appendingPathComponent("\(stem).json")
        // Dot-prefixed AND .tmp-suffixed: invisible to a `*.json` glob and to
        // a plain directory listing, so neither kind of watcher trips on it.
        let tempURL = queueDir.appendingPathComponent(".\(stem).json.tmp")
        try data.write(to: tempURL, options: .atomic)
        guard rename(
            (tempURL as NSURL).fileSystemRepresentation,
            (reportURL as NSURL).fileSystemRepresentation) == 0
        else {
            let code = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        return Written(reportURL: reportURL, imageURLs: imageURLs, stem: stem)
    }

    // MARK: - Payload

    private struct PayloadImage: Codable {
        let number: Int
        let path: String
    }

    private struct Payload: Codable {
        let version: Int
        let id: String
        let created: String
        let source: String
        let worktree: String
        let body: String
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
