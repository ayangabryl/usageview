import Foundation
import Security
import os

private let storeLog = Logger(subsystem: "com.ayangabryl.usage", category: "ClaudeCLICredentialStore")

/// Loads Claude Code CLI credentials using CodexBar's layered strategy.
enum ClaudeCLICredentialStore {
    static let keychainService = "Claude Code-credentials"
    private static let cacheKey = KeychainCacheStore.Key(category: "oauth", identifier: "claude-cli")
    private static let fileFingerprintKey = "ClaudeCLICredentialsFileFingerprint"
    private static let memoryValidity: TimeInterval = 60 * 5

    private struct CacheEntry: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?
        let cachedAt: Date
    }

    private struct FileFingerprint: Codable, Equatable {
        let modifiedAtMs: Int?
        let size: Int
    }

    private static var memoryCache: CacheEntry?
    private static var memoryCachedAt: Date?

    // MARK: - Public API

    static func load(interaction: ClaudeKeychainInteraction) -> ClaudeCLICredentials? {
        if let memory = readMemoryCache() {
            return memory
        }

        if interaction == .background {
            guard !hasAttemptedBackgroundLoadThisSession else { return nil }
            hasAttemptedBackgroundLoadThisSession = true
        }

        if case let .found(entry) = KeychainCacheStore.load(key: cacheKey, as: CacheEntry.self),
           Date().timeIntervalSince(entry.cachedAt) < memoryValidity * 12
        {
            writeMemoryCache(entry)
            return ClaudeCLICredentials(
                accessToken: entry.accessToken,
                refreshToken: entry.refreshToken,
                expiresAt: entry.expiresAt
            )
        }

        if let fileCreds = loadFromFile() {
            cacheCredentials(fileCreds)
            return fileCreds
        }

        guard UserDefaults.standard.bool(forKey: "allowClaudeCLIKeychainAccess") else {
            return nil
        }
        guard !suppressReadsThisSession else { return nil }

        let promptMode = currentPromptMode()
        guard shouldAttemptKeychain(mode: promptMode, interaction: interaction) else { return nil }
        guard ClaudeKeychainAccessGate.shouldAllowPrompt() else { return nil }

        if ClaudeKeychainReadStrategyPreference.shouldPreferSecurityCLI(),
           let creds = loadViaSecurityCLI()
        {
            cacheCredentials(creds)
            return creds
        }

        switch KeychainAccessPreflight.checkGenericPassword(service: keychainService) {
        case .interactionRequired:
            if interaction == .userInitiated, promptMode == .always {
                KeychainPromptCoordinator.notify(.init(kind: .claudeCLI))
            } else {
                suppressReadsThisSession = true
                ClaudeKeychainAccessGate.recordDenied()
                return nil
            }
        case .notFound:
            return nil
        case .failure:
            suppressReadsThisSession = true
            ClaudeKeychainAccessGate.recordDenied()
            return nil
        case .allowed:
            break
        }

        if let creds = loadViaSecurityFramework(allowInteractive: interaction == .userInitiated && promptMode == .always) {
            cacheCredentials(creds)
            return creds
        }

        return nil
    }

    static func hasCredentialsWithoutPrompt() -> Bool {
        if readMemoryCache() != nil { return true }
        if loadFromFile() != nil { return true }
        if case .found = KeychainCacheStore.load(key: cacheKey, as: CacheEntry.self) { return true }
        if ClaudeKeychainReadStrategyPreference.shouldPreferSecurityCLI(),
           loadViaSecurityCLI() != nil
        {
            return true
        }
        return KeychainAccessPreflight.checkGenericPassword(service: keychainService) == .allowed
    }

    static func invalidateMemoryCache() {
        memoryCache = nil
        memoryCachedAt = nil
    }

    static func resetSession() {
        suppressReadsThisSession = false
        hasAttemptedBackgroundLoadThisSession = false
        invalidateMemoryCache()
        ClaudeKeychainAccessGate.clearDenied()
    }

    static var isReadSuppressed: Bool { suppressReadsThisSession }

    /// One-time user setup; may show a single macOS Keychain dialog.
    static func connectOnce() -> Bool {
        resetSession()
        hasAttemptedBackgroundLoadThisSession = false
        KeychainPromptCoordinator.notify(.init(kind: .claudeCLI))

        if let fileCreds = loadFromFile() {
            cacheCredentials(fileCreds)
            return true
        }
        if let creds = loadViaSecurityCLI() {
            cacheCredentials(creds)
            return true
        }
        return loadViaSecurityFramework(allowInteractive: true) != nil
    }

    // MARK: - Session state

    private static var suppressReadsThisSession = false
    private static var hasAttemptedBackgroundLoadThisSession = false

    // MARK: - Load paths

    private static func loadFromFile() -> ClaudeCLICredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let size = (attrs[.size] as? NSNumber)?.intValue ?? data.count
        let modifiedAtMs = (attrs[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) }
        let fingerprint = FileFingerprint(modifiedAtMs: modifiedAtMs, size: size)

        if let stored = loadFileFingerprint(), stored == fingerprint, let memory = readMemoryCache() {
            return memory
        }
        saveFileFingerprint(fingerprint)

        let creds = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let accessToken = creds["accessToken"] as? String, !accessToken.isEmpty else { return nil }

        storeLog.info("Read Claude CLI credentials from file")
        return ClaudeCLICredentials(
            accessToken: accessToken,
            refreshToken: creds["refreshToken"] as? String,
            expiresAt: creds["expiresAt"] as? Double
        )
    }

    private static func loadViaSecurityCLI() -> ClaudeCLICredentials? {
        guard let data = CLIKeychainReader.readGenericPassword(service: keychainService) else { return nil }
        return parseKeychainData(data)
    }

    private static func loadViaSecurityFramework(allowInteractive: Bool) -> ClaudeCLICredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if allowInteractive {
            // User explicitly requested interactive access.
        } else {
            KeychainNoUIQuery.apply(to: &query)
        }

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

    private static func parseKeychainData(_ data: Data) -> ClaudeCLICredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let creds = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let accessToken = creds["accessToken"] as? String, !accessToken.isEmpty else { return nil }
        storeLog.info("Read Claude CLI credentials from Keychain")
        return ClaudeCLICredentials(
            accessToken: accessToken,
            refreshToken: creds["refreshToken"] as? String,
            expiresAt: creds["expiresAt"] as? Double
        )
    }

    // MARK: - Cache helpers

    private static func cacheCredentials(_ creds: ClaudeCLICredentials) {
        let entry = CacheEntry(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt,
            cachedAt: Date()
        )
        writeMemoryCache(entry)
        KeychainCacheStore.store(key: cacheKey, entry: entry)
    }

    private static func readMemoryCache() -> ClaudeCLICredentials? {
        guard let entry = memoryCache, let cachedAt = memoryCachedAt,
              Date().timeIntervalSince(cachedAt) < memoryValidity
        else { return nil }
        return ClaudeCLICredentials(
            accessToken: entry.accessToken,
            refreshToken: entry.refreshToken,
            expiresAt: entry.expiresAt
        )
    }

    private static func writeMemoryCache(_ entry: CacheEntry) {
        memoryCache = entry
        memoryCachedAt = Date()
    }

    private static func loadFileFingerprint() -> FileFingerprint? {
        guard let data = UserDefaults.standard.data(forKey: fileFingerprintKey) else { return nil }
        return try? JSONDecoder().decode(FileFingerprint.self, from: data)
    }

    private static func saveFileFingerprint(_ fingerprint: FileFingerprint) {
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: fileFingerprintKey)
        }
    }

    private static func currentPromptMode() -> ClaudeKeychainPromptMode {
        if let raw = UserDefaults.standard.string(forKey: "claudeOAuthKeychainPromptMode"),
           let mode = ClaudeKeychainPromptMode(rawValue: raw)
        {
            return mode
        }
        return .onlyOnUserAction
    }

    private static func shouldAttemptKeychain(
        mode: ClaudeKeychainPromptMode,
        interaction: ClaudeKeychainInteraction
    ) -> Bool {
        switch mode {
        case .never: return false
        case .onlyOnUserAction: return interaction == .userInitiated
        case .always: return true
        }
    }
}
