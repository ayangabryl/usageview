import Foundation
import Security

/// Usageview-owned Keychain cache for third-party CLI tokens (CodexBar `KeychainCacheStore` pattern).
enum KeychainCacheStore {
    struct Key: Hashable, Sendable {
        let category: String
        let identifier: String

        var account: String { "\(category).\(identifier)" }
    }

    enum LoadResult<Entry> {
        case found(Entry)
        case missing
        case temporarilyUnavailable
        case invalid
    }

    private static let cacheService = "com.ayangabryl.usage.cache"
    private static let cacheLabel = "Usageview Cache"

    static func load<Entry: Codable>(key: Key, as type: Entry.Type = Entry.self) -> LoadResult<Entry> {
        guard !KeychainAccessGate.isDisabled else { return .missing }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: key.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let decoded = try? JSONDecoder().decode(Entry.self, from: data)
            else { return .invalid }
            return .found(decoded)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .temporarilyUnavailable
        default:
            return .invalid
        }
    }

    static func store(key: Key, entry: some Codable) {
        guard !KeychainAccessGate.isDisabled else { return }
        guard let data = try? JSONEncoder().encode(entry) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: key.account,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = cacheLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    @discardableResult
    static func clear(key: Key) -> Bool {
        guard !KeychainAccessGate.isDisabled else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: key.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}
