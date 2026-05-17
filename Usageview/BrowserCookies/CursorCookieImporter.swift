#if os(macOS)
import Foundation
import SweetCookieKit
import Darwin

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
    /// BrowserCookieClient initialised with the real (non-sandboxed) home directory.
    /// `FileManager.homeDirectoryForCurrentUser` returns the container path in sandboxed apps;
    /// `getpwuid` always returns the actual `/Users/name` path.
    private static let cookieClient: BrowserCookieClient = {
        var homes = BrowserCookieClient.defaultHomeDirectories()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let realHome = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
            if !homes.contains(where: { $0.path == realHome.path }) {
                homes.insert(realHome, at: 0)
            }
        }
        return BrowserCookieClient(configuration: .init(homeDirectories: homes))
    }()
    private static let detection = BrowserDetection.shared
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
            CursorCookieHeader.make(from: cookies)
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

    /// Suggested URL for the Chrome Default profile Cookies file — uses real home via getpwuid.
    static var chromeDefaultCookiesURL: URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let realHome = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        return realHome
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies")
    }

    /// Import Cursor session cookies from a specific Chrome `Cookies` SQLite file
    /// (selected via NSOpenPanel with security-scoped access).
    static func importSessionsFromCookiesFile(
        _ fileURL: URL,
        logger: ((String) -> Void)? = nil
    ) -> [SessionInfo] {
        let log: (String) -> Void = { msg in logger?("[cursor-cookie] \(msg)") }
        let store = BrowserCookieStore(
            browser: .chrome,
            profile: BrowserProfile(id: "user-selected", name: "Selected File"),
            kind: .primary,
            label: "Chrome (selected file)",
            databaseURL: fileURL)
        let query = BrowserCookieQuery(domains: cookieDomains)
        do {
            let records = try cookieClient.records(matching: query, in: store, logger: log)
            guard !records.isEmpty else {
                log("No cursor.com cookies in selected file")
                return []
            }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(records, origin: query.origin)
            let hasNamedSession = httpCookies.contains { CursorCookieHeader.sessionCookieNames.contains($0.name) }
            if hasNamedSession {
                log("Found \(httpCookies.count) Cursor cookies in selected Chrome file")
                return [SessionInfo(cookies: httpCookies, sourceLabel: "Chrome (selected)")]
            }
            if !httpCookies.isEmpty {
                log("Found \(httpCookies.count) domain cookies in selected Chrome file")
                return [SessionInfo(cookies: httpCookies, sourceLabel: "Chrome (selected, domain cookies)")]
            }
        } catch {
            log("Selected Cookies file import failed: \(error.localizedDescription)")
        }
        return []
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
                let hasNamedSession = httpCookies.contains { CursorCookieHeader.sessionCookieNames.contains($0.name) }
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
