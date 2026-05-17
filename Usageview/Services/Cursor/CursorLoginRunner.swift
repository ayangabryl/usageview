#if os(macOS)
import AppKit
import Foundation

/// Opens Cursor sign-in in the default browser and polls until cookies validate (CodexBar pattern).
@MainActor
final class CursorLoginRunner {
    enum Phase: Sendable {
        case loading
        case waitingLogin
        case success
        case failed(String)
    }

    struct Result: Sendable {
        enum Outcome: Sendable {
            case success
            case cancelled
            case failed(String)
        }

        let outcome: Outcome
        let session: CursorValidatedSession?
    }

    static let authURL = URL(string: "https://authenticator.cursor.sh/")!

    private let accountId: UUID
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let openURL: @MainActor (URL) -> Bool
    private let sleeper: @Sendable (UInt64) async throws -> Void

    init(
        accountId: UUID,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 2,
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        sleeper: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.accountId = accountId
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.openURL = openURL
        self.sleeper = sleeper
    }

    func run(onPhaseChange: @escaping @MainActor (Phase) -> Void) async -> Result {
        onPhaseChange(.loading)
        CookieHeaderCache.clear(accountId: accountId)
        await CursorSessionStore.shared.clearCookies()

        guard openURL(Self.authURL) else {
            let message = "Could not open Cursor login in your browser."
            onPhaseChange(.failed(message))
            return Result(outcome: .failed(message), session: nil)
        }

        onPhaseChange(.waitingLogin)
        let probe = CursorStatusProbe()
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        repeat {
            if Task.isCancelled {
                return Result(outcome: .cancelled, session: nil)
            }

            do {
                let session = try await probe.fetchValidatedSession(
                    accountId: accountId,
                    allowCachedSessions: false,
                    allowKeychainPrompt: true)
                onPhaseChange(.success)
                return Result(outcome: .success, session: session)
            } catch {
                lastError = error
            }

            guard Date() < deadline else { break }
            let delay = UInt64(max(0.1, pollInterval) * 1_000_000_000)
            try? await sleeper(delay)
        } while true

        let message = Self.timeoutMessage(lastError: lastError)
        onPhaseChange(.failed(message))
        return Result(outcome: .failed(message), session: nil)
    }

    private static func timeoutMessage(lastError: Error?) -> String {
        let hint = "Sign in to cursor.com in your browser, then try again."
        guard let lastError else {
            return "Timed out waiting for Cursor login. \(hint)"
        }
        return "Timed out waiting for Cursor login. \(hint) \(lastError.localizedDescription)"
    }
}
#endif
