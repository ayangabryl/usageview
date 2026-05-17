import Foundation
import os

private let refreshLog = Logger(subsystem: "com.ayangabryl.usage", category: "ClaudeDelegatedRefresh")

/// Asks Claude Code CLI to refresh OAuth in Keychain without Usageview reading it repeatedly (CodexBar pattern).
enum ClaudeDelegatedRefreshCoordinator {
    enum Outcome: Sendable, Equatable {
        case skippedByCooldown
        case cliUnavailable
        case attemptedSucceeded
        case attemptedFailed(String)
    }

    private static let lastAttemptKey = "claudeOAuthDelegatedRefreshLastAttemptAt"
    private static let defaultCooldown: TimeInterval = 60 * 5

    static func attemptIfNeeded() async -> Outcome {
        guard !KeychainAccessGate.isDisabled else { return .cliUnavailable }
        guard UserDefaults.standard.bool(forKey: "allowClaudeCLIKeychainAccess") else {
            return .cliUnavailable
        }

        let now = Date()
        if isInCooldown(now: now) {
            return .skippedByCooldown
        }
        recordAttempt(now: now)

        guard let claudePath = resolveClaudeBinary() else {
            refreshLog.info("Claude CLI not found; skipping delegated refresh")
            return .cliUnavailable
        }

        let baseline = CLIKeychainReader.readGenericPassword(service: ClaudeCLICredentialStore.keychainService)

        do {
            try await runClaudeStatusTouch(binary: claudePath, timeout: 8)
        } catch {
            refreshLog.warning("Claude delegated refresh touch failed: \(error.localizedDescription)")
            return .attemptedFailed(error.localizedDescription)
        }

        try? await Task.sleep(for: .milliseconds(500))
        let after = CLIKeychainReader.readGenericPassword(service: ClaudeCLICredentialStore.keychainService)
        if let baseline, let after, baseline != after {
            refreshLog.info("Claude delegated refresh: keychain payload changed")
            return .attemptedSucceeded
        }
        if baseline == nil, after != nil {
            return .attemptedSucceeded
        }

        return .attemptedFailed("Claude keychain did not update after CLI touch.")
    }

    private static func isInCooldown(now: Date) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastAttemptKey)
        guard last > 0 else { return false }
        return now.timeIntervalSince1970 - last < defaultCooldown
    }

    private static func recordAttempt(now: Date) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastAttemptKey)
    }

    private static func resolveClaudeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    /// Lightweight CLI invocation — enough for Claude Code to refresh its Keychain OAuth entry.
    private static func runClaudeStatusTouch(binary: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["-p", "/status"]
                process.standardInput = nil
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard process.terminationStatus == 0 || process.terminationStatus == 15 else {
                    continuation.resume(throwing: NSError(
                        domain: "ClaudeDelegatedRefresh",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "claude exited with status \(process.terminationStatus)"]
                    ))
                    return
                }
                continuation.resume()
            }
        }
    }
}
