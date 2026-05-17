import Darwin
import Foundation

/// Reads third-party CLI keychain entries via `/usr/bin/security` to avoid GUI keychain prompts.
///
/// Based on CodexBar's experimental `securityCLI` reader for Claude Code credentials.
enum CLIKeychainReader {
    private static let securityBinaryPath = "/usr/bin/security"
    private static let readTimeout: TimeInterval = 1.5

    private enum ReadError: Error {
        case binaryUnavailable
        case launchFailed
        case timedOut
        case nonZeroExit(status: Int32)
    }

    /// Returns raw keychain payload bytes, or `nil` when unavailable or denied.
    static func readGenericPassword(service: String, account: String? = nil) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: securityBinaryPath) else { return nil }

        do {
            let output = try runFindGenericPassword(service: service, account: account)
            let sanitized = sanitizeOutput(output)
            return sanitized.isEmpty ? nil : sanitized
        } catch {
            return nil
        }
    }

    private static func sanitizeOutput(_ data: Data) -> Data {
        var sanitized = data
        while let last = sanitized.last, last == 0x0A || last == 0x0D {
            sanitized.removeLast()
        }
        return sanitized
    }

    private static func runFindGenericPassword(service: String, account: String?) throws -> Data {
        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityBinaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            throw ReadError.launchFailed
        }

        var processGroup: pid_t?
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        let deadline = Date().addingTimeInterval(readTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            terminate(process: process, processGroup: processGroup)
            throw ReadError.timedOut
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let status = process.terminationStatus
        guard status == 0 else {
            throw ReadError.nonZeroExit(status: status)
        }
        return stdout
    }

    private static func terminate(process: Process, processGroup: pid_t?) {
        guard process.isRunning else { return }
        process.terminate()
        if let processGroup {
            kill(-processGroup, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            if let processGroup {
                kill(-processGroup, SIGKILL)
            }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
