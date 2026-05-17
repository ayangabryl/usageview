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

    func saveFromBrowser(for accountId: UUID) async throws -> CursorAccountInfo {
        let session = try await probe.fetchValidatedSession(
            accountId: accountId,
            allowCachedSessions: true,
            allowKeychainPrompt: true)
        return applySession(session, for: accountId)
    }

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
            return applySession(session, for: accountId)
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
        return applySession(session, for: accountId)
    }

    func updateSession(
        cookieHeader: String,
        for accountId: UUID,
        sourceLabel: String? = nil,
        cookies: [HTTPCookie] = []
    ) {
        saveTokenValue(key: tokenKey(for: accountId), value: cookieHeader)
        if let sourceLabel {
            CookieHeaderCache.store(accountId: accountId, cookieHeader: cookieHeader, sourceLabel: sourceLabel)
        }
        if !cookies.isEmpty {
            Task { await CursorSessionStore.shared.setCookies(cookies) }
        }
    }

    func getToken(for accountId: UUID) -> String? {
        loadToken(key: tokenKey(for: accountId))
    }

    func disconnect(accountId: UUID) {
        removeToken(key: tokenKey(for: accountId))
        CookieHeaderCache.clear(accountId: accountId)
    }

    private func applySession(_ session: CursorValidatedSession, for accountId: UUID) -> CursorAccountInfo {
        updateSession(
            cookieHeader: session.cookieHeader,
            for: accountId,
            sourceLabel: session.sourceLabel,
            cookies: session.cookies)
        return session.accountInfo
    }

    private func tokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.cursor-token-\(id.uuidString)"
    }

    private func saveTokenValue(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}
