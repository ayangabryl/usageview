#if os(macOS)
import Foundation
import SweetCookieKit

enum KimiCookieImportError: LocalizedError {
    case noCookies

    var errorDescription: String? {
        switch self {
        case .noCookies:
            "No Kimi session found. Sign in at kimi.com in Safari, Chrome, or Arc, then try again."
        }
    }
}

enum KimiCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["www.kimi.com", "kimi.com"]

    struct SessionInfo: Sendable {
        let cookies: [HTTPCookie]
        let sourceLabel: String

        var authToken: String? {
            cookies.first { $0.name == "kimi-auth" }?.value
        }
    }

    static func importSession(logger: ((String) -> Void)? = nil) throws -> SessionInfo {
        let sessions = try importSessions(logger: logger)
        guard let first = sessions.first else {
            throw KimiCookieImportError.noCookies
        }
        return first
    }

    static func importSessions(logger: ((String) -> Void)? = nil) throws -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        for browser in Browser.defaultImportOrder.cookieImportCandidates() {
            do {
                sessions.append(contentsOf: try importSessions(from: browser, logger: logger))
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
            }
        }
        guard !sessions.isEmpty else {
            throw KimiCookieImportError.noCookies
        }
        return sessions
    }

    private static func importSessions(
        from browser: Browser,
        logger: ((String) -> Void)?
    ) throws -> [SessionInfo] {
        let query = BrowserCookieQuery(domains: cookieDomains)
        let log: (String) -> Void = { msg in logger?("[kimi-cookie] \(msg)") }
        let sources = try cookieClient.gatedRecords(matching: query, in: browser, logger: log)

        var sessions: [SessionInfo] = []
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let sortedGroups = grouped.values.sorted { mergedLabel(for: $0) < mergedLabel(for: $1) }

        for group in sortedGroups where !group.isEmpty {
            let label = mergedLabel(for: group)
            let mergedRecords = mergeRecords(group)
            guard !mergedRecords.isEmpty else { continue }
            let httpCookies = BrowserCookieClient.makeHTTPCookies(mergedRecords, origin: query.origin)
            guard httpCookies.contains(where: { $0.name == "kimi-auth" }) else { continue }
            log("Found kimi-auth cookie in \(label)")
            sessions.append(SessionInfo(cookies: httpCookies, sourceLabel: label))
        }
        return sessions
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else { return "Unknown" }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted {
            storePriority($0.store.kind) < storePriority($1.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
                if let existing = mergedByKey[key] {
                    if shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }
}
#endif
