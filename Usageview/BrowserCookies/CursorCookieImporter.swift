#if os(macOS)
import Foundation
import SweetCookieKit

enum CursorCookieImportError: LocalizedError {
    case noSessionCookie(details: String)
    case keychainAccessDisabled
    case safariNeedsFullDiskAccess(appPath: String)

    var errorDescription: String? {
        switch self {
        case let .noSessionCookie(details):
            details
        case .keychainAccessDisabled:
            "Browser import is off because “Stop password popups” is enabled in Settings. Paste your cookie manually, or turn that off and try again."
        case let .safariNeedsFullDiskAccess(appPath):
            [
                "Usageview still cannot read Safari cookies.",
                "",
                "Full Disk Access must be enabled for the app you are actually running:",
                appPath,
                "",
                "If you run from Xcode, add that Usageview.app (or Xcode.app) in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Usageview.",
            ].joined(separator: "\n")
        }
    }
}

/// Imports Cursor session cookies from browsers (CodexBar `CursorCookieImporter` pattern).
enum CursorCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let detection = BrowserDetection.shared
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
    ) -> [SessionInfo] {
        importCookiesFromBrowser(
            browser: browser,
            requireKnownSessionName: true,
            allowKeychainPrompt: allowKeychainPrompt,
            logger: logger)
    }

    static func importDomainCookieSessionsIfPresent(
        browser: Browser,
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) -> [SessionInfo] {
        importCookiesFromBrowser(
            browser: browser,
            requireKnownSessionName: false,
            allowKeychainPrompt: allowKeychainPrompt,
            logger: logger)
    }

    static var runningAppPathForPrivacySettings: String {
        Bundle.main.bundleURL.path
    }

    /// CodexBar-style: never throw from per-browser reads; return [] on failure.
    private static func importCookiesFromBrowser(
        browser: Browser,
        requireKnownSessionName: Bool,
        allowKeychainPrompt: Bool,
        logger: ((String) -> Void)?
    ) -> [SessionInfo] {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        guard detection.isCookieSourceAvailable(browser) else {
            log("\(browser.displayName) skipped (no cookie store on disk)")
            return []
        }
        guard BrowserCookieAccessGate.shouldAttempt(browser, allowKeychainPrompt: allowKeychainPrompt) else {
            log("\(browser.displayName) skipped (Keychain access blocked — tap Import again and choose Always Allow for Chrome Safe Storage)")
            return []
        }

        do {
            let query = BrowserCookieQuery(domains: cookieDomains)
            let sources = try cookieClient.gatedRecords(
                matching: query,
                in: browser,
                allowKeychainPrompt: allowKeychainPrompt,
                logger: log)

            var sessions: [SessionInfo] = []
            for source in sources where !source.records.isEmpty {
                let names = source.records.map(\.name).joined(separator: ", ")
                log("\(source.label): [\(names)]")

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
                } else if !httpCookies.isEmpty {
                    log("\(source.label) has cookies but no known session name yet")
                }
            }

            if sessions.isEmpty, browser == .safari {
                log("Safari: no Cursor cookies — sign in at cursor.com in Safari, or check Full Disk Access for \(runningAppPathForPrivacySettings)")
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
