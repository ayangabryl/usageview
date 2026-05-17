import Foundation

struct CursorAccountInfo: Sendable {
    var name: String?
    var email: String?
}

@Observable
@MainActor
final class CursorAuthService: Sendable {

    private let probe = CursorStatusProbe()

    func isAuthenticated(for accountId: UUID) -> Bool {
        loadToken(key: tokenKey(for: accountId)) != nil
    }

    /// Import and validate session from browsers (Safari first, then others — CodexBar order).
    func saveFromBrowser(for accountId: UUID) async throws -> CursorAccountInfo {
        let session = try await probe.fetchValidatedSession(
            accountId: accountId,
            allowCachedSessions: true,
            allowKeychainPrompt: true)
        return saveToken(session.cookieHeader, for: accountId, sourceLabel: session.sourceLabel, accountInfo: session.accountInfo)
    }

    /// Open authenticator.cursor.sh and poll until a valid session is detected.
    func runBrowserLogin(
        for accountId: UUID,
        onPhaseChange: @escaping @MainActor (CursorLoginRunner.Phase) -> Void = { _ in }
    ) async throws -> CursorAccountInfo {
        let runner = CursorLoginRunner(accountId: accountId)
        let result = await runner.run(onPhaseChange: onPhaseChange)

        switch result.outcome {
        case .success:
            guard let session = result.session else {
                throw CursorProbeError.noSessionCookie
            }
            return saveToken(
                session.cookieHeader,
                for: accountId,
                sourceLabel: session.sourceLabel,
                accountInfo: session.accountInfo)
        case .cancelled:
            throw CancellationError()
        case let .failed(message):
            throw CursorProbeError.networkError(message)
        }
    }

    func saveToken(_ token: String, for accountId: UUID) async throws -> CursorAccountInfo {
        guard let normalized = CookieHeaderNormalizer.normalize(token) else {
            throw CursorProbeError.networkError("Invalid cookie header")
        }
        let session = try await probe.fetchValidatedSession(
            accountId: accountId,
            manualCookieHeader: normalized,
            allowCachedSessions: false,
            allowKeychainPrompt: false)
        return saveToken(session.cookieHeader, for: accountId, sourceLabel: "manual", accountInfo: session.accountInfo)
    }

    @discardableResult
    private func saveToken(
        _ token: String,
        for accountId: UUID,
        sourceLabel: String?,
        accountInfo: CursorAccountInfo
    ) -> CursorAccountInfo {
        saveTokenValue(key: tokenKey(for: accountId), value: token)
        if let sourceLabel {
            CookieHeaderCache.store(accountId: accountId, cookieHeader: token, sourceLabel: sourceLabel)
        }
        return accountInfo
    }

    func getToken(for accountId: UUID) -> String? {
        loadToken(key: tokenKey(for: accountId))
    }

    func disconnect(accountId: UUID) {
        removeToken(key: tokenKey(for: accountId))
        CookieHeaderCache.clear(accountId: accountId)
    }

    private func tokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.cursor-token-\(id.uuidString)"
    }

    private func saveTokenValue(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}
