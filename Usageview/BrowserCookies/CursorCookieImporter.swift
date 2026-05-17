#if os(macOS)
import Foundation
import SweetCookieKit

enum CursorCookieImportError: LocalizedError {
    case noSessionCookie

    var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Cursor session found. Sign in at cursor.com in Safari, Chrome, or Arc, then try again."
        }
    }
}

/// Imports Cursor session cookies from installed browsers (CodexBar-style).
enum CursorCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "wos-session",
        "__Secure-wos-session",
        "authjs.session-token",
        "__Secure-authjs.session-token",
    ]

    private static let cookieDomains = [
        "cursor.com",
        "www.cursor.com",
        "cursor.sh",
        "authenticator.cursor.sh",
    ]

    struct SessionInfo: Sendable {
        let cookies: [HTTPCookie]
        let sourceLabel: String

        var cookieHeader: String {
            cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let browsers = Browser.defaultImportOrder.cookieImportCandidates()
        for browser in browsers {
            if let session = importSessionsIfPresent(browser: browser, logger: logger).first {
                return session
            }
        }
        for browser in browsers {
            if let session = importDomainCookieSessionsIfPresent(browser: browser, logger: logger).first {
                return session
            }
        }
        throw CursorCookieImportError.noSessionCookie
    }

    private static func importSessionsIfPresent(
        browser: Browser,
        logger: ((String) -> Void)?
    ) -> [SessionInfo] {
        importCookiesFromBrowser(browser: browser, requireKnownSessionName: true, logger: logger)
    }

    private static func importDomainCookieSessionsIfPresent(
        browser: Browser,
        logger: ((String) -> Void)?
    ) -> [SessionInfo] {
        importCookiesFromBrowser(browser: browser, requireKnownSessionName: false, logger: logger)
    }

    private static func importCookiesFromBrowser(
        browser: Browser,
        requireKnownSessionName: Bool,
        logger: ((String) -> Void)?
    ) -> [SessionInfo] {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }

        do {
            let query = BrowserCookieQuery(domains: cookieDomains)
            let sources = try cookieClient.gatedRecords(matching: query, in: browser, logger: log)
            var sessions: [SessionInfo] = []
            for source in sources where !source.records.isEmpty {
                let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                let hasNamedSession = httpCookies.contains { sessionCookieNames.contains($0.name) }
                if hasNamedSession, requireKnownSessionName {
                    log("Found \(httpCookies.count) Cursor cookies in \(source.label)")
                    sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: source.label))
                    continue
                }
                if !requireKnownSessionName, !httpCookies.isEmpty {
                    log("Found \(httpCookies.count) Cursor domain cookies in \(source.label)")
                    sessions.append(SessionInfo(
                        cookies: httpCookies,
                        sourceLabel: "\(source.label) (domain cookies)"))
                }
            }
            return sessions
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            log("\(browser.displayName) cookie import failed: \(error.localizedDescription)")
            return []
        }
    }
}
#endif
