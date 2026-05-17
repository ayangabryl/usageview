#if os(macOS)
import Foundation
import SweetCookieKit

enum CursorProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case noSessionCookie(details: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Cursor rejected the session. Sign in again at cursor.com, then retry."
        case let .networkError(msg):
            "Cursor API error: \(msg)"
        case let .noSessionCookie(details):
            details
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
    private let baseURLs = [
        URL(string: "https://cursor.com")!,
        URL(string: "https://www.cursor.com")!,
    ]
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
        var report = CursorImportReport()

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
        report.scannedBrowsers = browsers.map(\.displayName)

        if browsers.isEmpty {
            throw CursorProbeError.noSessionCookie(details: report.failureMessage(
                apiRejected: [],
                safariBlocked: false))
        }

        if let session = await scanBrowsers(
            browsers,
            accountId: accountId,
            report: &report,
            importSessions: { browser in
                CursorCookieImporter.importSessionsIfPresent(
                    browser: browser,
                    allowKeychainPrompt: allowKeychainPrompt,
                    logger: logger)
            },
            log: log)
        {
            return session
        }

        if !loginPollMode {
            if let session = await scanBrowsers(
                browsers,
                accountId: accountId,
                report: &report,
                importSessions: { browser in
                    CursorCookieImporter.importDomainCookieSessionsIfPresent(
                        browser: browser,
                        allowKeychainPrompt: allowKeychainPrompt,
                        logger: logger)
                },
                log: log)
            {
                return session
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
                } catch {
                    log("Stored session failed: \(error.localizedDescription)")
                }
            }
        }

        let safariBlocked = report.safariReadFailed
        throw CursorProbeError.noSessionCookie(details: report.failureMessage(
            apiRejected: report.apiRejectedSources,
            safariBlocked: safariBlocked && allowKeychainPrompt))
    }

    private func scanBrowsers(
        _ browsers: [Browser],
        accountId: UUID,
        report: inout CursorImportReport,
        importSessions: (Browser) -> [CursorCookieImporter.SessionInfo],
        log: @escaping (String) -> Void
    ) async -> CursorValidatedSession? {
        for browser in browsers {
            let sessions = importSessions(browser)
            if sessions.isEmpty {
                if browser == .safari {
                    report.safariHadNoCookies = true
                }
                continue
            }

            for session in sessions {
                report.foundSources.append(session.sourceLabel)
                log("Trying Cursor session from \(session.sourceLabel)")
                do {
                    return try await validateCookieHeader(
                        session.cookieHeader,
                        sourceLabel: session.sourceLabel,
                        accountId: accountId,
                        cookies: session.cookies)
                } catch let error as CursorProbeError where error == .notLoggedIn {
                    report.apiRejectedSources.append(session.sourceLabel)
                    log("Cursor API rejected cookies from \(session.sourceLabel); trying next")
                } catch {
                    log("Cursor fetch failed using \(session.sourceLabel): \(error.localizedDescription)")
                }
            }
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
        return CursorValidatedSession(
            cookieHeader: cookieHeader,
            sourceLabel: sourceLabel,
            accountInfo: CursorAccountInfo(name: name ?? sourceLabel, email: email),
            cookies: cookies)
    }

    private func fetchUsageSummary(cookieHeader: String) async throws {
        var lastStatus: Int?
        for baseURL in baseURLs {
            let url = baseURL.appendingPathComponent("/api/usage-summary")
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            lastStatus = http.statusCode
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CursorProbeError.notLoggedIn
            }
            if http.statusCode == 200 { return }
        }
        if lastStatus != nil {
            throw CursorProbeError.networkError("HTTP \(lastStatus!)")
        }
        throw CursorProbeError.networkError("Could not reach Cursor")
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        for baseURL in baseURLs {
            let url = baseURL.appendingPathComponent("/api/auth/me")
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
            return try JSONDecoder().decode(CursorUserInfo.self, from: data)
        }
        throw CursorProbeError.networkError("Failed to fetch user info")
    }
}

private struct CursorImportReport {
    var scannedBrowsers: [String] = []
    var foundSources: [String] = []
    var apiRejectedSources: [String] = []
    var safariHadNoCookies = false
    var safariReadFailed = false

    func failureMessage(apiRejected: [String], safariBlocked: Bool) -> String {
        var lines: [String] = []

        if !apiRejected.isEmpty {
            lines.append("Found cookies but Cursor rejected them (stale or wrong profile): \(apiRejected.joined(separator: ", ")).")
            lines.append("Sign out of cursor.com in your browser, sign in again, then Import.")
        } else if foundSources.isEmpty {
            lines.append("No Cursor session cookies found.")
            lines.append("Sign in at https://cursor.com in Safari or Chrome, then tap Import from browsers.")
        }

        if safariBlocked || safariHadNoCookies {
            lines.append("")
            lines.append("Safari: enable Full Disk Access for this exact app, then quit and reopen Usageview:")
            lines.append(CursorCookieImporter.runningAppPathForPrivacySettings)
        }

        if scannedBrowsers.isEmpty {
            lines.append("Chrome was skipped (Keychain). Tap Import again and click Always Allow if macOS asks for Chrome Safe Storage.")
        } else {
            lines.append("Checked: \(scannedBrowsers.joined(separator: ", ")).")
        }

        return lines.joined(separator: "\n")
    }
}

extension CursorProbeError: Equatable {
    static func == (lhs: CursorProbeError, rhs: CursorProbeError) -> Bool {
        switch (lhs, rhs) {
        case (.notLoggedIn, .notLoggedIn):
            return true
        case let (.networkError(a), .networkError(b)):
            return a == b
        case let (.noSessionCookie(a), .noSessionCookie(b)):
            return a == b
        default:
            return false
        }
    }
}
#endif
