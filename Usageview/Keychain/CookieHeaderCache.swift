import Foundation

/// Keychain-backed validated Cursor cookie header (CodexBar `CookieHeaderCache` pattern).
enum CookieHeaderCache {
    struct Entry: Codable, Sendable {
        let cookieHeader: String
        let storedAt: Date
        let sourceLabel: String
    }

    private static func cacheKey(accountId: UUID) -> KeychainCacheStore.Key {
        KeychainCacheStore.Key(category: "cookie", identifier: "cursor.\(accountId.uuidString.lowercased())")
    }

    static func load(accountId: UUID) -> Entry? {
        let key = cacheKey(accountId: accountId)
        switch KeychainCacheStore.load(key: key, as: Entry.self) {
        case let .found(entry):
            return entry
        case .invalid:
            KeychainCacheStore.clear(key: key)
            return nil
        case .missing, .temporarilyUnavailable:
            return nil
        }
    }

    static func store(accountId: UUID, cookieHeader: String, sourceLabel: String, now: Date = Date()) {
        guard let normalized = CookieHeaderNormalizer.normalize(cookieHeader), !normalized.isEmpty else {
            clear(accountId: accountId)
            return
        }
        let entry = Entry(cookieHeader: normalized, storedAt: now, sourceLabel: sourceLabel)
        KeychainCacheStore.store(key: cacheKey(accountId: accountId), entry: entry)
    }

    static func clear(accountId: UUID) {
        KeychainCacheStore.clear(key: cacheKey(accountId: accountId))
    }
}
