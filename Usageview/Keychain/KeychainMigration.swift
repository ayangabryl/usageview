import Foundation
import Security
import os

private let migrationLog = Logger(subsystem: "com.ayangabryl.usage", category: "KeychainMigration")

/// Re-saves Usageview Keychain items with `AfterFirstUnlock`, a stable service id, and the team-bound
/// keychain access group to eliminate "allow access" prompts on fresh DMG installs.
enum KeychainMigration {
    private static let migrationV2Key = "UsageviewKeychainMigrationV2Completed"
    private static let migrationV3Key = "UsageviewKeychainMigrationV3Completed"

    /// UserDefaults key that stores the last launched app version, used to detect fresh installs.
    private static let lastVersionKey = "UsageviewLastLaunchedVersion"

    /// UserDefaults keys for security-scoped bookmarks that become stale after a reinstall.
    private static let staleBookmarkKeys = [
        "CodexHomeDirBookmarkV1",
        "CodexOAuthFolderBookmarkV3",
    ]

    static func migrateIfNeeded() {
        guard !KeychainAccessGate.isDisabled else { return }

        clearStaleDataOnVersionChange()

        if !UserDefaults.standard.bool(forKey: migrationV2Key) {
            runV2Migration()
        }

        if !UserDefaults.standard.bool(forKey: migrationV3Key) {
            runV3Migration()
        }

        KeychainHelper.warmSessionCache()
    }

    // MARK: - Version-change cleanup

    /// Detects a fresh install or version change and clears stale security-scoped bookmarks so
    /// the new binary doesn't inherit invalid file-access grants from the old one.
    private static func clearStaleDataOnVersionChange() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let storedVersion = UserDefaults.standard.string(forKey: lastVersionKey) ?? ""

        guard currentVersion != storedVersion else { return }

        migrationLog.info("Version changed \(storedVersion) → \(currentVersion): clearing stale bookmarks")

        for key in staleBookmarkKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Re-run access-group migration on each new version install so any items created
        // by old builds (potentially with different ACLs) are re-saved cleanly.
        UserDefaults.standard.removeObject(forKey: migrationV3Key)

        UserDefaults.standard.set(currentVersion, forKey: lastVersionKey)
    }

    // MARK: - V2 migration (accessibility + service normalisation)

    private static func runV2Migration() {
        migrationLog.info("Starting Usageview keychain V2 migration")
        var migrated = 0
        for account in KeychainHelper.listUsageviewAccounts() {
            if migrateV2Account(account) { migrated += 1 }
        }
        migrationLog.info("Keychain V2 migration complete: \(migrated) item(s) updated")
        UserDefaults.standard.set(true, forKey: migrationV2Key)
    }

    // MARK: - V3 migration (team-bound access group)

    /// Re-saves every Usageview auth token into the team-bound keychain access group so that
    /// future DMG installs never show "Usageview wants to use your keychain" dialogs.
    private static func runV3Migration() {
        migrationLog.info("Starting Usageview keychain V3 migration (access group)")
        var migrated = 0
        for account in KeychainHelper.listUsageviewAccounts() {
            guard let value = KeychainHelper.load(forKey: account) else { continue }
            // save() deletes the old item and re-creates it with kSecAttrAccessGroup set.
            KeychainHelper.save(value, forKey: account)
            migrated += 1
        }
        migrationLog.info("Keychain V3 migration complete: \(migrated) item(s) updated")
        UserDefaults.standard.set(true, forKey: migrationV3Key)
    }

    // MARK: - Orphan cleanup

    /// Call after accounts are loaded from disk so deleted accounts do not leave Keychain clutter.
    static func cleanupOrphanedTokens(keepingAccountIds activeIds: Set<UUID>) {
        let removed = KeychainHelper.cleanupOrphanedTokens(keepingAccountIds: activeIds)
        if removed > 0 {
            migrationLog.info("Removed \(removed) orphaned Usageview keychain item(s)")
        }
    }

    // MARK: - Private V2 helpers

    private static func migrateV2Account(_ account: String) -> Bool {
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
