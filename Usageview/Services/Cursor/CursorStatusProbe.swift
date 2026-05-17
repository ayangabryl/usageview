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

/// Discovers and validates Cursor sessions (CodexBar `CursorStatusProbe.fetch` pattern).
struct CursorStatusProbe: Sendable {
    private let baseURL = URL(string: "https://cursor.com")!
    private let timeout: TimeInterval

    init(networkTimeout: TimeInterval = 15) {
        self.timeout = networkTimeout
    }

    /// Same flow as CodexBar: cache → strict browser pass → domain pass → stored session.
    func fetchValidatedSession(
        accountId: UUID,
        manualCookieHeader: String? = nil,
        allowCachedSessions: Bool = true,
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) async throws -> CursorValidatedSession {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        var report = CursorImportReport()

        if let override = CookieHeaderNormalizer.normalize(manualCookieHeader) {
            log("Using manual cookie header")
            let header = CursorCookieHeader.make(from: override)
            return try await validateCookieHeader(header, sourceLabel: "manual", accountId: accountId, cookies: [])
        }

        if allowCachedSessions,
           let cached = CookieHeaderCache.load(accountId: accountId),
           !cached.cookieHeader.isEmpty
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
                chromeSkipped: true))
        }

        // Pass 1: known session cookie names (CodexBar)
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

        // Pass 2: any domain cookies + API proof (CodexBar)
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

        if allowCachedSessions {
            let storedCookies = await CursorSessionStore.shared.getCookies()
            if !storedCookies.isEmpty {
                log("Using stored session cookies")
                let header = CursorCookieHeader.make(from: storedCookies)
                do {
                    return try await validateCookieHeader(
                        header,
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

        let chromeSkipped = browsers.contains { browser in
            browser.usesKeychainForCookieDecryption
                && !BrowserCookieAccessGate.shouldAttempt(browser, allowKeychainPrompt: allowKeychainPrompt)
        }
        throw CursorProbeError.noSessionCookie(details: report.failureMessage(
            apiRejected: report.apiRejectedSources,
            chromeSkipped: chromeSkipped))
    }

    /// Validate a pre-built list of sessions (e.g. from a user-selected file).
    func validateSessions(
        _ sessions: [CursorCookieImporter.SessionInfo],
        accountId: UUID,
        logger: ((String) -> Void)? = nil
    ) async throws -> CursorValidatedSession {
        let log: (String) -> Void = { msg in logger?("[cursor] \(msg)") }
        var apiRejected: [String] = []
        for session in sessions {
            log("Trying Cursor session from \(session.sourceLabel)")
            do {
                return try await validateCookieHeader(
                    session.cookieHeader,
                    sourceLabel: session.sourceLabel,
                    accountId: accountId,
                    cookies: session.cookies)
            } catch let error as CursorProbeError where error == .notLoggedIn {
                apiRejected.append(session.sourceLabel)
                log("Cursor API rejected cookies from \(session.sourceLabel)")
            } catch {
                log("Cursor fetch failed: \(error.localizedDescription)")
                throw error
            }
        }
        throw CursorProbeError.noSessionCookie(
            details: "Cursor API rejected the session cookies from the selected file. Make sure you're signed in to cursor.com in Chrome first.")
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
                if browser == .safari { report.safariHadNoCookies = true }
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
        let header = CursorCookieHeader.make(from: cookieHeader)
        let userInfo = try await validateWithCursorAPI(cookieHeader: header)
        CookieHeaderCache.store(accountId: accountId, cookieHeader: header, sourceLabel: sourceLabel)
        if !cookies.isEmpty {
            await CursorSessionStore.shared.setCookies(cookies)
        }

        let name = userInfo?.name ?? userInfo?.email
        return CursorValidatedSession(
            cookieHeader: header,
            sourceLabel: sourceLabel,
            accountInfo: CursorAccountInfo(name: name ?? sourceLabel, email: userInfo?.email),
            cookies: cookies)
    }

    /// CodexBar uses usage-summary; accept auth/me when usage-summary is unavailable but session is valid.
    private func validateWithCursorAPI(cookieHeader: String) async throws -> CursorUserInfo? {
        do {
            _ = try await fetchUsageSummary(cookieHeader: cookieHeader)
            return try? await fetchUserInfo(cookieHeader: cookieHeader)
        } catch let error as CursorProbeError where error == .notLoggedIn {
            throw error
        } catch {
            return try await fetchUserInfo(cookieHeader: cookieHeader)
        }
    }

    private func fetchUsageSummary(cookieHeader: String) async throws {
        let bases = [baseURL, URL(string: "https://www.cursor.com")!]
        var lastStatus: Int?
        for base in bases {
            var request = URLRequest(url: base.appendingPathComponent("/api/usage-summary"))
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("\(base.absoluteString)/settings", forHTTPHeaderField: "Referer")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            lastStatus = http.statusCode
            if http.statusCode == 401 || http.statusCode == 403 { throw CursorProbeError.notLoggedIn }
            if http.statusCode == 200 { return }
        }
        if let lastStatus { throw CursorProbeError.networkError("usage-summary HTTP \(lastStatus)") }
        throw CursorProbeError.networkError("Could not reach Cursor")
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> CursorUserInfo {
        let bases = [baseURL, URL(string: "https://www.cursor.com")!]
        for base in bases {
            var request = URLRequest(url: base.appendingPathComponent("/api/auth/me"))
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 { throw CursorProbeError.notLoggedIn }
            guard http.statusCode == 200 else { continue }
            return try JSONDecoder().decode(CursorUserInfo.self, from: data)
        }
        throw CursorProbeError.networkError("auth/me failed")
    }
}

private struct CursorImportReport {
    var scannedBrowsers: [String] = []
    var foundSources: [String] = []
    var apiRejectedSources: [String] = []
    var safariHadNoCookies = false

    func failureMessage(apiRejected: [String], chromeSkipped: Bool) -> String {
        var lines: [String] = []

        if !apiRejected.isEmpty {
            lines.append("Found cookies but Cursor rejected them: \(apiRejected.joined(separator: ", ")).")
            lines.append("Sign out at cursor.com, sign in again, then tap Import from browsers.")
        } else {
            lines.append("No valid Cursor session found.")
            lines.append("1. Sign in at https://cursor.com in Safari or Chrome (same browser you import from).")
            lines.append("2. Tap Import from browsers — allow Keychain if macOS asks for Chrome Safe Storage.")
        }

        if safariHadNoCookies {
            lines.append("")
            lines.append("Safari: turn on Full Disk Access for this app, quit & reopen Usageview:")
            lines.append(CursorCookieImporter.runningAppPathForPrivacySettings)
        }

        if chromeSkipped {
            lines.append("Chrome was skipped. Tap Import again and click Always Allow on the Keychain prompt.")
        } else if !scannedBrowsers.isEmpty {
            lines.append("Checked: \(scannedBrowsers.joined(separator: ", ")).")
        }

        return lines.joined(separator: "\n")
    }
}

extension CursorProbeError: Equatable {
    static func == (lhs: CursorProbeError, rhs: CursorProbeError) -> Bool {
        switch (lhs, rhs) {
        case (.notLoggedIn, .notLoggedIn): return true
        case let (.networkError(a), .networkError(b)): return a == b
        case let (.noSessionCookie(a), .noSessionCookie(b)): return a == b
        default: return false
        }
    }
}
#endif
