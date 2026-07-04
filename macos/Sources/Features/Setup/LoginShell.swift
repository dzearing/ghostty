import Foundation

/// Runs one-off commands through the user's login shell so their profile
/// (and therefore their PATH) applies, matching what a terminal would see.
enum LoginShell {
    /// The user's shell. GUI apps inherit SHELL from launchd.
    static var shellPath: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    /// The user's home directory, honoring a HOME override in the environment
    /// so it matches the home the login shell itself will use.
    static var homePath: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a command through the user's login shell. Blocking: run off the
    /// main thread. Returns nil if the shell could not be launched.
    static func run(_ command: String, timeout: TimeInterval = 30) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", command]
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: watchdog)

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
