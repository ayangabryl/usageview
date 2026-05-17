import Foundation
import LocalAuthentication
import Security

// MARK: - Keychain Helper

/// Shared Keychain read/write/delete utility used by all auth services.
enum KeychainHelper {
    static let service = "com.ayangabryl.usage"

    private static var sessionCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// Save (or overwrite) a string value for the given key.
    static func save(_ value: String, forKey key: String) {
        let data = Data(value.utf8)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Legacy items may exist without kSecAttrService.
        let legacyDelete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(legacyDelete as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
        if let value = query(account: key, service: service, interactive: interactive) {
            return value
        }
        return query(account: key, service: nil, interactive: interactive)
    }

    private static func query(account: String, service: String?, interactive: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let service {
            query[kSecAttrService as String] = service
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
