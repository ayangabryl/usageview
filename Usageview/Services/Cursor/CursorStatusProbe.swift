#if os(macOS)
import Foundation
import SweetCookieKit

enum CursorProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case noSessionCookie

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Cursor rejected the session. Sign in again in your browser, then retry."
        case let .networkError(msg):
            "Cursor API error: \(msg)"
        case .noSessionCookie:
            [
                "No Cursor session found. Sign in at cursor.com in \(BrowserCookieImportOrder.cursorCookieImportOrder.loginHint).",
                "If you use Safari, grant Usageview Full Disk Access in System Settings → Privacy & Security.",
                "Or use Sign in with browser below.",
            ].joined(separator: " ")
        }
    }
}

struct CursorValidatedSession: Sendable {
    let cookieHeader: String
    let sourceLabel: String
    let accountInfo: CursorAccountInfo
    let cookies: [HTTPCookie]
}

/// Discovers and validates Cursor sessions via browser cookies and API checks (CodexBar pattern).
struct CursorStatusProbe: Sendable {
    private let baseURL = URL(string: "https://cursor.com")!
    private let timeout: TimeInterval

    init(networkTimeout: TimeInterval = 15) {
        self.timeout = networkTimeout
    }

    func fetchValidatedSession(
        accountId: UUID,
        manualCookieHeader: String? = nil,
        allowCachedSessions: Bool = true,
        allowKeychainPrompt: Bool = false,
        loginPollMode: Bool = false,
        logger: ((String) -> Void)? = nil
    ) async throws -> CursorValidatedSession {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }

        if let override = CookieHeaderNormalizer.normalize(manualCookieHeader) {
            log("Using manual cookie header")
            return try await validateCookieHeader(override, sourceLabel: "manual", accountId: accountId, cookies: [])
        }

        if allowCachedSessions,
           let cached = CookieHeaderCache.load(accountId: accountId),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            log("Using cached cookie header from \(cached.sourceLabel)")
            do {
                return try await validateCookieHeader(
                    cached.cookieHeader,
                    sourceLabel: cached.sourceLabel,
                    accountId: accountId,
                    cookies: [])
            } catch let error as CursorProbeError where error == .notLoggedIn {
                CookieHeaderCache.clear(accountId: accountId)
            }
        }

        let browsers = BrowserCookieImportOrder.cursorCookieImportOrder
            .cookieImportCandidates(allowKeychainPrompt: allowKeychainPrompt)

        if let session = try await scanBrowsers(
            browsers,
            allowKeychainPrompt: allowKeychainPrompt,
            surfaceSafariErrors: allowKeychainPrompt && !loginPollMode,
            importSessions: { browser in
                try CursorCookieImporter.importSessionsIfPresent(
                    browser: browser,
                    allowKeychainPrompt: allowKeychainPrompt,
                    logger: logger)
            },
            accountId: accountId,
            log: log)
        {
            return session
        }

        if !loginPollMode {
            if let session = try await scanBrowsers(
                browsers,
                allowKeychainPrompt: allowKeychainPrompt,
                surfaceSafariErrors: !loginPollMode,
                importSessions: { browser in
                    try CursorCookieImporter.importDomainCookieSessionsIfPresent(
                        browser: browser,
                        allowKeychainPrompt: allowKeychainPrompt,
                        logger: logger)
                },
                accountId: accountId,
                log: log)
            {
                return session
            }
        }

        if allowKeychainPrompt, !loginPollMode {
            do {
                _ = try CursorCookieImporter.importSession(allowKeychainPrompt: true, logger: logger)
            } catch let error as CursorCookieImportError {
                switch error {
                case .safariNeedsFullDiskAccess, .keychainAccessDisabled:
                    throw error
                case .noSessionCookie:
                    break
                }
            } catch {
                // Fall through to generic no-session error.
            }
        }

        if allowCachedSessions {
            let storedCookies = await CursorSessionStore.shared.getCookies()
            if !storedCookies.isEmpty {
                log("Using stored session cookies")
                let cookieHeader = storedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                do {
                    return try await validateCookieHeader(
                        cookieHeader,
                        sourceLabel: "stored session",
                        accountId: accountId,
                        cookies: storedCookies)
                } catch let error as CursorProbeError where error == .notLoggedIn {
                    await CursorSessionStore.shared.clearCookies()
                    log("Stored session invalid, cleared")
                } catch {
                    log("Stored session failed: \(error.localizedDescription)")
                }
            }
        }

        throw CursorProbeError.noSessionCookie
    }

    private func scanBrowsers(
        _ browsers: [Browser],
        allowKeychainPrompt: Bool,
        surfaceSafariErrors: Bool,
        importSessions: (Browser) throws -> [CursorCookieImporter.SessionInfo],
        accountId: UUID,
        log: @escaping (String) -> Void
    ) async throws -> CursorValidatedSession? {
        var safariError: Error?

        for browser in browsers {
            let sessions: [CursorCookieImporter.SessionInfo]
            do {
                sessions = try importSessions(browser)
            } catch {
                if browser == .safari {
                    safariError = CursorCookieImporter.mapSafariError(error)
                    log("Safari cookie read failed: \(error.localizedDescription)")
                }
                continue
            }
            guard !sessions.isEmpty else { continue }

            for session in sessions {
                log("Trying Cursor session from \(session.sourceLabel)")
                do {
                    let validated = try await validateCookieHeader(
                        session.cookieHeader,
                        sourceLabel: session.sourceLabel,
                        accountId: accountId,
                        cookies: session.cookies)
                    return validated
                } catch let error as CursorProbeError where error == .notLoggedIn {
                    log("Cursor API rejected cookies from \(session.sourceLabel); trying next")
                    continue
                } catch {
                    log("Cursor fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
                    continue
                }
            }
        }

        if surfaceSafariErrors, let safariError {
            throw safariError
        }
        return nil
    }

    private func validateCookieHeader(
        _ cookieHeader: String,
        sourceLabel: String,
        accountId: UUID,
        cookies: [HTTPCookie]
    ) async throws -> CursorValidatedSession {
        _ = try await fetchUsageSummary(cookieHeader: cookieHeader)
        let userInfo = try? await fetchUserInfo(cookieHeader: cookieHeader)
        CookieHeaderCache.store(accountId: accountId, cookieHeader: cookieHeader, sourceLabel: sourceLabel)
        if !cookies.isEmpty {
            await CursorSessionStore.shared.setCookies(cookies)
        }

        let name = userInfo?.name ?? userInfo?.email
        let email = userInfo?.email
        let displayName = name ?? sourceLabel
        return CursorValidatedSession(
            cookieHeader: cookieHeader,
            sourceLabel: sourceLabel,
            accountInfo: CursorAccountInfo(name: displayName, email: email),
            cookies: cookies)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws {
        let url = baseURL.appendingPathComponent("/api/usage-summary")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorProbeError.networkError("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CursorProbeError.notLoggedIn
        }
        guard http.statusCode == 200 else {
            throw CursorProbeError.networkError("HTTP \(http.statusCode)")
        }
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let url = baseURL.appendingPathComponent("/api/auth/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CursorProbeError.networkError("Failed to fetch user info")
        }
        return try JSONDecoder().decode(CursorUserInfo.self, from: data)
    }
}

extension CursorProbeError: Equatable {
    static func == (lhs: CursorProbeError, rhs: CursorProbeError) -> Bool {
        switch (lhs, rhs) {
        case (.notLoggedIn, .notLoggedIn), (.noSessionCookie, .noSessionCookie):
            return true
        case let (.networkError(a), .networkError(b)):
            return a == b
        default:
            return false
        }
    }
}
#endif
