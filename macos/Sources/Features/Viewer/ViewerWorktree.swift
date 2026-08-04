import Foundation
import OSLog

/// The git repo a viewer pane's content belongs to — the destination for any
/// feedback filed against that pane.
///
/// "Worktree" here means any git working tree: a linked worktree AND a main
/// checkout both count, because `git rev-parse --show-toplevel` reports each
/// one's own root and either is a legitimate place to file feedback.
struct ViewerWorktree: Equatable {
    /// Absolute path of the working tree's top-level directory.
    let path: String

    /// The last path component — what the feedback button shows, so the user
    /// can see at a glance which repo a report would land in.
    var name: String { (path as NSString).lastPathComponent }

    var url: URL { URL(fileURLWithPath: path) }
}

/// Derives the worktree behind a viewer pane's current location.
///
/// Strategy (in order):
///  1. A file viewer contributes the viewed file's own directory.
///  2. An `http://localhost:PORT` viewer resolves the listening port to the
///     serving process, then to that process's working directory.
///  3. Anything else (a remote site, a blank pane, a port with no listener)
///     falls back to the directory the pane was OPENED from.
/// Whatever directory comes out is then handed to `git rev-parse
/// --show-toplevel`; if that fails there is no worktree and the caller shows
/// no feedback affordance at all.
///
/// Everything here is blocking process I/O — call `resolve` only from
/// `ViewerWorktreeCache.resolve`, which moves it off the main thread.
enum ViewerWorktreeResolver {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty",
        category: "ViewerWorktree")

    /// The directory a location should be attributed to, before git is asked
    /// anything. Nil when there is nothing to attribute it to at all.
    ///
    /// Split out from `resolve` so the strategy is unit-testable without a
    /// git repo: this is the part that encodes "port lookup first, pane-origin
    /// directory as fallback".
    static func candidateDirectory(
        for location: String,
        originDirectory: String?,
        portLookup: (Int) -> String? = listenerWorkingDirectory(port:)
    ) -> String? {
        // 1. File viewers: the file's own directory. A file that names a
        // directory that doesn't exist still falls through to the origin —
        // a viewer showing a missing file shouldn't misattribute feedback.
        if let fileURL = fileURL(for: location) {
            let dir = fileURL.deletingLastPathComponent().path
            if isDirectory(dir) { return dir }
            return originDirectory
        }

        // 2. Loopback dev servers: port → pid → cwd.
        if let port = loopbackPort(in: location), let cwd = portLookup(port) {
            return cwd
        }

        // 3. Everything else, including a loopback port with no listener.
        return originDirectory
    }

    /// Full resolution: candidate directory → repo root. Blocking.
    static func resolve(location: String, originDirectory: String?) -> ViewerWorktree? {
        guard let dir = candidateDirectory(for: location, originDirectory: originDirectory)
        else { return nil }
        guard let root = repositoryRoot(containing: dir) else { return nil }
        return ViewerWorktree(path: root)
    }

    // MARK: - Location classification

    /// The file a location names, or nil if it names a website. Mirrors
    /// `ViewerView.mode(for:)`'s split so the two can never disagree about
    /// what counts as a file.
    static func fileURL(for location: String) -> URL? {
        guard !location.isEmpty else { return nil }
        if location.hasPrefix("http://") || location.hasPrefix("https://")
            || location.hasPrefix("about:") {
            return nil
        }
        var path = location
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The TCP port of a loopback http(s) URL, or nil if the URL points
    /// somewhere else. A scheme-relative or hostless string is not loopback.
    ///
    /// `0.0.0.0` counts: a dev server bound to all interfaces and browsed as
    /// `http://0.0.0.0:3000` is still a local process we can look up.
    static func loopbackPort(in location: String) -> Int? {
        guard let url = URL(string: location),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return nil }

        let loopbackHosts: Set<String> = [
            "localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0",
        ]
        guard loopbackHosts.contains(host) else { return nil }
        return url.port ?? (scheme == "http" ? 80 : 443)
    }

    // MARK: - Port → working directory

    /// The working directory of the process listening on `port`, or nil if
    /// nothing is listening (or its cwd can't be read).
    ///
    /// Shelling out to `lsof` rather than using `proc_pidinfo`: there is no
    /// port→pid syscall. `proc_pidinfo` only answers questions about a pid you
    /// already hold, so a native implementation would have to `proc_listpids`
    /// every process and walk `PROC_PIDLISTFDS`/`PROC_PIDFDSOCKETINFO` on each
    /// — reimplementing lsof, and taking EPERM on every process this user
    /// doesn't own. Two short-lived `lsof` invocations on a background queue
    /// are simpler and carry no privilege surface.
    static func listenerWorkingDirectory(port: Int) -> String? {
        guard let pidOutput = run(
            tool: lsofPaths,
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        else { return nil }

        // Pre-forking servers report several pids; the parent (first line)
        // holds the cwd the user started the server from.
        guard let pid = pidOutput
            .split(separator: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
        else { return nil }

        guard let cwdOutput = run(
            tool: lsofPaths,
            arguments: ["-a", "-p", pid, "-d", "cwd", "-Fn"])
        else { return nil }

        // `-Fn` field output interleaves `p<pid>`, `f<fd>` and `n<path>`
        // lines; only the `n` line carries the directory.
        return cwdOutput
            .split(separator: "\n")
            .first { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
            .flatMap { isDirectory($0) ? $0 : nil }
    }

    // MARK: - Directory → repo root

    /// The top-level directory of the working tree containing `path`, or nil
    /// if it isn't in one.
    ///
    /// `--show-toplevel` returns the LINKED worktree's own root inside a
    /// linked worktree and the main checkout's root otherwise, so one command
    /// covers both without special-casing `git worktree list`.
    static func repositoryRoot(containing path: String) -> String? {
        guard isDirectory(path) else { return nil }
        guard let output = run(
            tool: gitPaths,
            arguments: ["-C", path, "rev-parse", "--show-toplevel"])
        else { return nil }
        let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, isDirectory(root) else { return nil }
        return root
    }

    /// The branch and commit a worktree is currently on, so a report can be
    /// replayed against the exact revision the user was looking at. Blocking;
    /// call off the main thread. Either half is nil when git can't answer
    /// (a detached HEAD has no branch name; a repo with no commits has no HEAD).
    static func revision(at root: String) -> (branch: String?, commit: String?) {
        let branch = run(
            tool: gitPaths,
            arguments: ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = run(
            tool: gitPaths,
            arguments: ["-C", root, "rev-parse", "HEAD"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            branch.flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 },
            commit.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Process plumbing

    /// Shared with the diff loader (see `ViewerProcess`) so there is one
    /// place that decides how the viewer launches a subprocess — absolute
    /// paths, no terminal prompts, a watchdog, and stdout drained before the
    /// wait.
    private static let gitPaths = ViewerProcess.gitPaths
    private static let lsofPaths = ViewerProcess.lsofPaths

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    private static func run(tool: [String], arguments: [String]) -> String? {
        ViewerProcess.run(tool: tool, arguments: arguments, timeout: 5)
    }
}

/// Off-main-thread worktree resolution with a short-lived cache.
///
/// Resolution costs two-to-three subprocess launches, and a viewer re-resolves
/// on EVERY navigation — including each step of a back/forward walk — so an
/// uncached implementation would stutter the pane. Entries expire after
/// `ttl` rather than living forever because the port→cwd half is genuinely
/// volatile: starting a dev server on :3000 must make the button appear
/// without the user having to reopen the pane.
final class ViewerWorktreeCache {
    static let shared = ViewerWorktreeCache()

    /// How long a resolution (including a negative one) stays good.
    static let ttl: TimeInterval = 15

    private struct Entry {
        let worktree: ViewerWorktree?
        let resolvedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let queue = DispatchQueue(
        label: "com.dzearing.ghoztty.viewer-worktree", qos: .utility)

    private static func key(location: String, originDirectory: String?) -> String {
        "\(location)\u{0}\(originDirectory ?? "")"
    }

    /// A still-valid cached answer, if there is one. The outer optional is
    /// "not cached"; the inner is "cached as no-worktree".
    func cached(location: String, originDirectory: String?) -> ViewerWorktree?? {
        let key = Self.key(location: location, originDirectory: originDirectory)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.resolvedAt) < Self.ttl
        else { return nil }
        return .some(entry.worktree)
    }

    /// Resolve off the main thread and deliver the answer on the main queue.
    /// A cached answer is delivered synchronously, so navigating back to a
    /// location already visited never flickers the button away and back.
    func resolve(
        location: String,
        originDirectory: String?,
        completion: @escaping (ViewerWorktree?) -> Void
    ) {
        if let hit = cached(location: location, originDirectory: originDirectory) {
            completion(hit)
            return
        }
        let key = Self.key(location: location, originDirectory: originDirectory)
        queue.async { [weak self] in
            let worktree = ViewerWorktreeResolver.resolve(
                location: location, originDirectory: originDirectory)
            self?.lock.lock()
            self?.entries[key] = Entry(worktree: worktree, resolvedAt: Date())
            self?.lock.unlock()
            DispatchQueue.main.async { completion(worktree) }
        }
    }

    /// Drop everything (tests).
    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
