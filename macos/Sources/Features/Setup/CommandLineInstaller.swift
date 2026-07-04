import AppKit
import OSLog

/// Installs and repairs the `ghoztty` command-line tool so terminals and other
/// tools can find it on PATH. All operations are idempotent: they are safe to
/// run on every launch and they repair stale links after the app moves or
/// updates.
enum CommandLineInstaller {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "CommandLineInstaller"
    )

    /// The CLI binary inside the currently running app bundle.
    static var bundledBinaryURL: URL? {
        Bundle.main.executableURL?.standardizedFileURL
    }

    static var userBinDirectory: URL {
        URL(fileURLWithPath: LoginShell.homePath)
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var userLinkURL: URL {
        userBinDirectory.appendingPathComponent("ghoztty")
    }

    /// The legacy location the website used to tell users to link with sudo.
    static let systemLinkPath = "/usr/local/bin/ghoztty"

    /// True if the app is running from a location a symlink shouldn't point at,
    /// such as a mounted DMG or an app translocation path.
    static var isRunningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    // MARK: Probe

    struct Probe {
        /// Where `ghoztty` resolves on the user's login shell PATH, if anywhere.
        let resolvedPath: String?

        /// Whether ~/.local/bin is already on the user's login shell PATH.
        let pathContainsUserBin: Bool

        /// True when `ghoztty` on PATH is this app bundle's binary.
        var isHealthy: Bool {
            guard let resolvedPath,
                  let binary = CommandLineInstaller.bundledBinaryURL else { return false }
            let resolved = URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath().path
            return resolved == binary.resolvingSymlinksInPath().path
        }
    }

    /// Checks the CLI from the user's login shell. Blocking: run off the main
    /// thread.
    static func probe() -> Probe {
        let resolved: String? = LoginShell.run("command -v ghoztty").flatMap { result in
            guard result.exitCode == 0 else { return nil }
            return result.stdout
                .split(separator: "\n")
                .last { $0.hasPrefix("/") }
                .map(String.init)
        }

        // fish joins $PATH with spaces inside double quotes, so split on both.
        let userBin = userBinDirectory.path
        let pathContainsUserBin = LoginShell.run("printf '%s\\n' \"$PATH\"").map { result in
            result.stdout
                .split { $0 == ":" || $0 == " " || $0 == "\n" }
                .contains { $0 == userBin }
        } ?? false

        return Probe(resolvedPath: resolved, pathContainsUserBin: pathContainsUserBin)
    }

    // MARK: Install

    enum InstallError: LocalizedError {
        case missingBinary
        case blockedByExistingFile(String)

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                return "The app bundle is missing its command-line binary."
            case .blockedByExistingFile(let path):
                return "A file already exists at \(path) and it is not a link Ghoztty can replace."
            }
        }
    }

    struct InstallOutcome {
        /// True if /usr/local/bin still has a stale ghoztty entry that could
        /// shadow the user-level link.
        let staleSystemLinkRemains: Bool
    }

    /// Creates or repairs the user-level link and PATH entry, and fixes a stale
    /// /usr/local/bin link when possible. Requires no privileges unless
    /// `allowAdminPrompt` is true and the stale system link can't be replaced
    /// directly. Blocking: run off the main thread.
    @discardableResult
    static func install(pathContainsUserBin: Bool, allowAdminPrompt: Bool) throws -> InstallOutcome {
        guard let binary = bundledBinaryURL else { throw InstallError.missingBinary }
        let fm = FileManager.default

        try fm.createDirectory(at: userBinDirectory, withIntermediateDirectories: true)

        if let dest = try? fm.destinationOfSymbolicLink(atPath: userLinkURL.path) {
            if dest != binary.path {
                try fm.removeItem(at: userLinkURL)
                try fm.createSymbolicLink(at: userLinkURL, withDestinationURL: binary)
            }
        } else if fm.fileExists(atPath: userLinkURL.path) {
            throw InstallError.blockedByExistingFile(userLinkURL.path)
        } else {
            try fm.createSymbolicLink(at: userLinkURL, withDestinationURL: binary)
        }

        if !pathContainsUserBin {
            try ensureProfilePathEntry()
        }

        let systemLinkClean = repairSystemLinkIfNeeded(
            binary: binary,
            allowAdminPrompt: allowAdminPrompt)
        return InstallOutcome(staleSystemLinkRemains: !systemLinkClean)
    }

    /// Adds ~/.local/bin to PATH in the profile of the user's login shell.
    private static func ensureProfilePathEntry() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: LoginShell.homePath)
        let shellName = URL(fileURLWithPath: LoginShell.shellPath).lastPathComponent

        if shellName == "fish" {
            let confDir = home.appendingPathComponent(".config/fish/conf.d", isDirectory: true)
            let confFile = confDir.appendingPathComponent("ghoztty.fish")
            guard !fm.fileExists(atPath: confFile.path) else { return }
            try fm.createDirectory(at: confDir, withIntermediateDirectories: true)
            let content = """
            # Added by Ghoztty so the ghoztty command is available.
            if not contains -- "$HOME/.local/bin" $PATH
                set -gx PATH "$HOME/.local/bin" $PATH
            end

            """
            try content.write(to: confFile, atomically: true, encoding: .utf8)
            return
        }

        let profileName: String
        switch shellName {
        case "bash": profileName = ".bash_profile"
        case "zsh": profileName = ".zprofile"
        default: profileName = ".profile"
        }

        let profile = home.appendingPathComponent(profileName)
        let existing = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""

        // If the profile already puts ~/.local/bin on PATH, leave it alone.
        guard !existing.contains(".local/bin") else { return }

        let addition = """

        # Added by Ghoztty so the ghoztty command is available.
        export PATH="$HOME/.local/bin:$PATH"

        """
        try (existing + addition).write(to: profile, atomically: true, encoding: .utf8)
    }

    /// Repairs a stale /usr/local/bin/ghoztty link left behind by the old
    /// sudo-based install instructions or by a moved app bundle. Returns true
    /// when no stale entry remains there afterwards.
    private static func repairSystemLinkIfNeeded(binary: URL, allowAdminPrompt: Bool) -> Bool {
        let fm = FileManager.default

        guard let dest = try? fm.destinationOfSymbolicLink(atPath: systemLinkPath) else {
            // Not a symlink. A regular file here would shadow the user-level
            // link, but we never touch files we didn't create.
            if fm.fileExists(atPath: systemLinkPath) {
                logger.warning("non-symlink found at \(self.systemLinkPath, privacy: .public); leaving it alone")
                return false
            }
            return true
        }

        // Already points at this app bundle's binary.
        if URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
            == binary.resolvingSymlinksInPath().path {
            return true
        }

        // Only manage links that were clearly created for a Ghoztty install.
        guard dest.lowercased().contains("ghoztty") else {
            logger.warning("system link points at unrelated target \(dest, privacy: .public); leaving it alone")
            return false
        }

        // /usr/local/bin is user-writable on some machines; try directly first.
        do {
            try fm.removeItem(atPath: systemLinkPath)
            try fm.createSymbolicLink(atPath: systemLinkPath, withDestinationPath: binary.path)
            logger.info("repaired stale system link at \(self.systemLinkPath, privacy: .public)")
            return true
        } catch {
            logger.info("direct system link repair failed: \(error, privacy: .public)")
        }

        guard allowAdminPrompt else { return false }
        return repairSystemLinkWithPrivileges(binary: binary)
    }

    /// Replaces the system link using the macOS authorization dialog. Blocking.
    private static func repairSystemLinkWithPrivileges(binary: URL) -> Bool {
        let command = "/bin/ln -sf '\(binary.path)' '\(systemLinkPath)'"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
