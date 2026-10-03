import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
    public let timedOut: Bool

    public func checked() throws -> CommandResult {
        if timedOut { throw AppError.message("The command timed out. No further action was taken.") }
        if status != 0 { throw AppError.message(error.isEmpty ? "Command exited with status \(status)." : error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return self
    }
}

public enum AppError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// No shell, bounded output, no inherited stdin. Temporary output avoids pipe deadlocks.
public struct ProcessRunner: Sendable {
    public init() {}
    public func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 15) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.execute(executable, arguments, environment: environment, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    // Foundation Process's run-loop lifetime stays on one worker thread.
    // Suspending between run() and waitUntilExit() can hop executors and stall reaping.
    private static func execute(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> CommandResult {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("git-settings-\(UUID().uuidString)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: directory) }
            let out = directory.appendingPathComponent("out"), err = directory.appendingPathComponent("err")
            fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
            fm.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
            defer { try? stdout.close(); try? stderr.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            let expired = process.isRunning
            if expired {
                process.terminate()
                let grace = Date().addingTimeInterval(0.3)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            func read(_ url: URL) throws -> String {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 262_144) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
            return try CommandResult(status: process.terminationStatus, output: read(out), error: read(err), timedOut: expired)
    }
}

public struct AppPaths: Sendable {
    public let home: URL
    public let environment: [String: String]
    public let git: String
    public static func current() -> AppPaths {
        var env = ProcessInfo.processInfo.environment
        if let fixture = env["GIT_SETTINGS_HOME"], fixture.hasPrefix("/") {
            let home = URL(fileURLWithPath: fixture)
            env["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
            env["GIT_CONFIG_GLOBAL"] = home.appendingPathComponent(".gitconfig").path
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env.removeValue(forKey: "SSH_AUTH_SOCK")
            return AppPaths(home: home, environment: env)
        }
        return AppPaths()
    }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment, git: String? = nil) {
        self.home = home
        var env = environment
        // GUI launches need a dependable PATH, but keep the existing agent socket.
        env["HOME"] = home.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        for key in Array(env.keys) where key.hasPrefix("GIT_") && key != "GIT_CONFIG_GLOBAL" && key != "GIT_CONFIG_NOSYSTEM" { env.removeValue(forKey: key) }
        self.environment = env
        self.git = git ?? ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/git"
    }
    public var ssh: URL { home.appendingPathComponent(".ssh") }
    public var sshConfig: URL { ssh.appendingPathComponent("config") }
    public var state: URL { home.appendingPathComponent(".config/mac-utilities/git-settings") }
    public var gitConfig: URL {
        if let custom = environment["GIT_CONFIG_GLOBAL"] { return URL(fileURLWithPath: custom) }
        let primary = home.appendingPathComponent(".gitconfig")
        let xdg = URL(fileURLWithPath: environment["XDG_CONFIG_HOME"] ?? home.appendingPathComponent(".config").path).appendingPathComponent("git/config")
        return !FileManager.default.fileExists(atPath: primary.path) && FileManager.default.fileExists(atPath: xdg.path) ? xdg : primary
    }
}
