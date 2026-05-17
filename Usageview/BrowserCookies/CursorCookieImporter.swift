#if os(macOS)
import Foundation
import SweetCookieKit

enum CursorCookieImportError: LocalizedError {
    case noSessionCookie
    case keychainAccessDisabled
    case safariNeedsFullDiskAccess

    var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            [
                "No Cursor session found in \(BrowserCookieImportOrder.cursorCookieImportOrder.loginHint).",
                "Sign in at cursor.com, grant Usageview Full Disk Access if you use Safari, or use Sign in with browser.",
            ].joined(separator: " ")
        case .keychainAccessDisabled:
            "Browser import is off because “Stop password popups” is enabled in Settings. Paste your cookie manually, or turn that off and try again."
        case .safariNeedsFullDiskAccess:
            [
                "Usageview needs Full Disk Access to read Safari cookies (macOS blocks the read even when Safari is signed in).",
                "",
                "1. Open System Settings → Privacy & Security → Full Disk Access",
                "2. Turn ON Usageview (unlock with your Mac password if asked)",
                "3. Quit and reopen Usageview, then try again",
            ].joined(separator: "\n")
        }
    }
}

/// Imports Cursor session cookies from browsers (CodexBar `CursorCookieImporter` pattern).
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

    static func importSessionsIfPresent(
        browser: Browser,
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) throws -> [SessionInfo] {
        try importCookiesFromBrowser(
            browser: browser,
            requireKnownSessionName: true,
            allowKeychainPrompt: allowKeychainPrompt,
            logger: logger)
    }

    static func importDomainCookieSessionsIfPresent(
        browser: Browser,
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) throws -> [SessionInfo] {
        try importCookiesFromBrowser(
            browser: browser,
            requireKnownSessionName: false,
            allowKeychainPrompt: allowKeychainPrompt,
            logger: logger)
    }

    /// Quick import without API validation (prefer ``CursorStatusProbe``).
    static func importSession(
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) throws -> SessionInfo {
        if KeychainAccessGate.isDisabled, allowKeychainPrompt {
            throw CursorCookieImportError.keychainAccessDisabled
        }

        let browsers = BrowserCookieImportOrder.cursorCookieImportOrder
            .cookieImportCandidates(allowKeychainPrompt: allowKeychainPrompt)

        var lastBrowserError: Error?

        for browser in browsers {
            do {
                if let session = try importSessionsIfPresent(
                    browser: browser,
                    allowKeychainPrompt: allowKeychainPrompt,
                    logger: logger).first
                {
                    return session
                }
                if let session = try importDomainCookieSessionsIfPresent(
                    browser: browser,
                    allowKeychainPrompt: allowKeychainPrompt,
                    logger: logger).first
                {
                    return session
                }
            } catch {
                lastBrowserError = error
                if allowKeychainPrompt, browser == .safari {
                    throw mapSafariError(error)
                }
            }
        }

        if let lastBrowserError, allowKeychainPrompt {
            throw mapSafariError(lastBrowserError)
        }
        throw CursorCookieImportError.noSessionCookie
    }

    static func mapSafariError(_ error: Error) -> Error {
        if let cookieError = error as? BrowserCookieError {
            switch cookieError {
            case .accessDenied(.safari, _):
                return CursorCookieImportError.safariNeedsFullDiskAccess
            case let .loadFailed(.safari, details)
                where details.localizedCaseInsensitiveContains("full disk")
                    || details.localizedCaseInsensitiveContains("not readable"):
                return CursorCookieImportError.safariNeedsFullDiskAccess
            default:
                break
            }
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("full disk")
            || text.localizedCaseInsensitiveContains("not readable")
        {
            return CursorCookieImportError.safariNeedsFullDiskAccess
        }
        return error
    }

    private static func importCookiesFromBrowser(
        browser: Browser,
        requireKnownSessionName: Bool,
        allowKeychainPrompt: Bool,
        logger: ((String) -> Void)?
    ) throws -> [SessionInfo] {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        guard BrowserCookieAccessGate.shouldAttempt(browser, allowKeychainPrompt: allowKeychainPrompt) else {
            return []
        }

        let query = BrowserCookieQuery(domains: cookieDomains)
        let sources: [BrowserCookieStoreRecords]
        do {
            sources = try cookieClient.gatedRecords(
                matching: query,
                in: browser,
                allowKeychainPrompt: allowKeychainPrompt,
                logger: log)
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            throw error
        }

        if sources.isEmpty, browser == .safari {
            log("Safari returned no cookie stores — Full Disk Access may be required for Usageview")
        }

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
    }
}
#endif
