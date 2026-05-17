import Foundation
import Security
import os

private let storeLog = Logger(subsystem: "com.ayangabryl.usage", category: "GeminiCLICredentialStore")

enum GeminiCLICredentialStore {
    static let keychainService = "gemini-cli-oauth"
    private static let cacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "gemini-cli")
    private static let memoryValidity: TimeInterval = 60 * 5

    private struct CacheEntry: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?
        let cachedAt: Date
    }

    private static var memoryCache: CacheEntry?
    private static var memoryCachedAt: Date?
    private static var suppressReadsThisSession = false
    private static var hasAttemptedBackgroundLoadThisSession = false

    static func load() -> GeminiOAuthCredentials? {
        if let memory = readMemoryCache() { return memory }

        guard !hasAttemptedBackgroundLoadThisSession else { return nil }
        hasAttemptedBackgroundLoadThisSession = true

        if case let .found(entry) = KeychainCacheStore.load(key: cacheKey, as: CacheEntry.self) {
            writeMemoryCache(entry)
            return GeminiOAuthCredentials(
                accessToken: entry.accessToken,
                refreshToken: entry.refreshToken,
                idToken: nil,
                expiresAt: entry.expiresAt
            )
        }

        if let fileCreds = loadFromFile() {
            cacheCredentials(fileCreds)
            return fileCreds
        }

        guard UserDefaults.standard.bool(forKey: "allowGeminiCLIKeychainAccess") else { return nil }
        guard !suppressReadsThisSession else { return nil }
        guard ClaudeKeychainAccessGate.shouldAllowPrompt() else { return nil }

        if ClaudeKeychainReadStrategyPreference.shouldPreferSecurityCLI(),
           let creds = loadViaSecurityCLI()
        {
            cacheCredentials(creds)
            return creds
        }

        switch KeychainAccessPreflight.checkGenericPassword(service: keychainService) {
        case .interactionRequired, .failure:
            suppressReadsThisSession = true
            ClaudeKeychainAccessGate.recordDenied()
            return nil
        case .notFound:
            return nil
        case .allowed:
            break
        }

        if let creds = loadViaSecurityFramework() {
            cacheCredentials(creds)
            return creds
        }
        return nil
    }

    static func resetSession() {
        suppressReadsThisSession = false
        hasAttemptedBackgroundLoadThisSession = false
        memoryCache = nil
        memoryCachedAt = nil
    }

    static var isReadSuppressed: Bool { suppressReadsThisSession }

    private static func loadFromFile() -> GeminiOAuthCredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".gemini/oauth_creds.json"),
            home.appendingPathComponent(".gemini/.credentials.json"),
        ]
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let tokenData = (json["main-account"] as? [String: Any])
                ?? (json["token"] as? [String: Any])
                ?? json

            guard let accessToken = tokenData["accessToken"] as? String
                ?? tokenData["access_token"] as? String,
                !accessToken.isEmpty
            else { continue }

            storeLog.info("Read Gemini CLI credentials from \(path.lastPathComponent)")
            return GeminiOAuthCredentials(
                accessToken: accessToken,
                refreshToken: tokenData["refreshToken"] as? String ?? tokenData["refresh_token"] as? String,
                idToken: tokenData["id_token"] as? String,
                expiresAt: tokenData["expiresAt"] as? Double ?? tokenData["expiry_date"] as? Double
            )
        }
        return nil
    }

    private static func loadViaSecurityCLI() -> GeminiOAuthCredentials? {
        guard let data = CLIKeychainReader.readGenericPassword(service: keychainService) else { return nil }
        return parseKeychainData(data)
    }

    private static func loadViaSecurityFramework() -> GeminiOAuthCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
                suppressReadsThisSession = true
                ClaudeKeychainAccessGate.recordDenied()
            }
            return nil
        }
        return parseKeychainData(data)
    }

    private static func parseKeychainData(_ data: Data) -> GeminiOAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokenData = (json["main-account"] as? [String: Any])
            ?? (json["token"] as? [String: Any])
            ?? json
        guard let accessToken = tokenData["accessToken"] as? String
            ?? tokenData["access_token"] as? String,
            !accessToken.isEmpty
        else { return nil }

        return GeminiOAuthCredentials(
            accessToken: accessToken,
            refreshToken: tokenData["refreshToken"] as? String ?? tokenData["refresh_token"] as? String,
            idToken: tokenData["id_token"] as? String,
            expiresAt: tokenData["expiresAt"] as? Double ?? tokenData["expiry_date"] as? Double
        )
    }

    private static func cacheCredentials(_ creds: GeminiOAuthCredentials) {
        let entry = CacheEntry(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt,
            cachedAt: Date()
        )
        writeMemoryCache(entry)
        KeychainCacheStore.store(key: cacheKey, entry: entry)
    }

    private static func readMemoryCache() -> GeminiOAuthCredentials? {
        guard let entry = memoryCache, let cachedAt = memoryCachedAt,
              Date().timeIntervalSince(cachedAt) < memoryValidity
        else { return nil }
        return GeminiOAuthCredentials(
            accessToken: entry.accessToken,
            refreshToken: entry.refreshToken,
            idToken: nil,
            expiresAt: entry.expiresAt
        )
    }

    private static func writeMemoryCache(_ entry: CacheEntry) {
        memoryCache = entry
        memoryCachedAt = Date()
    }
}
