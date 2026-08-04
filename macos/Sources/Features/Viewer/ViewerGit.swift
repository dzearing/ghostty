import Foundation
import OSLog

/// Blocking subprocess plumbing shared by everything in the viewer that shells
/// out (worktree provenance, and the diff loader below).
///
/// Absolute paths only — never a PATH search: these run against whatever
/// directory the pane happens to be showing, and resolving a tool name through
/// an inherited PATH would let a directory decide which binary we execute.
enum ViewerProcess {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty",
        category: "ViewerProcess")

    static let gitPaths = [
        "/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git",
    ]
    static let lsofPaths = ["/usr/sbin/lsof", "/usr/bin/lsof"]

    /// Run the first of `tool` that exists and return its stdout, or nil on a
    /// non-zero exit / launch failure / timeout. Blocking — never call this on
    /// the main thread.
    ///
    /// stdout is read to EOF BEFORE waiting for exit: a diff big enough to fill
    /// the pipe buffer would otherwise block the child forever while we block
    /// waiting for it, which is a deadlock that only shows up on large repos.
    static func run(
        tool: [String],
        arguments: [String],
        timeout: TimeInterval = 15
    ) -> String? {
        guard let executable = tool.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            logger.warning("no executable found among \(tool, privacy: .public)")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        // A git hook or config that reads the terminal would hang forever;
        // this makes any such prompt fail immediately instead. Optional locks
        // off so a read-only diff never fights a concurrent `git` in a pane.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env

        do {
            try process.run()
        } catch {
            logger.warning("failed to launch \(executable, privacy: .public): \(error)")
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Everything a diff pane asks git for.
///
/// Split in two on purpose, because that split is what makes a
/// thousand-file diff open instantly: the FILE LIST is computed eagerly (a
/// couple of `--numstat`/`--name-status` invocations, cheap even on a huge
/// range) and each file's PATCH is fetched only when its row is clicked.
///
/// Everything here is blocking process I/O — call it from
/// `ViewerDiffLoader`, which moves it off the main thread.
enum ViewerGit {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty",
        category: "ViewerGit")

    /// An untracked file bigger than this is summarized rather than read: it
    /// is new content, so "the diff" would be the whole file.
    static let untrackedByteCap = 2 * 1024 * 1024

    static func run(repo: String, _ arguments: [String]) -> String? {
        ViewerProcess.run(
            tool: ViewerProcess.gitPaths,
            arguments: ["-C", repo, "-c", "core.quotepath=false"] + arguments)
    }

    /// The base a bare `git-diff:` compares the current branch against.
    ///
    /// Ordered by what a human means by "the mainline": the local default
    /// branch if there is one, then the remote's. Returns nil in a repo with
    /// none of them, so the caller can say so instead of diffing against a
    /// ref that doesn't exist.
    static func defaultBase(repo: String) -> String? {
        // `origin/HEAD` names the remote's default branch and is the most
        // accurate answer when it is configured, but plenty of clones never
        // set it — hence the explicit fallbacks.
        if let symbolic = run(repo: repo, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           symbolic.hasPrefix("refs/remotes/") {
            return String(symbolic.dropFirst("refs/remotes/".count))
        }
        for candidate in ["main", "master", "origin/main", "origin/master"] {
            if run(repo: repo, ["rev-parse", "--verify", "--quiet", candidate]) != nil {
                return candidate
            }
        }
        return nil
    }

    // MARK: - File list

    /// The file list for a spec, or nil when git could not answer at all
    /// (a bad revspec, a directory that is not a repo).
    static func fileList(spec: ViewerDiffSpec, repo: String) -> [ViewerDiffFile]? {
        var files: [ViewerDiffFile] = []
        var anySucceeded = false

        for query in spec.fileListQueries() {
            if query.origin == .untracked {
                guard let output = run(repo: repo, query.nameStatus) else { continue }
                anySucceeded = true
                files += untrackedFiles(paths: nulFields(output), repo: repo)
                continue
            }

            guard let statusOutput = run(repo: repo, query.nameStatus) else { continue }
            anySucceeded = true
            let counts = run(repo: repo, query.numstat)
                .map(parseNumstat) ?? [:]

            for entry in parseNameStatus(statusOutput) {
                let count = counts[entry.path]
                files.append(ViewerDiffFile(
                    path: entry.path,
                    oldPath: entry.oldPath,
                    status: entry.status,
                    origin: query.origin,
                    additions: count?.additions ?? 0,
                    deletions: count?.deletions ?? 0,
                    isBinary: count?.isBinary ?? false))
            }
        }

        guard anySucceeded else { return nil }
        return files
    }

    /// One untracked file's entry. Every line is an addition, so the count is
    /// the file's own line count — cheap to read, and capped so a stray
    /// gigabyte-sized artifact in the working tree can't stall the list.
    private static func untrackedFiles(paths: [String], repo: String) -> [ViewerDiffFile] {
        paths.compactMap { path in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            var additions = 0
            // Anything we can't read as text is shown as a stub, which is also
            // the honest answer for a file too big to count.
            var binary = true
            if size <= untrackedByteCap, let data = try? Data(contentsOf: url) {
                binary = data.prefix(8000).contains(0)
                if !binary {
                    additions = data.reduce(into: 0) { $0 += ($1 == 0x0A ? 1 : 0) }
                    // A last line with no trailing newline still counts.
                    if let last = data.last, last != 0x0A { additions += 1 }
                }
            }
            return ViewerDiffFile(
                path: path, status: .added, origin: .untracked,
                additions: additions, isBinary: binary)
        }
    }

    // MARK: - Patches

    /// The unified-diff text for one file, or nil if git had nothing to say.
    ///
    /// An untracked file has no other side for git to diff against, so its
    /// patch is synthesized as an all-added file — the renderer then treats it
    /// exactly like any other addition instead of needing a second code path.
    static func patch(for file: ViewerDiffFile, spec: ViewerDiffSpec, repo: String) -> String? {
        if file.origin == .untracked {
            return syntheticAddPatch(for: file, repo: repo)
        }
        guard let arguments = spec.patchArguments(for: file) else { return nil }
        return run(repo: repo, arguments)
    }

    private static func syntheticAddPatch(for file: ViewerDiffFile, repo: String) -> String? {
        guard !file.isBinary else { return nil }
        let url = URL(fileURLWithPath: repo).appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url),
              data.count <= untrackedByteCap,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var lines = text.components(separatedBy: "\n")
        // `components(separatedBy:)` yields a trailing empty element for a
        // file that ends in a newline; that is not a line of content.
        let endsWithNewline = lines.count > 1 && lines.last == ""
        if endsWithNewline { lines.removeLast() }

        var out = "diff --git a/\(file.path) b/\(file.path)\n"
        out += "new file mode 100644\n"
        out += "--- /dev/null\n+++ b/\(file.path)\n"
        out += "@@ -0,0 +1,\(lines.count) @@\n"
        out += lines.map { "+" + $0 }.joined(separator: "\n")
        out += "\n"
        if !endsWithNewline { out += "\\ No newline at end of file\n" }
        return out
    }

    // MARK: - Output parsing

    /// Split `-z` output into its NUL-terminated fields, dropping the empty
    /// tail the final terminator produces.
    static func nulFields(_ output: String) -> [String] {
        var fields = output.components(separatedBy: "\0")
        if fields.last?.isEmpty == true { fields.removeLast() }
        return fields
    }

    struct NameStatusEntry: Equatable {
        let status: ViewerDiffFile.Status
        let path: String
        let oldPath: String?
    }

    /// Parse `--name-status -z`.
    ///
    /// With `-z` the status letter is its own NUL-terminated field, and a
    /// rename/copy is followed by TWO paths rather than one — which is the
    /// whole reason this can't be a line split.
    static func parseNameStatus(_ output: String) -> [NameStatusEntry] {
        let fields = nulFields(output)
        var entries: [NameStatusEntry] = []
        var i = 0
        while i < fields.count {
            let raw = fields[i]
            i += 1
            guard !raw.isEmpty else { continue }
            let status = ViewerDiffFile.Status.parse(raw)
            let isPair = raw.hasPrefix("R") || raw.hasPrefix("C")
            if isPair {
                guard i + 1 < fields.count else { break }
                let source = fields[i]
                let destination = fields[i + 1]
                i += 2
                entries.append(NameStatusEntry(
                    status: status, path: destination, oldPath: source))
            } else {
                guard i < fields.count else { break }
                let path = fields[i]
                i += 1
                entries.append(NameStatusEntry(status: status, path: path, oldPath: nil))
            }
        }
        return entries
    }

    struct LineCount: Equatable {
        let additions: Int
        let deletions: Int
        let isBinary: Bool
    }

    /// Parse `--numstat -z` into counts keyed by the file's CURRENT path.
    ///
    /// A binary file reports `-` for both counts. A rename leaves the path
    /// field empty and follows with two NUL-terminated paths, the same shape
    /// `--name-status` uses.
    static func parseNumstat(_ output: String) -> [String: LineCount] {
        let fields = nulFields(output)
        var counts: [String: LineCount] = [:]
        var i = 0
        while i < fields.count {
            let record = fields[i]
            i += 1
            guard !record.isEmpty else { continue }
            let parts = record.split(
                separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let additions = Int(parts[0])
            let deletions = Int(parts[1])
            var path = String(parts[2])
            if path.isEmpty {
                guard i + 1 < fields.count else { break }
                path = fields[i + 1]
                i += 2
            }
            counts[path] = LineCount(
                additions: additions ?? 0,
                deletions: deletions ?? 0,
                // git prints `-` for both counts on a binary file.
                isBinary: additions == nil && deletions == nil)
        }
        return counts
    }
}

/// Off-main-thread diff loading for one pane.
///
/// Serialized on a private queue per pane: a live-refreshing status pane and a
/// click on a file row must not race each other into git, and generation
/// counters keep a slow answer for a spec the pane has since navigated away
/// from from overwriting the current one.
final class ViewerDiffLoader {
    /// Everything a pane needs to draw the file tree.
    struct Listing {
        let spec: ViewerDiffSpec
        let repo: String
        let files: [ViewerDiffFile]
        /// Set when the listing is empty for a reason worth explaining.
        let message: String?
    }

    private let queue = DispatchQueue(
        label: "com.dzearing.ghoztty.viewer-diff", qos: .userInitiated)

    /// Bumped on every new request so a stale completion can be dropped.
    private var listGeneration = 0
    private var patchGeneration = 0

    /// Resolve the repo, resolve a bare `git-diff:` to a real range, and list
    /// the files. `directory` is the pane's origin directory.
    func loadListing(
        spec: ViewerDiffSpec,
        directory: String?,
        completion: @escaping (Result<Listing, ViewerDiffError>) -> Void
    ) {
        listGeneration += 1
        let generation = listGeneration
        queue.async { [weak self] in
            let result = Self.listingSync(spec: spec, directory: directory)
            DispatchQueue.main.async {
                guard let self, self.listGeneration == generation else { return }
                completion(result)
            }
        }
    }

    /// Fetch one file's patch. Cancels nothing in flight — it just makes sure
    /// only the newest answer is delivered, so a fast click-through of the
    /// tree never renders a file the user has already moved past.
    func loadPatch(
        file: ViewerDiffFile,
        spec: ViewerDiffSpec,
        repo: String,
        completion: @escaping (ViewerDiffFile, String?) -> Void
    ) {
        patchGeneration += 1
        let generation = patchGeneration
        queue.async { [weak self] in
            let patch = ViewerGit.patch(for: file, spec: spec, repo: repo)
            DispatchQueue.main.async {
                guard let self, self.patchGeneration == generation else { return }
                completion(file, patch)
            }
        }
    }

    static func listingSync(
        spec: ViewerDiffSpec,
        directory: String?
    ) -> Result<Listing, ViewerDiffError> {
        guard let directory, !directory.isEmpty else {
            return .failure(.noDirectory)
        }
        guard let repo = ViewerWorktreeResolver.repositoryRoot(containing: directory) else {
            return .failure(.notARepository(directory))
        }

        var resolved = spec
        if case .branch = spec.kind {
            guard let base = ViewerGit.defaultBase(repo: repo) else {
                return .failure(.noDefaultBase)
            }
            resolved = spec.resolving(defaultBase: base)
        }

        guard let files = ViewerGit.fileList(spec: resolved, repo: repo) else {
            return .failure(.gitFailed(resolved.title))
        }
        return .success(Listing(
            spec: resolved,
            repo: repo,
            files: files,
            message: files.isEmpty ? emptyMessage(for: resolved) : nil))
    }

    private static func emptyMessage(for spec: ViewerDiffSpec) -> String {
        switch spec.kind {
        case .status: return "The working tree is clean."
        default: return "No changes in \(spec.title)."
        }
    }
}

/// Why a diff pane has nothing to show. Each case is something the user can
/// act on, which is the point of not collapsing them into one "error".
enum ViewerDiffError: Error, Equatable {
    case noDirectory
    case notARepository(String)
    case noDefaultBase
    case gitFailed(String)

    var title: String {
        switch self {
        case .noDirectory: return "No directory"
        case .notARepository: return "Not a git repository"
        case .noDefaultBase: return "No default branch"
        case .gitFailed: return "git could not produce this diff"
        }
    }

    var detail: String {
        switch self {
        case .noDirectory:
            return "This pane was not opened from a directory, so there is no "
                + "repository to diff. Reopen it with --working-directory=<path>."
        case .notARepository(let path):
            return "\(path) is not inside a git working tree."
        case .noDefaultBase:
            return "This repository has no main, master, or origin/HEAD to compare "
                + "against. Name a base explicitly, e.g. git-diff:develop...HEAD."
        case .gitFailed(let spec):
            return "git rejected \(spec). Check the revision names."
        }
    }
}
