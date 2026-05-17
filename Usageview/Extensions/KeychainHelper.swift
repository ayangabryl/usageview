import Foundation
import LocalAuthentication
import Security

// MARK: - Keychain Helper

/// Shared Keychain read/write/delete utility used by all auth services.
enum KeychainHelper {
    static let service = "com.ayangabryl.usage"

    /// Keychain access group tied to the developer team rather than a specific binary,
    /// so re-installs via DMG never trigger "allow access" dialogs.
    static let accessGroup = "MZRACJ7Z64.com.ayangabryl.quotabar"

    private static var sessionCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// Save (or overwrite) a string value for the given key.
    static func save(_ value: String, forKey key: String) {
        let data = Data(value.utf8)

        // Delete any existing item regardless of which access group it was saved in.
        for deleteQuery: [String: Any] in [
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: key],
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrAccount as String: key],
        ] { SecItemDelete(deleteQuery as CFDictionary) }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)

        cacheLock.lock()
        sessionCache[key] = value
        cacheLock.unlock()
    }

    /// Load a previously saved string value, or `nil` if absent / temporarily unavailable.
    /// Uses non-interactive access so background refreshes never surface macOS password prompts.
    static func load(forKey key: String) -> String? {
        cacheLock.lock()
        if let cached = sessionCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let value = loadFromKeychain(forKey: key, interactive: false) else { return nil }

        cacheLock.lock()
        sessionCache[key] = value
        cacheLock.unlock()
        return value
    }

    /// Deletes the stored value and drops any in-memory cache entry.
    static func remove(forKey key: String) {
        cacheLock.lock()
        sessionCache.removeValue(forKey: key)
        cacheLock.unlock()

        let queries: [[String: Any]] = [
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ],
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
            ],
        ]
        for query in queries {
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Fills the session cache from Keychain without showing UI (safe on launch / refresh).
    static func warmSessionCache() {
        for account in listUsageviewAccounts() {
            _ = load(forKey: account)
        }
    }

    /// Removes Keychain rows whose trailing UUID is not a current Usageview account (e.g. after delete).
    @discardableResult
    static func cleanupOrphanedTokens(keepingAccountIds activeIds: Set<UUID>) -> Int {
        var removed = 0
        for key in listUsageviewAccounts() {
            guard let id = accountId(fromKeychainAccount: key) else { continue }
            guard !activeIds.contains(id) else { continue }
            remove(forKey: key)
            removed += 1
        }
        return removed
    }

    static func accountId(fromKeychainAccount key: String) -> UUID? {
        guard key.count >= 36 else { return nil }
        return UUID(uuidString: String(key.suffix(36)))
    }

    /// One-time interactive repair for items that still require a password / Allow dialog.
    @discardableResult
    static func repairSavedToken(forKey key: String) -> Bool {
        guard let value = loadFromKeychain(forKey: key, interactive: true) else { return false }
        save(value, forKey: key)
        return true
    }

    static func listUsageviewAccounts() -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row -> String? in
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix("com.ayangabryl.usage.")
            else { return nil }
            let rowService = row[kSecAttrService as String] as? String
            if rowService == "\(service).cache" { return nil }
            return account
        }
    }

    // MARK: - Private

    private static func loadFromKeychain(forKey key: String, interactive: Bool) -> String? {
        // Try with explicit access group first (post-V3 migration items), then fall back
        // to no-group queries for items saved before the access group was introduced.
        if let value = query(account: key, service: service, group: accessGroup, interactive: interactive) {
            return value
        }
        if let value = query(account: key, service: service, group: nil, interactive: interactive) {
            return value
        }
        return query(account: key, service: nil, group: nil, interactive: interactive)
    }

    private static func query(account: String, service: String?, group: String?, interactive: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        if let group {
            query[kSecAttrAccessGroup as String] = group
        }

        if interactive {
            let context = LAContext()
            context.localizedReason = "Usageview needs access to a saved sign-in token."
            query[kSecUseAuthenticationContext as String] = context
        } else {
            KeychainNoUIQuery.apply(to: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
