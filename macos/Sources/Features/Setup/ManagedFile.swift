// macos/Sources/Features/Setup/ManagedFile.swift
import Foundation

enum ManagedFileError: Error, Equatable {
    case notManaged(URL)
    case symlinkRefused(URL)
    case writeFailed(String)
}

/// Marker-guarded, symlink-refusing, atomic file writer for Ghoztty-managed
/// artifacts in shared config dirs. Only ever overwrites/removes files that
/// carry `marker`, so a user's own same-named file is never touched.
enum ManagedFile {
    static func state(at url: URL, expected: String, marker: String) -> ComponentInstallState {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return .notInstalled
        }
        guard contents.contains(marker) else { return .notInstalled }
        return contents == expected ? .installed : .outdated
    }

    static func write(_ contents: String, to url: URL, marker: String, mode: mode_t, fileManager: FileManager) throws {
        // Refuse to clobber a same-named file that isn't ours.
        if fileManager.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            guard existing.contains(marker) else { throw ManagedFileError.notManaged(url) }
        }
        // Refuse a symlink at the final path (dotfiles hazard).
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw ManagedFileError.symlinkRefused(url)
        }

        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".ghoztty-\(UUID().uuidString).tmp")

        let fd = tmp.path.withCString { cpath in
            open(cpath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
        }
        guard fd >= 0 else { throw ManagedFileError.writeFailed("open temp failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        let data = Array(contents.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            try? fileManager.removeItem(at: tmp)
            throw ManagedFileError.writeFailed("short write")
        }
        // Ensure mode isn't loosened by umask.
        _ = tmp.path.withCString { chmod($0, mode) }

        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
    }

    static func removeIfManaged(at url: URL, marker: String, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let contents = try String(contentsOf: url, encoding: .utf8)
        guard contents.contains(marker) else { throw ManagedFileError.notManaged(url) }
        try fileManager.removeItem(at: url)
    }
}
