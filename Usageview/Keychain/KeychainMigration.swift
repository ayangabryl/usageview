import Foundation
import Security
import os

private let migrationLog = Logger(subsystem: "com.ayangabryl.usage", category: "KeychainMigration")

/// Re-saves Usageview Keychain items with `AfterFirstUnlock` and a stable service id to reduce unlock prompts.
enum KeychainMigration {
    private static let migrationV2Key = "UsageviewKeychainMigrationV2Completed"

    static func migrateIfNeeded() {
        guard !KeychainAccessGate.isDisabled else { return }
        guard !UserDefaults.standard.bool(forKey: migrationV2Key) else {
            KeychainHelper.warmSessionCache()
            return
        }

        migrationLog.info("Starting Usageview keychain V2 migration")
        var migrated = 0

        for account in KeychainHelper.listUsageviewAccounts() {
            if migrateAccount(account) {
                migrated += 1
            }
        }

        migrationLog.info("Keychain V2 migration complete: \(migrated) item(s) updated")
        UserDefaults.standard.set(true, forKey: migrationV2Key)
        KeychainHelper.warmSessionCache()
    }

    /// Call after accounts are loaded from disk so deleted accounts do not leave Keychain clutter.
    static func cleanupOrphanedTokens(keepingAccountIds activeIds: Set<UUID>) {
        let removed = KeychainHelper.cleanupOrphanedTokens(keepingAccountIds: activeIds)
        if removed > 0 {
            migrationLog.info("Removed \(removed) orphaned Usageview keychain item(s)")
        }
    }

    private static func migrateAccount(_ account: String) -> Bool {
        guard let value = KeychainHelper.load(forKey: account) else { return false }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let item = result as? [String: Any]
        else {
            KeychainHelper.save(value, forKey: account)
            return true
        }

        let target = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        let hasService = (item[kSecAttrService as String] as? String) == KeychainHelper.service
        if let accessible = item[kSecAttrAccessible as String] as? String,
           accessible == target, hasService
        {
            return false
        }

        KeychainHelper.save(value, forKey: account)
        return true
    }
}
