import Foundation
import Security
import os

private let migrationLog = Logger(subsystem: "com.ayangabryl.usage", category: "KeychainMigration")

/// Re-saves Usageview Keychain items with `AfterFirstUnlock` accessibility to reduce unlock prompts.
enum KeychainMigration {
    private static let migrationKey = "UsageviewKeychainMigrationV1Completed"
    private static let accountPrefix = "com.ayangabryl.usage."

    static func migrateIfNeeded() {
        guard !KeychainAccessGate.isDisabled else { return }
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        migrationLog.info("Starting Usageview keychain accessibility migration")
        var migrated = 0

        let accounts = listUsageviewAccounts()
        for account in accounts {
            if migrateAccount(account) {
                migrated += 1
            }
        }

        migrationLog.info("Keychain migration complete: \(migrated) item(s) updated")
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private static func listUsageviewAccounts() -> [String] {
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

        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  account.hasPrefix(accountPrefix)
            else { return nil }
            return account
        }
    }

    private static func migrateAccount(_ account: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data
        else { return false }

        let target = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        if let accessible = item[kSecAttrAccessible as String] as? String, accessible == target {
            return false
        }

        SecItemDelete(query as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
}
